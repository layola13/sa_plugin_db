const std = @import("std");
const table = @import("table.zig");

const SA_DB_OK: u32 = 0;
const SA_DB_ERR_INVALID_ARGUMENT: u32 = 1;
const SA_DB_ERR_INVALID_FORMAT: u32 = 2;
const SA_DB_ERR_NOT_FOUND: u32 = 3;
const SA_DB_ERR_LOCKED: u32 = 4;
const SA_DB_ERR_CURSOR_OVERFLOW: u32 = 5;
const SA_DB_ERR_VERIFY_FAILED: u32 = 6;
const SA_DB_ERR_OUT_OF_MEMORY: u32 = 7;
const SA_DB_ERR_IO: u32 = 8;
const SA_DB_ERR_CONSTRAINT: u32 = 9;

var mutation_mutex = std.Thread.Mutex{};
var read_handle_mutex = std.Thread.Mutex{};
var read_handles = std.AutoHashMap(usize, ReadHandleEntry).init(std.heap.page_allocator);

const ReadHandleEntry = struct {
    snapshot: *table.ReadSnapshot,
    refs: usize = 0,
};

pub const SaDbTableInfo = extern struct {
    row_count: u64,
    segment_count: u64,
    epoch: u64,
    locked: u64,
};

pub const SaDbColumnInput = extern struct {
    data: ?[*]const u8,
    len: u64,
};

fn inputBytes(ptr: ?[*]const u8, len: u64) ?[]const u8 {
    if (len > @as(u64, @intCast(std.math.maxInt(usize)))) return null;
    const n: usize = @intCast(len);
    if (n == 0) return &.{};
    const p = ptr orelse return null;
    return p[0..n];
}

fn outputBytes(ptr: ?[*]u8, len: u64) ?[]u8 {
    if (len > @as(u64, @intCast(std.math.maxInt(usize)))) return null;
    const n: usize = @intCast(len);
    if (n == 0) return null;
    const p = ptr orelse return null;
    return p[0..n];
}

fn outputU64s(ptr: ?[*]u64, len: u64) ?[]u64 {
    if (len > @as(u64, @intCast(std.math.maxInt(usize)))) return null;
    const n: usize = @intCast(len);
    if (n == 0) return null;
    const p = ptr orelse return null;
    return p[0..n];
}

fn requiredBytes(ptr: ?[*]const u8, len: u64) ?[]const u8 {
    const bytes = inputBytes(ptr, len) orelse return null;
    if (bytes.len == 0) return null;
    return bytes;
}

fn rootBytes(ptr: ?[*]const u8, len: u64) ?[]const u8 {
    const bytes = inputBytes(ptr, len) orelse return null;
    if (bytes.len == 0) return ".";
    return bytes;
}

fn tableStatus(err: table.TableError) u32 {
    return switch (err) {
        error.OutOfMemory => SA_DB_ERR_OUT_OF_MEMORY,
        error.InvalidFormat, error.InvalidPath, error.SnapshotMissing => SA_DB_ERR_INVALID_FORMAT,
        error.NotFound => SA_DB_ERR_NOT_FOUND,
        error.Locked => SA_DB_ERR_LOCKED,
        error.CursorOverflow => SA_DB_ERR_CURSOR_OVERFLOW,
        error.VerifyFailed => SA_DB_ERR_VERIFY_FAILED,
        error.ConstraintViolation => SA_DB_ERR_CONSTRAINT,
    };
}

fn fillInfo(out_info: ?*SaDbTableInfo, info: table.TableInfo) u32 {
    const slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = .{
        .row_count = info.row_count,
        .segment_count = @intCast(info.segment_count),
        .epoch = info.epoch,
        .locked = if (info.locked) 1 else 0,
    };
    return SA_DB_OK;
}

fn readHandleKey(handle: ?*anyopaque) ?usize {
    const ptr = handle orelse return null;
    return @intFromPtr(ptr);
}

