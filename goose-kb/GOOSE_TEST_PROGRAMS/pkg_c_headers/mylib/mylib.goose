// Experiment: a package whose C is a header of static-inline adapters (c_headers).
namespace mylib;

import .inner;

// The Goose-side type the adapter fills in. The C spelling is mylib_EpollEv_g5 with fields events_g, data_g.
struct EpollEv { events: u32, data: u64 }

extern fn tr_epoll_create() -> i32;
extern fn tr_epoll_add(ep: i32, fd: i32, events: u32, data: u64) -> i32;
extern fn tr_epoll_wait(ep: i32, out: EpollEv&, max: i32, timeout_ms: i32) -> i32;
extern fn tr_boottime_ms() -> i64;
extern fn tr_sizeof_epoll_event() -> i32;
// libc with plain C shape, bound directly
extern fn pipe2(fds: i32[2]&, flags: i32) -> i32;
extern fn write(fd: i32, buf: const u8&, n: u64) -> i64;
extern fn read(fd: i32, buf: u8&, n: u64) -> i64;

fn selftest() -> bool {
    var fds: i32[2] = [0, 0];
    if pipe2(fds, 0) != 0 { return false; }
    let ep = tr_epoll_create();
    if tr_epoll_add(ep, fds[0], 1, 0xABCDEF0123 as u64) != 0 { return false; }
    let m = "x";
    write(fds[1], m[0], 1);
    var evs: EpollEv[4] = [EpollEv { 0, 0 }; 4];
    let n = tr_epoll_wait(ep, evs[0], 4, 1000);
    print("ready=", n, " events=", evs[0].events, " data=", evs[0].data,
          " sizeof(epoll_event)=", tr_sizeof_epoll_event(), " helper=", twice(21),
          " boottime>0=", tr_boottime_ms() > 0);
    return n == 1 && evs[0].data == 0xABCDEF0123;
}
