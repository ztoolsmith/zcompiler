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
    /// Le binding est-il RÉASSIGNÉ quelque part (`x = …`, `x++`, `x += …`) ?
    /// Distinct de « référencé » : c'est une ÉCRITURE. Un bundler en a besoin
    /// pour repérer les **live bindings** (`export let x` muté après coup) —
    /// un export mutable ne survit pas au scope hoisting, il faut savoir le
    /// refuser plutôt que d'émettre un bundle faux.
    assigned: bool = false,

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
    /// `class_body` d'une **expression de classe nommée** -> son nœud identifiant.
    /// Rempli à l'entrée de la `class_expression`, consommé à l'entrée de son
    /// `class_body` (le walker garantit cet ordre). Cf. `declareBinding` du
    /// scope de classe.
    class_names: std.AutoHashMapUnmanaged(*const Node, *const Node) = .empty,

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
                b.assigned = true; // écriture : cf. `Binding.assigned`
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
                // `const C = class Bar { m() { return Bar; } }` : le nom d'une
                // EXPRESSION de classe est lié dans le corps de la classe, et
                // nulle part ailleurs (`Bar` n'existe pas à l'extérieur). Miroir
                // exact de ce que `declareFunctionScope` fait déjà pour
                // `const f = function foo() { return foo; }`.
                .class_body => if (self.class_names.get(node)) |id| {
                    self.declareBinding(self.current, id, .class_);
                },
                else => {},
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
            // `export * as ns from 'm'` : `ns` est un NOM D'EXPORT, exactement
            // comme le `b` de `export { a as b }` — pas un binding local du
            // module, pas une référence. (Le namespace n'est jamais visible
            // dans le corps du module : `export * as ns` ≠ `import * as ns`.)
            .export_all_declaration => |e| if (e.exported) |ns| self.markNonRef(ns),
            // Expression de classe nommée : le nom n'est pas une référence, et
            // il sera déclaré dans le scope du corps (cf. `.class_body` plus haut).
            // L'`enter` de la classe précède celui de son corps : la note est lue
            // juste après avoir été posée.
            .class_expression => |c| if (c.id) |id| {
                self.class_names.put(self.arena, c.body, id) catch {};
                self.markNonRef(id);
            },
            // Les clés d'attribut (`with { type: 'json' }`) sont des noms de
            // propriété, pas des références — comme une clé d'objet.
            .import_attribute => |a| self.markNonRef(a.key),
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

// ---- module records (les dépendances de module d'un AST) ----
//
// Ajouté pour zbundle (2026-07-26) : un bundler a besoin de la liste des
// specifiers d'un fichier SANS refaire un parcours d'AST chez lui. La règle de
// l'org : ce que le compilateur sait faire vit DANS le compilateur.
//
// C'est une passe d'ANALYSE pure (lecture seule, ne dépend que d'`ast` +
// `walker`), d'où sa place ici plutôt que dans le parser.

pub const ModuleRecordKind = enum {
    /// `import x from './m'` / `import './m'` (side-effect) / `import { a } from './m'`
    import,
    /// `export { a } from './m'` — un re-export EST une dépendance.
    re_export,
    /// `export * from './m'` — re-exporte les noms de la cible.
    export_all,
    /// `export * as ns from './m'` (ES2020) — **opération différente** de
    /// `export_all` : ça ne re-exporte pas les noms de la cible, ça crée UN
    /// export nommé (`name`) qui vaut l'objet namespace. Un kind à part pour
    /// que le consommateur soit forcé de trancher (`switch` exhaustif).
    export_all_as,
    /// `import('./m')` avec un specifier littéral (statiquement analysable).
    dynamic_import,
};

/// Une entrée de `with { type: 'json' }` : `key` et `value` **décodés**.
pub const ImportAttribute = struct { key: []const u8, value: []const u8 };

/// Une dépendance de module, dans l'ORDRE DU SOURCE.
///
/// `specifier` est **décodé** (guillemets retirés, échappements résolus) : c'est
/// la chaîne telle que la verrait le runtime, prête à passer à un resolver.
/// `start`/`end` = le span du littéral (guillemets INCLUS), pour un diagnostic.
/// `type_only` = `import type …` / `export type …` (TS) : effacé à l'émission,
/// donc **pas** une dépendance runtime — c'est à l'appelant de filtrer.
/// `name` : le nom d'export d'un `export * as ns from` (null pour tout le reste).
/// `attributes` : la clause `with { … }`, vide si absente. Renseignée pour les
/// formes STATIQUES seulement — pour un `import(src, options)`, les options sont
/// une expression quelconque que la grammaire ne contraint pas, donc rien n'est
/// deviné ici (l'AST porte `ImportExpression.options` pour qui veut l'analyser).
pub const ModuleRecord = struct {
    specifier: []const u8,
    kind: ModuleRecordKind,
    start: u32,
    end: u32,
    type_only: bool = false,
    name: ?[]const u8 = null,
    attributes: []const ImportAttribute = &.{},
};

