/// Hot-reload analysis pass.
///
/// Compares two compiled `IrModule`s — the running version and the candidate
/// replacement — and classifies every module @attr as one of:
///
///   preserved   same name + same type + same lifetime  → value survives reload
///   lost        same name but type or lifetime changed  → value is reset
///   added       attr exists only in new version        → initialized fresh
///   removed     attr exists only in old version        → value discarded
///
/// Reload safety:
///   `ReloadReport.safe_reload` is true iff every script- or
///   persistent-lifetime attr in the new version is `preserved`.
///   Frame-lifetime attrs are always safe (they're cleared every tick anyway).
///
/// Usage:
///   const report = try reload.diff(old_module, new_module, allocator);
///   try reload.renderReport(report, writer);
///   if (!report.safe_reload) { /* warn user, offer to proceed */ }

const std      = @import("std");
const ir_mod   = @import("ir");
const sema_mod = @import("sema");
const Lifetime = @import("runtime").Lifetime;

const IrModule = ir_mod.IrModule;
const IrAttr   = ir_mod.IrAttr;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// How an attr's value fares across a module reload.
pub const Compat = enum {
    /// Value survives: same name, same type, same lifetime.
    preserved,
    /// Value is reset: type or lifetime annotation changed.
    lost,
    /// Attr is new in the incoming version; initialised fresh.
    added,
    /// Attr was removed; value is discarded.
    removed,
};

pub const AttrDiff = struct {
    name:         []const u8,
    compat:       Compat,
    old_type_id:  u32,
    new_type_id:  u32,
    old_lifetime: Lifetime,
    new_lifetime: Lifetime,
};

pub const ReloadReport = struct {
    diffs:       []const AttrDiff,
    /// True iff every script/persistent attr in the new version is `preserved`.
    safe_reload: bool,
    preserved:   u32,
    lost:        u32,
    added:       u32,
    removed:     u32,
};

// ---------------------------------------------------------------------------
// Diff engine
// ---------------------------------------------------------------------------

/// Compare two compiled modules and produce a `ReloadReport`.
/// All returned slices are owned by `allocator`.
pub fn diff(
    old: IrModule,
    new: IrModule,
    allocator: std.mem.Allocator,
) !ReloadReport {
    var result = std.ArrayListUnmanaged(AttrDiff){};
    var preserved: u32 = 0;
    var lost:      u32 = 0;
    var added:     u32 = 0;
    var removed:   u32 = 0;

    // Index old attrs by name for O(1) lookup.
    var old_map = std.StringHashMapUnmanaged(IrAttr){};
    defer old_map.deinit(allocator);
    for (old.attrs) |a| try old_map.put(allocator, a.name, a);

    // Walk new attrs: classify each against the old version.
    for (new.attrs) |new_a| {
        if (old_map.get(new_a.name)) |old_a| {
            const compat: Compat = if (old_a.type_id == new_a.type_id and
                old_a.lifetime == new_a.lifetime)
                .preserved
            else
                .lost;
            try result.append(allocator, .{
                .name         = new_a.name,
                .compat       = compat,
                .old_type_id  = old_a.type_id,
                .new_type_id  = new_a.type_id,
                .old_lifetime = old_a.lifetime,
                .new_lifetime = new_a.lifetime,
            });
            if (compat == .preserved) preserved += 1 else lost += 1;
        } else {
            try result.append(allocator, .{
                .name         = new_a.name,
                .compat       = .added,
                .old_type_id  = 0,
                .new_type_id  = new_a.type_id,
                .old_lifetime = .frame,
                .new_lifetime = new_a.lifetime,
            });
            added += 1;
        }
    }

    // Find attrs present in old but absent in new (removed).
    for (old.attrs) |old_a| {
        var found = false;
        for (new.attrs) |new_a| {
            if (std.mem.eql(u8, old_a.name, new_a.name)) { found = true; break; }
        }
        if (!found) {
            try result.append(allocator, .{
                .name         = old_a.name,
                .compat       = .removed,
                .old_type_id  = old_a.type_id,
                .new_type_id  = 0,
                .old_lifetime = old_a.lifetime,
                .new_lifetime = .frame,
            });
            removed += 1;
        }
    }

    // Safe iff no persistent or script attr is lost.
    const safe = blk: {
        for (result.items) |d| {
            if (d.compat == .lost and
                (d.new_lifetime == .script or d.new_lifetime == .persistent))
                break :blk false;
            // removed attrs with non-frame lifetime also break safety.
            if (d.compat == .removed and
                (d.old_lifetime == .script or d.old_lifetime == .persistent))
                break :blk false;
        }
        break :blk true;
    };

    return ReloadReport{
        .diffs       = try result.toOwnedSlice(allocator),
        .safe_reload = safe,
        .preserved   = preserved,
        .lost        = lost,
        .added       = added,
        .removed     = removed,
    };
}

// ---------------------------------------------------------------------------
// Report renderer
// ---------------------------------------------------------------------------

