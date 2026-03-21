/// Chasm LSP server.
///
/// Implements a subset of the Language Server Protocol focused on the features
/// that make Chasm's three-lifetime model useful in an editor:
///
///   • textDocument/publishDiagnostics — sema errors with source ranges.
///   • textDocument/hover              — shows the inferred lifetime (and type)
///                                       of the token under the cursor.
///
/// Supported requests / notifications:
///   initialize            → server capabilities
///   initialized           → no-op
///   textDocument/didOpen  → store source, analyse, publish diagnostics
///   textDocument/didChange → update source, re-analyse, publish diagnostics
///   textDocument/didClose → remove stored source
///   textDocument/hover    → return lifetime info at cursor position
///   shutdown              → flag + null response
///   exit                  → process exit

const std    = @import("std");
const jsonrpc = @import("jsonrpc");

const ast_mod    = @import("ast");
const diag_mod   = @import("diag");
const sema_mod   = @import("sema");
const prelude_mod = @import("prelude");
const Lexer    = @import("lexer").Lexer;
const Parser   = @import("parser").Parser;

const AstPool  = ast_mod.AstPool;
const NodeIndex = ast_mod.NodeIndex;
const DiagList = diag_mod.DiagList;
const Span     = diag_mod.Span;
const Sema     = sema_mod.Sema;
const Lifetime = @import("runtime").Lifetime;

// ---------------------------------------------------------------------------
// Analysis result
// ---------------------------------------------------------------------------

pub const Diagnostic = struct {
    range_start_line: u32,
    range_start_char: u32,
    range_end_char:   u32,
    severity: u32, // 1=error 2=warning 3=info
    message: []const u8,
};

pub const AnalysisResult = struct {
    arena:             std.heap.ArenaAllocator,
    pool:              AstPool,
    diags:             DiagList,
    sema:              Sema,
    top_level:         []const NodeIndex,
    /// Number of source lines occupied by the injected prelude.
    /// Subtracted from diagnostic spans before sending to the editor.
    prelude_line_offset: u32,

    pub fn deinit(self: *AnalysisResult) void {
        self.arena.deinit();
    }
};

/// Run the full lex → parse → sema pipeline on `source`.
/// The raylib prelude is always prepended so that engine API names are defined.
/// Returns an `AnalysisResult` owned by an internal arena.
pub fn analyze(source: []const u8, backing: std.mem.Allocator) !AnalysisResult {
    return analyzeWithUri(source, "", backing);
}

/// Same as `analyze` but accepts the document URI so that imports can be
/// resolved relative to the file's directory.
pub fn analyzeWithUri(source: []const u8, uri: []const u8, backing: std.mem.Allocator) !AnalysisResult {
    var arena = std.heap.ArenaAllocator.init(backing);
    const alloc = arena.allocator();

    // Prepend raylib prelude so all engine functions are defined during analysis.
    const prelude = prelude_mod.raylib_prelude;
    const full_source = try std.mem.concat(alloc, u8, &.{ prelude, "\n", source });

    // Count prelude lines (including the separator "\n") so we can adjust
    // diagnostic line numbers back to the user's file coordinates.
    const prelude_line_offset: u32 = @intCast(std.mem.count(u8, prelude, "\n") + 1);

    var pool  = AstPool.init(alloc);
    var diags = DiagList.init(alloc);

    var lex = Lexer.init(full_source);
    const toks = lex.tokenize(alloc) catch {
        return AnalysisResult{
            .arena = arena, .pool = pool, .diags = diags,
            .sema = Sema.init(&pool, &diags, alloc), .top_level = &.{},
            .prelude_line_offset = prelude_line_offset,
        };
    };

    var parser = Parser.init(toks, &pool, &diags, alloc);
    const top = parser.parseFile() catch {
        return AnalysisResult{
            .arena = arena, .pool = pool, .diags = diags,
            .sema = Sema.init(&pool, &diags, alloc), .top_level = &.{},
            .prelude_line_offset = prelude_line_offset,
        };
    };

    // Derive a filesystem path from the URI for import resolution.
    // Strip "file://" prefix; on POSIX the result is already absolute.
    const file_path: []const u8 = if (std.mem.startsWith(u8, uri, "file://"))
        uri["file://".len..]
    else
        uri;

    var sem = Sema.initWithFile(&pool, &diags, alloc, file_path);
    sem.analyze(top) catch {};

    return AnalysisResult{
        .arena = arena, .pool = pool, .diags = diags,
        .sema = sem, .top_level = top,
        .prelude_line_offset = prelude_line_offset,
    };
}

