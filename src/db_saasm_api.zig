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

const DECIMAL_MAX_SCALE: u32 = 18;
const MS_PER_DAY: u64 = 86_400_000;
const US_PER_DAY: u64 = 86_400_000_000;

var mutation_mutex = std.Thread.Mutex{};
var read_handle_mutex = std.Thread.Mutex{};
var read_handles = std.AutoHashMap(usize, ReadHandleEntry).init(std.heap.page_allocator);
var tx_handle_mutex = std.Thread.Mutex{};
var tx_handles = std.AutoHashMap(usize, *table.WriteTransaction).init(std.heap.page_allocator);
var empty_output_bytes: [0]u8 = .{};

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

pub const SaDbSnapshotInfo = extern struct {
    row_count: u64,
    column_count: u64,
    row_bytes: u64,
    epoch: u64,
};

pub const SaDbColumnInfo = extern struct {
    stride: u64,
    type_code: u64,
    name_len: u64,
    type_name_len: u64,
};

pub const SaDbColumnLogicalInfo = extern struct {
    logical_type: u64,
    logical_scale: u64,
    nullable: u64,
};

pub const SaDbPlanInfo = extern struct {
    written: u64,
    total: u64,
    first_predicate: u64,
    first_total: u64,
    second_total: u64,
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

fn inputU64s(ptr: ?[*]const u64, len: u64) ?[]const u64 {
    if (len > @as(u64, @intCast(std.math.maxInt(usize)))) return null;
    const n: usize = @intCast(len);
    if (n == 0) return null;
    const p = ptr orelse return null;
    return p[0..n];
}

fn inputU64sAllowEmpty(ptr: ?[*]const u64, len: u64) ?[]const u64 {
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

fn outputBytesAllowEmpty(ptr: ?[*]u8, len: u64) ?[]u8 {
    if (len > @as(u64, @intCast(std.math.maxInt(usize)))) return null;
    const n: usize = @intCast(len);
    if (n == 0) return empty_output_bytes[0..];
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

fn fillSnapshotInfo(out_info: ?*SaDbSnapshotInfo, info: table.SnapshotInfo) u32 {
    const slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = .{
        .row_count = info.row_count,
        .column_count = info.column_count,
        .row_bytes = info.row_bytes,
        .epoch = info.epoch,
    };
    return SA_DB_OK;
}

fn fillColumnInfo(out_info: ?*SaDbColumnInfo, info: table.ColumnInfo) u32 {
    const slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = .{
        .stride = info.stride,
        .type_code = info.type_code,
        .name_len = info.name_len,
        .type_name_len = info.type_name_len,
    };
    return SA_DB_OK;
}

fn fillColumnLogicalInfo(out_info: ?*SaDbColumnLogicalInfo, info: table.ColumnLogicalInfo) u32 {
    const slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = .{
        .logical_type = info.logical_type,
        .logical_scale = info.logical_scale,
        .nullable = info.nullable,
    };
    return SA_DB_OK;
}

fn fillPlanInfo(out_info: ?*SaDbPlanInfo, result: table.PlanRowsResult) u32 {
    const slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = .{
        .written = result.written,
        .total = result.total,
        .first_predicate = result.first_predicate,
        .first_total = result.first_total,
        .second_total = result.second_total,
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

fn registerWriteTransaction(tx: *table.WriteTransaction) bool {
    const key = @intFromPtr(tx);
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    tx_handles.put(key, tx) catch return false;
    return true;
}

fn unregisterWriteTransaction(handle: ?*anyopaque, out_tx: *?*table.WriteTransaction) u32 {
    out_tx.* = null;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    out_tx.* = tx;
    _ = tx_handles.remove(key);
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

fn boolFromAbi(value: u32) ?bool {
    return switch (value) {
        0 => false,
        1 => true,
        else => null,
    };
}

fn decimalScaleFactor(scale: u32) ?u64 {
    if (scale > DECIMAL_MAX_SCALE) return null;
    var factor: u64 = 1;
    var i: u32 = 0;
    while (i < scale) : (i += 1) {
        factor *= 10;
    }
    return factor;
}

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i64, month: u32) ?u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => null,
    };
}

const CivilDate = struct {
    year: i64,
    month: u32,
    day: u32,
};

fn daysFromCivil(year: i64, month: u32, day: u32) ?i64 {
    const month_days = daysInMonth(year, month) orelse return null;
    if (day == 0 or day > month_days) return null;

    var y: i128 = year;
    if (month <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const month_i: i128 = month;
    const mp = if (month > 2) month_i - 3 else month_i + 9;
    const doy = @divFloor(153 * mp + 2, 5) + @as(i128, day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    if (days < std.math.minInt(i64) or days > std.math.maxInt(i64)) return null;
    return @intCast(days);
}

fn civilFromDays(days: i64) ?CivilDate {
    const z: i128 = @as(i128, days) + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + if (mp < 10) @as(i128, 3) else -9;
    if (m <= 2) y += 1;
    if (y < std.math.minInt(i64) or y > std.math.maxInt(i64)) return null;
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
}

fn timestampFromParts(days: i64, subday: u64, units_per_day: u64) ?i64 {
    if (subday >= units_per_day) return null;
    const total = @as(i128, days) * @as(i128, units_per_day) + @as(i128, subday);
    if (total < std.math.minInt(i64) or total > std.math.maxInt(i64)) return null;
    return @intCast(total);
}

const TimestampParts = struct {
    days: i64,
    subday: u64,
};

fn timestampToParts(value: i64, units_per_day: u64) ?TimestampParts {
    const total: i128 = value;
    const unit: i128 = units_per_day;
    const days = @divFloor(total, unit);
    const subday = total - days * unit;
    if (days < std.math.minInt(i64) or days > std.math.maxInt(i64)) return null;
    return .{ .days = @intCast(days), .subday = @intCast(subday) };
}

pub export fn sa_db_decimal_from_parts(
    negative: u32,
    whole: u64,
    fraction: u64,
    scale: u32,
    out_value: ?*i64,
) u32 {
    const slot = out_value orelse return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = 0;
    const factor = decimalScaleFactor(scale) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (fraction >= factor) return SA_DB_ERR_INVALID_ARGUMENT;

    const total = @as(u128, whole) * @as(u128, factor) + @as(u128, fraction);
    const positive_limit: u128 = @intCast(std.math.maxInt(i64));
    const negative_limit = positive_limit + 1;
    if (negative == 0) {
        if (total > positive_limit) return SA_DB_ERR_INVALID_ARGUMENT;
        slot.* = @intCast(total);
    } else {
        if (total > negative_limit) return SA_DB_ERR_INVALID_ARGUMENT;
        if (total == negative_limit) {
            slot.* = std.math.minInt(i64);
        } else {
            slot.* = -@as(i64, @intCast(total));
        }
    }
    return SA_DB_OK;
}

pub export fn sa_db_decimal_to_parts(
    value: i64,
    scale: u32,
    out_negative: ?*u32,
    out_whole: ?*u64,
    out_fraction: ?*u64,
) u32 {
    const negative_slot = out_negative orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const whole_slot = out_whole orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const fraction_slot = out_fraction orelse return SA_DB_ERR_INVALID_ARGUMENT;
    negative_slot.* = 0;
    whole_slot.* = 0;
    fraction_slot.* = 0;
    const factor = decimalScaleFactor(scale) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var magnitude: u128 = 0;
    if (value < 0) {
        negative_slot.* = 1;
        magnitude = if (value == std.math.minInt(i64))
            @as(u128, @intCast(std.math.maxInt(i64))) + 1
        else
            @intCast(-value);
    } else {
        magnitude = @intCast(value);
    }
    whole_slot.* = @intCast(magnitude / factor);
    fraction_slot.* = @intCast(magnitude % factor);
    return SA_DB_OK;
}

pub export fn sa_db_date_from_ymd(year: i64, month: u32, day: u32, out_days: ?*i64) u32 {
    const slot = out_days orelse return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = 0;
    slot.* = daysFromCivil(year, month, day) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return SA_DB_OK;
}

pub export fn sa_db_date_to_ymd(days: i64, out_year: ?*i64, out_month: ?*u32, out_day: ?*u32) u32 {
    const year_slot = out_year orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const month_slot = out_month orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const day_slot = out_day orelse return SA_DB_ERR_INVALID_ARGUMENT;
    year_slot.* = 0;
    month_slot.* = 0;
    day_slot.* = 0;
    const date = civilFromDays(days) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    year_slot.* = date.year;
    month_slot.* = date.month;
    day_slot.* = date.day;
    return SA_DB_OK;
}

pub export fn sa_db_timestamp_ms_from_parts(days: i64, millis_of_day: u64, out_ms: ?*i64) u32 {
    const slot = out_ms orelse return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = 0;
    slot.* = timestampFromParts(days, millis_of_day, MS_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return SA_DB_OK;
}

pub export fn sa_db_timestamp_ms_to_parts(value_ms: i64, out_days: ?*i64, out_millis_of_day: ?*u64) u32 {
    const days_slot = out_days orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const subday_slot = out_millis_of_day orelse return SA_DB_ERR_INVALID_ARGUMENT;
    days_slot.* = 0;
    subday_slot.* = 0;
    const parts = timestampToParts(value_ms, MS_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    days_slot.* = parts.days;
    subday_slot.* = parts.subday;
    return SA_DB_OK;
}

pub export fn sa_db_timestamp_us_from_parts(days: i64, micros_of_day: u64, out_us: ?*i64) u32 {
    const slot = out_us orelse return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = 0;
    slot.* = timestampFromParts(days, micros_of_day, US_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return SA_DB_OK;
}

pub export fn sa_db_timestamp_us_to_parts(value_us: i64, out_days: ?*i64, out_micros_of_day: ?*u64) u32 {
    const days_slot = out_days orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const subday_slot = out_micros_of_day orelse return SA_DB_ERR_INVALID_ARGUMENT;
    days_slot.* = 0;
    subday_slot.* = 0;
    const parts = timestampToParts(value_us, US_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    days_slot.* = parts.days;
    subday_slot.* = parts.subday;
    return SA_DB_OK;
}

pub export fn sa_db_bool_encode(value: u32, out_encoded: ?*u64) u32 {
    const slot = out_encoded orelse return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = if (value == 0) 0 else 1;
    return SA_DB_OK;
}

pub export fn sa_db_bool_decode(encoded: u64, out_value: ?*u32) u32 {
    const slot = out_value orelse return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = 0;
    if (encoded > 1) return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = @intCast(encoded);
    return SA_DB_OK;
}

pub export fn sa_db_null_bitmap_required_bytes(row_count: u64, out_len: ?*u64) u32 {
    const slot = out_len orelse return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = row_count / 8 + if (row_count % 8 == 0) @as(u64, 0) else 1;
    return SA_DB_OK;
}

pub export fn sa_db_null_bitmap_clear(bitmap_ptr: ?[*]u8, bitmap_len: u64) u32 {
    if (bitmap_len > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const len: usize = @intCast(bitmap_len);
    if (len == 0) return SA_DB_OK;
    const ptr = bitmap_ptr orelse return SA_DB_ERR_INVALID_ARGUMENT;
    @memset(ptr[0..len], 0);
    return SA_DB_OK;
}

pub export fn sa_db_null_bitmap_set(bitmap_ptr: ?[*]u8, bitmap_len: u64, row_index: u64, is_null: u32) u32 {
    const bytes = outputBytes(bitmap_ptr, bitmap_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const byte_index_u64 = row_index / 8;
    if (byte_index_u64 >= bytes.len) return SA_DB_ERR_INVALID_ARGUMENT;
    const byte_index: usize = @intCast(byte_index_u64);
    const bit: u3 = @intCast(row_index & 7);
    const mask: u8 = @as(u8, 1) << bit;
    if (is_null == 0) {
        bytes[byte_index] &= ~mask;
    } else {
        bytes[byte_index] |= mask;
    }
    return SA_DB_OK;
}

pub export fn sa_db_null_bitmap_get(bitmap_ptr: ?[*]const u8, bitmap_len: u64, row_index: u64, out_is_null: ?*u32) u32 {
    const slot = out_is_null orelse return SA_DB_ERR_INVALID_ARGUMENT;
    slot.* = 0;
    const bytes = inputBytes(bitmap_ptr, bitmap_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const byte_index_u64 = row_index / 8;
    if (byte_index_u64 >= bytes.len) return SA_DB_ERR_INVALID_ARGUMENT;
    const byte_index: usize = @intCast(byte_index_u64);
    const bit: u3 = @intCast(row_index & 7);
    const mask: u8 = @as(u8, 1) << bit;
    slot.* = if ((bytes[byte_index] & mask) == 0) 0 else 1;
    return SA_DB_OK;
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

pub export fn sa_db_update_row_u64_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: u64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.updateRawRowU64Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_upsert_row_u32_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: u32,
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
    const result = table.upsertRawRowU32Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_update_row_u32_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: u32,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.updateRawRowU32Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_upsert_row_i32_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: i32,
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
    const result = table.upsertRawRowI32Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_update_row_i32_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: i32,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.updateRawRowI32Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_upsert_row_u8_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: u8,
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
    const result = table.upsertRawRowU8Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_update_row_u8_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: u8,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.updateRawRowU8Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_upsert_row_i8_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: i8,
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
    const result = table.upsertRawRowI8Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_update_row_i8_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: i8,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.updateRawRowI8Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_upsert_row_u16_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: u16,
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
    const result = table.upsertRawRowU16Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_update_row_u16_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: u16,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.updateRawRowU16Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_upsert_row_i16_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: i16,
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
    const result = table.upsertRawRowI16Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_update_row_i16_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: i16,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.updateRawRowI16Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_upsert_row_i64_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: i64,
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
    const result = table.upsertRawRowI64Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_update_row_i64_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: i64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.updateRawRowI64Key(gpa.allocator(), root, table_name, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_upsert_row_u64_pair_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    key2: u64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    inserted_slot.* = 0;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const result = table.upsertRawRowU64PairKey(gpa.allocator(), root, table_name, @intCast(column_index), @intCast(column_index2), key1, key2, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_update_row_u64_pair_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    key2: u64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.updateRawRowU64PairKey(gpa.allocator(), root, table_name, @intCast(column_index), @intCast(column_index2), key1, key2, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_upsert_row_u64_i64_pair_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    key2: i64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    inserted_slot.* = 0;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const result = table.upsertRawRowU64I64PairKey(gpa.allocator(), root, table_name, @intCast(column_index), @intCast(column_index2), key1, key2, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_update_row_u64_i64_pair_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    key2: i64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.updateRawRowU64I64PairKey(gpa.allocator(), root, table_name, @intCast(column_index), @intCast(column_index2), key1, key2, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_upsert_row_blob_eq_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = inputBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    inserted_slot.* = 0;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const result = table.upsertRawRowBlobEqKey(gpa.allocator(), root, table_name, @intCast(column_index), store_name, value, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_update_row_blob_eq_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = inputBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.updateRawRowBlobEqKey(gpa.allocator(), root, table_name, @intCast(column_index), store_name, value, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_begin(
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
    const tx = table.beginWriteTransaction(std.heap.page_allocator, root, table_name) catch |err| {
        mutation_mutex.unlock();
        return tableStatus(err);
    };
    if (!registerWriteTransaction(tx)) {
        table.destroyWriteTransaction(std.heap.page_allocator, tx);
        mutation_mutex.unlock();
        return SA_DB_ERR_OUT_OF_MEMORY;
    }
    slot.* = @ptrCast(tx);
    return SA_DB_OK;
}

pub export fn sa_db_tx_insert_row(
    handle: ?*anyopaque,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionInsertRawRow(tx, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_dict_intern(
    handle: ?*anyopaque,
    dict_ptr: ?[*]const u8,
    dict_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    out_id: ?*u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const dict_name = requiredBytes(dict_ptr, dict_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = requiredBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const id_slot = out_id orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    id_slot.* = 0;
    inserted_slot.* = 0;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    const result = table.writeTransactionInternStringDict(std.heap.page_allocator, tx, dict_name, value) catch |err| return tableStatus(err);
    id_slot.* = result.id;
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_tx_blob_put(
    handle: ?*anyopaque,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    out_id: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = inputBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const id_slot = out_id orelse return SA_DB_ERR_INVALID_ARGUMENT;
    id_slot.* = 0;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    const result = table.writeTransactionPutBlobValue(std.heap.page_allocator, tx, store_name, value) catch |err| return tableStatus(err);
    id_slot.* = result.id;
    return fillInfo(out_info, result.info);
}

pub export fn sa_db_tx_upsert_row_u64_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    inserted_slot.* = 0;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const result = table.writeTransactionUpsertRawRowU64Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_tx_update_row_u64_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionUpdateRawRowU64Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_upsert_row_u32_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u32,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    inserted_slot.* = 0;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const result = table.writeTransactionUpsertRawRowU32Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_tx_update_row_u32_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u32,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionUpdateRawRowU32Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_upsert_row_i32_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i32,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    inserted_slot.* = 0;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const result = table.writeTransactionUpsertRawRowI32Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_tx_update_row_i32_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i32,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionUpdateRawRowI32Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_upsert_row_u8_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u8,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    inserted_slot.* = 0;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const result = table.writeTransactionUpsertRawRowU8Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_tx_update_row_u8_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u8,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionUpdateRawRowU8Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_upsert_row_i8_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i8,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    inserted_slot.* = 0;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const result = table.writeTransactionUpsertRawRowI8Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_tx_update_row_i8_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i8,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionUpdateRawRowI8Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_upsert_row_u16_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u16,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    inserted_slot.* = 0;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const result = table.writeTransactionUpsertRawRowU16Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_tx_update_row_u16_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u16,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionUpdateRawRowU16Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_upsert_row_i16_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i16,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    inserted_slot.* = 0;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const result = table.writeTransactionUpsertRawRowI16Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_tx_update_row_i16_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i16,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionUpdateRawRowI16Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_upsert_row_i64_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    inserted_slot.* = 0;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const result = table.writeTransactionUpsertRawRowI64Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_tx_update_row_i64_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionUpdateRawRowI64Key(tx, @intCast(column_index), expected, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_upsert_row_u64_pair_key(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    key2: u64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    inserted_slot.* = 0;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const result = table.writeTransactionUpsertRawRowU64PairKey(tx, @intCast(column_index), @intCast(column_index2), key1, key2, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_tx_update_row_u64_pair_key(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    key2: u64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionUpdateRawRowU64PairKey(tx, @intCast(column_index), @intCast(column_index2), key1, key2, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_upsert_row_u64_i64_pair_key(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    key2: i64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    inserted_slot.* = 0;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const result = table.writeTransactionUpsertRawRowU64I64PairKey(tx, @intCast(column_index), @intCast(column_index2), key1, key2, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_tx_update_row_u64_i64_pair_key(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    key2: i64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionUpdateRawRowU64I64PairKey(tx, @intCast(column_index), @intCast(column_index2), key1, key2, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_upsert_row_blob_eq_key(
    handle: ?*anyopaque,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = inputBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    inserted_slot.* = 0;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const result = table.writeTransactionUpsertRawRowBlobEqKey(std.heap.page_allocator, tx, @intCast(column_index), store_name, value, row) catch |err| return tableStatus(err);
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_tx_update_row_blob_eq_key(
    handle: ?*anyopaque,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    row_ptr: ?[*]const u8,
    row_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = inputBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row = requiredBytes(row_ptr, row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionUpdateRawRowBlobEqKey(std.heap.page_allocator, tx, @intCast(column_index), store_name, value, row) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_delete_u64_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionDeleteU64Key(tx, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_delete_u32_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u32,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionDeleteU32Key(tx, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_delete_i32_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i32,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionDeleteI32Key(tx, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_delete_u8_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u8,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionDeleteU8Key(tx, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_delete_i8_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i8,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionDeleteI8Key(tx, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_delete_u16_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u16,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionDeleteU16Key(tx, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_delete_i16_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i16,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionDeleteI16Key(tx, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_delete_i64_key(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionDeleteI64Key(tx, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_delete_u64_pair_key(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    key2: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionDeleteU64PairKey(tx, @intCast(column_index), @intCast(column_index2), key1, key2) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_delete_u64_i64_pair_key(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    key2: i64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionDeleteU64I64PairKey(tx, @intCast(column_index), @intCast(column_index2), key1, key2) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_delete_blob_eq_key(
    handle: ?*anyopaque,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = inputBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const key = readHandleKey(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    tx_handle_mutex.lock();
    defer tx_handle_mutex.unlock();
    const tx = tx_handles.get(key) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info = table.writeTransactionDeleteBlobEqKey(std.heap.page_allocator, tx, @intCast(column_index), store_name, value) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_tx_commit(handle: ?*anyopaque, out_info: ?*SaDbTableInfo) u32 {
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    var tx: ?*table.WriteTransaction = null;
    const status = unregisterWriteTransaction(handle, &tx);
    if (status != SA_DB_OK) return status;

    const info = table.commitWriteTransaction(std.heap.page_allocator, tx.?) catch |err| {
        table.destroyWriteTransaction(std.heap.page_allocator, tx.?);
        mutation_mutex.unlock();
        return tableStatus(err);
    };
    table.destroyWriteTransaction(std.heap.page_allocator, tx.?);
    mutation_mutex.unlock();
    return fillInfo(info_slot, info);
}

pub export fn sa_db_tx_rollback(handle: ?*anyopaque) u32 {
    var tx: ?*table.WriteTransaction = null;
    const status = unregisterWriteTransaction(handle, &tx);
    if (status != SA_DB_OK) return status;
    table.destroyWriteTransaction(std.heap.page_allocator, tx.?);
    mutation_mutex.unlock();
    return SA_DB_OK;
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

pub export fn sa_db_create_i64_index(
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
    const info = table.createI64Index(gpa.allocator(), root, table_name, @intCast(column_index), unique != 0) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_create_u32_index(
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
    const info = table.createU32Index(gpa.allocator(), root, table_name, @intCast(column_index), unique != 0) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_create_i32_index(
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
    const info = table.createI32Index(gpa.allocator(), root, table_name, @intCast(column_index), unique != 0) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_create_u8_index(
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
    const info = table.createU8Index(gpa.allocator(), root, table_name, @intCast(column_index), unique != 0) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_create_i8_index(
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
    const info = table.createI8Index(gpa.allocator(), root, table_name, @intCast(column_index), unique != 0) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_create_u16_index(
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
    const info = table.createU16Index(gpa.allocator(), root, table_name, @intCast(column_index), unique != 0) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_create_i16_index(
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
    const info = table.createI16Index(gpa.allocator(), root, table_name, @intCast(column_index), unique != 0) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_create_f32_index(
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
    const info = table.createF32Index(gpa.allocator(), root, table_name, @intCast(column_index), unique != 0) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_create_f64_index(
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
    const info = table.createF64Index(gpa.allocator(), root, table_name, @intCast(column_index), unique != 0) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_create_u64_pair_index(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    column_index2: u64,
    unique: u32,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.createU64PairIndex(gpa.allocator(), root, table_name, @intCast(column_index), @intCast(column_index2), unique != 0) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_create_u64_i64_pair_index(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    column_index2: u64,
    unique: u32,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.createU64I64PairIndex(gpa.allocator(), root, table_name, @intCast(column_index), @intCast(column_index2), unique != 0) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_create_blob_eq_index(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    unique: u32,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.createBlobEqIndex(gpa.allocator(), root, table_name, @intCast(column_index), store_name, unique != 0) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_create_blob_token_index(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.createBlobTokenIndex(gpa.allocator(), root, table_name, @intCast(column_index), store_name) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_create_blob_prefix_index(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.createBlobPrefixIndex(gpa.allocator(), root, table_name, @intCast(column_index), store_name) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_create_blob_contains_index(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.createBlobContainsIndex(gpa.allocator(), root, table_name, @intCast(column_index), store_name) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_dict_intern(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    dict_ptr: ?[*]const u8,
    dict_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    out_id: ?*u64,
    out_inserted: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const dict_name = requiredBytes(dict_ptr, dict_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = requiredBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const id_slot = out_id orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const inserted_slot = out_inserted orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    id_slot.* = 0;
    inserted_slot.* = 0;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const result = table.internStringDict(gpa.allocator(), root, table_name, dict_name, value) catch |err| return tableStatus(err);
    id_slot.* = result.id;
    inserted_slot.* = if (result.inserted) 1 else 0;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_dict_lookup(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    dict_ptr: ?[*]const u8,
    dict_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    out_found: ?*u64,
    out_id: ?*u64,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const dict_name = requiredBytes(dict_ptr, dict_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = requiredBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const id_slot = out_id orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    id_slot.* = 0;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const result = table.lookupStringDict(gpa.allocator(), root, table_name, dict_name, value) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    id_slot.* = result.id;
    return SA_DB_OK;
}

pub export fn sa_db_dict_value_len(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    dict_ptr: ?[*]const u8,
    dict_len: u64,
    id: u64,
    out_found: ?*u64,
    out_len: ?*u64,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const dict_name = requiredBytes(dict_ptr, dict_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const len_slot = out_len orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    len_slot.* = 0;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const result = table.stringDictValueLen(gpa.allocator(), root, table_name, dict_name, id) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    len_slot.* = result.len;
    return SA_DB_OK;
}

pub export fn sa_db_dict_value_copy(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    dict_ptr: ?[*]const u8,
    dict_len: u64,
    id: u64,
    out_buf_ptr: ?[*]u8,
    out_buf_len: u64,
    out_found: ?*u64,
    out_written: ?*u64,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const dict_name = requiredBytes(dict_ptr, dict_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const out_buf = outputBytes(out_buf_ptr, out_buf_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    written_slot.* = 0;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const result = table.copyStringDictValue(gpa.allocator(), root, table_name, dict_name, id, out_buf) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    written_slot.* = result.written;
    return SA_DB_OK;
}

pub export fn sa_db_blob_put(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    out_id: ?*u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = inputBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const id_slot = out_id orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    id_slot.* = 0;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const result = table.putBlobValue(gpa.allocator(), root, table_name, store_name, value) catch |err| return tableStatus(err);
    id_slot.* = result.id;
    return fillInfo(info_slot, result.info);
}

pub export fn sa_db_blob_value_len(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    id: u64,
    out_found: ?*u64,
    out_len: ?*u64,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const len_slot = out_len orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    len_slot.* = 0;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const result = table.blobValueLen(gpa.allocator(), root, table_name, store_name, id) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    len_slot.* = result.len;
    return SA_DB_OK;
}

pub export fn sa_db_blob_value_copy(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    id: u64,
    out_buf_ptr: ?[*]u8,
    out_buf_len: u64,
    out_found: ?*u64,
    out_written: ?*u64,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const out_buf = outputBytesAllowEmpty(out_buf_ptr, out_buf_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    written_slot.* = 0;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const result = table.copyBlobValue(gpa.allocator(), root, table_name, store_name, id, out_buf) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    written_slot.* = result.written;
    return SA_DB_OK;
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

pub export fn sa_db_delete_u32_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: u32,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.deleteU32Key(gpa.allocator(), root, table_name, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_delete_i32_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: i32,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.deleteI32Key(gpa.allocator(), root, table_name, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_delete_u8_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: u8,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.deleteU8Key(gpa.allocator(), root, table_name, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_delete_i8_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: i8,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.deleteI8Key(gpa.allocator(), root, table_name, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_delete_u16_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: u16,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.deleteU16Key(gpa.allocator(), root, table_name, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_delete_i16_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: i16,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.deleteI16Key(gpa.allocator(), root, table_name, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_delete_i64_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    expected: i64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.deleteI64Key(gpa.allocator(), root, table_name, @intCast(column_index), expected) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_delete_u64_pair_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    key2: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.deleteU64PairKey(gpa.allocator(), root, table_name, @intCast(column_index), @intCast(column_index2), key1, key2) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_delete_u64_i64_pair_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    key2: i64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.deleteU64I64PairKey(gpa.allocator(), root, table_name, @intCast(column_index), @intCast(column_index2), key1, key2) catch |err| return tableStatus(err);
    return fillInfo(out_info, info);
}

pub export fn sa_db_delete_blob_eq_key(
    root_ptr: ?[*]const u8,
    root_len: u64,
    table_ptr: ?[*]const u8,
    table_len: u64,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    out_info: ?*SaDbTableInfo,
) u32 {
    const root = rootBytes(root_ptr, root_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const table_name = requiredBytes(table_ptr, table_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = inputBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    mutation_mutex.lock();
    defer mutation_mutex.unlock();
    const info = table.deleteBlobEqKey(gpa.allocator(), root, table_name, @intCast(column_index), store_name, value) catch |err| return tableStatus(err);
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

pub export fn sa_db_snapshot_info_handle(handle: ?*anyopaque, out_info: ?*SaDbSnapshotInfo) u32 {
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const info = table.snapshotInfo(snapshot) catch |err| return tableStatus(err);
    return fillSnapshotInfo(out_info, info);
}

pub export fn sa_db_column_info_handle(handle: ?*anyopaque, column_index: u64, out_info: ?*SaDbColumnInfo) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const info = table.snapshotColumnInfo(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    return fillColumnInfo(out_info, info);
}

pub export fn sa_db_column_logical_info_handle(handle: ?*anyopaque, column_index: u64, out_info: ?*SaDbColumnLogicalInfo) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const info = table.snapshotColumnLogicalInfo(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    return fillColumnLogicalInfo(out_info, info);
}

pub export fn sa_db_dict_lookup_handle(
    handle: ?*anyopaque,
    dict_ptr: ?[*]const u8,
    dict_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    out_found: ?*u64,
    out_id: ?*u64,
) u32 {
    const dict_name = requiredBytes(dict_ptr, dict_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = requiredBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const id_slot = out_id orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    id_slot.* = 0;

    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotDictLookup(snapshot, dict_name, value) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    id_slot.* = result.id;
    return SA_DB_OK;
}

pub export fn sa_db_dict_value_len_handle(
    handle: ?*anyopaque,
    dict_ptr: ?[*]const u8,
    dict_len: u64,
    id: u64,
    out_found: ?*u64,
    out_len: ?*u64,
) u32 {
    const dict_name = requiredBytes(dict_ptr, dict_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const len_slot = out_len orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    len_slot.* = 0;

    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotDictValueLen(snapshot, dict_name, id) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    len_slot.* = result.len;
    return SA_DB_OK;
}

pub export fn sa_db_dict_value_copy_handle(
    handle: ?*anyopaque,
    dict_ptr: ?[*]const u8,
    dict_len: u64,
    id: u64,
    out_buf_ptr: ?[*]u8,
    out_buf_len: u64,
    out_found: ?*u64,
    out_written: ?*u64,
) u32 {
    const dict_name = requiredBytes(dict_ptr, dict_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const out_buf = outputBytes(out_buf_ptr, out_buf_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    written_slot.* = 0;

    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotDictValueCopy(snapshot, dict_name, id, out_buf) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    written_slot.* = result.written;
    return SA_DB_OK;
}

pub export fn sa_db_blob_value_len_handle(
    handle: ?*anyopaque,
    store_ptr: ?[*]const u8,
    store_len: u64,
    id: u64,
    out_found: ?*u64,
    out_len: ?*u64,
) u32 {
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const len_slot = out_len orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    len_slot.* = 0;

    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotBlobValueLen(snapshot, store_name, id) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    len_slot.* = result.len;
    return SA_DB_OK;
}

pub export fn sa_db_blob_value_copy_handle(
    handle: ?*anyopaque,
    store_ptr: ?[*]const u8,
    store_len: u64,
    id: u64,
    out_buf_ptr: ?[*]u8,
    out_buf_len: u64,
    out_found: ?*u64,
    out_written: ?*u64,
) u32 {
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const out_buf = outputBytesAllowEmpty(out_buf_ptr, out_buf_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    written_slot.* = 0;

    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotBlobValueCopy(snapshot, store_name, id, out_buf) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    written_slot.* = result.written;
    return SA_DB_OK;
}

pub export fn sa_db_filter_blob_eq_handle(
    handle: ?*anyopaque,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
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
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = inputBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterBlobEqRows(gpa.allocator(), snapshot, @intCast(column_index), store_name, value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_blob_contains_handle(
    handle: ?*anyopaque,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
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
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = inputBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterBlobContainsRows(gpa.allocator(), snapshot, @intCast(column_index), store_name, value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_blob_token_handle(
    handle: ?*anyopaque,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
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
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = inputBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterBlobTokenRows(gpa.allocator(), snapshot, @intCast(column_index), store_name, value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_blob_prefix_handle(
    handle: ?*anyopaque,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
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
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = inputBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterBlobPrefixRows(gpa.allocator(), snapshot, @intCast(column_index), store_name, value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

fn filterRowsBlobHandle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
    comptime filterFn: anytype,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = inputBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = filterFn(gpa.allocator(), snapshot, @intCast(column_index), in_rows, store_name, value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_rows_blob_eq_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    return filterRowsBlobHandle(handle, column_index, in_rows_ptr, in_rows_len, store_ptr, store_len, value_ptr, value_len, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total, table.snapshotFilterRowsBlobEq);
}

pub export fn sa_db_filter_rows_blob_contains_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    return filterRowsBlobHandle(handle, column_index, in_rows_ptr, in_rows_len, store_ptr, store_len, value_ptr, value_len, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total, table.snapshotFilterRowsBlobContains);
}

pub export fn sa_db_filter_rows_blob_token_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    return filterRowsBlobHandle(handle, column_index, in_rows_ptr, in_rows_len, store_ptr, store_len, value_ptr, value_len, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total, table.snapshotFilterRowsBlobToken);
}

pub export fn sa_db_filter_rows_blob_prefix_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    return filterRowsBlobHandle(handle, column_index, in_rows_ptr, in_rows_len, store_ptr, store_len, value_ptr, value_len, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total, table.snapshotFilterRowsBlobPrefix);
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

pub export fn sa_db_stats_rows_u64_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    out_count: ?*u64,
    out_sum: ?*u64,
    out_min: ?*u64,
    out_max: ?*u64,
) u32 {
    const count_slot = out_count orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const sum_slot = out_sum orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const min_slot = out_min orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const max_slot = out_max orelse return SA_DB_ERR_INVALID_ARGUMENT;
    count_slot.* = 0;
    sum_slot.* = 0;
    min_slot.* = 0;
    max_slot.* = 0;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const stats = table.snapshotStatsRowsU64(snapshot, @intCast(column_index), in_rows) catch |err| return tableStatus(err);
    count_slot.* = stats.count;
    sum_slot.* = stats.sum;
    min_slot.* = stats.min;
    max_slot.* = stats.max;
    return SA_DB_OK;
}

pub export fn sa_db_stats_rows_i64_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    out_count: ?*u64,
    out_sum: ?*i64,
    out_min: ?*i64,
    out_max: ?*i64,
) u32 {
    const count_slot = out_count orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const sum_slot = out_sum orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const min_slot = out_min orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const max_slot = out_max orelse return SA_DB_ERR_INVALID_ARGUMENT;
    count_slot.* = 0;
    sum_slot.* = 0;
    min_slot.* = 0;
    max_slot.* = 0;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const stats = table.snapshotStatsRowsI64(snapshot, @intCast(column_index), in_rows) catch |err| return tableStatus(err);
    count_slot.* = stats.count;
    sum_slot.* = stats.sum;
    min_slot.* = stats.min;
    max_slot.* = stats.max;
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

pub export fn sa_db_count_i64_cmp_handle(handle: ?*anyopaque, column_index: u64, op: u32, expected: i64, out_count: ?*u64) u32 {
    const count_slot = out_count orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const cmp_op = u64CompareOpFromAbi(op) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const count = table.snapshotCountI64Cmp(snapshot, @intCast(column_index), cmp_op, expected) catch |err| return tableStatus(err);
    count_slot.* = count;
    return SA_DB_OK;
}

pub export fn sa_db_count_u32_cmp_handle(handle: ?*anyopaque, column_index: u64, op: u32, expected: u32, out_count: ?*u64) u32 {
    const count_slot = out_count orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const cmp_op = u64CompareOpFromAbi(op) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const count = table.snapshotCountU32Cmp(snapshot, @intCast(column_index), cmp_op, expected) catch |err| return tableStatus(err);
    count_slot.* = count;
    return SA_DB_OK;
}

pub export fn sa_db_count_i32_cmp_handle(handle: ?*anyopaque, column_index: u64, op: u32, expected: i32, out_count: ?*u64) u32 {
    const count_slot = out_count orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const cmp_op = u64CompareOpFromAbi(op) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const count = table.snapshotCountI32Cmp(snapshot, @intCast(column_index), cmp_op, expected) catch |err| return tableStatus(err);
    count_slot.* = count;
    return SA_DB_OK;
}

pub export fn sa_db_count_u8_cmp_handle(handle: ?*anyopaque, column_index: u64, op: u32, expected: u8, out_count: ?*u64) u32 {
    const count_slot = out_count orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const cmp_op = u64CompareOpFromAbi(op) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const count = table.snapshotCountU8Cmp(snapshot, @intCast(column_index), cmp_op, expected) catch |err| return tableStatus(err);
    count_slot.* = count;
    return SA_DB_OK;
}

pub export fn sa_db_count_i8_cmp_handle(handle: ?*anyopaque, column_index: u64, op: u32, expected: i8, out_count: ?*u64) u32 {
    const count_slot = out_count orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const cmp_op = u64CompareOpFromAbi(op) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const count = table.snapshotCountI8Cmp(snapshot, @intCast(column_index), cmp_op, expected) catch |err| return tableStatus(err);
    count_slot.* = count;
    return SA_DB_OK;
}

pub export fn sa_db_count_u16_cmp_handle(handle: ?*anyopaque, column_index: u64, op: u32, expected: u16, out_count: ?*u64) u32 {
    const count_slot = out_count orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const cmp_op = u64CompareOpFromAbi(op) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const count = table.snapshotCountU16Cmp(snapshot, @intCast(column_index), cmp_op, expected) catch |err| return tableStatus(err);
    count_slot.* = count;
    return SA_DB_OK;
}

pub export fn sa_db_count_i16_cmp_handle(handle: ?*anyopaque, column_index: u64, op: u32, expected: i16, out_count: ?*u64) u32 {
    const count_slot = out_count orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const cmp_op = u64CompareOpFromAbi(op) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const count = table.snapshotCountI16Cmp(snapshot, @intCast(column_index), cmp_op, expected) catch |err| return tableStatus(err);
    count_slot.* = count;
    return SA_DB_OK;
}

pub export fn sa_db_count_f32_cmp_handle(handle: ?*anyopaque, column_index: u64, op: u32, expected: f32, out_count: ?*u64) u32 {
    const count_slot = out_count orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const cmp_op = u64CompareOpFromAbi(op) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const count = table.snapshotCountF32Cmp(snapshot, @intCast(column_index), cmp_op, expected) catch |err| return tableStatus(err);
    count_slot.* = count;
    return SA_DB_OK;
}

pub export fn sa_db_count_f64_cmp_handle(handle: ?*anyopaque, column_index: u64, op: u32, expected: f64, out_count: ?*u64) u32 {
    const count_slot = out_count orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const cmp_op = u64CompareOpFromAbi(op) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const count = table.snapshotCountF64Cmp(snapshot, @intCast(column_index), cmp_op, expected) catch |err| return tableStatus(err);
    count_slot.* = count;
    return SA_DB_OK;
}

pub export fn sa_db_count_bool_handle(handle: ?*anyopaque, column_index: u64, expected: u32, out_count: ?*u64) u32 {
    const count_slot = out_count orelse return SA_DB_ERR_INVALID_ARGUMENT;
    count_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const expected_bool = boolFromAbi(expected) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const count = table.snapshotCountBool(snapshot, @intCast(column_index), expected_bool) catch |err| return tableStatus(err);
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

pub export fn sa_db_find_i64_handle(handle: ?*anyopaque, column_index: u64, expected: i64, out_found: ?*u64, out_row_index: ?*u64) u32 {
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row_slot = out_row_index orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    row_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFindI64(snapshot, @intCast(column_index), expected) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    row_slot.* = result.row_index;
    return SA_DB_OK;
}

pub export fn sa_db_find_u32_handle(handle: ?*anyopaque, column_index: u64, expected: u32, out_found: ?*u64, out_row_index: ?*u64) u32 {
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row_slot = out_row_index orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    row_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFindU32(snapshot, @intCast(column_index), expected) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    row_slot.* = result.row_index;
    return SA_DB_OK;
}

pub export fn sa_db_find_i32_handle(handle: ?*anyopaque, column_index: u64, expected: i32, out_found: ?*u64, out_row_index: ?*u64) u32 {
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row_slot = out_row_index orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    row_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFindI32(snapshot, @intCast(column_index), expected) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    row_slot.* = result.row_index;
    return SA_DB_OK;
}

pub export fn sa_db_find_u8_handle(handle: ?*anyopaque, column_index: u64, expected: u8, out_found: ?*u64, out_row_index: ?*u64) u32 {
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row_slot = out_row_index orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    row_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFindU8(snapshot, @intCast(column_index), expected) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    row_slot.* = result.row_index;
    return SA_DB_OK;
}

pub export fn sa_db_find_i8_handle(handle: ?*anyopaque, column_index: u64, expected: i8, out_found: ?*u64, out_row_index: ?*u64) u32 {
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row_slot = out_row_index orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    row_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFindI8(snapshot, @intCast(column_index), expected) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    row_slot.* = result.row_index;
    return SA_DB_OK;
}

pub export fn sa_db_find_u16_handle(handle: ?*anyopaque, column_index: u64, expected: u16, out_found: ?*u64, out_row_index: ?*u64) u32 {
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row_slot = out_row_index orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    row_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFindU16(snapshot, @intCast(column_index), expected) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    row_slot.* = result.row_index;
    return SA_DB_OK;
}

pub export fn sa_db_find_i16_handle(handle: ?*anyopaque, column_index: u64, expected: i16, out_found: ?*u64, out_row_index: ?*u64) u32 {
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row_slot = out_row_index orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    row_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFindI16(snapshot, @intCast(column_index), expected) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    row_slot.* = result.row_index;
    return SA_DB_OK;
}

pub export fn sa_db_find_f32_handle(handle: ?*anyopaque, column_index: u64, expected: f32, out_found: ?*u64, out_row_index: ?*u64) u32 {
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row_slot = out_row_index orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    row_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFindF32(snapshot, @intCast(column_index), expected) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    row_slot.* = result.row_index;
    return SA_DB_OK;
}

pub export fn sa_db_find_f64_handle(handle: ?*anyopaque, column_index: u64, expected: f64, out_found: ?*u64, out_row_index: ?*u64) u32 {
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row_slot = out_row_index orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    row_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFindF64(snapshot, @intCast(column_index), expected) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    row_slot.* = result.row_index;
    return SA_DB_OK;
}

pub export fn sa_db_find_bool_handle(handle: ?*anyopaque, column_index: u64, expected: u32, out_found: ?*u64, out_row_index: ?*u64) u32 {
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row_slot = out_row_index orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    row_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const expected_bool = boolFromAbi(expected) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFindBool(snapshot, @intCast(column_index), expected_bool) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    row_slot.* = result.row_index;
    return SA_DB_OK;
}

pub export fn sa_db_find_u64_pair_handle(handle: ?*anyopaque, column_index: u64, column_index2: u64, key1: u64, key2: u64, out_found: ?*u64, out_row_index: ?*u64) u32 {
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row_slot = out_row_index orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    row_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFindU64Pair(snapshot, @intCast(column_index), @intCast(column_index2), key1, key2) catch |err| return tableStatus(err);
    found_slot.* = if (result.found) 1 else 0;
    row_slot.* = result.row_index;
    return SA_DB_OK;
}

pub export fn sa_db_find_u64_i64_pair_handle(handle: ?*anyopaque, column_index: u64, column_index2: u64, key1: u64, key2: i64, out_found: ?*u64, out_row_index: ?*u64) u32 {
    const found_slot = out_found orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const row_slot = out_row_index orelse return SA_DB_ERR_INVALID_ARGUMENT;
    found_slot.* = 0;
    row_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFindU64I64Pair(snapshot, @intCast(column_index), @intCast(column_index2), key1, key2) catch |err| return tableStatus(err);
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

pub export fn sa_db_range_i64_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_value: i64,
    max_value: i64,
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
    const result = table.snapshotRangeI64Rows(snapshot, @intCast(column_index), min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_range_u32_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_value: u32,
    max_value: u32,
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
    const result = table.snapshotRangeU32Rows(snapshot, @intCast(column_index), min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_range_i32_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_value: i32,
    max_value: i32,
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
    const result = table.snapshotRangeI32Rows(snapshot, @intCast(column_index), min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_range_u8_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_value: u8,
    max_value: u8,
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
    const result = table.snapshotRangeU8Rows(snapshot, @intCast(column_index), min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_range_i8_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_value: i8,
    max_value: i8,
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
    const result = table.snapshotRangeI8Rows(snapshot, @intCast(column_index), min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_range_u16_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_value: u16,
    max_value: u16,
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
    const result = table.snapshotRangeU16Rows(snapshot, @intCast(column_index), min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_range_i16_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_value: i16,
    max_value: i16,
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
    const result = table.snapshotRangeI16Rows(snapshot, @intCast(column_index), min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_range_f32_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_value: f32,
    max_value: f32,
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
    const result = table.snapshotRangeF32Rows(snapshot, @intCast(column_index), min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_range_f64_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_value: f64,
    max_value: f64,
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
    const result = table.snapshotRangeF64Rows(snapshot, @intCast(column_index), min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_range_u64_null_bitmap_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_value: u64,
    max_value: u64,
    null_bitmap_ptr: ?[*]const u8,
    null_bitmap_len: u64,
    want_null: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const null_bitmap = inputBytes(null_bitmap_ptr, null_bitmap_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotRangeU64RowsNullBitmap(snapshot, @intCast(column_index), min_value, max_value, null_bitmap, want_null != 0, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_range_i64_null_bitmap_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_value: i64,
    max_value: i64,
    null_bitmap_ptr: ?[*]const u8,
    null_bitmap_len: u64,
    want_null: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const null_bitmap = inputBytes(null_bitmap_ptr, null_bitmap_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotRangeI64RowsNullBitmap(snapshot, @intCast(column_index), min_value, max_value, null_bitmap, want_null != 0, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_range_decimal_i64_handle(
    handle: ?*anyopaque,
    column_index: u64,
    scale: u32,
    min_negative: u32,
    min_whole: u64,
    min_fraction: u64,
    max_negative: u32,
    max_whole: u64,
    max_fraction: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    var min_value: i64 = 0;
    var max_value: i64 = 0;
    var status = sa_db_decimal_from_parts(min_negative, min_whole, min_fraction, scale, &min_value);
    if (status != SA_DB_OK) return status;
    status = sa_db_decimal_from_parts(max_negative, max_whole, max_fraction, scale, &max_value);
    if (status != SA_DB_OK) return status;
    return sa_db_range_i64_handle(handle, column_index, min_value, max_value, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_range_decimal_i64_null_bitmap_handle(
    handle: ?*anyopaque,
    column_index: u64,
    scale: u32,
    min_negative: u32,
    min_whole: u64,
    min_fraction: u64,
    max_negative: u32,
    max_whole: u64,
    max_fraction: u64,
    null_bitmap_ptr: ?[*]const u8,
    null_bitmap_len: u64,
    want_null: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    var min_value: i64 = 0;
    var max_value: i64 = 0;
    var status = sa_db_decimal_from_parts(min_negative, min_whole, min_fraction, scale, &min_value);
    if (status != SA_DB_OK) return status;
    status = sa_db_decimal_from_parts(max_negative, max_whole, max_fraction, scale, &max_value);
    if (status != SA_DB_OK) return status;
    return sa_db_range_i64_null_bitmap_handle(handle, column_index, min_value, max_value, null_bitmap_ptr, null_bitmap_len, want_null, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_range_date_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_year: i64,
    min_month: u32,
    min_day: u32,
    max_year: i64,
    max_month: u32,
    max_day: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const min_value = daysFromCivil(min_year, min_month, min_day) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const max_value = daysFromCivil(max_year, max_month, max_day) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return sa_db_range_i64_handle(handle, column_index, min_value, max_value, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_range_date_null_bitmap_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_year: i64,
    min_month: u32,
    min_day: u32,
    max_year: i64,
    max_month: u32,
    max_day: u32,
    null_bitmap_ptr: ?[*]const u8,
    null_bitmap_len: u64,
    want_null: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const min_value = daysFromCivil(min_year, min_month, min_day) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const max_value = daysFromCivil(max_year, max_month, max_day) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return sa_db_range_i64_null_bitmap_handle(handle, column_index, min_value, max_value, null_bitmap_ptr, null_bitmap_len, want_null, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_range_timestamp_ms_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_days: i64,
    min_millis_of_day: u64,
    max_days: i64,
    max_millis_of_day: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const min_value = timestampFromParts(min_days, min_millis_of_day, MS_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const max_value = timestampFromParts(max_days, max_millis_of_day, MS_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return sa_db_range_i64_handle(handle, column_index, min_value, max_value, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_range_timestamp_ms_null_bitmap_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_days: i64,
    min_millis_of_day: u64,
    max_days: i64,
    max_millis_of_day: u64,
    null_bitmap_ptr: ?[*]const u8,
    null_bitmap_len: u64,
    want_null: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const min_value = timestampFromParts(min_days, min_millis_of_day, MS_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const max_value = timestampFromParts(max_days, max_millis_of_day, MS_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return sa_db_range_i64_null_bitmap_handle(handle, column_index, min_value, max_value, null_bitmap_ptr, null_bitmap_len, want_null, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_range_timestamp_us_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_days: i64,
    min_micros_of_day: u64,
    max_days: i64,
    max_micros_of_day: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const min_value = timestampFromParts(min_days, min_micros_of_day, US_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const max_value = timestampFromParts(max_days, max_micros_of_day, US_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return sa_db_range_i64_handle(handle, column_index, min_value, max_value, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_range_timestamp_us_null_bitmap_handle(
    handle: ?*anyopaque,
    column_index: u64,
    min_days: i64,
    min_micros_of_day: u64,
    max_days: i64,
    max_micros_of_day: u64,
    null_bitmap_ptr: ?[*]const u8,
    null_bitmap_len: u64,
    want_null: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const min_value = timestampFromParts(min_days, min_micros_of_day, US_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const max_value = timestampFromParts(max_days, max_micros_of_day, US_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return sa_db_range_i64_null_bitmap_handle(handle, column_index, min_value, max_value, null_bitmap_ptr, null_bitmap_len, want_null, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_range_u64_pair_handle(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    min_key2: u64,
    max_key2: u64,
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
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotRangeU64PairRows(snapshot, @intCast(column_index), @intCast(column_index2), key1, min_key2, max_key2, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_range_u64_i64_pair_handle(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    min_key2: i64,
    max_key2: i64,
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
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotRangeU64I64PairRows(snapshot, @intCast(column_index), @intCast(column_index2), key1, min_key2, max_key2, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_range_u64_date_pair_handle(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    min_year: i64,
    min_month: u32,
    min_day: u32,
    max_year: i64,
    max_month: u32,
    max_day: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const min_value = daysFromCivil(min_year, min_month, min_day) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const max_value = daysFromCivil(max_year, max_month, max_day) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return sa_db_range_u64_i64_pair_handle(handle, column_index, column_index2, key1, min_value, max_value, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_range_u64_timestamp_ms_pair_handle(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    min_days: i64,
    min_millis_of_day: u64,
    max_days: i64,
    max_millis_of_day: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const min_value = timestampFromParts(min_days, min_millis_of_day, MS_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const max_value = timestampFromParts(max_days, max_millis_of_day, MS_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return sa_db_range_u64_i64_pair_handle(handle, column_index, column_index2, key1, min_value, max_value, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_range_u64_timestamp_us_pair_handle(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    min_days: i64,
    min_micros_of_day: u64,
    max_days: i64,
    max_micros_of_day: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const min_value = timestampFromParts(min_days, min_micros_of_day, US_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const max_value = timestampFromParts(max_days, max_micros_of_day, US_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return sa_db_range_u64_i64_pair_handle(handle, column_index, column_index2, key1, min_value, max_value, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_filter_u64_pair_key1_handle(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
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
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterU64PairKey1Rows(snapshot, @intCast(column_index), @intCast(column_index2), key1, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_u64_i64_pair_key1_handle(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
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
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterU64I64PairKey1Rows(snapshot, @intCast(column_index), @intCast(column_index2), key1, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_bool_handle(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u32,
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
    const expected_bool = boolFromAbi(expected) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterBoolRows(snapshot, @intCast(column_index), expected_bool, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_rows_u64_range_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    min_value: u64,
    max_value: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterRowsU64Range(snapshot, @intCast(column_index), in_rows, min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_rows_i64_range_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    min_value: i64,
    max_value: i64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterRowsI64Range(snapshot, @intCast(column_index), in_rows, min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_plan_u64_i64_ranges_handle(
    handle: ?*anyopaque,
    u64_column_index: u64,
    u64_min_value: u64,
    u64_max_value: u64,
    i64_column_index: u64,
    i64_min_value: i64,
    i64_max_value: i64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_info: ?*SaDbPlanInfo,
) u32 {
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    info_slot.* = .{ .written = 0, .total = 0, .first_predicate = 0, .first_total = 0, .second_total = 0 };
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (u64_column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (i64_column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const result = table.snapshotPlanU64I64RangeRows(
        gpa.allocator(),
        snapshot,
        @intCast(u64_column_index),
        u64_min_value,
        u64_max_value,
        @intCast(i64_column_index),
        i64_min_value,
        i64_max_value,
        offset,
        limit,
        rows,
    ) catch |err| return tableStatus(err);
    return fillPlanInfo(out_info, result);
}

pub export fn sa_db_plan_u64_u64_ranges_handle(
    handle: ?*anyopaque,
    first_column_index: u64,
    first_min_value: u64,
    first_max_value: u64,
    second_column_index: u64,
    second_min_value: u64,
    second_max_value: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_info: ?*SaDbPlanInfo,
) u32 {
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    info_slot.* = .{ .written = 0, .total = 0, .first_predicate = 0, .first_total = 0, .second_total = 0 };
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (first_column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (second_column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const result = table.snapshotPlanU64U64RangeRows(
        gpa.allocator(),
        snapshot,
        @intCast(first_column_index),
        first_min_value,
        first_max_value,
        @intCast(second_column_index),
        second_min_value,
        second_max_value,
        offset,
        limit,
        rows,
    ) catch |err| return tableStatus(err);
    return fillPlanInfo(out_info, result);
}

pub export fn sa_db_plan_i64_i64_ranges_handle(
    handle: ?*anyopaque,
    first_column_index: u64,
    first_min_value: i64,
    first_max_value: i64,
    second_column_index: u64,
    second_min_value: i64,
    second_max_value: i64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_info: ?*SaDbPlanInfo,
) u32 {
    const info_slot = out_info orelse return SA_DB_ERR_INVALID_ARGUMENT;
    info_slot.* = .{ .written = 0, .total = 0, .first_predicate = 0, .first_total = 0, .second_total = 0 };
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (first_column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (second_column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const result = table.snapshotPlanI64I64RangeRows(
        gpa.allocator(),
        snapshot,
        @intCast(first_column_index),
        first_min_value,
        first_max_value,
        @intCast(second_column_index),
        second_min_value,
        second_max_value,
        offset,
        limit,
        rows,
    ) catch |err| return tableStatus(err);
    return fillPlanInfo(out_info, result);
}

pub export fn sa_db_filter_rows_f32_range_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    min_value: f32,
    max_value: f32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterRowsF32Range(snapshot, @intCast(column_index), in_rows, min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_rows_f64_range_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    min_value: f64,
    max_value: f64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterRowsF64Range(snapshot, @intCast(column_index), in_rows, min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_rows_u32_range_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    min_value: u32,
    max_value: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterRowsU32Range(snapshot, @intCast(column_index), in_rows, min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_rows_i32_range_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    min_value: i32,
    max_value: i32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterRowsI32Range(snapshot, @intCast(column_index), in_rows, min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_rows_u8_range_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    min_value: u8,
    max_value: u8,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterRowsU8Range(snapshot, @intCast(column_index), in_rows, min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_rows_i8_range_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    min_value: i8,
    max_value: i8,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterRowsI8Range(snapshot, @intCast(column_index), in_rows, min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_rows_u16_range_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    min_value: u16,
    max_value: u16,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterRowsU16Range(snapshot, @intCast(column_index), in_rows, min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_rows_i16_range_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    min_value: i16,
    max_value: i16,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterRowsI16Range(snapshot, @intCast(column_index), in_rows, min_value, max_value, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_filter_rows_decimal_i64_range_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    scale: u32,
    min_negative: u32,
    min_whole: u64,
    min_fraction: u64,
    max_negative: u32,
    max_whole: u64,
    max_fraction: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    var min_value: i64 = 0;
    var max_value: i64 = 0;
    var status = sa_db_decimal_from_parts(min_negative, min_whole, min_fraction, scale, &min_value);
    if (status != SA_DB_OK) return status;
    status = sa_db_decimal_from_parts(max_negative, max_whole, max_fraction, scale, &max_value);
    if (status != SA_DB_OK) return status;
    return sa_db_filter_rows_i64_range_handle(handle, column_index, in_rows_ptr, in_rows_len, min_value, max_value, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_filter_rows_date_range_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    min_year: i64,
    min_month: u32,
    min_day: u32,
    max_year: i64,
    max_month: u32,
    max_day: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const min_value = daysFromCivil(min_year, min_month, min_day) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const max_value = daysFromCivil(max_year, max_month, max_day) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return sa_db_filter_rows_i64_range_handle(handle, column_index, in_rows_ptr, in_rows_len, min_value, max_value, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_filter_rows_timestamp_ms_range_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    min_days: i64,
    min_millis_of_day: u64,
    max_days: i64,
    max_millis_of_day: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const min_value = timestampFromParts(min_days, min_millis_of_day, MS_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const max_value = timestampFromParts(max_days, max_millis_of_day, MS_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return sa_db_filter_rows_i64_range_handle(handle, column_index, in_rows_ptr, in_rows_len, min_value, max_value, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_filter_rows_timestamp_us_range_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    min_days: i64,
    min_micros_of_day: u64,
    max_days: i64,
    max_micros_of_day: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const min_value = timestampFromParts(min_days, min_micros_of_day, US_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const max_value = timestampFromParts(max_days, max_micros_of_day, US_PER_DAY) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    return sa_db_filter_rows_i64_range_handle(handle, column_index, in_rows_ptr, in_rows_len, min_value, max_value, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total);
}

pub export fn sa_db_filter_rows_bool_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    expected: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const expected_bool = boolFromAbi(expected) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotFilterRowsBool(snapshot, @intCast(column_index), in_rows, expected_bool, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_intersect_rows_handle(
    handle: ?*anyopaque,
    left_rows_ptr: ?[*]const u64,
    left_rows_len: u64,
    right_rows_ptr: ?[*]const u64,
    right_rows_len: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const left_rows = inputU64sAllowEmpty(left_rows_ptr, left_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const right_rows = inputU64sAllowEmpty(right_rows_ptr, right_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotIntersectRows(gpa.allocator(), snapshot, left_rows, right_rows, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_union_rows_handle(
    handle: ?*anyopaque,
    left_rows_ptr: ?[*]const u64,
    left_rows_len: u64,
    right_rows_ptr: ?[*]const u64,
    right_rows_len: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const left_rows = inputU64sAllowEmpty(left_rows_ptr, left_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const right_rows = inputU64sAllowEmpty(right_rows_ptr, right_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotUnionRows(gpa.allocator(), snapshot, left_rows, right_rows, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_except_rows_handle(
    handle: ?*anyopaque,
    left_rows_ptr: ?[*]const u64,
    left_rows_len: u64,
    right_rows_ptr: ?[*]const u64,
    right_rows_len: u64,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const left_rows = inputU64sAllowEmpty(left_rows_ptr, left_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const right_rows = inputU64sAllowEmpty(right_rows_ptr, right_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = table.snapshotExceptRows(gpa.allocator(), snapshot, left_rows, right_rows, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

fn sortRowsHandle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    descending: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
    comptime sortFn: anytype,
) u32 {
    const written_slot = out_written orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const total_slot = out_total orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    total_slot.* = 0;
    const in_rows = inputU64sAllowEmpty(in_rows_ptr, in_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const rows = outputU64s(out_rows_ptr, out_rows_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const sort_descending = boolFromAbi(descending) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const result = sortFn(gpa.allocator(), snapshot, @intCast(column_index), in_rows, sort_descending, offset, limit, rows) catch |err| return tableStatus(err);
    written_slot.* = result.written;
    total_slot.* = result.total;
    return SA_DB_OK;
}

pub export fn sa_db_sort_rows_u64_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    descending: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    return sortRowsHandle(handle, column_index, in_rows_ptr, in_rows_len, descending, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total, table.snapshotSortRowsU64);
}

pub export fn sa_db_sort_rows_i64_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    descending: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    return sortRowsHandle(handle, column_index, in_rows_ptr, in_rows_len, descending, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total, table.snapshotSortRowsI64);
}

pub export fn sa_db_sort_rows_f32_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    descending: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    return sortRowsHandle(handle, column_index, in_rows_ptr, in_rows_len, descending, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total, table.snapshotSortRowsF32);
}

pub export fn sa_db_sort_rows_f64_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    descending: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    return sortRowsHandle(handle, column_index, in_rows_ptr, in_rows_len, descending, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total, table.snapshotSortRowsF64);
}

pub export fn sa_db_sort_rows_u32_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    descending: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    return sortRowsHandle(handle, column_index, in_rows_ptr, in_rows_len, descending, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total, table.snapshotSortRowsU32);
}

pub export fn sa_db_sort_rows_i32_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    descending: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    return sortRowsHandle(handle, column_index, in_rows_ptr, in_rows_len, descending, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total, table.snapshotSortRowsI32);
}

pub export fn sa_db_sort_rows_u8_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    descending: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    return sortRowsHandle(handle, column_index, in_rows_ptr, in_rows_len, descending, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total, table.snapshotSortRowsU8);
}

pub export fn sa_db_sort_rows_i8_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    descending: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    return sortRowsHandle(handle, column_index, in_rows_ptr, in_rows_len, descending, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total, table.snapshotSortRowsI8);
}

pub export fn sa_db_sort_rows_u16_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    descending: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    return sortRowsHandle(handle, column_index, in_rows_ptr, in_rows_len, descending, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total, table.snapshotSortRowsU16);
}

pub export fn sa_db_sort_rows_i16_handle(
    handle: ?*anyopaque,
    column_index: u64,
    in_rows_ptr: ?[*]const u64,
    in_rows_len: u64,
    descending: u32,
    offset: u64,
    limit: u64,
    out_rows_ptr: ?[*]u64,
    out_rows_len: u64,
    out_written: ?*u64,
    out_total: ?*u64,
) u32 {
    return sortRowsHandle(handle, column_index, in_rows_ptr, in_rows_len, descending, offset, limit, out_rows_ptr, out_rows_len, out_written, out_total, table.snapshotSortRowsI16);
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

pub export fn sa_db_get_bool_handle(handle: ?*anyopaque, column_index: u64, row_index: u64, out_value: ?*u32) u32 {
    const value_slot = out_value orelse return SA_DB_ERR_INVALID_ARGUMENT;
    value_slot.* = 0;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const value = table.snapshotGetBool(snapshot, @intCast(column_index), row_index) catch |err| return tableStatus(err);
    value_slot.* = if (value) 1 else 0;
    return SA_DB_OK;
}

pub export fn sa_db_get_i64_handle(handle: ?*anyopaque, column_index: u64, row_index: u64, out_value: ?*i64) u32 {
    const value_slot = out_value orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const value = table.snapshotGetI64(snapshot, @intCast(column_index), row_index) catch |err| return tableStatus(err);
    value_slot.* = value;
    return SA_DB_OK;
}

pub export fn sa_db_get_u32_handle(handle: ?*anyopaque, column_index: u64, row_index: u64, out_value: ?*u32) u32 {
    const value_slot = out_value orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const value = table.snapshotGetU32(snapshot, @intCast(column_index), row_index) catch |err| return tableStatus(err);
    value_slot.* = value;
    return SA_DB_OK;
}

pub export fn sa_db_get_i32_handle(handle: ?*anyopaque, column_index: u64, row_index: u64, out_value: ?*i32) u32 {
    const value_slot = out_value orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const value = table.snapshotGetI32(snapshot, @intCast(column_index), row_index) catch |err| return tableStatus(err);
    value_slot.* = value;
    return SA_DB_OK;
}

pub export fn sa_db_get_u8_handle(handle: ?*anyopaque, column_index: u64, row_index: u64, out_value: ?*u8) u32 {
    const value_slot = out_value orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const value = table.snapshotGetU8(snapshot, @intCast(column_index), row_index) catch |err| return tableStatus(err);
    value_slot.* = value;
    return SA_DB_OK;
}

pub export fn sa_db_get_i8_handle(handle: ?*anyopaque, column_index: u64, row_index: u64, out_value: ?*i8) u32 {
    const value_slot = out_value orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const value = table.snapshotGetI8(snapshot, @intCast(column_index), row_index) catch |err| return tableStatus(err);
    value_slot.* = value;
    return SA_DB_OK;
}

pub export fn sa_db_get_u16_handle(handle: ?*anyopaque, column_index: u64, row_index: u64, out_value: ?*u16) u32 {
    const value_slot = out_value orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const value = table.snapshotGetU16(snapshot, @intCast(column_index), row_index) catch |err| return tableStatus(err);
    value_slot.* = value;
    return SA_DB_OK;
}

pub export fn sa_db_get_i16_handle(handle: ?*anyopaque, column_index: u64, row_index: u64, out_value: ?*i16) u32 {
    const value_slot = out_value orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const value = table.snapshotGetI16(snapshot, @intCast(column_index), row_index) catch |err| return tableStatus(err);
    value_slot.* = value;
    return SA_DB_OK;
}

pub export fn sa_db_get_f32_handle(handle: ?*anyopaque, column_index: u64, row_index: u64, out_value: ?*f32) u32 {
    const value_slot = out_value orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const value = table.snapshotGetF32(snapshot, @intCast(column_index), row_index) catch |err| return tableStatus(err);
    value_slot.* = value;
    return SA_DB_OK;
}

pub export fn sa_db_get_f64_handle(handle: ?*anyopaque, column_index: u64, row_index: u64, out_value: ?*f64) u32 {
    const value_slot = out_value orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const value = table.snapshotGetF64(snapshot, @intCast(column_index), row_index) catch |err| return tableStatus(err);
    value_slot.* = value;
    return SA_DB_OK;
}

pub export fn sa_db_project_rows_handle(
    handle: ?*anyopaque,
    row_indices_ptr: ?[*]const u64,
    row_indices_len: u64,
    column_indices_ptr: ?[*]const u64,
    column_indices_len: u64,
    out_bytes_ptr: ?[*]u8,
    out_bytes_len: u64,
    out_written_rows: ?*u64,
    out_required_bytes: ?*u64,
) u32 {
    const row_indices = inputU64s(row_indices_ptr, row_indices_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const column_indices = inputU64s(column_indices_ptr, column_indices_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const written_slot = out_written_rows orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const required_slot = out_required_bytes orelse return SA_DB_ERR_INVALID_ARGUMENT;
    written_slot.* = 0;
    required_slot.* = 0;

    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);

    const required_bytes = table.snapshotProjectRowsRequiredBytes(snapshot, @intCast(row_indices.len), column_indices) catch |err| return tableStatus(err);
    required_slot.* = required_bytes;
    if (required_bytes > out_bytes_len) return SA_DB_ERR_CURSOR_OVERFLOW;

    const out_bytes = outputBytes(out_bytes_ptr, out_bytes_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const result = table.snapshotProjectRows(snapshot, row_indices, column_indices, out_bytes) catch |err| return tableStatus(err);
    written_slot.* = result.written_rows;
    required_slot.* = result.required_bytes;
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

pub export fn sa_db_get_row_i64_key_handle(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i64,
    out_row_ptr: ?[*]u8,
    out_row_len: u64,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const out_row = outputBytes(out_row_ptr, out_row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    table.snapshotGetRowI64Key(snapshot, @intCast(column_index), expected, out_row) catch |err| return tableStatus(err);
    return SA_DB_OK;
}

pub export fn sa_db_get_row_u32_key_handle(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u32,
    out_row_ptr: ?[*]u8,
    out_row_len: u64,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const out_row = outputBytes(out_row_ptr, out_row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    table.snapshotGetRowU32Key(snapshot, @intCast(column_index), expected, out_row) catch |err| return tableStatus(err);
    return SA_DB_OK;
}

pub export fn sa_db_get_row_i32_key_handle(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i32,
    out_row_ptr: ?[*]u8,
    out_row_len: u64,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const out_row = outputBytes(out_row_ptr, out_row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    table.snapshotGetRowI32Key(snapshot, @intCast(column_index), expected, out_row) catch |err| return tableStatus(err);
    return SA_DB_OK;
}

pub export fn sa_db_get_row_u8_key_handle(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u8,
    out_row_ptr: ?[*]u8,
    out_row_len: u64,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const out_row = outputBytes(out_row_ptr, out_row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    table.snapshotGetRowU8Key(snapshot, @intCast(column_index), expected, out_row) catch |err| return tableStatus(err);
    return SA_DB_OK;
}

pub export fn sa_db_get_row_i8_key_handle(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i8,
    out_row_ptr: ?[*]u8,
    out_row_len: u64,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const out_row = outputBytes(out_row_ptr, out_row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    table.snapshotGetRowI8Key(snapshot, @intCast(column_index), expected, out_row) catch |err| return tableStatus(err);
    return SA_DB_OK;
}

pub export fn sa_db_get_row_u16_key_handle(
    handle: ?*anyopaque,
    column_index: u64,
    expected: u16,
    out_row_ptr: ?[*]u8,
    out_row_len: u64,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const out_row = outputBytes(out_row_ptr, out_row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    table.snapshotGetRowU16Key(snapshot, @intCast(column_index), expected, out_row) catch |err| return tableStatus(err);
    return SA_DB_OK;
}

pub export fn sa_db_get_row_i16_key_handle(
    handle: ?*anyopaque,
    column_index: u64,
    expected: i16,
    out_row_ptr: ?[*]u8,
    out_row_len: u64,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const out_row = outputBytes(out_row_ptr, out_row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    table.snapshotGetRowI16Key(snapshot, @intCast(column_index), expected, out_row) catch |err| return tableStatus(err);
    return SA_DB_OK;
}

pub export fn sa_db_get_row_u64_pair_key_handle(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    key2: u64,
    out_row_ptr: ?[*]u8,
    out_row_len: u64,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const out_row = outputBytes(out_row_ptr, out_row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    table.snapshotGetRowU64PairKey(snapshot, @intCast(column_index), @intCast(column_index2), key1, key2, out_row) catch |err| return tableStatus(err);
    return SA_DB_OK;
}

pub export fn sa_db_get_row_u64_i64_pair_key_handle(
    handle: ?*anyopaque,
    column_index: u64,
    column_index2: u64,
    key1: u64,
    key2: i64,
    out_row_ptr: ?[*]u8,
    out_row_len: u64,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const out_row = outputBytes(out_row_ptr, out_row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    table.snapshotGetRowU64I64PairKey(snapshot, @intCast(column_index), @intCast(column_index2), key1, key2, out_row) catch |err| return tableStatus(err);
    return SA_DB_OK;
}

pub export fn sa_db_get_row_blob_eq_key_handle(
    handle: ?*anyopaque,
    column_index: u64,
    store_ptr: ?[*]const u8,
    store_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
    out_row_ptr: ?[*]u8,
    out_row_len: u64,
) u32 {
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const store_name = requiredBytes(store_ptr, store_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const value = inputBytes(value_ptr, value_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    const out_row = outputBytes(out_row_ptr, out_row_len) orelse return SA_DB_ERR_INVALID_ARGUMENT;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    table.snapshotGetRowBlobEqKey(gpa.allocator(), snapshot, @intCast(column_index), store_name, value, out_row) catch |err| return tableStatus(err);
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

pub export fn sa_db_min_i64_handle(handle: ?*anyopaque, column_index: u64, out_min: ?*i64) u32 {
    const min_slot = out_min orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const min_value = table.snapshotMinI64(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    min_slot.* = min_value;
    return SA_DB_OK;
}

pub export fn sa_db_max_i64_handle(handle: ?*anyopaque, column_index: u64, out_max: ?*i64) u32 {
    const max_slot = out_max orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const max_value = table.snapshotMaxI64(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    max_slot.* = max_value;
    return SA_DB_OK;
}

pub export fn sa_db_min_u32_handle(handle: ?*anyopaque, column_index: u64, out_min: ?*u32) u32 {
    const min_slot = out_min orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const min_value = table.snapshotMinU32(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    min_slot.* = min_value;
    return SA_DB_OK;
}

pub export fn sa_db_max_u32_handle(handle: ?*anyopaque, column_index: u64, out_max: ?*u32) u32 {
    const max_slot = out_max orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const max_value = table.snapshotMaxU32(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    max_slot.* = max_value;
    return SA_DB_OK;
}

pub export fn sa_db_min_i32_handle(handle: ?*anyopaque, column_index: u64, out_min: ?*i32) u32 {
    const min_slot = out_min orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const min_value = table.snapshotMinI32(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    min_slot.* = min_value;
    return SA_DB_OK;
}

pub export fn sa_db_max_i32_handle(handle: ?*anyopaque, column_index: u64, out_max: ?*i32) u32 {
    const max_slot = out_max orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const max_value = table.snapshotMaxI32(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    max_slot.* = max_value;
    return SA_DB_OK;
}

pub export fn sa_db_min_u8_handle(handle: ?*anyopaque, column_index: u64, out_min: ?*u8) u32 {
    const min_slot = out_min orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const min_value = table.snapshotMinU8(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    min_slot.* = min_value;
    return SA_DB_OK;
}

pub export fn sa_db_max_u8_handle(handle: ?*anyopaque, column_index: u64, out_max: ?*u8) u32 {
    const max_slot = out_max orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const max_value = table.snapshotMaxU8(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    max_slot.* = max_value;
    return SA_DB_OK;
}

pub export fn sa_db_min_i8_handle(handle: ?*anyopaque, column_index: u64, out_min: ?*i8) u32 {
    const min_slot = out_min orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const min_value = table.snapshotMinI8(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    min_slot.* = min_value;
    return SA_DB_OK;
}

pub export fn sa_db_max_i8_handle(handle: ?*anyopaque, column_index: u64, out_max: ?*i8) u32 {
    const max_slot = out_max orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const max_value = table.snapshotMaxI8(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    max_slot.* = max_value;
    return SA_DB_OK;
}

pub export fn sa_db_min_u16_handle(handle: ?*anyopaque, column_index: u64, out_min: ?*u16) u32 {
    const min_slot = out_min orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const min_value = table.snapshotMinU16(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    min_slot.* = min_value;
    return SA_DB_OK;
}

pub export fn sa_db_max_u16_handle(handle: ?*anyopaque, column_index: u64, out_max: ?*u16) u32 {
    const max_slot = out_max orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const max_value = table.snapshotMaxU16(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    max_slot.* = max_value;
    return SA_DB_OK;
}

pub export fn sa_db_min_i16_handle(handle: ?*anyopaque, column_index: u64, out_min: ?*i16) u32 {
    const min_slot = out_min orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const min_value = table.snapshotMinI16(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    min_slot.* = min_value;
    return SA_DB_OK;
}

pub export fn sa_db_max_i16_handle(handle: ?*anyopaque, column_index: u64, out_max: ?*i16) u32 {
    const max_slot = out_max orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const max_value = table.snapshotMaxI16(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    max_slot.* = max_value;
    return SA_DB_OK;
}

pub export fn sa_db_min_f32_handle(handle: ?*anyopaque, column_index: u64, out_min: ?*f32) u32 {
    const min_slot = out_min orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const min_value = table.snapshotMinF32(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    min_slot.* = min_value;
    return SA_DB_OK;
}

pub export fn sa_db_max_f32_handle(handle: ?*anyopaque, column_index: u64, out_max: ?*f32) u32 {
    const max_slot = out_max orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const max_value = table.snapshotMaxF32(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    max_slot.* = max_value;
    return SA_DB_OK;
}

pub export fn sa_db_min_f64_handle(handle: ?*anyopaque, column_index: u64, out_min: ?*f64) u32 {
    const min_slot = out_min orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const min_value = table.snapshotMinF64(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    min_slot.* = min_value;
    return SA_DB_OK;
}

pub export fn sa_db_max_f64_handle(handle: ?*anyopaque, column_index: u64, out_max: ?*f64) u32 {
    const max_slot = out_max orelse return SA_DB_ERR_INVALID_ARGUMENT;
    if (column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return SA_DB_ERR_INVALID_ARGUMENT;
    const snapshot = acquireReadSnapshot(handle) orelse return SA_DB_ERR_INVALID_ARGUMENT;
    defer releaseReadSnapshot(snapshot);
    const max_value = table.snapshotMaxF64(snapshot, @intCast(column_index)) catch |err| return tableStatus(err);
    max_slot.* = max_value;
    return SA_DB_OK;
}

test "db SA ABI logical type helpers" {
    var decimal: i64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_decimal_from_parts(0, 123, 45, 2, &decimal));
    try std.testing.expectEqual(@as(i64, 12345), decimal);
    try std.testing.expectEqual(SA_DB_OK, sa_db_decimal_from_parts(1, 10, 5, 2, &decimal));
    try std.testing.expectEqual(@as(i64, -1005), decimal);
    try std.testing.expectEqual(SA_DB_OK, sa_db_decimal_from_parts(1, 9223372036854775808, 0, 0, &decimal));
    try std.testing.expectEqual(std.math.minInt(i64), decimal);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_decimal_from_parts(0, 9223372036854775808, 0, 0, &decimal));
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_decimal_from_parts(0, 1, 100, 2, &decimal));

    var negative: u32 = 0;
    var whole: u64 = 0;
    var fraction: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_decimal_to_parts(-1005, 2, &negative, &whole, &fraction));
    try std.testing.expectEqual(@as(u32, 1), negative);
    try std.testing.expectEqual(@as(u64, 10), whole);
    try std.testing.expectEqual(@as(u64, 5), fraction);

    var days: i64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_date_from_ymd(1970, 1, 1, &days));
    try std.testing.expectEqual(@as(i64, 0), days);
    try std.testing.expectEqual(SA_DB_OK, sa_db_date_from_ymd(2024, 2, 29, &days));
    try std.testing.expectEqual(@as(i64, 19782), days);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_date_from_ymd(2023, 2, 29, &days));

    var year: i64 = 0;
    var month: u32 = 0;
    var day: u32 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_date_to_ymd(19782, &year, &month, &day));
    try std.testing.expectEqual(@as(i64, 2024), year);
    try std.testing.expectEqual(@as(u32, 2), month);
    try std.testing.expectEqual(@as(u32, 29), day);

    var timestamp: i64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_timestamp_ms_from_parts(0, 1, &timestamp));
    try std.testing.expectEqual(@as(i64, 1), timestamp);
    try std.testing.expectEqual(SA_DB_OK, sa_db_timestamp_ms_from_parts(-1, MS_PER_DAY - 1, &timestamp));
    try std.testing.expectEqual(@as(i64, -1), timestamp);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_timestamp_ms_from_parts(0, MS_PER_DAY, &timestamp));

    var subday: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_timestamp_ms_to_parts(-1, &days, &subday));
    try std.testing.expectEqual(@as(i64, -1), days);
    try std.testing.expectEqual(@as(u64, MS_PER_DAY - 1), subday);
    try std.testing.expectEqual(SA_DB_OK, sa_db_timestamp_us_from_parts(-1, US_PER_DAY - 1, &timestamp));
    try std.testing.expectEqual(@as(i64, -1), timestamp);
    try std.testing.expectEqual(SA_DB_OK, sa_db_timestamp_us_to_parts(-1, &days, &subday));
    try std.testing.expectEqual(@as(i64, -1), days);
    try std.testing.expectEqual(@as(u64, US_PER_DAY - 1), subday);

    var encoded_bool: u64 = 0;
    var decoded_bool: u32 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_bool_encode(99, &encoded_bool));
    try std.testing.expectEqual(@as(u64, 1), encoded_bool);
    try std.testing.expectEqual(SA_DB_OK, sa_db_bool_decode(encoded_bool, &decoded_bool));
    try std.testing.expectEqual(@as(u32, 1), decoded_bool);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_bool_decode(2, &decoded_bool));

    var bitmap_len: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_null_bitmap_required_bytes(9, &bitmap_len));
    try std.testing.expectEqual(@as(u64, 2), bitmap_len);
    var bitmap: [2]u8 = .{ 0xff, 0xff };
    try std.testing.expectEqual(SA_DB_OK, sa_db_null_bitmap_clear(&bitmap, bitmap.len));
    try std.testing.expectEqual(@as(u8, 0), bitmap[0]);
    try std.testing.expectEqual(@as(u8, 0), bitmap[1]);
    try std.testing.expectEqual(SA_DB_OK, sa_db_null_bitmap_set(&bitmap, bitmap.len, 8, 1));
    var is_null: u32 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_null_bitmap_get(&bitmap, bitmap.len, 0, &is_null));
    try std.testing.expectEqual(@as(u32, 0), is_null);
    try std.testing.expectEqual(SA_DB_OK, sa_db_null_bitmap_get(&bitmap, bitmap.len, 8, &is_null));
    try std.testing.expectEqual(@as(u32, 1), is_null);
    try std.testing.expectEqual(SA_DB_OK, sa_db_null_bitmap_set(&bitmap, bitmap.len, 8, 0));
    try std.testing.expectEqual(SA_DB_OK, sa_db_null_bitmap_get(&bitmap, bitmap.len, 8, &is_null));
    try std.testing.expectEqual(@as(u32, 0), is_null);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_null_bitmap_get(&bitmap, bitmap.len, 16, &is_null));
}

test "db SA ABI interns and reads string dictionaries" {
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
        \\#def COL_STATUS_STRIDE = 8 // u64
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "members.sadb-schema".ptr, "members.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

    var active_id: u64 = 0;
    var inserted: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_intern(root.ptr, root.len, "members".ptr, "members".len, "member_status".ptr, "member_status".len, "active".ptr, "active".len, &active_id, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 1), active_id);
    try std.testing.expectEqual(@as(u64, 1), inserted);
    try std.testing.expectEqual(@as(u64, 1), info.epoch);
    var paused_id: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_intern(root.ptr, root.len, "members".ptr, "members".len, "member_status".ptr, "member_status".len, "paused".ptr, "paused".len, &paused_id, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 2), paused_id);
    try std.testing.expectEqual(@as(u64, 1), inserted);
    try std.testing.expectEqual(@as(u64, 2), info.epoch);
    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_intern(root.ptr, root.len, "members".ptr, "members".len, "member_status".ptr, "member_status".len, "active".ptr, "active".len, &active_id, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 1), active_id);
    try std.testing.expectEqual(@as(u64, 0), inserted);
    try std.testing.expectEqual(@as(u64, 2), info.epoch);

    var found: u64 = 0;
    var lookup_id: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_lookup(root.ptr, root.len, "members".ptr, "members".len, "member_status".ptr, "member_status".len, "paused".ptr, "paused".len, &found, &lookup_id));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(@as(u64, 2), lookup_id);
    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_lookup(root.ptr, root.len, "members".ptr, "members".len, "member_status".ptr, "member_status".len, "closed".ptr, "closed".len, &found, &lookup_id));
    try std.testing.expectEqual(@as(u64, 0), found);
    try std.testing.expectEqual(@as(u64, 0), lookup_id);

    var value_len: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_value_len(root.ptr, root.len, "members".ptr, "members".len, "member_status".ptr, "member_status".len, paused_id, &found, &value_len));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(@as(u64, 6), value_len);
    var value_buf: [8]u8 = undefined;
    var written: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_value_copy(root.ptr, root.len, "members".ptr, "members".len, "member_status".ptr, "member_status".len, paused_id, &value_buf, value_buf.len, &found, &written));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(@as(u64, 6), written);
    try std.testing.expectEqualStrings("paused", value_buf[0..@intCast(written)]);

    var read_handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "members".ptr, "members".len, &read_handle));
    try std.testing.expect(read_handle != null);
    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_lookup_handle(read_handle, "member_status".ptr, "member_status".len, "active".ptr, "active".len, &found, &lookup_id));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(@as(u64, 1), lookup_id);
    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_lookup_handle(read_handle, "member_status".ptr, "member_status".len, "closed".ptr, "closed".len, &found, &lookup_id));
    try std.testing.expectEqual(@as(u64, 0), found);
    try std.testing.expectEqual(@as(u64, 0), lookup_id);
    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_value_len_handle(read_handle, "member_status".ptr, "member_status".len, paused_id, &found, &value_len));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(@as(u64, 6), value_len);
    @memset(value_buf[0..], 0);
    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_value_copy_handle(read_handle, "member_status".ptr, "member_status".len, paused_id, &value_buf, value_buf.len, &found, &written));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(@as(u64, 6), written);
    try std.testing.expectEqualStrings("paused", value_buf[0..@intCast(written)]);
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(read_handle));

    try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, "members".ptr, "members".len, &info));
}

test "db SA ABI queries logical bool columns" {
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
        \\#def COL_ACTIVE_STRIDE = 1 // u8 bool
        \\#def COL_POSTED_STRIDE = 8 // u64 bool
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "bool_members.sadb-schema".ptr, "bool_members.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

    var ids = [_]u64{ 1, 2, 3, 4 };
    var active = [_]u8{ 1, 1, 0, 1 };
    var posted = [_]u64{ 0, 1, 1, 0 };
    const cols = [_]SaDbColumnInput{
        .{ .data = @ptrCast(&ids), .len = @sizeOf(@TypeOf(ids)) },
        .{ .data = @ptrCast(&active), .len = @sizeOf(@TypeOf(active)) },
        .{ .data = @ptrCast(&posted), .len = @sizeOf(@TypeOf(posted)) },
    };
    try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "bool_members".ptr, "bool_members".len, active.len, &cols, cols.len, &info));

    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "bool_members".ptr, "bool_members".len, &handle));
    defer _ = sa_db_close_read_table(handle);

    var count: u64 = 99;
    try std.testing.expectEqual(SA_DB_OK, sa_db_count_bool_handle(handle, 1, 1, &count));
    try std.testing.expectEqual(@as(u64, 3), count);
    try std.testing.expectEqual(SA_DB_OK, sa_db_count_bool_handle(handle, 1, 0, &count));
    try std.testing.expectEqual(@as(u64, 1), count);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_count_bool_handle(handle, 1, 2, &count));
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_count_bool_handle(handle, 0, 1, &count));

    var found: u64 = 0;
    var row_index: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_bool_handle(handle, 1, 0, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(@as(u64, 2), row_index);

    var rows = [_]u64{ 99, 99, 99 };
    var written: u64 = 0;
    var total: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_bool_handle(handle, 1, 1, 1, 2, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 1), rows[0]);
    try std.testing.expectEqual(@as(u64, 3), rows[1]);

    var bool_value: u32 = 99;
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_bool_handle(handle, 1, 3, &bool_value));
    try std.testing.expectEqual(@as(u32, 1), bool_value);
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_bool_handle(handle, 2, 2, &bool_value));
    try std.testing.expectEqual(@as(u32, 1), bool_value);
}

test "db SA ABI creates and queries u64 pair indexes" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_ORDER_ID_STRIDE = 8 // u64
        \\#def COL_LINE_NO_STRIDE = 8 // u64
        \\#def COL_QTY_STRIDE = 8 // u64
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "order_lines.sadb-schema".ptr, "order_lines.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

    var order_ids = [_]u64{ 10, 10, 11, 10 };
    var line_nos = [_]u64{ 1, 2, 1, 3 };
    var qtys = [_]u64{ 5, 7, 9, 11 };
    const cols = [_]SaDbColumnInput{
        .{ .data = @ptrCast(&order_ids), .len = @sizeOf(@TypeOf(order_ids)) },
        .{ .data = @ptrCast(&line_nos), .len = @sizeOf(@TypeOf(line_nos)) },
        .{ .data = @ptrCast(&qtys), .len = @sizeOf(@TypeOf(qtys)) },
    };
    try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "order_lines".ptr, "order_lines".len, order_ids.len, &cols, cols.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_u64_pair_index(root.ptr, root.len, "order_lines".ptr, "order_lines".len, 0, 1, 1, &info));
    try std.testing.expectEqual(@as(u64, 2), info.epoch);

    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "order_lines".ptr, "order_lines".len, &handle));
    var found: u64 = 0;
    var row_index: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_pair_handle(handle, 0, 1, 10, 2, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(@as(u64, 1), row_index);
    var qty: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_u64_handle(handle, 2, row_index, &qty));
    try std.testing.expectEqual(@as(u64, 7), qty);

    var rows = [_]u64{ 99, 99, 99 };
    var written: u64 = 0;
    var total: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_range_u64_pair_handle(handle, 0, 1, 10, 1, 3, 0, 3, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 3), written);
    try std.testing.expectEqual(@as(u64, 0), rows[0]);
    try std.testing.expectEqual(@as(u64, 1), rows[1]);
    try std.testing.expectEqual(@as(u64, 3), rows[2]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_u64_pair_key1_handle(handle, 0, 1, 10, 0, 3, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 3), written);
    try std.testing.expectEqual(@as(u64, 0), rows[0]);
    try std.testing.expectEqual(@as(u64, 1), rows[1]);
    try std.testing.expectEqual(@as(u64, 3), rows[2]);
    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_u64_pair_key1_handle(handle, 0, 1, 10, 2, 1, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 1), written);
    try std.testing.expectEqual(@as(u64, 3), rows[0]);
    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_u64_pair_key1_handle(handle, 0, 1, 99, 0, 3, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), total);
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));

    try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, "order_lines".ptr, "order_lines".len, &info));
}

test "db SA ABI writes rows by i64 keys" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_DAY_STRIDE = 8 // i64 date
        \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64 decimal(2)
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "i64_write_days.sadb-schema".ptr, "i64_write_days.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

    var days = [_]i64{ -5, 0, 10 };
    var totals = [_]i64{ 1000, 2000, 3000 };
    const cols = [_]SaDbColumnInput{
        .{ .data = @ptrCast(&days), .len = @sizeOf(@TypeOf(days)) },
        .{ .data = @ptrCast(&totals), .len = @sizeOf(@TypeOf(totals)) },
    };
    try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "i64_write_days".ptr, "i64_write_days".len, days.len, &cols, cols.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_i64_index(root.ptr, root.len, "i64_write_days".ptr, "i64_write_days".len, 0, 1, &info));

    var row: [16]u8 = undefined;
    std.mem.writeInt(i64, row[0..8], 0, .little);
    std.mem.writeInt(i64, row[8..16], 2100, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_update_row_i64_key(root.ptr, root.len, "i64_write_days".ptr, "i64_write_days".len, 0, 0, &row, row.len, &info));

    std.mem.writeInt(i64, row[0..8], 99, .little);
    std.mem.writeInt(i64, row[8..16], 9900, .little);
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_update_row_i64_key(root.ptr, root.len, "i64_write_days".ptr, "i64_write_days".len, 0, 99, &row, row.len, &info));

    std.mem.writeInt(i64, row[0..8], 1, .little);
    std.mem.writeInt(i64, row[8..16], 111, .little);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_update_row_i64_key(root.ptr, root.len, "i64_write_days".ptr, "i64_write_days".len, 0, 0, &row, row.len, &info));

    var inserted: u64 = 99;
    std.mem.writeInt(i64, row[0..8], -5, .little);
    std.mem.writeInt(i64, row[8..16], 1100, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_i64_key(root.ptr, root.len, "i64_write_days".ptr, "i64_write_days".len, 0, -5, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 0), inserted);

    std.mem.writeInt(i64, row[0..8], 20, .little);
    std.mem.writeInt(i64, row[8..16], 2000, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_i64_key(root.ptr, root.len, "i64_write_days".ptr, "i64_write_days".len, 0, 20, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 1), inserted);
    try std.testing.expectEqual(@as(u64, 4), info.row_count);

    try std.testing.expectEqual(SA_DB_OK, sa_db_delete_i64_key(root.ptr, root.len, "i64_write_days".ptr, "i64_write_days".len, 0, 10, &info));
    try std.testing.expectEqual(@as(u64, 3), info.row_count);
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_delete_i64_key(root.ptr, root.len, "i64_write_days".ptr, "i64_write_days".len, 0, 10, &info));

    var tx_handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "i64_write_days".ptr, "i64_write_days".len, &tx_handle));
    std.mem.writeInt(i64, row[0..8], 0, .little);
    std.mem.writeInt(i64, row[8..16], 2500, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_i64_key(tx_handle, 0, 0, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 0), inserted);

    std.mem.writeInt(i64, row[0..8], 99, .little);
    std.mem.writeInt(i64, row[8..16], 9900, .little);
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_tx_update_row_i64_key(tx_handle, 0, 99, &row, row.len, &info));

    std.mem.writeInt(i64, row[0..8], 20, .little);
    std.mem.writeInt(i64, row[8..16], 2200, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_update_row_i64_key(tx_handle, 0, 20, &row, row.len, &info));

    std.mem.writeInt(i64, row[0..8], -1, .little);
    std.mem.writeInt(i64, row[8..16], 900, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_i64_key(tx_handle, 0, -1, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 1), inserted);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_delete_i64_key(tx_handle, 0, -5, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
    try std.testing.expectEqual(@as(u64, 3), info.row_count);

    tx_handle = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "i64_write_days".ptr, "i64_write_days".len, &tx_handle));
    std.mem.writeInt(i64, row[0..8], 99, .little);
    std.mem.writeInt(i64, row[8..16], 9900, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_i64_key(tx_handle, 0, 99, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_rollback(tx_handle));

    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "i64_write_days".ptr, "i64_write_days".len, &handle));
    var found: u64 = 0;
    var row_index: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_i64_handle(handle, 0, 0, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 1), found);
    var total: i64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_i64_handle(handle, 1, row_index, &total));
    try std.testing.expectEqual(@as(i64, 2500), total);
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_i64_handle(handle, 0, 20, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_i64_handle(handle, 1, row_index, &total));
    try std.testing.expectEqual(@as(i64, 2200), total);
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_i64_handle(handle, 0, -1, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_i64_handle(handle, 0, -5, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 0), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_i64_handle(handle, 0, 99, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 0), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, "i64_write_days".ptr, "i64_write_days".len, &info));
}

test "db SA ABI writes rows by u32 and i32 keys" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    var info: SaDbTableInfo = undefined;

    {
        const schema_source =
            \\#def MAX_ROWS = 8
            \\#def COL_CHANNEL_ID_STRIDE = 4 // u32
            \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64 decimal(2)
        ;
        try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "u32_write_channels.sadb-schema".ptr, "u32_write_channels.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

        var channel_ids = [_]u32{ 10, 20, 30 };
        var totals = [_]i64{ 1000, 2000, 3000 };
        const cols = [_]SaDbColumnInput{
            .{ .data = @ptrCast(&channel_ids), .len = @sizeOf(@TypeOf(channel_ids)) },
            .{ .data = @ptrCast(&totals), .len = @sizeOf(@TypeOf(totals)) },
        };
        try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "u32_write_channels".ptr, "u32_write_channels".len, channel_ids.len, &cols, cols.len, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_create_u32_index(root.ptr, root.len, "u32_write_channels".ptr, "u32_write_channels".len, 0, 1, &info));

        var row: [12]u8 = undefined;
        std.mem.writeInt(u32, row[0..4], 20, .little);
        std.mem.writeInt(i64, row[4..12], 2200, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_update_row_u32_key(root.ptr, root.len, "u32_write_channels".ptr, "u32_write_channels".len, 0, 20, &row, row.len, &info));

        std.mem.writeInt(u32, row[0..4], 99, .little);
        std.mem.writeInt(i64, row[4..12], 9900, .little);
        try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_update_row_u32_key(root.ptr, root.len, "u32_write_channels".ptr, "u32_write_channels".len, 0, 99, &row, row.len, &info));

        var inserted: u64 = 99;
        std.mem.writeInt(u32, row[0..4], 10, .little);
        std.mem.writeInt(i64, row[4..12], 1100, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_u32_key(root.ptr, root.len, "u32_write_channels".ptr, "u32_write_channels".len, 0, 10, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 0), inserted);

        std.mem.writeInt(u32, row[0..4], 40, .little);
        std.mem.writeInt(i64, row[4..12], 4000, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_u32_key(root.ptr, root.len, "u32_write_channels".ptr, "u32_write_channels".len, 0, 40, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 1), inserted);

        try std.testing.expectEqual(SA_DB_OK, sa_db_delete_u32_key(root.ptr, root.len, "u32_write_channels".ptr, "u32_write_channels".len, 0, 30, &info));
        try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_delete_u32_key(root.ptr, root.len, "u32_write_channels".ptr, "u32_write_channels".len, 0, 30, &info));

        var tx_handle: ?*anyopaque = null;
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "u32_write_channels".ptr, "u32_write_channels".len, &tx_handle));
        std.mem.writeInt(u32, row[0..4], 20, .little);
        std.mem.writeInt(i64, row[4..12], 2500, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u32_key(tx_handle, 0, 20, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 0), inserted);

        std.mem.writeInt(u32, row[0..4], 40, .little);
        std.mem.writeInt(i64, row[4..12], 4400, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_update_row_u32_key(tx_handle, 0, 40, &row, row.len, &info));

        std.mem.writeInt(u32, row[0..4], 50, .little);
        std.mem.writeInt(i64, row[4..12], 5000, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u32_key(tx_handle, 0, 50, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 1), inserted);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_delete_u32_key(tx_handle, 0, 10, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
        try std.testing.expectEqual(@as(u64, 3), info.row_count);

        tx_handle = null;
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "u32_write_channels".ptr, "u32_write_channels".len, &tx_handle));
        std.mem.writeInt(u32, row[0..4], 99, .little);
        std.mem.writeInt(i64, row[4..12], 9900, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u32_key(tx_handle, 0, 99, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_rollback(tx_handle));

        var handle: ?*anyopaque = null;
        try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "u32_write_channels".ptr, "u32_write_channels".len, &handle));
        var found: u64 = 0;
        var row_index: u64 = 0;
        try std.testing.expectEqual(SA_DB_OK, sa_db_find_u32_handle(handle, 0, 20, &found, &row_index));
        try std.testing.expectEqual(@as(u64, 1), found);
        var total: i64 = 0;
        try std.testing.expectEqual(SA_DB_OK, sa_db_get_i64_handle(handle, 1, row_index, &total));
        try std.testing.expectEqual(@as(i64, 2500), total);
        try std.testing.expectEqual(SA_DB_OK, sa_db_find_u32_handle(handle, 0, 99, &found, &row_index));
        try std.testing.expectEqual(@as(u64, 0), found);
        try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
        try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, "u32_write_channels".ptr, "u32_write_channels".len, &info));
    }

    {
        const schema_source =
            \\#def MAX_ROWS = 8
            \\#def COL_ADJUSTMENT_STRIDE = 4 // i32
            \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64 decimal(2)
        ;
        try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "i32_write_adjustments.sadb-schema".ptr, "i32_write_adjustments.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

        var adjustments = [_]i32{ -5, 0, 10 };
        var totals = [_]i64{ 1000, 2000, 3000 };
        const cols = [_]SaDbColumnInput{
            .{ .data = @ptrCast(&adjustments), .len = @sizeOf(@TypeOf(adjustments)) },
            .{ .data = @ptrCast(&totals), .len = @sizeOf(@TypeOf(totals)) },
        };
        try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "i32_write_adjustments".ptr, "i32_write_adjustments".len, adjustments.len, &cols, cols.len, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_create_i32_index(root.ptr, root.len, "i32_write_adjustments".ptr, "i32_write_adjustments".len, 0, 1, &info));

        var row: [12]u8 = undefined;
        std.mem.writeInt(i32, row[0..4], 0, .little);
        std.mem.writeInt(i64, row[4..12], 2100, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_update_row_i32_key(root.ptr, root.len, "i32_write_adjustments".ptr, "i32_write_adjustments".len, 0, 0, &row, row.len, &info));

        std.mem.writeInt(i32, row[0..4], 1, .little);
        std.mem.writeInt(i64, row[4..12], 111, .little);
        try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_update_row_i32_key(root.ptr, root.len, "i32_write_adjustments".ptr, "i32_write_adjustments".len, 0, 0, &row, row.len, &info));

        var inserted: u64 = 99;
        std.mem.writeInt(i32, row[0..4], -5, .little);
        std.mem.writeInt(i64, row[4..12], 1100, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_i32_key(root.ptr, root.len, "i32_write_adjustments".ptr, "i32_write_adjustments".len, 0, -5, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 0), inserted);

        std.mem.writeInt(i32, row[0..4], -10, .little);
        std.mem.writeInt(i64, row[4..12], 900, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_i32_key(root.ptr, root.len, "i32_write_adjustments".ptr, "i32_write_adjustments".len, 0, -10, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 1), inserted);

        try std.testing.expectEqual(SA_DB_OK, sa_db_delete_i32_key(root.ptr, root.len, "i32_write_adjustments".ptr, "i32_write_adjustments".len, 0, 10, &info));
        try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_delete_i32_key(root.ptr, root.len, "i32_write_adjustments".ptr, "i32_write_adjustments".len, 0, 10, &info));

        var tx_handle: ?*anyopaque = null;
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "i32_write_adjustments".ptr, "i32_write_adjustments".len, &tx_handle));
        std.mem.writeInt(i32, row[0..4], 0, .little);
        std.mem.writeInt(i64, row[4..12], 2500, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_i32_key(tx_handle, 0, 0, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 0), inserted);

        std.mem.writeInt(i32, row[0..4], -10, .little);
        std.mem.writeInt(i64, row[4..12], 1000, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_update_row_i32_key(tx_handle, 0, -10, &row, row.len, &info));

        std.mem.writeInt(i32, row[0..4], 20, .little);
        std.mem.writeInt(i64, row[4..12], 2000, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_i32_key(tx_handle, 0, 20, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 1), inserted);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_delete_i32_key(tx_handle, 0, -5, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
        try std.testing.expectEqual(@as(u64, 3), info.row_count);

        tx_handle = null;
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "i32_write_adjustments".ptr, "i32_write_adjustments".len, &tx_handle));
        std.mem.writeInt(i32, row[0..4], 99, .little);
        std.mem.writeInt(i64, row[4..12], 9900, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_i32_key(tx_handle, 0, 99, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_rollback(tx_handle));

        var handle: ?*anyopaque = null;
        try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "i32_write_adjustments".ptr, "i32_write_adjustments".len, &handle));
        var found: u64 = 0;
        var row_index: u64 = 0;
        try std.testing.expectEqual(SA_DB_OK, sa_db_find_i32_handle(handle, 0, 0, &found, &row_index));
        try std.testing.expectEqual(@as(u64, 1), found);
        var total: i64 = 0;
        try std.testing.expectEqual(SA_DB_OK, sa_db_get_i64_handle(handle, 1, row_index, &total));
        try std.testing.expectEqual(@as(i64, 2500), total);
        try std.testing.expectEqual(SA_DB_OK, sa_db_find_i32_handle(handle, 0, 99, &found, &row_index));
        try std.testing.expectEqual(@as(u64, 0), found);
        try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
        try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, "i32_write_adjustments".ptr, "i32_write_adjustments".len, &info));
    }
}

test "db SA ABI writes rows by u8 i8 u16 and i16 keys" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    var info: SaDbTableInfo = undefined;

    {
        const schema_source =
            \\#def MAX_ROWS = 8
            \\#def COL_CHANNEL_ID_STRIDE = 1 // u8
            \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64 decimal(2)
        ;
        try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "u8_write_channels.sadb-schema".ptr, "u8_write_channels.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

        var channel_ids = [_]u8{ 1, 2, 3 };
        var totals = [_]i64{ 1000, 2000, 3000 };
        const cols = [_]SaDbColumnInput{
            .{ .data = @ptrCast(&channel_ids), .len = @sizeOf(@TypeOf(channel_ids)) },
            .{ .data = @ptrCast(&totals), .len = @sizeOf(@TypeOf(totals)) },
        };
        try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "u8_write_channels".ptr, "u8_write_channels".len, channel_ids.len, &cols, cols.len, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_create_u8_index(root.ptr, root.len, "u8_write_channels".ptr, "u8_write_channels".len, 0, 1, &info));

        var row: [9]u8 = undefined;
        row[0] = 2;
        std.mem.writeInt(i64, row[1..9], 2200, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_update_row_u8_key(root.ptr, root.len, "u8_write_channels".ptr, "u8_write_channels".len, 0, 2, &row, row.len, &info));

        var inserted: u64 = 99;
        row[0] = 4;
        std.mem.writeInt(i64, row[1..9], 4000, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_u8_key(root.ptr, root.len, "u8_write_channels".ptr, "u8_write_channels".len, 0, 4, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 1), inserted);
        try std.testing.expectEqual(SA_DB_OK, sa_db_delete_u8_key(root.ptr, root.len, "u8_write_channels".ptr, "u8_write_channels".len, 0, 3, &info));

        var tx_handle: ?*anyopaque = null;
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "u8_write_channels".ptr, "u8_write_channels".len, &tx_handle));
        row[0] = 2;
        std.mem.writeInt(i64, row[1..9], 2500, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u8_key(tx_handle, 0, 2, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 0), inserted);
        row[0] = 4;
        std.mem.writeInt(i64, row[1..9], 4400, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_update_row_u8_key(tx_handle, 0, 4, &row, row.len, &info));
        row[0] = 5;
        std.mem.writeInt(i64, row[1..9], 5000, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u8_key(tx_handle, 0, 5, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_delete_u8_key(tx_handle, 0, 1, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
        try std.testing.expectEqual(@as(u64, 3), info.row_count);

        var handle: ?*anyopaque = null;
        try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "u8_write_channels".ptr, "u8_write_channels".len, &handle));
        var found: u64 = 0;
        var row_index: u64 = 0;
        try std.testing.expectEqual(SA_DB_OK, sa_db_find_u8_handle(handle, 0, 2, &found, &row_index));
        try std.testing.expectEqual(@as(u64, 1), found);
        var total: i64 = 0;
        try std.testing.expectEqual(SA_DB_OK, sa_db_get_i64_handle(handle, 1, row_index, &total));
        try std.testing.expectEqual(@as(i64, 2500), total);
        try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
    }

    {
        const schema_source =
            \\#def MAX_ROWS = 8
            \\#def COL_ADJUSTMENT_STRIDE = 1 // i8
            \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64 decimal(2)
        ;
        try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "i8_write_adjustments.sadb-schema".ptr, "i8_write_adjustments.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

        var adjustments = [_]i8{ -5, 0, 10 };
        var totals = [_]i64{ 1000, 2000, 3000 };
        const cols = [_]SaDbColumnInput{
            .{ .data = @ptrCast(&adjustments), .len = @sizeOf(@TypeOf(adjustments)) },
            .{ .data = @ptrCast(&totals), .len = @sizeOf(@TypeOf(totals)) },
        };
        try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "i8_write_adjustments".ptr, "i8_write_adjustments".len, adjustments.len, &cols, cols.len, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_create_i8_index(root.ptr, root.len, "i8_write_adjustments".ptr, "i8_write_adjustments".len, 0, 1, &info));

        var row: [9]u8 = undefined;
        row[0] = @bitCast(@as(i8, 0));
        std.mem.writeInt(i64, row[1..9], 2100, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_update_row_i8_key(root.ptr, root.len, "i8_write_adjustments".ptr, "i8_write_adjustments".len, 0, 0, &row, row.len, &info));

        var inserted: u64 = 99;
        row[0] = @bitCast(@as(i8, -10));
        std.mem.writeInt(i64, row[1..9], 900, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_i8_key(root.ptr, root.len, "i8_write_adjustments".ptr, "i8_write_adjustments".len, 0, -10, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 1), inserted);
        try std.testing.expectEqual(SA_DB_OK, sa_db_delete_i8_key(root.ptr, root.len, "i8_write_adjustments".ptr, "i8_write_adjustments".len, 0, 10, &info));

        var tx_handle: ?*anyopaque = null;
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "i8_write_adjustments".ptr, "i8_write_adjustments".len, &tx_handle));
        row[0] = @bitCast(@as(i8, 0));
        std.mem.writeInt(i64, row[1..9], 2500, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_i8_key(tx_handle, 0, 0, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 0), inserted);
        row[0] = @bitCast(@as(i8, -10));
        std.mem.writeInt(i64, row[1..9], 1000, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_update_row_i8_key(tx_handle, 0, -10, &row, row.len, &info));
        row[0] = @bitCast(@as(i8, 20));
        std.mem.writeInt(i64, row[1..9], 2000, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_i8_key(tx_handle, 0, 20, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_delete_i8_key(tx_handle, 0, -5, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
        try std.testing.expectEqual(@as(u64, 3), info.row_count);

        var handle: ?*anyopaque = null;
        try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "i8_write_adjustments".ptr, "i8_write_adjustments".len, &handle));
        var found: u64 = 0;
        var row_index: u64 = 0;
        try std.testing.expectEqual(SA_DB_OK, sa_db_find_i8_handle(handle, 0, -10, &found, &row_index));
        try std.testing.expectEqual(@as(u64, 1), found);
        var total: i64 = 0;
        try std.testing.expectEqual(SA_DB_OK, sa_db_get_i64_handle(handle, 1, row_index, &total));
        try std.testing.expectEqual(@as(i64, 1000), total);
        try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
    }

    {
        const schema_source =
            \\#def MAX_ROWS = 8
            \\#def COL_CHANNEL_ID_STRIDE = 2 // u16
            \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64 decimal(2)
        ;
        try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "u16_write_channels.sadb-schema".ptr, "u16_write_channels.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

        var channel_ids = [_]u16{ 100, 200, 300 };
        var totals = [_]i64{ 1000, 2000, 3000 };
        const cols = [_]SaDbColumnInput{
            .{ .data = @ptrCast(&channel_ids), .len = @sizeOf(@TypeOf(channel_ids)) },
            .{ .data = @ptrCast(&totals), .len = @sizeOf(@TypeOf(totals)) },
        };
        try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "u16_write_channels".ptr, "u16_write_channels".len, channel_ids.len, &cols, cols.len, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_create_u16_index(root.ptr, root.len, "u16_write_channels".ptr, "u16_write_channels".len, 0, 1, &info));

        var row: [10]u8 = undefined;
        std.mem.writeInt(u16, row[0..2], 200, .little);
        std.mem.writeInt(i64, row[2..10], 2200, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_update_row_u16_key(root.ptr, root.len, "u16_write_channels".ptr, "u16_write_channels".len, 0, 200, &row, row.len, &info));

        var inserted: u64 = 99;
        std.mem.writeInt(u16, row[0..2], 400, .little);
        std.mem.writeInt(i64, row[2..10], 4000, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_u16_key(root.ptr, root.len, "u16_write_channels".ptr, "u16_write_channels".len, 0, 400, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 1), inserted);
        try std.testing.expectEqual(SA_DB_OK, sa_db_delete_u16_key(root.ptr, root.len, "u16_write_channels".ptr, "u16_write_channels".len, 0, 300, &info));

        var tx_handle: ?*anyopaque = null;
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "u16_write_channels".ptr, "u16_write_channels".len, &tx_handle));
        std.mem.writeInt(u16, row[0..2], 200, .little);
        std.mem.writeInt(i64, row[2..10], 2500, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u16_key(tx_handle, 0, 200, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 0), inserted);
        std.mem.writeInt(u16, row[0..2], 400, .little);
        std.mem.writeInt(i64, row[2..10], 4400, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_update_row_u16_key(tx_handle, 0, 400, &row, row.len, &info));
        std.mem.writeInt(u16, row[0..2], 500, .little);
        std.mem.writeInt(i64, row[2..10], 5000, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u16_key(tx_handle, 0, 500, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_delete_u16_key(tx_handle, 0, 100, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
        try std.testing.expectEqual(@as(u64, 3), info.row_count);

        var handle: ?*anyopaque = null;
        try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "u16_write_channels".ptr, "u16_write_channels".len, &handle));
        var found: u64 = 0;
        var row_index: u64 = 0;
        try std.testing.expectEqual(SA_DB_OK, sa_db_find_u16_handle(handle, 0, 500, &found, &row_index));
        try std.testing.expectEqual(@as(u64, 1), found);
        var total: i64 = 0;
        try std.testing.expectEqual(SA_DB_OK, sa_db_get_i64_handle(handle, 1, row_index, &total));
        try std.testing.expectEqual(@as(i64, 5000), total);
        try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
    }

    {
        const schema_source =
            \\#def MAX_ROWS = 8
            \\#def COL_ADJUSTMENT_STRIDE = 2 // i16
            \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64 decimal(2)
        ;
        try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "i16_write_adjustments.sadb-schema".ptr, "i16_write_adjustments.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

        var adjustments = [_]i16{ -100, 0, 100 };
        var totals = [_]i64{ 1000, 2000, 3000 };
        const cols = [_]SaDbColumnInput{
            .{ .data = @ptrCast(&adjustments), .len = @sizeOf(@TypeOf(adjustments)) },
            .{ .data = @ptrCast(&totals), .len = @sizeOf(@TypeOf(totals)) },
        };
        try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "i16_write_adjustments".ptr, "i16_write_adjustments".len, adjustments.len, &cols, cols.len, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_create_i16_index(root.ptr, root.len, "i16_write_adjustments".ptr, "i16_write_adjustments".len, 0, 1, &info));

        var row: [10]u8 = undefined;
        std.mem.writeInt(i16, row[0..2], 0, .little);
        std.mem.writeInt(i64, row[2..10], 2100, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_update_row_i16_key(root.ptr, root.len, "i16_write_adjustments".ptr, "i16_write_adjustments".len, 0, 0, &row, row.len, &info));

        var inserted: u64 = 99;
        std.mem.writeInt(i16, row[0..2], -200, .little);
        std.mem.writeInt(i64, row[2..10], 900, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_i16_key(root.ptr, root.len, "i16_write_adjustments".ptr, "i16_write_adjustments".len, 0, -200, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 1), inserted);
        try std.testing.expectEqual(SA_DB_OK, sa_db_delete_i16_key(root.ptr, root.len, "i16_write_adjustments".ptr, "i16_write_adjustments".len, 0, 100, &info));

        var tx_handle: ?*anyopaque = null;
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "i16_write_adjustments".ptr, "i16_write_adjustments".len, &tx_handle));
        std.mem.writeInt(i16, row[0..2], 0, .little);
        std.mem.writeInt(i64, row[2..10], 2500, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_i16_key(tx_handle, 0, 0, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(@as(u64, 0), inserted);
        std.mem.writeInt(i16, row[0..2], -200, .little);
        std.mem.writeInt(i64, row[2..10], 1000, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_update_row_i16_key(tx_handle, 0, -200, &row, row.len, &info));
        std.mem.writeInt(i16, row[0..2], 200, .little);
        std.mem.writeInt(i64, row[2..10], 2000, .little);
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_i16_key(tx_handle, 0, 200, &row, row.len, &inserted, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_delete_i16_key(tx_handle, 0, -100, &info));
        try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
        try std.testing.expectEqual(@as(u64, 3), info.row_count);

        var handle: ?*anyopaque = null;
        try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "i16_write_adjustments".ptr, "i16_write_adjustments".len, &handle));
        var found: u64 = 0;
        var row_index: u64 = 0;
        try std.testing.expectEqual(SA_DB_OK, sa_db_find_i16_handle(handle, 0, -200, &found, &row_index));
        try std.testing.expectEqual(@as(u64, 1), found);
        var total: i64 = 0;
        try std.testing.expectEqual(SA_DB_OK, sa_db_get_i64_handle(handle, 1, row_index, &total));
        try std.testing.expectEqual(@as(i64, 1000), total);
        try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
    }
}

test "db SA ABI gets full rows by typed unique keys" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    var info: SaDbTableInfo = undefined;
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_I64_KEY_STRIDE = 8 // i64
        \\#def COL_U32_KEY_STRIDE = 4 // u32
        \\#def COL_I32_KEY_STRIDE = 4 // i32
        \\#def COL_U8_KEY_STRIDE = 1 // u8
        \\#def COL_I8_KEY_STRIDE = 1 // i8
        \\#def COL_U16_KEY_STRIDE = 2 // u16
        \\#def COL_I16_KEY_STRIDE = 2 // i16
        \\#def COL_TOTAL_STRIDE = 8 // i64 decimal(2)
    ;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "typed_key_get_rows.sadb-schema".ptr, "typed_key_get_rows.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

    var i64_keys = [_]i64{ -10, 0, 10 };
    var u32_keys = [_]u32{ 100, 200, 300 };
    var i32_keys = [_]i32{ -3, 0, 3 };
    var u8_keys = [_]u8{ 1, 2, 3 };
    var i8_keys = [_]i8{ -1, 0, 1 };
    var u16_keys = [_]u16{ 1000, 2000, 3000 };
    var i16_keys = [_]i16{ -100, 0, 100 };
    var totals = [_]i64{ 111, 222, 333 };
    const cols = [_]SaDbColumnInput{
        .{ .data = @ptrCast(&i64_keys), .len = @sizeOf(@TypeOf(i64_keys)) },
        .{ .data = @ptrCast(&u32_keys), .len = @sizeOf(@TypeOf(u32_keys)) },
        .{ .data = @ptrCast(&i32_keys), .len = @sizeOf(@TypeOf(i32_keys)) },
        .{ .data = @ptrCast(&u8_keys), .len = @sizeOf(@TypeOf(u8_keys)) },
        .{ .data = @ptrCast(&i8_keys), .len = @sizeOf(@TypeOf(i8_keys)) },
        .{ .data = @ptrCast(&u16_keys), .len = @sizeOf(@TypeOf(u16_keys)) },
        .{ .data = @ptrCast(&i16_keys), .len = @sizeOf(@TypeOf(i16_keys)) },
        .{ .data = @ptrCast(&totals), .len = @sizeOf(@TypeOf(totals)) },
    };
    try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "typed_key_get_rows".ptr, "typed_key_get_rows".len, i64_keys.len, &cols, cols.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_i64_index(root.ptr, root.len, "typed_key_get_rows".ptr, "typed_key_get_rows".len, 0, 1, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_u32_index(root.ptr, root.len, "typed_key_get_rows".ptr, "typed_key_get_rows".len, 1, 1, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_i32_index(root.ptr, root.len, "typed_key_get_rows".ptr, "typed_key_get_rows".len, 2, 1, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_u8_index(root.ptr, root.len, "typed_key_get_rows".ptr, "typed_key_get_rows".len, 3, 1, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_i8_index(root.ptr, root.len, "typed_key_get_rows".ptr, "typed_key_get_rows".len, 4, 1, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_u16_index(root.ptr, root.len, "typed_key_get_rows".ptr, "typed_key_get_rows".len, 5, 1, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_i16_index(root.ptr, root.len, "typed_key_get_rows".ptr, "typed_key_get_rows".len, 6, 1, &info));

    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "typed_key_get_rows".ptr, "typed_key_get_rows".len, &handle));
    defer std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle)) catch unreachable;

    var row: [30]u8 = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_i64_key_handle(handle, 0, 0, &row, row.len));
    try std.testing.expectEqual(@as(i64, 222), std.mem.readInt(i64, row[22..30], .little));
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_u32_key_handle(handle, 1, 300, &row, row.len));
    try std.testing.expectEqual(@as(i64, 333), std.mem.readInt(i64, row[22..30], .little));
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_i32_key_handle(handle, 2, -3, &row, row.len));
    try std.testing.expectEqual(@as(i64, 111), std.mem.readInt(i64, row[22..30], .little));
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_u8_key_handle(handle, 3, 2, &row, row.len));
    try std.testing.expectEqual(@as(i64, 222), std.mem.readInt(i64, row[22..30], .little));
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_i8_key_handle(handle, 4, 1, &row, row.len));
    try std.testing.expectEqual(@as(i64, 333), std.mem.readInt(i64, row[22..30], .little));
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_u16_key_handle(handle, 5, 1000, &row, row.len));
    try std.testing.expectEqual(@as(i64, 111), std.mem.readInt(i64, row[22..30], .little));
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_i16_key_handle(handle, 6, 0, &row, row.len));
    try std.testing.expectEqual(@as(i64, 222), std.mem.readInt(i64, row[22..30], .little));
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_get_row_i64_key_handle(handle, 0, 99, &row, row.len));
    var short_row: [29]u8 = undefined;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_get_row_u32_key_handle(handle, 1, 200, &short_row, short_row.len));
}

test "db SA ABI gets rows by unique blob eq key" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    const table_name = "blob_key_rows_abi";
    const store_name = "codes";
    const code_a = "CUST-001";
    const code_b = "CUST-002";
    const missing_code = "CUST-999";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_CODE_STRIDE = 8 // blob_handle
        \\#def COL_POINTS_STRIDE = 8 // u64
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "blob_key_rows_abi.sadb-schema".ptr, "blob_key_rows_abi.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

    var code_a_id: u64 = 0;
    var code_b_id: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_blob_put(root.ptr, root.len, table_name.ptr, table_name.len, store_name.ptr, store_name.len, code_a.ptr, code_a.len, &code_a_id, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_blob_put(root.ptr, root.len, table_name.ptr, table_name.len, store_name.ptr, store_name.len, code_b.ptr, code_b.len, &code_b_id, &info));

    var row: [24]u8 = undefined;
    std.mem.writeInt(u64, row[0..8], 1, .little);
    std.mem.writeInt(u64, row[8..16], code_a_id, .little);
    std.mem.writeInt(u64, row[16..24], 100, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_insert_row(root.ptr, root.len, table_name.ptr, table_name.len, &row, row.len, &info));
    std.mem.writeInt(u64, row[0..8], 2, .little);
    std.mem.writeInt(u64, row[8..16], code_b_id, .little);
    std.mem.writeInt(u64, row[16..24], 200, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_insert_row(root.ptr, root.len, table_name.ptr, table_name.len, &row, row.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_blob_eq_index(root.ptr, root.len, table_name.ptr, table_name.len, 1, store_name.ptr, store_name.len, 1, &info));

    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, table_name.ptr, table_name.len, &handle));
    defer std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle)) catch unreachable;

    var fetched_row: [24]u8 = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_blob_eq_key_handle(handle, 1, store_name.ptr, store_name.len, code_b.ptr, code_b.len, &fetched_row, fetched_row.len));
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, fetched_row[0..8], .little));
    try std.testing.expectEqual(code_b_id, std.mem.readInt(u64, fetched_row[8..16], .little));
    try std.testing.expectEqual(@as(u64, 200), std.mem.readInt(u64, fetched_row[16..24], .little));
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_get_row_blob_eq_key_handle(handle, 1, store_name.ptr, store_name.len, missing_code.ptr, missing_code.len, &fetched_row, fetched_row.len));
    var short_row: [23]u8 = undefined;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_get_row_blob_eq_key_handle(handle, 1, store_name.ptr, store_name.len, code_b.ptr, code_b.len, &short_row, short_row.len));
}

test "db SA ABI writes rows by unique blob eq keys" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    const table_name = "blob_key_write_abi";
    const store_name = "codes";
    const code_a = "CUST-001";
    const code_b = "CUST-002";
    const code_c = "CUST-003";
    const code_d = "CUST-004";
    const code_e = "CUST-005";
    const code_f = "CUST-006";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_CODE_STRIDE = 8 // blob_handle
        \\#def COL_POINTS_STRIDE = 8 // u64
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "blob_key_write_abi.sadb-schema".ptr, "blob_key_write_abi.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

    var code_a_id: u64 = 0;
    var code_b_id: u64 = 0;
    var code_c_id: u64 = 0;
    var code_d_id: u64 = 0;
    var code_e_id: u64 = 0;
    var code_f_id: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_blob_put(root.ptr, root.len, table_name.ptr, table_name.len, store_name.ptr, store_name.len, code_a.ptr, code_a.len, &code_a_id, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_blob_put(root.ptr, root.len, table_name.ptr, table_name.len, store_name.ptr, store_name.len, code_b.ptr, code_b.len, &code_b_id, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_blob_put(root.ptr, root.len, table_name.ptr, table_name.len, store_name.ptr, store_name.len, code_c.ptr, code_c.len, &code_c_id, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_blob_put(root.ptr, root.len, table_name.ptr, table_name.len, store_name.ptr, store_name.len, code_e.ptr, code_e.len, &code_e_id, &info));

    var row: [24]u8 = undefined;
    std.mem.writeInt(u64, row[0..8], 1, .little);
    std.mem.writeInt(u64, row[8..16], code_a_id, .little);
    std.mem.writeInt(u64, row[16..24], 100, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_insert_row(root.ptr, root.len, table_name.ptr, table_name.len, &row, row.len, &info));
    std.mem.writeInt(u64, row[0..8], 2, .little);
    std.mem.writeInt(u64, row[8..16], code_b_id, .little);
    std.mem.writeInt(u64, row[16..24], 200, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_insert_row(root.ptr, root.len, table_name.ptr, table_name.len, &row, row.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_blob_eq_index(root.ptr, root.len, table_name.ptr, table_name.len, 1, store_name.ptr, store_name.len, 1, &info));

    std.mem.writeInt(u64, row[0..8], 2, .little);
    std.mem.writeInt(u64, row[8..16], code_b_id, .little);
    std.mem.writeInt(u64, row[16..24], 250, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_update_row_blob_eq_key(root.ptr, root.len, table_name.ptr, table_name.len, 1, store_name.ptr, store_name.len, code_b.ptr, code_b.len, &row, row.len, &info));

    std.mem.writeInt(u64, row[0..8], 3, .little);
    std.mem.writeInt(u64, row[8..16], code_c_id, .little);
    std.mem.writeInt(u64, row[16..24], 300, .little);
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_update_row_blob_eq_key(root.ptr, root.len, table_name.ptr, table_name.len, 1, store_name.ptr, store_name.len, code_c.ptr, code_c.len, &row, row.len, &info));

    std.mem.writeInt(u64, row[0..8], 2, .little);
    std.mem.writeInt(u64, row[8..16], code_a_id, .little);
    std.mem.writeInt(u64, row[16..24], 251, .little);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_update_row_blob_eq_key(root.ptr, root.len, table_name.ptr, table_name.len, 1, store_name.ptr, store_name.len, code_b.ptr, code_b.len, &row, row.len, &info));

    var inserted: u64 = 99;
    std.mem.writeInt(u64, row[0..8], 2, .little);
    std.mem.writeInt(u64, row[8..16], code_b_id, .little);
    std.mem.writeInt(u64, row[16..24], 260, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_blob_eq_key(root.ptr, root.len, table_name.ptr, table_name.len, 1, store_name.ptr, store_name.len, code_b.ptr, code_b.len, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 0), inserted);

    std.mem.writeInt(u64, row[0..8], 3, .little);
    std.mem.writeInt(u64, row[8..16], code_c_id, .little);
    std.mem.writeInt(u64, row[16..24], 300, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_blob_eq_key(root.ptr, root.len, table_name.ptr, table_name.len, 1, store_name.ptr, store_name.len, code_c.ptr, code_c.len, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 1), inserted);
    try std.testing.expectEqual(@as(u64, 3), info.row_count);

    try std.testing.expectEqual(SA_DB_OK, sa_db_delete_blob_eq_key(root.ptr, root.len, table_name.ptr, table_name.len, 1, store_name.ptr, store_name.len, code_a.ptr, code_a.len, &info));
    try std.testing.expectEqual(@as(u64, 2), info.row_count);
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_delete_blob_eq_key(root.ptr, root.len, table_name.ptr, table_name.len, 1, store_name.ptr, store_name.len, code_a.ptr, code_a.len, &info));

    var tx_handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, table_name.ptr, table_name.len, &tx_handle));
    std.mem.writeInt(u64, row[0..8], 2, .little);
    std.mem.writeInt(u64, row[8..16], code_b_id, .little);
    std.mem.writeInt(u64, row[16..24], 270, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_blob_eq_key(tx_handle, 1, store_name.ptr, store_name.len, code_b.ptr, code_b.len, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 0), inserted);
    std.mem.writeInt(u64, row[0..8], 5, .little);
    std.mem.writeInt(u64, row[8..16], code_e_id, .little);
    std.mem.writeInt(u64, row[16..24], 500, .little);
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_tx_update_row_blob_eq_key(tx_handle, 1, store_name.ptr, store_name.len, code_e.ptr, code_e.len, &row, row.len, &info));
    std.mem.writeInt(u64, row[0..8], 3, .little);
    std.mem.writeInt(u64, row[8..16], code_c_id, .little);
    std.mem.writeInt(u64, row[16..24], 330, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_update_row_blob_eq_key(tx_handle, 1, store_name.ptr, store_name.len, code_c.ptr, code_c.len, &row, row.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_blob_put(tx_handle, store_name.ptr, store_name.len, code_d.ptr, code_d.len, &code_d_id, &info));
    std.mem.writeInt(u64, row[0..8], 4, .little);
    std.mem.writeInt(u64, row[8..16], code_d_id, .little);
    std.mem.writeInt(u64, row[16..24], 400, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_blob_eq_key(tx_handle, 1, store_name.ptr, store_name.len, code_d.ptr, code_d.len, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 1), inserted);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_delete_blob_eq_key(tx_handle, 1, store_name.ptr, store_name.len, code_b.ptr, code_b.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
    try std.testing.expectEqual(@as(u64, 2), info.row_count);

    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, table_name.ptr, table_name.len, &tx_handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_blob_put(tx_handle, store_name.ptr, store_name.len, code_f.ptr, code_f.len, &code_f_id, &info));
    std.mem.writeInt(u64, row[0..8], 6, .little);
    std.mem.writeInt(u64, row[8..16], code_f_id, .little);
    std.mem.writeInt(u64, row[16..24], 600, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_blob_eq_key(tx_handle, 1, store_name.ptr, store_name.len, code_f.ptr, code_f.len, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_rollback(tx_handle));

    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, table_name.ptr, table_name.len, &handle));
    var fetched_row: [24]u8 = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_blob_eq_key_handle(handle, 1, store_name.ptr, store_name.len, code_c.ptr, code_c.len, &fetched_row, fetched_row.len));
    try std.testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, fetched_row[0..8], .little));
    try std.testing.expectEqual(code_c_id, std.mem.readInt(u64, fetched_row[8..16], .little));
    try std.testing.expectEqual(@as(u64, 330), std.mem.readInt(u64, fetched_row[16..24], .little));
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_blob_eq_key_handle(handle, 1, store_name.ptr, store_name.len, code_d.ptr, code_d.len, &fetched_row, fetched_row.len));
    try std.testing.expectEqual(@as(u64, 4), std.mem.readInt(u64, fetched_row[0..8], .little));
    try std.testing.expectEqual(code_d_id, std.mem.readInt(u64, fetched_row[8..16], .little));
    try std.testing.expectEqual(@as(u64, 400), std.mem.readInt(u64, fetched_row[16..24], .little));
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_get_row_blob_eq_key_handle(handle, 1, store_name.ptr, store_name.len, code_a.ptr, code_a.len, &fetched_row, fetched_row.len));
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_get_row_blob_eq_key_handle(handle, 1, store_name.ptr, store_name.len, code_b.ptr, code_b.len, &fetched_row, fetched_row.len));
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_get_row_blob_eq_key_handle(handle, 1, store_name.ptr, store_name.len, code_f.ptr, code_f.len, &fetched_row, fetched_row.len));
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, table_name.ptr, table_name.len, &info));
}

test "db SA ABI writes rows by u64 pair keys" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_ORDER_ID_STRIDE = 8 // u64
        \\#def COL_LINE_NO_STRIDE = 8 // u64
        \\#def COL_QTY_STRIDE = 8 // u64
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "pair_write_lines.sadb-schema".ptr, "pair_write_lines.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

    var order_ids = [_]u64{ 10, 10, 11 };
    var line_nos = [_]u64{ 1, 2, 1 };
    var qtys = [_]u64{ 5, 7, 9 };
    const cols = [_]SaDbColumnInput{
        .{ .data = @ptrCast(&order_ids), .len = @sizeOf(@TypeOf(order_ids)) },
        .{ .data = @ptrCast(&line_nos), .len = @sizeOf(@TypeOf(line_nos)) },
        .{ .data = @ptrCast(&qtys), .len = @sizeOf(@TypeOf(qtys)) },
    };
    try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "pair_write_lines".ptr, "pair_write_lines".len, order_ids.len, &cols, cols.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_u64_pair_index(root.ptr, root.len, "pair_write_lines".ptr, "pair_write_lines".len, 0, 1, 1, &info));

    var row: [24]u8 = undefined;
    std.mem.writeInt(u64, row[0..8], 10, .little);
    std.mem.writeInt(u64, row[8..16], 2, .little);
    std.mem.writeInt(u64, row[16..24], 70, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_update_row_u64_pair_key(root.ptr, root.len, "pair_write_lines".ptr, "pair_write_lines".len, 0, 1, 10, 2, &row, row.len, &info));

    std.mem.writeInt(u64, row[0..8], 99, .little);
    std.mem.writeInt(u64, row[8..16], 1, .little);
    std.mem.writeInt(u64, row[16..24], 990, .little);
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_update_row_u64_pair_key(root.ptr, root.len, "pair_write_lines".ptr, "pair_write_lines".len, 0, 1, 99, 1, &row, row.len, &info));

    std.mem.writeInt(u64, row[0..8], 10, .little);
    std.mem.writeInt(u64, row[8..16], 3, .little);
    std.mem.writeInt(u64, row[16..24], 30, .little);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_update_row_u64_pair_key(root.ptr, root.len, "pair_write_lines".ptr, "pair_write_lines".len, 0, 1, 10, 2, &row, row.len, &info));

    var inserted: u64 = 99;
    std.mem.writeInt(u64, row[0..8], 10, .little);
    std.mem.writeInt(u64, row[8..16], 2, .little);
    std.mem.writeInt(u64, row[16..24], 71, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_u64_pair_key(root.ptr, root.len, "pair_write_lines".ptr, "pair_write_lines".len, 0, 1, 10, 2, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 0), inserted);

    std.mem.writeInt(u64, row[0..8], 10, .little);
    std.mem.writeInt(u64, row[8..16], 3, .little);
    std.mem.writeInt(u64, row[16..24], 11, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_u64_pair_key(root.ptr, root.len, "pair_write_lines".ptr, "pair_write_lines".len, 0, 1, 10, 3, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 1), inserted);
    try std.testing.expectEqual(@as(u64, 4), info.row_count);

    try std.testing.expectEqual(SA_DB_OK, sa_db_delete_u64_pair_key(root.ptr, root.len, "pair_write_lines".ptr, "pair_write_lines".len, 0, 1, 11, 1, &info));
    try std.testing.expectEqual(@as(u64, 3), info.row_count);
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_delete_u64_pair_key(root.ptr, root.len, "pair_write_lines".ptr, "pair_write_lines".len, 0, 1, 11, 1, &info));

    var tx_handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "pair_write_lines".ptr, "pair_write_lines".len, &tx_handle));
    std.mem.writeInt(u64, row[0..8], 10, .little);
    std.mem.writeInt(u64, row[8..16], 1, .little);
    std.mem.writeInt(u64, row[16..24], 50, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u64_pair_key(tx_handle, 0, 1, 10, 1, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 0), inserted);
    std.mem.writeInt(u64, row[0..8], 99, .little);
    std.mem.writeInt(u64, row[8..16], 1, .little);
    std.mem.writeInt(u64, row[16..24], 990, .little);
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_tx_update_row_u64_pair_key(tx_handle, 0, 1, 99, 1, &row, row.len, &info));
    std.mem.writeInt(u64, row[0..8], 10, .little);
    std.mem.writeInt(u64, row[8..16], 3, .little);
    std.mem.writeInt(u64, row[16..24], 13, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_update_row_u64_pair_key(tx_handle, 0, 1, 10, 3, &row, row.len, &info));
    std.mem.writeInt(u64, row[0..8], 12, .little);
    std.mem.writeInt(u64, row[8..16], 1, .little);
    std.mem.writeInt(u64, row[16..24], 21, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u64_pair_key(tx_handle, 0, 1, 12, 1, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 1), inserted);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_delete_u64_pair_key(tx_handle, 0, 1, 10, 2, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
    try std.testing.expectEqual(@as(u64, 3), info.row_count);

    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "pair_write_lines".ptr, "pair_write_lines".len, &tx_handle));
    std.mem.writeInt(u64, row[0..8], 99, .little);
    std.mem.writeInt(u64, row[8..16], 1, .little);
    std.mem.writeInt(u64, row[16..24], 990, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u64_pair_key(tx_handle, 0, 1, 99, 1, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_rollback(tx_handle));

    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "pair_write_lines".ptr, "pair_write_lines".len, &handle));
    var found: u64 = 0;
    var row_index: u64 = 0;
    var qty: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_pair_handle(handle, 0, 1, 10, 1, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_u64_handle(handle, 2, row_index, &qty));
    try std.testing.expectEqual(@as(u64, 50), qty);
    var fetched_row: [24]u8 = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_u64_pair_key_handle(handle, 0, 1, 10, 1, &fetched_row, fetched_row.len));
    try std.testing.expectEqual(@as(u64, 10), std.mem.readInt(u64, fetched_row[0..8], .little));
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, fetched_row[8..16], .little));
    try std.testing.expectEqual(@as(u64, 50), std.mem.readInt(u64, fetched_row[16..24], .little));
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_get_row_u64_pair_key_handle(handle, 0, 1, 99, 1, &fetched_row, fetched_row.len));
    var short_row: [23]u8 = undefined;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_get_row_u64_pair_key_handle(handle, 0, 1, 10, 1, &short_row, short_row.len));
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_pair_handle(handle, 0, 1, 10, 2, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 0), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_pair_handle(handle, 0, 1, 10, 3, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_u64_handle(handle, 2, row_index, &qty));
    try std.testing.expectEqual(@as(u64, 13), qty);
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_pair_handle(handle, 0, 1, 12, 1, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_u64_handle(handle, 2, row_index, &qty));
    try std.testing.expectEqual(@as(u64, 21), qty);
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_pair_handle(handle, 0, 1, 99, 1, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 0), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, "pair_write_lines".ptr, "pair_write_lines".len, &info));
}

test "db SA ABI creates and queries u64 i64 pair indexes" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_CUSTOMER_ID_STRIDE = 8 // u64
        \\#def COL_ORDER_DAY_STRIDE = 8 // i64
        \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "customer_orders.sadb-schema".ptr, "customer_orders.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

    var customer_ids = [_]u64{ 7, 7, 7, 8, 7 };
    var order_days = [_]i64{ -5, 0, 10, -3, 20 };
    var totals = [_]i64{ 1000, 2000, 3000, 4000, 5000 };
    const cols = [_]SaDbColumnInput{
        .{ .data = @ptrCast(&customer_ids), .len = @sizeOf(@TypeOf(customer_ids)) },
        .{ .data = @ptrCast(&order_days), .len = @sizeOf(@TypeOf(order_days)) },
        .{ .data = @ptrCast(&totals), .len = @sizeOf(@TypeOf(totals)) },
    };
    try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "customer_orders".ptr, "customer_orders".len, customer_ids.len, &cols, cols.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_u64_i64_pair_index(root.ptr, root.len, "customer_orders".ptr, "customer_orders".len, 0, 1, 1, &info));
    try std.testing.expectEqual(@as(u64, 2), info.epoch);

    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "customer_orders".ptr, "customer_orders".len, &handle));
    var found: u64 = 0;
    var row_index: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_i64_pair_handle(handle, 0, 1, 7, -5, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(@as(u64, 0), row_index);
    var total_cents: i64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_i64_handle(handle, 2, row_index, &total_cents));
    try std.testing.expectEqual(@as(i64, 1000), total_cents);
    var fetched_row: [24]u8 = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_u64_i64_pair_key_handle(handle, 0, 1, 7, -5, &fetched_row, fetched_row.len));
    try std.testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, fetched_row[0..8], .little));
    try std.testing.expectEqual(@as(i64, -5), std.mem.readInt(i64, fetched_row[8..16], .little));
    try std.testing.expectEqual(@as(i64, 1000), std.mem.readInt(i64, fetched_row[16..24], .little));
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_get_row_u64_i64_pair_key_handle(handle, 0, 1, 7, -99, &fetched_row, fetched_row.len));
    var short_row: [23]u8 = undefined;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_get_row_u64_i64_pair_key_handle(handle, 0, 1, 7, -5, &short_row, short_row.len));

    var rows = [_]u64{ 99, 99, 99, 99 };
    var written: u64 = 0;
    var total: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_range_u64_i64_pair_handle(handle, 0, 1, 7, -5, 10, 0, 4, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 3), written);
    try std.testing.expectEqual(@as(u64, 0), rows[0]);
    try std.testing.expectEqual(@as(u64, 1), rows[1]);
    try std.testing.expectEqual(@as(u64, 2), rows[2]);

    @memset(rows[0..], 99);
    try std.testing.expectEqual(SA_DB_OK, sa_db_range_u64_date_pair_handle(handle, 0, 1, 7, 1969, 12, 27, 1970, 1, 11, 0, 4, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 3), written);
    try std.testing.expectEqual(@as(u64, 0), rows[0]);
    try std.testing.expectEqual(@as(u64, 1), rows[1]);
    try std.testing.expectEqual(@as(u64, 2), rows[2]);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_range_u64_date_pair_handle(handle, 0, 1, 7, 2023, 2, 29, 2024, 2, 29, 0, 4, &rows, rows.len, &written, &total));

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_u64_i64_pair_key1_handle(handle, 0, 1, 7, 1, 2, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 4), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 1), rows[0]);
    try std.testing.expectEqual(@as(u64, 2), rows[1]);
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));

    try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, "customer_orders".ptr, "customer_orders".len, &info));
}

test "db SA ABI writes rows by u64 i64 pair keys" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_CUSTOMER_ID_STRIDE = 8 // u64
        \\#def COL_ORDER_DAY_STRIDE = 8 // i64
        \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "pair_i64_write_orders.sadb-schema".ptr, "pair_i64_write_orders.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

    var customer_ids = [_]u64{ 7, 7, 8 };
    var order_days = [_]i64{ -5, 0, -3 };
    var totals = [_]i64{ 1000, 2000, 4000 };
    const cols = [_]SaDbColumnInput{
        .{ .data = @ptrCast(&customer_ids), .len = @sizeOf(@TypeOf(customer_ids)) },
        .{ .data = @ptrCast(&order_days), .len = @sizeOf(@TypeOf(order_days)) },
        .{ .data = @ptrCast(&totals), .len = @sizeOf(@TypeOf(totals)) },
    };
    try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "pair_i64_write_orders".ptr, "pair_i64_write_orders".len, customer_ids.len, &cols, cols.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_u64_i64_pair_index(root.ptr, root.len, "pair_i64_write_orders".ptr, "pair_i64_write_orders".len, 0, 1, 1, &info));

    var row: [24]u8 = undefined;
    std.mem.writeInt(u64, row[0..8], 7, .little);
    std.mem.writeInt(i64, row[8..16], -5, .little);
    std.mem.writeInt(i64, row[16..24], 1100, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_update_row_u64_i64_pair_key(root.ptr, root.len, "pair_i64_write_orders".ptr, "pair_i64_write_orders".len, 0, 1, 7, -5, &row, row.len, &info));

    std.mem.writeInt(u64, row[0..8], 7, .little);
    std.mem.writeInt(i64, row[8..16], -10, .little);
    std.mem.writeInt(i64, row[16..24], 900, .little);
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_update_row_u64_i64_pair_key(root.ptr, root.len, "pair_i64_write_orders".ptr, "pair_i64_write_orders".len, 0, 1, 7, -10, &row, row.len, &info));

    std.mem.writeInt(u64, row[0..8], 7, .little);
    std.mem.writeInt(i64, row[8..16], 1, .little);
    std.mem.writeInt(i64, row[16..24], 2100, .little);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_update_row_u64_i64_pair_key(root.ptr, root.len, "pair_i64_write_orders".ptr, "pair_i64_write_orders".len, 0, 1, 7, 0, &row, row.len, &info));

    var inserted: u64 = 99;
    std.mem.writeInt(u64, row[0..8], 7, .little);
    std.mem.writeInt(i64, row[8..16], -5, .little);
    std.mem.writeInt(i64, row[16..24], 1200, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_u64_i64_pair_key(root.ptr, root.len, "pair_i64_write_orders".ptr, "pair_i64_write_orders".len, 0, 1, 7, -5, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 0), inserted);

    std.mem.writeInt(u64, row[0..8], 7, .little);
    std.mem.writeInt(i64, row[8..16], 10, .little);
    std.mem.writeInt(i64, row[16..24], 3000, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_upsert_row_u64_i64_pair_key(root.ptr, root.len, "pair_i64_write_orders".ptr, "pair_i64_write_orders".len, 0, 1, 7, 10, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 1), inserted);
    try std.testing.expectEqual(@as(u64, 4), info.row_count);

    try std.testing.expectEqual(SA_DB_OK, sa_db_delete_u64_i64_pair_key(root.ptr, root.len, "pair_i64_write_orders".ptr, "pair_i64_write_orders".len, 0, 1, 8, -3, &info));
    try std.testing.expectEqual(@as(u64, 3), info.row_count);
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_delete_u64_i64_pair_key(root.ptr, root.len, "pair_i64_write_orders".ptr, "pair_i64_write_orders".len, 0, 1, 8, -3, &info));

    var tx_handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "pair_i64_write_orders".ptr, "pair_i64_write_orders".len, &tx_handle));
    std.mem.writeInt(u64, row[0..8], 7, .little);
    std.mem.writeInt(i64, row[8..16], 0, .little);
    std.mem.writeInt(i64, row[16..24], 2200, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u64_i64_pair_key(tx_handle, 0, 1, 7, 0, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 0), inserted);
    std.mem.writeInt(u64, row[0..8], 7, .little);
    std.mem.writeInt(i64, row[8..16], 99, .little);
    std.mem.writeInt(i64, row[16..24], 9900, .little);
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_tx_update_row_u64_i64_pair_key(tx_handle, 0, 1, 7, 99, &row, row.len, &info));
    std.mem.writeInt(u64, row[0..8], 7, .little);
    std.mem.writeInt(i64, row[8..16], 10, .little);
    std.mem.writeInt(i64, row[16..24], 3300, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_update_row_u64_i64_pair_key(tx_handle, 0, 1, 7, 10, &row, row.len, &info));
    std.mem.writeInt(u64, row[0..8], 9, .little);
    std.mem.writeInt(i64, row[8..16], -1, .little);
    std.mem.writeInt(i64, row[16..24], 9000, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u64_i64_pair_key(tx_handle, 0, 1, 9, -1, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 1), inserted);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_delete_u64_i64_pair_key(tx_handle, 0, 1, 7, -5, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
    try std.testing.expectEqual(@as(u64, 3), info.row_count);

    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "pair_i64_write_orders".ptr, "pair_i64_write_orders".len, &tx_handle));
    std.mem.writeInt(u64, row[0..8], 99, .little);
    std.mem.writeInt(i64, row[8..16], -99, .little);
    std.mem.writeInt(i64, row[16..24], 9999, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u64_i64_pair_key(tx_handle, 0, 1, 99, -99, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_rollback(tx_handle));

    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "pair_i64_write_orders".ptr, "pair_i64_write_orders".len, &handle));
    var found: u64 = 0;
    var row_index: u64 = 0;
    var total: i64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_i64_pair_handle(handle, 0, 1, 7, 0, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_i64_handle(handle, 2, row_index, &total));
    try std.testing.expectEqual(@as(i64, 2200), total);
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_i64_pair_handle(handle, 0, 1, 7, -5, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 0), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_i64_pair_handle(handle, 0, 1, 7, 10, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_i64_handle(handle, 2, row_index, &total));
    try std.testing.expectEqual(@as(i64, 3300), total);
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_i64_pair_handle(handle, 0, 1, 9, -1, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_i64_handle(handle, 2, row_index, &total));
    try std.testing.expectEqual(@as(i64, 9000), total);
    try std.testing.expectEqual(SA_DB_OK, sa_db_find_u64_i64_pair_handle(handle, 0, 1, 99, -99, &found, &row_index));
    try std.testing.expectEqual(@as(u64, 0), found);
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, "pair_i64_write_orders".ptr, "pair_i64_write_orders".len, &info));
}

test "db SA ABI queries u64 timestamp pair ranges" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_STORE_ID_STRIDE = 8 // u64
        \\#def COL_POSTED_TS_STRIDE = 8 // i64 timestamp_ms
        \\#def COL_AMOUNT_CENTS_STRIDE = 8 // i64 decimal(2)
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "timestamp_orders.sadb-schema".ptr, "timestamp_orders.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

    var store_ids = [_]u64{ 7, 7, 7, 8, 7 };
    var posted_ts = [_]i64{
        timestampFromParts(0, 1000, MS_PER_DAY).?,
        timestampFromParts(0, 2000, MS_PER_DAY).?,
        timestampFromParts(0, 3000, MS_PER_DAY).?,
        timestampFromParts(0, 2500, MS_PER_DAY).?,
        timestampFromParts(1, 0, MS_PER_DAY).?,
    };
    var amounts = [_]i64{ 1000, 2000, 3000, 4000, 5000 };
    const cols = [_]SaDbColumnInput{
        .{ .data = @ptrCast(&store_ids), .len = @sizeOf(@TypeOf(store_ids)) },
        .{ .data = @ptrCast(&posted_ts), .len = @sizeOf(@TypeOf(posted_ts)) },
        .{ .data = @ptrCast(&amounts), .len = @sizeOf(@TypeOf(amounts)) },
    };
    try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "timestamp_orders".ptr, "timestamp_orders".len, store_ids.len, &cols, cols.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_u64_i64_pair_index(root.ptr, root.len, "timestamp_orders".ptr, "timestamp_orders".len, 0, 1, 0, &info));

    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "timestamp_orders".ptr, "timestamp_orders".len, &handle));

    var rows = [_]u64{ 99, 99, 99, 99 };
    var written: u64 = 123;
    var total: u64 = 456;
    try std.testing.expectEqual(SA_DB_OK, sa_db_range_u64_timestamp_ms_pair_handle(handle, 0, 1, 7, 0, 1500, 0, 3500, 0, 4, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 1), rows[0]);
    try std.testing.expectEqual(@as(u64, 2), rows[1]);

    @memset(rows[0..], 99);
    try std.testing.expectEqual(SA_DB_OK, sa_db_range_u64_timestamp_us_pair_handle(handle, 0, 1, 7, 0, 1500, 0, 3500, 0, 4, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 1), rows[0]);
    try std.testing.expectEqual(@as(u64, 2), rows[1]);

    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_range_u64_timestamp_ms_pair_handle(handle, 0, 1, 7, 0, MS_PER_DAY, 0, 0, 0, 4, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);
    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_range_u64_timestamp_us_pair_handle(handle, 0, 1, 7, 0, US_PER_DAY, 0, 0, 0, 4, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);

    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, "timestamp_orders".ptr, "timestamp_orders".len, &info));
}

test "db SA ABI filters candidate rows for ERP predicates" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_CUSTOMER_ID_STRIDE = 8 // u64
        \\#def COL_ORDER_DAY_STRIDE = 8 // i64 date
        \\#def COL_STATUS_ID_STRIDE = 8 // u64
        \\#def COL_POSTED_STRIDE = 1 // u8 bool
        \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64 decimal(2)
        \\#def COL_POSTED_MS_STRIDE = 8 // i64 timestamp_ms
        \\#def COL_POSTED_US_STRIDE = 8 // i64 timestamp_us
        \\#def COL_CHANNEL_ID_STRIDE = 4 // u32
        \\#def COL_ADJUSTMENT_STRIDE = 4 // i32
        \\#def COL_PRIORITY_STRIDE = 1 // u8
        \\#def COL_SIGNED_FLAG_STRIDE = 1 // i8
        \\#def COL_WAREHOUSE_ID_STRIDE = 2 // u16
        \\#def COL_QTY_DELTA_STRIDE = 2 // i16
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "candidate_filters.sadb-schema".ptr, "candidate_filters.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

    var customer_ids = [_]u64{ 7, 7, 7, 8, 7, 7 };
    var order_days = [_]i64{ -5, 0, 10, -3, 20, 25 };
    var status_ids = [_]u64{ 1, 2, 2, 2, 1, 2 };
    var posted = [_]u8{ 1, 1, 0, 1, 1, 1 };
    var totals = [_]i64{ 1000, 2000, 3000, 4000, 5000, 7000 };
    var posted_ms = [_]i64{ 0, 1000, 2000, 86_400_000, 86_400_001, 172_800_000 };
    var posted_us = [_]i64{ 0, 1000, 2000, 86_400_000_000, 86_400_000_001, 172_800_000_000 };
    var channel_ids = [_]u32{ 10, 20, 20, 30, 10, 40 };
    var adjustments = [_]i32{ -3, 5, 7, 9, -1, 11 };
    var priorities = [_]u8{ 1, 2, 3, 1, 2, 3 };
    var signed_flags = [_]i8{ -1, 0, 1, 0, -1, 1 };
    var warehouse_ids = [_]u16{ 100, 200, 200, 300, 100, 200 };
    var qty_deltas = [_]i16{ -5, 10, 20, 30, -15, 40 };
    const cols = [_]SaDbColumnInput{
        .{ .data = @ptrCast(&customer_ids), .len = @sizeOf(@TypeOf(customer_ids)) },
        .{ .data = @ptrCast(&order_days), .len = @sizeOf(@TypeOf(order_days)) },
        .{ .data = @ptrCast(&status_ids), .len = @sizeOf(@TypeOf(status_ids)) },
        .{ .data = @ptrCast(&posted), .len = @sizeOf(@TypeOf(posted)) },
        .{ .data = @ptrCast(&totals), .len = @sizeOf(@TypeOf(totals)) },
        .{ .data = @ptrCast(&posted_ms), .len = @sizeOf(@TypeOf(posted_ms)) },
        .{ .data = @ptrCast(&posted_us), .len = @sizeOf(@TypeOf(posted_us)) },
        .{ .data = @ptrCast(&channel_ids), .len = @sizeOf(@TypeOf(channel_ids)) },
        .{ .data = @ptrCast(&adjustments), .len = @sizeOf(@TypeOf(adjustments)) },
        .{ .data = @ptrCast(&priorities), .len = @sizeOf(@TypeOf(priorities)) },
        .{ .data = @ptrCast(&signed_flags), .len = @sizeOf(@TypeOf(signed_flags)) },
        .{ .data = @ptrCast(&warehouse_ids), .len = @sizeOf(@TypeOf(warehouse_ids)) },
        .{ .data = @ptrCast(&qty_deltas), .len = @sizeOf(@TypeOf(qty_deltas)) },
    };
    try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "candidate_filters".ptr, "candidate_filters".len, customer_ids.len, &cols, cols.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_u64_i64_pair_index(root.ptr, root.len, "candidate_filters".ptr, "candidate_filters".len, 0, 1, 1, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_u64_index(root.ptr, root.len, "candidate_filters".ptr, "candidate_filters".len, 0, 0, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_u64_index(root.ptr, root.len, "candidate_filters".ptr, "candidate_filters".len, 2, 0, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_i64_index(root.ptr, root.len, "candidate_filters".ptr, "candidate_filters".len, 1, 0, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_i64_index(root.ptr, root.len, "candidate_filters".ptr, "candidate_filters".len, 4, 0, &info));

    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "candidate_filters".ptr, "candidate_filters".len, &handle));

    var rows = [_]u64{ 99, 99, 99, 99, 99, 99 };
    var written: u64 = 0;
    var total: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_range_u64_i64_pair_handle(handle, 0, 1, 7, -5, 25, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 5), total);
    try std.testing.expectEqual(@as(u64, 5), written);
    const candidate_written = written;
    const original_candidate_rows = rows;

    var filtered = [_]u64{ 99, 99, 99, 99, 99, 99 };
    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_date_range_handle(handle, 1, &rows, candidate_written, 1970, 1, 1, 1970, 1, 21, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 3), written);
    try std.testing.expectEqual(@as(u64, 1), filtered[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered[1]);
    try std.testing.expectEqual(@as(u64, 4), filtered[2]);
    const date_written = written;

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_u64_range_handle(handle, 2, &rows, candidate_written, 2, 2, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 3), written);
    try std.testing.expectEqual(@as(u64, 1), rows[0]);
    try std.testing.expectEqual(@as(u64, 2), rows[1]);
    try std.testing.expectEqual(@as(u64, 5), rows[2]);
    const status_written = written;

    var intersect_rows = [_]u64{ 99, 99, 99, 99, 99, 99 };
    try std.testing.expectEqual(SA_DB_OK, sa_db_intersect_rows_handle(handle, &rows, status_written, &filtered, date_written, 0, intersect_rows.len, &intersect_rows, intersect_rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 1), intersect_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), intersect_rows[1]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_intersect_rows_handle(handle, &rows, status_written, &filtered, date_written, 1, 1, &intersect_rows, intersect_rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectEqual(@as(u64, 1), written);
    try std.testing.expectEqual(@as(u64, 2), intersect_rows[0]);

    var union_rows = [_]u64{ 99, 99, 99, 99, 99, 99 };
    try std.testing.expectEqual(SA_DB_OK, sa_db_union_rows_handle(handle, &rows, status_written, &filtered, date_written, 0, union_rows.len, &union_rows, union_rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 4), total);
    try std.testing.expectEqual(@as(u64, 4), written);
    try std.testing.expectEqual(@as(u64, 1), union_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), union_rows[1]);
    try std.testing.expectEqual(@as(u64, 5), union_rows[2]);
    try std.testing.expectEqual(@as(u64, 4), union_rows[3]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_union_rows_handle(handle, &rows, status_written, &filtered, date_written, 2, 2, &union_rows, union_rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 4), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 5), union_rows[0]);
    try std.testing.expectEqual(@as(u64, 4), union_rows[1]);

    var except_rows = [_]u64{ 99, 99, 99, 99, 99, 99 };
    try std.testing.expectEqual(SA_DB_OK, sa_db_except_rows_handle(handle, &rows, status_written, &filtered, date_written, 0, except_rows.len, &except_rows, except_rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 1), total);
    try std.testing.expectEqual(@as(u64, 1), written);
    try std.testing.expectEqual(@as(u64, 5), except_rows[0]);

    const invalid_intersect_rows = [_]u64{999};
    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_intersect_rows_handle(handle, &invalid_intersect_rows, invalid_intersect_rows.len, &filtered, date_written, 0, intersect_rows.len, &intersect_rows, intersect_rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);

    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_union_rows_handle(handle, &invalid_intersect_rows, invalid_intersect_rows.len, &filtered, date_written, 0, union_rows.len, &union_rows, union_rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);

    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_except_rows_handle(handle, &rows, status_written, &invalid_intersect_rows, invalid_intersect_rows.len, 0, except_rows.len, &except_rows, except_rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);

    var stats_count: u64 = 0;
    var stats_u64_sum: u64 = 0;
    var stats_u64_min: u64 = 0;
    var stats_u64_max: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_stats_rows_u64_handle(handle, 2, &rows, status_written, &stats_count, &stats_u64_sum, &stats_u64_min, &stats_u64_max));
    try std.testing.expectEqual(@as(u64, 3), stats_count);
    try std.testing.expectEqual(@as(u64, 6), stats_u64_sum);
    try std.testing.expectEqual(@as(u64, 2), stats_u64_min);
    try std.testing.expectEqual(@as(u64, 2), stats_u64_max);

    var stats_i64_sum: i64 = 0;
    var stats_i64_min: i64 = 0;
    var stats_i64_max: i64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_stats_rows_i64_handle(handle, 4, &rows, status_written, &stats_count, &stats_i64_sum, &stats_i64_min, &stats_i64_max));
    try std.testing.expectEqual(@as(u64, 3), stats_count);
    try std.testing.expectEqual(@as(i64, 12000), stats_i64_sum);
    try std.testing.expectEqual(@as(i64, 2000), stats_i64_min);
    try std.testing.expectEqual(@as(i64, 7000), stats_i64_max);

    try std.testing.expectEqual(SA_DB_OK, sa_db_sort_rows_u64_handle(handle, 2, &original_candidate_rows, candidate_written, 1, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 5), total);
    try std.testing.expectEqual(@as(u64, 5), written);
    try std.testing.expectEqual(@as(u64, 1), filtered[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered[1]);
    try std.testing.expectEqual(@as(u64, 5), filtered[2]);
    try std.testing.expectEqual(@as(u64, 0), filtered[3]);
    try std.testing.expectEqual(@as(u64, 4), filtered[4]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_sort_rows_i64_handle(handle, 4, &rows, status_written, 1, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 3), written);
    try std.testing.expectEqual(@as(u64, 5), filtered[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered[1]);
    try std.testing.expectEqual(@as(u64, 1), filtered[2]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_sort_rows_i64_handle(handle, 4, &rows, status_written, 1, 1, 1, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 1), written);
    try std.testing.expectEqual(@as(u64, 2), filtered[0]);

    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_sort_rows_i64_handle(handle, 4, &rows, status_written, 2, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);

    try std.testing.expectEqual(SA_DB_OK, sa_db_sort_rows_u32_handle(handle, 7, &original_candidate_rows, candidate_written, 1, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 5), total);
    try std.testing.expectEqual(@as(u64, 5), written);
    try std.testing.expectEqual(@as(u64, 5), filtered[0]);
    try std.testing.expectEqual(@as(u64, 1), filtered[1]);
    try std.testing.expectEqual(@as(u64, 2), filtered[2]);
    try std.testing.expectEqual(@as(u64, 0), filtered[3]);
    try std.testing.expectEqual(@as(u64, 4), filtered[4]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_sort_rows_i32_handle(handle, 8, &original_candidate_rows, candidate_written, 0, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 5), total);
    try std.testing.expectEqual(@as(u64, 5), written);
    try std.testing.expectEqual(@as(u64, 0), filtered[0]);
    try std.testing.expectEqual(@as(u64, 4), filtered[1]);
    try std.testing.expectEqual(@as(u64, 1), filtered[2]);
    try std.testing.expectEqual(@as(u64, 2), filtered[3]);
    try std.testing.expectEqual(@as(u64, 5), filtered[4]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_sort_rows_u8_handle(handle, 9, &original_candidate_rows, candidate_written, 1, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 5), total);
    try std.testing.expectEqual(@as(u64, 5), written);
    try std.testing.expectEqual(@as(u64, 2), filtered[0]);
    try std.testing.expectEqual(@as(u64, 5), filtered[1]);
    try std.testing.expectEqual(@as(u64, 1), filtered[2]);
    try std.testing.expectEqual(@as(u64, 4), filtered[3]);
    try std.testing.expectEqual(@as(u64, 0), filtered[4]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_sort_rows_i8_handle(handle, 10, &original_candidate_rows, candidate_written, 0, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 5), total);
    try std.testing.expectEqual(@as(u64, 5), written);
    try std.testing.expectEqual(@as(u64, 0), filtered[0]);
    try std.testing.expectEqual(@as(u64, 4), filtered[1]);
    try std.testing.expectEqual(@as(u64, 1), filtered[2]);
    try std.testing.expectEqual(@as(u64, 2), filtered[3]);
    try std.testing.expectEqual(@as(u64, 5), filtered[4]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_sort_rows_u16_handle(handle, 11, &original_candidate_rows, candidate_written, 1, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 5), total);
    try std.testing.expectEqual(@as(u64, 5), written);
    try std.testing.expectEqual(@as(u64, 1), filtered[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered[1]);
    try std.testing.expectEqual(@as(u64, 5), filtered[2]);
    try std.testing.expectEqual(@as(u64, 0), filtered[3]);
    try std.testing.expectEqual(@as(u64, 4), filtered[4]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_sort_rows_i16_handle(handle, 12, &original_candidate_rows, candidate_written, 0, 1, 2, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 5), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 0), filtered[0]);
    try std.testing.expectEqual(@as(u64, 1), filtered[1]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_u32_range_handle(handle, 7, &original_candidate_rows, candidate_written, 20, 40, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 3), written);
    try std.testing.expectEqual(@as(u64, 1), filtered[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered[1]);
    try std.testing.expectEqual(@as(u64, 5), filtered[2]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_i32_range_handle(handle, 8, &original_candidate_rows, candidate_written, 0, 10, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 1), filtered[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered[1]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_u8_range_handle(handle, 9, &original_candidate_rows, candidate_written, 2, 3, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 4), total);
    try std.testing.expectEqual(@as(u64, 4), written);
    try std.testing.expectEqual(@as(u64, 1), filtered[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered[1]);
    try std.testing.expectEqual(@as(u64, 4), filtered[2]);
    try std.testing.expectEqual(@as(u64, 5), filtered[3]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_i8_range_handle(handle, 10, &original_candidate_rows, candidate_written, -1, 0, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 3), written);
    try std.testing.expectEqual(@as(u64, 0), filtered[0]);
    try std.testing.expectEqual(@as(u64, 1), filtered[1]);
    try std.testing.expectEqual(@as(u64, 4), filtered[2]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_u16_range_handle(handle, 11, &original_candidate_rows, candidate_written, 200, 200, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 3), written);
    try std.testing.expectEqual(@as(u64, 1), filtered[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered[1]);
    try std.testing.expectEqual(@as(u64, 5), filtered[2]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_i16_range_handle(handle, 12, &original_candidate_rows, candidate_written, -20, 15, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 3), written);
    try std.testing.expectEqual(@as(u64, 0), filtered[0]);
    try std.testing.expectEqual(@as(u64, 1), filtered[1]);
    try std.testing.expectEqual(@as(u64, 4), filtered[2]);

    stats_count = 123;
    stats_i64_sum = 456;
    stats_i64_min = 789;
    stats_i64_max = 999;
    const invalid_stats_rows = [_]u64{999};
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_stats_rows_i64_handle(handle, 4, &invalid_stats_rows, invalid_stats_rows.len, &stats_count, &stats_i64_sum, &stats_i64_min, &stats_i64_max));
    try std.testing.expectEqual(@as(u64, 0), stats_count);
    try std.testing.expectEqual(@as(i64, 0), stats_i64_sum);
    try std.testing.expectEqual(@as(i64, 0), stats_i64_min);
    try std.testing.expectEqual(@as(i64, 0), stats_i64_max);

    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_sort_rows_i64_handle(handle, 4, &invalid_stats_rows, invalid_stats_rows.len, 1, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);

    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_sort_rows_u16_handle(handle, 11, &invalid_stats_rows, invalid_stats_rows.len, 1, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);

    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_filter_rows_u16_range_handle(handle, 11, &invalid_stats_rows, invalid_stats_rows.len, 200, 200, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_i64_range_handle(handle, 4, &rows, status_written, 1500, 5500, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 1), filtered[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered[1]);

    var plan_info: SaDbPlanInfo = undefined;
    var planned_rows = [_]u64{ 99, 99, 99, 99, 99, 99 };
    try std.testing.expectEqual(SA_DB_OK, sa_db_plan_u64_i64_ranges_handle(handle, 2, 2, 2, 4, 1500, 5500, 0, planned_rows.len, &planned_rows, planned_rows.len, &plan_info));
    try std.testing.expectEqual(@as(u64, 1), plan_info.first_predicate);
    try std.testing.expectEqual(@as(u64, 4), plan_info.first_total);
    try std.testing.expectEqual(@as(u64, 4), plan_info.second_total);
    try std.testing.expectEqual(@as(u64, 3), plan_info.total);
    try std.testing.expectEqual(@as(u64, 3), plan_info.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[1]);
    try std.testing.expectEqual(@as(u64, 3), planned_rows[2]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_plan_u64_i64_ranges_handle(handle, 2, 2, 2, 4, 1500, 5500, 1, 1, &planned_rows, planned_rows.len, &plan_info));
    try std.testing.expectEqual(@as(u64, 3), plan_info.total);
    try std.testing.expectEqual(@as(u64, 1), plan_info.written);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[0]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_plan_u64_i64_ranges_handle(handle, 2, 1, 2, 4, 1500, 3500, 0, planned_rows.len, &planned_rows, planned_rows.len, &plan_info));
    try std.testing.expectEqual(@as(u64, 2), plan_info.first_predicate);
    try std.testing.expectEqual(@as(u64, 2), plan_info.first_total);
    try std.testing.expectEqual(@as(u64, 6), plan_info.second_total);
    try std.testing.expectEqual(@as(u64, 2), plan_info.total);
    try std.testing.expectEqual(@as(u64, 2), plan_info.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[1]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_plan_u64_u64_ranges_handle(handle, 0, 7, 7, 2, 2, 2, 0, planned_rows.len, &planned_rows, planned_rows.len, &plan_info));
    try std.testing.expectEqual(@as(u64, 2), plan_info.first_predicate);
    try std.testing.expectEqual(@as(u64, 4), plan_info.first_total);
    try std.testing.expectEqual(@as(u64, 5), plan_info.second_total);
    try std.testing.expectEqual(@as(u64, 3), plan_info.total);
    try std.testing.expectEqual(@as(u64, 3), plan_info.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[1]);
    try std.testing.expectEqual(@as(u64, 5), planned_rows[2]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_plan_i64_i64_ranges_handle(handle, 1, -5, 20, 4, 1500, 3500, 0, planned_rows.len, &planned_rows, planned_rows.len, &plan_info));
    try std.testing.expectEqual(@as(u64, 2), plan_info.first_predicate);
    try std.testing.expectEqual(@as(u64, 2), plan_info.first_total);
    try std.testing.expectEqual(@as(u64, 5), plan_info.second_total);
    try std.testing.expectEqual(@as(u64, 2), plan_info.total);
    try std.testing.expectEqual(@as(u64, 2), plan_info.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[1]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_decimal_i64_range_handle(handle, 4, &rows, 3, 2, 0, 15, 0, 0, 55, 0, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 1), filtered[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered[1]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_timestamp_ms_range_handle(handle, 5, &rows, 3, 0, 0, 0, 3000, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 1), filtered[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered[1]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_timestamp_us_range_handle(handle, 6, &rows, 3, 0, 0, 0, 3000, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 1), filtered[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered[1]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_bool_handle(handle, 3, &rows, 3, 1, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 1), filtered[0]);
    try std.testing.expectEqual(@as(u64, 5), filtered[1]);

    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_filter_rows_bool_handle(handle, 3, &rows, 3, 2, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);

    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_filter_rows_date_range_handle(handle, 1, &rows, 3, 1970, 13, 1, 1970, 1, 1, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);

    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_filter_rows_timestamp_ms_range_handle(handle, 5, &rows, 3, 0, MS_PER_DAY, 0, 0, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);

    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_ARGUMENT, sa_db_filter_rows_timestamp_us_range_handle(handle, 6, &rows, 3, 0, US_PER_DAY, 0, 0, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);

    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, "candidate_filters".ptr, "candidate_filters".len, &info));
}

test "db SA ABI filters and sorts float candidate rows" {
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
        \\#def COL_QTY_STRIDE = 4 // f32
        \\#def COL_WEIGHT_STRIDE = 8 // f64
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "float_candidate_rows.sadb-schema".ptr, "float_candidate_rows.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

    var ids = [_]u64{ 1, 2, 3, 4, 5 };
    var quantities = [_]f32{ 1.5, -2.25, 0.0, -0.0, 9.75 };
    var weights = [_]f64{ 10.5, -3.25, 2.0, 2.0, 100.125 };
    const cols = [_]SaDbColumnInput{
        .{ .data = @ptrCast(&ids), .len = @sizeOf(@TypeOf(ids)) },
        .{ .data = @ptrCast(&quantities), .len = @sizeOf(@TypeOf(quantities)) },
        .{ .data = @ptrCast(&weights), .len = @sizeOf(@TypeOf(weights)) },
    };
    try std.testing.expectEqual(SA_DB_OK, sa_db_ingest_columns(root.ptr, root.len, "float_candidate_rows".ptr, "float_candidate_rows".len, ids.len, &cols, cols.len, &info));

    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "float_candidate_rows".ptr, "float_candidate_rows".len, &handle));

    var written: u64 = 0;
    var total: u64 = 0;
    var filtered = [_]u64{ 99, 99, 99, 99, 99 };
    var f32_candidate_rows = [_]u64{ 2, 3, 0, 1, 4 };
    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_f32_range_handle(handle, 1, &f32_candidate_rows, f32_candidate_rows.len, -0.0, 1.5, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 3), written);
    try std.testing.expectEqual(@as(u64, 2), filtered[0]);
    try std.testing.expectEqual(@as(u64, 3), filtered[1]);
    try std.testing.expectEqual(@as(u64, 0), filtered[2]);

    var f64_candidate_rows = [_]u64{ 1, 2, 3, 0, 4 };
    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_f64_range_handle(handle, 2, &f64_candidate_rows, f64_candidate_rows.len, 2.0, 10.5, 1, 2, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 3), filtered[0]);
    try std.testing.expectEqual(@as(u64, 0), filtered[1]);

    var all_rows = [_]u64{ 0, 1, 2, 3, 4 };
    try std.testing.expectEqual(SA_DB_OK, sa_db_sort_rows_f32_handle(handle, 1, &all_rows, all_rows.len, 1, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 5), total);
    try std.testing.expectEqual(@as(u64, 5), written);
    try std.testing.expectEqual(@as(u64, 4), filtered[0]);
    try std.testing.expectEqual(@as(u64, 0), filtered[1]);
    try std.testing.expectEqual(@as(u64, 2), filtered[2]);
    try std.testing.expectEqual(@as(u64, 3), filtered[3]);
    try std.testing.expectEqual(@as(u64, 1), filtered[4]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_sort_rows_f64_handle(handle, 2, &all_rows, all_rows.len, 0, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 5), total);
    try std.testing.expectEqual(@as(u64, 5), written);
    try std.testing.expectEqual(@as(u64, 1), filtered[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered[1]);
    try std.testing.expectEqual(@as(u64, 3), filtered[2]);
    try std.testing.expectEqual(@as(u64, 0), filtered[3]);
    try std.testing.expectEqual(@as(u64, 4), filtered[4]);

    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_filter_rows_f32_range_handle(handle, 1, &all_rows, all_rows.len, std.math.inf(f32), 1.0, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);

    const invalid_rows = [_]u64{999};
    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_sort_rows_f64_handle(handle, 2, &invalid_rows, invalid_rows.len, 1, 0, filtered.len, &filtered, filtered.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);

    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(handle));
}

test "db SA ABI commits and rolls back write transactions" {
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
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "tx_members.sadb-schema".ptr, "tx_members.sadb-schema".len, schema_source.ptr, schema_source.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_u64_index(root.ptr, root.len, "tx_members".ptr, "tx_members".len, 0, 1, &info));

    var tx_handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "tx_members".ptr, "tx_members".len, &tx_handle));
    var row: [16]u8 = undefined;
    std.mem.writeInt(u64, row[0..8], 1, .little);
    std.mem.writeInt(u64, row[8..16], 10, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_insert_row(tx_handle, &row, row.len, &info));
    std.mem.writeInt(u64, row[0..8], 2, .little);
    std.mem.writeInt(u64, row[8..16], 20, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_insert_row(tx_handle, &row, row.len, &info));
    try std.testing.expectEqual(@as(u64, 2), info.row_count);
    try std.testing.expectEqual(@as(u64, 1), info.epoch);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
    try std.testing.expectEqual(@as(u64, 2), info.row_count);
    try std.testing.expectEqual(@as(u64, 2), info.epoch);

    var read_handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "tx_members".ptr, "tx_members".len, &read_handle));
    var sum: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_sum_u64_handle(read_handle, 1, &sum));
    try std.testing.expectEqual(@as(u64, 30), sum);
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(read_handle));

    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "tx_members".ptr, "tx_members".len, &tx_handle));
    std.mem.writeInt(u64, row[0..8], 2, .little);
    std.mem.writeInt(u64, row[8..16], 200, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_insert_row(tx_handle, &row, row.len, &info));
    try std.testing.expectEqual(SA_DB_ERR_CONSTRAINT, sa_db_tx_commit(tx_handle, &info));

    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "tx_members".ptr, "tx_members".len, &read_handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_sum_u64_handle(read_handle, 1, &sum));
    try std.testing.expectEqual(@as(u64, 30), sum);
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(read_handle));

    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "tx_members".ptr, "tx_members".len, &tx_handle));
    var inserted: u64 = 99;
    std.mem.writeInt(u64, row[0..8], 2, .little);
    std.mem.writeInt(u64, row[8..16], 25, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u64_key(tx_handle, 0, 2, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 0), inserted);
    std.mem.writeInt(u64, row[0..8], 99, .little);
    std.mem.writeInt(u64, row[8..16], 990, .little);
    try std.testing.expectEqual(SA_DB_ERR_NOT_FOUND, sa_db_tx_update_row_u64_key(tx_handle, 0, 99, &row, row.len, &info));
    std.mem.writeInt(u64, row[0..8], 2, .little);
    std.mem.writeInt(u64, row[8..16], 26, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_update_row_u64_key(tx_handle, 0, 2, &row, row.len, &info));
    std.mem.writeInt(u64, row[0..8], 3, .little);
    std.mem.writeInt(u64, row[8..16], 30, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_upsert_row_u64_key(tx_handle, 0, 3, &row, row.len, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 1), inserted);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_delete_u64_key(tx_handle, 0, 1, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
    try std.testing.expectEqual(@as(u64, 2), info.row_count);
    try std.testing.expectEqual(@as(u64, 3), info.epoch);

    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, "tx_members".ptr, "tx_members".len, &tx_handle));
    std.mem.writeInt(u64, row[0..8], 4, .little);
    std.mem.writeInt(u64, row[8..16], 40, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_insert_row(tx_handle, &row, row.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_rollback(tx_handle));

    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, "tx_members".ptr, "tx_members".len, &read_handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_sum_u64_handle(read_handle, 1, &sum));
    try std.testing.expectEqual(@as(u64, 56), sum);
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(read_handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, "tx_members".ptr, "tx_members".len, &info));
}

test "db SA ABI commits and rolls back transaction blob handles" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    const table_name = "tx_blob_abi";
    const store_name = "notes";
    const value_a = "created in tx";
    const value_b = "blob only";
    const value_c = "rolled back";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_NOTE_STRIDE = 8 // blob_handle
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "tx_blob_abi.sadb-schema".ptr, "tx_blob_abi.sadb-schema".len, schema_source.ptr, schema_source.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_blob_eq_index(root.ptr, root.len, table_name.ptr, table_name.len, 1, store_name.ptr, store_name.len, 0, &info));

    var tx_handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, table_name.ptr, table_name.len, &tx_handle));
    var blob_a_id: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_blob_put(tx_handle, store_name.ptr, store_name.len, value_a.ptr, value_a.len, &blob_a_id, &info));
    try std.testing.expectEqual(@as(u64, 1), blob_a_id);
    var row: [16]u8 = undefined;
    std.mem.writeInt(u64, row[0..8], 100, .little);
    std.mem.writeInt(u64, row[8..16], blob_a_id, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_insert_row(tx_handle, &row, row.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
    try std.testing.expectEqual(@as(u64, 1), info.row_count);
    try std.testing.expectEqual(@as(u64, 2), info.epoch);

    var found: u64 = 0;
    var len: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_blob_value_len(root.ptr, root.len, table_name.ptr, table_name.len, store_name.ptr, store_name.len, blob_a_id, &found, &len));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(@as(u64, value_a.len), len);

    var read_handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, table_name.ptr, table_name.len, &read_handle));
    var rows = [_]u64{ 99, 99 };
    var written: u64 = 0;
    var total: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_blob_eq_handle(read_handle, 1, store_name.ptr, store_name.len, value_a.ptr, value_a.len, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 1), written);
    try std.testing.expectEqual(@as(u64, 1), total);
    try std.testing.expectEqual(@as(u64, 0), rows[0]);
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(read_handle));

    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, table_name.ptr, table_name.len, &tx_handle));
    var blob_b_id: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_blob_put(tx_handle, store_name.ptr, store_name.len, value_b.ptr, value_b.len, &blob_b_id, &info));
    try std.testing.expectEqual(@as(u64, 2), blob_b_id);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
    try std.testing.expectEqual(@as(u64, 1), info.row_count);
    try std.testing.expectEqual(@as(u64, 3), info.epoch);
    try std.testing.expectEqual(SA_DB_OK, sa_db_blob_value_len(root.ptr, root.len, table_name.ptr, table_name.len, store_name.ptr, store_name.len, blob_b_id, &found, &len));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(@as(u64, value_b.len), len);

    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, table_name.ptr, table_name.len, &tx_handle));
    var blob_c_id: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_blob_put(tx_handle, store_name.ptr, store_name.len, value_c.ptr, value_c.len, &blob_c_id, &info));
    try std.testing.expectEqual(@as(u64, 3), blob_c_id);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_rollback(tx_handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_blob_value_len(root.ptr, root.len, table_name.ptr, table_name.len, store_name.ptr, store_name.len, blob_c_id, &found, &len));
    try std.testing.expectEqual(@as(u64, 0), found);
    try std.testing.expectEqual(@as(u64, 0), len);
    try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, table_name.ptr, table_name.len, &info));
    try std.testing.expectEqual(@as(u64, 1), info.row_count);
    try std.testing.expectEqual(@as(u64, 3), info.epoch);
}

