# 09 — Open questions (Goose facts to verify)

Each is something this design assumes. Brian checks it with a small program in
`goose-kb/GOOSE_TEST_PROGRAMS/` before relying on it, records the result there, and tells Charlie
if the answer changes the design.

| id | Assumption | Used by | If false | Answer (Brian, 2026-11-04) |
|---|---|---|---|---|
| O-1 | A generic function can call free functions on its generic parameter's type, resolved at compile time (`pick(p, …)` with `p` of any policy type) | doc 07, `serve(w, p)` | Policy becomes an enum of known kinds (built-in, tcpproxy, test double), dispatched by `switch` | **Yes [V]**: engine calls `p.pick(…)` (UFCS) on its generic parameter; resolved in the type's namespace. `goose-kb/GOOSE_TEST_PROGRAMS/m0/o156_engine_shape.goose` |
| O-2 | No per-thread queue exists, so broadcast needs a pipe per worker | doc 03 §7 | Use the per-thread queue if there is one | **No per-thread queue; pipes work [V]**; created by `spawn` before the workers start. `m0/o24_workers_broadcast.goose` |
| O-3 | A growable array can be grown without moving earlier elements (goose-kb: "≤1 resizable per stack, topmost, never moves") — and whether that holds while the kernel writes into it | doc 03 §4 | Design already avoids it: the pool is fixed at start | **Yes with `push`/`append` [V]**; `resize` is refused while a reference is live. Pool sized once at start. `m0/o3_stable_buffers.goose` |
| O-4 | `thread_fn` can take arguments (config value, worker index), or how a worker gets its config | doc 02 §3 | Pass config through a queue message at start | **Yes [V]**: 66 KB flat Config by value into `thread_fn(cfg, index)`. `m0/o24_…` |
| O-5 | ADT/enum syntax with payloads, and `switch` on it, as written in doc 02 | doc 02, 04 | Syntax only | **Yes, struct-like payloads [V]**; `match` binds payloads; `match` is a keyword (field `on`); annotate variant literals (`let e: Event = …`) |
| O-6 | A block passed to `serve` can call library functions that take the worker by reference (`w` passed into the block, not captured) | doc 02 §4 | Pass actions back as a return value from the block | **Yes [V]**: the block gets `w` by reference. `m0/o156_…` |
| O-7 | `MSG_PEEK` + epoll edge vs level triggering for the inspect state; the C proxy uses edge-triggered epoll | doc 03 | Implementation detail | open (implementation detail; tested with the engine) |
| O-8 | How to install a SIGTERM/SIGINT handler without function pointers (signalfd in epoll, through a C sidecar if `sigprocmask` is awkward) | RT-8c | C sidecar | **Yes, no C [V]**: `sigprocmask` + `signalfd`, `sigset_t` as `u8[128]`. `m0/o8_signalfd.goose` |
| O-9 | gslib's licence (not stated in its README) | example B only | Example uses another TLS path; tcprouter never depends on gslib | open |
| O-10 | Package layout for a library with submodules (gslib uses `gslib::http`) and versioned import `@v0` | doc 06 layout | Follow whatever goose-libdeflate and gslib do | **Yes [V]**: `namespace tcprouter;` in every file, `import .sni;` inside, tests/examples import `from "../.."`/`".."`, `@v0` git import builds package C. `goose-kb/GOOSE_PACKAGES_AND_C.md` |
