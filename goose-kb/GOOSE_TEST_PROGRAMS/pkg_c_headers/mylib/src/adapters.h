#ifndef MYLIB_ADAPTERS_H
#define MYLIB_ADAPTERS_H
#include <stdint.h>
#include <time.h>
#include <sys/epoll.h>

/* Goose's types arrive before this header: mylib::EpollEv is mylib_EpollEv_g5 with events_g, data_g. */
static inline int32_t tr_epoll_create(void) { return epoll_create1(0); }

static inline int32_t tr_epoll_add(int32_t ep, int32_t fd, uint32_t events, uint64_t data) {
    struct epoll_event ev;
    ev.events = events;
    ev.data.u64 = data;
    return epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
}

/* The kernel's struct epoll_event is packed on x86-64 only; copying through the real type is right everywhere. */
static inline int32_t tr_epoll_wait(int32_t ep, mylib_EpollEv_g5 *out, int32_t max, int32_t timeout_ms) {
    struct epoll_event tmp[64];
    if (max > 64) max = 64;
    int n = epoll_wait(ep, tmp, max, timeout_ms);
    for (int i = 0; i < n; i++) { out[i].events_g = tmp[i].events; out[i].data_g = tmp[i].data.u64; }
    return n;
}

static inline int64_t tr_boottime_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_BOOTTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static inline int32_t tr_sizeof_epoll_event(void) { return (int32_t)sizeof(struct epoll_event); }
#endif
