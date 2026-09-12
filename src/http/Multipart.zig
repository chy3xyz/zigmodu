//! `multipart/form-data` parsing — file uploads and mixed forms, in memory,
//! with the limits that keep an upload endpoint from being a memory bomb.
//!
//! ```zig
//! // inside a handler
//! var form = try ctx.multipart(.{});
//! defer form.deinit();
//! const title = form.value("title");                    // text field
//! if (form.file("avatar")) |f| { ... f.data, f.filename ... }
//! ```
//!
//! Ownership: every string in `Part` and the parts themselves belong to the
//! `Form`; call `deinit()` when done. Parsing keeps the whole body in memory
//! (the framework already buffers the request), so the `Config` limits are the
//! real protection — set `max_total_bytes` to what your upload endpoint should
//! ever accept, and let `413`/`400` surface rather than allocating blindly.
//!
//! Streaming large uploads straight to disk is deliberately out of scope: the
//! request body is already buffered by the parser, so a streaming API would
//! pretend to save memory it cannot save.

const std = @import("std");

pub const Config = struct {
    /// Maximum number of parts (text + file).
    max_parts: usize = 64,
    /// Maximum size of a single part's data.
    max_part_bytes: usize = 8 * 1024 * 1024,
    /// Maximum size across all parts.
    max_total_bytes: usize = 32 * 1024 * 1024,
};

pub const Error = error{
    NotMultipart,
    MissingBoundary,
    MalformedPart,
    TooManyParts,
    PartTooLarge,
    PayloadTooLarge,
} || std.mem.Allocator.Error;

pub const Part = struct {
    /// Field name from `Content-Disposition`.
    name: []const u8,
    /// Present only for file parts.
    filename: ?[]const u8 = null,
    /// `Content-Type` of this part, when the client sent one.
    content_type: ?[]const u8 = null,
    /// The part's data (for a file part: the file bytes).
    data: []const u8,
};

