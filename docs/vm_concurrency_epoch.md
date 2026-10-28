# VM Concurrency — Epoch-Pinned Snapshot Readers + Single-Writer Epoch Commit

Status: implemented (concurrency line on top of VM step 1,
`docs/vm_query_layer.md`). Concurrency model decided by JEV
(jev-1.14.0, `db-concurrency-model`): **Model A — snapshot readers +
single-writer epoch commit**, p=0.99. User hard constraints, verbatim
in effect: the db stays embedded and niche-but-safe — **no network
listener, no wire protocol, no service mode, no SQL parser** is added
by this work; concurrency exists only as in-process multithreaded
qmod execution. The security trio — capability grants
(`db_read`/`db_write`/`db_atomic_cursor`, per table and column),
register-time static checking (`DbCapabilityEscalation`), and fuel
metering — must hold unchanged under concurrency, and is revalidated
under concurrency in §7.

## 1. What already existed at the step-1 base (measured, not assumed)

- **Storage is already epoch-versioned.** A table manifest
  (`<table>.manifest`) names the active versioned meta
  (`<table>.meta.<epoch>`); segment/index/dict/blob artifacts are
  immutable per epoch, and artifacts become durable only when a
  later meta/manifest publish points at them. Commit point = the
  manifest publish (`writeMeta` → `publishWrittenMeta`).
- **The qmod read path already materializes a private snapshot.**
  `loadReadTable` resolves the active meta through the manifest,
  then copies every segment file's bytes into memory, validating
  each file's length, SHA-256, and block hashes
  (`validateQmodFileBytes`) on every exec. After the load, a reader
  touches no shared state.
- **The qmod write path already serializes writers.**
  `evalWriteDbQmod` / `evalReadWriteDbQmod` / `evalAtomicDbQmod`
  hold the table write lock (`acquireTableWriteLock`: flock on
  `<table>.write.lock` for disk roots, the process write-lock
  registry for memory roots) across load → stage → commit.
  `commitWriteTable` revalidates the full meta
  (`tableMetaStillCurrent`, else `StaleMetadata`), rewrites only
  dirty segments at `epoch + 1`, rebuilds indexes, and publishes.
- **The native layer already had the read-snapshot discipline.**
  `openReadSnapshot` pins the active epoch and reads immutable
  artifacts lock-free in durable mode (see the `snapshotTable`
  comment in `src/table.zig`). The qmod layer had no equivalent
  named protocol — that asymmetry is what this line closes.

## 2. Gaps this line closes

- **G1 — no in-process epoch identity.** A qmod exec's epoch choice
  was an unnamed side effect of whichever manifest read happened
  during its load. A read-write exec loads its read table and its
  write table at unrelated instants, so its read side was not tied
  to any single committed epoch; and with no pin registry, nothing
  in-process could state which epochs are in use (the precondition
  for any reclamation discipline).
- **G2 — parallel exec was an unproven accident.** `execQuery` had
  no thread-safety contract, no concurrent test, and no parallel
  surface; whether N threads could execute qmods against one table
  was unknown (see the before/after evidence in §8).
- **G3 — no epoch GC discipline.** Nothing stated when a superseded
  epoch stops being in use in-process.
- **G4 — commit visibility was implicit.** A commit became visible
  to in-process readers only because each exec re-read the manifest;
  there was no protocol step that publishes a new epoch to the
  in-process runtime.

## 3. Design: the epoch runtime (`src/epoch_runtime.zig`)

A small in-process registry, one entry per table name:

```
TableEpochState {
    mutex:            std.Thread.Mutex   // guards the fields below
    current:          *EpochPin          // latest committed epoch known in-process
    live_pins:        usize              // diagnostics / test observability
}
EpochPin {
    epoch:            u64
    meta_source:      []const u8         // owned bytes of <table>.meta.<epoch>
    refs:             std.atomic.Value(u32)
    retired:          bool               // superseded; freed when refs drain
}
```

Registry-internal allocations use `std.heap.page_allocator` (the
same precedent as `wal_dir_synced` in `src/table.zig`), so pin
lifetimes never couple to a per-exec allocator.

### 3.1 Pin protocol (readers)

`pinLatest(allocator, table) -> *EpochPin`:

1. Read the table manifest (the cross-process source of truth).
2. Under the table-state mutex, compare the manifest epoch with
   `current`:
   - equal → reuse `current`;
   - manifest newer (an external or in-process commit landed) →
     adopt: build a pin for the manifest epoch (reading the
     versioned meta it names), swap `current`, retire the old pin;
   - manifest older (a restore published an older epoch) → adopt
     the regression the same way. The manifest always wins; the
     runtime never invents an epoch.
