//! Codegen (printer) : AST -> JS valide.
//!
//! Fidélité **sémantique**, pas textuelle : le formatage d'origine (espaces,
//! commentaires, ASI) est perdu ; ce qui est garanti c'est que
//! `parse(print(parse(src)))` redonne le MÊME AST que `parse(src)`.
//!
//! Style : indentation 2 espaces, un statement par ligne, `;` PARTOUT (l'ASI est
//! normalisée). Les littéraux (nombres/bigint/strings/regex/templates) sont
//! réémis via leur **span brut** (déjà la représentation source exacte).
//!
//! Le seul vrai travail : RECRÉER les parenthèses que l'AST ne stocke pas, quand
//! la précédence l'exige. On réutilise la même échelle de précédence que le Pratt
//! du parser. Sur-parenthéser reste correct (les `()` ne créent pas de nœud) ; on
//! reste donc conservateur en cas de doute.

const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;

// Échelle de précédence unifiée (plus haut = lie plus fort). Les niveaux binaires
// occupent 4..15 (= 3 + binPrec, binPrec 1..12 miroir de `binaryInfo`).
const PREC_SEQ: u8 = 1; // a, b
const PREC_ASSIGN: u8 = 2; // = += … , arrow, yield
const PREC_COND: u8 = 3; // ?:
const PREC_UNARY: u8 = 16; // !x -x typeof await ++x (préfixe)
const PREC_POSTFIX: u8 = 17; // x++
const PREC_CALL: u8 = 18; // f() a.b new X() a`t`
const PREC_PRIMARY: u8 = 19; // littéraux, identifiants, (…), [], {}

fn binPrec(op: ast.BinaryOp) u8 {
    return switch (op) {
        .nullish => 1,
        .logical_or => 2,
        .logical_and => 3,
        .bor => 4,
        .bxor => 5,
        .band => 6,
        .eq, .neq, .strict_eq, .strict_neq => 7,
        .lt, .gt, .le, .ge, .in_, .instance_of => 8,
        .shl, .shr, .ushr => 9,
        .add, .sub => 10,
        .mul, .div, .rem => 11,
        .exp => 12,
    };
}

/// Précédence d'un nœud expression sur l'échelle unifiée.
fn precOf(node: *const Node) u8 {
    return switch (node.kind) {
        .sequence_expression => PREC_SEQ,
        .assignment_expression, .arrow_function, .yield_expression => PREC_ASSIGN,
        .conditional_expression => PREC_COND,
        .binary_expression => |b| 3 + binPrec(b.operator),
        .unary_expression, .await_expression => PREC_UNARY,
        .update_expression => |u| if (u.prefix) PREC_UNARY else PREC_POSTFIX,
        .call_expression, .member_expression, .new_expression, .tagged_template_expression, .import_expression => PREC_CALL,
        // TS : `x as T`/`satisfies` lient lâche (parenthésés comme objet de membre :
        // `(x as T).y`) ; `x!` lie serré (postfix : `x!.y` sans parenthèses).
        .ts_as_expression, .ts_satisfies_expression => PREC_UNARY,
        .ts_non_null_expression => PREC_CALL,
        else => PREC_PRIMARY,
    };
}

/// Vrai si, en tête de statement (ou de corps d'arrow), l'expression commence par
/// un token ambigu (`{` objet, `function`, `class`) et doit être parenthésée. On
/// descend le fils le plus à gauche.
fn needsWrap(node: *const Node) bool {
    return switch (node.kind) {
        .object_expression, .object_pattern, .function_expression, .class_expression => true,
        .binary_expression => |b| needsWrap(b.left),
        .assignment_expression => |a| needsWrap(a.target),
        .member_expression => |m| needsWrap(m.object),
        // IIFE `(function(){})()` : le callee fonction/classe est auto-parenthésé par
        // le printer d'appel -> pas de wrap au niveau statement (style tsc `})()`).
        .call_expression => |c| switch (c.callee.kind) {
            .function_expression, .class_expression => false,
            else => needsWrap(c.callee),
        },
        .conditional_expression => |c| needsWrap(c.@"test"),
        .tagged_template_expression => |t| needsWrap(t.tag),
        .sequence_expression => |s| s.expressions.len > 0 and needsWrap(s.expressions[0]),
        .update_expression => |u| !u.prefix and needsWrap(u.argument),
        else => false,
    };
}

/// Vrai si la chaîne member/tag du callee de `new` contient un appel (impose des
/// parenthèses : `new (a().b)()`).
fn calleeHasCall(node: *const Node) bool {
    return switch (node.kind) {
        .call_expression => true,
        .member_expression => |m| calleeHasCall(m.object),
        .tagged_template_expression => |t| calleeHasCall(t.tag),
        else => false,
    };
}

/// Une position de sortie et la position SOURCE dont elle provient — en OCTETS
/// des deux côtés.
///
/// Le printer ne connaît ni lignes ni colonnes : il ne sait pas quel texte
/// l'entoure une fois concaténé. Il rend donc des offsets bruts, et c'est au
/// consommateur (un bundler qui assemble N modules) de les convertir. C'est le
/// dividende des spans byte-exacts posés au jour 1 : la position source est déjà
/// là, sur chaque nœud, il n'y avait qu'à la faire sortir.
pub const Mapping = struct {
    /// Offset dans `out` où commence ce qui est émis.
    out: u32,
    /// Offset dans `source` du nœud dont ça provient.
    src: u32,
};

/// De quoi le printer alimente un consommateur, en plus du texte.
pub const Sink = struct {
    /// Non-null = le printer enregistre ses positions au fil de l'émission.
    /// Null = comportement d'avant, au bit près.
    maps: ?*std.ArrayList(Mapping) = null,
};

