//! Le parser : transforme les tokens (lexer.zig) en AST (ast.zig).
//!
//! Statements : `parseStatement` dispatche sur le premier token — blocs `{}`,
//! `if/else`, `while`, `for`, `return`, `function`, déclarations `const/let/var`,
//! sinon expression statement.
//! Expressions, du plus bas au plus haut : assignment (droite, + arrow) ->
//! conditional (ternaire) -> binary (Pratt) -> unary (préfixe + update) ->
//! postfix (call/member/optionnel, en boucle) -> primary.
//! Tous les nœuds vivent dans l'arena passée au parser (bump, comme OXC).

const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

const TokenKind = lexer.TokenKind;

pub const Node = ast.Node;
pub const printTree = ast.printTree;

pub const Diagnostic = struct {
    message: []const u8 = "",
    pos: u32 = 0,
};

pub const ParseError = error{
    UnexpectedToken,
    InvalidAssignmentTarget,
    MissingInitializer,
    RestNotLast,
    Unsupported,
    ImportExportTopLevel,
    SourceNotString,
    MultipleDefault,
    OutOfMemory,
    UnterminatedString,
    UnterminatedComment,
    UnterminatedTemplate,
    UnterminatedRegex,
    InvalidBigInt,
    InvalidUnicodeEscape,
    InvalidUtf8,
    EscapedKeyword,
};

// ---- Tables opérateurs ----

const BinInfo = struct { prec: u8, op: ast.BinaryOp, right_assoc: bool };

/// Précédence JS (bas -> haut) : ?? < || < && < | < ^ < & < égalité <
/// relationnel (dont in/instanceof) < décalages < + - < * / % < ** (droite).
fn binaryInfo(kind: TokenKind) ?BinInfo {
    return switch (kind) {
        .question_question => .{ .prec = 1, .op = .nullish, .right_assoc = false },
        .pipe_pipe => .{ .prec = 2, .op = .logical_or, .right_assoc = false },
        .amp_amp => .{ .prec = 3, .op = .logical_and, .right_assoc = false },
        .pipe => .{ .prec = 4, .op = .bor, .right_assoc = false },
        .caret => .{ .prec = 5, .op = .bxor, .right_assoc = false },
        .amp => .{ .prec = 6, .op = .band, .right_assoc = false },
        .eq_eq => .{ .prec = 7, .op = .eq, .right_assoc = false },
        .neq => .{ .prec = 7, .op = .neq, .right_assoc = false },
        .strict_eq => .{ .prec = 7, .op = .strict_eq, .right_assoc = false },
        .strict_neq => .{ .prec = 7, .op = .strict_neq, .right_assoc = false },
        .lt => .{ .prec = 8, .op = .lt, .right_assoc = false },
        .gt => .{ .prec = 8, .op = .gt, .right_assoc = false },
        .lt_eq => .{ .prec = 8, .op = .le, .right_assoc = false },
        .gt_eq => .{ .prec = 8, .op = .ge, .right_assoc = false },
        .kw_in => .{ .prec = 8, .op = .in_, .right_assoc = false },
        .kw_instanceof => .{ .prec = 8, .op = .instance_of, .right_assoc = false },
        .shl => .{ .prec = 9, .op = .shl, .right_assoc = false },
        .shr => .{ .prec = 9, .op = .shr, .right_assoc = false },
        .ushr => .{ .prec = 9, .op = .ushr, .right_assoc = false },
        .plus => .{ .prec = 10, .op = .add, .right_assoc = false },
        .minus => .{ .prec = 10, .op = .sub, .right_assoc = false },
        .star => .{ .prec = 11, .op = .mul, .right_assoc = false },
        .slash => .{ .prec = 11, .op = .div, .right_assoc = false },
        .percent => .{ .prec = 11, .op = .rem, .right_assoc = false },
        .star_star => .{ .prec = 12, .op = .exp, .right_assoc = true },
        else => null,
    };
}

fn assignOp(kind: TokenKind) ?ast.AssignOp {
    return switch (kind) {
        .eq => .assign,
        .plus_eq => .add_assign,
        .minus_eq => .sub_assign,
        .star_eq => .mul_assign,
        .slash_eq => .div_assign,
        .pipe_eq => .bor_assign,
        .caret_eq => .bxor_assign,
        .amp_eq => .band_assign,
        .shl_eq => .shl_assign,
        .shr_eq => .shr_assign,
        .ushr_eq => .ushr_assign,
        .amp_amp_eq => .land_assign,
        .pipe_pipe_eq => .lor_assign,
        .question_question_eq => .nullish_assign,
        else => null,
    };
}

fn updateOp(kind: TokenKind) ?ast.UpdateOp {
    return switch (kind) {
        .plus_plus => .inc,
        .minus_minus => .dec,
        else => null,
    };
}

fn isAssignable(node: *const ast.Node) bool {
    return switch (node.kind) {
        .identifier, .member_expression => true,
        else => false,
    };
}

/// Vrai si le token est un mot-clé (kw_*). Utilisé pour autoriser les mots-clés
/// comme noms de membres/modules (`export { x as default }`).
fn isKeyword(kind: TokenKind) bool {
    return switch (kind) {
        .kw_const, .kw_let, .kw_var, .kw_function, .kw_return, .kw_if, .kw_else, .kw_for, .kw_while, .kw_class, .kw_new, .kw_import, .kw_export, .kw_default, .kw_true, .kw_false, .kw_null, .kw_this, .kw_super, .kw_typeof, .kw_in, .kw_extends, .kw_static, .kw_throw, .kw_try, .kw_catch, .kw_finally, .kw_switch, .kw_case, .kw_break, .kw_continue, .kw_do, .kw_instanceof, .kw_void, .kw_delete => true,
        else => false,
    };
}

/// Mots-clés de type primitifs (lexés en identifiants) : `number`, `string`, … En
/// position de type, ce sont des `ts_keyword_type`, pas des références.
fn isTsPrimitiveKeyword(text: []const u8) bool {
    const kws = [_][]const u8{ "number", "string", "boolean", "any", "unknown", "never", "object", "symbol", "undefined", "bigint" };
    for (kws) |k| if (std.mem.eql(u8, text, k)) return true;
    return false;
}

/// Un token qui peut commencer une clé de membre de classe.
fn keyStart(kind: TokenKind) bool {
    return switch (kind) {
        .identifier, .private_name, .string, .number, .bigint, .l_bracket, .kw_static => true,
        else => false,
    };
}

