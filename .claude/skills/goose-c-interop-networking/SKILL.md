---
name: goose-c-interop-networking
description: Binding libc/C from Goose and building network code (sockets, poll, epoll, threads, TCP proxies) in Goose. Use for any extern fn, sidecar .build file, C ABI layout, or socket/proxy design question in Goose.
---

# Goose C interop and networking (all verified in `goose-kb/GOOSE_TEST_PROGRAMS/`, see `GOOSE_TCP_PROXY_NOTES.md`)

- stdlib has **no networking**; bind libc with `extern fn name(...) -> T;` (optional `= "c_symbol"`).
- Crossable: scalars, flat fixed structs/arrays (packed, no padding), `T&` (pointer, never NULL), `T[:]` (`{data,len}`),
  `T[>..]&` builder. Pointer+length C APIs: pass `buf[0]` and `len` separately (guard empty).
- Not bindable: variadic (`fcntl`, `ioctl`), callbacks (`signal`), NULL pointers, returning refs/slices.
  Use flags (`SOCK_NONBLOCK`, `MSG_NOSIGNAL`) or a C sidecar (`foo.build`: `c_sources`, `c_headers`).
- Define constants and structs yourself; layouts: `SockAddrIn{u16,u16,u32,u8[8]}`=16, `Pollfd{i32,i16,i16}`=8,
  `EpollEvent{u32,u64}`=12 (packed, matches x86-64). Verify: `bytes_of(arr_of_one).len`. `htons` by hand.
- `goose run` (TinyCC) can't link libc/threads; use `goose build`. Or `extern "c" { ... }` plus sidecar
  `dylibs_linux = ["c=libc.so.6"];` for quick single-threaded runs.
- Concurrency: `thread_fn` workers (separate programs, copied globals, 2×2 GB reserved stacks each; `--stacks`),
  `qput/qget<Conn>` work queue, `qlimit` to shed load, fds are plain ints so they cross freely.
  Per-connection state: `slot_pool<ConnState>` with `u8[..N]` inline buffers, index = epoll data; validate indices from outside.
- Proxy correctness: handle EOF/error/partial send; half-close with `shutdown(SHUT_WR)`; blocking `send_all` can deadlock
  → production design uses non-blocking + POLLOUT. Working reference: `t02_tcp_proxy.goose` + `t02_test.py`.
