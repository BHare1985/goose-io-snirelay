# Goose Performance Guide (limited: benchmark docs/compiler passes [?] not studied)

## Measuring
1. **Never time `goose run`** (TinyCC, unoptimised). Use `goose build` (gcc -O2 by default) and time the executable. [D]
2. `goose build --stats` shows inlining/folding and **`bce: elided X/Y index and A/B slice checks`**.
   `--bce-lines` lists, per line, checks elided vs kept. `--no-bce` is the A/B baseline. [V t02]
3. `--debug` builds are for correctness (overflow/range/tag checks), not speed. [D]
4. `goose build --dry-run` / `-v` / `-o f.c` to see the C and the compiler flags. [D]
5. `--stacks` shows address-space cost per worker. [V]
Method [R]: build release, warm up, repeat ≥5×, report median wall-clock + peak RSS (`/usr/bin/time -v`); change one thing at a time.

## What the language gives for free [D]
Contiguous inline data, no allocator, O(1) scope teardown, narrow relative links, variable-size enums, in-place
construction (return-by-value is free), monomorphised generics/HOFs, direct inlinable calls.

## Bounds-check elimination [D, V]
- Index checks are removed when the compiler can prove range: loop counters against a known length, `%` by the length
  (Euclidean ⇒ always in range), lengths established by `assert(a.len == W)` before the loop.
- t02 relay: `bce: elided 12/13 index and 0/2 slice checks`. The kept one was `buf[..n]` where `n` is the `recv` result
  (unknowable from C). That check is *useful* (guards a hostile/buggy return). Don't assert it away. [V]
- Give the analysis a length (hoist `assert(x.len == N)`), slice rows into `u8[:]`, keep indices as the loop variable ± constant.
- Index types (`u32 in a`, `checkfree fn`) move validation to ingestion. [D, ?untested]

## Network-proxy specific [R]
- Syscalls dominate: use large buffers (16–64 KiB on the native stack), `poll`/`epoll` over thread-per-connection,
  consider `splice`/`sendfile` for zero copy (untested).
- Avoid per-message `str()` building on the hot path; reuse a `u8[>..]` scratch with `clear()` (allowed when no slice
  into it is still live).
- Queue messages are memcpy'd: keep them small (`fd`, `port`), not payloads.
- Worker count ≈ cores for epoll loops; 2 GB×2 address reserve per worker is virtual, `--stack-reserve 64M` shrinks it.
- `os::trim_memory()` returns data-stack pages to the OS after a spike. [D]
