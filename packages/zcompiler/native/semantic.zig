//! Semantic : passe d'ANALYSE (pas de transformation) qui construit des tables
//! de scopes/bindings À CÔTÉ de l'AST (l'AST ne change pas). Miroir simplifié
//! d'`oxc_semantic`.
//!
//! Ne dépend QUE de `ast.zig` + `walker.zig` (jamais parser/printer) — prêt pour
//! un futur split en crate indépendante.
//!
//! Raccourcis assumés (documentés) :
//!   - Les **function declarations** sont hoistées dans le scope FUNCTION/MODULE
//!     englobant (comportement pré-ES6 / sloppy), pas block-scoped strict.
//!   - Le **corps de fonction** est un scope block imbriqué dans le scope de la
//!     fonction (qui, lui, porte params + var + function hoistés). Conséquence :
//!     un conflit `function f(x) { let x; }` n'est pas détecté (scopes distincts).
//!   - Pas de **TDZ** : let/const sont déclarés à l'entrée du scope (hoist pour la
//!     résolution), donc une réf « avant déclaration » résout au lieu d'être une
//!     erreur. Pas d'analyse de captures/closures.

const std = @import("std");
const ast = @import("ast.zig");
const walker = @import("walker.zig");
const Node = ast.Node;

pub const ScopeKind = enum { module, function, block, for_, catch_, class_ };
pub const BindingKind = enum { var_, let_, const_, function_, class_, param, import_ };

pub const Reference = struct { start: u32, end: u32, scope_id: u32 };

pub const Binding = struct {
    name: []const u8,
    kind: BindingKind,
    decl_start: u32,
    decl_end: u32,
    references: std.ArrayList(Reference) = .empty,
    /// Nouveau nom posé par le mangler (null = garder le nom d'origine).
    new_name: ?[]const u8 = null,

    /// Nom courant : renommé s'il l'a été, sinon le nom d'origine.
    pub fn currentName(self: *const Binding) []const u8 {
        return self.new_name orelse self.name;
    }
};

pub const Scope = struct {
    id: u32,
    parent: ?u32,
    kind: ScopeKind,
    bindings: std.StringHashMapUnmanaged(*Binding) = .empty,
};

fn isLexical(kind: BindingKind) bool {
    return switch (kind) {
        .let_, .const_, .class_ => true,
        else => false,
    };
}

fn kindFromDecl(k: ast.DeclarationKind) BindingKind {
    return switch (k) {
        .@"const" => .const_,
        .let => .let_,
        .@"var" => .var_,
    };
}

/// Le scope créé par un nœud (ou null s'il n'en crée pas).
fn scopeKindFor(kind: std.meta.Tag(Node.Kind)) ?ScopeKind {
    return switch (kind) {
        .program => .module,
        .function_declaration, .function_expression, .arrow_function, .method_definition => .function,
        .block_statement => .block,
        .switch_statement => .block,
        .for_statement, .for_of_statement, .for_in_statement => .for_,
        .catch_clause => .catch_,
        .class_body => .class_,
        else => null,
    };
}

