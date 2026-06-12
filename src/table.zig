const std = @import("std");
const builtin = @import("builtin");
const schema = @import("schema.zig");

var temp_write_counter = std.atomic.Value(u64).init(0);

pub const TableError = error{
    OutOfMemory,
    InvalidFormat,
    InvalidPath,
    NotFound,
    Locked,
    CursorOverflow,
    SnapshotMissing,
    VerifyFailed,
};

pub const TableInfo = struct {
    row_count: u64,
    segment_count: usize,
    epoch: u64,
    locked: bool,
};

pub const RawColumnBytes = struct {
    bytes: []const u8,
};

pub const ColumnMeta = struct {
    name: []const u8,
    stride: u32,
    ty: []const u8,
};

pub const FileMeta = struct {
    path: []const u8,
    sha256: []const u8,
    bytes: u64,
};

pub const SegmentMeta = struct {
    id: u64,
    rows: u64,
    files: []FileMeta,
};

pub const TableMeta = struct {
    magic: []const u8,
    version: u32,
    table_name: []const u8,
    schema_path: []const u8,
    schema_hash: []const u8,
    locked: bool,
    epoch: u64,
    row_count: u64,
    max_rows: u64,
    row_bytes: u64,
    next_segment_id: u64,
    columns: []ColumnMeta,
    segments: []SegmentMeta,

    pub fn deinit(self: *TableMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.magic);
        allocator.free(self.table_name);
        allocator.free(self.schema_path);
        allocator.free(self.schema_hash);
        for (self.columns) |column| {
            allocator.free(column.name);
            allocator.free(column.ty);
        }
        allocator.free(self.columns);
        for (self.segments) |segment| {
            for (segment.files) |file| {
                allocator.free(file.path);
                allocator.free(file.sha256);
            }
            allocator.free(segment.files);
        }
        allocator.free(self.segments);
        self.* = undefined;
    }
};

pub const TableManifest = struct {
    magic: []const u8,
    version: u32,
    table_name: []const u8,
    epoch: u64,
    meta_path: []const u8,
    meta_sha256: []const u8,
    meta_bytes: u64,
};

pub const ReadColumnSnapshot = struct {
    bytes: []const u8,
};

pub const ReadSegmentSnapshot = struct {
    rows: u64,
    columns: []ReadColumnSnapshot,
};

pub const U64CompareOp = enum(u32) {
    eq = 0,
    ne = 1,
    lt = 2,
    le = 3,
    gt = 4,
    ge = 5,
};

pub const U64FindResult = struct {
    found: bool,
    row_index: u64,
};

pub const ReadSnapshot = struct {
    backing_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    table_name: []const u8,
    epoch: u64,
    row_count: u64,
    columns: []ColumnMeta,
    segments: []ReadSegmentSnapshot,

    pub fn destroy(self: *ReadSnapshot) void {
        const backing_allocator = self.backing_allocator;
        self.arena.deinit();
        backing_allocator.destroy(self);
    }
};

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn rootPrefix(root_dir: []const u8) []const u8 {
    const trimmed = trim(root_dir);
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".")) return "";
    return trimmed;
}

fn hashBytes(bytes: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn hashHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) TableError![]u8 {
    const hash = hashBytes(bytes);
    const encoded = std.fmt.bytesToHex(hash, .lower);
    return allocator.dupe(u8, encoded[0..]) catch TableError.OutOfMemory;
}

fn mapFileError(err: anyerror) TableError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.NotFound,
        error.InvalidPath => error.InvalidPath,
        error.AccessDenied => error.InvalidPath,
        error.PathAlreadyExists => error.InvalidFormat,
        error.FileTooBig => error.InvalidFormat,
        error.IsDir => error.InvalidFormat,
        error.Unexpected => error.InvalidFormat,
        else => error.InvalidFormat,
    };
}

fn mapJsonError(err: anyerror) TableError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidFormat,
    };
}

fn mapSchemaError(err: anyerror) TableError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidFormat,
    };
}

fn joinPath(allocator: std.mem.Allocator, parts: []const []const u8) TableError![]u8 {
    return std.fs.path.join(allocator, parts) catch |err| return mapFileError(err);
}

fn allocPrintPath(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) TableError![]u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch TableError.OutOfMemory;
}

fn activePath(allocator: std.mem.Allocator, root_dir: []const u8, basename: []const u8) TableError![]u8 {
    const prefix = rootPrefix(root_dir);
    if (prefix.len == 0) return allocator.dupe(u8, basename) catch TableError.OutOfMemory;
    return joinPath(allocator, &.{ prefix, basename });
}

fn tableMetaPath(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError![]u8 {
    const basename = try allocPrintPath(allocator, "{s}.meta", .{table_name});
    errdefer allocator.free(basename);
    const path = try activePath(allocator, root_dir, basename);
    allocator.free(basename);
    return path;
}

fn tableManifestPath(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError![]u8 {
    const basename = try allocPrintPath(allocator, "{s}.manifest", .{table_name});
    errdefer allocator.free(basename);
    const path = try activePath(allocator, root_dir, basename);
    allocator.free(basename);
    return path;
}

fn tableVersionedMetaName(allocator: std.mem.Allocator, table_name: []const u8, epoch: u64) TableError![]u8 {
    return allocPrintPath(allocator, "{s}.meta.{d}", .{ table_name, epoch });
}

fn tableVersionedMetaPath(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, epoch: u64) TableError![]u8 {
    const basename = try tableVersionedMetaName(allocator, table_name, epoch);
    errdefer allocator.free(basename);
    const path = try activePath(allocator, root_dir, basename);
    allocator.free(basename);
    return path;
}

fn schemaMetaPath(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError![]u8 {
    const basename = try allocPrintPath(allocator, "{s}.sadb-schema", .{table_name});
    errdefer allocator.free(basename);
    const path = try activePath(allocator, root_dir, basename);
    allocator.free(basename);
    return path;
}

fn segmentFileName(allocator: std.mem.Allocator, table_name: []const u8, seg_id: u64, column_index: usize) TableError![]u8 {
    return allocPrintPath(allocator, "{s}.col{d}.{d}.dat", .{ table_name, column_index, seg_id });
}

fn snapshotDir(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, epoch: u64) TableError![]u8 {
    const epoch_text = try allocPrintPath(allocator, "{d}", .{epoch});
    errdefer allocator.free(epoch_text);
    const prefix = rootPrefix(root_dir);
    const path = if (prefix.len == 0)
        try joinPath(allocator, &.{ ".sa", "db", "snapshots", table_name, epoch_text })
    else
        try joinPath(allocator, &.{ prefix, ".sa", "db", "snapshots", table_name, epoch_text });
    allocator.free(epoch_text);
    return path;
}

fn ensureParentDir(path: []const u8) TableError!void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len != 0) {
            std.fs.cwd().makePath(dir) catch |err| return mapFileError(err);
        }
    }
}

fn deleteIfExists(path: []const u8) TableError!void {
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return mapFileError(err),
    };
}

fn deleteTreeIfExists(path: []const u8) TableError!void {
    std.fs.cwd().deleteTree(path) catch return;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) TableError![]u8 {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| return mapFileError(err);
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes) catch |err| return mapFileError(err);
}

fn tempWritePath(allocator: std.mem.Allocator, path: []const u8) TableError![]u8 {
    const parent = std.fs.path.dirname(path);
    const basename = std.fs.path.basename(path);
    const counter = temp_write_counter.fetchAdd(1, .monotonic);
    const random = std.crypto.random.int(u64);
    const temp_name = try allocPrintPath(allocator, ".{s}.tmp.{x}.{x}", .{ basename, random, counter });
    errdefer allocator.free(temp_name);
    if (parent) |dir| {
        if (dir.len != 0) {
            const joined = try joinPath(allocator, &.{ dir, temp_name });
            allocator.free(temp_name);
            return joined;
        }
    }
    return temp_name;
}

fn syncParentDirBestEffort(path: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const dir_path = if (parent.len == 0) "." else parent;
    var dir = std.fs.cwd().openDir(dir_path, .{}) catch return;
    defer dir.close();
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.fsync(dir.fd);
    }
}

fn syncFile(path: []const u8) TableError!void {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| return mapFileError(err);
    defer file.close();
    file.sync() catch |err| return mapFileError(err);
}

fn writeFile(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) TableError!void {
    try ensureParentDir(path);
    const temp_path = try tempWritePath(allocator, path);
    defer allocator.free(temp_path);
    errdefer deleteIfExists(temp_path) catch {};

    {
        var file = std.fs.cwd().createFile(temp_path, .{ .truncate = true, .exclusive = true }) catch |err| return mapFileError(err);
        defer file.close();
        file.writeAll(bytes) catch |err| return mapFileError(err);
        file.sync() catch |err| return mapFileError(err);
    }

    std.fs.cwd().rename(temp_path, path) catch |err| return mapFileError(err);
    syncParentDirBestEffort(path);
}

fn copyFile(allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) TableError!void {
    try ensureParentDir(dst_path);
    const temp_path = try tempWritePath(allocator, dst_path);
    defer allocator.free(temp_path);
    errdefer deleteIfExists(temp_path) catch {};

    std.fs.Dir.copyFile(std.fs.cwd(), src_path, std.fs.cwd(), temp_path, .{}) catch |err| return mapFileError(err);
    try syncFile(temp_path);
    std.fs.cwd().rename(temp_path, dst_path) catch |err| return mapFileError(err);
    syncParentDirBestEffort(dst_path);
}

