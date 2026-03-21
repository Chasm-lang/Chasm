# Changelog

## [0.4.0] — 2026-03-21 — Language features + bootstrap arena fix

### Summary

Five new language features are now fully implemented end-to-end: `import`, `strbuild`, the pipe operator `|>`, `case/when`, and `enum`. The bootstrap binary was rebuilt with larger arenas (16 MB frame / 32 MB script / 64 MB persistent) to handle the grown compiler source. Fixpoint verified.

### New language features

#### `import`
`import "path"` is resolved by the Go CLI (`resolveImports` in `cmd/cli/cli.go`) before compilation. All public functions and extern declarations from the imported file are concatenated into the combined source passed to the compiler.

#### `strbuild`
Type ID 8 added to sema (`resolve_type`, `builtin_ret`) and codegen (`c_type`). Maps to `ChasmStrBuilder` in `chasm_rt.h`. `str_builder_new()`, `str_builder_push()`, `str_builder_append()`, and `str_builder_build()` all resolve correctly.

#### Pipe operator `|>`
`a |> f(b)` desugars to `f(a, b)`.

- **Lexer**: `|>` lexed as `:pipe` token.
- **Parser**: `parse_pipe` wraps `parse_or`; emits `:pipe_expr` nodes with lhs/rhs.
- **Sema**: `:pipe_expr` walks both sides; result type is rhs type.
- **Codegen**: rhs must be a `:call` node; lhs is prepended as first argument.

#### `case / when / end`
```chasm
case status do
  when :idle    -> "standing by"
  when :running -> "in motion"
  _             -> "unknown"
end
```
- **Lexer**: `case` and `when` added as keywords.
- **Parser**: `case expr do when pat -> expr ... end` parsed into `:match_expr` nodes (same IR as `match`). Dotted patterns (`EnumName.Variant`) are parsed by consuming the `.Variant` suffix after the base name.
- **Codegen**: pattern dispatch uses `strcmp` for atom patterns (`:idle`), `==` for enum/dotted patterns (`Direction.North` → `Direction_North`), and `_` is the catch-all default.

#### `enum`
```chasm
enum Direction { North, South, East, West }
enum Shape { Circle(float), Rect(float, float) }
```
- **Lexer**: `enum` keyword added.
- **Parser**: `enum Name { Variant, ... }` parsed at file scope into `:enum_decl` nodes. Payload types encoded into the variant name string as `"Name:type1,type2"` (no `ch[]` slots used, avoiding pool corruption).
- **Sema**: `collect_struct_list` now registers enum types alongside structs, assigning them type IDs so `EnumName` resolves as a type.
- **Codegen**: `emit_enum_def` emits `typedef enum { EnumName_Variant = N, ... } EnumName;`. `emit_struct_defs` emits enums first, then structs. `field_get` on an enum-typed ident emits `EnumName_Variant` instead of `obj.field`.

### Bootstrap arena fix

The self-hosted bootstrap binary was compiled with 1 MB frame / 4 MB script / 16 MB persistent arenas. As the compiler source grew, the frame arena was exhausted during codegen string concatenations, truncating output mid-function.

Fix:
- `archive/zig-compiler/src/main.zig` updated to emit 16 MB / 32 MB / 64 MB arenas in the standalone harness.
- Zig compiler rebuilt; used to compile the full Chasm compiler source into a new bootstrap binary.
- `cmd/cli/cli.go` `writeStandaloneHarness` updated to match (16 MB / 32 MB / 64 MB).
- Three-stage fixpoint verified (`stage2.c == stage3.c`). Bootstrap binary replaced.

### Bug fixes

- `codegen.chasm`: `match_expr` pattern `\"` replaced with `\042` for Zig-lexer compatibility (Zig string lexer has no escape processing).
- `codegen.chasm`: `emit_struct_defs` signature extended with `pool` and `ch` parameters so enum vs struct node tags can be distinguished at emit time.

---

## [0.3.0] — 2026-03-20 — Go CLI + game script support

### Summary

The Zig CLI is retired. A new Go CLI (`cmd/chasm/`) replaces it as the user-facing driver for `chasm run`, `chasm compile`, and `chasm watch`. The self-hosted compiler now supports `@attrs`, hex integer literals, and the Raylib engine binding — enough to compile and run `examples/game/example.chasm` end-to-end with no Zig dependency.

### New: Go CLI (`cmd/chasm/`)

- `chasm run <file.chasm>` — compile source → C, link standalone harness, execute.
- `chasm run --engine raylib <file.chasm>` — compile, link against Raylib + `engine/main.c`, execute.
- `chasm compile <file.chasm>` — emit `<file>.c` next to the source.
- `chasm watch <file.chasm>` — poll for changes, recompile and rerun on each save.
- `chasm version` / `chasm help`.
- Auto-detects the repo root via `CHASM_HOME` env var or by walking up from the executable.
- `install.sh` updated to `go build` the CLI; no longer requires Zig or copies a pre-built binary.

### Compiler: `@attr` support

