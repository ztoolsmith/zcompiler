//! Mangler : renomme les bindings LOCAUX en noms courts (`a`, `b`, … `z`, `aa`,
//! `ab`, …) — la base du minifier. Dépend d'`ast.zig` + `semantic.zig`.
//!
//! Principe : le semantic connaît chaque binding et TOUS ses nœuds (déclaration +
//! références) via `node_binding`. Renommer = poser `new_name` sur le binding,
//! puis écrire ce nom en `synthetic_text` sur chacun de ses nœuds identifiants.
//!
//! **On ne touche JAMAIS au scope module** (ses noms sont l'API publique) ni aux
//! propriétés/clés (non-références). Le shorthand `{x}` renommé est **désucré**
//! par le printer en `{ x: <nouveau> }` (cf. printer.zig).
//!
//! Stratégie de collisions (assigner en descendant, scopes en ordre de création
//! = pré-ordre, donc parents avant enfants) : pour un binding, l'ensemble des
//! noms INTERDITS = mots réservés ∪ tous les `unresolved` du fichier (évite de
//! capturer un global : `let x = console` ne devient jamais `console`) ∪ noms
//! COURANTS des bindings des scopes ANCÊTRES (évite le shadowing accidentel d'un
//! nom encore visible) ∪ frères déjà attribués. Les enfants évitant les noms des
//! ancêtres, un binding ne peut pas être shadowé par un descendant.

const std = @import("std");
const ast = @import("ast.zig");
const semantic = @import("semantic.zig");
const Node = ast.Node;

/// Mots à ne jamais générer : mots-clés + réservés + quelques identifiants
/// spéciaux (arguments/eval) et globals fréquents (par prudence).
const reserved = [_][]const u8{
    "break",     "case",      "catch",   "class",     "const",  "continue",
    "debugger",  "default",   "delete",  "do",        "else",   "export",
    "extends",   "false",     "finally", "for",       "function", "if",
    "import",    "in",        "instanceof", "new",    "null",   "return",
    "super",     "switch",    "this",    "throw",     "true",   "try",
    "typeof",    "var",       "void",    "while",     "with",   "yield",
    "let",       "static",    "enum",    "await",     "async",  "implements",
    "interface", "package",   "private", "protected", "public", "as",
    "of",        "get",       "set",     "arguments", "eval",
};

/// Nom court bijectif base-26 : 0->a … 25->z, 26->aa, 27->ab …
fn shortName(arena: std.mem.Allocator, index: usize) []const u8 {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var n = index + 1;
    while (n > 0) {
        n -= 1;
        buf[len] = 'a' + @as(u8, @intCast(n % 26));
        len += 1;
        n /= 26;
    }
    std.mem.reverse(u8, buf[0..len]);
    return arena.dupe(u8, buf[0..len]) catch "a";
}

fn lessDecl(_: void, a: *semantic.Binding, b: *semantic.Binding) bool {
    return a.decl_start < b.decl_start;
}

