//! Transformer : AST -> AST modifié. Passe ENTRE parse et print
//! (`parse → transform → print`). Le parser et le printer ne changent pas ; les
//! nœuds fabriqués s'allouent dans l'arena, comme `toPattern`.
//!
//! Deux briques :
//!   1. Le WALKER `walk(node, visitor)` : visite chaque nœud + ses enfants.
//!      Le `visitor` = pattern « vtable manuelle » (pointeur de contexte + fns) :
//!        - `enter(node)` : appelé AVANT les enfants. Retourne un remplaçant
//!          optionnel ; s'il en renvoie un, on SUBSTITUE et on NE redescend PAS
//!          dedans (au transform de gérer). `null` = garder + descendre.
//!        - `exit(node)` : appelé APRÈS les enfants (bottom-up). Idéal pour le
//!          fold : les fils sont déjà réduits, donc `(1 + 2) * 3` devient `9` en
//!          une seule passe.
//!   2. Les TRANSFORMS (dans `exit`) : constant folding + simplification booléenne.
//!
//! Convention des nœuds SYNTHÉTIQUES : le printer émet les littéraux via leur
//! span source, or un nœud créé ici n'a pas de span valide. Les littéraux
//! number/boolean portent donc un `synthetic_text` (cf. `ast.Literal`) : le
//! printer émet ce texte s'il existe. C'est LA convention pour toute création de
//! nœud littéral par une transformation.

const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;

// Le walker générique est partagé (cf. walker.zig).
const walker = @import("walker.zig");
const Visitor = walker.Visitor;
const walk = walker.walk;
// Le DCE scope-aware utilise l'analyse semantic (scopes/bindings/références).
const semantic = @import("semantic.zig");

// ------------------------------------------------------------------ transforms

const Transform = struct {
    source: []const u8,
    arena: std.mem.Allocator,
    count: usize = 0,

    fn newNode(self: *Transform, orig: *const Node, kind: Node.Kind) ?*Node {
        const n = self.arena.create(Node) catch return null;
        n.* = .{ .start = orig.start, .end = orig.end, .kind = kind };
        return n;
    }

    fn makeNumber(self: *Transform, orig: *const Node, text: []const u8) ?*Node {
        return self.newNode(orig, .{ .number_literal = .{ .synthetic_text = text } });
    }
    fn makeBool(self: *Transform, orig: *const Node, value: bool) ?*Node {
        return self.newNode(orig, .{ .boolean_literal = .{ .synthetic_text = if (value) "true" else "false" } });
    }
    fn emptyBlock(self: *Transform, orig: *const Node) ?*Node {
        return self.newNode(orig, .{ .block_statement = .{ .body = &.{} } });
    }

    /// La passe `exit` : bottom-up. Renvoie un remplaçant, ou null (garder).
    fn exit(self: *Transform, node: *Node) ?*Node {
        switch (node.kind) {
            .binary_expression => |b| {
                // Constant folding : `+ - *` sur deux NumberLiteral, résultat
                // entier >= 0. On EXCLUT `/` `%` (division par zéro, float) et les
                // strings. On exclut les floats (0.1 + 0.2 = 0.30000000000000004)
                // via `@trunc(r) == r`, et les résultats négatifs car un
                // NumberLiteral JS est toujours >= 0 (`-4` = `unary(neg, 4)`) :
                // synthétiser un littéral négatif casserait l'impression (`--2`).
                if (b.left.kind == .number_literal and b.right.kind == .number_literal and
                    (b.operator == .add or b.operator == .sub or b.operator == .mul))
                {
                    if (numValue(b.left.litText(self.source))) |lv| {
                        if (numValue(b.right.litText(self.source))) |rv| {
                            const r = switch (b.operator) {
                                .add => lv + rv,
                                .sub => lv - rv,
                                .mul => lv * rv,
                                else => unreachable,
                            };
                            if (std.math.isFinite(r) and r >= 0 and @trunc(r) == r and r <= 9007199254740992.0) {
                                const txt = std.fmt.allocPrint(self.arena, "{d}", .{@as(u64, @intFromFloat(r))}) catch return null;
                                if (self.makeNumber(node, txt)) |repl| {
                                    self.count += 1;
                                    return repl;
                                }
                            }
                        }
                    }
                }
                // Court-circuit booléen : `true && x`->`x`, `false && x`->`false`,
                // `true || x`->`true`, `false || x`->`x`.
                if (b.operator == .logical_and or b.operator == .logical_or) {
                    if (boolValue(b.left, self.source)) |lb| {
                        self.count += 1;
                        return switch (b.operator) {
                            .logical_and => if (lb) b.right else b.left,
                            .logical_or => if (lb) b.left else b.right,
                            else => unreachable,
                        };
                    }
                }
            },
            .unary_expression => |u| {
                // !true -> false, !false -> true.
                if (u.operator == .not) {
                    if (boolValue(u.operand, self.source)) |bv| {
                        if (self.makeBool(node, !bv)) |repl| {
                            self.count += 1;
                            return repl;
                        }
                    }
                }
            },
            .if_statement => |s| {
                // if (true) A else B -> A ; if (false) A else B -> B (ou {} sinon).
                if (boolValue(s.@"test", self.source)) |bv| {
                    self.count += 1;
                    if (bv) return s.consequent;
                    return s.alternate orelse self.emptyBlock(node);
                }
            },
            else => {},
        }
        return null;
    }
};

fn exitThunk(ctx: *anyopaque, node: *Node) ?*Node {
    const t: *Transform = @ptrCast(@alignCast(ctx));
    return t.exit(node);
}

