// The C layer, bound for tcprouter's own use. Not part of the public API. One place for every `extern fn`, with the
// struct layouts and constants they share with C. Everything here comes from C, so everything here is named c_...,
// exactly as in src/c_sys.c. Every function returns a negative errno on failure
// (-11, EAGAIN, means "not now"), which src/c_sys.c arranges because errno is thread-local.
namespace tcprouter;

// struct epoll_event as the C layer fills it: packed, 12 bytes (checked there by _Static_assert and in
// tests/unit/package_smoke_test.goose).
struct c_EpollEvent { events: u32, data: u64 }

let c_EPOLLIN: u32 = 0x001;
let c_EPOLLOUT: u32 = 0x004;
let c_EPOLLERR: u32 = 0x008;
let c_EPOLLHUP: u32 = 0x010;
let c_EPOLLRDHUP: u32 = 0x2000;
let c_EPOLLET: u32 = 0x80000000;
let c_EPOLL_CTL_ADD: i32 = 1;
let c_EPOLL_CTL_DEL: i32 = 2;
let c_EPOLL_CTL_MOD: i32 = 3;

let c_EAGAIN: i32 = 11;
let c_EINTR: i32 = 4;
let c_EADDRINUSE: i32 = 98;
let c_ECONNABORTED: i32 = 103;
let c_EPROTO: i32 = 71;

extern fn c_epoll_create() -> i32;
extern fn c_epoll_ctl(ep: i32, op: i32, fd: i32, events: u32, data: u64) -> i32;
extern fn c_epoll_wait(ep: i32, out: c_EpollEvent&, max: i32, timeout_ms: i32) -> i32;

// Sockets. `ip` is 4 bytes (IPv4) or 16 (IPv6) in network order, `v6` says which.
extern fn c_listen(v6: bool, ip: const u8[16]&, port: u16, reuseport: bool, backlog: i32) -> i32;
extern fn c_accept(lfd: i32) -> i32;
extern fn c_connect_start(v6: bool, ip: const u8[16]&, port: u16) -> i32;
extern fn c_connect_result(fd: i32) -> i32;
extern fn c_recv(fd: i32, buf: u8&, len: i64) -> i64;
extern fn c_send(fd: i32, buf: const u8&, len: i64) -> i64;
extern fn c_peek(fd: i32, buf: u8&, len: i64) -> i64;
extern fn c_set_rcvlowat(fd: i32, bytes: i32) -> i32;
extern fn c_shutdown_wr(fd: i32);
extern fn c_close(fd: i32);
extern fn c_reset(fd: i32);
extern fn c_strerror(out: u8[>..]&, err: i32);

extern fn c_pipe(fds: i32[2]&) -> i32;
extern fn c_pipe_write(fd: i32, buf: const u8&, len: i64) -> i64;
extern fn c_pipe_read(fd: i32, buf: u8&, len: i64) -> i64;

extern fn c_wait_readable_us(fd: i32, us: i64) -> i64;
extern fn c_signals_open() -> i32;
extern fn c_signal_wait(fd: i32) -> i32;

// CLOCK_BOOTTIME in milliseconds: counts through suspend (RT-6c).
extern fn c_boottime_ms() -> i64;
