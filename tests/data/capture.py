#!/usr/bin/env python3
"""Regenerates the captured TLS ClientHellos in this directory.

Each client is pointed at a local listener that records the first bytes it sends and then closes.
Only clients installed on the machine are used; each file's header in README.md says which.
Usage: python3 tests/data/capture.py
"""
import os, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))

def capture(name, argv_for_port, env=None):
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0)); srv.listen(1); srv.settimeout(5)
    port = srv.getsockname()[1]
    proc = subprocess.Popen(argv_for_port(port), stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        proc.kill(); print(f"{name}: client never connected"); return False
    conn.settimeout(0.4)
    data = b""
    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk: break
            data += chunk
    except socket.timeout:
        pass
    conn.close(); srv.close(); proc.kill(); proc.wait()
    open(os.path.join(HERE, name), "wb").write(data)
    print(f"{name}: {len(data)} bytes, first bytes {data[:6].hex()}")
    return True

def openssl(sni_args, extra=()):
    return lambda p: ["openssl", "s_client", "-connect", f"127.0.0.1:{p}", *sni_args, *extra]

capture("s1_openssl.bin",          openssl(["-servername", "api.example.com"]))
capture("s2_openssl_upper_dot.bin", openssl(["-servername", "API.Example.COM."]))
capture("s3_openssl_nosni.bin",    openssl(["-noservername"]))
capture("s12_openssl_tls12.bin",   openssl(["-servername", "tls12.example.com"], ["-tls1_2"]))
capture("s12_openssl_tls13_alpn.bin", openssl(["-servername", "alpn.example.com"], ["-tls1_3", "-alpn", "h2,http/1.1"]))
capture("s12_curl_http1.bin", lambda p: ["curl", "-sk", "--http1.1", "--max-time", "3",
        "--resolve", f"curl.example.com:{p}:127.0.0.1", f"https://curl.example.com:{p}/"])
capture("s12_curl_h2.bin", lambda p: ["curl", "-sk", "--http2", "--max-time", "3",
        "--resolve", f"curlh2.example.com:{p}:127.0.0.1", f"https://curlh2.example.com:{p}/"])
py = ("import ssl,socket,sys\n"
      "c=ssl.create_default_context(); c.check_hostname=False; c.verify_mode=ssl.CERT_NONE\n"
      "s=socket.create_connection(('127.0.0.1',int(sys.argv[1])),timeout=3)\n"
      "try: c.wrap_socket(s, server_hostname='python.example.com')\n"
      "except Exception: pass\n")
capture("s12_python.bin", lambda p: [sys.executable, "-I", "-c", py, str(p)])
node = ("const https=require('https');\n"
        "https.get({host:'127.0.0.1',port:+process.argv[1],servername:'node.example.com',rejectUnauthorized:false},()=>{}).on('error',()=>{});\n")
capture("s12_node.bin", lambda p: ["node", "-e", node, str(p)])
# wget sends SNI only for host names; it resolves through the system resolver, so use a name that maps to 127.0.0.1.
capture("s12_wget_localhost.bin", lambda p: ["wget", "-q", "-T", "3", "-t", "1", "--no-check-certificate", "-O", "-",
        f"https://localhost:{p}/"])
