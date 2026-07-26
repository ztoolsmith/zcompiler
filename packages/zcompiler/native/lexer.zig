//! Le lexer : logique Zig pure, sans aucune dépendance N-API.
//! Testable seul avec `zig build test`.
//!
//! Inspiré d'OXC (oxc_parser/src/lexer) :
//!  - `TokenKind` a un variant par lexème exact (mots-clés, opérateurs — y
//!    compris les multi-caractères comme `===`).
//!  - `Token` ne stocke qu'un span (`start`/`end`, offsets bytes u32) — pas de
//!    texte copié. Le texte s'obtient via `Token.text(source)`.
//!  - Le découpage se fait par "maximal munch" : on lit le plus long lexème
//!    possible en regardant les caractères suivants (peek).

const std = @import("std");

pub const TokenKind = enum {
    // Littéraux / identifiants
    identifier,
    private_name, // #x (champ/méthode privé de classe) — le `#` est inclus
    number,
    bigint, // 123n, 0xFFn (suffixe n sur un entier)
    /// Littéral de chaîne, guillemets inclus. Les échappements ne sont PAS
    /// décodés ici (comme OXC : le décodage vient plus tard).
    string,
    /// Caractère non reconnu (pas encore géré). Garde le lexer total.
    unknown,

    // Mots-clés JS (cf. `keywords`)
    kw_const,
    kw_let,
    kw_var,
    kw_function,
    kw_return,
    kw_if,
    kw_else,
    kw_for,
    kw_while,
    kw_class,
    kw_new,
    kw_import,
    kw_export,
    kw_default,
    kw_true,
    kw_false,
    kw_null,
    kw_undefined,
    kw_this,
    kw_super,
    kw_typeof,
    kw_in,
    kw_extends,
    kw_static, // contextuel en vrai JS ; traité en mot-clé (raccourci)
    kw_throw,
    kw_try,
    kw_catch,
    kw_finally,
    kw_switch,
    kw_case,
    kw_break,
    kw_continue,
    kw_do,
    kw_instanceof,
    kw_void,
    kw_delete,

    // Ponctuation sans variante multi-caractère
    l_paren, // (
    r_paren, // )
    l_brace, // {
    r_brace, // }
    l_bracket, // [
    r_bracket, // ]
    semicolon, // ;
    comma, // ,
    dot, // .
    dot_dot_dot, // ... (spread / rest)
    colon, // :
    percent, // %
    caret, // ^
    tilde, // ~

    // Opérateurs avec variantes multi-caractères (maximal munch)
    eq, // =
    eq_eq, // ==
    strict_eq, // ===
    arrow, // =>
    bang, // !
    neq, // !=
    strict_neq, // !==
    lt, // <
    lt_eq, // <=
    gt, // >
    gt_eq, // >=
    plus, // +
    plus_eq, // +=
    plus_plus, // ++
    minus, // -
    minus_eq, // -=
    minus_minus, // --
    star, // *
    star_eq, // *=
    star_star, // **
    slash, // /
    slash_eq, // /=
    amp, // &
    amp_amp, // &&
    pipe, // |
    pipe_pipe, // ||
    question, // ?
    question_question, // ??
    question_dot, // ?.
    shl, // <<
    shr, // >>
    ushr, // >>>
    shl_eq, // <<=
    shr_eq, // >>=
    ushr_eq, // >>>=
    pipe_eq, // |=
    amp_eq, // &=
    caret_eq, // ^=
    amp_amp_eq, // &&=
    pipe_pipe_eq, // ||=
    question_question_eq, // ??=

    // Template literals. Le span du token couvre les délimiteurs ; le parser
    // extrait le texte brut interne (sans `` ` ``, `${`, `}`).
    template_full, // `abc`
    template_head, // `abc${
    template_middle, // }abc${
    template_tail, // }abc`

    regex, // /pattern/flags

    // JSX (opt-in). Le texte brut entre balises ; le reste du JSX réutilise les
    // tokens JS (lt/gt/slash/l_brace/r_brace/identifier/eq/dot/colon/string).
    jsx_text,
};

/// Table figée au comptime : mot exact -> mot-clé (lookup en une passe, matche
/// le mot entier, pas un préfixe).
const keywords = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "const", .kw_const },
    .{ "let", .kw_let },
    .{ "var", .kw_var },
    .{ "function", .kw_function },
    .{ "return", .kw_return },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "for", .kw_for },
    .{ "while", .kw_while },
    .{ "class", .kw_class },
    .{ "new", .kw_new },
    .{ "import", .kw_import },
    .{ "export", .kw_export },
    .{ "default", .kw_default },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "null", .kw_null },
    // `undefined` n'est PAS un mot-clé JS -> reste un identifiant.
    .{ "this", .kw_this },
    .{ "super", .kw_super },
    .{ "typeof", .kw_typeof },
    .{ "in", .kw_in },
    .{ "extends", .kw_extends },
    .{ "static", .kw_static },
    .{ "throw", .kw_throw },
    .{ "try", .kw_try },
    .{ "catch", .kw_catch },
    .{ "finally", .kw_finally },
    .{ "switch", .kw_switch },
    .{ "case", .kw_case },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
    .{ "do", .kw_do },
    .{ "instanceof", .kw_instanceof },
    .{ "void", .kw_void },
    .{ "delete", .kw_delete },
});

/// Début d'identifiant ASCII : lettre, `_` ou `$`.
fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}
fn isBinDigit(c: u8) bool {
    return c == '0' or c == '1';
}
fn isOctDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}
/// Suite d'identifiant ASCII : idem + chiffres.
fn isIdentContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

// --- Unicode (raccourci assumé, cf. CLAUDE.md « Unicode ») ---
// La vraie règle ECMAScript utilise les propriétés ID_Start/ID_Continue (tables
// énormes). RACCOURCI : tout code point >= U+0080 est accepté en start ET en
// continue, SAUF les espaces/séparateurs Unicode. Accepte 100 % des identifiants
// valides (café, 変数, Ω, émojis) ; SUR-ACCEPTE quelques cas invalides (`¿x`,
// émojis qui ne sont pas ID_Start en vrai) — cohérent avec un parser sans early
// errors complets. Les vraies tables : le jour de la conformité Test262.

/// Espace / séparateur Unicode (non-ASCII). U+2028/U+2029 = terminateurs de ligne.
fn isUnicodeSpace(cp: u21) bool {
    return switch (cp) {
        0x00A0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        0x2000...0x200A => true,
        else => false,
    };
}

