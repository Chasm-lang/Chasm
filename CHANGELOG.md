# Changelog

## [0.6.0] — 2026-03-21 — String interpolation, range, multiple return values

### Summary

Three new language features implemented end-to-end: string interpolation `"#{expr}"`, range literals `lo..hi`, and multiple return values `return a, b` / `a, b = f()`. Bootstrap fixpoint verified.

### String interpolation

`"hello #{name}, score #{score}"` expands at compile time into a `str_concat` tree.

- **Lexer**: `..` lexed as `:dotdot` token; float literal scanner fixed so `1..10` no longer misparsed as `1.` float.
- **Parser**: `parse_primary` for `:string_lit` scans for `#{`, re-lexes each interpolated expression, wraps it in `:interp_expr`, and builds a left-associative `str_concat` call tree. Bug fix: renamed local variable `lex` → `lx` in `parse_primary` to stop it shadowing the `lex()` lexer function (was causing the bootstrap binary to call a string pointer as a function, producing an infinite loop).
- **Sema**: `:interp_expr` → type 4 (string).
- **Codegen**: `:interp_expr` dispatches to `chasm_int_to_str`, `chasm_float_to_str`, `chasm_bool_to_str`, or passes strings through directly.

### Range `lo..hi`

`for i in 0..10 do` iterates integers 0–9.

- **Parser**: `parse_add` detects `:dotdot` and emits `:range_expr` node.
- **Sema**: `:range_expr` → type 7 (array).
- **Codegen**: `:range_expr` → `chasm_range(ctx, lo, hi)`. For loop emitter now stores the iterable in a `ChasmArray _iter` temp variable to avoid double-evaluating rvalue expressions like `chasm_range(...)` (was causing `&rvalue` C compile error).
- **Runtime**: `chasm_range(ctx, lo, hi)` added to `runtime/chasm_rt.h`.

### Multiple return values

`return a, b` and `lo, hi = f()` work for 2- and 3-value tuples.

- **Parser**: `parse_return` collects comma-separated exprs into `:tuple_lit`; `parse_stmt` detects `ident, ident =` and emits `:tuple_dest`.
- **Sema**: `:tuple_lit` → type 9; `:tuple_dest` registers each lhs name.
- **Codegen**: `:tuple_lit` → `(ChasmTuple2){v0, v1}`; `:tuple_dest` emits `ChasmTuple2 _t = rhs; int64_t a = _t.v0; int64_t b = _t.v1;` at the outer scope (no wrapping `{}` block so variables are visible after the destructuring). Function return type detection (`fn_actual_ret_c`) walks the body for a `return_stmt` with a `tuple_lit` child and emits `ChasmTuple2`/`ChasmTuple3` instead of `int64_t`.
- **Runtime**: `ChasmTuple2`, `ChasmTuple3` structs added to `runtime/chasm_rt.h`.

### Bug fixes

- macOS binary replacement: bootstrap install now uses `cp + mv` (atomic rename) instead of `cp` directly over the running binary, preventing macOS from keeping a stale in-memory image.

---



### Bug fixes

- `parser.chasm`: `match { }` arms were allocating `b: 0` instead of `b: -1`. Node 0 is a valid pool slot, so every atom-pattern arm appeared to have a payload binding, triggering `__auto_type bind = subj.:atom.v` extraction in codegen. Fixed to use `-1` as the no-binding sentinel.
- Bootstrap rebuilt and fixpoint verified.

---

## [0.5.0] — 2026-03-21 — Stdlib, enum payloads, WASM emitter

### Summary

Three major features land: stdlib modules are fully implemented, enum payload destructuring works end-to-end with `case/when`, and the WASM emitter (WAT text format) is ported from the old Zig compiler. Bootstrap fixpoint verified.

### Stdlib

- `std/collections.chasm` — rewritten: all functions use `.len`/`.get`/`.set`/`.push`/`.pop` method syntax; no broken extern declarations.
- `std/io.chasm` — rewritten: `print_label`, `print_label_f`, `print_label_b`, `print_sep`, `print_nl`, `assert_msg` added; builtins need no import.
- `std/math.chasm`, `std/string.chasm` — already complete, no changes needed.

### Enum payload destructuring

`Shape.Circle(42)` now works as a constructor expression. `case s do when Shape.Circle(r) -> r end` extracts the payload into `r`.

- **Parser**: `case/when` arms parse `Variant(binding)` patterns; binding ident stored in `arm_node.b`.
- **Sema**: `method_call` on an enum type name resolves to that enum's `type_id` (constructor return type).
- **Codegen**: `method_call` on an enum receiver emits `EnumName_make_Variant(val)`; payload enums emit tagged union structs + constructor macros; `match_expr` arms with bindings emit GNU statement expressions `({ __auto_type bind = subj.Variant.v; val; })`.

### WASM emitter

`chasm compile --target wasm file.chasm` emits WAT (WebAssembly Text Format).

- `compiler/wasm.chasm` — new file: `wasm_codegen` + `wat_fn` + `wat_expr` + `wat_stmts`.
- `compiler/main.chasm` — reads `/tmp/chasm_target.txt` and dispatches to `wasm_codegen` vs `codegen`.
- `cmd/cli/cli.go` — `--target wasm` flag writes the target hint and uses `.wat` output extension.
- Supported: int/float/bool arithmetic, function calls, if/while/return, locals, module `@attrs` as mutable globals, extern fn declarations as WASM imports.
- Not yet: arrays, structs, strings (require linear memory).

---

## [0.4.1] — 2026-03-21 — Bug fix: struct literal lookahead

### Bug fixes

- `parser.chasm`: `Name { ... }` is now only parsed as a struct literal when the token after `{` is an `:ident` (field name). Previously, `match state { :normal => ... }` had `state{` consumed as a struct literal, swallowing all match arms as field inits and producing garbage C output.
- Bootstrap binary rebuilt and fixpoint verified.

---

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
