"""Helpers for tcprouter's network tests: Python 3 standard library only.

The tests drive the system under test (harness/forward_server.goose) from outside, with independent clients
and backends, so a bug in the library cannot hide behind a matching bug in the test.

  Test      counts checks, prints FAIL lines and a final "all N checks passed" (what run_tests.sh looks for)
  Server    runs forward_server, parses its READY/STAT lines, tracks its RSS
  EchoBackend, HoldBackend, ThreadedBackend   backends the proxy forwards to
  stream/digest   deterministic pseudo-random payloads, so a 1 GB transfer needs no 1 GB of memory
"""
import fcntl, hashlib, os, random, resource, selectors, signal, socket, struct, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.environ.get("FORWARD_SERVER", os.path.join(HERE, "forward_server"))
HANDLER_SERVER = os.environ.get("HANDLER_SERVER", os.path.join(HERE, "handler_server"))

# --------------------------------------------------------------------------------------------- reporting

class Test:
    def __init__(self, name, rows):
        self.name, self.rows = name, rows
        self.checks = self.failures = self.skips = 0
        self._lock = threading.Lock()
        print(f"# {name}: proves {rows}", flush=True)

    def check(self, ok, what):
        with self._lock:
            self.checks += 1
            if not ok:
                self.failures += 1
                print(f"FAIL: {what}", flush=True)
        return ok

    def skip(self, what, reason):
        with self._lock:
            self.skips += 1
        print(f"SKIP: {what}: {reason}", flush=True)

    def note(self, text):
        print(f"  {text}", flush=True)

    def run(self, body):
        """Runs body(); an exception (server died, timeout) is one failed check, not a traceback."""
        try:
            body()
        except Exception as e:
            import traceback
            where = traceback.extract_tb(e.__traceback__)[-1]
            self.check(False, f"{type(e).__name__}: {e} (at {os.path.basename(where.filename)}:{where.lineno} in {where.name})")

    def finish(self):
        if self.failures:
            print(f"{self.failures} of {self.checks} checks FAILED", flush=True)
            sys.exit(1)
        suffix = f" ({self.skips} skipped, see SKIP lines)" if self.skips else ""
        print(f"all {self.checks} checks passed{suffix}", flush=True)
        sys.exit(0)

# --------------------------------------------------------------------------------------------- ports, limits

_lock_file = None

def host_lock():
    """One network test at a time on this host (they use fixed port ranges and measure memory)."""
    global _lock_file
    _lock_file = open("/tmp/tcprouter-net-tests.lock", "w")
    fcntl.flock(_lock_file, fcntl.LOCK_EX)

def port_is_free(port, host="127.0.0.1"):
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    s = socket.socket(family, socket.SOCK_STREAM)
    s.settimeout(0.2)
    try:
        s.connect((host, port))
        return False                      # something is listening
    except (ConnectionRefusedError, OSError):
        return True
    finally:
        s.close()

_handed_out = set()

def free_port(host="127.0.0.1"):
    """A port nobody is listening on now, on both loopbacks. (A port taken by a SO_REUSEPORT listener
    would be silently shared with the proxy, so check it before use: design/06 'Steve's list'.)"""
    for _ in range(100):
        s = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET, socket.SOCK_STREAM)
        s.bind((host, 0))
        port = s.getsockname()[1]
        s.close()
        # bind(0) tends to give the same port again right after it was released, so keep a list: two tests ports must
        # never be equal (a "refused" target that is also the proxy's own port would connect, and loop).
        if port in _handed_out:
            continue
        if port_is_free(port, "127.0.0.1") and (not has_ipv6() or port_is_free(port, "::1")):
            _handed_out.add(port)
            return port
    raise RuntimeError("no free port")

def has_ipv6():
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s.bind(("::1", 0))
        s.close()
        return True
    except OSError:
        return False

def raise_nofile(want):
    """Raises the soft RLIMIT_NOFILE towards `want`; returns the limit in force (may be lower)."""
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    target = want if hard == resource.RLIM_INFINITY else min(want, hard)
    if soft < target:
        resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
    return resource.getrlimit(resource.RLIMIT_NOFILE)[0]

def rss_kb(pid):
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    return 0

# --------------------------------------------------------------------------------------------- payloads

CHUNK = 1 << 20

def stream(seed, total):
    """Deterministic pseudo-random bytes in chunks of up to 1 MB: the same seed gives the same bytes."""
    rng = random.Random(seed)
    left = total
    while left > 0:
        n = min(CHUNK, left)
        yield rng.randbytes(n)
        left -= n

