const std = @import("std");
const Lifetime = @import("runtime").Lifetime;
const Span = @import("diag").Span;

pub const NodeIndex = u32;
pub const invalid_node: NodeIndex = std.math.maxInt(NodeIndex);

pub const LifetimeAnnotation = union(enum) {
    inferred,
    explicit: Lifetime,
};

pub const BinaryOp = enum {
    add, sub, mul, div, mod,
    eq, neq, lt, lte, gt, gte,
    @"and", @"or",
};

pub const UnaryOp = enum { neg, not };

pub const CaseArm = struct {
    pattern: NodeIndex,
    body: NodeIndex,
};

pub const MatchArm = struct {
    pattern: NodeIndex, // ident or pattern_wildcard
    body: NodeIndex,
};

pub const StrPart = union(enum) {
    literal: []const u8,
    expr: NodeIndex,
};

pub const StructLitField = struct {
    name: []const u8,
    value: NodeIndex,
};

pub const EnumVariant = struct {
    name: []const u8,
    payload_types: []const []const u8, // empty = tag-only
};

pub const Node = union(enum) {
    // --- Declarations -------------------------------------------------------

    /// `def`/`defp` function declaration.
    fn_decl: struct {
        name: []const u8,
        params: []Param,
        ret_lt: LifetimeAnnotation,
        ret_ty: ?NodeIndex,
        body: NodeIndex,
        is_public: bool,
        span: Span,
    },

    /// `defstruct Name do ... end`
    struct_decl: struct {
        name: []const u8,
        fields: []Field,
        span: Span,
    },

    /// `@name :: lifetime [type] = expr`  — module-level attribute
    attr_decl: struct {
        name: []const u8,
        lifetime: LifetimeAnnotation,
        ty: ?NodeIndex,
        init: NodeIndex,
        span: Span,
    },

    /// `name :: [lifetime] [type] = expr`  — annotated local binding
    var_decl: struct {
        name: []const u8,
        lifetime: LifetimeAnnotation,
        ty: ?NodeIndex,
        init: NodeIndex,
        span: Span,
    },

    // --- Statements ---------------------------------------------------------

    block: struct {
        stmts: []NodeIndex,
        span: Span,
    },

    assign: struct {
        target: NodeIndex,
        value: NodeIndex,
        span: Span,
    },

    if_stmt: struct {
        cond: NodeIndex,
        then_block: NodeIndex,
        else_block: NodeIndex, // invalid_node if absent
        span: Span,
    },

    while_stmt: struct {
        cond: NodeIndex,
        body: NodeIndex,
        span: Span,
    },

    /// `for <var> in <iter> do ... end`
    for_in: struct {
        var_name: []const u8,
        iter: NodeIndex,
        body: NodeIndex,
        span: Span,
    },

    /// `lo..hi` range expression
    range: struct {
        lo: NodeIndex,
        hi: NodeIndex,
        span: Span,
    },

    return_stmt: struct {
        value: NodeIndex, // invalid_node for bare return
        span: Span,
    },

    break_stmt: struct { span: Span },
    continue_stmt: struct { span: Span },

    /// `x, y = expr`  — destructuring assignment from a multi-return call
    multi_assign: struct {
        targets: [][]const u8,
        value: NodeIndex,
        span: Span,
    },

    expr_stmt: struct {
        expr: NodeIndex,
        span: Span,
    },

    // --- Expressions --------------------------------------------------------

    int_lit: struct { value: i64, span: Span },
    float_lit: struct { value: f64, span: Span },
    bool_lit: struct { value: bool, span: Span },
    string_lit: struct { value: []const u8, span: Span },

    /// `:name` atom
    atom_lit: struct { value: []const u8, span: Span },

    ident: struct { name: []const u8, span: Span },

    /// `@name` — reference to a module attribute
    attr_ref: struct { name: []const u8, span: Span },

    binary: struct { op: BinaryOp, left: NodeIndex, right: NodeIndex, span: Span },
    unary: struct { op: UnaryOp, operand: NodeIndex, span: Span },

    call: struct { callee: NodeIndex, args: []NodeIndex, span: Span },
    field_access: struct { object: NodeIndex, field: []const u8, span: Span },
    index: struct { array: NodeIndex, idx: NodeIndex, span: Span },

    // --- Lifetime promotions ------------------------------------------------

    copy_to_script: struct { expr: NodeIndex, span: Span },
    persist_copy: struct { expr: NodeIndex, span: Span },

    // --- Builder pattern ----------------------------------------------------

    builder_init: struct { ty: NodeIndex, span: Span },
    builder_finish: struct { builder: NodeIndex, dst_lt: Lifetime, span: Span },

    // --- Pattern matching ---------------------------------------------------

    case_expr: struct {
        scrutinee: NodeIndex,
        arms: []CaseArm,
        span: Span,
    },

    /// Pattern nodes — used inside case arms.
    pattern_atom: struct { value: []const u8, span: Span }, // :name
    pattern_wildcard: struct { span: Span },                // _
    pattern_lit: struct { inner: NodeIndex, span: Span },   // 42, "str", true
    pattern_bind: struct { name: []const u8, span: Span },  // lowercase ident binding
    /// Matches an enum variant with payload bindings: `Variant(name1, name2)`
    pattern_variant: struct {
        variant_name: []const u8,
        bindings: []const []const u8, // names to bind payload fields to
        span: Span,
    },

    // --- String interpolation -----------------------------------------------

    /// `"text #{expr} more"`
    str_interp: struct {
        parts: []StrPart,
        span: Span,
    },

    // --- Array literal ------------------------------------------------------

    /// `[e, e, ...]` array literal
    array_lit: struct {
        elements: []NodeIndex,
        span: Span,
    },

    // --- Struct literal -----------------------------------------------------

    /// `TypeName { field: expr, field: expr }`
    struct_lit: struct {
        type_name: []const u8,
        fields: []StructLitField,
        span: Span,
    },

    // --- Synthetic (inserted by lifetime inference) -------------------------

    promote: struct { src: NodeIndex, dst_lt: Lifetime, span: Span },

    // --- Enum declaration ---------------------------------------------------

    /// `enum Name { Variant1, Variant2, ... }`
    enum_decl: struct {
        name: []const u8,
        variants: []EnumVariant,
        span: Span,
    },

    // --- Match expression ---------------------------------------------------

    /// `match expr { Pattern => body, ... }`
    match_expr: struct {
        subject: NodeIndex,
        arms: []MatchArm,
        span: Span,
    },

    // --- Extern declaration -------------------------------------------------

    /// `extern fn name(param: type) -> ReturnType`
    extern_decl: struct {
        name: []const u8,
        params: []FnParam,
        return_type: []const u8,
        c_name: []const u8, // defaults to name if not aliased
        span: Span,
    },

    // --- Import declaration -------------------------------------------------

    /// `import "path/to/module"`
    import_decl: struct {
        path: []const u8,
        span: Span,
    },

    // --- Type expressions ---------------------------------------------------

    type_ref: struct {
        name: []const u8,
        lifetime: LifetimeAnnotation,
        span: Span,
    },

    /// `[]ElemType` — typed array annotation
    array_type: struct {
        elem_name: []const u8,
        span: Span,
    },

    /// `(type1, type2)` — tuple return type annotation
    tuple_type: struct {
        types: []NodeIndex,
        span: Span,
    },

    /// `(v1, v2, ...)` — tuple value (used in return and multi-assign RHS)
    tuple_lit: struct {
        values: []NodeIndex,
        span: Span,
    },
};

