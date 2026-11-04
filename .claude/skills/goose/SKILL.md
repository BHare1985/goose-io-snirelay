---
name: goose
description: Write, review and debug Goose (aardappel/goose) code. Use whenever a task touches .goose files, the goose compiler, or designing software in Goose (arrays, references, pools, errors, threads). Loads the project's verified Goose knowledge base.
---

# Writing Goose

Knowledge base: `/home/bhare/dev/tcprouter/goose-kb/` (read `GOOSE_QUICK_REFERENCE.md` first; `GOOSE_CODING_RULES.md` for rules;
`GOOSE_LESSONS.md` for verified discoveries — append new ones). Compiler: `goose-kb/bin/goose` (version `dcaf1ef`).
Upstream docs/source: `goose-kb/upstream/goose/{docs,stdlib,samples}`.

## Workflow
1. Check the KB, then `grep` `upstream/goose/stdlib/*.goose` / `docs/reference.md` before using any builtin. Never invent APIs.
2. Write Goose, not C-in-Goose. Mental model: **no heap**; data lives inline in the owning variable; scope exit frees;
   arrays never move so references survive growth.
3. `goose-kb/bin/goose check f.goose` → `build` → run. Use `--debug` for tests, `--stats --bce-lines` for perf, `--stacks` for threads.
4. Read the whole error: it names both the reference's root and the destination.
5. Add anything new you learn to `GOOSE_LESSONS.md` with [V]erified / [D]oc / [R]ecommendation tags.

## Defaults
- Builder/arena `T[>..]`; struct-embedded buffers `T[..N]`; scratch `T[N]`; params `T[:]`; stack/queue `T[>..<]`.
- Bind with `.=` to hold a reference, `copy()` to really copy. `import std;` is required for `split/trim/find/parse_int`.
- Errors: trailing `bool`, `T?`, `return E from f`; `assert/abort` only for bugs.
- Pools: `slot_pool` / `slice_pool` (never deprecated `reusable`).
- Threads: `thread_fn` + typed queues, flat values only, `goose build` only.
- Explain non-obvious Goose-specific choices in comments.

## Known traps
`u32 + i32` is an error; `%` is Euclidean; `os::arg` returns void; no `sizeof` (use `bytes_of(arr_of_one).len`);
doc examples omit imports; the C++/Rust translation guide wrongly says there is no `defer`.
