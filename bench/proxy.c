// io_uring TCP proxy and SNI router:  :PORT -> backends     (liburing >= 2.5 to build)
// io_uring: Linux >= 6.1 (socket options through the ring: 6.7). epoll fallback: any 64-bit Linux.
//
// Data-path modes (-m), all sharing one event loop per worker thread:
//
//   hybrid  (default) self-tuning per direction. Starts every direction in COPY (recv into a
//           shared provided-buffer pool, send out; ~0.1 syscalls per small message). When a
//           read brings at least -Z bytes (8 KiB: bulk), the direction switches to INLINE SPLICE;
//           after a few wakeups moving less than that, it switches back to COPY.
//   copy    COPY only (slow peers still spill into a pipe, see below).
//   isplice INLINE SPLICE only: io_uring reports readiness (POLL_ADD), and the loop calls
//           splice() socket->pipe->socket itself, right away, on its own thread.
//   splice  legacy: splice submitted through io_uring. The kernel runs it on io-wq helper
//           threads, which costs a context switch per hop. Kept for comparison.
//
// SNI routing (TLS passthrough, enabled by any -R): before the backend is connected, the client's
// TLS ClientHello is read with MSG_PEEK, so its bytes stay queued in the socket and the data path
// above forwards the whole stream untouched. The server_name picks the route; no SNI or an unknown
// name takes the default route (-b; none by default, so such clients are closed); non-TLS input is
// closed. A ClientHello still arriving raises SO_RCVLOWAT to the bytes still missing, so the loop
// sleeps until they are there instead of re-peeking. A client that sends nothing is closed after -T ms.
//
// Backends (see BACKENDS): a route has servers, given as IPs or DNS names (re-resolved; several
// addresses = replicas), plus backups used only while no local server is up. Local servers take
// turns; a refused or timed-out connect (--connect-timeout, a linked timeout) marks that server down
// and moves on to the next one, invisibly to the client. Health checks (tcp or http) and the DNS
// resolver run on two plain threads off the data path.
//
// No heap on the data path. Connections are a fixed pool of flat records addressed by
// (slot, generation), packed into each SQE's user_data. Data a slow peer cannot take yet is
// never kept in userspace: it is written into a pooled kernel pipe and that direction drains
// through splice, so the shared buffer pool can never be starved by stalled readers.
//
// This layout is deliberate: it maps 1:1 onto Goose (share-nothing thread per core, a
// grow-only Conn[] pool with a free-slot stack, no pointers between records, tagged dispatch
// instead of function pointers, liburing behind a small extern-fn shim).
//
// epoll (--io): where io_uring is unavailable (Docker's and containerd's default seccomp profiles,
// kernel.io_uring_disabled, kernels before 6.1, a low memlock limit), each worker runs the same data
// path on an edge-triggered epoll loop instead: see EPOLL ENGINE. --io auto (default) takes io_uring
// when it initialises and falls back per worker; the routing, backends, fence, control socket and
// timeouts are shared, so both behave the same.
//
// Build: gcc -O2 -pthread -o proxy proxy.c -luring
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sched.h>
#include <pthread.h>
#include <getopt.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/ioctl.h>
#include <sys/eventfd.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <sys/utsname.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <stdatomic.h>
#include <liburing.h>
#include <limits.h>
#include "gkproxy.h"

#ifndef IORING_RECVSEND_POLL_FIRST
#define IORING_RECVSEND_POLL_FIRST (1U << 0)
#endif

#define RING_ENTRIES   4096
#define CQ_ENTRIES     65536
#define BGID           1
#define PIPE_POOL_MAX  4096
#define PUMP_BUDGET    16          // splice calls per wakeup before yielding to other connections

enum { M_COPY, M_SPLICE, M_ISPLICE, M_HYBRID };
static const char *mode_name[] = { "copy", "splice", "isplice", "hybrid" };
enum { RING_AUTO, RING_DEFER, RING_COOP, RING_PLAIN };
enum { IO_AUTO, IO_URING, IO_EPOLL };

enum { CK_NONE, CK_TCP, CK_HTTP };
struct check { int kind; uint16_t port; char path[128]; };   // port 0 = the server's own port

static struct {
    int port, workers, pin, mode, ringmode, verbose;
    unsigned bufsz, nbufs, pipesz, iowq, maxconn, big_n, small_n, peek_ms, nroutes;
    unsigned drain_ms;             // --drain-timeout: how long a drain lets sessions finish
    int defer_accept, ring_socket, old_close, tfo, smart_ack, cut_on_down;   // shut: any listener's
    unsigned eof_probes, bulk, nlisteners;
    unsigned sweep_ms;             // idle / half-close sweep period, 0 = no listener has a timeout
    unsigned resolve_ms, hold_ms, dns_slots;
    int dns_family;                // --dns-family: AF_UNSPEC (any), AF_INET, AF_INET6
    int io;                        // --io: IO_AUTO (io_uring, else epoll), IO_URING, IO_EPOLL
    unsigned ep_sweep_ms;          // epoll: the sweep also enforces the hello and connect timeouts
    unsigned batch_n, batch_us;    // --batch N:US, 0 = off (see ring_loop / ep_loop)
} cfg = { .mode = M_HYBRID, .ringmode = RING_AUTO,
          .bufsz = 32768, .nbufs = 512, .pipesz = 262144, .maxconn = 65536,
          .big_n = 1, .small_n = 3, .peek_ms = 5000, .drain_ms = 30000, .eof_probes = 4, .ring_socket = 1,
          .bulk = 8192, .smart_ack = -1,
          .resolve_ms = 1000, .hold_ms = 1000, .dns_slots = 8 };

// Listeners, routes, targets, servers. All fixed once the workers run, except which addresses a
// target has and whether each one is up (see BACKENDS).
//   listener  a port. Its SNI routes are routes[first .. first+nroutes), and routes[first+nroutes]
//             is its default route (-b): "no SNI / unknown name" is one more index, and a default
//             route without targets rejects those clients. Without SNI routes it is plain TCP.
//   policy    per listener: how its servers are checked and what going down does.
//   target    "host:port" as configured, with a role (local or backup) and a policy. Routes that name
//             the same host, port, role and policy share the target, so its servers are checked
//             once and every listener sees the same health (e.g. :443 and :8443, or a fenced write
//             port reached locally and from the peer).
//   server    one address of a target (a DNS name has --dns-slots of them).
// An IPv4 or IPv6 address and port. fam 0 = none. Kept zeroed outside the address bytes, since
// policies (which hold one) are compared bytewise.
struct ep { uint16_t fam, port; uint8_t ip[16]; };
union sa { struct sockaddr sa; struct sockaddr_in v4; struct sockaddr_in6 v6; };

static socklen_t ep_sa(const struct ep *e, uint16_t port, union sa *o) {    // port 0 = e's own
    memset(o, 0, sizeof *o);
    if (e->fam == AF_INET6) {
        o->v6.sin6_family = AF_INET6; o->v6.sin6_port = htons(port ? port : e->port);
        memcpy(&o->v6.sin6_addr, e->ip, 16);
        return sizeof o->v6;
    }
    o->v4.sin_family = AF_INET; o->v4.sin_port = htons(port ? port : e->port);
    memcpy(&o->v4.sin_addr, e->ip, 4);
    return sizeof o->v4;
}

static int ep_ip(const char *s, struct ep *e) {               // an IPv4 or IPv6 literal, no port
    memset(e, 0, sizeof *e);
    if (inet_pton(AF_INET, s, e->ip) == 1) { e->fam = AF_INET; return 0; }
    if (inet_pton(AF_INET6, s, e->ip) == 1) { e->fam = AF_INET6; return 0; }
    return -1;
}

// "IP:PORT" | "[IPV6]:PORT"; with need_port 0 also a bare "IP" / "IPV6" / "[IPV6]"
static int ep_parse(const char *s, int need_port, struct ep *e) {
    char ip[INET6_ADDRSTRLEN + 2]; const char *port = NULL;
    if (s[0] == '[') {
        const char *rb = strchr(s, ']');
        if (!rb || (size_t)(rb - s - 1) >= sizeof ip) return -1;
        memcpy(ip, s + 1, rb - s - 1); ip[rb - s - 1] = 0;
        if (rb[1] == ':') port = rb + 2; else if (rb[1]) return -1;
    } else {
        const char *colon = strrchr(s, ':');
        if (colon && strchr(s, ':') == colon) {               // exactly one ':': IPv4:PORT
            if ((size_t)(colon - s) >= sizeof ip) return -1;
            memcpy(ip, s, colon - s); ip[colon - s] = 0; port = colon + 1;
        } else {                                              // no ':' or a bare IPv6 address
            if (strlen(s) >= sizeof ip) return -1;
            strcpy(ip, s);
        }
    }
    if (ep_ip(ip, e) < 0) return -1;
    if (port) {
        char *end; long p = strtol(port, &end, 10);
        if (*end || p <= 0 || p > 65535) return -1;
        e->port = (uint16_t)p;
    } else if (need_port) return -1;
    return 0;
}

static void ep_fmt(const struct ep *e, char *out, size_t n) {
    char ip[INET6_ADDRSTRLEN];
    inet_ntop(e->fam ? e->fam : AF_INET, e->ip, ip, sizeof ip);
    if (e->fam == AF_INET6) snprintf(out, n, "[%s]:%u", ip, e->port);
    else snprintf(out, n, "%s:%u", ip, e->port);
}

#define MAX_LISTENERS 16
#define MAX_ROUTES  64             // SNI routes, all listeners together
#define MAX_TARGETS 8              // configured targets per route
#define MAX_SLOTS   32             // servers per route
#define MAX_GTARGETS 128           // distinct targets, all routes together
#define MAX_SERVERS 512
struct policy {
    struct check check, bcheck;    // --check for local targets, --backup-check for backups
    struct ep check_ep;            // --check-to (local targets only); fam 0 = each server
    unsigned connect_ms, inter_ms, check_ms, rise, fall;
    unsigned bconnect_ms;          // --backup-connect-timeout; UINT_MAX until set: then = connect_ms
    uint8_t start_down, cut_on_down, lease_required;
};
struct listener {
    uint16_t port;
    struct ep bind;                // -l ADDR:PORT; fam 0 = every address, IPv6 and IPv4
    int smart_ack;                 // -1 until settled: on with SNI routes
    unsigned first, nroutes;
    unsigned idle_ms, half_ms;     // --idle-timeout, --half-close-timeout (0 = off)
    struct policy pol;
    struct __kernel_timespec connect_ts, bconnect_ts;   // local servers, backups
};
static struct listener listeners[MAX_LISTENERS];
struct target {
    char host[256]; uint16_t port; uint8_t backup, dns, managed;   // managed: "@name", fed by --control
    uint8_t full_warned;           // "more addresses than --dns-slots" logged (once, not every lookup)
    _Atomic uint64_t connect_fail; // failed connects to its servers, ever (control "targets")
    unsigned first, n;             // servers [first, first+n)
    const struct policy *pol;
    const char *label;             // the first route using it: log lines and the checks' Host header
};
static struct target targets[MAX_GTARGETS];
static unsigned target_listener_port(const struct target *t) {   // the listener whose policy t uses
    for (unsigned i = 0; i < MAX_LISTENERS; i++) if (t->pol == &listeners[i].pol) return listeners[i].port;
    return 0;
}
static unsigned ntargets, nservers;
struct slot {                      // one server (backend address)
    _Atomic uint64_t addr;         // version of ep, 0 = empty. ep is written only while addr is 0, then
    struct ep ep;                  // addr gets a fresh version (release): a worker that copied ep and
                                   // still sees the same version afterwards has a consistent copy
    _Atomic uint8_t up;            // workers pick only up slots; set by the checker, cleared by a failed connect
    _Atomic uint8_t failed;        // errno of a worker's failed connect (passive check), for the checker
    _Atomic uint64_t fail_ms;      // wall-clock ms of that failure, for the log line
    _Atomic uint32_t epoch;        // --cut-on-down: bumped when it goes down; older sessions are cut
    uint8_t backup;                // fixed at startup
    uint8_t ok, bad, seen_up;      // control plane only (ctl_lock): check streaks, last logged state
    uint8_t maint;                 // set down through the control socket: checks cannot bring it back
    uint64_t gone_ms, down_ms, next_ms;
    _Atomic uint32_t sessions;     // open sessions connected to it, for "show" (drain --wait)
    _Atomic uint64_t lease_until;  // "lease": CLOCK_BOOTTIME ms it may serve until, 0 = no lease
    struct target *t;
};
static struct slot servers[MAX_SERVERS];
struct route {
    char name[256]; uint32_t len;
    unsigned lis;                  // its listener
    unsigned ntargets, nslots;
    struct target *t[MAX_TARGETS];
    uint16_t s[MAX_SLOTS];         // its servers (index into servers[]); conn->slot indexes this
    uint8_t backup[MAX_SLOTS];
};
static struct route routes[MAX_ROUTES + MAX_LISTENERS];
static unsigned nroutes_all;       // routes in use, defaults included
static struct __kernel_timespec peek_ts;          // ClientHello deadline (linked timeout)

// ----------------------------------------------------------- user_data ----
// [gen:24][slot:32][unused:3][kind:4][dir:1]   0 = ignore (fire-and-forget ops)
enum { K_CONNECT = 1, K_RECV, K_SEND, K_PIN, K_POUT, K_WQ_IN, K_WQ_OUT, K_WQ_POUT, K_PEEK, K_SOCKET,
       K_EP_C = 11, K_EP_B = 12,      // epoll: the client / backend socket (the unused bits: backend seq)
       K_SWEEP = 13, K_FENCE = 14, K_ACCEPT = 15 };
#define D_PEEK 2                   // waiter "direction" for a peek parked on ENOBUFS
#define UD_IGNORE 0ULL
#define UD_ACCEPT ((uint64_t)K_ACCEPT << 1)
#define UD_FENCE ((uint64_t)K_FENCE << 1)
#define UD_SWEEP ((uint64_t)K_SWEEP << 1)
static inline uint64_t mkud(uint32_t slot, uint32_t gen, unsigned kind, unsigned d) {
    return ((uint64_t)(gen & 0xffffff) << 40) | ((uint64_t)slot << 8) | (kind << 1) | d;
}

// ---------------------------------------------------------------- types ----
enum { E_COPY, E_SPLICE };

struct dir {                       // d[0] = client->backend, d[1] = backend->client
    int src, dst;
    int pipe_r, pipe_w;            // pooled pipe, -1 when none
    uint32_t pcap;                 // that pipe's real capacity
    uint32_t in_pipe;              // bytes sitting in the pipe
    int32_t  bid;                  // pool buffer held (copy), -1 none
    uint32_t off, len;
    uint8_t  eng;                  // E_COPY / E_SPLICE
    uint8_t  eof;                  // source reached EOF
    uint8_t  shut;                 // FIN forwarded to dst
    uint8_t  full, big, small, wait_send;
    uint8_t  chain, hot, err;      // legacy io-wq splice engine
    uint8_t  probes;               // EOF probes done (backend->client, copy engine)
    uint8_t  rd, wr, rdhup, queued;   // epoll: src readable, dst writable, src got FIN, in the defer queue
};

struct conn {
    int cfd, bfd;
    uint32_t gen;
    int inflight;                  // ops whose final CQE is still due (+ parked waiters)
    uint8_t used, dying;
    uint8_t counted;               // in its server's sessions count (connected, not freed yet)
    uint8_t lowat;                 // SO_RCVLOWAT raised on cfd while a ClientHello arrives
    uint8_t route;                 // index into routes[]
    uint8_t slot;                  // address being connected to (index into that route's slots)
    uint32_t tried;                // slots tried so far (bit per slot): each address at most once
    uint32_t peeked;               // bytes seen by the last peek (no progress => peer closed)
    uint32_t sepoch;               // the slot's epoch when it was picked
    uint32_t last;                 // worker clock (ms) of the last completion that moved bytes
    uint8_t connecting, bseq;      // epoll: connect in progress; backend socket number (stale events)
    union sa baddr;                // read by the kernel when the connect SQE is submitted
    socklen_t blen;
    struct dir d[2];
};

struct waiter { uint32_t slot, gen; uint8_t d; };
struct pipe_ent { int r, w; uint32_t cap; };

struct stats { uint64_t accepted, to_splice, to_copy, spills, enobufs, stale, splices, kills,
               peeks, sni_routed, sni_default, sni_bad, fin_merged, connect_fail, retries, no_server, fenced,
               idle_closed, half_closed; };

struct worker {
    int id;
    int efd; uint64_t evbuf;       // --cut-on-down: the checker wakes the worker through this
    uint32_t hiwater;              // highest pool slot ever handed out + 1 (bounds the shutdown scan)
    uint32_t now;                  // coarse clock (ms), advanced by each sweep while timeouts are on
    struct __kernel_timespec sweep_ts;
    struct io_uring ring;
    struct conn *conns; uint32_t *freeslots; uint32_t nfree, active;
    struct io_uring_buf_ring *br; unsigned char *bufs; unsigned br_mask, br_pending, bufs_out;
    struct waiter *wq; unsigned wq_cap, wq_head, wq_n;
    struct pipe_ent *pipes; int npipes;
    unsigned char *hs;             // scratch: a ClientHello split across TLS records, reassembled
    int accept_paused; uint64_t accept_retry_ms, next_stats_ms;
    uint32_t rr[MAX_ROUTES + MAX_LISTENERS];   // round-robin position per route
    int lfd[MAX_LISTENERS];
    uint32_t accept_paused_mask;   // listeners whose accept waits for accept_retry_ms
    uint8_t drained;               // listeners closed (drain): accepts are not re-armed
    uint8_t epoll;                 // this worker runs the epoll engine (no ring)
    int epfd, tfd;                 // epoll: its epoll set, the sweep's timerfd
    unsigned char *scratch;        // epoll: every read lands here and is sent on at once
    uint32_t *bfree; unsigned nbfree;   // epoll: free pool buffers (no buf ring)
    struct stats st;
};

static void fatal(const char *m) { perror(m); exit(1); }

static struct worker **all_workers;     // only for the final counter dump
// Drain (graceful stop or reload): SIGUSR1 or the control socket's "drain". Every worker closes its
// listeners, after taking what is already queued in them; open sessions run until they end or until
// the deadline, then the process exits. A reload is: start the new process (same ports, SO_REUSEPORT),
// then drain the old one. Not covered: a connection the kernel queues on the old listener in the
// instant between its last accept and its close is reset (the classic SO_REUSEPORT handover race).
static _Atomic int draining;
static _Atomic uint64_t drain_until;

static void wake_workers(void) {
    for (int i = 0; i < cfg.workers; i++) {
        uint64_t one = 1;
        if (write(all_workers[i]->efd, &one, sizeof one) < 0) { /* counter full: a wakeup is pending anyway */ }
    }
}

static uint64_t now_ms(void);
static void drain_start(unsigned ms) {                   // the first drain's deadline holds
    uint64_t none = 0;
    if (!atomic_compare_exchange_strong(&drain_until, &none, now_ms() + ms)) return;
    atomic_store(&draining, 1);
    fprintf(stderr, "draining: listeners closing, open sessions get %u ms\n", ms);
    wake_workers();
}

static uint64_t now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000;
}

// Fencing deadline (the control socket's "lease"): the arbiter renews a server's lease with each of
// its own; if a renewal is late the proxy fences that server by itself, without waiting for a check.
// BOOTTIME, not MONOTONIC: MONOTONIC stops while the host or VM is suspended, so a resumed proxy would
// believe its deadline still ahead. lease_min is the earliest unexpired deadline (0 = none); a worker
// reads the clock once per loop pass only while one is set, and cuts the expired server's sessions
// before it forwards anything, so a proxy resumed after a freeze does not serve a stale writer.
static _Atomic uint64_t lease_min;

static uint64_t boot_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_BOOTTIME, &ts);
    return ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000;
}

static inline int lease_expired(struct slot *s, uint64_t now) {
    uint64_t u = atomic_load_explicit(&s->lease_until, memory_order_relaxed);
    return u && now >= u;
}