fn registerReadSnapshot(snapshot: *table.ReadSnapshot) bool {
    const key = @intFromPtr(snapshot);
    read_handle_mutex.lock();
    defer read_handle_mutex.unlock();
    read_handles.put(key, .{ .snapshot = snapshot }) catch return false;
    return true;
}

fn acquireReadSnapshot(handle: ?*anyopaque) ?*table.ReadSnapshot {
    const key = readHandleKey(handle) orelse return null;
    read_handle_mutex.lock();
    defer read_handle_mutex.unlock();
    const entry = read_handles.getPtr(key) orelse return null;
    entry.refs += 1;
    return entry.snapshot;
}

fn releaseReadSnapshot(snapshot: *table.ReadSnapshot) void {
    const key = @intFromPtr(snapshot);
    read_handle_mutex.lock();
    defer read_handle_mutex.unlock();
    if (read_handles.getPtr(key)) |entry| {
        if (entry.refs > 0) entry.refs -= 1;
    }
}

fn unregisterReadSnapshot(handle: ?*anyopaque, out_snapshot: *?*table.ReadSnapshot) u32 {
    out_snapshot.* = null;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    read_handle_mutex.lock();
    defer read_handle_mutex.unlock();
    const entry = read_handles.getPtr(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (entry.refs != 0) return SA_DB_ERR_LOCKED;
    out_snapshot.* = entry.snapshot;
    _ = read_handles.remove(key);
    return SA_DB_OK;
}

fn u64CompareOpFromAbi(op: u32) ?table.U64CompareOp {
    return switch (op) {
        0 => .eq,
        1 => .ne,
        2 => .lt,
        3 => .le,
        4 => .gt,
        5 => .ge,
        else => null,
    };
}

pub export fn sa_db_init_schema(
    root_ptr: ?[*]const u8,
    root_len: u64,
    schema_path_ptr: ?[*]const u8,
    schema_path_len: u64,
    schema_ptr: ?[*]const u8,
    schema_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const schema_path = requiredBytes(schema_path_ptr, schema_path_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const schema_source = requiredBytes(schema_ptr, schema_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.initTableFromSchemaBytes(gpa.allocator(), root, schema_path, schema_source) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_remove_table(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.removeTable(gpa.allocator(), root, table_name) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_ingest_columns(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    row_count: u64,
    columns_ptr: ?[*]const SaDbColumnInput,
    columns_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (columns_len > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const n: usize = @intCast(columns_len);
    if (n == 0) return SA_DB_ERR_INVALID_ARGUMENT;
    const c_ptr = columns_ptr orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inputs = c_ptr[0..n];

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const raw_columns = allocator.alloc(table.RawColumnBytes, n) catch return SA_DB_ERR_OUT_OF_MEMORY;
    defer allocator.free(raw_columns);
    for (inputs, 0..) |input, idx| {
        raw_columns[idx] = .{ .bytes = inputBytes(input.data, input.len) orelse return SA_DB_ERR_INVALID_ARGUMENT };
    }

    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.ingestRawColumns(allocator, root, table_name, row_count, raw_columns) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_insert_row(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.insertRawRow(gpa.allocator(), root, table_name, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_upsert_row_u64_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: u64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const result = table.upsertRawRowU64Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_create_u64_index(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    unique: u32,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.createU64Index(gpa.allocator(), root, table_name, @intCast(column_index), unique != 0) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_delete_u64_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.deleteU64Key(gpa.allocator(), root, table_name, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_verify(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const info = table.verifyTable(gpa.allocator(), root, table_name) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_snapshot(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.snapshotTable(gpa.allocator(), root, table_name) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_restore(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    epoch: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.restoreTable(gpa.allocator(), root, table_name, epoch) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_recover(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.recoverTable(gpa.allocator(), root, table_name) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_compact(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.compactTable(gpa.allocator(), root, table_name) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_lock(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.lockTable(gpa.allocator(), root, table_name) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_unlock(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.unlockTable(gpa.allocator(), root, table_name) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_update_u64_add(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    start_row: u64,
    update_count: u64,
    delta: u64,
    out_updated: ?*u64,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const updated_slot = out_updated orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const updated = table.updateU64ColumnAdd(gpa.allocator(), root, table_name, @intCast(column_index), start_row, update_count, delta) catch |err| return tableStatus(err);
    updated_slot.* = updated;
    return SA_DB_OK;
}

pub export fn sa_db_open_read_table(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    out_handle: ?*?*anyopaque,
) u32 {
    const slot = out_handle orelse return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = null;
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const snapshot = table.openReadSnapshot(std.heap.page_allocator, root, table_name) catch |err| return tableStatus(err);
    if (!registerReadSnapshot(snapshot)) {
        snapshot.destroy();
        return SA_DB_ERR_OUT_OF_MEMORY;
    }
    slot.* = @ptrCast(snapshot);
    return SA_DB_OK;
}

pub export fn sa_db_close_read_table(handle: ?*anyopaque) u32 {
    var snapshot: ?*table.ReadSnapshot = null;
    const status = unregisterReadSnapshot(handle, &snapshot);
    if (status != SA_DB_OK) return status;
    snapshot.?.destroy();
    return SA_DB_OK;
}

pub export fn sa_db_sum_u64_handle(handle: ?*anyopaque, column_index: u64, out_sum: ?*u64) u32 {
    const sum_slot = out_sum orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const sum = table.snapshotSumU64(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    sum_slot.* = sum;
    return SA_DB_OK;
}

pub export fn sa_db_count_u64_eq_handle(handle: ?*anyopaque, column_index: u64, expected: u64, out_count: ?*u64) u32 {
    const count_slot = out_count orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const count = table.snapshotCountU64Cmp(snapshot, @intCast(column_index), .eq, expected) catch |err| return tableStatus(err);
    count_slot.* = count;
    return SA_DB_OK;
}

pub export fn sa_db_count_u64_cmp_handle(handle: ?*anyopaque, column_index: u64, op: u32, expected: u64, out_count: ?*u64) u32 {
    const count_slot = out_count orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const cmp_op = u64CompareOpFromAbi(op) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const count = table.snapshotCountU64Cmp(snapshot, @intCast(column_index), cmp_op, expected) catch |err| return tableStatus(err);
    count_slot.* = count;
    return SA_DB_OK;
}

pub export fn sa_db_find_u64_handle(handle: ?*anyopaque, column_index: u64, expected: u64, out_found: ?*u64, out_row_index: ?*u64) u32 {
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row_slot = out_row_index orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    row_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFindU64(snapshot, @intCast(column_index), expected) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    row_slot.* = result.row_index;
    return SA_DB_OK;
}

pub export fn sa_db_range_u64_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_value: u64,
    max_value: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotRangeU64Rows(snapshot, @intCast(column_index), min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_get_u64_handle(handle: ?*anyopaque, column_index: u64, row_index: u64, out_value: ?*u64) u32 {
    const value_slot = out_value orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const value = table.snapshotGetU64(snapshot, @intCast(column_index), row_index) catch |err| return tableStatus(err);
    value_slot.* = value;
    return SA_DB_OK;
}

pub export fn sa_db_get_row_handle(
    handle: ?*anyopaque,
    row_index: u64,
    out_row_ptr: ?[*]u8,
    out_row_len: u64,
) u32 {
    const out_row = outputBytes(out_row_ptr, out_row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    table.snapshotGetRow(snapshot, row_index, out_row) catch |err| return tableStatus(err);
    return SA_DB_OK;
}

pub export fn sa_db_get_row_u64_key_handle(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u64,
    out_row_ptr: ?[*]u8,
    out_row_len: u64,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const out_row = outputBytes(out_row_ptr, out_row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    table.snapshotGetRowU64Key(snapshot, @intCast(column_index), expected, out_row) catch |err| return tableStatus(err);
    return SA_DB_OK;
}

pub export fn sa_db_min_u64_handle(handle: ?*anyopaque, column_index: u64, out_min: ?*u64) u32 {
    const min_slot = out_min orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const min_value = table.snapshotMinU64(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    min_slot.* = min_value;
    return SA_DB_OK;
}

pub export fn sa_db_max_u64_handle(handle: ?*anyopaque, column_index: u64, out_max: ?*u64) u32 {
    const max_slot = out_max orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const max_value = table.snapshotMaxU64(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    max_slot.* = max_value;
    return SA_DB_OK;
}

test "db SA ABI creates ingests updates and scans raw columns" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_POINTS_STRIDE = 8 // u64
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "members.sadb-schema".ptr, "members.sadb-schema".len, schema_source.ptr, schema_source.len, &info));
    try std.testing.expectEqual(@as(u64, 0), info.row_count);

    var ids = [_]u64{ 1, 2, 3 };
    var points = [_]u64{ 10, 20, 30 };
    const cols = [_]SaDbColumnInput{
        .{ .data = @ptrCast(&ids), .len = @sizeOf(@TypeOf(ids)) },
        .{ .data = @ptrCast(&points), .len = @sizeOf(@TypeOf(points)) },
    };
    try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "members".ptr, "members".len, ids.len, &cols, cols.len, &info));
    try std.testing.expectEqual(@as(u64, 3), info.row_count);
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_u64_index(root.ptr, root.len, "members".ptr, "members".len, 0, 1, &info));
    try std.testing.expectEqual(@as(u64, 2), info.epoch);
    var row: [16]u8 = undefined;
    std.mem.writeInt(u64, row[0..8], 4, .little);
    std.mem.writeInt(u64, row[8..16], 40, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_insert_row(root.ptr, root.len, "members".ptr, "members".len, &row, row.len, &info));
    try std.testing.expectEqual(@as(u64, 4), info.row_count);
    try std.testing.expectEqual(@as(u64, 3), info.epoch);
    try std.testing.expectEqual(SA_DB_ERR_CONSTRAINT, sa_db_insert_row(root.ptr, root.len, "members".ptr, "members".len, &row, row.len, &info));
    try std.testing.expectEqual(@as(u64, 4), info.row_count);
    std.mem.writeInt(u64, row[0..8], 4, .little);
    std.mem.writeInt(u64, row[8..16], 44, .little);
    var upsert_inserted: u64 = 99;
    try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_u64_key(root.ptr, root.len, "members".ptr, "members".len, 0, 4, &row, row.len, &upsert_inserted, &info));
    try std.testing.expectEqual(@as(u64, 0), upsert_inserted);
    try std.testing.expectEqual(@as(u64, 4), info.row_count);
    try std.testing.expectEqual(@as(u64, 4), info.epoch);
    std.mem.writeInt(u64, row[0..8], 6, .little);
    std.mem.writeInt(u64, row[8..16], 60, .little);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_upsert_row_u64_key(root.ptr, root.len, "members".ptr, "members".len, 0, 4, &row, row.len, &upsert_inserted, &info));
    try std.testing.expectEqual(@as(u64, 4), info.row_count);
    std.mem.writeInt(u64, row[0..8], 5, .little);
    std.mem.writeInt(u64, row[8..16], 50, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_u64_key(root.ptr, root.len, "members".ptr, "members".len, 0, 5, &row, row.len, &upsert_inserted, &info));
    try std.testing.expectEqual(@as(u64, 1), upsert_inserted);
    try std.testing.expectEqual(@as(u64, 5), info.row_count);
    try std.testing.expectEqual(@as(u64, 5), info.epoch);
    try std.testing.expectEqual(SA_DB_OK, sa_db_snapshot(root.ptr, root.len, "members".ptr, "members".len, &info));
    try std.testing.expectEqual(@as(u64, 5), info.epoch);

    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "members".ptr, "members".len, &handle));
    try std.testing.expect(handle != null);

    var handle_sum: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_sum_u64_handle(handle, 1, &handle_sum));
    try std.testing.expectEqual(@as(u64, 154), handle_sum);
    var handle_count: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_count_u64_cmp_handle(handle, 0, @intFromEnum(table.U64CompareOp.ge), 2, &handle_count));
    try std.testing.expectEqual(@as(u64, 4), handle_count);
    var range_rows = [_]u64{ 99, 99 };
    var range_written: u64 = 0;
    var range_total: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_range_u64_handle(handle, 0, 2, 5, 1, 2, &range_rows, range_rows.len, &range_written, &range_total));
    try std.testing.expectEqual(@as(u64, 4), range_total);
    try std.testing.expectEqual(@as(u64, 2), range_written);
    try std.testing.expectEqual(@as(u64, 2), range_rows[0]);
    try std.testing.expectEqual(@as(u64, 3), range_rows[1]);
    var range_row: [16]u8 = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_handle(handle, range_rows[1], &range_row, range_row.len));
    try std.testing.expectEqual(@as(u64, 4), std.mem.readInt(u64, range_row[0..8], .little));
    try std.testing.expectEqual(@as(u64, 44), std.mem.readInt(u64, range_row[8..16], .little));
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_get_row_handle(handle, 99, &range_row, range_row.len));
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_range_u64_handle(handle, 1, 10, 50, 0, 2, &range_rows, range_rows.len, &range_written, &range_total));
    var found: u64 = 0;
    var row_index: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_handle(handle, 0, 3, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(@as(u64, 2), row_index);
    var row_points: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_u64_handle(handle, 1, row_index, &row_points));
    try std.testing.expectEqual(@as(u64, 30), row_points);
    var fetched_row: [16]u8 = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_u64_key_handle(handle, 0, 4, &fetched_row, fetched_row.len));
    try std.testing.expectEqual(@as(u64, 4), std.mem.readInt(u64, fetched_row[0..8], .little));
    try std.testing.expectEqual(@as(u64, 44), std.mem.readInt(u64, fetched_row[8..16], .little));
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_get_row_u64_key_handle(handle, 0, 99, &fetched_row, fetched_row.len));
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_handle(handle, 0, 99, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 0), found);
    var handle_min: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_min_u64_handle(handle, 1, &handle_min));
    try std.testing.expectEqual(@as(u64, 10), handle_min);
    var handle_max: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_max_u64_handle(handle, 1, &handle_max));
    try std.testing.expectEqual(@as(u64, 50), handle_max);

    var updated: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_update_u64_add(root.ptr, root.len, "members".ptr, "members".len, 1, 0, 4, 5, &updated));
    try std.testing.expectEqual(@as(u64, 4), updated);
    try std.testing.expectEqual(SA_DB_OK, sa_db_recover(root.ptr, root.len, "members".ptr, "members".len, &info));
    try std.testing.expectEqual(@as(u64, 6), info.epoch);

    try std.testing.expectEqual(SA_DB_OK, sa_db_sum_u64_handle(handle, 1, &handle_sum));
    try std.testing.expectEqual(@as(u64, 154), handle_sum);
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_sum_u64_handle(handle, 1, &handle_sum));

    try std.testing.expectEqual(SA_DB_OK, sa_db_delete_u64_key(root.ptr, root.len, "members".ptr, "members".len, 0, 4, &info));
    try std.testing.expectEqual(@as(u64, 4), info.row_count);
    try std.testing.expectEqual(@as(u64, 7), info.epoch);
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_delete_u64_key(root.ptr, root.len, "members".ptr, "members".len, 0, 4, &info));
    try std.testing.expectEqual(@as(u64, 4), info.row_count);

    handle = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "members".ptr, "members".len, &handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_sum_u64_handle(handle, 1, &handle_sum));
    try std.testing.expectEqual(@as(u64, 125), handle_sum);
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_handle(handle, 0, 4, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 0), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_count_u64_eq_handle(handle, 0, 2, &handle_count));
    try std.testing.expectEqual(@as(u64, 1), handle_count);
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));

    try std.testing.expectEqual(SA_DB_OK, sa_db_restore(root.ptr, root.len, "members".ptr, "members".len, 5, &info));
    try std.testing.expectEqual(@as(u64, 5), info.row_count);
    handle = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "members".ptr, "members".len, &handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_sum_u64_handle(handle, 1, &handle_sum));
    try std.testing.expectEqual(@as(u64, 154), handle_sum);
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
}
