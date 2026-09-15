//! Upload content policy — decide what a file *is* from its bytes, not from
//! what the client claims.
//!
//! `Multipart` answers "did this parse, and is it small enough". This answers
//! "is this the kind of file we accept", and it exists because the three obvious
//! ways to write that check are all broken:
//!
//! ```zig
//! // ✗ extension only: `shell.php` renamed `avatar.jpg` passes
//! if (!std.mem.endsWith(u8, filename, ".jpg")) return error.Rejected;
//!
//! // ✗ Content-Type only: the client writes the header, so it is a suggestion
//! if (!std.mem.eql(u8, part.content_type, "image/jpeg")) return error.Rejected;
//!
//! // ✗ allowing SVG: it is a script container. Served from your own origin it
//! //   is stored XSS — `.svg` with an inline <script> is not an image bug.
//! ```
//!
//! The rule that works: **sniff the bytes, then require the sniffed format and
//! the extension to agree.** A `.php` renamed `.jpg` sniffs as text, which cannot
//! match `.jpg`; a `.jpg` containing PHP text fails the same way.
//!
//! ```zig
//! var form = try http.extractMultipart(ctx, .{ .max_total_bytes = 8 << 20 });
//! defer form.deinit();
//! // Reject the whole upload if any file part is not a JPEG/PNG.
//! try http.UploadGuard.checkForm(&form, .{
//!     .extensions = &.{ "jpg", "jpeg", "png" },
//!     .formats = &.{ .jpeg, .png },
//!     .max_bytes = 5 << 20,
//! });
//! const avatar = form.file("avatar").?;   // data is now known-good
//! ```
//!
//! What this is not: a virus scanner, an image decoder, or a guarantee that the
//! bytes are well-formed beyond the header. It is the check that stops an upload
//! endpoint from becoming a file-drop for whatever an attacker can send.

const std = @import("std");
const Multipart = @import("Multipart.zig");

/// Format detected from the leading bytes (or from the text shape, for the
/// formats that have no magic number).
pub const Format = enum {
    jpeg,
    png,
    gif,
    webp,
    bmp,
    tiff,
    pdf,
    zip,
    gzip,
    mp4,
    webm,
    ogg,
    mp3,
    wav,
    /// Text or XML-ish content that is not active (txt, csv, json, xml …).
    plain,
    /// SVG: an XML document that may carry <script>. Active content.
    svg,
    /// HTML/JS: active content.
    html,
    /// Nothing matched — treat as hostile until proven otherwise.
    unknown,

    /// Formats that a browser will execute or script when served from your
    /// origin. Never accepted unless the policy says so explicitly.
    pub fn isActiveContent(self: Format) bool {
        return self == .svg or self == .html;
    }
};

pub const Error = error{
    /// File part had no usable extension, or one not in `extensions`.
    ExtensionNotAllowed,
    /// Sniffed format is not in `formats`.
    ContentNotAllowed,
    /// Extension and content disagree — the rename/upload-mismatch case.
    ExtensionContentMismatch,
    /// Sniffed active content (SVG/HTML) without an explicit opt-in.
    ActiveContentNotAllowed,
    /// Larger than `max_bytes`.
    FileTooLarge,
};

/// What an endpoint accepts. Empty lists mean "no restriction of this kind",
/// except `allow_active_content`, which is fail-closed.
pub const Policy = struct {
    /// Allowed extensions, lowercase, no dot. Empty = any extension.
    extensions: []const []const u8 = &.{},
    /// Allowed sniffed formats. Empty = any format.
    formats: []const Format = &.{},
    /// Per-file cap. `Multipart.Config` still caps the whole request; this one
    /// is per file so one part cannot consume the endpoint's entire budget.
    /// 0 = no per-file cap.
    max_bytes: usize = 0,
    /// Require `extensionOf(filename)` and `sniff(data)` to agree.
    /// Disable only for formats with no magic number (rare).
    require_extension_match: bool = true,
    /// Allow SVG/HTML. Almost always a mistake: served from your origin they
    /// are stored XSS. Off by default.
    allow_active_content: bool = false,
};