const RecordCollector = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    out: std.ArrayList(ModuleRecord) = .empty,

    /// N'enregistre QUE les specifiers littéraux. Un `import(expr)` calculé ou
    /// un nœud d'erreur (code cassé, error recovery) est ignoré en silence :
    /// il n'y a rien à résoudre.
    fn push(
        self: *RecordCollector,
        node: *Node,
        kind: ModuleRecordKind,
        type_only: bool,
        name: ?*Node,
        attrs: Node.Attributes,
    ) void {
        if (node.kind != .string_literal) return;
        const raw = node.litText(self.src);
        self.out.append(self.arena, .{
            .specifier = decodeStringLiteral(self.arena, raw),
            .kind = kind,
            .start = node.start,
            .end = node.end,
            .type_only = type_only,
            .name = if (name) |n| n.litText(self.src) else null,
            .attributes = self.decodeAttributes(attrs),
        }) catch {};
    }

    /// Les attributs, clés et valeurs décodées. Une clé identifiant se lit telle
    /// quelle ; une clé string passe par le décodage (guillemets + échappements),
    /// comme les valeurs — toujours des string literals par la grammaire.
    fn decodeAttributes(self: *RecordCollector, attrs: Node.Attributes) []const ImportAttribute {
        if (attrs.entries.len == 0) return &.{};
        const out = self.arena.alloc(ImportAttribute, attrs.entries.len) catch return &.{};
        for (attrs.entries, out) |entry, *slot| {
            const a = entry.kind.import_attribute;
            const key = a.key.litText(self.src);
            slot.* = .{
                .key = if (a.key.kind == .string_literal) decodeStringLiteral(self.arena, key) else key,
                .value = decodeStringLiteral(self.arena, a.value.litText(self.src)),
            };
        }
        return out;
    }

    fn enter(self: *RecordCollector, node: *Node) ?*Node {
        switch (node.kind) {
            .import_declaration => |d| self.push(d.source, .import, d.type_only, null, d.attributes),
            .export_all_declaration => |d| self.push(
                d.source,
                if (d.exported != null) .export_all_as else .export_all,
                false,
                d.exported,
                d.attributes,
            ),
            .export_named_declaration => |d| if (d.source) |s| self.push(s, .re_export, d.type_only, null, d.attributes),
            // `import(src, options)` : les options sont une expression quelconque
            // (pas la grammaire statique des attributs) — on ne devine rien.
            .import_expression => |e| self.push(e.source, .dynamic_import, false, null, .{}),
            else => {},
        }
        return null; // jamais de substitution : passe en lecture seule.
    }
};

fn recordsEnterThunk(ctx: *anyopaque, node: *Node) ?*Node {
    const c: *RecordCollector = @ptrCast(@alignCast(ctx));
    return c.enter(node);
}

/// Les dépendances de module de `program`, dans l'ordre du source.
///
/// Couvre : `import`, `export … from`, `export * from`, `import()` littéral.
/// Ne couvre PAS (assumé, documenté) : `require()` (CJS — zcompiler est ESM),
/// `import(expr)` calculé (rien à résoudre statiquement), les import attributes
/// (`with { type: 'json' }` — pas encore dans la grammaire).
///
/// Tout est alloué dans `arena` ; les specifiers SANS échappement pointent
/// directement dans `source` (zéro copie).
pub fn moduleRecords(arena: std.mem.Allocator, program: *Node, source: []const u8) []const ModuleRecord {
    var c = RecordCollector{ .arena = arena, .src = source };
    const v = walker.Visitor{ .ctx = &c, .enter = recordsEnterThunk };
    _ = walker.walk(program, v);
    return c.out.items;
}