pub const Semantic = struct {
    arena: std.mem.Allocator,
    src: []const u8 = "", // source, pour lire les spans des identifiants
    scopes: std.ArrayList(*Scope) = .empty,
    diagnostics: std.ArrayList([]const u8) = .empty,
    unresolved: std.StringHashMapUnmanaged(u32) = .empty,
    /// Nœud identifiant (déclaration OU référence) -> son binding. Base du
    /// mangling : renommer = poser `new_name` sur le binding, puis parcourir cette
    /// map pour écrire le `synthetic_text` sur chaque nœud.
    node_binding: std.AutoHashMapUnmanaged(*const Node, *Binding) = .empty,
    // État de construction :
    current: u32 = 0,
    non_ref: std.AutoHashMapUnmanaged(*const Node, void) = .empty,

    fn scopeAt(self: *Semantic, id: u32) *Scope {
        return self.scopes.items[id];
    }

    fn newScope(self: *Semantic, kind: ScopeKind, parent: ?u32) u32 {
        const id: u32 = @intCast(self.scopes.items.len);
        const s = self.arena.create(Scope) catch return self.current;
        s.* = .{ .id = id, .parent = parent, .kind = kind };
        self.scopes.append(self.arena, s) catch {};
        return id;
    }

    fn diag(self: *Semantic, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.arena, fmt, args) catch return;
        self.diagnostics.append(self.arena, msg) catch {};
    }

    fn markNonRef(self: *Semantic, node: *const Node) void {
        self.non_ref.put(self.arena, node, {}) catch {};
    }
    fn isNonRef(self: *Semantic, node: *const Node) bool {
        return self.non_ref.contains(node);
    }

    // ---- déclaration ----

    /// Déclare un binding depuis son nœud identifiant (nom/span dérivés du nœud),
    /// et associe le nœud à son binding (pour le mangling). Sur redéclaration
    /// permissive (var+var), le nœud pointe vers le binding existant.
    fn declareBinding(self: *Semantic, scope_id: u32, node: *const Node, kind: BindingKind) void {
        const scope = self.scopeAt(scope_id);
        const name = node.litText(self.src);
        if (scope.bindings.get(name)) |existing| {
            // var+var / var+function : légal (permissif). Sinon (un des deux est
            // lexical : let/const/class) -> redéclaration illégale.
            if (isLexical(existing.kind) or isLexical(kind)) {
                self.diag("redeclaration of '{s}'", .{name});
            }
            self.node_binding.put(self.arena, node, existing) catch {};
            return; // on garde le binding existant (les réfs s'y accumulent)
        }
        const b = self.arena.create(Binding) catch return;
        b.* = .{ .name = name, .kind = kind, .decl_start = node.start, .decl_end = node.end };
        scope.bindings.put(self.arena, name, b) catch {};
        self.node_binding.put(self.arena, node, b) catch {};
    }

    /// Déclare tous les noms liés d'un pattern (+ les marque non-référence). Les
    /// clés (non-computed) et valeurs par défaut restent des références, résolues
    /// pendant le walk.
    fn declarePattern(self: *Semantic, scope_id: u32, node: *const Node, kind: BindingKind) void {
        switch (node.kind) {
            .identifier => {
                self.declareBinding(scope_id, node, kind);
                self.markNonRef(node);
            },
            .array_pattern => |a| for (a.elements) |el| {
                if (el) |e| self.declarePattern(scope_id, e, kind);
            },
            .object_pattern => |o| for (o.properties) |prop| switch (prop.kind) {
                .rest_element => |r| self.declarePattern(scope_id, r.argument, kind),
                .property => |p| self.declarePattern(scope_id, p.value, kind),
                else => {},
            },
            .assignment_pattern => |a| self.declarePattern(scope_id, a.left, kind),
            .rest_element => |r| self.declarePattern(scope_id, r.argument, kind),
            // TS : `x: T` — on déclare le binding, l'annotation est ignorée (type).
            .ts_typed => |t| self.declarePattern(scope_id, t.binding, kind),
            else => {}, // member (cible d'assignation), etc. : pas un binding
        }
    }

    fn declareParams(self: *Semantic, scope_id: u32, params: []*Node) void {
        for (params) |p| self.declarePattern(scope_id, p, .param);
    }

    /// var + function declarations, en descendant récursivement les statements
    /// SANS traverser les fonctions/classes imbriquées (leur propre scope).
    fn hoistScan(self: *Semantic, scope_id: u32, stmt: *Node) void {
        switch (stmt.kind) {
            .variable_declaration => |d| if (d.kind == .@"var") {
                for (d.declarations) |decl| self.declarePattern(scope_id, decl.kind.variable_declarator.id, .var_);
            },
            .function_declaration => |f| if (f.id) |id| {
                self.declareBinding(scope_id, id, .function_);
                self.markNonRef(id);
            },
            .block_statement => |b| for (b.body) |s| self.hoistScan(scope_id, s),
            .if_statement => |s| {
                self.hoistScan(scope_id, s.consequent);
                if (s.alternate) |a| self.hoistScan(scope_id, a);
            },
            .for_statement => |s| {
                if (s.init) |i| self.hoistScan(scope_id, i);
                self.hoistScan(scope_id, s.body);
            },
            .for_of_statement, .for_in_statement => |s| {
                self.hoistScan(scope_id, s.left);
                self.hoistScan(scope_id, s.body);
            },
            .while_statement => |s| self.hoistScan(scope_id, s.body),
            .do_while_statement => |s| self.hoistScan(scope_id, s.body),
            .try_statement => |t| {
                self.hoistScan(scope_id, t.block);
                if (t.handler) |h| self.hoistScan(scope_id, h);
                if (t.finalizer) |f| self.hoistScan(scope_id, f);
            },
            .catch_clause => |c| self.hoistScan(scope_id, c.body),
            .switch_statement => |s| for (s.cases) |case| {
                for (case.kind.switch_case.consequent) |st| self.hoistScan(scope_id, st);
            },
            .labeled_statement => |s| self.hoistScan(scope_id, s.body),
            .export_named_declaration => |e| if (e.declaration) |d| self.hoistScan(scope_id, d),
            else => {},
        }
    }

    /// let/const/class DIRECTS d'une liste de statements (déclarés dans le scope
    /// courant, pas hoistés). Traverse les wrappers `export`.
    fn declareDirectLexical(self: *Semantic, scope_id: u32, statements: []*Node) void {
        for (statements) |stmt| self.declareLexicalStmt(scope_id, stmt);
    }
    fn declareLexicalStmt(self: *Semantic, scope_id: u32, stmt: *Node) void {
        switch (stmt.kind) {
            .variable_declaration => |d| if (d.kind == .let or d.kind == .@"const") {
                const bk = kindFromDecl(d.kind);
                for (d.declarations) |decl| self.declarePattern(scope_id, decl.kind.variable_declarator.id, bk);
            },
            .class_declaration => |c| if (c.id) |id| {
                self.declareBinding(scope_id, id, .class_);
                self.markNonRef(id);
            },
            // TS phase 3 : enum/namespace créent un binding de VALEUR (double nature :
            // `E.Red` / `x: E`). `var_` (comme le `var E` émis) -> pas de diagnostic
            // const, et référençable partout.
            .ts_enum => |e| {
                self.declareBinding(scope_id, e.id, .var_);
                self.markNonRef(e.id);
            },
            .ts_namespace => |n| if (n.id.kind == .identifier) {
                self.declareBinding(scope_id, n.id, .var_);
                self.markNonRef(n.id);
            },
            .export_named_declaration => |e| if (e.declaration) |d| self.declareLexicalStmt(scope_id, d),
            else => {},
        }
    }

    fn declareImports(self: *Semantic, scope_id: u32, statements: []*Node) void {
        for (statements) |stmt| switch (stmt.kind) {
            .import_declaration => |d| for (d.specifiers) |spec| {
                const local = switch (spec.kind) {
                    .import_default_specifier => |s| s.local,
                    .import_namespace_specifier => |s| s.local,
                    .import_specifier => |s| s.local,
                    else => continue,
                };
                self.declareBinding(scope_id, local, .import_);
                self.markNonRef(local);
            },
            else => {},
        };
    }

    // ---- résolution ----

    fn resolveRef(self: *Semantic, node: *const Node) void {
        const name = node.litText(self.src);
        var sid: ?u32 = self.current;
        while (sid) |id| {
            if (self.scopeAt(id).bindings.get(name)) |b| {
                b.references.append(self.arena, .{ .start = node.start, .end = node.end, .scope_id = self.current }) catch {};
                self.node_binding.put(self.arena, node, b) catch {}; // pour le mangling
                return;
            }
            sid = self.scopeAt(id).parent;
        }
        const gop = self.unresolved.getOrPut(self.arena, name) catch return;
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }

    /// Règle React pour les noms JSX : `<div>` (minuscule) = balise intrinsèque,
    /// PAS une référence ; `<App>` (Majuscule) = composant, une RÉFÉRENCE à
    /// résoudre. Un nom membre `A.B` : la racine `A` est TOUJOURS une référence
    /// (ex. `<motion.div>`, minuscule mais importé). Namespace `svg:path` : jamais.
    /// Sans ça, le DCE supprimerait un composant importé « inutilisé » et le
    /// mangler ne renommerait pas la balise de fermeture -> code cassé.
    fn resolveJSXName(self: *Semantic, name: *const Node) void {
        switch (name.kind) {
            // Frontière PARTAGÉE avec le transform JSX (ast.jsxIdentIsComponent).
            .jsx_identifier => if (ast.jsxIdentIsComponent(name.litText(self.src))) self.resolveRef(name),
            .jsx_member_expression => |m| self.resolveJSXName(m.object), // racine seulement
            else => {}, // namespace : intrinsèque
        }
    }

    /// Cible d'assignation `x = …` / `x++` : si `x` résout vers un `const` ->
    /// diagnostic (réassignation d'une constante).
    fn checkConstAssign(self: *Semantic, target: *const Node) void {
        if (target.kind != .identifier) return;
        const name = target.litText(self.src);
        var sid: ?u32 = self.current;
        while (sid) |id| {
            if (self.scopeAt(id).bindings.get(name)) |b| {
                if (b.kind == .const_) self.diag("assignment to constant '{s}'", .{name});
                return;
            }
            sid = self.scopeAt(id).parent;
        }
    }

    // ---- entrée / sortie (via le walker) ----

    fn enter(self: *Semantic, node: *Node) ?*Node {
        // TS (phase 1) : un nœud de TYPE (ou une déclaration type-only) est IGNORÉ
        // entièrement — retourner le nœud STOPPE la descente (le walker ne visite
        // pas ses enfants). Les types ne créent ni bindings ni références ; aucun
        // faux `unresolved` sur un nom de type. (`ts_typed`/`as`/`!` NE sont PAS des
        // nœuds-type : leur VALEUR se résout, seul le sous-type est sauté ici.)
        if (ast.isTypeNode(node.kind)) return node;
        // TS phase 3 : le CORPS d'un namespace n'est PAS analysé (conservateur : ses
        // membres exportés ne doivent pas être renommés par le mangle — ils sont
        // accédés en `N.x`. Le binding `N` est déjà déclaré par declareLexicalStmt).
        // Cas simple seulement ; les namespaces complexes -> diagnostic au strip.
        if (node.kind == .ts_namespace) {
            self.markNonRef(node.kind.ts_namespace.id);
            return node; // stoppe la descente
        }
        // Enum : ni le nom ni les noms de membres ne sont des références (les
        // initialiseurs, eux, sont analysés normalement -> le mangle voit les refs
        // externes ; une réf à un membre antérieur par nom nu reste unresolved, OK).
        if (node.kind == .ts_enum) {
            const e = node.kind.ts_enum;
            self.markNonRef(e.id);
            for (e.members) |m| self.markNonRef(m.kind.ts_enum_member.name);
        }
        // 1) Création de scope + déclarations dedans.
        if (scopeKindFor(node.kind)) |sk| {
            const parent: ?u32 = if (node.kind == .program) null else self.current;
            self.current = self.newScope(sk, parent);
            switch (node.kind) {
                .program => |p| {
                    for (p.body) |s| self.hoistScan(self.current, s);
                    self.declareDirectLexical(self.current, p.body);
                    self.declareImports(self.current, p.body);
                },
                .function_declaration, .function_expression, .arrow_function, .method_definition => self.declareFunctionScope(node),
                .block_statement => |b| self.declareDirectLexical(self.current, b.body),
                .switch_statement => |s| for (s.cases) |c| self.declareDirectLexical(self.current, c.kind.switch_case.consequent),
                .for_statement, .for_of_statement, .for_in_statement => self.declareForScope(node),
                .catch_clause => |c| if (c.param) |p| self.declarePattern(self.current, p, .param),
                else => {}, // class_body : juste un scope
            }
        }
        // 2) Marquages non-référence + résolution (indépendants du scope).
        switch (node.kind) {
            .member_expression => |m| if (!m.computed) self.markNonRef(m.property),
            .property => self.handleProperty(node),
            .property_definition => |p| if (!p.computed) self.markNonRef(p.key),
            .method_definition => |m| if (!m.computed) self.markNonRef(m.key),
            .labeled_statement => |s| self.markNonRef(s.label),
            .break_statement, .continue_statement => |s| if (s.label) |l| self.markNonRef(l),
            .export_specifier => |s| if (s.local == s.exported) {
                // `export { used }` : local==exported = MÊME nœud. C'est une
                // référence à `used` (résolue une fois, puis marquée pour éviter
                // le double-visit local/exported du walker).
                if (!self.isNonRef(s.local)) {
                    self.resolveRef(s.local);
                    self.markNonRef(s.local);
                }
            } else {
                // `export { x as y }` : `y` (alias exporté) n'est pas une réf.
                self.markNonRef(s.exported);
            },
            // Re-export `export { a as b } from 'm'` : `a`/`b` sont des noms du
            // module cible, PAS des références locales -> non-référence.
            .export_named_declaration => |e| if (e.source != null) for (e.specifiers) |spec| {
                const es = spec.kind.export_specifier;
                self.markNonRef(es.local);
                self.markNonRef(es.exported);
            },
            .function_declaration => |f| if (f.id) |id| self.markNonRef(id), // nom hoisté par l'englobant
            .class_declaration => |c| if (c.id) |id| self.markNonRef(id),
            .assignment_expression => |a| self.checkConstAssign(a.target),
            .update_expression => |u| self.checkConstAssign(u.argument),
            .identifier => if (!self.isNonRef(node)) self.resolveRef(node),
            // JSX : ouvrant ET fermant résolvent le composant (renommage cohérent).
            .jsx_opening_element => |o| self.resolveJSXName(o.name),
            .jsx_closing_element => |c| self.resolveJSXName(c.name),
            else => {},
        }
        return null;
    }

    fn exit(self: *Semantic, node: *Node) ?*Node {
        if (scopeKindFor(node.kind) != null) {
            if (self.scopeAt(self.current).parent) |p| self.current = p;
        }
        return null;
    }

    fn declareFunctionScope(self: *Semantic, node: *Node) void {
        const fs = self.current;
        switch (node.kind) {
            .function_declaration, .function_expression => |f| {
                self.declareParams(fs, f.params);
                if (node.kind == .function_expression) if (f.id) |id| {
                    self.declareBinding(fs, id, .function_);
                    self.markNonRef(id);
                };
                if (f.body.kind == .block_statement) for (f.body.kind.block_statement.body) |s| self.hoistScan(fs, s);
            },
            .arrow_function => |f| {
                self.declareParams(fs, f.params);
                if (f.body.kind == .block_statement) for (f.body.kind.block_statement.body) |s| self.hoistScan(fs, s);
            },
            .method_definition => |m| {
                self.declareParams(fs, m.params);
                if (m.body.kind == .block_statement) for (m.body.kind.block_statement.body) |s| self.hoistScan(fs, s);
            },
            else => {},
        }
    }

    fn declareForScope(self: *Semantic, node: *Node) void {
        const head: ?*Node = switch (node.kind) {
            .for_statement => |s| s.init,
            .for_of_statement, .for_in_statement => |s| s.left,
            else => null,
        };
        if (head) |h| if (h.kind == .variable_declaration) {
            const d = h.kind.variable_declaration;
            if (d.kind == .let or d.kind == .@"const") {
                const bk = kindFromDecl(d.kind);
                for (d.declarations) |decl| self.declarePattern(self.current, decl.kind.variable_declarator.id, bk);
            }
        };
    }

    /// Property d'objet : marque la clé non-computed ; le shorthand `{x}` est
    /// résolu UNE fois ici (key==value = même nœud, sinon le walker le visiterait
    /// deux fois).
    fn handleProperty(self: *Semantic, node: *Node) void {
        const p = node.kind.property;
        if (p.shorthand) {
            if (!self.isNonRef(p.key)) { // shorthand d'EXPRESSION (pas un pattern)
                self.resolveRef(p.key);
                self.markNonRef(p.key);
            }
        } else if (!p.computed) {
            self.markNonRef(p.key);
        }
    }
};