test "db SA ABI commits and rolls back transaction dictionaries" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    const table_name = "tx_dict_abi";
    const dict_name = "status";
    const active = "active";
    const paused = "paused";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_STATUS_STRIDE = 8 // u64
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "tx_dict_abi.sadb-schema".ptr, "tx_dict_abi.sadb-schema".len, schema_source.ptr, schema_source.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_u64_index(root.ptr, root.len, table_name.ptr, table_name.len, 0, 1, &info));

    var tx_handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, table_name.ptr, table_name.len, &tx_handle));
    var active_id: u64 = 0;
    var inserted: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_dict_intern(tx_handle, dict_name.ptr, dict_name.len, active.ptr, active.len, &active_id, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 1), active_id);
    try std.testing.expectEqual(@as(u64, 1), inserted);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_dict_intern(tx_handle, dict_name.ptr, dict_name.len, active.ptr, active.len, &active_id, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 1), active_id);
    try std.testing.expectEqual(@as(u64, 0), inserted);

    var found: u64 = 99;
    var lookup_id: u64 = 99;
    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_lookup(root.ptr, root.len, table_name.ptr, table_name.len, dict_name.ptr, dict_name.len, active.ptr, active.len, &found, &lookup_id));
    try std.testing.expectEqual(@as(u64, 0), found);
    try std.testing.expectEqual(@as(u64, 0), lookup_id);

    var row: [16]u8 = undefined;
    std.mem.writeInt(u64, row[0..8], 1, .little);
    std.mem.writeInt(u64, row[8..16], active_id, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_insert_row(tx_handle, &row, row.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_commit(tx_handle, &info));
    try std.testing.expectEqual(@as(u64, 1), info.row_count);
    try std.testing.expectEqual(@as(u64, 2), info.epoch);

    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_lookup(root.ptr, root.len, table_name.ptr, table_name.len, dict_name.ptr, dict_name.len, active.ptr, active.len, &found, &lookup_id));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(@as(u64, 1), lookup_id);

    var read_handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, table_name.ptr, table_name.len, &read_handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_lookup_handle(read_handle, dict_name.ptr, dict_name.len, active.ptr, active.len, &found, &lookup_id));
    try std.testing.expectEqual(@as(u64, 1), found);
    try std.testing.expectEqual(@as(u64, 1), lookup_id);
    var fetched_row: [16]u8 = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_u64_key_handle(read_handle, 0, 1, &fetched_row, fetched_row.len));
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, fetched_row[0..8], .little));
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, fetched_row[8..16], .little));
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(read_handle));

    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_begin(root.ptr, root.len, table_name.ptr, table_name.len, &tx_handle));
    var paused_id: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_dict_intern(tx_handle, dict_name.ptr, dict_name.len, paused.ptr, paused.len, &paused_id, &inserted, &info));
    try std.testing.expectEqual(@as(u64, 2), paused_id);
    try std.testing.expectEqual(@as(u64, 1), inserted);
    try std.testing.expectEqual(SA_DB_OK, sa_db_tx_rollback(tx_handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_dict_lookup(root.ptr, root.len, table_name.ptr, table_name.len, dict_name.ptr, dict_name.len, paused.ptr, paused.len, &found, &lookup_id));
    try std.testing.expectEqual(@as(u64, 0), found);
    try std.testing.expectEqual(@as(u64, 0), lookup_id);

    try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, table_name.ptr, table_name.len, &info));
    try std.testing.expectEqual(@as(u64, 1), info.row_count);
    try std.testing.expectEqual(@as(u64, 2), info.epoch);
}