/// `'./x'` -> `./x` : retire les guillemets et résout les échappements.
/// Sans `\` (le cas de 99,9 % des specifiers), renvoie une tranche du source —
/// aucune allocation. En cas d'échappement invalide, on garde le caractère brut
/// (on décode, on ne valide pas : le lexer a déjà validé).
pub fn decodeStringLiteral(arena: std.mem.Allocator, raw: []const u8) []const u8 {
    if (raw.len < 2) return raw; // défensif (littéral synthétique nu)
    const inner = raw[1 .. raw.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;

    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(arena, inner.len) catch return inner;
    var i: usize = 0;
    while (i < inner.len) {
        const ch = inner[i];
        if (ch != '\\' or i + 1 >= inner.len) {
            out.append(arena, ch) catch return inner;
            i += 1;
            continue;
        }
        i += 1; // consomme le `\`
        const esc = inner[i];
        i += 1;
        switch (esc) {
            'n' => out.append(arena, '\n') catch return inner,
            't' => out.append(arena, '\t') catch return inner,
            'r' => out.append(arena, '\r') catch return inner,
            'b' => out.append(arena, 0x08) catch return inner,
            'f' => out.append(arena, 0x0C) catch return inner,
            'v' => out.append(arena, 0x0B) catch return inner,
            '0' => out.append(arena, 0) catch return inner,
            '\n' => {}, // continuation de ligne : le `\` + le saut disparaissent
            'x' => {
                const cp = parseHex(inner, &i, 2) orelse continue;
                appendCodepoint(arena, &out, cp);
            },
            'u' => {
                const cp = parseUnicodeEscape(inner, &i) orelse continue;
                appendCodepoint(arena, &out, cp);
            },
            else => out.append(arena, esc) catch return inner, // \\ \' \" \` \/ …
        }
    }
    return out.items;
}

/// `ꯍ` ou `\u{1F600}` (le `\u` est déjà consommé). Recombine une paire de
/// surrogates `😀` en un seul code point.
fn parseUnicodeEscape(s: []const u8, i: *usize) ?u21 {
    if (i.* < s.len and s[i.*] == '{') {
        i.* += 1;
        const end = std.mem.indexOfScalarPos(u8, s, i.*, '}') orelse return null;
        const cp = std.fmt.parseInt(u21, s[i.*..end], 16) catch return null;
        i.* = end + 1;
        return cp;
    }
    const hi = parseHex(s, i, 4) orelse return null;
    if (hi < 0xD800 or hi > 0xDBFF) return hi;
    // High surrogate : la moitié basse suit-elle, sous forme d'un autre `\uXXXX` ?
    const save = i.*;
    if (i.* + 2 <= s.len and s[i.*] == '\\' and s[i.* + 1] == 'u') {
        i.* += 2;
        if (parseHex(s, i, 4)) |lo| {
            if (lo >= 0xDC00 and lo <= 0xDFFF)
                return 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
        }
        i.* = save; // pas une paire valide : on rend les octets
    }
    return hi;
}

fn parseHex(s: []const u8, i: *usize, comptime n: usize) ?u21 {
    if (i.* + n > s.len) return null;
    const v = std.fmt.parseInt(u21, s[i.* .. i.* + n], 16) catch return null;
    i.* += n;
    return v;
}

/// Encode `cp` en UTF-8. Un surrogate isolé (illégal en UTF-8) devient U+FFFD.
fn appendCodepoint(arena: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        out.appendSlice(arena, "\u{FFFD}") catch {};
        return;
    };
    out.appendSlice(arena, buf[0..n]) catch {};
}

// ---- module info : la table des imports/exports (ce qu'un LINKER doit savoir) ----
//
// Ajouté pour zbundle v0.2 (2026-07-26). `moduleRecords` répond « de quoi ce
// fichier dépend-il ? » — assez pour tracer un graphe. Lier, c'est une autre
// question : « quel BINDING se cache derrière chaque nom importé/exporté ? ».
//
// Équivalent du `ModuleRecord` d'oxc / du `Module` de rollup. Reste une passe
// d'ANALYSE en lecture seule (ast + walker), d'où sa place ici.

pub const ImportKind = enum {
    /// `import d from './m'`
    default,
    /// `import { a as b } from './m'`
    named,
    /// `import * as ns from './m'`
    namespace,
};

/// Un nom LIÉ localement par un import. `binding` est le binding du scope module
/// (celui qu'on renommera) ; `imported` est le nom vu chez la source.
pub const ImportEntry = struct {
    local: []const u8,
    binding: ?*Binding,
    specifier: []const u8,
    kind: ImportKind,
    /// `.named` seulement (vide pour default/namespace).
    imported: []const u8 = "",
};

pub const ExportKind = enum {
    /// `export const x` / `export { x }` / `export default x` : un binding LOCAL.
    local,
    /// `export default <expression>` : aucun binding, il faut en fabriquer un.
    default_expr,
    /// `export { a as b } from './m'` : indirect — suivre la chaîne chez la source.
    re_export,
    /// `export * as ns from './m'` : le namespace de la source, sous un nom.
    star_as,
};

/// Un nom vu de l'EXTÉRIEUR du module. `exported` vaut `"default"` pour un
/// export par défaut (c'est un nom d'export comme un autre).
pub const ExportEntry = struct {
    exported: []const u8,
    kind: ExportKind,
    /// `.local` : le binding exporté.
    binding: ?*Binding = null,
    /// `.default_expr` : l'expression à lier à un nom fabriqué.
    value: ?*Node = null,
    /// `.re_export` / `.star_as` : la source et le nom importé chez elle.
    specifier: []const u8 = "",
    imported: []const u8 = "",
};

