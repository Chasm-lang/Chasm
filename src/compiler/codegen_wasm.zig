/// WebAssembly Text Format (.wat) emitter for Chasm.
///
/// Emits a well-formed WAT module with:
///   • (import "env" ...) for builtins and extern fns.
///   • Proper (call $fn ...) instructions.
///   • Structured control flow: block/loop/(if (then)(else)) converted from
///     the flat label/branch/jump IR.
const std    = @import("std");
const ir_mod = @import("ir");
const IrModule   = ir_mod.IrModule;
const IrFunction = ir_mod.IrFunction;
const Instr      = ir_mod.Instr;
const Temp       = ir_mod.Temp;
const TempId     = ir_mod.TempId;
const LabelId    = ir_mod.LabelId;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn emitWat(module: IrModule, writer: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try writer.print("(module\n", .{});
    try writer.print("  (memory 1)\n\n", .{});

    // ---- Imports: builtins ------------------------------------------------
    try writer.print("  ;; Built-in imports\n", .{});
    for (builtinImports()) |bi| {
        try writer.print("  (import \"env\" \"{s}\" (func ${s}", .{ bi.env_name, bi.fn_name });
        for (bi.param_types) |pt| try writer.print(" (param {s})", .{pt});
        if (!std.mem.eql(u8, bi.ret_type, "void")) {
            try writer.print(" (result {s})", .{bi.ret_type});
        }
        try writer.print("))\n", .{});
    }

    // ---- Imports: extern fns from the module (skip duplicates of builtins) -
    if (module.extern_fns.len > 0) {
        try writer.print("  ;; Extern function imports\n", .{});
        for (module.extern_fns) |ef| {
            if (builtinByEnvName(ef.c_name) != null) continue;
            try writer.print("  (import \"env\" \"{s}\" (func ${s}))\n", .{ ef.c_name, ef.name });
        }
    }
    try writer.print("\n", .{});

    // ---- Globals (module @attrs) ------------------------------------------
    if (module.attrs.len > 0) {
        try writer.print("  ;; Module attributes\n", .{});
        for (module.attrs) |a| {
            const wt = watType(a.type_id);
            try writer.print("  (global $g_{s} (mut {s}) ({s}.const 0))\n", .{ a.name, wt, wt });
        }
        try writer.print("\n", .{});
    }

    // ---- Functions --------------------------------------------------------
    for (module.functions) |f| {
        try emitFunction(f, alloc, writer);
    }

    try writer.print(")\n", .{});
}

// ---------------------------------------------------------------------------
// Function
// ---------------------------------------------------------------------------

fn emitFunction(f: IrFunction, alloc: std.mem.Allocator, writer: anytype) !void {
    if (f.is_public) {
        try writer.print("  (func ${s} (export \"{s}\")", .{ f.name, f.name });
    } else {
        try writer.print("  (func ${s}", .{f.name});
    }

    for (f.params) |p| {
        try writer.print(" (param $t{d} {s})", .{ p.temp_id, watType(p.type_id) });
    }
    const ret_ty = inferRetType(f);
    if (ret_ty != 6) {
        try writer.print(" (result {s})", .{watType(ret_ty)});
    }
    try writer.print("\n", .{});

    // Locals
    for (f.temps) |t| {
        var is_param = false;
        for (f.params) |p| if (p.temp_id == t.id) { is_param = true; break; };
        if (!is_param) {
            try writer.print("    (local $t{d} {s})\n", .{ t.id, watType(t.type_id) });
        }
    }

    // Build control-flow maps.
    const label_pos    = try buildLabelMap(f.instrs, alloc);
    defer alloc.free(label_pos);
    var loop_headers   = try findLoopHeaders(f.instrs, label_pos, alloc);
    defer loop_headers.deinit(alloc);

    try emitRange(f.instrs, f.temps, label_pos, &loop_headers, 0, f.instrs.len, writer, 4);
    try writer.print("  )\n\n", .{});
}

// ---------------------------------------------------------------------------
// Control-flow helpers
// ---------------------------------------------------------------------------

