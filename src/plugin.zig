const std = @import("std");
const plugin = @import("plugin_api");
const qmod = @import("db_stub.zig");
const schema = @import("schema.zig");
const table = @import("table.zig");
pub usingnamespace @import("db_saasm_api.zig");

const skills = [_]plugin.SkillSection{
    .{
        .name = "database",
        .summary = "Standalone DB schema bootstrap and table helpers",
        .items = &.{
            "db init <schema.sadb-schema>",
            "db register <query.sa>",
            "db exec <hash> [--params <file>]",
            "db ingest <table> <csv|jsonl>",
            "db inspect <table|hash>",
            "db status <table>",
            "db snapshot <table>",
            "db restore <table> <epoch>",
            "db verify <table>",
            "db compact <table>",
            "db lock <table>",
            "db unlock <table>",
        },
    },
};

fn isDbCliError(err: anyerror) bool {
    return switch (err) {
        error.MissingSourcePath,
        error.UnexpectedArgument,
        error.InvalidPath,
        error.FileNotFound,
        error.NotDir,
        error.AccessDenied,
        error.InvalidFormat,
        error.InvalidQueryHash,
        error.QueryRegistryCorrupted,
        error.QueryPayloadCorrupted,
        error.InvalidParams,
        error.SchemaMismatch,
        error.ColumnTypeMismatch,
        error.SnapshotCorrupted,
        error.Locked,
        error.CursorOverflow,
        error.SnapshotMissing,
        error.VerifyFailed,
        error.QueryHashUnknown,
        error.DuplicateRegister,
        error.DbCapabilityEscalation,
        error.UnsupportedOperation,
        error.StaleMetadata,
        error.OutOfMemory,
        => true,
        else => false,
    };
}

fn dbCliHint(argv: []const []const u8, err: anyerror) []const u8 {
    const sub = if (argv.len >= 3) argv[2] else "";
    return switch (err) {
        error.MissingSourcePath => if (sub.len == 0)
            "usage: sa db <init|register|exec|ingest|inspect|status|snapshot|restore|verify|compact|lock|unlock> ..."
        else if (std.mem.eql(u8, sub, "init"))
            "usage: sa db init <schema.sadb-schema>"
        else if (std.mem.eql(u8, sub, "register"))
            "usage: sa db register <query.sa>"
        else if (std.mem.eql(u8, sub, "exec"))
            "usage: sa db exec <hash> [--params <file>]"
        else if (std.mem.eql(u8, sub, "ingest"))
            "usage: sa db ingest <table> <csv|jsonl>"
        else if (std.mem.eql(u8, sub, "restore"))
            "usage: sa db restore <table> <epoch>"
        else
            "usage: sa db <init|register|exec|ingest|inspect|status|snapshot|restore|verify|compact|lock|unlock> ...",
        error.UnexpectedArgument => "remove the extra DB argument",
        error.InvalidPath => "check the DB schema or table path",
        error.FileNotFound, error.NotDir => "check that the DB schema file exists",
        error.AccessDenied => "check filesystem permissions for the DB path",
        error.InvalidFormat => "check the DB schema format",
        error.InvalidQueryHash => "use a 64-character hexadecimal DB query hash",
        error.QueryRegistryCorrupted => "re-register the query or repair the corrupted DB qmod registry metadata",
        error.QueryPayloadCorrupted => "re-register the query or restore the corrupted DB qmod payload",
        error.InvalidParams => "check params.bin layout and byte length",
        error.SchemaMismatch => "refresh or restore the table schema before running this query",
        error.ColumnTypeMismatch => "use a u64 DB column for this atomic or typed DB operation",
        error.SnapshotCorrupted => "verify, restore, or rebuild the corrupted table snapshot before exec",
        error.Locked => "unlock or restore the table before writing",
        error.CursorOverflow => "reduce input rows or increase MAX_ROWS",
        error.SnapshotMissing => "check the requested snapshot epoch",
        error.VerifyFailed => "table segment or schema hash verification failed",
        error.QueryHashUnknown => "register the query hash before exec or inspect",
        error.DuplicateRegister => "keep the original source path, grants, and entrypoint for this registered hash",
        error.DbCapabilityEscalation => "add explicit db_read/db_write/db_atomic_cursor grants for the query instructions",
        error.StaleMetadata => "retry the DB operation after refreshing table metadata",
        error.UnsupportedOperation => "this DB operation is not implemented yet",
        error.OutOfMemory => "free memory and retry",
        else => "check DB command arguments",
    };
}

