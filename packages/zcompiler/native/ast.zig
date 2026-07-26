//! L'AST : nœuds inspirés d'ESTree, en tagged unions Zig.
//!
//! `Node` = un span (`start`/`end`) + un `kind` (union). Les feuilles
//! (`number_literal`/`string_literal`/`identifier`) n'ont pas de payload : leur
//! texte se lit dans le source via le span (`node.text(source)`) — aucune copie.
//! Les enfants sont des `*Node` alloués dans l'arena du parser.

const std = @import("std");

/// Opérateurs binaires (cf. la table de précédence dans parser.zig).
pub const BinaryOp = enum {
    nullish, // ??
    logical_or, // ||
    logical_and, // &&
    bor, // |
    bxor, // ^
    band, // &
    eq, // ==
    neq, // !=
    strict_eq, // ===
    strict_neq, // !==
    lt, // <
    gt, // >
    le, // <=
    ge, // >=
    in_, // in
    instance_of, // instanceof
    shl, // <<
    shr, // >>
    ushr, // >>>
    add, // +
    sub, // -
    mul, // *
    div, // /
    rem, // %
    exp, // **

    pub fn symbol(self: BinaryOp) []const u8 {
        return switch (self) {
            .nullish => "??",
            .logical_or => "||",
            .logical_and => "&&",
            .bor => "|",
            .bxor => "^",
            .band => "&",
            .eq => "==",
            .neq => "!=",
            .strict_eq => "===",
            .strict_neq => "!==",
            .lt => "<",
            .gt => ">",
            .le => "<=",
            .ge => ">=",
            .in_ => "in",
            .instance_of => "instanceof",
            .shl => "<<",
            .shr => ">>",
            .ushr => ">>>",
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .rem => "%",
            .exp => "**",
        };
    }
};

/// Opérateurs unaires préfixes.
pub const UnaryOp = enum {
    not, // !
    neg, // -
    pos, // +
    bitwise_not, // ~
    typeof_, // typeof
    void_, // void
    delete_, // delete

    pub fn symbol(self: UnaryOp) []const u8 {
        return switch (self) {
            .not => "!",
            .neg => "-",
            .pos => "+",
            .bitwise_not => "~",
            .typeof_ => "typeof",
            .void_ => "void",
            .delete_ => "delete",
        };
    }
};

/// Incrément / décrément (`++` / `--`), préfixe ou postfixe.
pub const UpdateOp = enum {
    inc, // ++
    dec, // --

    pub fn symbol(self: UpdateOp) []const u8 {
        return switch (self) {
            .inc => "++",
            .dec => "--",
        };
    }
};

/// Opérateurs d'assignation.
pub const AssignOp = enum {
    assign, // =
    add_assign, // +=
    sub_assign, // -=
    mul_assign, // *=
    div_assign, // /=
    bor_assign, // |=
    bxor_assign, // ^=
    band_assign, // &=
    shl_assign, // <<=
    shr_assign, // >>=
    ushr_assign, // >>>=
    land_assign, // &&=
    lor_assign, // ||=
    nullish_assign, // ??=

    pub fn symbol(self: AssignOp) []const u8 {
        return switch (self) {
            .assign => "=",
            .add_assign => "+=",
            .sub_assign => "-=",
            .mul_assign => "*=",
            .div_assign => "/=",
            .bor_assign => "|=",
            .bxor_assign => "^=",
            .band_assign => "&=",
            .shl_assign => "<<=",
            .shr_assign => ">>=",
            .ushr_assign => ">>>=",
            .land_assign => "&&=",
            .lor_assign => "||=",
            .nullish_assign => "??=",
        };
    }
};

/// `const` / `let` / `var`.
pub const DeclarationKind = enum {
    @"const",
    let,
    @"var",

    pub fn keyword(self: DeclarationKind) []const u8 {
        return @tagName(self);
    }
};

/// Nature d'une méthode de classe.
pub const MethodKind = enum {
    method,
    constructor,
    getter,
    setter,

    pub fn label(self: MethodKind) []const u8 {
        return switch (self) {
            .method => "method",
            .constructor => "constructor",
            .getter => "getter",
            .setter => "setter",
        };
    }
};