// --------------------------------------------------------------- ring -----
static struct io_uring_sqe *sqe_get(struct worker *w) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&w->ring);
    if (!sqe) {
        io_uring_submit(&w->ring);
        if (!(sqe = io_uring_get_sqe(&w->ring))) { fprintf(stderr, "SQ ring exhausted\n"); exit(1); }
    }
    return sqe;
}

static void fd_close(struct worker *w, int fd) {            // batched close, no CQE on success
    if (fd < 0) return;
    if (w->epoll) { close(fd); return; }                    // also leaves the epoll set
    struct io_uring_sqe *sqe = sqe_get(w);
    io_uring_prep_close(sqe, fd);
    io_uring_sqe_set_data64(sqe, UD_IGNORE);
    sqe->flags |= IOSQE_CQE_SKIP_SUCCESS;
}

// ---------------------------------------------------------- conn pool -----
static struct conn *conn_alloc(struct worker *w, uint32_t *slot) {
    if (!w->nfree) return NULL;
    *slot = w->freeslots[--w->nfree];
    struct conn *c = &w->conns[*slot];
    uint32_t gen = (c->gen + 1) & 0xffffff;
    memset(c, 0, sizeof *c);
    c->gen = gen; c->used = 1;
    if (*slot >= w->hiwater) w->hiwater = *slot + 1;
    c->last = w->now;
    c->cfd = c->bfd = -1;          // the backend socket does not exist yet while routing
    for (int i = 0; i < 2; i++) { c->d[i].bid = -1; c->d[i].pipe_r = c->d[i].pipe_w = -1; }
    w->active++;
    return c;
}

static inline uint32_t slot_of(struct worker *w, struct conn *c) { return (uint32_t)(c - w->conns); }
static inline uint64_t UD(struct worker *w, struct conn *c, unsigned kind, unsigned d) {
    return mkud(slot_of(w, c), c->gen, kind, d);
}

// sync shutdown on purpose: IORING_OP_SHUTDOWN is always punted to io-wq (slow, and unordered
// with respect to a later close, which could hit a reused fd number)
static void conn_kill(struct worker *w, struct conn *c) {
    if (c->dying) return;
    c->dying = 1; w->st.kills++;
    shutdown(c->cfd, SHUT_RDWR);                 // completes every op still pending on them
    shutdown(c->bfd, SHUT_RDWR);
}

// ---------------------------------------------------------- pipe pool -----
static int pipe_get(struct worker *w, struct dir *x) {
    if (x->pipe_r >= 0) return 0;
    if (w->npipes) {
        struct pipe_ent p = w->pipes[--w->npipes];
        x->pipe_r = p.r; x->pipe_w = p.w; x->pcap = p.cap;
        return 0;
    }
    int p[2];
    if (pipe2(p, O_NONBLOCK | O_CLOEXEC) < 0) return -1;
    if (cfg.pipesz != 65536) fcntl(p[0], F_SETPIPE_SZ, (int)cfg.pipesz);   // may be capped: fine
    int cap = fcntl(p[0], F_GETPIPE_SZ);
    x->pipe_r = p[0]; x->pipe_w = p[1]; x->pcap = cap > 0 ? (uint32_t)cap : 65536;
    return 0;
}

static void pipe_put(struct worker *w, struct dir *x) {
    if (x->pipe_r < 0) return;
    if (x->in_pipe == 0 && w->npipes < PIPE_POOL_MAX)
        w->pipes[w->npipes++] = (struct pipe_ent){ x->pipe_r, x->pipe_w, x->pcap };
    else { fd_close(w, x->pipe_r); fd_close(w, x->pipe_w); }
    x->pipe_r = x->pipe_w = -1; x->in_pipe = 0;
}

// ---------------------------------------------------------- buffer pool ---
#define BUF(w, bid) ((w)->bufs + (size_t)(bid) * cfg.bufsz)

static inline void buf_put(struct worker *w, int bid) {
    if (w->epoll) { w->bfree[w->nbfree++] = (uint32_t)bid; w->bufs_out--; return; }
    io_uring_buf_ring_add(w->br, BUF(w, bid), cfg.bufsz, bid, w->br_mask, w->br_pending++);
    w->bufs_out--;
}

static void release_buf(struct worker *w, struct dir *x) {
    if (x->bid >= 0) { buf_put(w, x->bid); x->bid = -1; }
}

static void conn_maybe_free(struct worker *w, struct conn *c) {
    if (!c->dying || c->inflight > 0 || !c->used) return;
    fd_close(w, c->cfd); fd_close(w, c->bfd);
    for (int i = 0; i < 2; i++) {
        struct dir *x = &c->d[i];
        release_buf(w, x);
#ifdef PARANOID
        if (x->pipe_r >= 0) { int n = 0; ioctl(x->pipe_r, FIONREAD, &n); if (n) x->in_pipe = n; }
#endif
        pipe_put(w, x);
    }
    if (c->counted) {
        atomic_fetch_sub_explicit(&servers[routes[c->route].s[c->slot]].sessions, 1, memory_order_relaxed);
        c->counted = 0;
    }
    c->used = 0;
    w->freeslots[w->nfree++] = slot_of(w, c);
    w->active--;
}

// forward EOF once all data of this direction is out; keep the other direction open.
// When the other direction is already done, nothing is pending on either socket and both sources
// have been read to EOF, so close() alone sends the last FIN: no shutdown() calls at all
// (-K restores the old path: shutdown(WR) here, then shutdown(RDWR) on both sockets).
static void dir_finish(struct worker *w, struct conn *c, int d) {
    struct dir *x = &c->d[d];
    if (x->shut) return;
    x->shut = 1;
    pipe_put(w, x);
    int last = c->d[d ^ 1].shut;
    if (!last || cfg.old_close) shutdown(x->dst, SHUT_WR);
    if (!last) return;
    if (cfg.old_close) conn_kill(w, c);
    else c->dying = 1;                        // freed (and closed) once inflight reaches 0
}

// ========================================================= COPY ENGINE ====
static void copy_recv(struct worker *w, struct conn *c, int d, int poll_first) {
    struct dir *x = &c->d[d];
    x->eng = E_COPY;
    struct io_uring_sqe *sqe = sqe_get(w);
    io_uring_prep_recv(sqe, x->src, NULL, 0, 0);
    sqe->flags |= IOSQE_BUFFER_SELECT;
    sqe->buf_group = BGID;
    if (poll_first) sqe->ioprio |= IORING_RECVSEND_POLL_FIRST;
    io_uring_sqe_set_data64(sqe, UD(w, c, K_RECV, d));
    c->inflight++;
}

static void copy_send(struct worker *w, struct conn *c, int d, int may_wait) {
    struct dir *x = &c->d[d];
    struct io_uring_sqe *sqe = sqe_get(w);
    io_uring_prep_send(sqe, x->dst, BUF(w, x->bid) + x->off, x->len - x->off,
                       MSG_NOSIGNAL | (may_wait ? 0 : MSG_DONTWAIT));
    x->wait_send = may_wait;
    io_uring_sqe_set_data64(sqe, UD(w, c, K_SEND, d));
    c->inflight++;
}

static void waiter_push(struct worker *w, struct conn *c, int d) {
    if (w->wq_n == w->wq_cap) {
        unsigned ncap = w->wq_cap ? w->wq_cap * 2 : 1024;
        struct waiter *n = malloc(ncap * sizeof *n);          // grows once to the peak, never on the hot path again
        if (!n) fatal("malloc");
        for (unsigned i = 0; i < w->wq_n; i++) n[i] = w->wq[(w->wq_head + i) & (w->wq_cap - 1)];
        free(w->wq); w->wq = n; w->wq_cap = ncap; w->wq_head = 0;
    }
    w->wq[(w->wq_head + w->wq_n++) & (w->wq_cap - 1)] = (struct waiter){ slot_of(w, c), c->gen, (uint8_t)d };
}

static void wq_push(struct worker *w, struct conn *c, int d) {
    waiter_push(w, c, d);
    c->inflight++;
    w->st.enobufs++;
}

static void pump(struct worker *w, struct conn *c, int d);
static void arm_pout(struct worker *w, struct conn *c, int d);
static void peek_arm(struct worker *w, struct conn *c, int poll_first);
static void start_dirs(struct worker *w, struct conn *c);

// The peer could not take everything: park the remainder in a kernel pipe (no heap, no pool
// buffer held) and let this direction continue as a splice direction until the pipe drains.
static void spill(struct worker *w, struct conn *c, int d) {
    struct dir *x = &c->d[d];
    uint32_t rem = x->len - x->off;
    if (pipe_get(w, x) == 0 && x->pcap >= rem) {
        ssize_t n = write(x->pipe_w, BUF(w, x->bid) + x->off, rem);
        if (n == (ssize_t)rem) {
            release_buf(w, x);
            x->in_pipe = rem; x->eng = E_SPLICE; w->st.spills++;
            arm_pout(w, c, d);
            return;
        }
        if (n > 0) { x->off += n; x->in_pipe = n; }          // pipe took part of it (tiny pipe)
    }
    if (x->in_pipe) {                                         // drain pipe first, then the rest
        x->eng = E_SPLICE; arm_pout(w, c, d);                 // buffer is kept until then
        return;
    }
    copy_send(w, c, d, 1);                                    // no usable pipe: wait in send
}

// Backends usually close right after their last bytes (HTTP Connection: close, TLS close_notify).
// The recv CQE cannot tell whether that FIN is already queued, so after a short read one
// non-blocking recv() asks. At EOF the data goes out with MSG_MORE and the FIN is sent at once,
// riding on the last data segment; the client then ACKs both together: 2 fewer segments per
// connection (HAProxy gets the same from EPOLLRDHUP). Only the first -E short reads of a
// connection probe, so keep-alive traffic stays at ~0 syscalls per message.
static int probe_eof(struct worker *w, struct conn *c, int d) {
    struct dir *x = &c->d[d];
    x->probes++;
    ssize_t n = recv(x->src, BUF(w, x->bid) + x->len, cfg.bufsz - x->len, MSG_DONTWAIT);
    if (n > 0) { x->len += n; return 0; }                 // more data: send it in one go
    if (n < 0) return 0;                                  // nothing queued (or an error recv reports)
    x->eof = 1;
    ssize_t s = send(x->dst, BUF(w, x->bid), x->len, MSG_DONTWAIT | MSG_NOSIGNAL | MSG_MORE);
    if (s == (ssize_t)x->len) {
        release_buf(w, x);
        w->st.fin_merged++;
        dir_finish(w, c, d);                              // shutdown()/close() attaches the FIN
        return 1;
    }
    if (s < 0 && errno != EAGAIN) { release_buf(w, x); conn_kill(w, c); return 1; }
    if (s > 0) x->off = s;
    spill(w, c, d);                                       // slow client: EOF is forwarded once drained
    return 1;
}

static void on_recv(struct worker *w, struct conn *c, int d, int res, unsigned flags) {
    struct dir *x = &c->d[d];
    int has_buf = flags & IORING_CQE_F_BUFFER;
    int bid = flags >> IORING_CQE_BUFFER_SHIFT;
    if (has_buf) w->bufs_out++;
    if (res > 0 && has_buf && !c->dying) {
        x->bid = bid; x->off = 0; x->len = res;
        x->full = ((unsigned)res == cfg.bufsz);
        x->big = ((unsigned)res >= cfg.bulk) ? x->big + 1 : 0;
        if (d == 1 && !x->full && x->probes < cfg.eof_probes && probe_eof(w, c, d)) return;
        copy_send(w, c, d, 0);
        return;
    }
    if (has_buf) buf_put(w, bid);
    if (c->dying) return;
    if (res == 0)                                   { x->eof = 1; dir_finish(w, c, d); }
    else if (res == -ENOBUFS)                       wq_push(w, c, d);
    else if (res == -EAGAIN || res == -EINTR)       copy_recv(w, c, d, 1);
    else                                            conn_kill(w, c);
}

static void on_send(struct worker *w, struct conn *c, int d, int res) {
    struct dir *x = &c->d[d];
    if (c->dying) { release_buf(w, x); return; }
    if (res == -EAGAIN && !x->wait_send) res = 0;
    if (res < 0 || (res == 0 && x->wait_send)) { release_buf(w, x); conn_kill(w, c); return; }
    x->off += res;
    if (x->off < x->len) {
        if (x->in_pipe) { conn_kill(w, c); return; }          // cannot happen: pipe drained first
        spill(w, c, d);
        return;
    }
    release_buf(w, x);
    if (cfg.mode == M_HYBRID && x->big >= cfg.big_n) {       // bulk stream: move it into the kernel
        x->eng = E_SPLICE; x->big = 0; x->small = 0; w->st.to_splice++;
        pump(w, c, d);
        return;
    }
    copy_recv(w, c, d, !x->full);                             // short read => socket is likely empty
}

static void cp_batch_end(struct worker *w) {
    unsigned returned = w->br_pending;
    if (returned) { io_uring_buf_ring_advance(w->br, returned); w->br_pending = 0; }
    unsigned wake = returned;
    if (w->wq_n && w->bufs_out == 0 && wake == 0) wake = 8;
    while (wake-- && w->wq_n) {
        struct waiter wt = w->wq[w->wq_head];
        w->wq_head = (w->wq_head + 1) & (w->wq_cap - 1);
        w->wq_n--;
        struct conn *c = &w->conns[wt.slot];
        if (!c->used || c->gen != wt.gen) { w->st.stale++; continue; }
        c->inflight--;
        if (c->dying) conn_maybe_free(w, c);
        else if (wt.d == D_PEEK) peek_arm(w, c, 1);
        else copy_recv(w, c, wt.d, 1);
    }
}

// ================================================= INLINE SPLICE ENGINE ====
static void arm_pin(struct worker *w, struct conn *c, int d) {
    struct io_uring_sqe *sqe = sqe_get(w);
    io_uring_prep_poll_add(sqe, c->d[d].src, POLLIN | POLLRDHUP);
    io_uring_sqe_set_data64(sqe, UD(w, c, K_PIN, d));
    c->inflight++;
}

static void arm_pout(struct worker *w, struct conn *c, int d) {
    struct io_uring_sqe *sqe = sqe_get(w);
    io_uring_prep_poll_add(sqe, c->d[d].dst, POLLOUT);
    io_uring_sqe_set_data64(sqe, UD(w, c, K_POUT, d));
    c->inflight++;
}

// Called with nothing outstanding for this direction. Moves data until the source is empty,
// the destination is full (then waits for POLLOUT without reading more: back-pressure, no spin),
// or the per-wakeup budget is used.
static void pump(struct worker *w, struct conn *c, int d) {
    struct dir *x = &c->d[d];
    uint64_t moved = 0;
    int src_empty = 0;
    for (int it = 0; it < PUMP_BUDGET; it++) {
        if (x->in_pipe) {
            ssize_t n = splice(x->pipe_r, NULL, x->dst, NULL, x->in_pipe, SPLICE_F_NONBLOCK | SPLICE_F_MOVE);
            w->st.splices++;
            if (n > 0) { x->in_pipe -= n; continue; }
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && errno == EAGAIN) { arm_pout(w, c, d); return; }
            conn_kill(w, c); return;
        }
        if (x->bid >= 0) {                                    // remainder of a partial spill
            x->eng = E_COPY; copy_send(w, c, d, 1); return;
        }
        if (x->eof) { dir_finish(w, c, d); return; }
        if (src_empty) break;
        if (pipe_get(w, x) < 0) { conn_kill(w, c); return; }
        ssize_t n = splice(x->src, NULL, x->pipe_w, NULL, x->pcap, SPLICE_F_NONBLOCK | SPLICE_F_MOVE);
        w->st.splices++;
        if (n > 0) { x->in_pipe = n; moved += n; src_empty = ((uint32_t)n < x->pcap); continue; }
        if (n == 0) { x->eof = 1; continue; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN) break;
        conn_kill(w, c); return;
    }
    if (x->in_pipe) { arm_pout(w, c, d); return; }            // budget used mid-transfer
    // source drained, pipe empty
    if (cfg.mode == M_COPY) { pipe_put(w, x); copy_recv(w, c, d, 1); return; }   // spill done
    if (cfg.mode == M_HYBRID) {
        x->small = moved < cfg.bulk ? x->small + 1 : 0;
        if (x->small >= cfg.small_n) {                        // back to small exchanges
            x->small = 0; x->big = 0; w->st.to_copy++;
            pipe_put(w, x);
            copy_recv(w, c, d, 1);
            return;
        }
    }
    pipe_put(w, x);                                           // idle directions hold no pipe
    arm_pin(w, c, d);
}

static void on_poll(struct worker *w, struct conn *c, int d, int res) {
    if (c->dying) return;
    if (res < 0) { conn_kill(w, c); return; }
    pump(w, c, d);
}

// ============================================ LEGACY io-wq SPLICE ENGINE ====
static void wq_chain(struct worker *w, struct conn *c, int d) {
    struct dir *x = &c->d[d];
    if (pipe_get(w, x) < 0) { conn_kill(w, c); return; }
    struct io_uring_sqe *s1 = sqe_get(w);
    io_uring_prep_splice(s1, x->src, -1, x->pipe_w, -1, x->pcap, SPLICE_F_NONBLOCK);
    s1->flags |= IOSQE_IO_HARDLINK;
    io_uring_sqe_set_data64(s1, UD(w, c, K_WQ_IN, d));
    struct io_uring_sqe *s2 = sqe_get(w);
    io_uring_prep_splice(s2, x->pipe_r, -1, x->dst, -1, x->pcap, SPLICE_F_NONBLOCK);
    io_uring_sqe_set_data64(s2, UD(w, c, K_WQ_OUT, d));
    x->chain = 2; c->inflight += 2;
}

static void wq_drain(struct worker *w, struct conn *c, int d) {
    struct dir *x = &c->d[d];
    struct io_uring_sqe *s1 = sqe_get(w);
    io_uring_prep_poll_add(s1, x->dst, POLLOUT);
    s1->flags |= IOSQE_IO_HARDLINK;
    io_uring_sqe_set_data64(s1, UD(w, c, K_WQ_POUT, d));
    struct io_uring_sqe *s2 = sqe_get(w);
    io_uring_prep_splice(s2, x->pipe_r, -1, x->dst, -1, x->in_pipe, SPLICE_F_NONBLOCK);
    io_uring_sqe_set_data64(s2, UD(w, c, K_WQ_OUT, d));
    x->chain = 2; c->inflight += 2;
}

static void wq_next(struct worker *w, struct conn *c, int d) {
    struct dir *x = &c->d[d];
    if (c->dying) return;
    if (x->err) { conn_kill(w, c); return; }
    if (x->in_pipe > 0) { wq_drain(w, c, d); return; }
    if (x->eof) { dir_finish(w, c, d); return; }
    pipe_put(w, x);
    if (x->hot) wq_chain(w, c, d); else arm_pin(w, c, d);
}

static void wq_done(struct worker *w, struct conn *c, int d, unsigned kind, int res) {
    struct dir *x = &c->d[d];
    if (kind == K_WQ_IN) {
        if (res > 0) { x->in_pipe += res; x->hot = ((unsigned)res >= x->pcap); }
        else if (res == 0) x->eof = 1;
        else { x->hot = 0; if (res != -EAGAIN) x->err = 1; }
    } else if (kind == K_WQ_OUT) {
        if (res > 0) x->in_pipe -= res;
        else if (res < 0 && res != -EAGAIN) x->err = 1;
    } else if (res < 0) x->err = 1;
    if (--x->chain == 0) wq_next(w, c, d);
}

// ======================================================= SNI ROUTING =====
enum { SNI_NEED = -1, SNI_BAD = -2 };

static inline int route_default(const struct listener *l) { return (int)(l->first + l->nroutes); }

static int route_find(const struct listener *l, const char *name, uint32_t len) {
    if (len && name[len - 1] == '.') len--;                   // "a.example." == "a.example"
    for (unsigned i = l->first; i < l->first + l->nroutes; i++)
        if (routes[i].len == len && !strncasecmp(routes[i].name, name, len)) return (int)i;
    return route_default(l);
}

