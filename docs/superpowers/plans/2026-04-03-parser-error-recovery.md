# Parser Error Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add panic-mode error recovery to the Chasm parser so syntax errors produce clear `E100`–`E103` diagnostics and multiple errors are reported in one compile run.

**Architecture:** Move `Diagnostic`/`DiagCollector` from `sema/diag.chasm` to `parser/helpers.chasm` so parsers can use them. Thread a `dc :: DiagCollector` parameter through every parse function — shared-heap mutation means callers see all diagnostics without returning `dc`. Emit diagnostics at specific error sites; use a new `sync_to` helper to skip forward to safe tokens after each error. `main.chasm` creates one `dc` shared by both parse and sema passes.

**Tech Stack:** Chasm self-hosted compiler. No external test framework — tests run by feeding bad .chasm files to the bootstrap binary and inspecting stderr.

---

## File map

| File | Change |
|---|---|
| `compiler/parser/helpers.chasm` | Add `Diagnostic`, `DiagCollector`, helpers (moved from sema); add `sync_to` |
| `compiler/sema/diag.chasm` | Remove moved definitions; keep `extract_snippet`, `make_caret`, `levenshtein`, `closest_match` |
| `compiler/parser/exprs.chasm` | Add `dc :: DiagCollector` to all parse functions; add E103 in `parse_primary` |
| `compiler/parser/stmts.chasm` | Add `dc :: DiagCollector` to all parse functions; add E100 in `parse_file`, E101/E102 in `parse_fn_decl`, `parse_defstruct`, `parse_if`, `parse_while` |
| `compiler/main.chasm` | Create `dc` before `parse_file`; pass to both `parse_file` and `sema_all` |

---

### Task 1: Move Diagnostic/DiagCollector to parser/helpers.chasm

**Context:** `Diagnostic` and `DiagCollector` are currently in `sema/diag.chasm`. The compiler concatenates files in this order: `lexer → parser/types → parser/helpers → parser/exprs → parser/stmts → sema/types → sema/diag → sema/resolve → sema/expr → sema/passes → codegen/* → main`. Parser files cannot reference sema types. Moving the structs and helpers to `parser/helpers.chasm` makes them available to both parser and sema.

**Files:**
- Modify: `compiler/parser/helpers.chasm`
- Modify: `compiler/sema/diag.chasm`

- [ ] **Step 1: Append the moved code to parser/helpers.chasm**

Add the following block at the end of `compiler/parser/helpers.chasm` (after the `parse_string_interp` comment but before any existing code):

```
# ---- Diagnostic types and collector (shared by parser and sema) ---------------

defstruct Diagnostic do
  code     :: string
  category :: string
  file     :: string
  line     :: int
  col      :: int
  message  :: string
  snippet  :: string
  caret    :: string
  help     :: string
end

defstruct DiagCollector do
  diags   :: []Diagnostic
  count_v :: []int
end

defp make_diag_collector() :: DiagCollector do
  pool  :: []Diagnostic = []
  empty :: Diagnostic   = Diagnostic{ code: "", category: "", file: "", line: 0, col: 0, message: "", snippet: "", caret: "", help: "" }
  i = 0
  while i < 256 do
    pool.push(empty)
    i = i + 1
  end
  cv :: []int = []
  cv.push(0)
  dc :: DiagCollector = DiagCollector{ diags: pool, count_v: cv }
  return dc
end

defp diag_emit(dc :: DiagCollector, d :: Diagnostic) :: DiagCollector do
  n = dc.count_v.get(0)
  if n < 256 do
    diags :: []Diagnostic = dc.diags
    diags.set(n, d)
    dc.count_v.set(0, n + 1)
  end
  return dc
end

defp diag_count(dc :: DiagCollector) :: int do
  return dc.count_v.get(0)
end

defp diag_has_errors(dc :: DiagCollector) :: bool do
  return dc.count_v.get(0) > 0
end

defp render_diagnostic(d :: Diagnostic) :: string do
  line_s  = int_to_str(d.line)
  pad     = " "
  gutter  = str_concat(pad, str_concat(line_s, " "))
  blank_g = str_repeat(" ", str_len(gutter))
  nl      = "\n"
  header  = str_concat("error[", str_concat(d.code, str_concat("]: ", str_concat(d.category, nl))))
  arrow   = str_concat("  --> ", str_concat(d.file, str_concat(":", str_concat(line_s, str_concat(":", str_concat(int_to_str(d.col), nl))))))
  sep1    = str_concat(blank_g, str_concat("|", nl))
  code_ln = str_concat(gutter, str_concat("| ", str_concat(d.snippet, nl)))
  caret_l = str_concat(blank_g, str_concat("|   ", str_concat(d.caret, nl)))
  sep2    = str_concat(blank_g, str_concat("|", nl))
  result  = str_concat(header, str_concat(arrow, str_concat(sep1, str_concat(code_ln, str_concat(caret_l, sep2)))))
  if str_len(d.help) > 0 do
    help_l = str_concat(blank_g, str_concat("= help: ", str_concat(d.help, nl)))
    result = str_concat(result, help_l)
  end
  return result
end

defp render_all_diags(dc :: DiagCollector) do
  n     = dc.count_v.get(0)
  diags :: []Diagnostic = dc.diags
  i = 0
  while i < n do
    d = diags.get(i)
    eprint(render_diagnostic(d))
    i = i + 1
  end
end
```