/// Un code point peut-il commencer/continuer un identifiant ?
fn identStartCp(cp: u21) bool {
    if (cp < 0x80) return isIdentStart(@intCast(cp));
    return !isUnicodeSpace(cp);
}
fn identContinueCp(cp: u21) bool {
    if (cp < 0x80) return isIdentContinue(@intCast(cp));
    return !isUnicodeSpace(cp);
}

/// Valeur d'un chiffre hexadécimal, ou null.
fn hexValue(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Un token : sa nature + son span dans le source (offsets bytes, u32).
/// Pas de champ texte : il référence le source, il ne le copie pas.
pub const Token = struct {
    kind: TokenKind,
    start: u32,
    end: u32,
    /// Vrai si au moins un saut de ligne (y compris dans un commentaire) sépare
    /// ce token du précédent. Base de l'ASI (insertion de `;` automatique).
    newline_before: bool = false,
    /// Nom DÉCODÉ d'un identifiant contenant des échappements `\u` (ex. `Abc`
    /// -> "Abc"), alloué dans l'arena. `null` = le nom est le span brut (cas
    /// courant). Le parser le propage en `synthetic_text` sur le nœud identifiant.
    cooked: ?[]const u8 = null,

    /// La tranche du source couverte par ce token : `source[start..end]`.
    pub fn text(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// Détail d'erreur de lexing (message statique + offset).
pub const Diagnostic = struct {
    message: []const u8 = "",
    pos: u32 = 0,
};

/// Contexte de lexing JSX (sommet de `jsx_stack`) :
///  - `tag` : entre `<` et `>` (balise ouvrante/fermante/auto-fermante) ;
///  - `children` : entre le `>` d'une ouvrante et la fermante -> JSXText ;
///  - `expr` : conteneur `{…}` d'expression -> lexing JS normal jusqu'au `}` apparié.
const JsxCtx = enum { tag, children, expr };
/// Une frame de la pile JSX. `brace` : profondeur d'accolades du conteneur `expr`
/// (pour retrouver le `}` apparié, comme `template_stack`). `saw_name`/`closing`/
/// `self_close` : état d'une balise en cours (décide la transition sur `>`).
const JsxFrame = struct {
    ctx: JsxCtx,
    brace: u32 = 0,
    saw_name: bool = false,
    closing: bool = false,
    self_close: bool = false,
};

/// Curseur sur le source, avec lookahead. Toutes les décisions passent par
/// `peek`/`match`.
const Lexer = struct {
    source: []const u8,
    pos: u32 = 0,
    diag: *Diagnostic,
    // Arena (pour allouer le nom décodé des identifiants avec échappements `\u`).
    allocator: std.mem.Allocator = undefined,
    // Coopération template/lexer : `brace_depth` = profondeur des `{}` ;
    // `template_stack` = profondeur d'entrée de chaque interpolation `${` active.
    brace_depth: u32 = 0,
    template_stack: [64]u32 = undefined,
    template_depth: usize = 0,
    // Dernier token émis : décide si `/` est une division ou une regex.
    last_kind: ?TokenKind = null,
    // Un saut de ligne a-t-il été vu depuis le dernier token émis ? (pour l'ASI)
    pending_newline: bool = false,
    // JSX (opt-in). Le lexer gagne des modes pilotés par une pile de contextes,
    // exactement comme les templates (cf. CLAUDE.md « JSX »). Quand `jsx == false`
    // (défaut), toute cette machinerie est INERTE -> comportement bit-identique.
    jsx: bool = false,
    jsx_stack: [64]JsxFrame = undefined,
    jsx_sp: usize = 0,

    fn tmplPush(self: *Lexer, depth: u32) void {
        if (self.template_depth < self.template_stack.len) self.template_stack[self.template_depth] = depth;
        self.template_depth += 1;
    }
    fn tmplTop(self: *const Lexer) u32 {
        return self.template_stack[@min(self.template_depth, self.template_stack.len) - 1];
    }
    fn tmplPop(self: *Lexer) void {
        if (self.template_depth > 0) self.template_depth -= 1;
    }

    // ---- JSX (pile de contextes, cf. JsxCtx) ----
    /// Contexte JSX courant (sommet de pile), ou null (JS pur).
    fn jsxCtx(self: *const Lexer) ?JsxCtx {
        return if (self.jsx_sp > 0) self.jsx_stack[self.jsx_sp - 1].ctx else null;
    }
    fn jsxTopPtr(self: *Lexer) *JsxFrame {
        return &self.jsx_stack[self.jsx_sp - 1];
    }
    fn jsxPush(self: *Lexer, ctx: JsxCtx) void {
        if (self.jsx_sp < self.jsx_stack.len) self.jsx_stack[self.jsx_sp] = .{ .ctx = ctx };
        self.jsx_sp += 1;
    }
    fn jsxPop(self: *Lexer) void {
        if (self.jsx_sp > 0) self.jsx_sp -= 1;
    }
    /// Ouvre un conteneur d'expression `{…}` : le `{` a déjà incrémenté
    /// `brace_depth` ; on retient cette profondeur pour repérer le `}` apparié.
    fn jsxPushExpr(self: *Lexer) void {
        self.jsxPush(.expr);
        if (self.jsx_sp <= self.jsx_stack.len) self.jsx_stack[self.jsx_sp - 1].brace = self.brace_depth;
    }
    /// Le `}` courant ferme-t-il le conteneur d'expression JSX du sommet ?
    fn jsxClosesExpr(self: *const Lexer) bool {
        if (self.jsx_sp == 0) return false;
        const top = self.jsx_stack[self.jsx_sp - 1];
        return top.ctx == .expr and self.brace_depth == top.brace;
    }

    /// Un token de mode « enfants JSX » : soit `<` (nouvelle balise / fermante),
    /// soit `{` (conteneur d'expression), soit un run de JSXText (verbatim, sans
    /// trimming : les blancs/newlines sont significatifs -> pas de skip whitespace).
    fn lexJsxChild(self: *Lexer) Token {
        const c = self.peek().?;
        if (c == '<') {
            const t = self.singleToken(.lt);
            self.jsxPush(.tag);
            return t;
        }
        if (c == '{') {
            self.brace_depth += 1;
            const t = self.singleToken(.l_brace);
            self.jsxPushExpr();
            return t;
        }
        const start = self.pos;
        while (self.peek()) |ch| {
            if (ch == '<' or ch == '{') break;
            self.advance();
        }
        return .{ .kind = .jsx_text, .start = start, .end = self.pos };
    }

    /// Un token de mode « balise JSX » (`<…>`). Les blancs y sont INSIGNIFIANTS
    /// (sautés par l'appelant). Décide les transitions de pile sur `>`.
    fn lexJsxTag(self: *Lexer) !Token {
        const c = self.peek().?;
        const top = self.jsxTopPtr();
        switch (c) {
            '>' => {
                const t = self.singleToken(.gt);
                if (top.self_close) {
                    self.jsxPop(); // <br/> : balise terminée, le parent reprend
                } else if (top.closing) {
                    self.jsxPop(); // la balise fermante
                    self.jsxPop(); // + le contexte `children` de l'élément fermé
                } else {
                    top.ctx = .children; // ouvrante -> on entre dans les enfants
                    top.saw_name = false;
                }
                return t;
            },
            '/' => {
                if (top.saw_name) top.self_close = true else top.closing = true;
                return self.singleToken(.slash);
            },
            '{' => {
                self.brace_depth += 1;
                const t = self.singleToken(.l_brace);
                self.jsxPushExpr();
                return t;
            },
            '=' => return self.singleToken(.eq),
            ':' => return self.singleToken(.colon),
            '.' => return self.singleToken(.dot),
            '"', '\'' => return self.string(),
            '<' => return self.singleToken(.lt), // invalide dans un tag : le parser récupère
            else => {
                if (self.jsxNameStartHere()) {
                    top.saw_name = true;
                    return self.jsxName();
                }
                return self.operator(); // repli (caractère inattendu dans un tag)
            },
        }
    }

    /// Un nom JSX commence-t-il ici ? (lettre ASCII / `_` / `$` / non-ASCII)
    fn jsxNameStartHere(self: *const Lexer) bool {
        const c = self.peek() orelse return false;
        if (c < 0x80) return isIdentStart(c);
        return true; // non-ASCII : optimiste
    }

    /// Après un `<` en position d'expression, est-ce vraiment du JSX ? Le caractère
    /// suivant doit être un début de nom, `>` (fragment) — sinon c'est `<`/`<=`/`<<`.
    fn jsxStartsHere(self: *const Lexer) bool {
        const n = self.peekAt(1) orelse return false;
        return n >= 0x80 or isIdentStart(n) or n == '>';
    }

    /// Lit un nom JSX : comme un identifiant mais AVEC le tiret (`data-foo`,
    /// `aria-label`) et SANS résolution de mot-clé (`<for>`, `key` sont des noms
    /// JSX valides). Émis en `identifier` ; le parser en fait un `jsx_identifier`.
    fn jsxName(self: *Lexer) Token {
        const start = self.pos;
        while (self.peek()) |ch| {
            if (ch < 0x80) {
                if (isIdentContinue(ch) or ch == '-') self.advance() else break;
            } else {
                const width = std.unicode.utf8ByteSequenceLength(ch) catch break;
                if (self.pos + width > self.source.len) break;
                const cp = std.unicode.utf8Decode(self.source[self.pos .. self.pos + width]) catch break;
                if (isUnicodeSpace(cp)) break;
                self.pos += width;
            }
        }
        return .{ .kind = .identifier, .start = start, .end = self.pos };
    }

    /// Décide si un `/` démarre une regex, d'après le dernier token émis :
    /// division si le dernier token peut TERMINER une expression, sinon regex.
    /// Choix documenté : `r_brace` -> regex (le cas statement `}` domine).
    fn regexAllowed(self: *const Lexer) bool {
        const k = self.last_kind orelse return true; // début de source -> regex
        return switch (k) {
            .identifier, .private_name, .number, .bigint, .string, .regex, .template_full, .template_tail, .r_paren, .r_bracket, .kw_this, .kw_true, .kw_false, .kw_null, .plus_plus, .minus_minus => false, // division
            else => true, // regex
        };
    }

    /// Lit un littéral regex `/pattern/flags`. `\` échappe ; dans `[...]` le `/`
    /// ne ferme pas ; une fin de ligne non échappée est une erreur.
    fn readRegex(self: *Lexer) !Token {
        const start = self.pos;
        self.advance(); // `/` ouvrant
        var in_class = false;
        while (self.peek()) |c| {
            switch (c) {
                '\\' => {
                    self.advance();
                    if (self.peek() == null) break;
                    self.advance();
                },
                '[' => {
                    in_class = true;
                    self.advance();
                },
                ']' => {
                    in_class = false;
                    self.advance();
                },
                '/' => {
                    if (in_class) {
                        self.advance();
                    } else {
                        self.advance(); // `/` fermant
                        while (self.peek()) |f| : (self.advance()) {
                            if (!isIdentContinue(f)) break; // flags gimsuy…
                        }
                        return .{ .kind = .regex, .start = start, .end = self.pos };
                    }
                },
                '\n', '\r' => {
                    self.setDiag("unterminated regular expression (newline)", start);
                    return error.UnterminatedRegex;
                },
                else => self.advance(),
            }
        }
        self.setDiag("unterminated regular expression", start);
        return error.UnterminatedRegex;
    }

    /// Émet un token d'un seul caractère au curseur.
    fn singleToken(self: *Lexer, kind: TokenKind) Token {
        const start = self.pos;
        self.advance();
        return .{ .kind = kind, .start = start, .end = self.pos };
    }

    /// Lit un morceau de template à partir de `self.pos` (juste après le
    /// délimiteur ouvrant : `` ` `` pour full/head, `}` pour middle/tail),
    /// jusqu'à `` ` `` (full/tail) ou `${` (head/middle -> push le stack).
    /// `\` échappe le caractère suivant. Erreur si non fermé.
    fn readTemplate(self: *Lexer, start: u32, opened_with_backtick: bool) !Token {
        while (self.peek()) |c| {
            switch (c) {
                '\\' => {
                    self.advance();
                    if (self.peek() == null) break;
                    self.advance();
                },
                '`' => {
                    self.advance();
                    return .{ .kind = if (opened_with_backtick) .template_full else .template_tail, .start = start, .end = self.pos };
                },
                '$' => {
                    if (self.peekAt(1) == '{') {
                        self.advance(); // $
                        self.advance(); // {
                        self.tmplPush(self.brace_depth);
                        return .{ .kind = if (opened_with_backtick) .template_head else .template_middle, .start = start, .end = self.pos };
                    }
                    self.advance();
                },
                else => self.advance(),
            }
        }
        self.setDiag("unterminated template literal", start);
        return error.UnterminatedTemplate;
    }

    fn peek(self: Lexer) ?u8 {
        return if (self.pos < self.source.len) self.source[self.pos] else null;
    }

    fn peekAt(self: Lexer, offset: u32) ?u8 {
        const i = self.pos + offset;
        return if (i < self.source.len) self.source[i] else null;
    }

    fn advance(self: *Lexer) void {
        self.pos += 1;
    }

    /// Consomme le caractère courant s'il vaut `expected`. Cœur du maximal munch.
    fn match(self: *Lexer, expected: u8) bool {
        if (self.peek() == expected) {
            self.advance();
            return true;
        }
        return false;
    }

    fn setDiag(self: *Lexer, message: []const u8, pos: u32) void {
        self.diag.message = message;
        self.diag.pos = pos;
    }

    fn digitAtOffset(self: Lexer, offset: u32) bool {
        if (self.peekAt(offset)) |n| return std.ascii.isDigit(n);
        return false;
    }

    /// Consomme une suite de chiffres valides (`isDigit`) avec séparateurs `_`
    /// (lenient : `_` seulement entre deux chiffres valides).
    fn consumeRadix(self: *Lexer, comptime isDigit: fn (u8) bool) void {
        while (self.peek()) |c| {
            if (isDigit(c)) {
                self.advance();
            } else if (c == '_' and self.peekAt(1) != null and isDigit(self.peekAt(1).?)) {
                self.advance();
            } else break;
        }
    }

    /// Lit un nombre : `123`, `0xFF`/`0b101`/`0o17`, `.5`, `1.`, `1e3`,
    /// `2.5e-7`, séparateurs `1_000`. (Décodage de la valeur : plus tard.)
    fn number(self: *Lexer) !Token {
        const start = self.pos;
        if (self.peek() == '0') {
            if (self.peekAt(1)) |p| switch (p) {
                'x', 'X' => {
                    self.advance();
                    self.advance();
                    self.consumeRadix(std.ascii.isHex);
                    return self.finishNumber(start, true);
                },
                'b', 'B' => {
                    self.advance();
                    self.advance();
                    self.consumeRadix(isBinDigit);
                    return self.finishNumber(start, true);
                },
                'o', 'O' => {
                    self.advance();
                    self.advance();
                    self.consumeRadix(isOctDigit);
                    return self.finishNumber(start, true);
                },
                else => {},
            };
        }
        var is_int = true;
        self.consumeRadix(std.ascii.isDigit); // partie entière (vide pour `.5`)
        if (self.peek() == '.') {
            is_int = false;
            self.advance();
            self.consumeRadix(std.ascii.isDigit);
        }
        if (self.peek()) |e| if (e == 'e' or e == 'E') {
            is_int = false;
            self.advance();
            if (self.peek()) |s| if (s == '+' or s == '-') self.advance();
            self.consumeRadix(std.ascii.isDigit);
        };
        return self.finishNumber(start, is_int);
    }

    /// Applique le suffixe BigInt `n` : autorisé seulement sur un entier
    /// (`123n`, `0xFFn`), erreur sur un décimal/scientifique (`1.5n`, `1e3n`).
    fn finishNumber(self: *Lexer, start: u32, is_int: bool) !Token {
        if (self.peek() == 'n') {
            if (!is_int) {
                self.setDiag("invalid BigInt literal (fractional or exponent)", start);
                return error.InvalidBigInt;
            }
            self.advance(); // 'n'
            return .{ .kind = .bigint, .start = start, .end = self.pos };
        }
        return .{ .kind = .number, .start = start, .end = self.pos };
    }

    /// Lit un identifiant, puis le résout en mot-clé si c'en est un.
    /// Si le curseur est sur un espace/séparateur Unicode, renvoie sa largeur en
    /// bytes + si c'est un terminateur de ligne (U+2028/U+2029, pour l'ASI).
    fn unicodeSpaceHere(self: *const Lexer) ?struct { len: u32, line: bool } {
        const c = self.peek() orelse return null;
        if (c < 0x80) return null;
        const width = std.unicode.utf8ByteSequenceLength(c) catch return null;
        if (self.pos + width > self.source.len) return null;
        const cp = std.unicode.utf8Decode(self.source[self.pos .. self.pos + width]) catch return null;
        if (!isUnicodeSpace(cp)) return null;
        return .{ .len = width, .line = (cp == 0x2028 or cp == 0x2029) };
    }

    /// Un identifiant commence-t-il à la position courante ? (ASCII, non-ASCII, ou
    /// échappement `\u`). Le décodage/validation réels se font dans le lecteur.
    fn identStartHere(self: *const Lexer) bool {
        const c = self.peek() orelse return false;
        if (c < 0x80) return isIdentStart(c) or (c == '\\' and self.peekAt(1) == 'u');
        return true; // non-ASCII : optimiste (le lecteur valide / erreur UTF-8)
    }

    fn identifierOrKeyword(self: *Lexer) !Token {
        const start = self.pos;
        // Fast path : identifiant pur ASCII (le cas ultra-courant, zéro copie).
        while (self.peek()) |c| {
            if (c < 0x80 and isIdentContinue(c)) {
                self.advance();
                continue;
            }
            if (c == '\\' or c >= 0x80) return self.identifierSlow(start); // échappement / unicode
            break;
        }
        const word = self.source[start..self.pos];
        return .{ .kind = keywords.get(word) orelse .identifier, .start = start, .end = self.pos };
    }

    /// Chemin lent : l'identifiant contient de l'Unicode et/ou des échappements
    /// `\u`. On décode le NOM complet (UTF-8) dans un buffer ; s'il y a un
    /// échappement, on l'alloue dans l'arena et le token porte ce `cooked`.
    fn identifierSlow(self: *Lexer, start: u32) !Token {
        self.pos = start; // on relit tout depuis le début
        var buf: [1024]u8 = undefined;
        var len: usize = 0;
        var has_escape = false;
        var first = true;
        while (self.peek()) |c| {
            var cp: u21 = undefined;
            var width: u32 = undefined;
            if (c == '\\') {
                if (self.peekAt(1) != 'u') break; // `\` hors `\u` : fin d'identifiant
                cp = try self.readUnicodeEscape(start);
                has_escape = true;
                width = 0; // déjà avancé par readUnicodeEscape
            } else if (c < 0x80) {
                cp = c;
                width = 1;
            } else {
                width = std.unicode.utf8ByteSequenceLength(c) catch return self.utfError();
                if (self.pos + width > self.source.len) return self.utfError();
                cp = std.unicode.utf8Decode(self.source[self.pos .. self.pos + width]) catch return self.utfError();
            }
            if (!(if (first) identStartCp(cp) else identContinueCp(cp))) {
                if (c == '\\') { // `\uXXXX` non valide en position d'identifiant
                    self.setDiag("invalid unicode escape in identifier", start);
                    return error.InvalidUnicodeEscape;
                }
                break;
            }
            // Encode le code point dans le buffer (nom décodé).
            if (len + 4 > buf.len) {
                self.setDiag("identifier too long", start);
                return error.InvalidUnicodeEscape;
            }
            len += std.unicode.utf8Encode(cp, buf[len..]) catch return self.utfError();
            if (width > 0) self.pos += width;
            first = false;
        }
        const name = buf[0..len];
        // Mot-clé : lookup sur le nom DÉCODÉ. Un mot-clé échappé (`if`) est
        // interdit par la spec.
        if (keywords.get(name)) |kw| {
            if (has_escape) {
                self.setDiag("keyword cannot contain an escape sequence", start);
                return error.EscapedKeyword;
            }
            return .{ .kind = kw, .start = start, .end = self.pos };
        }
        const cooked: ?[]const u8 = if (has_escape) (self.allocator.dupe(u8, name) catch null) else null;
        return .{ .kind = .identifier, .start = start, .end = self.pos, .cooked = cooked };
    }

    fn utfError(self: *Lexer) error{InvalidUtf8} {
        self.setDiag("invalid UTF-8 byte", self.pos);
        return error.InvalidUtf8;
    }

    /// Lit `\uXXXX` (4 hex) ou `\u{X..}` (1-6 hex) au curseur (`\` puis `u`),
    /// avance au-delà, renvoie le code point. Erreurs : hex incomplet, > 0x10FFFF,
    /// surrogate.
    fn readUnicodeEscape(self: *Lexer, err_pos: u32) !u21 {
        self.advance(); // '\'
        self.advance(); // 'u'
        var cp: u32 = 0;
        if (self.peek() == '{') {
            self.advance(); // '{'
            var any = false;
            while (self.peek()) |c| {
                if (c == '}') break;
                const d = hexValue(c) orelse return self.escapeError(err_pos);
                cp = cp * 16 + d;
                if (cp > 0x10FFFF) return self.escapeError(err_pos);
                any = true;
                self.advance();
            }
            if (!any or self.peek() != '}') return self.escapeError(err_pos);
            self.advance(); // '}'
        } else {
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                const c = self.peek() orelse return self.escapeError(err_pos);
                const d = hexValue(c) orelse return self.escapeError(err_pos);
                cp = cp * 16 + d;
                self.advance();
            }
        }
        // Surrogate isolé : refusé (les paires `😀` — rares en
        // identifiant — ne sont pas gérées ; utiliser `\u{...}`).
        if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return self.escapeError(err_pos);
        return @intCast(cp);
    }

    fn escapeError(self: *Lexer, pos: u32) error{InvalidUnicodeEscape} {
        self.setDiag("invalid unicode escape", pos);
        return error.InvalidUnicodeEscape;
    }

    /// Nom privé de classe `#x` : le `#` puis un identifiant. Le span inclut `#`.
    fn privateName(self: *Lexer) Token {
        const start = self.pos;
        self.advance(); // '#'
        while (self.peek()) |c| : (self.advance()) {
            if (!isIdentContinue(c)) break;
        }
        return .{ .kind = .private_name, .start = start, .end = self.pos };
    }

    /// Lit un littéral de chaîne, guillemets inclus, sans décoder les
    /// échappements. Erreur si non fermé avant une fin de ligne ou l'EOF.
    fn string(self: *Lexer) !Token {
        const start = self.pos;
        const quote = self.source[self.pos];
        self.advance(); // guillemet ouvrant
        while (self.peek()) |c| {
            switch (c) {
                '\\' => {
                    self.advance();
                    if (self.peek() == null) break; // `\` en fin de source
                    self.advance();
                },
                '\n', '\r' => {
                    self.setDiag("unterminated string literal", start);
                    return error.UnterminatedString;
                },
                else => {
                    self.advance();
                    if (c == quote) return .{ .kind = .string, .start = start, .end = self.pos };
                },
            }
        }
        self.setDiag("unterminated string literal", start);
        return error.UnterminatedString;
    }

    /// Saute un commentaire (`//` ou `/* */`) : aucun token. Erreur si un `/*`
    /// n'est jamais fermé. Précondition : `//` ou `/*` en cours.
    fn skipComment(self: *Lexer) !void {
        if (self.peekAt(1) == '/') {
            self.advance(); // /
            self.advance(); // /
            while (self.peek()) |c| : (self.advance()) {
                if (c == '\n') break; // la fin de ligne sera mangée comme espace
            }
        } else {
            const start = self.pos;
            self.advance(); // /
            self.advance(); // *
            while (self.peek()) |c| {
                if (c == '*' and self.peekAt(1) == '/') {
                    self.advance(); // *
                    self.advance(); // /
                    return;
                }
                // Un saut de ligne DANS un commentaire bloc compte pour l'ASI.
                if (c == '\n' or c == '\r') self.pending_newline = true;
                self.advance();
            }
            self.setDiag("unterminated block comment", start);
            return error.UnterminatedComment;
        }
    }

    /// Lit un opérateur / une ponctuation en prenant le plus long lexème
    /// possible (maximal munch).
    fn operator(self: *Lexer) Token {
        const start = self.pos;
        const c = self.source[self.pos];
        self.advance();
        const kind: TokenKind = switch (c) {
            '=' => if (self.match('=')) (if (self.match('=')) .strict_eq else .eq_eq) else if (self.match('>')) .arrow else .eq,
            '!' => if (self.match('=')) (if (self.match('=')) .strict_neq else .neq) else .bang,
            '<' => if (self.match('=')) .lt_eq else if (self.match('<')) (if (self.match('=')) .shl_eq else .shl) else .lt,
            '>' => if (self.match('=')) .gt_eq else if (self.match('>'))
                (if (self.match('>')) (if (self.match('=')) .ushr_eq else .ushr) else (if (self.match('=')) .shr_eq else .shr))
            else
                .gt,
            '+' => if (self.match('=')) .plus_eq else if (self.match('+')) .plus_plus else .plus,
            '-' => if (self.match('=')) .minus_eq else if (self.match('-')) .minus_minus else .minus,
            '*' => if (self.match('=')) .star_eq else if (self.match('*')) .star_star else .star,
            '/' => if (self.match('=')) .slash_eq else .slash,
            '&' => if (self.match('&')) (if (self.match('=')) .amp_amp_eq else .amp_amp) else if (self.match('=')) .amp_eq else .amp,
            '|' => if (self.match('|')) (if (self.match('=')) .pipe_pipe_eq else .pipe_pipe) else if (self.match('=')) .pipe_eq else .pipe,
            '?' => if (self.match('?')) (if (self.match('=')) .question_question_eq else .question_question) else if (self.match('.')) .question_dot else .question,
            '%' => .percent,
            '^' => if (self.match('=')) .caret_eq else .caret,
            '~' => .tilde,
            '(' => .l_paren,
            ')' => .r_paren,
            '{' => .l_brace,
            '}' => .r_brace,
            '[' => .l_bracket,
            ']' => .r_bracket,
            ';' => .semicolon,
            ',' => .comma,
            // `...` en un token ; `..` (deux points) reste deux `dot`.
            '.' => if (self.peek() == '.' and self.peekAt(1) == '.') blk: {
                self.advance();
                self.advance();
                break :blk .dot_dot_dot;
            } else .dot,
            ':' => .colon,
            else => .unknown,
        };
        return .{ .kind = kind, .start = start, .end = self.pos };
    }
};

/// Tokenize `source`. En cas d'erreur de lexing, remplit `diag` et retourne
/// l'erreur. `jsx` active la grammaire JSX (opt-in) ; à `false` (défaut),
/// comportement bit-identique à avant.
pub fn tokenizeDiag(allocator: std.mem.Allocator, source: []const u8, diag: *Diagnostic, jsx: bool) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);

    var lex = Lexer{ .source = source, .diag = diag, .allocator = allocator, .jsx = jsx };
    // Hashbang (ES2023) : `#!` en TOUT DÉBUT de source uniquement -> commentaire
    // jusqu'à la fin de ligne. Aucun token émis.
    if (std.mem.startsWith(u8, source, "#!")) {
        while (lex.peek()) |c| : (lex.advance()) {
            if (c == '\n' or c == '\r') break;
        }
    }
    while (lex.peek()) |c| {
        // ---- JSX : modes pilotés par la pile de contextes (avant tout le reste,
        // car en mode enfants les blancs sont SIGNIFICATIFS). Inerte si jsx off.
        if (lex.jsx) {
            if (lex.jsxCtx()) |ctx| switch (ctx) {
                .children => {
                    const tok = lex.lexJsxChild();
                    var st = tok;
                    st.newline_before = lex.pending_newline;
                    lex.pending_newline = false;
                    lex.last_kind = tok.kind;
                    try tokens.append(allocator, st);
                    continue;
                },
                .tag => {
                    // Blancs/commentaires insignifiants dans une balise.
                    if (std.ascii.isWhitespace(c)) {
                        if (c == '\n' or c == '\r') lex.pending_newline = true;
                        lex.advance();
                        continue;
                    }
                    if (lex.unicodeSpaceHere()) |info| {
                        lex.pos += info.len;
                        continue;
                    }
                    const tok = try lex.lexJsxTag();
                    var st = tok;
                    st.newline_before = lex.pending_newline;
                    lex.pending_newline = false;
                    lex.last_kind = tok.kind;
                    try tokens.append(allocator, st);
                    continue;
                },
                .expr => {}, // conteneur {…} : lexing JS normal (chute plus bas)
            };
        }
        // Whitespace / commentaires : aucun token, `last_kind` inchangé. Un saut
        // de ligne arme `pending_newline` (consommé par le prochain token, ASI).
        if (std.ascii.isWhitespace(c)) {
            if (c == '\n' or c == '\r') lex.pending_newline = true;
            lex.advance();
            continue;
        }
        // Espaces Unicode (NBSP, U+2000-200A, BOM…) ; U+2028/U+2029 = terminateurs
        // de ligne -> arment l'ASI (piège de conformité connu).
        if (lex.unicodeSpaceHere()) |info| {
            if (info.line) lex.pending_newline = true;
            lex.pos += info.len;
            continue;
        }
        if (c == '/' and (lex.peekAt(1) == '/' or lex.peekAt(1) == '*')) {
            try lex.skipComment();
            continue;
        }

        const tok = if (c == '"' or c == '\'')
            try lex.string()
        else if (c == '`') blk: {
            const start = lex.pos;
            lex.advance();
            break :blk try lex.readTemplate(start, true);
        } else if (c == '{') blk: {
            lex.brace_depth += 1;
            break :blk lex.singleToken(.l_brace);
        } else if (c == '}' and lex.template_depth > 0 and lex.brace_depth == lex.tmplTop()) blk: {
            // Ce `}` ferme une interpolation `${…}` -> on relit en mode template.
            lex.tmplPop();
            const start = lex.pos;
            lex.advance();
            break :blk try lex.readTemplate(start, false);
        } else if (lex.jsx and c == '}' and lex.jsxClosesExpr()) blk: {
            // Ce `}` ferme un conteneur d'expression JSX -> retour au mode JSX.
            if (lex.brace_depth > 0) lex.brace_depth -= 1;
            lex.jsxPop();
            break :blk lex.singleToken(.r_brace);
        } else if (c == '}') blk: {
            if (lex.brace_depth > 0) lex.brace_depth -= 1;
            break :blk lex.singleToken(.r_brace);
        } else if (lex.jsx and c == '<' and lex.regexAllowed() and lex.jsxStartsHere()) blk: {
            // `<` en position d'expression (heuristique regexAllowed, comme la
            // regex) + jsx activé -> début d'un élément JSX. On passe en mode tag.
            const t = lex.singleToken(.lt);
            lex.jsxPush(.tag);
            break :blk t;
        } else if (c == '/' and lex.regexAllowed())
            try lex.readRegex()
        else if (std.ascii.isDigit(c) or (c == '.' and lex.digitAtOffset(1)))
            try lex.number()
        else if (c == '#' and lex.peekAt(1) != null and isIdentStart(lex.peekAt(1).?))
            lex.privateName()
        else if (lex.identStartHere())
            try lex.identifierOrKeyword()
        else
            lex.operator();

        var stamped = tok;
        stamped.newline_before = lex.pending_newline;
        lex.pending_newline = false;
        lex.last_kind = tok.kind;
        try tokens.append(allocator, stamped);
    }
    // Interpolation ouverte mais jamais fermée (ex. "`a ${x").
    if (lex.template_depth > 0) {
        lex.setDiag("unterminated template literal", @intCast(source.len));
        return error.UnterminatedTemplate;
    }
    return tokens.toOwnedSlice(allocator);
}