// ClientHello body: version(2) random(32) session_id<1> cipher_suites<2> compression<1>
// extensions<2> { type(2) data<2> }; server_name (type 0) = list<2> { name_type(1) name<2> }
static int sni_lookup(const struct listener *l, const uint8_t *b, uint32_t n) {
    uint32_t i = 34;
    if (i + 1 > n) return SNI_BAD;
    i += 1 + b[i];
    if (i + 2 > n) return SNI_BAD;
    i += 2 + ((uint32_t)b[i] << 8 | b[i + 1]);
    if (i + 1 > n) return SNI_BAD;
    i += 1 + b[i];
    if (i == n) return route_default(l);                      // no extensions at all
    if (i + 2 > n) return SNI_BAD;
    uint32_t end = i + 2 + ((uint32_t)b[i] << 8 | b[i + 1]);
    if (end > n) return SNI_BAD;
    for (i += 2; i + 4 <= end; ) {
        uint32_t type = (uint32_t)b[i] << 8 | b[i + 1], len = (uint32_t)b[i + 2] << 8 | b[i + 3];
        i += 4;
        if (i + len > end) return SNI_BAD;
        if (type == 0) {
            for (uint32_t j = i + 2; j + 3 <= i + len; ) {
                uint32_t nl = (uint32_t)b[j + 1] << 8 | b[j + 2];
                if (j + 3 + nl > i + len) return SNI_BAD;
                if (b[j] == 0) return route_find(l, (const char *)b + j + 3, nl);   // host_name
                j += 3 + nl;
            }
            return route_default(l);
        }
        i += len;
    }
    return route_default(l);
}

// p[0..n) = bytes queued on the client socket. Returns a route index, SNI_BAD, or SNI_NEED with
// *need = how many queued bytes it takes to get further. A ClientHello may span several TLS
// records (rare); they are reassembled into w->hs.
static int sni_route(struct worker *w, const struct listener *l, const uint8_t *p, uint32_t n, uint32_t *need) {
    uint32_t off = 0, hn = 0;
    for (;;) {
        if (off + 5 > n) { *need = off + 5; return SNI_NEED; }
        const uint8_t *r = p + off;
        uint32_t rlen = (uint32_t)r[3] << 8 | r[4];
        if (r[0] != 22 || r[1] != 3 || rlen == 0 || rlen > 16384) return SNI_BAD;   // handshake record
        if (off + 5 + rlen > n) { *need = off + 5 + rlen; return SNI_NEED; }
        if (off == 0 && rlen >= 4) {                          // common case: one record, parse in place
            uint32_t hlen = 4 + ((uint32_t)r[6] << 16 | (uint32_t)r[7] << 8 | r[8]);
            if (r[5] != 1) return SNI_BAD;                    // not a ClientHello
            if (hlen <= rlen) return sni_lookup(l, r + 9, hlen - 4);
        }
        if (hn + rlen > cfg.bufsz) return SNI_BAD;
        memcpy(w->hs + hn, r + 5, rlen);
        hn += rlen; off += 5 + rlen;
        if (hn >= 4) {
            if (w->hs[0] != 1) return SNI_BAD;
            uint32_t hlen = 4 + ((uint32_t)w->hs[1] << 16 | (uint32_t)w->hs[2] << 8 | w->hs[3]);
            if (hlen > cfg.bufsz) return SNI_BAD;
            if (hn >= hlen) return sni_lookup(l, w->hs + 4, hlen - 4);
        }
    }
}

// keep the SQ from splitting a linked pair across two submits
static void sq_reserve(struct worker *w, unsigned n) {
    if (io_uring_sq_space_left(&w->ring) < n) io_uring_submit(&w->ring);
}

// peek the client's first bytes into a pool buffer (returned right away); the deadline is a
// linked timeout, which cancels the peek with -ECANCELED
static void peek_arm(struct worker *w, struct conn *c, int poll_first) {
    sq_reserve(w, 2);
    struct io_uring_sqe *sqe = sqe_get(w);
    io_uring_prep_recv(sqe, c->cfd, NULL, 0, MSG_PEEK);
    sqe->flags |= IOSQE_BUFFER_SELECT | IOSQE_IO_LINK;
    sqe->buf_group = BGID;
    if (poll_first) sqe->ioprio |= IORING_RECVSEND_POLL_FIRST;
    io_uring_sqe_set_data64(sqe, UD(w, c, K_PEEK, 0));
    c->inflight++;
    struct io_uring_sqe *t = sqe_get(w);
    io_uring_prep_link_timeout(t, &peek_ts, 0);
    io_uring_sqe_set_data64(t, UD_IGNORE);
}

static const int one_opt = 1, zero_opt = 0;   // setsockopt values, read by the kernel when the SQE runs

static void conn_set_bfd(struct conn *c, int bfd) {
    c->bfd = bfd;
    c->d[0].src = c->cfd; c->d[0].dst = bfd;
    c->d[1].src = bfd; c->d[1].dst = c->cfd;
}

// The next address for c: an up slot of its route not tried yet, local ones round-robin, backups
// only once no local one is left. -1 = nothing left (the client is then closed).
static int pick_slot(struct worker *w, struct conn *c) {
    struct route *r = &routes[c->route];
    uint8_t cand[MAX_SLOTS]; uint32_t ep[MAX_SLOTS];
    uint64_t lnow = atomic_load_explicit(&lease_min, memory_order_relaxed) ? boot_ms() : 0;
    for (uint8_t backup = 0; backup < 2; backup++) {
    again:;
        unsigned n = 0;
        for (unsigned i = 0; i < r->nslots; i++) {
            struct slot *s = &servers[r->s[i]];
            if (r->backup[i] != backup || (c->tried >> i & 1)) continue;
            uint32_t e = atomic_load(&s->epoch);              // before up: see slot_set_up
            if (!atomic_load_explicit(&s->up, memory_order_relaxed)) continue;
            if (lnow && lease_expired(s, lnow)) continue;
            if (atomic_load_explicit(&s->addr, memory_order_relaxed)) { cand[n] = (uint8_t)i; ep[n++] = e; }
        }
        if (!n) continue;
        unsigned k = w->rr[c->route]++ % n;
        struct slot *s = &servers[r->s[cand[k]]];
        c->tried |= 1u << cand[k];
        uint64_t v = atomic_load_explicit(&s->addr, memory_order_acquire);    // seqlock-style read of ep
        struct ep e = s->ep;
        atomic_thread_fence(memory_order_acquire);
        if (!v || atomic_load_explicit(&s->addr, memory_order_relaxed) != v) goto again;   // replaced meanwhile
        c->slot = cand[k]; c->sepoch = ep[k];
        c->blen = ep_sa(&e, 0, &c->baddr);
        return cand[k];
    }
    return -1;
}

// connect, with a linked timeout: a killed container's address goes silent (no RST), and without a
// deadline the client would wait out the kernel's SYN retries (~2 min) instead of the next server
static void submit_connect(struct worker *w, struct conn *c) {
    struct io_uring_sqe *sqe = sqe_get(w);
    io_uring_prep_connect(sqe, c->bfd, &c->baddr.sa, c->blen);
    io_uring_sqe_set_data64(sqe, UD(w, c, K_CONNECT, 0));
    c->inflight++;
    const struct route *r = &routes[c->route];
    const struct listener *l = &listeners[r->lis];
    int bk = r->backup[c->slot];
    if (!(bk ? l->pol.bconnect_ms : l->pol.connect_ms)) return;
    sqe->flags |= IOSQE_IO_LINK;
    struct io_uring_sqe *t = sqe_get(w);
    io_uring_prep_link_timeout(t, (struct __kernel_timespec *)(bk ? &l->bconnect_ts : &l->connect_ts), 0);   // older liburing: not const
    io_uring_sqe_set_data64(t, UD_IGNORE);
}

// Backend socket + TCP_NODELAY + connect. Default: socket through the ring (K_SOCKET); its CQE
// submits setsockopt (a ring socket command, linked) and the connect, so no syscall of its own
// (~4% less CPU per new connection on nitro). -o: two plain syscalls, then the connect SQE.
// -F adds TCP_FASTOPEN_CONNECT: the connect completes at once and the first bytes forwarded to the
// backend ride in its SYN (needs server-side TFO on the backend host; assumes the client speaks
// first, as in HTTP and TLS, since nothing is sent to the backend before that).
// -Q (smart ACKs, like HAProxy's tcp-smart-connect/-accept): TCP_QUICKACK=0 before the connect, so the
// last ACK of the handshake waits and leaves inside the first data segment; on the client socket the
// ACK of the request rides on the response. Fewer packets, no server support needed (-6% CPU per new
// connection). Default only with SNI routing: the delayed handshake ACK (up to 200 ms) would hold up a
// backend that speaks first, which cannot happen once a ClientHello has arrived.
static void ep_connect(struct worker *w, struct conn *c);
static void ep_start(struct worker *w, struct conn *c);