const Parser = struct {
    tokens: []const lexer.Token,
    source: []const u8,
    arena: std.mem.Allocator,
    /// Diagnostics ACCUMULÉS (error recovery) : `fail` en ajoute un et déroule la
    /// pile locale ; l'erreur est ATTRAPÉE aux frontières de statement (panic mode).
    errors: std.ArrayList(Diagnostic) = .empty,
    pos: usize = 0,
    // Contexte de fonction : `await` n'est un mot-clé QUE si `in_async`, `yield`
    // QUE si `in_generator`. Empilés/dépilés en entrant/sortant d'un corps de
    // fonction. Au top-level, `in_async = true` (top-level await des modules ES).
    in_async: bool = true,
    in_generator: bool = false,
    /// Grammaire JSX activée (opt-in). Propagé au lexer ; débloque `parseJSXElement`
    /// depuis `parsePrimary` sur un `<` en position primaire.
    jsx: bool = false,
    /// TypeScript activé (opt-in, phase 1). Débloque les annotations de type, les
    /// déclarations type-only, `as`/`satisfies`/`!`. Aucun effet sur le lexer (les
    /// mots-clés TS sont contextuels). Off = bit-identique.
    ts: bool = false,
    /// Compteur de `>` « virtuels » : quand `>>`/`>>>` ferment des arguments de
    /// type imbriqués (`Array<Array<T>>` — le lexer produit UN token `shr`), on
    /// consomme le token et on retient les `>` restants ici (re-découpe contextuelle).
    pending_gt: u32 = 0,

    fn at(self: *const Parser) ?lexer.Token {
        return if (self.pos < self.tokens.len) self.tokens[self.pos] else null;
    }

    /// Vrai si le token porte exactement le texte `word` (mots contextuels
    /// `async`/`await`/`yield`, tous des identifiants au niveau du lexer).
    fn tokenTextIs(self: *const Parser, tok: lexer.Token, word: []const u8) bool {
        return tok.kind == .identifier and std.mem.eql(u8, tok.text(self.source), word);
    }

    /// Vrai si le token courant peut commencer une expression (pour l'argument
    /// optionnel de `yield`).
    fn canStartExpr(self: *const Parser) bool {
        const t = self.at() orelse return false;
        return switch (t.kind) {
            .semicolon, .r_paren, .r_bracket, .r_brace, .comma, .colon => false,
            else => true,
        };
    }

    /// Parse un corps de fonction `{…}` avec le contexte async/generator donné,
    /// restauré à la sortie (les fonctions imbriquées ont leur propre contexte).
    fn parseFunctionBody(self: *Parser, is_async: bool, is_generator: bool) ParseError!*ast.Node {
        const saved_async = self.in_async;
        const saved_gen = self.in_generator;
        self.in_async = is_async;
        self.in_generator = is_generator;
        defer {
            self.in_async = saved_async;
            self.in_generator = saved_gen;
        }
        return self.parseBlock();
    }

    /// Kind du token à `offset` positions du curseur (lookahead pur).
    fn kindAt(self: *const Parser, offset: usize) ?TokenKind {
        const i = self.pos + offset;
        return if (i < self.tokens.len) self.tokens[i].kind else null;
    }

    fn atKind(self: *const Parser, kind: TokenKind) bool {
        if (self.at()) |t| return t.kind == kind;
        return false;
    }

    fn advance(self: *Parser) void {
        self.pos += 1;
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        if (self.pos < self.tokens.len and self.tokens[self.pos].kind == kind) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn eat(self: *Parser, kind: TokenKind, expected: []const u8) ParseError!lexer.Token {
        if (self.at()) |t| {
            if (t.kind == kind) {
                self.advance();
                return t;
            }
        }
        return self.failUnexpected(self.at(), expected);
    }

    fn expect(self: *Parser, kind: TokenKind, expected: []const u8) ParseError!void {
        _ = try self.eat(kind, expected);
    }

    /// Récupération fine : si le token attendu est là, on le consomme ; sinon on
    /// NOTE l'erreur et on CONTINUE comme s'il était présent (ne déroule pas).
    /// Ex. `if (x { }` : la `)` manquante -> 1 erreur + IfStatement complet.
    fn expectRecover(self: *Parser, kind: TokenKind, expected: []const u8) void {
        if (self.atKind(kind)) {
            self.advance();
        } else {
            const pos = if (self.at()) |t| t.start else @as(u32, @intCast(self.source.len));
            self.recordError(self.expectedMsg(expected), pos);
        }
    }

    fn expectedMsg(self: *Parser, expected: []const u8) []const u8 {
        return std.fmt.allocPrint(self.arena, "expected {s}", .{expected}) catch "parse error";
    }

    /// Un token qui OUVRE clairement un statement (point de synchronisation).
    fn isStatementStart(kind: TokenKind) bool {
        return switch (kind) {
            .kw_if, .kw_for, .kw_while, .kw_do, .kw_const, .kw_let, .kw_var, .kw_function, .kw_return, .kw_class, .kw_switch, .kw_try, .kw_throw, .kw_break, .kw_continue, .kw_import, .kw_export => true,
            else => false,
        };
    }

    /// Panic mode : après une erreur de statement, avance jusqu'à un point de
    /// synchronisation — un `;` (consommé), ou un `}` / début de statement
    /// (on s'arrête AVANT). C'est ce qui permet de reprendre le parsing.
    fn synchronize(self: *Parser) void {
        while (self.at()) |t| {
            switch (t.kind) {
                .semicolon => {
                    self.advance();
                    return;
                },
                .r_brace => return,
                else => {
                    if (isStatementStart(t.kind)) return;
                    self.advance();
                },
            }
        }
    }

    /// Fabrique le nœud `error_node` couvrant le statement raté (de `start_byte`
    /// jusqu'au dernier token consommé), après synchronisation. GARDE-FOU
    /// anti-boucle : si rien n'a avancé, consommer un token de force.
    fn recoverStmt(self: *Parser, before: usize, start_byte: u32) ParseError!*ast.Node {
        self.synchronize();
        if (self.pos == before) self.advance(); // garde-fou OBLIGATOIRE : progresser
        const end: u32 = if (self.pos > 0 and self.pos <= self.tokens.len)
            self.tokens[self.pos - 1].end
        else
            start_byte;
        return self.makeNode(start_byte, end, .error_node);
    }

    /// Fin de statement avec ASI (Automatic Semicolon Insertion). Un `;` explicite
    /// est consommé ; sinon on ACCEPTE (insertion virtuelle) si :
    ///   - fin de source, ou le token suivant est `}` (règle 1), ou
    ///   - un saut de ligne précède le token suivant (règle 1).
    /// Autrement -> erreur : le token ne peut pas suivre sans `;` (ex. `a = 1 b`).
    fn consumeSemicolon(self: *Parser) ParseError!void {
        const t = self.at() orelse return; // fin de source
        if (t.kind == .semicolon) {
            self.advance();
            return;
        }
        if (t.kind == .r_brace or t.newline_before) return; // ASI
        // Récupération fine : `;` manquant sans newline (`a = 1 b`). On NOTE
        // l'erreur mais on CONTINUE (comme si le `;` était là) — le statement
        // courant est complet, le suivant sera parsé normalement.
        self.recordError("expected ';' or newline after statement", t.start);
    }

    fn makeNode(self: *Parser, start: u32, end: u32, kind: ast.Node.Kind) ParseError!*ast.Node {
        const node = try self.arena.create(ast.Node);
        node.* = .{ .start = start, .end = end, .kind = kind };
        return node;
    }

    /// Nœud identifiant depuis un token. Propage le nom DÉCODÉ (`tok.cooked`,
    /// présent si l'identifiant contenait des échappements `\u`) en
    /// `synthetic_text` : le semantic et le printer voient alors le vrai nom.
    fn identNode(self: *Parser, tok: lexer.Token) ParseError!*ast.Node {
        return self.makeNode(tok.start, tok.end, .{ .identifier = .{ .synthetic_text = tok.cooked } });
    }

    /// Enregistre un diagnostic (sans dérouler la pile) — pour les récupérations
    /// fines qui continuent après avoir noté l'erreur.
    fn recordError(self: *Parser, message: []const u8, pos: u32) void {
        self.errors.append(self.arena, .{ .message = message, .pos = pos }) catch {};
    }

    /// Enregistre un diagnostic ET renvoie l'erreur (déroule la pile jusqu'à la
    /// prochaine frontière de statement, où le panic mode récupère).
    fn fail(self: *Parser, err: ParseError, message: []const u8, pos: u32) ParseError {
        self.recordError(message, pos);
        return err;
    }

    fn failUnexpected(self: *Parser, found: ?lexer.Token, expected: []const u8) ParseError {
        const found_desc = if (found) |t| @tagName(t.kind) else "end of input";
        const pos = if (found) |t| t.start else @as(u32, @intCast(self.source.len));
        return self.fail(
            error.UnexpectedToken,
            std.fmt.allocPrint(self.arena, "expected {s}, found {s}", .{ expected, found_desc }) catch "parse error",
            pos,
        );
    }

    // ---- statements ----

    fn parseProgram(self: *Parser) ParseError!*ast.Node {
        var body: std.ArrayList(*ast.Node) = .empty;
        while (self.at()) |t| {
            const before = self.pos;
            const stmt = self.parseModuleItem() catch {
                // Erreur déjà notée par `fail` : panic mode -> error_node + resync.
                try body.append(self.arena, try self.recoverStmt(before, t.start));
                continue;
            };
            try body.append(self.arena, stmt);
            if (self.pos == before) self.advance(); // garde-fou : jamais sur place
        }
        return self.makeNode(0, @intCast(self.source.len), .{ .program = .{ .body = try body.toOwnedSlice(self.arena) } });
    }

    // Top-level : import/export sont des déclarations ; ailleurs (blocs…),
    // parseStatement ne les gère pas -> erreur via parsePrimary.
    fn parseModuleItem(self: *Parser) ParseError!*ast.Node {
        const tok = self.at().?;
        switch (tok.kind) {
            .kw_import => {
                // `import(...)` dynamique et `import.meta` = expressions, pas des
                // déclarations.
                if (self.kindAt(1)) |k| if (k == .l_paren or k == .dot) return self.parseStatement();
                return self.parseImportDeclaration();
            },
            .kw_export => return self.parseExportDeclaration(),
            else => return self.parseStatement(),
        }
    }

    fn parseStatement(self: *Parser) ParseError!*ast.Node {
        const tok = self.at() orelse return self.failUnexpected(null, "statement");
        // `async function …` : déclaration de fonction async (async contextuel).
        if (self.tokenTextIs(tok, "async") and self.kindAt(1) == .kw_function) {
            self.advance(); // 'async'
            return self.parseFunctionDeclaration(tok.start, true);
        }
        // TypeScript : déclarations type-only (`type A = …`, `interface I { … }`).
        if (self.atTsTypeAlias()) return self.parseTypeAlias();
        if (self.atTsInterface()) return self.parseInterface();
        // `abstract class C { … }` : le modifieur `abstract` est effacé (les MEMBRES
        // abstraits sans corps sont HORS phase 1).
        if (self.ts and self.tokenTextIs(tok, "abstract") and self.kindAt(1) == .kw_class) {
            self.advance();
            return self.parseClass(true);
        }
        // TS phase 3 : `enum E {…}`, `const enum E {…}`, `namespace N {…}`/`module N {…}`.
        if (self.atTsEnum()) return self.parseEnum(false);
        if (self.ts and tok.kind == .kw_const and self.kindAt2Is("enum")) {
            self.advance(); // 'const'
            return self.parseEnum(true);
        }
        if (self.atTsNamespace()) return self.parseNamespace();
        // Labeled statement : identifier ':' (ex. `outer: for (…) {}`).
        if (tok.kind == .identifier) {
            if (self.kindAt(1)) |k| if (k == .colon) return self.parseLabeledStatement();
        }
        return switch (tok.kind) {
            .l_brace => self.parseBlock(),
            .kw_if => self.parseIf(),
            .kw_while => self.parseWhile(),
            .kw_do => self.parseDoWhile(),
            .kw_for => self.parseFor(),
            .kw_return => self.parseReturn(),
            .kw_throw => self.parseThrow(),
            .kw_try => self.parseTry(),
            .kw_switch => self.parseSwitch(),
            .kw_break => self.parseBreakContinue(true),
            .kw_continue => self.parseBreakContinue(false),
            .kw_function => self.parseFunctionDeclaration(tok.start, false),
            .kw_class => self.parseClass(true),
            .kw_const, .kw_let, .kw_var => self.parseVariableDeclaration(),
            else => self.parseExpressionStatement(),
        };
    }

    // block := '{' statement* '}'
    fn parseBlock(self: *Parser) ParseError!*ast.Node {
        const lbrace = try self.eat(.l_brace, "'{'");
        var body: std.ArrayList(*ast.Node) = .empty;
        while (self.at()) |t| {
            if (t.kind == .r_brace) break;
            const before = self.pos;
            const stmt = self.parseStatement() catch {
                try body.append(self.arena, try self.recoverStmt(before, t.start));
                continue;
            };
            try body.append(self.arena, stmt);
            if (self.pos == before) self.advance(); // garde-fou
        }
        // `}` manquant (ex. `{ return 1` en fin de source) : récupération fine.
        var end: u32 = if (self.pos > 0) self.tokens[self.pos - 1].end else lbrace.end;
        if (self.atKind(.r_brace)) {
            end = self.at().?.end;
            self.advance();
        } else {
            self.recordError("expected '}'", end);
        }
        return self.makeNode(lbrace.start, end, .{ .block_statement = .{ .body = try body.toOwnedSlice(self.arena) } });
    }

    fn parseIf(self: *Parser) ParseError!*ast.Node {
        const kw = self.at().?;
        self.advance();
        try self.expect(.l_paren, "'('");
        const test_expr = try self.parseExpr();
        self.expectRecover(.r_paren, "')'"); // récup. fine : `if (x {` -> if complet
        const consequent = try self.parseStatement();

        var alternate: ?*ast.Node = null;
        var end = consequent.end;
        if (self.match(.kw_else)) {
            const alt = try self.parseStatement(); // 'else if' = un IfStatement ici
            alternate = alt;
            end = alt.end;
        }
        return self.makeNode(kw.start, end, .{
            .if_statement = .{ .@"test" = test_expr, .consequent = consequent, .alternate = alternate },
        });
    }

    fn parseWhile(self: *Parser) ParseError!*ast.Node {
        const kw = self.at().?;
        self.advance();
        try self.expect(.l_paren, "'('");
        const test_expr = try self.parseExpr();
        self.expectRecover(.r_paren, "')'"); // récup. fine (condition while)
        const body = try self.parseStatement();
        return self.makeNode(kw.start, body.end, .{ .while_statement = .{ .@"test" = test_expr, .body = body } });
    }

    fn parseReturn(self: *Parser) ParseError!*ast.Node {
        const kw = self.at().?;
        self.advance();
        var argument: ?*ast.Node = null;
        var end = kw.end;
        // Restricted production (ASI règle 2) : un saut de ligne après `return`
        // coupe immédiatement -> `return;`.
        if (self.at()) |t| {
            if (!t.newline_before and t.kind != .semicolon and t.kind != .r_brace) {
                const arg = try self.parseExpr();
                argument = arg;
                end = arg.end;
            }
        }
        try self.consumeSemicolon();
        return self.makeNode(kw.start, end, .{ .return_statement = .{ .argument = argument } });
    }

    // throw := 'throw' [no LineTerminator here] expression ';'?  (argument obligatoire)
    fn parseThrow(self: *Parser) ParseError!*ast.Node {
        const kw = self.at().?;
        self.advance();
        // Restricted production (ASI règle 2) : aucun saut de ligne autorisé
        // après `throw` (et l'argument est obligatoire).
        const t = self.at() orelse return self.fail(error.UnexpectedToken, "throw requires an expression", kw.start);
        if (t.newline_before) return self.fail(error.UnexpectedToken, "illegal newline after throw", t.start);
        const argument = try self.parseExpr();
        try self.consumeSemicolon();
        return self.makeNode(kw.start, argument.end, .{ .throw_statement = .{ .argument = argument } });
    }

    // try := 'try' block ('catch' ('(' bindingPattern ')')? block)? ('finally' block)?
    // (au moins un catch ou un finally)
    fn parseTry(self: *Parser) ParseError!*ast.Node {
        const kw = self.at().?;
        self.advance();
        const block = try self.parseBlock();
        var end = block.end;

        var handler: ?*ast.Node = null;
        if (self.atKind(.kw_catch)) {
            const catch_kw = self.at().?;
            self.advance();
            var param: ?*ast.Node = null;
            if (self.atKind(.l_paren)) {
                self.advance();
                const binding = try self.parseBindingPattern(); // identifier ou pattern
                const ann = try self.tsTypeAnnotation(); // `catch (e: unknown)`
                param = try self.wrapTyped(binding, false, ann);
                try self.expect(.r_paren, "')'");
            }
            const cbody = try self.parseBlock();
            handler = try self.makeNode(catch_kw.start, cbody.end, .{ .catch_clause = .{ .param = param, .body = cbody } });
            end = cbody.end;
        }

        var finalizer: ?*ast.Node = null;
        if (self.atKind(.kw_finally)) {
            self.advance();
            const fbody = try self.parseBlock();
            finalizer = fbody;
            end = fbody.end;
        }

        if (handler == null and finalizer == null) {
            return self.fail(error.UnexpectedToken, "missing catch or finally after try", kw.start);
        }
        return self.makeNode(kw.start, end, .{ .try_statement = .{ .block = block, .handler = handler, .finalizer = finalizer } });
    }

    // switch := 'switch' '(' expr ')' '{' (('case' expr | 'default') ':' statement*)* '}'
    fn parseSwitch(self: *Parser) ParseError!*ast.Node {
        const kw = self.at().?;
        self.advance();
        try self.expect(.l_paren, "'('");
        const discriminant = try self.parseExpr();
        self.expectRecover(.r_paren, "')'"); // récup. fine (condition switch)
        try self.expect(.l_brace, "'{'");

        var cases: std.ArrayList(*ast.Node) = .empty;
        var seen_default = false;
        while (self.at()) |t| {
            if (t.kind == .r_brace) break;
            const case_start = t.start;
            var test_expr: ?*ast.Node = null;
            if (self.match(.kw_case)) {
                test_expr = try self.parseExpr();
            } else if (self.match(.kw_default)) {
                if (seen_default) return self.fail(error.MultipleDefault, "multiple default clauses in switch", case_start);
                seen_default = true;
            } else {
                return self.failUnexpected(t, "'case' or 'default'");
            }
            try self.expect(.colon, "':'");
            // Les statements s'accumulent jusqu'au prochain case/default/}.
            var consequent: std.ArrayList(*ast.Node) = .empty;
            while (self.at()) |s| {
                if (s.kind == .r_brace or s.kind == .kw_case or s.kind == .kw_default) break;
                try consequent.append(self.arena, try self.parseStatement());
            }
            const items = try consequent.toOwnedSlice(self.arena);
            var case_end = case_start;
            if (test_expr) |te| case_end = te.end;
            if (items.len > 0) case_end = items[items.len - 1].end;
            try cases.append(self.arena, try self.makeNode(case_start, case_end, .{ .switch_case = .{ .@"test" = test_expr, .consequent = items } }));
        }
        const close = try self.eat(.r_brace, "'}'");
        return self.makeNode(kw.start, close.end, .{ .switch_statement = .{ .discriminant = discriminant, .cases = try cases.toOwnedSlice(self.arena) } });
    }

    // break/continue := ('break'|'continue') identifier? ';'?
    fn parseBreakContinue(self: *Parser, is_break: bool) ParseError!*ast.Node {
        const kw = self.at().?;
        self.advance();
        var label: ?*ast.Node = null;
        var end = kw.end;
        // Restricted production (ASI règle 2) : un label sur la ligne suivante
        // n'appartient PAS au break/continue (`break\nouter` = `break;` puis `outer`).
        if (self.at()) |l| if (l.kind == .identifier and !l.newline_before) {
            self.advance();
            label = try self.identNode(l);
            end = l.end;
        };
        try self.consumeSemicolon();
        return self.makeNode(kw.start, end, if (is_break)
            .{ .break_statement = .{ .label = label } }
        else
            .{ .continue_statement = .{ .label = label } });
    }

    // labeled := identifier ':' statement
    fn parseLabeledStatement(self: *Parser) ParseError!*ast.Node {
        const label_tok = self.at().?;
        self.advance();
        const label = try self.identNode(label_tok);
        try self.expect(.colon, "':'");
        const body = try self.parseStatement();
        return self.makeNode(label_tok.start, body.end, .{ .labeled_statement = .{ .label = label, .body = body } });
    }

    // do-while := 'do' statement 'while' '(' expr ')' ';'?   (';' final optionnel)
    fn parseDoWhile(self: *Parser) ParseError!*ast.Node {
        const kw = self.at().?;
        self.advance();
        const body = try self.parseStatement();
        try self.expect(.kw_while, "'while'");
        try self.expect(.l_paren, "'('");
        const test_expr = try self.parseExpr();
        const close = try self.eat(.r_paren, "')'");
        var end = close.end;
        if (self.at()) |t| if (t.kind == .semicolon) {
            end = t.end;
            self.advance();
        };
        return self.makeNode(kw.start, end, .{ .do_while_statement = .{ .body = body, .@"test" = test_expr } });
    }

    fn parseFor(self: *Parser) ParseError!*ast.Node {
        const kw = self.at().?;
        self.advance();
        // `for await (x of stream)` : itération async, seulement en contexte async
        // et seulement avec `of`.
        var is_await = false;
        if (self.in_async) {
            if (self.at()) |t| if (self.tokenTextIs(t, "await")) {
                self.advance();
                is_await = true;
            };
        }
        try self.expect(.l_paren, "'('");

        // Tête : déclaration | expression | (vide). En contexte for, une decl
        // peut ne pas avoir d'init (for-of/for-in) -> parseVarDeclCore(false).
        var head: ?*ast.Node = null;
        if (self.at()) |t| {
            if (t.kind != .semicolon) {
                head = switch (t.kind) {
                    .kw_const, .kw_let, .kw_var => try self.parseVarDeclCore(false),
                    else => try self.parseExpr(),
                };
            }
        }

        // for-of / for-in ? (`of` contextuel, `in` = kw_in)
        if (head) |h| {
            if (self.matchContextualOf()) {
                const left = try self.forTarget(h);
                const right = try self.parseAssignment();
                try self.expect(.r_paren, "')'");
                const body = try self.parseStatement();
                return self.makeNode(kw.start, body.end, .{ .for_of_statement = .{ .left = left, .right = right, .body = body, .is_await = is_await } });
            }
            // `for await` n'existe qu'avec `of` : tout le reste est une erreur.
            if (is_await) return self.fail(error.UnexpectedToken, "'for await' is only valid with 'of'", kw.start);
            if (self.match(.kw_in)) {
                const left = try self.forTarget(h);
                const right = try self.parseExpr();
                try self.expect(.r_paren, "')'");
                const body = try self.parseStatement();
                return self.makeNode(kw.start, body.end, .{ .for_in_statement = .{ .left = left, .right = right, .body = body } });
            }
            // `for (x in obj)` sans déclaration : `in` étant maintenant un
            // opérateur binaire, `x in obj` a été parsé en binaire ; s'il est
            // suivi de `)`, on le reconstruit en for-in.
            switch (h.kind) {
                .binary_expression => |b| {
                    if (b.operator == .in_ and self.atKind(.r_paren)) {
                        const left = try self.forTarget(b.left);
                        try self.expect(.r_paren, "')'");
                        const body = try self.parseStatement();
                        return self.makeNode(kw.start, body.end, .{ .for_in_statement = .{ .left = left, .right = b.right, .body = body } });
                    }
                },
                else => {},
            }
        }

        // for classique : head est l'init. (`for await (;;)` n'existe pas.)
        if (is_await) return self.fail(error.UnexpectedToken, "'for await' is only valid with 'of'", kw.start);
        try self.expect(.semicolon, "';'");
        var test_expr: ?*ast.Node = null;
        if (self.at()) |t| {
            if (t.kind != .semicolon) test_expr = try self.parseExpr();
        }
        try self.expect(.semicolon, "';'");
        var update: ?*ast.Node = null;
        if (self.at()) |t| {
            if (t.kind != .r_paren) update = try self.parseExpr();
        }
        try self.expect(.r_paren, "')'");

        const body = try self.parseStatement();
        return self.makeNode(kw.start, body.end, .{
            .for_statement = .{ .init = head, .@"test" = test_expr, .update = update, .body = body },
        });
    }

    // functionDeclaration := 'function' identifier '(' params ')' block
    // Curseur sur `function`. `start` = début du nœud (le `async` si présent).
    fn parseFunctionDeclaration(self: *Parser, start: u32, is_async: bool) ParseError!*ast.Node {
        self.advance(); // 'function'
        const is_generator = self.match(.star);
        const name_tok = try self.eat(.identifier, "function name");
        const name = try self.identNode(name_tok);
        const type_params = try self.tsTypeParamsOpt();
        const params = try self.parseParams();
        const return_type = try self.tsTypeAnnotation();
        const body = try self.parseFunctionBody(is_async, is_generator);
        return self.makeNode(start, body.end, .{
            .function_declaration = .{ .id = name, .params = params, .body = body, .is_async = is_async, .is_generator = is_generator, .return_type = return_type, .type_params = type_params },
        });
    }

    // Expression de fonction. Curseur sur `function`. Le nom est optionnel.
    fn parseFunctionExpression(self: *Parser, start: u32, is_async: bool) ParseError!*ast.Node {
        self.advance(); // 'function'
        const is_generator = self.match(.star);
        var name: ?*ast.Node = null;
        if (self.at()) |t| if (t.kind == .identifier) {
            name = try self.identNode(t);
            self.advance();
        };
        const type_params = try self.tsTypeParamsOpt();
        const params = try self.parseParams();
        const return_type = try self.tsTypeAnnotation();
        const body = try self.parseFunctionBody(is_async, is_generator);
        return self.makeNode(start, body.end, .{
            .function_expression = .{ .id = name, .params = params, .body = body, .is_async = is_async, .is_generator = is_generator, .return_type = return_type, .type_params = type_params },
        });
    }

    // params := '(' (param (',' param)*)? ')'
    // param := bindingPattern ('?')? (':' type)? ('=' assignment)? | '...' rest (':' type)?
    // Les `?`/`:` (TypeScript) enveloppent le binding dans `ts_typed`.
    fn parseParams(self: *Parser) ParseError![]*ast.Node {
        try self.expect(.l_paren, "'('");
        var params: std.ArrayList(*ast.Node) = .empty;
        while (self.at()) |t| {
            if (t.kind == .r_paren) break;
            if (t.kind == .dot_dot_dot) {
                var rest = try self.parseRestElement();
                if (try self.tsTypeAnnotation()) |ann| rest = try self.wrapTyped(rest, false, ann); // `...args: T[]`
                try params.append(self.arena, rest);
                if (self.at()) |n| if (n.kind == .comma) {
                    return self.fail(error.RestNotLast, "rest element must be last", rest.start);
                };
                break;
            }
            try params.append(self.arena, try self.parseParam());
            if (!self.match(.comma)) break;
        }
        try self.expect(.r_paren, "')'");
        return params.toOwnedSlice(self.arena);
    }

    // Un paramètre : cible + `?`/`:` (TS) + défaut éventuel.
    fn parseParam(self: *Parser) ParseError!*ast.Node {
        // TS phase 3 : parameter property `constructor(private x: T)`. On collecte
        // les modificateurs d'accès/readonly ; leur PRÉSENCE fait de ce param une
        // property (le strip ajoute `this.x = x` en tête du constructeur).
        const start = if (self.at()) |t| t.start else 0;
        var access: []const u8 = "";
        var readonly = false;
        var is_param_prop = false;
        if (self.ts) while (self.at()) |t| {
            if (t.kind != .identifier) break;
            const text = t.text(self.source);
            if (std.mem.eql(u8, text, "public") or std.mem.eql(u8, text, "private") or std.mem.eql(u8, text, "protected")) {
                if (!self.kindStartsBinding(self.kindAt(1))) break; // `private` seul = nom de param
                access = text;
                is_param_prop = true;
                self.advance();
            } else if (std.mem.eql(u8, text, "readonly")) {
                if (!self.kindStartsBinding(self.kindAt(1))) break;
                readonly = true;
                is_param_prop = true;
                self.advance();
            } else break;
        };

        const binding = try self.parseBindingPattern();
        const optional = self.tsOptional();
        const ann = try self.tsTypeAnnotation();
        const typed = try self.wrapTyped(binding, optional, ann);
        var param = typed;
        if (self.match(.eq)) {
            const default = try self.parseAssignment();
            param = try self.makeNode(typed.start, default.end, .{ .assignment_pattern = .{ .left = typed, .right = default } });
        }
        if (is_param_prop) return self.makeNode(start, param.end, .{ .ts_param_property = .{ .param = param, .access = access, .readonly = readonly } });
        return param;
    }

    /// Un token qui peut commencer une cible de binding (pour distinguer un
    /// modificateur `private x` d'un param nommé `private`).
    fn kindStartsBinding(_: *const Parser, kind: ?TokenKind) bool {
        return switch (kind orelse return false) {
            .identifier, .l_bracket, .l_brace, .dot_dot_dot => true,
            else => false,
        };
    }

    fn parseVariableDeclaration(self: *Parser) ParseError!*ast.Node {
        const decl = try self.parseVarDeclCore(true);
        try self.consumeSemicolon();
        return decl;
    }

    // `enforce_const_init` : faux en contexte `for` (for-of/for-in autorisent
    // `const x` sans initialiseur).
    fn parseVarDeclCore(self: *Parser, enforce_const_init: bool) ParseError!*ast.Node {
        const kw = self.at().?;
        const decl_kind: ast.DeclarationKind = switch (kw.kind) {
            .kw_const => .@"const",
            .kw_let => .let,
            .kw_var => .@"var",
            else => unreachable,
        };
        self.advance();

        var decls: std.ArrayList(*ast.Node) = .empty;
        while (true) {
            // Cible : identifiant OU pattern de destructuring ([...] / {...}).
            const target = try self.parseBindingPattern();
            // TS : `let x!: T` (definite assignment, `!` effacé) puis `: T`.
            if (self.ts) _ = self.match(.bang);
            const ann = try self.tsTypeAnnotation();
            const id = try self.wrapTyped(target, false, ann);

            var init: ?*ast.Node = null;
            var end = id.end;
            if (self.match(.eq)) {
                const value = try self.parseAssignment();
                init = value;
                end = value.end;
            } else if (enforce_const_init and decl_kind == .@"const") {
                return self.fail(error.MissingInitializer, "missing initializer in const declaration", id.start);
            }

            try decls.append(self.arena, try self.makeNode(id.start, end, .{
                .variable_declarator = .{ .id = id, .init = init },
            }));
            if (!self.match(.comma)) break;
        }

        const end = decls.items[decls.items.len - 1].end;
        return self.makeNode(kw.start, end, .{
            .variable_declaration = .{ .kind = decl_kind, .declarations = try decls.toOwnedSlice(self.arena) },
        });
    }

    fn parseExpressionStatement(self: *Parser) ParseError!*ast.Node {
        const expr = try self.parseExpr();
        try self.consumeSemicolon();
        return self.makeNode(expr.start, expr.end, .{ .expression_statement = .{ .expression = expr } });
    }

    // ---- expressions ----

    // Expression (niveau le plus bas de la grammaire) = opérateur virgule.
    // `a, b, c` -> SequenceExpression. Sans virgule, on renvoie l'AssignmentExpression
    // tel quel (pas de nœud séquence à un seul élément). La virgule-opérateur n'existe
    // qu'ici : args d'appel, éléments de tableau et valeurs d'objet passent par
    // parseAssignment, où la virgule reste un séparateur.
    fn parseExpr(self: *Parser) ParseError!*ast.Node {
        const first = try self.parseAssignment();
        if (!self.atKind(.comma)) return first;

        var exprs: std.ArrayList(*ast.Node) = .empty;
        try exprs.append(self.arena, first);
        while (self.match(.comma)) {
            try exprs.append(self.arena, try self.parseAssignment());
        }
        const items = try exprs.toOwnedSlice(self.arena);
        return self.makeNode(items[0].start, items[items.len - 1].end, .{ .sequence_expression = .{ .expressions = items } });
    }

    // assignment := yield | arrow | conditional (assignOp assignment)?
    fn parseAssignment(self: *Parser) ParseError!*ast.Node {
        // `yield` / `yield*` : mot-clé UNIQUEMENT dans un generator, au niveau
        // de l'assignation (une des productions de AssignmentExpression).
        if (self.in_generator) {
            if (self.at()) |t| if (self.tokenTextIs(t, "yield")) return self.parseYield();
        }
        if (try self.tryParseArrow()) |arrow| return arrow;

        const left = try self.parseConditional();
        const tok = self.at() orelse return left;
        const op = assignOp(tok.kind) orelse return left;

        // Cible tableau/objet littéral -> destructuring assignment. On a parsé
        // une ArrayExpression/ObjectExpression (position d'expression) ; c'est en
        // voyant `=` qu'on sait que c'était une cible -> on CONVERTIT (cover
        // grammar). Seul `=` l'autorise (`[a] += x` est une erreur).
        const target = switch (left.kind) {
            .array_expression, .object_expression => t: {
                if (op != .assign) return self.fail(error.InvalidAssignmentTarget, "invalid assignment target", left.start);
                break :t try self.toPattern(left);
            },
            else => t: {
                if (!isAssignable(left)) return self.fail(error.InvalidAssignmentTarget, "invalid assignment target", left.start);
                break :t left;
            },
        };
        self.advance();
        const value = try self.parseAssignment();
        return self.makeNode(target.start, value.end, .{
            .assignment_expression = .{ .operator = op, .target = target, .value = value },
        });
    }

    // Détecte et parse une arrow function, sinon retourne null (sans consommer).
    //   (a) identifier '=>'
    //   (b) '(' ... ')' '=>'   (scan pur des parenthèses jusqu'à la ')' fermante)
    fn tryParseArrow(self: *Parser) ParseError!?*ast.Node {
        const tok = self.at() orelse return null;

        // Arrow async (`async` contextuel) : `async x =>` ou `async (...) =>`.
        // ATTENTION : `async(...)` SANS `=>` est un APPEL de `async` (pas une
        // arrow) -> on n'engage que si `=>` suit vraiment.
        if (self.tokenTextIs(tok, "async")) {
            if (self.kindAt(1) == .identifier and self.kindAt(2) == .arrow) {
                self.advance(); // 'async'
                const p = self.at().?;
                self.advance(); // param
                const params = try self.arena.alloc(*ast.Node, 1);
                params[0] = try self.identNode(p);
                return try self.finishArrow(tok.start, params, true, null);
            }
            if (self.kindAt(1) == .l_paren and self.arrowAheadAt(self.pos + 1)) {
                self.advance(); // 'async'
                const params = try self.parseParams();
                const rt = try self.tsTypeAnnotation();
                return try self.finishArrow(tok.start, params, true, rt);
            }
        }

        if (tok.kind == .identifier and self.kindAt(1) == .arrow) {
            self.advance(); // identifier
            const param = try self.identNode(tok);
            const params = try self.arena.alloc(*ast.Node, 1);
            params[0] = param;
            return try self.finishArrow(tok.start, params, false, null);
        }

        if (tok.kind == .l_paren and self.arrowAhead()) {
            const params = try self.parseParams();
            const rt = try self.tsTypeAnnotation();
            return try self.finishArrow(tok.start, params, false, rt);
        }

        return null;
    }

    /// Vrai si, depuis un '(' au curseur, la ')' correspondante est suivie d'un
    /// '=>'. Scan non destructif (le tableau de tokens EST notre sauvegarde de
    /// position). On compte TOUS les brackets `()[]{}` pour ne pas confondre la
    /// ')' fermante avec une autre dans `([a, b]) =>` / `({ k }) =>`.
    fn arrowAhead(self: *const Parser) bool {
        return self.arrowAheadAt(self.pos);
    }

    /// Idem `arrowAhead` mais en partant d'un index arbitraire (le token à
    /// `start` doit être une `(`). Sert à `async (...) =>`.
    fn arrowAheadAt(self: *const Parser, start: usize) bool {
        var depth: usize = 0;
        var i = start;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].kind) {
                .l_paren, .l_bracket, .l_brace => depth += 1,
                .r_paren, .r_bracket, .r_brace => {
                    depth -= 1;
                    if (depth == 0) {
                        const j = i + 1;
                        if (j >= self.tokens.len) return false;
                        if (self.tokens[j].kind == .arrow) return true;
                        // TS : retour typé `): T =>` — le `=>` suit le type, pas la `)`.
                        if (self.ts and self.tokens[j].kind == .colon) return self.arrowAfterReturnType(j + 1);
                        return false;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    /// Après un `):` (arrow à retour typé), scanne le type et renvoie vrai si un
    /// `=>` le suit au niveau 0. Heuristique phase 1 : ne compte que `()[]{}` (les
    /// `<>` des génériques passent au travers). Un `,`/`;` au niveau 0 avant `=>`
    /// = pas une arrow (ex. ternaire `a ? (x) : y`).
    fn arrowAfterReturnType(self: *const Parser, start: usize) bool {
        var depth: i32 = 0;
        var i = start;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].kind) {
                .l_paren, .l_bracket, .l_brace => depth += 1,
                .r_paren, .r_bracket, .r_brace => {
                    depth -= 1;
                    if (depth < 0) return false; // sortie du contexte englobant
                },
                .arrow => if (depth == 0) return true,
                .semicolon, .comma => if (depth == 0) return false,
                else => {},
            }
        }
        return false;
    }

    // Après les params : '=>' puis un corps bloc ('{') ou expression (assignment).
    // Le corps hérite du contexte async de l'arrow (jamais generator). On
    // sauvegarde/restaure les flags pour que le corps voie le bon contexte
    // `await` (une arrow non-async remet `in_async=false`).
    fn finishArrow(self: *Parser, start: u32, params: []*ast.Node, is_async: bool, return_type: ?*ast.Node) ParseError!*ast.Node {
        try self.expect(.arrow, "'=>'");
        const saved_async = self.in_async;
        const saved_gen = self.in_generator;
        self.in_async = is_async;
        self.in_generator = false;
        defer {
            self.in_async = saved_async;
            self.in_generator = saved_gen;
        }
        if (self.atKind(.l_brace)) {
            const body = try self.parseBlock();
            return self.makeNode(start, body.end, .{
                .arrow_function = .{ .params = params, .body = body, .expression = false, .is_async = is_async, .return_type = return_type },
            });
        }
        const body = try self.parseAssignment();
        return self.makeNode(start, body.end, .{
            .arrow_function = .{ .params = params, .body = body, .expression = true, .is_async = is_async, .return_type = return_type },
        });
    }

    // `yield` / `yield*` (curseur sur `yield`). Argument optionnel pour `yield`
    // seul ; obligatoire pour `yield*`.
    fn parseYield(self: *Parser) ParseError!*ast.Node {
        const kw = self.at().?;
        self.advance(); // 'yield'
        const delegate = self.match(.star);
        var argument: ?*ast.Node = null;
        var end = kw.end;
        if (delegate or self.canStartExpr()) {
            const arg = try self.parseAssignment();
            argument = arg;
            end = arg.end;
        }
        return self.makeNode(kw.start, end, .{ .yield_expression = .{ .argument = argument, .delegate = delegate } });
    }

    fn parseConditional(self: *Parser) ParseError!*ast.Node {
        const cond = try self.parseExpression(0);
        if (self.match(.question)) {
            const consequent = try self.parseAssignment();
            try self.expect(.colon, "':'");
            const alternate = try self.parseAssignment();
            return self.makeNode(cond.start, alternate.end, .{
                .conditional_expression = .{ .@"test" = cond, .consequent = consequent, .alternate = alternate },
            });
        }
        return cond;
    }

    // `x as T` / `x satisfies T` : opérateurs de type postfixes (TS). Précédence
    // juste au-dessus des binaires (`x + y as T` = `x + (y as T)`), on ERASE de
    // toute façon donc la frontière importe peu pour le strip.
    fn parseCast(self: *Parser) ParseError!*ast.Node {
        var e = try self.parseUnary();
        if (!self.ts) return e;
        while (self.at()) |t| {
            if (t.kind != .identifier or t.newline_before) break;
            const is_as = self.tokenTextIs(t, "as");
            const is_sat = self.tokenTextIs(t, "satisfies");
            if (!is_as and !is_sat) break;
            self.advance();
            // `x as const` (const assertion) : `const` est kw_const.
            const type_node = if (is_as and self.atKind(.kw_const)) blk: {
                const c = self.at().?;
                self.advance();
                break :blk try self.makeNode(c.start, c.end, .ts_keyword_type);
            } else try self.parseType();
            e = try self.makeNode(e.start, type_node.end, if (is_as)
                .{ .ts_as_expression = .{ .expr = e, .@"type" = type_node } }
            else
                .{ .ts_satisfies_expression = .{ .expr = e, .@"type" = type_node } });
        }
        return e;
    }

    fn parseExpression(self: *Parser, min_prec: u8) ParseError!*ast.Node {
        var left = try self.parseCast();
        while (self.at()) |tok| {
            const info = binaryInfo(tok.kind) orelse break;
            if (info.prec < min_prec) break;
            self.advance();
            const next_min = if (info.right_assoc) info.prec else info.prec + 1;
            const right = try self.parseExpression(next_min);
            left = try self.makeNode(left.start, right.end, .{
                .binary_expression = .{ .operator = info.op, .left = left, .right = right },
            });
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*ast.Node {
        const tok = self.at() orelse return self.failUnexpected(null, "expression");

        // `await expr` : mot-clé UNIQUEMENT en contexte async ; même précédence
        // que les opérateurs unaires (typeof/void/delete).
        if (self.in_async and self.tokenTextIs(tok, "await")) {
            self.advance();
            const arg = try self.parseUnary();
            return self.makeNode(tok.start, arg.end, .{ .await_expression = .{ .argument = arg } });
        }

        if (updateOp(tok.kind)) |o| {
            self.advance();
            const arg = try self.parseUnary();
            return self.makeNode(tok.start, arg.end, .{
                .update_expression = .{ .operator = o, .argument = arg, .prefix = true },
            });
        }

        const uop: ?ast.UnaryOp = switch (tok.kind) {
            .bang => .not,
            .minus => .neg,
            .plus => .pos,
            .tilde => .bitwise_not,
            .kw_typeof => .typeof_,
            .kw_void => .void_,
            .kw_delete => .delete_,
            else => null,
        };
        if (uop) |o| {
            self.advance();
            const operand = try self.parseUnary();
            return self.makeNode(tok.start, operand.end, .{
                .unary_expression = .{ .operator = o, .operand = operand },
            });
        }

        var expr = try self.parsePostfix();
        // Postfix `++`/`--` : restricted production (ASI règle 2). Un `++`/`--`
        // sur la ligne suivante appartient au statement suivant (préfixe) :
        // `a\n++b` = `a; ++b;`, PAS `a++; b;`.
        if (self.at()) |t| {
            if (updateOp(t.kind)) |o| {
                if (t.newline_before) return expr;
                self.advance();
                expr = try self.makeNode(expr.start, t.end, .{
                    .update_expression = .{ .operator = o, .argument = expr, .prefix = false },
                });
            }
        }
        return expr;
    }

    fn parsePostfix(self: *Parser) ParseError!*ast.Node {
        var expr = try self.parsePrimary();
        while (self.at()) |tok| {
            // TS : assertion non-null `x!` (postfix). `!=`/`!==` sont d'autres tokens
            // (maximal munch), donc un `bang` seul après un opérande est bien `!`.
            if (self.ts and tok.kind == .bang and !tok.newline_before) {
                self.advance();
                expr = try self.makeNode(expr.start, tok.end, .{ .ts_non_null_expression = .{ .expr = expr } });
                continue;
            }
            switch (tok.kind) {
                .l_paren => expr = try self.finishCall(expr, false),
                .dot => {
                    self.advance();
                    expr = try self.member(expr, try self.propertyName(), false, false);
                },
                .l_bracket => expr = try self.computedMember(expr, false),
                .question_dot => {
                    self.advance();
                    const next = self.at() orelse return self.failUnexpected(null, "property name, '(' or '['");
                    switch (next.kind) {
                        .l_paren => expr = try self.finishCall(expr, true),
                        .l_bracket => expr = try self.computedMember(expr, true),
                        else => expr = try self.member(expr, try self.propertyName(), false, true),
                    }
                },
                // Tagged template : `tag`…`` -> l'expression courante taggue le template.
                .template_full, .template_head => {
                    const quasi = try self.parseTemplateLiteral();
                    expr = try self.makeNode(expr.start, quasi.end, .{
                        .tagged_template_expression = .{ .tag = expr, .quasi = quasi },
                    });
                },
                // TS phase 2 : `<` en postfix -> peut-être un appel générique
                // `foo<T>(x)`. Spéculation ; si ça n'en est pas un, `break` et le
                // Pratt traitera `<` en comparaison. (Jamais en JS : gated `self.ts`.)
                .lt => {
                    if (!self.ts) break;
                    if (try self.tryGenericCall(expr)) |call| {
                        expr = call;
                    } else break;
                },
                else => break,
            }
        }
        return expr;
    }

    // Nom de membre après `.` : un identifiant OU n'importe quel mot réservé
    // (`p.catch`, `x.default`, `a.in` sont légaux — les mots-clés sont autorisés
    // comme noms de propriété).
    fn propertyName(self: *Parser) ParseError!*ast.Node {
        const t = self.at() orelse return self.failUnexpected(null, "property name");
        // `this.#x` : accès à un membre privé.
        if (t.kind == .private_name) {
            self.advance();
            return self.makeNode(t.start, t.end, .private_name);
        }
        if (t.kind != .identifier and !isKeyword(t.kind)) return self.failUnexpected(t, "property name");
        self.advance();
        return self.identNode(t);
    }

    fn member(self: *Parser, object: *ast.Node, property: *ast.Node, computed: bool, optional: bool) ParseError!*ast.Node {
        return self.makeNode(object.start, property.end, .{
            .member_expression = .{ .object = object, .property = property, .computed = computed, .optional = optional },
        });
    }

    fn computedMember(self: *Parser, object: *ast.Node, optional: bool) ParseError!*ast.Node {
        self.advance(); // '['
        const property = try self.parseExpr();
        const close = try self.eat(.r_bracket, "']'");
        return self.makeNode(object.start, close.end, .{
            .member_expression = .{ .object = object, .property = property, .computed = true, .optional = optional },
        });
    }

    const ArgList = struct { args: []*ast.Node, end: u32 };

    // '(' (arg (',' arg)*)? ')'   arg = spread | assignment. Curseur sur '('.
    fn parseArgList(self: *Parser) ParseError!ArgList {
        self.advance(); // '('
        var args: std.ArrayList(*ast.Node) = .empty;
        if (self.at()) |t| {
            if (t.kind != .r_paren) {
                while (true) {
                    const spread = if (self.at()) |a| a.kind == .dot_dot_dot else false;
                    const arg = if (spread) try self.parseSpread() else try self.parseAssignment();
                    try args.append(self.arena, arg);
                    if (!self.match(.comma) or self.atKind(.r_paren)) break; // trailing comma
                }
            }
        }
        const close = try self.eat(.r_paren, "')'");
        return .{ .args = try args.toOwnedSlice(self.arena), .end = close.end };
    }

    fn finishCall(self: *Parser, callee: *ast.Node, optional: bool) ParseError!*ast.Node {
        const al = try self.parseArgList();
        return self.makeNode(callee.start, al.end, .{
            .call_expression = .{ .callee = callee, .arguments = al.args, .optional = optional },
        });
    }

    /// TS phase 2 — SPÉCULATION d'un appel générique `foo<T>(x)` / `foo<T>`…`` `.
    /// `foo<T>(x)` est ambigu avec `(foo<T) > (x)` en JS : le lexer ne peut pas
    /// trancher, c'est un problème de PARSER. Stratégie de l'industrie (tsc/esbuild/
    /// oxc) : tenter de parser `< args de type >` puis regarder le token SUIVANT.
    /// `(` ou un template -> c'était bien des arguments de type. Sinon (ou échec du
    /// parse de type) -> RESTAURER pos/pending_gt/erreurs et renvoyer null (silence
    /// TOTAL : ni diagnostic ni nœud) ; le `<` redevient une comparaison.
    fn tryGenericCall(self: *Parser, callee: *ast.Node) ParseError!?*ast.Node {
        const saved_pos = self.pos;
        const saved_gt = self.pending_gt;
        const saved_errs = self.errors.items.len;

        const type_args = self.parseTypeArgs() catch {
            self.rewindSpec(saved_pos, saved_gt, saved_errs);
            return null;
        };
        const t = self.at() orelse {
            self.rewindSpec(saved_pos, saved_gt, saved_errs);
            return null;
        };
        switch (t.kind) {
            .l_paren => {
                const al = try self.parseArgList();
                return try self.makeNode(callee.start, al.end, .{
                    .call_expression = .{ .callee = callee, .arguments = al.args, .optional = false, .type_args = type_args },
                });
            },
            // Tagged template générique : `` foo<T>`x` `` (rare mais réel).
            .template_full, .template_head => {
                const quasi = try self.parseTemplateLiteral();
                return try self.makeNode(callee.start, quasi.end, .{
                    .tagged_template_expression = .{ .tag = callee, .quasi = quasi, .type_args = type_args },
                });
            },
            else => {
                self.rewindSpec(saved_pos, saved_gt, saved_errs);
                return null;
            },
        }
    }

    /// Rembobine une spéculation ratée : position, `>` virtuels, ET la longueur de
    /// la liste d'erreurs (les diagnostics accumulés pendant la tentative sont
    /// effacés — zéro trace).
    fn rewindSpec(self: *Parser, pos: usize, gt: u32, errs_len: usize) void {
        self.pos = pos;
        self.pending_gt = gt;
        self.errors.items.len = errs_len;
    }

    // primary := number | string | identifier | functionExpression | '(' expr ')'
    fn parsePrimary(self: *Parser) ParseError!*ast.Node {
        const tok = self.at() orelse return self.failUnexpected(null, "expression");
        switch (tok.kind) {
            .number => {
                self.advance();
                return self.makeNode(tok.start, tok.end, .{ .number_literal = .{} });
            },
            .bigint => {
                self.advance();
                return self.makeNode(tok.start, tok.end, .bigint_literal);
            },
            .string => {
                self.advance();
                return self.makeNode(tok.start, tok.end, .{ .string_literal = .{} });
            },
            .kw_true, .kw_false => {
                self.advance();
                return self.makeNode(tok.start, tok.end, .{ .boolean_literal = .{} });
            },
            .kw_null => {
                self.advance();
                return self.makeNode(tok.start, tok.end, .null_literal);
            },
            .regex => {
                self.advance();
                return self.makeNode(tok.start, tok.end, .regex_literal);
            },
            // `#x in obj` (ES2022) : le nom privé en position primaire, suivi de `in`.
            .private_name => {
                self.advance();
                return self.makeNode(tok.start, tok.end, .private_name);
            },
            .identifier => {
                // `async function …` : expression de fonction async.
                if (self.tokenTextIs(tok, "async") and self.kindAt(1) == .kw_function) {
                    self.advance(); // 'async'
                    return self.parseFunctionExpression(tok.start, true);
                }
                self.advance();
                return self.identNode(tok);
            },
            .kw_function => return self.parseFunctionExpression(tok.start, false),
            .l_bracket => return self.parseArrayLiteral(),
            .l_brace => return self.parseObjectLiteral(),
            .template_full, .template_head => return self.parseTemplateLiteral(),
            .kw_this => {
                self.advance();
                return self.makeNode(tok.start, tok.end, .this_expression);
            },
            .kw_super => {
                // `super` n'est valide qu'en callee d'appel (`super(...)`) ou
                // objet de membre (`super.x`, `super[k]`) — jamais seul.
                const next = self.kindAt(1) orelse return self.fail(error.UnexpectedToken, "'super' must be followed by '.', '[' or '('", tok.start);
                if (next != .dot and next != .l_bracket and next != .l_paren) {
                    return self.fail(error.UnexpectedToken, "'super' must be followed by '.', '[' or '('", tok.start);
                }
                self.advance();
                return self.makeNode(tok.start, tok.end, .super_expression);
            },
            .kw_new => return self.parseNew(),
            .kw_class => return self.parseClass(false),
            // import(...) dynamique. Un `import`/`export` hors expression est
            // une déclaration réservée au top-level (parseModuleItem).
            .kw_import => {
                if (self.kindAt(1)) |k| {
                    if (k == .l_paren) {
                        self.advance(); // 'import'
                        try self.expect(.l_paren, "'('");
                        const src = try self.parseAssignment();
                        const close = try self.eat(.r_paren, "')'");
                        return self.makeNode(tok.start, close.end, .{ .import_expression = .{ .source = src } });
                    }
                    if (k == .dot) {
                        // import.meta (meta-property des modules ES).
                        self.advance(); // 'import'
                        self.advance(); // '.'
                        const prop = try self.eat(.identifier, "'meta'");
                        return self.makeNode(tok.start, prop.end, .meta_property);
                    }
                }
                return self.fail(error.ImportExportTopLevel, "import/export only allowed at top level", tok.start);
            },
            .kw_export => return self.fail(error.ImportExportTopLevel, "import/export only allowed at top level", tok.start),
            .l_paren => {
                self.advance();
                const inner = try self.parseExpr();
                try self.expect(.r_paren, "')'");
                return inner;
            },
            // JSX : un `<` en position primaire (le lexer l'a lexé en mode tag) =
            // élément JSX. `lt` n'a de sens en primaire que si jsx est activé.
            .lt => {
                if (self.jsx) return self.parseJSXElement();
                return self.failUnexpected(tok, "expression");
            },
            else => return self.failUnexpected(tok, "expression"),
        }
    }

    fn parseSpread(self: *Parser) ParseError!*ast.Node {
        const dots = self.at().?; // '...'
        self.advance();
        const arg = try self.parseAssignment();
        return self.makeNode(dots.start, arg.end, .{ .spread_element = .{ .argument = arg } });
    }

    // array := '[' element (',' element)* ']'   element = spread | assignment | (vide -> elision)
    fn parseArrayLiteral(self: *Parser) ParseError!*ast.Node {
        const open = self.at().?; // '['
        self.advance();
        var elements: std.ArrayList(?*ast.Node) = .empty;
        while (self.at()) |t| {
            if (t.kind == .r_bracket) break;
            if (t.kind == .comma) {
                try elements.append(self.arena, null); // elision
                self.advance();
                continue;
            }
            const el = if (t.kind == .dot_dot_dot) try self.parseSpread() else try self.parseAssignment();
            try elements.append(self.arena, el);
            if (!self.match(.comma)) break;
        }
        const close = try self.eat(.r_bracket, "']'");
        return self.makeNode(open.start, close.end, .{
            .array_expression = .{ .elements = try elements.toOwnedSlice(self.arena) },
        });
    }

    // object := '{' (property (',' property)*)? '}'
    fn parseObjectLiteral(self: *Parser) ParseError!*ast.Node {
        const open = self.at().?; // '{'
        self.advance();
        var properties: std.ArrayList(*ast.Node) = .empty;
        while (self.at()) |t| {
            if (t.kind == .r_brace) break;
            // `{ ...defaults }` : spread (valeur) dans un objet.
            const prop = if (t.kind == .dot_dot_dot) try self.parseSpread() else try self.parseProperty();
            try properties.append(self.arena, prop);
            if (!self.match(.comma)) break;
        }
        const close = try self.eat(.r_brace, "'}'");
        return self.makeNode(open.start, close.end, .{
            .object_expression = .{ .properties = try properties.toOwnedSlice(self.arena) },
        });
    }

    // property := method | '[' expr ']' ':' assignment | key ':' assignment | key (shorthand)
    // method  := ('async')? ('*')? (get|set)? key '(' params ')' block
    // key réutilise `parseClassKey` (identifiant, mot réservé, string, number,
    // `[expr]`) ; les méthodes réutilisent le nœud `MethodDefinition` des classes.
    fn parseProperty(self: *Parser) ParseError!*ast.Node {
        const start = self.at().?.start;

        // Modifieurs de méthode (tous contextuels) : async, *, get, set.
        var is_async = false;
        var is_generator = false;
        if (self.isAsyncMethodModifier()) {
            self.advance();
            is_async = true;
        }
        if (self.match(.star)) is_generator = true;
        var mkind: ast.MethodKind = .method;
        if (!is_async and !is_generator) {
            if (self.isContextual("get")) {
                self.advance();
                mkind = .getter;
            } else if (self.isContextual("set")) {
                self.advance();
                mkind = .setter;
            }
        }
        const method_prefix = is_async or is_generator or mkind != .method;

        var computed = false;
        const key = try self.parseClassKey(&computed);

        // Méthode d'objet : `key ( params ) { body }`.
        if (self.atKind(.l_paren)) {
            const params = try self.parseParams();
            const body = try self.parseFunctionBody(is_async, is_generator);
            return self.makeNode(start, body.end, .{ .method_definition = .{
                .key = key,
                .params = params,
                .body = body,
                .kind = mkind,
                .static = false,
                .computed = computed,
                .is_async = is_async,
                .is_generator = is_generator,
            } });
        }
        // Un préfixe get/set/async/* sans `(` -> erreur.
        if (method_prefix) return self.failUnexpected(self.at(), "'(' (method body)");

        // Clé calculée non-méthode : `{ [k]: v }`.
        if (computed) {
            try self.expect(.colon, "':'");
            const value = try self.parseAssignment();
            return self.makeNode(start, value.end, .{
                .property = .{ .key = key, .value = value, .shorthand = false, .computed = true },
            });
        }

        // `key: value`.
        if (self.match(.colon)) {
            const value = try self.parseAssignment();
            return self.makeNode(start, value.end, .{
                .property = .{ .key = key, .value = value, .shorthand = false, .computed = false },
            });
        }

        // Shorthand : uniquement un identifiant nu.
        if (key.kind != .identifier) return self.failUnexpected(self.at(), "':'");

        // Cover grammar : `{ x = 1 }`. Invalide comme ObjectExpression pur, mais
        // valide comme CIBLE de destructuring (`({ x = 1 } = o)`) — on l'accepte,
        // la valeur = AssignmentPattern, et `toPattern` la garde telle quelle.
        if (self.match(.eq)) {
            const default_val = try self.parseAssignment();
            const ap = try self.makeNode(key.start, default_val.end, .{
                .assignment_pattern = .{ .left = key, .right = default_val },
            });
            return self.makeNode(start, default_val.end, .{
                .property = .{ .key = key, .value = ap, .shorthand = true, .computed = false },
            });
        }

        return self.makeNode(start, key.end, .{
            .property = .{ .key = key, .value = key, .shorthand = true, .computed = false },
        });
    }

    // ---- patterns (destructuring : cibles de liaison) ----

    // bindingPattern := identifier | arrayPattern | objectPattern
    fn parseBindingPattern(self: *Parser) ParseError!*ast.Node {
        const tok = self.at() orelse return self.failUnexpected(null, "binding pattern");
        switch (tok.kind) {
            .identifier => {
                self.advance();
                return self.identNode(tok);
            },
            .l_bracket => return self.parseArrayPattern(),
            .l_brace => return self.parseObjectPattern(),
            else => return self.failUnexpected(tok, "binding pattern"),
        }
    }

    // bindingElement := bindingPattern ('=' assignment)?   (défaut -> AssignmentPattern)
    fn parseBindingElement(self: *Parser) ParseError!*ast.Node {
        const target = try self.parseBindingPattern();
        if (self.match(.eq)) {
            const default = try self.parseAssignment();
            return self.makeNode(target.start, default.end, .{
                .assignment_pattern = .{ .left = target, .right = default },
            });
        }
        return target;
    }

    // '...' bindingPattern   (rest : pas de défaut)
    fn parseRestElement(self: *Parser) ParseError!*ast.Node {
        const dots = self.at().?; // '...'
        self.advance();
        const arg = try self.parseBindingPattern();
        return self.makeNode(dots.start, arg.end, .{ .rest_element = .{ .argument = arg } });
    }

    // arrayPattern := '[' element (',' element)* ']'
    //   element = bindingElement | '...' bindingPattern | (vide -> trou)
    fn parseArrayPattern(self: *Parser) ParseError!*ast.Node {
        const open = self.at().?; // '['
        self.advance();
        var elements: std.ArrayList(?*ast.Node) = .empty;
        while (self.at()) |t| {
            if (t.kind == .r_bracket) break;
            if (t.kind == .comma) {
                try elements.append(self.arena, null); // trou
                self.advance();
                continue;
            }
            if (t.kind == .dot_dot_dot) {
                const rest = try self.parseRestElement();
                try elements.append(self.arena, rest);
                if (self.at()) |n| if (n.kind == .comma) {
                    return self.fail(error.RestNotLast, "rest element must be last", rest.start);
                };
                break;
            }
            try elements.append(self.arena, try self.parseBindingElement());
            if (!self.match(.comma)) break;
        }
        const close = try self.eat(.r_bracket, "']'");
        return self.makeNode(open.start, close.end, .{
            .array_pattern = .{ .elements = try elements.toOwnedSlice(self.arena) },
        });
    }

    // objectPattern := '{' (patternProperty (',' patternProperty)*)? '}'
    fn parseObjectPattern(self: *Parser) ParseError!*ast.Node {
        const open = self.at().?; // '{'
        self.advance();
        var properties: std.ArrayList(*ast.Node) = .empty;
        while (self.at()) |t| {
            if (t.kind == .r_brace) break;
            if (t.kind == .dot_dot_dot) {
                const rest = try self.parseRestElement();
                try properties.append(self.arena, rest);
                if (self.at()) |n| if (n.kind == .comma) {
                    return self.fail(error.RestNotLast, "rest element must be last", rest.start);
                };
                break;
            }
            try properties.append(self.arena, try self.parseObjectPatternProperty());
            if (!self.match(.comma)) break;
        }
        const close = try self.eat(.r_brace, "'}'");
        return self.makeNode(open.start, close.end, .{
            .object_pattern = .{ .properties = try properties.toOwnedSlice(self.arena) },
        });
    }

    // patternProperty := '[' expr ']' ':' bindingElement       (computed)
    //                  | (identifier|string|number) ':' bindingElement
    //                  | identifier ('=' assignment)?          (shorthand, défaut optionnel)
    fn parseObjectPatternProperty(self: *Parser) ParseError!*ast.Node {
        const start_tok = self.at().?;

        if (start_tok.kind == .l_bracket) {
            self.advance();
            const key = try self.parseAssignment();
            try self.expect(.r_bracket, "']'");
            try self.expect(.colon, "':'");
            const value = try self.parseBindingElement();
            return self.makeNode(start_tok.start, value.end, .{
                .property = .{ .key = key, .value = value, .shorthand = false, .computed = true },
            });
        }

        const key: *ast.Node = switch (start_tok.kind) {
            .identifier => try self.identNode(start_tok),
            .string => try self.makeNode(start_tok.start, start_tok.end, .{ .string_literal = .{} }),
            .number => try self.makeNode(start_tok.start, start_tok.end, .{ .number_literal = .{} }),
            else => return self.failUnexpected(start_tok, "property key"),
        };
        self.advance();

        if (self.match(.colon)) {
            const value = try self.parseBindingElement();
            return self.makeNode(start_tok.start, value.end, .{
                .property = .{ .key = key, .value = value, .shorthand = false, .computed = false },
            });
        }

        // Shorthand : uniquement pour un identifiant.
        if (start_tok.kind != .identifier) return self.failUnexpected(self.at(), "':'");
        // `{ x = 1 }` : shorthand avec défaut -> value = AssignmentPattern.
        if (self.match(.eq)) {
            const default = try self.parseAssignment();
            const value = try self.makeNode(key.start, default.end, .{
                .assignment_pattern = .{ .left = key, .right = default },
            });
            return self.makeNode(start_tok.start, default.end, .{
                .property = .{ .key = key, .value = value, .shorthand = true, .computed = false },
            });
        }
        return self.makeNode(start_tok.start, start_tok.end, .{
            .property = .{ .key = key, .value = key, .shorthand = true, .computed = false },
        });
    }

    // ---- conversion expression -> pattern (cover grammar) ----
    // Choix : on CONSTRUIT de nouveaux nœuds pattern ; l'expression d'origine
    // est simplement abandonnée dans l'arena (pas de mutation, pas d'aliasing).

    fn toPattern(self: *Parser, node: *ast.Node) ParseError!*ast.Node {
        switch (node.kind) {
            // Cibles valides / nœuds déjà pattern (cover grammar `{ x = 1 }` produit
            // un assignment_pattern) : inchangés.
            .identifier, .member_expression, .assignment_pattern, .array_pattern, .object_pattern, .rest_element => return node,
            .array_expression => |arr| {
                const elements = try self.arena.alloc(?*ast.Node, arr.elements.len);
                for (arr.elements, 0..) |el, i| {
                    elements[i] = if (el) |e| try self.elementToPattern(e, i, arr.elements.len) else null;
                }
                return self.makeNode(node.start, node.end, .{ .array_pattern = .{ .elements = elements } });
            },
            .object_expression => |obj| {
                const properties = try self.arena.alloc(*ast.Node, obj.properties.len);
                for (obj.properties, 0..) |prop, i| {
                    properties[i] = try self.elementToPattern(prop, i, obj.properties.len);
                }
                return self.makeNode(node.start, node.end, .{ .object_pattern = .{ .properties = properties } });
            },
            // `a = 1` (op `=`) imbriqué -> défaut de pattern.
            .assignment_expression => |a| {
                if (a.operator != .assign) return self.fail(error.InvalidAssignmentTarget, "invalid assignment target", node.start);
                const left = try self.toPattern(a.target);
                return self.makeNode(node.start, node.end, .{ .assignment_pattern = .{ .left = left, .right = a.value } });
            },
            else => return self.fail(error.InvalidAssignmentTarget, "invalid assignment target", node.start),
        }
    }

    // Convertit un élément de tableau OU une propriété d'objet. `...x` -> rest
    // (doit être le dernier).
    fn elementToPattern(self: *Parser, node: *ast.Node, index: usize, len: usize) ParseError!*ast.Node {
        switch (node.kind) {
            .spread_element => |s| {
                if (index != len - 1) return self.fail(error.RestNotLast, "rest element must be last", node.start);
                const arg = try self.toPattern(s.argument);
                return self.makeNode(node.start, node.end, .{ .rest_element = .{ .argument = arg } });
            },
            .property => |p| {
                const value = try self.toPattern(p.value);
                return self.makeNode(node.start, node.end, .{
                    .property = .{ .key = p.key, .value = value, .shorthand = p.shorthand, .computed = p.computed },
                });
            },
            else => return self.toPattern(node),
        }
    }

    // ---- contexte for ----

    /// Consomme un identifiant contextuel (`of`, `from`, `as`…) s'il matche.
    fn matchContextual(self: *Parser, word: []const u8) bool {
        if (self.at()) |t| {
            if (t.kind == .identifier and std.mem.eql(u8, t.text(self.source), word)) {
                self.advance();
                return true;
            }
        }
        return false;
    }

    fn expectContextual(self: *Parser, word: []const u8, expected: []const u8) ParseError!void {
        if (!self.matchContextual(word)) return self.failUnexpected(self.at(), expected);
    }

    fn matchContextualOf(self: *Parser) bool {
        return self.matchContextual("of");
    }

    /// La cible d'un for-of/for-in : une déclaration reste telle quelle ; un
    /// littéral tableau/objet est converti en pattern.
    fn forTarget(self: *Parser, node: *ast.Node) ParseError!*ast.Node {
        return switch (node.kind) {
            .array_expression, .object_expression => try self.toPattern(node),
            else => node,
        };
    }

    // ---- template literals ----

    /// Un quasi : le texte brut entre délimiteurs. Le token couvre les
    /// délimiteurs ; on retire 1 à gauche (`` ` `` ou `}`) et 1 (`` ` ``) ou
    /// 2 (`${`) à droite.
    fn templateElement(self: *Parser, tok: lexer.Token, tail: bool) ParseError!*ast.Node {
        const right_strip: u32 = switch (tok.kind) {
            .template_head, .template_middle => 2,
            else => 1,
        };
        return self.makeNode(tok.start + 1, tok.end - right_strip, .{ .template_element = .{ .tail = tail } });
    }

    // templateLiteral := template_full
    //                  | template_head expr (template_middle expr)* template_tail
    // ---- JSX (opt-in) ----
    // Appelé depuis parsePrimary quand `self.jsx` et token courant = `<` (que le
    // lexer a déjà mis en mode « tag »). Grammaire d'EXPRESSIONS greffée sur JS :
    // `<div a="1">{x}</div>` est une expression au même titre qu'un appel.

    fn parseJSXElement(self: *Parser) ParseError!*ast.Node {
        const lt = self.at().?; // `<`
        const start = lt.start;
        self.advance();
        // Fragment `<>…</>` : `<` immédiatement suivi de `>`.
        if (self.atKind(.gt)) {
            self.advance(); // `>`
            const children = try self.parseJSXChildren();
            // Fermeture `</>` : `<` `/` `>`.
            try self.expectJSX(.lt, "'<'");
            self.expectRecover(.slash, "'/'");
            const gt = self.at();
            self.expectRecover(.gt, "'>'");
            const end: u32 = if (gt) |g| g.end else start;
            return self.makeNode(start, end, .{ .jsx_fragment = .{ .children = children } });
        }
        // Élément : nom + attributs.
        const name = try self.parseJSXElementName();
        const attrs = try self.parseJSXAttributes();
        var self_closing = false;
        if (self.atKind(.slash)) {
            self.advance();
            self_closing = true;
        }
        const gt_tok = self.at();
        self.expectRecover(.gt, "'>'");
        const open_end: u32 = if (gt_tok) |g| g.end else (if (self.pos > 0) self.tokens[self.pos - 1].end else start);
        const opening = try self.makeNode(start, open_end, .{ .jsx_opening_element = .{
            .name = name,
            .attributes = attrs,
            .self_closing = self_closing,
        } });
        if (self_closing) {
            return self.makeNode(start, open_end, .{ .jsx_element = .{ .opening = opening, .children = &.{}, .closing = null } });
        }
        // Enfants + balise fermante.
        const children = try self.parseJSXChildren();
        const closing = try self.parseJSXClosing(name);
        return self.makeNode(start, closing.end, .{ .jsx_element = .{ .opening = opening, .children = children, .closing = closing } });
    }

    /// `eat` version JSX : consomme le token attendu, sinon NOTE l'erreur et
    /// déroule (le panic mode récupère à la frontière de statement).
    fn expectJSX(self: *Parser, kind: TokenKind, expected: []const u8) ParseError!void {
        if (self.atKind(kind)) {
            self.advance();
            return;
        }
        return self.failUnexpected(self.at(), expected);
    }

    // name := jsxIdent (':' jsxIdent) | jsxIdent ('.' jsxIdent)*
    fn parseJSXElementName(self: *Parser) ParseError!*ast.Node {
        var name = try self.parseJSXIdentifier();
        if (self.atKind(.colon)) {
            self.advance();
            const rhs = try self.parseJSXIdentifier();
            return self.makeNode(name.start, rhs.end, .{ .jsx_namespaced_name = .{ .namespace = name, .name = rhs } });
        }
        while (self.atKind(.dot)) {
            self.advance();
            const prop = try self.parseJSXIdentifier();
            name = try self.makeNode(name.start, prop.end, .{ .jsx_member_expression = .{ .object = name, .property = prop } });
        }
        return name;
    }

    fn parseJSXIdentifier(self: *Parser) ParseError!*ast.Node {
        const t = self.at() orelse return self.failUnexpected(null, "JSX name");
        if (t.kind != .identifier) return self.failUnexpected(t, "JSX name");
        self.advance();
        return self.makeNode(t.start, t.end, .{ .jsx_identifier = .{ .synthetic_text = t.cooked } });
    }

    // attributes := (jsxAttribute | jsxSpreadAttribute)*  (jusqu'à `/` ou `>`)
    fn parseJSXAttributes(self: *Parser) ParseError![]*ast.Node {
        var list: std.ArrayList(*ast.Node) = .empty;
        while (self.at()) |t| {
            switch (t.kind) {
                .slash, .gt => break,
                .l_brace => try list.append(self.arena, try self.parseJSXSpreadAttribute()),
                .identifier => try list.append(self.arena, try self.parseJSXAttribute()),
                else => return self.failUnexpected(t, "JSX attribute"),
            }
        }
        return list.toOwnedSlice(self.arena);
    }

    // spreadAttribute := '{' '...' assignment '}'
    fn parseJSXSpreadAttribute(self: *Parser) ParseError!*ast.Node {
        const open = self.at().?; // `{`
        self.advance();
        try self.expectJSX(.dot_dot_dot, "'...'");
        const arg = try self.parseAssignment();
        const close = self.at();
        self.expectRecover(.r_brace, "'}'");
        const end: u32 = if (close) |c| c.end else arg.end;
        return self.makeNode(open.start, end, .{ .jsx_spread_attribute = .{ .argument = arg } });
    }

    // attribute := jsxAttrName ('=' attrValue)?
    fn parseJSXAttribute(self: *Parser) ParseError!*ast.Node {
        const name = try self.parseJSXAttributeName();
        var value: ?*ast.Node = null;
        var end = name.end;
        if (self.atKind(.eq)) {
            self.advance();
            const v = try self.parseJSXAttributeValue();
            value = v;
            end = v.end;
        }
        return self.makeNode(name.start, end, .{ .jsx_attribute = .{ .name = name, .value = value } });
    }

    // Nom d'attribut : identifiant, éventuellement namespacé (`xlink:href`).
    fn parseJSXAttributeName(self: *Parser) ParseError!*ast.Node {
        const name = try self.parseJSXIdentifier();
        if (self.atKind(.colon)) {
            self.advance();
            const rhs = try self.parseJSXIdentifier();
            return self.makeNode(name.start, rhs.end, .{ .jsx_namespaced_name = .{ .namespace = name, .name = rhs } });
        }
        return name;
    }

    // attrValue := string | '{' assignment '}' | jsxElement
    fn parseJSXAttributeValue(self: *Parser) ParseError!*ast.Node {
        const t = self.at() orelse return self.failUnexpected(null, "attribute value");
        switch (t.kind) {
            .string => {
                self.advance();
                return self.makeNode(t.start, t.end, .{ .string_literal = .{} });
            },
            .l_brace => return self.parseJSXExpressionContainer(),
            .lt => return self.parseJSXElement(),
            else => return self.failUnexpected(t, "attribute value"),
        }
    }

    // children := (jsxText | jsxExpressionContainer | jsxElement)*
    // S'arrête sur la balise fermante (`</`).
    fn parseJSXChildren(self: *Parser) ParseError![]*ast.Node {
        var list: std.ArrayList(*ast.Node) = .empty;
        while (self.at()) |t| {
            switch (t.kind) {
                .jsx_text => {
                    self.advance();
                    try list.append(self.arena, try self.makeNode(t.start, t.end, .jsx_text));
                },
                .l_brace => try list.append(self.arena, try self.parseJSXExpressionContainer()),
                .lt => {
                    if (self.kindAt(1) == .slash) break; // balise fermante -> fin des enfants
                    try list.append(self.arena, try self.parseJSXElement());
                },
                else => break,
            }
        }
        return list.toOwnedSlice(self.arena);
    }

    // container := '{' assignment? '}'   ('{}' et '{/* c */}' = expression null, légal)
    fn parseJSXExpressionContainer(self: *Parser) ParseError!*ast.Node {
        const open = self.at().?; // `{`
        self.advance();
        if (self.atKind(.r_brace)) {
            const close = self.at().?;
            self.advance();
            return self.makeNode(open.start, close.end, .{ .jsx_expression_container = .{ .expression = null } });
        }
        const expr = try self.parseAssignment();
        const close = self.at();
        self.expectRecover(.r_brace, "'}'");
        const end: u32 = if (close) |c| c.end else expr.end;
        return self.makeNode(open.start, end, .{ .jsx_expression_container = .{ .expression = expr } });
    }

    // closing := '<' '/' name '>' ; le nom doit matcher l'ouvrant (sinon diagnostic
    // avec les DEUX spans).
    fn parseJSXClosing(self: *Parser, opening_name: *ast.Node) ParseError!*ast.Node {
        const lt = self.at() orelse return self.failUnexpected(null, "closing tag");
        const start = lt.start;
        try self.expectJSX(.lt, "'<'");
        self.expectRecover(.slash, "'/'");
        const name = try self.parseJSXElementName();
        // Matching des noms ouvrant/fermant.
        const on = opening_name.text(self.source);
        const cn = name.text(self.source);
        if (!std.mem.eql(u8, on, cn)) {
            self.recordError(std.fmt.allocPrint(self.arena, "closing tag </{s}> does not match opening <{s}>", .{ cn, on }) catch "JSX tag mismatch", name.start);
        }
        const gt = self.at();
        self.expectRecover(.gt, "'>'");
        const end: u32 = if (gt) |g| g.end else name.end;
        return self.makeNode(start, end, .{ .jsx_closing_element = .{ .name = name } });
    }

    // ================= TypeScript (opt-in, phase 1) =================
    // Sous-grammaire des TYPES : un petit Pratt. Précédence : `[]` (postfix) >
    // `&` (intersection) > `|` (union) ; `=>` à droite. Les types sont un monde à
    // part : le semantic les ignore (isTypeNode), stripTypes les efface.

    /// Une annotation `?` optionnelle (params/champs) : consomme le `?` (ts only).
    fn tsOptional(self: *Parser) bool {
        return self.ts and self.match(.question);
    }
    /// Une annotation `: Type` optionnelle. Renvoie le type, ou null.
    fn tsTypeAnnotation(self: *Parser) ParseError!?*ast.Node {
        if (self.ts and self.match(.colon)) return try self.parseType();
        return null;
    }
    /// Enveloppe un binding dans `ts_typed` s'il porte un `?` ou une annotation.
    fn wrapTyped(self: *Parser, binding: *ast.Node, optional: bool, ann: ?*ast.Node) ParseError!*ast.Node {
        if (!optional and ann == null) return binding;
        const end = if (ann) |a| a.end else binding.end;
        return self.makeNode(binding.start, end, .{ .ts_typed = .{ .binding = binding, .type_annotation = ann, .optional = optional } });
    }

    /// Vrai si le token courant ferme des arguments de type (`>`, ou un `>` virtuel
    /// en attente, ou un `>>`/`>>>` dont le 1er `>` fermerait ici).
    fn atTypeGt(self: *const Parser) bool {
        if (self.pending_gt > 0) return true;
        if (self.at()) |t| return switch (t.kind) {
            .gt, .shr, .ushr, .gt_eq, .shr_eq, .ushr_eq => true,
            else => false,
        };
        return false;
    }
    /// Consomme un `>` fermant (re-découpe `>>`/`>>>`/`>=` en contexte type).
    fn eatTypeGt(self: *Parser) ParseError!void {
        if (self.pending_gt > 0) {
            self.pending_gt -= 1;
            return;
        }
        const t = self.at() orelse return self.failUnexpected(null, "'>'");
        switch (t.kind) {
            .gt => self.advance(),
            .shr => {
                self.advance();
                self.pending_gt += 1;
            }, // >> = ce `>` + 1 en attente
            .ushr => {
                self.advance();
                self.pending_gt += 2;
            }, // >>>
            .gt_eq => {
                self.advance(); // >= : rare en type ; on considère le `>` consommé
            },
            else => return self.failUnexpected(t, "'>'"),
        }
    }

    /// `< Type (, Type)* >` : arguments de type (`Array<T>`, `Map<K, V>`).
    fn parseTypeArgs(self: *Parser) ParseError![]*ast.Node {
        self.advance(); // '<'
        var args: std.ArrayList(*ast.Node) = .empty;
        if (!self.atTypeGt()) {
            while (true) {
                try args.append(self.arena, try self.parseType());
                if (!self.match(.comma)) break;
                if (self.atTypeGt()) break; // virgule finale
            }
        }
        try self.eatTypeGt();
        return args.toOwnedSlice(self.arena);
    }

    /// `< T (extends C)? (= D)? , … >` : paramètres de type d'une déclaration.
    fn parseTypeParams(self: *Parser) ParseError![]*ast.Node {
        self.advance(); // '<'
        var list: std.ArrayList(*ast.Node) = .empty;
        if (!self.atTypeGt()) {
            while (true) {
                const name_tok = try self.eat(.identifier, "type parameter");
                const name = try self.identNode(name_tok);
                var constraint: ?*ast.Node = null;
                var default: ?*ast.Node = null;
                if (self.match(.kw_extends)) constraint = try self.parseType();
                if (self.match(.eq)) default = try self.parseType();
                try list.append(self.arena, try self.makeNode(name.start, name.end, .{
                    .ts_type_parameter = .{ .name = name, .constraint = constraint, .default = default },
                }));
                if (!self.match(.comma)) break;
                if (self.atTypeGt()) break;
            }
        }
        try self.eatTypeGt();
        return list.toOwnedSlice(self.arena);
    }

    /// Paramètres de type optionnels après un nom (fonction/méthode/type/interface).
    fn tsTypeParamsOpt(self: *Parser) ParseError![]*ast.Node {
        if (self.ts and self.atKind(.lt)) return self.parseTypeParams();
        return &.{};
    }

    // type := union
    fn parseType(self: *Parser) ParseError!*ast.Node {
        return self.parseTypeUnion();
    }

    fn parseTypeUnion(self: *Parser) ParseError!*ast.Node {
        _ = self.match(.pipe); // `|` de tête optionnel
        const first = try self.parseTypeIntersection();
        if (!self.atKind(.pipe)) return first;
        var types: std.ArrayList(*ast.Node) = .empty;
        try types.append(self.arena, first);
        while (self.match(.pipe)) try types.append(self.arena, try self.parseTypeIntersection());
        const items = try types.toOwnedSlice(self.arena);
        return self.makeNode(items[0].start, items[items.len - 1].end, .{ .ts_union_type = .{ .types = items } });
    }

    fn parseTypeIntersection(self: *Parser) ParseError!*ast.Node {
        _ = self.match(.amp); // `&` de tête optionnel
        const first = try self.parseTypePostfix();
        if (!self.atKind(.amp)) return first;
        var types: std.ArrayList(*ast.Node) = .empty;
        try types.append(self.arena, first);
        while (self.match(.amp)) try types.append(self.arena, try self.parseTypePostfix());
        const items = try types.toOwnedSlice(self.arena);
        return self.makeNode(items[0].start, items[items.len - 1].end, .{ .ts_intersection_type = .{ .types = items } });
    }

    // postfix : `T[]` (tableau) et `T[K]` (accès indexé, TS phase 2).
    fn parseTypePostfix(self: *Parser) ParseError!*ast.Node {
        var t = try self.parseTypePrimary();
        while (self.atKind(.l_bracket)) {
            self.advance(); // '['
            if (self.atKind(.r_bracket)) { // `T[]` : tableau
                const close = self.at().?;
                self.advance();
                t = try self.makeNode(t.start, close.end, .{ .ts_array_type = .{ .element = t } });
            } else { // `T[K]` : accès indexé
                const index = try self.parseType();
                const close = try self.eat(.r_bracket, "']'");
                t = try self.makeNode(t.start, close.end, .{ .ts_indexed_access_type = .{ .object = t, .index = index } });
            }
        }
        return t;
    }

    fn parseTypePrimary(self: *Parser) ParseError!*ast.Node {
        const tok = self.at() orelse return self.failUnexpected(null, "type");
        switch (tok.kind) {
            .l_paren => return self.parseFunctionOrParenType(),
            .l_bracket => return self.parseTupleType(),
            .l_brace => return self.parseTypeLiteral(),
            .kw_typeof => {
                self.advance();
                const e = try self.parseTypeEntityName(); // `typeof x.y` (référence de valeur)
                return self.makeNode(tok.start, e.end, .{ .ts_typeof_type = .{ .expr = e } });
            },
            .kw_void, .kw_null, .kw_this => { // `void`/`null`/`this` (polymorphic this) en type
                self.advance();
                return self.makeNode(tok.start, tok.end, .ts_keyword_type);
            },
            .kw_true, .kw_false => {
                self.advance();
                const lit = try self.makeNode(tok.start, tok.end, .{ .boolean_literal = .{} });
                return self.makeNode(tok.start, tok.end, .{ .ts_literal_type = .{ .literal = lit } });
            },
            .string => {
                self.advance();
                const lit = try self.makeNode(tok.start, tok.end, .{ .string_literal = .{} });
                return self.makeNode(tok.start, tok.end, .{ .ts_literal_type = .{ .literal = lit } });
            },
            .number, .bigint => {
                self.advance();
                const lit = try self.makeNode(tok.start, tok.end, if (tok.kind == .bigint) .bigint_literal else .{ .number_literal = .{} });
                return self.makeNode(tok.start, tok.end, .{ .ts_literal_type = .{ .literal = lit } });
            },
            .minus => { // littéral négatif `-1` en type
                self.advance();
                const num = try self.eat(.number, "number literal");
                const lit = try self.makeNode(tok.start, num.end, .{ .number_literal = .{} });
                return self.makeNode(tok.start, num.end, .{ .ts_literal_type = .{ .literal = lit } });
            },
            .identifier => {
                const text = tok.text(self.source);
                if (isTsPrimitiveKeyword(text)) {
                    self.advance();
                    return self.makeNode(tok.start, tok.end, .ts_keyword_type);
                }
                if (std.mem.eql(u8, text, "keyof")) {
                    self.advance();
                    const t = try self.parseTypePostfix();
                    return self.makeNode(tok.start, t.end, .{ .ts_keyof_type = .{ .@"type" = t } });
                }
                if (std.mem.eql(u8, text, "readonly")) {
                    // Modifieur `readonly T[]`/`readonly [..]` : effacé, on parse le type.
                    self.advance();
                    return self.parseTypePostfix();
                }
                return self.parseTypeReference();
            },
            else => return self.failUnexpected(tok, "type"),
        }
    }

    /// Nom en position de type : `Foo`, `Foo.Bar`, avec `<args>` optionnels.
    fn parseTypeReference(self: *Parser) ParseError!*ast.Node {
        const name = try self.parseTypeEntityName();
        var end = name.end;
        var args: []*ast.Node = &.{};
        if (self.atKind(.lt)) {
            args = try self.parseTypeArgs();
            end = if (self.pos > 0) self.tokens[self.pos - 1].end else name.end;
        }
        return self.makeNode(name.start, end, .{ .ts_type_reference = .{ .name = name, .type_args = args } });
    }

    /// `Foo` ou `Foo.Bar.Baz` (qualified name) : identifiants + `.` (pas de `<>`).
    fn parseTypeEntityName(self: *Parser) ParseError!*ast.Node {
        const first = try self.eat(.identifier, "type name");
        var name = try self.identNode(first);
        while (self.match(.dot)) {
            const right_tok = try self.eat(.identifier, "type name");
            const right = try self.identNode(right_tok);
            name = try self.makeNode(name.start, right.end, .{ .ts_qualified_name = .{ .left = name, .right = right } });
        }
        return name;
    }

    /// `(T)` ou `(a: A) => B` : fonction si la `)` correspondante est suivie de `=>`.
    fn parseFunctionOrParenType(self: *Parser) ParseError!*ast.Node {
        const start = self.at().?.start;
        if (self.arrowAhead()) {
            const params = try self.parseParams(); // mêmes params typés qu'une fonction
            try self.expect(.arrow, "'=>'");
            const ret = try self.parseType();
            return self.makeNode(start, ret.end, .{ .ts_function_type = .{ .params = params, .return_type = ret } });
        }
        self.advance(); // '('
        const t = try self.parseType();
        const close = try self.eat(.r_paren, "')'");
        return self.makeNode(start, close.end, .{ .ts_parenthesized_type = .{ .@"type" = t } });
    }

    // `[A, B, ...C[]]` : tuple. Membres nommés (`[x: T]`) HORS phase 1 (documenté).
    fn parseTupleType(self: *Parser) ParseError!*ast.Node {
        const open = self.at().?; // '['
        self.advance();
        var elems: std.ArrayList(*ast.Node) = .empty;
        while (self.at()) |t| {
            if (t.kind == .r_bracket) break;
            if (t.kind == .dot_dot_dot) {
                self.advance();
                const rt = try self.parseType();
                try elems.append(self.arena, try self.makeNode(t.start, rt.end, .{ .ts_rest_type = .{ .@"type" = rt } }));
            } else {
                try elems.append(self.arena, try self.parseType());
            }
            if (!self.match(.comma)) break;
        }
        const close = try self.eat(.r_bracket, "']'");
        return self.makeNode(open.start, close.end, .{ .ts_tuple_type = .{ .elements = try elems.toOwnedSlice(self.arena) } });
    }

    // `{ a: T; b?: U; m(x): R }` : type objet.
    fn parseTypeLiteral(self: *Parser) ParseError!*ast.Node {
        const open = self.at().?; // '{'
        self.advance();
        var members: std.ArrayList(*ast.Node) = .empty;
        while (self.at()) |t| {
            if (t.kind == .r_brace) break;
            try members.append(self.arena, try self.parseTypeMember());
            _ = self.match(.semicolon) or self.match(.comma); // séparateur optionnel
        }
        const close = try self.eat(.r_brace, "'}'");
        return self.makeNode(open.start, close.end, .{ .ts_type_literal = .{ .members = try members.toOwnedSlice(self.arena) } });
    }

    /// Membre d'un type objet / d'une interface : signature d'index / propriété / méthode.
    fn parseTypeMember(self: *Parser) ParseError!*ast.Node {
        const start = self.at().?.start;
        var readonly = false;
        if (self.isContextualModifier("readonly")) {
            self.advance();
            readonly = true;
        }
        // Signature d'index `[k: string]: T` (TS phase 2) : `[` ident `:` type `]` `:` type.
        if (self.atKind(.l_bracket) and self.kindAt(1) == .identifier and self.kindAt(2) == .colon) {
            self.advance(); // '['
            const key_tok = self.at().?;
            const key = try self.identNode(key_tok);
            self.advance(); // nom de la clé
            self.advance(); // ':'
            const key_type = try self.parseType();
            try self.expect(.r_bracket, "']'");
            try self.expect(.colon, "':'");
            const value_type = try self.parseType();
            return self.makeNode(start, value_type.end, .{ .ts_index_signature = .{ .key = key, .key_type = key_type, .value_type = value_type, .readonly = readonly } });
        }
        var computed = false;
        const key = try self.parseTypeMemberKey(&computed);
        const optional = self.match(.question);
        if (self.atKind(.l_paren)) {
            const params = try self.parseParams();
            const ret = try self.tsTypeAnnotation();
            const end = if (ret) |r| r.end else (if (self.pos > 0) self.tokens[self.pos - 1].end else key.end);
            return self.makeNode(start, end, .{ .ts_method_signature = .{ .key = key, .params = params, .return_type = ret, .optional = optional, .computed = computed } });
        }
        const ann = try self.tsTypeAnnotation();
        const end = if (ann) |a| a.end else key.end;
        return self.makeNode(start, end, .{ .ts_property_signature = .{ .key = key, .type_annotation = ann, .optional = optional, .readonly = readonly, .computed = computed } });
    }

    fn parseTypeMemberKey(self: *Parser, computed: *bool) ParseError!*ast.Node {
        const t = self.at() orelse return self.failUnexpected(null, "member name");
        if (t.kind == .l_bracket) {
            self.advance();
            const e = try self.parseAssignment();
            try self.expect(.r_bracket, "']'");
            computed.* = true;
            return e;
        }
        if (t.kind == .string or t.kind == .number) {
            self.advance();
            return self.makeNode(t.start, t.end, if (t.kind == .string) .{ .string_literal = .{} } else .{ .number_literal = .{} });
        }
        if (t.kind != .identifier and !isKeyword(t.kind)) return self.failUnexpected(t, "member name");
        self.advance();
        return self.identNode(t);
    }

    // ---- déclarations type-only ----

    fn parseTypeAlias(self: *Parser) ParseError!*ast.Node {
        const kw = self.at().?; // 'type'
        self.advance();
        const id_tok = try self.eat(.identifier, "type name");
        const id = try self.identNode(id_tok);
        const tps = try self.tsTypeParamsOpt();
        try self.expect(.eq, "'='");
        const t = try self.parseType();
        try self.consumeSemicolon();
        return self.makeNode(kw.start, t.end, .{ .ts_type_alias = .{ .id = id, .type_params = tps, .@"type" = t } });
    }

    fn parseInterface(self: *Parser) ParseError!*ast.Node {
        const kw = self.at().?; // 'interface'
        self.advance();
        const id_tok = try self.eat(.identifier, "interface name");
        const id = try self.identNode(id_tok);
        const tps = try self.tsTypeParamsOpt();
        var ext: std.ArrayList(*ast.Node) = .empty;
        if (self.match(.kw_extends)) {
            while (true) {
                try ext.append(self.arena, try self.parseTypeReference());
                if (!self.match(.comma)) break;
            }
        }
        try self.expect(.l_brace, "'{'");
        var body: std.ArrayList(*ast.Node) = .empty;
        while (self.at()) |t| {
            if (t.kind == .r_brace) break;
            try body.append(self.arena, try self.parseTypeMember());
            _ = self.match(.semicolon) or self.match(.comma);
        }
        const close = try self.eat(.r_brace, "'}'");
        return self.makeNode(kw.start, close.end, .{ .ts_interface = .{
            .id = id,
            .type_params = tps,
            .extends = try ext.toOwnedSlice(self.arena),
            .body = try body.toOwnedSlice(self.arena),
        } });
    }

    /// `interface`/`type` en tête de statement (identifiants contextuels).
    fn atTsTypeAlias(self: *const Parser) bool {
        if (!self.ts) return false;
        const t = self.at() orelse return false;
        if (!self.tokenTextIs(t, "type")) return false;
        // `type A = …` ou `type A<…> = …` (sinon `type` est un simple identifiant).
        return self.kindAt(1) == .identifier and (self.kindAt(2) == .eq or self.kindAt(2) == .lt);
    }
    fn atTsInterface(self: *const Parser) bool {
        if (!self.ts) return false;
        const t = self.at() orelse return false;
        return self.tokenTextIs(t, "interface") and self.kindAt(1) == .identifier;
    }
    /// Le token à `pos+1` est-il l'identifiant `word` ? (ex. `const enum`).
    fn kindAt2Is(self: *const Parser, word: []const u8) bool {
        if (self.pos + 1 >= self.tokens.len) return false;
        return self.tokenTextIs(self.tokens[self.pos + 1], word);
    }
    fn atTsEnum(self: *const Parser) bool {
        if (!self.ts) return false;
        const t = self.at() orelse return false;
        return self.tokenTextIs(t, "enum") and self.kindAt(1) == .identifier;
    }
    fn atTsNamespace(self: *const Parser) bool {
        if (!self.ts) return false;
        const t = self.at() orelse return false;
        return (self.tokenTextIs(t, "namespace") or self.tokenTextIs(t, "module")) and self.kindAt(1) == .identifier;
    }

    // ---- TS phase 3 : enum / namespace ----

    // enum E { A, B = 5, C }   (const enum : is_const)
    fn parseEnum(self: *Parser, is_const: bool) ParseError!*ast.Node {
        const start = self.at().?.start;
        self.advance(); // 'enum'
        const id = try self.identNode(try self.eat(.identifier, "enum name"));
        try self.expect(.l_brace, "'{'");
        var members: std.ArrayList(*ast.Node) = .empty;
        var prev_was_string = false;
        while (self.at()) |t| {
            if (t.kind == .r_brace) break;
            const name = try self.parseEnumMemberName();
            var initializer: ?*ast.Node = null;
            if (self.match(.eq)) initializer = try self.parseAssignment();
            // Règle tsc : un membre SANS valeur après un membre string = erreur
            // (l'auto-incrément ne reprend qu'après un membre numérique constant).
            if (initializer == null and prev_was_string) {
                self.recordError("enum member must have initializer after a string member", name.start);
            }
            prev_was_string = if (initializer) |i| i.kind == .string_literal else false;
            try members.append(self.arena, try self.makeNode(name.start, if (initializer) |i| i.end else name.end, .{
                .ts_enum_member = .{ .name = name, .initializer = initializer },
            }));
            if (!self.match(.comma)) break;
        }
        const close = try self.eat(.r_brace, "'}'");
        return self.makeNode(start, close.end, .{ .ts_enum = .{ .id = id, .members = try members.toOwnedSlice(self.arena), .is_const = is_const } });
    }

    // Nom de membre d'enum : identifiant, mot réservé, ou string (`{ "a-b" = 1 }`).
    fn parseEnumMemberName(self: *Parser) ParseError!*ast.Node {
        const t = self.at() orelse return self.failUnexpected(null, "enum member");
        if (t.kind == .string) {
            self.advance();
            return self.makeNode(t.start, t.end, .{ .string_literal = .{} });
        }
        if (t.kind != .identifier and !isKeyword(t.kind)) return self.failUnexpected(t, "enum member");
        self.advance();
        return self.identNode(t);
    }

    // namespace N { … } / module N { … }  (name simple ; qualifié `A.B` = diag au strip)
    fn parseNamespace(self: *Parser) ParseError!*ast.Node {
        const start = self.at().?.start;
        self.advance(); // 'namespace' / 'module'
        var id = try self.identNode(try self.eat(.identifier, "namespace name"));
        if (self.atKind(.dot)) self.recordError("qualified namespace (A.B) is not supported", id.start);
        while (self.match(.dot)) { // `namespace A.B` (qualifié) : non supporté
            const right = try self.identNode(try self.eat(.identifier, "namespace name"));
            id = try self.makeNode(id.start, right.end, .{ .member_expression = .{ .object = id, .property = right, .computed = false, .optional = false } });
        }
        try self.expect(.l_brace, "'{'");
        var body: std.ArrayList(*ast.Node) = .empty;
        while (self.at()) |t| {
            if (t.kind == .r_brace) break;
            const before = self.pos;
            const stmt = self.parseModuleItem() catch {
                try body.append(self.arena, try self.recoverStmt(before, t.start));
                continue;
            };
            // Namespace imbriqué ou exporté imbriqué : non supporté (phase 3).
            const inner = if (stmt.kind == .export_named_declaration) stmt.kind.export_named_declaration.declaration else stmt;
            if (inner != null and inner.?.kind == .ts_namespace) {
                self.recordError("nested namespace is not supported", stmt.start);
            }
            try body.append(self.arena, stmt);
            if (self.pos == before) self.advance(); // garde-fou anti-boucle
        }
        const close = try self.eat(.r_brace, "'}'");
        return self.makeNode(start, close.end, .{ .ts_namespace = .{ .id = id, .body = try body.toOwnedSlice(self.arena) } });
    }

    /// Un identifiant contextuel (`readonly`, modifieurs de classe) suivi de qqch
    /// qui continue un membre (une clé, un `?`, un autre modifieur) → modifieur.
    fn isContextualModifier(self: *const Parser, word: []const u8) bool {
        const t = self.at() orelse return false;
        if (t.kind != .identifier or !std.mem.eql(u8, t.text(self.source), word)) return false;
        const next = self.kindAt(1) orelse return false;
        return keyStart(next) or next == .question or next == .star;
    }

    fn parseTemplateLiteral(self: *Parser) ParseError!*ast.Node {
        const first = self.at().?;
        var quasis: std.ArrayList(*ast.Node) = .empty;
        var expressions: std.ArrayList(*ast.Node) = .empty;

        if (first.kind == .template_full) {
            self.advance();
            try quasis.append(self.arena, try self.templateElement(first, true));
            return self.makeNode(first.start, first.end, .{ .template_literal = .{
                .quasis = try quasis.toOwnedSlice(self.arena),
                .expressions = try expressions.toOwnedSlice(self.arena),
            } });
        }

        // template_head
        try quasis.append(self.arena, try self.templateElement(first, false));
        self.advance();
        var end = first.end;
        while (true) {
            try expressions.append(self.arena, try self.parseExpr());
            const cont = self.at() orelse return self.failUnexpected(null, "template continuation");
            switch (cont.kind) {
                .template_middle => {
                    try quasis.append(self.arena, try self.templateElement(cont, false));
                    self.advance();
                },
                .template_tail => {
                    try quasis.append(self.arena, try self.templateElement(cont, true));
                    self.advance();
                    end = cont.end;
                    break;
                },
                else => return self.failUnexpected(cont, "template continuation"),
            }
        }
        return self.makeNode(first.start, end, .{ .template_literal = .{
            .quasis = try quasis.toOwnedSlice(self.arena),
            .expressions = try expressions.toOwnedSlice(self.arena),
        } });
    }

    // ---- new ----

    // new := 'new' callee arguments?
    //   callee = primary + (. | []) *   (PAS d'appel : les '()' sont au `new`)
    fn parseNew(self: *Parser) ParseError!*ast.Node {
        const kw = self.at().?; // 'new'
        self.advance();

        var callee = try self.parsePrimary();
        while (self.at()) |tok| {
            switch (tok.kind) {
                .dot => {
                    self.advance();
                    callee = try self.member(callee, try self.propertyName(), false, false);
                },
                .l_bracket => callee = try self.computedMember(callee, false),
                else => break,
            }
        }

        // TS phase 2 : `new Foo<T>(x)` — spéculation d'arguments de type, mais
        // générique SEULEMENT si un `(` suit (sinon `new Foo < T` = comparaison).
        var type_args: []*ast.Node = &.{};
        if (self.ts and self.atKind(.lt)) {
            const saved_pos = self.pos;
            const saved_gt = self.pending_gt;
            const saved_errs = self.errors.items.len;
            if (self.parseTypeArgs()) |ta| {
                if (self.atKind(.l_paren)) type_args = ta else self.rewindSpec(saved_pos, saved_gt, saved_errs);
            } else |_| self.rewindSpec(saved_pos, saved_gt, saved_errs);
        }

        // Arguments optionnels : `new Foo` (sans parens) est valide.
        var arguments = try self.arena.alloc(*ast.Node, 0);
        var end = callee.end;
        if (self.at()) |t| {
            if (t.kind == .l_paren) {
                const al = try self.parseArgList();
                arguments = al.args;
                end = al.end;
            }
        }
        return self.makeNode(kw.start, end, .{ .new_expression = .{ .callee = callee, .arguments = arguments, .type_args = type_args } });
    }

    // ---- classes ----

    fn parseClass(self: *Parser, is_declaration: bool) ParseError!*ast.Node {
        const kw = self.at().?; // 'class'
        self.advance();

        var id: ?*ast.Node = null;
        if (self.at()) |t| if (t.kind == .identifier) {
            id = try self.identNode(t);
            self.advance();
        };
        const type_params = try self.tsTypeParamsOpt(); // `class C<T>` (TS)

        var superclass: ?*ast.Node = null;
        var super_type_args: []*ast.Node = &.{};
        if (self.match(.kw_extends)) {
            // LeftHandSideExpression : `extends B`, `extends a.b`, `extends f()`.
            superclass = try self.parsePostfix();
            if (self.ts and self.atKind(.lt)) super_type_args = try self.parseTypeArgs(); // `extends B<U>`
        }
        // TS : `implements I, J` (clause effacée) — `implements` est contextuel.
        var impls: std.ArrayList(*ast.Node) = .empty;
        if (self.ts and self.at() != null and self.tokenTextIs(self.at().?, "implements")) {
            self.advance();
            while (true) {
                try impls.append(self.arena, try self.parseTypeReference());
                if (!self.match(.comma)) break;
            }
        }

        const body = try self.parseClassBody();
        const c = ast.Node.Class{ .id = id, .superclass = superclass, .body = body, .type_params = type_params, .super_type_args = super_type_args, .implements = try impls.toOwnedSlice(self.arena) };
        return self.makeNode(kw.start, body.end, if (is_declaration)
            .{ .class_declaration = c }
        else
            .{ .class_expression = c });
    }

    fn parseClassBody(self: *Parser) ParseError!*ast.Node {
        const open = try self.eat(.l_brace, "'{'");
        var members: std.ArrayList(*ast.Node) = .empty;
        while (self.at()) |t| {
            if (t.kind == .r_brace) break;
            if (t.kind == .semicolon) {
                self.advance(); // ';' entre membres toléré (et en trop)
                continue;
            }
            const before = self.pos;
            const mbr = self.parseClassMember() catch {
                // Membre raté -> error_node, la classe survit (error recovery).
                try members.append(self.arena, try self.recoverStmt(before, t.start));
                continue;
            };
            try members.append(self.arena, mbr);
            if (self.pos == before) self.advance(); // garde-fou
        }
        var end: u32 = if (self.pos > 0) self.tokens[self.pos - 1].end else open.end;
        if (self.atKind(.r_brace)) {
            end = self.at().?.end;
            self.advance();
        } else {
            self.recordError("expected '}'", end);
        }
        return self.makeNode(open.start, end, .{ .class_body = .{ .members = try members.toOwnedSlice(self.arena) } });
    }

    // member := 'static'? (get|set)? key ( '(' params ')' block   (méthode)
    //                                    | ('=' assignment)? ';'? )  (champ)
    fn parseClassMember(self: *Parser) ParseError!*ast.Node {
        const start = self.at().?.start;

        // TS : modifieurs d'accès de membre (`public`/`private`/`protected`/
        // `readonly`/`override`) — EFFACÉS (phase 1 ; `abstract`/`declare` HORS
        // phase 1). Modifieur seulement s'il précède une clé / un autre modifieur.
        while (self.ts and self.isMemberModifier()) self.advance();

        var is_static = false;
        if (self.isStaticModifier()) {
            self.advance();
            is_static = true;
        }
        while (self.ts and self.isMemberModifier()) self.advance(); // `static readonly …`

        // Modifieurs de méthode : `async` (contextuel, seulement s'il est suivi
        // d'une clé ou de `*`) puis `*` (generator).
        var is_async = false;
        var is_generator = false;
        if (self.isAsyncMethodModifier()) {
            self.advance();
            is_async = true;
        }
        if (self.match(.star)) is_generator = true;

        var mkind: ast.MethodKind = .method;
        // get/set : accesseurs seulement, jamais async/generator.
        if (!is_async and !is_generator) {
            if (self.isContextual("get")) {
                self.advance();
                mkind = .getter;
            } else if (self.isContextual("set")) {
                self.advance();
                mkind = .setter;
            }
        }

        var computed = false;
        const key = try self.parseClassKey(&computed);
        const optional = self.tsOptional(); // `x?` / `m?()`
        if (self.ts and !optional) _ = self.match(.bang); // `x!: T` (definite assignment)

        // Méthode ? (`(` ou, en TS, `<T>(` — méthode générique).
        if (self.atKind(.l_paren) or (self.ts and self.atKind(.lt))) {
            const type_params = try self.tsTypeParamsOpt();
            const params = try self.parseParams();
            const return_type = try self.tsTypeAnnotation();
            const body = try self.parseFunctionBody(is_async, is_generator);
            var final_kind = mkind;
            if (mkind == .method and !is_static and !computed and self.keyNamed(key, "constructor")) final_kind = .constructor;
            return self.makeNode(start, body.end, .{ .method_definition = .{
                .key = key,
                .params = params,
                .body = body,
                .kind = final_kind,
                .static = is_static,
                .computed = computed,
                .is_async = is_async,
                .is_generator = is_generator,
                .return_type = return_type,
                .type_params = type_params,
            } });
        }

        // Champ (class field) : `x: T`, `x?: T`, `x = v`.
        const type_annotation = try self.tsTypeAnnotation();
        var value: ?*ast.Node = null;
        var end = if (type_annotation) |ta| ta.end else key.end;
        if (self.match(.eq)) {
            const v = try self.parseAssignment();
            value = v;
            end = v.end;
        }
        try self.consumeSemicolon();
        return self.makeNode(start, end, .{ .property_definition = .{
            .key = key,
            .value = value,
            .static = is_static,
            .computed = computed,
            .type_annotation = type_annotation,
            .optional = optional,
        } });
    }

    /// Modifieur d'accès de membre de classe (TS) : `public`/`private`/`protected`/
    /// `readonly`/`override`, seulement s'il précède une clé / un autre modifieur.
    fn isMemberModifier(self: *const Parser) bool {
        const t = self.at() orelse return false;
        if (t.kind != .identifier) return false;
        const text = t.text(self.source);
        const mods = [_][]const u8{ "public", "private", "protected", "readonly", "override" };
        var is_mod = false;
        for (mods) |m| if (std.mem.eql(u8, text, m)) {
            is_mod = true;
        };
        if (!is_mod) return false;
        const next = self.kindAt(1) orelse return false;
        return keyStart(next) or next == .kw_static or (next == .identifier);
    }

    // `static` est un modifieur seulement s'il est suivi d'une clé.
    fn isStaticModifier(self: *const Parser) bool {
        if (self.at()) |t| {
            if (t.kind == .kw_static) {
                if (self.kindAt(1)) |next| return keyStart(next);
            }
        }
        return false;
    }

    // `get`/`set` (identifiants contextuels) : accesseur seulement si suivi d'une clé.
    fn isContextual(self: *const Parser, word: []const u8) bool {
        if (self.at()) |t| {
            if (t.kind == .identifier and std.mem.eql(u8, t.text(self.source), word)) {
                if (self.kindAt(1)) |next| return keyStart(next);
            }
        }
        return false;
    }

    // `async` est un modifieur de méthode seulement s'il est suivi d'une clé ou
    // d'un `*` (generator). Suivi de `(`, c'est une méthode NOMMÉE `async`.
    fn isAsyncMethodModifier(self: *const Parser) bool {
        if (self.at()) |t| {
            if (self.tokenTextIs(t, "async")) {
                if (self.kindAt(1)) |next| return keyStart(next) or next == .star;
            }
        }
        return false;
    }

    fn parseClassKey(self: *Parser, computed: *bool) ParseError!*ast.Node {
        const tok = self.at() orelse return self.failUnexpected(null, "class member name");
        switch (tok.kind) {
            .l_bracket => {
                computed.* = true;
                self.advance();
                const key = try self.parseAssignment();
                try self.expect(.r_bracket, "']'");
                return key;
            },
            .string => {
                self.advance();
                return self.makeNode(tok.start, tok.end, .{ .string_literal = .{} });
            },
            .number, .bigint => {
                self.advance();
                const kind: ast.Node.Kind = if (tok.kind == .bigint) .bigint_literal else .{ .number_literal = .{} };
                return self.makeNode(tok.start, tok.end, kind);
            },
            // Nom privé `#x` (champ/méthode privé de classe).
            .private_name => {
                self.advance();
                return self.makeNode(tok.start, tok.end, .private_name);
            },
            // Identifiant OU mot réservé (`static`, `catch`, `default`… sont des
            // noms de clé/membre valides).
            else => {
                if (tok.kind != .identifier and !isKeyword(tok.kind)) return self.failUnexpected(tok, "member name");
                self.advance();
                return self.identNode(tok);
            },
        }
    }

    fn keyNamed(self: *const Parser, key: *const ast.Node, name: []const u8) bool {
        return key.kind == .identifier and std.mem.eql(u8, key.text(self.source), name);
    }

    // ---- modules (import / export) ----

    /// Le module source : obligatoirement une string.
    fn parseSourceString(self: *Parser) ParseError!*ast.Node {
        const tok = self.at() orelse return self.fail(error.SourceNotString, "module source must be a string", @intCast(self.source.len));
        if (tok.kind != .string) {
            return self.fail(error.SourceNotString, "module source must be a string", tok.start);
        }
        self.advance();
        return self.makeNode(tok.start, tok.end, .{ .string_literal = .{} });
    }

    fn identifierNode(self: *Parser, what: []const u8) ParseError!*ast.Node {
        const t = try self.eat(.identifier, what);
        return self.identNode(t);
    }

    /// Nom de module/specifier : identifiant OU mot-clé (`default`, etc.).
    fn parseModuleName(self: *Parser, what: []const u8) ParseError!*ast.Node {
        const t = self.at() orelse return self.failUnexpected(null, what);
        if (t.kind == .identifier or isKeyword(t.kind)) {
            self.advance();
            return self.identNode(t);
        }
        return self.failUnexpected(t, what);
    }

    // import := 'import' string ';'?                          (side-effect)
    //        | 'import' (default (',' binding)? | binding) 'from' string ';'?
    fn parseImportDeclaration(self: *Parser) ParseError!*ast.Node {
        const kw = self.at().?; // 'import'
        self.advance();

        // import "side-effect";
        if (self.at()) |t| if (t.kind == .string) {
            const source = try self.parseSourceString();
            try self.consumeSemicolon();
            return self.makeNode(kw.start, source.end, .{ .import_declaration = .{ .specifiers = try self.arena.alloc(*ast.Node, 0), .source = source } });
        };

        // TS phase 2 : `import type …` (déclaration ENTIÈRE type-only) — `type`
        // modifieur si suivi de `{`/`*`/un identifiant ≠ `from` (sinon `type` = binding).
        const type_only = self.ts and self.atTypeOnlyModifier();
        if (type_only) self.advance();

        var specifiers: std.ArrayList(*ast.Node) = .empty;
        if (self.at()) |t| {
            if (t.kind == .identifier) {
                // default specifier
                const local = try self.identifierNode("imported binding");
                try specifiers.append(self.arena, try self.makeNode(local.start, local.end, .{ .import_default_specifier = .{ .local = local } }));
                if (self.match(.comma)) try self.parseImportBinding(&specifiers);
            } else {
                try self.parseImportBinding(&specifiers);
            }
        }

        try self.expectContextual("from", "'from'");
        const source = try self.parseSourceString();
        try self.consumeSemicolon();
        return self.makeNode(kw.start, source.end, .{ .import_declaration = .{
            .specifiers = try specifiers.toOwnedSlice(self.arena),
            .source = source,
            .type_only = type_only,
        } });
    }

    /// `type` en tête d'import/export = modifieur type-only si suivi de `{`/`*`/un
    /// identifiant qui n'est PAS `from`/`as` (sinon `type` est un nom lié/exporté).
    fn atTypeOnlyModifier(self: *const Parser) bool {
        const t = self.at() orelse return false;
        if (!self.tokenTextIs(t, "type")) return false;
        const next = self.kindAt(1) orelse return false;
        if (next == .l_brace or next == .star) return true;
        if (next == .identifier) {
            const nt = self.tokens[self.pos + 1];
            return !self.tokenTextIs(nt, "from") and !self.tokenTextIs(nt, "as");
        }
        return false;
    }
    /// `type` DEVANT un nom de spécificateur (`import { type A, B }`) : modifieur si
    /// suivi d'un identifiant qui n'est PAS `as` (sinon `type` est le nom importé).
    fn matchSpecifierTypeModifier(self: *Parser) bool {
        const t = self.at() orelse return false;
        if (!self.ts or !self.tokenTextIs(t, "type")) return false;
        if (self.kindAt(1) != .identifier) return false;
        if (self.tokenTextIs(self.tokens[self.pos + 1], "as")) return false;
        self.advance(); // consomme `type`
        return true;
    }

    // '* as ns'  |  '{ a, b as c }'
    fn parseImportBinding(self: *Parser, specifiers: *std.ArrayList(*ast.Node)) ParseError!void {
        const tok = self.at() orelse return self.failUnexpected(null, "'{' or '*'");
        if (tok.kind == .star) {
            self.advance();
            try self.expectContextual("as", "'as'");
            const local = try self.identifierNode("namespace binding");
            try specifiers.append(self.arena, try self.makeNode(tok.start, local.end, .{ .import_namespace_specifier = .{ .local = local } }));
            return;
        }
        if (tok.kind == .l_brace) {
            self.advance();
            while (self.at()) |t| {
                if (t.kind == .r_brace) break;
                const is_type = self.matchSpecifierTypeModifier(); // `{ type A, B }`
                const imported = try self.parseModuleName("imported name");
                var local = imported;
                if (self.matchContextual("as")) local = try self.parseModuleName("local name");
                try specifiers.append(self.arena, try self.makeNode(imported.start, local.end, .{ .import_specifier = .{ .imported = imported, .local = local, .type_only = is_type } }));
                if (!self.match(.comma) or self.atKind(.r_brace)) break;
            }
            try self.expect(.r_brace, "'}'");
            return;
        }
        return self.failUnexpected(tok, "'{' or '*'");
    }

    // export := 'export' 'default' assignment ';'?
    //        | 'export' '*' 'from' string ';'?
    //        | 'export' '{' specifiers '}' ('from' string)? ';'?
    //        | 'export' declaration
    fn parseExportDeclaration(self: *Parser) ParseError!*ast.Node {
        const kw = self.at().?; // 'export'
        self.advance();

        if (self.match(.kw_default)) {
            const decl = try self.parseAssignment();
            try self.consumeSemicolon();
            return self.makeNode(kw.start, decl.end, .{ .export_default_declaration = .{ .declaration = decl } });
        }

        if (self.match(.star)) {
            try self.expectContextual("from", "'from'");
            const source = try self.parseSourceString();
            try self.consumeSemicolon();
            return self.makeNode(kw.start, source.end, .{ .export_all_declaration = .{ .source = source } });
        }

        // TS phase 2 : `export type { … }` (export ENTIER type-only). `type` devant
        // `{` seulement (l'alias `export type A = …` reste géré plus bas).
        var exp_type_only = false;
        if (self.ts) if (self.at()) |t| {
            if (self.tokenTextIs(t, "type") and self.kindAt(1) == .l_brace) {
                self.advance();
                exp_type_only = true;
            }
        };

        if (self.at()) |t| {
            if (t.kind == .l_brace) {
                self.advance();
                var specifiers: std.ArrayList(*ast.Node) = .empty;
                while (self.at()) |m| {
                    if (m.kind == .r_brace) break;
                    const is_type = self.matchSpecifierTypeModifier(); // `{ type A, B }`
                    const local = try self.parseModuleName("exported name");
                    var exported = local;
                    if (self.matchContextual("as")) exported = try self.parseModuleName("export alias");
                    try specifiers.append(self.arena, try self.makeNode(local.start, exported.end, .{ .export_specifier = .{ .local = local, .exported = exported, .type_only = is_type } }));
                    if (!self.match(.comma) or self.atKind(.r_brace)) break;
                }
                const close = try self.eat(.r_brace, "'}'");
                var src: ?*ast.Node = null;
                var end = close.end;
                if (self.matchContextual("from")) {
                    const s = try self.parseSourceString();
                    src = s;
                    end = s.end;
                }
                try self.consumeSemicolon();
                return self.makeNode(kw.start, end, .{ .export_named_declaration = .{
                    .declaration = null,
                    .specifiers = try specifiers.toOwnedSlice(self.arena),
                    .source = src,
                    .type_only = exp_type_only,
                } });
            }
        }

        // TS : `export type A = …` / `export interface I { … }` (type-only, effacés
        // ENTIER par stripTypes — l'export disparaît avec sa déclaration).
        if (self.atTsTypeAlias() or self.atTsInterface()) {
            const decl = if (self.atTsTypeAlias()) try self.parseTypeAlias() else try self.parseInterface();
            return self.makeNode(kw.start, decl.end, .{ .export_named_declaration = .{
                .declaration = decl,
                .specifiers = try self.arena.alloc(*ast.Node, 0),
                .source = null,
            } });
        }

        // TS phase 3 : `export enum` / `export const enum` / `export namespace`
        // (compilés par stripTypes en `export var …` + IIFE).
        if (self.atTsEnum() or self.atTsNamespace() or (self.ts and self.at().?.kind == .kw_const and self.kindAt2Is("enum"))) {
            const decl = if (self.atTsNamespace()) try self.parseNamespace() else blk: {
                const is_const = self.at().?.kind == .kw_const;
                if (is_const) self.advance();
                break :blk try self.parseEnum(is_const);
            };
            return self.makeNode(kw.start, decl.end, .{ .export_named_declaration = .{
                .declaration = decl,
                .specifiers = try self.arena.alloc(*ast.Node, 0),
                .source = null,
            } });
        }

        // export <declaration> : const/let/var/function/class (+ async function)
        if (self.at()) |t| {
            const is_async_fn = self.tokenTextIs(t, "async") and self.kindAt(1) == .kw_function;
            if (is_async_fn or switch (t.kind) {
                .kw_const, .kw_let, .kw_var, .kw_function, .kw_class => true,
                else => false,
            }) {
                const decl = try self.parseStatement();
                return self.makeNode(kw.start, decl.end, .{ .export_named_declaration = .{
                    .declaration = decl,
                    .specifiers = try self.arena.alloc(*ast.Node, 0),
                    .source = null,
                } });
            }
        }
        return self.failUnexpected(self.at(), "declaration, '{', '*' or 'default'");
    }
};

/// Résultat de parsing : un AST TOUJOURS produit (partiel si erreurs) + la liste
/// des diagnostics. Zéro erreur => AST identique à avant (invariant absolu).
pub const ParseResult = struct { program: *ast.Node, errors: []Diagnostic };

/// Lexe `source` en récupérant : sur erreur lexer, on la NOTE puis on relexe le
/// PRÉFIXE propre (avant l'offset d'erreur) pour garder les statements sains
/// d'avant — le lexer lui-même n'a pas de récupération (raccourci assumé).
fn lexRecover(p: *Parser, source: []const u8) []const lexer.Token {
    var d: lexer.Diagnostic = .{};
    return lexer.tokenizeDiag(p.arena, source, &d, p.jsx) catch {
        p.recordError(d.message, d.pos);
        var d2: lexer.Diagnostic = .{};
        const cut = @min(@as(usize, d.pos), source.len);
        return lexer.tokenizeDiag(p.arena, source[0..cut], &d2, p.jsx) catch &.{};
    };
}

/// Parse un programme complet AVEC error recovery : renvoie `{ program, errors }`.
/// Ne peut échouer que sur OOM (les erreurs de syntaxe sont récupérées).
pub fn parse(arena: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!ParseResult {
    return parseWith(arena, source, false, false);
}

/// Idem `parse`, mais avec la grammaire JSX et/ou TypeScript (opt-in) activées.
pub fn parseWith(arena: std.mem.Allocator, source: []const u8, jsx: bool, ts: bool) std.mem.Allocator.Error!ParseResult {
    var p = Parser{ .tokens = &.{}, .source = source, .arena = arena, .jsx = jsx, .ts = ts };
    p.tokens = lexRecover(&p, source);
    const program = p.parseProgram() catch return error.OutOfMemory; // seul OOM s'échappe
    return .{ .program = program, .errors = p.errors.items };
}

/// Parse une seule expression et exige que tout le source soit consommé (pas de
/// recovery — usage tests / internes). Renvoie l'erreur au premier problème.
pub fn parseExpressionSource(arena: std.mem.Allocator, source: []const u8) ParseError!*ast.Node {
    return parseExpressionSourceWith(arena, source, false, false);
}

pub fn parseExpressionSourceWith(arena: std.mem.Allocator, source: []const u8, jsx: bool, ts: bool) ParseError!*ast.Node {
    var d: lexer.Diagnostic = .{};
    const tokens = lexer.tokenizeDiag(arena, source, &d, jsx) catch return error.UnexpectedToken;
    var p = Parser{ .tokens = tokens, .source = source, .arena = arena, .jsx = jsx, .ts = ts };
    const node = try p.parseExpr();
    if (p.at()) |tok| return p.failUnexpected(tok, "end of input");
    return node;
}

// ------------------------------------------------------------------ tests

fn treeOf(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const node = try parseExpressionSource(arena.allocator(), source);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try printTree(node, source, &out, gpa);
    return out.toOwnedSlice(gpa);
}

fn programTreeOf(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parse(arena.allocator(), source);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try printTree(r.program, source, &out, gpa);
    return out.toOwnedSlice(gpa);
}

/// Helper de test : renvoie le nombre de diagnostics d'un source.
fn errorCountOf(gpa: std.mem.Allocator, source: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parse(arena.allocator(), source);
    return r.errors.len;
}

/// Idem, grammaire JSX activée (arbre debug et compte d'erreurs).
fn programTreeOfJsx(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseWith(arena.allocator(), source, true, false);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try printTree(r.program, source, &out, gpa);
    return out.toOwnedSlice(gpa);
}
fn errorCountOfJsx(gpa: std.mem.Allocator, source: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseWith(arena.allocator(), source, true, false);
    return r.errors.len;
}

test "function declaration : function add(a, b) { return a + b; } -> 2 params" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "function add(a, b) { return a + b; }");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  FunctionDeclaration
        \\    Identifier add
        \\    Params
        \\      Identifier a
        \\      Identifier b
        \\    BlockStatement
        \\      ReturnStatement
        \\        BinaryExpression "+"
        \\          Identifier a
        \\          Identifier b
        \\
    , tree);
}