fn enterThunk(ctx: *anyopaque, node: *Node) ?*Node {
    const s: *Semantic = @ptrCast(@alignCast(ctx));
    return s.enter(node);
}
fn exitThunk(ctx: *anyopaque, node: *Node) ?*Node {
    const s: *Semantic = @ptrCast(@alignCast(ctx));
    return s.exit(node);
}

/// Analyse `program`. Toutes les tables sont allouées dans `arena` (indépendante
/// de celle de l'AST). Renvoie le résultat (scopes / diagnostics / unresolved).
pub fn analyze(arena: std.mem.Allocator, program: *Node, source: []const u8) *Semantic {
    const s = arena.create(Semantic) catch unreachable;
    s.* = .{ .arena = arena, .src = source };
    const v = walker.Visitor{ .ctx = s, .enter = enterThunk, .exit = exitThunk };
    _ = walker.walk(program, v);
    return s;
}

// ---- stats (pour le harnais) ----

pub const Stats = struct { scopes: u32, bindings: u32, resolved: u32, unresolved: u32, diagnostics: u32 };

pub fn stats(s: *Semantic) Stats {
    var bindings: u32 = 0;
    var resolved: u32 = 0;
    for (s.scopes.items) |scope| {
        bindings += @intCast(scope.bindings.count());
        var it = scope.bindings.valueIterator();
        while (it.next()) |b| resolved += @intCast(b.*.references.items.len);
    }
    return .{
        .scopes = @intCast(s.scopes.items.len),
        .bindings = bindings,
        .resolved = resolved,
        .unresolved = @intCast(s.unresolved.count()),
        .diagnostics = @intCast(s.diagnostics.items.len),
    };
}