/// Idem, sans avoir à fournir un `Diagnostic` (JS pur, jsx off).
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) ![]Token {
    var diag: Diagnostic = .{};
    return tokenizeDiag(allocator, source, &diag, false);
}

/// Idem, avec la grammaire JSX activée (pour les tests du lexer).
pub fn tokenizeJsx(allocator: std.mem.Allocator, source: []const u8) ![]Token {
    var diag: Diagnostic = .{};
    return tokenizeDiag(allocator, source, &diag, true);
}

// ------------------------------------------------------------------ tests

test "tokenize : identifiants, mots-clés, nombres, opérateurs simples + spans" {
    const a = std.testing.allocator;
    const source = "let x = 42;";
    const tokens = try tokenize(a, source);
    defer a.free(tokens);

    const want = [_]struct { kind: TokenKind, text: []const u8 }{
        .{ .kind = .kw_let, .text = "let" },
        .{ .kind = .identifier, .text = "x" },
        .{ .kind = .eq, .text = "=" },
        .{ .kind = .number, .text = "42" },
        .{ .kind = .semicolon, .text = ";" },
    };
    try std.testing.expectEqual(want.len, tokens.len);
    for (want, tokens) |w, tok| {
        try std.testing.expectEqual(w.kind, tok.kind);
        try std.testing.expectEqualStrings(w.text, tok.text(source));
    }
}

