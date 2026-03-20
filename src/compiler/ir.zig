/// Three-address IR for Chasm.
///
/// Design goals:
///   - Every value is a `TempId`; every temp knows its lifetime and type.
///   - Control flow is explicit: `label`/`branch`/`jump` instructions.
///   - Lifetime promotions are explicit `promote` instructions.
///   - Maps directly to C; codegen requires no further analysis.
///
/// Lifetime tagging: `Temp.lifetime` carries the solved lifetime from sema so
/// that the C emitter can choose the right arena pointer without re-running
/// any analysis.

const std    = @import("std");
const ast    = @import("ast");
const Lifetime = @import("runtime").Lifetime;

pub const TempId  = u32;
pub const LabelId = u32;

/// Sentinel for instructions that produce no result (branch, jump, store,…).
pub const invalid_temp: TempId = std.math.maxInt(TempId);

// Re-export operator enums so callers only need to import `ir`.
pub const BinaryOp = ast.BinaryOp;
pub const UnaryOp  = ast.UnaryOp;

// ---------------------------------------------------------------------------
// Temp
// ---------------------------------------------------------------------------

/// A single SSA-like value.  Temps are never re-defined; assignments to the
/// same Chasm variable produce a new temp (copy-on-write style).
pub const Temp = struct {
    id:       TempId,
    lifetime: Lifetime,
    /// TypeId from sema (T_INT, T_FLOAT, …).  0 = unknown.
    type_id:  u32,
};

// ---------------------------------------------------------------------------
// Instructions
// ---------------------------------------------------------------------------

pub const Instr = union(enum) {
    // ---- Literals ----------------------------------------------------------
    const_int:    struct { dest: TempId, value: i64 },
    const_float:  struct { dest: TempId, value: f64 },
    const_bool:   struct { dest: TempId, value: bool },
    /// Pointer into static/arena data — never re-allocated.
    const_string: struct { dest: TempId, value: []const u8 },
    /// Atom value as a slice (includes the leading colon).
    const_atom:   struct { dest: TempId, value: []const u8 },

    // ---- Data movement -----------------------------------------------------
    /// Bitwise copy; same or compatible lifetime.
    copy:    struct { dest: TempId, src: TempId },
    /// Arena-copy to a longer-lived arena.  `from < to` always.
    promote: struct { dest: TempId, src: TempId, from: Lifetime, to: Lifetime },

    // ---- Operations --------------------------------------------------------
    call:   struct { dest: TempId, callee: []const u8, args: []const TempId },
    binary: struct { dest: TempId, op: BinaryOp, left: TempId, right: TempId },
    unary:  struct { dest: TempId, op: UnaryOp,  operand: TempId },

    // ---- Memory ------------------------------------------------------------
    field_get: struct { dest: TempId, object: TempId, field: []const u8 },
    field_set: struct { object: TempId, field: []const u8, src: TempId },
    /// Read a module @attr into a fresh temp.
    load_attr:  struct { dest: TempId, name: []const u8, lifetime: Lifetime },
    /// Write a temp back to a module @attr.
    store_attr: struct { name: []const u8, src: TempId, lifetime: Lifetime },

    // ---- Control flow ------------------------------------------------------
    /// Branch-target marker.  Must appear at the start of a logical block.
    label:  LabelId,
    /// Two-way conditional branch.
    branch: struct { cond: TempId, then_lbl: LabelId, else_lbl: LabelId },
    /// Unconditional forward/backward jump.
    jump:   LabelId,
    /// Return a value.
    ret:     TempId,
    /// Return void.
    ret_void,
    /// Return multiple values (multi-return function).
    ret_tuple: struct { fn_name: []const u8, values: []const TempId },
};

// ---------------------------------------------------------------------------
// Function
// ---------------------------------------------------------------------------

pub const IrParam = struct {
    name:     []const u8,
    temp_id:  TempId,
    lifetime: Lifetime,
    type_id:  u32,
};

