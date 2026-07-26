# zcompiler

[![CI](https://github.com/serian/zcompiler/actions/workflows/ci.yml/badge.svg)](https://github.com/serian/zcompiler/actions/workflows/ci.yml)

Un **compilateur JavaScript écrit en Zig**, construit étape par étape à la manière
d'[OXC](https://oxc.rs)/Babel, exposé à Node.js via [zignapi](../zignapi) (bindings
natif **et WebAssembly** en Zig). Le paquet npm s'appelle `zcompiler` (backend natif
via `@zcompiler/binding-<triple>`, backend wasm via `wasm.js`) ; le projet a grandi
jusqu'à un pipeline complet. Sert aussi de banc de test en conditions réelles pour zignapi.

```
             ┌─────────┐   ┌──────────┐   ┌────────────────┐   ┌─────────┐
   source ──▶│  parse  │──▶│ semantic │──▶│ transform /    │──▶│  print  │──▶ JS
             │ (AST)   │   │ (scopes) │   │ mangle (AST')  │   │ (codegen)│
             └─────────┘   └──────────┘   └────────────────┘   └─────────┘
```

Chaque passe est isolée dans son fichier et ne dépend que de ce dont elle a besoin
(l'AST, parfois le walker/semantic) — prêt pour un split en paquets indépendants.

## Le pipeline

| Passe | Fichier | Rôle |
|---|---|---|
| **lexer** | `native/lexer.zig` | tokens + spans BYTES (zéro-copie), maximal munch, templates, regex contextuelle, hashbang, `#privé`, BigInt, **identifiants Unicode + `\u`** |
| **parser** | `native/parser.zig` | descente récursive + Pratt ; AST ESTree-like dans une arena ; cover grammar (destructuring) |
| **ast** | `native/ast.zig` | nœuds (tagged unions) + debug-printer indenté |
| **walker** | `native/walker.zig` | parcours générique `walk(node, visitor)` (enter/exit) — partagé |
| **semantic** | `native/semantic.zig` | scopes / bindings / résolution des références + quelques early errors |
| **transformer** | `native/transformer.zig` | constant folding, simplification booléenne, DCE scope-aware |
| **mangler** | `native/mangler.zig` | renommage des variables locales (base du minifier) |
| **printer** | `native/printer.zig` | codegen : AST → JS valide (recrée les parenthèses via la précédence) |
| **pont** | `native/main.zig` | `zignapi.register(...)` → `zparse.parse/parseErrors/print/transform/semantic/mangle` + jumeaux `*Jsx` (opt-in) |

## Ce que ça sait faire (les chiffres)

Corpus de test : **684 fichiers réels** (653 tiers + 16 sans-`;` + 10 unicode + 5 de
notre code) — lodash-es, nanoid, mitt (`corpus/node_modules`), + code « standard
style » sans `;` de feross/mafintosh (buffer, simple-peer, bittorrent-dht…), + notre
propre source ; plus un corpus fabriqué `corpus/unicode/` (10 fichiers : accents,
CJK, grec, `\u…`). Pour l'error recovery, un corpus **`corpus/broken/`** (19 fichiers
cassés, en-têtes `// errors: N`, dont 4 JSX). Pour le **JSX** (opt-in), un corpus
**`corpus/jsx/`** (13 fichiers `.jsx` : composants, map imbriqué, fragments, spread,
namespaces svg…), **`corpus/ts/`** (26 fichiers `.ts` : services typés, interfaces,
unions, génériques d'appel, as/satisfies, `import type`…) et **`corpus/tsx/`** (8
composants React typés). Chaque passe a son harnais (`playground/corpus.js`).

| Vérification | Résultat |
|---|---|
| **parse** | **684/684** (100 %) — ES moderne, avec et sans `;` |
| **round-trip** `parse(print(parse(x))) ≡ parse(x)` | **684/684** — fidélité sémantique |
| **transform** (fold + booléen + DCE) → reparse | **684/684**, zéro JS invalide émis |
| **semantic** (scopes/bindings) | **684/684, zéro diagnostic** ; unresolved = globals plausibles |
| **mangle** (renommage) + invariants | **684/684** ; **−12,6 %** de taille (vs print non-manglé) |
| **recovery** (`corpus/broken`, code cassé) | **19/19** — N erreurs exactes, AST partiel, print sans crash |
| **JSX** (opt-in, `corpus/jsx`) | **13/13** sur les 5 modes ; JS pur inchangé (jsx off = bit-identique) |
| **JSX transform** (`--jsx-transform`, automatic runtime) | **13/13** — sortie JS pur (0 nœud JSX), semantic + chaîné mangle OK |
| **TypeScript phase 1** (opt-in, `corpus/ts`) | annotations + types + décls type-only + as/satisfies ; **`--ts-strip`** → JS pur |
| **TypeScript phase 2** (`corpus/ts`, `corpus/tsx` 8) | génériques d'appel `foo<T>(x)` (lookahead spéculatif) + `.tsx` + `T[K]`/`import type` : **8/8** (`--tsx` → JS pur) |
| **TypeScript phase 3** (`corpus/ts` 26) | **émission** : `enum`→IIFE, parameter properties→`this.x=x`, `namespace`→IIFE : **26/26** (`--ts-strip` sortie JS pur) |

### Benchmark (parse)