static void conn_connect(struct worker *w, struct conn *c) {
    if (pick_slot(w, c) < 0) { w->st.no_server++; conn_kill(w, c); return; }   // unknown name, all down
    if (cfg.ring_socket && !w->epoll) {
        struct io_uring_sqe *sqe = sqe_get(w);
        io_uring_prep_socket(sqe, c->baddr.sa.sa_family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0, 0);
        io_uring_sqe_set_data64(sqe, UD(w, c, K_SOCKET, 0));
        c->inflight++;
        return;
    }
    int bfd = socket(c->baddr.sa.sa_family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (bfd < 0) { conn_kill(w, c); return; }
    setsockopt(bfd, IPPROTO_TCP, TCP_NODELAY, &one_opt, sizeof one_opt);
    if (cfg.tfo) setsockopt(bfd, IPPROTO_TCP, TCP_FASTOPEN_CONNECT, &one_opt, sizeof one_opt);
    if (listeners[routes[c->route].lis].smart_ack) setsockopt(bfd, IPPROTO_TCP, TCP_QUICKACK, &zero_opt, sizeof zero_opt);
    conn_set_bfd(c, bfd);
    if (w->epoll) { ep_connect(w, c); return; }
    sq_reserve(w, 2);
    submit_connect(w, c);
}

// A refused or timed-out connect marks that address down at once (the checker brings it back) and
// moves on to the next one. Nothing of the client's has been consumed yet (the ClientHello is only
// peeked; plain TCP starts reading after the connect), so the retry is invisible to it. Not covered:
// with -F the connect completes before the SYN leaves, so a dead server shows up later, as an error
// on the first send. Local errors (EADDRNOTAVAIL: out of ports) are not the server's fault.
static void on_connect(struct worker *w, struct conn *c, int res) {
    if (c->dying) return;
    if (res >= 0) {
        atomic_fetch_add_explicit(&servers[routes[c->route].s[c->slot]].sessions, 1, memory_order_relaxed);
        c->counted = 1;
        start_dirs(w, c);
        return;
    }
    w->st.connect_fail++;
    atomic_fetch_add_explicit(&servers[routes[c->route].s[c->slot]].t->connect_fail, 1, memory_order_relaxed);
    if (res == -EADDRNOTAVAIL) {                // out of local ports: say so, at most every 10 s
        static _Atomic uint64_t last_warn;
        uint64_t t = now_ms(), l = atomic_load(&last_warn);
        if (t - l >= 10000 && atomic_compare_exchange_strong(&last_warn, &l, t))
            fprintf(stderr, "connect: out of local ports (EADDRNOTAVAIL); widen net.ipv4.ip_local_port_range "
                    "(e.g. 1024 65535) or add backend addresses\n");
    }
    if (res == -ECONNREFUSED || res == -ECANCELED || res == -ETIMEDOUT || res == -EHOSTUNREACH ||
        res == -ENETUNREACH || res == -ECONNRESET) {
        struct slot *s = &servers[routes[c->route].s[c->slot]];
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        atomic_store_explicit(&s->up, 0, memory_order_relaxed);
        atomic_store_explicit(&s->fail_ms, (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000, memory_order_relaxed);
        atomic_store_explicit(&s->failed, (uint8_t)-res, memory_order_release);
    }
    fd_close(w, c->bfd);
    conn_set_bfd(c, -1);
    w->st.retries++;
    conn_connect(w, c);
}

static void ring_setsockopt(struct worker *w, int fd, int opt, const int *val, int link) {
    struct io_uring_sqe *sqe = sqe_get(w);
    io_uring_prep_cmd_sock(sqe, SOCKET_URING_OP_SETSOCKOPT, fd, IPPROTO_TCP, opt, (void *)val, sizeof *val);
    sqe->flags |= IOSQE_CQE_SKIP_SUCCESS | (link ? IOSQE_IO_LINK : 0);   // linked: a failure cancels the connect
    io_uring_sqe_set_data64(sqe, UD_IGNORE);
}

static void on_socket(struct worker *w, struct conn *c, int res) {
    if (res < 0) { conn_kill(w, c); return; }
    conn_set_bfd(c, res);                    // owned by the conn from here: closed on free
    if (c->dying) return;
    sq_reserve(w, 5);
    ring_setsockopt(w, res, TCP_NODELAY, &one_opt, 1);
    if (cfg.tfo) ring_setsockopt(w, res, TCP_FASTOPEN_CONNECT, &one_opt, 1);
    if (listeners[routes[c->route].lis].smart_ack) ring_setsockopt(w, res, TCP_QUICKACK, &zero_opt, 1);
    submit_connect(w, c);
}

static void on_peek(struct worker *w, struct conn *c, int res, unsigned flags) {
    int has_buf = flags & IORING_CQE_F_BUFFER;
    int bid = flags >> IORING_CQE_BUFFER_SHIFT;
    if (has_buf) w->bufs_out++;
    if (c->dying) { if (has_buf) buf_put(w, bid); return; }
    if (res > 0 && has_buf) {
        uint32_t need = 0;
        w->st.peeks++;
        const struct listener *l = &listeners[routes[c->route].lis];
        int r = sni_route(w, l, BUF(w, bid), (uint32_t)res, &need);
        buf_put(w, bid);
        if (r == SNI_NEED && need <= cfg.bufsz && (uint32_t)res > c->peeked) {
            c->peeked = res;                                  // sleep until `need` bytes are queued
            if (setsockopt(c->cfd, SOL_SOCKET, SO_RCVLOWAT, &(int){ (int)need }, sizeof(int)) == 0) c->lowat = 1;
            peek_arm(w, c, 1);
            return;
        }
        if (r < 0) { w->st.sni_bad++; conn_kill(w, c); return; }   // not TLS, too big, or no progress (FIN)
        if (c->lowat) setsockopt(c->cfd, SOL_SOCKET, SO_RCVLOWAT, &(int){ 1 }, sizeof(int));
        if (r == route_default(l)) w->st.sni_default++; else w->st.sni_routed++;
        c->route = (uint8_t)r;
        conn_connect(w, c);
        return;
    }
    if (has_buf) buf_put(w, bid);
    if (res == -ENOBUFS)                     wq_push(w, c, D_PEEK);
    else if (res == -EAGAIN || res == -EINTR) peek_arm(w, c, 1);
    else                                     conn_kill(w, c);  // EOF before a ClientHello, timeout, error
}

// ============================================================ shared ======
static void start_dirs(struct worker *w, struct conn *c) {
    c->last = w->now;                          // the idle clock starts once the backend is connected
    if (w->epoll) { ep_start(w, c); return; }
    switch (cfg.mode) {
    case M_COPY: case M_HYBRID:
        copy_recv(w, c, 0, 0);                 // the client's request is probably already queued
        copy_recv(w, c, 1, 1);                 // the backend cannot have answered yet
        break;
    case M_ISPLICE:
        c->d[0].eng = c->d[1].eng = E_SPLICE;
        pump(w, c, 0);
        arm_pin(w, c, 1);
        break;
    case M_SPLICE:
        wq_chain(w, c, 0);
        arm_pin(w, c, 1);
        break;
    }
}

// Idle and half-close timeouts, checked by a coarse sweep instead of a timer per conn (nothing to
// re-arm on the data path; a conn only stores the loop's clock when a completion moves bytes).
//   idle        no bytes either way for --idle-timeout ms (off by default: databases sit idle)
//   half-close  one direction has forwarded its FIN and the other one has not moved for
//               --half-close-timeout ms: the peer that half-closed is likely gone, and without a
//               limit the conn (two sockets, maybe a pipe) would stay forever
// Not while routing or connecting: the hello and connect timeouts cover those. A ring timeout wakes
// the worker once per sweep period; the clock is read only there, so a conn's idle time is known to
// within one period (a quarter of the shortest timeout, at most 1 s).
static void sweep_arm(struct worker *w) {
    struct io_uring_sqe *sqe = sqe_get(w);
    io_uring_prep_timeout(sqe, &w->sweep_ts, 0, 0);
    io_uring_sqe_set_data64(sqe, UD_SWEEP);
}

// Under epoll the sweep also enforces the ClientHello and connect deadlines (linked timeouts under
// io_uring). A conn's clock was read at the previous sweep, so it may be one period early: these two
// wait one period more, never firing early (a connect cut early would mark a live server down).
static void sweep(struct worker *w) {
    w->now = (uint32_t)now_ms();
    for (uint32_t i = 0; i < w->hiwater; i++) {
        struct conn *c = &w->conns[i];
        if (!c->used || c->dying) continue;
        const struct listener *l = &listeners[routes[c->route].lis];
        uint32_t quiet = w->now - c->last;
        if (w->epoll && !c->tried) {                               // still waiting for its ClientHello
            if (quiet >= cfg.peek_ms + cfg.ep_sweep_ms) { conn_kill(w, c); conn_maybe_free(w, c); }
            continue;
        }
        if (w->epoll && c->connecting) {
            unsigned cms = routes[c->route].backup[c->slot] ? l->pol.bconnect_ms : l->pol.connect_ms;
            if (cms && quiet >= cms + cfg.ep_sweep_ms) {
                c->connecting = 0;
                on_connect(w, c, -ETIMEDOUT);                      // marks it down, tries the next server
                conn_maybe_free(w, c);
            }
            continue;
        }
        if (c->bfd < 0 || !c->tried) continue;
        if (l->half_ms && (c->d[0].shut || c->d[1].shut) && quiet >= l->half_ms) { w->st.half_closed++; conn_kill(w, c); }
        else if (l->idle_ms && quiet >= l->idle_ms) { w->st.idle_closed++; conn_kill(w, c); }
        conn_maybe_free(w, c);                                     // epoll; under io_uring the CQEs free it
    }
}

static void accept_arm(struct worker *w, unsigned li) {     // the listener index rides in the slot field
    struct io_uring_sqe *sqe = sqe_get(w);
    io_uring_prep_multishot_accept(sqe, w->lfd[li], NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    io_uring_sqe_set_data64(sqe, mkud(li, 0, K_ACCEPT, 0));
}

// --cut-on-down: a read on the worker's eventfd, completed by the checker's write
static void fence_arm(struct worker *w) {
    struct io_uring_sqe *sqe = sqe_get(w);
    io_uring_prep_read(sqe, w->efd, &w->evbuf, sizeof w->evbuf, 0);
    io_uring_sqe_set_data64(sqe, UD_FENCE);
}

// A server went down: cut every session of this worker opened to it before that (older epoch). The
// scan is bounded by the pool's high-water mark: microseconds per thousand slots, and rare.
static void ep_accept(struct worker *w, unsigned li);
static void on_accept(struct worker *w, unsigned li, int res, unsigned flags);

// the drain, on this worker: no more accepts; take what the listeners already queued, then close them
static void worker_drain(struct worker *w) {
    if (w->drained) return;
    w->drained = 1; w->accept_paused = 0;
    for (unsigned li = 0; li < cfg.nlisteners; li++) {
        if (w->lfd[li] < 0) continue;
        if (w->epoll) {
            epoll_ctl(w->epfd, EPOLL_CTL_DEL, w->lfd[li], NULL);
            ep_accept(w, li);                                     // drained: loops until EAGAIN
        } else {
            struct io_uring_sqe *sqe = sqe_get(w);                // the multishot accept ends (-ECANCELED)
            io_uring_prep_cancel64(sqe, mkud(li, 0, K_ACCEPT, 0), 0);
            io_uring_sqe_set_data64(sqe, UD_IGNORE);
            for (int cfd; (cfd = accept4(w->lfd[li], NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC)) >= 0; )
                on_accept(w, li, cfd, IORING_CQE_F_MORE);
        }
        close(w->lfd[li]); w->lfd[li] = -1;
    }
}

static void on_fence(struct worker *w) {
    if (atomic_load(&draining)) worker_drain(w);
    for (uint32_t i = 0; i < w->hiwater; i++) {
        struct conn *c = &w->conns[i];
        if (!c->used || c->dying || !c->tried) continue;           // free, closing, or not routed yet
        if (atomic_load(&servers[routes[c->route].s[c->slot]].epoch) != c->sepoch) {
            w->st.fenced++; conn_kill(w, c); conn_maybe_free(w, c);
        }
    }
}

// A lease ran out: cut its sessions now, before this pass forwards anything (the checker also marks
// the server down within 50 ms and moves lease_min on)
static void lease_check(struct worker *w) {
    uint64_t m = atomic_load_explicit(&lease_min, memory_order_relaxed);
    if (!m) return;
    uint64_t now = boot_ms();
    if (now < m) return;
    for (uint32_t i = 0; i < w->hiwater; i++) {
        struct conn *c = &w->conns[i];
        if (!c->used || c->dying || !c->tried) continue;
        if (lease_expired(&servers[routes[c->route].s[c->slot]], now)) {
            w->st.fenced++; conn_kill(w, c); conn_maybe_free(w, c);
        }
    }
}

static void on_accept(struct worker *w, unsigned li, int res, unsigned flags) {
    const struct listener *l = &listeners[li];
    if (!(flags & IORING_CQE_F_MORE)) {
        if (res == -EMFILE || res == -ENFILE || res == -ENOMEM || res == -ENOBUFS) {
            w->accept_paused = 1; w->accept_paused_mask |= 1u << li;
            w->accept_retry_ms = now_ms() + 100;              // retry later, don't spin
        } else if (!w->drained) accept_arm(w, li);
    }
    if (res < 0) return;
    int cfd = res;                             // TCP_NODELAY inherited from the listener
    uint32_t slot;
    struct conn *c = conn_alloc(w, &slot);
    if (!c) { fd_close(w, cfd); return; }
    c->cfd = cfd;
    w->st.accepted++;
    if (l->smart_ack) {                        // a ring socket command needs Linux 6.7
        if (cfg.ring_socket) ring_setsockopt(w, cfd, TCP_QUICKACK, &zero_opt, 0);
        else setsockopt(cfd, IPPROTO_TCP, TCP_QUICKACK, &zero_opt, sizeof zero_opt);
    }
    c->route = (uint8_t)route_default(l);     // the default route, unless SNI picks another
    if (l->nroutes) peek_arm(w, c, 0);        // route first: the ClientHello is usually queued already
    else conn_connect(w, c);
    conn_maybe_free(w, c);                    // socket() failed
}

static void dispatch(struct worker *w, struct io_uring_cqe *cqe) {
    uint64_t ud = cqe->user_data;
    if (ud == UD_IGNORE) return;
    unsigned kind = (ud >> 1) & 15, d = ud & 1;
    if (kind == K_ACCEPT) { on_accept(w, (unsigned)(ud >> 8) & 0xff, cqe->res, cqe->flags); return; }
    if (kind == K_FENCE) { fence_arm(w); on_fence(w); return; }
    if (kind == K_SWEEP) { sweep_arm(w); sweep(w); return; }
    uint32_t slot = (uint32_t)(ud >> 8), gen = (uint32_t)(ud >> 40);
    struct conn *c = &w->conns[slot];
    if (slot >= cfg.maxconn || !c->used || c->gen != gen) { w->st.stale++; return; }
    int res = cqe->res;
    c->inflight--;
    if (res > 0) c->last = w->now;            // bytes moved (or a poll fired): the conn is alive
    switch (kind) {
    case K_CONNECT: on_connect(w, c, res); break;
    case K_RECV: on_recv(w, c, d, res, cqe->flags); break;
    case K_SEND: on_send(w, c, d, res); break;
    case K_PIN:
        if (cfg.mode == M_SPLICE) { if (!c->dying) { if (res < 0) conn_kill(w, c); else wq_chain(w, c, d); } }
        else on_poll(w, c, d, res);
        break;
    case K_POUT: on_poll(w, c, d, res); break;
    case K_WQ_IN: case K_WQ_OUT: case K_WQ_POUT: wq_done(w, c, d, kind, res); break;
    case K_PEEK: on_peek(w, c, res, cqe->flags); break;
    case K_SOCKET: on_socket(w, c, res); break;
    }
    conn_maybe_free(w, c);
}

// ========================================================= EPOLL ENGINE ====
// The same data path without io_uring, for hosts that block it. One epoll set per worker; both
// sockets of a conn join it once, edge-triggered for IN, OUT and RDHUP, and are never modified
// again (no epoll_ctl on the data path). Events only set per-direction flags (rd: the source may
// have bytes, wr: the destination may take bytes, rdhup: the source has its FIN); ep_pump then
// moves bytes until a syscall says EAGAIN, which clears the flag, so the next edge sets it again.
// The event's data is the same tag as io_uring's user_data: (slot, generation, kind).
//   copy    recv into the worker's scratch buffer and send it on at once: an idle conn holds no
//           buffer. A partial send parks the rest in a pooled pipe (a pool buffer only if the pipe
//           is too small) and drains it with splice before reading more.
//   splice  src -> pipe -> dst, as the inline splice engine (--mode isplice; hybrid switches as above)
// A short read means the socket is drained (the next bytes raise a new edge), so keep-alive traffic
// costs one recv and one send per message, no EAGAIN probe. A short read with the FIN already seen
// sends the data with MSG_MORE and the FIN right behind it, as probe_eof does, without the probe.
// Timeouts: hello and connect deadlines run on the sweep, driven by a timerfd.
#define EP_EVENTS 512

static inline uint64_t ep_ud(struct worker *w, struct conn *c, unsigned kind, unsigned seq) {
    return UD(w, c, kind, 0) | (uint64_t)(seq & 7) << 5;
}

static int ep_ctl(struct worker *w, int op, int fd, uint32_t events, uint64_t ud) {
    struct epoll_event ev = { .events = events, .data.u64 = ud };
    return epoll_ctl(w->epfd, op, fd, &ev);
}

#define EP_SOCK (EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET)

// Budget used up with work left: run the direction again after this batch of events.
static void ep_defer(struct worker *w, struct conn *c, int d) {
    if (c->d[d].queued) return;
    c->d[d].queued = 1;
    waiter_push(w, c, d);
}

// The bytes the destination did not take go into a pipe; what the pipe cannot hold goes into a pool
// buffer. -1: neither (the conn is closed).
static int ep_spill(struct worker *w, struct conn *c, int d, const unsigned char *p, uint32_t n) {
    struct dir *x = &c->d[d];
    w->st.spills++;
    if (pipe_get(w, x) == 0) {
        ssize_t k = write(x->pipe_w, p, n);
        if (k > 0) { x->in_pipe += k; p += k; n -= k; }
        if (!n) return 0;
    }
    if (!w->nbfree) { w->st.enobufs++; return -1; }
    x->bid = (int32_t)w->bfree[--w->nbfree]; w->bufs_out++;
    memcpy(BUF(w, x->bid), p, n);
    x->off = 0; x->len = n;
    return 0;
}

static void ep_pump(struct worker *w, struct conn *c, int d) {
    struct dir *x = &c->d[d];
    if (c->dying || x->shut) return;
    uint32_t moved = 0;
    int drained = 0;
    for (int it = 0; ; it++) {
        if (it == PUMP_BUDGET) { ep_defer(w, c, d); return; }
        if (x->in_pipe) {                                     // parked or spliced bytes go first
            if (!x->wr) return;
            ssize_t n = splice(x->pipe_r, NULL, x->dst, NULL, x->in_pipe, SPLICE_F_NONBLOCK | SPLICE_F_MOVE);
            w->st.splices++;
            if (n > 0) { x->in_pipe -= n; c->last = w->now; continue; }
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && errno == EAGAIN) { x->wr = 0; return; }
            conn_kill(w, c); return;
        }
        if (x->bid >= 0) {                                    // what the pipe could not take
            if (!x->wr) return;
            ssize_t n = send(x->dst, BUF(w, x->bid) + x->off, x->len - x->off, MSG_DONTWAIT | MSG_NOSIGNAL);
            if (n > 0) { x->off += n; c->last = w->now; if (x->off == x->len) release_buf(w, x); continue; }
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && errno == EAGAIN) { x->wr = 0; return; }
            conn_kill(w, c); return;
        }
        if (x->eof) { dir_finish(w, c, d); return; }
        if (!x->rd) break;
        if (x->eng == E_SPLICE) {
            if (pipe_get(w, x) < 0) { conn_kill(w, c); return; }
            ssize_t n = splice(x->src, NULL, x->pipe_w, NULL, x->pcap, SPLICE_F_NONBLOCK | SPLICE_F_MOVE);
            w->st.splices++;
            if (n > 0) { x->in_pipe = n; moved += n; c->last = w->now; continue; }   // short: maybe more
            if (n == 0) { x->eof = 1; continue; }
            if (errno == EINTR) continue;
            if (errno == EAGAIN) { x->rd = 0; drained = 1; continue; }
            conn_kill(w, c); return;
        }
        if (!x->wr) return;                                   // back-pressure: read once it can be sent
        ssize_t n = recv(x->src, w->scratch, cfg.bufsz, MSG_DONTWAIT);
        if (n > 0) {
            c->last = w->now;
            int fin = 0;
            if ((size_t)n < cfg.bufsz) { x->rd = 0; drained = 1; fin = x->rdhup; }   // drained; FIN next?
            ssize_t s = send(x->dst, w->scratch, n, MSG_DONTWAIT | MSG_NOSIGNAL | (fin ? MSG_MORE : 0));
            if (s < 0 && (errno == EAGAIN || errno == EINTR)) s = 0;
            if (s < 0) { conn_kill(w, c); return; }
            if (s < n) {
                x->wr = 0;
                if (ep_spill(w, c, d, w->scratch + s, (uint32_t)(n - s)) < 0) { conn_kill(w, c); return; }
            }
            if (fin) { x->eof = 1; if (s == n) w->st.fin_merged++; }
            x->big = (size_t)n >= cfg.bulk ? x->big + 1 : 0;
            if (cfg.mode == M_HYBRID && x->big >= cfg.big_n) {   // bulk stream: move it into the kernel
                x->eng = E_SPLICE; x->big = 0; x->small = 0; w->st.to_splice++;
            }
            continue;
        }
        if (n == 0) { x->eof = 1; continue; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN) { x->rd = 0; drained = 1; continue; }
        conn_kill(w, c); return;
    }
    // the source is drained and nothing is pending
    if (drained && x->eng == E_SPLICE && cfg.mode == M_HYBRID) {
        x->small = moved < cfg.bulk ? x->small + 1 : 0;
        if (x->small >= cfg.small_n) { x->small = 0; x->big = 0; x->eng = E_COPY; w->st.to_copy++; }
    }
    pipe_put(w, x);                                           // idle directions hold no pipe
}

static void ep_run_deferred(struct worker *w) {
    for (unsigned n = w->wq_n; n && w->wq_n; n--) {           // only what was queued before this pass
        struct waiter wt = w->wq[w->wq_head];
        w->wq_head = (w->wq_head + 1) & (w->wq_cap - 1);
        w->wq_n--;
        struct conn *c = &w->conns[wt.slot];
        if (!c->used || c->gen != wt.gen) { w->st.stale++; continue; }
        c->d[wt.d].queued = 0;
        ep_pump(w, c, wt.d);
        conn_maybe_free(w, c);
    }
}

// Connected (called through start_dirs). The ClientHello of an SNI conn is still queued.
static void ep_start(struct worker *w, struct conn *c) {
    uint8_t eng = (cfg.mode == M_ISPLICE || cfg.mode == M_SPLICE) ? E_SPLICE : E_COPY;
    c->d[0].eng = c->d[1].eng = eng;
    c->d[0].wr = 1;
    if (listeners[routes[c->route].lis].nroutes) c->d[0].rd = 1;
    ep_pump(w, c, 0);
    ep_pump(w, c, 1);
}

// The backend socket exists (conn_connect); a non-blocking connect, completed by its EPOLLOUT. The
// connect timeout is the sweep's. A new socket gets a new seq, so events of a closed one are stale.
static void ep_connect(struct worker *w, struct conn *c) {
    c->bseq = (c->bseq + 1) & 7;
    c->d[1].rd = c->d[1].rdhup = 0; c->d[0].wr = 0;
    if (ep_ctl(w, EPOLL_CTL_ADD, c->bfd, EP_SOCK, ep_ud(w, c, K_EP_B, c->bseq)) < 0) { conn_kill(w, c); return; }
    c->connecting = 1; c->last = w->now;
    if (connect(c->bfd, &c->baddr.sa, c->blen) == 0) { c->connecting = 0; on_connect(w, c, 0); }   // -F
    else if (errno != EINPROGRESS) { c->connecting = 0; on_connect(w, c, -errno); }
}

static void ep_connected(struct worker *w, struct conn *c, uint32_t ev) {
    int err = 0; socklen_t len = sizeof err;
    if (getsockopt(c->bfd, SOL_SOCKET, SO_ERROR, &err, &len) < 0) err = errno;
    if (!err && !(ev & EPOLLOUT)) return;
    c->connecting = 0;
    on_connect(w, c, -err);
}

// on_peek's logic on a plain MSG_PEEK. An event can arrive for bytes an earlier peek already saw, so
// a peek that finds nothing new means a FIN only once RDHUP was reported.
static void ep_peek(struct worker *w, struct conn *c) {
    ssize_t n = recv(c->cfd, w->scratch, cfg.bufsz, MSG_PEEK | MSG_DONTWAIT);
    if (n < 0 && (errno == EAGAIN || errno == EINTR)) { c->d[0].rd = 0; return; }
    if (n <= 0) { conn_kill(w, c); return; }                  // EOF before a ClientHello, or an error
    w->st.peeks++;
    if ((uint32_t)n <= c->peeked) {
        if (c->d[0].rdhup) { w->st.sni_bad++; conn_kill(w, c); } else c->d[0].rd = 0;
        return;
    }
    const struct listener *l = &listeners[routes[c->route].lis];
    uint32_t need = 0;
    int r = sni_route(w, l, w->scratch, (uint32_t)n, &need);
    if (r == SNI_NEED && need <= cfg.bufsz) {                 // sleep until `need` bytes are queued
        c->peeked = (uint32_t)n; c->d[0].rd = 0;
        if (setsockopt(c->cfd, SOL_SOCKET, SO_RCVLOWAT, &(int){ (int)need }, sizeof(int)) == 0) c->lowat = 1;
        return;
    }
    if (r < 0) { w->st.sni_bad++; conn_kill(w, c); return; }  // not TLS, or too big
    if (c->lowat) setsockopt(c->cfd, SOL_SOCKET, SO_RCVLOWAT, &(int){ 1 }, sizeof(int));
    if (r == route_default(l)) w->st.sni_default++; else w->st.sni_routed++;
    c->route = (uint8_t)r;
    conn_connect(w, c);
}

static void ep_accept(struct worker *w, unsigned li) {
    const struct listener *l = &listeners[li];
    for (int i = 0; i < 64 || w->drained; i++) {              // level-triggered: the rest is reported again
        int cfd = accept4(w->lfd[li], NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (cfd < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            if (errno == EMFILE || errno == ENFILE || errno == ENOMEM || errno == ENOBUFS) {
                epoll_ctl(w->epfd, EPOLL_CTL_DEL, w->lfd[li], NULL);
                w->accept_paused = 1; w->accept_paused_mask |= 1u << li;
                w->accept_retry_ms = now_ms() + 100;          // retry later, don't spin
            }
            return;
        }
        uint32_t slot;
        struct conn *c = conn_alloc(w, &slot);
        if (!c) { close(cfd); continue; }
        c->cfd = cfd;
        w->st.accepted++;
        if (l->smart_ack) setsockopt(cfd, IPPROTO_TCP, TCP_QUICKACK, &zero_opt, sizeof zero_opt);
        c->route = (uint8_t)route_default(l);
        if (ep_ctl(w, EPOLL_CTL_ADD, cfd, EP_SOCK, ep_ud(w, c, K_EP_C, 0)) < 0) conn_kill(w, c);
        else if (l->nroutes) { c->d[0].rd = 1; ep_peek(w, c); }   // the ClientHello is usually queued already
        else conn_connect(w, c);
        conn_maybe_free(w, c);
    }
}

static void ep_event(struct worker *w, uint64_t ud, uint32_t ev) {
    unsigned kind = (ud >> 1) & 15;
    uint64_t v;
    if (kind == K_ACCEPT) { ep_accept(w, (unsigned)(ud >> 8) & 0xff); return; }
    if (kind == K_FENCE) { if (read(w->efd, &v, sizeof v) < 0) {} on_fence(w); return; }
    if (kind == K_SWEEP) { if (read(w->tfd, &v, sizeof v) < 0) {} sweep(w); return; }
    uint32_t slot = (uint32_t)(ud >> 8), gen = (uint32_t)(ud >> 40);
    struct conn *c = &w->conns[slot];
    int s = kind == K_EP_B;                                   // 0: the client socket, 1: the backend's
    if (slot >= cfg.maxconn || !c->used || c->gen != gen || c->dying || (s && ((ud >> 5) & 7) != c->bseq)) {
        w->st.stale++; return;
    }
    // socket s is the source of direction s and the destination of the other one
    if (ev & (EPOLLIN | EPOLLRDHUP | EPOLLHUP | EPOLLERR)) c->d[s].rd = 1;
    if (ev & (EPOLLRDHUP | EPOLLHUP)) c->d[s].rdhup = 1;
    if (ev & (EPOLLOUT | EPOLLHUP | EPOLLERR)) c->d[s ^ 1].wr = 1;
    if (c->connecting) { if (s) ep_connected(w, c, ev); }
    else if (c->bfd < 0) { if (!s && c->d[0].rd) ep_peek(w, c); }   // routing
    else { ep_pump(w, c, 0); ep_pump(w, c, 1); }
    conn_maybe_free(w, c);
}

static void housekeeping(struct worker *w);

static void ep_loop(struct worker *w) {
    struct epoll_event ev[EP_EVENTS];
    for (;;) {
        int tmo = w->wq_n ? 0 : (w->accept_paused || cfg.verbose) ? 100 : -1;
        int n = epoll_wait(w->epfd, ev, EP_EVENTS, tmo);
        if (n < 0 && errno != EINTR) fatal("epoll_wait");
        lease_check(w);
        for (int i = 0; i < n; i++) ep_event(w, ev[i].data.u64, ev[i].events);
        ep_run_deferred(w);
        if (cfg.batch_n && n > 0 && (unsigned)n < cfg.batch_n) {      // --batch: a light pass, so let
            struct timespec ts = { 0, (long)cfg.batch_us * 1000 };     // events collect (as unorig-username's
            nanosleep(&ts, NULL);                                       // 2 ms after < 32 events)
        }
        if (w->accept_paused || cfg.verbose) housekeeping(w);
    }
}

static void ep_init(struct worker *w) {
    w->epfd = epoll_create1(EPOLL_CLOEXEC);
    w->scratch = malloc(cfg.bufsz);
    w->bfree = malloc(cfg.nbufs * sizeof *w->bfree);
    if (w->epfd < 0 || !w->scratch || !w->bfree) fatal("epoll init");
    for (unsigned i = 0; i < cfg.nbufs; i++) w->bfree[i] = cfg.nbufs - 1 - i;
    w->nbfree = cfg.nbufs;
    for (unsigned li = 0; li < cfg.nlisteners; li++)
        if (ep_ctl(w, EPOLL_CTL_ADD, w->lfd[li], EPOLLIN, mkud(li, 0, K_ACCEPT, 0)) < 0) fatal("epoll_ctl");
    if (w->efd >= 0 && ep_ctl(w, EPOLL_CTL_ADD, w->efd, EPOLLIN, UD_FENCE) < 0) fatal("epoll_ctl");
    w->tfd = -1;
    if (cfg.ep_sweep_ms) {
        w->tfd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
        struct timespec p = { cfg.ep_sweep_ms / 1000, (cfg.ep_sweep_ms % 1000) * 1000000L };
        struct itimerspec its = { p, p };
        if (w->tfd < 0 || timerfd_settime(w->tfd, 0, &its, NULL) < 0 ||
            ep_ctl(w, EPOLL_CTL_ADD, w->tfd, EPOLLIN, UD_SWEEP) < 0) fatal("timerfd");
    }
}

// -l PORT listens on every address: one IPv6 socket that also takes IPv4 (IPV6_V6ONLY off), or plain
// IPv4 where the kernel has no IPv6. -l ADDR:PORT listens on that address only.
static int make_listener(const struct listener *l) {
    union sa a; socklen_t alen;
    int fam = l->bind.fam ? l->bind.fam : AF_INET6;
    int fd = socket(fam, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0 && !l->bind.fam) fd = socket(fam = AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) fatal("socket");
    if (l->bind.fam) alen = ep_sa(&l->bind, l->port, &a);
    else {
        struct ep any = { .fam = (uint16_t)fam };                 // all-zero address: :: or 0.0.0.0
        alen = ep_sa(&any, l->port, &a);
        int zero = 0;
        if (fam == AF_INET6) setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof zero);
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);   // one listener per worker
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);   // inherited by accepted sockets
    if (l->smart_ack) {                      // as HAProxy tcp-smart-accept: set before any client arrives
        int zero = 0;
        setsockopt(fd, IPPROTO_TCP, TCP_QUICKACK, &zero, sizeof zero);
    }
    if (cfg.defer_accept)                    // accept only once the client has sent data (1 s cap)
        setsockopt(fd, IPPROTO_TCP, TCP_DEFER_ACCEPT, &one, sizeof one);
    if (bind(fd, &a.sa, alen) < 0) {
        if (l->bind.fam || fam != AF_INET6) fatal("bind");
        close(fd);                                            // IPv6 off (a container): IPv4 only
        struct listener v4 = *l;
        v4.bind = (struct ep){ .fam = AF_INET };
        return make_listener(&v4);
    }
    if (listen(fd, SOMAXCONN) < 0) fatal("listen");
    return fd;
}