fn hashHex(bytes: []const u8) [64]u8 {
    return std.fmt.bytesToHex(hashBytes(bytes), .lower);
}

fn parseTableMeta(allocator: std.mem.Allocator, source: []const u8) TableError!std.json.Parsed(TableMeta) {
    const parsed = std.json.parseFromSlice(TableMeta, allocator, source, .{}) catch |err| return mapJsonError(err);
    if (!std.mem.eql(u8, parsed.value.magic, "sa-db-table-meta")) {
        parsed.deinit();
        return TableError.InvalidFormat;
    }
    if (parsed.value.version != 1) {
        parsed.deinit();
        return TableError.InvalidFormat;
    }
    return parsed;
}

fn parseTableManifest(allocator: std.mem.Allocator, source: []const u8) TableError!std.json.Parsed(TableManifest) {
    const parsed = std.json.parseFromSlice(TableManifest, allocator, source, .{}) catch |err| return mapJsonError(err);
    if (!std.mem.eql(u8, parsed.value.magic, "sa-db-table-manifest")) {
        parsed.deinit();
        return TableError.InvalidFormat;
    }
    if (parsed.value.version != 1) {
        parsed.deinit();
        return TableError.InvalidFormat;
    }
    return parsed;
}

pub fn readActiveMetaSource(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError![]u8 {
    const manifest_path = try tableManifestPath(allocator, root_dir, table_name);
    defer allocator.free(manifest_path);

    const manifest_source = readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| switch (err) {
        TableError.NotFound => {
            const compat_meta_path = try tableMetaPath(allocator, root_dir, table_name);
            defer allocator.free(compat_meta_path);
            return try readFileAlloc(allocator, compat_meta_path, 16 * 1024 * 1024);
        },
        else => return err,
    };
    defer allocator.free(manifest_source);

    var manifest = try parseTableManifest(allocator, manifest_source);
    defer manifest.deinit();
    if (!std.mem.eql(u8, manifest.value.table_name, table_name)) return TableError.InvalidFormat;

    const meta_path = try activePath(allocator, root_dir, manifest.value.meta_path);
    defer allocator.free(meta_path);
    const meta_source = try readFileAlloc(allocator, meta_path, 16 * 1024 * 1024);
    errdefer allocator.free(meta_source);
    if (meta_source.len != manifest.value.meta_bytes) return TableError.VerifyFailed;
    const meta_hash = hashBytes(meta_source);
    const meta_hex = std.fmt.bytesToHex(meta_hash, .lower);
    if (!std.mem.eql(u8, meta_hex[0..], manifest.value.meta_sha256)) return TableError.VerifyFailed;

    var parsed_meta = try parseTableMeta(allocator, meta_source);
    defer parsed_meta.deinit();
    if (!std.mem.eql(u8, parsed_meta.value.table_name, table_name)) return TableError.InvalidFormat;
    if (parsed_meta.value.epoch != manifest.value.epoch) return TableError.VerifyFailed;

    return meta_source;
}

pub fn loadActiveMeta(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError!TableMeta {
    const source = try readActiveMetaSource(allocator, root_dir, table_name);
    defer allocator.free(source);
    var parsed = try parseTableMeta(allocator, source);
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.table_name, table_name)) return TableError.InvalidFormat;
    return try duplicateTableMeta(allocator, parsed.value);
}

fn parseJsonValue(allocator: std.mem.Allocator, source: []const u8) TableError!std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch |err| return mapJsonError(err);
}

fn parsePrimTypeTable(text: []const u8) TableError!schema.PrimType {
    return schema.parsePrimType(text) catch |err| switch (err) {
        error.OutOfMemory => TableError.OutOfMemory,
        else => TableError.InvalidFormat,
    };
}

fn effectivePrimType(column: schema.Column) TableError!schema.PrimType {
    if (column.ty) |ty| return ty;
    return switch (column.stride) {
        1 => .u8,
        2 => .u16,
        4 => .u32,
        8 => .u64,
        else => TableError.InvalidFormat,
    };
}

fn duplicateColumns(allocator: std.mem.Allocator, columns: []const schema.Column) TableError![]ColumnMeta {
    const out = try allocator.alloc(ColumnMeta, columns.len);
    errdefer {
        for (out) |column| {
            allocator.free(column.name);
            allocator.free(column.ty);
        }
        allocator.free(out);
    }
    for (columns, 0..) |column, idx| {
        const ty = try effectivePrimType(column);
        out[idx] = .{
            .name = try allocator.dupe(u8, column.name),
            .stride = column.stride,
            .ty = try allocator.dupe(u8, schema.primTypeName(ty)),
        };
    }
    return out;
}

fn duplicateTableMeta(allocator: std.mem.Allocator, meta: TableMeta) TableError!TableMeta {
    const columns = try allocator.alloc(ColumnMeta, meta.columns.len);
    errdefer {
        for (columns) |column| {
            allocator.free(column.name);
            allocator.free(column.ty);
        }
        allocator.free(columns);
    }
    for (meta.columns, 0..) |column, idx| {
        columns[idx] = .{
            .name = try allocator.dupe(u8, column.name),
            .stride = column.stride,
            .ty = try allocator.dupe(u8, column.ty),
        };
    }

    const segments = try allocator.alloc(SegmentMeta, meta.segments.len);
    errdefer {
        for (segments) |segment| {
            for (segment.files) |file| {
                allocator.free(file.path);
                allocator.free(file.sha256);
            }
            allocator.free(segment.files);
        }
        allocator.free(segments);
    }
    for (meta.segments, 0..) |segment, idx| {
        const files = try allocator.alloc(FileMeta, segment.files.len);
        errdefer {
            for (files) |file| {
                allocator.free(file.path);
                allocator.free(file.sha256);
            }
            allocator.free(files);
        }
        for (segment.files, 0..) |file, file_idx| {
            files[file_idx] = .{
                .path = try allocator.dupe(u8, file.path),
                .sha256 = try allocator.dupe(u8, file.sha256),
                .bytes = file.bytes,
            };
        }
        segments[idx] = .{
            .id = segment.id,
            .rows = segment.rows,
            .files = files,
        };
    }

    return .{
        .magic = try allocator.dupe(u8, meta.magic),
        .version = meta.version,
        .table_name = try allocator.dupe(u8, meta.table_name),
        .schema_path = try allocator.dupe(u8, meta.schema_path),
        .schema_hash = try allocator.dupe(u8, meta.schema_hash),
        .locked = meta.locked,
        .epoch = meta.epoch,
        .row_count = meta.row_count,
        .max_rows = meta.max_rows,
        .row_bytes = meta.row_bytes,
        .next_segment_id = meta.next_segment_id,
        .columns = columns,
        .segments = segments,
    };
}

fn buildInitialMeta(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    schema_path: []const u8,
    schema_hash_hex: []const u8,
    schema_obj: schema.Schema,
) TableError!TableMeta {
    return .{
        .magic = try allocator.dupe(u8, "sa-db-table-meta"),
        .version = 1,
        .table_name = try allocator.dupe(u8, table_name),
        .schema_path = try allocator.dupe(u8, schema_path),
        .schema_hash = try allocator.dupe(u8, schema_hash_hex),
        .locked = false,
        .epoch = 0,
        .row_count = 0,
        .max_rows = schema_obj.max_rows,
        .row_bytes = schema_obj.row_bytes,
        .next_segment_id = 0,
        .columns = try duplicateColumns(allocator, schema_obj.columns),
        .segments = try allocator.alloc(SegmentMeta, 0),
    };
}