pub const Node = struct {
    start: u32,
    end: u32,
    kind: Kind,

    pub const Kind = union(enum) {
        program: Program,
        // Statements
        block_statement: Block,
        if_statement: If,
        while_statement: While,
        for_statement: For,
        for_of_statement: ForInOf,
        for_in_statement: ForInOf,
        return_statement: Return,
        function_declaration: Function,
        variable_declaration: VariableDeclaration,
        variable_declarator: VariableDeclarator,
        expression_statement: ExpressionStatement,
        // Expressions
        number_literal: Literal, // valeur = source[start..end] OU synthetic_text
        bigint_literal, // `123n` / `0xFFn` — span brut (suffixe `n` inclus)
        string_literal: Literal, // texte brut = source[start..end], OU synthetic_text (string fabriquée : JSX transform)
        boolean_literal: Literal, // true / false (span, ou synthetic_text pour un fold)
        null_literal, // null
        regex_literal, // /pattern/flags (brut, non décodé)
        identifier: Literal, // nom = source[start..end], ou synthetic_text (mangling)
        private_name, // #x (clé privée de classe / accès `this.#x` / `#x in o`)
        error_node, // trou de l'arbre : rien n'a pu être parsé ici (error recovery)
        binary_expression: Binary,
        unary_expression: Unary,
        update_expression: Update,
        await_expression: Await,
        yield_expression: Yield,
        conditional_expression: Conditional,
        assignment_expression: Assignment,
        call_expression: Call,
        member_expression: Member,
        function_expression: Function,
        arrow_function: Arrow,
        array_expression: Array,
        sequence_expression: Sequence,
        object_expression: Object,
        property: Property,
        spread_element: Spread,
        // Patterns (cibles de destructuring)
        array_pattern: ArrayPattern,
        object_pattern: ObjectPattern,
        assignment_pattern: AssignmentPattern,
        rest_element: RestElement,
        // Template literals
        template_literal: TemplateLiteral,
        template_element: TemplateElement,
        tagged_template_expression: TaggedTemplate,
        // this / super / new / classes
        this_expression,
        super_expression, // `super` (valide seulement en callee d'appel / objet de membre)
        meta_property, // `import.meta` (texte brut = source[start..end])
        new_expression: New,
        class_declaration: Class,
        class_expression: Class,
        class_body: ClassBody,
        method_definition: MethodDefinition,
        property_definition: PropertyDefinition,
        // Statements de contrôle
        throw_statement: Throw,
        try_statement: Try,
        catch_clause: Catch,
        switch_statement: Switch,
        switch_case: SwitchCase,
        break_statement: BreakContinue,
        continue_statement: BreakContinue,
        labeled_statement: Labeled,
        do_while_statement: DoWhile,
        // Modules (import / export)
        import_declaration: ImportDeclaration,
        import_default_specifier: ImportDefaultSpecifier,
        import_specifier: ImportSpecifier,
        import_namespace_specifier: ImportNamespaceSpecifier,
        import_expression: ImportExpression,
        import_attribute: ImportAttribute, // `type: 'json'` dans un `with { … }`
        export_named_declaration: ExportNamed,
        export_default_declaration: ExportDefault,
        export_all_declaration: ExportAll,
        export_specifier: ExportSpecifier,
        // JSX (extension de grammaire, opt-in — cf. section « JSX » du CLAUDE.md)
        jsx_element: JSXElement,
        jsx_fragment: JSXFragment,
        jsx_opening_element: JSXOpeningElement,
        jsx_closing_element: JSXClosingElement,
        jsx_identifier: Literal, // div / App (feuille ; synthetic_text si composant renommé)
        jsx_member_expression: JSXMemberExpression, // A.B.C
        jsx_namespaced_name: JSXNamespacedName, // svg:path
        jsx_attribute: JSXAttribute, // a="s" / a={e} / a (bare)
        jsx_spread_attribute: JSXSpreadAttribute, // {...props}
        jsx_expression_container: JSXExpressionContainer, // {expr} / {} / {/* c */}
        jsx_text, // texte brut entre balises (span, aucun trimming)
        // TypeScript (opt-in, phase 1 — cf. section « TypeScript » du CLAUDE.md).
        // Les nœuds de TYPE (un monde à part) : le semantic les IGNORE entièrement
        // (isTypeNode), le transformer les EFFACE (stripTypes).
        ts_type_reference: TsTypeRef, // T, Foo.Bar, Array<T>
        ts_qualified_name: TsQualified, // Foo.Bar (dans un type)
        ts_keyword_type, // number/string/boolean/void/any/unknown/never/object/symbol/bigint (span)
        ts_literal_type: TsLiteralType, // "a" / 1 / true (en position de type)
        ts_union_type: TsTypeList, // A | B
        ts_intersection_type: TsTypeList, // A & B
        ts_parenthesized_type: TsParenType, // (T)
        ts_array_type: TsArrayType, // T[]
        ts_tuple_type: TsTupleType, // [A, B, ...C[]]
        ts_rest_type: TsRestType, // ...T (dans un tuple)
        ts_function_type: TsFunctionType, // (a: A) => B
        ts_type_literal: TsTypeLiteral, // { a: T; b?: U }
        ts_property_signature: TsPropertySignature, // a: T / readonly a?: T (dans un type objet)
        ts_method_signature: TsMethodSignature, // m(x: A): B
        ts_typeof_type: TsTypeofType, // typeof x
        ts_keyof_type: TsKeyofType, // keyof T
        ts_indexed_access_type: TsIndexedAccess, // T[K]
        ts_index_signature: TsIndexSignature, // { [k: string]: T }
        ts_type_parameter: TsTypeParam, // <T extends C = D>
        ts_type_alias: TsTypeAlias, // type A<T> = … (type-only, effacé entier)
        ts_interface: TsInterface, // interface I extends J { … } (type-only, effacé entier)
        // Nœuds ts porteurs d'une VALEUR : traversés par le semantic (leur valeur
        // se résout), leur type est un sous-nœud ts_type_* sauté.
        ts_typed: TsTyped, // binding annoté : x: T / a?: T (params, catch, déclarateur)
        ts_as_expression: TsAs, // x as T / x as const
        ts_satisfies_expression: TsSatisfies, // x satisfies T
        ts_non_null_expression: TsNonNull, // x!
        // TS phase 3 : constructions qui GÉNÈRENT du JS (stripTypes ÉMET, ne retire
        // pas). Double nature : le semantic déclare le binding (valeur), le printer
        // rend la SYNTAXE (round-trip), stripTypes émet l'IIFE compilée.
        ts_enum: TsEnum, // enum E { A, B = 5 } (+ const enum)
        ts_enum_member: TsEnumMember, // A / B = 5
        ts_namespace: TsNamespace, // namespace N { export const x = 1; }
        ts_param_property: TsParamProperty, // constructor(private x) -> this.x = x
    };

    /// Littéral (nombre / booléen) émis via son span source, SAUF si
    /// `synthetic_text` est renseigné : c'est le cas des nœuds fabriqués par le
    /// transformer (ex. le `7` de `1 + 2 * 3`), qui n'ont pas de span source. Le
    /// texte synthétique est alloué dans l'arena. C'est LA convention pour tous
    /// les nœuds synthétiques : porter leur texte, jamais un span bidon.
    pub const Literal = struct { synthetic_text: ?[]const u8 = null };

    pub const Program = struct { body: []*Node };
    pub const Block = struct { body: []*Node };
    pub const If = struct { @"test": *Node, consequent: *Node, alternate: ?*Node };
    pub const While = struct { @"test": *Node, body: *Node };
    pub const For = struct { init: ?*Node, @"test": ?*Node, update: ?*Node, body: *Node };
    /// `for (left of right)` et `for (left in right)`. `left` = déclaration ou
    /// cible (pattern converti).
    /// `for (left of right)` / `for (left in right)`. `is_await` : `for await`
    /// (itération async), uniquement pour for-of.
    pub const ForInOf = struct { left: *Node, right: *Node, body: *Node, is_await: bool = false };
    pub const Return = struct { argument: ?*Node };
    /// Déclaration ET expression de fonction. `id` requis pour la déclaration,
    /// optionnel (peut être null) pour l'expression.
    /// `return_type`/`type_params` : TypeScript (null/vide en JS ; effacés par stripTypes).
    pub const Function = struct { id: ?*Node, params: []*Node, body: *Node, is_async: bool, is_generator: bool, return_type: ?*Node = null, type_params: []*Node = &.{} };
    pub const Arrow = struct { params: []*Node, body: *Node, expression: bool, is_async: bool, return_type: ?*Node = null };
    pub const VariableDeclaration = struct { kind: DeclarationKind, declarations: []*Node };
    pub const VariableDeclarator = struct { id: *Node, init: ?*Node };
    pub const ExpressionStatement = struct { expression: *Node };
    pub const Binary = struct { operator: BinaryOp, left: *Node, right: *Node };
    pub const Unary = struct { operator: UnaryOp, operand: *Node };
    pub const Update = struct { operator: UpdateOp, argument: *Node, prefix: bool };
    pub const Await = struct { argument: *Node };
    /// `yield`, `yield x` (argument optionnel), `yield* iter` (delegate).
    pub const Yield = struct { argument: ?*Node, delegate: bool };
    pub const Conditional = struct { @"test": *Node, consequent: *Node, alternate: *Node };
    pub const Assignment = struct { operator: AssignOp, target: *Node, value: *Node };
    /// `type_args` : arguments de type d'un appel générique `foo<T>(x)` (TS phase 2 ;
    /// effacés par stripTypes).
    pub const Call = struct { callee: *Node, arguments: []*Node, optional: bool, type_args: []*Node = &.{} };
    pub const Member = struct { object: *Node, property: *Node, computed: bool, optional: bool };
    /// `elements` : un `null` = trou (elision `[1, , 3]`).
    pub const Array = struct { elements: []?*Node };
    pub const Sequence = struct { expressions: []*Node };
    pub const Object = struct { properties: []*Node };
    /// `shorthand` : `{ x }` (key == value). `computed` : `{ [expr]: v }`.
    pub const Property = struct { key: *Node, value: *Node, shorthand: bool, computed: bool };
    pub const Spread = struct { argument: *Node };
    /// `null` = trou dans un ArrayPattern (`[a, , c]`).
    pub const ArrayPattern = struct { elements: []?*Node };
    pub const ObjectPattern = struct { properties: []*Node };
    /// Valeur par défaut : `a = 1`. `left` = cible, `right` = valeur.
    pub const AssignmentPattern = struct { left: *Node, right: *Node };
    pub const RestElement = struct { argument: *Node };
    /// Invariant ESTree : `quasis.len == expressions.len + 1`.
    pub const TemplateLiteral = struct { quasis: []*Node, expressions: []*Node };
    /// `tail` = dernier quasi. Le span couvre le texte brut (sans délimiteurs).
    pub const TemplateElement = struct { tail: bool };
    pub const TaggedTemplate = struct { tag: *Node, quasi: *Node, type_args: []*Node = &.{} };
    pub const New = struct { callee: *Node, arguments: []*Node, type_args: []*Node = &.{} };
    /// `type_params`/`super_type_args`/`implements` : TypeScript (`class C<T> extends
    /// B<U> implements I` — effacés par stripTypes).
    pub const Class = struct { id: ?*Node, superclass: ?*Node, body: *Node, type_params: []*Node = &.{}, super_type_args: []*Node = &.{}, implements: []*Node = &.{} };
    pub const ClassBody = struct { members: []*Node };
    pub const MethodDefinition = struct { key: *Node, params: []*Node, body: *Node, kind: MethodKind, static: bool, computed: bool, is_async: bool, is_generator: bool, return_type: ?*Node = null, type_params: []*Node = &.{} };
    /// `type_annotation`/`optional` : TypeScript (`x: T`, `x?: T`) — effacés par stripTypes.
    pub const PropertyDefinition = struct { key: *Node, value: ?*Node, static: bool, computed: bool, type_annotation: ?*Node = null, optional: bool = false };
    pub const Throw = struct { argument: *Node };
    pub const Try = struct { block: *Node, handler: ?*Node, finalizer: ?*Node };
    pub const Catch = struct { param: ?*Node, body: *Node };
    pub const Switch = struct { discriminant: *Node, cases: []*Node };
    /// `test` null = clause `default`.
    pub const SwitchCase = struct { @"test": ?*Node, consequent: []*Node };
    pub const BreakContinue = struct { label: ?*Node };
    pub const Labeled = struct { label: *Node, body: *Node };
    pub const DoWhile = struct { body: *Node, @"test": *Node };
    /// La clause `with { … }` d'une déclaration de module (ES2025). `entries` sont
    /// des nœuds `import_attribute` ; `deprecated_assert` retient que la source
    /// disait `assert { … }` (l'ancien mot-clé des import assertions, accepté en
    /// lecture) pour le réémettre tel quel — un formateur ne réécrit pas la
    /// syntaxe de l'utilisateur dans son dos.
    pub const Attributes = struct { entries: []*Node = &.{}, deprecated_assert: bool = false };

    /// `type_only` : `import type { A } from …` (déclaration entière type-only, TS).
    /// `attributes` : `with { type: 'json' }` (ES2025 — cf. `ImportAttribute`).
    pub const ImportDeclaration = struct {
        specifiers: []*Node,
        source: *Node,
        type_only: bool = false,
        attributes: Attributes = .{},
    };
    pub const ImportDefaultSpecifier = struct { local: *Node };
    /// `import { a as b }` : `imported` = a, `local` = b (= a sans `as`). `type_only`
    /// : `import { type a, b }` (spécificateur type-only inline, TS — retiré par strip).
    pub const ImportSpecifier = struct { imported: *Node, local: *Node, type_only: bool = false };
    pub const ImportNamespaceSpecifier = struct { local: *Node };
    /// `import(source)` ou `import(source, options)` (ES2025). `options` est une
    /// **expression quelconque** (`{ with: { type: 'json' } }` typiquement) — la
    /// grammaire ne la contraint pas, contrairement au `with { … }` statique.
    pub const ImportExpression = struct { source: *Node, options: ?*Node = null };
    /// Une entrée d'un `with { … }` : `type: 'json'`.
    /// `key` = identifiant OU string literal ; `value` = string literal
    /// **obligatoire** (la spec n'autorise aucune autre expression).
    pub const ImportAttribute = struct { key: *Node, value: *Node };
    /// `type_only` : `export type { A }` (export type-only, TS — retiré par strip).
    pub const ExportNamed = struct {
        declaration: ?*Node,
        specifiers: []*Node,
        source: ?*Node,
        type_only: bool = false,
        attributes: Attributes = .{},
    };
    pub const ExportDefault = struct { declaration: *Node };
    /// `export * from './x'` (`exported` null) ou `export * as ns from './x'`
    /// (ES2020) : `exported` = le nom d'export `ns`. Ce n'est PAS un binding
    /// local — c'est un nom d'export, comme le `b` de `export { a as b }`.
    pub const ExportAll = struct { source: *Node, exported: ?*Node = null, attributes: Attributes = .{} };
    /// `export { a as b }` : `local` = a, `exported` = b (= a sans `as`). `type_only`
    /// : `export { type a, b }` (spécificateur type-only inline, TS).
    pub const ExportSpecifier = struct { local: *Node, exported: *Node, type_only: bool = false };

    // ---- JSX (opt-in) ----
    /// `<opening>children</closing>` ou `<opening/>` (self-closing : `closing` null).
    pub const JSXElement = struct { opening: *Node, children: []*Node, closing: ?*Node };
    /// `<>children</>` (fragment sans nom ni attributs).
    pub const JSXFragment = struct { children: []*Node };
    /// `<name attrs... />` ou `<name attrs...>`. `self_closing` = balise `/>`.
    pub const JSXOpeningElement = struct { name: *Node, attributes: []*Node, self_closing: bool };
    /// `</name>`.
    pub const JSXClosingElement = struct { name: *Node };
    /// `A.B` (namespace membre) : `object` = jsx_identifier|jsx_member_expression, `property` = jsx_identifier.
    pub const JSXMemberExpression = struct { object: *Node, property: *Node };
    /// `svg:path` : jamais une référence (nom intrinsèque namespacé).
    pub const JSXNamespacedName = struct { namespace: *Node, name: *Node };
    /// `name` (bare = true), `name="s"`, `name={e}`, `name=<b/>`. `value` null = bare.
    pub const JSXAttribute = struct { name: *Node, value: ?*Node };
    /// `{...expr}` en position d'attribut.
    pub const JSXSpreadAttribute = struct { argument: *Node };
    /// `{expr}` (ou `{}` / `{/* commentaire */}` : `expression` null = conteneur vide, légal).
    pub const JSXExpressionContainer = struct { expression: ?*Node };

    // ---- TypeScript (opt-in, phase 1) ----
    /// `Array<T>` : `name` = identifier | ts_qualified_name ; `type_args` = `<…>`.
    pub const TsTypeRef = struct { name: *Node, type_args: []*Node = &.{} };
    /// `Foo.Bar` en position de type.
    pub const TsQualified = struct { left: *Node, right: *Node };
    /// `"a"` / `1` / `true` en position de type (le littéral sous-jacent).
    pub const TsLiteralType = struct { literal: *Node };
    /// `A | B` (union) et `A & B` (intersection) partagent cette forme.
    pub const TsTypeList = struct { types: []*Node };
    pub const TsParenType = struct { @"type": *Node };
    pub const TsArrayType = struct { element: *Node };
    /// `[A, B]`, `[A, ...B[]]` : `elements` peut contenir des `ts_rest_type`.
    pub const TsTupleType = struct { elements: []*Node };
    pub const TsRestType = struct { @"type": *Node };
    /// `(a: A) => B` : `params` = liste de bindings (ts_typed / rest), `return_type` = B.
    pub const TsFunctionType = struct { params: []*Node, return_type: *Node, type_params: []*Node = &.{} };
    /// `{ a: T; b?: U }` : `members` = ts_property_signature / ts_method_signature.
    pub const TsTypeLiteral = struct { members: []*Node };
    pub const TsPropertySignature = struct { key: *Node, type_annotation: ?*Node = null, optional: bool = false, readonly: bool = false, computed: bool = false };
    pub const TsMethodSignature = struct { key: *Node, params: []*Node, return_type: ?*Node = null, optional: bool = false, computed: bool = false };
    pub const TsTypeofType = struct { expr: *Node }; // `typeof x` (x = référence de VALEUR, ignorée phase 1)
    pub const TsKeyofType = struct { @"type": *Node };
    /// `T[K]` : accès indexé en type. `object` = T, `index` = K.
    pub const TsIndexedAccess = struct { object: *Node, index: *Node };
    /// `{ [k: string]: T }` : signature d'index. `key` = identifiant (documentaire),
    /// `key_type` = type de la clé, `value_type` = type des valeurs.
    pub const TsIndexSignature = struct { key: *Node, key_type: *Node, value_type: *Node, readonly: bool = false };
    /// `<T extends C = D>` : `name` = identifier, `constraint`/`default` optionnels.
    pub const TsTypeParam = struct { name: *Node, constraint: ?*Node = null, default: ?*Node = null };
    /// `type A<T> = …` (type-only : effacé ENTIER par stripTypes).
    pub const TsTypeAlias = struct { id: *Node, type_params: []*Node = &.{}, @"type": *Node };
    /// `interface I<T> extends J { … }` (type-only : effacé ENTIER).
    pub const TsInterface = struct { id: *Node, type_params: []*Node = &.{}, extends: []*Node = &.{}, body: []*Node };
    /// Binding annoté : `x: T`, `a?: T`. `binding` = identifier | pattern | rest_element.
    pub const TsTyped = struct { binding: *Node, type_annotation: ?*Node = null, optional: bool = false };
    pub const TsAs = struct { expr: *Node, @"type": *Node }; // `x as T` (type = ts_type_* ou ref `const`)
    pub const TsSatisfies = struct { expr: *Node, @"type": *Node };
    pub const TsNonNull = struct { expr: *Node }; // `x!`
    // ---- TS phase 3 (émission) ----
    /// `enum E { … }` / `const enum E { … }`. `is_const` : documenté = compilé comme
    /// un enum normal (l'inlining cross-usage demande une table, cf. esbuild).
    pub const TsEnum = struct { id: *Node, members: []*Node, is_const: bool = false };
    /// Un membre : `A` (initializer null → auto-incrément) ou `A = 5` / `A = "a"`.
    pub const TsEnumMember = struct { name: *Node, initializer: ?*Node = null };
    /// `namespace N { … }` : `body` = statements (export const/function/class simples).
    pub const TsNamespace = struct { id: *Node, body: []*Node };
    /// `constructor(private x: T)` : property property. `param` = le param (ts_typed…),
    /// `access`/`readonly` = modificateurs (émis en `this.x = x`, erasés du reste).
    pub const TsParamProperty = struct { param: *Node, access: []const u8 = "", readonly: bool = false };

    /// La tranche source couverte par ce nœud : `source[start..end]`.
    pub fn text(self: *const Node, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }

    /// Texte d'un littéral nombre/booléen : `synthetic_text` s'il existe (nœud
    /// fabriqué par le transformer), sinon le span source. Pour les autres nœuds,
    /// c'est simplement le span.
    pub fn litText(self: *const Node, source: []const u8) []const u8 {
        return switch (self.kind) {
            .number_literal, .boolean_literal, .identifier, .jsx_identifier, .string_literal => |l| l.synthetic_text orelse self.text(source),
            else => self.text(source),
        };
    }
};