fn writeDbCliError(writer: std.io.AnyWriter, argv: []const []const u8, err: anyerror) !void {
    const message = switch (err) {
        error.MissingSourcePath => "missing required DB operand",
        error.UnexpectedArgument => "unexpected DB argument",
        error.InvalidPath => "invalid DB path",
        error.FileNotFound => "DB path not found",
        error.NotDir => "DB path is not a directory",
        error.AccessDenied => "DB path access denied",
        error.InvalidFormat => "invalid DB schema format",
        error.InvalidQueryHash => "invalid DB query hash",
        error.QueryRegistryCorrupted => "DB query registry metadata is corrupted",
        error.QueryPayloadCorrupted => "DB query payload is corrupted",
        error.InvalidParams => "invalid DB params format",
        error.SchemaMismatch => "DB schema hash mismatch",
        error.ColumnTypeMismatch => "DB column type mismatch",
        error.SnapshotCorrupted => "DB snapshot is corrupted",
        error.Locked => "DB table is locked",
        error.CursorOverflow => "DB table cursor overflow",
        error.SnapshotMissing => "DB snapshot not found",
        error.VerifyFailed => "DB verification failed",
        error.QueryHashUnknown => "DB query hash is unknown",
        error.DuplicateRegister => "DB query hash is already registered with different metadata",
        error.DbCapabilityEscalation => "DB query capability escalation",
        error.StaleMetadata => "DB table metadata changed during exec",
        error.UnsupportedOperation => "DB operation is not implemented",
        error.OutOfMemory => "out of memory while processing DB command",
        else => @errorName(err),
    };
    try writer.print("error[SA-DB-CLI]: {s}\n", .{message});
    try writer.print("  help: {s}\n", .{dbCliHint(argv, err)});
}

fn runDbInit(allocator: std.mem.Allocator, argv: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) anyerror!?u8 {
    _ = stderr;
    if (argv.len < 4) return error.MissingSourcePath;
    if (argv.len > 4) return error.UnexpectedArgument;

    const source_path = argv[3];
    const source = std.fs.cwd().readFileAlloc(allocator, source_path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        error.IsDir => return error.NotDir,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPath,
    };
    defer allocator.free(source);

    var parsed = schema.compile(allocator, source, source_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidFormat,
    };
    defer parsed.deinit();

    const iface_path = try schema.ifaceFilePath(allocator, source_path);
    defer allocator.free(iface_path);

    var file = std.fs.cwd().createFile(iface_path, .{ .truncate = true }) catch |err| switch (err) {
        error.PathAlreadyExists => unreachable,
        error.AccessDenied => return error.AccessDenied,
        error.IsDir => return error.InvalidPath,
        else => return error.InvalidPath,
    };
    defer file.close();
    try schema.writeIface(file.writer(), parsed);
    try stdout.print("{s}\n", .{iface_path});
    return 0;
}

fn mapTableError(err: table.TableError) anyerror {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidFormat => error.InvalidFormat,
        error.InvalidPath => error.InvalidPath,
        error.NotFound => error.FileNotFound,
        error.Locked => error.Locked,
        error.CursorOverflow => error.CursorOverflow,
        error.SnapshotMissing => error.SnapshotMissing,
        error.VerifyFailed => error.VerifyFailed,
    };
}

fn mapQmodError(err: qmod.ExecError) anyerror {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidFormat => error.InvalidFormat,
        error.InvalidQueryHash => error.InvalidQueryHash,
        error.QueryRegistryCorrupted => error.QueryRegistryCorrupted,
        error.QueryPayloadCorrupted => error.QueryPayloadCorrupted,
        error.InvalidParams => error.InvalidParams,
        error.SchemaMismatch => error.SchemaMismatch,
        error.ColumnTypeMismatch => error.ColumnTypeMismatch,
        error.SnapshotCorrupted => error.SnapshotCorrupted,
        error.InvalidPath => error.InvalidPath,
        error.FileNotFound => error.FileNotFound,
        error.QueryHashUnknown => error.QueryHashUnknown,
        error.DuplicateRegister => error.DuplicateRegister,
        error.DbCapabilityEscalation => error.DbCapabilityEscalation,
        error.Locked => error.Locked,
        error.StaleMetadata => error.StaleMetadata,
        error.UnsupportedOperation => error.UnsupportedOperation,
    };
}

fn writeHash(writer: std.io.AnyWriter, hash: [32]u8) !void {
    const hex = std.fmt.bytesToHex(hash, .lower);
    try writer.writeAll(hex[0..]);
}

