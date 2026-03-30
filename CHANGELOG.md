# Changelog

## [1.8.0] — 2026-03-29 — Scripting style, if-expressions, string arrays, error fixes

### Summary

Chasm is now a scripting language. Top-level statements run directly without a `def main()` wrapper, matching the behaviour of Lua and Python. `if/else/end` works as an expression. String arrays (`[]string`) now emit correct C. Undeclared `@attr` references are caught at compile time. New builtins (`assert`, `log`, `todo`, easing functions) are recognised by the type checker. Type aliases `f32`/`f64` are accepted. All test scripts updated to new-style method API.

### Changes

- **feat(lang)**: scripting style — top-level statements outside any function are collected and emitted into `chasm_main` automatically; `def main()` is still supported and takes priority
- **feat(lang)**: `if/else/end` as an expression — `label = if x > 0 do "pos" else "neg" end` now works anywhere a value is expected; parser handles `if` in `parse_primary`
- **feat(sema)**: undeclared `@attr` references now emit `error[E001]: undefined attribute` with a help message showing the correct declaration syntax
- **feat(sema)**: `f32` and `f64` accepted as type aliases for `float`
- **feat(sema)**: `assert`, `assert_eq`, `log`, `todo`, `file_write`, `str_builder_push`, `str_builder_append` registered as known builtins (no more false E005)
- **feat(sema)**: easing functions (`ease_in`, `ease_out`, `ease_in_out`, `ease_in_cubic`, `ease_out_cubic`, `ease_in_out_cubic`, `ease_out_bounce`, `ease_in_bounce`, `ease_in_elastic`, `ease_out_elastic`) registered as float-returning builtins
- **fix(codegen)**: `[]string` and `[]atom` arrays now emit `chasm_array_new_s`, `chasm_array_push_s`, `chasm_array_get_s`, `chasm_array_set_s` — fixes C type errors when pushing `const char*` into `int64_t` arrays
- **fix(runtime)**: added `chasm_array_new_s`, `chasm_array_push_s`, `chasm_array_get_s`, `chasm_array_set_s`, `chasm_array_pop_s` to both `runtime/chasm_rt.h` and `engine/raylib/chasm_rt.h`
- **fix(sema)**: `codegen.chasm` internal `[]string` arrays (`fn_names`, `field_names`, `lt_names`, `candidates`) now correctly use `_s` variants — fixes 10 C compile errors in the self-hosted compiler
- **feat(spec)**: grammar updated — `if_expr` added to `primary_expr`; `f32`/`f64` added to type list; scripting style, if-expressions, type aliases, and easing functions documented
- **chore**: all test scripts updated to new-style method API (`.push()`, `.get()`, `.len` instead of `array_push()`, `array_get()`, `array_len()`)
- **chore**: `cmd/cli/cli.go` version bumped to `1.8.0`
- **bootstrap**: three-stage fixpoint verified (`stage2.c == stage3.c`), binary replaced

---

## [1.7.0] — 2026-03-29 — Struct literal defaults, cross-platform CLI, getenv builtin

### Summary

Struct literals now fill in omitted fields from their declared defaults. The CLI temp-path logic is fixed for macOS (`os.TempDir()` was returning `/var/folders/...` but the bootstrap binary hardcodes `/tmp`). Adds `getenv` and `str_format` builtins, and improves `array_new` element-type inference.

### Changes