test "function expression anonyme : const f = function() { return 1; };" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "const f = function() { return 1; };");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  VariableDeclaration const
        \\    VariableDeclarator
        \\      Identifier f
        \\      FunctionExpression
        \\        Params
        \\        BlockStatement
        \\          ReturnStatement
        \\            NumberLiteral 1
        \\
    , tree);
}

test "arrow : x => x + 1 (1 param, corps expression)" {
    const gpa = std.testing.allocator;
    const tree = try treeOf(gpa, "x => x + 1");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\ArrowFunction (expression)
        \\  Params
        \\    Identifier x
        \\  BinaryExpression "+"
        \\    Identifier x
        \\    NumberLiteral 1
        \\
    , tree);
}

test "arrow : (a, b) => { return a * b; } (2 params, corps bloc)" {
    const gpa = std.testing.allocator;
    const tree = try treeOf(gpa, "(a, b) => { return a * b; }");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\ArrowFunction (block)
        \\  Params
        \\    Identifier a
        \\    Identifier b
        \\  BlockStatement
        \\    ReturnStatement
        \\      BinaryExpression "*"
        \\        Identifier a
        \\        Identifier b
        \\
    , tree);
}

test "arrow : () => 42 (0 param)" {
    const gpa = std.testing.allocator;
    const tree = try treeOf(gpa, "() => 42");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\ArrowFunction (expression)
        \\  Params
        \\  NumberLiteral 42
        \\
    , tree);
}

