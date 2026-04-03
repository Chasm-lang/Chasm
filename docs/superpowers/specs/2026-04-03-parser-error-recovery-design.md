# Parser Error Recovery — Design

**Date:** 2026-04-03
**Status:** Approved

## Problem

The Chasm parser silently skips unrecognized tokens and produces a best-effort AST with no diagnostics. Syntax errors (typos, missing keywords, mismatched `do`/`end`) surface as confusing sema errors downstream, and only one problem is visible per compile run. The goal is to emit clear parse-time diagnostics and continue parsing so multiple errors are reported in a single run.

## Approach

Panic-mode recovery with synchronization sets. At each error site the parser emits a `Diagnostic`, then advances `pos` forward until it finds a known "safe" token (a sync token) and resumes parsing from there. This is the smallest change to the existing recursive-descent parser and matches the `DiagCollector` pattern already established in sema.

## Design

### Section 1 — Data structures and threading

Parse errors use the existing `Diagnostic` / `DiagCollector` types. These are currently defined in `sema/diag.chasm`, but since compiler source is concatenated parser-before-sema, the parser cannot see sema types. Fix: move the shared definitions to `parser/helpers.chasm`.

**Moved from `sema/diag.chasm` to `parser/helpers.chasm`:**
- `defstruct Diagnostic do ... end`
- `defstruct DiagCollector do ... end`
- `make_diag_collector()`
- `diag_emit(dc, d)`
- `diag_has_errors(dc)`
- `render_all_diags(dc)`

**Remaining in `sema/diag.chasm`:** `extract_snippet`, `make_caret`, `closest_match` — these are sema-specific helpers that require the source string.

`DiagCollector` uses the shared-heap pattern (pre-allocated `[]Diagnostic` + `[]int` cursor singleton). Passing `dc :: DiagCollector` by value to parser functions is sufficient — `diag_emit` mutates the shared heap so the caller's copy sees all updates without returning `dc`.

`ParseResult` struct is unchanged. All parser functions gain one new parameter `dc :: DiagCollector` (added at the end of each signature).

In `main.chasm`: create `dc = make_diag_collector()` before `parse_file`. Pass the same `dc` to `parse_file` and then to `sema_all`. Parse errors and sema errors accumulate in one collector and are printed together by the existing `render_all_diags` / exit path.

### Section 2 — Synchronization helper

New function in `parser/helpers.chasm`:

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

Three sync modes, two booleans:

| Mode | `until_end` | `until_expr` | Stops at |
|---|---|---|---|
| Top-level | false | false | `def`, `defp`, `defstruct`, `enum`, `extern`, `eof` |
| Statement | true | false | above + `end`, `else`, `newline` |
| Expression | false | true | above + `rparen`, `rbracket`, `newline`, `end`, `else` |

### Section 3 — Error sites

Error codes `E100`–`E103` are reserved for parse errors. Sema codes `E001`–`E009` are unchanged.

| Code | Site | Trigger | Message | Sync mode |
|---|---|---|---|---|
| E100 | `parse_file` | Token is not a recognized top-level keyword and is not handled as a top-level statement | `"unexpected token at top level: \`X\`"` | Top-level |
| E101 | `parse_fn_decl`, `parse_defstruct`, `parse_if`, `parse_while` | Missing `do` keyword | `"expected \`do\` after <context>"` | Statement |
| E102 | `parse_fn_decl`, `parse_defstruct`, `parse_if`, `parse_while` | Missing `end` keyword | `"expected \`end\` to close <context>"` | Top-level or Statement (see below) |
| E103 | `parse_expr` (primary) | Unrecognized token in expression position | `"unexpected token in expression: \`X\`"` | Expression |

`E102` sync mode: `parse_fn_decl` and `parse_defstruct` sync to top-level (missing `end` likely means the whole item is broken); `parse_if` and `parse_while` sync to statement-level (missing `end` is recoverable within the enclosing function).

Snippet and caret fields are empty for parse errors in this iteration — the parser does not receive the source string. Adding source-string snippets to parse errors is a follow-up.

### Section 4 — File changes

| File | Change |
|---|---|
| `compiler/parser/helpers.chasm` | Add moved `Diagnostic`/`DiagCollector` types and helpers; add `sync_to` |
| `compiler/sema/diag.chasm` | Remove moved definitions; keep `extract_snippet`, `make_caret`, `closest_match` |
| `compiler/parser/stmts.chasm` | Add `dc` param to `parse_file`, `parse_fn_decl`, `parse_defstruct`, `parse_if`, `parse_while`, `parse_for`, `parse_return`, `parse_block_body`, `parse_stmt`; add E100–E102 error sites |
| `compiler/parser/exprs.chasm` | Add `dc` param to `parse_expr` and all sub-parsers; add E103 in primary expression parser |
| `compiler/parser/types.chasm` | No changes |
| `compiler/main.chasm` | Create `dc` before `parse_file`; pass to `parse_file` and `sema_all`; no changes to error rendering |

## Success criteria

- A file with a syntax error (e.g., `deff foo do end` or missing `end`) produces an `E100`–`E103` diagnostic with file, line, col, and message — not a silent misparse or a cascading sema error.
- Multiple syntax errors in one file are all reported in a single compile run.
- A syntactically valid file produces zero new parse diagnostics (no regression).
- Bootstrap fixpoint passes after the change.
- Existing sema error codes and format are unaffected.

## Out of scope

- Snippet/caret display for parse errors (requires passing source string to parser).
- Recovery inside enum variant lists or extern parameter lists.
- `parse_for` error sites (the for-loop parser is simple and unlikely to misparse).
