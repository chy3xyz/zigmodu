//! HPACK (RFC 7541) — static + dynamic table encode/decode for HTTP/2.
//! Huffman string literals (RFC 7541 Appendix B) are supported.

const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
    /// Ownership of `name` / `value` once the header leaves the producer.
    /// `Decoder.decode` sets these explicitly so `freeHeaders` never has to
    /// guess; hand-built literals keep the default and fall back to the
    /// static-table fingerprint.
    name_owner: Owner = .unspecified,
    value_owner: Owner = .unspecified,
};

/// Provenance of a `Header` slice, consumed by `freeHeaders`.
pub const Owner = enum {
    /// Heap slice belonging to this header — `freeHeaders` releases it.
    owned,
    /// Borrowed slice (static table, caller memory) — never released.
    borrowed,
    /// Producer did not say — `freeHeaders` falls back to `isStaticSlice`.
    unspecified,
};

/// RFC 7541 Appendix A static table (subset + common entries 1–61).
const static_table = [_]Header{
    .{ .name = "", .value = "" }, // 0 unused
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

/// RFC 7541 Appendix B — MSB-aligned canonical Huffman codes (256 octets + EOS).
const HuffmanSym = struct { len: u8, code: u32 };
const huffman_table = [_]HuffmanSym{
    .{ .len = 13, .code = 0xFFC00000 }, // 0
    .{ .len = 23, .code = 0xFFFFB000 }, // 1
    .{ .len = 28, .code = 0xFFFFFE20 }, // 2
    .{ .len = 28, .code = 0xFFFFFE30 }, // 3
    .{ .len = 28, .code = 0xFFFFFE40 }, // 4
    .{ .len = 28, .code = 0xFFFFFE50 }, // 5
    .{ .len = 28, .code = 0xFFFFFE60 }, // 6
    .{ .len = 28, .code = 0xFFFFFE70 }, // 7
    .{ .len = 28, .code = 0xFFFFFE80 }, // 8
    .{ .len = 24, .code = 0xFFFFEA00 }, // 9
    .{ .len = 30, .code = 0xFFFFFFF0 }, // 10
    .{ .len = 28, .code = 0xFFFFFE90 }, // 11
    .{ .len = 28, .code = 0xFFFFFEA0 }, // 12
    .{ .len = 30, .code = 0xFFFFFFF4 }, // 13
    .{ .len = 28, .code = 0xFFFFFEB0 }, // 14
    .{ .len = 28, .code = 0xFFFFFEC0 }, // 15
    .{ .len = 28, .code = 0xFFFFFED0 }, // 16
    .{ .len = 28, .code = 0xFFFFFEE0 }, // 17
    .{ .len = 28, .code = 0xFFFFFEF0 }, // 18
    .{ .len = 28, .code = 0xFFFFFF00 }, // 19
    .{ .len = 28, .code = 0xFFFFFF10 }, // 20
    .{ .len = 28, .code = 0xFFFFFF20 }, // 21
    .{ .len = 30, .code = 0xFFFFFFF8 }, // 22
    .{ .len = 28, .code = 0xFFFFFF30 }, // 23
    .{ .len = 28, .code = 0xFFFFFF40 }, // 24
    .{ .len = 28, .code = 0xFFFFFF50 }, // 25
    .{ .len = 28, .code = 0xFFFFFF60 }, // 26
    .{ .len = 28, .code = 0xFFFFFF70 }, // 27
    .{ .len = 28, .code = 0xFFFFFF80 }, // 28
    .{ .len = 28, .code = 0xFFFFFF90 }, // 29
    .{ .len = 28, .code = 0xFFFFFFA0 }, // 30
    .{ .len = 28, .code = 0xFFFFFFB0 }, // 31
    .{ .len = 6, .code = 0x50000000 }, // 32
    .{ .len = 10, .code = 0xFE000000 }, // 33
    .{ .len = 10, .code = 0xFE400000 }, // 34
    .{ .len = 12, .code = 0xFFA00000 }, // 35
    .{ .len = 13, .code = 0xFFC80000 }, // 36
    .{ .len = 6, .code = 0x54000000 }, // 37
    .{ .len = 8, .code = 0xF8000000 }, // 38
    .{ .len = 11, .code = 0xFF400000 }, // 39
    .{ .len = 10, .code = 0xFE800000 }, // 40
    .{ .len = 10, .code = 0xFEC00000 }, // 41
    .{ .len = 8, .code = 0xF9000000 }, // 42
    .{ .len = 11, .code = 0xFF600000 }, // 43
    .{ .len = 8, .code = 0xFA000000 }, // 44
    .{ .len = 6, .code = 0x58000000 }, // 45
    .{ .len = 6, .code = 0x5C000000 }, // 46
    .{ .len = 6, .code = 0x60000000 }, // 47
    .{ .len = 5, .code = 0x00000000 }, // 48
    .{ .len = 5, .code = 0x08000000 }, // 49
    .{ .len = 5, .code = 0x10000000 }, // 50
    .{ .len = 6, .code = 0x64000000 }, // 51
    .{ .len = 6, .code = 0x68000000 }, // 52
    .{ .len = 6, .code = 0x6C000000 }, // 53
    .{ .len = 6, .code = 0x70000000 }, // 54
    .{ .len = 6, .code = 0x74000000 }, // 55
    .{ .len = 6, .code = 0x78000000 }, // 56
    .{ .len = 6, .code = 0x7C000000 }, // 57
    .{ .len = 7, .code = 0xB8000000 }, // 58
    .{ .len = 8, .code = 0xFB000000 }, // 59
    .{ .len = 15, .code = 0xFFF80000 }, // 60
    .{ .len = 6, .code = 0x80000000 }, // 61
    .{ .len = 12, .code = 0xFFB00000 }, // 62
    .{ .len = 10, .code = 0xFF000000 }, // 63
    .{ .len = 13, .code = 0xFFD00000 }, // 64
    .{ .len = 6, .code = 0x84000000 }, // 65
    .{ .len = 7, .code = 0xBA000000 }, // 66
    .{ .len = 7, .code = 0xBC000000 }, // 67
    .{ .len = 7, .code = 0xBE000000 }, // 68
    .{ .len = 7, .code = 0xC0000000 }, // 69
    .{ .len = 7, .code = 0xC2000000 }, // 70
    .{ .len = 7, .code = 0xC4000000 }, // 71
    .{ .len = 7, .code = 0xC6000000 }, // 72
    .{ .len = 7, .code = 0xC8000000 }, // 73
    .{ .len = 7, .code = 0xCA000000 }, // 74
    .{ .len = 7, .code = 0xCC000000 }, // 75
    .{ .len = 7, .code = 0xCE000000 }, // 76
    .{ .len = 7, .code = 0xD0000000 }, // 77
    .{ .len = 7, .code = 0xD2000000 }, // 78
    .{ .len = 7, .code = 0xD4000000 }, // 79
    .{ .len = 7, .code = 0xD6000000 }, // 80
    .{ .len = 7, .code = 0xD8000000 }, // 81
    .{ .len = 7, .code = 0xDA000000 }, // 82
    .{ .len = 7, .code = 0xDC000000 }, // 83
    .{ .len = 7, .code = 0xDE000000 }, // 84
    .{ .len = 7, .code = 0xE0000000 }, // 85
    .{ .len = 7, .code = 0xE2000000 }, // 86
    .{ .len = 7, .code = 0xE4000000 }, // 87
    .{ .len = 8, .code = 0xFC000000 }, // 88
    .{ .len = 7, .code = 0xE6000000 }, // 89
    .{ .len = 8, .code = 0xFD000000 }, // 90
    .{ .len = 13, .code = 0xFFD80000 }, // 91
    .{ .len = 19, .code = 0xFFFE0000 }, // 92
    .{ .len = 13, .code = 0xFFE00000 }, // 93
    .{ .len = 14, .code = 0xFFF00000 }, // 94
    .{ .len = 6, .code = 0x88000000 }, // 95
    .{ .len = 15, .code = 0xFFFA0000 }, // 96
    .{ .len = 5, .code = 0x18000000 }, // 97
    .{ .len = 6, .code = 0x8C000000 }, // 98
    .{ .len = 5, .code = 0x20000000 }, // 99
    .{ .len = 6, .code = 0x90000000 }, // 100
    .{ .len = 5, .code = 0x28000000 }, // 101
    .{ .len = 6, .code = 0x94000000 }, // 102
    .{ .len = 6, .code = 0x98000000 }, // 103
    .{ .len = 6, .code = 0x9C000000 }, // 104
    .{ .len = 5, .code = 0x30000000 }, // 105
    .{ .len = 7, .code = 0xE8000000 }, // 106
    .{ .len = 7, .code = 0xEA000000 }, // 107
    .{ .len = 6, .code = 0xA0000000 }, // 108
    .{ .len = 6, .code = 0xA4000000 }, // 109
    .{ .len = 6, .code = 0xA8000000 }, // 110
    .{ .len = 5, .code = 0x38000000 }, // 111
    .{ .len = 6, .code = 0xAC000000 }, // 112
    .{ .len = 7, .code = 0xEC000000 }, // 113
    .{ .len = 6, .code = 0xB0000000 }, // 114
    .{ .len = 5, .code = 0x40000000 }, // 115
    .{ .len = 5, .code = 0x48000000 }, // 116
    .{ .len = 6, .code = 0xB4000000 }, // 117
    .{ .len = 7, .code = 0xEE000000 }, // 118
    .{ .len = 7, .code = 0xF0000000 }, // 119
    .{ .len = 7, .code = 0xF2000000 }, // 120
    .{ .len = 7, .code = 0xF4000000 }, // 121
    .{ .len = 7, .code = 0xF6000000 }, // 122
    .{ .len = 15, .code = 0xFFFC0000 }, // 123
    .{ .len = 11, .code = 0xFF800000 }, // 124
    .{ .len = 14, .code = 0xFFF40000 }, // 125
    .{ .len = 13, .code = 0xFFE80000 }, // 126
    .{ .len = 28, .code = 0xFFFFFFC0 }, // 127
    .{ .len = 20, .code = 0xFFFE6000 }, // 128
    .{ .len = 22, .code = 0xFFFF4800 }, // 129
    .{ .len = 20, .code = 0xFFFE7000 }, // 130
    .{ .len = 20, .code = 0xFFFE8000 }, // 131
    .{ .len = 22, .code = 0xFFFF4C00 }, // 132
    .{ .len = 22, .code = 0xFFFF5000 }, // 133
    .{ .len = 22, .code = 0xFFFF5400 }, // 134
    .{ .len = 23, .code = 0xFFFFB200 }, // 135
    .{ .len = 22, .code = 0xFFFF5800 }, // 136
    .{ .len = 23, .code = 0xFFFFB400 }, // 137
    .{ .len = 23, .code = 0xFFFFB600 }, // 138
    .{ .len = 23, .code = 0xFFFFB800 }, // 139
    .{ .len = 23, .code = 0xFFFFBA00 }, // 140
    .{ .len = 23, .code = 0xFFFFBC00 }, // 141
    .{ .len = 24, .code = 0xFFFFEB00 }, // 142
    .{ .len = 23, .code = 0xFFFFBE00 }, // 143
    .{ .len = 24, .code = 0xFFFFEC00 }, // 144
    .{ .len = 24, .code = 0xFFFFED00 }, // 145
    .{ .len = 22, .code = 0xFFFF5C00 }, // 146
    .{ .len = 23, .code = 0xFFFFC000 }, // 147
    .{ .len = 24, .code = 0xFFFFEE00 }, // 148
    .{ .len = 23, .code = 0xFFFFC200 }, // 149
    .{ .len = 23, .code = 0xFFFFC400 }, // 150
    .{ .len = 23, .code = 0xFFFFC600 }, // 151
    .{ .len = 23, .code = 0xFFFFC800 }, // 152
    .{ .len = 21, .code = 0xFFFEE000 }, // 153
    .{ .len = 22, .code = 0xFFFF6000 }, // 154
    .{ .len = 23, .code = 0xFFFFCA00 }, // 155
    .{ .len = 22, .code = 0xFFFF6400 }, // 156
    .{ .len = 23, .code = 0xFFFFCC00 }, // 157
    .{ .len = 23, .code = 0xFFFFCE00 }, // 158
    .{ .len = 24, .code = 0xFFFFEF00 }, // 159
    .{ .len = 22, .code = 0xFFFF6800 }, // 160
    .{ .len = 21, .code = 0xFFFEE800 }, // 161
    .{ .len = 20, .code = 0xFFFE9000 }, // 162
    .{ .len = 22, .code = 0xFFFF6C00 }, // 163
    .{ .len = 22, .code = 0xFFFF7000 }, // 164
    .{ .len = 23, .code = 0xFFFFD000 }, // 165
    .{ .len = 23, .code = 0xFFFFD200 }, // 166
    .{ .len = 21, .code = 0xFFFEF000 }, // 167
    .{ .len = 23, .code = 0xFFFFD400 }, // 168
    .{ .len = 22, .code = 0xFFFF7400 }, // 169
    .{ .len = 22, .code = 0xFFFF7800 }, // 170
    .{ .len = 24, .code = 0xFFFFF000 }, // 171
    .{ .len = 21, .code = 0xFFFEF800 }, // 172
    .{ .len = 22, .code = 0xFFFF7C00 }, // 173
    .{ .len = 23, .code = 0xFFFFD600 }, // 174
    .{ .len = 23, .code = 0xFFFFD800 }, // 175
    .{ .len = 21, .code = 0xFFFF0000 }, // 176
    .{ .len = 21, .code = 0xFFFF0800 }, // 177
    .{ .len = 22, .code = 0xFFFF8000 }, // 178
    .{ .len = 21, .code = 0xFFFF1000 }, // 179
    .{ .len = 23, .code = 0xFFFFDA00 }, // 180
    .{ .len = 22, .code = 0xFFFF8400 }, // 181
    .{ .len = 23, .code = 0xFFFFDC00 }, // 182
    .{ .len = 23, .code = 0xFFFFDE00 }, // 183
    .{ .len = 20, .code = 0xFFFEA000 }, // 184
    .{ .len = 22, .code = 0xFFFF8800 }, // 185
    .{ .len = 22, .code = 0xFFFF8C00 }, // 186
    .{ .len = 22, .code = 0xFFFF9000 }, // 187
    .{ .len = 23, .code = 0xFFFFE000 }, // 188
    .{ .len = 22, .code = 0xFFFF9400 }, // 189
    .{ .len = 22, .code = 0xFFFF9800 }, // 190
    .{ .len = 23, .code = 0xFFFFE200 }, // 191
    .{ .len = 26, .code = 0xFFFFF800 }, // 192
    .{ .len = 26, .code = 0xFFFFF840 }, // 193
    .{ .len = 20, .code = 0xFFFEB000 }, // 194
    .{ .len = 19, .code = 0xFFFE2000 }, // 195
    .{ .len = 22, .code = 0xFFFF9C00 }, // 196
    .{ .len = 23, .code = 0xFFFFE400 }, // 197
    .{ .len = 22, .code = 0xFFFFA000 }, // 198
    .{ .len = 25, .code = 0xFFFFF600 }, // 199
    .{ .len = 26, .code = 0xFFFFF880 }, // 200
    .{ .len = 26, .code = 0xFFFFF8C0 }, // 201
    .{ .len = 26, .code = 0xFFFFF900 }, // 202
    .{ .len = 27, .code = 0xFFFFFBC0 }, // 203
    .{ .len = 27, .code = 0xFFFFFBE0 }, // 204
    .{ .len = 26, .code = 0xFFFFF940 }, // 205
    .{ .len = 24, .code = 0xFFFFF100 }, // 206
    .{ .len = 25, .code = 0xFFFFF680 }, // 207
    .{ .len = 19, .code = 0xFFFE4000 }, // 208
    .{ .len = 21, .code = 0xFFFF1800 }, // 209
    .{ .len = 26, .code = 0xFFFFF980 }, // 210
    .{ .len = 27, .code = 0xFFFFFC00 }, // 211
    .{ .len = 27, .code = 0xFFFFFC20 }, // 212
    .{ .len = 26, .code = 0xFFFFF9C0 }, // 213
    .{ .len = 27, .code = 0xFFFFFC40 }, // 214
    .{ .len = 24, .code = 0xFFFFF200 }, // 215
    .{ .len = 21, .code = 0xFFFF2000 }, // 216
    .{ .len = 21, .code = 0xFFFF2800 }, // 217
    .{ .len = 26, .code = 0xFFFFFA00 }, // 218
    .{ .len = 26, .code = 0xFFFFFA40 }, // 219
    .{ .len = 28, .code = 0xFFFFFFD0 }, // 220
    .{ .len = 27, .code = 0xFFFFFC60 }, // 221
    .{ .len = 27, .code = 0xFFFFFC80 }, // 222
    .{ .len = 27, .code = 0xFFFFFCA0 }, // 223
    .{ .len = 20, .code = 0xFFFEC000 }, // 224
    .{ .len = 24, .code = 0xFFFFF300 }, // 225
    .{ .len = 20, .code = 0xFFFED000 }, // 226
    .{ .len = 21, .code = 0xFFFF3000 }, // 227
    .{ .len = 22, .code = 0xFFFFA400 }, // 228
    .{ .len = 21, .code = 0xFFFF3800 }, // 229
    .{ .len = 21, .code = 0xFFFF4000 }, // 230
    .{ .len = 23, .code = 0xFFFFE600 }, // 231
    .{ .len = 22, .code = 0xFFFFA800 }, // 232
    .{ .len = 22, .code = 0xFFFFAC00 }, // 233
    .{ .len = 25, .code = 0xFFFFF700 }, // 234
    .{ .len = 25, .code = 0xFFFFF780 }, // 235
    .{ .len = 24, .code = 0xFFFFF400 }, // 236
    .{ .len = 24, .code = 0xFFFFF500 }, // 237
    .{ .len = 26, .code = 0xFFFFFA80 }, // 238
    .{ .len = 23, .code = 0xFFFFE800 }, // 239
    .{ .len = 26, .code = 0xFFFFFAC0 }, // 240
    .{ .len = 27, .code = 0xFFFFFCC0 }, // 241
    .{ .len = 26, .code = 0xFFFFFB00 }, // 242
    .{ .len = 26, .code = 0xFFFFFB40 }, // 243
    .{ .len = 27, .code = 0xFFFFFCE0 }, // 244
    .{ .len = 27, .code = 0xFFFFFD00 }, // 245
    .{ .len = 27, .code = 0xFFFFFD20 }, // 246
    .{ .len = 27, .code = 0xFFFFFD40 }, // 247
    .{ .len = 27, .code = 0xFFFFFD60 }, // 248
    .{ .len = 28, .code = 0xFFFFFFE0 }, // 249
    .{ .len = 27, .code = 0xFFFFFD80 }, // 250
    .{ .len = 27, .code = 0xFFFFFDA0 }, // 251
    .{ .len = 27, .code = 0xFFFFFDC0 }, // 252
    .{ .len = 27, .code = 0xFFFFFDE0 }, // 253
    .{ .len = 27, .code = 0xFFFFFE00 }, // 254
    .{ .len = 26, .code = 0xFFFFFB80 }, // 255
    .{ .len = 30, .code = 0xFFFFFFFC }, // EOS
};

const huffman_eos_sym: u16 = 256;
const huffman_no_sym: u16 = 0xFFFF;

const HuffmanNode = struct {
    b0: u16 = 0,
    b1: u16 = 0,
    sym: u16 = huffman_no_sym,
};

const huffman_tree = buildHuffmanTree(&huffman_table);
const huffman_padding_ok = buildHuffmanPaddingStates(huffman_tree.nodes);

fn huffBit(code: u32, bit_index: u8) u1 {
    return @truncate((code >> @intCast(31 - bit_index)) & 1);
}

fn buildHuffmanTree(comptime table: *const [257]HuffmanSym) struct { nodes: [1024]HuffmanNode, count: usize } {
    @setEvalBranchQuota(10000);
    var nodes: [1024]HuffmanNode = @splat(.{});
    var count: usize = 1;
    inline for (table, 0..) |entry, sym| {
        var idx: u16 = 0;
        var bit_i: u8 = 0;
        while (bit_i < entry.len) : (bit_i += 1) {
            const b = huffBit(entry.code, bit_i);
            const is_last = bit_i == entry.len - 1;
            if (is_last) {
                if (b == 0) {
                    if (nodes[idx].b0 == 0) {
                        nodes[idx].b0 = @intCast(count);
                        count += 1;
                    }
                    nodes[nodes[idx].b0].sym = @intCast(sym);
                } else {
                    if (nodes[idx].b1 == 0) {
                        nodes[idx].b1 = @intCast(count);
                        count += 1;
                    }
                    nodes[nodes[idx].b1].sym = @intCast(sym);
                }
            } else if (b == 0) {
                if (nodes[idx].b0 == 0) {
                    nodes[idx].b0 = @intCast(count);
                    count += 1;
                }
                idx = nodes[idx].b0;
            } else {
                if (nodes[idx].b1 == 0) {
                    nodes[idx].b1 = @intCast(count);
                    count += 1;
                }
                idx = nodes[idx].b1;
            }
        }
    }
    return .{ .nodes = nodes, .count = count };
}

fn buildHuffmanPaddingStates(comptime nodes: [1024]HuffmanNode) [1024]bool {
    var ok: [1024]bool = @splat(false);
    ok[0] = true;
    var cur: u16 = 0;
    var i: u8 = 0;
    while (i < 30) : (i += 1) {
        const next = nodes[cur].b1;
        if (next == 0) break;
        ok[next] = true;
        if (nodes[next].sym == huffman_eos_sym) break;
        cur = next;
    }
    return ok;
}

fn huffmanEncodedLen(s: []const u8) usize {
    var nbits: usize = 0;
    for (s) |c| nbits += huffman_table[c].len;
    return (nbits + 7) / 8;
}

fn huffmanEncode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var accum: u64 = 0;
    var nbits: usize = 0;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (s) |c| {
        const sym = huffman_table[c];
        accum = (accum << @intCast(sym.len)) | (@as(u64, sym.code) >> @intCast(32 - sym.len));
        nbits += sym.len;
        while (nbits >= 8) {
            const shift = nbits - 8;
            try out.append(allocator, @truncate(accum >> @intCast(shift)));
            accum &= (@as(u64, 1) << @intCast(shift)) - 1;
            nbits -= 8;
        }
    }
    if (nbits > 0) {
        const pad = 8 - nbits;
        accum = (accum << @intCast(pad)) | ((@as(u64, 1) << @intCast(pad)) - 1);
        try out.append(allocator, @truncate(accum));
    }
    return out.toOwnedSlice(allocator);
}

