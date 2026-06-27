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

pub const LOGICAL_NONE: u32 = 0;
pub const LOGICAL_DECIMAL_I64: u32 = 1;
pub const LOGICAL_DATE_DAYS: u32 = 2;
pub const LOGICAL_TIMESTAMP_MS: u32 = 3;
pub const LOGICAL_TIMESTAMP_US: u32 = 4;
pub const LOGICAL_BOOL: u32 = 5;
pub const LOGICAL_NULL_BITMAP: u32 = 6;

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
    logical_type: u32 = LOGICAL_NONE,
    logical_scale: u32 = 0,
    nullable: bool = false,
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

const CompileOptions = struct {
    collect_defs: bool = true,
};

const InlineSeenDefSet = struct {
    const capacity = 64;

    allocator: std.mem.Allocator,
    names: [capacity]?[]const u8 = [_]?[]const u8{null} ** capacity,
    fallback: ?std.StringHashMap(void) = null,

    fn init(allocator: std.mem.Allocator) InlineSeenDefSet {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *InlineSeenDefSet) void {
        if (self.fallback) |*map| map.deinit();
    }

    fn containsOrPut(self: *InlineSeenDefSet, name: []const u8) !bool {
        if (self.fallback) |*map| {
            if (map.contains(name)) return true;
            try map.put(name, {});
            return false;
        }

        var idx: usize = @intCast(std.hash.Wyhash.hash(0, name) & (capacity - 1));
        var probes: usize = 0;
        while (probes < capacity) : (probes += 1) {
            if (self.names[idx]) |existing| {
                if (std.mem.eql(u8, existing, name)) return true;
            } else {
                self.names[idx] = name;
                return false;
            }
            idx = (idx + 1) & (capacity - 1);
        }

        var map = std.StringHashMap(void).init(self.allocator);
        errdefer map.deinit();
        try map.ensureTotalCapacity(capacity + 1);
        for (self.names) |existing| {
            if (existing) |seen_name| try map.put(seen_name, {});
        }
        if (map.contains(name)) return true;
        try map.put(name, {});
        self.fallback = map;
        return false;
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
        const filename = try std.fmt.allocPrint(allocator, "{s}.sai", .{stem});
        defer allocator.free(filename);
        return try std.fs.path.join(allocator, &.{ dir, filename });
    }
    return try std.fmt.allocPrint(allocator, "{s}.sai", .{stem});
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

fn logicalTypeFitsPrimitive(logical_type: u32, ty: PrimType) bool {
    return switch (logical_type) {
        LOGICAL_NONE => true,
        LOGICAL_DECIMAL_I64, LOGICAL_DATE_DAYS, LOGICAL_TIMESTAMP_MS, LOGICAL_TIMESTAMP_US => ty == .i64,
        LOGICAL_BOOL => ty == .i1 or ty == .u8 or ty == .u64,
        LOGICAL_NULL_BITMAP => ty == .u8,
        else => false,
    };
}

fn parseScaleSuffix(token: []const u8, prefix: []const u8) ParseError!?u32 {
    if (!std.mem.startsWith(u8, token, prefix)) return null;
    if (token.len < prefix.len + 3) return ParseError.InvalidFormat;
    if (token[prefix.len] != '(' or token[token.len - 1] != ')') return ParseError.InvalidFormat;
    const body = token[prefix.len + 1 .. token.len - 1];
    if (body.len == 0) return ParseError.InvalidFormat;
    const scale = std.fmt.parseInt(u32, body, 10) catch return ParseError.InvalidFormat;
    if (scale > 18) return ParseError.InvalidFormat;
    return scale;
}

fn parseLogicalAnnotations(comment_tail: []const u8, ty: PrimType) ParseError!struct { logical_type: u32, logical_scale: u32, nullable: bool } {
    const annotation_text = blk: {
        const colon = std.mem.indexOfScalar(u8, comment_tail, ':') orelse comment_tail.len;
        break :blk std.mem.trim(u8, comment_tail[0..colon], " \t\r,");
    };
    var logical_type: u32 = LOGICAL_NONE;
    var logical_scale: u32 = 0;
    var nullable = false;
    var tokens = std.mem.tokenizeAny(u8, annotation_text, " \t\r,");
    while (tokens.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r,");
        if (token.len == 0) continue;
        if (std.mem.eql(u8, token, "nullable")) {
            nullable = true;
            continue;
        }
        var next_type: u32 = LOGICAL_NONE;
        var next_scale: u32 = 0;
        if (try parseScaleSuffix(token, "decimal")) |scale| {
            next_type = LOGICAL_DECIMAL_I64;
            next_scale = scale;
        } else if (try parseScaleSuffix(token, "money")) |scale| {
            next_type = LOGICAL_DECIMAL_I64;
            next_scale = scale;
        } else if (std.mem.eql(u8, token, "date") or std.mem.eql(u8, token, "date_days")) {
            next_type = LOGICAL_DATE_DAYS;
        } else if (std.mem.eql(u8, token, "timestamp_ms")) {
            next_type = LOGICAL_TIMESTAMP_MS;
        } else if (std.mem.eql(u8, token, "timestamp_us")) {
            next_type = LOGICAL_TIMESTAMP_US;
        } else if (std.mem.eql(u8, token, "bool")) {
            next_type = LOGICAL_BOOL;
        } else if (std.mem.eql(u8, token, "null_bitmap")) {
            next_type = LOGICAL_NULL_BITMAP;
        } else {
            return ParseError.UnsupportedType;
        }
        if (logical_type != LOGICAL_NONE) return ParseError.InvalidFormat;
        if (!logicalTypeFitsPrimitive(next_type, ty)) return ParseError.InvalidFormat;
        logical_type = next_type;
        logical_scale = next_scale;
    }
    return .{ .logical_type = logical_type, .logical_scale = logical_scale, .nullable = nullable };
}

fn compileWithOptions(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: []const u8,
    options: CompileOptions,
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
    defer if (!options.collect_defs) defs.deinit();
    errdefer if (options.collect_defs) {
        for (defs.items) |def| {
            allocator.free(def.name);
            allocator.free(def.value);
        }
        defs.deinit();
    };

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var init_seen = InlineSeenDefSet.init(allocator);
    defer init_seen.deinit();

    var line_it = std.mem.splitScalar(u8, source, '\n');
    while (line_it.next()) |raw_line| {
        const line = cleanLine(raw_line);
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;

        const def = parseDef(line) orelse return ParseError.InvalidFormat;
        if (options.collect_defs) {
            if (seen.contains(def.name)) return ParseError.DuplicateDef;
            try seen.put(def.name, {});
            try appendDef(&defs, allocator, def.name, def.value);
        } else if (try init_seen.containsOrPut(def.name)) {
            return ParseError.DuplicateDef;
        }

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
        var logical_type: u32 = LOGICAL_NONE;
        var logical_scale: u32 = 0;
        var nullable = false;
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
                        const annotations = try parseLogicalAnnotations(comment[first..], ty);
                        logical_type = annotations.logical_type;
                        logical_scale = annotations.logical_scale;
                        nullable = annotations.nullable;
                    }
                }
            }
        }
        try columns.append(.{ .name = col_name, .stride = stride, .ty = col_ty, .logical_type = logical_type, .logical_scale = logical_scale, .nullable = nullable });
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

    const owned_defs = if (options.collect_defs)
        try defs.toOwnedSlice()
    else
        try allocator.alloc(Def, 0);

    return .{
        .allocator = allocator,
        .table_name = table_name,
        .max_rows = max_rows_value,
        .columns = try columns.toOwnedSlice(),
        .row_bytes = final_row_bytes,
        .defs = owned_defs,
    };
}

