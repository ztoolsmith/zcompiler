// Bac à sable pour tester le parser zparse à la main : affiche l'AST en arbre
// indenté + le temps de parsing.
//
// Usage :
//   node index.js                          # exemples intégrés
//   node index.js "a | b & c"              # parse l'argument
//
// Prérequis : zparse buildé (pnpm --filter zparse build).
const zparse = require("zcompiler");

const samples =
  process.argv.length > 2
    ? [process.argv.slice(2).join(" ")]
    : [
        "const flags = { a: true, b: false, c: null, d: undefined };",
        "const n = 0xFF + 0b101 + 1_000_000 + 2.5e-7;",
        "if (a & mask == flag || x >> 2 instanceof Y) {}",
        "for (const key in obj) delete obj[key];",
        "export { internal as default, helper };",
        "arr.map(x => x * 2,).filter(Boolean,)", // trailing commas
        "const re = /^\\s*(\\d+)\\/(\\d+)\\s*$/gi;", // regex vs division
        "for (let i = 0, j = n - 1; i < j; i++, j--) swap(a, i, j);", // séquence
        "async function load(url) { const r = await fetch(url); return await r.json(); }", // async/await
        "function* range(n) { for (let i = 0; i < n; i++) yield i; }", // generator
        "const dir = import.meta.dirname;", // meta-property
        "const a = 1\nconst b = 2\nprint(a + b)", // ASI (aucun ;)
        "fetch(u)\n  .then(r => r.json())\n  .catch(e => log(e))", // ASI + .catch (mot réservé)
        "cache ??= new Map(); total &&= total * 2;", // logical assignments
        "const big = 2n ** 64n;", // bigint
        "const api = { get size() { return n }, async load() {}, [key]() {} };", // méthodes d'objet
        "class Stream extends Base { constructor() { super() } async *chunks() { yield await this.next() } }", // super + async generator méthode
        "const ROTATE = 5 * 60 * 1000; if (true) log(1 + 2 * 3); else dead();", // transform : fold + simplif booléenne
        "function café(变数) { let \\u0041 = 变数 * 2; return A; }", // unicode + échappement \\u (mangle : café garde, 变数/A -> a/b)
        "let a = 1; let b = ; let c = 3;", // error recovery : b cassé, a et c intacts
      ];

function run(input) {
  console.log(`\ninput: ${JSON.stringify(input)}`);
  const t0 = process.hrtime.bigint();
  let out;
  try {
    out = zparse.parse(input);
  } catch (err) {
    const us = Number(process.hrtime.bigint() - t0) / 1000;
    console.log(`  ⚠ ${err.message}  (${us.toFixed(1)} µs)`);
    return;
  }
  const us = Number(process.hrtime.bigint() - t0) / 1000;
  console.log(
    out
      .split("\n")
      .filter(Boolean)
      .map((l) => "  " + l)
      .join("\n"),
  );
  console.log(`  → parsé en ${us.toFixed(1)} µs`);

  // Error recovery : parse() ne throw plus, les diagnostics se lisent à part.
  const errs = zparse.parseErrors(input);
  if (errs.length) {
    console.log(`  ⚠ ${errs.length} erreur(s) (AST partiel récupéré) :`);
    for (const e of errs) console.log(`    - ${e.message} @${e.offset}`);
  }

  // Codegen : réémet du JS valide + vérifie l'invariant round-trip.
  try {
    const printed = zparse.print(input);
    const rt = zparse.parse(printed) === out ? "✓ round-trip" : "✗ DIVERGE";
    console.log("  print:");
    console.log(
      printed
        .split("\n")
        .filter(Boolean)
        .map((l) => "    " + l)
        .join("\n"),
    );
    console.log(`  → ${rt}`);

    // Transform : montre le résultat s'il y a eu au moins un changement.
    const folds = zparse.transformCount(input);
    if (folds > 0) {
      const transformed = zparse.transform(input);
      console.log(`  transform (${folds} nœud(s) foldé(s)/supprimé(s)):`);
      console.log(
        transformed
          .split("\n")
          .filter(Boolean)
          .map((l) => "    " + l)
          .join("\n"),
      );
    }

    // Semantic : scopes / bindings / résolution.
    const sem = zparse.semantic(input);
    const diag = sem.diagnostics.length ? `  ⚠ ${sem.diagnostics.join("; ")}` : "";
    console.log(
      `  semantic: ${sem.scopes} scopes, ${sem.bindings} bindings, ${sem.resolved} réfs résolues` +
        (sem.unresolved.length ? `, unresolved: [${sem.unresolved.join(", ")}]` : "") +
        diag,
    );

    // Mangle : renommage des locaux (montré s'il change quelque chose).
    const mangled = zparse.mangle(input);
    if (mangled !== printed) {
      console.log("  mangle (renommage des locaux):");
      console.log(
        mangled
          .split("\n")
          .filter(Boolean)
          .map((l) => "    " + l)
          .join("\n"),
      );
    }
  } catch (err) {
    console.log(`  print ⚠ ${err.message}`);
  }
}

for (const input of samples) run(input);