const Printer = struct {
    source: []const u8,
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    depth: usize = 0,
    maps: ?*std.ArrayList(Mapping) = null,

    const Error = std.mem.Allocator.Error || error{Unprintable};

    /// Enregistre « ce qui sort ici vient de là ».
    ///
    /// **Un nœud SYNTHÉTIQUE (`end == 0`) n'est pas mappé.** L'IIFE d'un `enum`,
    /// l'appel `jsx()`, un littéral né du folding : ils ne viennent d'aucun
    /// caractère du source. Les fabriquer avec `start = 0` (ce que font
    /// `jsx_transform` et `transformer`) ferait pointer le mapping sur le PREMIER
    /// caractère du fichier — pire que pas de mapping du tout.
    ///
    /// Ne rien émettre est d'ailleurs la BONNE réponse, pas un pis-aller : un
    /// segment de source map vaut jusqu'au suivant, donc la sortie synthétique
    /// est attribuée au statement qui l'entoure — exactement « la position
    /// significative la plus proche ».
    ///
    /// Un vrai nœud a toujours `end > start >= 0`, donc `end == 0` est un
    /// discriminant sûr (et non `start == 0`, qui est légitime pour le premier
    /// nœud d'un fichier).
    fn mark(self: *Printer, node: *const Node) Error!void {
        const maps = self.maps orelse return;
        if (node.end == 0) return;
        try maps.append(self.gpa, .{ .out = @intCast(self.out.items.len), .src = node.start });
    }

    fn w(self: *Printer, s: []const u8) Error!void {
        try self.out.appendSlice(self.gpa, s);
    }
    fn wc(self: *Printer, c: u8) Error!void {
        try self.out.append(self.gpa, c);
    }
    fn nl(self: *Printer) Error!void {
        try self.wc('\n');
    }
    fn pad(self: *Printer) Error!void {
        var i: usize = 0;
        while (i < self.depth) : (i += 1) try self.w("  ");
    }
    /// Réémet le span brut d'un nœud (feuilles / clés).
    fn span(self: *Printer, node: *const Node) Error!void {
        try self.w(node.text(self.source));
    }

    // ---- expressions ----

    /// Imprime `node` en le parenthésant si sa précédence est < `min`.
    fn expr(self: *Printer, node: *const Node, min: u8) Error!void {
        const need = precOf(node) < min;
        if (need) try self.wc('(');
        try self.exprInner(node);
        if (need) try self.wc(')');
    }

    fn exprInner(self: *Printer, node: *const Node) Error!void {
        switch (node.kind) {
            // Feuilles : span brut, SAUF number/boolean qui peuvent porter un
            // `synthetic_text` (nœud fabriqué par le transformer) -> `litText`.
            // number/boolean/identifier peuvent porter un `synthetic_text` (fold
            // ou mangling) -> `litText`.
            // number/boolean/identifier/string peuvent porter un `synthetic_text`
            // (fold, mangling, ou string fabriquée par le transform JSX) -> litText.
            // `mark` AVANT `litText` : un identifiant renommé (mangling, ou la
            // table cross-module d'un linker) garde son NŒUD, seul son texte
            // change. Le span pointe donc toujours l'identifiant D'ORIGINE —
            // c'est ce qui rend un bundle renommé débogable, et ça ne coûte rien.
            .number_literal, .boolean_literal, .identifier, .string_literal => {
                try self.mark(node);
                try self.w(node.litText(self.source));
            },
            .bigint_literal, .regex_literal, .meta_property, .private_name => {
                try self.mark(node);
                try self.span(node);
            },
            // error recovery : on réémet le SPAN BRUT (pass-through — un formateur
            // doit préserver le code cassé, on ne l'invente pas).
            .error_node => try self.span(node),
            // TS : expressions à type (round-trip en mode ts ; effacées par stripTypes).
            .ts_as_expression => |t| {
                try self.expr(t.expr, PREC_UNARY);
                try self.w(" as ");
                try self.tsType(t.@"type");
            },
            .ts_satisfies_expression => |t| {
                try self.expr(t.expr, PREC_UNARY);
                try self.w(" satisfies ");
                try self.tsType(t.@"type");
            },
            .ts_non_null_expression => |t| {
                try self.expr(t.expr, PREC_CALL);
                try self.wc('!');
            },
            .null_literal => try self.w("null"),
            .this_expression => try self.w("this"),
            .super_expression => try self.w("super"),

            .binary_expression => |b| {
                const p = 3 + binPrec(b.operator);
                if (b.operator == .exp) { // ** est associatif à DROITE
                    try self.expr(b.left, PREC_UNARY + 1); // gauche : parenthèse si <= unaire (2**3**2, (-2)**2)
                    try self.w(" ** ");
                    try self.expr(b.right, p);
                } else {
                    try self.expr(b.left, p);
                    try self.wc(' ');
                    try self.w(b.operator.symbol());
                    try self.wc(' ');
                    try self.expr(b.right, p + 1); // droite : parenthèse si égal (a - (b - c))
                }
            },
            .unary_expression => |u| {
                try self.w(u.operator.symbol());
                // Mots (typeof/void/delete) : espace obligatoire. Symboles : espace
                // seulement si l'opérande est un unaire/update préfixe (`- -a`, `- --a`).
                if (isWordUnary(u.operator)) {
                    try self.wc(' ');
                } else switch (u.operand.kind) {
                    .unary_expression => try self.wc(' '),
                    .update_expression => |o| if (o.prefix) try self.wc(' '),
                    else => {},
                }
                try self.expr(u.operand, PREC_UNARY);
            },
            .update_expression => |u| {
                if (u.prefix) {
                    try self.w(u.operator.symbol());
                    try self.expr(u.argument, PREC_UNARY);
                } else {
                    try self.expr(u.argument, PREC_POSTFIX);
                    try self.w(u.operator.symbol());
                }
            },
            .await_expression => |a| {
                try self.w("await ");
                try self.expr(a.argument, PREC_UNARY);
            },
            .yield_expression => |y| {
                try self.w("yield");
                if (y.delegate) try self.wc('*');
                if (y.argument) |ya| {
                    try self.wc(' ');
                    try self.expr(ya, PREC_ASSIGN);
                }
            },
            .conditional_expression => |c| {
                try self.expr(c.@"test", PREC_COND + 1);
                try self.w(" ? ");
                try self.expr(c.consequent, PREC_ASSIGN);
                try self.w(" : ");
                try self.expr(c.alternate, PREC_ASSIGN);
            },
            .assignment_expression => |a| {
                try self.target(a.target);
                try self.wc(' ');
                try self.w(a.operator.symbol());
                try self.wc(' ');
                try self.expr(a.value, PREC_ASSIGN);
            },
            .sequence_expression => |s| {
                for (s.expressions, 0..) |e, i| {
                    if (i != 0) try self.w(", ");
                    try self.expr(e, PREC_ASSIGN);
                }
            },
            .call_expression => |c| {
                // Callee fonction/classe (IIFE) : parenthésé -> `(function(){})(x)`.
                const wrap_callee = c.callee.kind == .function_expression or c.callee.kind == .class_expression;
                if (wrap_callee) try self.wc('(');
                try self.expr(c.callee, PREC_CALL);
                if (wrap_callee) try self.wc(')');
                if (c.optional) try self.w("?.");
                try self.typeArgs(c.type_args); // TS : `foo<T>(x)`
                try self.argList(c.arguments);
            },
            .new_expression => |n| {
                try self.w("new ");
                // Le callee de `new` est une MemberExpression (sans appel) : dès
                // qu'un appel apparaît dans sa chaîne (`new (f())()`, `new (a().b)()`)
                // il faut parenthéser, sinon les `()` deviendraient l'appel du new.
                const wrap = calleeHasCall(n.callee);
                if (wrap) try self.wc('(');
                try self.expr(n.callee, PREC_CALL);
                if (wrap) try self.wc(')');
                try self.typeArgs(n.type_args); // TS : `new Foo<T>()`
                try self.argList(n.arguments);
            },
            .member_expression => |m| {
                // `1 .x` invalide -> parenthèse le nombre.
                const wrap = m.object.kind == .number_literal;
                if (wrap) try self.wc('(');
                try self.expr(m.object, PREC_CALL);
                if (wrap) try self.wc(')');
                if (m.computed) {
                    try self.w(if (m.optional) "?.[" else "[");
                    try self.expr(m.property, PREC_SEQ);
                    try self.wc(']');
                } else {
                    try self.w(if (m.optional) "?." else ".");
                    // litText : sert les propriétés de membre SYNTHÉTIQUES (transform
                    // JSX : `A.B.C`) ; fallback au span pour les nœuds du parser.
                    try self.w(m.property.litText(self.source));
                }
            },
            .tagged_template_expression => |t| {
                try self.expr(t.tag, PREC_CALL);
                try self.typeArgs(t.type_args); // TS : `` tag<T>`x` ``
                try self.template(t.quasi);
            },
            .import_expression => |ie| {
                try self.w("import(");
                try self.expr(ie.source, PREC_ASSIGN);
                if (ie.options) |o| { // `import(src, { with: { type: 'json' } })`
                    try self.w(", ");
                    try self.expr(o, PREC_ASSIGN);
                }
                try self.wc(')');
            },
            .array_expression => |a| {
                try self.wc('[');
                for (a.elements, 0..) |el, i| {
                    if (i != 0) try self.w(", ");
                    if (el) |e| try self.arg(e);
                }
                // Trou final : virgule supplémentaire pour le préserver (`[a, ,]`).
                if (a.elements.len > 0 and a.elements[a.elements.len - 1] == null) try self.wc(',');
                try self.wc(']');
            },
            .object_expression => |o| {
                if (o.properties.len == 0) {
                    try self.w("{}");
                    return;
                }
                try self.w("{ ");
                for (o.properties, 0..) |p, i| {
                    if (i != 0) try self.w(", ");
                    try self.objectMember(p);
                }
                try self.w(" }");
            },
            .template_literal => try self.template(node),
            .function_expression => try self.function(node, false),
            .arrow_function => |f| {
                if (f.is_async) try self.w("async ");
                try self.paramList(f.params);
                try self.annotation(f.return_type);
                try self.w(" => ");
                if (f.expression) {
                    if (needsWrap(f.body)) {
                        try self.wc('(');
                        try self.expr(f.body, PREC_ASSIGN);
                        try self.wc(')');
                    } else try self.expr(f.body, PREC_ASSIGN);
                } else try self.block(f.body);
            },
            .class_expression => try self.class(node),
            .spread_element => |s| {
                try self.w("...");
                try self.expr(s.argument, PREC_ASSIGN);
            },
            // Cibles de destructuring en position d'expression (assignment target).
            .array_pattern, .object_pattern, .assignment_pattern, .rest_element => try self.target(node),
            // JSX (expression).
            .jsx_element => try self.jsxElement(node),
            .jsx_fragment => try self.jsxFragment(node),
            else => return error.Unprintable,
        }
    }

    // ---- JSX ----
    // Fidélité round-trip : les blancs de BALISE (entre attributs) sont
    // insignifiants -> normalisés à un espace ; les ENFANTS (JSXText) sont
    // significatifs -> réémis verbatim, collés (aucun blanc ajouté).

    fn jsxElement(self: *Printer, node: *const Node) Error!void {
        const e = node.kind.jsx_element;
        try self.jsxOpening(e.opening);
        for (e.children) |c| try self.jsxChild(c);
        if (e.closing) |cl| try self.jsxClosing(cl);
    }

    fn jsxFragment(self: *Printer, node: *const Node) Error!void {
        const f = node.kind.jsx_fragment;
        try self.w("<>");
        for (f.children) |c| try self.jsxChild(c);
        try self.w("</>");
    }

    fn jsxOpening(self: *Printer, node: *const Node) Error!void {
        const o = node.kind.jsx_opening_element;
        try self.wc('<');
        try self.jsxName(o.name);
        for (o.attributes) |a| {
            try self.wc(' ');
            try self.jsxAttribute(a);
        }
        if (o.self_closing) try self.w(" />") else try self.wc('>');
    }

    fn jsxClosing(self: *Printer, node: *const Node) Error!void {
        try self.w("</");
        try self.jsxName(node.kind.jsx_closing_element.name);
        try self.wc('>');
    }

    /// Nom JSX : identifiant (via litText → renommé si composant manglé), membre
    /// `A.B.C`, ou namespace `svg:path`.
    fn jsxName(self: *Printer, node: *const Node) Error!void {
        switch (node.kind) {
            .jsx_identifier => try self.w(node.litText(self.source)),
            .jsx_member_expression => |m| {
                try self.jsxName(m.object);
                try self.wc('.');
                try self.jsxName(m.property);
            },
            .jsx_namespaced_name => |n| {
                try self.jsxName(n.namespace);
                try self.wc(':');
                try self.jsxName(n.name);
            },
            else => return error.Unprintable,
        }
    }

    fn jsxAttribute(self: *Printer, node: *const Node) Error!void {
        switch (node.kind) {
            .jsx_spread_attribute => |s| {
                try self.w("{...");
                try self.expr(s.argument, PREC_ASSIGN);
                try self.wc('}');
            },
            .jsx_attribute => |a| {
                try self.jsxName(a.name);
                if (a.value) |v| {
                    try self.wc('=');
                    // Valeur : string (span brut), conteneur {expr}, ou élément JSX.
                    switch (v.kind) {
                        .string_literal => try self.span(v),
                        .jsx_expression_container => try self.jsxContainer(v),
                        else => try self.exprInner(v), // <b/> comme valeur
                    }
                }
            },
            else => return error.Unprintable,
        }
    }

    fn jsxContainer(self: *Printer, node: *const Node) Error!void {
        try self.wc('{');
        if (node.kind.jsx_expression_container.expression) |e| try self.expr(e, PREC_SEQ);
        try self.wc('}');
    }

    /// Un enfant : texte brut (verbatim), conteneur `{expr}`, ou élément imbriqué.
    fn jsxChild(self: *Printer, node: *const Node) Error!void {
        switch (node.kind) {
            .jsx_text => try self.span(node),
            .jsx_expression_container => try self.jsxContainer(node),
            .jsx_element => try self.jsxElement(node),
            .jsx_fragment => try self.jsxFragment(node),
            else => return error.Unprintable,
        }
    }

    /// Argument d'appel / élément de tableau : `spread` ou expression (assign).
    fn arg(self: *Printer, node: *const Node) Error!void {
        if (node.kind == .spread_element) {
            try self.w("...");
            try self.expr(node.kind.spread_element.argument, PREC_ASSIGN);
        } else try self.expr(node, PREC_ASSIGN);
    }

    fn argList(self: *Printer, args: []*Node) Error!void {
        try self.wc('(');
        for (args, 0..) |a, i| {
            if (i != 0) try self.w(", ");
            try self.arg(a);
        }
        try self.wc(')');
    }

    fn template(self: *Printer, node: *const Node) Error!void {
        const t = node.kind.template_literal;
        try self.wc('`');
        for (t.quasis, 0..) |q, i| {
            try self.span(q); // texte brut du quasi (sans délimiteurs)
            if (i < t.expressions.len) {
                try self.w("${");
                try self.expr(t.expressions[i], PREC_SEQ);
                try self.wc('}');
            }
        }
        try self.wc('`');
    }

    /// Membre d'un objet littéral : spread, méthode, ou property.
    fn objectMember(self: *Printer, node: *const Node) Error!void {
        switch (node.kind) {
            .spread_element => |s| {
                try self.w("...");
                try self.expr(s.argument, PREC_ASSIGN);
            },
            .method_definition => try self.method(node),
            .property => |p| {
                if (p.shorthand) {
                    // Cover grammar `{ x = 1 }` (valeur = AssignmentPattern) : garder
                    // le défaut. Sinon `{x}` : désucrer si `x` a été renommé (mangling).
                    if (p.value.kind == .assignment_pattern) {
                        const ap = p.value.kind.assignment_pattern;
                        try self.desugarKey(p.key, ap.left);
                        try self.w(" = ");
                        try self.expr(ap.right, PREC_ASSIGN);
                    } else try self.shorthandOrDesugar(p.key);
                } else {
                    try self.key(p.key, p.computed);
                    try self.w(": ");
                    try self.expr(p.value, PREC_ASSIGN);
                }
            },
            else => return error.Unprintable,
        }
    }

    /// Shorthand `{x}` : émet la clé d'origine, et si le BINDING a été renommé
    /// (mangling), désucre en `<origine>: <nouveau>` (sinon on changerait la clé).
    /// `key` porte le nom d'origine ; `binding` porte le nom courant (renommé).
    fn desugarKey(self: *Printer, key_node: *const Node, binding: *const Node) Error!void {
        const orig = key_node.text(self.source);
        const cur = binding.litText(self.source);
        try self.w(orig);
        if (!std.mem.eql(u8, orig, cur)) {
            try self.w(": ");
            try self.w(cur);
        }
    }
    fn shorthandOrDesugar(self: *Printer, ident: *const Node) Error!void {
        try self.desugarKey(ident, ident); // {x} d'expression : clé == valeur
    }

    /// Clé de property/méthode : `[expr]` (computed) ou nom brut. `litText` (pas
    /// `span`) pour servir les clés SYNTHÉTIQUES du transform JSX (identifiant
    /// `children`, string `"data-id"`…) ; fallback au span pour les nœuds du parser.
    fn key(self: *Printer, k: *const Node, computed: bool) Error!void {
        if (computed) {
            try self.wc('[');
            try self.expr(k, PREC_ASSIGN);
            try self.wc(']');
        } else try self.w(k.litText(self.source));
    }

    // ---- cibles (params, destructuring) ----

    fn target(self: *Printer, node: *const Node) Error!void {
        switch (node.kind) {
            .array_pattern => |p| {
                try self.wc('[');
                for (p.elements, 0..) |el, i| {
                    if (i != 0) try self.w(", ");
                    if (el) |e| try self.target(e);
                }
                if (p.elements.len > 0 and p.elements[p.elements.len - 1] == null) try self.wc(',');
                try self.wc(']');
            },
            .object_pattern => |p| {
                if (p.properties.len == 0) {
                    try self.w("{}");
                    return;
                }
                try self.w("{ ");
                for (p.properties, 0..) |prop, i| {
                    if (i != 0) try self.w(", ");
                    try self.patternProp(prop);
                }
                try self.w(" }");
            },
            .assignment_pattern => |a| {
                try self.target(a.left);
                try self.w(" = ");
                try self.expr(a.right, PREC_ASSIGN);
            },
            .rest_element => |r| {
                try self.w("...");
                try self.target(r.argument);
            },
            // TS : binding annoté `x: T` / `a?: T`.
            .ts_typed => |t| {
                try self.target(t.binding);
                if (t.optional) try self.wc('?');
                try self.annotation(t.type_annotation);
            },
            // TS : parameter property `private readonly x: T`.
            .ts_param_property => |p| {
                if (p.access.len > 0) {
                    try self.w(p.access);
                    try self.wc(' ');
                }
                if (p.readonly) try self.w("readonly ");
                try self.target(p.param);
            },
            // identifiant, member (cible d'assignation), etc.
            else => try self.expr(node, PREC_ASSIGN),
        }
    }

    // ---- TypeScript ----
    /// `: Type` (annotation optionnelle).
    fn annotation(self: *Printer, ann: ?*const Node) Error!void {
        if (ann) |a| {
            try self.w(": ");
            try self.tsType(a);
        }
    }
    /// `<T, U>` (paramètres de type d'une déclaration).
    fn typeParams(self: *Printer, params: []*Node) Error!void {
        if (params.len == 0) return;
        try self.wc('<');
        for (params, 0..) |p, i| {
            if (i != 0) try self.w(", ");
            const tp = p.kind.ts_type_parameter;
            try self.tsType(tp.name);
            if (tp.constraint) |c| {
                try self.w(" extends ");
                try self.tsType(c);
            }
            if (tp.default) |d| {
                try self.w(" = ");
                try self.tsType(d);
            }
        }
        try self.wc('>');
    }

    /// `<A, B>` (arguments de type d'un appel générique), si non vide.
    fn typeArgs(self: *Printer, args: []*Node) Error!void {
        if (args.len == 0) return;
        try self.wc('<');
        for (args, 0..) |a, i| {
            if (i != 0) try self.w(", ");
            try self.tsType(a);
        }
        try self.wc('>');
    }

    /// Émet un nœud de TYPE. Réémission fidèle (round-trip en mode ts).
    fn tsType(self: *Printer, node: *const Node) Error!void {
        switch (node.kind) {
            .ts_keyword_type, .identifier => try self.w(node.litText(self.source)),
            .ts_type_reference => |t| {
                try self.tsType(t.name);
                if (t.type_args.len > 0) {
                    try self.wc('<');
                    for (t.type_args, 0..) |a, i| {
                        if (i != 0) try self.w(", ");
                        try self.tsType(a);
                    }
                    try self.wc('>');
                }
            },
            .ts_qualified_name => |q| {
                try self.tsType(q.left);
                try self.wc('.');
                try self.tsType(q.right);
            },
            .ts_literal_type => |t| try self.expr(t.literal, PREC_PRIMARY),
            .ts_union_type => |t| try self.tsTypeJoin(t.types, " | "),
            .ts_intersection_type => |t| try self.tsTypeJoin(t.types, " & "),
            .ts_parenthesized_type => |t| {
                try self.wc('(');
                try self.tsType(t.@"type");
                try self.wc(')');
            },
            .ts_array_type => |t| {
                try self.tsType(t.element);
                try self.w("[]");
            },
            .ts_tuple_type => |t| {
                try self.wc('[');
                for (t.elements, 0..) |e, i| {
                    if (i != 0) try self.w(", ");
                    try self.tsType(e);
                }
                try self.wc(']');
            },
            .ts_rest_type => |t| {
                try self.w("...");
                try self.tsType(t.@"type");
            },
            .ts_function_type => |t| {
                try self.paramList(t.params);
                try self.w(" => ");
                try self.tsType(t.return_type);
            },
            .ts_type_literal => |t| try self.tsMembers(t.members),
            .ts_property_signature => |p| {
                if (p.readonly) try self.w("readonly ");
                try self.key(p.key, p.computed);
                if (p.optional) try self.wc('?');
                try self.annotation(p.type_annotation);
            },
            .ts_method_signature => |m| {
                try self.key(m.key, m.computed);
                if (m.optional) try self.wc('?');
                try self.paramList(m.params);
                try self.annotation(m.return_type);
            },
            .ts_typeof_type => |t| {
                try self.w("typeof ");
                try self.tsType(t.expr); // entity name (identifier / qualified `a.b`)
            },
            .ts_keyof_type => |t| {
                try self.w("keyof ");
                try self.tsType(t.@"type");
            },
            .ts_indexed_access_type => |t| {
                try self.tsType(t.object);
                try self.wc('[');
                try self.tsType(t.index);
                try self.wc(']');
            },
            .ts_index_signature => |t| {
                if (t.readonly) try self.w("readonly ");
                try self.wc('[');
                try self.tsType(t.key); // nom de la clé
                try self.w(": ");
                try self.tsType(t.key_type);
                try self.w("]: ");
                try self.tsType(t.value_type);
            },
            else => return error.Unprintable,
        }
    }
    fn tsTypeJoin(self: *Printer, types: []*Node, sep: []const u8) Error!void {
        for (types, 0..) |t, i| {
            if (i != 0) try self.w(sep);
            try self.tsType(t);
        }
    }
    /// `{ a: T; b?: U }` (membres d'un type objet / interface), sur une ligne.
    fn tsMembers(self: *Printer, members: []*Node) Error!void {
        if (members.len == 0) {
            try self.w("{}");
            return;
        }
        try self.w("{ ");
        for (members, 0..) |m, i| {
            if (i != 0) try self.w("; ");
            try self.tsType(m);
        }
        try self.w(" }");
    }

    fn patternProp(self: *Printer, node: *const Node) Error!void {
        switch (node.kind) {
            .rest_element => |r| {
                try self.w("...");
                try self.target(r.argument);
            },
            .property => |p| {
                if (p.shorthand) {
                    // `{ x }` ou `{ x = 1 }`. Si `x` (binding) a été renommé,
                    // désucrer en `{ <origine>: <nouveau> }` (idem valeur défaut).
                    if (p.value.kind == .assignment_pattern) {
                        const ap = p.value.kind.assignment_pattern;
                        try self.desugarKey(p.key, ap.left); // binding = ap.left
                        try self.w(" = ");
                        try self.expr(ap.right, PREC_ASSIGN);
                    } else try self.shorthandOrDesugar(p.key);
                } else {
                    try self.key(p.key, p.computed);
                    try self.w(": ");
                    try self.target(p.value);
                }
            },
            else => return error.Unprintable,
        }
    }

    fn paramList(self: *Printer, params: []*Node) Error!void {
        try self.wc('(');
        for (params, 0..) |p, i| {
            if (i != 0) try self.w(", ");
            try self.target(p);
        }
        try self.wc(')');
    }

    // ---- fonctions / classes ----

    fn function(self: *Printer, node: *const Node, is_decl: bool) Error!void {
        _ = is_decl;
        const f = switch (node.kind) {
            .function_declaration, .function_expression => |x| x,
            else => return error.Unprintable,
        };
        if (f.is_async) try self.w("async ");
        try self.w("function");
        if (f.is_generator) try self.wc('*');
        if (f.id) |id| {
            try self.wc(' ');
            try self.w(id.litText(self.source)); // nom = binding renommable (mangling)
        }
        try self.typeParams(f.type_params);
        try self.paramList(f.params);
        try self.annotation(f.return_type);
        try self.wc(' ');
        try self.block(f.body);
    }

    fn class(self: *Printer, node: *const Node) Error!void {
        const c = switch (node.kind) {
            .class_declaration, .class_expression => |x| x,
            else => return error.Unprintable,
        };
        try self.w("class");
        if (c.id) |id| {
            try self.wc(' ');
            try self.w(id.litText(self.source)); // nom = binding renommable (mangling)
        }
        try self.typeParams(c.type_params); // `class C<T>` (TS)
        if (c.superclass) |sc| {
            try self.w(" extends ");
            try self.expr(sc, PREC_CALL);
            if (c.super_type_args.len > 0) { // `extends B<U>` (TS)
                try self.wc('<');
                for (c.super_type_args, 0..) |a, i| {
                    if (i != 0) try self.w(", ");
                    try self.tsType(a);
                }
                try self.wc('>');
            }
        }
        if (c.implements.len > 0) { // `implements I, J` (TS)
            try self.w(" implements ");
            for (c.implements, 0..) |im, i| {
                if (i != 0) try self.w(", ");
                try self.tsType(im);
            }
        }
        try self.wc(' ');
        // corps = class_body
        const body = c.body.kind.class_body;
        if (body.members.len == 0) {
            try self.w("{}");
            return;
        }
        try self.wc('{');
        try self.nl();
        self.depth += 1;
        for (body.members) |m| {
            try self.pad();
            switch (m.kind) {
                .method_definition => try self.method(m),
                .property_definition => try self.field(m),
                .error_node => try self.span(m), // membre raté (error recovery)
                else => return error.Unprintable,
            }
            try self.nl();
        }
        self.depth -= 1;
        try self.pad();
        try self.wc('}');
    }

    fn method(self: *Printer, node: *const Node) Error!void {
        const m = node.kind.method_definition;
        if (m.static) try self.w("static ");
        if (m.is_async) try self.w("async ");
        if (m.is_generator) try self.wc('*');
        switch (m.kind) {
            .getter => try self.w("get "),
            .setter => try self.w("set "),
            else => {},
        }
        try self.key(m.key, m.computed);
        try self.typeParams(m.type_params);
        try self.paramList(m.params);
        try self.annotation(m.return_type);
        try self.wc(' ');
        try self.block(m.body);
    }

    fn field(self: *Printer, node: *const Node) Error!void {
        const p = node.kind.property_definition;
        if (p.static) try self.w("static ");
        try self.key(p.key, p.computed);
        if (p.optional) try self.wc('?');
        try self.annotation(p.type_annotation);
        if (p.value) |v| {
            try self.w(" = ");
            try self.expr(v, PREC_ASSIGN);
        }
        try self.wc(';');
    }

    // ---- statements ----

    fn block(self: *Printer, node: *const Node) Error!void {
        const b = node.kind.block_statement;
        if (b.body.len == 0) {
            try self.w("{}");
            return;
        }
        try self.wc('{');
        try self.nl();
        self.depth += 1;
        for (b.body) |s| try self.stmtAt(s);
        self.depth -= 1;
        try self.pad();
        try self.wc('}');
    }

    /// Un statement complet : indentation + corps + retour ligne.
    fn stmtAt(self: *Printer, node: *const Node) Error!void {
        try self.pad();
        // Après l'indentation : le mapping pointe le premier caractère de CODE,
        // pas l'espace qui le précède.
        try self.mark(node);
        try self.stmt(node);
        try self.nl();
    }

    /// Le corps d'un statement, sans indentation initiale ni retour ligne final
    /// (les blocs internes gèrent leurs propres sauts). Utilisé aussi en position
    /// « inline » après `if (...) `, `else `, etc.
    fn stmt(self: *Printer, node: *const Node) Error!void {
        switch (node.kind) {
            // error recovery : le statement raté est réémis en span brut.
            .error_node => return self.span(node),
            // TS : déclarations type-only (round-trip en mode ts ; stripTypes les efface).
            .ts_type_alias => |t| {
                try self.w("type ");
                try self.tsType(t.id);
                try self.typeParams(t.type_params);
                try self.w(" = ");
                try self.tsType(t.@"type");
                try self.wc(';');
            },
            .ts_interface => |t| {
                try self.w("interface ");
                try self.tsType(t.id);
                try self.typeParams(t.type_params);
                if (t.extends.len > 0) {
                    try self.w(" extends ");
                    for (t.extends, 0..) |e, i| {
                        if (i != 0) try self.w(", ");
                        try self.tsType(e);
                    }
                }
                try self.wc(' ');
                try self.tsMembers(t.body);
            },
            // TS phase 3 : enum / namespace — SYNTAXE (round-trip ts ; stripTypes émet).
            .ts_enum => |e| {
                if (e.is_const) try self.w("const ");
                try self.w("enum ");
                try self.w(e.id.litText(self.source));
                if (e.members.len == 0) {
                    try self.w(" {}");
                    return;
                }
                try self.w(" {");
                try self.nl();
                self.depth += 1;
                for (e.members) |mem| {
                    const m = mem.kind.ts_enum_member;
                    try self.pad();
                    try self.span(m.name); // identifiant ou string (span brut)
                    if (m.initializer) |i| {
                        try self.w(" = ");
                        try self.expr(i, PREC_ASSIGN);
                    }
                    try self.wc(',');
                    try self.nl();
                }
                self.depth -= 1;
                try self.pad();
                try self.wc('}');
            },
            .ts_namespace => |n| {
                try self.w("namespace ");
                try self.expr(n.id, PREC_PRIMARY); // identifiant ou `A.B` (qualifié)
                try self.wc(' ');
                if (n.body.len == 0) {
                    try self.w("{}");
                    return;
                }
                try self.wc('{');
                try self.nl();
                self.depth += 1;
                for (n.body) |s| try self.stmtAt(s);
                self.depth -= 1;
                try self.pad();
                try self.wc('}');
            },
            .block_statement => try self.block(node),
            .expression_statement => |e| {
                if (needsWrap(e.expression)) {
                    try self.wc('(');
                    try self.expr(e.expression, PREC_SEQ);
                    try self.wc(')');
                } else try self.expr(e.expression, PREC_SEQ);
                try self.wc(';');
            },
            .if_statement => |s| {
                try self.w("if (");
                try self.expr(s.@"test", PREC_SEQ);
                try self.w(") ");
                try self.stmt(s.consequent);
                if (s.alternate) |alt| {
                    try self.w(" else ");
                    try self.stmt(alt);
                }
            },
            .while_statement => |s| {
                try self.w("while (");
                try self.expr(s.@"test", PREC_SEQ);
                try self.w(") ");
                try self.stmt(s.body);
            },
            .do_while_statement => |s| {
                try self.w("do ");
                try self.stmt(s.body);
                try self.w(" while (");
                try self.expr(s.@"test", PREC_SEQ);
                try self.w(");");
            },
            .for_statement => |s| {
                try self.w("for (");
                if (s.init) |init| try self.forHead(init);
                try self.w("; ");
                if (s.@"test") |t| try self.expr(t, PREC_SEQ);
                try self.w("; ");
                if (s.update) |u| try self.expr(u, PREC_SEQ);
                try self.w(") ");
                try self.stmt(s.body);
            },
            .for_of_statement => |s| {
                try self.w("for ");
                if (s.is_await) try self.w("await ");
                try self.wc('(');
                try self.forHead(s.left);
                try self.w(" of ");
                try self.expr(s.right, PREC_ASSIGN);
                try self.w(") ");
                try self.stmt(s.body);
            },
            .for_in_statement => |s| {
                try self.w("for (");
                try self.forHead(s.left);
                try self.w(" in ");
                try self.expr(s.right, PREC_SEQ);
                try self.w(") ");
                try self.stmt(s.body);
            },
            .return_statement => |s| {
                try self.w("return");
                if (s.argument) |a| {
                    try self.wc(' ');
                    try self.expr(a, PREC_SEQ);
                }
                try self.wc(';');
            },
            .throw_statement => |s| {
                try self.w("throw ");
                try self.expr(s.argument, PREC_SEQ);
                try self.wc(';');
            },
            .break_statement => |s| {
                try self.w("break");
                if (s.label) |l| {
                    try self.wc(' ');
                    try self.span(l);
                }
                try self.wc(';');
            },
            .continue_statement => |s| {
                try self.w("continue");
                if (s.label) |l| {
                    try self.wc(' ');
                    try self.span(l);
                }
                try self.wc(';');
            },
            .labeled_statement => |s| {
                try self.span(s.label);
                try self.w(": ");
                try self.stmt(s.body);
            },
            .variable_declaration => {
                try self.varDecl(node);
                try self.wc(';');
            },
            .function_declaration => try self.function(node, true),
            .class_declaration => try self.class(node),
            .switch_statement => try self.switchStmt(node),
            .try_statement => try self.tryStmt(node),
            .import_declaration => try self.importDecl(node),
            .export_named_declaration => try self.exportNamed(node),
            .export_default_declaration => |e| {
                try self.w("export default ");
                try self.expr(e.declaration, PREC_ASSIGN);
                try self.wc(';');
            },
            .export_all_declaration => |e| {
                try self.w("export *");
                if (e.exported) |ns| { // `export * as ns from …`
                    try self.w(" as ");
                    try self.w(ns.litText(self.source));
                }
                try self.w(" from ");
                try self.span(e.source);
                try self.attributes(e.attributes);
                try self.wc(';');
            },
            else => return error.Unprintable,
        }
    }

    fn forHead(self: *Printer, node: *const Node) Error!void {
        if (node.kind == .variable_declaration) {
            try self.varDecl(node);
        } else try self.target(node);
    }

    fn varDecl(self: *Printer, node: *const Node) Error!void {
        const v = node.kind.variable_declaration;
        try self.w(v.kind.keyword());
        try self.wc(' ');
        for (v.declarations, 0..) |d, i| {
            if (i != 0) try self.w(", ");
            const decl = d.kind.variable_declarator;
            try self.target(decl.id);
            if (decl.init) |init| {
                try self.w(" = ");
                try self.expr(init, PREC_ASSIGN);
            }
        }
    }

    fn switchStmt(self: *Printer, node: *const Node) Error!void {
        const s = node.kind.switch_statement;
        try self.w("switch (");
        try self.expr(s.discriminant, PREC_SEQ);
        try self.w(") {");
        try self.nl();
        self.depth += 1;
        for (s.cases) |case| {
            const c = case.kind.switch_case;
            try self.pad();
            if (c.@"test") |t| {
                try self.w("case ");
                try self.expr(t, PREC_SEQ);
                try self.wc(':');
            } else try self.w("default:");
            try self.nl();
            self.depth += 1;
            for (c.consequent) |st| try self.stmtAt(st);
            self.depth -= 1;
        }
        self.depth -= 1;
        try self.pad();
        try self.wc('}');
    }

    fn tryStmt(self: *Printer, node: *const Node) Error!void {
        const t = node.kind.try_statement;
        try self.w("try ");
        try self.block(t.block);
        if (t.handler) |h| {
            const c = h.kind.catch_clause;
            try self.w(" catch ");
            if (c.param) |p| {
                try self.wc('(');
                try self.target(p);
                try self.w(") ");
            }
            try self.block(c.body);
        }
        if (t.finalizer) |f| {
            try self.w(" finally ");
            try self.block(f);
        }
    }

    // ---- modules ----

    fn importDecl(self: *Printer, node: *const Node) Error!void {
        const imp = node.kind.import_declaration;
        try self.w("import ");
        if (imp.type_only) try self.w("type "); // TS : `import type { … }`
        if (imp.specifiers.len == 0) {
            // import "side-effect";  (avec ses attributs : `import './a.css'
            // with { type: 'css' }` — la forme la plus courante pour un asset)
            try self.span(imp.source);
            try self.attributes(imp.attributes);
            try self.wc(';');
            return;
        }
        // litText partout : sert l'import SYNTHÉTIQUE du transform JSX (noms +
        // source avec `synthetic_text`) ; fallback au span pour les imports parsés.
        var first = true;
        var in_named = false;
        for (imp.specifiers) |spec| {
            switch (spec.kind) {
                .import_default_specifier => |d| {
                    if (!first) try self.w(", ");
                    try self.w(d.local.litText(self.source));
                    first = false;
                },
                .import_namespace_specifier => |ns| {
                    if (!first) try self.w(", ");
                    try self.w("* as ");
                    try self.w(ns.local.litText(self.source));
                    first = false;
                },
                .import_specifier => |is| {
                    if (!in_named) {
                        if (!first) try self.w(", ");
                        try self.w("{ ");
                        in_named = true;
                        first = false;
                    } else try self.w(", ");
                    if (is.type_only) try self.w("type "); // `{ type A, B }`
                    try self.w(is.imported.litText(self.source));
                    if (!std.mem.eql(u8, is.imported.litText(self.source), is.local.litText(self.source))) {
                        try self.w(" as ");
                        try self.w(is.local.litText(self.source));
                    }
                },
                else => return error.Unprintable,
            }
        }
        if (in_named) try self.w(" }");
        try self.w(" from ");
        try self.w(imp.source.litText(self.source));
        try self.attributes(imp.attributes);
        try self.wc(';');
    }

    /// La clause `with { type: 'json' }` (ES2025), rien si elle est absente.
    /// Réémet `assert` si la source disait `assert` : un formateur ne réécrit pas
    /// la syntaxe de l'utilisateur, même dépréciée.
    fn attributes(self: *Printer, attrs: ast.Node.Attributes) Error!void {
        if (attrs.entries.len == 0) return;
        try self.w(if (attrs.deprecated_assert) " assert { " else " with { ");
        for (attrs.entries, 0..) |entry, i| {
            if (i != 0) try self.w(", ");
            const a = entry.kind.import_attribute;
            try self.w(a.key.litText(self.source));
            try self.w(": ");
            try self.w(a.value.litText(self.source));
        }
        try self.w(" }");
    }

    fn exportNamed(self: *Printer, node: *const Node) Error!void {
        const e = node.kind.export_named_declaration;
        try self.w("export ");
        if (e.declaration) |d| {
            try self.stmt(d); // export const/let/var/function/class …
            return;
        }
        if (e.type_only) try self.w("type "); // TS : `export type { … }`
        try self.w("{ ");
        for (e.specifiers, 0..) |spec, i| {
            if (i != 0) try self.w(", ");
            const es = spec.kind.export_specifier;
            if (es.type_only) try self.w("type "); // `{ type A, B }`
            try self.span(es.local);
            if (!std.mem.eql(u8, es.local.text(self.source), es.exported.text(self.source))) {
                try self.w(" as ");
                try self.span(es.exported);
            }
        }
        try self.w(" }");
        if (e.source) |src| {
            try self.w(" from ");
            try self.span(src);
            try self.attributes(e.attributes);
        }
        try self.wc(';');
    }
};

