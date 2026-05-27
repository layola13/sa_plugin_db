const std = @import("std");

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

pub const ParseError = error{
    OutOfMemory,
    InvalidFormat,
    UnsupportedType,
    DuplicateDef,
    MissingRowBytes,
    MissingMaxRows,
    CapacityOverflow,
};

pub const Column = struct {
    name: []const u8,
    stride: u32,
    ty: ?PrimType = null,
};

pub const Def = struct {
    name: []const u8,
    value: []const u8,
};

pub const Schema = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    max_rows: u64,
    columns: []Column,
    row_bytes: u64,
    defs: []Def,

    pub fn deinit(self: *Schema) void {
        for (self.columns) |column| self.allocator.free(column.name);
        self.allocator.free(self.columns);
        for (self.defs) |def| {
            self.allocator.free(def.name);
            self.allocator.free(def.value);
        }
        self.allocator.free(self.defs);
        self.allocator.free(self.table_name);
        self.* = undefined;
    }
};

pub fn ifaceFilePath(allocator: std.mem.Allocator, source_path: []const u8) ![]u8 {
    const basename = std.fs.path.basename(source_path);
    const stem = if (std.mem.endsWith(u8, basename, ".sadb-schema"))
        basename[0 .. basename.len - ".sadb-schema".len]
    else if (std.mem.endsWith(u8, basename, ".sa"))
        basename[0 .. basename.len - ".sa".len]
    else
        basename;
    if (std.fs.path.dirname(source_path)) |dir| {
        const filename = try std.fmt.allocPrint(allocator, "{s}.iface", .{stem});
        defer allocator.free(filename);
        return try std.fs.path.join(allocator, &.{ dir, filename });
    }
    return try std.fmt.allocPrint(allocator, "{s}.iface", .{stem});
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r");
}

fn stripInlineComment(line: []const u8) []const u8 {
    var in_string = false;
    var escape = false;
    var i: usize = 0;
    while (i + 1 < line.len) : (i += 1) {
        const c = line[i];
        if (in_string) {
            if (escape) {
                escape = false;
                continue;
            }
            switch (c) {
                '\\' => escape = true,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '/' => {
                if (line[i + 1] == '/') {
                    const prev = if (i == 0) ' ' else line[i - 1];
                    if (i == 0 or std.ascii.isWhitespace(prev)) return line[0..i];
                }
            },
            else => {},
        }
    }
    return line;
}

fn cleanLine(raw: []const u8) []const u8 {
    return trim(stripInlineComment(raw));
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn parseTableName(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, basename, ".sadb-schema")) return basename[0 .. basename.len - ".sadb-schema".len];
    return basename;
}

fn parseDef(line: []const u8) ?Def {
    if (!std.mem.startsWith(u8, line, "#def")) return null;
    var rest = std.mem.trimLeft(u8, line["#def".len..], " \t");
    if (rest.len == 0) return null;

    const eq = std.mem.indexOfScalar(u8, rest, '=');
    const name_text: []const u8 = if (eq) |idx| blk: {
        const name = trim(rest[0..idx]);
        const value = trim(rest[idx + 1 ..]);
        if (name.len == 0 or value.len == 0) return null;
        rest = value;
        break :blk name;
    } else blk: {
        const split = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
        const name = trim(rest[0..split]);
        const value = trim(rest[split..]);
        if (name.len == 0 or value.len == 0) return null;
        rest = value;
        break :blk name;
    };

    if (!isIdentStart(name_text[0])) return null;
    for (name_text[1..]) |c| {
        if (!isIdentChar(c)) return null;
    }
    return .{ .name = name_text, .value = rest };
}

fn isColumnDefName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "COL_") and std.mem.endsWith(u8, name, "_STRIDE");
}

fn appendDef(list: *std.ArrayList(Def), allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    try list.append(.{
        .name = try allocator.dupe(u8, name),
        .value = try allocator.dupe(u8, value),
    });
}

fn writeDef(writer: anytype, name: []const u8, value: []const u8) !void {
    try writer.print("#def {s} = {s}\n", .{ name, value });
}

fn writeDefInt(writer: anytype, name: []const u8, value: u64) !void {
    try writer.print("#def {s} = {d}\n", .{ name, value });
}