- [ ] **Step 2: Gut sema/diag.chasm — remove the moved definitions**

Replace the contents of `compiler/sema/diag.chasm` with just the functions that remain (snippet extraction, Levenshtein, closest_match). The new file should be:

```
# ---- Snippet extraction and caret builder ------------------------------------

defp extract_snippet(src :: string, line :: int) :: string do
  if line <= 0 do return "" end
  n       = str_len(src)
  cur_line = 1
  start   = 0
  i       = 0
  while i < n do
    c = str_char_at(src, i)
    if c == 10 do
      if cur_line == line do
        return str_slice(src, start, i)
      end
      cur_line = cur_line + 1
      start    = i + 1
    end
    i = i + 1
  end
  # Last line (no trailing newline)
  if cur_line == line do
    return str_slice(src, start, n)
  end
  return ""
end

defp make_caret(col :: int, len :: int) :: string do
  actual_len = len
  if actual_len < 1 do actual_len = 1 end
  spaces = ""
  si = 1
  while si < col do
    spaces = str_concat(spaces, " ")
    si = si + 1
  end
  carets = ""
  ci = 0
  while ci < actual_len do
    carets = str_concat(carets, "^")
    ci = ci + 1
  end
  return str_concat(spaces, carets)
end

# ---- Levenshtein distance and closest_match ----------------------------------

defp levenshtein(a :: string, b :: string) :: int do
  la = str_len(a)
  lb = str_len(b)
  if la == 0 do return lb end
  if lb == 0 do return la end
  # Two-row DP
  prev :: []int = []
  curr :: []int = []
  j = 0
  while j <= lb do
    prev.push(j)
    curr.push(0)
    j = j + 1
  end
  i = 1
  while i <= la do
    curr.set(0, i)
    j = 1
    while j <= lb do
      ca = str_char_at(a, i - 1)
      cb = str_char_at(b, j - 1)
      cost = 1
      if ca == cb do cost = 0 end
      del_cost = prev.get(j) + 1
      ins_cost = curr.get(j - 1) + 1
      sub_cost = prev.get(j - 1) + cost
      best = del_cost
      if ins_cost < best do best = ins_cost end
      if sub_cost < best do best = sub_cost end
      curr.set(j, best)
      j = j + 1
    end
    # swap prev and curr
    tmp :: []int = prev
    prev = curr
    curr = tmp
    i = i + 1
  end
  return prev.get(lb)
end

defp closest_match(candidates :: []string, name :: string) :: string do
  best_dist = 3
  best_name = ""
  i = 0
  while i < candidates.len do
    cand = candidates.get(i)
    d    = levenshtein(cand, name)
    if d < best_dist do
      best_dist = d
      best_name = cand
    end
    i = i + 1
  end
  if best_dist <= 2 do return best_name end
  return ""
end
```

- [ ] **Step 3: Verify the compiler still builds**

```bash
cd /Users/garrettomlin/exto
cat compiler/lexer.chasm \
    compiler/parser/types.chasm compiler/parser/helpers.chasm \
    compiler/parser/exprs.chasm compiler/parser/stmts.chasm \
    compiler/sema/types.chasm compiler/sema/diag.chasm \
    compiler/sema/resolve.chasm compiler/sema/expr.chasm \
    compiler/sema/passes.chasm \
    compiler/codegen/helpers.chasm compiler/codegen/exprs.chasm \
    compiler/codegen/stmts.chasm compiler/codegen/emit.chasm \
    compiler/codegen/wasm.chasm compiler/main.chasm \
    > /tmp/sema_combined.chasm && \
bootstrap/bin/chasm-macos-arm64 > /tmp/stage1.c 2>/tmp/stage1_err.txt
echo "exit: $?"
wc -l /tmp/stage1.c
cat /tmp/stage1_err.txt | head -5
```

