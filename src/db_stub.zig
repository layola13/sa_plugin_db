const std = @import("std");
const schema = @import("schema.zig");
const table_mod = @import("table.zig");

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
};

pub const ExecResult = struct {
    hash: [32]u8,
    qmod_path: []u8,
    meta_path: []u8,
    source_path: []u8,
    imports: u64,
    grants: u64,

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
};

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

    pub fn deinit(self: *TableColumn, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.ty);
        allocator.free(self.bytes);
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

    pub fn deinit(self: *ReadTable, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.columns) |*column| column.deinit(allocator);
        allocator.free(self.columns);
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
    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
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
    std.fs.cwd().makePath(".sa/db/qmods") catch return ExecError.InvalidPath;
}

fn qmodPath(allocator: std.mem.Allocator, hash_hex: []const u8) ExecError![]u8 {
    return std.fmt.allocPrint(allocator, ".sa/db/qmods/{s}.qmod", .{hash_hex}) catch ExecError.OutOfMemory;
}

fn metaPath(allocator: std.mem.Allocator, hash_hex: []const u8) ExecError![]u8 {
    return std.fmt.allocPrint(allocator, ".sa/db/qmods/{s}.meta.json", .{hash_hex}) catch ExecError.OutOfMemory;
}

fn writeFile(path: []const u8, bytes: []const u8) ExecError!void {
    var file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return ExecError.InvalidPath;
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
    const args = std.mem.trimLeft(u8, rest[split..], " \t");
    const comma = std.mem.indexOfScalar(u8, args, ',') orelse return ExecError.UnsupportedOperation;
    const addr = std.mem.trim(u8, args[0..comma], " \t");
    const plus = std.mem.indexOfScalar(u8, addr, '+') orelse return ExecError.UnsupportedOperation;
    return std.mem.trim(u8, addr[0..plus], " \t");
}

