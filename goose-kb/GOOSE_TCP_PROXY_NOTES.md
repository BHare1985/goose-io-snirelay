# Designing a TCP proxy in Goose: findings

Everything here is **[V]** unless tagged. Working code: `GOOSE_TEST_PROGRAMS/t01..t04`.

## 1. Sockets come from libc through `extern fn`

stdlib has no sockets, `poll`, or `epoll`. Bind libc directly:

```goose
struct SockAddrIn { family: u16, port: u16, addr: u32, zero: u8[8] }   // 16 bytes, matches C
struct Pollfd { fd: i32, events: i16, revents: i16 }                   // 8 bytes, matches C
struct EpollEvent { events: u32, data: u64 }                           // 12 bytes = C's *packed* epoll_event

extern fn socket(domain: i32, kind: i32, protocol: i32) -> i32;
extern fn send(fd: i32, buf: const u8&, len: u64, flags: i32) -> i64;   // (ptr,len): pass buf[0] and the length
extern fn recv(fd: i32, buf: u8&, len: u64, flags: i32) -> i64;
extern fn poll(fds: Pollfd&, nfds: u64, timeout_ms: i32) -> i32;       // pass fds[0]
extern fn accept(fd: i32, addr: SockAddrIn&, len: u32&) -> i32;         // no NULL: give it real storage
```

Rules that mattered:
- **Pointer + length** = pass element 0 by reference plus the count: `send(fd, rest[0], rest.len as u64, flags)`.
  `rest[0]` on an empty slice is a bounds error, so guard `len > 0`.
- A `T&` parameter cannot be NULL. Functions that accept NULL (`accept`, `getsockname`) just get real storage.
- Goose structs are **packed with no padding**: this matches `sockaddr_in` and `pollfd` naturally and also
  matches the x86-64 *packed* `epoll_event`. On other ABIs verify with `bytes_of(arr).len` (12 here [V]).
  Use `pad`/`pad n` for C padding. Structs with `pad` cross **by reference only**.
- **Variadic C functions cannot be bound** (`fcntl`, `ioctl`, `open`). Get non-blocking via
  `SOCK_NONBLOCK` in `socket()/accept4()/socketpair()` flags instead [V] (t03).
- **Callbacks / function pointers cannot be bound** (`signal`). Avoid SIGPIPE with `MSG_NOSIGNAL` (0x4000)
  on `send` [V]. Anything needing C glue: write `foo.build` with `c_sources`/`c_headers`.
- Integer constants like `AF_INET`, `MSG_NOSIGNAL` are not available: define `let` constants yourself.
  `let X = 2;` is a *named constant* that adapts to any integer type [D]; typed `let X: i16 = 1;` doesn't.
- Network byte order: write `htons` by hand: `(p << 8) | (p >> 8)` on `u16` [V]. 127.0.0.1 as a LE `u32` = `0x0100007f`.
- Two ways to bind libc:
  1. Plain `extern fn` + `goose build`: works [V]. `goose run` (TinyCC) fails: `unresolved reference to 'socketpair'`.
  2. `extern "c" { fn getpid() -> i32; }` **plus sidecar** `prog.build` containing
     `dylibs_linux = ["c=libc.so.6"];` — then even `goose run` works [V]. Without the sidecar:
     `cannot load c (libc.so): invalid ELF header` (libc.so is a linker script) [V].
     Handy for fast iteration on single-threaded code.

## 2. Concurrency model fits a proxy, with a catch

Verified working design (t02): `main` does `accept()` and `qput(Conn{fd,..})`; N `thread_fn worker`s loop on
`qget<Conn>()`. One queue per *type*, shared by all workers → natural work-queue. `qlimit<Conn>(64)` makes
`qput` return `false` instead of blocking → shed load by closing the fd. A `Conn{ fd: -1 }` message stops a worker.

- File descriptors are just ints, so they cross threads freely (the kernel owns them, Goose doesn't).
- Each worker is a separate program with its own 2 data stacks of **2 GB reserved address space** each
  (`--stacks`: "thread cap: 8186 workers"). A thread-per-connection design is capped near 8k concurrent
  connections; a pool of workers each running an epoll loop avoids that. Reserve is configurable with
  `--stack-reserve` (e.g. `64M`) [D].
- Globals are **copied** into each worker at spawn; mutating one in a worker never affects `main`.
  There is no shared connection table: anything shared (stats, config) travels as messages. A worker that
  owns an epoll fd owns its connection state (use `slot_pool`, t04) — that is the idiomatic shape.
- `thread_spawn_contained` + `thread_wait(id, msg)` lets a supervisor log an aborted worker (assert failure,
  bounds error) and restart it, without taking the proxy down [D, not yet tested].
- The listening fd can't be "owned" by a worker pool without sharing; either `main` accepts (t02), or each
  worker gets the listen fd as an argument and calls `accept` itself (kernel load-balances) [R, untested].

## 3. Memory for buffers

- Per-connection I/O buffers: fixed arrays `u8[16384]` live on the *native* stack, no data stack involved [V t02].
  Inside persistent state use `u8[..N]` (inline limited array, fixed-size, usable as a struct field) [V t04].
- Growable `u8[>..]` is for builders (headers, logs). Only one resizable per data stack; the compiler assigns
  stacks, you never name them.
- A `T[:]` view of a buffer cannot outlive it, and cannot be stored in a queue message (not flat).
  Messages carrying bytes must hold owned arrays (`u8[]`, `u8[..N]`) [D].

## 4. Gotchas hit while building the proxy

| Symptom | Cause | Fix |
|---|---|---|
| `error: ! requires bool, got void` on `arg(i, s)` | `os::arg` returns nothing | check `arg_count()` first |
| Clients got 0 bytes / data truncated | **my logic bug**: I overwrote `fds[i].fd = -1` for EOF then read `fds[1-i].fd` as the destination | keep real fds in a separate `let socks: i32[2]` |
| Half-close dropped data | returned on first EOF | `shutdown(dst, SHUT_WR)`, stop polling that side, finish when both EOF (t02) |
| `cannot find the module slot_pool … no standard library` | compiler binary not next to `stdlib/` | symlink `build/stdlib` or set `GOOSE_STDLIB` (done: `bin/goose`) |
| Blocking `send_all` in `relay` | simple but can deadlock if both peers stop reading | real proxy: non-blocking + `POLLOUT`/`EPOLLOUT`, per-direction pending buffer |

## 5. Open design questions for the proxy [R]

1. epoll loop per worker (+ `slot_pool<Conn>` with inline buffers) vs. poll-per-connection threads (t02, simplest).
2. Routing table / config: `dictionary<const u8[:], …>` or a flat `u8[]`-keyed array built at startup; can't be
   mutated across threads, so hot-reload = message to each worker.
3. Parsing the first bytes (TLS SNI / HTTP Host) with `binary::Reader` (checked reads, no copies) [D].
4. Zero-copy: `splice`/`sendfile` are plain fixed-arity libc calls, bindable [R, untested].
