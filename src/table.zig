const std = @import("std");
const builtin = @import("builtin");
const schema = @import("schema.zig");

var temp_write_counter = std.atomic.Value(u64).init(0);
const FILE_BLOCK_BYTES: usize = 64 * 1024;

pub const TableError = error{
    OutOfMemory,
    InvalidFormat,
    InvalidPath,
    NotFound,
    Locked,
    CursorOverflow,
    SnapshotMissing,
    VerifyFailed,
    ConstraintViolation,
};

pub const TableInfo = struct {
    row_count: u64,
    segment_count: usize,
    epoch: u64,
    locked: bool,
};

pub const UpsertResult = struct {
    info: TableInfo,
    inserted: bool,
};

pub const RawColumnBytes = struct {
    bytes: []const u8,
};

pub const ColumnMeta = struct {
    name: []const u8,
    stride: u32,
    ty: []const u8,
    logical_type: u32 = schema.LOGICAL_NONE,
    logical_scale: u32 = 0,
    nullable: bool = false,
};

pub const FileMeta = struct {
    path: []const u8,
    sha256: []const u8,
    bytes: u64,
    block_size: u64 = 0,
    block_sha256: [][]const u8 = &.{},
};

pub const SegmentMeta = struct {
    id: u64,
    rows: u64,
    files: []FileMeta,
};

pub const IndexMeta = struct {
    name: []const u8,
    kind: []const u8,
    column_index: u64,
    column_index2: ?u64 = null,
    store_name: ?[]const u8 = null,
    unique: bool,
    path: []const u8,
    sha256: []const u8,
    bytes: u64,
    block_size: u64 = 0,
    block_sha256: [][]const u8 = &.{},
};

pub const DictMeta = struct {
    name: []const u8,
    path: []const u8,
    sha256: []const u8,
    bytes: u64,
    entries: u64,
    block_size: u64 = 0,
    block_sha256: [][]const u8 = &.{},
};

pub const BlobStoreMeta = struct {
    name: []const u8,
    path: []const u8,
    sha256: []const u8,
    bytes: u64,
    entries: u64,
    block_size: u64 = 0,
    block_sha256: [][]const u8 = &.{},
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
    indexes: []IndexMeta = &.{},
    dicts: []DictMeta = &.{},
    blobs: []BlobStoreMeta = &.{},

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
            freeFileMetas(allocator, segment.files);
        }
        allocator.free(self.segments);
        freeIndexMetas(allocator, self.indexes);
        freeDictMetas(allocator, self.dicts);
        freeBlobStoreMetas(allocator, self.blobs);
        self.* = undefined;
    }
};

pub const DictInternResult = struct {
    info: TableInfo,
    id: u64,
    inserted: bool,
};

pub const DictLookupResult = struct {
    found: bool,
    id: u64,
};

pub const DictValueLenResult = struct {
    found: bool,
    len: u64,
};

pub const DictValueCopyResult = struct {
    found: bool,
    written: u64,
};

pub const BlobPutResult = struct {
    info: TableInfo,
    id: u64,
};

pub const BlobValueLenResult = struct {
    found: bool,
    len: u64,
};

pub const BlobValueCopyResult = struct {
    found: bool,
    written: u64,
};

pub const U64RowsStats = struct {
    count: u64,
    sum: u64,
    min: u64,
    max: u64,
};

pub const I64RowsStats = struct {
    count: u64,
    sum: i64,
    min: i64,
    max: i64,
};

pub const TableWriteLock = struct {
    file: std.fs.File,

    pub fn release(self: *TableWriteLock) void {
        self.file.unlock();
        self.file.close();
        self.* = undefined;
    }
};

pub const WriteTransaction = struct {
    root_dir: []const u8,
    table_name: []const u8,
    write_lock: TableWriteLock,
    meta: TableMeta,
    buffers: []std.ArrayList(u8),
    dirty: bool = false,
    rows_dirty: bool = false,

    pub fn deinit(self: *WriteTransaction, allocator: std.mem.Allocator) void {
        self.write_lock.release();
        self.meta.deinit(allocator);
        freeColumnBuffers(allocator, self.buffers);
        allocator.free(self.root_dir);
        allocator.free(self.table_name);
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

const TxPendingMarker = struct {
    magic: []const u8,
    version: u32,
    table_name: []const u8,
    previous_epoch: u64,
    target_epoch: u64,
};

const TxCommitMarker = struct {
    magic: []const u8,
    version: u32,
    table_name: []const u8,
    epoch: u64,
    meta_path: []const u8,
    meta_sha256: []const u8,
    meta_bytes: u64,
};

const WrittenMeta = struct {
    json: []u8,
    versioned_name: []u8,
    meta_hash: []u8,
    meta_bytes: usize,

    fn deinit(self: *WrittenMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
        allocator.free(self.versioned_name);
        allocator.free(self.meta_hash);
        self.* = undefined;
    }
};

pub const ReadColumnSnapshot = struct {
    bytes: []const u8,
};

pub const ReadSegmentSnapshot = struct {
    rows: u64,
    columns: []ReadColumnSnapshot,
};

pub const ReadIndexSnapshot = struct {
    kind: []const u8,
    column_index: u64,
    column_index2: ?u64 = null,
    store_name: ?[]const u8 = null,
    unique: bool,
    entries: []const u8,
};

pub const ReadDictSnapshot = struct {
    name: []const u8,
    bytes: []const u8,
    entries: u64,
};

pub const ReadBlobStoreSnapshot = struct {
    name: []const u8,
    bytes: []const u8,
    entries: u64,
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

const U64PairKey = struct {
    key1: u64,
    key2: u64,
};

pub const U64RangeResult = struct {
    written: u64,
    total: u64,
};

pub const BoolFilterResult = struct {
    written: u64,
    total: u64,
};

pub const BlobFilterResult = struct {
    written: u64,
    total: u64,
};

const BlobFilterMode = enum {
    eq,
    contains,
};

pub const ProjectRowsResult = struct {
    written_rows: u64,
    required_bytes: u64,
};

pub const SnapshotInfo = struct {
    row_count: u64,
    column_count: u64,
    row_bytes: u64,
    epoch: u64,
};

pub const ColumnInfo = struct {
    stride: u64,
    type_code: u64,
    name_len: u64,
    type_name_len: u64,
};

pub const ColumnLogicalInfo = struct {
    logical_type: u64,
    logical_scale: u64,
    nullable: u64,
};

pub const ReadSnapshot = struct {
    backing_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    table_name: []const u8,
    epoch: u64,
    row_count: u64,
    columns: []ColumnMeta,
    segments: []ReadSegmentSnapshot,
    indexes: []ReadIndexSnapshot,
    dicts: []ReadDictSnapshot,
    blobs: []ReadBlobStoreSnapshot,

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

fn txPendingMarkerName(allocator: std.mem.Allocator, table_name: []const u8, epoch: u64) TableError![]u8 {
    return allocPrintPath(allocator, "{s}.tx.{d}.pending", .{ table_name, epoch });
}

fn txCommitMarkerName(allocator: std.mem.Allocator, table_name: []const u8, epoch: u64) TableError![]u8 {
    return allocPrintPath(allocator, "{s}.tx.{d}.commit", .{ table_name, epoch });
}

fn txPendingMarkerPath(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, epoch: u64) TableError![]u8 {
    const basename = try txPendingMarkerName(allocator, table_name, epoch);
    errdefer allocator.free(basename);
    const path = try activePath(allocator, root_dir, basename);
    allocator.free(basename);
    return path;
}

fn txCommitMarkerPath(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, epoch: u64) TableError![]u8 {
    const basename = try txCommitMarkerName(allocator, table_name, epoch);
    errdefer allocator.free(basename);
    const path = try activePath(allocator, root_dir, basename);
    allocator.free(basename);
    return path;
}

fn tableWriteLockName(allocator: std.mem.Allocator, table_name: []const u8) TableError![]u8 {
    return allocPrintPath(allocator, "{s}.write.lock", .{table_name});
}

fn tableWriteLockPath(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError![]u8 {
    const basename = try tableWriteLockName(allocator, table_name);
    errdefer allocator.free(basename);
    const path = try activePath(allocator, root_dir, basename);
    allocator.free(basename);
    return path;
}

pub fn acquireTableWriteLock(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError!TableWriteLock {
    const path = try tableWriteLockPath(allocator, root_dir, table_name);
    defer allocator.free(path);
    try ensureParentDir(path);
    const file = std.fs.cwd().createFile(path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    }) catch |err| return mapFileError(err);
    return .{ .file = file };
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

fn indexFileName(allocator: std.mem.Allocator, table_name: []const u8, kind: []const u8, column_index: u64, epoch: u64) TableError![]u8 {
    return allocPrintPath(allocator, "{s}.idx.{s}.{d}.{d}.dat", .{ table_name, kind, column_index, epoch });
}

fn pairIndexFileName(allocator: std.mem.Allocator, table_name: []const u8, kind: []const u8, column_index: u64, column_index2: u64, epoch: u64) TableError![]u8 {
    return allocPrintPath(allocator, "{s}.idx.{s}.{d}.{d}.{d}.dat", .{ table_name, kind, column_index, column_index2, epoch });
}

fn blobEqIndexFileName(allocator: std.mem.Allocator, table_name: []const u8, column_index: u64, store_name: []const u8, epoch: u64) TableError![]u8 {
    return allocPrintPath(allocator, "{s}.idx.{s}.{d}.{s}.{d}.dat", .{ table_name, BLOB_EQ_INDEX_KIND, column_index, store_name, epoch });
}

fn blobTokenIndexFileName(allocator: std.mem.Allocator, table_name: []const u8, column_index: u64, store_name: []const u8, epoch: u64) TableError![]u8 {
    return allocPrintPath(allocator, "{s}.idx.{s}.{d}.{s}.{d}.dat", .{ table_name, BLOB_TOKEN_INDEX_KIND, column_index, store_name, epoch });
}

fn blobPrefixIndexFileName(allocator: std.mem.Allocator, table_name: []const u8, column_index: u64, store_name: []const u8, epoch: u64) TableError![]u8 {
    return allocPrintPath(allocator, "{s}.idx.{s}.{d}.{s}.{d}.dat", .{ table_name, BLOB_PREFIX_INDEX_KIND, column_index, store_name, epoch });
}

fn blobContainsIndexFileName(allocator: std.mem.Allocator, table_name: []const u8, column_index: u64, store_name: []const u8, epoch: u64) TableError![]u8 {
    return allocPrintPath(allocator, "{s}.idx.{s}.{d}.{s}.{d}.dat", .{ table_name, BLOB_CONTAINS_INDEX_KIND, column_index, store_name, epoch });
}

fn dictFileName(allocator: std.mem.Allocator, table_name: []const u8, dict_name: []const u8, epoch: u64) TableError![]u8 {
    return allocPrintPath(allocator, "{s}.dict.{s}.{d}.dat", .{ table_name, dict_name, epoch });
}

fn blobStoreFileName(allocator: std.mem.Allocator, table_name: []const u8, store_name: []const u8, epoch: u64) TableError![]u8 {
    return allocPrintPath(allocator, "{s}.blob.{s}.{d}.dat", .{ table_name, store_name, epoch });
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

fn parseTxCommitMarker(allocator: std.mem.Allocator, source: []const u8) TableError!std.json.Parsed(TxCommitMarker) {
    const parsed = std.json.parseFromSlice(TxCommitMarker, allocator, source, .{}) catch |err| return mapJsonError(err);
    if (!std.mem.eql(u8, parsed.value.magic, "sa-db-tx-commit")) {
        parsed.deinit();
        return TableError.InvalidFormat;
    }
    if (parsed.value.version != 1) {
        parsed.deinit();
        return TableError.InvalidFormat;
    }
    return parsed;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
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
            .logical_type = column.logical_type,
            .logical_scale = column.logical_scale,
            .nullable = column.nullable,
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
            .logical_type = column.logical_type,
            .logical_scale = column.logical_scale,
            .nullable = column.nullable,
        };
    }

    const segments = try allocator.alloc(SegmentMeta, meta.segments.len);
    initSegmentMetas(segments);
    errdefer {
        for (segments) |segment| {
            freeFileMetas(allocator, segment.files);
        }
        allocator.free(segments);
    }
    for (meta.segments, 0..) |segment, idx| {
        const files = try allocator.alloc(FileMeta, segment.files.len);
        initFileMetas(files);
        errdefer {
            for (files) |file| freeFileMeta(allocator, file);
            allocator.free(files);
        }
        for (segment.files, 0..) |file, file_idx| {
            files[file_idx] = try duplicateFileMeta(allocator, file);
        }
        segments[idx] = .{
            .id = segment.id,
            .rows = segment.rows,
            .files = files,
        };
    }

    const indexes = try duplicateIndexMetas(allocator, meta.indexes);
    errdefer freeIndexMetas(allocator, indexes);

    const dicts = try duplicateDictMetas(allocator, meta.dicts);
    errdefer freeDictMetas(allocator, dicts);

    const blobs = try duplicateBlobStoreMetas(allocator, meta.blobs);
    errdefer freeBlobStoreMetas(allocator, blobs);

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
        .indexes = indexes,
        .dicts = dicts,
        .blobs = blobs,
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
        .indexes = try allocator.alloc(IndexMeta, 0),
        .dicts = try allocator.alloc(DictMeta, 0),
        .blobs = try allocator.alloc(BlobStoreMeta, 0),
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

fn blockHashCount(byte_len: usize, block_size: usize) usize {
    if (byte_len == 0) return 0;
    return (byte_len + block_size - 1) / block_size;
}

fn makeBlockSha256List(allocator: std.mem.Allocator, bytes: []const u8, block_size: usize) TableError![][]const u8 {
    const count = blockHashCount(bytes.len, block_size);
    const out = try allocator.alloc([]const u8, count);
    for (out) |*hash| hash.* = &.{};
    errdefer {
        for (out) |hash| allocator.free(hash);
        allocator.free(out);
    }

    for (out, 0..) |*slot, idx| {
        const start = idx * block_size;
        const end = @min(start + block_size, bytes.len);
        slot.* = try hashHexAlloc(allocator, bytes[start..end]);
    }
    return out;
}

fn freeBlockSha256List(allocator: std.mem.Allocator, hashes: [][]const u8) void {
    for (hashes) |hash| allocator.free(hash);
    allocator.free(hashes);
}

fn duplicateBlockSha256List(allocator: std.mem.Allocator, hashes: []const []const u8) TableError![][]const u8 {
    const out = try allocator.alloc([]const u8, hashes.len);
    for (out) |*hash| hash.* = &.{};
    errdefer freeBlockSha256List(allocator, out);
    for (hashes, 0..) |hash, idx| out[idx] = try allocator.dupe(u8, hash);
    return out;
}

fn artifactBlockSize(bytes: []const u8) u64 {
    return if (bytes.len == 0) 0 else FILE_BLOCK_BYTES;
}

fn validateBlockSha256List(block_size_value: u64, block_sha256: []const []const u8, bytes: []const u8) TableError!void {
    if (block_size_value == 0) {
        if (block_sha256.len != 0) return TableError.VerifyFailed;
        return;
    }
    if (block_size_value > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.VerifyFailed;
    const block_size: usize = @intCast(block_size_value);
    if (block_size == 0) return TableError.VerifyFailed;
    const expected_count = blockHashCount(bytes.len, block_size);
    if (block_sha256.len != expected_count) return TableError.VerifyFailed;
    for (block_sha256, 0..) |expected_hash, idx| {
        if (expected_hash.len != 64) return TableError.VerifyFailed;
        const start = idx * block_size;
        const end = @min(start + block_size, bytes.len);
        const actual_hash = hashBytes(bytes[start..end]);
        const actual_hex = std.fmt.bytesToHex(actual_hash, .lower);
        if (!std.mem.eql(u8, actual_hex[0..], expected_hash)) return TableError.VerifyFailed;
    }
}

fn makeFileMeta(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) TableError!FileMeta {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const sha256 = try hashHexAlloc(allocator, bytes);
    errdefer allocator.free(sha256);
    const block_sha256 = try makeBlockSha256List(allocator, bytes, FILE_BLOCK_BYTES);
    errdefer freeBlockSha256List(allocator, block_sha256);
    return .{
        .path = owned_path,
        .sha256 = sha256,
        .bytes = bytes.len,
        .block_size = artifactBlockSize(bytes),
        .block_sha256 = block_sha256,
    };
}

fn freeFileMeta(allocator: std.mem.Allocator, file: FileMeta) void {
    allocator.free(file.path);
    allocator.free(file.sha256);
    freeBlockSha256List(allocator, file.block_sha256);
}

fn duplicateFileMeta(allocator: std.mem.Allocator, file: FileMeta) TableError!FileMeta {
    const path = try allocator.dupe(u8, file.path);
    errdefer allocator.free(path);
    const sha256 = try allocator.dupe(u8, file.sha256);
    errdefer allocator.free(sha256);
    const block_sha256 = try duplicateBlockSha256List(allocator, file.block_sha256);
    errdefer freeBlockSha256List(allocator, block_sha256);
    return .{
        .path = path,
        .sha256 = sha256,
        .bytes = file.bytes,
        .block_size = file.block_size,
        .block_sha256 = block_sha256,
    };
}

fn emptyFileMeta() FileMeta {
    return .{ .path = &.{}, .sha256 = &.{}, .bytes = 0 };
}

fn initFileMetas(files: []FileMeta) void {
    for (files) |*file| file.* = emptyFileMeta();
}

fn initSegmentMetas(segments: []SegmentMeta) void {
    for (segments) |*segment| segment.* = .{ .id = 0, .rows = 0, .files = &.{} };
}

pub fn validateFileBlockHashes(file: FileMeta, bytes: []const u8) TableError!void {
    try validateBlockSha256List(file.block_size, file.block_sha256, bytes);
}

fn validateIndexBlockHashes(index: IndexMeta, bytes: []const u8) TableError!void {
    try validateBlockSha256List(index.block_size, index.block_sha256, bytes);
}

fn validateDictBlockHashes(dict: DictMeta, bytes: []const u8) TableError!void {
    try validateBlockSha256List(dict.block_size, dict.block_sha256, bytes);
}

fn validateBlobStoreBlockHashes(blob: BlobStoreMeta, bytes: []const u8) TableError!void {
    try validateBlockSha256List(blob.block_size, blob.block_sha256, bytes);
}

fn validateFileMetaBytes(file: FileMeta, bytes: []const u8) TableError!void {
    if (bytes.len != file.bytes) return TableError.VerifyFailed;
    const hash = hashBytes(bytes);
    const hex = std.fmt.bytesToHex(hash, .lower);
    if (!std.mem.eql(u8, hex[0..], file.sha256)) return TableError.VerifyFailed;
    try validateFileBlockHashes(file, bytes);
}

fn writeSegmentFiles(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    seg_id: u64,
    buffers: []std.ArrayList(u8),
) TableError![]FileMeta {
    const files = try allocator.alloc(FileMeta, buffers.len);
    initFileMetas(files);
    errdefer {
        for (files) |file| freeFileMeta(allocator, file);
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
    for (files) |file| freeFileMeta(allocator, file);
    allocator.free(files);
}

fn freeSegmentMetas(allocator: std.mem.Allocator, segments: []SegmentMeta) void {
    for (segments) |segment| {
        freeFileMetas(allocator, segment.files);
    }
    allocator.free(segments);
}

fn emptyIndexMeta() IndexMeta {
    return .{
        .name = &.{},
        .kind = &.{},
        .column_index = 0,
        .column_index2 = null,
        .store_name = null,
        .unique = false,
        .path = &.{},
        .sha256 = &.{},
        .bytes = 0,
    };
}

fn initIndexMetas(indexes: []IndexMeta) void {
    for (indexes) |*index| index.* = emptyIndexMeta();
}

fn freeIndexMeta(allocator: std.mem.Allocator, index: IndexMeta) void {
    allocator.free(index.name);
    allocator.free(index.kind);
    if (index.store_name) |store_name| allocator.free(store_name);
    allocator.free(index.path);
    allocator.free(index.sha256);
    freeBlockSha256List(allocator, index.block_sha256);
}

fn freeIndexMetas(allocator: std.mem.Allocator, indexes: []IndexMeta) void {
    for (indexes) |index| freeIndexMeta(allocator, index);
    allocator.free(indexes);
}

fn duplicateIndexMeta(allocator: std.mem.Allocator, index: IndexMeta) TableError!IndexMeta {
    const name = try allocator.dupe(u8, index.name);
    errdefer allocator.free(name);
    const kind = try allocator.dupe(u8, index.kind);
    errdefer allocator.free(kind);
    const store_name = if (index.store_name) |value| try allocator.dupe(u8, value) else null;
    errdefer if (store_name) |value| allocator.free(value);
    const path = try allocator.dupe(u8, index.path);
    errdefer allocator.free(path);
    const sha256 = try allocator.dupe(u8, index.sha256);
    errdefer allocator.free(sha256);
    const block_sha256 = try duplicateBlockSha256List(allocator, index.block_sha256);
    errdefer freeBlockSha256List(allocator, block_sha256);
    return .{
        .name = name,
        .kind = kind,
        .column_index = index.column_index,
        .column_index2 = index.column_index2,
        .store_name = store_name,
        .unique = index.unique,
        .path = path,
        .sha256 = sha256,
        .bytes = index.bytes,
        .block_size = index.block_size,
        .block_sha256 = block_sha256,
    };
}

fn emptyDictMeta() DictMeta {
    return .{ .name = &.{}, .path = &.{}, .sha256 = &.{}, .bytes = 0, .entries = 0 };
}

fn initDictMetas(dicts: []DictMeta) void {
    for (dicts) |*dict| dict.* = emptyDictMeta();
}

fn freeDictMeta(allocator: std.mem.Allocator, dict: DictMeta) void {
    allocator.free(dict.name);
    allocator.free(dict.path);
    allocator.free(dict.sha256);
    freeBlockSha256List(allocator, dict.block_sha256);
}

fn freeDictMetas(allocator: std.mem.Allocator, dicts: []DictMeta) void {
    for (dicts) |dict| freeDictMeta(allocator, dict);
    allocator.free(dicts);
}

fn duplicateDictMeta(allocator: std.mem.Allocator, dict: DictMeta) TableError!DictMeta {
    const name = try allocator.dupe(u8, dict.name);
    errdefer allocator.free(name);
    const path = try allocator.dupe(u8, dict.path);
    errdefer allocator.free(path);
    const sha256 = try allocator.dupe(u8, dict.sha256);
    errdefer allocator.free(sha256);
    const block_sha256 = try duplicateBlockSha256List(allocator, dict.block_sha256);
    errdefer freeBlockSha256List(allocator, block_sha256);
    return .{
        .name = name,
        .path = path,
        .sha256 = sha256,
        .bytes = dict.bytes,
        .entries = dict.entries,
        .block_size = dict.block_size,
        .block_sha256 = block_sha256,
    };
}

fn duplicateDictMetas(allocator: std.mem.Allocator, dicts: []const DictMeta) TableError![]DictMeta {
    const out = try allocator.alloc(DictMeta, dicts.len);
    initDictMetas(out);
    errdefer freeDictMetas(allocator, out);
    for (dicts, 0..) |dict, idx| {
        out[idx] = try duplicateDictMeta(allocator, dict);
    }
    return out;
}

fn emptyBlobStoreMeta() BlobStoreMeta {
    return .{ .name = &.{}, .path = &.{}, .sha256 = &.{}, .bytes = 0, .entries = 0 };
}

fn initBlobStoreMetas(blobs: []BlobStoreMeta) void {
    for (blobs) |*blob| blob.* = emptyBlobStoreMeta();
}

fn freeBlobStoreMeta(allocator: std.mem.Allocator, blob: BlobStoreMeta) void {
    allocator.free(blob.name);
    allocator.free(blob.path);
    allocator.free(blob.sha256);
    freeBlockSha256List(allocator, blob.block_sha256);
}

fn freeBlobStoreMetas(allocator: std.mem.Allocator, blobs: []BlobStoreMeta) void {
    for (blobs) |blob| freeBlobStoreMeta(allocator, blob);
    allocator.free(blobs);
}

fn duplicateBlobStoreMeta(allocator: std.mem.Allocator, blob: BlobStoreMeta) TableError!BlobStoreMeta {
    const name = try allocator.dupe(u8, blob.name);
    errdefer allocator.free(name);
    const path = try allocator.dupe(u8, blob.path);
    errdefer allocator.free(path);
    const sha256 = try allocator.dupe(u8, blob.sha256);
    errdefer allocator.free(sha256);
    const block_sha256 = try duplicateBlockSha256List(allocator, blob.block_sha256);
    errdefer freeBlockSha256List(allocator, block_sha256);
    return .{
        .name = name,
        .path = path,
        .sha256 = sha256,
        .bytes = blob.bytes,
        .entries = blob.entries,
        .block_size = blob.block_size,
        .block_sha256 = block_sha256,
    };
}

fn duplicateBlobStoreMetas(allocator: std.mem.Allocator, blobs: []const BlobStoreMeta) TableError![]BlobStoreMeta {
    const out = try allocator.alloc(BlobStoreMeta, blobs.len);
    initBlobStoreMetas(out);
    errdefer freeBlobStoreMetas(allocator, out);
    for (blobs, 0..) |blob, idx| {
        out[idx] = try duplicateBlobStoreMeta(allocator, blob);
    }
    return out;
}

fn duplicateSegmentMetas(allocator: std.mem.Allocator, segments: []const SegmentMeta) TableError![]SegmentMeta {
    const out = try allocator.alloc(SegmentMeta, segments.len);
    initSegmentMetas(out);
    errdefer {
        for (out) |segment| {
            freeFileMetas(allocator, segment.files);
        }
        allocator.free(out);
    }

    for (segments, 0..) |segment, idx| {
        const files = try allocator.alloc(FileMeta, segment.files.len);
        initFileMetas(files);
        errdefer {
            for (files) |file| freeFileMeta(allocator, file);
            allocator.free(files);
        }
        for (segment.files, 0..) |file, file_idx| {
            files[file_idx] = try duplicateFileMeta(allocator, file);
        }
        out[idx] = .{
            .id = segment.id,
            .rows = segment.rows,
            .files = files,
        };
    }

    return out;
}

fn duplicateIndexMetas(allocator: std.mem.Allocator, indexes: []const IndexMeta) TableError![]IndexMeta {
    const out = try allocator.alloc(IndexMeta, indexes.len);
    initIndexMetas(out);
    errdefer freeIndexMetas(allocator, out);
    for (indexes, 0..) |index, idx| {
        out[idx] = try duplicateIndexMeta(allocator, index);
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
    initFileMetas(files);
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

    for (meta.indexes) |index| {
        const src_path = try activePath(allocator, root_dir, index.path);
        defer allocator.free(src_path);
        const dst_path = try joinPath(allocator, &.{ snapshot_dir_path, index.path });
        defer allocator.free(dst_path);
        try copyFile(allocator, src_path, dst_path);
    }

    for (meta.dicts) |dict| {
        const src_path = try activePath(allocator, root_dir, dict.path);
        defer allocator.free(src_path);
        const dst_path = try joinPath(allocator, &.{ snapshot_dir_path, dict.path });
        defer allocator.free(dst_path);
        try copyFile(allocator, src_path, dst_path);
    }

    for (meta.blobs) |blob| {
        const src_path = try activePath(allocator, root_dir, blob.path);
        defer allocator.free(src_path);
        const dst_path = try joinPath(allocator, &.{ snapshot_dir_path, blob.path });
        defer allocator.free(dst_path);
        try copyFile(allocator, src_path, dst_path);
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

    for (parsed.value.indexes) |index| {
        const src_path = try joinPath(allocator, &.{ snapshot_dir_path, index.path });
        defer allocator.free(src_path);
        const dst_path = try activePath(allocator, root_dir, index.path);
        defer allocator.free(dst_path);
        try copyFile(allocator, src_path, dst_path);
    }

    for (parsed.value.dicts) |dict| {
        const src_path = try joinPath(allocator, &.{ snapshot_dir_path, dict.path });
        defer allocator.free(src_path);
        const dst_path = try activePath(allocator, root_dir, dict.path);
        defer allocator.free(dst_path);
        try copyFile(allocator, src_path, dst_path);
    }

    for (parsed.value.blobs) |blob| {
        const src_path = try joinPath(allocator, &.{ snapshot_dir_path, blob.path });
        defer allocator.free(src_path);
        const dst_path = try activePath(allocator, root_dir, blob.path);
        defer allocator.free(dst_path);
        try copyFile(allocator, src_path, dst_path);
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
            try validateFileMetaBytes(file, bytes);
            if (bytes.len != expected_bytes) return TableError.VerifyFailed;
        }
    }
    if (total_rows != meta.row_count) return TableError.VerifyFailed;
}

fn validateIndexFiles(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta) TableError!void {
    for (meta.indexes) |index| {
        if (index.column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.VerifyFailed;
        const column_index: usize = @intCast(index.column_index);
        var expected_bytes: usize = undefined;
        if (std.mem.eql(u8, index.kind, "u64")) {
            if (index.column_index2 != null) return TableError.VerifyFailed;
            try ensureU64Column(meta, column_index);
            expected_bytes = try expectedIndexBytes(meta.row_count);
        } else if (std.mem.eql(u8, index.kind, "i64")) {
            if (index.column_index2 != null) return TableError.VerifyFailed;
            try ensureI64Column(meta, column_index);
            expected_bytes = try expectedIndexBytes(meta.row_count);
        } else if (std.mem.eql(u8, index.kind, "f32")) {
            if (index.column_index2 != null) return TableError.VerifyFailed;
            try ensureF32Column(meta, column_index);
            expected_bytes = try expectedIndexBytes(meta.row_count);
        } else if (std.mem.eql(u8, index.kind, "f64")) {
            if (index.column_index2 != null) return TableError.VerifyFailed;
            try ensureF64Column(meta, column_index);
            expected_bytes = try expectedIndexBytes(meta.row_count);
        } else if (std.mem.eql(u8, index.kind, "u8")) {
            if (index.column_index2 != null) return TableError.VerifyFailed;
            try ensureU8Column(meta, column_index);
            expected_bytes = try expectedIndexBytes(meta.row_count);
        } else if (std.mem.eql(u8, index.kind, "i8")) {
            if (index.column_index2 != null) return TableError.VerifyFailed;
            try ensureI8Column(meta, column_index);
            expected_bytes = try expectedIndexBytes(meta.row_count);
        } else if (std.mem.eql(u8, index.kind, "u16")) {
            if (index.column_index2 != null) return TableError.VerifyFailed;
            try ensureU16Column(meta, column_index);
            expected_bytes = try expectedIndexBytes(meta.row_count);
        } else if (std.mem.eql(u8, index.kind, "i16")) {
            if (index.column_index2 != null) return TableError.VerifyFailed;
            try ensureI16Column(meta, column_index);
            expected_bytes = try expectedIndexBytes(meta.row_count);
        } else if (std.mem.eql(u8, index.kind, "u32")) {
            if (index.column_index2 != null) return TableError.VerifyFailed;
            try ensureU32Column(meta, column_index);
            expected_bytes = try expectedIndexBytes(meta.row_count);
        } else if (std.mem.eql(u8, index.kind, "i32")) {
            if (index.column_index2 != null) return TableError.VerifyFailed;
            try ensureI32Column(meta, column_index);
            expected_bytes = try expectedIndexBytes(meta.row_count);
        } else if (std.mem.eql(u8, index.kind, "u64_pair")) {
            const column_index2 = try indexColumnIndex2(index);
            try ensureU64PairColumns(meta, column_index, column_index2);
            expected_bytes = try expectedU64PairIndexBytes(meta.row_count);
        } else if (std.mem.eql(u8, index.kind, "u64_i64_pair")) {
            const column_index2 = try indexColumnIndex2(index);
            try ensureU64I64PairColumns(meta, column_index, column_index2);
            expected_bytes = try expectedU64PairIndexBytes(meta.row_count);
        } else if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND)) {
            if (index.column_index2 != null) return TableError.VerifyFailed;
            _ = try indexBlobStoreName(index);
            try ensureBlobHandleColumn(meta, column_index);
            expected_bytes = try expectedIndexBytes(meta.row_count);
        } else if (std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND)) {
            if (index.column_index2 != null or index.unique) return TableError.VerifyFailed;
            _ = try indexBlobStoreName(index);
            try ensureBlobHandleColumn(meta, column_index);
            if (index.bytes > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.VerifyFailed;
            expected_bytes = @intCast(index.bytes);
        } else if (std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND)) {
            if (index.column_index2 != null or index.unique) return TableError.VerifyFailed;
            _ = try indexBlobStoreName(index);
            try ensureBlobHandleColumn(meta, column_index);
            if (index.bytes > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.VerifyFailed;
            expected_bytes = @intCast(index.bytes);
        } else if (std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND)) {
            if (index.column_index2 != null or index.unique) return TableError.VerifyFailed;
            _ = try indexBlobStoreName(index);
            try ensureBlobHandleColumn(meta, column_index);
            if (index.bytes > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.VerifyFailed;
            expected_bytes = @intCast(index.bytes);
        } else {
            return TableError.VerifyFailed;
        }
        if (index.bytes != @as(u64, @intCast(expected_bytes))) return TableError.VerifyFailed;
        const path = try activePath(allocator, root_dir, index.path);
        defer allocator.free(path);
        const bytes = try readFileAlloc(allocator, path, 1 << 30);
        defer allocator.free(bytes);
        if (bytes.len != index.bytes) return TableError.VerifyFailed;
        const hash = hashBytes(bytes);
        const hex = std.fmt.bytesToHex(hash, .lower);
        if (!std.mem.eql(u8, hex[0..], index.sha256)) return TableError.VerifyFailed;
        try validateIndexBlockHashes(index, bytes);
        if (std.mem.eql(u8, index.kind, "u64_pair") or std.mem.eql(u8, index.kind, "u64_i64_pair")) {
            try validateU64PairIndexBytesShape(bytes, meta.row_count, index.unique);
        } else if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND)) {
            try validateIndexBytesShape(bytes, meta.row_count, false);
        } else if (std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND)) {
            try validateVariableIndexBytesShape(bytes, meta.row_count);
        } else {
            try validateIndexBytesShape(bytes, meta.row_count, index.unique);
        }
        const expected = if (std.mem.eql(u8, index.kind, "u64"))
            try buildU64IndexBytes(allocator, root_dir, meta, column_index, index.unique)
        else if (std.mem.eql(u8, index.kind, "i64"))
            try buildI64IndexBytes(allocator, root_dir, meta, column_index, index.unique)
        else if (std.mem.eql(u8, index.kind, "f32"))
            try buildF32IndexBytes(allocator, root_dir, meta, column_index, index.unique)
        else if (std.mem.eql(u8, index.kind, "f64"))
            try buildF64IndexBytes(allocator, root_dir, meta, column_index, index.unique)
        else if (std.mem.eql(u8, index.kind, "u8"))
            try buildU8IndexBytes(allocator, root_dir, meta, column_index, index.unique)
        else if (std.mem.eql(u8, index.kind, "i8"))
            try buildI8IndexBytes(allocator, root_dir, meta, column_index, index.unique)
        else if (std.mem.eql(u8, index.kind, "u16"))
            try buildU16IndexBytes(allocator, root_dir, meta, column_index, index.unique)
        else if (std.mem.eql(u8, index.kind, "i16"))
            try buildI16IndexBytes(allocator, root_dir, meta, column_index, index.unique)
        else if (std.mem.eql(u8, index.kind, "u32"))
            try buildU32IndexBytes(allocator, root_dir, meta, column_index, index.unique)
        else if (std.mem.eql(u8, index.kind, "i32"))
            try buildI32IndexBytes(allocator, root_dir, meta, column_index, index.unique)
        else if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND))
            try buildBlobEqIndexBytes(allocator, root_dir, meta, column_index, try indexBlobStoreName(index), index.unique)
        else if (std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND))
            try buildBlobTokenIndexBytes(allocator, root_dir, meta, column_index, try indexBlobStoreName(index))
        else if (std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND))
            try buildBlobPrefixIndexBytes(allocator, root_dir, meta, column_index, try indexBlobStoreName(index))
        else if (std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND))
            try buildBlobContainsIndexBytes(allocator, root_dir, meta, column_index, try indexBlobStoreName(index))
        else if (std.mem.eql(u8, index.kind, "u64_pair"))
            try buildU64PairIndexBytes(allocator, root_dir, meta, column_index, try indexColumnIndex2(index), index.unique)
        else
            try buildU64I64PairIndexBytes(allocator, root_dir, meta, column_index, try indexColumnIndex2(index), index.unique);
        defer allocator.free(expected);
        if (!std.mem.eql(u8, bytes, expected)) return TableError.VerifyFailed;
    }
}

const DICT_MAX_NAME_BYTES: usize = 64;
const DICT_MAX_VALUE_BYTES: usize = 1024 * 1024;
const BLOB_STORE_MAX_NAME_BYTES: usize = 64;
const BLOB_MAX_VALUE_BYTES: usize = 16 * 1024 * 1024;

fn validateDictName(dict_name: []const u8) TableError!void {
    if (dict_name.len == 0 or dict_name.len > DICT_MAX_NAME_BYTES) return TableError.InvalidFormat;
    for (dict_name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return TableError.InvalidFormat;
    }
}

fn validateDictValue(value: []const u8) TableError!void {
    if (value.len == 0 or value.len > DICT_MAX_VALUE_BYTES) return TableError.InvalidFormat;
}

fn validateBlobStoreName(store_name: []const u8) TableError!void {
    if (store_name.len == 0 or store_name.len > BLOB_STORE_MAX_NAME_BYTES) return TableError.InvalidFormat;
    for (store_name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return TableError.InvalidFormat;
    }
}

fn validateBlobValue(value: []const u8) TableError!void {
    if (value.len > BLOB_MAX_VALUE_BYTES) return TableError.InvalidFormat;
}

fn dictEntryCount(bytes: []const u8) TableError!u64 {
    if (bytes.len < 8) return TableError.VerifyFailed;
    const count = readU64LE(bytes, 0);
    var offset: usize = 8;
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        if (offset > bytes.len or bytes.len - offset < 8) return TableError.VerifyFailed;
        const len_u64 = readU64LE(bytes, offset);
        if (len_u64 == 0 or len_u64 > DICT_MAX_VALUE_BYTES) return TableError.VerifyFailed;
        if (len_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.VerifyFailed;
        const len: usize = @intCast(len_u64);
        offset += 8;
        if (offset > bytes.len or bytes.len - offset < len) return TableError.VerifyFailed;
        offset += len;
    }
    if (offset != bytes.len) return TableError.VerifyFailed;
    return count;
}

fn dictValueSliceById(bytes: []const u8, id: u64) TableError!?[]const u8 {
    if (id == 0) return null;
    const count = try dictEntryCount(bytes);
    if (id > count) return null;
    var offset: usize = 8;
    var current_id: u64 = 1;
    while (current_id <= count) : (current_id += 1) {
        const len_u64 = readU64LE(bytes, offset);
        const len: usize = @intCast(len_u64);
        offset += 8;
        const value = bytes[offset .. offset + len];
        if (current_id == id) return value;
        offset += len;
    }
    return null;
}

fn dictFindValueId(bytes: []const u8, value: []const u8) TableError!?u64 {
    const count = try dictEntryCount(bytes);
    var offset: usize = 8;
    var current_id: u64 = 1;
    while (current_id <= count) : (current_id += 1) {
        const len_u64 = readU64LE(bytes, offset);
        const len: usize = @intCast(len_u64);
        offset += 8;
        const candidate = bytes[offset .. offset + len];
        if (std.mem.eql(u8, candidate, value)) return current_id;
        offset += len;
    }
    return null;
}

fn findDictMetaIndex(meta: TableMeta, dict_name: []const u8) ?usize {
    for (meta.dicts, 0..) |dict, idx| {
        if (std.mem.eql(u8, dict.name, dict_name)) return idx;
    }
    return null;
}

fn readDictBytes(allocator: std.mem.Allocator, root_dir: []const u8, dict: DictMeta) TableError![]u8 {
    const path = try activePath(allocator, root_dir, dict.path);
    defer allocator.free(path);
    const bytes = try readFileAlloc(allocator, path, 1 << 30);
    errdefer allocator.free(bytes);
    if (bytes.len != dict.bytes) return TableError.VerifyFailed;
    const count = try dictEntryCount(bytes);
    if (count != dict.entries) return TableError.VerifyFailed;
    const hash = hashBytes(bytes);
    const hex = std.fmt.bytesToHex(hash, .lower);
    if (!std.mem.eql(u8, hex[0..], dict.sha256)) return TableError.VerifyFailed;
    try validateDictBlockHashes(dict, bytes);
    return bytes;
}

fn validateDictFiles(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta) TableError!void {
    for (meta.dicts, 0..) |dict, idx| {
        try validateDictName(dict.name);
        if (dict.path.len == 0 or dict.sha256.len != 64) return TableError.VerifyFailed;
        for (meta.dicts[0..idx]) |previous| {
            if (std.mem.eql(u8, previous.name, dict.name)) return TableError.VerifyFailed;
        }
        const bytes = try readDictBytes(allocator, root_dir, dict);
        allocator.free(bytes);
    }
}

fn blobEntryCount(bytes: []const u8) TableError!u64 {
    if (bytes.len < 8) return TableError.VerifyFailed;
    const count = readU64LE(bytes, 0);
    var offset: usize = 8;
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        if (offset > bytes.len or bytes.len - offset < 8) return TableError.VerifyFailed;
        const len_u64 = readU64LE(bytes, offset);
        if (len_u64 > BLOB_MAX_VALUE_BYTES) return TableError.VerifyFailed;
        if (len_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.VerifyFailed;
        const len: usize = @intCast(len_u64);
        offset += 8;
        if (offset > bytes.len or bytes.len - offset < len) return TableError.VerifyFailed;
        offset += len;
    }
    if (offset != bytes.len) return TableError.VerifyFailed;
    return count;
}

fn blobValueSliceById(bytes: []const u8, id: u64) TableError!?[]const u8 {
    if (id == 0) return null;
    const count = try blobEntryCount(bytes);
    if (id > count) return null;
    var offset: usize = 8;
    var current_id: u64 = 1;
    while (current_id <= count) : (current_id += 1) {
        const len_u64 = readU64LE(bytes, offset);
        const len: usize = @intCast(len_u64);
        offset += 8;
        const value = bytes[offset .. offset + len];
        if (current_id == id) return value;
        offset += len;
    }
    return null;
}

fn findBlobStoreMetaIndex(meta: TableMeta, store_name: []const u8) ?usize {
    for (meta.blobs, 0..) |blob, idx| {
        if (std.mem.eql(u8, blob.name, store_name)) return idx;
    }
    return null;
}

fn readBlobStoreBytes(allocator: std.mem.Allocator, root_dir: []const u8, blob: BlobStoreMeta) TableError![]u8 {
    const path = try activePath(allocator, root_dir, blob.path);
    defer allocator.free(path);
    const bytes = try readFileAlloc(allocator, path, 1 << 30);
    errdefer allocator.free(bytes);
    if (bytes.len != blob.bytes) return TableError.VerifyFailed;
    const count = try blobEntryCount(bytes);
    if (count != blob.entries) return TableError.VerifyFailed;
    const hash = hashBytes(bytes);
    const hex = std.fmt.bytesToHex(hash, .lower);
    if (!std.mem.eql(u8, hex[0..], blob.sha256)) return TableError.VerifyFailed;
    try validateBlobStoreBlockHashes(blob, bytes);
    return bytes;
}

fn validateBlobStoreFiles(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta) TableError!void {
    for (meta.blobs, 0..) |blob, idx| {
        try validateBlobStoreName(blob.name);
        if (blob.path.len == 0 or blob.sha256.len != 64) return TableError.VerifyFailed;
        for (meta.blobs[0..idx]) |previous| {
            if (std.mem.eql(u8, previous.name, blob.name)) return TableError.VerifyFailed;
        }
        const bytes = try readBlobStoreBytes(allocator, root_dir, blob);
        allocator.free(bytes);
    }
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

    for (meta.indexes) |index| {
        const path = try activePath(allocator, root_dir, index.path);
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

    for (meta.dicts) |dict| {
        const path = try activePath(allocator, root_dir, dict.path);
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

    for (meta.blobs) |blob| {
        const path = try activePath(allocator, root_dir, blob.path);
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

fn validateRecoverCandidate(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta) TableError!void {
    if (!std.mem.eql(u8, meta.table_name, table_name)) return TableError.InvalidFormat;
    const schema_hash = try schemaHashFromFile(allocator, root_dir, table_name);
    defer allocator.free(schema_hash);
    if (!std.mem.eql(u8, meta.schema_hash, schema_hash)) return TableError.VerifyFailed;
    var schema_obj = try loadSchema(allocator, root_dir, table_name);
    defer schema_obj.deinit();
    try verifySchemaAgainstMeta(schema_obj, meta);
    try validateSegmentHashes(allocator, root_dir, meta);
    try validateIndexFiles(allocator, root_dir, meta);
    try validateDictFiles(allocator, root_dir, meta);
    try validateBlobStoreFiles(allocator, root_dir, meta);
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
    const pending_path = txPendingMarkerPath(allocator, root_dir, table_name, parsed.value.epoch) catch return;
    defer allocator.free(pending_path);
    const commit_path = txCommitMarkerPath(allocator, root_dir, table_name, parsed.value.epoch) catch return;
    defer allocator.free(commit_path);
    const has_pending = fileExists(pending_path);
    const has_commit = fileExists(commit_path);
    if (has_commit) {
        validateTxCommitMarkerForMeta(allocator, root_dir, table_name, parsed.value, source) catch return;
    } else if (has_pending) {
        return;
    }
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

fn cleanupPendingTxMarkers(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError!void {
    const dir_path = rootPrefix(root_dir);
    var dir = std.fs.cwd().openDir(if (dir_path.len == 0) "." else dir_path, .{ .iterate = true }) catch |err| return mapFileError(err);
    defer dir.close();

    const prefix = try allocPrintPath(allocator, "{s}.tx.", .{table_name});
    defer allocator.free(prefix);
    const suffix = ".pending";
    var it = dir.iterate();
    while (it.next() catch |err| return mapFileError(err)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        const epoch_text = entry.name[prefix.len .. entry.name.len - suffix.len];
        if (epoch_text.len == 0) continue;
        _ = std.fmt.parseInt(u64, epoch_text, 10) catch continue;
        const path = try activePath(allocator, root_dir, entry.name);
        defer allocator.free(path);
        try deleteIfExists(path);
    }
}

fn deleteRootTableArtifacts(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError!void {
    const dir_path = rootPrefix(root_dir);
    var dir = std.fs.cwd().openDir(if (dir_path.len == 0) "." else dir_path, .{ .iterate = true }) catch |err| return mapFileError(err);
    defer dir.close();

    const prefix = try allocPrintPath(allocator, "{s}.", .{table_name});
    defer allocator.free(prefix);
    const lock_name = try tableWriteLockName(allocator, table_name);
    defer allocator.free(lock_name);
    var it = dir.iterate();
    while (it.next() catch |err| return mapFileError(err)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (std.mem.eql(u8, entry.name, lock_name)) continue;
        const path = try activePath(allocator, root_dir, entry.name);
        defer allocator.free(path);
        try deleteIfExists(path);
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

    for (meta.indexes) |index| {
        const path = try activePath(allocator, root_dir, index.path);
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

    for (meta.dicts) |dict| {
        const path = try activePath(allocator, root_dir, dict.path);
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

    for (meta.blobs) |blob| {
        const path = try activePath(allocator, root_dir, blob.path);
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

fn writeVersionedMeta(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta) TableError!WrittenMeta {
    const json = std.json.stringifyAlloc(allocator, meta, .{}) catch |err| return mapJsonError(err);
    errdefer allocator.free(json);

    const versioned_name = try tableVersionedMetaName(allocator, table_name, meta.epoch);
    errdefer allocator.free(versioned_name);
    const versioned_path = try activePath(allocator, root_dir, versioned_name);
    defer allocator.free(versioned_path);
    try writeFile(allocator, versioned_path, json);

    const meta_hash = try hashHexAlloc(allocator, json);
    errdefer allocator.free(meta_hash);
    return .{
        .json = json,
        .versioned_name = versioned_name,
        .meta_hash = meta_hash,
        .meta_bytes = json.len,
    };
}

fn publishWrittenMeta(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta, written: WrittenMeta) TableError!void {
    const manifest: TableManifest = .{
        .magic = "sa-db-table-manifest",
        .version = 1,
        .table_name = table_name,
        .epoch = meta.epoch,
        .meta_path = written.versioned_name,
        .meta_sha256 = written.meta_hash,
        .meta_bytes = written.meta_bytes,
    };
    const manifest_json = std.json.stringifyAlloc(allocator, manifest, .{}) catch |err| return mapJsonError(err);
    defer allocator.free(manifest_json);
    const manifest_path = try tableManifestPath(allocator, root_dir, table_name);
    defer allocator.free(manifest_path);
    try writeFile(allocator, manifest_path, manifest_json);

    const compat_path = try tableMetaPath(allocator, root_dir, table_name);
    defer allocator.free(compat_path);
    try writeFile(allocator, compat_path, written.json);
}

fn writeMeta(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta) TableError!void {
    var written = try writeVersionedMeta(allocator, root_dir, table_name, meta);
    defer written.deinit(allocator);
    try publishWrittenMeta(allocator, root_dir, table_name, meta, written);
}

fn writeTxPendingMarker(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, previous_epoch: u64, target_epoch: u64) TableError!void {
    const marker: TxPendingMarker = .{
        .magic = "sa-db-tx-pending",
        .version = 1,
        .table_name = table_name,
        .previous_epoch = previous_epoch,
        .target_epoch = target_epoch,
    };
    const json = std.json.stringifyAlloc(allocator, marker, .{}) catch |err| return mapJsonError(err);
    defer allocator.free(json);
    const path = try txPendingMarkerPath(allocator, root_dir, table_name, target_epoch);
    defer allocator.free(path);
    try writeFile(allocator, path, json);
}

fn writeTxCommitMarker(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta, written: WrittenMeta) TableError!void {
    const marker: TxCommitMarker = .{
        .magic = "sa-db-tx-commit",
        .version = 1,
        .table_name = table_name,
        .epoch = meta.epoch,
        .meta_path = written.versioned_name,
        .meta_sha256 = written.meta_hash,
        .meta_bytes = written.meta_bytes,
    };
    const json = std.json.stringifyAlloc(allocator, marker, .{}) catch |err| return mapJsonError(err);
    defer allocator.free(json);
    const path = try txCommitMarkerPath(allocator, root_dir, table_name, meta.epoch);
    defer allocator.free(path);
    try writeFile(allocator, path, json);
}

fn deleteTxPendingMarkerIfExists(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, epoch: u64) TableError!void {
    const path = try txPendingMarkerPath(allocator, root_dir, table_name, epoch);
    defer allocator.free(path);
    try deleteIfExists(path);
}

fn validateTxCommitMarkerForMeta(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta, meta_source: []const u8) TableError!void {
    const path = try txCommitMarkerPath(allocator, root_dir, table_name, meta.epoch);
    defer allocator.free(path);
    const source = try readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(source);
    var parsed = try parseTxCommitMarker(allocator, source);
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.table_name, table_name)) return TableError.VerifyFailed;
    if (!std.mem.eql(u8, parsed.value.table_name, meta.table_name)) return TableError.VerifyFailed;
    if (parsed.value.epoch != meta.epoch) return TableError.VerifyFailed;
    const versioned_name = try tableVersionedMetaName(allocator, table_name, meta.epoch);
    defer allocator.free(versioned_name);
    if (!std.mem.eql(u8, parsed.value.meta_path, versioned_name)) return TableError.VerifyFailed;
    if (parsed.value.meta_bytes != meta_source.len) return TableError.VerifyFailed;
    const meta_hash = hashBytes(meta_source);
    const meta_hex = std.fmt.bytesToHex(meta_hash, .lower);
    if (!std.mem.eql(u8, parsed.value.meta_sha256, meta_hex[0..])) return TableError.VerifyFailed;
}

pub fn commitTableMetaUnlocked(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta) TableError!void {
    try writeMeta(allocator, root_dir, table_name, meta);
}

pub fn commitTableMeta(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta) TableError!void {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();
    try commitTableMetaUnlocked(allocator, root_dir, table_name, meta);
}

pub fn commitTableMetaWithRebuiltIndexesUnlocked(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta) TableError!void {
    var owned = try duplicateTableMeta(allocator, meta);
    defer owned.deinit(allocator);
    try rebuildIndexes(allocator, root_dir, &owned);
    try writeMeta(allocator, root_dir, table_name, owned);
}

pub fn commitTableMetaWithRebuiltIndexes(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta) TableError!void {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();
    try commitTableMetaWithRebuiltIndexesUnlocked(allocator, root_dir, table_name, meta);
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

    var write_lock = try acquireTableWriteLock(allocator, root_dir, schema_obj.table_name);
    defer write_lock.release();

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
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

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
        for (owned.indexes) |index| {
            const path = try activePath(allocator, root_dir, index.path);
            defer allocator.free(path);
            try deleteIfExists(path);
        }
        for (owned.dicts) |dict| {
            const path = try activePath(allocator, root_dir, dict.path);
            defer allocator.free(path);
            try deleteIfExists(path);
        }
        for (owned.blobs) |blob| {
            const path = try activePath(allocator, root_dir, blob.path);
            defer allocator.free(path);
            try deleteIfExists(path);
        }
    } else |err| switch (err) {
        TableError.NotFound => {},
        else => return err,
    }

    try deleteRootTableArtifacts(allocator, root_dir, table_name);

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

fn ingestRawColumnsUnlocked(
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
    try rebuildIndexes(allocator, root_dir, &meta);
    try writeMeta(allocator, root_dir, table_name, meta);

    for (buffers) |*buf| buf.deinit();
    allocator.free(buffers);

    return tableInfo(meta);
}

pub fn ingestRawColumns(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    row_count: u64,
    columns: []const RawColumnBytes,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();
    return try ingestRawColumnsUnlocked(allocator, root_dir, table_name, row_count, columns);
}

pub fn insertRawRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    row_bytes: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    const columns = try splitRawRowColumns(allocator, meta, row_bytes);
    defer allocator.free(columns);

    return try ingestRawColumnsUnlocked(allocator, root_dir, table_name, 1, columns);
}

fn fixedRowBytes(meta: TableMeta) TableError!usize {
    if (meta.row_bytes > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    return @intCast(meta.row_bytes);
}

fn rowColumnOffset(meta: TableMeta, column_index: usize) TableError!usize {
    if (column_index >= meta.columns.len) return TableError.InvalidFormat;
    var offset: u64 = 0;
    for (meta.columns[0..column_index]) |column| {
        offset = std.math.add(u64, offset, column.stride) catch return TableError.CursorOverflow;
    }
    if (offset > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    return @intCast(offset);
}

fn rowU64KeyValue(meta: TableMeta, column_index: usize, row_bytes: []const u8) TableError!u64 {
    try ensureU64Column(meta, column_index);
    if (row_bytes.len != try fixedRowBytes(meta)) return TableError.InvalidFormat;
    const offset = try rowColumnOffset(meta, column_index);
    return readU64LE(row_bytes, offset);
}

fn rowU64PairKeyValue(meta: TableMeta, column_index: usize, column_index2: usize, row_bytes: []const u8) TableError!U64PairKey {
    try ensureU64PairColumns(meta, column_index, column_index2);
    if (row_bytes.len != try fixedRowBytes(meta)) return TableError.InvalidFormat;
    const offset1 = try rowColumnOffset(meta, column_index);
    const offset2 = try rowColumnOffset(meta, column_index2);
    return .{
        .key1 = readU64LE(row_bytes, offset1),
        .key2 = readU64LE(row_bytes, offset2),
    };
}

fn splitRawRowColumns(allocator: std.mem.Allocator, meta: TableMeta, row_bytes: []const u8) TableError![]RawColumnBytes {
    if (row_bytes.len != try fixedRowBytes(meta)) return TableError.InvalidFormat;
    const columns = try allocator.alloc(RawColumnBytes, meta.columns.len);
    errdefer allocator.free(columns);

    var offset: usize = 0;
    for (meta.columns, 0..) |column, idx| {
        const stride: usize = @intCast(column.stride);
        const next_offset = std.math.add(usize, offset, stride) catch return TableError.CursorOverflow;
        if (next_offset > row_bytes.len) return TableError.InvalidFormat;
        columns[idx] = .{ .bytes = row_bytes[offset..next_offset] };
        offset = next_offset;
    }
    if (offset != row_bytes.len) return TableError.InvalidFormat;
    return columns;
}

fn buildSingleRowColumnBuffers(allocator: std.mem.Allocator, meta: TableMeta, row_bytes: []const u8) TableError![]std.ArrayList(u8) {
    const columns = try splitRawRowColumns(allocator, meta, row_bytes);
    defer allocator.free(columns);

    const buffers = try allocator.alloc(std.ArrayList(u8), meta.columns.len);
    errdefer allocator.free(buffers);
    for (buffers) |*buf| buf.* = std.ArrayList(u8).init(allocator);
    errdefer {
        for (buffers) |*buf| buf.deinit();
    }

    for (columns, 0..) |column, idx| {
        try buffers[idx].appendSlice(column.bytes);
    }
    return buffers;
}

fn freeColumnBuffers(allocator: std.mem.Allocator, buffers: []std.ArrayList(u8)) void {
    for (buffers) |*buf| buf.deinit();
    allocator.free(buffers);
}

fn buildAllColumnBuffers(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta) TableError![]std.ArrayList(u8) {
    const buffers = try allocator.alloc(std.ArrayList(u8), meta.columns.len);
    errdefer allocator.free(buffers);
    for (buffers) |*buf| buf.* = std.ArrayList(u8).init(allocator);
    errdefer {
        for (buffers) |*buf| buf.deinit();
    }

    for (meta.columns, 0..) |column, col_idx| {
        var copied_rows: u64 = 0;
        for (meta.segments) |segment| {
            const file_meta = segment.files[col_idx];
            const path = try activePath(allocator, root_dir, file_meta.path);
            defer allocator.free(path);
            const bytes = try readFileAlloc(allocator, path, 1 << 30);
            defer allocator.free(bytes);
            const expected_len = try expectedColumnBytes(segment.rows, column.stride);
            if (bytes.len != expected_len or file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
            try validateFileMetaBytes(file_meta, bytes);
            try buffers[col_idx].appendSlice(bytes);
            copied_rows = std.math.add(u64, copied_rows, segment.rows) catch return TableError.CursorOverflow;
        }
        if (copied_rows != meta.row_count) return TableError.VerifyFailed;
        const expected_total = try expectedColumnBytes(meta.row_count, column.stride);
        if (buffers[col_idx].items.len != expected_total) return TableError.VerifyFailed;
    }

    return buffers;
}

fn hasUniqueU64Index(meta: TableMeta, column_index: usize) bool {
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64") and
            index.unique and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null)
        {
            return true;
        }
    }
    return false;
}

fn hasUniqueU64PairIndex(meta: TableMeta, column_index: usize, column_index2: usize) bool {
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64_pair") and
            index.unique and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 != null and
            index.column_index2.? == @as(u64, @intCast(column_index2)))
        {
            return true;
        }
    }
    return false;
}

fn validateTransactionBuffers(tx: *const WriteTransaction) TableError!void {
    if (tx.buffers.len != tx.meta.columns.len) return TableError.InvalidFormat;
    for (tx.meta.columns, 0..) |column, col_idx| {
        const expected_len = try expectedColumnBytes(tx.meta.row_count, column.stride);
        if (tx.buffers[col_idx].items.len != expected_len) return TableError.VerifyFailed;
    }
}

fn txFindU64KeyRow(tx: *const WriteTransaction, column_index: usize, expected: u64) TableError!U64FindResult {
    try ensureU64Column(tx.meta, column_index);
    if (!hasUniqueU64Index(tx.meta, column_index)) return TableError.InvalidFormat;
    try validateTransactionBuffers(tx);

    const bytes = tx.buffers[column_index].items;
    var row: u64 = 0;
    while (row < tx.meta.row_count) : (row += 1) {
        const offset_u64 = std.math.mul(u64, row, 8) catch return TableError.CursorOverflow;
        const offset: usize = @intCast(offset_u64);
        if (readU64LE(bytes, offset) == expected) return .{ .found = true, .row_index = row };
    }
    return .{ .found = false, .row_index = 0 };
}

fn txFindU64PairKeyRow(tx: *const WriteTransaction, column_index: usize, column_index2: usize, key1: u64, key2: u64) TableError!U64FindResult {
    try ensureU64PairColumns(tx.meta, column_index, column_index2);
    if (!hasUniqueU64PairIndex(tx.meta, column_index, column_index2)) return TableError.InvalidFormat;
    try validateTransactionBuffers(tx);

    const bytes1 = tx.buffers[column_index].items;
    const bytes2 = tx.buffers[column_index2].items;
    var row: u64 = 0;
    while (row < tx.meta.row_count) : (row += 1) {
        const offset_u64 = std.math.mul(u64, row, 8) catch return TableError.CursorOverflow;
        const offset: usize = @intCast(offset_u64);
        if (readU64LE(bytes1, offset) == key1 and readU64LE(bytes2, offset) == key2) return .{ .found = true, .row_index = row };
    }
    return .{ .found = false, .row_index = 0 };
}

fn txAppendRawRow(tx: *WriteTransaction, row_bytes: []const u8) TableError!void {
    if (row_bytes.len != try fixedRowBytes(tx.meta)) return TableError.InvalidFormat;
    const next_row_count = std.math.add(u64, tx.meta.row_count, 1) catch return TableError.CursorOverflow;
    if (next_row_count > tx.meta.max_rows) return TableError.CursorOverflow;

    var offset: usize = 0;
    for (tx.meta.columns, 0..) |column, col_idx| {
        const stride: usize = @intCast(column.stride);
        const next_offset = std.math.add(usize, offset, stride) catch return TableError.CursorOverflow;
        if (next_offset > row_bytes.len) return TableError.InvalidFormat;
        try tx.buffers[col_idx].appendSlice(row_bytes[offset..next_offset]);
        offset = next_offset;
    }
    if (offset != row_bytes.len) return TableError.InvalidFormat;
    tx.meta.row_count = next_row_count;
    tx.dirty = true;
    tx.rows_dirty = true;
}

fn txReplaceRawRow(tx: *WriteTransaction, row_index: u64, row_bytes: []const u8) TableError!void {
    if (row_index >= tx.meta.row_count) return TableError.InvalidFormat;
    if (row_bytes.len != try fixedRowBytes(tx.meta)) return TableError.InvalidFormat;
    try validateTransactionBuffers(tx);

    var row_offset: usize = 0;
    for (tx.meta.columns, 0..) |column, col_idx| {
        const stride: usize = @intCast(column.stride);
        const next_row_offset = std.math.add(usize, row_offset, stride) catch return TableError.CursorOverflow;
        if (next_row_offset > row_bytes.len) return TableError.InvalidFormat;
        const dest_offset_u64 = std.math.mul(u64, row_index, column.stride) catch return TableError.CursorOverflow;
        if (dest_offset_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
        const dest_offset: usize = @intCast(dest_offset_u64);
        @memcpy(tx.buffers[col_idx].items[dest_offset .. dest_offset + stride], row_bytes[row_offset..next_row_offset]);
        row_offset = next_row_offset;
    }
    if (row_offset != row_bytes.len) return TableError.InvalidFormat;
    tx.dirty = true;
    tx.rows_dirty = true;
}

fn removeBufferRange(buf: *std.ArrayList(u8), start: usize, len: usize) void {
    const end = start + len;
    const tail_len = buf.items.len - end;
    std.mem.copyForwards(u8, buf.items[start .. start + tail_len], buf.items[end..]);
    buf.shrinkRetainingCapacity(buf.items.len - len);
}

fn txDeleteRow(tx: *WriteTransaction, row_index: u64) TableError!void {
    if (row_index >= tx.meta.row_count) return TableError.InvalidFormat;
    try validateTransactionBuffers(tx);

    for (tx.meta.columns, 0..) |column, col_idx| {
        const stride: usize = @intCast(column.stride);
        const offset_u64 = std.math.mul(u64, row_index, column.stride) catch return TableError.CursorOverflow;
        if (offset_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
        removeBufferRange(&tx.buffers[col_idx], @intCast(offset_u64), stride);
    }
    tx.meta.row_count -= 1;
    tx.dirty = true;
    tx.rows_dirty = true;
}

fn rewriteSegmentsFromTransaction(allocator: std.mem.Allocator, tx: *WriteTransaction) TableError!void {
    try validateTransactionBuffers(tx);

    const next_row_count = tx.meta.row_count;
    const new_segments = try allocator.alloc(SegmentMeta, if (next_row_count > 0) 1 else 0);
    var new_files: ?[]FileMeta = null;
    var assigned_segments = false;
    errdefer if (!assigned_segments) {
        if (new_files) |files| freeFileMetas(allocator, files);
        allocator.free(new_segments);
    };

    if (next_row_count > 0) {
        const files = try writeSegmentFiles(allocator, tx.root_dir, tx.table_name, tx.meta.next_segment_id, tx.buffers);
        new_files = files;
        new_segments[0] = .{
            .id = tx.meta.next_segment_id,
            .rows = next_row_count,
            .files = files,
        };
        new_files = null;
        tx.meta.next_segment_id += 1;
    }

    const old_segments = tx.meta.segments;
    tx.meta.segments = new_segments;
    assigned_segments = true;
    freeSegmentMetas(allocator, old_segments);
    tx.meta.epoch += 1;
}

pub fn beginWriteTransaction(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
) TableError!*WriteTransaction {
    const root_copy = try allocator.dupe(u8, root_dir);
    errdefer allocator.free(root_copy);
    const table_copy = try allocator.dupe(u8, table_name);
    errdefer allocator.free(table_copy);

    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    var write_lock_transferred = false;
    errdefer if (!write_lock_transferred) write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    var meta_transferred = false;
    errdefer if (!meta_transferred) meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;

    const buffers = try buildAllColumnBuffers(allocator, root_dir, meta);
    var buffers_transferred = false;
    errdefer if (!buffers_transferred) freeColumnBuffers(allocator, buffers);

    const tx = try allocator.create(WriteTransaction);
    errdefer allocator.destroy(tx);
    tx.* = .{
        .root_dir = root_copy,
        .table_name = table_copy,
        .write_lock = write_lock,
        .meta = meta,
        .buffers = buffers,
        .dirty = false,
    };
    write_lock_transferred = true;
    meta_transferred = true;
    buffers_transferred = true;
    return tx;
}

pub fn destroyWriteTransaction(allocator: std.mem.Allocator, tx: *WriteTransaction) void {
    tx.deinit(allocator);
    allocator.destroy(tx);
}

pub fn writeTransactionInfo(tx: *const WriteTransaction) TableInfo {
    return tableInfo(tx.meta);
}

pub fn writeTransactionInsertRawRow(tx: *WriteTransaction, row_bytes: []const u8) TableError!TableInfo {
    try txAppendRawRow(tx, row_bytes);
    return tableInfo(tx.meta);
}

pub fn writeTransactionUpsertRawRowU64Key(tx: *WriteTransaction, column_index: usize, expected: u64, row_bytes: []const u8) TableError!UpsertResult {
    const key_value = try rowU64KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindU64KeyRow(tx, column_index, expected);
    if (found.found) {
        try txReplaceRawRow(tx, found.row_index, row_bytes);
        return .{ .info = tableInfo(tx.meta), .inserted = false };
    }
    try txAppendRawRow(tx, row_bytes);
    return .{ .info = tableInfo(tx.meta), .inserted = true };
}

pub fn writeTransactionUpsertRawRowU64PairKey(tx: *WriteTransaction, column_index: usize, column_index2: usize, key1: u64, key2: u64, row_bytes: []const u8) TableError!UpsertResult {
    const key_value = try rowU64PairKeyValue(tx.meta, column_index, column_index2, row_bytes);
    if (key_value.key1 != key1 or key_value.key2 != key2) return TableError.InvalidFormat;
    const found = try txFindU64PairKeyRow(tx, column_index, column_index2, key1, key2);
    if (found.found) {
        try txReplaceRawRow(tx, found.row_index, row_bytes);
        return .{ .info = tableInfo(tx.meta), .inserted = false };
    }
    try txAppendRawRow(tx, row_bytes);
    return .{ .info = tableInfo(tx.meta), .inserted = true };
}

pub fn writeTransactionUpdateRawRowU64Key(tx: *WriteTransaction, column_index: usize, expected: u64, row_bytes: []const u8) TableError!TableInfo {
    const key_value = try rowU64KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindU64KeyRow(tx, column_index, expected);
    if (!found.found) return TableError.NotFound;
    try txReplaceRawRow(tx, found.row_index, row_bytes);
    return tableInfo(tx.meta);
}

pub fn writeTransactionUpdateRawRowU64PairKey(tx: *WriteTransaction, column_index: usize, column_index2: usize, key1: u64, key2: u64, row_bytes: []const u8) TableError!TableInfo {
    const key_value = try rowU64PairKeyValue(tx.meta, column_index, column_index2, row_bytes);
    if (key_value.key1 != key1 or key_value.key2 != key2) return TableError.InvalidFormat;
    const found = try txFindU64PairKeyRow(tx, column_index, column_index2, key1, key2);
    if (!found.found) return TableError.NotFound;
    try txReplaceRawRow(tx, found.row_index, row_bytes);
    return tableInfo(tx.meta);
}

pub fn writeTransactionDeleteU64Key(tx: *WriteTransaction, column_index: usize, expected: u64) TableError!TableInfo {
    const found = try txFindU64KeyRow(tx, column_index, expected);
    if (!found.found) return TableError.NotFound;
    try txDeleteRow(tx, found.row_index);
    return tableInfo(tx.meta);
}

pub fn writeTransactionDeleteU64PairKey(tx: *WriteTransaction, column_index: usize, column_index2: usize, key1: u64, key2: u64) TableError!TableInfo {
    const found = try txFindU64PairKeyRow(tx, column_index, column_index2, key1, key2);
    if (!found.found) return TableError.NotFound;
    try txDeleteRow(tx, found.row_index);
    return tableInfo(tx.meta);
}

pub fn writeTransactionInternStringDict(
    allocator: std.mem.Allocator,
    tx: *WriteTransaction,
    dict_name: []const u8,
    value: []const u8,
) TableError!DictInternResult {
    try validateDictName(dict_name);
    try validateDictValue(value);

    var old_bytes: []u8 = &.{};
    var old_count: u64 = 0;
    var has_old = false;
    if (findDictMetaIndex(tx.meta, dict_name)) |idx| {
        old_bytes = try readDictBytes(allocator, tx.root_dir, tx.meta.dicts[idx]);
        has_old = true;
        old_count = try dictEntryCount(old_bytes);
        if (try dictFindValueId(old_bytes, value)) |id| {
            allocator.free(old_bytes);
            return .{ .info = tableInfo(tx.meta), .id = id, .inserted = false };
        }
    }
    defer if (has_old) allocator.free(old_bytes);

    const new_count = std.math.add(u64, old_count, 1) catch return TableError.CursorOverflow;
    const new_bytes = try buildDictBytesWithValue(allocator, old_bytes, old_count, value);
    defer allocator.free(new_bytes);

    const target_epoch = std.math.add(u64, tx.meta.epoch, 1) catch return TableError.CursorOverflow;
    const basename = try dictFileName(allocator, tx.table_name, dict_name, target_epoch);
    defer allocator.free(basename);
    const path = try activePath(allocator, tx.root_dir, basename);
    defer allocator.free(path);
    try writeFile(allocator, path, new_bytes);

    const new_meta = try makeDictMeta(allocator, dict_name, basename, new_bytes, new_count);
    var consumed = false;
    errdefer if (!consumed) freeDictMeta(allocator, new_meta);
    try putDictMeta(allocator, &tx.meta, new_meta);
    consumed = true;
    tx.dirty = true;
    return .{ .info = tableInfo(tx.meta), .id = new_count, .inserted = true };
}

pub fn writeTransactionPutBlobValue(
    allocator: std.mem.Allocator,
    tx: *WriteTransaction,
    store_name: []const u8,
    value: []const u8,
) TableError!BlobPutResult {
    try validateBlobStoreName(store_name);
    try validateBlobValue(value);

    var old_bytes: []u8 = &.{};
    var old_count: u64 = 0;
    var has_old = false;
    if (findBlobStoreMetaIndex(tx.meta, store_name)) |idx| {
        old_bytes = try readBlobStoreBytes(allocator, tx.root_dir, tx.meta.blobs[idx]);
        has_old = true;
        old_count = try blobEntryCount(old_bytes);
    }
    defer if (has_old) allocator.free(old_bytes);

    const new_count = std.math.add(u64, old_count, 1) catch return TableError.CursorOverflow;
    const new_bytes = try buildBlobBytesWithValue(allocator, old_bytes, old_count, value);
    defer allocator.free(new_bytes);

    const target_epoch = std.math.add(u64, tx.meta.epoch, 1) catch return TableError.CursorOverflow;
    const basename = try blobStoreFileName(allocator, tx.table_name, store_name, target_epoch);
    defer allocator.free(basename);
    const path = try activePath(allocator, tx.root_dir, basename);
    defer allocator.free(path);
    try writeFile(allocator, path, new_bytes);

    const new_meta = try makeBlobStoreMeta(allocator, store_name, basename, new_bytes, new_count);
    var consumed = false;
    errdefer if (!consumed) freeBlobStoreMeta(allocator, new_meta);
    try putBlobStoreMeta(allocator, &tx.meta, new_meta);
    consumed = true;
    tx.dirty = true;
    return .{ .info = tableInfo(tx.meta), .id = new_count };
}

pub fn commitWriteTransaction(allocator: std.mem.Allocator, tx: *WriteTransaction) TableError!TableInfo {
    if (!tx.dirty) return tableInfo(tx.meta);
    const previous_epoch = tx.meta.epoch;
    const target_epoch = std.math.add(u64, previous_epoch, 1) catch return TableError.CursorOverflow;
    try writeTxPendingMarker(allocator, tx.root_dir, tx.table_name, previous_epoch, target_epoch);
    var pending_marker_live = true;
    errdefer if (pending_marker_live) deleteTxPendingMarkerIfExists(allocator, tx.root_dir, tx.table_name, target_epoch) catch {};

    if (tx.rows_dirty) {
        try rewriteSegmentsFromTransaction(allocator, tx);
    } else {
        tx.meta.epoch = target_epoch;
    }
    try rebuildIndexes(allocator, tx.root_dir, &tx.meta);
    var written = try writeVersionedMeta(allocator, tx.root_dir, tx.table_name, tx.meta);
    defer written.deinit(allocator);
    try writeTxCommitMarker(allocator, tx.root_dir, tx.table_name, tx.meta, written);
    try publishWrittenMeta(allocator, tx.root_dir, tx.table_name, tx.meta, written);
    deleteTxPendingMarkerIfExists(allocator, tx.root_dir, tx.table_name, tx.meta.epoch) catch {};
    pending_marker_live = false;
    tx.dirty = false;
    tx.rows_dirty = false;
    return tableInfo(tx.meta);
}

fn buildDictBytesWithValue(allocator: std.mem.Allocator, old_bytes: []const u8, old_count: u64, value: []const u8) TableError![]u8 {
    const new_count = std.math.add(u64, old_count, 1) catch return TableError.CursorOverflow;
    const extra = std.math.add(usize, 8, value.len) catch return TableError.CursorOverflow;
    const total = std.math.add(usize, old_bytes.len, if (old_bytes.len == 0) 8 + extra else extra) catch return TableError.CursorOverflow;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    const entry_offset: usize = if (old_bytes.len == 0) blk: {
        writeU64LE(out, 0, new_count);
        break :blk 8;
    } else blk: {
        @memcpy(out[0..old_bytes.len], old_bytes);
        writeU64LE(out, 0, new_count);
        break :blk old_bytes.len;
    };
    writeU64LE(out, entry_offset, @intCast(value.len));
    @memcpy(out[entry_offset + 8 .. entry_offset + 8 + value.len], value);
    return out;
}

fn makeDictMeta(allocator: std.mem.Allocator, dict_name: []const u8, path: []const u8, bytes: []const u8, entries: u64) TableError!DictMeta {
    const name = try allocator.dupe(u8, dict_name);
    errdefer allocator.free(name);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const sha256 = try hashHexAlloc(allocator, bytes);
    errdefer allocator.free(sha256);
    const block_sha256 = try makeBlockSha256List(allocator, bytes, FILE_BLOCK_BYTES);
    errdefer freeBlockSha256List(allocator, block_sha256);
    return .{
        .name = name,
        .path = owned_path,
        .sha256 = sha256,
        .bytes = bytes.len,
        .entries = entries,
        .block_size = artifactBlockSize(bytes),
        .block_sha256 = block_sha256,
    };
}

fn buildBlobBytesWithValue(allocator: std.mem.Allocator, old_bytes: []const u8, old_count: u64, value: []const u8) TableError![]u8 {
    const new_count = std.math.add(u64, old_count, 1) catch return TableError.CursorOverflow;
    const extra = std.math.add(usize, 8, value.len) catch return TableError.CursorOverflow;
    const total = std.math.add(usize, old_bytes.len, if (old_bytes.len == 0) 8 + extra else extra) catch return TableError.CursorOverflow;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    const entry_offset: usize = if (old_bytes.len == 0) blk: {
        writeU64LE(out, 0, new_count);
        break :blk 8;
    } else blk: {
        @memcpy(out[0..old_bytes.len], old_bytes);
        writeU64LE(out, 0, new_count);
        break :blk old_bytes.len;
    };
    writeU64LE(out, entry_offset, @intCast(value.len));
    if (value.len != 0) @memcpy(out[entry_offset + 8 .. entry_offset + 8 + value.len], value);
    return out;
}

fn makeBlobStoreMeta(allocator: std.mem.Allocator, store_name: []const u8, path: []const u8, bytes: []const u8, entries: u64) TableError!BlobStoreMeta {
    const name = try allocator.dupe(u8, store_name);
    errdefer allocator.free(name);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const sha256 = try hashHexAlloc(allocator, bytes);
    errdefer allocator.free(sha256);
    const block_sha256 = try makeBlockSha256List(allocator, bytes, FILE_BLOCK_BYTES);
    errdefer freeBlockSha256List(allocator, block_sha256);
    return .{
        .name = name,
        .path = owned_path,
        .sha256 = sha256,
        .bytes = bytes.len,
        .entries = entries,
        .block_size = artifactBlockSize(bytes),
        .block_sha256 = block_sha256,
    };
}

fn putDictMeta(allocator: std.mem.Allocator, meta: *TableMeta, dict: DictMeta) TableError!void {
    if (findDictMetaIndex(meta.*, dict.name)) |idx| {
        freeDictMeta(allocator, meta.dicts[idx]);
        meta.dicts[idx] = dict;
        return;
    }

    const old_dicts = meta.dicts;
    const new_dicts = try allocator.alloc(DictMeta, old_dicts.len + 1);
    @memcpy(new_dicts[0..old_dicts.len], old_dicts);
    new_dicts[old_dicts.len] = dict;
    allocator.free(old_dicts);
    meta.dicts = new_dicts;
}

fn putBlobStoreMeta(allocator: std.mem.Allocator, meta: *TableMeta, blob: BlobStoreMeta) TableError!void {
    if (findBlobStoreMetaIndex(meta.*, blob.name)) |idx| {
        freeBlobStoreMeta(allocator, meta.blobs[idx]);
        meta.blobs[idx] = blob;
        return;
    }

    const old_blobs = meta.blobs;
    const new_blobs = try allocator.alloc(BlobStoreMeta, old_blobs.len + 1);
    @memcpy(new_blobs[0..old_blobs.len], old_blobs);
    new_blobs[old_blobs.len] = blob;
    allocator.free(old_blobs);
    meta.blobs = new_blobs;
}

pub fn internStringDict(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    dict_name: []const u8,
    value: []const u8,
) TableError!DictInternResult {
    try validateDictName(dict_name);
    try validateDictValue(value);

    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;

    var old_bytes: []u8 = &.{};
    var old_count: u64 = 0;
    var has_old = false;
    if (findDictMetaIndex(meta, dict_name)) |idx| {
        old_bytes = try readDictBytes(allocator, root_dir, meta.dicts[idx]);
        has_old = true;
        old_count = try dictEntryCount(old_bytes);
        if (try dictFindValueId(old_bytes, value)) |id| {
            allocator.free(old_bytes);
            return .{ .info = tableInfo(meta), .id = id, .inserted = false };
        }
    }
    defer if (has_old) allocator.free(old_bytes);

    const new_count = std.math.add(u64, old_count, 1) catch return TableError.CursorOverflow;
    const new_bytes = try buildDictBytesWithValue(allocator, old_bytes, old_count, value);
    defer allocator.free(new_bytes);

    const next_epoch = std.math.add(u64, meta.epoch, 1) catch return TableError.CursorOverflow;
    const basename = try dictFileName(allocator, table_name, dict_name, next_epoch);
    defer allocator.free(basename);
    const path = try activePath(allocator, root_dir, basename);
    defer allocator.free(path);
    try writeFile(allocator, path, new_bytes);

    const new_meta = try makeDictMeta(allocator, dict_name, basename, new_bytes, new_count);
    var consumed = false;
    errdefer if (!consumed) freeDictMeta(allocator, new_meta);
    try putDictMeta(allocator, &meta, new_meta);
    consumed = true;
    meta.epoch = next_epoch;
    try writeMeta(allocator, root_dir, table_name, meta);
    return .{ .info = tableInfo(meta), .id = new_count, .inserted = true };
}

pub fn lookupStringDict(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    dict_name: []const u8,
    value: []const u8,
) TableError!DictLookupResult {
    try validateDictName(dict_name);
    try validateDictValue(value);

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    const idx = findDictMetaIndex(meta, dict_name) orelse return .{ .found = false, .id = 0 };
    const bytes = try readDictBytes(allocator, root_dir, meta.dicts[idx]);
    defer allocator.free(bytes);
    if (try dictFindValueId(bytes, value)) |id| return .{ .found = true, .id = id };
    return .{ .found = false, .id = 0 };
}

pub fn stringDictValueLen(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    dict_name: []const u8,
    id: u64,
) TableError!DictValueLenResult {
    try validateDictName(dict_name);
    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    const idx = findDictMetaIndex(meta, dict_name) orelse return .{ .found = false, .len = 0 };
    const bytes = try readDictBytes(allocator, root_dir, meta.dicts[idx]);
    defer allocator.free(bytes);
    const value = (try dictValueSliceById(bytes, id)) orelse return .{ .found = false, .len = 0 };
    return .{ .found = true, .len = value.len };
}

pub fn copyStringDictValue(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    dict_name: []const u8,
    id: u64,
    out: []u8,
) TableError!DictValueCopyResult {
    try validateDictName(dict_name);
    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    const idx = findDictMetaIndex(meta, dict_name) orelse return .{ .found = false, .written = 0 };
    const bytes = try readDictBytes(allocator, root_dir, meta.dicts[idx]);
    defer allocator.free(bytes);
    const value = (try dictValueSliceById(bytes, id)) orelse return .{ .found = false, .written = 0 };
    if (out.len < value.len) return TableError.CursorOverflow;
    @memcpy(out[0..value.len], value);
    return .{ .found = true, .written = value.len };
}

pub fn putBlobValue(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    store_name: []const u8,
    value: []const u8,
) TableError!BlobPutResult {
    try validateBlobStoreName(store_name);
    try validateBlobValue(value);

    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;

    var old_bytes: []u8 = &.{};
    var old_count: u64 = 0;
    var has_old = false;
    if (findBlobStoreMetaIndex(meta, store_name)) |idx| {
        old_bytes = try readBlobStoreBytes(allocator, root_dir, meta.blobs[idx]);
        has_old = true;
        old_count = try blobEntryCount(old_bytes);
    }
    defer if (has_old) allocator.free(old_bytes);

    const new_count = std.math.add(u64, old_count, 1) catch return TableError.CursorOverflow;
    const new_bytes = try buildBlobBytesWithValue(allocator, old_bytes, old_count, value);
    defer allocator.free(new_bytes);

    const next_epoch = std.math.add(u64, meta.epoch, 1) catch return TableError.CursorOverflow;
    const basename = try blobStoreFileName(allocator, table_name, store_name, next_epoch);
    defer allocator.free(basename);
    const path = try activePath(allocator, root_dir, basename);
    defer allocator.free(path);
    try writeFile(allocator, path, new_bytes);

    const new_meta = try makeBlobStoreMeta(allocator, store_name, basename, new_bytes, new_count);
    var consumed = false;
    errdefer if (!consumed) freeBlobStoreMeta(allocator, new_meta);
    try putBlobStoreMeta(allocator, &meta, new_meta);
    consumed = true;
    meta.epoch = next_epoch;
    try rebuildBlobIndexesForStore(allocator, root_dir, &meta, store_name);
    try writeMeta(allocator, root_dir, table_name, meta);
    return .{ .info = tableInfo(meta), .id = new_count };
}

pub fn blobValueLen(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    store_name: []const u8,
    id: u64,
) TableError!BlobValueLenResult {
    try validateBlobStoreName(store_name);
    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    const idx = findBlobStoreMetaIndex(meta, store_name) orelse return .{ .found = false, .len = 0 };
    const bytes = try readBlobStoreBytes(allocator, root_dir, meta.blobs[idx]);
    defer allocator.free(bytes);
    const value = (try blobValueSliceById(bytes, id)) orelse return .{ .found = false, .len = 0 };
    return .{ .found = true, .len = value.len };
}

pub fn copyBlobValue(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    store_name: []const u8,
    id: u64,
    out: []u8,
) TableError!BlobValueCopyResult {
    try validateBlobStoreName(store_name);
    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    const idx = findBlobStoreMetaIndex(meta, store_name) orelse return .{ .found = false, .written = 0 };
    const bytes = try readBlobStoreBytes(allocator, root_dir, meta.blobs[idx]);
    defer allocator.free(bytes);
    const value = (try blobValueSliceById(bytes, id)) orelse return .{ .found = false, .written = 0 };
    if (out.len < value.len) return TableError.CursorOverflow;
    if (value.len != 0) @memcpy(out[0..value.len], value);
    return .{ .found = true, .written = value.len };
}

pub fn createU64Index(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    unique: bool,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;
    try ensureU64Column(meta, column_index);

    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64") and index.column_index == @as(u64, @intCast(column_index))) {
            if (index.unique == unique) return tableInfo(meta);
            return TableError.InvalidFormat;
        }
    }

    const old_indexes = meta.indexes;
    const new_indexes = try allocator.alloc(IndexMeta, old_indexes.len + 1);
    initIndexMetas(new_indexes);
    var assigned_indexes = false;
    errdefer if (!assigned_indexes) freeIndexMetas(allocator, new_indexes);

    for (old_indexes, 0..) |index, idx| {
        new_indexes[idx] = try duplicateIndexMeta(allocator, index);
    }

    const new_index = &new_indexes[old_indexes.len];
    new_index.* = .{
        .name = try allocPrintPath(allocator, "u64_col{d}", .{column_index}),
        .kind = try allocator.dupe(u8, "u64"),
        .column_index = @intCast(column_index),
        .column_index2 = null,
        .unique = unique,
        .path = try allocator.dupe(u8, ""),
        .sha256 = try allocator.dupe(u8, ""),
        .bytes = 0,
    };

    freeIndexMetas(allocator, old_indexes);
    meta.indexes = new_indexes;
    assigned_indexes = true;
    meta.epoch += 1;
    try rebuildIndexAt(allocator, root_dir, &meta, meta.indexes.len - 1);
    try writeMeta(allocator, root_dir, table_name, meta);
    return tableInfo(meta);
}

pub fn createI64Index(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    unique: bool,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;
    try ensureI64Column(meta, column_index);

    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i64") and index.column_index == @as(u64, @intCast(column_index))) {
            if (index.unique == unique) return tableInfo(meta);
            return TableError.InvalidFormat;
        }
    }

    const old_indexes = meta.indexes;
    const new_indexes = try allocator.alloc(IndexMeta, old_indexes.len + 1);
    initIndexMetas(new_indexes);
    var assigned_indexes = false;
    errdefer if (!assigned_indexes) freeIndexMetas(allocator, new_indexes);

    for (old_indexes, 0..) |index, idx| {
        new_indexes[idx] = try duplicateIndexMeta(allocator, index);
    }

    const new_index = &new_indexes[old_indexes.len];
    new_index.* = .{
        .name = try allocPrintPath(allocator, "i64_col{d}", .{column_index}),
        .kind = try allocator.dupe(u8, "i64"),
        .column_index = @intCast(column_index),
        .column_index2 = null,
        .unique = unique,
        .path = try allocator.dupe(u8, ""),
        .sha256 = try allocator.dupe(u8, ""),
        .bytes = 0,
    };

    freeIndexMetas(allocator, old_indexes);
    meta.indexes = new_indexes;
    assigned_indexes = true;
    meta.epoch += 1;
    try rebuildIndexAt(allocator, root_dir, &meta, meta.indexes.len - 1);
    try writeMeta(allocator, root_dir, table_name, meta);
    return tableInfo(meta);
}

pub fn createU32Index(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    unique: bool,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;
    try ensureU32Column(meta, column_index);

    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u32") and index.column_index == @as(u64, @intCast(column_index))) {
            if (index.unique == unique) return tableInfo(meta);
            return TableError.InvalidFormat;
        }
    }

    const old_indexes = meta.indexes;
    const new_indexes = try allocator.alloc(IndexMeta, old_indexes.len + 1);
    initIndexMetas(new_indexes);
    var assigned_indexes = false;
    errdefer if (!assigned_indexes) freeIndexMetas(allocator, new_indexes);

    for (old_indexes, 0..) |index, idx| {
        new_indexes[idx] = try duplicateIndexMeta(allocator, index);
    }

    const new_index = &new_indexes[old_indexes.len];
    new_index.* = .{
        .name = try allocPrintPath(allocator, "u32_col{d}", .{column_index}),
        .kind = try allocator.dupe(u8, "u32"),
        .column_index = @intCast(column_index),
        .column_index2 = null,
        .unique = unique,
        .path = try allocator.dupe(u8, ""),
        .sha256 = try allocator.dupe(u8, ""),
        .bytes = 0,
    };

    freeIndexMetas(allocator, old_indexes);
    meta.indexes = new_indexes;
    assigned_indexes = true;
    meta.epoch += 1;
    try rebuildIndexAt(allocator, root_dir, &meta, meta.indexes.len - 1);
    try writeMeta(allocator, root_dir, table_name, meta);
    return tableInfo(meta);
}

pub fn createI32Index(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    unique: bool,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;
    try ensureI32Column(meta, column_index);

    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i32") and index.column_index == @as(u64, @intCast(column_index))) {
            if (index.unique == unique) return tableInfo(meta);
            return TableError.InvalidFormat;
        }
    }

    const old_indexes = meta.indexes;
    const new_indexes = try allocator.alloc(IndexMeta, old_indexes.len + 1);
    initIndexMetas(new_indexes);
    var assigned_indexes = false;
    errdefer if (!assigned_indexes) freeIndexMetas(allocator, new_indexes);

    for (old_indexes, 0..) |index, idx| {
        new_indexes[idx] = try duplicateIndexMeta(allocator, index);
    }

    const new_index = &new_indexes[old_indexes.len];
    new_index.* = .{
        .name = try allocPrintPath(allocator, "i32_col{d}", .{column_index}),
        .kind = try allocator.dupe(u8, "i32"),
        .column_index = @intCast(column_index),
        .column_index2 = null,
        .unique = unique,
        .path = try allocator.dupe(u8, ""),
        .sha256 = try allocator.dupe(u8, ""),
        .bytes = 0,
    };

    freeIndexMetas(allocator, old_indexes);
    meta.indexes = new_indexes;
    assigned_indexes = true;
    meta.epoch += 1;
    try rebuildIndexAt(allocator, root_dir, &meta, meta.indexes.len - 1);
    try writeMeta(allocator, root_dir, table_name, meta);
    return tableInfo(meta);
}

fn createSmallIntegerIndex(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    unique: bool,
    kind: SingleIndexKind,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;
    try ensureSingleIndexColumn(meta, column_index, kind);

    const kind_name = singleIndexKindName(kind);
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, kind_name) and index.column_index == @as(u64, @intCast(column_index))) {
            if (index.unique == unique) return tableInfo(meta);
            return TableError.InvalidFormat;
        }
    }

    const old_indexes = meta.indexes;
    const new_indexes = try allocator.alloc(IndexMeta, old_indexes.len + 1);
    initIndexMetas(new_indexes);
    var assigned_indexes = false;
    errdefer if (!assigned_indexes) freeIndexMetas(allocator, new_indexes);

    for (old_indexes, 0..) |index, idx| {
        new_indexes[idx] = try duplicateIndexMeta(allocator, index);
    }

    const new_index = &new_indexes[old_indexes.len];
    new_index.* = .{
        .name = try allocPrintPath(allocator, "{s}_col{d}", .{ kind_name, column_index }),
        .kind = try allocator.dupe(u8, kind_name),
        .column_index = @intCast(column_index),
        .column_index2 = null,
        .unique = unique,
        .path = try allocator.dupe(u8, ""),
        .sha256 = try allocator.dupe(u8, ""),
        .bytes = 0,
    };

    freeIndexMetas(allocator, old_indexes);
    meta.indexes = new_indexes;
    assigned_indexes = true;
    meta.epoch += 1;
    try rebuildIndexAt(allocator, root_dir, &meta, meta.indexes.len - 1);
    try writeMeta(allocator, root_dir, table_name, meta);
    return tableInfo(meta);
}

pub fn createU8Index(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    unique: bool,
) TableError!TableInfo {
    return createSmallIntegerIndex(allocator, root_dir, table_name, column_index, unique, .u8);
}

pub fn createI8Index(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    unique: bool,
) TableError!TableInfo {
    return createSmallIntegerIndex(allocator, root_dir, table_name, column_index, unique, .i8);
}

pub fn createU16Index(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    unique: bool,
) TableError!TableInfo {
    return createSmallIntegerIndex(allocator, root_dir, table_name, column_index, unique, .u16);
}

pub fn createI16Index(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    unique: bool,
) TableError!TableInfo {
    return createSmallIntegerIndex(allocator, root_dir, table_name, column_index, unique, .i16);
}

pub fn createF32Index(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    unique: bool,
) TableError!TableInfo {
    return createSmallIntegerIndex(allocator, root_dir, table_name, column_index, unique, .f32);
}

pub fn createF64Index(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    unique: bool,
) TableError!TableInfo {
    return createSmallIntegerIndex(allocator, root_dir, table_name, column_index, unique, .f64);
}

pub fn createU64PairIndex(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    column_index2: usize,
    unique: bool,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;
    try ensureU64PairColumns(meta, column_index, column_index2);

    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64_pair") and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 != null and
            index.column_index2.? == @as(u64, @intCast(column_index2)))
        {
            if (index.unique == unique) return tableInfo(meta);
            return TableError.InvalidFormat;
        }
    }

    const old_indexes = meta.indexes;
    const new_indexes = try allocator.alloc(IndexMeta, old_indexes.len + 1);
    initIndexMetas(new_indexes);
    var assigned_indexes = false;
    errdefer if (!assigned_indexes) freeIndexMetas(allocator, new_indexes);

    for (old_indexes, 0..) |index, idx| {
        new_indexes[idx] = try duplicateIndexMeta(allocator, index);
    }

    const new_index = &new_indexes[old_indexes.len];
    new_index.* = .{
        .name = try allocPrintPath(allocator, "u64_pair_col{d}_col{d}", .{ column_index, column_index2 }),
        .kind = try allocator.dupe(u8, "u64_pair"),
        .column_index = @intCast(column_index),
        .column_index2 = @intCast(column_index2),
        .unique = unique,
        .path = try allocator.dupe(u8, ""),
        .sha256 = try allocator.dupe(u8, ""),
        .bytes = 0,
    };

    freeIndexMetas(allocator, old_indexes);
    meta.indexes = new_indexes;
    assigned_indexes = true;
    meta.epoch += 1;
    try rebuildIndexAt(allocator, root_dir, &meta, meta.indexes.len - 1);
    try writeMeta(allocator, root_dir, table_name, meta);
    return tableInfo(meta);
}

pub fn createU64I64PairIndex(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    column_index2: usize,
    unique: bool,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;
    try ensureU64I64PairColumns(meta, column_index, column_index2);

    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64_i64_pair") and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 != null and
            index.column_index2.? == @as(u64, @intCast(column_index2)))
        {
            if (index.unique == unique) return tableInfo(meta);
            return TableError.InvalidFormat;
        }
    }

    const old_indexes = meta.indexes;
    const new_indexes = try allocator.alloc(IndexMeta, old_indexes.len + 1);
    initIndexMetas(new_indexes);
    var assigned_indexes = false;
    errdefer if (!assigned_indexes) freeIndexMetas(allocator, new_indexes);

    for (old_indexes, 0..) |index, idx| {
        new_indexes[idx] = try duplicateIndexMeta(allocator, index);
    }

    const new_index = &new_indexes[old_indexes.len];
    new_index.* = .{
        .name = try allocPrintPath(allocator, "u64_i64_pair_col{d}_col{d}", .{ column_index, column_index2 }),
        .kind = try allocator.dupe(u8, "u64_i64_pair"),
        .column_index = @intCast(column_index),
        .column_index2 = @intCast(column_index2),
        .unique = unique,
        .path = try allocator.dupe(u8, ""),
        .sha256 = try allocator.dupe(u8, ""),
        .bytes = 0,
    };

    freeIndexMetas(allocator, old_indexes);
    meta.indexes = new_indexes;
    assigned_indexes = true;
    meta.epoch += 1;
    try rebuildIndexAt(allocator, root_dir, &meta, meta.indexes.len - 1);
    try writeMeta(allocator, root_dir, table_name, meta);
    return tableInfo(meta);
}

pub fn createBlobEqIndex(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    store_name: []const u8,
    unique: bool,
) TableError!TableInfo {
    try validateBlobStoreName(store_name);

    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;
    try ensureBlobHandleColumn(meta, column_index);

    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND) and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null and
            index.store_name != null and
            std.mem.eql(u8, index.store_name.?, store_name))
        {
            if (index.unique == unique) return tableInfo(meta);
            return TableError.InvalidFormat;
        }
    }

    const old_indexes = meta.indexes;
    const new_indexes = try allocator.alloc(IndexMeta, old_indexes.len + 1);
    initIndexMetas(new_indexes);
    var assigned_indexes = false;
    errdefer if (!assigned_indexes) freeIndexMetas(allocator, new_indexes);

    for (old_indexes, 0..) |index, idx| {
        new_indexes[idx] = try duplicateIndexMeta(allocator, index);
    }

    const new_index = &new_indexes[old_indexes.len];
    new_index.* = .{
        .name = try allocPrintPath(allocator, "blob_eq_col{d}_{s}", .{ column_index, store_name }),
        .kind = try allocator.dupe(u8, BLOB_EQ_INDEX_KIND),
        .column_index = @intCast(column_index),
        .column_index2 = null,
        .store_name = try allocator.dupe(u8, store_name),
        .unique = unique,
        .path = try allocator.dupe(u8, ""),
        .sha256 = try allocator.dupe(u8, ""),
        .bytes = 0,
    };

    freeIndexMetas(allocator, old_indexes);
    meta.indexes = new_indexes;
    assigned_indexes = true;
    meta.epoch += 1;
    try rebuildIndexAt(allocator, root_dir, &meta, meta.indexes.len - 1);
    try writeMeta(allocator, root_dir, table_name, meta);
    return tableInfo(meta);
}

pub fn createBlobTokenIndex(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    store_name: []const u8,
) TableError!TableInfo {
    try validateBlobStoreName(store_name);

    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;
    try ensureBlobHandleColumn(meta, column_index);

    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND) and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null and
            index.store_name != null and
            std.mem.eql(u8, index.store_name.?, store_name))
        {
            return tableInfo(meta);
        }
    }

    const old_indexes = meta.indexes;
    const new_indexes = try allocator.alloc(IndexMeta, old_indexes.len + 1);
    initIndexMetas(new_indexes);
    var assigned_indexes = false;
    errdefer if (!assigned_indexes) freeIndexMetas(allocator, new_indexes);

    for (old_indexes, 0..) |index, idx| {
        new_indexes[idx] = try duplicateIndexMeta(allocator, index);
    }

    const new_index = &new_indexes[old_indexes.len];
    new_index.* = .{
        .name = try allocPrintPath(allocator, "blob_token_col{d}_{s}", .{ column_index, store_name }),
        .kind = try allocator.dupe(u8, BLOB_TOKEN_INDEX_KIND),
        .column_index = @intCast(column_index),
        .column_index2 = null,
        .store_name = try allocator.dupe(u8, store_name),
        .unique = false,
        .path = try allocator.dupe(u8, ""),
        .sha256 = try allocator.dupe(u8, ""),
        .bytes = 0,
    };

    freeIndexMetas(allocator, old_indexes);
    meta.indexes = new_indexes;
    assigned_indexes = true;
    meta.epoch += 1;
    try rebuildIndexAt(allocator, root_dir, &meta, meta.indexes.len - 1);
    try writeMeta(allocator, root_dir, table_name, meta);
    return tableInfo(meta);
}

pub fn createBlobPrefixIndex(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    store_name: []const u8,
) TableError!TableInfo {
    try validateBlobStoreName(store_name);

    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;
    try ensureBlobHandleColumn(meta, column_index);

    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND) and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null and
            index.store_name != null and
            std.mem.eql(u8, index.store_name.?, store_name))
        {
            return tableInfo(meta);
        }
    }

    const old_indexes = meta.indexes;
    const new_indexes = try allocator.alloc(IndexMeta, old_indexes.len + 1);
    initIndexMetas(new_indexes);
    var assigned_indexes = false;
    errdefer if (!assigned_indexes) freeIndexMetas(allocator, new_indexes);

    for (old_indexes, 0..) |index, idx| {
        new_indexes[idx] = try duplicateIndexMeta(allocator, index);
    }

    const new_index = &new_indexes[old_indexes.len];
    new_index.* = .{
        .name = try allocPrintPath(allocator, "blob_prefix_col{d}_{s}", .{ column_index, store_name }),
        .kind = try allocator.dupe(u8, BLOB_PREFIX_INDEX_KIND),
        .column_index = @intCast(column_index),
        .column_index2 = null,
        .store_name = try allocator.dupe(u8, store_name),
        .unique = false,
        .path = try allocator.dupe(u8, ""),
        .sha256 = try allocator.dupe(u8, ""),
        .bytes = 0,
    };

    freeIndexMetas(allocator, old_indexes);
    meta.indexes = new_indexes;
    assigned_indexes = true;
    meta.epoch += 1;
    try rebuildIndexAt(allocator, root_dir, &meta, meta.indexes.len - 1);
    try writeMeta(allocator, root_dir, table_name, meta);
    return tableInfo(meta);
}

pub fn createBlobContainsIndex(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    store_name: []const u8,
) TableError!TableInfo {
    try validateBlobStoreName(store_name);

    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadActiveMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;
    try ensureBlobHandleColumn(meta, column_index);

    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND) and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null and
            index.store_name != null and
            std.mem.eql(u8, index.store_name.?, store_name))
        {
            return tableInfo(meta);
        }
    }

    const old_indexes = meta.indexes;
    const new_indexes = try allocator.alloc(IndexMeta, old_indexes.len + 1);
    initIndexMetas(new_indexes);
    var assigned_indexes = false;
    errdefer if (!assigned_indexes) freeIndexMetas(allocator, new_indexes);

    for (old_indexes, 0..) |index, idx| {
        new_indexes[idx] = try duplicateIndexMeta(allocator, index);
    }

    const new_index = &new_indexes[old_indexes.len];
    new_index.* = .{
        .name = try allocPrintPath(allocator, "blob_contains_col{d}_{s}", .{ column_index, store_name }),
        .kind = try allocator.dupe(u8, BLOB_CONTAINS_INDEX_KIND),
        .column_index = @intCast(column_index),
        .column_index2 = null,
        .store_name = try allocator.dupe(u8, store_name),
        .unique = false,
        .path = try allocator.dupe(u8, ""),
        .sha256 = try allocator.dupe(u8, ""),
        .bytes = 0,
    };

    freeIndexMetas(allocator, old_indexes);
    meta.indexes = new_indexes;
    assigned_indexes = true;
    meta.epoch += 1;
    try rebuildIndexAt(allocator, root_dir, &meta, meta.indexes.len - 1);
    try writeMeta(allocator, root_dir, table_name, meta);
    return tableInfo(meta);
}

fn ensureU64Column(meta: TableMeta, column_index: usize) TableError!void {
    if (column_index >= meta.columns.len) return TableError.InvalidFormat;
    const column = meta.columns[column_index];
    if (column.stride != 8 or !std.mem.eql(u8, column.ty, "u64")) return TableError.InvalidFormat;
}

fn ensureI64Column(meta: TableMeta, column_index: usize) TableError!void {
    if (column_index >= meta.columns.len) return TableError.InvalidFormat;
    const column = meta.columns[column_index];
    if (column.stride != 8 or !std.mem.eql(u8, column.ty, "i64")) return TableError.InvalidFormat;
}

fn ensureU32Column(meta: TableMeta, column_index: usize) TableError!void {
    if (column_index >= meta.columns.len) return TableError.InvalidFormat;
    const column = meta.columns[column_index];
    if (column.stride != 4 or !std.mem.eql(u8, column.ty, "u32")) return TableError.InvalidFormat;
}

fn ensureI32Column(meta: TableMeta, column_index: usize) TableError!void {
    if (column_index >= meta.columns.len) return TableError.InvalidFormat;
    const column = meta.columns[column_index];
    if (column.stride != 4 or !std.mem.eql(u8, column.ty, "i32")) return TableError.InvalidFormat;
}

fn singleIndexKindName(kind: SingleIndexKind) []const u8 {
    return switch (kind) {
        .u8 => "u8",
        .i8 => "i8",
        .u16 => "u16",
        .i16 => "i16",
        .u32 => "u32",
        .i32 => "i32",
        .u64 => "u64",
        .i64 => "i64",
        .f32 => "f32",
        .f64 => "f64",
    };
}

fn singleIndexKindFromName(name: []const u8) ?SingleIndexKind {
    inline for (.{ .u8, .i8, .u16, .i16, .u32, .i32, .u64, .i64, .f32, .f64 }) |kind| {
        if (std.mem.eql(u8, name, singleIndexKindName(kind))) return kind;
    }
    return null;
}

fn singleIndexKindStride(kind: SingleIndexKind) u32 {
    return switch (kind) {
        .u8, .i8 => 1,
        .u16, .i16 => 2,
        .u32, .i32, .f32 => 4,
        .u64, .i64, .f64 => 8,
    };
}

fn ensureSingleIndexColumn(meta: TableMeta, column_index: usize, kind: SingleIndexKind) TableError!void {
    if (column_index >= meta.columns.len) return TableError.InvalidFormat;
    const column = meta.columns[column_index];
    if (column.stride != singleIndexKindStride(kind) or !std.mem.eql(u8, column.ty, singleIndexKindName(kind))) return TableError.InvalidFormat;
}

fn ensureU8Column(meta: TableMeta, column_index: usize) TableError!void {
    try ensureSingleIndexColumn(meta, column_index, .u8);
}

fn ensureI8Column(meta: TableMeta, column_index: usize) TableError!void {
    try ensureSingleIndexColumn(meta, column_index, .i8);
}

fn ensureU16Column(meta: TableMeta, column_index: usize) TableError!void {
    try ensureSingleIndexColumn(meta, column_index, .u16);
}

fn ensureI16Column(meta: TableMeta, column_index: usize) TableError!void {
    try ensureSingleIndexColumn(meta, column_index, .i16);
}

fn ensureF32Column(meta: TableMeta, column_index: usize) TableError!void {
    try ensureSingleIndexColumn(meta, column_index, .f32);
}

fn ensureF64Column(meta: TableMeta, column_index: usize) TableError!void {
    try ensureSingleIndexColumn(meta, column_index, .f64);
}

fn ensureU64PairColumns(meta: TableMeta, column_index: usize, column_index2: usize) TableError!void {
    try ensureU64Column(meta, column_index);
    try ensureU64Column(meta, column_index2);
}

fn ensureU64I64PairColumns(meta: TableMeta, column_index: usize, column_index2: usize) TableError!void {
    try ensureU64Column(meta, column_index);
    try ensureI64Column(meta, column_index2);
}

fn ensureBlobHandleColumn(meta: TableMeta, column_index: usize) TableError!void {
    if (column_index >= meta.columns.len) return TableError.InvalidFormat;
    const column = meta.columns[column_index];
    if (column.stride != 8 or !std.mem.eql(u8, column.ty, "blob_handle")) return TableError.InvalidFormat;
}

fn indexColumnIndex2(index: IndexMeta) TableError!usize {
    const column_index2 = index.column_index2 orelse return TableError.InvalidFormat;
    if (column_index2 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.InvalidFormat;
    return @intCast(column_index2);
}

fn indexBlobStoreName(index: IndexMeta) TableError![]const u8 {
    const store_name = index.store_name orelse return TableError.InvalidFormat;
    try validateBlobStoreName(store_name);
    return store_name;
}

fn readU64LE(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset .. offset + 8][0..8], .little);
}

fn readI64LE(bytes: []const u8, offset: usize) i64 {
    return std.mem.readInt(i64, bytes[offset .. offset + 8][0..8], .little);
}

fn readU32LE(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset .. offset + 4][0..4], .little);
}

fn readI32LE(bytes: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, bytes[offset .. offset + 4][0..4], .little);
}

fn readU16LE(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset .. offset + 2][0..2], .little);
}

fn readI16LE(bytes: []const u8, offset: usize) i16 {
    return std.mem.readInt(i16, bytes[offset .. offset + 2][0..2], .little);
}

fn readI8(bytes: []const u8, offset: usize) i8 {
    return @as(i8, @bitCast(bytes[offset]));
}

fn readF32LE(bytes: []const u8, offset: usize) f32 {
    return @as(f32, @bitCast(readU32LE(bytes, offset)));
}

fn readF64LE(bytes: []const u8, offset: usize) f64 {
    return @as(f64, @bitCast(readU64LE(bytes, offset)));
}

fn writeU64LE(bytes: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset .. offset + 8][0..8], value, .little);
}

fn writeI64LE(bytes: []u8, offset: usize, value: i64) void {
    std.mem.writeInt(i64, bytes[offset .. offset + 8][0..8], value, .little);
}

fn writeU32LE(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset .. offset + 4][0..4], value, .little);
}

fn writeI32LE(bytes: []u8, offset: usize, value: i32) void {
    std.mem.writeInt(i32, bytes[offset .. offset + 4][0..4], value, .little);
}

fn sortableI64Key(value: i64) u64 {
    const bits: u64 = @bitCast(value);
    return bits ^ (@as(u64, 1) << 63);
}

fn sortableI32Key(value: i32) u64 {
    const bits: u32 = @bitCast(value);
    return @as(u64, bits ^ (@as(u32, 1) << 31));
}

fn sortableI16Key(value: i16) u64 {
    const bits: u16 = @bitCast(value);
    return @as(u64, bits ^ (@as(u16, 1) << 15));
}

fn sortableI8Key(value: i8) u64 {
    const bits: u8 = @bitCast(value);
    return @as(u64, bits ^ (@as(u8, 1) << 7));
}

fn finiteF32(value: f32) TableError!f32 {
    if (!std.math.isFinite(value)) return TableError.InvalidFormat;
    return if (value == 0.0) 0.0 else value;
}

fn finiteF64(value: f64) TableError!f64 {
    if (!std.math.isFinite(value)) return TableError.InvalidFormat;
    return if (value == 0.0) 0.0 else value;
}

fn sortableF32Key(value: f32) TableError!u64 {
    const normalized = try finiteF32(value);
    const bits: u32 = @bitCast(normalized);
    const sign: u32 = @as(u32, 1) << 31;
    const key = if ((bits & sign) != 0) ~bits else bits ^ sign;
    return @as(u64, key);
}

fn sortableF64Key(value: f64) TableError!u64 {
    const normalized = try finiteF64(value);
    const bits: u64 = @bitCast(normalized);
    const sign: u64 = @as(u64, 1) << 63;
    return if ((bits & sign) != 0) ~bits else bits ^ sign;
}

fn duplicateColumnMetasToArena(allocator: std.mem.Allocator, columns: []const ColumnMeta) TableError![]ColumnMeta {
    const out = try allocator.alloc(ColumnMeta, columns.len);
    for (columns, 0..) |column, idx| {
        out[idx] = .{
            .name = try allocator.dupe(u8, column.name),
            .stride = column.stride,
            .ty = try allocator.dupe(u8, column.ty),
            .logical_type = column.logical_type,
            .logical_scale = column.logical_scale,
            .nullable = column.nullable,
        };
    }
    return out;
}

fn expectedColumnBytes(segment_rows: u64, stride: u32) TableError!usize {
    const expected = std.math.mul(u64, segment_rows, @as(u64, stride)) catch return TableError.CursorOverflow;
    if (expected > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    return @intCast(expected);
}

const INDEX_RECORD_BYTES: usize = 16;
const U64_PAIR_INDEX_RECORD_BYTES: usize = 24;
const BLOB_EQ_INDEX_KIND = "blob_eq";
const BLOB_TOKEN_INDEX_KIND = "blob_token";
const BLOB_PREFIX_INDEX_KIND = "blob_prefix";
const BLOB_CONTAINS_INDEX_KIND = "blob_contains";
const BLOB_TOKEN_MAX_BYTES: usize = 256;
const BLOB_PREFIX_MAX_BYTES: usize = 64;
const BLOB_CONTAINS_GRAM_BYTES: usize = 3;

const SingleIndexKind = enum {
    u8,
    i8,
    u16,
    i16,
    u32,
    i32,
    u64,
    i64,
    f32,
    f64,
};

const IndexEntry = struct {
    key: u64,
    row: u64,
};

const U64PairIndexEntry = struct {
    key1: u64,
    key2: u64,
    row: u64,
};

const BlobValueRef = struct {
    hash: u64 = 0,
    value: []const u8 = &.{},
    valid: bool = false,
};

const BlobEqIndexEntry = struct {
    key: u64,
    row: u64,
    blob_id: u64,
};

fn indexEntryLessThan(_: void, lhs: IndexEntry, rhs: IndexEntry) bool {
    return lhs.key < rhs.key or (lhs.key == rhs.key and lhs.row < rhs.row);
}

fn u64PairIndexEntryLessThan(_: void, lhs: U64PairIndexEntry, rhs: U64PairIndexEntry) bool {
    if (lhs.key1 != rhs.key1) return lhs.key1 < rhs.key1;
    if (lhs.key2 != rhs.key2) return lhs.key2 < rhs.key2;
    return lhs.row < rhs.row;
}

fn blobEqIndexEntryLessThan(_: void, lhs: BlobEqIndexEntry, rhs: BlobEqIndexEntry) bool {
    return lhs.key < rhs.key or (lhs.key == rhs.key and lhs.row < rhs.row);
}

fn blobValueHash(value: []const u8) u64 {
    const digest = hashBytes(value);
    return std.mem.readInt(u64, digest[0..8], .little);
}

fn isBlobTokenChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

fn normalizeBlobTokenByte(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + ('a' - 'A');
    return c;
}

fn validateBlobToken(token: []const u8) TableError!void {
    if (token.len == 0 or token.len > BLOB_TOKEN_MAX_BYTES) return TableError.InvalidFormat;
    for (token) |c| {
        if (!isBlobTokenChar(c)) return TableError.InvalidFormat;
    }
}

fn validateBlobPrefix(prefix: []const u8) TableError!void {
    if (prefix.len == 0 or prefix.len > BLOB_PREFIX_MAX_BYTES) return TableError.InvalidFormat;
    for (prefix) |c| {
        if (!isBlobTokenChar(c)) return TableError.InvalidFormat;
    }
}

fn blobTokenHash(token: []const u8) u64 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var one: [1]u8 = undefined;
    for (token) |c| {
        one[0] = normalizeBlobTokenByte(c);
        hasher.update(&one);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .little);
}

fn blobPrefixHash(prefix: []const u8) u64 {
    return blobTokenHash(prefix);
}

fn blobContainsGramHash(gram: []const u8) u64 {
    std.debug.assert(gram.len == BLOB_CONTAINS_GRAM_BYTES);
    const digest = hashBytes(gram);
    return std.mem.readInt(u64, digest[0..8], .little);
}

fn appendBlobContainsEntriesForValue(entries: *std.ArrayList(IndexEntry), row: u64, value: []const u8) TableError!void {
    if (value.len < BLOB_CONTAINS_GRAM_BYTES) return;
    var start: usize = 0;
    while (start + BLOB_CONTAINS_GRAM_BYTES <= value.len) : (start += 1) {
        const gram = value[start .. start + BLOB_CONTAINS_GRAM_BYTES];
        try entries.append(.{ .key = blobContainsGramHash(gram), .row = row });
    }
}

fn blobTokenEquals(value_token: []const u8, query_token: []const u8) bool {
    if (value_token.len != query_token.len) return false;
    for (value_token, query_token) |a, b| {
        if (normalizeBlobTokenByte(a) != normalizeBlobTokenByte(b)) return false;
    }
    return true;
}

fn blobTokenStartsWith(value_token: []const u8, query_prefix: []const u8) bool {
    if (value_token.len < query_prefix.len) return false;
    for (value_token[0..query_prefix.len], query_prefix) |a, b| {
        if (normalizeBlobTokenByte(a) != normalizeBlobTokenByte(b)) return false;
    }
    return true;
}

fn blobValueHasToken(value: []const u8, query_token: []const u8) bool {
    var token_start: ?usize = null;
    for (value, 0..) |c, idx| {
        if (isBlobTokenChar(c)) {
            if (token_start == null) token_start = idx;
            continue;
        }
        if (token_start) |start| {
            const token = value[start..idx];
            if (token.len <= BLOB_TOKEN_MAX_BYTES and blobTokenEquals(token, query_token)) return true;
            token_start = null;
        }
    }
    if (token_start) |start| {
        const token = value[start..];
        if (token.len <= BLOB_TOKEN_MAX_BYTES and blobTokenEquals(token, query_token)) return true;
    }
    return false;
}

fn blobValueHasTokenPrefix(value: []const u8, query_prefix: []const u8) bool {
    var token_start: ?usize = null;
    for (value, 0..) |c, idx| {
        if (isBlobTokenChar(c)) {
            if (token_start == null) token_start = idx;
            continue;
        }
        if (token_start) |start| {
            const token = value[start..idx];
            if (blobTokenStartsWith(token, query_prefix)) return true;
            token_start = null;
        }
    }
    if (token_start) |start| {
        const token = value[start..];
        if (blobTokenStartsWith(token, query_prefix)) return true;
    }
    return false;
}

fn appendBlobTokenEntriesForValue(entries: *std.ArrayList(IndexEntry), row: u64, value: []const u8) TableError!void {
    var token_start: ?usize = null;
    for (value, 0..) |c, idx| {
        if (isBlobTokenChar(c)) {
            if (token_start == null) token_start = idx;
            continue;
        }
        if (token_start) |start| {
            const token = value[start..idx];
            if (token.len != 0 and token.len <= BLOB_TOKEN_MAX_BYTES) {
                try entries.append(.{ .key = blobTokenHash(token), .row = row });
            }
            token_start = null;
        }
    }
    if (token_start) |start| {
        const token = value[start..];
        if (token.len != 0 and token.len <= BLOB_TOKEN_MAX_BYTES) {
            try entries.append(.{ .key = blobTokenHash(token), .row = row });
        }
    }
}

fn appendBlobPrefixEntriesForToken(entries: *std.ArrayList(IndexEntry), row: u64, token: []const u8) TableError!void {
    const capped_len = @min(token.len, BLOB_PREFIX_MAX_BYTES);
    var prefix_len: usize = 1;
    while (prefix_len <= capped_len) : (prefix_len += 1) {
        try entries.append(.{ .key = blobPrefixHash(token[0..prefix_len]), .row = row });
    }
}

fn appendBlobPrefixEntriesForValue(entries: *std.ArrayList(IndexEntry), row: u64, value: []const u8) TableError!void {
    var token_start: ?usize = null;
    for (value, 0..) |c, idx| {
        if (isBlobTokenChar(c)) {
            if (token_start == null) token_start = idx;
            continue;
        }
        if (token_start) |start| {
            const token = value[start..idx];
            if (token.len != 0) try appendBlobPrefixEntriesForToken(entries, row, token);
            token_start = null;
        }
    }
    if (token_start) |start| {
        const token = value[start..];
        if (token.len != 0) try appendBlobPrefixEntriesForToken(entries, row, token);
    }
}

fn buildBlobValueRefs(allocator: std.mem.Allocator, bytes: []const u8) TableError![]BlobValueRef {
    const count = try blobEntryCount(bytes);
    const ref_count = std.math.add(u64, count, 1) catch return TableError.CursorOverflow;
    if (ref_count > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    const refs = try allocator.alloc(BlobValueRef, @intCast(ref_count));
    errdefer allocator.free(refs);
    for (refs) |*item| item.* = .{};

    var offset: usize = 8;
    var id: u64 = 1;
    while (id <= count) : (id += 1) {
        const len_u64 = readU64LE(bytes, offset);
        const len: usize = @intCast(len_u64);
        offset += 8;
        const value = bytes[offset .. offset + len];
        refs[@intCast(id)] = .{
            .hash = blobValueHash(value),
            .value = value,
            .valid = true,
        };
        offset += len;
    }
    return refs;
}

fn blobRefForId(refs: []const BlobValueRef, id: u64) ?BlobValueRef {
    if (id > @as(u64, @intCast(std.math.maxInt(usize)))) return null;
    const idx: usize = @intCast(id);
    if (idx >= refs.len or !refs[idx].valid) return null;
    return refs[idx];
}

fn readIndexKey(bytes: []const u8, entry_index: usize) u64 {
    const offset = entry_index * INDEX_RECORD_BYTES;
    return std.mem.readInt(u64, bytes[offset .. offset + 8][0..8], .little);
}

fn readIndexRow(bytes: []const u8, entry_index: usize) u64 {
    const offset = entry_index * INDEX_RECORD_BYTES + 8;
    return std.mem.readInt(u64, bytes[offset .. offset + 8][0..8], .little);
}

fn writeIndexEntry(bytes: []u8, entry_index: usize, entry: IndexEntry) void {
    const offset = entry_index * INDEX_RECORD_BYTES;
    std.mem.writeInt(u64, bytes[offset .. offset + 8][0..8], entry.key, .little);
    std.mem.writeInt(u64, bytes[offset + 8 .. offset + 16][0..8], entry.row, .little);
}

fn readU64PairIndexKey1(bytes: []const u8, entry_index: usize) u64 {
    const offset = entry_index * U64_PAIR_INDEX_RECORD_BYTES;
    return std.mem.readInt(u64, bytes[offset .. offset + 8][0..8], .little);
}

fn readU64PairIndexKey2(bytes: []const u8, entry_index: usize) u64 {
    const offset = entry_index * U64_PAIR_INDEX_RECORD_BYTES + 8;
    return std.mem.readInt(u64, bytes[offset .. offset + 8][0..8], .little);
}

fn readU64PairIndexRow(bytes: []const u8, entry_index: usize) u64 {
    const offset = entry_index * U64_PAIR_INDEX_RECORD_BYTES + 16;
    return std.mem.readInt(u64, bytes[offset .. offset + 8][0..8], .little);
}

fn writeU64PairIndexEntry(bytes: []u8, entry_index: usize, entry: U64PairIndexEntry) void {
    const offset = entry_index * U64_PAIR_INDEX_RECORD_BYTES;
    std.mem.writeInt(u64, bytes[offset .. offset + 8][0..8], entry.key1, .little);
    std.mem.writeInt(u64, bytes[offset + 8 .. offset + 16][0..8], entry.key2, .little);
    std.mem.writeInt(u64, bytes[offset + 16 .. offset + 24][0..8], entry.row, .little);
}

fn expectedIndexBytes(row_count: u64) TableError!usize {
    const expected = std.math.mul(u64, row_count, INDEX_RECORD_BYTES) catch return TableError.CursorOverflow;
    if (expected > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    return @intCast(expected);
}

fn expectedU64PairIndexBytes(row_count: u64) TableError!usize {
    const expected = std.math.mul(u64, row_count, U64_PAIR_INDEX_RECORD_BYTES) catch return TableError.CursorOverflow;
    if (expected > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    return @intCast(expected);
}

fn validateIndexBytesShape(bytes: []const u8, row_count: u64, unique: bool) TableError!void {
    if (bytes.len != try expectedIndexBytes(row_count)) return TableError.VerifyFailed;
    if (bytes.len % INDEX_RECORD_BYTES != 0) return TableError.VerifyFailed;
    const n = bytes.len / INDEX_RECORD_BYTES;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const row = readIndexRow(bytes, i);
        if (row >= row_count) return TableError.VerifyFailed;
        if (i > 0) {
            const prev_key = readIndexKey(bytes, i - 1);
            const key = readIndexKey(bytes, i);
            const prev_row = readIndexRow(bytes, i - 1);
            if (prev_key > key) return TableError.VerifyFailed;
            if (prev_key == key) {
                if (unique) return TableError.VerifyFailed;
                if (prev_row > row) return TableError.VerifyFailed;
            }
        }
    }
}

fn validateVariableIndexBytesShape(bytes: []const u8, row_count: u64) TableError!void {
    if (bytes.len % INDEX_RECORD_BYTES != 0) return TableError.VerifyFailed;
    const n = bytes.len / INDEX_RECORD_BYTES;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const row = readIndexRow(bytes, i);
        if (row >= row_count) return TableError.VerifyFailed;
        if (i > 0) {
            const prev_key = readIndexKey(bytes, i - 1);
            const key = readIndexKey(bytes, i);
            const prev_row = readIndexRow(bytes, i - 1);
            if (prev_key > key) return TableError.VerifyFailed;
            if (prev_key == key and prev_row >= row) return TableError.VerifyFailed;
        }
    }
}

fn validateU64PairIndexBytesShape(bytes: []const u8, row_count: u64, unique: bool) TableError!void {
    if (bytes.len != try expectedU64PairIndexBytes(row_count)) return TableError.VerifyFailed;
    if (bytes.len % U64_PAIR_INDEX_RECORD_BYTES != 0) return TableError.VerifyFailed;
    const n = bytes.len / U64_PAIR_INDEX_RECORD_BYTES;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const row = readU64PairIndexRow(bytes, i);
        if (row >= row_count) return TableError.VerifyFailed;
        if (i > 0) {
            const prev_key1 = readU64PairIndexKey1(bytes, i - 1);
            const prev_key2 = readU64PairIndexKey2(bytes, i - 1);
            const prev_row = readU64PairIndexRow(bytes, i - 1);
            const key1 = readU64PairIndexKey1(bytes, i);
            const key2 = readU64PairIndexKey2(bytes, i);
            if (prev_key1 > key1) return TableError.VerifyFailed;
            if (prev_key1 == key1) {
                if (prev_key2 > key2) return TableError.VerifyFailed;
                if (prev_key2 == key2) {
                    if (unique) return TableError.VerifyFailed;
                    if (prev_row > row) return TableError.VerifyFailed;
                }
            }
        }
    }
}

fn buildU64IndexBytes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    unique: bool,
) TableError![]u8 {
    try ensureU64Column(meta, column_index);
    if (meta.row_count > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    const entries = try allocator.alloc(IndexEntry, @intCast(meta.row_count));
    defer allocator.free(entries);

    var row_base: u64 = 0;
    var entry_idx: usize = 0;
    for (meta.segments) |segment| {
        const file_meta = segment.files[column_index];
        const path = try activePath(allocator, root_dir, file_meta.path);
        defer allocator.free(path);
        const bytes = try readFileAlloc(allocator, path, 1 << 30);
        defer allocator.free(bytes);
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len or file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            entries[entry_idx] = .{ .key = readU64LE(bytes, byte_offset), .row = row_base + i };
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    std.sort.block(IndexEntry, entries, {}, indexEntryLessThan);
    if (unique and entries.len > 1) {
        for (entries[1..], 1..) |entry, idx| {
            if (entry.key == entries[idx - 1].key) return TableError.ConstraintViolation;
        }
    }

    const out = try allocator.alloc(u8, try expectedIndexBytes(meta.row_count));
    for (entries, 0..) |entry, idx| writeIndexEntry(out, idx, entry);
    return out;
}

fn buildI64IndexBytes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    unique: bool,
) TableError![]u8 {
    try ensureI64Column(meta, column_index);
    if (meta.row_count > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    const entries = try allocator.alloc(IndexEntry, @intCast(meta.row_count));
    defer allocator.free(entries);

    var row_base: u64 = 0;
    var entry_idx: usize = 0;
    for (meta.segments) |segment| {
        const file_meta = segment.files[column_index];
        const path = try activePath(allocator, root_dir, file_meta.path);
        defer allocator.free(path);
        const bytes = try readFileAlloc(allocator, path, 1 << 30);
        defer allocator.free(bytes);
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len or file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            entries[entry_idx] = .{ .key = sortableI64Key(readI64LE(bytes, byte_offset)), .row = row_base + i };
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    std.sort.block(IndexEntry, entries, {}, indexEntryLessThan);
    if (unique and entries.len > 1) {
        for (entries[1..], 1..) |entry, idx| {
            if (entry.key == entries[idx - 1].key) return TableError.ConstraintViolation;
        }
    }

    const out = try allocator.alloc(u8, try expectedIndexBytes(meta.row_count));
    for (entries, 0..) |entry, idx| writeIndexEntry(out, idx, entry);
    return out;
}

fn buildU32IndexBytes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    unique: bool,
) TableError![]u8 {
    try ensureU32Column(meta, column_index);
    if (meta.row_count > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    const entries = try allocator.alloc(IndexEntry, @intCast(meta.row_count));
    defer allocator.free(entries);

    var row_base: u64 = 0;
    var entry_idx: usize = 0;
    for (meta.segments) |segment| {
        const file_meta = segment.files[column_index];
        const path = try activePath(allocator, root_dir, file_meta.path);
        defer allocator.free(path);
        const bytes = try readFileAlloc(allocator, path, 1 << 30);
        defer allocator.free(bytes);
        const expected_len = try expectedColumnBytes(segment.rows, 4);
        if (bytes.len != expected_len or file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            entries[entry_idx] = .{ .key = readU32LE(bytes, byte_offset), .row = row_base + i };
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    std.sort.block(IndexEntry, entries, {}, indexEntryLessThan);
    if (unique and entries.len > 1) {
        for (entries[1..], 1..) |entry, idx| {
            if (entry.key == entries[idx - 1].key) return TableError.ConstraintViolation;
        }
    }

    const out = try allocator.alloc(u8, try expectedIndexBytes(meta.row_count));
    for (entries, 0..) |entry, idx| writeIndexEntry(out, idx, entry);
    return out;
}

fn buildI32IndexBytes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    unique: bool,
) TableError![]u8 {
    try ensureI32Column(meta, column_index);
    if (meta.row_count > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    const entries = try allocator.alloc(IndexEntry, @intCast(meta.row_count));
    defer allocator.free(entries);

    var row_base: u64 = 0;
    var entry_idx: usize = 0;
    for (meta.segments) |segment| {
        const file_meta = segment.files[column_index];
        const path = try activePath(allocator, root_dir, file_meta.path);
        defer allocator.free(path);
        const bytes = try readFileAlloc(allocator, path, 1 << 30);
        defer allocator.free(bytes);
        const expected_len = try expectedColumnBytes(segment.rows, 4);
        if (bytes.len != expected_len or file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            entries[entry_idx] = .{ .key = sortableI32Key(readI32LE(bytes, byte_offset)), .row = row_base + i };
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    std.sort.block(IndexEntry, entries, {}, indexEntryLessThan);
    if (unique and entries.len > 1) {
        for (entries[1..], 1..) |entry, idx| {
            if (entry.key == entries[idx - 1].key) return TableError.ConstraintViolation;
        }
    }

    const out = try allocator.alloc(u8, try expectedIndexBytes(meta.row_count));
    for (entries, 0..) |entry, idx| writeIndexEntry(out, idx, entry);
    return out;
}

fn readSmallIntegerIndexKey(kind: SingleIndexKind, bytes: []const u8, byte_offset: usize) u64 {
    return switch (kind) {
        .u8 => bytes[byte_offset],
        .i8 => sortableI8Key(readI8(bytes, byte_offset)),
        .u16 => readU16LE(bytes, byte_offset),
        .i16 => sortableI16Key(readI16LE(bytes, byte_offset)),
        .u32 => readU32LE(bytes, byte_offset),
        .i32 => sortableI32Key(readI32LE(bytes, byte_offset)),
        .u64 => readU64LE(bytes, byte_offset),
        .i64 => sortableI64Key(readI64LE(bytes, byte_offset)),
        .f32 => sortableF32Key(readF32LE(bytes, byte_offset)) catch unreachable,
        .f64 => sortableF64Key(readF64LE(bytes, byte_offset)) catch unreachable,
    };
}

fn readSingleIndexKey(kind: SingleIndexKind, bytes: []const u8, byte_offset: usize) TableError!u64 {
    return switch (kind) {
        .f32 => sortableF32Key(readF32LE(bytes, byte_offset)),
        .f64 => sortableF64Key(readF64LE(bytes, byte_offset)),
        else => readSmallIntegerIndexKey(kind, bytes, byte_offset),
    };
}

fn buildSmallIntegerIndexBytes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    unique: bool,
    kind: SingleIndexKind,
) TableError![]u8 {
    try ensureSingleIndexColumn(meta, column_index, kind);
    if (meta.row_count > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    const entries = try allocator.alloc(IndexEntry, @intCast(meta.row_count));
    defer allocator.free(entries);

    const stride = singleIndexKindStride(kind);
    var row_base: u64 = 0;
    var entry_idx: usize = 0;
    for (meta.segments) |segment| {
        const file_meta = segment.files[column_index];
        const path = try activePath(allocator, root_dir, file_meta.path);
        defer allocator.free(path);
        const bytes = try readFileAlloc(allocator, path, 1 << 30);
        defer allocator.free(bytes);
        const expected_len = try expectedColumnBytes(segment.rows, stride);
        if (bytes.len != expected_len or file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * @as(u64, stride));
            entries[entry_idx] = .{ .key = try readSingleIndexKey(kind, bytes, byte_offset), .row = row_base + i };
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    std.sort.block(IndexEntry, entries, {}, indexEntryLessThan);
    if (unique and entries.len > 1) {
        for (entries[1..], 1..) |entry, idx| {
            if (entry.key == entries[idx - 1].key) return TableError.ConstraintViolation;
        }
    }

    const out = try allocator.alloc(u8, try expectedIndexBytes(meta.row_count));
    for (entries, 0..) |entry, idx| writeIndexEntry(out, idx, entry);
    return out;
}

fn buildU8IndexBytes(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta, column_index: usize, unique: bool) TableError![]u8 {
    return buildSmallIntegerIndexBytes(allocator, root_dir, meta, column_index, unique, .u8);
}

fn buildI8IndexBytes(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta, column_index: usize, unique: bool) TableError![]u8 {
    return buildSmallIntegerIndexBytes(allocator, root_dir, meta, column_index, unique, .i8);
}

fn buildU16IndexBytes(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta, column_index: usize, unique: bool) TableError![]u8 {
    return buildSmallIntegerIndexBytes(allocator, root_dir, meta, column_index, unique, .u16);
}

fn buildI16IndexBytes(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta, column_index: usize, unique: bool) TableError![]u8 {
    return buildSmallIntegerIndexBytes(allocator, root_dir, meta, column_index, unique, .i16);
}

fn buildF32IndexBytes(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta, column_index: usize, unique: bool) TableError![]u8 {
    return buildSmallIntegerIndexBytes(allocator, root_dir, meta, column_index, unique, .f32);
}

fn buildF64IndexBytes(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta, column_index: usize, unique: bool) TableError![]u8 {
    return buildSmallIntegerIndexBytes(allocator, root_dir, meta, column_index, unique, .f64);
}

fn buildU64PairIndexBytes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    column_index2: usize,
    unique: bool,
) TableError![]u8 {
    try ensureU64PairColumns(meta, column_index, column_index2);
    if (meta.row_count > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    const entries = try allocator.alloc(U64PairIndexEntry, @intCast(meta.row_count));
    defer allocator.free(entries);

    var row_base: u64 = 0;
    var entry_idx: usize = 0;
    for (meta.segments) |segment| {
        const file_meta1 = segment.files[column_index];
        const file_meta2 = segment.files[column_index2];
        const path1 = try activePath(allocator, root_dir, file_meta1.path);
        defer allocator.free(path1);
        const path2 = try activePath(allocator, root_dir, file_meta2.path);
        defer allocator.free(path2);
        const bytes1 = try readFileAlloc(allocator, path1, 1 << 30);
        defer allocator.free(bytes1);
        const bytes2 = try readFileAlloc(allocator, path2, 1 << 30);
        defer allocator.free(bytes2);
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes1.len != expected_len or file_meta1.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
        if (bytes2.len != expected_len or file_meta2.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            entries[entry_idx] = .{
                .key1 = readU64LE(bytes1, byte_offset),
                .key2 = readU64LE(bytes2, byte_offset),
                .row = row_base + i,
            };
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    std.sort.block(U64PairIndexEntry, entries, {}, u64PairIndexEntryLessThan);
    if (unique and entries.len > 1) {
        for (entries[1..], 1..) |entry, idx| {
            const previous = entries[idx - 1];
            if (entry.key1 == previous.key1 and entry.key2 == previous.key2) return TableError.ConstraintViolation;
        }
    }

    const out = try allocator.alloc(u8, try expectedU64PairIndexBytes(meta.row_count));
    for (entries, 0..) |entry, idx| writeU64PairIndexEntry(out, idx, entry);
    return out;
}

fn buildU64I64PairIndexBytes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    column_index2: usize,
    unique: bool,
) TableError![]u8 {
    try ensureU64I64PairColumns(meta, column_index, column_index2);
    if (meta.row_count > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    const entries = try allocator.alloc(U64PairIndexEntry, @intCast(meta.row_count));
    defer allocator.free(entries);

    var row_base: u64 = 0;
    var entry_idx: usize = 0;
    for (meta.segments) |segment| {
        const file_meta1 = segment.files[column_index];
        const file_meta2 = segment.files[column_index2];
        const path1 = try activePath(allocator, root_dir, file_meta1.path);
        defer allocator.free(path1);
        const path2 = try activePath(allocator, root_dir, file_meta2.path);
        defer allocator.free(path2);
        const bytes1 = try readFileAlloc(allocator, path1, 1 << 30);
        defer allocator.free(bytes1);
        const bytes2 = try readFileAlloc(allocator, path2, 1 << 30);
        defer allocator.free(bytes2);
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes1.len != expected_len or file_meta1.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
        if (bytes2.len != expected_len or file_meta2.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            entries[entry_idx] = .{
                .key1 = readU64LE(bytes1, byte_offset),
                .key2 = sortableI64Key(readI64LE(bytes2, byte_offset)),
                .row = row_base + i,
            };
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    std.sort.block(U64PairIndexEntry, entries, {}, u64PairIndexEntryLessThan);
    if (unique and entries.len > 1) {
        for (entries[1..], 1..) |entry, idx| {
            const previous = entries[idx - 1];
            if (entry.key1 == previous.key1 and entry.key2 == previous.key2) return TableError.ConstraintViolation;
        }
    }

    const out = try allocator.alloc(u8, try expectedU64PairIndexBytes(meta.row_count));
    for (entries, 0..) |entry, idx| writeU64PairIndexEntry(out, idx, entry);
    return out;
}

fn buildBlobEqIndexBytes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    store_name: []const u8,
    unique: bool,
) TableError![]u8 {
    try ensureBlobHandleColumn(meta, column_index);
    try validateBlobStoreName(store_name);
    if (meta.row_count > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    var blob_bytes: []u8 = &.{};
    var blob_refs: []BlobValueRef = &.{};
    var has_blob_bytes = false;
    var has_blob_refs = false;
    if (findBlobStoreMetaIndex(meta, store_name)) |blob_idx| {
        blob_bytes = try readBlobStoreBytes(allocator, root_dir, meta.blobs[blob_idx]);
        has_blob_bytes = true;
        errdefer if (!has_blob_refs) allocator.free(blob_bytes);
        blob_refs = try buildBlobValueRefs(allocator, blob_bytes);
        has_blob_refs = true;
    }
    defer if (has_blob_refs) allocator.free(blob_refs);
    defer if (has_blob_bytes) allocator.free(blob_bytes);

    const entries = try allocator.alloc(BlobEqIndexEntry, @intCast(meta.row_count));
    defer allocator.free(entries);

    var row_base: u64 = 0;
    var entry_idx: usize = 0;
    for (meta.segments) |segment| {
        const file_meta = segment.files[column_index];
        const path = try activePath(allocator, root_dir, file_meta.path);
        defer allocator.free(path);
        const bytes = try readFileAlloc(allocator, path, 1 << 30);
        defer allocator.free(bytes);
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len or file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const blob_id = readU64LE(bytes, byte_offset);
            const key = if (blobRefForId(blob_refs, blob_id)) |value_ref| value_ref.hash else 0;
            entries[entry_idx] = .{ .key = key, .row = row_base + i, .blob_id = blob_id };
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    std.sort.block(BlobEqIndexEntry, entries, {}, blobEqIndexEntryLessThan);
    if (unique and entries.len > 1) {
        var group_start: usize = 0;
        while (group_start < entries.len) {
            var group_end = group_start + 1;
            while (group_end < entries.len and entries[group_end].key == entries[group_start].key) : (group_end += 1) {}
            var i = group_start;
            while (i < group_end) : (i += 1) {
                const value = blobRefForId(blob_refs, entries[i].blob_id) orelse continue;
                var j = group_start;
                while (j < i) : (j += 1) {
                    const previous_value = blobRefForId(blob_refs, entries[j].blob_id) orelse continue;
                    if (std.mem.eql(u8, value.value, previous_value.value)) return TableError.ConstraintViolation;
                }
            }
            group_start = group_end;
        }
    }

    const out = try allocator.alloc(u8, try expectedIndexBytes(meta.row_count));
    for (entries, 0..) |entry, idx| writeIndexEntry(out, idx, .{ .key = entry.key, .row = entry.row });
    return out;
}

fn buildBlobTokenIndexBytes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    store_name: []const u8,
) TableError![]u8 {
    try ensureBlobHandleColumn(meta, column_index);
    try validateBlobStoreName(store_name);

    var blob_bytes: []u8 = &.{};
    var blob_refs: []BlobValueRef = &.{};
    var has_blob_bytes = false;
    var has_blob_refs = false;
    if (findBlobStoreMetaIndex(meta, store_name)) |blob_idx| {
        blob_bytes = try readBlobStoreBytes(allocator, root_dir, meta.blobs[blob_idx]);
        has_blob_bytes = true;
        errdefer if (!has_blob_refs) allocator.free(blob_bytes);
        blob_refs = try buildBlobValueRefs(allocator, blob_bytes);
        has_blob_refs = true;
    }
    defer if (has_blob_refs) allocator.free(blob_refs);
    defer if (has_blob_bytes) allocator.free(blob_bytes);

    var entries = std.ArrayList(IndexEntry).init(allocator);
    defer entries.deinit();

    var row_base: u64 = 0;
    for (meta.segments) |segment| {
        const file_meta = segment.files[column_index];
        const path = try activePath(allocator, root_dir, file_meta.path);
        defer allocator.free(path);
        const bytes = try readFileAlloc(allocator, path, 1 << 30);
        defer allocator.free(bytes);
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len or file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const blob_id = readU64LE(bytes, byte_offset);
            const value_ref = blobRefForId(blob_refs, blob_id) orelse continue;
            try appendBlobTokenEntriesForValue(&entries, row_base + i, value_ref.value);
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (row_base != meta.row_count) return TableError.VerifyFailed;

    std.sort.block(IndexEntry, entries.items, {}, indexEntryLessThan);
    var dedup_count: usize = 0;
    for (entries.items) |entry| {
        if (dedup_count == 0 or
            entries.items[dedup_count - 1].key != entry.key or
            entries.items[dedup_count - 1].row != entry.row)
        {
            entries.items[dedup_count] = entry;
            dedup_count += 1;
        }
    }

    const out_len = std.math.mul(usize, dedup_count, INDEX_RECORD_BYTES) catch return TableError.CursorOverflow;
    const out = try allocator.alloc(u8, out_len);
    for (entries.items[0..dedup_count], 0..) |entry, idx| writeIndexEntry(out, idx, entry);
    return out;
}

fn buildBlobPrefixIndexBytes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    store_name: []const u8,
) TableError![]u8 {
    try ensureBlobHandleColumn(meta, column_index);
    try validateBlobStoreName(store_name);

    var blob_bytes: []u8 = &.{};
    var blob_refs: []BlobValueRef = &.{};
    var has_blob_bytes = false;
    var has_blob_refs = false;
    if (findBlobStoreMetaIndex(meta, store_name)) |blob_idx| {
        blob_bytes = try readBlobStoreBytes(allocator, root_dir, meta.blobs[blob_idx]);
        has_blob_bytes = true;
        errdefer if (!has_blob_refs) allocator.free(blob_bytes);
        blob_refs = try buildBlobValueRefs(allocator, blob_bytes);
        has_blob_refs = true;
    }
    defer if (has_blob_refs) allocator.free(blob_refs);
    defer if (has_blob_bytes) allocator.free(blob_bytes);

    var entries = std.ArrayList(IndexEntry).init(allocator);
    defer entries.deinit();

    var row_base: u64 = 0;
    for (meta.segments) |segment| {
        const file_meta = segment.files[column_index];
        const path = try activePath(allocator, root_dir, file_meta.path);
        defer allocator.free(path);
        const bytes = try readFileAlloc(allocator, path, 1 << 30);
        defer allocator.free(bytes);
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len or file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const blob_id = readU64LE(bytes, byte_offset);
            const value_ref = blobRefForId(blob_refs, blob_id) orelse continue;
            try appendBlobPrefixEntriesForValue(&entries, row_base + i, value_ref.value);
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (row_base != meta.row_count) return TableError.VerifyFailed;

    std.sort.block(IndexEntry, entries.items, {}, indexEntryLessThan);
    var dedup_count: usize = 0;
    for (entries.items) |entry| {
        if (dedup_count == 0 or
            entries.items[dedup_count - 1].key != entry.key or
            entries.items[dedup_count - 1].row != entry.row)
        {
            entries.items[dedup_count] = entry;
            dedup_count += 1;
        }
    }

    const out_len = std.math.mul(usize, dedup_count, INDEX_RECORD_BYTES) catch return TableError.CursorOverflow;
    const out = try allocator.alloc(u8, out_len);
    for (entries.items[0..dedup_count], 0..) |entry, idx| writeIndexEntry(out, idx, entry);
    return out;
}

fn buildBlobContainsIndexBytes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    store_name: []const u8,
) TableError![]u8 {
    try ensureBlobHandleColumn(meta, column_index);
    try validateBlobStoreName(store_name);

    var blob_bytes: []u8 = &.{};
    var blob_refs: []BlobValueRef = &.{};
    var has_blob_bytes = false;
    var has_blob_refs = false;
    if (findBlobStoreMetaIndex(meta, store_name)) |blob_idx| {
        blob_bytes = try readBlobStoreBytes(allocator, root_dir, meta.blobs[blob_idx]);
        has_blob_bytes = true;
        errdefer if (!has_blob_refs) allocator.free(blob_bytes);
        blob_refs = try buildBlobValueRefs(allocator, blob_bytes);
        has_blob_refs = true;
    }
    defer if (has_blob_refs) allocator.free(blob_refs);
    defer if (has_blob_bytes) allocator.free(blob_bytes);

    var entries = std.ArrayList(IndexEntry).init(allocator);
    defer entries.deinit();

    var row_base: u64 = 0;
    for (meta.segments) |segment| {
        const file_meta = segment.files[column_index];
        const path = try activePath(allocator, root_dir, file_meta.path);
        defer allocator.free(path);
        const bytes = try readFileAlloc(allocator, path, 1 << 30);
        defer allocator.free(bytes);
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len or file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const blob_id = readU64LE(bytes, byte_offset);
            const value_ref = blobRefForId(blob_refs, blob_id) orelse continue;
            try appendBlobContainsEntriesForValue(&entries, row_base + i, value_ref.value);
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (row_base != meta.row_count) return TableError.VerifyFailed;

    std.sort.block(IndexEntry, entries.items, {}, indexEntryLessThan);
    var dedup_count: usize = 0;
    for (entries.items) |entry| {
        if (dedup_count == 0 or
            entries.items[dedup_count - 1].key != entry.key or
            entries.items[dedup_count - 1].row != entry.row)
        {
            entries.items[dedup_count] = entry;
            dedup_count += 1;
        }
    }

    const out_len = std.math.mul(usize, dedup_count, INDEX_RECORD_BYTES) catch return TableError.CursorOverflow;
    const out = try allocator.alloc(u8, out_len);
    for (entries.items[0..dedup_count], 0..) |entry, idx| writeIndexEntry(out, idx, entry);
    return out;
}

fn rebuildIndexAt(allocator: std.mem.Allocator, root_dir: []const u8, meta: *TableMeta, index_idx: usize) TableError!void {
    const index = &meta.indexes[index_idx];
    if (index.column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.InvalidFormat;
    const column_index: usize = @intCast(index.column_index);
    const column_index2: ?usize = if (std.mem.eql(u8, index.kind, "u64_pair") or std.mem.eql(u8, index.kind, "u64_i64_pair")) try indexColumnIndex2(index.*) else null;
    const store_name = if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND)) try indexBlobStoreName(index.*) else null;
    const bytes = if (std.mem.eql(u8, index.kind, "u64"))
        try buildU64IndexBytes(allocator, root_dir, meta.*, column_index, index.unique)
    else if (std.mem.eql(u8, index.kind, "i64"))
        try buildI64IndexBytes(allocator, root_dir, meta.*, column_index, index.unique)
    else if (std.mem.eql(u8, index.kind, "f32"))
        try buildF32IndexBytes(allocator, root_dir, meta.*, column_index, index.unique)
    else if (std.mem.eql(u8, index.kind, "f64"))
        try buildF64IndexBytes(allocator, root_dir, meta.*, column_index, index.unique)
    else if (std.mem.eql(u8, index.kind, "u8"))
        try buildU8IndexBytes(allocator, root_dir, meta.*, column_index, index.unique)
    else if (std.mem.eql(u8, index.kind, "i8"))
        try buildI8IndexBytes(allocator, root_dir, meta.*, column_index, index.unique)
    else if (std.mem.eql(u8, index.kind, "u16"))
        try buildU16IndexBytes(allocator, root_dir, meta.*, column_index, index.unique)
    else if (std.mem.eql(u8, index.kind, "i16"))
        try buildI16IndexBytes(allocator, root_dir, meta.*, column_index, index.unique)
    else if (std.mem.eql(u8, index.kind, "u32"))
        try buildU32IndexBytes(allocator, root_dir, meta.*, column_index, index.unique)
    else if (std.mem.eql(u8, index.kind, "i32"))
        try buildI32IndexBytes(allocator, root_dir, meta.*, column_index, index.unique)
    else if (std.mem.eql(u8, index.kind, "u64_pair"))
        try buildU64PairIndexBytes(allocator, root_dir, meta.*, column_index, column_index2.?, index.unique)
    else if (std.mem.eql(u8, index.kind, "u64_i64_pair"))
        try buildU64I64PairIndexBytes(allocator, root_dir, meta.*, column_index, column_index2.?, index.unique)
    else if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND))
        try buildBlobEqIndexBytes(allocator, root_dir, meta.*, column_index, store_name.?, index.unique)
    else if (std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND))
        try buildBlobTokenIndexBytes(allocator, root_dir, meta.*, column_index, store_name.?)
    else if (std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND))
        try buildBlobPrefixIndexBytes(allocator, root_dir, meta.*, column_index, store_name.?)
    else if (std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND))
        try buildBlobContainsIndexBytes(allocator, root_dir, meta.*, column_index, store_name.?)
    else
        return TableError.InvalidFormat;
    defer allocator.free(bytes);
    const basename = if (store_name) |name|
        if (std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND))
            try blobTokenIndexFileName(allocator, meta.table_name, index.column_index, name, meta.epoch)
        else if (std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND))
            try blobPrefixIndexFileName(allocator, meta.table_name, index.column_index, name, meta.epoch)
        else if (std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND))
            try blobContainsIndexFileName(allocator, meta.table_name, index.column_index, name, meta.epoch)
        else
            try blobEqIndexFileName(allocator, meta.table_name, index.column_index, name, meta.epoch)
    else if (column_index2) |c2|
        try pairIndexFileName(allocator, meta.table_name, index.kind, index.column_index, @intCast(c2), meta.epoch)
    else
        try indexFileName(allocator, meta.table_name, index.kind, index.column_index, meta.epoch);
    defer allocator.free(basename);
    const path = try activePath(allocator, root_dir, basename);
    defer allocator.free(path);
    try writeFile(allocator, path, bytes);
    const next_path = try allocator.dupe(u8, basename);
    errdefer allocator.free(next_path);
    const next_hash = try hashHexAlloc(allocator, bytes);
    errdefer allocator.free(next_hash);
    const next_block_sha256 = try makeBlockSha256List(allocator, bytes, FILE_BLOCK_BYTES);
    errdefer freeBlockSha256List(allocator, next_block_sha256);
    allocator.free(index.path);
    allocator.free(index.sha256);
    freeBlockSha256List(allocator, index.block_sha256);
    index.path = next_path;
    index.sha256 = next_hash;
    index.bytes = bytes.len;
    index.block_size = artifactBlockSize(bytes);
    index.block_sha256 = next_block_sha256;
}

pub fn rebuildIndexes(allocator: std.mem.Allocator, root_dir: []const u8, meta: *TableMeta) TableError!void {
    for (0..meta.indexes.len) |idx| try rebuildIndexAt(allocator, root_dir, meta, idx);
}

fn rebuildBlobIndexesForStore(allocator: std.mem.Allocator, root_dir: []const u8, meta: *TableMeta, store_name: []const u8) TableError!void {
    for (0..meta.indexes.len) |idx| {
        const index = meta.indexes[idx];
        if ((std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND)) and
            index.store_name != null and
            std.mem.eql(u8, index.store_name.?, store_name))
        {
            try rebuildIndexAt(allocator, root_dir, meta, idx);
        }
    }
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
        .indexes = &.{},
        .dicts = &.{},
        .blobs = &.{},
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
    snapshot.indexes = try arena_allocator.alloc(ReadIndexSnapshot, parsed.value.indexes.len);
    snapshot.dicts = try arena_allocator.alloc(ReadDictSnapshot, parsed.value.dicts.len);
    snapshot.blobs = try arena_allocator.alloc(ReadBlobStoreSnapshot, parsed.value.blobs.len);

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
            try validateFileMetaBytes(file_meta, bytes);
            segment_columns[column_idx] = .{ .bytes = bytes };
        }
        snapshot.segments[segment_idx] = .{
            .rows = segment.rows,
            .columns = segment_columns,
        };
    }

    for (parsed.value.indexes, 0..) |index, index_idx| {
        if (index.column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.InvalidFormat;
        const column_index: usize = @intCast(index.column_index);
        var expected_bytes: usize = undefined;
        if (std.mem.eql(u8, index.kind, "u64")) {
            if (index.column_index2 != null) return TableError.InvalidFormat;
            try ensureSnapshotU64Column(snapshot, column_index);
            expected_bytes = try expectedIndexBytes(parsed.value.row_count);
        } else if (std.mem.eql(u8, index.kind, "i64")) {
            if (index.column_index2 != null) return TableError.InvalidFormat;
            try ensureSnapshotI64Column(snapshot, column_index);
            expected_bytes = try expectedIndexBytes(parsed.value.row_count);
        } else if (std.mem.eql(u8, index.kind, "f32")) {
            if (index.column_index2 != null) return TableError.InvalidFormat;
            try ensureSnapshotF32Column(snapshot, column_index);
            expected_bytes = try expectedIndexBytes(parsed.value.row_count);
        } else if (std.mem.eql(u8, index.kind, "f64")) {
            if (index.column_index2 != null) return TableError.InvalidFormat;
            try ensureSnapshotF64Column(snapshot, column_index);
            expected_bytes = try expectedIndexBytes(parsed.value.row_count);
        } else if (std.mem.eql(u8, index.kind, "u8")) {
            if (index.column_index2 != null) return TableError.InvalidFormat;
            try ensureSnapshotU8Column(snapshot, column_index);
            expected_bytes = try expectedIndexBytes(parsed.value.row_count);
        } else if (std.mem.eql(u8, index.kind, "i8")) {
            if (index.column_index2 != null) return TableError.InvalidFormat;
            try ensureSnapshotI8Column(snapshot, column_index);
            expected_bytes = try expectedIndexBytes(parsed.value.row_count);
        } else if (std.mem.eql(u8, index.kind, "u16")) {
            if (index.column_index2 != null) return TableError.InvalidFormat;
            try ensureSnapshotU16Column(snapshot, column_index);
            expected_bytes = try expectedIndexBytes(parsed.value.row_count);
        } else if (std.mem.eql(u8, index.kind, "i16")) {
            if (index.column_index2 != null) return TableError.InvalidFormat;
            try ensureSnapshotI16Column(snapshot, column_index);
            expected_bytes = try expectedIndexBytes(parsed.value.row_count);
        } else if (std.mem.eql(u8, index.kind, "u32")) {
            if (index.column_index2 != null) return TableError.InvalidFormat;
            try ensureSnapshotU32Column(snapshot, column_index);
            expected_bytes = try expectedIndexBytes(parsed.value.row_count);
        } else if (std.mem.eql(u8, index.kind, "i32")) {
            if (index.column_index2 != null) return TableError.InvalidFormat;
            try ensureSnapshotI32Column(snapshot, column_index);
            expected_bytes = try expectedIndexBytes(parsed.value.row_count);
        } else if (std.mem.eql(u8, index.kind, "u64_pair")) {
            const column_index2_u64 = index.column_index2 orelse return TableError.InvalidFormat;
            if (column_index2_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.InvalidFormat;
            const column_index2: usize = @intCast(column_index2_u64);
            try ensureSnapshotU64Column(snapshot, column_index);
            try ensureSnapshotU64Column(snapshot, column_index2);
            expected_bytes = try expectedU64PairIndexBytes(parsed.value.row_count);
        } else if (std.mem.eql(u8, index.kind, "u64_i64_pair")) {
            const column_index2_u64 = index.column_index2 orelse return TableError.InvalidFormat;
            if (column_index2_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.InvalidFormat;
            const column_index2: usize = @intCast(column_index2_u64);
            try ensureSnapshotU64Column(snapshot, column_index);
            try ensureSnapshotI64Column(snapshot, column_index2);
            expected_bytes = try expectedU64PairIndexBytes(parsed.value.row_count);
        } else if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND)) {
            if (index.column_index2 != null) return TableError.InvalidFormat;
            const store_name = index.store_name orelse return TableError.InvalidFormat;
            try validateBlobStoreName(store_name);
            try ensureSnapshotBlobHandleColumn(snapshot, column_index);
            expected_bytes = try expectedIndexBytes(parsed.value.row_count);
        } else if (std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND)) {
            if (index.column_index2 != null or index.unique) return TableError.InvalidFormat;
            const store_name = index.store_name orelse return TableError.InvalidFormat;
            try validateBlobStoreName(store_name);
            try ensureSnapshotBlobHandleColumn(snapshot, column_index);
            if (index.bytes > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.VerifyFailed;
            expected_bytes = @intCast(index.bytes);
        } else if (std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND)) {
            if (index.column_index2 != null or index.unique) return TableError.InvalidFormat;
            const store_name = index.store_name orelse return TableError.InvalidFormat;
            try validateBlobStoreName(store_name);
            try ensureSnapshotBlobHandleColumn(snapshot, column_index);
            if (index.bytes > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.VerifyFailed;
            expected_bytes = @intCast(index.bytes);
        } else if (std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND)) {
            if (index.column_index2 != null or index.unique) return TableError.InvalidFormat;
            const store_name = index.store_name orelse return TableError.InvalidFormat;
            try validateBlobStoreName(store_name);
            try ensureSnapshotBlobHandleColumn(snapshot, column_index);
            if (index.bytes > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.VerifyFailed;
            expected_bytes = @intCast(index.bytes);
        } else {
            return TableError.InvalidFormat;
        }
        if (index.bytes != @as(u64, @intCast(expected_bytes))) return TableError.VerifyFailed;
        const path = try activePath(backing_allocator, root_dir, index.path);
        defer backing_allocator.free(path);
        const bytes = try readFileAlloc(arena_allocator, path, 1 << 30);
        if (bytes.len != index.bytes) return TableError.VerifyFailed;
        const hash = hashBytes(bytes);
        const hex = std.fmt.bytesToHex(hash, .lower);
        if (!std.mem.eql(u8, hex[0..], index.sha256)) return TableError.VerifyFailed;
        try validateIndexBlockHashes(index, bytes);
        if (std.mem.eql(u8, index.kind, "u64_pair") or std.mem.eql(u8, index.kind, "u64_i64_pair")) {
            try validateU64PairIndexBytesShape(bytes, parsed.value.row_count, index.unique);
        } else if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND)) {
            try validateIndexBytesShape(bytes, parsed.value.row_count, false);
        } else if (std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND)) {
            try validateVariableIndexBytesShape(bytes, parsed.value.row_count);
        } else {
            try validateIndexBytesShape(bytes, parsed.value.row_count, index.unique);
        }
        snapshot.indexes[index_idx] = .{
            .kind = try arena_allocator.dupe(u8, index.kind),
            .column_index = index.column_index,
            .column_index2 = index.column_index2,
            .store_name = if (index.store_name) |store_name| try arena_allocator.dupe(u8, store_name) else null,
            .unique = index.unique,
            .entries = bytes,
        };
    }

    for (parsed.value.dicts, 0..) |dict, dict_idx| {
        try validateDictName(dict.name);
        if (dict.path.len == 0 or dict.sha256.len != 64) return TableError.VerifyFailed;
        for (parsed.value.dicts[0..dict_idx]) |previous| {
            if (std.mem.eql(u8, previous.name, dict.name)) return TableError.VerifyFailed;
        }
        const bytes = try readDictBytes(arena_allocator, root_dir, dict);
        snapshot.dicts[dict_idx] = .{
            .name = try arena_allocator.dupe(u8, dict.name),
            .bytes = bytes,
            .entries = dict.entries,
        };
    }

    for (parsed.value.blobs, 0..) |blob, blob_idx| {
        try validateBlobStoreName(blob.name);
        if (blob.path.len == 0 or blob.sha256.len != 64) return TableError.VerifyFailed;
        for (parsed.value.blobs[0..blob_idx]) |previous| {
            if (std.mem.eql(u8, previous.name, blob.name)) return TableError.VerifyFailed;
        }
        const bytes = try readBlobStoreBytes(arena_allocator, root_dir, blob);
        snapshot.blobs[blob_idx] = .{
            .name = try arena_allocator.dupe(u8, blob.name),
            .bytes = bytes,
            .entries = blob.entries,
        };
    }

    return snapshot;
}

fn ensureSnapshotU64Column(snapshot: *const ReadSnapshot, column_index: usize) TableError!void {
    if (column_index >= snapshot.columns.len) return TableError.InvalidFormat;
    const column = snapshot.columns[column_index];
    if (column.stride != 8 or !std.mem.eql(u8, column.ty, "u64")) return TableError.InvalidFormat;
}

fn ensureSnapshotI64Column(snapshot: *const ReadSnapshot, column_index: usize) TableError!void {
    if (column_index >= snapshot.columns.len) return TableError.InvalidFormat;
    const column = snapshot.columns[column_index];
    if (column.stride != 8 or !std.mem.eql(u8, column.ty, "i64")) return TableError.InvalidFormat;
}

fn ensureSnapshotU32Column(snapshot: *const ReadSnapshot, column_index: usize) TableError!void {
    if (column_index >= snapshot.columns.len) return TableError.InvalidFormat;
    const column = snapshot.columns[column_index];
    if (column.stride != 4 or !std.mem.eql(u8, column.ty, "u32")) return TableError.InvalidFormat;
}

fn ensureSnapshotI32Column(snapshot: *const ReadSnapshot, column_index: usize) TableError!void {
    if (column_index >= snapshot.columns.len) return TableError.InvalidFormat;
    const column = snapshot.columns[column_index];
    if (column.stride != 4 or !std.mem.eql(u8, column.ty, "i32")) return TableError.InvalidFormat;
}

fn ensureSnapshotSingleIndexColumn(snapshot: *const ReadSnapshot, column_index: usize, kind: SingleIndexKind) TableError!void {
    if (column_index >= snapshot.columns.len) return TableError.InvalidFormat;
    const column = snapshot.columns[column_index];
    if (column.stride != singleIndexKindStride(kind) or !std.mem.eql(u8, column.ty, singleIndexKindName(kind))) return TableError.InvalidFormat;
}

fn ensureSnapshotU8Column(snapshot: *const ReadSnapshot, column_index: usize) TableError!void {
    try ensureSnapshotSingleIndexColumn(snapshot, column_index, .u8);
}

fn ensureSnapshotI8Column(snapshot: *const ReadSnapshot, column_index: usize) TableError!void {
    try ensureSnapshotSingleIndexColumn(snapshot, column_index, .i8);
}

fn ensureSnapshotU16Column(snapshot: *const ReadSnapshot, column_index: usize) TableError!void {
    try ensureSnapshotSingleIndexColumn(snapshot, column_index, .u16);
}

fn ensureSnapshotI16Column(snapshot: *const ReadSnapshot, column_index: usize) TableError!void {
    try ensureSnapshotSingleIndexColumn(snapshot, column_index, .i16);
}

fn ensureSnapshotF32Column(snapshot: *const ReadSnapshot, column_index: usize) TableError!void {
    try ensureSnapshotSingleIndexColumn(snapshot, column_index, .f32);
}

fn ensureSnapshotF64Column(snapshot: *const ReadSnapshot, column_index: usize) TableError!void {
    try ensureSnapshotSingleIndexColumn(snapshot, column_index, .f64);
}

fn ensureSnapshotBoolColumn(snapshot: *const ReadSnapshot, column_index: usize) TableError!void {
    if (column_index >= snapshot.columns.len) return TableError.InvalidFormat;
    const column = snapshot.columns[column_index];
    if (column.logical_type != schema.LOGICAL_BOOL) return TableError.InvalidFormat;
    const ty = try parsePrimTypeTable(column.ty);
    switch (ty) {
        .i1, .u8 => if (column.stride != 1) return TableError.InvalidFormat,
        .u64 => if (column.stride != 8) return TableError.InvalidFormat,
        else => return TableError.InvalidFormat,
    }
}

fn ensureSnapshotBlobHandleColumn(snapshot: *const ReadSnapshot, column_index: usize) TableError!void {
    if (column_index >= snapshot.columns.len) return TableError.InvalidFormat;
    const column = snapshot.columns[column_index];
    if (column.stride != 8 or !std.mem.eql(u8, column.ty, "blob_handle")) return TableError.InvalidFormat;
}

fn snapshotFindDictIndex(snapshot: *const ReadSnapshot, dict_name: []const u8) ?usize {
    for (snapshot.dicts, 0..) |dict, idx| {
        if (std.mem.eql(u8, dict.name, dict_name)) return idx;
    }
    return null;
}

pub fn snapshotDictLookup(snapshot: *const ReadSnapshot, dict_name: []const u8, value: []const u8) TableError!DictLookupResult {
    try validateDictName(dict_name);
    try validateDictValue(value);
    const idx = snapshotFindDictIndex(snapshot, dict_name) orelse return .{ .found = false, .id = 0 };
    if (try dictFindValueId(snapshot.dicts[idx].bytes, value)) |id| return .{ .found = true, .id = id };
    return .{ .found = false, .id = 0 };
}

pub fn snapshotDictValueLen(snapshot: *const ReadSnapshot, dict_name: []const u8, id: u64) TableError!DictValueLenResult {
    try validateDictName(dict_name);
    const idx = snapshotFindDictIndex(snapshot, dict_name) orelse return .{ .found = false, .len = 0 };
    const value = (try dictValueSliceById(snapshot.dicts[idx].bytes, id)) orelse return .{ .found = false, .len = 0 };
    return .{ .found = true, .len = value.len };
}

pub fn snapshotDictValueCopy(snapshot: *const ReadSnapshot, dict_name: []const u8, id: u64, out: []u8) TableError!DictValueCopyResult {
    try validateDictName(dict_name);
    const idx = snapshotFindDictIndex(snapshot, dict_name) orelse return .{ .found = false, .written = 0 };
    const value = (try dictValueSliceById(snapshot.dicts[idx].bytes, id)) orelse return .{ .found = false, .written = 0 };
    if (out.len < value.len) return TableError.CursorOverflow;
    @memcpy(out[0..value.len], value);
    return .{ .found = true, .written = value.len };
}

fn snapshotFindBlobStoreIndex(snapshot: *const ReadSnapshot, store_name: []const u8) ?usize {
    for (snapshot.blobs, 0..) |blob, idx| {
        if (std.mem.eql(u8, blob.name, store_name)) return idx;
    }
    return null;
}

pub fn snapshotBlobValueLen(snapshot: *const ReadSnapshot, store_name: []const u8, id: u64) TableError!BlobValueLenResult {
    try validateBlobStoreName(store_name);
    const idx = snapshotFindBlobStoreIndex(snapshot, store_name) orelse return .{ .found = false, .len = 0 };
    const value = (try blobValueSliceById(snapshot.blobs[idx].bytes, id)) orelse return .{ .found = false, .len = 0 };
    return .{ .found = true, .len = value.len };
}

pub fn snapshotBlobValueCopy(snapshot: *const ReadSnapshot, store_name: []const u8, id: u64, out: []u8) TableError!BlobValueCopyResult {
    try validateBlobStoreName(store_name);
    const idx = snapshotFindBlobStoreIndex(snapshot, store_name) orelse return .{ .found = false, .written = 0 };
    const value = (try blobValueSliceById(snapshot.blobs[idx].bytes, id)) orelse return .{ .found = false, .written = 0 };
    if (out.len < value.len) return TableError.CursorOverflow;
    if (value.len != 0) @memcpy(out[0..value.len], value);
    return .{ .found = true, .written = value.len };
}

fn blobFilterValueMatches(value: []const u8, needle: []const u8, mode: BlobFilterMode) bool {
    return switch (mode) {
        .eq => std.mem.eql(u8, value, needle),
        .contains => std.mem.indexOf(u8, value, needle) != null,
    };
}

fn setBlobMatchBit(matches: []u8, id: u64) void {
    const byte_index: usize = @intCast(id >> 3);
    const bit: u3 = @intCast(id & 7);
    matches[byte_index] |= @as(u8, 1) << bit;
}

fn getBlobMatchBit(matches: []const u8, id: u64) bool {
    if (id >> 3 > @as(u64, @intCast(std.math.maxInt(usize)))) return false;
    const byte_index: usize = @intCast(id >> 3);
    if (byte_index >= matches.len) return false;
    const bit: u3 = @intCast(id & 7);
    return (matches[byte_index] & (@as(u8, 1) << bit)) != 0;
}

fn buildBlobMatchBitmap(allocator: std.mem.Allocator, bytes: []const u8, needle: []const u8, mode: BlobFilterMode) TableError![]u8 {
    const count = try blobEntryCount(bytes);
    const bit_count = std.math.add(u64, count, 1) catch return TableError.CursorOverflow;
    const bitmap_len_u64 = (bit_count + 7) / 8;
    if (bitmap_len_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    const matches = try allocator.alloc(u8, @intCast(bitmap_len_u64));
    errdefer allocator.free(matches);
    @memset(matches, 0);

    var offset: usize = 8;
    var id: u64 = 1;
    while (id <= count) : (id += 1) {
        const len_u64 = readU64LE(bytes, offset);
        const len: usize = @intCast(len_u64);
        offset += 8;
        const value = bytes[offset .. offset + len];
        if (blobFilterValueMatches(value, needle, mode)) setBlobMatchBit(matches, id);
        offset += len;
    }
    return matches;
}

fn snapshotBlobHandleAtRow(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!u64 {
    if (row_index >= snapshot.row_count) return TableError.VerifyFailed;
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const segment_end = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        if (row_index < segment_end) {
            const local_row = row_index - row_base;
            const bytes = segment.columns[column_index].bytes;
            const expected_len = try expectedColumnBytes(segment.rows, 8);
            if (bytes.len != expected_len) return TableError.VerifyFailed;
            const byte_offset_u64 = std.math.mul(u64, local_row, 8) catch return TableError.CursorOverflow;
            if (byte_offset_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
            const byte_offset: usize = @intCast(byte_offset_u64);
            return readU64LE(bytes, byte_offset);
        }
        row_base = segment_end;
    }
    return TableError.VerifyFailed;
}

fn snapshotFilterBlobEqRowsIndexed(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    index: ReadIndexSnapshot,
    column_index: usize,
    blob_bytes: []const u8,
    needle: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BlobFilterResult {
    const refs = try buildBlobValueRefs(allocator, blob_bytes);
    defer allocator.free(refs);

    const key = blobValueHash(needle);
    const start = lowerBoundU64Index(index, key);
    const end = upperBoundU64Index(index, key);
    var total: u64 = 0;
    var written: u64 = 0;
    const out_capacity: u64 = @intCast(out_rows.len);
    var i = start;
    while (i < end) : (i += 1) {
        const row = readIndexRow(index.entries, i);
        if (row >= snapshot.row_count) return TableError.VerifyFailed;
        const blob_id = try snapshotBlobHandleAtRow(snapshot, column_index, row);
        const value_ref = blobRefForId(refs, blob_id) orelse continue;
        if (!std.mem.eql(u8, value_ref.value, needle)) continue;
        if (total >= offset and limit != 0 and written < limit and written < out_capacity) {
            out_rows[@intCast(written)] = row;
            written += 1;
        }
        total = std.math.add(u64, total, 1) catch return TableError.CursorOverflow;
    }
    return .{ .written = written, .total = total };
}

fn snapshotFilterBlobTokenRowsIndexed(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    index: ReadIndexSnapshot,
    column_index: usize,
    blob_bytes: []const u8,
    token: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BlobFilterResult {
    const refs = try buildBlobValueRefs(allocator, blob_bytes);
    defer allocator.free(refs);

    const key = blobTokenHash(token);
    const start = lowerBoundU64Index(index, key);
    const end = upperBoundU64Index(index, key);
    var total: u64 = 0;
    var written: u64 = 0;
    const out_capacity: u64 = @intCast(out_rows.len);
    var i = start;
    while (i < end) : (i += 1) {
        const row = readIndexRow(index.entries, i);
        if (row >= snapshot.row_count) return TableError.VerifyFailed;
        const blob_id = try snapshotBlobHandleAtRow(snapshot, column_index, row);
        const value_ref = blobRefForId(refs, blob_id) orelse continue;
        if (!blobValueHasToken(value_ref.value, token)) continue;
        if (total >= offset and limit != 0 and written < limit and written < out_capacity) {
            out_rows[@intCast(written)] = row;
            written += 1;
        }
        total = std.math.add(u64, total, 1) catch return TableError.CursorOverflow;
    }
    return .{ .written = written, .total = total };
}

fn snapshotFilterBlobPrefixRowsIndexed(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    index: ReadIndexSnapshot,
    column_index: usize,
    blob_bytes: []const u8,
    prefix: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BlobFilterResult {
    const refs = try buildBlobValueRefs(allocator, blob_bytes);
    defer allocator.free(refs);

    const key = blobPrefixHash(prefix);
    const start = lowerBoundU64Index(index, key);
    const end = upperBoundU64Index(index, key);
    var total: u64 = 0;
    var written: u64 = 0;
    const out_capacity: u64 = @intCast(out_rows.len);
    var i = start;
    while (i < end) : (i += 1) {
        const row = readIndexRow(index.entries, i);
        if (row >= snapshot.row_count) return TableError.VerifyFailed;
        const blob_id = try snapshotBlobHandleAtRow(snapshot, column_index, row);
        const value_ref = blobRefForId(refs, blob_id) orelse continue;
        if (!blobValueHasTokenPrefix(value_ref.value, prefix)) continue;
        if (total >= offset and limit != 0 and written < limit and written < out_capacity) {
            out_rows[@intCast(written)] = row;
            written += 1;
        }
        total = std.math.add(u64, total, 1) catch return TableError.CursorOverflow;
    }
    return .{ .written = written, .total = total };
}

fn snapshotFilterBlobContainsRowsIndexed(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    index: ReadIndexSnapshot,
    column_index: usize,
    blob_bytes: []const u8,
    needle: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BlobFilterResult {
    if (needle.len < BLOB_CONTAINS_GRAM_BYTES) return TableError.InvalidFormat;

    var selected_start: usize = 0;
    var selected_end: usize = 0;
    var selected_count: usize = std.math.maxInt(usize);
    var have_key = false;
    var gram_start: usize = 0;
    while (gram_start + BLOB_CONTAINS_GRAM_BYTES <= needle.len) : (gram_start += 1) {
        const key = blobContainsGramHash(needle[gram_start .. gram_start + BLOB_CONTAINS_GRAM_BYTES]);
        const start = lowerBoundU64Index(index, key);
        const end = upperBoundU64Index(index, key);
        const count = end - start;
        if (!have_key or count < selected_count) {
            selected_start = start;
            selected_end = end;
            selected_count = count;
            have_key = true;
            if (count == 0) break;
        }
    }
    if (!have_key or selected_start == selected_end) return .{ .written = 0, .total = 0 };

    const refs = try buildBlobValueRefs(allocator, blob_bytes);
    defer allocator.free(refs);

    var total: u64 = 0;
    var written: u64 = 0;
    const out_capacity: u64 = @intCast(out_rows.len);
    var i = selected_start;
    while (i < selected_end) : (i += 1) {
        const row = readIndexRow(index.entries, i);
        if (row >= snapshot.row_count) return TableError.VerifyFailed;
        const blob_id = try snapshotBlobHandleAtRow(snapshot, column_index, row);
        const value_ref = blobRefForId(refs, blob_id) orelse continue;
        if (std.mem.indexOf(u8, value_ref.value, needle) == null) continue;
        if (total >= offset and limit != 0 and written < limit and written < out_capacity) {
            out_rows[@intCast(written)] = row;
            written += 1;
        }
        total = std.math.add(u64, total, 1) catch return TableError.CursorOverflow;
    }
    return .{ .written = written, .total = total };
}

fn snapshotFilterBlobRowsMode(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    store_name: []const u8,
    needle: []const u8,
    mode: BlobFilterMode,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BlobFilterResult {
    try ensureSnapshotBlobHandleColumn(snapshot, column_index);
    try validateBlobStoreName(store_name);
    try validateBlobValue(needle);
    const blob_idx = snapshotFindBlobStoreIndex(snapshot, store_name) orelse return .{ .written = 0, .total = 0 };
    if (mode == .eq) {
        if (snapshotIndexForBlobEqColumnStore(snapshot, column_index, store_name)) |index| {
            return snapshotFilterBlobEqRowsIndexed(allocator, snapshot, index, column_index, snapshot.blobs[blob_idx].bytes, needle, offset, limit, out_rows);
        }
    } else if (mode == .contains and needle.len >= BLOB_CONTAINS_GRAM_BYTES) {
        if (snapshotIndexForBlobContainsColumnStore(snapshot, column_index, store_name)) |index| {
            return snapshotFilterBlobContainsRowsIndexed(allocator, snapshot, index, column_index, snapshot.blobs[blob_idx].bytes, needle, offset, limit, out_rows);
        }
    }
    const matches = try buildBlobMatchBitmap(allocator, snapshot.blobs[blob_idx].bytes, needle, mode);
    defer allocator.free(matches);

    var total: u64 = 0;
    var written: u64 = 0;
    const out_capacity: u64 = @intCast(out_rows.len);
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const id = readU64LE(bytes, byte_offset);
            if (id != 0 and getBlobMatchBit(matches, id)) {
                if (total >= offset and limit != 0 and written < limit and written < out_capacity) {
                    out_rows[@intCast(written)] = row_base + i;
                    written += 1;
                }
                total = std.math.add(u64, total, 1) catch return TableError.CursorOverflow;
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .written = written, .total = total };
}

pub fn snapshotFilterBlobEqRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    store_name: []const u8,
    needle: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BlobFilterResult {
    return snapshotFilterBlobRowsMode(allocator, snapshot, column_index, store_name, needle, .eq, offset, limit, out_rows);
}

pub fn snapshotFilterBlobContainsRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    store_name: []const u8,
    needle: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BlobFilterResult {
    return snapshotFilterBlobRowsMode(allocator, snapshot, column_index, store_name, needle, .contains, offset, limit, out_rows);
}

pub fn snapshotFilterBlobTokenRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    store_name: []const u8,
    token: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BlobFilterResult {
    try ensureSnapshotBlobHandleColumn(snapshot, column_index);
    try validateBlobStoreName(store_name);
    try validateBlobToken(token);
    const blob_idx = snapshotFindBlobStoreIndex(snapshot, store_name) orelse return .{ .written = 0, .total = 0 };
    if (snapshotIndexForBlobTokenColumnStore(snapshot, column_index, store_name)) |index| {
        return snapshotFilterBlobTokenRowsIndexed(allocator, snapshot, index, column_index, snapshot.blobs[blob_idx].bytes, token, offset, limit, out_rows);
    }

    const refs = try buildBlobValueRefs(allocator, snapshot.blobs[blob_idx].bytes);
    defer allocator.free(refs);

    var total: u64 = 0;
    var written: u64 = 0;
    const out_capacity: u64 = @intCast(out_rows.len);
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const id = readU64LE(bytes, byte_offset);
            const value_ref = blobRefForId(refs, id) orelse continue;
            if (blobValueHasToken(value_ref.value, token)) {
                if (total >= offset and limit != 0 and written < limit and written < out_capacity) {
                    out_rows[@intCast(written)] = row_base + i;
                    written += 1;
                }
                total = std.math.add(u64, total, 1) catch return TableError.CursorOverflow;
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .written = written, .total = total };
}

pub fn snapshotFilterBlobPrefixRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    store_name: []const u8,
    prefix: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BlobFilterResult {
    try ensureSnapshotBlobHandleColumn(snapshot, column_index);
    try validateBlobStoreName(store_name);
    try validateBlobPrefix(prefix);
    const blob_idx = snapshotFindBlobStoreIndex(snapshot, store_name) orelse return .{ .written = 0, .total = 0 };
    if (snapshotIndexForBlobPrefixColumnStore(snapshot, column_index, store_name)) |index| {
        return snapshotFilterBlobPrefixRowsIndexed(allocator, snapshot, index, column_index, snapshot.blobs[blob_idx].bytes, prefix, offset, limit, out_rows);
    }

    const refs = try buildBlobValueRefs(allocator, snapshot.blobs[blob_idx].bytes);
    defer allocator.free(refs);

    var total: u64 = 0;
    var written: u64 = 0;
    const out_capacity: u64 = @intCast(out_rows.len);
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const id = readU64LE(bytes, byte_offset);
            const value_ref = blobRefForId(refs, id) orelse continue;
            if (blobValueHasTokenPrefix(value_ref.value, prefix)) {
                if (total >= offset and limit != 0 and written < limit and written < out_capacity) {
                    out_rows[@intCast(written)] = row_base + i;
                    written += 1;
                }
                total = std.math.add(u64, total, 1) catch return TableError.CursorOverflow;
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .written = written, .total = total };
}

fn readBoolColumnValue(column: ColumnMeta, bytes: []const u8, local_row: u64) TableError!bool {
    const stride = column.stride;
    const offset_u64 = std.math.mul(u64, local_row, @as(u64, stride)) catch return TableError.CursorOverflow;
    const end_u64 = std.math.add(u64, offset_u64, @as(u64, stride)) catch return TableError.CursorOverflow;
    if (end_u64 > @as(u64, @intCast(bytes.len))) return TableError.VerifyFailed;
    if (offset_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    const offset: usize = @intCast(offset_u64);
    const raw: u64 = switch (try parsePrimTypeTable(column.ty)) {
        .i1, .u8 => bytes[offset],
        .u64 => readU64LE(bytes, offset),
        else => return TableError.InvalidFormat,
    };
    return switch (raw) {
        0 => false,
        1 => true,
        else => TableError.InvalidFormat,
    };
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

fn compareI64(value: i64, op: U64CompareOp, expected: i64) bool {
    return switch (op) {
        .eq => value == expected,
        .ne => value != expected,
        .lt => value < expected,
        .le => value <= expected,
        .gt => value > expected,
        .ge => value >= expected,
    };
}

fn compareI32(value: i32, op: U64CompareOp, expected: i32) bool {
    return switch (op) {
        .eq => value == expected,
        .ne => value != expected,
        .lt => value < expected,
        .le => value <= expected,
        .gt => value > expected,
        .ge => value >= expected,
    };
}

fn compareI16(value: i16, op: U64CompareOp, expected: i16) bool {
    return switch (op) {
        .eq => value == expected,
        .ne => value != expected,
        .lt => value < expected,
        .le => value <= expected,
        .gt => value > expected,
        .ge => value >= expected,
    };
}

fn compareI8(value: i8, op: U64CompareOp, expected: i8) bool {
    return switch (op) {
        .eq => value == expected,
        .ne => value != expected,
        .lt => value < expected,
        .le => value <= expected,
        .gt => value > expected,
        .ge => value >= expected,
    };
}

fn compareF32(value: f32, op: U64CompareOp, expected: f32) TableError!bool {
    const normalized_value = try finiteF32(value);
    const normalized_expected = try finiteF32(expected);
    return switch (op) {
        .eq => normalized_value == normalized_expected,
        .ne => normalized_value != normalized_expected,
        .lt => normalized_value < normalized_expected,
        .le => normalized_value <= normalized_expected,
        .gt => normalized_value > normalized_expected,
        .ge => normalized_value >= normalized_expected,
    };
}

fn compareF64(value: f64, op: U64CompareOp, expected: f64) TableError!bool {
    const normalized_value = try finiteF64(value);
    const normalized_expected = try finiteF64(expected);
    return switch (op) {
        .eq => normalized_value == normalized_expected,
        .ne => normalized_value != normalized_expected,
        .lt => normalized_value < normalized_expected,
        .le => normalized_value <= normalized_expected,
        .gt => normalized_value > normalized_expected,
        .ge => normalized_value >= normalized_expected,
    };
}

fn snapshotIndexForU64Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotUniqueIndexForU64Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64") and index.unique and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForI64Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i64") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForF32Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "f32") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForF64Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "f64") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForU32Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u32") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForI32Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i32") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForU8Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u8") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForI8Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i8") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForU16Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u16") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForI16Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i16") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForU64PairColumns(snapshot: *const ReadSnapshot, column_index: usize, column_index2: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64_pair") and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 != null and
            index.column_index2.? == @as(u64, @intCast(column_index2)))
        {
            return index;
        }
    }
    return null;
}

fn snapshotIndexForU64I64PairColumns(snapshot: *const ReadSnapshot, column_index: usize, column_index2: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64_i64_pair") and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 != null and
            index.column_index2.? == @as(u64, @intCast(column_index2)))
        {
            return index;
        }
    }
    return null;
}

fn snapshotIndexForBlobEqColumnStore(snapshot: *const ReadSnapshot, column_index: usize, store_name: []const u8) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND) and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null and
            index.store_name != null and
            std.mem.eql(u8, index.store_name.?, store_name))
        {
            return index;
        }
    }
    return null;
}

fn snapshotIndexForBlobTokenColumnStore(snapshot: *const ReadSnapshot, column_index: usize, store_name: []const u8) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND) and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null and
            index.store_name != null and
            std.mem.eql(u8, index.store_name.?, store_name))
        {
            return index;
        }
    }
    return null;
}

fn snapshotIndexForBlobPrefixColumnStore(snapshot: *const ReadSnapshot, column_index: usize, store_name: []const u8) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND) and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null and
            index.store_name != null and
            std.mem.eql(u8, index.store_name.?, store_name))
        {
            return index;
        }
    }
    return null;
}

fn snapshotIndexForBlobContainsColumnStore(snapshot: *const ReadSnapshot, column_index: usize, store_name: []const u8) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND) and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null and
            index.store_name != null and
            std.mem.eql(u8, index.store_name.?, store_name))
        {
            return index;
        }
    }
    return null;
}

fn findU64InIndex(index: ReadIndexSnapshot, expected: u64) U64FindResult {
    var lo: usize = 0;
    var hi: usize = index.entries.len / INDEX_RECORD_BYTES;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const key = readIndexKey(index.entries, mid);
        if (key < expected) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    const n = index.entries.len / INDEX_RECORD_BYTES;
    if (lo < n and readIndexKey(index.entries, lo) == expected) {
        return .{ .found = true, .row_index = readIndexRow(index.entries, lo) };
    }
    return .{ .found = false, .row_index = 0 };
}

fn findI64InIndex(index: ReadIndexSnapshot, expected: i64) U64FindResult {
    return findU64InIndex(index, sortableI64Key(expected));
}

fn findI32InIndex(index: ReadIndexSnapshot, expected: i32) U64FindResult {
    return findU64InIndex(index, sortableI32Key(expected));
}

fn findI16InIndex(index: ReadIndexSnapshot, expected: i16) U64FindResult {
    return findU64InIndex(index, sortableI16Key(expected));
}

fn findI8InIndex(index: ReadIndexSnapshot, expected: i8) U64FindResult {
    return findU64InIndex(index, sortableI8Key(expected));
}

fn findF32InIndex(index: ReadIndexSnapshot, expected: f32) TableError!U64FindResult {
    return findU64InIndex(index, try sortableF32Key(expected));
}

fn findF64InIndex(index: ReadIndexSnapshot, expected: f64) TableError!U64FindResult {
    return findU64InIndex(index, try sortableF64Key(expected));
}

fn u64PairIndexEntryLessThanKey(index: ReadIndexSnapshot, entry_index: usize, key1: u64, key2: u64) bool {
    const entry_key1 = readU64PairIndexKey1(index.entries, entry_index);
    if (entry_key1 != key1) return entry_key1 < key1;
    return readU64PairIndexKey2(index.entries, entry_index) < key2;
}

fn u64PairIndexEntryLessThanOrEqualKey(index: ReadIndexSnapshot, entry_index: usize, key1: u64, key2: u64) bool {
    const entry_key1 = readU64PairIndexKey1(index.entries, entry_index);
    if (entry_key1 != key1) return entry_key1 < key1;
    return readU64PairIndexKey2(index.entries, entry_index) <= key2;
}

fn findU64PairInIndex(index: ReadIndexSnapshot, key1: u64, key2: u64) U64FindResult {
    var lo: usize = 0;
    var hi: usize = index.entries.len / U64_PAIR_INDEX_RECORD_BYTES;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (u64PairIndexEntryLessThanKey(index, mid, key1, key2)) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    const n = index.entries.len / U64_PAIR_INDEX_RECORD_BYTES;
    if (lo < n and readU64PairIndexKey1(index.entries, lo) == key1 and readU64PairIndexKey2(index.entries, lo) == key2) {
        return .{ .found = true, .row_index = readU64PairIndexRow(index.entries, lo) };
    }
    return .{ .found = false, .row_index = 0 };
}

fn lowerBoundU64PairIndex(index: ReadIndexSnapshot, key1: u64, key2: u64) usize {
    var lo: usize = 0;
    var hi: usize = index.entries.len / U64_PAIR_INDEX_RECORD_BYTES;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (u64PairIndexEntryLessThanKey(index, mid, key1, key2)) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn upperBoundU64PairIndex(index: ReadIndexSnapshot, key1: u64, key2: u64) usize {
    var lo: usize = 0;
    var hi: usize = index.entries.len / U64_PAIR_INDEX_RECORD_BYTES;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (u64PairIndexEntryLessThanOrEqualKey(index, mid, key1, key2)) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn lowerBoundU64Index(index: ReadIndexSnapshot, expected: u64) usize {
    var lo: usize = 0;
    var hi: usize = index.entries.len / INDEX_RECORD_BYTES;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (readIndexKey(index.entries, mid) < expected) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn upperBoundU64Index(index: ReadIndexSnapshot, expected: u64) usize {
    var lo: usize = 0;
    var hi: usize = index.entries.len / INDEX_RECORD_BYTES;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (readIndexKey(index.entries, mid) <= expected) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn requiredNullBitmapBytes(row_count: u64) TableError!usize {
    const required = row_count / 8 + if (row_count % 8 == 0) @as(u64, 0) else 1;
    if (required > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    return @intCast(required);
}

fn ensureNullBitmapRows(row_count: u64, null_bitmap: []const u8) TableError!void {
    if (null_bitmap.len < try requiredNullBitmapBytes(row_count)) return TableError.InvalidFormat;
}

fn nullBitmapRowIsNull(null_bitmap: []const u8, row_index: u64) bool {
    const byte_index: usize = @intCast(row_index / 8);
    const bit: u3 = @intCast(row_index & 7);
    const mask: u8 = @as(u8, 1) << bit;
    return (null_bitmap[byte_index] & mask) != 0;
}

fn copyRangeRowsWithNullBitmap(
    index: ReadIndexSnapshot,
    row_count: u64,
    start: usize,
    end: usize,
    null_bitmap: []const u8,
    want_null: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureNullBitmapRows(row_count, null_bitmap);
    var total: u64 = 0;
    var written: u64 = 0;
    const out_capacity: u64 = @intCast(out_rows.len);
    var i = start;
    while (i < end) : (i += 1) {
        const row = readIndexRow(index.entries, i);
        if (row >= row_count) return TableError.VerifyFailed;
        if (nullBitmapRowIsNull(null_bitmap, row) == want_null) {
            if (total >= offset and limit != 0 and written < limit and written < out_capacity) {
                out_rows[@intCast(written)] = row;
                written += 1;
            }
            total = std.math.add(u64, total, 1) catch return TableError.CursorOverflow;
        }
    }
    return .{ .written = written, .total = total };
}

const SnapshotRowValue = struct {
    bytes: []const u8,
    local_row: u64,
};

fn snapshotColumnBytesForRow(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64, stride: u32) TableError!SnapshotRowValue {
    if (row_index >= snapshot.row_count) return TableError.InvalidFormat;
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const segment_end = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        if (row_index < segment_end) {
            const bytes = segment.columns[column_index].bytes;
            const expected_len = try expectedColumnBytes(segment.rows, stride);
            if (bytes.len != expected_len) return TableError.VerifyFailed;
            return .{ .bytes = bytes, .local_row = row_index - row_base };
        }
        row_base = segment_end;
    }
    return TableError.InvalidFormat;
}

fn snapshotU64AtRow(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!u64 {
    const located = try snapshotColumnBytesForRow(snapshot, column_index, row_index, 8);
    const byte_offset: usize = @intCast(located.local_row * 8);
    return readU64LE(located.bytes, byte_offset);
}

fn snapshotI64AtRow(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!i64 {
    const located = try snapshotColumnBytesForRow(snapshot, column_index, row_index, 8);
    const byte_offset: usize = @intCast(located.local_row * 8);
    return readI64LE(located.bytes, byte_offset);
}

fn snapshotU32AtRow(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!u32 {
    const located = try snapshotColumnBytesForRow(snapshot, column_index, row_index, 4);
    const byte_offset: usize = @intCast(located.local_row * 4);
    return readU32LE(located.bytes, byte_offset);
}

fn snapshotI32AtRow(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!i32 {
    const located = try snapshotColumnBytesForRow(snapshot, column_index, row_index, 4);
    const byte_offset: usize = @intCast(located.local_row * 4);
    return readI32LE(located.bytes, byte_offset);
}

fn snapshotU8AtRow(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!u8 {
    const located = try snapshotColumnBytesForRow(snapshot, column_index, row_index, 1);
    const byte_offset: usize = @intCast(located.local_row);
    return located.bytes[byte_offset];
}

fn snapshotI8AtRow(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!i8 {
    const located = try snapshotColumnBytesForRow(snapshot, column_index, row_index, 1);
    const byte_offset: usize = @intCast(located.local_row);
    return readI8(located.bytes, byte_offset);
}

fn snapshotU16AtRow(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!u16 {
    const located = try snapshotColumnBytesForRow(snapshot, column_index, row_index, 2);
    const byte_offset: usize = @intCast(located.local_row * 2);
    return readU16LE(located.bytes, byte_offset);
}

fn snapshotI16AtRow(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!i16 {
    const located = try snapshotColumnBytesForRow(snapshot, column_index, row_index, 2);
    const byte_offset: usize = @intCast(located.local_row * 2);
    return readI16LE(located.bytes, byte_offset);
}

fn snapshotF32AtRow(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!f32 {
    const located = try snapshotColumnBytesForRow(snapshot, column_index, row_index, 4);
    const byte_offset: usize = @intCast(located.local_row * 4);
    return try finiteF32(readF32LE(located.bytes, byte_offset));
}

fn snapshotF64AtRow(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!f64 {
    const located = try snapshotColumnBytesForRow(snapshot, column_index, row_index, 8);
    const byte_offset: usize = @intCast(located.local_row * 8);
    return try finiteF64(readF64LE(located.bytes, byte_offset));
}

fn snapshotBoolAtRow(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!bool {
    const column = snapshot.columns[column_index];
    const located = try snapshotColumnBytesForRow(snapshot, column_index, row_index, column.stride);
    return try readBoolColumnValue(column, located.bytes, located.local_row);
}

fn copyCandidateRowsByPredicate(
    in_rows: []const u64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
    context: anytype,
    comptime matches: fn (@TypeOf(context), u64) TableError!bool,
) TableError!U64RangeResult {
    var total: u64 = 0;
    var written: u64 = 0;
    const out_capacity: u64 = @intCast(out_rows.len);
    for (in_rows) |row| {
        if (try matches(context, row)) {
            if (total >= offset and limit != 0 and written < limit and written < out_capacity) {
                out_rows[@intCast(written)] = row;
                written += 1;
            }
            total = std.math.add(u64, total, 1) catch return TableError.CursorOverflow;
        }
    }
    return .{ .written = written, .total = total };
}

fn validateSnapshotRows(snapshot: *const ReadSnapshot, rows: []const u64) TableError!void {
    for (rows) |row| {
        if (row >= snapshot.row_count) return TableError.InvalidFormat;
    }
}

fn u64LessThan(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

fn sortedRowsContain(rows: []const u64, needle: u64) bool {
    var lo: usize = 0;
    var hi: usize = rows.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (rows[mid] < needle) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo < rows.len and rows[lo] == needle;
}

fn appendPagedRow(row: u64, offset: u64, limit: u64, out_rows: []u64, total: *u64, written: *u64) TableError!void {
    const out_capacity: u64 = @intCast(out_rows.len);
    if (total.* >= offset and limit != 0 and written.* < limit and written.* < out_capacity) {
        out_rows[@intCast(written.*)] = row;
        written.* += 1;
    }
    total.* = std.math.add(u64, total.*, 1) catch return TableError.CursorOverflow;
}

pub fn snapshotIntersectRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    left_rows: []const u64,
    right_rows: []const u64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try validateSnapshotRows(snapshot, left_rows);
    try validateSnapshotRows(snapshot, right_rows);
    if (left_rows.len == 0 or right_rows.len == 0) return .{ .written = 0, .total = 0 };

    const right_sorted = try allocator.dupe(u64, right_rows);
    defer allocator.free(right_sorted);
    std.sort.block(u64, right_sorted, {}, u64LessThan);

    var total: u64 = 0;
    var written: u64 = 0;
    const out_capacity: u64 = @intCast(out_rows.len);
    for (left_rows) |row| {
        if (sortedRowsContain(right_sorted, row)) {
            if (total >= offset and limit != 0 and written < limit and written < out_capacity) {
                out_rows[@intCast(written)] = row;
                written += 1;
            }
            total = std.math.add(u64, total, 1) catch return TableError.CursorOverflow;
        }
    }
    return .{ .written = written, .total = total };
}

pub fn snapshotUnionRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    left_rows: []const u64,
    right_rows: []const u64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try validateSnapshotRows(snapshot, left_rows);
    try validateSnapshotRows(snapshot, right_rows);

    const left_copy = try allocator.dupe(u64, left_rows);
    defer allocator.free(left_copy);
    const right_copy = try allocator.dupe(u64, right_rows);
    defer allocator.free(right_copy);

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    var total: u64 = 0;
    var written: u64 = 0;
    for (left_copy) |row| {
        const entry = try seen.getOrPut(row);
        if (entry.found_existing) continue;
        try appendPagedRow(row, offset, limit, out_rows, &total, &written);
    }
    for (right_copy) |row| {
        const entry = try seen.getOrPut(row);
        if (entry.found_existing) continue;
        try appendPagedRow(row, offset, limit, out_rows, &total, &written);
    }
    return .{ .written = written, .total = total };
}

pub fn snapshotExceptRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    left_rows: []const u64,
    right_rows: []const u64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try validateSnapshotRows(snapshot, left_rows);
    try validateSnapshotRows(snapshot, right_rows);

    const left_copy = try allocator.dupe(u64, left_rows);
    defer allocator.free(left_copy);
    const right_copy = try allocator.dupe(u64, right_rows);
    defer allocator.free(right_copy);

    var excluded = std.AutoHashMap(u64, void).init(allocator);
    defer excluded.deinit();
    for (right_copy) |row| {
        try excluded.put(row, {});
    }

    var emitted = std.AutoHashMap(u64, void).init(allocator);
    defer emitted.deinit();

    var total: u64 = 0;
    var written: u64 = 0;
    for (left_copy) |row| {
        if (excluded.contains(row)) continue;
        const entry = try emitted.getOrPut(row);
        if (entry.found_existing) continue;
        try appendPagedRow(row, offset, limit, out_rows, &total, &written);
    }
    return .{ .written = written, .total = total };
}

const BlobCandidateFilterMode = enum {
    eq,
    contains,
    token,
    prefix,
};

fn blobCandidateValueMatches(value: []const u8, needle: []const u8, mode: BlobCandidateFilterMode) bool {
    return switch (mode) {
        .eq => std.mem.eql(u8, value, needle),
        .contains => std.mem.indexOf(u8, value, needle) != null,
        .token => blobValueHasToken(value, needle),
        .prefix => blobValueHasTokenPrefix(value, needle),
    };
}

fn snapshotFilterRowsBlobMode(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    store_name: []const u8,
    needle: []const u8,
    mode: BlobCandidateFilterMode,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BlobFilterResult {
    try ensureSnapshotBlobHandleColumn(snapshot, column_index);
    try validateBlobStoreName(store_name);
    try validateSnapshotRows(snapshot, in_rows);
    const blob_idx = snapshotFindBlobStoreIndex(snapshot, store_name) orelse return .{ .written = 0, .total = 0 };

    const refs = try buildBlobValueRefs(allocator, snapshot.blobs[blob_idx].bytes);
    defer allocator.free(refs);

    var total: u64 = 0;
    var written: u64 = 0;
    for (in_rows) |row| {
        const blob_id = try snapshotBlobHandleAtRow(snapshot, column_index, row);
        const value_ref = blobRefForId(refs, blob_id) orelse continue;
        if (!blobCandidateValueMatches(value_ref.value, needle, mode)) continue;
        try appendPagedRow(row, offset, limit, out_rows, &total, &written);
    }
    return .{ .written = written, .total = total };
}

pub fn snapshotFilterRowsBlobEq(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    store_name: []const u8,
    needle: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BlobFilterResult {
    try validateBlobValue(needle);
    return snapshotFilterRowsBlobMode(allocator, snapshot, column_index, in_rows, store_name, needle, .eq, offset, limit, out_rows);
}

pub fn snapshotFilterRowsBlobContains(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    store_name: []const u8,
    needle: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BlobFilterResult {
    try validateBlobValue(needle);
    return snapshotFilterRowsBlobMode(allocator, snapshot, column_index, in_rows, store_name, needle, .contains, offset, limit, out_rows);
}

pub fn snapshotFilterRowsBlobToken(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    store_name: []const u8,
    token: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BlobFilterResult {
    try validateBlobToken(token);
    return snapshotFilterRowsBlobMode(allocator, snapshot, column_index, in_rows, store_name, token, .token, offset, limit, out_rows);
}

pub fn snapshotFilterRowsBlobPrefix(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    store_name: []const u8,
    prefix: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BlobFilterResult {
    try validateBlobPrefix(prefix);
    return snapshotFilterRowsBlobMode(allocator, snapshot, column_index, in_rows, store_name, prefix, .prefix, offset, limit, out_rows);
}

const FilterRowsU64RangeContext = struct {
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: u64,
    max_value: u64,
};

fn matchesRowsU64Range(context: FilterRowsU64RangeContext, row: u64) TableError!bool {
    const value = try snapshotU64AtRow(context.snapshot, context.column_index, row);
    return value >= context.min_value and value <= context.max_value;
}

const FilterRowsI64RangeContext = struct {
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: i64,
    max_value: i64,
};

fn matchesRowsI64Range(context: FilterRowsI64RangeContext, row: u64) TableError!bool {
    const value = try snapshotI64AtRow(context.snapshot, context.column_index, row);
    return value >= context.min_value and value <= context.max_value;
}

const FilterRowsU32RangeContext = struct {
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: u32,
    max_value: u32,
};

fn matchesRowsU32Range(context: FilterRowsU32RangeContext, row: u64) TableError!bool {
    const value = try snapshotU32AtRow(context.snapshot, context.column_index, row);
    return value >= context.min_value and value <= context.max_value;
}

const FilterRowsI32RangeContext = struct {
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: i32,
    max_value: i32,
};

fn matchesRowsI32Range(context: FilterRowsI32RangeContext, row: u64) TableError!bool {
    const value = try snapshotI32AtRow(context.snapshot, context.column_index, row);
    return value >= context.min_value and value <= context.max_value;
}

const FilterRowsU8RangeContext = struct {
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: u8,
    max_value: u8,
};

fn matchesRowsU8Range(context: FilterRowsU8RangeContext, row: u64) TableError!bool {
    const value = try snapshotU8AtRow(context.snapshot, context.column_index, row);
    return value >= context.min_value and value <= context.max_value;
}

const FilterRowsI8RangeContext = struct {
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: i8,
    max_value: i8,
};

fn matchesRowsI8Range(context: FilterRowsI8RangeContext, row: u64) TableError!bool {
    const value = try snapshotI8AtRow(context.snapshot, context.column_index, row);
    return value >= context.min_value and value <= context.max_value;
}

const FilterRowsU16RangeContext = struct {
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: u16,
    max_value: u16,
};

fn matchesRowsU16Range(context: FilterRowsU16RangeContext, row: u64) TableError!bool {
    const value = try snapshotU16AtRow(context.snapshot, context.column_index, row);
    return value >= context.min_value and value <= context.max_value;
}

const FilterRowsI16RangeContext = struct {
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: i16,
    max_value: i16,
};

fn matchesRowsI16Range(context: FilterRowsI16RangeContext, row: u64) TableError!bool {
    const value = try snapshotI16AtRow(context.snapshot, context.column_index, row);
    return value >= context.min_value and value <= context.max_value;
}

const FilterRowsF32RangeContext = struct {
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: f32,
    max_value: f32,
};

fn matchesRowsF32Range(context: FilterRowsF32RangeContext, row: u64) TableError!bool {
    const value = try snapshotF32AtRow(context.snapshot, context.column_index, row);
    return value >= context.min_value and value <= context.max_value;
}

const FilterRowsF64RangeContext = struct {
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: f64,
    max_value: f64,
};

fn matchesRowsF64Range(context: FilterRowsF64RangeContext, row: u64) TableError!bool {
    const value = try snapshotF64AtRow(context.snapshot, context.column_index, row);
    return value >= context.min_value and value <= context.max_value;
}

const FilterRowsBoolContext = struct {
    snapshot: *const ReadSnapshot,
    column_index: usize,
    expected: bool,
};

fn matchesRowsBool(context: FilterRowsBoolContext, row: u64) TableError!bool {
    return (try snapshotBoolAtRow(context.snapshot, context.column_index, row)) == context.expected;
}

const SortRowsContext = struct {
    descending: bool,
};

fn SortRowsEntry(comptime Key: type) type {
    return struct {
        row: u64,
        key: Key,
        input_index: usize,
    };
}

fn sortRowsLessThan(comptime Key: type) fn (SortRowsContext, SortRowsEntry(Key), SortRowsEntry(Key)) bool {
    return struct {
        fn lessThan(context: SortRowsContext, lhs: SortRowsEntry(Key), rhs: SortRowsEntry(Key)) bool {
            if (lhs.key != rhs.key) {
                return if (context.descending) lhs.key > rhs.key else lhs.key < rhs.key;
            }
            return lhs.input_index < rhs.input_index;
        }
    }.lessThan;
}

fn copySortedRowsPage(entries: anytype, offset: u64, limit: u64, out_rows: []u64) U64RangeResult {
    const total: u64 = @intCast(entries.len);
    if (offset >= total or limit == 0 or out_rows.len == 0) {
        return .{ .written = 0, .total = total };
    }

    const page_start: usize = @intCast(offset);
    const available = entries.len - page_start;
    const capped_by_limit: usize = if (limit > @as(u64, @intCast(std.math.maxInt(usize))))
        available
    else
        @min(available, @as(usize, @intCast(limit)));
    const write_count = @min(capped_by_limit, out_rows.len);

    var i: usize = 0;
    while (i < write_count) : (i += 1) {
        out_rows[i] = entries[page_start + i].row;
    }
    return .{ .written = @intCast(write_count), .total = total };
}

fn snapshotSortRowsBy(
    comptime Key: type,
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    descending: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
    comptime readKey: fn (*const ReadSnapshot, usize, u64) TableError!Key,
) TableError!U64RangeResult {
    if (in_rows.len == 0) return .{ .written = 0, .total = 0 };

    const Entry = SortRowsEntry(Key);
    const entries = try allocator.alloc(Entry, in_rows.len);
    defer allocator.free(entries);

    for (in_rows, 0..) |row, idx| {
        entries[idx] = .{
            .row = row,
            .key = try readKey(snapshot, column_index, row),
            .input_index = idx,
        };
    }

    std.sort.block(Entry, entries, SortRowsContext{ .descending = descending }, sortRowsLessThan(Key));
    return copySortedRowsPage(entries, offset, limit, out_rows);
}

fn countU64CmpInIndex(index: ReadIndexSnapshot, op: U64CompareOp, expected: u64) u64 {
    const n = index.entries.len / INDEX_RECORD_BYTES;
    const lower = lowerBoundU64Index(index, expected);
    const upper = upperBoundU64Index(index, expected);
    const equal_count = upper - lower;
    return switch (op) {
        .eq => @intCast(equal_count),
        .ne => @intCast(n - equal_count),
        .lt => @intCast(lower),
        .le => @intCast(upper),
        .gt => @intCast(n - upper),
        .ge => @intCast(n - lower),
    };
}

fn countI64CmpInIndex(index: ReadIndexSnapshot, op: U64CompareOp, expected: i64) u64 {
    return countU64CmpInIndex(index, op, sortableI64Key(expected));
}

fn countI32CmpInIndex(index: ReadIndexSnapshot, op: U64CompareOp, expected: i32) u64 {
    return countU64CmpInIndex(index, op, sortableI32Key(expected));
}

fn countI16CmpInIndex(index: ReadIndexSnapshot, op: U64CompareOp, expected: i16) u64 {
    return countU64CmpInIndex(index, op, sortableI16Key(expected));
}

fn countI8CmpInIndex(index: ReadIndexSnapshot, op: U64CompareOp, expected: i8) u64 {
    return countU64CmpInIndex(index, op, sortableI8Key(expected));
}

fn countF32CmpInIndex(index: ReadIndexSnapshot, op: U64CompareOp, expected: f32) TableError!u64 {
    return countU64CmpInIndex(index, op, try sortableF32Key(expected));
}

fn countF64CmpInIndex(index: ReadIndexSnapshot, op: U64CompareOp, expected: f64) TableError!u64 {
    return countU64CmpInIndex(index, op, try sortableF64Key(expected));
}

fn snapshotRowBytes(snapshot: *const ReadSnapshot) TableError!usize {
    var total: u64 = 0;
    for (snapshot.columns) |column| {
        total = std.math.add(u64, total, column.stride) catch return TableError.CursorOverflow;
    }
    if (total > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    return @intCast(total);
}

pub fn snapshotInfo(snapshot: *const ReadSnapshot) TableError!SnapshotInfo {
    const row_bytes = try snapshotRowBytes(snapshot);
    return .{
        .row_count = snapshot.row_count,
        .column_count = @intCast(snapshot.columns.len),
        .row_bytes = @intCast(row_bytes),
        .epoch = snapshot.epoch,
    };
}

pub fn snapshotColumnInfo(snapshot: *const ReadSnapshot, column_index: usize) TableError!ColumnInfo {
    if (column_index >= snapshot.columns.len) return TableError.InvalidFormat;
    const column = snapshot.columns[column_index];
    const ty = try parsePrimTypeTable(column.ty);
    return .{
        .stride = column.stride,
        .type_code = @intFromEnum(ty),
        .name_len = column.name.len,
        .type_name_len = column.ty.len,
    };
}

pub fn snapshotColumnLogicalInfo(snapshot: *const ReadSnapshot, column_index: usize) TableError!ColumnLogicalInfo {
    if (column_index >= snapshot.columns.len) return TableError.InvalidFormat;
    const column = snapshot.columns[column_index];
    return .{
        .logical_type = column.logical_type,
        .logical_scale = column.logical_scale,
        .nullable = if (column.nullable) 1 else 0,
    };
}

fn snapshotCopyRow(snapshot: *const ReadSnapshot, row_index: u64, out_row: []u8) TableError!void {
    if (row_index >= snapshot.row_count) return TableError.InvalidFormat;
    const row_bytes = try snapshotRowBytes(snapshot);
    if (out_row.len != row_bytes) return TableError.InvalidFormat;

    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const segment_end = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        if (row_index < segment_end) {
            const local_row = row_index - row_base;
            var out_offset: usize = 0;
            for (snapshot.columns, 0..) |column, column_idx| {
                const bytes = segment.columns[column_idx].bytes;
                const expected_len = try expectedColumnBytes(segment.rows, column.stride);
                if (bytes.len != expected_len) return TableError.VerifyFailed;
                const stride: usize = @intCast(column.stride);
                const source_offset_u64 = std.math.mul(u64, local_row, @as(u64, column.stride)) catch return TableError.CursorOverflow;
                if (source_offset_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
                const source_offset: usize = @intCast(source_offset_u64);
                @memcpy(out_row[out_offset .. out_offset + stride], bytes[source_offset .. source_offset + stride]);
                out_offset += stride;
            }
            if (out_offset != out_row.len) return TableError.InvalidFormat;
            return;
        }
        row_base = segment_end;
    }
    return TableError.InvalidFormat;
}

pub fn snapshotGetRowU64Key(snapshot: *const ReadSnapshot, column_index: usize, expected: u64, out_row: []u8) TableError!void {
    try ensureSnapshotU64Column(snapshot, column_index);
    const index = snapshotUniqueIndexForU64Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    const found = findU64InIndex(index, expected);
    if (!found.found) return TableError.NotFound;
    try snapshotCopyRow(snapshot, found.row_index, out_row);
}

pub fn snapshotGetRow(snapshot: *const ReadSnapshot, row_index: u64, out_row: []u8) TableError!void {
    try snapshotCopyRow(snapshot, row_index, out_row);
}

fn snapshotProjectedRowBytes(snapshot: *const ReadSnapshot, column_indices: []const u64) TableError!usize {
    if (column_indices.len == 0) return TableError.InvalidFormat;
    var total: u64 = 0;
    for (column_indices) |column_index_u64| {
        if (column_index_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.InvalidFormat;
        const column_index: usize = @intCast(column_index_u64);
        if (column_index >= snapshot.columns.len) return TableError.InvalidFormat;
        total = std.math.add(u64, total, snapshot.columns[column_index].stride) catch return TableError.CursorOverflow;
    }
    if (total > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    return @intCast(total);
}

pub fn snapshotProjectRowsRequiredBytes(
    snapshot: *const ReadSnapshot,
    row_count: u64,
    column_indices: []const u64,
) TableError!u64 {
    const projected_row_bytes = try snapshotProjectedRowBytes(snapshot, column_indices);
    return std.math.mul(u64, row_count, @as(u64, @intCast(projected_row_bytes))) catch TableError.CursorOverflow;
}

pub fn snapshotProjectRows(
    snapshot: *const ReadSnapshot,
    row_indices: []const u64,
    column_indices: []const u64,
    out_bytes: []u8,
) TableError!ProjectRowsResult {
    const projected_row_bytes = try snapshotProjectedRowBytes(snapshot, column_indices);
    const required_bytes = std.math.mul(u64, @as(u64, @intCast(row_indices.len)), @as(u64, @intCast(projected_row_bytes))) catch return TableError.CursorOverflow;
    if (required_bytes > @as(u64, @intCast(out_bytes.len))) return TableError.CursorOverflow;

    var out_offset: usize = 0;
    for (row_indices) |row_index| {
        if (row_index >= snapshot.row_count) return TableError.InvalidFormat;
        var row_base: u64 = 0;
        var copied = false;
        for (snapshot.segments) |segment| {
            const segment_end = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
            if (row_index < segment_end) {
                const local_row = row_index - row_base;
                for (column_indices) |column_index_u64| {
                    const column_index: usize = @intCast(column_index_u64);
                    const column = snapshot.columns[column_index];
                    const bytes = segment.columns[column_index].bytes;
                    const expected_len = try expectedColumnBytes(segment.rows, column.stride);
                    if (bytes.len != expected_len) return TableError.VerifyFailed;
                    const stride: usize = @intCast(column.stride);
                    const source_offset_u64 = std.math.mul(u64, local_row, @as(u64, column.stride)) catch return TableError.CursorOverflow;
                    if (source_offset_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
                    const source_offset: usize = @intCast(source_offset_u64);
                    @memcpy(out_bytes[out_offset .. out_offset + stride], bytes[source_offset .. source_offset + stride]);
                    out_offset += stride;
                }
                copied = true;
                break;
            }
            row_base = segment_end;
        }
        if (!copied) return TableError.InvalidFormat;
    }

    return .{ .written_rows = @intCast(row_indices.len), .required_bytes = required_bytes };
}

fn findUniqueU64KeyRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    expected: u64,
) TableError!U64FindResult {
    try ensureU64Column(meta, column_index);
    var selected: ?IndexMeta = null;
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64") and index.unique and index.column_index == @as(u64, @intCast(column_index))) {
            selected = index;
            break;
        }
    }
    const index = selected orelse return TableError.InvalidFormat;
    if (index.bytes != @as(u64, @intCast(try expectedIndexBytes(meta.row_count)))) return TableError.VerifyFailed;

    const path = try activePath(allocator, root_dir, index.path);
    defer allocator.free(path);
    const bytes = try readFileAlloc(allocator, path, 1 << 30);
    defer allocator.free(bytes);
    if (bytes.len != index.bytes) return TableError.VerifyFailed;
    const actual_hash = hashBytes(bytes);
    const actual_hex = std.fmt.bytesToHex(actual_hash, .lower);
    if (!std.mem.eql(u8, actual_hex[0..], index.sha256)) return TableError.VerifyFailed;
    try validateIndexBytesShape(bytes, meta.row_count, true);

    return findU64InIndex(.{
        .kind = "u64",
        .column_index = @intCast(column_index),
        .unique = true,
        .entries = bytes,
    }, expected);
}

fn findUniqueU64PairKeyRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    column_index2: usize,
    key1: u64,
    key2: u64,
) TableError!U64FindResult {
    try ensureU64PairColumns(meta, column_index, column_index2);
    var selected: ?IndexMeta = null;
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64_pair") and
            index.unique and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 != null and
            index.column_index2.? == @as(u64, @intCast(column_index2)))
        {
            selected = index;
            break;
        }
    }
    const index = selected orelse return TableError.InvalidFormat;
    if (index.bytes != @as(u64, @intCast(try expectedU64PairIndexBytes(meta.row_count)))) return TableError.VerifyFailed;

    const path = try activePath(allocator, root_dir, index.path);
    defer allocator.free(path);
    const bytes = try readFileAlloc(allocator, path, 1 << 30);
    defer allocator.free(bytes);
    if (bytes.len != index.bytes) return TableError.VerifyFailed;
    const actual_hash = hashBytes(bytes);
    const actual_hex = std.fmt.bytesToHex(actual_hash, .lower);
    if (!std.mem.eql(u8, actual_hex[0..], index.sha256)) return TableError.VerifyFailed;
    try validateU64PairIndexBytesShape(bytes, meta.row_count, true);

    return findU64PairInIndex(.{
        .kind = "u64_pair",
        .column_index = @intCast(column_index),
        .column_index2 = @intCast(column_index2),
        .unique = true,
        .entries = bytes,
    }, key1, key2);
}

fn buildColumnBuffersWithoutRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    delete_row_index: u64,
) TableError![]std.ArrayList(u8) {
    const buffers = try allocator.alloc(std.ArrayList(u8), meta.columns.len);
    errdefer allocator.free(buffers);
    for (buffers) |*buf| buf.* = std.ArrayList(u8).init(allocator);
    errdefer {
        for (buffers) |*buf| buf.deinit();
    }

    for (meta.columns, 0..) |column, col_idx| {
        var row_base: u64 = 0;
        for (meta.segments) |segment| {
            const file_meta = segment.files[col_idx];
            const path = try activePath(allocator, root_dir, file_meta.path);
            defer allocator.free(path);
            const bytes = try readFileAlloc(allocator, path, 1 << 30);
            defer allocator.free(bytes);
            const expected_len = try expectedColumnBytes(segment.rows, column.stride);
            if (bytes.len != expected_len or file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;

            const stride: usize = @intCast(column.stride);
            var local_row: u64 = 0;
            while (local_row < segment.rows) : (local_row += 1) {
                if (row_base + local_row == delete_row_index) continue;
                const offset_u64 = std.math.mul(u64, local_row, @as(u64, column.stride)) catch return TableError.CursorOverflow;
                const offset: usize = @intCast(offset_u64);
                try buffers[col_idx].appendSlice(bytes[offset .. offset + stride]);
            }
            row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        }
        if (row_base != meta.row_count) return TableError.VerifyFailed;
    }

    return buffers;
}

fn buildColumnBuffersReplacingRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    replace_row_index: u64,
    row_bytes: []const u8,
) TableError![]std.ArrayList(u8) {
    if (row_bytes.len != try fixedRowBytes(meta)) return TableError.InvalidFormat;
    const buffers = try allocator.alloc(std.ArrayList(u8), meta.columns.len);
    errdefer allocator.free(buffers);
    for (buffers) |*buf| buf.* = std.ArrayList(u8).init(allocator);
    errdefer {
        for (buffers) |*buf| buf.deinit();
    }

    var row_offset: usize = 0;
    for (meta.columns, 0..) |column, col_idx| {
        const stride: usize = @intCast(column.stride);
        const next_row_offset = std.math.add(usize, row_offset, stride) catch return TableError.CursorOverflow;
        if (next_row_offset > row_bytes.len) return TableError.InvalidFormat;
        const replacement = row_bytes[row_offset..next_row_offset];

        var row_base: u64 = 0;
        for (meta.segments) |segment| {
            const file_meta = segment.files[col_idx];
            const path = try activePath(allocator, root_dir, file_meta.path);
            defer allocator.free(path);
            const bytes = try readFileAlloc(allocator, path, 1 << 30);
            defer allocator.free(bytes);
            const expected_len = try expectedColumnBytes(segment.rows, column.stride);
            if (bytes.len != expected_len or file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;

            var local_row: u64 = 0;
            while (local_row < segment.rows) : (local_row += 1) {
                const global_row = std.math.add(u64, row_base, local_row) catch return TableError.CursorOverflow;
                if (global_row == replace_row_index) {
                    try buffers[col_idx].appendSlice(replacement);
                    continue;
                }
                const offset_u64 = std.math.mul(u64, local_row, @as(u64, column.stride)) catch return TableError.CursorOverflow;
                const offset: usize = @intCast(offset_u64);
                try buffers[col_idx].appendSlice(bytes[offset .. offset + stride]);
            }
            row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        }
        if (row_base != meta.row_count) return TableError.VerifyFailed;
        row_offset = next_row_offset;
    }
    if (row_offset != row_bytes.len) return TableError.InvalidFormat;

    return buffers;
}

fn replaceRowAtIndex(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    meta: *TableMeta,
    row_index: u64,
    row_bytes: []const u8,
) TableError!TableInfo {
    if (row_index >= meta.row_count) return TableError.InvalidFormat;
    const buffers = try buildColumnBuffersReplacingRow(allocator, root_dir, meta.*, row_index, row_bytes);
    defer {
        for (buffers) |*buf| buf.deinit();
        allocator.free(buffers);
    }

    const new_segments = try allocator.alloc(SegmentMeta, 1);
    var new_files: ?[]FileMeta = null;
    var assigned_segments = false;
    errdefer if (!assigned_segments) {
        if (new_files) |files| freeFileMetas(allocator, files);
        allocator.free(new_segments);
    };

    const files = try writeSegmentFiles(allocator, root_dir, table_name, meta.next_segment_id, buffers);
    new_files = files;
    new_segments[0] = .{
        .id = meta.next_segment_id,
        .rows = meta.row_count,
        .files = files,
    };
    new_files = null;
    meta.next_segment_id += 1;

    const old_segments = meta.segments;
    meta.segments = new_segments;
    assigned_segments = true;
    freeSegmentMetas(allocator, old_segments);
    meta.epoch += 1;
    try rebuildIndexes(allocator, root_dir, meta);
    try writeMeta(allocator, root_dir, table_name, meta.*);
    return tableInfo(meta.*);
}

fn deleteRowAtIndex(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    meta: *TableMeta,
    row_index: u64,
) TableError!TableInfo {
    if (row_index >= meta.row_count) return TableError.InvalidFormat;
    const next_row_count = meta.row_count - 1;
    const buffers = try buildColumnBuffersWithoutRow(allocator, root_dir, meta.*, row_index);
    defer {
        for (buffers) |*buf| buf.deinit();
        allocator.free(buffers);
    }

    const new_segments = try allocator.alloc(SegmentMeta, if (next_row_count > 0) 1 else 0);
    var new_files: ?[]FileMeta = null;
    var assigned_segments = false;
    errdefer if (!assigned_segments) {
        if (new_files) |files| freeFileMetas(allocator, files);
        allocator.free(new_segments);
    };
    if (next_row_count > 0) {
        const files = try writeSegmentFiles(allocator, root_dir, table_name, meta.next_segment_id, buffers);
        new_files = files;
        new_segments[0] = .{
            .id = meta.next_segment_id,
            .rows = next_row_count,
            .files = files,
        };
        new_files = null;
        meta.next_segment_id += 1;
    }

    const old_segments = meta.segments;
    meta.segments = new_segments;
    assigned_segments = true;
    freeSegmentMetas(allocator, old_segments);
    meta.row_count = next_row_count;
    meta.epoch += 1;
    try rebuildIndexes(allocator, root_dir, meta);
    try writeMeta(allocator, root_dir, table_name, meta.*);
    return tableInfo(meta.*);
}

pub fn deleteU64Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: u64,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadActiveMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const found = try findUniqueU64KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try deleteRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index);
}

pub fn deleteU64PairKey(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    column_index2: usize,
    key1: u64,
    key2: u64,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadActiveMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const found = try findUniqueU64PairKeyRow(allocator, root_dir, owned, column_index, column_index2, key1, key2);
    if (!found.found) return TableError.NotFound;
    return try deleteRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index);
}

pub fn updateRawRowU64Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: u64,
    row_bytes: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadActiveMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowU64KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueU64KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try replaceRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index, row_bytes);
}

pub fn updateRawRowU64PairKey(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    column_index2: usize,
    key1: u64,
    key2: u64,
    row_bytes: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadActiveMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowU64PairKeyValue(owned, column_index, column_index2, row_bytes);
    if (key_value.key1 != key1 or key_value.key2 != key2) return TableError.InvalidFormat;

    const found = try findUniqueU64PairKeyRow(allocator, root_dir, owned, column_index, column_index2, key1, key2);
    if (!found.found) return TableError.NotFound;
    return try replaceRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index, row_bytes);
}

pub fn upsertRawRowU64Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: u64,
    row_bytes: []const u8,
) TableError!UpsertResult {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadActiveMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowU64KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueU64KeyRow(allocator, root_dir, owned, column_index, expected);
    if (found.found) {
        const info = try replaceRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index, row_bytes);
        return .{ .info = info, .inserted = false };
    }

    const total_rows = std.math.add(u64, owned.row_count, 1) catch return TableError.CursorOverflow;
    if (total_rows > owned.max_rows) return TableError.CursorOverflow;
    const buffers = try buildSingleRowColumnBuffers(allocator, owned, row_bytes);
    defer {
        for (buffers) |*buf| buf.deinit();
        allocator.free(buffers);
    }

    try appendSegmentToMeta(allocator, root_dir, table_name, &owned, buffers, 1);
    try rebuildIndexes(allocator, root_dir, &owned);
    try writeMeta(allocator, root_dir, table_name, owned);
    return .{ .info = tableInfo(owned), .inserted = true };
}

pub fn upsertRawRowU64PairKey(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    column_index2: usize,
    key1: u64,
    key2: u64,
    row_bytes: []const u8,
) TableError!UpsertResult {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadActiveMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowU64PairKeyValue(owned, column_index, column_index2, row_bytes);
    if (key_value.key1 != key1 or key_value.key2 != key2) return TableError.InvalidFormat;

    const found = try findUniqueU64PairKeyRow(allocator, root_dir, owned, column_index, column_index2, key1, key2);
    if (found.found) {
        const info = try replaceRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index, row_bytes);
        return .{ .info = info, .inserted = false };
    }

    const total_rows = std.math.add(u64, owned.row_count, 1) catch return TableError.CursorOverflow;
    if (total_rows > owned.max_rows) return TableError.CursorOverflow;
    const buffers = try buildSingleRowColumnBuffers(allocator, owned, row_bytes);
    defer {
        for (buffers) |*buf| buf.deinit();
        allocator.free(buffers);
    }

    try appendSegmentToMeta(allocator, root_dir, table_name, &owned, buffers, 1);
    try rebuildIndexes(allocator, root_dir, &owned);
    try writeMeta(allocator, root_dir, table_name, owned);
    return .{ .info = tableInfo(owned), .inserted = true };
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

pub fn snapshotStatsRowsU64(snapshot: *const ReadSnapshot, column_index: usize, row_indices: []const u64) TableError!U64RowsStats {
    try ensureSnapshotU64Column(snapshot, column_index);
    var stats = U64RowsStats{ .count = 0, .sum = 0, .min = 0, .max = 0 };
    for (row_indices) |row_index| {
        const value = try snapshotU64AtRow(snapshot, column_index, row_index);
        if (stats.count == 0) {
            stats.min = value;
            stats.max = value;
        } else {
            stats.min = @min(stats.min, value);
            stats.max = @max(stats.max, value);
        }
        stats.sum = std.math.add(u64, stats.sum, value) catch return TableError.CursorOverflow;
        stats.count = std.math.add(u64, stats.count, 1) catch return TableError.CursorOverflow;
    }
    return stats;
}

pub fn snapshotStatsRowsI64(snapshot: *const ReadSnapshot, column_index: usize, row_indices: []const u64) TableError!I64RowsStats {
    try ensureSnapshotI64Column(snapshot, column_index);
    var stats = I64RowsStats{ .count = 0, .sum = 0, .min = 0, .max = 0 };
    for (row_indices) |row_index| {
        const value = try snapshotI64AtRow(snapshot, column_index, row_index);
        if (stats.count == 0) {
            stats.min = value;
            stats.max = value;
        } else {
            stats.min = @min(stats.min, value);
            stats.max = @max(stats.max, value);
        }
        stats.sum = std.math.add(i64, stats.sum, value) catch return TableError.CursorOverflow;
        stats.count = std.math.add(u64, stats.count, 1) catch return TableError.CursorOverflow;
    }
    return stats;
}

pub fn snapshotCountU64Cmp(snapshot: *const ReadSnapshot, column_index: usize, op: U64CompareOp, expected: u64) TableError!u64 {
    try ensureSnapshotU64Column(snapshot, column_index);
    if (snapshotIndexForU64Column(snapshot, column_index)) |index| {
        return countU64CmpInIndex(index, op, expected);
    }
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
    if (snapshotIndexForU64Column(snapshot, column_index)) |index| {
        return findU64InIndex(index, expected);
    }
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

pub fn snapshotCountI64Cmp(snapshot: *const ReadSnapshot, column_index: usize, op: U64CompareOp, expected: i64) TableError!u64 {
    try ensureSnapshotI64Column(snapshot, column_index);
    if (snapshotIndexForI64Column(snapshot, column_index)) |index| {
        return countI64CmpInIndex(index, op, expected);
    }
    var count: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            if (compareI64(readI64LE(bytes, byte_offset), op, expected)) count += 1;
        }
    }
    return count;
}

pub fn snapshotFindI64(snapshot: *const ReadSnapshot, column_index: usize, expected: i64) TableError!U64FindResult {
    try ensureSnapshotI64Column(snapshot, column_index);
    if (snapshotIndexForI64Column(snapshot, column_index)) |index| {
        return findI64InIndex(index, expected);
    }
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            if (readI64LE(bytes, byte_offset) == expected) {
                return .{ .found = true, .row_index = row_base + i };
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .found = false, .row_index = 0 };
}

pub fn snapshotCountU32Cmp(snapshot: *const ReadSnapshot, column_index: usize, op: U64CompareOp, expected: u32) TableError!u64 {
    try ensureSnapshotU32Column(snapshot, column_index);
    if (snapshotIndexForU32Column(snapshot, column_index)) |index| {
        return countU64CmpInIndex(index, op, expected);
    }
    var count: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 4);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            if (compareU64(readU32LE(bytes, byte_offset), op, expected)) count += 1;
        }
    }
    return count;
}

pub fn snapshotFindU32(snapshot: *const ReadSnapshot, column_index: usize, expected: u32) TableError!U64FindResult {
    try ensureSnapshotU32Column(snapshot, column_index);
    if (snapshotIndexForU32Column(snapshot, column_index)) |index| {
        return findU64InIndex(index, expected);
    }
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 4);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            if (readU32LE(bytes, byte_offset) == expected) {
                return .{ .found = true, .row_index = row_base + i };
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .found = false, .row_index = 0 };
}

pub fn snapshotCountI32Cmp(snapshot: *const ReadSnapshot, column_index: usize, op: U64CompareOp, expected: i32) TableError!u64 {
    try ensureSnapshotI32Column(snapshot, column_index);
    if (snapshotIndexForI32Column(snapshot, column_index)) |index| {
        return countI32CmpInIndex(index, op, expected);
    }
    var count: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 4);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            if (compareI32(readI32LE(bytes, byte_offset), op, expected)) count += 1;
        }
    }
    return count;
}

pub fn snapshotFindI32(snapshot: *const ReadSnapshot, column_index: usize, expected: i32) TableError!U64FindResult {
    try ensureSnapshotI32Column(snapshot, column_index);
    if (snapshotIndexForI32Column(snapshot, column_index)) |index| {
        return findI32InIndex(index, expected);
    }
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 4);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            if (readI32LE(bytes, byte_offset) == expected) {
                return .{ .found = true, .row_index = row_base + i };
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .found = false, .row_index = 0 };
}

pub fn snapshotCountU8Cmp(snapshot: *const ReadSnapshot, column_index: usize, op: U64CompareOp, expected: u8) TableError!u64 {
    try ensureSnapshotU8Column(snapshot, column_index);
    if (snapshotIndexForU8Column(snapshot, column_index)) |index| {
        return countU64CmpInIndex(index, op, expected);
    }
    var count: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 1);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i);
            if (compareU64(bytes[byte_offset], op, expected)) count += 1;
        }
    }
    return count;
}

pub fn snapshotFindU8(snapshot: *const ReadSnapshot, column_index: usize, expected: u8) TableError!U64FindResult {
    try ensureSnapshotU8Column(snapshot, column_index);
    if (snapshotIndexForU8Column(snapshot, column_index)) |index| {
        return findU64InIndex(index, expected);
    }
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 1);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i);
            if (bytes[byte_offset] == expected) {
                return .{ .found = true, .row_index = row_base + i };
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .found = false, .row_index = 0 };
}

pub fn snapshotCountI8Cmp(snapshot: *const ReadSnapshot, column_index: usize, op: U64CompareOp, expected: i8) TableError!u64 {
    try ensureSnapshotI8Column(snapshot, column_index);
    if (snapshotIndexForI8Column(snapshot, column_index)) |index| {
        return countI8CmpInIndex(index, op, expected);
    }
    var count: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 1);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i);
            if (compareI8(readI8(bytes, byte_offset), op, expected)) count += 1;
        }
    }
    return count;
}

pub fn snapshotFindI8(snapshot: *const ReadSnapshot, column_index: usize, expected: i8) TableError!U64FindResult {
    try ensureSnapshotI8Column(snapshot, column_index);
    if (snapshotIndexForI8Column(snapshot, column_index)) |index| {
        return findI8InIndex(index, expected);
    }
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 1);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i);
            if (readI8(bytes, byte_offset) == expected) {
                return .{ .found = true, .row_index = row_base + i };
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .found = false, .row_index = 0 };
}

pub fn snapshotCountU16Cmp(snapshot: *const ReadSnapshot, column_index: usize, op: U64CompareOp, expected: u16) TableError!u64 {
    try ensureSnapshotU16Column(snapshot, column_index);
    if (snapshotIndexForU16Column(snapshot, column_index)) |index| {
        return countU64CmpInIndex(index, op, expected);
    }
    var count: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 2);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 2);
            if (compareU64(readU16LE(bytes, byte_offset), op, expected)) count += 1;
        }
    }
    return count;
}

pub fn snapshotFindU16(snapshot: *const ReadSnapshot, column_index: usize, expected: u16) TableError!U64FindResult {
    try ensureSnapshotU16Column(snapshot, column_index);
    if (snapshotIndexForU16Column(snapshot, column_index)) |index| {
        return findU64InIndex(index, expected);
    }
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 2);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 2);
            if (readU16LE(bytes, byte_offset) == expected) {
                return .{ .found = true, .row_index = row_base + i };
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .found = false, .row_index = 0 };
}

pub fn snapshotCountI16Cmp(snapshot: *const ReadSnapshot, column_index: usize, op: U64CompareOp, expected: i16) TableError!u64 {
    try ensureSnapshotI16Column(snapshot, column_index);
    if (snapshotIndexForI16Column(snapshot, column_index)) |index| {
        return countI16CmpInIndex(index, op, expected);
    }
    var count: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 2);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 2);
            if (compareI16(readI16LE(bytes, byte_offset), op, expected)) count += 1;
        }
    }
    return count;
}

pub fn snapshotFindI16(snapshot: *const ReadSnapshot, column_index: usize, expected: i16) TableError!U64FindResult {
    try ensureSnapshotI16Column(snapshot, column_index);
    if (snapshotIndexForI16Column(snapshot, column_index)) |index| {
        return findI16InIndex(index, expected);
    }
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 2);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 2);
            if (readI16LE(bytes, byte_offset) == expected) {
                return .{ .found = true, .row_index = row_base + i };
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .found = false, .row_index = 0 };
}

pub fn snapshotCountF32Cmp(snapshot: *const ReadSnapshot, column_index: usize, op: U64CompareOp, expected: f32) TableError!u64 {
    _ = try finiteF32(expected);
    try ensureSnapshotF32Column(snapshot, column_index);
    if (snapshotIndexForF32Column(snapshot, column_index)) |index| {
        return try countF32CmpInIndex(index, op, expected);
    }
    var count: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 4);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            if (try compareF32(readF32LE(bytes, byte_offset), op, expected)) count += 1;
        }
    }
    return count;
}

pub fn snapshotFindF32(snapshot: *const ReadSnapshot, column_index: usize, expected: f32) TableError!U64FindResult {
    _ = try finiteF32(expected);
    try ensureSnapshotF32Column(snapshot, column_index);
    if (snapshotIndexForF32Column(snapshot, column_index)) |index| {
        return try findF32InIndex(index, expected);
    }
    const normalized_expected = try finiteF32(expected);
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 4);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            if ((try finiteF32(readF32LE(bytes, byte_offset))) == normalized_expected) {
                return .{ .found = true, .row_index = row_base + i };
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .found = false, .row_index = 0 };
}

pub fn snapshotCountF64Cmp(snapshot: *const ReadSnapshot, column_index: usize, op: U64CompareOp, expected: f64) TableError!u64 {
    _ = try finiteF64(expected);
    try ensureSnapshotF64Column(snapshot, column_index);
    if (snapshotIndexForF64Column(snapshot, column_index)) |index| {
        return try countF64CmpInIndex(index, op, expected);
    }
    var count: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            if (try compareF64(readF64LE(bytes, byte_offset), op, expected)) count += 1;
        }
    }
    return count;
}

pub fn snapshotFindF64(snapshot: *const ReadSnapshot, column_index: usize, expected: f64) TableError!U64FindResult {
    _ = try finiteF64(expected);
    try ensureSnapshotF64Column(snapshot, column_index);
    if (snapshotIndexForF64Column(snapshot, column_index)) |index| {
        return try findF64InIndex(index, expected);
    }
    const normalized_expected = try finiteF64(expected);
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            if ((try finiteF64(readF64LE(bytes, byte_offset))) == normalized_expected) {
                return .{ .found = true, .row_index = row_base + i };
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .found = false, .row_index = 0 };
}

pub fn snapshotCountBool(snapshot: *const ReadSnapshot, column_index: usize, expected: bool) TableError!u64 {
    try ensureSnapshotBoolColumn(snapshot, column_index);
    const column = snapshot.columns[column_index];
    var count: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, column.stride);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            if ((try readBoolColumnValue(column, bytes, i)) == expected) {
                count = std.math.add(u64, count, 1) catch return TableError.CursorOverflow;
            }
        }
    }
    return count;
}

pub fn snapshotFindBool(snapshot: *const ReadSnapshot, column_index: usize, expected: bool) TableError!U64FindResult {
    try ensureSnapshotBoolColumn(snapshot, column_index);
    const column = snapshot.columns[column_index];
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, column.stride);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            if ((try readBoolColumnValue(column, bytes, i)) == expected) {
                return .{ .found = true, .row_index = row_base + i };
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .found = false, .row_index = 0 };
}

pub fn snapshotFilterBoolRows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    expected: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!BoolFilterResult {
    try ensureSnapshotBoolColumn(snapshot, column_index);
    const column = snapshot.columns[column_index];
    var total: u64 = 0;
    var written: u64 = 0;
    const out_capacity: u64 = @intCast(out_rows.len);
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, column.stride);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            if ((try readBoolColumnValue(column, bytes, i)) == expected) {
                if (total >= offset and limit != 0 and written < limit and written < out_capacity) {
                    out_rows[@intCast(written)] = row_base + i;
                    written += 1;
                }
                total = std.math.add(u64, total, 1) catch return TableError.CursorOverflow;
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    return .{ .written = written, .total = total };
}

pub fn snapshotFindU64Pair(snapshot: *const ReadSnapshot, column_index: usize, column_index2: usize, key1: u64, key2: u64) TableError!U64FindResult {
    try ensureSnapshotU64Column(snapshot, column_index);
    try ensureSnapshotU64Column(snapshot, column_index2);
    const index = snapshotIndexForU64PairColumns(snapshot, column_index, column_index2) orelse return TableError.InvalidFormat;
    return findU64PairInIndex(index, key1, key2);
}

pub fn snapshotFindU64I64Pair(snapshot: *const ReadSnapshot, column_index: usize, column_index2: usize, key1: u64, key2: i64) TableError!U64FindResult {
    try ensureSnapshotU64Column(snapshot, column_index);
    try ensureSnapshotI64Column(snapshot, column_index2);
    const index = snapshotIndexForU64I64PairColumns(snapshot, column_index, column_index2) orelse return TableError.InvalidFormat;
    return findU64PairInIndex(index, key1, sortableI64Key(key2));
}

pub fn snapshotRangeU64Rows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: u64,
    max_value: u64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, column_index);
    const index = snapshotIndexForU64Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    if (min_value > max_value) return .{ .written = 0, .total = 0 };

    const start = lowerBoundU64Index(index, min_value);
    const end = upperBoundU64Index(index, max_value);
    const total = end - start;
    if (offset >= @as(u64, @intCast(total)) or limit == 0 or out_rows.len == 0) {
        return .{ .written = 0, .total = @intCast(total) };
    }

    const offset_usize: usize = @intCast(offset);
    const page_start = start + offset_usize;
    const available = end - page_start;
    const capped_by_limit: usize = if (limit > @as(u64, @intCast(std.math.maxInt(usize))))
        available
    else
        @min(available, @as(usize, @intCast(limit)));
    const write_count = @min(capped_by_limit, out_rows.len);

    var i: usize = 0;
    while (i < write_count) : (i += 1) {
        out_rows[i] = readIndexRow(index.entries, page_start + i);
    }
    return .{ .written = @intCast(write_count), .total = @intCast(total) };
}

pub fn snapshotRangeU64RowsNullBitmap(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: u64,
    max_value: u64,
    null_bitmap: []const u8,
    want_null: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, column_index);
    const index = snapshotIndexForU64Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    try ensureNullBitmapRows(snapshot.row_count, null_bitmap);
    if (min_value > max_value) return .{ .written = 0, .total = 0 };

    const start = lowerBoundU64Index(index, min_value);
    const end = upperBoundU64Index(index, max_value);
    return try copyRangeRowsWithNullBitmap(index, snapshot.row_count, start, end, null_bitmap, want_null, offset, limit, out_rows);
}

pub fn snapshotRangeI64Rows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: i64,
    max_value: i64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotI64Column(snapshot, column_index);
    const index = snapshotIndexForI64Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    if (min_value > max_value) return .{ .written = 0, .total = 0 };

    const start = lowerBoundU64Index(index, sortableI64Key(min_value));
    const end = upperBoundU64Index(index, sortableI64Key(max_value));
    const total = end - start;
    if (offset >= @as(u64, @intCast(total)) or limit == 0 or out_rows.len == 0) {
        return .{ .written = 0, .total = @intCast(total) };
    }

    const offset_usize: usize = @intCast(offset);
    const page_start = start + offset_usize;
    const available = end - page_start;
    const capped_by_limit: usize = if (limit > @as(u64, @intCast(std.math.maxInt(usize))))
        available
    else
        @min(available, @as(usize, @intCast(limit)));
    const write_count = @min(capped_by_limit, out_rows.len);

    var i: usize = 0;
    while (i < write_count) : (i += 1) {
        out_rows[i] = readIndexRow(index.entries, page_start + i);
    }
    return .{ .written = @intCast(write_count), .total = @intCast(total) };
}

pub fn snapshotRangeU32Rows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: u32,
    max_value: u32,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU32Column(snapshot, column_index);
    const index = snapshotIndexForU32Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    if (min_value > max_value) return .{ .written = 0, .total = 0 };

    const start = lowerBoundU64Index(index, min_value);
    const end = upperBoundU64Index(index, max_value);
    const total = end - start;
    if (offset >= @as(u64, @intCast(total)) or limit == 0 or out_rows.len == 0) {
        return .{ .written = 0, .total = @intCast(total) };
    }

    const offset_usize: usize = @intCast(offset);
    const page_start = start + offset_usize;
    const available = end - page_start;
    const capped_by_limit: usize = if (limit > @as(u64, @intCast(std.math.maxInt(usize))))
        available
    else
        @min(available, @as(usize, @intCast(limit)));
    const write_count = @min(capped_by_limit, out_rows.len);

    var i: usize = 0;
    while (i < write_count) : (i += 1) {
        out_rows[i] = readIndexRow(index.entries, page_start + i);
    }
    return .{ .written = @intCast(write_count), .total = @intCast(total) };
}

pub fn snapshotRangeI32Rows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: i32,
    max_value: i32,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotI32Column(snapshot, column_index);
    const index = snapshotIndexForI32Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    if (min_value > max_value) return .{ .written = 0, .total = 0 };

    const start = lowerBoundU64Index(index, sortableI32Key(min_value));
    const end = upperBoundU64Index(index, sortableI32Key(max_value));
    const total = end - start;
    if (offset >= @as(u64, @intCast(total)) or limit == 0 or out_rows.len == 0) {
        return .{ .written = 0, .total = @intCast(total) };
    }

    const offset_usize: usize = @intCast(offset);
    const page_start = start + offset_usize;
    const available = end - page_start;
    const capped_by_limit: usize = if (limit > @as(u64, @intCast(std.math.maxInt(usize))))
        available
    else
        @min(available, @as(usize, @intCast(limit)));
    const write_count = @min(capped_by_limit, out_rows.len);

    var i: usize = 0;
    while (i < write_count) : (i += 1) {
        out_rows[i] = readIndexRow(index.entries, page_start + i);
    }
    return .{ .written = @intCast(write_count), .total = @intCast(total) };
}

pub fn snapshotRangeU8Rows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: u8,
    max_value: u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU8Column(snapshot, column_index);
    const index = snapshotIndexForU8Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    if (min_value > max_value) return .{ .written = 0, .total = 0 };

    const start = lowerBoundU64Index(index, min_value);
    const end = upperBoundU64Index(index, max_value);
    const total = end - start;
    if (offset >= @as(u64, @intCast(total)) or limit == 0 or out_rows.len == 0) {
        return .{ .written = 0, .total = @intCast(total) };
    }

    const offset_usize: usize = @intCast(offset);
    const page_start = start + offset_usize;
    const available = end - page_start;
    const capped_by_limit: usize = if (limit > @as(u64, @intCast(std.math.maxInt(usize))))
        available
    else
        @min(available, @as(usize, @intCast(limit)));
    const write_count = @min(capped_by_limit, out_rows.len);

    var i: usize = 0;
    while (i < write_count) : (i += 1) {
        out_rows[i] = readIndexRow(index.entries, page_start + i);
    }
    return .{ .written = @intCast(write_count), .total = @intCast(total) };
}

pub fn snapshotRangeI8Rows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: i8,
    max_value: i8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotI8Column(snapshot, column_index);
    const index = snapshotIndexForI8Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    if (min_value > max_value) return .{ .written = 0, .total = 0 };

    const start = lowerBoundU64Index(index, sortableI8Key(min_value));
    const end = upperBoundU64Index(index, sortableI8Key(max_value));
    const total = end - start;
    if (offset >= @as(u64, @intCast(total)) or limit == 0 or out_rows.len == 0) {
        return .{ .written = 0, .total = @intCast(total) };
    }

    const offset_usize: usize = @intCast(offset);
    const page_start = start + offset_usize;
    const available = end - page_start;
    const capped_by_limit: usize = if (limit > @as(u64, @intCast(std.math.maxInt(usize))))
        available
    else
        @min(available, @as(usize, @intCast(limit)));
    const write_count = @min(capped_by_limit, out_rows.len);

    var i: usize = 0;
    while (i < write_count) : (i += 1) {
        out_rows[i] = readIndexRow(index.entries, page_start + i);
    }
    return .{ .written = @intCast(write_count), .total = @intCast(total) };
}

pub fn snapshotRangeU16Rows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: u16,
    max_value: u16,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU16Column(snapshot, column_index);
    const index = snapshotIndexForU16Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    if (min_value > max_value) return .{ .written = 0, .total = 0 };

    const start = lowerBoundU64Index(index, min_value);
    const end = upperBoundU64Index(index, max_value);
    const total = end - start;
    if (offset >= @as(u64, @intCast(total)) or limit == 0 or out_rows.len == 0) {
        return .{ .written = 0, .total = @intCast(total) };
    }

    const offset_usize: usize = @intCast(offset);
    const page_start = start + offset_usize;
    const available = end - page_start;
    const capped_by_limit: usize = if (limit > @as(u64, @intCast(std.math.maxInt(usize))))
        available
    else
        @min(available, @as(usize, @intCast(limit)));
    const write_count = @min(capped_by_limit, out_rows.len);

    var i: usize = 0;
    while (i < write_count) : (i += 1) {
        out_rows[i] = readIndexRow(index.entries, page_start + i);
    }
    return .{ .written = @intCast(write_count), .total = @intCast(total) };
}

pub fn snapshotRangeI16Rows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: i16,
    max_value: i16,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotI16Column(snapshot, column_index);
    const index = snapshotIndexForI16Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    if (min_value > max_value) return .{ .written = 0, .total = 0 };

    const start = lowerBoundU64Index(index, sortableI16Key(min_value));
    const end = upperBoundU64Index(index, sortableI16Key(max_value));
    const total = end - start;
    if (offset >= @as(u64, @intCast(total)) or limit == 0 or out_rows.len == 0) {
        return .{ .written = 0, .total = @intCast(total) };
    }

    const offset_usize: usize = @intCast(offset);
    const page_start = start + offset_usize;
    const available = end - page_start;
    const capped_by_limit: usize = if (limit > @as(u64, @intCast(std.math.maxInt(usize))))
        available
    else
        @min(available, @as(usize, @intCast(limit)));
    const write_count = @min(capped_by_limit, out_rows.len);

    var i: usize = 0;
    while (i < write_count) : (i += 1) {
        out_rows[i] = readIndexRow(index.entries, page_start + i);
    }
    return .{ .written = @intCast(write_count), .total = @intCast(total) };
}

pub fn snapshotRangeF32Rows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: f32,
    max_value: f32,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotF32Column(snapshot, column_index);
    const index = snapshotIndexForF32Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    const normalized_min = try finiteF32(min_value);
    const normalized_max = try finiteF32(max_value);
    if (normalized_min > normalized_max) return .{ .written = 0, .total = 0 };

    const start = lowerBoundU64Index(index, try sortableF32Key(normalized_min));
    const end = upperBoundU64Index(index, try sortableF32Key(normalized_max));
    const total = end - start;
    if (offset >= @as(u64, @intCast(total)) or limit == 0 or out_rows.len == 0) {
        return .{ .written = 0, .total = @intCast(total) };
    }

    const offset_usize: usize = @intCast(offset);
    const page_start = start + offset_usize;
    const available = end - page_start;
    const capped_by_limit: usize = if (limit > @as(u64, @intCast(std.math.maxInt(usize))))
        available
    else
        @min(available, @as(usize, @intCast(limit)));
    const write_count = @min(capped_by_limit, out_rows.len);

    var i: usize = 0;
    while (i < write_count) : (i += 1) {
        out_rows[i] = readIndexRow(index.entries, page_start + i);
    }
    return .{ .written = @intCast(write_count), .total = @intCast(total) };
}

pub fn snapshotRangeF64Rows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: f64,
    max_value: f64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotF64Column(snapshot, column_index);
    const index = snapshotIndexForF64Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    const normalized_min = try finiteF64(min_value);
    const normalized_max = try finiteF64(max_value);
    if (normalized_min > normalized_max) return .{ .written = 0, .total = 0 };

    const start = lowerBoundU64Index(index, try sortableF64Key(normalized_min));
    const end = upperBoundU64Index(index, try sortableF64Key(normalized_max));
    const total = end - start;
    if (offset >= @as(u64, @intCast(total)) or limit == 0 or out_rows.len == 0) {
        return .{ .written = 0, .total = @intCast(total) };
    }

    const offset_usize: usize = @intCast(offset);
    const page_start = start + offset_usize;
    const available = end - page_start;
    const capped_by_limit: usize = if (limit > @as(u64, @intCast(std.math.maxInt(usize))))
        available
    else
        @min(available, @as(usize, @intCast(limit)));
    const write_count = @min(capped_by_limit, out_rows.len);

    var i: usize = 0;
    while (i < write_count) : (i += 1) {
        out_rows[i] = readIndexRow(index.entries, page_start + i);
    }
    return .{ .written = @intCast(write_count), .total = @intCast(total) };
}

pub fn snapshotRangeI64RowsNullBitmap(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: i64,
    max_value: i64,
    null_bitmap: []const u8,
    want_null: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotI64Column(snapshot, column_index);
    const index = snapshotIndexForI64Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    try ensureNullBitmapRows(snapshot.row_count, null_bitmap);
    if (min_value > max_value) return .{ .written = 0, .total = 0 };

    const start = lowerBoundU64Index(index, sortableI64Key(min_value));
    const end = upperBoundU64Index(index, sortableI64Key(max_value));
    return try copyRangeRowsWithNullBitmap(index, snapshot.row_count, start, end, null_bitmap, want_null, offset, limit, out_rows);
}

pub fn snapshotRangeU64PairRows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    column_index2: usize,
    key1: u64,
    min_key2: u64,
    max_key2: u64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, column_index);
    try ensureSnapshotU64Column(snapshot, column_index2);
    const index = snapshotIndexForU64PairColumns(snapshot, column_index, column_index2) orelse return TableError.InvalidFormat;
    if (min_key2 > max_key2) return .{ .written = 0, .total = 0 };

    const start = lowerBoundU64PairIndex(index, key1, min_key2);
    const end = upperBoundU64PairIndex(index, key1, max_key2);
    const total = end - start;
    if (offset >= @as(u64, @intCast(total)) or limit == 0 or out_rows.len == 0) {
        return .{ .written = 0, .total = @intCast(total) };
    }

    const offset_usize: usize = @intCast(offset);
    const page_start = start + offset_usize;
    const available = end - page_start;
    const capped_by_limit: usize = if (limit > @as(u64, @intCast(std.math.maxInt(usize))))
        available
    else
        @min(available, @as(usize, @intCast(limit)));
    const write_count = @min(capped_by_limit, out_rows.len);

    var i: usize = 0;
    while (i < write_count) : (i += 1) {
        out_rows[i] = readU64PairIndexRow(index.entries, page_start + i);
    }
    return .{ .written = @intCast(write_count), .total = @intCast(total) };
}

pub fn snapshotRangeU64I64PairRows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    column_index2: usize,
    key1: u64,
    min_key2: i64,
    max_key2: i64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, column_index);
    try ensureSnapshotI64Column(snapshot, column_index2);
    const index = snapshotIndexForU64I64PairColumns(snapshot, column_index, column_index2) orelse return TableError.InvalidFormat;
    if (min_key2 > max_key2) return .{ .written = 0, .total = 0 };

    const start = lowerBoundU64PairIndex(index, key1, sortableI64Key(min_key2));
    const end = upperBoundU64PairIndex(index, key1, sortableI64Key(max_key2));
    const total = end - start;
    if (offset >= @as(u64, @intCast(total)) or limit == 0 or out_rows.len == 0) {
        return .{ .written = 0, .total = @intCast(total) };
    }

    const offset_usize: usize = @intCast(offset);
    const page_start = start + offset_usize;
    const available = end - page_start;
    const capped_by_limit: usize = if (limit > @as(u64, @intCast(std.math.maxInt(usize))))
        available
    else
        @min(available, @as(usize, @intCast(limit)));
    const write_count = @min(capped_by_limit, out_rows.len);

    var i: usize = 0;
    while (i < write_count) : (i += 1) {
        out_rows[i] = readU64PairIndexRow(index.entries, page_start + i);
    }
    return .{ .written = @intCast(write_count), .total = @intCast(total) };
}

pub fn snapshotFilterU64PairKey1Rows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    column_index2: usize,
    key1: u64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    return snapshotRangeU64PairRows(snapshot, column_index, column_index2, key1, 0, std.math.maxInt(u64), offset, limit, out_rows);
}

pub fn snapshotFilterU64I64PairKey1Rows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    column_index2: usize,
    key1: u64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    return snapshotRangeU64I64PairRows(snapshot, column_index, column_index2, key1, std.math.minInt(i64), std.math.maxInt(i64), offset, limit, out_rows);
}

pub fn snapshotFilterRowsU64Range(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    min_value: u64,
    max_value: u64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, column_index);
    if (min_value > max_value) return .{ .written = 0, .total = 0 };
    return try copyCandidateRowsByPredicate(in_rows, offset, limit, out_rows, FilterRowsU64RangeContext{
        .snapshot = snapshot,
        .column_index = column_index,
        .min_value = min_value,
        .max_value = max_value,
    }, matchesRowsU64Range);
}

pub fn snapshotFilterRowsI64Range(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    min_value: i64,
    max_value: i64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotI64Column(snapshot, column_index);
    if (min_value > max_value) return .{ .written = 0, .total = 0 };
    return try copyCandidateRowsByPredicate(in_rows, offset, limit, out_rows, FilterRowsI64RangeContext{
        .snapshot = snapshot,
        .column_index = column_index,
        .min_value = min_value,
        .max_value = max_value,
    }, matchesRowsI64Range);
}

pub fn snapshotFilterRowsU32Range(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    min_value: u32,
    max_value: u32,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU32Column(snapshot, column_index);
    if (min_value > max_value) return .{ .written = 0, .total = 0 };
    return try copyCandidateRowsByPredicate(in_rows, offset, limit, out_rows, FilterRowsU32RangeContext{
        .snapshot = snapshot,
        .column_index = column_index,
        .min_value = min_value,
        .max_value = max_value,
    }, matchesRowsU32Range);
}

pub fn snapshotFilterRowsI32Range(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    min_value: i32,
    max_value: i32,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotI32Column(snapshot, column_index);
    if (min_value > max_value) return .{ .written = 0, .total = 0 };
    return try copyCandidateRowsByPredicate(in_rows, offset, limit, out_rows, FilterRowsI32RangeContext{
        .snapshot = snapshot,
        .column_index = column_index,
        .min_value = min_value,
        .max_value = max_value,
    }, matchesRowsI32Range);
}

pub fn snapshotFilterRowsU8Range(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    min_value: u8,
    max_value: u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU8Column(snapshot, column_index);
    if (min_value > max_value) return .{ .written = 0, .total = 0 };
    return try copyCandidateRowsByPredicate(in_rows, offset, limit, out_rows, FilterRowsU8RangeContext{
        .snapshot = snapshot,
        .column_index = column_index,
        .min_value = min_value,
        .max_value = max_value,
    }, matchesRowsU8Range);
}

pub fn snapshotFilterRowsI8Range(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    min_value: i8,
    max_value: i8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotI8Column(snapshot, column_index);
    if (min_value > max_value) return .{ .written = 0, .total = 0 };
    return try copyCandidateRowsByPredicate(in_rows, offset, limit, out_rows, FilterRowsI8RangeContext{
        .snapshot = snapshot,
        .column_index = column_index,
        .min_value = min_value,
        .max_value = max_value,
    }, matchesRowsI8Range);
}

pub fn snapshotFilterRowsU16Range(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    min_value: u16,
    max_value: u16,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU16Column(snapshot, column_index);
    if (min_value > max_value) return .{ .written = 0, .total = 0 };
    return try copyCandidateRowsByPredicate(in_rows, offset, limit, out_rows, FilterRowsU16RangeContext{
        .snapshot = snapshot,
        .column_index = column_index,
        .min_value = min_value,
        .max_value = max_value,
    }, matchesRowsU16Range);
}

pub fn snapshotFilterRowsI16Range(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    min_value: i16,
    max_value: i16,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotI16Column(snapshot, column_index);
    if (min_value > max_value) return .{ .written = 0, .total = 0 };
    return try copyCandidateRowsByPredicate(in_rows, offset, limit, out_rows, FilterRowsI16RangeContext{
        .snapshot = snapshot,
        .column_index = column_index,
        .min_value = min_value,
        .max_value = max_value,
    }, matchesRowsI16Range);
}

pub fn snapshotFilterRowsF32Range(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    min_value: f32,
    max_value: f32,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotF32Column(snapshot, column_index);
    const normalized_min = try finiteF32(min_value);
    const normalized_max = try finiteF32(max_value);
    if (normalized_min > normalized_max) return .{ .written = 0, .total = 0 };
    return try copyCandidateRowsByPredicate(in_rows, offset, limit, out_rows, FilterRowsF32RangeContext{
        .snapshot = snapshot,
        .column_index = column_index,
        .min_value = normalized_min,
        .max_value = normalized_max,
    }, matchesRowsF32Range);
}

pub fn snapshotFilterRowsF64Range(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    min_value: f64,
    max_value: f64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotF64Column(snapshot, column_index);
    const normalized_min = try finiteF64(min_value);
    const normalized_max = try finiteF64(max_value);
    if (normalized_min > normalized_max) return .{ .written = 0, .total = 0 };
    return try copyCandidateRowsByPredicate(in_rows, offset, limit, out_rows, FilterRowsF64RangeContext{
        .snapshot = snapshot,
        .column_index = column_index,
        .min_value = normalized_min,
        .max_value = normalized_max,
    }, matchesRowsF64Range);
}

pub fn snapshotFilterRowsBool(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    expected: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotBoolColumn(snapshot, column_index);
    return try copyCandidateRowsByPredicate(in_rows, offset, limit, out_rows, FilterRowsBoolContext{
        .snapshot = snapshot,
        .column_index = column_index,
        .expected = expected,
    }, matchesRowsBool);
}

pub fn snapshotSortRowsU64(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    descending: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, column_index);
    return try snapshotSortRowsBy(u64, allocator, snapshot, column_index, in_rows, descending, offset, limit, out_rows, snapshotU64AtRow);
}

pub fn snapshotSortRowsI64(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    descending: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotI64Column(snapshot, column_index);
    return try snapshotSortRowsBy(i64, allocator, snapshot, column_index, in_rows, descending, offset, limit, out_rows, snapshotI64AtRow);
}

pub fn snapshotSortRowsU32(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    descending: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU32Column(snapshot, column_index);
    return try snapshotSortRowsBy(u32, allocator, snapshot, column_index, in_rows, descending, offset, limit, out_rows, snapshotU32AtRow);
}

pub fn snapshotSortRowsI32(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    descending: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotI32Column(snapshot, column_index);
    return try snapshotSortRowsBy(i32, allocator, snapshot, column_index, in_rows, descending, offset, limit, out_rows, snapshotI32AtRow);
}

pub fn snapshotSortRowsU8(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    descending: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU8Column(snapshot, column_index);
    return try snapshotSortRowsBy(u8, allocator, snapshot, column_index, in_rows, descending, offset, limit, out_rows, snapshotU8AtRow);
}

pub fn snapshotSortRowsI8(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    descending: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotI8Column(snapshot, column_index);
    return try snapshotSortRowsBy(i8, allocator, snapshot, column_index, in_rows, descending, offset, limit, out_rows, snapshotI8AtRow);
}

pub fn snapshotSortRowsU16(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    descending: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU16Column(snapshot, column_index);
    return try snapshotSortRowsBy(u16, allocator, snapshot, column_index, in_rows, descending, offset, limit, out_rows, snapshotU16AtRow);
}

pub fn snapshotSortRowsI16(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    descending: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotI16Column(snapshot, column_index);
    return try snapshotSortRowsBy(i16, allocator, snapshot, column_index, in_rows, descending, offset, limit, out_rows, snapshotI16AtRow);
}

pub fn snapshotSortRowsF32(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    descending: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotF32Column(snapshot, column_index);
    return try snapshotSortRowsBy(f32, allocator, snapshot, column_index, in_rows, descending, offset, limit, out_rows, snapshotF32AtRow);
}

pub fn snapshotSortRowsF64(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    descending: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotF64Column(snapshot, column_index);
    return try snapshotSortRowsBy(f64, allocator, snapshot, column_index, in_rows, descending, offset, limit, out_rows, snapshotF64AtRow);
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

pub fn snapshotGetI64(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!i64 {
    try ensureSnapshotI64Column(snapshot, column_index);
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
            return readI64LE(bytes, byte_offset);
        }
        row_base = segment_end;
    }
    return TableError.InvalidFormat;
}

pub fn snapshotGetU32(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!u32 {
    try ensureSnapshotU32Column(snapshot, column_index);
    if (row_index >= snapshot.row_count) return TableError.InvalidFormat;
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const segment_end = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        if (row_index < segment_end) {
            const bytes = segment.columns[column_index].bytes;
            const expected_len = try expectedColumnBytes(segment.rows, 4);
            if (bytes.len != expected_len) return TableError.VerifyFailed;
            const local_row = row_index - row_base;
            const byte_offset: usize = @intCast(local_row * 4);
            return readU32LE(bytes, byte_offset);
        }
        row_base = segment_end;
    }
    return TableError.InvalidFormat;
}

pub fn snapshotGetI32(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!i32 {
    try ensureSnapshotI32Column(snapshot, column_index);
    if (row_index >= snapshot.row_count) return TableError.InvalidFormat;
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const segment_end = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        if (row_index < segment_end) {
            const bytes = segment.columns[column_index].bytes;
            const expected_len = try expectedColumnBytes(segment.rows, 4);
            if (bytes.len != expected_len) return TableError.VerifyFailed;
            const local_row = row_index - row_base;
            const byte_offset: usize = @intCast(local_row * 4);
            return readI32LE(bytes, byte_offset);
        }
        row_base = segment_end;
    }
    return TableError.InvalidFormat;
}

pub fn snapshotGetU8(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!u8 {
    try ensureSnapshotU8Column(snapshot, column_index);
    if (row_index >= snapshot.row_count) return TableError.InvalidFormat;
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const segment_end = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        if (row_index < segment_end) {
            const bytes = segment.columns[column_index].bytes;
            const expected_len = try expectedColumnBytes(segment.rows, 1);
            if (bytes.len != expected_len) return TableError.VerifyFailed;
            const local_row = row_index - row_base;
            const byte_offset: usize = @intCast(local_row);
            return bytes[byte_offset];
        }
        row_base = segment_end;
    }
    return TableError.InvalidFormat;
}

pub fn snapshotGetI8(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!i8 {
    try ensureSnapshotI8Column(snapshot, column_index);
    if (row_index >= snapshot.row_count) return TableError.InvalidFormat;
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const segment_end = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        if (row_index < segment_end) {
            const bytes = segment.columns[column_index].bytes;
            const expected_len = try expectedColumnBytes(segment.rows, 1);
            if (bytes.len != expected_len) return TableError.VerifyFailed;
            const local_row = row_index - row_base;
            const byte_offset: usize = @intCast(local_row);
            return readI8(bytes, byte_offset);
        }
        row_base = segment_end;
    }
    return TableError.InvalidFormat;
}

pub fn snapshotGetU16(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!u16 {
    try ensureSnapshotU16Column(snapshot, column_index);
    if (row_index >= snapshot.row_count) return TableError.InvalidFormat;
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const segment_end = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        if (row_index < segment_end) {
            const bytes = segment.columns[column_index].bytes;
            const expected_len = try expectedColumnBytes(segment.rows, 2);
            if (bytes.len != expected_len) return TableError.VerifyFailed;
            const local_row = row_index - row_base;
            const byte_offset: usize = @intCast(local_row * 2);
            return readU16LE(bytes, byte_offset);
        }
        row_base = segment_end;
    }
    return TableError.InvalidFormat;
}

pub fn snapshotGetI16(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!i16 {
    try ensureSnapshotI16Column(snapshot, column_index);
    if (row_index >= snapshot.row_count) return TableError.InvalidFormat;
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const segment_end = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        if (row_index < segment_end) {
            const bytes = segment.columns[column_index].bytes;
            const expected_len = try expectedColumnBytes(segment.rows, 2);
            if (bytes.len != expected_len) return TableError.VerifyFailed;
            const local_row = row_index - row_base;
            const byte_offset: usize = @intCast(local_row * 2);
            return readI16LE(bytes, byte_offset);
        }
        row_base = segment_end;
    }
    return TableError.InvalidFormat;
}

pub fn snapshotGetF32(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!f32 {
    try ensureSnapshotF32Column(snapshot, column_index);
    if (row_index >= snapshot.row_count) return TableError.InvalidFormat;
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const segment_end = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        if (row_index < segment_end) {
            const bytes = segment.columns[column_index].bytes;
            const expected_len = try expectedColumnBytes(segment.rows, 4);
            if (bytes.len != expected_len) return TableError.VerifyFailed;
            const local_row = row_index - row_base;
            const byte_offset: usize = @intCast(local_row * 4);
            return try finiteF32(readF32LE(bytes, byte_offset));
        }
        row_base = segment_end;
    }
    return TableError.InvalidFormat;
}

pub fn snapshotGetF64(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!f64 {
    try ensureSnapshotF64Column(snapshot, column_index);
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
            return try finiteF64(readF64LE(bytes, byte_offset));
        }
        row_base = segment_end;
    }
    return TableError.InvalidFormat;
}

pub fn snapshotGetBool(snapshot: *const ReadSnapshot, column_index: usize, row_index: u64) TableError!bool {
    try ensureSnapshotBoolColumn(snapshot, column_index);
    if (row_index >= snapshot.row_count) return TableError.InvalidFormat;
    const column = snapshot.columns[column_index];
    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const segment_end = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        if (row_index < segment_end) {
            const bytes = segment.columns[column_index].bytes;
            const expected_len = try expectedColumnBytes(segment.rows, column.stride);
            if (bytes.len != expected_len) return TableError.VerifyFailed;
            return try readBoolColumnValue(column, bytes, row_index - row_base);
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

pub fn snapshotMinI64(snapshot: *const ReadSnapshot, column_index: usize) TableError!i64 {
    try ensureSnapshotI64Column(snapshot, column_index);
    var seen = false;
    var min_value: i64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const value = readI64LE(bytes, byte_offset);
            if (!seen or value < min_value) {
                min_value = value;
                seen = true;
            }
        }
    }
    return min_value;
}

pub fn snapshotMaxI64(snapshot: *const ReadSnapshot, column_index: usize) TableError!i64 {
    try ensureSnapshotI64Column(snapshot, column_index);
    var seen = false;
    var max_value: i64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const value = readI64LE(bytes, byte_offset);
            if (!seen or value > max_value) {
                max_value = value;
                seen = true;
            }
        }
    }
    return max_value;
}

pub fn snapshotMinU32(snapshot: *const ReadSnapshot, column_index: usize) TableError!u32 {
    try ensureSnapshotU32Column(snapshot, column_index);
    var seen = false;
    var min_value: u32 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 4);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            const value = readU32LE(bytes, byte_offset);
            if (!seen or value < min_value) {
                min_value = value;
                seen = true;
            }
        }
    }
    return min_value;
}

pub fn snapshotMaxU32(snapshot: *const ReadSnapshot, column_index: usize) TableError!u32 {
    try ensureSnapshotU32Column(snapshot, column_index);
    var seen = false;
    var max_value: u32 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 4);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            const value = readU32LE(bytes, byte_offset);
            if (!seen or value > max_value) {
                max_value = value;
                seen = true;
            }
        }
    }
    return max_value;
}

pub fn snapshotMinI32(snapshot: *const ReadSnapshot, column_index: usize) TableError!i32 {
    try ensureSnapshotI32Column(snapshot, column_index);
    var seen = false;
    var min_value: i32 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 4);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            const value = readI32LE(bytes, byte_offset);
            if (!seen or value < min_value) {
                min_value = value;
                seen = true;
            }
        }
    }
    return min_value;
}

pub fn snapshotMaxI32(snapshot: *const ReadSnapshot, column_index: usize) TableError!i32 {
    try ensureSnapshotI32Column(snapshot, column_index);
    var seen = false;
    var max_value: i32 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 4);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            const value = readI32LE(bytes, byte_offset);
            if (!seen or value > max_value) {
                max_value = value;
                seen = true;
            }
        }
    }
    return max_value;
}

pub fn snapshotMinU8(snapshot: *const ReadSnapshot, column_index: usize) TableError!u8 {
    try ensureSnapshotU8Column(snapshot, column_index);
    var seen = false;
    var min_value: u8 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 1);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i);
            const value = bytes[byte_offset];
            if (!seen or value < min_value) {
                min_value = value;
                seen = true;
            }
        }
    }
    return min_value;
}

pub fn snapshotMaxU8(snapshot: *const ReadSnapshot, column_index: usize) TableError!u8 {
    try ensureSnapshotU8Column(snapshot, column_index);
    var seen = false;
    var max_value: u8 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 1);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i);
            const value = bytes[byte_offset];
            if (!seen or value > max_value) {
                max_value = value;
                seen = true;
            }
        }
    }
    return max_value;
}

pub fn snapshotMinI8(snapshot: *const ReadSnapshot, column_index: usize) TableError!i8 {
    try ensureSnapshotI8Column(snapshot, column_index);
    var seen = false;
    var min_value: i8 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 1);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i);
            const value = readI8(bytes, byte_offset);
            if (!seen or value < min_value) {
                min_value = value;
                seen = true;
            }
        }
    }
    return min_value;
}

pub fn snapshotMaxI8(snapshot: *const ReadSnapshot, column_index: usize) TableError!i8 {
    try ensureSnapshotI8Column(snapshot, column_index);
    var seen = false;
    var max_value: i8 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 1);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i);
            const value = readI8(bytes, byte_offset);
            if (!seen or value > max_value) {
                max_value = value;
                seen = true;
            }
        }
    }
    return max_value;
}

pub fn snapshotMinU16(snapshot: *const ReadSnapshot, column_index: usize) TableError!u16 {
    try ensureSnapshotU16Column(snapshot, column_index);
    var seen = false;
    var min_value: u16 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 2);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 2);
            const value = readU16LE(bytes, byte_offset);
            if (!seen or value < min_value) {
                min_value = value;
                seen = true;
            }
        }
    }
    return min_value;
}

pub fn snapshotMaxU16(snapshot: *const ReadSnapshot, column_index: usize) TableError!u16 {
    try ensureSnapshotU16Column(snapshot, column_index);
    var seen = false;
    var max_value: u16 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 2);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 2);
            const value = readU16LE(bytes, byte_offset);
            if (!seen or value > max_value) {
                max_value = value;
                seen = true;
            }
        }
    }
    return max_value;
}

pub fn snapshotMinI16(snapshot: *const ReadSnapshot, column_index: usize) TableError!i16 {
    try ensureSnapshotI16Column(snapshot, column_index);
    var seen = false;
    var min_value: i16 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 2);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 2);
            const value = readI16LE(bytes, byte_offset);
            if (!seen or value < min_value) {
                min_value = value;
                seen = true;
            }
        }
    }
    return min_value;
}

pub fn snapshotMaxI16(snapshot: *const ReadSnapshot, column_index: usize) TableError!i16 {
    try ensureSnapshotI16Column(snapshot, column_index);
    var seen = false;
    var max_value: i16 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 2);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 2);
            const value = readI16LE(bytes, byte_offset);
            if (!seen or value > max_value) {
                max_value = value;
                seen = true;
            }
        }
    }
    return max_value;
}

pub fn snapshotMinF32(snapshot: *const ReadSnapshot, column_index: usize) TableError!f32 {
    try ensureSnapshotF32Column(snapshot, column_index);
    var seen = false;
    var min_value: f32 = 0.0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 4);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            const value = try finiteF32(readF32LE(bytes, byte_offset));
            if (!seen or value < min_value) {
                min_value = value;
                seen = true;
            }
        }
    }
    return min_value;
}

pub fn snapshotMaxF32(snapshot: *const ReadSnapshot, column_index: usize) TableError!f32 {
    try ensureSnapshotF32Column(snapshot, column_index);
    var seen = false;
    var max_value: f32 = 0.0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 4);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            const value = try finiteF32(readF32LE(bytes, byte_offset));
            if (!seen or value > max_value) {
                max_value = value;
                seen = true;
            }
        }
    }
    return max_value;
}

pub fn snapshotMinF64(snapshot: *const ReadSnapshot, column_index: usize) TableError!f64 {
    try ensureSnapshotF64Column(snapshot, column_index);
    var seen = false;
    var min_value: f64 = 0.0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const value = try finiteF64(readF64LE(bytes, byte_offset));
            if (!seen or value < min_value) {
                min_value = value;
                seen = true;
            }
        }
    }
    return min_value;
}

pub fn snapshotMaxF64(snapshot: *const ReadSnapshot, column_index: usize) TableError!f64 {
    try ensureSnapshotF64Column(snapshot, column_index);
    var seen = false;
    var max_value: f64 = 0.0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const value = try finiteF64(readF64LE(bytes, byte_offset));
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
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

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
        freeFileMeta(allocator, file_meta.*);
        file_meta.* = updated_file;
        updated += local_count;
    }

    owned.epoch = next_epoch;
    try rebuildIndexes(allocator, root_dir, &owned);
    try writeMeta(allocator, root_dir, table_name, owned);
    return updated;
}

pub fn ingestTable(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    data_path: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

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
    try rebuildIndexes(allocator, root_dir, &meta);
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
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

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
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

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
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var best: ?TableMeta = null;
    defer if (best) |*meta| meta.deinit(allocator);

    try scanVersionedRecoveryMetas(allocator, root_dir, table_name, &best);

    const compat_path = try tableMetaPath(allocator, root_dir, table_name);
    defer allocator.free(compat_path);
    try maybeSelectRecoveryMeta(allocator, root_dir, table_name, compat_path, &best);

    const recovered = best orelse return TableError.VerifyFailed;
    try writeMeta(allocator, root_dir, table_name, recovered);
    try cleanupPendingTxMarkers(allocator, root_dir, table_name);
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
    try validateIndexFiles(allocator, root_dir, meta);
    try validateDictFiles(allocator, root_dir, meta);
    try validateBlobStoreFiles(allocator, root_dir, meta);
    return tableInfo(meta);
}

pub fn lockTable(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

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
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadActiveMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    try validateSegmentHashes(allocator, root_dir, owned);
    try validateIndexFiles(allocator, root_dir, owned);
    try validateDictFiles(allocator, root_dir, owned);
    try validateBlobStoreFiles(allocator, root_dir, owned);
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
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

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
    try rebuildIndexes(allocator, root_dir, &owned);
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

test "table segment files record block checksums and old metadata remains readable" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "block_checked_orders";
    try writeFileToTemp(tmp_dir.dir, "block_checked_orders.sadb-schema",
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_QTY_STRIDE = 8 // u64
    );
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "block_checked_orders.sadb-schema",
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_QTY_STRIDE = 8 // u64
    );

    var ids = [_]u64{ 1, 2 };
    var qtys = [_]u64{ 5, 8 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(qtys[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, ids.len, &columns);

    var meta = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer meta.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, FILE_BLOCK_BYTES), meta.segments[0].files[0].block_size);
    try std.testing.expectEqual(@as(usize, 1), meta.segments[0].files[0].block_sha256.len);
    try std.testing.expectEqual(@as(usize, 64), meta.segments[0].files[0].block_sha256[0].len);

    const original_hash = try std.testing.allocator.dupe(u8, meta.segments[0].files[0].block_sha256[0]);
    defer std.testing.allocator.free(original_hash);
    std.testing.allocator.free(meta.segments[0].files[0].block_sha256[0]);
    meta.segments[0].files[0].block_sha256[0] = try std.testing.allocator.dupe(u8, "0000000000000000000000000000000000000000000000000000000000000000");
    try writeMeta(std.testing.allocator, ".", table_name, meta);
    try std.testing.expectError(TableError.VerifyFailed, verifyTable(std.testing.allocator, ".", table_name));

    std.testing.allocator.free(meta.segments[0].files[0].block_sha256[0]);
    meta.segments[0].files[0].block_sha256[0] = try std.testing.allocator.dupe(u8, original_hash);
    try writeMeta(std.testing.allocator, ".", table_name, meta);
    _ = try verifyTable(std.testing.allocator, ".", table_name);

    freeBlockSha256List(std.testing.allocator, meta.segments[0].files[0].block_sha256);
    meta.segments[0].files[0].block_sha256 = try std.testing.allocator.alloc([]const u8, 0);
    meta.segments[0].files[0].block_size = 0;
    try writeMeta(std.testing.allocator, ".", table_name, meta);
    _ = try verifyTable(std.testing.allocator, ".", table_name);
}

test "table index files record block checksums and old metadata remains readable" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "block_checked_indexes";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "block_checked_indexes.sadb-schema",
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_QTY_STRIDE = 8 // u64
    );

    var ids = [_]u64{ 1, 2 };
    var qtys = [_]u64{ 5, 8 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(qtys[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, ids.len, &columns);
    _ = try createU64Index(std.testing.allocator, ".", table_name, 0, true);

    var meta = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer meta.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), meta.indexes.len);
    try std.testing.expectEqual(@as(u64, FILE_BLOCK_BYTES), meta.indexes[0].block_size);
    try std.testing.expectEqual(@as(usize, 1), meta.indexes[0].block_sha256.len);
    try std.testing.expectEqual(@as(usize, 64), meta.indexes[0].block_sha256[0].len);

    const original_hash = try std.testing.allocator.dupe(u8, meta.indexes[0].block_sha256[0]);
    defer std.testing.allocator.free(original_hash);
    std.testing.allocator.free(meta.indexes[0].block_sha256[0]);
    meta.indexes[0].block_sha256[0] = try std.testing.allocator.dupe(u8, "0000000000000000000000000000000000000000000000000000000000000000");
    try writeMeta(std.testing.allocator, ".", table_name, meta);
    try std.testing.expectError(TableError.VerifyFailed, verifyTable(std.testing.allocator, ".", table_name));
    try std.testing.expectError(TableError.VerifyFailed, openReadSnapshot(std.testing.allocator, ".", table_name));

    std.testing.allocator.free(meta.indexes[0].block_sha256[0]);
    meta.indexes[0].block_sha256[0] = try std.testing.allocator.dupe(u8, original_hash);
    try writeMeta(std.testing.allocator, ".", table_name, meta);
    _ = try verifyTable(std.testing.allocator, ".", table_name);
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
    }

    freeBlockSha256List(std.testing.allocator, meta.indexes[0].block_sha256);
    meta.indexes[0].block_sha256 = try std.testing.allocator.alloc([]const u8, 0);
    meta.indexes[0].block_size = 0;
    try writeMeta(std.testing.allocator, ".", table_name, meta);
    _ = try verifyTable(std.testing.allocator, ".", table_name);
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
    }
}

test "table dictionary files record block checksums and old metadata remains readable" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "block_checked_dicts";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "block_checked_dicts.sadb-schema",
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_STATUS_STRIDE = 8 // u64
    );
    _ = try internStringDict(std.testing.allocator, ".", table_name, "status", "active");
    _ = try internStringDict(std.testing.allocator, ".", table_name, "status", "paused");

    var meta = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer meta.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), meta.dicts.len);
    try std.testing.expectEqual(@as(u64, FILE_BLOCK_BYTES), meta.dicts[0].block_size);
    try std.testing.expectEqual(@as(usize, 1), meta.dicts[0].block_sha256.len);
    try std.testing.expectEqual(@as(usize, 64), meta.dicts[0].block_sha256[0].len);

    const original_hash = try std.testing.allocator.dupe(u8, meta.dicts[0].block_sha256[0]);
    defer std.testing.allocator.free(original_hash);
    std.testing.allocator.free(meta.dicts[0].block_sha256[0]);
    meta.dicts[0].block_sha256[0] = try std.testing.allocator.dupe(u8, "1111111111111111111111111111111111111111111111111111111111111111");
    try writeMeta(std.testing.allocator, ".", table_name, meta);
    try std.testing.expectError(TableError.VerifyFailed, verifyTable(std.testing.allocator, ".", table_name));
    try std.testing.expectError(TableError.VerifyFailed, lookupStringDict(std.testing.allocator, ".", table_name, "status", "active"));

    std.testing.allocator.free(meta.dicts[0].block_sha256[0]);
    meta.dicts[0].block_sha256[0] = try std.testing.allocator.dupe(u8, original_hash);
    try writeMeta(std.testing.allocator, ".", table_name, meta);
    _ = try verifyTable(std.testing.allocator, ".", table_name);
    const active = try lookupStringDict(std.testing.allocator, ".", table_name, "status", "active");
    try std.testing.expect(active.found);
    try std.testing.expectEqual(@as(u64, 1), active.id);

    freeBlockSha256List(std.testing.allocator, meta.dicts[0].block_sha256);
    meta.dicts[0].block_sha256 = try std.testing.allocator.alloc([]const u8, 0);
    meta.dicts[0].block_size = 0;
    try writeMeta(std.testing.allocator, ".", table_name, meta);
    _ = try verifyTable(std.testing.allocator, ".", table_name);
    const paused = try lookupStringDict(std.testing.allocator, ".", table_name, "status", "paused");
    try std.testing.expect(paused.found);
    try std.testing.expectEqual(@as(u64, 2), paused.id);
}

test "table string dictionary is persisted snapshotted restored and verified" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "dict_members";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "dict_members.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_STATUS_STRIDE = 8 // u64
    );

    const active = try internStringDict(std.testing.allocator, ".", table_name, "member_status", "active");
    try std.testing.expectEqual(@as(u64, 1), active.id);
    try std.testing.expect(active.inserted);
    try std.testing.expectEqual(@as(u64, 1), active.info.epoch);
    const paused = try internStringDict(std.testing.allocator, ".", table_name, "member_status", "paused");
    try std.testing.expectEqual(@as(u64, 2), paused.id);
    try std.testing.expect(paused.inserted);
    try std.testing.expectEqual(@as(u64, 2), paused.info.epoch);
    const active_again = try internStringDict(std.testing.allocator, ".", table_name, "member_status", "active");
    try std.testing.expectEqual(@as(u64, 1), active_again.id);
    try std.testing.expect(!active_again.inserted);
    try std.testing.expectEqual(@as(u64, 2), active_again.info.epoch);

    const lookup_active = try lookupStringDict(std.testing.allocator, ".", table_name, "member_status", "active");
    try std.testing.expect(lookup_active.found);
    try std.testing.expectEqual(@as(u64, 1), lookup_active.id);
    const lookup_missing = try lookupStringDict(std.testing.allocator, ".", table_name, "member_status", "closed");
    try std.testing.expect(!lookup_missing.found);

    const paused_len = try stringDictValueLen(std.testing.allocator, ".", table_name, "member_status", paused.id);
    try std.testing.expect(paused_len.found);
    try std.testing.expectEqual(@as(u64, 6), paused_len.len);
    var value_buf: [8]u8 = undefined;
    const copied = try copyStringDictValue(std.testing.allocator, ".", table_name, "member_status", paused.id, &value_buf);
    try std.testing.expect(copied.found);
    try std.testing.expectEqual(@as(u64, 6), copied.written);
    try std.testing.expectEqualStrings("paused", value_buf[0..@intCast(copied.written)]);
    var too_small: [4]u8 = undefined;
    try std.testing.expectError(TableError.CursorOverflow, copyStringDictValue(std.testing.allocator, ".", table_name, "member_status", paused.id, &too_small));

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 2), verified.epoch);
    const snap = try snapshotTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 2), snap.epoch);

    const disabled = try internStringDict(std.testing.allocator, ".", table_name, "member_status", "disabled");
    try std.testing.expectEqual(@as(u64, 3), disabled.id);
    const lookup_disabled = try lookupStringDict(std.testing.allocator, ".", table_name, "member_status", "disabled");
    try std.testing.expect(lookup_disabled.found);

    _ = try restoreTable(std.testing.allocator, ".", table_name, snap.epoch);
    const restored_disabled = try lookupStringDict(std.testing.allocator, ".", table_name, "member_status", "disabled");
    try std.testing.expect(!restored_disabled.found);
    const restored_paused = try lookupStringDict(std.testing.allocator, ".", table_name, "member_status", "paused");
    try std.testing.expect(restored_paused.found);
    try std.testing.expectEqual(@as(u64, 2), restored_paused.id);

    var meta = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer meta.deinit(std.testing.allocator);
    const dict_path = try activePath(std.testing.allocator, ".", meta.dicts[0].path);
    defer std.testing.allocator.free(dict_path);
    try writeFile(std.testing.allocator, dict_path, "corrupt");
    try std.testing.expectError(TableError.VerifyFailed, verifyTable(std.testing.allocator, ".", table_name));
}

test "table blob store persists variable bytes and read snapshots are isolated" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "blob_items";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "blob_items.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_NOTE_STRIDE = 8 // blob_handle
    );

    const empty = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "");
    try std.testing.expectEqual(@as(u64, 1), empty.id);
    try std.testing.expectEqual(@as(u64, 1), empty.info.epoch);
    const first = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "first note");
    try std.testing.expectEqual(@as(u64, 2), first.id);
    try std.testing.expectEqual(@as(u64, 2), first.info.epoch);

    var row_bytes: [16]u8 = undefined;
    writeU64LE(&row_bytes, 0, 100);
    writeU64LE(&row_bytes, 8, first.id);
    _ = try insertRawRow(std.testing.allocator, ".", table_name, &row_bytes);

    const read_snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer read_snapshot.destroy();

    const duplicate = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "first note");
    try std.testing.expectEqual(@as(u64, 3), duplicate.id);
    try std.testing.expectEqual(@as(u64, 4), duplicate.info.epoch);

    const empty_len = try blobValueLen(std.testing.allocator, ".", table_name, "notes", empty.id);
    try std.testing.expect(empty_len.found);
    try std.testing.expectEqual(@as(u64, 0), empty_len.len);
    var empty_buf: [0]u8 = .{};
    const copied_empty = try copyBlobValue(std.testing.allocator, ".", table_name, "notes", empty.id, &empty_buf);
    try std.testing.expect(copied_empty.found);
    try std.testing.expectEqual(@as(u64, 0), copied_empty.written);

    const first_len = try blobValueLen(std.testing.allocator, ".", table_name, "notes", first.id);
    try std.testing.expect(first_len.found);
    try std.testing.expectEqual(@as(u64, 10), first_len.len);
    var value_buf: [16]u8 = undefined;
    const copied = try copyBlobValue(std.testing.allocator, ".", table_name, "notes", first.id, &value_buf);
    try std.testing.expect(copied.found);
    try std.testing.expectEqual(@as(u64, 10), copied.written);
    try std.testing.expectEqualStrings("first note", value_buf[0..@intCast(copied.written)]);
    var too_small: [4]u8 = undefined;
    try std.testing.expectError(TableError.CursorOverflow, copyBlobValue(std.testing.allocator, ".", table_name, "notes", first.id, &too_small));

    const snapshot_first_len = try snapshotBlobValueLen(read_snapshot, "notes", first.id);
    try std.testing.expect(snapshot_first_len.found);
    try std.testing.expectEqual(@as(u64, 10), snapshot_first_len.len);
    const snapshot_duplicate_len = try snapshotBlobValueLen(read_snapshot, "notes", duplicate.id);
    try std.testing.expect(!snapshot_duplicate_len.found);

    var projected_row: [16]u8 = undefined;
    try snapshotGetRow(read_snapshot, 0, &projected_row);
    try std.testing.expectEqual(@as(u64, 100), readU64LE(&projected_row, 0));
    try std.testing.expectEqual(first.id, readU64LE(&projected_row, 8));

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 4), verified.epoch);
    const snap = try snapshotTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 4), snap.epoch);

    const after_snapshot = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "after snapshot");
    try std.testing.expectEqual(@as(u64, 4), after_snapshot.id);
    _ = try restoreTable(std.testing.allocator, ".", table_name, snap.epoch);
    const restored_after_snapshot = try blobValueLen(std.testing.allocator, ".", table_name, "notes", after_snapshot.id);
    try std.testing.expect(!restored_after_snapshot.found);
    const restored_duplicate = try blobValueLen(std.testing.allocator, ".", table_name, "notes", duplicate.id);
    try std.testing.expect(restored_duplicate.found);

    var meta = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer meta.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), meta.blobs.len);
    const blob_path = try activePath(std.testing.allocator, ".", meta.blobs[0].path);
    defer std.testing.allocator.free(blob_path);
    try writeFile(std.testing.allocator, blob_path, "corrupt");
    try std.testing.expectError(TableError.VerifyFailed, verifyTable(std.testing.allocator, ".", table_name));
}

test "table blob handle filters exact and contains values" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "blob_filter_items";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "blob_filter_items.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_NOTE_STRIDE = 8 // blob_handle
    );

    const empty = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "");
    const first = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "first note");
    const second = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "second note with details");
    const duplicate = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "first note");

    var row_bytes: [16]u8 = undefined;
    const row_ids = [_]u64{ 100, 101, 102, 103, 104, 105 };
    const note_ids = [_]u64{ first.id, second.id, duplicate.id, empty.id, 999, 0 };
    for (row_ids, note_ids) |row_id, note_id| {
        writeU64LE(&row_bytes, 0, row_id);
        writeU64LE(&row_bytes, 8, note_id);
        _ = try insertRawRow(std.testing.allocator, ".", table_name, &row_bytes);
    }

    try std.testing.expectError(TableError.ConstraintViolation, createBlobEqIndex(std.testing.allocator, ".", table_name, 1, "notes", true));
    const indexed = try createBlobEqIndex(std.testing.allocator, ".", table_name, 1, "notes", false);
    try std.testing.expectEqual(@as(u64, 6), indexed.row_count);
    _ = try verifyTable(std.testing.allocator, ".", table_name);

    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();

    var rows: [8]u64 = undefined;
    const exact = try snapshotFilterBlobEqRows(std.testing.allocator, snapshot, 1, "notes", "first note", 0, 8, &rows);
    try std.testing.expectEqual(@as(u64, 2), exact.total);
    try std.testing.expectEqual(@as(u64, 2), exact.written);
    try std.testing.expectEqual(@as(u64, 0), rows[0]);
    try std.testing.expectEqual(@as(u64, 2), rows[1]);

    const exact_page = try snapshotFilterBlobEqRows(std.testing.allocator, snapshot, 1, "notes", "first note", 1, 1, &rows);
    try std.testing.expectEqual(@as(u64, 2), exact_page.total);
    try std.testing.expectEqual(@as(u64, 1), exact_page.written);
    try std.testing.expectEqual(@as(u64, 2), rows[0]);

    const contains = try snapshotFilterBlobContainsRows(std.testing.allocator, snapshot, 1, "notes", "details", 0, 8, &rows);
    try std.testing.expectEqual(@as(u64, 1), contains.total);
    try std.testing.expectEqual(@as(u64, 1), contains.written);
    try std.testing.expectEqual(@as(u64, 1), rows[0]);

    const candidate_rows = [_]u64{ 2, 1, 0, 5 };
    const candidate_exact = try snapshotFilterRowsBlobEq(std.testing.allocator, snapshot, 1, &candidate_rows, "notes", "first note", 0, 8, &rows);
    try std.testing.expectEqual(@as(u64, 2), candidate_exact.total);
    try std.testing.expectEqual(@as(u64, 2), candidate_exact.written);
    try std.testing.expectEqual(@as(u64, 2), rows[0]);
    try std.testing.expectEqual(@as(u64, 0), rows[1]);

    const candidate_exact_page = try snapshotFilterRowsBlobEq(std.testing.allocator, snapshot, 1, &candidate_rows, "notes", "first note", 1, 1, &rows);
    try std.testing.expectEqual(@as(u64, 2), candidate_exact_page.total);
    try std.testing.expectEqual(@as(u64, 1), candidate_exact_page.written);
    try std.testing.expectEqual(@as(u64, 0), rows[0]);

    const candidate_contains = try snapshotFilterRowsBlobContains(std.testing.allocator, snapshot, 1, &candidate_rows, "notes", "note", 0, 8, &rows);
    try std.testing.expectEqual(@as(u64, 3), candidate_contains.total);
    try std.testing.expectEqual(@as(u64, 3), candidate_contains.written);
    try std.testing.expectEqual(@as(u64, 2), rows[0]);
    try std.testing.expectEqual(@as(u64, 1), rows[1]);
    try std.testing.expectEqual(@as(u64, 0), rows[2]);

    const empty_exact = try snapshotFilterBlobEqRows(std.testing.allocator, snapshot, 1, "notes", "", 0, 8, &rows);
    try std.testing.expectEqual(@as(u64, 1), empty_exact.total);
    try std.testing.expectEqual(@as(u64, 1), empty_exact.written);
    try std.testing.expectEqual(@as(u64, 3), rows[0]);

    const missing_store = try snapshotFilterBlobContainsRows(std.testing.allocator, snapshot, 1, "other_notes", "note", 0, 8, &rows);
    try std.testing.expectEqual(@as(u64, 0), missing_store.total);
    try std.testing.expectEqual(@as(u64, 0), missing_store.written);

    try std.testing.expectError(TableError.InvalidFormat, snapshotFilterBlobEqRows(std.testing.allocator, snapshot, 0, "notes", "first note", 0, 8, &rows));
    const invalid_candidate_rows = [_]u64{999};
    try std.testing.expectError(TableError.InvalidFormat, snapshotFilterRowsBlobEq(std.testing.allocator, snapshot, 1, &invalid_candidate_rows, "notes", "first note", 0, 8, &rows));
}

test "table blob exact index is rebuilt when blob values are appended" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "blob_index_late_values";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "blob_index_late_values.sadb-schema",
        \\#def MAX_ROWS = 4
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_NOTE_STRIDE = 8 // blob_handle
    );

    var row_bytes: [16]u8 = undefined;
    writeU64LE(&row_bytes, 0, 200);
    writeU64LE(&row_bytes, 8, 1);
    _ = try insertRawRow(std.testing.allocator, ".", table_name, &row_bytes);
    _ = try createBlobEqIndex(std.testing.allocator, ".", table_name, 1, "notes", false);

    const late = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "late note");
    try std.testing.expectEqual(@as(u64, 1), late.id);
    _ = try verifyTable(std.testing.allocator, ".", table_name);

    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();

    var rows: [2]u64 = undefined;
    const exact = try snapshotFilterBlobEqRows(std.testing.allocator, snapshot, 1, "notes", "late note", 0, 2, &rows);
    try std.testing.expectEqual(@as(u64, 1), exact.total);
    try std.testing.expectEqual(@as(u64, 1), exact.written);
    try std.testing.expectEqual(@as(u64, 0), rows[0]);
}

test "table blob token index filters ERP text tokens" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "blob_token_items";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "blob_token_items.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_NOTE_STRIDE = 8 // blob_handle
    );

    const note_a = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "Blue Widget SKU-001 urgent");
    const note_b = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "red widget sku_002 standard");
    const note_c = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "invoice paid customer blue");
    const note_d = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "blue widget widget");

    var row_bytes: [16]u8 = undefined;
    const row_ids = [_]u64{ 100, 101, 102, 103 };
    const note_ids = [_]u64{ note_a.id, note_b.id, note_c.id, note_d.id };
    for (row_ids, note_ids) |row_id, note_id| {
        writeU64LE(&row_bytes, 0, row_id);
        writeU64LE(&row_bytes, 8, note_id);
        _ = try insertRawRow(std.testing.allocator, ".", table_name, &row_bytes);
    }

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        var rows: [8]u64 = undefined;
        const fallback = try snapshotFilterBlobTokenRows(std.testing.allocator, snapshot, 1, "notes", "widget", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 3), fallback.total);
        try std.testing.expectEqual(@as(u64, 3), fallback.written);
        try std.testing.expectEqual(@as(u64, 0), rows[0]);
        try std.testing.expectEqual(@as(u64, 1), rows[1]);
        try std.testing.expectEqual(@as(u64, 3), rows[2]);
    }

    const indexed = try createBlobTokenIndex(std.testing.allocator, ".", table_name, 1, "notes");
    try std.testing.expectEqual(@as(u64, 4), indexed.row_count);
    _ = try verifyTable(std.testing.allocator, ".", table_name);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        var rows: [8]u64 = undefined;
        const widget = try snapshotFilterBlobTokenRows(std.testing.allocator, snapshot, 1, "notes", "WIDGET", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 3), widget.total);
        try std.testing.expectEqual(@as(u64, 3), widget.written);
        try std.testing.expectEqual(@as(u64, 0), rows[0]);
        try std.testing.expectEqual(@as(u64, 1), rows[1]);
        try std.testing.expectEqual(@as(u64, 3), rows[2]);

        const candidate_rows = [_]u64{ 3, 2, 1, 0 };
        const candidate_widget = try snapshotFilterRowsBlobToken(std.testing.allocator, snapshot, 1, &candidate_rows, "notes", "WIDGET", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 3), candidate_widget.total);
        try std.testing.expectEqual(@as(u64, 3), candidate_widget.written);
        try std.testing.expectEqual(@as(u64, 3), rows[0]);
        try std.testing.expectEqual(@as(u64, 1), rows[1]);
        try std.testing.expectEqual(@as(u64, 0), rows[2]);

        const candidate_widget_page = try snapshotFilterRowsBlobToken(std.testing.allocator, snapshot, 1, &candidate_rows, "notes", "widget", 1, 1, &rows);
        try std.testing.expectEqual(@as(u64, 3), candidate_widget_page.total);
        try std.testing.expectEqual(@as(u64, 1), candidate_widget_page.written);
        try std.testing.expectEqual(@as(u64, 1), rows[0]);

        const widget_page = try snapshotFilterBlobTokenRows(std.testing.allocator, snapshot, 1, "notes", "widget", 1, 1, &rows);
        try std.testing.expectEqual(@as(u64, 3), widget_page.total);
        try std.testing.expectEqual(@as(u64, 1), widget_page.written);
        try std.testing.expectEqual(@as(u64, 1), rows[0]);

        const sku = try snapshotFilterBlobTokenRows(std.testing.allocator, snapshot, 1, "notes", "sku", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 1), sku.total);
        try std.testing.expectEqual(@as(u64, 0), rows[0]);
        const sku_002 = try snapshotFilterBlobTokenRows(std.testing.allocator, snapshot, 1, "notes", "SKU_002", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 1), sku_002.total);
        try std.testing.expectEqual(@as(u64, 1), rows[0]);

        try std.testing.expectError(TableError.InvalidFormat, snapshotFilterBlobTokenRows(std.testing.allocator, snapshot, 1, "notes", "two words", 0, 8, &rows));
    }

    writeU64LE(&row_bytes, 0, 104);
    writeU64LE(&row_bytes, 8, 5);
    _ = try insertRawRow(std.testing.allocator, ".", table_name, &row_bytes);
    const late = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "late searchable note");
    try std.testing.expectEqual(@as(u64, 5), late.id);
    _ = try verifyTable(std.testing.allocator, ".", table_name);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        var rows: [8]u64 = undefined;
        const searchable = try snapshotFilterBlobTokenRows(std.testing.allocator, snapshot, 1, "notes", "searchable", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 1), searchable.total);
        try std.testing.expectEqual(@as(u64, 1), searchable.written);
        try std.testing.expectEqual(@as(u64, 4), rows[0]);
    }
}

test "table blob prefix index filters ERP text prefixes" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "blob_prefix_items";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "blob_prefix_items.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_NOTE_STRIDE = 8 // blob_handle
    );

    const note_a = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "Blue Widget SKU-001 urgent");
    const note_b = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "red widget sku_002 standard");
    const note_c = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "invoice paid customer blue");
    const note_d = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "blue widget widget");

    var row_bytes: [16]u8 = undefined;
    const row_ids = [_]u64{ 100, 101, 102, 103 };
    const note_ids = [_]u64{ note_a.id, note_b.id, note_c.id, note_d.id };
    for (row_ids, note_ids) |row_id, note_id| {
        writeU64LE(&row_bytes, 0, row_id);
        writeU64LE(&row_bytes, 8, note_id);
        _ = try insertRawRow(std.testing.allocator, ".", table_name, &row_bytes);
    }

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        var rows: [8]u64 = undefined;
        const fallback = try snapshotFilterBlobPrefixRows(std.testing.allocator, snapshot, 1, "notes", "wid", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 3), fallback.total);
        try std.testing.expectEqual(@as(u64, 3), fallback.written);
        try std.testing.expectEqual(@as(u64, 0), rows[0]);
        try std.testing.expectEqual(@as(u64, 1), rows[1]);
        try std.testing.expectEqual(@as(u64, 3), rows[2]);
    }

    const indexed = try createBlobPrefixIndex(std.testing.allocator, ".", table_name, 1, "notes");
    try std.testing.expectEqual(@as(u64, 4), indexed.row_count);
    _ = try verifyTable(std.testing.allocator, ".", table_name);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        var rows: [8]u64 = undefined;
        const widget = try snapshotFilterBlobPrefixRows(std.testing.allocator, snapshot, 1, "notes", "WID", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 3), widget.total);
        try std.testing.expectEqual(@as(u64, 3), widget.written);
        try std.testing.expectEqual(@as(u64, 0), rows[0]);
        try std.testing.expectEqual(@as(u64, 1), rows[1]);
        try std.testing.expectEqual(@as(u64, 3), rows[2]);

        const candidate_rows = [_]u64{ 2, 1, 0 };
        const candidate_widget = try snapshotFilterRowsBlobPrefix(std.testing.allocator, snapshot, 1, &candidate_rows, "notes", "WID", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 2), candidate_widget.total);
        try std.testing.expectEqual(@as(u64, 2), candidate_widget.written);
        try std.testing.expectEqual(@as(u64, 1), rows[0]);
        try std.testing.expectEqual(@as(u64, 0), rows[1]);

        const widget_page = try snapshotFilterBlobPrefixRows(std.testing.allocator, snapshot, 1, "notes", "wid", 1, 1, &rows);
        try std.testing.expectEqual(@as(u64, 3), widget_page.total);
        try std.testing.expectEqual(@as(u64, 1), widget_page.written);
        try std.testing.expectEqual(@as(u64, 1), rows[0]);

        const blue = try snapshotFilterBlobPrefixRows(std.testing.allocator, snapshot, 1, "notes", "blu", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 3), blue.total);
        try std.testing.expectEqual(@as(u64, 0), rows[0]);
        try std.testing.expectEqual(@as(u64, 2), rows[1]);
        try std.testing.expectEqual(@as(u64, 3), rows[2]);

        const sku = try snapshotFilterBlobPrefixRows(std.testing.allocator, snapshot, 1, "notes", "sku_", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 1), sku.total);
        try std.testing.expectEqual(@as(u64, 1), rows[0]);

        try std.testing.expectError(TableError.InvalidFormat, snapshotFilterBlobPrefixRows(std.testing.allocator, snapshot, 1, "notes", "two words", 0, 8, &rows));
    }

    writeU64LE(&row_bytes, 0, 104);
    writeU64LE(&row_bytes, 8, 5);
    _ = try insertRawRow(std.testing.allocator, ".", table_name, &row_bytes);
    const late = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "late searchable note");
    try std.testing.expectEqual(@as(u64, 5), late.id);
    _ = try verifyTable(std.testing.allocator, ".", table_name);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        var rows: [8]u64 = undefined;
        const searchable = try snapshotFilterBlobPrefixRows(std.testing.allocator, snapshot, 1, "notes", "sear", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 1), searchable.total);
        try std.testing.expectEqual(@as(u64, 1), searchable.written);
        try std.testing.expectEqual(@as(u64, 4), rows[0]);
    }
}

test "table blob contains index filters ERP substrings" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "blob_contains_items";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "blob_contains_items.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_NOTE_STRIDE = 8 // blob_handle
    );

    const note_a = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "Blue Widget SKU-001 urgent");
    const note_b = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "red widget sku_002 standard");
    const note_c = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "invoice paid customer blue");
    const note_d = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "manual customer WID-GAP note");

    var row_bytes: [16]u8 = undefined;
    const row_ids = [_]u64{ 100, 101, 102, 103 };
    const note_ids = [_]u64{ note_a.id, note_b.id, note_c.id, note_d.id };
    for (row_ids, note_ids) |row_id, note_id| {
        writeU64LE(&row_bytes, 0, row_id);
        writeU64LE(&row_bytes, 8, note_id);
        _ = try insertRawRow(std.testing.allocator, ".", table_name, &row_bytes);
    }

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        var rows: [8]u64 = undefined;
        const fallback = try snapshotFilterBlobContainsRows(std.testing.allocator, snapshot, 1, "notes", "dget SKU", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 1), fallback.total);
        try std.testing.expectEqual(@as(u64, 1), fallback.written);
        try std.testing.expectEqual(@as(u64, 0), rows[0]);
    }

    const indexed = try createBlobContainsIndex(std.testing.allocator, ".", table_name, 1, "notes");
    try std.testing.expectEqual(@as(u64, 4), indexed.row_count);
    _ = try verifyTable(std.testing.allocator, ".", table_name);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        var rows: [8]u64 = undefined;
        const widget_sku = try snapshotFilterBlobContainsRows(std.testing.allocator, snapshot, 1, "notes", "dget SKU", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 1), widget_sku.total);
        try std.testing.expectEqual(@as(u64, 1), widget_sku.written);
        try std.testing.expectEqual(@as(u64, 0), rows[0]);

        const customer = try snapshotFilterBlobContainsRows(std.testing.allocator, snapshot, 1, "notes", "customer", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 2), customer.total);
        try std.testing.expectEqual(@as(u64, 2), customer.written);
        try std.testing.expectEqual(@as(u64, 2), rows[0]);
        try std.testing.expectEqual(@as(u64, 3), rows[1]);

        const customer_page = try snapshotFilterBlobContainsRows(std.testing.allocator, snapshot, 1, "notes", "customer", 1, 1, &rows);
        try std.testing.expectEqual(@as(u64, 2), customer_page.total);
        try std.testing.expectEqual(@as(u64, 1), customer_page.written);
        try std.testing.expectEqual(@as(u64, 3), rows[0]);

        const short_needle = try snapshotFilterBlobContainsRows(std.testing.allocator, snapshot, 1, "notes", "ed", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 1), short_needle.total);
        try std.testing.expectEqual(@as(u64, 1), short_needle.written);
        try std.testing.expectEqual(@as(u64, 1), rows[0]);

        const empty_needle = try snapshotFilterBlobContainsRows(std.testing.allocator, snapshot, 1, "notes", "", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 4), empty_needle.total);
        try std.testing.expectEqual(@as(u64, 4), empty_needle.written);
    }

    writeU64LE(&row_bytes, 0, 104);
    writeU64LE(&row_bytes, 8, 5);
    _ = try insertRawRow(std.testing.allocator, ".", table_name, &row_bytes);
    const late = try putBlobValue(std.testing.allocator, ".", table_name, "notes", "late searchable note");
    try std.testing.expectEqual(@as(u64, 5), late.id);
    _ = try verifyTable(std.testing.allocator, ".", table_name);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        var rows: [8]u64 = undefined;
        const searchable = try snapshotFilterBlobContainsRows(std.testing.allocator, snapshot, 1, "notes", "searchable", 0, 8, &rows);
        try std.testing.expectEqual(@as(u64, 1), searchable.total);
        try std.testing.expectEqual(@as(u64, 1), searchable.written);
        try std.testing.expectEqual(@as(u64, 4), rows[0]);
    }
}

test "table persistent u64 pair index supports ERP composite lookups" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "order_lines";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "order_lines.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ORDER_ID_STRIDE = 8 // u64
        \\#def COL_LINE_NO_STRIDE = 8 // u64
        \\#def COL_SKU_ID_STRIDE = 8 // u64
        \\#def COL_QTY_STRIDE = 8 // u64
    );

    var order_ids = [_]u64{ 10, 10, 11, 10 };
    var line_nos = [_]u64{ 1, 2, 1, 3 };
    var sku_ids = [_]u64{ 100, 200, 300, 400 };
    var qtys = [_]u64{ 5, 7, 9, 11 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(order_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(line_nos[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(sku_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(qtys[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, order_ids.len, &columns);
    const indexed = try createU64PairIndex(std.testing.allocator, ".", table_name, 0, 1, true);
    try std.testing.expectEqual(@as(u64, 4), indexed.row_count);
    try std.testing.expectEqual(@as(u64, 2), indexed.epoch);

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 4), verified.row_count);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        const found = try snapshotFindU64Pair(snapshot, 0, 1, 10, 2);
        try std.testing.expect(found.found);
        try std.testing.expectEqual(@as(u64, 1), found.row_index);
        try std.testing.expectEqual(@as(u64, 7), try snapshotGetU64(snapshot, 3, found.row_index));

        var range_rows = [_]u64{ 99, 99, 99, 99 };
        const range = try snapshotRangeU64PairRows(snapshot, 0, 1, 10, 1, 3, 0, 4, &range_rows);
        try std.testing.expectEqual(@as(u64, 3), range.total);
        try std.testing.expectEqual(@as(u64, 3), range.written);
        try std.testing.expectEqual(@as(u64, 0), range_rows[0]);
        try std.testing.expectEqual(@as(u64, 1), range_rows[1]);
        try std.testing.expectEqual(@as(u64, 3), range_rows[2]);

        const page = try snapshotRangeU64PairRows(snapshot, 0, 1, 10, 1, 3, 1, 1, &range_rows);
        try std.testing.expectEqual(@as(u64, 3), page.total);
        try std.testing.expectEqual(@as(u64, 1), page.written);
        try std.testing.expectEqual(@as(u64, 1), range_rows[0]);

        const key1_rows = try snapshotFilterU64PairKey1Rows(snapshot, 0, 1, 10, 0, 4, &range_rows);
        try std.testing.expectEqual(@as(u64, 3), key1_rows.total);
        try std.testing.expectEqual(@as(u64, 3), key1_rows.written);
        try std.testing.expectEqual(@as(u64, 0), range_rows[0]);
        try std.testing.expectEqual(@as(u64, 1), range_rows[1]);
        try std.testing.expectEqual(@as(u64, 3), range_rows[2]);

        const key1_page = try snapshotFilterU64PairKey1Rows(snapshot, 0, 1, 10, 2, 1, &range_rows);
        try std.testing.expectEqual(@as(u64, 3), key1_page.total);
        try std.testing.expectEqual(@as(u64, 1), key1_page.written);
        try std.testing.expectEqual(@as(u64, 3), range_rows[0]);

        const key1_missing = try snapshotFilterU64PairKey1Rows(snapshot, 0, 1, 99, 0, 4, &range_rows);
        try std.testing.expectEqual(@as(u64, 0), key1_missing.total);
        try std.testing.expectEqual(@as(u64, 0), key1_missing.written);
        try std.testing.expectError(TableError.InvalidFormat, snapshotFindU64Pair(snapshot, 1, 0, 2, 10));
    }

    var duplicate_row: [32]u8 = undefined;
    writeU64LE(&duplicate_row, 0, 10);
    writeU64LE(&duplicate_row, 8, 2);
    writeU64LE(&duplicate_row, 16, 999);
    writeU64LE(&duplicate_row, 24, 99);
    try std.testing.expectError(TableError.ConstraintViolation, insertRawRow(std.testing.allocator, ".", table_name, &duplicate_row));
    const after_duplicate = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 4), after_duplicate.row_count);

    var meta = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer meta.deinit(std.testing.allocator);
    const index_path = try activePath(std.testing.allocator, ".", meta.indexes[0].path);
    defer std.testing.allocator.free(index_path);
    try writeFile(std.testing.allocator, index_path, "corrupt");
    try std.testing.expectError(TableError.VerifyFailed, verifyTable(std.testing.allocator, ".", table_name));
}

test "table u64 pair key row writes update upsert and delete" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "pair_write_lines";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "pair_write_lines.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ORDER_ID_STRIDE = 8 // u64
        \\#def COL_LINE_NO_STRIDE = 8 // u64
        \\#def COL_QTY_STRIDE = 8 // u64
    );

    var order_ids = [_]u64{ 10, 10, 11 };
    var line_nos = [_]u64{ 1, 2, 1 };
    var qtys = [_]u64{ 5, 7, 9 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(order_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(line_nos[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(qtys[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, order_ids.len, &columns);
    _ = try createU64PairIndex(std.testing.allocator, ".", table_name, 0, 1, true);

    var row: [24]u8 = undefined;
    writeU64LE(&row, 0, 10);
    writeU64LE(&row, 8, 2);
    writeU64LE(&row, 16, 70);
    const direct_update = try updateRawRowU64PairKey(std.testing.allocator, ".", table_name, 0, 1, 10, 2, &row);
    try std.testing.expectEqual(@as(u64, 3), direct_update.row_count);

    writeU64LE(&row, 0, 99);
    writeU64LE(&row, 8, 1);
    writeU64LE(&row, 16, 990);
    try std.testing.expectError(TableError.NotFound, updateRawRowU64PairKey(std.testing.allocator, ".", table_name, 0, 1, 99, 1, &row));

    writeU64LE(&row, 0, 10);
    writeU64LE(&row, 8, 3);
    writeU64LE(&row, 16, 30);
    try std.testing.expectError(TableError.InvalidFormat, updateRawRowU64PairKey(std.testing.allocator, ".", table_name, 0, 1, 10, 2, &row));

    writeU64LE(&row, 0, 10);
    writeU64LE(&row, 8, 2);
    writeU64LE(&row, 16, 71);
    const direct_upsert_existing = try upsertRawRowU64PairKey(std.testing.allocator, ".", table_name, 0, 1, 10, 2, &row);
    try std.testing.expect(!direct_upsert_existing.inserted);

    writeU64LE(&row, 0, 10);
    writeU64LE(&row, 8, 3);
    writeU64LE(&row, 16, 11);
    const direct_upsert_new = try upsertRawRowU64PairKey(std.testing.allocator, ".", table_name, 0, 1, 10, 3, &row);
    try std.testing.expect(direct_upsert_new.inserted);
    try std.testing.expectEqual(@as(u64, 4), direct_upsert_new.info.row_count);

    const direct_delete = try deleteU64PairKey(std.testing.allocator, ".", table_name, 0, 1, 11, 1);
    try std.testing.expectEqual(@as(u64, 3), direct_delete.row_count);
    try std.testing.expectError(TableError.NotFound, deleteU64PairKey(std.testing.allocator, ".", table_name, 0, 1, 11, 1));

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        const found = try snapshotFindU64Pair(snapshot, 0, 1, 10, 2);
        try std.testing.expect(found.found);
        try std.testing.expectEqual(@as(u64, 71), try snapshotGetU64(snapshot, 2, found.row_index));
        const deleted = try snapshotFindU64Pair(snapshot, 0, 1, 11, 1);
        try std.testing.expect(!deleted.found);
    }

    var tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    writeU64LE(&row, 0, 10);
    writeU64LE(&row, 8, 1);
    writeU64LE(&row, 16, 50);
    const tx_upsert_existing = try writeTransactionUpsertRawRowU64PairKey(tx, 0, 1, 10, 1, &row);
    try std.testing.expect(!tx_upsert_existing.inserted);

    writeU64LE(&row, 0, 99);
    writeU64LE(&row, 8, 1);
    writeU64LE(&row, 16, 990);
    try std.testing.expectError(TableError.NotFound, writeTransactionUpdateRawRowU64PairKey(tx, 0, 1, 99, 1, &row));

    writeU64LE(&row, 0, 10);
    writeU64LE(&row, 8, 3);
    writeU64LE(&row, 16, 13);
    _ = try writeTransactionUpdateRawRowU64PairKey(tx, 0, 1, 10, 3, &row);

    writeU64LE(&row, 0, 12);
    writeU64LE(&row, 8, 1);
    writeU64LE(&row, 16, 21);
    const tx_upsert_new = try writeTransactionUpsertRawRowU64PairKey(tx, 0, 1, 12, 1, &row);
    try std.testing.expect(tx_upsert_new.inserted);
    _ = try writeTransactionDeleteU64PairKey(tx, 0, 1, 10, 2);

    const committed = try commitWriteTransaction(std.testing.allocator, tx);
    destroyWriteTransaction(std.testing.allocator, tx);
    try std.testing.expectEqual(@as(u64, 3), committed.row_count);

    tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    writeU64LE(&row, 0, 99);
    writeU64LE(&row, 8, 1);
    writeU64LE(&row, 16, 990);
    _ = try writeTransactionUpsertRawRowU64PairKey(tx, 0, 1, 99, 1, &row);
    destroyWriteTransaction(std.testing.allocator, tx);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 3), snapshot.row_count);
        const line1 = try snapshotFindU64Pair(snapshot, 0, 1, 10, 1);
        try std.testing.expect(line1.found);
        try std.testing.expectEqual(@as(u64, 50), try snapshotGetU64(snapshot, 2, line1.row_index));
        const line2 = try snapshotFindU64Pair(snapshot, 0, 1, 10, 2);
        try std.testing.expect(!line2.found);
        const line3 = try snapshotFindU64Pair(snapshot, 0, 1, 10, 3);
        try std.testing.expect(line3.found);
        try std.testing.expectEqual(@as(u64, 13), try snapshotGetU64(snapshot, 2, line3.row_index));
        const new_line = try snapshotFindU64Pair(snapshot, 0, 1, 12, 1);
        try std.testing.expect(new_line.found);
        try std.testing.expectEqual(@as(u64, 21), try snapshotGetU64(snapshot, 2, new_line.row_index));
        const rolled_back = try snapshotFindU64Pair(snapshot, 0, 1, 99, 1);
        try std.testing.expect(!rolled_back.found);
    }
}

test "table persistent u64 i64 pair index supports ERP date lookups" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "customer_orders";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "customer_orders.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_CUSTOMER_ID_STRIDE = 8 // u64
        \\#def COL_ORDER_DAY_STRIDE = 8 // i64
        \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64
    );

    var customer_ids = [_]u64{ 7, 7, 7, 8, 7 };
    var order_days = [_]i64{ -5, 0, 10, -3, 20 };
    var totals = [_]i64{ 1000, 2000, 3000, 4000, 5000 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(customer_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(order_days[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(totals[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, customer_ids.len, &columns);
    const indexed = try createU64I64PairIndex(std.testing.allocator, ".", table_name, 0, 1, true);
    try std.testing.expectEqual(@as(u64, 5), indexed.row_count);
    try std.testing.expectEqual(@as(u64, 2), indexed.epoch);

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 5), verified.row_count);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        const found = try snapshotFindU64I64Pair(snapshot, 0, 1, 7, -5);
        try std.testing.expect(found.found);
        try std.testing.expectEqual(@as(u64, 0), found.row_index);
        try std.testing.expectEqual(@as(i64, 1000), try snapshotGetI64(snapshot, 2, found.row_index));

        var range_rows = [_]u64{ 99, 99, 99, 99 };
        const range = try snapshotRangeU64I64PairRows(snapshot, 0, 1, 7, -5, 10, 0, 4, &range_rows);
        try std.testing.expectEqual(@as(u64, 3), range.total);
        try std.testing.expectEqual(@as(u64, 3), range.written);
        try std.testing.expectEqual(@as(u64, 0), range_rows[0]);
        try std.testing.expectEqual(@as(u64, 1), range_rows[1]);
        try std.testing.expectEqual(@as(u64, 2), range_rows[2]);

        const page = try snapshotRangeU64I64PairRows(snapshot, 0, 1, 7, -5, 10, 1, 1, &range_rows);
        try std.testing.expectEqual(@as(u64, 3), page.total);
        try std.testing.expectEqual(@as(u64, 1), page.written);
        try std.testing.expectEqual(@as(u64, 1), range_rows[0]);

        const key1_rows = try snapshotFilterU64I64PairKey1Rows(snapshot, 0, 1, 7, 0, 4, &range_rows);
        try std.testing.expectEqual(@as(u64, 4), key1_rows.total);
        try std.testing.expectEqual(@as(u64, 4), key1_rows.written);
        try std.testing.expectEqual(@as(u64, 0), range_rows[0]);
        try std.testing.expectEqual(@as(u64, 1), range_rows[1]);
        try std.testing.expectEqual(@as(u64, 2), range_rows[2]);
        try std.testing.expectEqual(@as(u64, 4), range_rows[3]);

        const missing = try snapshotRangeU64I64PairRows(snapshot, 0, 1, 7, -20, -10, 0, 4, &range_rows);
        try std.testing.expectEqual(@as(u64, 0), missing.total);
        try std.testing.expectEqual(@as(u64, 0), missing.written);
        try std.testing.expectError(TableError.InvalidFormat, snapshotFindU64I64Pair(snapshot, 1, 0, 7, -5));
    }

    var duplicate_row: [24]u8 = undefined;
    writeU64LE(&duplicate_row, 0, 7);
    writeI64LE(&duplicate_row, 8, 0);
    writeI64LE(&duplicate_row, 16, 9999);
    try std.testing.expectError(TableError.ConstraintViolation, insertRawRow(std.testing.allocator, ".", table_name, &duplicate_row));
    const after_duplicate = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 5), after_duplicate.row_count);
}

test "table filters candidate rows for ERP composite predicates" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "erp_candidate_filters";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "erp_candidate_filters.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_CUSTOMER_ID_STRIDE = 8 // u64
        \\#def COL_ORDER_DAY_STRIDE = 8 // i64 date
        \\#def COL_STATUS_ID_STRIDE = 8 // u64
        \\#def COL_POSTED_STRIDE = 1 // u8 bool
        \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64 decimal(2)
        \\#def COL_CHANNEL_ID_STRIDE = 4 // u32
        \\#def COL_ADJUSTMENT_STRIDE = 4 // i32
        \\#def COL_PRIORITY_STRIDE = 1 // u8
        \\#def COL_SIGNED_FLAG_STRIDE = 1 // i8
        \\#def COL_WAREHOUSE_ID_STRIDE = 2 // u16
        \\#def COL_QTY_DELTA_STRIDE = 2 // i16
    );

    var customer_ids = [_]u64{ 7, 7, 7, 8, 7, 7 };
    var order_days = [_]i64{ -5, 0, 10, -3, 20, 25 };
    var status_ids = [_]u64{ 1, 2, 2, 2, 1, 2 };
    var posted = [_]u8{ 1, 1, 0, 1, 1, 1 };
    var totals = [_]i64{ 1000, 2000, 3000, 4000, 5000, 7000 };
    var channel_ids = [_]u32{ 10, 20, 20, 30, 10, 40 };
    var adjustments = [_]i32{ -3, 5, 7, 9, -1, 11 };
    var priorities = [_]u8{ 1, 2, 3, 1, 2, 3 };
    var signed_flags = [_]i8{ -1, 0, 1, 0, -1, 1 };
    var warehouse_ids = [_]u16{ 100, 200, 200, 300, 100, 200 };
    var qty_deltas = [_]i16{ -5, 10, 20, 30, -15, 40 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(customer_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(order_days[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(status_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(posted[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(totals[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(channel_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(adjustments[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(priorities[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(signed_flags[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(warehouse_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(qty_deltas[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, customer_ids.len, &columns);
    _ = try createU64I64PairIndex(std.testing.allocator, ".", table_name, 0, 1, true);

    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();

    var candidate_rows = [_]u64{ 99, 99, 99, 99, 99, 99 };
    const candidate_result = try snapshotRangeU64I64PairRows(snapshot, 0, 1, 7, -5, 25, 0, candidate_rows.len, &candidate_rows);
    try std.testing.expectEqual(@as(u64, 5), candidate_result.total);
    try std.testing.expectEqual(@as(u64, 5), candidate_result.written);

    const candidate_len: usize = @intCast(candidate_result.written);
    const original_candidate_rows = candidate_rows;
    const status_result = try snapshotFilterRowsU64Range(snapshot, 2, candidate_rows[0..candidate_len], 2, 2, 0, candidate_rows.len, &candidate_rows);
    try std.testing.expectEqual(@as(u64, 3), status_result.total);
    try std.testing.expectEqual(@as(u64, 3), status_result.written);
    try std.testing.expectEqual(@as(u64, 1), candidate_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), candidate_rows[1]);
    try std.testing.expectEqual(@as(u64, 5), candidate_rows[2]);

    var filtered_rows = [_]u64{ 99, 99, 99, 99 };
    const status_page = try snapshotFilterRowsU64Range(snapshot, 2, original_candidate_rows[0..candidate_len], 2, 2, 1, 1, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 3), status_page.total);
    try std.testing.expectEqual(@as(u64, 1), status_page.written);
    try std.testing.expectEqual(@as(u64, 2), filtered_rows[0]);

    const status_len: usize = @intCast(status_result.written);
    var date_candidate_rows = [_]u64{ 99, 99, 99, 99, 99, 99 };
    const date_candidate_result = try snapshotFilterRowsI64Range(snapshot, 1, original_candidate_rows[0..candidate_len], 0, 20, 0, date_candidate_rows.len, &date_candidate_rows);
    try std.testing.expectEqual(@as(u64, 3), date_candidate_result.total);
    try std.testing.expectEqual(@as(u64, 3), date_candidate_result.written);
    try std.testing.expectEqual(@as(u64, 1), date_candidate_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), date_candidate_rows[1]);
    try std.testing.expectEqual(@as(u64, 4), date_candidate_rows[2]);

    const date_candidate_len: usize = @intCast(date_candidate_result.written);
    const intersect_result = try snapshotIntersectRows(std.testing.allocator, snapshot, candidate_rows[0..status_len], date_candidate_rows[0..date_candidate_len], 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 2), intersect_result.total);
    try std.testing.expectEqual(@as(u64, 2), intersect_result.written);
    try std.testing.expectEqual(@as(u64, 1), filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered_rows[1]);

    const intersect_page = try snapshotIntersectRows(std.testing.allocator, snapshot, candidate_rows[0..status_len], date_candidate_rows[0..date_candidate_len], 1, 1, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 2), intersect_page.total);
    try std.testing.expectEqual(@as(u64, 1), intersect_page.written);
    try std.testing.expectEqual(@as(u64, 2), filtered_rows[0]);

    const union_result = try snapshotUnionRows(std.testing.allocator, snapshot, candidate_rows[0..status_len], date_candidate_rows[0..date_candidate_len], 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 4), union_result.total);
    try std.testing.expectEqual(@as(u64, 4), union_result.written);
    try std.testing.expectEqual(@as(u64, 1), filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered_rows[1]);
    try std.testing.expectEqual(@as(u64, 5), filtered_rows[2]);
    try std.testing.expectEqual(@as(u64, 4), filtered_rows[3]);

    const union_page = try snapshotUnionRows(std.testing.allocator, snapshot, candidate_rows[0..status_len], date_candidate_rows[0..date_candidate_len], 2, 2, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 4), union_page.total);
    try std.testing.expectEqual(@as(u64, 2), union_page.written);
    try std.testing.expectEqual(@as(u64, 5), filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 4), filtered_rows[1]);

    const except_result = try snapshotExceptRows(std.testing.allocator, snapshot, candidate_rows[0..status_len], date_candidate_rows[0..date_candidate_len], 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 1), except_result.total);
    try std.testing.expectEqual(@as(u64, 1), except_result.written);
    try std.testing.expectEqual(@as(u64, 5), filtered_rows[0]);

    var duplicate_left_rows = [_]u64{ 1, 1, 2 };
    var duplicate_right_rows = [_]u64{ 2, 4, 4 };
    const union_dedup = try snapshotUnionRows(std.testing.allocator, snapshot, &duplicate_left_rows, &duplicate_right_rows, 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 3), union_dedup.total);
    try std.testing.expectEqual(@as(u64, 3), union_dedup.written);
    try std.testing.expectEqual(@as(u64, 1), filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered_rows[1]);
    try std.testing.expectEqual(@as(u64, 4), filtered_rows[2]);

    const invalid_intersect_rows = [_]u64{999};
    try std.testing.expectError(TableError.InvalidFormat, snapshotIntersectRows(std.testing.allocator, snapshot, &invalid_intersect_rows, date_candidate_rows[0..date_candidate_len], 0, filtered_rows.len, &filtered_rows));
    try std.testing.expectError(TableError.InvalidFormat, snapshotUnionRows(std.testing.allocator, snapshot, &invalid_intersect_rows, date_candidate_rows[0..date_candidate_len], 0, filtered_rows.len, &filtered_rows));
    try std.testing.expectError(TableError.InvalidFormat, snapshotExceptRows(std.testing.allocator, snapshot, candidate_rows[0..status_len], &invalid_intersect_rows, 0, filtered_rows.len, &filtered_rows));

    const status_stats = try snapshotStatsRowsU64(snapshot, 2, candidate_rows[0..status_len]);
    try std.testing.expectEqual(@as(u64, 3), status_stats.count);
    try std.testing.expectEqual(@as(u64, 6), status_stats.sum);
    try std.testing.expectEqual(@as(u64, 2), status_stats.min);
    try std.testing.expectEqual(@as(u64, 2), status_stats.max);

    const amount_stats = try snapshotStatsRowsI64(snapshot, 4, candidate_rows[0..status_len]);
    try std.testing.expectEqual(@as(u64, 3), amount_stats.count);
    try std.testing.expectEqual(@as(i64, 12000), amount_stats.sum);
    try std.testing.expectEqual(@as(i64, 2000), amount_stats.min);
    try std.testing.expectEqual(@as(i64, 7000), amount_stats.max);

    var sorted_rows = [_]u64{ 99, 99, 99, 99, 99, 99 };
    const status_sort = try snapshotSortRowsU64(std.testing.allocator, snapshot, 2, original_candidate_rows[0..candidate_len], true, 0, sorted_rows.len, &sorted_rows);
    try std.testing.expectEqual(@as(u64, 5), status_sort.total);
    try std.testing.expectEqual(@as(u64, 5), status_sort.written);
    try std.testing.expectEqual(@as(u64, 1), sorted_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), sorted_rows[1]);
    try std.testing.expectEqual(@as(u64, 5), sorted_rows[2]);
    try std.testing.expectEqual(@as(u64, 0), sorted_rows[3]);
    try std.testing.expectEqual(@as(u64, 4), sorted_rows[4]);

    const amount_sort = try snapshotSortRowsI64(std.testing.allocator, snapshot, 4, candidate_rows[0..status_len], true, 0, sorted_rows.len, &sorted_rows);
    try std.testing.expectEqual(@as(u64, 3), amount_sort.total);
    try std.testing.expectEqual(@as(u64, 3), amount_sort.written);
    try std.testing.expectEqual(@as(u64, 5), sorted_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), sorted_rows[1]);
    try std.testing.expectEqual(@as(u64, 1), sorted_rows[2]);

    const amount_page = try snapshotSortRowsI64(std.testing.allocator, snapshot, 4, candidate_rows[0..status_len], true, 1, 1, &sorted_rows);
    try std.testing.expectEqual(@as(u64, 3), amount_page.total);
    try std.testing.expectEqual(@as(u64, 1), amount_page.written);
    try std.testing.expectEqual(@as(u64, 2), sorted_rows[0]);

    const channel_sort = try snapshotSortRowsU32(std.testing.allocator, snapshot, 5, original_candidate_rows[0..candidate_len], true, 0, sorted_rows.len, &sorted_rows);
    try std.testing.expectEqual(@as(u64, 5), channel_sort.total);
    try std.testing.expectEqual(@as(u64, 5), channel_sort.written);
    try std.testing.expectEqual(@as(u64, 5), sorted_rows[0]);
    try std.testing.expectEqual(@as(u64, 1), sorted_rows[1]);
    try std.testing.expectEqual(@as(u64, 2), sorted_rows[2]);
    try std.testing.expectEqual(@as(u64, 0), sorted_rows[3]);
    try std.testing.expectEqual(@as(u64, 4), sorted_rows[4]);

    const adjustment_sort = try snapshotSortRowsI32(std.testing.allocator, snapshot, 6, original_candidate_rows[0..candidate_len], false, 0, sorted_rows.len, &sorted_rows);
    try std.testing.expectEqual(@as(u64, 5), adjustment_sort.total);
    try std.testing.expectEqual(@as(u64, 5), adjustment_sort.written);
    try std.testing.expectEqual(@as(u64, 0), sorted_rows[0]);
    try std.testing.expectEqual(@as(u64, 4), sorted_rows[1]);
    try std.testing.expectEqual(@as(u64, 1), sorted_rows[2]);
    try std.testing.expectEqual(@as(u64, 2), sorted_rows[3]);
    try std.testing.expectEqual(@as(u64, 5), sorted_rows[4]);

    const priority_sort = try snapshotSortRowsU8(std.testing.allocator, snapshot, 7, original_candidate_rows[0..candidate_len], true, 0, sorted_rows.len, &sorted_rows);
    try std.testing.expectEqual(@as(u64, 5), priority_sort.total);
    try std.testing.expectEqual(@as(u64, 5), priority_sort.written);
    try std.testing.expectEqual(@as(u64, 2), sorted_rows[0]);
    try std.testing.expectEqual(@as(u64, 5), sorted_rows[1]);
    try std.testing.expectEqual(@as(u64, 1), sorted_rows[2]);
    try std.testing.expectEqual(@as(u64, 4), sorted_rows[3]);
    try std.testing.expectEqual(@as(u64, 0), sorted_rows[4]);

    const signed_flag_sort = try snapshotSortRowsI8(std.testing.allocator, snapshot, 8, original_candidate_rows[0..candidate_len], false, 0, sorted_rows.len, &sorted_rows);
    try std.testing.expectEqual(@as(u64, 5), signed_flag_sort.total);
    try std.testing.expectEqual(@as(u64, 5), signed_flag_sort.written);
    try std.testing.expectEqual(@as(u64, 0), sorted_rows[0]);
    try std.testing.expectEqual(@as(u64, 4), sorted_rows[1]);
    try std.testing.expectEqual(@as(u64, 1), sorted_rows[2]);
    try std.testing.expectEqual(@as(u64, 2), sorted_rows[3]);
    try std.testing.expectEqual(@as(u64, 5), sorted_rows[4]);

    const warehouse_sort = try snapshotSortRowsU16(std.testing.allocator, snapshot, 9, original_candidate_rows[0..candidate_len], true, 0, sorted_rows.len, &sorted_rows);
    try std.testing.expectEqual(@as(u64, 5), warehouse_sort.total);
    try std.testing.expectEqual(@as(u64, 5), warehouse_sort.written);
    try std.testing.expectEqual(@as(u64, 1), sorted_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), sorted_rows[1]);
    try std.testing.expectEqual(@as(u64, 5), sorted_rows[2]);
    try std.testing.expectEqual(@as(u64, 0), sorted_rows[3]);
    try std.testing.expectEqual(@as(u64, 4), sorted_rows[4]);

    const qty_delta_page = try snapshotSortRowsI16(std.testing.allocator, snapshot, 10, original_candidate_rows[0..candidate_len], false, 1, 2, &sorted_rows);
    try std.testing.expectEqual(@as(u64, 5), qty_delta_page.total);
    try std.testing.expectEqual(@as(u64, 2), qty_delta_page.written);
    try std.testing.expectEqual(@as(u64, 0), sorted_rows[0]);
    try std.testing.expectEqual(@as(u64, 1), sorted_rows[1]);

    const channel_result = try snapshotFilterRowsU32Range(snapshot, 5, original_candidate_rows[0..candidate_len], 20, 40, 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 3), channel_result.total);
    try std.testing.expectEqual(@as(u64, 3), channel_result.written);
    try std.testing.expectEqual(@as(u64, 1), filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered_rows[1]);
    try std.testing.expectEqual(@as(u64, 5), filtered_rows[2]);

    const adjustment_result = try snapshotFilterRowsI32Range(snapshot, 6, original_candidate_rows[0..candidate_len], 0, 10, 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 2), adjustment_result.total);
    try std.testing.expectEqual(@as(u64, 2), adjustment_result.written);
    try std.testing.expectEqual(@as(u64, 1), filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered_rows[1]);

    const priority_result = try snapshotFilterRowsU8Range(snapshot, 7, original_candidate_rows[0..candidate_len], 2, 3, 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 4), priority_result.total);
    try std.testing.expectEqual(@as(u64, 4), priority_result.written);
    try std.testing.expectEqual(@as(u64, 1), filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered_rows[1]);
    try std.testing.expectEqual(@as(u64, 4), filtered_rows[2]);
    try std.testing.expectEqual(@as(u64, 5), filtered_rows[3]);

    const signed_flag_result = try snapshotFilterRowsI8Range(snapshot, 8, original_candidate_rows[0..candidate_len], -1, 0, 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 3), signed_flag_result.total);
    try std.testing.expectEqual(@as(u64, 3), signed_flag_result.written);
    try std.testing.expectEqual(@as(u64, 0), filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 1), filtered_rows[1]);
    try std.testing.expectEqual(@as(u64, 4), filtered_rows[2]);

    const warehouse_result = try snapshotFilterRowsU16Range(snapshot, 9, original_candidate_rows[0..candidate_len], 200, 200, 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 3), warehouse_result.total);
    try std.testing.expectEqual(@as(u64, 3), warehouse_result.written);
    try std.testing.expectEqual(@as(u64, 1), filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered_rows[1]);
    try std.testing.expectEqual(@as(u64, 5), filtered_rows[2]);

    const qty_delta_result = try snapshotFilterRowsI16Range(snapshot, 10, original_candidate_rows[0..candidate_len], -20, 15, 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 3), qty_delta_result.total);
    try std.testing.expectEqual(@as(u64, 3), qty_delta_result.written);
    try std.testing.expectEqual(@as(u64, 0), filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 1), filtered_rows[1]);
    try std.testing.expectEqual(@as(u64, 4), filtered_rows[2]);

    const amount_result = try snapshotFilterRowsI64Range(snapshot, 4, candidate_rows[0..status_len], 1500, 5500, 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 2), amount_result.total);
    try std.testing.expectEqual(@as(u64, 2), amount_result.written);
    try std.testing.expectEqual(@as(u64, 1), filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered_rows[1]);

    const posted_result = try snapshotFilterRowsBool(snapshot, 3, candidate_rows[0..status_len], true, 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 2), posted_result.total);
    try std.testing.expectEqual(@as(u64, 2), posted_result.written);
    try std.testing.expectEqual(@as(u64, 1), filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 5), filtered_rows[1]);

    const empty = try snapshotFilterRowsU64Range(snapshot, 2, &.{}, 2, 2, 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 0), empty.total);
    try std.testing.expectEqual(@as(u64, 0), empty.written);
    const empty_stats = try snapshotStatsRowsI64(snapshot, 4, &.{});
    try std.testing.expectEqual(@as(u64, 0), empty_stats.count);
    try std.testing.expectEqual(@as(i64, 0), empty_stats.sum);
    try std.testing.expectEqual(@as(i64, 0), empty_stats.min);
    try std.testing.expectEqual(@as(i64, 0), empty_stats.max);

    const invalid_rows = [_]u64{999};
    try std.testing.expectError(TableError.InvalidFormat, snapshotFilterRowsU64Range(snapshot, 2, &invalid_rows, 2, 2, 0, filtered_rows.len, &filtered_rows));
    try std.testing.expectError(TableError.InvalidFormat, snapshotFilterRowsU16Range(snapshot, 9, &invalid_rows, 200, 200, 0, filtered_rows.len, &filtered_rows));
    try std.testing.expectError(TableError.InvalidFormat, snapshotStatsRowsU64(snapshot, 2, &invalid_rows));
    try std.testing.expectError(TableError.InvalidFormat, snapshotSortRowsI64(std.testing.allocator, snapshot, 4, &invalid_rows, true, 0, filtered_rows.len, &filtered_rows));
    try std.testing.expectError(TableError.InvalidFormat, snapshotSortRowsU16(std.testing.allocator, snapshot, 9, &invalid_rows, true, 0, filtered_rows.len, &filtered_rows));
}

test "table write transaction commits atomically and preserves previous epoch on constraint failure" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "tx_members";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "tx_members.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_POINTS_STRIDE = 8 // u64
    );
    _ = try createU64Index(std.testing.allocator, ".", table_name, 0, true);

    var tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    var row: [16]u8 = undefined;
    writeU64LE(&row, 0, 1);
    writeU64LE(&row, 8, 10);
    _ = try writeTransactionInsertRawRow(tx, &row);
    writeU64LE(&row, 0, 2);
    writeU64LE(&row, 8, 20);
    _ = try writeTransactionInsertRawRow(tx, &row);
    const committed = try commitWriteTransaction(std.testing.allocator, tx);
    try std.testing.expectEqual(@as(u64, 2), committed.row_count);
    try std.testing.expectEqual(@as(u64, 2), committed.epoch);
    destroyWriteTransaction(std.testing.allocator, tx);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 30), try snapshotSumU64(snapshot, 1));
    }

    tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    writeU64LE(&row, 0, 2);
    writeU64LE(&row, 8, 200);
    _ = try writeTransactionInsertRawRow(tx, &row);
    try std.testing.expectError(TableError.ConstraintViolation, commitWriteTransaction(std.testing.allocator, tx));
    destroyWriteTransaction(std.testing.allocator, tx);

    const after_failed_commit = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 2), after_failed_commit.row_count);
    try std.testing.expectEqual(@as(u64, 2), after_failed_commit.epoch);
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 30), try snapshotSumU64(snapshot, 1));
    }

    tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    writeU64LE(&row, 0, 2);
    writeU64LE(&row, 8, 25);
    const upsert_existing = try writeTransactionUpsertRawRowU64Key(tx, 0, 2, &row);
    try std.testing.expect(!upsert_existing.inserted);
    writeU64LE(&row, 0, 99);
    writeU64LE(&row, 8, 990);
    try std.testing.expectError(TableError.NotFound, writeTransactionUpdateRawRowU64Key(tx, 0, 99, &row));
    writeU64LE(&row, 0, 2);
    writeU64LE(&row, 8, 26);
    _ = try writeTransactionUpdateRawRowU64Key(tx, 0, 2, &row);
    writeU64LE(&row, 0, 3);
    writeU64LE(&row, 8, 30);
    const upsert_new = try writeTransactionUpsertRawRowU64Key(tx, 0, 3, &row);
    try std.testing.expect(upsert_new.inserted);
    _ = try writeTransactionDeleteU64Key(tx, 0, 1);
    const committed_mutations = try commitWriteTransaction(std.testing.allocator, tx);
    try std.testing.expectEqual(@as(u64, 2), committed_mutations.row_count);
    try std.testing.expectEqual(@as(u64, 3), committed_mutations.epoch);
    destroyWriteTransaction(std.testing.allocator, tx);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 56), try snapshotSumU64(snapshot, 1));
    }
}

test "table write transaction commits blob handles with rows atomically" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "tx_blob_items";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "tx_blob_items.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_NOTE_STRIDE = 8 // blob_handle
    );
    _ = try createBlobEqIndex(std.testing.allocator, ".", table_name, 1, "notes", false);

    var tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    const note = try writeTransactionPutBlobValue(std.testing.allocator, tx, "notes", "created in tx");
    try std.testing.expectEqual(@as(u64, 1), note.id);
    const not_visible_before_commit = try blobValueLen(std.testing.allocator, ".", table_name, "notes", note.id);
    try std.testing.expect(!not_visible_before_commit.found);

    var row: [16]u8 = undefined;
    writeU64LE(&row, 0, 100);
    writeU64LE(&row, 8, note.id);
    _ = try writeTransactionInsertRawRow(tx, &row);
    const committed = try commitWriteTransaction(std.testing.allocator, tx);
    try std.testing.expectEqual(@as(u64, 1), committed.row_count);
    try std.testing.expectEqual(@as(u64, 2), committed.epoch);
    destroyWriteTransaction(std.testing.allocator, tx);

    _ = try verifyTable(std.testing.allocator, ".", table_name);
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        var rows: [2]u64 = undefined;
        const exact = try snapshotFilterBlobEqRows(std.testing.allocator, snapshot, 1, "notes", "created in tx", 0, 2, &rows);
        try std.testing.expectEqual(@as(u64, 1), exact.total);
        try std.testing.expectEqual(@as(u64, 1), exact.written);
        try std.testing.expectEqual(@as(u64, 0), rows[0]);
        const len = try snapshotBlobValueLen(snapshot, "notes", note.id);
        try std.testing.expect(len.found);
        try std.testing.expectEqual(@as(u64, 13), len.len);
    }

    tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    const blob_only = try writeTransactionPutBlobValue(std.testing.allocator, tx, "notes", "blob only");
    try std.testing.expectEqual(@as(u64, 2), blob_only.id);
    const blob_only_commit = try commitWriteTransaction(std.testing.allocator, tx);
    try std.testing.expectEqual(@as(u64, 1), blob_only_commit.row_count);
    try std.testing.expectEqual(@as(u64, 3), blob_only_commit.epoch);
    destroyWriteTransaction(std.testing.allocator, tx);
    const blob_only_len = try blobValueLen(std.testing.allocator, ".", table_name, "notes", blob_only.id);
    try std.testing.expect(blob_only_len.found);
    try std.testing.expectEqual(@as(u64, 9), blob_only_len.len);

    tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    const rolled_back = try writeTransactionPutBlobValue(std.testing.allocator, tx, "notes", "rolled back");
    try std.testing.expectEqual(@as(u64, 3), rolled_back.id);
    destroyWriteTransaction(std.testing.allocator, tx);
    const rolled_back_len = try blobValueLen(std.testing.allocator, ".", table_name, "notes", rolled_back.id);
    try std.testing.expect(!rolled_back_len.found);

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 3), verified.epoch);
    try std.testing.expectEqual(@as(u64, 1), verified.row_count);
}

test "table write transaction interns dictionaries with rows atomically" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "tx_dict_members";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "tx_dict_members.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_STATUS_STRIDE = 8 // u64
    );
    _ = try createU64Index(std.testing.allocator, ".", table_name, 0, true);

    var tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    const active = try writeTransactionInternStringDict(std.testing.allocator, tx, "status", "active");
    try std.testing.expectEqual(@as(u64, 1), active.id);
    try std.testing.expect(active.inserted);
    const active_again = try writeTransactionInternStringDict(std.testing.allocator, tx, "status", "active");
    try std.testing.expectEqual(@as(u64, 1), active_again.id);
    try std.testing.expect(!active_again.inserted);

    const not_visible_before_commit = try lookupStringDict(std.testing.allocator, ".", table_name, "status", "active");
    try std.testing.expect(!not_visible_before_commit.found);

    var row: [16]u8 = undefined;
    writeU64LE(&row, 0, 1);
    writeU64LE(&row, 8, active.id);
    _ = try writeTransactionInsertRawRow(tx, &row);
    const committed = try commitWriteTransaction(std.testing.allocator, tx);
    try std.testing.expectEqual(@as(u64, 1), committed.row_count);
    try std.testing.expectEqual(@as(u64, 2), committed.epoch);
    destroyWriteTransaction(std.testing.allocator, tx);

    _ = try verifyTable(std.testing.allocator, ".", table_name);
    const visible = try lookupStringDict(std.testing.allocator, ".", table_name, "status", "active");
    try std.testing.expect(visible.found);
    try std.testing.expectEqual(@as(u64, 1), visible.id);
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        const found = try snapshotFindU64(snapshot, 0, 1);
        try std.testing.expect(found.found);
        try std.testing.expectEqual(@as(u64, 1), try snapshotGetU64(snapshot, 1, found.row_index));
        const status_lookup = try snapshotDictLookup(snapshot, "status", "active");
        try std.testing.expect(status_lookup.found);
        try std.testing.expectEqual(@as(u64, 1), status_lookup.id);
    }

    tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    const paused = try writeTransactionInternStringDict(std.testing.allocator, tx, "status", "paused");
    try std.testing.expectEqual(@as(u64, 2), paused.id);
    try std.testing.expect(paused.inserted);
    destroyWriteTransaction(std.testing.allocator, tx);
    const rolled_back = try lookupStringDict(std.testing.allocator, ".", table_name, "status", "paused");
    try std.testing.expect(!rolled_back.found);

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 2), verified.epoch);
    try std.testing.expectEqual(@as(u64, 1), verified.row_count);
}

test "table persistent u64 index tracks ingest update and corruption" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "indexed_members";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "indexed_members.sadb-schema",
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_POINTS_STRIDE = 8 // u64
    );

    var ids1 = [_]u64{ 1, 2 };
    var points1 = [_]u64{ 10, 20 };
    const first_columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids1[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(points1[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, ids1.len, &first_columns);
    const indexed = try createU64Index(std.testing.allocator, ".", table_name, 0, true);
    try std.testing.expectEqual(@as(u64, 2), indexed.row_count);

    {
        var meta = try loadActiveMeta(std.testing.allocator, ".", table_name);
        defer meta.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), meta.indexes.len);
        try std.testing.expectEqual(@as(u64, 0), meta.indexes[0].column_index);
        try std.testing.expect(meta.indexes[0].unique);
        try std.testing.expectEqual(@as(u64, 32), meta.indexes[0].bytes);
        try validateIndexFiles(std.testing.allocator, ".", meta);
    }

    var ids2 = [_]u64{3};
    var points2 = [_]u64{30};
    const second_columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids2[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(points2[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, ids2.len, &second_columns);
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(usize, 1), snapshot.indexes.len);
        const found3 = try snapshotFindU64(snapshot, 0, 3);
        try std.testing.expect(found3.found);
        try std.testing.expectEqual(@as(u64, 2), found3.row_index);
        try std.testing.expectEqual(@as(u64, 30), try snapshotGetU64(snapshot, 1, found3.row_index));
        try std.testing.expectEqual(@as(u64, 1), try snapshotCountU64Cmp(snapshot, 0, .eq, 3));
        try std.testing.expectEqual(@as(u64, 2), try snapshotCountU64Cmp(snapshot, 0, .ne, 2));
        try std.testing.expectEqual(@as(u64, 2), try snapshotCountU64Cmp(snapshot, 0, .lt, 3));
        try std.testing.expectEqual(@as(u64, 2), try snapshotCountU64Cmp(snapshot, 0, .ge, 2));
    }

    var row: [16]u8 = undefined;
    writeU64LE(&row, 0, 4);
    writeU64LE(&row, 8, 40);
    const inserted = try insertRawRow(std.testing.allocator, ".", table_name, &row);
    try std.testing.expectEqual(@as(u64, 4), inserted.row_count);
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        const found4 = try snapshotFindU64(snapshot, 0, 4);
        try std.testing.expect(found4.found);
        try std.testing.expectEqual(@as(u64, 3), found4.row_index);
        try std.testing.expectEqual(@as(u64, 40), try snapshotGetU64(snapshot, 1, found4.row_index));
        try std.testing.expectEqual(@as(u64, 3), try snapshotCountU64Cmp(snapshot, 0, .ge, 2));
        var fetched_row: [16]u8 = undefined;
        try snapshotGetRowU64Key(snapshot, 0, 4, &fetched_row);
        try std.testing.expectEqual(@as(u64, 4), readU64LE(&fetched_row, 0));
        try std.testing.expectEqual(@as(u64, 40), readU64LE(&fetched_row, 8));
        try std.testing.expectError(TableError.NotFound, snapshotGetRowU64Key(snapshot, 0, 99, &fetched_row));
    }

    var duplicate_row: [16]u8 = undefined;
    writeU64LE(&duplicate_row, 0, 4);
    writeU64LE(&duplicate_row, 8, 400);
    try std.testing.expectError(TableError.ConstraintViolation, insertRawRow(std.testing.allocator, ".", table_name, &duplicate_row));
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 4), snapshot.row_count);
        try std.testing.expectEqual(@as(u64, 1), try snapshotCountU64Cmp(snapshot, 0, .eq, 4));
    }

    var upsert_existing_row: [16]u8 = undefined;
    writeU64LE(&upsert_existing_row, 0, 4);
    writeU64LE(&upsert_existing_row, 8, 44);
    const upsert_existing = try upsertRawRowU64Key(std.testing.allocator, ".", table_name, 0, 4, &upsert_existing_row);
    try std.testing.expect(!upsert_existing.inserted);
    try std.testing.expectEqual(@as(u64, 4), upsert_existing.info.row_count);
    try std.testing.expectEqual(@as(usize, 1), upsert_existing.info.segment_count);
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 4), snapshot.row_count);
        var fetched_row: [16]u8 = undefined;
        try snapshotGetRowU64Key(snapshot, 0, 4, &fetched_row);
        try std.testing.expectEqual(@as(u64, 4), readU64LE(&fetched_row, 0));
        try std.testing.expectEqual(@as(u64, 44), readU64LE(&fetched_row, 8));
    }

    var update_existing_row: [16]u8 = undefined;
    writeU64LE(&update_existing_row, 0, 4);
    writeU64LE(&update_existing_row, 8, 45);
    const update_existing = try updateRawRowU64Key(std.testing.allocator, ".", table_name, 0, 4, &update_existing_row);
    try std.testing.expectEqual(@as(u64, 4), update_existing.row_count);
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        var fetched_row: [16]u8 = undefined;
        try snapshotGetRowU64Key(snapshot, 0, 4, &fetched_row);
        try std.testing.expectEqual(@as(u64, 45), readU64LE(&fetched_row, 8));
    }
    writeU64LE(&update_existing_row, 8, 44);
    _ = try updateRawRowU64Key(std.testing.allocator, ".", table_name, 0, 4, &update_existing_row);

    var missing_update_row: [16]u8 = undefined;
    writeU64LE(&missing_update_row, 0, 99);
    writeU64LE(&missing_update_row, 8, 990);
    try std.testing.expectError(TableError.NotFound, updateRawRowU64Key(std.testing.allocator, ".", table_name, 0, 99, &missing_update_row));

    var mismatched_update_row: [16]u8 = undefined;
    writeU64LE(&mismatched_update_row, 0, 6);
    writeU64LE(&mismatched_update_row, 8, 60);
    try std.testing.expectError(TableError.InvalidFormat, updateRawRowU64Key(std.testing.allocator, ".", table_name, 0, 4, &mismatched_update_row));

    var mismatched_upsert_row: [16]u8 = undefined;
    writeU64LE(&mismatched_upsert_row, 0, 6);
    writeU64LE(&mismatched_upsert_row, 8, 60);
    try std.testing.expectError(TableError.InvalidFormat, upsertRawRowU64Key(std.testing.allocator, ".", table_name, 0, 4, &mismatched_upsert_row));

    var upsert_new_row: [16]u8 = undefined;
    writeU64LE(&upsert_new_row, 0, 5);
    writeU64LE(&upsert_new_row, 8, 50);
    const upsert_new = try upsertRawRowU64Key(std.testing.allocator, ".", table_name, 0, 5, &upsert_new_row);
    try std.testing.expect(upsert_new.inserted);
    try std.testing.expectEqual(@as(u64, 5), upsert_new.info.row_count);
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 5), snapshot.row_count);
        const info = try snapshotInfo(snapshot);
        try std.testing.expectEqual(@as(u64, 5), info.row_count);
        try std.testing.expectEqual(@as(u64, 2), info.column_count);
        try std.testing.expectEqual(@as(u64, 16), info.row_bytes);
        const points_info = try snapshotColumnInfo(snapshot, 1);
        try std.testing.expectEqual(@as(u64, 8), points_info.stride);
        try std.testing.expectEqual(@as(u64, @intFromEnum(schema.PrimType.u64)), points_info.type_code);
        try std.testing.expectEqual(@as(u64, 6), points_info.name_len);
        try std.testing.expectEqual(@as(u64, 3), points_info.type_name_len);
        try std.testing.expectEqual(@as(u64, 1), try snapshotCountU64Cmp(snapshot, 0, .eq, 5));
        var range_rows = [_]u64{ 99, 99, 99 };
        const range = try snapshotRangeU64Rows(snapshot, 0, 2, 5, 1, 2, &range_rows);
        try std.testing.expectEqual(@as(u64, 4), range.total);
        try std.testing.expectEqual(@as(u64, 2), range.written);
        try std.testing.expectEqual(@as(u64, 2), range_rows[0]);
        try std.testing.expectEqual(@as(u64, 3), range_rows[1]);
        var range_row: [16]u8 = undefined;
        try snapshotGetRow(snapshot, range_rows[1], &range_row);
        try std.testing.expectEqual(@as(u64, 4), readU64LE(&range_row, 0));
        try std.testing.expectEqual(@as(u64, 44), readU64LE(&range_row, 8));
        const project_columns = [_]u64{ 0, 1 };
        try std.testing.expectEqual(@as(u64, 32), try snapshotProjectRowsRequiredBytes(snapshot, 2, &project_columns));
        var projected_rows: [32]u8 = undefined;
        const projected = try snapshotProjectRows(snapshot, range_rows[0..2], &project_columns, &projected_rows);
        try std.testing.expectEqual(@as(u64, 2), projected.written_rows);
        try std.testing.expectEqual(@as(u64, 32), projected.required_bytes);
        try std.testing.expectEqual(@as(u64, 3), readU64LE(&projected_rows, 0));
        try std.testing.expectEqual(@as(u64, 30), readU64LE(&projected_rows, 8));
        try std.testing.expectEqual(@as(u64, 4), readU64LE(&projected_rows, 16));
        try std.testing.expectEqual(@as(u64, 44), readU64LE(&projected_rows, 24));
        var too_small_project: [24]u8 = undefined;
        try std.testing.expectError(TableError.CursorOverflow, snapshotProjectRows(snapshot, range_rows[0..2], &project_columns, &too_small_project));
        const empty_range = try snapshotRangeU64Rows(snapshot, 0, 9, 2, 0, 2, &range_rows);
        try std.testing.expectEqual(@as(u64, 0), empty_range.total);
        try std.testing.expectEqual(@as(u64, 0), empty_range.written);
        try std.testing.expectError(TableError.InvalidFormat, snapshotRangeU64Rows(snapshot, 1, 10, 50, 0, 2, &range_rows));
        var fetched_row: [16]u8 = undefined;
        try snapshotGetRowU64Key(snapshot, 0, 5, &fetched_row);
        try std.testing.expectEqual(@as(u64, 50), readU64LE(&fetched_row, 8));
    }

    var duplicate_ids = [_]u64{4};
    var duplicate_points = [_]u64{400};
    const duplicate_columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(duplicate_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(duplicate_points[0..]) },
    };
    try std.testing.expectError(TableError.ConstraintViolation, ingestRawColumns(std.testing.allocator, ".", table_name, duplicate_ids.len, &duplicate_columns));
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 5), snapshot.row_count);
        try std.testing.expectEqual(@as(u64, 1), try snapshotCountU64Cmp(snapshot, 0, .eq, 4));
    }

    _ = try updateU64ColumnAdd(std.testing.allocator, ".", table_name, 0, 0, 1, 10);
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        const old_id = try snapshotFindU64(snapshot, 0, 1);
        try std.testing.expect(!old_id.found);
        const new_id = try snapshotFindU64(snapshot, 0, 11);
        try std.testing.expect(new_id.found);
        try std.testing.expectEqual(@as(u64, 0), new_id.row_index);
        try std.testing.expectEqual(@as(u64, 4), try snapshotCountU64Cmp(snapshot, 0, .ge, 3));
        try std.testing.expectEqual(@as(u64, 0), try snapshotCountU64Cmp(snapshot, 0, .le, 1));
    }

    try std.testing.expectError(TableError.ConstraintViolation, updateU64ColumnAdd(std.testing.allocator, ".", table_name, 0, 1, 1, 1));
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 2), try snapshotGetU64(snapshot, 0, 1));
        try std.testing.expectEqual(@as(u64, 1), try snapshotCountU64Cmp(snapshot, 0, .eq, 3));
    }

    const deleted = try deleteU64Key(std.testing.allocator, ".", table_name, 0, 4);
    try std.testing.expectEqual(@as(u64, 4), deleted.row_count);
    try std.testing.expectEqual(@as(usize, 1), deleted.segment_count);
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 4), snapshot.row_count);
        const deleted_id = try snapshotFindU64(snapshot, 0, 4);
        try std.testing.expect(!deleted_id.found);
        try std.testing.expectEqual(@as(u64, 0), try snapshotCountU64Cmp(snapshot, 0, .eq, 4));
        try std.testing.expectEqual(@as(u64, 3), try snapshotCountU64Cmp(snapshot, 0, .ge, 3));
    }
    try std.testing.expectError(TableError.NotFound, deleteU64Key(std.testing.allocator, ".", table_name, 0, 4));

    {
        var meta = try loadActiveMeta(std.testing.allocator, ".", table_name);
        defer meta.deinit(std.testing.allocator);
        const index_path = try activePath(std.testing.allocator, ".", meta.indexes[0].path);
        defer std.testing.allocator.free(index_path);
        try writeFile(std.testing.allocator, index_path, "corrupt");
    }
    try std.testing.expectError(TableError.VerifyFailed, verifyTable(std.testing.allocator, ".", table_name));
}

test "table unique u64 index rejects duplicate existing data" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "duplicate_members";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "duplicate_members.sadb-schema",
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_POINTS_STRIDE = 8 // u64
    );

    var ids = [_]u64{ 1, 1 };
    var points = [_]u64{ 10, 20 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(points[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, ids.len, &columns);

    try std.testing.expectError(TableError.ConstraintViolation, createU64Index(std.testing.allocator, ".", table_name, 0, true));
    const non_unique = try createU64Index(std.testing.allocator, ".", table_name, 0, false);
    try std.testing.expectEqual(@as(u64, 2), non_unique.row_count);
    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 2), verified.row_count);
}

test "table persistent i64 index uses signed ordering" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "ledger_entries";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "ledger_entries.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_BALANCE_CENTS_STRIDE = 8 // i64
    );

    var ids = [_]u64{ 1, 2, 3, 4 };
    var balances = [_]i64{ -100, 0, 50, -25 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(balances[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, ids.len, &columns);
    const indexed = try createI64Index(std.testing.allocator, ".", table_name, 1, false);
    try std.testing.expectEqual(@as(u64, 4), indexed.row_count);

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 4), verified.row_count);

    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();

    try std.testing.expectEqual(@as(u64, 2), try snapshotCountI64Cmp(snapshot, 1, .lt, 0));
    try std.testing.expectEqual(@as(u64, 2), try snapshotCountI64Cmp(snapshot, 1, .ge, 0));
    const found = try snapshotFindI64(snapshot, 1, -25);
    try std.testing.expect(found.found);
    try std.testing.expectEqual(@as(u64, 3), found.row_index);
    try std.testing.expectEqual(@as(i64, -25), try snapshotGetI64(snapshot, 1, found.row_index));

    var range_rows = [_]u64{ 99, 99, 99, 99 };
    const range = try snapshotRangeI64Rows(snapshot, 1, -30, 10, 0, 4, &range_rows);
    try std.testing.expectEqual(@as(u64, 2), range.total);
    try std.testing.expectEqual(@as(u64, 2), range.written);
    try std.testing.expectEqual(@as(u64, 3), range_rows[0]);
    try std.testing.expectEqual(@as(u64, 1), range_rows[1]);
    try std.testing.expectEqual(@as(i64, -100), try snapshotMinI64(snapshot, 1));
    try std.testing.expectEqual(@as(i64, 50), try snapshotMaxI64(snapshot, 1));
}

test "table persistent u32 and i32 indexes use compact typed ordering" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "compact_items";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "compact_items.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_STATUS_STRIDE = 4 // u32
        \\#def COL_DELTA_STRIDE = 4 // i32
    );

    var ids = [_]u64{ 1, 2, 3, 4 };
    var statuses = [_]u32{ 10, 2, 10, 7 };
    var deltas = [_]i32{ -3, 0, 5, -1 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(statuses[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(deltas[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, ids.len, &columns);
    _ = try createU32Index(std.testing.allocator, ".", table_name, 1, false);
    _ = try createI32Index(std.testing.allocator, ".", table_name, 2, false);

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 4), verified.row_count);

    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();

    try std.testing.expectEqual(@as(u64, 2), try snapshotCountU32Cmp(snapshot, 1, .eq, 10));
    try std.testing.expectEqual(@as(u64, 3), try snapshotCountU32Cmp(snapshot, 1, .ge, 7));
    const found_status = try snapshotFindU32(snapshot, 1, 7);
    try std.testing.expect(found_status.found);
    try std.testing.expectEqual(@as(u64, 3), found_status.row_index);
    try std.testing.expectEqual(@as(u32, 7), try snapshotGetU32(snapshot, 1, found_status.row_index));

    var status_rows = [_]u64{ 99, 99, 99 };
    const status_range = try snapshotRangeU32Rows(snapshot, 1, 2, 10, 1, 2, &status_rows);
    try std.testing.expectEqual(@as(u64, 4), status_range.total);
    try std.testing.expectEqual(@as(u64, 2), status_range.written);
    try std.testing.expectEqual(@as(u64, 3), status_rows[0]);
    try std.testing.expectEqual(@as(u64, 0), status_rows[1]);
    try std.testing.expectEqual(@as(u32, 2), try snapshotMinU32(snapshot, 1));
    try std.testing.expectEqual(@as(u32, 10), try snapshotMaxU32(snapshot, 1));

    try std.testing.expectEqual(@as(u64, 2), try snapshotCountI32Cmp(snapshot, 2, .lt, 0));
    try std.testing.expectEqual(@as(u64, 2), try snapshotCountI32Cmp(snapshot, 2, .ge, 0));
    const found_delta = try snapshotFindI32(snapshot, 2, -1);
    try std.testing.expect(found_delta.found);
    try std.testing.expectEqual(@as(u64, 3), found_delta.row_index);
    try std.testing.expectEqual(@as(i32, -1), try snapshotGetI32(snapshot, 2, found_delta.row_index));

    var delta_rows = [_]u64{ 99, 99, 99 };
    const delta_range = try snapshotRangeI32Rows(snapshot, 2, -3, 0, 0, 3, &delta_rows);
    try std.testing.expectEqual(@as(u64, 3), delta_range.total);
    try std.testing.expectEqual(@as(u64, 3), delta_range.written);
    try std.testing.expectEqual(@as(u64, 0), delta_rows[0]);
    try std.testing.expectEqual(@as(u64, 3), delta_rows[1]);
    try std.testing.expectEqual(@as(u64, 1), delta_rows[2]);
    try std.testing.expectEqual(@as(i32, -3), try snapshotMinI32(snapshot, 2));
    try std.testing.expectEqual(@as(i32, 5), try snapshotMaxI32(snapshot, 2));
}

test "table persistent u8 i8 u16 and i16 indexes use compact typed ordering" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "small_items";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "small_items.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_STATUS_STRIDE = 1 // u8
        \\#def COL_DELTA8_STRIDE = 1 // i8
        \\#def COL_WAREHOUSE_STRIDE = 2 // u16
        \\#def COL_DELTA16_STRIDE = 2 // i16
    );

    var ids = [_]u64{ 1, 2, 3, 4, 5 };
    var statuses = [_]u8{ 1, 7, 3, 7, 9 };
    var deltas8 = [_]i8{ -2, 0, 5, -1, -2 };
    var warehouses = [_]u16{ 300, 10, 300, 42, 655 };
    var deltas16 = [_]i16{ -100, 50, 0, -25, 50 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(statuses[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(deltas8[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(warehouses[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(deltas16[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, ids.len, &columns);
    _ = try createU8Index(std.testing.allocator, ".", table_name, 1, false);
    _ = try createI8Index(std.testing.allocator, ".", table_name, 2, false);
    _ = try createU16Index(std.testing.allocator, ".", table_name, 3, false);
    _ = try createI16Index(std.testing.allocator, ".", table_name, 4, false);

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 5), verified.row_count);

    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();

    try std.testing.expectEqual(@as(u64, 2), try snapshotCountU8Cmp(snapshot, 1, .eq, 7));
    try std.testing.expectEqual(@as(u64, 3), try snapshotCountU8Cmp(snapshot, 1, .ge, 7));
    const found_status = try snapshotFindU8(snapshot, 1, 3);
    try std.testing.expect(found_status.found);
    try std.testing.expectEqual(@as(u64, 2), found_status.row_index);
    try std.testing.expectEqual(@as(u8, 3), try snapshotGetU8(snapshot, 1, found_status.row_index));
    var status_rows = [_]u64{ 99, 99, 99 };
    const status_range = try snapshotRangeU8Rows(snapshot, 1, 1, 7, 1, 3, &status_rows);
    try std.testing.expectEqual(@as(u64, 4), status_range.total);
    try std.testing.expectEqual(@as(u64, 3), status_range.written);
    try std.testing.expectEqual(@as(u64, 2), status_rows[0]);
    try std.testing.expectEqual(@as(u64, 1), status_rows[1]);
    try std.testing.expectEqual(@as(u64, 3), status_rows[2]);
    try std.testing.expectEqual(@as(u8, 1), try snapshotMinU8(snapshot, 1));
    try std.testing.expectEqual(@as(u8, 9), try snapshotMaxU8(snapshot, 1));

    try std.testing.expectEqual(@as(u64, 3), try snapshotCountI8Cmp(snapshot, 2, .lt, 0));
    try std.testing.expectEqual(@as(u64, 2), try snapshotCountI8Cmp(snapshot, 2, .ge, 0));
    const found_delta8 = try snapshotFindI8(snapshot, 2, -1);
    try std.testing.expect(found_delta8.found);
    try std.testing.expectEqual(@as(u64, 3), found_delta8.row_index);
    try std.testing.expectEqual(@as(i8, -1), try snapshotGetI8(snapshot, 2, found_delta8.row_index));
    var delta8_rows = [_]u64{ 99, 99, 99, 99 };
    const delta8_range = try snapshotRangeI8Rows(snapshot, 2, -2, 0, 0, 4, &delta8_rows);
    try std.testing.expectEqual(@as(u64, 4), delta8_range.total);
    try std.testing.expectEqual(@as(u64, 4), delta8_range.written);
    try std.testing.expectEqual(@as(u64, 0), delta8_rows[0]);
    try std.testing.expectEqual(@as(u64, 4), delta8_rows[1]);
    try std.testing.expectEqual(@as(u64, 3), delta8_rows[2]);
    try std.testing.expectEqual(@as(u64, 1), delta8_rows[3]);
    try std.testing.expectEqual(@as(i8, -2), try snapshotMinI8(snapshot, 2));
    try std.testing.expectEqual(@as(i8, 5), try snapshotMaxI8(snapshot, 2));

    try std.testing.expectEqual(@as(u64, 2), try snapshotCountU16Cmp(snapshot, 3, .eq, 300));
    try std.testing.expectEqual(@as(u64, 2), try snapshotCountU16Cmp(snapshot, 3, .lt, 100));
    const found_warehouse = try snapshotFindU16(snapshot, 3, 42);
    try std.testing.expect(found_warehouse.found);
    try std.testing.expectEqual(@as(u64, 3), found_warehouse.row_index);
    try std.testing.expectEqual(@as(u16, 42), try snapshotGetU16(snapshot, 3, found_warehouse.row_index));
    var warehouse_rows = [_]u64{ 99, 99, 99 };
    const warehouse_range = try snapshotRangeU16Rows(snapshot, 3, 10, 300, 1, 3, &warehouse_rows);
    try std.testing.expectEqual(@as(u64, 4), warehouse_range.total);
    try std.testing.expectEqual(@as(u64, 3), warehouse_range.written);
    try std.testing.expectEqual(@as(u64, 3), warehouse_rows[0]);
    try std.testing.expectEqual(@as(u64, 0), warehouse_rows[1]);
    try std.testing.expectEqual(@as(u64, 2), warehouse_rows[2]);
    try std.testing.expectEqual(@as(u16, 10), try snapshotMinU16(snapshot, 3));
    try std.testing.expectEqual(@as(u16, 655), try snapshotMaxU16(snapshot, 3));

    try std.testing.expectEqual(@as(u64, 3), try snapshotCountI16Cmp(snapshot, 4, .le, 0));
    const found_delta16 = try snapshotFindI16(snapshot, 4, -25);
    try std.testing.expect(found_delta16.found);
    try std.testing.expectEqual(@as(u64, 3), found_delta16.row_index);
    try std.testing.expectEqual(@as(i16, -25), try snapshotGetI16(snapshot, 4, found_delta16.row_index));
    var delta16_rows = [_]u64{ 99, 99, 99 };
    const delta16_range = try snapshotRangeI16Rows(snapshot, 4, -100, 0, 0, 3, &delta16_rows);
    try std.testing.expectEqual(@as(u64, 3), delta16_range.total);
    try std.testing.expectEqual(@as(u64, 3), delta16_range.written);
    try std.testing.expectEqual(@as(u64, 0), delta16_rows[0]);
    try std.testing.expectEqual(@as(u64, 3), delta16_rows[1]);
    try std.testing.expectEqual(@as(u64, 2), delta16_rows[2]);
    try std.testing.expectEqual(@as(i16, -100), try snapshotMinI16(snapshot, 4));
    try std.testing.expectEqual(@as(i16, 50), try snapshotMaxI16(snapshot, 4));
}

test "table persistent f32 and f64 indexes use finite float ordering" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "float_items";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "float_items.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_QTY_STRIDE = 4 // f32
        \\#def COL_WEIGHT_STRIDE = 8 // f64
    );

    var ids = [_]u64{ 1, 2, 3, 4, 5 };
    var quantities = [_]f32{ 1.5, -2.25, 0.0, -0.0, 9.75 };
    var weights = [_]f64{ 10.5, -3.25, 2.0, 2.0, 100.125 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(quantities[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(weights[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, ids.len, &columns);
    _ = try createF32Index(std.testing.allocator, ".", table_name, 1, false);
    _ = try createF64Index(std.testing.allocator, ".", table_name, 2, false);

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 5), verified.row_count);

    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();

    try std.testing.expectEqual(@as(u64, 2), try snapshotCountF32Cmp(snapshot, 1, .eq, 0.0));
    try std.testing.expectEqual(@as(u64, 4), try snapshotCountF32Cmp(snapshot, 1, .ge, 0.0));
    const found_qty = try snapshotFindF32(snapshot, 1, 1.5);
    try std.testing.expect(found_qty.found);
    try std.testing.expectEqual(@as(u64, 0), found_qty.row_index);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), try snapshotGetF32(snapshot, 1, found_qty.row_index), 0.0001);
    var qty_rows = [_]u64{ 99, 99, 99 };
    const qty_range = try snapshotRangeF32Rows(snapshot, 1, -0.0, 1.5, 0, 3, &qty_rows);
    try std.testing.expectEqual(@as(u64, 3), qty_range.total);
    try std.testing.expectEqual(@as(u64, 3), qty_range.written);
    try std.testing.expectEqual(@as(u64, 2), qty_rows[0]);
    try std.testing.expectEqual(@as(u64, 3), qty_rows[1]);
    try std.testing.expectEqual(@as(u64, 0), qty_rows[2]);
    try std.testing.expectApproxEqAbs(@as(f32, -2.25), try snapshotMinF32(snapshot, 1), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 9.75), try snapshotMaxF32(snapshot, 1), 0.0001);

    try std.testing.expectEqual(@as(u64, 2), try snapshotCountF64Cmp(snapshot, 2, .eq, 2.0));
    try std.testing.expectEqual(@as(u64, 2), try snapshotCountF64Cmp(snapshot, 2, .gt, 10.0));
    const found_weight = try snapshotFindF64(snapshot, 2, -3.25);
    try std.testing.expect(found_weight.found);
    try std.testing.expectEqual(@as(u64, 1), found_weight.row_index);
    try std.testing.expectApproxEqAbs(@as(f64, -3.25), try snapshotGetF64(snapshot, 2, found_weight.row_index), 0.0000001);
    var weight_rows = [_]u64{ 99, 99 };
    const weight_range = try snapshotRangeF64Rows(snapshot, 2, 2.0, 10.5, 1, 2, &weight_rows);
    try std.testing.expectEqual(@as(u64, 3), weight_range.total);
    try std.testing.expectEqual(@as(u64, 2), weight_range.written);
    try std.testing.expectEqual(@as(u64, 3), weight_rows[0]);
    try std.testing.expectEqual(@as(u64, 0), weight_rows[1]);
    try std.testing.expectApproxEqAbs(@as(f64, -3.25), try snapshotMinF64(snapshot, 2), 0.0000001);
    try std.testing.expectApproxEqAbs(@as(f64, 100.125), try snapshotMaxF64(snapshot, 2), 0.0000001);

    var f32_candidate_rows = [_]u64{ 2, 3, 0, 1, 4 };
    var f32_filtered_rows = [_]u64{ 99, 99, 99 };
    const f32_filter = try snapshotFilterRowsF32Range(snapshot, 1, &f32_candidate_rows, -0.0, 1.5, 0, f32_filtered_rows.len, &f32_filtered_rows);
    try std.testing.expectEqual(@as(u64, 3), f32_filter.total);
    try std.testing.expectEqual(@as(u64, 3), f32_filter.written);
    try std.testing.expectEqual(@as(u64, 2), f32_filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 3), f32_filtered_rows[1]);
    try std.testing.expectEqual(@as(u64, 0), f32_filtered_rows[2]);

    var f64_candidate_rows = [_]u64{ 1, 2, 3, 0, 4 };
    var f64_filtered_rows = [_]u64{ 99, 99 };
    const f64_filter = try snapshotFilterRowsF64Range(snapshot, 2, &f64_candidate_rows, 2.0, 10.5, 1, f64_filtered_rows.len, &f64_filtered_rows);
    try std.testing.expectEqual(@as(u64, 3), f64_filter.total);
    try std.testing.expectEqual(@as(u64, 2), f64_filter.written);
    try std.testing.expectEqual(@as(u64, 3), f64_filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 0), f64_filtered_rows[1]);

    var all_rows = [_]u64{ 0, 1, 2, 3, 4 };
    var sorted_rows = [_]u64{ 99, 99, 99, 99, 99 };
    const f32_sort = try snapshotSortRowsF32(std.testing.allocator, snapshot, 1, &all_rows, true, 0, sorted_rows.len, &sorted_rows);
    try std.testing.expectEqual(@as(u64, 5), f32_sort.total);
    try std.testing.expectEqual(@as(u64, 5), f32_sort.written);
    try std.testing.expectEqual(@as(u64, 4), sorted_rows[0]);
    try std.testing.expectEqual(@as(u64, 0), sorted_rows[1]);
    try std.testing.expectEqual(@as(u64, 2), sorted_rows[2]);
    try std.testing.expectEqual(@as(u64, 3), sorted_rows[3]);
    try std.testing.expectEqual(@as(u64, 1), sorted_rows[4]);

    const f64_sort = try snapshotSortRowsF64(std.testing.allocator, snapshot, 2, &all_rows, false, 0, sorted_rows.len, &sorted_rows);
    try std.testing.expectEqual(@as(u64, 5), f64_sort.total);
    try std.testing.expectEqual(@as(u64, 5), f64_sort.written);
    try std.testing.expectEqual(@as(u64, 1), sorted_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), sorted_rows[1]);
    try std.testing.expectEqual(@as(u64, 3), sorted_rows[2]);
    try std.testing.expectEqual(@as(u64, 0), sorted_rows[3]);
    try std.testing.expectEqual(@as(u64, 4), sorted_rows[4]);

    const empty_float_filter = try snapshotFilterRowsF64Range(snapshot, 2, &all_rows, 10.5, 2.0, 0, f64_filtered_rows.len, &f64_filtered_rows);
    try std.testing.expectEqual(@as(u64, 0), empty_float_filter.total);
    try std.testing.expectEqual(@as(u64, 0), empty_float_filter.written);

    try std.testing.expectError(TableError.InvalidFormat, snapshotCountF32Cmp(snapshot, 1, .eq, std.math.inf(f32)));
    try std.testing.expectError(TableError.InvalidFormat, snapshotFindF64(snapshot, 2, std.math.nan(f64)));
    try std.testing.expectError(TableError.InvalidFormat, snapshotFilterRowsF32Range(snapshot, 1, &all_rows, std.math.inf(f32), 1.0, 0, f32_filtered_rows.len, &f32_filtered_rows));
    const invalid_rows = [_]u64{999};
    try std.testing.expectError(TableError.InvalidFormat, snapshotSortRowsF64(std.testing.allocator, snapshot, 2, &invalid_rows, true, 0, sorted_rows.len, &sorted_rows));
}

test "table delete u64 key can empty a table" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "single_member";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "single_member.sadb-schema",
        \\#def MAX_ROWS = 4
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_POINTS_STRIDE = 8 // u64
    );

    var ids = [_]u64{7};
    var points = [_]u64{70};
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(points[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, ids.len, &columns);
    _ = try createU64Index(std.testing.allocator, ".", table_name, 0, true);

    const deleted = try deleteU64Key(std.testing.allocator, ".", table_name, 0, 7);
    try std.testing.expectEqual(@as(u64, 0), deleted.row_count);
    try std.testing.expectEqual(@as(usize, 0), deleted.segment_count);
    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 0), verified.row_count);
    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();
    try std.testing.expectEqual(@as(u64, 0), snapshot.row_count);
    try std.testing.expectEqual(@as(u64, 0), try snapshotCountU64Cmp(snapshot, 0, .eq, 7));
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

test "table recover skips corrupt highest segment artifact" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "recover_bad_segment";
    const schema_source =
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_TOTAL_STRIDE = 8 // u64
    ;
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "recover_bad_segment.sadb-schema", schema_source);

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
    try std.testing.expectEqual(@as(u64, 2), second.epoch);

    var latest = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer latest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), latest.segments.len);
    const corrupt_path = try activePath(std.testing.allocator, ".", latest.segments[1].files[0].path);
    defer std.testing.allocator.free(corrupt_path);
    try writeFile(std.testing.allocator, corrupt_path, "corrupt");
    try std.testing.expectError(TableError.VerifyFailed, verifyTable(std.testing.allocator, ".", table_name));

    const recovered = try recoverTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 1), recovered.row_count);
    try std.testing.expectEqual(@as(u64, 1), recovered.epoch);
    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 1), verified.row_count);
    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();
    try std.testing.expectEqual(@as(u64, 100), try snapshotSumU64(snapshot, 1));
}

test "table recover skips corrupt highest index artifact" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "recover_bad_index";
    const schema_source =
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_TOTAL_STRIDE = 8 // u64
    ;
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "recover_bad_index.sadb-schema", schema_source);

    var ids = [_]u64{ 1, 2 };
    var totals = [_]u64{ 100, 200 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(totals[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, ids.len, &columns);
    const indexed = try createU64Index(std.testing.allocator, ".", table_name, 0, true);
    try std.testing.expectEqual(@as(u64, 2), indexed.epoch);

    var latest = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer latest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), latest.indexes.len);
    const corrupt_path = try activePath(std.testing.allocator, ".", latest.indexes[0].path);
    defer std.testing.allocator.free(corrupt_path);
    try writeFile(std.testing.allocator, corrupt_path, "corrupt");
    try std.testing.expectError(TableError.VerifyFailed, verifyTable(std.testing.allocator, ".", table_name));

    const recovered = try recoverTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 2), recovered.row_count);
    try std.testing.expectEqual(@as(u64, 1), recovered.epoch);
    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();
    try std.testing.expectEqual(@as(usize, 0), snapshot.indexes.len);
    try std.testing.expectEqual(@as(u64, 300), try snapshotSumU64(snapshot, 1));
}

test "table recover skips corrupt highest dictionary artifact" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "recover_bad_dict";
    const schema_source =
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_STATUS_STRIDE = 8 // u64
    ;
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "recover_bad_dict.sadb-schema", schema_source);
    _ = try internStringDict(std.testing.allocator, ".", table_name, "status", "active");
    const paused = try internStringDict(std.testing.allocator, ".", table_name, "status", "paused");
    try std.testing.expectEqual(@as(u64, 2), paused.info.epoch);

    var latest = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer latest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), latest.dicts.len);
    const corrupt_path = try activePath(std.testing.allocator, ".", latest.dicts[0].path);
    defer std.testing.allocator.free(corrupt_path);
    try writeFile(std.testing.allocator, corrupt_path, "corrupt");
    try std.testing.expectError(TableError.VerifyFailed, verifyTable(std.testing.allocator, ".", table_name));

    const recovered = try recoverTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 0), recovered.row_count);
    try std.testing.expectEqual(@as(u64, 1), recovered.epoch);
    const active = try lookupStringDict(std.testing.allocator, ".", table_name, "status", "active");
    try std.testing.expect(active.found);
    try std.testing.expectEqual(@as(u64, 1), active.id);
    const missing_paused = try lookupStringDict(std.testing.allocator, ".", table_name, "status", "paused");
    try std.testing.expect(!missing_paused.found);
}

test "table recover completes committed transaction marker when manifest is stale" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "recover_committed_tx";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_POINTS_STRIDE = 8 // u64
    ;
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "recover_committed_tx.sadb-schema", schema_source);
    const indexed = try createU64Index(std.testing.allocator, ".", table_name, 0, true);
    try std.testing.expectEqual(@as(u64, 1), indexed.epoch);

    const manifest_path = try tableManifestPath(std.testing.allocator, ".", table_name);
    defer std.testing.allocator.free(manifest_path);
    const old_manifest = try readFileAlloc(std.testing.allocator, manifest_path, 1024 * 1024);
    defer std.testing.allocator.free(old_manifest);

    const tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    var row: [16]u8 = undefined;
    writeU64LE(&row, 0, 1);
    writeU64LE(&row, 8, 10);
    _ = try writeTransactionInsertRawRow(tx, &row);
    const committed = try commitWriteTransaction(std.testing.allocator, tx);
    try std.testing.expectEqual(@as(u64, 2), committed.epoch);
    destroyWriteTransaction(std.testing.allocator, tx);

    try writeFile(std.testing.allocator, manifest_path, old_manifest);
    const active_old = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 0), active_old.row_count);

    const recovered = try recoverTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 1), recovered.row_count);
    try std.testing.expectEqual(@as(u64, 2), recovered.epoch);
    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();
    try std.testing.expectEqual(@as(u64, 10), try snapshotSumU64(snapshot, 1));
}

test "table recover ignores incomplete transaction meta and cleans pending marker" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "recover_incomplete_tx";
    const schema_source =
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_POINTS_STRIDE = 8 // u64
    ;
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "recover_incomplete_tx.sadb-schema", schema_source);
    const indexed = try createU64Index(std.testing.allocator, ".", table_name, 0, true);
    try std.testing.expectEqual(@as(u64, 1), indexed.epoch);

    var tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    var row: [16]u8 = undefined;
    writeU64LE(&row, 0, 1);
    writeU64LE(&row, 8, 10);
    _ = try writeTransactionInsertRawRow(tx, &row);
    const target_epoch = tx.meta.epoch + 1;
    try writeTxPendingMarker(std.testing.allocator, ".", table_name, tx.meta.epoch, target_epoch);
    try rewriteSegmentsFromTransaction(std.testing.allocator, tx);
    try rebuildIndexes(std.testing.allocator, ".", &tx.meta);
    var written = try writeVersionedMeta(std.testing.allocator, ".", table_name, tx.meta);
    written.deinit(std.testing.allocator);
    destroyWriteTransaction(std.testing.allocator, tx);

    const active_before_recover = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 0), active_before_recover.row_count);
    try std.testing.expectEqual(@as(u64, 1), active_before_recover.epoch);

    const recovered = try recoverTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 0), recovered.row_count);
    try std.testing.expectEqual(@as(u64, 1), recovered.epoch);
    const pending_path = try txPendingMarkerPath(std.testing.allocator, ".", table_name, target_epoch);
    defer std.testing.allocator.free(pending_path);
    try std.testing.expect(!fileExists(pending_path));
}

test "table remove clears stale versioned files before reuse" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "reused_orders";
    const schema_source =
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_TOTAL_STRIDE = 8 // u64
    ;
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "reused_orders.sadb-schema", schema_source);
    var old_ids = [_]u64{ 1, 2 };
    var old_totals = [_]u64{ 100, 200 };
    const old_columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(old_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(old_totals[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, old_ids.len, &old_columns);
    _ = try createU64Index(std.testing.allocator, ".", table_name, 0, true);

    _ = try removeTable(std.testing.allocator, ".", table_name);

    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "reused_orders.sadb-schema", schema_source);
    var new_ids = [_]u64{9};
    var new_totals = [_]u64{900};
    const new_columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(new_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(new_totals[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, new_ids.len, &new_columns);

    const recovered = try recoverTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 1), recovered.row_count);
    try std.testing.expectEqual(@as(u64, 1), recovered.epoch);

    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();
    try std.testing.expectEqual(@as(u64, 1), snapshot.row_count);
    try std.testing.expectEqual(@as(u64, 900), try snapshotSumU64(snapshot, 1));
}

test "table remove preserves write lock file" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "locked_remove_orders";
    const schema_source =
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_TOTAL_STRIDE = 8 // u64
    ;
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "locked_remove_orders.sadb-schema", schema_source);

    var ids = [_]u64{1};
    var totals = [_]u64{100};
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(totals[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, ids.len, &columns);

    var write_lock = try acquireTableWriteLock(std.testing.allocator, ".", table_name);
    write_lock.release();

    const lock_path = try tableWriteLockPath(std.testing.allocator, ".", table_name);
    defer std.testing.allocator.free(lock_path);
    try std.fs.cwd().access(lock_path, .{});

    _ = try removeTable(std.testing.allocator, ".", table_name);
    try std.fs.cwd().access(lock_path, .{});

    var next_lock = try acquireTableWriteLock(std.testing.allocator, ".", table_name);
    next_lock.release();
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
