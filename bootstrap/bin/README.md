# bootstrap/bin

Pre-built binaries for the Chasm compiler pipeline.

## Binaries

| File | Role |
|---|---|
| `chasm-macos-arm64` | Self-hosted Chasm compiler — reads `/tmp/sema_combined.chasm`, writes generated C99 to stdout |

> `chasm-cli-macos-arm64` is the old Zig-compiled CLI, kept for reference. It is no longer used — the CLI is now the Go binary built from `cmd/chasm/`.

---

## Running the bootstrap compiler directly

The bootstrap binary is a low-level tool used by the build pipeline. Most users should use the `chasm` CLI instead (see below).

```bash
# 1. Write the source you want to compile to the expected input path.
cat compiler/lexer.chasm compiler/parser.chasm compiler/sema.chasm \
    compiler/codegen.chasm compiler/main.chasm > /tmp/sema_combined.chasm

# 2. Run the bootstrap binary — output is C99 on stdout.
bootstrap/bin/chasm-macos-arm64 > /tmp/chasm_out.c

# 3. Compile the C output with the runtime header.
cp runtime/chasm_rt.h /tmp/chasm_rt.h
cc -o /tmp/chasm_out /tmp/chasm_out.c -I/tmp

# 4. Run.
/tmp/chasm_out
```

For scripts that have no `def main()` (e.g. the compiler source itself), link the standalone harness:

```bash
cc -o /tmp/chasm_out /tmp/chasm_out.c /tmp/chasm_harness.c -I/tmp
```

---

## Using the `chasm` CLI (recommended)

Install once:

```bash
./install.sh          # installs chasm to ~/.local/bin
export CHASM_HOME="$(pwd)"   # add to ~/.zshrc to make permanent
```

Then:

```bash
# Run a standalone script
chasm run examples/hello/hello.chasm

# Run a Raylib game
chasm run --engine raylib examples/game/example.chasm

# Compile to C only
chasm compile examples/hello/hello.chasm

# Watch for changes and rerun automatically
chasm watch examples/hello/hello.chasm

chasm version
chasm help
```

---

## Rebuilding the bootstrap binary

Run this whenever `compiler/*.chasm` changes:

```bash
# Concatenate compiler source
cat compiler/lexer.chasm compiler/parser.chasm compiler/sema.chasm \
    compiler/codegen.chasm compiler/main.chasm > /tmp/sema_combined.chasm

# Stage 1: old bootstrap compiles new source
bootstrap/bin/chasm-macos-arm64 > /tmp/stage1.c
cp runtime/chasm_rt.h /tmp/chasm_rt.h
cc -o /tmp/stage1 /tmp/stage1.c /tmp/chasm_harness.c -I/tmp

# Stage 2: stage1 compiles new source again
/tmp/stage1 > /tmp/stage2.c
cc -o /tmp/stage2 /tmp/stage2.c /tmp/chasm_harness.c -I/tmp

# Stage 3: verify fixpoint (stage2 output == stage3 output)
/tmp/stage2 > /tmp/stage3.c
diff /tmp/stage2.c /tmp/stage3.c && echo "✓ FIXPOINT"

# Replace binary
cp /tmp/stage2 bootstrap/bin/chasm-macos-arm64
```

The `chasm_harness.c` is written to `/tmp/` by the CLI on first run, or you can write it manually — see `cmd/chasm/main.go` for the content.

---

## Platform support

| Platform | Status |
|---|---|
| macOS arm64 | Pre-built binary included |
| Other platforms | Build from `archive/zig-compiler/` with Zig 0.15+ |