fn isHashText(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn isHashLength(text: []const u8) bool {
    return text.len == 64;
}

fn printInfo(stdout: std.io.AnyWriter, info: table.TableInfo) !void {
    try stdout.print("row_count: {d}\nsegment_count: {d}\nepoch: {d}\nlocked: {s}\n", .{
        info.row_count,
        info.segment_count,
        info.epoch,
        if (info.locked) "true" else "false",
    });
}

fn loadInfo(allocator: std.mem.Allocator, table_name: []const u8) anyerror!table.TableInfo {
    return table.verifyTable(allocator, ".", table_name) catch |err| return mapTableError(err);
}

fn runDbRegister(allocator: std.mem.Allocator, argv: []const []const u8, stdout: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 4) return error.MissingSourcePath;
    if (argv.len > 4) return error.UnexpectedArgument;
    var result = qmod.registerQuery(allocator, argv[3]) catch |err| return mapQmodError(err);
    defer result.deinit(allocator);
    try stdout.print("Compiled: {s}\nHash: ", .{result.source_path});
    try writeHash(stdout, result.hash);
    try stdout.print("\nRegistered: {s}\nimports: {d}\ngrants: {d}\n", .{ result.qmod_path, result.imports, result.grants });
    return 0;
}

fn runDbExec(allocator: std.mem.Allocator, argv: []const []const u8, stdout: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 4) return error.MissingSourcePath;
    var params_path: ?[]const u8 = null;
    if (argv.len == 6) {
        if (!std.mem.eql(u8, argv[4], "--params")) return error.UnexpectedArgument;
        params_path = argv[5];
    } else if (argv.len != 4) return error.UnexpectedArgument;
    var result = qmod.execQuery(allocator, argv[3], params_path) catch |err| return mapQmodError(err);
    defer result.deinit(allocator);
    switch (result) {
        .ok => |ok| {
            if (ok.code == 0) {
                try stdout.print("Executed: {s}\n", .{ok.function_name});
                if (ok.result_u64) |value| try stdout.print("result_u64: {d}\n", .{value});
            }
            return ok.code;
        },
    }
}

fn runDbIngest(allocator: std.mem.Allocator, argv: []const []const u8, stdout: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 5) return error.MissingSourcePath;
    if (argv.len > 5) return error.UnexpectedArgument;
    const info = table.ingestTable(allocator, ".", argv[3], argv[4]) catch |err| return mapTableError(err);
    try printInfo(stdout, info);
    return 0;
}

fn runDbInspect(allocator: std.mem.Allocator, argv: []const []const u8, stdout: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 4) return error.MissingSourcePath;
    if (argv.len > 4) return error.UnexpectedArgument;
    if (isHashText(argv[3])) {
        const text = qmod.inspectRegistry(allocator, argv[3]) catch |err| return mapQmodError(err);
        defer allocator.free(text);
        try stdout.writeAll(text);
        return 0;
    }
    if (isHashLength(argv[3])) return error.InvalidQueryHash;
    const info = try loadInfo(allocator, argv[3]);
    try printInfo(stdout, info);
    return 0;
}

fn runDbSnapshot(allocator: std.mem.Allocator, argv: []const []const u8, stdout: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 4) return error.MissingSourcePath;
    if (argv.len > 4) return error.UnexpectedArgument;
    const info = table.snapshotTable(allocator, ".", argv[3]) catch |err| return mapTableError(err);
    try printInfo(stdout, info);
    return 0;
}

fn runDbRestore(allocator: std.mem.Allocator, argv: []const []const u8, stdout: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 5) return error.MissingSourcePath;
    if (argv.len > 5) return error.UnexpectedArgument;
    const epoch = std.fmt.parseInt(u64, argv[4], 10) catch return error.InvalidFormat;
    const info = table.restoreTable(allocator, ".", argv[3], epoch) catch |err| return mapTableError(err);
    try printInfo(stdout, info);
    return 0;
}

fn runDbVerify(allocator: std.mem.Allocator, argv: []const []const u8, stdout: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 4) return error.MissingSourcePath;
    if (argv.len > 4) return error.UnexpectedArgument;
    const info = table.verifyTable(allocator, ".", argv[3]) catch |err| return mapTableError(err);
    try printInfo(stdout, info);
    return 0;
}

fn runDbCompact(allocator: std.mem.Allocator, argv: []const []const u8, stdout: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 4) return error.MissingSourcePath;
    if (argv.len > 4) return error.UnexpectedArgument;
    const info = table.compactTable(allocator, ".", argv[3]) catch |err| return mapTableError(err);
    try printInfo(stdout, info);
    return 0;
}

