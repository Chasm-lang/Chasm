# Chasm Language Specification

This document is the authoritative reference for the Chasm language. It covers syntax, types, operators, keywords, lifetime rules, and built-in functions.

---

## Keywords

| Keyword | Role |
|---|---|
| `def` | Declare a public function |
| `defp` | Declare a private function |
| `defstruct` | Declare a struct type |
| `enum` | Declare an enum type |
| `extern fn` | Declare a C function binding |
| `import` | Import another Chasm file |
| `do` | Begin a block (after `def`, `if`, `while`, `for`, `case`) |
| `end` | Close a block |
| `if` | Conditional branch |
| `else` | Alternate branch |
| `while` | Conditional loop |
| `for` / `in` | Range or array iteration |
| `break` | Exit the nearest enclosing loop |
| `continue` | Skip to the next iteration of the nearest enclosing loop |
| `return` | Return a value from a function |
| `case` | Pattern match on a value |
| `when` | Match arm inside `case` |
| `true` / `false` | Boolean literals |
| `and` / `or` / `not` | Boolean operators |

---

## Lifetimes

Every value has a **lifetime** — a region of memory that determines how long it lives.

```
Frame  <  Script  <  Persistent
```

| Lifetime | Cleared when | Annotated as |
|---|---|---|
| `frame` | Every tick (every call to your update function) | `:: frame` |
| `script` | On hot-reload, or when you explicitly reset | `:: script` |
| `persistent` | Never (until the process exits) | `:: persistent` |

Values can only flow **upward** — from shorter to longer lifetimes. Assigning a `frame`-lifetime value to a `script` variable is a compile error unless you use an explicit promotion function.

### Lifetime inference

The compiler infers the lifetime of every expression:

| Expression form | Inferred lifetime |
|---|---|
| `@attr` reference | The attr's declared lifetime |
| Literal (`0`, `0.0`, `true`, `:atom`) | Persistent — assignable anywhere |
| Local variable | Frame |
| `f(a, b, ...)` call | Max lifetime of all arguments |
| `recv.method(a, ...)` call | Max lifetime of receiver + arguments |
| `a + b`, `a * b`, etc. | Max lifetime of both operands |
| `copy_to_script(x)` | Script |
| `persist_copy(x)` | Persistent |

This means expressions that involve `@script` attrs automatically carry script lifetime, so assigning them back to a `@script` attr is fine without promotion. Only when a frame-local value (e.g. a computed delta from `dt`) flows into a longer-lived attr does the compiler require an explicit promotion call.

### Promotion Functions

| Function | Effect |
|---|---|
| `copy_to_script(x)` | Copies `x` into the script arena. Returns same type as `x`. |
| `persist_copy(x)` | Copies `x` into the persistent arena. Returns same type as `x`. |

---

## Types

| Type | Description | Examples |
|---|---|---|
| `int` | 64-bit signed integer | `0`, `42`, `-7`, `0xff` |
| `float` | 64-bit IEEE 754 float | `0.0`, `3.14`, `-1.5` |
| `bool` | Boolean | `true`, `false` |
| `string` | Immutable UTF-8 byte string | `"hello"` |
| `atom` | Compile-time symbol (maps to string constant) | `:idle`, `:running` |
| `[]T` | Array of element type `T` | `array_new(8)`, `array_new(Bullet, 8)`, `array_fixed(8)`, `array_fixed(8, 0.0)` |
| `strbuild` | Mutable string builder | `str_builder_new()` |
| `StructName` | User-defined struct (value type) | `Vec2 { x: 0.0, y: 0.0 }` |
| `EnumName` | Tagged enum (with optional payload) | `State.Idle` |

Integer literals can be written in decimal or hexadecimal (`0x` prefix):

```chasm
x   :: int = 255
hex :: int = 0xff          # same value
color :: int = 0x181820ff  # RGBA packed color
```

Type annotations use `::`:

```chasm
x :: int = 10
label :: atom = :active
name :: string = "chasm"
positions :: []float = array_new(16)
```

---

## Operators

### Arithmetic

```chasm
x + y    # addition
x - y    # subtraction
x * y    # multiplication
x / y    # division
```

### Comparison

```chasm
x == y   # equal
x != y   # not equal
x < y    # less than
x > y    # greater than
x <= y   # less than or equal
x >= y   # greater than or equal
```