/// Find the innermost AST node whose span contains `(line, col)`.
/// `line` and `col` are 0-indexed (LSP convention).
/// Returns the NodeIndex and its span, or null if none found.
pub fn findNodeAt(pool: *const AstPool, line: u32, col: u32) ?struct { idx: NodeIndex, span: Span } {
    // Convert from 0-indexed LSP to 1-indexed internal spans.
    const target_line: u32 = line + 1;
    const target_col:  u32 = col  + 1;

    var best_idx: ?NodeIndex = null;
    var best_len: u32        = std.math.maxInt(u32);

    for (0..pool.len()) |i| {
        const idx: NodeIndex = @intCast(i);
        const span = ast_mod.nodeSpan(pool, idx) orelse continue;
        if (span.line != target_line) continue;
        if (target_col < span.col) continue;
        if (target_col >= span.col + span.len) continue;
        if (span.len < best_len) {
            best_len = span.len;
            best_idx = idx;
        }
    }

    if (best_idx) |idx| {
        return .{ .idx = idx, .span = ast_mod.nodeSpan(pool, idx).? };
    }
    return null;
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

/// Render a JSON string, escaping control chars.
fn jsonStr(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try buf.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"'  => try buf.appendSlice(alloc, "\\\""),
            '\\'  => try buf.appendSlice(alloc, "\\\\"),
            '\n'  => try buf.appendSlice(alloc, "\\n"),
            '\r'  => try buf.appendSlice(alloc, "\\r"),
            '\t'  => try buf.appendSlice(alloc, "\\t"),
            0...8, 11, 12, 14...31 => {
                var tmp: [8]u8 = undefined;
                const encoded = try std.fmt.bufPrint(&tmp, "\\u{X:0>4}", .{c});
                try buf.appendSlice(alloc, encoded);
            },
            else => try buf.append(alloc, c),
        }
    }
    try buf.append(alloc, '"');
}

