// t04: a connection registry with slot_pool: per-connection state with fixed-size inline buffers,
// freed in any order (lifetimes don't nest) and addressed by a u32 index that fits in epoll's data field.
//   goose build t04_conn_registry.goose && ./t04_conn_registry
import slot_pool;

struct ConnState {
    fd: i32,
    peer: i32,                 // slot index of the paired connection, -1 if none
    out: u8[..256],            // pending bytes to write: a limited array, inline, fixed size
    live: bool,
}

var conns = slot_pool<ConnState> {};

fn open_conn(fd: i32, peer: i32) -> i64 {
    return conns.alloc_index(ConnState { fd: fd, peer: peer, out: [], live: true });
}

// Untrusted index (e.g. from epoll data): validate before use, never assume.
fn lookup(i: u64) -> ConnState? {
    if i >= conns.items.len as u64 { return null; }
    let c .= conns.items[i as i64];
    if !c.live { return null; }
    return c;
}

fn close_conn(i: i64) {
    conns.items[i].live = false;
    conns.items[i].out.clear();
    conns.free(i);
}

fn main() {
    let a = open_conn(10, -1);
    let b = open_conn(11, a as i32);
    let c = open_conn(12, -1);
    conns.items[a].peer = b as i32;
    print("slots ", a, " ", b, " ", c, " len ", conns.items.len);

    close_conn(b);
    let d = open_conn(13, -1);      // reuses b's slot
    print("reused slot: ", d == b, "  len still ", conns.items.len);

    let x = lookup(a as u64);
    if x { x.out.append("queued"); print("a.out = ", x.out, " fd=", x.fd); }
    let bad = lookup(999);
    print("hostile index 999 -> ", bad == null);
    let stale = lookup(c as u64);
    close_conn(c);
    print("freed slot looked up -> ", lookup(c as u64) == null);
}
