# Changelog

Toutes les modifications notables de zcompiler. Format inspiré de
[Keep a Changelog](https://keepachangelog.com/fr/1.1.0/) ; versionnage
[SemVer](https://semver.org/lang/fr/).

## [0.3.0] — 2026-07-26

La release **« le compilateur au service d'un linker »**. zbundle v0.2 fusionne
N modules dans un seul scope ; pour ça il lui faut savoir, de chaque module, quel
BINDING se cache derrière chaque nom importé/exporté, puis pouvoir **imposer sa
propre table de noms**. Rien de tout ça n'a été écrit chez le consommateur.

### Ajouté

- **`semantic.moduleInfo(arena, program, source, sem)`** — la table de liaison
  d'un module : `imports` (`{ local, binding, specifier, kind, imported }`),
  `exports` (`{ exported, kind, binding | value, specifier, imported }`),
  `star_exports`, le scope module, et deux drapeaux (`has_top_level_await`,
  `has_import_meta`). Équivalent du `ModuleRecord` d'oxc.
  `moduleRecords` répondait « **de quoi ce fichier dépend-il ?** » — assez pour
  tracer un graphe. `moduleInfo` répond « **qu'est-ce qui est lié à quoi ?** » —
  ce qu'il faut pour lier. Les deux coexistent : la première est bien plus légère.
  `export default <identifiant lié>` est classé `.local` (pas `.default_expr`) :
  un consommateur n'a pas à fabriquer un `const x = x` inutile.
- **`mangler.applyRenames(sem)`** — extrait du corps de `mangle`. Écrit sur l'AST
  les noms posés dans `binding.new_name` (déclarations ET références, via
  `node_binding`). La **génération** des noms reste au mangler ; l'**application**
  est désormais partagée, donc un consommateur peut poser sa propre table — par
  exemple un bundler qui résout des collisions cross-module. Idempotent.
- **`printer.printStatement`** / **`printer.printExpression`** — imprimer UN
  nœud, pas un programme entier. Nécessaire à qui **recompose** un programme :
  un bundler choisit statement par statement ce qu'il garde (les `import`
  disparaissent, `export const x` perd son mot-clé, `export default <expr>` se
  lie à un nom fabriqué).
- **`Binding.assigned`** — le binding est-il **réassigné** quelque part
  (`x = …`, `x++`, `x += …`) ? Distinct de « référencé » : c'est une ÉCRITURE.
  Renseigné par le chemin qui vérifiait déjà les `const`. Sert à repérer les
  **live bindings**.

### Corrigé

- **Le nom d'une expression de classe nommée n'était lié nulle part.** Dans
  `const C = class Bar { m() { return Bar; } }`, `Bar` partait en `unresolved` —
  alors que l'équivalent pour les fonctions (`const f = function foo() { … foo … }`)
  était géré depuis toujours. Désormais le nom est déclaré **dans le corps de la
  classe**, et nulle part ailleurs (`Bar` reste `unresolved` à l'extérieur, ce
  qui est correct). Trouvé par zbundle, dont le contrôle « aucun nom interne ne
  fuit » signalait un faux positif sur du code parfaitement sain.

### Compatibilité

Aucune rupture : que des ajouts. `mangle` se comporte exactement comme avant
(il appelle simplement la fonction extraite). Le seul changement observable est
la correction ci-dessus — un `unresolved` de moins, jamais un de plus.

**Vérifications** : 213 tests Zig, 79 tests Node, corpus **683/683** sur les 5
modes, recovery 22/22, ts-strip 26/26, tsx 8/8, jsx-transform 13/13, snapshot API
natif vs wasm byte-identique. Et, côté consommateur, le juge de zbundle : **12/12
bundles qui s'exécutent et disent exactement ce que dit le projet d'origine**,
lodash-es (172 modules) inclus.

## [0.2.0] — 2026-07-26

La release du **premier retour de la règle d'or** : zbundle, le premier
consommateur externe de zcompiler, a rencontré deux syntaxes ESM que le parser
ne lisait pas. Elles se corrigent **ici**, dans le compilateur — pas chez le
consommateur. Deux trous, un numéro de version.

### Ajouté

- **`export * as ns from './x'`** (ES2020) — le re-export d'un namespace, très
  courant dans les fichiers « barrel ». `ExportAll` gagne `exported: ?*Node`
  (null = la forme nue `export * from`). Le nom peut être un mot-clé
  (`export * as default from './x'` est légal).
  - **Sémantique** : `ns` n'est **pas** un binding local du module — c'est un
    nom d'export, exactement comme le `b` de `export { a as b }`. Il n'apparaît
    donc ni dans les bindings, ni dans les `unresolved`. (À ne pas confondre
    avec `import * as ns`, qui LUI crée un binding référençable.)
  - **`moduleRecords`** : nouveau kind **`export_all_as`** (opération différente
    de `export_all` : ça ne re-exporte pas les noms de la cible, ça crée UN
    export nommé qui vaut l'objet namespace) + le champ **`name`**.

- **Import attributes** `with { type: 'json' }` (ES2025) — la syntaxe qui
  permettra de router les assets vers le bon loader. Acceptée partout où la
  grammaire l'autorise : `import … from`, `import` de side-effect
  (`import './a.css' with { type: 'css' }`), `export … from`, `export * from`
  et `export * as ns from`.
  - AST : `Attributes { entries: []*Node, deprecated_assert: bool }` sur les
    quatre nœuds concernés ; chaque entrée est un nœud `import_attribute`
    `{ key, value }`. La clé est un identifiant ou une string ; la valeur est
    **obligatoirement** une string (spec) — sinon un diagnostic clair.
  - **`assert { … }`** (l'ancien mot-clé des « import assertions ») est
    **accepté** comme alias déprécié — il traîne dans du code réel, le refuser
    n'apporte rien (même choix qu'esbuild). Il est **préservé** à l'impression :
    un formateur ne réécrit pas la syntaxe de l'utilisateur dans son dos.
  - **`moduleRecords`** expose `attributes: []ImportAttribute { key, value }`,
    clés et valeurs **décodées**.

- **`import(source, options)`** — le 2ᵉ argument de l'import dynamique (ES2025)
  était une **erreur de parse** ; il est désormais lu et conservé
  (`ImportExpression.options`). C'est une **expression quelconque** que la
  grammaire ne contraint pas (contrairement au `with { … }` statique) : à ce
  titre `moduleRecords` n'en déduit **aucun** attribut, plutôt que d'en deviner.

- **Corpus `corpus/esm/`** (4 fichiers) : barrels, attributs sur toutes les
  formes, `assert` déprécié, non-régression `with`/`assert` comme identifiants
  ordinaires. Plus 3 fichiers de recovery dans `corpus/broken/`. Câblés en CI.

### Corrigé

- Le printer perdait la clause `with { … }` sur l'**import de side-effect**
  (`import './a.css' with { type: 'css' }`) — sortie anticipée avant l'émission
  des attributs. Trouvé par le round-trip, avant même la première exécution.
- **Récupération fine sur un attribut invalide** (la 4ᵉ, cf. la section « Error
  recovery » du CLAUDE.md) : une valeur non-string produit désormais **une**
  erreur claire au lieu de trois — on saute jusqu'au `}` de la clause plutôt que
  de dérouler jusqu'à la frontière de statement, qui laissait `}` et `;` générer
  deux diagnostics parasites derrière le vrai.

### Interne

Ces changements étaient dans l'arbre depuis le chantier zbundle mais n'avaient
jamais eu leur release — ils sortent avec la 0.2.0 :

- **`native/root.zig` + `b.addModule("zcompiler", …)`** — zcompiler est
  désormais une **bibliothèque Zig consommable** (`@import("zcompiler")`), pas
  seulement un addon. Un seul module racine qui réexporte les namespaces
  (ast/lexer/parser/printer/walker/semantic/transformer/mangler/jsx_transform) :
  en Zig, N `addModule` sur des fichiers qui s'importent par chemin relatif
  donneraient N instanciations d'`ast.zig`, donc des types incompatibles.
- **`semantic.moduleRecords(arena, program, source)`** — les dépendances de
  module d'un AST, dans l'ordre du source, specifiers décodés. La capacité qui
  manquait pour lire les imports depuis l'extérieur.
- `build.zig.zon` : `.name` `.zparse` → **`.zcompiler`** (le nom du paquet Zig
  était resté à l'ancien nom du projet ; le fingerprint en dérive et a été
  regénéré).

### Compatibilité

Aucune rupture. Les champs ajoutés à l'AST ont tous une valeur par défaut ; du
code qui ne connaît pas les nouvelles syntaxes se comporte exactement comme en
0.1.0. La surface JS gagne des possibilités, n'en retire aucune.

**Vérifications** : 203 tests Zig, 79 tests Node, corpus **683/683** sur les 5
modes (parse / round-trip / transform / semantic / mangle), recovery **22/22**,
ts-strip 26/26, tsx 8/8, jsx-transform 13/13, et le **snapshot API natif vs wasm
byte-identique**.

## [0.1.0] — 2026-07-25

La **fondatrice** : tout le compilateur, d'un coup.

Lexer (spans en bytes, templates, regex contextuelles, Unicode + échappements
`\u`, ASI), parser récursif-descendant + Pratt **feature-complete ES**, AST
ESTree-like, **error recovery** (panic mode + synchronisation — `parse` rend
toujours un AST + des diagnostics), **printer** (round-trip sémantique garanti),
**transformer** (constant folding, simplification booléenne, DCE scope-aware),
**semantic** (scopes/bindings/résolution), **mangler** (renommage des locaux,
−12,6 %), **JSX** (parsing + transform automatic-runtime `jsx()/jsxs()`) et
**TypeScript** (annotations, types, génériques d'appel, `.tsx`, et l'émission
enum / parameter properties / namespace).

Deux backends, une vérité : natif (N-API via zignapi) et **wasm**, dont le
snapshot API est byte-identique. 6 triples publiés.

[0.3.0]: https://github.com/ztoolsmith/zcompiler/releases/tag/v0.3.0
[0.2.0]: https://github.com/ztoolsmith/zcompiler/releases/tag/v0.2.0
[0.1.0]: https://github.com/ztoolsmith/zcompiler/releases/tag/v0.1.0