Expected: exit 0, ~6277 lines, no errors.

- [ ] **Step 4: Commit**

```bash
git add compiler/parser/helpers.chasm compiler/sema/diag.chasm
git commit -m "refactor(parser): move Diagnostic/DiagCollector to parser/helpers.chasm"
```

---

### Task 2: Add sync_to helper to parser/helpers.chasm

**Context:** `sync_to` advances `pos` until a "safe" token is found. It is used after emitting a diagnostic to skip garbage tokens and resume parsing. Three modes controlled by two booleans: top-level sync (only def/defstruct/enum/extern/eof), statement sync (+ end/else/newline), expression sync (+ rparen/rbracket/newline/end/else).

**Files:**
- Modify: `compiler/parser/helpers.chasm`

- [ ] **Step 1: Add sync_to after the render_all_diags definition in parser/helpers.chasm**

```
defp sync_to(tokens :: []Token, pos :: int, until_end :: bool, until_expr :: bool) :: int do
  while tok_kind(tokens, pos) != :eof do
    k = tok_kind(tokens, pos)
    if k == :def_kw or k == :defp_kw or k == :defstruct_kw or k == :enum_kw or k == :extern_kw do
      return pos
    end
    if until_end do
      if k == :end_kw or k == :else_kw or k == :newline do return pos end
    end
    if until_expr do
      if k == :rparen or k == :rbracket or k == :newline or k == :end_kw or k == :else_kw do
        return pos
      end
    end
    pos = pos + 1
  end
  return pos
end
```

- [ ] **Step 2: Verify build still passes (same command as Task 1 Step 3)**

```bash
cat compiler/lexer.chasm \
    compiler/parser/types.chasm compiler/parser/helpers.chasm \
    compiler/parser/exprs.chasm compiler/parser/stmts.chasm \
    compiler/sema/types.chasm compiler/sema/diag.chasm \
    compiler/sema/resolve.chasm compiler/sema/expr.chasm \
    compiler/sema/passes.chasm \
    compiler/codegen/helpers.chasm compiler/codegen/exprs.chasm \
    compiler/codegen/stmts.chasm compiler/codegen/emit.chasm \
    compiler/codegen/wasm.chasm compiler/main.chasm \
    > /tmp/sema_combined.chasm && \
bootstrap/bin/chasm-macos-arm64 > /tmp/stage1.c 2>/tmp/stage1_err.txt
echo "exit: $?"; cat /tmp/stage1_err.txt | head -5
```

Expected: exit 0, no errors.

- [ ] **Step 3: Commit**

```bash
git add compiler/parser/helpers.chasm
git commit -m "feat(parser): add sync_to helper for error recovery"
```

---

### Task 3: Add dc param to all expr parse functions (exprs.chasm)

**Context:** Every parse function in `exprs.chasm` needs a `dc :: DiagCollector` parameter appended to its signature, and every call to another parse function inside it needs `dc` added as the last argument. Only `parse_string_interp` is exempt — it has no `tokens` parameter and calls no parse functions.

The error site added here is **E103** in `parse_primary`: when no token matches any known expression form, emit E103 and advance one token (the existing `error_node` fallback path).

**Important:** After this task, stmts.chasm still calls parse_expr without `dc`. The code is inconsistent until Task 4 completes. The bootstrap binary is lenient about argument counts; the inconsistency is resolved in Task 4.

**Files:**
- Modify: `compiler/parser/exprs.chasm`

- [ ] **Step 1: Update parse_primary_ident signature and internal parse_expr calls**

Old signature: `defp parse_primary_ident(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, lx :: string, line :: int, col :: int) :: ParseResult do`

New signature: `defp parse_primary_ident(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, lx :: string, line :: int, col :: int, dc :: DiagCollector) :: ParseResult do`

There are 2 calls to `parse_expr` inside `parse_primary_ident` (one in the function-call argument loop, one in the struct-literal field loop). Change each from:
```
r = parse_expr(tokens, pool, np, ch, cp, pos)
```
to:
```
r = parse_expr(tokens, pool, np, ch, cp, pos, dc)
```

- [ ] **Step 2: Update parse_primary_match signature and internal parse_expr calls**

Old signature: `defp parse_primary_match(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, line :: int, col :: int) :: ParseResult do`

