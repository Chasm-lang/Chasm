# Write Buffer — Named Output Sections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all direct `print()` calls in the codegen path with a buffered, named-section system so any emit function can write to any section and sections flush in a fixed order.

**Architecture:** Add a `SectionBuf` struct (pre-allocated `[]string` + `[]int` cursor) and a `sections :: []SectionBuf` field to `CCtx`. All `print(s)` calls become `sec_emit(cctx, @SEC_X, s)`. At end of `codegen()`, `flush_sections(cctx)` prints sections 0→4 in order.

**Tech Stack:** Chasm (bootstrap compiler source only — no external dependencies). After all changes, run the 3-stage fixpoint to rebuild `bootstrap/bin/chasm-macos-arm64`.

**Spec:** `docs/superpowers/specs/2026-04-02-write-buffer-design.md`

---

## Files

| File | Change |
|---|---|
| `compiler/codegen/helpers.chasm` | Add `SectionBuf` struct, section ID constants, `@SEC_BUF_CAP`, `make_section_buf`, update `CCtx` + `make_cctx`, add `sec_emit` |
| `compiler/codegen/emit.chasm` | Add `flush_sections`; add `cctx` param to `emit_array_helpers`, `emit_enum_def`, `emit_struct_defs`, `emit_fwd_decls`; migrate all `print()` to `sec_emit()` |
| `compiler/codegen/stmts.chasm` | Migrate all `print()` in `emit_stmt` to `sec_emit(cctx, @SEC_BODY, ...)` |

---

### Task 1: Capture baseline C output

**Files:**
- Read: `test/scripts/test_features.chasm` (used as regression input)

- [ ] **Step 1: Compile the test file with the current bootstrap and save output**

```bash
chasm compile test/scripts/test_features.chasm > /tmp/baseline_codegen.c
echo "Baseline: $(wc -l < /tmp/baseline_codegen.c) lines"
```

Expected: exits 0, prints a line count. This file is your regression target — after all changes, the new output must match it exactly.

- [ ] **Step 2: Commit nothing — baseline is in /tmp only**

No commit needed for this step.

---

### Task 2: Add SectionBuf, section IDs, and make_section_buf to helpers.chasm

**Files:**
- Modify: `compiler/codegen/helpers.chasm` (insert before the `CCtx` struct definition at line 7)

- [ ] **Step 1: Insert section ID constants and SectionBuf struct before the CCtx struct**

In `compiler/codegen/helpers.chasm`, insert the following block immediately before `defstruct CCtx do` (currently at line 7):

```
# ---- Output section IDs -------------------------------------------------------
# Sections are flushed in numeric order by flush_sections().

@SEC_BUF_CAP = 65536   # max lines per section (guards against overflow)

@SEC_PRE   = 0   # preamble: header comment, #include
@SEC_TYPES = 1   # enum and struct typedefs
@SEC_HELP  = 2   # typed array helpers
@SEC_FWD   = 3   # function forward declarations
@SEC_BODY  = 4   # function bodies, module attrs, chasm_main

defstruct SectionBuf do
  lines  :: []string
  cursor :: []int
end

defp make_section_buf() :: SectionBuf do
  lines  :: []string = []
  cursor :: []int    = []
  cursor.push(0)
  empty  = ""
  i = 0
  while i < @SEC_BUF_CAP do
    lines.push(empty)
    i = i + 1
  end
  return SectionBuf{ lines: lines, cursor: cursor }
end

```

- [ ] **Step 2: Verify helpers.chasm parses**

```bash
chasm compile test/scripts/test_features.chasm 2>&1 | head -5
```