3. Increment the pin's refcount and return it. Loads then consume
   the pin's `meta_source` — one named, consistent epoch per exec.

`release(pin)`: decrement; when a retired pin's refcount reaches
zero it is freed (the in-memory GC point, §3.3) and the table's
live-pin count drops.

Load integration (surgical, in `src/db_stub.zig`): `loadReadTable`
splits into a pinning front-end and `loadReadTableFromMeta`, which
takes the meta source as a parameter. The read-only evaluator pins
for the duration of its segment load; the cross-table read-write
evaluator pins its read table at the same point. The pin covers
the load window: segment bytes are copied into exec-private memory
after per-file hash validation, exactly as before — the pin adds
the epoch identity and the drain accounting, it does not change
what is verified.

### 3.2 Commit protocol (writer)

Unchanged staging discipline — step 1's, inherited by step 2's
write procedures and its AOT tier, which both commit through
`commitWriteTable`: stage into owned buffers under the table write
lock, revalidate meta freshness, write dirty segments at
`epoch + 1`, rebuild indexes, publish the manifest. The manifest
publish remains the durable, cross-process commit point.

This line adds the in-process publication step at the success tail
of `commitWriteTable`: `epoch_runtime.noteCommitted(table,
next_epoch)` swaps the registry's `current` to a fresh pin for the
new epoch and retires the previous one. Readers that pin after the
swap start on the new epoch; readers already pinned finish on
theirs. When no write happens (no dirty segments), there is no
epoch bump and no swap — unchanged from before.

### 3.3 Epoch GC discipline

- **In memory:** a retired `EpochPin` is freed exactly when its
  refcount drains to zero — never while a reader holds it. No other
  code frees pins.
- **On disk:** superseded epoch artifacts are *retained by design*
  in this storage engine — `recoverTable` scans versioned metas as
  recovery candidates and validates their segment files, and
  snapshots copy epoch artifacts — so automatic on-disk reaping
  would break recovery. This line therefore adds no file deletion.
  The contract any future on-disk reaper must obey is stated here
  as binding: reap only under the table write lock, only epochs
  strictly older than the oldest live pin for that table, and never
  the manifest-current epoch. The pin registry is the authority for
  "oldest live pin".

### 3.4 Atomic cursor ruling

The atomic-cursor evaluator is **writer-class**, and this line
rules its semantics explicitly: an atomic exec takes the table
write lock, stages from the **latest committed epoch** (it does not
read from a reader pin), applies its `atomic_rmw_add` operations to
the staged epoch, and publishes `epoch + 1` like any other writer.
"Atomic" names the read-modify-write semantics of the instruction
within the staged epoch; it is not a lock-free CAS against live
segment bytes. Concurrent atomic execs therefore serialize in
commit order with no lost updates (proven in §7: N threads × M
increments leave exactly N×M).

### 3.5 What is deliberately not here

- No change to `src/table.zig` or `src/plugin.zig`: the storage
  primitives (manifest publish, write lock, versioned metas) were
  sufficient, and the CLI surface is untouched (the CLI skill list
  and its guard tests are step-2-adjacent surface; the parallel
  surface below is an API for in-process hosts).
- Registration is unchanged and not made concurrent: registering is
  an operator action, and exec of a hash whose registration is
  in flight behaves exactly as before.
- WAL interplay is unchanged: qmod epochs are the durable manifest
  epochs; folding committed-but-uncheckpointed WAL data remains
  the native layer's discipline (`openReadSnapshot` / verify /
  snapshot), exactly as at step 1.

## 4. Parallel execution surface

