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
