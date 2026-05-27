const std = @import("std");
const instr = @import("instruction.zig");
const upstream = @import("upstream_loc.zig");

pub const ParseError = error{
    OutOfMemory,
    InvalidFunctionSig,
    UnsupportedType,
};

pub const PrimType = enum(u8) {
    void,
    i1,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    ptr,
    blob_handle,
    v128,
};

pub const FallibleInfo = struct {
    return_cap: ?instr.CapPrefix,
    return_ty: PrimType,
};

pub const ParamSpec = struct {
    name: []const u8,
    ty: PrimType,
    cap: instr.CapPrefix,
};

pub const FunctionSig = struct {
    id: u32,
    name: []const u8,
    params: []const ParamSpec,
    kind: FunctionKind,
    return_cap: ?instr.CapPrefix,
    return_ty: PrimType,
    return_fallible: bool = false,
    entry_inst_idx: u32,
    is_ffi_wrapper: bool,
    upstream_file: ?[]const u8 = null,
    upstream_loc: ?upstream.UpstreamLoc = null,
    param_ids: []const u32 = &.{},
    reg_ids: []const u32 = &.{},
    llvm_name: ?[]const u8 = null,
    ignored: bool = false,
    should_panic: bool = false,

    pub fn deinit(self: *FunctionSig, allocator: std.mem.Allocator) void {
        for (self.params) |param| {
            allocator.free(param.name);
        }
        allocator.free(self.params);
        if (self.param_ids.len != 0) allocator.free(self.param_ids);
        if (self.reg_ids.len != 0) allocator.free(self.reg_ids);
        if (self.upstream_file) |file| allocator.free(file);
        if (self.llvm_name) |name| allocator.free(name);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const FunctionKind = enum(u8) {
    normal,
    ffi_wrapper,
    external,
    exported,
    test_func,
};

const HeaderSpec = struct {
    prefix: []const u8,
    require_colon: bool,
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn parsePrimType(text: []const u8) ParseError!PrimType {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    inline for ([_]struct { name: []const u8, ty: PrimType }{
        .{ .name = "void", .ty = .void },
        .{ .name = "i1", .ty = .i1 },
        .{ .name = "i8", .ty = .i8 },
        .{ .name = "i16", .ty = .i16 },
        .{ .name = "i32", .ty = .i32 },
        .{ .name = "i64", .ty = .i64 },
        .{ .name = "u8", .ty = .u8 },
        .{ .name = "u16", .ty = .u16 },
        .{ .name = "u32", .ty = .u32 },
        .{ .name = "u64", .ty = .u64 },
        .{ .name = "f32", .ty = .f32 },
        .{ .name = "f64", .ty = .f64 },
        .{ .name = "ptr", .ty = .ptr },
        .{ .name = "blob_handle", .ty = .blob_handle },
        .{ .name = "v128", .ty = .v128 },
    }) |item| {
        if (std.mem.eql(u8, trimmed, item.name)) return item.ty;
    }
    return ParseError.UnsupportedType;
}

pub fn primTypeName(ty: PrimType) []const u8 {
    return switch (ty) {
        .void => "void",
        .i1 => "i1",
        .i8 => "i8",
        .i16 => "i16",
        .i32 => "i32",
        .i64 => "i64",
        .u8 => "u8",
        .u16 => "u16",
        .u32 => "u32",
        .u64 => "u64",
        .f32 => "f32",
        .f64 => "f64",
        .ptr => "ptr",
        .blob_handle => "blob_handle",
        .v128 => "v128",
    };
}

pub fn primTypeBits(ty: PrimType) u32 {
    return switch (ty) {
        .void => 0,
        .i1 => 1,
        .i8, .u8 => 8,
        .i16, .u16 => 16,
        .i32, .u32, .f32 => 32,
        .i64, .u64, .f64, .ptr, .blob_handle => 64,
        .v128 => 128,
    };
}

pub fn returnValueType(return_cap: ?instr.CapPrefix, return_ty: PrimType) PrimType {
    if (return_ty == .void) return .void;
    return switch (return_cap orelse .by_value) {
        .raw, .borrow => .ptr,
        .move, .by_value => return_ty,
    };
}

pub fn primTypeBytes(ty: PrimType) u32 {
    return switch (ty) {
        .void => 0,
        else => @max(@as(u32, 1), primTypeBits(ty) / 8),
    };
}

pub fn testLLVMName(allocator: std.mem.Allocator, id: u32) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "_saasm_test_{d}", .{id});
}

pub fn primTypeFromTag(tag: u32) ?PrimType {
    if (tag > @intFromEnum(PrimType.v128)) return null;
    return @enumFromInt(tag);
}

fn parseOptionalCap(text: []const u8) struct { cap: ?instr.CapPrefix, rest: []const u8 } {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    if (trimmed.len == 0) return .{ .cap = null, .rest = trimmed };
    return switch (trimmed[0]) {
        '&' => .{ .cap = .borrow, .rest = std.mem.trim(u8, trimmed[1..], " \t\r") },
        '^' => .{ .cap = .move, .rest = std.mem.trim(u8, trimmed[1..], " \t\r") },
        '*' => .{ .cap = .raw, .rest = std.mem.trim(u8, trimmed[1..], " \t\r") },
        else => .{ .cap = null, .rest = trimmed },
    };
}

pub fn displayName(kind: FunctionKind, name: []const u8) []const u8 {
    if (kind != .test_func) return name;
    if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"') {
        return name[1 .. name.len - 1];
    }
    return name;
}

