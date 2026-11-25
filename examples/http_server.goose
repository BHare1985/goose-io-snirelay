// An HTTP/1.1 server on tcprouter's handler mode, written to be benchmarked and to be read: the same behaviour as the C
// backend the proxy benchmarks use (bench/backend.c), so the two can be compared on the same wrk lines.
//
//     goose build examples/http_server.goose && ./examples/http_server [--port 8080] [--workers N] [--root DIR]
//
//   GET /        11 bytes (the same pattern as /11)
//   GET /N       200 with an N-byte body, body[i] = i % 251 (a client can check every byte), N up to 64 MiB
//   GET /path    the file ROOT/path, when --root is given (the tree is read into memory at startup)
//   HEAD         the same headers, no body.   Any other method: 405.   Unknown path: 404.
//   Keep-alive is the default; "Connection: close" (or HTTP/1.0 without keep-alive) answers and closes.
//   Requests may arrive in pieces and may be pipelined; a request body (Content-Length) is read and ignored.
//   A head over 4 KiB gets 431 and a close; garbage gets 400 and a close.
//
// How it is built (this is the pattern for your own server):
//  * One Session per connection in a slot_pool you own. Opened allocates it and set_user stores its index in the
//    connection; every later event carries that index back, and Closed frees it.
//  * A response is generated, not stored: each piece is built from the session's offsets and sent with send(), which is all
//    or nothing. When send() says false (the queue of 4 buffers is full) the session just stops; the engine sends Writable
//    when there is room and the same function continues from the same offsets. Nothing is copied to "retry".
//  * The block you pass to serve only calls named functions: a `return` inside it would leave the worker.
import tcprouter from "..";
import goose_io from "github.com/BHare1985/goose-io@apply-name-resolution";
import epoll_ext from "github.com/BHare1985/goose-io-epoll-ext@main";

import slot_pool;
import std;
import os;

let MAX_HEAD = 4096;
let CHUNK = 32768;                  // bytes of body per send() (the engine's buffer size)
let MAX_BODY = 67108864;            // 64 MiB, as bench/backend.c
let PERIOD = 251;                   // body[i] = i % 251

struct Session {
    live: bool,
    inbox: u8[..4096],              // the start of the next request, until its head is complete
    skip: i64,                      // bytes of a request body still to be discarded
    busy: bool,                     // a response is still being sent
    head: u8[..512],                // the response head, until it has been sent
    head_sent: bool,
    close_after: bool,              // close once this response is out
    file: i64,                      // index into the file table, or -1 for a generated body
    offset: i64,                    // body bytes sent
    total: i64,                     // body bytes to send
}

// Files served from --root, read into memory at startup. Globals are copied to every worker when it starts.
struct FileEntry { path: u8[..160], at: i64, len: i64, kind: u8 }      // kind: 0 octet-stream, 1 html, 2 text, 3 css, 4 js, 5 json
var FILES: FileEntry[>..] = [];
var FILE_BYTES: u8[>..] = [];

fn content_type(kind: u8) -> u8[:] {
    match kind {
        1 => "text/html; charset=utf-8",
        2 => "text/plain",
        3 => "text/css",
        4 => "application/javascript",
        5 => "application/json",
        _ => "application/octet-stream",
    }
}

fn kind_of(path: const u8[:]) -> u8 {
    if path.ends_with(".html") { 1 } else if path.ends_with(".txt") { 2 } else if path.ends_with(".css") { 3 }
    else if path.ends_with(".js") { 4 } else if path.ends_with(".json") { 5 } else { 0 }
}

// --- reading the request ------------------------------------------------------------------------------------

struct Request { method: u8, target: const u8[:], close: bool, body: i64, ok: bool }      // method: 1 GET, 2 HEAD, 0 other

// Reads the head in `head` (without the blank line). `ok` is false for a request line that is not "METHOD target HTTP/1.x".
fn parse_head(head: const u8[:]) -> Request {
    var r = Request { method: 0, target: head[..0], close: false, body: 0, ok: false };
    let eol = find(head, "\r\n");
    let line = if eol < 0 { head } else { head[..eol] };
    let sp1 = find(line, " ");
    if sp1 < 1 { return r; }
    let rest = line[sp1 + 1..];
    let sp2 = find(rest, " ");
    if sp2 < 1 { return r; }
    let version = rest[sp2 + 1..];
    if version != "HTTP/1.1" && version != "HTTP/1.0" { return r; }
    r.ok = true;
    let method = line[..sp1];
    r.method = if method == "GET" { 1 } else if method == "HEAD" { 2 } else { 0 };
    r.target = rest[..sp2];
    // The header lines, lower-cased once so that names and values compare without regard to case.
    var lower: u8[>..] = [];
    if eol >= 0 { lower.append(head[eol..]); }
    to_lower(lower);
    r.close = if version == "HTTP/1.0" { find(lower, "\r\nconnection: keep-alive") < 0 } else { find(lower, "\r\nconnection: close") >= 0 };
    let cl = find(lower, "\r\ncontent-length:");
    if cl >= 0 {
        let from = cl + 17;
        let end = from + find(lower[from..], "\r\n");
        let n, good = parse_int(trim(lower[from..if end < from { lower.len } else { end }]));
        if good && n > 0 { r.body = n; }
    }
    return r;
}