// ------------------------------------------------------------------ tests

const parser = @import("parser.zig");

const Probe = struct {
    arena: std.heap.ArenaAllocator,
    sem: *Semantic,
    fn deinit(self: *Probe) void {
        self.arena.deinit();
    }
    fn totalRefs(self: *Probe, name: []const u8) usize {
        var n: usize = 0;
        for (self.sem.scopes.items) |sc| if (sc.bindings.get(name)) |b| {
            n += b.references.items.len;
        };
        return n;
    }
    fn bindingCount(self: *Probe, name: []const u8) usize {
        var n: usize = 0;
        for (self.sem.scopes.items) |sc| if (sc.bindings.contains(name)) {
            n += 1;
        };
        return n;
    }
    fn refsInKind(self: *Probe, kind: ScopeKind, name: []const u8) usize {
        for (self.sem.scopes.items) |sc| if (sc.kind == kind) if (sc.bindings.get(name)) |b| {
            return b.references.items.len;
        };
        return 0;
    }
    fn unresolved(self: *Probe, name: []const u8) bool {
        return self.sem.unresolved.contains(name);
    }
    fn diags(self: *Probe) usize {
        return self.sem.diagnostics.items.len;
    }
};

fn probe(gpa: std.mem.Allocator, src: []const u8) !Probe {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const program = (try parser.parse(a, src)).program;
    const sem = analyze(a, program, src);
    return .{ .arena = arena, .sem = sem };
}
fn probeTs(gpa: std.mem.Allocator, src: []const u8) !Probe {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const program = (try parser.parseWith(a, src, false, true)).program;
    const sem = analyze(a, program, src);
    return .{ .arena = arena, .sem = sem };
}