### Boolean

```chasm
x and y  # logical and
x or y   # logical or
not x    # logical not
```

### Pipe

The pipe operator `|>` passes the value on the left as the first argument to the function on the right:

```chasm
result = delta |> scale(2.0) |> clamp(0.0, 100.0)
# equivalent to: clamp(scale(delta, 2.0), 0.0, 100.0)
```

### String Interpolation

Strings support inline expression interpolation with `#{}`:

```chasm
msg :: string = "score: #{@score}"
```

---

## Declarations

### Module Attributes

Module attributes (`@name`) are module-level variables declared at file scope. They use the `@` prefix and persist across function calls for the duration of their lifetime. Unlike local variables they survive between ticks and are initialized once before the script runs.

#### Declaration syntax

```
@name :: lifetime = expr
```

- `@name` — the attribute name. The leading `@` is part of the name everywhere it appears.
- `:: lifetime` — one of `frame`, `script`, or `persistent`.
- `= expr` — initializer evaluated at module init time.

```chasm
@score      :: script     = 0
@high_score :: persistent = 0
@speed      :: script     = 400.0
@bg_color   :: script     = 0x181820ff
```

#### Reading an attribute

Use `@name` anywhere an expression is valid:

```chasm
def on_tick(dt :: float) do
  new_x = player_x + @speed * dt
  draw_text("score: #{@score}", 10, 10, 20, 0xffffffff)
end
```

#### Assigning an attribute

Assign to `@name` inside a function body with a plain `=`:

```chasm
def on_hit() do
  @score = @score + 100
  if @score > @high_score do
    @high_score = @score
  end
end
```

Attribute assignment is a statement, not an expression. It cannot appear on the right-hand side of another assignment.

#### Lifetime rules

`@attr` lifetimes follow the same hierarchy as local variables:

| Lifetime | Lives until |
|---|---|
| `:: frame` | End of the current tick (reset by the engine before each call) |
| `:: script` | Hot-reload or explicit reset |
| `:: persistent` | Process exit |

An `@frame` attribute is re-initialized on every tick. An `@script` attribute survives across ticks but is reset on hot-reload. An `@persistent` attribute is never reset.

You cannot assign a shorter-lived value to a longer-lived attribute without explicit promotion:

```chasm
@saved :: persistent = persist_copy(computed_value)
```

#### Common patterns

```chasm
# Counter that survives frames
@ticks :: script = 0

def on_tick(dt :: float) do
  @ticks = @ticks + 1
end

# High score that survives reload
@best :: persistent = 0

def record(score :: int) do
  if score > @best do
    @best = persist_copy(score)
  end
end

# Preloaded resource handle
@font :: script = 0

def init() do
  @font = load_font("assets/mono.ttf")
end

# Fixed-capacity arena-backed array (no heap, lifetime-safe)
# Float array — all slots pre-filled, no push loop needed
@positions :: script = array_fixed(8, 0.0)

def on_tick(dt :: float) do
  @positions.set(0, @player_x)   # direct float — no to_int/to_float casting
end
```

### Functions

```chasm
# Public function (callable from host)
def on_tick(dt :: float) do
  # body
end

# Private function (callable within this module only)
defp compute(x :: int) :: int do
  x * 2
end
```

The return type annotation (`:: type`) is optional for public functions and required for private ones when the return type cannot be inferred. Function parameters always have explicit type annotations.

**Multiple return values:**

```chasm
defp minmax(a :: int, b :: int) :: (int, int) do
  return a, b
end

lo, hi = minmax(3, 7)
```

### Structs

```chasm
defstruct Vec2 do
  x :: float
  y :: float
end

v :: Vec2 = Vec2 { x: 1.0, y: 2.0 }
```

Fields may include default values, which are used when array slots are pre-filled via `array_fixed`:

```chasm
defstruct Bullet do
  x      :: float = 0.0
  y      :: float = 0.0
  active :: int   = 0
end
```

Structs are value types — copied on assignment, no heap allocation.

**Struct update** — copy a struct with specific fields overridden using `with`:

```chasm
# Only override the fields that changed; all others are copied from the base
@enemies.set(i, e with { x: e.x + dx_step, y: e.y + dy_step })
```

