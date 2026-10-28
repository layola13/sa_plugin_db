const std = @import("std");
const builtin = @import("builtin");
const sio = @import("sio");
const schema = @import("schema.zig");
const table_mod = @import("table.zig");
const epoch_runtime = @import("epoch_runtime.zig");

// ---------------------------------------------------------------------------
// Optional exec-phase profiling (perf line instrumentation).
//
// Disabled by default; the bench harness enables it by setting the
// process env SA_DB_PROFILE=1 before the first exec (see
// scripts/bench/bench_main.zig). Counters are atomic accumulators of
// nanoseconds per phase plus call counts, so concurrent execs can
// share them. When disabled the only cost is one relaxed atomic load
// per phase boundary.
// ---------------------------------------------------------------------------
pub const Profile = struct {
    pub const Phase = enum {
        registry_meta,
        params_read,
        qmod_load,
        scalar_eval,
        table_meta_source,
        table_meta_parse_pin,
        table_schema,
        segment_read,
        segment_validate,
        segment_copy,
        read_eval_rest,
        prog_params,
        prog_lines,
        stmt_loop,
        scan_fold,
        write_load,
        write_eval_rest,
        commit_publish,
    };
    pub const phase_count = 18;
    pub const phase_names: [phase_count][]const u8 = .{
        "registry_meta",      "params_read",   "qmod_load",       "scalar_eval",
        "table_meta_source",  "table_meta_parse_pin", "table_schema", "segment_read",
        "segment_validate",   "segment_copy",  "read_eval_rest",  "prog_params",
        "prog_lines",         "stmt_loop",     "scan_fold",      "write_load",
        "write_eval_rest",    "commit_publish",
    };

    var enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var ns: [phase_count]std.atomic.Value(u64) = initCounts();
    var calls: [phase_count]std.atomic.Value(u64) = initCounts();

    fn initCounts() [phase_count]std.atomic.Value(u64) {
        var out: [phase_count]std.atomic.Value(u64) = undefined;
        for (&out) |*slot| slot.* = std.atomic.Value(u64).init(0);
        return out;
    }

    pub fn setEnabled(on: bool) void {
        enabled.store(on, .monotonic);
    }

    pub fn isEnabled() bool {
        return enabled.load(.monotonic);
    }

    pub fn add(phase: Phase, elapsed_ns: u64) void {
        if (!enabled.load(.monotonic)) return;
        const idx = @intFromEnum(phase);
        _ = ns[idx].fetchAdd(elapsed_ns, .monotonic);
        _ = calls[idx].fetchAdd(1, .monotonic);
    }

    pub fn dump() void {
        if (!enabled.load(.monotonic)) return;
        std.debug.print("== SA_DB_PROFILE (accumulated ns / calls / us per call) ==\n", .{});
        for (phase_names, 0..) |name, idx| {
            const total = ns[idx].load(.monotonic);
            const n = calls[idx].load(.monotonic);
            if (n > 0) {
                std.debug.print("  {s:<20} {d:>14} ns  {d:>8} calls  {d:>10} us/call\n", .{ name, total, n, total / n / 1000 });
            }
        }
    }
};

pub const ScopedTimer = struct {
    phase: Profile.Phase,
    start: i128,

    pub fn begin(phase: Profile.Phase) ScopedTimer {
        return .{ .phase = phase, .start = sio.nanoTimestamp() };
    }

    pub fn end(self: ScopedTimer) void {
        if (!Profile.isEnabled()) return;
        const elapsed: u64 = @intCast(sio.nanoTimestamp() - self.start);
        Profile.add(self.phase, elapsed);
    }
};

pub const ExecError = error{
    OutOfMemory,
    InvalidFormat,
    InvalidQueryHash,
    QueryRegistryCorrupted,
    QueryPayloadCorrupted,
    InvalidParams,
    SchemaMismatch,
    ColumnTypeMismatch,
    SnapshotCorrupted,
    InvalidPath,
    FileNotFound,
    QueryHashUnknown,
    DuplicateRegister,
    DbCapabilityEscalation,
    Locked,
    StaleMetadata,
    UnsupportedOperation,
    ConstraintViolation,
    FuelExhausted,
    InvalidFuelLimit,
    AotLibraryInvalid,
    AotSymbolMissing,
    AotAbiMismatch,
    AotUnsupportedShape,
    AotAlreadyRegistered,
};

pub const ExecResult = struct {
    hash: [32]u8,
    qmod_path: []u8,
    meta_path: []u8,
    source_path: []u8,
    imports: u64,
    grants: u64,
    kind: []const u8 = "query",
    write_capability: bool = false,

    pub fn deinit(self: *ExecResult, allocator: std.mem.Allocator) void {
        allocator.free(self.qmod_path);
        allocator.free(self.meta_path);
        allocator.free(self.source_path);
        self.* = undefined;
    }
};

pub const ExecRunResult = struct {
    code: u8,
    function_name: []u8,
    hash: [32]u8,
    result_u64: ?u64 = null,
    fuel_used: u64 = 0,
    fuel_limit: u64 = 0,
    aot: bool = false,

    pub fn deinit(self: *ExecRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.function_name);
        self.* = undefined;
    }
};

pub const ExecRun = union(enum) {
    ok: ExecRunResult,

    pub fn deinit(self: *ExecRun, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*result| result.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Default per-exec fuel budget, in abstract steps. One step is charged per
/// executed qmod instruction; native column primitives additionally charge
/// one step per scanned row. The default matches the historical hard-coded
/// 1,000,000 instruction cap the evaluators used before fuel metering
/// existed, so previously accepted modules keep running unchanged.
pub const default_fuel_limit: u64 = 1_000_000;

/// Environment variable that overrides the default fuel limit for
/// `sa db exec` when no explicit fuel limit is given. Following the same
/// pattern as table.zig's SA_DB_UNSAFE_NO_SYNC detection, the value is read
/// from /proc/self/environ on Linux: libdb.so is linked without libc, so
/// getenv is unavailable (and std.posix.getenv was removed in Zig 0.17);
/// the variable is only honored as inherited at process start.
pub const fuel_limit_env_var = "SA_DB_QMOD_FUEL";

/// Step budget for one qmod execution. A single meter is created per exec
/// and shared by every evaluator shape the exec attempts, so shape probing
/// cannot multiply the total work one exec performs. Exhaustion is a hard
/// error (FuelExhausted), never the UnsupportedOperation shape signal.
pub const FuelMeter = struct {
    limit: u64,
    used: u64 = 0,

    pub fn charge(self: *FuelMeter, steps: u64) ExecError!void {
        if (steps > self.limit - @min(self.used, self.limit)) return ExecError.FuelExhausted;
        self.used += steps;
    }
};

fn fuelLimitFromProcEnv() ExecError!?u64 {
    if (builtin.os.tag != .linux) return null;
    var file = sio.openFileAbsolute("/proc/self/environ", .{}) catch return null;
    defer file.close();
    var buffer: [128 * 1024]u8 = undefined;
    const bytes_read = file.read(&buffer) catch return null;
    var entries = std.mem.splitScalar(u8, buffer[0..bytes_read], 0);
    while (entries.next()) |entry| {
        if (entry.len <= fuel_limit_env_var.len) continue;
        if (entry[fuel_limit_env_var.len] != '=') continue;
        if (!std.mem.eql(u8, entry[0..fuel_limit_env_var.len], fuel_limit_env_var)) continue;
        const text = entry[fuel_limit_env_var.len + 1 ..];
        const value = std.fmt.parseInt(u64, text, 10) catch return ExecError.InvalidFuelLimit;
        if (value == 0) return ExecError.InvalidFuelLimit;
        return value;
    }
    return null;
}

/// Resolve the effective fuel limit for one exec: an explicit limit wins,
/// then the SA_DB_QMOD_FUEL environment variable, then the default.
pub fn resolveFuelLimit(explicit: ?u64) ExecError!u64 {
    if (explicit) |limit| {
        if (limit == 0) return ExecError.InvalidFuelLimit;
        return limit;
    }
    if (try fuelLimitFromProcEnv()) |limit| return limit;
    return default_fuel_limit;
}

const QueryMeta = struct {
    magic: []const u8,
    version: u32,
    hash: []const u8,
    source_path: []const u8,
    qmod_path: []const u8,
    imports: u64,
    grants: u64,
    grant_entries: []const []const u8,
    main: []const u8,
    // Step 2 (VM write procedures): the module class derived from the
    // grant entries, recorded explicitly in the registry record.
    // Version 1 records predate these fields; the defaults keep them
    // parseable, and readers derive the class from grant_entries for
    // such records instead of trusting the stored defaults.
    kind: []const u8 = "query",
    write_capability: bool = false,
    write_tables: []const []const u8 = &.{},
    // Step 2 AOT escape hatch: present only when a native library was
    // explicitly registered for this module (per-module opt-in). Exec
    // verifies the library bytes against lib_sha256 on every run and
    // never falls back to the interpreter when an AOT record exists.
    aot: ?AotRecord = null,
};

const AotRecord = struct {
    lib_path: []const u8,
    lib_sha256: []const u8,
    symbol: []const u8,
    abi_version: u32,
};

/// A registered module's class, derived from its grant entries. A
/// module holding any table-writing grant (db_write /
/// db_atomic_cursor) is a write procedure: a category separate from
/// read-only query modules, whose registry record carries the write
/// capability explicitly (kind / write_capability / write_tables).
const ModuleClass = struct {
    kind: []const u8,
    write_capability: bool,
    write_tables: []const []const u8,
};

fn deriveModuleClass(allocator: std.mem.Allocator, entries: []const []const u8) ExecError!ModuleClass {
    var tables = std.array_list.Managed([]const u8).init(allocator);
    errdefer tables.deinit();
    for (entries) |entry| {
        const table_name = parseWriteGrant(entry) orelse parseAtomicGrant(entry) orelse continue;
        var seen = false;
        for (tables.items) |existing| {
            if (std.mem.eql(u8, existing, table_name)) {
                seen = true;
                break;
            }
        }
        if (!seen) tables.append(table_name) catch return ExecError.OutOfMemory;
    }
    const write_tables = tables.toOwnedSlice() catch return ExecError.OutOfMemory;
    return .{
        .kind = if (write_tables.len > 0) "procedure" else "query",
        .write_capability = write_tables.len > 0,
        .write_tables = write_tables,
    };
}

const GrantSet = struct {
    entries: [][]u8,
    db_read: bool = false,
    db_write: bool = false,
    db_atomic_cursor: bool = false,
    db_alloc_blob: bool = false,

    pub fn deinit(self: *GrantSet, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| allocator.free(entry);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

const ValueMap = std.StringHashMap(u64);

const ParamCursor = struct {
    allocator: std.mem.Allocator,
    params_path: ?[]const u8,
    bytes: ?[]u8 = null,
    offset: usize = 0,

    pub fn deinit(self: *ParamCursor) void {
        if (self.bytes) |bytes| self.allocator.free(bytes);
        self.* = undefined;
    }

    pub fn readU64(self: *ParamCursor) ExecError!u64 {
        if (self.bytes == null) {
            const path = self.params_path orelse return ExecError.InvalidParams;
            self.bytes = try readFileAlloc(self.allocator, path, 64 * 1024 * 1024);
        }
        const bytes = self.bytes.?;
        if (bytes.len - self.offset < @sizeOf(u64)) return ExecError.InvalidParams;
        const value = std.mem.readInt(u64, bytes[self.offset..][0..8], .little);
        self.offset += @sizeOf(u64);
        return value;
    }

    pub fn finish(self: *ParamCursor) ExecError!void {
        if (self.bytes) |bytes| {
            if (self.offset != bytes.len) return ExecError.InvalidParams;
        } else if (self.params_path != null) return ExecError.InvalidParams;
    }
};

const FunctionSig = struct {
    name: []const u8,
    params: []const []const u8,

    pub fn deinit(self: *FunctionSig, allocator: std.mem.Allocator) void {
        allocator.free(self.params);
        self.* = undefined;
    }
};

const QmodTableMeta = table_mod.TableMeta;

const TableColumn = struct {
    name: []const u8,
    ty: []const u8,
    stride: u32,
    bytes: []u8,
    /// False when name/ty/bytes are borrowed from a pinned snapshot
    /// (see Snapshot below); the snapshot owns them and frees them
    /// when its pin drains. Owned columns free their parts here.
    owned: bool = true,

    pub fn deinit(self: *TableColumn, allocator: std.mem.Allocator) void {
        if (self.owned) {
            allocator.free(self.name);
            allocator.free(self.ty);
            allocator.free(self.bytes);
        }
        self.* = undefined;
    }
};

const WriteColumnSegment = struct {
    path: []const u8,
    rows: u64,
    bytes: []u8,
    dirty: bool = false,

    pub fn deinit(self: *WriteColumnSegment, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const WriteColumn = struct {
    name: []const u8,
    ty: []const u8,
    stride: u32,
    segments: []WriteColumnSegment,

    pub fn deinit(self: *WriteColumn, allocator: std.mem.Allocator) void {
        for (self.segments) |*segment| segment.deinit(allocator);
        allocator.free(self.segments);
        self.* = undefined;
    }
};

const WriteTable = struct {
    meta_path: []u8,
    parsed: std.json.Parsed(QmodTableMeta),
    row_count: u64,
    columns: []WriteColumn,

    pub fn deinit(self: *WriteTable, allocator: std.mem.Allocator) void {
        allocator.free(self.meta_path);
        for (self.columns) |*column| column.deinit(allocator);
        allocator.free(self.columns);
        self.parsed.deinit();
        self.* = undefined;
    }
};

const ReadTable = struct {
    name: []u8,
    row_count: u64,
    columns: []TableColumn,
    /// Set when the columns borrow from a pinned snapshot: the pin
    /// hold taken by loadReadTable is owned by this ReadTable and
    /// released here, so the snapshot outlives every use of the
    /// borrowed bytes. `pin_table_name` borrows the caller's table
    /// name slice (grant storage outlives the exec).
    pin: ?*epoch_runtime.EpochPin = null,
    pin_table_name: []const u8 = "",

    pub fn deinit(self: *ReadTable, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.columns) |*column| column.deinit(allocator);
        allocator.free(self.columns);
        if (self.pin) |pin| epoch_runtime.release(self.pin_table_name, pin);
        self.* = undefined;
    }
};

fn hashBytes(bytes: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn hashHexAlloc(allocator: std.mem.Allocator, hash: [32]u8) ExecError![]u8 {
    const encoded = std.fmt.bytesToHex(hash, .lower);
    return allocator.dupe(u8, encoded[0..]) catch ExecError.OutOfMemory;
}

fn hashHex(bytes: []const u8) [64]u8 {
    return std.fmt.bytesToHex(hashBytes(bytes), .lower);
}

fn parseHashHex(text: []const u8) ExecError![32]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len != 64) return ExecError.InvalidQueryHash;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(out[0..], trimmed) catch return ExecError.InvalidQueryHash;
    return out;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ExecError![]u8 {
    var file = sio.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return ExecError.FileNotFound,
        else => return ExecError.InvalidPath,
    };
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes) catch |err| switch (err) {
        error.OutOfMemory => ExecError.OutOfMemory,
        else => ExecError.InvalidFormat,
    };
}

fn mapTableError(err: table_mod.TableError) ExecError {
    return switch (err) {
        error.OutOfMemory => ExecError.OutOfMemory,
        error.InvalidFormat => ExecError.SnapshotCorrupted,
        error.InvalidPath => ExecError.InvalidPath,
        error.NotFound => ExecError.FileNotFound,
        error.Locked => ExecError.Locked,
        error.CursorOverflow => ExecError.InvalidFormat,
        error.SnapshotMissing => ExecError.FileNotFound,
        error.VerifyFailed => ExecError.SnapshotCorrupted,
        error.ConstraintViolation => ExecError.ConstraintViolation,
    };
}

fn acquireTableWriteLock(allocator: std.mem.Allocator, table_name: []const u8) ExecError!table_mod.TableWriteLock {
    return table_mod.acquireTableWriteLock(allocator, ".", table_name) catch |err| return mapTableError(err);
}

fn readActiveTableMetaSource(allocator: std.mem.Allocator, table_name: []const u8) ExecError![]u8 {
    return table_mod.readActiveMetaSource(allocator, ".", table_name) catch |err| return mapTableError(err);
}

fn validateQmodFileBytes(file_meta: table_mod.FileMeta, bytes: []const u8) ExecError!void {
    if (bytes.len != file_meta.bytes) return ExecError.SnapshotCorrupted;
    const actual_hash = hashHex(bytes);
    if (!std.mem.eql(u8, actual_hash[0..], file_meta.sha256)) return ExecError.SnapshotCorrupted;
    table_mod.validateFileBlockHashes(file_meta, bytes) catch |err| return mapTableError(err);
}

fn ensureRegistryDir() ExecError!void {
    sio.cwd().makePath(".sa/db/qmods") catch return ExecError.InvalidPath;
}

fn qmodPath(allocator: std.mem.Allocator, hash_hex: []const u8) ExecError![]u8 {
    return std.fmt.allocPrint(allocator, ".sa/db/qmods/{s}.qmod", .{hash_hex}) catch ExecError.OutOfMemory;
}

fn metaPath(allocator: std.mem.Allocator, hash_hex: []const u8) ExecError![]u8 {
    return std.fmt.allocPrint(allocator, ".sa/db/qmods/{s}.meta.json", .{hash_hex}) catch ExecError.OutOfMemory;
}

fn writeFile(path: []const u8, bytes: []const u8) ExecError!void {
    var file = sio.cwd().createFile(path, .{ .truncate = true }) catch return ExecError.InvalidPath;
    defer file.close();
    file.writeAll(bytes) catch return ExecError.InvalidPath;
}

fn grantEntriesEqual(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn verifyExistingRegistration(
    allocator: std.mem.Allocator,
    hash_hex: []const u8,
    source_path: []const u8,
    source: []const u8,
    qmod_path: []const u8,
    imports: u64,
    grants: GrantSet,
    main_name: []const u8,
) ExecError!void {
    const existing_meta = loadMeta(allocator, hash_hex) catch |err| switch (err) {
        ExecError.QueryHashUnknown => return,
        else => return err,
    };
    defer existing_meta.deinit();

    if (!std.mem.eql(u8, existing_meta.value.source_path, source_path) or
        !std.mem.eql(u8, existing_meta.value.qmod_path, qmod_path) or
        existing_meta.value.imports != imports or
        existing_meta.value.grants != grants.entries.len or
        !grantEntriesEqual(existing_meta.value.grant_entries, grants.entries) or
        !std.mem.eql(u8, existing_meta.value.main, main_name) or
        !std.mem.eql(u8, existing_meta.value.hash, hash_hex))
    {
        return ExecError.DuplicateRegister;
    }

    if (existing_meta.value.version >= 2) {
        // A version 2 record's stored class fields must agree with the
        // class derived from its own grant entries; a record that lies
        // about its write capability is corrupted, not a duplicate.
        const existing_class = try deriveModuleClass(allocator, existing_meta.value.grant_entries);
        defer allocator.free(existing_class.write_tables);
        if (!std.mem.eql(u8, existing_meta.value.kind, existing_class.kind) or
            existing_meta.value.write_capability != existing_class.write_capability or
            !grantEntriesEqual(existing_meta.value.write_tables, existing_class.write_tables))
        {
            return ExecError.QueryRegistryCorrupted;
        }
    }

    const existing_qmod = try readFileAlloc(allocator, qmod_path, 16 * 1024 * 1024);
    defer allocator.free(existing_qmod);
    if (!std.mem.eql(u8, existing_qmod, source)) return ExecError.DuplicateRegister;
}

fn tableMetaPath(allocator: std.mem.Allocator, table_name: []const u8) ExecError![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.meta", .{table_name}) catch return ExecError.OutOfMemory;
}

fn schemaPath(allocator: std.mem.Allocator, table_name: []const u8) ExecError![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.sadb-schema", .{table_name}) catch return ExecError.OutOfMemory;
}

fn parseReadGrant(entry: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, entry, "db_read:")) return null;
    const table_name = entry["db_read:".len..];
    if (table_name.len == 0) return null;
    return table_name;
}

fn parseWriteGrant(entry: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, entry, "db_write:")) return null;
    const table_name = entry["db_write:".len..];
    if (table_name.len == 0) return null;
    return table_name;
}

fn parseAtomicGrant(entry: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, entry, "db_atomic_cursor:")) return null;
    const table_name = entry["db_atomic_cursor:".len..];
    if (table_name.len == 0) return null;
    return table_name;
}

fn singleReadGrant(entries: []const []const u8) ExecError!?[]const u8 {
    var out: ?[]const u8 = null;
    for (entries) |entry| {
        if (parseReadGrant(entry)) |table_name| {
            if (out != null) return null;
            out = table_name;
        } else if (std.mem.startsWith(u8, entry, "db_write:") or
            std.mem.startsWith(u8, entry, "db_atomic_cursor:") or
            std.mem.startsWith(u8, entry, "db_alloc_blob:"))
        {
            return null;
        } else return ExecError.InvalidFormat;
    }
    return out;
}

fn singleReadValidationGrant(entries: []const []const u8) ExecError!?[]const u8 {
    var out: ?[]const u8 = null;
    for (entries) |entry| {
        if (parseReadGrant(entry)) |table_name| {
            if (out != null) return ExecError.DbCapabilityEscalation;
            out = table_name;
        } else if (parseWriteGrant(entry) != null or
            std.mem.startsWith(u8, entry, "db_atomic_cursor:") or
            std.mem.startsWith(u8, entry, "db_alloc_blob:"))
        {
            continue;
        } else return ExecError.InvalidFormat;
    }
    return out;
}

const ReadWriteGrant = struct {
    read_table: []const u8,
    write_table: []const u8,
};

fn singleReadWriteGrant(entries: []const []const u8) ExecError!?ReadWriteGrant {
    var read_table: ?[]const u8 = null;
    var write_table: ?[]const u8 = null;
    for (entries) |entry| {
        if (parseReadGrant(entry)) |table_name| {
            if (read_table != null) return ExecError.DbCapabilityEscalation;
            read_table = table_name;
        } else if (parseWriteGrant(entry)) |table_name| {
            if (write_table != null) return ExecError.DbCapabilityEscalation;
            write_table = table_name;
        } else if (std.mem.startsWith(u8, entry, "db_atomic_cursor:") or
            std.mem.startsWith(u8, entry, "db_alloc_blob:"))
        {
            return null;
        } else return ExecError.InvalidFormat;
    }
    const read_name = read_table orelse return null;
    const write_name = write_table orelse return null;
    return .{ .read_table = read_name, .write_table = write_name };
}

fn columnNameFromPointer(param_name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, param_name, "col_")) return null;
    return param_name["col_".len..];
}

fn parseLoadBasePointer(line: []const u8) ExecError!?[]const u8 {
    const eq = std.mem.indexOf(u8, line, " = load ") orelse return null;
    if (!std.mem.endsWith(u8, line, " as u64")) return ExecError.UnsupportedOperation;
    const addr = std.mem.trim(u8, line[eq + " = load ".len .. line.len - " as u64".len], " \t");
    const plus = std.mem.indexOfScalar(u8, addr, '+') orelse return ExecError.UnsupportedOperation;
    return std.mem.trim(u8, addr[0..plus], " \t");
}

fn parseStoreBasePointer(line: []const u8) ExecError!?[]const u8 {
    const rest = if (std.mem.startsWith(u8, line, "store "))
        line["store ".len..]
    else if (std.mem.indexOf(u8, line, " = store ")) |idx|
        line[idx + " = store ".len ..]
    else
        return null;
    const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return ExecError.UnsupportedOperation;
    const addr = std.mem.trim(u8, rest[0..comma], " \t");
    const plus = std.mem.indexOfScalar(u8, addr, '+') orelse return ExecError.UnsupportedOperation;
    return std.mem.trim(u8, addr[0..plus], " \t");
}

fn parseAtomicBasePointer(line: []const u8) ExecError!?[]const u8 {
    const atomic_idx = std.mem.indexOf(u8, line, "atomic_rmw_") orelse return null;
    const rest = line[atomic_idx..];
    const split = std.mem.indexOfAny(u8, rest, " \t") orelse return ExecError.UnsupportedOperation;
    const args = std.mem.trimStart(u8, rest[split..], " \t");
    const comma = std.mem.indexOfScalar(u8, args, ',') orelse return ExecError.UnsupportedOperation;
    const addr = std.mem.trim(u8, args[0..comma], " \t");
    const plus = std.mem.indexOfScalar(u8, addr, '+') orelse return ExecError.UnsupportedOperation;
    return std.mem.trim(u8, addr[0..plus], " \t");
}

fn parseAtomicOffsetToken(line: []const u8) ExecError!?[]const u8 {
    const atomic_idx = std.mem.indexOf(u8, line, "atomic_rmw_") orelse return null;
    const rest = line[atomic_idx..];
    const split = std.mem.indexOfAny(u8, rest, " \t") orelse return ExecError.UnsupportedOperation;
    const args = std.mem.trimStart(u8, rest[split..], " \t");
    const comma = std.mem.indexOfScalar(u8, args, ',') orelse return ExecError.UnsupportedOperation;
    const addr = std.mem.trim(u8, args[0..comma], " \t");
    const plus = std.mem.indexOfScalar(u8, addr, '+') orelse return ExecError.UnsupportedOperation;
    return std.mem.trim(u8, addr[plus + 1 ..], " \t");
}

fn isCursorPointerName(name: []const u8) bool {
    return std.mem.eql(u8, name, "cursor") or std.mem.startsWith(u8, name, "cursor_");
}

fn cursorColumnName(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "cursor")) return null;
    if (!std.mem.startsWith(u8, name, "cursor_")) return null;
    const column_name = name["cursor_".len..];
    if (column_name.len == 0) return null;
    return column_name;
}

fn schemaHasColumn(schema_obj: schema.Schema, column_name: []const u8) bool {
    for (schema_obj.columns) |column| {
        if (std.ascii.eqlIgnoreCase(column.name, column_name)) return true;
    }
    return false;
}

fn collectMainDbPointers(
    allocator: std.mem.Allocator,
    source: []const u8,
    main_name: []const u8,
    allow_cursor: bool,
) ExecError!std.StringHashMap([]const u8) {
    var pointers = std.StringHashMap([]const u8).init(allocator);
    errdefer pointers.deinit();

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = trimLineComment(line);
        if (!std.mem.startsWith(u8, trimmed, "@")) continue;
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse continue;
        if (!std.mem.eql(u8, trimmed[1..open], main_name)) continue;
        const close = std.mem.indexOfScalar(u8, trimmed[open + 1 ..], ')') orelse return ExecError.InvalidFormat;
        const params_text = trimmed[open + 1 .. open + 1 + close];
        var param_it = std.mem.splitScalar(u8, params_text, ',');
        while (param_it.next()) |raw_param| {
            const param = std.mem.trim(u8, raw_param, " \t\r\n");
            if (!std.mem.startsWith(u8, param, "&")) continue;
            const colon = std.mem.indexOfScalar(u8, param, ':') orelse return ExecError.InvalidFormat;
            const raw_name = std.mem.trim(u8, param[1..colon], " \t\r\n");
            const ty = std.mem.trim(u8, param[colon + 1 ..], " \t\r\n");
            if (!std.mem.eql(u8, ty, "ptr")) return ExecError.DbCapabilityEscalation;
            if (columnNameFromPointer(raw_name)) |column_name| {
                pointers.put(raw_name, column_name) catch return ExecError.OutOfMemory;
            } else if (allow_cursor and isCursorPointerName(raw_name)) {
                pointers.put(raw_name, raw_name) catch return ExecError.OutOfMemory;
            } else {
                return ExecError.DbCapabilityEscalation;
            }
        }
        return pointers;
    }
    return pointers;
}

fn verifyReadGrantColumns(allocator: std.mem.Allocator, source: []const u8, grant_entries: []const []const u8) ExecError!void {
    const table_name = try singleReadValidationGrant(grant_entries) orelse return;
    const main_name = findMainName(source);
    var declared_pointers = try collectMainDbPointers(allocator, source, main_name, false);
    defer declared_pointers.deinit();
    var schema_obj: ?schema.Schema = null;
    defer if (schema_obj) |*obj| obj.deinit();

    var saw_load = false;
    var load_it = std.mem.splitScalar(u8, source, '\n');
    while (load_it.next()) |line| {
        const trimmed = trimLineComment(line);
        const ptr_name = (try parseLoadBasePointer(trimmed)) orelse continue;
        saw_load = true;
        const column_name = declared_pointers.get(ptr_name) orelse return ExecError.DbCapabilityEscalation;
        if (schema_obj == null) {
            const path = try schemaPath(allocator, table_name);
            defer allocator.free(path);
            const schema_source = try readFileAlloc(allocator, path, 16 * 1024 * 1024);
            defer allocator.free(schema_source);
            schema_obj = schema.compile(allocator, schema_source, path) catch |err| switch (err) {
                error.OutOfMemory => return ExecError.OutOfMemory,
                else => return ExecError.InvalidFormat,
            };
        }
        if (!schemaHasColumn(schema_obj.?, column_name)) return ExecError.DbCapabilityEscalation;
    }
    if (!saw_load and table_name.len != 0 and std.mem.indexOf(u8, source, " load ") != null) return ExecError.DbCapabilityEscalation;
}