fn parseParam(allocator: std.mem.Allocator, fragment: []const u8) ParseError!ParamSpec {
    const trimmed = std.mem.trim(u8, fragment, " \t\r");
    if (trimmed.len == 0) return ParseError.InvalidFunctionSig;

    const cap_split = parseOptionalCap(trimmed);
    const body = cap_split.rest;
    const colon = std.mem.indexOfScalar(u8, body, ':') orelse return ParseError.InvalidFunctionSig;
    const name = std.mem.trim(u8, body[0..colon], " \t\r");
    const ty_text = std.mem.trim(u8, body[colon + 1 ..], " \t\r");
    if (name.len == 0 or ty_text.len == 0) return ParseError.InvalidFunctionSig;
    if (!isIdentStart(name[0])) return ParseError.InvalidFunctionSig;
    for (name[1..]) |c| {
        if (!isIdentChar(c)) return ParseError.InvalidFunctionSig;
    }

    return .{
        .name = try allocator.dupe(u8, name),
        .ty = try parsePrimType(ty_text),
        .cap = cap_split.cap orelse .by_value,
    };
}

const TestModifiers = struct {
    ignored: bool = false,
    should_panic: bool = false,
    rest: []const u8,
};

fn parseTestModifiers(text: []const u8) ParseError!TestModifiers {
    var rest = std.mem.trimLeft(u8, text, " \t");
    var ignored = false;
    var should_panic = false;

    while (rest.len != 0 and rest[0] != '"') {
        const token_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const token = rest[0..token_end];
        if (std.mem.eql(u8, token, "ignored")) {
            if (ignored) return ParseError.InvalidFunctionSig;
            ignored = true;
        } else if (std.mem.eql(u8, token, "should_panic")) {
            if (should_panic) return ParseError.InvalidFunctionSig;
            should_panic = true;
        } else {
            return ParseError.InvalidFunctionSig;
        }
        rest = std.mem.trimLeft(u8, rest[token_end..], " \t");
    }

    return .{
        .ignored = ignored,
        .should_panic = should_panic,
        .rest = rest,
    };
}

