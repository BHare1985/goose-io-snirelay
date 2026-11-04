// libc and the C layer, bound for tcprouter's own use. Internal: not part of the public API.
// One place for every `extern fn`, with the struct layouts they share with C.
namespace tcprouter_sys;

// struct epoll_event as the C layer in src/tr_sys.c fills it: packed, 12 bytes (checked there by
// _Static_assert and in tests/unit/package_smoke_test.goose).
struct EpollEvent { events: u32, data: u64 }

extern fn tr_epoll_create() -> i32;
extern fn tr_epoll_ctl(ep: i32, op: i32, fd: i32, events: u32, data: u64) -> i32;
extern fn tr_epoll_wait(ep: i32, out: EpollEvent&, max: i32, timeout_ms: i32) -> i32;

// CLOCK_BOOTTIME in milliseconds: counts through suspend (RT-6c).
extern fn tr_boottime_ms() -> i64;