fn huffmanDecode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var idx: u16 = 0;
    // Bits seen since the last complete symbol. Whatever trails the final
    // symbol is padding, and RFC 7541 §5.2 caps padding at 7 bits — a whole
    // 0xFF byte must not be accepted (the EOS walk makes it look "valid").
    var padding_bits: u8 = 0;
    for (data) |byte| {
        var bit_pos: u4 = 0;
        while (bit_pos < 8) : (bit_pos += 1) {
            const bit: u1 = @truncate((byte >> @intCast(7 - bit_pos)) & 1);
            idx = if (bit == 0) huffman_tree.nodes[idx].b0 else huffman_tree.nodes[idx].b1;
            if (idx == 0) return error.InvalidHpack;
            const sym = huffman_tree.nodes[idx].sym;
            if (sym != huffman_no_sym) {
                if (sym == huffman_eos_sym) return error.InvalidHpack;
                try out.append(allocator, @intCast(sym));
                idx = 0;
                padding_bits = 0;
            } else {
                padding_bits += 1;
            }
        }
    }
    if (idx != 0 and (padding_bits > 7 or !huffman_padding_ok[idx])) return error.InvalidHpack;
    return out.toOwnedSlice(allocator);
}

/// RFC 7541 §6.5.2 default SETTINGS_HEADER_TABLE_SIZE.
pub const default_table_size: usize = 4096;