static int ring_init(struct io_uring *r) {
    unsigned tries[3]; int n = 0;
    if (cfg.ringmode == RING_AUTO || cfg.ringmode == RING_DEFER) tries[n++] = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN;
    if (cfg.ringmode == RING_AUTO || cfg.ringmode == RING_COOP)  tries[n++] = IORING_SETUP_COOP_TASKRUN;
    if (cfg.ringmode == RING_AUTO || cfg.ringmode == RING_PLAIN) tries[n++] = 0;
    int ret = -EINVAL;
    for (int i = 0; i < n; i++) {
        struct io_uring_params p;
        memset(&p, 0, sizeof p);
        p.flags = tries[i] | IORING_SETUP_CQSIZE | IORING_SETUP_SUBMIT_ALL;
        p.cq_entries = CQ_ENTRIES;
        ret = io_uring_queue_init_params(RING_ENTRIES, r, &p);
        if (ret == 0) return 0;
        if (ret != -EINVAL) break;
    }
    return ret;
}

static cpu_set_t allowed;
static int nth_allowed_cpu(int n) {
    int tot = CPU_COUNT(&allowed);
    n %= tot;
    for (int i = 0, k = 0; i < CPU_SETSIZE; i++)
        if (CPU_ISSET(i, &allowed) && k++ == n) return i;
    return 0;
}

static int sni_any(void) {
    for (unsigned li = 0; li < cfg.nlisteners; li++) if (listeners[li].nroutes) return 1;
    return 0;
}

static void print_stats(struct worker *w) {
    fprintf(stderr, "[w%d] active=%u accepted=%lu to_splice=%lu to_copy=%lu spills=%lu enobufs=%lu "
            "splices=%lu kills=%lu stale=%lu pipes_pooled=%d fin_merged=%lu", w->id, w->active,
            w->st.accepted, w->st.to_splice, w->st.to_copy, w->st.spills, w->st.enobufs,
            w->st.splices, w->st.kills, w->st.stale, w->npipes, w->st.fin_merged);
    fprintf(stderr, " connect_fail=%lu retries=%lu no_server=%lu fenced=%lu idle_closed=%lu half_closed=%lu",
            w->st.connect_fail, w->st.retries, w->st.no_server, w->st.fenced, w->st.idle_closed, w->st.half_closed);
    if (sni_any())
        fprintf(stderr, " peeks=%lu sni_routed=%lu sni_default=%lu sni_bad=%lu",
                w->st.peeks, w->st.sni_routed, w->st.sni_default, w->st.sni_bad);
    fputc('\n', stderr);
}

static int kernel_at_least(int maj, int min) {
    struct utsname u; int a = 0, b = 0;
    if (uname(&u) == 0) sscanf(u.release, "%d.%d", &a, &b);
    return a > maj || (a == maj && b >= min);
}

// io_uring with everything a worker uses: NULL, or why not (then epoll). EPERM / ENOSYS:
// kernel.io_uring_disabled or a seccomp profile (Docker, containerd); ENOMEM: the memlock limit.
static const char *uring_why(int err, const char *what) {
    static __thread char why[160];
    const char *hint = err == EPERM ? " (kernel.io_uring_disabled, or a seccomp profile)" :
                       err == ENOSYS ? " (a seccomp profile, or a kernel without io_uring)" :
                       err == ENOMEM ? " (memlock limit: ulimit -l / Docker ulimits memlock)" : "";
    snprintf(why, sizeof why, "%s: %s%s", what, strerror(err), hint);
    return why;
}

// liburing's io_uring_setup_buf_ring, plus a retry: Ubuntu 24.04's 6.8.0-147 kernel checks the
// registration's reserved field the wrong way round (EINVAL on a zeroed one, which every correct
// kernel requires), found by c-iouring-einhornimmond. Without the retry --io auto ran epoll there.
static struct io_uring_buf_ring *buf_ring_setup(struct io_uring *r, unsigned n, int *err) {
    size_t sz = (size_t)n * sizeof(struct io_uring_buf);
    struct io_uring_buf_ring *br = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    if (br == MAP_FAILED) { *err = -errno; return NULL; }
    struct io_uring_buf_reg reg = { .ring_addr = (uint64_t)(uintptr_t)br, .ring_entries = n, .bgid = BGID };
    io_uring_buf_ring_init(br);
    int ret = io_uring_register_buf_ring(r, &reg, 0);
    if (ret == -EINVAL) { reg.resv[0] = 1; ret = io_uring_register_buf_ring(r, &reg, 0); }
    if (ret) { munmap(br, sz); *err = ret; return NULL; }
    return br;
}

static const char *ring_setup(struct worker *w) {
    int ret = ring_init(&w->ring);
    if (ret < 0) return uring_why(-ret, "io_uring_setup");
    if (cfg.iowq) { unsigned v[2] = { 0, cfg.iowq }; io_uring_register_iowq_max_workers(&w->ring, v); }
    if (cfg.mode == M_COPY || cfg.mode == M_HYBRID || sni_any()) {       // SNI peeks use the pool too
        int err;
        w->br = buf_ring_setup(&w->ring, cfg.nbufs, &err);
        if (!w->br) { io_uring_queue_exit(&w->ring); return uring_why(-err, "buf ring"); }
        w->br_mask = io_uring_buf_ring_mask(cfg.nbufs);
        for (unsigned i = 0; i < cfg.nbufs; i++)
            io_uring_buf_ring_add(w->br, BUF(w, i), cfg.bufsz, i, w->br_mask, i);
        io_uring_buf_ring_advance(w->br, cfg.nbufs);
    }
    return NULL;
}

// once at startup, for the log line and to choose for every worker; a worker whose own ring still
// fails (e.g. the memlock limit, counted per user) falls back on its own
static const char *uring_probe(void) {
    if (!kernel_at_least(6, 1)) return "kernel older than 6.1";
    struct io_uring r;
    int ret = ring_init(&r);
    if (ret < 0) return uring_why(-ret, "io_uring_setup");
    int err = 0;
    struct io_uring_buf_ring *br = buf_ring_setup(&r, cfg.nbufs, &err);
    if (br) { io_uring_unregister_buf_ring(&r, BGID); munmap(br, (size_t)cfg.nbufs * sizeof(struct io_uring_buf)); }
    io_uring_queue_exit(&r);
    return br ? NULL : uring_why(-err, "buf ring");
}

static void housekeeping(struct worker *w) {
    uint64_t t = now_ms();
    if (w->accept_paused && t >= w->accept_retry_ms) {
        for (unsigned li = 0; li < cfg.nlisteners; li++) {
            if (!(w->accept_paused_mask >> li & 1)) continue;
            if (w->epoll) ep_ctl(w, EPOLL_CTL_ADD, w->lfd[li], EPOLLIN, mkud(li, 0, K_ACCEPT, 0));
            else accept_arm(w, li);
        }
        w->accept_paused = 0; w->accept_paused_mask = 0;
    }
    if (cfg.verbose && t >= w->next_stats_ms) { print_stats(w); w->next_stats_ms = t + 5000; }
}

// --batch N:US (off by default): after a pass that had work, wait for N completions or US
// microseconds, whichever comes first, so one kernel entry and one pass serve many connections
// (c-iouring-einhornimmond: 32 / 1 ms). Idle, the loop still wakes on the first completion. The cost
// is latency: up to US per hop, twice per exchange through a proxy.
static void ring_loop(struct worker *w) {
    unsigned seen = 0;
    for (;;) {
        struct io_uring_cqe *first;
        int ret;
        if (cfg.batch_n && seen) {
            struct __kernel_timespec ts = { 0, (long long)cfg.batch_us * 1000 };
            ret = io_uring_submit_and_wait_timeout(&w->ring, &first, cfg.batch_n, &ts, NULL);
        } else if (w->accept_paused || cfg.verbose) {
            struct __kernel_timespec ts = { 0, 100 * 1000 * 1000 };
            ret = io_uring_submit_and_wait_timeout(&w->ring, &first, 1, &ts, NULL);
        } else {
            ret = io_uring_submit_and_wait(&w->ring, 1);
        }
        if (ret < 0 && ret != -EINTR && ret != -EAGAIN && ret != -EBUSY && ret != -ETIME) {
            fprintf(stderr, "submit_and_wait: %s\n", strerror(-ret)); exit(1);
        }
        unsigned head;
        struct io_uring_cqe *cqe;
        seen = 0;
        lease_check(w);
        io_uring_for_each_cqe(&w->ring, head, cqe) { dispatch(w, cqe); seen++; }
        io_uring_cq_advance(&w->ring, seen);
        if (w->br) cp_batch_end(w);
        if (w->accept_paused || cfg.verbose) housekeeping(w);
    }
}

