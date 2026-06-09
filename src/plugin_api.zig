const std = @import("std");

pub const api = @This();

pub const SkillSection = struct {
    name: []const u8,
    summary: []const u8,
    items: []const []const u8,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    host_version: ?[]const u8 = host_version,
    log: ?*const fn (ctx: *const anyopaque, level: LogLevel, message_ptr: [*]const u8, message_len: usize) callconv(.c) void = null,
    log_ctx: ?*anyopaque = null,
    json_mode: bool = false,
    broker_abi_version: u32 = 0,
    broker_call: ?BrokerCallFn = null,
    broker_ctx: ?*anyopaque = null,
};

pub const LogLevel = enum(u8) {
    debug,
    info,
    warn,
    err,
};

pub const abi_version: u32 = 1;
pub const host_version: []const u8 = "sci-0.2";
pub const descriptor_symbol_name: [:0]const u8 = "saasm_plugin_descriptor_v1";
pub const descriptor_fn_symbol_name: [:0]const u8 = "saasm_plugin_descriptor_v1_fn";
pub const broker_abi_version: u32 = 1;

pub const AbiStatus = enum(u32) {
    ok = 0,
    unknown_command = 1,
    failed = 2,
    version_mismatch = 3,
    invalid_descriptor = 4,
};

pub const BrokerCallFn = *const fn (ctx: ?*anyopaque, op: u32, req: ?*const anyopaque, resp: ?*anyopaque) callconv(.c) u32;

pub const BrokerOp = enum(u32) {
    env_get = 1,
    fs_read = 2,
    http_request = 3,
    process_spawn = 4,
};

pub const BrokerStatus = enum(u32) {
    ok = 0,
    denied = 1,
    unsupported = 2,
    invalid_request = 3,
    not_found = 4,
    insufficient_buffer = 5,
    failed = 6,
};

pub const PluginDescriptor = extern struct {
    abi_version: u32,
    descriptor_size: u32,
    name: [*:0]const u8,
    init: ?*const fn (ctx: *const Context) callconv(.c) u32,
    prebuild: ?*const fn (ctx: *const Context, compile_options: ?*anyopaque) callconv(.c) u32,
    postbuild: ?*const fn (ctx: *const Context) callconv(.c) u32,
    handle_command: ?*const fn (ctx: *const Context, argv: [*]const [*:0]const u8, argv_len: usize, stdout: HostStream, stderr: HostStream, out_code: *u8) callconv(.c) u32,
    skills_ptr: [*]const SkillSection,
    skills_len: usize,
};

pub const DescriptorFn = *const fn (out: *PluginDescriptor) callconv(.c) void;
pub const DescriptorPtr = *const PluginDescriptor;

pub const StreamWriteAllFn = *const fn (ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) u32;

pub const HostStream = extern struct {
    ctx: ?*anyopaque,
    write_all: ?StreamWriteAllFn,
};

pub const Plugin = struct {
    name: []const u8,
    init: ?*const fn (ctx: *const Context) anyerror!void = null,
    prebuild: ?*const fn (ctx: *const Context, compile_options: *anyopaque) anyerror!void = null,
    postbuild: ?*const fn (ctx: *const Context) anyerror!void = null,
    handleCommand: ?*const fn (ctx: *const Context, argv: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) anyerror!?u8 = null,
    skills: ?[]const SkillSection = null,
};

pub fn emitLog(ctx: *const Context, level: LogLevel, message: []const u8) void {
    if (ctx.log) |log_fn| {
        const log_ctx = ctx.log_ctx orelse return;
        log_fn(log_ctx, level, message.ptr, message.len);
    }
}