/// Renomme les bindings locaux de `program` (en place, `synthetic_text` alloués
/// dans `arena`). Renvoie le nombre de bindings renommés.
pub fn mangle(arena: std.mem.Allocator, program: *Node, source: []const u8) usize {
    const sem = semantic.analyze(arena, program, source);

    // Base interdite (constante pour tous les scopes) : réservés + unresolved.
    var base: std.StringHashMapUnmanaged(void) = .empty;
    for (reserved) |kw| base.put(arena, kw, {}) catch {};
    var uit = sem.unresolved.keyIterator();
    while (uit.next()) |name| base.put(arena, name.*, {}) catch {};

    // Bindings utilisés comme NOM DE COMPOSANT JSX (`<Foo/>`) : on ne les renomme
    // PAS. La règle React majuscule/minuscule : `Foo` renommé en `a` (minuscule)
    // deviendrait une balise INTRINSÈQUE -> on casserait le composant (référence
    // perdue). Le pipeline correct est jsxTransform PUIS mangle (le `<Foo/>` devient
    // `jsx(Foo, …)`, un identifiant normal, manglable) ; sur du JSX/TSX BRUT on reste
    // conservateur. (Un `jsx_identifier` dans `node_binding` = un composant résolu.)
    var jsx_component: std.AutoHashMapUnmanaged(*semantic.Binding, void) = .empty;
    var jit = sem.node_binding.iterator();
    while (jit.next()) |entry| {
        if (entry.key_ptr.*.kind == .jsx_identifier) jsx_component.put(arena, entry.value_ptr.*, {}) catch {};
    }

    var local: std.StringHashMapUnmanaged(void) = .empty; // ancêtres + frères
    var renamed: usize = 0;

    // Scopes en ordre de création (= pré-ordre : parents avant enfants).
    for (sem.scopes.items) |scope| {
        if (scope.kind == .module) continue; // API publique : intacte

        // Interdits « locaux » : noms courants des bindings ancêtres.
        local.clearRetainingCapacity();
        var pid = scope.parent;
        while (pid) |id| {
            var bit = sem.scopes.items[id].bindings.valueIterator();
            while (bit.next()) |b| local.put(arena, b.*.currentName(), {}) catch {};
            pid = sem.scopes.items[id].parent;
        }

        // Bindings du scope triés par position de déclaration (déterminisme).
        var list: std.ArrayList(*semantic.Binding) = .empty;
        var it = scope.bindings.valueIterator();
        while (it.next()) |b| list.append(arena, b.*) catch {};
        std.mem.sort(*semantic.Binding, list.items, {}, lessDecl);

        var counter: usize = 0;
        for (list.items) |b| {
            if (jsx_component.contains(b)) continue; // composant JSX : nom conservé
            const name = while (true) {
                const cand = shortName(arena, counter);
                counter += 1;
                if (!base.contains(cand) and !local.contains(cand)) break cand;
            };
            b.new_name = name;
            local.put(arena, name, {}) catch {}; // frère : interdit pour les suivants
            renamed += 1;
        }
    }

    // Application : chaque nœud identifiant d'un binding renommé porte son
    // `synthetic_text` (déclaration ET références, via `node_binding`).
    var nit = sem.node_binding.iterator();
    while (nit.next()) |entry| {
        if (entry.value_ptr.*.new_name) |nn| {
            const node: *Node = @constCast(entry.key_ptr.*);
            // Un nœud résolu est un `identifier` OU un `jsx_identifier` (nom de
            // composant JSX résolu par la règle majuscule) : les deux portent un
            // `synthetic_text` que le printer sert via `litText`.
            switch (node.kind) {
                .identifier => |*l| l.synthetic_text = nn,
                .jsx_identifier => |*l| l.synthetic_text = nn,
                else => {},
            }
        }
    }
    return renamed;
}

// ------------------------------------------------------------------ tests

const parser = @import("parser.zig");
const printer = @import("printer.zig");

fn mangleSource(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const program = (try parser.parse(a, src)).program;
    _ = mangle(a, program, src);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try printer.print(program, src, &out, gpa);
    return out.toOwnedSlice(gpa);
}

fn expectMangle(gpa: std.mem.Allocator, src: []const u8, expected: []const u8) !void {
    const out = try mangleSource(gpa, src);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "param renommé en a" {
    try expectMangle(std.testing.allocator, "function f(longName) { return longName + 1; }", "function f(a) {\n  return a + 1;\n}\n");
}

test "scopes imbriqués : a, b, c sans collision" {
    try expectMangle(
        std.testing.allocator,
        "function f(x) { let y = 1; { let z = 2; use(x, y, z); } }",
        "function f(a) {\n  let b = 1;\n  {\n    let c = 2;\n    use(a, b, c);\n  }\n}\n",
    );
}

test "jamais renommé vers un global capturé (console)" {
    const gpa = std.testing.allocator;
    const out = try mangleSource(gpa, "function f() { let x = 1; return console.log(x); }");
    defer gpa.free(out);
    // x renommé, mais PAS en `console` (unresolved) ; l'appel console.log intact.
    try std.testing.expect(std.mem.indexOf(u8, out, "console.log") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "let a = 1") != null);
}

test "fonctions imbriquées co-visibles ne se shadowent pas" {
    try expectMangle(
        std.testing.allocator,
        "function f(a) { function g(b) { return a + b; } return g; }",
        "function f(a) {\n  function b(c) {\n    return a + c;\n  }\n  return b;\n}\n",
    );
}

test "shorthand : désucrage {x} -> {x: nouveau}" {
    try expectMangle(std.testing.allocator, "function f(longName) { return { longName }; }", "function f(a) {\n  return { longName: a };\n}\n");
}

test "scope module intact : les noms top-level sont l'API" {
    try expectMangle(std.testing.allocator, "const api = 1; export { api };", "const api = 1;\nexport { api };\n");
}
