//! Concurrency capacity bench for sa_plugin_db (VM concurrency line).
//!
//! Measures OUR db only: read throughput across a thread sweep,
//! single-writer commit throughput, a mixed 1-writer + N-readers
//! run with the whole-epoch oracle checked on every read, and
//! point reads. SQLite/PostgreSQL reference numbers come from the
//! companion scripts (see run_bench.sh); this binary never talks
//! to either — it links the plugin's query layer in-process, which
//! is exactly the access path an embedding application uses.
//!
//! Usage: bench <scenario> <threads> <ops>
//!   readsum  col_sum primitive execs over the 20k-row table
//!   point    single-row loads by ordinal over the 20k-row table
//!   write    single-writer set-all commits over the 2k-row table
//!   mixed    1 writer committing on the 20k-row table while
//!            <threads> readers sum it; ops = writer commits
//! Run with the working directory set to a prepared bench dir
//! (run_bench.sh creates one via `bench setup`).
//!
//! Output: one CSV line on stdout:
//!   scenario,threads,ops,wall_ms,ops_per_sec,p50_us,p99_us,bad
const std = @import("std");
const sio = @import("sio");
const db = @import("../../src/db_stub.zig");
const table_mod = @import("../../src/table.zig");

const alloc = std.heap.smp_allocator;

const bench_rows: u64 = 20_000;
const write_rows: u64 = 2_000;

fn writeFile(path: []const u8, bytes: []const u8) !void {
    var file = try sio.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn registerSource(name: []const u8, source: []const u8) ![]const u8 {
    try writeFile(name, source);
    var result = try db.registerQuery(alloc, name);
    defer result.deinit(alloc);
    const hex = std.fmt.bytesToHex(result.hash, .lower);
    return alloc.dupe(u8, &hex);
}

fn setup() !void {
    // bench table: id u64, val u64, 20_000 rows, val = 1.
    try writeFile("bench.sadb-schema",
        \\#def MAX_ROWS = 65536
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_VAL_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 16
    );
    var csv = std.array_list.Managed(u8).init(alloc);
    try csv.appendSlice("ID,VAL\n");
    var line_buf: [64]u8 = undefined;
    for (0..bench_rows) |i| {
        const line = try std.fmt.bufPrint(&line_buf, "{d},1\n", .{i});
        try csv.appendSlice(line);
    }
    try writeFile("bench.csv", csv.items);
    csv.deinit();
    _ = try table_mod.ingestTable(alloc, ".", "bench", "bench.csv");

    // wbench table: same shape, 2_000 rows, for the write curve.
    try writeFile("wbench.sadb-schema",
        \\#def MAX_ROWS = 65536
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_VAL_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 16
    );
    var wcsv = std.array_list.Managed(u8).init(alloc);
    try wcsv.appendSlice("ID,VAL\n");
    for (0..write_rows) |i| {
        const line = try std.fmt.bufPrint(&line_buf, "{d},1\n", .{i});
        try wcsv.appendSlice(line);
    }
    try writeFile("wbench.csv", wcsv.items);
    wcsv.deinit();
    _ = try table_mod.ingestTable(alloc, ".", "wbench", "wbench.csv");

    const sum_hash = try registerSource("sum.query.sa",
        \\grants [db_read:bench]
        \\@main(&col_val: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\total = col_sum col_val, len
        \\return total
    );
    const wsum_hash = try registerSource("wsum.query.sa",
        \\grants [db_read:wbench]
        \\@main(&col_val: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\total = col_sum col_val, len
        \\return total
    );
    // Set-all uses the native col_fill primitive (perf line): the
    // scenario is "set every row of the column to a constant", the
    // counterpart of SQL UPDATE ... SET val = c; the interpreted
    // per-row store loop it replaces measured ~85% of commit time
    // and remains covered by the unit suite.
    const setall_hash = try registerSource("setall.query.sa",
        \\grants [db_write:bench]
        \\@main(&col_val: ptr, len: u64, value: u64) -> u64:
        \\L_ENTRY:
        \\filled = col_fill col_val, len, value
        \\return value
    );
    const wsetall_hash = try registerSource("wsetall.query.sa",
        \\grants [db_write:wbench]
        \\@main(&col_val: ptr, len: u64, value: u64) -> u64:
        \\L_ENTRY:
        \\filled = col_fill col_val, len, value
        \\return value
    );
    const point_hash = try registerSource("point.query.sa",
        \\grants [db_read:bench]
        \\@main(&col_val: ptr, len: u64, idx: u64) -> u64:
        \\L_ENTRY:
        \\offset = mul idx, 8
        \\value = load col_val+offset as u64
        \\return value
    );

    const manifest = try std.fmt.allocPrint(alloc, "sum={s}\nwsum={s}\nsetall={s}\nwsetall={s}\npoint={s}\n", .{ sum_hash, wsum_hash, setall_hash, wsetall_hash, point_hash });
    defer alloc.free(manifest);
    try writeFile("bench_manifest.txt", manifest);

    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, 1, .little);
    try writeFile("v1.bin", &bytes);
    std.mem.writeInt(u64, &bytes, 2, .little);
    try writeFile("v2.bin", &bytes);
    std.mem.writeInt(u64, &bytes, 12345, .little);
    try writeFile("idx.bin", &bytes);
}

const Hashes = struct {
    sum: []const u8,
    wsum: []const u8,
    setall: []const u8,
    wsetall: []const u8,
    point: []const u8,
};

fn loadHashes() !Hashes {
    var manifest_file = try sio.cwd().openFile("bench_manifest.txt", .{});
    defer manifest_file.close();
    const text = try manifest_file.readToEndAlloc(alloc, 1 << 20);
    var hashes: Hashes = undefined;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "sum")) hashes.sum = value;
        if (std.mem.eql(u8, key, "wsum")) hashes.wsum = value;
        if (std.mem.eql(u8, key, "setall")) hashes.setall = value;
        if (std.mem.eql(u8, key, "wsetall")) hashes.wsetall = value;
        if (std.mem.eql(u8, key, "point")) hashes.point = value;
    }
    return hashes;
}