The expression `base with { field: new_val, ... }` is equivalent to writing a full struct literal with every unchanged field copied from `base`. The struct type is inferred from `base`.

### Enums

Tag-only enums:

```chasm
enum State { Idle, Running, Dead }
```

Enums with payload:

```chasm
enum Shape {
  Circle(float),
  Rect(float, float)
}
```

Payload enums compile to C tagged unions.

### Extern Functions

```chasm
extern fn draw_circle(x: float, y: float, r: float, color: int) -> void = "rl_draw_circle"
```

The `= "c_name"` alias is optional. Without it, the Chasm name is used as the C symbol.

---

## Variables

```chasm
x :: frame = 42         # explicit frame lifetime
y :: script = 0.0       # explicit script lifetime
z = compute()           # lifetime inferred from right-hand side
```

If the lifetime is omitted, Chasm infers it from the assigned value.

---

## Control Flow

### if / else / end

```chasm
if x > 10 do
  print(x)
else
  print(0)
end
```

### while / end

```chasm
i = 0
while i < 10 do
  i = i + 1
end
```

### for / in / do / end

```chasm
# Range iteration (exclusive upper bound)
for i in 0..10 do
  print(i)
end

# Array iteration
for enemy in @enemies do
  enemy.health = enemy.health - 1
end
```

### break / continue

```chasm
for i in 0..100 do
  if i == 42 do
    break
  end
end

for i in 0..10 do
  if i == 3 do
    continue
  end
  print(i)
end
```

Both work in `while` and `for/in` loops, targeting the innermost enclosing loop.

### case / when / end

```chasm
case status do
  when :idle    -> "standing by"
  when :running -> "in motion"
  _             -> "unknown"
end
```

Arms are matched top to bottom. `_` is the catch-all.

---

## Arrays

Arrays come in two flavors depending on where they live.

### `array_new(N)` — heap-backed, growable (primitives)

For local variables and function-scoped data. Grows automatically as elements are pushed.

```chasm
arr :: []int = array_new(4)
arr.push(10)
arr.push(20)
x = arr.get(1)   # 20
arr.set(0, 99)
n = arr.len      # 2
c = arr.cap      # allocated capacity
arr.clear()
```

### `array_new(Type, N)` — heap-backed, growable (structs)

Pass a struct type name as the first argument to create a typed heap array. `.push`, `.get`, and `.set` operate on the struct type directly — no casting needed.

```chasm
defstruct Bullet do
  x     :: float
  y     :: float
  speed :: float
end

bullets = array_new(Bullet, 64)
bullets.push(Bullet{ x: 0.0, y: 0.0, speed: 5.0 })
b :: Bullet = bullets.get(0)
bullets.set(0, b with { x: b.x + b.speed })
```

Use `array_new(Type, cap)` for local struct collections where the maximum size is not known upfront. Use `array_fixed` for module-level struct arrays.

### `array_fixed(N)` — arena-backed, fixed capacity

For module attributes (`@name`). Allocates from the arena that matches the attribute's declared lifetime. The capacity is fixed at declaration time; pushing beyond it aborts with an error.

```chasm
@bullets :: script     = array_fixed(8)       # int array, seeded via push
@sparks  :: frame      = array_fixed(32)      # wiped every tick — zero per-element cost
@records :: persistent = array_fixed(4)       # never reset
```

**Typed arrays with a default value** — pass a second argument to `array_fixed` to declare the element type and pre-fill all slots at init time. The type is inferred from the default literal: an integer default gives `[]int`, a float default gives `[]float`, and a struct literal default gives `[]StructName`.

```chasm
@bullet_x :: script = array_fixed(4, 0.0)   # []float, all slots initialised to 0.0
@bullet_y :: script = array_fixed(4, 0.0)   # []float
@active   :: script = array_fixed(4, 0)     # []int,   all slots initialised to 0
```

With a default, `on_init` needs no push loop — all slots are ready immediately. `get`/`set` on a float array return and accept `float` directly, with no `to_float`/`to_int` casting required.

**Struct arrays** — pass a struct literal as the default to create a fixed array of structs. All slots are pre-filled with the given default value. `get` returns the struct by value; `set` writes a new struct literal into a slot.

