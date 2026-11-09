# Goose Lessons (append as you learn; tag [V]/[D]/[R])

1. [V] Goose can drive raw Linux sockets/poll/epoll via `extern fn` with packed structs matching C layouts. A working multi-threaded forwarding proxy with 12 concurrent 300 KB echo clients passed (t02).
2. [V] `goose run` can't link libc symbols or start threads; `extern "c"{}` + sidecar `dylibs_linux=["c=libc.so.6"]` fixes the first.
3. [V] Variadic/callback C functions are unbindable; use flags (`SOCK_NONBLOCK`, `MSG_NOSIGNAL`) or a C sidecar.
4. [V] `T&` params can't be NULL; give `accept` real storage.
5. [V] `std` is not implicit: `import std;`. Doc examples hide it. Translation guide is stale about `defer`.
6. [V] Compiler binary needs `stdlib/` beside it or `GOOSE_STDLIB`. Wrapper `goose-kb/bin/goose` handles it.
7. [V] `--stacks` is the tool to size thread designs (2 data stacks per worker; cap 8186).
8. [V] Slot reuse and index validation behave as documented (t04).
9. [V] BCE: `buf[..n]` after `recv` keeps its check (correct); fixed-array indexing in loops is elided (12/13).
10. [D] Memory safety comes from roots + whole-program specialisation, no annotations; non-fixed values never copy implicitly.
11. [D] Errors: `return E from f` for deep failure; reserve `abort/assert` for bugs, not peer behaviour.
12. [R] Design the proxy around per-worker epoll loops with `slot_pool<Conn>` state and message-passing for config/stats.

Still open: lifetime-checker error messages in practice, `thread_spawn_contained` supervision, splice/sendfile,
`slice_pool`, index types, serialization of config, performance numbers vs a C baseline.

## Added during tcprouter M0 (2026-11-04)
13. [V] Package/C: see GOOSE_PACKAGES_AND_C.md. `c_sources` works under run+build; `c_headers` adapters break `goose run` (TinyCC has no system headers here).
14. [V] `root struct` cannot be returned by value nor nest another root (e.g. slot_pool); construct in place, then `start(w, …)`.
15. [V] `match` is a keyword (no field named `match`); variant literals have the variant's type, annotate (`let e: Event = …`) to `match`.
16. [V] `resize` on a grow-only array is refused while any reference/slice into it is live; `push`/`append` are fine.
17. [V] No per-thread queue: broadcast = pipe per worker, created before `thread_spawn`; configs of 66 KB pass as thread args.
18. [V] signalfd works for SIGTERM/SIGINT with `sigset_t` as `u8[128]`; no C.
19. [V] Generic engine can call policy fns via UFCS (`p.pick(…)`); plain-call form does not cross namespaces.
20. [V] Goose moves daily: at 751794c (7 commits after dcaf1ef) `root struct` still cannot nest another root (e.g. a slot_pool inside a root) nor be returned. Re-test these when updating; `bin/update-goose.sh` fetches and rebuilds (the full rebuild is about 10 minutes, main.cpp dominates).
21. [V] Library root types (`slot_pool`, `slice_pool`) are implemented in Goose with `root struct`; own tables = own root fields, one data stack each.
22. [V] A --debug test catches real bugs: my first sni.goose indexed `rest[0]` on an empty slice and aborted with "index 0 out of bounds"; fixed by checking `rest.len >= 1` first.
23. [V] A thread blocked in `os::read_line` (stdio) holds stdin's lock, and `exit()`/returning from `main` then hangs forever. A
    control thread must read stdin with a raw `read(0, …)` extern instead (tests/net/harness/forward_server.goose does).
24. [V] Goose `thread_spawn(W, …)` takes the thread_fn as a trailing function argument of a generic function; globals set in `main`
    before the spawn (pipe fds, a worker count) are copied into each worker and into a control thread started later.


## Author's idioms, checked against upstream docs and samples (2026-11-09)

Sources: `upstream/goose/docs/tutorial.md` (sections 9, 13), `docs/reference.md` (Namespaces, UFCS), `docs/design/namespaces.md`,
`docs/design/root_structs.md`, `stdlib/slot_pool.goose`, `samples/05_shapes.goose`, `17_calc.goose`, `18_json.goose`; README of
github.com/aardappel/goose. A pasted AI-Studio chat about "classes in Goose" was checked against them: its core claims hold
(no classes/inheritance/vtables; structs + UFCS + namespaces; enums + case functions for polymorphism; root structs for several
growables), its extras do not (see the last bullet).
- **[D] Call with method syntax.** `x.f(a)` is `f(x, a)`; it looks in the namespace of x's type FIRST, from any namespace
  (reference, "Namespaces"). So Worker functions are written `w._pump(i)`, `w.send(conn, bytes)`, `w.serve() { ... }`, not `_pump(w, i)`.
  The author's stdlib does this everywhere (`pool.alloc_index(v)`, `items.push(x)`). [V] converted all of tcprouter; builds and passes.
- **[D] Short functions are one expression, no `return`.** `fn area(s: Shape.Rect) -> f64 { s.w * s.h }`. Keep `return` for early exits.
- **[D] Per-variant behaviour: `match`, or case functions** (one overload per variant: `fn area(s: Shape.Circle)`, `fn area(s: Shape.Rect)`;
  the call `area(s)` dispatches through a jump table and stops compiling when a variant is added). Use case functions when the behaviour is
  "a method of the enum"; a `match` when one arm does something and the rest are `_ => {}` (as in route.goose). No enum-to-integer builtin exists.
- **[D] Nested functions share the enclosing function's locals "so you avoid passing a state struct through every call"** (tutorial section 9 and 13), but only
  "when the code that works on the tables is small enough to fit inside the driver ... The struct is for code spread over many functions or files."
  tcprouter's engine spans files, so `root struct Worker` + UFCS functions is the right shape; nested functions are for helpers inside one function.
- **[D] There is no privacy** ("There is no privacy, no re-export and no nesting of namespaces", reference; "Goose currently lacks field privacy:
  internal-field conventions and checked indexing preserve memory safety", root_structs.md). A leading underscore is OUR convention (the user's call), not the author's: his stdlib has no
  underscore names. Keep it, and say so in the README.
- **[D] Several growables in one value: `root struct`** (slot_pool, slice_pool are the author's examples; fields are plain, no privacy).
- **Not from the author (do not rely on):** "opaque handle + validating API" as a privacy pattern; "private helper = nested fn" at namespace level;
  the chat's `import image.filters;` form and its `PI  s.r  s.r` example (its multiplication signs were lost).