pub const IrFunction = struct {
    name:      []const u8,
    is_public: bool,
    /// Parameters, in declaration order.  Each param occupies temp `temp_id`.
    params:    []const IrParam,
    /// All temps used by this function, indexed by `TempId`.
    temps:     []const Temp,
    /// Flat instruction list.  Control flow via label/branch/jump.
    instrs:    []const Instr,
};

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

pub const IrAttr = struct {
    name:      []const u8,
    lifetime:  Lifetime,
    type_id:   u32,
    /// The temp in `attr_init_instrs` that holds the initial value.
    init_temp: TempId,
};

pub const IrEnumVariant = struct {
    enum_name: []const u8,
    variant_name: []const u8,
    index: i64,
};

pub const IrExternFn = struct {
    name: []const u8,
    c_name: []const u8,
};

pub const IrStructField = struct {
    name: []const u8,
    type_id: u32,
};

pub const IrStructDef = struct {
    name: []const u8,
    type_id: u32,
    fields: []const IrStructField,
};

/// An imported function forward declaration (for use across module boundaries).
pub const IrImportedFn = struct {
    name: []const u8,
    /// C return type string.
    ret_c_type: []const u8,
    /// C parameter types in order.
    param_c_types: []const []const u8,
};

/// Metadata for functions that return multiple values.
/// The generated C function returns a struct `ChRet_<name>` with fields v0, v1, ...
pub const IrTupleReturn = struct {
    fn_name: []const u8,
    /// TypeIds of the return values, in order.
    type_ids: []const u32,
};

/// The fully-lowered module ready for codegen.
pub const IrModule = struct {
    functions:        []const IrFunction,
    attrs:            []const IrAttr,
    /// Instructions that run once at module load to initialise all @attrs.
    attr_init_instrs: []const Instr,
    attr_init_temps:  []const Temp,
    /// Enum variant definitions for #define emission.
    enum_variants:    []const IrEnumVariant,
    /// Extern function declarations.
    extern_fns:       []const IrExternFn,
    /// Forward declarations of imported module functions.
    imported_fwd_decls: []const IrImportedFn,
    /// Struct type definitions.
    struct_defs: []const IrStructDef,
    /// Multi-return function metadata.
    tuple_returns: []const IrTupleReturn,
};

// ---------------------------------------------------------------------------
// Debug printer
// ---------------------------------------------------------------------------

pub fn printModule(module: IrModule, writer: anytype) !void {
    // Print struct defs
    for (module.struct_defs) |sd| {
        try writer.print("struct {s} {{\n", .{sd.name});
        for (sd.fields) |f| {
            try writer.print("  {s}: {d}\n", .{ f.name, f.type_id });
        }
        try writer.print("}}\n", .{});
    }
    if (module.struct_defs.len > 0) try writer.print("\n", .{});

    // Print enum variants
    for (module.enum_variants) |ev| {
        try writer.print("enum {s}.{s} = {d}\n", .{ ev.enum_name, ev.variant_name, ev.index });
    }
    if (module.enum_variants.len > 0) try writer.print("\n", .{});

    // Print attrs
    for (module.attrs) |a| {
        try writer.print("@{s} :: {s}\n", .{ a.name, @tagName(a.lifetime) });
    }
    if (module.attrs.len > 0) try writer.print("\n", .{});

    // Print attr init block if non-empty
    if (module.attr_init_instrs.len > 0) {
        try writer.print("init:\n", .{});
        for (module.attr_init_instrs) |instr| try printInstr(instr, writer);
        try writer.print("\n", .{});
    }

    for (module.functions) |f| {
        try writer.print("{s} {s}(", .{ if (f.is_public) "def" else "defp", f.name });
        for (f.params, 0..) |p, i| {
            if (i > 0) try writer.print(", ", .{});
            try writer.print("%{d}:{s}", .{ p.temp_id, @tagName(p.lifetime) });
        }
        try writer.print("):\n", .{});
        for (f.instrs) |instr| try printInstr(instr, writer);
        try writer.print("\n", .{});
    }
}

