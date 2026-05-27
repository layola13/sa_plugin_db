const std = @import("std");
const plugin = @import("plugin_api");
const schema = @import("schema.zig");

const skills = [_]plugin.SkillSection{
    .{
        .name = "database",
        .summary = "Standalone DB schema bootstrap and table helpers",
        .items = &.{
            "db init <schema>",
            "db inspect <table>",
            "db ingest <table> <csv|jsonl>",
            "db export <table> <dir>",
            "db lock <table>",
            "db unlock <table>",
            "db status <table>",
            "db query <table> <sql>",
            "db run <table> <script>",
            "db exec <hash> [--params <file>]",
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
        error.OutOfMemory,
        => true,
        else => false,
    };
}

fn dbCliHint(argv: []const []const u8, err: anyerror) []const u8 {
    const sub = if (argv.len >= 3) argv[2] else "";
    return switch (err) {
        error.MissingSourcePath => if (sub.len == 0)
            "usage: sa db <init|inspect|ingest|export|lock|unlock|status|query|run|exec> ..."
        else if (std.mem.eql(u8, sub, "init"))
            "usage: sa db init <schema.sadb-schema>"
        else
            "usage: sa db <init|inspect|ingest|export|lock|unlock|status|query|run|exec> ...",
        error.UnexpectedArgument => "remove the extra DB argument",
        error.InvalidPath => "check the DB schema or table path",
        error.FileNotFound, error.NotDir => "check that the DB schema file exists",
        error.AccessDenied => "check filesystem permissions for the DB path",
        error.InvalidFormat => "check the DB schema format",
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
        error.OutOfMemory => "out of memory while processing DB command",
        else => @errorName(err),
    };
    try writer.print("error[SA-DB-CLI]: {s}\n", .{message});
    try writer.print("  help: {s}\n", .{dbCliHint(argv, err)});
}

fn runDbInit(ctx: *const plugin.Context, argv: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) anyerror!?u8 {
    _ = stderr;
    if (argv.len < 4) return error.MissingSourcePath;
    if (argv.len > 4) return error.UnexpectedArgument;

    const source_path = argv[3];
    const source = std.fs.cwd().readFileAlloc(ctx.allocator, source_path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        error.IsDir => return error.NotDir,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPath,
    };
    defer ctx.allocator.free(source);

    var parsed = schema.compile(ctx.allocator, source, source_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidFormat,
    };
    defer parsed.deinit();

    const iface_path = try schema.ifaceFilePath(ctx.allocator, source_path);
    defer ctx.allocator.free(iface_path);

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

fn runDbCommandImpl(ctx: *const plugin.Context, argv: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 2) return null;
    if (!std.mem.eql(u8, argv[1], "db")) return null;
    if (argv.len < 3) return error.MissingSourcePath;

    const sub = argv[2];
    if (std.mem.eql(u8, sub, "init")) {
        return try runDbInit(ctx, argv, stdout, stderr);
    }
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
    out_code.* = 0;
    const args = cArgvToSlice(argv, argv_len, ctx.allocator) catch return @intFromEnum(plugin.AbiStatus.failed);
    defer ctx.allocator.free(args);

    var stdout_storage = stdout;
    var stderr_storage = stderr;
    const stdout_writer = makeAnyWriter(stdout, &stdout_storage) orelse return @intFromEnum(plugin.AbiStatus.failed);
    const stderr_writer = makeAnyWriter(stderr, &stderr_storage) orelse return @intFromEnum(plugin.AbiStatus.failed);

    const result = runDbCommandImpl(ctx, args, stdout_writer, stderr_writer) catch |err| {
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
    try std.testing.expectEqual(@as(usize, 10), items.len);
    try std.testing.expectEqualStrings("db init <schema>", items[0]);
    try std.testing.expectEqualStrings("db exec <hash> [--params <file>]", items[9]);
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
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.items, 1, "flash_sale.iface"));

    const iface = try tmp.dir.readFileAlloc(std.testing.allocator, "flash_sale.iface", 1 << 20);
    defer std.testing.allocator.free(iface);
    try std.testing.expect(std.mem.containsAtLeast(u8, iface, 1, "#def TABLE_ROW_BYTES = 12"));
}
