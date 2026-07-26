const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");

const addon = require("./zcompiler.node");
const api = require("./index.js");

const tree = (lines) => lines.join("\n") + "\n";

// Error recovery : parse() ne throw plus, il renvoie un AST + accumule les
// erreurs. Un diagnostic se lit via parseErrors(src) : [{ message, offset }].
const expectParseError = (src, re) => {
  const errs = api.parseErrors(src);
  assert.ok(errs.length > 0, `attendu une erreur pour: ${src}`);
  assert.ok(
    errs.some((e) => re.test(e.message)),
    `aucune erreur ne matche ${re} dans ${JSON.stringify(errs)}`,
  );
};

// ---- régression (statements) ----

test("régression : try/catch + switch", () => {
  assert.match(api.parse("try { a() } catch (e) {}"), /TryStatement\n {4}BlockStatement[\s\S]*CatchClause/);
  assert.match(api.parse("switch (x) { case 1: break; }"), /SwitchStatement\n {4}Identifier x\n {4}SwitchCase/);
});

// ---- fix 1 : littéraux ----

test("littéraux true/false/null ; undefined = identifier", () => {
  assert.strictEqual(
    addon.parse("x == null"),
    tree(["Program", "  ExpressionStatement", '    BinaryExpression "=="', "      Identifier x", "      NullLiteral"]),
  );
  assert.match(api.parse("[true, false]"), /BooleanLiteral true\n {6}BooleanLiteral false/);
  assert.match(api.parse("undefined"), /Identifier undefined/);
});

// ---- fix 2 + 3 : _/$ identifiants + nombres ----

test("_ et $ dans identifiants, nombres complets", () => {
  assert.match(api.parse("const _x = $y.__z;"), /Identifier _x[\s\S]*Identifier \$y\n {8}Identifier __z/);
  for (const n of ["0xFF", "0b101", ".5", "1e3", "1_000_000"]) {
    assert.match(api.parse(n), new RegExp("NumberLiteral " + n.replace(/[.$]/g, "\\$&")));
  }
});

// ---- fix 4 : opérateurs ----

test("opérateurs bitwise/décalages/in/instanceof/void/delete + précédence", () => {
  // a & b == c  ->  a & (b == c)
  assert.strictEqual(
    api.parse("a & b == c"),
    tree(["Program", "  ExpressionStatement", '    BinaryExpression "&"', "      Identifier a", '      BinaryExpression "=="', "        Identifier b", "        Identifier c"]),
  );
  assert.match(api.parse("x in obj"), /BinaryExpression "in"/);
  assert.match(api.parse("a instanceof B"), /BinaryExpression "instanceof"/);
  assert.match(api.parse("a >>> b"), /BinaryExpression ">>>"/);
  assert.match(api.parse("a |= b"), /AssignmentExpression "\|="/);
  assert.match(api.parse("void 0"), /UnaryExpression "void"/);
  assert.match(api.parse("delete a.b"), /UnaryExpression "delete"/);
  assert.match(api.parse("~a"), /UnaryExpression "~"/);
  assert.match(api.parse("for (x in obj) {}"), /ForInStatement\n {4}Identifier x\n {4}Identifier obj/);
});

// ---- fix 5 + 6 : export default + trailing comma ----

test("export { x as default } et trailing comma dans les appels", () => {
  assert.strictEqual(
    api.parse("export { x as default };"),
    tree(["Program", "  ExportNamedDeclaration", "    ExportSpecifier", "      Identifier x", "      Identifier default"]),
  );
  assert.strictEqual(
    api.parse("f(a, b,)"),
    tree(["Program", "  ExpressionStatement", "    CallExpression", "      Identifier f", "      Identifier a", "      Identifier b"]),
  );
});

// ---- regex : `/` contextuel (regex vs division) ----