fn loadSchema(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError!schema.Schema {
    const path = try schemaMetaPath(allocator, root_dir, table_name);
    defer allocator.free(path);
    const source = try readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(source);
    return schema.compile(allocator, source, path) catch |err| switch (err) {
        error.OutOfMemory => TableError.OutOfMemory,
        else => TableError.InvalidFormat,
    };
}

fn schemaHashFromFile(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError![]u8 {
    const path = try schemaMetaPath(allocator, root_dir, table_name);
    defer allocator.free(path);
    const source = try readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(source);
    return try hashHexAlloc(allocator, source);
}

fn makeFileMeta(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) TableError!FileMeta {
    return .{
        .path = try allocator.dupe(u8, path),
        .sha256 = try hashHexAlloc(allocator, bytes),
        .bytes = bytes.len,
    };
}

fn writeSegmentFiles(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    seg_id: u64,
    buffers: []std.ArrayList(u8),
) TableError![]FileMeta {
    const files = try allocator.alloc(FileMeta, buffers.len);
    errdefer {
        for (files) |file| {
            allocator.free(file.path);
            allocator.free(file.sha256);
        }
        allocator.free(files);
    }

    for (buffers, 0..) |buffer, idx| {
        const basename = try segmentFileName(allocator, table_name, seg_id, idx);
        defer allocator.free(basename);
        const path = try activePath(allocator, root_dir, basename);
        defer allocator.free(path);
        try writeFile(allocator, path, buffer.items);
        files[idx] = try makeFileMeta(allocator, basename, buffer.items);
    }

    return files;
}

fn freeFileMetas(allocator: std.mem.Allocator, files: []FileMeta) void {
    for (files) |file| {
        allocator.free(file.path);
        allocator.free(file.sha256);
    }
    allocator.free(files);
}

fn freeSegmentMetas(allocator: std.mem.Allocator, segments: []SegmentMeta) void {
    for (segments) |segment| {
        freeFileMetas(allocator, segment.files);
    }
    allocator.free(segments);
}

fn duplicateSegmentMetas(allocator: std.mem.Allocator, segments: []const SegmentMeta) TableError![]SegmentMeta {
    const out = try allocator.alloc(SegmentMeta, segments.len);
    errdefer {
        for (out) |segment| {
            freeFileMetas(allocator, segment.files);
        }
        allocator.free(out);
    }

    for (segments, 0..) |segment, idx| {
        const files = try allocator.alloc(FileMeta, segment.files.len);
        errdefer {
            for (files) |file| {
                allocator.free(file.path);
                allocator.free(file.sha256);
            }
            allocator.free(files);
        }
        for (segment.files, 0..) |file, file_idx| {
            files[file_idx] = .{
                .path = try allocator.dupe(u8, file.path),
                .sha256 = try allocator.dupe(u8, file.sha256),
                .bytes = file.bytes,
            };
        }
        out[idx] = .{
            .id = segment.id,
            .rows = segment.rows,
            .files = files,
        };
    }

    return out;
}

fn appendSegmentToMeta(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    meta: *TableMeta,
    buffers: []std.ArrayList(u8),
    row_count: u64,
) TableError!void {
    const old_segments = meta.segments;
    const preserved_segments = try duplicateSegmentMetas(allocator, old_segments);
    errdefer freeSegmentMetas(allocator, preserved_segments);

    const files = try writeSegmentFiles(allocator, root_dir, table_name, meta.next_segment_id, buffers);
    errdefer freeFileMetas(allocator, files);

    const new_segments = try allocator.alloc(SegmentMeta, preserved_segments.len + 1);
    errdefer allocator.free(new_segments);
    @memcpy(new_segments[0..preserved_segments.len], preserved_segments);
    new_segments[preserved_segments.len] = .{
        .id = meta.next_segment_id,
        .rows = row_count,
        .files = files,
    };

    freeSegmentMetas(allocator, old_segments);
    allocator.free(preserved_segments);
    meta.segments = new_segments;
    meta.row_count = std.math.add(u64, meta.row_count, row_count) catch return TableError.CursorOverflow;
    meta.epoch += 1;
    meta.next_segment_id += 1;
}

fn mergeSegmentFiles(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    meta: *const TableMeta,
    new_seg_id: u64,
) TableError![]FileMeta {
    const files = try allocator.alloc(FileMeta, meta.columns.len);
    errdefer freeFileMetas(allocator, files);

    for (0..meta.columns.len) |col_idx| {
        var merged = std.ArrayList(u8).init(allocator);
        errdefer merged.deinit();
        for (meta.segments) |segment| {
            const file_meta = segment.files[col_idx];
            const path = try activePath(allocator, root_dir, file_meta.path);
            defer allocator.free(path);
            const bytes = try readFileAlloc(allocator, path, 1 << 30);
            defer allocator.free(bytes);
            try merged.appendSlice(bytes);
        }
        const basename = try segmentFileName(allocator, table_name, new_seg_id, col_idx);
        defer allocator.free(basename);
        const dst_path = try activePath(allocator, root_dir, basename);
        defer allocator.free(dst_path);
        try writeFile(allocator, dst_path, merged.items);
        files[col_idx] = try makeFileMeta(allocator, basename, merged.items);
        merged.deinit();
    }

    return files;
}

fn tableInfo(meta: TableMeta) TableInfo {
    return .{
        .row_count = meta.row_count,
        .segment_count = meta.segments.len,
        .epoch = meta.epoch,
        .locked = meta.locked,
    };
}

fn loadCurrentMeta(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    schema_obj: schema.Schema,
    schema_path: []const u8,
    schema_hex: []const u8,
) TableError!TableMeta {
    var meta = loadActiveMeta(allocator, root_dir, table_name) catch |err| switch (err) {
        TableError.NotFound => return try buildInitialMeta(allocator, table_name, schema_path, schema_hex, schema_obj),
        else => return err,
    };
    errdefer meta.deinit(allocator);
    if (!std.mem.eql(u8, meta.schema_hash, schema_hex)) return TableError.InvalidFormat;
    try verifySchemaAgainstMeta(schema_obj, meta);
    return meta;
}

fn verifySchemaAgainstMeta(schema_obj: schema.Schema, meta: TableMeta) TableError!void {
    if (schema_obj.columns.len != meta.columns.len) return TableError.InvalidFormat;
    if (schema_obj.row_bytes != meta.row_bytes) return TableError.InvalidFormat;
    if (schema_obj.max_rows != meta.max_rows) return TableError.InvalidFormat;
    for (schema_obj.columns, 0..) |column, idx| {
        const meta_column = meta.columns[idx];
        const ty = try effectivePrimType(column);
        if (!std.mem.eql(u8, column.name, meta_column.name)) return TableError.InvalidFormat;
        if (column.stride != meta_column.stride) return TableError.InvalidFormat;
        if (!std.mem.eql(u8, schema.primTypeName(ty), meta_column.ty)) return TableError.InvalidFormat;
    }
}

fn appendSnapshotArtifacts(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta) TableError!void {
    const snapshot_dir_path = try snapshotDir(allocator, root_dir, table_name, meta.epoch);
    defer allocator.free(snapshot_dir_path);
    try deleteTreeIfExists(snapshot_dir_path);
    std.fs.cwd().makePath(snapshot_dir_path) catch |err| return mapFileError(err);

    const snapshot_meta_name = try allocPrintPath(allocator, "{s}.meta", .{table_name});
    defer allocator.free(snapshot_meta_name);
    const snapshot_meta_path = try joinPath(allocator, &.{ snapshot_dir_path, snapshot_meta_name });
    defer allocator.free(snapshot_meta_path);
    const active_meta_source = try readActiveMetaSource(allocator, root_dir, table_name);
    defer allocator.free(active_meta_source);
    try writeFile(allocator, snapshot_meta_path, active_meta_source);

    const schema_path = try schemaMetaPath(allocator, root_dir, table_name);
    defer allocator.free(schema_path);
    const snapshot_schema_name = std.fs.path.basename(schema_path);
    const snapshot_schema_path = try joinPath(allocator, &.{ snapshot_dir_path, snapshot_schema_name });
    defer allocator.free(snapshot_schema_path);
    try copyFile(allocator, schema_path, snapshot_schema_path);

    for (meta.segments) |segment| {
        for (segment.files) |file| {
            const src_path = try activePath(allocator, root_dir, file.path);
            defer allocator.free(src_path);
            const dst_path = try joinPath(allocator, &.{ snapshot_dir_path, file.path });
            defer allocator.free(dst_path);
            try copyFile(allocator, src_path, dst_path);
        }
    }
}

fn restoreSnapshotArtifacts(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, epoch: u64) TableError!TableInfo {
    const snapshot_dir_path = try snapshotDir(allocator, root_dir, table_name, epoch);
    defer allocator.free(snapshot_dir_path);

    const snapshot_meta_name = try allocPrintPath(allocator, "{s}.meta", .{table_name});
    defer allocator.free(snapshot_meta_name);
    const snapshot_meta_path = try joinPath(allocator, &.{ snapshot_dir_path, snapshot_meta_name });
    defer allocator.free(snapshot_meta_path);
    const source = try readFileAlloc(allocator, snapshot_meta_path, 16 * 1024 * 1024);
    defer allocator.free(source);
    var parsed = try parseTableMeta(allocator, source);
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.table_name, table_name)) return TableError.InvalidFormat;

    const schema_path = try schemaMetaPath(allocator, root_dir, table_name);
    defer allocator.free(schema_path);

    const snapshot_schema_name = try allocPrintPath(allocator, "{s}.sadb-schema", .{table_name});
    defer allocator.free(snapshot_schema_name);
    const snapshot_schema_path = try joinPath(allocator, &.{ snapshot_dir_path, snapshot_schema_name });
    defer allocator.free(snapshot_schema_path);
    try copyFile(allocator, snapshot_schema_path, schema_path);

    for (parsed.value.segments) |segment| {
        for (segment.files) |file| {
            const src_path = try joinPath(allocator, &.{ snapshot_dir_path, file.path });
            defer allocator.free(src_path);
            const dst_path = try activePath(allocator, root_dir, file.path);
            defer allocator.free(dst_path);
            try copyFile(allocator, src_path, dst_path);
        }
    }

    var owned = try duplicateTableMeta(allocator, parsed.value);
    defer owned.deinit(allocator);
    try writeMeta(allocator, root_dir, table_name, owned);
    return tableInfo(parsed.value);
}