fn singleWriteGrant(entries: []const []const u8) ExecError!?[]const u8 {
    var out: ?[]const u8 = null;
    for (entries) |entry| {
        if (parseWriteGrant(entry)) |table_name| {
            if (out != null) return ExecError.DbCapabilityEscalation;
            out = table_name;
        } else if (parseReadGrant(entry) != null or
            std.mem.startsWith(u8, entry, "db_atomic_cursor:") or
            std.mem.startsWith(u8, entry, "db_alloc_blob:"))
        {
            continue;
        } else return ExecError.InvalidFormat;
    }
    return out;
}

fn verifyWriteGrantColumns(allocator: std.mem.Allocator, source: []const u8, grant_entries: []const []const u8) ExecError!void {
    const table_name = try singleWriteGrant(grant_entries) orelse return;
    const main_name = findMainName(source);
    var declared_pointers = try collectMainDbPointers(allocator, source, main_name, false);
    defer declared_pointers.deinit();
    var schema_obj: ?schema.Schema = null;
    defer if (schema_obj) |*obj| obj.deinit();

    var saw_store = false;
    var store_it = std.mem.splitScalar(u8, source, '\n');
    while (store_it.next()) |line| {
        const trimmed = trimLineComment(line);
        const ptr_name = (try parseStoreBasePointer(trimmed)) orelse continue;
        saw_store = true;
        const column_name = declared_pointers.get(ptr_name) orelse return ExecError.DbCapabilityEscalation;
        if (schema_obj == null) {
            const path = try schemaPath(allocator, table_name);
            defer allocator.free(path);
            const schema_source = try readFileAlloc(allocator, path, 16 * 1024 * 1024);
            defer allocator.free(schema_source);
            schema_obj = schema.compile(allocator, schema_source, path) catch |err| switch (err) {
                error.OutOfMemory => return ExecError.OutOfMemory,
                else => return ExecError.InvalidFormat,
            };
        }
        if (!schemaHasColumn(schema_obj.?, column_name)) return ExecError.DbCapabilityEscalation;
    }
    if (!saw_store and table_name.len != 0 and std.mem.indexOf(u8, source, "store ") != null) return ExecError.DbCapabilityEscalation;
}

fn singleAtomicGrant(entries: []const []const u8) ExecError!?[]const u8 {
    var out: ?[]const u8 = null;
    for (entries) |entry| {
        if (parseAtomicGrant(entry)) |table_name| {
            if (out != null) return ExecError.DbCapabilityEscalation;
            out = table_name;
        } else if (parseReadGrant(entry) != null or parseWriteGrant(entry) != null or
            std.mem.startsWith(u8, entry, "db_alloc_blob:"))
        {
            continue;
        } else return ExecError.InvalidFormat;
    }
    return out;
}

fn verifyAtomicGrantCursors(allocator: std.mem.Allocator, source: []const u8, grant_entries: []const []const u8) ExecError!void {
    const table_name = try singleAtomicGrant(grant_entries) orelse return;
    const path = try schemaPath(allocator, table_name);
    defer allocator.free(path);
    const schema_source = try readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(schema_source);
    var schema_obj = schema.compile(allocator, schema_source, path) catch |err| switch (err) {
        error.OutOfMemory => return ExecError.OutOfMemory,
        else => return ExecError.InvalidFormat,
    };
    defer schema_obj.deinit();

    const main_name = findMainName(source);
    var declared_pointers = try collectMainDbPointers(allocator, source, main_name, true);
    defer declared_pointers.deinit();

    var allowed_pointers = std.StringHashMap(void).init(allocator);
    defer allowed_pointers.deinit();
    var saw_pointer = false;
    var ptr_it = declared_pointers.iterator();
    while (ptr_it.next()) |entry| {
        const raw_name = entry.key_ptr.*;
        if (std.mem.eql(u8, raw_name, "cursor")) {
            if (schema_obj.columns.len == 0) return ExecError.InvalidFormat;
            if (!isAtomicCursorSchemaColumn(schema_obj.columns[0].ty, schema_obj.columns[0].stride)) return ExecError.ColumnTypeMismatch;
            allowed_pointers.put(raw_name, {}) catch return ExecError.OutOfMemory;
            saw_pointer = true;
        } else if (cursorColumnName(raw_name)) |column_name| {
            var matched = false;
            for (schema_obj.columns) |column| {
                if (!std.ascii.eqlIgnoreCase(column.name, column_name)) continue;
                matched = true;
                if (!isAtomicCursorSchemaColumn(column.ty, column.stride)) return ExecError.ColumnTypeMismatch;
                break;
            }
            if (!matched) return ExecError.DbCapabilityEscalation;
            allowed_pointers.put(raw_name, {}) catch return ExecError.OutOfMemory;
            saw_pointer = true;
        }
    }
    if (!saw_pointer and std.mem.indexOf(u8, source, "atomic_rmw_") != null) return ExecError.DbCapabilityEscalation;

    var atomic_it = std.mem.splitScalar(u8, source, '\n');
    while (atomic_it.next()) |line| {
        const trimmed = trimLineComment(line);
        const ptr_name = (try parseAtomicBasePointer(trimmed)) orelse continue;
        const offset_token = (try parseAtomicOffsetToken(trimmed)) orelse return ExecError.DbCapabilityEscalation;
        if (!std.mem.eql(u8, offset_token, "0")) return ExecError.DbCapabilityEscalation;
        if (!allowed_pointers.contains(ptr_name)) return ExecError.DbCapabilityEscalation;
    }
}

fn activeMetaEpoch(allocator: std.mem.Allocator, meta_bytes: []const u8) ExecError!u64 {
    var parsed = std.json.parseFromSlice(QmodTableMeta, allocator, meta_bytes, .{ .allocate = .alloc_always }) catch return ExecError.SnapshotCorrupted;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.magic, "sa-db-table-meta") or parsed.value.version != 1) return ExecError.SnapshotCorrupted;
    return parsed.value.epoch;
}

/// A materialized, immutable copy of one pinned epoch's read
/// columns (perf line; design note in docs/vm_concurrency_epoch.md
/// §9). Built once per (table, epoch, meta-hash) by the first exec
/// that pins the epoch — the build is exactly the legacy per-exec
/// load, including manifest/meta resolution, schema-hash check and
/// full segment hash validation — and then shared by every later
/// exec on the same pin. The snapshot hangs off the epoch pin
/// itself (`EpochPin.attachment`), so its lifetime is the pin's:
/// it is freed by the pin-free hook when the pin is retired and
/// its last holder releases it, never while a reader can still
/// borrow from it. Retained memory uses the page allocator,
/// following the epoch registry precedent, so snapshot lifetimes
/// never couple to a per-exec allocator.
///
/// Semantic note (validation timing): segment bytes and the schema
/// are validated at materialization, not re-validated per exec.
/// Within the storage layer's own operations an epoch's artifacts
/// are immutable — commits write new files and publish by manifest
/// swap — so re-validating identical content-addressed bytes on
/// every exec could only ever re-derive the same verdict. Epoch
/// advance or restore is still adopted immediately: the manifest
/// and meta are re-read on every exec and a different (epoch,
/// meta-hash) never hits the old snapshot. What changes is only
/// the treatment of out-of-band edits to an already-pinned epoch's
/// files mid-flight, which the epoch model places outside its
/// consistency domain (a fresh process — or a fresh epoch —
/// materializes and validates from disk as before).
const Snapshot = struct {
    columns: []TableColumn,
    row_count: u64,
    total_bytes: u64,
};

const snapshot_allocator = std.heap.page_allocator;
/// Snapshots larger than this are not cached; their execs take the
/// legacy per-exec load path and produce identical results. Bounds
/// worst-case retained memory per live pin.
const snapshot_max_bytes: u64 = 256 * 1024 * 1024;
var snapshot_attach_mutex: std.atomic.Mutex = .unlocked;
var snapshot_hook_installed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn freeSnapshotAttachment(pin: *epoch_runtime.EpochPin) void {
    const snapshot: *Snapshot = @ptrCast(@alignCast(pin.attachment.?));
    for (snapshot.columns) |*column| column.deinit(snapshot_allocator);
    snapshot_allocator.free(snapshot.columns);
    snapshot_allocator.destroy(snapshot);
    pin.attachment = null;
}

fn ensureSnapshotHook() void {
    if (!snapshot_hook_installed.swap(true, .acq_rel)) {
        epoch_runtime.pin_free_hook = freeSnapshotAttachment;
    }
}

/// Return the pin's materialized snapshot, building it on first
/// use. Null means the snapshot exceeds the cache size cap and the
/// caller should take the legacy load path. Build errors are the
/// legacy load's errors, propagated unchanged; a failed build
/// leaves nothing attached, so the next exec retries the load (and
/// fails the same way) exactly as the uncached path would.
fn snapshotForPin(table_name: []const u8, pin: *epoch_runtime.EpochPin) ExecError!?*Snapshot {
    ensureSnapshotHook();
    while (!snapshot_attach_mutex.tryLock()) std.atomic.spinLoopHint();
    defer snapshot_attach_mutex.unlock();
    if (pin.attachment) |attachment| {
        const snapshot: *Snapshot = @ptrCast(@alignCast(attachment));
        return snapshot;
    }
    var built = try loadReadTableFromMeta(snapshot_allocator, table_name, pin.meta_source);
    var total: u64 = 0;
    for (built.columns) |column| total += @as(u64, column.bytes.len);
    if (total > snapshot_max_bytes) {
        built.deinit(snapshot_allocator);
        return null;
    }
    const snapshot = snapshot_allocator.create(Snapshot) catch {
        built.deinit(snapshot_allocator);
        return ExecError.OutOfMemory;
    };
    snapshot.* = .{ .columns = built.columns, .row_count = built.row_count, .total_bytes = total };
    snapshot_allocator.free(built.name);
    pin.attachment = snapshot;
    return snapshot;
}

/// Read-side load under the epoch protocol (docs/vm_concurrency_epoch.md
/// §3.1): resolve the active meta through the manifest, pin that epoch
/// in the in-process runtime, and serve the exec from the pinned
/// epoch's materialized snapshot (see Snapshot above). The pin hold
/// transfers to the returned ReadTable and is released by its
/// deinit, so borrowed snapshot bytes stay live for the whole exec;
/// a concurrent commit swaps in a new epoch without disturbing this
/// exec. Epochs whose snapshots exceed the cache cap take the
/// legacy path: bytes are loaded and hash-validated per exec and
/// the pin is released when the load window closes, as before.
fn loadReadTable(allocator: std.mem.Allocator, table_name: []const u8) ExecError!ReadTable {
    const t_source = ScopedTimer.begin(.table_meta_source);
    const meta_bytes = try readActiveTableMetaSource(allocator, table_name);
    t_source.end();
    defer allocator.free(meta_bytes);
    const t_parse = ScopedTimer.begin(.table_meta_parse_pin);
    const epoch = try activeMetaEpoch(allocator, meta_bytes);
    const pin = epoch_runtime.pinLatest(table_name, meta_bytes, epoch, hashBytes(meta_bytes)) catch return ExecError.OutOfMemory;
    t_parse.end();
    const snapshot = snapshotForPin(table_name, pin) catch |err| {
        epoch_runtime.release(table_name, pin);
        return err;
    };
    if (snapshot) |snap| {
        const out = ReadTable{
            .name = allocator.dupe(u8, table_name) catch {
                epoch_runtime.release(table_name, pin);
                return ExecError.OutOfMemory;
            },
            .row_count = snap.row_count,
            .columns = allocator.alloc(TableColumn, snap.columns.len) catch {
                epoch_runtime.release(table_name, pin);
                return ExecError.OutOfMemory;
            },
            .pin = pin,
            .pin_table_name = table_name,
        };
        for (snap.columns, out.columns) |*src_column, *dst_column| {
            dst_column.* = .{
                .name = src_column.name,
                .ty = src_column.ty,
                .stride = src_column.stride,
                .bytes = src_column.bytes,
                .owned = false,
            };
        }
        return out;
    }
    defer epoch_runtime.release(table_name, pin);
    return loadReadTableFromMeta(allocator, table_name, pin.meta_source);
}

fn loadReadTableFromMeta(allocator: std.mem.Allocator, table_name: []const u8, meta_bytes: []const u8) ExecError!ReadTable {
    const t_parse2 = ScopedTimer.begin(.table_meta_parse_pin);
    var parsed = std.json.parseFromSlice(QmodTableMeta, allocator, meta_bytes, .{ .allocate = .alloc_always }) catch return ExecError.SnapshotCorrupted;
    t_parse2.end();
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.magic, "sa-db-table-meta") or parsed.value.version != 1) return ExecError.SnapshotCorrupted;
    if (!std.mem.eql(u8, parsed.value.table_name, table_name)) return ExecError.SnapshotCorrupted;

    const t_schema = ScopedTimer.begin(.table_schema);
    const current_schema_path = try schemaPath(allocator, table_name);
    defer allocator.free(current_schema_path);
    const current_schema = try readFileAlloc(allocator, current_schema_path, 1024 * 1024);
    defer allocator.free(current_schema);
    const current_schema_hash = hashHex(current_schema);
    t_schema.end();
    if (!std.mem.eql(u8, current_schema_hash[0..], parsed.value.schema_hash)) return ExecError.SchemaMismatch;

    var out = ReadTable{
        .name = allocator.dupe(u8, table_name) catch return ExecError.OutOfMemory,
        .row_count = parsed.value.row_count,
        .columns = allocator.alloc(TableColumn, parsed.value.columns.len) catch return ExecError.OutOfMemory,
    };
    errdefer out.deinit(allocator);
    for (out.columns) |*column| column.* = .{ .name = &.{}, .ty = &.{}, .stride = 0, .bytes = &.{} };

    for (parsed.value.columns, 0..) |meta_column, col_idx| {
        if (!isReadableColumn(meta_column.ty, meta_column.stride)) return ExecError.UnsupportedOperation;
        var merged = std.array_list.Managed(u8).init(allocator);
        errdefer merged.deinit();
        for (parsed.value.segments) |segment| {
            if (segment.files.len != parsed.value.columns.len) return ExecError.SnapshotCorrupted;
            const file_meta = segment.files[col_idx];
            const t_read = ScopedTimer.begin(.segment_read);
            const bytes = try readFileAlloc(allocator, file_meta.path, 1 << 30);
            t_read.end();
            defer allocator.free(bytes);
            const t_validate = ScopedTimer.begin(.segment_validate);
            try validateQmodFileBytes(file_meta, bytes);
            t_validate.end();
            if (bytes.len != segment.rows * meta_column.stride) return ExecError.SnapshotCorrupted;
            const t_copy = ScopedTimer.begin(.segment_copy);
            merged.appendSlice(bytes) catch return ExecError.OutOfMemory;
            t_copy.end();
        }
        out.columns[col_idx] = .{
            .name = allocator.dupe(u8, meta_column.name) catch return ExecError.OutOfMemory,
            .ty = allocator.dupe(u8, meta_column.ty) catch return ExecError.OutOfMemory,
            .stride = meta_column.stride,
            .bytes = merged.toOwnedSlice() catch return ExecError.OutOfMemory,
        };
    }
    return out;
}

fn validateCurrentSchemaHash(allocator: std.mem.Allocator, table_name: []const u8, expected_hash: []const u8) ExecError!void {
    const current_schema_path = try schemaPath(allocator, table_name);
    defer allocator.free(current_schema_path);
    const current_schema = try readFileAlloc(allocator, current_schema_path, 1024 * 1024);
    defer allocator.free(current_schema);
    const current_schema_hash = hashHex(current_schema);
    if (!std.mem.eql(u8, current_schema_hash[0..], expected_hash)) return ExecError.SchemaMismatch;
}

fn loadWriteTable(allocator: std.mem.Allocator, table_name: []const u8) ExecError!WriteTable {
    const meta_path = try tableMetaPath(allocator, table_name);
    errdefer allocator.free(meta_path);
    const meta_bytes = try readActiveTableMetaSource(allocator, table_name);
    defer allocator.free(meta_bytes);
    var parsed = std.json.parseFromSlice(QmodTableMeta, allocator, meta_bytes, .{ .allocate = .alloc_always }) catch return ExecError.SnapshotCorrupted;
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.magic, "sa-db-table-meta") or parsed.value.version != 1) return ExecError.SnapshotCorrupted;
    if (!std.mem.eql(u8, parsed.value.table_name, table_name)) return ExecError.SnapshotCorrupted;
    if (parsed.value.locked) return ExecError.Locked;
    try validateCurrentSchemaHash(allocator, table_name, parsed.value.schema_hash);

    var out = WriteTable{
        .meta_path = meta_path,
        .parsed = parsed,
        .row_count = parsed.value.row_count,
        .columns = allocator.alloc(WriteColumn, parsed.value.columns.len) catch return ExecError.OutOfMemory,
    };
    errdefer out.deinit(allocator);
    for (out.columns) |*column| column.* = .{ .name = &.{}, .ty = &.{}, .stride = 0, .segments = &.{} };

    for (out.parsed.value.columns, 0..) |meta_column, col_idx| {
        if (!isReadableColumn(meta_column.ty, meta_column.stride)) return ExecError.UnsupportedOperation;
        const segments = allocator.alloc(WriteColumnSegment, out.parsed.value.segments.len) catch return ExecError.OutOfMemory;
        errdefer allocator.free(segments);
        for (segments) |*segment| segment.* = .{ .path = &.{}, .rows = 0, .bytes = &.{}, .dirty = false };
        for (out.parsed.value.segments, 0..) |segment_meta, seg_idx| {
            if (segment_meta.files.len != out.parsed.value.columns.len) return ExecError.SnapshotCorrupted;
            const file_meta = segment_meta.files[col_idx];
            const bytes = try readFileAlloc(allocator, file_meta.path, 1 << 30);
            errdefer allocator.free(bytes);
            try validateQmodFileBytes(file_meta, bytes);
            if (bytes.len != segment_meta.rows * meta_column.stride) return ExecError.SnapshotCorrupted;
            segments[seg_idx] = .{ .path = file_meta.path, .rows = segment_meta.rows, .bytes = bytes };
        }
        out.columns[col_idx] = .{
            .name = meta_column.name,
            .ty = meta_column.ty,
            .stride = meta_column.stride,
            .segments = segments,
        };
    }
    return out;
}

fn isReadableColumn(ty: []const u8, stride: u32) bool {
    return (std.mem.eql(u8, ty, "u64") and stride == 8) or
        (std.mem.eql(u8, ty, "u32") and stride == 4) or
        (std.mem.eql(u8, ty, "u16") and stride == 2) or
        (std.mem.eql(u8, ty, "u8") and stride == 1) or
        (std.mem.eql(u8, ty, "i64") and stride == 8) or
        (std.mem.eql(u8, ty, "i32") and stride == 4) or
        (std.mem.eql(u8, ty, "i16") and stride == 2) or
        (std.mem.eql(u8, ty, "i8") and stride == 1) or
        (std.mem.eql(u8, ty, "f64") and stride == 8) or
        (std.mem.eql(u8, ty, "f32") and stride == 4);
}

fn isAtomicCursorColumn(ty: []const u8, stride: u32) bool {
    return std.mem.eql(u8, ty, "u64") and stride == 8;
}

fn isAtomicCursorSchemaColumn(ty: ?schema.PrimType, stride: u32) bool {
    return ty == .u64 and stride == 8;
}

fn findColumn(read_table: ReadTable, name: []const u8) ?*const TableColumn {
    for (read_table.columns) |*column| {
        if (std.ascii.eqlIgnoreCase(column.name, name)) return column;
    }
    return null;
}

fn findWriteColumn(write_table: *WriteTable, name: []const u8) ?*WriteColumn {
    for (write_table.columns) |*column| {
        if (std.ascii.eqlIgnoreCase(column.name, name)) return column;
    }
    return null;
}

fn loadColumnValue(column: TableColumn, offset: u64) ExecError!u64 {
    if (!isReadableColumn(column.ty, column.stride)) return ExecError.UnsupportedOperation;
    if (offset > column.bytes.len or column.bytes.len - @as(usize, @intCast(offset)) < column.stride) return ExecError.InvalidFormat;
    const idx: usize = @intCast(offset);
    if (std.mem.eql(u8, column.ty, "u64")) return std.mem.readInt(u64, column.bytes[idx..][0..8], .little);
    if (std.mem.eql(u8, column.ty, "u32")) return std.mem.readInt(u32, column.bytes[idx..][0..4], .little);
    if (std.mem.eql(u8, column.ty, "u16")) return std.mem.readInt(u16, column.bytes[idx..][0..2], .little);
    if (std.mem.eql(u8, column.ty, "u8")) return column.bytes[idx];
    if (std.mem.eql(u8, column.ty, "i64")) return @bitCast(std.mem.readInt(i64, column.bytes[idx..][0..8], .little));
    if (std.mem.eql(u8, column.ty, "i32")) return @bitCast(@as(i64, std.mem.readInt(i32, column.bytes[idx..][0..4], .little)));
    if (std.mem.eql(u8, column.ty, "i16")) return @bitCast(@as(i64, std.mem.readInt(i16, column.bytes[idx..][0..2], .little)));
    if (std.mem.eql(u8, column.ty, "i8")) return @bitCast(@as(i64, @as(i8, @bitCast(column.bytes[idx]))));
    if (std.mem.eql(u8, column.ty, "f64")) return std.mem.readInt(u64, column.bytes[idx..][0..8], .little);
    if (std.mem.eql(u8, column.ty, "f32")) {
        const bits = std.mem.readInt(u32, column.bytes[idx..][0..4], .little);
        return @bitCast(@as(f64, @floatCast(@as(f32, @bitCast(bits)))));
    }
    return ExecError.UnsupportedOperation;
}

/// The value kind of a readable column, resolved once per primitive
/// call instead of re-dispatching on the type string for every row
/// (perf line: the per-row string dispatch in `loadColumnValue`
/// dominated scan primitives — 20k rows × ~10 `mem.eql` each).
/// Resolution mirrors `isReadableColumn` + the dispatch order of
/// `loadColumnValue` exactly, and `loadColumnValueKind` reproduces
/// `loadColumnValue`'s value for every kind bit-for-bit, so scan
/// results are unchanged; only the dispatch cost moves out of the
/// loop. Callers must guarantee `offset + stride <= bytes.len`
/// (the primitive row limit already does).
const ColumnKind = enum { u64_, u32_, u16_, u8_, i64_, i32_, i16_, i8_, f64_, f32_ };

fn columnKind(ty: []const u8, stride: u32) ?ColumnKind {
    if (!isReadableColumn(ty, stride)) return null;
    if (std.mem.eql(u8, ty, "u64")) return .u64_;
    if (std.mem.eql(u8, ty, "u32")) return .u32_;
    if (std.mem.eql(u8, ty, "u16")) return .u16_;
    if (std.mem.eql(u8, ty, "u8")) return .u8_;
    if (std.mem.eql(u8, ty, "i64")) return .i64_;
    if (std.mem.eql(u8, ty, "i32")) return .i32_;
    if (std.mem.eql(u8, ty, "i16")) return .i16_;
    if (std.mem.eql(u8, ty, "i8")) return .i8_;
    if (std.mem.eql(u8, ty, "f64")) return .f64_;
    if (std.mem.eql(u8, ty, "f32")) return .f32_;
    return null;
}

fn loadColumnValueKind(kind: ColumnKind, bytes: []const u8, offset: usize) u64 {
    // Reads go through fixed-size array pointers: `readInt` on a
    // runtime slice (`bytes[offset..][0..8]`) compiles to a byte-wise
    // fallback in this toolchain (measured ~25 ns/read vs ~1 ns),
    // while the array-pointer form has statically known size and
    // alignment and compiles to a single unaligned load. Values are
    // identical either way (little-endian file layout).
    return switch (kind) {
        .u64_ => std.mem.readInt(u64, @ptrCast(bytes.ptr + offset), .little),
        .u32_ => std.mem.readInt(u32, @ptrCast(bytes.ptr + offset), .little),
        .u16_ => std.mem.readInt(u16, @ptrCast(bytes.ptr + offset), .little),
        .u8_ => bytes[offset],
        .i64_ => @bitCast(std.mem.readInt(i64, @ptrCast(bytes.ptr + offset), .little)),
        .i32_ => @bitCast(@as(i64, std.mem.readInt(i32, @ptrCast(bytes.ptr + offset), .little))),
        .i16_ => @bitCast(@as(i64, std.mem.readInt(i16, @ptrCast(bytes.ptr + offset), .little))),
        .i8_ => @bitCast(@as(i64, @as(i8, @bitCast(bytes[offset])))),
        .f64_ => std.mem.readInt(u64, @ptrCast(bytes.ptr + offset), .little),
        .f32_ => @bitCast(@as(f64, @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, @ptrCast(bytes.ptr + offset), .little)))))),
    };
}

/// Whole-column scan operations for the read primitives. The fold
/// runs over a typed word slice whenever the column buffer is
/// aligned for the word size (our own allocations are; a runtime
/// check keeps unaligned buffers correct), which lets the compiler
/// vectorize the loop — measured ~20x faster than per-row scalar
/// loads for a 20k-row u64 sum. The unaligned path folds over an
/// `align(1)` word slice with the same conversions, so results are
/// bit-for-bit identical on every path: each kind's conversion is
/// exactly `loadColumnValueKind`'s. `.min`/`.max` require
/// rows >= 1 (callers reject rows == 0 first, as before) and seed
/// from row 0, matching the legacy loops.
const ScanOp = union(enum) {
    sum,
    min,
    max,
    count_eq: u64,
    count_range: struct { lo: u64, hi: u64 },
};

fn scanConvert(comptime kind: ColumnKind, word: anytype) u64 {
    return switch (kind) {
        .u64_, .i64_, .f64_, .u32_, .u16_, .u8_ => @as(u64, word),
        .i32_ => @bitCast(@as(i64, @as(i32, @bitCast(word)))),
        .i16_ => @bitCast(@as(i64, @as(i16, @bitCast(word)))),
        .i8_ => @bitCast(@as(i64, @as(i8, @bitCast(word)))),
        .f32_ => @bitCast(@as(f64, @floatCast(@as(f32, @bitCast(word))))),
    };
}

fn foldWords(comptime kind: ColumnKind, words: anytype, op: ScanOp) u64 {
    switch (op) {
        .sum => {
            var acc: u64 = 0;
            for (words) |word| acc +%= scanConvert(kind, word);
            return acc;
        },
        .min => {
            var acc: u64 = scanConvert(kind, words[0]);
            for (words[1..]) |word| {
                const value = scanConvert(kind, word);
                if (value < acc) acc = value;
            }
            return acc;
        },
        .max => {
            var acc: u64 = scanConvert(kind, words[0]);
            for (words[1..]) |word| {
                const value = scanConvert(kind, word);
                if (value > acc) acc = value;
            }
            return acc;
        },
        .count_eq => |target| {
            var count: u64 = 0;
            for (words) |word| {
                if (scanConvert(kind, word) == target) count += 1;
            }
            return count;
        },
        .count_range => |range| {
            var count: u64 = 0;
            for (words) |word| {
                const value = scanConvert(kind, word);
                if (value >= range.lo and value < range.hi) count += 1;
            }
            return count;
        },
    }
}

fn scanKind(comptime kind: ColumnKind, comptime W: type, bytes: []const u8, rows: u64, op: ScanOp) u64 {
    const n: usize = @intCast(rows);
    if (comptime @import("builtin").cpu.arch.endian() == .little) {
        if (@intFromPtr(bytes.ptr) % @sizeOf(W) == 0) {
            // bytesAsSlice returns an align(1) slice in this
            // toolchain, which silently blocks vectorization; the
            // runtime check above proves the natural alignment, so
            // restore it explicitly (measured ~10x on a 20k sum).
            const words: []const W = @alignCast(std.mem.bytesAsSlice(W, bytes[0 .. n * @sizeOf(W)]));
            return foldWords(kind, words, op);
        }
    }
    const base: [*]align(1) const W = @ptrCast(bytes.ptr);
    return foldWords(kind, base[0..n], op);
}

fn scanOp(kind: ColumnKind, bytes: []const u8, rows: u64, op: ScanOp) u64 {
    const t_scan = ScopedTimer.begin(.scan_fold);
    defer t_scan.end();
    return switch (kind) {
        .u64_ => scanKind(.u64_, u64, bytes, rows, op),
        .i64_ => scanKind(.i64_, u64, bytes, rows, op),
        .f64_ => scanKind(.f64_, u64, bytes, rows, op),
        .u32_ => scanKind(.u32_, u32, bytes, rows, op),
        .i32_ => scanKind(.i32_, u32, bytes, rows, op),
        .f32_ => scanKind(.f32_, u32, bytes, rows, op),
        .u16_ => scanKind(.u16_, u16, bytes, rows, op),
        .i16_ => scanKind(.i16_, u16, bytes, rows, op),
        .u8_ => scanKind(.u8_, u8, bytes, rows, op),
        .i8_ => scanKind(.i8_, u8, bytes, rows, op),
    };
}