Script- and persistent-lifetime module attributes (`@x :: script = 400.0`) now work end-to-end:

- **Lexer**: `@` (ASCII 64) is consumed as `:at_ident` token carrying the full `@name` lexeme.
- **Parser**: `@name :: lifetime = expr` at file scope → `:at_decl` node; `@name = expr` inside a function → `:at_assign` node; `@name` in an expression → `:at_ref` node.
- **Sema**: `@attrs` are pre-populated into the symbol table before functions are type-checked, so `@name` references inside function bodies resolve correctly.
- **Codegen**: emits `static <type> g_<name>;` globals and a `chasm_module_init(ChasmCtx *ctx)` function that initializes them; `:at_ref` → `g_<name>`; `:at_assign` → `g_<name> = ...;`.
- `is_stmt_tag` extended to include `:at_assign` so attribute assignments inside `if`/`while` bodies are emitted.

### Compiler: hex integer literals

`0x`-prefixed hex literals (`0x181820ff`, `0xff4455ff`) are now lexed correctly. The digit branch in the lexer checks for `0x`/`0X` and consumes hex digits (`0-9`, `a-f`, `A-F`) into a single `:int_lit` token. The C compiler receives the full literal unchanged.

### Runtime: lifetime promotion macros

`chasm_rt.h` now defines:

```c
#define chasm_copy_to_script(ctx, val)    (val)
#define chasm_persist_copy(ctx, val, ...) (val)
```

These are compile-time lifetime annotations with no runtime cost. The self-hosted codegen emits them as regular function calls; the macros satisfy the linker.

### Engine: Raylib shim (`engine/chasm_rl_shim.h`)

The self-hosted codegen emits `chasm_<funcname>(ctx, args)` for every call, including Raylib bindings. `chasm_rl_shim.h` maps all 40+ bindings to the corresponding `rl_*()` functions in `chasm_rl.h` via preprocessor macros. Force-included at compile time with `-include engine/chasm_rl_shim.h`.

### Documentation

- `bootstrap/bin/README.md` added — explains the two binaries, how to run the bootstrap compiler directly, how to use the CLI, and how to rebuild the bootstrap binary.

### Self-hosting fixpoint

Fixpoint `stage2.c == stage3.c` verified after all compiler changes. Bootstrap binary rebuilt from the updated self-hosted source.

---

## [0.2.0] — 2026-03-20 — Self-hosting milestone

### Summary

The Chasm bootstrap compiler (`bootstrap/*.chasm`) can now compile itself. The fixpoint `output_B.c == output_C.c` is verified: the Chasm-written compiler produces identical output across two compilation rounds.

### Repository restructure

- `src/`, `build.zig`, `build.zig.zon` moved to `archive/zig-compiler/` — the Zig compiler is frozen; no further PRs against it.
- `bootstrap/bin/chasm-macos-arm64` — pre-built ReleaseFast binary from the archived Zig source. This is the compiler used to bootstrap further development.
- `compiler/` created at the repo root. `compiler/sema.chasm` is the first production-quality module written in Chasm. Stubs for `lexer.chasm`, `parser.chasm`, `ir.chasm`, `codegen.chasm`, `main.chasm` mark the work ahead.
- `std/` created with stubs for `math.chasm`, `string.chasm`, `collections.chasm`, `io.chasm`.
- `SPEC.md` added — authoritative language specification (keywords, types, operators, lifetime rules, built-in functions).
- `install.sh` updated — installs from the pre-built binary; no Zig required on the user's machine.

### Bootstrap bug fixes (achieved fixpoint)

Three bugs fixed in the Chasm bootstrap compiler:

1. **`parse_if` else-if consumed wrong `end_kw`** — When `else\n  if` appears in source (newline between `else` and `if`), the inner `parse_if` consumed its own `end` but left pos at a newline before the outer `end`. The outer `end_kw` was then consumed by the wrong `parse_block_body`, causing loop body child-count (`cl=1`) errors and spurious `break`/`continue` outside loop diagnostics. Fixed by calling `skip_newlines` before checking for `end_kw` in the else-if return path.

2. **`fn_split_ret` returned `int64_t` for void functions** — The parser encodes all function names as `"name::ret_type"`. For void functions `ret_type` is empty, so `fn_split_ret` found `::`, extracted `""`, and called `resolve_type("") = 0` (int64_t). Fixed by checking `str_len(type_str) == 0` before `resolve_type` and returning 6 (void) in that case.

3. **`get` method returned wrong element type** — `sema_expr` hardcoded `get` to return type 0 (int64_t) for all arrays. Fixed by extending the `Sym` struct with `elem_type`, populating it from array type annotations (`[]T`) at `var_decl` and parameter sites, and using `sym_elem_lookup` in the `get` handler.

---

## [0.1.0] — Initial release

- Zig compiler: lexer, parser, sema, IR, C99 code generator, WASM emitter.
- Raylib 5.5 engine integration with hot-reload.
- LSP with diagnostics, hover, signature help.
- Three-lifetime memory model: frame / script / persistent.
- VS Code / Cursor extension with syntax highlighting.
