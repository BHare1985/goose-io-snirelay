// Messages to the routers beside the loops, tags, deadlines and fences (RT-6, RT-10) on goose-io (port, stage 4).
//
// A router has no pipe of its own: each worker tells main its Waker (a wake_with target) when it starts, and post() sends the
// message to every Waker as one value and a body of at most 64 bytes. Value: kind (8 bits), tag (16), gen (32). Body: the
// deadline (i64, little endian), then for SetAddr the slot and the address, for Policy the length and the bytes.
namespace tcprouter;

import std;
import binary;
import goose_io from "github.com/BHare1985/goose-io@apply-name-resolution";

let _MESSAGE_DRAIN: i64 = 1;
let _MESSAGE_DEADLINE: i64 = 2;
let _MESSAGE_CLOSE_TAGGED: i64 = 3;
let _MESSAGE_STATS: i64 = 4;
let _MESSAGE_REPLACE_DEADLINE: i64 = 5;
let _MESSAGE_SET_ADDR: i64 = 6;
let _MESSAGE_POLICY: i64 = 7;
let _NO_DEADLINE: i64 = 9223372036854775807;

var _wakers: goose_io::Waker[64] = [goose_io::Waker { .. }; 64];
var _worker_count: i64 = 0;

struct _StatsReply { worker: i64, stats: Stats }

// After the workers are spawned: collects the Waker each one reported from start(), so post() can reach them. Call it from the
// thread that spawned them, before it starts any thread that posts.
fn workers_ready(n: i64) {
    _worker_count = if n < 64 { n } else { 64 };
    for k in _worker_count {
        let r = qget<_WakerReport>();
        if r.index >= 0 && r.index < 64 { _wakers[r.index] = r.waker; }
    }
}

fn _send<Io>(io: Io&, kind: i64, tag: u16, gen: u32, until: i64, extra: const u8[:], slot: u8, with_slot: bool) {
    var raw: u8[>..] = [];
    binary::write_i64le(raw, until);
    if with_slot { raw.push(slot); }
    raw.append(extra);
    let value = kind | ((tag as i64) << 8) | ((gen as i64) << 24);
    for k in _worker_count { io.wake_with(_wakers[k], value, raw[..]); }
}

// Sends a message to every worker; each receives it once (RT-10a). `io` is any loop value of the same kind: a wake needs one
// to name the operation, not to reach a loop, so a thread with no loop of its own makes an unused one.
fn post<Io>(io: Io&, m: Message) {
    match m {
        Drain d => { _send(io, _MESSAGE_DRAIN, 0, 0, d.deadline_ms, "", 0, false); },
        Deadline d => { _send(io, _MESSAGE_DEADLINE, d.tag, 0, d.until_ms, "", 0, false); },
        CloseTagged c => { _send(io, _MESSAGE_CLOSE_TAGGED, c.tag, c.gen, 0, "", 0, false); },
        Stats r => { _send(io, _MESSAGE_STATS, r.reply_to, 0, 0, "", 0, false); },
        ReplaceDeadline d => { _send(io, _MESSAGE_REPLACE_DEADLINE, d.tag, 0, d.until_ms, "", 0, false); },
        Policy m => {
            var body: u8[>..] = [];
            body.push(m.body.len as u8);
            body.append(m.body);
            _send(io, _MESSAGE_POLICY, 0, 0, 0, body[..], 0, false);
        },
        SetAddr a => { _send(io, _MESSAGE_SET_ADDR, a.target, 0, 0, a.addr.text, a.slot, true); },
    }
}

fn _add_stats(total: Stats&, s: Stats) {
    total.accepted += s.accepted;  total.open += s.open;
    for k in 11 { total.closed[k] += s.closed[k]; }
    total.bytes_in += s.bytes_in;  total.bytes_out += s.bytes_out;
    total.connect_failures += s.connect_failures;  total.retries += s.retries;
    total.buffers_total += s.buffers_total;  total.buffers_in_use += s.buffers_in_use;  total.buffer_waits += s.buffer_waits;
    total.ready_len += s.ready_len;  total.waiting_len += s.waiting_len;
    total.batch_waits += s.batch_waits;  total.batch_wait_us += s.batch_wait_us;
    total.stale_events += s.stale_events;  total.bad_events += s.bad_events;  total.accept_failures += s.accept_failures;
    for t in s.tags {
        var found = false;
        for &mine in total.tags { if mine.tag == t.tag { mine.open += t.open; found = true; } }
        if !found && total.tags.len < total.tags.cap { total.tags.push(t); }
    }
}

