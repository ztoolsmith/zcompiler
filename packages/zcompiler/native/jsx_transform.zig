//! Transform JSX → appels de fonctions (le « automatic runtime » React 17+, le
//! standard depuis 2020) : ce que fait Babel/esbuild pour que React tourne.
//!
//!   <div className="a">hi</div>  →  jsx("div", { className: "a", children: "hi" })
//!   <App x={1}>{a}{b}</App>       →  jsxs(App, { x: 1, children: [a, b] })
//!   <>…</>                        →  jsx(Fragment, { children: … })
//! + l'import auto en tête de module :
//!   import { jsx, jsxs, Fragment } from "react/jsx-runtime";
//!
//! On NE fait PAS le mode « classic » (`React.createElement`) : legacy, double
//! maintenance pour rien. Ni `__source`/`__self` (dev), ni TypeScript.
//!
//! Archi (comme le mangler) : dépend d'`ast` + `semantic`, PAS du parser/printer.
//! Passe bottom-up (`exit` du walker) : les enfants JSX se transforment avant
//! leurs parents, donc `<ul>{xs.map(x => <li/>)}</ul>` tombe tout seul.
//! Ordre du pipeline : parse → jsxTransform → (mangle) → print.

const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const walker = @import("walker.zig");
const semantic = @import("semantic.zig");

pub const Options = struct {
    /// `jsxImportSource` : la source du runtime. `"react"` → `react/jsx-runtime`,
    /// `"preact"` → `preact/jsx-runtime`. Une string à substituer.
    import_source: []const u8 = "react",
};

