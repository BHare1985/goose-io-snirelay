// gk-proxy as a library: the CLI (main.c) and the gatekeeper Go binary (cgo) both drive it through
// these calls. One proxy per process; call them in order: gkp_init, gkp_start, then gkp_wait.
//
// Signals are the host's job: the library installs no handlers. The host must
//   - ignore SIGPIPE before gkp_start (a send to a closed peer would otherwise kill the process);
//   - turn its stop and drain signals into gkp_stop / gkp_drain (main.c: SIGTERM/SIGINT, SIGUSR1).
// Threads gkp_start creates inherit the caller's signal mask.
#ifndef GKPROXY_H
#define GKPROXY_H

// Parses the CLI flags (same as the proxy binary: argv[0] is the program name), binds the listeners
// and the control socket, and prints the configuration to stdout. 0: ready; 2: bad flags (the reason
// is on stderr). A fatal setup error exits the process with status 1.
int gkp_init(int argc, char **argv);

// Starts the workers, the checker, the resolver and the control socket. Returns at once.
void gkp_start(void);

// Blocks until gkp_stop, or until a drain (gkp_drain or the control socket's "drain") has finished:
// every session ended, or the drain deadline passed. Returns the process exit status (0). The caller
// then exits; open sessions close with the process.
int gkp_wait(void);

// Stop now. Safe from any thread, and from a signal handler.
void gkp_stop(void);

// Graceful stop: close the listeners, let open sessions end for up to MS (0: --drain-timeout).
// From any thread, not from a signal handler. A second drain keeps the first deadline.
void gkp_drain(unsigned ms);

#endif