pub const Form = struct {
    allocator: std.mem.Allocator,
    parts: std.ArrayList(Part) = .empty,

    pub fn deinit(self: *Form) void {
        for (self.parts.items) |p| {
            self.allocator.free(p.name);
            self.allocator.free(p.data);
            if (p.filename) |f| self.allocator.free(f);
            if (p.content_type) |c| self.allocator.free(c);
        }
        self.parts.deinit(self.allocator);
        self.* = undefined;
    }

    /// Value of the first **non-file** part with this name (file parts have a
    /// `filename` and are skipped so a text lookup cannot silently return a
    /// blob).
    pub fn value(self: *const Form, name: []const u8) ?[]const u8 {
        for (self.parts.items) |p| {
            if (p.filename == null and std.mem.eql(u8, p.name, name)) return p.data;
        }
        return null;
    }

    /// First file part with this field name.
    pub fn file(self: *const Form, name: []const u8) ?*const Part {
        for (self.parts.items) |*p| {
            if (p.filename != null and std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// Every part with this name, text or file.
    pub fn count(self: *const Form, name: []const u8) usize {
        var n: usize = 0;
        for (self.parts.items) |p| {
            if (std.mem.eql(u8, p.name, name)) n += 1;
        }
        return n;
    }

    /// Text fields as a map (file parts excluded) — the bridge to
    /// `Context.bindStringMap`, so `bindMultipart` reuses the same binding
    /// contract as `bindForm`.
    pub fn textFields(self: *const Form, allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
        var map = std.StringHashMap([]const u8).init(allocator);
        errdefer map.deinit();
        for (self.parts.items) |p| {
            if (p.filename != null) continue;
            if (map.contains(p.name)) continue; // first wins, like value()
            try map.put(p.name, p.data);
        }
        return map;
    }
};

/// Extract the boundary token from a `Content-Type` header value.
pub fn boundaryFrom(content_type: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, content_type, "multipart/form-data") == null) return null;
    const idx = std.mem.indexOf(u8, content_type, "boundary=") orelse return null;
    var rest = std.mem.trim(u8, content_type[idx + "boundary=".len ..], " ");
    if (rest.len == 0) return null;
    if (rest[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
        rest = rest[1..end];
    } else {
        var end: usize = 0;
        while (end < rest.len and rest[end] != ';' and rest[end] != ' ') end += 1;
        rest = rest[0..end];
    }
    if (rest.len == 0) return null;
    return rest;
}

/// Parse a multipart body. `content_type` is the request's `Content-Type`.
pub fn parse(allocator: std.mem.Allocator, body: []const u8, content_type: []const u8, config: Config) Error!Form {
    const boundary = boundaryFrom(content_type) orelse {
        return if (std.mem.indexOf(u8, content_type, "multipart/form-data") == null)
            Error.NotMultipart
        else
            Error.MissingBoundary;
    };
    if (config.max_total_bytes > 0 and body.len > config.max_total_bytes) return Error.PayloadTooLarge;

    const delim = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    defer allocator.free(delim);

    var form = Form{ .allocator = allocator };
    errdefer form.deinit();

    // Walk `--boundary` occurrences; the payload of a part is everything up to
    // the next delimiter (minus its trailing CRLF).
    var pos: usize = std.mem.indexOf(u8, body, delim) orelse return Error.MalformedPart;
    while (true) {
        pos += delim.len;
        // Closing delimiter is `--boundary--`.
        if (pos + 1 < body.len and body[pos] == '-' and body[pos + 1] == '-') break;
        // Skip CRLF after the delimiter; a bare LF is tolerated.
        if (pos < body.len and body[pos] == '\r') pos += 1;
        if (pos < body.len and body[pos] == '\n') pos += 1;

        if (form.parts.items.len >= config.max_parts) return Error.TooManyParts;

        const header_end = std.mem.indexOf(u8, body[pos..], "\r\n\r\n") orelse
            std.mem.indexOf(u8, body[pos..], "\n\n") orelse return Error.MalformedPart;
        const headers = body[pos .. pos + header_end];
        const sep_len: usize = if (std.mem.indexOf(u8, body[pos..], "\r\n\r\n")) |_| 4 else 2;
        const data_start = pos + header_end + sep_len;

        const next = std.mem.indexOf(u8, body[data_start..], delim) orelse return Error.MalformedPart;
        var data_end = data_start + next;
        // Strip the CRLF that belongs to the delimiter line, not the payload.
        if (data_end >= 2 and body[data_end - 2] == '\r' and body[data_end - 1] == '\n') {
            data_end -= 2;
        } else if (data_end >= 1 and body[data_end - 1] == '\n') {
            data_end -= 1;
        }

        const data = body[data_start..data_end];
        if (config.max_part_bytes > 0 and data.len > config.max_part_bytes) return Error.PartTooLarge;

        const disposition = headerValue(headers, "content-disposition") orelse return Error.MalformedPart;
        const name = dispositionParam(disposition, "name") orelse return Error.MalformedPart;
        const filename = dispositionParam(disposition, "filename");
        const part_type = headerValue(headers, "content-type");

        try form.parts.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .filename = if (filename) |f| try allocator.dupe(u8, f) else null,
            .content_type = if (part_type) |c| try allocator.dupe(u8, c) else null,
            .data = try allocator.dupe(u8, data),
        });

        pos = data_start + next;
    }

    return form;
}

/// Case-insensitive header lookup over a raw header block.
pub fn headerValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, headers, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

/// Extract `key="value"` (or `key=value`) from a `Content-Disposition` value.
pub fn dispositionParam(disposition: []const u8, key: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, disposition, search_from, key)) |idx| {
        // Must start a token (preceded by `;` or space) and be followed by `=`.
        const before_ok = idx == 0 or disposition[idx - 1] == ';' or disposition[idx - 1] == ' ';
        if (before_ok and idx + key.len < disposition.len and disposition[idx + key.len] == '=') {
            var rest = disposition[idx + key.len + 1 ..];
            if (rest.len > 0 and rest[0] == '"') {
                const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
                return rest[1..end];
            }
            var end: usize = 0;
            while (end < rest.len and rest[end] != ';' and rest[end] != ' ') end += 1;
            rest = rest[0..end];
            return if (rest.len > 0) rest else null;
        }
        search_from = idx + key.len;
    }
    return null;
}