pub fn compile(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: []const u8,
) ParseError!Schema {
    return compileWithOptions(allocator, source, source_path, .{});
}

pub fn compileInitFast(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: []const u8,
) ParseError!Schema {
    return compileWithOptions(allocator, source, source_path, .{ .collect_defs = false });
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

test "schema compiler parses logical column annotations" {
    const source =
        \\#def MAX_ROWS = 16
        \\#def COL_AMOUNT_STRIDE = 8 // i64 decimal(2) nullable : invoice amount
        \\#def COL_DUE_DATE_STRIDE = 8 // i64 date
        \\#def COL_POSTED_AT_STRIDE = 8 // i64 timestamp_ms
        \\#def COL_ACTIVE_STRIDE = 1 // u8 bool
    ;
    var compiled = try compile(std.testing.allocator, source, "erp.sadb-schema");
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 4), compiled.columns.len);
    try std.testing.expectEqual(@as(u32, LOGICAL_DECIMAL_I64), compiled.columns[0].logical_type);
    try std.testing.expectEqual(@as(u32, 2), compiled.columns[0].logical_scale);
    try std.testing.expect(compiled.columns[0].nullable);
    try std.testing.expectEqual(@as(u32, LOGICAL_DATE_DAYS), compiled.columns[1].logical_type);
    try std.testing.expectEqual(@as(u32, LOGICAL_TIMESTAMP_MS), compiled.columns[2].logical_type);
    try std.testing.expectEqual(@as(u32, LOGICAL_BOOL), compiled.columns[3].logical_type);
}