const Ctx = struct {
    source: []const u8,
    arena: std.mem.Allocator,
    // Noms LOCAUX des helpers (aliasés en `_jsx`/… si collision avec un binding
    // du module — le semantic le sait). Les callees utilisent ces noms.
    local_jsx: []const u8,
    local_jsxs: []const u8,
    local_fragment: []const u8,
    used_jsx: bool = false,
    used_jsxs: bool = false,
    used_fragment: bool = false,
    count: usize = 0,

    // ---- fabriques de nœuds synthétiques (span 0..0 ; le printer les émet via
    // `litText`, jamais via leur span) ----
    fn node(self: *Ctx, kind: Node.Kind) *Node {
        const n = self.arena.create(Node) catch unreachable;
        n.* = .{ .start = 0, .end = 0, .kind = kind };
        return n;
    }
    fn ident(self: *Ctx, name: []const u8) *Node {
        return self.node(.{ .identifier = .{ .synthetic_text = name } });
    }
    fn strLit(self: *Ctx, quoted: []const u8) *Node {
        return self.node(.{ .string_literal = .{ .synthetic_text = quoted } });
    }
    fn boolTrue(self: *Ctx) *Node {
        return self.node(.{ .boolean_literal = .{ .synthetic_text = "true" } });
    }
    fn prop(self: *Ctx, key: *Node, value: *Node) *Node {
        return self.node(.{ .property = .{ .key = key, .value = value, .shorthand = false, .computed = false } });
    }

    /// Entoure `raw` de guillemets doubles en échappant `\` et `"` (les newlines
    /// ont disparu au trimming ; on reste défensif sur `\`/`"`). Aucune entité
    /// HTML décodée (cohérent avec tout le projet).
    fn quote(self: *Ctx, raw: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        out.append(self.arena, '"') catch unreachable;
        for (raw) |c| {
            switch (c) {
                '\\' => out.appendSlice(self.arena, "\\\\") catch unreachable,
                '"' => out.appendSlice(self.arena, "\\\"") catch unreachable,
                '\n' => out.appendSlice(self.arena, "\\n") catch unreachable,
                '\r' => out.appendSlice(self.arena, "\\r") catch unreachable,
                '\t' => out.appendSlice(self.arena, "\\t") catch unreachable,
                else => out.append(self.arena, c) catch unreachable,
            }
        }
        out.append(self.arena, '"') catch unreachable;
        return out.toOwnedSlice(self.arena) catch unreachable;
    }

    /// 1er argument de `jsx()` : nom minuscule/hyphéné/namespacé → STRING ("div") ;
    /// Majuscule/membre → l'EXPRESSION (référence). Réutilise EXACTEMENT la
    /// frontière du semantic (`ast.jsxIdentIsComponent`).
    fn nameToType(self: *Ctx, name: *const Node) *Node {
        switch (name.kind) {
            .jsx_identifier => {
                const t = name.litText(self.source);
                if (ast.jsxIdentIsComponent(t)) return self.ident(t);
                return self.strLit(self.quote(t));
            },
            .jsx_member_expression => return self.memberExpr(name),
            .jsx_namespaced_name => return self.strLit(self.quote(name.text(self.source))),
            else => return self.ident("undefined"),
        }
    }

    /// `A.B.C` (jsx_member_expression) → member_expression normale. La RACINE est
    /// toujours une référence (`<motion.div>` : minuscule mais importé) ; les
    /// propriétés sont de simples noms.
    fn memberExpr(self: *Ctx, name: *const Node) *Node {
        const m = name.kind.jsx_member_expression;
        const obj = switch (m.object.kind) {
            .jsx_member_expression => self.memberExpr(m.object),
            else => self.ident(m.object.litText(self.source)), // racine = référence
        };
        const property = self.ident(m.property.litText(self.source));
        return self.node(.{ .member_expression = .{ .object = obj, .property = property, .computed = false, .optional = false } });
    }

    /// Clé d'une propriété d'objet depuis un nom d'attribut : identifiant JS valide
    /// → clé identifiant (`className`) ; sinon (tiret `data-id`, namespace) → clé
    /// string (`"data-id"`, `"xlink:href"`).
    fn attrKey(self: *Ctx, name: *const Node) *Node {
        switch (name.kind) {
            .jsx_identifier => {
                const t = name.litText(self.source);
                if (isPlainIdent(t)) return self.ident(t);
                return self.strLit(self.quote(t));
            },
            .jsx_namespaced_name => return self.strLit(self.quote(name.text(self.source))),
            else => return self.ident("undefined"),
        }
    }

    /// Valeur d'un attribut : bare → `true` ; string → réutilisée (span brut) ;
    /// `{expr}` → l'expression ; élément → déjà transformé en appel.
    fn attrValue(self: *Ctx, value: ?*Node) *Node {
        const v = value orelse return self.boolTrue();
        return switch (v.kind) {
            .jsx_expression_container => |c| c.expression orelse self.ident("undefined"),
            else => v, // string_literal (réutilisé), ou call (élément transformé)
        };
    }

    /// Applique le trimming Babel à un JSXText et, s'il reste du texte, renvoie un
    /// StringLiteral synthétique ; sinon null (le texte disparaît des children).
    fn textChild(self: *Ctx, raw: []const u8) ?*Node {
        const cleaned = cleanJSXText(self.arena, raw) orelse return null;
        return self.strLit(self.quote(cleaned));
    }

    /// Transforme un `jsx_element` en appel `jsx(type, props, key?)` / `jsxs(...)`.
    fn lowerElement(self: *Ctx, elem: *Node) *Node {
        const el = elem.kind.jsx_element;
        const opening = el.opening.kind.jsx_opening_element;
        const type_arg = self.nameToType(opening.name);

        var props: std.ArrayList(*Node) = .empty;
        var key_arg: ?*Node = null;
        for (opening.attributes) |attr| {
            switch (attr.kind) {
                .jsx_attribute => |a| {
                    // `key` : NE va PAS dans les props, devient le 3e argument.
                    if (a.name.kind == .jsx_identifier and std.mem.eql(u8, a.name.litText(self.source), "key")) {
                        key_arg = self.attrValue(a.value);
                        continue;
                    }
                    props.append(self.arena, self.prop(self.attrKey(a.name), self.attrValue(a.value))) catch unreachable;
                },
                .jsx_spread_attribute => |s| {
                    // {...props} → spread dans l'objet (l'ObjectExpression sait déjà).
                    props.append(self.arena, self.node(.{ .spread_element = .{ .argument = s.argument } })) catch unreachable;
                },
                else => {},
            }
        }

        const kids = self.collectChildren(el.children);
        self.appendChildrenProp(&props, kids);
        return self.buildCall(if (kids.len >= 2) self.calleeJsxs() else self.calleeJsx(), type_arg, &props, key_arg);
    }

    fn lowerFragment(self: *Ctx, frag: *Node) *Node {
        const f = frag.kind.jsx_fragment;
        const kids = self.collectChildren(f.children);
        var props: std.ArrayList(*Node) = .empty;
        self.appendChildrenProp(&props, kids);
        self.used_fragment = true;
        const type_arg = self.ident(self.local_fragment);
        return self.buildCall(if (kids.len >= 2) self.calleeJsxs() else self.calleeJsx(), type_arg, &props, null);
    }

    fn calleeJsx(self: *Ctx) *Node {
        self.used_jsx = true;
        return self.ident(self.local_jsx);
    }
    fn calleeJsxs(self: *Ctx) *Node {
        self.used_jsxs = true;
        return self.ident(self.local_jsxs);
    }

    /// children : 0 → pas de clé ; 1 → `children: <l'enfant>` ; 2+ → `children:
    /// [tableau]`. C'est TOUTE la différence jsx (1) / jsxs (2+).
    fn appendChildrenProp(self: *Ctx, props: *std.ArrayList(*Node), kids: []*Node) void {
        if (kids.len == 0) return;
        const value = if (kids.len == 1) kids[0] else self.childrenArray(kids);
        props.append(self.arena, self.prop(self.ident("children"), value)) catch unreachable;
    }

    fn childrenArray(self: *Ctx, kids: []*Node) *Node {
        const elems = self.arena.alloc(?*Node, kids.len) catch unreachable;
        for (kids, 0..) |k, i| elems[i] = k;
        return self.node(.{ .array_expression = .{ .elements = elems } });
    }

    fn buildCall(self: *Ctx, callee: *Node, type_arg: *Node, props: *std.ArrayList(*Node), key_arg: ?*Node) *Node {
        const obj = self.node(.{ .object_expression = .{ .properties = props.toOwnedSlice(self.arena) catch unreachable } });
        var args: std.ArrayList(*Node) = .empty;
        args.append(self.arena, type_arg) catch unreachable;
        args.append(self.arena, obj) catch unreachable;
        if (key_arg) |k| args.append(self.arena, k) catch unreachable;
        self.count += 1;
        return self.node(.{ .call_expression = .{
            .callee = callee,
            .arguments = args.toOwnedSlice(self.arena) catch unreachable,
            .optional = false,
        } });
    }

    /// Traite les enfants (déjà transformés bottom-up pour les éléments imbriqués) :
    /// trimming des JSXText, dépliage des `{expr}` (les `{}`/`{/* */}` disparaissent),
    /// pass-through des appels (éléments enfants transformés).
    fn collectChildren(self: *Ctx, children: []*Node) []*Node {
        var out: std.ArrayList(*Node) = .empty;
        for (children) |c| {
            switch (c.kind) {
                .jsx_text => if (self.textChild(c.text(self.source))) |s| {
                    out.append(self.arena, s) catch unreachable;
                },
                .jsx_expression_container => |cont| if (cont.expression) |e| {
                    out.append(self.arena, e) catch unreachable;
                },
                else => out.append(self.arena, c) catch unreachable,
            }
        }
        return out.toOwnedSlice(self.arena) catch unreachable;
    }
};