New signature: `defp parse_primary_match(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, line :: int, col :: int, dc :: DiagCollector) :: ParseResult do`

Change both `parse_expr` calls inside to pass `dc`.

- [ ] **Step 3: Update parse_primary_case signature and internal parse_expr calls**

Old signature: `defp parse_primary_case(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, line :: int, col :: int) :: ParseResult do`

New signature: `defp parse_primary_case(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, line :: int, col :: int, dc :: DiagCollector) :: ParseResult do`

Change the one `parse_expr` call inside to pass `dc`.

- [ ] **Step 4: Update parse_primary signature, internal calls, and add E103**

Old signature: `defp parse_primary(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int) :: ParseResult do`

New signature: `defp parse_primary(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, dc :: DiagCollector) :: ParseResult do`

Internal call sites to update (add `dc` as last arg):
- `parse_string_interp(pool, np, ch, cp, pos, lx, line, col)` — **no change** (parse_string_interp is exempt)
- `parse_primary_ident(tokens, pool, np, ch, cp, pos, lx, line, col)` → add `, dc`
- `parse_primary_match(tokens, pool, np, ch, cp, pos, line, col)` → add `, dc`
- `parse_primary_case(tokens, pool, np, ch, cp, pos, line, col)` → add `, dc`
- `parse_if(tokens, pool, np, ch, cp, pos)` → add `, dc`
- `parse_expr(tokens, pool, np, ch, cp, pos)` (inside lparen handler) → add `, dc`

**Add E103 at the fallback path.** The current fallback (bottom of parse_primary, before the final `return`) is:
```
pos = pos + 1
node_idx = np
np = alloc_node(pool, np, :error_node, 0, 0, 0, lx, line, col)
return ParseResult{ pos: pos, np: np, cp: cp, node_idx: node_idx }
```

Replace with:
```
d :: Diagnostic = Diagnostic{ code: "E103", category: "syntax error", file: "sema_combined.chasm", line: line, col: col, message: str_concat("unexpected token in expression: `", str_concat(lx, "`")), snippet: "", caret: "", help: "" }
dc = diag_emit(dc, d)
pos = sync_to(tokens, pos, false, true)
node_idx = np
np = alloc_node(pool, np, :error_node, 0, 0, 0, lx, line, col)
return ParseResult{ pos: pos, np: np, cp: cp, node_idx: node_idx }
```

- [ ] **Step 5: Update parse_postfix signature and internal calls**

Old: `defp parse_postfix(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int) :: ParseResult do`

New: `defp parse_postfix(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, dc :: DiagCollector) :: ParseResult do`

Internal calls to update (all add `, dc`):
- `parse_primary(tokens, pool, np, ch, cp, pos)` → add `, dc`
- `parse_expr(tokens, pool, np, ch, cp, pos)` — there are 3 of these (dot-method args loop, bracket index, struct-update field loop) → all add `, dc`

- [ ] **Step 6: Update parse_unary signature and internal calls**

Old: `defp parse_unary(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int) :: ParseResult do`

New: `defp parse_unary(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, dc :: DiagCollector) :: ParseResult do`

3 calls to `parse_postfix(tokens, pool, np, ch, cp, pos)` → all add `, dc`.

- [ ] **Step 7: Update parse_mul through parse_pipe (6 functions)**

For each of `parse_mul`, `parse_add`, `parse_compare`, `parse_and`, `parse_or`, `parse_pipe`:

Change signature: add `dc :: DiagCollector` at end.

Change each internal call to the next-lower precedence function: add `, dc`.

Specific call chains:
- `parse_mul`: 2 calls to `parse_unary` → add `, dc`
- `parse_add`: 3 calls to `parse_mul` → add `, dc`
- `parse_compare`: 2 calls to `parse_add` → add `, dc`
- `parse_and`: 2 calls to `parse_compare` → add `, dc`
- `parse_or`: 2 calls to `parse_and` → add `, dc`
- `parse_pipe`: 2 calls to `parse_or` → add `, dc`

- [ ] **Step 8: Update parse_expr signature and internal call**

Old: `defp parse_expr(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int) :: ParseResult do`

New: `defp parse_expr(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, dc :: DiagCollector) :: ParseResult do`

Body: `return parse_pipe(tokens, pool, np, ch, cp, pos)` → `return parse_pipe(tokens, pool, np, ch, cp, pos, dc)`

- [ ] **Step 9: Commit (intermediate — stmts.chasm not yet updated)**