test "groupement non cassé par l'arrow : (a + b) * 2" {
    const gpa = std.testing.allocator;
    const tree = try treeOf(gpa, "(a + b) * 2");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\BinaryExpression "*"
        \\  BinaryExpression "+"
        \\    Identifier a
        \\    Identifier b
        \\  NumberLiteral 2
        \\
    , tree);
}

test "arrow dans une déclaration : const g = (x) => x * 2;" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "const g = (x) => x * 2;");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  VariableDeclaration const
        \\    VariableDeclarator
        \\      Identifier g
        \\      ArrowFunction (expression)
        \\        Params
        \\          Identifier x
        \\        BinaryExpression "*"
        \\          Identifier x
        \\          NumberLiteral 2
        \\
    , tree);
}

test "arrow comme argument d'appel : arr.map(x => x * 2)" {
    const gpa = std.testing.allocator;
    const tree = try treeOf(gpa, "arr.map(x => x * 2)");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\CallExpression
        \\  MemberExpression
        \\    Identifier arr
        \\    Identifier map
        \\  ArrowFunction (expression)
        \\    Params
        \\      Identifier x
        \\    BinaryExpression "*"
        \\      Identifier x
        \\      NumberLiteral 2
        \\
    , tree);
}

test "array : [1, 2, 3], [] et elision [1, , 3]" {
    const gpa = std.testing.allocator;
    {
        const tree = try treeOf(gpa, "[1, 2, 3]");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\ArrayExpression
            \\  NumberLiteral 1
            \\  NumberLiteral 2
            \\  NumberLiteral 3
            \\
        , tree);
    }
    {
        const tree = try treeOf(gpa, "[]");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings("ArrayExpression\n", tree);
    }
    {
        const tree = try treeOf(gpa, "[1, , 3]");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\ArrayExpression
            \\  NumberLiteral 1
            \\  <elision>
            \\  NumberLiteral 3
            \\
        , tree);
    }
}