test "mots-clés reconnus (dont typeof) ; superstring reste identifier" {
    const a = std.testing.allocator;
    const tokens = try tokenize(a, "const typeof letter");
    defer a.free(tokens);
    const expected = [_]TokenKind{ .kw_const, .kw_typeof, .identifier };
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |want, got| try std.testing.expectEqual(want, got.kind);
}

test "maximal munch : a===b -> identifier / strict_eq / identifier (pas eq+eq)" {
    const a = std.testing.allocator;
    const tokens = try tokenize(a, "a===b");
    defer a.free(tokens);
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(TokenKind.identifier, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.strict_eq, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.identifier, tokens[2].kind);
}

test "tous les opérateurs multi-caractères" {
    const a = std.testing.allocator;
    // NB : `/=` n'est PAS dans cette liste — après un opérateur, un `/` démarre
    // une regex (cf. `regexAllowed`). On teste `/=` en contexte division plus bas.
    const src = "== === != !== => <= >= && || += -= *= ++ -- ** ?? ?.";
    const tokens = try tokenize(a, src);
    defer a.free(tokens);
    const expected = [_]TokenKind{
        .eq_eq,     .strict_eq,         .neq,          .strict_neq, .arrow,
        .lt_eq,     .gt_eq,             .amp_amp,      .pipe_pipe,  .plus_eq,
        .minus_eq,  .star_eq,           .plus_plus,    .minus_minus,
        .star_star, .question_question, .question_dot,
    };
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |want, got| try std.testing.expectEqual(want, got.kind);

    // `/=` en contexte division (après un identifiant).
    const t2 = try tokenize(a, "x /= 2");
    defer a.free(t2);
    const k2 = [_]TokenKind{ .identifier, .slash_eq, .number };
    try std.testing.expectEqual(k2.len, t2.len);
    for (k2, t2) |want, got| try std.testing.expectEqual(want, got.kind);
}

