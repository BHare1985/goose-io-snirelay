---
name: goose-packages-and-c
description: Make and consume Goose packages and include C libraries. Use for any package layout, namespace, sidecar .build file, c_sources/c_headers/cmake_target/extern block, vendored C, versioned git imports, or C ABI mapping question in Goose.
---

# Goose packages and C (full notes: `goose-kb/GOOSE_PACKAGES_AND_C.md`)

- Package = dir with `name.goose` (`namespace name;` in EVERY file), optional `name.build` sidecar, `src/` C, `vendor/`, and
  root programs in `tests/` `examples/` that `import name from "..";`. Only the root file declares packages
  (`import tcprouter from "github.com/bhare1985/tcprouter@v0";`); others `import name;`. Inside the package: `import .other;`.
- Sidecar keys: `c_sources c_include c_defines c_flags_cc c_libs c_headers cmake_target cmake_options dylibs main_thread_only exclude`
  (+ `_linux/_windows/_macos`). Always set `exclude = ["tests","examples","bench","design","goose-kb"];`.
- Choose: plain libc `extern fn` for fixed-arity libc; `c_sources` for anything needing system structs/macros (works in `run`
  and `build`); `c_headers` static-inline shims only (breaks `goose run` here: TinyCC lacks system headers); `cmake_target` for
  CMake libs; `extern "lib" {}` for dlopen (libc needs `dylibs_linux=["c=libc.so.6"]`).
- Boundary: slices = `{data,len}` struct you declare in C; `T&` = pointer (never NULL); builder `u8[>..]&` = `gs_rref` via
  `#include "goose.h"` + `gs_bld_append`; C pointers cross as `i64` handles; no variadics/callbacks/returned refs.
  Structs are packed: mirror with `__attribute__((packed))` + `_Static_assert(sizeof…)`.
- Package C is always built release (even with `--debug`); threads need `goose build`; C must not keep borrowed args.
- Reference implementation: `~/dev/netbench/references/goose-libdeflate`. Verified experiments: `goose-kb/GOOSE_TEST_PROGRAMS/pkg_*`.