fn validateSegmentHashes(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta) TableError!void {
    const schema_path = try schemaMetaPath(allocator, root_dir, meta.table_name);
    defer allocator.free(schema_path);
    const schema_source = try readFileAlloc(allocator, schema_path, 16 * 1024 * 1024);
    defer allocator.free(schema_source);
    const schema_hash = hashBytes(schema_source);
    const schema_hex = std.fmt.bytesToHex(schema_hash, .lower);
    if (!std.mem.eql(u8, schema_hex[0..], meta.schema_hash)) return TableError.VerifyFailed;

    var total_rows: u64 = 0;
    for (meta.segments) |segment| {
        if (segment.files.len != meta.columns.len) return TableError.VerifyFailed;
        total_rows = std.math.add(u64, total_rows, segment.rows) catch return TableError.VerifyFailed;
        for (segment.files, 0..) |file, column_idx| {
            const expected_bytes = try expectedColumnBytes(segment.rows, meta.columns[column_idx].stride);
            if (file.bytes != @as(u64, @intCast(expected_bytes))) return TableError.VerifyFailed;
            const path = try activePath(allocator, root_dir, file.path);
            defer allocator.free(path);
            const bytes = try readFileAlloc(allocator, path, 1 << 30);
            defer allocator.free(bytes);
            const hash = hashBytes(bytes);
            const hex = std.fmt.bytesToHex(hash, .lower);
            if (!std.mem.eql(u8, hex[0..], file.sha256)) return TableError.VerifyFailed;
            if (bytes.len != expected_bytes) return TableError.VerifyFailed;
        }
    }
    if (total_rows != meta.row_count) return TableError.VerifyFailed;
}

fn makeReadonlyRecursive(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta) TableError!void {
    const schema_path = try schemaMetaPath(allocator, root_dir, meta.table_name);
    defer allocator.free(schema_path);
    if (std.fs.cwd().openFile(schema_path, .{})) |file| {
        var f = file;
        defer f.close();
        f.chmod(0o444) catch {};
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFileError(err),
    }

    const meta_path = try tableMetaPath(allocator, root_dir, meta.table_name);
    defer allocator.free(meta_path);
    if (std.fs.cwd().openFile(meta_path, .{})) |file| {
        var f = file;
        defer f.close();
        f.chmod(0o444) catch {};
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFileError(err),
    }

    const manifest_path = try tableManifestPath(allocator, root_dir, meta.table_name);
    defer allocator.free(manifest_path);
    if (std.fs.cwd().openFile(manifest_path, .{})) |file| {
        var f = file;
        defer f.close();
        f.chmod(0o444) catch {};
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFileError(err),
    }

    const versioned_meta_path = try tableVersionedMetaPath(allocator, root_dir, meta.table_name, meta.epoch);
    defer allocator.free(versioned_meta_path);
    if (std.fs.cwd().openFile(versioned_meta_path, .{})) |file| {
        var f = file;
        defer f.close();
        f.chmod(0o444) catch {};
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFileError(err),
    }

    for (meta.segments) |segment| {
        for (segment.files) |file_meta| {
            const path = try activePath(allocator, root_dir, file_meta.path);
            defer allocator.free(path);
            if (std.fs.cwd().openFile(path, .{})) |file| {
                var f = file;
                defer f.close();
                f.chmod(0o444) catch {};
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return mapFileError(err),
            }
        }
    }
}

fn validateRecoverCandidate(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta) TableError!void {
    if (!std.mem.eql(u8, meta.table_name, table_name)) return TableError.InvalidFormat;
    const schema_hash = try schemaHashFromFile(allocator, root_dir, table_name);
    defer allocator.free(schema_hash);
    if (!std.mem.eql(u8, meta.schema_hash, schema_hash)) return TableError.VerifyFailed;
    var schema_obj = try loadSchema(allocator, root_dir, table_name);
    defer schema_obj.deinit();
    try verifySchemaAgainstMeta(schema_obj, meta);
    try validateSegmentHashes(allocator, root_dir, meta);
}

fn maybeSelectRecoveryMeta(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    path: []const u8,
    best: *?TableMeta,
) TableError!void {
    const source = readFileAlloc(allocator, path, 16 * 1024 * 1024) catch return;
    defer allocator.free(source);
    var parsed = parseTableMeta(allocator, source) catch return;
    defer parsed.deinit();
    validateRecoverCandidate(allocator, root_dir, table_name, parsed.value) catch return;
    if (best.*) |current| {
        if (parsed.value.epoch <= current.epoch) return;
        var old = best.*.?;
        old.deinit(allocator);
        best.* = null;
    }
    best.* = try duplicateTableMeta(allocator, parsed.value);
}

fn scanVersionedRecoveryMetas(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    best: *?TableMeta,
) TableError!void {
    const dir_path = rootPrefix(root_dir);
    var dir = std.fs.cwd().openDir(if (dir_path.len == 0) "." else dir_path, .{ .iterate = true }) catch |err| return mapFileError(err);
    defer dir.close();

    const prefix = try allocPrintPath(allocator, "{s}.meta.", .{table_name});
    defer allocator.free(prefix);
    var it = dir.iterate();
    while (it.next() catch |err| return mapFileError(err)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        const epoch_text = entry.name[prefix.len..];
        if (epoch_text.len == 0) continue;
        _ = std.fmt.parseInt(u64, epoch_text, 10) catch continue;
        const path = try activePath(allocator, root_dir, entry.name);
        defer allocator.free(path);
        try maybeSelectRecoveryMeta(allocator, root_dir, table_name, path, best);
    }
}

fn makeWritableRecursive(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta) TableError!void {
    const schema_path = try schemaMetaPath(allocator, root_dir, meta.table_name);
    defer allocator.free(schema_path);
    if (std.fs.cwd().openFile(schema_path, .{})) |file| {
        var f = file;
        defer f.close();
        f.chmod(0o644) catch {};
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFileError(err),
    }

    const meta_path = try tableMetaPath(allocator, root_dir, meta.table_name);
    defer allocator.free(meta_path);
    if (std.fs.cwd().openFile(meta_path, .{})) |file| {
        var f = file;
        defer f.close();
        f.chmod(0o644) catch {};
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFileError(err),
    }

    const manifest_path = try tableManifestPath(allocator, root_dir, meta.table_name);
    defer allocator.free(manifest_path);
    if (std.fs.cwd().openFile(manifest_path, .{})) |file| {
        var f = file;
        defer f.close();
        f.chmod(0o644) catch {};
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFileError(err),
    }

    const versioned_meta_path = try tableVersionedMetaPath(allocator, root_dir, meta.table_name, meta.epoch);
    defer allocator.free(versioned_meta_path);
    if (std.fs.cwd().openFile(versioned_meta_path, .{})) |file| {
        var f = file;
        defer f.close();
        f.chmod(0o644) catch {};
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFileError(err),
    }

    for (meta.segments) |segment| {
        for (segment.files) |file_meta| {
            const path = try activePath(allocator, root_dir, file_meta.path);
            defer allocator.free(path);
            if (std.fs.cwd().openFile(path, .{})) |file| {
                var f = file;
                defer f.close();
                f.chmod(0o644) catch {};
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return mapFileError(err),
            }
        }
    }
}

fn parseDataFileFormat(path: []const u8) enum { csv, jsonl } {
    if (std.mem.endsWith(u8, path, ".jsonl")) return .jsonl;
    return .csv;
}

fn parseCsvRecord(allocator: std.mem.Allocator, line: []const u8) TableError![]const []u8 {
    var fields = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (fields.items) |field| allocator.free(field);
        fields.deinit();
    }

    var field = std.ArrayList(u8).init(allocator);
    errdefer field.deinit();

    var i: usize = 0;
    while (true) {
        field.clearRetainingCapacity();
        var quoted = false;
        if (i < line.len and line[i] == '"') {
            quoted = true;
            i += 1;
            while (i < line.len) : (i += 1) {
                const c = line[i];
                if (c == '"') {
                    if (i + 1 < line.len and line[i + 1] == '"') {
                        try field.append('"');
                        i += 1;
                        continue;
                    }
                    i += 1;
                    quoted = false;
                    break;
                }
                try field.append(c);
            }
            if (quoted) return TableError.InvalidFormat;
        } else {
            while (i < line.len and line[i] != ',') : (i += 1) {
                try field.append(line[i]);
            }
        }

        var owned = try field.toOwnedSlice();
        const trimmed = std.mem.trim(u8, owned, " \t\r");
        if (trimmed.ptr != owned.ptr or trimmed.len != owned.len) {
            const copy = try allocator.dupe(u8, trimmed);
            allocator.free(owned);
            owned = copy;
        }
        try fields.append(owned);

        if (i >= line.len) break;
        if (line[i] != ',') return TableError.InvalidFormat;
        i += 1;
        if (i == line.len) {
            try fields.append(try allocator.dupe(u8, ""));
            break;
        }
    }

    return try fields.toOwnedSlice();
}

fn freeCsvRecord(allocator: std.mem.Allocator, fields: []const []u8) void {
    for (fields) |field| allocator.free(field);
    allocator.free(fields);
}