/// Header-list budget for one decoded block (RFC 9113 §6.5.2), charged as the
/// fields are decoded.
///
/// The compressed block is not the interesting bound: an indexed reference
/// costs 1–2 bytes on the wire and can name a 4 KiB dynamic-table entry, so a
/// 64 KiB block inflates into a header list orders of magnitude larger. What a
/// peer can make us allocate is the *decoded* list, so that is what is metered.
const HeaderListBudget = struct {
    /// Advertised SETTINGS_MAX_HEADER_LIST_SIZE. 0 = no byte budget.
    max_bytes: usize = 0,
    /// Field-count cap (there is no SETTINGS entry for it). 0 = no cap.
    max_fields: usize = 0,
    bytes: usize = 0,
    fields: usize = 0,
    /// The limit error, once the budget is spent; `null` while within it.
    hit: ?anyerror = null,

    /// Charge one decoded field (name + value + the 32-byte per-field overhead
    /// RFC 9113 §6.5.2 counts). Returns `false` once the budget is spent — the
    /// caller must then drop the field **and keep decoding**: see
    /// `Decoder.decode`.
    fn charge(self: *HeaderListBudget, name: []const u8, value: []const u8) bool {
        if (self.hit == null) {
            self.fields += 1;
            self.bytes += name.len + value.len + 32;
            if (self.max_bytes != 0 and self.bytes > self.max_bytes) {
                self.hit = error.HeaderListTooLarge;
            } else if (self.max_fields != 0 and self.fields > self.max_fields) {
                self.hit = error.TooManyHeaderFields;
            }
        }
        return self.hit == null;
    }
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    dynamic: std.ArrayList(OwnedHeader) = .empty,
    /// Hard upper bound for `max_table_size`: the SETTINGS_HEADER_TABLE_SIZE we
    /// advertised to the peer. A dynamic table size update above it is a
    /// decoding error (RFC 7541 §6.3).
    settings_max_table_size: usize = default_table_size,
    /// Current table limit — the last size update received, or the advertised
    /// value. Drives eviction (RFC 7541 §4.4).
    max_table_size: usize = default_table_size,
    current_size: usize = 0,
    /// Advertised SETTINGS_MAX_HEADER_LIST_SIZE in bytes (RFC 9113 §6.5.2).
    /// 0 = no budget: a direct `Decoder` user keeps the unbounded behaviour
    /// unless it opts in through `setAdvertisedHeaderListSize`.
    max_header_list_size: usize = 0,
    /// Field-count budget. Not a SETTINGS value — HTTP/2 has none for it; it
    /// mirrors the H1 `HeaderLimits.max_count` guard. 0 = no budget.
    max_header_count: usize = 0,

    const OwnedHeader = struct {
        name: []u8,
        value: []u8,
    };

    /// One decoded field plus the ownership flags `freeHeaders` needs — the
    /// unit the header-list budget is charged for.
    const Decoded = struct {
        name: []const u8,
        value: []const u8,
        name_owner: Owner = .borrowed,
        value_owner: Owner = .borrowed,
    };

    pub fn init(allocator: std.mem.Allocator) Decoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Decoder) void {
        self.clearDynamic();
        self.dynamic.deinit(self.allocator);
        self.* = undefined;
    }

    /// Advertise a new SETTINGS_HEADER_TABLE_SIZE: the hard upper bound for
    /// dynamic table size updates, and the current limit until the peer sends
    /// one of its own. Shrinking trims the table immediately (RFC 7541 §4.2).
    pub fn setAdvertisedTableSize(self: *Decoder, size: usize) void {
        self.settings_max_table_size = size;
        self.max_table_size = size;
        self.evictFor(0);
    }

    /// Advertise SETTINGS_MAX_HEADER_LIST_SIZE: a decoded list larger than
    /// `bytes` (RFC 9113 §6.5.2 counts name + value + 32 per field), or with
    /// more than `max_fields` fields, fails `decode` with
    /// `error.HeaderListTooLarge` / `error.TooManyHeaderFields`. `0` disables
    /// either budget. Both errors are stream errors (`isConnectionError` is
    /// false): the block decoded, only the list is past what we advertised.
    pub fn setAdvertisedHeaderListSize(self: *Decoder, bytes: usize, max_fields: usize) void {
        self.max_header_list_size = bytes;
        self.max_header_count = max_fields;
    }

    fn clearDynamic(self: *Decoder) void {
        for (self.dynamic.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.dynamic.clearRetainingCapacity();
        self.current_size = 0;
    }

    /// Release a decoded field whose ownership never reached the header list.
    fn release(self: *Decoder, d: Decoded) void {
        if (ownsSlice(d.name_owner, d.name)) self.allocator.free(@constCast(d.name));
        if (ownsSlice(d.value_owner, d.value)) self.allocator.free(@constCast(d.value));
    }

    /// Decode a header block. Slice ownership is flagged per header
    /// (`Header.name_owner` / `value_owner`); release the result with
    /// `freeHeaders`.
    ///
    /// A decoding failure is a connection error (RFC 7541 §4.2): the caller
    /// must send GOAWAY(COMPRESSION_ERROR) instead of RST_STREAM — see
    /// `isConnectionError`. The table state is undefined after a failure, so
    /// drop the decoder rather than reusing it.
    ///
    /// A header-list budget breach (`setAdvertisedHeaderListSize`) is **not**
    /// one of those: the block decoded fine, only the list is bigger than we
    /// advertised, so the caller answers RST_STREAM and keeps the decoder.
    /// That is why the loop runs to the end of the block even after the budget
    /// is spent — the dynamic table is shared by every stream on the
    /// connection (RFC 7541 §2.2), so abandoning a block mid-way would leave
    /// our table out of step with the peer's encoder and make the next stream
    /// fail too.
    pub fn decode(self: *Decoder, block: []const u8) ![]Header {
        var out = std.ArrayList(Header).empty;
        errdefer {
            // Release the fields already decoded, then the list's own buffer.
            // `freeHeaders` cannot be used here: it frees the slice it is
            // handed, and that slice is `out.items` (length ≤ capacity, so not
            // the allocation the allocator knows) while `deinit` frees the
            // capacity — one free too many.
            for (out.items) |h| self.release(.{
                .name = h.name,
                .value = h.value,
                .name_owner = h.name_owner,
                .value_owner = h.value_owner,
            });
            out.deinit(self.allocator);
        }
        var budget = HeaderListBudget{
            .max_bytes = self.max_header_list_size,
            .max_fields = self.max_header_count,
        };
        var i: usize = 0;
        while (i < block.len) {
            const b = block[i];
            if (b & 0x80 != 0) {
                // 1xxxxxxx — indexed header field (RFC 7541 §6.1).
                const idx, const n = try decodeInt(block[i..], 7);
                i += n;
                const h = try self.lookup(idx);
                const is_static = idx < static_table.len;
                // A dynamic entry's two halves are separate copies, and the
                // second one is a second place to fail: the name is armed for
                // release *before* the value is attempted, because the
                // `errdefer self.release(d)` below only arms once `d` exists —
                // a value-side failure used to strand the name copy (found by
                // the OOM scan at the bottom of this file).
                const d: Decoded = blk: {
                    if (is_static) break :blk Decoded{ .name = h.name, .value = h.value };
                    const owned_name = try self.allocator.dupe(u8, h.name);
                    errdefer self.allocator.free(owned_name);
                    const owned_value = try self.allocator.dupe(u8, h.value);
                    break :blk Decoded{
                        .name = owned_name,
                        .value = owned_value,
                        .name_owner = .owned,
                        .value_owner = .owned,
                    };
                };
                errdefer self.release(d);
                if (!budget.charge(d.name, d.value)) {
                    self.release(d);
                    continue;
                }
                try out.append(self.allocator, .{
                    .name = d.name,
                    .value = d.value,
                    .name_owner = d.name_owner,
                    .value_owner = d.value_owner,
                });
                continue;
            }
            if (b & 0x40 != 0) {
                // 01xxxxxx — literal with incremental indexing (§6.2.1).
                const name_idx, const n0 = try decodeInt(block[i..], 6);
                i += n0;
                const name_is_static = name_idx > 0 and name_idx < static_table.len;
                // A Huffman name is an allocation of `decodeString`'s, and it
                // has to stay alive until the last read of `name` below
                // (`dupEntry`) — so its cleanup belongs to this field's scope,
                // the same way the value's does. A `defer` inside the block
                // expression runs at `break :blk`, i.e. before the owned copy
                // is taken, and hands a freed buffer to the copy.
                var name_owned: ?[]u8 = null;
                defer if (name_owned) |buf| self.allocator.free(buf);
                const name = if (name_idx == 0) blk: {
                    const ds = try decodeString(self.allocator, block[i..]);
                    i += ds.consumed;
                    if (ds.owned) name_owned = @constCast(ds.value);
                    break :blk ds.value;
                } else (try self.lookup(name_idx)).name;
                // When the name came from a dynamic index, `name` points into
                // that entry: inserting below evicts from the oldest end
                // (§4.4) and can free the very entry being read. Take the copy
                // out of the table first.
                const out_name: []const u8 = if (name_is_static) name else try self.allocator.dupe(u8, name);
                errdefer if (!name_is_static) self.allocator.free(@constCast(out_name));

                const value_ds = try decodeString(self.allocator, block[i..]);
                i += value_ds.consumed;
                defer if (value_ds.owned) self.allocator.free(@constCast(value_ds.value));
                const value = value_ds.value;

                try self.pushDynamic(try self.dupEntry(name, value));

                const out_value = try self.allocator.dupe(u8, value);
                errdefer self.allocator.free(out_value);
                const d = Decoded{
                    .name = out_name,
                    .value = out_value,
                    .name_owner = if (name_is_static) .borrowed else .owned,
                    .value_owner = .owned,
                };
                if (!budget.charge(d.name, d.value)) {
                    self.release(d);
                    continue;
                }
                try out.append(self.allocator, .{
                    .name = d.name,
                    .value = d.value,
                    .name_owner = d.name_owner,
                    .value_owner = d.value_owner,
                });
                continue;
            }
            if (b & 0x20 != 0) {
                // 001xxxxx — dynamic table size update (RFC 7541 §6.3).
                const new_size, const n = try decodeInt(block[i..], 5);
                i += n;
                try self.setMaxTableSize(new_size);
                continue;
            }
            // 0000xxxx / 0001xxxx — literal without indexing (§6.2.2 / §6.2.3).
            const name_idx, const n0 = try decodeInt(block[i..], 4);
            i += n0;
            const name_is_static = name_idx > 0 and name_idx < static_table.len;
            // Same rule as the incremental-indexing branch above: the Huffman
            // name buffer is owned by this field, freed when the field ends.
            var name_owned: ?[]u8 = null;
            defer if (name_owned) |buf| self.allocator.free(buf);
            const name = if (name_idx == 0) blk: {
                const ds = try decodeString(self.allocator, block[i..]);
                i += ds.consumed;
                if (ds.owned) name_owned = @constCast(ds.value);
                break :blk ds.value;
            } else (try self.lookup(name_idx)).name;
            const value_ds = try decodeString(self.allocator, block[i..]);
            i += value_ds.consumed;
            defer if (value_ds.owned) self.allocator.free(@constCast(value_ds.value));
            const value = value_ds.value;
            // This branch inserts nothing, so a table-supplied `name` is stable
            // until the caller-owned copy below is taken.
            const out_name: []const u8 = if (name_is_static) name else try self.allocator.dupe(u8, name);
            errdefer if (!name_is_static) self.allocator.free(@constCast(out_name));
            const out_value = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(out_value);
            const d = Decoded{
                .name = out_name,
                .value = out_value,
                .name_owner = if (name_is_static) .borrowed else .owned,
                .value_owner = .owned,
            };
            if (!budget.charge(d.name, d.value)) {
                self.release(d);
                continue;
            }
            try out.append(self.allocator, .{
                .name = d.name,
                .value = d.value,
                .name_owner = d.name_owner,
                .value_owner = d.value_owner,
            });
        }
        if (budget.hit) |limit_err| return limit_err;
        return try out.toOwnedSlice(self.allocator);
    }

    /// Resolve an index against static + dynamic table. The returned slices are
    /// borrows into the table (static memory or a live entry) — never handed to
    /// `freeHeaders`, and invalidated by any insertion that evicts the entry.
    fn lookup(self: *Decoder, index: usize) !Header {
        if (index == 0) return error.InvalidHpackIndex;
        if (index < static_table.len) return static_table[index];
        const dyn_i = index - static_table.len;
        if (dyn_i >= self.dynamic.items.len) return error.InvalidHpackIndex;
        const rev = self.dynamic.items.len - 1 - dyn_i;
        const h = self.dynamic.items[rev];
        return .{ .name = h.name, .value = h.value, .name_owner = .borrowed, .value_owner = .borrowed };
    }

    /// Duplicate both halves of an entry in one step, so a half-built pair can
    /// never be lost: the caller hands the result to `pushDynamic`.
    fn dupEntry(self: *Decoder, name: []const u8, value: []const u8) !OwnedHeader {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        return .{ .name = owned_name, .value = owned_value };
    }

    /// Apply a dynamic table size update (RFC 7541 §6.3): the new size may not
    /// exceed what we advertised, and shrinking evicts from the oldest end.
    fn setMaxTableSize(self: *Decoder, size: usize) !void {
        if (size > self.settings_max_table_size) return error.InvalidHpackTableSize;
        self.max_table_size = size;
        self.evictFor(0);
    }

    /// Evict oldest entries until `incoming` more bytes fit (RFC 7541 §4.4).
    fn evictFor(self: *Decoder, incoming: usize) void {
        while (self.dynamic.items.len > 0 and self.current_size + incoming > self.max_table_size) {
            const old = self.dynamic.orderedRemove(0);
            self.current_size -= old.name.len + old.value.len + 32;
            self.allocator.free(old.name);
            self.allocator.free(old.value);
        }
    }

    /// Append an entry to the dynamic table, taking ownership of both slices.
    fn pushDynamic(self: *Decoder, entry: OwnedHeader) !void {
        errdefer self.allocator.free(entry.name);
        errdefer self.allocator.free(entry.value);
        const entry_size = entry.name.len + entry.value.len + 32;
        self.evictFor(entry_size);
        if (entry_size > self.max_table_size) {
            // Larger than the whole table: inserted never, table left empty.
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
            return;
        }
        try self.dynamic.append(self.allocator, entry);
        self.current_size += entry_size;
    }
};

