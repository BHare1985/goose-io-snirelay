# Test results (goose dcaf1ef, gcc 15.2.0, Linux). All commands were actually run.

Run with `../bin/goose build tNN.goose && ./tNN`. `t02` needs `python3 t02_test.py`.

| Program | What | Result |
|---|---|---|
| t01_ffi_socketpair | libc `socketpair/send/recv/close` via `extern fn`, fixed-array scratch | `goose check` clean; `build` OK; output `received 28 bytes…`, EOF → `recv returns 0`. `goose run` fails: `unresolved reference to 'socketpair'` (TinyCC). `check --stats`: bce 7/8 index elided |
| t02_tcp_proxy + t02_test.py | TCP forwarder: accept loop, 4 `thread_fn` workers, typed queue, `poll` relay, half-close | After fixing two of *my* bugs (early return on first EOF; clobbering `fds[i].fd`): 12 concurrent clients × 300 000 random bytes echoed byte-exact via 4 workers, `failures=[]`. Upstream-down: client gets EOF, proxy survives, logs `worker 0: upstream connect failed`. `--stats`: bce 12/13 index, 0/2 slice (kept: `buf[..n]` after `recv`). `--stacks`: 2 data stacks/worker, cap 8186 workers |
| t03_epoll | `epoll_create1/ctl/wait`, packed `EpollEvent`, `SOCK_NONBLOCK` | `sizeof` check = 12 passed; ready event data/events correct; empty nonblocking `recv` = -1 |
| t04_conn_registry | `slot_pool<ConnState>` with inline `u8[..256]`, free/reuse, hostile index lookup | slot reuse `true`, index 999 → null, freed slot → null |
| (adhoc) `extern "c"` | `getpid`, `write` through dlopen | fails without sidecar (`libc.so: invalid ELF header`); works under both `run` and `build` with `dylibs_linux = ["c=libc.so.6"];` |
| (adhoc) `defer` | block-exit defer | prints `body`, `deferred`, `after` |
| (adhoc) std import | `split` w/o `import std;` | `unknown function: split` |

## Not done (out of scope after the user narrowed the work to the TCP-proxy design)
String builder, frequency counter with `dictionary`, variable-size record array, relative-ref tree, index-type graph,
`slice_pool` child lists, nested-function parser with `return … from`, `from_bytes` untrusted input,
`thread_spawn_contained` supervisor, `--debug` runs, benchmarks vs C.