/// Result of a successful check — the caller may want it for storage metadata.
pub const Accepted = struct {
    format: Format,
    extension: []const u8,
};

/// Check one uploaded file. Returns the accepted format, or the reason it is
/// not acceptable. `filename` may be empty.
///
/// Order decides *which* error you get, and it is deliberate:
///
///   1. `FileTooLarge` — cheapest, and size is the one thing the client cannot lie about
///   2. `ActiveContentNotAllowed` — before any allowlist can bless SVG/HTML
///   3. `ExtensionNotAllowed` — extension allowlist
///   4. `ContentNotAllowed` — sniffed-format allowlist
///   5. `ExtensionContentMismatch` — extension vs content, for pairs that both passed
///
/// So a `.jpg` holding a script reports `ContentNotAllowed` (the bytes are not a
/// JPEG), while PNG bytes under a `.jpg` name report `ExtensionContentMismatch`
/// (both sides are acceptable file types, but they disagree).
pub fn check(filename: []const u8, data: []const u8, policy: Policy) Error!Accepted {
    if (policy.max_bytes > 0 and data.len > policy.max_bytes) return Error.FileTooLarge;

    const format = sniff(data);

    // Active content is refused before the allowlists are consulted: an
    // allowlist entry for "svg" should not be the only thing standing between a
    // script container and your file host.
    if (format.isActiveContent() and !policy.allow_active_content) return Error.ActiveContentNotAllowed;

    const ext = extensionOf(filename);
    if (policy.extensions.len > 0) {
        const ext_ok = if (ext) |e| containsStr(policy.extensions, e) else false;
        if (!ext_ok) return Error.ExtensionNotAllowed;
    }
    if (policy.formats.len > 0 and !containsFormat(policy.formats, format)) return Error.ContentNotAllowed;

    if (policy.require_extension_match) {
        if (ext) |e| {
            if (!extensionMatchesFormat(e, format)) return Error.ExtensionContentMismatch;
        } else if (policy.extensions.len > 0) {
            // An allowlist was given but the file has no extension to check.
            return Error.ExtensionNotAllowed;
        }
    }

    return .{ .format = format, .extension = ext orelse "" };
}

/// Check every file part of a parsed form; the first failure decides. Parts
/// without a filename are text fields and are skipped.
pub fn checkForm(form: *const Multipart.Form, policy: Policy) Error!void {
    for (form.parts.items) |part| {
        if (part.filename == null) continue;
        _ = try check(part.filename.?, part.data, policy);
    }
}

/// Sniff the format from the leading bytes. Text-ish input with no magic number
/// is classified as `.svg` / `.html` when it opens with one of those documents,
/// `.plain` otherwise.
pub fn sniff(data: []const u8) Format {
    if (data.len >= 3 and std.mem.eql(u8, data[0..3], "\xFF\xD8\xFF")) return .jpeg;
    if (data.len >= 8 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (data.len >= 6 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a"))) return .gif;
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF")) {
        if (std.mem.eql(u8, data[8..12], "WEBP")) return .webp;
        if (std.mem.eql(u8, data[8..12], "WAVE")) return .wav;
    }
    if (data.len >= 2 and std.mem.eql(u8, data[0..2], "BM")) return .bmp;
    if (data.len >= 4 and (std.mem.eql(u8, data[0..4], "II\x2a\x00") or std.mem.eql(u8, data[0..4], "MM\x00\x2a"))) return .tiff;
    if (data.len >= 5 and std.mem.eql(u8, data[0..5], "%PDF-")) return .pdf;
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "PK\x03\x04")) return .zip;
    if (data.len >= 2 and std.mem.eql(u8, data[0..2], "\x1f\x8b")) return .gzip;
    if (isIsoBmff(data)) return .mp4;
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "\x1a\x45\xdf\xa3")) return .webm;
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "OggS")) return .ogg;
    if (data.len >= 3 and std.mem.eql(u8, data[0..3], "ID3")) return .mp3;
    if (data.len >= 2 and data[0] == 0xFF and (data[1] & 0xE0) == 0xE0) return .mp3;

    // No magic number: decide from the text shape. Anything opening with a tag
    // is inspected for the two active containers before falling back to plain.
    const head = textHead(data);
    if (head.len > 0 and head[0] == '<') {
        if (containsAsciiIgnoreCase(head, "<svg")) return .svg;
        if (containsAsciiIgnoreCase(head, "<!doctype html") or
            containsAsciiIgnoreCase(head, "<html") or
            containsAsciiIgnoreCase(head, "<script") or
            containsAsciiIgnoreCase(head, "<body")) return .html;
        // XML-ish but not a known active container: plain text.
        return .plain;
    }
    if (head.len > 0) return .plain;

    return .unknown;
}