fn parseAtomicOffsetToken(line: []const u8) ExecError!?[]const u8 {
    const atomic_idx = std.mem.indexOf(u8, line, "atomic_rmw_") orelse return null;
    const rest = line[atomic_idx..];
    const split = std.mem.indexOfAny(u8, rest, " \t") orelse return ExecError.UnsupportedOperation;
    const args = std.mem.trimLeft(u8, rest[split..], " \t");
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

fn loadReadTable(allocator: std.mem.Allocator, table_name: []const u8) ExecError!ReadTable {
    const meta_bytes = try readActiveTableMetaSource(allocator, table_name);
    defer allocator.free(meta_bytes);
    var parsed = std.json.parseFromSlice(QmodTableMeta, allocator, meta_bytes, .{ .allocate = .alloc_always }) catch return ExecError.SnapshotCorrupted;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.magic, "sa-db-table-meta") or parsed.value.version != 1) return ExecError.SnapshotCorrupted;
    if (!std.mem.eql(u8, parsed.value.table_name, table_name)) return ExecError.SnapshotCorrupted;

    const current_schema_path = try schemaPath(allocator, table_name);
    defer allocator.free(current_schema_path);
    const current_schema = try readFileAlloc(allocator, current_schema_path, 1024 * 1024);
    defer allocator.free(current_schema);
    const current_schema_hash = hashHex(current_schema);
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
        var merged = std.ArrayList(u8).init(allocator);
        errdefer merged.deinit();
        for (parsed.value.segments) |segment| {
            if (segment.files.len != parsed.value.columns.len) return ExecError.SnapshotCorrupted;
            const file_meta = segment.files[col_idx];
            const bytes = try readFileAlloc(allocator, file_meta.path, 1 << 30);
            defer allocator.free(bytes);
            try validateQmodFileBytes(file_meta, bytes);
            if (bytes.len != segment.rows * meta_column.stride) return ExecError.SnapshotCorrupted;
            merged.appendSlice(bytes) catch return ExecError.OutOfMemory;
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
        const trimmed = std.mem.trimLeft(u8, line, " \t\r");
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

fn appendGrantEntry(allocator: std.mem.Allocator, entries: *std.ArrayList([]u8), entry: []const u8) ExecError!void {
    const trimmed = std.mem.trim(u8, entry, " \t\r\n");
    if (trimmed.len == 0) return;
    entries.append(allocator.dupe(u8, trimmed) catch return ExecError.OutOfMemory) catch return ExecError.OutOfMemory;
}

fn parseGrants(allocator: std.mem.Allocator, source: []const u8) ExecError!GrantSet {
    var entries = std.ArrayList([]u8).init(allocator);
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
        const trimmed = std.mem.trimLeft(u8, line, " \t\r");
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
        var params = std.ArrayList([]const u8).init(allocator);
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

fn evalScalarQmod(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8, params_path: ?[]const u8) ExecError!?u64 {
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
                const param_name = std.mem.trimLeft(u8, raw_name[1..], " \t");
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
                const param_name = std.mem.trimLeft(u8, raw_name[1..], " \t");
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
                const param_name = std.mem.trimLeft(u8, raw_name[1..], " \t");
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
                const param_name = std.mem.trimLeft(u8, raw_name[1..], " \t");
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
    var lines = std.ArrayList([]const u8).init(allocator);
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
    if (current.block_size != expected.block_size) return false;
    if (current.block_sha256.len != expected.block_sha256.len) return false;
    for (current.block_sha256, expected.block_sha256) |current_hash, expected_hash| {
        if (!std.mem.eql(u8, current_hash, expected_hash)) return false;
    }
    return true;
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
    if (current.value.columns.len != expected.columns.len or current.value.segments.len != expected.segments.len or current.value.indexes.len != expected.indexes.len) return false;
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
        if (!std.mem.eql(u8, current_index.name, expected_index.name)) return false;
        if (!std.mem.eql(u8, current_index.kind, expected_index.kind)) return false;
        if (current_index.column_index != expected_index.column_index) return false;
        if (current_index.unique != expected_index.unique) return false;
        if (!std.mem.eql(u8, current_index.path, expected_index.path)) return false;
        if (!std.mem.eql(u8, current_index.sha256, expected_index.sha256)) return false;
        if (current_index.bytes != expected_index.bytes) return false;
    }
    return true;
}

fn commitWriteTable(allocator: std.mem.Allocator, write_table: *WriteTable) ExecError!void {
    var any_dirty = false;
    var owned_paths = std.ArrayList([]const u8).init(allocator);
    defer {
        for (owned_paths.items) |path| allocator.free(path);
        owned_paths.deinit();
    }
    var owned_hashes = std.ArrayList([]const u8).init(allocator);
    defer {
        for (owned_hashes.items) |hash| allocator.free(hash);
        owned_hashes.deinit();
    }
    var owned_block_hashes = std.ArrayList([][]const u8).init(allocator);
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
}

fn evalReadonlyDbQmod(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8, grant_entries: []const []const u8, params_path: ?[]const u8) ExecError!?u64 {
    const table_name = try singleReadGrant(grant_entries) orelse return null;
    if (std.mem.indexOf(u8, source, "store ") != null or std.mem.indexOf(u8, source, "atomic_rmw_") != null) return null;

    var read_table = try loadReadTable(allocator, table_name);
    defer read_table.deinit(allocator);
    var values = ValueMap.init(allocator);
    defer values.deinit();
    var pointers = std.StringHashMap(*const TableColumn).init(allocator);
    defer pointers.deinit();
    parseDbFunctionParams(allocator, source, main_name, read_table, params_path, &values, &pointers) catch |err| switch (err) {
        ExecError.UnsupportedOperation => return null,
        else => return err,
    };

    var labels = std.StringHashMap(usize).init(allocator);
    defer labels.deinit();
    const lines = try collectExecutableLines(allocator, source, main_name, &labels);
    defer allocator.free(lines);

    var pc: usize = 0;
    var steps: usize = 0;
    while (pc < lines.len) {
        steps += 1;
        if (steps > 1_000_000) return ExecError.UnsupportedOperation;
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

fn evalWriteDbQmod(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8, grant_entries: []const []const u8, params_path: ?[]const u8) ExecError!?u64 {
    const table_name = try singleWriteGrant(grant_entries) orelse return null;
    if (std.mem.indexOf(u8, source, " load ") != null or std.mem.indexOf(u8, source, "atomic_rmw_") != null) return null;

    var write_lock = try acquireTableWriteLock(allocator, table_name);
    defer write_lock.release();

    var write_table = try loadWriteTable(allocator, table_name);
    defer write_table.deinit(allocator);
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
    var steps: usize = 0;
    while (pc < lines.len) {
        steps += 1;
        if (steps > 1_000_000) return ExecError.UnsupportedOperation;
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

fn evalReadWriteDbQmod(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8, grant_entries: []const []const u8, params_path: ?[]const u8) ExecError!?u64 {
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
    var steps: usize = 0;
    while (pc < lines.len) {
        steps += 1;
        if (steps > 1_000_000) return ExecError.UnsupportedOperation;
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

fn evalAtomicDbQmod(allocator: std.mem.Allocator, source: []const u8, main_name: []const u8, grant_entries: []const []const u8, params_path: ?[]const u8) ExecError!?u64 {
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
    var steps: usize = 0;
    while (pc < lines.len) {
        steps += 1;
        if (steps > 1_000_000) return ExecError.UnsupportedOperation;
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

    const meta = QueryMeta{
        .magic = "sa-db-qmod-meta",
        .version = 1,
        .hash = hash_hex,
        .source_path = source_path,
        .qmod_path = qmod_path,
        .imports = imports,
        .grants = grants.entries.len,
        .grant_entries = grants.entries,
        .main = main_name,
    };
    const json = std.json.stringifyAlloc(allocator, meta, .{}) catch return ExecError.OutOfMemory;
    defer allocator.free(json);
    try writeFile(meta_path, json);

    return .{
        .hash = hash,
        .qmod_path = qmod_path,
        .meta_path = meta_path,
        .source_path = try allocator.dupe(u8, source_path),
        .imports = imports,
        .grants = grants.entries.len,
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
    if (!std.mem.eql(u8, parsed.value.magic, "sa-db-qmod-meta") or parsed.value.version != 1) {
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
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    out.writer().print("hash: {s}\n", .{parsed.value.hash}) catch return ExecError.OutOfMemory;
    out.writer().print("source: {s}\n", .{parsed.value.source_path}) catch return ExecError.OutOfMemory;
    out.writer().print("qmod: {s}\n", .{parsed.value.qmod_path}) catch return ExecError.OutOfMemory;
    out.writer().print("imports: {d}\n", .{parsed.value.imports}) catch return ExecError.OutOfMemory;
    out.writer().print("grants: {d}\n", .{parsed.value.grants}) catch return ExecError.OutOfMemory;
    for (parsed.value.grant_entries) |entry| {
        out.writer().print("grant: {s}\n", .{entry}) catch return ExecError.OutOfMemory;
    }
    out.writer().print("main: {s}\n", .{parsed.value.main}) catch return ExecError.OutOfMemory;
    return out.toOwnedSlice() catch return ExecError.OutOfMemory;
}

pub fn execQuery(allocator: std.mem.Allocator, hash_text: []const u8, params_path: ?[]const u8) ExecError!ExecRun {
    var parsed = try loadMeta(allocator, hash_text);
    defer parsed.deinit();
    if (params_path) |path| {
        const params = try readFileAlloc(allocator, path, 64 * 1024 * 1024);
        allocator.free(params);
    }
    const hash = try parseHashHex(parsed.value.hash);
    const qmod_source = readFileAlloc(allocator, parsed.value.qmod_path, 16 * 1024 * 1024) catch |err| switch (err) {
        ExecError.FileNotFound => return ExecError.QueryPayloadCorrupted,
        else => return err,
    };
    defer allocator.free(qmod_source);
    if (!std.mem.eql(u8, &hashBytes(qmod_source), &hash)) return ExecError.QueryPayloadCorrupted;
    const scalar_result = evalScalarQmod(allocator, qmod_source, parsed.value.main, params_path) catch |err| switch (err) {
        ExecError.UnsupportedOperation => null,
        else => return err,
    };
    const db_result = if (scalar_result == null)
        (evalReadonlyDbQmod(allocator, qmod_source, parsed.value.main, parsed.value.grant_entries, params_path) catch |err| switch (err) {
            ExecError.UnsupportedOperation => null,
            else => return err,
        })
    else
        null;
    const write_result = if (scalar_result == null and db_result == null)
        (evalWriteDbQmod(allocator, qmod_source, parsed.value.main, parsed.value.grant_entries, params_path) catch |err| switch (err) {
            ExecError.UnsupportedOperation => null,
            else => return err,
        })
    else
        null;
    const read_write_result = if (scalar_result == null and db_result == null and write_result == null)
        (evalReadWriteDbQmod(allocator, qmod_source, parsed.value.main, parsed.value.grant_entries, params_path) catch |err| switch (err) {
            ExecError.UnsupportedOperation => null,
            else => return err,
        })
    else
        null;
    const atomic_result = if (scalar_result == null and db_result == null and write_result == null and read_write_result == null)
        (evalAtomicDbQmod(allocator, qmod_source, parsed.value.main, parsed.value.grant_entries, params_path) catch |err| switch (err) {
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
    } };
}

test "qmod register inspect and exec metadata round trip" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var query = try tmp.dir.createFile("simple.query.sa", .{ .truncate = true });
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

    var params = try tmp.dir.createFile("params.bin", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var first = try tmp.dir.createFile("first.query.sa", .{ .truncate = true });
    defer first.close();
    try first.writeAll(
        \\@main() -> u64:
        \\L_ENTRY:
        \\return 1
    );
    var second = try tmp.dir.createFile("second.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var first = try tmp.dir.createFile("first.query.sa", .{ .truncate = true });
    defer first.close();
    try first.writeAll(
        \\@main() -> u64:
        \\L_ENTRY:
        \\return 1
    );
    var second = try tmp.dir.createFile("second.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var query = try tmp.dir.createFile("simple.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var query = try tmp.dir.createFile("simple.query.sa", .{ .truncate = true });
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

    try std.fs.cwd().deleteFile(result.qmod_path);

    try std.testing.expectError(ExecError.QueryPayloadCorrupted, execQuery(std.testing.allocator, hash_hex, null));
}

test "qmod register rejects duplicate hash from different source path" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const query_text =
        \\grants [db_read:simple]
        \\@main(lhs: u64) -> u64:
        \\L_ENTRY:
        \\return lhs
    ;

    var first = try tmp.dir.createFile("first.query.sa", .{ .truncate = true });
    defer first.close();
    try first.writeAll(query_text);

    var second = try tmp.dir.createFile("second.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var query = try tmp.dir.createFile("scalar.query.sa", .{ .truncate = true });
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

    var params = try tmp.dir.createFile("params.bin", .{ .truncate = true });
    defer params.close();
    var param_bytes: [24]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 7, .little);
    std.mem.writeInt(u64, param_bytes[8..16], 5, .little);
    std.mem.writeInt(u64, param_bytes[16..24], 99, .little);
    try params.writeAll(&param_bytes);

    try std.testing.expectError(ExecError.InvalidParams, execQuery(std.testing.allocator, hash_hex, "params.bin"));
}

test "qmod exec supports scalar bitwise and shift ops" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var query = try tmp.dir.createFile("bitwise.query.sa", .{ .truncate = true });
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

    var params = try tmp.dir.createFile("params.bin", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    {
        var query = try tmp.dir.createFile("missing_read.query.sa", .{ .truncate = true });
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
        var query = try tmp.dir.createFile("missing_write.query.sa", .{ .truncate = true });
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
        var query = try tmp.dir.createFile("missing_cursor.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try tmp.dir.createFile("missing_column.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try tmp.dir.createFile("wrong_pointer.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try tmp.dir.createFile("helper_pointer.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try tmp.dir.createFile("bad_pointer_type.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try tmp.dir.createFile("bad_store_column.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try tmp.dir.createFile("bad_store_pointer.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try tmp.dir.createFile("bad_atomic_pointer.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try tmp.dir.createFile("atomic_ok.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try tmp.dir.createFile("atomic_offset.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_COUNT_STRIDE = 4 // u32
        \\#def TABLE_ROW_BYTES = 4
    );
    var query = try tmp.dir.createFile("atomic_u32_base.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_SCORE_STRIDE = 4 // u32
        \\#def TABLE_ROW_BYTES = 12
    );
    var query = try tmp.dir.createFile("atomic_u32_named.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var query = try tmp.dir.createFile("atomic_helper_pointer.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv1 = try tmp.dir.createFile("rows1.csv", .{ .truncate = true });
    defer csv1.close();
    try csv1.writeAll(
        \\id
        \\1
        \\2
    );
    var csv2 = try tmp.dir.createFile("rows2.csv", .{ .truncate = true });
    defer csv2.close();
    try csv2.writeAll(
        \\id
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows1.csv");
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows2.csv");

    var query = try tmp.dir.createFile("sum.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var query = try tmp.dir.createFile("sum.query.sa", .{ .truncate = true });
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

    var drifted_schema = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var query = try tmp.dir.createFile("sum.query.sa", .{ .truncate = true });
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

    const meta_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.meta", .{"simple"});
    defer std.testing.allocator.free(meta_path);
    const meta_bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, meta_path, 1 << 20);
    defer std.testing.allocator.free(meta_bytes);
    var parsed = try std.json.parseFromSlice(QmodTableMeta, std.testing.allocator, meta_bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    var file = try std.fs.cwd().openFile(parsed.value.segments[0].files[0].path, .{ .mode = .read_write });
    defer file.close();
    const end_pos = try file.getEndPos();
    try file.seekTo(end_pos);
    try file.writeAll("x");

    try std.testing.expectError(ExecError.SnapshotCorrupted, execQuery(std.testing.allocator, hash_hex, null));
}

test "qmod exec rejects table snapshot block checksum metadata drift" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try table_mod.ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var query = try tmp.dir.createFile("sum.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var query = try tmp.dir.createFile("sum.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var params_file = try tmp.dir.createFile("params.bin", .{ .truncate = true });
    defer params_file.close();
    var param_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 1, .little);
    std.mem.writeInt(u64, param_bytes[8..16], 9, .little);
    try params_file.writeAll(&param_bytes);

    var write_query = try tmp.dir.createFile("write.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var params_file = try tmp.dir.createFile("params.bin", .{ .truncate = true });
    defer params_file.close();
    var param_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 1, .little);
    std.mem.writeInt(u64, param_bytes[8..16], 9, .little);
    try params_file.writeAll(&param_bytes);

    var write_query = try tmp.dir.createFile("write.query.sa", .{ .truncate = true });
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

    var read_query = try tmp.dir.createFile("sum.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var params_file = try tmp.dir.createFile("params.bin", .{ .truncate = true });
    defer params_file.close();
    var param_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 1, .little);
    std.mem.writeInt(u64, param_bytes[8..16], 7, .little);
    try params_file.writeAll(&param_bytes);

    var update_query = try tmp.dir.createFile("update.query.sa", .{ .truncate = true });
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

    var read_query = try tmp.dir.createFile("sum.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var src_schema = try tmp.dir.createFile("src.sadb-schema", .{ .truncate = true });
    defer src_schema.close();
    try src_schema.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var dst_schema = try tmp.dir.createFile("dst.sadb-schema", .{ .truncate = true });
    defer dst_schema.close();
    try dst_schema.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_SCORE_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var src_csv = try tmp.dir.createFile("src.csv", .{ .truncate = true });
    defer src_csv.close();
    try src_csv.writeAll(
        \\id
        \\1
        \\2
    );
    var dst_csv = try tmp.dir.createFile("dst.csv", .{ .truncate = true });
    defer dst_csv.close();
    try dst_csv.writeAll(
        \\score
        \\0
        \\0
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "src", "src.csv");
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "dst", "dst.csv");

    var params_file = try tmp.dir.createFile("params.bin", .{ .truncate = true });
    defer params_file.close();
    var param_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 1, .little);
    std.mem.writeInt(u64, param_bytes[8..16], 10, .little);
    try params_file.writeAll(&param_bytes);

    var copy_query = try tmp.dir.createFile("copy.query.sa", .{ .truncate = true });
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

    var read_query = try tmp.dir.createFile("sum_dst.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\5
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var atomic_query = try tmp.dir.createFile("atomic.query.sa", .{ .truncate = true });
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

    var read_query = try tmp.dir.createFile("sum.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\5
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var atomic_query = try tmp.dir.createFile("atomic_dynamic_offset.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_SCORE_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 16
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id,score
        \\5,7
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var atomic_query = try tmp.dir.createFile("atomic_score.query.sa", .{ .truncate = true });
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

    var read_query = try tmp.dir.createFile("read.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\5
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");
    _ = try @import("table.zig").lockTable(std.testing.allocator, ".", "simple");

    var write_query = try tmp.dir.createFile("write.query.sa", .{ .truncate = true });
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

    var atomic_query = try tmp.dir.createFile("atomic.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv1 = try tmp.dir.createFile("rows1.csv", .{ .truncate = true });
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

    var csv2 = try tmp.dir.createFile("rows2.csv", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var query = try tmp.dir.createFile("count_gt.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var query = try tmp.dir.createFile("count_odd.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("compact.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_SCORE_STRIDE = 4 // u32
        \\#def TABLE_ROW_BYTES = 4
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\score
        \\70000
        \\2
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "compact", "rows.csv");

    var query = try tmp.dir.createFile("sum_u32.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("signed.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_DELTA_STRIDE = 4 // i32
        \\#def TABLE_ROW_BYTES = 4
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\delta
        \\-2
        \\5
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "signed", "rows.csv");

    var query = try tmp.dir.createFile("sum_i32.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var params_file = try tmp.dir.createFile("params.bin", .{ .truncate = true });
    defer params_file.close();
    var param_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 1, .little);
    try params_file.writeAll(&param_bytes);

    var query = try tmp.dir.createFile("count_param.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("simple.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def TABLE_ROW_BYTES = 8
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\id
        \\1
        \\2
        \\3
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "simple", "rows.csv");

    var params_file = try tmp.dir.createFile("params.bin", .{ .truncate = true });
    defer params_file.close();
    var param_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], 1, .little);
    std.mem.writeInt(u64, param_bytes[8..16], 99, .little);
    try params_file.writeAll(&param_bytes);

    var query = try tmp.dir.createFile("count_param.query.sa", .{ .truncate = true });
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
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var schema_file = try tmp.dir.createFile("prices.sadb-schema", .{ .truncate = true });
    defer schema_file.close();
    try schema_file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_PRICE_STRIDE = 4 // f32
        \\#def TABLE_ROW_BYTES = 4
    );
    var csv = try tmp.dir.createFile("rows.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writeAll(
        \\price
        \\9.5
        \\12.25
        \\20.0
    );
    _ = try @import("table.zig").ingestTable(std.testing.allocator, ".", "prices", "rows.csv");

    var params_file = try tmp.dir.createFile("params.bin", .{ .truncate = true });
    defer params_file.close();
    var param_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, param_bytes[0..8], @as(u64, @bitCast(@as(f64, 10.0))), .little);
    try params_file.writeAll(&param_bytes);

    var query = try tmp.dir.createFile("count_price.query.sa", .{ .truncate = true });
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