/// Tout ce qu'un linker doit savoir d'un module, en une passe.
pub const ModuleInfo = struct {
    imports: []const ImportEntry,
    exports: []const ExportEntry,
    /// `export * from './m'` : les specifiers dont les noms sont re-exportés en
    /// bloc (à résoudre chez la source — ils ne sont pas énumérables ici).
    star_exports: []const []const u8,
    /// Le scope module : tous les bindings top-level, la matière du renommage.
    module_scope: *Scope,
    /// `await` en dehors de toute fonction. Un bundler à scope hoisting ne peut
    /// pas concaténer ça dans un module qui ne l'attend pas.
    has_top_level_await: bool = false,
    /// `import.meta` : dépend de l'URL du module, qui n'existe plus après fusion.
    has_import_meta: bool = false,
};

const InfoCollector = struct {
    arena: std.mem.Allocator,
    sem: *Semantic,
    src: []const u8,
    fn_depth: u32 = 0,
    tla: bool = false,
    meta: bool = false,

    fn enter(self: *InfoCollector, node: *Node) ?*Node {
        switch (node.kind) {
            .function_declaration, .function_expression, .arrow_function, .method_definition => self.fn_depth += 1,
            .await_expression => if (self.fn_depth == 0) {
                self.tla = true;
            },
            .meta_property => self.meta = true,
            else => {},
        }
        return null;
    }
    fn exit(self: *InfoCollector, node: *Node) ?*Node {
        switch (node.kind) {
            .function_declaration, .function_expression, .arrow_function, .method_definition => self.fn_depth -= 1,
            else => {},
        }
        return null;
    }
};

fn infoEnterThunk(ctx: *anyopaque, node: *Node) ?*Node {
    const c: *InfoCollector = @ptrCast(@alignCast(ctx));
    return c.enter(node);
}
fn infoExitThunk(ctx: *anyopaque, node: *Node) ?*Node {
    const c: *InfoCollector = @ptrCast(@alignCast(ctx));
    return c.exit(node);
}

/// Les imports/exports de `program`, dans l'ordre du source. `sem` doit être
/// l'analyse DE CE program (les bindings renvoyés en viennent).
///
/// Ne regarde que le TOP-LEVEL pour les déclarations de module (c'est la seule
/// place légale) ; le walk complet ne sert qu'à repérer `await` top-level et
/// `import.meta`, où qu'ils soient.
pub fn moduleInfo(arena: std.mem.Allocator, program: *Node, source: []const u8, sem: *Semantic) ModuleInfo {
    var imports: std.ArrayList(ImportEntry) = .empty;
    var exports: std.ArrayList(ExportEntry) = .empty;
    var stars: std.ArrayList([]const u8) = .empty;
    const scope = sem.scopes.items[0]; // scope 0 = module (créé sur `.program`)

    const bindingOf = struct {
        fn get(s: *Scope, name: []const u8) ?*Binding {
            return s.bindings.get(name);
        }
    }.get;

    for (program.kind.program.body) |stmt| switch (stmt.kind) {
        .import_declaration => |d| {
            if (d.type_only) continue; // effacé à l'émission : rien à lier
            const spec = specifierText(arena, d.source, source);
            for (d.specifiers) |s| switch (s.kind) {
                .import_default_specifier => |x| imports.append(arena, .{
                    .local = x.local.litText(source),
                    .binding = bindingOf(scope, x.local.litText(source)),
                    .specifier = spec,
                    .kind = .default,
                }) catch {},
                .import_namespace_specifier => |x| imports.append(arena, .{
                    .local = x.local.litText(source),
                    .binding = bindingOf(scope, x.local.litText(source)),
                    .specifier = spec,
                    .kind = .namespace,
                }) catch {},
                .import_specifier => |x| if (!x.type_only) imports.append(arena, .{
                    .local = x.local.litText(source),
                    .binding = bindingOf(scope, x.local.litText(source)),
                    .specifier = spec,
                    .kind = .named,
                    .imported = x.imported.litText(source),
                }) catch {},
                else => {},
            };
        },
        .export_named_declaration => |d| {
            if (d.type_only) continue;
            if (d.declaration) |decl| {
                // `export const x = …` / `export function f(){}` / `export class C{}`
                for (declaredNames(arena, decl, source)) |name| exports.append(arena, .{
                    .exported = name,
                    .kind = .local,
                    .binding = bindingOf(scope, name),
                }) catch {};
                continue;
            }
            const spec: ?[]const u8 = if (d.source) |s| specifierText(arena, s, source) else null;
            for (d.specifiers) |s| {
                const es = s.kind.export_specifier;
                if (es.type_only) continue;
                const local = es.local.litText(source);
                const exported = es.exported.litText(source);
                if (spec) |sp| {
                    exports.append(arena, .{ .exported = exported, .kind = .re_export, .specifier = sp, .imported = local }) catch {};
                } else {
                    exports.append(arena, .{ .exported = exported, .kind = .local, .binding = bindingOf(scope, local) }) catch {};
                }
            }
        },
        .export_default_declaration => |d| {
            // `export default foo;` où `foo` est un binding du module = un export
            // local, pas une expression à matérialiser (évite un `const x = x`).
            if (d.declaration.kind == .identifier) {
                if (bindingOf(scope, d.declaration.litText(source))) |b| {
                    exports.append(arena, .{ .exported = "default", .kind = .local, .binding = b }) catch {};
                    continue;
                }
            }
            exports.append(arena, .{ .exported = "default", .kind = .default_expr, .value = d.declaration }) catch {};
        },
        .export_all_declaration => |d| {
            const spec = specifierText(arena, d.source, source);
            if (d.exported) |ns| {
                exports.append(arena, .{
                    .exported = ns.litText(source),
                    .kind = .star_as,
                    .specifier = spec,
                }) catch {};
            } else stars.append(arena, spec) catch {};
        },
        else => {},
    };

    var c = InfoCollector{ .arena = arena, .sem = sem, .src = source };
    _ = walker.walk(program, .{ .ctx = &c, .enter = infoEnterThunk, .exit = infoExitThunk });

    return .{
        .imports = imports.items,
        .exports = exports.items,
        .star_exports = stars.items,
        .module_scope = scope,
        .has_top_level_await = c.tla,
        .has_import_meta = c.meta,
    };
}