/// Lowercased extension of `filename`, without the dot. Null when there is none.
pub fn extensionOf(filename: []const u8) ?[]const u8 {
    // Look only at the final path component so "../../x.jpg" cannot smuggle a
    // separator into the extension compare.
    const base = filename[std.mem.lastIndexOfAny(u8, filename, "/\\") orelse 0 ..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    if (dot + 1 >= base.len) return null;
    return base[dot + 1 ..];
}

/// Extension ↔ sniffed format agreement. Extensions that cannot be expressed as
/// a magic number (txt → plain) are matched by family, not by exact equality.
pub fn extensionMatchesFormat(ext: []const u8, format: Format) bool {
    return switch (format) {
        .jpeg => eqlAny(ext, &.{ "jpg", "jpeg", "jpe" }),
        .png => std.mem.eql(u8, ext, "png"),
        .gif => std.mem.eql(u8, ext, "gif"),
        .webp => std.mem.eql(u8, ext, "webp"),
        .bmp => std.mem.eql(u8, ext, "bmp"),
        .tiff => eqlAny(ext, &.{ "tif", "tiff" }),
        .pdf => std.mem.eql(u8, ext, "pdf"),
        .gzip => eqlAny(ext, &.{ "gz", "tgz" }),
        .zip => eqlAny(ext, &.{ "zip", "docx", "xlsx", "pptx", "jar", "apk", "epub" }),
        .mp4 => eqlAny(ext, &.{ "mp4", "m4v", "mov", "m4a", "3gp" }),
        .webm => eqlAny(ext, &.{ "webm", "mkv" }),
        .ogg => eqlAny(ext, &.{ "ogg", "oga", "ogv", "opus" }),
        .mp3 => std.mem.eql(u8, ext, "mp3"),
        .wav => std.mem.eql(u8, ext, "wav"),
        .svg => std.mem.eql(u8, ext, "svg"),
        .html => eqlAny(ext, &.{ "html", "htm", "js", "mjs", "xhtml" }),
        .plain, .unknown => eqlAny(ext, &.{ "txt", "text", "csv", "tsv", "json", "xml", "yaml", "yml", "md", "log", "ini", "toml" }),
    };
}

/// True for an ISO base media file: `[4-byte size][ftyp][brand…]`.
///
/// Size must be plausible (≥ 8, or the `1` extended-size marker) — matching
/// `ftyp` at a fixed offset without the size check accepts any file whose bytes
/// happen to contain those four letters there.
fn isIsoBmff(data: []const u8) bool {
    if (data.len < 12) return false;
    if (!std.mem.eql(u8, data[4..8], "ftyp")) return false;
    const size = std.mem.readInt(u32, data[0..4], .big);
    if (size == 0 or size == 1) return true; // to-end-of-file, or 64-bit extended size
    return size >= 8 and size <= data.len;
}

fn textHead(data: []const u8) []const u8 {
    var i: usize = 0;
    // Skip a UTF-8/UTF-16 BOM and leading whitespace before judging the shape.
    if (std.mem.startsWith(u8, data, "\xEF\xBB\xBF")) i = 3;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\r' or data[i] == '\n')) i += 1;
    const rest = data[i..];
    // A NUL in the first bytes means binary, not text.
    if (std.mem.indexOfScalar(u8, rest[0..@min(rest.len, 64)], 0) != null) return &.{};
    return rest[0..@min(rest.len, 256)];
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn containsStr(list: []const []const u8, want: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, want)) return true;
    return false;
}

