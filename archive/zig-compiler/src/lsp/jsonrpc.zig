/// JSON-RPC 2.0 message framing over stdio.
///
/// LSP uses HTTP-style headers followed by a blank line, then the JSON body:
///
///   Content-Length: 123\r\n
///   \r\n
///   {"jsonrpc":"2.0",...}
///
/// `readMessage`  — reads one complete message; caller owns the returned slice.
/// `writeMessage` — writes Content-Length framing then the JSON payload.
/// `writeResponse`/ `writeNotification` — convenience wrappers.

const std = @import("std");

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

pub const ReadError = error{
    MissingContentLength,
    InvalidContentLength,
    EndOfStream,
} || std.mem.Allocator.Error || error{StreamTooLong};

/// Read one JSON-RPC message from `reader`.  Caller owns the returned slice.
pub fn readMessage(reader: anytype, allocator: std.mem.Allocator) ![]u8 {
    var content_length: ?usize = null;
    var header_buf: [512]u8 = undefined;

    // Read header lines until we see a blank line.
    while (true) {
        const line = reader.readUntilDelimiter(&header_buf, '\n') catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return err,
        };
        // Strip trailing \r if present.
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;
        if (trimmed.len == 0) break; // blank line — end of headers
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            const rest = std.mem.trimLeft(u8, trimmed["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, rest, 10) catch
                return error.InvalidContentLength;
        }
    }

    const length = content_length orelse return error.MissingContentLength;
    const body = try allocator.alloc(u8, length);
    errdefer allocator.free(body);
    try reader.readNoEof(body);
    return body;
}

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

/// Write a raw JSON payload with Content-Length framing.
pub fn writeMessage(writer: anytype, data: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ data.len, data });
}

/// Write a successful JSON-RPC response.
/// `id_json` must be a valid JSON fragment (e.g. `"1"`, `"\"abc\""`, `"null"`).
/// `result_json` must be a valid JSON fragment.
pub fn writeResponse(writer: anytype, id_json: []const u8, result_json: []const u8) !void {
    var buf: [65536]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","id":{s},"result":{s}}}
        , .{ id_json, result_json });
    try writeMessage(writer, msg);
}

/// Write a JSON-RPC error response.
pub fn writeError(
    writer: anytype,
    id_json: []const u8,
    code: i32,
    message: []const u8,
) !void {
    var buf: [4096]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","id":{s},"error":{{"code":{d},"message":"{s}"}}}}
        , .{ id_json, code, message });
    try writeMessage(writer, msg);
}

/// Write a JSON-RPC notification (no id, no response expected).
pub fn writeNotification(writer: anytype, method: []const u8, params_json: []const u8) !void {
    var buf: [65536]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","method":"{s}","params":{s}}}
        , .{ method, params_json });
    try writeMessage(writer, msg);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "writeMessage adds Content-Length header" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeMessage(fbs.writer(), "{\"hello\":1}");
    const out = fbs.getWritten();
    try testing.expect(std.mem.startsWith(u8, out, "Content-Length: 11\r\n\r\n"));
    try testing.expect(std.mem.endsWith(u8, out, "{\"hello\":1}"));
}

test "readMessage parses Content-Length correctly" {
    const raw = "Content-Length: 15\r\n\r\n{\"method\":\"hi\"}";
    var fbs = std.io.fixedBufferStream(raw);
    const msg = try readMessage(fbs.reader(), testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("{\"method\":\"hi\"}", msg);
}

test "readMessage case-insensitive header" {
    const raw = "content-length: 4\r\n\r\nnull";
    var fbs = std.io.fixedBufferStream(raw);
    const msg = try readMessage(fbs.reader(), testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("null", msg);
}

test "writeResponse formats correctly" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeResponse(fbs.writer(), "1", "null");
    const out = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, out, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"result\":null") != null);
}

test "writeNotification formats correctly" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeNotification(fbs.writer(), "textDocument/publishDiagnostics", "{\"uri\":\"x\"}");
    const out = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, out, "publishDiagnostics") != null);
}
