// Harnais de test sur corpus : passe tous les .js/.mjs d'un dossier dans zparse
// et rapporte OK / échec, avec un classement des erreurs par fréquence.
//
// Usage :
//   node corpus.js <dossier> [<dossier>...]              # parse seul
//   node corpus.js --roundtrip <dossier> [<dossier>...]  # test round-trip
//   node corpus.js --transform <dossier> [<dossier>...]  # test transform
//   node corpus.js --semantic <dossier> [<dossier>...]   # analyse semantic
//   node corpus.js --mangle <dossier> [<dossier>...]     # renommage + vérifs
//   node corpus.js --recovery <dossier> [<dossier>...]   # error recovery (corpus cassé)
//   node corpus.js --jsx-transform corpus/jsx            # JSX → jsx()/jsxs() (React runtime)
//
// Round-trip : ast1 = parse(src) ; out = print(ast1) ; ast2 = parse(out) ;
// on compare les DEBUG-TREES de ast1 et ast2 (structure + textes, sans offsets).
// Une divergence = bug de parens du printer OU misparse latent révélé. Un crash
// à l'étape parse(out) = le printer a émis du JS invalide (catégorie à part).
//
// Transform : parse → transform → print → parse. L'AST a changé (c'est le but),
// donc on ne compare PAS ; on vérifie seulement que le résultat REPARSE sans
// erreur (zéro JS invalide émis). Bonus : total de nœuds foldés.
//
// Un fichier = un résultat (on ne s'arrête pas à la 1re erreur du run).
const zparse = require("zcompiler");
const fs = require("node:fs");
const path = require("node:path");

// Fichiers .js/.mjs, récursif, en sautant les node_modules imbriqués et les
// dossiers cachés. (Le dossier racine passé en argument est toujours exploré,
// même s'il est lui-même dans un node_modules.)
function walk(dir) {
  const out = [];
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    if (e.name === "node_modules" || e.name.startsWith(".")) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    // `.d.ts` = fichiers de DÉCLARATION (type-only, `declare …`) : ce n'est pas du
    // source exécutable, tous les bundlers les traitent à part -> on les saute.
    else if (/\.(m?js|jsx|tsx|ts)$/.test(e.name) && !/\.d\.ts$/.test(e.name)) out.push(p);
  }
  return out;
}

// Détection par EXTENSION (comme esbuild/oxc) : `.jsx` → `*Jsx`, `.ts` → `*Ts`,
// `.tsx` → `*Tsx` (JSX + TypeScript), `.js`/`.mjs` → fonctions normales. L'opt-in
// vit ici, dans le harnais.
function apiFor(file) {
  const j = file.endsWith(".jsx");
  const t = file.endsWith(".ts");
  const tx = file.endsWith(".tsx");
  if (tx)
    return {
      jsx: true,
      ts: true,
      parse: zparse.parseTsx,
      parseErrors: zparse.parseErrorsTsx,
      print: zparse.printTsx,
      transform: zparse.transformTsx,
      transformCount: null,
      semantic: zparse.semanticTsx,
      mangle: zparse.mangleTsx,
    };
  if (t)
    return {
      jsx: false,
      ts: true,
      parse: zparse.parseTs,
      parseErrors: zparse.parseErrorsTs,
      print: zparse.printTs,
      transform: zparse.transformTs,
      transformCount: null,
      semantic: zparse.semanticTs,
      mangle: zparse.mangleTs,
    };
  return {
    jsx: j,
    parse: j ? zparse.parseJsx : zparse.parse,
    parseErrors: j ? zparse.parseErrorsJsx : zparse.parseErrors,
    print: j ? zparse.printJsx : zparse.print,
    transform: j ? zparse.transformJsx : zparse.transform,
    transformCount: j ? null : zparse.transformCount,
    semantic: j ? zparse.semanticJsx : zparse.semantic,
    mangle: j ? zparse.mangleJsx : zparse.mangle,
  };
}