fn appendTextValue(buf: *std.ArrayList(u8), ty: schema.PrimType, text: []const u8) TableError!void {
    const trimmed = trim(text);
    if (trimmed.len == 0) return TableError.InvalidFormat;
    switch (ty) {
        .i1 => {
            if (std.ascii.eqlIgnoreCase(trimmed, "true") or std.mem.eql(u8, trimmed, "1")) {
                try writeScalarBytes(buf, ty, true);
            } else if (std.ascii.eqlIgnoreCase(trimmed, "false") or std.mem.eql(u8, trimmed, "0")) {
                try writeScalarBytes(buf, ty, false);
            } else return TableError.InvalidFormat;
        },
        .f32, .f64 => {
            if (std.mem.indexOfAny(u8, trimmed, ".eE") != null) {
                const v = std.fmt.parseFloat(f64, trimmed) catch return TableError.InvalidFormat;
                if (ty == .f32) {
                    try writeScalarBytes(buf, ty, @as(f32, @floatCast(v)));
                } else {
                    try writeScalarBytes(buf, ty, v);
                }
            } else {
                const v = std.fmt.parseInt(i64, trimmed, 10) catch return TableError.InvalidFormat;
                try writeScalarBytes(buf, ty, v);
            }
        },
        .u64, .ptr, .blob_handle => {
            const v = std.fmt.parseInt(u64, trimmed, 10) catch return TableError.InvalidFormat;
            try writeScalarBytes(buf, ty, v);
        },
        .u32 => {
            const v = std.fmt.parseInt(u64, trimmed, 10) catch return TableError.InvalidFormat;
            try writeScalarBytes(buf, ty, v);
        },
        .u16 => {
            const v = std.fmt.parseInt(u64, trimmed, 10) catch return TableError.InvalidFormat;
            try writeScalarBytes(buf, ty, v);
        },
        .u8 => {
            const v = std.fmt.parseInt(u64, trimmed, 10) catch return TableError.InvalidFormat;
            try writeScalarBytes(buf, ty, v);
        },
        .i64 => {
            const v = std.fmt.parseInt(i64, trimmed, 10) catch return TableError.InvalidFormat;
            try writeScalarBytes(buf, ty, v);
        },
        .i32 => {
            const v = std.fmt.parseInt(i64, trimmed, 10) catch return TableError.InvalidFormat;
            try writeScalarBytes(buf, ty, v);
        },
        .i16 => {
            const v = std.fmt.parseInt(i64, trimmed, 10) catch return TableError.InvalidFormat;
            try writeScalarBytes(buf, ty, v);
        },
        .i8 => {
            const v = std.fmt.parseInt(i64, trimmed, 10) catch return TableError.InvalidFormat;
            try writeScalarBytes(buf, ty, v);
        },
        .void, .v128 => return TableError.InvalidFormat,
    }
}

fn writeScalarBytes(buf: *std.ArrayList(u8), ty: schema.PrimType, value: anytype) TableError!void {
    var tmp: [16]u8 = undefined;
    switch (ty) {
        .i1 => {
            const bit: u8 = switch (@TypeOf(value)) {
                bool => if (value) 1 else 0,
                else => if (value != 0) 1 else 0,
            };
            tmp[0] = bit & 1;
            try buf.append(tmp[0]);
        },
        .i8 => {
            const casted: i8 = switch (@TypeOf(value)) {
                i8 => value,
                i64 => std.math.cast(i8, value) orelse return TableError.InvalidFormat,
                u64 => std.math.cast(i8, value) orelse return TableError.InvalidFormat,
                else => return TableError.InvalidFormat,
            };
            std.mem.writeInt(i8, tmp[0..1], casted, .little);
            try buf.appendSlice(tmp[0..1]);
        },
        .u8 => {
            const casted: u8 = switch (@TypeOf(value)) {
                bool => if (value) 1 else 0,
                i64 => std.math.cast(u8, value) orelse return TableError.InvalidFormat,
                u64 => std.math.cast(u8, value) orelse return TableError.InvalidFormat,
                else => return TableError.InvalidFormat,
            };
            std.mem.writeInt(u8, tmp[0..1], casted, .little);
            try buf.appendSlice(tmp[0..1]);
        },
        .i16 => {
            const casted: i16 = switch (@TypeOf(value)) {
                i64 => std.math.cast(i16, value) orelse return TableError.InvalidFormat,
                u64 => std.math.cast(i16, value) orelse return TableError.InvalidFormat,
                else => return TableError.InvalidFormat,
            };
            std.mem.writeInt(i16, tmp[0..2], casted, .little);
            try buf.appendSlice(tmp[0..2]);
        },
        .u16 => {
            const casted: u16 = switch (@TypeOf(value)) {
                i64 => std.math.cast(u16, value) orelse return TableError.InvalidFormat,
                u64 => std.math.cast(u16, value) orelse return TableError.InvalidFormat,
                else => return TableError.InvalidFormat,
            };
            std.mem.writeInt(u16, tmp[0..2], casted, .little);
            try buf.appendSlice(tmp[0..2]);
        },
        .i32 => {
            const casted: i32 = switch (@TypeOf(value)) {
                i64 => std.math.cast(i32, value) orelse return TableError.InvalidFormat,
                u64 => std.math.cast(i32, value) orelse return TableError.InvalidFormat,
                else => return TableError.InvalidFormat,
            };
            std.mem.writeInt(i32, tmp[0..4], casted, .little);
            try buf.appendSlice(tmp[0..4]);
        },
        .u32 => {
            const casted: u32 = switch (@TypeOf(value)) {
                i64 => std.math.cast(u32, value) orelse return TableError.InvalidFormat,
                u64 => std.math.cast(u32, value) orelse return TableError.InvalidFormat,
                else => return TableError.InvalidFormat,
            };
            std.mem.writeInt(u32, tmp[0..4], casted, .little);
            try buf.appendSlice(tmp[0..4]);
        },
        .i64 => {
            const casted: i64 = switch (@TypeOf(value)) {
                i64 => value,
                u64 => std.math.cast(i64, value) orelse return TableError.InvalidFormat,
                else => return TableError.InvalidFormat,
            };
            std.mem.writeInt(i64, tmp[0..8], casted, .little);
            try buf.appendSlice(tmp[0..8]);
        },
        .u64, .ptr, .blob_handle => {
            const casted: u64 = switch (@TypeOf(value)) {
                bool => if (value) 1 else 0,
                i64 => std.math.cast(u64, value) orelse return TableError.InvalidFormat,
                u64 => value,
                else => return TableError.InvalidFormat,
            };
            std.mem.writeInt(u64, tmp[0..8], casted, .little);
            try buf.appendSlice(tmp[0..8]);
        },
        .f32 => {
            const casted: f32 = switch (@TypeOf(value)) {
                f32 => value,
                f64 => @floatCast(value),
                i64 => @floatFromInt(value),
                u64 => @floatFromInt(value),
                else => return TableError.InvalidFormat,
            };
            std.mem.writeInt(u32, tmp[0..4], @as(u32, @bitCast(casted)), .little);
            try buf.appendSlice(tmp[0..4]);
        },
        .f64 => {
            const casted: f64 = switch (@TypeOf(value)) {
                f32 => value,
                f64 => value,
                i64 => @floatFromInt(value),
                u64 => @floatFromInt(value),
                else => return TableError.InvalidFormat,
            };
            std.mem.writeInt(u64, tmp[0..8], @as(u64, @bitCast(casted)), .little);
            try buf.appendSlice(tmp[0..8]);
        },
        .void, .v128 => return TableError.InvalidFormat,
    }
}

fn appendJsonValue(buf: *std.ArrayList(u8), ty: schema.PrimType, value: std.json.Value) TableError!void {
    switch (value) {
        .null => return TableError.InvalidFormat,
        .bool => |b| try writeScalarBytes(buf, ty, b),
        .integer => |i| try writeScalarBytes(buf, ty, i),
        .float => |f| try writeScalarBytes(buf, ty, f),
        .number_string => |s| try appendTextValue(buf, ty, s),
        .string => |s| try appendTextValue(buf, ty, s),
        else => return TableError.InvalidFormat,
    }
}

fn appendRowFromCsv(columns: []const ColumnMeta, fields: []const []u8, buffers: []std.ArrayList(u8)) TableError!void {
    if (fields.len != columns.len) return TableError.InvalidFormat;
    for (columns, 0..) |column, idx| {
        const ty = try parsePrimTypeTable(column.ty);
        try appendTextValue(&buffers[idx], ty, fields[idx]);
    }
}

fn appendRowFromJson(columns: []const ColumnMeta, row: std.json.Value, buffers: []std.ArrayList(u8)) TableError!void {
    const object = switch (row) {
        .object => |obj| obj,
        else => return TableError.InvalidFormat,
    };

    for (columns, 0..) |column, idx| {
        var found: ?std.json.Value = null;
        var it = object.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, column.name)) {
                found = entry.value_ptr.*;
                break;
            }
        }
        const value = found orelse return TableError.InvalidFormat;
        const ty = try parsePrimTypeTable(column.ty);
        try appendJsonValue(&buffers[idx], ty, value);
    }
}

fn writeMeta(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta) TableError!void {
    const json = std.json.stringifyAlloc(allocator, meta, .{}) catch |err| return mapJsonError(err);
    defer allocator.free(json);

    const versioned_name = try tableVersionedMetaName(allocator, table_name, meta.epoch);
    defer allocator.free(versioned_name);
    const versioned_path = try activePath(allocator, root_dir, versioned_name);
    defer allocator.free(versioned_path);
    try writeFile(allocator, versioned_path, json);

    const meta_hash = try hashHexAlloc(allocator, json);
    defer allocator.free(meta_hash);
    const manifest: TableManifest = .{
        .magic = "sa-db-table-manifest",
        .version = 1,
        .table_name = table_name,
        .epoch = meta.epoch,
        .meta_path = versioned_name,
        .meta_sha256 = meta_hash,
        .meta_bytes = json.len,
    };
    const manifest_json = std.json.stringifyAlloc(allocator, manifest, .{}) catch |err| return mapJsonError(err);
    defer allocator.free(manifest_json);
    const manifest_path = try tableManifestPath(allocator, root_dir, table_name);
    defer allocator.free(manifest_path);
    try writeFile(allocator, manifest_path, manifest_json);

    const compat_path = try tableMetaPath(allocator, root_dir, table_name);
    defer allocator.free(compat_path);
    try writeFile(allocator, compat_path, json);
}

