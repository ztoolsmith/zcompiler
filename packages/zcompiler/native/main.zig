//! Pont N-API : expose le lexer + le parser (parser.zig / lexer.zig) à Node.js
//! via zignapi. On écrit des fonctions Zig normales et on les enregistre avec
//! `zignapi.register`.
//!
//! Réécrit sur **zignapi v1** : plus une seule fonction ne prend `env: napi.Env`
//! ni ne renvoie une `napi.Value` construite à la main. On demande l'allocateur
//! d'appel (`a: std.mem.Allocator`, injecté par le wrapper) et on RETOURNE une
//! valeur Zig — string, struct, slice-de-struct — que zignapi convertit en JS
//! puis libère. Les objets/tableaux JS sont décrits par des structs « vue »
//! (`TokenView`, `ErrorView`, `SemanticInfo`) pour figer exactement la forme
//! exposée (les champs internes de `Token` restent privés).
//!
//! Error recovery : `parser.parseWith` renvoie TOUJOURS un AST (partiel si
//! besoin) + une liste de diagnostics. Donc `parse`/`print`/`transform`/
//! `semantic` ne throw PLUS sur une erreur de syntaxe ; les erreurs se lisent
//! via `parseErrors`. Seul `mangle` REFUSE de tourner sur du code cassé, et
//! `tokenize` s'arrête à la 1re erreur de lexing (pas de recovery lexer) —
//! les deux lèvent une exception JS via `zignapi.fail`.

const std = @import("std");
const zignapi = @import("zignapi");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const printer = @import("printer.zig");
const transformer = @import("transformer.zig");
const jsx_transform = @import("jsx_transform.zig");
const semantic = @import("semantic.zig");
const mangler = @import("mangler.zig");

const Allocator = std.mem.Allocator;

// ---- Structs « vue » : la forme JS exacte de chaque retour composite ----

/// Un token exposé à JS : `{ kind, start, end }`. On NE réexpose PAS les champs
/// internes de `lexer.Token` (`newline_before`, `cooked`). `kind` (un enum) est
/// converti en chaîne (son `@tagName`) par zignapi.
const TokenView = struct { kind: lexer.TokenKind, start: u32, end: u32 };

/// Une erreur de parse exposée à JS : `{ message, offset }` (renomme `pos`).
const ErrorView = struct { message: []const u8, offset: u32 };

/// Le résultat de `semantic` : `{ scopes, bindings, resolved, unresolved: string[],
/// diagnostics: string[] }`.
const SemanticInfo = struct {
    scopes: u32,
    bindings: u32,
    resolved: u32,
    unresolved: []const []const u8,
    diagnostics: []const []const u8,
};

// ---- Helpers partagés (pas de la glue par-fonction) ----

/// Imprime `program` en JS via le printer et renvoie le buffer (alloué dans `a`,
/// donc valide jusqu'à la conversion du retour par zignapi).
fn render(a: Allocator, program: *parser.Node, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try printer.print(program, input, &out, a);
    return out.items;
}

/// Les clés d'une StringHashMap, dans l'ordre d'itération de la map (identique
/// à l'ancien parcours `keyIterator` — l'ordre exposé ne change pas).
fn keysOf(a: Allocator, map: anytype) ![]const []const u8 {
    const out = try a.alloc([]const u8, map.count());
    var it = map.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) out[i] = k.*;
    return out;
}

// ---- tokenize ----

/// tokenize(input) -> Array<{ kind, start, end }>. Le lexer s'arrête à la 1re
/// erreur -> exception JS (pas de recovery lexer).
fn tokenize(a: Allocator, input: []const u8) ![]const TokenView {
    var diag: lexer.Diagnostic = .{};
    const toks = lexer.tokenizeDiag(a, input, &diag, false) catch |err|
        return zignapi.fail(try std.fmt.allocPrint(a, "zparse: {s} (offset {d})", .{
            if (diag.message.len != 0) diag.message else @errorName(err), diag.pos,
        }));
    const out = try a.alloc(TokenView, toks.len);
    for (toks, 0..) |t, i| out[i] = .{ .kind = t.kind, .start = t.start, .end = t.end };
    return out;
}

// ---- parse (AST rendu en arbre indenté) ----