/// Le specifier décodé d'un nœud source (guillemets retirés, échappements résolus).
fn specifierText(arena: std.mem.Allocator, node: *Node, source: []const u8) []const u8 {
    if (node.kind != .string_literal) return "";
    return decodeStringLiteral(arena, node.litText(source));
}

/// Les noms liés par une déclaration exportée (`export const {a, b} = o` en lie
/// deux). Réutilise la logique de patterns du semantic, en lecture seule.
fn declaredNames(arena: std.mem.Allocator, decl: *Node, source: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (decl.kind) {
        .variable_declaration => |d| for (d.declarations) |v| {
            collectPatternNames(arena, v.kind.variable_declarator.id, source, &out);
        },
        .function_declaration => |f| if (f.id) |id| out.append(arena, id.litText(source)) catch {},
        .class_declaration => |c| if (c.id) |id| out.append(arena, id.litText(source)) catch {},
        // TS : `export enum E` / `export namespace N` déclarent aussi un binding.
        .ts_enum => |e| out.append(arena, e.id.litText(source)) catch {},
        .ts_namespace => |n| out.append(arena, n.id.litText(source)) catch {},
        else => {},
    }
    return out.items;
}

fn collectPatternNames(arena: std.mem.Allocator, node: *Node, source: []const u8, out: *std.ArrayList([]const u8)) void {
    switch (node.kind) {
        .identifier => out.append(arena, node.litText(source)) catch {},
        .array_pattern => |a| for (a.elements) |el| {
            if (el) |e| collectPatternNames(arena, e, source, out);
        },
        .object_pattern => |o| for (o.properties) |p| switch (p.kind) {
            .rest_element => |r| collectPatternNames(arena, r.argument, source, out),
            .property => |pr| collectPatternNames(arena, pr.value, source, out),
            else => {},
        },
        .assignment_pattern => |a| collectPatternNames(arena, a.left, source, out),
        .rest_element => |r| collectPatternNames(arena, r.argument, source, out),
        .ts_typed => |t| collectPatternNames(arena, t.binding, source, out),
        else => {},
    }
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

// ---- module records ----

const Records = struct {
    arena: std.heap.ArenaAllocator,
    items: []const ModuleRecord,
    fn deinit(self: *Records) void {
        self.arena.deinit();
    }
};

fn records(gpa: std.mem.Allocator, src: []const u8, ts: bool) !Records {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const program = (try parser.parseWith(a, src, false, ts)).program;
    // En DEUX temps, obligatoirement : dans un `return .{ .arena = arena,
    // .items = moduleRecords(a, …) }`, l'arène est copiée dans le slot de retour
    // AVANT que `.items` n'alloue — l'allocation partirait dans la copie locale,
    // que le `deinit` de la copie retournée ne connaît pas (fuite).
    const items = moduleRecords(a, program, src);
    return .{ .arena = arena, .items = items };
}

test "moduleRecords : import / re-export / export * / import() dynamique" {
    var r = try records(std.testing.allocator,
        \\import a from './a.js';
        \\import './side-effect.css';
        \\export { b } from './b';
        \\export * from './c';
        \\const lazy = () => import('./d');
    , false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 5), r.items.len);
    // L'ordre du SOURCE est préservé.
    try std.testing.expectEqualStrings("./a.js", r.items[0].specifier);
    try std.testing.expectEqual(ModuleRecordKind.import, r.items[0].kind);
    try std.testing.expectEqualStrings("./side-effect.css", r.items[1].specifier);
    try std.testing.expectEqual(ModuleRecordKind.import, r.items[1].kind);
    try std.testing.expectEqualStrings("./b", r.items[2].specifier);
    try std.testing.expectEqual(ModuleRecordKind.re_export, r.items[2].kind);
    try std.testing.expectEqualStrings("./c", r.items[3].specifier);
    try std.testing.expectEqual(ModuleRecordKind.export_all, r.items[3].kind);
    try std.testing.expectEqualStrings("./d", r.items[4].specifier);
    try std.testing.expectEqual(ModuleRecordKind.dynamic_import, r.items[4].kind);
}