pub fn parseFunctionSig(
    allocator: std.mem.Allocator,
    text: []const u8,
    id: u32,
    entry_inst_idx: u32,
) ParseError!FunctionSig {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    if (trimmed.len < 3 or trimmed[0] != '@' or trimmed[trimmed.len - 1] != ':') {
        return ParseError.InvalidFunctionSig;
    }

    const body = trimmed[1 .. trimmed.len - 1];
    const open = std.mem.indexOfScalar(u8, body, '(') orelse return ParseError.InvalidFunctionSig;
    const close = std.mem.lastIndexOfScalar(u8, body, ')') orelse return ParseError.InvalidFunctionSig;
    if (close <= open) return ParseError.InvalidFunctionSig;

    const name_text = std.mem.trim(u8, body[0..open], " \t\r");
    if (name_text.len == 0 or !isIdentStart(name_text[0])) return ParseError.InvalidFunctionSig;
    for (name_text[1..]) |c| {
        if (!isIdentChar(c)) return ParseError.InvalidFunctionSig;
    }

    const params_text = std.mem.trim(u8, body[open + 1 .. close], " \t\r");
    var tail = std.mem.trim(u8, body[close + 1 ..], " \t\r");

    var return_cap: ?instr.CapPrefix = null;
    var return_ty: PrimType = .void;
    var return_fallible = false;
    if (tail.len != 0) {
        if (!std.mem.startsWith(u8, tail, "->")) return ParseError.InvalidFunctionSig;
        var return_text = std.mem.trim(u8, tail[2..], " \t\r");
        if (return_text.len == 0) return ParseError.InvalidFunctionSig;
        if (return_text[return_text.len - 1] == '!') {
            return_fallible = true;
            return_text = std.mem.trimRight(u8, return_text[0 .. return_text.len - 1], " \t\r");
            if (return_text.len == 0) return ParseError.InvalidFunctionSig;
        }
        const cap_split = parseOptionalCap(return_text);
        return_cap = cap_split.cap;
        const ty_text = std.mem.trimLeft(u8, cap_split.rest, " \t\r");
        if (ty_text.len == 0) return ParseError.InvalidFunctionSig;
        if (ty_text.len != 0 and (ty_text[0] == '*' or ty_text[0] == '&' or ty_text[0] == '^')) {
            return_ty = .ptr;
        } else {
            return_ty = try parsePrimType(ty_text);
        }
    }

    var param_list = std.ArrayList(ParamSpec).init(allocator);
    errdefer {
        for (param_list.items) |param| allocator.free(param.name);
        param_list.deinit();
    }

    if (params_text.len != 0) {
        var iterator = std.mem.splitScalar(u8, params_text, ',');
        while (iterator.next()) |fragment| {
            try param_list.append(try parseParam(allocator, fragment));
        }
    }

    const name = try allocator.dupe(u8, name_text);
    errdefer allocator.free(name);
    const params = try param_list.toOwnedSlice();

    return .{
        .id = id,
        .name = name,
        .params = params,
        .kind = .normal,
        .return_cap = return_cap,
        .return_ty = return_ty,
        .return_fallible = return_fallible,
        .entry_inst_idx = entry_inst_idx,
        .is_ffi_wrapper = false,
        .upstream_file = null,
        .upstream_loc = null,
    };
}