/// RFC 7541 §4.2 — every decoding failure is a *connection* error: the peer
/// must be closed with GOAWAY(COMPRESSION_ERROR). A stream-level RST_STREAM
/// leaves the connection alive while the two sides disagree about every later
/// header block. `error.OutOfMemory` is ours, not a compression error.
pub fn isConnectionError(err: anyerror) bool {
    return switch (err) {
        error.InvalidHpack, error.InvalidHpackIndex, error.InvalidHpackTableSize => true,
        else => false,
    };
}

/// Static-table membership test, kept as the fallback used by `freeHeaders`
/// for headers whose producer left `name_owner` / `value_owner` unspecified.
fn isStaticSlice(slice: []const u8) bool {
    for (static_table) |st| {
        if (slice.ptr == st.name.ptr and slice.len == st.name.len) return true;
        if (slice.ptr == st.value.ptr and slice.len == st.value.len) return true;
    }
    return false;
}

fn ownsSlice(owner: Owner, slice: []const u8) bool {
    return switch (owner) {
        .owned => true,
        .borrowed => false,
        .unspecified => !isStaticSlice(slice),
    };
}

pub fn freeHeaders(allocator: std.mem.Allocator, headers: []Header) void {
    for (headers) |h| {
        if (ownsSlice(h.name_owner, h.name)) allocator.free(@constCast(h.name));
        if (ownsSlice(h.value_owner, h.value)) allocator.free(@constCast(h.value));
    }
    allocator.free(headers);
}