pub const FnParam = struct {
    name: []const u8,
    type_name: []const u8,
};

pub const Param = struct {
    name: []const u8,
    lifetime: LifetimeAnnotation,
    ty: ?NodeIndex,
};

pub const Field = struct {
    name: []const u8,
    lifetime: LifetimeAnnotation,
    ty: ?NodeIndex,
    default: ?NodeIndex,
};

/// Return the source span of any node, if one is stored in that variant.
pub fn nodeSpan(pool: *const AstPool, idx: NodeIndex) ?Span {
    return switch (pool.get(idx).*) {
        .fn_decl       => |n| n.span,
        .struct_decl   => |n| n.span,
        .attr_decl     => |n| n.span,
        .var_decl      => |n| n.span,
        .block         => |n| n.span,
        .assign        => |n| n.span,
        .if_stmt       => |n| n.span,
        .while_stmt    => |n| n.span,
        .for_in        => |n| n.span,
        .range         => |n| n.span,
        .return_stmt   => |n| n.span,
        .break_stmt    => |n| n.span,
        .continue_stmt => |n| n.span,
        .multi_assign  => |n| n.span,
        .expr_stmt     => |n| n.span,
        .int_lit       => |n| n.span,
        .float_lit     => |n| n.span,
        .bool_lit      => |n| n.span,
        .string_lit    => |n| n.span,
        .atom_lit      => |n| n.span,
        .ident         => |n| n.span,
        .attr_ref      => |n| n.span,
        .binary        => |n| n.span,
        .unary         => |n| n.span,
        .call          => |n| n.span,
        .field_access  => |n| n.span,
        .index         => |n| n.span,
        .copy_to_script => |n| n.span,
        .persist_copy  => |n| n.span,
        .builder_init  => |n| n.span,
        .builder_finish => |n| n.span,
        .case_expr     => |n| n.span,
        .pattern_atom  => |n| n.span,
        .pattern_wildcard => |n| n.span,
        .pattern_lit   => |n| n.span,
        .pattern_bind    => |n| n.span,
        .pattern_variant => |n| n.span,
        .promote         => |n| n.span,
        .type_ref      => |n| n.span,
        .array_type    => |n| n.span,
        .tuple_type    => |n| n.span,
        .tuple_lit     => |n| n.span,
        .str_interp    => |n| n.span,
        .array_lit     => |n| n.span,
        .struct_lit    => |n| n.span,
        .enum_decl     => |n| n.span,
        .match_expr    => |n| n.span,
        .extern_decl   => |n| n.span,
        .import_decl   => |n| n.span,
    };
}