pub fn parseFunctionHeader(
    allocator: std.mem.Allocator,
    text: []const u8,
    id: u32,
    entry_inst_idx: u32,
    kind: FunctionKind,
) ParseError!FunctionSig {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    if (trimmed.len == 0) return ParseError.InvalidFunctionSig;

    const spec: HeaderSpec = switch (kind) {
        .normal => .{ .prefix = "@", .require_colon = true },
        .ffi_wrapper => .{ .prefix = "@ffi_wrapper", .require_colon = true },
        .external => .{ .prefix = "@extern", .require_colon = false },
        .exported => .{ .prefix = "@export", .require_colon = true },
        .test_func => .{ .prefix = "@test", .require_colon = true },
    };

    if (!std.mem.startsWith(u8, trimmed, spec.prefix)) return ParseError.InvalidFunctionSig;
    if (spec.require_colon and trimmed[trimmed.len - 1] != ':') return ParseError.InvalidFunctionSig;

    var body = if (spec.require_colon)
        trimmed[spec.prefix.len .. trimmed.len - 1]
    else
        std.mem.trimRight(u8, trimmed[spec.prefix.len..], " :\t\r");

    var ignored = false;
    var should_panic = false;
    if (kind == .test_func) {
        const modifiers = try parseTestModifiers(body);
        body = modifiers.rest;
        ignored = modifiers.ignored;
        should_panic = modifiers.should_panic;
    }

    const after_name = std.mem.trimLeft(u8, body, " \t");
    const open = std.mem.indexOfScalar(u8, after_name, '(') orelse return ParseError.InvalidFunctionSig;
    const close = std.mem.lastIndexOfScalar(u8, after_name, ')') orelse return ParseError.InvalidFunctionSig;
    if (close <= open) return ParseError.InvalidFunctionSig;

    const name_text = std.mem.trim(u8, after_name[0..open], " \t\r");
    if (name_text.len == 0) return ParseError.InvalidFunctionSig;

    // For @test functions, allow string literals as names
    if (kind == .test_func) {
        if (name_text[0] != '"') return ParseError.InvalidFunctionSig;
        const end_quote = std.mem.indexOfScalarPos(u8, name_text, 1, '"') orelse return ParseError.InvalidFunctionSig;
        if (end_quote != name_text.len - 1) return ParseError.InvalidFunctionSig;
    } else {
        if (!isIdentStart(name_text[0])) return ParseError.InvalidFunctionSig;
        for (name_text[1..]) |c| {
            if (!isIdentChar(c)) return ParseError.InvalidFunctionSig;
        }
    }

    const params_text = std.mem.trim(u8, after_name[open + 1 .. close], " \t\r");
    var tail = std.mem.trim(u8, after_name[close + 1 ..], " \t\r");

    var return_cap: ?instr.CapPrefix = null;
    var return_ty: PrimType = .void;
    var return_fallible = false;
    if (tail.len != 0) {
        if (!std.mem.startsWith(u8, tail, "->")) return ParseError.InvalidFunctionSig;
        var return_text = std.mem.trim(u8, tail[2..], " \t\r");
        if (return_text.len == 0) return ParseError.InvalidFunctionSig;
        if (return_text[return_text.len - 1] == '!') {
            return_fallible = true;
            return_text = std.mem.trimRight(u8, return_text[0 .. return_text.len - 1], " \t\r");
            if (return_text.len == 0) return ParseError.InvalidFunctionSig;
        }
        const cap_split = parseOptionalCap(return_text);
        return_cap = cap_split.cap;
        const ty_text = std.mem.trimLeft(u8, cap_split.rest, " \t\r");
        if (ty_text.len == 0) return ParseError.InvalidFunctionSig;
        if (ty_text.len != 0 and (ty_text[0] == '*' or ty_text[0] == '&' or ty_text[0] == '^')) {
            return_ty = .ptr;
        } else {
            return_ty = try parsePrimType(ty_text);
        }
    }

    var param_list = std.ArrayList(ParamSpec).init(allocator);
    errdefer {
        for (param_list.items) |param| allocator.free(param.name);
        param_list.deinit();
    }

    if (params_text.len != 0) {
        var iterator = std.mem.splitScalar(u8, params_text, ',');
        while (iterator.next()) |fragment| {
            try param_list.append(try parseParam(allocator, fragment));
        }
    }

    const name = try allocator.dupe(u8, name_text);
    errdefer allocator.free(name);
    const params = try param_list.toOwnedSlice();
    const llvm_name = if (kind == .test_func) try testLLVMName(allocator, id) else null;

    return .{
        .id = id,
        .name = name,
        .params = params,
        .kind = kind,
        .return_cap = return_cap,
        .return_ty = return_ty,
        .return_fallible = return_fallible,
        .entry_inst_idx = entry_inst_idx,
        .is_ffi_wrapper = kind == .ffi_wrapper,
        .upstream_file = null,
        .upstream_loc = null,
        .llvm_name = llvm_name,
        .ignored = ignored,
        .should_panic = should_panic,
    };
}

test "function signature carries prefix and params" {
    const params = [_]ParamSpec{
        .{ .name = "x", .ty = .i32, .cap = .borrow },
    };
    const sig = FunctionSig{
        .id = 1,
        .name = "main",
        .params = params[0..],
        .kind = .normal,
        .return_cap = .move,
        .return_ty = .i32,
        .return_fallible = true,
        .entry_inst_idx = 0,
        .is_ffi_wrapper = false,
        .upstream_file = "main.rs",
        .upstream_loc = .{ .file = "main.rs", .line = 1, .col = 1 },
        .param_ids = &.{},
    };
    try std.testing.expectEqual(@as(u32, 1), sig.id);
    try std.testing.expectEqualStrings("main", sig.name);
    try std.testing.expectEqual(@as(usize, 1), sig.params.len);
    try std.testing.expectEqual(instr.CapPrefix.move, sig.return_cap.?);
    try std.testing.expect(sig.return_fallible);
}