fn isWordUnary(op: ast.UnaryOp) bool {
    return switch (op) {
        .typeof_, .void_, .delete_ => true,
        else => false,
    };
}

/// Imprime un programme complet en JS (sémantiquement équivalent à la source).
pub fn print(node: *const Node, source: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) Printer.Error!void {
    try printWith(node, source, out, .{}, gpa);
}

/// `print`, en enregistrant les positions dans `sink.maps`.
///
/// Avec un sink vide la sortie est **bit-identique** à `print` : le marquage
/// n'ajoute pas un octet au texte, il remplit une liste à côté.
pub fn printWith(
    node: *const Node,
    source: []const u8,
    out: *std.ArrayList(u8),
    sink: Sink,
    gpa: std.mem.Allocator,
) Printer.Error!void {
    var p = Printer{ .source = source, .out = out, .gpa = gpa, .maps = sink.maps };
    const prog = node.kind.program;
    for (prog.body) |stmt| try p.stmtAt(stmt);
}

/// Imprime UN statement (indenté, terminé par un saut de ligne).
///
/// Ajouté en 0.3.0 pour les consommateurs qui recomposent un programme au lieu
/// de le réémettre tel quel — un bundler concatène des modules en choisissant
/// statement par statement ce qu'il garde (les `import` disparaissent, les
/// `export const x` perdent leur `export`…). Sans ça il faudrait fabriquer un
/// faux `program` par statement.
pub fn printStatement(node: *const Node, source: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) Printer.Error!void {
    try printStatementWith(node, source, out, .{}, gpa);
}

