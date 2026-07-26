//! Walker générique sur l'AST : `walk(node, visitor)` visite chaque nœud + ses
//! enfants. Extrait du transformer pour être partagé (transformer, semantic…).
//!
//! Ne dépend QUE de `ast.zig` (aucune dépendance parser/printer) : c'est la
//! brique de base pour toute passe qui parcourt l'arbre.
//!
//! Le `visitor` = « vtable manuelle » (pointeur de contexte `*anyopaque` + fns) :
//!   - `enter(node)` : AVANT les enfants. Retourne un remplaçant optionnel ; s'il
//!     en renvoie un, on SUBSTITUE et on NE redescend PAS dedans.
//!   - `exit(node)` : APRÈS les enfants (bottom-up).

const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;

pub const Visitor = struct {
    ctx: *anyopaque,
    enter: ?*const fn (ctx: *anyopaque, node: *Node) ?*Node = null,
    exit: ?*const fn (ctx: *anyopaque, node: *Node) ?*Node = null,
};

/// Visite `node` : enter -> enfants -> exit. Retourne le nœud (éventuellement
/// remplacé). L'appelant réaffecte le slot parent avec la valeur de retour.
pub fn walk(node: *Node, v: Visitor) *Node {
    if (v.enter) |enter| {
        if (enter(v.ctx, node)) |repl| return repl; // substitué : on ne descend pas.
    }
    walkChildren(node, v);
    if (v.exit) |exit| {
        if (exit(v.ctx, node)) |repl| return repl;
    }
    return node;
}

fn walkOne(slot: *(*Node), v: Visitor) void {
    slot.* = walk(slot.*, v);
}
fn walkOpt(slot: *?*Node, v: Visitor) void {
    if (slot.*) |c| slot.* = walk(c, v);
}
fn walkSlice(slice: []*Node, v: Visitor) void {
    for (slice) |*slot| slot.* = walk(slot.*, v);
}
fn walkSliceOpt(slice: []?*Node, v: Visitor) void {
    for (slice) |*slot| if (slot.*) |c| {
        slot.* = walk(c, v);
    };
}

