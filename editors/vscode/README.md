# Chasm Language Support

Language support for [Chasm](https://github.com/Chasm-lang/Chasm) — a lightweight scripting language designed for games and real-time tools.

## Features

- **Syntax highlighting** — keywords, types, atoms, string interpolation, module attributes
- **Diagnostics** — type errors, undefined variables, and missing `end` blocks shown inline
- **Hover documentation** — hover any builtin, keyword, or user-defined function for its signature
- **Completions** — keywords, builtins, user functions, module attributes, and array/struct methods (`.get`, `.set`, `.push`, etc.)
- **Go to definition** — jump to `def`/`defstruct`/`enum` declarations
- **Document symbols** — outline view for all functions, structs, and enums
- **Code formatting** — auto-format on save
- **CodeLens** — `▶ Run` button above `on_tick`/`on_draw`/`main` functions
- **Snippets** — `tick`, `draw`, `fn`, `struct`, `for`, `if`, `game`, `with`, and more

## Requirements

The LSP features (diagnostics, hover, completions, go-to-definition) require the `chasm-lsp` binary on your PATH. Install it with the [Chasm installer](https://github.com/Chasm-lang/Chasm):

```sh
curl -fsSL https://raw.githubusercontent.com/Chasm-lang/Chasm/main/install.sh | sh
```

## Extension Settings

| Setting | Default | Description |
|---|---|---|
| `chasm.serverPath` | `""` | Path to `chasm-lsp`. Leave empty to use PATH. |
| `chasm.chasmPath` | `"chasm"` | Path to the `chasm` CLI for running files. |

## Quick Start

```chasm
@score :: script int = 0

def on_tick(dt :: float) do
  @score = @score + 1
end

def on_draw() do
  draw_text("Score: #{@score}", 10.0, 10.0, 24, 0xFFFFFFFF)
end
```

## Language Overview

- **Lifetimes** — `frame` (cleared each tick), `script` (survives ticks), `persistent` (survives reload)
- **Structs** — value types with update syntax: `e with { x: new_x, y: new_y }`
- **Enums** — tagged unions with optional payloads
- **Arrays** — `array_fixed(n, default)` for arena-backed arrays, `array_new(cap)` for heap arrays
- **String interpolation** — `"Score: #{@score}"`

Full language reference: [SPEC.md](https://github.com/Chasm-lang/Chasm/blob/main/SPEC.md)