pub const Encoder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .allocator = allocator };
    }

    /// Encode as literal-without-indexing new-name (no dynamic table pollution).
    pub fn encodeLiterals(self: Encoder, headers: []const Header) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        for (headers) |h| {
            try out.append(self.allocator, 0x00);
            try appendStringRaw(&out, self.allocator, h.name);
            try appendStringRaw(&out, self.allocator, h.value);
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// Prefer static index when possible; use Huffman for literals when smaller.
    pub fn encodeSmart(self: Encoder, headers: []const Header) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        for (headers) |h| {
            if (try encodeStaticIndexed(&out, self.allocator, h)) continue;
            try out.append(self.allocator, 0x00);
            try appendStringSmart(&out, self.allocator, h.name);
            try appendStringSmart(&out, self.allocator, h.value);
        }
        return out.toOwnedSlice(self.allocator);
    }
};

fn encodeStaticIndexed(out: *std.ArrayList(u8), allocator: std.mem.Allocator, h: Header) !bool {
    var i: usize = 1;
    while (i < static_table.len) : (i += 1) {
        const e = static_table[i];
        if (std.mem.eql(u8, e.name, h.name) and std.mem.eql(u8, e.value, h.value) and e.value.len > 0) {
            if (i < 127) {
                try out.append(allocator, @intCast(0x80 | i));
            } else {
                try out.append(allocator, 0xff);
                try encodeIntRest(out, allocator, i - 127);
            }
            return true;
        }
    }
    return false;
}

fn decodeInt(buf: []const u8, prefix_bits: u3) !struct { usize, usize } {
    if (buf.len == 0) return error.InvalidHpack;
    const mask: u8 = (@as(u8, 1) << prefix_bits) - 1;
    var value: usize = buf[0] & mask;
    if (value < mask) return .{ value, 1 };
    var i: usize = 1;
    var m: u6 = 0;
    while (i < buf.len) : (i += 1) {
        const b = buf[i];
        value += @as(usize, b & 0x7f) << m;
        if ((b & 0x80) == 0) return .{ value, i + 1 };
        m += 7;
        if (m > 28) return error.InvalidHpack;
    }
    return error.InvalidHpack;
}

fn encodeIntRest(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    var v = value;
    while (v >= 128) {
        try out.append(allocator, @truncate((v & 0x7f) | 0x80));
        v >>= 7;
    }
    try out.append(allocator, @truncate(v));
}

fn rawStringEncodedLen(s: []const u8) usize {
    if (s.len < 127) return 1 + s.len;
    var extra: usize = 1;
    var v = s.len - 127;
    while (v >= 128) : (extra += 1) v >>= 7;
    return extra + 1 + s.len;
}

const DecodedString = struct { value: []const u8, consumed: usize, owned: bool };

fn decodeString(allocator: std.mem.Allocator, buf: []const u8) !DecodedString {
    if (buf.len == 0) return error.InvalidHpack;
    const huffman = buf[0] & 0x80 != 0;
    const len, const n = try decodeInt(buf, 7);
    if (n + len > buf.len) return error.InvalidHpack;
    const data = buf[n .. n + len];
    if (!huffman) return .{ .value = data, .consumed = n + len, .owned = false };
    const decoded = try huffmanDecode(allocator, data);
    return .{ .value = decoded, .consumed = n + len, .owned = true };
}

fn appendStringRaw(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    if (s.len < 127) {
        try out.append(allocator, @intCast(s.len));
    } else {
        try out.append(allocator, 127);
        try encodeIntRest(out, allocator, s.len - 127);
    }
    try out.appendSlice(allocator, s);
}

fn appendStringHuffman(out: *std.ArrayList(u8), allocator: std.mem.Allocator, encoded: []const u8) !void {
    const len = encoded.len;
    if (len < 127) {
        try out.append(allocator, @intCast(0x80 | len));
    } else {
        try out.append(allocator, 0xff);
        try encodeIntRest(out, allocator, len - 127);
    }
    try out.appendSlice(allocator, encoded);
}

fn appendStringSmart(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    const huff_len = huffmanEncodedLen(s);
    if (huff_len < rawStringEncodedLen(s)) {
        const encoded = try huffmanEncode(allocator, s);
        defer allocator.free(encoded);
        try appendStringHuffman(out, allocator, encoded);
    } else {
        try appendStringRaw(out, allocator, s);
    }
}

test "Hpack decode indexed POST" {
    const allocator = std.testing.allocator;
    var dec = Decoder.init(allocator);
    defer dec.deinit();
    const block = [_]u8{0x83};
    const headers = try dec.decode(&block);
    defer freeHeaders(allocator, headers);
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings(":method", headers[0].name);
    try std.testing.expectEqualStrings("POST", headers[0].value);
}

test "Hpack encodeLiterals decode roundtrip" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    const block = try enc.encodeLiterals(&.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/api/v1" },
        .{ .name = "content-type", .value = "application/grpc" },
    });
    defer allocator.free(block);

    var dec = Decoder.init(allocator);
    defer dec.deinit();
    const headers = try dec.decode(block);
    defer freeHeaders(allocator, headers);
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings("/api/v1", headers[1].value);
    try std.testing.expectEqualStrings("application/grpc", headers[2].value);
}