test "strings : span guillemets inclus, échappements non décodés" {
    const a = std.testing.allocator;
    const src = "\"a\\\"b\" 'c'"; // -> `"a\"b" 'c'`
    const tokens = try tokenize(a, src);
    defer a.free(tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(TokenKind.string, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.string, tokens[1].kind);
    try std.testing.expectEqualStrings("\"a\\\"b\"", tokens[0].text(src));
    try std.testing.expectEqualStrings("'c'", tokens[1].text(src));
}

test "string non fermée -> UnterminatedString" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnterminatedString, tokenize(a, "\"abc"));
    try std.testing.expectError(error.UnterminatedString, tokenize(a, "\"abc\ndef\""));
}

test "commentaires sautés ; bloc non fermé -> UnterminatedComment" {
    const a = std.testing.allocator;
    {
        const tokens = try tokenize(a, "x // ligne\n y /* bloc */ z");
        defer a.free(tokens);
        const expected = [_]TokenKind{ .identifier, .identifier, .identifier };
        try std.testing.expectEqual(expected.len, tokens.len);
        for (expected, tokens) |want, got| try std.testing.expectEqual(want, got.kind);
    }
    try std.testing.expectError(error.UnterminatedComment, tokenize(a, "a /* jamais fermé"));
}

test "spread : `...` est un seul token, `.` reste `.`" {
    const a = std.testing.allocator;
    const t1 = try tokenize(a, "...");
    defer a.free(t1);
    try std.testing.expectEqual(@as(usize, 1), t1.len);
    try std.testing.expectEqual(TokenKind.dot_dot_dot, t1[0].kind);

    const t2 = try tokenize(a, "a.b");
    defer a.free(t2);
    const kinds = [_]TokenKind{ .identifier, .dot, .identifier };
    try std.testing.expectEqual(kinds.len, t2.len);
    for (kinds, t2) |want, got| try std.testing.expectEqual(want, got.kind);
}