function lineCol(src, offset) {
  let line = 1;
  let col = 1;
  for (let i = 0; i < offset && i < src.length; i++) {
    if (src[i] === "\n") {
      line++;
      col = 1;
    } else col++;
  }
  return { line, col };
}

const offsetOf = (msg) => {
  const m = msg.match(/offset (\d+)/);
  return m ? Number(m[1]) : null;
};
// Message sans le préfixe ni l'offset, pour l'agrégation.
const normalize = (msg) =>
  msg.replace(/^zparse:\s*/, "").replace(/\s*\(offset \d+\)/, "").trim();
const oneLine = (s) => s.replace(/\n/g, "\\n").replace(/\t/g, "\\t");

const args = process.argv.slice(2);
const roundtrip = args.includes("--roundtrip");
const doTransform = args.includes("--transform");
const doSemantic = args.includes("--semantic");
const doMangle = args.includes("--mangle");
const doRecovery = args.includes("--recovery");
const doJsxTransform = args.includes("--jsx-transform");
const doTsStrip = args.includes("--ts-strip") || args.includes("--tsx"); // --tsx = alias (.tsx)
const FLAGS = new Set(["--roundtrip", "--transform", "--semantic", "--mangle", "--recovery", "--jsx-transform", "--ts-strip", "--tsx"]);
const dirs = args.filter((a) => !FLAGS.has(a));
if (dirs.length === 0) {
  console.error("usage: node corpus.js [--roundtrip|--transform|--semantic|--mangle] <dossier> [<dossier>...]");
  process.exit(1);
}
let totalFolds = 0;
// Semantic : agrégats globaux.
const semTotals = { scopes: 0, bindings: 0, resolved: 0, diagnostics: 0 };
const unresolvedFreq = new Map();
// Mangle : réduction de taille.
let mangleBytesBefore = 0;
let mangleBytesAfter = 0;

// Première ligne où deux arbres indentés divergent (1-indexée), ou null.
function firstDiff(a, b) {
  const la = a.split("\n");
  const lb = b.split("\n");
  const n = Math.max(la.length, lb.length);
  for (let i = 0; i < n; i++) {
    if (la[i] !== lb[i]) return { line: i + 1, a: la[i] ?? "∅", b: lb[i] ?? "∅" };
  }
  return null;
}

const files = dirs.flatMap(walk);
let ok = 0;
const failures = [];
const byMessage = new Map();
const t0 = process.hrtime.bigint();

for (const file of files) {
  let src;
  try {
    src = fs.readFileSync(file, "utf8");
  } catch {
    continue; // illisible : ignoré
  }
  if (doTsStrip) {
    tsStripFile(file, src);
  } else if (doJsxTransform) {
    jsxTransformFile(file, src);
  } else if (doRecovery) {
    recoveryFile(file, src);
  } else if (doMangle) {
    mangleFile(file, src);
  } else if (doSemantic) {
    semanticFile(file, src);
  } else if (doTransform) {
    transformFile(file, src);
  } else if (roundtrip) {
    roundtripFile(file, src);
  } else {
    // Parse : avec l'error recovery, parse() ne throw plus. Un fichier valide
    // a `parseErrors(src).length === 0`. `.jsx` -> variante JSX.
    let errs;
    try {
      errs = apiFor(file).parseErrors(src);
    } catch (err) {
      record(file, "parse a levé une erreur: " + normalize(err.message));
      continue;
    }
    if (errs.length === 0) {
      ok++;
    } else {
      const e = errs[0];
      const { line, col } = lineCol(src, e.offset);
      const around = oneLine(src.slice(Math.max(0, e.offset - 20), e.offset + 20));
      byMessage.set(e.message, (byMessage.get(e.message) || 0) + 1);
      failures.push({ file, msg: e.message, where: `${line}:${col}  …${around}…` });
    }
  }
}

function record(file, category, where) {
  byMessage.set(category, (byMessage.get(category) || 0) + 1);
  failures.push({ file, msg: category, where: where || "" });
}

