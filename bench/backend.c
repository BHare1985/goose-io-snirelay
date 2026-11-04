// Minimal keep-alive HTTP backend for proxy benchmarking.
//   GET /<N>  -> 200 with an N-byte body, body[i] = i % 251 (detects corruption/reordering)
//   GET /     -> 11-byte body
//   GET /<path> of a file under the static root (3rd argument) -> that file, with a Content-Type
//             by extension. The tree is loaded into memory at startup (a warm page cache, as a
//             static file server under load would have)
//   'Connection: close' in the request -> answered, then the connection is closed
//   TLS handshake records in front of a request (a ClientHello, as proxybench's sni-plain suite sends)
//             are skipped: SNI proxies route on them, the request itself is plain HTTP
// Usage: backend [threads] [port | ip:port,ip:port,...] [static_root]   (a bare port = 127.0.0.1)
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <ftw.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#define MAXBODY (64u << 20)
static unsigned char *body;
#define MAXLISTEN 32
static struct sockaddr_in g_addr[MAXLISTEN];
static int g_naddr;

// ------------------------------------------------------------- static files ----
struct sfile { char path[256]; size_t plen; unsigned char *data; size_t len; const char *ctype; };
static struct sfile *files;
static size_t nfiles, files_cap;
static size_t root_len;

static const char *ctype_of(const char *p) {
    static const struct { const char *ext, *type; } map[] = {
        { ".html", "text/html; charset=utf-8" }, { ".css", "text/css" },
        { ".js", "application/javascript" }, { ".json", "application/json" },
        { ".svg", "image/svg+xml" }, { ".png", "image/png" }, { ".jpg", "image/jpeg" },
        { ".webp", "image/webp" }, { ".woff2", "font/woff2" }, { ".ico", "image/x-icon" },
    };
    const char *dot = strrchr(p, '.');
    for (size_t i = 0; dot && i < sizeof map / sizeof map[0]; i++)
        if (!strcmp(dot, map[i].ext)) return map[i].type;
    return "application/octet-stream";
}

static int load_file(const char *fpath, const struct stat *sb, int type, struct FTW *ftw) {
    (void)ftw;
    if (type != FTW_F || strlen(fpath + root_len) >= sizeof files[0].path) return 0;
    if (nfiles == files_cap) {
        files_cap = files_cap ? files_cap * 2 : 64;
        if (!(files = realloc(files, files_cap * sizeof *files))) { perror("realloc"); exit(1); }
    }
    struct sfile *f = &files[nfiles];
    f->len = sb->st_size;
    f->data = malloc(f->len ? f->len : 1);
    int fd = open(fpath, O_RDONLY);
    if (fd < 0 || !f->data || read(fd, f->data, f->len) != (ssize_t)f->len) { perror(fpath); exit(1); }
    close(fd);
    strcpy(f->path, fpath + root_len);                 // "/static/js/app.js"
    f->plen = strlen(f->path);
    f->ctype = ctype_of(f->path);
    nfiles++;
    return 0;
}

static const struct sfile *find_file(const char *p, size_t n) {
    for (size_t i = 0; i < nfiles; i++)
        if (files[i].plen == n && !memcmp(files[i].path, p, n)) return &files[i];
    return NULL;
}

struct conn {
    int fd, inlen, sending, close_after, listener;
    size_t hdr_len, body_len, sent;
    const unsigned char *bp;           // body being sent: a static file, or the i % 251 pattern
    char hdr[224];
    char in[4097];
};

static void set_events(int ep, struct conn *c, uint32_t ev) {
    struct epoll_event e = { .events = ev, .data.ptr = c };
    epoll_ctl(ep, EPOLL_CTL_MOD, c->fd, &e);
}

// returns 1 = response fully sent, 0 = would block, -1 = error
static int flush_resp(struct conn *c) {
    size_t total = c->hdr_len + c->body_len;
    while (c->sent < total) {
        ssize_t n;
        if (c->sent < c->hdr_len) {
            struct iovec iov[2] = {
                { c->hdr + c->sent, c->hdr_len - c->sent },
                { (void *)c->bp, c->body_len },
            };
            n = writev(c->fd, iov, c->body_len ? 2 : 1);
        } else {
            n = send(c->fd, c->bp + (c->sent - c->hdr_len), total - c->sent, MSG_NOSIGNAL);
        }
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) return 0;
            return -1;
        }
        c->sent += n;
    }
    return 1;
}