fn buildLabelMap(instrs: []const Instr, alloc: std.mem.Allocator) ![]usize {
    var max_lbl: usize = 0;
    for (instrs) |instr| switch (instr) {
        .label  => |id| if (id > max_lbl) { max_lbl = id; },
        .branch => |b| {
            if (b.then_lbl > max_lbl) max_lbl = b.then_lbl;
            if (b.else_lbl > max_lbl) max_lbl = b.else_lbl;
        },
        .jump   => |id| if (id > max_lbl) { max_lbl = id; },
        else    => {},
    };
    const map = try alloc.alloc(usize, max_lbl + 1);
    @memset(map, std.math.maxInt(usize));
    for (instrs, 0..) |instr, i| switch (instr) {
        .label => |id| map[id] = i,
        else   => {},
    };
    return map;
}

fn findLoopHeaders(instrs: []const Instr, label_pos: []const usize, alloc: std.mem.Allocator) !std.AutoHashMapUnmanaged(LabelId, void) {
    var set = std.AutoHashMapUnmanaged(LabelId, void){};
    for (instrs, 0..) |instr, i| switch (instr) {
        .jump => |id| {
            if (id < label_pos.len and label_pos[id] != std.math.maxInt(usize) and label_pos[id] <= i) {
                try set.put(alloc, id, {});
            }
        },
        else => {},
    };
    return set;
}

fn findBackJump(instrs: []const Instr, start: usize, target: LabelId) ?usize {
    var j = start;
    while (j < instrs.len) : (j += 1) switch (instrs[j]) {
        .jump => |lbl| if (lbl == target) return j,
        else  => {},
    };
    return null;
}

// ---------------------------------------------------------------------------
// Structured emitter
// ---------------------------------------------------------------------------

fn emitRange(
    instrs:       []const Instr,
    temps:        []const Temp,
    label_pos:    []const usize,
    loop_headers: *const std.AutoHashMapUnmanaged(LabelId, void),
    start:        usize,
    end:          usize,
    writer:       anytype,
    ind:          usize,
) anyerror!void {
    var i = start;
    while (i < end) {
        i = try emitOne(instrs, temps, label_pos, loop_headers, i, end, writer, ind);
    }
}

