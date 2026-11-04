---
name: goose-memory-and-perf
description: Choosing Goose data layouts (array family, references, relative links, pools, enums) and making Goose fast (bounds-check elimination, release builds, measurement). Use when designing data structures or optimizing Goose code.
---

# Goose memory model and performance (see `goose-kb/GOOSE_MEMORY_MODEL.md`, `GOOSE_PERFORMANCE.md`)

Pick storage by what size does: fixed `T[N]` · frozen `T[]`/`T[varint]` · inline-cap `T[..N]` · grow-only `T[>..]` (default,
refs stay valid) · grow-shrink `T[>..<]` (refs only in variables, die at shrink) · view `T[:]`.
One resizable per data stack; compiler assigns stacks (`--stacks`). Variable-size elements ⇒ iterate-only; keep an index of
`T&<u32 in pool>` links to jump around.

Links: `T&` (8 B, local), `T&<u32>` self-relative (same array, serialisable), `T&<u32 in global>` pool-relative.
Non-nested lifetimes: `slot_pool` / `slice_pool`; stale index = logic bug, not memory unsafety.
Enums: fixed `E` (indexable, overwritable) vs variable `E..` (compact, pointable, immutable variant).

Performance: measure only `goose build` binaries; `goose build --stats --bce-lines`; make lengths provable
(slice rows, `assert(len == N)` only if truly invariant, loop counter ± const, `%` by length); keep hot buffers on the native
stack as fixed arrays; avoid per-iteration `str()`; compare with `--no-bce`. Release = wraps on signed overflow; `--debug` aborts.