test "parse function signature with params and return cap" {
    var sig = try parseFunctionSig(std.testing.allocator, "@sum(^lhs: i32, rhs: i32) -> ^i32!:", 7, 3);
    defer sig.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 7), sig.id);
    try std.testing.expectEqualStrings("sum", sig.name);
    try std.testing.expectEqual(@as(usize, 2), sig.params.len);
    try std.testing.expectEqual(instr.CapPrefix.move, sig.params[0].cap);
    try std.testing.expectEqual(PrimType.i32, sig.params[0].ty);
    try std.testing.expectEqual(instr.CapPrefix.by_value, sig.params[1].cap);
    try std.testing.expectEqual(instr.CapPrefix.move, sig.return_cap.?);
    try std.testing.expectEqual(PrimType.i32, sig.return_ty);
    try std.testing.expect(sig.return_fallible);
}

test "parse function headers cover all declaration kinds" {
    const cases = [_]struct {
        kind: FunctionKind,
        text: []const u8,
        name: []const u8,
        is_ffi_wrapper: bool,
        return_cap: ?instr.CapPrefix,
        return_ty: PrimType,
        return_fallible: bool,
        param_count: usize,
    }{
        .{
            .kind = .normal,
            .text = "@main() -> i32:",
            .name = "main",
            .is_ffi_wrapper = false,
            .return_cap = null,
            .return_ty = .i32,
            .return_fallible = false,
            .param_count = 0,
        },
        .{
            .kind = .ffi_wrapper,
            .text = "@ffi_wrapper bridge(*raw: ptr) -> ^ptr!:",
            .name = "bridge",
            .is_ffi_wrapper = true,
            .return_cap = .move,
            .return_ty = .ptr,
            .return_fallible = true,
            .param_count = 1,
        },
        .{
            .kind = .external,
            .text = "@extern memcpy(*dst: ptr, *src: ptr, len: u64) -> i32",
            .name = "memcpy",
            .is_ffi_wrapper = false,
            .return_cap = null,
            .return_ty = .i32,
            .return_fallible = false,
            .param_count = 3,
        },
        .{
            .kind = .exported,
            .text = "@export simd(v: v128) -> v128:",
            .name = "simd",
            .is_ffi_wrapper = false,
            .return_cap = null,
            .return_ty = .v128,
            .return_fallible = false,
            .param_count = 1,
        },
    };

    for (cases, 0..) |case, idx| {
        var parsed = try parseFunctionHeader(std.testing.allocator, case.text, @intCast(idx), @intCast(idx * 10), case.kind);
        defer parsed.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(u32, @intCast(idx)), parsed.id);
        try std.testing.expectEqual(case.kind, parsed.kind);
        try std.testing.expectEqual(case.is_ffi_wrapper, parsed.is_ffi_wrapper);
        try std.testing.expectEqual(case.return_cap, parsed.return_cap);
        try std.testing.expectEqual(case.return_ty, parsed.return_ty);
        try std.testing.expectEqual(case.return_fallible, parsed.return_fallible);
        try std.testing.expectEqual(case.param_count, parsed.params.len);
        try std.testing.expectEqualStrings(case.name, parsed.name);
    }
}

test "prim types accept all supported literals including v128" {
    const cases = [_]struct {
        text: []const u8,
        ty: PrimType,
    }{
        .{ .text = "void", .ty = .void },
        .{ .text = "i1", .ty = .i1 },
        .{ .text = "i8", .ty = .i8 },
        .{ .text = "i16", .ty = .i16 },
        .{ .text = "i32", .ty = .i32 },
        .{ .text = "i64", .ty = .i64 },
        .{ .text = "u8", .ty = .u8 },
        .{ .text = "u16", .ty = .u16 },
        .{ .text = "u32", .ty = .u32 },
        .{ .text = "u64", .ty = .u64 },
        .{ .text = "f32", .ty = .f32 },
        .{ .text = "f64", .ty = .f64 },
        .{ .text = "ptr", .ty = .ptr },
        .{ .text = "v128", .ty = .v128 },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.ty, try parsePrimType(case.text));
        try std.testing.expectEqualStrings(case.text, primTypeName(case.ty));
    }
}

const TypeCase = struct {
    name: []const u8,
    ty: PrimType,
};

const all_type_cases = [_]TypeCase{
    .{ .name = "void", .ty = .void },
    .{ .name = "i1", .ty = .i1 },
    .{ .name = "i8", .ty = .i8 },
    .{ .name = "i16", .ty = .i16 },
    .{ .name = "i32", .ty = .i32 },
    .{ .name = "i64", .ty = .i64 },
    .{ .name = "u8", .ty = .u8 },
    .{ .name = "u16", .ty = .u16 },
    .{ .name = "u32", .ty = .u32 },
    .{ .name = "u64", .ty = .u64 },
    .{ .name = "f32", .ty = .f32 },
    .{ .name = "f64", .ty = .f64 },
    .{ .name = "ptr", .ty = .ptr },
    .{ .name = "v128", .ty = .v128 },
};