fn emitOne(
    instrs:       []const Instr,
    temps:        []const Temp,
    label_pos:    []const usize,
    loop_headers: *const std.AutoHashMapUnmanaged(LabelId, void),
    i:            usize,
    end:          usize,
    writer:       anytype,
    ind:          usize,
) anyerror!usize {
    if (i >= end) return end;
    switch (instrs[i]) {

        // ---- Loop-header label ------------------------------------------
        .label => |lbl| {
            if (!loop_headers.contains(lbl)) return i + 1; // non-loop label: skip

            // Find the exit label: first branch after this label gives else_lbl.
            const exit_lbl: LabelId = blk: {
                var j = i + 1;
                while (j < end) : (j += 1) switch (instrs[j]) {
                    .branch => |b| break :blk b.else_lbl,
                    .label  => break,
                    else    => {},
                };
                return i + 1; // malformed — skip
            };
            const back_pos = findBackJump(instrs, i + 1, lbl) orelse return i + 1;
            const exit_pos = if (exit_lbl < label_pos.len and label_pos[exit_lbl] != std.math.maxInt(usize))
                label_pos[exit_lbl] else end;

            try wi(writer, ind);
            try writer.print("(block $BL{d}\n", .{exit_lbl});
            try wi(writer, ind + 2);
            try writer.print("(loop $L{d}\n", .{lbl});
            try emitRange(instrs, temps, label_pos, loop_headers, i + 1, back_pos, writer, ind + 4);
            try wi(writer, ind + 4);
            try writer.print("(br $L{d})\n", .{lbl});
            try wi(writer, ind + 2);
            try writer.print(")\n", .{});
            try wi(writer, ind);
            try writer.print(")\n", .{});
            return if (exit_pos < std.math.maxInt(usize)) exit_pos + 1 else end;
        },

        // ---- Branch: if/else --------------------------------------------
        .branch => |b| {
            const then_pos = if (b.then_lbl < label_pos.len) label_pos[b.then_lbl] else std.math.maxInt(usize);
            const else_pos = if (b.else_lbl < label_pos.len) label_pos[b.else_lbl] else std.math.maxInt(usize);
            if (then_pos == std.math.maxInt(usize) or else_pos == std.math.maxInt(usize)) return i + 1;

            // Detect while-condition branch: if the condition variable's label
            // is a loop header, this branch is the exit check.  Emit as br_if.
            // (The loop-header handler wraps the whole loop; we just need the
            // exit-condition br_if here.)
            if (else_pos <= i) {
                // Inverted — not an expected pattern; skip.
                return i + 1;
            }

            // Is there a jump at the end of the then block?
            const end_lbl: ?LabelId = blk: {
                if (else_pos > 0) switch (instrs[else_pos - 1]) {
                    .jump => |jl| break :blk jl,
                    else  => {},
                };
                break :blk null;
            };

            // Check if this branch is inside a loop body (else_lbl is the loop exit).
            // In that case we emit: (br_if $BL<exit> (i32.eqz $cond)) for the
            // while-condition check.
            if (loop_headers.contains(b.then_lbl) or
                (end_lbl != null and label_pos.len > end_lbl.? and
                 label_pos[end_lbl.?] != std.math.maxInt(usize) and
                 label_pos[end_lbl.?] < else_pos))
            {
                // Likely a while-condition: emit br_if to exit block.
                try wi(writer, ind);
                try writer.print("(br_if $BL{d} (i32.eqz (local.get $t{d})))\n", .{ b.else_lbl, b.cond });
                return i + 1;
            }

            try wi(writer, ind);
            try writer.print("(if (local.get $t{d})\n", .{b.cond});
            try wi(writer, ind + 2);
            try writer.print("(then\n", .{});

            if (end_lbl) |el| {
                const end_pos_val = if (el < label_pos.len and label_pos[el] != std.math.maxInt(usize))
                    label_pos[el] else end;
                const then_body_end = if (else_pos > 0) else_pos - 1 else else_pos;
                try emitRange(instrs, temps, label_pos, loop_headers, then_pos + 1, then_body_end, writer, ind + 4);
                try wi(writer, ind + 2);
                try writer.print(")\n", .{});

                const else_body_end = @min(end_pos_val, end);
                if (else_pos + 1 < else_body_end) {
                    try wi(writer, ind + 2);
                    try writer.print("(else\n", .{});
                    try emitRange(instrs, temps, label_pos, loop_headers, else_pos + 1, else_body_end, writer, ind + 4);
                    try wi(writer, ind + 2);
                    try writer.print(")\n", .{});
                }
                try wi(writer, ind);
                try writer.print(")\n", .{});
                return else_body_end + 1;
            } else {
                // if without else (else_lbl is the merge point)
                try emitRange(instrs, temps, label_pos, loop_headers, then_pos + 1, else_pos, writer, ind + 4);
                try wi(writer, ind + 2);
                try writer.print(")\n", .{});
                try wi(writer, ind);
                try writer.print(")\n", .{});
                return else_pos + 1;
            }
        },

        // ---- Jump (forward: skip; backward: handled by loop emitter) ----
        .jump => return i + 1,

        // ---- Plain instructions -----------------------------------------
        else => |instr| {
            try emitInstr(instr, temps, writer, ind);
            return i + 1;
        },
    }
}

