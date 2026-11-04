// The C layer, bound for tcprouter's own use. Internal: not part of the public API. One place for every
// `extern fn`, with the struct layouts they share with C. Every function returns a negative errno on failure
// (-11, EAGAIN, means "not now"), which src/c_sys.c arranges because errno is thread-local.
namespace tcprouter;

// struct epoll_event as the C layer fills it: packed, 12 bytes (checked there by _Static_assert and in
// tests/unit/package_smoke_test.goose).
struct router_EpollEvent { events: u32, data: u64 }

let ROUTER_EPOLL_IN: u32 = 0x001;
let ROUTER_EPOLL_OUT: u32 = 0x004;
let ROUTER_EPOLL_ERROR: u32 = 0x008;
let ROUTER_EPOLL_HANGUP: u32 = 0x010;
let ROUTER_EPOLL_CTL_ADD: i32 = 1;
let ROUTER_EPOLL_CTL_DEL: i32 = 2;
let ROUTER_EPOLL_CTL_MOD: i32 = 3;

let ROUTER_ERRNO_AGAIN: i32 = 11;
let ROUTER_ERRNO_INTERRUPTED: i32 = 4;
let ROUTER_ERRNO_ADDRESS_IN_USE: i32 = 98;

extern fn router_epoll_create() -> i32 = "c_epoll_create";
extern fn router_epoll_control(ep: i32, op: i32, fd: i32, events: u32, data: u64) -> i32 = "c_epoll_ctl";
extern fn router_epoll_wait(ep: i32, out: router_EpollEvent&, max: i32, timeout_ms: i32) -> i32 = "c_epoll_wait";

// Sockets. `ip` is 4 bytes (IPv4) or 16 (IPv6) in network order, `v6` says which.
extern fn router_socket_listen(v6: bool, ip: const u8[16]&, port: u16, reuseport: bool, backlog: i32) -> i32 = "c_listen";
extern fn router_socket_accept(lfd: i32) -> i32 = "c_accept";
extern fn router_socket_connect_start(v6: bool, ip: const u8[16]&, port: u16) -> i32 = "c_connect_start";
extern fn router_socket_connect_result(fd: i32) -> i32 = "c_connect_result";
extern fn router_socket_receive(fd: i32, buf: u8&, len: i64) -> i64 = "c_recv";
extern fn router_socket_send(fd: i32, buf: const u8&, len: i64) -> i64 = "c_send";
extern fn router_socket_shutdown_write(fd: i32) = "c_shutdown_wr";
extern fn router_socket_close(fd: i32) = "c_close";
extern fn router_socket_reset(fd: i32) = "c_reset";
extern fn router_error_text(out: u8[>..]&, err: i32) = "c_strerror";

extern fn router_signals_block_and_open() -> i32 = "c_signals_open";
extern fn router_signal_wait(fd: i32) -> i32 = "c_signal_wait";

// CLOCK_BOOTTIME in milliseconds: counts through suspend (RT-6c).
extern fn router_boottime_milliseconds() -> i64 = "c_boottime_ms";