/// Règle React pour un nom JSX bare : première lettre MAJUSCULE ASCII = composant
/// (une **référence** à résoudre / l'expression comme 1er argument de `jsx()`) ;
/// sinon balise intrinsèque (jamais une référence / une **string** `"div"`).
/// Frontière PARTAGÉE par le semantic (résolution) et le transform JSX (codegen).
pub fn jsxIdentIsComponent(name: []const u8) bool {
    return name.len > 0 and name[0] >= 'A' and name[0] <= 'Z';
}

/// Un nœud de TYPE (ou une déclaration type-only) ? Le semantic le saute
/// ENTIÈREMENT (ni bindings ni références — raccourci phase 1). N'INCLUT PAS les
/// nœuds ts porteurs d'une valeur (`ts_typed`/`ts_as_expression`/`ts_satisfies_
/// expression`/`ts_non_null_expression`), que le semantic traverse normalement.
pub fn isTypeNode(kind: std.meta.Tag(Node.Kind)) bool {
    return switch (kind) {
        .ts_type_reference, .ts_qualified_name, .ts_keyword_type, .ts_literal_type, .ts_union_type, .ts_intersection_type, .ts_parenthesized_type, .ts_array_type, .ts_tuple_type, .ts_rest_type, .ts_function_type, .ts_type_literal, .ts_property_signature, .ts_method_signature, .ts_typeof_type, .ts_keyof_type, .ts_indexed_access_type, .ts_index_signature, .ts_type_parameter, .ts_type_alias, .ts_interface => true,
        else => false,
    };
}

