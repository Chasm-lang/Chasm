# Minimal IR — Design

**Date:** 2026-04-03
**Status:** Approved

## Problem

The Chasm codegen passes (`exprs.chasm`, `stmts.chasm`) walk the parse tree recursively and re-derive type information at every node: linear O(n) struct name→ID scans per reference, field list scans per struct literal, enum variant payloads re-parsed from raw strings at emit time, pipe/match/string-interp desugaring interleaved with C emission. This makes codegen hard to read, hard to test, and difficult to add optimization passes to.

## Goal

Introduce a typed flat IR between sema and codegen. The lowering pass transforms the parse tree into a flat array of typed `IROp` instructions, fully desugaring all syntactic sugar. Codegen becomes a flat loop over `IROp`s that emits one C line per op with no type re-inference and no tree recursion.

## Approach

**Typed flat IR with structured control flow.** Functions become linear sequences of `IROp` instructions. Complex expressions are broken into named temporaries (`t0`, `t1`, …). Structured control flow ops (`if_begin`/`if_else`/`if_end`, `while_begin`/`while_cond`/`while_end`) form balanced pairs in the flat array — no jump labels, since the target is C which has structured control flow. SSA/phi nodes are out of scope: they add complexity with no benefit for a C-targeting compiler.

## Design

### Section 1 — Data structures

**`IRVal`** — a typed value reference (temporary or named variable):

```
defstruct IRVal do
  tmp :: string   # temporary name ("t0", "t1", ...) or source variable name
  tid :: int      # resolved type ID (never 0 in valid IR)
end
```

**`IROp`** — a single instruction:

```
defstruct IROp do
  op   :: atom    # operation kind (see op table)
  dst  :: IRVal   # result value (empty tmp = no result / void)
  a    :: IRVal   # primary operand
  b    :: IRVal   # secondary operand
  name :: string  # function name / field name / operator / literal value
  ai   :: int     # index into IRProg.args pool (for calls and struct_new)
  ac   :: int     # arg count
  line :: int
  col  :: int
end
```

**`IRFn`** — a function as a contiguous slice of `IROp`s:

```
defstruct IRFn do
  name      :: string
  ret_tid   :: int
  ops_start :: int
  ops_len   :: int
end
```

**`IRProg`** — the top-level IR, replacing `CCtx`:

```
defstruct IRProg do
  fns     :: []IRFn
  ops     :: []IROp
  args    :: []IRVal      # flat arg pool sliced by IROp.ai + IROp.ac
  structs :: []StructDef
  fields  :: []FieldDef
end
```

**Op table:**

| Category | Op atoms |
|---|---|
| Literals | `:lit_int` `:lit_float` `:lit_bool` `:lit_str` `:lit_atom` |
| Arithmetic / logic | `:binop` (operator in `name`) `:unop` |
| Variables | `:var_decl` `:assign` `:at_read` `:at_write` |
| Calls | `:call` `:method_call` |
| Struct | `:field_get` `:struct_new` `:struct_update` |
| Arrays | `:index_get` `:index_set` |
| Tuples | `:tuple_new` `:tuple_get` |
| Control flow | `:if_begin` `:if_else` `:if_end` `:while_begin` `:while_cond` `:while_end` `:break` `:continue` `:return` |

### Section 2 — Lowering pass

**File:** `compiler/ir/lower.chasm`

**Entry point:**

```
defp lower(pool :: []Node, ch :: []int, root :: int,
           types :: []int, structs :: []StructDef,
           fields :: []FieldDef, fns :: []FnSig) :: IRProg
```

**Temporaries:** a counter `tc` (passed by value, returned with results) increments for each intermediate result. Named variables from source (`var_decl` / `assign` nodes) keep their source names. Only intermediate computations introduced during lowering get `tN` names.

**Expression lowering:** `lower_expr` walks an expression node, emits ops for all sub-expressions recursively, and returns an `IRVal` naming the result. Leaf nodes (literals, idents, `@attrs`) emit one op and return immediately.

**Desugaring rules:**

| Sugar | IR lowering |
|---|---|
| `a \|> f(b, c)` | `:call` with args `[a_val, b_val, c_val]` |
| `"#{x} text #{y}"` | chain of `:call str_concat` ops with temporaries |
| `match x` / `case :A` | `:if_begin` / `:if_else` / `:if_end` chains with `:binop ==` checks |
| `for v in arr` | `:while_begin` + `:while_cond` + `:var_decl v` + `:while_end` |
| `a, b = rhs` | `:var_decl _t = rhs`, `:tuple_get a = _t[0]`, `:tuple_get b = _t[1]` |
| `S{ x: 1 }` (with defaults) | `:struct_new` with all fields filled (defaults resolved at lower time) |
| `if` used as expression | `:if_begin` / `:if_else` / `:if_end` with `:assign` into a fresh tmp in each branch |