```bash
git add compiler/parser/exprs.chasm
git commit -m "refactor(parser): add dc param to all expr parse functions, add E103"
```

---

### Task 4: Add dc param to all stmt parse functions + error sites + update main.chasm

**Context:** All parse functions in `stmts.chasm` need `dc :: DiagCollector` appended to their signatures. Error sites E100 (parse_file), E101 (missing `do`), and E102 (missing `end`) are added here. `main.chasm` is updated to create `dc` before `parse_file` and pass it to both parse and sema.

**Note on the parse_if else-if chain:** `parse_if` has a complex branch for `else if` chains. The `end` check in that branch (around line 137-139 of stmts.chasm) is inside the `else if` early-return path — it already silently skips missing `end`. Add E102 there as well.

**Files:**
- Modify: `compiler/parser/stmts.chasm`
- Modify: `compiler/main.chasm`

- [ ] **Step 1: Update parse_return**

Old: `defp parse_return(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int) :: ParseResult do`

New: `defp parse_return(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, dc :: DiagCollector) :: ParseResult do`

Change 2 calls to `parse_expr` inside → add `, dc`.

- [ ] **Step 2: Update parse_while with E101 and E102**

Old: `defp parse_while(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int) :: ParseResult do`

New: `defp parse_while(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, dc :: DiagCollector) :: ParseResult do`

Change `parse_expr` call → add `, dc`.
Change `parse_block_body` call → add `, dc`.

The existing code has `pos = skip_newlines(tokens, pos)` **before** the `do_kw` check — keep that line unchanged. Replace only the silent `do_kw` skip itself:
```
if tok_kind(tokens, pos) == :do_kw do
  pos = pos + 1
end
```
with:
```
if tok_kind(tokens, pos) == :do_kw do
  pos = pos + 1
else
  err_line = tok_line(tokens, pos)
  err_col  = tok_col(tokens, pos)
  d :: Diagnostic = Diagnostic{ code: "E101", category: "syntax error", file: "sema_combined.chasm", line: err_line, col: err_col, message: "expected `do` after `while` condition", snippet: "", caret: "", help: "" }
  dc = diag_emit(dc, d)
  pos = sync_to(tokens, pos, true, false)
end
```

Replace the silent `end_kw` skip:
```
if tok_kind(tokens, pos) == :end_kw do
  pos = pos + 1
end
```
with:
```
if tok_kind(tokens, pos) == :end_kw do
  pos = pos + 1
else
  err_line = tok_line(tokens, pos)
  err_col  = tok_col(tokens, pos)
  d :: Diagnostic = Diagnostic{ code: "E102", category: "syntax error", file: "sema_combined.chasm", line: err_line, col: err_col, message: "expected `end` to close `while`", snippet: "", caret: "", help: "" }
  dc = diag_emit(dc, d)
  pos = sync_to(tokens, pos, true, false)
end
```

- [ ] **Step 3: Update parse_for**

Old: `defp parse_for(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int) :: ParseResult do`

New: `defp parse_for(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, dc :: DiagCollector) :: ParseResult do`

Change `parse_expr` call → add `, dc`.
Change `parse_block_body` call → add `, dc`.
(No error sites for parse_for per spec.)

- [ ] **Step 4: Update parse_if with E101 and E102**

Old: `defp parse_if(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int) :: ParseResult do`

New: `defp parse_if(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, dc :: DiagCollector) :: ParseResult do`

Change `parse_expr` call → add `, dc`.
Change all `parse_block_body` calls → add `, dc`.
Change recursive `parse_if` call → add `, dc`.

The existing code has `pos = skip_newlines(tokens, pos)` **before** the `do_kw` check — keep that line unchanged. Replace only the silent `do_kw` skip (after `parse_expr` returns `cond`):
```
if tok_kind(tokens, pos) == :do_kw do
  pos = pos + 1
end
```
with:
```
if tok_kind(tokens, pos) == :do_kw do
  pos = pos + 1
else
  err_line = tok_line(tokens, pos)
  err_col  = tok_col(tokens, pos)
  d :: Diagnostic = Diagnostic{ code: "E101", category: "syntax error", file: "sema_combined.chasm", line: err_line, col: err_col, message: "expected `do` after `if` condition", snippet: "", caret: "", help: "" }
  dc = diag_emit(dc, d)
  pos = sync_to(tokens, pos, true, false)
end
```

