/* TEST-ONLY. A fast echo backend for the network tests: not part of the tcprouter package and not a model
 * for anything. Python cannot accept the 100,000 connections per second that generation_test needs, so this
 * 80-line epoll echo server stands in. It is independent of tcprouter on purpose.
 *
 *   echo_server PORT        listens on 127.0.0.1:PORT, echoes every connection, prints READY
 *
 * Built by tests/run_tests.sh with the system C compiler. Level-triggered epoll, non-blocking sockets,
 * a small pending buffer per connection (the tests send 16 bytes; larger writes are still echoed correctly).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAXFD 1048576
struct conn { char buf[4096]; int len, pos, eof; };
static struct conn *conns[MAXFD];

static void drop(int ep, int fd) {
    epoll_ctl(ep, EPOLL_CTL_DEL, fd, NULL);
    close(fd);
    free(conns[fd]);
    conns[fd] = NULL;
}

static void rearm(int ep, int fd) {
    struct conn *c = conns[fd];
    struct epoll_event ev = { .events = (c->len > c->pos ? EPOLLOUT : EPOLLIN), .data.fd = fd };
    epoll_ctl(ep, EPOLL_CTL_MOD, fd, &ev);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: echo_server PORT\n"); return 2; }
    int ls = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0), one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(atoi(argv[1])) };
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(ls, (struct sockaddr *)&a, sizeof a) < 0 || listen(ls, 4096) < 0) { perror("echo_server"); return 1; }
    int ep = epoll_create1(0);
    struct epoll_event ev = { .events = EPOLLIN, .data.fd = ls };
    epoll_ctl(ep, EPOLL_CTL_ADD, ls, &ev);
    printf("READY\n");
    fflush(stdout);
    struct epoll_event evs[256];
    for (;;) {
        int n = epoll_wait(ep, evs, 256, -1);
        for (int i = 0; i < n; i++) {
            int fd = evs[i].data.fd;
            if (fd == ls) {
                for (;;) {
                    int c = accept4(ls, NULL, NULL, SOCK_NONBLOCK);
                    if (c < 0) break;
                    if (c >= MAXFD) { close(c); continue; }
                    conns[c] = calloc(1, sizeof(struct conn));
                    struct epoll_event e = { .events = EPOLLIN, .data.fd = c };
                    epoll_ctl(ep, EPOLL_CTL_ADD, c, &e);
                }
                continue;
            }
            struct conn *c = conns[fd];
            if (!c) continue;
            if (c->len > c->pos) {                                   /* finish a pending write first */
                ssize_t w = send(fd, c->buf + c->pos, c->len - c->pos, MSG_NOSIGNAL);
                if (w < 0 && errno != EAGAIN) { drop(ep, fd); continue; }
                if (w > 0) c->pos += w;
                if (c->pos == c->len) { c->pos = c->len = 0; if (c->eof) { drop(ep, fd); continue; } }
                rearm(ep, fd);
                continue;
            }
            ssize_t r = recv(fd, c->buf, sizeof c->buf, 0);
            if (r == 0) { drop(ep, fd); continue; }                  /* FIN: done (the test side is closing too) */
            if (r < 0) { if (errno != EAGAIN) drop(ep, fd); continue; }
            ssize_t w = send(fd, c->buf, r, MSG_NOSIGNAL);
            if (w < 0 && errno != EAGAIN) { drop(ep, fd); continue; }
            c->pos = w > 0 ? (int)w : 0;
            c->len = (int)r;
            if (c->pos == c->len) c->pos = c->len = 0; else rearm(ep, fd);
        }
    }
}