// Corpus cassé : chaque fichier a un en-tête `// errors: N`. On vérifie que le
// parser récupère (N diagnostics EXACTEMENT), que le formateur imprime le code
// cassé sans crasher, et que le tout se termine (le garde-fou anti-boucle marche
// puisque le run complet ne timeout pas).
function recoveryFile(file, src) {
  const m = src.match(/\/\/\s*errors:\s*(\d+)/);
  if (!m) {
    record(file, "recovery: en-tête `// errors: N` manquant");
    return;
  }
  const expected = Number(m[1]);
  const api = apiFor(file);
  let errs;
  try {
    errs = api.parseErrors(src);
  } catch (err) {
    record(file, "recovery: parseErrors a crashé: " + normalize(err.message));
    return;
  }
  if (errs.length !== expected) {
    record(file, "recovery: nb d'erreurs inattendu", `attendu ${expected}, obtenu ${errs.length}`);
    return;
  }
  // Un formateur doit marcher sur du code cassé (print ne crashe pas + reparse).
  try {
    const out = api.print(src);
    api.parseErrors(out); // ne doit pas crasher
  } catch (err) {
    record(file, "recovery: print du code cassé a crashé: " + normalize(err.message));
    return;
  }
  ok++;
}

// TS strip : stripTypes(src) doit produire du JS PUR (plus AUCUN nœud ts), qui
// reparse EN MODE JS (ts OFF), passe le semantic sans diagnostic (aucun faux
// unresolved sur un nom de type), puis se mangle proprement (du TS entre, du JS
// minifié sort). Le juge de paix du chantier TypeScript.
function tsStripFile(file, src) {
  const isTsx = file.endsWith(".tsx");
  let out;
  try {
    // `.tsx` : efface les types (JSX conservé) PUIS lower le JSX -> JS pur.
    // `.ts` : efface les types -> JS pur directement.
    out = isTsx ? zparse.jsxTransform(zparse.stripTypesTsx(src)) : zparse.stripTypes(src);
  } catch (err) {
    record(file, "ts-strip a levé une erreur: " + normalize(err.message));
    return;
  }
  // 1. sortie = JS PUR : reparse EN MODE JS (ts off) sans erreur, zéro nœud ts/jsx.
  let errs;
  try {
    errs = zparse.parseErrors(out);
  } catch (err) {
    record(file, "ts-strip: sortie illexable: " + normalize(err.message));
    return;
  }
  if (errs.length) {
    record(file, "ts-strip: la sortie ne reparse pas (JS pur)", errs[0].message);
    return;
  }
  const tree = zparse.parse(out);
  if (/\bTs[A-Z]/.test(tree) || /JSX(Element|Fragment|Text)/.test(tree)) {
    record(file, "ts-strip: nœud TS/JSX résiduel dans la sortie");
    return;
  }
  // 2. semantic : zéro diagnostic (les noms de types ne fuient pas en unresolved).
  const sem = zparse.semantic(out);
  if (sem.diagnostics.length) {
    record(file, "ts-strip: diagnostic semantic", sem.diagnostics.slice(0, 2).join(" | "));
    return;
  }
  // 3. chaîné mangle : du TS entre, du JS minifié sort, reparse + re-semantic OK.
  try {
    const m = zparse.mangle(out);
    if (zparse.parseErrors(m).length || zparse.semantic(m).diagnostics.length) {
      record(file, "ts-strip+mangle: résultat invalide");
      return;
    }
  } catch (err) {
    record(file, "ts-strip+mangle a échoué: " + normalize(err.message));
    return;
  }
  ok++;
}