/// `printStatement`, en enregistrant les positions. C'est CETTE variante qu'un
/// bundler appelle : il imprime statement par statement, et compose les
/// mappings de chaque module en les décalant de sa position dans le bundle.
pub fn printStatementWith(
    node: *const Node,
    source: []const u8,
    out: *std.ArrayList(u8),
    sink: Sink,
    gpa: std.mem.Allocator,
) Printer.Error!void {
    var p = Printer{ .source = source, .out = out, .gpa = gpa, .maps = sink.maps };
    try p.stmtAt(node);
}

/// Imprime UNE expression (sans indentation ni `;`), parenthésée si sa
/// précédence l'exige au niveau assignation. Le pendant de `printStatement`
/// pour, par exemple, lier un `export default <expression>` à un nom fabriqué.
pub fn printExpression(node: *const Node, source: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) Printer.Error!void {
    try printExpressionWith(node, source, out, .{}, gpa);
}

/// `printExpression`, en enregistrant les positions.
pub fn printExpressionWith(
    node: *const Node,
    source: []const u8,
    out: *std.ArrayList(u8),
    sink: Sink,
    gpa: std.mem.Allocator,
) Printer.Error!void {
    var p = Printer{ .source = source, .out = out, .gpa = gpa, .maps = sink.maps };
    try p.expr(node, PREC_ASSIGN);
}