/// Valeur booléenne d'un nœud, ou null si ce n'est pas un littéral booléen.
fn boolValue(node: *const Node, source: []const u8) ?bool {
    return switch (node.kind) {
        .boolean_literal => std.mem.eql(u8, node.litText(source), "true"),
        else => null,
    };
}

/// Décode un littéral numérique JS en f64. Gère `0x`/`0b`/`0o`, les séparateurs
/// `_`, les décimales et l'exposant. Renvoie null si non décodable.
fn numValue(text: []const u8) ?f64 {
    if (text.len >= 2 and text[0] == '0') switch (text[1]) {
        'x', 'X' => return radixValue(text[2..], 16),
        'b', 'B' => return radixValue(text[2..], 2),
        'o', 'O' => return radixValue(text[2..], 8),
        else => {},
    };
    // Décimal : on retire les `_` puis parseFloat.
    var buf: [96]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (c == '_') continue;
        if (n >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    return std.fmt.parseFloat(f64, buf[0..n]) catch null;
}

fn radixValue(digits: []const u8, base: u8) ?f64 {
    var acc: f64 = 0;
    var any = false;
    for (digits) |c| {
        if (c == '_') continue;
        const d = std.fmt.charToDigit(c, base) catch return null;
        acc = acc * @as(f64, @floatFromInt(base)) + @as(f64, @floatFromInt(d));
        any = true;
    }
    return if (any) acc else null;
}

/// Un init « sûr » à supprimer (aucun side-effect possible) : littéral, fonction,
/// arrow, ou absent. Volontairement conservateur : `const x = f()` est gardé.
fn safeInit(init: ?*const Node) bool {
    const n = init orelse return true; // pas d'init (let x;) -> undefined, sûr
    return switch (n.kind) {
        .number_literal, .bigint_literal, .string_literal, .boolean_literal, .null_literal, .regex_literal, .function_expression, .arrow_function => true,
        else => false,
    };
}

/// Le nom lié par un statement candidat au DCE (single-declarator const/let, ou
/// function declaration). Null si non candidat.
fn deadCandidateName(source: []const u8, stmt: *const Node) ?[]const u8 {
    switch (stmt.kind) {
        .variable_declaration => |d| {
            if (d.kind == .@"var") return null; // on ne touche pas aux var
            if (d.declarations.len != 1) return null; // multi-déclarateur : prudence
            const decl = d.declarations[0].kind.variable_declarator;
            if (decl.id.kind != .identifier) return null; // pas de pattern
            if (!safeInit(decl.init)) return null;
            return decl.id.text(source);
        },
        .function_declaration => |f| {
            const id = f.id orelse return null;
            return id.text(source);
        },
        else => return null,
    }
}

/// Dead code elimination scope-aware au niveau MODULE : supprime les bindings
/// const/let/function sans AUCUNE référence, non exportés (un `export { x }`
/// compte comme une référence à `x`), et à l'init sûr. Renvoie le nb supprimés.
fn dce(program: *Node, source: []const u8, arena: std.mem.Allocator) usize {
    const sem = semantic.analyze(arena, program, source);
    if (sem.scopes.items.len == 0) return 0;
    const module = sem.scopes.items[0]; // scope 0 = module

    var kept: std.ArrayList(*Node) = .empty;
    var removed: usize = 0;
    const body = program.kind.program.body;
    for (body) |stmt| {
        var dead = false;
        if (deadCandidateName(source, stmt)) |name| {
            if (module.bindings.get(name)) |b| {
                // const/let/function uniquement, zéro référence (les exports en
                // créent une), et l'init sûr (déjà vérifié pour les variables).
                const eligible = switch (b.kind) {
                    .const_, .let_, .function_ => true,
                    else => false,
                };
                if (eligible and b.references.items.len == 0) dead = true;
            }
        }
        if (dead) {
            removed += 1;
        } else {
            kept.append(arena, stmt) catch return removed;
        }
    }
    if (removed > 0) program.kind.program.body = kept.toOwnedSlice(arena) catch body;
    return removed;
}

// ------------------------------------------------------------------ stripTypes

/// Efface le TypeScript : `parse(ts) → stripTypes → print` = JS pur qui reparse
/// en mode js. Le juge de paix du chantier TS. Passe walker (`exit`, bottom-up) :
/// - `x as T` / `x satisfies T` / `x!` → l'expression (le type disparaît) ;
/// - `x: T` (ts_typed) → le binding seul ;
/// - annotations de retour / type params / types de champ → effacés (champs à null) ;
/// - déclarations type-only (`type` / `interface`, même exportées) → retirées des
///   listes de statements (program / block / switch-case).
const Strip = struct {
    arena: std.mem.Allocator,
    source: []const u8,

    // ---- fabriques de nœuds synthétiques (span 0..0 ; le printer les émet via
    // `litText` ; les structuraux n'utilisent jamais leur span) ----
    fn mk(self: *Strip, kind: Node.Kind) *Node {
        const n = self.arena.create(Node) catch unreachable;
        n.* = .{ .start = 0, .end = 0, .kind = kind };
        return n;
    }
    fn ident(self: *Strip, name: []const u8) *Node {
        return self.mk(.{ .identifier = .{ .synthetic_text = name } });
    }
    fn strLit(self: *Strip, quoted: []const u8) *Node {
        return self.mk(.{ .string_literal = .{ .synthetic_text = quoted } });
    }
    fn numLit(self: *Strip, text: []const u8) *Node {
        return self.mk(.{ .number_literal = .{ .synthetic_text = text } });
    }
    fn exprStmt(self: *Strip, e: *Node) *Node {
        return self.mk(.{ .expression_statement = .{ .expression = e } });
    }
    fn assign(self: *Strip, target: *Node, value: *Node) *Node {
        return self.mk(.{ .assignment_expression = .{ .operator = .assign, .target = target, .value = value } });
    }
    fn computedMember(self: *Strip, obj: *Node, prop: *Node) *Node {
        return self.mk(.{ .member_expression = .{ .object = obj, .property = prop, .computed = true, .optional = false } });
    }
    fn dotMember(self: *Strip, obj: *Node, name: []const u8) *Node {
        return self.mk(.{ .member_expression = .{ .object = obj, .property = self.ident(name), .computed = false, .optional = false } });
    }
    /// Guillemets doubles + échappement de `\` et `"` (pour les clés/noms de membres).
    fn quote(self: *Strip, raw: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        out.append(self.arena, '"') catch unreachable;
        for (raw) |c| switch (c) {
            '\\' => out.appendSlice(self.arena, "\\\\") catch unreachable,
            '"' => out.appendSlice(self.arena, "\\\"") catch unreachable,
            else => out.append(self.arena, c) catch unreachable,
        };
        out.append(self.arena, '"') catch unreachable;
        return out.toOwnedSlice(self.arena) catch unreachable;
    }

    fn exit(self: *Strip, node: *Node) ?*Node {
        switch (node.kind) {
            .ts_as_expression => |t| return t.expr,
            .ts_satisfies_expression => |t| return t.expr,
            .ts_non_null_expression => |t| return t.expr,
            .ts_typed => |t| return t.binding,
            .function_declaration, .function_expression => |*f| {
                f.return_type = null;
                f.type_params = &.{};
                f.params = self.stripParamProps(f.params, null);
            },
            .arrow_function => |*f| {
                f.return_type = null;
                f.params = self.stripParamProps(f.params, null); // params génériques, jamais de props
            },
            .method_definition => |*m| {
                m.return_type = null;
                m.type_params = &.{};
                // Parameter properties : le CONSTRUCTEUR gagne `this.x = x` en tête
                // (après `super(...)` s'il existe) ; le modificateur s'efface du param.
                const body_block = if (m.body.kind == .block_statement) m.body else null;
                m.params = self.stripParamProps(m.params, if (m.kind == .constructor) body_block else null);
            },
            .property_definition => |*p| {
                p.type_annotation = null;
                p.optional = false;
            },
            .class_declaration, .class_expression => |*c| {
                c.type_params = &.{};
                c.super_type_args = &.{};
                c.implements = &.{};
            },
            // TS phase 2 : arguments de type d'un appel générique -> effacés.
            .call_expression => |*c| c.type_args = &.{},
            .new_expression => |*n| n.type_args = &.{},
            .tagged_template_expression => |*t| t.type_args = &.{},
            // Imports/exports : retire les spécificateurs type-only mixtes (`import
            // { type A, B }` -> `import { B }`). Si tout devient type-only, on marque
            // la déclaration pour la retirer (dropTypeOnly, via `type_only`).
            .import_declaration => |*imp| if (!imp.type_only) {
                const kept = self.filterValueSpecifiers(imp.specifiers);
                if (imp.specifiers.len > 0 and kept.len == 0) imp.type_only = true else imp.specifiers = kept;
            },
            .export_named_declaration => |*e| if (!e.type_only and e.declaration == null and e.source == null) {
                const kept = self.filterValueSpecifiers(e.specifiers);
                if (e.specifiers.len > 0 and kept.len == 0) e.type_only = true else e.specifiers = kept;
            },
            // Conteneurs de statements : retire le type-only ET expanse les
            // enum/namespace (émission phase 3) — bottom-up, les enfants sont prêts.
            .program => |*p| p.body = self.rewriteBody(p.body),
            .block_statement => |*b| b.body = self.rewriteBody(b.body),
            .ts_namespace => |*n| n.body = self.rewriteBody(n.body),
            .switch_case => |*c| c.consequent = self.rewriteBody(c.consequent),
            else => {},
        }
        return null;
    }

    /// Retire les statements type-only d'une liste (déclaration `type`/`interface`,
    /// ou `export` d'une telle déclaration).
    fn dropTypeOnly(self: *Strip, body: []*Node) []*Node {
        var any = false;
        for (body) |s| if (isTypeOnly(s)) {
            any = true;
        };
        if (!any) return body; // rien à retirer : on garde la slice telle quelle
        var kept: std.ArrayList(*Node) = .empty;
        for (body) |s| {
            if (!isTypeOnly(s)) kept.append(self.arena, s) catch return body;
        }
        return kept.toOwnedSlice(self.arena) catch body;
    }

    /// Retire les spécificateurs `import { type A, B }` type-only, garde le reste
    /// (default/namespace + spécificateurs de valeur).
    fn filterValueSpecifiers(self: *Strip, specs: []*Node) []*Node {
        var any_type = false;
        for (specs) |s| if (specIsTypeOnly(s)) {
            any_type = true;
        };
        if (!any_type) return specs;
        var kept: std.ArrayList(*Node) = .empty;
        for (specs) |s| if (!specIsTypeOnly(s)) {
            kept.append(self.arena, s) catch return specs;
        };
        return kept.toOwnedSlice(self.arena) catch specs;
    }

    // ---- émission phase 3 : réécriture d'une liste de statements ----

    /// Retire le type-only ET expanse enum/namespace (émission) dans une liste.
    fn rewriteBody(self: *Strip, body: []*Node) []*Node {
        var needs = false;
        for (body) |s| if (isTypeOnly(s) or (self.emitDeclaration(s) != null)) {
            needs = true;
        };
        if (!needs) return body;
        var out: std.ArrayList(*Node) = .empty;
        for (body) |s| {
            if (isTypeOnly(s)) continue;
            if (self.emitDeclaration(s)) |stmts| {
                out.appendSlice(self.arena, stmts) catch {};
            } else out.append(self.arena, s) catch {};
        }
        return out.toOwnedSlice(self.arena) catch body;
    }

    /// Si `stmt` est un enum/namespace (nu ou exporté), renvoie les statements JS
    /// émis ; sinon null (statement gardé tel quel).
    fn emitDeclaration(self: *Strip, stmt: *Node) ?[]*Node {
        switch (stmt.kind) {
            .ts_enum => return self.emitEnum(stmt, false),
            .ts_namespace => return self.emitNamespace(stmt, false),
            .export_named_declaration => |e| if (e.declaration) |d| switch (d.kind) {
                .ts_enum => return self.emitEnum(d, true),
                .ts_namespace => return self.emitNamespace(d, true),
                else => return null,
            } else return null,
            else => return null,
        }
    }

    // ---- ENUM ----

    /// enum E { … } -> `var E; (function(E){ … })(E || (E = {}));`. String members :
    /// pas de reverse mapping. Numériques : `E[E["A"] = v] = "A"`.
    fn emitEnum(self: *Strip, enum_node: *Node, is_export: bool) []*Node {
        const e = enum_node.kind.ts_enum;
        const name = e.id.litText(self.source);

        // 1) var E;  (ou export var E;)
        const declr = self.mk(.{ .variable_declarator = .{ .id = self.ident(name), .init = null } });
        var decls = self.arena.alloc(*Node, 1) catch unreachable;
        decls[0] = declr;
        var var_stmt = self.mk(.{ .variable_declaration = .{ .kind = .@"var", .declarations = decls } });
        if (is_export) var_stmt = self.mk(.{ .export_named_declaration = .{ .declaration = var_stmt, .specifiers = &.{}, .source = null } });

        // 2) le corps de l'IIFE.
        var values: std.StringHashMapUnmanaged(f64) = .empty;
        var next: f64 = 0;
        var body: std.ArrayList(*Node) = .empty;
        for (e.members) |mem| {
            const m = mem.kind.ts_enum_member;
            const key_quoted = if (m.name.kind == .string_literal) m.name.text(self.source) else self.quote(m.name.text(self.source));
            const name_raw = if (m.name.kind == .string_literal) unquote(m.name.text(self.source)) else m.name.text(self.source);

            var is_string = false;
            var value_node: *Node = undefined;
            if (m.initializer) |init| {
                if (init.kind == .string_literal) {
                    is_string = true;
                    value_node = init;
                } else switch (self.evalConst(init, &values)) {
                    .number => |n| {
                        value_node = self.numLit(self.fmtNum(n));
                        next = n + 1;
                        values.put(self.arena, name_raw, n) catch {};
                    },
                    .non_const => {
                        value_node = init; // émet l'expression telle quelle
                        next += 1;
                    },
                }
            } else { // auto-incrément
                value_node = self.numLit(self.fmtNum(next));
                values.put(self.arena, name_raw, next) catch {};
                next += 1;
            }

            if (is_string) {
                // E["A"] = "a";  (PAS de reverse mapping pour les string enums)
                const target = self.computedMember(self.ident(name), self.strLit(key_quoted));
                body.append(self.arena, self.exprStmt(self.assign(target, value_node))) catch {};
            } else {
                // E[E["A"] = v] = "A";
                const fwd = self.assign(self.computedMember(self.ident(name), self.strLit(key_quoted)), value_node);
                const rev = self.assign(self.computedMember(self.ident(name), fwd), self.strLit(self.quote(name_raw)));
                body.append(self.arena, self.exprStmt(rev)) catch {};
            }
        }

        const iife_stmt = self.iife(name, body.toOwnedSlice(self.arena) catch &.{});
        var out = self.arena.alloc(*Node, 2) catch unreachable;
        out[0] = var_stmt;
        out[1] = iife_stmt;
        return out;
    }

    /// `(function(N){ <body> })(N || (N = {}));`
    fn iife(self: *Strip, name: []const u8, body: []*Node) *Node {
        var params = self.arena.alloc(*Node, 1) catch unreachable;
        params[0] = self.ident(name);
        const func = self.mk(.{ .function_expression = .{ .id = null, .params = params, .body = self.mk(.{ .block_statement = .{ .body = body } }), .is_async = false, .is_generator = false } });
        // argument : `N || (N = {})`
        const empty_obj = self.mk(.{ .object_expression = .{ .properties = &.{} } });
        const arg = self.mk(.{ .binary_expression = .{ .operator = .logical_or, .left = self.ident(name), .right = self.assign(self.ident(name), empty_obj) } });
        var args = self.arena.alloc(*Node, 1) catch unreachable;
        args[0] = arg;
        return self.exprStmt(self.mk(.{ .call_expression = .{ .callee = func, .arguments = args, .optional = false } }));
    }

    const ConstVal = union(enum) { number: f64, non_const };

    /// Évalue un initialiseur d'enum constant (nombres, unaires, binaires arithm./
    /// bitwise/shift, réf à un membre antérieur). Réutilise `numValue` (le folder).
    fn evalConst(self: *Strip, n: *const Node, values: *std.StringHashMapUnmanaged(f64)) ConstVal {
        switch (n.kind) {
            .number_literal => return if (numValue(n.litText(self.source))) |v| .{ .number = v } else .non_const,
            .unary_expression => |u| {
                const v = self.evalConst(u.operand, values);
                if (v != .number) return .non_const;
                return switch (u.operator) {
                    .neg => .{ .number = -v.number },
                    .pos => .{ .number = v.number },
                    .bitwise_not => .{ .number = @floatFromInt(~toI32(v.number)) },
                    else => .non_const,
                };
            },
            .binary_expression => |b| {
                const l = self.evalConst(b.left, values);
                const r = self.evalConst(b.right, values);
                if (l != .number or r != .number) return .non_const;
                return if (applyBinop(b.operator, l.number, r.number)) |res| .{ .number = res } else .non_const;
            },
            .identifier => return if (values.get(n.litText(self.source))) |v| .{ .number = v } else .non_const,
            .member_expression => |m| {
                if (!m.computed and m.property.kind == .identifier)
                    if (values.get(m.property.litText(self.source))) |v| return .{ .number = v };
                return .non_const;
            },
            else => return .non_const,
        }
    }

    fn fmtNum(self: *Strip, n: f64) []const u8 {
        if (std.math.isFinite(n) and @trunc(n) == n and @abs(n) < 1e15)
            return std.fmt.allocPrint(self.arena, "{d}", .{@as(i64, @intFromFloat(n))}) catch "0";
        return std.fmt.allocPrint(self.arena, "{d}", .{n}) catch "0";
    }

    // ---- NAMESPACE ----

    /// namespace N { … } -> `var N; (function(N){ … })(N || (N = {}));`. `export
    /// const x = v` -> `N.x = v` ; `export function/class` -> décl + `N.name = name`.
    fn emitNamespace(self: *Strip, ns_node: *Node, is_export: bool) []*Node {
        const ns = ns_node.kind.ts_namespace;
        const name = ns.id.litText(self.source);

        const declr = self.mk(.{ .variable_declarator = .{ .id = self.ident(name), .init = null } });
        var decls = self.arena.alloc(*Node, 1) catch unreachable;
        decls[0] = declr;
        var var_stmt = self.mk(.{ .variable_declaration = .{ .kind = .@"var", .declarations = decls } });
        if (is_export) var_stmt = self.mk(.{ .export_named_declaration = .{ .declaration = var_stmt, .specifiers = &.{}, .source = null } });

        var body: std.ArrayList(*Node) = .empty;
        for (ns.body) |s| self.emitNamespaceMember(name, s, &body);

        const iife_stmt = self.iife(name, body.toOwnedSlice(self.arena) catch &.{});
        var out = self.arena.alloc(*Node, 2) catch unreachable;
        out[0] = var_stmt;
        out[1] = iife_stmt;
        return out;
    }

    fn emitNamespaceMember(self: *Strip, ns: []const u8, s: *Node, out: *std.ArrayList(*Node)) void {
        switch (s.kind) {
            .export_named_declaration => |e| if (e.declaration) |d| switch (d.kind) {
                .variable_declaration => |v| {
                    // export const x = 1, y = 2 -> N.x = 1; N.y = 2;
                    for (v.declarations) |dn| {
                        const decl = dn.kind.variable_declarator;
                        if (decl.id.kind == .identifier and decl.init != null)
                            out.append(self.arena, self.exprStmt(self.assign(self.dotMember(self.ident(ns), decl.id.litText(self.source)), decl.init.?))) catch {};
                    }
                },
                .function_declaration => |f| if (f.id) |id| { // décl + N.f = f
                    out.append(self.arena, d) catch {};
                    out.append(self.arena, self.exprStmt(self.assign(self.dotMember(self.ident(ns), id.litText(self.source)), self.ident(id.litText(self.source))))) catch {};
                },
                .class_declaration => |c| if (c.id) |id| {
                    out.append(self.arena, d) catch {};
                    out.append(self.arena, self.exprStmt(self.assign(self.dotMember(self.ident(ns), id.litText(self.source)), self.ident(id.litText(self.source))))) catch {};
                },
                else => {}, // autres exports : ignorés (cas complexe -> diagnostic au parse)
            },
            .ts_namespace, .ts_enum => {}, // imbriqué : diagnostiqué au parse, non émis
            else => out.append(self.arena, s) catch {}, // membre non exporté : gardé
        }
    }

    // ---- PARAMETER PROPERTIES ----

    /// Déballe les `ts_param_property` d'une liste de params (le param nu ressort) ;
    /// si `body_block` (constructeur), préfixe `this.x = x` en tête (après super()).
    fn stripParamProps(self: *Strip, params: []*Node, body_block: ?*Node) []*Node {
        var any = false;
        for (params) |p| if (p.kind == .ts_param_property) {
            any = true;
        };
        if (!any) return params;
        var new_params: std.ArrayList(*Node) = .empty;
        var assigns: std.ArrayList(*Node) = .empty;
        for (params) |p| {
            if (p.kind == .ts_param_property) {
                const inner = p.kind.ts_param_property.param;
                new_params.append(self.arena, inner) catch {};
                if (paramPropName(inner)) |nm| {
                    const nm_text = nm.litText(self.source);
                    assigns.append(self.arena, self.exprStmt(self.assign(self.dotMember(self.mk(.this_expression), nm_text), self.ident(nm_text)))) catch {};
                }
            } else new_params.append(self.arena, p) catch {};
        }
        if (body_block) |bb| self.prependAssigns(bb, assigns.items);
        return new_params.toOwnedSlice(self.arena) catch params;
    }

    /// Insère les assignations en tête d'un bloc — APRÈS `super(...)` s'il ouvre le corps.
    fn prependAssigns(self: *Strip, block: *Node, assigns: []*Node) void {
        if (assigns.len == 0) return;
        const b = block.kind.block_statement;
        var out: std.ArrayList(*Node) = .empty;
        var i: usize = 0;
        if (b.body.len > 0 and isSuperCall(b.body[0])) {
            out.append(self.arena, b.body[0]) catch {};
            i = 1;
        }
        out.appendSlice(self.arena, assigns) catch {};
        while (i < b.body.len) : (i += 1) out.append(self.arena, b.body[i]) catch {};
        block.kind.block_statement.body = out.toOwnedSlice(self.arena) catch b.body;
    }
};

/// Nom lié par un param (identifiant, ou `x = def` -> x). Null si pattern.
fn paramPropName(param: *Node) ?*Node {
    return switch (param.kind) {
        .identifier => param,
        .assignment_pattern => |a| if (a.left.kind == .identifier) a.left else null,
        .ts_typed => |t| paramPropName(t.binding), // défensif (normalement déjà stripé)
        else => null,
    };
}

fn isSuperCall(stmt: *const Node) bool {
    if (stmt.kind != .expression_statement) return false;
    const e = stmt.kind.expression_statement.expression;
    return e.kind == .call_expression and e.kind.call_expression.callee.kind == .super_expression;
}

/// Retire les guillemets d'un littéral string (`"a-b"` -> `a-b`).
fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2) return s[1 .. s.len - 1];
    return s;
}