fn storeColumnValue(column: *WriteColumn, offset: u64, value: u64) ExecError!void {
    if (!isReadableColumn(column.ty, column.stride)) return ExecError.UnsupportedOperation;
    var base: u64 = 0;
    for (column.segments) |*segment| {
        const segment_bytes = segment.rows * column.stride;
        if (offset >= base and offset < base + segment_bytes) {
            const local_offset = offset - base;
            if (local_offset > segment.bytes.len or segment.bytes.len - @as(usize, @intCast(local_offset)) < column.stride) return ExecError.InvalidFormat;
            const idx: usize = @intCast(local_offset);
            if (std.mem.eql(u8, column.ty, "u64")) std.mem.writeInt(u64, segment.bytes[idx..][0..8], value, .little) else if (std.mem.eql(u8, column.ty, "u32")) std.mem.writeInt(u32, segment.bytes[idx..][0..4], std.math.cast(u32, value) orelse return ExecError.InvalidFormat, .little) else if (std.mem.eql(u8, column.ty, "u16")) std.mem.writeInt(u16, segment.bytes[idx..][0..2], std.math.cast(u16, value) orelse return ExecError.InvalidFormat, .little) else if (std.mem.eql(u8, column.ty, "u8")) segment.bytes[idx] = std.math.cast(u8, value) orelse return ExecError.InvalidFormat else if (std.mem.eql(u8, column.ty, "i64")) std.mem.writeInt(i64, segment.bytes[idx..][0..8], @bitCast(value), .little) else if (std.mem.eql(u8, column.ty, "i32")) std.mem.writeInt(i32, segment.bytes[idx..][0..4], std.math.cast(i32, @as(i64, @bitCast(value))) orelse return ExecError.InvalidFormat, .little) else if (std.mem.eql(u8, column.ty, "i16")) std.mem.writeInt(i16, segment.bytes[idx..][0..2], std.math.cast(i16, @as(i64, @bitCast(value))) orelse return ExecError.InvalidFormat, .little) else if (std.mem.eql(u8, column.ty, "i8")) segment.bytes[idx] = @bitCast(std.math.cast(i8, @as(i64, @bitCast(value))) orelse return ExecError.InvalidFormat) else if (std.mem.eql(u8, column.ty, "f64")) std.mem.writeInt(u64, segment.bytes[idx..][0..8], value, .little) else if (std.mem.eql(u8, column.ty, "f32")) std.mem.writeInt(u32, segment.bytes[idx..][0..4], @bitCast(@as(f32, @floatCast(@as(f64, @bitCast(value))))), .little) else return ExecError.UnsupportedOperation;
            segment.dirty = true;
            return;
        }
        base += segment_bytes;
    }
    return ExecError.InvalidFormat;
}

fn countLinesWithPrefix(source: []const u8, prefix: []const u8) u64 {
    var count: u64 = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, prefix)) count += 1;
    }
    return count;
}

fn countGrantEntries(source: []const u8) u64 {
    var count: u64 = 0;
    var search = source;
    while (std.mem.indexOf(u8, search, "grants [")) |idx| {
        const rest = search[idx + "grants [".len ..];
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse break;
        const body = std.mem.trim(u8, rest[0..close], " \t\r\n");
        if (body.len != 0) {
            count += 1;
            for (body) |c| {
                if (c == ',') count += 1;
            }
        }
        search = rest[close + 1 ..];
    }
    return count;
}

fn trimLineComment(line: []const u8) []const u8 {
    const body = if (std.mem.indexOf(u8, line, "//")) |idx| line[0..idx] else line;
    return std.mem.trim(u8, body, " \t\r\n");
}

fn appendGrantEntry(allocator: std.mem.Allocator, entries: *std.array_list.Managed([]u8), entry: []const u8) ExecError!void {
    const trimmed = std.mem.trim(u8, entry, " \t\r\n");
    if (trimmed.len == 0) return;
    entries.append(allocator.dupe(u8, trimmed) catch return ExecError.OutOfMemory) catch return ExecError.OutOfMemory;
}

fn parseGrants(allocator: std.mem.Allocator, source: []const u8) ExecError!GrantSet {
    var entries = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit();
    }

    var search = source;
    while (std.mem.indexOf(u8, search, "grants [")) |idx| {
        const rest = search[idx + "grants [".len ..];
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return ExecError.InvalidFormat;
        var entry_it = std.mem.splitScalar(u8, rest[0..close], ',');
        while (entry_it.next()) |entry| try appendGrantEntry(allocator, &entries, entry);
        search = rest[close + 1 ..];
    }

    var out = GrantSet{ .entries = try entries.toOwnedSlice() };
    errdefer out.deinit(allocator);
    for (out.entries) |entry| {
        if (std.mem.startsWith(u8, entry, "db_read:")) out.db_read = true else if (std.mem.startsWith(u8, entry, "db_write:")) out.db_write = true else if (std.mem.startsWith(u8, entry, "db_atomic_cursor:")) out.db_atomic_cursor = true else if (std.mem.startsWith(u8, entry, "db_alloc_blob:")) out.db_alloc_blob = true else return ExecError.InvalidFormat;
    }
    return out;
}

fn isLoadInstruction(line: []const u8) bool {
    return std.mem.indexOf(u8, line, " = load ") != null or std.mem.startsWith(u8, line, "load ");
}

fn isStoreInstruction(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "store ") or std.mem.indexOf(u8, line, " = store ") != null;
}

fn isAtomicInstruction(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "atomic_rmw_") or std.mem.indexOf(u8, line, " = atomic_rmw_") != null;
}

fn verifyDbGrants(source: []const u8, grants: GrantSet) ExecError!void {
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        const line = trimLineComment(raw_line);
        if (line.len == 0 or std.mem.startsWith(u8, line, "@") or std.mem.startsWith(u8, line, "grants [") or std.mem.endsWith(u8, line, ":")) continue;
        if (isAtomicInstruction(line) and !grants.db_atomic_cursor) return ExecError.DbCapabilityEscalation;
        if (isStoreInstruction(line) and !grants.db_write) return ExecError.DbCapabilityEscalation;
        if (isLoadInstruction(line) and !grants.db_read) return ExecError.DbCapabilityEscalation;
    }
}

fn findMainName(source: []const u8) []const u8 {
    var first_name: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "@")) continue;
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse continue;
        const name = trimmed[1..open];
        if (std.mem.eql(u8, name, "main")) return name;
        if (first_name == null) first_name = name;
    }
    return first_name orelse "main";
}

fn parseFunctionSig(allocator: std.mem.Allocator, source: []const u8, expected_name: []const u8) ExecError!FunctionSig {
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = trimLineComment(line);
        if (!std.mem.startsWith(u8, trimmed, "@")) continue;
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse continue;
        const close = std.mem.indexOfScalar(u8, trimmed[open + 1 ..], ')') orelse return ExecError.InvalidFormat;
        const name = trimmed[1..open];
        if (!std.mem.eql(u8, name, expected_name)) continue;
        const params_text = trimmed[open + 1 .. open + 1 + close];
        var params = std.array_list.Managed([]const u8).init(allocator);
        errdefer params.deinit();
        var param_it = std.mem.splitScalar(u8, params_text, ',');
        while (param_it.next()) |raw_param| {
            const param = std.mem.trim(u8, raw_param, " \t\r\n");
            if (param.len == 0) continue;
            if (std.mem.indexOfScalar(u8, param, '&') != null) return ExecError.UnsupportedOperation;
            const colon = std.mem.indexOfScalar(u8, param, ':') orelse return ExecError.InvalidFormat;
            const name_text = std.mem.trim(u8, param[0..colon], " \t\r\n");
            const ty_text = std.mem.trim(u8, param[colon + 1 ..], " \t\r\n");
            if (!std.mem.eql(u8, ty_text, "u64")) return ExecError.UnsupportedOperation;
            params.append(name_text) catch return ExecError.OutOfMemory;
        }
        return .{ .name = name, .params = params.toOwnedSlice() catch return ExecError.OutOfMemory };
    }
    return ExecError.InvalidFormat;
}

fn readScalarParams(allocator: std.mem.Allocator, params_path: ?[]const u8, count: usize) ExecError![]u64 {
    const values = allocator.alloc(u64, count) catch return ExecError.OutOfMemory;
    errdefer allocator.free(values);
    if (count == 0) return values;
    const path = params_path orelse return ExecError.InvalidParams;
    const bytes = try readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(bytes);
    if (bytes.len != count * @sizeOf(u64)) return ExecError.InvalidParams;
    for (values, 0..) |*value, idx| {
        const offset = idx * @sizeOf(u64);
        value.* = std.mem.readInt(u64, bytes[offset..][0..8], .little);
    }
    return values;
}

fn lookupValue(values: *ValueMap, token: []const u8) ExecError!u64 {
    if (values.get(token)) |value| return value;
    return std.fmt.parseInt(u64, token, 10) catch return ExecError.UnsupportedOperation;
}

fn boolU64(value: bool) u64 {
    return if (value) 1 else 0;
}

fn evalBinaryU64(op: []const u8, lhs: u64, rhs: u64) ExecError!u64 {
    if (std.mem.eql(u8, op, "add")) return lhs +% rhs;
    if (std.mem.eql(u8, op, "sub")) return lhs -% rhs;
    if (std.mem.eql(u8, op, "mul")) return lhs *% rhs;
    if (std.mem.eql(u8, op, "and")) return lhs & rhs;
    if (std.mem.eql(u8, op, "or")) return lhs | rhs;
    if (std.mem.eql(u8, op, "xor")) return lhs ^ rhs;
    if (std.mem.eql(u8, op, "shl")) return lhs << @as(u6, @intCast(rhs & 63));
    if (std.mem.eql(u8, op, "lshr")) return lhs >> @as(u6, @intCast(rhs & 63));
    if (std.mem.eql(u8, op, "eq")) return boolU64(lhs == rhs);
    if (std.mem.eql(u8, op, "ne")) return boolU64(lhs != rhs);
    if (std.mem.eql(u8, op, "ult")) return boolU64(lhs < rhs);
    if (std.mem.eql(u8, op, "ule")) return boolU64(lhs <= rhs);
    if (std.mem.eql(u8, op, "ugt")) return boolU64(lhs > rhs);
    if (std.mem.eql(u8, op, "uge")) return boolU64(lhs >= rhs);
    return ExecError.UnsupportedOperation;
}

fn evalBinaryValue(op: []const u8, lhs: u64, rhs: u64) ExecError!u64 {
    if (std.mem.startsWith(u8, op, "fcmp_")) {
        const lf: f64 = @bitCast(lhs);
        const rf: f64 = @bitCast(rhs);
        const cmp = op["fcmp_".len..];
        if (std.mem.eql(u8, cmp, "gt")) return boolU64(lf > rf);
        if (std.mem.eql(u8, cmp, "ge")) return boolU64(lf >= rf);
        if (std.mem.eql(u8, cmp, "lt")) return boolU64(lf < rf);
        if (std.mem.eql(u8, cmp, "le")) return boolU64(lf <= rf);
        if (std.mem.eql(u8, cmp, "eq")) return boolU64(lf == rf);
        if (std.mem.eql(u8, cmp, "ne")) return boolU64(lf != rf);
        return ExecError.UnsupportedOperation;
    }
    return evalBinaryU64(op, lhs, rhs);
}

fn evalScalarQmod(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8, params_path: ?[]const u8, meter: *FuelMeter) ExecError!?u64 {
    if (std.mem.indexOf(u8, source, " load ") != null or
        std.mem.indexOf(u8, source, "store ") != null or
        std.mem.indexOf(u8, source, "atomic_rmw_") != null or
        std.mem.indexOf(u8, source, "br ") != null or
        std.mem.indexOf(u8, source, "jmp ") != null)
    {
        return null;
    }

    var sig = parseFunctionSig(allocator, source, main_name) catch |err| switch (err) {
        ExecError.UnsupportedOperation => return null,
        else => return err,
    };
    defer sig.deinit(allocator);
    const params = try readScalarParams(allocator, params_path, sig.params.len);
    defer allocator.free(params);

    var values = ValueMap.init(allocator);
    defer values.deinit();
    for (sig.params, 0..) |param, idx| {
        values.put(param, params[idx]) catch return ExecError.OutOfMemory;
    }

    var in_body = false;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        const line = trimLineComment(raw_line);
        if (line.len == 0 or std.mem.startsWith(u8, line, "@import") or std.mem.startsWith(u8, line, "grants [")) continue;
        if (std.mem.startsWith(u8, line, "@")) {
            in_body = std.mem.startsWith(u8, line[1..], main_name);
            continue;
        }
        if (!in_body or std.mem.endsWith(u8, line, ":")) continue;
        try meter.charge(1);
        if (std.mem.startsWith(u8, line, "return ")) {
            return try lookupValue(&values, std.mem.trim(u8, line["return ".len..], " \t\r\n"));
        }
        const eq = std.mem.indexOf(u8, line, " = ") orelse return ExecError.UnsupportedOperation;
        const dst = std.mem.trim(u8, line[0..eq], " \t\r\n");
        const expr = std.mem.trim(u8, line[eq + 3 ..], " \t\r\n");
        var parts = std.mem.tokenizeAny(u8, expr, " ,\t");
        const op = parts.next() orelse return ExecError.InvalidFormat;
        const lhs_text = parts.next() orelse return ExecError.InvalidFormat;
        const rhs_text = parts.next() orelse return ExecError.InvalidFormat;
        if (parts.next() != null) return ExecError.UnsupportedOperation;
        const lhs = try lookupValue(&values, lhs_text);
        const rhs = try lookupValue(&values, rhs_text);
        const value = try evalBinaryValue(op, lhs, rhs);
        values.put(dst, value) catch return ExecError.OutOfMemory;
    }
    return ExecError.InvalidFormat;
}

fn parseDbFunctionParams(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8, read_table: ReadTable, params_path: ?[]const u8, values: *ValueMap, pointers: *std.StringHashMap(*const TableColumn)) ExecError!void {
    var params = ParamCursor{ .allocator = allocator, .params_path = params_path };
    defer params.deinit();
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = trimLineComment(line);
        if (!std.mem.startsWith(u8, trimmed, "@")) continue;
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse continue;
        if (!std.mem.eql(u8, trimmed[1..open], main_name)) continue;
        const close = std.mem.indexOfScalar(u8, trimmed[open + 1 ..], ')') orelse return ExecError.InvalidFormat;
        const params_text = trimmed[open + 1 .. open + 1 + close];
        var param_it = std.mem.splitScalar(u8, params_text, ',');
        while (param_it.next()) |raw_param| {
            const param = std.mem.trim(u8, raw_param, " \t\r\n");
            if (param.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, param, ':') orelse return ExecError.InvalidFormat;
            const raw_name = std.mem.trim(u8, param[0..colon], " \t\r\n");
            const ty = std.mem.trim(u8, param[colon + 1 ..], " \t\r\n");
            if (std.mem.startsWith(u8, raw_name, "&")) {
                if (!std.mem.eql(u8, ty, "ptr")) return ExecError.UnsupportedOperation;
                const param_name = std.mem.trimStart(u8, raw_name[1..], " \t");
                const column_name = columnNameFromPointer(param_name) orelse return ExecError.UnsupportedOperation;
                const column = findColumn(read_table, column_name) orelse return ExecError.InvalidFormat;
                pointers.put(param_name, column) catch return ExecError.OutOfMemory;
            } else if (std.mem.eql(u8, raw_name, "len") and std.mem.eql(u8, ty, "u64")) {
                values.put(raw_name, read_table.row_count) catch return ExecError.OutOfMemory;
            } else if (std.mem.eql(u8, ty, "u64")) {
                const value = try params.readU64();
                values.put(raw_name, value) catch return ExecError.OutOfMemory;
            } else return ExecError.UnsupportedOperation;
        }
        try params.finish();
        return;
    }
    return ExecError.InvalidFormat;
}

fn parseWriteDbFunctionParams(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8, write_table: *WriteTable, params_path: ?[]const u8, values: *ValueMap, pointers: *std.StringHashMap(*WriteColumn)) ExecError!void {
    var params = ParamCursor{ .allocator = allocator, .params_path = params_path };
    defer params.deinit();
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = trimLineComment(line);
        if (!std.mem.startsWith(u8, trimmed, "@")) continue;
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse continue;
        if (!std.mem.eql(u8, trimmed[1..open], main_name)) continue;
        const close = std.mem.indexOfScalar(u8, trimmed[open + 1 ..], ')') orelse return ExecError.InvalidFormat;
        const params_text = trimmed[open + 1 .. open + 1 + close];
        var param_it = std.mem.splitScalar(u8, params_text, ',');
        while (param_it.next()) |raw_param| {
            const param = std.mem.trim(u8, raw_param, " \t\r\n");
            if (param.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, param, ':') orelse return ExecError.InvalidFormat;
            const raw_name = std.mem.trim(u8, param[0..colon], " \t\r\n");
            const ty = std.mem.trim(u8, param[colon + 1 ..], " \t\r\n");
            if (std.mem.startsWith(u8, raw_name, "&")) {
                if (!std.mem.eql(u8, ty, "ptr")) return ExecError.UnsupportedOperation;
                const param_name = std.mem.trimStart(u8, raw_name[1..], " \t");
                const column_name = columnNameFromPointer(param_name) orelse return ExecError.UnsupportedOperation;
                const column = findWriteColumn(write_table, column_name) orelse return ExecError.InvalidFormat;
                pointers.put(param_name, column) catch return ExecError.OutOfMemory;
            } else if (std.mem.eql(u8, raw_name, "len") and std.mem.eql(u8, ty, "u64")) {
                values.put(raw_name, write_table.row_count) catch return ExecError.OutOfMemory;
            } else if (std.mem.eql(u8, ty, "u64")) {
                const value = try params.readU64();
                values.put(raw_name, value) catch return ExecError.OutOfMemory;
            } else return ExecError.UnsupportedOperation;
        }
        try params.finish();
        return;
    }
    return ExecError.InvalidFormat;
}

fn parseCrossReadWriteDbFunctionParams(
    allocator: std.mem.Allocator,
    source: []const u8,
    main_name: []const u8,
    read_table: ReadTable,
    write_table: *WriteTable,
    params_path: ?[]const u8,
    values: *ValueMap,
    read_pointers: *std.StringHashMap(*const TableColumn),
    write_pointers: *std.StringHashMap(*WriteColumn),
) ExecError!void {
    if (read_table.row_count != write_table.row_count) return ExecError.InvalidFormat;
    var params = ParamCursor{ .allocator = allocator, .params_path = params_path };
    defer params.deinit();
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = trimLineComment(line);
        if (!std.mem.startsWith(u8, trimmed, "@")) continue;
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse continue;
        if (!std.mem.eql(u8, trimmed[1..open], main_name)) continue;
        const close = std.mem.indexOfScalar(u8, trimmed[open + 1 ..], ')') orelse return ExecError.InvalidFormat;
        const params_text = trimmed[open + 1 .. open + 1 + close];
        var param_it = std.mem.splitScalar(u8, params_text, ',');
        while (param_it.next()) |raw_param| {
            const param = std.mem.trim(u8, raw_param, " \t\r\n");
            if (param.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, param, ':') orelse return ExecError.InvalidFormat;
            const raw_name = std.mem.trim(u8, param[0..colon], " \t\r\n");
            const ty = std.mem.trim(u8, param[colon + 1 ..], " \t\r\n");
            if (std.mem.startsWith(u8, raw_name, "&")) {
                if (!std.mem.eql(u8, ty, "ptr")) return ExecError.UnsupportedOperation;
                const param_name = std.mem.trimStart(u8, raw_name[1..], " \t");
                const column_name = columnNameFromPointer(param_name) orelse return ExecError.UnsupportedOperation;
                var bound = false;
                if (findColumn(read_table, column_name)) |column| {
                    read_pointers.put(param_name, column) catch return ExecError.OutOfMemory;
                    bound = true;
                }
                if (findWriteColumn(write_table, column_name)) |column| {
                    write_pointers.put(param_name, column) catch return ExecError.OutOfMemory;
                    bound = true;
                }
                if (!bound) return ExecError.InvalidFormat;
            } else if (std.mem.eql(u8, raw_name, "len") and std.mem.eql(u8, ty, "u64")) {
                values.put(raw_name, write_table.row_count) catch return ExecError.OutOfMemory;
            } else if (std.mem.eql(u8, ty, "u64")) {
                const value = try params.readU64();
                values.put(raw_name, value) catch return ExecError.OutOfMemory;
            } else return ExecError.UnsupportedOperation;
        }
        try params.finish();
        return;
    }
    return ExecError.InvalidFormat;
}

fn parseAtomicDbFunctionParams(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8, write_table: *WriteTable, params_path: ?[]const u8, values: *ValueMap, cursors: *std.StringHashMap(*WriteColumn)) ExecError!void {
    if (write_table.columns.len == 0) return ExecError.InvalidFormat;
    if (!isAtomicCursorColumn(write_table.columns[0].ty, write_table.columns[0].stride)) return ExecError.ColumnTypeMismatch;
    var params = ParamCursor{ .allocator = allocator, .params_path = params_path };
    defer params.deinit();
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = trimLineComment(line);
        if (!std.mem.startsWith(u8, trimmed, "@")) continue;
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse continue;
        if (!std.mem.eql(u8, trimmed[1..open], main_name)) continue;
        const close = std.mem.indexOfScalar(u8, trimmed[open + 1 ..], ')') orelse return ExecError.InvalidFormat;
        const params_text = trimmed[open + 1 .. open + 1 + close];
        var param_it = std.mem.splitScalar(u8, params_text, ',');
        while (param_it.next()) |raw_param| {
            const param = std.mem.trim(u8, raw_param, " \t\r\n");
            if (param.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, param, ':') orelse return ExecError.InvalidFormat;
            const raw_name = std.mem.trim(u8, param[0..colon], " \t\r\n");
            const ty = std.mem.trim(u8, param[colon + 1 ..], " \t\r\n");
            if (std.mem.startsWith(u8, raw_name, "&")) {
                if (!std.mem.eql(u8, ty, "ptr")) return ExecError.UnsupportedOperation;
                const param_name = std.mem.trimStart(u8, raw_name[1..], " \t");
                if (std.mem.eql(u8, param_name, "cursor")) {
                    cursors.put(param_name, &write_table.columns[0]) catch return ExecError.OutOfMemory;
                } else if (cursorColumnName(param_name)) |column_name| {
                    const column = findWriteColumn(write_table, column_name) orelse return ExecError.InvalidFormat;
                    if (!isAtomicCursorColumn(column.ty, column.stride)) return ExecError.ColumnTypeMismatch;
                    cursors.put(param_name, column) catch return ExecError.OutOfMemory;
                } else return ExecError.UnsupportedOperation;
            } else if (std.mem.eql(u8, raw_name, "len") and std.mem.eql(u8, ty, "u64")) {
                values.put(raw_name, write_table.row_count) catch return ExecError.OutOfMemory;
            } else if (std.mem.eql(u8, ty, "u64")) {
                const value = try params.readU64();
                values.put(raw_name, value) catch return ExecError.OutOfMemory;
            } else return ExecError.UnsupportedOperation;
        }
        try params.finish();
        return;
    }
    return ExecError.InvalidFormat;
}

fn collectExecutableLines(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8, labels: *std.StringHashMap(usize)) ExecError![]const []const u8 {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    errdefer lines.deinit();
    var in_body = false;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        const line = trimLineComment(raw_line);
        if (line.len == 0 or std.mem.startsWith(u8, line, "@import") or std.mem.startsWith(u8, line, "grants [")) continue;
        if (std.mem.startsWith(u8, line, "@")) {
            in_body = std.mem.startsWith(u8, line[1..], main_name);
            continue;
        }
        if (!in_body) continue;
        if (std.mem.endsWith(u8, line, ":")) {
            const label = line[0 .. line.len - 1];
            labels.put(label, lines.items.len) catch return ExecError.OutOfMemory;
            continue;
        }
        lines.append(line) catch return ExecError.OutOfMemory;
    }
    return lines.toOwnedSlice() catch return ExecError.OutOfMemory;
}

fn evalLoad(line: []const u8, values: *ValueMap, pointers: *std.StringHashMap(*const TableColumn)) ExecError!?struct { dst: []const u8, value: u64 } {
    const eq = std.mem.indexOf(u8, line, " = load ") orelse return null;
    if (!std.mem.endsWith(u8, line, " as u64")) return ExecError.UnsupportedOperation;
    const dst = std.mem.trim(u8, line[0..eq], " \t");
    const addr = std.mem.trim(u8, line[eq + " = load ".len .. line.len - " as u64".len], " \t");
    const plus = std.mem.indexOfScalar(u8, addr, '+') orelse return ExecError.UnsupportedOperation;
    const ptr_name = std.mem.trim(u8, addr[0..plus], " \t");
    const offset_name = std.mem.trim(u8, addr[plus + 1 ..], " \t");
    const column = pointers.get(ptr_name) orelse return ExecError.UnsupportedOperation;
    const offset = try lookupValue(values, offset_name);
    return .{ .dst = dst, .value = try loadColumnValue(column.*, offset) };
}

fn loadWriteColumnValue(column: *WriteColumn, offset: u64) ExecError!u64 {
    var base: u64 = 0;
    for (column.segments) |*segment| {
        const segment_bytes = segment.rows * column.stride;
        if (offset >= base and offset < base + segment_bytes) {
            const local_offset = offset - base;
            const temp = TableColumn{ .name = column.name, .ty = column.ty, .stride = column.stride, .bytes = segment.bytes };
            return try loadColumnValue(temp, local_offset);
        }
        base += segment_bytes;
    }
    return ExecError.InvalidFormat;
}

fn evalWriteLoad(line: []const u8, values: *ValueMap, pointers: *std.StringHashMap(*WriteColumn)) ExecError!?struct { dst: []const u8, value: u64 } {
    const eq = std.mem.indexOf(u8, line, " = load ") orelse return null;
    if (!std.mem.endsWith(u8, line, " as u64")) return ExecError.UnsupportedOperation;
    const dst = std.mem.trim(u8, line[0..eq], " \t");
    const addr = std.mem.trim(u8, line[eq + " = load ".len .. line.len - " as u64".len], " \t");
    const plus = std.mem.indexOfScalar(u8, addr, '+') orelse return ExecError.UnsupportedOperation;
    const ptr_name = std.mem.trim(u8, addr[0..plus], " \t");
    const offset_name = std.mem.trim(u8, addr[plus + 1 ..], " \t");
    const column = pointers.get(ptr_name) orelse return ExecError.UnsupportedOperation;
    const offset = try lookupValue(values, offset_name);
    return .{ .dst = dst, .value = try loadWriteColumnValue(column, offset) };
}

fn evalStore(line: []const u8, values: *ValueMap, pointers: *std.StringHashMap(*WriteColumn)) ExecError!bool {
    const rest = if (std.mem.startsWith(u8, line, "store "))
        line["store ".len..]
    else
        return false;
    if (!std.mem.endsWith(u8, rest, " as u64")) return ExecError.UnsupportedOperation;
    const body = std.mem.trim(u8, rest[0 .. rest.len - " as u64".len], " \t");
    const comma = std.mem.indexOfScalar(u8, body, ',') orelse return ExecError.InvalidFormat;
    const addr = std.mem.trim(u8, body[0..comma], " \t");
    const value_name = std.mem.trim(u8, body[comma + 1 ..], " \t");
    const plus = std.mem.indexOfScalar(u8, addr, '+') orelse return ExecError.UnsupportedOperation;
    const ptr_name = std.mem.trim(u8, addr[0..plus], " \t");
    const offset_name = std.mem.trim(u8, addr[plus + 1 ..], " \t");
    const column = pointers.get(ptr_name) orelse return ExecError.UnsupportedOperation;
    const offset = try lookupValue(values, offset_name);
    const value = try lookupValue(values, value_name);
    try storeColumnValue(column, offset, value);
    return true;
}

fn evalAtomicRmwAdd(line: []const u8, values: *ValueMap, cursors: *std.StringHashMap(*WriteColumn)) ExecError!?struct { dst: []const u8, old: u64 } {
    const eq = std.mem.indexOf(u8, line, " = atomic_rmw_add ") orelse return null;
    const dst = std.mem.trim(u8, line[0..eq], " \t");
    const args = std.mem.trim(u8, line[eq + " = atomic_rmw_add ".len ..], " \t");
    const comma = std.mem.indexOfScalar(u8, args, ',') orelse return ExecError.InvalidFormat;
    const addr = std.mem.trim(u8, args[0..comma], " \t");
    const delta_name = std.mem.trim(u8, args[comma + 1 ..], " \t\r\n");
    const plus = std.mem.indexOfScalar(u8, addr, '+') orelse return ExecError.UnsupportedOperation;
    const cursor_name = std.mem.trim(u8, addr[0..plus], " \t");
    const offset_name = std.mem.trim(u8, addr[plus + 1 ..], " \t");
    const column = cursors.get(cursor_name) orelse return ExecError.UnsupportedOperation;
    const offset = try lookupValue(values, offset_name);
    if (offset != 0) return ExecError.DbCapabilityEscalation;
    const delta = try lookupValue(values, delta_name);
    const old = try loadWriteColumnValue(column, offset);
    try storeColumnValue(column, offset, old +% delta);
    return .{ .dst = dst, .old = old };
}