// JSX transform (automatic runtime) : jsxTransform(src) doit produire du JS PUR
// (plus AUCUN nœud JSX), qui reparse (jsx OFF), passe le semantic sans diagnostic
// (les refs App/xs + le helper importé `jsx` restent résolus), puis se mangle
// proprement (le pipeline complet parse → transform → mangle → print sur du React).
function jsxTransformFile(file, src) {
  let out;
  try {
    out = zparse.jsxTransform(src);
  } catch (err) {
    record(file, "jsx-transform a levé une erreur: " + normalize(err.message));
    return;
  }
  // 1. sortie = JS PUR : reparse (jsx OFF) sans erreur ET zéro nœud JSX résiduel.
  let errs;
  try {
    errs = zparse.parseErrors(out);
  } catch (err) {
    record(file, "jsx-transform: sortie illexable: " + normalize(err.message));
    return;
  }
  if (errs.length) {
    record(file, "jsx-transform: la sortie ne reparse pas (JS pur)", errs[0].message);
    return;
  }
  if (/JSX(Element|Fragment|Text|ExpressionContainer|Attribute)/.test(zparse.parse(out))) {
    record(file, "jsx-transform: nœud JSX résiduel dans la sortie");
    return;
  }
  // 2. semantic : zéro diagnostic (refs toujours résolues).
  const sem = zparse.semantic(out);
  if (sem.diagnostics.length) {
    record(file, "jsx-transform: diagnostic semantic", sem.diagnostics.slice(0, 2).join(" | "));
    return;
  }
  // 3. chaîné mangle : parse → transform → mangle → print, reparse + re-semantic OK.
  try {
    const m = zparse.mangle(out);
    if (zparse.parseErrors(m).length || zparse.semantic(m).diagnostics.length) {
      record(file, "jsx-transform+mangle: résultat invalide");
      return;
    }
  } catch (err) {
    record(file, "jsx-transform+mangle a échoué: " + normalize(err.message));
    return;
  }
  ok++;
}

function mangleFile(file, src) {
  const api = apiFor(file);
  let before;
  try {
    before = api.semantic(src);
  } catch (err) {
    record(file, "mangle: parse(src) a échoué: " + normalize(err.message));
    return;
  }
  let out;
  try {
    out = api.mangle(src);
  } catch (err) {
    record(file, "mangle a levé une erreur: " + normalize(err.message));
    return;
  }
  let after;
  try {
    after = api.semantic(out); // reparse + re-semantic du résultat
  } catch (err) {
    record(file, "mangle a produit du JS invalide: " + normalize(err.message));
    return;
  }
  // (b) zéro diagnostic ; (c) mêmes bindings/références ; (d) unresolved IDENTIQUES.
  if (after.diagnostics.length > 0) {
    record(file, "mangle: diagnostic sur le résultat", after.diagnostics.slice(0, 2).join(" | "));
    return;
  }
  if (before.bindings !== after.bindings || before.resolved !== after.resolved) {
    record(file, "mangle: bindings/refs changés", `${before.bindings}/${before.resolved} → ${after.bindings}/${after.resolved}`);
    return;
  }
  const ub = [...before.unresolved].sort().join(",");
  const ua = [...after.unresolved].sort().join(",");
  if (ub !== ua) {
    record(file, "mangle: unresolved changés (global capturé !)", `${ub} → ${ua}`);
    return;
  }
  // Réduction = mangle vs print NON-manglé (même pretty-printer : isole le gain
  // du renommage, pas le reformatage).
  try {
    mangleBytesBefore += Buffer.byteLength(api.print(src));
    mangleBytesAfter += Buffer.byteLength(out);
  } catch {
    /* stat best-effort */
  }
  ok++;
}

function semanticFile(file, src) {
  let r;
  try {
    r = apiFor(file).semantic(src);
  } catch (err) {
    record(file, "semantic a levé une erreur: " + normalize(err.message));
    return;
  }
  semTotals.scopes += r.scopes;
  semTotals.bindings += r.bindings;
  semTotals.resolved += r.resolved;
  semTotals.diagnostics += r.diagnostics.length;
  for (const u of r.unresolved) unresolvedFreq.set(u, (unresolvedFreq.get(u) || 0) + 1);
  // Un diagnostic sur du vrai code = un bug de NOS règles.
  if (r.diagnostics.length > 0) {
    record(file, "diagnostic semantic (bug de règles ?)", r.diagnostics.slice(0, 2).join(" | "));
    return;
  }
  ok++;
}

