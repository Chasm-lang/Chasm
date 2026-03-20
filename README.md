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
chasm run <file.chasm>                          compile and run immediately
chasm run <file.chasm> --engine raylib          compile and run with Raylib game window
chasm run <file.chasm> --engine raylib --watch  live hot-reload (recompiles on save)
chasm run <file.chasm> --link libname           compile, link external library, and run
chasm compile <file.chasm>                      compile to C (produces file.c + chasm_rt.h)
chasm compile <file.chasm> --engine raylib      compile to C with Raylib header
chasm <file.chasm>                              compile to C (short form)
chasm <file.chasm> --target wasm                compile to WebAssembly Text Format (.wat + .html)
chasm compare <old.chasm> <new.chasm>           show hot-reload diff between two versions
chasm --watch <file.chasm>                      watch for changes, recompile, show reload diff
chasm --version                                 print version
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

**Multiple return values** — functions can return a tuple of values:

```chasm
defp minmax(a :: int, b :: int) :: (int, int) do
  return a, b
end

def on_tick() do
  lo, hi = minmax(3, 7)
  print(lo)   # 3
  print(hi)   # 7
end
```

The return type is written as `:: (type1, type2, ...)`. The caller destructures into separate variables with `x, y = call(...)`. The compiler generates a C struct (`ChRet_fnname`) internally — no heap allocation.

---

### Types

| Type | Description | Examples |
|---|---|---|
| `int` | 64-bit signed integer | `0`, `42`, `-7` |
| `float` | 64-bit float | `0.0`, `3.14`, `-1.5` |
| `bool` | Boolean | `true`, `false` |
| `string` | Immutable UTF-8 string | `"hello"` |
| `atom` | Compile-time symbol | `:idle`, `:running`, `:dead` |
| `[]int` / `[]float` / `[]T` | Growable typed array | `array_new(8)` |
| `strbuild` | Mutable string builder | `str_builder_new()` |
| `StructName` | User-defined struct | `Vec2 { x: 0.0, y: 0.0 }` |
| `EnumName` | Tagged enum (with optional payload) | `Color.Red` |

Types are always written after `::`:

```chasm
x :: int = 10
label :: atom = :active
name :: string = "chasm"
buf :: strbuild = str_builder_new()
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

**for / in / do / end** — iterate over a range or array

```chasm
# Range iteration
for i in 0..10 do
  print(i)
end

# Array iteration
for enemy in @enemies do
  enemy.health = enemy.health - 1
end
```

The loop variable is always `frame`-lifetime and is read-only from the outer perspective — it's a fresh binding each iteration.

**break / continue** — early exit and skip in loops

```chasm
# break exits the nearest enclosing loop
for i in 0..100 do
  if i == 42 do
    break
  end
end

# continue skips the rest of the current iteration
for i in 0..10 do
  if i == 3 do
    continue
  end
  print(i)   # prints 0, 1, 2, 4, 5, 6, 7, 8, 9
end
```

Both `break` and `continue` work in `while` and `for/in` loops. They jump to the innermost enclosing loop.

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

### Arrays

Arrays are growable, heap-backed sequences of values. They grow automatically when you push past their initial capacity.

```chasm
arr :: []int = array_new(4)   # initial cap 4, grows as needed

arr.push(10)
arr.push(20)
arr.push(30)

print(arr.len)    # 3
print(arr[1])     # 20
arr[0] = 99       # index write
```

**Method syntax** — arrays support dot-method calls:

| Method / property | Equivalent function | Description |
|---|---|---|
| `arr.len` | `array_len(arr)` | Number of elements |
| `arr.push(v)` | `array_push(arr, v)` | Append a value (grows if needed) |
| `arr.pop()` | `array_pop(arr)` | Remove and return the last value |
| `arr.clear()` | `array_clear(arr)` | Reset length to 0 (keeps capacity) |
| `arr[i]` | `array_get(arr, i)` | Read element at index |
| `arr[i] = v` | `array_set(arr, i, v)` | Write element at index |

All function-call forms still work. Arrays use `malloc`/`realloc` for growth — they are not arena-backed, so they live until the process exits (or you discard the array variable).

Array literals `[a, b, c]` desugar to `array_new` + `push` calls automatically.

**Typed arrays** — annotate the element type with `[]TypeName` to get typed index expressions:

```chasm
positions :: []float = array_new(16)
positions.push(3.14)
x :: float = positions[0]   # inferred as float

defstruct Vec2 do
  x :: float
  y :: float
end
vecs :: []Vec2 = array_new(8)   # generates typed C helpers
```

---

### Strings

Strings support dot-method syntax alongside the traditional function forms:

```chasm
s :: string = "hello world"