const ExecPool = struct {
    hash: []const u8,
    params: ?[]const u8,
    expected: ?u64,
    next: std.atomic.Value(u64) = .init(0),
    total: u64,
    lat: []u64,
    done: std.atomic.Value(u64) = .init(0),
    bad: std.atomic.Value(u64) = .init(0),

    fn work(self: *ExecPool) void {
        while (true) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.total) return;
            const start = sio.nanoTimestamp();
            var run = db.execQuery(alloc, self.hash, self.params) catch {
                _ = self.bad.fetchAdd(1, .monotonic);
                continue;
            };
            const elapsed: u64 = @intCast(sio.nanoTimestamp() - start);
            self.lat[i] = elapsed;
            if (self.expected) |want| {
                if (run.ok.code != 0 or run.ok.result_u64.? != want) {
                    _ = self.bad.fetchAdd(1, .monotonic);
                }
            }
            run.deinit(alloc);
            _ = self.done.fetchAdd(1, .monotonic);
        }
    }
};

fn runRead(scenario: []const u8, hash: []const u8, params: ?[]const u8, expected: ?u64, threads: u32, ops: u64) !void {
    const lat = try alloc.alloc(u64, @intCast(ops));
    defer alloc.free(lat);
    var pool = ExecPool{ .hash = hash, .params = params, .expected = expected, .total = ops, .lat = lat };
    const handles = try alloc.alloc(std.Thread, threads);
    defer alloc.free(handles);
    const start = sio.nanoTimestamp();
    for (handles) |*handle| handle.* = try std.Thread.spawn(.{}, ExecPool.work, .{&pool});
    for (handles) |*handle| handle.join();
    const wall_ns: u64 = @intCast(sio.nanoTimestamp() - start);
    printReport(scenario, threads, pool.done.load(.monotonic), wall_ns, lat[0..@intCast(pool.done.load(.monotonic))], pool.bad.load(.monotonic));
}

fn runWrite(hash: []const u8, commits: u64) !void {
    const lat = try alloc.alloc(u64, @intCast(commits));
    defer alloc.free(lat);
    var done: u64 = 0;
    var bad: u64 = 0;
    const start = sio.nanoTimestamp();
    var i: u64 = 0;
    while (i < commits) : (i += 1) {
        const one_start = sio.nanoTimestamp();
        var run = db.execQuery(alloc, hash, if (i % 2 == 0) "v1.bin" else "v2.bin") catch |err| {
            if (bad == 0) std.debug.print("write first error: {s}\n", .{@errorName(err)});
            bad += 1;
            continue;
        };
        lat[done] = @intCast(sio.nanoTimestamp() - one_start);
        if (run.ok.code != 0) {
            if (bad == 0) std.debug.print("write nonzero code: code={d} result={?d}\n", .{ run.ok.code, run.ok.result_u64 });
            bad += 1;
        }
        run.deinit(alloc);
        done += 1;
    }
    const wall_ns: u64 = @intCast(sio.nanoTimestamp() - start);
    printReport("write", 1, done, wall_ns, lat[0..@intCast(done)], bad);
}

const MixedWriterCtx = struct {
    hash: []const u8,
    commits: u64,
    done_flag: *std.atomic.Value(bool),
    commits_done: u64 = 0,
    bad: u64 = 0,
};

const MixedReaderCtx = struct {
    hash: []const u8,
    done_flag: *std.atomic.Value(bool),
    execs: u64 = 0,
    bad: u64 = 0,
};