// ------------------------------------------------------------------ tests

const parser = @import("parser.zig");

/// Parse `src`, imprime, et renvoie la sortie JS (arena libérée par l'appelant
/// via le retour dupliqué dans `gpa`).
fn printSource(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const program = (try parser.parse(arena.allocator(), src)).program;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try print(program, src, &out, gpa);
    return out.toOwnedSlice(gpa);
}

/// Le debug-tree (structure + textes de span, sans offsets) d'un source.
fn treeOf(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const program = (try parser.parse(arena.allocator(), src)).program;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try ast.printTree(program, src, &out, gpa);
    return out.toOwnedSlice(gpa);
}

/// Vérifie l'invariant round-trip : parse(print(parse(src))) ≡ parse(src)
/// (mêmes debug-trees).
fn expectRoundtrip(gpa: std.mem.Allocator, src: []const u8) !void {
    const out = try printSource(gpa, src);
    defer gpa.free(out);
    const t1 = try treeOf(gpa, src);
    defer gpa.free(t1);
    const t2 = try treeOf(gpa, out);
    defer gpa.free(t2);
    std.testing.expectEqualStrings(t1, t2) catch |err| {
        std.debug.print("\n--- round-trip DIVERGE pour: {s}\n--- réimprimé: {s}\n", .{ src, out });
        return err;
    };
}