// "/1234" is 1234; anything else is -1.
fn body_length(target: const u8[:]) -> i64 {
    if target.len < 2 || target.len > 10 || target[0] != '/' { return -1; }
    let n, good = parse_int(target[1..]);
    if good && n >= 0 && n <= MAX_BODY { n } else { -1 }
}

fn find_file(target: const u8[:]) -> i64 {
    for i in FILES.len { if FILES[i].path == target { return i; } }
    -1
}

// --- sending the response ------------------------------------------------------------------------------------

fn begin_response(s: Session&, status: const u8[:], ctype: const u8[:], total: i64, file: i64, head_only: bool, close: bool) {
    s.head.clear();
    format(s.head, "HTTP/1.1 ", status, "\r\nContent-Length: ", total, "\r\nContent-Type: ", ctype, "\r\n",
           if close { "Connection: close\r\n" } else { "" }, "\r\n");
    s.head_sent = false;
    s.file = file;
    s.offset = 0;
    s.total = if head_only { 0 } else { total };
    s.close_after = close;
    s.busy = true;
}

// Sends the response in pieces; stops when send() refuses (nothing of that piece was queued) and Writable continues.
// The head and the first CHUNK - head bytes of the body go out in one send (one system call for any response that fits); the
// rest follows in windows of CHUNK bytes sent straight from the pattern or the file, so `send`'s copy into its queue is the only one.
fn send_pieces(w: tcprouter::Worker&, io: epoll_ext::Loop&, s: Session&, conn: tcprouter::Conn, pattern: const u8[:]) {
    while s.busy {
        var want = 0;
        var queued = false;
        if !s.head_sent {
            var piece: u8[>..] = [];                                // built in a growable array: not zero-filled first
            piece.append(s.head[..]);
            want = if s.total - s.offset < CHUNK - s.head.len { s.total - s.offset } else { CHUNK - s.head.len };
            if s.file >= 0 {
                piece.append(FILE_BYTES[FILES[s.file].at + s.offset..FILES[s.file].at + s.offset + want]);
            } else {
                piece.append(pattern[s.offset % PERIOD..s.offset % PERIOD + want]);
            }
            queued = w.send(io, conn, piece);
        } else {
            want = if s.total - s.offset < CHUNK { s.total - s.offset } else { CHUNK };
            if s.file >= 0 {
                queued = w.send(io, conn, FILE_BYTES[FILES[s.file].at + s.offset..FILES[s.file].at + s.offset + want]);
            } else {
                let start = s.offset % PERIOD;                      // the pattern repeats every 251 bytes
                queued = w.send(io, conn, pattern[start..start + want]);
            }
        }
        if !queued { return; }                                      // nothing of that piece was queued: the same piece on Writable
        s.head_sent = true;
        s.offset += want;
        if s.offset >= s.total {
            s.busy = false;
            if s.close_after { w.close(io, conn); }
        }
    }
}

fn answer(s: Session&, r: Request) {
    let head_only = r.method == 2;
    if r.method == 0 { begin_response(s, "405 Method Not Allowed", "text/plain", 0, -1, true, r.close); return; }
    if r.target == "/" { begin_response(s, "200 OK", "application/octet-stream", 11, -1, head_only, r.close); return; }
    let n = body_length(r.target);
    if n >= 0 { begin_response(s, "200 OK", "application/octet-stream", n, -1, head_only, r.close); return; }
    let f = find_file(r.target);
    if f >= 0 { begin_response(s, "200 OK", content_type(FILES[f].kind), FILES[f].len, f, head_only, r.close); return; }
    begin_response(s, "404 Not Found", "text/plain", 0, -1, true, r.close);
}

// Removes the first n bytes of the inbox.
fn consume(s: Session&, n: i64) {
    let rest = s.inbox.len - n;
    for k in rest { s.inbox[k] = s.inbox[n + k]; }
    s.inbox.pop_n(n);
}

