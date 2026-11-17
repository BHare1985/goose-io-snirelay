# Retry when the server ends before its first byte

Status: design, gate proof in `gates/early_close_peek/` (row RT-21, added with the red tests).

## The problem

A server that is stopping can keep its listening socket for a moment: the connect succeeds, the server reads the ClientHello, then closes
or resets without a byte. tcprouter has already sent the hello on (the bytes were peeked for routing, then consumed by the forward), so there
is nothing to resend and the client sees a failed connection.

## Mechanism (proved in `gates/early_close_peek/peek_resend_test.py`)

On a listener with `inspect: Sni`, a forwarded connection keeps the hello in the client's socket until the server's first byte:

1. When the connect finishes, `MSG_PEEK` the client's queued bytes (the hello) and `send` them to the server. Nothing is consumed. The
   upward pump does not read the client until step 3 (a TLS client waits for the server's hello, so nothing more arrives).
2. If the server ends first (read gives 0 or an error, or the socket reports an error) the connection goes back to the connecting
   state exactly as a failed connect does, and the same bytes are sent to the next address.
3. When the server's first byte arrives, `recv` (no peek) the hello bytes from the client to drop them, mark the client readable and carry
   on as today. No extra buffer: the kernel holds the hello.

If the first `send` is partial, the sent bytes are consumed and the pump carries on (no retry for that connection): correct, and rare
(a fresh socket takes a 16 KB hello).

Not done on listeners without `inspect: Sni`, and never after the server's first byte.

## API (task 1.2): no change

An early end is reported to the policy as a failed connect: `connect_failed(conn, slot, tag, tried, now_ms) -> Retry`, with `Retry.Next` or
`Retry.GiveUp`, which every policy already has. Without a policy the built-in rotation moves to the next address and counts a retry. If the
policy was told `connected`, the engine first queues its `closed` hook, so a policy counting connections stays right. `tried` already holds
the slots used, so the retry never repeats a server. No new type, hook or option: a public API change would need the user's yes, and this is not one.

The tag (v0.6.1 or v0.7.0) is the user's decision. Behaviour changes for SNI listeners, the API does not.

## First version: close and reset only

A server that accepts and stays silent is not retried here (that needs a timeout option, and a slow healthy server would be retried
without need). Health checks keep that case.