fn runDbLock(allocator: std.mem.Allocator, argv: []const []const u8, stdout: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 4) return error.MissingSourcePath;
    if (argv.len > 4) return error.UnexpectedArgument;
    const info = table.lockTable(allocator, ".", argv[3]) catch |err| return mapTableError(err);
    try printInfo(stdout, info);
    return 0;
}

fn runDbUnlock(allocator: std.mem.Allocator, argv: []const []const u8, stdout: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 4) return error.MissingSourcePath;
    if (argv.len > 4) return error.UnexpectedArgument;
    const info = table.unlockTable(allocator, ".", argv[3]) catch |err| return mapTableError(err);
    try printInfo(stdout, info);
    return 0;
}

fn runDbCommandImpl(allocator: std.mem.Allocator, argv: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 2) return null;
    if (!std.mem.eql(u8, argv[1], "db")) return null;
    if (argv.len < 3) return error.MissingSourcePath;

    const sub = argv[2];
    if (std.mem.eql(u8, sub, "init")) {
        return try runDbInit(allocator, argv, stdout, stderr);
    }
    if (std.mem.eql(u8, sub, "register")) return try runDbRegister(allocator, argv, stdout);
    if (std.mem.eql(u8, sub, "exec")) return try runDbExec(allocator, argv, stdout);
    if (std.mem.eql(u8, sub, "ingest")) return try runDbIngest(allocator, argv, stdout);
    if (std.mem.eql(u8, sub, "inspect") or std.mem.eql(u8, sub, "status")) return try runDbInspect(allocator, argv, stdout);
    if (std.mem.eql(u8, sub, "snapshot")) return try runDbSnapshot(allocator, argv, stdout);
    if (std.mem.eql(u8, sub, "restore")) return try runDbRestore(allocator, argv, stdout);
    if (std.mem.eql(u8, sub, "verify")) return try runDbVerify(allocator, argv, stdout);
    if (std.mem.eql(u8, sub, "compact")) return try runDbCompact(allocator, argv, stdout);
    if (std.mem.eql(u8, sub, "lock")) return try runDbLock(allocator, argv, stdout);
    if (std.mem.eql(u8, sub, "unlock")) return try runDbUnlock(allocator, argv, stdout);
    return error.UnexpectedArgument;
}

fn cArgvToSlice(argv: [*]const [*:0]const u8, argv_len: usize, allocator: std.mem.Allocator) ![]const []const u8 {
    const slice = argv[0..argv_len];
    var out = try allocator.alloc([]const u8, slice.len);
    errdefer allocator.free(out);
    for (slice, 0..) |arg, idx| out[idx] = std.mem.span(arg);
    return out;
}

fn makeAnyWriter(stream: plugin.HostStream, storage: *plugin.HostStream) ?std.io.AnyWriter {
    if (stream.write_all == null or stream.ctx == null) return null;
    storage.* = stream;
    return .{ .context = storage, .writeFn = struct {
        fn write(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
            const hs = @as(*const plugin.HostStream, @ptrCast(@alignCast(ctx)));
            const write_all = hs.write_all orelse return error.WriteFailed;
            if (write_all(hs.ctx, bytes.ptr, bytes.len) != @intFromEnum(plugin.AbiStatus.ok)) return error.WriteFailed;
            return bytes.len;
        }
    }.write };
}

fn runDbCommandAbi(ctx: *const plugin.Context, argv: [*]const [*:0]const u8, argv_len: usize, stdout: plugin.HostStream, stderr: plugin.HostStream, out_code: *u8) callconv(.c) u32 {
    _ = ctx;
    out_code.* = 0;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = cArgvToSlice(argv, argv_len, allocator) catch return @intFromEnum(plugin.AbiStatus.failed);
    defer allocator.free(args);

    var stdout_storage = stdout;
    var stderr_storage = stderr;
    const stdout_writer = makeAnyWriter(stdout, &stdout_storage) orelse return @intFromEnum(plugin.AbiStatus.failed);
    const stderr_writer = makeAnyWriter(stderr, &stderr_storage) orelse return @intFromEnum(plugin.AbiStatus.failed);

    const result = runDbCommandImpl(allocator, args, stdout_writer, stderr_writer) catch |err| {
        if (!isDbCliError(err)) return @intFromEnum(plugin.AbiStatus.failed);
        writeDbCliError(stderr_writer, args, err) catch return @intFromEnum(plugin.AbiStatus.failed);
        out_code.* = 1;
        return @intFromEnum(plugin.AbiStatus.ok);
    };
    if (result) |code| {
        out_code.* = code;
        return @intFromEnum(plugin.AbiStatus.ok);
    }
    return @intFromEnum(plugin.AbiStatus.unknown_command);
}

