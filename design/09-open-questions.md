# 09 — Open questions (Goose facts to verify)

Each is something this design assumes. Brian checks it with a small program in
`goose-kb/GOOSE_TEST_PROGRAMS/` before relying on it, records the result there, and tells Charlie
if the answer changes the design.

| id | Assumption | Used by | If false |
|---|---|---|---|
| O-1 | A generic function can call free functions on its generic parameter's type, resolved at compile time (`pick(p, …)` with `p` of any policy type) | doc 07, `serve(w, p)` | Policy becomes an enum of known kinds (built-in, tcpproxy, test double), dispatched by `switch` |
| O-2 | No per-thread queue exists, so broadcast needs a pipe per worker | doc 03 §7 | Use the per-thread queue if there is one |
| O-3 | A growable array can be grown without moving earlier elements (goose-kb: "≤1 resizable per stack, topmost, never moves") — and whether that holds while the kernel writes into it | doc 03 §4 | Design already avoids it: the pool is fixed at start |
| O-4 | `thread_fn` can take arguments (config value, worker index), or how a worker gets its config | doc 02 §3 | Pass config through a queue message at start |
| O-5 | ADT/enum syntax with payloads, and `switch` on it, as written in doc 02 | doc 02, 04 | Syntax only |
| O-6 | A block passed to `serve` can call library functions that take the worker by reference (`w` passed into the block, not captured) | doc 02 §4 | Pass actions back as a return value from the block |
| O-7 | `MSG_PEEK` + epoll edge vs level triggering for the inspect state; the C proxy uses edge-triggered epoll | doc 03 | Implementation detail |
| O-8 | How to install a SIGTERM/SIGINT handler without function pointers (signalfd in epoll, through a C sidecar if `sigprocmask` is awkward) | RT-8c | C sidecar |
| O-9 | gslib's licence (not stated in its README) | example B only | Example uses another TLS path; tcprouter never depends on gslib |
| O-10 | Package layout for a library with submodules (gslib uses `gslib::http`) and versioned import `@v0` | doc 06 layout | Follow whatever goose-libdeflate and gslib do |
