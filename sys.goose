// The C layer, bound for tcprouter's own use. Internal: not part of the public API. One place for every
// `extern fn`, with the struct layouts they share with C. Every function returns a negative errno on failure
// (a -EAGAIN of -11 means "not now"), which src/c_sys.c arranges because errno is thread-local.
namespace tcprouter_sys;

// struct epoll_event as the C layer fills it: packed, 12 bytes (checked there by _Static_assert and in
// tests/unit/package_smoke_test.goose).
struct EpollEvent { events: u32, data: u64 }

let EPOLLIN: u32 = 0x001;
let EPOLLOUT: u32 = 0x004;
let EPOLLERR: u32 = 0x008;
let EPOLLHUP: u32 = 0x010;
let EPOLL_CTL_ADD: i32 = 1;
let EPOLL_CTL_DEL: i32 = 2;
let EPOLL_CTL_MOD: i32 = 3;

let EAGAIN: i32 = 11;
let EINTR: i32 = 4;
let EADDRINUSE: i32 = 98;

extern fn c_epoll_create() -> i32;
extern fn c_epoll_ctl(ep: i32, op: i32, fd: i32, events: u32, data: u64) -> i32;
extern fn c_epoll_wait(ep: i32, out: EpollEvent&, max: i32, timeout_ms: i32) -> i32;

// Sockets. `ip` is 4 bytes (IPv4) or 16 (IPv6) in network order, `v6` says which.
extern fn c_listen(v6: bool, ip: const u8[16]&, port: u16, reuseport: bool, backlog: i32) -> i32;
extern fn c_accept(lfd: i32) -> i32;
extern fn c_connect_start(v6: bool, ip: const u8[16]&, port: u16) -> i32;
extern fn c_connect_result(fd: i32) -> i32;
extern fn c_recv(fd: i32, buf: u8&, len: i64) -> i64;
extern fn c_send(fd: i32, buf: const u8&, len: i64) -> i64;
extern fn c_shutdown_wr(fd: i32);
extern fn c_close(fd: i32);
extern fn c_reset(fd: i32);
extern fn c_strerror(out: u8[>..]&, err: i32);

extern fn c_signals_open() -> i32;
extern fn c_signal_wait(fd: i32) -> i32;

// CLOCK_BOOTTIME in milliseconds: counts through suspend (RT-6c).
extern fn c_boottime_ms() -> i64;