/// Un identifiant JS « simple » (utilisable comme clé sans guillemets) : ASCII
/// `[A-Za-z_$][A-Za-z0-9_$]*`. Sinon (tiret, non-ASCII) → clé string.
fn isPlainIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s, 0..) |c, i| {
        const ok = std.ascii.isAlphabetic(c) or c == '_' or c == '$' or (i > 0 and std.ascii.isDigit(c));
        if (!ok) return false;
    }
    return true;
}

/// Trimming JSXText de Babel (`cleanJSXElementLiteralChild`) : découpe en lignes,
/// remplace les tabs par des espaces, retire les blancs de bord (sauf 1re/dernière
/// ligne), colle les lignes non vides avec un espace. Renvoie null si tout blanc.
fn cleanJSXText(arena: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    // Pass 1 : nombre de lignes + index de la dernière ligne non-vide.
    var n_lines: usize = 0;
    var last_non_empty: usize = 0;
    {
        var it = std.mem.splitScalar(u8, raw, '\n');
        var i: usize = 0;
        while (it.next()) |line| : (i += 1) {
            if (hasNonSpace(stripCr(line))) last_non_empty = i;
        }
        n_lines = i;
    }
    // Pass 2 : reconstruction.
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, '\n');
    var i: usize = 0;
    while (it.next()) |raw_line| : (i += 1) {
        const line = stripCr(raw_line);
        const is_first = (i == 0);
        const is_last = (i == n_lines - 1);
        var start: usize = 0;
        var end: usize = line.len;
        if (!is_first) while (start < end and (line[start] == ' ' or line[start] == '\t')) : (start += 1) {}; // trim leading
        if (!is_last) while (end > start and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}; // trim trailing
        const trimmed = line[start..end];
        if (trimmed.len == 0) continue;
        // Les tabs internes deviennent des espaces.
        for (trimmed) |c| out.append(arena, if (c == '\t') ' ' else c) catch unreachable;
        if (i != last_non_empty) out.append(arena, ' ') catch unreachable;
    }
    if (out.items.len == 0) return null;
    return out.toOwnedSlice(arena) catch unreachable;
}