**Statement lowering:** `lower_stmt` emits control flow ops. `:if_begin` carries the condition `IRVal` in its `a` field. `:while_cond` carries the condition. `:return` carries the return value in `a`.

### Section 3 — New codegen

**File:** `compiler/codegen/ir_emit.chasm`

**Entry point:**

```
defp ir_emit(prog :: IRProg, src_file :: string) :: string
```

A flat loop per function over `IRFn.ops`:

```
for each IROp op in fn.ops:
  if op.op == :lit_int    do emit "{c_type(op.dst.tid)} {op.dst.tmp} = {op.name};" end
  if op.op == :binop      do emit "{c_type(op.dst.tid)} {op.dst.tmp} = {op.a.tmp} {op.name} {op.b.tmp};" end
  if op.op == :call       do emit "{c_type(op.dst.tid)} {op.dst.tmp} = {op.name}({args_str(prog, op)});" end
  if op.op == :field_get  do emit "{c_type(op.dst.tid)} {op.dst.tmp} = {op.a.tmp}.{op.name};" end
  if op.op == :if_begin   do emit "if ({unwrap_cond(op.a.tmp)}) {" end
  if op.op == :if_else    do emit "} else {" end
  if op.op == :if_end     do emit "}" end
  ...
```

Each op has all information needed to emit exactly one C statement. No recursion. No type re-inference. `c_type(tid, structs)` and `args_str` are the only helpers needed beyond the op itself.

Void calls (no result): if `op.dst.tmp` is empty, emit the call without assignment.

`struct_new` emits a C struct initializer using the args pool for field values (fields are in declaration order — the lowering pass fills defaults).

### Section 4 — File changes

| File | Change |
|---|---|
| `compiler/ir/types.chasm` | **New** — `IRVal`, `IROp`, `IRFn`, `IRProg` |
| `compiler/ir/lower.chasm` | **New** — lowering pass (parse tree → `IRProg`) |
| `compiler/codegen/ir_emit.chasm` | **New** — IR-based codegen (flat loop) |
| `compiler/codegen/helpers.chasm` | Add `args_str` helper |
| `compiler/main.chasm` | Add `lower` call; add `ir_emit` path alongside old codegen for diff verification; then switch exclusively to IR path |
| `compiler/codegen/exprs.chasm` | **Deleted** when IR path verified |
| `compiler/codegen/stmts.chasm` | **Deleted** when IR path verified |

**Concat order** (updated for new files):
```
lexer → parser/types → parser/helpers → parser/exprs → parser/stmts →
sema/types → sema/diag → sema/resolve → sema/expr → sema/passes →
ir/types → ir/lower →
codegen/helpers → codegen/ir_emit → codegen/emit → codegen/wasm →
main
```

(`codegen/exprs.chasm` and `codegen/stmts.chasm` are removed from this order when deleted.)

**Implementation order** (compiler remains working throughout):

1. Add `ir/types.chasm` — structs only, no logic
2. Add `ir/lower.chasm` — expression lowering (all expr node types)
3. Add `ir/lower.chasm` — statement lowering (control flow + desugaring)
4. Add `codegen/ir_emit.chasm` — flat loop codegen for all op types
5. Wire into `main.chasm` in dual-path mode: run both old and new codegen, diff C output — must match exactly
6. Switch `main.chasm` to IR-only path; delete `exprs.chasm` and `stmts.chasm`
7. Fixpoint + bootstrap binary rebuild

## Success criteria

- A valid Chasm source file compiles to identical C output through both the old (tree-walk) and new (IR) codegen paths before the old path is removed.
- Bootstrap fixpoint passes after old codegen is deleted.
- `codegen/exprs.chasm` and `codegen/stmts.chasm` no longer exist in the final state.
- A new optimization pass (e.g., constant folding of `:binop` on two `:lit_int` ops) can be added as a loop over `IRProg.ops` without modifying lowering or codegen.

## Out of scope

- SSA / phi nodes
- Optimization passes in this iteration (IR is the foundation; passes come after)
- WASM codegen changes (`codegen/wasm.chasm` continues to use the parse tree for now)
- Inlining, dead code elimination, register allocation