fn fileMetasEqual(current: table_mod.FileMeta, expected: table_mod.FileMeta) bool {
    if (!std.mem.eql(u8, current.path, expected.path)) return false;
    if (!std.mem.eql(u8, current.sha256, expected.sha256)) return false;
    if (current.bytes != expected.bytes) return false;
    return blockHashMetadataEqual(current.block_size, current.block_sha256, expected.block_size, expected.block_sha256);
}

fn blockHashMetadataEqual(current_size: u64, current_hashes: []const []const u8, expected_size: u64, expected_hashes: []const []const u8) bool {
    if (current_size != expected_size) return false;
    if (current_hashes.len != expected_hashes.len) return false;
    for (current_hashes, expected_hashes) |current_hash, expected_hash| {
        if (!std.mem.eql(u8, current_hash, expected_hash)) return false;
    }
    return true;
}

fn indexMetasEqual(current: table_mod.IndexMeta, expected: table_mod.IndexMeta) bool {
    if (!std.mem.eql(u8, current.name, expected.name)) return false;
    if (!std.mem.eql(u8, current.kind, expected.kind)) return false;
    if (current.column_index != expected.column_index) return false;
    if (current.column_index2 != expected.column_index2) return false;
    if (current.unique != expected.unique) return false;
    if (!std.mem.eql(u8, current.path, expected.path)) return false;
    if (!std.mem.eql(u8, current.sha256, expected.sha256)) return false;
    if (current.bytes != expected.bytes) return false;
    return blockHashMetadataEqual(current.block_size, current.block_sha256, expected.block_size, expected.block_sha256);
}

fn dictMetasEqual(current: table_mod.DictMeta, expected: table_mod.DictMeta) bool {
    if (!std.mem.eql(u8, current.name, expected.name)) return false;
    if (!std.mem.eql(u8, current.path, expected.path)) return false;
    if (!std.mem.eql(u8, current.sha256, expected.sha256)) return false;
    if (current.bytes != expected.bytes) return false;
    if (current.entries != expected.entries) return false;
    return blockHashMetadataEqual(current.block_size, current.block_sha256, expected.block_size, expected.block_sha256);
}

fn tableMetaStillCurrent(allocator: std.mem.Allocator, write_table: *WriteTable) ExecError!bool {
    const meta_bytes = try readActiveTableMetaSource(allocator, write_table.parsed.value.table_name);
    defer allocator.free(meta_bytes);
    var current = std.json.parseFromSlice(QmodTableMeta, allocator, meta_bytes, .{ .allocate = .alloc_always }) catch return ExecError.InvalidFormat;
    defer current.deinit();
    const expected = write_table.parsed.value;
    if (!std.mem.eql(u8, current.value.magic, expected.magic) or current.value.version != expected.version) return false;
    if (!std.mem.eql(u8, current.value.table_name, expected.table_name)) return false;
    if (!std.mem.eql(u8, current.value.schema_hash, expected.schema_hash)) return false;
    if (current.value.locked != expected.locked) return false;
    if (current.value.epoch != expected.epoch) return false;
    if (current.value.row_count != expected.row_count) return false;
    if (current.value.max_rows != expected.max_rows) return false;
    if (current.value.row_bytes != expected.row_bytes) return false;
    if (current.value.next_segment_id != expected.next_segment_id) return false;
    if (current.value.columns.len != expected.columns.len or current.value.segments.len != expected.segments.len or current.value.indexes.len != expected.indexes.len or current.value.dicts.len != expected.dicts.len) return false;
    for (current.value.columns, expected.columns) |current_col, expected_col| {
        if (!std.mem.eql(u8, current_col.name, expected_col.name)) return false;
        if (!std.mem.eql(u8, current_col.ty, expected_col.ty)) return false;
        if (current_col.stride != expected_col.stride) return false;
    }
    for (current.value.segments, expected.segments) |current_segment, expected_segment| {
        if (current_segment.id != expected_segment.id or current_segment.rows != expected_segment.rows) return false;
        if (current_segment.files.len != expected_segment.files.len) return false;
        for (current_segment.files, expected_segment.files) |current_file, expected_file| {
            if (!fileMetasEqual(current_file, expected_file)) return false;
        }
    }
    for (current.value.indexes, expected.indexes) |current_index, expected_index| {
        if (!indexMetasEqual(current_index, expected_index)) return false;
    }
    for (current.value.dicts, expected.dicts) |current_dict, expected_dict| {
        if (!dictMetasEqual(current_dict, expected_dict)) return false;
    }
    return true;
}

fn commitWriteTable(allocator: std.mem.Allocator, write_table: *WriteTable) ExecError!void {
    const t_commit = ScopedTimer.begin(.commit_publish);
    defer t_commit.end();
    var any_dirty = false;
    var owned_paths = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (owned_paths.items) |path| allocator.free(path);
        owned_paths.deinit();
    }
    var owned_hashes = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (owned_hashes.items) |hash| allocator.free(hash);
        owned_hashes.deinit();
    }
    var owned_block_hashes = std.array_list.Managed([][]const u8).init(allocator);
    defer {
        for (owned_block_hashes.items) |hashes| {
            for (hashes) |hash| allocator.free(hash);
            allocator.free(hashes);
        }
        owned_block_hashes.deinit();
    }
    for (write_table.columns) |*column| {
        for (column.segments) |*segment| {
            if (segment.dirty) any_dirty = true;
        }
    }
    if (!any_dirty) return;
    if (!(try tableMetaStillCurrent(allocator, write_table))) return ExecError.StaleMetadata;

    const next_epoch = write_table.parsed.value.epoch + 1;
    for (write_table.columns, 0..) |*column, col_idx| {
        for (column.segments, 0..) |*segment, seg_idx| {
            if (!segment.dirty) continue;
            var file_meta = table_mod.rewriteColumnFileForEpoch(allocator, ".", segment.path, next_epoch, segment.bytes) catch |err| return mapTableError(err);
            errdefer {
                allocator.free(file_meta.path);
                allocator.free(file_meta.sha256);
                for (file_meta.block_sha256) |hash| allocator.free(hash);
                allocator.free(file_meta.block_sha256);
            }
            owned_paths.append(file_meta.path) catch return ExecError.OutOfMemory;
            errdefer _ = owned_paths.pop();
            owned_hashes.append(file_meta.sha256) catch return ExecError.OutOfMemory;
            errdefer _ = owned_hashes.pop();
            owned_block_hashes.append(file_meta.block_sha256) catch return ExecError.OutOfMemory;
            errdefer _ = owned_block_hashes.pop();
            const target = &write_table.parsed.value.segments[seg_idx].files[col_idx];
            target.* = file_meta;
            segment.path = target.path;
            file_meta = undefined;
        }
    }
    write_table.parsed.value.epoch = next_epoch;
    table_mod.commitTableMetaWithRebuiltIndexesUnlocked(allocator, ".", write_table.parsed.value.table_name, write_table.parsed.value) catch |err| return mapTableError(err);
    // In-process publication (docs/vm_concurrency_epoch.md §3.2): the
    // manifest publish above is the durable commit point; this swap
    // retires the previous epoch pin so in-process readers that pin
    // from now on adopt the new epoch and the old pin drains.
    epoch_runtime.noteCommitted(write_table.parsed.value.table_name, next_epoch);
}

/// Native column primitives for read-only qmod modules (VM query layer,
/// step 1). A primitive call is written like an assignment whose operator
/// is the primitive name:
///
///     total = col_sum col_amount, len
///     hits  = col_count_eq col_qty, len, 5
///     total = col_sum_where_eq col_amount, len, col_qty, 5
///
/// Primitives run natively over the read snapshot's merged column bytes;
/// the module only orchestrates (which columns, which predicate, how
/// results combine). Each call charges the fuel meter one step per scanned
/// row, on top of the per-instruction step the eval loop charges for the
/// call line itself. Only integer-typed columns are supported (u8..u64 and
/// i8..i64 as loaded by loadColumnValue); float columns are rejected with
/// ColumnTypeMismatch because aggregating their loaded bit patterns would
/// be meaningless. All comparisons use the loaded u64 cell representation,
/// so signed columns compare as their two's-complement bit patterns.
fn isIntegerColumnType(ty: []const u8) bool {
    return std.mem.eql(u8, ty, "u64") or std.mem.eql(u8, ty, "u32") or
        std.mem.eql(u8, ty, "u16") or std.mem.eql(u8, ty, "u8") or
        std.mem.eql(u8, ty, "i64") or std.mem.eql(u8, ty, "i32") or
        std.mem.eql(u8, ty, "i16") or std.mem.eql(u8, ty, "i8");
}

fn primitiveColumn(pointers: *std.StringHashMap(*const TableColumn), name: []const u8) ExecError!*const TableColumn {
    const column = pointers.get(name) orelse return ExecError.UnsupportedOperation;
    if (!isIntegerColumnType(column.ty)) return ExecError.ColumnTypeMismatch;
    return column;
}

fn primitiveRowLimit(column: *const TableColumn, len: u64) ExecError!u64 {
    const available: u64 = @intCast(column.bytes.len / column.stride);
    if (len > available) return ExecError.InvalidFormat;
    return len;
}

fn evalColumnPrimitive(line: []const u8, values: *ValueMap, pointers: *std.StringHashMap(*const TableColumn), meter: *FuelMeter) ExecError!?struct { dst: []const u8, value: u64 } {
    const eq = std.mem.indexOf(u8, line, " = ") orelse return null;
    const expr = std.mem.trim(u8, line[eq + 3 ..], " \t\r\n");
    var parts = std.mem.tokenizeAny(u8, expr, " ,\t");
    const op = parts.next() orelse return null;
    if (!std.mem.startsWith(u8, op, "col_")) return null;
    const dst = std.mem.trim(u8, line[0..eq], " \t\r\n");
    var arg_buf: [4][]const u8 = undefined;
    var arg_count: usize = 0;
    while (parts.next()) |arg| {
        if (arg_count >= arg_buf.len) return ExecError.InvalidFormat;
        arg_buf[arg_count] = arg;
        arg_count += 1;
    }
    const args = arg_buf[0..arg_count];

    if (std.mem.eql(u8, op, "col_sum") or std.mem.eql(u8, op, "col_min") or std.mem.eql(u8, op, "col_max")) {
        if (args.len != 2) return ExecError.InvalidFormat;
        const column = try primitiveColumn(pointers, args[0]);
        const rows = try primitiveRowLimit(column, try lookupValue(values, args[1]));
        try meter.charge(rows);
        if (rows == 0) {
            if (std.mem.eql(u8, op, "col_sum")) return .{ .dst = dst, .value = 0 };
            return ExecError.InvalidFormat;
        }
        const is_sum = std.mem.eql(u8, op, "col_sum");
        const is_min = std.mem.eql(u8, op, "col_min");
        if (columnKind(column.ty, column.stride)) |kind| {
            const scan_op: ScanOp = if (is_sum) .sum else if (is_min) .min else .max;
            return .{ .dst = dst, .value = scanOp(kind, column.bytes, rows, scan_op) };
        }
        var acc: u64 = 0;
        var row: u64 = 0;
        if (!is_sum) {
            acc = try loadColumnValue(column.*, 0);
            row = 1;
        }
        while (row < rows) : (row += 1) {
            const value = try loadColumnValue(column.*, row * @as(u64, column.stride));
            if (is_sum) {
                acc +%= value;
            } else if (is_min) {
                if (value < acc) acc = value;
            } else {
                if (value > acc) acc = value;
            }
        }
        return .{ .dst = dst, .value = acc };
    }
    if (std.mem.eql(u8, op, "col_count_eq")) {
        if (args.len != 3) return ExecError.InvalidFormat;
        const column = try primitiveColumn(pointers, args[0]);
        const rows = try primitiveRowLimit(column, try lookupValue(values, args[1]));
        const target = try lookupValue(values, args[2]);
        try meter.charge(rows);
        if (columnKind(column.ty, column.stride)) |kind| {
            return .{ .dst = dst, .value = scanOp(kind, column.bytes, rows, .{ .count_eq = target }) };
        }
        var count: u64 = 0;
        var row: u64 = 0;
        while (row < rows) : (row += 1) {
            if ((try loadColumnValue(column.*, row * @as(u64, column.stride))) == target) count += 1;
        }
        return .{ .dst = dst, .value = count };
    }
    if (std.mem.eql(u8, op, "col_count_range")) {
        if (args.len != 4) return ExecError.InvalidFormat;
        const column = try primitiveColumn(pointers, args[0]);
        const rows = try primitiveRowLimit(column, try lookupValue(values, args[1]));
        const lo = try lookupValue(values, args[2]);
        const hi = try lookupValue(values, args[3]);
        try meter.charge(rows);
        if (columnKind(column.ty, column.stride)) |kind| {
            return .{ .dst = dst, .value = scanOp(kind, column.bytes, rows, .{ .count_range = .{ .lo = lo, .hi = hi } }) };
        }
        var count: u64 = 0;
        var row: u64 = 0;
        while (row < rows) : (row += 1) {
            const value = try loadColumnValue(column.*, row * @as(u64, column.stride));
            if (value >= lo and value < hi) count += 1;
        }
        return .{ .dst = dst, .value = count };
    }
    if (std.mem.eql(u8, op, "col_sum_where_eq")) {
        if (args.len != 4) return ExecError.InvalidFormat;
        const sum_column = try primitiveColumn(pointers, args[0]);
        const rows = try primitiveRowLimit(sum_column, try lookupValue(values, args[1]));
        const key_column = try primitiveColumn(pointers, args[2]);
        _ = try primitiveRowLimit(key_column, rows);
        const target = try lookupValue(values, args[3]);
        try meter.charge(rows);
        var sum: u64 = 0;
        var row: u64 = 0;
        const key_kind = columnKind(key_column.ty, key_column.stride);
        const sum_kind = columnKind(sum_column.ty, sum_column.stride);
        if (key_kind != null and sum_kind != null) {
            const key_bytes = key_column.bytes;
            const sum_bytes = sum_column.bytes;
            const key_stride: u64 = key_column.stride;
            const sum_stride: u64 = sum_column.stride;
            while (row < rows) : (row += 1) {
                if (loadColumnValueKind(key_kind.?, key_bytes, @intCast(row * key_stride)) == target) {
                    sum +%= loadColumnValueKind(sum_kind.?, sum_bytes, @intCast(row * sum_stride));
                }
            }
        } else {
            while (row < rows) : (row += 1) {
                if ((try loadColumnValue(key_column.*, row * @as(u64, key_column.stride))) == target) {
                    sum +%= try loadColumnValue(sum_column.*, row * @as(u64, sum_column.stride));
                }
            }
        }
        return .{ .dst = dst, .value = sum };
    }
    return ExecError.InvalidFormat;
}

fn evalReadonlyDbQmod(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8, grant_entries: []const []const u8, params_path: ?[]const u8, meter: *FuelMeter) ExecError!?u64 {
    const table_name = try singleReadGrant(grant_entries) orelse return null;
    if (std.mem.indexOf(u8, source, "store ") != null or std.mem.indexOf(u8, source, "atomic_rmw_") != null) return null;

    var read_table = try loadReadTable(allocator, table_name);
    defer read_table.deinit(allocator);
    const t_rest = ScopedTimer.begin(.read_eval_rest);
    defer t_rest.end();
    var values = ValueMap.init(allocator);
    defer values.deinit();
    var pointers = std.StringHashMap(*const TableColumn).init(allocator);
    defer pointers.deinit();
    const t_params = ScopedTimer.begin(.prog_params);
    parseDbFunctionParams(allocator, source, main_name, read_table, params_path, &values, &pointers) catch |err| switch (err) {
        ExecError.UnsupportedOperation => return null,
        else => return err,
    };
    t_params.end();

    var labels = std.StringHashMap(usize).init(allocator);
    defer labels.deinit();
    const t_lines = ScopedTimer.begin(.prog_lines);
    const lines = try collectExecutableLines(allocator, source, main_name, &labels);
    t_lines.end();
    defer allocator.free(lines);

    const t_loop = ScopedTimer.begin(.stmt_loop);
    defer t_loop.end();
    var pc: usize = 0;
    while (pc < lines.len) {
        try meter.charge(1);
        const line = lines[pc];
        if (std.mem.startsWith(u8, line, "!")) {
            pc += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "return ")) {
            return try lookupValue(&values, std.mem.trim(u8, line["return ".len..], " \t\r\n"));
        }
        if (std.mem.startsWith(u8, line, "jmp ")) {
            const label = std.mem.trim(u8, line["jmp ".len..], " \t\r\n");
            pc = labels.get(label) orelse return ExecError.InvalidFormat;
            continue;
        }
        if (std.mem.startsWith(u8, line, "br ")) {
            const arrow = std.mem.indexOf(u8, line, " -> ") orelse return ExecError.InvalidFormat;
            const cond_name = std.mem.trim(u8, line["br ".len..arrow], " \t");
            var targets = std.mem.splitScalar(u8, line[arrow + " -> ".len ..], ',');
            const true_label = std.mem.trim(u8, targets.next() orelse return ExecError.InvalidFormat, " \t\r\n");
            const false_label = std.mem.trim(u8, targets.next() orelse return ExecError.InvalidFormat, " \t\r\n");
            if (targets.next() != null) return ExecError.InvalidFormat;
            pc = labels.get(if ((try lookupValue(&values, cond_name)) != 0) true_label else false_label) orelse return ExecError.InvalidFormat;
            continue;
        }
        if (try evalLoad(line, &values, &pointers)) |loaded| {
            values.put(loaded.dst, loaded.value) catch return ExecError.OutOfMemory;
            pc += 1;
            continue;
        }
        if (try evalColumnPrimitive(line, &values, &pointers, meter)) |primitive| {
            values.put(primitive.dst, primitive.value) catch return ExecError.OutOfMemory;
            pc += 1;
            continue;
        }
        const eq = std.mem.indexOf(u8, line, " = ") orelse return ExecError.UnsupportedOperation;
        const dst = std.mem.trim(u8, line[0..eq], " \t\r\n");
        const expr = std.mem.trim(u8, line[eq + 3 ..], " \t\r\n");
        var parts = std.mem.tokenizeAny(u8, expr, " ,\t");
        const op = parts.next() orelse return ExecError.InvalidFormat;
        const lhs_text = parts.next() orelse return ExecError.InvalidFormat;
        const rhs_text = parts.next() orelse return ExecError.InvalidFormat;
        if (parts.next() != null) return ExecError.UnsupportedOperation;
        const lhs = try lookupValue(&values, lhs_text);
        const rhs = try lookupValue(&values, rhs_text);
        const value = try evalBinaryValue(op, lhs, rhs);
        values.put(dst, value) catch return ExecError.OutOfMemory;
        pc += 1;
    }
    return ExecError.InvalidFormat;
}

fn evalWriteDbQmod(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8, grant_entries: []const []const u8, params_path: ?[]const u8, meter: *FuelMeter) ExecError!?u64 {
    const table_name = try singleWriteGrant(grant_entries) orelse return null;
    if (std.mem.indexOf(u8, source, " load ") != null or std.mem.indexOf(u8, source, "atomic_rmw_") != null) return null;

    var write_lock = try acquireTableWriteLock(allocator, table_name);
    defer write_lock.release();

    const t_wload = ScopedTimer.begin(.write_load);
    var write_table = try loadWriteTable(allocator, table_name);
    t_wload.end();
    defer write_table.deinit(allocator);
    const t_weval = ScopedTimer.begin(.write_eval_rest);
    defer t_weval.end();
    var values = ValueMap.init(allocator);
    defer values.deinit();
    var pointers = std.StringHashMap(*WriteColumn).init(allocator);
    defer pointers.deinit();
    parseWriteDbFunctionParams(allocator, source, main_name, &write_table, params_path, &values, &pointers) catch |err| switch (err) {
        ExecError.UnsupportedOperation => return null,
        else => return err,
    };

    var labels = std.StringHashMap(usize).init(allocator);
    defer labels.deinit();
    const lines = try collectExecutableLines(allocator, source, main_name, &labels);
    defer allocator.free(lines);

    var pc: usize = 0;
    while (pc < lines.len) {
        try meter.charge(1);
        const line = lines[pc];
        if (std.mem.startsWith(u8, line, "!")) {
            pc += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "return ")) {
            const result = try lookupValue(&values, std.mem.trim(u8, line["return ".len..], " \t\r\n"));
            try commitWriteTable(allocator, &write_table);
            return result;
        }
        if (std.mem.startsWith(u8, line, "jmp ")) {
            const label = std.mem.trim(u8, line["jmp ".len..], " \t\r\n");
            pc = labels.get(label) orelse return ExecError.InvalidFormat;
            continue;
        }
        if (std.mem.startsWith(u8, line, "br ")) {
            const arrow = std.mem.indexOf(u8, line, " -> ") orelse return ExecError.InvalidFormat;
            const cond_name = std.mem.trim(u8, line["br ".len..arrow], " \t");
            var targets = std.mem.splitScalar(u8, line[arrow + " -> ".len ..], ',');
            const true_label = std.mem.trim(u8, targets.next() orelse return ExecError.InvalidFormat, " \t\r\n");
            const false_label = std.mem.trim(u8, targets.next() orelse return ExecError.InvalidFormat, " \t\r\n");
            if (targets.next() != null) return ExecError.InvalidFormat;
            pc = labels.get(if ((try lookupValue(&values, cond_name)) != 0) true_label else false_label) orelse return ExecError.InvalidFormat;
            continue;
        }
        if (try evalStore(line, &values, &pointers)) {
            pc += 1;
            continue;
        }
        const eq = std.mem.indexOf(u8, line, " = ") orelse return ExecError.UnsupportedOperation;
        const dst = std.mem.trim(u8, line[0..eq], " \t\r\n");
        const expr = std.mem.trim(u8, line[eq + 3 ..], " \t\r\n");
        var parts = std.mem.tokenizeAny(u8, expr, " ,\t");
        const op = parts.next() orelse return ExecError.InvalidFormat;
        const lhs_text = parts.next() orelse return ExecError.InvalidFormat;
        const rhs_text = parts.next() orelse return ExecError.InvalidFormat;
        if (parts.next() != null) return ExecError.UnsupportedOperation;
        const lhs = try lookupValue(&values, lhs_text);
        const rhs = try lookupValue(&values, rhs_text);
        const value = try evalBinaryValue(op, lhs, rhs);
        values.put(dst, value) catch return ExecError.OutOfMemory;
        pc += 1;
    }
    return ExecError.InvalidFormat;
}

fn evalReadWriteDbQmod(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8, grant_entries: []const []const u8, params_path: ?[]const u8, meter: *FuelMeter) ExecError!?u64 {
    const grants = try singleReadWriteGrant(grant_entries) orelse return null;
    if (std.mem.indexOf(u8, source, "atomic_rmw_") != null) return null;

    var write_lock = try acquireTableWriteLock(allocator, grants.write_table);
    defer write_lock.release();

    var write_table = try loadWriteTable(allocator, grants.write_table);
    defer write_table.deinit(allocator);
    var read_table: ?ReadTable = if (std.mem.eql(u8, grants.read_table, grants.write_table)) null else try loadReadTable(allocator, grants.read_table);
    defer if (read_table) |*table| table.deinit(allocator);
    var values = ValueMap.init(allocator);
    defer values.deinit();
    var read_pointers = std.StringHashMap(*const TableColumn).init(allocator);
    defer read_pointers.deinit();
    var write_pointers = std.StringHashMap(*WriteColumn).init(allocator);
    defer write_pointers.deinit();
    if (read_table) |table| {
        parseCrossReadWriteDbFunctionParams(allocator, source, main_name, table, &write_table, params_path, &values, &read_pointers, &write_pointers) catch |err| switch (err) {
            ExecError.UnsupportedOperation => return null,
            else => return err,
        };
    } else {
        parseWriteDbFunctionParams(allocator, source, main_name, &write_table, params_path, &values, &write_pointers) catch |err| switch (err) {
            ExecError.UnsupportedOperation => return null,
            else => return err,
        };
    }

    var labels = std.StringHashMap(usize).init(allocator);
    defer labels.deinit();
    const lines = try collectExecutableLines(allocator, source, main_name, &labels);
    defer allocator.free(lines);

    var pc: usize = 0;
    while (pc < lines.len) {
        try meter.charge(1);
        const line = lines[pc];
        if (std.mem.startsWith(u8, line, "!")) {
            pc += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "return ")) {
            const result = try lookupValue(&values, std.mem.trim(u8, line["return ".len..], " \t\r\n"));
            try commitWriteTable(allocator, &write_table);
            return result;
        }
        if (std.mem.startsWith(u8, line, "jmp ")) {
            const label = std.mem.trim(u8, line["jmp ".len..], " \t\r\n");
            pc = labels.get(label) orelse return ExecError.InvalidFormat;
            continue;
        }
        if (std.mem.startsWith(u8, line, "br ")) {
            const arrow = std.mem.indexOf(u8, line, " -> ") orelse return ExecError.InvalidFormat;
            const cond_name = std.mem.trim(u8, line["br ".len..arrow], " \t");
            var targets = std.mem.splitScalar(u8, line[arrow + " -> ".len ..], ',');
            const true_label = std.mem.trim(u8, targets.next() orelse return ExecError.InvalidFormat, " \t\r\n");
            const false_label = std.mem.trim(u8, targets.next() orelse return ExecError.InvalidFormat, " \t\r\n");
            if (targets.next() != null) return ExecError.InvalidFormat;
            pc = labels.get(if ((try lookupValue(&values, cond_name)) != 0) true_label else false_label) orelse return ExecError.InvalidFormat;
            continue;
        }
        if (read_table != null) {
            if (try evalLoad(line, &values, &read_pointers)) |loaded| {
                values.put(loaded.dst, loaded.value) catch return ExecError.OutOfMemory;
                pc += 1;
                continue;
            }
        } else {
            if (try evalWriteLoad(line, &values, &write_pointers)) |loaded| {
                values.put(loaded.dst, loaded.value) catch return ExecError.OutOfMemory;
                pc += 1;
                continue;
            }
        }
        if (try evalStore(line, &values, &write_pointers)) {
            pc += 1;
            continue;
        }
        const eq = std.mem.indexOf(u8, line, " = ") orelse return ExecError.UnsupportedOperation;
        const dst = std.mem.trim(u8, line[0..eq], " \t\r\n");
        const expr = std.mem.trim(u8, line[eq + 3 ..], " \t\r\n");
        var parts = std.mem.tokenizeAny(u8, expr, " ,\t");
        const op = parts.next() orelse return ExecError.InvalidFormat;
        const lhs_text = parts.next() orelse return ExecError.InvalidFormat;
        const rhs_text = parts.next() orelse return ExecError.InvalidFormat;
        if (parts.next() != null) return ExecError.UnsupportedOperation;
        const lhs = try lookupValue(&values, lhs_text);
        const rhs = try lookupValue(&values, rhs_text);
        const value = try evalBinaryValue(op, lhs, rhs);
        values.put(dst, value) catch return ExecError.OutOfMemory;
        pc += 1;
    }
    return ExecError.InvalidFormat;
}

