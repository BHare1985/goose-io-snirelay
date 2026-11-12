# Dial path profile, 2026-11-12 (T25, on hold)

Release `dial_server` (tests/net/harness), 1 worker, `wrk -t2 -c64 -d9s` against `/via/<echo port>` (every request: one dial, "hello", the echo, the reply), C echo backend.
10,563 req/s, the worker at 100% of one CPU; utime 62 vs stime 837 ticks (93% kernel); 82% of perf samples in the kernel.

**Host note:** `nft_do_chain` (5.7%), `nf_hook_slow` (1.6%) and `expr_call_ops_eval` (1.5%) are the host's own nftables rules (docker) running on loopback traffic. They skew every loopback benchmark on this host
equally; we do not tune the host. Numbers from this host are comparable with each other, not with a host without those rules.
