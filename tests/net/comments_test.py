#!/usr/bin/env python3
# Proves: RT-11b   (every public function of the library has a comment directly above it, saying what it does)
#
#     tests/net/comments_test.py
#
# Public = a top-level `fn` whose name does not start with an underscore, in the library's own *.goose files (not tests or examples).
# A `let` line between the comment and the fn (a constant the comment also covers) is allowed. Whether the comment also says who owns
# what and whether the call can fail is a review matter; the test makes sure there IS a comment.
import glob, os, re, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness"))
from netlib import *

t = Test("comments_test", "RT-11b")
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

def body():
    missing, total = [], 0
    for path in sorted(glob.glob(os.path.join(ROOT, "*.goose"))):
        lines = open(path).read().split("\n")
        for i, line in enumerate(lines):
            m = re.match(r"(?:recursive )?fn ([A-Za-z]\w*)", line)
            if not m:
                continue
            total += 1
            j = i - 1
            while j >= 0 and lines[j].startswith("let "):
                j -= 1
            if j < 0 or not lines[j].lstrip().startswith("//"):
                missing.append(f"{os.path.basename(path)}:{i + 1} {m.group(1)}")
    t.check(total > 20, f"RT-11b found the public functions ({total})")
    t.check(not missing, f"RT-11b every public function has a comment above it (missing: {missing})")

t.run(body)
t.finish()
