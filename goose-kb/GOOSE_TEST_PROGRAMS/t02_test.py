#!/usr/bin/env python3
"""End-to-end test for t02_tcp_proxy: echo upstream <- proxy <- N concurrent clients."""
import os, socket, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
UP, PX = 19101, 19102

def echo_server(stop):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", UP)); s.listen(64); s.settimeout(0.2)
    def handle(c):
        with c:
            while (d := c.recv(65536)):
                c.sendall(d)
    while not stop.is_set():
        try:
            c, _ = s.accept()
        except socket.timeout:
            continue
        threading.Thread(target=handle, args=(c,), daemon=True).start()

stop = threading.Event()
threading.Thread(target=echo_server, args=(stop,), daemon=True).start()
proxy = subprocess.Popen([os.path.join(HERE, "t02_tcp_proxy"), str(PX), str(UP), "4"],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
time.sleep(0.5)

failures = []
def client(i):
    try:
        payload = os.urandom(300_000)         # bigger than the 16 KiB relay buffer
        with socket.create_connection(("127.0.0.1", PX), timeout=10) as c:
            def writer():
                c.sendall(payload); c.shutdown(socket.SHUT_WR)
            t = threading.Thread(target=writer); t.start()
            got = b""
            while (d := c.recv(65536)):
                got += d
            t.join()
        if got != payload:
            failures.append((i, "mismatch", len(got), len(payload)))
    except Exception as e:
        failures.append((i, repr(e)))

ts = [threading.Thread(target=client, args=(i,)) for i in range(12)]   # 12 clients > 4 workers
t0 = time.time()
[t.start() for t in ts]; [t.join() for t in ts]
print(f"12 clients x 300000 bytes via 4 workers in {time.time()-t0:.2f}s; failures={failures}")

# upstream down: proxy must survive and report
down = subprocess.Popen([os.path.join(HERE, "t02_tcp_proxy"), "19103", "19999", "1"],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
time.sleep(0.4)
with socket.create_connection(("127.0.0.1", 19103), timeout=3) as c:
    print("upstream-down client recv ->", c.recv(10))      # expect b'' (closed)
time.sleep(0.2)
print("proxy still alive:", down.poll() is None)
down.terminate(); print("stderr:", down.communicate(timeout=3)[1].strip())

proxy.terminate(); out, err = proxy.communicate(timeout=3)
print("proxy stdout:", out.strip(), "| stderr:", err.strip())
stop.set()
sys.exit(1 if failures else 0)