test "Hpack encodeSmart uses static index for POST" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    const block = try enc.encodeSmart(&.{.{ .name = ":method", .value = "POST" }});
    defer allocator.free(block);
    try std.testing.expectEqual(@as(u8, 0x83), block[0]);
}

test "Hpack huffman decode :method literal" {
    const allocator = std.testing.allocator;
    const encoded = try huffmanDecode(allocator, &[_]u8{ 0xb9, 0x49, 0x53, 0x39, 0xe4 });
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings(":method", encoded);
}

test "Hpack huffman decode RFC www.example.com" {
    const allocator = std.testing.allocator;
    const encoded = try huffmanDecode(allocator, &[_]u8{ 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff });
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("www.example.com", encoded);
}

test "Hpack huffman encode decode roundtrip" {
    const allocator = std.testing.allocator;
    const samples = [_][]const u8{ ":method", "GET", "www.example.com", "no-cache", "application/grpc" };
    for (samples) |s| {
        const enc = try huffmanEncode(allocator, s);
        defer allocator.free(enc);
        const dec = try huffmanDecode(allocator, enc);
        defer allocator.free(dec);
        try std.testing.expectEqualStrings(s, dec);
    }
}

test "Hpack decodeString Huffman end-to-end via Decoder.decode" {
    const allocator = std.testing.allocator;
    const value_huff = [_]u8{ 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff };
    const block = blk: {
        var parts = std.ArrayList(u8).empty;
        defer parts.deinit(allocator);
        try parts.append(allocator, 0x41);
        try parts.appendSlice(allocator, &value_huff);
        break :blk try parts.toOwnedSlice(allocator);
    };
    defer allocator.free(block);

    var dec = Decoder.init(allocator);
    defer dec.deinit();
    const headers = try dec.decode(block);
    defer freeHeaders(allocator, headers);
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings(":authority", headers[0].name);
    try std.testing.expectEqualStrings("www.example.com", headers[0].value);
}

// ---------------------------------------------------------------------------
// Dynamic table (RFC 7541 §2.3.2, §4.4) + header block boundary tests.
// ---------------------------------------------------------------------------

/// `01` + 6-bit index 0 → literal with incremental indexing, new name.
fn appendLitIncNewName(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    try buf.append(allocator, 0x40);
    try appendStringRaw(buf, allocator, name);
    try appendStringRaw(buf, allocator, value);
}

/// `01` + 6-bit index → incremental indexing with a table-supplied name.
fn appendLitIncIndexedName(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, name_idx: usize, value: []const u8) !void {
    if (name_idx < 63) {
        try buf.append(allocator, @intCast(0x40 | name_idx));
    } else {
        try buf.append(allocator, 0x7f);
        try encodeIntRest(buf, allocator, name_idx - 63);
    }
    try appendStringRaw(buf, allocator, value);
}

test "Hpack dynamic table insert accounting and index order" {
    const allocator = std.testing.allocator;
    var block = std.ArrayList(u8).empty;
    defer block.deinit(allocator);

    var dec = Decoder.init(allocator);
    defer dec.deinit();

    try appendLitIncNewName(&block, allocator, "a", "1");
    const first = try dec.decode(block.items);
    defer freeHeaders(allocator, first);
    try std.testing.expectEqual(@as(usize, 1), dec.dynamic.items.len);
    try std.testing.expectEqual(@as(usize, 1 + 1 + 32), dec.current_size);

    block.clearRetainingCapacity();
    try appendLitIncNewName(&block, allocator, "b", "2");
    const second = try dec.decode(block.items);
    defer freeHeaders(allocator, second);
    try std.testing.expectEqual(@as(usize, 2), dec.dynamic.items.len);
    try std.testing.expectEqual(@as(usize, 2 * 34), dec.current_size);

    // Newest first: index 62 is "b", index 63 is "a".
    const refs = [_]u8{ 0xbe, 0xbf };
    const by_index = try dec.decode(&refs);
    defer freeHeaders(allocator, by_index);
    try std.testing.expectEqualStrings("b", by_index[0].name);
    try std.testing.expectEqualStrings("2", by_index[0].value);
    try std.testing.expectEqualStrings("a", by_index[1].name);
    try std.testing.expectEqualStrings("1", by_index[1].value);
}

test "Hpack dynamic table evicts oldest entries when full" {
    const allocator = std.testing.allocator;
    var dec = Decoder.init(allocator);
    defer dec.deinit();
    dec.max_table_size = 70; // room for two 34-byte entries.

    var block = std.ArrayList(u8).empty;
    defer block.deinit(allocator);

    try appendLitIncNewName(&block, allocator, "a", "1");
    try appendLitIncNewName(&block, allocator, "b", "2");
    const two = try dec.decode(block.items);
    defer freeHeaders(allocator, two);
    try std.testing.expectEqual(@as(usize, 2), dec.dynamic.items.len);
    try std.testing.expectEqual(@as(usize, 68), dec.current_size);

    // Third entry pushes the oldest ("a") out; "b" then "c" remain.
    block.clearRetainingCapacity();
    try appendLitIncNewName(&block, allocator, "c", "3");
    const three = try dec.decode(block.items);
    defer freeHeaders(allocator, three);
    try std.testing.expectEqual(@as(usize, 2), dec.dynamic.items.len);
    try std.testing.expectEqual(@as(usize, 68), dec.current_size);

    const refs = [_]u8{ 0xbe, 0xbf };
    const remaining = try dec.decode(&refs);
    defer freeHeaders(allocator, remaining);
    try std.testing.expectEqualStrings("c", remaining[0].name);
    try std.testing.expectEqualStrings("b", remaining[1].name);

    // Index of the evicted entry is gone.
    const stale = [_]u8{0xc0}; // indexed 64 → dynamic index 2, out of range
    try std.testing.expectError(error.InvalidHpackIndex, dec.decode(&stale));
}

test "Hpack dynamic name is copied before the entry can be evicted (UAF regression)" {
    const allocator = std.testing.allocator;
    var block = std.ArrayList(u8).empty;
    defer block.deinit(allocator);

    try appendLitIncNewName(&block, allocator, "s", "S");
    const big = try allocator.alloc(u8, 3900);
    defer allocator.free(big);
    @memset(big, 'B');
    try appendLitIncNewName(&block, allocator, "b", big);
    const c200 = try allocator.alloc(u8, 200);
    defer allocator.free(c200);
    @memset(c200, 'C');
    // Name index 63 == the oldest entry ("s", dynamic index 1): inserting this
    // 233-byte entry evicts — and frees — that very entry, so the emitted name
    // must already be an owned copy (reading the table entry here would read
    // freed memory).
    try appendLitIncIndexedName(&block, allocator, static_table.len + 1, c200);

    var dec = Decoder.init(allocator);
    defer dec.deinit();
    const headers = try dec.decode(block.items);
    defer freeHeaders(allocator, headers);

    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings("b", headers[1].name);
    try std.testing.expectEqualStrings("s", headers[2].name);
    try std.testing.expectEqualStrings("S", headers[0].value);
    try std.testing.expectEqualStrings(c200, headers[2].value);
    try std.testing.expectEqual(@as(usize, 1), dec.dynamic.items.len);
    try std.testing.expectEqual(@as(usize, 233), dec.current_size);
}

test "Hpack decodes dynamic table size update" {
    const allocator = std.testing.allocator;
    var dec = Decoder.init(allocator);
    defer dec.deinit();

    // 001 00000 → update to 0; 0x82 → indexed static 2 (:method GET).
    const block = [_]u8{ 0x20, 0x82 };
    const headers = try dec.decode(&block);
    defer freeHeaders(allocator, headers);
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings(":method", headers[0].name);
    try std.testing.expectEqualStrings("GET", headers[0].value);
    try std.testing.expectEqual(@as(usize, 0), dec.max_table_size);
}

test "Hpack dynamic table size update evicts down to the new limit" {
    const allocator = std.testing.allocator;
    var dec = Decoder.init(allocator);
    defer dec.deinit();

    var block = std.ArrayList(u8).empty;
    defer block.deinit(allocator);
    try appendLitIncNewName(&block, allocator, "a", "1");
    try appendLitIncNewName(&block, allocator, "b", "2");
    const two = try dec.decode(block.items);
    defer freeHeaders(allocator, two);
    try std.testing.expectEqual(@as(usize, 2), dec.dynamic.items.len);

    block.clearRetainingCapacity();
    try block.append(allocator, 0x20); // update to 0
    try block.append(allocator, 0xbe); // indexed 62 → evicted with the table
    try std.testing.expectError(error.InvalidHpackIndex, dec.decode(block.items));
    try std.testing.expectEqual(@as(usize, 0), dec.dynamic.items.len);
    try std.testing.expectEqual(@as(usize, 0), dec.current_size);
    try std.testing.expectEqual(@as(usize, 0), dec.max_table_size);
}