/// Build a `textDocument/publishDiagnostics` params JSON blob.
pub fn buildDiagnosticsJson(
    uri: []const u8,
    result: *const AnalysisResult,
    alloc: std.mem.Allocator,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};

    try buf.appendSlice(alloc, "{\"uri\":");
    try jsonStr(&buf, alloc, uri);
    try buf.appendSlice(alloc, ",\"diagnostics\":[");

    var first = true;
    for (result.diags.items.items) |d| {
        const s = d.span;
        // Skip diagnostics that originate inside the injected prelude.
        if (s.line <= result.prelude_line_offset) continue;
        // Adjust line back to user-file coordinates (1-indexed prelude offset).
        const user_line = s.line - result.prelude_line_offset;
        // Convert 1-indexed span → 0-indexed LSP range.
        const sl: u32 = if (user_line > 0) user_line - 1 else 0;
        const sc: u32 = if (s.col  > 0) s.col  - 1 else 0;
        const ec: u32 = sc + s.len;

        if (!first) try buf.append(alloc, ',');
        first = false;
        const severity: u32 = switch (d.level) {
            .err  => 1,
            .warn => 2,
            .note => 3,
        };

        const entry_hdr = try std.fmt.allocPrint(alloc,
            \\{{"range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}},"severity":{d},"source":"chasm","message":
            , .{ sl, sc, sl, ec, severity });
        defer alloc.free(entry_hdr);
        try buf.appendSlice(alloc, entry_hdr);
        try jsonStr(&buf, alloc, d.message);
        try buf.append(alloc, '}');
    }

    try buf.appendSlice(alloc, "]}");
    return try buf.toOwnedSlice(alloc);
}

/// Build a hover response JSON for a given node.
pub fn buildHoverJson(
    result: *const AnalysisResult,
    idx: NodeIndex,
    alloc: std.mem.Allocator,
) ![]const u8 {
    const lt = result.sema.lifetimeOf(idx);
    const ty = result.sema.nodeType(idx);
    const lt_name = @tagName(lt);
    const ty_name = sema_mod.typeName(ty);

    const value = try std.fmt.allocPrint(alloc,
        "**lifetime**: `{s}`  \n**type**: `{s}`",
        .{ lt_name, ty_name });
    defer alloc.free(value);

    var buf: std.ArrayListUnmanaged(u8) = .{};
    try buf.appendSlice(alloc, "{\"contents\":{\"kind\":\"markdown\",\"value\":");
    try jsonStr(&buf, alloc, value);
    try buf.append(alloc, '}');
    try buf.append(alloc, '}');
    return try buf.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

pub const Server = struct {
    gpa:      std.heap.GeneralPurposeAllocator(.{}),
    docs:     std.StringHashMapUnmanaged([]u8), // URI → owned source
    shutdown: bool,

    pub fn init() Server {
        return .{
            .gpa      = .{},
            .docs     = .{},
            .shutdown = false,
        };
    }

    pub fn deinit(self: *Server) void {
        const alloc = self.gpa.allocator();
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.docs.deinit(alloc);
        _ = self.gpa.deinit();
    }

    /// Main loop: read messages from `reader`, write responses to `writer`.
    pub fn run(self: *Server, reader: anytype, writer: anytype) !void {
        const alloc = self.gpa.allocator();
        while (true) {
            const msg = jsonrpc.readMessage(reader, alloc) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            defer alloc.free(msg);
            self.handleMessage(msg, writer) catch |err| {
                std.log.err("handleMessage error: {}", .{err});
            };
            if (self.shutdown) return;
        }
    }

    pub fn handleMessage(self: *Server, msg: []const u8, writer: anytype) !void {
        const alloc = self.gpa.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, msg, .{}) catch {
            try jsonrpc.writeError(writer, "null", -32700, "Parse error");
            return;
        };
        defer parsed.deinit();
        const val = parsed.value;

        const obj = switch (val) {
            .object => |o| o,
            else => {
                try jsonrpc.writeError(writer, "null", -32600, "Invalid Request");
                return;
            },
        };

        const method_val = obj.get("method") orelse {
            // No method → it's a response, ignore.
            return;
        };
        const method = switch (method_val) {
            .string => |s| s,
            else => {
                try jsonrpc.writeError(writer, "null", -32600, "Invalid Request");
                return;
            },
        };

        // Extract id as a JSON fragment for echo-back.
        var id_buf: [64]u8 = undefined;
        const id_json: []const u8 = if (obj.get("id")) |id_val| blk: {
            break :blk switch (id_val) {
                .integer => |n| try std.fmt.bufPrint(&id_buf, "{d}", .{n}),
                .string  => |s| try std.fmt.bufPrint(&id_buf, "\"{s}\"", .{s}),
                .null    => "null",
                else     => "null",
            };
        } else "null"; // notification — no id

        const params = obj.get("params");

        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(id_json, writer);
        } else if (std.mem.eql(u8, method, "initialized")) {
            // notification, no response
        } else if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown = true;
            try jsonrpc.writeResponse(writer, id_json, "null");
        } else if (std.mem.eql(u8, method, "exit")) {
            std.process.exit(if (self.shutdown) 0 else 1);
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(params, writer);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(params, writer);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.handleDidClose(params);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.handleHover(id_json, params, writer);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            try self.handleDefinition(id_json, params, writer);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.handleCompletion(id_json, params, writer);
        } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
            try self.handleSignatureHelp(id_json, params, writer);
        } else if (id_json.len > 0 and !std.mem.eql(u8, id_json, "null")) {
            // Unknown request (has id) — respond with method-not-found.
            try jsonrpc.writeError(writer, id_json, -32601, "Method not found");
        }
        // Unknown notifications are silently dropped.
    }

    // ---- Handlers ----------------------------------------------------------

    fn handleInitialize(self: *Server, id_json: []const u8, writer: anytype) !void {
        _ = self;
        // Declare: incremental sync (kind=2), hover, diagnostics (push), definition, completion, signatureHelp.
        const result =
            \\{"capabilities":{"textDocumentSync":{"openClose":true,"change":2},"hoverProvider":true,"definitionProvider":true,"completionProvider":{"triggerCharacters":[".","@"]},"signatureHelpProvider":{"triggerCharacters":["(",","]}}}
        ;
        try jsonrpc.writeResponse(writer, id_json, result);
    }

    fn handleDidOpen(self: *Server, params: ?std.json.Value, writer: anytype) !void {
        const alloc = self.gpa.allocator();
        const uri, const text = extractUriAndText(params, "textDocument", "text") orelse return;
        try self.storeDoc(uri, text);
        try self.publishDiagnostics(uri, writer, alloc);
    }

    fn handleDidChange(self: *Server, params: ?std.json.Value, writer: anytype) !void {
        const alloc = self.gpa.allocator();
        // For simplicity we require full-document sync (the last change is the whole doc).
        const uri_val = getNestedStr(params, &.{"textDocument", "uri"}) orelse return;
        const changes = switch (params orelse return) {
            .object => |o| switch (o.get("contentChanges") orelse return) {
                .array => |a| a,
                else   => return,
            },
            else => return,
        };
        if (changes.items.len == 0) return;
        const last  = changes.items[changes.items.len - 1];
        const text  = switch (last) {
            .object => |o| switch (o.get("text") orelse return) {
                .string => |s| s,
                else    => return,
            },
            else => return,
        };
        try self.storeDoc(uri_val, text);
        try self.publishDiagnostics(uri_val, writer, alloc);
    }

    fn handleDidClose(self: *Server, params: ?std.json.Value) !void {
        const alloc = self.gpa.allocator();
        const uri = getNestedStr(params, &.{"textDocument", "uri"}) orelse return;
        if (self.docs.fetchRemove(uri)) |entry| {
            alloc.free(entry.key);
            alloc.free(entry.value);
        }
    }

    fn handleHover(self: *Server, id_json: []const u8, params: ?std.json.Value, writer: anytype) !void {
        const alloc = self.gpa.allocator();

        const uri = getNestedStr(params, &.{"textDocument", "uri"}) orelse {
            try jsonrpc.writeResponse(writer, id_json, "null");
            return;
        };
        const source = self.docs.get(uri) orelse {
            try jsonrpc.writeResponse(writer, id_json, "null");
            return;
        };

        const pos_obj = switch (params orelse return) {
            .object => |o| switch (o.get("position") orelse {
                try jsonrpc.writeResponse(writer, id_json, "null");
                return;
            }) {
                .object => |p| p,
                else => {
                    try jsonrpc.writeResponse(writer, id_json, "null");
                    return;
                },
            },
            else => {
                try jsonrpc.writeResponse(writer, id_json, "null");
                return;
            },
        };

        const line: u32 = @intCast(switch (pos_obj.get("line") orelse .null) {
            .integer => |n| n,
            else     => 0,
        });
        const char: u32 = @intCast(switch (pos_obj.get("character") orelse .null) {
            .integer => |n| n,
            else     => 0,
        });

        var result = try analyzeWithUri(source, uri, alloc);
        defer result.deinit();

        // Offset the LSP line by the prelude so we search the combined AST.
        const adjusted_line = line + result.prelude_line_offset;
        if (findNodeAt(&result.pool, adjusted_line, char)) |found| {
            const hover_json = try buildHoverJson(&result, found.idx, alloc);
            defer alloc.free(hover_json);
            try jsonrpc.writeResponse(writer, id_json, hover_json);
        } else {
            try jsonrpc.writeResponse(writer, id_json, "null");
        }
    }

    fn handleDefinition(self: *Server, id_json: []const u8, params: ?std.json.Value, writer: anytype) !void {
        const alloc = self.gpa.allocator();

        const uri = getNestedStr(params, &.{"textDocument", "uri"}) orelse {
            try jsonrpc.writeResponse(writer, id_json, "null");
            return;
        };
        const source = self.docs.get(uri) orelse {
            try jsonrpc.writeResponse(writer, id_json, "null");
            return;
        };

        const pos_obj = blk: {
            const p = params orelse {
                try jsonrpc.writeResponse(writer, id_json, "null");
                return;
            };
            break :blk switch (p) {
                .object => |o| switch (o.get("position") orelse {
                    try jsonrpc.writeResponse(writer, id_json, "null");
                    return;
                }) {
                    .object => |pobj| pobj,
                    else => {
                        try jsonrpc.writeResponse(writer, id_json, "null");
                        return;
                    },
                },
                else => {
                    try jsonrpc.writeResponse(writer, id_json, "null");
                    return;
                },
            };
        };

        const line: u32 = @intCast(switch (pos_obj.get("line") orelse .null) {
            .integer => |n| n,
            else     => 0,
        });
        const char: u32 = @intCast(switch (pos_obj.get("character") orelse .null) {
            .integer => |n| n,
            else     => 0,
        });

        var result = try analyzeWithUri(source, uri, alloc);
        defer result.deinit();

        // Find node at cursor (offset line by prelude to search the combined AST)
        const found = findNodeAt(&result.pool, line + result.prelude_line_offset, char) orelse {
            try jsonrpc.writeResponse(writer, id_json, "null");
            return;
        };

        // Get the name we're looking for
        const target_name: []const u8 = switch (result.pool.get(found.idx).*) {
            .ident    => |id| id.name,
            .attr_ref => |ar| ar.name,
            else      => {
                try jsonrpc.writeResponse(writer, id_json, "null");
                return;
            },
        };

        // Search the AST pool for a matching declaration
        var decl_span: ?Span = null;
        for (0..result.pool.len()) |i| {
            const idx: NodeIndex = @intCast(i);
            switch (result.pool.get(idx).*) {
                .fn_decl   => |f| if (std.mem.eql(u8, f.name, target_name)) { decl_span = f.span; break; },
                .attr_decl => |a| if (std.mem.eql(u8, a.name, target_name)) { decl_span = a.span; break; },
                .var_decl  => |v| if (std.mem.eql(u8, v.name, target_name)) { decl_span = v.span; break; },
                else       => {},
            }
        }

        if (decl_span) |ds| {
            // Subtract prelude offset and convert 1-indexed → 0-indexed.
            const user_line = if (ds.line > result.prelude_line_offset) ds.line - result.prelude_line_offset else ds.line;
            const dl: u32 = if (user_line > 0) user_line - 1 else 0;
            const dc: u32 = if (ds.col  > 0) ds.col  - 1 else 0;
            const ec: u32 = dc + ds.len;
            const loc_json = try std.fmt.allocPrint(alloc,
                \\{{"uri":{s},"range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}}}}
                , .{ try std.fmt.allocPrint(alloc, "\"{s}\"", .{uri}), dl, dc, dl, ec });
            defer alloc.free(loc_json);
            try jsonrpc.writeResponse(writer, id_json, loc_json);
        } else {
            try jsonrpc.writeResponse(writer, id_json, "null");
        }
    }

    fn handleCompletion(self: *Server, id_json: []const u8, params: ?std.json.Value, writer: anytype) !void {
        const alloc = self.gpa.allocator();

        const uri = getNestedStr(params, &.{"textDocument", "uri"}) orelse {
            try jsonrpc.writeResponse(writer, id_json, "[]");
            return;
        };
        const source = self.docs.get(uri) orelse {
            try jsonrpc.writeResponse(writer, id_json, "[]");
            return;
        };

        // Read cursor position to detect `module.` prefix context.
        const module_prefix: ?[]const u8 = blk: {
            const pos_obj = switch (params orelse break :blk null) {
                .object => |o| switch (o.get("position") orelse break :blk null) {
                    .object => |p| p,
                    else    => break :blk null,
                },
                else => break :blk null,
            };
            const line_num: usize = @intCast(switch (pos_obj.get("line") orelse .null) {
                .integer => |n| n,
                else     => break :blk null,
            });
            const char_num: usize = @intCast(switch (pos_obj.get("character") orelse .null) {
                .integer => |n| n,
                else     => break :blk null,
            });
            // Find the line in source.
            var cur_line: usize = 0;
            var line_start: usize = 0;
            for (source, 0..) |c, ci| {
                if (cur_line == line_num) { line_start = ci; break; }
                if (c == '\n') cur_line += 1;
            }
            const line_end = line_start + char_num;
            if (line_end > source.len) break :blk null;
            const prefix_text = source[line_start..line_end];
            if (prefix_text.len == 0) break :blk null;
            // Find the last `.` in the prefix — handles both `utils.` and `utils.pa`.
            const dot_pos = std.mem.lastIndexOfScalar(u8, prefix_text, '.') orelse break :blk null;
            const before_dot = prefix_text[0..dot_pos];
            // Walk back to find the start of the identifier before the dot.
            var id_end = before_dot.len;
            while (id_end > 0) {
                const ch = before_dot[id_end - 1];
                if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                    (ch >= '0' and ch <= '9') or ch == '_') {
                    id_end -= 1;
                } else break;
            }
            const mod_name = before_dot[id_end..];
            if (mod_name.len == 0) break :blk null;
            break :blk mod_name;
        };

        var ar = try analyzeWithUri(source, uri, alloc);
        defer ar.deinit();

        var buf: std.ArrayListUnmanaged(u8) = .{};
        try buf.appendSlice(alloc, "[");
        var first = true;

        if (module_prefix) |prefix| {
            // Only return members of the named module (strip `prefix.` from labels).
            const needle = try std.fmt.allocPrint(alloc, "{s}.", .{prefix});
            defer alloc.free(needle);
            var it = ar.sema.module_scope.symbols.iterator();
            while (it.next()) |entry| {
                const sym_name = entry.key_ptr.*;
                if (!std.mem.startsWith(u8, sym_name, needle)) continue;
                const label = sym_name[needle.len..];
                if (!first) try buf.append(alloc, ',');
                first = false;
                const item = try std.fmt.allocPrint(alloc,
                    \\{{"label":"{s}","kind":3}}
                    , .{label});
                defer alloc.free(item);
                try buf.appendSlice(alloc, item);
            }
        } else {
            // Collect all symbols from the module scope (excluding namespaced ones).
            var it = ar.sema.module_scope.symbols.iterator();
            while (it.next()) |entry| {
                const sym_name = entry.key_ptr.*;
                // Skip prefixed module members — they only appear in `module.` context.
                if (std.mem.indexOfScalar(u8, sym_name, '.') != null) continue;
                if (!first) try buf.append(alloc, ',');
                first = false;
                const item = try std.fmt.allocPrint(alloc,
                    \\{{"label":"{s}","kind":3}}
                    , .{sym_name});
                defer alloc.free(item);
                try buf.appendSlice(alloc, item);
            }

            // Collect function and var decl names from the AST.
            for (0..ar.pool.len()) |i| {
                const idx: NodeIndex = @intCast(i);
                const name: ?[]const u8 = switch (ar.pool.get(idx).*) {
                    .fn_decl  => |f| f.name,
                    .var_decl => |v| v.name,
                    else      => null,
                };
                if (name) |n| {
                    if (!first) try buf.append(alloc, ',');
                    first = false;
                    const item = try std.fmt.allocPrint(alloc,
                        \\{{"label":"{s}","kind":6}}
                        , .{n});
                    defer alloc.free(item);
                    try buf.appendSlice(alloc, item);
                }
            }
        }

        try buf.appendSlice(alloc, "]");
        const result_json = try buf.toOwnedSlice(alloc);
        defer alloc.free(result_json);
        try jsonrpc.writeResponse(writer, id_json, result_json);
    }

    fn handleSignatureHelp(self: *Server, id_json: []const u8, params: ?std.json.Value, writer: anytype) !void {
        const alloc = self.gpa.allocator();

        const uri = getNestedStr(params, &.{"textDocument", "uri"}) orelse {
            try jsonrpc.writeResponse(writer, id_json, "null");
            return;
        };
        const source = self.docs.get(uri) orelse {
            try jsonrpc.writeResponse(writer, id_json, "null");
            return;
        };

        const pos_obj = blk: {
            const p = params orelse {
                try jsonrpc.writeResponse(writer, id_json, "null");
                return;
            };
            break :blk switch (p) {
                .object => |o| switch (o.get("position") orelse {
                    try jsonrpc.writeResponse(writer, id_json, "null");
                    return;
                }) {
                    .object => |pobj| pobj,
                    else => {
                        try jsonrpc.writeResponse(writer, id_json, "null");
                        return;
                    },
                },
                else => {
                    try jsonrpc.writeResponse(writer, id_json, "null");
                    return;
                },
            };
        };

        const line: u32 = @intCast(switch (pos_obj.get("line") orelse .null) {
            .integer => |n| n,
            else     => 0,
        });
        const char: u32 = @intCast(switch (pos_obj.get("character") orelse .null) {
            .integer => |n| n,
            else     => 0,
        });

        const call_ctx = findCallContext(source, line, char) orelse {
            try jsonrpc.writeResponse(writer, id_json, "null");
            return;
        };

        var result = try analyzeWithUri(source, uri, alloc);
        defer result.deinit();

        // Find the fn_decl for the called function in the AST pool.
        var fn_node_idx: ?NodeIndex = null;
        for (0..result.pool.len()) |i| {
            const idx: NodeIndex = @intCast(i);
            switch (result.pool.get(idx).*) {
                .fn_decl => |f| if (std.mem.eql(u8, f.name, call_ctx.name)) {
                    fn_node_idx = idx;
                    break;
                },
                else => {},
            }
        }

        if (fn_node_idx == null) {
            try jsonrpc.writeResponse(writer, id_json, "null");
            return;
        }

        const fn_node = result.pool.get(fn_node_idx.?).fn_decl;

        // Build the signature label and parameter list JSON.
        var sig_label = std.ArrayListUnmanaged(u8){};
        defer sig_label.deinit(alloc);
        try sig_label.appendSlice(alloc, fn_node.name);
        try sig_label.append(alloc, '(');

        var params_arr = std.ArrayListUnmanaged(u8){};
        defer params_arr.deinit(alloc);
        try params_arr.append(alloc, '[');

        for (fn_node.params, 0..) |param, pi| {
            if (pi > 0) {
                try sig_label.appendSlice(alloc, ", ");
                try params_arr.append(alloc, ',');
            }

            var param_label = std.ArrayListUnmanaged(u8){};
            defer param_label.deinit(alloc);
            try param_label.appendSlice(alloc, param.name);

            // Append lifetime annotation if explicit.
            switch (param.lifetime) {
                .inferred => {},
                .explicit => |lt| {
                    try param_label.appendSlice(alloc, " :: ");
                    try param_label.appendSlice(alloc, @tagName(lt));
                    try param_label.append(alloc, ' ');
                },
            }

            // Append type name from the type annotation node if present.
            if (param.ty) |ty_idx| {
                switch (result.pool.get(ty_idx).*) {
                    .ident => |id| {
                        if (param.lifetime == .inferred) try param_label.appendSlice(alloc, ": ");
                        try param_label.appendSlice(alloc, id.name);
                    },
                    else => {},
                }
            }

            try sig_label.appendSlice(alloc, param_label.items);

            try params_arr.appendSlice(alloc, "{\"label\":");
            try jsonStr(&params_arr, alloc, param_label.items);
            try params_arr.append(alloc, '}');
        }

        try sig_label.append(alloc, ')');
        try params_arr.append(alloc, ']');

        const active = if (fn_node.params.len > 0)
            @min(call_ctx.active_param, @as(u32, @intCast(fn_node.params.len - 1)))
        else
            0;

        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(alloc);
        try buf.appendSlice(alloc, "{\"signatures\":[{\"label\":");
        try jsonStr(&buf, alloc, sig_label.items);
        try buf.appendSlice(alloc, ",\"parameters\":");
        try buf.appendSlice(alloc, params_arr.items);
        try buf.appendSlice(alloc, "}],\"activeSignature\":0,\"activeParameter\":");
        const active_str = try std.fmt.allocPrint(alloc, "{d}", .{active});
        defer alloc.free(active_str);
        try buf.appendSlice(alloc, active_str);
        try buf.append(alloc, '}');

        const result_json = try buf.toOwnedSlice(alloc);
        defer alloc.free(result_json);
        try jsonrpc.writeResponse(writer, id_json, result_json);
    }

    // ---- Helpers -----------------------------------------------------------

    fn storeDoc(self: *Server, uri: []const u8, text: []const u8) !void {
        const alloc = self.gpa.allocator();
        // Remove existing entry if present.
        if (self.docs.fetchRemove(uri)) |old| {
            alloc.free(old.key);
            alloc.free(old.value);
        }
        const uri_owned  = try alloc.dupe(u8, uri);
        const text_owned = try alloc.dupe(u8, text);
        try self.docs.put(alloc, uri_owned, text_owned);
    }

    fn emptyDiagnostics(uri: []const u8, writer: anytype, alloc: std.mem.Allocator) !void {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        try buf.appendSlice(alloc, "{\"uri\":");
        try jsonStr(&buf, alloc, uri);
        try buf.appendSlice(alloc, ",\"diagnostics\":[]}");
        const json = try buf.toOwnedSlice(alloc);
        defer alloc.free(json);
        try jsonrpc.writeNotification(writer, "textDocument/publishDiagnostics", json);
    }

    fn publishDiagnostics(
        self: *Server,
        uri: []const u8,
        writer: anytype,
        alloc: std.mem.Allocator,
    ) !void {
        // bootstrap/ files are frozen source — never show diagnostics.
        if (std.mem.indexOf(u8, uri, "/bootstrap/") != null) {
            return emptyDiagnostics(uri, writer, alloc);
        }

        // compiler/ files are a concatenated unit — analyze together and
        // map diagnostics back to each individual file.
        if (std.mem.indexOf(u8, uri, "/compiler/") != null) {
            return self.publishDiagnosticsCompilerDir(uri, writer, alloc);
        }

        const source = self.docs.get(uri) orelse return;
        var result = try analyzeWithUri(source, uri, alloc);
        defer result.deinit();
        const params_json = try buildDiagnosticsJson(uri, &result, alloc);
        defer alloc.free(params_json);
        try jsonrpc.writeNotification(writer, "textDocument/publishDiagnostics", params_json);
    }

    fn publishDiagnosticsCompilerDir(
        self: *Server,
        uri: []const u8,
        writer: anytype,
        alloc: std.mem.Allocator,
    ) !void {
        const file_path: []const u8 = if (std.mem.startsWith(u8, uri, "file://"))
            uri["file://".len..]
        else
            uri;
        const dir_path = std.fs.path.dirname(file_path) orelse ".";

        // Fixed concatenation order — matches build_stage2.sh.
        const order = [_][]const u8{ "lexer", "parser", "sema", "codegen", "main" };

        const FileInfo = struct {
            uri:        []u8,
            start_line: u32, // 0-indexed line in combined source (after prelude stripped)
            line_count: u32,
        };

        var combined    = std.ArrayListUnmanaged(u8){};
        var file_infos  = std.ArrayListUnmanaged(FileInfo){};
        defer {
            for (file_infos.items) |fi| alloc.free(fi.uri);
            file_infos.deinit(alloc);
            combined.deinit(alloc);
        }

        for (order) |base| {
            const fname = try std.fmt.allocPrint(alloc, "{s}.chasm", .{base});
            defer alloc.free(fname);
            const fpath = try std.fs.path.join(alloc, &.{ dir_path, fname });
            defer alloc.free(fpath);
            const furi  = try std.fmt.allocPrint(alloc, "file://{s}", .{fpath});
            errdefer alloc.free(furi);

            // Prefer the in-memory (unsaved) version; fall back to disk.
            var disk_buf: ?[]u8 = null;
            const source: []const u8 = blk: {
                if (self.docs.get(furi)) |s| break :blk s;
                const f = std.fs.openFileAbsolute(fpath, .{}) catch {
                    alloc.free(furi);
                    continue; // file doesn't exist yet — skip
                };
                defer f.close();
                disk_buf = try f.readToEndAlloc(alloc, 16 * 1024 * 1024);
                break :blk disk_buf.?;
            };
            defer if (disk_buf) |b| alloc.free(b);

            const start_line: u32 = @intCast(std.mem.count(u8, combined.items, "\n"));
            const line_count: u32 = @intCast(std.mem.count(u8, source, "\n") + 1);

            try file_infos.append(alloc, .{
                .uri        = furi,
                .start_line = start_line,
                .line_count = line_count,
            });
            try combined.appendSlice(alloc, source);
            if (combined.items.len > 0 and combined.items[combined.items.len - 1] != '\n')
                try combined.append(alloc, '\n');
        }

        if (combined.items.len == 0) return;

        var result = try analyzeWithUri(combined.items, uri, alloc);
        defer result.deinit();

        // Publish diagnostics for every compiler file, mapping line numbers back.
        for (file_infos.items) |fi| {
            var buf: std.ArrayListUnmanaged(u8) = .{};
            defer buf.deinit(alloc);
            try buf.appendSlice(alloc, "{\"uri\":");
            try jsonStr(&buf, alloc, fi.uri);
            try buf.appendSlice(alloc, ",\"diagnostics\":[");

            var first = true;
            for (result.diags.items.items) |d| {
                const s = d.span;
                if (s.line <= result.prelude_line_offset) continue;
                // Convert 1-indexed sema line → 0-indexed combined line.
                const combined_line: u32 = s.line - result.prelude_line_offset - 1;
                if (combined_line < fi.start_line) continue;
                if (combined_line >= fi.start_line + fi.line_count) continue;

                const local_line: u32 = combined_line - fi.start_line;
                const sc: u32 = if (s.col > 0) s.col - 1 else 0;
                const ec: u32 = sc + s.len;
                const severity: u32 = switch (d.level) {
                    .err  => 1,
                    .warn => 2,
                    .note => 3,
                };

                if (!first) try buf.append(alloc, ',');
                first = false;

                const hdr = try std.fmt.allocPrint(alloc,
                    \\{{"range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}},"severity":{d},"source":"chasm","message":
                    , .{ local_line, sc, local_line, ec, severity });
                defer alloc.free(hdr);
                try buf.appendSlice(alloc, hdr);
                try jsonStr(&buf, alloc, d.message);
                try buf.append(alloc, '}');
            }

            try buf.appendSlice(alloc, "]}");
            const params_json = try buf.toOwnedSlice(alloc);
            defer alloc.free(params_json);
            try jsonrpc.writeNotification(writer, "textDocument/publishDiagnostics", params_json);
        }
    }
};

// ---------------------------------------------------------------------------
// JSON accessor helpers
// ---------------------------------------------------------------------------

fn getNestedStr(val: ?std.json.Value, keys: []const []const u8) ?[]const u8 {
    var cur: std.json.Value = val orelse return null;
    for (keys) |k| {
        cur = switch (cur) {
            .object => |o| o.get(k) orelse return null,
            else    => return null,
        };
    }
    return switch (cur) {
        .string => |s| s,
        else    => null,
    };
}

fn extractUriAndText(
    params: ?std.json.Value,
    doc_key: []const u8,
    text_key: []const u8,
) ?struct { []const u8, []const u8 } {
    const obj = switch (params orelse return null) {
        .object => |o| o,
        else    => return null,
    };
    const doc = switch (obj.get(doc_key) orelse return null) {
        .object => |o| o,
        else    => return null,
    };
    const uri = switch (doc.get("uri") orelse return null) {
        .string => |s| s,
        else    => return null,
    };
    const text = switch (doc.get(text_key) orelse return null) {
        .string => |s| s,
        else    => return null,
    };
    return .{ uri, text };
}

// ---------------------------------------------------------------------------
// Signature help — call context detection
// ---------------------------------------------------------------------------

/// Scan the source text backward from (line, col) to find the enclosing
/// function call.  Returns the function name and the 0-based index of the
/// argument the cursor is in (counted by commas at the same nesting depth).
fn findCallContext(source: []const u8, line: u32, col: u32) ?struct { name: []const u8, active_param: u32 } {
    // Locate the cursor byte offset.
    var offset: usize = 0;
    var cur_line: u32 = 0;
    while (offset < source.len) {
        if (cur_line == line) {
            offset += @min(@as(usize, col), source.len - offset);
            break;
        }
        if (source[offset] == '\n') cur_line += 1;
        offset += 1;
    }
    if (offset == 0) return null;

    var depth: i32 = 0;
    var commas: u32 = 0;
    var i = offset;
    while (i > 0) {
        i -= 1;
        switch (source[i]) {
            ')' => depth += 1,
            '(' => {
                if (depth == 0) {
                    // Found the opening paren of the enclosing call.
                    // Walk backwards past any whitespace to find the identifier.
                    var j = i;
                    while (j > 0 and source[j - 1] == ' ') j -= 1;
                    const id_end = j;
                    while (j > 0 and callIdentChar(source[j - 1])) j -= 1;
                    const name = source[j..id_end];
                    if (name.len == 0) return null;
                    return .{ .name = name, .active_param = commas };
                }
                depth -= 1;
            },
            ',' => if (depth == 0) { commas += 1; },
            '\n' => break, // don't cross line boundaries
            else => {},
        }
    }
    return null;
}

fn callIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
           (c >= '0' and c <= '9') or c == '_';
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "analyze returns diagnostics for undefined name" {
    var result = try analyze(
        \\def f() do
        \\  undefined_var
        \\end
    , testing.allocator);
    defer result.deinit();
    try testing.expect(result.diags.hasErrors());
}

test "analyze clean source produces no diagnostics" {
    var result = try analyze(
        \\def f() do
        \\  x :: frame = 42
        \\  x
        \\end
    , testing.allocator);
    defer result.deinit();
    try testing.expect(!result.diags.hasErrors());
}

test "findNodeAt locates ident token" {
    // "x" is on line 2 (0-indexed: 1), col 3 (0-indexed: 2) in:
    //   def f() do\n  x :: frame = 42\n  x\nend
    var result = try analyze(
        \\def f() do
        \\  x :: frame = 42
        \\  x
        \\end
    , testing.allocator);
    defer result.deinit();
    // Line 1 (0-indexed) = "  x :: frame = 42", char 2 = 'x'.
    const found = findNodeAt(&result.pool, 1, 2);
    try testing.expect(found != null);
}

test "buildDiagnosticsJson produces valid JSON structure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var result = try analyze(
        \\def f() do
        \\  bad_name
        \\end
    , alloc);
    defer result.deinit();

    const json = try buildDiagnosticsJson("file:///test.chasm", &result, alloc);
    try testing.expect(std.mem.indexOf(u8, json, "\"uri\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"diagnostics\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"severity\"") != null);
}

