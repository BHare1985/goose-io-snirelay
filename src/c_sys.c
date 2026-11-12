/* The C layer of tcprouter: only what Goose cannot bind straight to libc.
 *
 * Why C at all (the rules are in goose-kb/GOOSE_PACKAGES_AND_C.md):
 *   - struct epoll_event is packed on x86-64 and NOT on arm64, so Goose (whose structs are always packed)
 *     fills the same 12-byte record on both and this file copies to and from the real type;
 *   - errno is thread-local and libc returns -1: Goose wants the error as a negative number, so every call
 *     here returns -errno on failure;
 *   - sockaddr is built here from (family, ip bytes, port), so no layout is shared with Goose;
 *   - signalfd and sigprocmask take opaque sigset_t values;
 *   - CLOCK_BOOTTIME and struct timespec are constants and a struct, not plain integers.
 * Everything here is a thin, thread-safe wrapper over one syscall. Nothing keeps a pointer.
 * Descriptors are non-blocking and close-on-exec from birth (SOCK_NONBLOCK, SOCK_CLOEXEC).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/epoll.h>
#include <sys/signalfd.h>
#include <sys/socket.h>

#include "goose.h"

/* Must match `EpollEvent` in sys.goose: { events: u32, data: u64 }, packed. */
typedef struct __attribute__((packed)) { uint32_t events; uint64_t data; } c_epoll_event;
_Static_assert(sizeof(c_epoll_event) == 12, "c_epoll_event must be 12 bytes, as Goose lays out EpollEvent");

#define C_MAX_EVENTS 256

/* --- epoll ------------------------------------------------------------------------------------------- */

int32_t c_epoll_create(void) {
    int fd = epoll_create1(EPOLL_CLOEXEC);
    return fd < 0 ? -errno : fd;
}

int32_t c_epoll_ctl(int32_t ep, int32_t op, int32_t fd, uint32_t events, uint64_t data) {
    struct epoll_event ev;
    ev.events = events;
    ev.data.u64 = data;
    return epoll_ctl(ep, op, fd, &ev) < 0 ? -errno : 0;
}

/* Returns the number of events written to `out` (at most `max` and C_MAX_EVENTS), 0 when interrupted, or -errno. */
int32_t c_epoll_wait(int32_t ep, c_epoll_event *out, int32_t max, int32_t timeout_ms) {
    struct epoll_event tmp[C_MAX_EVENTS];
    if (max > C_MAX_EVENTS) max = C_MAX_EVENTS;
    if (max < 1) return -EINVAL;
    int n = epoll_wait(ep, tmp, max, timeout_ms);
    if (n < 0) return errno == EINTR ? 0 : -errno;
    for (int i = 0; i < n; i++) {
        out[i].events = tmp[i].events;
        out[i].data = tmp[i].data.u64;
    }
    return n;
}

/* --- sockets ----------------------------------------------------------------------------------------- */

static socklen_t fill_addr(struct sockaddr_storage *ss, uint8_t v6, const uint8_t *ip, uint16_t port) {
    memset(ss, 0, sizeof *ss);
    if (v6) {
        struct sockaddr_in6 *a = (struct sockaddr_in6 *)ss;
        a->sin6_family = AF_INET6;
        a->sin6_port = htons(port);
        memcpy(&a->sin6_addr, ip, 16);
        return sizeof *a;
    }
    struct sockaddr_in *a = (struct sockaddr_in *)ss;
    a->sin_family = AF_INET;
    a->sin_port = htons(port);
    memcpy(&a->sin_addr, ip, 4);
    return sizeof *a;
}

/* A listening socket: returns its fd, or -errno. IPv6 listeners are v6-only (v4 has its own listener). */
int32_t c_listen(uint8_t v6, const uint8_t *ip, uint16_t port, uint8_t reuseport, int32_t backlog) {
    int fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return -errno;
    int one = 1, err = 0;
    struct sockaddr_storage ss;
    socklen_t len = fill_addr(&ss, v6, ip, port);
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one) < 0) err = errno;
    else if (reuseport && setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one) < 0) err = errno;
    else if (v6 && setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one) < 0) err = errno;
    else if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one) < 0) err = errno;   /* accepted sockets inherit it */
    else if (bind(fd, (struct sockaddr *)&ss, len) < 0) err = errno;
    else if (listen(fd, backlog) < 0) err = errno;
    if (err) { close(fd); return -err; }
    return fd;
}

/* Accepts one connection: its fd (non-blocking, TCP_NODELAY), or -errno (-EAGAIN when none is waiting). */
int32_t c_accept(int32_t lfd) {
    int fd = accept4(lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (fd < 0) return -errno;
    return fd;                                   /* TCP_NODELAY is inherited from the listening socket (c_listen) */
}

/* Starts a non-blocking connect: the socket's fd with the connect in progress (or already done), or -errno.
   Writability of the fd, then c_connect_result, tells how it ended. */
int32_t c_connect_start(uint8_t v6, const uint8_t *ip, uint16_t port) {
    int fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return -errno;
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    struct sockaddr_storage ss;
    socklen_t len = fill_addr(&ss, v6, ip, port);
    if (connect(fd, (struct sockaddr *)&ss, len) < 0 && errno != EINPROGRESS) {
        int err = errno;
        close(fd);
        return -err;
    }
    return fd;
}

/* How a connect ended: 0 for success, else the errno. */
int32_t c_connect_result(int32_t fd) {
    int err = 0;
    socklen_t len = sizeof err;
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) < 0) return errno;
    return err;
}

