# zcompiler

A **JavaScript/TypeScript compiler written in Zig**, exposed to Node.js through
[zignapi](https://www.npmjs.com/package/zignapi) — with **two backends built from
the same source**: a native addon and a WebAssembly module.

Lexer, parser, AST, error recovery, semantic analysis, transformer, mangler,
printer — plus **JSX** and **TypeScript** as opt-in dialects.

```sh
npm install zcompiler
```

Node loads the native binary (`@zcompiler/binding-<triple>`, installed
automatically for your platform); a bundler targeting the browser picks up
`wasm.js` instead. Same API, same results — that equality is verified byte for
byte in CI.

## Quick start

```js
import z from "zcompiler";

z.parse(src);       // the AST, as an indented debug tree
z.parseErrors(src); // Array<{ message, offset }> — [] when the code is valid
z.tokenize(src);    // Array<{ kind, start, end }> — spans, zero copy
z.print(src);       // reparse -> re-emit normalized JS
z.transform(src);   // constant folding + boolean simplification + scope-aware DCE
z.semantic(src);    // { scopes, bindings, resolved, unresolved[], diagnostics[] }
z.mangle(src);      // rename local bindings to short names
```

**JSX** (opt-in, React dialect) — the `*Jsx` twins turn the JSX grammar on:

```js
z.parseJsx(src);    // <div/> is an expression
z.jsxTransform(src); // JSX -> jsx()/jsxs()/Fragment + automatic import
// also: parseErrorsJsx, printJsx, transformJsx, semanticJsx, mangleJsx
```

**TypeScript** (opt-in) — the `*Ts` / `*Tsx` twins, plus the eraser:

```js
z.parseTs(src);      // `let x: number` and `foo<T>(x)` are valid
z.stripTypes(src);   // ERASES the types -> plain JS (never type-checked: tsc stays the judge)
z.stripTypesTsx(src); // .tsx: JSX and TypeScript together
// also: parseErrorsTs, printTs, transformTs, semanticTs, mangleTs (+ *Tsx)
```

## How it works

```
          ┌─────────┐   ┌──────────┐   ┌─────────────────┐   ┌─────────┐
source ──▶│  parse  │──▶│ semantic │──▶│ transform /     │──▶│  print  │──▶ JS
          │  (AST)  │   │ (scopes) │   │ mangle  (AST')  │   │ (codegen)│
          └─────────┘   └──────────┘   └─────────────────┘   └─────────┘
```

Each pass lives in its own file and depends only on what it needs.

| Pass | File | Role |
|---|---|---|
| **lexer** | `native/lexer.zig` | tokens with **byte spans** (zero copy), maximal munch, templates, contextual regex, hashbang, `#private`, BigInt, Unicode identifiers |
| **parser** | `native/parser.zig` | recursive descent + Pratt; ESTree-like AST in an arena; cover grammar for destructuring |
| **ast** | `native/ast.zig` | nodes (tagged unions) + indented debug printer |
| **walker** | `native/walker.zig` | generic `walk(node, visitor)` traversal (enter/exit) — shared |
| **semantic** | `native/semantic.zig` | scopes / bindings / reference resolution + some early errors |
| **transformer** | `native/transformer.zig` | constant folding, boolean simplification, scope-aware DCE, `stripTypes` |
| **mangler** | `native/mangler.zig` | renames local bindings (the minifier's foundation) |
| **jsx_transform** | `native/jsx_transform.zig` | JSX → `jsx()/jsxs()` (React automatic runtime) + auto-import |
| **printer** | `native/printer.zig` | codegen: AST → valid JS (re-creates parentheses from precedence) |

Three design decisions carry most of the weight:

- **Spans are byte offsets into the source, and nodes hold no copied text.** A
  literal is printed by re-emitting its span. That is what makes the lexer zero
  copy, and it survives Unicode intact (`café` is 5 bytes, and the span says so).
- **`synthetic_text`** is the escape hatch for nodes that have *no* source span —
  the `7` produced by folding `1 + 2 * 3`, a mangled name, a decoded `\u` escape,
  a string literal fabricated by the JSX transform. `litText()` returns
  `synthetic_text orelse span`, and every consumer goes through it. One
  convention, reused by four different passes.
- **The parser never stops at the first error.** `parse` always returns an AST
  (partial if needed) plus a list of diagnostics: panic mode, synchronization at
  statement boundaries, `error_node` leaves where nothing could be parsed. The
  rest of the pipeline treats those as leaves, so a formatter or an LSP keeps
  working on broken code. The invariant: with zero errors the AST is
  **bit-identical** to what it was before recovery existed.

**JSX and TypeScript are opt-in for a real reason**: in plain JS `a < b` is a
comparison, and `foo<T>(x)` is two of them. The ambiguity cannot be resolved by
the lexer, so — like esbuild, oxc and tsc — the dialect is selected up front (by
file extension in practice), and generic *calls* are resolved by **speculative
lookahead** with a full rewind. With the flags off, behaviour is bit-identical to
plain JS by construction, not merely by testing.

## As a Zig library

zcompiler is also a Zig module. One `b.addModule("zcompiler", …)` pointing at
`native/root.zig`, which re-exports the namespaces:

```zig
const zc = @import("zcompiler");

const result = try zc.parser.parseWith(arena, source, false, false);
const records = try zc.semantic.moduleRecords(arena, result.program, source);
```

**One module, not one per file** — in Zig a file imported by relative path
belongs to the importer's module, so N modules would mean N instantiations of
`ast.zig` and mutually incompatible types.

The surface a linker or bundler needs:

| Function | What it gives you |
|---|---|
| `semantic.moduleRecords` | **what a module depends on** — specifiers (decoded), kind (`import` / `re_export` / `export_all` / `export_all_as` / `dynamic_import`), import attributes |
| `semantic.moduleInfo` | **what is bound to what** — imports with their local `*Binding`, exports (`.local` / `.default_expr` / `.re_export` / `.star_as`), star exports, top-level await, `import.meta` |
| `mangler.applyRenames` | apply an **external** rename table — how a cross-module linker resolves collisions |
| `printer.printStatement` / `printExpression` | re-compose a program one node at a time |
| `Binding.assigned` | write vs read — how you spot live bindings |

That surface exists because a consumer asked for it. The org's rule is that a
missing capability is added **here**, never worked around downstream —
[zbundle](https://www.npmjs.com/package/zbundle) is the consumer that drove it.

## What it can do (the numbers)

Test corpus: **684 real files** (lodash-es, nanoid, mitt, plus semicolon-less
"standard style" code from feross/mafintosh, plus our own source), a handmade
Unicode corpus, and a `broken/` corpus for recovery.

| Check | Result |
|---|---|
| **parse** | **684/684** — modern ES, with and without semicolons |
| **round-trip** `parse(print(parse(x))) ≡ parse(x)` | **684/684** — semantic fidelity |
| **transform** (fold + boolean + DCE) → reparse | **684/684**, zero invalid JS emitted |
| **semantic** (scopes/bindings) | **684/684, zero diagnostics**; unresolved = plausible globals |
| **mangle** + invariants | **684/684**; **−12.6 %** size (vs unmangled print) |
| **recovery** (broken code) | **22/22** — exact error counts, partial AST, print without crashing |
| **JSX** | 13/13 across 5 modes; plain JS unchanged (jsx off = bit-identical) |
| **JSX transform** (automatic runtime) | 13/13 — plain JS output (0 JSX nodes) |
| **TypeScript** (`.ts`) | 26/26 — annotations, generics, `enum`/parameter properties/`namespace` emission |
| **TypeScript** (`.tsx`) | 8/8 — `--tsx` → plain JS |
| **native vs wasm** | API snapshot **byte-identical** across both backends |

Parsing runs at ~21 MB/s, about **4× slower than
[oxc-parser](https://www.npmjs.com/package/oxc-parser)** (Rust, the fastest in the
ecosystem). Honest comparison: oxc does *more* — full early errors, strict mode, a
materialized AST. Same order of magnitude is the right place to be at this stage.

## What it does NOT do (the honest list)

No strict mode, no complete semantic early errors, no real Unicode
`ID_Start`/`ID_Continue` tables (it over-accepts), no `\u` decoding inside
strings, no decorators, no `using`.

**JSX** is parsed and transformed (automatic runtime); the **classic** mode
(`React.createElement`), `__source`/`__self` and decoded HTML entities are not.

**TypeScript** is parsed and erased/compiled, but **never type-checked** — tsc
stays the judge. Still out of scope: decorators, generic arrows in `.tsx`, inlined
`const enum`, complex namespaces.

**CommonJS**: zcompiler is ESM. `moduleRecords` reports no `require()` — a
`require('x')` is just a function call.

## Requirements

- **Node ≥ 18** to consume the npm package.
- **Zig 0.16.0** to build from source or to use it as a Zig library.

MIT.
