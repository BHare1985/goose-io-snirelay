# M0 answers (O-1 … O-6, plus O-8 and O-10). goose dcaf1ef, gcc 15.2.0. All programs in this directory were compiled and run.

| id | Answer | Evidence |
|---|---|---|
| **O-1** generic call on a policy type | **YES.** `serve<P, F>(w, p: P&)` calls `p.pick(7)` (UFCS); it resolves at compile time in the *type's* namespace. Two policy types in two namespaces, no interface declaration. A plain `pick(p, 7)` would look in the namespace of the engine, so the engine must use the method form. | `o156_engine_shape.goose`: `policy A … tick(107)`, `policy B … tick(99)` |
| **O-2** broadcast to workers | **No per-thread queue.** `qput` reaches ONE receiver (typed queue per type; 4 jobs → 4 completions). Pipes work: main makes N `pipe2` pairs **before** spawning and passes each worker its read fd; `post` writes a 17-byte message to every write end (atomic ≤ PIPE_BUF). Each of 4 workers got it exactly once, 3/3 runs. | `o24_workers_broadcast.goose` |
| **O-3** stable growth under the kernel | **YES, with `push`/`append`.** A reference into a `u8[>..]` stays valid after 64 MB of `append`; `recv` through the OLD reference landed in the array. **`resize` is rejected while a reference is live** ("cannot resize pool while first is still used": resize may shrink). So: size the pool once up front, hand out sub-slices; if it must grow, use `append`. | `o3_stable_buffers.goose` |
| **O-4** `thread_fn` arguments | **YES.** `thread_fn worker(cfg: Config, index: i64, msg_fd: i32)`; `thread_spawn(worker, cfg, i, fd)`. A 66 KB flat Config (256 routes, enums with 253-byte names) copies in fine. | `o24_workers_broadcast.goose`: "Config size in bytes: 66314", workers saw 200 routes |
| **O-5** enum/ADT syntax | **YES, struct-like payloads.** `enum Event { Opened { conn: Conn, tag: u16 }, Data { conn: Conn, bytes: const u8[:] }, … }`. Read with `match ev { Opened o => o.conn.slot, Data d => d.bytes, … }`. Gotchas: (a) a variant literal has the *variant's* type: `let e: Event = Event.Opened {…}` is needed to `match` on it; (b) **`match` is a keyword**: a field named `match` (doc 02's `Route.match`) is a parse error → use `on`/`when`; (c) a slice payload is fine. | `o156_engine_shape.goose`, `o24_…` |
| **O-6** block calls library fns with the worker | **YES.** `serve(w, p) { w, ev => … send(w, d.conn, d.bytes) … }`; the block gets `w` by reference and mutates it (`w.sent`, `w.scratch`). | `o156_engine_shape.goose`: `sent=5 scratch=hello` |
| **O-8** SIGTERM without callbacks | **YES, no C needed.** `sigprocmask(BLOCK)` + `signalfd` in main before spawning (workers inherit the mask), `sigset_t` as `u8[128]`. `read` on the signalfd returned 128 bytes with `ssi_signo = 15`. | `o8_signalfd.goose` |
| **O-10** package layout | Entry `tcprouter.goose` (`namespace tcprouter;`), same namespace in every file, inside the package `import .sni;`, tests/examples are roots with `import tcprouter from "../..";`, `@v0` git import works and builds package C. See `../../GOOSE_PACKAGES_AND_C.md`. | `../pkg_c_headers`, `../pkg_c_sources` |
| O-7, O-9 | not part of M0; O-7 is implementation detail (will test with the engine), O-9 is a licence question. | |

## Things the design must change (all [V])
1. **`worker()` cannot return the worker.** The worker needs several growable tables (slots, free list, buffer pool, output queues).
   An ordinary struct allows one resizable field; the answer is a **`root struct Worker`**, and a root **cannot be returned by value**
   ("root struct W can only be owned by a local or global variable; return a reference instead"). So the shape is:
   `var w = tcprouter::Worker { .. }; if !tcprouter::start(w, cfg, index) { … }` (start binds sockets, returns false/err on failure).
2. **A root cannot contain `slot_pool`** ("nested root owners are not supported"). The engine keeps its own `Slot[>..]` plus a free-list
   `u32[>..<]` inside the Worker root. (slot_pool still fine for user code that owns its own pool as a local.)
3. **`Route.match` → another name** (keyword).
4. `Event.Data` etc. need an annotated binding (`let e: Event = …`) in the engine before calling the block.
5. Package C: `c_sources` works under both `goose run` and `goose build`; `c_headers` adapters need system headers that TinyCC can't find on this machine, so `run` fails. The skeleton uses `c_sources`. (epoll_event layout is thereby handled for arm64.)