fn emitInstr(instr: Instr, temps: []const Temp, writer: anytype, ind: usize) !void {
    switch (instr) {
        .const_int    => |ci| {
            try wi(writer, ind);
            try writer.print("(local.set $t{d} (i64.const {d}))\n", .{ ci.dest, ci.value });
        },
        .const_float  => |ci| {
            try wi(writer, ind);
            try writer.print("(local.set $t{d} (f64.const {d}))\n", .{ ci.dest, ci.value });
        },
        .const_bool   => |ci| {
            try wi(writer, ind);
            try writer.print("(local.set $t{d} (i32.const {d}))\n",
                .{ ci.dest, if (ci.value) @as(i32, 1) else @as(i32, 0) });
        },
        .const_string => |ci| {
            try wi(writer, ind);
            try writer.print(";; str \"{s}\" → i32.const 0 (TODO: linear memory)\n", .{ci.value});
            try wi(writer, ind);
            try writer.print("(local.set $t{d} (i32.const 0))\n", .{ci.dest});
        },
        .const_atom   => |ci| {
            try wi(writer, ind);
            try writer.print(";; atom {s}\n", .{ci.value});
            try wi(writer, ind);
            try writer.print("(local.set $t{d} (i32.const 0))\n", .{ci.dest});
        },
        .copy, .promote => {
            const dest = switch (instr) { .copy => |c| c.dest, .promote => |p| p.dest, else => unreachable };
            const src  = switch (instr) { .copy => |c| c.src,  .promote => |p| p.src,  else => unreachable };
            try wi(writer, ind);
            try writer.print("(local.set $t{d} (local.get $t{d}))\n", .{ dest, src });
        },
        .load_attr    => |li| {
            try wi(writer, ind);
            try writer.print("(local.set $t{d} (global.get $g_{s}))\n", .{ li.dest, li.name });
        },
        .store_attr   => |si| {
            try wi(writer, ind);
            try writer.print("(global.set $g_{s} (local.get $t{d}))\n", .{ si.name, si.src });
        },
        .binary       => |bi| {
            const ty = tempTypeOf(bi.left, temps);
            try wi(writer, ind);
            try writer.print("(local.set $t{d} ({s} (local.get $t{d}) (local.get $t{d})))\n",
                .{ bi.dest, watBinaryOp(bi.op, ty), bi.left, bi.right });
        },
        .unary        => |ui| {
            try wi(writer, ind);
            switch (ui.op) {
                .neg => try writer.print("(local.set $t{d} (i64.sub (i64.const 0) (local.get $t{d})))\n", .{ ui.dest, ui.operand }),
                .not => try writer.print("(local.set $t{d} (i32.eqz (local.get $t{d})))\n", .{ ui.dest, ui.operand }),
            }
        },
        .call         => |ci| {
            try wi(writer, ind);
            if (ci.dest != std.math.maxInt(TempId)) {
                try writer.print("(local.set $t{d} (call ${s}", .{ ci.dest, ci.callee });
            } else {
                try writer.print("(call ${s}", .{ci.callee});
            }
            for (ci.args) |a| try writer.print(" (local.get $t{d})", .{a});
            if (ci.dest != std.math.maxInt(TempId)) {
                try writer.print("))\n", .{}); // close (call ...) and (local.set ...)
            } else {
                try writer.print(")\n", .{});  // close (call ...) only
            }
        },
        .ret          => |t| {
            try wi(writer, ind);
            try writer.print("(return (local.get $t{d}))\n", .{t});
        },
        .ret_void     => {
            try wi(writer, ind);
            try writer.print("(return)\n", .{});
        },
        .ret_tuple    => |rt| {
            try wi(writer, ind);
            if (rt.values.len > 0) {
                try writer.print("(return (local.get $t{d}))\n", .{rt.values[0]});
            } else {
                try writer.print("(return)\n", .{});
            }
        },
        .field_get    => |fgi| {
            try wi(writer, ind);
            try writer.print(";; field_get t{d}.{s} (structs not in WASM)\n", .{ fgi.object, fgi.field });
            try wi(writer, ind);
            try writer.print("(local.set $t{d} (i64.const 0))\n", .{fgi.dest});
        },
        .field_set    => |fsi| {
            try wi(writer, ind);
            try writer.print(";; field_set t{d}.{s} = t{d}\n", .{ fsi.object, fsi.field, fsi.src });
        },
        .label, .branch, .jump => {}, // should not reach here
    }
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn wi(writer: anytype, n: usize) !void {
    var j: usize = 0;
    while (j < n) : (j += 1) try writer.writeByte(' ');
}

fn tempTypeOf(id: TempId, temps: []const Temp) u32 {
    for (temps) |t| if (t.id == id) return t.type_id;
    return 1;
}

fn watType(type_id: u32) []const u8 {
    return switch (type_id) {
        0, 1 => "i64",
        2    => "f64",
        3    => "i32",
        4, 5 => "i32",
        else => "i64",
    };
}

fn watBinaryOp(op: ir_mod.BinaryOp, type_id: u32) []const u8 {
    const f = (type_id == 2);
    return switch (op) {
        .add    => if (f) "f64.add" else "i64.add",
        .sub    => if (f) "f64.sub" else "i64.sub",
        .mul    => if (f) "f64.mul" else "i64.mul",
        .div    => if (f) "f64.div" else "i64.div_s",
        .mod    => "i64.rem_s",
        .lt     => if (f) "f64.lt"  else "i64.lt_s",
        .gt     => if (f) "f64.gt"  else "i64.gt_s",
        .lte    => if (f) "f64.le"  else "i64.le_s",
        .gte    => if (f) "f64.ge"  else "i64.ge_s",
        .eq     => if (f) "f64.eq"  else "i64.eq",
        .neq    => if (f) "f64.ne"  else "i64.ne",
        .@"and" => "i32.and",
        .@"or"  => "i32.or",
    };
}

fn inferRetType(f: IrFunction) u32 {
    for (f.instrs) |instr| switch (instr) {
        .ret => |t| return if (t < f.temps.len) f.temps[t].type_id else 1,
        else => {},
    };
    return 6; // void
}

// ---------------------------------------------------------------------------
// Built-in import table
// ---------------------------------------------------------------------------

const BuiltinImport = struct {
    env_name:    []const u8,
    fn_name:     []const u8,
    param_types: []const []const u8,
    ret_type:    []const u8,
};

fn builtinImports() []const BuiltinImport {
    return &.{
        .{ .env_name = "print",   .fn_name = "print",   .param_types = &.{"i64"},                  .ret_type = "void" },
        .{ .env_name = "abs",     .fn_name = "abs",     .param_types = &.{"f64"},                  .ret_type = "f64"  },
        .{ .env_name = "sqrt",    .fn_name = "sqrt",    .param_types = &.{"f64"},                  .ret_type = "f64"  },
        .{ .env_name = "sin",     .fn_name = "sin",     .param_types = &.{"f64"},                  .ret_type = "f64"  },
        .{ .env_name = "cos",     .fn_name = "cos",     .param_types = &.{"f64"},                  .ret_type = "f64"  },
        .{ .env_name = "floor",   .fn_name = "floor",   .param_types = &.{"f64"},                  .ret_type = "f64"  },
        .{ .env_name = "ceil",    .fn_name = "ceil",    .param_types = &.{"f64"},                  .ret_type = "f64"  },
        .{ .env_name = "round",   .fn_name = "round",   .param_types = &.{"f64"},                  .ret_type = "f64"  },
        .{ .env_name = "min",     .fn_name = "min",     .param_types = &.{ "f64", "f64" },         .ret_type = "f64"  },
        .{ .env_name = "max",     .fn_name = "max",     .param_types = &.{ "f64", "f64" },         .ret_type = "f64"  },
        .{ .env_name = "clamp",   .fn_name = "clamp",   .param_types = &.{ "f64", "f64", "f64" },  .ret_type = "f64"  },
        .{ .env_name = "lerp",    .fn_name = "lerp",    .param_types = &.{ "f64", "f64", "f64" },  .ret_type = "f64"  },
        .{ .env_name = "atan2",   .fn_name = "atan2",   .param_types = &.{ "f64", "f64" },         .ret_type = "f64"  },
    };
}

fn builtinByEnvName(name: []const u8) ?BuiltinImport {
    for (builtinImports()) |b| if (std.mem.eql(u8, b.env_name, name)) return b;
    return null;
}