test "object : const o = { a: 1, b }; (property + shorthand)" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "const o = { a: 1, b };");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  VariableDeclaration const
        \\    VariableDeclarator
        \\      Identifier o
        \\      ObjectExpression
        \\        Property
        \\          Identifier a
        \\          NumberLiteral 1
        \\        Property [shorthand]
        \\          Identifier b
        \\
    , tree);
}

test "object computed : const k = { [x + 1]: v };" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "const k = { [x + 1]: v };");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  VariableDeclaration const
        \\    VariableDeclarator
        \\      Identifier k
        \\      ObjectExpression
        \\        Property [computed]
        \\          BinaryExpression "+"
        \\            Identifier x
        \\            NumberLiteral 1
        \\          Identifier v
        \\
    , tree);
}

test "ambiguïté { : bloc + labeled statement, objet via ({...})" {
    const gpa = std.testing.allocator;

    // '{ a: 1 }' en statement = bloc ; DEPUIS LES LABELS, `a: 1` = LabeledStatement
    // (label `a`, corps `1`) — plus une erreur (comportement changé).
    {
        const tree = try programTreeOf(gpa, "{ a: 1 }");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  BlockStatement
            \\    LabeledStatement
            \\      Identifier a
            \\      ExpressionStatement
            \\        NumberLiteral 1
            \\
        , tree);
    }

    // '({ a: 1 })' = ObjectExpression (seule façon d'avoir un objet en tête).
    {
        const tree = try treeOf(gpa, "({ a: 1 })");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\ObjectExpression
            \\  Property
            \\    Identifier a
            \\    NumberLiteral 1
            \\
        , tree);
    }
}

