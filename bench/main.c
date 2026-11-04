// The gk-proxy CLI: the library (proxy.c, gkproxy.h) plus the signals it leaves to its host.
//   SIGTERM, SIGINT  stop now
//   SIGUSR1          drain (--drain-timeout), as the control socket's "drain"
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include "gkproxy.h"

static sigset_t sigs;

static void *signal_main(void *arg) {
    (void)arg;
    for (int sig;;) {
        if (sigwait(&sigs, &sig)) continue;
        if (sig == SIGUSR1) gkp_drain(0);
        else gkp_stop();
    }
    return NULL;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    sigemptyset(&sigs); sigaddset(&sigs, SIGTERM); sigaddset(&sigs, SIGINT); sigaddset(&sigs, SIGUSR1);
    pthread_sigmask(SIG_BLOCK, &sigs, NULL);                  // inherited by every thread; sigwait takes them
    int rc = gkp_init(argc, argv);
    if (rc) return rc;
    pthread_t t;
    pthread_create(&t, NULL, signal_main, NULL);
    gkp_start();
    return gkp_wait();
}
