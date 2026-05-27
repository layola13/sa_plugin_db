const std = @import("std");
const trap = @import("common/trap.zig");

pub const ExecError = error{
    UnsupportedOperation,
};

pub const ExecResult = struct {
    hash: [32]u8 = [_]u8{0} ** 32,
    qmod_path: []u8 = &[_]u8{},
    iface_path: []u8 = &[_]u8{},
    registry_path: []u8 = &[_]u8{},
    source_path: []u8 = &[_]u8{},

    pub fn deinit(self: *ExecResult, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = undefined;
    }
};

pub const ExecRunResult = struct {
    code: u8 = 0,
    function_name: []u8 = &[_]u8{},
    hash: [32]u8 = [_]u8{0} ** 32,

    pub fn deinit(self: *ExecRunResult, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = undefined;
    }
};

pub const ExecRun = union(enum) {
    ok: ExecRunResult,
    trap: trap.TrapReport,

    pub fn deinit(self: *ExecRun, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = undefined;
    }
};

pub fn compileSchema(_: std.mem.Allocator, _: []const u8) ![]u8 {
    return error.UnsupportedOperation;
}

pub fn registerQuery(_: std.mem.Allocator, _: []const u8, _: []const u8) !ExecResult {
    return error.UnsupportedOperation;
}

pub fn inspectRegistry(_: std.mem.Allocator, _: []const u8, _: []const u8) ![]u8 {
    return error.UnsupportedOperation;
}

pub fn execQuery(_: std.mem.Allocator, _: []const u8, _: []const u8, _: ?[]const u8, _: std.io.AnyWriter, _: std.io.AnyWriter) !ExecRun {
    return error.UnsupportedOperation;
}