fn evalAtomicDbQmod(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8, grant_entries: []const []const u8, params_path: ?[]const u8, meter: *FuelMeter) ExecError!?u64 {
    const table_name = try singleAtomicGrant(grant_entries) orelse return null;
    if (std.mem.indexOf(u8, source, " load ") != null or std.mem.indexOf(u8, source, "store ") != null) return null;

    var write_lock = try acquireTableWriteLock(allocator, table_name);
    defer write_lock.release();

    var write_table = try loadWriteTable(allocator, table_name);
    defer write_table.deinit(allocator);
    var values = ValueMap.init(allocator);
    defer values.deinit();
    var cursors = std.StringHashMap(*WriteColumn).init(allocator);
    defer cursors.deinit();
    parseAtomicDbFunctionParams(allocator, source, main_name, &write_table, params_path, &values, &cursors) catch |err| switch (err) {
        ExecError.UnsupportedOperation => return null,
        else => return err,
    };

    var labels = std.StringHashMap(usize).init(allocator);
    defer labels.deinit();
    const lines = try collectExecutableLines(allocator, source, main_name, &labels);
    defer allocator.free(lines);

    var pc: usize = 0;
    while (pc < lines.len) {
        try meter.charge(1);
        const line = lines[pc];
        if (std.mem.startsWith(u8, line, "!")) {
            pc += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "return ")) {
            const result = try lookupValue(&values, std.mem.trim(u8, line["return ".len..], " \t\r\n"));
            try commitWriteTable(allocator, &write_table);
            return result;
        }
        if (std.mem.startsWith(u8, line, "jmp ")) {
            const label = std.mem.trim(u8, line["jmp ".len..], " \t\r\n");
            pc = labels.get(label) orelse return ExecError.InvalidFormat;
            continue;
        }
        if (std.mem.startsWith(u8, line, "br ")) {
            const arrow = std.mem.indexOf(u8, line, " -> ") orelse return ExecError.InvalidFormat;
            const cond_name = std.mem.trim(u8, line["br ".len..arrow], " \t");
            var targets = std.mem.splitScalar(u8, line[arrow + " -> ".len ..], ',');
            const true_label = std.mem.trim(u8, targets.next() orelse return ExecError.InvalidFormat, " \t\r\n");
            const false_label = std.mem.trim(u8, targets.next() orelse return ExecError.InvalidFormat, " \t\r\n");
            if (targets.next() != null) return ExecError.InvalidFormat;
            pc = labels.get(if ((try lookupValue(&values, cond_name)) != 0) true_label else false_label) orelse return ExecError.InvalidFormat;
            continue;
        }
        if (try evalAtomicRmwAdd(line, &values, &cursors)) |atomic| {
            values.put(atomic.dst, atomic.old) catch return ExecError.OutOfMemory;
            pc += 1;
            continue;
        }
        const eq = std.mem.indexOf(u8, line, " = ") orelse return ExecError.UnsupportedOperation;
        const dst = std.mem.trim(u8, line[0..eq], " \t\r\n");
        const expr = std.mem.trim(u8, line[eq + 3 ..], " \t\r\n");
        var parts = std.mem.tokenizeAny(u8, expr, " ,\t");
        const op = parts.next() orelse return ExecError.InvalidFormat;
        const lhs_text = parts.next() orelse return ExecError.InvalidFormat;
        const rhs_text = parts.next() orelse return ExecError.InvalidFormat;
        if (parts.next() != null) return ExecError.UnsupportedOperation;
        const lhs = try lookupValue(&values, lhs_text);
        const rhs = try lookupValue(&values, rhs_text);
        const value = try evalBinaryValue(op, lhs, rhs);
        values.put(dst, value) catch return ExecError.OutOfMemory;
        pc += 1;
    }
    return ExecError.InvalidFormat;
}

pub fn compileSchema(allocator: std.mem.Allocator, source_path: []const u8) ![]u8 {
    return allocator.dupe(u8, source_path);
}

pub fn registerQuery(allocator: std.mem.Allocator, source_path: []const u8) ExecError!ExecResult {
    const source = try readFileAlloc(allocator, source_path, 16 * 1024 * 1024);
    defer allocator.free(source);

    const hash = hashBytes(source);
    const hash_hex = try hashHexAlloc(allocator, hash);
    defer allocator.free(hash_hex);
    const qmod_path = try qmodPath(allocator, hash_hex);
    errdefer allocator.free(qmod_path);
    const meta_path = try metaPath(allocator, hash_hex);
    errdefer allocator.free(meta_path);

    const imports = countLinesWithPrefix(source, "@import");
    var grants = try parseGrants(allocator, source);
    defer grants.deinit(allocator);
    try verifyDbGrants(source, grants);
    try verifyReadGrantColumns(allocator, source, grants.entries);
    try verifyWriteGrantColumns(allocator, source, grants.entries);
    try verifyAtomicGrantCursors(allocator, source, grants.entries);
    const main_name = findMainName(source);

    try ensureRegistryDir();
    try verifyExistingRegistration(allocator, hash_hex, source_path, source, qmod_path, imports, grants, main_name);
    try writeFile(qmod_path, source);

    const module_class = try deriveModuleClass(allocator, grants.entries);
    defer allocator.free(module_class.write_tables);

    const meta = QueryMeta{
        .magic = "sa-db-qmod-meta",
        .version = 2,
        .hash = hash_hex,
        .source_path = source_path,
        .qmod_path = qmod_path,
        .imports = imports,
        .grants = grants.entries.len,
        .grant_entries = grants.entries,
        .main = main_name,
        .kind = module_class.kind,
        .write_capability = module_class.write_capability,
        .write_tables = module_class.write_tables,
    };
    const json = std.json.Stringify.valueAlloc(allocator, meta, .{}) catch return ExecError.OutOfMemory;
    defer allocator.free(json);
    try writeFile(meta_path, json);

    return .{
        .hash = hash,
        .qmod_path = qmod_path,
        .meta_path = meta_path,
        .source_path = try allocator.dupe(u8, source_path),
        .imports = imports,
        .grants = grants.entries.len,
        .kind = module_class.kind,
        .write_capability = module_class.write_capability,
    };
}

fn loadMeta(allocator: std.mem.Allocator, hash_text: []const u8) ExecError!std.json.Parsed(QueryMeta) {
    const hash = try parseHashHex(hash_text);
    const hash_hex = try hashHexAlloc(allocator, hash);
    defer allocator.free(hash_hex);
    const path = try metaPath(allocator, hash_hex);
    defer allocator.free(path);
    const expected_qmod_path = try qmodPath(allocator, hash_hex);
    defer allocator.free(expected_qmod_path);
    const bytes = readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| switch (err) {
        ExecError.FileNotFound => return ExecError.QueryHashUnknown,
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(QueryMeta, allocator, bytes, .{ .allocate = .alloc_always }) catch return ExecError.InvalidFormat;
    if (!std.mem.eql(u8, parsed.value.magic, "sa-db-qmod-meta") or (parsed.value.version != 1 and parsed.value.version != 2)) {
        parsed.deinit();
        return ExecError.InvalidFormat;
    }
    if (!std.mem.eql(u8, parsed.value.hash, hash_hex) or
        !std.mem.eql(u8, parsed.value.qmod_path, expected_qmod_path) or
        parsed.value.grants != parsed.value.grant_entries.len or
        parsed.value.main.len == 0)
    {
        parsed.deinit();
        return ExecError.QueryRegistryCorrupted;
    }
    return parsed;
}

pub fn inspectRegistry(allocator: std.mem.Allocator, hash_text: []const u8) ExecError![]u8 {
    var parsed = try loadMeta(allocator, hash_text);
    defer parsed.deinit();
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    out.print("hash: {s}\n", .{parsed.value.hash}) catch return ExecError.OutOfMemory;
    out.print("source: {s}\n", .{parsed.value.source_path}) catch return ExecError.OutOfMemory;
    out.print("qmod: {s}\n", .{parsed.value.qmod_path}) catch return ExecError.OutOfMemory;
    out.print("imports: {d}\n", .{parsed.value.imports}) catch return ExecError.OutOfMemory;
    out.print("grants: {d}\n", .{parsed.value.grants}) catch return ExecError.OutOfMemory;
    for (parsed.value.grant_entries) |entry| {
        out.print("grant: {s}\n", .{entry}) catch return ExecError.OutOfMemory;
    }
    out.print("main: {s}\n", .{parsed.value.main}) catch return ExecError.OutOfMemory;
    const module_class = try deriveModuleClass(allocator, parsed.value.grant_entries);
    defer allocator.free(module_class.write_tables);
    out.print("kind: {s}\n", .{module_class.kind}) catch return ExecError.OutOfMemory;
    out.print("write_capability: {s}\n", .{if (module_class.write_capability) "true" else "false"}) catch return ExecError.OutOfMemory;
    for (module_class.write_tables) |table_name| {
        out.print("write_table: {s}\n", .{table_name}) catch return ExecError.OutOfMemory;
    }
    if (parsed.value.aot) |record| {
        out.print("aot_lib: {s}\n", .{record.lib_path}) catch return ExecError.OutOfMemory;
        out.print("aot_lib_sha256: {s}\n", .{record.lib_sha256}) catch return ExecError.OutOfMemory;
        out.print("aot_symbol: {s}\n", .{record.symbol}) catch return ExecError.OutOfMemory;
        out.print("aot_abi_version: {d}\n", .{record.abi_version}) catch return ExecError.OutOfMemory;
    }
    return out.toOwnedSlice() catch return ExecError.OutOfMemory;
}

/// Exec-time capability revalidation (step 2). Registration already
/// validated the module, but the registry record is data on disk: at
/// exec time the payload (whose hash is verified by the caller) is the
/// source of truth. The record's grant entries must match the grants
/// declared in the payload itself, the payload's instructions must not
/// exceed those grants, and a version 2 record's stored class fields
/// must agree with the class derived from the payload grants. Any
/// disagreement is an explicit error — a read-only-class module can
/// never reach a writing evaluator through a tampered record, and a
/// write procedure can never be silently demoted or escalated.
fn validateExecPayload(allocator: std.mem.Allocator, meta: QueryMeta, source: []const u8) ExecError!void {
    var payload_grants = try parseGrants(allocator, source);
    defer payload_grants.deinit(allocator);
    if (!grantEntriesEqual(meta.grant_entries, payload_grants.entries)) return ExecError.QueryRegistryCorrupted;
    try verifyDbGrants(source, payload_grants);
    if (meta.version >= 2) {
        const derived = try deriveModuleClass(allocator, payload_grants.entries);
        defer allocator.free(derived.write_tables);
        if (!std.mem.eql(u8, meta.kind, derived.kind) or
            meta.write_capability != derived.write_capability or
            !grantEntriesEqual(meta.write_tables, derived.write_tables))
        {
            return ExecError.QueryRegistryCorrupted;
        }
    }
}

/// AOT escape hatch (step 2). A module opts in per-module when a
/// native library — built from an SA source through the toolchain's
/// normal AOT path (`sa build-lib` with an export contract) — is
/// registered against its hash with `registerAot`. The library must
/// export `sa_db_aot_abi_version` returning `aot_abi_version` and an
/// entry point (default `sa_db_qmod_main`) with the descriptor
/// signature `fn (slots: [*]const u64, slot_count: u64) -> u64`.
///
/// Slot layout follows the module signature in order: a column
/// parameter (`&col_<name>: ptr`) takes two slots (buffer address,
/// buffer byte length), `len: u64` takes one slot (row count), and
/// each scalar `u64` parameter takes one slot (its value, read from
/// the params file exactly as the interpreters read it). Write
/// columns are staged into contiguous buffers the native code may
/// mutate; on a clean return the staged bytes are written back and
/// committed through the same single-table transaction commit as the
/// interpreted write evaluators. Native code is trusted code — that
/// is precisely why the tier is opt-in per module — and it is not
/// instruction-metered; the interpreted tier keeps the fuel budget.
pub const aot_abi_version: u32 = 1;
pub const aot_abi_version_symbol = "sa_db_aot_abi_version";
pub const aot_default_entry_symbol = "sa_db_qmod_main";
pub const aot_max_slots: usize = 32;

const AotMainFn = fn ([*]const u64, u64) callconv(.c) u64;
const AotAbiFn = fn () callconv(.c) i64;

pub const AotResult = struct {
    hash: [32]u8,
    lib_path: []u8,
    lib_sha256: []u8,
    symbol: []u8,
    abi_version: u32,

    pub fn deinit(self: *AotResult, allocator: std.mem.Allocator) void {
        allocator.free(self.lib_path);
        allocator.free(self.lib_sha256);
        allocator.free(self.symbol);
        self.* = undefined;
    }
};

const AotShape = struct {
    read_table: ?[]const u8 = null,
    write_table: ?[]const u8 = null,
};

fn aotShape(entries: []const []const u8) ExecError!AotShape {
    var shape = AotShape{};
    for (entries) |entry| {
        if (parseReadGrant(entry)) |table_name| {
            if (shape.read_table != null and !std.mem.eql(u8, shape.read_table.?, table_name)) return ExecError.AotUnsupportedShape;
            shape.read_table = table_name;
        } else if (parseWriteGrant(entry)) |table_name| {
            if (shape.write_table != null and !std.mem.eql(u8, shape.write_table.?, table_name)) return ExecError.AotUnsupportedShape;
            shape.write_table = table_name;
        } else {
            // db_atomic_cursor and db_alloc_blob grants have no AOT
            // tier: the cursor discipline does not map onto the buffer
            // descriptor, and blob allocation is not implemented by
            // any evaluator. Refuse explicitly at registration time
            // instead of silently covering a shape AOT cannot stage.
            return ExecError.AotUnsupportedShape;
        }
    }
    return shape;
}

const AotParam = union(enum) {
    column: []const u8,
    row_count,
    scalar: []const u8,
};

fn parseAotParams(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8) ExecError![]AotParam {
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = trimLineComment(line);
        if (!std.mem.startsWith(u8, trimmed, "@")) continue;
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse continue;
        if (!std.mem.eql(u8, trimmed[1..open], main_name)) continue;
        const close = std.mem.indexOfScalar(u8, trimmed[open + 1 ..], ')') orelse return ExecError.InvalidFormat;
        const params_text = trimmed[open + 1 .. open + 1 + close];
        var params = std.array_list.Managed(AotParam).init(allocator);
        errdefer params.deinit();
        var param_it = std.mem.splitScalar(u8, params_text, ',');
        while (param_it.next()) |raw_param| {
            const param = std.mem.trim(u8, raw_param, " \t\r\n");
            if (param.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, param, ':') orelse return ExecError.InvalidFormat;
            const raw_name = std.mem.trim(u8, param[0..colon], " \t\r\n");
            const ty = std.mem.trim(u8, param[colon + 1 ..], " \t\r\n");
            if (std.mem.startsWith(u8, raw_name, "&")) {
                if (!std.mem.eql(u8, ty, "ptr")) return ExecError.UnsupportedOperation;
                const param_name = std.mem.trimStart(u8, raw_name[1..], " \t");
                const column_name = columnNameFromPointer(param_name) orelse return ExecError.UnsupportedOperation;
                params.append(.{ .column = column_name }) catch return ExecError.OutOfMemory;
            } else if (std.mem.eql(u8, raw_name, "len") and std.mem.eql(u8, ty, "u64")) {
                params.append(.row_count) catch return ExecError.OutOfMemory;
            } else if (std.mem.eql(u8, ty, "u64")) {
                params.append(.{ .scalar = raw_name }) catch return ExecError.OutOfMemory;
            } else return ExecError.UnsupportedOperation;
        }
        return params.toOwnedSlice() catch return ExecError.OutOfMemory;
    }
    return ExecError.InvalidFormat;
}

fn aotSlotCount(params: []const AotParam) usize {
    var count: usize = 0;
    for (params) |param| {
        count += switch (param) {
            .column => 2,
            .row_count, .scalar => 1,
        };
    }
    return count;
}

const OpenedAotLibrary = struct {
    lib: std.DynLib,
    main_fn: *const AotMainFn,
};

fn openAotLibrary(allocator: std.mem.Allocator, lib_path: []const u8, symbol: []const u8) ExecError!OpenedAotLibrary {
    // A bare filename would be treated as a library *name* and
    // searched in system paths only; prefixing ./ keeps a relative
    // registration path anchored at the working directory.
    const open_path = if (std.mem.indexOfScalar(u8, lib_path, '/') == null)
        std.fmt.allocPrint(allocator, "./{s}", .{lib_path}) catch return ExecError.OutOfMemory
    else
        lib_path;
    defer if (open_path.ptr != lib_path.ptr) allocator.free(open_path);
    var lib = std.DynLib.open(open_path) catch return ExecError.AotLibraryInvalid;
    errdefer lib.close();
    const abi_fn = lib.lookup(*const AotAbiFn, aot_abi_version_symbol) orelse return ExecError.AotSymbolMissing;
    if (abi_fn() != @as(i64, @intCast(aot_abi_version))) return ExecError.AotAbiMismatch;
    const symbol_z = allocator.dupeSentinel(u8, symbol, 0) catch return ExecError.OutOfMemory;
    defer allocator.free(symbol_z);
    const main_fn = lib.lookup(*const AotMainFn, symbol_z) orelse return ExecError.AotSymbolMissing;
    return .{ .lib = lib, .main_fn = main_fn };
}

fn readAotLibraryBytes(allocator: std.mem.Allocator, lib_path: []const u8) ExecError![]u8 {
    return readFileAlloc(allocator, lib_path, 512 * 1024 * 1024) catch |err| switch (err) {
        ExecError.FileNotFound => return ExecError.AotLibraryInvalid,
        else => return err,
    };
}

/// Register (or, with `replace`, explicitly substitute) the native
/// AOT library for an already-registered module. Registration is the
/// opt-in: without an AOT record the module always runs interpreted,
/// and with one it always runs native — substitution requires the
/// explicit replace flag, never a silent overwrite of native code.
pub fn registerAot(allocator: std.mem.Allocator, hash_text: []const u8, lib_path: []const u8, symbol: ?[]const u8, replace: bool) ExecError!AotResult {
    var parsed = try loadMeta(allocator, hash_text);
    defer parsed.deinit();
    const meta = parsed.value;
    const entry_symbol = symbol orelse aot_default_entry_symbol;
    const hash = try parseHashHex(meta.hash);

    const payload = readFileAlloc(allocator, meta.qmod_path, 16 * 1024 * 1024) catch |err| switch (err) {
        ExecError.FileNotFound => return ExecError.QueryPayloadCorrupted,
        else => return err,
    };
    defer allocator.free(payload);
    if (!std.mem.eql(u8, &hashBytes(payload), &hash)) return ExecError.QueryPayloadCorrupted;
    try validateExecPayload(allocator, meta, payload);
    _ = try aotShape(meta.grant_entries);
    const params = try parseAotParams(allocator, payload, meta.main);
    defer allocator.free(params);
    if (aotSlotCount(params) > aot_max_slots) return ExecError.AotUnsupportedShape;

    const lib_bytes = try readAotLibraryBytes(allocator, lib_path);
    defer allocator.free(lib_bytes);
    const lib_hash = hashHex(lib_bytes);

    if (meta.aot) |existing| {
        const same = std.mem.eql(u8, existing.lib_path, lib_path) and
            std.mem.eql(u8, existing.lib_sha256, lib_hash[0..]) and
            std.mem.eql(u8, existing.symbol, entry_symbol) and
            existing.abi_version == aot_abi_version;
        if (same) return aotResultAlloc(allocator, hash, lib_path, lib_hash[0..], entry_symbol);
        if (!replace) return ExecError.AotAlreadyRegistered;
    }

    var opened = try openAotLibrary(allocator, lib_path, entry_symbol);
    opened.lib.close();

    const module_class = try deriveModuleClass(allocator, meta.grant_entries);
    defer allocator.free(module_class.write_tables);
    var new_meta = meta;
    new_meta.version = 2;
    new_meta.kind = module_class.kind;
    new_meta.write_capability = module_class.write_capability;
    new_meta.write_tables = module_class.write_tables;
    new_meta.aot = .{
        .lib_path = lib_path,
        .lib_sha256 = lib_hash[0..],
        .symbol = entry_symbol,
        .abi_version = aot_abi_version,
    };
    const json = std.json.Stringify.valueAlloc(allocator, new_meta, .{}) catch return ExecError.OutOfMemory;
    defer allocator.free(json);
    const path = try metaPath(allocator, meta.hash);
    defer allocator.free(path);
    try writeFile(path, json);

    return aotResultAlloc(allocator, hash, lib_path, lib_hash[0..], entry_symbol);
}

fn aotResultAlloc(allocator: std.mem.Allocator, hash: [32]u8, lib_path: []const u8, lib_sha256: []const u8, symbol: []const u8) ExecError!AotResult {
    const path_copy = allocator.dupe(u8, lib_path) catch return ExecError.OutOfMemory;
    errdefer allocator.free(path_copy);
    const hash_copy = allocator.dupe(u8, lib_sha256) catch return ExecError.OutOfMemory;
    errdefer allocator.free(hash_copy);
    const symbol_copy = allocator.dupe(u8, symbol) catch return ExecError.OutOfMemory;
    return .{
        .hash = hash,
        .lib_path = path_copy,
        .lib_sha256 = hash_copy,
        .symbol = symbol_copy,
        .abi_version = aot_abi_version,
    };
}

const StagedColumn = struct {
    column: *WriteColumn,
    bytes: []u8,

    fn deinit(self: *StagedColumn, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }

    /// Copy the staged bytes back over the write table's segments,
    /// marking only the segments whose contents actually changed as
    /// dirty (mirroring the interpreted evaluators' store accounting,
    /// so commit rewrites exactly what the procedure touched).
    fn copyBack(self: *StagedColumn) void {
        var offset: usize = 0;
        for (self.column.segments) |*segment| {
            const seg_len = segment.bytes.len;
            if (!std.mem.eql(u8, segment.bytes, self.bytes[offset .. offset + seg_len])) {
                @memcpy(segment.bytes, self.bytes[offset .. offset + seg_len]);
                segment.dirty = true;
            }
            offset += seg_len;
        }
    }
};

fn aotColumnBuffer(allocator: std.mem.Allocator, staged: *std.array_list.Managed(StagedColumn), write_table: ?*WriteTable, read_table: ?*ReadTable, column_name: []const u8) ExecError![]const u8 {
    if (write_table) |table| {
        if (findWriteColumn(table, column_name)) |column| {
            for (staged.items) |*existing| {
                if (existing.column == column) return existing.bytes;
            }
            var total: usize = 0;
            for (column.segments) |segment| total += segment.bytes.len;
            const buffer = allocator.alloc(u8, total) catch return ExecError.OutOfMemory;
            errdefer allocator.free(buffer);
            var offset: usize = 0;
            for (column.segments) |segment| {
                @memcpy(buffer[offset .. offset + segment.bytes.len], segment.bytes);
                offset += segment.bytes.len;
            }
            staged.append(.{ .column = column, .bytes = buffer }) catch return ExecError.OutOfMemory;
            return buffer;
        }
    }
    if (read_table) |table| {
        if (findColumn(table.*, column_name)) |column| return column.bytes;
    }
    return ExecError.InvalidFormat;
}

fn execAotQmod(allocator: std.mem.Allocator, meta: QueryMeta, record: AotRecord, source: []const u8, params_path: ?[]const u8) ExecError!u64 {
    const shape = try aotShape(meta.grant_entries);

    // The library on disk must still be the exact artifact that was
    // registered; any drift is an explicit error, never a fallback.
    const lib_bytes = try readAotLibraryBytes(allocator, record.lib_path);
    defer allocator.free(lib_bytes);
    const lib_hash = hashHex(lib_bytes);
    if (!std.mem.eql(u8, lib_hash[0..], record.lib_sha256)) return ExecError.AotLibraryInvalid;

    var opened = try openAotLibrary(allocator, record.lib_path, record.symbol);
    defer opened.lib.close();

    const params = try parseAotParams(allocator, source, meta.main);
    defer allocator.free(params);
    const slot_count = aotSlotCount(params);
    if (slot_count > aot_max_slots) return ExecError.AotUnsupportedShape;

    var write_lock: ?table_mod.TableWriteLock = null;
    defer if (write_lock) |*lock| lock.release();
    var write_table: ?WriteTable = null;
    defer if (write_table) |*table| table.deinit(allocator);
    var read_table: ?ReadTable = null;
    defer if (read_table) |*table| table.deinit(allocator);

    if (shape.write_table) |table_name| {
        write_lock = try acquireTableWriteLock(allocator, table_name);
        write_table = try loadWriteTable(allocator, table_name);
    }
    const same_table = shape.read_table != null and shape.write_table != null and std.mem.eql(u8, shape.read_table.?, shape.write_table.?);
    if (shape.read_table) |table_name| {
        if (!same_table) read_table = try loadReadTable(allocator, table_name);
    }
    if (write_table != null and read_table != null and write_table.?.row_count != read_table.?.row_count) return ExecError.InvalidFormat;
    const row_count: u64 = if (write_table) |table| table.row_count else if (read_table) |table| table.row_count else 0;

    var staged = std.array_list.Managed(StagedColumn).init(allocator);
    defer {
        for (staged.items) |*column| column.deinit(allocator);
        staged.deinit();
    }

    var cursor = ParamCursor{ .allocator = allocator, .params_path = params_path };
    defer cursor.deinit();

    var slots: [aot_max_slots]u64 = undefined;
    var slot_idx: usize = 0;
    for (params) |param| {
        switch (param) {
            .column => |column_name| {
                const buffer = try aotColumnBuffer(allocator, &staged, if (write_table) |*table| table else null, if (read_table) |*table| table else null, column_name);
                slots[slot_idx] = @intFromPtr(buffer.ptr);
                slots[slot_idx + 1] = @intCast(buffer.len);
                slot_idx += 2;
            },
            .row_count => {
                slots[slot_idx] = row_count;
                slot_idx += 1;
            },
            .scalar => {
                slots[slot_idx] = try cursor.readU64();
                slot_idx += 1;
            },
        }
    }
    try cursor.finish();

    const result = opened.main_fn(slots[0..slot_count].ptr, @intCast(slot_count));

    if (write_table) |*table| {
        for (staged.items) |*column| column.copyBack();
        try commitWriteTable(allocator, table);
    }
    return result;
}

pub fn execQuery(allocator: std.mem.Allocator, hash_text: []const u8, params_path: ?[]const u8) ExecError!ExecRun {
    return execQueryWithFuel(allocator, hash_text, params_path, null);
}

pub fn execQueryWithFuel(allocator: std.mem.Allocator, hash_text: []const u8, params_path: ?[]const u8, fuel_limit: ?u64) ExecError!ExecRun {
    var meter = FuelMeter{ .limit = try resolveFuelLimit(fuel_limit) };
    const t_registry = ScopedTimer.begin(.registry_meta);
    var parsed = try loadMeta(allocator, hash_text);
    t_registry.end();
    defer parsed.deinit();
    if (params_path) |path| {
        const t_params = ScopedTimer.begin(.params_read);
        const params = try readFileAlloc(allocator, path, 64 * 1024 * 1024);
        t_params.end();
        allocator.free(params);
    }
    const hash = try parseHashHex(parsed.value.hash);
    const t_qmod = ScopedTimer.begin(.qmod_load);
    const qmod_source = readFileAlloc(allocator, parsed.value.qmod_path, 16 * 1024 * 1024) catch |err| switch (err) {
        ExecError.FileNotFound => return ExecError.QueryPayloadCorrupted,
        else => return err,
    };
    t_qmod.end();
    defer allocator.free(qmod_source);
    if (!std.mem.eql(u8, &hashBytes(qmod_source), &hash)) return ExecError.QueryPayloadCorrupted;
    try validateExecPayload(allocator, parsed.value, qmod_source);
    if (parsed.value.aot) |record| {
        // An AOT record is an explicit per-module opt-in: the module
        // runs natively or fails loudly. There is no fallback to the
        // interpreter from this branch.
        const aot_result = try execAotQmod(allocator, parsed.value, record, qmod_source, params_path);
        return .{ .ok = .{
            .code = 0,
            .function_name = try allocator.dupe(u8, parsed.value.main),
            .hash = hash,
            .result_u64 = aot_result,
            .fuel_used = meter.used,
            .fuel_limit = meter.limit,
            .aot = true,
        } };
    }
    const t_scalar = ScopedTimer.begin(.scalar_eval);
    const scalar_result = evalScalarQmod(allocator, qmod_source, parsed.value.main, params_path, &meter) catch |err| switch (err) {
        ExecError.UnsupportedOperation => null,
        else => return err,
    };
    t_scalar.end();
    const db_result = if (scalar_result == null)
        (evalReadonlyDbQmod(allocator, qmod_source, parsed.value.main, parsed.value.grant_entries, params_path, &meter) catch |err| switch (err) {
            ExecError.UnsupportedOperation => null,
            else => return err,
        })
    else
        null;
    const write_result = if (scalar_result == null and db_result == null)
        (evalWriteDbQmod(allocator, qmod_source, parsed.value.main, parsed.value.grant_entries, params_path, &meter) catch |err| switch (err) {
            ExecError.UnsupportedOperation => null,
            else => return err,
        })
    else
        null;
    const read_write_result = if (scalar_result == null and db_result == null and write_result == null)
        (evalReadWriteDbQmod(allocator, qmod_source, parsed.value.main, parsed.value.grant_entries, params_path, &meter) catch |err| switch (err) {
            ExecError.UnsupportedOperation => null,
            else => return err,
        })
    else
        null;
    const atomic_result = if (scalar_result == null and db_result == null and write_result == null and read_write_result == null)
        (evalAtomicDbQmod(allocator, qmod_source, parsed.value.main, parsed.value.grant_entries, params_path, &meter) catch |err| switch (err) {
            ExecError.UnsupportedOperation => null,
            else => return err,
        })
    else
        null;
    const final_result = scalar_result orelse db_result orelse write_result orelse read_write_result orelse atomic_result;
    return .{ .ok = .{
        .code = if (final_result == null) 12 else 0,
        .function_name = try allocator.dupe(u8, parsed.value.main),
        .hash = hash,
        .result_u64 = final_result,
        .fuel_used = meter.used,
        .fuel_limit = meter.limit,
    } };
}