/// JS ToInt32 (simplifié, valeurs d'enum raisonnables).
fn toI32(f: f64) i32 {
    if (!std.math.isFinite(f) or @abs(f) >= 9.007199254740992e15) return 0;
    return @truncate(@as(i64, @intFromFloat(@trunc(f))));
}
fn toU32(f: f64) u32 {
    return @bitCast(toI32(f));
}

/// Applique un opérateur binaire à deux nombres (sémantique JS int32 pour bitwise/shift).
fn applyBinop(op: ast.BinaryOp, l: f64, r: f64) ?f64 {
    return switch (op) {
        .add => l + r,
        .sub => l - r,
        .mul => l * r,
        .div => if (r == 0) null else l / r,
        .rem => if (r == 0) null else @rem(l, r),
        .band => @floatFromInt(toI32(l) & toI32(r)),
        .bor => @floatFromInt(toI32(l) | toI32(r)),
        .bxor => @floatFromInt(toI32(l) ^ toI32(r)),
        .shl => @floatFromInt(toI32(l) << @intCast(toU32(r) & 31)),
        .shr => @floatFromInt(toI32(l) >> @intCast(toU32(r) & 31)),
        .ushr => @floatFromInt(toU32(l) >> @intCast(toU32(r) & 31)),
        else => null,
    };
}

