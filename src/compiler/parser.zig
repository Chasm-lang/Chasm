const std = @import("std");
const token = @import("token");
const Token = token.Token;
const TokenKind = token.TokenKind;
const ast = @import("ast");
const NodeIndex = ast.NodeIndex;
const AstPool = ast.AstPool;
const LifetimeAnnotation = ast.LifetimeAnnotation;
const Lifetime = @import("runtime").Lifetime;
const diag = @import("diag");
const DiagList = diag.DiagList;
const Span = diag.Span;

pub const ParseError = error{
    UnexpectedToken,
    OutOfMemory,
};

pub const Parser = struct {
    tokens: []const Token,
    pos: usize = 0,
    pool: *AstPool,
    diags: *DiagList,
    allocator: std.mem.Allocator,

    pub fn init(
        tokens: []const Token,
        pool: *AstPool,
        diags: *DiagList,
        allocator: std.mem.Allocator,
    ) Parser {
        return .{ .tokens = tokens, .pool = pool, .diags = diags, .allocator = allocator };
    }

    // ---- Helpers -----------------------------------------------------------

    fn peek(self: *Parser) Token {
        if (self.pos >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[self.pos];
    }

    fn peekKind(self: *Parser) TokenKind {
        return self.peek().kind;
    }

    fn peekAheadKind(self: *Parser, offset: usize) TokenKind {
        const i = self.pos + offset;
        if (i >= self.tokens.len) return .eof;
        return self.tokens[i].kind;
    }

    fn advance(self: *Parser) Token {
        const t = self.peek();
        if (self.pos < self.tokens.len - 1) self.pos += 1;
        return t;
    }

    fn check(self: *Parser, kind: TokenKind) bool {
        return self.peekKind() == kind;
    }

    fn match(self: *Parser, kind: TokenKind) ?Token {
        if (self.check(kind)) return self.advance();
        return null;
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!Token {
        if (self.check(kind)) return self.advance();
        const t = self.peek();
        self.diags.err(spanOf(t), "expected {s}, found '{s}'", .{ @tagName(kind), t.lexeme }) catch {};
        return error.UnexpectedToken;
    }

    /// Accept a newline, EOF, or `end`/`else` as a statement terminator.
    fn expectStmtEnd(self: *Parser) ParseError!void {
        _ = self.match(.newline);
        if (self.check(.eof) or self.check(.end_kw) or self.check(.else_kw) or self.check(.when_kw)) return;
        // If we consumed a newline above, we're done.
        // If we're at a non-terminator, that is already covered by match.
    }

    /// Skip any number of consecutive newline tokens.
    fn skipNewlines(self: *Parser) void {
        while (self.match(.newline)) |_| {}
    }

    /// In pipe chains, allow a newline before `|>`.
    fn skipNewlineIfNext(self: *Parser, kind: TokenKind) void {
        if (self.check(.newline) and self.peekAheadKind(1) == kind) {
            _ = self.advance();
        }
    }

    fn spanOf(t: Token) Span {
        return .{ .line = t.line, .col = t.col, .len = @intCast(t.lexeme.len) };
    }

    fn currentSpan(self: *Parser) Span {
        return spanOf(self.peek());
    }

    // ---- Top level ---------------------------------------------------------

    pub fn parseFile(self: *Parser) ParseError![]NodeIndex {
        var items = std.ArrayListUnmanaged(NodeIndex){};
        self.skipNewlines();
        while (!self.check(.eof)) {
            const decl = try self.parseDecl();
            try items.append(self.allocator, decl);
            self.skipNewlines();
        }
        return items.toOwnedSlice(self.allocator);
    }

    fn parseDecl(self: *Parser) ParseError!NodeIndex {
        if (self.check(.def_kw) or self.check(.defp_kw)) return self.parseFnDecl();
        if (self.check(.defstruct_kw)) return self.parseStructDecl();
        if (self.check(.at_sign)) return self.parseAttrDecl();
        if (self.check(.enum_kw)) return self.parseEnumDecl();
        if (self.check(.extern_kw)) return self.parseExternDecl();
        if (self.check(.import_kw)) return self.parseImportDecl();
        const t = self.peek();
        self.diags.err(spanOf(t), "expected declaration (def, defp, defstruct, enum, extern, import, @attr), found '{s}'", .{t.lexeme}) catch {};
        return error.UnexpectedToken;
    }

    // ---- Declarations ------------------------------------------------------

    fn parseFnDecl(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        const is_public = self.match(.def_kw) != null;
        if (!is_public) _ = try self.expect(.defp_kw);

        const name_tok = try self.expect(.ident);
        _ = try self.expect(.lparen);

        var params = std.ArrayListUnmanaged(ast.Param){};
        while (!self.check(.rparen) and !self.check(.eof)) {
            const pname = try self.expect(.ident);
            _ = try self.expect(.colon_colon);
            const lt = self.parseLifetimeAnnotation();
            var ty: ?NodeIndex = null;
            if (!self.check(.comma) and !self.check(.rparen)) {
                ty = try self.parseTypeExpr();
            }
            try params.append(self.allocator, .{ .name = pname.lexeme, .lifetime = lt, .ty = ty });
            _ = self.match(.comma);
        }
        _ = try self.expect(.rparen);

        // Optional return type: `:: [lifetime] type`
        var ret_lt: LifetimeAnnotation = .inferred;
        var ret_ty: ?NodeIndex = null;
        if (self.match(.colon_colon)) |_| {
            ret_lt = self.parseLifetimeAnnotation();
            if (!self.check(.do_kw)) {
                ret_ty = try self.parseTypeExpr();
            }
        }

        const body = try self.parseBlock();

        return self.pool.push(.{ .fn_decl = .{
            .name = name_tok.lexeme,
            .params = try params.toOwnedSlice(self.allocator),
            .ret_lt = ret_lt,
            .ret_ty = ret_ty,
            .body = body,
            .is_public = is_public,
            .span = start,
        } });
    }

    fn parseStructDecl(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        _ = try self.expect(.defstruct_kw);
        const name_tok = try self.expect(.ident);
        _ = try self.expect(.do_kw);
        self.skipNewlines();

        var fields = std.ArrayListUnmanaged(ast.Field){};
        while (!self.check(.end_kw) and !self.check(.eof)) {
            const fname = try self.expect(.ident);
            _ = try self.expect(.colon_colon);
            const lt = self.parseLifetimeAnnotation();
            var ty: ?NodeIndex = null;
            if (!self.check(.newline) and !self.check(.eq) and !self.check(.end_kw)) {
                ty = try self.parseTypeExpr();
            }
            var default: ?NodeIndex = null;
            if (self.match(.eq)) |_| {
                default = try self.parseExpr();
            }
            try fields.append(self.allocator, .{
                .name = fname.lexeme,
                .lifetime = lt,
                .ty = ty,
                .default = default,
            });
            self.skipNewlines();
        }
        _ = try self.expect(.end_kw);

        return self.pool.push(.{ .struct_decl = .{
            .name = name_tok.lexeme,
            .fields = try fields.toOwnedSlice(self.allocator),
            .span = start,
        } });
    }

    fn parseAttrDecl(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        _ = try self.expect(.at_sign);
        const name_tok = try self.expect(.ident);
        _ = try self.expect(.colon_colon);
        const lt = self.parseLifetimeAnnotation();
        var ty: ?NodeIndex = null;
        if (!self.check(.eq)) {
            ty = try self.parseTypeExpr();
        }
        _ = try self.expect(.eq);
        const initializer = try self.parseExpr();
        try self.expectStmtEnd();

        return self.pool.push(.{ .attr_decl = .{
            .name = name_tok.lexeme,
            .lifetime = lt,
            .ty = ty,
            .init = initializer,
            .span = start,
        } });
    }

    fn parseEnumDecl(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        _ = try self.expect(.enum_kw);
        const name_tok = try self.expect(.ident);
        _ = try self.expect(.lbrace);
        self.skipNewlines();

        var variants = std.ArrayListUnmanaged(ast.EnumVariant){};
        while (!self.check(.rbrace) and !self.check(.eof)) {
            const vtok = try self.expect(.ident);
            const variant_name = vtok.lexeme;
            var payload_types = std.ArrayListUnmanaged([]const u8){};
            // check for payload: Variant(Type1, Type2, ...)
            if (self.peek().kind == .lparen) {
                _ = self.advance(); // consume '('
                while (!self.check(.rparen) and !self.check(.eof)) {
                    const ty_tok = try self.expect(.ident);
                    try payload_types.append(self.allocator, ty_tok.lexeme);
                    if (self.check(.comma)) _ = self.advance();
                }
                _ = try self.expect(.rparen);
            }
            try variants.append(self.allocator, ast.EnumVariant{
                .name = variant_name,
                .payload_types = try payload_types.toOwnedSlice(self.allocator),
            });
            _ = self.match(.comma);
            self.skipNewlines();
        }
        _ = try self.expect(.rbrace);

        return self.pool.push(.{ .enum_decl = .{
            .name = name_tok.lexeme,
            .variants = try variants.toOwnedSlice(self.allocator),
            .span = start,
        } });
    }

    fn parseExternDecl(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        _ = try self.expect(.extern_kw);
        // expect `fn` keyword (as ident since we don't have fn_kw; use def_kw or ident)
        // The syntax uses 'fn' which is an ident in this language
        const fn_or_def = self.peek();
        if (std.mem.eql(u8, fn_or_def.lexeme, "fn") or fn_or_def.kind == .def_kw or fn_or_def.kind == .ident) {
            _ = self.advance(); // consume 'fn' or 'def'
        }

        const name_tok = try self.expect(.ident);
        _ = try self.expect(.lparen);

        var params = std.ArrayListUnmanaged(ast.FnParam){};
        while (!self.check(.rparen) and !self.check(.eof)) {
            const pname = try self.expect(.ident);
            _ = try self.expect(.colon);
            const ptype = try self.expect(.ident);
            try params.append(self.allocator, .{ .name = pname.lexeme, .type_name = ptype.lexeme });
            _ = self.match(.comma);
        }
        _ = try self.expect(.rparen);

        // Return type: `-> Type`
        var ret_type: []const u8 = "void";
        if (self.match(.arrow)) |_| {
            const ret_tok = try self.expect(.ident);
            ret_type = ret_tok.lexeme;
        }

        // Optional C alias: `= "c_name"`
        var c_name: []const u8 = name_tok.lexeme;
        if (self.match(.eq)) |_| {
            const alias_tok = try self.expect(.string_lit);
            // Strip quotes
            c_name = alias_tok.lexeme[1 .. alias_tok.lexeme.len - 1];
        }

        try self.expectStmtEnd();

        return self.pool.push(.{ .extern_decl = .{
            .name = name_tok.lexeme,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = ret_type,
            .c_name = c_name,
            .span = start,
        } });
    }

    fn parseImportDecl(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        _ = try self.expect(.import_kw);
        const path_tok = try self.expect(.string_lit);
        // Strip quotes
        const path = path_tok.lexeme[1 .. path_tok.lexeme.len - 1];
        try self.expectStmtEnd();

        return self.pool.push(.{ .import_decl = .{
            .path = path,
            .span = start,
        } });
    }

    fn parseMatchExpr(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        _ = try self.expect(.match_kw);
        // Parse subject without allowing struct literal (avoid `match d { ... }` ambiguity).
        const subject = try self.parseMatchSubject();
        _ = try self.expect(.lbrace);
        self.skipNewlines();

        var arms = std.ArrayListUnmanaged(ast.MatchArm){};
        while (!self.check(.rbrace) and !self.check(.eof)) {
            const pat = try self.parseMatchPattern();
            _ = try self.expect(.fat_arrow);
            const body = try self.parseExpr();
            try arms.append(self.allocator, .{ .pattern = pat, .body = body });
            _ = self.match(.comma);
            self.skipNewlines();
        }
        _ = try self.expect(.rbrace);

        return self.pool.push(.{ .match_expr = .{
            .subject = subject,
            .arms = try arms.toOwnedSlice(self.allocator),
            .span = start,
        } });
    }

    /// Parse the subject of a `match` without consuming a trailing `{` as a struct literal.
    fn parseMatchSubject(self: *Parser) ParseError!NodeIndex {
        const t = self.peek();
        const span = spanOf(t);
        if (self.check(.ident)) {
            _ = self.advance();
            // Don't check for struct literal here — the `{` belongs to match arms.
            return self.pool.push(.{ .ident = .{ .name = t.lexeme, .span = span } });
        }
        if (self.check(.at_sign)) {
            _ = self.advance();
            const name_tok = try self.expect(.ident);
            return self.pool.push(.{ .attr_ref = .{ .name = name_tok.lexeme, .span = span } });
        }
        if (self.check(.lparen)) {
            _ = self.advance();
            const inner = try self.parseExpr();
            _ = try self.expect(.rparen);
            return inner;
        }
        // Fall back to full expression for numeric/complex subjects.
        return self.parseExpr();
    }

    fn parseMatchPattern(self: *Parser) ParseError!NodeIndex {
        const t = self.peek();
        const span = spanOf(t);
        if (self.check(.ident) and std.mem.eql(u8, t.lexeme, "_")) {
            _ = self.advance();
            return self.pool.push(.{ .pattern_wildcard = .{ .span = span } });
        }
        if (self.check(.ident)) {
            _ = self.advance();
            const name = t.lexeme;
            // Check if this is a variant pattern: Variant(binding1, binding2)
            if (name.len > 0 and name[0] >= 'A' and name[0] <= 'Z' and self.peek().kind == .lparen) {
                _ = self.advance(); // consume '('
                var bindings = std.ArrayListUnmanaged([]const u8){};
                while (!self.check(.rparen) and !self.check(.eof)) {
                    const b = try self.expect(.ident);
                    try bindings.append(self.allocator, b.lexeme);
                    if (self.check(.comma)) _ = self.advance();
                }
                _ = try self.expect(.rparen);
                return self.pool.push(.{ .pattern_variant = .{
                    .variant_name = name,
                    .bindings = try bindings.toOwnedSlice(self.allocator),
                    .span = span,
                } });
            }
            return self.pool.push(.{ .pattern_bind = .{ .name = name, .span = span } });
        }
        self.diags.err(span, "expected pattern (identifier or _), found '{s}'", .{t.lexeme}) catch {};
        return error.UnexpectedToken;
    }

    // ---- Types -------------------------------------------------------------

    fn parseLifetimeAnnotation(self: *Parser) LifetimeAnnotation {
        if (self.match(.frame_kw)) |_| return .{ .explicit = .frame };
        if (self.match(.script_kw)) |_| return .{ .explicit = .script };
        if (self.match(.persistent_kw)) |_| return .{ .explicit = .persistent };
        return .inferred;
    }

    fn parseTypeExpr(self: *Parser) ParseError!NodeIndex {
        // `[]ElemType` typed array annotation.
        if (self.match(.lbracket)) |lbrak| {
            _ = try self.expect(.rbracket);
            const elem_tok = try self.expect(.ident);
            return self.pool.push(.{ .array_type = .{
                .elem_name = elem_tok.lexeme,
                .span = spanOf(lbrak),
            } });
        }
        // `(type1, type2, ...)` tuple type annotation.
        if (self.match(.lparen)) |lparen_tok| {
            var types = std.ArrayListUnmanaged(ast.NodeIndex){};
            while (!self.check(.rparen) and !self.check(.eof)) {
                try types.append(self.allocator, try self.parseTypeExpr());
                _ = self.match(.comma);
            }
            _ = try self.expect(.rparen);
            return self.pool.push(.{ .tuple_type = .{
                .types = try types.toOwnedSlice(self.allocator),
                .span = spanOf(lparen_tok),
            } });
        }
        const t = try self.expect(.ident);
        const lt = self.parseLifetimeAnnotation();
        return self.pool.push(.{ .type_ref = .{
            .name = t.lexeme,
            .lifetime = lt,
            .span = spanOf(t),
        } });
    }

    // ---- Blocks ------------------------------------------------------------

    /// Parse `do ... end`, collecting statements.
    fn parseBlock(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        _ = try self.expect(.do_kw);
        const block = try self.parseBlockBody(start, .end_kw);
        _ = try self.expect(.end_kw);
        return block;
    }

    /// Parse a sequence of statements until `stop` (or `else_kw`/`when_kw`) is reached.
    /// Does NOT consume the stop token.
    fn parseBlockBody(self: *Parser, start: Span, stop: TokenKind) ParseError!NodeIndex {
        self.skipNewlines();
        var stmts = std.ArrayListUnmanaged(NodeIndex){};
        while (!self.check(stop) and !self.check(.else_kw) and !self.check(.when_kw) and !self.check(.eof)) {
            const s = try self.parseStmt();
            self.skipNewlines();
            try stmts.append(self.allocator, s);
        }
        return self.pool.push(.{ .block = .{
            .stmts = try stmts.toOwnedSlice(self.allocator),
            .span = start,
        } });
    }

    // ---- Statements --------------------------------------------------------

    fn parseStmt(self: *Parser) ParseError!NodeIndex {
        // Two-token lookahead: `ident ::` → annotated var decl.
        if (self.check(.ident) and self.peekAheadKind(1) == .colon_colon) {
            return self.parseVarDecl();
        }
        // Multi-assign: `ident, ident [, ident]* =` pattern.
        if (self.check(.ident) and self.peekAheadKind(1) == .comma) {
            if (try self.tryParseMultiAssign()) |node| return node;
        }
        if (self.check(.return_kw)) return self.parseReturn();
        if (self.check(.break_kw)) return self.parseBreak();
        if (self.check(.continue_kw)) return self.parseContinue();
        if (self.check(.if_kw)) return self.parseIf();
        if (self.check(.while_kw)) return self.parseWhile();
        if (self.check(.for_kw)) return self.parseForIn();
        return self.parseExprStmt();
    }

    /// Try to parse `ident, ident, ... = expr` as a multi_assign.
    /// Returns null if the pattern doesn't match (so caller can fallback).
    fn tryParseMultiAssign(self: *Parser) ParseError!?NodeIndex {
        // Scan ahead to confirm: ident (, ident)+ = pattern.
        var offset: usize = 0;
        while (self.peekAheadKind(offset) == .ident) {
            offset += 1;
            if (self.peekAheadKind(offset) == .comma) {
                offset += 1; // skip comma
            } else break;
        }
        if (self.peekAheadKind(offset) != .eq) return null;

        // Parse the target name list.
        const start = self.currentSpan();
        var targets = std.ArrayListUnmanaged([]const u8){};
        const first_tok = try self.expect(.ident);
        try targets.append(self.allocator, first_tok.lexeme);
        while (self.match(.comma)) |_| {
            const name_tok = try self.expect(.ident);
            try targets.append(self.allocator, name_tok.lexeme);
        }
        _ = try self.expect(.eq);
        const value = try self.parseExpr();
        try self.expectStmtEnd();

        return try self.pool.push(.{ .multi_assign = .{
            .targets = try targets.toOwnedSlice(self.allocator),
            .value = value,
            .span = start,
        } });
    }

    fn parseVarDecl(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        const name_tok = try self.expect(.ident);
        _ = try self.expect(.colon_colon);
        const lt = self.parseLifetimeAnnotation();
        var ty: ?NodeIndex = null;
        if (!self.check(.eq) and !self.check(.newline) and !self.check(.eof) and !self.check(.end_kw)) {
            ty = try self.parseTypeExpr();
        }
        _ = try self.expect(.eq);
        const initializer = try self.parseExpr();
        try self.expectStmtEnd();

        return self.pool.push(.{ .var_decl = .{
            .name = name_tok.lexeme,
            .lifetime = lt,
            .ty = ty,
            .init = initializer,
            .span = start,
        } });
    }

    fn parseReturn(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        _ = try self.expect(.return_kw);
        var value = ast.invalid_node;
        if (!self.check(.newline) and !self.check(.end_kw) and !self.check(.eof)) {
            const first = try self.parseExpr();
            // `return x, y` → tuple_lit
            if (self.match(.comma)) |_| {
                var values = std.ArrayListUnmanaged(ast.NodeIndex){};
                try values.append(self.allocator, first);
                try values.append(self.allocator, try self.parseExpr());
                while (self.match(.comma)) |_| {
                    try values.append(self.allocator, try self.parseExpr());
                }
                value = try self.pool.push(.{ .tuple_lit = .{
                    .values = try values.toOwnedSlice(self.allocator),
                    .span = start,
                } });
            } else {
                value = first;
            }
        }
        try self.expectStmtEnd();
        return self.pool.push(.{ .return_stmt = .{ .value = value, .span = start } });
    }

    fn parseBreak(self: *Parser) ParseError!NodeIndex {
        const span = self.currentSpan();
        _ = try self.expect(.break_kw);
        try self.expectStmtEnd();
        return self.pool.push(.{ .break_stmt = .{ .span = span } });
    }

    fn parseContinue(self: *Parser) ParseError!NodeIndex {
        const span = self.currentSpan();
        _ = try self.expect(.continue_kw);
        try self.expectStmtEnd();
        return self.pool.push(.{ .continue_stmt = .{ .span = span } });
    }

    fn parseIf(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        _ = try self.expect(.if_kw);
        const cond = try self.parseExpr();
        _ = try self.expect(.do_kw);

        // Then branch: read until `else` or `end`.
        const then_block = try self.parseBlockBody(start, .end_kw);

        var else_block = ast.invalid_node;
        if (self.match(.else_kw)) |_| {
            // `else if` (no newline between) → chain; `else\n  if` → regular else block.
            if (self.check(.if_kw)) {
                // `else if` chain — inner parseIf consumes its own `end`,
                // so we wrap it in a block and return without a second `end_kw`.
                const chain_if = try self.parseIf();
                const stmts = try self.allocator.alloc(ast.NodeIndex, 1);
                stmts[0] = chain_if;
                else_block = try self.pool.push(.{ .block = .{
                    .stmts = stmts,
                    .span = start,
                } });
                return self.pool.push(.{ .if_stmt = .{
                    .cond = cond,
                    .then_block = then_block,
                    .else_block = else_block,
                    .span = start,
                } });
            }
            self.skipNewlines();
            else_block = try self.parseBlockBody(start, .end_kw);
        }
        _ = try self.expect(.end_kw);

        return self.pool.push(.{ .if_stmt = .{
            .cond = cond,
            .then_block = then_block,
            .else_block = else_block,
            .span = start,
        } });
    }

    fn parseWhile(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        _ = try self.expect(.while_kw);
        const cond = try self.parseExpr();
        _ = try self.expect(.do_kw);
        const body = try self.parseBlockBody(start, .end_kw);
        _ = try self.expect(.end_kw);
        return self.pool.push(.{ .while_stmt = .{ .cond = cond, .body = body, .span = start } });
    }

    fn parseStrInterp(self: *Parser, raw: []const u8, span: Span) ParseError!NodeIndex {
        var parts = std.ArrayListUnmanaged(ast.StrPart){};
        var i: usize = 0;
        while (i < raw.len) {
            if (i + 1 < raw.len and raw[i] == '#' and raw[i + 1] == '{') {
                // Find matching '}'
                var j = i + 2;
                while (j < raw.len and raw[j] != '}') : (j += 1) {}
                const inner = raw[i + 2 .. j];
                // Parse inner as expression using a sub-lexer/parser
                var sub_lex = @import("lexer").Lexer.init(inner);
                const sub_toks = sub_lex.tokenize(self.allocator) catch {
                    // On error, treat as literal
                    try parts.append(self.allocator, .{ .literal = inner });
                    i = if (j < raw.len) j + 1 else raw.len;
                    continue;
                };
                const sub_pool_inner = ast.AstPool.init(self.allocator);
                var sub_diags = @import("diag").DiagList.init(self.allocator);
                var sub_parser = Parser.init(sub_toks, self.pool, &sub_diags, self.allocator);
                _ = sub_pool_inner;
                const expr_idx = sub_parser.parseExpr() catch {
                    try parts.append(self.allocator, .{ .literal = inner });
                    i = if (j < raw.len) j + 1 else raw.len;
                    continue;
                };
                try parts.append(self.allocator, .{ .expr = expr_idx });
                i = if (j < raw.len) j + 1 else raw.len;
            } else {
                // Find next `#{`
                var j = i;
                while (j < raw.len) : (j += 1) {
                    if (j + 1 < raw.len and raw[j] == '#' and raw[j + 1] == '{') break;
                }
                if (j > i) {
                    try parts.append(self.allocator, .{ .literal = raw[i..j] });
                }
                i = j;
            }
        }
        return self.pool.push(.{ .str_interp = .{
            .parts = try parts.toOwnedSlice(self.allocator),
            .span = span,
        } });
    }

    fn parseForIn(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        _ = try self.expect(.for_kw);
        const var_tok = try self.expect(.ident);
        _ = try self.expect(.in_kw);
        const iter = try self.parseExpr();
        _ = try self.expect(.do_kw);
        const body = try self.parseBlockBody(start, .end_kw);
        _ = try self.expect(.end_kw);
        return self.pool.push(.{ .for_in = .{
            .var_name = var_tok.lexeme,
            .iter = iter,
            .body = body,
            .span = start,
        } });
    }

    fn parseExprStmt(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        const expr = try self.parseExpr();

        // `expr = rhs` — assignment (covers both `ident = val` and `@attr = val`)
        if (self.match(.eq)) |_| {
            const rhs = try self.parseExpr();
            try self.expectStmtEnd();
            return self.pool.push(.{ .assign = .{ .target = expr, .value = rhs, .span = start } });
        }

        try self.expectStmtEnd();
        return self.pool.push(.{ .expr_stmt = .{ .expr = expr, .span = start } });
    }

    // ---- Case expression ---------------------------------------------------

    fn parseCase(self: *Parser) ParseError!NodeIndex {
        const start = self.currentSpan();
        _ = try self.expect(.case_kw);
        const scrutinee = try self.parseExpr();
        _ = try self.expect(.do_kw);
        self.skipNewlines();

        var arms = std.ArrayListUnmanaged(ast.CaseArm){};
        while (!self.check(.end_kw) and !self.check(.eof)) {
            const arm = try self.parseCaseArm();
            try arms.append(self.allocator, arm);
            self.skipNewlines();
        }
        _ = try self.expect(.end_kw);

        return self.pool.push(.{ .case_expr = .{
            .scrutinee = scrutinee,
            .arms = try arms.toOwnedSlice(self.allocator),
            .span = start,
        } });
    }

    fn parseCaseArm(self: *Parser) ParseError!ast.CaseArm {
        const pat = try self.parsePattern();
        _ = try self.expect(.arrow);

        // Arm body: either a newline-terminated block or single expression.
        const body = if (self.check(.newline)) blk: {
            self.skipNewlines();
            break :blk try self.parseBlockBody(self.currentSpan(), .end_kw);
        } else blk: {
            const e = try self.parseExpr();
            try self.expectStmtEnd();
            break :blk e;
        };

        return .{ .pattern = pat, .body = body };
    }

    fn parsePattern(self: *Parser) ParseError!NodeIndex {
        const t = self.peek();
        const span = spanOf(t);

        if (self.match(.when_kw)) |_| {
            // `when :atom` — consume the `when`, then parse the actual pattern
            return self.parsePattern();
        }
        if (self.check(.atom_lit)) {
            _ = self.advance();
            return self.pool.push(.{ .pattern_atom = .{
                .value = t.lexeme[1..], // strip leading ':'
                .span = span,
            } });
        }
        if (self.check(.ident) and std.mem.eql(u8, t.lexeme, "_")) {
            _ = self.advance();
            return self.pool.push(.{ .pattern_wildcard = .{ .span = span } });
        }
        if (self.check(.ident)) {
            _ = self.advance();
            const name = t.lexeme;
            // Check if this is a variant pattern: Variant(binding1, binding2)
            if (name.len > 0 and name[0] >= 'A' and name[0] <= 'Z' and self.peek().kind == .lparen) {
                _ = self.advance(); // consume '('
                var bindings = std.ArrayListUnmanaged([]const u8){};
                while (!self.check(.rparen) and !self.check(.eof)) {
                    const b = try self.expect(.ident);
                    try bindings.append(self.allocator, b.lexeme);
                    if (self.check(.comma)) _ = self.advance();
                }
                _ = try self.expect(.rparen);
                return self.pool.push(.{ .pattern_variant = .{
                    .variant_name = name,
                    .bindings = try bindings.toOwnedSlice(self.allocator),
                    .span = span,
                } });
            }
            return self.pool.push(.{ .pattern_bind = .{ .name = name, .span = span } });
        }
        if (self.check(.int_lit) or self.check(.float_lit) or
            self.check(.string_lit) or self.check(.true_kw) or self.check(.false_kw))
        {
            const lit = try self.parsePrimary();
            return self.pool.push(.{ .pattern_lit = .{ .inner = lit, .span = span } });
        }
        self.diags.err(span, "expected pattern, found '{s}'", .{t.lexeme}) catch {};
        return error.UnexpectedToken;
    }

    // ---- Expressions (Pratt) -----------------------------------------------

    fn parseExpr(self: *Parser) ParseError!NodeIndex {
        const left = try self.parsePipe();
        // Range: `lo..hi`
        if (self.match(.dot_dot)) |dot_tok| {
            const right = try self.parsePipe();
            return self.pool.push(.{ .range = .{
                .lo = left,
                .hi = right,
                .span = spanOf(dot_tok),
            } });
        }
        return left;
    }

    /// Left-associative pipe: `a |> f(b)` desugars to `f(a, b)`.
    fn parsePipe(self: *Parser) ParseError!NodeIndex {
        var left = try self.parseOr();
        while (true) {
            self.skipNewlineIfNext(.pipe_gt);
            if (self.match(.pipe_gt)) |_| {
                const rhs = try self.parsePostfix();
                left = try self.desugarPipe(left, rhs);
            } else break;
        }
        return left;
    }

    fn desugarPipe(self: *Parser, lhs: NodeIndex, rhs: NodeIndex) !NodeIndex {
        switch (self.pool.get(rhs).*) {
            .call => |c| {
                // Prepend lhs to the existing args list.
                var new_args = try self.allocator.alloc(NodeIndex, c.args.len + 1);
                new_args[0] = lhs;
                @memcpy(new_args[1..], c.args);
                return self.pool.push(.{ .call = .{
                    .callee = c.callee,
                    .args = new_args,
                    .span = c.span,
                } });
            },
            .ident => |i| {
                // `a |> f` → `f(a)`
                const args = try self.allocator.alloc(NodeIndex, 1);
                args[0] = lhs;
                return self.pool.push(.{ .call = .{
                    .callee = rhs,
                    .args = args,
                    .span = i.span,
                } });
            },
            else => {
                self.diags.err(self.currentSpan(), "right-hand side of |> must be a function call or name", .{}) catch {};
                return error.UnexpectedToken;
            },
        }
    }

    fn parseOr(self: *Parser) ParseError!NodeIndex {
        var left = try self.parseAnd();
        while (self.match(.or_kw)) |op_tok| {
            const right = try self.parseAnd();
            left = try self.pool.push(.{ .binary = .{ .op = .@"or", .left = left, .right = right, .span = spanOf(op_tok) } });
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParseError!NodeIndex {
        var left = try self.parseEquality();
        while (self.match(.and_kw)) |op_tok| {
            const right = try self.parseEquality();
            left = try self.pool.push(.{ .binary = .{ .op = .@"and", .left = left, .right = right, .span = spanOf(op_tok) } });
        }
        return left;
    }

    fn parseEquality(self: *Parser) ParseError!NodeIndex {
        var left = try self.parseComparison();
        while (true) {
            const op: ast.BinaryOp = if (self.match(.eqeq)) |_| .eq else if (self.match(.bang_eq)) |_| .neq else break;
            const right = try self.parseComparison();
            left = try self.pool.push(.{ .binary = .{ .op = op, .left = left, .right = right, .span = self.currentSpan() } });
        }
        return left;
    }

    fn parseComparison(self: *Parser) ParseError!NodeIndex {
        var left = try self.parseAddSub();
        while (true) {
            const op: ast.BinaryOp = if (self.match(.lt)) |_| .lt else if (self.match(.lt_eq)) |_| .lte else if (self.match(.gt)) |_| .gt else if (self.match(.gt_eq)) |_| .gte else break;
            const right = try self.parseAddSub();
            left = try self.pool.push(.{ .binary = .{ .op = op, .left = left, .right = right, .span = self.currentSpan() } });
        }
        return left;
    }

    fn parseAddSub(self: *Parser) ParseError!NodeIndex {
        var left = try self.parseMulDiv();
        while (true) {
            const op: ast.BinaryOp = if (self.match(.plus)) |_| .add else if (self.match(.minus)) |_| .sub else break;
            const right = try self.parseMulDiv();
            left = try self.pool.push(.{ .binary = .{ .op = op, .left = left, .right = right, .span = self.currentSpan() } });
        }
        return left;
    }

    fn parseMulDiv(self: *Parser) ParseError!NodeIndex {
        var left = try self.parseUnary();
        while (true) {
            const op: ast.BinaryOp = if (self.match(.star)) |_| .mul else if (self.match(.slash)) |_| .div else if (self.match(.percent)) |_| .mod else break;
            const right = try self.parseUnary();
            left = try self.pool.push(.{ .binary = .{ .op = op, .left = left, .right = right, .span = self.currentSpan() } });
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!NodeIndex {
        const span = self.currentSpan();
        if (self.match(.bang)) |_| return self.pool.push(.{ .unary = .{ .op = .not, .operand = try self.parseUnary(), .span = span } });
        if (self.match(.minus)) |_| return self.pool.push(.{ .unary = .{ .op = .neg, .operand = try self.parseUnary(), .span = span } });
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParseError!NodeIndex {
        var node = try self.parsePrimary();
        while (true) {
            if (self.match(.dot)) |_| {
                const field_tok = try self.expect(.ident);
                node = try self.pool.push(.{ .field_access = .{ .object = node, .field = field_tok.lexeme, .span = spanOf(field_tok) } });
            } else if (self.match(.lbracket)) |_| {
                const idx_expr = try self.parseExpr();
                _ = try self.expect(.rbracket);
                node = try self.pool.push(.{ .index = .{ .array = node, .idx = idx_expr, .span = self.currentSpan() } });
            } else if (self.match(.lparen)) |_| {
                var args = std.ArrayListUnmanaged(NodeIndex){};
                while (!self.check(.rparen) and !self.check(.eof)) {
                    try args.append(self.allocator, try self.parseExpr());
                    _ = self.match(.comma);
                }
                _ = try self.expect(.rparen);
                node = try self.pool.push(.{ .call = .{ .callee = node, .args = try args.toOwnedSlice(self.allocator), .span = self.currentSpan() } });
            } else break;
        }
        return node;
    }

    fn parsePrimary(self: *Parser) ParseError!NodeIndex {
        const t = self.peek();
        const span = spanOf(t);

        switch (t.kind) {
            .int_lit => {
                _ = self.advance();
                return self.pool.push(.{ .int_lit = .{ .value = std.fmt.parseInt(i64, t.lexeme, 0) catch 0, .span = span } });
            },
            .float_lit => {
                _ = self.advance();
                return self.pool.push(.{ .float_lit = .{ .value = std.fmt.parseFloat(f64, t.lexeme) catch 0.0, .span = span } });
            },
            .true_kw => { _ = self.advance(); return self.pool.push(.{ .bool_lit = .{ .value = true, .span = span } }); },
            .false_kw => { _ = self.advance(); return self.pool.push(.{ .bool_lit = .{ .value = false, .span = span } }); },
            .string_lit => {
                _ = self.advance();
                const raw = t.lexeme[1 .. t.lexeme.len - 1]; // strip quotes
                // Check if string contains interpolation
                if (std.mem.indexOf(u8, raw, "#{") != null) {
                    return self.parseStrInterp(raw, span);
                }
                return self.pool.push(.{ .string_lit = .{ .value = raw, .span = span } });
            },
            .atom_lit => {
                _ = self.advance();
                return self.pool.push(.{ .atom_lit = .{ .value = t.lexeme[1..], .span = span } });
            },
            .at_sign => {
                _ = self.advance();
                const name_tok = try self.expect(.ident);
                return self.pool.push(.{ .attr_ref = .{ .name = name_tok.lexeme, .span = span } });
            },
            .copy_to_script_kw => {
                _ = self.advance();
                _ = try self.expect(.lparen);
                const expr = try self.parseExpr();
                _ = try self.expect(.rparen);
                return self.pool.push(.{ .copy_to_script = .{ .expr = expr, .span = span } });
            },
            .persist_copy_kw => {
                _ = self.advance();
                _ = try self.expect(.lparen);
                const expr = try self.parseExpr();
                _ = try self.expect(.rparen);
                return self.pool.push(.{ .persist_copy = .{ .expr = expr, .span = span } });
            },
            .case_kw => return self.parseCase(),
            .match_kw => return self.parseMatchExpr(),
            .ident => {
                _ = self.advance();
                // Check for struct literal: `TypeName { field: expr, ... }`
                if (self.check(.lbrace)) {
                    _ = self.advance(); // consume '{'
                    var fields = std.ArrayListUnmanaged(ast.StructLitField){};
                    while (!self.check(.rbrace) and !self.check(.eof)) {
                        const field_tok = try self.expect(.ident);
                        _ = try self.expect(.colon);
                        const val = try self.parseExpr();
                        try fields.append(self.allocator, .{ .name = field_tok.lexeme, .value = val });
                        if (self.match(.comma) == null) break;
                        self.skipNewlines();
                    }
                    _ = try self.expect(.rbrace);
                    return self.pool.push(.{ .struct_lit = .{
                        .type_name = t.lexeme,
                        .fields = try fields.toOwnedSlice(self.allocator),
                        .span = span,
                    } });
                }
                return self.pool.push(.{ .ident = .{ .name = t.lexeme, .span = span } });
            },
            .lbracket => {
                _ = self.advance();
                var elems = std.ArrayListUnmanaged(NodeIndex){};
                while (!self.check(.rbracket) and !self.check(.eof)) {
                    try elems.append(self.allocator, try self.parseExpr());
                    if (self.match(.comma) == null) break;
                    self.skipNewlines();
                }
                _ = try self.expect(.rbracket);
                return self.pool.push(.{ .array_lit = .{
                    .elements = try elems.toOwnedSlice(self.allocator),
                    .span = span,
                } });
            },
            .lparen => {
                _ = self.advance();
                const inner = try self.parseExpr();
                _ = try self.expect(.rparen);
                return inner;
            },
            else => {
                self.diags.err(span, "unexpected token '{s}' in expression", .{t.lexeme}) catch {};
                return error.UnexpectedToken;
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Helper: arena-backed test parse — all allocations freed in bulk.
const TestParse = struct {
    arena: std.heap.ArenaAllocator,
    pool: AstPool,
    diags: DiagList,
    nodes: []NodeIndex,

    fn init(src: []const u8) !TestParse {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const alloc = arena.allocator();
        var lex = @import("lexer").Lexer.init(src);
        const toks = try lex.tokenize(alloc);
        var pool = AstPool.init(alloc);
        var diags_inst = DiagList.init(alloc);
        var parser = Parser.init(toks, &pool, &diags_inst, alloc);
        const nodes = try parser.parseFile();
        return .{ .arena = arena, .pool = pool, .diags = diags_inst, .nodes = nodes };
    }

    fn deinit(self: *TestParse) void {
        self.arena.deinit();
    }
};

test "parse annotated var decl" {
    var tp = try TestParse.init(
        \\@score :: script = 0
    );
    defer tp.deinit();

    try std.testing.expect(tp.nodes.len == 1);
    const node = tp.pool.get(tp.nodes[0]);
    try std.testing.expectEqualSlices(u8, "score", node.attr_decl.name);
    try std.testing.expect(node.attr_decl.lifetime == .explicit);
    try std.testing.expectEqual(Lifetime.script, node.attr_decl.lifetime.explicit);
}

test "parse def function" {
    const src =
        \\def add(a :: i32, b :: i32) :: i32 do
        \\  return a
        \\end
    ;
    var tp = try TestParse.init(src);
    defer tp.deinit();

    try std.testing.expect(tp.nodes.len == 1);
    const node = tp.pool.get(tp.nodes[0]);
    try std.testing.expectEqualSlices(u8, "add", node.fn_decl.name);
    try std.testing.expect(node.fn_decl.is_public);
    try std.testing.expectEqual(@as(usize, 2), node.fn_decl.params.len);
}

test "parse defp private function" {
    const src =
        \\defp helper(x :: f32) do
        \\  x
        \\end
    ;
    var tp = try TestParse.init(src);
    defer tp.deinit();

    const node = tp.pool.get(tp.nodes[0]);
    try std.testing.expect(!node.fn_decl.is_public);
}

test "parse defstruct" {
    const src =
        \\defstruct Player do
        \\  health :: int
        \\  pos :: Vec2
        \\end
    ;
    var tp = try TestParse.init(src);
    defer tp.deinit();

    const node = tp.pool.get(tp.nodes[0]);
    try std.testing.expectEqualSlices(u8, "Player", node.struct_decl.name);
    try std.testing.expectEqual(@as(usize, 2), node.struct_decl.fields.len);
}

test "parse frame lifetime annotation in var decl" {
    const src =
        \\def f() do
        \\  speed :: frame = 9.8
        \\  speed
        \\end
    ;
    var tp = try TestParse.init(src);
    defer tp.deinit();

    const fn_node = tp.pool.get(tp.nodes[0]);
    const body = tp.pool.get(fn_node.fn_decl.body);
    const var_node = tp.pool.get(body.block.stmts[0]);
    try std.testing.expectEqualSlices(u8, "speed", var_node.var_decl.name);
    try std.testing.expectEqual(Lifetime.frame, var_node.var_decl.lifetime.explicit);
}

test "parse if/else with do/end" {
    const src =
        \\def check(x :: int) do
        \\  if x > 0 do
        \\    x
        \\  else
        \\    0
        \\  end
        \\end
    ;
    var tp = try TestParse.init(src);
    defer tp.deinit();

    try std.testing.expect(tp.nodes.len == 1);
    try std.testing.expect(!tp.diags.hasErrors());
}

test "parse while with do/end" {
    const src =
        \\def loop(n :: int) do
        \\  i :: frame = 0
        \\  while i < n do
        \\    i = i + 1
        \\  end
        \\end
    ;
    var tp = try TestParse.init(src);
    defer tp.deinit();
    try std.testing.expect(!tp.diags.hasErrors());
}

test "parse atom literal" {
    const src =
        \\def f() do
        \\  :idle
        \\end
    ;
    var tp = try TestParse.init(src);
    defer tp.deinit();

    const fn_node = tp.pool.get(tp.nodes[0]);
    const body = tp.pool.get(fn_node.fn_decl.body);
    const stmt = tp.pool.get(body.block.stmts[0]);
    const expr = tp.pool.get(stmt.expr_stmt.expr);
    try std.testing.expectEqualSlices(u8, "idle", expr.atom_lit.value);
}

test "parse @attr module attribute declaration" {
    const src =
        \\@high_score :: persistent = 0
    ;
    var tp = try TestParse.init(src);
    defer tp.deinit();

    const node = tp.pool.get(tp.nodes[0]);
    try std.testing.expectEqualSlices(u8, "high_score", node.attr_decl.name);
    try std.testing.expectEqual(Lifetime.persistent, node.attr_decl.lifetime.explicit);
}

test "parse @attr reference and assignment" {
    const src =
        \\def save() do
        \\  @score = copy_to_script(42)
        \\end
    ;
    var tp = try TestParse.init(src);
    defer tp.deinit();
    try std.testing.expect(!tp.diags.hasErrors());
    const fn_node = tp.pool.get(tp.nodes[0]);
    const body = tp.pool.get(fn_node.fn_decl.body);
    const assign = tp.pool.get(body.block.stmts[0]);
    const target = tp.pool.get(assign.assign.target);
    try std.testing.expectEqualSlices(u8, "score", target.attr_ref.name);
}

test "parse pipe operator" {
    const src =
        \\def f(x :: f32) do
        \\  x |> scale(2.0)
        \\end
    ;
    var tp = try TestParse.init(src);
    defer tp.deinit();
    try std.testing.expect(!tp.diags.hasErrors());

    const fn_node = tp.pool.get(tp.nodes[0]);
    const body = tp.pool.get(fn_node.fn_decl.body);
    const stmt = tp.pool.get(body.block.stmts[0]);
    const call = tp.pool.get(stmt.expr_stmt.expr);
    // After desugaring, should be a call with 2 args.
    try std.testing.expectEqual(@as(usize, 2), call.call.args.len);
}

test "parse case/when expression" {
    const src =
        \\def describe(s :: atom) do
        \\  case s do
        \\    when :idle -> "standing"
        \\    _ -> "other"
        \\  end
        \\end
    ;
    var tp = try TestParse.init(src);
    defer tp.deinit();
    try std.testing.expect(!tp.diags.hasErrors());

    const fn_node = tp.pool.get(tp.nodes[0]);
    const body = tp.pool.get(fn_node.fn_decl.body);
    const case_stmt = tp.pool.get(body.block.stmts[0]);
    const case_expr = tp.pool.get(case_stmt.expr_stmt.expr);
    try std.testing.expectEqual(@as(usize, 2), case_expr.case_expr.arms.len);
}

test "parse copy_to_script builtin" {
    const src =
        \\def f(x :: f32) do
        \\  copy_to_script(x)
        \\end
    ;
    var tp = try TestParse.init(src);
    defer tp.deinit();
    try std.testing.expect(!tp.diags.hasErrors());
}

test "parse multiline pipe chain" {
    // newline before |> should be non-significant (consumed by skipNewlineIfNext)
    const src =
        \\def f(x :: f32) do
        \\  x
        \\    |> scale(2.0)
        \\end
    ;
    var tp = try TestParse.init(src);
    defer tp.deinit();
    try std.testing.expect(!tp.diags.hasErrors());
}
