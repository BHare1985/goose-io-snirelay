#!/usr/bin/env python3
# Proves: RT-11a   (the README's example is the real examples/forward_port.goose, it builds, and the README links only to files that exist)
#
#     tests/net/readme_test.py   (GOOSE=path/to/goose selects the compiler; run_tests.sh sets it)
import os, re, subprocess, sys, tempfile, shutil
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
GOOSE = os.environ.get("GOOSE") or os.path.join(ROOT, "goose-kb", "bin", "goose")

t = Test("readme_test", "RT-11a")

def body():
    readme = open(os.path.join(ROOT, "README.md")).read()
    example = open(os.path.join(ROOT, "examples", "forward_port.goose")).read().rstrip("\n")
    blocks = re.findall(r"```goose\n(.*?)\n```", readme, re.S)
    t.check(example in blocks, "RT-11a the README holds examples/forward_port.goose verbatim in a goose block")
    out = tempfile.mkdtemp(prefix="tcprouter_readme_")
    try:
        exe = os.path.join(out, "forward_port")
        r = subprocess.run([GOOSE, "build", "--debug", "-o", exe, os.path.join(ROOT, "examples", "forward_port.goose")], capture_output=True, text=True)
        t.check(r.returncode == 0 and os.path.exists(exe), f"RT-11a that example builds ({(r.stdout + r.stderr).strip()[-300:] if r.returncode else 'ok'})")
    finally:
        shutil.rmtree(out, ignore_errors=True)
    missing = []
    for target in re.findall(r"\]\(([^)#]+)(?:#[^)]*)?\)", readme):
        if "://" in target:
            continue
        if not os.path.exists(os.path.join(ROOT, target)):
            missing.append(target)
    t.check(not missing, f"RT-11a every file the README links to exists ({missing})")

t.run(body)
t.finish()
