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
let _MESSAGE_REPLACE_DEADLINE: u8 = 5;
let _MESSAGE_SET_ADDR: u8 = 6;
let _MESSAGE_POLICY: u8 = 7;                 // byte 15 = body length, bytes 16 to 63 = the body (at most 48 bytes)
// kind(1) tag(2) gen(4) value(8), then byte 15 (SetAddr: the slot) and bytes 16 to 63 (SetAddr: the address text, zero padded).
// A pipe write up to PIPE_BUF (4096 bytes on Linux) is atomic, so each worker still receives each message whole and once (RT-10a).
let _MESSAGE_SIZE: i64 = 64;
let _NO_DEADLINE: i64 = 9223372036854775807;  // ReplaceDeadline with 0: an entry that never expires, which is the same as no entry

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
        ReplaceDeadline d => { _write_message(raw, _MESSAGE_REPLACE_DEADLINE, d.tag, 0, d.until_ms); },
        Policy m => {
            _write_message(raw, _MESSAGE_POLICY, 0, 0, 0);
            raw.push(m.body.len as u8);
            raw.append(m.body);
        },
        SetAddr a => {
            _write_message(raw, _MESSAGE_SET_ADDR, a.target, 0, 0);
            raw.push(a.slot);
            raw.append(a.addr.text);
        },
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

// Blocks the calling thread until SIGTERM, SIGINT or SIGUSR1 arrives and returns its number (15, 2, 10), or -1 when no signalfd exists
// (call spawn first). The program decides what each signal means: the usual pair is `drain` on all three, or an immediate exit on
// SIGTERM and a drain on SIGUSR1 (RT-8d).
fn wait_for_signal() -> i32 {
    if _signal_fd >= 0 { c_signal_wait(_signal_fd) } else { -1 }
}

// What a worker says when it has finished: how many sessions it closed at the drain deadline (CloseReason.Drained).
struct _DrainReport { drained: i64 }

var _drain_done: bool = false;

// Drains every worker (RT-8): listeners close at once, open sessions finish, and the ones still open `deadline_ms` later are closed.
// Returns when every worker has ended, with the number of sessions closed at the deadline (0 = every session ended by itself) (RT-8e).
// Call it once, from the thread that called spawn; a second call returns 0.
fn drain(deadline_ms: i64) -> i64 {
    if _drain_done { return 0; }
    _drain_done = true;
    post(Message.Drain { deadline_ms: deadline_ms });
    for k in _worker_count { thread_wait(_worker_ids[k]); }
    var closed: i64 = 0;
    for k in _worker_count { closed += qget<_DrainReport>().drained; }     // every worker reports once, when it ends or fails to start
    closed
}

// Blocks until SIGTERM or SIGINT (or SIGUSR1), then drains every worker with a deadline (RT-8c). A thin wrapper over the two calls above.
fn wait_for_signal_then_drain(deadline_ms: i64) {
    wait_for_signal();
    drain(deadline_ms);
}

// --- inside a worker -----------------------------------------------------------------------------------------------

// Reads every message waiting in this worker's pipe and acts on it.
fn _read_messages(w: Worker&) {
    var raw: u8[64] = [0; 64];
    while c_pipe_read(w._message_fd, raw[0], _MESSAGE_SIZE) == _MESSAGE_SIZE {
        var r = binary::reader(raw[..]);
        let kind, ok = binary::read_u8(r);
        let tag, ok2 = binary::read_u16le(r);
        let gen, ok3 = binary::read_u32le(r);
        let value, ok4 = binary::read_i64le(r);
        if !ok || !ok2 || !ok3 || !ok4 { continue; }
        if kind == _MESSAGE_DRAIN { w._begin_drain(value); }
        else if kind == _MESSAGE_DEADLINE { w._set_deadline(tag, value); }
        else if kind == _MESSAGE_CLOSE_TAGGED { w._close_tagged(tag, gen); }
        else if kind == _MESSAGE_REPLACE_DEADLINE { w._replace_deadline(tag, value); }
        else if kind == _MESSAGE_POLICY { w._queue_policy_message(raw[15], raw[16..64]); }
        else if kind == _MESSAGE_SET_ADDR { w._set_address(tag, raw[15], raw[16..64]); }
        else if kind == _MESSAGE_STATS {
            // With a policy the reply is queued behind the policy messages read before it, so a gather proves they were applied (PX-5).
            if w._policy_on { w._queue_policy_stats(); } else { qput(_StatsReply { worker: w.index, stats: w.stats() }); }
        }
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
        for i in w._connection_slots.len { w._close_connection(i, CloseReason.Drained); }
    }
    w._stats.open == 0
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
    !w._tags_full
}