// Asks every worker for its counters and adds them up (RT-10b). Blocks until each of the `workers` has answered.
fn gather_stats<Io>(io: Io&, workers: i64) -> Stats {
    post(io, Message.Stats { reply_to: 1 });
    var total = Stats { .. };
    for k in workers { _add_stats(total, qget<_StatsReply>().stats); }
    total
}

// This worker's counters. The pool and queue numbers belong to the loop: they are read from its own stats() (the loop is expected to
// have one; it is not part of the contract).
fn snapshot<Io>(w: Worker&, io: Io&) -> Stats {
    var s = w.stats;
    let l = io.stats();
    s.buffers_total = l.buffers_total;  s.buffers_in_use = l.buffers_in_use;  s.buffer_waits = l.buffer_waits;
    s.stale_events = l.stale_events;  s.bad_events = l.bad_events;  s.accept_failures = l.accept_failures;
    s.batch_waits = l.batch_waits;  s.batch_wait_us = l.batch_wait_us;  s.ready_len = l.ready_len;  s.waiting_len = l.waiting_len;
    s.tags.clear();
    for i in w.recs.entries.len {
        let e .= w.recs.entries[i];
        let live = goose_io::Link { slot: i as u32, gen: e.gen };
        if e.gen != 0 && !e.v.done && (e.v.role == _Role.Client || e.v.role == _Role.Server) {      // bytes the relay carries on links still open
            if e.v.role == _Role.Client { s.bytes_in += io.relayed_bytes(live); } else { s.bytes_out += io.relayed_bytes(live); }
        }
        if e.gen != 0 && !e.v.done && e.v.tag != 0 && e.v.role != _Role.Refused && e.v.role != _Role.Server {
            var found = false;
            for &t in s.tags { if t.tag == e.v.tag { t.open++; found = true; } }
            if !found && s.tags.len < s.tags.cap { s.tags.push(TagSessions { tag: e.v.tag, open: 1 }); }
        }
    }
    s
}

// --- inside a worker -----------------------------------------------------------------------------------------------------

fn _tag_allows<Io>(w: Worker&, io: Io&, tag: u16) -> bool {
    if tag == 0 { return true; }
    for e in w.tags { if e.tag == tag { return e.until_ms > io.now_ms(); } }
    !w.tags_full
}

// Sets the loop's write deadline on `link` to its tag's deadline, so no byte is written after it even if the router is slow (RT-6a).
fn _arm_fence<Io>(w: Worker&, io: Io&, link: goose_io::Link, tag: u16) {
    if tag == 0 { return; }
    for e in w.tags {
        if e.tag == tag {
            let r = w.recs.find(link);
            if e.until_ms > 0 && e.until_ms != _NO_DEADLINE { io.write_deadline(link, e.until_ms + 1); if r { r.armed = true; } }
            else if e.until_ms == _NO_DEADLINE { io.write_deadline(link, 0); if r { r.armed = false; } }
            return;
        }
    }
}

fn _record_tag<Io>(w: Worker&, io: Io&, tag: u16, until_ms: i64) {
    if w.tags.len < w.tags.cap { w.tags.push(_TagEntry { tag: tag, until_ms: until_ms }); return; }
    w.tags_full = true;
    w.scan_at = io.now_ms();
}

fn _rearm_tag<Io>(w: Worker&, io: Io&, tag: u16) {
    for i in w.recs.entries.len {
        let e .= w.recs.entries[i];
        if e.gen != 0 && !e.v.done && e.v.tag == tag && e.v.role != _Role.Refused {
            w._arm_fence(io, goose_io::Link { slot: i as u32, gen: e.gen }, tag);
        }
    }
    w._schedule_scan(io);
}

fn _schedule_scan<Io>(w: Worker&, io: Io&) {
    var next: i64 = 0;
    for e in w.tags { if e.until_ms > 0 && e.until_ms != _NO_DEADLINE && (next == 0 || e.until_ms < next) { next = e.until_ms; } }
    if w.tags_full { next = io.now_ms(); }
    w.scan_at = next;
    if next > 0 { io.tick_by(next); }
}

