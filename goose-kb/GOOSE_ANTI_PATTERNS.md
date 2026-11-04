# Goose Anti-Patterns

| # | Anti-pattern (from C/C++/Rust/Go/Zig habits) | Why wrong | Goose way | Source |
|---|---|---|---|---|
| 1 | `malloc`-style: looking for a heap/`Box` | none exists | variable in owning scope; `push` returns a ref | D |
| 2 | Vec<Struct{String,Vec}> mindset, pointer per field | Goose nests inline; indirection is waste | `Order{customer:u8[varint], items:Item[varint]}` | D |
| 3 | Index everywhere "because vectors move" | arrays never move; indices lose type safety | hold `T&` via `.=`; use `&<u32>` links when stored | D |
| 4 | `let b = a;` expecting a copy of an array | non-fixed values bind by reference | `copy(a)` | D |
| 5 | `u32 + i32`, `x as i64` everywhere | compile error / redundant cast warning | match widths; cast only where it decides | D |
| 6 | `if n {` / `-1` sentinels | no int→bool; sentinels hide errors | `T?`, trailing `bool` | D |
| 7 | Result/`?` threaded through every frame | not needed | `return E from f` | D |
| 8 | Closures stored in structs / callbacks | function values are compile-time only | pass blocks to generic fns; ADT tag dispatch | D |
| 9 | Recursive parser holding `u8[>..]` locals across recursion | rejected | pass the pool in; owner outside the cycle | D |
| 10 | Shared counters/maps between threads | worker globals are copies | messages over typed queues | D, V |
| 11 | Thread per connection at large scale | 2×2 GB reserved per worker, cap ~8k | worker pool + epoll | V |
| 12 | `fcntl(fd, F_SETFL, O_NONBLOCK)` | variadic C not bindable | `SOCK_NONBLOCK` in socket/accept4 flags | D, V |
| 13 | Passing NULL to `accept(fd, NULL, NULL)` | `T&` can't be null | pass real storage | V |
| 14 | `signal(SIGPIPE, SIG_IGN)` | function pointers not bindable | `MSG_NOSIGNAL` on `send` | V |
| 15 | `reusable` pools | deprecated | `slot_pool` / `slice_pool` | D |
| 16 | `assert` added only to delete a bounds check | must be a real invariant | restructure so length is provable | D |
| 17 | Trusting epoll `data` / wire length as an index | OOB aborts the process | validate; `lookup()` returning `T?` (t04) | V |
| 18 | `goose run` for benchmarks or threaded code | TinyCC, no TLS | `goose build` | D, V |
| 19 | Mutating a sentinel in the array you also read state from | my own bug | separate immutable copy | V |
| 20 | Reading the translation guide as authoritative | it says "no defer"; `defer` exists | check compiler | V |
| 21 | Relying on doc examples without `import std;` | examples elide imports | add `import std;` | V |