- **fix(compiler)**: struct literals with omitted fields now emit declared default values instead of leaving members uninitialized — `Foo{ x: 1 }` correctly fills `y`, `z`, etc. from `defstruct` defaults
- **fix(parser)**: allow empty struct literals (`Foo{}`) — the parser previously required at least one field
- **fix(parser)**: struct field default value node is now stored in `field.b` so codegen can retrieve and emit it
- **fix(cli)**: `tmpPath` uses `/tmp` on Unix/macOS (matching the bootstrap binary's hardcoded path) and `os.TempDir()` on Windows — fixes "FileNotFound" on macOS where `os.TempDir()` returns `/var/folders/...`
- **feat(sema)**: register `getenv` as a string-returning builtin
- **feat(sema)**: register `str_format` as a string-returning builtin
- **feat(runtime)**: add `chasm_getenv` to `chasm_rt.h` for use by user scripts and future Windows bootstrap
- **feat(sema)**: `array_new(Type, cap)` element type is now inferred in `var`, plain assignment, and `@attr` initializer contexts (no explicit type annotation needed)

---

## [1.6.0] — 2026-03-29 — Godot plugin, typed heap arrays, runtime hardening

### Summary

Adds a complete Godot 4 GDExtension plugin (`ChasmComponent`), typed heap arrays via `array_new(Type, cap)`, and several compiler and runtime improvements including a parser bug fix for struct default values, arena overflow abort, and frame GC debug memset.

### Changes

- **feat(godot)**: new `--engine godot` mode and GDExtension plugin (`engine/godot/`, `addons/chasm/`) — attach `.chasm` scripts to Godot 4 nodes via `ChasmComponent`; compile-on-save, hot-reload via mtime polling, 20+ Godot API bindings (`move_and_slide`, `get_axis`, `is_action_just_pressed`, etc.)
- **feat**: `array_new(Type, cap)` syntax for heap-backed typed struct arrays — emits `chasm_array_new_typed(ctx, cap, sizeof(T))` with full VarElem propagation so `.push`/`.get`/`.set` use typed helpers automatically
- **feat**: `.cap` accessor on arrays — `arr.cap` returns the allocated capacity
- **feat(runtime)**: `chasm_alloc` aborts with a diagnostic message on arena overflow instead of silently returning NULL
- **feat(runtime)**: `ChasmArray` gains `elem_size` field; new `chasm_array_new_typed`, `chasm_array_set_raw`, `chasm_array_get_raw`, `chasm_array_push_raw` for raw element operations
- **feat(runtime)**: `CHASM_DEBUG` build flag enables `memset(0xCD)` on `chasm_clear_frame` to catch use-after-frame bugs early
- **fix(codegen)**: `chasm_array_fixed_init_<T>` now sets `elem_size = sizeof(T)` in the returned `ChasmArray`
- **fix(codegen)**: first-use `name = array.get(i)` on a typed array now infers the correct struct C type instead of `int64_t`
- **fix(parser)**: `defstruct` fields with default values (e.g. `x :: float = 0.0`) no longer generate spurious `int64_t =;` struct members — the default expression is now correctly skipped
- **feat(raylib)**: bundled pre-built raylib 5.5 for Linux x86_64 and Windows x86_64 — raylib engine works out of the box on all platforms
- **fix(cli)**: `compileSharedLib` outputs `.dll` on Windows
- **fix(cli)**: all hardcoded `/tmp/` paths replaced with `os.TempDir()` — compiler pipeline works on Windows

---

## [1.5.0] — 2026-03-24 — Struct arrays, struct update syntax, LSP fixes

### Summary

Typed struct arrays now work correctly with full C type safety. Introduces `expr with { field: val }` struct update syntax. LSP fixes for `selectionRange` and dot completions.

### Changes

- **feat**: `array_fixed(n, StructName{...})` generates typed C helpers (`chasm_array_get_T`, `chasm_array_set_T`) — fixes type errors when using struct arrays
- **feat**: struct update syntax — `e with { x: new_x }` copies base struct and overrides listed fields
- **fix(lsp)**: `selectionRange must be contained in fullRange` error on `textDocument/documentSymbol`
- **fix(lsp)**: method completions (`.set`, `.get`, etc.) now persist while typing after the dot
- **fix(lsp)**: `with` added as keyword for highlighting and completions
- **fix**: `on_tick(dt :: float)` signature corrected in VS Code snippets

## [1.4.0] — 2026-03-24 — CI hardening and self-hosted cross-compilation

### Summary

CI now runs cleanly on every push using only the committed bootstrap binary — no Zig source build required. The release workflow cross-compiles all four platform binaries from the self-hosted Chasm compiler using `zig cc` as a cross-compiler, ensuring release binaries always reflect the latest language features.

### Changes

- **Release workflow**: builds compiler source to C via self-hosted `bootstrap/bin/chasm-macos-arm64`, then uses `zig cc` to cross-compile for macOS arm64, macOS x86_64, Linux x86_64, and Windows x86_64 in a single job
- **CI workflow**: simplified to a single macOS arm64 job — Go tests, E2E compile, and bootstrap fixpoint using the committed binary; no Zig install required
- **`runtime/chasm_standalone.c`**: added minimal `main()` harness for linking compiled Chasm programs as standalone executables
- **`cmd/cli/cli.go`**: fixed bootstrap invocation — binary reads from `/tmp/sema_combined.chasm` and `/tmp/chasm_target.txt` (hardcoded paths); CLI correctly writes both before calling the bootstrap binary
- **Fixpoint**: runs to completion (stage2 == stage3) with errors surfaced instead of silently skipped

---

## [1.3.0] — 2026-03-24 — Cross-platform support (Linux, Windows, macOS Intel)

### Summary

Chasm now ships prebuilt binaries for all four major platforms. A GitHub Actions release workflow builds and publishes platform archives on every version tag. One-liner installers (`install.sh` / `install.ps1`) handle download, extraction, and PATH setup automatically.

### Platform support

| Platform | Bootstrap binary |
|---|---|
| macOS arm64 (Apple Silicon) | `chasm-macos-arm64` |
| macOS x86_64 (Intel) | `chasm-macos-x86_64` |
| Linux x86_64 | `chasm-linux-x86_64` |
| Windows x86_64 | `chasm-windows-x86_64.exe` |

### Release workflow (`.github/workflows/release.yml`)

On `git push --tags`, four parallel jobs build and upload platform archives:

- Each job installs Zig 0.15, builds the bootstrap binary from `archive/zig-compiler/` via `zig build -Doptimize=ReleaseFast`
- Go CLI compiled with `GOOS`/`GOARCH` cross-compilation; `defaultChasmHome` left empty so the binary resolves its home directory from its own location at runtime
- Archives: `.tar.gz` for Unix, `.zip` for Windows, each containing the CLI, bootstrap binary, runtime headers, engine preludes, and examples
- Uploaded to GitHub Releases via `softprops/action-gh-release`

### CI workflow (`.github/workflows/ci.yml`)

Runs on every push to `main` and every pull request, across all four platforms:

- Builds the bootstrap binary from `archive/zig-compiler/` on the target runner
- Runs `go test ./cmd/cli/...` (property-based tests for diagnostics and bindings)
- End-to-end compile test: `chasm compile examples/hello/hello.chasm`
- Bootstrap fixpoint check on macOS arm64 (authoritative platform): `stage2.c == stage3.c`

### Installers

**macOS / Linux** (`install.sh`):
```sh
curl -fsSL https://raw.githubusercontent.com/Chasm-lang/Chasm/main/install.sh | sh
```
Detects OS and architecture, downloads the matching release archive, extracts to `~/.chasm/`, symlinks `chasm` into `~/.local/bin`, and prints a PATH hint if needed.

**Windows** (`install.ps1`):
```powershell
irm https://raw.githubusercontent.com/Chasm-lang/Chasm/main/install.ps1 | iex
```
Downloads the `.zip` release, extracts to `%LOCALAPPDATA%\chasm`, and adds the bin directory to the user PATH registry key.

### CLI fix (`cmd/cli/cli.go`)

`bootstrapBin()` now appends `.exe` to the binary name when `runtime.GOOS == "windows"`, matching the `chasm-windows-x86_64.exe` naming convention.

## [1.2.0] — 2026-03-22 — LSP enhancements: imports, snippets, formatter, CodeLens

### Added
- **Import-aware completions** — typing `utils.` after `import "utils"` shows all public functions from that module
- **Go-to-definition across imports** — jump to the definition in the imported file
- **Snippets** — `tick`, `init`, `draw`, `struct`, `attr`, `fn`, `defp`, `for`, `forin`, `case`, `if`, `ifelse`, `while`, `enum`, `import`, `game` snippets in VS Code
- **Formatter** — `chasm fmt <file>` formats source in-place; LSP `textDocument/formatting` enables format-on-save in VS Code
- **CodeLens run button** — `▶ Run` appears above `on_tick`, `on_init`, `on_draw`, and `main`; clicking opens a terminal and runs `chasm run <file>`
- **`chasm.runFile` VS Code command** — also accessible from the editor title bar play button
- Extension bumped to `0.3.0`, LSP server bumped to `1.2.0`

## [1.2.1] — 2026-03-22 — Module-qualified call syntax (`utils.fn()`)

### Fixed
- `compiler/sema.chasm` — `utils.fn(args)` no longer emits E001 "undefined variable" for the module name. When a `:method_call` receiver is an identifier not in the symbol table, sema now detects it as a namespace-qualified call and skips receiver evaluation entirely, falling through to the existing `fnsig_lookup` path. E005 is still emitted if the function itself doesn't exist.
- `compiler/codegen.chasm` — namespace-qualified calls now emit `chasm_fn(ctx, args)` instead of the invalid `utils.fn(args)` C expression. The receiver identifier is checked against known structs/enums; if it matches neither, it's treated as a module prefix and discarded.
- Bootstrap rebuilt at fixpoint (stage2 == stage3 ✓), binary replaced.

## [1.1.0] — 2026-03-22 — Raylib runtime fixes + clean CC error output

### Summary

Two runtime bugs fixed for `chasm run --engine raylib`: extra `)` in the array seeding loop (generated invalid C), and missing helpers in `engine/raylib/chasm_rt.h` (`chasm_range`, fixed-array helpers). CC errors are now filtered and reformatted as clean Chasm-style diagnostics instead of leaking raw `/tmp/chasm_out.c:LINE:COL:` clang output.

### Bug fixes

- `compiler/codegen.chasm` — seeding loop for `array_fixed(N, default)` emitted `((double*)g_name.data))[_di]` (extra `)`). Fixed to `.data)[_di]`.
- `engine/raylib/chasm_rt.h` — added `chasm_range`, `chasm_array_fixed_in`, `chasm_array_push_fixed`, `chasm_array_fixed_in_f`, `chasm_array_push_fixed_f`, `chasm_array_get_f`, `chasm_array_set_f`, `chasm_array_new_in`. These were present in `runtime/chasm_rt.h` and emitted inline by codegen but missing from the raylib engine header.
- `compiler/codegen.chasm` — the inline helper block is now guarded with `#ifndef CHASM_ARRAY_FIXED_HELPERS_DEFINED` / `#endif`; the raylib header defines the macro before its own copies, preventing redefinition errors when compiling in raylib mode.

### CLI: clean CC error output (`cmd/cli/cli.go`)

`compileSharedLib` and the standalone `cc` call now capture cc stderr instead of passing it through raw. `filterCCErrors` parses clang's `file:line:col: severity: message` format and reformats it:

```
error[CC]: redefinition of 'chasm_array_fixed_in'
  --> generated C, line 114
  --> source: examples/game/shape_shooter.chasm
```

`note:` lines (internal C cross-references) are suppressed. Lines from engine headers pass through unchanged.

### Bootstrap

Bootstrap binary rebuilt and three-stage fixpoint verified (`stage2.c == stage3.c`).

## [1.0.0] — 2026-03-22 — Arena-backed arrays + complete lifetime enforcement

### Summary

`array_fixed(N)` lands as the canonical primitive for module-level arrays. Fixed-capacity arrays allocate from the arena matching their declared lifetime — no `malloc`, no heap, no GC. The lifetime model is now fully enforced for arrays and all expression forms. The shape_shooter demo is rewritten to use `array_fixed` for bullets and enemies.

### `array_fixed(N)` — arena-backed fixed-capacity arrays (`compiler/codegen.chasm`)

When a module attribute is declared as `@name :: lifetime = array_fixed(N)`, the compiler emits:

```c
static ChasmArray g_name;
// in chasm_module_init:
g_name = chasm_array_fixed_in(&ctx->script, N);
```

The `chasm_array_fixed_in` helper allocates `N × 8` bytes directly from the named arena — one contiguous allocation, no heap. `chasm_array_push_fixed` is a bounds-checked push that aborts on overflow instead of reallocating. Both helpers are emitted inline into the generated C only when needed.

| Operation | Cost |
|---|---|
| `arr.get(i)` | Single pointer deref |
| `arr.set(i, v)` | Bounds check + write |
| `arr.push(v)` | Bounds check + write, aborts on overflow |
| Frame array wipe | Bump pointer reset — zero per-element cost |
| Script array on hot-reload | Arena reset + reinit |

### Lifetime enforcement completed (`compiler/sema.chasm`)

`expr_lifetime` now propagates through all expression forms:

- **Builtin/user calls**: result lifetime is the max of all argument lifetimes (previously always returned frame)
- **Method calls**: result lifetime is the max of receiver and argument lifetimes
- **Literals**: return persistent (3) — compile-time constants are assignable anywhere
- **Binop/unary**: max of operand lifetimes (unchanged)
- **`@attr` refs**: carry the attr's declared lifetime (unchanged)

This means `clamp(@px + move_x * @pspeed * dt, ...)` correctly infers script lifetime (from `@px`) and no longer false-positives as E008 when assigned back to `@px :: script`.

### `builtin_ret` completed (`compiler/sema.chasm`)

All math, conversion, color, and vector builtins added: `cos`, `sin`, `sqrt`, `deg_to_rad`, `rad_to_deg`, `atan2`, `clamp`, `to_int`, `to_float`, `to_bool`, `rgb`, `rgba`, `color_lerp`, `color_mix`, `bit_and/or/xor/not/shl/shr`, `vec2_*`, `smooth_step`, `move_toward`, `angle_diff`, and more.

### Shape Shooter rewritten with `array_fixed` (`examples/game/shape_shooter.chasm`)

Bullets (4 slots) and enemies (8 slots) now use `array_fixed` per-field arrays:

```chasm
@bx     :: script = array_fixed(4)
@by     :: script = array_fixed(4)
@bvx    :: script = array_fixed(4)
@bvy    :: script = array_fixed(4)
@bactive :: script = array_fixed(4)

@ex     :: script = array_fixed(8)
@ey     :: script = array_fixed(8)
@ealive :: script = array_fixed(8)
```

Positions are stored as integers (via `to_int`/`to_float`) since `ChasmArray` elements are `int64_t`. Lifetime promotions are explicit: `copy_to_script()` for frame→script, `persist_copy()` for script→persistent.

### Bootstrap

Bootstrap binary rebuilt and three-stage fixpoint verified (`stage2.c == stage3.c`).

## [0.9.0] — 2026-03-22 — Rich compiler diagnostics + lifetime violation detection

### Summary

The Chasm compiler now emits Rust-style diagnostics to stderr instead of silently producing invalid C. Eight error codes (E001–E008) are detected during semantic analysis, collected without early abort, rendered with source snippets and caret underlines, and the compiler exits non-zero when any error is present. The parser now preserves `@attr` lifetime annotations so E008 (lifetime violation) can be enforced at compile time.

### Diagnostic infrastructure (`compiler/sema.chasm`)

- `Diagnostic` struct: `code`, `category`, `file`, `line`, `col`, `message`, `snippet`, `caret`, `help`.
- `DiagCollector` struct: pre-allocated pool of 256 diagnostics; uses `count_v :: []int` (single-element array) for mutable reference semantics across value-copy struct passing.
- `make_diag_collector`, `diag_emit`, `diag_count`, `diag_has_errors`.
- `extract_snippet(src, line)` — returns the Nth newline-delimited line from the source string (1-indexed).
- `make_caret(col, len)` — returns `(col-1)` spaces followed by `max(len,1)` `^` characters.
- `render_diagnostic(d)` — formats one diagnostic in Rust style; `render_all_diags(dc)` calls `eprint` for each.
- `levenshtein(a, b)` — iterative two-row DP edit distance.
- `closest_match(candidates, name)` — returns the candidate within edit distance ≤ 2, or `""`.

### Error codes

| Code | Category | Trigger |
|---|---|---|
| E001 | undefined variable | `:ident` not in symbol table (`sym_contains` check) |
| E002 | type mismatch | annotated type ≠ inferred type on `:var_decl` |
| E003 | wrong argument count | call arg count ≠ `params_count` for user-defined fn |
| E005 | unknown function | name not in fn registry and not in `builtin_ret`; "did you mean?" via `closest_match` |
| E006 | return type mismatch | `return` expression type ≠ declared return type |
| E007 | undefined struct field | `field_lookup` returns 0 for known struct; "did you mean?" via `closest_match` |
| E008 | lifetime violation | `@attr` assignment where RHS lifetime < attr declared lifetime |

### Lifetime violation detection (E008)

- **Parser** (`compiler/parser.chasm`): `at_decl` parsing now captures the lifetime keyword and stores it as an integer in `node.b` (1=frame, 2=script, 3=persistent) instead of discarding it.
- **Sema**: `sema_all` pre-pass builds `[]AttrInfo` from `decl.b`; threaded through `sema_fn` → `sema_block` → `sema_stmt`.
- `expr_lifetime` helper infers RHS lifetime: `@attr` refs carry their declared lifetime; `copy_to_script()` → 2; `persist_copy()` → 3; everything else → 1 (frame).
- `copy_to_script` and `persist_copy` added to `builtin_ret` (return type 1) so they don't false-positive as E005.
- E008 emitted with promotion hint: `frame → script` → `use \`copy_to_script()\``; `* → persistent` → `use \`persist_copy()\``.

### Runtime (`runtime/chasm_rt.h`)

- `chasm_eprint(ctx, s)` — writes string to stderr via `fprintf(stderr, "%s", s)`.
- `chasm_eprint_nl(ctx, s)` — same with trailing newline.
- `chasm_exit(ctx, code)` — calls `exit((int)code)` for clean non-zero exit.

### Codegen (`compiler/codegen.chasm`)

- `eprint` and `exit` dispatch branches added to `emit_call`.

### Driver (`compiler/main.chasm`)

- `make_diag_collector()` called before `sema_all`.
- `src` and `"sema_combined.chasm"` threaded into `sema_all`.
- After sema: if `diag_has_errors(dc)` → `render_all_diags(dc)` + `exit(1)`; otherwise proceed to codegen.

### Property-based tests (`cmd/cli/diag_pbt_test.go`)

New test suite using `pgregory.net/rapid` (100 iterations each):

- **P1** — diagnostic accumulation is monotonic (count = emissions, no record lost)
- **P2** — snippet extraction round-trip (extracted line equals original line text)
- **P3** — caret length matches token lexeme length
- **P4** — rendered diagnostic contains required fields (code, file, line, snippet)
- **P5** — compiler exits non-zero for source with undefined variable (integration, invokes binary)
- **P6** — K independent undefined variables produce ≥ K E001 diagnostics (no early abort)
- **P7** — `closest_match` suggestion is within edit distance 2

### Bootstrap

Bootstrap binary rebuilt and three-stage fixpoint verified (`stage2.c == stage3.c`).

## [0.8.0] — 2026-03-22 — Raylib extended bindings + multi-engine layout

### Summary

37 new Raylib 5.5 bindings across eight categories, a Shape Shooter demo game exercising them, a fix to `chasm run --engine raylib` (was incorrectly linking `main.c` into the binary instead of using the dylib path), and a reorganisation of the engine directory to support multiple future engines.

### Raylib extended bindings (`engine/raylib/`)

All four binding files updated atomically for each new function:

- **Audio extended**: `sound_playing`, `sound_volume`, `sound_pitch`, `pause_sound`, `resume_sound`, `music_playing`, `music_volume`, `music_pitch`, `music_length`, `music_played`, `pause_music`, `resume_music`
- **Window extended**: `window_resized`, `set_window_size`, `toggle_fullscreen`, `is_fullscreen`, `window_focused`
- **Drawing extended**: `draw_triangle`, `draw_triangle_lines`, `draw_ellipse`, `draw_ring`, `draw_poly`
- **Texture extended**: `draw_texture_tiled`, `set_texture_filter`
- **Camera 2D**: `camera2d_begin`, `camera2d_end`, `world_to_screen_x`, `world_to_screen_y`
- **Gamepad**: `gamepad_available`, `gamepad_button_down`, `gamepad_button_pressed`, `gamepad_axis`
- **Mouse extended**: `set_mouse_pos`, `mouse_cursor`
- **Clipboard**: `get_clipboard`, `set_clipboard`

### Property-based tests (`cmd/cli/bindings_pbt_test.go`)

New test suite using `pgregory.net/rapid`:

- **P1** — binding symbol naming convention (`rl_<name>` for all new bindings)
- **P4** — music played time invariant (`0 ≤ played ≤ length`)
- **P5** — invalid handle safety (handles `≤ 0` or `≥ 1024` return zero/false)
- **P7** — `toggle_fullscreen` idempotence (double-toggle restores original state)
- **P8** — `CHASM_TO_RL_COLOR` channel extraction (R/G/B/A bit fields)
- **P9** — `world_to_screen` identity under identity camera
- **P10** — clipboard null guard (`get_clipboard` returns `""` not NULL)

### Bug fix: `chasm run --engine raylib` (`cmd/cli/cli.go`)

`buildAndRun` was calling `buildEngineCC` which linked `main.c` (a dlopen host) directly with the script C, producing a binary that immediately tried to `dlopen /tmp/chasm_script.dylib` and failed. Fixed: raylib mode now compiles a dylib via `compileSharedLib` and passes it to the engine binary, matching the watch-mode path.

### Multi-engine directory layout

Engine files moved from `engine/` flat into `engine/raylib/` to make room for future engines:

```
engine/
  raylib/          ← all Raylib-specific files
    main.c
    loader.h
    chasm_rl.h
    chasm_rl_shim.h
    chasm_rl_exports.c
    chasm_rt.h
    raylib.chasm
    raylib-5.5_macos/
  sdl/             ← placeholder for future SDL engine
```

CLI updated: `engineDir()` now returns `engine/` (top-level), `raylibEngineDir()` returns `engine/raylib/`. All path references in `compileSharedLib`, `buildEngineOnly`, and `buildEngineCC` updated accordingly.

### Demo game (`examples/game/shape_shooter.chasm`)

Shape Shooter — top-down arena shooter exercising the new bindings:
- `draw_poly` (player pentagon), `draw_triangle` (nose), `draw_ring` (engine glow + enemies), `draw_ellipse` (bullets + enemy cores)
- `camera2d_begin/end` for smooth follow camera
- `gamepad_available`, `gamepad_axis`, `gamepad_button_pressed` for controller support
- `window_focused` to dim the player and show a pause hint

## [0.7.0] — 2026-03-21 — Hot-reload via dlopen + sentinel file

### Summary

True hot-reload for the Chasm/Raylib engine. The engine process stays alive across source edits; only the script `.dylib` is recompiled and swapped in-place each frame via `dlopen`. The window never closes during iteration.

### Engine (`engine/main.c`, `engine/loader.h`)

- `ChasmLoader` struct wraps `dlopen`/`dlsym`/`dlclose` and holds function pointers for `chasm_module_init`, `chasm_on_tick`, `chasm_on_draw`, `chasm_on_init`, `chasm_on_unload`, `chasm_reload_migrate`.
- `chasm_loader_open` / `chasm_loader_reload` / `chasm_loader_close` manage the library lifecycle.
- Failed reload (bad compile, missing symbols) leaves the old script running and prints to stderr — the window stays open.
- Main loop polls for `/tmp/chasm_reload_ready` sentinel each frame (`access` call); on detection, unlinks sentinel and calls `chasm_loader_reload`.

### Runtime (`runtime/chasm_rt.h`)

- `chasm_clear_script(ctx)` added — resets the script arena bump pointer to 0 on each reload.
- Persistent arena is never reset; `@persistent` variables survive hot-reload.

### CLI (`cmd/cli/cli.go`)

- `compileSharedLib` compiles the Chasm-generated C to a `.dylib` (macOS) or `.so` (Linux) with `-dynamiclib` / `-shared -fPIC`.
- `buildEngineOnly` compiles `engine/main.c` once to `/tmp/chasm_engine`; the engine binary is cached and not rebuilt on every source change.
- `runWatch` no longer kills and restarts the engine process. On a successful recompile it writes the sentinel file; the engine picks it up next frame.
- Compile errors print to stderr and leave the old script running.

---

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