def digest(seed, total):
    h = hashlib.sha256()
    for c in stream(seed, total):
        h.update(c)
    return h.hexdigest()

def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        d = sock.recv(n - len(buf))
        if not d:
            raise EOFError(f"connection closed after {len(buf)} of {n} bytes")
        buf += d
    return bytes(buf)

def read_all(sock, h=None):
    """Reads to EOF; returns the byte count (and updates hash h if given)."""
    n = 0
    while True:
        d = sock.recv(1 << 16)
        if not d:
            return n
        n += len(d)
        if h is not None:
            h.update(d)

def send_stream(sock, seed, total, h=None):
    for c in stream(seed, total):
        sock.sendall(c)
        if h is not None:
            h.update(c)

# --------------------------------------------------------------------------------------------- the server

class ServerDied(Exception):
    pass

class Server:
    """Runs forward_server and follows its stdout/stderr."""
    def __init__(self, listens, targets, workers=1, buffers=None, buffer_size=None, stat_ms=1000, nofile=None, routes=(),
                 extra=(), exe=None, handles=()):
        self.workers = workers
        self.exe = exe or SERVER
        self.args = [self.exe]
        for h in handles: self.args += ["--handle", h]
        for l in listens: self.args += ["--listen", l]
        for t in targets: self.args += ["--to", t]
        for listen, tos in routes: self.args += ["--route", f"{listen}={','.join(tos)}"]
        self.args += list(extra)
        self.args += ["--workers", str(workers), "--stat-ms", str(stat_ms)]
        if buffers: self.args += ["--buffers", str(buffers)]
        if buffer_size: self.args += ["--buffer-size", str(buffer_size)]
        self.nofile = nofile
        self.ready = set()
        self.stats = {}                 # worker index -> latest STAT dict
        self.stat_lines = 0
        self.max_buffers_in_use = 0
        self.stderr = []
        self.lines = []                 # every other stdout line (handler_server's "E …" event log)
        self._lock = threading.Lock()

    def start(self):
        if not os.path.exists(self.exe):
            raise ServerDied(f"{self.exe} is not built")
        def limits():
            # The server gets exactly this soft limit: lower than the driver's too (raise_nofile only raises).
            if self.nofile:
                soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
                resource.setrlimit(resource.RLIMIT_NOFILE, (min(self.nofile, hard), hard))
        self.proc = subprocess.Popen(self.args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                     preexec_fn=limits)
        threading.Thread(target=self._read_out, daemon=True).start()
        threading.Thread(target=self._read_err, daemon=True).start()
        return self

    def _read_out(self):
        for line in self.proc.stdout:
            parts = line.split()
            with self._lock:
                if parts[:1] == ["READY"]:
                    self.ready.add(int(parts[1]))
                elif parts[:1] != ["STAT"]:
                    self.lines.append(line.rstrip("\n"))
                elif parts[:1] == ["STAT"]:
                    d = {"worker": int(parts[1])}
                    for kv in parts[2:]:
                        k, v = kv.split("=")
                        d[k] = [int(x) for x in v.split(",")] if "," in v else int(v)
                    d["at"] = time.time()
                    self.stats[d["worker"]] = d
                    self.stat_lines += 1
                    self.max_buffers_in_use = max(self.max_buffers_in_use, d.get("buffers_in_use", 0))

    def _read_err(self):
        for line in self.proc.stderr:
            self.stderr.append(line.rstrip())

    def command(self, line):
        """Sends a command line to the server's control thread (forward_server --control)."""
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def wait_exit(self, timeout):
        """Waits for the process to end; returns (seconds waited, exit status) or (seconds, None) if it did not."""
        t0 = time.time()
        try:
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return time.time() - t0, None
        return time.time() - t0, self.proc.returncode

    def alive(self):
        return self.proc.poll() is None

    def wait_ready(self, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            if len(self.ready) >= self.workers:
                return self
            if not self.alive():
                time.sleep(0.2)
                raise ServerDied(f"forward_server exited with status {self.proc.returncode} before it was ready"
                                 f" (stderr: {' | '.join(self.stderr) or 'empty'})")
            time.sleep(0.05)
        raise ServerDied("forward_server was not ready in time")

    def total(self, key):
        with self._lock:
            return sum(s.get(key, 0) for s in self.stats.values())

    CLOSE_REASONS = ["PeerClosed", "PeerReset", "IdleTimeout", "HalfCloseTimeout", "InspectTimeout",
                     "ConnectFailed", "Fenced", "Drained", "ByHandler", "Error", "InvalidHello"]

    def closed(self, reason):
        """Connections closed for `reason` (a CloseReason name), summed over workers."""
        i = self.CLOSE_REASONS.index(reason)
        with self._lock:
            return sum((s.get("closed") or [0] * 11)[i] for s in self.stats.values())

    def wait_closed(self, reason, pred, timeout=5):
        end = time.time() + timeout
        v = self.closed(reason)
        while time.time() < end:
            v = self.closed(reason)
            if pred(v):
                return v
            time.sleep(0.05)
        return v

    def stat_of(self, worker, key):
        with self._lock:
            return self.stats.get(worker, {}).get(key, 0)

    def cpu_seconds(self):
        """User + system CPU time the server process has used so far."""
        with open(f"/proc/{self.proc.pid}/stat") as f:
            fields = f.read().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")

    def wait_stat(self, key, pred, timeout=5):
        """Waits until pred(total of `key` across workers) holds; returns the last value seen."""
        end = time.time() + timeout
        v = self.total(key)
        while time.time() < end:
            v = self.total(key)
            if pred(v):
                return v
            time.sleep(0.05)
        return v

    def ticking(self, seconds=2.5):
        """True if STAT lines keep arriving: the worker's loop is not wedged."""
        before = self.stat_lines
        time.sleep(seconds)
        return self.stat_lines > before

    def rss_kb(self):
        return rss_kb(self.proc.pid)

    def stop(self):
        if not hasattr(self, "proc"):
            return                          # start() never got as far as a process
        if self.proc.poll() is None:
            try: self.proc.stdin.close()
            except Exception: pass
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()

# --------------------------------------------------------------------------------------------- backends

class _Listening:
    def __init__(self, port, host="127.0.0.1", backlog=1024, rcvbuf=None):
        self.port = port
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if rcvbuf:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
        self.sock.bind((host, port))
        self.sock.listen(backlog)
        self.sock.setblocking(False)
        self.accepted = 0

class EchoBackend(_Listening):
    """Single-threaded non-blocking echo: scales to thousands of connections. On EOF it flushes, then closes."""
    def __init__(self, port, **kw):
        super().__init__(port, **kw)
        self.sel = selectors.DefaultSelector()
        self.sel.register(self.sock, selectors.EVENT_READ, None)
        self.pending = {}                 # conn -> bytes still to send
        self.eof = set()
        self.stop_flag = False
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def _loop(self):
        while not self.stop_flag:
            for key, ev in self.sel.select(0.1):
                if key.data is None:
                    self._accept()
                else:
                    self._conn(key.fileobj, ev)

    def _accept(self):
        while True:
            try:
                c, _ = self.sock.accept()
            except (BlockingIOError, InterruptedError):
                return
            except OSError:
                return
            c.setblocking(False)
            self.accepted += 1
            self.pending[c] = b""
            self.sel.register(c, selectors.EVENT_READ, "conn")

    def _close(self, c):
        try: self.sel.unregister(c)
        except Exception: pass
        self.pending.pop(c, None)
        self.eof.discard(c)
        try: c.close()
        except OSError: pass

    def _conn(self, c, ev):
        try:
            if ev & selectors.EVENT_READ and c not in self.eof:
                d = c.recv(1 << 16)
                if not d:
                    self.eof.add(c)
                else:
                    self.pending[c] += d
            if self.pending.get(c):
                n = c.send(self.pending[c])
                self.pending[c] = self.pending[c][n:]
            if c in self.eof and not self.pending.get(c):
                try: c.shutdown(socket.SHUT_WR)
                except OSError: pass
                self._close(c)
                return
            want = selectors.EVENT_READ if c not in self.eof else 0
            if self.pending.get(c):
                want |= selectors.EVENT_WRITE
            if want:
                self.sel.modify(c, want, "conn")
        except (BlockingIOError, InterruptedError):
            pass
        except OSError:
            self._close(c)

    def open_count(self):
        return len(self.pending)

    def stop(self):
        self.stop_flag = True
        self.thread.join(2)
        for c in list(self.pending):
            self._close(c)
        self.sock.close()

class HoldBackend(_Listening):
    """Accepts connections and never reads from them (until drain() is called). For backpressure and idle tests."""
    def __init__(self, port, **kw):
        super().__init__(port, **kw)
        self.conns = []
        self.stop_flag = False
        self.digest = hashlib.sha256()
        self.received = 0
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def _loop(self):
        while not self.stop_flag:
            try:
                c, _ = self.sock.accept()
                self.conns.append(c)
                self.accepted += 1
            except (BlockingIOError, InterruptedError):
                time.sleep(0.01)
            except OSError:
                return

    def drain_all(self, timeout=120):
        """Starts reading every accepted connection, each in a thread. A client's first 4 bytes are its id;
        what follows is hashed. Returns {id: (bytes, sha256 hex)} once every connection has ended."""
        results, lock = {}, threading.Lock()
        def one(c):
            c.setblocking(True)
            c.settimeout(timeout)
            cid = struct.unpack(">I", recv_exact(c, 4))[0]
            h = hashlib.sha256()
            n = read_all(c, h)
            with lock:
                results[cid] = (n, h.hexdigest())
            c.close()
        ts = [threading.Thread(target=one, args=(c,), daemon=True) for c in list(self.conns)]
        for th in ts: th.start()
        for th in ts: th.join(timeout)
        return results

    def drain(self, expect_bytes, timeout=120):
        """Starts reading the first connection, hashing what arrives, until `expect_bytes` or EOF."""
        c = self.conns[0]
        c.setblocking(True)
        c.settimeout(timeout)
        while self.received < expect_bytes:
            d = c.recv(1 << 20)
            if not d:
                break
            self.received += len(d)
            self.digest.update(d)
        return self.received

    def stop(self):
        self.stop_flag = True
        for c in self.conns:
            try: c.close()
            except OSError: pass
        self.sock.close()

class ThreadedBackend:
    """A backend that runs handler(conn) in a thread per accepted connection. For scripted scenarios."""
    def __init__(self, port, handler, host="127.0.0.1"):
        self.port, self.handler = port, handler
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((host, port))
        self.sock.listen(1024)
        self.sock.settimeout(0.2)
        self.stop_flag = False
        self.results = []
        self.errors = []
        self._lock = threading.Lock()
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while not self.stop_flag:
            try:
                c, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self._run, args=(c,), daemon=True).start()

    def _run(self, c):
        try:
            r = self.handler(c)
            with self._lock:
                self.results.append(r)
        except Exception as e:
            with self._lock:
                self.errors.append(repr(e))
        finally:
            try: c.close()
            except OSError: pass

    def wait_results(self, n, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            with self._lock:
                if len(self.results) + len(self.errors) >= n:
                    break
            time.sleep(0.02)
        with self._lock:
            return list(self.results)

    def stop(self):
        self.stop_flag = True
        self.sock.close()

def connect(port, host="127.0.0.1", timeout=10):
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    s = socket.socket(family, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((host, port))
    return s

def run_threads(fns, join_timeout=300):
    """Runs each fn in its own thread; returns the list of results (exceptions become the result)."""
    results = [None] * len(fns)
    def wrap(i, f):
        try:
            results[i] = f()
        except Exception as e:
            results[i] = e
    ts = [threading.Thread(target=wrap, args=(i, f), daemon=True) for i, f in enumerate(fns)]
    for t in ts: t.start()
    for t in ts: t.join(join_timeout)
    return results


class ProcessBackend:
    """Runs an external backend program (the C echo_server) and waits for its READY line."""
    def __init__(self, port):
        exe = os.environ.get("ECHO_SERVER", os.path.join(HERE, "echo_server"))
        self.proc = subprocess.Popen([exe, str(port)], stdout=subprocess.PIPE, text=True)
        line = self.proc.stdout.readline()
        if line.strip() != "READY":
            raise RuntimeError(f"echo_server did not start: {line!r}")

    def stop(self):
        self.proc.terminate()
        self.proc.wait()


class BlackholeBackend:
    """An address where a connect never completes, with no firewall and no root: a listen(0) socket whose accept queue is
    filled, so further SYNs are dropped and the connecting side waits (and retransmits) until its own timeout."""
    def __init__(self, port, host="127.0.0.1"):
        self.port = port
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((host, port))
        self.sock.listen(0)
        self.fillers = []
        for _ in range(8):                          # fill the accept queue; the later ones just hang
            f = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            f.setblocking(False)
            try:
                f.connect((host, port))
            except BlockingIOError:
                pass
            self.fillers.append(f)
        time.sleep(0.2)
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        probe.settimeout(0.4)
        try:
            probe.connect((host, port))
            raise RuntimeError("the blackhole accepted a connection: the accept queue is not full")
        except socket.timeout:
            pass
        finally:
            probe.close()

    def stop(self):
        for f in self.fillers:
            f.close()
        self.sock.close()