static void *worker_main(void *arg) {
    struct worker *w = arg;
    if (cfg.pin) {
        cpu_set_t s; CPU_ZERO(&s); CPU_SET(nth_allowed_cpu(w->id), &s);
        pthread_setaffinity_np(pthread_self(), sizeof s, &s);
    }

    // connection pool: reserved once, touched lazily; free-slot stack hands out low slots first
    w->conns = mmap(NULL, (size_t)cfg.maxconn * sizeof(struct conn), PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    w->freeslots = malloc((size_t)cfg.maxconn * sizeof(uint32_t));
    w->pipes = malloc(PIPE_POOL_MAX * sizeof *w->pipes);
    if (w->conns == MAP_FAILED || !w->freeslots || !w->pipes) fatal("pool alloc");
    for (uint32_t i = 0; i < cfg.maxconn; i++) w->freeslots[i] = cfg.maxconn - 1 - i;
    w->nfree = cfg.maxconn;
    if (sni_any() && !(w->hs = malloc(cfg.bufsz))) fatal("malloc");
    // buffer pool: io_uring's provided buffers; under epoll only for spills a pipe cannot take
    w->bufs = mmap(NULL, (size_t)cfg.nbufs * cfg.bufsz, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (w->bufs == MAP_FAILED) fatal("mmap");

    w->epoll = cfg.io == IO_EPOLL;
    if (!w->epoll) {
        const char *why = ring_setup(w);
        if (why && cfg.io == IO_URING) { fprintf(stderr, "%s\n", why); exit(1); }
        if (why) { fprintf(stderr, "[w%d] %s; using epoll\n", w->id, why); w->epoll = 1; }
    }

    for (unsigned li = 0; li < cfg.nlisteners; li++) w->lfd[li] = make_listener(&listeners[li]);
    w->next_stats_ms = now_ms() + 5000;
    w->now = (uint32_t)now_ms();
    if (w->epoll) { ep_init(w); ep_loop(w); return NULL; }

    for (unsigned li = 0; li < cfg.nlisteners; li++) accept_arm(w, li);
    if (w->efd >= 0) fence_arm(w);
    if (cfg.sweep_ms) {
        w->sweep_ts = (struct __kernel_timespec){ cfg.sweep_ms / 1000, (cfg.sweep_ms % 1000) * 1000000LL };
        sweep_arm(w);
    }
    ring_loop(w);
    return NULL;
}

// ========================================================= BACKENDS ======
// Two plain threads keep the slots current, off the data path; workers only read two atomics per
// slot and, when a connect fails, mark that slot down.
//   resolver  every --resolve-interval ms, getaddrinfo() for each DNS target (in Docker: its DNS
//             at 127.0.0.11, via resolv.conf; several A records = several replicas). A new address
//             takes a free slot of its target and is up at once (a failed connect marks it down
//             again); an address missing from the answers for --dns-hold ms is dropped. A failed
//             lookup (timeout, SERVFAIL) keeps what is there; "no such name" empties the target.
//   checker   health checks, --check for local targets and --backup-check for backups: every
//             --check-interval ms (every 250 ms while a slot is changing state), --fall failures
//             in a row mark it down, --rise successes up. A connect that failed on live traffic
//             marks the slot down at once; the checker must then see --rise successes. Without
//             checks such a slot is tried again after --check-interval ms.
#define FASTINTER_MS 250
static pthread_mutex_t ctl_lock = PTHREAD_MUTEX_INITIALIZER;   // control-plane fields of the slots

// A server's address changes only through these, under ctl_lock (see struct slot).
static uint64_t addr_seq;
static void slot_put(struct slot *s, const struct ep *e) {
    s->ep = *e;
    atomic_store_explicit(&s->addr, ++addr_seq, memory_order_release);
}
static void slot_clear(struct slot *s) { atomic_store(&s->addr, 0); }   // ep stays for the log line

// Wall-clock HH:MM:SS.mmm (UTC) of ms since the epoch, so the lines line up with other logs.
static void fmt_clock(uint64_t ms, char *out, size_t n) {
    time_t t = (time_t)(ms / 1000);
    struct tm tm;
    gmtime_r(&t, &tm);
    snprintf(out, n, "%02d:%02d:%02d.%03u", tm.tm_hour, tm.tm_min, tm.tm_sec, (unsigned)(ms % 1000));
}

static void slot_log(struct slot *s, const char *what) {
    char buf[64], at[16];
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ep_fmt(&s->ep, buf, sizeof buf);
    fmt_clock((uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000, at, sizeof at);
    fprintf(stderr, "%s backend %s %s%s: %s\n", at, s->t->label, buf, s->backup ? " (backup)" : "", what);
}

// --cut-on-down: a server going down also cuts the sessions open to it (a database losing its
// write lease). up=0 first, then the epoch (both seq_cst); a worker reads the epoch before up, so a
// session it opens either saw up=0 or carries the old epoch and is cut by the scan the wakeup starts.
// cut: close its sessions whatever --cut-on-down says (the control socket's "cut"). A server in
// maintenance stays down whatever the checks say.
static void slot_change(struct slot *s, int up, const char *why, int cut) {
    if (up && (s->maint || lease_expired(s, boot_ms()))) return;
    atomic_store(&s->up, (uint8_t)up);
    if (!up && (cut || (s->seen_up && s->t->pol->cut_on_down))) {
        atomic_fetch_add(&s->epoch, 1);
        wake_workers();
    }
    if (s->seen_up != up) {
        char m[160];
        snprintf(m, sizeof m, "%s%s%s", up ? "UP" : "DOWN", why ? ", " : "", why ? why : "");
        slot_log(s, m);
    }
    s->seen_up = (uint8_t)up;
}

static void slot_set_up(struct slot *s, int up, const char *why) { slot_change(s, up, why, 0); }

static inline uint8_t initial_up(const struct target *t) {
    return t->backup || (!t->pol->start_down && !t->pol->lease_required);
}

// --lease-required: a new local server starts fenced (a lease already expired) until its first
// "lease", so a proxy restarted after the arbiter resigned does not serve the old writer
static void lease_init(struct slot *s) {
    atomic_store(&s->lease_until, !s->backup && s->t->pol->lease_required ? 1 : 0);
}

// now: the agent's "resolve" after a Docker event, an answer to trust; an address missing from it goes
// at once (Docker may give that IP to another container), not after --dns-hold, which is for flaps
static void resolve_target(struct target *t, int now_drop) {
    struct addrinfo hints = { .ai_family = cfg.dns_family, .ai_socktype = SOCK_STREAM }, *res = NULL;
    int e = getaddrinfo(t->host, NULL, &hints, &res);
    if (e && e != EAI_NONAME) return;                     // transient: keep the current set
    struct ep ips[MAX_SLOTS]; unsigned n = 0;
    for (struct addrinfo *a = e ? NULL : res; a && n < MAX_SLOTS; a = a->ai_next) {
        struct ep x = { .fam = (uint16_t)a->ai_family, .port = t->port };
        if (a->ai_family == AF_INET) memcpy(x.ip, &((struct sockaddr_in *)a->ai_addr)->sin_addr, 4);
        else if (a->ai_family == AF_INET6) memcpy(x.ip, &((struct sockaddr_in6 *)a->ai_addr)->sin6_addr, 16);
        else continue;
        unsigned k = 0;
        while (k < n && memcmp(&ips[k], &x, sizeof x)) k++;
        if (k == n) ips[n++] = x;
    }
    if (res) freeaddrinfo(res);
    uint64_t now = now_ms();
    pthread_mutex_lock(&ctl_lock);
    for (unsigned i = t->first; i < t->first + t->n; i++) {           // known addresses: still there?
        struct slot *s = &servers[i];
        if (!atomic_load(&s->addr)) continue;
        unsigned k = 0;
        while (k < n && memcmp(&ips[k], &s->ep, sizeof s->ep)) k++;
        if (k < n) {
            ips[k] = ips[--n];
            if (s->gone_ms) {                                         // back in DNS (restarted container)
                s->gone_ms = 0; s->ok = s->bad = 0; s->next_ms = now;
                slot_set_up(s, initial_up(t), "back in DNS");
            }
        } else if (!now_drop && !s->gone_ms) {
            s->gone_ms = now;
        } else if (now_drop || now - s->gone_ms >= cfg.hold_ms) {
            atomic_store(&s->up, 0);
            slot_clear(s);
            slot_log(s, "removed (gone from DNS)");
        }
    }
    for (unsigned k = 0; k < n; k++) {                                // new addresses: a free server each
        unsigned i = t->first;
        while (i < t->first + t->n && atomic_load(&servers[i].addr)) i++;
        if (i == t->first + t->n) {
            if (t->full_warned) break;
            t->full_warned = 1;
            fprintf(stderr, "backend %s: %s has more addresses than --dns-slots %u; the rest are not used\n", t->label, t->host, t->n);
            break;
        }
        struct slot *s = &servers[i];
        uint8_t up = initial_up(t);
        s->ok = s->bad = 0; s->gone_ms = 0; s->down_ms = 0; s->next_ms = now; s->seen_up = up;
        atomic_store(&s->failed, 0); lease_init(s);
        slot_put(s, &ips[k]);                                      // address first, then up
        atomic_store(&s->up, up);
        slot_log(s, "added (DNS)");
    }
    pthread_mutex_unlock(&ctl_lock);
}

static void resolve_all(void) {
    for (unsigned ti = 0; ti < ntargets; ti++)
        if (targets[ti].dns) resolve_target(&targets[ti], 0);
}

static void *resolver_main(void *arg) {
    (void)arg;
    for (;;) { usleep(cfg.resolve_ms * 1000); resolve_all(); }
    return NULL;
}

// one health check in flight: non-blocking connect, then (http) a GET and its status line
enum { P_IDLE, P_CONNECT, P_READ };
struct probe { int fd, state; uint64_t addr, deadline; unsigned n; char buf[64]; };

static void probe_close(struct probe *p) {
    if (p->fd >= 0) close(p->fd);
    p->fd = -1; p->state = P_IDLE;
}

static inline const struct check *slot_check(const struct slot *s) {
    return s->backup ? &s->t->pol->bcheck : &s->t->pol->check;
}

// a check result, applied under ctl_lock; dropped if the server changed address meanwhile
static void probe_result(struct slot *s, struct probe *p, int ok, const char *why, uint64_t now) {
    const struct policy *pol = s->t->pol;
    uint64_t a = p->addr;
    probe_close(p);
    if (atomic_load(&s->addr) != a) return;
    int up = atomic_load(&s->up);
    if (ok) {
        s->bad = 0;
        if (s->ok < 255) s->ok++;
        if (!up && s->ok >= pol->rise) { slot_set_up(s, 1, "health check passed"); up = 1; }
    } else {
        s->ok = 0;
        if (s->bad < 255) s->bad++;
        if (up && s->bad >= pol->fall) { slot_set_up(s, 0, why); up = 0; }
    }
    unsigned fast = pol->inter_ms < FASTINTER_MS ? pol->inter_ms : FASTINTER_MS;
    s->next_ms = now + ((up ? s->bad : s->ok) ? fast : pol->inter_ms);
}

static void probe_start(struct slot *s, struct probe *p, uint64_t a, uint64_t now) {
    const struct check *ck = slot_check(s);
    const struct ep *at = !s->backup && s->t->pol->check_ep.fam ? &s->t->pol->check_ep : &s->ep;
    union sa to;
    socklen_t tl = ep_sa(at, ck->port ? ck->port : s->ep.port, &to);
    p->addr = a; p->n = 0;
    p->deadline = now + s->t->pol->check_ms;
    p->fd = socket(to.sa.sa_family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (p->fd < 0) { probe_result(s, p, 0, "check: socket failed", now); return; }
    if (connect(p->fd, &to.sa, tl) < 0 && errno != EINPROGRESS) {
        char m[80]; snprintf(m, sizeof m, "check: connect: %s", strerror(errno));
        probe_result(s, p, 0, m, now);
        return;
    }
    p->state = P_CONNECT;
}

// the probe's fd is ready (or its deadline passed: ev = 0)
static void probe_step(struct slot *s, struct probe *p, short ev, uint64_t now) {
    const struct check *ck = slot_check(s);
    if (!ev) { probe_result(s, p, 0, "check: timed out", now); return; }
    if (p->state == P_CONNECT) {
        int err = 0; socklen_t l = sizeof err;
        getsockopt(p->fd, SOL_SOCKET, SO_ERROR, &err, &l);
        if (err) {
            char m[80]; snprintf(m, sizeof m, "check: connect: %s", strerror(err));
            probe_result(s, p, 0, m, now);
            return;
        }
        if (ck->kind == CK_TCP) { probe_result(s, p, 1, NULL, now); return; }
        char req[512];
        int n = snprintf(req, sizeof req, "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: c_proxy-check\r\n"
                         "Connection: close\r\n\r\n", ck->path, s->t->label[0] == '(' ? "localhost" : s->t->label);
        if (send(p->fd, req, n, MSG_NOSIGNAL) != n) { probe_result(s, p, 0, "check: send failed", now); return; }
        p->state = P_READ;
        return;
    }
    ssize_t n = recv(p->fd, p->buf + p->n, sizeof p->buf - 1 - p->n, 0);
    if (n < 0 && (errno == EAGAIN || errno == EINTR)) return;
    if (n > 0) p->n += n;
    if (p->n >= 12 || n <= 0) {                               // "HTTP/1.1 200" or the peer is done
        p->buf[p->n] = 0;
        int ok = p->n >= 12 && !strncmp(p->buf, "HTTP/1.", 7) && (p->buf[9] == '2' || p->buf[9] == '3');
        char m[80]; snprintf(m, sizeof m, "check: %.12s", p->n ? p->buf : "connection closed");
        probe_result(s, p, ok, ok ? NULL : m, now);
    }
}

// Under ctl_lock: fence servers whose lease ran out, and recompute lease_min
static void lease_sweep(void) {
    uint64_t now = boot_ms(), m = 0;
    for (unsigned i = 0; i < nservers; i++) {
        struct slot *s = &servers[i];
        uint64_t u = atomic_load(&s->lease_until);
        if (!u || !atomic_load(&s->addr)) continue;
        if (now >= u) {
            if (atomic_load(&s->up) || s->seen_up) slot_change(s, 0, "lease expired, sessions cut", 1);
        } else if (!m || u < m) m = u;
    }
    atomic_store(&lease_min, m);
}

static void *checker_main(void *arg) {
    (void)arg;
    static struct probe pr[MAX_SERVERS];
    static struct pollfd pfd[MAX_SERVERS];
    static unsigned idx[MAX_SERVERS];
    for (unsigned i = 0; i < MAX_SERVERS; i++) pr[i].fd = -1;
    for (;;) {
        uint64_t now = now_ms();
        unsigned np = 0;
        pthread_mutex_lock(&ctl_lock);
        lease_sweep();
        for (unsigned i = 0; i < nservers; i++) {
            struct slot *s = &servers[i];
            struct probe *p = &pr[i];
            const struct policy *pol = s->t->pol;
            uint64_t a = atomic_load(&s->addr);
            if (!a) { probe_close(p); continue; }
            int err = atomic_exchange_explicit(&s->failed, 0, memory_order_acquire);
            if (err) {                                        // a worker marked it down
                char why[96], at[16];
                s->ok = 0; s->bad = (uint8_t)pol->fall; s->down_ms = now;
                s->next_ms = now + FASTINTER_MS;
                fmt_clock(atomic_load_explicit(&s->fail_ms, memory_order_relaxed), at, sizeof at);
                snprintf(why, sizeof why, "connect failed on live traffic (%s at %s)",
                         err == ECANCELED ? "timed out" : strerror(err), at);   // ECANCELED: the linked timeout fired
                slot_set_up(s, 0, why);
            }
            if (slot_check(s)->kind == CK_NONE) {             // passive only: retry after an interval
                if (!atomic_load(&s->up) && now - s->down_ms >= pol->inter_ms) slot_set_up(s, 1, "retry");
                continue;
            }
            if (p->state == P_IDLE && now >= s->next_ms) probe_start(s, p, a, now);
            if (p->state != P_IDLE && now >= p->deadline) probe_step(s, p, 0, now);
            if (p->state == P_IDLE) continue;
            pfd[np] = (struct pollfd){ .fd = p->fd, .events = p->state == P_CONNECT ? POLLOUT : POLLIN };
            idx[np++] = i;
        }
        pthread_mutex_unlock(&ctl_lock);
        if (poll(pfd, np, 50) <= 0) continue;
        now = now_ms();
        pthread_mutex_lock(&ctl_lock);
        for (unsigned k = 0; k < np; k++) {
            if (!pfd[k].revents) continue;
            struct probe *p = &pr[idx[k]];
            if (p->fd != pfd[k].fd) continue;                 // closed meanwhile
            probe_step(&servers[idx[k]], p, pfd[k].revents, now);
        }
        pthread_mutex_unlock(&ctl_lock);
    }
    return NULL;
}

// ========================================================= CONTROL =======
// --control PATH: a unix socket (mode 0600) for the agent. One command per line, answered by zero or
// more data lines and then "ok" or "err <why>". Applied under ctl_lock, like the checker's changes.
//   version                       "gk-proxy control 1 COMMAND,..." (protocol version 1; docs/control-protocol.md)
//   show                          every server: target, role, address, up/down/maint, sessions=N (open)
//   stats                         counters summed over the workers
//   targets                       one line per target: NAME LABEL local|backup up=U maint=M total=T
//                                 connect_fail=N (ever; a CI gate diffs two readings)
//   add NAME IP:PORT              a server for the managed target @NAME (TARGETS "@NAME"); up at once,
//                                 or after --rise checks with --start-down
//   del NAME IP:PORT [cut]        remove it; "cut" also closes its sessions (else they finish)
//   down NAME IP:PORT|* [cut]     maintenance: down until "up", whatever the checks say; "cut" closes
//                                 its sessions now (the fence; --cut-on-down does it always)
//   up NAME IP:PORT|*             end maintenance: up at once without checks, else once they pass
//   drain [MS]                    stop accepting; exit once every session ended, or after MS
//                                 (--drain-timeout); for a restart or a reload (see "Drain")
//   resolve NAME|*                look up DNS targets now, not at the next --resolve-interval (the
//                                 agent, on a container start, stop or recreate); answered once applied;
//                                 an address no longer in DNS is removed at once, without --dns-hold
//   lease NAME IP:PORT|* MS|off   fencing deadline: serve for MS more (CLOCK_BOOTTIME), then fence as
//                                 "down ... cut" does, until the next "lease"; the arbiter renews it
//                                 with each lease of its own. "off" ends it. Local servers only
// NAME is a target as written in TARGETS ("@db", "payments-backend", "10.0.0.5") or "HOST:PORT"; it
// applies to every target of that name (several listeners or roles may each have one).
#define CTL_PROTO 1
static int ctl_lfd = -1;

static int ctl_match(const struct target *t, const char *name) {
    if (!strcmp(t->host, name) || (t->managed && name[0] != '@' && !strcmp(t->host + 1, name))) return 1;
    const char *colon = strrchr(name, ':');                   // "HOST:PORT" or "[IPV6]:PORT"
    if (!colon) return 0;
    const char *h = name; size_t hl = (size_t)(colon - name);
    if (h[0] == '[' && hl >= 2 && h[hl - 1] == ']') { h++; hl -= 2; }
    return strlen(t->host) == hl && !strncmp(h, t->host, hl) && atoi(colon + 1) == t->port;
}


static void ctl_command(char *line, FILE *o) {
    char *argv[6]; int argc = 0;
    for (char *save = NULL, *tok = strtok_r(line, " \t\r", &save); tok && argc < 6; tok = strtok_r(NULL, " \t\r", &save))
        argv[argc++] = tok;
    if (!argc) return;
    const char *cmd = argv[0];
    if (!strcmp(cmd, "version")) {                           // bump CTL_PROTO on an incompatible change
        fprintf(o, "gk-proxy control %d show,stats,targets,add,del,down,up,drain,resolve,lease\nok\n", CTL_PROTO);
        return;
    }
    if (!strcmp(cmd, "show") || !strcmp(cmd, "targets")) lease_sweep();   // report a lease that just ran out
    if (!strcmp(cmd, "show")) {
        for (unsigned i = 0; i < nservers; i++) {
            struct slot *s = &servers[i];
            if (!atomic_load(&s->addr)) continue;
            char buf[64]; ep_fmt(&s->ep, buf, sizeof buf);
            char lease[24] = "none";                        // lease=none|expired|MS remaining
            uint64_t u = atomic_load(&s->lease_until), now = boot_ms();
            if (u) { if (u <= now) strcpy(lease, "expired"); else snprintf(lease, sizeof lease, "%llu", (unsigned long long)(u - now)); }
            fprintf(o, "%s %s %s %s %s sessions=%u lease=%s listener=%u\n", s->t->host, s->t->label, s->backup ? "backup" : "local", buf,
                    s->maint ? "maint" : atomic_load(&s->up) ? "up" : "down", atomic_load(&s->sessions), lease,
                    target_listener_port(s->t));
        }
        fprintf(o, "ok\n");
        return;
    }
    if (!strcmp(cmd, "drain")) {
        if (argc > 2 || (argc == 2 && atoi(argv[1]) <= 0)) { fprintf(o, "err usage: drain [MS]\n"); return; }
        drain_start(argc == 2 ? (unsigned)atoi(argv[1]) : cfg.drain_ms);
        fprintf(o, "ok\n");
        return;
    }
    if (!strcmp(cmd, "targets")) {
        for (unsigned ti = 0; ti < ntargets; ti++) {
            const struct target *t = &targets[ti];
            unsigned up = 0, maint = 0, total = 0;
            for (unsigned i = t->first; i < t->first + t->n; i++) {
                const struct slot *x = &servers[i];
                if (!atomic_load(&x->addr)) continue;
                total++; maint += x->maint; up += !x->maint && atomic_load(&x->up);
            }
            fprintf(o, "%s %s %s up=%u maint=%u total=%u connect_fail=%lu listener=%u\n", t->host, t->label,
                    t->backup ? "backup" : "local", up, maint, total, (unsigned long)atomic_load(&t->connect_fail),
                    target_listener_port(t));
        }
        fprintf(o, "ok\n");
        return;
    }
    if (!strcmp(cmd, "stats")) {
        struct stats t = { 0 }; uint64_t active = 0;
        for (int i = 0; i < cfg.workers; i++) {               // racy snapshot: fine for counters
            const struct stats *w = &all_workers[i]->st;
            active += all_workers[i]->active;
            t.accepted += w->accepted; t.kills += w->kills; t.connect_fail += w->connect_fail;
            t.retries += w->retries; t.no_server += w->no_server; t.fenced += w->fenced;
            t.idle_closed += w->idle_closed; t.half_closed += w->half_closed; t.sni_bad += w->sni_bad;
        }
        fprintf(o, "active=%lu accepted=%lu kills=%lu connect_fail=%lu retries=%lu no_server=%lu fenced=%lu "
                "idle_closed=%lu half_closed=%lu sni_bad=%lu\nok\n", active, t.accepted, t.kills, t.connect_fail,
                t.retries, t.no_server, t.fenced, t.idle_closed, t.half_closed, t.sni_bad);
        return;
    }
    if (!strcmp(cmd, "resolve")) {
        if (argc != 2) { fprintf(o, "err usage: resolve NAME|*\n"); return; }
        unsigned n = 0;
        for (unsigned ti = 0; ti < ntargets; ti++)
            if (targets[ti].dns && (!strcmp(argv[1], "*") || ctl_match(&targets[ti], argv[1]))) {
                pthread_mutex_unlock(&ctl_lock);              // held by control_main; the lookup must not
                resolve_target(&targets[ti], 1); n++;            // hold it (resolve_target applies under it)
                pthread_mutex_lock(&ctl_lock);
            }
        if (n) fprintf(o, "ok\n"); else fprintf(o, "err no DNS target %s\n", argv[1]);
        return;
    }
    int add = !strcmp(cmd, "add"), del = !strcmp(cmd, "del"), down = !strcmp(cmd, "down"), up = !strcmp(cmd, "up");
    int lease = !strcmp(cmd, "lease");
    uint64_t lease_to = 0;
    if (lease) {
        char *end = NULL;
        unsigned long ms = argc == 4 && strcmp(argv[3], "off") ? strtoul(argv[3], &end, 10) : 0;
        if (argc != 4 || (strcmp(argv[3], "off") && (!ms || *end))) { fprintf(o, "err usage: lease NAME IP:PORT|* MS|off\n"); return; }
        if (ms) lease_to = boot_ms() + ms;
        for (unsigned ti = 0; !ms && ti < ntargets; ti++)
            if (ctl_match(&targets[ti], argv[1]) && targets[ti].pol->lease_required) {
                fprintf(o, "err %s needs a lease (--lease-required)\n", argv[1]); return;
            }
    } else if (!(add || del || down || up) || argc < 3 || argc > 4 || (argc == 4 && (strcmp(argv[3], "cut") || add || up))) {
        fprintf(o, "err usage: version | show | stats | targets | drain [MS] | resolve NAME|* | add NAME IP:PORT | del NAME IP:PORT [cut] | down NAME IP:PORT|* [cut] | up NAME IP:PORT|* | lease NAME IP:PORT|* MS|off\n");
        return;
    }
    int all = !strcmp(argv[2], "*"), cut = argc == 4 && !lease;
    struct ep a = { 0 };
    if ((add || del || !all) && ep_parse(argv[2], 1, &a) < 0) {
        fprintf(o, "err bad address %s (want IP:PORT or [IPV6]:PORT)\n", argv[2]); return;
    }
    unsigned matched = 0, changed = 0;
    uint64_t now = now_ms();
    for (unsigned ti = 0; ti < ntargets; ti++) {
        struct target *t = &targets[ti];
        if (!ctl_match(t, argv[1])) continue;
        if (add && !t->managed) { fprintf(o, "err %s is not a managed target (write it as @NAME in TARGETS)\n", argv[1]); return; }
        matched++;
        if (add) {
            unsigned free_i = 0, have = 0;
            for (unsigned i = t->first; i < t->first + t->n; i++) {
                int used = atomic_load(&servers[i].addr) != 0;
                if (used && !memcmp(&servers[i].ep, &a, sizeof a)) have = 1;
                if (!used && !free_i) free_i = i + 1;
            }
            if (have) continue;
            if (!free_i) { fprintf(o, "err %s is full (%u servers; raise --dns-slots)\n", argv[1], t->n); return; }
            struct slot *s = &servers[free_i - 1];
            uint8_t u = initial_up(t);
            s->ok = s->bad = 0; s->gone_ms = 0; s->down_ms = 0; s->next_ms = now; s->seen_up = u; s->maint = 0;
            atomic_store(&s->failed, 0); lease_init(s);
            slot_put(s, &a);                                  // address first, then up
            atomic_store(&s->up, u);
            slot_log(s, "added (control)");
            changed++;
            continue;
        }
        for (unsigned i = t->first; i < t->first + t->n; i++) {
            struct slot *s = &servers[i];
            if (!atomic_load(&s->addr) || (!all && memcmp(&s->ep, &a, sizeof a))) continue;
            changed++;
            if (del) {
                slot_change(s, 0, "removed (control)", cut);
                s->maint = 0; atomic_store(&s->lease_until, 0);
                slot_clear(s);
            } else if (down) {
                const char *why = cut ? "maintenance (control), sessions cut" : "maintenance (control)";
                int was_up = s->seen_up;
                s->maint = 1;
                slot_change(s, 0, why, cut);                  // logs only a transition
                if (!was_up) slot_log(s, why);
            } else if (up) {
                s->maint = 0;
                if (slot_check(s)->kind == CK_NONE || s->ok >= t->pol->rise) slot_set_up(s, 1, "up (control)");
                else { s->next_ms = now; slot_log(s, "maintenance over (control), waiting for checks"); }
            } else {                                          // lease: renew, or end with "off"
                int was_expired = lease_expired(s, boot_ms());
                if (s->backup) continue;                      // leases gate local servers only
                atomic_store(&s->lease_until, lease_to);
                if (was_expired && !s->maint) {               // fenced by its lease: may serve again
                    if (slot_check(s)->kind == CK_NONE || s->ok >= t->pol->rise) slot_set_up(s, 1, "lease renewed");
                    else { s->next_ms = now; slot_log(s, "lease renewed, waiting for checks"); }
                }
            }
        }
    }
    if (!matched) { fprintf(o, "err no target %s\n", argv[1]); return; }
    if (!changed && !add) { fprintf(o, "err no server %s in %s\n", argv[2], argv[1]); return; }
    if (lease) lease_sweep();                                 // a shorter deadline reaches the workers now
    fprintf(o, "ok\n");
}

struct ctl_client { int fd; unsigned n; char buf[1024]; };

static void *control_main(void *arg) {
    (void)arg;
    enum { NCLI = 8 };
    struct ctl_client cl[NCLI];
    for (int i = 0; i < NCLI; i++) cl[i].fd = -1;
    for (;;) {
        struct pollfd pf[NCLI + 1]; int map[NCLI + 1], np = 0;
        pf[np] = (struct pollfd){ .fd = ctl_lfd, .events = POLLIN }; map[np++] = -1;
        for (int i = 0; i < NCLI; i++) if (cl[i].fd >= 0) { pf[np] = (struct pollfd){ .fd = cl[i].fd, .events = POLLIN }; map[np++] = i; }
        if (poll(pf, np, -1) <= 0) continue;
        for (int k = 0; k < np; k++) {
            if (!pf[k].revents) continue;
            if (map[k] < 0) {
                int fd = accept4(ctl_lfd, NULL, NULL, SOCK_CLOEXEC);
                if (fd < 0) continue;
                int i = 0;
                while (i < NCLI && cl[i].fd >= 0) i++;
                if (i == NCLI) { const char *m = "err too many control clients\n"; if (write(fd, m, strlen(m)) < 0) {} close(fd); continue; }
                cl[i].fd = fd; cl[i].n = 0;
                continue;
            }
            struct ctl_client *c = &cl[map[k]];
            ssize_t r = read(c->fd, c->buf + c->n, sizeof c->buf - 1 - c->n);
            if (r <= 0) { close(c->fd); c->fd = -1; continue; }
            c->n += (unsigned)r;
            char *nl;
            while ((nl = memchr(c->buf, '\n', c->n))) {
                *nl = 0;
                char *out = NULL; size_t len = 0;
                FILE *o = open_memstream(&out, &len);
                pthread_mutex_lock(&ctl_lock);
                ctl_command(c->buf, o);
                pthread_mutex_unlock(&ctl_lock);
                fclose(o);
                for (size_t off = 0; off < len; ) {           // blocking write: replies are small
                    ssize_t w = write(c->fd, out + off, len - off);
                    if (w <= 0) break;
                    off += (size_t)w;
                }
                free(out);
                unsigned used = (unsigned)(nl - c->buf) + 1;
                memmove(c->buf, nl + 1, c->n - used); c->n -= used;
            }
            if (c->n == sizeof c->buf - 1) { close(c->fd); c->fd = -1; }   // a line too long: drop the client
        }
    }
    return NULL;
}

static int control_listen(const char *path) {
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof a.sun_path) return -1;
    strcpy(a.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    unlink(path);                                             // a stale socket from an earlier run
    mode_t old = umask(0177);                                 // created 0600: the agent's user only
    int r = bind(fd, (struct sockaddr *)&a, sizeof a);
    umask(old);
    if (r < 0 || listen(fd, 8) < 0) { close(fd); return -1; }
    return fd;
}

// ----------------------------------------------------------- config parsing ----
// The target for host:port in this role under this policy: an existing one (shared) or a new one
// with its servers. NULL = a table is full.
static struct target *target_get(const char *host, uint16_t port, int backup, const struct policy *pol,
                                 const char *label) {
    for (unsigned i = 0; i < ntargets; i++) {
        struct target *t = &targets[i];
        if (t->port == port && t->backup == backup && !strcmp(t->host, host) && !memcmp(t->pol, pol, sizeof *pol))
            return t;
    }
    struct ep ip;
    int managed = host[0] == '@', dns = !managed && ep_ip(host, &ip) < 0;
    unsigned n = dns || managed ? cfg.dns_slots : 1;
    if (ntargets == MAX_GTARGETS || nservers + n > MAX_SERVERS) return NULL;
    struct target *t = &targets[ntargets++];
    strcpy(t->host, host);
    t->port = port; t->backup = (uint8_t)backup; t->dns = (uint8_t)dns; t->managed = (uint8_t)managed;
    t->pol = pol; t->label = label;
    t->first = nservers; t->n = n;
    nservers += n;
    for (unsigned i = t->first; i < t->first + n; i++) { servers[i].t = t; servers[i].backup = (uint8_t)backup; }
    if (!dns && !managed) {
        uint8_t up = initial_up(t);                       // --start-down: local servers wait for a check
        ip.port = port;
        lease_init(&servers[t->first]);
        slot_put(&servers[t->first], &ip);
        atomic_store(&servers[t->first].up, up);
        servers[t->first].seen_up = up;
    }
    return t;
}

// targets: "port" (127.0.0.1) | "host:port" | "backup=host:port", comma-separated; "0" = none.
// host is an IPv4 address or a DNS name (resolved and re-resolved by the resolver thread).
static int parse_targets(struct route *r, const char *spec) {
    char buf[2048];
    if (strlen(spec) >= sizeof buf) return -1;
    strcpy(buf, spec);
    if (!strcmp(buf, "0")) return 0;
    const struct policy *pol = &listeners[r->lis].pol;
    char *save = NULL;
    for (char *it = strtok_r(buf, ",", &save); it; it = strtok_r(NULL, ",", &save)) {
        int backup = 0;
        if (!strncmp(it, "backup=", 7)) { backup = 1; it += 7; }
        if (it[0] == '@') {                                   // agent-managed: addresses come from --control
            if (!it[1] || strlen(it) >= sizeof targets[0].host || strchr(it, ':') || r->ntargets == MAX_TARGETS) return -1;
            struct target *t = target_get(it, 0, backup, pol, r->len ? r->name : "(default)");
            if (!t || r->nslots + t->n > MAX_SLOTS) return -1;
            r->t[r->ntargets++] = t;
            for (unsigned i = 0; i < t->n; i++) { r->s[r->nslots] = (uint16_t)(t->first + i); r->backup[r->nslots++] = (uint8_t)backup; }
            continue;
        }
        char *colon = strrchr(it, ':');
        const char *host = colon ? it : "127.0.0.1";
        if (it[0] == '[') {                                   // [IPV6]:PORT
            char *rb = strchr(it, ']');
            if (!rb || rb[1] != ':') return -1;
            *rb = 0; host = it + 1; colon = rb + 1;
        } else if (colon && strchr(it, ':') != colon) return -1;   // a bare IPv6 address needs [ ]
        char *e;
        long port = strtol(colon ? colon + 1 : it, &e, 10);
        if (colon) *colon = 0;
        if (*e || port <= 0 || port > 65535 || !*host || strlen(host) >= sizeof targets[0].host) return -1;
        if (r->ntargets == MAX_TARGETS) return -1;
        struct target *t = target_get(host, (uint16_t)port, backup, pol, r->len ? r->name : "(default)");
        if (!t || r->nslots + t->n > MAX_SLOTS) return -1;
        r->t[r->ntargets++] = t;
        for (unsigned i = 0; i < t->n; i++) {
            r->s[r->nslots] = (uint16_t)(t->first + i);
            r->backup[r->nslots++] = (uint8_t)backup;
        }
    }
    return 0;
}

// "none" | "tcp[:port]" | "http[:port][/path]"; port 0/absent = the server's own port
static int parse_check(struct check *ck, const char *s) {
    memset(ck, 0, sizeof *ck);
    if (!strcmp(s, "none")) return 0;
    if (!strncmp(s, "http", 4)) { ck->kind = CK_HTTP; s += 4; strcpy(ck->path, "/"); }
    else if (!strncmp(s, "tcp", 3)) { ck->kind = CK_TCP; s += 3; }
    else return -1;
    if (*s == ':') {
        char *e;
        long p = strtol(s + 1, &e, 10);
        if (p < 0 || p > 65535) return -1;
        ck->port = (uint16_t)p; s = e;
    }
    if (*s == '/' && ck->kind == CK_HTTP && strlen(s) < sizeof ck->path) strcpy(ck->path, s);
    else if (*s) return -1;
    return 0;
}

static const char *check_str(const struct check *ck, const struct ep *ip, char *out, size_t n) {
    char at[64] = "";
    if (ip && ip->fam) { at[0] = '@'; inet_ntop(ip->fam, ip->ip, at + 1, sizeof at - 1); }
    if (ck->kind == CK_NONE) snprintf(out, n, "none (passive)");
    else if (ck->port) snprintf(out, n, "%s:%u%s%s", ck->kind == CK_HTTP ? "http" : "tcp", ck->port, ck->path, at);
    else snprintf(out, n, "%s%s%s", ck->kind == CK_HTTP ? "http" : "tcp", ck->path, at);
    return out;
}

static void usage(const char *a) {
    fprintf(stderr,
        "usage: %s [options]       every option has a long form; the short ones are aliases\n"
        "\n"
        "listening and routing\n"
        "  -l, --listen [ADDR:]PORT     a listener (repeatable, up to %d; default one on 8443; no ADDR = every\n"
        "                               IPv6 and IPv4 address, [IPV6]:PORT for one IPv6 address). Routing,\n"
        "                               backend and smart-ACK options after it apply to it; given before\n"
        "                               the first -l they are defaults for every listener. Servers of the\n"
        "                               same host:port, role and check settings are shared between\n"
        "                               listeners: one health state, one fence. e.g.\n"
        "                                 -l 443 -R a.internal=a:443,backup=PEER:8443 -l 8443 -R a.internal=a:443\n"
        "  -R, --route NAME=TARGETS     SNI route (repeatable, up to %d): TLS clients asking for NAME go to\n"
        "                               TARGETS. Any route turns on SNI routing (TLS passthrough)\n"
        "  -b, --backend TARGETS        default route: plain TCP mode, or SNI clients with no / an unknown\n"
        "                               name. Plain TCP default 127.0.0.1:8080; with routes default none,\n"
        "                               i.e. such clients are closed. \"0\" = none\n"
        "       TARGETS = comma-separated  PORT (127.0.0.1) | HOST:PORT | backup=HOST:PORT\n"
        "       HOST is an IPv4 address, [IPV6], or a DNS name; a name is re-resolved and each of its addresses\n"
        "       is a server (several A records = replicas). @NAME is a target whose servers come from\n"
        "       --control (add/del), up to --dns-slots of them. Local servers are used round-robin, backups\n"
        "       only while no local one is up, e.g.\n"
        "         -R payments.internal=payments-backend:443,backup=10.42.0.12:8443\n"
        "      --control PATH           unix socket (0600) for an agent: add/del servers of @NAME targets,\n"
        "                               down/up (maintenance, optionally cutting sessions: a fence), show,\n"
        "                               stats. One command per line; see CONTROL in proxy.c\n"
        "      --drain-timeout MS       on SIGUSR1 or the control socket's \"drain\": stop accepting, let\n"
        "                               open sessions finish this long, then exit (30000)\n"
        "  -T, --hello-timeout MS       close a client that has not sent its ClientHello by then (5000)\n"
        "      --idle-timeout MS        close a connection that moved no bytes either way for MS (0 = off;\n"
        "                               off by default: database sessions sit idle for long stretches)\n"
        "      --half-close-timeout MS  once one side has closed its half, close the connection if the other\n"
        "                               direction moves nothing for MS (60000; 0 = off)\n"
        "\n"
        "backends\n"
        "      --connect-timeout MS     then the next server (1000; 0 = the kernel's SYN retries)\n"
        "      --backup-connect-timeout MS\n"
        "                               the same for backups: a peer over a WAN, where one lost SYN costs a\n"
        "                               1 s retransmit, wants more, e.g. 1500 (default: --connect-timeout)\n"
        "      --check SPEC             health check of local servers: none | tcp[:PORT] | http[:PORT][/PATH]\n"
        "                               (none: only failed connects mark a server down, tried again after\n"
        "                               --check-interval). http expects a 2xx/3xx status (none)\n"
        "      --backup-check SPEC      same for backups (tcp: a connect to the backup's own port)\n"
        "      --check-to IP            send --check there instead of to each server (HAProxy \"addr\"),\n"
        "                               e.g. a lease holder's /fence on 127.0.0.1 gating a database\n"
        "      --start-down / --no-start-down\n"
        "                               local servers start down until --rise checks pass (off)\n"
        "      --lease-required / --no-lease-required\n"
        "                               local servers start fenced until their first control \"lease\"\n"
        "                               (a proxy restarted after the arbiter resigned serves nothing) (off)\n"
        "      --cut-on-down / --no-cut-on-down\n"
        "                               a server marked down also has its open sessions closed, both\n"
        "                               sides, at once (HAProxy on-marked-down shutdown-sessions) (off)\n"
        "      --check-interval MS      (1000; 250 while a server is changing state)\n"
        "      --check-timeout MS       (1000)\n"
        "      --rise N / --fall N      successes to mark up / failures to mark down (2 / 2)\n"
        "      --resolve-interval MS    re-resolve DNS targets (1000)\n"
        "      --dns-hold MS            keep an address that vanished from DNS this long (1000)\n"
        "      --dns-slots N            addresses kept per DNS or @NAME target (8)\n"
        "      --dns-family F           any | ipv4 | ipv6: which addresses of a DNS name to use (any)\n"
        "\n"
        "threads and data path\n"
        "      --io IO                  auto | uring | epoll   auto (default): io_uring when it initialises\n"
        "                               (Linux >= 6.1, not blocked by seccomp or kernel.io_uring_disabled),\n"
        "                               else epoll. Same features either way\n"
        "      --batch N:US             after a pass with work, let events collect: io_uring waits for N\n"
        "                               completions or US microseconds; epoll sleeps US after a pass with\n"
        "                               fewer than N events. Less CPU per message, up to US more latency per\n"
        "                               hop (off; e.g. 32:1000)\n"
        "  -t, --threads N              worker threads, one io_uring or epoll loop each (default: one per CPU)\n"
        "  -P, --pin                    pin worker i to the i-th usable CPU\n"
        "  -m, --mode MODE              hybrid (default) | copy | isplice | splice (legacy)\n"
        "  -Z, --bulk BYTES             a read at least this big counts as bulk; a wakeup moving less\n"
        "                               counts as small (8192)\n"
        "  -G, --bulk-reads N           bulk reads in a row before a direction switches to splice (1)\n"
        "  -s, --small-wakeups N        small wakeups in a row before it switches back to copy (3)\n"
        "  -B, --buf-size BYTES         per pool buffer (32768)\n"
        "  -N, --bufs N                 pool buffers per worker, power of 2 (512)\n"
        "  -S, --pipe-size BYTES        (262144)\n"
        "  -C, --max-conns N            per worker (65536)\n"
        "  -W, --io-wq N                max io-wq threads per worker, legacy splice mode only (4)\n"
        "  -r, --ring-mode MODE         auto | defer | coop | plain   io_uring task-run mode\n"
        "\n"
        "TCP tweaks (each one has an on and an off form)\n"
        "  -Q, --smart-ack / -q, --no-smart-ack\n"
        "                               delay the handshake ACK to the backend and the request ACK to the\n"
        "                               client so both ride on data (like HAProxy tcp-smart-connect/-accept).\n"
        "                               Default: on with SNI routing (the client spoke first), off otherwise:\n"
        "                               a server-speaks-first backend (SMTP, SSH) would wait up to 200 ms\n"
        "  -F, --tfo / --no-tfo         TCP Fast Open to the backend: the client's first bytes ride in the SYN\n"
        "                               (client-speaks-first only; needs net.ipv4.tcp_fastopen & 2 on the\n"
        "                               backend host; a dead server then shows up after connect, so it is\n"
        "                               not retried on the next one) (off)\n"
        "  -E, --eof-probes N           the first N short reads from the backend check for its FIN so it can\n"
        "                               ride on the last data segment (4; 0 = off)\n"
        "  -A, --defer-accept / --no-defer-accept\n"
        "                               TCP_DEFER_ACCEPT: accept a client once it has sent data (off)\n"
        "      --ring-socket / -o, --no-ring-socket\n"
        "                               create the backend socket and set its options through the ring\n"
        "                               (on from Linux 6.7, which it needs)\n"
        "  -K, --old-close              shutdown() both sockets before close (A/B only)\n"
        "\n"
        "  -v, --verbose                per-worker counters to stderr every 5 s\n"
        "  -h, --help\n", a, MAX_LISTENERS, MAX_ROUTES);
}

static int run_dns;

int gkp_init(int argc, char **argv) {
    enum { O_NO_TFO = 256, O_NO_DEFER, O_RING_SOCKET, O_CONNECT, O_BCONNECT, O_CHECK, O_BCHECK, O_INTER, O_CTIMEOUT,
           O_RISE, O_FALL, O_RESOLVE, O_HOLD, O_DNS_SLOTS, O_CHECK_TO, O_START_DOWN, O_NO_START_DOWN, O_LEASE_REQ, O_NO_LEASE_REQ,
           O_CUT_ON_DOWN, O_NO_CUT_ON_DOWN, O_IDLE, O_HALF, O_CONTROL, O_DNS_FAMILY, O_IO, O_BATCH, O_DRAIN };
    static const struct option longopts[] = {
        { "listen", 1, 0, 'l' }, { "backend", 1, 0, 'b' }, { "route", 1, 0, 'R' },
        { "hello-timeout", 1, 0, 'T' }, { "threads", 1, 0, 't' }, { "pin", 0, 0, 'P' },
        { "mode", 1, 0, 'm' }, { "ring-mode", 1, 0, 'r' }, { "bulk", 1, 0, 'Z' },
        { "bulk-reads", 1, 0, 'G' }, { "small-wakeups", 1, 0, 's' }, { "buf-size", 1, 0, 'B' },
        { "bufs", 1, 0, 'N' }, { "pipe-size", 1, 0, 'S' }, { "max-conns", 1, 0, 'C' }, { "io-wq", 1, 0, 'W' },
        { "smart-ack", 0, 0, 'Q' }, { "no-smart-ack", 0, 0, 'q' }, { "tfo", 0, 0, 'F' }, { "no-tfo", 0, 0, O_NO_TFO },
        { "eof-probes", 1, 0, 'E' }, { "defer-accept", 0, 0, 'A' }, { "no-defer-accept", 0, 0, O_NO_DEFER },
        { "ring-socket", 0, 0, O_RING_SOCKET }, { "no-ring-socket", 0, 0, 'o' }, { "old-close", 0, 0, 'K' },
        { "connect-timeout", 1, 0, O_CONNECT }, { "backup-connect-timeout", 1, 0, O_BCONNECT }, { "check", 1, 0, O_CHECK }, { "backup-check", 1, 0, O_BCHECK },
        { "check-interval", 1, 0, O_INTER }, { "check-timeout", 1, 0, O_CTIMEOUT },
        { "rise", 1, 0, O_RISE }, { "fall", 1, 0, O_FALL }, { "resolve-interval", 1, 0, O_RESOLVE },
        { "dns-hold", 1, 0, O_HOLD }, { "dns-slots", 1, 0, O_DNS_SLOTS }, { "check-to", 1, 0, O_CHECK_TO },
        { "start-down", 0, 0, O_START_DOWN }, { "no-start-down", 0, 0, O_NO_START_DOWN },
        { "lease-required", 0, 0, O_LEASE_REQ }, { "no-lease-required", 0, 0, O_NO_LEASE_REQ },
        { "cut-on-down", 0, 0, O_CUT_ON_DOWN }, { "no-cut-on-down", 0, 0, O_NO_CUT_ON_DOWN },
        { "idle-timeout", 1, 0, O_IDLE }, { "half-close-timeout", 1, 0, O_HALF }, { "control", 1, 0, O_CONTROL }, { "drain-timeout", 1, 0, O_DRAIN },
        { "dns-family", 1, 0, O_DNS_FAMILY }, { "io", 1, 0, O_IO }, { "batch", 1, 0, O_BATCH },
        { "verbose", 0, 0, 'v' }, { "help", 0, 0, 'h' }, { 0, 0, 0, 0 },
    };
    // Options before the first -l are defaults for every listener; per-listener ones (routes, checks,
    // timeouts, smart ACKs) after a -l apply to that listener. Routes before any -l go to the first.
    struct policy defpol = { .check = { CK_NONE, 0, "" }, .bcheck = { CK_TCP, 0, "" },
                             .connect_ms = 1000, .bconnect_ms = UINT_MAX, .inter_ms = 1000, .check_ms = 1000, .rise = 2, .fall = 2 };
    struct { unsigned lis; const char *name; size_t len; const char *spec; } rq[MAX_ROUTES];
    const char *default_spec[MAX_LISTENERS] = { 0 };
    unsigned nrq = 0;
    struct listener *cur = NULL;
    unsigned def_idle = 0, def_half = 60000;
    const char *control_path = NULL;
#define POL (cur ? &cur->pol : &defpol)
#define LIS (cur ? (unsigned)(cur - listeners) : 0)
    int o;
    while ((o = getopt_long(argc, argv, "l:b:t:m:r:B:N:S:W:C:G:s:R:T:E:Z:AoKFQqPvh", longopts, NULL)) != -1) {
        switch (o) {
        case 'F': cfg.tfo = 1; break;
        case O_NO_TFO: cfg.tfo = 0; break;
        case 'Q': if (cur) cur->smart_ack = 1; else cfg.smart_ack = 1; break;
        case 'q': if (cur) cur->smart_ack = 0; else cfg.smart_ack = 0; break;
        case 'Z': cfg.bulk = atoi(optarg); break;
        case 'E': cfg.eof_probes = atoi(optarg); if (cfg.eof_probes > 255) cfg.eof_probes = 255; break;
        case 'A': cfg.defer_accept = 1; break;
        case O_NO_DEFER: cfg.defer_accept = 0; break;
        case 'o': cfg.ring_socket = 0; break;
        case O_RING_SOCKET: cfg.ring_socket = 2; break;          // 2: asked for, even before Linux 6.7
        case 'K': cfg.old_close = 1; break;
        case 'R': {
            const char *eq = strchr(optarg, '=');
            size_t len = eq ? (size_t)(eq - optarg) : 0;
            if (len && optarg[len - 1] == '.') len--;
            if (!len || len >= sizeof routes[0].name || nrq == MAX_ROUTES) {
                fprintf(stderr, "bad -R %s (want NAME=TARGETS, at most %d routes)\n", optarg, MAX_ROUTES); return 2;
            }
            rq[nrq].lis = LIS; rq[nrq].name = optarg; rq[nrq].len = len; rq[nrq++].spec = eq + 1;
            break;
        }
        case 'b': default_spec[LIS] = optarg; break;
        case 'T': cfg.peek_ms = atoi(optarg); break;
        case 'l': {
            if (cfg.nlisteners == MAX_LISTENERS) { fprintf(stderr, "at most %d listeners\n", MAX_LISTENERS); return 2; }
            struct ep b = { 0 };                              // PORT | ADDR:PORT | [IPV6]:PORT
            char *e; long port = strtol(optarg, &e, 10);
            if (*e) { if (ep_parse(optarg, 1, &b) < 0) port = 0; else port = b.port; }
            if (port <= 0 || port > 65535) { fprintf(stderr, "bad -l %s (PORT, ADDR:PORT or [IPV6]:PORT)\n", optarg); return 2; }
            b.port = 0;
            for (unsigned i = 0; i < cfg.nlisteners; i++)
                if (listeners[i].port == port && !memcmp(&listeners[i].bind, &b, sizeof b)) { fprintf(stderr, "-l %s given twice\n", optarg); return 2; }
            cur = &listeners[cfg.nlisteners++];
            memcpy(&cur->pol, &defpol, sizeof defpol);        // memcpy: targets compare policies bytewise
            cur->port = (uint16_t)port; cur->smart_ack = cfg.smart_ack; cur->bind = b;
            cur->idle_ms = def_idle; cur->half_ms = def_half;
            break;
        }
        case 't': cfg.workers = atoi(optarg); break;
        case 'm': {
            int m = -1;
            for (int i = 0; i < 4; i++) if (!strcmp(optarg, mode_name[i])) m = i;
            if (m < 0) { usage(argv[0]); return 2; }
            cfg.mode = m; break;
        }
        case 'r': cfg.ringmode = !strcmp(optarg, "defer") ? RING_DEFER : !strcmp(optarg, "coop") ? RING_COOP :
                                 !strcmp(optarg, "plain") ? RING_PLAIN : RING_AUTO; break;
        case 'B': cfg.bufsz = atoi(optarg); break;
        case 'N': cfg.nbufs = atoi(optarg); break;
        case 'S': cfg.pipesz = atoi(optarg); break;
        case 'W': cfg.iowq = atoi(optarg); break;
        case 'C': cfg.maxconn = atoi(optarg); break;
        case 'G': cfg.big_n = atoi(optarg); break;
        case 's': cfg.small_n = atoi(optarg); break;
        case 'P': cfg.pin = 1; break;
        case 'v': cfg.verbose = 1; break;
        case O_CONNECT: POL->connect_ms = atoi(optarg); break;
        case O_BCONNECT: POL->bconnect_ms = atoi(optarg); break;
        case O_CHECK: case O_BCHECK:
            if (parse_check(o == O_CHECK ? &POL->check : &POL->bcheck, optarg) < 0) {
                fprintf(stderr, "bad check %s (want none | tcp[:PORT] | http[:PORT][/PATH])\n", optarg); return 2;
            }
            break;
        case O_INTER: POL->inter_ms = atoi(optarg); break;
        case O_CHECK_TO:
            if (ep_parse(optarg, 0, &POL->check_ep) < 0 || POL->check_ep.port) {
                fprintf(stderr, "bad --check-to %s (an IPv4 or IPv6 address)\n", optarg); return 2;
            }
            break;
        case O_START_DOWN: POL->start_down = 1; break;
        case O_NO_START_DOWN: POL->start_down = 0; break;
        case O_LEASE_REQ: POL->lease_required = 1; break;
        case O_NO_LEASE_REQ: POL->lease_required = 0; break;
        case O_CONTROL: control_path = optarg; break;
        case O_BATCH:
            if (sscanf(optarg, "%u:%u", &cfg.batch_n, &cfg.batch_us) != 2 || cfg.batch_us >= 1000000) {
                fprintf(stderr, "bad --batch %s (N:US, e.g. 32:1000; 0:0 = off)\n", optarg); return 2;
            }
            if (!cfg.batch_us) cfg.batch_n = 0;
            break;
        case O_DRAIN: cfg.drain_ms = (unsigned)atoi(optarg); break;
        case O_IO:
            if (!strcmp(optarg, "auto")) cfg.io = IO_AUTO;
            else if (!strcmp(optarg, "uring") || !strcmp(optarg, "io_uring")) cfg.io = IO_URING;
            else if (!strcmp(optarg, "epoll")) cfg.io = IO_EPOLL;
            else { fprintf(stderr, "bad --io %s (auto | uring | epoll)\n", optarg); return 2; }
            break;
        case O_DNS_FAMILY:
            if (!strcmp(optarg, "any")) cfg.dns_family = AF_UNSPEC;
            else if (!strcmp(optarg, "ipv4")) cfg.dns_family = AF_INET;
            else if (!strcmp(optarg, "ipv6")) cfg.dns_family = AF_INET6;
            else { fprintf(stderr, "bad --dns-family %s (any | ipv4 | ipv6)\n", optarg); return 2; }
            break;
        case O_IDLE: *(cur ? &cur->idle_ms : &def_idle) = (unsigned)atoi(optarg); break;
        case O_HALF: *(cur ? &cur->half_ms : &def_half) = (unsigned)atoi(optarg); break;
        case O_CUT_ON_DOWN: POL->cut_on_down = 1; break;
        case O_NO_CUT_ON_DOWN: POL->cut_on_down = 0; break;
        case O_CTIMEOUT: POL->check_ms = atoi(optarg); break;
        case O_RISE: POL->rise = atoi(optarg); break;
        case O_FALL: POL->fall = atoi(optarg); break;
        case O_RESOLVE: cfg.resolve_ms = atoi(optarg); break;
        case O_HOLD: cfg.hold_ms = atoi(optarg); break;
        case O_DNS_SLOTS: cfg.dns_slots = atoi(optarg); break;
        default: usage(argv[0]); return o == 'h' ? 0 : 2;
        }
    }
#undef POL
#undef LIS
    if (optind < argc) { fprintf(stderr, "unexpected argument %s\n", argv[optind]); return 2; }
    if (cfg.bufsz < 1024 || cfg.nbufs < 2 || (cfg.nbufs & (cfg.nbufs - 1)) || cfg.nbufs > 32768) {
        fprintf(stderr, "-N must be a power of two in [2, 32768] and -B >= 1024\n"); return 2;
    }
    if (cfg.maxconn < 16 || cfg.maxconn > (1u << 30)) { fprintf(stderr, "bad -C\n"); return 2; }
    if (cfg.dns_slots < 1 || cfg.dns_slots > MAX_SLOTS) { fprintf(stderr, "--dns-slots must be 1..%d\n", MAX_SLOTS); return 2; }
    if (cfg.resolve_ms < 10) cfg.resolve_ms = 10;
    if (cfg.mode == M_SPLICE && !cfg.iowq) cfg.iowq = 4;
    if (!cfg.bulk || cfg.bulk > cfg.bufsz) cfg.bulk = cfg.bufsz;
    if (!cfg.nlisteners) {                                    // no -l: one listener on 8443
        cur = &listeners[cfg.nlisteners++];
        memcpy(&cur->pol, &defpol, sizeof defpol);
        cur->port = 8443; cur->smart_ack = cfg.smart_ack;
        cur->idle_ms = def_idle; cur->half_ms = def_half;
    }

    // route layout: each listener's SNI routes, then its default route
    for (unsigned li = 0; li < cfg.nlisteners; li++) {
        struct listener *l = &listeners[li];
        struct policy *pol = &l->pol;
        if (pol->rise < 1) pol->rise = 1;
        if (pol->fall < 1) pol->fall = 1;
        if (pol->inter_ms < 10) pol->inter_ms = 10;
        if (!pol->check_ms) pol->check_ms = 1;
        if (pol->start_down && pol->check.kind == CK_NONE) { fprintf(stderr, "--start-down needs --check\n"); return 2; }
        cfg.cut_on_down |= pol->cut_on_down;
        for (int k = 0; k < 2; k++) {                       // sweep 4x per shortest timeout, 50 ms .. 1 s
            unsigned ms = k ? l->half_ms : l->idle_ms, p = ms / 4 < 50 ? 50 : ms / 4 > 1000 ? 1000 : ms / 4;
            if (ms && (!cfg.sweep_ms || p < cfg.sweep_ms)) cfg.sweep_ms = p;
        }
        if (pol->bconnect_ms == UINT_MAX) pol->bconnect_ms = pol->connect_ms;
        l->connect_ts = (struct __kernel_timespec){ pol->connect_ms / 1000, (pol->connect_ms % 1000) * 1000000LL };
        l->bconnect_ts = (struct __kernel_timespec){ pol->bconnect_ms / 1000, (pol->bconnect_ms % 1000) * 1000000LL };
        l->first = nroutes_all;
        for (unsigned i = 0; i < nrq; i++) {
            if (rq[i].lis != li) continue;
            struct route *r = &routes[nroutes_all++];
            memcpy(r->name, rq[i].name, rq[i].len); r->name[rq[i].len] = 0; r->len = (uint32_t)rq[i].len; r->lis = li;
            l->nroutes++;
        }
        struct route *d = &routes[nroutes_all++];                // its default route
        d->lis = li;
        if (l->smart_ack < 0) l->smart_ack = l->nroutes > 0;     // SNI: the client provably spoke first
        // targets are parsed once every option is known (--dns-slots may come after -R)
        for (unsigned i = l->first, k = 0; i < l->first + l->nroutes; i++, k++) {
            while (rq[k].lis != li) k++;
            if (parse_targets(&routes[i], rq[k].spec) < 0 || !routes[i].nslots) {
                fprintf(stderr, "bad -R %s=%s (TARGETS: PORT | HOST:PORT | backup=HOST:PORT, comma-separated, "
                        "at most %d targets / %d addresses per route, %d servers in all)\n",
                        routes[i].name, rq[k].spec, MAX_TARGETS, MAX_SLOTS, MAX_SERVERS);
                return 2;
            }
        }
        const char *ds = default_spec[li];
        if (!ds && !l->nroutes) ds = "127.0.0.1:8080";
        if (ds && parse_targets(d, ds) < 0) { fprintf(stderr, "bad -b %s\n", ds); return 2; }
        if (!l->nroutes && !d->nslots) { fprintf(stderr, ":%u: -b 0 needs at least one -R\n", l->port); return 2; }
    }

    if (control_path) {
        if ((ctl_lfd = control_listen(control_path)) < 0) { fprintf(stderr, "--control %s: %s\n", control_path, strerror(errno)); return 2; }
        cfg.cut_on_down = 1;                                // "cut" needs the workers' wakeup
    }

    sched_getaffinity(0, sizeof allowed, &allowed);
    if (cfg.workers <= 0) cfg.workers = CPU_COUNT(&allowed);

    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < rl.rlim_max) { rl.rlim_cur = rl.rlim_max; setrlimit(RLIMIT_NOFILE, &rl); }

    if (cfg.peek_ms == 0) cfg.peek_ms = 1;
    peek_ts = (struct __kernel_timespec){ cfg.peek_ms / 1000, (cfg.peek_ms % 1000) * 1000000LL };
    // epoll sweep: 4x per shortest timeout as above, the hello and connect timeouts included
    for (unsigned li = 0; li < cfg.nlisteners; li++) {
        const struct listener *l = &listeners[li];
        unsigned ms4[5] = { l->idle_ms, l->half_ms, l->pol.connect_ms, l->pol.bconnect_ms, l->nroutes ? cfg.peek_ms : 0 };
        for (int k = 0; k < 5; k++) {
            unsigned ms = ms4[k], p = ms / 4 < 50 ? 50 : ms / 4 > 1000 ? 1000 : ms / 4;
            if (ms && (!cfg.ep_sweep_ms || p < cfg.ep_sweep_ms)) cfg.ep_sweep_ms = p;
        }
    }
    const char *io_why = NULL;
    if (cfg.io == IO_AUTO && (io_why = uring_probe())) cfg.io = IO_EPOLL;
    if (cfg.ring_socket == 1 && !kernel_at_least(6, 7)) cfg.ring_socket = 0;   // setsockopt through the ring: 6.7

    printf("proxy: io=%s mode=%s workers=%d pin=%d pool=%ux%u pipe=%u maxconn=%u switch=%u/%u\n",
           cfg.io == IO_EPOLL ? "epoll" : "io_uring", mode_name[cfg.mode], cfg.workers, cfg.pin, cfg.nbufs,
           cfg.bufsz, cfg.pipesz, cfg.maxconn, cfg.big_n, cfg.small_n);
    if (io_why) printf("io_uring unavailable (%s): using epoll\n", io_why);
    if (cfg.batch_n) printf("batch: %u events or %u us\n", cfg.batch_n, cfg.batch_us);
    printf("options: eof-probes=%u bulk=%u%s%s%s%s\n", cfg.eof_probes, cfg.bulk, cfg.defer_accept ? " defer-accept" : "",
           cfg.io == IO_EPOLL ? "" : cfg.ring_socket ? " ring-socket" : " plain-socket", cfg.old_close ? " old-close" : "",
           cfg.tfo ? " tfo" : "");
    int dns = 0;
    for (unsigned li = 0; li < cfg.nlisteners; li++) {
        const struct listener *l = &listeners[li];
        const struct policy *pol = &l->pol;
        char lb[64] = "";
        if (l->bind.fam) { struct ep b = l->bind; b.port = l->port; ep_fmt(&b, lb, sizeof lb); }
        else snprintf(lb, sizeof lb, ":%u", l->port);
        printf("listen %s %s%s idle-timeout=%u half-close-timeout=%u\n", lb, l->nroutes ? "sni" : "tcp",
               l->smart_ack ? " smart-ack" : "", l->idle_ms, l->half_ms);
        for (unsigned ri = l->first; ri <= l->first + l->nroutes; ri++) {
            struct route *r = &routes[ri];
            if (ri == l->first + l->nroutes) printf("  %s", l->nroutes ? "route (no SNI / unknown name) ->" : "route ->");
            else printf("  route %s ->", r->name);
            if (!r->ntargets) printf(" rejected");
            for (unsigned ti = 0; ti < r->ntargets; ti++) {
                struct target *t = r->t[ti];
                dns |= t->dns;
                if (t->managed) printf("%s %s%s (control)", ti ? "," : "", t->backup ? "backup " : "", t->host);
                else printf(strchr(t->host, ':') ? "%s %s[%s]:%u%s" : "%s %s%s:%u%s", ti ? "," : "",
                            t->backup ? "backup " : "", t->host, t->port, t->dns ? " (dns)" : "");
                if (strcmp(t->label, r->len ? r->name : "(default)") || t->pol != pol) printf(" (shared)");
            }
            putchar('\n');
        }
        char c1[160], c2[160];
        printf("  backends: connect-timeout=%u backup-connect-timeout=%u check=%s backup-check=%s interval=%u timeout=%u rise=%u fall=%u%s%s%s\n",
               pol->connect_ms, pol->bconnect_ms, check_str(&pol->check, &pol->check_ep, c1, sizeof c1),
               check_str(&pol->bcheck, NULL, c2, sizeof c2), pol->inter_ms, pol->check_ms, pol->rise, pol->fall,
               pol->start_down ? " start-down" : "", pol->lease_required ? " lease-required" : "",
               pol->cut_on_down ? " cut-on-down" : "");
    }
    if (dns) printf("dns: resolve=%u dns-hold=%u dns-slots=%u family=%s\n", cfg.resolve_ms, cfg.hold_ms, cfg.dns_slots,
                    cfg.dns_family == AF_INET ? "ipv4" : cfg.dns_family == AF_INET6 ? "ipv6" : "any");
    if (sni_any()) printf("sni: hello-timeout=%u\n", cfg.peek_ms);
    fflush(stdout);
    run_dns = dns;
    return 0;
}

// ======================================================= LIBRARY API =====
// gkproxy.h. The library installs no signal handlers: the host owns signals and calls gkp_stop and
// gkp_drain (main.c for the CLI; the Go binary through cgo).
static _Atomic int stopping;

void gkp_stop(void) { atomic_store(&stopping, 1); }
void gkp_drain(unsigned ms) { drain_start(ms ? ms : cfg.drain_ms); }

void gkp_start(void) {
    resolve_all();                                            // first answers before the first client
    pthread_t *t = calloc(cfg.workers, sizeof *t);
    all_workers = calloc(cfg.workers, sizeof *all_workers);   // complete before the checker can wake one
    for (int i = 0; i < cfg.workers; i++) {
        struct worker *w = calloc(1, sizeof *w);
        w->id = i; all_workers[i] = w;
        w->efd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);        // cuts and the drain wake it
        if (w->efd < 0) fatal("eventfd");
    }
    pthread_t ctl;
    if (run_dns) pthread_create(&ctl, NULL, resolver_main, NULL);
    pthread_create(&ctl, NULL, checker_main, NULL);
    if (ctl_lfd >= 0) pthread_create(&ctl, NULL, control_main, NULL);
    for (int i = 0; i < cfg.workers; i++) pthread_create(&t[i], NULL, worker_main, all_workers[i]);
}

int gkp_wait(void) {
    for (;;) {                                                // gkp_stop: now; gkp_drain: once drained
        struct timespec tick = { 0, 50 * 1000000L };
        nanosleep(&tick, NULL);
        if (atomic_load(&stopping)) break;
        if (!atomic_load(&draining)) continue;
        uint64_t open = 0;
        for (int i = 0; i < cfg.workers; i++) open += all_workers[i]->active;   // racy read: fine here
        if (!open) { fprintf(stderr, "drained: every session ended\n"); break; }
        if (now_ms() >= atomic_load(&drain_until)) {
            fprintf(stderr, "drain deadline: closing %lu open sessions\n", (unsigned long)open);
            break;
        }
    }
    if (cfg.verbose) {                                        // racy snapshot: fine for diagnostics
        for (int i = 0; i < cfg.workers; i++) { fprintf(stderr, "final "); print_stats(all_workers[i]); }
    }
    return 0;
}