/// One independent exec request for `execQueriesParallel`.
pub const ExecRequest = struct {
    hash_text: []const u8,
    params_path: ?[]const u8 = null,
    fuel_limit: ?u64 = null,
};

/// Per-request outcome of `execQueriesParallel`, in request order.
/// Exactly one of `run` / `err` is set.
pub const ExecOutcome = struct {
    run: ?ExecRun = null,
    err: ?ExecError = null,

    pub fn deinit(self: *ExecOutcome, allocator: std.mem.Allocator) void {
        if (self.run) |*run| run.deinit(allocator);
        self.* = undefined;
    }
};

const ParallelExecCtx = struct {
    allocator: std.mem.Allocator,
    requests: []const ExecRequest,
    outcomes: []ExecOutcome,
    next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn runOne(self: *ParallelExecCtx, idx: usize) void {
        const request = self.requests[idx];
        if (execQueryWithFuel(self.allocator, request.hash_text, request.params_path, request.fuel_limit)) |run| {
            self.outcomes[idx].run = run;
        } else |err| {
            self.outcomes[idx].err = err;
        }
    }

    fn worker(self: *ParallelExecCtx) void {
        while (true) {
            const idx = self.next.fetchAdd(1, .monotonic);
            if (idx >= self.requests.len) return;
            self.runOne(idx);
        }
    }
};

/// Run independent exec requests concurrently — the in-process
/// parallel surface of the epoch concurrency model
/// (docs/vm_concurrency_epoch.md §4). Read requests execute truly
/// in parallel against pinned epoch snapshots; write requests
/// serialize per table on the existing table write lock. Each
/// request gets its own fuel meter, exactly as a solo
/// `execQueryWithFuel` call would.
///
/// `execQuery` / `execQueryWithFuel` are safe to call concurrently
/// from multiple threads under the same condition this helper
/// requires of its caller: `allocator` must be thread-safe (for
/// example `std.heap.smp_allocator`, or a per-process debug
/// allocator in tests). All evaluator state is per-call; this file
/// keeps no mutable globals — the only shared state is the epoch
/// runtime's mutex-guarded pin registry and the table layer's
/// already-guarded caches.
///
/// `max_threads` bounds the worker pool (and is clamped to the
/// request count); 0 or 1 runs everything on the calling thread.
/// If a worker thread cannot be spawned, the remaining requests
/// still run on the calling thread — requests are never dropped.
pub fn execQueriesParallel(allocator: std.mem.Allocator, requests: []const ExecRequest, max_threads: usize) error{OutOfMemory}![]ExecOutcome {
    const outcomes = try allocator.alloc(ExecOutcome, requests.len);
    for (outcomes) |*outcome| outcome.* = .{};
    if (requests.len == 0) return outcomes;

    const worker_count = @min(@max(max_threads, 1), requests.len);
    if (worker_count == 1) {
        for (requests, 0..) |_, idx| {
            var ctx = ParallelExecCtx{ .allocator = allocator, .requests = requests, .outcomes = outcomes };
            ctx.runOne(idx);
        }
        return outcomes;
    }

    var ctx = ParallelExecCtx{ .allocator = allocator, .requests = requests, .outcomes = outcomes };
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    var spawned: usize = 0;
    defer {
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (threads) |*thread| {
        thread.* = std.Thread.spawn(.{}, ParallelExecCtx.worker, .{&ctx}) catch break;
        spawned += 1;
    }
    // If spawning fell short (including zero), drain the rest here;
    // the atomic cursor makes this race-safe with live workers.
    if (spawned < worker_count) ctx.worker();
    return outcomes;
}

test "qmod register inspect and exec metadata round trip" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\@import "simple.sadb-schema"
        \\grants [db_read:simple]
        \\@main(id: u64, factor: u64) -> u64:
        \\L_ENTRY:
        \\total = add id, factor
        \\return total
    );

    var result = try registerQuery(std.testing.allocator, "simple.query.sa");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), result.imports);
    try std.testing.expectEqual(@as(u64, 1), result.grants);

    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);
    const inspect = try inspectRegistry(std.testing.allocator, hash_hex);
    defer std.testing.allocator.free(inspect);
    try std.testing.expect(std.mem.containsAtLeast(u8, inspect, 1, "imports: 1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, inspect, 1, "grants: 1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, inspect, 1, "grant: db_read:simple"));

    var params = try (sio.Dir{ .inner = tmp.dir }).createFile("params.bin", .{ .truncate = true });
    defer params.close();
    var param_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 7, .little);
    std.mem.writeInt(u64, param_bytes[8..16], 5, .little);
    try params.writeAll(&param_bytes);

    var run = try execQuery(std.testing.allocator, hash_hex, "params.bin");
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), run.ok.code);
    try std.testing.expectEqual(@as(u64, 12), run.ok.result_u64.?);
}

test "qmod exec rejects malformed query hash text" {
    try std.testing.expectError(ExecError.InvalidQueryHash, execQuery(std.testing.allocator, "not-a-hash", null));
}

test "qmod inspect rejects malformed query hash text" {
    const malformed = "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg";
    try std.testing.expectError(ExecError.InvalidQueryHash, inspectRegistry(std.testing.allocator, malformed));
}

test "qmod exec distinguishes unknown query hash from malformed hash" {
    const unknown = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expectError(ExecError.QueryHashUnknown, execQuery(std.testing.allocator, unknown, null));
}

test "qmod inspect rejects corrupted registry metadata" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var first = try (sio.Dir{ .inner = tmp.dir }).createFile("first.query.sa", .{ .truncate = true });
    defer first.close();
    try first.writeAll(
        \\@main() -> u64:
        \\L_ENTRY:
        \\return 1
    );
    var second = try (sio.Dir{ .inner = tmp.dir }).createFile("second.query.sa", .{ .truncate = true });
    defer second.close();
    try second.writeAll(
        \\@main() -> u64:
        \\L_ENTRY:
        \\return 2
    );

    var first_result = try registerQuery(std.testing.allocator, "first.query.sa");
    defer first_result.deinit(std.testing.allocator);
    var second_result = try registerQuery(std.testing.allocator, "second.query.sa");
    defer second_result.deinit(std.testing.allocator);

    const first_hash = try hashHexAlloc(std.testing.allocator, first_result.hash);
    defer std.testing.allocator.free(first_hash);
    const second_hash = try hashHexAlloc(std.testing.allocator, second_result.hash);
    defer std.testing.allocator.free(second_hash);
    const second_meta = try metaPath(std.testing.allocator, second_hash);
    defer std.testing.allocator.free(second_meta);
    const first_meta = try metaPath(std.testing.allocator, first_hash);
    defer std.testing.allocator.free(first_meta);

    const replacement = try readFileAlloc(std.testing.allocator, second_meta, 16 * 1024 * 1024);
    defer std.testing.allocator.free(replacement);
    try writeFile(first_meta, replacement);

    try std.testing.expectError(ExecError.QueryRegistryCorrupted, inspectRegistry(std.testing.allocator, first_hash));
}

test "qmod exec rejects corrupted registry metadata" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var first = try (sio.Dir{ .inner = tmp.dir }).createFile("first.query.sa", .{ .truncate = true });
    defer first.close();
    try first.writeAll(
        \\@main() -> u64:
        \\L_ENTRY:
        \\return 1
    );
    var second = try (sio.Dir{ .inner = tmp.dir }).createFile("second.query.sa", .{ .truncate = true });
    defer second.close();
    try second.writeAll(
        \\@main() -> u64:
        \\L_ENTRY:
        \\return 2
    );

    var first_result = try registerQuery(std.testing.allocator, "first.query.sa");
    defer first_result.deinit(std.testing.allocator);
    var second_result = try registerQuery(std.testing.allocator, "second.query.sa");
    defer second_result.deinit(std.testing.allocator);

    const first_hash = try hashHexAlloc(std.testing.allocator, first_result.hash);
    defer std.testing.allocator.free(first_hash);
    const second_hash = try hashHexAlloc(std.testing.allocator, second_result.hash);
    defer std.testing.allocator.free(second_hash);
    const second_meta = try metaPath(std.testing.allocator, second_hash);
    defer std.testing.allocator.free(second_meta);
    const first_meta = try metaPath(std.testing.allocator, first_hash);
    defer std.testing.allocator.free(first_meta);

    const replacement = try readFileAlloc(std.testing.allocator, second_meta, 16 * 1024 * 1024);
    defer std.testing.allocator.free(replacement);
    try writeFile(first_meta, replacement);

    try std.testing.expectError(ExecError.QueryRegistryCorrupted, execQuery(std.testing.allocator, first_hash, null));
}

test "qmod exec rejects corrupted query payload" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\@main() -> u64:
        \\L_ENTRY:
        \\return 1
    );

    var result = try registerQuery(std.testing.allocator, "simple.query.sa");
    defer result.deinit(std.testing.allocator);

    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);

    try writeFile(result.qmod_path, "@main() -> u64:\nL_ENTRY:\nreturn 2\n");

    try std.testing.expectError(ExecError.QueryPayloadCorrupted, execQuery(std.testing.allocator, hash_hex, null));
}

test "qmod exec rejects missing query payload" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\@main() -> u64:
        \\L_ENTRY:
        \\return 1
    );

    var result = try registerQuery(std.testing.allocator, "simple.query.sa");
    defer result.deinit(std.testing.allocator);

    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);

    try sio.cwd().deleteFile(result.qmod_path);

    try std.testing.expectError(ExecError.QueryPayloadCorrupted, execQuery(std.testing.allocator, hash_hex, null));
}

test "qmod register rejects duplicate hash from different source path" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const query_text =
        \\grants [db_read:simple]
        \\@main(lhs: u64) -> u64:
        \\L_ENTRY:
        \\return lhs
    ;

    var first = try (sio.Dir{ .inner = tmp.dir }).createFile("first.query.sa", .{ .truncate = true });
    defer first.close();
    try first.writeAll(query_text);

    var second = try (sio.Dir{ .inner = tmp.dir }).createFile("second.query.sa", .{ .truncate = true });
    defer second.close();
    try second.writeAll(query_text);

    var first_result = try registerQuery(std.testing.allocator, "first.query.sa");
    defer first_result.deinit(std.testing.allocator);

    var second_same_path = try registerQuery(std.testing.allocator, "first.query.sa");
    defer second_same_path.deinit(std.testing.allocator);

    try std.testing.expectError(ExecError.DuplicateRegister, registerQuery(std.testing.allocator, "second.query.sa"));

    const hash_hex = try hashHexAlloc(std.testing.allocator, first_result.hash);
    defer std.testing.allocator.free(hash_hex);
    const inspect = try inspectRegistry(std.testing.allocator, hash_hex);
    defer std.testing.allocator.free(inspect);
    try std.testing.expect(std.mem.containsAtLeast(u8, inspect, 1, "source: first.query.sa"));
}

test "qmod exec rejects trailing scalar params bytes" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("scalar.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\@main(lhs: u64, rhs: u64) -> u64:
        \\L_ENTRY:
        \\sum = add lhs, rhs
        \\return sum
    );

    var result = try registerQuery(std.testing.allocator, "scalar.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);

    var params = try (sio.Dir{ .inner = tmp.dir }).createFile("params.bin", .{ .truncate = true });
    defer params.close();
    var param_bytes: [24]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 7, .little);
    std.mem.writeInt(u64, param_bytes[8..16], 5, .little);
    std.mem.writeInt(u64, param_bytes[16..24], 99, .little);
    try params.writeAll(&param_bytes);

    try std.testing.expectError(ExecError.InvalidParams, execQuery(std.testing.allocator, hash_hex, "params.bin"));
}

test "qmod exec supports scalar bitwise and shift ops" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("bitwise.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\@main(lhs: u64, rhs: u64) -> u64:
        \\L_ENTRY:
        \\mask = and lhs, rhs
        \\bits = or lhs, rhs
        \\delta = xor bits, mask
        \\wide = shl mask, 1
        \\folded = lshr wide, 2
        \\result = add folded, delta
        \\return result
    );

    var result = try registerQuery(std.testing.allocator, "bitwise.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);

    var params = try (sio.Dir{ .inner = tmp.dir }).createFile("params.bin", .{ .truncate = true });
    defer params.close();
    var param_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 0b1010, .little);
    std.mem.writeInt(u64, param_bytes[8..16], 0b1100, .little);
    try params.writeAll(&param_bytes);

    var run = try execQuery(std.testing.allocator, hash_hex, "params.bin");
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), run.ok.code);
    try std.testing.expectEqual(@as(u64, 10), run.ok.result_u64.?);
}

test "qmod register rejects DB instructions without matching grants" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    {
        var query = try (sio.Dir{ .inner = tmp.dir }).createFile("missing_read.query.sa", .{ .truncate = true });
        defer query.close();
        try query.writeAll(
            \\@main(&col_id: ptr) -> u64:
            \\L_ENTRY:
            \\id = load col_id+0 as u64
            \\return id
        );
        try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "missing_read.query.sa"));
    }
    {
        var query = try (sio.Dir{ .inner = tmp.dir }).createFile("missing_write.query.sa", .{ .truncate = true });
        defer query.close();
        try query.writeAll(
            \\grants [db_read:simple]
            \\@main(&col_id: ptr) -> u64:
            \\L_ENTRY:
            \\store col_id+0, 1 as u64
            \\return 0
        );
        try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "missing_write.query.sa"));
    }
    {
        var query = try (sio.Dir{ .inner = tmp.dir }).createFile("missing_cursor.query.sa", .{ .truncate = true });
        defer query.close();
        try query.writeAll(
            \\grants [db_write:simple]
            \\@main(&cursor: ptr) -> u64:
            \\L_ENTRY:
            \\old = atomic_rmw_add cursor+0, 1
            \\return old
        );
        try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "missing_cursor.query.sa"));
    }
}

test "qmod register rejects columns outside db_read schema" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("missing_column.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_missing: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\offset = mul 0, 8
        \\value = load col_missing+offset as u64
        \\return value
    );
    try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "missing_column.query.sa"));
}

test "qmod register rejects loads from undeclared DB pointers" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("wrong_pointer.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\offset = mul 0, 8
        \\value = load other+offset as u64
        \\return value
    );
    try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "wrong_pointer.query.sa"));
}

test "qmod register rejects load pointer smuggled through helper signature" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("helper_pointer.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@helper(&col_id: ptr) -> u64:
        \\L_HELPER:
        \\return 0
        \\@main(len: u64) -> u64:
        \\L_ENTRY:
        \\value = load col_id+0 as u64
        \\return value
    );
    try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "helper_pointer.query.sa"));
}

test "qmod register rejects DB column pointer declared with non-ptr type" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("bad_pointer_type.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: u64, len: u64) -> u64:
        \\L_ENTRY:
        \\value = load col_id+0 as u64
        \\return value
    );
    try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "bad_pointer_type.query.sa"));
}

test "qmod register rejects stores outside db_write schema" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("bad_store_column.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_write:simple]
        \\@main(&col_missing: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\store col_missing+0, 1 as u64
        \\return 0
    );
    try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "bad_store_column.query.sa"));
}

test "qmod register rejects stores from undeclared DB pointers" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("bad_store_pointer.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_write:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\store other+0, 1 as u64
        \\return 0
    );
    try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "bad_store_pointer.query.sa"));
}

test "qmod register rejects atomic cursor from undeclared DB pointers" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("bad_atomic_pointer.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_atomic_cursor:simple]
        \\@main(&cursor: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\old = atomic_rmw_add other+0, 1
        \\return old
    );
    try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "bad_atomic_pointer.query.sa"));
}

test "qmod register accepts declared atomic cursor grant" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("atomic_ok.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_atomic_cursor:simple]
        \\@main(&cursor: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\old = atomic_rmw_add cursor+0, 1
        \\return old
    );
    var result = try registerQuery(std.testing.allocator, "atomic_ok.query.sa");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), result.grants);
}

test "qmod register rejects atomic cursor nonzero offset" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("atomic_offset.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_atomic_cursor:simple]
        \\@main(&cursor: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\old = atomic_rmw_add cursor+8, 1
        \\return old
    );
    try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "atomic_offset.query.sa"));
}

test "qmod register rejects atomic cursor against non-u64 base column" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_COUNT_STRIDE = 4 // u32
        \\#def TABLE_ROW_BYTES = 4
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("atomic_u32_base.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_atomic_cursor:simple]
        \\@main(&cursor: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\old = atomic_rmw_add cursor+0, 1
        \\return old
    );
    try std.testing.expectError(ExecError.ColumnTypeMismatch, registerQuery(std.testing.allocator, "atomic_u32_base.query.sa"));
}

test "qmod register rejects atomic named cursor against non-u64 column" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_SCORE_STRIDE = 4 // u32
        \\#def TABLE_ROW_BYTES = 12
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("atomic_u32_named.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_atomic_cursor:simple]
        \\@main(&cursor_score: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\old = atomic_rmw_add cursor_score+0, 1
        \\return old
    );
    try std.testing.expectError(ExecError.ColumnTypeMismatch, registerQuery(std.testing.allocator, "atomic_u32_named.query.sa"));
}

test "qmod register rejects atomic cursor smuggled through helper signature" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("atomic_helper_pointer.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_atomic_cursor:simple]
        \\@helper(&cursor: ptr) -> u64:
        \\L_HELPER:
        \\return 0
        \\@main(len: u64) -> u64:
        \\L_ENTRY:
        \\old = atomic_rmw_add cursor+0, 1
        \\return old
    );
    try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "atomic_helper_pointer.query.sa"));
}

test "qmod exec reads u64 DB column segments" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv1 = try (sio.Dir{ .inner = tmp.dir }).createFile("rows1.csv", .{ .truncate = true });
    defer csv1.close();
    try csv1.writeAll(
        \\id
        \\1
        \\2
    );
    var csv2 = try (sio.Dir{ .inner = tmp.dir }).createFile("rows2.csv", .{ .truncate = true });
    defer csv2.close();
    try csv2.writeAll(
        \\id
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows1.csv");
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows2.csv");

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\sum = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_id+offset as u64
        \\sum = add sum, value
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return sum
    );

    var result = try registerQuery(std.testing.allocator, "sum.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);
    var run = try execQuery(std.testing.allocator, hash_hex, null);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), run.ok.code);
    try std.testing.expectEqual(@as(u64, 6), run.ok.result_u64.?);
}

test "qmod exec rejects table schema hash drift" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\sum = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_id+offset as u64
        \\sum = add sum, value
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return sum
    );

    var result = try registerQuery(std.testing.allocator, "sum.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);

    var drifted_schema = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer drifted_schema.close();
    try drifted_schema.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
        \\#def SCHEMA_EPOCH = 2
    );

    try std.testing.expectError(ExecError.SchemaMismatch, execQuery(std.testing.allocator, hash_hex, null));
}

test "qmod exec rejects corrupted table snapshot segment" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\value = load col_id+0 as u64
        \\return value
    );

    var result = try registerQuery(std.testing.allocator, "sum.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);

    const meta_bytes = try readActiveTableMetaSource(std.testing.allocator, "simple");
    defer std.testing.allocator.free(meta_bytes);
    var parsed = try std.json.parseFromSlice(QmodTableMeta, std.testing.allocator, meta_bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    var file = try sio.cwd().openFile(parsed.value.segments[0].files[0].path, .{ .mode = .read_write });
    defer file.close();
    const end_pos = try file.getEndPos();
    try file.seekTo(end_pos);
    try file.writeAll("x");

    try std.testing.expectError(ExecError.SnapshotCorrupted, execQuery(std.testing.allocator, hash_hex, null));
}

test "qmod exec rejects table snapshot block checksum metadata drift" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try table_mod.ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\value = load col_id+0 as u64
        \\return value
    );

    var result = try registerQuery(std.testing.allocator, "sum.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);

    var meta = try table_mod.loadActiveMeta(std.testing.allocator, ".", "simple");
    defer meta.deinit(std.testing.allocator);
    try std.testing.expect(meta.segments[0].files[0].block_sha256.len > 0);
    std.testing.allocator.free(meta.segments[0].files[0].block_sha256[0]);
    meta.segments[0].files[0].block_sha256[0] = try std.testing.allocator.dupe(u8, "0000000000000000000000000000000000000000000000000000000000000000");
    try table_mod.commitTableMetaUnlocked(std.testing.allocator, ".", "simple", meta);

    try std.testing.expectError(ExecError.SnapshotCorrupted, execQuery(std.testing.allocator, hash_hex, null));
}

test "qmod exec rejects corrupted table snapshot metadata" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\value = load col_id+0 as u64
        \\return value
    );

    var result = try registerQuery(std.testing.allocator, "sum.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);

    try writeFile("simple.manifest", "{not-json}\n");

    try std.testing.expectError(ExecError.SnapshotCorrupted, execQuery(std.testing.allocator, hash_hex, null));
}

test "qmod write rejects corrupted table snapshot metadata" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var params_file = try (sio.Dir{ .inner = tmp.dir }).createFile("params.bin", .{ .truncate = true });
    defer params_file.close();
    var param_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 1, .little);
    std.mem.writeInt(u64, param_bytes[8..16], 9, .little);
    try params_file.writeAll(&param_bytes);

    var write_query = try (sio.Dir{ .inner = tmp.dir }).createFile("write.query.sa", .{ .truncate = true });
    defer write_query.close();
    try write_query.writeAll(
        \\grants [db_write:simple]
        \\@main(&col_id: ptr, len: u64, row: u64, value: u64) -> u64:
        \\L_ENTRY:
        \\offset = mul row, 8
        \\store col_id+offset, value as u64
        \\return value
    );

    var write_result = try registerQuery(std.testing.allocator, "write.query.sa");
    defer write_result.deinit(std.testing.allocator);
    const write_hash = try hashHexAlloc(std.testing.allocator, write_result.hash);
    defer std.testing.allocator.free(write_hash);

    try writeFile("simple.manifest", "{not-json}\n");

    try std.testing.expectError(ExecError.SnapshotCorrupted, execQuery(std.testing.allocator, write_hash, "params.bin"));
}

test "qmod exec writes u64 DB column segments" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var params_file = try (sio.Dir{ .inner = tmp.dir }).createFile("params.bin", .{ .truncate = true });
    defer params_file.close();
    var param_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 1, .little);
    std.mem.writeInt(u64, param_bytes[8..16], 9, .little);
    try params_file.writeAll(&param_bytes);

    var write_query = try (sio.Dir{ .inner = tmp.dir }).createFile("write.query.sa", .{ .truncate = true });
    defer write_query.close();
    try write_query.writeAll(
        \\grants [db_write:simple]
        \\@main(&col_id: ptr, len: u64, row: u64, value: u64) -> u64:
        \\L_ENTRY:
        \\offset = mul row, 8
        \\store col_id+offset, value as u64
        \\return value
    );

    var write_result = try registerQuery(std.testing.allocator, "write.query.sa");
    defer write_result.deinit(std.testing.allocator);
    const write_hash = try hashHexAlloc(std.testing.allocator, write_result.hash);
    defer std.testing.allocator.free(write_hash);
    var write_run = try execQuery(std.testing.allocator, write_hash, "params.bin");
    defer write_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), write_run.ok.code);
    try std.testing.expectEqual(@as(u64, 9), write_run.ok.result_u64.?);

    _ = try @import("table.zig").verifyTable(std.testing.allocator, ".", "simple");

    var read_query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum.query.sa", .{ .truncate = true });
    defer read_query.close();
    try read_query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\sum = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_id+offset as u64
        \\sum = add sum, value
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return sum
    );

    var read_result = try registerQuery(std.testing.allocator, "sum.query.sa");
    defer read_result.deinit(std.testing.allocator);
    const read_hash = try hashHexAlloc(std.testing.allocator, read_result.hash);
    defer std.testing.allocator.free(read_hash);
    var read_run = try execQuery(std.testing.allocator, read_hash, null);
    defer read_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), read_run.ok.code);
    try std.testing.expectEqual(@as(u64, 10), read_run.ok.result_u64.?);
}

test "qmod exec read-modify-writes u64 DB column segments" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var params_file = try (sio.Dir{ .inner = tmp.dir }).createFile("params.bin", .{ .truncate = true });
    defer params_file.close();
    var param_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 1, .little);
    std.mem.writeInt(u64, param_bytes[8..16], 7, .little);
    try params_file.writeAll(&param_bytes);

    var update_query = try (sio.Dir{ .inner = tmp.dir }).createFile("update.query.sa", .{ .truncate = true });
    defer update_query.close();
    try update_query.writeAll(
        \\grants [db_read:simple, db_write:simple]
        \\@main(&col_id: ptr, len: u64, row: u64, delta: u64) -> u64:
        \\L_ENTRY:
        \\offset = mul row, 8
        \\old = load col_id+offset as u64
        \\new = add old, delta
        \\store col_id+offset, new as u64
        \\return new
    );

    var update_result = try registerQuery(std.testing.allocator, "update.query.sa");
    defer update_result.deinit(std.testing.allocator);
    const update_hash = try hashHexAlloc(std.testing.allocator, update_result.hash);
    defer std.testing.allocator.free(update_hash);
    var update_run = try execQuery(std.testing.allocator, update_hash, "params.bin");
    defer update_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), update_run.ok.code);
    try std.testing.expectEqual(@as(u64, 9), update_run.ok.result_u64.?);

    _ = try @import("table.zig").verifyTable(std.testing.allocator, ".", "simple");

    var read_query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum.query.sa", .{ .truncate = true });
    defer read_query.close();
    try read_query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\sum = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_id+offset as u64
        \\sum = add sum, value
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return sum
    );

    var read_result = try registerQuery(std.testing.allocator, "sum.query.sa");
    defer read_result.deinit(std.testing.allocator);
    const read_hash = try hashHexAlloc(std.testing.allocator, read_result.hash);
    defer std.testing.allocator.free(read_hash);
    var read_run = try execQuery(std.testing.allocator, read_hash, null);
    defer read_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), read_run.ok.code);
    try std.testing.expectEqual(@as(u64, 10), read_run.ok.result_u64.?);
}

test "qmod exec cross-table read-writes u64 DB column segments" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var src_schema = try (sio.Dir{ .inner = tmp.dir }).createFile("src.sadb-schema", .{ .truncate = true });
    defer src_schema.close();
    try src_schema.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var dst_schema = try (sio.Dir{ .inner = tmp.dir }).createFile("dst.sadb-schema", .{ .truncate = true });
    defer dst_schema.close();
    try dst_schema.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_SCORE_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var src_csv = try (sio.Dir{ .inner = tmp.dir }).createFile("src.csv", .{ .truncate = true });
    defer src_csv.close();
    try src_csv.writeAll(
        \\id
        \\1
        \\2
    );
    var dst_csv = try (sio.Dir{ .inner = tmp.dir }).createFile("dst.csv", .{ .truncate = true });
    defer dst_csv.close();
    try dst_csv.writeAll(
        \\score
        \\0
        \\0
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "src", "src.csv");
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "dst", "dst.csv");

    var params_file = try (sio.Dir{ .inner = tmp.dir }).createFile("params.bin", .{ .truncate = true });
    defer params_file.close();
    var param_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 1, .little);
    std.mem.writeInt(u64, param_bytes[8..16], 10, .little);
    try params_file.writeAll(&param_bytes);

    var copy_query = try (sio.Dir{ .inner = tmp.dir }).createFile("copy.query.sa", .{ .truncate = true });
    defer copy_query.close();
    try copy_query.writeAll(
        \\grants [db_read:src, db_write:dst]
        \\@main(&col_id: ptr, &col_score: ptr, len: u64, row: u64, delta: u64) -> u64:
        \\L_ENTRY:
        \\offset = mul row, 8
        \\old = load col_id+offset as u64
        \\new = add old, delta
        \\store col_score+offset, new as u64
        \\return new
    );

    var copy_result = try registerQuery(std.testing.allocator, "copy.query.sa");
    defer copy_result.deinit(std.testing.allocator);
    const copy_hash = try hashHexAlloc(std.testing.allocator, copy_result.hash);
    defer std.testing.allocator.free(copy_hash);
    var copy_run = try execQuery(std.testing.allocator, copy_hash, "params.bin");
    defer copy_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), copy_run.ok.code);
    try std.testing.expectEqual(@as(u64, 12), copy_run.ok.result_u64.?);

    _ = try @import("table.zig").verifyTable(std.testing.allocator, ".", "src");
    _ = try @import("table.zig").verifyTable(std.testing.allocator, ".", "dst");

    var read_query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum_dst.query.sa", .{ .truncate = true });
    defer read_query.close();
    try read_query.writeAll(
        \\grants [db_read:dst]
        \\@main(&col_score: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\sum = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_score+offset as u64
        \\sum = add sum, value
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return sum
    );

    var read_result = try registerQuery(std.testing.allocator, "sum_dst.query.sa");
    defer read_result.deinit(std.testing.allocator);
    const read_hash = try hashHexAlloc(std.testing.allocator, read_result.hash);
    defer std.testing.allocator.free(read_hash);
    var read_run = try execQuery(std.testing.allocator, read_hash, null);
    defer read_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), read_run.ok.code);
    try std.testing.expectEqual(@as(u64, 12), read_run.ok.result_u64.?);
}

