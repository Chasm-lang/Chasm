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

### Promotion Functions

| Function | Effect |
|---|---|
| `copy_to_script(x)` | Copies `x` into the script arena. Returns same type as `x`. |
| `persist_copy(x)` | Copies `x` into the persistent arena. Returns same type as `x`. |

---

## Types

| Type | Description | Examples |
|---|---|---|
| `int` | 64-bit signed integer | `0`, `42`, `-7` |
| `float` | 64-bit IEEE 754 float | `0.0`, `3.14`, `-1.5` |
| `bool` | Boolean | `true`, `false` |
| `string` | Immutable UTF-8 byte string | `"hello"` |
| `atom` | Compile-time symbol (maps to int constant) | `:idle`, `:running` |
| `[]T` | Growable typed array of element type `T` | `array_new(8)` |
| `strbuild` | Mutable string builder | `str_builder_new()` |
| `StructName` | User-defined struct (value type) | `Vec2 { x: 0.0, y: 0.0 }` |
| `EnumName` | Tagged enum (with optional payload) | `State.Idle` |

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

Module attributes are global state declared at the top of a file. They use the `@` prefix and require an explicit lifetime annotation.

```chasm
@score      :: script     = 0
@high_score :: persistent = 0
@frame_temp :: frame      = 0.0
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

Structs are value types. They compile to C structs with no heap allocation.

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

```chasm
arr :: []int = array_new(4)
arr.push(10)
arr.push(20)
x = arr[1]      # 20
arr[0] = 99
n = arr.len     # 2
arr.clear()
```

| Method / syntax | Equivalent | Description |
|---|---|---|
| `arr.len` | `array_len(arr)` | Number of elements |
| `arr.push(v)` | `array_push(arr, v)` | Append a value |
| `arr.pop()` | `array_pop(arr)` | Remove and return last value |
| `arr[i]` | `array_get(arr, i)` | Read element at index |
| `arr[i] = v` | `array_set(arr, i, v)` | Write element at index |
| `arr.clear()` | `array_clear(arr)` | Reset length to 0 |

Array literals `[a, b, c]` desugar to `array_new` + `push` calls.

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
file          ::= (attr_decl | fn_decl | struct_decl | enum_decl | extern_decl | import_decl)*

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
unary_expr    ::= 'not' unary_expr | primary_expr
primary_expr  ::= literal | IDENT | '@' IDENT | call_expr | method_chain | struct_lit | array_lit | '(' expr ')'

type          ::= 'int' | 'float' | 'bool' | 'string' | 'atom' | 'strbuild' | '[]' type | IDENT
lifetime      ::= 'frame' | 'script' | 'persistent'
```

---

## Code Generation

Chasm compiles to C99. The generated C:

- Embeds `ChasmCtx*` in every function signature.
- Uses three arena allocators (frame, script, persistent) — no heap allocation except for arrays.
- Produces a `chasm_rt.h` runtime header with all standard library implementations.
- Is readable — variable names, struct names, and function names are preserved.
- Has no hidden threads, no GC, no runtime beyond `libc`.
