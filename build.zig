const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- Runtime module ----------------------------------------------------
    const runtime_mod = b.addModule("runtime", .{
        .root_source_file = b.path("src/runtime/arena.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- Prelude module (shared between compiler and LSP) ------------------
    const prelude_mod = b.addModule("prelude", .{
        .root_source_file = b.path("src/compiler/prelude.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- Compiler modules --------------------------------------------------
    const diag_mod = b.addModule("diag", .{
        .root_source_file = b.path("src/compiler/diag.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
        },
    });

    const token_mod = b.addModule("token", .{
        .root_source_file = b.path("src/compiler/token.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lexer_mod = b.addModule("lexer", .{
        .root_source_file = b.path("src/compiler/lexer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "token", .module = token_mod },
        },
    });

    const ast_mod = b.addModule("ast", .{
        .root_source_file = b.path("src/compiler/ast.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "diag", .module = diag_mod },
        },
    });

    const lifetime_mod = b.addModule("lifetime", .{
        .root_source_file = b.path("src/compiler/lifetime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "ast", .module = ast_mod },
            .{ .name = "diag", .module = diag_mod },
        },
    });

    const parser_mod = b.addModule("parser", .{
        .root_source_file = b.path("src/compiler/parser.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "diag", .module = diag_mod },
            .{ .name = "token", .module = token_mod },
            .{ .name = "lexer", .module = lexer_mod },
            .{ .name = "ast", .module = ast_mod },
        },
    });

    const module_resolver_mod = b.addModule("module_resolver", .{
        .root_source_file = b.path("src/compiler/module_resolver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    const sema_mod = b.addModule("sema", .{
        .root_source_file = b.path("src/compiler/sema.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "ast", .module = ast_mod },
            .{ .name = "diag", .module = diag_mod },
            .{ .name = "lifetime", .module = lifetime_mod },
            .{ .name = "lexer", .module = lexer_mod },
            .{ .name = "parser", .module = parser_mod },
            .{ .name = "module_resolver", .module = module_resolver_mod },
        },
    });

    const ir_mod = b.addModule("ir", .{
        .root_source_file = b.path("src/compiler/ir.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "ast", .module = ast_mod },
        },
    });

    const reload_mod = b.addModule("reload", .{
        .root_source_file = b.path("src/compiler/reload.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "ir",      .module = ir_mod },
            .{ .name = "sema",    .module = sema_mod },
        },
    });

    const lower_mod = b.addModule("lower", .{
        .root_source_file = b.path("src/compiler/lower.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "ast", .module = ast_mod },
            .{ .name = "diag", .module = diag_mod },
            .{ .name = "sema", .module = sema_mod },
            .{ .name = "ir", .module = ir_mod },
            .{ .name = "lexer", .module = lexer_mod },
            .{ .name = "parser", .module = parser_mod },
        },
    });

    const codegen_mod = b.addModule("codegen", .{
        .root_source_file = b.path("src/compiler/codegen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "ast",     .module = ast_mod },
            .{ .name = "diag",    .module = diag_mod },
            .{ .name = "sema",    .module = sema_mod },
            .{ .name = "ir",      .module = ir_mod },
            .{ .name = "reload",  .module = reload_mod },
            .{ .name = "lower",   .module = lower_mod },
            .{ .name = "lexer",   .module = lexer_mod },
            .{ .name = "parser",  .module = parser_mod },
        },
    });

    const codegen_wasm_mod = b.addModule("codegen_wasm", .{
        .root_source_file = b.path("src/compiler/codegen_wasm.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ir", .module = ir_mod },
        },
    });

    // ---- Executable --------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "chasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "prelude",      .module = prelude_mod },
                .{ .name = "runtime", .module = runtime_mod },
                .{ .name = "diag", .module = diag_mod },
                .{ .name = "token", .module = token_mod },
                .{ .name = "lexer", .module = lexer_mod },
                .{ .name = "ast", .module = ast_mod },
                .{ .name = "parser", .module = parser_mod },
                .{ .name = "lifetime", .module = lifetime_mod },
                .{ .name = "sema", .module = sema_mod },
                .{ .name = "ir",      .module = ir_mod },
                .{ .name = "reload",  .module = reload_mod },
                .{ .name = "lower",        .module = lower_mod },
                .{ .name = "codegen",      .module = codegen_mod },
                .{ .name = "codegen_wasm", .module = codegen_wasm_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the Chasm compiler");
    run_step.dependOn(&run_cmd.step);

    // ---- LSP modules -------------------------------------------------------
    const jsonrpc_mod = b.addModule("jsonrpc", .{
        .root_source_file = b.path("src/lsp/jsonrpc.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    const lsp_server_mod = b.addModule("server", .{
        .root_source_file = b.path("src/lsp/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "prelude",  .module = prelude_mod },
            .{ .name = "jsonrpc", .module = jsonrpc_mod },
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "ast",     .module = ast_mod },
            .{ .name = "diag",    .module = diag_mod },
            .{ .name = "lexer",   .module = lexer_mod },
            .{ .name = "parser",  .module = parser_mod },
            .{ .name = "sema",    .module = sema_mod },
        },
    });

    const lsp_exe = b.addExecutable(.{
        .name = "chasm-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "server", .module = lsp_server_mod },
            },
        }),
    });
    b.installArtifact(lsp_exe);

    // ---- Tests -------------------------------------------------------------
    const test_step = b.step("test", "Run all tests");

    const test_modules = [_]struct { name: []const u8, path: []const u8, imports: []const std.Build.Module.Import }{
        .{ .name = "arena", .path = "src/runtime/arena.zig", .imports = &.{} },
        .{ .name = "diag", .path = "src/compiler/diag.zig", .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
        } },
        .{ .name = "lexer", .path = "src/compiler/lexer.zig", .imports = &.{
            .{ .name = "token", .module = token_mod },
        } },
        .{ .name = "ast", .path = "src/compiler/ast.zig", .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "diag", .module = diag_mod },
        } },
        .{ .name = "lifetime", .path = "src/compiler/lifetime.zig", .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "ast", .module = ast_mod },
            .{ .name = "diag", .module = diag_mod },
        } },
        .{ .name = "parser", .path = "src/compiler/parser.zig", .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "diag", .module = diag_mod },
            .{ .name = "token", .module = token_mod },
            .{ .name = "lexer", .module = lexer_mod },
            .{ .name = "ast", .module = ast_mod },
        } },
        .{ .name = "sema", .path = "src/compiler/sema.zig", .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "ast", .module = ast_mod },
            .{ .name = "diag", .module = diag_mod },
            .{ .name = "lifetime", .module = lifetime_mod },
            .{ .name = "lexer", .module = lexer_mod },
            .{ .name = "parser", .module = parser_mod },
            .{ .name = "module_resolver", .module = module_resolver_mod },
        } },
        .{ .name = "ir", .path = "src/compiler/ir.zig", .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "ast", .module = ast_mod },
        } },
        .{ .name = "reload", .path = "src/compiler/reload.zig", .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "ir",      .module = ir_mod },
            .{ .name = "sema",    .module = sema_mod },
        } },
        .{ .name = "lower", .path = "src/compiler/lower.zig", .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "ast", .module = ast_mod },
            .{ .name = "diag", .module = diag_mod },
            .{ .name = "sema", .module = sema_mod },
            .{ .name = "ir", .module = ir_mod },
            .{ .name = "lexer", .module = lexer_mod },
            .{ .name = "parser", .module = parser_mod },
        } },
        .{ .name = "codegen", .path = "src/compiler/codegen.zig", .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "ast",     .module = ast_mod },
            .{ .name = "diag",    .module = diag_mod },
            .{ .name = "sema",    .module = sema_mod },
            .{ .name = "ir",      .module = ir_mod },
            .{ .name = "reload",  .module = reload_mod },
            .{ .name = "lower",   .module = lower_mod },
            .{ .name = "lexer",   .module = lexer_mod },
            .{ .name = "parser",  .module = parser_mod },
        } },
        .{ .name = "jsonrpc", .path = "src/lsp/jsonrpc.zig", .imports = &.{} },
        .{ .name = "lsp_server", .path = "src/lsp/server.zig", .imports = &.{
            .{ .name = "jsonrpc",  .module = jsonrpc_mod },
            .{ .name = "runtime",  .module = runtime_mod },
            .{ .name = "ast",      .module = ast_mod },
            .{ .name = "diag",     .module = diag_mod },
            .{ .name = "lexer",    .module = lexer_mod },
            .{ .name = "parser",   .module = parser_mod },
            .{ .name = "sema",     .module = sema_mod },
            .{ .name = "prelude",  .module = prelude_mod },
        } },
    };

    inline for (test_modules) |tm| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(tm.path),
                .target = target,
                .optimize = optimize,
                .imports = tm.imports,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