/// Écrit l'AST en arbre indenté (2 espaces par niveau) dans `out`.
pub fn printTree(
    node: *const Node,
    source: []const u8,
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    try writeNode(node, source, out, gpa, 0);
}

fn indent(out: *std.ArrayList(u8), gpa: std.mem.Allocator, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try out.appendSlice(gpa, "  ");
}

/// Écrit `indent + s + '\n'`.
fn line(out: *std.ArrayList(u8), gpa: std.mem.Allocator, depth: usize, s: []const u8) !void {
    try indent(out, gpa, depth);
    try out.appendSlice(gpa, s);
    try out.append(gpa, '\n');
}

/// Écrit `indent + label + ' ' + texte + '\n'` (feuilles). `litText` = span, ou
/// texte synthétique pour un littéral fabriqué par le transformer.
fn leaf(node: *const Node, source: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator, depth: usize, label: []const u8) !void {
    try indent(out, gpa, depth);
    try out.appendSlice(gpa, label);
    try out.append(gpa, ' ');
    try out.appendSlice(gpa, node.litText(source));
    try out.append(gpa, '\n');
}

/// Écrit le sous-arbre s'il existe, sinon une ligne `<empty>` (parties
/// optionnelles d'un `for`, où la position compte).
fn writeOptional(node: ?*Node, source: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator, depth: usize) std.mem.Allocator.Error!void {
    if (node) |n| try writeNode(n, source, out, gpa, depth) else try line(out, gpa, depth, "<empty>");
}

/// Écrit un groupement `Params` avec un enfant par paramètre.
fn writeParams(params: []*Node, source: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator, depth: usize) std.mem.Allocator.Error!void {
    try line(out, gpa, depth, "Params");
    for (params) |p| try writeNode(p, source, out, gpa, depth + 1);
}