test "template : full/head/tail, objet dans ${}, non fermés" {
    const a = std.testing.allocator;
    {
        const t = try tokenize(a, "`hello`");
        defer a.free(t);
        try std.testing.expectEqual(@as(usize, 1), t.len);
        try std.testing.expectEqual(TokenKind.template_full, t[0].kind);
    }
    {
        const t = try tokenize(a, "`a ${x} b`");
        defer a.free(t);
        const kinds = [_]TokenKind{ .template_head, .identifier, .template_tail };
        try std.testing.expectEqual(kinds.len, t.len);
        for (kinds, t) |want, got| try std.testing.expectEqual(want, got.kind);
    }
    {
        // Le `}` de l'objet ne doit PAS fermer l'interpolation.
        const t = try tokenize(a, "`o: ${ {a: 1}.a }`");
        defer a.free(t);
        const kinds = [_]TokenKind{ .template_head, .l_brace, .identifier, .colon, .number, .r_brace, .dot, .identifier, .template_tail };
        try std.testing.expectEqual(kinds.len, t.len);
        for (kinds, t) |want, got| try std.testing.expectEqual(want, got.kind);
    }
    try std.testing.expectError(error.UnterminatedTemplate, tokenize(a, "`pas fermé"));
    try std.testing.expectError(error.UnterminatedTemplate, tokenize(a, "`a ${x"));
}