fn expectPrint(gpa: std.mem.Allocator, src: []const u8, expected: []const u8) !void {
    const out = try printSource(gpa, src);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "printer : parenthèses selon la précédence" {
    const gpa = std.testing.allocator;
    // Le fils + (plus faible) sous un * -> parenthèses recréées.
    try expectPrint(gpa, "(a + b) * c", "(a + b) * c;\n");
    // Associativité gauche : a - (b - c) garde ses parens ; a - b - c non.
    try expectPrint(gpa, "a - b - c", "a - b - c;\n");
    try expectPrint(gpa, "a - (b - c)", "a - (b - c);\n");
    // ** associatif à droite.
    try expectPrint(gpa, "2 ** 3 ** 2", "2 ** 3 ** 2;\n");
    try expectPrint(gpa, "(2 ** 3) ** 2", "(2 ** 3) ** 2;\n");
    // unaire à gauche de ** -> parens obligatoires.
    try expectPrint(gpa, "(-2) ** 2", "(-2) ** 2;\n");
}

test "printer : ambiguïtés de tête de statement (round-trip)" {
    const gpa = std.testing.allocator;
    // Objet en tête -> parens. `f((a,b))` -> séquence en argument gardée.
    try expectPrint(gpa, "({ a: 1 })", "({ a: 1 });\n");
    try expectPrint(gpa, "f((a, b))", "f((a, b));\n");
    try expectPrint(gpa, "() => ({})", "() => ({});\n");
    // IIFE / arrow ambigus : le round-trip est le juge (la FORME des parens peut
    // varier — `(function(){}())` vs `(function(){})()` — tant que l'AST tient).
    try expectRoundtrip(gpa, "(function () {})()");
    try expectRoundtrip(gpa, "(class {})");
    try expectRoundtrip(gpa, "({}).toString()");
}

test "printer round-trip : échantillon représentatif" {
    const gpa = std.testing.allocator;
    const samples = [_][]const u8{
        "const x = 1, y = 2;",
        "let { a, b: c, d = 3, ...rest } = obj;",
        "const [p, , q = 5, ...tail] = xs;",
        "a ? b : c ? d : e;",
        "x = y = z;",
        "a ??= b; c ||= d; e &&= f;",
        "const n = 123n + 0xFFn;",
        "async function* g(a, b = 1, ...r) { yield await f(a); yield* h(); }",
        "class C extends B { x = 1; static s = 2; get v() { return 1; } async *m() {} [k]() {} }",
        "const o = { foo() {}, get x() { return 1; }, [k]: v, ...s, n: 1 };",
        "for (let i = 0, j = n; i < j; i++, j--) swap(i, j);",
        "for (const x of xs) {} for (const k in obj) {}",
        "try { f(); } catch (e) { g(e); } finally { h(); }",
        "switch (x) { case 1: a(); break; default: b(); }",
        "label: while (1) { break label; continue label; }",
        "throw new Error('boom');",
        "const re = /ab+c/gi; const s = `x ${a + b} y`;",
        "p.then(r => r.json()).catch(e => log(e));",
        "new Foo(1, 2); new (bar())();",
        "obj?.a?.[b]?.(c);",
        "typeof x; void 0; delete a.b; -(-a); !!flag;",
        "export const z = 1; export default function () {}; export { a, b as c };",
        "import d, { e, f as g } from 'm'; import * as ns from 'n'; import 'side';",
    };
    for (samples) |s| try expectRoundtrip(gpa, s);
}

test "printer : champs/méthodes privés #x (ES2022)" {
    const gpa = std.testing.allocator;
    try expectRoundtrip(gpa, "class C { #x = 1; static #s = 2; #m() { return this.#x; } has(o) { return #x in o; } }");
    // clé privée émise avec le `#`.
    try expectPrint(gpa, "class C { #x = 1; }", "class C {\n  #x = 1;\n}\n");
}

test "printer : cover grammar shorthand-défaut en objet" {
    const gpa = std.testing.allocator;
    // `({ x = 1 } = o)` : le shorthand-défaut n'est valide que comme cible.
    try expectRoundtrip(gpa, "({ x = 1 } = o)");
    try expectRoundtrip(gpa, "({ a, b = 2, c: d = 3, ...rest } = o)");
    try expectPrint(gpa, "({ x = 1 } = o)", "({ x = 1 } = o);\n");
}

test "printer : export * as ns from (ES2020) — les deux formes" {
    const gpa = std.testing.allocator;
    try expectPrint(gpa, "export * from './x'", "export * from './x';\n");
    try expectPrint(gpa, "export * as ns from './x'", "export * as ns from './x';\n");
    // `default` est un nom d'export légal derrière `as`.
    try expectPrint(gpa, "export * as default from './x'", "export * as default from './x';\n");
    try expectRoundtrip(gpa, "export * from './x'");
    try expectRoundtrip(gpa, "export * as ns from './x'");
    try expectRoundtrip(gpa, "export * as default from './x'");
}

test "printer : import attributes (ES2025) sur les trois formes statiques" {
    const gpa = std.testing.allocator;
    try expectPrint(gpa, "import d from './d.json' with { type: 'json' }", "import d from './d.json' with { type: 'json' };\n");
    // Side-effect : la forme la plus courante pour un asset.
    try expectPrint(gpa, "import './a.css' with { type: 'css' }", "import './a.css' with { type: 'css' };\n");
    try expectPrint(gpa, "export { a } from './b.json' with { type: 'json' }", "export { a } from './b.json' with { type: 'json' };\n");
    try expectPrint(gpa, "export * from './b.json' with { type: 'json' }", "export * from './b.json' with { type: 'json' };\n");
    try expectPrint(gpa, "export * as d from './b.json' with { type: 'json' }", "export * as d from './b.json' with { type: 'json' };\n");
    // Plusieurs entrées, clé string, virgule finale.
    try expectPrint(gpa, "import x from './y' with { 'a-b': 'v', type: 'json', }", "import x from './y' with { 'a-b': 'v', type: 'json' };\n");
}

test "printer : `assert` déprécié est PRÉSERVÉ (pas réécrit en `with`)" {
    const gpa = std.testing.allocator;
    try expectPrint(gpa, "import d from './d.json' assert { type: 'json' }", "import d from './d.json' assert { type: 'json' };\n");
    try expectRoundtrip(gpa, "import d from './d.json' assert { type: 'json' }");
}

test "printer : import(src, options) — le 2e argument (ES2025)" {
    const gpa = std.testing.allocator;
    try expectPrint(gpa, "import('./x')", "import('./x');\n");
    try expectPrint(gpa, "import('./x.json', { with: { type: 'json' } })", "import('./x.json', { with: { type: 'json' } });\n");
    try expectRoundtrip(gpa, "const p = import('./x.json', { with: { type: 'json' } })");
}

test "printer : round-trip des attributs sur tout le spectre" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{
        "import './a.css' with { type: 'css' }",
        "import d from './d.json' with { type: 'json' }",
        "import * as ns from './m.json' with { type: 'json' }",
        "import a, { b as c } from './m.json' with { type: 'json' }",
        "export { a } from './b.json' with { type: 'json' }",
        "export * from './b.json' with { type: 'json' }",
        "export * as data from './b.json' assert { type: 'json' }",
        "import x from './y' with { 'a-b': 'v', type: 'json' }",
    }) |src| try expectRoundtrip(gpa, src);
}