test "moduleRecords : le span pointe sur le littéral, guillemets inclus" {
    const src = "import x from './a';";
    var r = try records(std.testing.allocator, src, false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.items.len);
    try std.testing.expectEqualStrings("'./a'", src[r.items[0].start..r.items[0].end]);
}

test "moduleRecords : `export { a }` SANS `from` n'est pas une dépendance" {
    var r = try records(std.testing.allocator, "const a = 1; export { a }; export default a;", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.items.len);
}

test "moduleRecords : import() calculé et import.meta sont ignorés" {
    var r = try records(std.testing.allocator, "const u = import.meta.url; import(path); import(`./${x}`);", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.items.len);
}

test "moduleRecords : TS type-only marqué (pas une dépendance runtime)" {
    var r = try records(std.testing.allocator, "import type { T } from './t'; import { v } from './v';", true);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.items.len);
    try std.testing.expect(r.items[0].type_only);
    try std.testing.expect(!r.items[1].type_only);
}

test "moduleRecords : échappements décodés dans le specifier" {
    var r = try records(std.testing.allocator, "import a from './caf\\u00e9/\\x41';", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.items.len);
    try std.testing.expectEqualStrings("./café/A", r.items[0].specifier);
}

test "moduleRecords : code cassé -> ce qui reste lisible est récupéré" {
    // Error recovery : l'import cassé disparaît, les sains restent.
    var r = try records(std.testing.allocator, "import a from './a'; import from; import c from './c';", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.items.len);
    try std.testing.expectEqualStrings("./a", r.items[0].specifier);
    try std.testing.expectEqualStrings("./c", r.items[1].specifier);
}

test "moduleRecords : imports imbriqués (dynamique dans une fonction)" {
    var r = try records(std.testing.allocator,
        \\async function load() {
        \\  if (cond) { const m = await import("./deep/mod.ts"); return m; }
        \\}
    , false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.items.len);
    try std.testing.expectEqualStrings("./deep/mod.ts", r.items[0].specifier);
    try std.testing.expectEqual(ModuleRecordKind.dynamic_import, r.items[0].kind);
}

test "export * as ns : `ns` n'est PAS un binding local ni une référence" {
    var p = try probe(std.testing.allocator, "export * as ns from './m'; const x = 1;");
    defer p.deinit();
    // Ni déclaré (ce n'est pas `import * as ns`), ni unresolved (ce n'est pas
    // une référence) : c'est un NOM D'EXPORT, comme le `b` de `export { a as b }`.
    try std.testing.expectEqual(@as(usize, 0), p.bindingCount("ns"));
    try std.testing.expect(!p.unresolved("ns"));
    try std.testing.expectEqual(@as(usize, 0), p.diags());
}

test "export * as ns : contraste avec `import * as ns` (LUI est un binding)" {
    var p = try probe(std.testing.allocator, "import * as ns from './m'; ns.x;");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.bindingCount("ns"));
    try std.testing.expectEqual(@as(usize, 1), p.totalRefs("ns"));
}

test "import attributes : les clés ne sont ni des bindings ni des références" {
    var p = try probe(std.testing.allocator, "import d from './d.json' with { type: 'json' };");
    defer p.deinit();
    try std.testing.expect(!p.unresolved("type"));
    try std.testing.expectEqual(@as(usize, 0), p.bindingCount("type"));
    try std.testing.expectEqual(@as(usize, 0), p.diags());
}

test "moduleRecords : export * as ns -> kind export_all_as + name" {
    var r = try records(std.testing.allocator,
        \\export * from './plain';
        \\export * as ns from './named';
    , false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.items.len);
    try std.testing.expectEqual(ModuleRecordKind.export_all, r.items[0].kind);
    try std.testing.expectEqual(@as(?[]const u8, null), r.items[0].name);
    try std.testing.expectEqual(ModuleRecordKind.export_all_as, r.items[1].kind);
    try std.testing.expectEqualStrings("ns", r.items[1].name.?);
    try std.testing.expectEqualStrings("./named", r.items[1].specifier);
}

