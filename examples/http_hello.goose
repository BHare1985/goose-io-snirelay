// A tiny HTTP/1.1 server on handler mode: every request gets "hello". Keep-alive works, and a
// request may arrive in pieces. (Plain HTTP; TLS termination is the application's business.)
//
//     goose build examples/http_hello.goose && ./examples/http_hello
//
// Your per-connection state lives in your own slot_pool. On Opened you allocate a Session and tell
// tcprouter its index with set_user; every later event carries that index back.
import tcprouter from "..";
import goose_io from "github.com/BHare1985/goose-io@bfadab427f4ac37a89d9182fbd943d0c9e0d7457";
import epoll_ext from "github.com/BHare1985/goose-io-epoll-ext@ee6e3c9f414f300e4ffe2180f16d9ebe3230233e";

import slot_pool;
import std;
import os;

struct Session { inbox: u8[..2048], live: bool }

// The response is small, so one send is enough. A response bigger than the send queue (4 buffers, 64 KB by default) must be
// sent in pieces, the next when Writable arrives: see design/02-api.md section 4 and tests/net/harness/handler_server.goose.
let RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nContent-Type: text/plain\r\n\r\nhello\n";

// One request head ends at a blank line. Answers every complete head in the buffer.
// (A function of its own: a `return` inside the serve block would leave `worker`, not the block.)
fn on_data(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&, conn: tcprouter::Conn, user: u32,
           bytes: const u8[:]) {
    // The id comes back from the engine; check it anyway before indexing.
    if user >= sessions.items.len { return; }
    var s .= sessions.items[user];
    if !s.live { return; }
    if s.inbox.len + bytes.len > s.inbox.cap {            // request head too large
        w.reset(io, conn);
        return;
    }
    s.inbox.append(bytes);
    loop {
        let end = find(s.inbox, "\r\n\r\n");
        if end < 0 { break; }
        w.send(io, conn, RESPONSE);
        let used = end + 4;
        let rest = s.inbox.len - used;
        for k in rest { s.inbox[k] = s.inbox[used + k]; }
        s.inbox.pop_n(used);
    }
}

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var sessions = slot_pool<Session> {};
    var io = epoll_ext::Loop { .. };
    var w = tcprouter::Worker { .. };
    if !w.start(io, cfg, index) { print(w.error); return; }
    io.attach(index);
    io.serve() { io, ev => w.on_event(io, ev) { w, io, e =>
        match e {
            Opened o => {
                let i = sessions.alloc_index(Session { inbox: [], live: true });
                w.set_user(io, o.conn, i as u32);
            },
            Data d => { on_data(w, io, sessions, d.conn, d.user, d.bytes); },
            Closed c => {
                if c.user < sessions.items.len {
                    sessions.items[c.user].live = false;
                    sessions.free(c.user);
                }
            },
            _ => {},
        }
    }; };
}

// `http_hello` listens on 0.0.0.0:8080; `http_hello 9000` on port 9000.
fn main() {
    var address: u8[>..] = [];
    address.append("0.0.0.0:");
    if arg_count() > 1 { arg(1, address); } else { address.append("8080"); }
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr(address) });
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Handle { tag: 1 }));
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { print(problems); exit(2); }
    epoll_ext::spawn(epoll_ext::cpu_count(), cfg, worker);
    epoll_ext::wait_for_signal_then_drain(30000);
}