/// Descend dans TOUS les enfants de `node` (chaque `*Node`/`[]*Node`/`?*Node`).
/// Les feuilles n'ont pas d'enfant.
pub fn walkChildren(node: *Node, v: Visitor) void {
    switch (node.kind) {
        .program => |*p| walkSlice(p.body, v),
        .block_statement => |*b| walkSlice(b.body, v),
        .if_statement => |*s| {
            walkOne(&s.@"test", v);
            walkOne(&s.consequent, v);
            walkOpt(&s.alternate, v);
        },
        .while_statement => |*s| {
            walkOne(&s.@"test", v);
            walkOne(&s.body, v);
        },
        .do_while_statement => |*s| {
            walkOne(&s.body, v);
            walkOne(&s.@"test", v);
        },
        .for_statement => |*s| {
            walkOpt(&s.init, v);
            walkOpt(&s.@"test", v);
            walkOpt(&s.update, v);
            walkOne(&s.body, v);
        },
        .for_of_statement, .for_in_statement => |*s| {
            walkOne(&s.left, v);
            walkOne(&s.right, v);
            walkOne(&s.body, v);
        },
        .return_statement => |*s| walkOpt(&s.argument, v),
        .throw_statement => |*s| walkOne(&s.argument, v),
        .expression_statement => |*s| walkOne(&s.expression, v),
        .labeled_statement => |*s| {
            walkOne(&s.label, v);
            walkOne(&s.body, v);
        },
        .break_statement, .continue_statement => |*s| walkOpt(&s.label, v),
        .variable_declaration => |*d| walkSlice(d.declarations, v),
        .variable_declarator => |*d| {
            walkOne(&d.id, v);
            walkOpt(&d.init, v);
        },
        .function_declaration, .function_expression => |*f| {
            walkOpt(&f.id, v);
            walkSlice(f.type_params, v);
            walkSlice(f.params, v);
            walkOpt(&f.return_type, v);
            walkOne(&f.body, v);
        },
        .arrow_function => |*f| {
            walkSlice(f.params, v);
            walkOpt(&f.return_type, v);
            walkOne(&f.body, v);
        },
        .binary_expression => |*b| {
            walkOne(&b.left, v);
            walkOne(&b.right, v);
        },
        .unary_expression => |*u| walkOne(&u.operand, v),
        .update_expression => |*u| walkOne(&u.argument, v),
        .await_expression => |*a| walkOne(&a.argument, v),
        .yield_expression => |*y| walkOpt(&y.argument, v),
        .conditional_expression => |*c| {
            walkOne(&c.@"test", v);
            walkOne(&c.consequent, v);
            walkOne(&c.alternate, v);
        },
        .assignment_expression => |*a| {
            walkOne(&a.target, v);
            walkOne(&a.value, v);
        },
        .sequence_expression => |*s| walkSlice(s.expressions, v),
        .call_expression => |*c| {
            walkOne(&c.callee, v);
            walkSlice(c.type_args, v);
            walkSlice(c.arguments, v);
        },
        .new_expression => |*n| {
            walkOne(&n.callee, v);
            walkSlice(n.type_args, v);
            walkSlice(n.arguments, v);
        },
        .member_expression => |*m| {
            walkOne(&m.object, v);
            walkOne(&m.property, v);
        },
        .array_expression => |*a| walkSliceOpt(a.elements, v),
        .array_pattern => |*a| walkSliceOpt(a.elements, v),
        .object_expression => |*o| walkSlice(o.properties, v),
        .object_pattern => |*o| walkSlice(o.properties, v),
        .property => |*p| {
            walkOne(&p.key, v);
            walkOne(&p.value, v);
        },
        .spread_element => |*s| walkOne(&s.argument, v),
        .rest_element => |*s| walkOne(&s.argument, v),
        .assignment_pattern => |*a| {
            walkOne(&a.left, v);
            walkOne(&a.right, v);
        },
        .template_literal => |*t| {
            walkSlice(t.quasis, v);
            walkSlice(t.expressions, v);
        },
        .tagged_template_expression => |*t| {
            walkOne(&t.tag, v);
            walkSlice(t.type_args, v);
            walkOne(&t.quasi, v);
        },
        .class_declaration, .class_expression => |*c| {
            walkOpt(&c.id, v);
            walkSlice(c.type_params, v);
            walkOpt(&c.superclass, v);
            walkSlice(c.super_type_args, v);
            walkSlice(c.implements, v);
            walkOne(&c.body, v);
        },
        .class_body => |*b| walkSlice(b.members, v),
        .method_definition => |*m| {
            walkOne(&m.key, v);
            walkSlice(m.type_params, v);
            walkSlice(m.params, v);
            walkOpt(&m.return_type, v);
            walkOne(&m.body, v);
        },
        .property_definition => |*p| {
            walkOne(&p.key, v);
            walkOpt(&p.type_annotation, v);
            walkOpt(&p.value, v);
        },
        .try_statement => |*t| {
            walkOne(&t.block, v);
            walkOpt(&t.handler, v);
            walkOpt(&t.finalizer, v);
        },
        .catch_clause => |*c| {
            walkOpt(&c.param, v);
            walkOne(&c.body, v);
        },
        .switch_statement => |*s| {
            walkOne(&s.discriminant, v);
            walkSlice(s.cases, v);
        },
        .switch_case => |*c| {
            walkOpt(&c.@"test", v);
            walkSlice(c.consequent, v);
        },
        .import_declaration => |*d| {
            walkSlice(d.specifiers, v);
            walkOne(&d.source, v);
        },
        .import_default_specifier => |*s| walkOne(&s.local, v),
        .import_namespace_specifier => |*s| walkOne(&s.local, v),
        .import_specifier => |*s| {
            walkOne(&s.imported, v);
            walkOne(&s.local, v);
        },
        .import_expression => |*e| walkOne(&e.source, v),
        .export_named_declaration => |*e| {
            walkOpt(&e.declaration, v);
            walkSlice(e.specifiers, v);
            walkOpt(&e.source, v);
        },
        .export_default_declaration => |*e| walkOne(&e.declaration, v),
        .export_all_declaration => |*e| walkOne(&e.source, v),
        .export_specifier => |*s| {
            walkOne(&s.local, v);
            walkOne(&s.exported, v);
        },
        // ---- JSX ----
        .jsx_element => |*e| {
            walkOne(&e.opening, v);
            walkSlice(e.children, v);
            walkOpt(&e.closing, v);
        },
        .jsx_fragment => |*f| walkSlice(f.children, v),
        .jsx_opening_element => |*o| {
            walkOne(&o.name, v);
            walkSlice(o.attributes, v);
        },
        .jsx_closing_element => |*c| walkOne(&c.name, v),
        .jsx_member_expression => |*m| {
            walkOne(&m.object, v);
            walkOne(&m.property, v);
        },
        .jsx_namespaced_name => |*n| {
            walkOne(&n.namespace, v);
            walkOne(&n.name, v);
        },
        .jsx_attribute => |*a| {
            walkOne(&a.name, v);
            walkOpt(&a.value, v);
        },
        .jsx_spread_attribute => |*s| walkOne(&s.argument, v),
        .jsx_expression_container => |*c| walkOpt(&c.expression, v),
        // ---- TypeScript ----
        .ts_type_reference => |*t| {
            walkOne(&t.name, v);
            walkSlice(t.type_args, v);
        },
        .ts_qualified_name => |*q| {
            walkOne(&q.left, v);
            walkOne(&q.right, v);
        },
        .ts_literal_type => |*t| walkOne(&t.literal, v),
        .ts_union_type, .ts_intersection_type => |*t| walkSlice(t.types, v),
        .ts_parenthesized_type => |*t| walkOne(&t.@"type", v),
        .ts_array_type => |*t| walkOne(&t.element, v),
        .ts_tuple_type => |*t| walkSlice(t.elements, v),
        .ts_rest_type => |*t| walkOne(&t.@"type", v),
        .ts_function_type => |*t| {
            walkSlice(t.type_params, v);
            walkSlice(t.params, v);
            walkOne(&t.return_type, v);
        },
        .ts_type_literal => |*t| walkSlice(t.members, v),
        .ts_property_signature => |*p| {
            walkOne(&p.key, v);
            walkOpt(&p.type_annotation, v);
        },
        .ts_method_signature => |*m| {
            walkOne(&m.key, v);
            walkSlice(m.params, v);
            walkOpt(&m.return_type, v);
        },
        .ts_typeof_type => |*t| walkOne(&t.expr, v),
        .ts_keyof_type => |*t| walkOne(&t.@"type", v),
        .ts_indexed_access_type => |*t| {
            walkOne(&t.object, v);
            walkOne(&t.index, v);
        },
        .ts_index_signature => |*t| {
            walkOne(&t.key_type, v);
            walkOne(&t.value_type, v);
        },
        .ts_type_parameter => |*t| {
            walkOne(&t.name, v);
            walkOpt(&t.constraint, v);
            walkOpt(&t.default, v);
        },
        .ts_type_alias => |*t| {
            walkOne(&t.id, v);
            walkSlice(t.type_params, v);
            walkOne(&t.@"type", v);
        },
        .ts_interface => |*t| {
            walkOne(&t.id, v);
            walkSlice(t.type_params, v);
            walkSlice(t.extends, v);
            walkSlice(t.body, v);
        },
        .ts_typed => |*t| {
            walkOne(&t.binding, v);
            walkOpt(&t.type_annotation, v);
        },
        .ts_as_expression => |*t| {
            walkOne(&t.expr, v);
            walkOne(&t.@"type", v);
        },
        .ts_satisfies_expression => |*t| {
            walkOne(&t.expr, v);
            walkOne(&t.@"type", v);
        },
        .ts_non_null_expression => |*t| walkOne(&t.expr, v),
        .ts_enum => |*e| {
            walkOne(&e.id, v);
            walkSlice(e.members, v);
        },
        .ts_enum_member => |*m| {
            walkOne(&m.name, v);
            walkOpt(&m.initializer, v);
        },
        .ts_namespace => |*n| {
            walkOne(&n.id, v);
            walkSlice(n.body, v);
        },
        .ts_param_property => |*p| walkOne(&p.param, v),
        // Feuilles (aucun enfant).
        .number_literal, .bigint_literal, .string_literal, .boolean_literal, .null_literal, .regex_literal, .identifier, .private_name, .error_node, .this_expression, .super_expression, .meta_property, .template_element, .jsx_identifier, .jsx_text, .ts_keyword_type => {},
    }
}
