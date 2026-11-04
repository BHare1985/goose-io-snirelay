# Goose Quick Reference  ([V] = compiled here, [D] = upstream docs)

## Commands
```bash
goose check f.goose              # parse+typecheck only; --stats --bce-lines --specs --stacks --no-bce
goose build f.goose              # real C compiler, optimized (-O2 default); --debug adds overflow/range/tag checks
goose run f.goose -- args        # in-process TinyCC; NO threads, NO benchmarking
goose -o f.c f.goose             # emit C;  goose build --dry-run prints the commands
goose format f.goose
```
Local wrapper: `goose-kb/bin/goose` (sets `GOOSE_STDLIB`). Sidecar `f.build` next to `f.goose`: `c_sources`, `c_headers`, `c_libs`, `dylibs_linux`.

## Syntax
```goose
import std; import os; import slot_pool;          // modules by name; std is NOT implicit for find/split/parse_int
let a = 1; var b: i32 = 0; const t = [1,2,3];      // let: no rebind; const: read-only contents
fn f(x: i64, y = 2) -> i64, bool { return x, true; }     // multiple results = calling convention, no tuples
let v, ok = f(1);   v, ok = f(2);
if c { } else { }   let k = match n { 0 => "z", 1..5 => "low", _ => "hi" };   // expressions
guard cond else { return; }     defer cleanup();       // defer runs at block end/return/break [V]
for i in 10 {}  for i in 2..9 {}  for x in xs {}  for &x in xs { x *= 2; }  for x, i in xs {}
while c {}  loop { break; }
struct P { x: i32, y: i32 = 5, name: u8[..16] }   P { 1, 2, "a" }  P { x: 1, .. }
enum E { A { v: i64 }, B, }    E.A { v: 1 }     // fixed mode `E`, variable mode `E..`
xs.push(v) -> T&   xs.append(src)   xs.pop()   xs.len   xs.cap   copy(x)   str(a,b)  format(out,a,b)  print(a,b)
```

## Arrays
| `T[4]` fixed | `T[]` frozen | `T[..16]` inline cap, fixed-size | `T[>..]` grow-only (default) | `T[>..<]` grow-shrink | `T[:]` view |
Only `[>..]`/`[>..<]` are resizable (one live per data stack). Variable-size elements ⇒ iterate only, no indexing.

## References
`let r .= xs[0];` bind  `r .= other;` rebind  `a .== b` identity  `T?` nullable (narrow with `if`/`guard`/`assert`)
`T&<u32>` self-relative link (same array)  `T&<u32 in pool>` pool-relative (global array)  `self` for sentinels.

## Errors
```goose
fn load() -> X, u8[] { ...; return x, ""; }     // callee anywhere below:  return [], str("bad ", n) from load;
exception::try<u8[]>(body) { e => print(e); };  assert(c);  abort("msg");  exit(1);
```

## Pools
`var p = slot_pool<T> {};` `p.alloc_index(v)->i64` `p.alloc_ref(v)->T&` `p.alloc_with() { T{..} }` `p.free(i)` `p.items`
`slice_pool<T>`: `alloc_slice(n)` `realloc_slice(s,n)` `free_slice(s)`. (`reusable` is deprecated.) [D]; slot_pool [V t04]

## Generics / HOF
`fn twice(x) { x + x }`  `fn f<T>(a: T, b: T) -> T`  `xs.filter() { it > 0 }`  `fold(xs, 0) { acc, x => acc + x }`
`recursive fn` required for recursion; recursive fns can't hold growable locals across the recursive call.

## Threads  (goose build only)
```goose
thread_fn worker(id: i64) { loop { let j = qget<Job>(); ... qput(Res{..}); } }
let id = thread_spawn(worker, 1);  thread_wait(id);  qlimit<Job>(64);  qput(v)->bool(false if full)
qget<T>(ms)->T,bool   qpoll<T>()->T,bool   hardware_threads()   thread_spawn_contained(w, ..)
```
Only flat values (no refs/slices) cross; globals are copied per worker.

## C interop
```goose
extern fn name(a: i32, p: Foo&, s: const u8[:], out: u8[>..]&) -> i32 = "c_symbol";
extern "c" { fn getpid() -> i32; }      // + sidecar  dylibs_linux = ["c=libc.so.6"];
export fn f(a: i32) -> i32 { a }        // goose --standalone --header f.h -o f.c f.goose
```
Crossable: scalars, flat fixed structs/arrays, `T&`, `T[:]`, `T[>..]&`. Not: variadics, callbacks, NULL, returns of refs.

## Gotchas (all hit or documented)
- `u32 + i32` is a compile error; use `as`. Literals adapt. `%` Euclidean; `/` truncates.
- `let y = x;` for a non-fixed value *binds*, doesn't copy; `copy(x)` for a real copy.
- `os::arg(i, out)` returns void. `find`, `trim`, `split`, `parse_int` need `import std;` [V: `unknown function: split` without it, even though many reference examples omit the import].
- No `sizeof`: `bytes_of(array_of_one).len` [V].
- Optionals must be narrowed before use. [D]
