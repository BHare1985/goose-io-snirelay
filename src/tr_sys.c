/* The C layer of tcprouter: only what Goose cannot bind straight to libc.
 *
 * Today that is the parts of libc whose argument types differ between architectures:
 *   - struct epoll_event is packed on x86-64 and NOT on arm64, so Goose (whose structs are always
 *     packed) fills the same 12-byte record on both and this file copies to and from the real type;
 *   - CLOCK_BOOTTIME and struct timespec are constants and a struct, not plain integers.
 * Everything here is a thin, thread-safe wrapper over one syscall. Nothing keeps a pointer.
 * See design/08-c-map.md and goose-kb/GOOSE_PACKAGES_AND_C.md.
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <time.h>
#include <sys/epoll.h>

/* Must match `EpollEvent` in sys.goose: { events: u32, data: u64 }, packed. */
typedef struct __attribute__((packed)) { uint32_t events; uint64_t data; } tr_epoll_event;
_Static_assert(sizeof(tr_epoll_event) == 12, "tr_epoll_event must be 12 bytes, as Goose lays out EpollEvent");

#define TR_MAX_EVENTS 256

int32_t tr_epoll_create(void) { return epoll_create1(EPOLL_CLOEXEC); }

int32_t tr_epoll_ctl(int32_t ep, int32_t op, int32_t fd, uint32_t events, uint64_t data) {
    struct epoll_event ev;
    ev.events = events;
    ev.data.u64 = data;
    return epoll_ctl(ep, op, fd, &ev);
}

/* Returns the number of events written to `out` (at most `max`, and at most TR_MAX_EVENTS), or -1. */
int32_t tr_epoll_wait(int32_t ep, tr_epoll_event *out, int32_t max, int32_t timeout_ms) {
    struct epoll_event tmp[TR_MAX_EVENTS];
    if (max > TR_MAX_EVENTS) max = TR_MAX_EVENTS;
    if (max < 1) return -1;
    int n = epoll_wait(ep, tmp, max, timeout_ms);
    for (int i = 0; i < n; i++) {
        out[i].events = tmp[i].events;
        out[i].data = tmp[i].data.u64;
    }
    return n;
}

int64_t tr_boottime_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_BOOTTIME, &ts) != 0) return -1;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