test "regex vs division : `/` contextuel selon le token précédent" {
    const a = std.testing.allocator;
    {
        // Début de source, après `=`, après `(` -> regex.
        const t = try tokenize(a, "x = /ab+c/g");
        defer a.free(t);
        const kinds = [_]TokenKind{ .identifier, .eq, .regex };
        try std.testing.expectEqual(kinds.len, t.len);
        for (kinds, t) |want, got| try std.testing.expectEqual(want, got.kind);
    }
    {
        // Après un identifiant / un nombre -> division.
        const t = try tokenize(a, "a / b / c");
        defer a.free(t);
        const kinds = [_]TokenKind{ .identifier, .slash, .identifier, .slash, .identifier };
        try std.testing.expectEqual(kinds.len, t.len);
        for (kinds, t) |want, got| try std.testing.expectEqual(want, got.kind);
    }
    {
        // Après `)` et `]` -> division ; le `/` d'ouverture reste ambigu.
        const t = try tokenize(a, "(a) / 2 + b[0] / 3");
        defer a.free(t);
        const kinds = [_]TokenKind{ .l_paren, .identifier, .r_paren, .slash, .number, .plus, .identifier, .l_bracket, .number, .r_bracket, .slash, .number };
        try std.testing.expectEqual(kinds.len, t.len);
        for (kinds, t) |want, got| try std.testing.expectEqual(want, got.kind);
    }
    {
        // char class `[...]` : le `/` interne ne ferme pas ; les flags suivent.
        const t = try tokenize(a, "/a[/]b/gi");
        defer a.free(t);
        try std.testing.expectEqual(@as(usize, 1), t.len);
        try std.testing.expectEqual(TokenKind.regex, t[0].kind);
    }
    // regex non terminée (fin de ligne / fin de source) -> erreur.
    try std.testing.expectError(error.UnterminatedRegex, tokenize(a, "x = /abc"));
    try std.testing.expectError(error.UnterminatedRegex, tokenize(a, "x = /abc\n/"));
}