```chasm
defstruct Bullet do
  x      :: float
  y      :: float
  vel_x  :: float
  vel_y  :: float
  active :: int
end

@bullets :: script = array_fixed(8, Bullet{ x: 0.0, y: 0.0, vel_x: 0.0, vel_y: 0.0, active: 0 })

def on_tick(dt :: float) do
  b :: frame = @bullets.get(0)        # returns Bullet by value
  @bullets.set(0, Bullet{ x: b.x + b.vel_x * dt, y: b.y + b.vel_y * dt,
                           vel_x: b.vel_x, vel_y: b.vel_y, active: b.active })
end
```

On hot-reload the script arena resets and the array is re-initialised automatically — no manual cleanup needed.

Use `array_fixed` for any module-level array where the maximum size is known upfront. Use `array_new` for local scratch arrays inside functions.

### Methods (both kinds)

| Method | Description |
|---|---|
| `arr.len` | Number of elements currently stored |
| `arr.cap` | Allocated capacity — how many elements fit before the array must grow (`array_new`) or abort (`array_fixed`) |
| `arr.push(v)` | Append a value (`array_fixed` aborts on overflow) |
| `arr.get(i)` | Read element at index |
| `arr.set(i, v)` | Write element at index |
| `arr.pop()` | Remove and return last value |
| `arr.clear()` | Reset length to 0 (capacity unchanged) |

### Lifetime enforcement for arrays

The compiler enforces the same lifetime rules for arrays as for scalars. Assigning a `frame`-lifetime value to a `script` array attribute is a compile error:

```chasm
@positions :: script = array_fixed(8)

def on_tick(dt :: float) do
  local_val :: frame = compute()
  @positions.set(0, local_val)   # OK — set() is a statement, not an assignment to @attr
  @positions = something_frame   # ERROR E008: lifetime violation
end
```

The `expr_lifetime` rules for arrays:
- A call result carries the **max lifetime of its arguments** — so `clamp(@player_x + delta, ...)` is script-lifetime because `@player_x` is script.
- A method call result carries the **max lifetime of the receiver and all arguments**.
- Literals (`0`, `0.0`, `true`, `:atom`) are persistent-lifetime — assignable anywhere without promotion.

---

## Strings

```chasm
s = "hello world"
n = s.len           # 11
b = s[0]            # 104  (byte value of 'h')
sub = s.slice(6, 11)  # "world"
```

| Method / syntax | Returns | Description |
|---|---|---|
| `s.len` / `str_len(s)` | `int` | Byte length |
| `s[i]` / `str_char_at(s, i)` | `int` | Byte value at index |
| `s.slice(from, to)` / `str_slice(s, from, to)` | `string` | Substring `[from, to)` |
| `s.concat(t)` / `str_concat(a, b)` | `string` | Concatenate |
| `s.repeat(n)` / `str_repeat(s, n)` | `string` | Repeat `n` times |
| `s.upper()` / `str_upper(s)` | `string` | Uppercase copy |
| `s.lower()` / `str_lower(s)` | `string` | Lowercase copy |
| `s.trim()` / `str_trim(s)` | `string` | Strip whitespace |
| `s.contains(sub)` / `str_contains(s, sub)` | `bool` | Substring check |
| `s.starts_with(p)` / `str_starts_with(s, p)` | `bool` | Prefix check |
| `s.ends_with(p)` / `str_ends_with(s, p)` | `bool` | Suffix check |
| `s.eq(t)` / `str_eq(a, b)` | `bool` | String equality |

---

## Built-in Functions

### Math