test "schema compiler rejects incompatible logical annotations" {
    const source =
        \\#def MAX_ROWS = 16
        \\#def COL_AMOUNT_STRIDE = 8 // u64 decimal(2)
    ;
    try std.testing.expectError(ParseError.InvalidFormat, compile(std.testing.allocator, source, "bad.sadb-schema"));
}

test "schema init fast compiler preserves init metadata without defs" {
    const source =
        \\#def MAX_ROWS = 16
        \\#def COL_AMOUNT_STRIDE = 8 // i64 decimal(2) nullable
        \\#def COL_DUE_DATE_STRIDE = 8 // i64 date
        \\#def COL_ACTIVE_STRIDE = 1 // u8 bool
        \\#def TABLE_ROW_BYTES = 17
    ;

    var fast = try compileInitFast(std.testing.allocator, source, "erp_init_fast.sadb-schema");
    defer fast.deinit();
    var full = try compile(std.testing.allocator, source, "erp_init_fast.sadb-schema");
    defer full.deinit();

    try std.testing.expectEqualStrings(full.table_name, fast.table_name);
    try std.testing.expectEqual(full.max_rows, fast.max_rows);
    try std.testing.expectEqual(full.row_bytes, fast.row_bytes);
    try std.testing.expectEqual(@as(usize, 0), fast.defs.len);
    try std.testing.expectEqual(full.columns.len, fast.columns.len);
    for (full.columns, fast.columns) |expected, actual| {
        try std.testing.expectEqualStrings(expected.name, actual.name);
        try std.testing.expectEqual(expected.stride, actual.stride);
        try std.testing.expectEqual(expected.ty, actual.ty);
        try std.testing.expectEqual(expected.logical_type, actual.logical_type);
        try std.testing.expectEqual(expected.logical_scale, actual.logical_scale);
        try std.testing.expectEqual(expected.nullable, actual.nullable);
    }
}

test "schema init fast compiler rejects duplicate defs" {
    const source =
        \\#def MAX_ROWS = 16
        \\#def COL_ID_STRIDE = 8 // u64
        \\#def COL_ID_STRIDE = 8 // u64
    ;

    try std.testing.expectError(ParseError.DuplicateDef, compileInitFast(std.testing.allocator, source, "dup_fast.sadb-schema"));
}

test "schema init fast compiler duplicate check falls back past inline capacity" {
    var source = std.ArrayList(u8).init(std.testing.allocator);
    defer source.deinit();

    try source.appendSlice("#def MAX_ROWS = 16\n");
    var idx: usize = 0;
    while (idx < InlineSeenDefSet.capacity + 1) : (idx += 1) {
        try source.writer().print("#def COL_C{d}_STRIDE = 8 // u64\n", .{idx});
    }
    try source.appendSlice("#def COL_C0_STRIDE = 8 // u64\n");

    try std.testing.expectError(ParseError.DuplicateDef, compileInitFast(std.testing.allocator, source.items, "dup_fallback_fast.sadb-schema"));
}