Replace both silent `end_kw` skips — the one in the early-return else-if path AND the one at the end:
```
if tok_kind(tokens, pos) == :end_kw do
  pos = pos + 1
end
```
→ (apply to BOTH occurrences):
```
if tok_kind(tokens, pos) == :end_kw do
  pos = pos + 1
else
  err_line = tok_line(tokens, pos)
  err_col  = tok_col(tokens, pos)
  d :: Diagnostic = Diagnostic{ code: "E102", category: "syntax error", file: "sema_combined.chasm", line: err_line, col: err_col, message: "expected `end` to close `if`", snippet: "", caret: "", help: "" }
  dc = diag_emit(dc, d)
  pos = sync_to(tokens, pos, true, false)
end
```

- [ ] **Step 5: Update parse_stmt**

Old: `defp parse_stmt(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int) :: ParseResult do`

New: `defp parse_stmt(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, dc :: DiagCollector) :: ParseResult do`

Update all internal delegating calls (add `, dc` to each):
- `parse_return(tokens, pool, np, ch, cp, pos)` → add `, dc`
- `parse_if(tokens, pool, np, ch, cp, pos)` → add `, dc`
- `parse_while(tokens, pool, np, ch, cp, pos)` → add `, dc`
- `parse_for(tokens, pool, np, ch, cp, pos)` → add `, dc`
- `parse_expr(tokens, pool, np, ch, cp, pos)` — appears **5 times**: in the @attr handler (`k == :at_ident`), the var_decl handler (`k == :ident and k2 == :colon_colon`), the assign handler (`k == :ident and k2 == :eq`), the tuple_dest handler (`k == :ident and k2 == :comma`), and the final fallback `return parse_expr(...)` → all 5 add `, dc`

- [ ] **Step 6: Update parse_block_body**

Old: `defp parse_block_body(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int) :: ParseResult do`

New: `defp parse_block_body(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, dc :: DiagCollector) :: ParseResult do`

Change `parse_stmt(tokens, pool, np, ch, cp, pos)` → add `, dc`.

- [ ] **Step 7: Update parse_defstruct with E101 and E102**

Old: `defp parse_defstruct(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int) :: ParseResult do`

New: `defp parse_defstruct(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, dc :: DiagCollector) :: ParseResult do`

Change `parse_expr` call (default value) → add `, dc`.

The existing code has `pos = skip_newlines(tokens, pos)` **before** the `do_kw` check — keep that line unchanged. Replace only the silent `do_kw` skip:
```
if tok_kind(tokens, pos) == :do_kw do
  pos = pos + 1
end
```
with:
```
if tok_kind(tokens, pos) == :do_kw do
  pos = pos + 1
else
  err_line = tok_line(tokens, pos)
  err_col  = tok_col(tokens, pos)
  d :: Diagnostic = Diagnostic{ code: "E101", category: "syntax error", file: "sema_combined.chasm", line: err_line, col: err_col, message: "expected `do` after `defstruct` name", snippet: "", caret: "", help: "" }
  dc = diag_emit(dc, d)
  pos = sync_to(tokens, pos, true, false)
end
```

Replace the silent `end_kw` skip:
```
if tok_kind(tokens, pos) == :end_kw do
  pos = pos + 1
end
```
with:
```
if tok_kind(tokens, pos) == :end_kw do
  pos = pos + 1
else
  err_line = tok_line(tokens, pos)
  err_col  = tok_col(tokens, pos)
  d :: Diagnostic = Diagnostic{ code: "E102", category: "syntax error", file: "sema_combined.chasm", line: err_line, col: err_col, message: "expected `end` to close `defstruct`", snippet: "", caret: "", help: "" }
  dc = diag_emit(dc, d)
  pos = sync_to(tokens, pos, false, false)
end
```

- [ ] **Step 8: Update parse_fn_decl with E101 and E102**

Old: `defp parse_fn_decl(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int) :: ParseResult do`

New: `defp parse_fn_decl(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, dc :: DiagCollector) :: ParseResult do`

Change `parse_block_body(tokens, pool, np, ch, cp, pos)` → add `, dc`.

The existing code has `pos = skip_newlines(tokens, pos)` **before** the `do_kw` check — keep that line unchanged. Replace only the silent `do_kw` skip (after return type parsing, before parse_block_body):
```
if tok_kind(tokens, pos) == :do_kw do
  pos = pos + 1
end
```
with:
```
if tok_kind(tokens, pos) == :do_kw do
  pos = pos + 1
else
  err_line = tok_line(tokens, pos)
  err_col  = tok_col(tokens, pos)
  d :: Diagnostic = Diagnostic{ code: "E101", category: "syntax error", file: "sema_combined.chasm", line: err_line, col: err_col, message: str_concat("expected `do` after function signature for `", str_concat(name, "`")), snippet: "", caret: "", help: "" }
  dc = diag_emit(dc, d)
  pos = sync_to(tokens, pos, true, false)
end
```