fn parseCore(a: Allocator, input: []const u8, jsx: bool, ts: bool) ![]const u8 {
    const r = try parser.parseWith(a, input, jsx, ts);
    var out: std.ArrayList(u8) = .empty;
    try parser.printTree(r.program, input, &out, a);
    return out.items;
}
fn parse(a: Allocator, input: []const u8) ![]const u8 {
    return parseCore(a, input, false, false);
}
fn parseJsx(a: Allocator, input: []const u8) ![]const u8 {
    return parseCore(a, input, true, false);
}
fn parseTs(a: Allocator, input: []const u8) ![]const u8 {
    return parseCore(a, input, false, true);
}
fn parseTsx(a: Allocator, input: []const u8) ![]const u8 {
    return parseCore(a, input, true, true);
}

// ---- parseErrors ----

fn parseErrorsCore(a: Allocator, input: []const u8, jsx: bool, ts: bool) ![]const ErrorView {
    const r = try parser.parseWith(a, input, jsx, ts);
    const out = try a.alloc(ErrorView, r.errors.len);
    for (r.errors, 0..) |e, i| out[i] = .{ .message = e.message, .offset = e.pos };
    return out;
}
fn parseErrors(a: Allocator, input: []const u8) ![]const ErrorView {
    return parseErrorsCore(a, input, false, false);
}
fn parseErrorsJsx(a: Allocator, input: []const u8) ![]const ErrorView {
    return parseErrorsCore(a, input, true, false);
}
fn parseErrorsTs(a: Allocator, input: []const u8) ![]const ErrorView {
    return parseErrorsCore(a, input, false, true);
}
fn parseErrorsTsx(a: Allocator, input: []const u8) ![]const ErrorView {
    return parseErrorsCore(a, input, true, true);
}

// ---- print ----

fn printCore(a: Allocator, input: []const u8, jsx: bool, ts: bool) ![]const u8 {
    const r = try parser.parseWith(a, input, jsx, ts);
    return render(a, r.program, input);
}
fn print(a: Allocator, input: []const u8) ![]const u8 {
    return printCore(a, input, false, false);
}
fn printJsx(a: Allocator, input: []const u8) ![]const u8 {
    return printCore(a, input, true, false);
}
fn printTs(a: Allocator, input: []const u8) ![]const u8 {
    return printCore(a, input, false, true);
}
fn printTsx(a: Allocator, input: []const u8) ![]const u8 {
    return printCore(a, input, true, true);
}

// ---- transform (fold + booléen + DCE) ----

fn transformCore(a: Allocator, input: []const u8, jsx: bool, ts: bool) ![]const u8 {
    const r = try parser.parseWith(a, input, jsx, ts);
    _ = transformer.transform(r.program, input, a);
    return render(a, r.program, input);
}
fn transformImpl(a: Allocator, input: []const u8) ![]const u8 {
    return transformCore(a, input, false, false);
}
fn transformJsx(a: Allocator, input: []const u8) ![]const u8 {
    return transformCore(a, input, true, false);
}
fn transformTs(a: Allocator, input: []const u8) ![]const u8 {
    return transformCore(a, input, false, true);
}
fn transformTsx(a: Allocator, input: []const u8) ![]const u8 {
    return transformCore(a, input, true, true);
}

/// transformCount(input) -> number : nb de nœuds foldés/simplifiés.
fn transformCount(a: Allocator, input: []const u8) !u32 {
    const r = try parser.parseWith(a, input, false, false);
    return @intCast(transformer.transform(r.program, input, a));
}

/// parseOnly(input) -> number : parse SANS rendre l'AST (nb de statements
/// top-level). Pour benchmarker la vitesse de parsing pure.
fn parseOnly(a: Allocator, input: []const u8) !u32 {
    const r = try parser.parseWith(a, input, false, false);
    return @intCast(r.program.kind.program.body.len);
}

// ---- jsxTransform : JSX -> jsx()/jsxs() (automatic runtime) + import auto ----

fn jsxTransformImpl(a: Allocator, input: []const u8) ![]const u8 {
    const r = try parser.parseWith(a, input, true, false);
    _ = jsx_transform.transform(r.program, input, a, .{});
    return render(a, r.program, input);
}