test "qmod exec atomic cursor add updates u64 DB column" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\5
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var atomic_query = try (sio.Dir{ .inner = tmp.dir }).createFile("atomic.query.sa", .{ .truncate = true });
    defer atomic_query.close();
    try atomic_query.writeAll(
        \\grants [db_atomic_cursor:simple]
        \\@main(&cursor: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\old = atomic_rmw_add cursor+0, 3
        \\return old
    );

    var atomic_result = try registerQuery(std.testing.allocator, "atomic.query.sa");
    defer atomic_result.deinit(std.testing.allocator);
    const atomic_hash = try hashHexAlloc(std.testing.allocator, atomic_result.hash);
    defer std.testing.allocator.free(atomic_hash);
    var atomic_run = try execQuery(std.testing.allocator, atomic_hash, null);
    defer atomic_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), atomic_run.ok.code);
    try std.testing.expectEqual(@as(u64, 5), atomic_run.ok.result_u64.?);

    _ = try @import("table.zig").verifyTable(std.testing.allocator, ".", "simple");

    var read_query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum.query.sa", .{ .truncate = true });
    defer read_query.close();
    try read_query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\value = load col_id+0 as u64
        \\return value
    );

    var read_result = try registerQuery(std.testing.allocator, "sum.query.sa");
    defer read_result.deinit(std.testing.allocator);
    const read_hash = try hashHexAlloc(std.testing.allocator, read_result.hash);
    defer std.testing.allocator.free(read_hash);
    var read_run = try execQuery(std.testing.allocator, read_hash, null);
    defer read_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), read_run.ok.code);
    try std.testing.expectEqual(@as(u64, 8), read_run.ok.result_u64.?);
}

test "qmod register rejects atomic cursor dynamic offset expression" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\5
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var atomic_query = try (sio.Dir{ .inner = tmp.dir }).createFile("atomic_dynamic_offset.query.sa", .{ .truncate = true });
    defer atomic_query.close();
    try atomic_query.writeAll(
        \\grants [db_atomic_cursor:simple]
        \\@main(&cursor: ptr, len: u64, offset: u64) -> u64:
        \\L_ENTRY:
        \\old = atomic_rmw_add cursor+offset, 1
        \\return old
    );

    try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "atomic_dynamic_offset.query.sa"));
}

test "qmod exec atomic cursor targets named DB column" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_SCORE_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 16
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id,score
        \\5,7
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var atomic_query = try (sio.Dir{ .inner = tmp.dir }).createFile("atomic_score.query.sa", .{ .truncate = true });
    defer atomic_query.close();
    try atomic_query.writeAll(
        \\grants [db_atomic_cursor:simple]
        \\@main(&cursor_score: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\old = atomic_rmw_add cursor_score+0, 5
        \\return old
    );

    var atomic_result = try registerQuery(std.testing.allocator, "atomic_score.query.sa");
    defer atomic_result.deinit(std.testing.allocator);
    const atomic_hash = try hashHexAlloc(std.testing.allocator, atomic_result.hash);
    defer std.testing.allocator.free(atomic_hash);
    var atomic_run = try execQuery(std.testing.allocator, atomic_hash, null);
    defer atomic_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), atomic_run.ok.code);
    try std.testing.expectEqual(@as(u64, 7), atomic_run.ok.result_u64.?);

    _ = try @import("table.zig").verifyTable(std.testing.allocator, ".", "simple");

    var read_query = try (sio.Dir{ .inner = tmp.dir }).createFile("read.query.sa", .{ .truncate = true });
    defer read_query.close();
    try read_query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, &col_score: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\id = load col_id+0 as u64
        \\score = load col_score+0 as u64
        \\total = add id, score
        \\return total
    );

    var read_result = try registerQuery(std.testing.allocator, "read.query.sa");
    defer read_result.deinit(std.testing.allocator);
    const read_hash = try hashHexAlloc(std.testing.allocator, read_result.hash);
    defer std.testing.allocator.free(read_hash);
    var read_run = try execQuery(std.testing.allocator, read_hash, null);
    defer read_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), read_run.ok.code);
    try std.testing.expectEqual(@as(u64, 17), read_run.ok.result_u64.?);
}

test "qmod exec rejects writes against locked tables" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\5
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");
    _ = try @import("table.zig").lockTable(std.testing.allocator, ".", "simple");

    var write_query = try (sio.Dir{ .inner = tmp.dir }).createFile("write.query.sa", .{ .truncate = true });
    defer write_query.close();
    try write_query.writeAll(
        \\grants [db_write:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\store col_id+0, 9 as u64
        \\return 9
    );

    var write_result = try registerQuery(std.testing.allocator, "write.query.sa");
    defer write_result.deinit(std.testing.allocator);
    const write_hash = try hashHexAlloc(std.testing.allocator, write_result.hash);
    defer std.testing.allocator.free(write_hash);
    try std.testing.expectError(ExecError.Locked, execQuery(std.testing.allocator, write_hash, null));

    var atomic_query = try (sio.Dir{ .inner = tmp.dir }).createFile("atomic.query.sa", .{ .truncate = true });
    defer atomic_query.close();
    try atomic_query.writeAll(
        \\grants [db_atomic_cursor:simple]
        \\@main(&cursor: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\old = atomic_rmw_add cursor+0, 3
        \\return old
    );

    var atomic_result = try registerQuery(std.testing.allocator, "atomic.query.sa");
    defer atomic_result.deinit(std.testing.allocator);
    const atomic_hash = try hashHexAlloc(std.testing.allocator, atomic_result.hash);
    defer std.testing.allocator.free(atomic_hash);
    try std.testing.expectError(ExecError.Locked, execQuery(std.testing.allocator, atomic_hash, null));
}

test "qmod write commit rejects stale table metadata" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv1 = try (sio.Dir{ .inner = tmp.dir }).createFile("rows1.csv", .{ .truncate = true });
    defer csv1.close();
    try csv1.writeAll(
        \\id
        \\5
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows1.csv");

    var write_table = try loadWriteTable(std.testing.allocator, "simple");
    defer write_table.deinit(std.testing.allocator);
    const id_column = findWriteColumn(&write_table, "id") orelse return ExecError.InvalidFormat;
    try storeColumnValue(id_column, 0, 9);

    var csv2 = try (sio.Dir{ .inner = tmp.dir }).createFile("rows2.csv", .{ .truncate = true });
    defer csv2.close();
    try csv2.writeAll(
        \\id
        \\6
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows2.csv");

    try std.testing.expectError(ExecError.StaleMetadata, commitWriteTable(std.testing.allocator, &write_table));

    var read_table = try loadReadTable(std.testing.allocator, "simple");
    defer read_table.deinit(std.testing.allocator);
    const read_column = findColumn(read_table, "id") orelse return ExecError.InvalidFormat;
    try std.testing.expectEqual(@as(u64, 5), try loadColumnValue(read_column.*, 0));
    try std.testing.expectEqual(@as(u64, 6), try loadColumnValue(read_column.*, 8));
}

test "qmod write commit rejects stale block checksum metadata" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\5
    );
    _ = try table_mod.ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var write_table = try loadWriteTable(std.testing.allocator, "simple");
    defer write_table.deinit(std.testing.allocator);
    const id_column = findWriteColumn(&write_table, "id") orelse return ExecError.InvalidFormat;
    try storeColumnValue(id_column, 0, 9);

    var meta = try table_mod.loadActiveMeta(std.testing.allocator, ".", "simple");
    defer meta.deinit(std.testing.allocator);
    try std.testing.expect(meta.segments[0].files[0].block_sha256.len > 0);
    std.testing.allocator.free(meta.segments[0].files[0].block_sha256[0]);
    meta.segments[0].files[0].block_sha256[0] = try std.testing.allocator.dupe(u8, "1111111111111111111111111111111111111111111111111111111111111111");
    try table_mod.commitTableMetaUnlocked(std.testing.allocator, ".", "simple", meta);

    try std.testing.expectError(ExecError.StaleMetadata, commitWriteTable(std.testing.allocator, &write_table));
}

test "qmod exec filters u64 DB column values" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("count_gt.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\count = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_id+offset as u64
        \\hit = ugt value, 1
        \\br hit -> L_MATCH, L_NEXT
        \\L_MATCH:
        \\count = add count, 1
        \\jmp L_NEXT
        \\L_NEXT:
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return count
    );

    var result = try registerQuery(std.testing.allocator, "count_gt.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);
    var run = try execQuery(std.testing.allocator, hash_hex, null);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), run.ok.code);
    try std.testing.expectEqual(@as(u64, 2), run.ok.result_u64.?);
}

test "qmod exec filters DB column values with bitwise ops" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("count_odd.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\count = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_id+offset as u64
        \\low = and value, 1
        \\hit = eq low, 1
        \\br hit -> L_MATCH, L_NEXT
        \\L_MATCH:
        \\count = add count, 1
        \\jmp L_NEXT
        \\L_NEXT:
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return count
    );

    var result = try registerQuery(std.testing.allocator, "count_odd.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);
    var run = try execQuery(std.testing.allocator, hash_hex, null);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), run.ok.code);
    try std.testing.expectEqual(@as(u64, 2), run.ok.result_u64.?);
}

test "qmod exec reads compact unsigned DB columns" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("compact.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_SCORE_STRIDE = 4 // u32
        \\#def TABLE_ROW_BYTES = 4
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\score
        \\70000
        \\2
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "compact", "rows.csv");

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum_u32.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:compact]
        \\@main(&col_score: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\sum = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 4
        \\value = load col_score+offset as u64
        \\sum = add sum, value
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return sum
    );

    var result = try registerQuery(std.testing.allocator, "sum_u32.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);
    var run = try execQuery(std.testing.allocator, hash_hex, null);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), run.ok.code);
    try std.testing.expectEqual(@as(u64, 70005), run.ok.result_u64.?);
}

test "qmod exec reads signed integer DB columns" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("signed.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_DELTA_STRIDE = 4 // i32
        \\#def TABLE_ROW_BYTES = 4
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\delta
        \\-2
        \\5
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "signed", "rows.csv");

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum_i32.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:signed]
        \\@main(&col_delta: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\sum = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 4
        \\value = load col_delta+offset as u64
        \\sum = add sum, value
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return sum
    );

    var result = try registerQuery(std.testing.allocator, "sum_i32.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);
    var run = try execQuery(std.testing.allocator, hash_hex, null);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), run.ok.code);
    try std.testing.expectEqual(@as(u64, 3), run.ok.result_u64.?);
}

test "qmod exec filters DB column with u64 params" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var params_file = try (sio.Dir{ .inner = tmp.dir }).createFile("params.bin", .{ .truncate = true });
    defer params_file.close();
    var param_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 1, .little);
    try params_file.writeAll(&param_bytes);

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("count_param.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64, threshold: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\count = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_id+offset as u64
        \\hit = ugt value, threshold
        \\br hit -> L_MATCH, L_NEXT
        \\L_MATCH:
        \\count = add count, 1
        \\jmp L_NEXT
        \\L_NEXT:
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return count
    );

    var result = try registerQuery(std.testing.allocator, "count_param.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);
    var run = try execQuery(std.testing.allocator, hash_hex, "params.bin");
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), run.ok.code);
    try std.testing.expectEqual(@as(u64, 2), run.ok.result_u64.?);
}

test "qmod exec rejects trailing DB params bytes" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var params_file = try (sio.Dir{ .inner = tmp.dir }).createFile("params.bin", .{ .truncate = true });
    defer params_file.close();
    var param_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 1, .little);
    std.mem.writeInt(u64, param_bytes[8..16], 99, .little);
    try params_file.writeAll(&param_bytes);

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("count_param.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64, threshold: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\count = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_id+offset as u64
        \\hit = ugt value, threshold
        \\br hit -> L_MATCH, L_NEXT
        \\L_MATCH:
        \\count = add count, 1
        \\jmp L_NEXT
        \\L_NEXT:
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return count
    );

    var result = try registerQuery(std.testing.allocator, "count_param.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);
    try std.testing.expectError(ExecError.InvalidParams, execQuery(std.testing.allocator, hash_hex, "params.bin"));
}

test "qmod exec filters f32 DB column values" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("prices.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_PRICE_STRIDE = 4 // f32
        \\#def TABLE_ROW_BYTES = 4
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\price
        \\9.5
        \\12.25
        \\20.0
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "prices", "rows.csv");

    var params_file = try (sio.Dir{ .inner = tmp.dir }).createFile("params.bin", .{ .truncate = true });
    defer params_file.close();
    var param_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], @as(u64, @bitCast(@as(f64, 10.0))), .little);
    try params_file.writeAll(&param_bytes);

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("count_price.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:prices]
        \\@main(&col_price: ptr, len: u64, threshold: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\count = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 4
        \\value = load col_price+offset as u64
        \\hit = fcmp_gt value, threshold
        \\br hit -> L_MATCH, L_NEXT
        \\L_MATCH:
        \\count = add count, 1
        \\jmp L_NEXT
        \\L_NEXT:
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return count
    );

    var result = try registerQuery(std.testing.allocator, "count_price.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);
    var run = try execQuery(std.testing.allocator, hash_hex, "params.bin");
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), run.ok.code);
    try std.testing.expectEqual(@as(u64, 2), run.ok.result_u64.?);
}

test "qmod vm column primitives match loop aggregation" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("orders.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_QTY_STRIDE = 8 // u64
        \\#def COL_AMOUNT_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 24
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id,qty,amount
        \\1,2,100
        \\2,5,250
        \\3,1,40
        \\4,5,300
        \\5,3,150
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "orders", "rows.csv");

    const Case = struct { name: []const u8, source: []const u8, expected: u64 };
    const cases = [_]Case{
        .{
            .name = "loop_sum_where.query.sa",
            .source =
            \\grants [db_read:orders]
            \\@main(&col_qty: ptr, &col_amount: ptr, len: u64) -> u64:
            \\L_ENTRY:
            \\idx = add 0, 0
            \\sum = add 0, 0
            \\jmp L_COND
            \\L_COND:
            \\cond = ult idx, len
            \\br cond -> L_BODY, L_EXIT
            \\L_BODY:
            \\qoff = mul idx, 8
            \\qty = load col_qty+qoff as u64
            \\hit = eq qty, 5
            \\br hit -> L_MATCH, L_NEXT
            \\L_MATCH:
            \\aoff = mul idx, 8
            \\amt = load col_amount+aoff as u64
            \\sum = add sum, amt
            \\jmp L_NEXT
            \\L_NEXT:
            \\idx = add idx, 1
            \\jmp L_COND
            \\L_EXIT:
            \\return sum
            ,
            .expected = 550,
        },
        .{
            .name = "prim_sum_where.query.sa",
            .source =
            \\grants [db_read:orders]
            \\@main(&col_amount: ptr, &col_qty: ptr, len: u64) -> u64:
            \\L_ENTRY:
            \\total = col_sum_where_eq col_amount, len, col_qty, 5
            \\return total
            ,
            .expected = 550,
        },
        .{
            .name = "prim_sum.query.sa",
            .source =
            \\grants [db_read:orders]
            \\@main(&col_amount: ptr, len: u64) -> u64:
            \\L_ENTRY:
            \\total = col_sum col_amount, len
            \\return total
            ,
            .expected = 840,
        },
        .{
            .name = "prim_count_range.query.sa",
            .source =
            \\grants [db_read:orders]
            \\@main(&col_qty: ptr, len: u64) -> u64:
            \\L_ENTRY:
            \\hits = col_count_range col_qty, len, 3, 6
            \\return hits
            ,
            .expected = 3,
        },
        .{
            .name = "prim_count_eq.query.sa",
            .source =
            \\grants [db_read:orders]
            \\@main(&col_qty: ptr, len: u64) -> u64:
            \\L_ENTRY:
            \\hits = col_count_eq col_qty, len, 5
            \\return hits
            ,
            .expected = 2,
        },
        .{
            .name = "prim_min.query.sa",
            .source =
            \\grants [db_read:orders]
            \\@main(&col_amount: ptr, len: u64) -> u64:
            \\L_ENTRY:
            \\smallest = col_min col_amount, len
            \\return smallest
            ,
            .expected = 40,
        },
        .{
            .name = "prim_max.query.sa",
            .source =
            \\grants [db_read:orders]
            \\@main(&col_amount: ptr, len: u64) -> u64:
            \\L_ENTRY:
            \\largest = col_max col_amount, len
            \\return largest
            ,
            .expected = 300,
        },
    };
    for (cases) |case| {
        var query = try (sio.Dir{ .inner = tmp.dir }).createFile(case.name, .{ .truncate = true });
        try query.writeAll(case.source);
        query.close();
        var result = try registerQuery(std.testing.allocator, case.name);
        defer result.deinit(std.testing.allocator);
        const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
        defer std.testing.allocator.free(hash_hex);
        var run = try execQuery(std.testing.allocator, hash_hex, null);
        defer run.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), run.ok.code);
        try std.testing.expectEqual(case.expected, run.ok.result_u64.?);
        try std.testing.expect(run.ok.fuel_used > 0);
        try std.testing.expect(run.ok.fuel_used <= run.ok.fuel_limit);
    }
}

test "qmod fuel meter terminates unbounded and over-budget modules" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var loop_query = try (sio.Dir{ .inner = tmp.dir }).createFile("runaway.query.sa", .{ .truncate = true });
    defer loop_query.close();
    try loop_query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\zero = add 0, 0
        \\jmp L_TOP
        \\L_TOP:
        \\v = load col_id+zero as u64
        \\jmp L_TOP
    );
    var loop_result = try registerQuery(std.testing.allocator, "runaway.query.sa");
    defer loop_result.deinit(std.testing.allocator);
    const loop_hash = try hashHexAlloc(std.testing.allocator, loop_result.hash);
    defer std.testing.allocator.free(loop_hash);
    try std.testing.expectError(ExecError.FuelExhausted, execQueryWithFuel(std.testing.allocator, loop_hash, null, 1_000));
    try std.testing.expectError(ExecError.FuelExhausted, execQueryWithFuel(std.testing.allocator, loop_hash, null, null));

    var sum_query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum_ids.query.sa", .{ .truncate = true });
    defer sum_query.close();
    try sum_query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\sum = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_id+offset as u64
        \\sum = add sum, value
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return sum
    );
    var sum_result = try registerQuery(std.testing.allocator, "sum_ids.query.sa");
    defer sum_result.deinit(std.testing.allocator);
    const sum_hash = try hashHexAlloc(std.testing.allocator, sum_result.hash);
    defer std.testing.allocator.free(sum_hash);
    try std.testing.expectError(ExecError.FuelExhausted, execQueryWithFuel(std.testing.allocator, sum_hash, null, 10));
    var run = try execQueryWithFuel(std.testing.allocator, sum_hash, null, 100_000);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), run.ok.code);
    try std.testing.expectEqual(@as(u64, 6), run.ok.result_u64.?);
    try std.testing.expectEqual(@as(u64, 100_000), run.ok.fuel_limit);
    try std.testing.expect(run.ok.fuel_used > 10);
    try std.testing.expect(run.ok.fuel_used <= 100_000);

    try std.testing.expectError(ExecError.InvalidFuelLimit, resolveFuelLimit(0));
    try std.testing.expectEqual(@as(u64, 42), try resolveFuelLimit(42));
}

test "qmod column primitives reject float columns and overscan" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("flash.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_PRICE_STRIDE = 4 // f32
        \\#def TABLE_ROW_BYTES = 12
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id,price
        \\1,9.5
        \\2,10.25
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "flash", "rows.csv");

    var float_query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum_price.query.sa", .{ .truncate = true });
    defer float_query.close();
    try float_query.writeAll(
        \\grants [db_read:flash]
        \\@main(&col_price: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\total = col_sum col_price, len
        \\return total
    );
    var float_result = try registerQuery(std.testing.allocator, "sum_price.query.sa");
    defer float_result.deinit(std.testing.allocator);
    const float_hash = try hashHexAlloc(std.testing.allocator, float_result.hash);
    defer std.testing.allocator.free(float_hash);
    try std.testing.expectError(ExecError.ColumnTypeMismatch, execQuery(std.testing.allocator, float_hash, null));

    var over_query = try (sio.Dir{ .inner = tmp.dir }).createFile("overscan.query.sa", .{ .truncate = true });
    defer over_query.close();
    try over_query.writeAll(
        \\grants [db_read:flash]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\wide = add len, 10
        \\total = col_sum col_id, wide
        \\return total
    );
    var over_result = try registerQuery(std.testing.allocator, "overscan.query.sa");
    defer over_result.deinit(std.testing.allocator);
    const over_hash = try hashHexAlloc(std.testing.allocator, over_result.hash);
    defer std.testing.allocator.free(over_hash);
    try std.testing.expectError(ExecError.InvalidFormat, execQuery(std.testing.allocator, over_hash, null));

    var unknown_query = try (sio.Dir{ .inner = tmp.dir }).createFile("unknown_prim.query.sa", .{ .truncate = true });
    defer unknown_query.close();
    try unknown_query.writeAll(
        \\grants [db_read:flash]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\total = col_frobnicate col_id, len
        \\return total
    );
    var unknown_result = try registerQuery(std.testing.allocator, "unknown_prim.query.sa");
    defer unknown_result.deinit(std.testing.allocator);
    const unknown_hash = try hashHexAlloc(std.testing.allocator, unknown_result.hash);
    defer std.testing.allocator.free(unknown_hash);
    try std.testing.expectError(ExecError.InvalidFormat, execQuery(std.testing.allocator, unknown_hash, null));
}

test "qmod write procedure class is recorded in registry metadata" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );

    var read_query = try (sio.Dir{ .inner = tmp.dir }).createFile("read.query.sa", .{ .truncate = true });
    defer read_query.close();
    try read_query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\value = load col_id+0 as u64
        \\return value
    );
    var read_result = try registerQuery(std.testing.allocator, "read.query.sa");
    defer read_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("query", read_result.kind);
    try std.testing.expect(!read_result.write_capability);

    var write_query = try (sio.Dir{ .inner = tmp.dir }).createFile("write.query.sa", .{ .truncate = true });
    defer write_query.close();
    try write_query.writeAll(
        \\grants [db_write:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\store col_id+0, 1 as u64
        \\return 0
    );
    var write_result = try registerQuery(std.testing.allocator, "write.query.sa");
    defer write_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("procedure", write_result.kind);
    try std.testing.expect(write_result.write_capability);

    const write_hash = try hashHexAlloc(std.testing.allocator, write_result.hash);
    defer std.testing.allocator.free(write_hash);
    var parsed = try loadMeta(std.testing.allocator, write_hash);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 2), parsed.value.version);
    try std.testing.expectEqualStrings("procedure", parsed.value.kind);
    try std.testing.expect(parsed.value.write_capability);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.write_tables.len);
    try std.testing.expectEqualStrings("simple", parsed.value.write_tables[0]);

    const inspect = try inspectRegistry(std.testing.allocator, write_hash);
    defer std.testing.allocator.free(inspect);
    try std.testing.expect(std.mem.containsAtLeast(u8, inspect, 1, "kind: procedure"));
    try std.testing.expect(std.mem.containsAtLeast(u8, inspect, 1, "write_capability: true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, inspect, 1, "write_table: simple"));

    // Re-registering the same procedure from the same source path is
    // idempotent against its own version 2 record.
    var again_result = try registerQuery(std.testing.allocator, "write.query.sa");
    defer again_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("procedure", again_result.kind);
}

test "qmod exec rejects registry grant entries tampered after register" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\sum = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_id+offset as u64
        \\sum = add sum, value
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return sum
    );
    var result = try registerQuery(std.testing.allocator, "sum.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);

    var run = try execQuery(std.testing.allocator, hash_hex, null);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 3), run.ok.result_u64.?);

    // Escalate the record's grants on disk: the payload still declares
    // db_read only, so exec must refuse the mismatched record.
    const path = try metaPath(std.testing.allocator, hash_hex);
    defer std.testing.allocator.free(path);
    const meta_bytes = try readFileAlloc(std.testing.allocator, path, 16 * 1024 * 1024);
    defer std.testing.allocator.free(meta_bytes);
    const tampered = try std.mem.replaceOwned(u8, std.testing.allocator, meta_bytes, "db_read:simple", "db_write:simple");
    defer std.testing.allocator.free(tampered);
    try writeFile(path, tampered);

    try std.testing.expectError(ExecError.QueryRegistryCorrupted, execQuery(std.testing.allocator, hash_hex, null));
}

test "qmod exec rejects write procedure record with downgraded grants" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("write.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_write:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\store col_id+0, 7 as u64
        \\return 7
    );
    var result = try registerQuery(std.testing.allocator, "write.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);

    var run = try execQuery(std.testing.allocator, hash_hex, null);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 7), run.ok.result_u64.?);

    // Demote the record's grants on disk: the payload still declares
    // db_write, so exec must refuse the mismatched record instead of
    // silently running the procedure under a read-only description.
    const path = try metaPath(std.testing.allocator, hash_hex);
    defer std.testing.allocator.free(path);
    const meta_bytes = try readFileAlloc(std.testing.allocator, path, 16 * 1024 * 1024);
    defer std.testing.allocator.free(meta_bytes);
    const tampered = try std.mem.replaceOwned(u8, std.testing.allocator, meta_bytes, "db_write:simple", "db_read:simple");
    defer std.testing.allocator.free(tampered);
    try writeFile(path, tampered);

    try std.testing.expectError(ExecError.QueryRegistryCorrupted, execQuery(std.testing.allocator, hash_hex, null));
}

test "qmod exec rejects forged module class in registry record" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("write.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_write:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\store col_id+0, 1 as u64
        \\return 0
    );
    var result = try registerQuery(std.testing.allocator, "write.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);

    // Forge the stored class: the record now claims the module is a
    // read-only query while its grants declare a write procedure.
    const path = try metaPath(std.testing.allocator, hash_hex);
    defer std.testing.allocator.free(path);
    const meta_bytes = try readFileAlloc(std.testing.allocator, path, 16 * 1024 * 1024);
    defer std.testing.allocator.free(meta_bytes);
    const tampered = try std.mem.replaceOwned(u8, std.testing.allocator, meta_bytes, "procedure", "query");
    defer std.testing.allocator.free(tampered);
    try std.testing.expect(!std.mem.eql(u8, tampered, meta_bytes));
    try writeFile(path, tampered);

    try std.testing.expectError(ExecError.QueryRegistryCorrupted, execQuery(std.testing.allocator, hash_hex, null));
}

test "qmod write procedure fuel exhaustion leaves zero partial writes" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    // Read-write procedure: scale every row by 10, return the row count.
    var proc = try (sio.Dir{ .inner = tmp.dir }).createFile("scale.proc.sa", .{ .truncate = true });
    defer proc.close();
    try proc.writeAll(
        \\grants [db_read:simple, db_write:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_id+offset as u64
        \\scaled = mul value, 10
        \\store col_id+offset, scaled as u64
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return idx
    );
    var proc_result = try registerQuery(std.testing.allocator, "scale.proc.sa");
    defer proc_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("procedure", proc_result.kind);
    const proc_hash = try hashHexAlloc(std.testing.allocator, proc_result.hash);
    defer std.testing.allocator.free(proc_hash);

    var sum_query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum.query.sa", .{ .truncate = true });
    defer sum_query.close();
    try sum_query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\sum = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_id+offset as u64
        \\sum = add sum, value
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return sum
    );
    var sum_result = try registerQuery(std.testing.allocator, "sum.query.sa");
    defer sum_result.deinit(std.testing.allocator);
    const sum_hash = try hashHexAlloc(std.testing.allocator, sum_result.hash);
    defer std.testing.allocator.free(sum_hash);

    var sumsq_query = try (sio.Dir{ .inner = tmp.dir }).createFile("sumsq.query.sa", .{ .truncate = true });
    defer sumsq_query.close();
    try sumsq_query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\sum = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_id+offset as u64
        \\sq = mul value, value
        \\sum = add sum, sq
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return sum
    );
    var sumsq_result = try registerQuery(std.testing.allocator, "sumsq.query.sa");
    defer sumsq_result.deinit(std.testing.allocator);
    const sumsq_hash = try hashHexAlloc(std.testing.allocator, sumsq_result.hash);
    defer std.testing.allocator.free(sumsq_hash);

    // A budget of 5 steps cannot finish even the first row, but the
    // first store may already be staged when the meter runs out. The
    // staged write set must be discarded wholesale: both independent
    // aggregates still describe the original rows (1, 2, 3).
    try std.testing.expectError(ExecError.FuelExhausted, execQueryWithFuel(std.testing.allocator, proc_hash, null, 5));

    var sum_run = try execQuery(std.testing.allocator, sum_hash, null);
    defer sum_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 6), sum_run.ok.result_u64.?);
    var sumsq_run = try execQuery(std.testing.allocator, sumsq_hash, null);
    defer sumsq_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 14), sumsq_run.ok.result_u64.?);
    _ = try @import("table.zig").verifyTable(std.testing.allocator, ".", "simple");

    // With the default budget the same procedure commits atomically:
    // every scaled value becomes visible at once.
    var proc_run = try execQuery(std.testing.allocator, proc_hash, null);
    defer proc_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), proc_run.ok.code);
    try std.testing.expectEqual(@as(u64, 3), proc_run.ok.result_u64.?);

    var scaled_run = try execQuery(std.testing.allocator, sum_hash, null);
    defer scaled_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 60), scaled_run.ok.result_u64.?);
    _ = try @import("table.zig").verifyTable(std.testing.allocator, ".", "simple");
}