| Function | Returns | Description |
|---|---|---|
| `abs(v)` | `float` | Absolute value |
| `sqrt(v)` | `float` | Square root |
| `pow(b, e)` | `float` | `b` raised to the power `e` |
| `sin(v)` | `float` | Sine (radians) |
| `cos(v)` | `float` | Cosine (radians) |
| `tan(v)` | `float` | Tangent (radians) |
| `atan2(y, x)` | `float` | Arctangent of `y/x` |
| `floor(v)` | `float` | Round down |
| `ceil(v)` | `float` | Round up |
| `round(v)` | `float` | Round to nearest |
| `fract(v)` | `float` | Fractional part (`v - floor(v)`) |
| `sign(v)` | `float` | `-1.0`, `0.0`, or `1.0` |
| `min(a, b)` | `float` | Minimum of two values |
| `max(a, b)` | `float` | Maximum of two values |
| `clamp(v, lo, hi)` | `float` | Clamp `v` between `lo` and `hi` |
| `wrap(v, lo, hi)` | `float` | Wrap `v` into `[lo, hi)` |
| `snap(v, step)` | `float` | Round `v` to nearest multiple of `step` |
| `scale(v, factor)` | `float` | Multiply `v` by `factor` |
| `lerp(a, b, t)` | `float` | Linear interpolation |
| `smooth_step(a, b, t)` | `float` | Smooth Hermite interpolation |
| `smoother_step(a, b, t)` | `float` | Smoother 5th-order interpolation |
| `ping_pong(t, len)` | `float` | Bounce `t` back and forth over `[0, len]` |
| `move_toward(cur, target, step)` | `float` | Move `cur` toward `target` by at most `step` |
| `angle_diff(a, b)` | `float` | Shortest signed angle difference (radians) |
| `deg_to_rad(d)` | `float` | Degrees to radians |
| `rad_to_deg(r)` | `float` | Radians to degrees |

### Easing

| Function | Returns | Description |
|---|---|---|
| `ease_in(t)` | `float` | Quadratic ease-in (`t²`) |
| `ease_out(t)` | `float` | Quadratic ease-out |
| `ease_in_out(t)` | `float` | Quadratic ease-in-out |
| `ease_in_cubic(t)` | `float` | Cubic ease-in (`t³`) |
| `ease_out_cubic(t)` | `float` | Cubic ease-out |
| `ease_in_out_cubic(t)` | `float` | Cubic ease-in-out |
| `ease_out_bounce(t)` | `float` | Bounce ease-out |
| `ease_in_elastic(t)` | `float` | Elastic ease-in |
| `ease_out_elastic(t)` | `float` | Elastic ease-out |

### Vector math

| Function | Returns | Description |
|---|---|---|
| `vec2_len(x, y)` | `float` | Length of 2D vector |
| `vec2_dot(ax, ay, bx, by)` | `float` | Dot product |
| `vec2_dist(ax, ay, bx, by)` | `float` | Distance between two points |
| `vec2_angle(x, y)` | `float` | Angle of vector (radians) |
| `vec2_cross(ax, ay, bx, by)` | `float` | 2D cross product (scalar) |
| `vec2_norm_x(x, y)` | `float` | X component of normalised vector |
| `vec2_norm_y(x, y)` | `float` | Y component of normalised vector |

### Type conversion

| Function | Returns | Description |
|---|---|---|
| `to_int(v)` | `int` | Convert float → int (truncates) |
| `to_float(v)` | `float` | Convert int → float |
| `to_bool(v)` | `bool` | Convert int → bool (`0` = false) |

### Color

| Function | Returns | Description |
|---|---|---|
| `rgb(r, g, b)` | `int` | Pack RGB into `0xRRGGBBFF` |
| `rgba(r, g, b, a)` | `int` | Pack RGBA into `0xRRGGBBAA` |
| `color_r(c)` | `int` | Extract red channel |
| `color_g(c)` | `int` | Extract green channel |
| `color_b(c)` | `int` | Extract blue channel |
| `color_a(c)` | `int` | Extract alpha channel |
| `color_lerp(a, b, t)` | `int` | Interpolate between two packed colors |
| `color_mix(a, b, t)` | `int` | Alias for `color_lerp` |

### Bitwise

| Function | Returns | Description |
|---|---|---|
| `bit_and(a, b)` | `int` | Bitwise AND |
| `bit_or(a, b)` | `int` | Bitwise OR |
| `bit_xor(a, b)` | `int` | Bitwise XOR |
| `bit_not(v)` | `int` | Bitwise NOT |
| `bit_shl(v, n)` | `int` | Shift left by `n` bits |
| `bit_shr(v, n)` | `int` | Shift right by `n` bits |

### Strings

| Function | Returns | Description |
|---|---|---|
| `int_to_str(v)` | `string` | Integer → string |
| `float_to_str(v)` | `string` | Float → string |
| `bool_to_str(v)` | `string` | Bool → `"true"` or `"false"` |
| `str_from_char(c)` | `string` | Byte value → 1-char string |

### StringBuilder

| Function | Description |
|---|---|
| `str_builder_new()` | Create a new builder |
| `str_builder_push(b, char_int)` | Append a byte by integer value |
| `str_builder_append(b, s)` | Append a string |
| `str_builder_build(b)` | Finalize and return the string |

