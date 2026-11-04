# Goose packages and C libraries (the key skill for tcprouter)

Tags: **[V]** compiled/run here (programs in `GOOSE_TEST_PROGRAMS/pkg_c_headers`, `pkg_c_sources`, `m0/`),
**[D]** upstream docs (`docs/packages.md`, `docs/design/packages.md`, `docs/design/namespaces.md`, spec §7.10),
**[R]** recommendation. Reference package from the user: `~/dev/netbench/references/goose-libdeflate`
(`deflate.goose` + `deflate.build` + `src/` glue + `vendor/libdeflate`), which I read in full.

## 1. Anatomy of a package [D][V]

```
mylib/                      a git repo, or any directory
  mylib.goose               the entry module: `namespace mylib;` … (the import name = this file name)
  other.goose               more modules: `namespace mylib;` too; imported inside the package as `import .other;`
  mylib.build               the sidecar (optional): C sources/headers/libs, exclude, main_thread_only
  src/*.c, src/*.h, vendor/ the C
  examples/  test/          root programs of their own: `import mylib from "..";`
```
- Consumers declare it **once, in the root file only**, with a pinned source:
  `import mylib from "github.com/bhare1985/tcprouter@v0";` (tag or commit pins; a branch is re-fetched with `--update`),
  or `from "../path"` (used in place, nothing copied). Git import with a tag **works and builds the package's C** [V, local `file://` repo].
  Every other file imports by name only (`import mylib;`). A library that needs another package writes the same
  `import x from "…";` in its entry; the compiler checks it against the root's declaration (flat, one version of each).
- Namespace: `namespace mylib;` at the top of **every file** of the package. All declarations are public; callers write
  `mylib::Config`, `mylib::serve(...)`. The import path does **not** create a namespace: `inner.goose` with
  `namespace mylib;` gives `mylib::twice`, not `mylib::inner::twice` [V].
- Inside the package use **`import .inner;`** (relative to the importing file) [V]. `import mylib.inner;` from inside the
  package fails ("cannot find the module mylib.inner") [V]. Outside, a root program can write `import mylib.inner;`
  (package modules resolve to `<pkg root>/inner.goose`) [D].
- UFCS and `format`/overloads follow the **type's namespace**: `x.f()` for `x: mylib::T` finds `mylib::f` anywhere [D][V o156].
  A plain call `f(x)` stays in the namespace where it is written (no ADL), and overload sets do **not** merge across
  namespaces: inside `namespace tcprouter`, declaring `tcprouter::abort(...)` hides the builtin `abort(msg)` (use `::abort`) [D].
- A tool needs on the user's machine: `git` (to fetch), a C compiler (any C part), `cmake` only for `cmake_target`.
  A package with **no C** needs none of them to build [D].
- `exclude = ["tests","examples","bench","design","goose-kb"];` — directories whose `.goose` files are not the package's own
  (the compiler scans package `.goose` files for `extern fn` symbols; excluding avoids picking up test externs) [D].
- Cache: `~/.goose/pkg/<host>/<owner>/<repo>/<ref>/` (sources), `~/.goose/build/pkg/…/<toolchain>/` (native objects, once per
  C compiler), `~/.goose/build/prog/…` (each program's C). Deleting `~/.goose` loses nothing rebuildable [D].

## 2. Five ways to use C, and which to choose

| Way | Sidecar / syntax | Use when | Verified |
|---|---|---|---|
| A. **Direct libc `extern fn`** | none | the C function has a plain fixed-arity signature and Goose-shaped args (socket, accept4, recv, send, connect, poll, shutdown, close, pipe2, kill, signalfd…) | [V] t01–t03, m0/o8 |
| B. **`c_headers`: static-inline adapters** | `c_headers = ["src/adapters.h"];` | tiny shims written against the real system headers; compiled into the program's own C unit so they inline; **no native part is built** | [V] `pkg_c_headers`: works with `build`; **`goose run` fails on this machine** (`include file 'time.h' not found`: TinyCC can't see system headers) |
| C. **`c_sources`: separately compiled C** | `c_sources = ["src/x.c"]; c_include=[…]; c_defines=[…]; c_flags_cc=[…]; c_libs=["m"];` | anything bigger than a shim; vendored libraries (libdeflate pattern); needs system headers; works under **both** `goose run` and `goose build` | [V] `pkg_c_sources` (also via a git `@v0` import) |
| D. **`cmake_target`** | `cmake_target="name"; cmake_options=[…]` | an upstream library that already has a CMake project (liburing-style); compiler wraps it, extracts the link closure | [D] untested |
| E. **`extern "lib" { fn … }`** | + `dylibs_linux=["name=libfoo.so.1"];` | a *shared* library found at run time (dlopen); libc itself needs `["c=libc.so.6"]` | [V] |