test "moduleRecords : les attributs sont exposés, décodés" {
    var r = try records(std.testing.allocator,
        \\import d from './d.json' with { type: 'json' };
        \\import './a.css' with { type: 'css' };
        \\export { x } from './x.json' with { type: 'json' };
        \\export * as data from './y.json' assert { type: 'json' };
        \\import plain from './plain.js';
    , false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 5), r.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.items[0].attributes.len);
    try std.testing.expectEqualStrings("type", r.items[0].attributes[0].key);
    try std.testing.expectEqualStrings("json", r.items[0].attributes[0].value);
    try std.testing.expectEqualStrings("css", r.items[1].attributes[0].value);
    try std.testing.expectEqualStrings("json", r.items[2].attributes[0].value);
    // `assert` : même contenu exposé, le mot-clé n'est qu'une question de syntaxe.
    try std.testing.expectEqualStrings("json", r.items[3].attributes[0].value);
    // Sans clause : slice vide, pas de null à gérer côté consommateur.
    try std.testing.expectEqual(@as(usize, 0), r.items[4].attributes.len);
}

test "moduleRecords : clé string décodée comme les valeurs" {
    var r = try records(std.testing.allocator, "import x from './y' with { 'a-b': 'v\\u0041' };", false);
    defer r.deinit();
    try std.testing.expectEqualStrings("a-b", r.items[0].attributes[0].key);
    try std.testing.expectEqualStrings("vA", r.items[0].attributes[0].value);
}

test "moduleRecords : import(src, options) reste un dynamic_import sans attributs" {
    var r = try records(std.testing.allocator, "import('./x.json', { with: { type: 'json' } });", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.items.len);
    try std.testing.expectEqual(ModuleRecordKind.dynamic_import, r.items[0].kind);
    try std.testing.expectEqualStrings("./x.json", r.items[0].specifier);
    // Les options d'un import() sont une EXPRESSION quelconque : on ne devine
    // rien (l'AST porte `ImportExpression.options` pour qui veut l'analyser).
    try std.testing.expectEqual(@as(usize, 0), r.items[0].attributes.len);
}

// ---- module info ----

const Info = struct {
    arena: std.heap.ArenaAllocator,
    info: ModuleInfo,
    fn deinit(self: *Info) void {
        self.arena.deinit();
    }
    fn exportNamed(self: *Info, name: []const u8) ?ExportEntry {
        for (self.info.exports) |e| if (std.mem.eql(u8, e.exported, name)) return e;
        return null;
    }
    fn importLocal(self: *Info, name: []const u8) ?ImportEntry {
        for (self.info.imports) |i| if (std.mem.eql(u8, i.local, name)) return i;
        return null;
    }
};

fn moduleInfoOf(gpa: std.mem.Allocator, src: []const u8, ts: bool) !Info {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const program = (try parser.parseWith(a, src, false, ts)).program;
    const sem = analyze(a, program, src);
    // En deux temps : `.arena = arena` copierait l'arène AVANT que `moduleInfo`
    // n'alloue dedans (cf. la note du helper `records`).
    const info = moduleInfo(a, program, src, sem);
    return .{ .arena = arena, .info = info };
}

test "moduleInfo : les trois formes d'import, avec leur binding" {
    var i = try moduleInfoOf(std.testing.allocator,
        \\import def from './a';
        \\import * as ns from './b';
        \\import { x, y as z } from './c';
    , false);
    defer i.deinit();
    try std.testing.expectEqual(@as(usize, 4), i.info.imports.len);

    const d = i.importLocal("def").?;
    try std.testing.expectEqual(ImportKind.default, d.kind);
    try std.testing.expectEqualStrings("./a", d.specifier);
    try std.testing.expect(d.binding != null); // renommable

    try std.testing.expectEqual(ImportKind.namespace, i.importLocal("ns").?.kind);

    const z = i.importLocal("z").?;
    try std.testing.expectEqual(ImportKind.named, z.kind);
    try std.testing.expectEqualStrings("y", z.imported); // le nom CHEZ LA SOURCE
    try std.testing.expectEqualStrings("./c", z.specifier);
}

test "moduleInfo : exports locaux (const, function, class, destructuring)" {
    var i = try moduleInfoOf(std.testing.allocator,
        \\export const a = 1;
        \\export function f() {}
        \\export class C {}
        \\export const { x, y: [z] } = o;
        \\const hidden = 2;
        \\export { hidden as pub };
    , false);
    defer i.deinit();
    for ([_][]const u8{ "a", "f", "C", "x", "z", "pub" }) |name| {
        const e = i.exportNamed(name) orelse {
            std.debug.print("export manquant: {s}\n", .{name});
            return error.MissingExport;
        };
        try std.testing.expectEqual(ExportKind.local, e.kind);
        try std.testing.expect(e.binding != null);
    }
    // `pub` pointe sur le binding `hidden` (le nom LOCAL, pas le nom public).
    try std.testing.expectEqualStrings("hidden", i.exportNamed("pub").?.binding.?.name);
}