pub fn commitTableMeta(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta) TableError!void {
    try writeMeta(allocator, root_dir, table_name, meta);
}

pub fn rewriteColumnFileForEpoch(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    previous_path: []const u8,
    epoch: u64,
    bytes: []const u8,
) TableError!FileMeta {
    const next_path = try allocPrintPath(allocator, "{s}.e{d}", .{ previous_path, epoch });
    defer allocator.free(next_path);
    const active_next_path = try activePath(allocator, root_dir, next_path);
    defer allocator.free(active_next_path);
    try writeFile(allocator, active_next_path, bytes);
    return try makeFileMeta(allocator, next_path, bytes);
}

fn writeGeneratedIface(allocator: std.mem.Allocator, root_dir: []const u8, schema_obj: schema.Schema) TableError!void {
    var iface = std.ArrayList(u8).init(allocator);
    defer iface.deinit();
    schema.writeIface(iface.writer(), schema_obj) catch |err| return mapFileError(err);

    const basename = try allocPrintPath(allocator, "{s}.sai", .{schema_obj.table_name});
    defer allocator.free(basename);
    const path = try activePath(allocator, root_dir, basename);
    defer allocator.free(path);
    try writeFile(allocator, path, iface.items);
}

pub fn initTableFromSchemaBytes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    schema_path_hint: []const u8,
    schema_source: []const u8,
) TableError!TableInfo {
    if (schema_path_hint.len == 0 or schema_source.len == 0) return TableError.InvalidFormat;

    var schema_obj = schema.compile(allocator, schema_source, schema_path_hint) catch |err| return mapSchemaError(err);
    defer schema_obj.deinit();

    const schema_path = try schemaMetaPath(allocator, root_dir, schema_obj.table_name);
    defer allocator.free(schema_path);
    try writeFile(allocator, schema_path, schema_source);
    try writeGeneratedIface(allocator, root_dir, schema_obj);

    const schema_hash = try hashHexAlloc(allocator, schema_source);
    defer allocator.free(schema_hash);

    var meta = try buildInitialMeta(allocator, schema_obj.table_name, schema_path, schema_hash, schema_obj);
    defer meta.deinit(allocator);
    try writeMeta(allocator, root_dir, schema_obj.table_name, meta);
    return tableInfo(meta);
}

pub fn removeTable(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError!TableInfo {
    if (loadActiveMeta(allocator, root_dir, table_name)) |meta| {
        var owned = meta;
        defer owned.deinit(allocator);
        for (owned.segments) |segment| {
            for (segment.files) |file| {
                const path = try activePath(allocator, root_dir, file.path);
                defer allocator.free(path);
                try deleteIfExists(path);
            }
        }
    } else |err| switch (err) {
        TableError.NotFound => {},
        else => return err,
    }

    const meta_path = try tableMetaPath(allocator, root_dir, table_name);
    defer allocator.free(meta_path);
    try deleteIfExists(meta_path);

    const manifest_path = try tableManifestPath(allocator, root_dir, table_name);
    defer allocator.free(manifest_path);
    try deleteIfExists(manifest_path);

    const schema_path = try schemaMetaPath(allocator, root_dir, table_name);
    defer allocator.free(schema_path);
    try deleteIfExists(schema_path);

    const iface_basename = try allocPrintPath(allocator, "{s}.sai", .{table_name});
    defer allocator.free(iface_basename);
    const iface_path = try activePath(allocator, root_dir, iface_basename);
    defer allocator.free(iface_path);
    try deleteIfExists(iface_path);

    const prefix = rootPrefix(root_dir);
    const snapshot_path = if (prefix.len == 0)
        try joinPath(allocator, &.{ ".sa", "db", "snapshots", table_name })
    else
        try joinPath(allocator, &.{ prefix, ".sa", "db", "snapshots", table_name });
    defer allocator.free(snapshot_path);
    try deleteTreeIfExists(snapshot_path);

    return .{ .row_count = 0, .segment_count = 0, .epoch = 0, .locked = false };
}

pub fn ingestRawColumns(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    row_count: u64,
    columns: []const RawColumnBytes,
) TableError!TableInfo {
    var schema_obj = try loadSchema(allocator, root_dir, table_name);
    defer schema_obj.deinit();

    const schema_path = try schemaMetaPath(allocator, root_dir, table_name);
    defer allocator.free(schema_path);
    const schema_source = try readFileAlloc(allocator, schema_path, 16 * 1024 * 1024);
    defer allocator.free(schema_source);
    const schema_hash = try hashHexAlloc(allocator, schema_source);
    defer allocator.free(schema_hash);

    var meta = try loadCurrentMeta(allocator, root_dir, table_name, schema_obj, schema_path, schema_hash);
    defer meta.deinit(allocator);

    if (meta.locked) return TableError.Locked;
    if (columns.len != meta.columns.len) return TableError.InvalidFormat;
    const total_rows = std.math.add(u64, meta.row_count, row_count) catch return TableError.CursorOverflow;
    if (total_rows > meta.max_rows) return TableError.CursorOverflow;

    const buffers = try allocator.alloc(std.ArrayList(u8), meta.columns.len);
    errdefer {
        for (buffers) |*buf| buf.deinit();
        allocator.free(buffers);
    }
    for (buffers) |*buf| buf.* = std.ArrayList(u8).init(allocator);

    for (columns, 0..) |column, idx| {
        const expected_len = std.math.mul(u64, row_count, meta.columns[idx].stride) catch return TableError.CursorOverflow;
        if (column.bytes.len != expected_len) return TableError.InvalidFormat;
        try buffers[idx].appendSlice(column.bytes);
    }

    try appendSegmentToMeta(allocator, root_dir, table_name, &meta, buffers, row_count);
    try writeMeta(allocator, root_dir, table_name, meta);

    for (buffers) |*buf| buf.deinit();
    allocator.free(buffers);

    return tableInfo(meta);
}

fn ensureU64Column(meta: TableMeta, column_index: usize) TableError!void {
    if (column_index >= meta.columns.len) return TableError.InvalidFormat;
    const column = meta.columns[column_index];
    if (column.stride != 8 or !std.mem.eql(u8, column.ty, "u64")) return TableError.InvalidFormat;
}

fn readU64LE(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset .. offset + 8][0..8], .little);
}

fn writeU64LE(bytes: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset .. offset + 8][0..8], value, .little);
}

fn duplicateColumnMetasToArena(allocator: std.mem.Allocator, columns: []const ColumnMeta) TableError![]ColumnMeta {
    const out = try allocator.alloc(ColumnMeta, columns.len);
    for (columns, 0..) |column, idx| {
        out[idx] = .{
            .name = try allocator.dupe(u8, column.name),
            .stride = column.stride,
            .ty = try allocator.dupe(u8, column.ty),
        };
    }
    return out;
}

fn expectedColumnBytes(segment_rows: u64, stride: u32) TableError!usize {
    const expected = std.math.mul(u64, segment_rows, @as(u64, stride)) catch return TableError.CursorOverflow;
    if (expected > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    return @intCast(expected);
}

pub fn openReadSnapshot(
    backing_allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
) TableError!*ReadSnapshot {
    const snapshot = backing_allocator.create(ReadSnapshot) catch return TableError.OutOfMemory;
    snapshot.* = .{
        .backing_allocator = backing_allocator,
        .arena = std.heap.ArenaAllocator.init(backing_allocator),
        .table_name = &.{},
        .epoch = 0,
        .row_count = 0,
        .columns = &.{},
        .segments = &.{},
    };
    errdefer snapshot.destroy();

    const arena_allocator = snapshot.arena.allocator();
    const source = try readActiveMetaSource(backing_allocator, root_dir, table_name);
    defer backing_allocator.free(source);
    var parsed = try parseTableMeta(backing_allocator, source);
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.table_name, table_name)) return TableError.InvalidFormat;

    snapshot.table_name = try arena_allocator.dupe(u8, parsed.value.table_name);
    snapshot.epoch = parsed.value.epoch;
    snapshot.row_count = parsed.value.row_count;
    snapshot.columns = try duplicateColumnMetasToArena(arena_allocator, parsed.value.columns);
    snapshot.segments = try arena_allocator.alloc(ReadSegmentSnapshot, parsed.value.segments.len);

    for (parsed.value.segments, 0..) |segment, segment_idx| {
        const segment_columns = try arena_allocator.alloc(ReadColumnSnapshot, segment.files.len);
        if (segment.files.len != parsed.value.columns.len) return TableError.InvalidFormat;
        for (segment.files, 0..) |file_meta, column_idx| {
            const expected_len = try expectedColumnBytes(segment.rows, parsed.value.columns[column_idx].stride);
            if (file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
            const path = try activePath(backing_allocator, root_dir, file_meta.path);
            defer backing_allocator.free(path);
            const bytes = try readFileAlloc(arena_allocator, path, 1 << 30);
            if (bytes.len != expected_len) return TableError.VerifyFailed;
            segment_columns[column_idx] = .{ .bytes = bytes };
        }
        snapshot.segments[segment_idx] = .{
            .rows = segment.rows,
            .columns = segment_columns,
        };
    }

    return snapshot;
}

fn ensureSnapshotU64Column(snapshot: *const ReadSnapshot, column_index: usize) TableError!void {
    if (column_index >= snapshot.columns.len) return TableError.InvalidFormat;
    const column = snapshot.columns[column_index];
    if (column.stride != 8 or !std.mem.eql(u8, column.ty, "u64")) return TableError.InvalidFormat;
}