const nonvoid_type_cases = [_]TypeCase{
    .{ .name = "i1", .ty = .i1 },
    .{ .name = "i8", .ty = .i8 },
    .{ .name = "i16", .ty = .i16 },
    .{ .name = "i32", .ty = .i32 },
    .{ .name = "i64", .ty = .i64 },
    .{ .name = "u8", .ty = .u8 },
    .{ .name = "u16", .ty = .u16 },
    .{ .name = "u32", .ty = .u32 },
    .{ .name = "u64", .ty = .u64 },
    .{ .name = "f32", .ty = .f32 },
    .{ .name = "f64", .ty = .f64 },
    .{ .name = "ptr", .ty = .ptr },
    .{ .name = "v128", .ty = .v128 },
};

fn capText(prefix: instr.CapPrefix) []const u8 {
    return switch (prefix) {
        .by_value => "",
        .borrow => "&",
        .move => "^",
        .raw => "*",
    };
}

pub fn writeFunctionHeader(writer: anytype, sig: FunctionSig) !void {
    switch (sig.kind) {
        .normal => try writer.writeAll("@"),
        .ffi_wrapper => try writer.writeAll("@ffi_wrapper "),
        .external => try writer.writeAll("@extern "),
        .exported => try writer.writeAll("@export "),
        .test_func => {
            try writer.writeAll("@test ");
            if (sig.ignored) try writer.writeAll("ignored ");
            if (sig.should_panic) try writer.writeAll("should_panic ");
        },
    }
    if (sig.kind == .test_func and sig.name.len != 0 and sig.name[0] == '"') {
        try writer.writeAll(sig.name);
    } else {
        try writer.writeAll(sig.name);
    }
    try writer.writeByte('(');
    for (sig.params, 0..) |param, idx| {
        if (idx != 0) try writer.writeAll(", ");
        if (param.cap != .by_value) try writer.writeAll(capText(param.cap));
        try writer.print("{s}: {s}", .{ param.name, primTypeName(param.ty) });
    }
    try writer.writeByte(')');
    if (sig.return_ty != .void) {
        try writer.writeAll(" -> ");
        if (sig.return_cap) |cap| try writer.writeAll(capText(cap));
        try writer.writeAll(primTypeName(sig.return_ty));
        if (sig.return_fallible) try writer.writeByte('!');
    }
    if (sig.kind != .external) try writer.writeByte(':');
}

fn expectSigEqual(expected: FunctionSig, actual: FunctionSig) !void {
    try std.testing.expectEqual(expected.id, actual.id);
    try std.testing.expectEqual(expected.kind, actual.kind);
    try std.testing.expectEqual(expected.return_cap, actual.return_cap);
    try std.testing.expectEqual(expected.return_ty, actual.return_ty);
    try std.testing.expectEqual(expected.return_fallible, actual.return_fallible);
    try std.testing.expectEqual(expected.entry_inst_idx, actual.entry_inst_idx);
    try std.testing.expectEqual(expected.is_ffi_wrapper, actual.is_ffi_wrapper);
    try std.testing.expectEqual(expected.ignored, actual.ignored);
    try std.testing.expectEqual(expected.should_panic, actual.should_panic);
    try std.testing.expectEqualStrings(expected.name, actual.name);
    try std.testing.expectEqual(expected.params.len, actual.params.len);
    for (expected.params, actual.params) |lhs, rhs| {
        try std.testing.expectEqual(lhs.ty, rhs.ty);
        try std.testing.expectEqual(lhs.cap, rhs.cap);
        try std.testing.expectEqualStrings(lhs.name, rhs.name);
    }
}