test "spread : foo(...args) et [a, ...rest]" {
    const gpa = std.testing.allocator;
    {
        const tree = try treeOf(gpa, "foo(...args)");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\CallExpression
            \\  Identifier foo
            \\  SpreadElement
            \\    Identifier args
            \\
        , tree);
    }
    {
        const tree = try treeOf(gpa, "[a, ...rest]");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\ArrayExpression
            \\  Identifier a
            \\  SpreadElement
            \\    Identifier rest
            \\
        , tree);
    }
}

test "méthodes d'objet : foo(), get/set, *gen, async, [computed]" {
    const gpa = std.testing.allocator;
    const t = try treeOf(gpa, "({ foo() {}, get x() {}, set x(v) {}, *gen() {}, async m() {}, [k]() {} })");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\ObjectExpression
        \\  MethodDefinition method
        \\    Identifier foo
        \\    Params
        \\    BlockStatement
        \\  MethodDefinition getter
        \\    Identifier x
        \\    Params
        \\    BlockStatement
        \\  MethodDefinition setter
        \\    Identifier x
        \\    Params
        \\      Identifier v
        \\    BlockStatement
        \\  MethodDefinition method generator
        \\    Identifier gen
        \\    Params
        \\    BlockStatement
        \\  MethodDefinition method async
        \\    Identifier m
        \\    Params
        \\    BlockStatement
        \\  MethodDefinition method computed
        \\    Identifier k
        \\    Params
        \\    BlockStatement
        \\
    , t);
}

