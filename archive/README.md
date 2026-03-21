# Zig Compiler (Archived)

This is the original Zig implementation of the Chasm compiler. It produced the bootstrap binary that lives in `bootstrap/bin/`.

**This directory is frozen. Please do not open PRs against it.**

The active compiler source is now being written in Chasm itself, in `compiler/`. The Zig compiler served its purpose: bootstrapping the language to the point where it can compile itself.

## What's here

- `src/compiler/` — Zig lexer, parser, semantic analysis, and code generator
- `src/lsp/` — Zig-based language server (Chasm LSP)
- `src/runtime/` — C runtime headers used by generated C output
- `build.zig` / `build.zig.zon` — Zig build system files

## Why archived

At the self-hosting milestone (`v0.2.0`), the Chasm bootstrap compiler (`bootstrap/*.chasm`) can compile itself — i.e., `output_B.c == output_C.c`. The Zig compiler is no longer needed for development. It is kept here for reference and historical record.
