# Chasm

A scripting language for real-time games. Chasm compiles to C99, runs at native speed, and replaces garbage collection with a deterministic three-lifetime memory model that makes every allocation cost visible in the source code.

---


## Why Chasm

Game scripts run on a tight loop potentially thousands of times per second. Every invisible allocation, every GC pause, every hidden copy is a frame drop. Languages like Lua and Python hide these costs. Chasm does not.

In Chasm, **memory lifetime is part of the syntax**. You cannot accidentally allocate into a long-lived region the act of doing so must appear in the source as a function call. The compiler enforces this. There is nowhere for costs to hide.

The result is a language that reads like a scripting language but performs like handwritten C.

---

## The Three-Lifetime Model

This is the core idea. Every value in Chasm exists in exactly one of three memory regions:

```
Frame  <  Script  <  Persistent
```

| Lifetime | Lives until | Use for |
|---|---|---|
| `frame` | End of the current tick | Temporaries, intermediate computation |
| `script` | Hot-reload or explicit reset | Game state that survives across frames |
| `persistent` | Process exit | High scores, saved data, anything permanent |

Values flow in one direction only  upward, from shorter to longer lifetimes. To move a value up, you call a promotion function that is visible in the source:

```elixir
copy_to_script(x)   # frame → script
persist_copy(x)     # frame or script → persistent
```

Flowing downward is a compile error. There is no implicit promotion.

### Why this matters

In most scripting languages the question *"where does this live and when is it freed?"* is unanswerable without reading the GC implementation. In Chasm the answer is always in the source. A value annotated `:: frame` is gone before the next tick begins. A value promoted with `copy_to_script` costs exactly one copy. A `persist_copy` costs exactly one copy into a never-freed region.

The memory model is also what makes hot-reload safe. When a script is reloaded, `frame` state is already gone. `script` and `persistent` state is preserved if — and only if — its name, type, and lifetime are unchanged in the new version. The compiler checks this statically before the swap happens.

---

## Philosophy

**Allocation is always visible.** There is no way to write a Chasm program that silently allocates into a long-lived arena. The promotion call is always in the source. This makes it impossible to accidentally cause GC pressure or frame spikes from allocation patterns you didn't intend.

**The type system enforces the lifetime hierarchy.** Assigning a `frame` value to a `script` variable is a compile error. This catches an entire class of bugs — dangling references to arena memory that has already been cleared — at compile time rather than at runtime.

**No runtime, no GC, no VM.** The output is plain C99. You can read it, debug it, and profile it with standard tools. The runtime is a single header file (`chasm_rt.h`). There are no hidden threads, no background collectors, no runtime dependencies beyond libc.

**Explicit over implicit.** Lifetime promotion is visible. Type annotations are required at declaration sites and function parameters. The pipe operator `|>` rewrites to normal function calls — no special semantics. What you see is what the compiler generates.

**Designed for embedding.** Chasm is not a general-purpose language. It is designed to be embedded in game engines the same way Lua is — but without the GC overhead, and with a memory model that integrates naturally with arena-allocating host engines. The host controls all memory through a `ChasmCtx` passed to every generated function.

---

## Installation

```bash
git clone <repo>
cd chasm
./install.sh            # installs to ~/.local/bin
./install.sh /usr/local # installs system-wide
```

Installs the pre-built `chasm` binary and the Cursor/VS Code extension. No Zig required.

> **Platform support:** macOS arm64. To build for other platforms, see `archive/zig-compiler/`.

---

## Project Structure

```
compiler/          — compiler source (written in Chasm)
  lexer.chasm
  parser.chasm
  sema.chasm
  codegen.chasm
  main.chasm
runtime/           — C runtime header included in generated output
  chasm_rt.h
std/               — standard library (TODO)
bootstrap/         — pre-built bootstrap binary
  bin/
    chasm-macos-arm64
engine/            — Raylib integration
editors/           — VS Code / Cursor extension
archive/
  zig-compiler/    — original Zig compiler (frozen, no PRs)
SPEC.md            — language specification
CHANGELOG.md       — version history
```
