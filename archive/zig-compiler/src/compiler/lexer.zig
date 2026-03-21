const std = @import("std");
const token = @import("token");
const Token = token.Token;
const TokenKind = token.TokenKind;

pub const LexError = error{
    UnterminatedString,
    UnexpectedChar,
    OutOfMemory,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    col: u32 = 1,
    /// Kind of the last non-newline token emitted; drives newline significance.
    last_kind: ?TokenKind = null,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src };
    }

    pub fn tokenize(self: *Lexer, allocator: std.mem.Allocator) LexError![]Token {
        var list = std.ArrayListUnmanaged(Token){};
        while (true) {
            const tok = try self.next();
            try list.append(allocator, tok);
            if (tok.kind == .eof) break;
        }
        return list.toOwnedSlice(allocator);
    }

    // ---- Internal helpers --------------------------------------------------

    fn peek(self: *Lexer) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn peekAt(self: *Lexer, offset: usize) ?u8 {
        const i = self.pos + offset;
        if (i >= self.src.len) return null;
        return self.src[i];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return c;
    }

    fn matchChar(self: *Lexer, expected: u8) bool {
        if (self.peek()) |c| {
            if (c == expected) { _ = self.advance(); return true; }
        }
        return false;
    }

    /// Skip spaces, tabs, carriage returns, and `#` line comments.
    /// Does NOT consume newlines.
    fn skipHorizontal(self: *Lexer) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\r') {
                _ = self.advance();
            } else if (c == '#') {
                while (self.peek()) |cc| {
                    if (cc == '\n') break;
                    _ = self.advance();
                }
            } else {
                break;
            }
        }
    }

    fn emit(self: *Lexer, kind: TokenKind, lexeme: []const u8, line: u32, col: u32) Token {
        if (kind != .newline) self.last_kind = kind;
        return .{ .kind = kind, .lexeme = lexeme, .line = line, .col = col };
    }

    // ---- Main tokenizer ----------------------------------------------------

    pub fn next(self: *Lexer) LexError!Token {
        // Outer loop: skip horizontal whitespace/comments, handle newlines.
        while (true) {
            self.skipHorizontal();

            if (self.peek()) |c| {
                if (c == '\n') {
                    const nl_line = self.line;
                    const nl_col = self.col;
                    _ = self.advance(); // consume '\n'

                    const is_significant = if (self.last_kind) |lk| token.isLineCloser(lk) else false;
                    if (is_significant) {
                        // Emit one newline token; subsequent blank lines are collapsed.
                        self.last_kind = .newline;
                        return .{ .kind = .newline, .lexeme = "\n", .line = nl_line, .col = nl_col };
                    }
                    continue; // non-significant newline, keep scanning
                }
            } else {
                // EOF
                return self.emit(.eof, "", self.line, self.col);
            }

            break; // non-whitespace character, proceed to tokenize
        }

        const start_pos = self.pos;
        const start_line = self.line;
        const start_col = self.col;

        const c = self.advance();

        switch (c) {
            // ---- Single-char punctuation -----------------------------------
            '(' => return self.emit(.lparen, self.src[start_pos..self.pos], start_line, start_col),
            ')' => return self.emit(.rparen, self.src[start_pos..self.pos], start_line, start_col),
            '[' => return self.emit(.lbracket, self.src[start_pos..self.pos], start_line, start_col),
            ']' => return self.emit(.rbracket, self.src[start_pos..self.pos], start_line, start_col),
            '{' => return self.emit(.lbrace, self.src[start_pos..self.pos], start_line, start_col),
            '}' => return self.emit(.rbrace, self.src[start_pos..self.pos], start_line, start_col),
            ',' => return self.emit(.comma, self.src[start_pos..self.pos], start_line, start_col),
            '.' => {
                if (self.peek() == '.') {
                    _ = self.advance();
                    return self.emit(.dot_dot, self.src[start_pos..self.pos], start_line, start_col);
                }
                return self.emit(.dot, self.src[start_pos..self.pos], start_line, start_col);
            },
            '+' => return self.emit(.plus, self.src[start_pos..self.pos], start_line, start_col),
            '*' => return self.emit(.star, self.src[start_pos..self.pos], start_line, start_col),
            '%' => return self.emit(.percent, self.src[start_pos..self.pos], start_line, start_col),
            '/' => return self.emit(.slash, self.src[start_pos..self.pos], start_line, start_col),

            // ---- Multi-char operators --------------------------------------
            '-' => {
                if (self.matchChar('>')) {
                    return self.emit(.arrow, self.src[start_pos..self.pos], start_line, start_col);
                }
                return self.emit(.minus, self.src[start_pos..self.pos], start_line, start_col);
            },
            '=' => {
                if (self.matchChar('=')) {
                    return self.emit(.eqeq, self.src[start_pos..self.pos], start_line, start_col);
                }
                if (self.matchChar('>')) {
                    return self.emit(.fat_arrow, self.src[start_pos..self.pos], start_line, start_col);
                }
                return self.emit(.eq, self.src[start_pos..self.pos], start_line, start_col);
            },
            '!' => {
                if (self.matchChar('=')) {
                    return self.emit(.bang_eq, self.src[start_pos..self.pos], start_line, start_col);
                }
                return self.emit(.bang, self.src[start_pos..self.pos], start_line, start_col);
            },
            '<' => {
                if (self.matchChar('=')) {
                    return self.emit(.lt_eq, self.src[start_pos..self.pos], start_line, start_col);
                }
                return self.emit(.lt, self.src[start_pos..self.pos], start_line, start_col);
            },
            '>' => {
                if (self.matchChar('=')) {
                    return self.emit(.gt_eq, self.src[start_pos..self.pos], start_line, start_col);
                }
                return self.emit(.gt, self.src[start_pos..self.pos], start_line, start_col);
            },
            '|' => {
                if (self.matchChar('>')) {
                    return self.emit(.pipe_gt, self.src[start_pos..self.pos], start_line, start_col);
                }
                return self.emit(.pipe, self.src[start_pos..self.pos], start_line, start_col);
            },
            '@' => return self.emit(.at_sign, self.src[start_pos..self.pos], start_line, start_col),

            // ---- Colon: ':', '::', or ':atom' ------------------------------
            ':' => {
                // '::' — lifetime/type annotation separator
                if (self.peek() == ':') {
                    _ = self.advance();
                    return self.emit(.colon_colon, self.src[start_pos..self.pos], start_line, start_col);
                }
                // ':atom' — atom literal: colon immediately followed by ident chars
                if (self.peek()) |nc| {
                    if ((nc >= 'a' and nc <= 'z') or (nc >= 'A' and nc <= 'Z') or nc == '_') {
                        while (self.peek()) |ac| {
                            if ((ac >= 'a' and ac <= 'z') or
                                (ac >= 'A' and ac <= 'Z') or
                                (ac >= '0' and ac <= '9') or
                                ac == '_')
                            {
                                _ = self.advance();
                            } else break;
                        }
                        return self.emit(.atom_lit, self.src[start_pos..self.pos], start_line, start_col);
                    }
                }
                return self.emit(.colon, self.src[start_pos..self.pos], start_line, start_col);
            },

            // ---- String literal --------------------------------------------
            '"' => {
                while (self.peek()) |sc| {
                    if (sc == '"') { _ = self.advance(); break; }
                    if (sc == '\n') return error.UnterminatedString;
                    _ = self.advance();
                } else {
                    return error.UnterminatedString;
                }
                return self.emit(.string_lit, self.src[start_pos..self.pos], start_line, start_col);
            },

            // ---- Numeric literals -----------------------------------------
            '0'...'9' => {
                // Hex literal: 0x / 0X
                if (c == '0' and (self.peek() == 'x' or self.peek() == 'X')) {
                    _ = self.advance(); // consume 'x'
                    while (self.peek()) |nc| {
                        if ((nc >= '0' and nc <= '9') or
                            (nc >= 'a' and nc <= 'f') or
                            (nc >= 'A' and nc <= 'F')) { _ = self.advance(); } else break;
                    }
                    return self.emit(.int_lit, self.src[start_pos..self.pos], start_line, start_col);
                }
                while (self.peek()) |nc| {
                    if (nc >= '0' and nc <= '9') { _ = self.advance(); } else break;
                }
                // Float?
                if (self.peek() == '.' and
                    (self.peekAt(1) orelse 0) >= '0' and
                    (self.peekAt(1) orelse 0) <= '9')
                {
                    _ = self.advance(); // consume '.'
                    while (self.peek()) |nc| {
                        if (nc >= '0' and nc <= '9') { _ = self.advance(); } else break;
                    }
                    return self.emit(.float_lit, self.src[start_pos..self.pos], start_line, start_col);
                }
                return self.emit(.int_lit, self.src[start_pos..self.pos], start_line, start_col);
            },

            // ---- Identifiers & keywords ------------------------------------
            'a'...'z', 'A'...'Z', '_' => {
                while (self.peek()) |nc| {
                    if ((nc >= 'a' and nc <= 'z') or
                        (nc >= 'A' and nc <= 'Z') or
                        (nc >= '0' and nc <= '9') or
                        nc == '_')
                    {
                        _ = self.advance();
                    } else break;
                }
                const lexeme = self.src[start_pos..self.pos];
                const kw = token.lookupKeyword(lexeme);
                return self.emit(kw orelse .ident, lexeme, start_line, start_col);
            },

            else => return error.UnexpectedChar,
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "basic tokens" {
    const src = "x :: script = 42";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(TokenKind.ident, toks[0].kind);
    try std.testing.expectEqual(TokenKind.colon_colon, toks[1].kind);
    try std.testing.expectEqual(TokenKind.script_kw, toks[2].kind);
    try std.testing.expectEqual(TokenKind.eq, toks[3].kind);
    try std.testing.expectEqual(TokenKind.int_lit, toks[4].kind);
    try std.testing.expectEqual(TokenKind.eof, toks[5].kind);
}

test "lifetime keywords lowercase" {
    const src = "frame script persistent copy_to_script persist_copy";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(TokenKind.frame_kw, toks[0].kind);
    try std.testing.expectEqual(TokenKind.script_kw, toks[1].kind);
    try std.testing.expectEqual(TokenKind.persistent_kw, toks[2].kind);
    try std.testing.expectEqual(TokenKind.copy_to_script_kw, toks[3].kind);
    try std.testing.expectEqual(TokenKind.persist_copy_kw, toks[4].kind);
}

test "atom literal" {
    const src = ":idle :running";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(TokenKind.atom_lit, toks[0].kind);
    try std.testing.expectEqualSlices(u8, ":idle", toks[0].lexeme);
    try std.testing.expectEqual(TokenKind.atom_lit, toks[1].kind);
}

test "double colon vs single colon vs atom" {
    const src = "x :: :name";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(TokenKind.ident, toks[0].kind);
    try std.testing.expectEqual(TokenKind.colon_colon, toks[1].kind);
    try std.testing.expectEqual(TokenKind.atom_lit, toks[2].kind);
}

test "pipe operator" {
    const src = "x |> f";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(TokenKind.ident, toks[0].kind);
    try std.testing.expectEqual(TokenKind.pipe_gt, toks[1].kind);
    try std.testing.expectEqual(TokenKind.ident, toks[2].kind);
}

test "hash comment skipped" {
    const src = "# this is a comment\ndef";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TokenKind.def_kw, toks[0].kind);
}

test "significant newline after ident" {
    const src = "x\ny";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(TokenKind.ident, toks[0].kind);
    try std.testing.expectEqual(TokenKind.newline, toks[1].kind);
    try std.testing.expectEqual(TokenKind.ident, toks[2].kind);
}

test "non-significant newline after operator" {
    const src = "x +\ny";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    // newline after '+' is not significant
    try std.testing.expectEqual(TokenKind.ident, toks[0].kind);
    try std.testing.expectEqual(TokenKind.plus, toks[1].kind);
    try std.testing.expectEqual(TokenKind.ident, toks[2].kind);
    try std.testing.expectEqual(TokenKind.eof, toks[3].kind);
}

test "significant newline after rparen" {
    const src = "f()\ng";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(TokenKind.ident, toks[0].kind);
    try std.testing.expectEqual(TokenKind.lparen, toks[1].kind);
    try std.testing.expectEqual(TokenKind.rparen, toks[2].kind);
    try std.testing.expectEqual(TokenKind.newline, toks[3].kind);
    try std.testing.expectEqual(TokenKind.ident, toks[4].kind);
}

test "newline after end keyword is significant" {
    const src = "end\nx";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(TokenKind.end_kw, toks[0].kind);
    try std.testing.expectEqual(TokenKind.newline, toks[1].kind);
}

test "multiple blank lines collapse to one newline" {
    const src = "x\n\n\ny";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(TokenKind.ident, toks[0].kind);
    try std.testing.expectEqual(TokenKind.newline, toks[1].kind);
    try std.testing.expectEqual(TokenKind.ident, toks[2].kind);
    try std.testing.expectEqual(TokenKind.eof, toks[3].kind);
}

test "def/do/end keywords" {
    const src = "def foo do end";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(TokenKind.def_kw, toks[0].kind);
    try std.testing.expectEqual(TokenKind.ident, toks[1].kind);
    try std.testing.expectEqual(TokenKind.do_kw, toks[2].kind);
    try std.testing.expectEqual(TokenKind.end_kw, toks[3].kind);
}

test "float literal" {
    const src = "3.14";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TokenKind.float_lit, toks[0].kind);
}

test "arrow token for case arms" {
    const src = "when :ok -> 1";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TokenKind.when_kw, toks[0].kind);
    try std.testing.expectEqual(TokenKind.atom_lit, toks[1].kind);
    try std.testing.expectEqual(TokenKind.arrow, toks[2].kind);
}

test "at_sign token" {
    const src = "@score";
    var lex = Lexer.init(src);
    const toks = try lex.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TokenKind.at_sign, toks[0].kind);
    try std.testing.expectEqual(TokenKind.ident, toks[1].kind);
    try std.testing.expectEqualSlices(u8, "score", toks[1].lexeme);
}
