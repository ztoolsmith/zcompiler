//! zcompiler — le point d'entrée du module Zig que les CONSOMMATEURS importent
//! avec `@import("zcompiler")` (cf. `b.addModule("zcompiler", …)` dans build.zig).
//!
//! Jusqu'ici `native/` n'était consommé que par `native/main.zig` (le pont
//! N-API), en interne : chaque fichier s'importe par chemin relatif
//! (`@import("ast.zig")`). Un consommateur externe (zbundle) a besoin du même
//! accès, mais **par un seul module**.
//!
//! Pourquoi UN module et pas trois (`zast` + `zparser` + `zsemantic`) : en Zig,
//! un fichier importé par chemin relatif appartient au module de l'importeur.
//! Trois `addModule` distincts donneraient donc TROIS instanciations d'`ast.zig`
//! — et `parser.ParseResult.program` (un `*ast.Node` de l'instance « zparser »)
//! ne serait pas du même type que le `ast.Node` de l'instance « zast ». Un seul
//! module racine qui réexporte les namespaces = une seule instanciation, zéro
//! duplication de types. C'est déjà le choix de zignapi (`native/root.zig`).
//!
//! Ce fichier ne fait QUE réexporter : aucune logique. `main.zig` (le pont N-API)
//! en est volontairement absent — il n'a de sens que compilé en addon.

pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const printer = @import("printer.zig");
pub const walker = @import("walker.zig");
pub const semantic = @import("semantic.zig");
pub const transformer = @import("transformer.zig");
pub const mangler = @import("mangler.zig");
pub const jsx_transform = @import("jsx_transform.zig");

/// Raccourcis sur les types les plus manipulés par un consommateur.
pub const Node = ast.Node;
pub const ParseResult = parser.ParseResult;

/// `parser.parseWith(arena, source, jsx, ts)` — l'entrée universelle : renvoie
/// TOUJOURS un AST (partiel si le source est cassé) + la liste des diagnostics.
pub const parseWith = parser.parseWith;

/// `semantic.moduleRecords(arena, program, source)` — les dépendances de module
/// d'un AST (imports, re-exports, `export *`, `import()` dynamique). C'est la
/// porte d'entrée d'un bundler ; cf. la section « Module records » du CLAUDE.md.
pub const moduleRecords = semantic.moduleRecords;
pub const ModuleRecord = semantic.ModuleRecord;
pub const ModuleRecordKind = semantic.ModuleRecordKind;

test {
    // Tire chaque sous-module dans le build de test pour que `zig build test`
    // exécute leurs tests même en passant par la racine.
    _ = ast;
    _ = lexer;
    _ = parser;
    _ = printer;
    _ = walker;
    _ = semantic;
    _ = transformer;
    _ = mangler;
    _ = jsx_transform;
}
