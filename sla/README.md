# sla/ — goroutine access layer over the epoch engine

Stage-2 goroutine retrofit of sa_plugin_db. The engine (Zig:
`src/epoch_runtime.zig`, `src/table.zig`, `src/db_stub.zig`) is
untouched; everything here is SLA built on the goroutine runtime
(go / Chan / select / monitor / supervise / Done).

## Files

- `db_access.sla` — the access layer library.
- `test_db_access.sla` — acceptance tests (9 tests).
- `examples/quota_service.sla` — the relay-station quota
  reference scenario (sala 15): concurrent balance checks and
  deductions against one account table.
- `bench/bench_access.sla` — same-window bench driver (see
  BENCH.md in this directory for the recorded runs).

## Shape

```
clients ──tickets──> query goroutines (one pinned snapshot each)
clients ──tickets──> inbox Chan ──> ONE writer goroutine
                                    (batch -> one tx -> one commit)
writer ──monitor──> watchdog goroutine ──Done──> all waiters
```

- **Queries** pin one epoch snapshot per query
  (`sa_db_open_read_table`) and run all of the query's ops
  through the handle face. A pin is paid once per query, never
  per op — the G3 read regression (0.53×–0.81×) came from the
  per-exec path, and this layer deliberately does not stack it:
  root-face per-op calls are forbidden in the query path. Every
  result carries the epoch it read.
- **Pin release is structural**: the outer query goroutine opens
  the pin, spawns the inner worker supervised, joins it, and
  closes the pin on every path — including inner traps. A
  trapped query fails its own receipt (`ACCESS_TRAPPED`) and
  cannot leak the pin or stall the epoch frontier (acceptance
  test: trap probe, then a commit lands and a fresh pin reads
  the new epoch).
- **Deducts** are answered by the single writer. One batch is
  one function call (`writer_cycle`): loop-body stack
  allocations do not rewind in this compiler phase, so a
  while-true writer body ratchets its fixed goroutine stack
  until it overflows (observed: stack overflow before 5,000
  sequential deducts; the per-batch call frame unwinds instead —
  same family as the slanginx accept-loop finding). The writer
  collects a batch (up to `batch_max`, waiting up to
  `batch_window_ns` for stragglers), evaluates the batch against one pinned snapshot
  with a per-batch running-balance cache (repeat deducts on one
  account see staged values), applies all surviving deducts in
  ONE engine transaction and commits once — group commit formed
  at the language layer. Every receipt carries the commit epoch
  and the post-deduct balance; a whole batch shares one epoch
  (acceptance test asserts exactly one commit for 3 tickets).
- **Writer death is service-fatal**: the watchdog monitors the
  writer; on a non-clean exit it signals the service Done
  channel and every blocked waiter wakes with
  `ACCESS_SERVICE_DEAD`. The writer is never restarted. Query
  traps, by contrast, never take the service down.
- **Cancellation** (Done channels, per sa_std/ctx.sla): the
  writer honors Done when it *starts* the batch holding the
  request — answered `ACCESS_CANCELLED`, never applied. If the
  batch already started, the request commits and the receipt
  honestly says so (no fake rollback). A waiter that abandons a
  ticket leaves its block to be reaped at `access_close`.

## API

```
access_start(root: ptr, root_len, table: ptr, table_len, opts) -> AccessHandle
access_share(&h) -> AccessHandle            // more handles, same service
access_query(&h, q) -> QueryTicket
access_query_wait_ticket(&t) -> DbResult
access_query_wait_cancellable(&t, done) -> QueryWaitOutcome { filled, res }
access_query_wait(&h, q) -> DbResult        // submit + wait
access_deduct(&h, req) -> DeductTicket
access_deduct_cancellable(&h, req, done) -> DeductTicket
access_deduct_wait_ticket(&t) -> DeductReceipt
access_deduct_wait_cancellable(&t) -> DeductWaitOutcome { filled, res }
access_deduct_wait(&h, req) -> DeductReceipt
access_stats(&h) -> AccessStats
access_close(h) -> pending_count            // 0 in a healthy service
access_close_strict(h)                      // panics if pending != 0
```

root/table are explicit (ptr, len) pairs, not `String`: in this
ABI a `String` parameter only accepts owned strings, and passing
a literal where a String struct is expected produces a malformed
value (the DEF-2 dual-representation discipline; cf. the header
note in heng's species.sla). Pass literals as `STR_PTR("..")` /
`STR_LEN("..")` evaluated in your own frame. Results are returned
BY VALUE, never written through `&out` parameters: writing
`(*out).field` through an `&Struct` parameter from inside an SLA
function segfaults on a caller stack local in the current
compiler (extern writes and heap-pointer writes through the same
address are fine; minimal repro forwarded to the compiler line).

Query kinds: `query_point` (find by u64 key column, read i64
value column), sum over an i64 column, row count, filtered scan
sum (key column >= threshold; the row loop yields every 256
rows), and a trap-probe kind used by health checks and tests.
Receipts report `ACCESS_*` statuses; on `ACCESS_ENGINE_ERROR`
the engine's status code rides in the value/balance field. The
trap probe deliberately raises a RUNTIME trap (double channel
close, trap code 4) — the kind the supervised boundary contains;
a language-level `panic()` inside a supervised goroutine is
observed to propagate past the boundary and kill the process.

Close protocol: intake stops under the ctl lock; the stop block
queues behind all submitted deducts (FIFO), so close *drains* —
the writer processes everything, commits the final partial
batch, acks, and is joined; in-flight queries are waited out on
a waitgroup; abandoned ticket blocks are reaped. Contract: wait
your tickets before closing; receipts of drained deducts stay
waitable after close because a healthy close never signals the
dead channel.

## Discipline notes (external-evaluation warnings, applied)

- Fan-in is single-channel (writer inbox; per-ticket replies),
  so select declaration-order bias cannot starve an arm. The
  only multi-arm selects are per-waiter (reply vs Done vs dead),
  where reply-first is intended priority.
- The compiler inserts no yields: CPU-dense sections chunk and
  call `sa_task_yield()` by hand (scan queries every 256 rows,
  the writer after each batch).
- sa_std globals are used nowhere in this layer; all state is
  in the control block behind the handle.
- No recursion; traversal is bounded loops.

## Build & run (box toolchain)

```
zig build                       # libdb.so (needs ../sci sibling)
SA_PLUGIN_DEV=1 sa plugin install --dev .     # db plugin
SA_PLUGIN_DEV=1 sa plugin install --dev <sla-plugin-tree>
mkdir /tmp/run && cd /tmp/run
SA_STD_DIR=<sci>/sa_std SA_PLUGIN_DEV=1 sla test <db>/sla/test_db_access.sla

Use the standalone `sla test`, not `sa sla test`: the
host-dispatched direct-SAB lowering currently rejects the
chan-recv + cast consumer shape used by this layer (and by
sa_std/executor.sla) with UnsupportedSabDirectFeature, while the
standalone runner lowers it fine — a pipeline parity gap,
forwarded to the compiler line with a minimal repro. The text
backend (`--test-backend sa`) is likewise blocked by a compiler
emitter defect: a drop marker (`!msg`) is emitted for a
chan-received pointer after a cast consumed it, and the text
verifier rejects its own emission (trap 1009, UseAfterMove);
the SAB backend is green (9/9 access tests, 3/3 executor
tests).
SA_STD_DIR=<sci>/sa_std SA_PLUGIN_DEV=1 sla build-exe <db>/sla/examples/quota_service.sla
./quota_service
```
