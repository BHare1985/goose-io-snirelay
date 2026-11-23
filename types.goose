// The router's public types: connections, events, stats, messages and the policy hooks (design/02-api.md).
namespace tcprouter;

import .config;

// --- connections and events ---------------------------------------------------------------------

// A handle to one connection. Valid until its Closed event; a stale handle is ignored, never
// reaches the connection that now uses the slot (RT-2b).
struct Conn { slot: u32, gen: u32 }

enum CloseReason {
    PeerClosed, PeerReset, IdleTimeout, HalfCloseTimeout, InspectTimeout, ConnectFailed,
    Fenced, Drained, ByHandler, Error,
    InvalidHello,       // the first bytes were a TLS handshake that breaks the format or exceeds 16 KB (RT-3f)
}

// What your serve block is called with. Read it with `match`.
enum Event {
    // A connection routed to Action.Handle(tag). `user` is 0 until you set_user.
    Opened { conn: Conn, tag: u16, listener: u16, sni: u8[..253] },
    // Bytes from the peer. `bytes` is a view into the engine's buffer: valid only inside this call.
    Data { conn: Conn, user: u32, bytes: const u8[:] },
    // Your earlier sends have drained below the low-water mark; send again.
    Writable { conn: Conn, user: u32 },
    // The peer finished sending (EOF); only for a connection that called set_keep_open_on_eof. You can still send; call shutdown_write or close when done.
    PeerEof { conn: Conn, user: u32 },
    // Only after w.want_pass_end(true): the end of a pass that delivered at least one handler event (Opened, Data, Writable, PeerEof, Closed); once per pass, after the last of them. Never on an idle pass, never for a Tick or a posted message alone.
    PassEnd { },
    // Always the last event of a connection, exactly once.
    Closed { conn: Conn, user: u32, why: CloseReason },
    // At least every 100 ms while the worker runs: your timers.
    Tick { now_ms: i64 },
}

// --- stats ---------------------------------------------------------------------------------------

// A snapshot of one worker's counters (design/03-engine.md section 9). Flat. Read it on the worker's
// own thread, for example from a Tick event; nothing is shared between workers, so there is no lock.
// (Sessions per tag arrive with tags in M4.)
struct TagSessions { tag: u16, open: i64 }

struct Stats {
    accepted: i64,            // connections accepted
    open: i64,                // connections open now
    closed: i64[11],          // connections closed, by CloseReason in declaration order
    bytes_in: i64,            // client to server, forwarded
    bytes_out: i64,           // server to client, forwarded
    connect_failures: i64,    // outgoing connects that failed
    retries: i64,             // of those, the ones retried on another address
    buffers_total: i64,       // buffers in this worker's pool
    buffers_in_use: i64,      // buffers borrowed right now
    buffer_waits: i64,        // times a read had to wait for a free buffer
    stale_events: i64,        // events for a connection that was already closed and its slot reused (RT-2b)
    bad_events: i64,          // events whose slot index or kind was out of range (RT-2c)
    accept_failures: i64,     // accepts that failed for lack of a resource; the listener rests briefly (RT-1e)
    batch_waits: i64,         // batching windows entered (RT-16): 0 unless Limits.batch_min_events and batch_max_wait_us are both set
    batch_wait_us: i64,       // microseconds slept in them
    ready_len: i64,           // entries in the engine's list of connections with bytes left to move (a gauge: stays small under any load, RT-18a)
    waiting_len: i64,         // entries in its list of reads waiting for a pool buffer (a gauge, RT-18b)
    tags: TagSessions[..64],  // connections open now under each tag (sessions per tag)
}


enum Message {
    Drain { deadline_ms: i64 },
    Deadline { tag: u16, until_ms: i64 },     // tag may forward until this CLOCK_BOOTTIME millisecond; the latest deadline wins
    CloseTagged { tag: u16, gen: u32 },       // close every connection of the tag whose target generation is <= gen
    Stats { reply_to: u16 },
    ReplaceDeadline { tag: u16, until_ms: i64 },   // sets the tag's deadline exactly (shorter or longer); 0 = unfenced (RT-6f)
    Policy { body: u8[..48] },                     // handed untouched to the worker's policy: on_message (RT-13g)
    SetAddr { target: u16, slot: u8, addr: Addr }, // sets address `slot` of Config.targets[target] on every worker; empty addr clears it (RT-10c)
}

enum Pick {
    To { addr: Addr, tag: u16, gen: u32, slot: u8, connect_ms: i64 },   // connect to addr; the connection's tag and target generation are these; connect_ms is this connect's timeout (0 = Limits.connect_timeout_ms)
    None,                                              // nowhere: close the client
}

enum Retry { Next, GiveUp }

// What a policy asks the engine to do after a message. The engine performs it on this worker only (nothing is re-broadcast: every
// worker got the same message and its policy decides the same way).
enum Effect {
    None,
    CloseTagged { tag: u16, gen: u32 },      // close every connection of the tag whose target generation is <= gen (as Message.CloseTagged)
}
