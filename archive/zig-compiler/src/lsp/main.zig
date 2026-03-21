const std    = @import("std");
const server = @import("server");

pub fn main() !void {
    var srv = server.Server.init();
    defer srv.deinit();

    const stdin  = std.fs.File.stdin().deprecatedReader();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Suppress all debug/info/warn logs; only errors reach stderr.
    // (LSP clients connect stdout/stdin — any extraneous output breaks framing.)
    srv.run(stdin, stdout) catch |err| {
        std.log.err("chasm-lsp fatal: {}", .{err});
        std.process.exit(1);
    };
}