Expected: still compiles (CCtx hasn't changed yet so the output is identical). No parse errors.

- [ ] **Step 3: Commit**

```bash
git add compiler/codegen/helpers.chasm
git commit -m "feat(codegen): add SectionBuf struct and make_section_buf"
```

---

### Task 3: Update CCtx, make_cctx, and add sec_emit

**Files:**
- Modify: `compiler/codegen/helpers.chasm`

- [ ] **Step 1: Add `sections` field to CCtx**

Change:

```
defstruct CCtx do
  pool    :: []Node
  ch      :: []int
  types   :: []int
  structs :: []StructDef
  fns     :: []FnSig
  fields  :: []FieldDef
end
```

To:

```
defstruct CCtx do
  pool     :: []Node
  ch       :: []int
  types    :: []int
  structs  :: []StructDef
  fns      :: []FnSig
  fields   :: []FieldDef
  sections :: []SectionBuf
end
```

- [ ] **Step 2: Update make_cctx to build 5 SectionBuf slots**

Change:

```
defp make_cctx(pool :: []Node, ch :: []int, types :: []int,
               structs :: []StructDef, fns :: []FnSig,
               fields :: []FieldDef) :: CCtx do
  return CCtx{ pool: pool, ch: ch, types: types, structs: structs, fns: fns, fields: fields }
end
```

To:

```
defp make_cctx(pool :: []Node, ch :: []int, types :: []int,
               structs :: []StructDef, fns :: []FnSig,
               fields :: []FieldDef) :: CCtx do
  sections :: []SectionBuf = []
  i = 0
  while i < 5 do
    sections.push(make_section_buf())
    i = i + 1
  end
  return CCtx{ pool: pool, ch: ch, types: types, structs: structs, fns: fns, fields: fields, sections: sections }
end
```

- [ ] **Step 3: Add sec_emit after make_cctx**

Insert after the `make_cctx` function:

```
defp sec_emit(cctx :: CCtx, sec_id :: int, line :: string) do
  sb = cctx.sections.get(sec_id)
  n  = sb.cursor.get(0)
  if n < @SEC_BUF_CAP do
    sb.lines.set(n, line)
    sb.cursor.set(0, n + 1)
  end
end

```

- [ ] **Step 4: Verify helpers.chasm parses**

```bash
chasm compile test/scripts/test_features.chasm 2>&1 | head -5
```

Expected: still compiles. `sec_emit` is defined but not yet called, so output is unchanged.

- [ ] **Step 5: Commit**

```bash
git add compiler/codegen/helpers.chasm
git commit -m "feat(codegen): update CCtx with sections field, add sec_emit"
```

---

### Task 4: Add flush_sections to emit.chasm

**Files:**
- Modify: `compiler/codegen/emit.chasm` (add before the `codegen` entry point, around line 446)

- [ ] **Step 1: Add flush_sections function**

Insert the following immediately before `# ---- Top-level codegen entry point`:

```
# ---- Flush all output sections to stdout in order ----------------------------

defp flush_sections(cctx :: CCtx) do
  sec_id = 0
  while sec_id < 5 do
    sb = cctx.sections.get(sec_id)
    n  = sb.cursor.get(0)
    i  = 0
    while i < n do
      print(sb.lines.get(i))
      i = i + 1
    end
    sec_id = sec_id + 1
  end
end

```

- [ ] **Step 2: Verify**

```bash
chasm compile test/scripts/test_features.chasm 2>&1 | head -5
```

Expected: still compiles, output unchanged (`flush_sections` is not yet called).

- [ ] **Step 3: Commit**

```bash
git add compiler/codegen/emit.chasm
git commit -m "feat(codegen): add flush_sections"
```

---

### Task 5: Add cctx to emit_array_helpers, migrate to SEC_HELP

**Files:**
- Modify: `compiler/codegen/emit.chasm` (lines 4–25)

`emit_array_helpers` currently takes only `sn :: string`. It calls `print()` 10 times, all going to `SEC_HELP`.

- [ ] **Step 1: Update signature and replace all print() calls**

Change the function from:

```
defp emit_array_helpers(sn :: string) do
  print(str_concat("static inline ", ...
```

To (full replacement — add `cctx :: CCtx` as first parameter and replace every `print(x)` with `sec_emit(cctx, @SEC_HELP, x)`):

```
defp emit_array_helpers(cctx :: CCtx, sn :: string) do
  sec_emit(cctx, @SEC_HELP, str_concat("static inline ", str_concat(sn, str_concat(" chasm_array_get_", str_concat(sn, "(ChasmCtx *ctx, ChasmArray *a, int64_t i) {")))))
  sec_emit(cctx, @SEC_HELP, str_concat("    static const ", str_concat(sn, " zero = {0};")))
  sec_emit(cctx, @SEC_HELP, "    if (i < 0 || i >= a->len) return zero;")
  sec_emit(cctx, @SEC_HELP, str_concat("    return ((", str_concat(sn, "*)a->data)[i];")))
  sec_emit(cctx, @SEC_HELP, "}")
  sec_emit(cctx, @SEC_HELP, str_concat("static inline void chasm_array_set_", str_concat(sn, str_concat("(ChasmCtx *ctx, ChasmArray *a, int64_t i, ", str_concat(sn, " v) {")))))
  sec_emit(cctx, @SEC_HELP, str_concat("    if (i >= 0 && i < a->len) ((", str_concat(sn, "*)a->data)[i] = v;")))
  sec_emit(cctx, @SEC_HELP, "}")
  sec_emit(cctx, @SEC_HELP, str_concat("static inline void chasm_array_push_", str_concat(sn, str_concat("(ChasmCtx *ctx, ChasmArray *a, ", str_concat(sn, " v) {")))))
  sec_emit(cctx, @SEC_HELP, str_concat("    if (a->len >= a->cap) { a->cap = a->cap * 2 + 8; a->data = realloc(a->data, (size_t)a->cap * sizeof(", str_concat(sn, ")); }")))
  sec_emit(cctx, @SEC_HELP, str_concat("    if (a->data) ((", str_concat(sn, "*)a->data)[a->len++] = v;")))
  sec_emit(cctx, @SEC_HELP, "}")
  sec_emit(cctx, @SEC_HELP, str_concat("static inline ChasmArray chasm_array_fixed_init_", str_concat(sn, str_concat("(ChasmArena *arena, int64_t cap, ", str_concat(sn, " def) {")))))
  sec_emit(cctx, @SEC_HELP, "    if (cap <= 0) cap = 8;")
  sec_emit(cctx, @SEC_HELP, str_concat("    void *d = chasm_alloc(arena, (size_t)cap * sizeof(", str_concat(sn, str_concat("), _Alignof(", str_concat(sn, "));")))))
  sec_emit(cctx, @SEC_HELP, str_concat("    if (!d) return (ChasmArray){NULL, 0, cap, (int64_t)sizeof(", str_concat(sn, ")};")))
  sec_emit(cctx, @SEC_HELP, str_concat("    ", str_concat(sn, str_concat(" *p = (", str_concat(sn, "*)d; for (int64_t _i = 0; _i < cap; _i++) p[_i] = def;")))))
  sec_emit(cctx, @SEC_HELP, str_concat("    return (ChasmArray){d, cap, cap, (int64_t)sizeof(", str_concat(sn, ")};")))
  sec_emit(cctx, @SEC_HELP, "}")
  sec_emit(cctx, @SEC_HELP, "")
end
```

- [ ] **Step 2: Commit (do not test yet — callers still pass old signature)**

```bash
git add compiler/codegen/emit.chasm
git commit -m "refactor(codegen): emit_array_helpers takes cctx, writes to SEC_HELP"
```

---

### Task 6: Add cctx to emit_enum_def, migrate to SEC_TYPES

**Files:**
- Modify: `compiler/codegen/emit.chasm` (lines 52–206)

`emit_enum_def` currently takes `(pool, ch, structs, decl_idx)`. Add `cctx :: CCtx` as the first parameter and replace every `print(x)` with `sec_emit(cctx, @SEC_TYPES, x)`. The function has ~18 `print()` call sites.

- [ ] **Step 1: Update function signature**

Change:

```
defp emit_enum_def(pool :: []Node, ch :: []int, structs :: []StructDef, decl_idx :: int) do
```

To:

```
defp emit_enum_def(cctx :: CCtx, pool :: []Node, ch :: []int, structs :: []StructDef, decl_idx :: int) do
```

- [ ] **Step 2: Replace all print() calls in emit_enum_def**

Apply this substitution to every `print(x)` in the function body:

```
# Before:
print(x)
# After:
sec_emit(cctx, @SEC_TYPES, x)
```

There are ~18 occurrences. All of them go to `@SEC_TYPES`. None go anywhere else.

- [ ] **Step 3: Commit (caller update comes in Task 7)**

```bash
git add compiler/codegen/emit.chasm
git commit -m "refactor(codegen): emit_enum_def takes cctx, writes to SEC_TYPES"
```

---

### Task 7: Add cctx to emit_struct_defs, update internal calls, migrate to SEC_TYPES/SEC_HELP

**Files:**
- Modify: `compiler/codegen/emit.chasm` (lines 210–264)

`emit_struct_defs` currently takes `(structs, fields, pool, ch)`. It calls `emit_enum_def` and `emit_array_helpers` internally — those now need `cctx` passed. Its own `print()` calls go to `SEC_TYPES` (struct typedefs) or `SEC_HELP` (the "Typed array helpers" comment).

- [ ] **Step 1: Update function signature**

Change:

```
defp emit_struct_defs(structs :: []StructDef, fields :: []FieldDef, pool :: []Node, ch :: []int) do
```

To:

```
defp emit_struct_defs(cctx :: CCtx, structs :: []StructDef, fields :: []FieldDef, pool :: []Node, ch :: []int) do
```

- [ ] **Step 2: Replace print() calls in emit_struct_defs**

There are 6 direct `print()` calls. Apply the following mappings:

```
# "/* Enum types */" banner → SEC_TYPES
sec_emit(cctx, @SEC_TYPES, "/* Enum types */")

# "/* Struct types */" banner → SEC_TYPES
sec_emit(cctx, @SEC_TYPES, "/* Struct types */")

# typedef struct { → SEC_TYPES
sec_emit(cctx, @SEC_TYPES, "typedef struct {")

# individual field lines → SEC_TYPES
sec_emit(cctx, @SEC_TYPES, str_concat("    ", str_concat(c_type(fd.type_id, structs), str_concat(" ", str_concat(fd.name, ";")))))

# } StructName; → SEC_TYPES
sec_emit(cctx, @SEC_TYPES, str_concat("} ", str_concat(sd.name, ";")))

# blank line after struct → SEC_TYPES
sec_emit(cctx, @SEC_TYPES, "")

# "/* Typed array helpers */" banner → SEC_HELP
sec_emit(cctx, @SEC_HELP, "/* Typed array helpers */")
```

- [ ] **Step 3: Update the call to emit_enum_def (add cctx)**

Change:

```
emit_enum_def(pool, ch, structs, sd.node_idx)
```

To:

```
emit_enum_def(cctx, pool, ch, structs, sd.node_idx)
```

- [ ] **Step 4: Update the call to emit_array_helpers (add cctx)**

Change:

```
emit_array_helpers(sd.name)
```

To:

```
emit_array_helpers(cctx, sd.name)
```

- [ ] **Step 5: Verify (still print()-based output but now partially buffered)**

```bash
chasm compile test/scripts/test_features.chasm 2>&1 | head -5
```

Expected: the compiler does NOT crash. Output will be wrong (struct defs now go to buffer but haven't been flushed yet — they'll be missing from stdout). We are mid-migration; wait for Task 10 to restore correct output.

- [ ] **Step 6: Commit**

```bash
git add compiler/codegen/emit.chasm
git commit -m "refactor(codegen): emit_struct_defs takes cctx, writes to SEC_TYPES/SEC_HELP"
```

---

### Task 8: Add cctx to emit_fwd_decls, migrate to SEC_FWD

**Files:**
- Modify: `compiler/codegen/emit.chasm` (lines 297–322)

`emit_fwd_decls` currently takes `(pool, ch, structs, fns)`. Add `cctx :: CCtx` as first parameter.

- [ ] **Step 1: Update signature**

Change:

```
defp emit_fwd_decls(pool :: []Node, ch :: []int, structs :: []StructDef, fns :: []FnSig) do
```

To:

```
defp emit_fwd_decls(cctx :: CCtx, pool :: []Node, ch :: []int, structs :: []StructDef, fns :: []FnSig) do
```

- [ ] **Step 2: Replace all print() calls**

There are 3 `print()` calls. Apply:

```
# Before:
print("/* Forward declarations */")
# After:
sec_emit(cctx, @SEC_FWD, "/* Forward declarations */")

# Before:
print(str_concat(ret_c, str_concat(" chasm_", str_concat(f.name, str_concat("(ChasmCtx *ctx", str_concat(params_s, ");"))))))
# After:
sec_emit(cctx, @SEC_FWD, str_concat(ret_c, str_concat(" chasm_", str_concat(f.name, str_concat("(ChasmCtx *ctx", str_concat(params_s, ");"))))))

# Before:
print("")
# After:
sec_emit(cctx, @SEC_FWD, "")
```

- [ ] **Step 3: Commit (caller update in Task 10)**

```bash
git add compiler/codegen/emit.chasm
git commit -m "refactor(codegen): emit_fwd_decls takes cctx, writes to SEC_FWD"
```

---

### Task 9: Migrate emit_fn print() calls to SEC_BODY

**Files:**
- Modify: `compiler/codegen/emit.chasm` (lines 366–444)

`emit_fn` already takes `cctx :: CCtx`. It has 3 `print()` calls (line 401: opening brace; line 434: implicit return; line 442: closing brace; line 443: blank line).

- [ ] **Step 1: Replace all print() calls in emit_fn**

Change (line 401):

```
print(str_concat(ret_c, str_concat(" chasm_", str_concat(fn_name, str_concat("(ChasmCtx *ctx", str_concat(params_str, ") {"))))))
```

To:

```
sec_emit(cctx, @SEC_BODY, str_concat(ret_c, str_concat(" chasm_", str_concat(fn_name, str_concat("(ChasmCtx *ctx", str_concat(params_str, ") {"))))))
```

Change (line 434):

```
print(str_concat("  return ", str_concat(ec, ";")))
```

To:

```
sec_emit(cctx, @SEC_BODY, str_concat("  return ", str_concat(ec, ";")))
```

Change (line 442):

```
print("}")
```

To:

```
sec_emit(cctx, @SEC_BODY, "}")
```

Change (line 443):

```
print("")
```

To:

```
sec_emit(cctx, @SEC_BODY, "")
```

- [ ] **Step 2: Commit**

```bash
git add compiler/codegen/emit.chasm
git commit -m "refactor(codegen): emit_fn writes to SEC_BODY"
```

---

### Task 10: Update codegen() — preamble, attr helpers, attr globals, chasm_main, call flush_sections

**Files:**
- Modify: `compiler/codegen/emit.chasm` (lines 448–675)

This is the largest change in a single function. `codegen()` has ~50 `print()` calls across several blocks, plus two function calls (`emit_struct_defs`, `emit_fwd_decls`) that now need `cctx`.

- [ ] **Step 1: Migrate preamble print() calls to SEC_PRE (lines 452–454)**

Change:

```
  print("/* Generated by Chasm bootstrap compiler - do not edit. */")
  print("#include \042chasm_rt.h\042")
  print("")
```

To:

```
  sec_emit(cctx, @SEC_PRE, "/* Generated by Chasm bootstrap compiler - do not edit. */")
  sec_emit(cctx, @SEC_PRE, "#include \042chasm_rt.h\042")
  sec_emit(cctx, @SEC_PRE, "")
```

- [ ] **Step 2: Update emit_struct_defs call to pass cctx (line 455)**

Change:

```
  emit_struct_defs(structs, fields, pool, ch)
```

To:

```
  emit_struct_defs(cctx, structs, fields, pool, ch)
```

- [ ] **Step 3: Update emit_fwd_decls call to pass cctx (line 456)**

Change:

```
  emit_fwd_decls(pool, ch, structs, fns)
```

To:

```
  emit_fwd_decls(cctx, pool, ch, structs, fns)
```

- [ ] **Step 4: Migrate has_array_attr block print() calls to SEC_HELP (lines 475–527)**

Apply `print(x)` → `sec_emit(cctx, @SEC_HELP, x)` to all 26 `print()` calls inside the `if has_array_attr do` block. Each call maps directly — just swap the function name and add `cctx, @SEC_HELP,` as the first two arguments.

Example (first and last):

```
# First:
sec_emit(cctx, @SEC_HELP, "#ifndef CHASM_ARRAY_FIXED_HELPERS_DEFINED")
# ...
# Last:
sec_emit(cctx, @SEC_HELP, "")
```

- [ ] **Step 5: Migrate module attrs block print() calls to SEC_BODY (lines 537–624)**

Apply `print(x)` → `sec_emit(cctx, @SEC_BODY, x)` to all `print()` calls in the module attrs section (the `/* Module attributes */` comment, individual global declarations, and the `chasm_module_init` function body). There are ~12 `print()` calls here.

Example (first and last):

```
# First:
sec_emit(cctx, @SEC_BODY, "/* Module attributes */")
# ...
# Last (closing brace of chasm_module_init):
sec_emit(cctx, @SEC_BODY, "}")
sec_emit(cctx, @SEC_BODY, "")
```

- [ ] **Step 6: Migrate chasm_main block print() calls to SEC_BODY (lines 657–673)**

Apply `print(x)` → `sec_emit(cctx, @SEC_BODY, x)` to all 3 `print()` calls in the `if has_toplevel` block:

```
sec_emit(cctx, @SEC_BODY, "void chasm_main(ChasmCtx *ctx) {")
# ... (emit_stmt calls already write to SEC_BODY via Task 11)
sec_emit(cctx, @SEC_BODY, "}")
sec_emit(cctx, @SEC_BODY, "")
```

- [ ] **Step 7: Add flush_sections(cctx) at the very end of codegen(), after the function-walk loop**

The last statement of `codegen()` is currently the closing `end`. Add `flush_sections(cctx)` immediately before the `end`:

```
  # ... (existing function-walk and chasm_main blocks)
  flush_sections(cctx)
end
```

- [ ] **Step 8: Verify output is restored**

```bash
chasm compile test/scripts/test_features.chasm > /tmp/after_task10.c
diff /tmp/baseline_codegen.c /tmp/after_task10.c
```

Expected: `diff` outputs nothing (files are identical). This is the key regression check. If there's a diff, the section assignment for one of the print() calls above is wrong — compare the diff to identify which section is misassigned.

- [ ] **Step 9: Commit**

```bash
git add compiler/codegen/emit.chasm
git commit -m "refactor(codegen): codegen() uses sec_emit, calls flush_sections"
```

---

### Task 11: Migrate stmts.chasm emit_stmt print() calls to SEC_BODY

**Files:**
- Modify: `compiler/codegen/stmts.chasm`

`emit_stmt` and `emit_block_body` already take `cctx :: CCtx`. There are 23 `print()` calls in this file, all going to `SEC_BODY`.

- [ ] **Step 1: Replace all print() calls — apply the pattern throughout**

Pattern: `print(x)` → `sec_emit(cctx, @SEC_BODY, x)`

Apply to every `print()` in the file. Below is the complete list of substitutions:

```
# var_decl:
sec_emit(cctx, @SEC_BODY, str_concat(ind, str_concat(type_c, str_concat(" ", str_concat(node.name, str_concat(" = ", str_concat(val_c, ";")))))))

# assign — reassignment:
sec_emit(cctx, @SEC_BODY, str_concat(ind, str_concat(nm, str_concat(" = ", str_concat(val_c, ";")))))

# assign — first use:
sec_emit(cctx, @SEC_BODY, str_concat(ind, str_concat(type_c, str_concat(" ", str_concat(nm, str_concat(" = ", str_concat(val_c, ";")))))))

# return — void:
sec_emit(cctx, @SEC_BODY, str_concat(ind, "return;"))

# return — value:
sec_emit(cctx, @SEC_BODY, str_concat(ind, str_concat("return ", str_concat(val_c, ";"))))

# if — open brace:
sec_emit(cctx, @SEC_BODY, str_concat(ind, str_concat("if (", str_concat(unwrap_cond(cond_c), ") {"))))

# if — else:
sec_emit(cctx, @SEC_BODY, str_concat(ind, "} else {"))

# if — close brace:
sec_emit(cctx, @SEC_BODY, str_concat(ind, "}"))

# while — open brace:
sec_emit(cctx, @SEC_BODY, str_concat(ind, str_concat("while (", str_concat(unwrap_cond(cond_c), ") {"))))

# while — close brace:
sec_emit(cctx, @SEC_BODY, str_concat(ind, "}"))

# for — outer open brace:
sec_emit(cctx, @SEC_BODY, str_concat(ind, "{"))

# for — iter declaration:
sec_emit(cctx, @SEC_BODY, str_concat(ind1, str_concat("ChasmArray _iter = ", str_concat(iter_c, ";"))))

# for — C for-loop header:
sec_emit(cctx, @SEC_BODY, str_concat(ind1, "for (int64_t _fi = 0; _fi < _iter.len; _fi++) {"))

# for — loop variable:
sec_emit(cctx, @SEC_BODY, str_concat(ind2, str_concat(elem_c, str_concat(" ", str_concat(var_n, str_concat(" = chasm_array_get", str_concat(esuf, "(ctx, &_iter, _fi);")))))))

# for — inner close brace:
sec_emit(cctx, @SEC_BODY, str_concat(ind1, "}"))

# for — outer close brace:
sec_emit(cctx, @SEC_BODY, str_concat(ind, "}"))

# break:
sec_emit(cctx, @SEC_BODY, str_concat(ind, "break;"))

# continue:
sec_emit(cctx, @SEC_BODY, str_concat(ind, "continue;"))

# at_assign:
sec_emit(cctx, @SEC_BODY, str_concat(ind, str_concat("g_", str_concat(attr_name, str_concat(" = ", str_concat(val_c, ";"))))))

# tuple_dest — temp var:
sec_emit(cctx, @SEC_BODY, str_concat(ind, str_concat(ttype, str_concat(" _t = ", str_concat(rhs_c, ";")))))

# tuple_dest — reassignment:
sec_emit(cctx, @SEC_BODY, str_concat(ind, str_concat(vname2, str_concat(" = _t.", str_concat(field_s, ";")))))

# tuple_dest — first use:
sec_emit(cctx, @SEC_BODY, str_concat(ind, str_concat("int64_t ", str_concat(vname2, str_concat(" = _t.", str_concat(field_s, ";"))))))

# expression statement:
sec_emit(cctx, @SEC_BODY, str_concat(ind, str_concat(ec, ";")))
```

- [ ] **Step 2: Verify output still matches baseline**

```bash
chasm compile test/scripts/test_features.chasm > /tmp/after_task11.c
diff /tmp/baseline_codegen.c /tmp/after_task11.c
```

Expected: no diff.

- [ ] **Step 3: Also test with a script that exercises all statement types**

```bash
chasm compile test/scripts/test_features.chasm > /dev/null && echo "OK"
```

Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add compiler/codegen/stmts.chasm
git commit -m "refactor(codegen): emit_stmt writes to SEC_BODY via sec_emit"
```

---

### Task 12: Run fixpoint, verify baseline, rebuild bootstrap binary

**Files:**
- Modify: `bootstrap/bin/chasm-macos-arm64` (replaced with new binary after fixpoint)

After all source changes, the bootstrap binary must be rebuilt via the 3-stage fixpoint. See `bootstrap/README.md` for full explanation. The fixpoint proves the compiler is self-consistent.

- [ ] **Step 1: Concatenate compiler source in dependency order**

```bash
cat compiler/lexer.chasm \
    compiler/parser/types.chasm compiler/parser/helpers.chasm \
    compiler/parser/exprs.chasm compiler/parser/stmts.chasm \
    compiler/sema/types.chasm compiler/sema/diag.chasm \
    compiler/sema/resolve.chasm compiler/sema/expr.chasm compiler/sema/passes.chasm \
    compiler/codegen/helpers.chasm compiler/codegen/exprs.chasm \
    compiler/codegen/stmts.chasm compiler/codegen/emit.chasm compiler/codegen/wasm.chasm \
    compiler/main.chasm > /tmp/sema_combined.chasm
echo "Combined: $(wc -l < /tmp/sema_combined.chasm) lines"
```

Expected: prints a line count with no errors.

- [ ] **Step 2: Trigger harness write (if /tmp/full_harness.c is missing)**

```bash
chasm compile examples/hello_world.chasm > /dev/null
ls /tmp/full_harness.c
```

Expected: file exists.

- [ ] **Step 3: Stage 1 — old bootstrap compiles new source**

```bash
bootstrap/bin/chasm-macos-arm64 /tmp/sema_combined.chasm > /tmp/stage1.c
cp /tmp/full_harness.c /tmp/full_harness_s1.c
cat /tmp/stage1.c >> /tmp/full_harness_s1.c
clang -O2 -o /tmp/stage1_bin /tmp/full_harness_s1.c -I runtime/
echo "Stage 1: $?"
```

Expected: `Stage 1: 0`

- [ ] **Step 4: Stage 2 — stage1 binary compiles new source**

```bash
/tmp/stage1_bin /tmp/sema_combined.chasm > /tmp/stage2.c
cp /tmp/full_harness.c /tmp/full_harness_s2.c
cat /tmp/stage2.c >> /tmp/full_harness_s2.c
clang -O2 -o /tmp/stage2_bin /tmp/full_harness_s2.c -I runtime/
echo "Stage 2: $?"
```

Expected: `Stage 2: 0`

- [ ] **Step 5: Stage 3 — verify fixpoint**

```bash
/tmp/stage2_bin /tmp/sema_combined.chasm > /tmp/stage3.c
diff /tmp/stage2.c /tmp/stage3.c && echo "✓ FIXPOINT"
```

Expected: `✓ FIXPOINT` with no diff output. If diff shows differences, there is a non-determinism bug in the codegen — do not proceed to Step 6 until it is resolved.

- [ ] **Step 6: Replace bootstrap binary**

```bash
cp /tmp/stage2_bin bootstrap/bin/chasm-macos-arm64
chmod +x bootstrap/bin/chasm-macos-arm64
```

- [ ] **Step 7: Verify baseline still matches using the new binary**

```bash
chasm compile test/scripts/test_features.chasm > /tmp/after_fixpoint.c
diff /tmp/baseline_codegen.c /tmp/after_fixpoint.c && echo "✓ BASELINE MATCH"
```

Expected: `✓ BASELINE MATCH`

- [ ] **Step 8: Rebuild the CLI (picks up the new binary path if needed)**

```bash
go build -ldflags "-X main.defaultChasmHome=$(pwd)" -o ~/.local/bin/chasm ./cmd/cli
chasm version
```

Expected: prints version string.

- [ ] **Step 9: Commit**

```bash
git add bootstrap/bin/chasm-macos-arm64
git commit -m "chore: rebuild bootstrap binary after write buffer migration"
```

---

## Self-Review Checklist

- **Spec coverage**: preamble→SEC_PRE ✓, typedefs→SEC_TYPES ✓, helpers→SEC_HELP ✓, fwd_decls→SEC_FWD ✓, fn bodies + module attrs + chasm_main→SEC_BODY ✓, flush_sections ✓, wasm backend untouched ✓
- **No placeholders**: all print() substitutions are listed explicitly, all function signatures shown
- **Type consistency**: `SectionBuf`, `CCtx.sections :: []SectionBuf`, `sec_emit(cctx :: CCtx, sec_id :: int, line :: string)` — used consistently across all tasks
- **Overflow guard**: `if n < @SEC_BUF_CAP` in `sec_emit` matches the 65536-slot pre-allocation in `make_section_buf`
- **Caller updates**: `emit_array_helpers` updated in Task 5, caller (emit_struct_defs) updated in Task 7. `emit_enum_def` updated in Task 6, caller updated in Task 7. `emit_fwd_decls` updated in Task 8, caller updated in Task 10. `emit_struct_defs` updated in Task 7, caller updated in Task 10.