test "TS : les noms de TYPES ne créent aucun faux unresolved (ignorés)" {
    var p = try probeTs(std.testing.allocator, "let v: MyType = z; function f(a: Foo): Bar { return a; }");
    defer p.deinit();
    // `z` = vraie référence de valeur -> unresolved (global). Les types NON.
    try std.testing.expect(p.unresolved("z"));
    try std.testing.expect(!p.unresolved("MyType"));
    try std.testing.expect(!p.unresolved("Foo"));
    try std.testing.expect(!p.unresolved("Bar"));
    try std.testing.expectEqual(@as(usize, 0), p.diags());
    // Le param `a` (binding annoté ts_typed) est bien déclaré -> résolu, pas unresolved.
    try std.testing.expect(!p.unresolved("a"));
}

test "shadowing : la référence résout vers le binding le plus proche" {
    var p = try probe(std.testing.allocator, "let x = 1; { let x = 2; y(x); }");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.bindingCount("x")); // module + block
    try std.testing.expectEqual(@as(usize, 1), p.refsInKind(.block, "x")); // résout vers l'interne
    try std.testing.expectEqual(@as(usize, 0), p.refsInKind(.module, "x"));
    try std.testing.expect(p.unresolved("y"));
    try std.testing.expectEqual(@as(usize, 0), p.diags());
}