### File I/O

| Function | Returns | Description |
|---|---|---|
| `file_read(path)` | `string` | Read file contents (persistent arena) |
| `file_write(path, content)` | | Overwrite file with string |
| `file_exists(path)` | `bool` | Check whether file exists |

### I/O

| Function | Description |
|---|---|
| `print(x)` | Print a value followed by a newline |
| `log(x)` | Alias for `print` |
| `assert(cond)` | Abort if `cond` is false |
| `todo()` | Mark a code path as unreachable (aborts) |

---

## Imports

```chasm
import "math_utils"
```

All public functions and extern declarations from the imported file become available in the importing file.

---

## Grammar (Informal)

```
file          ::= (attr_decl | fn_decl | struct_decl | enum_decl | extern_decl | import_decl | stmt)*

attr_decl     ::= '@' IDENT '::' lifetime '=' expr

fn_decl       ::= ('def' | 'defp') IDENT '(' params ')' ('::' type)? 'do' block 'end'
params        ::= (param (',' param)*)?
param         ::= IDENT '::' type

struct_decl   ::= 'defstruct' IDENT 'do' (IDENT '::' type)* 'end'

enum_decl     ::= 'enum' IDENT '{' (IDENT ('(' type (',' type)* ')')? ',')* '}'

extern_decl   ::= 'extern' 'fn' IDENT '(' extern_params ')' '->' type ('=' STRING)?
import_decl   ::= 'import' STRING

block         ::= stmt*
stmt          ::= var_decl | assign | expr_stmt | return_stmt | if_stmt | while_stmt | for_stmt | break_stmt | continue_stmt | case_stmt

var_decl      ::= IDENT '::' (lifetime | type | lifetime type)? '=' expr
assign        ::= lvalue '=' expr
lvalue        ::= IDENT | '@' IDENT | lvalue '.' IDENT | lvalue '[' expr ']'

if_stmt       ::= 'if' expr 'do' block ('else' ('if' expr 'do' block)* ('else' block)?)? 'end'
while_stmt    ::= 'while' expr 'do' block 'end'
for_stmt      ::= 'for' IDENT 'in' (expr '..' expr | expr) 'do' block 'end'
case_stmt     ::= 'case' expr 'do' when_arm* ('_' '->' expr)? 'end'
when_arm      ::= 'when' pattern '->' expr

return_stmt   ::= 'return' expr (',' expr)*

expr          ::= pipe_expr
pipe_expr     ::= cmp_expr ('|>' call_expr)*
cmp_expr      ::= add_expr (cmp_op add_expr)*
add_expr      ::= mul_expr (('+' | '-') mul_expr)*
mul_expr      ::= unary_expr (('*' | '/') unary_expr)*
unary_expr    ::= ('-' | 'not') unary_expr | postfix_expr
postfix_expr  ::= primary_expr ('.' IDENT ('(' args ')')? | '[' expr ']')* ('with' '{' field_init* '}')?
primary_expr  ::= literal | IDENT | '@' IDENT | call_expr | struct_lit | array_lit | '(' expr ')' | if_expr

if_expr       ::= 'if' expr 'do' block ('else' block)? 'end'

type          ::= 'int' | 'float' | 'f32' | 'f64' | 'bool' | 'string' | 'atom' | 'strbuild' | '[]' type | IDENT
lifetime      ::= 'frame' | 'script' | 'persistent'
```

---

## Scripting Style

Chasm supports top-level statements outside any function. Code at file scope runs automatically — no `def main()` required:

```chasm
print("hello world")

x = 42
print(x)
```

This is equivalent to wrapping the statements in `def main()`. If a `def main()` is present, top-level statements are ignored in favour of it. Module attributes (`@name`) and function definitions can be freely mixed with top-level statements.

---

## `if` as an Expression

`if/else/end` can be used as an expression anywhere a value is expected:

```chasm
label = if @score > 100 do "great" else "ok" end
print(label)
```

The `else` branch is required when `if` is used as an expression. The value of each branch must have a compatible type.

---

## Type Aliases

| Alias | Resolves to |
|---|---|
| `f32` | `float` |
| `f64` | `float` |
| `str` | `string` |

