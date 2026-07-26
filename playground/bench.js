// Benchmark : zcompiler (zparse.parse) vs oxc-parser (parseSync) sur les MÊMES
// fichiers du corpus. Mesure des MB/s de source parsé + le ratio.
//
// Usage : node bench.js <dossier> [<dossier>...]
//   (oxc-parser doit être installé — cf. le chemin OXC_PATH ci-dessous.)
//
// HONNÊTETÉ : ce n'est PAS apples-to-apples. `zparse.parse` fait parse + rend
// l'AST en une STRING (debug-tree) ; `oxc.parseSync` fait parse + matérialise un
// graphe d'objets JS AND effectue les early errors + strict mode. oxc fait donc
// PLUS de travail. L'objectif : un ORDRE DE GRANDEUR, pas « gagner ». Même ordre
// = très bien ; 2-3× plus lent = normal et sain à ce stade.
const fs = require("node:fs");
const path = require("node:path");
const zparse = require("zcompiler");

// oxc-parser : `require` normal, sinon un chemin explicite via OXC_PATH (le
// protocole workspace: de pnpm empêche `npm i oxc-parser` dans playground/ ;
// installer ailleurs et pointer OXC_PATH=/chemin/vers/node_modules/oxc-parser).
let oxc;
try {
  oxc = require("oxc-parser");
} catch {
  try {
    oxc = require(process.env.OXC_PATH);
  } catch {
    console.error("oxc-parser introuvable. Installez-le puis : OXC_PATH=<...>/node_modules/oxc-parser node bench.js <dir>");
    process.exit(1);
  }
}

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
    else if (/\.(m?js)$/.test(e.name)) out.push(p);
  }
  return out;
}

const dirs = process.argv.slice(2);
if (dirs.length === 0) {
  console.error("usage: node bench.js <dossier> [<dossier>...]");
  process.exit(1);
}

// On ne garde que les fichiers que LES DEUX parsers acceptent (comparaison juste).
const files = [];
for (const f of dirs.flatMap(walk)) {
  let src;
  try {
    src = fs.readFileSync(f, "utf8");
  } catch {
    continue;
  }
  try {
    if (zparse.parseErrors(src).length > 0) continue; // zparse le parse proprement
    if (oxc.parseSync(f, src).errors.length > 0) continue;
  } catch {
    continue;
  }
  files.push({ src, bytes: Buffer.byteLength(src), name: f });
}

const N = 50;
const WARMUP = 5;

function timeRun(items, fn) {
  const t0 = process.hrtime.bigint();
  for (let i = 0; i < N; i++) for (const it of items) fn(it);
  return Number(process.hrtime.bigint() - t0) / 1e9; // secondes
}

function benchBucket(label, items) {
  if (items.length === 0) return;
  const totalBytes = items.reduce((s, it) => s + it.bytes, 0) * N;
  const mbps = (t) => (totalBytes / 1e6 / t).toFixed(1).padStart(6);
  // warmup
  for (let i = 0; i < WARMUP; i++) for (const it of items) {
    zparse.parseOnly(it.src);
    zparse.parse(it.src);
    oxc.parseSync(it.name, it.src);
  }
  const tpo = timeRun(items, (it) => zparse.parseOnly(it.src)); // parse pur
  const tp = timeRun(items, (it) => zparse.parse(it.src)); // parse + debug-tree
  const to = timeRun(items, (it) => oxc.parseSync(it.name, it.src)); // parse + AST JS
  const ratio = (tpo / to).toFixed(2); // parse-pur vs oxc
  console.log(
    `  ${label.padEnd(18)} ${String(items.length).padStart(4)} fic |  ` +
      `zparse parse-pur ${mbps(tpo)} MB/s  (+tree ${mbps(tp)})  |  oxc ${mbps(to)} MB/s  |  ` +
      `${ratio}× oxc`,
  );
}

const small = files.filter((f) => f.bytes < 5 * 1024);
const large = files.filter((f) => f.bytes > 20 * 1024);

console.log(`\nBenchmark parse : ${files.length} fichiers (acceptés par les deux), N=${N} + ${WARMUP} warmup`);
console.log("zparse.parse = parse + rendu debug-tree (string) ; oxc.parseSync = parse + AST JS + early errors.\n");
benchBucket("tous", files);
benchBucket("petits (<5 Ko)", small);
benchBucket("gros (>20 Ko)", large);
console.log("");