const testing = std.testing;

test "boundary and disposition parsing" {
    try testing.expectEqualStrings("----WebKitFormBoundaryABC", boundaryFrom("multipart/form-data; boundary=----WebKitFormBoundaryABC").?);
    try testing.expectEqualStrings("xyz", boundaryFrom("multipart/form-data; boundary=\"xyz\"").?);
    try testing.expectEqualStrings("abc", boundaryFrom("multipart/form-data; charset=utf-8; boundary=abc; foo=bar").?);
    try testing.expect(boundaryFrom("multipart/form-data") == null);
    try testing.expect(boundaryFrom("application/json") == null);

    try testing.expectEqualStrings("avatar", dispositionParam("form-data; name=\"avatar\"; filename=\"a.png\"", "name").?);
    try testing.expectEqualStrings("a.png", dispositionParam("form-data; name=\"avatar\"; filename=\"a.png\"", "filename").?);
    try testing.expect(dispositionParam("form-data; name=\"x\"", "filename") == null);
    // `name` must not match inside another parameter (`filename`).
    try testing.expectEqualStrings("n", dispositionParam("form-data; filename=\"f\"; name=\"n\"", "name").?);
}

test "parse a mixed form with a file part" {
    const allocator = testing.allocator;
    const body =
        "--BND\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n" ++
        "\r\n" ++
        "Quarterly report\r\n" ++
        "--BND\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"a.png\"\r\n" ++
        "Content-Type: image/png\r\n" ++
        "\r\n" ++
        "\x89PNG\r\n" ++
        "--BND--\r\n";

    var form = try parse(allocator, body, "multipart/form-data; boundary=BND", .{});
    defer form.deinit();

    try testing.expectEqual(@as(usize, 2), form.parts.items.len);
    try testing.expectEqualStrings("Quarterly report", form.value("title").?);
    try testing.expect(form.file("title") == null); // text lookup skips blobs
    const f = form.file("avatar").?;
    try testing.expectEqualStrings("a.png", f.filename.?);
    try testing.expectEqualStrings("image/png", f.content_type.?);
    try testing.expectEqualStrings("\x89PNG", f.data);
    // The payload kept its own CRLF, the delimiter's CRLF was stripped.
    try testing.expect(std.mem.indexOf(u8, f.data, "\r\n--") == null);
}

test "parse rejects non-multipart, missing boundary and oversized parts" {
    const allocator = testing.allocator;
    try testing.expectError(Error.NotMultipart, parse(allocator, "", "application/json", .{}));
    try testing.expectError(Error.MissingBoundary, parse(allocator, "", "multipart/form-data", .{}));

    const body = "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n12345\r\n--B--\r\n";
    try testing.expectError(Error.PartTooLarge, parse(allocator, body, "multipart/form-data; boundary=B", .{ .max_part_bytes = 3 }));
    try testing.expectError(Error.PayloadTooLarge, parse(allocator, body, "multipart/form-data; boundary=B", .{ .max_total_bytes = 4 }));
    try testing.expectError(Error.TooManyParts, parse(allocator, body, "multipart/form-data; boundary=B", .{ .max_parts = 0 }));

    // A part without Content-Disposition is malformed, not silently dropped.
    const bad = "--B\r\nContent-Type: text/plain\r\n\r\nx\r\n--B--\r\n";
    try testing.expectError(Error.MalformedPart, parse(allocator, bad, "multipart/form-data; boundary=B", .{}));
}

test "textFields bridge feeds the loose struct binder" {
    const allocator = testing.allocator;
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"full_name\"\r\n\r\nZhang San\r\n" ++
        "--B\r\nContent-Disposition: form-data; name=\"age\"\r\n\r\n42\r\n" ++
        "--B\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"a.txt\"\r\n\r\nblob\r\n" ++
        "--B--\r\n";
    var form = try parse(allocator, body, "multipart/form-data; boundary=B", .{});
    defer form.deinit();

    var map = try form.textFields(allocator);
    defer map.deinit();
    try testing.expectEqualStrings("Zhang San", map.get("full_name").?);
    try testing.expectEqual(@as(usize, 2), map.count()); // file part excluded
}