fn compareU64(value: u64, op: U64CompareOp, expected: u64) bool {
    return switch (op) {
        .eq => value == expected,
        .ne => value != expected,
        .lt => value < expected,
        .le => value <= expected,
        .gt => value > expected,
        .ge => value >= expected,
    };
}

pub fn snapshotSumU64(snapshot: *const ReadSnapshot, column_index: usize) TableError!u64 {
    try ensureSnapshotU64Column(snapshot, column_index);
    var sum: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            sum = std.math.add(u64, sum, readU64LE(bytes, byte_offset)) catch return TableError.CursorOverflow;
        }
    }
    return sum;
}

pub fn snapshotCountU64Cmp(snapshot: *const ReadSnapshot, column_index: usize, op: U64CompareOp, expected: u64) TableError!u64 {
    try ensureSnapshotU64Column(snapshot, column_index);
    var count: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            if (compareU64(readU64LE(bytes, byte_offset), op, expected)) count += 1;
        }
    }
    return count;
}

pub fn snapshotFindU64(snapshot: *const ReadSnapshot, column_index: usize, expected: u64) TableError!U64FindResult {
    try ensureSnapshotU64Column(snapshot, column_index);
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            if (readU64LE(bytes, byte_offset) == expected) {
                return .{ .found = true, .row_index = row_base + i };
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .found = false, .row_index = 0 };
}

pub fn snapshotGetU64(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!u64 {
    try ensureSnapshotU64Column(snapshot, column_index);
    if (row_index >= snapshot.row_count) return TableError.InvalidFormat;
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const segment_end = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        if (row_index < segment_end) {
            const bytes = segment.columns[column_index].bytes;
            const expected_len = try expectedColumnBytes(segment.rows, 8);
            if (bytes.len != expected_len) return TableError.VerifyFailed;
            const local_row = row_index - row_base;
            const byte_offset: usize = @intCast(local_row * 8);
            return readU64LE(bytes, byte_offset);
        }
        row_base = segment_end;
    }
    return TableError.InvalidFormat;
}

pub fn snapshotMinU64(snapshot: *const ReadSnapshot, column_index: usize) TableError!u64 {
    try ensureSnapshotU64Column(snapshot, column_index);
    var seen = false;
    var min_value: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const value = readU64LE(bytes, byte_offset);
            if (!seen or value < min_value) {
                min_value = value;
                seen = true;
            }
        }
    }
    return min_value;
}

pub fn snapshotMaxU64(snapshot: *const ReadSnapshot, column_index: usize) TableError!u64 {
    try ensureSnapshotU64Column(snapshot, column_index);
    var seen = false;
    var max_value: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const value = readU64LE(bytes, byte_offset);
            if (!seen or value > max_value) {
                max_value = value;
                seen = true;
            }
        }
    }
    return max_value;
}

pub fn updateU64ColumnAdd(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    start_row: u64,
    update_count: u64,
    delta: u64,
) TableError!u64 {
    var owned = try loadActiveMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    try ensureU64Column(owned, column_index);
    const end_row = std.math.add(u64, start_row, update_count) catch return TableError.CursorOverflow;
    if (end_row > owned.row_count) return TableError.InvalidFormat;
    const next_epoch = owned.epoch + 1;

    var segment_start: u64 = 0;
    var updated: u64 = 0;
    for (owned.segments) |*segment| {
        const segment_end = segment_start + segment.rows;
        defer segment_start = segment_end;
        if (end_row <= segment_start or start_row >= segment_end) continue;

        const range_start = @max(start_row, segment_start);
        const range_end = @min(end_row, segment_end);
        const local_start = range_start - segment_start;
        const local_count = range_end - range_start;

        const file_meta = &segment.files[column_index];
        const path = try activePath(allocator, root_dir, file_meta.path);
        defer allocator.free(path);
        const current = try readFileAlloc(allocator, path, 1 << 30);
        defer allocator.free(current);
        if (current.len != segment.rows * 8) return TableError.VerifyFailed;
        const mutable = allocator.dupe(u8, current) catch return TableError.OutOfMemory;
        defer allocator.free(mutable);

        var i: u64 = 0;
        while (i < local_count) : (i += 1) {
            const byte_offset_u64 = (local_start + i) * 8;
            const byte_offset: usize = @intCast(byte_offset_u64);
            const value = readU64LE(mutable, byte_offset);
            const next = std.math.add(u64, value, delta) catch return TableError.CursorOverflow;
            writeU64LE(mutable, byte_offset, next);
        }

        const updated_file = try rewriteColumnFileForEpoch(allocator, root_dir, file_meta.path, next_epoch, mutable);
        allocator.free(file_meta.path);
        allocator.free(file_meta.sha256);
        file_meta.* = updated_file;
        updated += local_count;
    }

    owned.epoch = next_epoch;
    try writeMeta(allocator, root_dir, table_name, owned);
    return updated;
}

pub fn ingestTable(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    data_path: []const u8,
) TableError!TableInfo {
    var schema_obj = try loadSchema(allocator, root_dir, table_name);
    defer schema_obj.deinit();

    const schema_path = try schemaMetaPath(allocator, root_dir, table_name);
    defer allocator.free(schema_path);
    const schema_source = try readFileAlloc(allocator, schema_path, 16 * 1024 * 1024);
    defer allocator.free(schema_source);
    const schema_hash = try hashHexAlloc(allocator, schema_source);
    defer allocator.free(schema_hash);

    var meta = try loadCurrentMeta(allocator, root_dir, table_name, schema_obj, schema_path, schema_hash);
    defer meta.deinit(allocator);

    if (meta.locked) return TableError.Locked;

    const data_source = try readFileAlloc(allocator, data_path, 1 << 30);
    defer allocator.free(data_source);

    const buffers = try allocator.alloc(std.ArrayList(u8), meta.columns.len);
    errdefer {
        for (buffers) |*buf| buf.deinit();
        allocator.free(buffers);
    }
    for (buffers) |*buf| buf.* = std.ArrayList(u8).init(allocator);
    var row_count: u64 = 0;

    switch (parseDataFileFormat(data_path)) {
        .csv => {
            var it = std.mem.splitScalar(u8, data_source, '\n');
            var header_checked = false;
            while (it.next()) |raw_line| {
                const line = trim(raw_line);
                if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;
                const fields = try parseCsvRecord(allocator, line);
                defer freeCsvRecord(allocator, fields);
                if (!header_checked) {
                    header_checked = true;
                    if (fields.len == meta.columns.len) {
                        var header_match = true;
                        for (fields, 0..) |field, idx| {
                            if (!std.ascii.eqlIgnoreCase(field, meta.columns[idx].name)) {
                                header_match = false;
                                break;
                            }
                        }
                        if (header_match) continue;
                    }
                }
                try appendRowFromCsv(meta.columns, fields, buffers);
                row_count += 1;
            }
        },
        .jsonl => {
            var it = std.mem.splitScalar(u8, data_source, '\n');
            while (it.next()) |raw_line| {
                const line = trim(raw_line);
                if (line.len == 0) continue;
                var parsed = try parseJsonValue(allocator, line);
                defer parsed.deinit();
                try appendRowFromJson(meta.columns, parsed.value, buffers);
                row_count += 1;
            }
        },
    }

    const total_rows = std.math.add(u64, meta.row_count, row_count) catch return TableError.CursorOverflow;
    if (total_rows > meta.max_rows) return TableError.CursorOverflow;

    try appendSegmentToMeta(allocator, root_dir, table_name, &meta, buffers, row_count);
    try writeMeta(allocator, root_dir, table_name, meta);

    for (buffers) |*buf| buf.deinit();
    allocator.free(buffers);

    return tableInfo(meta);
}

pub fn snapshotTable(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
) TableError!TableInfo {
    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    try appendSnapshotArtifacts(allocator, root_dir, table_name, meta);
    return tableInfo(meta);
}

pub fn restoreTable(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    epoch: u64,
) TableError!TableInfo {
    return restoreSnapshotArtifacts(allocator, root_dir, table_name, epoch) catch |err| switch (err) {
        TableError.NotFound => TableError.SnapshotMissing,
        else => err,
    };
}

pub fn recoverTable(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
) TableError!TableInfo {
    var best: ?TableMeta = null;
    defer if (best) |*meta| meta.deinit(allocator);

    try scanVersionedRecoveryMetas(allocator, root_dir, table_name, &best);

    const compat_path = try tableMetaPath(allocator, root_dir, table_name);
    defer allocator.free(compat_path);
    try maybeSelectRecoveryMeta(allocator, root_dir, table_name, compat_path, &best);

    const recovered = best orelse return TableError.VerifyFailed;
    try writeMeta(allocator, root_dir, table_name, recovered);
    return tableInfo(recovered);
}

pub fn verifyTable(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
) TableError!TableInfo {
    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    try validateSegmentHashes(allocator, root_dir, meta);
    return tableInfo(meta);
}

pub fn lockTable(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
) TableError!TableInfo {
    var owned = try loadActiveMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    owned.locked = true;
    owned.epoch += 1;
    try writeMeta(allocator, root_dir, table_name, owned);
    try makeReadonlyRecursive(allocator, root_dir, owned);
    return tableInfo(owned);
}

