/// Semantic analysis pass.
///
/// Responsibilities (in order):
///   1. Collect module-level declarations into the module scope (pass 1).
///   2. Analyse each declaration's body: name resolution + type inference (pass 2).
///   3. Emit lifetime constraints into the InferenceTable as expressions are visited.
///   4. Solve the constraint graph and report violations.
///
/// Lifetime constraint rules:
///   - Explicit `:: lifetime` annotation  → at_least constraint on the binding node.
///   - `copy_to_script(x)`               → result at_least .script.
///   - `persist_copy(x)`                 → result at_least .persistent.
///   - `@attr` reference                 → use inherits attr's declared lifetime.
///   - `target = value` assignment       → flows_to(value → target).
///   - `var_decl` init                   → flows_to(init → decl).
///   - ident use                         → flows_to(decl_site → use_site) or
///                                         at_least(param_lifetime) for params.

const std = @import("std");
const Lifetime = @import("runtime").Lifetime;
const ast_mod = @import("ast");
const NodeIndex = ast_mod.NodeIndex;
const AstPool = ast_mod.AstPool;
const LifetimeAnnotation = ast_mod.LifetimeAnnotation;
const diag_mod = @import("diag");
const DiagList = diag_mod.DiagList;
const Span = diag_mod.Span;
const lt_mod = @import("lifetime");
const InferenceTable = lt_mod.InferenceTable;
const LifetimeVar = lt_mod.LifetimeVar;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const TypeId = u32;
// Built-in type constants (indices 0-6 are always pre-allocated).
pub const T_UNKNOWN: TypeId = 0;
pub const T_INT: TypeId     = 1;
pub const T_FLOAT: TypeId   = 2;
pub const T_BOOL: TypeId    = 3;
pub const T_STRING: TypeId  = 4;
pub const T_ATOM: TypeId    = 5;
pub const T_VOID: TypeId    = 6;
pub const T_ARRAY: TypeId   = 7;
pub const T_ENUM_BASE: TypeId = 8; // All enum instances share a base int type
pub const T_STRBUILDER: TypeId = 9; // StringBuilder type

pub fn typeName(ty: TypeId) []const u8 {
    return switch (ty) {
        T_UNKNOWN   => "unknown",
        T_INT       => "int",
        T_FLOAT     => "float",
        T_BOOL      => "bool",
        T_STRING    => "string",
        T_ATOM      => "atom",
        T_VOID      => "void",
        T_ARRAY      => "array",
        T_ENUM_BASE  => "enum",
        T_STRBUILDER => "strbuild",
        else         => "user-defined",
    };
}

/// Map Chasm type name strings to TypeIds.
pub fn typeIdFromName(name: []const u8) TypeId {
    if (std.mem.eql(u8, name, "int"))      return T_INT;
    if (std.mem.eql(u8, name, "float"))    return T_FLOAT;
    if (std.mem.eql(u8, name, "bool"))     return T_BOOL;
    if (std.mem.eql(u8, name, "str"))      return T_STRING;
    if (std.mem.eql(u8, name, "string"))   return T_STRING;
    if (std.mem.eql(u8, name, "void"))     return T_VOID;
    if (std.mem.eql(u8, name, "atom"))     return T_ATOM;
    if (std.mem.eql(u8, name, "strbuild")) return T_STRBUILDER;
    return T_UNKNOWN;
}

// ---------------------------------------------------------------------------
// ImportedFnSig
// ---------------------------------------------------------------------------

pub const ImportedFnSig = struct {
    name: []const u8,
    ret_type_id: TypeId,
    param_type_ids: []TypeId,
};

// ---------------------------------------------------------------------------
// Symbol
// ---------------------------------------------------------------------------

pub const Symbol = struct {
    name: []const u8,
    type_id: TypeId,
    lifetime: Lifetime,
    /// Declaration-site NodeIndex, doubles as LifetimeVar (same index space).
    /// `invalid_node` for synthetic entries (e.g., function parameters that
    /// have no separate AST node).
    node_idx: NodeIndex,
};

// ---------------------------------------------------------------------------
// Scope
// ---------------------------------------------------------------------------

pub const Scope = struct {
    symbols: std.StringHashMapUnmanaged(Symbol) = .{},
    parent: ?*Scope = null,

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.symbols.deinit(allocator);
    }

    pub fn define(self: *Scope, allocator: std.mem.Allocator, sym: Symbol) !void {
        try self.symbols.put(allocator, sym.name, sym);
    }

    pub fn lookup(self: *const Scope, name: []const u8) ?Symbol {
        if (self.symbols.get(name)) |s| return s;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }
};

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

pub const SemaStats = struct {
    symbols_resolved: u32 = 0,
    undefined_names: u32 = 0,
    frame_vars: u32 = 0,
    script_vars: u32 = 0,
    persistent_vars: u32 = 0,
};

// ---------------------------------------------------------------------------
// Sema
// ---------------------------------------------------------------------------