// ---- le flux de mappings (source maps) ----

/// Imprime `src` en collectant les positions. Rend la sortie ET les mappings.
fn printMapped(gpa: std.mem.Allocator, src: []const u8) !struct { code: []u8, maps: []Mapping } {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const program = (try parser.parse(arena.allocator(), src)).program;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var maps: std.ArrayList(Mapping) = .empty;
    errdefer maps.deinit(gpa);
    try printWith(program, src, &out, .{ .maps = &maps }, gpa);
    return .{ .code = try out.toOwnedSlice(gpa), .maps = try maps.toOwnedSlice(gpa) };
}

test "mappings : un sink vide laisse la sortie BIT-IDENTIQUE" {
    const gpa = std.testing.allocator;
    const src = "const a = 1;\nfunction f(x) { return x + a; }\n";
    const plain = try printSource(gpa, src);
    defer gpa.free(plain);
    const mapped = try printMapped(gpa, src);
    defer gpa.free(mapped.code);
    defer gpa.free(mapped.maps);
    // Le marquage remplit une liste À CÔTÉ : il n'ajoute pas un octet au texte.
    try std.testing.expectEqualStrings(plain, mapped.code);
    try std.testing.expect(mapped.maps.len > 0);
}

test "mappings : chaque position source pointe bien le nœud d'origine" {
    const gpa = std.testing.allocator;
    //             0123456789...
    const src = "const alpha = 1;\nconst beta = alpha;\n";
    const r = try printMapped(gpa, src);
    defer gpa.free(r.code);
    defer gpa.free(r.maps);

    // Tout mapping doit désigner un offset réel du source, et la sortie qu'il
    // annonce doit exister.
    for (r.maps) |m| {
        try std.testing.expect(m.src < src.len);
        try std.testing.expect(m.out <= r.code.len);
    }
    // L'identifiant `alpha` de la LIGNE 2 (offset 30) est mappé : c'est la
    // référence, pas la déclaration.
    const ref_at = std.mem.lastIndexOf(u8, src, "alpha").?;
    var found = false;
    for (r.maps) |m| {
        if (m.src == ref_at) found = true;
    }
    try std.testing.expect(found);
}