test "moduleInfo : export default — binding existant vs expression" {
    // `export default foo` où foo est un binding -> local (pas de const inutile).
    {
        var i = try moduleInfoOf(std.testing.allocator, "const foo = 1; export default foo;", false);
        defer i.deinit();
        const e = i.exportNamed("default").?;
        try std.testing.expectEqual(ExportKind.local, e.kind);
        try std.testing.expectEqualStrings("foo", e.binding.?.name);
    }
    // Une expression -> il faudra lui fabriquer un nom.
    {
        var i = try moduleInfoOf(std.testing.allocator, "export default function () { return 1; };", false);
        defer i.deinit();
        const e = i.exportNamed("default").?;
        try std.testing.expectEqual(ExportKind.default_expr, e.kind);
        try std.testing.expect(e.value != null);
    }
}

test "moduleInfo : re-export, export * et export * as ns" {
    var i = try moduleInfoOf(std.testing.allocator,
        \\export { a, b as c } from './m';
        \\export * from './n';
        \\export * as ns from './o';
    , false);
    defer i.deinit();
    const c = i.exportNamed("c").?;
    try std.testing.expectEqual(ExportKind.re_export, c.kind);
    try std.testing.expectEqualStrings("./m", c.specifier);
    try std.testing.expectEqualStrings("b", c.imported); // le nom chez la source

    const ns = i.exportNamed("ns").?;
    try std.testing.expectEqual(ExportKind.star_as, ns.kind);
    try std.testing.expectEqualStrings("./o", ns.specifier);

    try std.testing.expectEqual(@as(usize, 1), i.info.star_exports.len);
    try std.testing.expectEqualStrings("./n", i.info.star_exports[0]);
}

test "moduleInfo : top-level await détecté, pas celui dans une fonction" {
    {
        var i = try moduleInfoOf(std.testing.allocator, "const x = await fetch('/');", false);
        defer i.deinit();
        try std.testing.expect(i.info.has_top_level_await);
    }
    {
        var i = try moduleInfoOf(std.testing.allocator, "async function f() { return await g(); }", false);
        defer i.deinit();
        try std.testing.expect(!i.info.has_top_level_await);
    }
}

test "moduleInfo : import.meta détecté" {
    var i = try moduleInfoOf(std.testing.allocator, "const u = import.meta.url;", false);
    defer i.deinit();
    try std.testing.expect(i.info.has_import_meta);
}

test "moduleInfo : `import type` n'entre pas dans la table de liaison" {
    var i = try moduleInfoOf(std.testing.allocator, "import type { T } from './t'; import { v } from './v';", true);
    defer i.deinit();
    try std.testing.expectEqual(@as(usize, 1), i.info.imports.len);
    try std.testing.expectEqualStrings("v", i.info.imports[0].local);
}

test "Binding.assigned : distingue la lecture de l'ÉCRITURE (live bindings)" {
    var p = try probe(std.testing.allocator, "export let mutable = 1; export const stable = 2; mutable = 3; stable;");
    defer p.deinit();
    const scope = p.sem.scopes.items[0];
    try std.testing.expect(scope.bindings.get("mutable").?.assigned);
    // `stable` est LU, jamais écrit.
    try std.testing.expect(!scope.bindings.get("stable").?.assigned);
}

test "Binding.assigned : ++ et += comptent comme des écritures" {
    var p = try probe(std.testing.allocator, "let a = 0; let b = 0; let c = 0; a++; b += 1; c;");
    defer p.deinit();
    const scope = p.sem.scopes.items[0];
    try std.testing.expect(scope.bindings.get("a").?.assigned);
    try std.testing.expect(scope.bindings.get("b").?.assigned);
    try std.testing.expect(!scope.bindings.get("c").?.assigned);
}

test "expression de classe nommée : le nom est lié DANS le corps, nulle part ailleurs" {
    // Miroir de `const f = function foo() { return foo; }` (déjà géré).
    {
        var p = try probe(std.testing.allocator, "const C = class Bar { m() { return Bar; } };");
        defer p.deinit();
        try std.testing.expect(!p.unresolved("Bar"));
        try std.testing.expectEqual(@as(usize, 1), p.totalRefs("Bar"));
    }
    // Mais PAS visible à l'extérieur : `Bar` n'existe que dans la classe.
    {
        var p = try probe(std.testing.allocator, "const C = class Bar {}; Bar;");
        defer p.deinit();
        try std.testing.expect(p.unresolved("Bar"));
    }
    // Une DÉCLARATION de classe garde son comportement (nom visible dehors).
    {
        var p = try probe(std.testing.allocator, "class Baz { m() { return Baz; } } Baz;");
        defer p.deinit();
        try std.testing.expect(!p.unresolved("Baz"));
    }
}
