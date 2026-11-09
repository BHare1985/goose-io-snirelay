# Goose Coding Rules (for this project)

Provenance: **[D]** upstream docs, **[V]** verified here, **[R]** my judgement. Rules marked [R] are
conventions I recommend, not language requirements.

## MUST
1. **Write Goose, not C-in-Goose.** Use arrays/slices/enums/pools, not manual buffers+indices where a slice works. [R]
2. **Compile every change** (`goose check`, then `goose build`) and run it. Don't guess syntax or library APIs; grep `stdlib/` and `docs/`. [R]
3. **Use `goose build` for anything with threads or timing.** `run` can't start threads and isn't optimized. [D][V]
4. **Validate every integer from outside before using it as an index/length** (fds from epoll data, lengths from the wire). Goose bounds-checks, but a check failure is an `abort`, i.e. a remote crash. [V t04 `lookup`]
5. **Keep real data out of fields you mutate as sentinels** (`fds[i].fd = -1` then reading `fds[1-i].fd` was my bug). [V]
6. **Handle partial `send`/`recv`** and EOF (`n == 0`) / error (`n < 0`); half-close with `shutdown(WR)`. [V t02]
7. **Pass only flat values through queues** (no `T&`, `T[:]`). [D]
8. **Declare recursion with `recursive fn`** and pass growable state in as a parameter. [D]
9. **Use `copy()` when you need an independent non-fixed value**; otherwise assignment binds. [D]
10. **Define libc constants/structs yourself, with exact C layout**, and verify size with `bytes_of`. [V]

## SHOULD
- Call functions as methods: `w.pump(i)`, `s.direction_of(up)` (UFCS finds `fn pump(w: Worker&, i: i64)` in the receiver type's namespace). Plain `pump(w, i)` is not the author's style. [D][V]
- Write short functions as one tail expression (`fn area(s: Shape.Rect) -> f64 { s.w * s.h }`); `return` only for early exits. [D][V]
- One behaviour per enum variant: case functions (overloads on `Shape.Circle`...) or a `match`; both are exhaustive. [D]
- State used by one function and its helpers: nested functions over locals. State spread over files: a `root struct` plus UFCS functions. [D]
- Default to `T[>..]` for builders/arenas; `T[..N]` for strings/buffers inside structs; fixed `T[N]` for I/O scratch. [D]
- Prefer `T?` returns for "found or not" and a trailing `bool` for two-outcome calls; `return … from` for deep parse failures. [D]
- Use `slot_pool<T>` for objects freed in arbitrary order (connections); keep indices as `u32` for epoll data. [V t04]
- Use `binary::Reader` for wire parsing (checked reads, no copies). [D]
- Use `import std;` helpers (`split`, `trim`, `find`, `parse_int`) instead of hand loops. [D]
- Use `--debug` builds in tests: catches signed overflow, range/tag errors with line numbers. [D]
- Use `defer` for fd cleanup when a function has several exits. [V compile; D semantics]
- Use `qlimit` so overloaded queues shed load. [V t02]
- Give one-line comments for non-obvious Goose decisions (`.=` vs `=`, why a fixed array). [R]

## AVOID
- `reusable` / `reusable[]` (deprecated → `slot_pool` / `slice_pool`). [D]
- Variadic or callback C APIs; wrap them in a C sidecar instead. [D]
- Arrays of variable-size elements when you need random access (use an index of `&<u32 in pool>` links). [D]
- Thread-per-connection at scale: 2 GB × 2 reserved stacks per worker, cap ~8k. [V `--stacks`]
- Adding `assert`s just to silence bounds checks; each must be a true invariant. [R, matches upstream intent]
- Blocking `send` loops in a relay serving untrusted peers (stall/deadlock). [V analysis]

## NEVER
- Never assume C/Rust semantics (implicit promotion, `%` sign, copy-on-assign of arrays, NULL pointers).
- Never keep a slice/reference past what the compiler allows by working around it with indices into freed pool slots: pool `free` keeps memory valid but a stale index reads someone else's data. [D]
- Never trust `from_bytes` for integrity (it verifies *safety* only). [D]
- Never use Goose `exit()` / `abort` in a worker as error handling for peer-caused conditions; they take the process down (unless `thread_spawn_contained`). [D]
- Never invent builtins; if unsure, search `docs/reference.md` §25 and `stdlib/*.goose`.