test "mappings : un identifiant RENOMMÉ mappe vers son span d'origine" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "const longName = 1;\nconsole.log(longName);\n";
    const program = (try parser.parse(a, src)).program;

    // On renomme comme le fait un linker : le NŒUD reste, seul son texte change.
    const sem = @import("semantic.zig").analyze(a, program, src);
    var it = sem.scopes.items[0].bindings.valueIterator();
    while (it.next()) |b| {
        if (std.mem.eql(u8, b.*.name, "longName")) b.*.new_name = "z";
    }
    @import("mangler.zig").applyRenames(sem);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var maps: std.ArrayList(Mapping) = .empty;
    defer maps.deinit(gpa);
    try printWith(program, src, &out, .{ .maps = &maps }, gpa);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "const z = 1") != null);
    // LE point : le mapping du `z` émis pointe le `longName` du source. Sans ça
    // un bundle renommé serait indébogable.
    const decl_at = std.mem.indexOf(u8, src, "longName").?;
    const ref_at = std.mem.lastIndexOf(u8, src, "longName").?;
    var saw_decl = false;
    var saw_ref = false;
    for (maps.items) |m| {
        if (m.src == decl_at) saw_decl = true;
        if (m.src == ref_at) saw_ref = true;
    }
    try std.testing.expect(saw_decl);
    try std.testing.expect(saw_ref);
}

test "mappings : le folding GARDE le span de l'expression d'origine" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "console.log(1 + 2 * 3);\n";
    const program = (try parser.parse(a, src)).program;
    _ = @import("transformer.zig").transform(program, src, a);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var maps: std.ArrayList(Mapping) = .empty;
    defer maps.deinit(gpa);
    try printWith(program, src, &out, .{ .maps = &maps }, gpa);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "log(7)") != null);
    // Le `7` fabriqué par le fold porte le span de `1 + 2 * 3` : cliquer sur le
    // `7` du bundle renvoie à l'expression qui l'a produit. C'est mieux que
    // « pas de mapping », et c'est le transformer qui l'offre — on le fixe.
    const expr_at = std.mem.indexOf(u8, src, "1 + 2").?;
    var mapped_to_expr = false;
    for (maps.items) |m| {
        if (m.src == expr_at) mapped_to_expr = true;
    }
    try std.testing.expect(mapped_to_expr);
}

test "mappings : le JSX injecté n'est PAS mappé (aucun span à pointer)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "const A = () => <b>hi</b>;\n";
    const program = (try parser.parseWith(a, src, true, false)).program;
    _ = @import("jsx_transform.zig").transform(program, src, a, .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var maps: std.ArrayList(Mapping) = .empty;
    defer maps.deinit(gpa);
    try printWith(program, src, &out, .{ .maps = &maps }, gpa);

    // `jsxTransform` PRÉFIXE le module d'un import qu'aucun caractère du source
    // n'a écrit. Il ne doit produire aucun mapping : le premier commence APRÈS.
    const import_end = std.mem.indexOf(u8, out.items, "\n").? + 1;
    for (maps.items) |m| {
        try std.testing.expect(m.out >= import_end);
    }
    try std.testing.expect(maps.items.len > 0);
}

test "mappings : printStatementWith compose statement par statement" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "const a = 1;\nconst b = 2;\n";
    const program = (try parser.parse(a, src)).program;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var maps: std.ArrayList(Mapping) = .empty;
    defer maps.deinit(gpa);
    // Ce que fait un bundler : il choisit les statements un par un.
    for (program.kind.program.body) |st| {
        try printStatementWith(st, src, &out, .{ .maps = &maps }, gpa);
    }
    // Les offsets de sortie sont CROISSANTS : chaque statement s'ajoute derrière
    // le précédent, donc les mappings d'un module composent par simple décalage.
    var prev: u32 = 0;
    for (maps.items) |m| {
        try std.testing.expect(m.out >= prev);
        prev = m.out;
    }
    try std.testing.expect(maps.items.len >= 4); // 2 statements + 2 identifiants
}