fn specIsTypeOnly(node: *const Node) bool {
    return switch (node.kind) {
        .import_specifier => |s| s.type_only,
        .export_specifier => |s| s.type_only,
        else => false,
    };
}

fn isTypeOnly(node: *const Node) bool {
    return switch (node.kind) {
        .ts_type_alias, .ts_interface => true,
        .import_declaration => |imp| imp.type_only, // `import type …` (entier, ou vidé)
        .export_named_declaration => |e| e.type_only or (if (e.declaration) |d| isTypeOnly(d) else false),
        else => false,
    };
}

fn stripExitThunk(ctx: *anyopaque, node: *Node) ?*Node {
    const s: *Strip = @ptrCast(@alignCast(ctx));
    return s.exit(node);
}

/// Efface toutes les annotations/déclarations TypeScript de `program` (en place).
/// La sortie est du JS pur (reparse en mode js, semantic propre).
pub fn stripTypes(program: *Node, source: []const u8, arena: std.mem.Allocator) void {
    var s = Strip{ .arena = arena, .source = source };
    const v = Visitor{ .ctx = &s, .exit = stripExitThunk };
    _ = walk(program, v);
}

/// Applique les transformations à `program` (en place, nœuds dans `arena`).
/// Renvoie le nombre de nœuds foldés/simplifiés/supprimés.
pub fn transform(program: *Node, source: []const u8, arena: std.mem.Allocator) usize {
    // 1) fold + simplification booléenne (bottom-up). Peut supprimer des
    //    références (ex. `if (false) use(x)`), ce qui rend plus de code mort.
    var t = Transform{ .source = source, .arena = arena };
    const v = Visitor{ .ctx = &t, .exit = exitThunk };
    _ = walk(program, v);
    // 2) DCE scope-aware au niveau module (semantic recalculé sur l'AST à jour).
    return t.count + dce(program, source, arena);
}