test "function signature parsing is deterministic across random headers" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_4111);
    const random = prng.random();
    const kinds = [_]FunctionKind{ .normal, .ffi_wrapper, .external, .exported };
    const caps = [_]instr.CapPrefix{ .by_value, .borrow, .move, .raw };

    for (0..64) |idx| {
        const kind = kinds[random.intRangeLessThan(usize, 0, kinds.len)];
        const param_count = random.intRangeAtMost(usize, 0, 3);
        const include_return = random.boolean();
        const return_fallible = include_return and random.boolean();
        var return_case = all_type_cases[random.intRangeLessThan(usize, 0, all_type_cases.len)];
        if (return_fallible and return_case.ty == .void) {
            return_case = nonvoid_type_cases[random.intRangeLessThan(usize, 0, nonvoid_type_cases.len)];
        }
        const return_cap = if (include_return and return_case.ty != .void and random.boolean())
            caps[random.intRangeLessThan(usize, 0, caps.len)]
        else
            instr.CapPrefix.by_value;

        var buf = std.ArrayList(u8).init(std.testing.allocator);
        defer buf.deinit();
        const writer = buf.writer();
        var expected = FunctionSig{
            .id = @intCast(idx),
            .name = try std.fmt.allocPrint(std.testing.allocator, "f_{d}", .{idx}),
            .params = &.{},
            .kind = kind,
            .return_cap = if (include_return and return_case.ty != .void) return_cap else null,
            .return_ty = if (include_return) return_case.ty else .void,
            .return_fallible = include_return and return_fallible,
            .entry_inst_idx = @intCast(idx * 10),
            .is_ffi_wrapper = kind == .ffi_wrapper,
            .upstream_file = null,
            .upstream_loc = null,
        };
        defer std.testing.allocator.free(expected.name);
        const param_buf = try std.testing.allocator.alloc(ParamSpec, param_count);
        defer std.testing.allocator.free(param_buf);
        expected.params = param_buf;
        for (0..param_count) |pidx| {
            const param_cap = caps[random.intRangeLessThan(usize, 0, caps.len)];
            const param_ty = nonvoid_type_cases[random.intRangeLessThan(usize, 0, nonvoid_type_cases.len)];
            param_buf[pidx] = .{
                .name = try std.fmt.allocPrint(std.testing.allocator, "p{d}", .{pidx}),
                .ty = param_ty.ty,
                .cap = param_cap,
            };
        }
        try writeFunctionHeader(writer, expected);
        for (param_buf) |param| {
            std.testing.allocator.free(param.name);
        }

        var first = try parseFunctionHeader(std.testing.allocator, buf.items, @intCast(idx), @intCast(idx * 10), kind);
        defer first.deinit(std.testing.allocator);
        var second = try parseFunctionHeader(std.testing.allocator, buf.items, @intCast(idx), @intCast(idx * 10), kind);
        defer second.deinit(std.testing.allocator);

        try expectSigEqual(first, second);
    }
}

test "test signatures receive stable internal llvm names" {
    const name = try testLLVMName(std.testing.allocator, 7);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("_saasm_test_7", name);
}

test "test signatures parse ignored and should_panic modifiers" {
    var sig = try parseFunctionHeader(
        std.testing.allocator,
        "@test ignored should_panic \"panic path\"():",
        9,
        90,
        .test_func,
    );
    defer sig.deinit(std.testing.allocator);

    try std.testing.expect(sig.ignored);
    try std.testing.expect(sig.should_panic);
    try std.testing.expectEqualStrings("\"panic path\"", sig.name);
    try std.testing.expectEqualStrings("panic path", displayName(sig.kind, sig.name));
    try std.testing.expectEqualStrings("_saasm_test_9", sig.llvm_name.?);
}

test "type literal PBT accepts supported names and rejects near misses" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_4112);
    const random = prng.random();

    for (0..96) |idx| {
        const chosen = all_type_cases[random.intRangeLessThan(usize, 0, all_type_cases.len)];
        const padded = try std.fmt.allocPrint(std.testing.allocator, " \t{s}\r ", .{chosen.name});
        defer std.testing.allocator.free(padded);
        try std.testing.expectEqual(chosen.ty, try parsePrimType(padded));

        const invalid = switch (idx % 3) {
            0 => try std.fmt.allocPrint(std.testing.allocator, "{s}_x", .{chosen.name}),
            1 => try std.fmt.allocPrint(std.testing.allocator, "{s}{d}", .{ chosen.name, idx }),
            else => try std.fmt.allocPrint(std.testing.allocator, "x_{s}", .{chosen.name}),
        };
        defer std.testing.allocator.free(invalid);
        try std.testing.expectError(ParseError.UnsupportedType, parsePrimType(invalid));
    }
}
