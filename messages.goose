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
let _MESSAGE_DEADLINE: u8 = 2;
let _MESSAGE_CLOSE_TAGGED: u8 = 3;
let _MESSAGE_STATS: u8 = 4;
let _MESSAGE_SIZE: i64 = 16;                  // kind(1) tag(2) gen(4) value(8), padded to 16; a pipe write this small is atomic

var _message_read_fds: i32[64] = [-1; 64];    // set by spawn(); each worker finds its own by index
var _message_write_fds: i32[64] = [-1; 64];
var _worker_count: i64 = 0;
var _worker_ids: i64[64] = [0; 64];

// Sends a message to every worker; each receives it once (RT-10a). Call it from main, or from a thread started after spawn.
fn post(m: Message) {
    var raw: u8[>..] = [];
    match m {
        Drain d => { _write_message(raw, _MESSAGE_DRAIN, 0, 0, d.deadline_ms); },
        Deadline d => { _write_message(raw, _MESSAGE_DEADLINE, d.tag, 0, d.until_ms); },
        CloseTagged c => { _write_message(raw, _MESSAGE_CLOSE_TAGGED, c.tag, c.gen, 0); },
        Stats r => { _write_message(raw, _MESSAGE_STATS, r.reply_to, 0, 0); },
    }
    while raw.len < _MESSAGE_SIZE { raw.push(0); }
    for k in _worker_count { c_pipe_write(_message_write_fds[k], raw[0], _MESSAGE_SIZE); }
}

fn _write_message(raw: u8[>..]&, kind: u8, tag: u16, gen: u32, value: i64) {
    binary::write_u8(raw, kind);
    binary::write_u16le(raw, tag);
    binary::write_u32le(raw, gen);
    binary::write_i64le(raw, value);
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
        else if kind == _MESSAGE_DEADLINE { _set_deadline(w, tag, value); }
        else if kind == _MESSAGE_CLOSE_TAGGED { _close_tagged(w, tag, gen); }
        else if kind == _MESSAGE_STATS { qput(_StatsReply { worker: w.index, stats: stats(w) }); }
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

// --- tags, deadlines and fences (RT-6) -----------------------------------------------------------------------------------

// A tag that has an entry may carry connections only while `until_ms` (absolute CLOCK_BOOTTIME) is in the future; 0 means fenced
// (a tag from Config.fenced_tags that has had no deadline yet). A tag with no entry, and tag 0, are never fenced.
struct _TagEntry { tag: u16, until_ms: i64 }

// Reads the clock itself instead of using the time the pass began: a worker can be stopped (SIGSTOP, a paused VM, a long
// preemption) between the start of a pass and a write, and a stale time would let those writes through after the deadline
// (RT-6a). Only tagged connections pay for the clock call.
fn _tag_allows(w: Worker&, tag: u16) -> bool {
    if tag == 0 { return true; }
    for e in w._tags { if e.tag == tag { return e.until_ms > c_boottime_ms(); } }
    return true;
}

// The latest deadline wins: a later one renews, an earlier or equal one (a delayed or duplicate message) changes nothing.
fn _set_deadline(w: Worker&, tag: u16, until_ms: i64) {
    var found = false;
    for &e in w._tags {
        if e.tag == tag { found = true; if until_ms > e.until_ms { e.until_ms = until_ms; } }
    }
    if !found && w._tags.len < w._tags.cap { w._tags.push(_TagEntry { tag: tag, until_ms: until_ms }); }
    if w._deadline_scan_at == 0 || until_ms < w._deadline_scan_at { w._deadline_scan_at = until_ms; }
}

// Closes (as Fenced) every connection of `tag` whose target generation is <= gen.
fn _close_tagged(w: Worker&, tag: u16, gen: u32) {
    for i in w._connection_slots.len {
        let s .= w._connection_slots[i];
        if s.live && s.tag == tag && s.target_gen <= gen { _close_connection(w, i, CloseReason.Fenced); }
    }
}

// Once per pass, before any event is dispatched: close the connections of tags whose deadline has passed. The scan runs only
// when some deadline has just expired (`_deadline_scan_at`), not on every pass.
fn _enforce_deadlines(w: Worker&) {
    if w._deadline_scan_at == 0 || w._now_ms < w._deadline_scan_at { return; }
    var next: i64 = 0;
    for e in w._tags {
        if e.until_ms > w._now_ms && (next == 0 || e.until_ms < next) { next = e.until_ms; }
    }
    w._deadline_scan_at = next;
    for i in w._connection_slots.len {
        let s .= w._connection_slots[i];
        if s.live && !_tag_allows(w, s.tag) { _close_connection(w, i, CloseReason.Fenced); }
    }
}

// --- stats across workers ------------------------------------------------------------------------------------------------

struct _StatsReply { worker: i64, stats: Stats }

fn _add_stats(total: Stats&, s: Stats) {
    total.accepted += s.accepted;  total.open += s.open;
    for k in 11 { total.closed[k] += s.closed[k]; }
    total.bytes_in += s.bytes_in;  total.bytes_out += s.bytes_out;
    total.connect_failures += s.connect_failures;  total.retries += s.retries;
    total.buffers_total += s.buffers_total;  total.buffers_in_use += s.buffers_in_use;  total.buffer_waits += s.buffer_waits;
    total.stale_events += s.stale_events;  total.bad_events += s.bad_events;  total.accept_failures += s.accept_failures;
    for t in s.tags {
        var found = false;
        for &mine in total.tags { if mine.tag == t.tag { mine.open += t.open; found = true; } }
        if !found && total.tags.len < total.tags.cap { total.tags.push(t); }
    }
}

// Asks every worker for its counters and adds them up: the totals of the whole program (RT-10b). Blocks until each of the
// `workers` has answered. One caller at a time: the replies share one queue.
fn gather_stats(workers: i64) -> Stats {
    post(Message.Stats { reply_to: 1 });
    var total = Stats { .. };
    for k in workers { _add_stats(total, qget<_StatsReply>().stats); }
    return total;
}