Replace the silent `end_kw` skip (after parse_block_body):
```
if tok_kind(tokens, pos) == :end_kw do
  pos = pos + 1
end
```
with:
```
if tok_kind(tokens, pos) == :end_kw do
  pos = pos + 1
else
  err_line = tok_line(tokens, pos)
  err_col  = tok_col(tokens, pos)
  d :: Diagnostic = Diagnostic{ code: "E102", category: "syntax error", file: "sema_combined.chasm", line: err_line, col: err_col, message: str_concat("expected `end` to close function `", str_concat(name, "`")), snippet: "", caret: "", help: "" }
  dc = diag_emit(dc, d)
  pos = sync_to(tokens, pos, false, false)
end
```

- [ ] **Step 9: Update parse_file with E100 and call site updates**

Old: `defp parse_file(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int) :: ParseResult do`

New: `defp parse_file(tokens :: []Token, pool :: []Node, np :: int, ch :: []int, cp :: int, pos :: int, dc :: DiagCollector) :: ParseResult do`

Change all internal calls to pass `dc`:
- `parse_fn_decl(tokens, pool, np, ch, cp, pos)` → add `, dc`
- `parse_defstruct(tokens, pool, np, ch, cp, pos)` → add `, dc`
- `parse_expr(tokens, pool, np, ch, cp, pos)` (in @attr value parsing) → add `, dc`
- `parse_stmt(tokens, pool, np, ch, cp, pos)` (in toplevel_stmt fallback) → add `, dc`

**Add E100** inside the catch-all branch (the `if k != :def_kw and k != :defp_kw and ...` block), before the `parse_stmt` call. Insert a check for tokens that obviously cannot start a statement:

```
if k != :def_kw and k != :defp_kw and k != :defstruct_kw and k != :at_ident and k != :import_kw and k != :extern_kw and k != :enum_kw do
  if k == :end_kw or k == :else_kw or k == :do_kw do
    err_line = tok_line(tokens, pos)
    err_col  = tok_col(tokens, pos)
    err_lx   = tok_lex(tokens, pos)
    d :: Diagnostic = Diagnostic{ code: "E100", category: "syntax error", file: "sema_combined.chasm", line: err_line, col: err_col, message: str_concat("unexpected token at top level: `", str_concat(err_lx, "`")), snippet: "", caret: "", help: "" }
    dc = diag_emit(dc, d)
    pos = pos + 1
  else
    # Top-level statement (scripting style)
    tl_line = tok_line(tokens, pos)
    tl_col  = tok_col(tokens, pos)
    r   = parse_stmt(tokens, pool, np, ch, cp, pos, dc)
    pos = r.pos
    np  = r.np
    cp  = r.cp
    si  = r.node_idx
    if si != -1 do
      tl_idx = np
      np = alloc_node(pool, np, :toplevel_stmt, si, 0, 0, "", tl_line, tl_col)
      ch.set(cp, tl_idx)
      cp = cp + 1
    end
  end
end
```

- [ ] **Step 10: Update main.chasm**

In `compiler/main.chasm`, move `make_diag_collector()` to before `parse_file` and pass `dc` to `parse_file`:

Replace:
```
r    = parse_file(tokens, pool, 0, ch, 0, 0)
np   = r.np
root = r.node_idx

types   :: []int = make_int_pool(60000)
syms    :: []Sym = make_sym_pool(2000)

structs = collect_struct_list(pool, ch, root, 10)
fields  = collect_field_list(pool, ch, structs)
fns     = collect_fn_list(pool, ch, root, structs)
dc      = make_diag_collector()
dc      = sema_all(pool, ch, root, types, syms, fns, structs, fields, src, "sema_combined.chasm", dc)
```

with:

```
dc   = make_diag_collector()
r    = parse_file(tokens, pool, 0, ch, 0, 0, dc)
np   = r.np
root = r.node_idx

types   :: []int = make_int_pool(60000)
syms    :: []Sym = make_sym_pool(2000)

structs = collect_struct_list(pool, ch, root, 10)
fields  = collect_field_list(pool, ch, structs)
fns     = collect_fn_list(pool, ch, root, structs)
dc      = sema_all(pool, ch, root, types, syms, fns, structs, fields, src, "sema_combined.chasm", dc)
```

