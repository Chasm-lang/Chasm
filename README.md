# Chasm

A scripting language for real-time games. Chasm compiles to C99, runs at native speed, and replaces garbage collection with a deterministic three-lifetime memory model that makes every allocation cost visible in the source code.

---

## Why Chasm

Game scripts run on a tight loop — potentially thousands of times per second. Every invisible allocation, every GC pause, every hidden copy is a frame drop. Languages like Lua and Python hide these costs. Chasm does not.

In Chasm, **memory lifetime is part of the syntax**. When you write `copy_to_script(x)` you are paying an explicit cost — promoting a short-lived value into a longer-lived arena. When you don't write it, nothing allocates. The compiler enforces this. You cannot accidentally assign a `frame`-lifetime value into a `script` variable without the promotion being visible in the source.

The result is a language that reads like a scripting language but performs like handwritten C.

---

## Installation

You need [Zig](https://ziglang.org) (0.15+) installed.

```bash
git clone <repo>
cd chasm
./install.sh            # installs to ~/.local/bin
./install.sh /usr/local # installs system-wide
```

This builds release-optimized binaries and installs:
- `chasm` — the compiler and runner
- `chasm-lsp` — the language server (for editor support)

The install script also copies the Cursor/VS Code extension into your editors automatically.

---

## Quick Start

Create `hello.chasm`:

```chasm
@score :: script = 0

def tick() do
  @score = copy_to_script(@score + 1)
  print(@score)
end
```

Run it:

```bash
chasm run hello.chasm
```

---

## Raylib Game Engine

Chasm has first-class support for [Raylib 5.5](https://www.raylib.com). The `--engine raylib` flag compiles your script against Raylib and opens a game window automatically — no boilerplate required.

```bash
chasm run --engine raylib game.chasm
```

The engine injects all Raylib bindings as built-in functions. Your script just defines the hooks it needs:

```chasm
@x  :: script = 400.0
@y  :: script = 300.0
@vx :: script = 200.0
@vy :: script = 150.0

def on_tick(dt :: float) do
  @x = @x + @vx * dt
  @y = @y + @vy * dt

  if @x < 0.0 do  @vx = abs(@vx)  end
  if @x > 800.0 do  @vx = 0.0 - abs(@vx)  end
  if @y < 0.0 do  @vy = abs(@vy)  end
  if @y > 600.0 do  @vy = 0.0 - abs(@vy)  end
end

def on_draw() do
  clear(0x181820ff)
  draw_circle(@x, @y, 24.0, 0xff4455ff)
  draw_text("Chasm + Raylib", 12.0, 12.0, 20, 0xffffffff)
  draw_fps(12.0, 580.0)
end
```

### Game Loop Hooks

The engine calls these functions automatically each frame. Define only the ones you need:

| Hook | Signature | Called |
|------|-----------|--------|
| `on_init` | `def on_init() do` | Once after the window opens |
| `on_tick` | `def on_tick(dt :: float) do` | Every frame, before drawing |
| `on_draw` | `def on_draw() do` | Every frame, inside Begin/EndDrawing |
| `on_unload` | `def on_unload() do` | Once before the window closes |

### Built-in Raylib Functions

All functions below are available without any import or declaration when using `--engine raylib`. Colors are packed `int` values in `0xRRGGBBAA` format. Textures, fonts, sounds, and music are opaque `int` handles returned by `load_*` functions.

**Drawing**

| Function | Description |
|----------|-------------|
| `clear(color)` | Clear the background |
| `draw_rect(x, y, w, h, color)` | Filled rectangle |
| `draw_rect_lines(x, y, w, h, color)` | Rectangle outline |
| `draw_rect_rounded(x, y, w, h, r, seg, color)` | Rounded rectangle |
| `draw_circle(x, y, r, color)` | Filled circle |
| `draw_circle_lines(x, y, r, color)` | Circle outline |
| `draw_line(x1, y1, x2, y2, color)` | Line |
| `draw_line_ex(x1, y1, x2, y2, thick, color)` | Line with thickness |
| `draw_text(text, x, y, size, color)` | Text with default font |
| `draw_text_ex(font, text, x, y, size, spacing, color)` | Text with custom font |
| `measure_text(text, size)` | Text width in pixels |
| `draw_fps(x, y)` | FPS counter |

**Texture**

| Function | Description |
|----------|-------------|
| `load_texture(path)` | Load texture, returns handle |
| `unload_texture(handle)` | Free texture |
| `draw_texture(handle, x, y, tint)` | Draw texture |
| `draw_texture_ex(handle, x, y, rot, scale, tint)` | Draw with rotation/scale |
| `draw_texture_rect(handle, sx, sy, sw, sh, dx, dy, tint)` | Draw sub-region |
| `texture_w(handle)` | Texture width |
| `texture_h(handle)` | Texture height |

**Font & Audio**

| Function | Description |
|----------|-------------|
| `load_font(path)` | Load font, returns handle |
| `init_audio()` | Initialize audio device |
| `load_sound(path)` | Load sound, returns handle |
| `play_sound(handle)` | Play sound |
| `stop_sound(handle)` | Stop sound |
| `load_music(path)` | Load music stream, returns handle |
| `play_music(handle)` | Start music |
| `update_music(handle)` | Stream next chunk (call each frame) |
| `stop_music(handle)` | Stop music |

**Keyboard**

Key codes: `A`=65..`Z`=90, `0`=48..`9`=57, `SPACE`=32, `ESCAPE`=256, `ENTER`=257, `RIGHT`=262, `LEFT`=263, `DOWN`=264, `UP`=265, `LEFT_SHIFT`=340, `LEFT_CTRL`=341

| Function | Description |
|----------|-------------|
| `key_down(key)` | True while key is held |
| `key_pressed(key)` | True on the frame the key is first pressed |
| `key_released(key)` | True on the frame the key is released |
| `key_up(key)` | True while key is not held |
| `key_last()` | Key code of the last key pressed |

**Mouse**

Mouse buttons: `LEFT`=0, `RIGHT`=1, `MIDDLE`=2

| Function | Description |
|----------|-------------|
| `mouse_x()` | Cursor X position |
| `mouse_y()` | Cursor Y position |
| `mouse_dx()` | Cursor delta X this frame |
| `mouse_dy()` | Cursor delta Y this frame |
| `mouse_down(btn)` | True while button is held |
| `mouse_pressed(btn)` | True on the frame the button is first pressed |
| `mouse_released(btn)` | True on the frame the button is released |
| `mouse_wheel()` | Scroll wheel delta |
| `hide_cursor()` | Hide the cursor |
| `show_cursor()` | Show the cursor |

**Window & System**

| Function | Description |
|----------|-------------|
| `screen_w()` | Window width in pixels |
| `screen_h()` | Window height in pixels |
| `set_fps(fps)` | Set target frame rate |
| `set_title(title)` | Set window title |
| `fps()` | Current frames per second |
| `dt()` | Frame delta time in seconds |
| `time()` | Total elapsed time in seconds |

**Collision**

| Function | Description |
|----------|-------------|
| `collide_rects(x1, y1, w1, h1, x2, y2, w2, h2)` | Rectangle vs rectangle |
| `collide_circles(x1, y1, r1, x2, y2, r2)` | Circle vs circle |
| `point_in_rect(px, py, rx, ry, rw, rh)` | Point inside rectangle |

### Raylib Prerequisites

Chasm ships with a pre-built Raylib 5.5 static library for macOS at `engine/raylib-5.5_macos/`. On macOS no extra installation is needed. The compiler links it automatically.

---

## CLI Reference

```
chasm run <file.chasm>                        compile and run immediately
chasm run <file.chasm> --engine raylib        compile and run with Raylib game window
chasm run <file.chasm> --link libname         compile, link external library, and run
chasm compile <file.chasm>                    compile to C (produces file.c + chasm_rt.h)
chasm <file.chasm>                            compile to C (short form)
chasm compare <old.chasm> <new.chasm>         show hot-reload diff between two versions
chasm --watch <file.chasm>                    watch for changes, recompile, show reload diff
chasm --version                               print version
```

---

## The Three-Lifetime Model

This is the core idea of Chasm. Every value has a **lifetime** — a region of memory that determines how long it lives.

```
Frame  <  Script  <  Persistent
```

| Lifetime | Cleared when | Annotated as |
|---|---|---|
| `frame` | Every tick (every call to your update function) | `:: frame` |
| `script` | On hot-reload, or when you explicitly reset | `:: script` |
| `persistent` | Never (until the process exits) | `:: persistent` |

Values can only flow **upward** — from shorter to longer lifetimes. Flowing downward is a compile error. Promoting a value costs an explicit function call that is visible in the source.

### Promotion functions

```chasm
copy_to_script(x)   # copies x from frame → script
persist_copy(x)     # copies x from frame or script → persistent
```

These are not magic — they map directly to memory copies in the generated C. You see them in the code, so you know when they happen.

### Why this matters

```chasm
def on_tick(dt :: float) do
  delta :: frame = dt * 9.8              # free — lives in frame arena, gone next tick
  saved :: script = copy_to_script(delta) # explicit copy — you paid for this
  @score = saved
end
```

If you forget `copy_to_script`, the compiler tells you. You cannot silently allocate into a longer-lived region.

---

## Language Reference

### Module Attributes

Module attributes are shared state declared at the top of a file. They use the `@` prefix and must carry an explicit lifetime annotation.

```chasm
@score      :: script     = 0
@high_score :: persistent = 0
@frame_temp :: frame      = 0.0
```

Attributes are the only global state in Chasm. Everything else is local to a function.

Inside functions, read and write attributes with the same `@name` syntax:

```chasm
def update() do
  @score = copy_to_script(@score + 10)
end
```

---

### Functions

**Public function** — callable from the host engine:

```chasm
def on_tick(dt :: float) do
  # body
end
```

**Private function** — callable only within this module:

```chasm
defp compute(x :: int) :: int do
  x * 2
end
```

The return type annotation (`:: int`) is optional. If omitted, the compiler infers it.

Function parameters always have explicit type annotations. The return lifetime is always inferred — it is at least as long as the longest-lived input.

---

### Types

| Type | Description | Examples |
|---|---|---|
| `int` | 64-bit signed integer | `0`, `42`, `-7` |
| `float` | 64-bit float | `0.0`, `3.14`, `-1.5` |
| `bool` | Boolean | `true`, `false` |
| `str` | Immutable string | `"hello"` |
| `atom` | Compile-time symbol | `:idle`, `:running`, `:dead` |

Types are always written after `::`:

```chasm
x :: int = 10
label :: atom = :active
name :: str = "chasm"
```

---

### Variables

Variables are declared with `::` followed by an optional lifetime annotation and type:

```chasm
x :: frame = 42         # explicit frame lifetime
y :: script = 0.0       # explicit script lifetime
z = compute()           # lifetime inferred from right-hand side
```

If you omit the lifetime, Chasm infers it from the value being assigned. If the value is a function call that returns a `script`-lifetime result, the variable becomes `script`. If it's a literal or a `frame` computation, it becomes `frame`.

---

### Operators

```chasm
# Arithmetic
x + y    x - y    x * y    x / y

# Comparison
x == y   x != y   x < y    x > y    x <= y    x >= y

# Boolean
x and y   x or y   not x

# Pipe — passes left side as first argument to right side
x |> scale(2.0) |> clamp(0.0, 100.0)
# equivalent to: clamp(scale(x, 2.0), 0.0, 100.0)
```

---

### Control Flow

**if / else / end**

```chasm
if x > 10 do
  print(x)
else
  print(0)
end
```

`else` is optional. The result of an `if` expression is the last value in the taken branch.

**while / end**

```chasm
i :: frame = 0
while i < 10 do
  i = i + 1
end
```

**case / when / end** — pattern matching on atoms

```chasm
def describe(status :: atom) do
  case status do
    when :idle    -> "standing by"
    when :running -> "in motion"
    when :dead    -> "game over"
    _             -> "unknown"
  end
end
```

The `_` arm is the catch-all. Chasm matches arms top to bottom and takes the first match.

---

### Structs

```chasm
defstruct Vec2 do
  x :: float
  y :: float
end

defstruct Player do
  health :: int
  pos    :: Vec2
end
```

Struct fields carry type annotations. The struct's lifetime is determined by where it is allocated.

---

### Pipe Operator

The pipe operator `|>` passes the value on the left as the first argument to the function on the right:

```chasm
# Without pipe
result = clamp(scale(delta, 2.0), 0.0, 100.0)

# With pipe — reads left to right
result = delta |> scale(2.0) |> clamp(0.0, 100.0)
```

---

### Extern Functions

Chasm can call C functions directly using `extern fn`. The optional `= "c_name"` alias lets you give the function a cleaner Chasm name while mapping to any C symbol:

```chasm
extern fn draw_circle(x: float, y: float, r: float, color: int) -> void = "rl_draw_circle"
extern fn key_down(key: int) -> bool = "rl_is_key_down"
```

When using `--engine raylib`, all Raylib bindings are injected automatically — you never write `extern fn` for them manually.

---

### Imports

A Chasm file can import another Chasm file. All public functions and extern declarations from the imported file become available:

```chasm
import "math_utils"

def on_tick(dt :: float) do
  @x = lerp(@x, target_x, dt * 10.0)
end
```

---

### Built-in Functions

**Lifetime promotion**

| Function | Effect |
|---|---|
| `copy_to_script(x)` | Copies `x` into the script arena. Returns same type as `x`. |
| `persist_copy(x)` | Copies `x` into the persistent arena. Returns same type as `x`. |

**Math**

| Function | Returns | Description |
|---|---|---|
| `abs(v)` | `float` | Absolute value |
| `sqrt(v)` | `float` | Square root |
| `sin(v)` | `float` | Sine (radians) |
| `cos(v)` | `float` | Cosine (radians) |
| `tan(v)` | `float` | Tangent (radians) |
| `atan2(y, x)` | `float` | Arctangent |
| `floor(v)` | `float` | Round down |
| `ceil(v)` | `float` | Round up |
| `round(v)` | `float` | Round to nearest |
| `min(a, b)` | `float` | Minimum |
| `max(a, b)` | `float` | Maximum |
| `clamp(v, lo, hi)` | `float` | Clamp between lo and hi |
| `scale(v, factor)` | `float` | Multiply v by factor |
| `lerp(a, b, t)` | `float` | Linear interpolation |
| `deg_to_rad(d)` | `float` | Degrees to radians |
| `rad_to_deg(r)` | `float` | Radians to degrees |

**I/O**

| Function | Description |
|---|---|
| `print(x)` | Print a value followed by a newline |
| `log(x)` | Same as `print` (alias) |

---

## Real-World Pattern: Game Update Loop

This is the pattern Chasm is designed for. A host engine calls into Chasm scripts once per frame.

```chasm
@position_x :: script = 0.0
@position_y :: script = 0.0
@velocity_x :: script = 1.0
@velocity_y :: script = 0.0
@high_score :: persistent = 0

defp move(x :: float, vx :: float, dt :: float) :: float do
  x + vx * dt
end

def on_tick(dt :: float) do
  # All intermediate values are frame-lifetime — free after this call
  new_x :: frame = move(@position_x, @velocity_x, dt)
  new_y :: frame = move(@position_y, @velocity_y, dt)

  # Explicit promotions — you see exactly what crosses into script memory
  @position_x = copy_to_script(new_x)
  @position_y = copy_to_script(new_y)
end

def on_save() do
  # Persist the score once at save time — one explicit cost, paid once
  @high_score = persist_copy(@score)
end
```

The host calls `chasm_on_tick(ctx, dt)` once per frame. No GC. No hidden allocations. `new_x` and `new_y` live in the frame arena and are gone before the next frame begins.

---

## Hot-Reload

Chasm has first-class hot-reload support. The compiler analyzes two versions of a module and tells you exactly what state survives the swap.

```bash
chasm compare v1.chasm v2.chasm
```

Output:

```
Reload analysis: v1.chasm → v2.chasm

  @score          :: script      ✓  preserved
  @high_score     :: persistent  ✓  preserved
  @new_counter    :: script      +  new — initialized fresh

Safe to hot-reload: yes  (2 preserved, 1 added)
```

A reload is **safe** if every `script` and `persistent` attribute in the new version is either preserved (same name, type, and lifetime) or newly added. If a type or lifetime changes, the attribute is marked `lost` and the reload is flagged unsafe — Chasm won't silently corrupt your game state.

Watch mode does this automatically on every save:

```bash
chasm --watch game.chasm
```

---

## How Compilation Works

Chasm compiles directly to C99. When you run `chasm game.chasm` you get:

- `game.c` — the compiled module
- `chasm_rt.h` — a small runtime header (~50 lines) with the arena types and helper macros

The generated C is readable and embeds `ChasmCtx*` in every function signature so the host engine controls all memory. There are no global allocators, no hidden threads, no runtime dependencies beyond `libc`.

To integrate into a C/C++ project:

```c
#include "chasm_rt.h"
#include "game.c"   // or compile separately and link

int main(void) {
    uint8_t frame_buf[64*1024];
    uint8_t script_buf[256*1024];
    uint8_t persist_buf[1024*1024];

    ChasmCtx ctx = {
        .frame      = {frame_buf,   0, sizeof(frame_buf)},
        .script     = {script_buf,  0, sizeof(script_buf)},
        .persistent = {persist_buf, 0, sizeof(persist_buf)},
    };

    chasm_module_init(&ctx);

    float dt = 0.016f; // 60fps
    while (game_running) {
        chasm_on_tick(&ctx, dt);
        chasm_clear_frame(&ctx);  // free all frame memory at end of tick
    }

    chasm_on_save(&ctx);
}
```

---

## Editor Support

The `install.sh` script automatically installs the Chasm extension into Cursor and VS Code. Restart your editor after running it.

Features:
- Syntax highlighting for `.chasm` files
- Error diagnostics (red underlines on parse/type errors) via `chasm-lsp`
- Hover to see inferred lifetime and type of any variable or attribute
- Auto-indent for `do`/`end` blocks

The language server (`chasm-lsp`) runs the full compiler pipeline on every keystroke and reports errors in real time. It speaks LSP over stdio so it works with any editor that supports LSP.

---

## Design Philosophy

**Allocation is always visible.** You cannot write a Chasm program that allocates into a long-lived arena without a function call (`copy_to_script` or `persist_copy`) appearing in the source. This makes it impossible to accidentally create GC pressure or frame-rate spikes from allocation.

**The type system enforces the lifetime hierarchy.** You cannot assign a `frame` value to a `script` variable. The compiler will tell you. This catches a whole class of bugs — dangling references to arena memory that has been cleared — at compile time.

**No runtime, no GC, no VM.** The output is plain C99 with no hidden runtime. You can read it, debug it, and profile it with standard tools. `chasm_rt.h` is the entire runtime — it is intentionally small.

**Explicit over implicit.** Chasm deliberately avoids magic. Lifetime promotion is visible. Type annotations are required on function parameters and module attributes. The pipe operator rewrites to normal function calls with no special semantics.

**Designed for embedding.** Chasm does not try to be a general-purpose language. It is designed to be embedded in game engines the same way Lua is, but without the GC overhead and with a memory model that integrates naturally with arena-allocating host engines.

---

## Project Structure

```
src/
  main.zig                  — CLI: compile, run, watch, compare
  compiler/
    lexer.zig               — tokenizer
    token.zig               — token types
    parser.zig              — recursive descent parser → AST
    ast.zig                 — AST node pool (flat, index-based)
    sema.zig                — type inference + lifetime constraint solver
    lifetime.zig            — lifetime analysis helpers
    ir.zig                  — three-address IR definition
    lower.zig               — AST → IR lowering pass
    codegen.zig             — IR → C99 code generator
    reload.zig              — hot-reload diff engine
    diag.zig                — diagnostics + error rendering
  runtime/
    arena.zig               — ArenaTriple + Lifetime enum
  lsp/
    main.zig                — LSP server entry point
    server.zig              — LSP request handlers
    jsonrpc.zig             — JSON-RPC 2.0 framing
engine/
  raylib-5.5_macos/         — pre-built Raylib 5.5 for macOS (include/ + lib/)
  chasm_rl.h                — Raylib adapter (color packing, handle table, wrappers)
  raylib.chasm              — canonical extern fn declarations for reference
  example.chasm             — bouncing ball demo
  main.c                    — standalone host loop for manual builds
editors/
  vscode/                   — Cursor / VS Code extension
    syntaxes/chasm.tmLanguage.json
    src/extension.ts        — LSP client
test/
  scripts/                  — example .chasm files
```