test "qmod write procedure mid error leaves zero partial writes" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    // The first store succeeds into the staged write set; the second
    // targets a byte offset far beyond the table and fails. The whole
    // procedure must roll back: row 0 keeps its original value.
    var proc = try (sio.Dir{ .inner = tmp.dir }).createFile("bad.proc.sa", .{ .truncate = true });
    defer proc.close();
    try proc.writeAll(
        \\grants [db_write:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\store col_id+0, 99 as u64
        \\store col_id+8000, 5 as u64
        \\return 0
    );
    var proc_result = try registerQuery(std.testing.allocator, "bad.proc.sa");
    defer proc_result.deinit(std.testing.allocator);
    const proc_hash = try hashHexAlloc(std.testing.allocator, proc_result.hash);
    defer std.testing.allocator.free(proc_hash);

    try std.testing.expectError(ExecError.InvalidFormat, execQuery(std.testing.allocator, proc_hash, null));

    var sum_query = try (sio.Dir{ .inner = tmp.dir }).createFile("sum.query.sa", .{ .truncate = true });
    defer sum_query.close();
    try sum_query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\sum = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_id+offset as u64
        \\sum = add sum, value
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return sum
    );
    var sum_result = try registerQuery(std.testing.allocator, "sum.query.sa");
    defer sum_result.deinit(std.testing.allocator);
    const sum_hash = try hashHexAlloc(std.testing.allocator, sum_result.hash);
    defer std.testing.allocator.free(sum_hash);
    var sum_run = try execQuery(std.testing.allocator, sum_hash, null);
    defer sum_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 6), sum_run.ok.result_u64.?);
    _ = try @import("table.zig").verifyTable(std.testing.allocator, ".", "simple");
}

test "qmod atomic cursor fuel exhaustion leaves cell unchanged" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try (sio.Dir{ .inner = tmp.dir }).createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\41
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var proc = try (sio.Dir{ .inner = tmp.dir }).createFile("spin.proc.sa", .{ .truncate = true });
    defer proc.close();
    try proc.writeAll(
        \\grants [db_atomic_cursor:simple]
        \\@main(&cursor: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\jmp L_LOOP
        \\L_LOOP:
        \\old = atomic_rmw_add cursor+0, 1
        \\jmp L_LOOP
    );
    var proc_result = try registerQuery(std.testing.allocator, "spin.proc.sa");
    defer proc_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("procedure", proc_result.kind);
    const proc_hash = try hashHexAlloc(std.testing.allocator, proc_result.hash);
    defer std.testing.allocator.free(proc_hash);

    try std.testing.expectError(ExecError.FuelExhausted, execQueryWithFuel(std.testing.allocator, proc_hash, null, 20));

    var read_query = try (sio.Dir{ .inner = tmp.dir }).createFile("read.query.sa", .{ .truncate = true });
    defer read_query.close();
    try read_query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\value = load col_id+0 as u64
        \\return value
    );
    var read_result = try registerQuery(std.testing.allocator, "read.query.sa");
    defer read_result.deinit(std.testing.allocator);
    const read_hash = try hashHexAlloc(std.testing.allocator, read_result.hash);
    defer std.testing.allocator.free(read_hash);
    var read_run = try execQuery(std.testing.allocator, read_hash, null);
    defer read_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 41), read_run.ok.result_u64.?);
}

test "qmod register-aot rejects missing library file" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("read.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\value = load col_id+0 as u64
        \\return value
    );
    var result = try registerQuery(std.testing.allocator, "read.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);

    try std.testing.expectError(ExecError.AotLibraryInvalid, registerAot(std.testing.allocator, hash_hex, "missing.so", null, false));
}

test "qmod register-aot rejects non-library file" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("read.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_read:simple]
        \\@main(&col_id: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\value = load col_id+0 as u64
        \\return value
    );
    var result = try registerQuery(std.testing.allocator, "read.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);

    var fake = try (sio.Dir{ .inner = tmp.dir }).createFile("fake.so", .{ .truncate = true });
    defer fake.close();
    try fake.writeAll("this is not a shared library\n");

    try std.testing.expectError(ExecError.AotLibraryInvalid, registerAot(std.testing.allocator, hash_hex, "fake.so", null, false));
}

test "qmod register-aot rejects atomic cursor shape" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try (sio.Dir{ .inner = tmp.dir }).createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try (sio.Dir{ .inner = tmp.dir }).createFile("atomic.query.sa", .{ .truncate = true });
    defer query.close();
    try query.writeAll(
        \\grants [db_atomic_cursor:simple]
        \\@main(&cursor: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\old = atomic_rmw_add cursor+0, 1
        \\return old
    );
    var result = try registerQuery(std.testing.allocator, "atomic.query.sa");
    defer result.deinit(std.testing.allocator);
    const hash_hex = try hashHexAlloc(std.testing.allocator, result.hash);
    defer std.testing.allocator.free(hash_hex);

    // The shape gate fires before the library is even read: the
    // atomic-cursor discipline has no AOT tier in step 2.
    try std.testing.expectError(ExecError.AotUnsupportedShape, registerAot(std.testing.allocator, hash_hex, "missing.so", null, false));
}

// ------------------------------------------------------------------
// Concurrency tests (VM concurrency line, Model A epoch protocol;
// docs/vm_concurrency_epoch.md). Fixtures mirror the serial tests
// above: tmp cwd, schema file, CSV ingest, register, exec.
// ------------------------------------------------------------------

fn concWriteFile(tmp: std.testing.TmpDir, name: []const u8, bytes: []const u8) !void {
    var file = try (sio.Dir{ .inner = tmp.dir }).createFile(name, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn concRegister(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, file_name: []const u8, source: []const u8) ![]u8 {
    try concWriteFile(tmp, file_name, source);
    var result = try registerQuery(allocator, file_name);
    defer result.deinit(allocator);
    return hashHexAlloc(allocator, result.hash);
}

/// Builds the two-column `conc` table (id, val) with `rows` rows and
/// val = `val_fill` everywhere, plus a one-column `counter` table.
/// Returns the registered module hashes used by the concurrency
/// tests.
const ConcFixture = struct {
    sum_hash: []u8,
    setall_hash: []u8,
    atomic_hash: []u8,
    counter_sum_hash: []u8,
};

fn concSetup(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, rows: u32, val_fill: u64) !ConcFixture {
    try concWriteFile(tmp, "conc.sadb-schema",
        \\#def MAX_ROWS = 65536
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_VAL_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 16
    );
    var csv_text = std.array_list.Managed(u8).init(allocator);
    defer csv_text.deinit();
    try csv_text.appendSlice("ID,VAL\n");
    var line_buf: [64]u8 = undefined;
    for (0..rows) |i| {
        const line = try std.fmt.bufPrint(&line_buf, "{d},{d}\n", .{ i, val_fill });
        try csv_text.appendSlice(line);
    }
    try concWriteFile(tmp, "conc.csv", csv_text.items);
    _ = try table_mod.ingestTable(allocator, ".", "conc", "conc.csv");

    try concWriteFile(tmp, "counter.sadb-schema",
        \\#def MAX_ROWS = 16
        \\#def COL_N_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    try concWriteFile(tmp, "counter.csv", "n\n0\n");
    _ = try table_mod.ingestTable(allocator, ".", "counter", "counter.csv");

    const sum_hash = try concRegister(allocator, tmp, "conc_sum.query.sa",
        \\grants [db_read:conc]
        \\@main(&col_val: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\total = col_sum col_val, len
        \\return total
    );
    errdefer allocator.free(sum_hash);
    const setall_hash = try concRegister(allocator, tmp, "conc_setall.query.sa",
        \\grants [db_write:conc]
        \\@main(&col_val: ptr, len: u64, value: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\store col_val+offset, value as u64
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return value
    );
    errdefer allocator.free(setall_hash);
    const atomic_hash = try concRegister(allocator, tmp, "conc_atomic.query.sa",
        \\grants [db_atomic_cursor:counter]
        \\@main(&cursor: ptr) -> u64:
        \\L_ENTRY:
        \\old = atomic_rmw_add cursor+0, 1
        \\return old
    );
    errdefer allocator.free(atomic_hash);
    const counter_sum_hash = try concRegister(allocator, tmp, "counter_sum.query.sa",
        \\grants [db_read:counter]
        \\@main(&col_n: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\total = col_sum col_n, len
        \\return total
    );
    return .{
        .sum_hash = sum_hash,
        .setall_hash = setall_hash,
        .atomic_hash = atomic_hash,
        .counter_sum_hash = counter_sum_hash,
    };
}

fn concFreeFixture(allocator: std.mem.Allocator, fixture: ConcFixture) void {
    allocator.free(fixture.sum_hash);
    allocator.free(fixture.setall_hash);
    allocator.free(fixture.atomic_hash);
    allocator.free(fixture.counter_sum_hash);
}

test "qmod concurrent readers and single writer keep the epoch oracle" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const rows: u64 = 200;
    const commits: u64 = 10;
    const fixture = try concSetup(std.testing.allocator, tmp, @intCast(rows), 0);
    defer concFreeFixture(std.testing.allocator, fixture);

    // Per-commit params files, written up front so worker threads
    // never write files.
    var param_names: [10][24]u8 = undefined;
    for (0..commits) |i| {
        const name = try std.fmt.bufPrint(&param_names[i], "cparams{d}.bin", .{i + 1});
        param_names[i][name.len] = 0;
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, i + 1, .little);
        try concWriteFile(tmp, name, &bytes);
    }

    // One warm exec adopts the setup epoch into the runtime.
    {
        var warm = try execQuery(std.testing.allocator, fixture.sum_hash, null);
        defer warm.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u64, 0), warm.ok.result_u64.?);
    }
    const base_epoch = epoch_runtime.currentEpoch("conc").?;

    const WriterCtx = struct {
        hash: []const u8,
        names: *const [10][24]u8,
        commits: u64,
        done: u64 = 0,
        bad: u64 = 0,
    };
    const writer_fn = struct {
        fn work(ctx: *WriterCtx) void {
            var gpa = std.heap.DebugAllocator(.{}){};
            defer _ = gpa.deinit();
            const alloc = gpa.allocator();
            var v: u64 = 1;
            while (v <= ctx.commits) : (v += 1) {
                const name = std.mem.sliceTo(&ctx.names[v - 1], 0);
                var run = execQuery(alloc, ctx.hash, name) catch {
                    ctx.bad += 1;
                    continue;
                };
                defer run.deinit(alloc);
                if (run.ok.code != 0 or run.ok.result_u64.? != v) ctx.bad += 1;
                ctx.done += 1;
            }
        }
    }.work;

    const ReaderCtx = struct {
        hash: []const u8,
        rows: u64,
        max_v: u64,
        execs: u64,
        done: u64 = 0,
        bad: u64 = 0,
    };
    const reader_fn = struct {
        fn work(ctx: *ReaderCtx) void {
            var gpa = std.heap.DebugAllocator(.{}){};
            defer _ = gpa.deinit();
            const alloc = gpa.allocator();
            var last_v: u64 = 0;
            var i: u64 = 0;
            while (i < ctx.execs) : (i += 1) {
                var run = execQuery(alloc, ctx.hash, null) catch {
                    ctx.bad += 1;
                    continue;
                };
                defer run.deinit(alloc);
                if (run.ok.code != 0) {
                    ctx.bad += 1;
                    continue;
                }
                const sum = run.ok.result_u64.?;
                // The oracle: every committed epoch has val == v in
                // all rows, so a consistent read is exactly v*rows
                // for some committed v, and v never goes backwards
                // for a single reader. Anything else is a torn read.
                if (sum % ctx.rows != 0) {
                    ctx.bad += 1;
                    continue;
                }
                const v = sum / ctx.rows;
                if (v > ctx.max_v or v < last_v) {
                    ctx.bad += 1;
                    continue;
                }
                last_v = v;
                ctx.done += 1;
            }
        }
    }.work;

    var writer_ctx = WriterCtx{ .hash = fixture.setall_hash, .names = &param_names, .commits = commits };
    var reader_ctxs: [4]ReaderCtx = undefined;
    for (&reader_ctxs) |*ctx| ctx.* = .{ .hash = fixture.sum_hash, .rows = rows, .max_v = commits, .execs = 30 };

    var writer_thread = try std.Thread.spawn(.{}, writer_fn, .{&writer_ctx});
    var reader_threads: [4]std.Thread = undefined;
    for (&reader_threads, &reader_ctxs) |*thread, *ctx| {
        thread.* = try std.Thread.spawn(.{}, reader_fn, .{ctx});
    }
    writer_thread.join();
    for (&reader_threads) |*thread| thread.join();

    try std.testing.expectEqual(@as(u64, 0), writer_ctx.bad);
    try std.testing.expectEqual(commits, writer_ctx.done);
    for (&reader_ctxs) |*ctx| {
        try std.testing.expectEqual(@as(u64, 0), ctx.bad);
        try std.testing.expectEqual(@as(u64, 30), ctx.done);
    }

    // Final state equals the serial oracle: the last commit wins.
    {
        var run = try execQuery(std.testing.allocator, fixture.sum_hash, null);
        defer run.deinit(std.testing.allocator);
        try std.testing.expectEqual(commits * rows, run.ok.result_u64.?);
    }
    _ = try table_mod.verifyTable(std.testing.allocator, ".", "conc");
    // Every pin drained; the runtime's current epoch is the last commit.
    try std.testing.expectEqual(@as(usize, 0), epoch_runtime.livePinCount("conc"));
    try std.testing.expectEqual(@as(?u64, null), epoch_runtime.oldestLiveEpoch("conc"));
    try std.testing.expectEqual(@as(?u64, base_epoch + commits), epoch_runtime.currentEpoch("conc"));
}

test "qmod concurrent atomic cursor increments are exact" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const fixture = try concSetup(std.testing.allocator, tmp, 4, 0);
    defer concFreeFixture(std.testing.allocator, fixture);

    const threads_n: u64 = 4;
    const per_thread: u64 = 12;
    const total: u64 = threads_n * per_thread;

    const Ctx = struct {
        hash: []const u8,
        execs: u64,
        seen: *[64]bool,
        seen_mutex: *std.atomic.Mutex,
        bad: u64 = 0,
    };
    const worker = struct {
        fn work(ctx: *Ctx) void {
            var gpa = std.heap.DebugAllocator(.{}){};
            defer _ = gpa.deinit();
            const alloc = gpa.allocator();
            var i: u64 = 0;
            while (i < ctx.execs) : (i += 1) {
                var run = execQuery(alloc, ctx.hash, null) catch {
                    ctx.bad += 1;
                    continue;
                };
                defer run.deinit(alloc);
                if (run.ok.code != 0) {
                    ctx.bad += 1;
                    continue;
                }
                const old = run.ok.result_u64.?;
                if (old >= 64) {
                    ctx.bad += 1;
                    continue;
                }
                while (!ctx.seen_mutex.tryLock()) std.atomic.spinLoopHint();
                if (ctx.seen[old]) ctx.bad += 1;
                ctx.seen[old] = true;
                ctx.seen_mutex.unlock();
            }
        }
    }.work;

    var seen: [64]bool = std.mem.zeroes([64]bool);
    var seen_mutex: std.atomic.Mutex = .unlocked;
    var ctxs: [4]Ctx = undefined;
    for (&ctxs) |*ctx| ctx.* = .{ .hash = fixture.atomic_hash, .execs = per_thread, .seen = &seen, .seen_mutex = &seen_mutex };
    var threads: [4]std.Thread = undefined;
    for (&threads, &ctxs) |*thread, *ctx| {
        thread.* = try std.Thread.spawn(.{}, worker, .{ctx});
    }
    for (&threads) |*thread| thread.join();

    for (&ctxs) |*ctx| try std.testing.expectEqual(@as(u64, 0), ctx.bad);
    // Every old value 0..total-1 was handed out exactly once: no
    // lost update and no double increment across concurrent execs.
    for (0..total) |i| try std.testing.expect(seen[i]);
    for (total..64) |i| try std.testing.expect(!seen[i]);

    var run = try execQuery(std.testing.allocator, fixture.counter_sum_hash, null);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(total, run.ok.result_u64.?);
}

test "qmod fuel exhaustion under concurrency stays per-exec" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const fixture = try concSetup(std.testing.allocator, tmp, 50, 1);
    defer concFreeFixture(std.testing.allocator, fixture);

    const runaway_hash = try concRegister(std.testing.allocator, tmp, "conc_runaway.query.sa",
        \\grants [db_read:conc]
        \\@main(&col_val: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\zero = add 0, 0
        \\jmp L_TOP
        \\L_TOP:
        \\v = load col_val+zero as u64
        \\jmp L_TOP
    );
    defer std.testing.allocator.free(runaway_hash);

    // Params for a set-all of value 9 that will be starved of fuel.
    var nine: [8]u8 = undefined;
    std.mem.writeInt(u64, &nine, 9, .little);
    try concWriteFile(tmp, "fparams.bin", &nine);

    const FlagCtx = struct {
        hash: []const u8,
        params: ?[]const u8,
        fuel: ?u64,
        got_fuel_exhausted: bool = false,
        bad: u64 = 0,
    };
    const flag_fn = struct {
        fn work(ctx: *FlagCtx) void {
            var gpa = std.heap.DebugAllocator(.{}){};
            defer _ = gpa.deinit();
            const alloc = gpa.allocator();
            if (execQueryWithFuel(alloc, ctx.hash, ctx.params, ctx.fuel)) |run| {
                var owned = run;
                owned.deinit(alloc);
                ctx.bad += 1; // must not succeed
            } else |err| {
                if (err == ExecError.FuelExhausted) {
                    ctx.got_fuel_exhausted = true;
                } else {
                    ctx.bad += 1;
                }
            }
        }
    }.work;

    const ReaderCtx = struct {
        hash: []const u8,
        expected: u64,
        execs: u64,
        bad: u64 = 0,
    };
    const reader_fn = struct {
        fn work(ctx: *ReaderCtx) void {
            var gpa = std.heap.DebugAllocator(.{}){};
            defer _ = gpa.deinit();
            const alloc = gpa.allocator();
            var i: u64 = 0;
            while (i < ctx.execs) : (i += 1) {
                var run = execQuery(alloc, ctx.hash, null) catch {
                    ctx.bad += 1;
                    continue;
                };
                defer run.deinit(alloc);
                if (run.ok.code != 0 or run.ok.result_u64.? != ctx.expected) ctx.bad += 1;
            }
        }
    }.work;

    var runaway_ctx = FlagCtx{ .hash = runaway_hash, .params = null, .fuel = null };
    var starved_ctx = FlagCtx{ .hash = fixture.setall_hash, .params = "fparams.bin", .fuel = 10 };
    var reader_ctxs: [2]ReaderCtx = undefined;
    for (&reader_ctxs) |*ctx| ctx.* = .{ .hash = fixture.sum_hash, .expected = 50, .execs = 20 };

    var t1 = try std.Thread.spawn(.{}, flag_fn, .{&runaway_ctx});
    var t2 = try std.Thread.spawn(.{}, flag_fn, .{&starved_ctx});
    var reader_threads: [2]std.Thread = undefined;
    for (&reader_threads, &reader_ctxs) |*thread, *ctx| {
        thread.* = try std.Thread.spawn(.{}, reader_fn, .{ctx});
    }
    t1.join();
    t2.join();
    for (&reader_threads) |*thread| thread.join();

    // Both runaway executions died on their own meters...
    try std.testing.expect(runaway_ctx.got_fuel_exhausted);
    try std.testing.expect(starved_ctx.got_fuel_exhausted);
    try std.testing.expectEqual(@as(u64, 0), runaway_ctx.bad);
    try std.testing.expectEqual(@as(u64, 0), starved_ctx.bad);
    // ...readers were never disturbed...
    for (&reader_ctxs) |*ctx| try std.testing.expectEqual(@as(u64, 0), ctx.bad);
    // ...and the starved writer left zero partial writes.
    var run = try execQuery(std.testing.allocator, fixture.sum_hash, null);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 50), run.ok.result_u64.?);
}

test "qmod grant rejections hold under concurrent read load" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const fixture = try concSetup(std.testing.allocator, tmp, 50, 1);
    defer concFreeFixture(std.testing.allocator, fixture);

    const ReaderCtx = struct {
        hash: []const u8,
        expected: u64,
        execs: u64,
        bad: u64 = 0,
    };
    const reader_fn = struct {
        fn work(ctx: *ReaderCtx) void {
            var gpa = std.heap.DebugAllocator(.{}){};
            defer _ = gpa.deinit();
            const alloc = gpa.allocator();
            var i: u64 = 0;
            while (i < ctx.execs) : (i += 1) {
                var run = execQuery(alloc, ctx.hash, null) catch {
                    ctx.bad += 1;
                    continue;
                };
                defer run.deinit(alloc);
                if (run.ok.code != 0 or run.ok.result_u64.? != ctx.expected) ctx.bad += 1;
            }
        }
    }.work;

    var reader_ctxs: [3]ReaderCtx = undefined;
    for (&reader_ctxs) |*ctx| ctx.* = .{ .hash = fixture.sum_hash, .expected = 50, .execs = 40 };
    var reader_threads: [3]std.Thread = undefined;
    for (&reader_threads, &reader_ctxs) |*thread, *ctx| {
        thread.* = try std.Thread.spawn(.{}, reader_fn, .{ctx});
    }

    // While readers hammer the table, the register-time static
    // checks must reject exactly as they do without load: a store
    // under a read grant, a load through an undeclared pointer, and
    // an atomic op under a read grant are all capability escalations.
    try concWriteFile(tmp, "bad_store.query.sa",
        \\grants [db_read:conc]
        \\@main(&col_val: ptr) -> u64:
        \\L_ENTRY:
        \\store col_val+0, 1 as u64
        \\return 0
    );
    try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "bad_store.query.sa"));

    try concWriteFile(tmp, "bad_pointer.query.sa",
        \\grants [db_read:conc]
        \\@main(&col_val: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\offset = mul 0, 8
        \\value = load other+offset as u64
        \\return value
    );
    try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "bad_pointer.query.sa"));

    try concWriteFile(tmp, "bad_atomic.query.sa",
        \\grants [db_read:conc]
        \\@main(&cursor: ptr) -> u64:
        \\L_ENTRY:
        \\old = atomic_rmw_add cursor+0, 1
        \\return old
    );
    try std.testing.expectError(ExecError.DbCapabilityEscalation, registerQuery(std.testing.allocator, "bad_atomic.query.sa"));

    for (&reader_threads) |*thread| thread.join();
    for (&reader_ctxs) |*ctx| try std.testing.expectEqual(@as(u64, 0), ctx.bad);
}

test "qmod parallel exec surface is ordered and scales readers" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    // A CPU-bound read workload: interpreter loop sum over 20k rows
    // (no native primitive), so serial-vs-parallel wall time shows
    // whether readers truly run concurrently.
    try concWriteFile(tmp, "bench.sadb-schema",
        \\#def MAX_ROWS = 65536
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_VAL_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 16
    );
    var csv_text = std.array_list.Managed(u8).init(std.testing.allocator);
    defer csv_text.deinit();
    try csv_text.appendSlice("ID,VAL\n");
    var line_buf: [64]u8 = undefined;
    for (0..20_000) |i| {
        const line = try std.fmt.bufPrint(&line_buf, "{d},1\n", .{i});
        try csv_text.appendSlice(line);
    }
    try concWriteFile(tmp, "bench.csv", csv_text.items);
    _ = try table_mod.ingestTable(std.testing.allocator, ".", "bench", "bench.csv");

    const loop_hash = try concRegister(std.testing.allocator, tmp, "bench_sum.query.sa",
        \\grants [db_read:bench]
        \\@main(&col_val: ptr, len: u64) -> u64:
        \\L_ENTRY:
        \\idx = add 0, 0
        \\sum = add 0, 0
        \\jmp L_COND
        \\L_COND:
        \\cond = ult idx, len
        \\br cond -> L_BODY, L_EXIT
        \\L_BODY:
        \\offset = mul idx, 8
        \\value = load col_val+offset as u64
        \\sum = add sum, value
        \\idx = add idx, 1
        \\jmp L_COND
        \\L_EXIT:
        \\return sum
    );
    defer std.testing.allocator.free(loop_hash);

    var requests: [8]ExecRequest = undefined;
    for (&requests) |*request| request.* = .{ .hash_text = loop_hash };

    const serial_start = sio.nanoTimestamp();
    const serial = try execQueriesParallel(std.testing.allocator, &requests, 1);
    const serial_ns: u64 = @intCast(sio.nanoTimestamp() - serial_start);
    for (serial) |*outcome| {
        try std.testing.expect(outcome.err == null);
        try std.testing.expectEqual(@as(u64, 20_000), outcome.run.?.ok.result_u64.?);
        outcome.deinit(std.testing.allocator);
    }
    std.testing.allocator.free(serial);

    const parallel_start = sio.nanoTimestamp();
    const parallel = try execQueriesParallel(std.testing.allocator, &requests, 4);
    const parallel_ns: u64 = @intCast(sio.nanoTimestamp() - parallel_start);
    for (parallel) |*outcome| {
        try std.testing.expect(outcome.err == null);
        try std.testing.expectEqual(@as(u64, 20_000), outcome.run.?.ok.result_u64.?);
        outcome.deinit(std.testing.allocator);
    }
    std.testing.allocator.free(parallel);

    std.debug.print("qmod parallel scaling: serial={d}ms parallel4={d}ms\n", .{ serial_ns / std.time.ns_per_ms, parallel_ns / std.time.ns_per_ms });
    // Readers are not serialized by a global lock: four workers
    // finish the same CPU-bound batch well under the serial time.
    try std.testing.expect(parallel_ns * 4 <= serial_ns * 3);

    // Mixed batch: outcomes stay in request order even though the
    // write races the reads; each read sees a whole epoch.
    const fixture = try concSetup(std.testing.allocator, tmp, 10, 3);
    defer concFreeFixture(std.testing.allocator, fixture);
    var seven: [8]u8 = undefined;
    std.mem.writeInt(u64, &seven, 7, .little);
    try concWriteFile(tmp, "mparams.bin", &seven);
    const mixed = [_]ExecRequest{
        .{ .hash_text = fixture.sum_hash },
        .{ .hash_text = fixture.setall_hash, .params_path = "mparams.bin" },
        .{ .hash_text = fixture.sum_hash },
    };
    const outcomes = try execQueriesParallel(std.testing.allocator, &mixed, 3);
    defer std.testing.allocator.free(outcomes);
    defer for (outcomes) |*outcome| outcome.deinit(std.testing.allocator);
    for (outcomes) |*outcome| try std.testing.expect(outcome.err == null);
    const first_sum = outcomes[0].run.?.ok.result_u64.?;
    const last_sum = outcomes[2].run.?.ok.result_u64.?;
    try std.testing.expect(first_sum == 30 or first_sum == 70);
    try std.testing.expect(last_sum == 30 or last_sum == 70);
    try std.testing.expectEqual(@as(u64, 7), outcomes[1].run.?.ok.result_u64.?);

    var run = try execQuery(std.testing.allocator, fixture.sum_hash, null);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 70), run.ok.result_u64.?);
}

test "qmod many sequential commits keep canonical epoch file names" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try (sio.Dir{ .inner = tmp.dir }).setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const fixture = try concSetup(std.testing.allocator, tmp, 4, 1);
    defer concFreeFixture(std.testing.allocator, fixture);

    // Regression for the chained epoch-suffix defect: the segment
    // rewrite used to append ".e<epoch>" to the previous epoch's
    // file name, so names grew on every commit and writes started
    // failing with SnapshotCorrupted once the name crossed the
    // filesystem limit (observed at epoch 57 on the bench table),
    // leaving the table permanently unwritable. 90 commits stay
    // far below that limit only when names are canonical.
    var i: u64 = 0;
    while (i < 90) : (i += 1) {
        const value: u64 = if (i % 2 == 0) 5 else 6;
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try concWriteFile(tmp, "mparams.bin", &bytes);
        var run = try execQuery(std.testing.allocator, fixture.setall_hash, "mparams.bin");
        defer run.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), run.ok.code);
        try std.testing.expectEqual(value, run.ok.result_u64.?);
    }

    var run = try execQuery(std.testing.allocator, fixture.sum_hash, null);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 24), run.ok.result_u64.?);
    const info = try table_mod.verifyTable(std.testing.allocator, ".", "conc");
    try std.testing.expectEqual(@as(u64, 91), info.epoch);
    try std.testing.expectEqual(@as(u64, 4), info.row_count);
    try std.testing.expect(!info.locked);
}