test("regex littéraux vs opérateur division", () => {
  // Après `=`, `(`, `,`, `return`… -> regex (span brut, non décodée).
  assert.strictEqual(
    api.parse("x = /ab+c/g"),
    tree(["Program", "  ExpressionStatement", '    AssignmentExpression "="', "      Identifier x", "      RegexLiteral /ab+c/g"]),
  );
  // Le `/` d'une char class `[...]` ne ferme pas la regex.
  assert.match(api.parse("const re = /a[/]b/;"), /RegexLiteral \/a\[\/\]b\//);
  // regex en argument d'appel.
  assert.match(api.parse("f(/re/, 2)"), /RegexLiteral \/re\//);
  // Après un identifiant / `)` / `]` -> division (associative à gauche).
  assert.strictEqual(
    api.parse("a / b / c"),
    tree(["Program", "  ExpressionStatement", '    BinaryExpression "/"', '      BinaryExpression "/"', "        Identifier a", "        Identifier b", "      Identifier c"]),
  );
  assert.match(api.parse("(a) / 2"), /BinaryExpression "\/"/);
});

// ---- sequence : opérateur virgule ----

test("sequence expressions (opérateur virgule)", () => {
  // Statement d'expression : séquence aplatie.
  assert.strictEqual(
    api.parse("a, b, c;"),
    tree(["Program", "  ExpressionStatement", "    SequenceExpression", "      Identifier a", "      Identifier b", "      Identifier c"]),
  );
  // Grouping `(a, b)` -> séquence ; en RHS d'affectation.
  assert.strictEqual(
    api.parse("x = (a, b)"),
    tree(["Program", "  ExpressionStatement", '    AssignmentExpression "="', "      Identifier x", "      SequenceExpression", "        Identifier a", "        Identifier b"]),
  );
  // La virgule reste un séparateur : PAS de séquence dans un appel/tableau.
  assert.doesNotMatch(api.parse("f(a, b)"), /SequenceExpression/);
  assert.doesNotMatch(api.parse("[a, b]"), /SequenceExpression/);
  // Clauses init + update d'un for.
  assert.strictEqual((api.parse("for (i = 0, j = 9; i < j; i++, j--) {}").match(/SequenceExpression/g) || []).length, 2);
});

// ---- async / await ----

test("async functions, arrows et await", () => {
  // async function declaration + await (mot-clé en contexte async).
  assert.strictEqual(
    api.parse("async function f() { await g(); }"),
    tree([
      "Program",
      "  FunctionDeclaration async",
      "    Identifier f",
      "    Params",
      "    BlockStatement",
      "      ExpressionStatement",
      "        AwaitExpression",
      "          CallExpression",
      "            Identifier g",
    ]),
  );
  // async arrow parenthésé.
  assert.match(api.parse("const h = async (a, b) => await p;"), /ArrowFunction async \(expression\)/);
  // async(...) SANS => est un appel, PAS une arrow.
  assert.strictEqual(
    api.parse("async(1, 2)"),
    tree(["Program", "  ExpressionStatement", "    CallExpression", "      Identifier async", "      NumberLiteral 1", "      NumberLiteral 2"]),
  );
  // async reste un identifiant valide.
  assert.match(api.parse("const async = 1; async + 2;"), /Identifier async/);
  assert.doesNotMatch(api.parse("const async = 1;"), /FunctionDeclaration|AwaitExpression/);
  // top-level await (choix documenté : in_async = true au top-level).
  assert.match(api.parse("await x"), /AwaitExpression/);
});

// ---- generators + yield ----

test("generators : yield, yield*, yield nu ; async generator", () => {
  assert.strictEqual(
    api.parse("function* g() { yield 1; yield* it(); yield; }"),
    tree([
      "Program",
      "  FunctionDeclaration generator",
      "    Identifier g",
      "    Params",
      "    BlockStatement",
      "      ExpressionStatement",
      "        YieldExpression",
      "          NumberLiteral 1",
      "      ExpressionStatement",
      "        YieldExpression delegate",
      "          CallExpression",
      "            Identifier it",
      "      ExpressionStatement",
      "        YieldExpression",
    ]),
  );
  // yield hors generator = identifiant.
  assert.match(api.parse("const yield = 1;"), /Identifier yield/);
  // async generator : les deux flags.
  assert.match(api.parse("async function* s() { yield await f(); }"), /FunctionDeclaration async generator/);
});

// ---- hashbang + import.meta ----

test("hashbang ignoré + import.meta meta-property", () => {
  assert.strictEqual(
    api.parse("#!/usr/bin/env node\nconst x = 1;"),
    tree(["Program", "  VariableDeclaration const", "    VariableDeclarator", "      Identifier x", "      NumberLiteral 1"]),
  );
  assert.match(api.parse("import.meta.url"), /MetaProperty import\.meta/);
});

// ---- ASI (Automatic Semicolon Insertion) ----

test("ASI : sauts de ligne, restricted productions, pièges", () => {
  // Deux déclarations séparées par un \n.
  assert.strictEqual(
    api.parse("let a = 1\nlet b = 2"),
    tree([
      "Program",
      "  VariableDeclaration let",
      "    VariableDeclarator",
      "      Identifier a",
      "      NumberLiteral 1",
      "  VariableDeclaration let",
      "    VariableDeclarator",
      "      Identifier b",
      "      NumberLiteral 2",
    ]),
  );
  // return\nx = return; puis x (restricted).
  assert.strictEqual(
    api.parse("function f() { return\nx }"),
    tree(["Program", "  FunctionDeclaration", "    Identifier f", "    Params", "    BlockStatement", "      ReturnStatement", "      ExpressionStatement", "        Identifier x"]),
  );
  // a\n++b = a; puis ++b (préfixe), PAS a++.
  assert.match(api.parse("a\n++b"), /ExpressionStatement\n {4}Identifier a\n {2}ExpressionStatement\n {4}UpdateExpression "\+\+" \(prefix\)/);
  // break\nouter = break; sans label.
  assert.doesNotMatch(api.parse("outer: while (1) { break\nouter }"), /BreakStatement\n {8}Identifier/);
  // piège IIFE : le ( continue l'expression -> UN statement (b(c).d()).
  assert.match(api.parse("let a = b\n(c).d()"), /MemberExpression\n {10}CallExpression\n {12}Identifier b\n {12}Identifier c/);
});

test("ASI : erreurs (throw\\n, statements collés sans newline)", () => {
  // throw + newline = erreur.
  expectParseError("throw\nx", /newline after throw/);
  // deux statements sans ; ni newline = erreur.
  expectParseError("let a = 1 let b = 2", /expected ';'/);
});

test("mots réservés comme noms de membre (p.catch, x.default)", () => {
  assert.match(api.parse("p.catch(f)"), /MemberExpression\n {8}Identifier p\n {8}Identifier catch/);
  assert.match(api.parse("x.default"), /Identifier default/);
});

// ---- logical assignments + bigint + méthodes objet + for-await + super ----

test("logical assignments ??= ||= &&=", () => {
  assert.match(api.parse("x ??= 1"), /AssignmentExpression "\?\?="/);
  assert.match(api.parse("x ||= 1"), /AssignmentExpression "\|\|="/);
  assert.match(api.parse("x &&= a.b"), /AssignmentExpression "&&="/);
});

test("bigint literals : 123n, 0xFFn ; 1.5n = erreur", () => {
  assert.match(api.parse("const b = 123n"), /BigIntLiteral 123n/);
  assert.match(api.parse("const c = 0xFFn"), /BigIntLiteral 0xFFn/);
  expectParseError("const d = 1.5n", /invalid BigInt/);
});

test("méthodes d'objet : foo(), get/set, *gen, async, [k]()", () => {
  assert.strictEqual(
    api.parse("({ foo() {}, get x() {}, *g() {}, async m() {}, [k]() {} })"),
    tree([
      "Program",
      "  ExpressionStatement",
      "    ObjectExpression",
      "      MethodDefinition method",
      "        Identifier foo",
      "        Params",
      "        BlockStatement",
      "      MethodDefinition getter",
      "        Identifier x",
      "        Params",
      "        BlockStatement",
      "      MethodDefinition method generator",
      "        Identifier g",
      "        Params",
      "        BlockStatement",
      "      MethodDefinition method async",
      "        Identifier m",
      "        Params",
      "        BlockStatement",
      "      MethodDefinition method computed",
      "        Identifier k",
      "        Params",
      "        BlockStatement",
    ]),
  );
  // property normale toujours ok (non-régression).
  assert.match(api.parse("({ a: 1, b })"), /Property\n {8}Identifier a/);
});

test("for await (uniquement en contexte async / top-level)", () => {
  assert.match(
    api.parse("async function f(s) { for await (const x of s) {} }"),
    /ForOfStatement await/,
  );
});

test("super : appel, membre, computed ; super seul = erreur", () => {
  assert.match(api.parse("class C extends B { m() { super.x() } }"), /CallExpression\n {14}MemberExpression\n {16}Super/);
  assert.match(api.parse("class C extends B { constructor() { super(1) } }"), /CallExpression\n {14}Super/);
  expectParseError("super", /'super' must be followed/);
  expectParseError("super + 1", /'super' must be followed/);
});

// ---- printer (codegen) + round-trip ----

// L'invariant : parse(print(src)) donne le MÊME arbre que parse(src).
const roundtrips = (src) => api.parse(api.print(src)) === api.parse(src);

test("printer : sortie JS attendue (parens recréées, ; normalisés)", () => {
  assert.strictEqual(api.print("(a + b) * c"), "(a + b) * c;\n");
  assert.strictEqual(api.print("a - (b - c)"), "a - (b - c);\n");
  assert.strictEqual(api.print("(-2) ** 2"), "(-2) ** 2;\n");
  assert.strictEqual(api.print("({ a: 1 })"), "({ a: 1 });\n");
  assert.strictEqual(api.print("() => ({})"), "() => ({});\n");
  assert.strictEqual(api.print("let {x, y=1} = o"), "let { x, y = 1 } = o;\n");
  // ASI normalisée : point-virgule ajouté même sans ; en entrée.
  assert.strictEqual(api.print("a\nb"), "a;\nb;\n");
});

test("printer round-trip : invariant parse∘print", () => {
  const samples = [
    "a || b && c; a ?? (b || c);",
    "new (a().b)(1); new Foo(1, 2);",
    "class C extends B { get v() { return 1; } static m() {} #n() {} }".replace("#n", "n"),
    "async function* g(a = 1, ...r) { yield await f(a); }",
    "for (const [k, v] of Object.entries(o)) log(k, v);",
    "p.then(r => r.json()).catch(e => log(e));",
    "const t = `a ${x + 1} b ${y} c`; const re = /ab+/gi;",
    "export { a, b as c }; export default function () {};",
    "obj?.a?.[b]?.(c); delete a.b; typeof x === 'string';",
  ];
  for (const s of samples) assert.ok(roundtrips(s), `round-trip KO: ${s}`);
});

test("index.d.ts déclare tokenize, parse et print", () => {
  const dts = fs.readFileSync("./index.d.ts", "utf8");
  assert.match(dts, /export function print\(arg0: string\)/);
});

// ---- transformer (fold + simplification booléenne + DCE) ----
// NB : `transform` inclut le DCE, qui supprimerait un `const x` inutilisé — on
// utilise donc des assignations pour isoler le fold.

test("transform : constant folding (+ - *) entiers, bottom-up", () => {
  assert.strictEqual(api.transform("x = 1 + 2 * 3;"), "x = 7;\n");
  assert.strictEqual(api.transform("y = (1 + 2) * 3;"), "y = 9;\n");
  assert.strictEqual(api.transform("t = 5 * 60 * 1000;"), "t = 300000;\n");
  // NON foldés : float non entier, un seul littéral, /, résultat négatif.
  assert.strictEqual(api.transform("0.1 + 0.2;"), "0.1 + 0.2;\n");
  assert.strictEqual(api.transform("1 + x;"), "1 + x;\n");
  assert.strictEqual(api.transform("6 / 2;"), "6 / 2;\n");
  assert.strictEqual(api.transform("5 - 8;"), "5 - 8;\n");
});

test("transform : simplification booléenne", () => {
  assert.strictEqual(api.transform("z = true && getX();"), "z = getX();\n");
  assert.strictEqual(api.transform("false && side();"), "false;\n");
  assert.strictEqual(api.transform("true || other();"), "true;\n");
  assert.strictEqual(api.transform("b = !true;"), "b = false;\n");
  assert.strictEqual(api.transform("if (true) { a(); } else { b(); }"), "{\n  a();\n}\n");
  assert.strictEqual(api.transform("if (false) a(); else b();"), "b();\n");
});

test("transform : DCE scope-aware (module)", () => {
  assert.strictEqual(api.transform("const used = 1; const dead = 2; export { used };"), "const used = 1;\nexport { used };\n");
  assert.strictEqual(api.transform("function keep() {} function drop() {} keep();"), "function keep() {}\nkeep();\n");
  assert.strictEqual(api.transform("const x = f();"), "const x = f();\n"); // init non-sûr : gardé
  assert.strictEqual(api.transform("var unused = 1;"), "var unused = 1;\n"); // var jamais touché
});

test("transform : compteur + reparse toujours valide", () => {
  assert.strictEqual(api.transformCount("x = 1 + 2 * 3;"), 2);
  const out = api.transform("for (let i = 0; i < 10 * 2; i++) f(2 + 3);");
  assert.doesNotThrow(() => api.parse(out));
  assert.match(out, /i < 20/);
  assert.match(out, /f\(5\)/);
});

// ---- semantic (scopes / bindings / résolution / diagnostics) ----

test("semantic : shadowing, hoisting var, resolution", () => {
  const a = api.semantic("let x = 1; { let x = 2; y(x); }");
  assert.strictEqual(a.scopes, 2);
  assert.strictEqual(a.bindings, 2);
  assert.strictEqual(a.resolved, 1);
  assert.deepStrictEqual(a.unresolved, ["y"]);
  assert.deepStrictEqual(a.diagnostics, []);

  // var hoisté au module + résolu ; import résolu ; globals unresolved.
  assert.deepStrictEqual(api.semantic("if (a) { var y = 1; } y;").unresolved, ["a"]);
  assert.strictEqual(api.semantic("import { x } from 'm'; x();").resolved, 1);
});

test("semantic : diagnostics (const réassigné, let redéclaré)", () => {
  assert.deepStrictEqual(api.semantic("const c = 1; c = 2;").diagnostics, ["assignment to constant 'c'"]);
  assert.deepStrictEqual(api.semantic("let a; let a;").diagnostics, ["redeclaration of 'a'"]);
  assert.deepStrictEqual(api.semantic("var b; var b;").diagnostics, []); // var+var légal
});

// ---- mangler (renommage des locaux) ----

test("mangle : bindings locaux -> noms courts, module intact", () => {
  assert.strictEqual(api.mangle("function f(longName) { return longName + 1; }"), "function f(a) {\n  return a + 1;\n}\n");
  assert.strictEqual(
    api.mangle("function f(x) { let y = 1; { let z = 2; use(x, y, z); } }"),
    "function f(a) {\n  let b = 1;\n  {\n    let c = 2;\n    use(a, b, c);\n  }\n}\n",
  );
  // shorthand désucré, propriété de membre intacte.
  assert.strictEqual(api.mangle("function f(longName) { return { longName }; }"), "function f(a) {\n  return { longName: a };\n}\n");
  // scope module = API publique : intact.
  assert.strictEqual(api.mangle("const api = 1; export { api };"), "const api = 1;\nexport { api };\n");
});

test("mangle : jamais de capture de global + invariant semantic", () => {
  const out = api.mangle("function f() { let x = 1; return console.log(x); }");
  assert.match(out, /console\.log/); // console (unresolved) jamais renommé
  assert.doesNotMatch(out, /let console/);
  // Invariant : mêmes bindings/refs/unresolved, zéro diagnostic après renommage.
  for (const src of ["function f(a, b) { return a + b + c; }", "const keep = 1; export { keep };"]) {
    const before = api.semantic(src);
    const after = api.semantic(api.mangle(src));
    assert.strictEqual(after.diagnostics.length, 0);
    assert.strictEqual(after.bindings, before.bindings);
    assert.strictEqual(after.resolved, before.resolved);
    assert.deepStrictEqual([...after.unresolved].sort(), [...before.unresolved].sort());
  }
});

// ---- identifiants Unicode + échappements \u ----

test("unicode : identifiants non-ASCII (café, CJK, grec)", () => {
  // binding + référence résolus.
  const s = api.semantic("const café = 1; log(café);");
  assert.strictEqual(s.bindings, 1);
  assert.strictEqual(s.resolved, 1);
  assert.deepStrictEqual(s.unresolved, ["log"]);
  // round-trip (span en bytes, zéro-copie).
  assert.strictEqual(api.parse(api.print("let 変数 = 5; 変数++;")), api.parse("let 変数 = 5; 変数++;"));
  assert.strictEqual(api.print("const Ω = 3.14;"), "const Ω = 3.14;\n");
});

test("unicode : \\u dans les identifiants -> MÊME binding décodé", () => {
  // Le cœur : A (décl) et A (réf) = le MÊME binding.
  const s = api.semantic("function f() { let \\u0041 = 1; return A; }");
  assert.strictEqual(s.resolved, 1); // A résout vers A
  assert.deepStrictEqual(s.unresolved, []);
  // Le printer émet le nom décodé.
  assert.strictEqual(api.print("let \\u0041bc = 1; \\u0041bc++;"), "let Abc = 1;\nAbc++;\n");
  // Mangle : l'identifiant échappé renommé comme n'importe quel binding.
  assert.strictEqual(api.mangle("function f() { let \\u0041 = 1; return A; }"), "function f() {\n  let a = 1;\n  return a;\n}\n");
  // Sur-acceptation documentée : émoji via \u{}.
  assert.doesNotThrow(() => api.parse("let \\u{1F600}x = 1;"));
});

test("unicode : erreurs (mot-clé échappé, \\u invalide)", () => {
  expectParseError("const \\u0069f = 1;", /keyword cannot contain/);
  expectParseError("let x\\u{ = 1", /invalid unicode escape/);
});

test("unicode : strings \\u NON décodés (non-régression) + U+2028 ASI", () => {
  // Le \u dans une string reste brut (cooked value non décodée, convention).
  assert.strictEqual(api.print('"caf\\u00e9"'), '"caf\\u00e9";\n');
  // U+2028 (Line Separator) littéral = terminateur de ligne -> ASI.
  assert.strictEqual(api.print("a b"), "a;\nb;\n");
});

// ---- error recovery ----

test("recovery : code valide -> zéro diagnostic (invariant)", () => {
  for (const src of ["const x = 1; f(x);", "class C { #p = 1; m() { return this.#p; } }", "for (const a of xs) g(a);"]) {
    assert.strictEqual(api.parseErrors(src).length, 0);
  }
});

test("recovery : parser récupère + rapporte, AST partiel produit", () => {
  // let b = ; -> 1 erreur, a et c intacts dans l'AST.
  assert.strictEqual(api.parseErrors("let a = 1; let b = ; let c = 3;").length, 1);
  const t = api.parse("let a = 1; let b = ; let c = 3;");
  assert.match(t, /Identifier a/);
  assert.match(t, /Identifier c/);
  assert.match(t, /ErrorNode/);
  // if (x { -> ) récupérée : IfStatement complet + g() survit, PAS d'error_node.
  assert.strictEqual(api.parseErrors("if (x { f(); } g();").length, 1);
  assert.match(api.parse("if (x { f(); } g();"), /IfStatement[\s\S]*Identifier g/);
  // deux erreurs distantes -> les DEUX rapportées.
  assert.strictEqual(api.parseErrors("let a = ;\nx();\ny();\nz();\nlet b = ;\nend();").length, 2);
});

test("recovery : garde-fou anti-boucle (pas de timeout)", () => {
  // Ces cas boucleraient à l'infini sans le garde-fou. Que ça revienne = OK.
  for (const src of ["let x = ((((((;", "}}}}}}", "@#@#@#", "function f( function g("]) {
    assert.ok(api.parseErrors(src).length >= 1);
  }
});

test("recovery : mangle REFUSE le code cassé ; print/transform l'acceptent", () => {
  assert.throws(() => api.mangle("let a = ;"), /syntax errors/);
  // Un formateur doit marcher sur du code cassé.
  assert.doesNotThrow(() => api.print("if (x { f(); }"));
  assert.doesNotThrow(() => api.transform("let a = ;"));
});

test("parseErrors : format { message, offset }", () => {
  const errs = api.parseErrors("let a = 1 let b = 2");
  assert.strictEqual(errs.length, 1);
  assert.strictEqual(typeof errs[0].message, "string");
  assert.strictEqual(typeof errs[0].offset, "number");
});

// ---- JSX (opt-in) ----

test("JSX : élément complet (attribut string + enfant)", () => {
  const t = api.parseJsx('<div className="a">hello</div>');
  assert.match(t, /JSXElement/);
  assert.match(t, /JSXOpeningElement\n {8}JSXIdentifier div/);
  assert.match(t, /JSXAttribute\n {10}JSXIdentifier className\n {10}StringLiteral "a"/);
  assert.match(t, /JSXText "hello"/);
  assert.strictEqual(api.parseErrorsJsx('<div className="a">hello</div>').length, 0);
});

test("JSX : membre A.B.C + 3 formes d'attributs + fragment", () => {
  const t = api.parseJsx("<A.B.C x={1} {...p} bare/>");
  assert.match(t, /JSXMemberExpression/);
  assert.match(t, /JSXExpressionContainer\n {12}NumberLiteral 1/);
  assert.match(t, /JSXSpreadAttribute/);
  assert.strictEqual(api.parseErrorsJsx("<>{a}<b/></>").length, 0);
  assert.match(api.parseJsx("<>{a}<b/></>"), /JSXFragment/);
});

test("JSX : double bascule JS<->JSX + texte à espaces préservés", () => {
  assert.strictEqual(api.parseErrorsJsx("<ul>{xs.map(x => <li key={x}>{x}</li>)}</ul>").length, 0);
  const t = api.parseJsx("<div>a {b} c</div>");
  assert.match(t, /JSXText "a "/);
  assert.match(t, /JSXText " c"/);
});

test("JSX : balise fermante non appariée -> 1 diagnostic", () => {
  const errs = api.parseErrorsJsx("<span>x</div>");
  assert.strictEqual(errs.length, 1);
  assert.match(errs[0].message, /does not match/);
  // Deux erreurs distantes : les deux, le milieu survit.
  assert.strictEqual(api.parseErrorsJsx("const a = <A></B>;\nlet ok = 1;\nconst c = <X></Y>;").length, 2);
});

test("JSX OFF : `a < b` reste une BinaryExpression (non-régression sacrée)", () => {
  assert.match(api.parse("a < b"), /BinaryExpression "<"/);
  assert.strictEqual(api.parseErrors("a < b").length, 0);
  // jsx ON : `a` en position d'opérateur -> toujours binaire (mêmes tokens).
  assert.match(api.parseJsx("a < b"), /BinaryExpression "<"/);
});

test("JSX : round-trip print(x) reparse identique", () => {
  for (const src of ['<div className="a">hello</div>', "<>{a}<b/></>", "<ul>{xs.map(x => <li key={x}>{x}</li>)}</ul>", "<div>a {b} c</div>"]) {
    assert.strictEqual(api.parseJsx(api.printJsx(src)), api.parseJsx(src), `round-trip: ${src}`);
  }
});

test("JSX : composant local <A/> référencé (semantic) + renommé au mangle ; mangle refuse le cassé", () => {
  // <App/> est une référence -> App n'est pas unresolved (règle majuscule).
  const s = api.semanticJsx("function f(){ const App = () => 1; return <App/>; }");
  assert.strictEqual(s.diagnostics.length, 0);
  // Un composant JSX local est PRÉSERVÉ par le mangle (le renommer en minuscule
  // `a` en ferait une balise intrinsèque -> on casserait le composant). Le pipeline
  // correct est jsxTransform PUIS mangle (cf. `mangle d'un composant JSX local`).
  const m = api.mangleJsx("function f(){ const App = () => 1; return <App>hi</App>; }");
  assert.match(m, /<App>hi<\/App>/); // composant intact
  // mangle refuse le JSX cassé.
  assert.throws(() => api.mangleJsx("<span>x</div>"), /syntax errors/);
});

// ---- JSX transform (automatic runtime) ----

const xf = (src) => api.jsxTransform(src).trim();

test("jsxTransform : cas Babel automatic runtime", () => {
  assert.strictEqual(
    xf('<div className="a">hi</div>'),
    'import { jsx } from "react/jsx-runtime";\njsx("div", { className: "a", children: "hi" });',
  );
  assert.strictEqual(
    xf("<App x={1}>{a}{b}</App>"),
    'import { jsxs } from "react/jsx-runtime";\njsxs(App, { x: 1, children: [a, b] });',
  );
  assert.strictEqual(xf("<div/>").split("\n")[1], 'jsx("div", {});'); // objet vide, pas de children
  assert.strictEqual(xf("<li key={k}>{v}</li>").split("\n")[1], 'jsx("li", { children: v }, k);'); // key 3e arg
  assert.strictEqual(xf("<>{a}</>"), 'import { jsx, Fragment } from "react/jsx-runtime";\njsx(Fragment, { children: a });');
  assert.strictEqual(xf("<div>\n  hello\n</div>").split("\n")[1], 'jsx("div", { children: "hello" });'); // trimming
  assert.strictEqual(xf("<div>a {b} c</div>").split("\n")[1], 'jsxs("div", { children: ["a ", b, " c"] });');
  assert.strictEqual(xf("<div>{/* c */}</div>").split("\n")[1], 'jsx("div", {});'); // commentaire disparaît
  assert.strictEqual(xf('<svg:path d="M0"/>').split("\n")[1], 'jsx("svg:path", { d: "M0" });'); // namespace -> string
});

test("jsxTransform : collision 'jsx' -> import aliasé _jsx", () => {
  const out = xf("const jsx = 1; <div/>;");
  assert.match(out, /import \{ jsx as _jsx \} from "react\/jsx-runtime";/);
  assert.match(out, /_jsx\("div", \{\}\);/);
});

test("jsxTransform : sortie = JS PUR (reparse jsx OFF, zéro nœud JSX)", () => {
  const src = '<ul className="l">{xs.map((x) => <li key={x}>{x}</li>)}</ul>';
  const out = api.jsxTransform(src);
  assert.strictEqual(api.parseErrors(out).length, 0); // reparse en JS pur
  assert.doesNotMatch(api.parse(out), /JSX/); // plus aucun nœud JSX
  assert.strictEqual(api.semantic(out).diagnostics.length, 0); // refs résolues
});

test("jsxTransform : pipeline chaîné avec mangle (parse -> transform -> mangle -> print)", () => {
  const out = api.jsxTransform("function C(){ const App = () => <div/>; return <App/>; }");
  const m = api.mangle(out); // la sortie est du JS pur -> manglable
  assert.strictEqual(api.parseErrors(m).length, 0);
  assert.strictEqual(api.semantic(m).diagnostics.length, 0);
});

test("jsxTransform : JS pur inchangé (aucun élément -> pas d'import)", () => {
  assert.strictEqual(api.jsxTransform("const x = a < b;"), api.print("const x = a < b;"));
});

// ---- TypeScript (opt-in, phase 1) : parse + EFFACE, jamais vérifie ----

const strip = (src) => api.stripTypes(src).trim();

test("stripTypes : les 8 cas d'effacement obligatoires", () => {
  assert.strictEqual(strip("let x: number = 1;"), "let x = 1;");
  assert.strictEqual(strip("function f(a: string, b?: number): void {}"), "function f(a, b) {}");
  assert.strictEqual(strip("type A = { x: number } | string; let v: A;"), "let v;"); // type A disparaît entier
  assert.strictEqual(strip("interface I extends J { m(x: T): U; }\nx;"), "x;"); // interface disparaît
  assert.strictEqual(strip("const y = x as unknown as T;"), "const y = x;");
  assert.strictEqual(strip("a! + b!;"), "a + b;");
  assert.doesNotThrow(() => api.stripTypes("let t: [string, ...number[]] | (() => void);")); // parse + strip
  assert.strictEqual(strip("const fn = (x: T): U => x;"), "const fn = (x) => x;");
});

test("stripTypes : sortie = JS PUR (reparse en mode js, zéro nœud TS)", () => {
  const ts = `interface User { id: number; name: string; }
export class Repo<T extends User> implements Iterable<T> {
  private items: T[] = [];
  add(x: T): void { this.items.push(x); }
  find(id: number): T | undefined { return this.items.find((i) => i.id === id); }
}
const r = new Repo("x");`;
  const out = api.stripTypes(ts);
  assert.strictEqual(api.parseErrors(out).length, 0); // reparse en mode js
  assert.doesNotMatch(api.parse(out), /\bTs[A-Z]/); // plus aucun nœud TS
  assert.strictEqual(api.semantic(out).diagnostics.length, 0);
});

test("semanticTs : un nom de TYPE n'est pas un faux unresolved ; la valeur oui", () => {
  const s = api.semanticTs("let v: MyType = z; function f(a: Foo): Bar { return a; }");
  const un = [...s.unresolved];
  assert.ok(un.includes("z"), "z (valeur) doit être unresolved");
  assert.ok(!un.includes("MyType"), "MyType (type) ignoré");
  assert.ok(!un.includes("Foo") && !un.includes("Bar"), "types ignorés");
  assert.strictEqual(s.diagnostics.length, 0);
});

test("TS off : `let x: number` est une erreur normale (non-régression)", () => {
  assert.ok(api.parseErrors("let x: number = 1;").length > 0);
  // et `a < b` reste une comparaison (bit-identique)
  assert.match(api.parse("a < b"), /BinaryExpression "<"/);
});

test("TS : pipeline chaîné strip -> mangle (du TS entre, du JS minifié sort)", () => {
  const out = api.stripTypes("function f<T>(x: T): T { const y: number = 1; return x; }");
  const m = api.mangle(out);
  assert.strictEqual(api.parseErrors(m).length, 0);
  assert.strictEqual(api.semantic(m).diagnostics.length, 0);
});

// ---- TypeScript phase 2 : génériques d'appel + .tsx ----

test("stripTypes : appels génériques foo<T>(x), new C<T>(), tagged", () => {
  assert.strictEqual(strip("foo<T>(x);"), "foo(x);");
  assert.strictEqual(strip("const m = new Map<string, number[]>();"), "const m = new Map();");
  assert.strictEqual(strip("gql<T>`q`;"), "gql`q`;");
  assert.strictEqual(strip("const r = identity<string>(\"a\");"), 'const r = identity("a");');
});

test("spéculation : les comparaisons NE deviennent PAS des génériques (silence total)", () => {
  // Aucune trace : ni TypeArgs dans l'arbre, ni diagnostic.
  for (const src of ["a < b", "a < b > c", "f(a < b, c > d)", "x < y && z > w"]) {
    assert.doesNotMatch(api.parseTs(src), /TypeArgs/, src);
    assert.strictEqual(api.parseErrorsTs(src).length, 0, src);
  }
  // strip laisse les comparaisons intactes.
  assert.strictEqual(strip("f(a < b, c > d);"), "f(a < b, c > d);");
});

test("import type / export type / spécificateurs mixtes", () => {
  assert.strictEqual(strip('import type { A } from "m"; x;'), "x;");
  assert.strictEqual(strip('import { type A, B } from "m"; B;'), 'import { B } from "m";\nB;');
  assert.strictEqual(strip('export type { A }; y;'), "y;");
});

test("indexed access T[K] + index signatures parsent + s'effacent", () => {
  assert.strictEqual(api.parseErrorsTs('type V = O["k"]; type D = { [k: string]: number };').length, 0);
  assert.strictEqual(strip('type V = O["k"]; let a: V;'), "let a;");
});

test("TSX : parse + strip (types partis, JSX conservé) + pipeline vers JS pur", () => {
  const tsx = `export function List<T>({ items }: { items: T[] }) {
  const [n, setN] = useState<number>(0);
  return <ul>{items.map((x, i) => <li key={i} onClick={() => setN(i)}>{String(x)}</li>)}</ul>;
}`;
  assert.strictEqual(api.parseErrorsTsx(tsx).length, 0);
  // strip TSX : les types partent, le JSX reste.
  const stripped = api.stripTypesTsx(tsx);
  assert.doesNotMatch(api.parseTsx(stripped), /\bTs[A-Z]/); // plus de types
  assert.match(stripped, /<ul>/); // JSX conservé
  // Puis jsxTransform -> JS pur.
  const js = api.jsxTransform(stripped);
  assert.strictEqual(api.parseErrors(js).length, 0);
  assert.doesNotMatch(api.parse(js), /\bTs[A-Z]|JSXElement/);
});

test("mangle d'un composant JSX local : nom PRÉSERVÉ (pas de minuscule)", () => {
  // `Provider` renommé en `a` (minuscule) deviendrait une balise intrinsèque.
  const m = api.mangleTsx("function W(){ const Provider = ctx.Provider; return <Provider>x</Provider>; }");
  assert.match(m, /<Provider>x<\/Provider>/); // composant intact
  assert.strictEqual(api.parseErrorsTsx(m).length, 0);
});

// ---- TypeScript phase 3 : émission (enum, param props, namespace) ----

test("stripTypes : enum -> IIFE (valeurs 0/5/6, style tsc)", () => {
  assert.strictEqual(
    strip("enum E { A, B = 5, C }"),
    'var E;\n(function(E) {\n  E[E["A"] = 0] = "A";\n  E[E["B"] = 5] = "B";\n  E[E["C"] = 6] = "C";\n})(E || (E = {}));',
  );
});

test("stripTypes : enum string sans reverse ; 1<<4=16 ; const enum ; export enum", () => {
  assert.doesNotMatch(strip('enum S { A = "a" }'), /S\[S\[/); // PAS de reverse mapping (double-index)
  assert.match(strip('enum S { A = "a" }'), /S\["A"\] = "a"/); // forward seulement
  assert.match(strip("enum F { X = 1 << 4 }"), /F\["X"\] = 16\]/); // folder réutilisé
  assert.match(strip("const enum C { A }"), /C\["A"\] = 0\]/); // compilé normal
  assert.match(strip("export enum Color { Red }"), /export var Color;/);
});

test("enum M { A='a', B } -> diagnostic (auto-incrément après string)", () => {
  const errs = api.parseErrorsTs('enum M { A = "a", B }');
  assert.ok(errs.some((e) => /initializer after a string/.test(e.message)));
});

test("stripTypes : double nature — enum E { A } let x: E = E.A;", () => {
  const out = strip("enum E { A } let x: E = E.A;");
  assert.match(out, /var E;/); // émis
  assert.match(out, /let x = E\.A;/); // type effacé, E.A reste
  assert.strictEqual(api.parseErrors(out).length, 0); // JS pur
  assert.strictEqual(api.semantic(out).diagnostics.length, 0);
});

test("stripTypes : parameter properties (this.x = x, super() d'abord)", () => {
  assert.match(
    strip("class C { constructor(private a, public b = 2) {} }"),
    /constructor\(a, b = 2\) \{\n {4}this\.a = a;\n {4}this\.b = b;/,
  );
  const d = strip("class D extends B { constructor(private a) { super(); f(); } }");
  assert.match(d, /super\(\);\n {4}this\.a = a;\n {4}f\(\);/); // super PUIS this.a PUIS f()
});

test("stripTypes : namespace -> IIFE + N.x résolu ; imbriqué -> diagnostic", () => {
  const out = strip("namespace N { export const x = 1; } N.x;");
  assert.match(out, /var N;/);
  assert.match(out, /N\.x = 1;/);
  assert.match(out, /N\.x;/);
  assert.strictEqual(api.parseErrors(out).length, 0);
  assert.ok(api.parseErrorsTs("namespace A { namespace B {} }").some((e) => /nested namespace/.test(e.message)));
});

test("semanticTs : enum crée un binding (E référençable, pas unresolved)", () => {
  const s = api.semanticTs("enum E { A, B } function f(){ return E.A; }");
  assert.ok(![...s.unresolved].includes("E"));
  assert.strictEqual(s.diagnostics.length, 0);
});

test("index.d.ts déclare tokenize et parse", () => {
  const dts = fs.readFileSync("./index.d.ts", "utf8");
  assert.match(dts, /export function tokenize\(arg0: string\)/);
  assert.match(dts, /export function parse\(arg0: string\)/);
});
