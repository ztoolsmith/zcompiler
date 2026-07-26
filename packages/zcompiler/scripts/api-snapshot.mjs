// Dump a deterministic JSON snapshot of the WHOLE zcompiler API over a set of
// corpus files, for a given backend. The CI runs this twice — once on the
// native `index.js`, once on `wasm.js` — and diffs the two: byte-identical means
// the two backends produce the same results (tokenize/parseErrors/semantic +
// string returns AND exceptions). Two backends, one truth.
//
// Usage: node api-snapshot.mjs <addon.js> <dir> [<dir>...]
import { readFileSync, readdirSync } from "node:fs";
import { join, extname, relative, resolve } from "node:path";
import { createRequire } from "node:module";
import process from "node:process";

const require = createRequire(import.meta.url);
const [addonPath, ...dirs] = process.argv.slice(2);
if (!addonPath || dirs.length === 0) {
  process.stderr.write("usage: node api-snapshot.mjs <addon.js> <dir>...\n");
  process.exit(1);
}
const api = require(resolve(addonPath));

// Pick the right twin per extension so every grammar path is exercised.
function fnsFor(ext) {
  const suffix = ext === ".jsx" ? "Jsx" : ext === ".ts" ? "Ts" : ext === ".tsx" ? "Tsx" : "";
  const out = { tokenize: "tokenize", parseOnly: "parseOnly", transformCount: "transformCount" };
  for (const f of ["parse", "parseErrors", "print", "transform", "semantic", "mangle"]) out[f] = f + suffix;
  if (ext === ".jsx") out.jsxTransform = "jsxTransform";
  if (ext === ".ts") out.stripTypes = "stripTypes";
  if (ext === ".tsx") out.stripTypesTsx = "stripTypesTsx";
  return out;
}

function callSafe(name, src) {
  try {
    return { ok: true, v: api[name](src) };
  } catch (e) {
    return { ok: false, err: String((e && e.message) || e) };
  }
}

function walk(dir, acc) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.name.startsWith(".")) continue;
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p, acc);
    else if (/\.(js|mjs|jsx|ts|tsx)$/.test(e.name)) acc.push(p);
  }
  return acc;
}

const result = {};
for (const dir of dirs) {
  const base = resolve(dir);
  for (const file of walk(base, []).sort()) {
    const src = readFileSync(file, "utf8");
    const entry = {};
    for (const [key, name] of Object.entries(fnsFor(extname(file)))) entry[key] = callSafe(name, src);
    result[`${dir}/${relative(base, file)}`] = entry;
  }
}
process.stdout.write(JSON.stringify(result, null, 1));