// Takes complete requests out of the inbox, one at a time, for as long as the previous response is out.
fn process(w: tcprouter::Worker&, io: epoll_ext::Loop&, s: Session&, conn: tcprouter::Conn, pattern: const u8[:]) {
    loop {
        if s.busy { send_pieces(w, io, s, conn, pattern); if s.busy { return; } }
        if s.skip > 0 {                                             // discard a request body that is still arriving
            let drop = if s.skip < s.inbox.len { s.skip } else { s.inbox.len };
            s.consume(drop);
            s.skip -= drop;
            if s.skip > 0 { return; }
        }
        let end = find(s.inbox, "\r\n\r\n");
        if end < 0 {
            if s.inbox.len >= MAX_HEAD {                            // no end of head within the limit
                begin_response(s, "431 Request Header Fields Too Large", "text/plain", 0, -1, true, true);
                s.inbox.clear();
                send_pieces(w, io, s, conn, pattern);
            }
            return;
        }
        let r = parse_head(s.inbox[..end]);                         // r.target points into the inbox: answer before consuming it
        if !r.ok {
            begin_response(s, "400 Bad Request", "text/plain", 0, -1, true, true);
            s.inbox.clear();
            send_pieces(w, io, s, conn, pattern);
            return;
        }
        s.skip = r.body;
        s.answer(r);                                                // sets the session up to send; the loop's next turn sends
        s.consume(end + 4);
    }
}

fn on_data(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&, pattern: const u8[:], conn: tcprouter::Conn, user: u32,
           bytes: const u8[:]) {
    if user >= sessions.items.len { return; }                       // the id comes back from the engine; check it anyway
    let s .= sessions.items[user];
    if !s.live || s.close_after { return; }
    if s.inbox.len + bytes.len > s.inbox.cap {
        // More than fits: take what fits (the head may complete), and let process() decide; a flood is cut by 431.
        let room = s.inbox.cap - s.inbox.len;
        s.inbox.append(bytes[..room]);
    } else {
        s.inbox.append(bytes);
    }
    process(w, io, s, conn, pattern);
}

fn on_writable(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&, pattern: const u8[:], conn: tcprouter::Conn, user: u32) {
    if user >= sessions.items.len { return; }
    let s .= sessions.items[user];
    if s.live { process(w, io, s, conn, pattern); }
}

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var sessions = slot_pool<Session> {};
    var pattern: u8[>..] = [];
    for i in PERIOD * 140 { pattern.push((i % PERIOD) as! u8); }    // a long enough run that any CHUNK window is a slice of it
    var io = epoll_ext::Loop { .. };
    var w = tcprouter::Worker { .. };
    if !w.start(io, cfg, index) { print(w.error); return; }
    io.attach(index);
    io.serve() { io, ev => w.on_event(io, ev) { w, io, e =>
        match e {
            Opened o => {
                let i = sessions.alloc_index(Session { live: true, inbox: [], skip: 0, busy: false, head: [], head_sent: false,
                                                       close_after: false, file: -1, offset: 0, total: 0 });
                w.set_user(io, o.conn, i as u32);
            },
            Data d => { on_data(w, io, sessions, pattern, d.conn, d.user, d.bytes); },
            Writable x => { on_writable(w, io, sessions, pattern, x.conn, x.user); },
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

// --- startup ---------------------------------------------------------------------------------------------------

fn die(message: const u8[:]) {
    write_stderr(str("http_server: ", message, "\n"));
    exit(2);
}

// Reads every file below `root` into FILES / FILE_BYTES under the path it will be requested by ("/dir/name"). The directories
// still to read are a list, not recursion: a function in a recursive cycle may not hold growable data across the call.
fn load_tree(root: const u8[:]) {
    var todo: u8[>..] = [];                             // directory paths relative to root, one per line; "" is the root itself
    todo.append("\n");
    var done = 0;
    while done < todo.len {
        let nl = done + find(todo[done..], "\n");
        let dir = todo[done..nl];
        done = nl + 1;
        var names: u8[>..] = [];
        if !list_dir(str(root, dir), names) { continue; }
        each_split(names, '\n') {
            if it.len > 0 {
                let path = str(dir, "/", it);
                if is_dir(str(root, path)) {
                    todo.append(path);
                    todo.push('\n');
                } else if path.len <= 160 {
                    let at = FILE_BYTES.len;
                    if read_file(str(root, path), FILE_BYTES) {
                        FILES.push(FileEntry { path: path, at: at, len: FILE_BYTES.len - at, kind: kind_of(path) });
                    }
                }
            }
        };
    }
}

fn main() {
    let a = args();
    var port = "8080";
    var workers = epoll_ext::cpu_count();
    var root = "";
    var i = 1;
    while i < a.len {
        if i + 1 >= a.len { die(str(a[i], " needs a value")); }
        if a[i] == "--port" { port = a[i + 1]; }
        else if a[i] == "--workers" { let n, good = parse_int(a[i + 1]); if !good || n < 1 { die("--workers needs a positive number"); } workers = n; }
        else if a[i] == "--root" { root = a[i + 1]; }
        else { die(str("unknown flag ", a[i])); }
        i += 2;
    }
    if root.len > 0 { load_tree(root); }

    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr(str("0.0.0.0:", port)) });
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Handle { tag: 1 }));
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { write_stderr(problems); exit(2); }
    epoll_ext::spawn(workers, cfg, worker);
    epoll_ext::wait_for_signal_then_drain(30000);
}