// The latest deadline wins: a later one renews; an earlier or equal one (delayed or duplicate) changes nothing.
fn _set_deadline<Io>(w: Worker&, io: Io&, tag: u16, until_ms: i64) {
    var found = false;
    for &e in w.tags { if e.tag == tag { found = true; if until_ms > e.until_ms { e.until_ms = until_ms; } } }
    if !found { w._record_tag(io, tag, until_ms); }
    w._rearm_tag(io, tag);
}

// Sets the deadline exactly, shorter or longer (RT-6f); 0 = unfenced.
fn _replace_deadline<Io>(w: Worker&, io: Io&, tag: u16, until_ms: i64) {
    let until = if until_ms == 0 { _NO_DEADLINE } else { until_ms };
    var found = false;
    for &e in w.tags { if e.tag == tag { found = true; e.until_ms = until; } }
    if !found { w._record_tag(io, tag, until); }
    w._rearm_tag(io, tag);
}

fn _fence_link<Io>(w: Worker&, io: Io&, link: goose_io::Link, r: _Rec&) {
    r._decide(CloseReason.Fenced);
    io.close(link);
}

// Closes (as Fenced) every link of `tag` whose target generation is <= gen.
fn _close_tagged<Io>(w: Worker&, io: Io&, tag: u16, gen: u32) {
    for i in w.recs.entries.len {
        let e .= w.recs.entries[i];
        if e.gen != 0 && !e.v.done && e.v.role != _Role.Refused && e.v.tag == tag && e.v.target_gen <= gen {
            w._fence_link(io, goose_io::Link { slot: i as u32, gen: e.gen }, e.v);
        }
    }
}

// When a deadline has passed: close the links of tags that no longer carry connections.
fn _enforce_deadlines<Io>(w: Worker&, io: Io&) {
    if w.scan_at == 0 || io.now_ms() < w.scan_at { return; }
    for i in w.recs.entries.len {
        let e .= w.recs.entries[i];
        if e.gen != 0 && !e.v.done && e.v.role != _Role.Refused && e.v.tag != 0 && !w._tag_allows(io, e.v.tag) {
            w._fence_link(io, goose_io::Link { slot: i as u32, gen: e.gen }, e.v);
        }
    }
    w._schedule_scan(io);
}

// SetAddr (RT-10c): empty text clears the slot; a bad target, slot or address is ignored.
fn _set_address(w: Worker&, target: u16, slot: u8, text: const u8[:]) {
    if target >= w.cfg.targets.len { return; }
    if slot >= 8 { return; }
    if text.len > 0 && !address_ok(text) { return; }
    let t .= w.cfg.targets[target as i64];
    var addr = Addr { text: [] };
    addr.text.append(text);
    if slot < t.addrs.len { t.addrs[slot] = addr; }
    else if t.addrs.len < t.addrs.cap { t.addrs.push(addr); }
}

// A Woken event: a message from post().
fn _on_woken<Io, P>(w: Worker&, io: Io&, value: i64, body: const u8[:], p: P&) {
    let kind = value & 255;
    let tag = ((value >> 8) & 65535) as u16;
    let gen = ((value >> 24) & 4294967295) as u32;
    var r = binary::reader(body);
    let until, ok = binary::read_i64le(r);
    if !ok { return; }
    let rest = body[8..];
    if kind == _MESSAGE_DRAIN { io.stop(until); }
    else if kind == _MESSAGE_DEADLINE { w._set_deadline(io, tag, until); }
    else if kind == _MESSAGE_REPLACE_DEADLINE { w._replace_deadline(io, tag, until); }
    else if kind == _MESSAGE_CLOSE_TAGGED { w._close_tagged(io, tag, gen); }
    else if kind == _MESSAGE_SET_ADDR { if rest.len >= 1 { w._set_address(tag, rest[0], rest[1..]); } }
    else if kind == _MESSAGE_POLICY {
        if w.policy_on && rest.len >= 1 {
            var n = rest[0] as i64;
            if n > rest.len - 1 { n = rest.len - 1; }
            let effect = p.on_message(rest[1..1 + n], io.now_ms());
            match effect { CloseTagged c => { w._close_tagged(io, c.tag, c.gen); }, _ => {}, }
        }
    }
    else if kind == _MESSAGE_STATS { qput(_StatsReply { worker: w.index, stats: w.snapshot(io) }); }
}
