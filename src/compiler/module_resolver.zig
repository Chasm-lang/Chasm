/// Module resolver for Chasm.
///
/// Resolves `import "path/to/module"` relative to the importing file's
/// directory, appending `.chasm` if the path has no extension.

const std = @import("std");

/// Resolve `import_path` relative to the directory of `importing_file`.
/// Returns a heap-allocated absolute path (caller must free).
pub fn resolve(
    importing_file: []const u8,
    import_path: []const u8,
    alloc: std.mem.Allocator,
) ![]const u8 {
    // Append .chasm extension if not present.
    const needs_ext = !std.mem.endsWith(u8, import_path, ".chasm");
    const with_ext = if (needs_ext)
        try std.fmt.allocPrint(alloc, "{s}.chasm", .{import_path})
    else
        try alloc.dupe(u8, import_path);
    defer alloc.free(with_ext);

    // Absolute import paths are used as-is (no directory joining).
    const joined = if (std.fs.path.isAbsolute(with_ext))
        try alloc.dupe(u8, with_ext)
    else blk: {
        // Get directory of the importing file and join.
        const dir = std.fs.path.dirname(importing_file) orelse ".";
        break :blk try std.fs.path.join(alloc, &.{ dir, with_ext });
    };
    errdefer alloc.free(joined);

    // Attempt to resolve to an absolute path; on failure return the joined path.
    if (std.fs.cwd().realpathAlloc(alloc, joined)) |abs| {
        alloc.free(joined);
        return abs;
    } else |_| {
        // File not found or other error — return joined path anyway.
        return joined;
    }
}

/// Extract the module name (basename without extension) from a path.
pub fn moduleName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".chasm")) {
        return base[0 .. base.len - ".chasm".len];
    }
    return base;
}
