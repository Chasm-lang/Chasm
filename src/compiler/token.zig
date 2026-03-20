const std = @import("std");

pub const TokenKind = enum {
    // Literals
    int_lit,
    float_lit,
    string_lit,
    atom_lit, // :name  (the whole :ident is one token)
    true_kw,
    false_kw,

    // Identifiers
    ident,

    // Declaration keywords
    def_kw,
    defp_kw,
    defstruct_kw,

    // Control flow
    return_kw,
    if_kw,
    else_kw,
    while_kw,
    for_kw,
    in_kw,
    break_kw,
    continue_kw,
    case_kw,
    when_kw,

    // Block delimiters
    do_kw,
    end_kw,

    // Logical operators (keyword form)
    and_kw,
    or_kw,

    // Lifetime keywords (lowercase)
    frame_kw,
    script_kw,
    persistent_kw,

    // Promotion builtins
    copy_to_script_kw,
    persist_copy_kw,

    // Builder keywords
    builder_kw,
    finish_kw,
    freeze_kw,

    // Punctuation
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,   // kept for future map literal syntax
    rbrace,
    comma,
    dot,
    dot_dot,
    colon,        // lone ':'  (rare, kept for forward compat)
    colon_colon,  // '::'  lifetime/type annotation
    arrow,        // '->'  case arm separator
    at_sign,      // '@'   module attribute sigil
    pipe_gt,      // '|>'  pipe operator
    newline,      // significant newline (virtual semicolon)

    // Operators
    eq,      // =
    eqeq,    // ==
    bang_eq, // !=
    plus,
    minus,
    star,
    slash,
    percent,
    lt,
    lt_eq,
    gt,
    gt_eq,
    bang,

    // Enum + match
    enum_kw,
    match_kw,
    fat_arrow, // =>
    pipe,      // |  (bare pipe, distinct from |>)

    // FFI
    extern_kw,

    // Modules
    import_kw,

    // Special
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    line: u32,
    col: u32,
};

const keywords = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "def", .def_kw },
    .{ "defp", .defp_kw },
    .{ "defstruct", .defstruct_kw },
    .{ "return", .return_kw },
    .{ "if", .if_kw },
    .{ "else", .else_kw },
    .{ "while", .while_kw },
    .{ "for", .for_kw },
    .{ "in", .in_kw },
    .{ "break", .break_kw },
    .{ "continue", .continue_kw },
    .{ "case", .case_kw },
    .{ "when", .when_kw },
    .{ "do", .do_kw },
    .{ "end", .end_kw },
    .{ "and", .and_kw },
    .{ "or", .or_kw },
    .{ "true", .true_kw },
    .{ "false", .false_kw },
    .{ "frame", .frame_kw },
    .{ "script", .script_kw },
    .{ "persistent", .persistent_kw },
    .{ "copy_to_script", .copy_to_script_kw },
    .{ "persist_copy", .persist_copy_kw },
    .{ "builder", .builder_kw },
    .{ "finish", .finish_kw },
    .{ "freeze", .freeze_kw },
    .{ "enum", .enum_kw },
    .{ "match", .match_kw },
    .{ "extern", .extern_kw },
    .{ "import", .import_kw },
});

pub fn lookupKeyword(ident: []const u8) ?TokenKind {
    return keywords.get(ident);
}

/// Tokens after which a newline is significant (acts as statement terminator).
pub fn isLineCloser(kind: TokenKind) bool {
    return switch (kind) {
        .int_lit,
        .float_lit,
        .string_lit,
        .atom_lit,
        .true_kw,
        .false_kw,
        .ident,
        .rparen,
        .rbracket,
        .rbrace,
        .end_kw,
        .return_kw,
        .break_kw,
        .continue_kw,
        .else_kw,
        => true,
        else => false,
    };
}