fn printInstr(instr: Instr, writer: anytype) !void {
    switch (instr) {
        .const_int    => |i| try writer.print("  %{d} = {d}\n",           .{ i.dest, i.value }),
        .const_float  => |i| try writer.print("  %{d} = {d}\n",           .{ i.dest, i.value }),
        .const_bool   => |i| try writer.print("  %{d} = {}\n",            .{ i.dest, i.value }),
        .const_string => |i| try writer.print("  %{d} = \"{s}\"\n",       .{ i.dest, i.value }),
        .const_atom   => |i| try writer.print("  %{d} = {s}\n",           .{ i.dest, i.value }),
        .copy         => |i| try writer.print("  %{d} = %{d}\n",          .{ i.dest, i.src }),
        .promote      => |i| try writer.print("  %{d} = promote(%{d}, {s}->{s})\n", .{ i.dest, i.src, @tagName(i.from), @tagName(i.to) }),
        .call         => |i| {
            try writer.print("  %{d} = {s}(", .{ i.dest, i.callee });
            for (i.args, 0..) |a, n| {
                if (n > 0) try writer.print(", ", .{});
                try writer.print("%{d}", .{a});
            }
            try writer.print(")\n", .{});
        },
        .binary       => |i| try writer.print("  %{d} = %{d} {s} %{d}\n", .{ i.dest, i.left, @tagName(i.op), i.right }),
        .unary        => |i| try writer.print("  %{d} = {s}%{d}\n",       .{ i.dest, @tagName(i.op), i.operand }),
        .field_get    => |i| try writer.print("  %{d} = %{d}.{s}\n",      .{ i.dest, i.object, i.field }),
        .field_set    => |i| try writer.print("  %{d}.{s} = %{d}\n",      .{ i.object, i.field, i.src }),
        .load_attr    => |i| try writer.print("  %{d} = @{s}\n",          .{ i.dest, i.name }),
        .store_attr   => |i| try writer.print("  @{s} = %{d}\n",          .{ i.name, i.src }),
        .label        => |id| try writer.print("L{d}:\n",                 .{id}),
        .branch       => |i| try writer.print("  br %{d} -> L{d}, L{d}\n", .{ i.cond, i.then_lbl, i.else_lbl }),
        .jump         => |id| try writer.print("  jmp L{d}\n",            .{id}),
        .ret          => |t|  try writer.print("  ret %{d}\n",            .{t}),
        .ret_void     =>      try writer.print("  ret\n",                 .{}),
        .ret_tuple    => |rt| {
            try writer.print("  ret_tuple_{s}(", .{rt.fn_name});
            for (rt.values, 0..) |t, i| {
                if (i > 0) try writer.print(", ", .{});
                try writer.print("%{d}", .{t});
            }
            try writer.print(")\n", .{});
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Temp fields" {
    const t = Temp{ .id = 0, .lifetime = .frame, .type_id = 1 };
    try testing.expectEqual(@as(TempId, 0), t.id);
    try testing.expectEqual(Lifetime.frame, t.lifetime);
}

test "Instr union tags" {
    const i: Instr = .{ .const_int = .{ .dest = 0, .value = 42 } };
    switch (i) {
        .const_int => |ci| try testing.expectEqual(@as(i64, 42), ci.value),
        else => return error.WrongTag,
    }
}

test "printModule smoke test" {
    const module = IrModule{
        .functions = &.{IrFunction{
            .name      = "f",
            .is_public = true,
            .params    = &.{},
            .temps     = &.{Temp{ .id = 0, .lifetime = .frame, .type_id = 1 }},
            .instrs    = &.{
                Instr{ .const_int = .{ .dest = 0, .value = 7 } },
                Instr{ .ret = 0 },
            },
        }},
        .attrs            = &.{},
        .attr_init_instrs = &.{},
        .attr_init_temps  = &.{},
        .enum_variants    = &.{},
        .extern_fns       = &.{},
        .imported_fwd_decls = &.{},
        .struct_defs      = &.{},
        .tuple_returns    = &.{},
    };
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try printModule(module, fbs.writer());
    const out = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, out, "def f()") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ret %0")  != null);
}