Contre [`oxc-parser`](https://www.npmjs.com/package/oxc-parser) (le parser JS le
plus rapide de l'écosystème, Rust) sur les mêmes fichiers :

```
zparse parse-pur  ~21 MB/s   |   oxc  ~90 MB/s   →   zparse ~4,2× plus lent qu'oxc
```

**Honnêteté** : oxc fait PLUS (early errors complets, strict mode, AST matérialisé) ;
zcompiler est un parser from-scratch sans validation sémantique complète. ~4× plus
lent que l'état de l'art = même ordre de grandeur, sain à ce stade.
(`node playground/bench.js <dir>`)

## Utilisation

```js
const z = require("@zparse/zparse");

z.parse(src);      // AST rendu en arbre indenté (debug) — récupère les erreurs, ne throw plus
z.parseErrors(src);// Array<{ message, offset }> — [] si le code est valide
z.tokenize(src);   // Array<{ kind, start, end }>
z.print(src);      // reparse → réimprime en JS normalisé (; partout, indentation 2)
z.transform(src);  // constant folding + simplif booléenne + DCE
z.semantic(src);   // { scopes, bindings, resolved, unresolved[], diagnostics[] }
z.mangle(src);     // renomme les bindings locaux en noms courts

// JSX (opt-in, dialecte React) : jumeaux *Jsx qui activent la grammaire JSX.
z.parseJsx(src);   // idem parse, mais <div/> est une expression
z.parseErrorsJsx(src); z.printJsx(src); z.transformJsx(src); z.semanticJsx(src); z.mangleJsx(src);
z.jsxTransform(src); // JSX -> jsx()/jsxs()/Fragment + import auto (automatic runtime React)

// TypeScript (opt-in, phases 1-3) : jumeaux *Ts / *Tsx + stripTypes.
z.parseTs(src);    // idem parse, mais `let x: number` et `foo<T>(x)` sont valides
z.parseErrorsTs(src); z.printTs(src); z.transformTs(src); z.semanticTs(src); z.mangleTs(src);
z.stripTypes(src); // EFFACE les types -> JS pur (jamais de vérification : tsc reste le juge)
z.parseTsx(src); z.stripTypesTsx(src); // .tsx : JSX + TypeScript ensemble (+ *Tsx)
```

## Build & tests

```bash
pnpm install
pnpm --filter zparse build               # zignapi build : compile l'addon + génère index.js/.d.ts
(cd packages/zparse && zig build test)   # tests unitaires Zig (lexer/parser/printer/…)
(cd packages/zparse && node --test)      # tests JS via l'addon

# Harnais corpus (6 modes ; les fichiers .jsx passent en mode JSX automatiquement) :
node playground/corpus.js [--roundtrip|--transform|--semantic|--mangle] <dir>...
node playground/corpus.js --recovery corpus/broken   # code cassé : N erreurs exactes, pas de crash
node playground/corpus.js --roundtrip corpus/jsx     # JSX (opt-in via l'extension .jsx)
node playground/corpus.js --jsx-transform corpus/jsx # JSX -> jsx()/jsxs() (React automatic runtime)
node playground/corpus.js --ts-strip corpus/ts       # TypeScript -> JS pur (efface les types)
node playground/corpus.js --tsx corpus/tsx           # .tsx -> JS pur (strip types + transform JSX)
```

Prérequis : Zig 0.16.0 et le repo [zignapi](../zignapi) cloné à côté et buildé une
fois. Détails d'architecture et journal des évolutions dans [CLAUDE.md](./CLAUDE.md).

## Roadmap

- **Split** en paquets `@zcompiler/*` (lexer, parser, semantic, printer…) — chaque
  passe est déjà découplée pour ça.
- **Early errors** complets, **strict mode**, **TDZ**, analyse de captures/closures.
- **Minifier** complet (le mangler + DCE en sont les fondations).
- Identifiants **Unicode** / échappements `\u{…}`, **error recovery**, **JSX**
  (parsing + transform), **TypeScript** (phases 1-3 : annotations, génériques d'appel,
  `.tsx`, émission enum/parameter-properties/namespace) : **faits**.
- **TypeScript** — restent hors périmètre : décorateurs, arrow générique en `.tsx`,
  const enum inliné, namespaces complexes. Et la vérification de types (tsc reste le juge).

## Ce que ça ne fait PAS (liste honnête)

Pas de strict mode, d'early errors sémantiques complets, pas les vraies tables
Unicode `ID_Start`/`ID_Continue` (on sur-accepte, cf. section Unicode), pas de
décodage `\u` dans les strings, pas de décorateurs ni de `using`. Le **JSX** est
*parsé* ET *transformé* (opt-in, `jsxTransform`) ; le mode **classic**, `__source`/
`__self`, et les **entités HTML** décodées, non. Le **TypeScript** est *parsé* et
*effacé/compilé* (opt-in, phases 1-3 : annotations, génériques, **enum**/parameter
properties/**namespace** émis, `stripTypes` → JS pur) mais **jamais vérifié** (tsc
reste le juge) ; restent décorateurs, arrow générique `.tsx`, const enum inliné.
L'**error recovery** est là (parse ne throw plus : AST partiel + `parseErrors`),
mais **sans messages « did you mean »** ni récupération dans le lexer (au-delà du
re-lex du préfixe propre). Voir la section « État du parser » de
[CLAUDE.md](./CLAUDE.md).
