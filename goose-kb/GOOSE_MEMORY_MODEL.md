# Goose Memory Model (from tutorial/reference; internals [?] not studied)

## Regions
```
native stack      fixed-size locals, registers, call frames, fixed arrays like u8[16384]   [V: t02 relay buf]
static data       string literals, const globals with constant initialisers
data stack 0..N-1 bump-pointer regions (2 GB address reservation each by default)
                  hold every variable-size / resizable value; N computed by the compiler (--stacks)
```
`goose build --stacks` on t02: main = 2 data stacks + 1 global stack; each worker = 2 data stacks. [V]

## Scope exit = one store
```
before block:   stack top ─►│ ····
inside block:   │ scratch (u8[>..], grows by bumping) ──►top
after block:    top reset to "before"; nothing walked, no destructors
```
Rule 1: values pushed in lifetime order, freed together. Rule 2: ≤1 resizable per stack, topmost, so it
never moves ⇒ references into it stay valid. [D]

## Layouts [D]
```
u8[][>..] ["a","bcd"]:  [len=2][1 'a'][3 'b' 'c' 'd']        one block, no pointers
Order{id:varint, customer:u8[varint], items:Item[varint]}:   29 bytes for a sample order, 0 allocations
Node{key:i32,count:i32,left:&<u32>?,right:&<u32>?}:           16 bytes, links = 4-byte offsets in same array
Shape fixed: [tag][max payload]  (17 B)     Shape.. variable: [tag][own payload] (1/9/17 B)
```
Structs are packed, no padding ⇒ maps onto C wire/ABI structs (sockaddr_in, pollfd, packed epoll_event). [V]

## Which array
| need | use |
|---|---|
| builder, arena, tree storage, scratch | `T[>..]` |
| stack/queue/heap | `T[>..<]` (refs only in variables; invalid after shrink) |
| inline in a struct/element (name, small list, conn buffer) | `T[..N]` |
| finished data in a record | `T[]` / `T[varint]` |
| fixed shape / I/O scratch | `T[N]` |
| parameter taking any of the above | `T[:]` |

## References
- Root = the variable that bounds the target's lifetime; inferred, functions specialised per root. A reference
  can't outlive its root or be stored somewhere that outlives it; a slice can't survive a `clear/pop/resize`
  that it overlaps (liveness-based: last use before the clear is fine). [D]
- Self-relative `T&<u32>`: offset from the field, same array, position-independent, not copyable once stored
  (build in place with `push`). Pool-relative `T&<u32 in pool>`: from a global array's base, copyable, other
  arrays can hold them. [D]

## Non-nested lifetimes: pools
`slot_pool<T>`: `items` array + freelist. `free(i)` releases nothing; slot stays a valid `T`. Stale index ⇒ logic
bug, never memory unsafety. Verified reuse of a freed slot and index validation in t04. [V]

## Threads
Each `thread_fn` = separate program: own data stacks, copied globals, only flat values via typed queues. [D][V]