fn containsFormat(list: []const Format, want: Format) bool {
    for (list) |item| if (item == want) return true;
    return false;
}

fn eqlAny(value: []const u8, candidates: []const []const u8) bool {
    return containsStr(candidates, value);
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

const jpeg_bytes = "\xFF\xD8\xFF\xE0" ++ "jfif-ish padding";
const png_bytes = "\x89PNG\r\n\x1a\n" ++ "padding";
const php_bytes = "<?php system($_GET['c']); ?>";

test "sniff identifies the formats an upload endpoint accepts" {
    try std.testing.expectEqual(Format.jpeg, sniff(jpeg_bytes));
    try std.testing.expectEqual(Format.png, sniff(png_bytes));
    try std.testing.expectEqual(Format.gif, sniff("GIF89a\x01\x00"));
    try std.testing.expectEqual(Format.webp, sniff("RIFF\x24\x00\x00\x00WEBPVP8 "));
    try std.testing.expectEqual(Format.wav, sniff("RIFF\x24\x00\x00\x00WAVEfmt "));
    try std.testing.expectEqual(Format.pdf, sniff("%PDF-1.7\n%âãÏÓ"));
    try std.testing.expectEqual(Format.zip, sniff("PK\x03\x04\x14\x00"));
    try std.testing.expectEqual(Format.gzip, sniff("\x1f\x8b\x08\x00"));
    try std.testing.expectEqual(Format.mp3, sniff("ID3\x04\x00\x00"));
    try std.testing.expectEqual(Format.unknown, sniff("\x00\x01\x02\x03binary-ish"));
}

test "sniff reads ISO-BMFF only with a plausible box size" {
    // size = 0x10 (16) covering the whole box, 'ftyp', brand 'isom'.
    try std.testing.expectEqual(Format.mp4, sniff("\x00\x00\x00\x10ftypisom\x00\x00\x02\x00"));
    // `ftyp` at offset 4 but a nonsense size: not a media file.
    try std.testing.expectEqual(Format.unknown, sniff("\x00\x00\x00\x02ftypisom\x00\x00\x02\x00"));
    // Size claims more bytes than were uploaded.
    try std.testing.expectEqual(Format.unknown, sniff("\x00\x00\x00\x40ftypisom\x00\x00\x02\x00"));
    // Truncated header.
    try std.testing.expectEqual(Format.unknown, sniff("\x00\x00\x00\x10ftyp"));
}

test "sniff separates active content from plain text" {
    try std.testing.expectEqual(Format.svg, sniff("<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>"));
    try std.testing.expectEqual(Format.svg, sniff("  \n<SVG onload=alert(1)/>"));
    try std.testing.expectEqual(Format.html, sniff("<!DOCTYPE html><html><body>hi"));
    try std.testing.expectEqual(Format.html, sniff("<script>alert(1)</script>"));
    try std.testing.expectEqual(Format.plain, sniff("id,name\n1,Zhang San\n"));
    try std.testing.expectEqual(Format.plain, sniff("<?xml version=\"1.0\"?><note>hi</note>"));
    try std.testing.expectEqual(Format.plain, sniff("\xEF\xBB\xBF{\"a\":1}"));
}

test "extensionOf handles paths and missing extensions" {
    try std.testing.expectEqualStrings("jpg", extensionOf("avatar.jpg").?);
    try std.testing.expectEqualStrings("JPG", extensionOf("avatar.JPG").?); // caller lowercases for compare
    try std.testing.expectEqualStrings("jpg", extensionOf("/tmp/a.b/avatar.jpg").?);
    try std.testing.expectEqualStrings("png", extensionOf("C:\\uploads\\a.png").?);
    try std.testing.expect(extensionOf("noext") == null);
    try std.testing.expect(extensionOf("trailing.") == null);
    // A dot in a directory must not become the extension.
    try std.testing.expect(extensionOf("dir.d/file") == null);
}

test "a renamed script cannot pass as an image" {
    const policy = Policy{
        .extensions = &.{ "jpg", "jpeg", "png" },
        .formats = &.{ .jpeg, .png },
    };
    // The exact bypass an extension-only check lets through: the bytes are not
    // an accepted format, so it fails on content even though the name is fine.
    try std.testing.expectError(Error.ContentNotAllowed, check("avatar.jpg", php_bytes, policy));
    // A .txt name is simply not on the extension allowlist — the client's
    // Content-Type header is never consulted, so it cannot argue either way.
    try std.testing.expectError(Error.ExtensionNotAllowed, check("avatar.txt", php_bytes, policy));
    // Real image, allowed pair.
    const ok = try check("avatar.jpg", jpeg_bytes, policy);
    try std.testing.expectEqual(Format.jpeg, ok.format);

    // Cross-family rename: PNG bytes under a .jpg name. Both sides are
    // acceptable file types, they just disagree — the more specific error.
    try std.testing.expectError(Error.ExtensionContentMismatch, check("avatar.jpg", png_bytes, policy));
}

test "SVG is refused even when the allowlist names it" {
    const svg = "<svg onload=\"fetch('/steal')\"></svg>";
    // The extension says image, the content is a script container.
    try std.testing.expectError(Error.ActiveContentNotAllowed, check("logo.svg", svg, .{ .extensions = &.{"svg"} }));
    // Active-content refusal comes first, before any format allowlist is
    // consulted — an allowlist must not be the only thing guarding a script host.
    try std.testing.expectError(Error.ActiveContentNotAllowed, check("logo.svg", svg, .{ .formats = &.{ .jpeg, .png } }));
    // Renaming it does not help either: the content is what is judged.
    try std.testing.expectError(Error.ActiveContentNotAllowed, check("logo.png", svg, .{ .extensions = &.{"png"} }));
    // Opting in is possible, and explicit.
    const accepted = try check("logo.svg", svg, .{
        .extensions = &.{"svg"},
        .formats = &.{.svg},
        .allow_active_content = true,
    });
    try std.testing.expectEqual(Format.svg, accepted.format);
}

test "policy caps a single file and requires a known extension" {
    const tiny = "\xFF\xD8\xFF\xE0"; // 4 bytes, valid JPEG header

    // Size is judged before anything else: a 20-byte file against an 8-byte cap.
    try std.testing.expectError(Error.FileTooLarge, check("big.jpg", jpeg_bytes, .{ .max_bytes = 8 }));

    // No extension at all is rejected once an allowlist is in play.
    const policy = Policy{ .extensions = &.{"jpg"} };
    try std.testing.expectError(Error.ExtensionNotAllowed, check("noext", tiny, policy));
    try std.testing.expectError(Error.ExtensionNotAllowed, check("noext", tiny, .{ .extensions = &.{"jpg"}, .max_bytes = 0 }));
    _ = try check("ok.jpg", tiny, policy);

    // Empty lists mean "no restriction of that kind".
    _ = try check("anything", jpeg_bytes, .{});
}

test "checkForm refuses a form whose file part is not what it claims" {
    const allocator = std.testing.allocator;
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nreport\r\n" ++
        "--B\r\nContent-Disposition: form-data; name=\"doc\"; filename=\"report.pdf\"\r\n" ++
        "Content-Type: application/pdf\r\n\r\n%PDF-1.4\r\n" ++
        "--B--\r\n";
    var form = try Multipart.parse(allocator, body, "multipart/form-data; boundary=B", .{});
    defer form.deinit();

    // Text parts are skipped; the PDF part satisfies an image+pdf policy.
    try checkForm(&form, .{
        .extensions = &.{ "pdf", "jpg" },
        .formats = &.{ .pdf, .jpeg },
        .max_bytes = 1 << 20,
    });

    // Same form, image-only policy → the PDF part is refused.
    try std.testing.expectError(Error.ContentNotAllowed, checkForm(&form, .{
        .extensions = &.{ "jpg", "pdf" },
        .formats = &.{.jpeg},
    }));
}