print(s.len)            # 11
print(s[0])             # 104  (byte value of 'h')
sub :: string = s.slice(6, 11)   # "world"
upper :: string = s.upper()
ok :: bool = s.contains("world")
```

| Method / property | Returns | Description |
|---|---|---|
| `s.len` | `int` | Byte length |
| `s[i]` | `int` | Byte value at index |
| `s.slice(from, to)` | `string` | Substring `[from, to)` |
| `s.concat(t)` | `string` | Concatenate |
| `s.repeat(n)` | `string` | Repeat `n` times |
| `s.upper()` | `string` | Uppercase copy |
| `s.lower()` | `string` | Lowercase copy |
| `s.trim()` | `string` | Strip leading/trailing whitespace |
| `s.contains(sub)` | `bool` | Substring check |
| `s.starts_with(pre)` | `bool` | Prefix check |
| `s.ends_with(suf)` | `bool` | Suffix check |
| `s.eq(t)` | `bool` | String equality |

All `str_*` function forms still work (`str_len(s)`, `str_slice(s, from, to)`, etc.).

String interpolation uses `"text #{expr} more"` — any expression is accepted inside `#{}`.

### StringBuilder

Use `StringBuilder` to build strings incrementally without intermediate allocations:

```chasm
b :: strbuild = str_builder_new()
str_builder_append(b, "hello")
str_builder_push(b, 32)          # space (byte value)
str_builder_append(b, "world")
result :: string = str_builder_build(b)   # "hello world"
print(result.len)   # 11
```

| Function | Description |
|---|---|
| `str_builder_new()` | Create a new builder (heap-allocated, grows as needed) |
| `str_builder_push(b, char)` | Append a single byte by integer value |
| `str_builder_append(b, s)` | Append a string |
| `str_builder_build(b)` | Finalize and return the string (copies to frame arena) |

### File I/O

```chasm
file_write("/tmp/save.txt", "42")
content :: string = file_read("/tmp/save.txt")
print(content)        # "42"

if file_exists("/tmp/save.txt") do
  print(1)
end
```

| Function | Returns | Description |
|---|---|---|
| `file_read(path)` | `string` | Read entire file; returns `""` on error. Buffer lives in persistent arena. |
| `file_write(path, content)` | | Write string to file (overwrites) |
| `file_exists(path)` | `bool` | Check whether file exists |

### Enums

Tag-only enums map to integer constants:

```chasm
enum State { Idle, Running, Dead }

@state :: script = State.Idle

def on_tick(dt :: float) do
  match @state {
    State.Idle    => print(0)
    State.Running => print(1)
    State.Dead    => print(2)
  }
end
```

Enums with **payload** carry data alongside the tag. Declare payload types inside parentheses after each variant name:

```chasm
enum Shape {
  Circle(float),
  Rect(float, float)
}
```

Pattern matching on payload variants binds the payload fields into the arm scope:

```chasm
case shape do
  Circle(r)    -> draw_circle(0.0, 0.0, r, 0xffffffff)
  Rect(w, h)   -> draw_rect(0.0, 0.0, w, h, 0xffffffff)
  _            -> print(0)
end
```

Payload enums compile to C tagged unions. The tag is an `int64_t`; each variant's payload is a nested struct inside a `union`.

### Structs

Structs are value types that compile directly to C structs. Field types are inferred from their annotations.

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

Create struct values with a struct literal:

```chasm
@player :: script = Player { health: 100, pos: Vec2 { x: 0.0, y: 0.0 } }
```

Read and write fields with `.`:

```chasm
def on_tick(dt :: float) do
  @player.pos.x = @player.pos.x + 5.0
  @player.health = @player.health - 1

  if @player.health <= 0 do
    @player = Player { health: 100, pos: Vec2 { x: 0.0, y: 0.0 } }
  end
end
```

Assigning to a field on a module attribute (`@player.pos.x = val`) automatically writes the modified struct back to the global — there is no separate "commit" step.

Struct fields carry type annotations. The struct's lifetime is determined by where it is allocated (the outer variable's lifetime).

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

**Arrays**

| Function / syntax | Description |
|---|---|
| `array_new(cap)` | Allocate array with initial capacity (grows automatically) |
| `arr.push(v)` / `array_push(arr, v)` | Append a value |
| `arr.pop()` / `array_pop(arr)` | Remove and return the last value |
| `arr[i]` / `array_get(arr, i)` | Read element at index |
| `arr[i] = v` / `array_set(arr, i, v)` | Write element at index |
| `arr.len` / `array_len(arr)` | Current element count |
| `arr.clear()` / `array_clear(arr)` | Reset length to 0 (keeps capacity) |

**Strings**

