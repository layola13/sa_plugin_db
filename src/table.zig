const std = @import("std");
const builtin = @import("builtin");
const schema = @import("schema.zig");

var temp_write_counter = std.atomic.Value(u64).init(0);
var unsafe_no_sync_state = std.atomic.Value(u8).init(0);
var unsafe_init_meta_cache_mutex: std.Thread.Mutex = .{};
var unsafe_init_meta_cache_next_slot: usize = 0;
var unsafe_init_meta_cache = [_]?UnsafeInitMetaCacheEntry{null} ** 4;
const unsafe_init_cache_allocator = std.heap.page_allocator;
const UNSAFE_NO_SYNC_ENV = "SA_DB_UNSAFE_NO_SYNC";
const FILE_BLOCK_BYTES: usize = 64 * 1024;
const COLTX_INLINE_BYTES_LIMIT: usize = 128 * 1024;

fn isTruthyEnvValue(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or
        std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "TRUE") or
        std.mem.eql(u8, value, "yes") or
        std.mem.eql(u8, value, "YES");
}

fn detectUnsafeNoSyncModeFromProc() bool {
    if (builtin.os.tag != .linux) return false;

    var file = std.fs.openFileAbsolute("/proc/self/environ", .{}) catch return false;
    defer file.close();

    var buffer: [128 * 1024]u8 = undefined;
    const bytes_read = file.readAll(&buffer) catch return false;
    var entries = std.mem.splitScalar(u8, buffer[0..bytes_read], 0);
    while (entries.next()) |entry| {
        if (entry.len <= UNSAFE_NO_SYNC_ENV.len) continue;
        if (entry[UNSAFE_NO_SYNC_ENV.len] != '=') continue;
        if (!std.mem.eql(u8, entry[0..UNSAFE_NO_SYNC_ENV.len], UNSAFE_NO_SYNC_ENV)) continue;
        return isTruthyEnvValue(entry[UNSAFE_NO_SYNC_ENV.len + 1 ..]);
    }
    return false;
}

fn detectUnsafeNoSyncMode() bool {
    const value = std.posix.getenv(UNSAFE_NO_SYNC_ENV) orelse return detectUnsafeNoSyncModeFromProc();
    return isTruthyEnvValue(value);
}

fn skipDurabilitySync() bool {
    const cached = unsafe_no_sync_state.load(.acquire);
    if (cached != 0) return cached == 2;

    const enabled = detectUnsafeNoSyncMode();
    unsafe_no_sync_state.store(if (enabled) 2 else 1, .release);
    return enabled;
}

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

const StagedColumnFile = struct {
    staged_path: []u8,
    sha256: []u8,
    bytes: u64,
    block_size: u64 = 0,
    block_sha256: [][]const u8 = &.{},
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

pub const CreateIndexKind = enum(u32) {
    u64 = 1,
    i64 = 2,
    u32 = 3,
    i32 = 4,
    u8 = 5,
    i8 = 6,
    u16 = 7,
    i16 = 8,
    f32 = 9,
    f64 = 10,
    u64_pair = 11,
    u64_i64_pair = 12,
    blob_eq = 13,
    blob_token = 14,
    blob_prefix = 15,
    blob_contains = 16,
};

pub const CreateIndexRequest = struct {
    kind: CreateIndexKind,
    column_index: usize,
    column_index2: ?usize = null,
    store_name: ?[]const u8 = null,
    unique: bool = false,
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

const UnsafeInitMetaCacheEntry = struct {
    root_dir: []u8,
    table_name: []u8,
    meta: TableMeta,
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

pub const DictInternManyResult = struct {
    info: TableInfo,
    inserted_count: u64,
};

pub const DictLookupResult = struct {
    found: bool,
    id: u64,
};

const PendingDictWrite = struct {
    name: []const u8,
    path: []const u8,
    bytes: []u8,
};

const DictScanResult = struct {
    count: u64,
    found_id: ?u64,
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
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    write_lock: TableWriteLock,
    meta: TableMeta,
    buffers: []std.ArrayList(u8),
    pending_append_buffers: []std.ArrayList(u8),
    pending_dict_writes: []PendingDictWrite = &.{},
    base_row_count: u64,
    pending_append_row_count: u64 = 0,
    dirty: bool = false,
    rows_dirty: bool = false,

    pub fn deinit(self: *WriteTransaction, allocator: std.mem.Allocator) void {
        self.write_lock.release();
        self.meta.deinit(allocator);
        if (self.buffers.len != 0) freeColumnBuffers(allocator, self.buffers);
        if (self.pending_append_buffers.len != 0) freeColumnBuffers(allocator, self.pending_append_buffers);
        if (self.pending_dict_writes.len != 0) freePendingDictWrites(allocator, self.pending_dict_writes);
        allocator.free(self.root_dir);
        allocator.free(self.table_name);
        self.* = undefined;
    }
};

pub const ColumnBatch = struct {
    row_count: u64,
    files: ?[]StagedColumnFile = null,
    columns: ?[]RawColumnBytes = null,

    fn deinit(self: *ColumnBatch, allocator: std.mem.Allocator) void {
        if (self.files) |files| freeStagedColumnFiles(allocator, files, true);
        if (self.columns) |columns| freeOwnedRawColumnBytes(allocator, columns);
        self.* = undefined;
    }
};

pub const ColumnIngestSession = struct {
    root_dir: []const u8,
    table_name: []const u8,
    write_lock: TableWriteLock,
    meta: TableMeta,
    columns_len: usize,
    column_strides: []u32,
    batches: std.ArrayList(ColumnBatch),

    pub fn deinit(self: *ColumnIngestSession, allocator: std.mem.Allocator) void {
        self.write_lock.release();
        self.meta.deinit(allocator);
        for (self.batches.items) |*batch| batch.deinit(allocator);
        self.batches.deinit();
        allocator.free(self.column_strides);
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

const MappedReadRegion = struct {
    memory: []align(std.heap.page_size_min) const u8,
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

const U64I64PairKey = struct {
    key1: u64,
    key2: i64,
};

pub const U64RangeResult = struct {
    written: u64,
    total: u64,
};

pub const GroupSortBy = enum(u32) {
    key = 0,
    count = 1,
    sum = 2,
    min = 3,
    max = 4,
};

const U64I64GroupAccumulator = struct {
    key: u64,
    count: u64,
    sum: i64,
    min: i64,
    max: i64,
    ordinal: u64,
};

pub const PlanRowsResult = struct {
    written: u64,
    total: u64,
    first_predicate: u64,
    first_total: u64,
    second_total: u64,
};

pub const Plan3RowsResult = struct {
    written: u64,
    total: u64,
    first_predicate: u64,
    first_total: u64,
    second_predicate: u64,
    second_total: u64,
    third_predicate: u64,
    third_total: u64,
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

pub const ExportNullBitmapResult = struct {
    written_bytes: u64,
    row_count: u64,
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
    mapped_regions: []MappedReadRegion,

    pub fn destroy(self: *ReadSnapshot) void {
        const backing_allocator = self.backing_allocator;
        for (self.mapped_regions) |region| {
            if (region.memory.len != 0) std.posix.munmap(region.memory);
        }
        backing_allocator.free(self.mapped_regions);
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

fn hashHexFromDigestAlloc(allocator: std.mem.Allocator, hash: [32]u8) TableError![]u8 {
    const encoded = std.fmt.bytesToHex(hash, .lower);
    return allocator.dupe(u8, encoded[0..]) catch TableError.OutOfMemory;
}

fn optionalHashHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) TableError![]u8 {
    if (skipDurabilitySync()) return allocator.alloc(u8, 0) catch TableError.OutOfMemory;
    return hashHexAlloc(allocator, bytes);
}

fn validateOptionalSha256(expected_sha256: []const u8, bytes: []const u8) TableError!void {
    if (expected_sha256.len == 0) return;
    if (expected_sha256.len != 64) return TableError.VerifyFailed;
    const actual_sha256 = hashBytes(bytes);
    const actual_hex = std.fmt.bytesToHex(actual_sha256, .lower);
    if (!std.mem.eql(u8, actual_hex[0..], expected_sha256)) return TableError.VerifyFailed;
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

fn isParentMissing(err: anyerror) bool {
    return err == error.FileNotFound or err == error.PathAlreadyDoesNotExist;
}

fn createFileEnsuringParent(path: []const u8, flags: std.fs.File.CreateFlags) TableError!std.fs.File {
    return std.fs.cwd().createFile(path, flags) catch |err| {
        if (!isParentMissing(err)) return mapFileError(err);
        try ensureParentDir(path);
        return std.fs.cwd().createFile(path, flags) catch |retry_err| return mapFileError(retry_err);
    };
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

fn mappedReadFile(path: []const u8, expected_len: usize) TableError!MappedReadRegion {
    if (expected_len == 0) return .{ .memory = &[_]u8{} };
    var file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| return mapFileError(err);
    defer file.close();
    const stat = file.stat() catch |err| return mapFileError(err);
    if (stat.size != expected_len) return TableError.VerifyFailed;
    const mapped = std.posix.mmap(null, expected_len, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, file.handle, 0) catch |err| switch (err) {
        error.OutOfMemory => return TableError.OutOfMemory,
        error.MemoryMappingNotSupported, error.AccessDenied, error.PermissionDenied => return TableError.InvalidFormat,
        else => return TableError.InvalidFormat,
    };
    return .{ .memory = mapped };
}

fn readFileTail(path: []const u8, expected_len: usize, tail: []u8) TableError!void {
    if (tail.len == 0) return;
    if (expected_len < tail.len) return TableError.VerifyFailed;

    var file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| return mapFileError(err);
    defer file.close();
    const stat = file.stat() catch |err| return mapFileError(err);
    if (stat.size != expected_len) return TableError.VerifyFailed;
    _ = file.seekTo(expected_len - tail.len) catch |err| return mapFileError(err);
    const got = file.readAll(tail) catch |err| return mapFileError(err);
    if (got != tail.len) return TableError.VerifyFailed;
}

fn mappedRegionBytes(region: MappedReadRegion) []const u8 {
    return region.memory;
}

fn mappedSegmentColumnBytes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    segment: SegmentMeta,
    column_index: usize,
    expected_stride: u32,
) TableError!MappedReadRegion {
    if (column_index >= segment.files.len) return TableError.InvalidFormat;
    const file_meta = segment.files[column_index];
    const expected_len = try expectedColumnBytes(segment.rows, expected_stride);
    if (file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
    const path = try activePath(allocator, root_dir, file_meta.path);
    defer allocator.free(path);
    return mappedReadFile(path, expected_len);
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
    if (skipDurabilitySync()) return;
    const parent = std.fs.path.dirname(path) orelse ".";
    const dir_path = if (parent.len == 0) "." else parent;
    syncDirBestEffort(dir_path);
}

fn syncDirBestEffort(dir_path: []const u8) void {
    if (skipDurabilitySync()) return;
    var dir = std.fs.cwd().openDir(dir_path, .{}) catch return;
    defer dir.close();
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.fsync(dir.fd);
    }
}

fn syncFile(path: []const u8) TableError!void {
    if (skipDurabilitySync()) return;
    var file = std.fs.cwd().openFile(path, .{}) catch |err| return mapFileError(err);
    defer file.close();
    if (builtin.os.tag == .linux) {
        std.posix.fdatasync(file.handle) catch |err| return mapFileError(err);
    } else {
        file.sync() catch |err| return mapFileError(err);
    }
}

fn writeFileWithParentSync(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, sync_parent: bool) TableError!void {
    if (skipDurabilitySync()) {
        var file = try createFileEnsuringParent(path, .{ .truncate = true });
        defer file.close();
        file.writeAll(bytes) catch |err| return mapFileError(err);
        return;
    }

    const temp_path = try tempWritePath(allocator, path);
    defer allocator.free(temp_path);
    errdefer deleteIfExists(temp_path) catch {};

    {
        var file = try createFileEnsuringParent(temp_path, .{ .truncate = true, .exclusive = true });
        defer file.close();
        file.writeAll(bytes) catch |err| return mapFileError(err);
        if (!skipDurabilitySync()) {
            if (builtin.os.tag == .linux) {
                std.posix.fdatasync(file.handle) catch |err| return mapFileError(err);
            } else {
                file.sync() catch |err| return mapFileError(err);
            }
        }
    }

    std.fs.cwd().rename(temp_path, path) catch |err| return mapFileError(err);
    if (sync_parent) syncParentDirBestEffort(path);
}

fn writeFile(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) TableError!void {
    try writeFileWithParentSync(allocator, path, bytes, true);
}

fn writeArtifactFile(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) TableError!void {
    // Artifact files become durable only after a later meta/manifest publish points at them,
    // so avoid an extra parent-directory fsync for every intermediate artifact rewrite.
    try writeFileWithParentSync(allocator, path, bytes, false);
}

fn copyFile(allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) TableError!void {
    const temp_path = try tempWritePath(allocator, dst_path);
    defer allocator.free(temp_path);
    errdefer deleteIfExists(temp_path) catch {};

    try ensureParentDir(temp_path);

    std.fs.Dir.copyFile(std.fs.cwd(), src_path, std.fs.cwd(), temp_path, .{}) catch |err| return mapFileError(err);
    try syncFile(temp_path);
    std.fs.cwd().rename(temp_path, dst_path) catch |err| return mapFileError(err);
    syncParentDirBestEffort(dst_path);
}

fn appendFileBytesUnsafe(allocator: std.mem.Allocator, root_dir: []const u8, relative_path: []const u8, appended_bytes: []const u8) TableError!void {
    if (appended_bytes.len == 0) return;

    const path = try activePath(allocator, root_dir, relative_path);
    defer allocator.free(path);

    var file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| return mapFileError(err);
    defer file.close();
    _ = file.seekFromEnd(0) catch |err| return mapFileError(err);
    file.writeAll(appended_bytes) catch |err| return mapFileError(err);
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

fn loadRecoveredActiveMetaSource(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError![]u8 {
    var best: ?TableMeta = null;
    defer if (best) |*meta| meta.deinit(allocator);

    try scanVersionedRecoveryMetas(allocator, root_dir, table_name, &best);

    const compat_path = try tableMetaPath(allocator, root_dir, table_name);
    defer allocator.free(compat_path);
    try maybeSelectRecoveryMeta(allocator, root_dir, table_name, compat_path, &best);

    const recovered = best orelse return TableError.NotFound;
    return std.json.stringifyAlloc(allocator, recovered, .{}) catch |err| return mapJsonError(err);
}

fn readCompatMetaSource(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError![]u8 {
    const compat_path = try tableMetaPath(allocator, root_dir, table_name);
    defer allocator.free(compat_path);

    const source = try readFileAlloc(allocator, compat_path, 16 * 1024 * 1024);
    errdefer allocator.free(source);

    var parsed = try parseTableMeta(allocator, source);
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.table_name, table_name)) return TableError.InvalidFormat;
    return source;
}

fn parseOwnedTableMeta(allocator: std.mem.Allocator, source: []const u8, table_name: []const u8) TableError!TableMeta {
    const value = std.json.parseFromSliceLeaky(TableMeta, allocator, source, .{ .allocate = .alloc_always }) catch |err| return mapJsonError(err);
    if (!std.mem.eql(u8, value.table_name, table_name)) return TableError.InvalidFormat;
    if (!std.mem.eql(u8, value.magic, "sa-db-table-meta")) return TableError.InvalidFormat;
    if (value.version != 1) return TableError.InvalidFormat;
    return value;
}

fn loadCompatMeta(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError!TableMeta {
    const compat_path = try tableMetaPath(allocator, root_dir, table_name);
    defer allocator.free(compat_path);

    const source = try readFileAlloc(allocator, compat_path, 16 * 1024 * 1024);
    defer allocator.free(source);
    return parseOwnedTableMeta(allocator, source, table_name);
}

pub fn readActiveMetaSource(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError![]u8 {
    if (skipDurabilitySync()) {
        return readCompatMetaSource(allocator, root_dir, table_name) catch |err| switch (err) {
            TableError.NotFound => return try loadRecoveredActiveMetaSource(allocator, root_dir, table_name),
            else => return err,
        };
    }

    const manifest_path = try tableManifestPath(allocator, root_dir, table_name);
    defer allocator.free(manifest_path);

    const manifest_source = readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| switch (err) {
        TableError.NotFound => return try loadRecoveredActiveMetaSource(allocator, root_dir, table_name),
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
    try validateOptionalSha256(manifest.value.meta_sha256, meta_source);

    var parsed_meta = try parseTableMeta(allocator, meta_source);
    defer parsed_meta.deinit();
    if (!std.mem.eql(u8, parsed_meta.value.table_name, table_name)) return TableError.InvalidFormat;
    if (parsed_meta.value.epoch != manifest.value.epoch) return TableError.VerifyFailed;

    return meta_source;
}

pub fn loadActiveMeta(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError!TableMeta {
    if (skipDurabilitySync()) {
        return loadCompatMeta(allocator, root_dir, table_name) catch |err| switch (err) {
            TableError.NotFound => {
                if (try unsafeInitCachePeek(allocator, root_dir, table_name)) |meta| return meta;
                const source = loadRecoveredActiveMetaSource(allocator, root_dir, table_name) catch |recover_err| switch (recover_err) {
                    TableError.NotFound => return buildInitialMetaFromSchemaFile(allocator, root_dir, table_name),
                    else => return recover_err,
                };
                defer allocator.free(source);
                return parseOwnedTableMeta(allocator, source, table_name);
            },
            else => return err,
        };
    }

    const source = try readActiveMetaSource(allocator, root_dir, table_name);
    defer allocator.free(source);
    return parseOwnedTableMeta(allocator, source, table_name);
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

fn freeUnsafeInitCacheEntry(entry: *UnsafeInitMetaCacheEntry) void {
    unsafe_init_cache_allocator.free(entry.root_dir);
    unsafe_init_cache_allocator.free(entry.table_name);
    entry.meta.deinit(unsafe_init_cache_allocator);
}

fn unsafeInitCachePut(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta) TableError!void {
    if (!skipDurabilitySync()) return;

    _ = allocator;
    const owned_root = try unsafe_init_cache_allocator.dupe(u8, root_dir);
    errdefer unsafe_init_cache_allocator.free(owned_root);
    const owned_table = try unsafe_init_cache_allocator.dupe(u8, table_name);
    errdefer unsafe_init_cache_allocator.free(owned_table);
    const owned_meta = try duplicateTableMeta(unsafe_init_cache_allocator, meta);
    errdefer {
        var cleanup_meta = owned_meta;
        cleanup_meta.deinit(unsafe_init_cache_allocator);
    }

    unsafe_init_meta_cache_mutex.lock();
    defer unsafe_init_meta_cache_mutex.unlock();

    for (&unsafe_init_meta_cache) |*slot| {
        if (slot.*) |*entry| {
            if (!std.mem.eql(u8, entry.root_dir, root_dir) or !std.mem.eql(u8, entry.table_name, table_name)) continue;
            freeUnsafeInitCacheEntry(entry);
            slot.* = .{ .root_dir = owned_root, .table_name = owned_table, .meta = owned_meta };
            return;
        }
    }

    for (&unsafe_init_meta_cache) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .root_dir = owned_root, .table_name = owned_table, .meta = owned_meta };
            return;
        }
    }

    const slot = &unsafe_init_meta_cache[unsafe_init_meta_cache_next_slot];
    freeUnsafeInitCacheEntry(&(slot.*.?));
    slot.* = .{ .root_dir = owned_root, .table_name = owned_table, .meta = owned_meta };
    unsafe_init_meta_cache_next_slot = (unsafe_init_meta_cache_next_slot + 1) % unsafe_init_meta_cache.len;
}

fn unsafeInitCacheTake(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError!?TableMeta {
    if (!skipDurabilitySync()) return null;

    unsafe_init_meta_cache_mutex.lock();
    defer unsafe_init_meta_cache_mutex.unlock();

    for (&unsafe_init_meta_cache) |*slot| {
        if (slot.*) |*entry| {
            if (!std.mem.eql(u8, entry.root_dir, root_dir) or !std.mem.eql(u8, entry.table_name, table_name)) continue;

            const meta = try duplicateTableMeta(allocator, entry.meta);
            freeUnsafeInitCacheEntry(entry);
            slot.* = null;
            return meta;
        }
    }
    return null;
}

fn unsafeInitCachePeek(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) TableError!?TableMeta {
    if (!skipDurabilitySync()) return null;

    unsafe_init_meta_cache_mutex.lock();
    defer unsafe_init_meta_cache_mutex.unlock();

    for (&unsafe_init_meta_cache) |*slot| {
        if (slot.*) |entry| {
            if (!std.mem.eql(u8, entry.root_dir, root_dir) or !std.mem.eql(u8, entry.table_name, table_name)) continue;
            return try duplicateTableMeta(allocator, entry.meta);
        }
    }
    return null;
}

fn unsafeInitCacheDelete(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8) void {
    _ = allocator;
    unsafe_init_meta_cache_mutex.lock();
    defer unsafe_init_meta_cache_mutex.unlock();

    for (&unsafe_init_meta_cache) |*slot| {
        if (slot.*) |*entry| {
            if (!std.mem.eql(u8, entry.root_dir, root_dir) or !std.mem.eql(u8, entry.table_name, table_name)) continue;
            freeUnsafeInitCacheEntry(entry);
            slot.* = null;
        }
    }
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

fn buildInitialMetaFromSchemaFile(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
) TableError!TableMeta {
    const schema_path = try schemaMetaPath(allocator, root_dir, table_name);
    defer allocator.free(schema_path);
    const schema_source = try readFileAlloc(allocator, schema_path, 16 * 1024 * 1024);
    defer allocator.free(schema_source);
    const schema_hash = try hashHexAlloc(allocator, schema_source);
    defer allocator.free(schema_hash);

    var schema_obj = schema.compile(allocator, schema_source, schema_path) catch |err| return mapSchemaError(err);
    defer schema_obj.deinit();
    return buildInitialMeta(allocator, table_name, schema_path, schema_hash, schema_obj);
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
    if (skipDurabilitySync()) {
        const out = try allocator.alloc([]const u8, 0);
        return out;
    }
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

fn makeFileHashesSinglePass(allocator: std.mem.Allocator, bytes: []const u8, block_size: usize) TableError!struct {
    sha256: []const u8,
    block_size: u64,
    block_sha256: [][]const u8,
} {
    if (bytes.len == 0) {
        const sha256 = try optionalHashHexAlloc(allocator, bytes);
        errdefer allocator.free(sha256);
        const block_sha256 = try allocator.alloc([]const u8, 0);
        return .{ .sha256 = sha256, .block_size = 0, .block_sha256 = block_sha256 };
    }
    if (skipDurabilitySync()) {
        const sha256 = try optionalHashHexAlloc(allocator, bytes);
        errdefer allocator.free(sha256);
        const block_sha256 = try allocator.alloc([]const u8, 0);
        return .{ .sha256 = sha256, .block_size = 0, .block_sha256 = block_sha256 };
    }
    if (block_size == 0) return TableError.InvalidFormat;

    const count = blockHashCount(bytes.len, block_size);
    const block_sha256 = try allocator.alloc([]const u8, count);
    for (block_sha256) |*hash| hash.* = &.{};
    errdefer freeBlockSha256List(allocator, block_sha256);

    var file_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (block_sha256, 0..) |*slot, idx| {
        const start = idx * block_size;
        const end = @min(start + block_size, bytes.len);
        const block = bytes[start..end];
        file_hasher.update(block);

        var block_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        block_hasher.update(block);
        var block_digest: [32]u8 = undefined;
        block_hasher.final(&block_digest);
        slot.* = try hashHexFromDigestAlloc(allocator, block_digest);
    }

    var file_digest: [32]u8 = undefined;
    file_hasher.final(&file_digest);
    const sha256 = try hashHexFromDigestAlloc(allocator, file_digest);
    errdefer allocator.free(sha256);

    return .{ .sha256 = sha256, .block_size = block_size, .block_sha256 = block_sha256 };
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
    if (skipDurabilitySync()) return 0;
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

fn validateHashesSinglePass(
    allocator: std.mem.Allocator,
    expected_sha256: []const u8,
    block_size_value: u64,
    expected_block_sha256: []const []const u8,
    bytes: []const u8,
) TableError!void {
    _ = allocator;
    if (expected_sha256.len == 0) {
        if (block_size_value != 0 or expected_block_sha256.len != 0) return TableError.VerifyFailed;
        return;
    }
    if (expected_sha256.len != 64) return TableError.VerifyFailed;
    if (block_size_value == 0) {
        if (expected_block_sha256.len != 0) return TableError.VerifyFailed;
        try validateOptionalSha256(expected_sha256, bytes);
        return;
    }

    if (block_size_value > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.VerifyFailed;
    const block_size: usize = @intCast(block_size_value);
    if (block_size == 0) return TableError.VerifyFailed;

    const expected_count = blockHashCount(bytes.len, block_size);
    if (expected_block_sha256.len != expected_count) return TableError.VerifyFailed;

    var file_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (expected_block_sha256, 0..) |expected_hash, idx| {
        if (expected_hash.len != 64) return TableError.VerifyFailed;
        const start = idx * block_size;
        const end = @min(start + block_size, bytes.len);
        const block = bytes[start..end];
        file_hasher.update(block);

        var block_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        block_hasher.update(block);
        var block_digest: [32]u8 = undefined;
        block_hasher.final(&block_digest);
        const block_hex = std.fmt.bytesToHex(block_digest, .lower);
        if (!std.mem.eql(u8, block_hex[0..], expected_hash)) return TableError.VerifyFailed;
    }

    var file_digest: [32]u8 = undefined;
    file_hasher.final(&file_digest);
    const file_hex = std.fmt.bytesToHex(file_digest, .lower);
    if (!std.mem.eql(u8, file_hex[0..], expected_sha256)) return TableError.VerifyFailed;
}

fn makeFileMeta(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) TableError!FileMeta {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const hashes = try makeFileHashesSinglePass(allocator, bytes, FILE_BLOCK_BYTES);
    errdefer allocator.free(hashes.sha256);
    errdefer freeBlockSha256List(allocator, hashes.block_sha256);
    return .{
        .path = owned_path,
        .sha256 = hashes.sha256,
        .bytes = bytes.len,
        .block_size = hashes.block_size,
        .block_sha256 = hashes.block_sha256,
    };
}

fn freeFileMeta(allocator: std.mem.Allocator, file: FileMeta) void {
    allocator.free(file.path);
    allocator.free(file.sha256);
    freeBlockSha256List(allocator, file.block_sha256);
}

fn emptyStagedColumnFile() StagedColumnFile {
    return .{ .staged_path = &.{}, .sha256 = &.{}, .bytes = 0, .block_size = 0, .block_sha256 = &.{} };
}

fn initStagedColumnFiles(files: []StagedColumnFile) void {
    for (files) |*file| file.* = emptyStagedColumnFile();
}

fn freeStagedColumnFile(allocator: std.mem.Allocator, file: StagedColumnFile, delete_path: bool) void {
    if (delete_path and file.staged_path.len != 0) deleteIfExists(file.staged_path) catch {};
    allocator.free(file.staged_path);
    allocator.free(file.sha256);
    freeBlockSha256List(allocator, file.block_sha256);
}

fn freeStagedColumnFiles(allocator: std.mem.Allocator, files: []StagedColumnFile, delete_paths: bool) void {
    for (files) |file| freeStagedColumnFile(allocator, file, delete_paths);
    allocator.free(files);
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
    try validateHashesSinglePass(std.heap.page_allocator, file.sha256, file.block_size, file.block_sha256, bytes);
}

fn validateFileMetaPath(allocator: std.mem.Allocator, root_dir: []const u8, file: FileMeta) TableError!void {
    const path = try activePath(allocator, root_dir, file.path);
    defer allocator.free(path);
    const mapped = try mappedReadFile(path, @intCast(file.bytes));
    defer if (mapped.memory.len != 0) std.posix.munmap(mapped.memory);
    try validateFileMetaBytes(file, mappedRegionBytes(mapped));
}

fn validateIndexMetaPath(allocator: std.mem.Allocator, root_dir: []const u8, index: IndexMeta) TableError!MappedReadRegion {
    const path = try activePath(allocator, root_dir, index.path);
    defer allocator.free(path);
    const mapped = try mappedReadFile(path, @intCast(index.bytes));
    const bytes = mappedRegionBytes(mapped);
    try validateHashesSinglePass(allocator, index.sha256, index.block_size, index.block_sha256, bytes);
    return mapped;
}

fn validateDictMetaPath(allocator: std.mem.Allocator, root_dir: []const u8, dict: DictMeta) TableError!void {
    const path = try activePath(allocator, root_dir, dict.path);
    defer allocator.free(path);
    const mapped = try mappedReadFile(path, @intCast(dict.bytes));
    defer if (mapped.memory.len != 0) std.posix.munmap(mapped.memory);
    const bytes = mappedRegionBytes(mapped);
    const count = try dictEntryCount(bytes);
    if (count != dict.entries) return TableError.VerifyFailed;
    try validateHashesSinglePass(allocator, dict.sha256, dict.block_size, dict.block_sha256, bytes);
}

fn validateBlobStoreMetaPath(allocator: std.mem.Allocator, root_dir: []const u8, blob: BlobStoreMeta) TableError!void {
    const path = try activePath(allocator, root_dir, blob.path);
    defer allocator.free(path);
    const mapped = try mappedReadFile(path, @intCast(blob.bytes));
    defer if (mapped.memory.len != 0) std.posix.munmap(mapped.memory);
    const bytes = mappedRegionBytes(mapped);
    const count = try blobEntryCount(bytes);
    if (count != blob.entries) return TableError.VerifyFailed;
    try validateHashesSinglePass(allocator, blob.sha256, blob.block_size, blob.block_sha256, bytes);
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
        try writeFileWithParentSync(allocator, path, buffer.items, false);
        files[idx] = try makeFileMeta(allocator, basename, buffer.items);
    }
    const dir_sync_path = try activePath(allocator, root_dir, table_name);
    defer allocator.free(dir_sync_path);
    syncParentDirBestEffort(dir_sync_path);

    return files;
}

fn writeSegmentRawFiles(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    seg_id: u64,
    columns: []const RawColumnBytes,
) TableError![]FileMeta {
    const files = try allocator.alloc(FileMeta, columns.len);
    initFileMetas(files);
    errdefer {
        for (files) |file| freeFileMeta(allocator, file);
        allocator.free(files);
    }

    for (columns, 0..) |column, idx| {
        const basename = try segmentFileName(allocator, table_name, seg_id, idx);
        defer allocator.free(basename);
        const path = try activePath(allocator, root_dir, basename);
        defer allocator.free(path);
        try writeFileWithParentSync(allocator, path, column.bytes, false);
        files[idx] = try makeFileMeta(allocator, basename, column.bytes);
    }
    const dir_sync_path = try activePath(allocator, root_dir, table_name);
    defer allocator.free(dir_sync_path);
    syncParentDirBestEffort(dir_sync_path);

    return files;
}

fn stageRawColumnFiles(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    columns: []const RawColumnBytes,
) TableError![]StagedColumnFile {
    const batch_id = temp_write_counter.fetchAdd(1, .monotonic);
    const files = try allocator.alloc(StagedColumnFile, columns.len);
    initStagedColumnFiles(files);
    errdefer freeStagedColumnFiles(allocator, files, true);

    for (columns, 0..) |column, idx| {
        const staged_name = try allocPrintPath(allocator, "{s}.stage.{d}.{d}.dat", .{ table_name, batch_id, idx });
        defer allocator.free(staged_name);
        const staged_path = try activePath(allocator, root_dir, staged_name);
        errdefer allocator.free(staged_path);
        try writeFileWithParentSync(allocator, staged_path, column.bytes, false);

        const hashes = try makeFileHashesSinglePass(allocator, column.bytes, FILE_BLOCK_BYTES);
        errdefer allocator.free(hashes.sha256);
        errdefer freeBlockSha256List(allocator, hashes.block_sha256);

        files[idx] = .{
            .staged_path = staged_path,
            .sha256 = @constCast(hashes.sha256),
            .bytes = column.bytes.len,
            .block_size = hashes.block_size,
            .block_sha256 = hashes.block_sha256,
        };
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

fn indexExistsConflict(meta: TableMeta, request: CreateIndexRequest) TableError!bool {
    for (meta.indexes) |index| {
        switch (request.kind) {
            .u64, .i64, .u32, .i32, .u8, .i8, .u16, .i16, .f32, .f64 => {
                const kind_name = switch (request.kind) {
                    .u64 => "u64",
                    .i64 => "i64",
                    .u32 => "u32",
                    .i32 => "i32",
                    .u8 => "u8",
                    .i8 => "i8",
                    .u16 => "u16",
                    .i16 => "i16",
                    .f32 => "f32",
                    .f64 => "f64",
                    else => unreachable,
                };
                if (std.mem.eql(u8, index.kind, kind_name) and index.column_index == @as(u64, @intCast(request.column_index))) {
                    if (index.unique == request.unique) return true;
                    return TableError.InvalidFormat;
                }
            },
            .u64_pair, .u64_i64_pair => {
                const kind_name = if (request.kind == .u64_pair) "u64_pair" else "u64_i64_pair";
                const column_index2 = request.column_index2 orelse return TableError.InvalidFormat;
                if (std.mem.eql(u8, index.kind, kind_name) and
                    index.column_index == @as(u64, @intCast(request.column_index)) and
                    index.column_index2 != null and
                    index.column_index2.? == @as(u64, @intCast(column_index2)))
                {
                    if (index.unique == request.unique) return true;
                    return TableError.InvalidFormat;
                }
            },
            .blob_eq, .blob_token, .blob_prefix, .blob_contains => {
                const kind_name = switch (request.kind) {
                    .blob_eq => BLOB_EQ_INDEX_KIND,
                    .blob_token => BLOB_TOKEN_INDEX_KIND,
                    .blob_prefix => BLOB_PREFIX_INDEX_KIND,
                    .blob_contains => BLOB_CONTAINS_INDEX_KIND,
                    else => unreachable,
                };
                const store_name = request.store_name orelse return TableError.InvalidFormat;
                if (std.mem.eql(u8, index.kind, kind_name) and
                    index.column_index == @as(u64, @intCast(request.column_index)) and
                    index.column_index2 == null and
                    index.store_name != null and
                    std.mem.eql(u8, index.store_name.?, store_name))
                {
                    if (request.kind == .blob_eq) {
                        if (index.unique == request.unique) return true;
                        return TableError.InvalidFormat;
                    }
                    return true;
                }
            },
        }
    }
    return false;
}

fn validateCreateIndexRequest(meta: TableMeta, request: CreateIndexRequest) TableError!void {
    switch (request.kind) {
        .u64 => try ensureU64Column(meta, request.column_index),
        .i64 => try ensureI64Column(meta, request.column_index),
        .u32 => try ensureU32Column(meta, request.column_index),
        .i32 => try ensureI32Column(meta, request.column_index),
        .u8 => try ensureU8Column(meta, request.column_index),
        .i8 => try ensureI8Column(meta, request.column_index),
        .u16 => try ensureU16Column(meta, request.column_index),
        .i16 => try ensureI16Column(meta, request.column_index),
        .f32 => try ensureF32Column(meta, request.column_index),
        .f64 => try ensureF64Column(meta, request.column_index),
        .u64_pair => try ensureU64PairColumns(meta, request.column_index, request.column_index2 orelse return TableError.InvalidFormat),
        .u64_i64_pair => try ensureU64I64PairColumns(meta, request.column_index, request.column_index2 orelse return TableError.InvalidFormat),
        .blob_eq => {
            const store_name = request.store_name orelse return TableError.InvalidFormat;
            try validateBlobStoreName(store_name);
            try ensureBlobHandleColumn(meta, request.column_index);
        },
        .blob_token, .blob_prefix, .blob_contains => {
            const store_name = request.store_name orelse return TableError.InvalidFormat;
            try validateBlobStoreName(store_name);
            try ensureBlobHandleColumn(meta, request.column_index);
        },
    }
}

fn makeIndexMetaFromRequest(allocator: std.mem.Allocator, request: CreateIndexRequest) TableError!IndexMeta {
    return switch (request.kind) {
        .u64 => .{
            .name = try allocPrintPath(allocator, "u64_col{d}", .{request.column_index}),
            .kind = try allocator.dupe(u8, "u64"),
            .column_index = @intCast(request.column_index),
            .column_index2 = null,
            .unique = request.unique,
            .path = try allocator.dupe(u8, ""),
            .sha256 = try allocator.dupe(u8, ""),
            .bytes = 0,
        },
        .i64 => .{
            .name = try allocPrintPath(allocator, "i64_col{d}", .{request.column_index}),
            .kind = try allocator.dupe(u8, "i64"),
            .column_index = @intCast(request.column_index),
            .column_index2 = null,
            .unique = request.unique,
            .path = try allocator.dupe(u8, ""),
            .sha256 = try allocator.dupe(u8, ""),
            .bytes = 0,
        },
        .u32 => .{
            .name = try allocPrintPath(allocator, "u32_col{d}", .{request.column_index}),
            .kind = try allocator.dupe(u8, "u32"),
            .column_index = @intCast(request.column_index),
            .column_index2 = null,
            .unique = request.unique,
            .path = try allocator.dupe(u8, ""),
            .sha256 = try allocator.dupe(u8, ""),
            .bytes = 0,
        },
        .i32 => .{
            .name = try allocPrintPath(allocator, "i32_col{d}", .{request.column_index}),
            .kind = try allocator.dupe(u8, "i32"),
            .column_index = @intCast(request.column_index),
            .column_index2 = null,
            .unique = request.unique,
            .path = try allocator.dupe(u8, ""),
            .sha256 = try allocator.dupe(u8, ""),
            .bytes = 0,
        },
        .u8, .i8, .u16, .i16, .f32, .f64 => blk: {
            const kind_name = switch (request.kind) {
                .u8 => "u8",
                .i8 => "i8",
                .u16 => "u16",
                .i16 => "i16",
                .f32 => "f32",
                .f64 => "f64",
                else => unreachable,
            };
            break :blk .{
                .name = try allocPrintPath(allocator, "{s}_col{d}", .{ kind_name, request.column_index }),
                .kind = try allocator.dupe(u8, kind_name),
                .column_index = @intCast(request.column_index),
                .column_index2 = null,
                .unique = request.unique,
                .path = try allocator.dupe(u8, ""),
                .sha256 = try allocator.dupe(u8, ""),
                .bytes = 0,
            };
        },
        .u64_pair => .{
            .name = try allocPrintPath(allocator, "u64_pair_col{d}_col{d}", .{ request.column_index, request.column_index2.? }),
            .kind = try allocator.dupe(u8, "u64_pair"),
            .column_index = @intCast(request.column_index),
            .column_index2 = @intCast(request.column_index2.?),
            .unique = request.unique,
            .path = try allocator.dupe(u8, ""),
            .sha256 = try allocator.dupe(u8, ""),
            .bytes = 0,
        },
        .u64_i64_pair => .{
            .name = try allocPrintPath(allocator, "u64_i64_pair_col{d}_col{d}", .{ request.column_index, request.column_index2.? }),
            .kind = try allocator.dupe(u8, "u64_i64_pair"),
            .column_index = @intCast(request.column_index),
            .column_index2 = @intCast(request.column_index2.?),
            .unique = request.unique,
            .path = try allocator.dupe(u8, ""),
            .sha256 = try allocator.dupe(u8, ""),
            .bytes = 0,
        },
        .blob_eq => .{
            .name = try allocPrintPath(allocator, "blob_eq_col{d}_{s}", .{ request.column_index, request.store_name.? }),
            .kind = try allocator.dupe(u8, BLOB_EQ_INDEX_KIND),
            .column_index = @intCast(request.column_index),
            .column_index2 = null,
            .store_name = try allocator.dupe(u8, request.store_name.?),
            .unique = request.unique,
            .path = try allocator.dupe(u8, ""),
            .sha256 = try allocator.dupe(u8, ""),
            .bytes = 0,
        },
        .blob_token => .{
            .name = try allocPrintPath(allocator, "blob_token_col{d}_{s}", .{ request.column_index, request.store_name.? }),
            .kind = try allocator.dupe(u8, BLOB_TOKEN_INDEX_KIND),
            .column_index = @intCast(request.column_index),
            .column_index2 = null,
            .store_name = try allocator.dupe(u8, request.store_name.?),
            .unique = false,
            .path = try allocator.dupe(u8, ""),
            .sha256 = try allocator.dupe(u8, ""),
            .bytes = 0,
        },
        .blob_prefix => .{
            .name = try allocPrintPath(allocator, "blob_prefix_col{d}_{s}", .{ request.column_index, request.store_name.? }),
            .kind = try allocator.dupe(u8, BLOB_PREFIX_INDEX_KIND),
            .column_index = @intCast(request.column_index),
            .column_index2 = null,
            .store_name = try allocator.dupe(u8, request.store_name.?),
            .unique = false,
            .path = try allocator.dupe(u8, ""),
            .sha256 = try allocator.dupe(u8, ""),
            .bytes = 0,
        },
        .blob_contains => .{
            .name = try allocPrintPath(allocator, "blob_contains_col{d}_{s}", .{ request.column_index, request.store_name.? }),
            .kind = try allocator.dupe(u8, BLOB_CONTAINS_INDEX_KIND),
            .column_index = @intCast(request.column_index),
            .column_index2 = null,
            .store_name = try allocator.dupe(u8, request.store_name.?),
            .unique = false,
            .path = try allocator.dupe(u8, ""),
            .sha256 = try allocator.dupe(u8, ""),
            .bytes = 0,
        },
    };
}

fn createIndexesForTableLocked(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    meta: *TableMeta,
    requests: []const CreateIndexRequest,
) TableError!TableInfo {
    if (meta.locked) return TableError.Locked;
    if (requests.len == 0) return tableInfo(meta.*);

    var add_count: usize = 0;
    for (requests) |request| {
        try validateCreateIndexRequest(meta.*, request);
        if (!(try indexExistsConflict(meta.*, request))) add_count += 1;
    }
    if (add_count == 0) return tableInfo(meta.*);

    const old_indexes = meta.indexes;
    const new_indexes = try allocator.alloc(IndexMeta, old_indexes.len + add_count);
    initIndexMetas(new_indexes);
    var assigned_indexes = false;
    errdefer if (!assigned_indexes) freeIndexMetas(allocator, new_indexes);

    for (old_indexes, 0..) |index, idx| {
        new_indexes[idx] = try duplicateIndexMeta(allocator, index);
    }

    var next_idx = old_indexes.len;
    for (requests) |request| {
        if (try indexExistsConflict(meta.*, request)) continue;
        new_indexes[next_idx] = try makeIndexMetaFromRequest(allocator, request);
        next_idx += 1;
    }

    freeIndexMetas(allocator, old_indexes);
    meta.indexes = new_indexes;
    assigned_indexes = true;
    meta.epoch += 1;

    for (old_indexes.len..meta.indexes.len) |idx| {
        try rebuildIndexAt(allocator, root_dir, meta, idx);
    }
    try writeMeta(allocator, root_dir, table_name, meta.*);
    return tableInfo(meta.*);
}

pub fn createIndexes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    requests: []const CreateIndexRequest,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadWritableMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    return createIndexesForTableLocked(allocator, root_dir, table_name, &meta, requests);
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

fn freePendingDictWrites(allocator: std.mem.Allocator, writes: []PendingDictWrite) void {
    for (writes) |write| {
        allocator.free(write.name);
        allocator.free(write.path);
        allocator.free(write.bytes);
    }
    allocator.free(writes);
}

fn findPendingDictWriteIndex(tx: *const WriteTransaction, dict_name: []const u8) ?usize {
    for (tx.pending_dict_writes, 0..) |write, idx| {
        if (std.mem.eql(u8, write.name, dict_name)) return idx;
    }
    return null;
}

fn putPendingDictWrite(allocator: std.mem.Allocator, tx: *WriteTransaction, dict_name: []const u8, path: []const u8, bytes: []u8) TableError!void {
    const owned_name = try allocator.dupe(u8, dict_name);
    errdefer allocator.free(owned_name);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);

    if (findPendingDictWriteIndex(tx, dict_name)) |idx| {
        allocator.free(tx.pending_dict_writes[idx].name);
        allocator.free(tx.pending_dict_writes[idx].path);
        allocator.free(tx.pending_dict_writes[idx].bytes);
        tx.pending_dict_writes[idx] = .{
            .name = owned_name,
            .path = owned_path,
            .bytes = bytes,
        };
        return;
    }

    const old_writes = tx.pending_dict_writes;
    const new_writes = try allocator.alloc(PendingDictWrite, old_writes.len + 1);
    @memcpy(new_writes[0..old_writes.len], old_writes);
    new_writes[old_writes.len] = .{
        .name = owned_name,
        .path = owned_path,
        .bytes = bytes,
    };
    allocator.free(old_writes);
    tx.pending_dict_writes = new_writes;
}

fn flushPendingDictWrites(allocator: std.mem.Allocator, tx: *WriteTransaction) TableError!void {
    for (tx.pending_dict_writes) |write| {
        const path = try activePath(allocator, tx.root_dir, write.path);
        defer allocator.free(path);
        try writeFile(allocator, path, write.bytes);
    }
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
    const files = try writeSegmentFiles(allocator, root_dir, table_name, meta.next_segment_id, buffers);
    errdefer freeFileMetas(allocator, files);

    const new_segments = try allocator.alloc(SegmentMeta, old_segments.len + 1);
    errdefer allocator.free(new_segments);
    @memcpy(new_segments[0..old_segments.len], old_segments);
    new_segments[old_segments.len] = .{
        .id = meta.next_segment_id,
        .rows = row_count,
        .files = files,
    };

    allocator.free(old_segments);
    meta.segments = new_segments;
    meta.row_count = std.math.add(u64, meta.row_count, row_count) catch return TableError.CursorOverflow;
    meta.epoch += 1;
    meta.next_segment_id += 1;
}

fn appendRawSegmentToMeta(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    meta: *TableMeta,
    columns: []const RawColumnBytes,
    row_count: u64,
) TableError!void {
    const old_segments = meta.segments;
    const files = try writeSegmentRawFiles(allocator, root_dir, table_name, meta.next_segment_id, columns);
    errdefer freeFileMetas(allocator, files);

    const new_segments = try allocator.alloc(SegmentMeta, old_segments.len + 1);
    errdefer allocator.free(new_segments);
    @memcpy(new_segments[0..old_segments.len], old_segments);
    new_segments[old_segments.len] = .{
        .id = meta.next_segment_id,
        .rows = row_count,
        .files = files,
    };

    allocator.free(old_segments);
    meta.segments = new_segments;
    meta.row_count = std.math.add(u64, meta.row_count, row_count) catch return TableError.CursorOverflow;
    meta.epoch += 1;
    meta.next_segment_id += 1;
}

fn appendRawColumnsToLastSegmentUnsafe(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: *TableMeta,
    columns: []const RawColumnBytes,
    row_count: u64,
) TableError!void {
    if (!skipDurabilitySync()) return TableError.InvalidFormat;
    if (meta.segments.len == 0) return TableError.InvalidFormat;
    if (columns.len != meta.columns.len) return TableError.InvalidFormat;

    const segment = &meta.segments[meta.segments.len - 1];
    if (segment.files.len != columns.len) return TableError.InvalidFormat;

    for (columns, 0..) |column, idx| {
        const expected_len = std.math.mul(u64, row_count, meta.columns[idx].stride) catch return TableError.CursorOverflow;
        if (column.bytes.len != expected_len) return TableError.InvalidFormat;
        try appendFileBytesUnsafe(allocator, root_dir, segment.files[idx].path, column.bytes);

        allocator.free(segment.files[idx].sha256);
        freeBlockSha256List(allocator, segment.files[idx].block_sha256);
        segment.files[idx].sha256 = try allocator.alloc(u8, 0);
        segment.files[idx].bytes = std.math.add(u64, segment.files[idx].bytes, column.bytes.len) catch return TableError.CursorOverflow;
        segment.files[idx].block_size = 0;
        segment.files[idx].block_sha256 = try allocator.alloc([]const u8, 0);
    }

    segment.rows = std.math.add(u64, segment.rows, row_count) catch return TableError.CursorOverflow;
    meta.row_count = std.math.add(u64, meta.row_count, row_count) catch return TableError.CursorOverflow;
    meta.epoch += 1;
}

fn publishStagedSegmentToMeta(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    meta: *TableMeta,
    staged_files: []StagedColumnFile,
    row_count: u64,
) TableError!void {
    const old_segments = meta.segments;
    const files = try allocator.alloc(FileMeta, staged_files.len);
    initFileMetas(files);
    errdefer freeFileMetas(allocator, files);

    for (staged_files, 0..) |*staged_file, idx| {
        const basename = try segmentFileName(allocator, table_name, meta.next_segment_id, idx);
        errdefer allocator.free(basename);
        const final_path = try activePath(allocator, root_dir, basename);
        defer allocator.free(final_path);
        std.fs.cwd().rename(staged_file.staged_path, final_path) catch |err| return mapFileError(err);

        allocator.free(staged_file.staged_path);
        staged_file.staged_path = &.{};

        files[idx] = .{
            .path = basename,
            .sha256 = staged_file.sha256,
            .bytes = staged_file.bytes,
            .block_size = staged_file.block_size,
            .block_sha256 = staged_file.block_sha256,
        };
        staged_file.sha256 = &.{};
        staged_file.bytes = 0;
        staged_file.block_size = 0;
        staged_file.block_sha256 = &.{};
    }

    const dir_sync_path = try activePath(allocator, root_dir, table_name);
    defer allocator.free(dir_sync_path);
    syncParentDirBestEffort(dir_sync_path);

    const new_segments = try allocator.alloc(SegmentMeta, old_segments.len + 1);
    errdefer allocator.free(new_segments);
    @memcpy(new_segments[0..old_segments.len], old_segments);
    new_segments[old_segments.len] = .{
        .id = meta.next_segment_id,
        .rows = row_count,
        .files = files,
    };

    allocator.free(old_segments);
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

fn loadWritableMeta(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
) TableError!TableMeta {
    if (skipDurabilitySync()) {
        return loadCompatMeta(allocator, root_dir, table_name) catch |err| switch (err) {
            TableError.NotFound => {
                if (try unsafeInitCacheTake(allocator, root_dir, table_name)) |meta| return meta;
                const source = loadRecoveredActiveMetaSource(allocator, root_dir, table_name) catch |recover_err| switch (recover_err) {
                    TableError.NotFound => return buildInitialMetaFromSchemaFile(allocator, root_dir, table_name),
                    else => return recover_err,
                };
                defer allocator.free(source);
                return parseOwnedTableMeta(allocator, source, table_name);
            },
            else => return err,
        };
    }

    return loadActiveMeta(allocator, root_dir, table_name) catch |err| switch (err) {
        TableError.NotFound => {
            if (try unsafeInitCacheTake(allocator, root_dir, table_name)) |meta| return meta;
            return buildInitialMetaFromSchemaFile(allocator, root_dir, table_name);
        },
        else => return err,
    };
}

fn appendRawColumnsWithLoadedMeta(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    meta: *TableMeta,
    row_count: u64,
    columns: []const RawColumnBytes,
) TableError!TableInfo {
    if (meta.locked) return TableError.Locked;
    if (columns.len != meta.columns.len) return TableError.InvalidFormat;
    const total_rows = std.math.add(u64, meta.row_count, row_count) catch return TableError.CursorOverflow;
    if (total_rows > meta.max_rows) return TableError.CursorOverflow;

    for (columns, 0..) |column, idx| {
        const expected_len = std.math.mul(u64, row_count, meta.columns[idx].stride) catch return TableError.CursorOverflow;
        if (column.bytes.len != expected_len) return TableError.InvalidFormat;
    }

    const previous_row_count = meta.row_count;
    if (skipDurabilitySync() and meta.segments.len != 0) {
        const base_segment = meta.segments[meta.segments.len - 1];
        const appended_segment = SegmentMeta{
            .id = base_segment.id,
            .rows = row_count,
            .files = base_segment.files,
        };
        try appendRawColumnsToLastSegmentUnsafe(allocator, root_dir, meta, columns, row_count);
        const incremental_ok = try tryAppendIndexesForAppendedRows(allocator, root_dir, meta, appended_segment, previous_row_count, row_count, columns);
        if (!incremental_ok) try rebuildIndexes(allocator, root_dir, meta);
    } else {
        try appendRawSegmentToMeta(allocator, root_dir, table_name, meta, columns, row_count);
        const incremental_ok = try tryAppendIndexesForSegment(allocator, root_dir, meta, meta.segments.len - 1, previous_row_count, columns);
        if (!incremental_ok) try rebuildIndexes(allocator, root_dir, meta);
    }

    try writeMeta(allocator, root_dir, table_name, meta.*);
    return tableInfo(meta.*);
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
            try validateFileMetaPath(allocator, root_dir, file);
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
        const mapped = try validateIndexMetaPath(allocator, root_dir, index);
        defer if (mapped.memory.len != 0) std.posix.munmap(mapped.memory);
        const bytes = mappedRegionBytes(mapped);
        if (std.mem.eql(u8, index.kind, "u64_pair") or std.mem.eql(u8, index.kind, "u64_i64_pair")) {
            try validateU64PairIndexBytesShape(bytes, meta.row_count, index.unique);
        } else if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND)) {
            try validateIndexBytesShape(bytes, meta.row_count, false);
        } else if (std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND)) {
            try validateVariableIndexBytesShape(bytes, meta.row_count);
        } else {
            try validateIndexBytesShape(bytes, meta.row_count, index.unique);
        }
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

fn dictScanCountAndFindValueId(bytes: []const u8, value: []const u8) TableError!DictScanResult {
    if (bytes.len < 8) return TableError.VerifyFailed;
    const count = readU64LE(bytes, 0);
    var offset: usize = 8;
    var current_id: u64 = 1;
    var found_id: ?u64 = null;
    while (current_id <= count) : (current_id += 1) {
        if (offset > bytes.len or bytes.len - offset < 8) return TableError.VerifyFailed;
        const len_u64 = readU64LE(bytes, offset);
        if (len_u64 == 0 or len_u64 > DICT_MAX_VALUE_BYTES) return TableError.VerifyFailed;
        if (len_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.VerifyFailed;
        const len: usize = @intCast(len_u64);
        offset += 8;
        if (offset > bytes.len or bytes.len - offset < len) return TableError.VerifyFailed;
        const candidate = bytes[offset .. offset + len];
        if (found_id == null and std.mem.eql(u8, candidate, value)) found_id = current_id;
        offset += len;
    }
    if (offset != bytes.len) return TableError.VerifyFailed;
    return .{ .count = count, .found_id = found_id };
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
    try validateOptionalSha256(dict.sha256, bytes);
    try validateDictBlockHashes(dict, bytes);
    return bytes;
}

fn validateDictFiles(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta) TableError!void {
    for (meta.dicts, 0..) |dict, idx| {
        try validateDictName(dict.name);
        if (dict.path.len == 0 or (dict.sha256.len != 0 and dict.sha256.len != 64)) return TableError.VerifyFailed;
        for (meta.dicts[0..idx]) |previous| {
            if (std.mem.eql(u8, previous.name, dict.name)) return TableError.VerifyFailed;
        }
        try validateDictMetaPath(allocator, root_dir, dict);
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
    try validateOptionalSha256(blob.sha256, bytes);
    try validateBlobStoreBlockHashes(blob, bytes);
    return bytes;
}

fn validateBlobStoreFiles(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta) TableError!void {
    for (meta.blobs, 0..) |blob, idx| {
        try validateBlobStoreName(blob.name);
        if (blob.path.len == 0 or (blob.sha256.len != 0 and blob.sha256.len != 64)) return TableError.VerifyFailed;
        for (meta.blobs[0..idx]) |previous| {
            if (std.mem.eql(u8, previous.name, blob.name)) return TableError.VerifyFailed;
        }
        try validateBlobStoreMetaPath(allocator, root_dir, blob);
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
        dir.deleteFile(entry.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return mapFileError(err),
        };
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
    try writeFileWithParentSync(allocator, versioned_path, json, false);

    const meta_hash = try hashHexAlloc(allocator, json);
    errdefer allocator.free(meta_hash);
    return .{
        .json = json,
        .versioned_name = versioned_name,
        .meta_hash = meta_hash,
        .meta_bytes = json.len,
    };
}

fn writeCompatMeta(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta) TableError!void {
    const json = std.json.stringifyAlloc(allocator, meta, .{}) catch |err| return mapJsonError(err);
    defer allocator.free(json);

    const meta_path = try tableMetaPath(allocator, root_dir, table_name);
    defer allocator.free(meta_path);
    try writeFileWithParentSync(allocator, meta_path, json, false);
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
    try writeFileWithParentSync(allocator, manifest_path, manifest_json, false);
    syncParentDirBestEffort(manifest_path);
}

fn writeMeta(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, meta: TableMeta) TableError!void {
    if (skipDurabilitySync()) {
        try writeCompatMeta(allocator, root_dir, table_name, meta);
        unsafeInitCacheDelete(allocator, root_dir, table_name);
        return;
    }

    var written = try writeVersionedMeta(allocator, root_dir, table_name, meta);
    defer written.deinit(allocator);
    try publishWrittenMeta(allocator, root_dir, table_name, meta, written);
    unsafeInitCacheDelete(allocator, root_dir, table_name);
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
    try validateOptionalSha256(parsed.value.meta_sha256, meta_source);
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
    if (!skipDurabilitySync()) {
        try writeGeneratedIface(allocator, root_dir, schema_obj);
    }

    if (skipDurabilitySync()) {
        const schema_hash = try hashHexAlloc(allocator, schema_source);
        defer allocator.free(schema_hash);
        var meta = try buildInitialMeta(allocator, schema_obj.table_name, schema_path, schema_hash, schema_obj);
        defer meta.deinit(allocator);
        const info = tableInfo(meta);
        try unsafeInitCachePut(allocator, root_dir, schema_obj.table_name, meta);
        return info;
    }

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

    try deleteRootTableArtifacts(allocator, root_dir, table_name);

    const prefix = rootPrefix(root_dir);
    const snapshot_path = if (prefix.len == 0)
        try joinPath(allocator, &.{ ".sa", "db", "snapshots", table_name })
    else
        try joinPath(allocator, &.{ prefix, ".sa", "db", "snapshots", table_name });
    defer allocator.free(snapshot_path);
    try deleteTreeIfExists(snapshot_path);
    unsafeInitCacheDelete(allocator, root_dir, table_name);

    return .{ .row_count = 0, .segment_count = 0, .epoch = 0, .locked = false };
}

fn ingestRawColumnsUnlocked(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    row_count: u64,
    columns: []const RawColumnBytes,
) TableError!TableInfo {
    var meta = try loadWritableMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    return appendRawColumnsWithLoadedMeta(allocator, root_dir, table_name, &meta, row_count, columns);
}

pub fn ingestRawColumns(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    row_count: u64,
    columns: []const RawColumnBytes,
) TableError!TableInfo {
    const staged_files = try stageRawColumnFiles(allocator, root_dir, table_name, columns);
    defer freeStagedColumnFiles(allocator, staged_files, true);

    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadWritableMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);

    if (meta.locked) return TableError.Locked;
    if (columns.len != meta.columns.len) return TableError.InvalidFormat;
    const total_rows = std.math.add(u64, meta.row_count, row_count) catch return TableError.CursorOverflow;
    if (total_rows > meta.max_rows) return TableError.CursorOverflow;

    for (columns, 0..) |column, idx| {
        const expected_len = std.math.mul(u64, row_count, meta.columns[idx].stride) catch return TableError.CursorOverflow;
        if (column.bytes.len != expected_len) return TableError.InvalidFormat;
    }

    const previous_row_count = meta.row_count;
    try publishStagedSegmentToMeta(allocator, root_dir, table_name, &meta, staged_files, row_count);
    const incremental_ok = try tryAppendIndexesForSegment(allocator, root_dir, &meta, meta.segments.len - 1, previous_row_count, columns);
    if (!incremental_ok) try rebuildIndexes(allocator, root_dir, &meta);
    try writeMeta(allocator, root_dir, table_name, meta);
    return tableInfo(meta);
}

pub fn beginColumnIngestSession(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
) TableError!*ColumnIngestSession {
    const root_copy = try allocator.dupe(u8, root_dir);
    errdefer allocator.free(root_copy);
    const table_copy = try allocator.dupe(u8, table_name);
    errdefer allocator.free(table_copy);

    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    var write_lock_transferred = false;
    errdefer if (!write_lock_transferred) write_lock.release();

    var meta = try loadWritableMeta(allocator, root_dir, table_name);
    var meta_transferred = false;
    errdefer if (!meta_transferred) meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;

    const column_strides = try allocator.alloc(u32, meta.columns.len);
    errdefer allocator.free(column_strides);
    for (meta.columns, 0..) |column, idx| column_strides[idx] = column.stride;

    const session = try allocator.create(ColumnIngestSession);
    errdefer allocator.destroy(session);
    session.* = .{
        .root_dir = root_copy,
        .table_name = table_copy,
        .write_lock = write_lock,
        .meta = meta,
        .columns_len = meta.columns.len,
        .column_strides = column_strides,
        .batches = std.ArrayList(ColumnBatch).init(allocator),
    };
    write_lock_transferred = true;
    meta_transferred = true;
    return session;
}

pub fn destroyColumnIngestSession(allocator: std.mem.Allocator, session: *ColumnIngestSession) void {
    session.deinit(allocator);
    allocator.destroy(session);
}

pub fn columnIngestSessionAddRawColumns(
    allocator: std.mem.Allocator,
    session: *ColumnIngestSession,
    row_count: u64,
    columns: []const RawColumnBytes,
) TableError!void {
    if (columns.len != session.columns_len) return TableError.InvalidFormat;
    var total_bytes: usize = 0;
    for (columns, 0..) |column, idx| {
        const expected_len = std.math.mul(u64, row_count, session.column_strides[idx]) catch return TableError.CursorOverflow;
        if (column.bytes.len != expected_len) return TableError.InvalidFormat;
        total_bytes = std.math.add(usize, total_bytes, column.bytes.len) catch return TableError.CursorOverflow;
    }

    if (total_bytes <= COLTX_INLINE_BYTES_LIMIT) {
        const owned_columns = try duplicateRawColumnBytes(allocator, columns);
        errdefer freeOwnedRawColumnBytes(allocator, owned_columns);
        session.batches.append(.{ .row_count = row_count, .columns = owned_columns }) catch return TableError.OutOfMemory;
        return;
    }

    const files = try stageRawColumnFiles(allocator, session.root_dir, session.table_name, columns);
    errdefer freeStagedColumnFiles(allocator, files, true);
    session.batches.append(.{ .row_count = row_count, .files = files }) catch return TableError.OutOfMemory;
}

pub fn commitColumnIngestSession(
    allocator: std.mem.Allocator,
    session: *ColumnIngestSession,
) TableError!TableInfo {
    if (session.meta.locked) return TableError.Locked;

    var total_added_rows: u64 = 0;
    for (session.batches.items) |batch| {
        const next_total = std.math.add(u64, total_added_rows, batch.row_count) catch return TableError.CursorOverflow;
        total_added_rows = next_total;
    }
    const total_rows = std.math.add(u64, session.meta.row_count, total_added_rows) catch return TableError.CursorOverflow;
    if (total_rows > session.meta.max_rows) return TableError.CursorOverflow;

    var incremental_ok = true;
    for (session.batches.items) |*batch| {
        const previous_row_count = session.meta.row_count;
        var appended_columns: ?[]const RawColumnBytes = null;
        if (batch.columns) |columns| {
            if (skipDurabilitySync() and session.meta.segments.len != 0) {
                const base_segment = session.meta.segments[session.meta.segments.len - 1];
                const appended_segment = SegmentMeta{
                    .id = base_segment.id,
                    .rows = batch.row_count,
                    .files = base_segment.files,
                };
                try appendRawColumnsToLastSegmentUnsafe(allocator, session.root_dir, &session.meta, columns, batch.row_count);
                if (incremental_ok) incremental_ok = try tryAppendIndexesForAppendedRows(allocator, session.root_dir, &session.meta, appended_segment, previous_row_count, batch.row_count, columns);
            } else {
                try appendRawSegmentToMeta(allocator, session.root_dir, session.table_name, &session.meta, columns, batch.row_count);
                appended_columns = columns;
                if (incremental_ok) incremental_ok = try tryAppendIndexesForSegment(allocator, session.root_dir, &session.meta, session.meta.segments.len - 1, previous_row_count, appended_columns);
            }
        } else if (batch.files) |files| {
            try publishStagedSegmentToMeta(allocator, session.root_dir, session.table_name, &session.meta, files, batch.row_count);
            freeStagedColumnFiles(allocator, files, false);
            batch.files = null;
            if (incremental_ok) incremental_ok = try tryAppendIndexesForSegment(allocator, session.root_dir, &session.meta, session.meta.segments.len - 1, previous_row_count, appended_columns);
        } else {
            return TableError.InvalidFormat;
        }
        if (batch.columns) |columns| {
            freeOwnedRawColumnBytes(allocator, columns);
            batch.columns = null;
        }
    }
    session.batches.clearRetainingCapacity();

    if (!incremental_ok) try rebuildIndexes(allocator, session.root_dir, &session.meta);
    try writeMeta(allocator, session.root_dir, session.table_name, session.meta);
    return tableInfo(session.meta);
}

pub fn insertRawRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    row_bytes: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadWritableMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    const columns = try splitRawRowColumns(allocator, meta, row_bytes);
    defer allocator.free(columns);

    return try appendRawColumnsWithLoadedMeta(allocator, root_dir, table_name, &meta, 1, columns);
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

fn rowI64KeyValue(meta: TableMeta, column_index: usize, row_bytes: []const u8) TableError!i64 {
    try ensureI64Column(meta, column_index);
    if (row_bytes.len != try fixedRowBytes(meta)) return TableError.InvalidFormat;
    const offset = try rowColumnOffset(meta, column_index);
    return readI64LE(row_bytes, offset);
}

fn rowU32KeyValue(meta: TableMeta, column_index: usize, row_bytes: []const u8) TableError!u32 {
    try ensureU32Column(meta, column_index);
    if (row_bytes.len != try fixedRowBytes(meta)) return TableError.InvalidFormat;
    const offset = try rowColumnOffset(meta, column_index);
    return readU32LE(row_bytes, offset);
}

fn rowI32KeyValue(meta: TableMeta, column_index: usize, row_bytes: []const u8) TableError!i32 {
    try ensureI32Column(meta, column_index);
    if (row_bytes.len != try fixedRowBytes(meta)) return TableError.InvalidFormat;
    const offset = try rowColumnOffset(meta, column_index);
    return readI32LE(row_bytes, offset);
}

fn rowU8KeyValue(meta: TableMeta, column_index: usize, row_bytes: []const u8) TableError!u8 {
    try ensureU8Column(meta, column_index);
    if (row_bytes.len != try fixedRowBytes(meta)) return TableError.InvalidFormat;
    const offset = try rowColumnOffset(meta, column_index);
    return row_bytes[offset];
}

fn rowI8KeyValue(meta: TableMeta, column_index: usize, row_bytes: []const u8) TableError!i8 {
    try ensureI8Column(meta, column_index);
    if (row_bytes.len != try fixedRowBytes(meta)) return TableError.InvalidFormat;
    const offset = try rowColumnOffset(meta, column_index);
    return readI8(row_bytes, offset);
}

fn rowU16KeyValue(meta: TableMeta, column_index: usize, row_bytes: []const u8) TableError!u16 {
    try ensureU16Column(meta, column_index);
    if (row_bytes.len != try fixedRowBytes(meta)) return TableError.InvalidFormat;
    const offset = try rowColumnOffset(meta, column_index);
    return readU16LE(row_bytes, offset);
}

fn rowI16KeyValue(meta: TableMeta, column_index: usize, row_bytes: []const u8) TableError!i16 {
    try ensureI16Column(meta, column_index);
    if (row_bytes.len != try fixedRowBytes(meta)) return TableError.InvalidFormat;
    const offset = try rowColumnOffset(meta, column_index);
    return readI16LE(row_bytes, offset);
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

fn rowU64I64PairKeyValue(meta: TableMeta, column_index: usize, column_index2: usize, row_bytes: []const u8) TableError!U64I64PairKey {
    try ensureU64I64PairColumns(meta, column_index, column_index2);
    if (row_bytes.len != try fixedRowBytes(meta)) return TableError.InvalidFormat;
    const offset1 = try rowColumnOffset(meta, column_index);
    const offset2 = try rowColumnOffset(meta, column_index2);
    return .{
        .key1 = readU64LE(row_bytes, offset1),
        .key2 = readI64LE(row_bytes, offset2),
    };
}

fn rowBlobHandleKeyValue(meta: TableMeta, column_index: usize, row_bytes: []const u8) TableError!u64 {
    try ensureBlobHandleColumn(meta, column_index);
    if (row_bytes.len != try fixedRowBytes(meta)) return TableError.InvalidFormat;
    const offset = try rowColumnOffset(meta, column_index);
    return readU64LE(row_bytes, offset);
}

fn ensureRowBlobEqKeyValue(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    store_name: []const u8,
    value: []const u8,
    row_bytes: []const u8,
) TableError!void {
    try validateBlobStoreName(store_name);
    try validateBlobValue(value);
    const blob_id = try rowBlobHandleKeyValue(meta, column_index, row_bytes);
    const blob_idx = findBlobStoreMetaIndex(meta, store_name) orelse return TableError.InvalidFormat;
    const blob_bytes = try readBlobStoreBytes(allocator, root_dir, meta.blobs[blob_idx]);
    defer allocator.free(blob_bytes);
    const actual = (try blobValueSliceById(blob_bytes, blob_id)) orelse return TableError.InvalidFormat;
    if (!std.mem.eql(u8, actual, value)) return TableError.InvalidFormat;
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

fn allocateColumnBuffers(allocator: std.mem.Allocator, column_count: usize) TableError![]std.ArrayList(u8) {
    const buffers = try allocator.alloc(std.ArrayList(u8), column_count);
    errdefer allocator.free(buffers);
    for (buffers) |*buf| buf.* = std.ArrayList(u8).init(allocator);
    errdefer {
        for (buffers) |*buf| buf.deinit();
    }
    return buffers;
}

fn borrowRawColumnBytesFromBuffers(allocator: std.mem.Allocator, buffers: []std.ArrayList(u8)) TableError![]RawColumnBytes {
    const columns = try allocator.alloc(RawColumnBytes, buffers.len);
    errdefer allocator.free(columns);
    for (buffers, 0..) |buffer, idx| columns[idx] = .{ .bytes = buffer.items };
    return columns;
}

fn ensurePendingAppendBuffers(tx: *WriteTransaction) TableError!void {
    if (tx.pending_append_buffers.len != 0) return;
    tx.pending_append_buffers = try allocateColumnBuffers(tx.allocator, tx.meta.columns.len);
}

fn reservePendingAppendBuffers(tx: *WriteTransaction) TableError!void {
    try ensurePendingAppendBuffers(tx);
    if (tx.pending_append_row_count != 0) return;

    const remaining_rows = tx.meta.max_rows - tx.base_row_count;
    if (remaining_rows == 0) return;

    const reserve_rows = @min(remaining_rows, @as(u64, 4096));
    for (tx.meta.columns, 0..) |column, col_idx| {
        const reserve_bytes_u64 = std.math.mul(u64, reserve_rows, column.stride) catch return TableError.CursorOverflow;
        if (reserve_bytes_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
        try tx.pending_append_buffers[col_idx].ensureTotalCapacity(@intCast(reserve_bytes_u64));
    }
}

fn buildSingleRowColumnBuffers(allocator: std.mem.Allocator, meta: TableMeta, row_bytes: []const u8) TableError![]std.ArrayList(u8) {
    const columns = try splitRawRowColumns(allocator, meta, row_bytes);
    defer allocator.free(columns);

    const buffers = try allocateColumnBuffers(allocator, meta.columns.len);
    errdefer freeColumnBuffers(allocator, buffers);

    for (columns, 0..) |column, idx| {
        try buffers[idx].appendSlice(column.bytes);
    }
    return buffers;
}

fn freeColumnBuffers(allocator: std.mem.Allocator, buffers: []std.ArrayList(u8)) void {
    for (buffers) |*buf| buf.deinit();
    allocator.free(buffers);
}

fn duplicateRawColumnBytes(allocator: std.mem.Allocator, columns: []const RawColumnBytes) TableError![]RawColumnBytes {
    const owned = try allocator.alloc(RawColumnBytes, columns.len);
    errdefer allocator.free(owned);
    for (owned) |*column| column.* = .{ .bytes = &.{} };
    errdefer freeOwnedRawColumnBytes(allocator, owned);

    for (columns, 0..) |column, idx| {
        owned[idx] = .{ .bytes = try allocator.dupe(u8, column.bytes) };
    }
    return owned;
}

fn freeOwnedRawColumnBytes(allocator: std.mem.Allocator, columns: []RawColumnBytes) void {
    for (columns) |column| allocator.free(column.bytes);
    allocator.free(columns);
}

fn buildAllColumnBuffers(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta) TableError![]std.ArrayList(u8) {
    const buffers = try allocateColumnBuffers(allocator, meta.columns.len);
    errdefer freeColumnBuffers(allocator, buffers);

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

fn hasUniqueI64Index(meta: TableMeta, column_index: usize) bool {
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i64") and
            index.unique and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null)
        {
            return true;
        }
    }
    return false;
}

fn hasUniqueU32Index(meta: TableMeta, column_index: usize) bool {
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u32") and
            index.unique and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null)
        {
            return true;
        }
    }
    return false;
}

fn hasUniqueI32Index(meta: TableMeta, column_index: usize) bool {
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i32") and
            index.unique and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null)
        {
            return true;
        }
    }
    return false;
}

fn hasUniqueU8Index(meta: TableMeta, column_index: usize) bool {
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u8") and
            index.unique and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null)
        {
            return true;
        }
    }
    return false;
}

fn hasUniqueI8Index(meta: TableMeta, column_index: usize) bool {
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i8") and
            index.unique and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null)
        {
            return true;
        }
    }
    return false;
}

fn hasUniqueU16Index(meta: TableMeta, column_index: usize) bool {
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u16") and
            index.unique and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null)
        {
            return true;
        }
    }
    return false;
}

fn hasUniqueI16Index(meta: TableMeta, column_index: usize) bool {
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i16") and
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

fn hasUniqueU64I64PairIndex(meta: TableMeta, column_index: usize, column_index2: usize) bool {
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64_i64_pair") and
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

fn hasUniqueBlobEqIndex(meta: TableMeta, column_index: usize, store_name: []const u8) bool {
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND) and
            index.unique and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null and
            index.store_name != null and
            std.mem.eql(u8, index.store_name.?, store_name))
        {
            return true;
        }
    }
    return false;
}

fn validateTransactionBuffers(tx: *const WriteTransaction) TableError!void {
    if (tx.buffers.len == 0) {
        if (tx.pending_append_buffers.len == 0) {
            if (tx.pending_append_row_count != 0) return TableError.InvalidFormat;
            return;
        }
        if (tx.pending_append_buffers.len != tx.meta.columns.len) return TableError.InvalidFormat;
        for (tx.meta.columns, 0..) |column, col_idx| {
            const expected_len = try expectedColumnBytes(tx.pending_append_row_count, column.stride);
            if (tx.pending_append_buffers[col_idx].items.len != expected_len) return TableError.VerifyFailed;
        }
        return;
    }
    if (tx.buffers.len != tx.meta.columns.len) return TableError.InvalidFormat;
    for (tx.meta.columns, 0..) |column, col_idx| {
        const expected_len = try expectedColumnBytes(tx.meta.row_count, column.stride);
        if (tx.buffers[col_idx].items.len != expected_len) return TableError.VerifyFailed;
    }
}

fn materializeTransactionBuffers(tx: *WriteTransaction) TableError!void {
    if (tx.buffers.len != 0) return;
    var base_meta = tx.meta;
    base_meta.row_count = tx.base_row_count;
    tx.buffers = try buildAllColumnBuffers(tx.allocator, tx.root_dir, base_meta);
    errdefer {
        freeColumnBuffers(tx.allocator, tx.buffers);
        tx.buffers = &.{};
    }
    if (tx.pending_append_row_count == 0) return;
    if (tx.pending_append_buffers.len != tx.meta.columns.len) return TableError.InvalidFormat;
    for (tx.meta.columns, 0..) |_, col_idx| {
        try tx.buffers[col_idx].appendSlice(tx.pending_append_buffers[col_idx].items);
    }
    freeColumnBuffers(tx.allocator, tx.pending_append_buffers);
    tx.pending_append_buffers = &.{};
}

fn txFindU64KeyRow(tx: *const WriteTransaction, column_index: usize, expected: u64) TableError!U64FindResult {
    try materializeTransactionBuffers(@constCast(tx));
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

fn txFindI64KeyRow(tx: *const WriteTransaction, column_index: usize, expected: i64) TableError!U64FindResult {
    try materializeTransactionBuffers(@constCast(tx));
    try ensureI64Column(tx.meta, column_index);
    if (!hasUniqueI64Index(tx.meta, column_index)) return TableError.InvalidFormat;
    try validateTransactionBuffers(tx);

    const bytes = tx.buffers[column_index].items;
    var row: u64 = 0;
    while (row < tx.meta.row_count) : (row += 1) {
        const offset_u64 = std.math.mul(u64, row, 8) catch return TableError.CursorOverflow;
        const offset: usize = @intCast(offset_u64);
        if (readI64LE(bytes, offset) == expected) return .{ .found = true, .row_index = row };
    }
    return .{ .found = false, .row_index = 0 };
}

fn txFindU32KeyRow(tx: *const WriteTransaction, column_index: usize, expected: u32) TableError!U64FindResult {
    try materializeTransactionBuffers(@constCast(tx));
    try ensureU32Column(tx.meta, column_index);
    if (!hasUniqueU32Index(tx.meta, column_index)) return TableError.InvalidFormat;
    try validateTransactionBuffers(tx);

    const bytes = tx.buffers[column_index].items;
    var row: u64 = 0;
    while (row < tx.meta.row_count) : (row += 1) {
        const offset_u64 = std.math.mul(u64, row, 4) catch return TableError.CursorOverflow;
        const offset: usize = @intCast(offset_u64);
        if (readU32LE(bytes, offset) == expected) return .{ .found = true, .row_index = row };
    }
    return .{ .found = false, .row_index = 0 };
}

fn txFindI32KeyRow(tx: *const WriteTransaction, column_index: usize, expected: i32) TableError!U64FindResult {
    try materializeTransactionBuffers(@constCast(tx));
    try ensureI32Column(tx.meta, column_index);
    if (!hasUniqueI32Index(tx.meta, column_index)) return TableError.InvalidFormat;
    try validateTransactionBuffers(tx);

    const bytes = tx.buffers[column_index].items;
    var row: u64 = 0;
    while (row < tx.meta.row_count) : (row += 1) {
        const offset_u64 = std.math.mul(u64, row, 4) catch return TableError.CursorOverflow;
        const offset: usize = @intCast(offset_u64);
        if (readI32LE(bytes, offset) == expected) return .{ .found = true, .row_index = row };
    }
    return .{ .found = false, .row_index = 0 };
}

fn txFindU8KeyRow(tx: *const WriteTransaction, column_index: usize, expected: u8) TableError!U64FindResult {
    try materializeTransactionBuffers(@constCast(tx));
    try ensureU8Column(tx.meta, column_index);
    if (!hasUniqueU8Index(tx.meta, column_index)) return TableError.InvalidFormat;
    try validateTransactionBuffers(tx);

    const bytes = tx.buffers[column_index].items;
    var row: u64 = 0;
    while (row < tx.meta.row_count) : (row += 1) {
        const offset: usize = @intCast(row);
        if (bytes[offset] == expected) return .{ .found = true, .row_index = row };
    }
    return .{ .found = false, .row_index = 0 };
}

fn txFindI8KeyRow(tx: *const WriteTransaction, column_index: usize, expected: i8) TableError!U64FindResult {
    try materializeTransactionBuffers(@constCast(tx));
    try ensureI8Column(tx.meta, column_index);
    if (!hasUniqueI8Index(tx.meta, column_index)) return TableError.InvalidFormat;
    try validateTransactionBuffers(tx);

    const bytes = tx.buffers[column_index].items;
    var row: u64 = 0;
    while (row < tx.meta.row_count) : (row += 1) {
        const offset: usize = @intCast(row);
        if (readI8(bytes, offset) == expected) return .{ .found = true, .row_index = row };
    }
    return .{ .found = false, .row_index = 0 };
}

fn txFindU16KeyRow(tx: *const WriteTransaction, column_index: usize, expected: u16) TableError!U64FindResult {
    try materializeTransactionBuffers(@constCast(tx));
    try ensureU16Column(tx.meta, column_index);
    if (!hasUniqueU16Index(tx.meta, column_index)) return TableError.InvalidFormat;
    try validateTransactionBuffers(tx);

    const bytes = tx.buffers[column_index].items;
    var row: u64 = 0;
    while (row < tx.meta.row_count) : (row += 1) {
        const offset_u64 = std.math.mul(u64, row, 2) catch return TableError.CursorOverflow;
        const offset: usize = @intCast(offset_u64);
        if (readU16LE(bytes, offset) == expected) return .{ .found = true, .row_index = row };
    }
    return .{ .found = false, .row_index = 0 };
}

fn txFindI16KeyRow(tx: *const WriteTransaction, column_index: usize, expected: i16) TableError!U64FindResult {
    try materializeTransactionBuffers(@constCast(tx));
    try ensureI16Column(tx.meta, column_index);
    if (!hasUniqueI16Index(tx.meta, column_index)) return TableError.InvalidFormat;
    try validateTransactionBuffers(tx);

    const bytes = tx.buffers[column_index].items;
    var row: u64 = 0;
    while (row < tx.meta.row_count) : (row += 1) {
        const offset_u64 = std.math.mul(u64, row, 2) catch return TableError.CursorOverflow;
        const offset: usize = @intCast(offset_u64);
        if (readI16LE(bytes, offset) == expected) return .{ .found = true, .row_index = row };
    }
    return .{ .found = false, .row_index = 0 };
}

fn txFindU64PairKeyRow(tx: *const WriteTransaction, column_index: usize, column_index2: usize, key1: u64, key2: u64) TableError!U64FindResult {
    try materializeTransactionBuffers(@constCast(tx));
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

fn txFindU64I64PairKeyRow(tx: *const WriteTransaction, column_index: usize, column_index2: usize, key1: u64, key2: i64) TableError!U64FindResult {
    try materializeTransactionBuffers(@constCast(tx));
    try ensureU64I64PairColumns(tx.meta, column_index, column_index2);
    if (!hasUniqueU64I64PairIndex(tx.meta, column_index, column_index2)) return TableError.InvalidFormat;
    try validateTransactionBuffers(tx);

    const bytes1 = tx.buffers[column_index].items;
    const bytes2 = tx.buffers[column_index2].items;
    var row: u64 = 0;
    while (row < tx.meta.row_count) : (row += 1) {
        const offset_u64 = std.math.mul(u64, row, 8) catch return TableError.CursorOverflow;
        const offset: usize = @intCast(offset_u64);
        if (readU64LE(bytes1, offset) == key1 and readI64LE(bytes2, offset) == key2) return .{ .found = true, .row_index = row };
    }
    return .{ .found = false, .row_index = 0 };
}

fn txFindBlobEqKeyRow(allocator: std.mem.Allocator, tx: *const WriteTransaction, column_index: usize, store_name: []const u8, value: []const u8) TableError!U64FindResult {
    try materializeTransactionBuffers(@constCast(tx));
    try ensureBlobHandleColumn(tx.meta, column_index);
    try validateBlobStoreName(store_name);
    try validateBlobValue(value);
    if (!hasUniqueBlobEqIndex(tx.meta, column_index, store_name)) return TableError.InvalidFormat;
    try validateTransactionBuffers(tx);

    const blob_idx = findBlobStoreMetaIndex(tx.meta, store_name) orelse return .{ .found = false, .row_index = 0 };
    const blob_bytes = try readBlobStoreBytes(allocator, tx.root_dir, tx.meta.blobs[blob_idx]);
    defer allocator.free(blob_bytes);
    const refs = try buildBlobValueRefs(allocator, blob_bytes);
    defer allocator.free(refs);

    const bytes = tx.buffers[column_index].items;
    var row: u64 = 0;
    while (row < tx.meta.row_count) : (row += 1) {
        const offset_u64 = std.math.mul(u64, row, 8) catch return TableError.CursorOverflow;
        const offset: usize = @intCast(offset_u64);
        const blob_id = readU64LE(bytes, offset);
        const value_ref = blobRefForId(refs, blob_id) orelse continue;
        if (std.mem.eql(u8, value_ref.value, value)) return .{ .found = true, .row_index = row };
    }
    return .{ .found = false, .row_index = 0 };
}

fn txAppendRawRow(tx: *WriteTransaction, row_bytes: []const u8) TableError!void {
    if (row_bytes.len != try fixedRowBytes(tx.meta)) return TableError.InvalidFormat;
    const next_row_count = std.math.add(u64, tx.meta.row_count, 1) catch return TableError.CursorOverflow;
    if (next_row_count > tx.meta.max_rows) return TableError.CursorOverflow;

    if (tx.buffers.len == 0) {
        try reservePendingAppendBuffers(tx);
        var offset_append: usize = 0;
        for (tx.meta.columns, 0..) |column, col_idx| {
            const stride_append: usize = @intCast(column.stride);
            const next_offset_append = std.math.add(usize, offset_append, stride_append) catch return TableError.CursorOverflow;
            if (next_offset_append > row_bytes.len) return TableError.InvalidFormat;
            try tx.pending_append_buffers[col_idx].appendSlice(row_bytes[offset_append..next_offset_append]);
            offset_append = next_offset_append;
        }
        if (offset_append != row_bytes.len) return TableError.InvalidFormat;
        tx.meta.row_count = next_row_count;
        tx.pending_append_row_count = std.math.add(u64, tx.pending_append_row_count, 1) catch return TableError.CursorOverflow;
        tx.dirty = true;
        tx.rows_dirty = true;
        return;
    }

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
    try materializeTransactionBuffers(tx);
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
    try materializeTransactionBuffers(tx);
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
    try materializeTransactionBuffers(tx);
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

fn appendPendingSegmentsFromTransaction(allocator: std.mem.Allocator, tx: *WriteTransaction) TableError!bool {
    if (tx.pending_append_row_count == 0) return true;
    try validateTransactionBuffers(tx);
    const appended_columns = try borrowRawColumnBytesFromBuffers(allocator, tx.pending_append_buffers);
    defer allocator.free(appended_columns);
    const previous_row_count = tx.base_row_count;
    if (skipDurabilitySync() and tx.meta.segments.len != 0) {
        const base_segment = tx.meta.segments[tx.meta.segments.len - 1];
        const appended_segment = SegmentMeta{
            .id = base_segment.id,
            .rows = tx.pending_append_row_count,
            .files = base_segment.files,
        };
        tx.meta.row_count = tx.base_row_count;
        try appendRawColumnsToLastSegmentUnsafe(allocator, tx.root_dir, &tx.meta, appended_columns, tx.pending_append_row_count);
        const incremental_ok_unsafe = try tryAppendIndexesForAppendedRows(allocator, tx.root_dir, &tx.meta, appended_segment, previous_row_count, tx.pending_append_row_count, appended_columns);
        freeColumnBuffers(allocator, tx.pending_append_buffers);
        tx.pending_append_buffers = &.{};
        tx.base_row_count = tx.meta.row_count;
        tx.pending_append_row_count = 0;
        return incremental_ok_unsafe;
    }

    tx.meta.row_count = tx.base_row_count;
    try appendSegmentToMeta(allocator, tx.root_dir, tx.table_name, &tx.meta, tx.pending_append_buffers, tx.pending_append_row_count);
    const incremental_ok = try tryAppendIndexesForSegment(allocator, tx.root_dir, &tx.meta, tx.meta.segments.len - 1, previous_row_count, appended_columns);
    freeColumnBuffers(allocator, tx.pending_append_buffers);
    tx.pending_append_buffers = &.{};
    tx.base_row_count = tx.meta.row_count;
    tx.pending_append_row_count = 0;
    return incremental_ok;
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

    var meta = try loadWritableMeta(allocator, root_dir, table_name);
    var meta_transferred = false;
    errdefer if (!meta_transferred) meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;

    const tx = try allocator.create(WriteTransaction);
    errdefer allocator.destroy(tx);
    tx.* = .{
        .allocator = allocator,
        .root_dir = root_copy,
        .table_name = table_copy,
        .write_lock = write_lock,
        .meta = meta,
        .buffers = &.{},
        .pending_append_buffers = &.{},
        .base_row_count = meta.row_count,
        .dirty = false,
    };
    write_lock_transferred = true;
    meta_transferred = true;
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

pub fn writeTransactionInsertRawRows(tx: *WriteTransaction, rows_bytes: []const u8, row_count: u64) TableError!TableInfo {
    if (row_count == 0) return tableInfo(tx.meta);

    const row_bytes = try fixedRowBytes(tx.meta);
    const row_count_usize: usize = @intCast(row_count);
    const expected_bytes = std.math.mul(usize, row_bytes, row_count_usize) catch return TableError.CursorOverflow;
    if (rows_bytes.len != expected_bytes) return TableError.InvalidFormat;

    const next_row_count = std.math.add(u64, tx.meta.row_count, row_count) catch return TableError.CursorOverflow;
    if (next_row_count > tx.meta.max_rows) return TableError.CursorOverflow;

    if (tx.buffers.len == 0) {
        try reservePendingAppendBuffers(tx);
        for (tx.meta.columns, 0..) |column, col_idx| {
            const stride: usize = @intCast(column.stride);
            const additional_bytes = std.math.mul(usize, stride, row_count_usize) catch return TableError.CursorOverflow;
            const next_capacity = std.math.add(usize, tx.pending_append_buffers[col_idx].items.len, additional_bytes) catch return TableError.CursorOverflow;
            try tx.pending_append_buffers[col_idx].ensureTotalCapacityPrecise(next_capacity);
        }

        var row_offset: usize = 0;
        var row_idx: usize = 0;
        while (row_idx < row_count_usize) : (row_idx += 1) {
            var offset_append: usize = 0;
            for (tx.meta.columns, 0..) |column, col_idx| {
                const stride_append: usize = @intCast(column.stride);
                const next_offset_append = std.math.add(usize, offset_append, stride_append) catch return TableError.CursorOverflow;
                tx.pending_append_buffers[col_idx].appendSliceAssumeCapacity(rows_bytes[row_offset + offset_append .. row_offset + next_offset_append]);
                offset_append = next_offset_append;
            }
            row_offset = std.math.add(usize, row_offset, row_bytes) catch return TableError.CursorOverflow;
        }

        tx.meta.row_count = next_row_count;
        tx.pending_append_row_count = std.math.add(u64, tx.pending_append_row_count, row_count) catch return TableError.CursorOverflow;
        tx.dirty = true;
        tx.rows_dirty = true;
        return tableInfo(tx.meta);
    }

    for (tx.meta.columns, 0..) |column, col_idx| {
        const stride: usize = @intCast(column.stride);
        const additional_bytes = std.math.mul(usize, stride, row_count_usize) catch return TableError.CursorOverflow;
        const next_capacity = std.math.add(usize, tx.buffers[col_idx].items.len, additional_bytes) catch return TableError.CursorOverflow;
        try tx.buffers[col_idx].ensureTotalCapacityPrecise(next_capacity);
    }

    var row_offset: usize = 0;
    var row_idx: usize = 0;
    while (row_idx < row_count_usize) : (row_idx += 1) {
        var offset: usize = 0;
        for (tx.meta.columns, 0..) |column, col_idx| {
            const stride: usize = @intCast(column.stride);
            const next_offset = std.math.add(usize, offset, stride) catch return TableError.CursorOverflow;
            tx.buffers[col_idx].appendSliceAssumeCapacity(rows_bytes[row_offset + offset .. row_offset + next_offset]);
            offset = next_offset;
        }
        row_offset = std.math.add(usize, row_offset, row_bytes) catch return TableError.CursorOverflow;
    }

    tx.meta.row_count = next_row_count;
    tx.dirty = true;
    tx.rows_dirty = true;
    return tableInfo(tx.meta);
}

pub fn writeTransactionInsertRawColumns(tx: *WriteTransaction, row_count: u64, columns: []const RawColumnBytes) TableError!TableInfo {
    if (row_count == 0) return tableInfo(tx.meta);
    if (columns.len != tx.meta.columns.len) return TableError.InvalidFormat;

    const next_row_count = std.math.add(u64, tx.meta.row_count, row_count) catch return TableError.CursorOverflow;
    if (next_row_count > tx.meta.max_rows) return TableError.CursorOverflow;

    for (columns, 0..) |column, idx| {
        const expected_len = std.math.mul(u64, row_count, tx.meta.columns[idx].stride) catch return TableError.CursorOverflow;
        if (column.bytes.len != expected_len) return TableError.InvalidFormat;
    }

    if (tx.buffers.len == 0) {
        try reservePendingAppendBuffers(tx);
        for (columns, 0..) |column, col_idx| {
            const next_capacity = std.math.add(usize, tx.pending_append_buffers[col_idx].items.len, column.bytes.len) catch return TableError.CursorOverflow;
            try tx.pending_append_buffers[col_idx].ensureTotalCapacityPrecise(next_capacity);
        }
        for (columns, 0..) |column, col_idx| {
            tx.pending_append_buffers[col_idx].appendSliceAssumeCapacity(column.bytes);
        }
        tx.meta.row_count = next_row_count;
        tx.pending_append_row_count = std.math.add(u64, tx.pending_append_row_count, row_count) catch return TableError.CursorOverflow;
        tx.dirty = true;
        tx.rows_dirty = true;
        return tableInfo(tx.meta);
    }

    for (columns, 0..) |column, col_idx| {
        const next_capacity = std.math.add(usize, tx.buffers[col_idx].items.len, column.bytes.len) catch return TableError.CursorOverflow;
        try tx.buffers[col_idx].ensureTotalCapacityPrecise(next_capacity);
    }
    for (columns, 0..) |column, col_idx| {
        tx.buffers[col_idx].appendSliceAssumeCapacity(column.bytes);
    }

    tx.meta.row_count = next_row_count;
    tx.dirty = true;
    tx.rows_dirty = true;
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

pub fn writeTransactionUpsertRawRowI64Key(tx: *WriteTransaction, column_index: usize, expected: i64, row_bytes: []const u8) TableError!UpsertResult {
    const key_value = try rowI64KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindI64KeyRow(tx, column_index, expected);
    if (found.found) {
        try txReplaceRawRow(tx, found.row_index, row_bytes);
        return .{ .info = tableInfo(tx.meta), .inserted = false };
    }
    try txAppendRawRow(tx, row_bytes);
    return .{ .info = tableInfo(tx.meta), .inserted = true };
}

pub fn writeTransactionUpsertRawRowU32Key(tx: *WriteTransaction, column_index: usize, expected: u32, row_bytes: []const u8) TableError!UpsertResult {
    const key_value = try rowU32KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindU32KeyRow(tx, column_index, expected);
    if (found.found) {
        try txReplaceRawRow(tx, found.row_index, row_bytes);
        return .{ .info = tableInfo(tx.meta), .inserted = false };
    }
    try txAppendRawRow(tx, row_bytes);
    return .{ .info = tableInfo(tx.meta), .inserted = true };
}

pub fn writeTransactionUpsertRawRowI32Key(tx: *WriteTransaction, column_index: usize, expected: i32, row_bytes: []const u8) TableError!UpsertResult {
    const key_value = try rowI32KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindI32KeyRow(tx, column_index, expected);
    if (found.found) {
        try txReplaceRawRow(tx, found.row_index, row_bytes);
        return .{ .info = tableInfo(tx.meta), .inserted = false };
    }
    try txAppendRawRow(tx, row_bytes);
    return .{ .info = tableInfo(tx.meta), .inserted = true };
}

pub fn writeTransactionUpsertRawRowU8Key(tx: *WriteTransaction, column_index: usize, expected: u8, row_bytes: []const u8) TableError!UpsertResult {
    const key_value = try rowU8KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindU8KeyRow(tx, column_index, expected);
    if (found.found) {
        try txReplaceRawRow(tx, found.row_index, row_bytes);
        return .{ .info = tableInfo(tx.meta), .inserted = false };
    }
    try txAppendRawRow(tx, row_bytes);
    return .{ .info = tableInfo(tx.meta), .inserted = true };
}

pub fn writeTransactionUpsertRawRowI8Key(tx: *WriteTransaction, column_index: usize, expected: i8, row_bytes: []const u8) TableError!UpsertResult {
    const key_value = try rowI8KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindI8KeyRow(tx, column_index, expected);
    if (found.found) {
        try txReplaceRawRow(tx, found.row_index, row_bytes);
        return .{ .info = tableInfo(tx.meta), .inserted = false };
    }
    try txAppendRawRow(tx, row_bytes);
    return .{ .info = tableInfo(tx.meta), .inserted = true };
}

pub fn writeTransactionUpsertRawRowU16Key(tx: *WriteTransaction, column_index: usize, expected: u16, row_bytes: []const u8) TableError!UpsertResult {
    const key_value = try rowU16KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindU16KeyRow(tx, column_index, expected);
    if (found.found) {
        try txReplaceRawRow(tx, found.row_index, row_bytes);
        return .{ .info = tableInfo(tx.meta), .inserted = false };
    }
    try txAppendRawRow(tx, row_bytes);
    return .{ .info = tableInfo(tx.meta), .inserted = true };
}

pub fn writeTransactionUpsertRawRowI16Key(tx: *WriteTransaction, column_index: usize, expected: i16, row_bytes: []const u8) TableError!UpsertResult {
    const key_value = try rowI16KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindI16KeyRow(tx, column_index, expected);
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

pub fn writeTransactionUpsertRawRowU64I64PairKey(tx: *WriteTransaction, column_index: usize, column_index2: usize, key1: u64, key2: i64, row_bytes: []const u8) TableError!UpsertResult {
    const key_value = try rowU64I64PairKeyValue(tx.meta, column_index, column_index2, row_bytes);
    if (key_value.key1 != key1 or key_value.key2 != key2) return TableError.InvalidFormat;
    const found = try txFindU64I64PairKeyRow(tx, column_index, column_index2, key1, key2);
    if (found.found) {
        try txReplaceRawRow(tx, found.row_index, row_bytes);
        return .{ .info = tableInfo(tx.meta), .inserted = false };
    }
    try txAppendRawRow(tx, row_bytes);
    return .{ .info = tableInfo(tx.meta), .inserted = true };
}

pub fn writeTransactionUpsertRawRowBlobEqKey(allocator: std.mem.Allocator, tx: *WriteTransaction, column_index: usize, store_name: []const u8, value: []const u8, row_bytes: []const u8) TableError!UpsertResult {
    try ensureRowBlobEqKeyValue(allocator, tx.root_dir, tx.meta, column_index, store_name, value, row_bytes);
    const found = try txFindBlobEqKeyRow(allocator, tx, column_index, store_name, value);
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

pub fn writeTransactionUpdateRawRowI64Key(tx: *WriteTransaction, column_index: usize, expected: i64, row_bytes: []const u8) TableError!TableInfo {
    const key_value = try rowI64KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindI64KeyRow(tx, column_index, expected);
    if (!found.found) return TableError.NotFound;
    try txReplaceRawRow(tx, found.row_index, row_bytes);
    return tableInfo(tx.meta);
}

pub fn writeTransactionUpdateRawRowU32Key(tx: *WriteTransaction, column_index: usize, expected: u32, row_bytes: []const u8) TableError!TableInfo {
    const key_value = try rowU32KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindU32KeyRow(tx, column_index, expected);
    if (!found.found) return TableError.NotFound;
    try txReplaceRawRow(tx, found.row_index, row_bytes);
    return tableInfo(tx.meta);
}

pub fn writeTransactionUpdateRawRowI32Key(tx: *WriteTransaction, column_index: usize, expected: i32, row_bytes: []const u8) TableError!TableInfo {
    const key_value = try rowI32KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindI32KeyRow(tx, column_index, expected);
    if (!found.found) return TableError.NotFound;
    try txReplaceRawRow(tx, found.row_index, row_bytes);
    return tableInfo(tx.meta);
}

pub fn writeTransactionUpdateRawRowU8Key(tx: *WriteTransaction, column_index: usize, expected: u8, row_bytes: []const u8) TableError!TableInfo {
    const key_value = try rowU8KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindU8KeyRow(tx, column_index, expected);
    if (!found.found) return TableError.NotFound;
    try txReplaceRawRow(tx, found.row_index, row_bytes);
    return tableInfo(tx.meta);
}

pub fn writeTransactionUpdateRawRowI8Key(tx: *WriteTransaction, column_index: usize, expected: i8, row_bytes: []const u8) TableError!TableInfo {
    const key_value = try rowI8KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindI8KeyRow(tx, column_index, expected);
    if (!found.found) return TableError.NotFound;
    try txReplaceRawRow(tx, found.row_index, row_bytes);
    return tableInfo(tx.meta);
}

pub fn writeTransactionUpdateRawRowU16Key(tx: *WriteTransaction, column_index: usize, expected: u16, row_bytes: []const u8) TableError!TableInfo {
    const key_value = try rowU16KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindU16KeyRow(tx, column_index, expected);
    if (!found.found) return TableError.NotFound;
    try txReplaceRawRow(tx, found.row_index, row_bytes);
    return tableInfo(tx.meta);
}

pub fn writeTransactionUpdateRawRowI16Key(tx: *WriteTransaction, column_index: usize, expected: i16, row_bytes: []const u8) TableError!TableInfo {
    const key_value = try rowI16KeyValue(tx.meta, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;
    const found = try txFindI16KeyRow(tx, column_index, expected);
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

pub fn writeTransactionUpdateRawRowU64I64PairKey(tx: *WriteTransaction, column_index: usize, column_index2: usize, key1: u64, key2: i64, row_bytes: []const u8) TableError!TableInfo {
    const key_value = try rowU64I64PairKeyValue(tx.meta, column_index, column_index2, row_bytes);
    if (key_value.key1 != key1 or key_value.key2 != key2) return TableError.InvalidFormat;
    const found = try txFindU64I64PairKeyRow(tx, column_index, column_index2, key1, key2);
    if (!found.found) return TableError.NotFound;
    try txReplaceRawRow(tx, found.row_index, row_bytes);
    return tableInfo(tx.meta);
}

pub fn writeTransactionUpdateRawRowBlobEqKey(allocator: std.mem.Allocator, tx: *WriteTransaction, column_index: usize, store_name: []const u8, value: []const u8, row_bytes: []const u8) TableError!TableInfo {
    try ensureRowBlobEqKeyValue(allocator, tx.root_dir, tx.meta, column_index, store_name, value, row_bytes);
    const found = try txFindBlobEqKeyRow(allocator, tx, column_index, store_name, value);
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

pub fn writeTransactionDeleteI64Key(tx: *WriteTransaction, column_index: usize, expected: i64) TableError!TableInfo {
    const found = try txFindI64KeyRow(tx, column_index, expected);
    if (!found.found) return TableError.NotFound;
    try txDeleteRow(tx, found.row_index);
    return tableInfo(tx.meta);
}

pub fn writeTransactionDeleteU32Key(tx: *WriteTransaction, column_index: usize, expected: u32) TableError!TableInfo {
    const found = try txFindU32KeyRow(tx, column_index, expected);
    if (!found.found) return TableError.NotFound;
    try txDeleteRow(tx, found.row_index);
    return tableInfo(tx.meta);
}

pub fn writeTransactionDeleteI32Key(tx: *WriteTransaction, column_index: usize, expected: i32) TableError!TableInfo {
    const found = try txFindI32KeyRow(tx, column_index, expected);
    if (!found.found) return TableError.NotFound;
    try txDeleteRow(tx, found.row_index);
    return tableInfo(tx.meta);
}

pub fn writeTransactionDeleteU8Key(tx: *WriteTransaction, column_index: usize, expected: u8) TableError!TableInfo {
    const found = try txFindU8KeyRow(tx, column_index, expected);
    if (!found.found) return TableError.NotFound;
    try txDeleteRow(tx, found.row_index);
    return tableInfo(tx.meta);
}

pub fn writeTransactionDeleteI8Key(tx: *WriteTransaction, column_index: usize, expected: i8) TableError!TableInfo {
    const found = try txFindI8KeyRow(tx, column_index, expected);
    if (!found.found) return TableError.NotFound;
    try txDeleteRow(tx, found.row_index);
    return tableInfo(tx.meta);
}

pub fn writeTransactionDeleteU16Key(tx: *WriteTransaction, column_index: usize, expected: u16) TableError!TableInfo {
    const found = try txFindU16KeyRow(tx, column_index, expected);
    if (!found.found) return TableError.NotFound;
    try txDeleteRow(tx, found.row_index);
    return tableInfo(tx.meta);
}

pub fn writeTransactionDeleteI16Key(tx: *WriteTransaction, column_index: usize, expected: i16) TableError!TableInfo {
    const found = try txFindI16KeyRow(tx, column_index, expected);
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

pub fn writeTransactionDeleteU64I64PairKey(tx: *WriteTransaction, column_index: usize, column_index2: usize, key1: u64, key2: i64) TableError!TableInfo {
    const found = try txFindU64I64PairKeyRow(tx, column_index, column_index2, key1, key2);
    if (!found.found) return TableError.NotFound;
    try txDeleteRow(tx, found.row_index);
    return tableInfo(tx.meta);
}

pub fn writeTransactionDeleteBlobEqKey(allocator: std.mem.Allocator, tx: *WriteTransaction, column_index: usize, store_name: []const u8, value: []const u8) TableError!TableInfo {
    const found = try txFindBlobEqKeyRow(allocator, tx, column_index, store_name, value);
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

    var old_bytes: []const u8 = &.{};
    var old_count: u64 = 0;
    var owned_old_bytes: ?[]u8 = null;
    defer if (owned_old_bytes) |bytes| allocator.free(bytes);

    if (findPendingDictWriteIndex(tx, dict_name)) |pending_idx| {
        old_bytes = tx.pending_dict_writes[pending_idx].bytes;
        const scan = try dictScanCountAndFindValueId(old_bytes, value);
        old_count = scan.count;
        if (scan.found_id) |id| {
            return .{ .info = tableInfo(tx.meta), .id = id, .inserted = false };
        }
    } else if (findDictMetaIndex(tx.meta, dict_name)) |idx| {
        const bytes = try readDictBytes(allocator, tx.root_dir, tx.meta.dicts[idx]);
        owned_old_bytes = bytes;
        old_bytes = bytes;
        const scan = try dictScanCountAndFindValueId(old_bytes, value);
        old_count = scan.count;
        if (scan.found_id) |id| {
            return .{ .info = tableInfo(tx.meta), .id = id, .inserted = false };
        }
    }

    const new_count = std.math.add(u64, old_count, 1) catch return TableError.CursorOverflow;
    const new_bytes = try buildDictBytesWithValue(allocator, old_bytes, old_count, value);

    const target_epoch = std.math.add(u64, tx.meta.epoch, 1) catch return TableError.CursorOverflow;
    const basename = try dictFileName(allocator, tx.table_name, dict_name, target_epoch);
    defer allocator.free(basename);

    const new_meta = try makeDictMeta(allocator, dict_name, basename, new_bytes, new_count);
    var consumed = false;
    errdefer {
        if (!consumed) {
            freeDictMeta(allocator, new_meta);
            allocator.free(new_bytes);
        }
    }
    try putDictMeta(allocator, &tx.meta, new_meta);
    try putPendingDictWrite(allocator, tx, dict_name, basename, new_bytes);
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
    const unsafe_no_sync = skipDurabilitySync();
    if (!unsafe_no_sync) {
        try writeTxPendingMarker(allocator, tx.root_dir, tx.table_name, previous_epoch, target_epoch);
    }
    var pending_marker_live = !unsafe_no_sync;
    errdefer if (pending_marker_live) deleteTxPendingMarkerIfExists(allocator, tx.root_dir, tx.table_name, target_epoch) catch {};

    var rebuilt_indexes = false;
    if (tx.rows_dirty) {
        if (tx.buffers.len == 0) {
            const incremental_ok = try appendPendingSegmentsFromTransaction(allocator, tx);
            if (!incremental_ok) {
                try rebuildIndexes(allocator, tx.root_dir, &tx.meta);
                rebuilt_indexes = true;
            }
        } else {
            try rewriteSegmentsFromTransaction(allocator, tx);
            try rebuildIndexes(allocator, tx.root_dir, &tx.meta);
            rebuilt_indexes = true;
        }
    } else {
        tx.meta.epoch = target_epoch;
    }
    if (!rebuilt_indexes) {
        // append-only incremental path already refreshed index artifacts for the new epoch
    }
    try flushPendingDictWrites(allocator, tx);
    if (unsafe_no_sync) {
        try writeCompatMeta(allocator, tx.root_dir, tx.table_name, tx.meta);
        unsafeInitCacheDelete(allocator, tx.root_dir, tx.table_name);
    } else {
        var written = try writeVersionedMeta(allocator, tx.root_dir, tx.table_name, tx.meta);
        defer written.deinit(allocator);
        try writeTxCommitMarker(allocator, tx.root_dir, tx.table_name, tx.meta, written);
        try publishWrittenMeta(allocator, tx.root_dir, tx.table_name, tx.meta, written);
        deleteTxPendingMarkerIfExists(allocator, tx.root_dir, tx.table_name, tx.meta.epoch) catch {};
        pending_marker_live = false;
    }
    if (tx.pending_dict_writes.len != 0) {
        freePendingDictWrites(allocator, tx.pending_dict_writes);
        tx.pending_dict_writes = &.{};
    }
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

fn buildDictBytesWithValues(allocator: std.mem.Allocator, old_bytes: []const u8, old_count: u64, values: []const []const u8) TableError![]u8 {
    var total = old_bytes.len;
    if (old_bytes.len == 0) {
        total = std.math.add(usize, total, 8) catch return TableError.CursorOverflow;
    }
    for (values) |value| {
        const extra = std.math.add(usize, 8, value.len) catch return TableError.CursorOverflow;
        total = std.math.add(usize, total, extra) catch return TableError.CursorOverflow;
    }

    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    const new_count = std.math.add(u64, old_count, values.len) catch return TableError.CursorOverflow;
    var offset: usize = 0;
    writeU64LE(out, offset, new_count);
    offset += 8;
    if (old_bytes.len != 0) {
        @memcpy(out[offset..][0 .. old_bytes.len - 8], old_bytes[8..]);
        offset += old_bytes.len - 8;
    }
    for (values) |value| {
        writeU64LE(out, offset, @intCast(value.len));
        offset += 8;
        @memcpy(out[offset..][0..value.len], value);
        offset += value.len;
    }
    return out;
}

fn makeDictMeta(allocator: std.mem.Allocator, dict_name: []const u8, path: []const u8, bytes: []const u8, entries: u64) TableError!DictMeta {
    const name = try allocator.dupe(u8, dict_name);
    errdefer allocator.free(name);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const sha256 = try optionalHashHexAlloc(allocator, bytes);
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
    const sha256 = try optionalHashHexAlloc(allocator, bytes);
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

    var meta = try loadWritableMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;

    var old_bytes: []u8 = &.{};
    var old_count: u64 = 0;
    var has_old = false;
    if (findDictMetaIndex(meta, dict_name)) |idx| {
        old_bytes = try readDictBytes(allocator, root_dir, meta.dicts[idx]);
        has_old = true;
        const scan = try dictScanCountAndFindValueId(old_bytes, value);
        old_count = scan.count;
        if (scan.found_id) |id| {
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

pub fn internStringDictMany(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    dict_name: []const u8,
    values: []const []const u8,
    out_ids: []u64,
    out_inserted: []bool,
) TableError!DictInternManyResult {
    if (values.len != out_ids.len or values.len != out_inserted.len) return TableError.InvalidFormat;
    try validateDictName(dict_name);
    for (values) |value| try validateDictValue(value);

    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var meta = try loadWritableMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    if (meta.locked) return TableError.Locked;

    var old_bytes: []u8 = &.{};
    var old_count: u64 = 0;
    var has_old = false;
    if (findDictMetaIndex(meta, dict_name)) |idx| {
        old_bytes = try readDictBytes(allocator, root_dir, meta.dicts[idx]);
        has_old = true;
        old_count = try dictEntryCount(old_bytes);
    }
    defer if (has_old) allocator.free(old_bytes);

    const pending_values = try allocator.alloc([]const u8, values.len);
    defer allocator.free(pending_values);
    var pending_count: usize = 0;
    var inserted_count: u64 = 0;
    var next_id = old_count;

    for (values, 0..) |value, idx| {
        if (has_old) {
            if (try dictFindValueId(old_bytes, value)) |id| {
                out_ids[idx] = id;
                out_inserted[idx] = false;
                continue;
            }
        }

        var existing_pending: ?u64 = null;
        for (pending_values[0..pending_count], 0..) |pending_value, pending_idx| {
            if (std.mem.eql(u8, pending_value, value)) {
                existing_pending = old_count + @as(u64, pending_idx) + 1;
                break;
            }
        }
        if (existing_pending) |id| {
            out_ids[idx] = id;
            out_inserted[idx] = false;
            continue;
        }

        next_id = std.math.add(u64, next_id, 1) catch return TableError.CursorOverflow;
        out_ids[idx] = next_id;
        out_inserted[idx] = true;
        pending_values[pending_count] = value;
        pending_count += 1;
        inserted_count = std.math.add(u64, inserted_count, 1) catch return TableError.CursorOverflow;
    }

    if (pending_count == 0) {
        return .{ .info = tableInfo(meta), .inserted_count = 0 };
    }

    const new_bytes = try buildDictBytesWithValues(allocator, old_bytes, old_count, pending_values[0..pending_count]);
    defer allocator.free(new_bytes);

    const new_count = std.math.add(u64, old_count, pending_count) catch return TableError.CursorOverflow;
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
    return .{ .info = tableInfo(meta), .inserted_count = inserted_count };
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

    var meta = try loadWritableMeta(allocator, root_dir, table_name);
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

    var meta = try loadWritableMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    const request = [_]CreateIndexRequest{.{
        .kind = .u64,
        .column_index = column_index,
        .unique = unique,
    }};
    return createIndexesForTableLocked(allocator, root_dir, table_name, &meta, &request);
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

    var meta = try loadWritableMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    const request = [_]CreateIndexRequest{.{
        .kind = .i64,
        .column_index = column_index,
        .unique = unique,
    }};
    return createIndexesForTableLocked(allocator, root_dir, table_name, &meta, &request);
}

pub fn createU32Index(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    unique: bool,
) TableError!TableInfo {
    return createSmallIntegerIndex(allocator, root_dir, table_name, column_index, unique, .u32);
}

pub fn createI32Index(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    unique: bool,
) TableError!TableInfo {
    return createSmallIntegerIndex(allocator, root_dir, table_name, column_index, unique, .i32);
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

    var meta = try loadWritableMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    const request_kind: CreateIndexKind = switch (kind) {
        .u8 => .u8,
        .i8 => .i8,
        .u16 => .u16,
        .i16 => .i16,
        .u32 => .u32,
        .i32 => .i32,
        .u64 => .u64,
        .i64 => .i64,
        .f32 => .f32,
        .f64 => .f64,
    };
    const request = [_]CreateIndexRequest{.{
        .kind = request_kind,
        .column_index = column_index,
        .unique = unique,
    }};
    return createIndexesForTableLocked(allocator, root_dir, table_name, &meta, &request);
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

    var meta = try loadWritableMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    const request = [_]CreateIndexRequest{.{
        .kind = .u64_pair,
        .column_index = column_index,
        .column_index2 = column_index2,
        .unique = unique,
    }};
    return createIndexesForTableLocked(allocator, root_dir, table_name, &meta, &request);
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

    var meta = try loadWritableMeta(allocator, root_dir, table_name);
    defer meta.deinit(allocator);
    const request = [_]CreateIndexRequest{.{
        .kind = .u64_i64_pair,
        .column_index = column_index,
        .column_index2 = column_index2,
        .unique = unique,
    }};
    return createIndexesForTableLocked(allocator, root_dir, table_name, &meta, &request);
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
    const request = [_]CreateIndexRequest{.{
        .kind = .blob_eq,
        .column_index = column_index,
        .store_name = store_name,
        .unique = unique,
    }};
    return createIndexes(allocator, root_dir, table_name, &request);
}

pub fn createBlobTokenIndex(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    store_name: []const u8,
) TableError!TableInfo {
    try validateBlobStoreName(store_name);
    const request = [_]CreateIndexRequest{.{
        .kind = .blob_token,
        .column_index = column_index,
        .store_name = store_name,
    }};
    return createIndexes(allocator, root_dir, table_name, &request);
}

pub fn createBlobPrefixIndex(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    store_name: []const u8,
) TableError!TableInfo {
    try validateBlobStoreName(store_name);
    const request = [_]CreateIndexRequest{.{
        .kind = .blob_prefix,
        .column_index = column_index,
        .store_name = store_name,
    }};
    return createIndexes(allocator, root_dir, table_name, &request);
}

pub fn createBlobContainsIndex(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    store_name: []const u8,
) TableError!TableInfo {
    try validateBlobStoreName(store_name);
    const request = [_]CreateIndexRequest{.{
        .kind = .blob_contains,
        .column_index = column_index,
        .store_name = store_name,
    }};
    return createIndexes(allocator, root_dir, table_name, &request);
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

fn writeU16LE(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset .. offset + 2][0..2], value, .little);
}

fn writeI16LE(bytes: []u8, offset: usize, value: i16) void {
    std.mem.writeInt(i16, bytes[offset .. offset + 2][0..2], value, .little);
}

fn writeU8(bytes: []u8, offset: usize, value: u8) void {
    bytes[offset] = value;
}

fn writeI8(bytes: []u8, offset: usize, value: i8) void {
    bytes[offset] = @bitCast(value);
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

const CachedColumnBytes = struct {
    loaded: bool = false,
    owned: bool = false,
    bytes: []const u8 = &.{},
};

const CachedBlobStore = struct {
    loaded: bool = false,
    blob_idx: usize = 0,
    bytes: []u8 = &.{},
    refs: []BlobValueRef = &.{},
};

fn indexEntryLessThan(_: void, lhs: IndexEntry, rhs: IndexEntry) bool {
    return lhs.key < rhs.key or (lhs.key == rhs.key and lhs.row < rhs.row);
}

fn indexEntrySortedAfter(previous: IndexEntry, current: IndexEntry) bool {
    return previous.key < current.key or (previous.key == current.key and previous.row <= current.row);
}

fn singleIndexCanAppendTail(unique: bool, existing_last_key: u64, existing_last_row: u64, appended_first_key: u64, appended_first_row: u64) bool {
    return existing_last_key < appended_first_key or
        (existing_last_key == appended_first_key and !unique and existing_last_row <= appended_first_row);
}

fn u64PairIndexEntryLessThan(_: void, lhs: U64PairIndexEntry, rhs: U64PairIndexEntry) bool {
    if (lhs.key1 != rhs.key1) return lhs.key1 < rhs.key1;
    if (lhs.key2 != rhs.key2) return lhs.key2 < rhs.key2;
    return lhs.row < rhs.row;
}

fn u64PairIndexEntrySortedAfter(previous: U64PairIndexEntry, current: U64PairIndexEntry) bool {
    if (previous.key1 != current.key1) return previous.key1 < current.key1;
    if (previous.key2 != current.key2) return previous.key2 < current.key2;
    return previous.row <= current.row;
}

fn u64PairIndexCanAppendTail(unique: bool, existing_last_key1: u64, existing_last_key2: u64, existing_last_row: u64, appended_first_key1: u64, appended_first_key2: u64, appended_first_row: u64) bool {
    return existing_last_key1 < appended_first_key1 or
        (existing_last_key1 == appended_first_key1 and
        (existing_last_key2 < appended_first_key2 or
        (existing_last_key2 == appended_first_key2 and !unique and existing_last_row <= appended_first_row)));
}

fn variableIndexCanAppendTail(existing_last_key: u64, existing_last_row: u64, appended_first_key: u64, appended_first_row: u64) bool {
    return existing_last_key < appended_first_key or
        (existing_last_key == appended_first_key and existing_last_row < appended_first_row);
}

fn radixSortIndexEntries(allocator: std.mem.Allocator, entries: []IndexEntry) TableError!void {
    if (entries.len <= 1) return;

    const buffer = try allocator.alloc(IndexEntry, entries.len);
    defer allocator.free(buffer);

    var src = entries;
    var dst = buffer;

    var shift: usize = 0;
    while (shift < 64) : (shift += 8) {
        var counts = [_]usize{0} ** 256;
        for (src) |entry| counts[@intCast((entry.key >> @as(u6, @intCast(shift))) & 0xff)] += 1;

        var offsets: [256]usize = undefined;
        var total: usize = 0;
        for (&offsets, counts) |*offset, count| {
            offset.* = total;
            total += count;
        }

        for (src) |entry| {
            const bucket: usize = @intCast((entry.key >> @as(u6, @intCast(shift))) & 0xff);
            dst[offsets[bucket]] = entry;
            offsets[bucket] += 1;
        }

        const tmp = src;
        src = dst;
        dst = tmp;
    }

    if (src.ptr != entries.ptr) @memcpy(entries, src);
}

fn radixSortU64PairIndexEntries(allocator: std.mem.Allocator, entries: []U64PairIndexEntry) TableError!void {
    if (entries.len <= 1) return;

    const buffer = try allocator.alloc(U64PairIndexEntry, entries.len);
    defer allocator.free(buffer);

    var src = entries;
    var dst = buffer;

    inline for ([_][]const u8{ "key2", "key1" }) |field_name| {
        var shift: usize = 0;
        while (shift < 64) : (shift += 8) {
            var counts = [_]usize{0} ** 256;
            for (src) |entry| {
                const value = @field(entry, field_name);
                counts[@intCast((value >> @as(u6, @intCast(shift))) & 0xff)] += 1;
            }

            var offsets: [256]usize = undefined;
            var total: usize = 0;
            for (&offsets, counts) |*offset, count| {
                offset.* = total;
                total += count;
            }

            for (src) |entry| {
                const value = @field(entry, field_name);
                const bucket: usize = @intCast((value >> @as(u6, @intCast(shift))) & 0xff);
                dst[offsets[bucket]] = entry;
                offsets[bucket] += 1;
            }

            const tmp = src;
            src = dst;
            dst = tmp;
        }
    }

    if (src.ptr != entries.ptr) @memcpy(entries, src);
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

fn getCachedSegmentColumnBytes(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    segment: SegmentMeta,
    column_index: usize,
    expected_stride: u32,
    in_memory_columns: ?[]const RawColumnBytes,
    cache: []CachedColumnBytes,
) TableError![]const u8 {
    if (column_index >= segment.files.len or column_index >= cache.len) return TableError.InvalidFormat;
    if (!cache[column_index].loaded) {
        const expected_len = try expectedColumnBytes(segment.rows, expected_stride);
        if (in_memory_columns) |columns| {
            if (column_index >= columns.len) return TableError.InvalidFormat;
            if (columns[column_index].bytes.len != expected_len) return TableError.VerifyFailed;
            cache[column_index] = .{ .loaded = true, .bytes = columns[column_index].bytes };
        } else {
            const file_meta = segment.files[column_index];
            const path = try activePath(allocator, root_dir, file_meta.path);
            defer allocator.free(path);
            const bytes = try readFileAlloc(allocator, path, 1 << 30);
            errdefer allocator.free(bytes);
            if (bytes.len != expected_len or file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
            cache[column_index] = .{ .loaded = true, .owned = true, .bytes = bytes };
        }
    }
    return cache[column_index].bytes;
}

fn getCachedBlobStore(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    store_name: []const u8,
    cache: *CachedBlobStore,
) TableError!?*const CachedBlobStore {
    const blob_idx = findBlobStoreMetaIndex(meta, store_name) orelse return null;
    if (!cache.loaded or cache.blob_idx != blob_idx) {
        if (cache.loaded) {
            allocator.free(cache.refs);
            allocator.free(cache.bytes);
        }
        const bytes = try readBlobStoreBytes(allocator, root_dir, meta.blobs[blob_idx]);
        errdefer allocator.free(bytes);
        const refs = try buildBlobValueRefs(allocator, bytes);
        errdefer allocator.free(refs);
        cache.* = .{
            .loaded = true,
            .blob_idx = blob_idx,
            .bytes = bytes,
            .refs = refs,
        };
    }
    return cache;
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

fn readSingleIndexTailEntry(allocator: std.mem.Allocator, root_dir: []const u8, index: IndexMeta) TableError!IndexEntry {
    const path = try activePath(allocator, root_dir, index.path);
    defer allocator.free(path);

    var tail: [INDEX_RECORD_BYTES]u8 = undefined;
    try readFileTail(path, @intCast(index.bytes), &tail);
    return .{
        .key = readIndexKey(&tail, 0),
        .row = readIndexRow(&tail, 0),
    };
}

fn readU64PairIndexTailEntry(allocator: std.mem.Allocator, root_dir: []const u8, index: IndexMeta) TableError!U64PairIndexEntry {
    const path = try activePath(allocator, root_dir, index.path);
    defer allocator.free(path);

    var tail: [U64_PAIR_INDEX_RECORD_BYTES]u8 = undefined;
    try readFileTail(path, @intCast(index.bytes), &tail);
    return .{
        .key1 = readU64PairIndexKey1(&tail, 0),
        .key2 = readU64PairIndexKey2(&tail, 0),
        .row = readU64PairIndexRow(&tail, 0),
    };
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

fn shouldValidateMergedIndexes() bool {
    return builtin.mode != .ReleaseFast;
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
    var already_sorted = true;
    var have_previous = false;
    var previous_entry: IndexEntry = undefined;
    for (meta.segments) |segment| {
        const mapped = try mappedSegmentColumnBytes(allocator, root_dir, segment, column_index, 8);
        defer if (mapped.memory.len != 0) std.posix.munmap(mapped.memory);
        const bytes = mappedRegionBytes(mapped);
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const entry = IndexEntry{ .key = readU64LE(bytes, byte_offset), .row = row_base + i };
            if (have_previous and !indexEntrySortedAfter(previous_entry, entry)) already_sorted = false;
            previous_entry = entry;
            have_previous = true;
            entries[entry_idx] = entry;
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    if (!already_sorted) try radixSortIndexEntries(allocator, entries);
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
    var already_sorted = true;
    var have_previous = false;
    var previous_entry: IndexEntry = undefined;
    for (meta.segments) |segment| {
        const mapped = try mappedSegmentColumnBytes(allocator, root_dir, segment, column_index, 8);
        defer if (mapped.memory.len != 0) std.posix.munmap(mapped.memory);
        const bytes = mappedRegionBytes(mapped);
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const entry = IndexEntry{ .key = sortableI64Key(readI64LE(bytes, byte_offset)), .row = row_base + i };
            if (have_previous and !indexEntrySortedAfter(previous_entry, entry)) already_sorted = false;
            previous_entry = entry;
            have_previous = true;
            entries[entry_idx] = entry;
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    if (!already_sorted) try radixSortIndexEntries(allocator, entries);
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
    var already_sorted = true;
    var have_previous = false;
    var previous_entry: IndexEntry = undefined;
    for (meta.segments) |segment| {
        const mapped = try mappedSegmentColumnBytes(allocator, root_dir, segment, column_index, 4);
        defer if (mapped.memory.len != 0) std.posix.munmap(mapped.memory);
        const bytes = mappedRegionBytes(mapped);
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            const entry = IndexEntry{ .key = readU32LE(bytes, byte_offset), .row = row_base + i };
            if (have_previous and !indexEntrySortedAfter(previous_entry, entry)) already_sorted = false;
            previous_entry = entry;
            have_previous = true;
            entries[entry_idx] = entry;
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    if (!already_sorted) try radixSortIndexEntries(allocator, entries);
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
    var already_sorted = true;
    var have_previous = false;
    var previous_entry: IndexEntry = undefined;
    for (meta.segments) |segment| {
        const mapped = try mappedSegmentColumnBytes(allocator, root_dir, segment, column_index, 4);
        defer if (mapped.memory.len != 0) std.posix.munmap(mapped.memory);
        const bytes = mappedRegionBytes(mapped);
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 4);
            const entry = IndexEntry{ .key = sortableI32Key(readI32LE(bytes, byte_offset)), .row = row_base + i };
            if (have_previous and !indexEntrySortedAfter(previous_entry, entry)) already_sorted = false;
            previous_entry = entry;
            have_previous = true;
            entries[entry_idx] = entry;
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    if (!already_sorted) try radixSortIndexEntries(allocator, entries);
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
    var already_sorted = true;
    var have_previous = false;
    var previous_entry: IndexEntry = undefined;
    for (meta.segments) |segment| {
        const mapped = try mappedSegmentColumnBytes(allocator, root_dir, segment, column_index, stride);
        defer if (mapped.memory.len != 0) std.posix.munmap(mapped.memory);
        const bytes = mappedRegionBytes(mapped);
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * @as(u64, stride));
            const entry = IndexEntry{ .key = try readSingleIndexKey(kind, bytes, byte_offset), .row = row_base + i };
            if (have_previous and !indexEntrySortedAfter(previous_entry, entry)) already_sorted = false;
            previous_entry = entry;
            have_previous = true;
            entries[entry_idx] = entry;
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    if (!already_sorted) try radixSortIndexEntries(allocator, entries);
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
    var already_sorted = true;
    var have_previous = false;
    var previous_entry: U64PairIndexEntry = undefined;
    for (meta.segments) |segment| {
        const mapped1 = try mappedSegmentColumnBytes(allocator, root_dir, segment, column_index, 8);
        defer if (mapped1.memory.len != 0) std.posix.munmap(mapped1.memory);
        const mapped2 = try mappedSegmentColumnBytes(allocator, root_dir, segment, column_index2, 8);
        defer if (mapped2.memory.len != 0) std.posix.munmap(mapped2.memory);
        const bytes1 = mappedRegionBytes(mapped1);
        const bytes2 = mappedRegionBytes(mapped2);
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const entry = U64PairIndexEntry{
                .key1 = readU64LE(bytes1, byte_offset),
                .key2 = readU64LE(bytes2, byte_offset),
                .row = row_base + i,
            };
            if (have_previous and !u64PairIndexEntrySortedAfter(previous_entry, entry)) already_sorted = false;
            previous_entry = entry;
            have_previous = true;
            entries[entry_idx] = entry;
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    if (!already_sorted) try radixSortU64PairIndexEntries(allocator, entries);
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
    var already_sorted = true;
    var have_previous = false;
    var previous_entry: U64PairIndexEntry = undefined;
    for (meta.segments) |segment| {
        const mapped1 = try mappedSegmentColumnBytes(allocator, root_dir, segment, column_index, 8);
        defer if (mapped1.memory.len != 0) std.posix.munmap(mapped1.memory);
        const mapped2 = try mappedSegmentColumnBytes(allocator, root_dir, segment, column_index2, 8);
        defer if (mapped2.memory.len != 0) std.posix.munmap(mapped2.memory);
        const bytes1 = mappedRegionBytes(mapped1);
        const bytes2 = mappedRegionBytes(mapped2);
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            const entry = U64PairIndexEntry{
                .key1 = readU64LE(bytes1, byte_offset),
                .key2 = sortableI64Key(readI64LE(bytes2, byte_offset)),
                .row = row_base + i,
            };
            if (have_previous and !u64PairIndexEntrySortedAfter(previous_entry, entry)) already_sorted = false;
            previous_entry = entry;
            have_previous = true;
            entries[entry_idx] = entry;
            entry_idx += 1;
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (entry_idx != entries.len or row_base != meta.row_count) return TableError.VerifyFailed;

    if (!already_sorted) try radixSortU64PairIndexEntries(allocator, entries);
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
        const mapped = try mappedSegmentColumnBytes(allocator, root_dir, segment, column_index, 8);
        defer if (mapped.memory.len != 0) std.posix.munmap(mapped.memory);
        const bytes = mappedRegionBytes(mapped);
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

fn mergeIndexEntryBytes(
    allocator: std.mem.Allocator,
    existing_bytes: []const u8,
    appended_bytes: []const u8,
    total_row_count: u64,
    unique: bool,
) TableError![]u8 {
    if (existing_bytes.len % INDEX_RECORD_BYTES != 0) return TableError.VerifyFailed;
    if (appended_bytes.len % INDEX_RECORD_BYTES != 0) return TableError.VerifyFailed;

    const existing_count = existing_bytes.len / INDEX_RECORD_BYTES;
    const appended_count = appended_bytes.len / INDEX_RECORD_BYTES;
    const total_count = std.math.add(usize, existing_count, appended_count) catch return TableError.CursorOverflow;

    if (existing_count == 0) {
        const out = try allocator.dupe(u8, appended_bytes);
        if (shouldValidateMergedIndexes()) try validateIndexBytesShape(out, total_row_count, unique);
        return out;
    }
    if (appended_count == 0) {
        const out = try allocator.dupe(u8, existing_bytes);
        if (shouldValidateMergedIndexes()) try validateIndexBytesShape(out, total_row_count, unique);
        return out;
    }

    const existing_last_key = readIndexKey(existing_bytes, existing_count - 1);
    const existing_last_row = readIndexRow(existing_bytes, existing_count - 1);
    const appended_first_key = readIndexKey(appended_bytes, 0);
    const appended_first_row = readIndexRow(appended_bytes, 0);
    if (existing_last_key < appended_first_key or
        (existing_last_key == appended_first_key and !unique and existing_last_row <= appended_first_row))
    {
        const out = try allocator.alloc(u8, total_count * INDEX_RECORD_BYTES);
        errdefer allocator.free(out);
        @memcpy(out[0..existing_bytes.len], existing_bytes);
        @memcpy(out[existing_bytes.len..], appended_bytes);
        if (shouldValidateMergedIndexes()) try validateIndexBytesShape(out, total_row_count, unique);
        return out;
    }

    const out = try allocator.alloc(u8, total_count * INDEX_RECORD_BYTES);
    errdefer allocator.free(out);

    var existing_idx: usize = 0;
    var appended_idx: usize = 0;
    var out_idx: usize = 0;
    var have_prev = false;
    var prev_key: u64 = 0;
    var prev_row: u64 = 0;
    while (existing_idx < existing_count or appended_idx < appended_count) : (out_idx += 1) {
        const use_existing = if (existing_idx >= existing_count)
            false
        else if (appended_idx >= appended_count)
            true
        else blk: {
            const existing = IndexEntry{ .key = readIndexKey(existing_bytes, existing_idx), .row = readIndexRow(existing_bytes, existing_idx) };
            const appended = IndexEntry{ .key = readIndexKey(appended_bytes, appended_idx), .row = readIndexRow(appended_bytes, appended_idx) };
            break :blk indexEntryLessThan({}, existing, appended);
        };

        const chosen = if (use_existing) blk: {
            const entry = IndexEntry{ .key = readIndexKey(existing_bytes, existing_idx), .row = readIndexRow(existing_bytes, existing_idx) };
            existing_idx += 1;
            break :blk entry;
        } else blk: {
            const entry = IndexEntry{ .key = readIndexKey(appended_bytes, appended_idx), .row = readIndexRow(appended_bytes, appended_idx) };
            appended_idx += 1;
            break :blk entry;
        };

        if (have_prev) {
            if (prev_key > chosen.key) return TableError.VerifyFailed;
            if (prev_key == chosen.key) {
                if (unique) return TableError.ConstraintViolation;
                if (prev_row > chosen.row) return TableError.VerifyFailed;
            }
        }
        writeIndexEntry(out, out_idx, chosen);
        prev_key = chosen.key;
        prev_row = chosen.row;
        have_prev = true;
    }

    if (out_idx != total_count) return TableError.VerifyFailed;
    if (shouldValidateMergedIndexes()) try validateIndexBytesShape(out, total_row_count, unique);
    return out;
}

fn mergeVariableIndexEntryBytes(
    allocator: std.mem.Allocator,
    existing_bytes: []const u8,
    appended_bytes: []const u8,
    total_row_count: u64,
) TableError![]u8 {
    if (existing_bytes.len % INDEX_RECORD_BYTES != 0) return TableError.VerifyFailed;
    if (appended_bytes.len % INDEX_RECORD_BYTES != 0) return TableError.VerifyFailed;

    const existing_count = existing_bytes.len / INDEX_RECORD_BYTES;
    const appended_count = appended_bytes.len / INDEX_RECORD_BYTES;
    const total_count = std.math.add(usize, existing_count, appended_count) catch return TableError.CursorOverflow;

    if (existing_count == 0) {
        const out = try allocator.dupe(u8, appended_bytes);
        if (shouldValidateMergedIndexes()) try validateVariableIndexBytesShape(out, total_row_count);
        return out;
    }
    if (appended_count == 0) {
        const out = try allocator.dupe(u8, existing_bytes);
        if (shouldValidateMergedIndexes()) try validateVariableIndexBytesShape(out, total_row_count);
        return out;
    }

    const existing_last_key = readIndexKey(existing_bytes, existing_count - 1);
    const existing_last_row = readIndexRow(existing_bytes, existing_count - 1);
    const appended_first_key = readIndexKey(appended_bytes, 0);
    const appended_first_row = readIndexRow(appended_bytes, 0);
    if (existing_last_key < appended_first_key or
        (existing_last_key == appended_first_key and existing_last_row < appended_first_row))
    {
        const out = try allocator.alloc(u8, total_count * INDEX_RECORD_BYTES);
        errdefer allocator.free(out);
        @memcpy(out[0..existing_bytes.len], existing_bytes);
        @memcpy(out[existing_bytes.len..], appended_bytes);
        if (shouldValidateMergedIndexes()) try validateVariableIndexBytesShape(out, total_row_count);
        return out;
    }

    const out = try allocator.alloc(u8, total_count * INDEX_RECORD_BYTES);
    errdefer allocator.free(out);

    var existing_idx: usize = 0;
    var appended_idx: usize = 0;
    var out_idx: usize = 0;
    var dedup_count: usize = 0;
    var have_prev = false;
    var prev_key: u64 = 0;
    var prev_row: u64 = 0;
    while (existing_idx < existing_count or appended_idx < appended_count) : (out_idx += 1) {
        const use_existing = if (existing_idx >= existing_count)
            false
        else if (appended_idx >= appended_count)
            true
        else blk: {
            const existing = IndexEntry{ .key = readIndexKey(existing_bytes, existing_idx), .row = readIndexRow(existing_bytes, existing_idx) };
            const appended = IndexEntry{ .key = readIndexKey(appended_bytes, appended_idx), .row = readIndexRow(appended_bytes, appended_idx) };
            break :blk indexEntryLessThan({}, existing, appended);
        };

        const chosen = if (use_existing) blk: {
            const entry = IndexEntry{ .key = readIndexKey(existing_bytes, existing_idx), .row = readIndexRow(existing_bytes, existing_idx) };
            existing_idx += 1;
            break :blk entry;
        } else blk: {
            const entry = IndexEntry{ .key = readIndexKey(appended_bytes, appended_idx), .row = readIndexRow(appended_bytes, appended_idx) };
            appended_idx += 1;
            break :blk entry;
        };

        if (!have_prev) {
            writeIndexEntry(out, dedup_count, chosen);
            dedup_count = 1;
            prev_key = chosen.key;
            prev_row = chosen.row;
            have_prev = true;
            continue;
        }

        if (prev_key > chosen.key or (prev_key == chosen.key and prev_row > chosen.row)) return TableError.VerifyFailed;
        if (prev_key == chosen.key and prev_row == chosen.row) continue;
        writeIndexEntry(out, dedup_count, chosen);
        dedup_count += 1;
        prev_key = chosen.key;
        prev_row = chosen.row;
    }

    const final_len = std.math.mul(usize, dedup_count, INDEX_RECORD_BYTES) catch return TableError.CursorOverflow;
    const trimmed = try allocator.alloc(u8, final_len);
    errdefer allocator.free(trimmed);
    if (final_len != 0) @memcpy(trimmed, out[0..final_len]);
    allocator.free(out);
    if (shouldValidateMergedIndexes()) try validateVariableIndexBytesShape(trimmed, total_row_count);
    return trimmed;
}

fn mergeU64PairIndexBytes(
    allocator: std.mem.Allocator,
    existing_bytes: []const u8,
    appended_bytes: []const u8,
    total_row_count: u64,
    unique: bool,
) TableError![]u8 {
    if (existing_bytes.len % U64_PAIR_INDEX_RECORD_BYTES != 0) return TableError.VerifyFailed;
    if (appended_bytes.len % U64_PAIR_INDEX_RECORD_BYTES != 0) return TableError.VerifyFailed;

    const existing_count = existing_bytes.len / U64_PAIR_INDEX_RECORD_BYTES;
    const appended_count = appended_bytes.len / U64_PAIR_INDEX_RECORD_BYTES;
    const total_count = std.math.add(usize, existing_count, appended_count) catch return TableError.CursorOverflow;

    if (existing_count == 0) {
        const out = try allocator.dupe(u8, appended_bytes);
        if (shouldValidateMergedIndexes()) try validateU64PairIndexBytesShape(out, total_row_count, unique);
        return out;
    }
    if (appended_count == 0) {
        const out = try allocator.dupe(u8, existing_bytes);
        if (shouldValidateMergedIndexes()) try validateU64PairIndexBytesShape(out, total_row_count, unique);
        return out;
    }

    const existing_last_key1 = readU64PairIndexKey1(existing_bytes, existing_count - 1);
    const existing_last_key2 = readU64PairIndexKey2(existing_bytes, existing_count - 1);
    const existing_last_row = readU64PairIndexRow(existing_bytes, existing_count - 1);
    const appended_first_key1 = readU64PairIndexKey1(appended_bytes, 0);
    const appended_first_key2 = readU64PairIndexKey2(appended_bytes, 0);
    const appended_first_row = readU64PairIndexRow(appended_bytes, 0);
    const can_append_tail = existing_last_key1 < appended_first_key1 or
        (existing_last_key1 == appended_first_key1 and
        (existing_last_key2 < appended_first_key2 or
        (existing_last_key2 == appended_first_key2 and !unique and existing_last_row <= appended_first_row)));
    if (can_append_tail) {
        const out = try allocator.alloc(u8, total_count * U64_PAIR_INDEX_RECORD_BYTES);
        errdefer allocator.free(out);
        @memcpy(out[0..existing_bytes.len], existing_bytes);
        @memcpy(out[existing_bytes.len..], appended_bytes);
        if (shouldValidateMergedIndexes()) try validateU64PairIndexBytesShape(out, total_row_count, unique);
        return out;
    }

    const out = try allocator.alloc(u8, total_count * U64_PAIR_INDEX_RECORD_BYTES);
    errdefer allocator.free(out);

    var existing_idx: usize = 0;
    var appended_idx: usize = 0;
    var out_idx: usize = 0;
    var have_prev = false;
    var prev_key1: u64 = 0;
    var prev_key2: u64 = 0;
    var prev_row: u64 = 0;
    while (existing_idx < existing_count or appended_idx < appended_count) : (out_idx += 1) {
        const use_existing = if (existing_idx >= existing_count)
            false
        else if (appended_idx >= appended_count)
            true
        else blk: {
            const existing = U64PairIndexEntry{
                .key1 = readU64PairIndexKey1(existing_bytes, existing_idx),
                .key2 = readU64PairIndexKey2(existing_bytes, existing_idx),
                .row = readU64PairIndexRow(existing_bytes, existing_idx),
            };
            const appended = U64PairIndexEntry{
                .key1 = readU64PairIndexKey1(appended_bytes, appended_idx),
                .key2 = readU64PairIndexKey2(appended_bytes, appended_idx),
                .row = readU64PairIndexRow(appended_bytes, appended_idx),
            };
            break :blk u64PairIndexEntryLessThan({}, existing, appended);
        };

        const chosen = if (use_existing) blk: {
            const entry = U64PairIndexEntry{
                .key1 = readU64PairIndexKey1(existing_bytes, existing_idx),
                .key2 = readU64PairIndexKey2(existing_bytes, existing_idx),
                .row = readU64PairIndexRow(existing_bytes, existing_idx),
            };
            existing_idx += 1;
            break :blk entry;
        } else blk: {
            const entry = U64PairIndexEntry{
                .key1 = readU64PairIndexKey1(appended_bytes, appended_idx),
                .key2 = readU64PairIndexKey2(appended_bytes, appended_idx),
                .row = readU64PairIndexRow(appended_bytes, appended_idx),
            };
            appended_idx += 1;
            break :blk entry;
        };

        if (have_prev) {
            if (prev_key1 > chosen.key1) return TableError.VerifyFailed;
            if (prev_key1 == chosen.key1) {
                if (prev_key2 > chosen.key2) return TableError.VerifyFailed;
                if (prev_key2 == chosen.key2) {
                    if (unique) return TableError.ConstraintViolation;
                    if (prev_row > chosen.row) return TableError.VerifyFailed;
                }
            }
        }
        writeU64PairIndexEntry(out, out_idx, chosen);
        prev_key1 = chosen.key1;
        prev_key2 = chosen.key2;
        prev_row = chosen.row;
        have_prev = true;
    }

    if (out_idx != total_count) return TableError.VerifyFailed;
    if (shouldValidateMergedIndexes()) try validateU64PairIndexBytesShape(out, total_row_count, unique);
    return out;
}

fn buildSingleIndexBytesForSegment(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    segment: SegmentMeta,
    row_base: u64,
    column_index: usize,
    kind: SingleIndexKind,
    unique: bool,
    in_memory_columns: ?[]const RawColumnBytes,
    column_cache: []CachedColumnBytes,
) TableError![]u8 {
    try ensureSingleIndexColumn(meta, column_index, kind);
    const row_count = segment.rows;
    if (row_count > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    const entries = try allocator.alloc(IndexEntry, @intCast(row_count));
    defer allocator.free(entries);

    const stride = singleIndexKindStride(kind);
    const bytes = try getCachedSegmentColumnBytes(allocator, root_dir, segment, column_index, stride, in_memory_columns, column_cache);

    var already_sorted = true;
    var have_previous = false;
    var previous_entry: IndexEntry = undefined;
    var i: u64 = 0;
    while (i < row_count) : (i += 1) {
        const byte_offset: usize = @intCast(i * @as(u64, stride));
        const entry = IndexEntry{ .key = try readSingleIndexKey(kind, bytes, byte_offset), .row = row_base + i };
        if (have_previous and !indexEntrySortedAfter(previous_entry, entry)) already_sorted = false;
        previous_entry = entry;
        have_previous = true;
        entries[@intCast(i)] = entry;
    }

    if (!already_sorted) try radixSortIndexEntries(allocator, entries);
    if (unique and entries.len > 1) {
        for (entries[1..], 1..) |entry, idx| {
            if (entry.key == entries[idx - 1].key) return TableError.ConstraintViolation;
        }
    }

    const out = try allocator.alloc(u8, try expectedIndexBytes(row_count));
    for (entries, 0..) |entry, idx| writeIndexEntry(out, idx, entry);
    return out;
}

fn buildU64PairIndexBytesForSegment(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    segment: SegmentMeta,
    row_base: u64,
    column_index: usize,
    column_index2: usize,
    unique: bool,
    in_memory_columns: ?[]const RawColumnBytes,
    column_cache: []CachedColumnBytes,
) TableError![]u8 {
    try ensureU64PairColumns(meta, column_index, column_index2);
    if (segment.rows > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    const entries = try allocator.alloc(U64PairIndexEntry, @intCast(segment.rows));
    defer allocator.free(entries);

    const bytes1 = try getCachedSegmentColumnBytes(allocator, root_dir, segment, column_index, 8, in_memory_columns, column_cache);
    const bytes2 = try getCachedSegmentColumnBytes(allocator, root_dir, segment, column_index2, 8, in_memory_columns, column_cache);

    var already_sorted = true;
    var have_previous = false;
    var previous_entry: U64PairIndexEntry = undefined;
    var i: u64 = 0;
    while (i < segment.rows) : (i += 1) {
        const byte_offset: usize = @intCast(i * 8);
        const entry = U64PairIndexEntry{
            .key1 = readU64LE(bytes1, byte_offset),
            .key2 = readU64LE(bytes2, byte_offset),
            .row = row_base + i,
        };
        if (have_previous and !u64PairIndexEntrySortedAfter(previous_entry, entry)) already_sorted = false;
        previous_entry = entry;
        have_previous = true;
        entries[@intCast(i)] = entry;
    }

    if (!already_sorted) try radixSortU64PairIndexEntries(allocator, entries);
    if (unique and entries.len > 1) {
        for (entries[1..], 1..) |entry, idx| {
            const previous = entries[idx - 1];
            if (entry.key1 == previous.key1 and entry.key2 == previous.key2) return TableError.ConstraintViolation;
        }
    }

    const out = try allocator.alloc(u8, try expectedU64PairIndexBytes(segment.rows));
    for (entries, 0..) |entry, idx| writeU64PairIndexEntry(out, idx, entry);
    return out;
}

fn buildU64I64PairIndexBytesForSegment(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    segment: SegmentMeta,
    row_base: u64,
    column_index: usize,
    column_index2: usize,
    unique: bool,
    in_memory_columns: ?[]const RawColumnBytes,
    column_cache: []CachedColumnBytes,
) TableError![]u8 {
    try ensureU64I64PairColumns(meta, column_index, column_index2);
    if (segment.rows > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    const entries = try allocator.alloc(U64PairIndexEntry, @intCast(segment.rows));
    defer allocator.free(entries);

    const bytes1 = try getCachedSegmentColumnBytes(allocator, root_dir, segment, column_index, 8, in_memory_columns, column_cache);
    const bytes2 = try getCachedSegmentColumnBytes(allocator, root_dir, segment, column_index2, 8, in_memory_columns, column_cache);

    var already_sorted = true;
    var have_previous = false;
    var previous_entry: U64PairIndexEntry = undefined;
    var i: u64 = 0;
    while (i < segment.rows) : (i += 1) {
        const byte_offset: usize = @intCast(i * 8);
        const entry = U64PairIndexEntry{
            .key1 = readU64LE(bytes1, byte_offset),
            .key2 = sortableI64Key(readI64LE(bytes2, byte_offset)),
            .row = row_base + i,
        };
        if (have_previous and !u64PairIndexEntrySortedAfter(previous_entry, entry)) already_sorted = false;
        previous_entry = entry;
        have_previous = true;
        entries[@intCast(i)] = entry;
    }

    if (!already_sorted) try radixSortU64PairIndexEntries(allocator, entries);
    if (unique and entries.len > 1) {
        for (entries[1..], 1..) |entry, idx| {
            const previous = entries[idx - 1];
            if (entry.key1 == previous.key1 and entry.key2 == previous.key2) return TableError.ConstraintViolation;
        }
    }

    const out = try allocator.alloc(u8, try expectedU64PairIndexBytes(segment.rows));
    for (entries, 0..) |entry, idx| writeU64PairIndexEntry(out, idx, entry);
    return out;
}

fn buildBlobEqIndexBytesForSegment(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    segment: SegmentMeta,
    row_base: u64,
    column_index: usize,
    store_name: []const u8,
    unique: bool,
    in_memory_columns: ?[]const RawColumnBytes,
    column_cache: []CachedColumnBytes,
    blob_cache: *CachedBlobStore,
) TableError![]u8 {
    try ensureBlobHandleColumn(meta, column_index);
    try validateBlobStoreName(store_name);

    const blob_refs = if (try getCachedBlobStore(allocator, root_dir, meta, store_name, blob_cache)) |blob_store| blob_store.refs else &.{};

    if (segment.rows > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
    const entries = try allocator.alloc(BlobEqIndexEntry, @intCast(segment.rows));
    defer allocator.free(entries);

    const bytes = try getCachedSegmentColumnBytes(allocator, root_dir, segment, column_index, 8, in_memory_columns, column_cache);

    var i: u64 = 0;
    while (i < segment.rows) : (i += 1) {
        const byte_offset: usize = @intCast(i * 8);
        const blob_id = readU64LE(bytes, byte_offset);
        const key = if (blobRefForId(blob_refs, blob_id)) |value_ref| value_ref.hash else 0;
        entries[@intCast(i)] = .{ .key = key, .row = row_base + i, .blob_id = blob_id };
    }

    std.sort.block(BlobEqIndexEntry, entries, {}, blobEqIndexEntryLessThan);
    if (unique and entries.len > 1) {
        var group_start: usize = 0;
        while (group_start < entries.len) {
            var group_end = group_start + 1;
            while (group_end < entries.len and entries[group_end].key == entries[group_start].key) : (group_end += 1) {}
            var lhs = group_start;
            while (lhs < group_end) : (lhs += 1) {
                const value = blobRefForId(blob_refs, entries[lhs].blob_id) orelse continue;
                var rhs = group_start;
                while (rhs < lhs) : (rhs += 1) {
                    const previous_value = blobRefForId(blob_refs, entries[rhs].blob_id) orelse continue;
                    if (std.mem.eql(u8, value.value, previous_value.value)) return TableError.ConstraintViolation;
                }
            }
            group_start = group_end;
        }
    }

    const out = try allocator.alloc(u8, try expectedIndexBytes(segment.rows));
    for (entries, 0..) |entry, idx| writeIndexEntry(out, idx, .{ .key = entry.key, .row = entry.row });
    return out;
}

fn buildBlobTokenIndexBytesForSegment(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    segment: SegmentMeta,
    row_base: u64,
    column_index: usize,
    store_name: []const u8,
    in_memory_columns: ?[]const RawColumnBytes,
    column_cache: []CachedColumnBytes,
    blob_cache: *CachedBlobStore,
) TableError![]u8 {
    try ensureBlobHandleColumn(meta, column_index);
    try validateBlobStoreName(store_name);

    const blob_refs = if (try getCachedBlobStore(allocator, root_dir, meta, store_name, blob_cache)) |blob_store| blob_store.refs else &.{};

    var entries = std.ArrayList(IndexEntry).init(allocator);
    defer entries.deinit();

    const bytes = try getCachedSegmentColumnBytes(allocator, root_dir, segment, column_index, 8, in_memory_columns, column_cache);

    var i: u64 = 0;
    while (i < segment.rows) : (i += 1) {
        const byte_offset: usize = @intCast(i * 8);
        const blob_id = readU64LE(bytes, byte_offset);
        const value_ref = blobRefForId(blob_refs, blob_id) orelse continue;
        try appendBlobTokenEntriesForValue(&entries, row_base + i, value_ref.value);
    }

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

fn buildBlobPrefixIndexBytesForSegment(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    segment: SegmentMeta,
    row_base: u64,
    column_index: usize,
    store_name: []const u8,
    in_memory_columns: ?[]const RawColumnBytes,
    column_cache: []CachedColumnBytes,
    blob_cache: *CachedBlobStore,
) TableError![]u8 {
    try ensureBlobHandleColumn(meta, column_index);
    try validateBlobStoreName(store_name);

    const blob_refs = if (try getCachedBlobStore(allocator, root_dir, meta, store_name, blob_cache)) |blob_store| blob_store.refs else &.{};

    var entries = std.ArrayList(IndexEntry).init(allocator);
    defer entries.deinit();

    const bytes = try getCachedSegmentColumnBytes(allocator, root_dir, segment, column_index, 8, in_memory_columns, column_cache);

    var i: u64 = 0;
    while (i < segment.rows) : (i += 1) {
        const byte_offset: usize = @intCast(i * 8);
        const blob_id = readU64LE(bytes, byte_offset);
        const value_ref = blobRefForId(blob_refs, blob_id) orelse continue;
        try appendBlobPrefixEntriesForValue(&entries, row_base + i, value_ref.value);
    }

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

fn buildBlobContainsIndexBytesForSegment(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    segment: SegmentMeta,
    row_base: u64,
    column_index: usize,
    store_name: []const u8,
    in_memory_columns: ?[]const RawColumnBytes,
    column_cache: []CachedColumnBytes,
    blob_cache: *CachedBlobStore,
) TableError![]u8 {
    try ensureBlobHandleColumn(meta, column_index);
    try validateBlobStoreName(store_name);

    const blob_refs = if (try getCachedBlobStore(allocator, root_dir, meta, store_name, blob_cache)) |blob_store| blob_store.refs else &.{};

    var entries = std.ArrayList(IndexEntry).init(allocator);
    defer entries.deinit();

    const bytes = try getCachedSegmentColumnBytes(allocator, root_dir, segment, column_index, 8, in_memory_columns, column_cache);

    var i: u64 = 0;
    while (i < segment.rows) : (i += 1) {
        const byte_offset: usize = @intCast(i * 8);
        const blob_id = readU64LE(bytes, byte_offset);
        const value_ref = blobRefForId(blob_refs, blob_id) orelse continue;
        try appendBlobContainsEntriesForValue(&entries, row_base + i, value_ref.value);
    }

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

fn rewriteIndexMetaBytes(allocator: std.mem.Allocator, root_dir: []const u8, table_name: []const u8, epoch: u64, index: *IndexMeta, bytes: []const u8) TableError!void {
    const store_name = if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND)) try indexBlobStoreName(index.*) else null;
    const column_index2 = if (std.mem.eql(u8, index.kind, "u64_pair") or std.mem.eql(u8, index.kind, "u64_i64_pair")) try indexColumnIndex2(index.*) else null;
    const basename = if (store_name) |name|
        if (std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND))
            try blobTokenIndexFileName(allocator, table_name, index.column_index, name, epoch)
        else if (std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND))
            try blobPrefixIndexFileName(allocator, table_name, index.column_index, name, epoch)
        else if (std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND))
            try blobContainsIndexFileName(allocator, table_name, index.column_index, name, epoch)
        else
            try blobEqIndexFileName(allocator, table_name, index.column_index, name, epoch)
    else if (column_index2) |c2|
        try pairIndexFileName(allocator, table_name, index.kind, index.column_index, c2, epoch)
    else
        try indexFileName(allocator, table_name, index.kind, index.column_index, epoch);
    defer allocator.free(basename);

    const path = try activePath(allocator, root_dir, basename);
    defer allocator.free(path);
    try writeArtifactFile(allocator, path, bytes);

    const next_path = try allocator.dupe(u8, basename);
    errdefer allocator.free(next_path);
    const hashes = try makeFileHashesSinglePass(allocator, bytes, FILE_BLOCK_BYTES);
    errdefer allocator.free(hashes.sha256);
    errdefer freeBlockSha256List(allocator, hashes.block_sha256);

    allocator.free(index.path);
    allocator.free(index.sha256);
    freeBlockSha256List(allocator, index.block_sha256);
    index.path = next_path;
    index.sha256 = hashes.sha256;
    index.bytes = bytes.len;
    index.block_size = hashes.block_size;
    index.block_sha256 = hashes.block_sha256;
}

fn appendIndexMetaBytesUnsafe(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    index: *IndexMeta,
    appended_bytes: []const u8,
) TableError!void {
    try appendFileBytesUnsafe(allocator, root_dir, index.path, appended_bytes);

    allocator.free(index.sha256);
    freeBlockSha256List(allocator, index.block_sha256);
    index.sha256 = try allocator.alloc(u8, 0);
    index.bytes = std.math.add(u64, index.bytes, appended_bytes.len) catch return TableError.CursorOverflow;
    index.block_size = 0;
    index.block_sha256 = try allocator.alloc([]const u8, 0);
}

fn rewriteIndexMetaBytesUnsafeFields(allocator: std.mem.Allocator, index: *IndexMeta, bytes_len: usize) TableError!void {
    allocator.free(index.sha256);
    freeBlockSha256List(allocator, index.block_sha256);
    index.sha256 = try allocator.alloc(u8, 0);
    index.bytes = bytes_len;
    index.block_size = 0;
    index.block_sha256 = try allocator.alloc([]const u8, 0);
}

fn mapExpandedFileReadWrite(path: []const u8, old_len: usize, new_len: usize) TableError!struct { file: std.fs.File, mapped: MappedReadRegion } {
    var file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| return mapFileError(err);
    errdefer file.close();
    const stat = file.stat() catch |err| return mapFileError(err);
    if (stat.size != old_len) return TableError.VerifyFailed;
    file.setEndPos(new_len) catch |err| return mapFileError(err);
    const mapped = std.posix.mmap(null, new_len, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, file.handle, 0) catch |err| switch (err) {
        error.OutOfMemory => return TableError.OutOfMemory,
        error.MemoryMappingNotSupported, error.AccessDenied, error.PermissionDenied => return TableError.InvalidFormat,
        else => return TableError.InvalidFormat,
    };
    return .{ .file = file, .mapped = .{ .memory = mapped } };
}

fn detectUniqueSingleMergeConflict(existing_bytes: []const u8, appended_bytes: []const u8) TableError!void {
    var existing_idx: usize = 0;
    var appended_idx: usize = 0;
    const existing_count = existing_bytes.len / INDEX_RECORD_BYTES;
    const appended_count = appended_bytes.len / INDEX_RECORD_BYTES;
    while (existing_idx < existing_count and appended_idx < appended_count) {
        const existing_key = readIndexKey(existing_bytes, existing_idx);
        const appended_key = readIndexKey(appended_bytes, appended_idx);
        if (existing_key < appended_key) {
            existing_idx += 1;
        } else if (existing_key > appended_key) {
            appended_idx += 1;
        } else {
            return TableError.ConstraintViolation;
        }
    }
}

fn detectUniquePairMergeConflict(existing_bytes: []const u8, appended_bytes: []const u8) TableError!void {
    var existing_idx: usize = 0;
    var appended_idx: usize = 0;
    const existing_count = existing_bytes.len / U64_PAIR_INDEX_RECORD_BYTES;
    const appended_count = appended_bytes.len / U64_PAIR_INDEX_RECORD_BYTES;
    while (existing_idx < existing_count and appended_idx < appended_count) {
        const existing_key1 = readU64PairIndexKey1(existing_bytes, existing_idx);
        const appended_key1 = readU64PairIndexKey1(appended_bytes, appended_idx);
        if (existing_key1 < appended_key1) {
            existing_idx += 1;
            continue;
        }
        if (existing_key1 > appended_key1) {
            appended_idx += 1;
            continue;
        }

        const existing_key2 = readU64PairIndexKey2(existing_bytes, existing_idx);
        const appended_key2 = readU64PairIndexKey2(appended_bytes, appended_idx);
        if (existing_key2 < appended_key2) {
            existing_idx += 1;
        } else if (existing_key2 > appended_key2) {
            appended_idx += 1;
        } else {
            return TableError.ConstraintViolation;
        }
    }
}

fn unsafeMergeSingleIndexFileInPlace(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    index: *IndexMeta,
    appended_bytes: []const u8,
    unique: bool,
    validate_variable_shape: bool,
    total_row_count: u64,
) TableError!void {
    if (appended_bytes.len % INDEX_RECORD_BYTES != 0) return TableError.VerifyFailed;

    const existing_len: usize = @intCast(index.bytes);
    if (existing_len % INDEX_RECORD_BYTES != 0) return TableError.VerifyFailed;
    const appended_len = appended_bytes.len;
    if (appended_len == 0) return;

    const existing_count = existing_len / INDEX_RECORD_BYTES;
    const appended_count = appended_len / INDEX_RECORD_BYTES;
    const total_count = std.math.add(usize, existing_count, appended_count) catch return TableError.CursorOverflow;
    const total_len = std.math.mul(usize, total_count, INDEX_RECORD_BYTES) catch return TableError.CursorOverflow;

    const path = try activePath(allocator, root_dir, index.path);
    defer allocator.free(path);

    var mapped_file = try mapExpandedFileReadWrite(path, existing_len, total_len);
    defer mapped_file.file.close();
    defer if (mapped_file.mapped.memory.len != 0) std.posix.munmap(mapped_file.mapped.memory);

    const bytes = mappedRegionBytes(mapped_file.mapped);
    var writable = @as([]u8, @constCast(bytes));
    if (unique) try detectUniqueSingleMergeConflict(bytes[0..existing_len], appended_bytes);

    @memcpy(writable[existing_len..total_len], appended_bytes);

    var existing_idx: isize = @intCast(existing_count);
    existing_idx -= 1;
    var appended_idx: isize = @intCast(appended_count);
    appended_idx -= 1;
    var out_idx: isize = @intCast(total_count);
    out_idx -= 1;

    while (existing_idx >= 0 or appended_idx >= 0) : (out_idx -= 1) {
        const use_existing = if (appended_idx < 0)
            true
        else if (existing_idx < 0)
            false
        else blk: {
            const existing = IndexEntry{
                .key = readIndexKey(writable, @intCast(existing_idx)),
                .row = readIndexRow(writable, @intCast(existing_idx)),
            };
            const appended = IndexEntry{
                .key = readIndexKey(appended_bytes, @intCast(appended_idx)),
                .row = readIndexRow(appended_bytes, @intCast(appended_idx)),
            };
            break :blk !indexEntryLessThan({}, existing, appended);
        };

        const chosen = if (use_existing) blk: {
            const entry = IndexEntry{
                .key = readIndexKey(writable, @intCast(existing_idx)),
                .row = readIndexRow(writable, @intCast(existing_idx)),
            };
            existing_idx -= 1;
            break :blk entry;
        } else blk: {
            const entry = IndexEntry{
                .key = readIndexKey(appended_bytes, @intCast(appended_idx)),
                .row = readIndexRow(appended_bytes, @intCast(appended_idx)),
            };
            appended_idx -= 1;
            break :blk entry;
        };

        writeIndexEntry(writable, @intCast(out_idx), chosen);
    }

    if (validate_variable_shape) {
        try validateVariableIndexBytesShape(writable, total_row_count);
    } else {
        try validateIndexBytesShape(writable, total_row_count, unique);
    }
    try rewriteIndexMetaBytesUnsafeFields(allocator, index, total_len);
}

fn unsafeMergeU64PairIndexFileInPlace(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    index: *IndexMeta,
    appended_bytes: []const u8,
    unique: bool,
    total_row_count: u64,
) TableError!void {
    if (appended_bytes.len % U64_PAIR_INDEX_RECORD_BYTES != 0) return TableError.VerifyFailed;

    const existing_len: usize = @intCast(index.bytes);
    if (existing_len % U64_PAIR_INDEX_RECORD_BYTES != 0) return TableError.VerifyFailed;
    const appended_len = appended_bytes.len;
    if (appended_len == 0) return;

    const existing_count = existing_len / U64_PAIR_INDEX_RECORD_BYTES;
    const appended_count = appended_len / U64_PAIR_INDEX_RECORD_BYTES;
    const total_count = std.math.add(usize, existing_count, appended_count) catch return TableError.CursorOverflow;
    const total_len = std.math.mul(usize, total_count, U64_PAIR_INDEX_RECORD_BYTES) catch return TableError.CursorOverflow;

    const path = try activePath(allocator, root_dir, index.path);
    defer allocator.free(path);

    var mapped_file = try mapExpandedFileReadWrite(path, existing_len, total_len);
    defer mapped_file.file.close();
    defer if (mapped_file.mapped.memory.len != 0) std.posix.munmap(mapped_file.mapped.memory);

    const bytes = mappedRegionBytes(mapped_file.mapped);
    var writable = @as([]u8, @constCast(bytes));
    if (unique) try detectUniquePairMergeConflict(bytes[0..existing_len], appended_bytes);

    @memcpy(writable[existing_len..total_len], appended_bytes);

    var existing_idx: isize = @intCast(existing_count);
    existing_idx -= 1;
    var appended_idx: isize = @intCast(appended_count);
    appended_idx -= 1;
    var out_idx: isize = @intCast(total_count);
    out_idx -= 1;

    while (existing_idx >= 0 or appended_idx >= 0) : (out_idx -= 1) {
        const use_existing = if (appended_idx < 0)
            true
        else if (existing_idx < 0)
            false
        else blk: {
            const existing = U64PairIndexEntry{
                .key1 = readU64PairIndexKey1(writable, @intCast(existing_idx)),
                .key2 = readU64PairIndexKey2(writable, @intCast(existing_idx)),
                .row = readU64PairIndexRow(writable, @intCast(existing_idx)),
            };
            const appended = U64PairIndexEntry{
                .key1 = readU64PairIndexKey1(appended_bytes, @intCast(appended_idx)),
                .key2 = readU64PairIndexKey2(appended_bytes, @intCast(appended_idx)),
                .row = readU64PairIndexRow(appended_bytes, @intCast(appended_idx)),
            };
            break :blk !u64PairIndexEntryLessThan({}, existing, appended);
        };

        const chosen = if (use_existing) blk: {
            const entry = U64PairIndexEntry{
                .key1 = readU64PairIndexKey1(writable, @intCast(existing_idx)),
                .key2 = readU64PairIndexKey2(writable, @intCast(existing_idx)),
                .row = readU64PairIndexRow(writable, @intCast(existing_idx)),
            };
            existing_idx -= 1;
            break :blk entry;
        } else blk: {
            const entry = U64PairIndexEntry{
                .key1 = readU64PairIndexKey1(appended_bytes, @intCast(appended_idx)),
                .key2 = readU64PairIndexKey2(appended_bytes, @intCast(appended_idx)),
                .row = readU64PairIndexRow(appended_bytes, @intCast(appended_idx)),
            };
            appended_idx -= 1;
            break :blk entry;
        };

        writeU64PairIndexEntry(writable, @intCast(out_idx), chosen);
    }

    try validateU64PairIndexBytesShape(writable, total_row_count, unique);
    try rewriteIndexMetaBytesUnsafeFields(allocator, index, total_len);
}

fn rewriteIndexMetaBytesUnsafe(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    index: *IndexMeta,
    bytes: []const u8,
) TableError!void {
    const path = try activePath(allocator, root_dir, index.path);
    defer allocator.free(path);
    try writeArtifactFile(allocator, path, bytes);

    allocator.free(index.sha256);
    freeBlockSha256List(allocator, index.block_sha256);
    index.sha256 = try allocator.alloc(u8, 0);
    index.bytes = bytes.len;
    index.block_size = 0;
    index.block_sha256 = try allocator.alloc([]const u8, 0);
}

fn tryAppendIndexesForAppendedRows(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: *TableMeta,
    segment: SegmentMeta,
    previous_row_count: u64,
    appended_row_count: u64,
    in_memory_columns: ?[]const RawColumnBytes,
) TableError!bool {
    if (previous_row_count + appended_row_count != meta.row_count) return TableError.VerifyFailed;
    if (segment.rows != appended_row_count) return TableError.VerifyFailed;
    if (meta.indexes.len == 0) return true;

    const column_cache = try allocator.alloc(CachedColumnBytes, segment.files.len);
    defer {
        for (column_cache) |cached| if (cached.loaded and cached.owned) allocator.free(cached.bytes);
        allocator.free(column_cache);
    }
    for (column_cache) |*cached| cached.* = .{};

    var blob_cache = CachedBlobStore{};
    defer {
        if (blob_cache.loaded) {
            allocator.free(blob_cache.refs);
            allocator.free(blob_cache.bytes);
        }
    }

    for (0..meta.indexes.len) |idx| {
        const index = &meta.indexes[idx];

        if (std.mem.eql(u8, index.kind, "u64") or
            std.mem.eql(u8, index.kind, "i64") or
            std.mem.eql(u8, index.kind, "u32") or
            std.mem.eql(u8, index.kind, "i32") or
            std.mem.eql(u8, index.kind, "u8") or
            std.mem.eql(u8, index.kind, "i8") or
            std.mem.eql(u8, index.kind, "u16") or
            std.mem.eql(u8, index.kind, "i16") or
            std.mem.eql(u8, index.kind, "f32") or
            std.mem.eql(u8, index.kind, "f64"))
        {
            const kind = singleIndexKindFromName(index.kind) orelse return TableError.InvalidFormat;
            const appended = try buildSingleIndexBytesForSegment(allocator, root_dir, meta.*, segment, previous_row_count, @intCast(index.column_index), kind, index.unique, in_memory_columns, column_cache);
            defer allocator.free(appended);
            if (skipDurabilitySync() and index.bytes != 0) {
                if (appended.len != 0) {
                    const existing_tail = try readSingleIndexTailEntry(allocator, root_dir, index.*);
                    const appended_first_key = readIndexKey(appended, 0);
                    const appended_first_row = readIndexRow(appended, 0);
                    if (singleIndexCanAppendTail(index.unique, existing_tail.key, existing_tail.row, appended_first_key, appended_first_row)) {
                        try appendIndexMetaBytesUnsafe(allocator, root_dir, index, appended);
                        continue;
                    }
                }
            }
            const index_path = try activePath(allocator, root_dir, index.path);
            defer allocator.free(index_path);
            const mapped_existing = try mappedReadFile(index_path, @intCast(index.bytes));
            defer if (mapped_existing.memory.len != 0) std.posix.munmap(mapped_existing.memory);
            const existing_bytes = mappedRegionBytes(mapped_existing);
            if (skipDurabilitySync()) {
                try unsafeMergeSingleIndexFileInPlace(allocator, root_dir, index, appended, index.unique, false, meta.row_count);
            } else {
                const merged = try mergeIndexEntryBytes(allocator, existing_bytes, appended, meta.row_count, index.unique);
                defer allocator.free(merged);
                try rewriteIndexMetaBytes(allocator, root_dir, meta.table_name, meta.epoch, index, merged);
            }
            continue;
        }

        if (std.mem.eql(u8, index.kind, "u64_pair")) {
            const column_index2 = try indexColumnIndex2(index.*);
            const appended = try buildU64PairIndexBytesForSegment(allocator, root_dir, meta.*, segment, previous_row_count, @intCast(index.column_index), column_index2, index.unique, in_memory_columns, column_cache);
            defer allocator.free(appended);
            if (skipDurabilitySync() and index.bytes != 0) {
                if (appended.len != 0) {
                    const existing_tail = try readU64PairIndexTailEntry(allocator, root_dir, index.*);
                    const appended_first_key1 = readU64PairIndexKey1(appended, 0);
                    const appended_first_key2 = readU64PairIndexKey2(appended, 0);
                    const appended_first_row = readU64PairIndexRow(appended, 0);
                    if (u64PairIndexCanAppendTail(index.unique, existing_tail.key1, existing_tail.key2, existing_tail.row, appended_first_key1, appended_first_key2, appended_first_row)) {
                        try appendIndexMetaBytesUnsafe(allocator, root_dir, index, appended);
                        continue;
                    }
                }
            }
            const index_path = try activePath(allocator, root_dir, index.path);
            defer allocator.free(index_path);
            const mapped_existing = try mappedReadFile(index_path, @intCast(index.bytes));
            defer if (mapped_existing.memory.len != 0) std.posix.munmap(mapped_existing.memory);
            const existing_bytes = mappedRegionBytes(mapped_existing);
            if (skipDurabilitySync()) {
                try unsafeMergeU64PairIndexFileInPlace(allocator, root_dir, index, appended, index.unique, meta.row_count);
            } else {
                const merged = try mergeU64PairIndexBytes(allocator, existing_bytes, appended, meta.row_count, index.unique);
                defer allocator.free(merged);
                try rewriteIndexMetaBytes(allocator, root_dir, meta.table_name, meta.epoch, index, merged);
            }
            continue;
        }

        if (std.mem.eql(u8, index.kind, "u64_i64_pair")) {
            const column_index2 = try indexColumnIndex2(index.*);
            const appended = try buildU64I64PairIndexBytesForSegment(allocator, root_dir, meta.*, segment, previous_row_count, @intCast(index.column_index), column_index2, index.unique, in_memory_columns, column_cache);
            defer allocator.free(appended);
            if (skipDurabilitySync() and index.bytes != 0) {
                if (appended.len != 0) {
                    const existing_tail = try readU64PairIndexTailEntry(allocator, root_dir, index.*);
                    const appended_first_key1 = readU64PairIndexKey1(appended, 0);
                    const appended_first_key2 = readU64PairIndexKey2(appended, 0);
                    const appended_first_row = readU64PairIndexRow(appended, 0);
                    if (u64PairIndexCanAppendTail(index.unique, existing_tail.key1, existing_tail.key2, existing_tail.row, appended_first_key1, appended_first_key2, appended_first_row)) {
                        try appendIndexMetaBytesUnsafe(allocator, root_dir, index, appended);
                        continue;
                    }
                }
            }
            const index_path = try activePath(allocator, root_dir, index.path);
            defer allocator.free(index_path);
            const mapped_existing = try mappedReadFile(index_path, @intCast(index.bytes));
            defer if (mapped_existing.memory.len != 0) std.posix.munmap(mapped_existing.memory);
            const existing_bytes = mappedRegionBytes(mapped_existing);
            if (skipDurabilitySync()) {
                try unsafeMergeU64PairIndexFileInPlace(allocator, root_dir, index, appended, index.unique, meta.row_count);
            } else {
                const merged = try mergeU64PairIndexBytes(allocator, existing_bytes, appended, meta.row_count, index.unique);
                defer allocator.free(merged);
                try rewriteIndexMetaBytes(allocator, root_dir, meta.table_name, meta.epoch, index, merged);
            }
            continue;
        }

        if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND)) {
            const store_name = try indexBlobStoreName(index.*);
            const appended = try buildBlobEqIndexBytesForSegment(allocator, root_dir, meta.*, segment, previous_row_count, @intCast(index.column_index), store_name, index.unique, in_memory_columns, column_cache, &blob_cache);
            defer allocator.free(appended);
            if (skipDurabilitySync() and index.bytes != 0) {
                if (appended.len != 0) {
                    const existing_tail = try readSingleIndexTailEntry(allocator, root_dir, index.*);
                    const appended_first_key = readIndexKey(appended, 0);
                    const appended_first_row = readIndexRow(appended, 0);
                    if (singleIndexCanAppendTail(index.unique, existing_tail.key, existing_tail.row, appended_first_key, appended_first_row)) {
                        try appendIndexMetaBytesUnsafe(allocator, root_dir, index, appended);
                        continue;
                    }
                }
            }
            const index_path = try activePath(allocator, root_dir, index.path);
            defer allocator.free(index_path);
            const mapped_existing = try mappedReadFile(index_path, @intCast(index.bytes));
            defer if (mapped_existing.memory.len != 0) std.posix.munmap(mapped_existing.memory);
            const existing_bytes = mappedRegionBytes(mapped_existing);
            if (skipDurabilitySync()) {
                try unsafeMergeSingleIndexFileInPlace(allocator, root_dir, index, appended, index.unique, false, meta.row_count);
            } else {
                const merged = try mergeIndexEntryBytes(allocator, existing_bytes, appended, meta.row_count, index.unique);
                defer allocator.free(merged);
                try rewriteIndexMetaBytes(allocator, root_dir, meta.table_name, meta.epoch, index, merged);
            }
            continue;
        }

        if (std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND)) {
            const store_name = try indexBlobStoreName(index.*);
            const appended = try buildBlobTokenIndexBytesForSegment(allocator, root_dir, meta.*, segment, previous_row_count, @intCast(index.column_index), store_name, in_memory_columns, column_cache, &blob_cache);
            defer allocator.free(appended);
            if (skipDurabilitySync() and index.bytes != 0) {
                if (appended.len != 0) {
                    const existing_tail = try readSingleIndexTailEntry(allocator, root_dir, index.*);
                    const appended_first_key = readIndexKey(appended, 0);
                    const appended_first_row = readIndexRow(appended, 0);
                    if (variableIndexCanAppendTail(existing_tail.key, existing_tail.row, appended_first_key, appended_first_row)) {
                        try appendIndexMetaBytesUnsafe(allocator, root_dir, index, appended);
                        continue;
                    }
                }
            }
            const index_path = try activePath(allocator, root_dir, index.path);
            defer allocator.free(index_path);
            const mapped_existing = try mappedReadFile(index_path, @intCast(index.bytes));
            defer if (mapped_existing.memory.len != 0) std.posix.munmap(mapped_existing.memory);
            const existing_bytes = mappedRegionBytes(mapped_existing);
            if (skipDurabilitySync()) {
                try unsafeMergeSingleIndexFileInPlace(allocator, root_dir, index, appended, false, true, meta.row_count);
            } else {
                const merged = try mergeVariableIndexEntryBytes(allocator, existing_bytes, appended, meta.row_count);
                defer allocator.free(merged);
                try rewriteIndexMetaBytes(allocator, root_dir, meta.table_name, meta.epoch, index, merged);
            }
            continue;
        }

        if (std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND)) {
            const store_name = try indexBlobStoreName(index.*);
            const appended = try buildBlobPrefixIndexBytesForSegment(allocator, root_dir, meta.*, segment, previous_row_count, @intCast(index.column_index), store_name, in_memory_columns, column_cache, &blob_cache);
            defer allocator.free(appended);
            if (skipDurabilitySync() and index.bytes != 0) {
                if (appended.len != 0) {
                    const existing_tail = try readSingleIndexTailEntry(allocator, root_dir, index.*);
                    const appended_first_key = readIndexKey(appended, 0);
                    const appended_first_row = readIndexRow(appended, 0);
                    if (variableIndexCanAppendTail(existing_tail.key, existing_tail.row, appended_first_key, appended_first_row)) {
                        try appendIndexMetaBytesUnsafe(allocator, root_dir, index, appended);
                        continue;
                    }
                }
            }
            const index_path = try activePath(allocator, root_dir, index.path);
            defer allocator.free(index_path);
            const mapped_existing = try mappedReadFile(index_path, @intCast(index.bytes));
            defer if (mapped_existing.memory.len != 0) std.posix.munmap(mapped_existing.memory);
            const existing_bytes = mappedRegionBytes(mapped_existing);
            if (skipDurabilitySync()) {
                try unsafeMergeSingleIndexFileInPlace(allocator, root_dir, index, appended, false, true, meta.row_count);
            } else {
                const merged = try mergeVariableIndexEntryBytes(allocator, existing_bytes, appended, meta.row_count);
                defer allocator.free(merged);
                try rewriteIndexMetaBytes(allocator, root_dir, meta.table_name, meta.epoch, index, merged);
            }
            continue;
        }

        if (std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND)) {
            const store_name = try indexBlobStoreName(index.*);
            const appended = try buildBlobContainsIndexBytesForSegment(allocator, root_dir, meta.*, segment, previous_row_count, @intCast(index.column_index), store_name, in_memory_columns, column_cache, &blob_cache);
            defer allocator.free(appended);
            if (skipDurabilitySync() and index.bytes != 0) {
                if (appended.len != 0) {
                    const existing_tail = try readSingleIndexTailEntry(allocator, root_dir, index.*);
                    const appended_first_key = readIndexKey(appended, 0);
                    const appended_first_row = readIndexRow(appended, 0);
                    if (variableIndexCanAppendTail(existing_tail.key, existing_tail.row, appended_first_key, appended_first_row)) {
                        try appendIndexMetaBytesUnsafe(allocator, root_dir, index, appended);
                        continue;
                    }
                }
            }
            const index_path = try activePath(allocator, root_dir, index.path);
            defer allocator.free(index_path);
            const mapped_existing = try mappedReadFile(index_path, @intCast(index.bytes));
            defer if (mapped_existing.memory.len != 0) std.posix.munmap(mapped_existing.memory);
            const existing_bytes = mappedRegionBytes(mapped_existing);
            if (skipDurabilitySync()) {
                try unsafeMergeSingleIndexFileInPlace(allocator, root_dir, index, appended, false, true, meta.row_count);
            } else {
                const merged = try mergeVariableIndexEntryBytes(allocator, existing_bytes, appended, meta.row_count);
                defer allocator.free(merged);
                try rewriteIndexMetaBytes(allocator, root_dir, meta.table_name, meta.epoch, index, merged);
            }
            continue;
        }

        return false;
    }

    return true;
}

fn tryAppendIndexesForSegment(allocator: std.mem.Allocator, root_dir: []const u8, meta: *TableMeta, segment_index: usize, previous_row_count: u64, in_memory_columns: ?[]const RawColumnBytes) TableError!bool {
    if (segment_index >= meta.segments.len) return TableError.InvalidFormat;
    return try tryAppendIndexesForAppendedRows(allocator, root_dir, meta, meta.segments[segment_index], previous_row_count, meta.segments[segment_index].rows, in_memory_columns);
}

fn buildIndexBytesForMeta(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    index: IndexMeta,
) TableError![]u8 {
    if (index.column_index > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.InvalidFormat;
    const column_index: usize = @intCast(index.column_index);
    const column_index2: ?usize = if (std.mem.eql(u8, index.kind, "u64_pair") or std.mem.eql(u8, index.kind, "u64_i64_pair")) try indexColumnIndex2(index) else null;
    const store_name = if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND)) try indexBlobStoreName(index) else null;

    return if (std.mem.eql(u8, index.kind, "u64"))
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
    else if (std.mem.eql(u8, index.kind, "u64_pair"))
        try buildU64PairIndexBytes(allocator, root_dir, meta, column_index, column_index2.?, index.unique)
    else if (std.mem.eql(u8, index.kind, "u64_i64_pair"))
        try buildU64I64PairIndexBytes(allocator, root_dir, meta, column_index, column_index2.?, index.unique)
    else if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND))
        try buildBlobEqIndexBytes(allocator, root_dir, meta, column_index, store_name.?, index.unique)
    else if (std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND))
        try buildBlobTokenIndexBytes(allocator, root_dir, meta, column_index, store_name.?)
    else if (std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND))
        try buildBlobPrefixIndexBytes(allocator, root_dir, meta, column_index, store_name.?)
    else if (std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND))
        try buildBlobContainsIndexBytes(allocator, root_dir, meta, column_index, store_name.?)
    else
        TableError.InvalidFormat;
}

fn rebuildIndexAt(allocator: std.mem.Allocator, root_dir: []const u8, meta: *TableMeta, index_idx: usize) TableError!void {
    const index = &meta.indexes[index_idx];
    const column_index2: ?usize = if (std.mem.eql(u8, index.kind, "u64_pair") or std.mem.eql(u8, index.kind, "u64_i64_pair")) try indexColumnIndex2(index.*) else null;
    const store_name = if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_TOKEN_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_PREFIX_INDEX_KIND) or std.mem.eql(u8, index.kind, BLOB_CONTAINS_INDEX_KIND)) try indexBlobStoreName(index.*) else null;
    const bytes = try buildIndexBytesForMeta(allocator, root_dir, meta.*, index.*);
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
    try writeArtifactFile(allocator, path, bytes);
    const next_path = try allocator.dupe(u8, basename);
    errdefer allocator.free(next_path);
    const hashes = try makeFileHashesSinglePass(allocator, bytes, FILE_BLOCK_BYTES);
    errdefer allocator.free(hashes.sha256);
    errdefer freeBlockSha256List(allocator, hashes.block_sha256);
    allocator.free(index.path);
    allocator.free(index.sha256);
    freeBlockSha256List(allocator, index.block_sha256);
    index.path = next_path;
    index.sha256 = hashes.sha256;
    index.bytes = bytes.len;
    index.block_size = hashes.block_size;
    index.block_sha256 = hashes.block_sha256;
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
        .mapped_regions = &.{},
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
    snapshot.mapped_regions = try backing_allocator.alloc(MappedReadRegion, parsed.value.segments.len * parsed.value.columns.len + parsed.value.indexes.len + parsed.value.dicts.len + parsed.value.blobs.len);
    for (snapshot.mapped_regions) |*region| region.* = .{ .memory = &[_]u8{} };

    var mapped_region_idx: usize = 0;

    for (parsed.value.segments, 0..) |segment, segment_idx| {
        const segment_columns = try arena_allocator.alloc(ReadColumnSnapshot, segment.files.len);
        if (segment.files.len != parsed.value.columns.len) return TableError.InvalidFormat;
        for (segment.files, 0..) |file_meta, column_idx| {
            const expected_len = try expectedColumnBytes(segment.rows, parsed.value.columns[column_idx].stride);
            if (file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
            const path = try activePath(backing_allocator, root_dir, file_meta.path);
            defer backing_allocator.free(path);
            const mapped = try mappedReadFile(path, expected_len);
            snapshot.mapped_regions[mapped_region_idx] = mapped;
            mapped_region_idx += 1;
            const bytes = mappedRegionBytes(mapped);
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
        const mapped = try mappedReadFile(path, @intCast(index.bytes));
        snapshot.mapped_regions[mapped_region_idx] = mapped;
        mapped_region_idx += 1;
        const bytes = mappedRegionBytes(mapped);
        try validateOptionalSha256(index.sha256, bytes);
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
        if (dict.path.len == 0 or (dict.sha256.len != 0 and dict.sha256.len != 64)) return TableError.VerifyFailed;
        for (parsed.value.dicts[0..dict_idx]) |previous| {
            if (std.mem.eql(u8, previous.name, dict.name)) return TableError.VerifyFailed;
        }
        const path = try activePath(backing_allocator, root_dir, dict.path);
        defer backing_allocator.free(path);
        const mapped = try mappedReadFile(path, @intCast(dict.bytes));
        snapshot.mapped_regions[mapped_region_idx] = mapped;
        mapped_region_idx += 1;
        const bytes = mappedRegionBytes(mapped);
        if (bytes.len != dict.bytes) return TableError.VerifyFailed;
        if (try dictEntryCount(bytes) != dict.entries) return TableError.VerifyFailed;
        try validateOptionalSha256(dict.sha256, bytes);
        try validateDictBlockHashes(dict, bytes);
        snapshot.dicts[dict_idx] = .{
            .name = try arena_allocator.dupe(u8, dict.name),
            .bytes = bytes,
            .entries = dict.entries,
        };
    }

    for (parsed.value.blobs, 0..) |blob, blob_idx| {
        try validateBlobStoreName(blob.name);
        if (blob.path.len == 0 or (blob.sha256.len != 0 and blob.sha256.len != 64)) return TableError.VerifyFailed;
        for (parsed.value.blobs[0..blob_idx]) |previous| {
            if (std.mem.eql(u8, previous.name, blob.name)) return TableError.VerifyFailed;
        }
        const path = try activePath(backing_allocator, root_dir, blob.path);
        defer backing_allocator.free(path);
        const mapped = try mappedReadFile(path, @intCast(blob.bytes));
        snapshot.mapped_regions[mapped_region_idx] = mapped;
        mapped_region_idx += 1;
        const bytes = mappedRegionBytes(mapped);
        if (bytes.len != blob.bytes) return TableError.VerifyFailed;
        if (try blobEntryCount(bytes) != blob.entries) return TableError.VerifyFailed;
        try validateOptionalSha256(blob.sha256, bytes);
        try validateBlobStoreBlockHashes(blob, bytes);
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

fn ensureSnapshotNullBitmapColumn(snapshot: *const ReadSnapshot, column_index: usize) TableError!void {
    if (column_index >= snapshot.columns.len) return TableError.InvalidFormat;
    const column = snapshot.columns[column_index];
    if (column.logical_type != schema.LOGICAL_NULL_BITMAP) return TableError.InvalidFormat;
    const ty = try parsePrimTypeTable(column.ty);
    if (ty != .u8 or column.stride != 1) return TableError.InvalidFormat;
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

fn findBlobEqInUniqueIndex(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    index: ReadIndexSnapshot,
    column_index: usize,
    blob_bytes: []const u8,
    needle: []const u8,
) TableError!U64FindResult {
    const refs = try buildBlobValueRefs(allocator, blob_bytes);
    defer allocator.free(refs);

    const key = blobValueHash(needle);
    const start = lowerBoundU64Index(index, key);
    const end = upperBoundU64Index(index, key);
    var matched_row: ?u64 = null;
    var i = start;
    while (i < end) : (i += 1) {
        const row = readIndexRow(index.entries, i);
        if (row >= snapshot.row_count) return TableError.VerifyFailed;
        const blob_id = try snapshotBlobHandleAtRow(snapshot, column_index, row);
        const value_ref = blobRefForId(refs, blob_id) orelse continue;
        if (!std.mem.eql(u8, value_ref.value, needle)) continue;
        if (matched_row != null) return TableError.VerifyFailed;
        matched_row = row;
    }
    if (matched_row) |row| return .{ .found = true, .row_index = row };
    return .{ .found = false, .row_index = 0 };
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

fn readNullBitmapColumnValue(column: ColumnMeta, bytes: []const u8, local_row: u64) TableError!bool {
    if (column.logical_type != schema.LOGICAL_NULL_BITMAP) return TableError.InvalidFormat;
    return try readBoolColumnValue(column, bytes, local_row);
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

fn snapshotUniqueIndexForI64Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i64") and index.unique and index.column_index == @as(u64, @intCast(column_index))) return index;
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

fn snapshotUniqueIndexForU32Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u32") and index.unique and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForI32Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i32") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotUniqueIndexForI32Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i32") and index.unique and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForU8Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u8") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotUniqueIndexForU8Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u8") and index.unique and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForI8Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i8") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotUniqueIndexForI8Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i8") and index.unique and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForU16Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u16") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotUniqueIndexForU16Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u16") and index.unique and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotIndexForI16Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i16") and index.column_index == @as(u64, @intCast(column_index))) return index;
    }
    return null;
}

fn snapshotUniqueIndexForI16Column(snapshot: *const ReadSnapshot, column_index: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i16") and index.unique and index.column_index == @as(u64, @intCast(column_index))) return index;
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

fn snapshotUniqueIndexForU64PairColumns(snapshot: *const ReadSnapshot, column_index: usize, column_index2: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64_pair") and
            index.unique and
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

fn snapshotUniqueIndexForU64I64PairColumns(snapshot: *const ReadSnapshot, column_index: usize, column_index2: usize) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64_i64_pair") and
            index.unique and
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

fn snapshotUniqueIndexForBlobEqColumnStore(snapshot: *const ReadSnapshot, column_index: usize, store_name: []const u8) ?ReadIndexSnapshot {
    for (snapshot.indexes) |index| {
        if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND) and
            index.unique and
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

const FilterRowsU64NullBitmapContext = struct {
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: u64,
    max_value: u64,
    null_bitmap: []const u8,
    want_null: bool,
};

fn matchesRowsU64NullBitmap(context: FilterRowsU64NullBitmapContext, row: u64) TableError!bool {
    const value = try snapshotU64AtRow(context.snapshot, context.column_index, row);
    if (value < context.min_value or value > context.max_value) return false;
    return nullBitmapRowIsNull(context.null_bitmap, row) == context.want_null;
}

const FilterRowsI64NullBitmapContext = struct {
    snapshot: *const ReadSnapshot,
    column_index: usize,
    min_value: i64,
    max_value: i64,
    null_bitmap: []const u8,
    want_null: bool,
};

fn matchesRowsI64NullBitmap(context: FilterRowsI64NullBitmapContext, row: u64) TableError!bool {
    const value = try snapshotI64AtRow(context.snapshot, context.column_index, row);
    if (value < context.min_value or value > context.max_value) return false;
    return nullBitmapRowIsNull(context.null_bitmap, row) == context.want_null;
}

pub fn snapshotFilterRowsU64RangeNullBitmap(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    min_value: u64,
    max_value: u64,
    null_bitmap: []const u8,
    want_null: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, column_index);
    try validateSnapshotRows(snapshot, in_rows);
    try ensureNullBitmapRows(snapshot.row_count, null_bitmap);
    if (min_value > max_value) return .{ .written = 0, .total = 0 };
    return try copyCandidateRowsByPredicate(in_rows, offset, limit, out_rows, FilterRowsU64NullBitmapContext{
        .snapshot = snapshot,
        .column_index = column_index,
        .min_value = min_value,
        .max_value = max_value,
        .null_bitmap = null_bitmap,
        .want_null = want_null,
    }, matchesRowsU64NullBitmap);
}

pub fn snapshotFilterRowsI64RangeNullBitmap(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    min_value: i64,
    max_value: i64,
    null_bitmap: []const u8,
    want_null: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotI64Column(snapshot, column_index);
    try validateSnapshotRows(snapshot, in_rows);
    try ensureNullBitmapRows(snapshot.row_count, null_bitmap);
    if (min_value > max_value) return .{ .written = 0, .total = 0 };
    return try copyCandidateRowsByPredicate(in_rows, offset, limit, out_rows, FilterRowsI64NullBitmapContext{
        .snapshot = snapshot,
        .column_index = column_index,
        .min_value = min_value,
        .max_value = max_value,
        .null_bitmap = null_bitmap,
        .want_null = want_null,
    }, matchesRowsI64NullBitmap);
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

pub fn snapshotExportNullBitmap(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    out_bitmap: []u8,
) TableError!ExportNullBitmapResult {
    try ensureSnapshotNullBitmapColumn(snapshot, column_index);
    const required = try requiredNullBitmapBytes(snapshot.row_count);
    if (out_bitmap.len < required) return TableError.CursorOverflow;
    @memset(out_bitmap[0..required], 0);

    var row_base: u64 = 0;
    for (snapshot.segments) |segment| {
        const column = snapshot.columns[column_index];
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, column.stride);
        if (bytes.len != expected_len) return TableError.VerifyFailed;

        var local_row: u64 = 0;
        while (local_row < segment.rows) : (local_row += 1) {
            if (try readNullBitmapColumnValue(column, bytes, local_row)) {
                const row_index = std.math.add(u64, row_base, local_row) catch return TableError.CursorOverflow;
                const byte_index: usize = @intCast(row_index / 8);
                const bit: u3 = @intCast(row_index & 7);
                out_bitmap[byte_index] |= @as(u8, 1) << bit;
            }
        }
        row_base = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
    }
    if (row_base != snapshot.row_count) return TableError.VerifyFailed;
    return .{ .written_bytes = @intCast(required), .row_count = snapshot.row_count };
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

pub fn snapshotGetRowI64Key(snapshot: *const ReadSnapshot, column_index: usize, expected: i64, out_row: []u8) TableError!void {
    try ensureSnapshotI64Column(snapshot, column_index);
    const index = snapshotUniqueIndexForI64Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    const found = findI64InIndex(index, expected);
    if (!found.found) return TableError.NotFound;
    try snapshotCopyRow(snapshot, found.row_index, out_row);
}

pub fn snapshotGetRowU32Key(snapshot: *const ReadSnapshot, column_index: usize, expected: u32, out_row: []u8) TableError!void {
    try ensureSnapshotU32Column(snapshot, column_index);
    const index = snapshotUniqueIndexForU32Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    const found = findU64InIndex(index, expected);
    if (!found.found) return TableError.NotFound;
    try snapshotCopyRow(snapshot, found.row_index, out_row);
}

pub fn snapshotGetRowI32Key(snapshot: *const ReadSnapshot, column_index: usize, expected: i32, out_row: []u8) TableError!void {
    try ensureSnapshotI32Column(snapshot, column_index);
    const index = snapshotUniqueIndexForI32Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    const found = findI32InIndex(index, expected);
    if (!found.found) return TableError.NotFound;
    try snapshotCopyRow(snapshot, found.row_index, out_row);
}

pub fn snapshotGetRowU8Key(snapshot: *const ReadSnapshot, column_index: usize, expected: u8, out_row: []u8) TableError!void {
    try ensureSnapshotU8Column(snapshot, column_index);
    const index = snapshotUniqueIndexForU8Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    const found = findU64InIndex(index, expected);
    if (!found.found) return TableError.NotFound;
    try snapshotCopyRow(snapshot, found.row_index, out_row);
}

pub fn snapshotGetRowI8Key(snapshot: *const ReadSnapshot, column_index: usize, expected: i8, out_row: []u8) TableError!void {
    try ensureSnapshotI8Column(snapshot, column_index);
    const index = snapshotUniqueIndexForI8Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    const found = findI8InIndex(index, expected);
    if (!found.found) return TableError.NotFound;
    try snapshotCopyRow(snapshot, found.row_index, out_row);
}

pub fn snapshotGetRowU16Key(snapshot: *const ReadSnapshot, column_index: usize, expected: u16, out_row: []u8) TableError!void {
    try ensureSnapshotU16Column(snapshot, column_index);
    const index = snapshotUniqueIndexForU16Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    const found = findU64InIndex(index, expected);
    if (!found.found) return TableError.NotFound;
    try snapshotCopyRow(snapshot, found.row_index, out_row);
}

pub fn snapshotGetRowI16Key(snapshot: *const ReadSnapshot, column_index: usize, expected: i16, out_row: []u8) TableError!void {
    try ensureSnapshotI16Column(snapshot, column_index);
    const index = snapshotUniqueIndexForI16Column(snapshot, column_index) orelse return TableError.InvalidFormat;
    const found = findI16InIndex(index, expected);
    if (!found.found) return TableError.NotFound;
    try snapshotCopyRow(snapshot, found.row_index, out_row);
}

pub fn snapshotGetRowU64PairKey(snapshot: *const ReadSnapshot, column_index: usize, column_index2: usize, key1: u64, key2: u64, out_row: []u8) TableError!void {
    try ensureSnapshotU64Column(snapshot, column_index);
    try ensureSnapshotU64Column(snapshot, column_index2);
    const index = snapshotUniqueIndexForU64PairColumns(snapshot, column_index, column_index2) orelse return TableError.InvalidFormat;
    const found = findU64PairInIndex(index, key1, key2);
    if (!found.found) return TableError.NotFound;
    try snapshotCopyRow(snapshot, found.row_index, out_row);
}

pub fn snapshotGetRowU64I64PairKey(snapshot: *const ReadSnapshot, column_index: usize, column_index2: usize, key1: u64, key2: i64, out_row: []u8) TableError!void {
    try ensureSnapshotU64Column(snapshot, column_index);
    try ensureSnapshotI64Column(snapshot, column_index2);
    const index = snapshotUniqueIndexForU64I64PairColumns(snapshot, column_index, column_index2) orelse return TableError.InvalidFormat;
    const found = findU64PairInIndex(index, key1, sortableI64Key(key2));
    if (!found.found) return TableError.NotFound;
    try snapshotCopyRow(snapshot, found.row_index, out_row);
}

pub fn snapshotGetRowBlobEqKey(allocator: std.mem.Allocator, snapshot: *const ReadSnapshot, column_index: usize, store_name: []const u8, value: []const u8, out_row: []u8) TableError!void {
    try ensureSnapshotBlobHandleColumn(snapshot, column_index);
    try validateBlobStoreName(store_name);
    try validateBlobValue(value);
    const index = snapshotUniqueIndexForBlobEqColumnStore(snapshot, column_index, store_name) orelse return TableError.InvalidFormat;
    const blob_idx = snapshotFindBlobStoreIndex(snapshot, store_name) orelse return TableError.NotFound;
    const found = try findBlobEqInUniqueIndex(allocator, snapshot, index, column_index, snapshot.blobs[blob_idx].bytes, value);
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
    try validateOptionalSha256(index.sha256, bytes);
    try validateIndexBytesShape(bytes, meta.row_count, true);

    return findU64InIndex(.{
        .kind = "u64",
        .column_index = @intCast(column_index),
        .unique = true,
        .entries = bytes,
    }, expected);
}

fn findUniqueI64KeyRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    expected: i64,
) TableError!U64FindResult {
    try ensureI64Column(meta, column_index);
    var selected: ?IndexMeta = null;
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i64") and index.unique and index.column_index == @as(u64, @intCast(column_index))) {
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
    try validateOptionalSha256(index.sha256, bytes);
    try validateIndexBytesShape(bytes, meta.row_count, true);

    return findU64InIndex(.{
        .kind = "i64",
        .column_index = @intCast(column_index),
        .unique = true,
        .entries = bytes,
    }, sortableI64Key(expected));
}

fn findUniqueU32KeyRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    expected: u32,
) TableError!U64FindResult {
    try ensureU32Column(meta, column_index);
    var selected: ?IndexMeta = null;
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u32") and index.unique and index.column_index == @as(u64, @intCast(column_index))) {
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
    try validateOptionalSha256(index.sha256, bytes);
    try validateIndexBytesShape(bytes, meta.row_count, true);

    return findU64InIndex(.{
        .kind = "u32",
        .column_index = @intCast(column_index),
        .unique = true,
        .entries = bytes,
    }, expected);
}

fn findUniqueI32KeyRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    expected: i32,
) TableError!U64FindResult {
    try ensureI32Column(meta, column_index);
    var selected: ?IndexMeta = null;
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i32") and index.unique and index.column_index == @as(u64, @intCast(column_index))) {
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
    try validateOptionalSha256(index.sha256, bytes);
    try validateIndexBytesShape(bytes, meta.row_count, true);

    return findU64InIndex(.{
        .kind = "i32",
        .column_index = @intCast(column_index),
        .unique = true,
        .entries = bytes,
    }, sortableI32Key(expected));
}

fn findUniqueU8KeyRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    expected: u8,
) TableError!U64FindResult {
    try ensureU8Column(meta, column_index);
    var selected: ?IndexMeta = null;
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u8") and index.unique and index.column_index == @as(u64, @intCast(column_index))) {
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
    try validateOptionalSha256(index.sha256, bytes);
    try validateIndexBytesShape(bytes, meta.row_count, true);

    return findU64InIndex(.{
        .kind = "u8",
        .column_index = @intCast(column_index),
        .unique = true,
        .entries = bytes,
    }, expected);
}

fn findUniqueI8KeyRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    expected: i8,
) TableError!U64FindResult {
    try ensureI8Column(meta, column_index);
    var selected: ?IndexMeta = null;
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i8") and index.unique and index.column_index == @as(u64, @intCast(column_index))) {
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
    try validateOptionalSha256(index.sha256, bytes);
    try validateIndexBytesShape(bytes, meta.row_count, true);

    return findU64InIndex(.{
        .kind = "i8",
        .column_index = @intCast(column_index),
        .unique = true,
        .entries = bytes,
    }, sortableI8Key(expected));
}

fn findUniqueU16KeyRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    expected: u16,
) TableError!U64FindResult {
    try ensureU16Column(meta, column_index);
    var selected: ?IndexMeta = null;
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u16") and index.unique and index.column_index == @as(u64, @intCast(column_index))) {
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
    try validateOptionalSha256(index.sha256, bytes);
    try validateIndexBytesShape(bytes, meta.row_count, true);

    return findU64InIndex(.{
        .kind = "u16",
        .column_index = @intCast(column_index),
        .unique = true,
        .entries = bytes,
    }, expected);
}

fn findUniqueI16KeyRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    expected: i16,
) TableError!U64FindResult {
    try ensureI16Column(meta, column_index);
    var selected: ?IndexMeta = null;
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "i16") and index.unique and index.column_index == @as(u64, @intCast(column_index))) {
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
    try validateOptionalSha256(index.sha256, bytes);
    try validateIndexBytesShape(bytes, meta.row_count, true);

    return findU64InIndex(.{
        .kind = "i16",
        .column_index = @intCast(column_index),
        .unique = true,
        .entries = bytes,
    }, sortableI16Key(expected));
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
    try validateOptionalSha256(index.sha256, bytes);
    try validateU64PairIndexBytesShape(bytes, meta.row_count, true);

    return findU64PairInIndex(.{
        .kind = "u64_pair",
        .column_index = @intCast(column_index),
        .column_index2 = @intCast(column_index2),
        .unique = true,
        .entries = bytes,
    }, key1, key2);
}

fn findUniqueU64I64PairKeyRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    column_index2: usize,
    key1: u64,
    key2: i64,
) TableError!U64FindResult {
    try ensureU64I64PairColumns(meta, column_index, column_index2);
    var selected: ?IndexMeta = null;
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, "u64_i64_pair") and
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
    try validateOptionalSha256(index.sha256, bytes);
    try validateU64PairIndexBytesShape(bytes, meta.row_count, true);

    return findU64PairInIndex(.{
        .kind = "u64_i64_pair",
        .column_index = @intCast(column_index),
        .column_index2 = @intCast(column_index2),
        .unique = true,
        .entries = bytes,
    }, key1, sortableI64Key(key2));
}

fn blobHandleAtRowFromMeta(allocator: std.mem.Allocator, root_dir: []const u8, meta: TableMeta, column_index: usize, row_index: u64) TableError!u64 {
    try ensureBlobHandleColumn(meta, column_index);
    if (row_index >= meta.row_count) return TableError.VerifyFailed;

    var row_base: u64 = 0;
    for (meta.segments) |segment| {
        const segment_end = std.math.add(u64, row_base, segment.rows) catch return TableError.CursorOverflow;
        if (row_index < segment_end) {
            const local_row = row_index - row_base;
            const file_meta = segment.files[column_index];
            const path = try activePath(allocator, root_dir, file_meta.path);
            defer allocator.free(path);
            const bytes = try readFileAlloc(allocator, path, 1 << 30);
            defer allocator.free(bytes);
            const expected_len = try expectedColumnBytes(segment.rows, 8);
            if (bytes.len != expected_len or file_meta.bytes != @as(u64, @intCast(expected_len))) return TableError.VerifyFailed;
            const byte_offset_u64 = std.math.mul(u64, local_row, 8) catch return TableError.CursorOverflow;
            if (byte_offset_u64 > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;
            return readU64LE(bytes, @intCast(byte_offset_u64));
        }
        row_base = segment_end;
    }
    return TableError.VerifyFailed;
}

fn findUniqueBlobEqKeyRow(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    meta: TableMeta,
    column_index: usize,
    store_name: []const u8,
    value: []const u8,
) TableError!U64FindResult {
    try ensureBlobHandleColumn(meta, column_index);
    try validateBlobStoreName(store_name);
    try validateBlobValue(value);
    var selected: ?IndexMeta = null;
    for (meta.indexes) |index| {
        if (std.mem.eql(u8, index.kind, BLOB_EQ_INDEX_KIND) and
            index.unique and
            index.column_index == @as(u64, @intCast(column_index)) and
            index.column_index2 == null and
            index.store_name != null and
            std.mem.eql(u8, index.store_name.?, store_name))
        {
            selected = index;
            break;
        }
    }
    const index = selected orelse return TableError.InvalidFormat;
    if (index.bytes != @as(u64, @intCast(try expectedIndexBytes(meta.row_count)))) return TableError.VerifyFailed;

    const blob_idx = findBlobStoreMetaIndex(meta, store_name) orelse return .{ .found = false, .row_index = 0 };
    const blob_bytes = try readBlobStoreBytes(allocator, root_dir, meta.blobs[blob_idx]);
    defer allocator.free(blob_bytes);
    const refs = try buildBlobValueRefs(allocator, blob_bytes);
    defer allocator.free(refs);

    const path = try activePath(allocator, root_dir, index.path);
    defer allocator.free(path);
    const bytes = try readFileAlloc(allocator, path, 1 << 30);
    defer allocator.free(bytes);
    if (bytes.len != index.bytes) return TableError.VerifyFailed;
    try validateOptionalSha256(index.sha256, bytes);
    try validateIndexBytesShape(bytes, meta.row_count, true);

    const key = blobValueHash(value);
    const read_index = ReadIndexSnapshot{
        .kind = BLOB_EQ_INDEX_KIND,
        .column_index = @intCast(column_index),
        .unique = true,
        .entries = bytes,
    };
    const start = lowerBoundU64Index(read_index, key);
    const end = upperBoundU64Index(read_index, key);
    var matched_row: ?u64 = null;
    var i = start;
    while (i < end) : (i += 1) {
        const row = readIndexRow(bytes, i);
        const blob_id = try blobHandleAtRowFromMeta(allocator, root_dir, meta, column_index, row);
        const value_ref = blobRefForId(refs, blob_id) orelse continue;
        if (!std.mem.eql(u8, value_ref.value, value)) continue;
        if (matched_row != null) return TableError.VerifyFailed;
        matched_row = row;
    }
    if (matched_row) |row| return .{ .found = true, .row_index = row };
    return .{ .found = false, .row_index = 0 };
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

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const found = try findUniqueU64KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try deleteRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index);
}

pub fn deleteI64Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: i64,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const found = try findUniqueI64KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try deleteRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index);
}

pub fn deleteU32Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: u32,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const found = try findUniqueU32KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try deleteRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index);
}

pub fn deleteI32Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: i32,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const found = try findUniqueI32KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try deleteRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index);
}

pub fn deleteU8Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const found = try findUniqueU8KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try deleteRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index);
}

pub fn deleteI8Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: i8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const found = try findUniqueI8KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try deleteRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index);
}

pub fn deleteU16Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: u16,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const found = try findUniqueU16KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try deleteRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index);
}

pub fn deleteI16Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: i16,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const found = try findUniqueI16KeyRow(allocator, root_dir, owned, column_index, expected);
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

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const found = try findUniqueU64PairKeyRow(allocator, root_dir, owned, column_index, column_index2, key1, key2);
    if (!found.found) return TableError.NotFound;
    return try deleteRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index);
}

pub fn deleteU64I64PairKey(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    column_index2: usize,
    key1: u64,
    key2: i64,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const found = try findUniqueU64I64PairKeyRow(allocator, root_dir, owned, column_index, column_index2, key1, key2);
    if (!found.found) return TableError.NotFound;
    return try deleteRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index);
}

pub fn deleteBlobEqKey(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    store_name: []const u8,
    value: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const found = try findUniqueBlobEqKeyRow(allocator, root_dir, owned, column_index, store_name, value);
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

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowU64KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueU64KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try replaceRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index, row_bytes);
}

pub fn updateRawRowI64Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: i64,
    row_bytes: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowI64KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueI64KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try replaceRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index, row_bytes);
}

pub fn updateRawRowU32Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: u32,
    row_bytes: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowU32KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueU32KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try replaceRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index, row_bytes);
}

pub fn updateRawRowI32Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: i32,
    row_bytes: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowI32KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueI32KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try replaceRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index, row_bytes);
}

pub fn updateRawRowU8Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: u8,
    row_bytes: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowU8KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueU8KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try replaceRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index, row_bytes);
}

pub fn updateRawRowI8Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: i8,
    row_bytes: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowI8KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueI8KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try replaceRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index, row_bytes);
}

pub fn updateRawRowU16Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: u16,
    row_bytes: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowU16KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueU16KeyRow(allocator, root_dir, owned, column_index, expected);
    if (!found.found) return TableError.NotFound;
    return try replaceRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index, row_bytes);
}

pub fn updateRawRowI16Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: i16,
    row_bytes: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowI16KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueI16KeyRow(allocator, root_dir, owned, column_index, expected);
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

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowU64PairKeyValue(owned, column_index, column_index2, row_bytes);
    if (key_value.key1 != key1 or key_value.key2 != key2) return TableError.InvalidFormat;

    const found = try findUniqueU64PairKeyRow(allocator, root_dir, owned, column_index, column_index2, key1, key2);
    if (!found.found) return TableError.NotFound;
    return try replaceRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index, row_bytes);
}

pub fn updateRawRowU64I64PairKey(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    column_index2: usize,
    key1: u64,
    key2: i64,
    row_bytes: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowU64I64PairKeyValue(owned, column_index, column_index2, row_bytes);
    if (key_value.key1 != key1 or key_value.key2 != key2) return TableError.InvalidFormat;

    const found = try findUniqueU64I64PairKeyRow(allocator, root_dir, owned, column_index, column_index2, key1, key2);
    if (!found.found) return TableError.NotFound;
    return try replaceRowAtIndex(allocator, root_dir, table_name, &owned, found.row_index, row_bytes);
}

pub fn updateRawRowBlobEqKey(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    store_name: []const u8,
    value: []const u8,
    row_bytes: []const u8,
) TableError!TableInfo {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    try ensureRowBlobEqKeyValue(allocator, root_dir, owned, column_index, store_name, value, row_bytes);

    const found = try findUniqueBlobEqKeyRow(allocator, root_dir, owned, column_index, store_name, value);
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

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
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

pub fn upsertRawRowI64Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: i64,
    row_bytes: []const u8,
) TableError!UpsertResult {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowI64KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueI64KeyRow(allocator, root_dir, owned, column_index, expected);
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

pub fn upsertRawRowU32Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: u32,
    row_bytes: []const u8,
) TableError!UpsertResult {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowU32KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueU32KeyRow(allocator, root_dir, owned, column_index, expected);
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

pub fn upsertRawRowI32Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: i32,
    row_bytes: []const u8,
) TableError!UpsertResult {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowI32KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueI32KeyRow(allocator, root_dir, owned, column_index, expected);
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

pub fn upsertRawRowU8Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: u8,
    row_bytes: []const u8,
) TableError!UpsertResult {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowU8KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueU8KeyRow(allocator, root_dir, owned, column_index, expected);
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

pub fn upsertRawRowI8Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: i8,
    row_bytes: []const u8,
) TableError!UpsertResult {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowI8KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueI8KeyRow(allocator, root_dir, owned, column_index, expected);
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

pub fn upsertRawRowU16Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: u16,
    row_bytes: []const u8,
) TableError!UpsertResult {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowU16KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueU16KeyRow(allocator, root_dir, owned, column_index, expected);
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

pub fn upsertRawRowI16Key(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    expected: i16,
    row_bytes: []const u8,
) TableError!UpsertResult {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowI16KeyValue(owned, column_index, row_bytes);
    if (key_value != expected) return TableError.InvalidFormat;

    const found = try findUniqueI16KeyRow(allocator, root_dir, owned, column_index, expected);
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

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
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

pub fn upsertRawRowU64I64PairKey(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    column_index2: usize,
    key1: u64,
    key2: i64,
    row_bytes: []const u8,
) TableError!UpsertResult {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    const key_value = try rowU64I64PairKeyValue(owned, column_index, column_index2, row_bytes);
    if (key_value.key1 != key1 or key_value.key2 != key2) return TableError.InvalidFormat;

    const found = try findUniqueU64I64PairKeyRow(allocator, root_dir, owned, column_index, column_index2, key1, key2);
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

pub fn upsertRawRowBlobEqKey(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    table_name: []const u8,
    column_index: usize,
    store_name: []const u8,
    value: []const u8,
    row_bytes: []const u8,
) TableError!UpsertResult {
    var write_lock = try acquireTableWriteLock(allocator, root_dir, table_name);
    defer write_lock.release();

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
    defer owned.deinit(allocator);
    if (owned.locked) return TableError.Locked;
    try ensureRowBlobEqKeyValue(allocator, root_dir, owned, column_index, store_name, value, row_bytes);

    const found = try findUniqueBlobEqKeyRow(allocator, root_dir, owned, column_index, store_name, value);
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

pub fn snapshotSumI64(snapshot: *const ReadSnapshot, column_index: usize) TableError!i64 {
    try ensureSnapshotI64Column(snapshot, column_index);
    var sum: i64 = 0;
    for (snapshot.segments) |segment| {
        const bytes = segment.columns[column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (bytes.len != expected_len) return TableError.VerifyFailed;
        var i: u64 = 0;
        while (i < segment.rows) : (i += 1) {
            const byte_offset: usize = @intCast(i * 8);
            sum = std.math.add(i64, sum, readI64LE(bytes, byte_offset)) catch return TableError.CursorOverflow;
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

fn addU64I64Group(
    groups: *std.ArrayList(U64I64GroupAccumulator),
    group_index: *std.AutoHashMap(u64, usize),
    key: u64,
    amount: i64,
) TableError!void {
    const entry = group_index.getOrPut(key) catch return TableError.OutOfMemory;
    if (!entry.found_existing) {
        entry.value_ptr.* = groups.items.len;
        groups.append(.{ .key = key, .count = 0, .sum = 0, .min = amount, .max = amount, .ordinal = @intCast(groups.items.len) }) catch return TableError.OutOfMemory;
    }
    const idx = entry.value_ptr.*;
    const group = &groups.items[idx];
    if (group.count == 0) {
        group.min = amount;
        group.max = amount;
    } else {
        group.min = @min(group.min, amount);
        group.max = @max(group.max, amount);
    }
    group.count = std.math.add(u64, group.count, 1) catch return TableError.CursorOverflow;
    group.sum = std.math.add(i64, group.sum, amount) catch return TableError.CursorOverflow;
}

fn copyU64I64GroupPage(
    groups: []const U64I64GroupAccumulator,
    offset: u64,
    limit: u64,
    out_keys: []u64,
    out_counts: []u64,
    out_sums: []i64,
) U64RangeResult {
    const out_capacity: u64 = @min(@as(u64, @intCast(out_keys.len)), @min(@as(u64, @intCast(out_counts.len)), @as(u64, @intCast(out_sums.len))));
    var written: u64 = 0;
    for (groups, 0..) |group, idx| {
        const total: u64 = @intCast(idx);
        if (total >= offset and limit != 0 and written < limit and written < out_capacity) {
            const out_idx: usize = @intCast(written);
            out_keys[out_idx] = group.key;
            out_counts[out_idx] = group.count;
            out_sums[out_idx] = group.sum;
            written += 1;
        }
    }
    return .{ .written = written, .total = @intCast(groups.len) };
}

const U64I64GroupSortContext = struct {
    sort_by: GroupSortBy,
    descending: bool,
};

fn compareU64I64GroupPrimary(context: U64I64GroupSortContext, lhs: U64I64GroupAccumulator, rhs: U64I64GroupAccumulator) std.math.Order {
    return switch (context.sort_by) {
        .key => std.math.order(lhs.key, rhs.key),
        .count => std.math.order(lhs.count, rhs.count),
        .sum => std.math.order(lhs.sum, rhs.sum),
        .min => std.math.order(lhs.min, rhs.min),
        .max => std.math.order(lhs.max, rhs.max),
    };
}

fn u64I64GroupLessThan(context: U64I64GroupSortContext, lhs: U64I64GroupAccumulator, rhs: U64I64GroupAccumulator) bool {
    const order = compareU64I64GroupPrimary(context, lhs, rhs);
    if (order != .eq) return if (context.descending) order == .gt else order == .lt;
    return lhs.ordinal < rhs.ordinal;
}

fn copySortedU64I64GroupPage(
    allocator: std.mem.Allocator,
    groups: []const U64I64GroupAccumulator,
    sort_by: GroupSortBy,
    descending: bool,
    offset: u64,
    limit: u64,
    out_keys: []u64,
    out_counts: []u64,
    out_sums: []i64,
) TableError!U64RangeResult {
    const sorted = allocator.dupe(U64I64GroupAccumulator, groups) catch return TableError.OutOfMemory;
    defer allocator.free(sorted);
    std.sort.block(U64I64GroupAccumulator, sorted, U64I64GroupSortContext{ .sort_by = sort_by, .descending = descending }, u64I64GroupLessThan);
    return copyU64I64GroupPage(sorted, offset, limit, out_keys, out_counts, out_sums);
}

fn copyU64I64GroupStatsPage(
    groups: []const U64I64GroupAccumulator,
    offset: u64,
    limit: u64,
    out_keys: []u64,
    out_counts: []u64,
    out_sums: []i64,
    out_mins: []i64,
    out_maxs: []i64,
) U64RangeResult {
    const out_capacity: u64 = @min(
        @as(u64, @intCast(out_keys.len)),
        @min(
            @as(u64, @intCast(out_counts.len)),
            @min(
                @as(u64, @intCast(out_sums.len)),
                @min(@as(u64, @intCast(out_mins.len)), @as(u64, @intCast(out_maxs.len))),
            ),
        ),
    );
    var written: u64 = 0;
    for (groups, 0..) |group, idx| {
        const total: u64 = @intCast(idx);
        if (total >= offset and limit != 0 and written < limit and written < out_capacity) {
            const out_idx: usize = @intCast(written);
            out_keys[out_idx] = group.key;
            out_counts[out_idx] = group.count;
            out_sums[out_idx] = group.sum;
            out_mins[out_idx] = group.min;
            out_maxs[out_idx] = group.max;
            written += 1;
        }
    }
    return .{ .written = written, .total = @intCast(groups.len) };
}

fn copySortedU64I64GroupStatsPage(
    allocator: std.mem.Allocator,
    groups: []const U64I64GroupAccumulator,
    sort_by: GroupSortBy,
    descending: bool,
    offset: u64,
    limit: u64,
    out_keys: []u64,
    out_counts: []u64,
    out_sums: []i64,
    out_mins: []i64,
    out_maxs: []i64,
) TableError!U64RangeResult {
    const sorted = allocator.dupe(U64I64GroupAccumulator, groups) catch return TableError.OutOfMemory;
    defer allocator.free(sorted);
    std.sort.block(U64I64GroupAccumulator, sorted, U64I64GroupSortContext{ .sort_by = sort_by, .descending = descending }, u64I64GroupLessThan);
    return copyU64I64GroupStatsPage(sorted, offset, limit, out_keys, out_counts, out_sums, out_mins, out_maxs);
}

fn buildU64I64GroupsFromSnapshot(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    group_column_index: usize,
    sum_column_index: usize,
) TableError!std.ArrayList(U64I64GroupAccumulator) {
    var groups = std.ArrayList(U64I64GroupAccumulator).init(allocator);
    errdefer groups.deinit();
    var group_index = std.AutoHashMap(u64, usize).init(allocator);
    defer group_index.deinit();

    for (snapshot.segments) |segment| {
        const group_bytes = segment.columns[group_column_index].bytes;
        const sum_bytes = segment.columns[sum_column_index].bytes;
        const expected_len = try expectedColumnBytes(segment.rows, 8);
        if (group_bytes.len != expected_len or sum_bytes.len != expected_len) return TableError.VerifyFailed;
        var local_row: u64 = 0;
        while (local_row < segment.rows) : (local_row += 1) {
            const byte_offset: usize = @intCast(local_row * 8);
            try addU64I64Group(&groups, &group_index, readU64LE(group_bytes, byte_offset), readI64LE(sum_bytes, byte_offset));
        }
    }
    return groups;
}

fn buildU64I64GroupsFromRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    group_column_index: usize,
    sum_column_index: usize,
    row_indices: []const u64,
) TableError!std.ArrayList(U64I64GroupAccumulator) {
    var groups = std.ArrayList(U64I64GroupAccumulator).init(allocator);
    errdefer groups.deinit();
    var group_index = std.AutoHashMap(u64, usize).init(allocator);
    defer group_index.deinit();

    for (row_indices) |row_index| {
        try addU64I64Group(
            &groups,
            &group_index,
            try snapshotU64AtRow(snapshot, group_column_index, row_index),
            try snapshotI64AtRow(snapshot, sum_column_index, row_index),
        );
    }
    return groups;
}

pub fn snapshotGroupSumI64ByU64(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    group_column_index: usize,
    sum_column_index: usize,
    offset: u64,
    limit: u64,
    out_keys: []u64,
    out_counts: []u64,
    out_sums: []i64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, group_column_index);
    try ensureSnapshotI64Column(snapshot, sum_column_index);

    var groups = try buildU64I64GroupsFromSnapshot(allocator, snapshot, group_column_index, sum_column_index);
    defer groups.deinit();
    return copyU64I64GroupPage(groups.items, offset, limit, out_keys, out_counts, out_sums);
}

pub fn snapshotGroupSumI64ByU64Sorted(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    group_column_index: usize,
    sum_column_index: usize,
    sort_by: GroupSortBy,
    descending: bool,
    offset: u64,
    limit: u64,
    out_keys: []u64,
    out_counts: []u64,
    out_sums: []i64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, group_column_index);
    try ensureSnapshotI64Column(snapshot, sum_column_index);

    var groups = try buildU64I64GroupsFromSnapshot(allocator, snapshot, group_column_index, sum_column_index);
    defer groups.deinit();
    return try copySortedU64I64GroupPage(allocator, groups.items, sort_by, descending, offset, limit, out_keys, out_counts, out_sums);
}

pub fn snapshotGroupRowsSumI64ByU64(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    group_column_index: usize,
    sum_column_index: usize,
    row_indices: []const u64,
    offset: u64,
    limit: u64,
    out_keys: []u64,
    out_counts: []u64,
    out_sums: []i64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, group_column_index);
    try ensureSnapshotI64Column(snapshot, sum_column_index);
    try validateSnapshotRows(snapshot, row_indices);

    var groups = try buildU64I64GroupsFromRows(allocator, snapshot, group_column_index, sum_column_index, row_indices);
    defer groups.deinit();
    return copyU64I64GroupPage(groups.items, offset, limit, out_keys, out_counts, out_sums);
}

pub fn snapshotGroupRowsSumI64ByU64Sorted(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    group_column_index: usize,
    sum_column_index: usize,
    row_indices: []const u64,
    sort_by: GroupSortBy,
    descending: bool,
    offset: u64,
    limit: u64,
    out_keys: []u64,
    out_counts: []u64,
    out_sums: []i64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, group_column_index);
    try ensureSnapshotI64Column(snapshot, sum_column_index);
    try validateSnapshotRows(snapshot, row_indices);

    var groups = try buildU64I64GroupsFromRows(allocator, snapshot, group_column_index, sum_column_index, row_indices);
    defer groups.deinit();
    return try copySortedU64I64GroupPage(allocator, groups.items, sort_by, descending, offset, limit, out_keys, out_counts, out_sums);
}

pub fn snapshotGroupStatsI64ByU64(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    group_column_index: usize,
    stats_column_index: usize,
    offset: u64,
    limit: u64,
    out_keys: []u64,
    out_counts: []u64,
    out_sums: []i64,
    out_mins: []i64,
    out_maxs: []i64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, group_column_index);
    try ensureSnapshotI64Column(snapshot, stats_column_index);

    var groups = try buildU64I64GroupsFromSnapshot(allocator, snapshot, group_column_index, stats_column_index);
    defer groups.deinit();
    return copyU64I64GroupStatsPage(groups.items, offset, limit, out_keys, out_counts, out_sums, out_mins, out_maxs);
}

pub fn snapshotGroupStatsI64ByU64Sorted(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    group_column_index: usize,
    stats_column_index: usize,
    sort_by: GroupSortBy,
    descending: bool,
    offset: u64,
    limit: u64,
    out_keys: []u64,
    out_counts: []u64,
    out_sums: []i64,
    out_mins: []i64,
    out_maxs: []i64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, group_column_index);
    try ensureSnapshotI64Column(snapshot, stats_column_index);

    var groups = try buildU64I64GroupsFromSnapshot(allocator, snapshot, group_column_index, stats_column_index);
    defer groups.deinit();
    return try copySortedU64I64GroupStatsPage(allocator, groups.items, sort_by, descending, offset, limit, out_keys, out_counts, out_sums, out_mins, out_maxs);
}

pub fn snapshotGroupRowsStatsI64ByU64(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    group_column_index: usize,
    stats_column_index: usize,
    row_indices: []const u64,
    offset: u64,
    limit: u64,
    out_keys: []u64,
    out_counts: []u64,
    out_sums: []i64,
    out_mins: []i64,
    out_maxs: []i64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, group_column_index);
    try ensureSnapshotI64Column(snapshot, stats_column_index);
    try validateSnapshotRows(snapshot, row_indices);

    var groups = try buildU64I64GroupsFromRows(allocator, snapshot, group_column_index, stats_column_index, row_indices);
    defer groups.deinit();
    return copyU64I64GroupStatsPage(groups.items, offset, limit, out_keys, out_counts, out_sums, out_mins, out_maxs);
}

pub fn snapshotGroupRowsStatsI64ByU64Sorted(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    group_column_index: usize,
    stats_column_index: usize,
    row_indices: []const u64,
    sort_by: GroupSortBy,
    descending: bool,
    offset: u64,
    limit: u64,
    out_keys: []u64,
    out_counts: []u64,
    out_sums: []i64,
    out_mins: []i64,
    out_maxs: []i64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, group_column_index);
    try ensureSnapshotI64Column(snapshot, stats_column_index);
    try validateSnapshotRows(snapshot, row_indices);

    var groups = try buildU64I64GroupsFromRows(allocator, snapshot, group_column_index, stats_column_index, row_indices);
    defer groups.deinit();
    return try copySortedU64I64GroupStatsPage(allocator, groups.items, sort_by, descending, offset, limit, out_keys, out_counts, out_sums, out_mins, out_maxs);
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

pub fn snapshotFilterDictEqRows(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    dict_name: []const u8,
    value: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, column_index);
    const lookup = try snapshotDictLookup(snapshot, dict_name, value);
    if (!lookup.found) return .{ .written = 0, .total = 0 };
    return try snapshotRangeU64Rows(snapshot, column_index, lookup.id, lookup.id, offset, limit, out_rows);
}

pub fn snapshotFilterRowsDictEq(
    snapshot: *const ReadSnapshot,
    column_index: usize,
    in_rows: []const u64,
    dict_name: []const u8,
    value: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    try ensureSnapshotU64Column(snapshot, column_index);
    const lookup = try snapshotDictLookup(snapshot, dict_name, value);
    if (!lookup.found) return .{ .written = 0, .total = 0 };
    return try snapshotFilterRowsU64Range(snapshot, column_index, in_rows, lookup.id, lookup.id, offset, limit, out_rows);
}

pub fn snapshotPlanU64I64RangeRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    i64_column_index: usize,
    i64_min_value: i64,
    i64_max_value: i64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!PlanRowsResult {
    var empty_rows: [0]u64 = .{};
    const u64_count = try snapshotRangeU64Rows(snapshot, u64_column_index, u64_min_value, u64_max_value, 0, 0, &empty_rows);
    const i64_count = try snapshotRangeI64Rows(snapshot, i64_column_index, i64_min_value, i64_max_value, 0, 0, &empty_rows);
    const u64_first = u64_count.total <= i64_count.total;
    const first_predicate: u64 = if (u64_first) 1 else 2;
    const first_total = if (u64_first) u64_count.total else i64_count.total;
    const second_total = if (u64_first) i64_count.total else u64_count.total;
    if (first_total == 0 or second_total == 0) {
        return .{ .written = 0, .total = 0, .first_predicate = first_predicate, .first_total = first_total, .second_total = second_total };
    }
    if (first_total > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const candidate_rows = try allocator.alloc(u64, @intCast(first_total));
    defer allocator.free(candidate_rows);

    const initial = if (u64_first)
        try snapshotRangeU64Rows(snapshot, u64_column_index, u64_min_value, u64_max_value, 0, first_total, candidate_rows)
    else
        try snapshotRangeI64Rows(snapshot, i64_column_index, i64_min_value, i64_max_value, 0, first_total, candidate_rows);
    if (initial.total != first_total or initial.written != first_total) return TableError.VerifyFailed;

    const filtered = if (u64_first)
        try snapshotFilterRowsI64Range(snapshot, i64_column_index, candidate_rows, i64_min_value, i64_max_value, offset, limit, out_rows)
    else
        try snapshotFilterRowsU64Range(snapshot, u64_column_index, candidate_rows, u64_min_value, u64_max_value, offset, limit, out_rows);
    return .{
        .written = filtered.written,
        .total = filtered.total,
        .first_predicate = first_predicate,
        .first_total = first_total,
        .second_total = second_total,
    };
}

pub fn snapshotPlanU64U64RangeRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    first_column_index: usize,
    first_min_value: u64,
    first_max_value: u64,
    second_column_index: usize,
    second_min_value: u64,
    second_max_value: u64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!PlanRowsResult {
    var empty_rows: [0]u64 = .{};
    const first_count = try snapshotRangeU64Rows(snapshot, first_column_index, first_min_value, first_max_value, 0, 0, &empty_rows);
    const second_count = try snapshotRangeU64Rows(snapshot, second_column_index, second_min_value, second_max_value, 0, 0, &empty_rows);
    const use_first_predicate = first_count.total <= second_count.total;
    const first_predicate: u64 = if (use_first_predicate) 1 else 2;
    const first_total = if (use_first_predicate) first_count.total else second_count.total;
    const second_total = if (use_first_predicate) second_count.total else first_count.total;
    if (first_total == 0 or second_total == 0) {
        return .{ .written = 0, .total = 0, .first_predicate = first_predicate, .first_total = first_total, .second_total = second_total };
    }
    if (first_total > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const candidate_rows = try allocator.alloc(u64, @intCast(first_total));
    defer allocator.free(candidate_rows);

    const initial = if (use_first_predicate)
        try snapshotRangeU64Rows(snapshot, first_column_index, first_min_value, first_max_value, 0, first_total, candidate_rows)
    else
        try snapshotRangeU64Rows(snapshot, second_column_index, second_min_value, second_max_value, 0, first_total, candidate_rows);
    if (initial.total != first_total or initial.written != first_total) return TableError.VerifyFailed;

    const filtered = if (use_first_predicate)
        try snapshotFilterRowsU64Range(snapshot, second_column_index, candidate_rows, second_min_value, second_max_value, offset, limit, out_rows)
    else
        try snapshotFilterRowsU64Range(snapshot, first_column_index, candidate_rows, first_min_value, first_max_value, offset, limit, out_rows);
    return .{
        .written = filtered.written,
        .total = filtered.total,
        .first_predicate = first_predicate,
        .first_total = first_total,
        .second_total = second_total,
    };
}

pub fn snapshotPlanI64I64RangeRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    first_column_index: usize,
    first_min_value: i64,
    first_max_value: i64,
    second_column_index: usize,
    second_min_value: i64,
    second_max_value: i64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!PlanRowsResult {
    var empty_rows: [0]u64 = .{};
    const first_count = try snapshotRangeI64Rows(snapshot, first_column_index, first_min_value, first_max_value, 0, 0, &empty_rows);
    const second_count = try snapshotRangeI64Rows(snapshot, second_column_index, second_min_value, second_max_value, 0, 0, &empty_rows);
    const use_first_predicate = first_count.total <= second_count.total;
    const first_predicate: u64 = if (use_first_predicate) 1 else 2;
    const first_total = if (use_first_predicate) first_count.total else second_count.total;
    const second_total = if (use_first_predicate) second_count.total else first_count.total;
    if (first_total == 0 or second_total == 0) {
        return .{ .written = 0, .total = 0, .first_predicate = first_predicate, .first_total = first_total, .second_total = second_total };
    }
    if (first_total > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const candidate_rows = try allocator.alloc(u64, @intCast(first_total));
    defer allocator.free(candidate_rows);

    const initial = if (use_first_predicate)
        try snapshotRangeI64Rows(snapshot, first_column_index, first_min_value, first_max_value, 0, first_total, candidate_rows)
    else
        try snapshotRangeI64Rows(snapshot, second_column_index, second_min_value, second_max_value, 0, first_total, candidate_rows);
    if (initial.total != first_total or initial.written != first_total) return TableError.VerifyFailed;

    const filtered = if (use_first_predicate)
        try snapshotFilterRowsI64Range(snapshot, second_column_index, candidate_rows, second_min_value, second_max_value, offset, limit, out_rows)
    else
        try snapshotFilterRowsI64Range(snapshot, first_column_index, candidate_rows, first_min_value, first_max_value, offset, limit, out_rows);
    return .{
        .written = filtered.written,
        .total = filtered.total,
        .first_predicate = first_predicate,
        .first_total = first_total,
        .second_total = second_total,
    };
}

pub fn snapshotPlanU64BlobEqRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    blob_column_index: usize,
    store_name: []const u8,
    needle: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!PlanRowsResult {
    var empty_rows: [0]u64 = .{};
    const range_count = try snapshotRangeU64Rows(snapshot, u64_column_index, u64_min_value, u64_max_value, 0, 0, &empty_rows);
    const blob_count = try snapshotFilterBlobEqRows(allocator, snapshot, blob_column_index, store_name, needle, 0, 0, &empty_rows);
    const range_first = range_count.total <= blob_count.total;
    const first_predicate: u64 = if (range_first) 1 else 2;
    const first_total = if (range_first) range_count.total else blob_count.total;
    const second_total = if (range_first) blob_count.total else range_count.total;
    if (first_total == 0 or second_total == 0) {
        return .{ .written = 0, .total = 0, .first_predicate = first_predicate, .first_total = first_total, .second_total = second_total };
    }
    if (first_total > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const candidate_rows = try allocator.alloc(u64, @intCast(first_total));
    defer allocator.free(candidate_rows);

    if (range_first) {
        const initial = try snapshotRangeU64Rows(snapshot, u64_column_index, u64_min_value, u64_max_value, 0, first_total, candidate_rows);
        if (initial.total != first_total or initial.written != first_total) return TableError.VerifyFailed;
    } else {
        const initial = try snapshotFilterBlobEqRows(allocator, snapshot, blob_column_index, store_name, needle, 0, first_total, candidate_rows);
        if (initial.total != first_total or initial.written != first_total) return TableError.VerifyFailed;
    }

    var filtered_written: u64 = 0;
    var filtered_total: u64 = 0;
    if (range_first) {
        const filtered = try snapshotFilterRowsBlobEq(allocator, snapshot, blob_column_index, candidate_rows, store_name, needle, offset, limit, out_rows);
        filtered_written = filtered.written;
        filtered_total = filtered.total;
    } else {
        const filtered = try snapshotFilterRowsU64Range(snapshot, u64_column_index, candidate_rows, u64_min_value, u64_max_value, offset, limit, out_rows);
        filtered_written = filtered.written;
        filtered_total = filtered.total;
    }
    return .{
        .written = filtered_written,
        .total = filtered_total,
        .first_predicate = first_predicate,
        .first_total = first_total,
        .second_total = second_total,
    };
}

pub fn snapshotPlanU64DictEqRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    dict_column_index: usize,
    dict_name: []const u8,
    value: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!PlanRowsResult {
    try ensureSnapshotU64Column(snapshot, dict_column_index);
    const lookup = try snapshotDictLookup(snapshot, dict_name, value);
    var empty_rows: [0]u64 = .{};
    const range_count = try snapshotRangeU64Rows(snapshot, u64_column_index, u64_min_value, u64_max_value, 0, 0, &empty_rows);
    const dict_total = if (lookup.found)
        (try snapshotCountU64Cmp(snapshot, dict_column_index, .eq, lookup.id))
    else
        0;
    const range_first = range_count.total <= dict_total;
    const first_predicate: u64 = if (range_first) 1 else 2;
    const first_total = if (range_first) range_count.total else dict_total;
    const second_total = if (range_first) dict_total else range_count.total;
    if (first_total == 0 or second_total == 0) {
        return .{ .written = 0, .total = 0, .first_predicate = first_predicate, .first_total = first_total, .second_total = second_total };
    }
    if (first_total > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const candidate_rows = try allocator.alloc(u64, @intCast(first_total));
    defer allocator.free(candidate_rows);

    if (range_first) {
        const initial = try snapshotRangeU64Rows(snapshot, u64_column_index, u64_min_value, u64_max_value, 0, first_total, candidate_rows);
        if (initial.total != first_total or initial.written != first_total) return TableError.VerifyFailed;
        const filtered = try snapshotFilterRowsU64Range(snapshot, dict_column_index, candidate_rows, lookup.id, lookup.id, offset, limit, out_rows);
        return .{ .written = filtered.written, .total = filtered.total, .first_predicate = first_predicate, .first_total = first_total, .second_total = second_total };
    }

    const initial = try snapshotRangeU64Rows(snapshot, dict_column_index, lookup.id, lookup.id, 0, first_total, candidate_rows);
    if (initial.total != first_total or initial.written != first_total) return TableError.VerifyFailed;
    const filtered = try snapshotFilterRowsU64Range(snapshot, u64_column_index, candidate_rows, u64_min_value, u64_max_value, offset, limit, out_rows);
    return .{ .written = filtered.written, .total = filtered.total, .first_predicate = first_predicate, .first_total = first_total, .second_total = second_total };
}

pub fn snapshotPlanI64DictEqRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    i64_column_index: usize,
    i64_min_value: i64,
    i64_max_value: i64,
    dict_column_index: usize,
    dict_name: []const u8,
    value: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!PlanRowsResult {
    try ensureSnapshotU64Column(snapshot, dict_column_index);
    const lookup = try snapshotDictLookup(snapshot, dict_name, value);
    var empty_rows: [0]u64 = .{};
    const range_count = try snapshotRangeI64Rows(snapshot, i64_column_index, i64_min_value, i64_max_value, 0, 0, &empty_rows);
    const dict_total = if (lookup.found)
        (try snapshotCountU64Cmp(snapshot, dict_column_index, .eq, lookup.id))
    else
        0;
    const range_first = range_count.total <= dict_total;
    const first_predicate: u64 = if (range_first) 1 else 2;
    const first_total = if (range_first) range_count.total else dict_total;
    const second_total = if (range_first) dict_total else range_count.total;
    if (first_total == 0 or second_total == 0) {
        return .{ .written = 0, .total = 0, .first_predicate = first_predicate, .first_total = first_total, .second_total = second_total };
    }
    if (first_total > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const candidate_rows = try allocator.alloc(u64, @intCast(first_total));
    defer allocator.free(candidate_rows);

    if (range_first) {
        const initial = try snapshotRangeI64Rows(snapshot, i64_column_index, i64_min_value, i64_max_value, 0, first_total, candidate_rows);
        if (initial.total != first_total or initial.written != first_total) return TableError.VerifyFailed;
        const filtered = try snapshotFilterRowsU64Range(snapshot, dict_column_index, candidate_rows, lookup.id, lookup.id, offset, limit, out_rows);
        return .{ .written = filtered.written, .total = filtered.total, .first_predicate = first_predicate, .first_total = first_total, .second_total = second_total };
    }

    const initial = try snapshotRangeU64Rows(snapshot, dict_column_index, lookup.id, lookup.id, 0, first_total, candidate_rows);
    if (initial.total != first_total or initial.written != first_total) return TableError.VerifyFailed;
    const filtered = try snapshotFilterRowsI64Range(snapshot, i64_column_index, candidate_rows, i64_min_value, i64_max_value, offset, limit, out_rows);
    return .{ .written = filtered.written, .total = filtered.total, .first_predicate = first_predicate, .first_total = first_total, .second_total = second_total };
}

fn snapshotPlanU64I64DictMaterialize(
    snapshot: *const ReadSnapshot,
    predicate: u64,
    expected_total: u64,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    i64_column_index: usize,
    i64_min_value: i64,
    i64_max_value: i64,
    dict_column_index: usize,
    dict_id: u64,
    out_rows: []u64,
) TableError!void {
    switch (predicate) {
        1 => {
            const result = try snapshotRangeU64Rows(snapshot, u64_column_index, u64_min_value, u64_max_value, 0, expected_total, out_rows);
            if (result.total != expected_total or result.written != expected_total) return TableError.VerifyFailed;
        },
        2 => {
            const result = try snapshotRangeI64Rows(snapshot, i64_column_index, i64_min_value, i64_max_value, 0, expected_total, out_rows);
            if (result.total != expected_total or result.written != expected_total) return TableError.VerifyFailed;
        },
        3 => {
            const result = try snapshotRangeU64Rows(snapshot, dict_column_index, dict_id, dict_id, 0, expected_total, out_rows);
            if (result.total != expected_total or result.written != expected_total) return TableError.VerifyFailed;
        },
        else => return TableError.VerifyFailed,
    }
}

fn snapshotPlanU64I64DictFilter(
    snapshot: *const ReadSnapshot,
    predicate: u64,
    in_rows: []const u64,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    i64_column_index: usize,
    i64_min_value: i64,
    i64_max_value: i64,
    dict_column_index: usize,
    dict_id: u64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    return switch (predicate) {
        1 => try snapshotFilterRowsU64Range(snapshot, u64_column_index, in_rows, u64_min_value, u64_max_value, offset, limit, out_rows),
        2 => try snapshotFilterRowsI64Range(snapshot, i64_column_index, in_rows, i64_min_value, i64_max_value, offset, limit, out_rows),
        3 => try snapshotFilterRowsU64Range(snapshot, dict_column_index, in_rows, dict_id, dict_id, offset, limit, out_rows),
        else => TableError.VerifyFailed,
    };
}

pub fn snapshotPlanU64I64DictEqRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    i64_column_index: usize,
    i64_min_value: i64,
    i64_max_value: i64,
    dict_column_index: usize,
    dict_name: []const u8,
    value: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!Plan3RowsResult {
    try ensureSnapshotU64Column(snapshot, dict_column_index);
    const lookup = try snapshotDictLookup(snapshot, dict_name, value);
    var empty_rows: [0]u64 = .{};
    const u64_count = try snapshotRangeU64Rows(snapshot, u64_column_index, u64_min_value, u64_max_value, 0, 0, &empty_rows);
    const i64_count = try snapshotRangeI64Rows(snapshot, i64_column_index, i64_min_value, i64_max_value, 0, 0, &empty_rows);
    const dict_total = if (lookup.found)
        (try snapshotCountU64Cmp(snapshot, dict_column_index, .eq, lookup.id))
    else
        0;
    const predicates = sortedPlan3Predicates(u64_count.total, i64_count.total, dict_total);
    if (predicates[0].total == 0 or predicates[1].total == 0 or predicates[2].total == 0) {
        return .{
            .written = 0,
            .total = 0,
            .first_predicate = predicates[0].predicate,
            .first_total = predicates[0].total,
            .second_predicate = predicates[1].predicate,
            .second_total = predicates[1].total,
            .third_predicate = predicates[2].predicate,
            .third_total = predicates[2].total,
        };
    }
    if (predicates[0].total > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const first_rows = try allocator.alloc(u64, @intCast(predicates[0].total));
    defer allocator.free(first_rows);
    try snapshotPlanU64I64DictMaterialize(snapshot, predicates[0].predicate, predicates[0].total, u64_column_index, u64_min_value, u64_max_value, i64_column_index, i64_min_value, i64_max_value, dict_column_index, lookup.id, first_rows);

    const second_rows = try allocator.alloc(u64, @intCast(predicates[0].total));
    defer allocator.free(second_rows);
    const second_result = try snapshotPlanU64I64DictFilter(snapshot, predicates[1].predicate, first_rows, u64_column_index, u64_min_value, u64_max_value, i64_column_index, i64_min_value, i64_max_value, dict_column_index, lookup.id, 0, predicates[0].total, second_rows);
    if (second_result.written != second_result.total) return TableError.VerifyFailed;
    if (second_result.written > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const second_len: usize = @intCast(second_result.written);
    const final_result = try snapshotPlanU64I64DictFilter(snapshot, predicates[2].predicate, second_rows[0..second_len], u64_column_index, u64_min_value, u64_max_value, i64_column_index, i64_min_value, i64_max_value, dict_column_index, lookup.id, offset, limit, out_rows);
    return .{
        .written = final_result.written,
        .total = final_result.total,
        .first_predicate = predicates[0].predicate,
        .first_total = predicates[0].total,
        .second_predicate = predicates[1].predicate,
        .second_total = predicates[1].total,
        .third_predicate = predicates[2].predicate,
        .third_total = predicates[2].total,
    };
}

pub fn snapshotPlanI64BlobEqRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    i64_column_index: usize,
    i64_min_value: i64,
    i64_max_value: i64,
    blob_column_index: usize,
    store_name: []const u8,
    needle: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!PlanRowsResult {
    var empty_rows: [0]u64 = .{};
    const range_count = try snapshotRangeI64Rows(snapshot, i64_column_index, i64_min_value, i64_max_value, 0, 0, &empty_rows);
    const blob_count = try snapshotFilterBlobEqRows(allocator, snapshot, blob_column_index, store_name, needle, 0, 0, &empty_rows);
    const range_first = range_count.total <= blob_count.total;
    const first_predicate: u64 = if (range_first) 1 else 2;
    const first_total = if (range_first) range_count.total else blob_count.total;
    const second_total = if (range_first) blob_count.total else range_count.total;
    if (first_total == 0 or second_total == 0) {
        return .{ .written = 0, .total = 0, .first_predicate = first_predicate, .first_total = first_total, .second_total = second_total };
    }
    if (first_total > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const candidate_rows = try allocator.alloc(u64, @intCast(first_total));
    defer allocator.free(candidate_rows);

    if (range_first) {
        const initial = try snapshotRangeI64Rows(snapshot, i64_column_index, i64_min_value, i64_max_value, 0, first_total, candidate_rows);
        if (initial.total != first_total or initial.written != first_total) return TableError.VerifyFailed;
    } else {
        const initial = try snapshotFilterBlobEqRows(allocator, snapshot, blob_column_index, store_name, needle, 0, first_total, candidate_rows);
        if (initial.total != first_total or initial.written != first_total) return TableError.VerifyFailed;
    }

    var filtered_written: u64 = 0;
    var filtered_total: u64 = 0;
    if (range_first) {
        const filtered = try snapshotFilterRowsBlobEq(allocator, snapshot, blob_column_index, candidate_rows, store_name, needle, offset, limit, out_rows);
        filtered_written = filtered.written;
        filtered_total = filtered.total;
    } else {
        const filtered = try snapshotFilterRowsI64Range(snapshot, i64_column_index, candidate_rows, i64_min_value, i64_max_value, offset, limit, out_rows);
        filtered_written = filtered.written;
        filtered_total = filtered.total;
    }
    return .{
        .written = filtered_written,
        .total = filtered_total,
        .first_predicate = first_predicate,
        .first_total = first_total,
        .second_total = second_total,
    };
}

const Plan3PredicateEstimate = struct {
    predicate: u64,
    total: u64,
};

fn plan3PredicateLess(left: Plan3PredicateEstimate, right: Plan3PredicateEstimate) bool {
    if (left.total != right.total) return left.total < right.total;
    return left.predicate < right.predicate;
}

fn sortedPlan3Predicates(u64_total: u64, i64_total: u64, third_total: u64) [3]Plan3PredicateEstimate {
    var predicates = [_]Plan3PredicateEstimate{
        .{ .predicate = 1, .total = u64_total },
        .{ .predicate = 2, .total = i64_total },
        .{ .predicate = 3, .total = third_total },
    };
    var i: usize = 1;
    while (i < predicates.len) : (i += 1) {
        var j = i;
        while (j > 0 and plan3PredicateLess(predicates[j], predicates[j - 1])) : (j -= 1) {
            std.mem.swap(Plan3PredicateEstimate, &predicates[j], &predicates[j - 1]);
        }
    }
    return predicates;
}

fn snapshotPlanU64I64BlobEqMaterialize(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    predicate: u64,
    expected_total: u64,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    i64_column_index: usize,
    i64_min_value: i64,
    i64_max_value: i64,
    blob_column_index: usize,
    store_name: []const u8,
    needle: []const u8,
    out_rows: []u64,
) TableError!void {
    switch (predicate) {
        1 => {
            const result = try snapshotRangeU64Rows(snapshot, u64_column_index, u64_min_value, u64_max_value, 0, expected_total, out_rows);
            if (result.total != expected_total or result.written != expected_total) return TableError.VerifyFailed;
        },
        2 => {
            const result = try snapshotRangeI64Rows(snapshot, i64_column_index, i64_min_value, i64_max_value, 0, expected_total, out_rows);
            if (result.total != expected_total or result.written != expected_total) return TableError.VerifyFailed;
        },
        3 => {
            const result = try snapshotFilterBlobEqRows(allocator, snapshot, blob_column_index, store_name, needle, 0, expected_total, out_rows);
            if (result.total != expected_total or result.written != expected_total) return TableError.VerifyFailed;
        },
        else => return TableError.VerifyFailed,
    }
}

fn snapshotPlanU64I64BlobEqFilter(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    predicate: u64,
    in_rows: []const u64,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    i64_column_index: usize,
    i64_min_value: i64,
    i64_max_value: i64,
    blob_column_index: usize,
    store_name: []const u8,
    needle: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    return switch (predicate) {
        1 => try snapshotFilterRowsU64Range(snapshot, u64_column_index, in_rows, u64_min_value, u64_max_value, offset, limit, out_rows),
        2 => try snapshotFilterRowsI64Range(snapshot, i64_column_index, in_rows, i64_min_value, i64_max_value, offset, limit, out_rows),
        3 => blk: {
            const result = try snapshotFilterRowsBlobEq(allocator, snapshot, blob_column_index, in_rows, store_name, needle, offset, limit, out_rows);
            break :blk .{ .written = result.written, .total = result.total };
        },
        else => TableError.VerifyFailed,
    };
}

pub fn snapshotPlanU64I64BlobEqRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    i64_column_index: usize,
    i64_min_value: i64,
    i64_max_value: i64,
    blob_column_index: usize,
    store_name: []const u8,
    needle: []const u8,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!Plan3RowsResult {
    var empty_rows: [0]u64 = .{};
    const u64_count = try snapshotRangeU64Rows(snapshot, u64_column_index, u64_min_value, u64_max_value, 0, 0, &empty_rows);
    const i64_count = try snapshotRangeI64Rows(snapshot, i64_column_index, i64_min_value, i64_max_value, 0, 0, &empty_rows);
    const blob_count = try snapshotFilterBlobEqRows(allocator, snapshot, blob_column_index, store_name, needle, 0, 0, &empty_rows);
    const predicates = sortedPlan3Predicates(u64_count.total, i64_count.total, blob_count.total);
    if (predicates[0].total == 0 or predicates[1].total == 0 or predicates[2].total == 0) {
        return .{
            .written = 0,
            .total = 0,
            .first_predicate = predicates[0].predicate,
            .first_total = predicates[0].total,
            .second_predicate = predicates[1].predicate,
            .second_total = predicates[1].total,
            .third_predicate = predicates[2].predicate,
            .third_total = predicates[2].total,
        };
    }
    if (predicates[0].total > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const first_rows = try allocator.alloc(u64, @intCast(predicates[0].total));
    defer allocator.free(first_rows);
    try snapshotPlanU64I64BlobEqMaterialize(
        allocator,
        snapshot,
        predicates[0].predicate,
        predicates[0].total,
        u64_column_index,
        u64_min_value,
        u64_max_value,
        i64_column_index,
        i64_min_value,
        i64_max_value,
        blob_column_index,
        store_name,
        needle,
        first_rows,
    );

    const second_rows = try allocator.alloc(u64, @intCast(predicates[0].total));
    defer allocator.free(second_rows);
    const second_result = try snapshotPlanU64I64BlobEqFilter(
        allocator,
        snapshot,
        predicates[1].predicate,
        first_rows,
        u64_column_index,
        u64_min_value,
        u64_max_value,
        i64_column_index,
        i64_min_value,
        i64_max_value,
        blob_column_index,
        store_name,
        needle,
        0,
        predicates[0].total,
        second_rows,
    );
    if (second_result.written != second_result.total) return TableError.VerifyFailed;
    if (second_result.written > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const second_len: usize = @intCast(second_result.written);
    const final_result = try snapshotPlanU64I64BlobEqFilter(
        allocator,
        snapshot,
        predicates[2].predicate,
        second_rows[0..second_len],
        u64_column_index,
        u64_min_value,
        u64_max_value,
        i64_column_index,
        i64_min_value,
        i64_max_value,
        blob_column_index,
        store_name,
        needle,
        offset,
        limit,
        out_rows,
    );
    return .{
        .written = final_result.written,
        .total = final_result.total,
        .first_predicate = predicates[0].predicate,
        .first_total = predicates[0].total,
        .second_predicate = predicates[1].predicate,
        .second_total = predicates[1].total,
        .third_predicate = predicates[2].predicate,
        .third_total = predicates[2].total,
    };
}

fn snapshotPlanU64I64BoolMaterialize(
    snapshot: *const ReadSnapshot,
    predicate: u64,
    expected_total: u64,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    i64_column_index: usize,
    i64_min_value: i64,
    i64_max_value: i64,
    bool_column_index: usize,
    expected_bool: bool,
    out_rows: []u64,
) TableError!void {
    switch (predicate) {
        1 => {
            const result = try snapshotRangeU64Rows(snapshot, u64_column_index, u64_min_value, u64_max_value, 0, expected_total, out_rows);
            if (result.total != expected_total or result.written != expected_total) return TableError.VerifyFailed;
        },
        2 => {
            const result = try snapshotRangeI64Rows(snapshot, i64_column_index, i64_min_value, i64_max_value, 0, expected_total, out_rows);
            if (result.total != expected_total or result.written != expected_total) return TableError.VerifyFailed;
        },
        3 => {
            const result = try snapshotFilterBoolRows(snapshot, bool_column_index, expected_bool, 0, expected_total, out_rows);
            if (result.total != expected_total or result.written != expected_total) return TableError.VerifyFailed;
        },
        else => return TableError.VerifyFailed,
    }
}

fn snapshotPlanU64I64BoolFilter(
    snapshot: *const ReadSnapshot,
    predicate: u64,
    in_rows: []const u64,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    i64_column_index: usize,
    i64_min_value: i64,
    i64_max_value: i64,
    bool_column_index: usize,
    expected_bool: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    return switch (predicate) {
        1 => try snapshotFilterRowsU64Range(snapshot, u64_column_index, in_rows, u64_min_value, u64_max_value, offset, limit, out_rows),
        2 => try snapshotFilterRowsI64Range(snapshot, i64_column_index, in_rows, i64_min_value, i64_max_value, offset, limit, out_rows),
        3 => try snapshotFilterRowsBool(snapshot, bool_column_index, in_rows, expected_bool, offset, limit, out_rows),
        else => TableError.VerifyFailed,
    };
}

pub fn snapshotPlanU64I64BoolRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    i64_column_index: usize,
    i64_min_value: i64,
    i64_max_value: i64,
    bool_column_index: usize,
    expected_bool: bool,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!Plan3RowsResult {
    var empty_rows: [0]u64 = .{};
    const u64_count = try snapshotRangeU64Rows(snapshot, u64_column_index, u64_min_value, u64_max_value, 0, 0, &empty_rows);
    const i64_count = try snapshotRangeI64Rows(snapshot, i64_column_index, i64_min_value, i64_max_value, 0, 0, &empty_rows);
    const bool_count = try snapshotFilterBoolRows(snapshot, bool_column_index, expected_bool, 0, 0, &empty_rows);
    const predicates = sortedPlan3Predicates(u64_count.total, i64_count.total, bool_count.total);
    if (predicates[0].total == 0 or predicates[1].total == 0 or predicates[2].total == 0) {
        return .{
            .written = 0,
            .total = 0,
            .first_predicate = predicates[0].predicate,
            .first_total = predicates[0].total,
            .second_predicate = predicates[1].predicate,
            .second_total = predicates[1].total,
            .third_predicate = predicates[2].predicate,
            .third_total = predicates[2].total,
        };
    }
    if (predicates[0].total > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const first_rows = try allocator.alloc(u64, @intCast(predicates[0].total));
    defer allocator.free(first_rows);
    try snapshotPlanU64I64BoolMaterialize(
        snapshot,
        predicates[0].predicate,
        predicates[0].total,
        u64_column_index,
        u64_min_value,
        u64_max_value,
        i64_column_index,
        i64_min_value,
        i64_max_value,
        bool_column_index,
        expected_bool,
        first_rows,
    );

    const second_rows = try allocator.alloc(u64, @intCast(predicates[0].total));
    defer allocator.free(second_rows);
    const second_result = try snapshotPlanU64I64BoolFilter(
        snapshot,
        predicates[1].predicate,
        first_rows,
        u64_column_index,
        u64_min_value,
        u64_max_value,
        i64_column_index,
        i64_min_value,
        i64_max_value,
        bool_column_index,
        expected_bool,
        0,
        predicates[0].total,
        second_rows,
    );
    if (second_result.written != second_result.total) return TableError.VerifyFailed;
    if (second_result.written > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const second_len: usize = @intCast(second_result.written);
    const final_result = try snapshotPlanU64I64BoolFilter(
        snapshot,
        predicates[2].predicate,
        second_rows[0..second_len],
        u64_column_index,
        u64_min_value,
        u64_max_value,
        i64_column_index,
        i64_min_value,
        i64_max_value,
        bool_column_index,
        expected_bool,
        offset,
        limit,
        out_rows,
    );
    return .{
        .written = final_result.written,
        .total = final_result.total,
        .first_predicate = predicates[0].predicate,
        .first_total = predicates[0].total,
        .second_predicate = predicates[1].predicate,
        .second_total = predicates[1].total,
        .third_predicate = predicates[2].predicate,
        .third_total = predicates[2].total,
    };
}

fn snapshotPlanU64I64I64Materialize(
    snapshot: *const ReadSnapshot,
    predicate: u64,
    expected_total: u64,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    first_i64_column_index: usize,
    first_i64_min_value: i64,
    first_i64_max_value: i64,
    second_i64_column_index: usize,
    second_i64_min_value: i64,
    second_i64_max_value: i64,
    out_rows: []u64,
) TableError!void {
    switch (predicate) {
        1 => {
            const result = try snapshotRangeU64Rows(snapshot, u64_column_index, u64_min_value, u64_max_value, 0, expected_total, out_rows);
            if (result.total != expected_total or result.written != expected_total) return TableError.VerifyFailed;
        },
        2 => {
            const result = try snapshotRangeI64Rows(snapshot, first_i64_column_index, first_i64_min_value, first_i64_max_value, 0, expected_total, out_rows);
            if (result.total != expected_total or result.written != expected_total) return TableError.VerifyFailed;
        },
        3 => {
            const result = try snapshotRangeI64Rows(snapshot, second_i64_column_index, second_i64_min_value, second_i64_max_value, 0, expected_total, out_rows);
            if (result.total != expected_total or result.written != expected_total) return TableError.VerifyFailed;
        },
        else => return TableError.VerifyFailed,
    }
}

fn snapshotPlanU64I64I64Filter(
    snapshot: *const ReadSnapshot,
    predicate: u64,
    in_rows: []const u64,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    first_i64_column_index: usize,
    first_i64_min_value: i64,
    first_i64_max_value: i64,
    second_i64_column_index: usize,
    second_i64_min_value: i64,
    second_i64_max_value: i64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!U64RangeResult {
    return switch (predicate) {
        1 => try snapshotFilterRowsU64Range(snapshot, u64_column_index, in_rows, u64_min_value, u64_max_value, offset, limit, out_rows),
        2 => try snapshotFilterRowsI64Range(snapshot, first_i64_column_index, in_rows, first_i64_min_value, first_i64_max_value, offset, limit, out_rows),
        3 => try snapshotFilterRowsI64Range(snapshot, second_i64_column_index, in_rows, second_i64_min_value, second_i64_max_value, offset, limit, out_rows),
        else => TableError.VerifyFailed,
    };
}

pub fn snapshotPlanU64I64I64RangeRows(
    allocator: std.mem.Allocator,
    snapshot: *const ReadSnapshot,
    u64_column_index: usize,
    u64_min_value: u64,
    u64_max_value: u64,
    first_i64_column_index: usize,
    first_i64_min_value: i64,
    first_i64_max_value: i64,
    second_i64_column_index: usize,
    second_i64_min_value: i64,
    second_i64_max_value: i64,
    offset: u64,
    limit: u64,
    out_rows: []u64,
) TableError!Plan3RowsResult {
    var empty_rows: [0]u64 = .{};
    const u64_count = try snapshotRangeU64Rows(snapshot, u64_column_index, u64_min_value, u64_max_value, 0, 0, &empty_rows);
    const first_i64_count = try snapshotRangeI64Rows(snapshot, first_i64_column_index, first_i64_min_value, first_i64_max_value, 0, 0, &empty_rows);
    const second_i64_count = try snapshotRangeI64Rows(snapshot, second_i64_column_index, second_i64_min_value, second_i64_max_value, 0, 0, &empty_rows);
    const predicates = sortedPlan3Predicates(u64_count.total, first_i64_count.total, second_i64_count.total);
    if (predicates[0].total == 0 or predicates[1].total == 0 or predicates[2].total == 0) {
        return .{
            .written = 0,
            .total = 0,
            .first_predicate = predicates[0].predicate,
            .first_total = predicates[0].total,
            .second_predicate = predicates[1].predicate,
            .second_total = predicates[1].total,
            .third_predicate = predicates[2].predicate,
            .third_total = predicates[2].total,
        };
    }
    if (predicates[0].total > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const first_rows = try allocator.alloc(u64, @intCast(predicates[0].total));
    defer allocator.free(first_rows);
    try snapshotPlanU64I64I64Materialize(
        snapshot,
        predicates[0].predicate,
        predicates[0].total,
        u64_column_index,
        u64_min_value,
        u64_max_value,
        first_i64_column_index,
        first_i64_min_value,
        first_i64_max_value,
        second_i64_column_index,
        second_i64_min_value,
        second_i64_max_value,
        first_rows,
    );

    const second_rows = try allocator.alloc(u64, @intCast(predicates[0].total));
    defer allocator.free(second_rows);
    const second_result = try snapshotPlanU64I64I64Filter(
        snapshot,
        predicates[1].predicate,
        first_rows,
        u64_column_index,
        u64_min_value,
        u64_max_value,
        first_i64_column_index,
        first_i64_min_value,
        first_i64_max_value,
        second_i64_column_index,
        second_i64_min_value,
        second_i64_max_value,
        0,
        predicates[0].total,
        second_rows,
    );
    if (second_result.written != second_result.total) return TableError.VerifyFailed;
    if (second_result.written > @as(u64, @intCast(std.math.maxInt(usize)))) return TableError.CursorOverflow;

    const second_len: usize = @intCast(second_result.written);
    const final_result = try snapshotPlanU64I64I64Filter(
        snapshot,
        predicates[2].predicate,
        second_rows[0..second_len],
        u64_column_index,
        u64_min_value,
        u64_max_value,
        first_i64_column_index,
        first_i64_min_value,
        first_i64_max_value,
        second_i64_column_index,
        second_i64_min_value,
        second_i64_max_value,
        offset,
        limit,
        out_rows,
    );
    return .{
        .written = final_result.written,
        .total = final_result.total,
        .first_predicate = predicates[0].predicate,
        .first_total = predicates[0].total,
        .second_predicate = predicates[1].predicate,
        .second_total = predicates[1].total,
        .third_predicate = predicates[2].predicate,
        .third_total = predicates[2].total,
    };
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

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
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

    var meta = try loadWritableMeta(allocator, root_dir, table_name);
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

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
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

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
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

    var owned = try loadWritableMeta(allocator, root_dir, table_name);
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

    const source = try readActiveMetaSource(std.testing.allocator, ".", table_name);
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

test "table unique blob eq key copies full rows" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "blob_key_rows";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "blob_key_rows.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_CODE_STRIDE = 8 // blob_handle
        \\#def COL_POINTS_STRIDE = 8 // u64
    );

    const code_a = try putBlobValue(std.testing.allocator, ".", table_name, "codes", "CUST-001");
    const code_b = try putBlobValue(std.testing.allocator, ".", table_name, "codes", "CUST-002");
    var row_bytes: [24]u8 = undefined;
    writeU64LE(&row_bytes, 0, 1);
    writeU64LE(&row_bytes, 8, code_a.id);
    writeU64LE(&row_bytes, 16, 100);
    _ = try insertRawRow(std.testing.allocator, ".", table_name, &row_bytes);
    writeU64LE(&row_bytes, 0, 2);
    writeU64LE(&row_bytes, 8, code_b.id);
    writeU64LE(&row_bytes, 16, 200);
    _ = try insertRawRow(std.testing.allocator, ".", table_name, &row_bytes);
    _ = try createBlobEqIndex(std.testing.allocator, ".", table_name, 1, "codes", true);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        var fetched_row: [24]u8 = undefined;
        try snapshotGetRowBlobEqKey(std.testing.allocator, snapshot, 1, "codes", "CUST-002", &fetched_row);
        try std.testing.expectEqual(@as(u64, 2), readU64LE(&fetched_row, 0));
        try std.testing.expectEqual(code_b.id, readU64LE(&fetched_row, 8));
        try std.testing.expectEqual(@as(u64, 200), readU64LE(&fetched_row, 16));
        try std.testing.expectError(TableError.NotFound, snapshotGetRowBlobEqKey(std.testing.allocator, snapshot, 1, "codes", "CUST-999", &fetched_row));
        var short_row: [23]u8 = undefined;
        try std.testing.expectError(TableError.InvalidFormat, snapshotGetRowBlobEqKey(std.testing.allocator, snapshot, 1, "codes", "CUST-002", &short_row));
        try std.testing.expectError(TableError.InvalidFormat, snapshotGetRowBlobEqKey(std.testing.allocator, snapshot, 0, "codes", "CUST-002", &fetched_row));
    }

    const non_unique_name = "blob_key_rows_non_unique";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "blob_key_rows_non_unique.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_CODE_STRIDE = 8 // blob_handle
    );
    const non_unique_code = try putBlobValue(std.testing.allocator, ".", non_unique_name, "codes", "CUST-003");
    var non_unique_row: [16]u8 = undefined;
    writeU64LE(&non_unique_row, 0, 3);
    writeU64LE(&non_unique_row, 8, non_unique_code.id);
    _ = try insertRawRow(std.testing.allocator, ".", non_unique_name, &non_unique_row);
    _ = try createBlobEqIndex(std.testing.allocator, ".", non_unique_name, 1, "codes", false);
    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", non_unique_name);
        defer snapshot.destroy();
        var fetched_row: [16]u8 = undefined;
        try std.testing.expectError(TableError.InvalidFormat, snapshotGetRowBlobEqKey(std.testing.allocator, snapshot, 1, "codes", "CUST-003", &fetched_row));
    }
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
        var fetched_row: [32]u8 = undefined;
        try snapshotGetRowU64PairKey(snapshot, 0, 1, 10, 2, &fetched_row);
        try std.testing.expectEqual(@as(u64, 10), readU64LE(&fetched_row, 0));
        try std.testing.expectEqual(@as(u64, 2), readU64LE(&fetched_row, 8));
        try std.testing.expectEqual(@as(u64, 200), readU64LE(&fetched_row, 16));
        try std.testing.expectEqual(@as(u64, 7), readU64LE(&fetched_row, 24));
        try std.testing.expectError(TableError.NotFound, snapshotGetRowU64PairKey(snapshot, 0, 1, 99, 1, &fetched_row));
        var short_row: [31]u8 = undefined;
        try std.testing.expectError(TableError.InvalidFormat, snapshotGetRowU64PairKey(snapshot, 0, 1, 10, 2, &short_row));

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
        try std.testing.expectError(TableError.InvalidFormat, snapshotGetRowU64PairKey(snapshot, 1, 0, 2, 10, &fetched_row));
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
        var fetched_row: [24]u8 = undefined;
        try snapshotGetRowU64I64PairKey(snapshot, 0, 1, 7, -5, &fetched_row);
        try std.testing.expectEqual(@as(u64, 7), readU64LE(&fetched_row, 0));
        try std.testing.expectEqual(@as(i64, -5), readI64LE(&fetched_row, 8));
        try std.testing.expectEqual(@as(i64, 1000), readI64LE(&fetched_row, 16));
        try std.testing.expectError(TableError.NotFound, snapshotGetRowU64I64PairKey(snapshot, 0, 1, 7, -99, &fetched_row));
        var short_row: [23]u8 = undefined;
        try std.testing.expectError(TableError.InvalidFormat, snapshotGetRowU64I64PairKey(snapshot, 0, 1, 7, -5, &short_row));

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
        try std.testing.expectError(TableError.InvalidFormat, snapshotGetRowU64I64PairKey(snapshot, 1, 0, 7, -5, &fetched_row));
    }

    var duplicate_row: [24]u8 = undefined;
    writeU64LE(&duplicate_row, 0, 7);
    writeI64LE(&duplicate_row, 8, 0);
    writeI64LE(&duplicate_row, 16, 9999);
    try std.testing.expectError(TableError.ConstraintViolation, insertRawRow(std.testing.allocator, ".", table_name, &duplicate_row));
    const after_duplicate = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 5), after_duplicate.row_count);
}

test "table u64 i64 pair key row writes update upsert and delete" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "pair_i64_write_orders";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "pair_i64_write_orders.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_CUSTOMER_ID_STRIDE = 8 // u64
        \\#def COL_ORDER_DAY_STRIDE = 8 // i64
        \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64
    );

    var customer_ids = [_]u64{ 7, 7, 8 };
    var order_days = [_]i64{ -5, 0, -3 };
    var totals = [_]i64{ 1000, 2000, 4000 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(customer_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(order_days[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(totals[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, customer_ids.len, &columns);
    _ = try createU64I64PairIndex(std.testing.allocator, ".", table_name, 0, 1, true);

    var row: [24]u8 = undefined;
    writeU64LE(&row, 0, 7);
    writeI64LE(&row, 8, -5);
    writeI64LE(&row, 16, 1100);
    const direct_update = try updateRawRowU64I64PairKey(std.testing.allocator, ".", table_name, 0, 1, 7, -5, &row);
    try std.testing.expectEqual(@as(u64, 3), direct_update.row_count);

    writeU64LE(&row, 0, 7);
    writeI64LE(&row, 8, -10);
    writeI64LE(&row, 16, 900);
    try std.testing.expectError(TableError.NotFound, updateRawRowU64I64PairKey(std.testing.allocator, ".", table_name, 0, 1, 7, -10, &row));

    writeU64LE(&row, 0, 7);
    writeI64LE(&row, 8, 1);
    writeI64LE(&row, 16, 2100);
    try std.testing.expectError(TableError.InvalidFormat, updateRawRowU64I64PairKey(std.testing.allocator, ".", table_name, 0, 1, 7, 0, &row));

    writeU64LE(&row, 0, 7);
    writeI64LE(&row, 8, -5);
    writeI64LE(&row, 16, 1200);
    const direct_upsert_existing = try upsertRawRowU64I64PairKey(std.testing.allocator, ".", table_name, 0, 1, 7, -5, &row);
    try std.testing.expect(!direct_upsert_existing.inserted);

    writeU64LE(&row, 0, 7);
    writeI64LE(&row, 8, 10);
    writeI64LE(&row, 16, 3000);
    const direct_upsert_new = try upsertRawRowU64I64PairKey(std.testing.allocator, ".", table_name, 0, 1, 7, 10, &row);
    try std.testing.expect(direct_upsert_new.inserted);
    try std.testing.expectEqual(@as(u64, 4), direct_upsert_new.info.row_count);

    const direct_delete = try deleteU64I64PairKey(std.testing.allocator, ".", table_name, 0, 1, 8, -3);
    try std.testing.expectEqual(@as(u64, 3), direct_delete.row_count);
    try std.testing.expectError(TableError.NotFound, deleteU64I64PairKey(std.testing.allocator, ".", table_name, 0, 1, 8, -3));

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        const found = try snapshotFindU64I64Pair(snapshot, 0, 1, 7, -5);
        try std.testing.expect(found.found);
        try std.testing.expectEqual(@as(i64, 1200), try snapshotGetI64(snapshot, 2, found.row_index));
        const deleted = try snapshotFindU64I64Pair(snapshot, 0, 1, 8, -3);
        try std.testing.expect(!deleted.found);
    }

    var tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    writeU64LE(&row, 0, 7);
    writeI64LE(&row, 8, 0);
    writeI64LE(&row, 16, 2200);
    const tx_upsert_existing = try writeTransactionUpsertRawRowU64I64PairKey(tx, 0, 1, 7, 0, &row);
    try std.testing.expect(!tx_upsert_existing.inserted);

    writeU64LE(&row, 0, 7);
    writeI64LE(&row, 8, 99);
    writeI64LE(&row, 16, 9900);
    try std.testing.expectError(TableError.NotFound, writeTransactionUpdateRawRowU64I64PairKey(tx, 0, 1, 7, 99, &row));

    writeU64LE(&row, 0, 7);
    writeI64LE(&row, 8, 10);
    writeI64LE(&row, 16, 3300);
    _ = try writeTransactionUpdateRawRowU64I64PairKey(tx, 0, 1, 7, 10, &row);

    writeU64LE(&row, 0, 9);
    writeI64LE(&row, 8, -1);
    writeI64LE(&row, 16, 9000);
    const tx_upsert_new = try writeTransactionUpsertRawRowU64I64PairKey(tx, 0, 1, 9, -1, &row);
    try std.testing.expect(tx_upsert_new.inserted);
    _ = try writeTransactionDeleteU64I64PairKey(tx, 0, 1, 7, -5);

    const committed = try commitWriteTransaction(std.testing.allocator, tx);
    destroyWriteTransaction(std.testing.allocator, tx);
    try std.testing.expectEqual(@as(u64, 3), committed.row_count);

    tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    writeU64LE(&row, 0, 99);
    writeI64LE(&row, 8, -99);
    writeI64LE(&row, 16, 9999);
    _ = try writeTransactionUpsertRawRowU64I64PairKey(tx, 0, 1, 99, -99, &row);
    destroyWriteTransaction(std.testing.allocator, tx);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 3), snapshot.row_count);
        const day0 = try snapshotFindU64I64Pair(snapshot, 0, 1, 7, 0);
        try std.testing.expect(day0.found);
        try std.testing.expectEqual(@as(i64, 2200), try snapshotGetI64(snapshot, 2, day0.row_index));
        const old_day = try snapshotFindU64I64Pair(snapshot, 0, 1, 7, -5);
        try std.testing.expect(!old_day.found);
        const day10 = try snapshotFindU64I64Pair(snapshot, 0, 1, 7, 10);
        try std.testing.expect(day10.found);
        try std.testing.expectEqual(@as(i64, 3300), try snapshotGetI64(snapshot, 2, day10.row_index));
        const new_customer = try snapshotFindU64I64Pair(snapshot, 0, 1, 9, -1);
        try std.testing.expect(new_customer.found);
        try std.testing.expectEqual(@as(i64, 9000), try snapshotGetI64(snapshot, 2, new_customer.row_index));
        const rolled_back = try snapshotFindU64I64Pair(snapshot, 0, 1, 99, -99);
        try std.testing.expect(!rolled_back.found);
    }
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
        \\#def COL_DOC_TYPE_STRIDE = 8 // blob_handle
    );

    const invoice_doc = try putBlobValue(std.testing.allocator, ".", table_name, "doc_type", "invoice");
    const order_doc = try putBlobValue(std.testing.allocator, ".", table_name, "doc_type", "order");
    const credit_doc = try putBlobValue(std.testing.allocator, ".", table_name, "doc_type", "credit");
    const active_status = try internStringDict(std.testing.allocator, ".", table_name, "status", "active");
    const paid_status = try internStringDict(std.testing.allocator, ".", table_name, "status", "paid");

    var customer_ids = [_]u64{ 7, 7, 7, 8, 7, 7 };
    var order_days = [_]i64{ -5, 0, 10, -3, 20, 25 };
    var status_ids = [_]u64{ active_status.id, paid_status.id, paid_status.id, paid_status.id, active_status.id, paid_status.id };
    var posted = [_]u8{ 1, 1, 0, 1, 1, 1 };
    var totals = [_]i64{ 1000, 2000, 3000, 4000, 5000, 7000 };
    var channel_ids = [_]u32{ 10, 20, 20, 30, 10, 40 };
    var adjustments = [_]i32{ -3, 5, 7, 9, -1, 11 };
    var priorities = [_]u8{ 1, 2, 3, 1, 2, 3 };
    var signed_flags = [_]i8{ -1, 0, 1, 0, -1, 1 };
    var warehouse_ids = [_]u16{ 100, 200, 200, 300, 100, 200 };
    var qty_deltas = [_]i16{ -5, 10, 20, 30, -15, 40 };
    var doc_type_ids = [_]u64{ invoice_doc.id, order_doc.id, invoice_doc.id, order_doc.id, credit_doc.id, invoice_doc.id };
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
        .{ .bytes = std.mem.sliceAsBytes(doc_type_ids[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, customer_ids.len, &columns);
    _ = try createU64I64PairIndex(std.testing.allocator, ".", table_name, 0, 1, true);
    _ = try createU64Index(std.testing.allocator, ".", table_name, 0, false);
    _ = try createU64Index(std.testing.allocator, ".", table_name, 2, false);
    _ = try createI64Index(std.testing.allocator, ".", table_name, 1, false);
    _ = try createI64Index(std.testing.allocator, ".", table_name, 4, false);
    _ = try createBlobEqIndex(std.testing.allocator, ".", table_name, 11, "doc_type", false);

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

    const dict_status = try snapshotFilterDictEqRows(snapshot, 2, "status", "paid", 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 4), dict_status.total);
    try std.testing.expectEqual(@as(u64, 4), dict_status.written);
    try std.testing.expectEqual(@as(u64, 1), filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), filtered_rows[1]);
    try std.testing.expectEqual(@as(u64, 3), filtered_rows[2]);
    try std.testing.expectEqual(@as(u64, 5), filtered_rows[3]);

    const dict_status_page = try snapshotFilterRowsDictEq(snapshot, 2, original_candidate_rows[0..candidate_len], "status", "paid", 1, 1, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 3), dict_status_page.total);
    try std.testing.expectEqual(@as(u64, 1), dict_status_page.written);
    try std.testing.expectEqual(@as(u64, 2), filtered_rows[0]);

    const dict_missing = try snapshotFilterDictEqRows(snapshot, 2, "status", "missing", 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 0), dict_missing.total);
    try std.testing.expectEqual(@as(u64, 0), dict_missing.written);

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

    var null_bitmap = [_]u8{0};
    null_bitmap[0] |= 1 << @as(u3, 1);
    null_bitmap[0] |= 1 << @as(u3, 5);
    const null_u64_result = try snapshotFilterRowsU64RangeNullBitmap(snapshot, 2, original_candidate_rows[0..candidate_len], 2, 2, &null_bitmap, true, 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 2), null_u64_result.total);
    try std.testing.expectEqual(@as(u64, 2), null_u64_result.written);
    try std.testing.expectEqual(@as(u64, 1), filtered_rows[0]);
    try std.testing.expectEqual(@as(u64, 5), filtered_rows[1]);

    const null_i64_result = try snapshotFilterRowsI64RangeNullBitmap(snapshot, 4, candidate_rows[0..status_len], 1500, 5500, &null_bitmap, false, 0, filtered_rows.len, &filtered_rows);
    try std.testing.expectEqual(@as(u64, 1), null_i64_result.total);
    try std.testing.expectEqual(@as(u64, 1), null_i64_result.written);
    try std.testing.expectEqual(@as(u64, 2), filtered_rows[0]);

    var planned_rows = [_]u64{ 99, 99, 99, 99 };
    const planned_status_first = try snapshotPlanU64I64RangeRows(std.testing.allocator, snapshot, 2, 2, 2, 4, 1500, 5500, 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 1), planned_status_first.first_predicate);
    try std.testing.expectEqual(@as(u64, 4), planned_status_first.first_total);
    try std.testing.expectEqual(@as(u64, 4), planned_status_first.second_total);
    try std.testing.expectEqual(@as(u64, 3), planned_status_first.total);
    try std.testing.expectEqual(@as(u64, 3), planned_status_first.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[1]);
    try std.testing.expectEqual(@as(u64, 3), planned_rows[2]);

    const planned_status_page = try snapshotPlanU64I64RangeRows(std.testing.allocator, snapshot, 2, 2, 2, 4, 1500, 5500, 1, 1, &planned_rows);
    try std.testing.expectEqual(@as(u64, 3), planned_status_page.total);
    try std.testing.expectEqual(@as(u64, 1), planned_status_page.written);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[0]);

    const planned_i64_first = try snapshotPlanU64I64RangeRows(std.testing.allocator, snapshot, 2, 1, 2, 4, 1500, 3500, 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 2), planned_i64_first.first_predicate);
    try std.testing.expectEqual(@as(u64, 2), planned_i64_first.first_total);
    try std.testing.expectEqual(@as(u64, 6), planned_i64_first.second_total);
    try std.testing.expectEqual(@as(u64, 2), planned_i64_first.total);
    try std.testing.expectEqual(@as(u64, 2), planned_i64_first.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[1]);

    const planned_u64_u64 = try snapshotPlanU64U64RangeRows(std.testing.allocator, snapshot, 0, 7, 7, 2, 2, 2, 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 2), planned_u64_u64.first_predicate);
    try std.testing.expectEqual(@as(u64, 4), planned_u64_u64.first_total);
    try std.testing.expectEqual(@as(u64, 5), planned_u64_u64.second_total);
    try std.testing.expectEqual(@as(u64, 3), planned_u64_u64.total);
    try std.testing.expectEqual(@as(u64, 3), planned_u64_u64.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[1]);
    try std.testing.expectEqual(@as(u64, 5), planned_rows[2]);

    const planned_i64_i64 = try snapshotPlanI64I64RangeRows(std.testing.allocator, snapshot, 1, -5, 20, 4, 1500, 3500, 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 2), planned_i64_i64.first_predicate);
    try std.testing.expectEqual(@as(u64, 2), planned_i64_i64.first_total);
    try std.testing.expectEqual(@as(u64, 5), planned_i64_i64.second_total);
    try std.testing.expectEqual(@as(u64, 2), planned_i64_i64.total);
    try std.testing.expectEqual(@as(u64, 2), planned_i64_i64.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[1]);

    const planned_status_paid = try snapshotPlanU64DictEqRows(std.testing.allocator, snapshot, 0, 7, 7, 2, "status", "paid", 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 2), planned_status_paid.first_predicate);
    try std.testing.expectEqual(@as(u64, 4), planned_status_paid.first_total);
    try std.testing.expectEqual(@as(u64, 5), planned_status_paid.second_total);
    try std.testing.expectEqual(@as(u64, 3), planned_status_paid.total);
    try std.testing.expectEqual(@as(u64, 3), planned_status_paid.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[1]);
    try std.testing.expectEqual(@as(u64, 5), planned_rows[2]);

    const planned_day_paid = try snapshotPlanI64DictEqRows(std.testing.allocator, snapshot, 1, 0, 20, 2, "status", "paid", 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 1), planned_day_paid.first_predicate);
    try std.testing.expectEqual(@as(u64, 3), planned_day_paid.first_total);
    try std.testing.expectEqual(@as(u64, 4), planned_day_paid.second_total);
    try std.testing.expectEqual(@as(u64, 2), planned_day_paid.total);
    try std.testing.expectEqual(@as(u64, 2), planned_day_paid.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[1]);

    const planned_three_paid = try snapshotPlanU64I64DictEqRows(std.testing.allocator, snapshot, 0, 7, 7, 1, 0, 20, 2, "status", "paid", 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 2), planned_three_paid.first_predicate);
    try std.testing.expectEqual(@as(u64, 3), planned_three_paid.first_total);
    try std.testing.expectEqual(@as(u64, 3), planned_three_paid.second_predicate);
    try std.testing.expectEqual(@as(u64, 4), planned_three_paid.second_total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_paid.third_predicate);
    try std.testing.expectEqual(@as(u64, 5), planned_three_paid.third_total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_paid.total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_paid.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[1]);

    const planned_status_order = try snapshotPlanU64BlobEqRows(std.testing.allocator, snapshot, 2, 2, 2, 11, "doc_type", "order", 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 2), planned_status_order.first_predicate);
    try std.testing.expectEqual(@as(u64, 2), planned_status_order.first_total);
    try std.testing.expectEqual(@as(u64, 4), planned_status_order.second_total);
    try std.testing.expectEqual(@as(u64, 2), planned_status_order.total);
    try std.testing.expectEqual(@as(u64, 2), planned_status_order.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);
    try std.testing.expectEqual(@as(u64, 3), planned_rows[1]);

    const planned_status_order_page = try snapshotPlanU64BlobEqRows(std.testing.allocator, snapshot, 2, 2, 2, 11, "doc_type", "order", 1, 1, &planned_rows);
    try std.testing.expectEqual(@as(u64, 2), planned_status_order_page.total);
    try std.testing.expectEqual(@as(u64, 1), planned_status_order_page.written);
    try std.testing.expectEqual(@as(u64, 3), planned_rows[0]);

    const planned_status_invoice = try snapshotPlanU64BlobEqRows(std.testing.allocator, snapshot, 2, 1, 1, 11, "doc_type", "invoice", 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 1), planned_status_invoice.first_predicate);
    try std.testing.expectEqual(@as(u64, 2), planned_status_invoice.first_total);
    try std.testing.expectEqual(@as(u64, 3), planned_status_invoice.second_total);
    try std.testing.expectEqual(@as(u64, 1), planned_status_invoice.total);
    try std.testing.expectEqual(@as(u64, 1), planned_status_invoice.written);
    try std.testing.expectEqual(@as(u64, 0), planned_rows[0]);

    const planned_due_order = try snapshotPlanI64BlobEqRows(std.testing.allocator, snapshot, 1, 0, 20, 11, "doc_type", "order", 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 2), planned_due_order.first_predicate);
    try std.testing.expectEqual(@as(u64, 2), planned_due_order.first_total);
    try std.testing.expectEqual(@as(u64, 3), planned_due_order.second_total);
    try std.testing.expectEqual(@as(u64, 1), planned_due_order.total);
    try std.testing.expectEqual(@as(u64, 1), planned_due_order.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);

    const planned_due_invoice = try snapshotPlanI64BlobEqRows(std.testing.allocator, snapshot, 1, 20, 25, 11, "doc_type", "invoice", 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 1), planned_due_invoice.first_predicate);
    try std.testing.expectEqual(@as(u64, 2), planned_due_invoice.first_total);
    try std.testing.expectEqual(@as(u64, 3), planned_due_invoice.second_total);
    try std.testing.expectEqual(@as(u64, 1), planned_due_invoice.total);
    try std.testing.expectEqual(@as(u64, 1), planned_due_invoice.written);
    try std.testing.expectEqual(@as(u64, 5), planned_rows[0]);

    const planned_three_i64_first = try snapshotPlanU64I64BlobEqRows(std.testing.allocator, snapshot, 2, 2, 2, 1, 0, 20, 11, "doc_type", "invoice", 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 2), planned_three_i64_first.first_predicate);
    try std.testing.expectEqual(@as(u64, 3), planned_three_i64_first.first_total);
    try std.testing.expectEqual(@as(u64, 3), planned_three_i64_first.second_predicate);
    try std.testing.expectEqual(@as(u64, 3), planned_three_i64_first.second_total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_i64_first.third_predicate);
    try std.testing.expectEqual(@as(u64, 4), planned_three_i64_first.third_total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_i64_first.total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_i64_first.written);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[0]);

    const planned_three_blob_first_page = try snapshotPlanU64I64BlobEqRows(std.testing.allocator, snapshot, 2, 2, 2, 1, -5, 25, 11, "doc_type", "order", 1, 1, &planned_rows);
    try std.testing.expectEqual(@as(u64, 3), planned_three_blob_first_page.first_predicate);
    try std.testing.expectEqual(@as(u64, 2), planned_three_blob_first_page.first_total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_blob_first_page.second_predicate);
    try std.testing.expectEqual(@as(u64, 4), planned_three_blob_first_page.second_total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_blob_first_page.third_predicate);
    try std.testing.expectEqual(@as(u64, 6), planned_three_blob_first_page.third_total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_blob_first_page.total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_blob_first_page.written);
    try std.testing.expectEqual(@as(u64, 3), planned_rows[0]);

    const planned_three_u64_first = try snapshotPlanU64I64BlobEqRows(std.testing.allocator, snapshot, 2, 1, 1, 1, -5, 25, 11, "doc_type", "invoice", 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 1), planned_three_u64_first.first_predicate);
    try std.testing.expectEqual(@as(u64, 2), planned_three_u64_first.first_total);
    try std.testing.expectEqual(@as(u64, 3), planned_three_u64_first.second_predicate);
    try std.testing.expectEqual(@as(u64, 3), planned_three_u64_first.second_total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_u64_first.third_predicate);
    try std.testing.expectEqual(@as(u64, 6), planned_three_u64_first.third_total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_u64_first.total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_u64_first.written);
    try std.testing.expectEqual(@as(u64, 0), planned_rows[0]);

    const planned_three_bool_i64_first = try snapshotPlanU64I64BoolRows(std.testing.allocator, snapshot, 2, 2, 2, 1, 0, 20, 3, true, 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 2), planned_three_bool_i64_first.first_predicate);
    try std.testing.expectEqual(@as(u64, 3), planned_three_bool_i64_first.first_total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_bool_i64_first.second_predicate);
    try std.testing.expectEqual(@as(u64, 4), planned_three_bool_i64_first.second_total);
    try std.testing.expectEqual(@as(u64, 3), planned_three_bool_i64_first.third_predicate);
    try std.testing.expectEqual(@as(u64, 5), planned_three_bool_i64_first.third_total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_bool_i64_first.total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_bool_i64_first.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);

    const planned_three_bool_first = try snapshotPlanU64I64BoolRows(std.testing.allocator, snapshot, 2, 2, 2, 1, -5, 25, 3, false, 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 3), planned_three_bool_first.first_predicate);
    try std.testing.expectEqual(@as(u64, 1), planned_three_bool_first.first_total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_bool_first.second_predicate);
    try std.testing.expectEqual(@as(u64, 4), planned_three_bool_first.second_total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_bool_first.third_predicate);
    try std.testing.expectEqual(@as(u64, 6), planned_three_bool_first.third_total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_bool_first.total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_bool_first.written);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[0]);

    const planned_three_bool_u64_first_page = try snapshotPlanU64I64BoolRows(std.testing.allocator, snapshot, 2, 1, 1, 1, -5, 25, 3, true, 1, 1, &planned_rows);
    try std.testing.expectEqual(@as(u64, 1), planned_three_bool_u64_first_page.first_predicate);
    try std.testing.expectEqual(@as(u64, 2), planned_three_bool_u64_first_page.first_total);
    try std.testing.expectEqual(@as(u64, 3), planned_three_bool_u64_first_page.second_predicate);
    try std.testing.expectEqual(@as(u64, 5), planned_three_bool_u64_first_page.second_total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_bool_u64_first_page.third_predicate);
    try std.testing.expectEqual(@as(u64, 6), planned_three_bool_u64_first_page.third_total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_bool_u64_first_page.total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_bool_u64_first_page.written);
    try std.testing.expectEqual(@as(u64, 4), planned_rows[0]);

    const planned_three_i64_i64_amount_first = try snapshotPlanU64I64I64RangeRows(std.testing.allocator, snapshot, 2, 2, 2, 1, -5, 25, 4, 1500, 3500, 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 3), planned_three_i64_i64_amount_first.first_predicate);
    try std.testing.expectEqual(@as(u64, 2), planned_three_i64_i64_amount_first.first_total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_i64_i64_amount_first.second_predicate);
    try std.testing.expectEqual(@as(u64, 4), planned_three_i64_i64_amount_first.second_total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_i64_i64_amount_first.third_predicate);
    try std.testing.expectEqual(@as(u64, 6), planned_three_i64_i64_amount_first.third_total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_i64_i64_amount_first.total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_i64_i64_amount_first.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[1]);

    const planned_three_i64_i64_day_first = try snapshotPlanU64I64I64RangeRows(std.testing.allocator, snapshot, 2, 2, 2, 1, 0, 20, 4, 1500, 5500, 0, planned_rows.len, &planned_rows);
    try std.testing.expectEqual(@as(u64, 2), planned_three_i64_i64_day_first.first_predicate);
    try std.testing.expectEqual(@as(u64, 3), planned_three_i64_i64_day_first.first_total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_i64_i64_day_first.second_predicate);
    try std.testing.expectEqual(@as(u64, 4), planned_three_i64_i64_day_first.second_total);
    try std.testing.expectEqual(@as(u64, 3), planned_three_i64_i64_day_first.third_predicate);
    try std.testing.expectEqual(@as(u64, 4), planned_three_i64_i64_day_first.third_total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_i64_i64_day_first.total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_i64_i64_day_first.written);
    try std.testing.expectEqual(@as(u64, 1), planned_rows[0]);
    try std.testing.expectEqual(@as(u64, 2), planned_rows[1]);

    const planned_three_i64_i64_u64_first_page = try snapshotPlanU64I64I64RangeRows(std.testing.allocator, snapshot, 2, 1, 1, 1, -5, 25, 4, 0, 6000, 1, 1, &planned_rows);
    try std.testing.expectEqual(@as(u64, 1), planned_three_i64_i64_u64_first_page.first_predicate);
    try std.testing.expectEqual(@as(u64, 2), planned_three_i64_i64_u64_first_page.first_total);
    try std.testing.expectEqual(@as(u64, 3), planned_three_i64_i64_u64_first_page.second_predicate);
    try std.testing.expectEqual(@as(u64, 5), planned_three_i64_i64_u64_first_page.second_total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_i64_i64_u64_first_page.third_predicate);
    try std.testing.expectEqual(@as(u64, 6), planned_three_i64_i64_u64_first_page.third_total);
    try std.testing.expectEqual(@as(u64, 2), planned_three_i64_i64_u64_first_page.total);
    try std.testing.expectEqual(@as(u64, 1), planned_three_i64_i64_u64_first_page.written);
    try std.testing.expectEqual(@as(u64, 4), planned_rows[0]);

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
        const found1 = try snapshotFindU64(snapshot, 0, 1);
        try std.testing.expect(found1.found);
        try std.testing.expectEqual(@as(u64, 0), found1.row_index);
        const found2 = try snapshotFindU64(snapshot, 0, 2);
        try std.testing.expect(found2.found);
        try std.testing.expectEqual(@as(u64, 1), found2.row_index);
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
        const found1 = try snapshotFindU64(snapshot, 0, 1);
        try std.testing.expect(found1.found);
        try std.testing.expectEqual(@as(u64, 0), found1.row_index);
        const found2 = try snapshotFindU64(snapshot, 0, 2);
        try std.testing.expect(found2.found);
        try std.testing.expectEqual(@as(u64, 1), found2.row_index);
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

test "table write transaction raw columns append unique indexes in place in unsafe mode" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const previous_unsafe = unsafe_no_sync_state.load(.acquire);
    unsafe_no_sync_state.store(2, .release);
    defer unsafe_no_sync_state.store(previous_unsafe, .release);

    const table_name = "tx_append_unique_unsafe";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "tx_append_unique_unsafe.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_INVOICE_ID_STRIDE = 8 // u64
        \\#def COL_ORDER_ID_STRIDE = 8 // u64
        \\#def COL_LINE_NO_STRIDE = 8 // u64
    );

    var invoice_ids = [_]u64{ 100, 101 };
    var order_ids = [_]u64{ 10, 10 };
    var line_nos = [_]u64{ 1, 2 };
    const initial_columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(invoice_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(order_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(line_nos[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, invoice_ids.len, &initial_columns);
    _ = try createU64Index(std.testing.allocator, ".", table_name, 0, true);
    _ = try createU64PairIndex(std.testing.allocator, ".", table_name, 1, 2, true);

    var before = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), before.indexes.len);
    try std.testing.expectEqualStrings("u64", before.indexes[0].kind);
    try std.testing.expectEqualStrings("u64_pair", before.indexes[1].kind);

    const before_u64_path = try std.testing.allocator.dupe(u8, before.indexes[0].path);
    defer std.testing.allocator.free(before_u64_path);
    const before_pair_path = try std.testing.allocator.dupe(u8, before.indexes[1].path);
    defer std.testing.allocator.free(before_pair_path);
    const before_u64_bytes = before.indexes[0].bytes;
    const before_pair_bytes = before.indexes[1].bytes;

    const tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    defer destroyWriteTransaction(std.testing.allocator, tx);

    var appended_invoice_ids = [_]u64{ 102, 103 };
    var appended_order_ids = [_]u64{ 10, 11 };
    var appended_line_nos = [_]u64{ 3, 1 };
    const appended_columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(appended_invoice_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(appended_order_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(appended_line_nos[0..]) },
    };
    _ = try writeTransactionInsertRawColumns(tx, appended_invoice_ids.len, &appended_columns);
    const committed = try commitWriteTransaction(std.testing.allocator, tx);
    try std.testing.expectEqual(@as(u64, 4), committed.row_count);

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 4), verified.row_count);

    var after = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), after.indexes.len);
    try std.testing.expectEqualStrings(before_u64_path, after.indexes[0].path);
    try std.testing.expectEqualStrings(before_pair_path, after.indexes[1].path);
    try std.testing.expectEqual(before_u64_bytes + 2 * INDEX_RECORD_BYTES, after.indexes[0].bytes);
    try std.testing.expectEqual(before_pair_bytes + 2 * U64_PAIR_INDEX_RECORD_BYTES, after.indexes[1].bytes);
    try std.testing.expectEqual(@as(usize, 0), after.indexes[0].sha256.len);
    try std.testing.expectEqual(@as(usize, 0), after.indexes[1].sha256.len);
    try std.testing.expectEqual(@as(u64, 0), after.indexes[0].block_size);
    try std.testing.expectEqual(@as(u64, 0), after.indexes[1].block_size);
    try std.testing.expectEqual(@as(usize, 0), after.indexes[0].block_sha256.len);
    try std.testing.expectEqual(@as(usize, 0), after.indexes[1].block_sha256.len);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        const invoice = try snapshotFindU64(snapshot, 0, 103);
        try std.testing.expect(invoice.found);
        try std.testing.expectEqual(@as(u64, 3), invoice.row_index);
        const line = try snapshotFindU64Pair(snapshot, 1, 2, 10, 3);
        try std.testing.expect(line.found);
        try std.testing.expectEqual(@as(u64, 2), line.row_index);
        var fetched_row: [24]u8 = undefined;
        try snapshotGetRowU64Key(snapshot, 0, 102, &fetched_row);
        try std.testing.expectEqual(@as(u64, 102), readU64LE(&fetched_row, 0));
        try std.testing.expectEqual(@as(u64, 10), readU64LE(&fetched_row, 8));
        try std.testing.expectEqual(@as(u64, 3), readU64LE(&fetched_row, 16));
    }
}

test "table write transaction raw columns rewrite merged indexes in place in unsafe mode" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const previous_unsafe = unsafe_no_sync_state.load(.acquire);
    unsafe_no_sync_state.store(2, .release);
    defer unsafe_no_sync_state.store(previous_unsafe, .release);

    const table_name = "tx_append_merge_unsafe";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "tx_append_merge_unsafe.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_INVOICE_ID_STRIDE = 8 // u64
        \\#def COL_STATUS_STRIDE = 8 // u64
        \\#def COL_DUE_DAY_STRIDE = 8 // i64 date
    );

    var invoice_ids = [_]u64{ 100, 101 };
    var statuses = [_]u64{ 1, 2 };
    var due_days = [_]i64{ 20, 30 };
    const initial_columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(invoice_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(statuses[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(due_days[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, invoice_ids.len, &initial_columns);
    _ = try createU64I64PairIndex(std.testing.allocator, ".", table_name, 1, 2, false);

    var before = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), before.indexes.len);
    try std.testing.expectEqualStrings("u64_i64_pair", before.indexes[0].kind);

    const before_path = try std.testing.allocator.dupe(u8, before.indexes[0].path);
    defer std.testing.allocator.free(before_path);

    const tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    defer destroyWriteTransaction(std.testing.allocator, tx);

    var appended_invoice_ids = [_]u64{ 102, 103 };
    var appended_statuses = [_]u64{ 1, 2 };
    var appended_due_days = [_]i64{ 10, 25 };
    const appended_columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(appended_invoice_ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(appended_statuses[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(appended_due_days[0..]) },
    };
    _ = try writeTransactionInsertRawColumns(tx, appended_invoice_ids.len, &appended_columns);
    const committed = try commitWriteTransaction(std.testing.allocator, tx);
    try std.testing.expectEqual(@as(u64, 4), committed.row_count);

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 4), verified.row_count);

    var after = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), after.indexes.len);
    try std.testing.expectEqualStrings(before_path, after.indexes[0].path);
    try std.testing.expectEqual(@as(u64, 4 * U64_PAIR_INDEX_RECORD_BYTES), after.indexes[0].bytes);
    try std.testing.expectEqual(@as(usize, 0), after.indexes[0].sha256.len);
    try std.testing.expectEqual(@as(u64, 0), after.indexes[0].block_size);
    try std.testing.expectEqual(@as(usize, 0), after.indexes[0].block_sha256.len);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        const first = try snapshotFindU64I64Pair(snapshot, 1, 2, 1, 10);
        try std.testing.expect(first.found);
        try std.testing.expectEqual(@as(u64, 2), first.row_index);
        const second = try snapshotFindU64I64Pair(snapshot, 1, 2, 2, 25);
        try std.testing.expect(second.found);
        try std.testing.expectEqual(@as(u64, 3), second.row_index);
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

test "table intern string dict many batches inserts and reuses ids" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "dict_many_members";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "dict_many_members.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
    );

    const first_values = [_][]const u8{ "active", "paused", "active", "closed" };
    var first_ids: [first_values.len]u64 = undefined;
    var first_inserted: [first_values.len]bool = undefined;
    const first = try internStringDictMany(std.testing.allocator, ".", table_name, "status", &first_values, &first_ids, &first_inserted);
    try std.testing.expectEqual(@as(u64, 3), first.inserted_count);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 1, 3 }, &first_ids);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, true }, &first_inserted);
    try std.testing.expectEqual(@as(u64, 1), first.info.epoch);

    const second_values = [_][]const u8{ "paused", "open", "closed", "open" };
    var second_ids: [second_values.len]u64 = undefined;
    var second_inserted: [second_values.len]bool = undefined;
    const second = try internStringDictMany(std.testing.allocator, ".", table_name, "status", &second_values, &second_ids, &second_inserted);
    try std.testing.expectEqual(@as(u64, 1), second.inserted_count);
    try std.testing.expectEqualSlices(u64, &.{ 2, 4, 3, 4 }, &second_ids);
    try std.testing.expectEqualSlices(bool, &.{ false, true, false, false }, &second_inserted);
    try std.testing.expectEqual(@as(u64, 2), second.info.epoch);

    const open = try lookupStringDict(std.testing.allocator, ".", table_name, "status", "open");
    try std.testing.expect(open.found);
    try std.testing.expectEqual(@as(u64, 4), open.id);
    const active = try lookupStringDict(std.testing.allocator, ".", table_name, "status", "active");
    try std.testing.expect(active.found);
    try std.testing.expectEqual(@as(u64, 1), active.id);

    _ = try verifyTable(std.testing.allocator, ".", table_name);
}

test "table write transaction dictionary-only commit keeps indexes intact without rebuild" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "tx_dict_only_indexed";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "tx_dict_only_indexed.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_STATUS_STRIDE = 8 // u64
    );

    var row: [16]u8 = undefined;
    writeU64LE(&row, 0, 1);
    writeU64LE(&row, 8, 0);
    _ = try insertRawRow(std.testing.allocator, ".", table_name, &row);
    _ = try createU64Index(std.testing.allocator, ".", table_name, 0, true);

    var before = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), before.indexes.len);
    const before_index_path = try std.testing.allocator.dupe(u8, before.indexes[0].path);
    defer std.testing.allocator.free(before_index_path);
    const before_index_sha = try std.testing.allocator.dupe(u8, before.indexes[0].sha256);
    defer std.testing.allocator.free(before_index_sha);
    const before_index_bytes = before.indexes[0].bytes;

    const tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    const active = try writeTransactionInternStringDict(std.testing.allocator, tx, "status", "active");
    try std.testing.expectEqual(@as(u64, 1), active.id);
    try std.testing.expect(active.inserted);
    const committed = try commitWriteTransaction(std.testing.allocator, tx);
    try std.testing.expectEqual(@as(u64, 1), committed.row_count);
    try std.testing.expectEqual(@as(u64, 3), committed.epoch);
    destroyWriteTransaction(std.testing.allocator, tx);

    var after = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), after.indexes.len);
    try std.testing.expectEqualStrings(before_index_path, after.indexes[0].path);
    try std.testing.expectEqualStrings(before_index_sha, after.indexes[0].sha256);
    try std.testing.expectEqual(before_index_bytes, after.indexes[0].bytes);

    const visible = try lookupStringDict(std.testing.allocator, ".", table_name, "status", "active");
    try std.testing.expect(visible.found);
    try std.testing.expectEqual(@as(u64, 1), visible.id);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        const found = try snapshotFindU64(snapshot, 0, 1);
        try std.testing.expect(found.found);
        try std.testing.expectEqual(@as(u64, 0), found.row_index);
    }

    _ = try verifyTable(std.testing.allocator, ".", table_name);
}

test "table unsafe init defers empty meta until first write" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const previous_unsafe = unsafe_no_sync_state.load(.acquire);
    unsafe_no_sync_state.store(2, .release);
    defer unsafe_no_sync_state.store(previous_unsafe, .release);

    const table_name = "unsafe_init_members";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "unsafe_init_members.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_STATUS_STRIDE = 8 // u64
    );

    const meta_path = try tableMetaPath(std.testing.allocator, ".", table_name);
    defer std.testing.allocator.free(meta_path);
    try std.testing.expect(!fileExists(meta_path));

    const values = [_][]const u8{ "active", "paused" };
    var ids: [values.len]u64 = undefined;
    var inserted: [values.len]bool = undefined;
    const info = try internStringDictMany(std.testing.allocator, ".", table_name, "status", &values, &ids, &inserted);
    try std.testing.expectEqual(@as(u64, 2), info.inserted_count);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, &ids);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, &inserted);

    try std.testing.expect(fileExists(meta_path));
    const visible = try lookupStringDict(std.testing.allocator, ".", table_name, "status", "paused");
    try std.testing.expect(visible.found);
    try std.testing.expectEqual(@as(u64, 2), visible.id);
    _ = try verifyTable(std.testing.allocator, ".", table_name);
}

test "table unsafe init cache serves first write transaction bootstrap" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const previous_unsafe = unsafe_no_sync_state.load(.acquire);
    unsafe_no_sync_state.store(2, .release);
    defer unsafe_no_sync_state.store(previous_unsafe, .release);

    const table_name = "unsafe_tx_bootstrap";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "unsafe_tx_bootstrap.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_STATUS_STRIDE = 8 // u64
    );

    const meta_path = try tableMetaPath(std.testing.allocator, ".", table_name);
    defer std.testing.allocator.free(meta_path);
    try std.testing.expect(!fileExists(meta_path));

    const tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    defer destroyWriteTransaction(std.testing.allocator, tx);
    const interned = try writeTransactionInternStringDict(std.testing.allocator, tx, "status", "active");
    try std.testing.expectEqual(@as(u64, 1), interned.id);
    try std.testing.expect(interned.inserted);
    const committed = try commitWriteTransaction(std.testing.allocator, tx);
    try std.testing.expectEqual(@as(u64, 1), committed.epoch);
    try std.testing.expect(fileExists(meta_path));

    const visible = try lookupStringDict(std.testing.allocator, ".", table_name, "status", "active");
    try std.testing.expect(visible.found);
    try std.testing.expectEqual(@as(u64, 1), visible.id);
}

test "table unsafe init cache serves first coltx bootstrap" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const previous_unsafe = unsafe_no_sync_state.load(.acquire);
    unsafe_no_sync_state.store(2, .release);
    defer unsafe_no_sync_state.store(previous_unsafe, .release);

    const table_name = "unsafe_coltx_bootstrap";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "unsafe_coltx_bootstrap.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_STATUS_STRIDE = 8 // u64
    );

    const meta_path = try tableMetaPath(std.testing.allocator, ".", table_name);
    defer std.testing.allocator.free(meta_path);
    try std.testing.expect(!fileExists(meta_path));

    const session = try beginColumnIngestSession(std.testing.allocator, ".", table_name);
    defer destroyColumnIngestSession(std.testing.allocator, session);

    var ids = [_]u64{1, 2};
    var statuses = [_]u64{10, 20};
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(statuses[0..]) },
    };
    try columnIngestSessionAddRawColumns(std.testing.allocator, session, ids.len, &columns);
    const committed = try commitColumnIngestSession(std.testing.allocator, session);
    try std.testing.expectEqual(@as(u64, 2), committed.row_count);
    try std.testing.expectEqual(@as(u64, 1), committed.epoch);
    try std.testing.expect(fileExists(meta_path));

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 2), verified.row_count);
}

test "table unsafe init cache survives read before first write bootstrap" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const previous_unsafe = unsafe_no_sync_state.load(.acquire);
    unsafe_no_sync_state.store(2, .release);
    defer unsafe_no_sync_state.store(previous_unsafe, .release);

    const table_name = "unsafe_read_then_write";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "unsafe_read_then_write.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_STATUS_STRIDE = 8 // u64
    );

    const meta_path = try tableMetaPath(std.testing.allocator, ".", table_name);
    defer std.testing.allocator.free(meta_path);
    try std.testing.expect(!fileExists(meta_path));

    var peeked = try loadActiveMeta(std.testing.allocator, ".", table_name);
    defer peeked.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), peeked.row_count);
    try std.testing.expect(!fileExists(meta_path));

    const tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    defer destroyWriteTransaction(std.testing.allocator, tx);
    const interned = try writeTransactionInternStringDict(std.testing.allocator, tx, "status", "active");
    try std.testing.expectEqual(@as(u64, 1), interned.id);
    try std.testing.expect(interned.inserted);
    const committed = try commitWriteTransaction(std.testing.allocator, tx);
    try std.testing.expectEqual(@as(u64, 1), committed.epoch);
    try std.testing.expect(fileExists(meta_path));

    const visible = try lookupStringDict(std.testing.allocator, ".", table_name, "status", "active");
    try std.testing.expect(visible.found);
    try std.testing.expectEqual(@as(u64, 1), visible.id);
}

test "table unsafe init cache survives init allocator teardown before ingest" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const previous_unsafe = unsafe_no_sync_state.load(.acquire);
    unsafe_no_sync_state.store(2, .release);
    defer unsafe_no_sync_state.store(previous_unsafe, .release);

    const table_name = "unsafe_arena_teardown_ingest";
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        _ = try initTableFromSchemaBytes(arena.allocator(), ".", "unsafe_arena_teardown_ingest.sadb-schema",
            \\#def MAX_ROWS = 8
            \\#def COL_ID_STRIDE = 8 // u64
            \\#def COL_STATUS_STRIDE = 8 // u64
        );
    }

    var ids = [_]u64{ 1, 2 };
    var statuses = [_]u64{ 10, 20 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(statuses[0..]) },
    };
    const info = try ingestRawColumns(std.testing.allocator, ".", table_name, ids.len, &columns);
    try std.testing.expectEqual(@as(u64, 2), info.row_count);
    try std.testing.expectEqual(@as(u64, 1), info.epoch);

    const verified = try verifyTable(std.testing.allocator, ".", table_name);
    try std.testing.expectEqual(@as(u64, 2), verified.row_count);
}

test "table unsafe init cache serves first direct row insert bootstrap" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const previous_unsafe = unsafe_no_sync_state.load(.acquire);
    unsafe_no_sync_state.store(2, .release);
    defer unsafe_no_sync_state.store(previous_unsafe, .release);

    const table_name = "unsafe_insert_row_bootstrap";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "unsafe_insert_row_bootstrap.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_STATUS_STRIDE = 8 // u64
    );

    const meta_path = try tableMetaPath(std.testing.allocator, ".", table_name);
    defer std.testing.allocator.free(meta_path);
    try std.testing.expect(!fileExists(meta_path));

    var row = [_]u64{ 7, 11 };
    const inserted = try insertRawRow(std.testing.allocator, ".", table_name, std.mem.sliceAsBytes(row[0..]));
    try std.testing.expectEqual(@as(u64, 1), inserted.row_count);
    try std.testing.expectEqual(@as(u64, 1), inserted.epoch);
    try std.testing.expect(fileExists(meta_path));

    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();
    const found = try snapshotFindU64(snapshot, 0, 7);
    try std.testing.expect(found.found);
    try std.testing.expectEqual(@as(u64, 0), found.row_index);
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

test "table i64 key row writes update upsert and delete" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "signed_day_rows";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "signed_day_rows.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_DAY_STRIDE = 8 // i64 date
        \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64 decimal(2)
    );

    var days = [_]i64{ -5, 0, 10 };
    var totals = [_]i64{ 1000, 2000, 3000 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(days[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(totals[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, days.len, &columns);
    _ = try createI64Index(std.testing.allocator, ".", table_name, 0, true);

    var row: [16]u8 = undefined;
    writeI64LE(&row, 0, 0);
    writeI64LE(&row, 8, 2100);
    const direct_update = try updateRawRowI64Key(std.testing.allocator, ".", table_name, 0, 0, &row);
    try std.testing.expectEqual(@as(u64, 3), direct_update.row_count);

    writeI64LE(&row, 0, 99);
    writeI64LE(&row, 8, 9900);
    try std.testing.expectError(TableError.NotFound, updateRawRowI64Key(std.testing.allocator, ".", table_name, 0, 99, &row));

    writeI64LE(&row, 0, 1);
    writeI64LE(&row, 8, 111);
    try std.testing.expectError(TableError.InvalidFormat, updateRawRowI64Key(std.testing.allocator, ".", table_name, 0, 0, &row));

    writeI64LE(&row, 0, -5);
    writeI64LE(&row, 8, 1100);
    const direct_upsert_existing = try upsertRawRowI64Key(std.testing.allocator, ".", table_name, 0, -5, &row);
    try std.testing.expect(!direct_upsert_existing.inserted);

    writeI64LE(&row, 0, 20);
    writeI64LE(&row, 8, 2000);
    const direct_upsert_new = try upsertRawRowI64Key(std.testing.allocator, ".", table_name, 0, 20, &row);
    try std.testing.expect(direct_upsert_new.inserted);
    try std.testing.expectEqual(@as(u64, 4), direct_upsert_new.info.row_count);

    const direct_delete = try deleteI64Key(std.testing.allocator, ".", table_name, 0, 10);
    try std.testing.expectEqual(@as(u64, 3), direct_delete.row_count);
    try std.testing.expectError(TableError.NotFound, deleteI64Key(std.testing.allocator, ".", table_name, 0, 10));

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        const day0 = try snapshotFindI64(snapshot, 0, 0);
        try std.testing.expect(day0.found);
        try std.testing.expectEqual(@as(i64, 2100), try snapshotGetI64(snapshot, 1, day0.row_index));
        const deleted = try snapshotFindI64(snapshot, 0, 10);
        try std.testing.expect(!deleted.found);
    }

    var tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    writeI64LE(&row, 0, 0);
    writeI64LE(&row, 8, 2500);
    const tx_upsert_existing = try writeTransactionUpsertRawRowI64Key(tx, 0, 0, &row);
    try std.testing.expect(!tx_upsert_existing.inserted);

    writeI64LE(&row, 0, 99);
    writeI64LE(&row, 8, 9900);
    try std.testing.expectError(TableError.NotFound, writeTransactionUpdateRawRowI64Key(tx, 0, 99, &row));

    writeI64LE(&row, 0, 20);
    writeI64LE(&row, 8, 2200);
    _ = try writeTransactionUpdateRawRowI64Key(tx, 0, 20, &row);

    writeI64LE(&row, 0, -1);
    writeI64LE(&row, 8, 900);
    const tx_upsert_new = try writeTransactionUpsertRawRowI64Key(tx, 0, -1, &row);
    try std.testing.expect(tx_upsert_new.inserted);
    _ = try writeTransactionDeleteI64Key(tx, 0, -5);

    const committed = try commitWriteTransaction(std.testing.allocator, tx);
    destroyWriteTransaction(std.testing.allocator, tx);
    try std.testing.expectEqual(@as(u64, 3), committed.row_count);

    tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
    writeI64LE(&row, 0, 99);
    writeI64LE(&row, 8, 9900);
    _ = try writeTransactionUpsertRawRowI64Key(tx, 0, 99, &row);
    destroyWriteTransaction(std.testing.allocator, tx);

    {
        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 3), snapshot.row_count);
        const day0 = try snapshotFindI64(snapshot, 0, 0);
        try std.testing.expect(day0.found);
        try std.testing.expectEqual(@as(i64, 2500), try snapshotGetI64(snapshot, 1, day0.row_index));
        const day20 = try snapshotFindI64(snapshot, 0, 20);
        try std.testing.expect(day20.found);
        try std.testing.expectEqual(@as(i64, 2200), try snapshotGetI64(snapshot, 1, day20.row_index));
        const day_neg1 = try snapshotFindI64(snapshot, 0, -1);
        try std.testing.expect(day_neg1.found);
        try std.testing.expectEqual(@as(i64, 900), try snapshotGetI64(snapshot, 1, day_neg1.row_index));
        const old_day = try snapshotFindI64(snapshot, 0, -5);
        try std.testing.expect(!old_day.found);
        const rolled_back = try snapshotFindI64(snapshot, 0, 99);
        try std.testing.expect(!rolled_back.found);
    }
}

test "table u32 and i32 key row writes update upsert and delete" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    {
        const table_name = "u32_channel_totals";
        _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "u32_channel_totals.sadb-schema",
            \\#def MAX_ROWS = 8
            \\#def COL_CHANNEL_ID_STRIDE = 4 // u32
            \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64
        );

        var channel_ids = [_]u32{ 10, 20, 30 };
        var totals = [_]i64{ 1000, 2000, 3000 };
        const columns = [_]RawColumnBytes{
            .{ .bytes = std.mem.sliceAsBytes(channel_ids[0..]) },
            .{ .bytes = std.mem.sliceAsBytes(totals[0..]) },
        };
        _ = try ingestRawColumns(std.testing.allocator, ".", table_name, channel_ids.len, &columns);
        _ = try createU32Index(std.testing.allocator, ".", table_name, 0, true);

        var row: [12]u8 = undefined;
        writeU32LE(&row, 0, 20);
        writeI64LE(&row, 4, 2200);
        const direct_update = try updateRawRowU32Key(std.testing.allocator, ".", table_name, 0, 20, &row);
        try std.testing.expectEqual(@as(u64, 3), direct_update.row_count);

        writeU32LE(&row, 0, 99);
        writeI64LE(&row, 4, 9900);
        try std.testing.expectError(TableError.NotFound, updateRawRowU32Key(std.testing.allocator, ".", table_name, 0, 99, &row));

        writeU32LE(&row, 0, 21);
        writeI64LE(&row, 4, 2100);
        try std.testing.expectError(TableError.InvalidFormat, updateRawRowU32Key(std.testing.allocator, ".", table_name, 0, 20, &row));

        writeU32LE(&row, 0, 10);
        writeI64LE(&row, 4, 1100);
        const direct_upsert_existing = try upsertRawRowU32Key(std.testing.allocator, ".", table_name, 0, 10, &row);
        try std.testing.expect(!direct_upsert_existing.inserted);

        writeU32LE(&row, 0, 40);
        writeI64LE(&row, 4, 4000);
        const direct_upsert_new = try upsertRawRowU32Key(std.testing.allocator, ".", table_name, 0, 40, &row);
        try std.testing.expect(direct_upsert_new.inserted);
        try std.testing.expectEqual(@as(u64, 4), direct_upsert_new.info.row_count);

        const direct_delete = try deleteU32Key(std.testing.allocator, ".", table_name, 0, 30);
        try std.testing.expectEqual(@as(u64, 3), direct_delete.row_count);
        try std.testing.expectError(TableError.NotFound, deleteU32Key(std.testing.allocator, ".", table_name, 0, 30));

        var tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
        writeU32LE(&row, 0, 20);
        writeI64LE(&row, 4, 2500);
        const tx_upsert_existing = try writeTransactionUpsertRawRowU32Key(tx, 0, 20, &row);
        try std.testing.expect(!tx_upsert_existing.inserted);

        writeU32LE(&row, 0, 99);
        writeI64LE(&row, 4, 9900);
        try std.testing.expectError(TableError.NotFound, writeTransactionUpdateRawRowU32Key(tx, 0, 99, &row));

        writeU32LE(&row, 0, 40);
        writeI64LE(&row, 4, 4400);
        _ = try writeTransactionUpdateRawRowU32Key(tx, 0, 40, &row);

        writeU32LE(&row, 0, 50);
        writeI64LE(&row, 4, 5000);
        const tx_upsert_new = try writeTransactionUpsertRawRowU32Key(tx, 0, 50, &row);
        try std.testing.expect(tx_upsert_new.inserted);
        _ = try writeTransactionDeleteU32Key(tx, 0, 10);

        const committed = try commitWriteTransaction(std.testing.allocator, tx);
        destroyWriteTransaction(std.testing.allocator, tx);
        try std.testing.expectEqual(@as(u64, 3), committed.row_count);

        tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
        writeU32LE(&row, 0, 99);
        writeI64LE(&row, 4, 9900);
        _ = try writeTransactionUpsertRawRowU32Key(tx, 0, 99, &row);
        destroyWriteTransaction(std.testing.allocator, tx);

        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 3), snapshot.row_count);
        const channel20 = try snapshotFindU32(snapshot, 0, 20);
        try std.testing.expect(channel20.found);
        try std.testing.expectEqual(@as(i64, 2500), try snapshotGetI64(snapshot, 1, channel20.row_index));
        const channel40 = try snapshotFindU32(snapshot, 0, 40);
        try std.testing.expect(channel40.found);
        try std.testing.expectEqual(@as(i64, 4400), try snapshotGetI64(snapshot, 1, channel40.row_index));
        const channel50 = try snapshotFindU32(snapshot, 0, 50);
        try std.testing.expect(channel50.found);
        try std.testing.expectEqual(@as(i64, 5000), try snapshotGetI64(snapshot, 1, channel50.row_index));
        const deleted = try snapshotFindU32(snapshot, 0, 10);
        try std.testing.expect(!deleted.found);
        const rolled_back = try snapshotFindU32(snapshot, 0, 99);
        try std.testing.expect(!rolled_back.found);
    }

    {
        const table_name = "i32_adjustment_totals";
        _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "i32_adjustment_totals.sadb-schema",
            \\#def MAX_ROWS = 8
            \\#def COL_ADJUSTMENT_STRIDE = 4 // i32
            \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64
        );

        var adjustments = [_]i32{ -5, 0, 10 };
        var totals = [_]i64{ 1000, 2000, 3000 };
        const columns = [_]RawColumnBytes{
            .{ .bytes = std.mem.sliceAsBytes(adjustments[0..]) },
            .{ .bytes = std.mem.sliceAsBytes(totals[0..]) },
        };
        _ = try ingestRawColumns(std.testing.allocator, ".", table_name, adjustments.len, &columns);
        _ = try createI32Index(std.testing.allocator, ".", table_name, 0, true);

        var row: [12]u8 = undefined;
        writeI32LE(&row, 0, 0);
        writeI64LE(&row, 4, 2100);
        const direct_update = try updateRawRowI32Key(std.testing.allocator, ".", table_name, 0, 0, &row);
        try std.testing.expectEqual(@as(u64, 3), direct_update.row_count);

        writeI32LE(&row, 0, 99);
        writeI64LE(&row, 4, 9900);
        try std.testing.expectError(TableError.NotFound, updateRawRowI32Key(std.testing.allocator, ".", table_name, 0, 99, &row));

        writeI32LE(&row, 0, 1);
        writeI64LE(&row, 4, 111);
        try std.testing.expectError(TableError.InvalidFormat, updateRawRowI32Key(std.testing.allocator, ".", table_name, 0, 0, &row));

        writeI32LE(&row, 0, -5);
        writeI64LE(&row, 4, 1100);
        const direct_upsert_existing = try upsertRawRowI32Key(std.testing.allocator, ".", table_name, 0, -5, &row);
        try std.testing.expect(!direct_upsert_existing.inserted);

        writeI32LE(&row, 0, -10);
        writeI64LE(&row, 4, 900);
        const direct_upsert_new = try upsertRawRowI32Key(std.testing.allocator, ".", table_name, 0, -10, &row);
        try std.testing.expect(direct_upsert_new.inserted);
        try std.testing.expectEqual(@as(u64, 4), direct_upsert_new.info.row_count);

        const direct_delete = try deleteI32Key(std.testing.allocator, ".", table_name, 0, 10);
        try std.testing.expectEqual(@as(u64, 3), direct_delete.row_count);
        try std.testing.expectError(TableError.NotFound, deleteI32Key(std.testing.allocator, ".", table_name, 0, 10));

        var tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
        writeI32LE(&row, 0, 0);
        writeI64LE(&row, 4, 2500);
        const tx_upsert_existing = try writeTransactionUpsertRawRowI32Key(tx, 0, 0, &row);
        try std.testing.expect(!tx_upsert_existing.inserted);

        writeI32LE(&row, 0, 99);
        writeI64LE(&row, 4, 9900);
        try std.testing.expectError(TableError.NotFound, writeTransactionUpdateRawRowI32Key(tx, 0, 99, &row));

        writeI32LE(&row, 0, -10);
        writeI64LE(&row, 4, 1000);
        _ = try writeTransactionUpdateRawRowI32Key(tx, 0, -10, &row);

        writeI32LE(&row, 0, 20);
        writeI64LE(&row, 4, 2000);
        const tx_upsert_new = try writeTransactionUpsertRawRowI32Key(tx, 0, 20, &row);
        try std.testing.expect(tx_upsert_new.inserted);
        _ = try writeTransactionDeleteI32Key(tx, 0, -5);

        const committed = try commitWriteTransaction(std.testing.allocator, tx);
        destroyWriteTransaction(std.testing.allocator, tx);
        try std.testing.expectEqual(@as(u64, 3), committed.row_count);

        tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
        writeI32LE(&row, 0, 99);
        writeI64LE(&row, 4, 9900);
        _ = try writeTransactionUpsertRawRowI32Key(tx, 0, 99, &row);
        destroyWriteTransaction(std.testing.allocator, tx);

        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 3), snapshot.row_count);
        const adj0 = try snapshotFindI32(snapshot, 0, 0);
        try std.testing.expect(adj0.found);
        try std.testing.expectEqual(@as(i64, 2500), try snapshotGetI64(snapshot, 1, adj0.row_index));
        const adj_neg10 = try snapshotFindI32(snapshot, 0, -10);
        try std.testing.expect(adj_neg10.found);
        try std.testing.expectEqual(@as(i64, 1000), try snapshotGetI64(snapshot, 1, adj_neg10.row_index));
        const adj20 = try snapshotFindI32(snapshot, 0, 20);
        try std.testing.expect(adj20.found);
        try std.testing.expectEqual(@as(i64, 2000), try snapshotGetI64(snapshot, 1, adj20.row_index));
        const deleted = try snapshotFindI32(snapshot, 0, -5);
        try std.testing.expect(!deleted.found);
        const rolled_back = try snapshotFindI32(snapshot, 0, 99);
        try std.testing.expect(!rolled_back.found);
    }
}

test "table u8 i8 u16 and i16 key row writes update upsert and delete" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    {
        const table_name = "u8_channel_totals";
        _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "u8_channel_totals.sadb-schema",
            \\#def MAX_ROWS = 8
            \\#def COL_CHANNEL_ID_STRIDE = 1 // u8
            \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64
        );

        var channel_ids = [_]u8{ 1, 2, 3 };
        var totals = [_]i64{ 1000, 2000, 3000 };
        const columns = [_]RawColumnBytes{
            .{ .bytes = std.mem.sliceAsBytes(channel_ids[0..]) },
            .{ .bytes = std.mem.sliceAsBytes(totals[0..]) },
        };
        _ = try ingestRawColumns(std.testing.allocator, ".", table_name, channel_ids.len, &columns);
        _ = try createU8Index(std.testing.allocator, ".", table_name, 0, true);

        var row: [9]u8 = undefined;
        writeU8(&row, 0, 2);
        writeI64LE(&row, 1, 2200);
        const direct_update = try updateRawRowU8Key(std.testing.allocator, ".", table_name, 0, 2, &row);
        try std.testing.expectEqual(@as(u64, 3), direct_update.row_count);

        writeU8(&row, 0, 9);
        writeI64LE(&row, 1, 9900);
        try std.testing.expectError(TableError.NotFound, updateRawRowU8Key(std.testing.allocator, ".", table_name, 0, 9, &row));

        writeU8(&row, 0, 4);
        writeI64LE(&row, 1, 400);
        try std.testing.expectError(TableError.InvalidFormat, updateRawRowU8Key(std.testing.allocator, ".", table_name, 0, 2, &row));

        writeU8(&row, 0, 1);
        writeI64LE(&row, 1, 1100);
        const direct_upsert_existing = try upsertRawRowU8Key(std.testing.allocator, ".", table_name, 0, 1, &row);
        try std.testing.expect(!direct_upsert_existing.inserted);

        writeU8(&row, 0, 4);
        writeI64LE(&row, 1, 4000);
        const direct_upsert_new = try upsertRawRowU8Key(std.testing.allocator, ".", table_name, 0, 4, &row);
        try std.testing.expect(direct_upsert_new.inserted);
        try std.testing.expectEqual(@as(u64, 4), direct_upsert_new.info.row_count);

        const direct_delete = try deleteU8Key(std.testing.allocator, ".", table_name, 0, 3);
        try std.testing.expectEqual(@as(u64, 3), direct_delete.row_count);
        try std.testing.expectError(TableError.NotFound, deleteU8Key(std.testing.allocator, ".", table_name, 0, 3));

        var tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
        writeU8(&row, 0, 2);
        writeI64LE(&row, 1, 2500);
        const tx_upsert_existing = try writeTransactionUpsertRawRowU8Key(tx, 0, 2, &row);
        try std.testing.expect(!tx_upsert_existing.inserted);

        writeU8(&row, 0, 9);
        writeI64LE(&row, 1, 9900);
        try std.testing.expectError(TableError.NotFound, writeTransactionUpdateRawRowU8Key(tx, 0, 9, &row));

        writeU8(&row, 0, 4);
        writeI64LE(&row, 1, 4400);
        _ = try writeTransactionUpdateRawRowU8Key(tx, 0, 4, &row);

        writeU8(&row, 0, 5);
        writeI64LE(&row, 1, 5000);
        const tx_upsert_new = try writeTransactionUpsertRawRowU8Key(tx, 0, 5, &row);
        try std.testing.expect(tx_upsert_new.inserted);
        _ = try writeTransactionDeleteU8Key(tx, 0, 1);

        const committed = try commitWriteTransaction(std.testing.allocator, tx);
        destroyWriteTransaction(std.testing.allocator, tx);
        try std.testing.expectEqual(@as(u64, 3), committed.row_count);

        tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
        writeU8(&row, 0, 9);
        writeI64LE(&row, 1, 9900);
        _ = try writeTransactionUpsertRawRowU8Key(tx, 0, 9, &row);
        destroyWriteTransaction(std.testing.allocator, tx);

        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 3), snapshot.row_count);
        const channel2 = try snapshotFindU8(snapshot, 0, 2);
        try std.testing.expect(channel2.found);
        try std.testing.expectEqual(@as(i64, 2500), try snapshotGetI64(snapshot, 1, channel2.row_index));
        const channel4 = try snapshotFindU8(snapshot, 0, 4);
        try std.testing.expect(channel4.found);
        try std.testing.expectEqual(@as(i64, 4400), try snapshotGetI64(snapshot, 1, channel4.row_index));
        const channel5 = try snapshotFindU8(snapshot, 0, 5);
        try std.testing.expect(channel5.found);
        try std.testing.expectEqual(@as(i64, 5000), try snapshotGetI64(snapshot, 1, channel5.row_index));
        try std.testing.expect(!(try snapshotFindU8(snapshot, 0, 1)).found);
        try std.testing.expect(!(try snapshotFindU8(snapshot, 0, 9)).found);
    }

    {
        const table_name = "i8_adjustment_totals";
        _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "i8_adjustment_totals.sadb-schema",
            \\#def MAX_ROWS = 8
            \\#def COL_ADJUSTMENT_STRIDE = 1 // i8
            \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64
        );

        var adjustments = [_]i8{ -5, 0, 10 };
        var totals = [_]i64{ 1000, 2000, 3000 };
        const columns = [_]RawColumnBytes{
            .{ .bytes = std.mem.sliceAsBytes(adjustments[0..]) },
            .{ .bytes = std.mem.sliceAsBytes(totals[0..]) },
        };
        _ = try ingestRawColumns(std.testing.allocator, ".", table_name, adjustments.len, &columns);
        _ = try createI8Index(std.testing.allocator, ".", table_name, 0, true);

        var row: [9]u8 = undefined;
        writeI8(&row, 0, 0);
        writeI64LE(&row, 1, 2100);
        const direct_update = try updateRawRowI8Key(std.testing.allocator, ".", table_name, 0, 0, &row);
        try std.testing.expectEqual(@as(u64, 3), direct_update.row_count);

        writeI8(&row, 0, 99);
        writeI64LE(&row, 1, 9900);
        try std.testing.expectError(TableError.NotFound, updateRawRowI8Key(std.testing.allocator, ".", table_name, 0, 99, &row));

        writeI8(&row, 0, 1);
        writeI64LE(&row, 1, 111);
        try std.testing.expectError(TableError.InvalidFormat, updateRawRowI8Key(std.testing.allocator, ".", table_name, 0, 0, &row));

        writeI8(&row, 0, -5);
        writeI64LE(&row, 1, 1100);
        const direct_upsert_existing = try upsertRawRowI8Key(std.testing.allocator, ".", table_name, 0, -5, &row);
        try std.testing.expect(!direct_upsert_existing.inserted);

        writeI8(&row, 0, -10);
        writeI64LE(&row, 1, 900);
        const direct_upsert_new = try upsertRawRowI8Key(std.testing.allocator, ".", table_name, 0, -10, &row);
        try std.testing.expect(direct_upsert_new.inserted);
        try std.testing.expectEqual(@as(u64, 4), direct_upsert_new.info.row_count);

        const direct_delete = try deleteI8Key(std.testing.allocator, ".", table_name, 0, 10);
        try std.testing.expectEqual(@as(u64, 3), direct_delete.row_count);
        try std.testing.expectError(TableError.NotFound, deleteI8Key(std.testing.allocator, ".", table_name, 0, 10));

        var tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
        writeI8(&row, 0, 0);
        writeI64LE(&row, 1, 2500);
        const tx_upsert_existing = try writeTransactionUpsertRawRowI8Key(tx, 0, 0, &row);
        try std.testing.expect(!tx_upsert_existing.inserted);

        writeI8(&row, 0, 99);
        writeI64LE(&row, 1, 9900);
        try std.testing.expectError(TableError.NotFound, writeTransactionUpdateRawRowI8Key(tx, 0, 99, &row));

        writeI8(&row, 0, -10);
        writeI64LE(&row, 1, 1000);
        _ = try writeTransactionUpdateRawRowI8Key(tx, 0, -10, &row);

        writeI8(&row, 0, 20);
        writeI64LE(&row, 1, 2000);
        const tx_upsert_new = try writeTransactionUpsertRawRowI8Key(tx, 0, 20, &row);
        try std.testing.expect(tx_upsert_new.inserted);
        _ = try writeTransactionDeleteI8Key(tx, 0, -5);

        const committed = try commitWriteTransaction(std.testing.allocator, tx);
        destroyWriteTransaction(std.testing.allocator, tx);
        try std.testing.expectEqual(@as(u64, 3), committed.row_count);

        tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
        writeI8(&row, 0, 99);
        writeI64LE(&row, 1, 9900);
        _ = try writeTransactionUpsertRawRowI8Key(tx, 0, 99, &row);
        destroyWriteTransaction(std.testing.allocator, tx);

        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 3), snapshot.row_count);
        const adj0 = try snapshotFindI8(snapshot, 0, 0);
        try std.testing.expect(adj0.found);
        try std.testing.expectEqual(@as(i64, 2500), try snapshotGetI64(snapshot, 1, adj0.row_index));
        const adj_neg10 = try snapshotFindI8(snapshot, 0, -10);
        try std.testing.expect(adj_neg10.found);
        try std.testing.expectEqual(@as(i64, 1000), try snapshotGetI64(snapshot, 1, adj_neg10.row_index));
        const adj20 = try snapshotFindI8(snapshot, 0, 20);
        try std.testing.expect(adj20.found);
        try std.testing.expectEqual(@as(i64, 2000), try snapshotGetI64(snapshot, 1, adj20.row_index));
        try std.testing.expect(!(try snapshotFindI8(snapshot, 0, -5)).found);
        try std.testing.expect(!(try snapshotFindI8(snapshot, 0, 99)).found);
    }

    {
        const table_name = "u16_channel_totals";
        _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "u16_channel_totals.sadb-schema",
            \\#def MAX_ROWS = 8
            \\#def COL_CHANNEL_ID_STRIDE = 2 // u16
            \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64
        );

        var channel_ids = [_]u16{ 100, 200, 300 };
        var totals = [_]i64{ 1000, 2000, 3000 };
        const columns = [_]RawColumnBytes{
            .{ .bytes = std.mem.sliceAsBytes(channel_ids[0..]) },
            .{ .bytes = std.mem.sliceAsBytes(totals[0..]) },
        };
        _ = try ingestRawColumns(std.testing.allocator, ".", table_name, channel_ids.len, &columns);
        _ = try createU16Index(std.testing.allocator, ".", table_name, 0, true);

        var row: [10]u8 = undefined;
        writeU16LE(&row, 0, 200);
        writeI64LE(&row, 2, 2200);
        const direct_update = try updateRawRowU16Key(std.testing.allocator, ".", table_name, 0, 200, &row);
        try std.testing.expectEqual(@as(u64, 3), direct_update.row_count);

        writeU16LE(&row, 0, 999);
        writeI64LE(&row, 2, 9900);
        try std.testing.expectError(TableError.NotFound, updateRawRowU16Key(std.testing.allocator, ".", table_name, 0, 999, &row));

        writeU16LE(&row, 0, 201);
        writeI64LE(&row, 2, 2010);
        try std.testing.expectError(TableError.InvalidFormat, updateRawRowU16Key(std.testing.allocator, ".", table_name, 0, 200, &row));

        writeU16LE(&row, 0, 100);
        writeI64LE(&row, 2, 1100);
        const direct_upsert_existing = try upsertRawRowU16Key(std.testing.allocator, ".", table_name, 0, 100, &row);
        try std.testing.expect(!direct_upsert_existing.inserted);

        writeU16LE(&row, 0, 400);
        writeI64LE(&row, 2, 4000);
        const direct_upsert_new = try upsertRawRowU16Key(std.testing.allocator, ".", table_name, 0, 400, &row);
        try std.testing.expect(direct_upsert_new.inserted);
        try std.testing.expectEqual(@as(u64, 4), direct_upsert_new.info.row_count);

        const direct_delete = try deleteU16Key(std.testing.allocator, ".", table_name, 0, 300);
        try std.testing.expectEqual(@as(u64, 3), direct_delete.row_count);
        try std.testing.expectError(TableError.NotFound, deleteU16Key(std.testing.allocator, ".", table_name, 0, 300));

        var tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
        writeU16LE(&row, 0, 200);
        writeI64LE(&row, 2, 2500);
        const tx_upsert_existing = try writeTransactionUpsertRawRowU16Key(tx, 0, 200, &row);
        try std.testing.expect(!tx_upsert_existing.inserted);

        writeU16LE(&row, 0, 999);
        writeI64LE(&row, 2, 9900);
        try std.testing.expectError(TableError.NotFound, writeTransactionUpdateRawRowU16Key(tx, 0, 999, &row));

        writeU16LE(&row, 0, 400);
        writeI64LE(&row, 2, 4400);
        _ = try writeTransactionUpdateRawRowU16Key(tx, 0, 400, &row);

        writeU16LE(&row, 0, 500);
        writeI64LE(&row, 2, 5000);
        const tx_upsert_new = try writeTransactionUpsertRawRowU16Key(tx, 0, 500, &row);
        try std.testing.expect(tx_upsert_new.inserted);
        _ = try writeTransactionDeleteU16Key(tx, 0, 100);

        const committed = try commitWriteTransaction(std.testing.allocator, tx);
        destroyWriteTransaction(std.testing.allocator, tx);
        try std.testing.expectEqual(@as(u64, 3), committed.row_count);

        tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
        writeU16LE(&row, 0, 999);
        writeI64LE(&row, 2, 9900);
        _ = try writeTransactionUpsertRawRowU16Key(tx, 0, 999, &row);
        destroyWriteTransaction(std.testing.allocator, tx);

        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 3), snapshot.row_count);
        const channel200 = try snapshotFindU16(snapshot, 0, 200);
        try std.testing.expect(channel200.found);
        try std.testing.expectEqual(@as(i64, 2500), try snapshotGetI64(snapshot, 1, channel200.row_index));
        const channel400 = try snapshotFindU16(snapshot, 0, 400);
        try std.testing.expect(channel400.found);
        try std.testing.expectEqual(@as(i64, 4400), try snapshotGetI64(snapshot, 1, channel400.row_index));
        const channel500 = try snapshotFindU16(snapshot, 0, 500);
        try std.testing.expect(channel500.found);
        try std.testing.expectEqual(@as(i64, 5000), try snapshotGetI64(snapshot, 1, channel500.row_index));
        try std.testing.expect(!(try snapshotFindU16(snapshot, 0, 100)).found);
        try std.testing.expect(!(try snapshotFindU16(snapshot, 0, 999)).found);
    }

    {
        const table_name = "i16_adjustment_totals";
        _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "i16_adjustment_totals.sadb-schema",
            \\#def MAX_ROWS = 8
            \\#def COL_ADJUSTMENT_STRIDE = 2 // i16
            \\#def COL_TOTAL_CENTS_STRIDE = 8 // i64
        );

        var adjustments = [_]i16{ -100, 0, 100 };
        var totals = [_]i64{ 1000, 2000, 3000 };
        const columns = [_]RawColumnBytes{
            .{ .bytes = std.mem.sliceAsBytes(adjustments[0..]) },
            .{ .bytes = std.mem.sliceAsBytes(totals[0..]) },
        };
        _ = try ingestRawColumns(std.testing.allocator, ".", table_name, adjustments.len, &columns);
        _ = try createI16Index(std.testing.allocator, ".", table_name, 0, true);

        var row: [10]u8 = undefined;
        writeI16LE(&row, 0, 0);
        writeI64LE(&row, 2, 2100);
        const direct_update = try updateRawRowI16Key(std.testing.allocator, ".", table_name, 0, 0, &row);
        try std.testing.expectEqual(@as(u64, 3), direct_update.row_count);

        writeI16LE(&row, 0, 999);
        writeI64LE(&row, 2, 9900);
        try std.testing.expectError(TableError.NotFound, updateRawRowI16Key(std.testing.allocator, ".", table_name, 0, 999, &row));

        writeI16LE(&row, 0, 1);
        writeI64LE(&row, 2, 111);
        try std.testing.expectError(TableError.InvalidFormat, updateRawRowI16Key(std.testing.allocator, ".", table_name, 0, 0, &row));

        writeI16LE(&row, 0, -100);
        writeI64LE(&row, 2, 1100);
        const direct_upsert_existing = try upsertRawRowI16Key(std.testing.allocator, ".", table_name, 0, -100, &row);
        try std.testing.expect(!direct_upsert_existing.inserted);

        writeI16LE(&row, 0, -200);
        writeI64LE(&row, 2, 900);
        const direct_upsert_new = try upsertRawRowI16Key(std.testing.allocator, ".", table_name, 0, -200, &row);
        try std.testing.expect(direct_upsert_new.inserted);
        try std.testing.expectEqual(@as(u64, 4), direct_upsert_new.info.row_count);

        const direct_delete = try deleteI16Key(std.testing.allocator, ".", table_name, 0, 100);
        try std.testing.expectEqual(@as(u64, 3), direct_delete.row_count);
        try std.testing.expectError(TableError.NotFound, deleteI16Key(std.testing.allocator, ".", table_name, 0, 100));

        var tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
        writeI16LE(&row, 0, 0);
        writeI64LE(&row, 2, 2500);
        const tx_upsert_existing = try writeTransactionUpsertRawRowI16Key(tx, 0, 0, &row);
        try std.testing.expect(!tx_upsert_existing.inserted);

        writeI16LE(&row, 0, 999);
        writeI64LE(&row, 2, 9900);
        try std.testing.expectError(TableError.NotFound, writeTransactionUpdateRawRowI16Key(tx, 0, 999, &row));

        writeI16LE(&row, 0, -200);
        writeI64LE(&row, 2, 1000);
        _ = try writeTransactionUpdateRawRowI16Key(tx, 0, -200, &row);

        writeI16LE(&row, 0, 200);
        writeI64LE(&row, 2, 2000);
        const tx_upsert_new = try writeTransactionUpsertRawRowI16Key(tx, 0, 200, &row);
        try std.testing.expect(tx_upsert_new.inserted);
        _ = try writeTransactionDeleteI16Key(tx, 0, -100);

        const committed = try commitWriteTransaction(std.testing.allocator, tx);
        destroyWriteTransaction(std.testing.allocator, tx);
        try std.testing.expectEqual(@as(u64, 3), committed.row_count);

        tx = try beginWriteTransaction(std.testing.allocator, ".", table_name);
        writeI16LE(&row, 0, 999);
        writeI64LE(&row, 2, 9900);
        _ = try writeTransactionUpsertRawRowI16Key(tx, 0, 999, &row);
        destroyWriteTransaction(std.testing.allocator, tx);

        const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
        defer snapshot.destroy();
        try std.testing.expectEqual(@as(u64, 3), snapshot.row_count);
        const adj0 = try snapshotFindI16(snapshot, 0, 0);
        try std.testing.expect(adj0.found);
        try std.testing.expectEqual(@as(i64, 2500), try snapshotGetI64(snapshot, 1, adj0.row_index));
        const adj_neg200 = try snapshotFindI16(snapshot, 0, -200);
        try std.testing.expect(adj_neg200.found);
        try std.testing.expectEqual(@as(i64, 1000), try snapshotGetI64(snapshot, 1, adj_neg200.row_index));
        const adj200 = try snapshotFindI16(snapshot, 0, 200);
        try std.testing.expect(adj200.found);
        try std.testing.expectEqual(@as(i64, 2000), try snapshotGetI64(snapshot, 1, adj200.row_index));
        try std.testing.expect(!(try snapshotFindI16(snapshot, 0, -100)).found);
        try std.testing.expect(!(try snapshotFindI16(snapshot, 0, 999)).found);
    }
}

test "table gets full rows by typed unique keys" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "typed_key_rows";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "typed_key_rows.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_I64_KEY_STRIDE = 8 // i64
        \\#def COL_U32_KEY_STRIDE = 4 // u32
        \\#def COL_I32_KEY_STRIDE = 4 // i32
        \\#def COL_U8_KEY_STRIDE = 1 // u8
        \\#def COL_I8_KEY_STRIDE = 1 // i8
        \\#def COL_U16_KEY_STRIDE = 2 // u16
        \\#def COL_I16_KEY_STRIDE = 2 // i16
        \\#def COL_TOTAL_STRIDE = 8 // i64
    );

    var i64_keys = [_]i64{ -10, 0, 10 };
    var u32_keys = [_]u32{ 100, 200, 300 };
    var i32_keys = [_]i32{ -3, 0, 3 };
    var u8_keys = [_]u8{ 1, 2, 3 };
    var i8_keys = [_]i8{ -1, 0, 1 };
    var u16_keys = [_]u16{ 1000, 2000, 3000 };
    var i16_keys = [_]i16{ -100, 0, 100 };
    var totals = [_]i64{ 111, 222, 333 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(i64_keys[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(u32_keys[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(i32_keys[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(u8_keys[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(i8_keys[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(u16_keys[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(i16_keys[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(totals[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, i64_keys.len, &columns);
    _ = try createI64Index(std.testing.allocator, ".", table_name, 0, true);
    _ = try createU32Index(std.testing.allocator, ".", table_name, 1, true);
    _ = try createI32Index(std.testing.allocator, ".", table_name, 2, true);
    _ = try createU8Index(std.testing.allocator, ".", table_name, 3, true);
    _ = try createI8Index(std.testing.allocator, ".", table_name, 4, true);
    _ = try createU16Index(std.testing.allocator, ".", table_name, 5, true);
    _ = try createI16Index(std.testing.allocator, ".", table_name, 6, true);

    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();
    var row: [30]u8 = undefined;

    try snapshotGetRowI64Key(snapshot, 0, 0, &row);
    try std.testing.expectEqual(@as(i64, 222), readI64LE(&row, 22));
    try snapshotGetRowU32Key(snapshot, 1, 300, &row);
    try std.testing.expectEqual(@as(i64, 333), readI64LE(&row, 22));
    try snapshotGetRowI32Key(snapshot, 2, -3, &row);
    try std.testing.expectEqual(@as(i64, 111), readI64LE(&row, 22));
    try snapshotGetRowU8Key(snapshot, 3, 2, &row);
    try std.testing.expectEqual(@as(i64, 222), readI64LE(&row, 22));
    try snapshotGetRowI8Key(snapshot, 4, 1, &row);
    try std.testing.expectEqual(@as(i64, 333), readI64LE(&row, 22));
    try snapshotGetRowU16Key(snapshot, 5, 1000, &row);
    try std.testing.expectEqual(@as(i64, 111), readI64LE(&row, 22));
    try snapshotGetRowI16Key(snapshot, 6, 0, &row);
    try std.testing.expectEqual(@as(i64, 222), readI64LE(&row, 22));

    try std.testing.expectError(TableError.NotFound, snapshotGetRowI64Key(snapshot, 0, 99, &row));
    var short_row: [29]u8 = undefined;
    try std.testing.expectError(TableError.InvalidFormat, snapshotGetRowU32Key(snapshot, 1, 200, &short_row));

    const non_unique_name = "typed_key_rows_non_unique";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "typed_key_rows_non_unique.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_U8_KEY_STRIDE = 1 // u8
        \\#def COL_TOTAL_STRIDE = 8 // i64
    );
    var duplicate_u8 = [_]u8{ 1, 1, 2 };
    var duplicate_totals = [_]i64{ 10, 20, 30 };
    const non_unique_columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(duplicate_u8[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(duplicate_totals[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", non_unique_name, duplicate_u8.len, &non_unique_columns);
    _ = try createU8Index(std.testing.allocator, ".", non_unique_name, 0, false);
    const non_unique_snapshot = try openReadSnapshot(std.testing.allocator, ".", non_unique_name);
    defer non_unique_snapshot.destroy();
    var non_unique_row: [9]u8 = undefined;
    try std.testing.expectError(TableError.InvalidFormat, snapshotGetRowU8Key(non_unique_snapshot, 0, 1, &non_unique_row));
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

test "table exports packed null bitmap from logical null_bitmap column" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const table_name = "packed_null_bitmap";
    _ = try initTableFromSchemaBytes(std.testing.allocator, ".", "packed_null_bitmap.sadb-schema",
        \\#def MAX_ROWS = 8
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_AMOUNT_STRIDE = 8 // i64 decimal(2) nullable
        \\#def COL_AMOUNT_NULLS_STRIDE = 1 // u8 null_bitmap
    );

    var ids = [_]u64{ 1, 2, 3, 4 };
    var amounts = [_]i64{ 1000, 2000, 3000, 4000 };
    var amount_nulls = [_]u8{ 0, 1, 0, 1 };
    const columns = [_]RawColumnBytes{
        .{ .bytes = std.mem.sliceAsBytes(ids[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(amounts[0..]) },
        .{ .bytes = std.mem.sliceAsBytes(amount_nulls[0..]) },
    };
    _ = try ingestRawColumns(std.testing.allocator, ".", table_name, ids.len, &columns);
    _ = try createI64Index(std.testing.allocator, ".", table_name, 1, false);

    const snapshot = try openReadSnapshot(std.testing.allocator, ".", table_name);
    defer snapshot.destroy();

    const amount_logical = try snapshotColumnLogicalInfo(snapshot, 1);
    try std.testing.expectEqual(@as(u64, schema.LOGICAL_DECIMAL_I64), amount_logical.logical_type);
    try std.testing.expectEqual(@as(u64, 1), amount_logical.nullable);
    const nulls_logical = try snapshotColumnLogicalInfo(snapshot, 2);
    try std.testing.expectEqual(@as(u64, schema.LOGICAL_NULL_BITMAP), nulls_logical.logical_type);
    try std.testing.expectEqual(@as(u64, 0), nulls_logical.nullable);

    var exported = [_]u8{0};
    const result = try snapshotExportNullBitmap(snapshot, 2, &exported);
    try std.testing.expectEqual(@as(u64, 1), result.written_bytes);
    try std.testing.expectEqual(@as(u64, 4), result.row_count);
    try std.testing.expectEqual(@as(u8, 0b00001010), exported[0]);

    var rows = [_]u64{ 99, 99, 99, 99 };
    const filtered = try snapshotRangeI64RowsNullBitmap(snapshot, 1, 0, 5000, &exported, true, 0, rows.len, &rows);
    try std.testing.expectEqual(@as(u64, 2), filtered.total);
    try std.testing.expectEqual(@as(u64, 2), filtered.written);
    try std.testing.expectEqual(@as(u64, 1), rows[0]);
    try std.testing.expectEqual(@as(u64, 3), rows[1]);

    var too_small = [_]u8{};
    try std.testing.expectError(TableError.CursorOverflow, snapshotExportNullBitmap(snapshot, 2, &too_small));
    try std.testing.expectError(TableError.InvalidFormat, snapshotExportNullBitmap(snapshot, 1, &exported));
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

    const source = try readActiveMetaSource(std.testing.allocator, ".", table_name);
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