fn stripCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}
fn hasNonSpace(line: []const u8) bool {
    for (line) |c| if (c != ' ' and c != '\t') return true;
    return false;
}

fn exitThunk(ctx: *anyopaque, n: *Node) ?*Node {
    const self: *Ctx = @ptrCast(@alignCast(ctx));
    return switch (n.kind) {
        .jsx_element => self.lowerElement(n),
        .jsx_fragment => self.lowerFragment(n),
        else => null,
    };
}

/// Nom local d'un helper : le vrai nom, ou `_<nom>` s'il entre en collision avec
/// un binding du scope MODULE (aliasing). Raccourci assumé : `_<nom>` est libre.
fn localName(arena: std.mem.Allocator, module: *semantic.Scope, name: []const u8) []const u8 {
    if (module.bindings.get(name) == null) return name;
    return std.fmt.allocPrint(arena, "_{s}", .{name}) catch name;
}

/// Transforme le JSX de `program` en appels `jsx()/jsxs()` (en place) et préfixe
/// l'import auto si ≥1 élément a été transformé. Renvoie le nombre d'éléments.
pub fn transform(program: *Node, source: []const u8, arena: std.mem.Allocator, opts: Options) usize {
    // Semantic AVANT le walk : décide les alias (collision de noms au module).
    const sem = semantic.analyze(arena, program, source);
    const module = if (sem.scopes.items.len > 0) sem.scopes.items[0] else return 0;

    var ctx = Ctx{
        .source = source,
        .arena = arena,
        .local_jsx = localName(arena, module, "jsx"),
        .local_jsxs = localName(arena, module, "jsxs"),
        .local_fragment = localName(arena, module, "Fragment"),
    };
    const v = walker.Visitor{ .ctx = &ctx, .exit = exitThunk };
    _ = walker.walk(program, v);

    if (ctx.count == 0) return 0; // JS pur : rien ne bouge (pas d'import)
    prependImport(program, source, arena, &ctx, opts);
    return ctx.count;
}

/// Préfixe le Program d'un `import { jsx, jsxs, Fragment } from "…/jsx-runtime"`
/// — seulement les helpers UTILISÉS, aliasés si besoin.
fn prependImport(program: *Node, source: []const u8, arena: std.mem.Allocator, ctx: *Ctx, opts: Options) void {
    _ = source;
    var specs: std.ArrayList(*Node) = .empty;
    const add = struct {
        fn spec(a: std.mem.Allocator, c: *Ctx, imported: []const u8, local: []const u8, list: *std.ArrayList(*Node)) void {
            const node = c.node(.{ .import_specifier = .{ .imported = c.ident(imported), .local = c.ident(local) } });
            list.append(a, node) catch unreachable;
        }
    };
    if (ctx.used_jsx) add.spec(arena, ctx, "jsx", ctx.local_jsx, &specs);
    if (ctx.used_jsxs) add.spec(arena, ctx, "jsxs", ctx.local_jsxs, &specs);
    if (ctx.used_fragment) add.spec(arena, ctx, "Fragment", ctx.local_fragment, &specs);

    const runtime = std.fmt.allocPrint(arena, "\"{s}/jsx-runtime\"", .{opts.import_source}) catch "\"react/jsx-runtime\"";
    const src_node = ctx.strLit(runtime);
    const import_decl = ctx.node(.{ .import_declaration = .{
        .specifiers = specs.toOwnedSlice(arena) catch unreachable,
        .source = src_node,
    } });

    const old = program.kind.program.body;
    const new_body = arena.alloc(*Node, old.len + 1) catch return;
    new_body[0] = import_decl;
    @memcpy(new_body[1..], old);
    program.kind.program.body = new_body;
}

// ------------------------------------------------------------------ tests

const parser = @import("parser.zig");
const printer = @import("printer.zig");