// returns 0 ok, -1 close; sets *blocked when waiting for EPOLLOUT
static int process(struct conn *c, int *blocked) {
    *blocked = 0;
    for (;;) {
        if (c->sending) {
            int r = flush_resp(c);
            if (r < 0) return -1;
            if (r == 0) { *blocked = 1; return 0; }
            c->sending = 0;
            if (c->close_after) return -1;          // "Connection: close": done, close it
        }
        while (c->inlen >= 5 && (unsigned char)c->in[0] == 22 && c->in[1] == 3) {   // a TLS handshake record
            int rl = 5 + ((unsigned char)c->in[3] << 8 | (unsigned char)c->in[4]);
            if (rl > (int)sizeof c->in - 1) return -1;
            if (c->inlen < rl) return 0;                       // wait for the rest of it
            memmove(c->in, c->in + rl, c->inlen - rl);
            c->inlen -= rl;
        }
        c->in[c->inlen] = 0;
        char *end = memmem(c->in, c->inlen, "\r\n\r\n", 4);
        if (!end) return 0;
        size_t reqlen = (end + 4) - c->in;
        size_t n = 11;
        const struct sfile *f = NULL;
        if (c->inlen >= 5 && !memcmp(c->in, "GET /", 5)) {
            char *e;
            unsigned long v = strtoul(c->in + 5, &e, 10);
            if (e != c->in + 5 && *e == ' ') n = v > MAXBODY ? MAXBODY : v;
            else if (nfiles) {
                char *sp = memchr(c->in + 4, ' ', reqlen - 4);
                if (sp) f = find_file(c->in + 4, sp - (c->in + 4));
            }
        }
        *end = 0;
        c->close_after = strcasestr(c->in, "\r\nConnection: close") != NULL;
        if (f) n = f->len;
        c->hdr_len = snprintf(c->hdr, sizeof c->hdr,
            "HTTP/1.1 200 OK\r\nContent-Length: %zu\r\nContent-Type: %s\r\n%s\r\n", n,
            f ? f->ctype : "application/octet-stream", c->close_after ? "Connection: close\r\n" : "");
        c->bp = f ? f->data : body;
        c->body_len = n;
        c->sent = 0;
        c->sending = 1;
        memmove(c->in, c->in + reqlen, c->inlen - reqlen);
        c->inlen -= reqlen;
    }
}

static void *loop(void *arg) {
    (void)arg;
    int one = 1, ep = epoll_create1(0);
    for (int k = 0; k < g_naddr; k++) {
        struct conn *l = calloc(1, sizeof *l);
        l->listener = 1;
        l->fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
        setsockopt(l->fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        setsockopt(l->fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
        if (bind(l->fd, (void *)&g_addr[k], sizeof g_addr[k]) < 0) { perror("backend bind"); exit(1); }
        // accept TCP Fast Open (request data in the SYN) from clients that use it, when the host
        // allows server-side TFO (net.ipv4.tcp_fastopen & 2); other clients are unaffected
        int qlen = 4096;
        setsockopt(l->fd, IPPROTO_TCP, TCP_FASTOPEN, &qlen, sizeof qlen);
        listen(l->fd, 4096);
        struct epoll_event ev = { .events = EPOLLIN, .data.ptr = l };
        epoll_ctl(ep, EPOLL_CTL_ADD, l->fd, &ev);
    }

    struct epoll_event evs[256];
    for (;;) {
        int n = epoll_wait(ep, evs, 256, -1);
        for (int i = 0; i < n; i++) {
            struct conn *c = evs[i].data.ptr;
            if (c->listener) {
                int lfd = c->fd;
                for (;;) {
                    int fd = accept4(lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (fd < 0) break;
                    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
                    c = calloc(1, sizeof *c);
                    c->fd = fd;
                    struct epoll_event ce = { .events = EPOLLIN, .data.ptr = c };
                    epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ce);
                }
                continue;
            }
            int blocked = 0, dead = 0;
            if (evs[i].events & (EPOLLERR | EPOLLHUP)) dead = 1;
            if (!dead && (evs[i].events & EPOLLIN) && !c->sending) {
                ssize_t r = read(c->fd, c->in + c->inlen, sizeof c->in - 1 - c->inlen);
                if (r == 0) dead = 1;
                else if (r < 0 && errno != EAGAIN && errno != EINTR) dead = 1;
                else if (r > 0) c->inlen += r;
            }
            if (!dead && process(c, &blocked) < 0) dead = 1;
            if (dead) { close(c->fd); free(c); continue; }
            set_events(ep, c, blocked ? EPOLLOUT : EPOLLIN);
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    int threads = argc > 1 ? atoi(argv[1]) : 1;
    char spec[1024] = "8080";
    if (argc > 2) snprintf(spec, sizeof spec, "%s", argv[2]);
    for (char *save = NULL, *it = strtok_r(spec, ",", &save); it; it = strtok_r(NULL, ",", &save)) {
        if (g_naddr == MAXLISTEN) { fprintf(stderr, "backend: at most %d addresses\n", MAXLISTEN); return 1; }
        struct sockaddr_in *a = &g_addr[g_naddr++];
        char *colon = strrchr(it, ':');
        *a = (struct sockaddr_in){ .sin_family = AF_INET, .sin_port = htons(atoi(colon ? colon + 1 : it)),
                                   .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
        if (colon) { *colon = 0; if (inet_pton(AF_INET, it, &a->sin_addr) != 1) { fprintf(stderr, "backend: bad address %s\n", it); return 1; } }
    }
    if (argc > 3) {
        root_len = strlen(argv[3]);
        while (root_len > 1 && argv[3][root_len - 1] == '/') root_len--;
        if (nftw(argv[3], load_file, 16, FTW_PHYS) < 0) { perror(argv[3]); return 1; }
        fprintf(stderr, "backend: %zu static files from %s\n", nfiles, argv[3]);
    }
    signal(SIGPIPE, SIG_IGN);
    body = malloc(MAXBODY);
    for (size_t i = 0; i < MAXBODY; i++) body[i] = i % 251;
    pthread_t t[64];
    for (int i = 0; i < threads; i++) pthread_create(&t[i], NULL, loop, NULL);
    for (int i = 0; i < threads; i++) pthread_join(t[i], NULL);
    return 0;
}