/// Print a human-readable reload report to `writer`.
pub fn renderReport(report: ReloadReport, writer: anytype) !void {
    if (report.diffs.len == 0) {
        try writer.print("  (no module attributes)\n", .{});
        return;
    }

    for (report.diffs) |d| {
        const icon: []const u8 = switch (d.compat) {
            .preserved => "✓",
            .lost      => "✗",
            .added     => "+",
            .removed   => "-",
        };
        const detail: []const u8 = switch (d.compat) {
            .preserved => "preserved",
            .lost      => "lost (type or lifetime changed)",
            .added     => "new — initialized fresh",
            .removed   => "removed — value discarded",
        };
        const lt = switch (d.compat) {
            .removed => d.old_lifetime,
            else     => d.new_lifetime,
        };
        try writer.print("  @{s:<20} :: {s:<10}  {s}  {s}\n",
            .{ d.name, @tagName(lt), icon, detail });
    }

    try writer.print("\n", .{});
    if (report.safe_reload) {
        try writer.print("Safe to hot-reload: yes  ({d} preserved", .{report.preserved});
    } else {
        try writer.print("Safe to hot-reload: NO   ({d} lost", .{report.lost});
    }
    if (report.added   > 0) try writer.print(", {d} added",   .{report.added});
    if (report.removed > 0) try writer.print(", {d} removed", .{report.removed});
    try writer.print(")\n", .{});
}

