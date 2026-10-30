# BENCH — access layer, same-window record

Window: 2026-10-30 afternoon (Asia/Shanghai), Colab box
`1ab1452dc2e8`, toolchain sla master `6004af4` / sci `e7c18568`,
db plugin built from this tree (base `c02b4ec`) ReleaseFast. The
box was shared with other stage-2 lines during the window (load
fluctuated ~1–5), so treat these as same-session figures under
contention, not isolated peaks.

## Access layer (bench/bench_access.sla, this tree)

Table: 2,000 rows seeded by one transaction. Direct face = one
pinned read handle driven from the main goroutine (find + get
per op). Access face = the goroutine access layer of this
directory (one pin per query, ticket round trip).

| measurement | result |
|---|---|
| point direct (pinned handle, in-process) | 5,500,852 qps |
| point via access layer, 1 client | 1,134 qps |
| point via access layer, 4 clients | 952 qps |
| point via access layer, 8 clients | 970 qps |
| deduct via access layer, 4 clients × 500 | 82 rps |
| deduct batches / commits / ok | 500 / 500 / 2,000 |

Reading of the access numbers: a point query through the layer
costs ~0.9 ms end to end — two goroutine spawns (runner +
outer), one supervised spawn, a pin open (manifest read) and a
handle find+get. Concurrency does not raise point throughput
(952–970 qps at 4–8 clients vs 1,134 at 1): the bottleneck is
per-query fixed cost, not client parallelism, and the engine's
read path serializes on the table's manifest/lock surface. The
layer does NOT stack the per-exec regression (its per-op cost
inside a pin is the handle face, same as direct); what it adds
is a bounded per-query orchestration cost (~0.9 ms), which is
the honest price of pin-per-query isolation and trap
containment. Deduct throughput (82 rps at 4 clients) is bounded
below by the 2 ms batching window plus one fsync'd commit per
batch; batches averaged 4 requests (500 batches / 2,000
deducts) because the bench's clients wait for each receipt
before sending the next.

Writer endurance: 20,000 sequential deducts from one client
were attempted twice. Before the writer-cycle refactor the
writer goroutine died of fixed-stack overflow before 5,000
(loop-body stack ratchet). After the refactor the run passed
15,000 deducts with no crash and no failed receipt observed,
and was then cut by the 900 s harness timeout under box
contention (~17–25 deducts/s effective for a sequential
client: 2 ms batch window + fsync'd commit + scheduling); the
final counters were not observed. The 2,000-deduct bench phase
above completes cleanly (2,000 ok / 500 commits).

## Engine bench (repo suite, same session)

`scripts/bench/run_bench.sh` rerun in this session against
the unmodified engine (base `c02b4ec`), three repetitions,
medians of ops/s (CSV columns: ops, threads, total, wall ms,
ops/s, p50 µs, p99 µs, errors — all error counts 0):

| measurement | this session (median) | G3 window median |
|---|---|---|
| readsum 1t | 3,866.8/s | (ratio 0.81× of pre-WAL) |
| readsum 4t | 7,969.3/s | (ratio 0.66×) |
| readsum 8t | 7,072.3/s | (ratio 0.53×) |
| point 1t | 6,506.0/s, p50 125 µs | (ratio 0.77×) |
| point 4t | 11,136.6/s | (ratio 0.62×) |
| write 1t | 114.7/s | 114.7/s |
| mixed 4 readers + 1 writer | 369.1 sums/s, 22.6 commits/s | — |

The write median reproduces the G3 figure exactly (114.7/s),
which anchors the two windows against each other. Absolute
read numbers sit below the §9.4 doc anchors (point 1t
12,099/s): those anchors came from a quieter window; this
session's box was shared with two other stage-2 lines. The
mixed row is NOT comparable to the §9.4 mixed anchor: in this
suite version the mixed readers run full-table sums (369/s),
while the anchor's readers ran point reads (12,070/s).

The same suite's SQLite reference (single run, this session):
readsum 1t 1,080.7/s; point 1t 145,376.0/s; write 1t 92.7/s.
SQLite point reads are an in-process C library call with no
per-query pin/manifest work, so the point gap is structural,
not a tuning delta; the engine beats the reference on readsum
and write in this window.

## Reference anchors (DIFFERENT window — do not mix)

PLAN-GOROUTINE §9.4 / INTEGRATION_PREP doc anchors, recorded by
the WAL integration line in its own window (single-run values,
for orientation only):

| measurement | anchor |
|---|---|
| readsum 1t | 6,048/s |
| readsum 8t | 15,386/s |
| point 1t | 12,099/s, p50 68 µs |
| point 4t | 24,863/s |
| write 1t | 81/s, p50 12.1 ms |
| mixed 4t readers / writer | 12,070/s / 51.3/s |

G3 verdicts from the integration window (medians): write 1t
114.7/s (2.67× the pre-WAL baseline); readsum 1t/4t/8t =
0.81×/0.66×/0.53× of the old baseline; point 1t/4t =
0.77×/0.62×. The read regression is an engine-side per-exec
cost; this layer's answer is structural (pin once per query,
handle face per op), measured above.