const CaptureStream = struct {
    buffer: *std.ArrayList(u8),
};

fn captureWriteAll(ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) u32 {
    const stream = @as(*CaptureStream, @ptrCast(@alignCast(ctx orelse return @intFromEnum(plugin.AbiStatus.failed))));
    stream.buffer.appendSlice(bytes[0..len]) catch return @intFromEnum(plugin.AbiStatus.failed);
    return @intFromEnum(plugin.AbiStatus.ok);
}

fn captureHostStream(ctx: *CaptureStream) plugin.HostStream {
    return .{ .ctx = ctx, .write_all = captureWriteAll };
}

const descriptor: plugin.PluginDescriptor = .{
    .abi_version = plugin.abi_version,
    .descriptor_size = @as(u32, @intCast(@sizeOf(plugin.PluginDescriptor))),
    .name = "db",
    .init = null,
    .prebuild = null,
    .postbuild = null,
    .handle_command = runDbCommandAbi,
    .skills_ptr = skills[0..].ptr,
    .skills_len = skills.len,
};

pub export const saasm_plugin_descriptor_v1: plugin.PluginDescriptor = descriptor;
pub export fn saasm_plugin_descriptor_v1_fn(out: *plugin.PluginDescriptor) callconv(.c) void {
    out.* = descriptor;
}

test "db plugin wrapper exports runtime descriptor" {
    var exported: plugin.PluginDescriptor = undefined;
    saasm_plugin_descriptor_v1_fn(&exported);
    try std.testing.expectEqualStrings("db", std.mem.span(exported.name));
    try std.testing.expectEqual(@as(usize, 1), exported.skills_len);
    const items = exported.skills_ptr[0].items;
    try std.testing.expectEqual(@as(usize, 12), items.len);
    try std.testing.expectEqualStrings("db init <schema.sadb-schema>", items[0]);
    try std.testing.expectEqualStrings("db unlock <table>", items[11]);
}

test "db plugin wrapper abi maps missing init schema to cli diagnostic" {
    var ctx = plugin.Context{ .allocator = std.testing.allocator };
    var stdout_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();
    var stdout_ctx = CaptureStream{ .buffer = &stdout_buffer };
    var stderr_ctx = CaptureStream{ .buffer = &stderr_buffer };

    const argv = try std.testing.allocator.alloc([*:0]const u8, 3);
    defer {
        for (argv) |arg| std.testing.allocator.free(std.mem.sliceTo(arg, 0));
        std.testing.allocator.free(argv);
    }
    argv[0] = try std.testing.allocator.dupeZ(u8, "sa");
    argv[1] = try std.testing.allocator.dupeZ(u8, "db");
    argv[2] = try std.testing.allocator.dupeZ(u8, "init");

    var out_code: u8 = 255;
    const status = runDbCommandAbi(&ctx, argv.ptr, argv.len, captureHostStream(&stdout_ctx), captureHostStream(&stderr_ctx), &out_code);

    try std.testing.expectEqual(@intFromEnum(plugin.AbiStatus.ok), status);
    try std.testing.expectEqual(@as(u8, 1), out_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "error[SA-DB-CLI]: missing required DB operand"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "usage: sa db init <schema.sadb-schema>"));
}

test "db plugin wrapper renders invalid exec params diagnostic" {
    var stderr_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const argv = [_][]const u8{ "sa", "db", "exec", "<hash>", "--params", "params.bin" };
    try writeDbCliError(stderr_buffer.writer().any(), &argv, error.InvalidParams);

    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "error[SA-DB-CLI]: invalid DB params format"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "check params.bin layout and byte length"));
}

test "db plugin wrapper renders invalid query hash diagnostic" {
    var stderr_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const argv = [_][]const u8{ "sa", "db", "exec", "not-a-hash" };
    try writeDbCliError(stderr_buffer.writer().any(), &argv, error.InvalidQueryHash);

    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "error[SA-DB-CLI]: invalid DB query hash"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "use a 64-character hexadecimal DB query hash"));
}