test "array pattern : const [a, b] = xs; et le trou const [a, , c] = xs;" {
    const gpa = std.testing.allocator;
    {
        const tree = try programTreeOf(gpa, "const [a, b] = xs;");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  VariableDeclaration const
            \\    VariableDeclarator
            \\      ArrayPattern
            \\        Identifier a
            \\        Identifier b
            \\      Identifier xs
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "const [a, , c] = xs;");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  VariableDeclaration const
            \\    VariableDeclarator
            \\      ArrayPattern
            \\        Identifier a
            \\        <elision>
            \\        Identifier c
            \\      Identifier xs
            \\
        , tree);
    }
}

test "array pattern : défaut + rest const [a, b = 2, ...rest] = xs;" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "const [a, b = 2, ...rest] = xs;");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  VariableDeclaration const
        \\    VariableDeclarator
        \\      ArrayPattern
        \\        Identifier a
        \\        AssignmentPattern
        \\          Identifier b
        \\          NumberLiteral 2
        \\        RestElement
        \\          Identifier rest
        \\      Identifier xs
        \\
    , tree);
}

test "object pattern : const { x, y: alias, z = 3 } = obj;" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "const { x, y: alias, z = 3 } = obj;");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  VariableDeclaration const
        \\    VariableDeclarator
        \\      ObjectPattern
        \\        Property [shorthand]
        \\          Identifier x
        \\        Property
        \\          Identifier y
        \\          Identifier alias
        \\        Property [shorthand]
        \\          AssignmentPattern
        \\            Identifier z
        \\            NumberLiteral 3
        \\      Identifier obj
        \\
    , tree);
}

test "object pattern imbriqué : const { a: { b } } = o;" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "const { a: { b } } = o;");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  VariableDeclaration const
        \\    VariableDeclarator
        \\      ObjectPattern
        \\        Property
        \\          Identifier a
        \\          ObjectPattern
        \\            Property [shorthand]
        \\              Identifier b
        \\      Identifier o
        \\
    , tree);
}

test "object pattern : rest const { a, ...others } = obj;" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "const { a, ...others } = obj;");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  VariableDeclaration const
        \\    VariableDeclarator
        \\      ObjectPattern
        \\        Property [shorthand]
        \\          Identifier a
        \\        RestElement
        \\          Identifier others
        \\      Identifier obj
        \\
    , tree);
}

test "params complets : function f(a = 1, ...rest) {}" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "function f(a = 1, ...rest) {}");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  FunctionDeclaration
        \\    Identifier f
        \\    Params
        \\      AssignmentPattern
        \\        Identifier a
        \\        NumberLiteral 1
        \\      RestElement
        \\        Identifier rest
        \\    BlockStatement
        \\
    , tree);
}

test "rest doit être le dernier : function g(...r, x) {} -> erreur" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expect((try parse(arena.allocator(), "function g(...r, x) {}")).errors.len >= 1);
}

test "arrowAhead avec brackets : ([a, b]) => a" {
    const gpa = std.testing.allocator;
    const tree = try treeOf(gpa, "([a, b]) => a");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\ArrowFunction (expression)
        \\  Params
        \\    ArrayPattern
        \\      Identifier a
        \\      Identifier b
        \\  Identifier a
        \\
    , tree);
}

test "spread objet (valeur) : const merged = { ...defaults, x: 1 };" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "const merged = { ...defaults, x: 1 };");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  VariableDeclaration const
        \\    VariableDeclarator
        \\      Identifier merged
        \\      ObjectExpression
        \\        SpreadElement
        \\          Identifier defaults
        \\        Property
        \\          Identifier x
        \\          NumberLiteral 1
        \\
    , tree);
}

test "destructuring assignment : [a, b] = xs; (conversion)" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "[a, b] = xs;");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  ExpressionStatement
        \\    AssignmentExpression "="
        \\      ArrayPattern
        \\        Identifier a
        \\        Identifier b
        \\      Identifier xs
        \\
    , tree);
}

test "destructuring assignment récursif : [a, [b, c]] = xs;" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "[a, [b, c]] = xs;");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  ExpressionStatement
        \\    AssignmentExpression "="
        \\      ArrayPattern
        \\        Identifier a
        \\        ArrayPattern
        \\          Identifier b
        \\          Identifier c
        \\      Identifier xs
        \\
    , tree);
}

test "destructuring assignment objet : ({ x, y: z } = o);" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "({ x, y: z } = o);");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  ExpressionStatement
        \\    AssignmentExpression "="
        \\      ObjectPattern
        \\        Property [shorthand]
        \\          Identifier x
        \\        Property
        \\          Identifier y
        \\          Identifier z
        \\      Identifier o
        \\
    , tree);
}

test "destructuring assignment : rest et erreurs" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // [a, ...rest] = xs;
    {
        const tree = try programTreeOf(gpa, "[a, ...rest] = xs;");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ExpressionStatement
            \\    AssignmentExpression "="
            \\      ArrayPattern
            \\        Identifier a
            \\        RestElement
            \\          Identifier rest
            \\      Identifier xs
            \\
        , tree);
    }

    // [...r, b] = xs; -> rest pas en dernier
    try std.testing.expect((try parse(arena.allocator(), "[...r, b] = xs;")).errors.len >= 1);

    // [foo()] = xs; -> cible invalide
    try std.testing.expect((try parse(arena.allocator(), "[foo()] = xs;")).errors.len >= 1);

    // { a } = o; -> bloc puis erreur (règle du { ; JS réel)
    try std.testing.expect((try parse(arena.allocator(), "{ a } = o;")).errors.len >= 1);

    // [a] += xs; -> seul '=' accepte un pattern
    try std.testing.expect((try parse(arena.allocator(), "[a] += xs;")).errors.len >= 1);
}

test "for-of / for-in : déclaration, cible existante, in" {
    const gpa = std.testing.allocator;
    {
        const tree = try programTreeOf(gpa, "for (const [k, v] of entries) {}");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ForOfStatement
            \\    VariableDeclaration const
            \\      VariableDeclarator
            \\        ArrayPattern
            \\          Identifier k
            \\          Identifier v
            \\    Identifier entries
            \\    BlockStatement
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "for (x of xs) {}");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ForOfStatement
            \\    Identifier x
            \\    Identifier xs
            \\    BlockStatement
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "for (const k in obj) {}");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ForInStatement
            \\    VariableDeclaration const
            \\      VariableDeclarator
            \\        Identifier k
            \\    Identifier obj
            \\    BlockStatement
            \\
        , tree);
    }
}

test "template : `hello` (full), `a ${x} b`, `${a}${b}`" {
    const gpa = std.testing.allocator;
    {
        const tree = try treeOf(gpa, "`hello`");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\TemplateLiteral
            \\  TemplateElement "hello"
            \\
        , tree);
    }
    {
        const tree = try treeOf(gpa, "`a ${x} b`");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\TemplateLiteral
            \\  TemplateElement "a "
            \\  Identifier x
            \\  TemplateElement " b"
            \\
        , tree);
    }
    {
        const tree = try treeOf(gpa, "`${a}${b}`");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\TemplateLiteral
            \\  TemplateElement ""
            \\  Identifier a
            \\  TemplateElement ""
            \\  Identifier b
            \\  TemplateElement ""
            \\
        , tree);
    }
}

test "template imbriqué : `outer ${ `inner ${x}` } end`" {
    const gpa = std.testing.allocator;
    const tree = try treeOf(gpa, "`outer ${ `inner ${x}` } end`");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\TemplateLiteral
        \\  TemplateElement "outer "
        \\  TemplateLiteral
        \\    TemplateElement "inner "
        \\    Identifier x
        \\    TemplateElement ""
        \\  TemplateElement " end"
        \\
    , tree);
}

test "template : expression complète et objet dans ${}" {
    const gpa = std.testing.allocator;
    {
        const tree = try treeOf(gpa, "`sum: ${a + b}`");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\TemplateLiteral
            \\  TemplateElement "sum: "
            \\  BinaryExpression "+"
            \\    Identifier a
            \\    Identifier b
            \\  TemplateElement ""
            \\
        , tree);
    }
    {
        const tree = try treeOf(gpa, "`obj: ${ {a: 1}.a }`");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\TemplateLiteral
            \\  TemplateElement "obj: "
            \\  MemberExpression
            \\    ObjectExpression
            \\      Property
            \\        Identifier a
            \\        NumberLiteral 1
            \\    Identifier a
            \\  TemplateElement ""
            \\
        , tree);
    }
}

test "tagged template : tag`x ${y}`" {
    const gpa = std.testing.allocator;
    const tree = try treeOf(gpa, "tag`x ${y}`");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\TaggedTemplateExpression
        \\  Identifier tag
        \\  TemplateLiteral
        \\    TemplateElement "x "
        \\    Identifier y
        \\    TemplateElement ""
        \\
    , tree);
}

test "template non fermé -> erreur" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expect((try parse(arena.allocator(), "`pas fermé")).errors.len >= 1);
    try std.testing.expect((try parse(arena.allocator(), "`a ${x")).errors.len >= 1);
}

test "new : new Foo(a, b), new Foo (sans parens), new a.b.C()" {
    const gpa = std.testing.allocator;
    {
        const tree = try treeOf(gpa, "new Foo(a, b)");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\NewExpression
            \\  Identifier Foo
            \\  Identifier a
            \\  Identifier b
            \\
        , tree);
    }
    {
        const tree = try treeOf(gpa, "new Foo");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings("NewExpression\n  Identifier Foo\n", tree);
    }
    {
        const tree = try treeOf(gpa, "new a.b.C()");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\NewExpression
            \\  MemberExpression
            \\    MemberExpression
            \\      Identifier a
            \\      Identifier b
            \\    Identifier C
            \\
        , tree);
    }
}

test "class vide : class A {} et const B = class {};" {
    const gpa = std.testing.allocator;
    {
        const tree = try programTreeOf(gpa, "class A {}");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ClassDeclaration
            \\    Identifier A
            \\    ClassBody
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "const B = class {};");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  VariableDeclaration const
            \\    VariableDeclarator
            \\      Identifier B
            \\      ClassExpression
            \\        ClassBody
            \\
        , tree);
    }
}

test "class extends + constructor + this" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "class A extends B { constructor(x) { this.x = x; } }");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  ClassDeclaration
        \\    Identifier A
        \\    SuperClass
        \\      Identifier B
        \\    ClassBody
        \\      MethodDefinition constructor
        \\        Identifier constructor
        \\        Params
        \\          Identifier x
        \\        BlockStatement
        \\          ExpressionStatement
        \\            AssignmentExpression "="
        \\              MemberExpression
        \\                ThisExpression
        \\                Identifier x
        \\              Identifier x
        \\
    , tree);
}

test "getter / setter, et get() = méthode nommée get" {
    const gpa = std.testing.allocator;
    {
        const tree = try programTreeOf(gpa, "class P { get area() { return 1; } set area(v) {} }");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ClassDeclaration
            \\    Identifier P
            \\    ClassBody
            \\      MethodDefinition getter
            \\        Identifier area
            \\        Params
            \\        BlockStatement
            \\          ReturnStatement
            \\            NumberLiteral 1
            \\      MethodDefinition setter
            \\        Identifier area
            \\        Params
            \\          Identifier v
            \\        BlockStatement
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "class C { get() { return 1; } }");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ClassDeclaration
            \\    Identifier C
            \\    ClassBody
            \\      MethodDefinition method
            \\        Identifier get
            \\        Params
            \\        BlockStatement
            \\          ReturnStatement
            \\            NumberLiteral 1
            \\
        , tree);
    }
}

test "static méthode + champs (fields)" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "class D { static create() {} x = 1; static y = 2; }");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  ClassDeclaration
        \\    Identifier D
        \\    ClassBody
        \\      MethodDefinition method static
        \\        Identifier create
        \\        Params
        \\        BlockStatement
        \\      PropertyDefinition
        \\        Identifier x
        \\        NumberLiteral 1
        \\      PropertyDefinition static
        \\        Identifier y
        \\        NumberLiteral 2
        \\
    , tree);
}

test "clé computed et superclass = expression" {
    const gpa = std.testing.allocator;
    {
        const tree = try programTreeOf(gpa, "class E { [Symbol.iterator]() {} }");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ClassDeclaration
            \\    Identifier E
            \\    ClassBody
            \\      MethodDefinition method computed
            \\        MemberExpression
            \\          Identifier Symbol
            \\          Identifier iterator
            \\        Params
            \\        BlockStatement
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "class A extends getBase() {}");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ClassDeclaration
            \\    Identifier A
            \\    SuperClass
            \\      CallExpression
            \\        Identifier getBase
            \\    ClassBody
            \\
        , tree);
    }
}

test "import : default, named (as), namespace, combiné, side-effect" {
    const gpa = std.testing.allocator;
    {
        const tree = try programTreeOf(gpa, "import x from 'mod';");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ImportDeclaration
            \\    ImportDefaultSpecifier
            \\      Identifier x
            \\    StringLiteral 'mod'
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "import { a, b as c } from 'mod';");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ImportDeclaration
            \\    ImportSpecifier
            \\      Identifier a
            \\      Identifier a
            \\    ImportSpecifier
            \\      Identifier b
            \\      Identifier c
            \\    StringLiteral 'mod'
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "import * as ns from 'mod';");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ImportDeclaration
            \\    ImportNamespaceSpecifier
            \\      Identifier ns
            \\    StringLiteral 'mod'
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "import x, { a } from 'mod';");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ImportDeclaration
            \\    ImportDefaultSpecifier
            \\      Identifier x
            \\    ImportSpecifier
            \\      Identifier a
            \\      Identifier a
            \\    StringLiteral 'mod'
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "import 'polyfill';");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ImportDeclaration
            \\    StringLiteral 'polyfill'
            \\
        , tree);
    }
}

test "export : const, default anonyme, named (as), all, re-export" {
    const gpa = std.testing.allocator;
    {
        const tree = try programTreeOf(gpa, "export const x = 1;");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ExportNamedDeclaration
            \\    VariableDeclaration const
            \\      VariableDeclarator
            \\        Identifier x
            \\        NumberLiteral 1
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "export default function() {}");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ExportDefaultDeclaration
            \\    FunctionExpression
            \\      Params
            \\      BlockStatement
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "export { a as b };");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ExportNamedDeclaration
            \\    ExportSpecifier
            \\      Identifier a
            \\      Identifier b
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "export * from 'mod';");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ExportAllDeclaration
            \\    StringLiteral 'mod'
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "export { a } from 'mod';");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ExportNamedDeclaration
            \\    ExportSpecifier
            \\      Identifier a
            \\      Identifier a
            \\    StringLiteral 'mod'
            \\
        , tree);
    }
}

test "import() dynamique et erreurs top-level / source" {
    const gpa = std.testing.allocator;
    {
        const tree = try programTreeOf(gpa, "const p = import('./mod');");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  VariableDeclaration const
            \\    VariableDeclarator
            \\      Identifier p
            \\      ImportExpression
            \\        StringLiteral './mod'
            \\
        , tree);
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // import dans un bloc -> erreur top-level
    try std.testing.expect((try parse(arena.allocator(), "if (x) { import y from 'm'; }")).errors.len >= 1);

    // source non-string -> erreur
    try std.testing.expect((try parse(arena.allocator(), "import x from foo;")).errors.len >= 1);
}

test "throw et try/catch/finally (param, sans param, pattern, erreur)" {
    const gpa = std.testing.allocator;
    {
        const tree = try programTreeOf(gpa, "throw e;");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings("Program\n  ThrowStatement\n    Identifier e\n", tree);
    }
    {
        const tree = try programTreeOf(gpa, "try { f(); } catch (e) { g(e); } finally { h(); }");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  TryStatement
            \\    BlockStatement
            \\      ExpressionStatement
            \\        CallExpression
            \\          Identifier f
            \\    CatchClause
            \\      Identifier e
            \\      BlockStatement
            \\        ExpressionStatement
            \\          CallExpression
            \\            Identifier g
            \\            Identifier e
            \\    Finalizer
            \\      BlockStatement
            \\        ExpressionStatement
            \\          CallExpression
            \\            Identifier h
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "try { f(); } catch { g(); }");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  TryStatement
            \\    BlockStatement
            \\      ExpressionStatement
            \\        CallExpression
            \\          Identifier f
            \\    CatchClause
            \\      BlockStatement
            \\        ExpressionStatement
            \\          CallExpression
            \\            Identifier g
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "try { f(); } catch ({ message }) {}");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  TryStatement
            \\    BlockStatement
            \\      ExpressionStatement
            \\        CallExpression
            \\          Identifier f
            \\    CatchClause
            \\      ObjectPattern
            \\        Property [shorthand]
            \\          Identifier message
            \\      BlockStatement
            \\
        , tree);
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expect((try parse(arena.allocator(), "try { f(); }")).errors.len >= 1);
}

test "switch : fallthrough, default, et double default -> erreur" {
    const gpa = std.testing.allocator;
    {
        const tree = try programTreeOf(gpa, "switch (x) { case 1: case 2: a(); break; default: b(); }");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  SwitchStatement
            \\    Identifier x
            \\    SwitchCase
            \\      NumberLiteral 1
            \\    SwitchCase
            \\      NumberLiteral 2
            \\      ExpressionStatement
            \\        CallExpression
            \\          Identifier a
            \\      BreakStatement
            \\    SwitchCase default
            \\      ExpressionStatement
            \\        CallExpression
            \\          Identifier b
            \\
        , tree);
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expect((try parse(arena.allocator(), "switch (x) { default: default: }")).errors.len >= 1);
}

test "labels, break outer, do-while" {
    const gpa = std.testing.allocator;
    {
        const tree = try programTreeOf(gpa, "outer: for (;;) { break outer; }");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  LabeledStatement
            \\    Identifier outer
            \\    ForStatement
            \\      <empty>
            \\      <empty>
            \\      <empty>
            \\      BlockStatement
            \\        BreakStatement
            \\          Identifier outer
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "a: 1;");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  LabeledStatement
            \\    Identifier a
            \\    ExpressionStatement
            \\      NumberLiteral 1
            \\
        , tree);
    }
    {
        const tree = try programTreeOf(gpa, "do i++; while (i < 10);");
        defer gpa.free(tree);
        try std.testing.expectEqualStrings(
            \\Program
            \\  DoWhileStatement
            \\    ExpressionStatement
            \\      UpdateExpression "++" (postfix)
            \\        Identifier i
            \\    BinaryExpression "<"
            \\      Identifier i
            \\      NumberLiteral 10
            \\
        , tree);
    }
}

// ---- corpus fixes (littéraux, _/$, nombres, opérateurs, modules) ----

test "fix1 littéraux : true/false/null, undefined = identifier" {
    const gpa = std.testing.allocator;
    const tree = try treeOf(gpa, "x == null");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\BinaryExpression "=="
        \\  Identifier x
        \\  NullLiteral
        \\
    , tree);
    inline for (.{ .{ "true", "BooleanLiteral true\n" }, .{ "false", "BooleanLiteral false\n" }, .{ "undefined", "Identifier undefined\n" } }) |c| {
        const t = try treeOf(gpa, c[0]);
        defer gpa.free(t);
        try std.testing.expectEqualStrings(c[1], t);
    }
}

test "fix2 _/$ identifiants + fix3 nombres" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "const _x = $y.__z$1;");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  VariableDeclaration const
        \\    VariableDeclarator
        \\      Identifier _x
        \\      MemberExpression
        \\        Identifier $y
        \\        Identifier __z$1
        \\
    , tree);
    inline for (.{ "0xFF", "0b101", "0o17", ".5", "1.", "1e3", "2.5e-7", "1_000_000" }) |src| {
        const t = try treeOf(gpa, src);
        defer gpa.free(t);
        try std.testing.expectEqualStrings("NumberLiteral " ++ src ++ "\n", t);
    }
}

test "fix4 opérateurs : précédence bitwise, in, instanceof, void/delete, décalages" {
    const gpa = std.testing.allocator;
    // a & b == c  ->  a & (b == c)  (== lie plus fort que &)
    {
        const t = try treeOf(gpa, "a & b == c");
        defer gpa.free(t);
        try std.testing.expectEqualStrings(
            \\BinaryExpression "&"
            \\  Identifier a
            \\  BinaryExpression "=="
            \\    Identifier b
            \\    Identifier c
            \\
        , t);
    }
    // a | b & c  ->  a | (b & c)
    {
        const t = try treeOf(gpa, "a | b & c");
        defer gpa.free(t);
        try std.testing.expectEqualStrings(
            \\BinaryExpression "|"
            \\  Identifier a
            \\  BinaryExpression "&"
            \\    Identifier b
            \\    Identifier c
            \\
        , t);
    }
    inline for (.{
        .{ "x in obj", "in", "x", "obj" },
        .{ "a instanceof B", "instanceof", "a", "B" },
        .{ "a >>> b", ">>>", "a", "b" },
    }) |c| {
        const t = try treeOf(gpa, c[0]);
        defer gpa.free(t);
        const expected = "BinaryExpression \"" ++ c[1] ++ "\"\n  Identifier " ++ c[2] ++ "\n  Identifier " ++ c[3] ++ "\n";
        try std.testing.expectEqualStrings(expected, t);
    }
    // unaires void/delete/~
    {
        const t = try treeOf(gpa, "void 0");
        defer gpa.free(t);
        try std.testing.expectEqualStrings("UnaryExpression \"void\"\n  NumberLiteral 0\n", t);
    }
    // décalage assign
    {
        const t = try treeOf(gpa, "a >>= b");
        defer gpa.free(t);
        try std.testing.expectEqualStrings("AssignmentExpression \">>=\"\n  Identifier a\n  Identifier b\n", t);
    }
    // `for (x in obj)` sans déclaration -> for-in reconstruit
    {
        const t = try programTreeOf(gpa, "for (x in obj) {}");
        defer gpa.free(t);
        try std.testing.expectEqualStrings("Program\n  ForInStatement\n    Identifier x\n    Identifier obj\n    BlockStatement\n", t);
    }
}

test "fix5 export { x as default } + fix6 trailing comma appel" {
    const gpa = std.testing.allocator;
    {
        const t = try programTreeOf(gpa, "export { x as default };");
        defer gpa.free(t);
        try std.testing.expectEqualStrings(
            \\Program
            \\  ExportNamedDeclaration
            \\    ExportSpecifier
            \\      Identifier x
            \\      Identifier default
            \\
        , t);
    }
    {
        const t = try treeOf(gpa, "f(a, b,)");
        defer gpa.free(t);
        try std.testing.expectEqualStrings("CallExpression\n  Identifier f\n  Identifier a\n  Identifier b\n", t);
    }
}