// ---- mangle : renomme les bindings locaux, REFUSE le code cassé ----

fn mangleCore(a: Allocator, input: []const u8, jsx: bool, ts: bool) ![]const u8 {
    const r = try parser.parseWith(a, input, jsx, ts);
    if (r.errors.len > 0) return zignapi.fail("zparse: cannot mangle code with syntax errors");
    _ = mangler.mangle(a, r.program, input);
    return render(a, r.program, input);
}
fn mangleImpl(a: Allocator, input: []const u8) ![]const u8 {
    return mangleCore(a, input, false, false);
}
fn mangleJsx(a: Allocator, input: []const u8) ![]const u8 {
    return mangleCore(a, input, true, false);
}
fn mangleTs(a: Allocator, input: []const u8) ![]const u8 {
    return mangleCore(a, input, false, true);
}
fn mangleTsx(a: Allocator, input: []const u8) ![]const u8 {
    return mangleCore(a, input, true, true);
}

// ---- semantic : analyse de scopes/bindings (accepte le code cassé) ----

fn semanticCore(a: Allocator, input: []const u8, jsx: bool, ts: bool) !SemanticInfo {
    const r = try parser.parseWith(a, input, jsx, ts);
    const sem = semantic.analyze(a, r.program, input);
    const st = semantic.stats(sem);
    return .{ .scopes = st.scopes, .bindings = st.bindings, .resolved = st.resolved, .unresolved = try keysOf(a, sem.unresolved), .diagnostics = sem.diagnostics.items };
}
fn semanticImpl(a: Allocator, input: []const u8) !SemanticInfo {
    return semanticCore(a, input, false, false);
}
fn semanticJsx(a: Allocator, input: []const u8) !SemanticInfo {
    return semanticCore(a, input, true, false);
}
fn semanticTs(a: Allocator, input: []const u8) !SemanticInfo {
    return semanticCore(a, input, false, true);
}
fn semanticTsx(a: Allocator, input: []const u8) !SemanticInfo {
    return semanticCore(a, input, true, true);
}

// ---- stripTypes : TS -> JS pur (efface les types) ----

fn stripTypesImpl(a: Allocator, input: []const u8) ![]const u8 {
    const r = try parser.parseWith(a, input, false, true);
    transformer.stripTypes(r.program, input, a);
    return render(a, r.program, input);
}

/// stripTypesTsx : `.tsx` — efface les types en gardant le JSX (parse jsx+ts).
fn stripTypesTsxImpl(a: Allocator, input: []const u8) ![]const u8 {
    const r = try parser.parseWith(a, input, true, true);
    transformer.stripTypes(r.program, input, a);
    return render(a, r.program, input);
}

comptime {
    zignapi.register(.{
        .tokenize = tokenize,
        .parse = parse,
        .parseErrors = parseErrors,
        .print = print,
        .transform = transformImpl,
        .transformCount = transformCount,
        .semantic = semanticImpl,
        .mangle = mangleImpl,
        .parseOnly = parseOnly,
        // Jumeaux JSX (opt-in) : mêmes fonctions, grammaire JSX activée.
        .parseJsx = parseJsx,
        .parseErrorsJsx = parseErrorsJsx,
        .printJsx = printJsx,
        .transformJsx = transformJsx,
        .semanticJsx = semanticJsx,
        .mangleJsx = mangleJsx,
        // JSX → jsx()/jsxs() (automatic runtime) + import auto.
        .jsxTransform = jsxTransformImpl,
        // Jumeaux TypeScript (opt-in) : grammaire TS activée.
        .parseTs = parseTs,
        .parseErrorsTs = parseErrorsTs,
        .printTs = printTs,
        .transformTs = transformTs,
        .semanticTs = semanticTs,
        .mangleTs = mangleTs,
        // TS → JS pur (efface les types).
        .stripTypes = stripTypesImpl,
        // Jumeaux TSX (opt-in) : JSX + TypeScript ensemble.
        .parseTsx = parseTsx,
        .parseErrorsTsx = parseErrorsTsx,
        .printTsx = printTsx,
        .transformTsx = transformTsx,
        .semanticTsx = semanticTsx,
        .mangleTsx = mangleTsx,
        .stripTypesTsx = stripTypesTsxImpl,
    });
}