test "Hpack rejects huffman padding longer than 7 bits" {
    const allocator = std.testing.allocator;
    // RFC 7541 C.4.1 encoding of "www.example.com" ends with 1..7 padding bits;
    // appending a whole 0xFF byte makes the padding 8+ bits, which §5.2 says
    // MUST be treated as a decoding error.
    const over_padded = [_]u8{ 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff, 0xff };
    try std.testing.expectError(error.InvalidHpack, huffmanDecode(allocator, &over_padded));
    // The same encoding without the extra byte still decodes.
    const ok = try huffmanDecode(allocator, over_padded[0..12]);
    defer allocator.free(ok);
    try std.testing.expectEqualStrings("www.example.com", ok);
}

test "Hpack size update may move within the advertised limit" {
    const allocator = std.testing.allocator;
    var dec = Decoder.init(allocator);
    defer dec.deinit();
    try std.testing.expectEqual(default_table_size, dec.settings_max_table_size);

    // 4096 needs a multi-byte 5-bit-prefixed integer: 0x3f, rest = 4065.
    const to_advertised = [_]u8{ 0x3f, 0xe1, 0x1f };
    try std.testing.expectEqual(@as(usize, 0), (try dec.decode(&to_advertised)).len);
    try std.testing.expectEqual(@as(usize, 4096), dec.max_table_size);

    const to_zero = [_]u8{0x20};
    try std.testing.expectEqual(@as(usize, 0), (try dec.decode(&to_zero)).len);
    try std.testing.expectEqual(@as(usize, 0), dec.max_table_size);

    // Back up to the advertised ceiling is allowed; one byte more is not.
    try std.testing.expectEqual(@as(usize, 0), (try dec.decode(&to_advertised)).len);
    const oversize = [_]u8{ 0x3f, 0xe2, 0x1f }; // 4097
    try std.testing.expectError(error.InvalidHpackTableSize, dec.decode(&oversize));
    try std.testing.expect(isConnectionError(error.InvalidHpackTableSize));
    try std.testing.expectEqual(@as(usize, 4096), dec.max_table_size);
}

test "Hpack advertised table size bounds what a peer may ask for" {
    const allocator = std.testing.allocator;
    var dec = Decoder.init(allocator);
    defer dec.deinit();

    var block = std.ArrayList(u8).empty;
    defer block.deinit(allocator);
    try appendLitIncNewName(&block, allocator, "a", "1");
    try appendLitIncNewName(&block, allocator, "b", "2");
    const two = try dec.decode(block.items);
    defer freeHeaders(allocator, two);
    try std.testing.expectEqual(@as(usize, 68), dec.current_size);

    // Shrinking below the newest entry trims the table immediately.
    dec.setAdvertisedTableSize(34);
    try std.testing.expectEqual(@as(usize, 1), dec.dynamic.items.len);
    try std.testing.expectEqual(@as(usize, 34), dec.current_size);
    try std.testing.expectEqualStrings("b", dec.dynamic.items[0].name);

    // 35 is now above what we advertised: 0x3f, rest = 35 - 31 = 4.
    const too_big = [_]u8{ 0x3f, 0x04 };
    try std.testing.expectError(error.InvalidHpackTableSize, dec.decode(&too_big));
    // 34 is exactly the limit: 0x3f, rest = 3.
    const at_limit = [_]u8{ 0x3f, 0x03 };
    try std.testing.expectEqual(@as(usize, 0), (try dec.decode(&at_limit)).len);
    try std.testing.expectEqual(@as(usize, 34), dec.max_table_size);
}

test "Hpack isConnectionError separates compression failures from OOM" {
    try std.testing.expect(isConnectionError(error.InvalidHpack));
    try std.testing.expect(isConnectionError(error.InvalidHpackIndex));
    try std.testing.expect(isConnectionError(error.InvalidHpackTableSize));
    try std.testing.expect(!isConnectionError(error.OutOfMemory));

    var dec = Decoder.init(std.testing.allocator);
    defer dec.deinit();
    // Indexed 62 against an empty dynamic table — a real decode failure, and
    // one the caller must classify as a connection error.
    const malformed = [_]u8{0xbe};
    try std.testing.expectError(error.InvalidHpackIndex, dec.decode(&malformed));
}

test "Hpack decoder follows RFC 7541 C.3 (dynamic table, 256-byte limit)" {
    const allocator = std.testing.allocator;
    var dec = Decoder.init(allocator);
    defer dec.deinit();
    dec.setAdvertisedTableSize(256);

    // C.3.1 — :method GET, :scheme http, :path /, :authority www.example.com.
    const first = [_]u8{
        0x82, 0x86, 0x84, 0x41, 0x0f, 'w', 'w', 'w', '.', 'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm',
    };
    const h1 = try dec.decode(&first);
    defer freeHeaders(allocator, h1);
    try std.testing.expectEqual(@as(usize, 4), h1.len);
    try std.testing.expectEqualStrings(":method", h1[0].name);
    try std.testing.expectEqualStrings("GET", h1[0].value);
    try std.testing.expectEqualStrings(":authority", h1[3].name);
    try std.testing.expectEqualStrings("www.example.com", h1[3].value);
    try std.testing.expectEqual(@as(usize, 57), dec.current_size);

    // C.3.2 — same four headers, :authority now from the dynamic table (index
    // 62), plus cache-control: no-cache.
    const second = [_]u8{ 0x82, 0x86, 0x84, 0xbe, 0x58, 0x08, 'n', 'o', '-', 'c', 'a', 'c', 'h', 'e' };
    const h2 = try dec.decode(&second);
    defer freeHeaders(allocator, h2);
    try std.testing.expectEqual(@as(usize, 5), h2.len);
    try std.testing.expectEqualStrings(":authority", h2[3].name);
    try std.testing.expectEqualStrings("www.example.com", h2[3].value);
    try std.testing.expectEqualStrings("cache-control", h2[4].name);
    try std.testing.expectEqualStrings("no-cache", h2[4].value);
    try std.testing.expectEqual(@as(usize, 110), dec.current_size);

    // C.3.3 — :scheme https, :path /index.html, :authority via index 63, then a
    // new literal name with incremental indexing.
    const third = [_]u8{
        0x82, 0x87, 0x85, 0xbf, 0x40, 0x0a, 'c', 'u', 's', 't', 'o', 'm', '-', 'k', 'e', 'y', 0x0c, 'c', 'u', 's', 't', 'o', 'm', '-', 'v', 'a', 'l', 'u', 'e',
    };
    const h3 = try dec.decode(&third);
    defer freeHeaders(allocator, h3);
    try std.testing.expectEqual(@as(usize, 5), h3.len);
    try std.testing.expectEqualStrings(":scheme", h3[1].name);
    try std.testing.expectEqualStrings("https", h3[1].value);
    try std.testing.expectEqualStrings(":path", h3[2].name);
    try std.testing.expectEqualStrings("/index.html", h3[2].value);
    try std.testing.expectEqualStrings(":authority", h3[3].name);
    try std.testing.expectEqualStrings("custom-key", h3[4].name);
    try std.testing.expectEqualStrings("custom-value", h3[4].value);
    try std.testing.expectEqual(@as(usize, 164), dec.current_size);
    try std.testing.expectEqual(@as(usize, 3), dec.dynamic.items.len);
}

test "Hpack freeHeaders follows explicit ownership over the static fingerprint" {
    const allocator = std.testing.allocator;

    // `.borrowed` wins over the fingerprint: heap slices stay with the caller.
    const name = try allocator.dupe(u8, "x-name");
    defer allocator.free(name);
    const value = try allocator.dupe(u8, "x-value");
    defer allocator.free(value);
    const borrowed = try allocator.alloc(Header, 1);
    borrowed[0] = .{ .name = name, .value = value, .name_owner = .borrowed, .value_owner = .borrowed };
    freeHeaders(allocator, borrowed);
    try std.testing.expectEqualStrings("x-name", name);
    try std.testing.expectEqualStrings("x-value", value);

    // Headers a caller built by hand keep the old fingerprint behaviour:
    // static-table slices are never released.
    const legacy = try allocator.alloc(Header, 1);
    legacy[0] = .{ .name = static_table[2].name, .value = static_table[2].value };
    freeHeaders(allocator, legacy);
    try std.testing.expectEqualStrings(":method", static_table[2].name);
    try std.testing.expectEqualStrings("GET", static_table[2].value);
}

// ---------------------------------------------------------------------------
// Header-list budget (RFC 9113 §6.5.2 SETTINGS_MAX_HEADER_LIST_SIZE).
// ---------------------------------------------------------------------------