test "db plugin wrapper renders corrupted registry metadata diagnostic" {
    var stderr_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const argv = [_][]const u8{ "sa", "db", "exec", "<hash>" };
    try writeDbCliError(stderr_buffer.writer().any(), &argv, error.QueryRegistryCorrupted);

    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "error[SA-DB-CLI]: DB query registry metadata is corrupted"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "re-register the query or repair the corrupted DB qmod registry metadata"));
}

test "db plugin wrapper renders corrupted query payload diagnostic" {
    var stderr_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const argv = [_][]const u8{ "sa", "db", "exec", "<hash>" };
    try writeDbCliError(stderr_buffer.writer().any(), &argv, error.QueryPayloadCorrupted);

    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "error[SA-DB-CLI]: DB query payload is corrupted"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "re-register the query or restore the corrupted DB qmod payload"));
}

test "db plugin wrapper renders duplicate register diagnostic" {
    var stderr_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const argv = [_][]const u8{ "sa", "db", "register", "query.sa" };
    try writeDbCliError(stderr_buffer.writer().any(), &argv, error.DuplicateRegister);

    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "error[SA-DB-CLI]: DB query hash is already registered with different metadata"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "keep the original source path, grants, and entrypoint for this registered hash"));
}

test "db plugin wrapper renders schema mismatch diagnostic" {
    var stderr_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const argv = [_][]const u8{ "sa", "db", "exec", "<hash>" };
    try writeDbCliError(stderr_buffer.writer().any(), &argv, error.SchemaMismatch);

    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "error[SA-DB-CLI]: DB schema hash mismatch"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "refresh or restore the table schema before running this query"));
}

test "db plugin wrapper renders column type mismatch diagnostic" {
    var stderr_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const argv = [_][]const u8{ "sa", "db", "register", "query.sa" };
    try writeDbCliError(stderr_buffer.writer().any(), &argv, error.ColumnTypeMismatch);

    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "error[SA-DB-CLI]: DB column type mismatch"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "use a u64 DB column for this atomic or typed DB operation"));
}

test "db plugin wrapper renders snapshot corrupted diagnostic" {
    var stderr_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const argv = [_][]const u8{ "sa", "db", "exec", "<hash>" };
    try writeDbCliError(stderr_buffer.writer().any(), &argv, error.SnapshotCorrupted);

    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "error[SA-DB-CLI]: DB snapshot is corrupted"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.items, 1, "verify, restore, or rebuild the corrupted table snapshot before exec"));
}

test "db inspect rejects malformed 64-byte hash text before table lookup" {
    var stdout_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();

    const bad_hash = "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg";
    const argv = [_][]const u8{ "sa", "db", "inspect", bad_hash };
    try std.testing.expectError(error.InvalidQueryHash, runDbInspect(std.testing.allocator, &argv, stdout_buffer.writer().any()));
}

test "db plugin wrapper runs init command through ABI" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var file = try tmp.dir.createFile("flash_sale.sadb-schema", .{ .truncate = true });
    defer file.close();
    try file.writeAll(
        \\#def MAX_ROWS = 10
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_PRICE_STRIDE = 4 // f32
    );

    var ctx = plugin.Context{ .allocator = std.testing.allocator };
    var stdout_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();
    var stdout_ctx = CaptureStream{ .buffer = &stdout_buffer };
    var stderr_ctx = CaptureStream{ .buffer = &stderr_buffer };

    const argv = try std.testing.allocator.alloc([*:0]const u8, 4);
    defer {
        for (argv) |arg| std.testing.allocator.free(std.mem.sliceTo(arg, 0));
        std.testing.allocator.free(argv);
    }
    argv[0] = try std.testing.allocator.dupeZ(u8, "sa");
    argv[1] = try std.testing.allocator.dupeZ(u8, "db");
    argv[2] = try std.testing.allocator.dupeZ(u8, "init");
    argv[3] = try std.testing.allocator.dupeZ(u8, "flash_sale.sadb-schema");

    var out_code: u8 = 255;
    const status = runDbCommandAbi(&ctx, argv.ptr, argv.len, captureHostStream(&stdout_ctx), captureHostStream(&stderr_ctx), &out_code);

    try std.testing.expectEqual(@intFromEnum(plugin.AbiStatus.ok), status);
    try std.testing.expectEqual(@as(u8, 0), out_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "flash_sale.sai"));

    const iface = try tmp.dir.readFileAlloc(std.testing.allocator, "flash_sale.sai", 1 << 20);
    defer std.testing.allocator.free(iface);
    try std.testing.expect(std.mem.containsAtLeast(u8, iface, 1, "#def TABLE_ROW_BYTES = 12"));
}