pub const Sema = struct {
    pool: *const AstPool,
    diags: *DiagList,
    lt_table: InferenceTable,
    /// Type of every expression node, indexed by NodeIndex.
    node_types: std.ArrayListUnmanaged(TypeId),
    /// Module-level scope: functions, structs, @attrs.
    module_scope: Scope,
    /// Per-block scope stack (innermost scope is at the top).
    scope_stack: std.ArrayListUnmanaged(*Scope),
    stats: SemaStats,
    allocator: std.mem.Allocator,
    /// Enum declarations: name → list of variants
    enums: std.StringHashMapUnmanaged([]ast_mod.EnumVariant),
    /// Enum variant payload: "EnumName.VariantName" → []TypeId (one per payload field)
    enum_variant_payloads: std.StringHashMapUnmanaged([]TypeId),
    /// Struct type id map: struct name → TypeId
    struct_type_ids: std.StringHashMapUnmanaged(TypeId),
    /// Next struct type id to assign
    next_struct_type_id: TypeId,
    /// Flat field-type map: "StructName.fieldName" → TypeId
    struct_field_types: std.StringHashMapUnmanaged(TypeId),
    /// Extern function table: name → c_name
    extern_fns: std.StringHashMapUnmanaged([]const u8),
    /// Visited import paths (for circular import detection).
    visited: std.StringHashMapUnmanaged(void),
    /// Path of the file being analysed (for resolving imports).
    importing_file: []const u8,
    /// List of successfully resolved import paths (for codegen to include).
    imported_files: std.ArrayListUnmanaged([]const u8),
    /// Imported function signatures for forward declaration emission.
    imported_fn_sigs: std.ArrayListUnmanaged(ImportedFnSig),
    /// Typed array element types: variable name → element TypeId (for []TypeName annotations).
    array_elem_types: std.StringHashMapUnmanaged(TypeId),

    pub fn init(pool: *const AstPool, diags: *DiagList, allocator: std.mem.Allocator) Sema {
        return initWithFile(pool, diags, allocator, "");
    }

    pub fn initWithFile(pool: *const AstPool, diags: *DiagList, allocator: std.mem.Allocator, file_path: []const u8) Sema {
        return .{
            .pool = pool,
            .diags = diags,
            .lt_table = InferenceTable.init(allocator),
            .node_types = .{},
            .module_scope = .{},
            .scope_stack = .{},
            .stats = .{},
            .allocator = allocator,
            .enums = .{},
            .enum_variant_payloads = .{},
            .struct_type_ids = .{},
            .next_struct_type_id = 10, // after T_STRBUILDER = 9
            .struct_field_types = .{},
            .extern_fns = .{},
            .visited = .{},
            .importing_file = file_path,
            .imported_files = .{},
            .imported_fn_sigs = .{},
            .array_elem_types = .{},
        };
    }

    pub fn deinit(self: *Sema) void {
        self.lt_table.deinit();
        self.node_types.deinit(self.allocator);
        self.module_scope.deinit(self.allocator);
        for (self.scope_stack.items) |s| {
            s.deinit(self.allocator);
            self.allocator.destroy(s);
        }
        self.scope_stack.deinit(self.allocator);
        self.enums.deinit(self.allocator);
        self.enum_variant_payloads.deinit(self.allocator);
        self.struct_type_ids.deinit(self.allocator);
        self.struct_field_types.deinit(self.allocator);
        self.extern_fns.deinit(self.allocator);
        self.visited.deinit(self.allocator);
        self.imported_files.deinit(self.allocator);
        for (self.imported_fn_sigs.items) |sig| {
            self.allocator.free(sig.name);
            self.allocator.free(sig.param_type_ids);
        }
        self.imported_fn_sigs.deinit(self.allocator);
        self.array_elem_types.deinit(self.allocator);
    }

    // ---- Scope management --------------------------------------------------

    fn currentScope(self: *Sema) *Scope {
        const n = self.scope_stack.items.len;
        if (n > 0) return self.scope_stack.items[n - 1];
        return &self.module_scope;
    }

    fn pushScope(self: *Sema) !void {
        const s = try self.allocator.create(Scope);
        s.* = .{ .parent = self.currentScope() };
        try self.scope_stack.append(self.allocator, s);
    }

    fn popScope(self: *Sema) void {
        if (self.scope_stack.pop()) |s| {
            s.deinit(self.allocator);
            self.allocator.destroy(s);
        }
    }

    // ---- Node type table ---------------------------------------------------

    fn setNodeType(self: *Sema, idx: NodeIndex, ty: TypeId) !void {
        const i = @as(usize, idx);
        while (self.node_types.items.len <= i) {
            try self.node_types.append(self.allocator, T_UNKNOWN);
        }
        self.node_types.items[i] = ty;
    }

    pub fn nodeType(self: *const Sema, idx: NodeIndex) TypeId {
        const i = @as(usize, idx);
        if (i >= self.node_types.items.len) return T_UNKNOWN;
        return self.node_types.items[i];
    }

    pub fn lifetimeOf(self: *const Sema, idx: NodeIndex) Lifetime {
        return self.lt_table.lifetimeOf(idx);
    }

    pub fn typeIdForStruct(self: *const Sema, name: []const u8) TypeId {
        return self.struct_type_ids.get(name) orelse T_UNKNOWN;
    }

    pub fn typeIdFromNameDynamic(self: *const Sema, name: []const u8) TypeId {
        const builtin_id = typeIdFromName(name);
        if (builtin_id != T_UNKNOWN) return builtin_id;
        return self.struct_type_ids.get(name) orelse T_UNKNOWN;
    }

    // ---- Constraint helpers ------------------------------------------------

    /// Constrain `node_idx`'s lifetime to be at least `bound`.
    fn atLeast(self: *Sema, node_idx: NodeIndex, bound: Lifetime) !void {
        const lv = try self.lt_table.ensureNode(node_idx);
        try self.lt_table.constrain(.{ .at_least = .{ .lv = lv, .bound = bound } });
    }

    /// Assert that `src_idx`'s lifetime flows into `dst_idx`'s lifetime.
    fn flowsTo(self: *Sema, src_idx: NodeIndex, dst_idx: NodeIndex, span: Span) !void {
        _ = try self.lt_table.ensureNode(src_idx);
        _ = try self.lt_table.ensureNode(dst_idx);
        const src_lv: LifetimeVar = src_idx;
        const dst_lv: LifetimeVar = dst_idx;
        try self.lt_table.constrain(.{ .flows_to = .{ .src = src_lv, .dst = dst_lv, .span = span } });
    }

    // ---- Main entry --------------------------------------------------------

    pub fn analyze(self: *Sema, top_level: []const NodeIndex) !void {
        // Pre-register engine built-ins so scripts can call them without forward
        // declarations.  These are resolved at link time against the host engine.
        try self.registerBuiltins();
        // Pass 1: register all top-level names so functions can reference each other.
        for (top_level) |idx| try self.collectDecl(idx);
        // Pass 2: analyse bodies and emit lifetime constraints.
        for (top_level) |idx| try self.analyzeDecl(idx);
        // Solve the constraint graph.
        try self.lt_table.solve();
        // Check for downward-flow violations.
        const promos = try self.lt_table.checkAndEmitViolations(self.diags);
        defer self.allocator.free(promos);
        // Tally lifetime distribution.
        for (self.lt_table.solved.items) |maybe_lt| {
            switch (maybe_lt orelse .frame) {
                .frame      => self.stats.frame_vars      += 1,
                .script     => self.stats.script_vars     += 1,
                .persistent => self.stats.persistent_vars += 1,
            }
        }
    }

    // ---- Built-in registration ---------------------------------------------

    fn registerBuiltins(self: *Sema) !void {
        const builtins = [_]struct { name: []const u8, type_id: TypeId }{
            // Lifetime promotion (also handled specially in analyzeExprInner)
            .{ .name = "copy_to_script", .type_id = T_UNKNOWN },
            .{ .name = "persist_copy",   .type_id = T_UNKNOWN },

            // ---- math -------------------------------------------------------
            .{ .name = "scale",       .type_id = T_FLOAT },
            .{ .name = "clamp",       .type_id = T_FLOAT },
            .{ .name = "abs",         .type_id = T_FLOAT },
            .{ .name = "sqrt",        .type_id = T_FLOAT },
            .{ .name = "pow",         .type_id = T_FLOAT },
            .{ .name = "floor",       .type_id = T_FLOAT },
            .{ .name = "ceil",        .type_id = T_FLOAT },
            .{ .name = "round",       .type_id = T_FLOAT },
            .{ .name = "lerp",        .type_id = T_FLOAT },
            .{ .name = "sign",        .type_id = T_FLOAT },
            .{ .name = "sin",         .type_id = T_FLOAT },
            .{ .name = "cos",         .type_id = T_FLOAT },
            .{ .name = "tan",         .type_id = T_FLOAT },
            .{ .name = "atan2",       .type_id = T_FLOAT },
            .{ .name = "min",         .type_id = T_FLOAT },
            .{ .name = "max",         .type_id = T_FLOAT },
            .{ .name = "deg_to_rad",  .type_id = T_FLOAT },
            .{ .name = "rad_to_deg",  .type_id = T_FLOAT },

            // ---- random -----------------------------------------------------
            .{ .name = "rand",        .type_id = T_FLOAT }, // 0.0 .. 1.0
            .{ .name = "rand_range",  .type_id = T_FLOAT }, // rand_range(lo, hi)
            .{ .name = "rand_int",    .type_id = T_INT   }, // rand_int(lo, hi)

            // ---- math: shape / interpolation --------------------------------
            .{ .name = "fract",         .type_id = T_FLOAT }, // fractional part
            .{ .name = "wrap",          .type_id = T_FLOAT }, // wrap(v, lo, hi)
            .{ .name = "snap",          .type_id = T_FLOAT }, // snap to step
            .{ .name = "smooth_step",   .type_id = T_FLOAT }, // smooth Hermite
            .{ .name = "smoother_step", .type_id = T_FLOAT }, // Perlin's smoother
            .{ .name = "ping_pong",     .type_id = T_FLOAT }, // 0→len→0 bounce
            .{ .name = "move_toward",   .type_id = T_FLOAT }, // approach target by delta
            .{ .name = "angle_diff",    .type_id = T_FLOAT }, // shortest angle between two angles

            // ---- easing -----------------------------------------------------
            .{ .name = "ease_in",         .type_id = T_FLOAT },
            .{ .name = "ease_out",        .type_id = T_FLOAT },
            .{ .name = "ease_in_out",     .type_id = T_FLOAT },
            .{ .name = "ease_in_cubic",   .type_id = T_FLOAT },
            .{ .name = "ease_out_cubic",  .type_id = T_FLOAT },
            .{ .name = "ease_in_out_cubic", .type_id = T_FLOAT },
            .{ .name = "ease_in_elastic", .type_id = T_FLOAT },
            .{ .name = "ease_out_bounce", .type_id = T_FLOAT },

            // ---- vec2 (flat — pass x,y as separate floats) ------------------
            .{ .name = "vec2_len",    .type_id = T_FLOAT }, // vec2_len(x, y)
            .{ .name = "vec2_dot",    .type_id = T_FLOAT }, // vec2_dot(ax,ay,bx,by)
            .{ .name = "vec2_dist",   .type_id = T_FLOAT }, // vec2_dist(ax,ay,bx,by)
            .{ .name = "vec2_angle",  .type_id = T_FLOAT }, // vec2_angle(x, y) → radians
            .{ .name = "vec2_norm_x", .type_id = T_FLOAT }, // x component of normalised
            .{ .name = "vec2_norm_y", .type_id = T_FLOAT }, // y component of normalised
            .{ .name = "vec2_cross",  .type_id = T_FLOAT }, // 2-d cross product (scalar)

            // ---- bitwise ----------------------------------------------------
            .{ .name = "bit_and", .type_id = T_INT },
            .{ .name = "bit_or",  .type_id = T_INT },
            .{ .name = "bit_xor", .type_id = T_INT },
            .{ .name = "bit_not", .type_id = T_INT },
            .{ .name = "bit_shl", .type_id = T_INT }, // bit_shl(v, n)
            .{ .name = "bit_shr", .type_id = T_INT }, // bit_shr(v, n)

            // ---- string -----------------------------------------------------
            .{ .name = "str_len",        .type_id = T_INT    },
            .{ .name = "str_concat",     .type_id = T_STRING },
            .{ .name = "str_repeat",     .type_id = T_STRING }, // str_repeat(s, n)
            .{ .name = "str_slice",      .type_id = T_STRING }, // str_slice(s, start, end)
            .{ .name = "str_char_at",    .type_id = T_INT    }, // returns char code
            .{ .name = "str_from_char",  .type_id = T_STRING }, // int → 1-char string
            .{ .name = "str_upper",      .type_id = T_STRING },
            .{ .name = "str_lower",      .type_id = T_STRING },
            .{ .name = "str_trim",       .type_id = T_STRING },
            .{ .name = "str_contains",   .type_id = T_BOOL   },
            .{ .name = "str_starts_with",.type_id = T_BOOL   },
            .{ .name = "str_ends_with",  .type_id = T_BOOL   },
            .{ .name = "str_eq",         .type_id = T_BOOL   },
            .{ .name = "int_to_str",     .type_id = T_STRING },
            .{ .name = "float_to_str",   .type_id = T_STRING },
            .{ .name = "bool_to_str",    .type_id = T_STRING },

            // ---- type conversion --------------------------------------------
            .{ .name = "to_int",   .type_id = T_INT   }, // truncate float → int
            .{ .name = "to_float", .type_id = T_FLOAT }, // int → float
            .{ .name = "to_bool",  .type_id = T_BOOL  }, // 0/nonzero → bool

            // ---- color (packed 0xRRGGBBAA int) ------------------------------
            .{ .name = "rgb",         .type_id = T_INT }, // rgb(r,g,b) → int
            .{ .name = "rgba",        .type_id = T_INT }, // rgba(r,g,b,a) → int
            .{ .name = "color_r",     .type_id = T_INT },
            .{ .name = "color_g",     .type_id = T_INT },
            .{ .name = "color_b",     .type_id = T_INT },
            .{ .name = "color_a",     .type_id = T_INT },
            .{ .name = "color_lerp",  .type_id = T_INT }, // color_lerp(a, b, t)
            .{ .name = "color_mix",   .type_id = T_INT }, // alias for color_lerp

            // ---- time -------------------------------------------------------
            .{ .name = "time_now", .type_id = T_FLOAT }, // seconds since epoch
            .{ .name = "time_ms",  .type_id = T_INT   }, // milliseconds since epoch

            // ---- arrays -----------------------------------------------------
            .{ .name = "array_new",   .type_id = T_ARRAY },
            .{ .name = "array_push",  .type_id = T_VOID  },
            .{ .name = "array_pop",   .type_id = T_INT   },
            .{ .name = "array_get",   .type_id = T_INT   },
            .{ .name = "array_set",   .type_id = T_VOID  },
            .{ .name = "array_len",   .type_id = T_INT   },
            .{ .name = "array_clear", .type_id = T_VOID  },

            // ---- i/o --------------------------------------------------------
            .{ .name = "print",      .type_id = T_VOID },
            .{ .name = "log",        .type_id = T_VOID },
            .{ .name = "assert",     .type_id = T_VOID },
            .{ .name = "assert_eq",  .type_id = T_VOID }, // assert_eq(a, b)
            .{ .name = "todo",       .type_id = T_VOID }, // marks unreachable

            // ---- file i/o ---------------------------------------------------
            .{ .name = "file_read",   .type_id = T_STRING },
            .{ .name = "file_write",  .type_id = T_VOID   },
            .{ .name = "file_exists", .type_id = T_BOOL   },

            // ---- string builder ---------------------------------------------
            .{ .name = "str_builder_new",    .type_id = T_STRBUILDER },
            .{ .name = "str_builder_push",   .type_id = T_VOID       },
            .{ .name = "str_builder_append", .type_id = T_VOID       },
            .{ .name = "str_builder_build",  .type_id = T_STRING     },
        };
        for (builtins) |b| {
            try self.module_scope.define(self.allocator, .{
                .name     = b.name,
                .type_id  = b.type_id,
                .lifetime = .frame,
                .node_idx = ast_mod.invalid_node,
            });
        }
    }

    // ---- Pass 1: collect declarations --------------------------------------

    fn collectDecl(self: *Sema, idx: NodeIndex) !void {
        _ = try self.lt_table.ensureNode(idx);
        switch (self.pool.get(idx).*) {
            .fn_decl => |f| {
                // If the return type is a tuple, assign a synthetic struct type_id
                // for the ChRet_<name> C struct, so call results are typed correctly.
                const ret_type_id: TypeId = if (f.ret_ty) |rty| blk: {
                    if (self.pool.get(rty).* == .tuple_type) {
                        const synthetic_name = try std.fmt.allocPrint(self.allocator, "ChRet_{s}", .{f.name});
                        const type_id = self.next_struct_type_id;
                        self.next_struct_type_id += 1;
                        try self.struct_type_ids.put(self.allocator, synthetic_name, type_id);
                        break :blk type_id;
                    }
                    // Resolve named return type if present
                    switch (self.pool.get(rty).*) {
                        .type_ref  => |tr| break :blk self.typeIdFromNameDynamic(tr.name),
                        .ident     => |id| break :blk self.typeIdFromNameDynamic(id.name),
                        .array_type => break :blk T_ARRAY,
                        else => {},
                    }
                    break :blk T_UNKNOWN;
                } else T_VOID; // no return type annotation → void
                try self.module_scope.define(self.allocator, .{
                    .name     = f.name,
                    .type_id  = ret_type_id,
                    .lifetime = .frame,
                    .node_idx = idx,
                });
            },
            .struct_decl => |s| {
                const type_id = self.next_struct_type_id;
                self.next_struct_type_id += 1;
                try self.struct_type_ids.put(self.allocator, s.name, type_id);
                // Register field types as "StructName.fieldName" → TypeId.
                for (s.fields) |field| {
                    const field_type_id: TypeId = if (field.ty) |ty_idx| blk: {
                        switch (self.pool.get(ty_idx).*) {
                            .type_ref => |tr| break :blk self.typeIdFromNameDynamic(tr.name),
                            else => break :blk T_UNKNOWN,
                        }
                    } else T_UNKNOWN;
                    const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ s.name, field.name });
                    try self.struct_field_types.put(self.allocator, key, field_type_id);
                }
                try self.module_scope.define(self.allocator, .{
                    .name     = s.name,
                    .type_id  = type_id,
                    .lifetime = .frame,
                    .node_idx = idx,
                });
            },
            .attr_decl => |a| {
                const lt = resolveLifetime(a.lifetime, .script);
                try self.atLeast(idx, lt);
                try self.module_scope.define(self.allocator, .{
                    .name     = a.name,
                    .type_id  = T_UNKNOWN,
                    .lifetime = lt,
                    .node_idx = idx,
                });
            },
            .enum_decl => |e| {
                try self.enums.put(self.allocator, e.name, e.variants);
                // Register the enum type name in module scope.
                try self.module_scope.define(self.allocator, .{
                    .name     = e.name,
                    .type_id  = T_ENUM_BASE,
                    .lifetime = .frame,
                    .node_idx = idx,
                });
                // Register each variant as a constant with its index.
                for (e.variants, 0..) |variant, vi| {
                    const qname = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ e.name, variant.name });
                    try self.module_scope.define(self.allocator, .{
                        .name     = qname,
                        .type_id  = T_ENUM_BASE,
                        .lifetime = .frame,
                        .node_idx = idx,
                    });
                    _ = vi;
                    // Register payload types if any.
                    if (variant.payload_types.len > 0) {
                        var payload_ids = try self.allocator.alloc(TypeId, variant.payload_types.len);
                        for (variant.payload_types, 0..) |ty_name, ti| {
                            payload_ids[ti] = self.typeIdFromNameDynamic(ty_name);
                        }
                        const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ e.name, variant.name });
                        try self.enum_variant_payloads.put(self.allocator, key, payload_ids);
                    }
                }
            },
            .extern_decl => |ex| {
                const ret_type_id = typeIdFromName(ex.return_type);
                try self.module_scope.define(self.allocator, .{
                    .name     = ex.name,
                    .type_id  = ret_type_id,
                    .lifetime = .frame,
                    .node_idx = idx,
                });
                try self.extern_fns.put(self.allocator, ex.name, ex.c_name);
            },
            .import_decl => {}, // handled in analyzeDecl
            else => {},
        }
    }

    // ---- Pass 2: analyse bodies --------------------------------------------

    fn analyzeDecl(self: *Sema, idx: NodeIndex) anyerror!void {
        switch (self.pool.get(idx).*) {
            .fn_decl   => try self.analyzeFnDecl(idx),
            .attr_decl => |a| {
                const init_ty = try self.analyzeExpr(a.init);
                // Back-fill the type into module_scope now that we know it.
                if (self.module_scope.symbols.getPtr(a.name)) |sym| {
                    if (sym.type_id == T_UNKNOWN) sym.type_id = init_ty;
                }
            },
            .enum_decl => {}, // already collected in pass 1
            .extern_decl => {}, // already collected in pass 1
            .import_decl => |imp| try self.analyzeImport(imp.path, imp.span),
            else       => {},
        }
    }

    fn analyzeImport(self: *Sema, import_path: []const u8, span: Span) !void {
        const LexerT = @import("lexer").Lexer;
        const ParserT = @import("parser").Parser;
        const module_resolver = @import("module_resolver");

        // Resolve the import path relative to the importing file.
        const resolved_path = module_resolver.resolve(self.importing_file, import_path, self.allocator) catch |err| {
            try self.diags.err(span, "cannot resolve import '{s}': {s}", .{ import_path, @errorName(err) });
            return;
        };
        defer self.allocator.free(resolved_path);

        // Circular import check.
        if (self.visited.contains(resolved_path)) return;
        try self.visited.put(self.allocator, resolved_path, {});

        // Record this import for the codegen/run pipeline.
        try self.imported_files.append(self.allocator, try self.allocator.dupe(u8, resolved_path));

        // Read and parse the imported file.
        const src = std.fs.cwd().readFileAlloc(self.allocator, resolved_path, 4 * 1024 * 1024) catch |err| {
            try self.diags.err(span, "cannot read module '{s}': {s}", .{ resolved_path, @errorName(err) });
            return;
        };
        defer self.allocator.free(src);

        var sub_pool = AstPool.init(self.allocator);
        defer sub_pool.deinit();

        var sub_diags = DiagList.initWithSource(self.allocator, src);
        defer sub_diags.deinit();

        var lex = LexerT.init(src);
        const toks = lex.tokenize(self.allocator) catch {
            try self.diags.err(span, "lex error in module '{s}'", .{resolved_path});
            return;
        };
        defer self.allocator.free(toks);

        var parser = ParserT.init(toks, &sub_pool, &sub_diags, self.allocator);
        const top_level = parser.parseFile() catch {
            try self.diags.err(span, "parse error in module '{s}'", .{resolved_path});
            return;
        };

        // Create a sub-sema for the imported module.
        var sub_sema = Sema.initWithFile(&sub_pool, &sub_diags, self.allocator, resolved_path);
        defer sub_sema.deinit();

        // Copy visited set to detect circular imports transitively.
        var vis_iter = self.visited.iterator();
        while (vis_iter.next()) |entry| {
            try sub_sema.visited.put(self.allocator, entry.key_ptr.*, {});
        }

        try sub_sema.registerBuiltins();
        for (top_level) |tidx| try sub_sema.collectDecl(tidx);
        for (top_level) |tidx| try sub_sema.analyzeDecl(tidx);

        // Determine module name prefix (basename without .chasm).
        const mod_name = module_resolver.moduleName(resolved_path);

        // Merge imported module's function/enum/attr table into current scope
        // under the namespace prefix `modname.fn_name`.
        var sym_iter = sub_sema.module_scope.symbols.iterator();
        while (sym_iter.next()) |entry| {
            const sym = entry.value_ptr.*;
            // Skip builtins (they're already registered).
            if (sym.node_idx == ast_mod.invalid_node) continue;
            // Create prefixed name.
            const prefixed = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ mod_name, sym.name });
            try self.module_scope.define(self.allocator, .{
                .name     = prefixed,
                .type_id  = sym.type_id,
                .lifetime = sym.lifetime,
                .node_idx = sym.node_idx,
            });
        }

        // Merge enum declarations.
        var enum_iter = sub_sema.enums.iterator();
        while (enum_iter.next()) |entry| {
            try self.enums.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
        }

        // Merge extern functions.
        var ext_iter = sub_sema.extern_fns.iterator();
        while (ext_iter.next()) |entry| {
            try self.extern_fns.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
        }

        // Collect imported function signatures for forward declarations.
        for (top_level) |tidx| {
            switch (sub_pool.get(tidx).*) {
                .fn_decl => |f| {
                    // Gather param type ids.
                    var param_ids = try self.allocator.alloc(TypeId, f.params.len);
                    for (f.params, 0..) |p, pi| {
                        if (p.ty) |ty_idx| {
                            const ty_node = sub_pool.get(ty_idx);
                            if (ty_node.* == .type_ref) {
                                param_ids[pi] = typeIdFromName(ty_node.type_ref.name);
                            } else {
                                param_ids[pi] = T_UNKNOWN;
                            }
                        } else {
                            param_ids[pi] = T_UNKNOWN;
                        }
                    }
                    // Get return type from fn_decl's ret_ty annotation.
                    const ret_id: TypeId = if (f.ret_ty) |ty_idx| blk: {
                        const ty_node = sub_pool.get(ty_idx);
                        if (ty_node.* == .type_ref) {
                            break :blk typeIdFromName(ty_node.type_ref.name);
                        }
                        break :blk T_VOID;
                    } else T_VOID;
                    try self.imported_fn_sigs.append(self.allocator, .{
                        .name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, f.name }),
                        .ret_type_id = ret_id,
                        .param_type_ids = param_ids,
                    });
                },
                else => {},
            }
        }
    }

    fn analyzeFnDecl(self: *Sema, idx: NodeIndex) !void {
        const f = self.pool.get(idx).fn_decl;
        try self.pushScope();
        defer self.popScope();
        for (f.params) |param| {
            const lt = resolveLifetime(param.lifetime, .frame);
            // Resolve declared parameter type from annotation if present.
            const param_type_id: TypeId = if (param.ty) |ty_idx| blk: {
                switch (self.pool.get(ty_idx).*) {
                    .ident    => |id| break :blk self.typeIdFromNameDynamic(id.name),
                    .type_ref => |tr| break :blk self.typeIdFromNameDynamic(tr.name),
                    .array_type => |at| {
                        // Register elem type for this param so method dispatch works.
                        const elem_ty = self.typeIdFromNameDynamic(at.elem_name);
                        try self.array_elem_types.put(self.allocator, param.name, elem_ty);
                        break :blk T_ARRAY;
                    },
                    else => {},
                }
                break :blk T_UNKNOWN;
            } else T_UNKNOWN;
            try self.currentScope().define(self.allocator, .{
                .name     = param.name,
                .type_id  = param_type_id,
                .lifetime = lt,
                .node_idx = ast_mod.invalid_node,
            });
        }
        try self.analyzeBlock(f.body);
    }

    // ---- Block & statement analysis ----------------------------------------

    fn analyzeBlock(self: *Sema, idx: NodeIndex) anyerror!void {
        const block = self.pool.get(idx).block;
        try self.pushScope();
        defer self.popScope();
        for (block.stmts) |stmt_idx| try self.analyzeStmt(stmt_idx);
    }

    fn analyzeStmt(self: *Sema, idx: NodeIndex) anyerror!void {
        _ = try self.lt_table.ensureNode(idx);
        switch (self.pool.get(idx).*) {
            .var_decl  => try self.analyzeVarDecl(idx),
            .assign    => try self.analyzeAssign(idx),
            .if_stmt   => try self.analyzeIf(idx),
            .while_stmt => try self.analyzeWhile(idx),
            .for_in    => try self.analyzeForIn(idx),
            .return_stmt => |rs| {
                if (rs.value != ast_mod.invalid_node) _ = try self.analyzeExpr(rs.value);
            },
            .multi_assign => |ma| {
                _ = try self.analyzeExpr(ma.value);
                for (ma.targets) |target_name| {
                    if (self.currentScope().lookup(target_name) == null) {
                        try self.currentScope().define(self.allocator, .{
                            .name     = target_name,
                            .type_id  = T_UNKNOWN,
                            .lifetime = .frame,
                            .node_idx = ast_mod.invalid_node,
                        });
                    }
                }
            },
            .expr_stmt => |es| _ = try self.analyzeExpr(es.expr),
            .block     => try self.analyzeBlock(idx),
            else       => {},
        }
    }

    fn analyzeVarDecl(self: *Sema, idx: NodeIndex) !void {
        const vd = self.pool.get(idx).var_decl;
        const init_ty = try self.analyzeExpr(vd.init);
        const lt = resolveLifetime(vd.lifetime, .frame);

        // Constrain the declaration site.
        try self.atLeast(idx, lt);
        // The init expression must flow into the declaration's lifetime.
        try self.flowsTo(vd.init, idx, vd.span);

        // If there's an array_type annotation ([]ElemType), record the element type.
        if (vd.ty) |ty_idx| {
            if (self.pool.get(ty_idx).* == .array_type) {
                const at = self.pool.get(ty_idx).array_type;
                const elem_type_id = self.typeIdFromNameDynamic(at.elem_name);
                try self.array_elem_types.put(self.allocator, vd.name, elem_type_id);
            }
        }

        try self.currentScope().define(self.allocator, .{
            .name     = vd.name,
            .type_id  = init_ty,
            .lifetime = lt,
            .node_idx = idx,
        });
        self.stats.symbols_resolved += 1;
    }

    fn analyzeAssign(self: *Sema, idx: NodeIndex) !void {
        const a = self.pool.get(idx).assign;
        const val_ty = try self.analyzeExpr(a.value);
        switch (self.pool.get(a.target).*) {
            .ident => |id| {
                _ = try self.lt_table.ensureNode(a.target);
                if (self.currentScope().lookup(id.name) == null) {
                    // Implicit binding: infer lifetime from the RHS expression.
                    const inferred_lt = self.inferredLifetime(a.value);
                    try self.atLeast(a.target, inferred_lt);
                    try self.currentScope().define(self.allocator, .{
                        .name     = id.name,
                        .type_id  = val_ty,
                        .lifetime = inferred_lt,
                        .node_idx = a.target,
                    });
                    self.stats.symbols_resolved += 1;
                } else {
                    _ = try self.analyzeExpr(a.target);
                    try self.flowsTo(a.value, a.target, a.span);
                }
            },
            else => {
                _ = try self.analyzeExpr(a.target);
                try self.flowsTo(a.value, a.target, a.span);
            },
        }
    }

    /// Infer the lifetime of an expression purely from its kind, without
    /// consulting the solver.  Used for implicit bindings where no annotation
    /// is present.
    fn inferredLifetime(self: *const Sema, idx: NodeIndex) Lifetime {
        return switch (self.pool.get(idx).*) {
            .copy_to_script => .script,
            .persist_copy   => .persistent,
            else            => .frame,
        };
    }

    fn analyzeIf(self: *Sema, idx: NodeIndex) !void {
        const is = self.pool.get(idx).if_stmt;
        _ = try self.analyzeExpr(is.cond);
        try self.analyzeBlock(is.then_block);
        if (is.else_block != ast_mod.invalid_node) try self.analyzeBlock(is.else_block);
    }

    fn analyzeWhile(self: *Sema, idx: NodeIndex) !void {
        const ws = self.pool.get(idx).while_stmt;
        _ = try self.analyzeExpr(ws.cond);
        try self.analyzeBlock(ws.body);
    }

    fn analyzeForIn(self: *Sema, idx: NodeIndex) !void {
        const fi = self.pool.get(idx).for_in;
        _ = try self.analyzeExpr(fi.iter);
        try self.pushScope();
        defer self.popScope();
        try self.currentScope().define(self.allocator, .{
            .name     = fi.var_name,
            .type_id  = T_INT,
            .lifetime = .frame,
            .node_idx = idx,
        });
        self.stats.symbols_resolved += 1;
        // Analyze body — it's a block node, use analyzeBlock directly
        const body_node = self.pool.get(fi.body);
        _ = body_node;
        try self.analyzeBlock(fi.body);
    }

    // ---- Expression analysis -----------------------------------------------

    /// Top-level expression analyser: ensures a lifetime var exists, records
    /// the resolved type in `node_types`, and returns it.
    pub fn analyzeExpr(self: *Sema, idx: NodeIndex) anyerror!TypeId {
        _ = try self.lt_table.ensureNode(idx);
        const ty = try self.analyzeExprInner(idx);
        try self.setNodeType(idx, ty);
        return ty;
    }

    fn analyzeExprInner(self: *Sema, idx: NodeIndex) anyerror!TypeId {
        switch (self.pool.get(idx).*) {
            // ---- Literals --------------------------------------------------
            .int_lit    => return T_INT,
            .float_lit  => return T_FLOAT,
            .bool_lit   => return T_BOOL,
            .string_lit => return T_STRING,
            .atom_lit   => return T_ATOM,

            // ---- Names -----------------------------------------------------
            .ident    => |id| return self.analyzeIdent(id.name, id.span, idx),
            .attr_ref => |ar| return self.analyzeAttrRef(ar.name, ar.span, idx),

            // ---- Arithmetic & logic ----------------------------------------
            .binary => |b| {
                const lt = try self.analyzeExpr(b.left);
                const rt = try self.analyzeExpr(b.right);
                return switch (b.op) {
                    .eq, .neq, .lt, .lte, .gt, .gte, .@"and", .@"or" => T_BOOL,
                    else => if (lt == T_FLOAT or rt == T_FLOAT) T_FLOAT else lt,
                };
            },
            .unary => |u| return self.analyzeExpr(u.operand),

            // ---- Calls & access --------------------------------------------
            .call => |c| {
                // Check for namespaced call: `module.fn(args)` resolves via module table.
                if (self.pool.get(c.callee).* == .field_access) {
                    const fa = self.pool.get(c.callee).field_access;
                    // Module-qualified call check MUST come before analyzeExpr(fa.object)
                    // so that bare module names (e.g. `utils`) never hit analyzeIdent.
                    if (self.pool.get(fa.object).* == .ident) {
                        const obj_name = self.pool.get(fa.object).ident.name;
                        const qualified = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ obj_name, fa.field });
                        defer self.allocator.free(qualified);
                        if (self.currentScope().lookup(qualified)) |sym| {
                            self.stats.symbols_resolved += 1;
                            try self.atLeast(c.callee, sym.lifetime);
                            try self.setNodeType(c.callee, sym.type_id);
                            // Also propagate to the call node itself so hover works.
                            try self.setNodeType(idx, sym.type_id);
                            try self.atLeast(idx, sym.lifetime);
                            for (c.args) |a| _ = try self.analyzeExpr(a);
                            return sym.type_id;
                        }
                    }
                    // Not a module call; compute obj type for string/array/struct method dispatch.
                    const obj_ty_for_method: TypeId = blk: {
                        const existing = self.nodeType(fa.object);
                        if (existing != T_UNKNOWN) break :blk existing;
                        _ = try self.lt_table.ensureNode(fa.object);
                        break :blk try self.analyzeExpr(fa.object);
                    };
                    if (self.pool.get(fa.object).* == .ident) {
                        // String method sugar: s.slice(from, to), s.contains(sub), etc.
                        if (obj_ty_for_method == T_STRING) {
                            for (c.args) |a| _ = try self.analyzeExpr(a);
                            if (std.mem.eql(u8, fa.field, "slice"))        return T_STRING;
                            if (std.mem.eql(u8, fa.field, "concat"))       return T_STRING;
                            if (std.mem.eql(u8, fa.field, "contains"))     return T_BOOL;
                            if (std.mem.eql(u8, fa.field, "starts_with"))  return T_BOOL;
                            if (std.mem.eql(u8, fa.field, "ends_with"))    return T_BOOL;
                            if (std.mem.eql(u8, fa.field, "upper"))        return T_STRING;
                            if (std.mem.eql(u8, fa.field, "lower"))        return T_STRING;
                            if (std.mem.eql(u8, fa.field, "trim"))         return T_STRING;
                            if (std.mem.eql(u8, fa.field, "repeat"))       return T_STRING;
                            if (std.mem.eql(u8, fa.field, "eq"))           return T_BOOL;
                        }
                        // Array method sugar: arr.push(v), arr.get(i), arr.pop(), arr.clear()
                        if (obj_ty_for_method == T_ARRAY) {
                            for (c.args) |a| _ = try self.analyzeExpr(a);
                            if (std.mem.eql(u8, fa.field, "push"))  return T_VOID;
                            if (std.mem.eql(u8, fa.field, "set"))   return T_VOID;
                            if (std.mem.eql(u8, fa.field, "pop"))   return T_INT;
                            if (std.mem.eql(u8, fa.field, "clear")) return T_VOID;
                            if (std.mem.eql(u8, fa.field, "get")) {
                                // Return element type if known (struct array)
                                const var_name: ?[]const u8 = switch (self.pool.get(fa.object).*) {
                                    .ident    => |id| id.name,
                                    .attr_ref => |ar| ar.name,
                                    else => null,
                                };
                                if (var_name) |vn| {
                                    if (self.array_elem_types.get(vn)) |elem_ty| {
                                        return elem_ty;
                                    }
                                }
                                return T_UNKNOWN;
                            }
                        }
                    }
                }
                const callee_ty = try self.analyzeExpr(c.callee);
                for (c.args) |a| _ = try self.analyzeExpr(a);
                // If callee resolved to a known type (e.g. a builtin with T_VOID),
                // propagate it so the lowerer can emit void calls correctly.
                return if (callee_ty != T_UNKNOWN) callee_ty else T_UNKNOWN;
            },
            .field_access => |fa| {
                const obj_ty = try self.analyzeExpr(fa.object);
                // String method sugar: s.len
                if (obj_ty == T_STRING and std.mem.eql(u8, fa.field, "len")) return T_INT;
                // Array method sugar: arr.len
                if (obj_ty == T_ARRAY and std.mem.eql(u8, fa.field, "len")) return T_INT;
                // If the object has a known struct type, look up the field's type.
                if (obj_ty >= 10) {
                    // Find struct name from type_id.
                    var it = self.struct_type_ids.iterator();
                    while (it.next()) |entry| {
                        if (entry.value_ptr.* == obj_ty) {
                            const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ entry.key_ptr.*, fa.field });
                            defer self.allocator.free(key);
                            if (self.struct_field_types.get(key)) |fty| return fty;
                            break;
                        }
                    }
                }
                return T_UNKNOWN;
            },
            .index => |ix| {
                _ = try self.analyzeExpr(ix.array);
                _ = try self.analyzeExpr(ix.idx);
                // String indexing: s[i] → int (byte value)
                const arr_ty = self.nodeType(ix.array);
                if (arr_ty == T_STRING) return T_INT;
                // If the array base is an ident with a known element type, return it.
                if (self.pool.get(ix.array).* == .ident) {
                    const arr_name = self.pool.get(ix.array).ident.name;
                    if (self.array_elem_types.get(arr_name)) |elem_ty| return elem_ty;
                } else if (self.pool.get(ix.array).* == .attr_ref) {
                    const arr_name = self.pool.get(ix.array).attr_ref.name;
                    if (self.array_elem_types.get(arr_name)) |elem_ty| return elem_ty;
                }
                return T_UNKNOWN;
            },

            // ---- Lifetime promotions ---------------------------------------
            .copy_to_script => |cts| {
                const inner_ty = try self.analyzeExpr(cts.expr);
                try self.atLeast(idx, .script);
                return inner_ty;
            },
            .persist_copy => |pc| {
                const inner_ty = try self.analyzeExpr(pc.expr);
                try self.atLeast(idx, .persistent);
                return inner_ty;
            },

            // ---- Pattern matching ------------------------------------------
            .case_expr => |ce| {
                _ = try self.analyzeExpr(ce.scrutinee);
                for (ce.arms) |arm| {
                    try self.pushScope();
                    defer self.popScope();
                    try self.analyzePattern(arm.pattern);
                    _ = try self.analyzeExprOrBlock(arm.body);
                }
                return T_UNKNOWN;
            },

            // ---- Match expression (enum/int switch) -----------------------
            .match_expr => |me| {
                const subj_ty = try self.analyzeExpr(me.subject);
                _ = subj_ty;
                var result_ty: TypeId = T_UNKNOWN;
                for (me.arms, 0..) |arm, ai| {
                    const body_ty = try self.analyzeExprOrBlock(arm.body);
                    if (ai == 0) result_ty = body_ty;
                }
                return result_ty;
            },

            // ---- Range expression ------------------------------------------
            .range => |r| {
                _ = try self.analyzeExpr(r.lo);
                _ = try self.analyzeExpr(r.hi);
                return T_INT;
            },

            // ---- String interpolation --------------------------------------
            .str_interp => |si| {
                for (si.parts) |part| {
                    switch (part) {
                        .literal => {},
                        .expr => |e| _ = try self.analyzeExpr(e),
                    }
                }
                return T_STRING;
            },

            // ---- Array literal ---------------------------------------------
            .array_lit => |al| {
                for (al.elements) |elem| _ = try self.analyzeExpr(elem);
                return T_ARRAY;
            },

            // ---- Struct literal --------------------------------------------
            .struct_lit => |sl| {
                for (sl.fields) |f| _ = try self.analyzeExpr(f.value);
                return self.typeIdForStruct(sl.type_name);
            },

            // ---- Nested block ----------------------------------------------
            .block => {
                try self.analyzeBlock(idx);
                return T_VOID;
            },

            // ---- Synthetic (inserted after inference) ----------------------
            .promote => |p| return self.analyzeExpr(p.src),

            // ---- Pattern nodes appearing in expression position ------------
            .pattern_bind, .pattern_wildcard, .pattern_atom, .pattern_lit, .pattern_variant => return T_UNKNOWN,

            // ---- Tuple nodes -----------------------------------------------
            .tuple_lit => |tl| {
                for (tl.values) |v| _ = try self.analyzeExpr(v);
                return T_UNKNOWN; // tuple itself has no single type
            },
            .tuple_type => return T_UNKNOWN,
            .array_type => return T_UNKNOWN,

            else => return T_UNKNOWN,
        }
    }

    fn analyzeIdent(self: *Sema, name: []const u8, span: Span, use_idx: NodeIndex) !TypeId {
        if (self.currentScope().lookup(name)) |sym| {
            self.stats.symbols_resolved += 1;
            // The use site inherits at least the symbol's lifetime.
            // Using flows_to(decl → use) would fire a violation when reading a
            // longer-lived symbol into a frame-lifetime use site — which is fine.
            // Instead, we pin the use site to *at least* the symbol's lifetime.
            try self.atLeast(use_idx, sym.lifetime);
            return sym.type_id;
        }
        self.stats.undefined_names += 1;
        try self.diags.err(span, "undefined name '{s}'", .{name});
        return T_UNKNOWN;
    }

    fn analyzeAttrRef(self: *Sema, name: []const u8, span: Span, use_idx: NodeIndex) !TypeId {
        if (self.module_scope.symbols.get(name)) |sym| {
            self.stats.symbols_resolved += 1;
            try self.atLeast(use_idx, sym.lifetime);
            return sym.type_id;
        }
        self.stats.undefined_names += 1;
        try self.diags.err(span, "undefined attribute '@{s}'", .{name});
        return T_UNKNOWN;
    }

    fn analyzePattern(self: *Sema, idx: NodeIndex) !void {
        _ = try self.lt_table.ensureNode(idx);
        switch (self.pool.get(idx).*) {
            .pattern_bind => |pb| {
                // Introduce the bound name into the arm's scope.
                try self.currentScope().define(self.allocator, .{
                    .name     = pb.name,
                    .type_id  = T_UNKNOWN,
                    .lifetime = .frame,
                    .node_idx = idx,
                });
                self.stats.symbols_resolved += 1;
            },
            .pattern_lit => |pl| _ = try self.analyzeExpr(pl.inner),
            .pattern_variant => |pv| {
                // Define all bindings in the arm's scope with T_UNKNOWN type.
                for (pv.bindings) |binding_name| {
                    try self.currentScope().define(self.allocator, .{
                        .name     = binding_name,
                        .type_id  = T_UNKNOWN,
                        .lifetime = .frame,
                        .node_idx = idx,
                    });
                    self.stats.symbols_resolved += 1;
                }
            },
            else => {},
        }
    }

    fn analyzeExprOrBlock(self: *Sema, idx: NodeIndex) anyerror!TypeId {
        return switch (self.pool.get(idx).*) {
            .block => blk: {
                try self.analyzeBlock(idx);
                break :blk T_VOID;
            },
            else => self.analyzeExpr(idx),
        };
    }
};

