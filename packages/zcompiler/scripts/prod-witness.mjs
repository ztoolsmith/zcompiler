// Automated dress rehearsal for publishing: `npm pack` the main package + the
// host's per-platform package into an EMPTY witness, then prove both backends
// resolve and run through the published `exports` map:
//   - Node condition       → index.js → bindings.js → the native platform package
//   - browser condition     → wasm.js (self-contained), via Node --conditions=browser
//     (the same package-`exports` resolution a bundler applies — no bundler dep)
// This is the "prod simulée" the release workflow runs before uploading artifacts.
//
// Run from the package dir (packages/zcompiler) AFTER `zignapi build` +
// `zignapi build --target wasm` + `zignapi build --target <host-triple>`.
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import process from "node:process";

const PKG = process.cwd();

// The napi-rs triple of the host (must match a built npm/<triple>/).
function currentTriple() {
  const a = process.arch;
  if (process.platform === "darwin") return `darwin-${a}`;
  if (process.platform === "win32") return `win32-${a}-msvc`;
  if (process.platform === "linux") {
    const rep = process.report.getReport();
    const libc = rep.header?.glibcVersionRuntime ? "gnu" : "musl";
    return `linux-${a}-${libc}`;
  }
  return `${process.platform}-${a}`;
}

function pack(dir, dest) {
  const out = execFileSync("npm", ["pack", "--pack-destination", dest], { cwd: dir, encoding: "utf8" });
  return join(dest, out.trim().split("\n").pop());
}

function extractInto(tgz, targetDir) {
  mkdirSync(targetDir, { recursive: true });
  const tmp = mkdtempSync(join(tmpdir(), "x-"));
  execFileSync("tar", ["-xzf", tgz, "-C", tmp]);
  // npm tarballs wrap everything in `package/`.
  execFileSync("cp", ["-R", join(tmp, "package") + "/.", targetDir]);
  rmSync(tmp, { recursive: true, force: true });
}

const triple = currentTriple();
const platformDir = join(PKG, "npm", triple);
if (!readdirSync(join(PKG, "npm")).includes(triple)) {
  throw new Error(`no npm/${triple}/ — run \`zignapi build --target ${triple}\` first`);
}

const witness = mkdtempSync(join(tmpdir(), "zc-witness-"));
const nm = join(witness, "node_modules");
const scope = join(nm, "@zcompiler");
mkdirSync(scope, { recursive: true });

const mainTgz = pack(PKG, witness);
const platTgz = pack(platformDir, witness);
extractInto(mainTgz, join(nm, "zcompiler"));
extractInto(platTgz, join(scope, `binding-${triple}`));

const SRC = "const x = 1 + 1;";
const EXPECT = "const x = 1 + 1;\n"; // print(SRC)

// 1. Node condition → native platform package.
const nodeOut = execFileSync(
  process.execPath,
  ["-e", `process.stdout.write(require("zcompiler").print(${JSON.stringify(SRC)}))`],
  { cwd: witness, encoding: "utf8" },
);
assert(nodeOut === EXPECT, `node/native print mismatch: ${JSON.stringify(nodeOut)}`);
process.stdout.write("✔ node condition → native (index.js → bindings.js → platform pkg)\n");

// 2. browser condition → wasm.js, resolved exactly like a bundler does. We use
// Node's OWN `--conditions=browser` (the same package-`exports` condition
// resolution esbuild/webpack/rollup apply) — dependency-free, so nothing to
// build or approve in CI. It proves `exports["."].browser` → wasm.js and that
// the self-contained wasm glue runs.
const browserOut = execFileSync(
  process.execPath,
  [
    "--conditions=browser",
    "--input-type=module",
    "-e",
    `import * as z from "zcompiler"; process.stdout.write((z.default ?? z).print(${JSON.stringify(SRC)}));`,
  ],
  { cwd: witness, encoding: "utf8" },
);
assert(browserOut === EXPECT, `browser/wasm print mismatch: ${JSON.stringify(browserOut)}`);
process.stdout.write("✔ browser condition (--conditions=browser) → wasm.js, runs\n");

rmSync(witness, { recursive: true, force: true });
process.stdout.write("✔ prod witness: both backends resolve + run through the exports map\n");

function assert(cond, msg) {
  if (!cond) {
    process.stderr.write("✗ " + msg + "\n");
    process.exit(1);
  }
}
