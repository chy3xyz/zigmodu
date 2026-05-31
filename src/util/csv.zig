const std = @import("std");

/// CSV reader — streaming, RFC 4180 compatible.
pub const Reader = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,
    delimiter: u8 = ',',
    quote: u8 = '"',
    has_header: bool = true,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Self {
        return .{ .allocator = allocator, .input = input };
    }

    /// Read the header row. Must be called before readRow().
    pub fn readHeader(self: *Self) ![][]const u8 {
        if (!self.has_header) return &.{};
        self.has_header = false;
        return (try self.readRow()) orelse error.EmptyFile;
    }

    /// Read next row as slices into input. Returns null at EOF.
    pub fn readRow(self: *Self) !?[][]const u8 {
        if (self.pos >= self.input.len) return null;
        var fields = std.ArrayList([]const u8).empty;

        while (self.pos < self.input.len) {
            const field = try self.readField();
            try fields.append(self.allocator, field);
            if (self.pos >= self.input.len) break;
            if (self.input[self.pos] == '\n') {
                self.pos += 1;
                break;
            }
            if (self.input[self.pos] == '\r') {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
                break;
            }
        }
        if (fields.items.len == 0) return null;
        return @as(?[][]const u8, try fields.toOwnedSlice(self.allocator));
    }

    fn readField(self: *Self) ![]const u8 {
        if (self.pos >= self.input.len) return &.{};
        const start = self.pos;
        if (self.input[self.pos] == self.quote) {
            self.pos += 1;
            while (self.pos < self.input.len) {
                if (self.input[self.pos] == self.quote) {
                    if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == self.quote) {
                        self.pos += 2;
                        continue;
                    }
                    const content = self.input[start + 1 .. self.pos];
                    self.pos += 1;
                    if (self.pos < self.input.len and self.input[self.pos] == self.delimiter) self.pos += 1;
                    return content;
                }
                self.pos += 1;
            }
            return error.UnterminatedQuote;
        }
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == self.delimiter) {
                const field = self.input[start..self.pos];
                self.pos += 1;
                return field;
            }
            if (self.input[self.pos] == '\n' or self.input[self.pos] == '\r') {
                return self.input[start..self.pos];
            }
            self.pos += 1;
        }
        return self.input[start..self.pos];
    }

    /// Read all rows into an ArrayList of string slices.
    pub fn readAll(self: *Self) !std.ArrayList([][]const u8) {
        var rows = std.ArrayList([][]const u8).empty;
        if (self.has_header) {
            _ = try self.readHeader();
        }
        while (try self.readRow()) |row| {
            try rows.append(self.allocator, row);
        }
        return rows;
    }
};

/// CSV writer — streaming, RFC 4180 compatible.
pub const Writer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
    delimiter: u8 = ',',
    quote_all: bool = false,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator, .buf = std.ArrayList(u8).empty };
    }

    pub fn deinit(self: *Self) void {
        self.buf.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn writeHeader(self: *Self, headers: []const []const u8) !void {
        try self.writeRow(headers);
    }

    pub fn writeRow(self: *Self, fields: []const []const u8) !void {
        if (self.buf.items.len > 0) try self.buf.append(self.allocator, '\n');
        for (fields, 0..) |f, i| {
            if (i > 0) try self.buf.append(self.allocator, self.delimiter);
            try self.writeField(f);
        }
    }

    fn writeField(self: *Self, field: []const u8) !void {
        const needs_quote = self.quote_all or
            std.mem.indexOfAny(u8, field, ",\"\n\r") != null;
        if (needs_quote) {
            try self.buf.append(self.allocator, '"');
            for (field) |c| {
                if (c == '"') try self.buf.appendSlice(self.allocator, "\"\"") else try self.buf.append(self.allocator, c);
            }
            try self.buf.append(self.allocator, '"');
        } else {
            try self.buf.appendSlice(self.allocator, field);
        }
    }

    pub fn toOwnedSlice(self: *Self) ![]const u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }

    pub fn items(self: *Self) []const u8 {
        return self.buf.items;
    }
};

/// Parse a CSV string into an array of rows. Convenience wrapper.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList([][]const u8) {
    var reader = Reader.init(allocator, input);
    return try reader.readAll();
}

/// Encode rows to CSV string. Convenience wrapper.
pub fn encode(allocator: std.mem.Allocator, headers: []const []const u8, rows: []const [][]const u8) ![]const u8 {
    var writer = Writer.init(allocator);
    defer writer.deinit();
    try writer.writeHeader(headers);
    for (rows) |row| try writer.writeRow(row);
    return try writer.toOwnedSlice();
}

// ── Tests ──

test "parse simple CSV" {
    const a = std.testing.allocator;
    var rows = try parse(a, "name,age\nAlice,30\nBob,25");
    defer {
        for (rows.items) |r| a.free(r);
        rows.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqualStrings("Alice", rows.items[0][0]);
    try std.testing.expectEqualStrings("30", rows.items[0][1]);
}

test "parse quoted fields" {
    const a = std.testing.allocator;
    var rows = try parse(a, "\"name\",\"age\"\n\"Alice, Jr.\",30");
    defer {
        for (rows.items) |r| a.free(r);
        rows.deinit(a);
    }
    try std.testing.expectEqualStrings("Alice, Jr.", rows.items[0][0]);
}

test "encode CSV" {
    const a = std.testing.allocator;
    var w = Writer.init(a);
    defer w.deinit();
    try w.writeHeader(&.{ "name", "age" });
    try w.writeRow(&.{ "Alice", "30" });
    try w.writeRow(&.{ "Bob", "25" });
    const csv = try w.toOwnedSlice();
    defer a.free(csv);
    try std.testing.expect(std.mem.indexOf(u8, csv, "Alice,30") != null);
}

test "write row with comma" {
    const a = std.testing.allocator;
    var w = Writer.init(a);
    defer w.deinit();
    try w.writeRow(&.{ "Alice, Jr.", "30" });
    const csv = try w.toOwnedSlice();
    defer a.free(csv);
    try std.testing.expect(std.mem.indexOf(u8, csv, "\"Alice, Jr.\"") != null);
}

test "reader reads header then rows" {
    const a = std.testing.allocator;
    var r = Reader.init(a, "a,b\n1,2");
    const h = try r.readHeader();
    defer a.free(h);
    try std.testing.expectEqualStrings("a", h[0]);
    const row = try r.readRow();
    defer a.free(row.?);
    try std.testing.expectEqualStrings("1", row.?[0]);
    try std.testing.expect(try r.readRow() == null);
}