/* Bytes read, 0 at end of stream, or -errno (-EAGAIN when nothing is waiting). */
int64_t c_recv(int32_t fd, uint8_t *buf, int64_t len) {
    ssize_t n = recv(fd, buf, (size_t)len, 0);
    return n < 0 ? -errno : n;
}

/* Bytes sent, or -errno. MSG_NOSIGNAL: a closed peer is an error return, never SIGPIPE. */
int64_t c_send(int32_t fd, const uint8_t *buf, int64_t len) {
    ssize_t n = send(fd, buf, (size_t)len, MSG_NOSIGNAL);
    return n < 0 ? -errno : n;
}

/* Like c_recv but the bytes stay queued in the socket (MSG_PEEK): the ClientHello is read without being consumed. */
int64_t c_peek(int32_t fd, uint8_t *buf, int64_t len) {
    ssize_t n = recv(fd, buf, (size_t)len, MSG_PEEK);
    return n < 0 ? -errno : n;
}

/* Wake the socket's readers only when at least `bytes` are queued (or the peer ends): how a short ClientHello waits
   for the rest without a timer and without being read again and again. 1 is the default. Returns 0 or -errno. */
int32_t c_set_rcvlowat(int32_t fd, int32_t bytes) {
    return setsockopt(fd, SOL_SOCKET, SO_RCVLOWAT, &bytes, sizeof bytes) < 0 ? -errno : 0;
}

void c_shutdown_wr(int32_t fd) { shutdown(fd, SHUT_WR); }
void c_close(int32_t fd) { close(fd); }

/* Close with an RST instead of a FIN. */
void c_reset(int32_t fd) {
    struct linger lg = { 1, 0 };
    setsockopt(fd, SOL_SOCKET, SO_LINGER, &lg, sizeof lg);
    close(fd);
}

/* Appends strerror(err) to a Goose byte builder. */
void c_strerror(gs_rref out, int32_t err) {
    const char *s = strerror(err);
    gs_bld_append(out, s, (int64_t)strlen(s));
}

/* --- the batching window (RT-16) ---------------------------------------------------------------------- */

/* Waits up to `us` microseconds for `fd` to become readable (a worker's message pipe), and returns the microseconds actually waited (-1 on error).
   A message arriving ends the wait at once: that is the point of waiting on the pipe and not sleeping. */
int64_t c_wait_readable_us(int32_t fd, int64_t us) {
    struct timespec t0, t1, to;
    struct pollfd p;
    p.fd = fd; p.events = POLLIN; p.revents = 0;
    to.tv_sec = us / 1000000; to.tv_nsec = (us % 1000000) * 1000;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    int rc = ppoll(&p, 1, &to, NULL);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    if (rc < 0 && errno != EINTR) return -1;
    return (int64_t)(t1.tv_sec - t0.tv_sec) * 1000000 + (t1.tv_nsec - t0.tv_nsec) / 1000;
}

/* --- signals ----------------------------------------------------------------------------------------- */

/* Blocks SIGTERM and SIGINT in the calling thread (threads started later inherit that) and returns a
   signalfd that reports them, or -errno. Call it before starting any worker. */
int32_t c_signals_open(void) {
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGTERM);
    sigaddset(&set, SIGINT);
    sigaddset(&set, SIGUSR1);          /* a program may drain on SIGUSR1 (wait_for_signal returns the number) */
    int rc = pthread_sigmask(SIG_BLOCK, &set, NULL);
    if (rc != 0) return -rc;
    int fd = signalfd(-1, &set, SFD_CLOEXEC);
    return fd < 0 ? -errno : fd;
}

/* Waits until a signal arrives on the signalfd; returns its number, or -errno. */
int32_t c_signal_wait(int32_t fd) {
    struct signalfd_siginfo si;
    for (;;) {
        ssize_t n = read(fd, &si, sizeof si);
        if (n == (ssize_t)sizeof si) return (int32_t)si.ssi_signo;
        if (n < 0 && errno != EINTR) return -errno;
    }
}

/* --- pipes (messages to workers) ---------------------------------------------------------------------- */

/* A pipe, close-on-exec, whose READ end is non-blocking (a worker polls it from epoll); the write end blocks. 0 or -errno. */
int32_t c_pipe(int32_t *fds) {
    if (pipe2(fds, O_CLOEXEC) < 0) return -errno;
    return fcntl(fds[0], F_SETFL, O_NONBLOCK) < 0 ? -errno : 0;
}

int64_t c_pipe_write(int32_t fd, const uint8_t *buf, int64_t len) {
    ssize_t n = write(fd, buf, (size_t)len);
    return n < 0 ? -errno : n;
}

int64_t c_pipe_read(int32_t fd, uint8_t *buf, int64_t len) {
    ssize_t n = read(fd, buf, (size_t)len);
    return n < 0 ? -errno : n;
}

/* --- clock ------------------------------------------------------------------------------------------- */

/* CLOCK_BOOTTIME in milliseconds: counts through suspend (RT-6c). */
int64_t c_boottime_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_BOOTTIME, &ts) != 0) return -1;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