test "db SA ABI creates and queries blob token indexes" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const root = ".";
    const table_name = "token_abi";
    const store_name = "notes";
    const value_a = "Blue Widget SKU-001";
    const value_b = "red widget sku_002";
    const value_c = "invoice paid customer";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_NOTE_STRIDE = 8 // blob_handle
    ;
    var info: SaDbTableInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_init_schema(root.ptr, root.len, "token_abi.sadb-schema".ptr, "token_abi.sadb-schema".len, schema_source.ptr, schema_source.len, &info));

    var blob_a_id: u64 = 0;
    var blob_b_id: u64 = 0;
    var blob_c_id: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_blob_put(root.ptr, root.len, table_name.ptr, table_name.len, store_name.ptr, store_name.len, value_a.ptr, value_a.len, &blob_a_id, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_blob_put(root.ptr, root.len, table_name.ptr, table_name.len, store_name.ptr, store_name.len, value_b.ptr, value_b.len, &blob_b_id, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_blob_put(root.ptr, root.len, table_name.ptr, table_name.len, store_name.ptr, store_name.len, value_c.ptr, value_c.len, &blob_c_id, &info));

    var row: [16]u8 = undefined;
    std.mem.writeInt(u64, row[0..8], 100, .little);
    std.mem.writeInt(u64, row[8..16], blob_a_id, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_insert_row(root.ptr, root.len, table_name.ptr, table_name.len, &row, row.len, &info));
    std.mem.writeInt(u64, row[0..8], 101, .little);
    std.mem.writeInt(u64, row[8..16], blob_b_id, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_insert_row(root.ptr, root.len, table_name.ptr, table_name.len, &row, row.len, &info));
    std.mem.writeInt(u64, row[0..8], 102, .little);
    std.mem.writeInt(u64, row[8..16], blob_c_id, .little);
    try std.testing.expectEqual(SA_DB_OK, sa_db_insert_row(root.ptr, root.len, table_name.ptr, table_name.len, &row, row.len, &info));

    try std.testing.expectEqual(SA_DB_OK, sa_db_create_blob_token_index(root.ptr, root.len, table_name.ptr, table_name.len, 1, store_name.ptr, store_name.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_blob_prefix_index(root.ptr, root.len, table_name.ptr, table_name.len, 1, store_name.ptr, store_name.len, &info));
    try std.testing.expectEqual(SA_DB_OK, sa_db_create_blob_contains_index(root.ptr, root.len, table_name.ptr, table_name.len, 1, store_name.ptr, store_name.len, &info));
    try std.testing.expectEqual(@as(u64, 3), info.row_count);

    var read_handle: ?*anyopaque = null;
    try std.testing.expectEqual(SA_DB_OK, sa_db_open_read_table(root.ptr, root.len, table_name.ptr, table_name.len, &read_handle));
    var rows = [_]u64{ 99, 99, 99 };
    var written: u64 = 0;
    var total: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_blob_token_handle(read_handle, 1, store_name.ptr, store_name.len, "WIDGET".ptr, "WIDGET".len, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 0), rows[0]);
    try std.testing.expectEqual(@as(u64, 1), rows[1]);
    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_blob_token_handle(read_handle, 1, store_name.ptr, store_name.len, "paid".ptr, "paid".len, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 1), total);
    try std.testing.expectEqual(@as(u64, 2), rows[0]);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_filter_blob_token_handle(read_handle, 1, store_name.ptr, store_name.len, "two words".ptr, "two words".len, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);
    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_blob_prefix_handle(read_handle, 1, store_name.ptr, store_name.len, "wid".ptr, "wid".len, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 0), rows[0]);
    try std.testing.expectEqual(@as(u64, 1), rows[1]);
    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_blob_prefix_handle(read_handle, 1, store_name.ptr, store_name.len, "SKU_".ptr, "SKU_".len, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 1), total);
    try std.testing.expectEqual(@as(u64, 1), written);
    try std.testing.expectEqual(@as(u64, 1), rows[0]);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_filter_blob_prefix_handle(read_handle, 1, store_name.ptr, store_name.len, "two words".ptr, "two words".len, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);
    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_blob_contains_handle(read_handle, 1, store_name.ptr, store_name.len, "dget SKU".ptr, "dget SKU".len, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 1), total);
    try std.testing.expectEqual(@as(u64, 1), written);
    try std.testing.expectEqual(@as(u64, 0), rows[0]);
    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_blob_contains_handle(read_handle, 1, store_name.ptr, store_name.len, "ed".ptr, "ed".len, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 1), total);
    try std.testing.expectEqual(@as(u64, 1), written);
    try std.testing.expectEqual(@as(u64, 1), rows[0]);

    const candidate_rows = [_]u64{ 2, 1, 0 };
    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_blob_eq_handle(read_handle, 1, &candidate_rows, candidate_rows.len, store_name.ptr, store_name.len, value_a.ptr, value_a.len, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 1), total);
    try std.testing.expectEqual(@as(u64, 1), written);
    try std.testing.expectEqual(@as(u64, 0), rows[0]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_blob_contains_handle(read_handle, 1, &candidate_rows, candidate_rows.len, store_name.ptr, store_name.len, "idget".ptr, "idget".len, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 1), rows[0]);
    try std.testing.expectEqual(@as(u64, 0), rows[1]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_blob_token_handle(read_handle, 1, &candidate_rows, candidate_rows.len, store_name.ptr, store_name.len, "WIDGET".ptr, "WIDGET".len, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectEqual(@as(u64, 2), written);
    try std.testing.expectEqual(@as(u64, 1), rows[0]);
    try std.testing.expectEqual(@as(u64, 0), rows[1]);

    try std.testing.expectEqual(SA_DB_OK, sa_db_filter_rows_blob_prefix_handle(read_handle, 1, &candidate_rows, candidate_rows.len, store_name.ptr, store_name.len, "SKU_".ptr, "SKU_".len, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 1), total);
    try std.testing.expectEqual(@as(u64, 1), written);
    try std.testing.expectEqual(@as(u64, 1), rows[0]);

    const invalid_candidate_rows = [_]u64{999};
    written = 123;
    total = 456;
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_filter_rows_blob_eq_handle(read_handle, 1, &invalid_candidate_rows, invalid_candidate_rows.len, store_name.ptr, store_name.len, value_a.ptr, value_a.len, 0, rows.len, &rows, rows.len, &written, &total));
    try std.testing.expectEqual(@as(u64, 0), written);
    try std.testing.expectEqual(@as(u64, 0), total);
    try std.testing.expectEqual(SA_DB_OK, sa_db_close_read_table(read_handle));
    try std.testing.expectEqual(SA_DB_OK, sa_db_verify(root.ptr, root.len, table_name.ptr, table_name.len, &info));
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

    var snapshot_info: SaDbSnapshotInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_snapshot_info_handle(handle, &snapshot_info));
    try std.testing.expectEqual(@as(u64, 5), snapshot_info.row_count);
    try std.testing.expectEqual(@as(u64, 2), snapshot_info.column_count);
    try std.testing.expectEqual(@as(u64, 16), snapshot_info.row_bytes);
    try std.testing.expectEqual(@as(u64, 5), snapshot_info.epoch);
    var column_info: SaDbColumnInfo = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_column_info_handle(handle, 1, &column_info));
    try std.testing.expectEqual(@as(u64, 8), column_info.stride);
    try std.testing.expectEqual(@as(u64, 9), column_info.type_code);
    try std.testing.expectEqual(@as(u64, 6), column_info.name_len);
    try std.testing.expectEqual(@as(u64, 3), column_info.type_name_len);
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_column_info_handle(handle, 99, &column_info));

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
    var null_bitmap = [_]u8{0};
    var null_range_rows = [_]u64{ 99, 99 };
    var null_range_written: u64 = 0;
    var null_range_total: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_null_bitmap_set(&null_bitmap, null_bitmap.len, 3, 1));
    try std.testing.expectEqual(SA_DB_OK, sa_db_range_u64_null_bitmap_handle(handle, 0, 2, 5, &null_bitmap, null_bitmap.len, 0, 0, 3, &null_range_rows, null_range_rows.len, &null_range_written, &null_range_total));
    try std.testing.expectEqual(@as(u64, 3), null_range_total);
    try std.testing.expectEqual(@as(u64, 2), null_range_written);
    try std.testing.expectEqual(@as(u64, 1), null_range_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), null_range_rows[1]);
    try std.testing.expectEqual(SA_DB_OK, sa_db_range_u64_null_bitmap_handle(handle, 0, 2, 5, &null_bitmap, null_bitmap.len, 1, 0, 3, &null_range_rows, null_range_rows.len, &null_range_written, &null_range_total));
    try std.testing.expectEqual(@as(u64, 1), null_range_total);
    try std.testing.expectEqual(@as(u64, 1), null_range_written);
    try std.testing.expectEqual(@as(u64, 3), null_range_rows[0]);
    var range_row: [16]u8 = undefined;
    try std.testing.expectEqual(SA_DB_OK, sa_db_get_row_handle(handle, range_rows[1], &range_row, range_row.len));
    try std.testing.expectEqual(@as(u64, 4), std.mem.readInt(u64, range_row[0..8], .little));
    try std.testing.expectEqual(@as(u64, 44), std.mem.readInt(u64, range_row[8..16], .little));
    try std.testing.expectEqual(SA_DB_ERR_INVALID_FORMAT, sa_db_get_row_handle(handle, 99, &range_row, range_row.len));
    var project_columns = [_]u64{ 0, 1 };
    var projected_rows: [32]u8 = undefined;
    var projected_written: u64 = 0;
    var projected_required: u64 = 0;
    try std.testing.expectEqual(SA_DB_OK, sa_db_project_rows_handle(handle, &range_rows, range_written, &project_columns, project_columns.len, &projected_rows, projected_rows.len, &projected_written, &projected_required));
    try std.testing.expectEqual(@as(u64, 2), projected_written);
    try std.testing.expectEqual(@as(u64, 32), projected_required);
    try std.testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, projected_rows[0..8], .little));
    try std.testing.expectEqual(@as(u64, 30), std.mem.readInt(u64, projected_rows[8..16], .little));
    try std.testing.expectEqual(@as(u64, 4), std.mem.readInt(u64, projected_rows[16..24], .little));
    try std.testing.expectEqual(@as(u64, 44), std.mem.readInt(u64, projected_rows[24..32], .little));
    var too_small_projected_rows: [24]u8 = undefined;
    projected_written = 99;
    projected_required = 0;
    try std.testing.expectEqual(SA_DB_ERR_CURSOR_OVERFLOW, sa_db_project_rows_handle(handle, &range_rows, range_written, &project_columns, project_columns.len, &too_small_projected_rows, too_small_projected_rows.len, &projected_written, &projected_required));
    try std.testing.expectEqual(@as(u64, 0), projected_written);
    try std.testing.expectEqual(@as(u64, 32), projected_required);
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