// ------------------------------------------------------------------ tests

const parser = @import("parser.zig");
const printer = @import("printer.zig");

/// parse -> transform -> print. Renvoie le JS résultant.
fn transformSource(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const program = (try parser.parse(arena.allocator(), src)).program;
    _ = transform(program, src, arena.allocator());
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try printer.print(program, src, &out, gpa);
    return out.toOwnedSlice(gpa);
}

fn expectTransform(gpa: std.mem.Allocator, src: []const u8, expected: []const u8) !void {
    const out = try transformSource(gpa, src);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

// NB : on utilise des assignations (cibles globales) plutôt que `const x = …`
// pour isoler le FOLD du DCE (qui supprimerait un `const x` inutilisé).
test "constant folding : + - * entiers, bottom-up" {
    const gpa = std.testing.allocator;
    try expectTransform(gpa, "x = 1 + 2 * 3;", "x = 7;\n");
    try expectTransform(gpa, "y = (1 + 2) * 3;", "y = 9;\n"); // bottom-up
    try expectTransform(gpa, "z = 10 - 3 - 2;", "z = 5;\n");
    try expectTransform(gpa, "a = 0xFF + 1;", "a = 256;\n"); // hex
    try expectTransform(gpa, "a = 1_000 * 2;", "a = 2000;\n"); // séparateurs
}

test "constant folding : cas NON foldés" {
    const gpa = std.testing.allocator;
    try expectTransform(gpa, "1 + x;", "1 + x;\n"); // un seul littéral
    try expectTransform(gpa, "0.1 + 0.2;", "0.1 + 0.2;\n"); // float non entier
    try expectTransform(gpa, "5 - 8;", "5 - 8;\n"); // résultat négatif
    try expectTransform(gpa, "6 / 2;", "6 / 2;\n"); // division exclue
    try expectTransform(gpa, "'a' + 'b';", "'a' + 'b';\n"); // strings exclues
}

test "simplification booléenne" {
    const gpa = std.testing.allocator;
    try expectTransform(gpa, "z = true && getX();", "z = getX();\n");
    try expectTransform(gpa, "false && side();", "false;\n");
    try expectTransform(gpa, "true || other();", "true;\n");
    try expectTransform(gpa, "false || fallback();", "fallback();\n");
    try expectTransform(gpa, "b = !true;", "b = false;\n");
    try expectTransform(gpa, "c = !false;", "c = true;\n");
    try expectTransform(gpa, "if (true) { a(); } else { b(); }", "{\n  a();\n}\n");
    try expectTransform(gpa, "if (false) a(); else b();", "b();\n");
    try expectTransform(gpa, "if (false) a();", "{}\n");
}

test "walk : idempotent + compteur" {
    const gpa = std.testing.allocator;
    // Rien à fold ni à supprimer (exporté) -> inchangé.
    try expectTransform(gpa, "export function f(a, b) { return a + b; }", "export function f(a, b) {\n  return a + b;\n}\n");
    // Le compteur reflète le nombre de folds : `1 + 2 * 3` -> 2 (le `*` puis le `+`).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const src = "x = 1 + 2 * 3;"; // assignation : pas de DCE, juste 2 folds
    const program = (try parser.parse(arena.allocator(), src)).program;
    try std.testing.expectEqual(@as(usize, 2), transform(program, src, arena.allocator()));
    // Rien à fold, init non-sûr -> compteur 0.
    const src2 = "const y = a + b; use(y);";
    const p2 = (try parser.parse(arena.allocator(), src2)).program;
    try std.testing.expectEqual(@as(usize, 0), transform(p2, src2, arena.allocator()));
}

test "DCE scope-aware : supprime un binding module mort, garde l'exporté" {
    const gpa = std.testing.allocator;
    try expectTransform(gpa, "const used = 1; const dead = 2; export { used };", "const used = 1;\nexport { used };\n");
    // fonction morte supprimée ; utilisée gardée.
    try expectTransform(gpa, "function dead() {} function live() {} live();", "function live() {}\nlive();\n");
    // init non-sûr (appel) -> gardé (side-effect possible).
    try expectTransform(gpa, "const x = f();", "const x = f();\n");
    // var jamais touché.
    try expectTransform(gpa, "var unused = 1;", "var unused = 1;\n");
    // fold PUIS dce : `if (false) use(dead)` retire la réf -> dead meurt.
    try expectTransform(gpa, "const dead = 1; if (false) use(dead);", "{}\n");
}

// ------------------------------------------------------------------ tests stripTypes

/// parse(TS) → stripTypes → print. Renvoie le JS pur résultant.
fn stripSource(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const program = (try parser.parseWith(arena.allocator(), src, false, true)).program;
    stripTypes(program, src, arena.allocator());
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try printer.print(program, src, &out, gpa);
    return out.toOwnedSlice(gpa);
}
fn expectStrip(gpa: std.mem.Allocator, src: []const u8, expected: []const u8) !void {
    const out = try stripSource(gpa, src);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "stripTypes : annotation de variable" {
    try expectStrip(std.testing.allocator, "let x: number = 1;", "let x = 1;\n");
}
test "stripTypes : params typés + optionnel + retour" {
    try expectStrip(std.testing.allocator, "function f(a: string, b?: number): void {}", "function f(a, b) {}\n");
}
test "stripTypes : type alias disparaît entier" {
    try expectStrip(std.testing.allocator, "type A = { x: number } | string; let v: A;", "let v;\n");
}
test "stripTypes : interface disparaît entière" {
    try expectStrip(std.testing.allocator, "interface I extends J { m(x: T): U; }\nx;", "x;\n");
}
test "stripTypes : as / as unknown as" {
    try expectStrip(std.testing.allocator, "const y = x as unknown as T;", "const y = x;\n");
}
test "stripTypes : non-null" {
    try expectStrip(std.testing.allocator, "a! + b!;", "a + b;\n");
}
test "stripTypes : tuple + union + function type (parse + strip)" {
    try expectStrip(std.testing.allocator, "let t: [string, ...number[]] | (() => void);", "let t;\n");
}
test "stripTypes : arrow à retour typé" {
    try expectStrip(std.testing.allocator, "const fn = (x: T): U => x;", "const fn = (x) => x;\n");
}
test "stripTypes : satisfies / as const" {
    try expectStrip(std.testing.allocator, "const c = o satisfies R; const m = \"x\" as const;", "const c = o;\nconst m = \"x\";\n");
}
test "stripTypes : classe générique + implements + champs/méthodes typés" {
    try expectStrip(std.testing.allocator,
        "class C<T> extends B implements I { private x: T; m(a: T): void {} }",
        "class C extends B {\n  x;\n  m(a) {}\n}\n",
    );
}

// ---- tests stripTypes phase 2 (génériques d'appel, import type, indexed access) ----

test "stripTypes : appel générique foo<T>(x) -> foo(x)" {
    try expectStrip(std.testing.allocator, "foo<T>(x);", "foo(x);\n");
    try expectStrip(std.testing.allocator, "const r = identity<string>(\"a\");", "const r = identity(\"a\");\n");
}
test "stripTypes : new générique + imbriqué Map<K, V[]>" {
    try expectStrip(std.testing.allocator, "const m = new Map<string, number[]>();", "const m = new Map();\n");
}
test "stripTypes : tagged template générique" {
    try expectStrip(std.testing.allocator, "gql<T>`query`;", "gql`query`;\n");
}
test "stripTypes : NON-régression — les comparaisons restent (a<b>c, f(a<b,c>d))" {
    try expectStrip(std.testing.allocator, "x = a < b;", "x = a < b;\n");
    try expectStrip(std.testing.allocator, "x = a < b > c;", "x = a < b > c;\n");
    try expectStrip(std.testing.allocator, "f(a < b, c > d);", "f(a < b, c > d);\n");
}
test "stripTypes : import type entier / mixte / export type" {
    try expectStrip(std.testing.allocator, "import type { A } from \"m\"; x;", "x;\n");
    try expectStrip(std.testing.allocator, "import { type A, B } from \"m\"; B;", "import { B } from \"m\";\nB;\n");
    try expectStrip(std.testing.allocator, "export type { A }; y;", "y;\n");
}
test "stripTypes : indexed access + index signature (type-only, disparaissent)" {
    try expectStrip(std.testing.allocator, "type V = O[K]; let a: V;", "let a;\n");
    try expectStrip(std.testing.allocator, "type D = { [k: string]: number }; let d: D;", "let d;\n");
}

// ---- tests stripTypes phase 3 (émission : enum, param props, namespace) ----

test "stripTypes : enum numérique -> IIFE avec valeurs 0/5/6" {
    try expectStrip(std.testing.allocator, "enum E { A, B = 5, C }",
        \\var E;
        \\(function(E) {
        \\  E[E["A"] = 0] = "A";
        \\  E[E["B"] = 5] = "B";
        \\  E[E["C"] = 6] = "C";
        \\})(E || (E = {}));
        \\
    );
}
test "stripTypes : enum string -> PAS de reverse mapping" {
    try expectStrip(std.testing.allocator, "enum S { A = \"a\", B = \"b\" }",
        \\var S;
        \\(function(S) {
        \\  S["A"] = "a";
        \\  S["B"] = "b";
        \\})(S || (S = {}));
        \\
    );
}
test "stripTypes : initialiseur constant 1 << 4 -> 16 (folder réutilisé)" {
    try expectStrip(std.testing.allocator, "enum F { X = 1 << 4 }",
        \\var F;
        \\(function(F) {
        \\  F[F["X"] = 16] = "X";
        \\})(F || (F = {}));
        \\
    );
}
test "stripTypes : const enum -> compilé comme un enum normal" {
    try expectStrip(std.testing.allocator, "const enum C { A }",
        \\var C;
        \\(function(C) {
        \\  C[C["A"] = 0] = "A";
        \\})(C || (C = {}));
        \\
    );
}
test "stripTypes : export enum -> export var + IIFE" {
    const out = try stripSource(std.testing.allocator, "export enum E { A }");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "export var E;") != null);
}
test "stripTypes : double nature — le type s'efface, E.A reste" {
    try expectStrip(std.testing.allocator, "enum E { A } let x: E = E.A;",
        \\var E;
        \\(function(E) {
        \\  E[E["A"] = 0] = "A";
        \\})(E || (E = {}));
        \\let x = E.A;
        \\
    );
}
test "stripTypes : parameter properties -> this.x = x en tête" {
    try expectStrip(std.testing.allocator, "class C { constructor(private a, public b = 2) {} }",
        \\class C {
        \\  constructor(a, b = 2) {
        \\    this.a = a;
        \\    this.b = b;
        \\  }
        \\}
        \\
    );
}
test "stripTypes : parameter properties APRÈS super()" {
    try expectStrip(std.testing.allocator, "class D extends B { constructor(private a) { super(); f(); } }",
        \\class D extends B {
        \\  constructor(a) {
        \\    super();
        \\    this.a = a;
        \\    f();
        \\  }
        \\}
        \\
    );
}
test "stripTypes : namespace -> IIFE + N.x résolu" {
    try expectStrip(std.testing.allocator, "namespace N { export const x = 1; } N.x;",
        \\var N;
        \\(function(N) {
        \\  N.x = 1;
        \\})(N || (N = {}));
        \\N.x;
        \\
    );
}