/// Écrit un groupement `TypeArgs` (arguments de type d'un appel générique), si non vide.
fn writeTypeArgs(type_args: []*Node, source: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator, depth: usize) std.mem.Allocator.Error!void {
    if (type_args.len == 0) return;
    try line(out, gpa, depth, "TypeArgs");
    for (type_args) |a| try writeNode(a, source, out, gpa, depth + 1);
}

/// Label d'une fonction (déclaration/expression) avec ses modifieurs éventuels
/// `async`/`generator` en suffixe (ex. `FunctionDeclaration async generator`).
fn writeFnLabel(out: *std.ArrayList(u8), gpa: std.mem.Allocator, depth: usize, base: []const u8, is_async: bool, is_generator: bool) std.mem.Allocator.Error!void {
    try indent(out, gpa, depth);
    try out.appendSlice(gpa, base);
    if (is_async) try out.appendSlice(gpa, " async");
    if (is_generator) try out.appendSlice(gpa, " generator");
    try out.append(gpa, '\n');
}

/// Écrit une classe (déclaration ou expression). `SuperClass` est un
/// groupement synthétique pour lever l'ambiguïté nom/superclasse/corps.
fn writeClass(label: []const u8, c: Node.Class, source: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator, depth: usize) std.mem.Allocator.Error!void {
    try line(out, gpa, depth, label);
    if (c.id) |id| try writeNode(id, source, out, gpa, depth + 1);
    if (c.superclass) |sc| {
        try line(out, gpa, depth + 1, "SuperClass");
        try writeNode(sc, source, out, gpa, depth + 2);
    }
    try writeNode(c.body, source, out, gpa, depth + 1);
}

