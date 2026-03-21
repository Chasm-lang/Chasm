/// Lifetime inference engine.
///
/// Algorithm:
///  1. Walk the AST, assign a LifetimeVar to every expression node.
///  2. Collect constraints from variable declarations, assignments, and
///     promotions.
///  3. Solve: each var gets the maximum Lifetime bound from its constraints.
///     Vars with no constraints default to .frame.
///  4. Walk assignments again; where the resolved src lifetime > dst lifetime,
///     emit a lifetimeMismatch diagnostic.
///  5. Insert synthetic `promote` nodes at valid escape sites (where the
///     compiler can satisfy the constraint automatically, e.g. return from
///     a Script-lifetime function).

const std = @import("std");
const Lifetime = @import("runtime").Lifetime;
const ast = @import("ast");
const NodeIndex = ast.NodeIndex;
const AstPool = ast.AstPool;
const LifetimeAnnotation = ast.LifetimeAnnotation;
const diag = @import("diag");
const DiagList = diag.DiagList;
const Span = diag.Span;

pub const LifetimeVar = u32;

pub const Constraint = union(enum) {
    /// `lv` must be >= `bound`.
    at_least: struct { lv: LifetimeVar, bound: Lifetime },
    /// `src` must flow into `dst`; src must be <= dst (or a promotion is needed).
    flows_to: struct { src: LifetimeVar, dst: LifetimeVar, span: Span },
};

pub const InferenceTable = struct {
    /// One LifetimeVar per AST node (indexed by NodeIndex).
    vars: std.ArrayListUnmanaged(LifetimeVar) = .{},
    /// Solved lifetime per var (null = unsolved, defaults to .frame).
    solved: std.ArrayListUnmanaged(?Lifetime) = .{},
    constraints: std.ArrayListUnmanaged(Constraint) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) InferenceTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InferenceTable) void {
        self.vars.deinit(self.allocator);
        self.solved.deinit(self.allocator);
        self.constraints.deinit(self.allocator);
    }

    /// Ensure the table has an entry for the given node index.
    pub fn ensureNode(self: *InferenceTable, node_idx: NodeIndex) !LifetimeVar {
        const idx = @as(usize, node_idx);
        while (self.vars.items.len <= idx) {
            const lv: LifetimeVar = @intCast(self.vars.items.len);
            try self.vars.append(self.allocator, lv);
            try self.solved.append(self.allocator, null);
        }
        return self.vars.items[idx];
    }

    pub fn constrain(self: *InferenceTable, c: Constraint) !void {
        try self.constraints.append(self.allocator, c);
    }

    /// Solve all constraints.  Each var takes the maximum of all `at_least`
    /// bounds; `flows_to` is checked after solving.
    pub fn solve(self: *InferenceTable) !void {
        // Pass 1: propagate `at_least` constraints.
        for (self.constraints.items) |c| {
            switch (c) {
                .at_least => |al| {
                    const current = self.solved.items[al.lv] orelse Lifetime.frame;
                    if (@intFromEnum(al.bound) > @intFromEnum(current)) {
                        self.solved.items[al.lv] = al.bound;
                    }
                },
                else => {},
            }
        }

        // Pass 2: propagate through `flows_to` edges (iterate to fixpoint).
        var changed = true;
        while (changed) {
            changed = false;
            for (self.constraints.items) |c| {
                switch (c) {
                    .flows_to => |ft| {
                        const src_lt = self.solved.items[ft.src] orelse Lifetime.frame;
                        const dst_lt = self.solved.items[ft.dst] orelse Lifetime.frame;
                        // If src flows to dst and dst is longer, dst's bound
                        // propagates back to src (caller must match callee).
                        if (@intFromEnum(dst_lt) > @intFromEnum(src_lt)) {
                            self.solved.items[ft.src] = dst_lt;
                            changed = true;
                        }
                    },
                    else => {},
                }
            }
        }

        // Default unsolved vars to .frame.
        for (self.solved.items) |*s| {
            if (s.* == null) s.* = .frame;
        }
    }

    pub fn lifetimeOf(self: *const InferenceTable, node_idx: NodeIndex) Lifetime {
        if (node_idx >= self.solved.items.len) return .frame;
        return self.solved.items[node_idx] orelse .frame;
    }

    /// Check `flows_to` edges for violations after solve().
    /// Emits diagnostics for downward moves (forbidden) and returns the
    /// set of edges that need automatic promotions.
    pub fn checkAndEmitViolations(
        self: *const InferenceTable,
        diags: *DiagList,
    ) ![]const Constraint {
        var promotions = std.ArrayListUnmanaged(Constraint){};
        for (self.constraints.items) |c| {
            switch (c) {
                .flows_to => |ft| {
                    const src_lt = self.solved.items[ft.src] orelse Lifetime.frame;
                    const dst_lt = self.solved.items[ft.dst] orelse Lifetime.frame;
                    if (@intFromEnum(src_lt) > @intFromEnum(dst_lt)) {
                        // Downward move — hard error.
                        try diag.lifetimeMismatch(diags, ft.span, src_lt, dst_lt);
                    }
                    // Upward move without explicit promotion — record for insertion.
                    if (@intFromEnum(src_lt) < @intFromEnum(dst_lt)) {
                        try promotions.append(self.allocator, c);
                    }
                },
                else => {},
            }
        }
        return promotions.toOwnedSlice(self.allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "at_least constraint propagates" {
    var table = InferenceTable.init(std.testing.allocator);
    defer table.deinit();

    _ = try table.ensureNode(0);
    try table.constrain(.{ .at_least = .{ .lv = 0, .bound = .script } });
    try table.solve();
    try std.testing.expectEqual(Lifetime.script, table.lifetimeOf(0));
}

test "default unsolved is frame" {
    var table = InferenceTable.init(std.testing.allocator);
    defer table.deinit();

    _ = try table.ensureNode(0);
    try table.solve();
    try std.testing.expectEqual(Lifetime.frame, table.lifetimeOf(0));
}

test "flows_to propagates dst bound back to src" {
    var table = InferenceTable.init(std.testing.allocator);
    defer table.deinit();

    _ = try table.ensureNode(0); // src
    _ = try table.ensureNode(1); // dst
    try table.constrain(.{ .at_least = .{ .lv = 1, .bound = .script } });
    try table.constrain(.{ .flows_to = .{ .src = 0, .dst = 1, .span = .{ .line = 1, .col = 1, .len = 1 } } });
    try table.solve();
    // src must be elevated to match dst
    try std.testing.expectEqual(Lifetime.script, table.lifetimeOf(0));
}

test "downward flow emits error diagnostic" {
    var table = InferenceTable.init(std.testing.allocator);
    defer table.deinit();
    var diags = DiagList.init(std.testing.allocator);
    defer diags.deinit();

    _ = try table.ensureNode(0); // src (script)
    _ = try table.ensureNode(1); // dst (frame)
    // Force src = script, dst = frame
    try table.constrain(.{ .at_least = .{ .lv = 0, .bound = .script } });
    // Simulate assignment dst = src (downward forbidden)
    // We manually set dst solved to frame and src solved to script after solve.
    try table.solve();
    // Manually set dst to frame (it defaulted to frame already).
    // flows_to from src(script) to dst(frame) — should error.
    try table.constrain(.{ .flows_to = .{ .src = 0, .dst = 1, .span = .{ .line = 2, .col = 1, .len = 1 } } });
    const promotions = try table.checkAndEmitViolations(&diags);
    defer std.testing.allocator.free(promotions);
    try std.testing.expect(diags.hasErrors());
}
