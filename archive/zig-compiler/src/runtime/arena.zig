const std = @import("std");
const assert = std.debug.assert;

pub const Lifetime = enum(u2) {
    frame = 0,
    script = 1,
    persistent = 2,

    pub fn name(self: Lifetime) []const u8 {
        return switch (self) {
            .frame => "Frame",
            .script => "Script",
            .persistent => "Persistent",
        };
    }
};

/// Three bump-allocator arenas, one per lifetime region.
/// Frame  — cleared every tick (retain_capacity to avoid syscall overhead)
/// Script — cleared on hot-reload (free_all)
/// Persistent — never cleared by the runtime
pub const ArenaTriple = struct {
    frame: std.heap.ArenaAllocator,
    script: std.heap.ArenaAllocator,
    persistent: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator) ArenaTriple {
        return .{
            .frame = std.heap.ArenaAllocator.init(backing),
            .script = std.heap.ArenaAllocator.init(backing),
            .persistent = std.heap.ArenaAllocator.init(backing),
        };
    }

    pub fn deinit(self: *ArenaTriple) void {
        self.frame.deinit();
        self.script.deinit();
        self.persistent.deinit();
    }

    pub fn allocator(self: *ArenaTriple, lt: Lifetime) std.mem.Allocator {
        return switch (lt) {
            .frame => self.frame.allocator(),
            .script => self.script.allocator(),
            .persistent => self.persistent.allocator(),
        };
    }

    /// Allocate raw bytes into the given lifetime arena.
    pub fn alloc(self: *ArenaTriple, lt: Lifetime, n: usize, alignment: std.mem.Alignment) ![]u8 {
        _ = alignment;
        return self.allocator(lt).alloc(u8, n);
    }

    /// Deep-copy bytes from src_lt arena into dst_lt arena.
    /// dst_lt must be >= src_lt (monotone movement only).
    pub fn promote(
        self: *ArenaTriple,
        src_lt: Lifetime,
        dst_lt: Lifetime,
        bytes: []const u8,
        alignment: std.mem.Alignment,
    ) ![]u8 {
        assert(@intFromEnum(dst_lt) >= @intFromEnum(src_lt));
        const dst = try self.alloc(dst_lt, bytes.len, alignment);
        @memcpy(dst, bytes);
        return dst;
    }

    /// End of tick: reset frame arena, retaining committed pages.
    pub fn clearFrame(self: *ArenaTriple) void {
        _ = self.frame.reset(.retain_capacity);
    }

    /// Hot-reload: reset script arena, freeing all pages.
    pub fn clearScript(self: *ArenaTriple) void {
        _ = self.script.reset(.free_all);
    }

    pub fn stats(self: *ArenaTriple) ArenaStats {
        return .{
            .frame_bytes = self.frame.queryCapacity(),
            .script_bytes = self.script.queryCapacity(),
            .persistent_bytes = self.persistent.queryCapacity(),
        };
    }
};

pub const ArenaStats = struct {
    frame_bytes: usize,
    script_bytes: usize,
    persistent_bytes: usize,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "basic alloc per lifetime" {
    var arenas = ArenaTriple.init(std.testing.allocator);
    defer arenas.deinit();

    const f = try arenas.allocator(.frame).alloc(u8, 16);
    const s = try arenas.allocator(.script).alloc(u8, 16);
    const p = try arenas.allocator(.persistent).alloc(u8, 16);
    _ = f;
    _ = s;
    _ = p;
}

test "promote frame->script survives clearFrame" {
    var arenas = ArenaTriple.init(std.testing.allocator);
    defer arenas.deinit();

    // Allocate in frame and write a value.
    const frame_mem = try arenas.allocator(.frame).alloc(u8, 4);
    @memcpy(frame_mem, "test");

    // Promote to script before clearing frame.
    const script_mem = try arenas.promote(.frame, .script, frame_mem, .@"1");
    arenas.clearFrame();

    // The promoted copy must still be valid.
    try std.testing.expectEqualSlices(u8, "test", script_mem);
}

test "promote script->persistent survives clearScript" {
    var arenas = ArenaTriple.init(std.testing.allocator);
    defer arenas.deinit();

    const script_mem = try arenas.allocator(.script).alloc(u8, 5);
    @memcpy(script_mem, "hello");

    const persist_mem = try arenas.promote(.script, .persistent, script_mem, .@"1");
    arenas.clearScript();

    try std.testing.expectEqualSlices(u8, "hello", persist_mem);
}

test "clearScript does not touch persistent" {
    var arenas = ArenaTriple.init(std.testing.allocator);
    defer arenas.deinit();

    const p = try arenas.allocator(.persistent).alloc(u8, 3);
    @memcpy(p, "abc");

    arenas.clearScript();

    try std.testing.expectEqualSlices(u8, "abc", p);
}

test "hot-reload simulation" {
    var arenas = ArenaTriple.init(std.testing.allocator);
    defer arenas.deinit();

    // Write persistent data (save game).
    const save = try arenas.allocator(.persistent).alloc(u8, 4);
    @memcpy(save, "save");

    // First "load": script-scope global.
    var script_global = try arenas.allocator(.script).alloc(u8, 5);
    @memcpy(script_global, "v1.00");

    // Hot-reload: tear down script, re-init.
    arenas.clearScript();
    script_global = try arenas.allocator(.script).alloc(u8, 5);
    @memcpy(script_global, "v1.01");

    // Persistent must be untouched.
    try std.testing.expectEqualSlices(u8, "save", save);
    try std.testing.expectEqualSlices(u8, "v1.01", script_global);
}

test "promote enforces monotone ordering (debug assert)" {
    // This test documents the contract; the assert fires in debug builds.
    // In release builds we trust the compiler-inserted promotion calls.
    _ = Lifetime.script; // Frame < Script < Persistent enforced by enum ordinal
    try std.testing.expect(@intFromEnum(Lifetime.frame) < @intFromEnum(Lifetime.script));
    try std.testing.expect(@intFromEnum(Lifetime.script) < @intFromEnum(Lifetime.persistent));
}