fn writeNode(
    node: *const Node,
    source: []const u8,
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    depth: usize,
) std.mem.Allocator.Error!void {
    switch (node.kind) {
        .program => |p| {
            try line(out, gpa, depth, "Program");
            for (p.body) |child| try writeNode(child, source, out, gpa, depth + 1);
        },
        .block_statement => |b| {
            try line(out, gpa, depth, "BlockStatement");
            for (b.body) |child| try writeNode(child, source, out, gpa, depth + 1);
        },
        .if_statement => |s| {
            try line(out, gpa, depth, "IfStatement");
            try writeNode(s.@"test", source, out, gpa, depth + 1);
            try writeNode(s.consequent, source, out, gpa, depth + 1);
            if (s.alternate) |alt| try writeNode(alt, source, out, gpa, depth + 1);
        },
        .while_statement => |s| {
            try line(out, gpa, depth, "WhileStatement");
            try writeNode(s.@"test", source, out, gpa, depth + 1);
            try writeNode(s.body, source, out, gpa, depth + 1);
        },
        .for_statement => |s| {
            try line(out, gpa, depth, "ForStatement");
            try writeOptional(s.init, source, out, gpa, depth + 1);
            try writeOptional(s.@"test", source, out, gpa, depth + 1);
            try writeOptional(s.update, source, out, gpa, depth + 1);
            try writeNode(s.body, source, out, gpa, depth + 1);
        },
        .for_of_statement => |s| {
            try line(out, gpa, depth, if (s.is_await) "ForOfStatement await" else "ForOfStatement");
            try writeNode(s.left, source, out, gpa, depth + 1);
            try writeNode(s.right, source, out, gpa, depth + 1);
            try writeNode(s.body, source, out, gpa, depth + 1);
        },
        .for_in_statement => |s| {
            try line(out, gpa, depth, "ForInStatement");
            try writeNode(s.left, source, out, gpa, depth + 1);
            try writeNode(s.right, source, out, gpa, depth + 1);
            try writeNode(s.body, source, out, gpa, depth + 1);
        },
        .return_statement => |s| {
            try line(out, gpa, depth, "ReturnStatement");
            if (s.argument) |arg| try writeNode(arg, source, out, gpa, depth + 1);
        },
        .function_declaration => |f| {
            try writeFnLabel(out, gpa, depth, "FunctionDeclaration", f.is_async, f.is_generator);
            if (f.id) |id| try writeNode(id, source, out, gpa, depth + 1);
            try writeParams(f.params, source, out, gpa, depth + 1);
            try writeNode(f.body, source, out, gpa, depth + 1);
        },
        .variable_declaration => |v| {
            try indent(out, gpa, depth);
            try out.appendSlice(gpa, "VariableDeclaration ");
            try out.appendSlice(gpa, v.kind.keyword());
            try out.append(gpa, '\n');
            for (v.declarations) |d| try writeNode(d, source, out, gpa, depth + 1);
        },
        .variable_declarator => |d| {
            try line(out, gpa, depth, "VariableDeclarator");
            try writeNode(d.id, source, out, gpa, depth + 1);
            if (d.init) |init| try writeNode(init, source, out, gpa, depth + 1);
        },
        .expression_statement => |s| {
            try line(out, gpa, depth, "ExpressionStatement");
            try writeNode(s.expression, source, out, gpa, depth + 1);
        },
        .number_literal => try leaf(node, source, out, gpa, depth, "NumberLiteral"),
        .bigint_literal => try leaf(node, source, out, gpa, depth, "BigIntLiteral"),
        .string_literal => try leaf(node, source, out, gpa, depth, "StringLiteral"),
        .boolean_literal => try leaf(node, source, out, gpa, depth, "BooleanLiteral"),
        .null_literal => try line(out, gpa, depth, "NullLiteral"),
        .regex_literal => try leaf(node, source, out, gpa, depth, "RegexLiteral"),
        .identifier => try leaf(node, source, out, gpa, depth, "Identifier"),
        .private_name => try leaf(node, source, out, gpa, depth, "PrivateName"),
        .error_node => try line(out, gpa, depth, "ErrorNode"),
        .binary_expression => |b| {
            try indent(out, gpa, depth);
            try out.appendSlice(gpa, "BinaryExpression \"");
            try out.appendSlice(gpa, b.operator.symbol());
            try out.appendSlice(gpa, "\"\n");
            try writeNode(b.left, source, out, gpa, depth + 1);
            try writeNode(b.right, source, out, gpa, depth + 1);
        },
        .unary_expression => |u| {
            try indent(out, gpa, depth);
            try out.appendSlice(gpa, "UnaryExpression \"");
            try out.appendSlice(gpa, u.operator.symbol());
            try out.appendSlice(gpa, "\"\n");
            try writeNode(u.operand, source, out, gpa, depth + 1);
        },
        .update_expression => |u| {
            try indent(out, gpa, depth);
            try out.appendSlice(gpa, "UpdateExpression \"");
            try out.appendSlice(gpa, u.operator.symbol());
            try out.appendSlice(gpa, if (u.prefix) "\" (prefix)\n" else "\" (postfix)\n");
            try writeNode(u.argument, source, out, gpa, depth + 1);
        },
        .await_expression => |a| {
            try line(out, gpa, depth, "AwaitExpression");
            try writeNode(a.argument, source, out, gpa, depth + 1);
        },
        .yield_expression => |y| {
            try line(out, gpa, depth, if (y.delegate) "YieldExpression delegate" else "YieldExpression");
            if (y.argument) |arg| try writeNode(arg, source, out, gpa, depth + 1);
        },
        .assignment_expression => |a| {
            try indent(out, gpa, depth);
            try out.appendSlice(gpa, "AssignmentExpression \"");
            try out.appendSlice(gpa, a.operator.symbol());
            try out.appendSlice(gpa, "\"\n");
            try writeNode(a.target, source, out, gpa, depth + 1);
            try writeNode(a.value, source, out, gpa, depth + 1);
        },
        .conditional_expression => |c| {
            try line(out, gpa, depth, "ConditionalExpression");
            try writeNode(c.@"test", source, out, gpa, depth + 1);
            try writeNode(c.consequent, source, out, gpa, depth + 1);
            try writeNode(c.alternate, source, out, gpa, depth + 1);
        },
        .call_expression => |c| {
            try indent(out, gpa, depth);
            try out.appendSlice(gpa, "CallExpression");
            if (c.optional) try out.appendSlice(gpa, " ?.");
            try out.append(gpa, '\n');
            try writeNode(c.callee, source, out, gpa, depth + 1);
            try writeTypeArgs(c.type_args, source, out, gpa, depth + 1);
            for (c.arguments) |arg| try writeNode(arg, source, out, gpa, depth + 1);
        },
        .member_expression => |m| {
            try indent(out, gpa, depth);
            try out.appendSlice(gpa, "MemberExpression");
            if (m.computed) try out.appendSlice(gpa, " [computed]");
            if (m.optional) try out.appendSlice(gpa, " ?.");
            try out.append(gpa, '\n');
            try writeNode(m.object, source, out, gpa, depth + 1);
            try writeNode(m.property, source, out, gpa, depth + 1);
        },
        .function_expression => |f| {
            try writeFnLabel(out, gpa, depth, "FunctionExpression", f.is_async, f.is_generator);
            if (f.id) |id| try writeNode(id, source, out, gpa, depth + 1);
            try writeParams(f.params, source, out, gpa, depth + 1);
            try writeNode(f.body, source, out, gpa, depth + 1);
        },
        .arrow_function => |f| {
            try indent(out, gpa, depth);
            try out.appendSlice(gpa, "ArrowFunction");
            if (f.is_async) try out.appendSlice(gpa, " async");
            try out.appendSlice(gpa, if (f.expression) " (expression)" else " (block)");
            try out.append(gpa, '\n');
            try writeParams(f.params, source, out, gpa, depth + 1);
            try writeNode(f.body, source, out, gpa, depth + 1);
        },
        .array_expression => |arr| {
            try line(out, gpa, depth, "ArrayExpression");
            for (arr.elements) |el| {
                if (el) |e| try writeNode(e, source, out, gpa, depth + 1) else try line(out, gpa, depth + 1, "<elision>");
            }
        },
        .sequence_expression => |seq| {
            try line(out, gpa, depth, "SequenceExpression");
            for (seq.expressions) |e| try writeNode(e, source, out, gpa, depth + 1);
        },
        .object_expression => |obj| {
            try line(out, gpa, depth, "ObjectExpression");
            for (obj.properties) |prop| try writeNode(prop, source, out, gpa, depth + 1);
        },
        .property => |prop| {
            try indent(out, gpa, depth);
            try out.appendSlice(gpa, "Property");
            if (prop.computed) try out.appendSlice(gpa, " [computed]");
            if (prop.shorthand) try out.appendSlice(gpa, " [shorthand]");
            try out.append(gpa, '\n');
            // Shorthand : la valeur porte tout (Identifier, ou AssignmentPattern
            // pour `{ z = 3 }`). Sinon : clé puis valeur.
            if (prop.shorthand) {
                try writeNode(prop.value, source, out, gpa, depth + 1);
            } else {
                try writeNode(prop.key, source, out, gpa, depth + 1);
                try writeNode(prop.value, source, out, gpa, depth + 1);
            }
        },
        .spread_element => |s| {
            try line(out, gpa, depth, "SpreadElement");
            try writeNode(s.argument, source, out, gpa, depth + 1);
        },
        .array_pattern => |arr| {
            try line(out, gpa, depth, "ArrayPattern");
            for (arr.elements) |el| {
                if (el) |e| try writeNode(e, source, out, gpa, depth + 1) else try line(out, gpa, depth + 1, "<elision>");
            }
        },
        .object_pattern => |obj| {
            try line(out, gpa, depth, "ObjectPattern");
            for (obj.properties) |prop| try writeNode(prop, source, out, gpa, depth + 1);
        },
        .assignment_pattern => |a| {
            try line(out, gpa, depth, "AssignmentPattern");
            try writeNode(a.left, source, out, gpa, depth + 1);
            try writeNode(a.right, source, out, gpa, depth + 1);
        },
        .rest_element => |r| {
            try line(out, gpa, depth, "RestElement");
            try writeNode(r.argument, source, out, gpa, depth + 1);
        },
        .template_literal => |t| {
            try line(out, gpa, depth, "TemplateLiteral");
            // Quasis et expressions entrelacés : quasi[0], expr[0], quasi[1]…
            for (t.quasis, 0..) |q, i| {
                try writeNode(q, source, out, gpa, depth + 1);
                if (i < t.expressions.len) try writeNode(t.expressions[i], source, out, gpa, depth + 1);
            }
        },
        .template_element => {
            try indent(out, gpa, depth);
            try out.appendSlice(gpa, "TemplateElement \"");
            try out.appendSlice(gpa, node.text(source));
            try out.appendSlice(gpa, "\"\n");
        },
        .tagged_template_expression => |t| {
            try line(out, gpa, depth, "TaggedTemplateExpression");
            try writeNode(t.tag, source, out, gpa, depth + 1);
            try writeTypeArgs(t.type_args, source, out, gpa, depth + 1);
            try writeNode(t.quasi, source, out, gpa, depth + 1);
        },
        .this_expression => try line(out, gpa, depth, "ThisExpression"),
        .super_expression => try line(out, gpa, depth, "Super"),
        .meta_property => try leaf(node, source, out, gpa, depth, "MetaProperty"),
        .new_expression => |n| {
            try line(out, gpa, depth, "NewExpression");
            try writeNode(n.callee, source, out, gpa, depth + 1);
            try writeTypeArgs(n.type_args, source, out, gpa, depth + 1);
            for (n.arguments) |arg| try writeNode(arg, source, out, gpa, depth + 1);
        },
        .class_declaration => |c| try writeClass("ClassDeclaration", c, source, out, gpa, depth),
        .class_expression => |c| try writeClass("ClassExpression", c, source, out, gpa, depth),
        .class_body => |b| {
            try line(out, gpa, depth, "ClassBody");
            for (b.members) |m| try writeNode(m, source, out, gpa, depth + 1);
        },
        .method_definition => |m| {
            try indent(out, gpa, depth);
            try out.appendSlice(gpa, "MethodDefinition ");
            try out.appendSlice(gpa, m.kind.label());
            if (m.static) try out.appendSlice(gpa, " static");
            if (m.is_async) try out.appendSlice(gpa, " async");
            if (m.is_generator) try out.appendSlice(gpa, " generator");
            if (m.computed) try out.appendSlice(gpa, " computed");
            try out.append(gpa, '\n');
            try writeNode(m.key, source, out, gpa, depth + 1);
            try writeParams(m.params, source, out, gpa, depth + 1);
            try writeNode(m.body, source, out, gpa, depth + 1);
        },
        .property_definition => |p| {
            try indent(out, gpa, depth);
            try out.appendSlice(gpa, "PropertyDefinition");
            if (p.static) try out.appendSlice(gpa, " static");
            if (p.computed) try out.appendSlice(gpa, " computed");
            try out.append(gpa, '\n');
            try writeNode(p.key, source, out, gpa, depth + 1);
            if (p.value) |v| try writeNode(v, source, out, gpa, depth + 1);
        },
        .throw_statement => |s| {
            try line(out, gpa, depth, "ThrowStatement");
            try writeNode(s.argument, source, out, gpa, depth + 1);
        },
        .try_statement => |s| {
            try line(out, gpa, depth, "TryStatement");
            try writeNode(s.block, source, out, gpa, depth + 1);
            if (s.handler) |h| try writeNode(h, source, out, gpa, depth + 1);
            if (s.finalizer) |f| {
                try line(out, gpa, depth + 1, "Finalizer");
                try writeNode(f, source, out, gpa, depth + 2);
            }
        },
        .catch_clause => |c| {
            try line(out, gpa, depth, "CatchClause");
            if (c.param) |p| try writeNode(p, source, out, gpa, depth + 1);
            try writeNode(c.body, source, out, gpa, depth + 1);
        },
        .switch_statement => |s| {
            try line(out, gpa, depth, "SwitchStatement");
            try writeNode(s.discriminant, source, out, gpa, depth + 1);
            for (s.cases) |c| try writeNode(c, source, out, gpa, depth + 1);
        },
        .switch_case => |c| {
            if (c.@"test") |t| {
                try line(out, gpa, depth, "SwitchCase");
                try writeNode(t, source, out, gpa, depth + 1);
            } else {
                try line(out, gpa, depth, "SwitchCase default");
            }
            for (c.consequent) |stmt| try writeNode(stmt, source, out, gpa, depth + 1);
        },
        .break_statement => |s| {
            try line(out, gpa, depth, "BreakStatement");
            if (s.label) |l| try writeNode(l, source, out, gpa, depth + 1);
        },
        .continue_statement => |s| {
            try line(out, gpa, depth, "ContinueStatement");
            if (s.label) |l| try writeNode(l, source, out, gpa, depth + 1);
        },
        .labeled_statement => |s| {
            try line(out, gpa, depth, "LabeledStatement");
            try writeNode(s.label, source, out, gpa, depth + 1);
            try writeNode(s.body, source, out, gpa, depth + 1);
        },
        .do_while_statement => |s| {
            try line(out, gpa, depth, "DoWhileStatement");
            try writeNode(s.body, source, out, gpa, depth + 1);
            try writeNode(s.@"test", source, out, gpa, depth + 1);
        },
        .import_declaration => |d| {
            try line(out, gpa, depth, "ImportDeclaration");
            for (d.specifiers) |s| try writeNode(s, source, out, gpa, depth + 1);
            try writeNode(d.source, source, out, gpa, depth + 1); // StringLiteral
            for (d.attributes.entries) |a| try writeNode(a, source, out, gpa, depth + 1);
        },
        .import_attribute => |a| {
            try line(out, gpa, depth, "ImportAttribute");
            try writeNode(a.key, source, out, gpa, depth + 1);
            try writeNode(a.value, source, out, gpa, depth + 1);
        },
        .import_default_specifier => |s| {
            try line(out, gpa, depth, "ImportDefaultSpecifier");
            try writeNode(s.local, source, out, gpa, depth + 1);
        },
        .import_specifier => |s| {
            try line(out, gpa, depth, "ImportSpecifier");
            try writeNode(s.imported, source, out, gpa, depth + 1);
            try writeNode(s.local, source, out, gpa, depth + 1);
        },
        .import_namespace_specifier => |s| {
            try line(out, gpa, depth, "ImportNamespaceSpecifier");
            try writeNode(s.local, source, out, gpa, depth + 1);
        },
        .import_expression => |e| {
            try line(out, gpa, depth, "ImportExpression");
            try writeNode(e.source, source, out, gpa, depth + 1);
            if (e.options) |o| try writeNode(o, source, out, gpa, depth + 1);
        },
        .export_named_declaration => |d| {
            try line(out, gpa, depth, "ExportNamedDeclaration");
            if (d.declaration) |decl| try writeNode(decl, source, out, gpa, depth + 1);
            for (d.specifiers) |s| try writeNode(s, source, out, gpa, depth + 1);
            if (d.source) |src| try writeNode(src, source, out, gpa, depth + 1);
            for (d.attributes.entries) |a| try writeNode(a, source, out, gpa, depth + 1);
        },
        .export_default_declaration => |d| {
            try line(out, gpa, depth, "ExportDefaultDeclaration");
            try writeNode(d.declaration, source, out, gpa, depth + 1);
        },
        .export_all_declaration => |d| {
            try line(out, gpa, depth, "ExportAllDeclaration");
            // `export * as ns from` : le nom d'export AVANT la source, comme dans
            // le source — le debug-tree doit distinguer les deux formes (c'est lui
            // que compare le round-trip).
            if (d.exported) |e| try writeNode(e, source, out, gpa, depth + 1);
            try writeNode(d.source, source, out, gpa, depth + 1);
            for (d.attributes.entries) |a| try writeNode(a, source, out, gpa, depth + 1);
        },
        .export_specifier => |s| {
            try line(out, gpa, depth, "ExportSpecifier");
            try writeNode(s.local, source, out, gpa, depth + 1);
            try writeNode(s.exported, source, out, gpa, depth + 1);
        },
        // ---- JSX ----
        .jsx_element => |e| {
            try line(out, gpa, depth, "JSXElement");
            try writeNode(e.opening, source, out, gpa, depth + 1);
            for (e.children) |c| try writeNode(c, source, out, gpa, depth + 1);
            if (e.closing) |cl| try writeNode(cl, source, out, gpa, depth + 1);
        },
        .jsx_fragment => |f| {
            try line(out, gpa, depth, "JSXFragment");
            for (f.children) |c| try writeNode(c, source, out, gpa, depth + 1);
        },
        .jsx_opening_element => |o| {
            try line(out, gpa, depth, if (o.self_closing) "JSXOpeningElement self-closing" else "JSXOpeningElement");
            try writeNode(o.name, source, out, gpa, depth + 1);
            for (o.attributes) |a| try writeNode(a, source, out, gpa, depth + 1);
        },
        .jsx_closing_element => |c| {
            try line(out, gpa, depth, "JSXClosingElement");
            try writeNode(c.name, source, out, gpa, depth + 1);
        },
        .jsx_identifier => try leaf(node, source, out, gpa, depth, "JSXIdentifier"),
        .jsx_member_expression => |m| {
            try line(out, gpa, depth, "JSXMemberExpression");
            try writeNode(m.object, source, out, gpa, depth + 1);
            try writeNode(m.property, source, out, gpa, depth + 1);
        },
        .jsx_namespaced_name => |n| {
            try line(out, gpa, depth, "JSXNamespacedName");
            try writeNode(n.namespace, source, out, gpa, depth + 1);
            try writeNode(n.name, source, out, gpa, depth + 1);
        },
        .jsx_attribute => |a| {
            try line(out, gpa, depth, "JSXAttribute");
            try writeNode(a.name, source, out, gpa, depth + 1);
            if (a.value) |v| try writeNode(v, source, out, gpa, depth + 1);
        },
        .jsx_spread_attribute => |s| {
            try line(out, gpa, depth, "JSXSpreadAttribute");
            try writeNode(s.argument, source, out, gpa, depth + 1);
        },
        .jsx_expression_container => |c| {
            try line(out, gpa, depth, "JSXExpressionContainer");
            if (c.expression) |e| try writeNode(e, source, out, gpa, depth + 1) else try line(out, gpa, depth + 1, "<empty>");
        },
        .jsx_text => {
            try indent(out, gpa, depth);
            try out.appendSlice(gpa, "JSXText \"");
            try out.appendSlice(gpa, node.text(source));
            try out.appendSlice(gpa, "\"\n");
        },
        // ---- TypeScript ----
        .ts_type_reference => |t| {
            try line(out, gpa, depth, "TsTypeReference");
            try writeNode(t.name, source, out, gpa, depth + 1);
            for (t.type_args) |a| try writeNode(a, source, out, gpa, depth + 1);
        },
        .ts_qualified_name => |q| {
            try line(out, gpa, depth, "TsQualifiedName");
            try writeNode(q.left, source, out, gpa, depth + 1);
            try writeNode(q.right, source, out, gpa, depth + 1);
        },
        .ts_keyword_type => try leaf(node, source, out, gpa, depth, "TsKeywordType"),
        .ts_literal_type => |t| {
            try line(out, gpa, depth, "TsLiteralType");
            try writeNode(t.literal, source, out, gpa, depth + 1);
        },
        .ts_union_type => |t| {
            try line(out, gpa, depth, "TsUnionType");
            for (t.types) |x| try writeNode(x, source, out, gpa, depth + 1);
        },
        .ts_intersection_type => |t| {
            try line(out, gpa, depth, "TsIntersectionType");
            for (t.types) |x| try writeNode(x, source, out, gpa, depth + 1);
        },
        .ts_parenthesized_type => |t| {
            try line(out, gpa, depth, "TsParenthesizedType");
            try writeNode(t.@"type", source, out, gpa, depth + 1);
        },
        .ts_array_type => |t| {
            try line(out, gpa, depth, "TsArrayType");
            try writeNode(t.element, source, out, gpa, depth + 1);
        },
        .ts_tuple_type => |t| {
            try line(out, gpa, depth, "TsTupleType");
            for (t.elements) |x| try writeNode(x, source, out, gpa, depth + 1);
        },
        .ts_rest_type => |t| {
            try line(out, gpa, depth, "TsRestType");
            try writeNode(t.@"type", source, out, gpa, depth + 1);
        },
        .ts_function_type => |t| {
            try line(out, gpa, depth, "TsFunctionType");
            try writeParams(t.params, source, out, gpa, depth + 1);
            try writeNode(t.return_type, source, out, gpa, depth + 1);
        },
        .ts_type_literal => |t| {
            try line(out, gpa, depth, "TsTypeLiteral");
            for (t.members) |m| try writeNode(m, source, out, gpa, depth + 1);
        },
        .ts_property_signature => |p| {
            try line(out, gpa, depth, if (p.optional) "TsPropertySignature optional" else "TsPropertySignature");
            try writeNode(p.key, source, out, gpa, depth + 1);
            if (p.type_annotation) |ty| try writeNode(ty, source, out, gpa, depth + 1);
        },
        .ts_method_signature => |m| {
            try line(out, gpa, depth, "TsMethodSignature");
            try writeNode(m.key, source, out, gpa, depth + 1);
            try writeParams(m.params, source, out, gpa, depth + 1);
            if (m.return_type) |ty| try writeNode(ty, source, out, gpa, depth + 1);
        },
        .ts_typeof_type => |t| {
            try line(out, gpa, depth, "TsTypeofType");
            try writeNode(t.expr, source, out, gpa, depth + 1);
        },
        .ts_keyof_type => |t| {
            try line(out, gpa, depth, "TsKeyofType");
            try writeNode(t.@"type", source, out, gpa, depth + 1);
        },
        .ts_indexed_access_type => |t| {
            try line(out, gpa, depth, "TsIndexedAccessType");
            try writeNode(t.object, source, out, gpa, depth + 1);
            try writeNode(t.index, source, out, gpa, depth + 1);
        },
        .ts_index_signature => |t| {
            try line(out, gpa, depth, "TsIndexSignature");
            try writeNode(t.key_type, source, out, gpa, depth + 1);
            try writeNode(t.value_type, source, out, gpa, depth + 1);
        },
        .ts_type_parameter => |t| {
            try line(out, gpa, depth, "TsTypeParameter");
            try writeNode(t.name, source, out, gpa, depth + 1);
            if (t.constraint) |c| try writeNode(c, source, out, gpa, depth + 1);
            if (t.default) |d| try writeNode(d, source, out, gpa, depth + 1);
        },
        .ts_type_alias => |t| {
            try line(out, gpa, depth, "TsTypeAlias");
            try writeNode(t.id, source, out, gpa, depth + 1);
            for (t.type_params) |p| try writeNode(p, source, out, gpa, depth + 1);
            try writeNode(t.@"type", source, out, gpa, depth + 1);
        },
        .ts_interface => |t| {
            try line(out, gpa, depth, "TsInterface");
            try writeNode(t.id, source, out, gpa, depth + 1);
            for (t.type_params) |p| try writeNode(p, source, out, gpa, depth + 1);
            for (t.extends) |e| try writeNode(e, source, out, gpa, depth + 1);
            for (t.body) |m| try writeNode(m, source, out, gpa, depth + 1);
        },
        .ts_typed => |t| {
            try line(out, gpa, depth, if (t.optional) "TsTyped optional" else "TsTyped");
            try writeNode(t.binding, source, out, gpa, depth + 1);
            if (t.type_annotation) |ty| try writeNode(ty, source, out, gpa, depth + 1);
        },
        .ts_as_expression => |t| {
            try line(out, gpa, depth, "TsAsExpression");
            try writeNode(t.expr, source, out, gpa, depth + 1);
            try writeNode(t.@"type", source, out, gpa, depth + 1);
        },
        .ts_satisfies_expression => |t| {
            try line(out, gpa, depth, "TsSatisfiesExpression");
            try writeNode(t.expr, source, out, gpa, depth + 1);
            try writeNode(t.@"type", source, out, gpa, depth + 1);
        },
        .ts_non_null_expression => |t| {
            try line(out, gpa, depth, "TsNonNullExpression");
            try writeNode(t.expr, source, out, gpa, depth + 1);
        },
        .ts_enum => |e| {
            try line(out, gpa, depth, if (e.is_const) "TsEnum const" else "TsEnum");
            try writeNode(e.id, source, out, gpa, depth + 1);
            for (e.members) |m| try writeNode(m, source, out, gpa, depth + 1);
        },
        .ts_enum_member => |m| {
            try line(out, gpa, depth, "TsEnumMember");
            try writeNode(m.name, source, out, gpa, depth + 1);
            if (m.initializer) |i| try writeNode(i, source, out, gpa, depth + 1);
        },
        .ts_namespace => |n| {
            try line(out, gpa, depth, "TsNamespace");
            try writeNode(n.id, source, out, gpa, depth + 1);
            for (n.body) |s| try writeNode(s, source, out, gpa, depth + 1);
        },
        .ts_param_property => |p| {
            try line(out, gpa, depth, "TsParamProperty");
            try writeNode(p.param, source, out, gpa, depth + 1);
        },
    }
}