test "hashbang : #! en tête sauté ; ailleurs c'est un token normal" {
    const a = std.testing.allocator;
    {
        // `#!...` en position 0 -> aucun token avant la fin de ligne.
        const t = try tokenize(a, "#!/usr/bin/env node\nlet x");
        defer a.free(t);
        const kinds = [_]TokenKind{ .kw_let, .identifier };
        try std.testing.expectEqual(kinds.len, t.len);
        for (kinds, t) |want, got| try std.testing.expectEqual(want, got.kind);
    }
    {
        // `#!` PAS en position 0 -> pas de traitement spécial (ici `#` = unknown).
        const t = try tokenize(a, "x\n#!");
        defer a.free(t);
        try std.testing.expect(t.len >= 2);
        try std.testing.expectEqual(TokenKind.identifier, t[0].kind);
    }
}

test "unicode : identifiants non-ASCII (span en bytes, zéro-copie)" {
    const a = std.testing.allocator;
    {
        const t = try tokenize(a, "café"); // c-a-f-é : é = 2 bytes -> span 0..5
        defer a.free(t);
        try std.testing.expectEqual(@as(usize, 1), t.len);
        try std.testing.expectEqual(TokenKind.identifier, t[0].kind);
        try std.testing.expectEqual(@as(u32, 5), t[0].end); // 5 bytes
        try std.testing.expect(t[0].cooked == null); // pas d'échappement -> span brut
    }
    {
        const t = try tokenize(a, "変数 = 5"); // CJK
        defer a.free(t);
        const kinds = [_]TokenKind{ .identifier, .eq, .number };
        try std.testing.expectEqual(kinds.len, t.len);
        for (kinds, t) |want, got| try std.testing.expectEqual(want, got.kind);
    }
}

test "unicode : échappements \\u dans les identifiants -> cooked décodé" {
    const a = std.testing.allocator;
    // Arena : le nom décodé (`cooked`) est alloué dedans, libéré en bloc (comme
    // en prod). Avec l'allocateur de test on aurait une fuite (non libéré).
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    {
        const t = try tokenize(arena.allocator(), "\\u0041bc");
        try std.testing.expectEqual(TokenKind.identifier, t[0].kind);
        try std.testing.expectEqualStrings("Abc", t[0].cooked.?); // Abc -> Abc
    }
    {
        const t = try tokenize(arena.allocator(), "\\u{74}est");
        try std.testing.expectEqualStrings("test", t[0].cooked.?);
    }
    // Mot-clé échappé -> erreur.
    try std.testing.expectError(error.EscapedKeyword, tokenize(a, "\\u0069f"));
    // \u invalides.
    try std.testing.expectError(error.InvalidUnicodeEscape, tokenize(a, "x\\u{"));
    try std.testing.expectError(error.InvalidUnicodeEscape, tokenize(a, "x\\u12"));
    try std.testing.expectError(error.InvalidUnicodeEscape, tokenize(a, "x\\u{110000}")); // > 0x10FFFF
}

test "unicode : U+2028/U+2029 = terminateurs de ligne (ASI)" {
    const a = std.testing.allocator;
    const t = try tokenize(a, "a\u{2028}b"); // LS entre deux identifiants
    defer a.free(t);
    try std.testing.expectEqual(@as(usize, 2), t.len);
    try std.testing.expect(!t[0].newline_before);
    try std.testing.expect(t[1].newline_before); // le LS a armé l'ASI
}

test "unicode : NBSP et autres espaces Unicode sautés" {
    const a = std.testing.allocator;
    const t = try tokenize(a, "a\u{00A0}b\u{3000}c"); // NBSP, idéographique
    defer a.free(t);
    const kinds = [_]TokenKind{ .identifier, .identifier, .identifier };
    try std.testing.expectEqual(kinds.len, t.len);
    for (kinds, t) |want, got| try std.testing.expectEqual(want, got.kind);
}

test "JSX : la danse des tokens (tag / children / conteneur d'expression)" {
    const a = std.testing.allocator;
    {
        // `<div>{x}</div>` : lt div gt l_brace x r_brace lt slash div gt.
        const t = try tokenizeJsx(a, "<div>{x}</div>");
        defer a.free(t);
        const kinds = [_]TokenKind{ .lt, .identifier, .gt, .l_brace, .identifier, .r_brace, .lt, .slash, .identifier, .gt };
        try std.testing.expectEqual(kinds.len, t.len);
        for (kinds, t) |want, got| try std.testing.expectEqual(want, got.kind);
    }
    {
        // Texte brut : `<p>a b</p>` -> jsx_text "a b" (pas deux identifiants).
        // Tokens : lt p gt [jsx_text] lt slash p gt -> le texte est à l'index 3.
        const t = try tokenizeJsx(a, "<p>a b</p>");
        defer a.free(t);
        try std.testing.expectEqual(TokenKind.jsx_text, t[3].kind);
        try std.testing.expectEqualStrings("a b", t[3].text("<p>a b</p>"));
    }
    {
        // Auto-fermant + attribut : `<br x=\"1\"/>`.
        const t = try tokenizeJsx(a, "<br x=\"1\"/>");
        defer a.free(t);
        const kinds = [_]TokenKind{ .lt, .identifier, .identifier, .eq, .string, .slash, .gt };
        try std.testing.expectEqual(kinds.len, t.len);
        for (kinds, t) |want, got| try std.testing.expectEqual(want, got.kind);
    }
    {
        // Non-régression : jsx OFF, `</div>` NE déclenche PAS une regex qui avale.
        const t = try tokenize(a, "a < b");
        defer a.free(t);
        const kinds = [_]TokenKind{ .identifier, .lt, .identifier };
        try std.testing.expectEqual(kinds.len, t.len);
        for (kinds, t) |want, got| try std.testing.expectEqual(want, got.kind);
    }
}