/// Emit a C migration stub with inline documentation of what state survives.
/// The stub is suitable for inclusion in the generated `.c` file.
pub fn emitMigrationFn(report: ReloadReport, writer: anytype) !void {
    try writer.print(
        \\/* Hot-reload migration — call this after dlopen'ing the new module.
        \\ * The host engine must preserve ChasmCtx across the swap.
        \\ * Frame state is always discarded (cleared each tick).
        \\ *
        , .{});

    for (report.diffs) |d| {
        const status: []const u8 = switch (d.compat) {
            .preserved => "preserved",
            .lost      => "RESET (type changed)",
            .added     => "initialized fresh",
            .removed   => "discarded",
        };
        try writer.print(" *   @{s}: {s}\n", .{ d.name, status });
    }

    try writer.print(
        \\ */
        \\void chasm_reload_migrate(ChasmCtx *ctx) {{
        \\    chasm_clear_frame(ctx);
        , .{});

    // Re-initialize attrs that are new or lost (need fresh values).
    var needs_init = false;
    for (report.diffs) |d| {
        if (d.compat == .added or d.compat == .lost) { needs_init = true; break; }
    }
    if (needs_init) {
        try writer.print("\n    /* Re-initialise changed/added attrs: */\n", .{});
        try writer.print("    chasm_module_init(ctx);\n", .{});
    }

    try writer.print("}}\n\n", .{});
}

// ---------------------------------------------------------------------------
// Attr snapshot (lightweight, heap-stable representation for watch mode)
// ---------------------------------------------------------------------------

/// A minimal copy of module attr metadata that survives arena resets.
pub const AttrSnapshot = struct {
    name:     []const u8,
    type_id:  u32,
    lifetime: Lifetime,
};

pub const ModuleSnapshot = struct {
    attrs: []AttrSnapshot,

    pub fn capture(module: IrModule, allocator: std.mem.Allocator) !ModuleSnapshot {
        const attrs = try allocator.alloc(AttrSnapshot, module.attrs.len);
        for (module.attrs, 0..) |a, i| {
            attrs[i] = .{
                .name     = try allocator.dupe(u8, a.name),
                .type_id  = a.type_id,
                .lifetime = a.lifetime,
            };
        }
        return .{ .attrs = attrs };
    }

    pub fn deinit(self: *ModuleSnapshot, allocator: std.mem.Allocator) void {
        for (self.attrs) |a| allocator.free(a.name);
        allocator.free(self.attrs);
    }

    /// Convert snapshot back to a minimal IrModule for diffing.
    pub fn toIrModule(self: *const ModuleSnapshot, allocator: std.mem.Allocator) !IrModule {
        const attrs = try allocator.alloc(IrAttr, self.attrs.len);
        for (self.attrs, 0..) |a, i| {
            attrs[i] = .{
                .name      = a.name,
                .lifetime  = a.lifetime,
                .type_id   = a.type_id,
                .init_temp = 0,
            };
        }
        return IrModule{
            .functions        = &.{},
            .attrs            = attrs,
            .attr_init_instrs = &.{},
            .attr_init_temps  = &.{},
            .enum_variants    = &.{},
            .extern_fns       = &.{},
            .imported_fwd_decls = &.{},
            .struct_defs      = &.{},
            .tuple_returns    = &.{},
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeModule(attr_defs: []const struct { name: []const u8, type_id: u32, lifetime: Lifetime }) IrModule {
    const attrs = testing.allocator.alloc(IrAttr, attr_defs.len) catch unreachable;
    for (attr_defs, 0..) |a, i| {
        attrs[i] = .{ .name = a.name, .type_id = a.type_id, .lifetime = a.lifetime, .init_temp = 0 };
    }
    return IrModule{
        .functions = &.{}, .attrs = attrs,
        .attr_init_instrs = &.{}, .attr_init_temps = &.{},
        .enum_variants = &.{}, .extern_fns = &.{},
        .imported_fwd_decls = &.{},
        .struct_defs = &.{},
        .tuple_returns = &.{},
    };
}

test "identical modules produce all-preserved report" {
    const old = makeModule(&.{
        .{ .name = "score",      .type_id = 1, .lifetime = .script },
        .{ .name = "high_score", .type_id = 1, .lifetime = .persistent },
    });
    defer testing.allocator.free(old.attrs);
    const new = makeModule(&.{
        .{ .name = "score",      .type_id = 1, .lifetime = .script },
        .{ .name = "high_score", .type_id = 1, .lifetime = .persistent },
    });
    defer testing.allocator.free(new.attrs);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const report = try diff(old, new, arena.allocator());

    try testing.expect(report.safe_reload);
    try testing.expectEqual(@as(u32, 2), report.preserved);
    try testing.expectEqual(@as(u32, 0), report.lost);
}

test "type change marks attr as lost, unsafe reload" {
    const old = makeModule(&.{
        .{ .name = "score", .type_id = 1, .lifetime = .script }, // T_INT
    });
    defer testing.allocator.free(old.attrs);
    const new = makeModule(&.{
        .{ .name = "score", .type_id = 2, .lifetime = .script }, // T_FLOAT
    });
    defer testing.allocator.free(new.attrs);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const report = try diff(old, new, arena.allocator());

    try testing.expect(!report.safe_reload);
    try testing.expectEqual(@as(u32, 1), report.lost);
    try testing.expectEqual(Compat.lost, report.diffs[0].compat);
}

test "added attr is safe (fresh init)" {
    const old = makeModule(&.{
        .{ .name = "score", .type_id = 1, .lifetime = .script },
    });
    defer testing.allocator.free(old.attrs);
    const new = makeModule(&.{
        .{ .name = "score",   .type_id = 1, .lifetime = .script },
        .{ .name = "new_var", .type_id = 1, .lifetime = .script },
    });
    defer testing.allocator.free(new.attrs);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const report = try diff(old, new, arena.allocator());

    try testing.expect(report.safe_reload); // added attr is safe
    try testing.expectEqual(@as(u32, 1), report.added);
    try testing.expectEqual(@as(u32, 1), report.preserved);
}

test "removed script attr makes reload unsafe" {
    const old = makeModule(&.{
        .{ .name = "score",       .type_id = 1, .lifetime = .script },
        .{ .name = "temp_buffer", .type_id = 1, .lifetime = .script },
    });
    defer testing.allocator.free(old.attrs);
    const new = makeModule(&.{
        .{ .name = "score", .type_id = 1, .lifetime = .script },
    });
    defer testing.allocator.free(new.attrs);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const report = try diff(old, new, arena.allocator());

    try testing.expect(!report.safe_reload);
    try testing.expectEqual(@as(u32, 1), report.removed);
}

test "lifetime upgrade is considered lost" {
    // Changing @score from script to persistent = different contract.
    const old = makeModule(&.{
        .{ .name = "score", .type_id = 1, .lifetime = .script },
    });
    defer testing.allocator.free(old.attrs);
    const new = makeModule(&.{
        .{ .name = "score", .type_id = 1, .lifetime = .persistent },
    });
    defer testing.allocator.free(new.attrs);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const report = try diff(old, new, arena.allocator());

    try testing.expect(!report.safe_reload);
    try testing.expectEqual(Compat.lost, report.diffs[0].compat);
}

test "renderReport writes human-readable output" {
    const old = makeModule(&.{
        .{ .name = "score",      .type_id = 1, .lifetime = .script },
        .{ .name = "high_score", .type_id = 1, .lifetime = .persistent },
    });
    defer testing.allocator.free(old.attrs);
    const new = makeModule(&.{
        .{ .name = "score",      .type_id = 2, .lifetime = .script }, // type changed
        .{ .name = "high_score", .type_id = 1, .lifetime = .persistent },
        .{ .name = "speed",      .type_id = 2, .lifetime = .script }, // added
    });
    defer testing.allocator.free(new.attrs);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const report = try diff(old, new, arena.allocator());

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try renderReport(report, fbs.writer());
    const out = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, out, "preserved") != null);
    try testing.expect(std.mem.indexOf(u8, out, "lost") != null);
    try testing.expect(std.mem.indexOf(u8, out, "NO") != null);
}

test "AttrSnapshot round-trips through toIrModule" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const src = makeModule(&.{
        .{ .name = "score", .type_id = 1, .lifetime = .script },
    });
    defer testing.allocator.free(src.attrs);

    var snap = try ModuleSnapshot.capture(src, alloc);
    defer snap.deinit(alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const rebuilt = try snap.toIrModule(arena.allocator());
    try testing.expectEqual(@as(usize, 1), rebuilt.attrs.len);
    try testing.expectEqualStrings("score", rebuilt.attrs[0].name);
}