/// parse(jsx) → jsxTransform → print. Renvoie le JS résultant.
fn xf(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    return xfOpts(gpa, src, .{});
}
fn xfOpts(gpa: std.mem.Allocator, src: []const u8, opts: Options) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const program = (try parser.parseWith(arena.allocator(), src, true, false)).program;
    _ = transform(program, src, arena.allocator(), opts);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try printer.print(program, src, &out, gpa);
    return out.toOwnedSlice(gpa);
}
fn expectXf(gpa: std.mem.Allocator, src: []const u8, expected: []const u8) !void {
    const out = try xf(gpa, src);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "jsx transform : élément simple + import auto" {
    const gpa = std.testing.allocator;
    try expectXf(gpa,
        \\<div className="a">hi</div>;
    ,
        \\import { jsx } from "react/jsx-runtime";
        \\jsx("div", { className: "a", children: "hi" });
        \\
    );
}

test "jsx transform : jsxs (2+ enfants) + composant + attribut expr" {
    const gpa = std.testing.allocator;
    try expectXf(gpa,
        \\<App x={1}>{a}{b}</App>;
    ,
        \\import { jsxs } from "react/jsx-runtime";
        \\jsxs(App, { x: 1, children: [a, b] });
        \\
    );
}

test "jsx transform : self-closing -> objet vide, pas de children" {
    const gpa = std.testing.allocator;
    try expectXf(gpa, "<div/>;",
        \\import { jsx } from "react/jsx-runtime";
        \\jsx("div", {});
        \\
    );
}

test "jsx transform : key -> 3e argument, hors des props" {
    const gpa = std.testing.allocator;
    try expectXf(gpa, "<li key={k}>{v}</li>;",
        \\import { jsx } from "react/jsx-runtime";
        \\jsx("li", { children: v }, k);
        \\
    );
}

test "jsx transform : fragment -> jsx(Fragment, …)" {
    const gpa = std.testing.allocator;
    try expectXf(gpa, "<>{a}</>;",
        \\import { jsx, Fragment } from "react/jsx-runtime";
        \\jsx(Fragment, { children: a });
        \\
    );
}

test "jsx transform : trimming Babel (newline + indentation)" {
    const gpa = std.testing.allocator;
    try expectXf(gpa, "<div>\n  hello\n</div>;",
        \\import { jsx } from "react/jsx-runtime";
        \\jsx("div", { children: "hello" });
        \\
    );
    // Texte + expr + texte : espaces internes préservés, tableau (jsxs).
    try expectXf(gpa, "<div>a {b} c</div>;",
        \\import { jsxs } from "react/jsx-runtime";
        \\jsxs("div", { children: ["a ", b, " c"] });
        \\
    );
}

test "jsx transform : commentaire seul enfant -> pas de children" {
    const gpa = std.testing.allocator;
    try expectXf(gpa, "<div>{/* rien */}</div>;",
        \\import { jsx } from "react/jsx-runtime";
        \\jsx("div", {});
        \\
    );
}

test "jsx transform : collision 'jsx' -> import aliasé _jsx" {
    const gpa = std.testing.allocator;
    try expectXf(gpa, "const jsx = 1; <div/>;",
        \\import { jsx as _jsx } from "react/jsx-runtime";
        \\const jsx = 1;
        \\_jsx("div", {});
        \\
    );
}

test "jsx transform : namespace -> string, attribut namespacé -> clé string" {
    const gpa = std.testing.allocator;
    try expectXf(gpa,
        \\<svg:path d="M0"/>;
    ,
        \\import { jsx } from "react/jsx-runtime";
        \\jsx("svg:path", { d: "M0" });
        \\
    );
}

test "jsx transform : membre A.B, tiret data-id -> clé string, bare -> true" {
    const gpa = std.testing.allocator;
    try expectXf(gpa, "<A.B data-id={1} hidden/>;",
        \\import { jsx } from "react/jsx-runtime";
        \\jsx(A.B, { "data-id": 1, hidden: true });
        \\
    );
}

test "jsx transform : imbriqué (map) -> récursif, aucun nœud JSX résiduel" {
    const gpa = std.testing.allocator;
    const out = try xf(gpa, "<ul>{xs.map(x => <li key={x}>{x}</li>)}</ul>;");
    defer gpa.free(out);
    // Le résultat ne contient plus AUCUNE balise `<`.
    try std.testing.expect(std.mem.indexOfScalar(u8, out, '<') == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "jsx(\"ul\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "jsx(\"li\"") != null);
}

test "jsx transform : option jsxImportSource (preact)" {
    const gpa = std.testing.allocator;
    try expectXf2(gpa, "<div/>;", .{ .import_source = "preact" },
        \\import { jsx } from "preact/jsx-runtime";
        \\jsx("div", {});
        \\
    );
}
fn expectXf2(gpa: std.mem.Allocator, src: []const u8, opts: Options, expected: []const u8) !void {
    const out = try xfOpts(gpa, src, opts);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "jsx transform : JS pur inchangé (aucun élément)" {
    const gpa = std.testing.allocator;
    try expectXf(gpa, "const x = a < b;", "const x = a < b;\n"); // pas d'import, rien ne bouge
}