fn parsePrimType(text: []const u8) ParseError!PrimType {
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

fn primTypeName(ty: PrimType) []const u8 {
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

fn primTypeBytes(ty: PrimType) u32 {
    return switch (ty) {
        .void => 0,
        .i1 => 1,
        .i8, .u8 => 1,
        .i16, .u16 => 2,
        .i32, .u32, .f32 => 4,
        .i64, .u64, .f64, .ptr, .blob_handle => 8,
        .v128 => 16,
    };
}
pub fn compile(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: []const u8,
) ParseError!Schema {
    const table_name = try allocator.dupe(u8, parseTableName(source_path));
    errdefer allocator.free(table_name);
    if (table_name.len == 0 or !isIdentStart(table_name[0])) return ParseError.InvalidFormat;
    for (table_name[1..]) |c| {
        if (!isIdentChar(c)) return ParseError.InvalidFormat;
    }

    var max_rows: ?u64 = null;
    var row_bytes: ?u64 = null;

    var columns = std.ArrayList(Column).init(allocator);
    errdefer {
        for (columns.items) |column| allocator.free(column.name);
        columns.deinit();
    }

    var defs = std.ArrayList(Def).init(allocator);
    errdefer {
        for (defs.items) |def| {
            allocator.free(def.name);
            allocator.free(def.value);
        }
        defs.deinit();
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var line_it = std.mem.splitScalar(u8, source, '\n');
    while (line_it.next()) |raw_line| {
        const line = cleanLine(raw_line);
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;

        const def = parseDef(line) orelse return ParseError.InvalidFormat;
        if (seen.contains(def.name)) return ParseError.DuplicateDef;
        try seen.put(def.name, {});
        try appendDef(&defs, allocator, def.name, def.value);

        if (std.mem.eql(u8, def.name, "MAX_ROWS")) {
            max_rows = std.fmt.parseInt(u64, def.value, 10) catch return ParseError.InvalidFormat;
            continue;
        }
        if (std.mem.eql(u8, def.name, "TABLE_ROW_BYTES") or std.mem.endsWith(u8, def.name, "_TABLE_ROW_BYTES") or std.mem.endsWith(u8, def.name, "_ROW_BYTES")) {
            row_bytes = std.fmt.parseInt(u64, def.value, 10) catch return ParseError.InvalidFormat;
            continue;
        }
        if (!isColumnDefName(def.name)) continue;

        const stride = std.fmt.parseInt(u32, def.value, 10) catch return ParseError.InvalidFormat;
        const base_name = def.name["COL_".len .. def.name.len - "_STRIDE".len];
        const col_name = try allocator.dupe(u8, base_name);
        errdefer allocator.free(col_name);
        var col_ty: ?PrimType = null;
        if (std.mem.indexOf(u8, raw_line, "//")) |comment_idx| {
            const comment = trim(raw_line[comment_idx + 2 ..]);
            if (comment.len != 0) {
                const first = std.mem.indexOfAny(u8, comment, " \t:") orelse comment.len;
                const ty_text = trim(comment[0..first]);
                if (ty_text.len != 0) {
                    col_ty = parsePrimType(ty_text) catch |err| switch (err) {
                        ParseError.UnsupportedType => return ParseError.UnsupportedType,
                        else => null,
                    };
                    if (col_ty) |ty| {
                        if (primTypeBytes(ty) != stride) return ParseError.InvalidFormat;
                    }
                }
            }
        }
        try columns.append(.{ .name = col_name, .stride = stride, .ty = col_ty });
    }

    const max_rows_value = max_rows orelse return ParseError.MissingMaxRows;
    const computed_row_bytes = blk: {
        var total: u64 = 0;
        for (columns.items) |column| {
            total = std.math.add(u64, total, column.stride) catch return ParseError.CapacityOverflow;
        }
        break :blk total;
    };
    const final_row_bytes = if (row_bytes) |declared| blk: {
        if (declared != computed_row_bytes) return ParseError.InvalidFormat;
        break :blk declared;
    } else computed_row_bytes;
    if (max_rows_value != 0 and computed_row_bytes != 0) {
        const cap = std.math.mul(u64, max_rows_value, computed_row_bytes) catch return ParseError.CapacityOverflow;
        if (cap > 64 * 1024 * 1024 * 1024) return ParseError.CapacityOverflow;
    }

    return .{
        .allocator = allocator,
        .table_name = table_name,
        .max_rows = max_rows_value,
        .columns = try columns.toOwnedSlice(),
        .row_bytes = final_row_bytes,
        .defs = try defs.toOwnedSlice(),
    };
}

fn hasDef(defs: []const Def, name: []const u8) bool {
    for (defs) |def| {
        if (std.mem.eql(u8, def.name, name)) return true;
    }
    return false;
}

pub fn writeIface(writer: anytype, schema: Schema) !void {
    try writer.writeAll("// generated by sa db init\n");
    for (schema.defs) |def| {
        try writeDef(writer, def.name, def.value);
    }
    if (!hasDef(schema.defs, "TABLE_ROW_BYTES")) {
        try writeDefInt(writer, "TABLE_ROW_BYTES", schema.row_bytes);
    }
    const alias = try std.fmt.allocPrint(schema.allocator, "{s}_ROW_BYTES", .{schema.table_name});
    defer schema.allocator.free(alias);
    if (!hasDef(schema.defs, alias)) {
        try writeDefInt(writer, alias, schema.row_bytes);
    }
}

test "schema compiler computes row bytes and preserves table alias" {
    const source =
        \\#def MAX_ROWS = 100
        \\#def COL_ID_STRIDE = 8
        \\#def COL_PRICE_STRIDE = 4
        \\#def COL_STATUS_STRIDE = 1
        \\#def TABLE_ROW_BYTES = 13
    ;
    var schema = try compile(std.testing.allocator, source, "flash_sale.sadb-schema");
    defer schema.deinit();

    try std.testing.expectEqual(@as(u64, 100), schema.max_rows);
    try std.testing.expectEqual(@as(u64, 13), schema.row_bytes);
    try std.testing.expectEqual(@as(usize, 3), schema.columns.len);
    try std.testing.expectEqualStrings("flash_sale", schema.table_name);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try writeIface(out.writer(), schema);
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "#def TABLE_ROW_BYTES = 13"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "#def flash_sale_ROW_BYTES = 13"));
}