**Decision rule [R]:** prefer A for plain libc; use **C (`c_sources`) for anything that needs a system struct or macro**
(`epoll_event` layout differs between x86-64 and arm64, `CLOCK_BOOTTIME`, `sigset_t`, `sockaddr` for IPv6); use B only for
one-liners where inlining matters and tests run with `build`; vendor third-party C under `vendor/` and compile it with
`c_sources` (no cmake) like goose-libdeflate; reach for D only if the library's build is complicated.
Keep the C layer **thin and boring** (each C function does one syscall-ish job, `_Static_assert`s the layout it shares with Goose).

## 3. Crossing the boundary [D][V]

| Goose | C sees | Notes |
|---|---|---|
| `i8…i64,u8…u64,f32,f64,bool` | `int8_t…`, `double`, 1-byte bool | `size_t` = `u64`; C `long` is `i64` on Linux only |
| `T&` (flat fixed `T`) | `T *` | never NULL, writable as the type says; `const T&` for read-only |
| `T[:]` / `const T[:]` | `struct { T *data; int64_t len; }` — declare it yourself in a header | |
| `T[>..]&` (e.g. `u8[>..]&`) | `gs_rref` from `#include "goose.h"`; append whole elements with `gs_bld_append(ref, p, n)` | the compiler puts `goose.h` on every native part's include path [V]; C may only **append** |
| flat struct by value | packed C struct (no padding) | match with `__attribute__((packed))` or explicit `pad`; structs with `pad` cross **by reference only** |
| fixed array `T[N]` by reference | `T *` / `T (*)[N]` | `buf[0]` passes element 0 for (ptr,len) APIs |
| C pointer owned by C | `i64` / `u64` handle | cast `(int64_t)(intptr_t)p`; Goose can't hold or deref it (goose-libdeflate does this for compressors) |
| return value | one scalar or one flat fixed value, or nothing | **no** refs/slices/builders returned |
| NOT possible | variadic functions (`fcntl`, `ioctl`, `open`), callbacks/function pointers, NULL, optionals, varints | write a C wrapper (way C) |

Names the C side needs when it shares *generated* types (way B only; separately compiled C can't see them) [D][V]:
`mylib::Pair` → `mylib_Pair_g5` (namespace, `_`, type, `_g`, **length of the namespace**); fields get `_g` (`lo_g`);
`Pair` in the global namespace → `Pair_g`. Generic/composite names are ugly: inspect with `goose -o app.c app.goose`.
`extern fn`'s own C symbol is never mangled. **Not a stable ABI**: for `c_sources` define your own matching C structs.

Ownership rules for C [D]: must not keep a borrowed argument after the call; may write through `T&`/mutable slices; may not
write to unrelated Goose globals; builders are append-only. An unused `extern fn` needs no C implementation to link.
Thread rules [D]: C runs on whatever thread called it; `main_thread_only = true;` in the sidecar makes calls from a
`thread_fn` a compile error (gfx/ui do this). tcprouter's C must be thread-safe (pure syscalls), which is the default.

## 4. Build/run behaviour that matters [D][V]

- `goose check` never builds C. `goose run` builds the package C into a shared library and loads it (JIT); **no threads**.
  `goose build` links the package objects into the executable. First use prints `building the package X's C`.
- `--debug` changes the *program* and runtime only; **package C is always built release** [D]. The program's *own*
  `c_sources` follow `--debug` in a separate directory.
- Native parts rebuild when C sources (path/mtime/size), the sidecar, the set of extern fns, or `goose.h` change.
- Package native parts are compiled by the C compiler found by `goose toolchain` (`--cc`/`GOOSE_CC`); switching compilers builds again.
- Programs with `thread_fn` need `goose build` (TinyCC can't do thread-locals) — every tcprouter network test is `build`.
- A package's C is self-contained: it may not include or call another package's C [D]. tcpproxy → tcprouter is Goose-to-Goose.

## 5. Public-library hygiene [R]
- One `namespace tcprouter;` for every file; internal helpers can't be private (**all declarations public**) → mark them
  with a naming convention (`_`‑free but documented "internal", or put in `tcprouter.internal` files and say so).
- Keep libc bindings in one file (`sys.goose`); constants and struct layouts live next to their `extern fn`s with a comment
  citing the man page; verify layout with `bytes_of(array_of_one).len` in a unit test and with `_Static_assert` in C.
- Don't depend on `goose-kb/` from the package: it's our workspace; `exclude` it.
- Pin everything: `@v0` tag for consumers, `GOOSE` version in README, record `goose version` in CI.
- Licence file; vendored C keeps its own licence + version stamp (goose-libdeflate tests the C version from Goose).