pub fn unlockTable(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
) TableError!TableInfo {
    var owned = try loadActiveMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    try validateSegmentHashes(allocator, root_dir, owned);
    if (owned.locked) {
        owned.locked = false;
        owned.epoch += 1;
    }
    try makeWritableRecursive(allocator, root_dir, owned);
    try writeMeta(allocator, root_dir, table_name, owned);
    return tableInfo(owned);
}

pub fn compactTable(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
) TableError!TableInfo {
    var owned = try loadActiveMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    if (owned.segments.len == 0) return tableInfo(owned);

    const files = try mergeSegmentFiles(allocator, root_dir, table_name, &owned, owned.next_segment_id);
    errdefer freeFileMetas(allocator, files);

    const new_segments = try allocator.alloc(SegmentMeta, 1);
    errdefer allocator.free(new_segments);
    new_segments[0] = .{
        .id = owned.next_segment_id,
        .rows = owned.row_count,
        .files = files,
    };

    const old_segments = owned.segments;
    owned.segments = new_segments;
    freeSegmentMetas(allocator, old_segments);
    owned.next_segment_id += 1;
    owned.epoch += 1;
    try writeMeta(allocator, root_dir, table_name, owned);
    return tableInfo(owned);
}

fn writeFileToTemp(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

test "table atomic write replaces target and cleans temporary files" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    try writeFile(std.testing.allocator, "data.bin", "old");
    try writeFile(std.testing.allocator, "data.bin", "new");

    const contents = try readFileAlloc(std.testing.allocator, "data.bin", 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("new", contents);

    try tmp_dir.dir.makeDir("target_dir");
    try std.testing.expectError(TableError.InvalidFormat, writeFile(std.testing.allocator, "target_dir", "x"));

    var iter = tmp_dir.dir.iterate();
    while (try iter.next()) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".data.bin.tmp."));
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".target_dir.tmp."));
    }
}

test "table verify rejects segment byte-count metadata mismatch" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "inventory_txn";
    try writeFileToTemp(tmp_dir.dir, "inventory_txn.sadb-schema",
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_QTY_STRIDE = 8 // u64
    );
    try writeFileToTemp(tmp_dir.dir, "rows.csv",
        \\ID,QTY
        \\1,5
        \\2,8
    );

    _ = try ingestTable(std.testing.allocator, ".", table_name, "rows.csv");

    const meta_path = try tableMetaPath(std.testing.allocator, ".", table_name);
    defer std.testing.allocator.free(meta_path);
    const source = try readFileAlloc(std.testing.allocator, meta_path, 16 * 1024 * 1024);
    defer std.testing.allocator.free(source);
    var parsed = try parseTableMeta(std.testing.allocator, source);
    defer parsed.deinit();

    var owned = try duplicateTableMeta(std.testing.allocator, parsed.value);
    defer owned.deinit(std.testing.allocator);
    owned.segments[0].files[0].bytes += 8;
    try writeMeta(std.testing.allocator, ".", table_name, owned);

    try std.testing.expectError(TableError.VerifyFailed, verifyTable(std.testing.allocator, ".", table_name));
}

test "table manifest selects active epoch over compatibility meta" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "orders";
    const schema_source =
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_TOTAL_CENTS_STRIDE = 8 // u64
    ;
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "orders.sadb-schema", schema_source);

    var ids1 = [_]u64{1};
    var totals1 = [_]u64{500};
    const first_columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids1[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(totals1[0..]) },
    };
    const first = try ingestRawColumns(std.testing.allocator, ".", table_name, 1, &first_columns);
    try std.testing.expectEqual(@as(u64, 1), first.row_count);

    const manifest_path = try tableManifestPath(std.testing.allocator, ".", table_name);
    defer std.testing.allocator.free(manifest_path);
    const old_manifest = try readFileAlloc(std.testing.allocator, manifest_path, 1024 * 1024);
    defer std.testing.allocator.free(old_manifest);

    var ids2 = [_]u64{2};
    var totals2 = [_]u64{700};
    const second_columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids2[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(totals2[0..]) },
    };
    const second = try ingestRawColumns(std.testing.allocator, ".", table_name, 1, &second_columns);
    try std.testing.expectEqual(@as(u64, 2), second.row_count);

    try writeFile(std.testing.allocator, manifest_path, old_manifest);

    const active = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 1), active.row_count);

    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();
    try std.testing.expectEqual(@as(u64, 1), snapshot.row_count);
    try std.testing.expectEqual(@as(u64, 500), try snapshotSumU64(snapshot, 1));
}

test "table recover rebuilds manifest from highest valid versioned meta" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "recover_orders";
    const schema_source =
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_TOTAL_STRIDE = 8 // u64
    ;
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "recover_orders.sadb-schema", schema_source);

    var ids1 = [_]u64{1};
    var totals1 = [_]u64{100};
    const first_columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids1[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(totals1[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, 1, &first_columns);

    var ids2 = [_]u64{2};
    var totals2 = [_]u64{200};
    const second_columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids2[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(totals2[0..]) },
    };
    const second = try ingestRawColumns(std.testing.allocator, ".", table_name, 1, &second_columns);
    try std.testing.expectEqual(@as(u64, 2), second.row_count);

    const manifest_path = try tableManifestPath(std.testing.allocator, ".", table_name);
    defer std.testing.allocator.free(manifest_path);
    try writeFile(std.testing.allocator, manifest_path, "{not-json}\n");
    try std.testing.expectError(TableError.InvalidFormat, verifyTable(std.testing.allocator, ".", table_name));

    const recovered = try recoverTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 2), recovered.row_count);
    try std.testing.expectEqual(@as(u64, 2), recovered.epoch);

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 2), verified.row_count);
    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();
    try std.testing.expectEqual(@as(u64, 300), try snapshotSumU64(snapshot, 1));
}

test "table ingest, verify, snapshot, restore, lock, unlock and compact are real" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "flash_sale";
    const schema_path = "flash_sale.sadb-schema";
    const csv1 = "rows1.csv";
    const csv2 = "rows2.csv";
    const jsonl = "rows.jsonl";

    try writeFileToTemp(tmp_dir.dir, schema_path,
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_PRICE_STRIDE = 4 // f32
    );
    try writeFileToTemp(tmp_dir.dir, csv1,
        \\ID,PRICE
        \\1,9.5
        \\2,10.25
    );
    try writeFileToTemp(tmp_dir.dir, csv2,
        \\ID,PRICE
        \\3,11.75
    );
    try writeFileToTemp(tmp_dir.dir, jsonl,
        \\{"ID":4,"PRICE":12.5}
        \\{"ID":5,"PRICE":13.25}
    );

    const first = try ingestTable(std.testing.allocator, ".", table_name, csv1);
    try std.testing.expectEqual(@as(u64, 2), first.row_count);
    try std.testing.expectEqual(@as(usize, 1), first.segment_count);

    const verified1 = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 2), verified1.row_count);

    const snap1 = try snapshotTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 1), snap1.epoch);

    const second = try ingestTable(std.testing.allocator, ".", table_name, csv2);
    try std.testing.expectEqual(@as(u64, 3), second.row_count);
    try std.testing.expectEqual(@as(usize, 2), second.segment_count);

    const compacted = try compactTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 3), compacted.row_count);
    try std.testing.expectEqual(@as(usize, 1), compacted.segment_count);

    const locked = try lockTable(std.testing.allocator, ".", table_name);
    try std.testing.expect(locked.locked);

    try std.testing.expectError(TableError.Locked, ingestTable(std.testing.allocator, ".", table_name, jsonl));

    const unlocked = try unlockTable(std.testing.allocator, ".", table_name);
    try std.testing.expect(!unlocked.locked);

    const after_unlock = try ingestTable(std.testing.allocator, ".", table_name, jsonl);
    try std.testing.expectEqual(@as(u64, 5), after_unlock.row_count);

    const restored = try restoreTable(std.testing.allocator, ".", table_name, snap1.epoch);
    try std.testing.expectEqual(@as(u64, 2), restored.row_count);
    try std.testing.expect(!restored.locked);

    const meta_path = try tableMetaPath(std.testing.allocator, ".", table_name);
    defer std.testing.allocator.free(meta_path);
    const source = try readFileAlloc(std.testing.allocator, meta_path, 16 * 1024 * 1024);
    defer std.testing.allocator.free(source);
    var parsed = try parseTableMeta(std.testing.allocator, source);
    defer parsed.deinit();
    const corrupt_path = try activePath(std.testing.allocator, ".", parsed.value.segments[0].files[0].path);
    defer std.testing.allocator.free(corrupt_path);
    var file = try std.fs.cwd().openFile(corrupt_path, .{ .mode = .read_write });
    defer file.close();
    const end_pos = try file.getEndPos();
    try file.seekTo(end_pos);
    try file.writeAll("x");
    try std.testing.expectError(TableError.VerifyFailed, verifyTable(std.testing.allocator, ".", table_name));
}

test "table ingest accepts jsonl input" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "flash_sale";
    try writeFileToTemp(tmp_dir.dir, "flash_sale.sadb-schema",
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_PRICE_STRIDE = 4 // f32
    );
    try writeFileToTemp(tmp_dir.dir, "rows.jsonl",
        \\{"ID":10,"PRICE":1.5}
        \\{"ID":11,"PRICE":2.25}
    );

    const info = try ingestTable(std.testing.allocator, ".", table_name, "rows.jsonl");
    try std.testing.expectEqual(@as(u64, 2), info.row_count);
    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 2), verified.row_count);
}