pub const AstPool = struct {
    nodes: std.ArrayListUnmanaged(Node) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AstPool {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AstPool) void {
        self.nodes.deinit(self.allocator);
    }

    pub fn push(self: *AstPool, node: Node) !NodeIndex {
        const idx: NodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return idx;
    }

    pub fn get(self: *const AstPool, idx: NodeIndex) *const Node {
        return &self.nodes.items[idx];
    }

    pub fn getMut(self: *AstPool, idx: NodeIndex) *Node {
        return &self.nodes.items[idx];
    }

    pub fn len(self: *const AstPool) usize {
        return self.nodes.items.len;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "push and get round-trip" {
    var pool = AstPool.init(std.testing.allocator);
    defer pool.deinit();

    const idx = try pool.push(.{ .int_lit = .{ .value = 42, .span = .{ .line = 1, .col = 1, .len = 2 } } });
    try std.testing.expectEqual(@as(i64, 42), pool.get(idx).int_lit.value);
}

test "atom_lit node" {
    var pool = AstPool.init(std.testing.allocator);
    defer pool.deinit();

    const idx = try pool.push(.{ .atom_lit = .{ .value = "idle", .span = .{ .line = 1, .col = 1, .len = 5 } } });
    try std.testing.expectEqualSlices(u8, "idle", pool.get(idx).atom_lit.value);
}

test "attr_ref node" {
    var pool = AstPool.init(std.testing.allocator);
    defer pool.deinit();

    const idx = try pool.push(.{ .attr_ref = .{ .name = "score", .span = .{ .line = 1, .col = 1, .len = 6 } } });
    try std.testing.expectEqualSlices(u8, "score", pool.get(idx).attr_ref.name);
}