- [ ] **Step 11: Commit**

```bash
git add compiler/parser/stmts.chasm compiler/main.chasm
git commit -m "feat(parser): add dc param + E100-E102 error sites to stmt parse functions"
```

---

### Task 5: Test error reporting and run fixpoint

**Context:** Verify E100-E103 diagnostics appear on bad input, valid input still compiles clean, and the bootstrap fixpoint passes. The test writes .chasm files directly to `/tmp`, runs the bootstrap binary on them, and inspects stderr.

**Files:**
- No source changes — test only

- [ ] **Step 1: Create a test file with intentional syntax errors**

```bash
cat > /tmp/test_parse_errors.chasm << 'EOF'
# Missing `do` after function signature
def bad_fn(x :: int) :: int
  return x + 1
end

# Missing `end` for while
def another_fn() do
  i = 0
  while i < 10 do
    i = i + 1

  return i
end
EOF
```

- [ ] **Step 2: Run bootstrap on the error test file**

```bash
cd /Users/garrettomlin/exto
cp /tmp/test_parse_errors.chasm /tmp/sema_combined.chasm
bootstrap/bin/chasm-macos-arm64 > /tmp/parse_err_out.c 2>/tmp/parse_err_stderr.txt
echo "exit: $?"
cat /tmp/parse_err_stderr.txt
```

Expected: stderr contains at least one `error[E101]` (missing `do`) and at least one `error[E102]` (missing `end`). Exit code 1.

- [ ] **Step 3: Verify valid file produces no parse errors**

```bash
cp examples/hello_world.chasm /tmp/sema_combined.chasm
bootstrap/bin/chasm-macos-arm64 > /tmp/hello_out.c 2>/tmp/hello_err.txt
echo "exit: $?"
cat /tmp/hello_err.txt
```

Expected: exit 0, stderr empty (no parse or sema errors).

- [ ] **Step 4: Run the fixpoint**

```bash
cd /Users/garrettomlin/exto

# Concatenate all compiler source
cat compiler/lexer.chasm \
    compiler/parser/types.chasm compiler/parser/helpers.chasm \
    compiler/parser/exprs.chasm compiler/parser/stmts.chasm \
    compiler/sema/types.chasm compiler/sema/diag.chasm \
    compiler/sema/resolve.chasm compiler/sema/expr.chasm \
    compiler/sema/passes.chasm \
    compiler/codegen/helpers.chasm compiler/codegen/exprs.chasm \
    compiler/codegen/stmts.chasm compiler/codegen/emit.chasm \
    compiler/codegen/wasm.chasm compiler/main.chasm \
    > /tmp/sema_combined.chasm

# Stage 1 — old bootstrap compiles new source
bootstrap/bin/chasm-macos-arm64 > /tmp/stage1.c 2>/tmp/stage1_err.txt
echo "stage1 exit: $?"; cat /tmp/stage1_err.txt | head -5

clang -O2 -Wno-int-conversion -o /tmp/stage1_bin /tmp/stage1.c runtime/chasm_standalone.c -I runtime/
echo "stage1 compile: $?"

# Stage 2 — stage1 binary compiles new source
/tmp/stage1_bin > /tmp/stage2.c 2>/tmp/stage2_err.txt
echo "stage2 exit: $?"; head -3 /tmp/stage2.c

clang -O2 -Wno-int-conversion -o /tmp/stage2_bin /tmp/stage2.c runtime/chasm_standalone.c -I runtime/
echo "stage2 compile: $?"

# Stage 3 — fixpoint check
/tmp/stage2_bin > /tmp/stage3.c
diff /tmp/stage2.c /tmp/stage3.c && echo "✓ FIXPOINT" || echo "✗ FIXPOINT FAILED"
```

Expected: all exit codes 0, `✓ FIXPOINT`.

- [ ] **Step 5: Replace bootstrap binary and rebuild CLI**

```bash
cp /tmp/stage2_bin bootstrap/bin/chasm-macos-arm64
chmod +x bootstrap/bin/chasm-macos-arm64
go build -ldflags "-X main.defaultChasmHome=$(pwd)" -o ~/.local/bin/chasm ./cmd/cli
echo "rebuild: $?"
chasm run examples/hello_world.chasm
```

Expected: `Hello from Chasm!` (smoke test passes).

- [ ] **Step 6: Commit**

```bash
git add bootstrap/bin/chasm-macos-arm64
git commit -m "chore: rebuild bootstrap binary (parser error recovery)"
```