test "regex : littéral, flags, char class contenant /" {
    const gpa = std.testing.allocator;
    {
        const t = try treeOf(gpa, "/ab+c/g");
        defer gpa.free(t);
        try std.testing.expectEqualStrings("RegexLiteral /ab+c/g\n", t);
    }
    {
        // Le `/` dans une classe `[...]` ne ferme pas la regex.
        const t = try treeOf(gpa, "/a[/]b/");
        defer gpa.free(t);
        try std.testing.expectEqualStrings("RegexLiteral /a[/]b/\n", t);
    }
    {
        // regex en argument d'appel.
        const t = try treeOf(gpa, "f(/re/, 2)");
        defer gpa.free(t);
        try std.testing.expectEqualStrings(
            \\CallExpression
            \\  Identifier f
            \\  RegexLiteral /re/
            \\  NumberLiteral 2
            \\
        , t);
    }
}

test "regex vs division : / est contextuel selon le token précédent" {
    const gpa = std.testing.allocator;
    {
        // Après un identifiant -> division (associative à gauche).
        const t = try treeOf(gpa, "a / b / c");
        defer gpa.free(t);
        try std.testing.expectEqualStrings(
            \\BinaryExpression "/"
            \\  BinaryExpression "/"
            \\    Identifier a
            \\    Identifier b
            \\  Identifier c
            \\
        , t);
    }
    {
        // Après `)` -> division (le groupement se déplie).
        const t = try treeOf(gpa, "(a) / 2");
        defer gpa.free(t);
        try std.testing.expectEqualStrings(
            \\BinaryExpression "/"
            \\  Identifier a
            \\  NumberLiteral 2
            \\
        , t);
    }
}

test "sequence : a, b, c aplati (opérateur virgule)" {
    const gpa = std.testing.allocator;
    const t = try treeOf(gpa, "a, b, c");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\SequenceExpression
        \\  Identifier a
        \\  Identifier b
        \\  Identifier c
        \\
    , t);
}

test "sequence : grouping (a, b) est une séquence ; f(a, b) NE l'est PAS" {
    const gpa = std.testing.allocator;
    {
        const t = try treeOf(gpa, "(a, b)");
        defer gpa.free(t);
        try std.testing.expectEqualStrings(
            \\SequenceExpression
            \\  Identifier a
            \\  Identifier b
            \\
        , t);
    }
    {
        // La virgule reste un séparateur d'arguments : pas de SequenceExpression.
        const t = try treeOf(gpa, "f(a, b)");
        defer gpa.free(t);
        try std.testing.expectEqualStrings(
            \\CallExpression
            \\  Identifier f
            \\  Identifier a
            \\  Identifier b
            \\
        , t);
    }
}

test "sequence : dans les clauses init et update d'un for" {
    const gpa = std.testing.allocator;
    const t = try programTreeOf(gpa, "for (i = 0, j = 9; i < j; i++, j--) {}");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\Program
        \\  ForStatement
        \\    SequenceExpression
        \\      AssignmentExpression "="
        \\        Identifier i
        \\        NumberLiteral 0
        \\      AssignmentExpression "="
        \\        Identifier j
        \\        NumberLiteral 9
        \\    BinaryExpression "<"
        \\      Identifier i
        \\      Identifier j
        \\    SequenceExpression
        \\      UpdateExpression "++" (postfix)
        \\        Identifier i
        \\      UpdateExpression "--" (postfix)
        \\        Identifier j
        \\    BlockStatement
        \\
    , t);
}

test "async : déclaration + await ; l'await est un mot-clé en contexte async" {
    const gpa = std.testing.allocator;
    const t = try programTreeOf(gpa, "async function f() { await g(); }");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\Program
        \\  FunctionDeclaration async
        \\    Identifier f
        \\    Params
        \\    BlockStatement
        \\      ExpressionStatement
        \\        AwaitExpression
        \\          CallExpression
        \\            Identifier g
        \\
    , t);
}

test "async arrow parenthésé : async (a, b) => await p" {
    const gpa = std.testing.allocator;
    const t = try treeOf(gpa, "async (a, b) => await p");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\ArrowFunction async (expression)
        \\  Params
        \\    Identifier a
        \\    Identifier b
        \\  AwaitExpression
        \\    Identifier p
        \\
    , t);
}

test "async(...) sans => est un APPEL, pas une arrow" {
    const gpa = std.testing.allocator;
    const t = try treeOf(gpa, "async(1, 2)");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\CallExpression
        \\  Identifier async
        \\  NumberLiteral 1
        \\  NumberLiteral 2
        \\
    , t);
}

test "async / yield restent des identifiants hors contexte" {
    const gpa = std.testing.allocator;
    {
        const t = try programTreeOf(gpa, "const async = 1;");
        defer gpa.free(t);
        try std.testing.expectEqualStrings(
            \\Program
            \\  VariableDeclaration const
            \\    VariableDeclarator
            \\      Identifier async
            \\      NumberLiteral 1
            \\
        , t);
    }
    {
        // `yield` hors generator = identifiant.
        const t = try programTreeOf(gpa, "const yield = 1;");
        defer gpa.free(t);
        try std.testing.expectEqualStrings(
            \\Program
            \\  VariableDeclaration const
            \\    VariableDeclarator
            \\      Identifier yield
            \\      NumberLiteral 1
            \\
        , t);
    }
}

// Choix documenté : au top-level `in_async = true` (top-level await des modules ES).
test "await au top-level -> AwaitExpression (top-level await)" {
    const gpa = std.testing.allocator;
    const t = try treeOf(gpa, "await x");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\AwaitExpression
        \\  Identifier x
        \\
    , t);
}

test "generator : yield, yield*, yield nu" {
    const gpa = std.testing.allocator;
    const t = try programTreeOf(gpa, "function* g() { yield 1; yield* inner(); yield; }");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\Program
        \\  FunctionDeclaration generator
        \\    Identifier g
        \\    Params
        \\    BlockStatement
        \\      ExpressionStatement
        \\        YieldExpression
        \\          NumberLiteral 1
        \\      ExpressionStatement
        \\        YieldExpression delegate
        \\          CallExpression
        \\            Identifier inner
        \\      ExpressionStatement
        \\        YieldExpression
        \\
    , t);
}

test "async generator : les deux flags + yield await imbriqué" {
    const gpa = std.testing.allocator;
    const t = try programTreeOf(gpa, "async function* stream() { yield await fetch(); }");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\Program
        \\  FunctionDeclaration async generator
        \\    Identifier stream
        \\    Params
        \\    BlockStatement
        \\      ExpressionStatement
        \\        YieldExpression
        \\          AwaitExpression
        \\            CallExpression
        \\              Identifier fetch
        \\
    , t);
}

test "hashbang : #! en tête est ignoré (ES2023)" {
    const gpa = std.testing.allocator;
    const t = try programTreeOf(gpa, "#!/usr/bin/env node\nconst x = 1;");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\Program
        \\  VariableDeclaration const
        \\    VariableDeclarator
        \\      Identifier x
        \\      NumberLiteral 1
        \\
    , t);
}

test "import.meta : meta-property (+ accès membre)" {
    const gpa = std.testing.allocator;
    const t = try treeOf(gpa, "import.meta.url");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\MemberExpression
        \\  MetaProperty import.meta
        \\  Identifier url
        \\
    , t);
}

test "ASI : deux déclarations séparées par un saut de ligne" {
    const gpa = std.testing.allocator;
    const t = try programTreeOf(gpa, "let a = 1\nlet b = 2");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\Program
        \\  VariableDeclaration let
        \\    VariableDeclarator
        \\      Identifier a
        \\      NumberLiteral 1
        \\  VariableDeclaration let
        \\    VariableDeclarator
        \\      Identifier b
        \\      NumberLiteral 2
        \\
    , t);
}

test "ASI : a()\\nb() -> deux appels" {
    const gpa = std.testing.allocator;
    const t = try programTreeOf(gpa, "a()\nb()");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\Program
        \\  ExpressionStatement
        \\    CallExpression
        \\      Identifier a
        \\  ExpressionStatement
        \\    CallExpression
        \\      Identifier b
        \\
    , t);
}

test "ASI restricted : return\\nx -> return; puis x" {
    const gpa = std.testing.allocator;
    const t = try programTreeOf(gpa, "function f() { return\nx }");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\Program
        \\  FunctionDeclaration
        \\    Identifier f
        \\    Params
        \\    BlockStatement
        \\      ReturnStatement
        \\      ExpressionStatement
        \\        Identifier x
        \\
    , t);
}

test "ASI restricted : throw\\nx -> erreur (illegal newline after throw)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try parse(arena.allocator(), "throw\nx")).errors.len >= 1);
}

test "ASI restricted : break\\nouter -> break; puis statement outer" {
    const gpa = std.testing.allocator;
    const t = try programTreeOf(gpa, "outer: while (1) { break\nouter }");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\Program
        \\  LabeledStatement
        \\    Identifier outer
        \\    WhileStatement
        \\      NumberLiteral 1
        \\      BlockStatement
        \\        BreakStatement
        \\        ExpressionStatement
        \\          Identifier outer
        \\
    , t);
}

test "ASI restricted : a\\n++b -> a; puis ++b (préfixe), PAS a++" {
    const gpa = std.testing.allocator;
    const t = try programTreeOf(gpa, "a\n++b");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\Program
        \\  ExpressionStatement
        \\    Identifier a
        \\  ExpressionStatement
        \\    UpdateExpression "++" (prefix)
        \\      Identifier b
        \\
    , t);
    // Contraste : a++\nb garde le postfix.
    const t2 = try programTreeOf(gpa, "a++\nb");
    defer gpa.free(t2);
    try std.testing.expectEqualStrings(
        \\Program
        \\  ExpressionStatement
        \\    UpdateExpression "++" (postfix)
        \\      Identifier a
        \\  ExpressionStatement
        \\    Identifier b
        \\
    , t2);
}

test "ASI piège IIFE : let a = b\\n(c).d() -> UN statement b(c).d()" {
    const gpa = std.testing.allocator;
    const t = try programTreeOf(gpa, "let a = b\n(c).d()");
    defer gpa.free(t);
    // Le `(` continue l'expression (appel) : pas d'ASI.
    try std.testing.expectEqualStrings(
        \\Program
        \\  VariableDeclaration let
        \\    VariableDeclarator
        \\      Identifier a
        \\      CallExpression
        \\        MemberExpression
        \\          CallExpression
        \\            Identifier b
        \\            Identifier c
        \\          Identifier d
        \\
    , t);
}

test "ASI : `let a = 1 let b = 2` (sans newline) est une ERREUR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try parse(arena.allocator(), "let a = 1 let b = 2")).errors.len >= 1);
}

test "reserved words comme noms de membre : p.catch, x.default, a.in" {
    const gpa = std.testing.allocator;
    const t = try treeOf(gpa, "p.catch(f)");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\CallExpression
        \\  MemberExpression
        \\    Identifier p
        \\    Identifier catch
        \\  Identifier f
        \\
    , t);
    // les mots-clés passent aussi en `.default` / `.in`.
    const t2 = try treeOf(gpa, "x.default.in");
    defer gpa.free(t2);
    try std.testing.expectEqualStrings(
        \\MemberExpression
        \\  MemberExpression
        \\    Identifier x
        \\    Identifier default
        \\  Identifier in
        \\
    , t2);
}

test "recovery : let b = ; -> 1 erreur, a et c intacts" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try errorCountOf(gpa, "let a = 1; let b = ; let c = 3;"));
    const tree = try programTreeOf(gpa, "let a = 1; let b = ; let c = 3;");
    defer gpa.free(tree);
    // a et c survivent (VariableDeclaration), b -> ErrorNode.
    try std.testing.expect(std.mem.indexOf(u8, tree, "Identifier a") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree, "Identifier c") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree, "ErrorNode") != null);
}

test "recovery : if (x { -> ) récupérée, if complet + 2 stmts" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try errorCountOf(gpa, "if (x { f(); } g();"));
    const tree = try programTreeOf(gpa, "if (x { f(); } g();");
    defer gpa.free(tree);
    try std.testing.expect(std.mem.indexOf(u8, tree, "IfStatement") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree, "Identifier g") != null); // g() survit
    try std.testing.expect(std.mem.indexOf(u8, tree, "ErrorNode") == null); // récup fine, pas d'error_node
}

test "recovery : erreur dans une classe -> C existe" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOf(gpa, "class C { foo() {} bar( }");
    defer gpa.free(tree);
    try std.testing.expect(std.mem.indexOf(u8, tree, "ClassDeclaration") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree, "Identifier C") != null);
    try std.testing.expect((try errorCountOf(gpa, "class C { foo() {} bar( }")) >= 1);
}

test "recovery : deux erreurs distantes -> les DEUX rapportées" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 2), try errorCountOf(gpa, "let a = ;\nx();\ny();\nz();\nlet b = ;\nend();"));
}

test "recovery : GARDE-FOU anti-boucle (le test se termine = pas de boucle)" {
    const gpa = std.testing.allocator;
    // Si le garde-fou anti-boucle manquait, ces cas boucleraient à l'infini et le
    // test ne se terminerait jamais. Qu'il se termine EST l'assertion.
    try std.testing.expect((try errorCountOf(gpa, "let x = ((((((;")) >= 1);
    try std.testing.expect((try errorCountOf(gpa, "}}}}}}")) >= 1);
    try std.testing.expect((try errorCountOf(gpa, "@#@#@#")) >= 1);
    _ = try errorCountOf(gpa, "((("); // pas de `;` ni fin claire
    _ = try errorCountOf(gpa, "function f( function g(");
}

test "recovery : code valide -> ZÉRO diagnostic (invariant sacré)" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), try errorCountOf(gpa, "const x = 1; function f(a) { return a + x; } f(2);"));
    try std.testing.expectEqual(@as(usize, 0), try errorCountOf(gpa, "class C extends B { #p = 1; m() { return this.#p; } }"));
}

// ------------------------------------------------------------------ tests JSX

test "JSX : élément simple avec attribut string + enfant texte" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOfJsx(gpa, "<div className=\"a\">hello</div>;");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  ExpressionStatement
        \\    JSXElement
        \\      JSXOpeningElement
        \\        JSXIdentifier div
        \\        JSXAttribute
        \\          JSXIdentifier className
        \\          StringLiteral "a"
        \\      JSXText "hello"
        \\      JSXClosingElement
        \\        JSXIdentifier div
        \\
    , tree);
}

test "JSX : nom membre A.B.C + 3 formes d'attributs (expr, spread, bare)" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOfJsx(gpa, "<A.B.C x={1} {...p} bare/>;");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  ExpressionStatement
        \\    JSXElement
        \\      JSXOpeningElement self-closing
        \\        JSXMemberExpression
        \\          JSXMemberExpression
        \\            JSXIdentifier A
        \\            JSXIdentifier B
        \\          JSXIdentifier C
        \\        JSXAttribute
        \\          JSXIdentifier x
        \\          JSXExpressionContainer
        \\            NumberLiteral 1
        \\        JSXSpreadAttribute
        \\          Identifier p
        \\        JSXAttribute
        \\          JSXIdentifier bare
        \\
    , tree);
}

test "JSX : fragment <>{a}<b/></>" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOfJsx(gpa, "<>{a}<b/></>;");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  ExpressionStatement
        \\    JSXFragment
        \\      JSXExpressionContainer
        \\        Identifier a
        \\      JSXElement
        \\        JSXOpeningElement self-closing
        \\          JSXIdentifier b
        \\
    , tree);
}

test "JSX : double bascule JS<->JSX (map imbriqué), sans erreur" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), try errorCountOfJsx(gpa, "<ul>{xs.map(x => <li key={x}>{x}</li>)}</ul>;"));
}

test "JSX : texte avec espaces préservés (a / {b} / c)" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOfJsx(gpa, "<div>a {b} c</div>;");
    defer gpa.free(tree);
    // Les JSXText « a » (avec espace final) et «  c » (espace initial) sont bruts.
    try std.testing.expectEqualStrings(
        \\Program
        \\  ExpressionStatement
        \\    JSXElement
        \\      JSXOpeningElement
        \\        JSXIdentifier div
        \\      JSXText "a "
        \\      JSXExpressionContainer
        \\        Identifier b
        \\      JSXText " c"
        \\      JSXClosingElement
        \\        JSXIdentifier div
        \\
    , tree);
}

test "JSX : conteneur vide {} et {/* commentaire */} (expression null)" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), try errorCountOfJsx(gpa, "<div>{}{/* c */}</div>;"));
}

test "JSX : balise fermante qui ne matche pas -> 1 diagnostic" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try errorCountOfJsx(gpa, "<span>x</div>;"));
    // Deux erreurs distantes : les deux rapportées, le milieu survit.
    try std.testing.expectEqual(@as(usize, 2), try errorCountOfJsx(gpa, "const a = <A></B>;\nlet ok = 1;\nconst c = <X></Y>;"));
}

test "JSX OFF : `a < b` reste une BinaryExpression (non-régression sacrée)" {
    const gpa = std.testing.allocator;
    // jsx off (parse normal) : `<` = opérateur relationnel.
    const tree = try programTreeOf(gpa, "a < b;");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        \\Program
        \\  ExpressionStatement
        \\    BinaryExpression "<"
        \\      Identifier a
        \\      Identifier b
        \\
    , tree);
    // jsx ON : `a < b` (a est un identifiant -> position d'opérateur) reste binaire.
    const tree2 = try programTreeOfJsx(gpa, "a < b;");
    defer gpa.free(tree2);
    try std.testing.expectEqualStrings(tree, tree2);
}

test "JSX : composant local référencé par <A/> (semantic) survit au mangle" {
    const gpa = std.testing.allocator;
    // La règle majuscule : <A/> est une RÉFÉRENCE à A -> A n'est pas unresolved.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const src = "function f() { const App = () => 1; return <App/>; }";
    const r = try parseWith(arena.allocator(), src, true, false);
    try std.testing.expectEqual(@as(usize, 0), r.errors.len);
}

// ------------------------------------------------------------------ tests TypeScript

fn errorCountOfTs(gpa: std.mem.Allocator, source: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseWith(arena.allocator(), source, false, true);
    return r.errors.len;
}
fn programTreeOfTs(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseWith(arena.allocator(), source, false, true);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try printTree(r.program, source, &out, gpa);
    return out.toOwnedSlice(gpa);
}

test "TS : constructions variées parsent sans erreur (ts on)" {
    const gpa = std.testing.allocator;
    const ok = [_][]const u8{
        "let x: number = 1;",
        "function f(a: string, b?: number): void {}",
        "type A<T> = { x: number; y?: string } | T[] | (() => void);",
        "interface I extends J, K { readonly r: T; m(x: A): B; }",
        "const fn = (x: T): U => x;",
        "const y = x as unknown as T;",
        "const z = o satisfies R;",
        "a! + b!;",
        "let t: [string, ...number[]];",
        "let u: Map<string, Array<number>>;", // génériques imbriqués (>>)
        "class C<T extends B> extends D implements I { private x: T = a; m<U>(v: U): T { return v; } }",
        "function g<T, R = T>(x: T): R { return x; }",
        "try { a(); } catch (e: unknown) { b(); }",
        "let k: keyof typeof obj;",
        "type N = number | \"a\" | 1 | true | null;",
    };
    for (ok) |src| {
        try std.testing.expectEqual(@as(usize, 0), errorCountOfTs(gpa, src));
    }
}

test "TS : `let x: number` est une ERREUR en mode js (non-régression)" {
    const gpa = std.testing.allocator;
    // ts OFF : `:` après un identifiant de déclaration n'est PAS valide -> erreur.
    try std.testing.expect((try errorCountOf(gpa, "let x: number = 1;")) >= 1);
    // Et l'AST js reste bit-identique : `a < b` est une comparaison (comme avant).
    const t = try programTreeOf(gpa, "a < b;");
    defer gpa.free(t);
    try std.testing.expect(std.mem.indexOf(u8, t, "BinaryExpression") != null);
}

test "TS : annotation -> ts_typed, `as` -> ts_as_expression dans l'arbre" {
    const gpa = std.testing.allocator;
    const tree = try programTreeOfTs(gpa, "let x: number = 1;");
    defer gpa.free(tree);
    try std.testing.expect(std.mem.indexOf(u8, tree, "TsTyped") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree, "TsKeywordType") != null);
    const t2 = try programTreeOfTs(gpa, "y = x as T;");
    defer gpa.free(t2);
    try std.testing.expect(std.mem.indexOf(u8, t2, "TsAsExpression") != null);
}

// ---- tests TypeScript phase 2 : génériques d'appel (spéculation) ----

test "TS2 : appel générique -> CallExpression avec TypeArgs" {
    const gpa = std.testing.allocator;
    const t = try programTreeOfTs(gpa, "foo<T>(x);");
    defer gpa.free(t);
    try std.testing.expect(std.mem.indexOf(u8, t, "CallExpression") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "TypeArgs") != null);
}

test "TS2 : la spéculation rembobine -> les comparaisons restent des BinaryExpression" {
    const gpa = std.testing.allocator;
    // Aucune de ces formes ne doit produire de TypeArgs (le `<` reste `<`).
    const cmp = [_][]const u8{ "a < b;", "a < b > c;", "f(a < b, c > d);", "if (x < y) z;" };
    for (cmp) |src| {
        const t = try programTreeOfTs(gpa, src);
        defer gpa.free(t);
        try std.testing.expect(std.mem.indexOf(u8, t, "TypeArgs") == null);
        try std.testing.expect(std.mem.indexOf(u8, t, "BinaryExpression") != null);
    }
    // Et zéro diagnostic (la spéculation ratée ne laisse aucune trace).
    try std.testing.expectEqual(@as(usize, 0), try errorCountOfTs(gpa, "f(a < b, c > d);"));
}

test "TS2 : new générique, indexed access, index signature, import type parsent" {
    const gpa = std.testing.allocator;
    const ok = [_][]const u8{
        "const m = new Map<string, number[]>();",
        "type V = Config[\"host\"]; type W = O[K];",
        "type D = { [k: string]: number; readonly [i: number]: string };",
        "import type { A } from \"m\"; import { type B, C } from \"n\"; C;",
        "export type { A, B }; export { type C, d };",
        "const r = f<A>(x)<B>(y);", // appels génériques chaînés
    };
    for (ok) |src| try std.testing.expectEqual(@as(usize, 0), errorCountOfTs(gpa, src));
}

test "TS2 : le `<` générique reste inerte en mode JS (non-régression)" {
    const gpa = std.testing.allocator;
    const t = try programTreeOf(gpa, "foo < T > (x);"); // js : deux comparaisons
    defer gpa.free(t);
    try std.testing.expect(std.mem.indexOf(u8, t, "TypeArgs") == null);
    try std.testing.expect(std.mem.indexOf(u8, t, "BinaryExpression") != null);
}