test "buildHoverJson produces lifetime info" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var result = try analyze(
        \\def f() do
        \\  x :: frame = 42
        \\end
    , alloc);
    defer result.deinit();

    // Any node index that has solved lifetime.
    if (result.pool.len() > 0) {
        const json = try buildHoverJson(&result, 0, alloc);
        try testing.expect(std.mem.indexOf(u8, json, "lifetime") != null);
        try testing.expect(std.mem.indexOf(u8, json, "markdown") != null);
    }
}

test "server handleMessage initialize" {
    var server = Server.init();
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    ;
    var out_buf: std.ArrayListUnmanaged(u8) = .{};
    defer out_buf.deinit(testing.allocator);

    try server.handleMessage(msg, out_buf.writer(testing.allocator));

    const out = out_buf.items;
    try testing.expect(std.mem.indexOf(u8, out, "capabilities") != null);
    try testing.expect(std.mem.indexOf(u8, out, "hoverProvider") != null);
}

test "server handleMessage unknown method returns error" {
    var server = Server.init();
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/unknownMethod","params":{}}
    ;
    var out_buf: std.ArrayListUnmanaged(u8) = .{};
    defer out_buf.deinit(testing.allocator);

    try server.handleMessage(msg, out_buf.writer(testing.allocator));
    const out = out_buf.items;
    try testing.expect(std.mem.indexOf(u8, out, "error") != null);
}

test "server didOpen triggers diagnostics" {
    var server = Server.init();
    defer server.deinit();

    const msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.chasm","languageId":"chasm","version":1,"text":"def f() do\n  bad\nend"}}}
    ;
    var out_buf: std.ArrayListUnmanaged(u8) = .{};
    defer out_buf.deinit(testing.allocator);

    try server.handleMessage(msg, out_buf.writer(testing.allocator));
    const out = out_buf.items;
    try testing.expect(std.mem.indexOf(u8, out, "publishDiagnostics") != null);
}
