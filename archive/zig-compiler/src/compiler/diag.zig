const std = @import("std");
const Lifetime = @import("runtime").Lifetime;

pub const Span = struct {
    line: u32,
    col: u32,
    len: u32,
};

pub const Level = enum { err, warn, note };

pub const Diag = struct {
    level: Level,
    span: Span,
    message: []const u8,
};

pub const DiagList = struct {
    items: std.ArrayListUnmanaged(Diag) = .{},
    allocator: std.mem.Allocator,
    /// Optional source text for caret rendering.
    source: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) DiagList {
        return .{ .allocator = allocator };
    }

    pub fn initWithSource(allocator: std.mem.Allocator, source: []const u8) DiagList {
        return .{ .allocator = allocator, .source = source };
    }

    pub fn deinit(self: *DiagList) void {
        for (self.items.items) |d| self.allocator.free(d.message);
        self.items.deinit(self.allocator);
    }

    pub fn err(self: *DiagList, span: Span, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.items.append(self.allocator, .{ .level = .err, .span = span, .message = msg });
    }

    pub fn warn(self: *DiagList, span: Span, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.items.append(self.allocator, .{ .level = .warn, .span = span, .message = msg });
    }

    pub fn note(self: *DiagList, span: Span, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.items.append(self.allocator, .{ .level = .note, .span = span, .message = msg });
    }

    pub fn hasErrors(self: *const DiagList) bool {
        for (self.items.items) |d| {
            if (d.level == .err) return true;
        }
        return false;
    }

    pub fn render(self: *const DiagList, source_path: []const u8, writer: anytype) !void {
        for (self.items.items) |d| {
            const level_str = switch (d.level) {
                .err => "error",
                .warn => "warning",
                .note => "note",
            };
            try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{
                source_path,
                d.span.line,
                d.span.col,
                level_str,
                d.message,
            });

            // Optionally print the source line with caret.
            if (self.source) |src| {
                const line_text = getLine(src, d.span.line);
                if (line_text.len > 0) {
                    try writer.print("  {s}\n", .{line_text});
                    // Caret: col is 1-based
                    const col0: usize = if (d.span.col > 0) d.span.col - 1 else 0;
                    const caret_len: usize = if (d.span.len > 0) d.span.len else 1;
                    // Print spaces then carets
                    const spaces = "                                                                ";
                    const carets = "^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^";
                    const sp = spaces[0..@min(col0 + 2, spaces.len)]; // +2 for "  " prefix
                    const ca = carets[0..@min(caret_len, carets.len)];
                    try writer.print("{s}{s}\n", .{ sp, ca });
                }
            }
        }
    }
};

/// Extract the Nth line (1-based) from source text.
fn getLine(src: []const u8, line_num: u32) []const u8 {
    var current_line: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\n') {
            if (current_line == line_num) {
                return src[line_start..i];
            }
            current_line += 1;
            line_start = i + 1;
        }
    }
    // Last line (no trailing newline)
    if (current_line == line_num) {
        return src[line_start..];
    }
    return "";
}

/// Lifetime mismatch error with a fix-it hint.
pub fn lifetimeMismatch(
    diags: *DiagList,
    span: Span,
    src_lt: Lifetime,
    dst_lt: Lifetime,
) !void {
    try diags.err(span, "cannot assign {s}-lifetime value to {s}-lifetime variable (lifetimes can only move up: Frame < Script < Persistent)", .{
        src_lt.name(),
        dst_lt.name(),
    });
    const fixit = switch (dst_lt) {
        .frame => "Frame is the shortest lifetime; Script/Persistent values cannot move down — redesign so data flows upward",
        .script => "use CopyToScript(...) to explicitly promote this value",
        .persistent => "use PersistCopy(...) to explicitly promote this value",
    };
    try diags.note(span, "fix: {s}", .{fixit});
}

/// Warn when a promotion call appears inside the hot path (per-frame function).
pub fn promotionInHotPath(diags: *DiagList, span: Span, dst_lt: Lifetime) !void {
    try diags.warn(span, "promotion to {s} inside a per-frame function — this allocates every tick", .{dst_lt.name()});
    try diags.note(span, "consider moving initialization to an on-load handler to pay the cost once", .{});
}