fn mixedWriter(ctx: *MixedWriterCtx) void {
    var i: u64 = 0;
    while (i < ctx.commits) : (i += 1) {
        var run = db.execQuery(alloc, ctx.hash, if (i % 2 == 0) "v2.bin" else "v1.bin") catch {
            ctx.bad += 1;
            continue;
        };
        if (run.ok.code != 0) ctx.bad += 1;
        run.deinit(alloc);
        ctx.commits_done += 1;
    }
    // Restore val = 1 (uncounted) so later bench rounds see the
    // canonical table state regardless of the commit count parity.
    var restore = db.execQuery(alloc, ctx.hash, "v1.bin") catch null;
    if (restore) |*run| {
        if (run.ok.code != 0) ctx.bad += 1;
        run.deinit(alloc);
    } else {
        ctx.bad += 1;
    }
    ctx.done_flag.store(true, .release);
}

fn mixedReader(ctx: *MixedReaderCtx) void {
    while (!ctx.done_flag.load(.acquire)) {
        var run = db.execQuery(alloc, ctx.hash, null) catch {
            ctx.bad += 1;
            continue;
        };
        const sum = run.ok.result_u64.?;
        // Whole-epoch oracle: val is uniformly 1 or 2 per commit.
        if (run.ok.code != 0 or (sum != bench_rows and sum != bench_rows * 2)) ctx.bad += 1;
        run.deinit(alloc);
        ctx.execs += 1;
    }
}

fn runMixed(hashes: Hashes, readers: u32, commits: u64) !void {
    var done_flag = std.atomic.Value(bool).init(false);
    var writer_ctx = MixedWriterCtx{ .hash = hashes.setall, .commits = commits, .done_flag = &done_flag };
    const reader_ctxs = try alloc.alloc(MixedReaderCtx, readers);
    defer alloc.free(reader_ctxs);
    for (reader_ctxs) |*ctx| ctx.* = .{ .hash = hashes.sum, .done_flag = &done_flag };
    const handles = try alloc.alloc(std.Thread, readers);
    defer alloc.free(handles);
    const start = sio.nanoTimestamp();
    for (handles, reader_ctxs) |*handle, *ctx| handle.* = try std.Thread.spawn(.{}, mixedReader, .{ctx});
    const writer_thread = try std.Thread.spawn(.{}, mixedWriter, .{&writer_ctx});
    writer_thread.join();
    for (handles) |*handle| handle.join();
    const wall_ns: u64 = @intCast(sio.nanoTimestamp() - start);
    var total_reads: u64 = 0;
    var bad: u64 = writer_ctx.bad;
    for (reader_ctxs) |*ctx| {
        total_reads += ctx.execs;
        bad += ctx.bad;
    }
    const wall_ms = @as(f64, @floatFromInt(wall_ns)) / 1e6;
    const read_tput = @as(f64, @floatFromInt(total_reads)) / (wall_ms / 1000.0);
    const write_tput = @as(f64, @floatFromInt(writer_ctx.commits_done)) / (wall_ms / 1000.0);
    sio.getStdOut().print("mixed,{d},{d},{d:.1},{d:.1},{d:.1},0,0,{d}\n", .{ readers, total_reads, wall_ms, read_tput, write_tput, bad }) catch {};
}

fn printReport(scenario: []const u8, threads: u32, ops_done: u64, wall_ns: u64, lat: []u64, bad: u64) void {
    std.mem.sort(u64, lat, {}, std.sort.asc(u64));
    const wall_ms = @as(f64, @floatFromInt(wall_ns)) / 1e6;
    const tput = @as(f64, @floatFromInt(ops_done)) / (wall_ms / 1000.0);
    const p50: u64 = if (lat.len == 0) 0 else lat[(lat.len * 50) / 100];
    const p99: u64 = if (lat.len == 0) 0 else lat[@min(lat.len - 1, (lat.len * 99) / 100)];
    sio.getStdOut().print("{s},{d},{d},{d:.1},{d:.1},{d},{d},{d}\n", .{ scenario, threads, ops_done, wall_ms, tput, p50 / 1000, p99 / 1000, bad }) catch {};
}

pub fn runBench(args: []const []const u8) !void {
    if (args.len < 2) return error.MissingArgument;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--profile")) db.Profile.setEnabled(true);
    }
    defer db.Profile.dump();
    if (std.mem.eql(u8, args[1], "setup")) {
        try setup();
        return;
    }
    if (args.len < 4) return error.MissingArgument;
    const scenario = args[1];
    const threads = try std.fmt.parseInt(u32, args[2], 10);
    const ops = try std.fmt.parseInt(u64, args[3], 10);
    const hashes = try loadHashes();
    if (std.mem.eql(u8, scenario, "readsum")) {
        try runRead("readsum", hashes.sum, null, bench_rows, threads, ops);
    } else if (std.mem.eql(u8, scenario, "point")) {
        try runRead("point", hashes.point, "idx.bin", null, threads, ops);
    } else if (std.mem.eql(u8, scenario, "write")) {
        try runWrite(hashes.wsetall, ops);
    } else if (std.mem.eql(u8, scenario, "mixed")) {
        try runMixed(hashes, threads, ops);
    } else {
        return error.UnknownScenario;
    }
}