- **Thread-safety contract for `execQuery` / `execQueryWithFuel`:**
  safe to call concurrently from multiple threads against the same
  or different tables, provided each call passes a thread-safe
  allocator (the per-thread `DebugAllocator` pattern the native
  layer's concurrency tests already use). All evaluator state —
  including the `FuelMeter` — is per-call; `src/db_stub.zig` holds
  no mutable globals; the shared state below it (table-layer
  caches, WAL registries) was already mutex/atomic-guarded.
- **`execQueriesParallel`**: a batch helper that runs a slice of
  independent exec requests on a bounded worker pool (one thread
  per request up to the requested parallelism), each with its own
  allocator and fuel meter, returning per-request results/errors
  in request order. It is a scheduling convenience over the same
  `execQueryWithFuel`; it adds no new execution semantics.

## 5. Semantics reconciliation (existing commands under the epoch protocol)

| Operation | Disposition under Model A |
| --- | --- |
| `snapshot` | **Keep, unchanged.** Already pins the active epoch and copies immutable artifacts lock-free in durable mode; qmod pins do not interact with snapshot copies. |
| `restore` | **Keep, unchanged.** Runs under the table write lock and republishes an older epoch as current. In-process readers keep their pinned (newer) epoch and finish consistently — its files persist; the next pin adopts the restored epoch (§3.1 regression rule). |
| `compact` | **Keep, unchanged.** Write-locked; merges segments and publishes `epoch + 1` without deleting superseded segment files. Pinned readers are unaffected; the runtime adopts the new epoch on the next pin or `noteCommitted`. |
| `lock` / `unlock` | **Keep, unchanged.** The meta `locked` flag still refuses write loads (`Locked`) and still permits reads; `lock` also makes artifacts read-only on disk. Concurrency does not widen or narrow it. |
| `verify` / `recover` | **Keep, unchanged.** Operate on the manifest-current epoch (plus WAL folding / versioned-meta scan) exactly as before; the pin registry is not consulted, and §3.3's retention rule exists precisely to protect `recover`. |
| `register` / `inspect` | **Keep, unchanged.** Operator actions outside the concurrency model. |

## 6. Step-2 alignment

Step 2's write-set staging is the same `loadWriteTable` →
`commitWriteTable` machinery (§1), so the commit hook of §3.2 sits
at the one point both the interpreted evaluators and the AOT tier
commit through. If step 2 reshapes `commitWriteTable`'s tail, the
integration cost is moving one `noteCommitted` call. Step 2's
registry-record changes (class derivation, exec-time revalidation)
are orthogonal: pins key on table names and epochs, never on
registry records.

*Status note (after step 2 landed as sa_plugin_db `be8468d5`):*
step 2's design doc confirms its AOT write procedures commit
through the same `commitWriteTable`, so the single
`noteCommitted` hook covers interpreted and AOT writers alike,
as designed. This line's staging is based on the step-1 commit,
so integration rebases it onto the step-2 tip; the expected
overlap is `src/db_stub.zig` (the `loadReadTable` /
`commitWriteTable` / exec area) plus the one-function storage
fix in `src/table.zig` described in §7.1. `src/plugin.zig` is
untouched.

## 7. Verification

All runs on the Colab box (hostname `2d60bdf6bf1a`), full fixture
tree, `zig build test --summary all` against sci
`28fd2ceb` / sa_plugin_sla `754edb2f`.

**Name-set regression.** Baseline at the step-1 commit
(`320158f`): 212/212 unit tests pass, failure name set ∅
(126/129 build steps; the single failed step,
`check-benchmark-artifacts`, was environmental — the subset
staging lacks `benchmark_test/` and a git repo; the harness was
reconstructed box-side only, staging untouched, and the guard
then passes standalone). After this line: **221/221 tests,
129/129 steps, failure name set ∅** — the 212 baseline tests plus
9 new ones (3 epoch-runtime unit tests, 5 concurrency/safety
tests, 1 regression test from §7.1). The pre-fix gate was re-run
three extra times with fresh seeds: 220/220 each time (that
stage predates the regression test), no flaky names.

**Stress oracle** (`qmod concurrent readers and single writer
keep the epoch oracle`). 200-row table; one writer commits
set-all v = 1..10 while 4 readers × 30 execs sum the column.
Every observed sum equals v×200 for some committed v (never a
torn value), each reader's v is non-decreasing, the final sum is
2000 (the serial oracle), `verifyTable` is clean, and the pin
registry drains to zero live pins with
`currentEpoch == base + 10`. The bench's mixed runs (§8) repeat
the same oracle over 3.4k–4.9k reads per round with 0
violations.

**Atomic cursor** (`qmod concurrent atomic cursor increments are
exact`). 4 threads × 12 increments return the old values 0..47,
each exactly once; the final counter is 48. The writer-class
ruling of §3.4 holds under concurrency: no lost or duplicated
increments.

**Safety trio under concurrency.**
- *Grants*: while 3 reader threads hammer valid execs,
  registration of a store under `db_read`, a load through an
  undeclared pointer, and an `atomic_rmw` under `db_read` are
  each rejected with `DbCapabilityEscalation`
  (`qmod grant rejections hold under concurrent read load`),
  on top of the pre-existing rejection family in the 212.
- *Fuel*: a runaway read loop and a fuel-starved writer (limit
  10) both terminate `FuelExhausted` on their own meters while
  concurrent readers keep returning the correct sum; the starved
  writer leaves zero partial writes
  (`qmod fuel exhaustion under concurrency stays per-exec`).
- *No listener surface*: this line adds no networking at all.
  Census of `src/*.zig` after the change: zero occurrences of
  `socket` or `listen` anywhere in the plugin sources (the epoch
  runtime included). The db remains in-process and file-backed
  only.

**Parallel contrast** (`qmod parallel exec surface is ordered
and scales readers`). The same batch of 8 CPU-bound loop-sum
execs over 20,000 rows takes 3209 ms on 1 worker and 1034 ms on
4 workers (3.10×) through `execQueriesParallel`; a mixed
[read, write, read] batch returns ordered outcomes, each read
observing a whole epoch. §8 has the full thread sweep.

### 7.1 Defect found by the bench: chained epoch suffixes (fixed)

The first bench run exposed a pre-existing step-1 defect in the
storage layer, unrelated to the epoch design but fatal to any
sustained write workload: `rewriteColumnFileForEpoch`
(`src/table.zig`) formed each new segment file name by appending
`.e<epoch>` to the *previous* epoch's path, so names chained
without bound (`wbench.col1.0.dat.e2.e3.…e56`). After 55
successful commits the next commit failed with
`SnapshotCorrupted` and the table stayed permanently unwritable
(the manifest froze at epoch 56), while the codebase's own
cleanup enumeration (`deleteTableArtifacts`) already assumes
the canonical `<base>.e<epoch>` form — the chained files were
not even reachable for deletion. Every other versioned artifact
(meta, indexes, dicts) is named from the table name directly;
this function was the sole deviation.

Fix: the function now strips trailing `.e<digits>` suffixes to
recover the base name before appending the new epoch once.
Recorded paths in existing metas are explicit, so old tables
(including already-chained ones) keep reading and heal on their
next commit. Regression test `qmod many sequential commits keep
canonical epoch file names` (90 sequential commits) provides the
dual evidence required by house rules: with the fix reverted,
the suite is 220/221 and the *only* failure is that test; with
the fix, 221/221. After the fix the bench writes 60/60 commits
in every round (§8) instead of collapsing at 55.

## 8. Benchmarks

**Headline numbers.** On the bench machine below, our db's
maximum effective concurrency is **8 reader threads** — exactly
the core count: read throughput climbs to a peak of **535.6
exec/s** (column-sum executions over 20,000 rows; point reads
peak at **980.4/s**) and then stops growing. Peak write
throughput is **26.1 commits/s** for full-table set-all commits
over 2,000 rows, and **2.5 commits/s** over 20,000 rows while 4
parallel readers sustain **398.5 reads/s** against the same
table with zero oracle violations. Past saturation (16–32
threads) throughput stays flat (~420–450 exec/s, no cliff, no
errors) while latency queue-inflates: p50 grows 12.5 ms → 64.3
ms and p99 blows out 30.6 ms → 167.0 ms. The knee is the core
count, and the post-saturation shape is queueing, not collapse.

**Machine.** Colab box, hostname `2d60bdf6bf1a`: 8 cores, AMD
EPYC 7B12, 50 GB RAM (MemTotal 53,467,180 kB), Linux, box-local
disk. The box is shared with other work lines, so every scenario
ran 3 rounds and the tables below are medians of the rounds;
single-round outliers are visible in the raw CSVs produced by
`scripts/bench/run_bench.sh` / `bench_pg.sh`.

**Method.** Fixed dataset for all three systems: a 20,000-row
table `t(id u64/int, val u64/int)` with `val = 1` (sum =
20,000), plus a 2,000-row twin for writes. Equivalent
operations: our qmod primitives (`col_sum`, single-row load,
set-all write module) vs SQLite `SELECT sum(val)` / `SELECT val
WHERE id = 12345` / transactional full-table `UPDATE`, vs the
same SQL on PostgreSQL via pgbench. Access paths, stated
plainly: ours is **in-process direct calls** into the plugin's
query layer (ReleaseFast bench binary, `scripts/bench/`); SQLite
is **in-process library calls** through python3's `sqlite3`
module (3.45.1) — its multi-thread rows pass through CPython
threads and are GIL-bound, so its 1-thread rows are the clean
comparison; PostgreSQL 16 is a **local unix-socket** server
(private throwaway cluster created for this bench and deleted
after; pgbench clients, per-transaction logs for percentiles).

### 8.1 Our concurrency curve (medians of 3 rounds)

Read sweep — `col_sum` execs, 480 per tier, whole-epoch oracle
checked on every exec (bad = 0 in every round and tier):

| threads | exec/s | p50 | p99 |
| --- | --- | --- | --- |
| 1 | 142.0 | 7.01 ms | 8.11 ms |
| 2 | 276.2 | 7.21 ms | 8.22 ms |
| 4 | 411.3 | 10.62 ms | 11.26 ms |
| 8 | **535.6** | 12.52 ms | 30.58 ms |
| 16 | 420.1 | 37.11 ms | 76.89 ms |
| 32 | 449.2 | 64.30 ms | 167.03 ms |

Point reads — single-row loads by ordinal, 480 per tier:

| threads | exec/s | p50 | p99 |
| --- | --- | --- | --- |
| 1 | 222.7 | 4.48 ms | 4.87 ms |
| 4 | 811.2 | 4.79 ms | 6.61 ms |
| 8 | **980.4** | 8.06 ms | 13.62 ms |

Writes — single writer, 60 set-all commits per round on the
2,000-row table: **26.1 commits/s**, p50 36.18 ms, p99 84.39 ms
(p99 across only 60 samples per round is spiky: 37.5 / 84.4 /
165.2 ms by round).

Mixed — 1 writer + 4 readers on the 20,000-row table, 25
commits per round: readers sustain **398.5 exec/s** while the
writer lands **2.5 commits/s**; 3,371–4,861 oracle-checked
reads per round, **0 violations** (every read saw a whole
committed epoch).

### 8.2 Reference frame (same machine, same data)

SQLite (medians; multi-thread rows are CPython-GIL-bound, see
Method):

| scenario | threads | ops/s | p50 | p99 |
| --- | --- | --- | --- | --- |
| sum | 1 | 1,058.1 | 0.83 ms | 1.42 ms |
| sum | 8 | 4,828.3 | 1.38 ms | 4.97 ms |
| sum | 16 | 5,058.3 | 1.39 ms | 9.37 ms |
| point | 1 | 164,780.7 | 5 µs | 10 µs |
| point | 8 | 12,589.9 | 0.58 ms | 1.59 ms |
| write | 1 | 181.3 | 5.53 ms | 6.11 ms |

PostgreSQL 16 via pgbench (medians; unix socket):

| scenario | clients | ops/s | p50 | p99 |
| --- | --- | --- | --- | --- |
| sum | 1 | 918.0 | 1.07 ms | 1.32 ms |
| sum | 8 | 3,671.1 | 1.95 ms | 5.22 ms |
| sum | 16 | 3,715.0 | 3.90 ms | 9.13 ms |
| point | 1 | 14,655.9 | 59 µs | 116 µs |
| point | 8 | 24,842.8 | 192 µs | 519 µs |
| write | 1 | 175.8 | 5.00 ms | 14.71 ms |

### 8.3 Attribution — where we lose, and why

We lose every absolute-throughput row against both references
on this dataset, and the reasons split cleanly into model
differences and implementation gaps:

- **Per-exec snapshot materialization (implementation gap,
  dominant).** Every one of our execs re-reads the manifest and
  meta, loads the segment files, and revalidates lengths,
  SHA-256 and per-block hashes before the query runs — a
  ~4.5–7 ms floor per exec at 20,000 rows, paid identically by
  a full column sum and by a single-row point read. SQLite and
  PostgreSQL answer from an already-open, warm database, so
  their per-op costs (0.83 ms sum / 5 µs point for SQLite;
  1.07 ms / 59 µs for PG) measure query work only. This is the
  single biggest lever for future work: the epoch pin registry
  shipped by this line is exactly the identity a materialized-
  snapshot cache would key on (pin epoch + meta hash), but
  caching snapshots is deliberately out of this line's scope —
  the step-1 discipline "no state survives an exec" stays
  until someone designs that cache's invalidation story.
- **Write cost (model difference + maturity).** A commit
  rewrites every dirty segment as a new immutable artifact,
  rebuilds the table's indexes, and publishes a new manifest —
  36 ms at 2,000 rows, ~400 ms at 20,000 rows. SQLite/PG update
  in place under a WAL/journal (~5 ms for the same full-table
  update). Immutable epoch artifacts are the price of the
  snapshot-reader model itself; the index-rebuild share of the
  cost is implementation maturity, not model.
- **What does hold up.** Our scaling *shape* is the cleanest of
  the three: throughput rises monotonically to the core count
  with no lock cliff (the references saturate too — PG's sum
  plateaus at ~3,700/s from 8 clients, SQLite's point reads
  *degrade* 13× from 1→8 python threads under the GIL), and our
  post-saturation failure mode is latency inflation with zero
  errors and zero oracle violations, never wrong data. The
  product claim of this db was never raw speed — it is the
  capability/fuel safety posture of §7 plus verified snapshot
  consistency — but the snapshot-reuse gap above is recorded
  here as the honest first optimization target.