test "Hpack decoder enforces the advertised header list size" {
    const allocator = std.testing.allocator;

    // Two `a`/`1` + `b`/`2` pairs: 34 bytes each (name + value + the 32-byte
    // per-field overhead), so 64 is spent by the second field.
    var block = std.ArrayList(u8).empty;
    defer block.deinit(allocator);
    try appendLitIncNewName(&block, allocator, "a", "1");
    try appendLitIncNewName(&block, allocator, "b", "2");

    var dec = Decoder.init(allocator);
    defer dec.deinit();
    // Default is unbounded: an existing `Decoder` user sees no change.
    try std.testing.expectEqual(@as(usize, 0), dec.max_header_list_size);

    dec.setAdvertisedHeaderListSize(64, 0);
    try std.testing.expectError(error.HeaderListTooLarge, dec.decode(block.items));
    // A list past what we advertised is a *stream* error: the block decoded.
    try std.testing.expect(!isConnectionError(error.HeaderListTooLarge));

    // Both insertions landed: the loop ran to the end of the block instead of
    // bailing out at the limit, which is what keeps our dynamic table in step
    // with the peer's encoder. 68 = 34 + 34, even though only the first field
    // was kept.
    try std.testing.expectEqual(@as(usize, 68), dec.current_size);
    try std.testing.expectEqual(@as(usize, 2), dec.dynamic.items.len);
    // …and the connection-level state is still usable: the very next block
    // referencing those entries decodes against the same decoder.
    dec.setAdvertisedHeaderListSize(0, 0);
    const refs = [_]u8{ 0xbe, 0xbf }; // indexes 62 then 63
    const after = try dec.decode(&refs);
    defer freeHeaders(allocator, after);
    try std.testing.expectEqual(@as(usize, 2), after.len);
    try std.testing.expectEqualStrings("b", after[0].name);
    try std.testing.expectEqualStrings("2", after[0].value);
    try std.testing.expectEqualStrings("a", after[1].name);

    // Exactly at the advertised size is still within the budget.
    dec.setAdvertisedHeaderListSize(68, 0);
    const at_limit = try dec.decode(block.items);
    defer freeHeaders(allocator, at_limit);
    try std.testing.expectEqual(@as(usize, 2), at_limit.len);
}

test "Hpack decoder enforces the advertised header count" {
    const allocator = std.testing.allocator;

    var block = std.ArrayList(u8).empty;
    defer block.deinit(allocator);
    try appendLitIncNewName(&block, allocator, "a", "1");
    try appendLitIncNewName(&block, allocator, "b", "2");

    var dec = Decoder.init(allocator);
    defer dec.deinit();

    // Byte budget off, count budget on: one field fits, the second is over.
    dec.setAdvertisedHeaderListSize(0, 1);
    try std.testing.expectError(error.TooManyHeaderFields, dec.decode(block.items));
    try std.testing.expect(!isConnectionError(error.TooManyHeaderFields));
    // The block still decoded in full — same reason as the byte budget.
    try std.testing.expectEqual(@as(usize, 68), dec.current_size);

    dec.setAdvertisedHeaderListSize(0, 2);
    const two = try dec.decode(block.items);
    defer freeHeaders(allocator, two);
    try std.testing.expectEqual(@as(usize, 2), two.len);
}

test "Hpack oversize list drops the extra fields without leaking them" {
    const allocator = std.testing.allocator;

    // Two indexed fields whose names/values are table entries: each is an
    // owned dupe, so the one the budget refuses has to be released by the
    // decoder (std.testing.allocator fails the test on a leak).
    var block = std.ArrayList(u8).empty;
    defer block.deinit(allocator);
    try appendLitIncNewName(&block, allocator, "x-name", "x-value");
    try appendLitIncNewName(&block, allocator, "y-name", "y-value");

    var dec = Decoder.init(allocator);
    defer dec.deinit();

    const seeded = try dec.decode(block.items);
    freeHeaders(allocator, seeded);

    // The same two fields again, this time as dynamic-table references: 1 byte
    // each on the wire, 45 bytes each once decoded — the inflation the budget
    // exists for. Both fit at 90…
    const refs = [_]u8{ 0xbf, 0xbe }; // indexes 63 then 62
    dec.setAdvertisedHeaderListSize(90, 0);
    const inflated = try dec.decode(&refs);
    defer freeHeaders(allocator, inflated);
    try std.testing.expectEqual(@as(usize, 2), inflated.len);
    try std.testing.expectEqualStrings("x-name", inflated[0].name);
    try std.testing.expectEqualStrings("y-value", inflated[1].value);

    // …and at 60 only the first does, so the second is decoded, charged and
    // then dropped: no leak, and no new table entries either (indexed fields
    // insert nothing), so the size the first block left is unchanged.
    dec.setAdvertisedHeaderListSize(60, 0);
    try std.testing.expectError(error.HeaderListTooLarge, dec.decode(&refs));
    try std.testing.expectEqual(@as(usize, 90), dec.current_size);
}

test "Hpack huffman-encoded literal name decodes to the name itself" {
    const allocator = std.testing.allocator;

    // `01` + index 0 and `0000` + index 0: both literal branches with a *new*
    // name, the name Huffman-encoded (the values stay raw). `decodeString`
    // allocates the name in both, so this is where an owned name buffer has to
    // survive until the caller's own copy has been taken.
    const name_a = "x-trace-id";
    const name_b = "x-request-id";
    var block = std.ArrayList(u8).empty;
    defer block.deinit(allocator);
    for ([_][]const u8{ name_a, name_b }, 0..) |n, i| {
        try block.append(allocator, if (i == 0) 0x40 else 0x00);
        const enc = try huffmanEncode(allocator, n);
        defer allocator.free(enc);
        try appendStringHuffman(&block, allocator, enc);
        try appendStringRaw(&block, allocator, if (i == 0) "abc-123" else "def-456");
    }

    var dec = Decoder.init(allocator);
    defer dec.deinit();
    const headers = try dec.decode(block.items);
    defer freeHeaders(allocator, headers);
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings(name_a, headers[0].name);
    try std.testing.expectEqualStrings("abc-123", headers[0].value);
    try std.testing.expectEqualStrings(name_b, headers[1].name);
    try std.testing.expectEqualStrings("def-456", headers[1].value);
    // The first branch also inserts, and that copy is taken from the same
    // buffer: the table entry must carry the name, not its freed remains.
    try std.testing.expectEqual(@as(usize, 1), dec.dynamic.items.len);
    try std.testing.expectEqualStrings(name_a, dec.dynamic.items[0].name);
}

// ---------------------------------------------------------------------------
// OOM scan (std.testing.checkAllAllocationFailures).
// ---------------------------------------------------------------------------

// `decode` is the file's densest allocation site: four branch shapes, each
// with its own `errdefer`/ownership hand-off, plus the dynamic table's own
// copies. `checkAllAllocationFailures` re-runs it once per allocation point
// with that allocation failing, and asserts the error propagates (no
// swallowing) with every byte that was handed out given back.
test "Hpack decode survives every allocation point failing (OOM scan)" {
    const allocator = std.testing.allocator;

    // One field per branch shape: indexed static (allocates nothing), literal
    // with incremental indexing and a new name (duplicates both halves, then
    // inserts a second pair into the dynamic table), an *indexed reference* to
    // the entry that insertion created — both halves of that one are allocated
    // inside a struct literal — and literal without indexing, which copies
    // without inserting.
    var block = std.ArrayList(u8).empty;
    defer block.deinit(allocator);
    try block.append(allocator, 0x82); // indexed static 2 → :method GET
    try appendLitIncNewName(&block, allocator, "x-trace-id", "abc-123");
    try block.append(allocator, @intCast(0x80 | static_table.len)); // dynamic index 62
    try block.append(allocator, 0x00); // literal without indexing, new name
    try appendStringRaw(&block, allocator, "x-extra");
    try appendStringRaw(&block, allocator, "yes");

    const Scan = struct {
        fn run(alloc: std.mem.Allocator, b: []const u8) !void {
            var dec = Decoder.init(alloc);
            defer dec.deinit();
            const headers = try dec.decode(b);
            defer freeHeaders(alloc, headers);
            try std.testing.expectEqual(@as(usize, 4), headers.len);
            try std.testing.expectEqual(@as(usize, 1), dec.dynamic.items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{block.items});
}

// Same scan for the header-list budget path: every field is decoded and then
// dropped by `HeaderListBudget.charge`, so `release` + `continue` is the code
// under the injector, and the block still has to end in the limit error.
test "Hpack budget-dropped fields survive every allocation point failing (OOM scan)" {
    const allocator = std.testing.allocator;

    // One 45-byte entry (6 + 7 + the 32-byte per-field overhead) referenced
    // three times: against a 45-byte budget the first reference fits and the
    // other two are decoded, charged and released.
    var block = std.ArrayList(u8).empty;
    defer block.deinit(allocator);
    try appendLitIncNewName(&block, allocator, "x-name", "x-value");
    std.debug.assert(static_table.len == 62);
    try block.appendSlice(allocator, &.{ 0xbe, 0xbe, 0xbe }); // dynamic index 62, thrice

    const Scan = struct {
        fn run(alloc: std.mem.Allocator, b: []const u8) !void {
            var dec = Decoder.init(alloc);
            defer dec.deinit();
            const seeded = try dec.decode(b);
            defer freeHeaders(alloc, seeded);

            dec.setAdvertisedHeaderListSize(45, 0);
            const result = dec.decode(b);
            if (result) |limited| {
                // The budget must have refused the extra references.
                freeHeaders(alloc, limited);
                return error.ExpectedHeaderListTooLarge;
            } else |err| switch (err) {
                error.OutOfMemory => return err, // the injected failure comes back out
                error.HeaderListTooLarge => {}, // the budget path, exercised in full
                else => return err,
            }
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{block.items});
}
