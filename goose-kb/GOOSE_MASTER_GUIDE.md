# Goose Master Guide (scoped to the TCP-proxy project)

**Version in use:** `goose 751794c (runtime f2efb7e50b49)` (updated 2026-11-04 with `goose-kb/bin/update-goose.sh`;
first studied at `dcaf1ef`, 7 commits earlier, no language-surface change), repo `aardappel/goose`, built with gcc 15.2.0.
**Always run `goose-kb/bin/update-goose.sh --check` at the start of a session.**
Source: `upstream/goose/`, compiler: `upstream/build/goose`, wrapper: `bin/goose`.

**Scope note.** The user steered this work toward *designing a TCP proxy in Goose*, so the research was
deliberately limited. Legend used everywhere in this KB:

- **[V]** verified by compiling/running here (see `GOOSE_TEST_PROGRAMS/RESULTS.md`)
- **[D]** stated by upstream docs, read but not independently tested
- **[R]** my recommendation / interpretation
- **[?]** not investigated

## What was and was not studied

| Area | Status |
|---|---|
| Tutorial (all), reference §1–13, §22 threads, §24 C interop | read |
| Spec §7.10 `extern fn`, §11.2 concurrency; stdlib `os`, `binary`, `exception`, `ffi` docs | read |
| C++/Rust translation guide (errors, RAII, threads, serialization) | read |
| Reference §14–21, §23, §25; rest of the spec (lifetime inference, shrink rules, BCE) | **[?] skimmed/unread** |
| Compiler/runtime internals (`implementation.md`, `src/`), benchmarks, most samples | **[?] unread** |
| Exercises 3–10 from the original brief (records, relative-ref tree, graph, parser, serialization…) | **[?] not done** (out of scope after steering) |

## The language in one page

- Compiles whole program to C; `goose build` (real C compiler, optimized) vs `goose run` (in-process TinyCC,
  no threads, no libc symbols unless bound via `extern "c"` block). [D][V]
- **No heap.** Memory = native stack + N *data stacks* (bump pointer, 2 GB address reservation each) + statics.
  Scope exit frees by resetting the pointer. At most one *resizable* value live per stack, always on top, so
  growth never moves and references into a growing array stay valid. [D]
- **Array family** (all inline `[metadata][elements]`): `T[k]` fixed, `T[]` frozen, `T[varint]`, `T[..k]`
  inline capacity k (fixed-size, usable in structs), `T[..]`, `T[>..]` grow-only (default), `T[>..<]`
  grow-shrink (stack/queue). Strings are `u8` arrays; `u8[:]` is a view. [D]
- **Slices `T[:]`, references `T&`, optionals `T?`** carry static *roots*; the compiler rejects anything that
  could outlive its owner. No lifetime syntax. `.=` binds/rebinds a reference, `.==` compares identity. [D]
- Non-fixed values never copy implicitly: use `copy(x)`. Fixed-size values copy silently. [D]
- Arithmetic at operand width; no implicit sign change/narrowing; `as` (checked in `--debug`) / `as!`
  (never checked). `%` is Euclidean (never negative). Unsigned wraps; signed overflow aborts only in `--debug`. [D]
- Errors: trailing `bool`, `T?`, `return E from f` (long-distance, statically checked), `exception::try/throw`,
  `assert`/`abort`/`exit`. No `Result`, no exceptions. [D]
- `defer stmt;` exists and works [V] (the translation guide still says "no defer": that doc is stale).
- Generics: untyped params / `<T>`; function values are compile-time only (no closures that escape, no fn pointers). [D]
- Threads: `thread_fn` workers are separate programs with copied globals; communication only via typed
  queues (`qput`, `qget<T>`, `qpoll<T>`, `qlimit<T>`); only **flat** values cross. Need `goose build`. [D][V]
- No networking in stdlib ("arrive later"). Sockets = libc through `extern fn`. [D][V]

See `GOOSE_QUICK_REFERENCE.md` for syntax, `GOOSE_TCP_PROXY_NOTES.md` for what this means for the proxy.