test "var hoisté à la fonction/module en traversant les blocs" {
    var p = try probe(std.testing.allocator, "if (a) { var y = 1; } y;");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.bindingCount("y"));
    try std.testing.expectEqual(@as(usize, 1), p.refsInKind(.module, "y")); // y résolu au module
    try std.testing.expect(p.unresolved("a"));
    try std.testing.expectEqual(@as(usize, 0), p.diags());
}

test "diagnostics : const réassigné, let redéclaré ; var+var légal" {
    {
        var p = try probe(std.testing.allocator, "const c = 1; c = 2;");
        defer p.deinit();
        try std.testing.expectEqual(@as(usize, 1), p.diags());
    }
    {
        var p = try probe(std.testing.allocator, "let a; let a;");
        defer p.deinit();
        try std.testing.expectEqual(@as(usize, 1), p.diags());
    }
    {
        var p = try probe(std.testing.allocator, "var b; var b;");
        defer p.deinit();
        try std.testing.expectEqual(@as(usize, 0), p.diags());
    }
    {
        var p = try probe(std.testing.allocator, "let x; var x;");
        defer p.deinit();
        try std.testing.expectEqual(@as(usize, 1), p.diags());
    }
}

test "params résolus, globals unresolved" {
    var p = try probe(std.testing.allocator, "function f(p) { return p + q; }");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.totalRefs("p")); // p résolu
    try std.testing.expect(p.unresolved("q")); // q global
    try std.testing.expect(!p.unresolved("p"));
    try std.testing.expectEqual(@as(usize, 0), p.diags());
}

test "catch (e) : e dans le scope catch" {
    var p = try probe(std.testing.allocator, "try {} catch (e) { e; }");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.totalRefs("e"));
    try std.testing.expect(!p.unresolved("e"));
}

test "import { x } : x est un binding du module" {
    var p = try probe(std.testing.allocator, "import { x } from 'm'; x();");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.refsInKind(.module, "x"));
    try std.testing.expect(!p.unresolved("x"));
}

test "forward reference vers une fonction hoistée résout" {
    var p = try probe(std.testing.allocator, "y(); function y() {}");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.totalRefs("y"));
    try std.testing.expect(!p.unresolved("y"));
}

test "clés d'objet / propriétés de membre ne sont pas des références" {
    var p = try probe(std.testing.allocator, "const o = { a: v }; o.b; const s = { c };");
    defer p.deinit();
    // `a` (clé) et `b` (propriété membre) NON résolus/unresolved ; `v` et `c` oui.
    try std.testing.expect(!p.unresolved("a"));
    try std.testing.expect(!p.unresolved("b"));
    try std.testing.expect(p.unresolved("v"));
    try std.testing.expect(p.unresolved("c")); // shorthand {c} = référence
}