// Adds a tag to the deadline table. When the table is full the tag cannot be recorded, and a tag without an entry is normally
// unfenced, so dropping it would silently loosen a fence. Fail closed instead: from now on every tag without an entry is fenced
// (RT-6g), and the scan runs at once so open connections of such tags are closed too. A program that sees tags refused sizes its
// tag use below 64 per worker.
fn _record_tag(w: Worker&, tag: u16, until_ms: i64) {
    if w._tags.len < w._tags.cap { w._tags.push(_TagEntry { tag: tag, until_ms: until_ms }); return; }
    w._tags_full = true;
    w._deadline_scan_at = w._now_ms;
}

// The latest deadline wins: a later one renews, an earlier or equal one (a delayed or duplicate message) changes nothing.
fn _set_deadline(w: Worker&, tag: u16, until_ms: i64) {
    var found = false;
    for &e in w._tags {
        if e.tag == tag { found = true; if until_ms > e.until_ms { e.until_ms = until_ms; } }
    }
    if !found { w._record_tag(tag, until_ms); }
    if w._deadline_scan_at == 0 || until_ms < w._deadline_scan_at { w._deadline_scan_at = until_ms; }
}

// Sets the tag's deadline exactly, shorter or longer than the one it has (RT-6f). 0 means "unfenced": it also lifts the start
// fence, so the tag is never fenced until a later deadline says so. Use Deadline (latest wins) when messages may arrive late or
// twice; use this one when the sender is one ordered writer (a control thread writes the pipes in order) and must be able to shorten.
fn _replace_deadline(w: Worker&, tag: u16, until_ms: i64) {
    let until = if until_ms == 0 { _NO_DEADLINE } else { until_ms };
    var found = false;
    for &e in w._tags { if e.tag == tag { found = true; e.until_ms = until; } }
    if !found { w._record_tag(tag, until); }
    if w._deadline_scan_at == 0 || until < w._deadline_scan_at { w._deadline_scan_at = until; }
}

// SetAddr (RT-10c): `text` is the address padded with zeros; empty clears the slot (a cleared slot is never picked). A slot
// past the end appends. A bad target, slot or address is ignored: a message never aborts a worker.
fn _set_address(w: Worker&, target: u16, slot: u8, text: const u8[:]) {
    if target >= w.cfg.targets.len { return; }
    var n = text.len;
    while n > 0 && text[n - 1] == 0 { n--; }
    let t .= w.cfg.targets[target as i64];
    if slot >= 8 { return; }
    var addr = Addr { text: [] };
    addr.text.append(text[..n]);
    if n > 0 {
        var p = _ParsedAddress { false, [0; 16], 0 };
        if !_parse_address(addr.text, p) { return; }
    }
    if slot < t.addrs.len { t.addrs[slot] = addr; }
    else if t.addrs.len < t.addrs.cap { t.addrs.push(addr); }
}

// Closes (as Fenced) every connection of `tag` whose target generation is <= gen.
fn _close_tagged(w: Worker&, tag: u16, gen: u32) {
    for i in w._connection_slots.len {
        let s .= w._connection_slots[i];
        if s.live && s.tag == tag && s.target_gen <= gen { w._close_connection(i, CloseReason.Fenced); }
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
        if s.live && !w._tag_allows(s.tag) { w._close_connection(i, CloseReason.Fenced); }
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
    total.batch_waits += s.batch_waits;  total.batch_wait_us += s.batch_wait_us;
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
    total
}
