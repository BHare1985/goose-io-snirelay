// Messages to running workers and draining (design/02-api.md section 6, design/03-engine.md sections 7 and 8).
//
// Goose's typed queues deliver a value to ONE receiver, so a broadcast needs an address per worker: each worker owns a pipe.
// spawn() makes all of them before it starts any worker (globals set in main are copied into each worker at spawn), post()
// writes one small flat record to every pipe, and a worker reads its own from epoll, before it handles the events of the same pass.
namespace tcprouter;

import binary;
import .config;
import .engine;
import .conn;

let _MAX_WORKERS: i64 = 64;
let _MESSAGE_DRAIN: u8 = 1;
let _MESSAGE_SIZE: i64 = 16;                  // kind(1) tag(2) gen(4) value(8), padded to 16; a pipe write this small is atomic

var _message_read_fds: i32[64] = [-1; 64];    // set by spawn(); each worker finds its own by index
var _message_write_fds: i32[64] = [-1; 64];
var _worker_count: i64 = 0;
var _worker_ids: i64[64] = [0; 64];

// Sends a message to every worker; each receives it once (RT-10a). Call it from main, or from a thread started after spawn.
fn post(m: Message) {
    var raw: u8[>..] = [];
    match m {
        Drain d => { binary::write_u8(raw, _MESSAGE_DRAIN); binary::write_u16le(raw, 0); binary::write_u32le(raw, 0); binary::write_i64le(raw, d.deadline_ms); },
        _ => { return; },
    }
    while raw.len < _MESSAGE_SIZE { raw.push(0); }
    for k in _worker_count { c_pipe_write(_message_write_fds[k], raw[0], _MESSAGE_SIZE); }
}

// Blocks the calling thread until SIGTERM or SIGINT, then drains every worker with a deadline (RT-8c): listeners close at
// once, connections finish, and what is still open at the deadline is closed. Returns when every worker has ended.
// Call it from main, after spawn.
fn wait_for_signal_then_drain(deadline_ms: i64) {
    if _signal_fd >= 0 { c_signal_wait(_signal_fd); }
    post(Message.Drain { deadline_ms: deadline_ms });
    for k in _worker_count { thread_wait(_worker_ids[k]); }
}

// --- inside a worker -----------------------------------------------------------------------------------------------

// Reads every message waiting in this worker's pipe and acts on it.
fn _read_messages(w: Worker&) {
    var raw: u8[16] = [0; 16];
    while c_pipe_read(w._message_fd, raw[0], _MESSAGE_SIZE) == _MESSAGE_SIZE {
        var r = binary::reader(raw[..]);
        let kind, ok = binary::read_u8(r);
        let tag, ok2 = binary::read_u16le(r);
        let gen, ok3 = binary::read_u32le(r);
        let value, ok4 = binary::read_i64le(r);
        if !ok || !ok2 || !ok3 || !ok4 { continue; }
        if kind == _MESSAGE_DRAIN { _begin_drain(w, value); }
    }
}

// Stop taking new connections now (the kernel refuses them: nobody listens), let the open ones finish, and remember when to
// give up on them.
fn _begin_drain(w: Worker&, deadline_ms: i64) {
    if w._draining { return; }
    w._draining = true;
    w._drain_deadline_ms = w._now_ms + deadline_ms;
    for li in w.cfg.listeners.len {
        if w._listen_fds[li] >= 0 { c_close(w._listen_fds[li]); w._listen_fds[li] = -1; }
    }
}

// True when the worker's drain is over: nothing is open, or the deadline passed and what was open has been closed as Drained.
fn _drain_finished(w: Worker&) -> bool {
    if !w._draining { return false; }
    if w._stats.open > 0 && w._now_ms >= w._drain_deadline_ms {
        for i in w._connection_slots.len { _close_connection(w, i, CloseReason.Drained); }
    }
    return w._stats.open == 0;
}

// Asks every worker for its counters and adds them up: the totals of the whole program (RT-10b). Blocks until each of the
// `workers` has answered. STUB.
fn gather_stats(workers: i64) -> Stats {
    return Stats { .. };
}