function transformFile(file, src) {
  const api = apiFor(file);
  let out;
  try {
    out = api.transform(src);
  } catch (err) {
    record(file, "transform a levé une erreur: " + normalize(err.message));
    return;
  }
  // L'AST a changé : on vérifie seulement que le résultat REPARSE.
  try {
    api.parse(out);
  } catch (err) {
    record(file, "transform a produit du JS invalide: " + normalize(err.message));
    return;
  }
  if (api.transformCount) {
    try {
      totalFolds += api.transformCount(src);
    } catch {
      /* stat best-effort */
    }
  }
  ok++;
}

function roundtripFile(file, src) {
  const api = apiFor(file);
  let tree1;
  try {
    tree1 = api.parse(src);
  } catch (err) {
    record(file, "parse(src) a échoué: " + normalize(err.message));
    return;
  }
  let out;
  try {
    out = api.print(src);
  } catch (err) {
    record(file, "print a levé une erreur: " + normalize(err.message));
    return;
  }
  let tree2;
  try {
    tree2 = api.parse(out);
  } catch (err) {
    // Le printer a produit du JS que le parser refuse.
    record(file, "print a produit du JS invalide: " + normalize(err.message));
    return;
  }
  if (tree1 === tree2) {
    ok++;
    return;
  }
  const d = firstDiff(tree1, tree2);
  const where = d ? `arbre L${d.line}: «${d.a.trim()}» ≠ «${d.b.trim()}»` : "?";
  record(file, "AST diverge (parens/misparse)", where);
}
const ms = Number(process.hrtime.bigint() - t0) / 1e6;

const pct = files.length ? ((100 * ok) / files.length).toFixed(1) : "0";
const verb = doTsStrip
  ? "ts-strip OK (JS pur, 0 nœud TS, semantic + mangle OK)"
  : doJsxTransform
  ? "jsx-transform OK (JS pur, 0 nœud JSX, semantic + mangle OK)"
  : doRecovery
  ? "recovery OK (N erreurs exactes, print sans crash)"
  : doMangle
  ? "mangle OK (reparse + invariants)"
  : doSemantic
    ? "semantic OK (0 diag)"
    : doTransform
      ? "transform OK (reparse)"
      : roundtrip
        ? "round-trip OK"
        : "parsés";
console.log(`\n${ok}/${files.length} fichiers ${verb} (${pct}%) en ${ms.toFixed(0)} ms`);
if (doTransform) console.log(`  ${totalFolds} nœuds foldés/simplifiés au total`);
if (doMangle && mangleBytesBefore > 0) {
  const red = (100 * (1 - mangleBytesAfter / mangleBytesBefore)).toFixed(1);
  console.log(`  taille : ${mangleBytesBefore} → ${mangleBytesAfter} o (−${red}% via renommage, vs print non-manglé)`);
}
if (doSemantic) {
  console.log(
    `  scopes:${semTotals.scopes}  bindings:${semTotals.bindings}  résolus:${semTotals.resolved}  diagnostics:${semTotals.diagnostics}`,
  );
  const top = [...unresolvedFreq.entries()].sort((a, b) => b[1] - a[1]).slice(0, 15);
  console.log(`  top unresolved (globals attendus) : ${top.map(([n, c]) => `${n}·${c}`).join("  ")}`);
}
console.log("");

if (failures.length) {
  console.log("── Erreurs par fréquence ──");
  for (const [msg, count] of [...byMessage.entries()].sort((a, b) => b[1] - a[1])) {
    console.log(`  ${String(count).padStart(4)}  ${msg}`);
  }
  console.log("\n── Détail (jusqu'à 25 échecs) ──");
  const root = dirs[0];
  for (const f of failures.slice(0, 25)) {
    console.log(`  ${path.relative(root, f.file)}`);
    console.log(`      ${f.msg}${f.where ? "  @ " + f.where : ""}`);
  }
  if (failures.length > 25) console.log(`  … et ${failures.length - 25} autres échecs`);
  // Sortie non-nulle sur échec : rend le harnais utilisable comme gate en CI.
  process.exitCode = 1;
}