| Function / syntax | Returns | Description |
|---|---|---|
| `s.len` / `str_len(s)` | `int` | Byte length |
| `s[i]` / `str_char_at(s, i)` | `int` | Byte value at index |
| `s.slice(from, to)` / `str_slice(s, from, to)` | `string` | Substring |
| `s.concat(t)` / `str_concat(a, b)` | `string` | Concatenate |
| `s.repeat(n)` / `str_repeat(s, n)` | `string` | Repeat `n` times |
| `s.upper()` / `str_upper(s)` | `string` | Uppercase copy |
| `s.lower()` / `str_lower(s)` | `string` | Lowercase copy |
| `s.trim()` / `str_trim(s)` | `string` | Strip whitespace |
| `s.contains(sub)` / `str_contains(s, sub)` | `bool` | Substring check |
| `s.starts_with(p)` / `str_starts_with(s, p)` | `bool` | Prefix check |
| `s.ends_with(p)` / `str_ends_with(s, p)` | `bool` | Suffix check |
| `s.eq(t)` / `str_eq(a, b)` | `bool` | String equality |
| `int_to_str(v)` | `string` | Integer → string |
| `float_to_str(v)` | `string` | Float → string |
| `bool_to_str(v)` | `string` | Bool → `"true"` or `"false"` |
| `str_from_char(c)` | `string` | Byte value → 1-char string |

**StringBuilder**

| Function | Description |
|---|---|
| `str_builder_new()` | Create a new builder |
| `str_builder_push(b, char_int)` | Append a byte by integer value |
| `str_builder_append(b, s)` | Append a string |
| `str_builder_build(b)` | Finalize and return the string |

**File I/O**

| Function | Returns | Description |
|---|---|---|
| `file_read(path)` | `string` | Read file contents (persistent arena) |
| `file_write(path, content)` | | Overwrite file with string |
| `file_exists(path)` | `bool` | Check whether file exists |

**I/O**

| Function | Description |
|---|---|
| `print(x)` | Print a value followed by a newline |
| `log(x)` | Same as `print` (alias) |
| `assert(cond)` | Abort if `cond` is false |
| `todo()` | Mark a code path as unreachable (aborts) |

---

## Real-World Pattern: Game Update Loop

This is the pattern Chasm is designed for. A host engine calls into Chasm scripts once per frame.

```chasm
defstruct Vec2 do
  x :: float
  y :: float
end

defstruct Enemy do
  pos    :: Vec2
  health :: int
  speed  :: float
end

@player   :: script = Vec2 { x: 400.0, y: 300.0 }
@enemies  :: script = [0, 0, 0, 0, 0, 0, 0, 0]   # handles or packed data
@score    :: script = 0
@hi_score :: persistent = 0

defp move_toward(px :: float, tx :: float, spd :: float, dt :: float) :: float do
  dx :: frame = tx - px
  px + dx * spd * dt
end

def on_tick(dt :: float) do
  # Frame-lifetime — free after this tick, no GC needed
  count :: frame = 0

  for i in 0..8 do
    count = count + 1
  end

  @score = @score + count

  # Field mutation on a module attr writes back automatically
  @player.x = move_toward(@player.x, 400.0, 2.0, dt)
  @player.y = move_toward(@player.y, 300.0, 2.0, dt)
end

def on_save() do
  @hi_score = persist_copy(@score)
end
```

The host calls `chasm_on_tick(ctx, dt)` once per frame. No GC. No hidden allocations. All frame-lifetime values are gone before the next tick begins.

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

**Live hot-reload with Raylib** keeps a game window open and swaps the script without restarting:

```bash
chasm run --engine raylib --watch game.chasm
```

Chasm compiles your script to a `.dylib`, loads it via `dlopen`, and polls the source file for changes. On save it recompiles and swaps the function pointers while the window stays open. State annotated `:: script` or `:: persistent` survives the swap; `:: frame` state is always fresh.

---

## WebAssembly

Chasm can compile to [WebAssembly Text Format](https://webassembly.github.io/spec/core/text/index.html) (`.wat`), which assembles to `.wasm` with `wat2wasm`:

```bash
chasm --target wasm game.chasm
```

This produces:
- `game.wat` — the WebAssembly module in text format
- `game.html` — a ready-to-open HTML host page with Canvas2D bindings

The HTML file provides a JavaScript environment that implements the `env` imports your script uses: `print`, math functions, and Canvas2D drawing primitives (`clear`, `draw_circle`, `draw_rect`, `draw_line`, `draw_text`). Open `game.html` in a browser with no server required.

To assemble and run headlessly:

```bash
wat2wasm game.wat -o game.wasm
node -e "const fs=require('fs'); WebAssembly.instantiate(fs.readFileSync('game.wasm'), {env:{print:console.log}}).then(m=>m.instance.exports.main())"
```

---

## How Compilation Works

Chasm compiles directly to C99. When you run `chasm game.chasm` you get:

- `game.c` — the compiled module
- `chasm_rt.h` — the runtime header: arenas, growable arrays, string builder, file I/O, math, and all standard library functions

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
- Signature help — parameter hints pop up as you type a function call (triggered by `(` and `,`)
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
    codegen_wasm.zig        — IR → WebAssembly Text Format emitter
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