// ---------------------------------------------------------------------------
// Free helpers
// ---------------------------------------------------------------------------

fn resolveLifetime(ann: LifetimeAnnotation, default: Lifetime) Lifetime {
    return switch (ann) {
        .inferred  => default,
        .explicit  => |l| l,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Lexer = @import("lexer").Lexer;
const Parser = @import("parser").Parser;

/// Arena-backed end-to-end parse + sema helper.
const TestSema = struct {
    arena: std.heap.ArenaAllocator,
    pool: AstPool,
    diags: DiagList,
    sema: Sema,

    fn init(src: []const u8) !TestSema {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const alloc = arena.allocator();

        var lex = Lexer.init(src);
        const toks = try lex.tokenize(alloc);
        var pool = AstPool.init(alloc);
        var diags = DiagList.init(alloc);
        var parser = Parser.init(toks, &pool, &diags, alloc);
        const top_level = try parser.parseFile();

        var sem = Sema.init(&pool, &diags, alloc);
        try sem.analyze(top_level);

        return .{ .arena = arena, .pool = pool, .diags = diags, .sema = sem };
    }

    fn deinit(self: *TestSema) void {
        self.arena.deinit();
    }
};

test "literals resolve to correct types" {
    var ts = try TestSema.init(
        \\def f() do
        \\  42
        \\  3.14
        \\  true
        \\  "hello"
        \\  :ok
        \\end
    );
    defer ts.deinit();
    try testing.expect(!ts.diags.hasErrors());
}

test "undefined name produces error" {
    var ts = try TestSema.init(
        \\def f() do
        \\  undefined_var
        \\end
    );
    defer ts.deinit();
    try testing.expect(ts.diags.hasErrors());
    try testing.expect(ts.sema.stats.undefined_names > 0);
}

test "defined local resolves without error" {
    var ts = try TestSema.init(
        \\def f() do
        \\  x :: frame = 42
        \\  x
        \\end
    );
    defer ts.deinit();
    try testing.expect(!ts.diags.hasErrors());
    try testing.expect(ts.sema.stats.symbols_resolved > 0);
}

test "explicit frame lifetime constraint" {
    var ts = try TestSema.init(
        \\def f() do
        \\  x :: frame = 9.8
        \\end
    );
    defer ts.deinit();
    try testing.expect(!ts.diags.hasErrors());
    // Find the var_decl node (node 0 is fn_decl, further in is block/var_decl)
    // Just verify no errors and lifetime inference ran.
    try testing.expect(ts.sema.lt_table.solved.items.len > 0);
}

test "copy_to_script result is script lifetime" {
    var ts = try TestSema.init(
        \\def f() do
        \\  raw :: frame = 1
        \\  saved = copy_to_script(raw)
        \\end
    );
    defer ts.deinit();
    try testing.expect(!ts.diags.hasErrors());
    // Find the copy_to_script node and verify its solved lifetime is .script.
    var found_script = false;
    for (ts.sema.lt_table.solved.items) |maybe_lt| {
        if (maybe_lt) |lt| {
            if (lt == .script) { found_script = true; break; }
        }
    }
    try testing.expect(found_script);
}

test "persist_copy result is persistent lifetime" {
    var ts = try TestSema.init(
        \\@score :: script = 0
        \\def save() do
        \\  persist_copy(@score)
        \\end
    );
    defer ts.deinit();
    try testing.expect(!ts.diags.hasErrors());
    var found_persistent = false;
    for (ts.sema.lt_table.solved.items) |maybe_lt| {
        if (maybe_lt) |lt| {
            if (lt == .persistent) { found_persistent = true; break; }
        }
    }
    try testing.expect(found_persistent);
}

test "@attr reference resolves and carries script lifetime" {
    var ts = try TestSema.init(
        \\@score :: script = 0
        \\def f() do
        \\  @score
        \\end
    );
    defer ts.deinit();
    try testing.expect(!ts.diags.hasErrors());
    try testing.expect(ts.sema.stats.symbols_resolved > 0);
}

test "undefined @attr produces error" {
    var ts = try TestSema.init(
        \\def f() do
        \\  @no_such_attr
        \\end
    );
    defer ts.deinit();
    try testing.expect(ts.diags.hasErrors());
}

test "binary expression type inference" {
    var ts = try TestSema.init(
        \\def f() do
        \\  x :: float = 1.0 + 2.0
        \\  y :: bool = x > 0.5
        \\end
    );
    defer ts.deinit();
    try testing.expect(!ts.diags.hasErrors());
}

test "function params are resolvable" {
    var ts = try TestSema.init(
        \\def add(a :: int, b :: int) do
        \\  a + b
        \\end
    );
    defer ts.deinit();
    try testing.expect(!ts.diags.hasErrors());
    try testing.expect(ts.sema.stats.symbols_resolved >= 2);
}

test "module-level function names are resolvable from other functions" {
    var ts = try TestSema.init(
        \\def helper() do
        \\  1
        \\end
        \\def caller() do
        \\  helper()
        \\end
    );
    defer ts.deinit();
    try testing.expect(!ts.diags.hasErrors());
}

test "case/when with atom pattern" {
    var ts = try TestSema.init(
        \\def f(s :: atom) do
        \\  case s do
        \\    when :idle -> "standing"
        \\    _ -> "other"
        \\  end
        \\end
    );
    defer ts.deinit();
    try testing.expect(!ts.diags.hasErrors());
}

test "downward lifetime assignment is a violation" {
    // Assigning a script-lifetime result to an (inferred) frame-lifetime var
    // via copy_to_script then assigning it back down should trigger a violation.
    // Here we assign a frame var to a script @attr and then force a downward flow.
    //
    // In practice the violation fires when the solver propagates and finds a
    // flows_to edge where src > dst.  This is a minimal trigger scenario:
    // a copy_to_script result (script) assigned to a var annotated as frame.
    var ts = try TestSema.init(
        \\def f() do
        \\  raw :: frame = 1
        \\  bad :: frame = copy_to_script(raw)
        \\end
    );
    defer ts.deinit();
    // The copy_to_script result is .script; flows_to bad (forced .frame) → violation.
    try testing.expect(ts.diags.hasErrors());
}

test "full hello.chasm-style program passes sema" {
    var ts = try TestSema.init(
        \\@score :: script = 0
        \\@high_score :: persistent = 0
        \\defp compute_delta(dt :: f32) :: f32 do
        \\  speed :: frame = 9.8
        \\  speed * dt
        \\end
        \\def on_tick(dt :: f32) do
        \\  delta :: frame = compute_delta(dt)
        \\  saved :: script = copy_to_script(delta)
        \\  @score = saved
        \\end
        \\def on_save() do
        \\  final :: persistent = persist_copy(@score)
        \\  @high_score = final
        \\end
    );
    defer ts.deinit();
    try testing.expect(!ts.diags.hasErrors());
    // All three lifetimes should appear after solving.
    try testing.expect(ts.sema.stats.frame_vars > 0);
    try testing.expect(ts.sema.stats.script_vars > 0);
    try testing.expect(ts.sema.stats.persistent_vars > 0);
}
