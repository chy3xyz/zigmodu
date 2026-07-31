//! HPACK (RFC 7541) — static + dynamic table encode/decode for HTTP/2.
//! Huffman string literals (RFC 7541 Appendix B) are supported.

const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
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
            }
        }
    }
    if (idx != 0 and !huffman_padding_ok[idx]) return error.InvalidHpack;
    return out.toOwnedSlice(allocator);
}

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    dynamic: std.ArrayList(OwnedHeader) = .empty,
    max_table_size: usize = 4096,
    current_size: usize = 0,

    const OwnedHeader = struct {
        name: []u8,
        value: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) Decoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Decoder) void {
        self.clearDynamic();
        self.dynamic.deinit(self.allocator);
        self.* = undefined;
    }

    fn clearDynamic(self: *Decoder) void {
        for (self.dynamic.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.dynamic.clearRetainingCapacity();
        self.current_size = 0;
    }

    /// Decode header block. Returns owned Header slice (names/values owned; free with freeHeaders).
    pub fn decode(self: *Decoder, block: []const u8) ![]Header {
        var out = std.ArrayList(Header).empty;
        errdefer {
            freeHeaders(self.allocator, out.items);
            out.deinit(self.allocator);
        }
        var i: usize = 0;
        while (i < block.len) {
            const b = block[i];
            if (b & 0x80 != 0) {
                const idx, const n = try decodeInt(block[i..], 7);
                i += n;
                const h = try self.lookup(idx);
                try out.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, h.name),
                    .value = try self.allocator.dupe(u8, h.value),
                });
                continue;
            }
            if (b & 0x40 != 0) {
                const name_idx, const n0 = try decodeInt(block[i..], 6);
                i += n0;
                const name = if (name_idx == 0) blk: {
                    const ds = try decodeString(self.allocator, block[i..]);
                    i += ds.consumed;
                    defer if (ds.owned) self.allocator.free(@constCast(ds.value));
                    break :blk ds.value;
                } else (try self.lookup(name_idx)).name;
                const value_ds = try decodeString(self.allocator, block[i..]);
                i += value_ds.consumed;
                defer if (value_ds.owned) self.allocator.free(@constCast(value_ds.value));
                const value = value_ds.value;
                const name_owned = try self.allocator.dupe(u8, name);
                errdefer self.allocator.free(name_owned);
                const value_owned = try self.allocator.dupe(u8, value);
                errdefer self.allocator.free(value_owned);
                try self.pushDynamic(name_owned, value_owned);
                try out.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, name_owned),
                    .value = try self.allocator.dupe(u8, value_owned),
                });
                continue;
            }
            const name_idx, const n0 = try decodeInt(block[i..], 4);
            i += n0;
            const name = if (name_idx == 0) blk: {
                const ds = try decodeString(self.allocator, block[i..]);
                i += ds.consumed;
                defer if (ds.owned) self.allocator.free(@constCast(ds.value));
                break :blk ds.value;
            } else (try self.lookup(name_idx)).name;
            const value_ds = try decodeString(self.allocator, block[i..]);
            i += value_ds.consumed;
            defer if (value_ds.owned) self.allocator.free(@constCast(value_ds.value));
            const value = value_ds.value;
            try out.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, name),
                .value = try self.allocator.dupe(u8, value),
            });
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn lookup(self: *Decoder, index: usize) !Header {
        if (index == 0) return error.InvalidHpackIndex;
        if (index < static_table.len) return static_table[index];
        const dyn_i = index - static_table.len;
        if (dyn_i >= self.dynamic.items.len) return error.InvalidHpackIndex;
        const rev = self.dynamic.items.len - 1 - dyn_i;
        const h = self.dynamic.items[rev];
        return .{ .name = h.name, .value = h.value };
    }

    fn pushDynamic(self: *Decoder, name: []u8, value: []u8) !void {
        const entry_size = name.len + value.len + 32;
        while (self.current_size + entry_size > self.max_table_size and self.dynamic.items.len > 0) {
            const old = self.dynamic.orderedRemove(0);
            self.current_size -= old.name.len + old.value.len + 32;
            self.allocator.free(old.name);
            self.allocator.free(old.value);
        }
        if (entry_size > self.max_table_size) {
            self.allocator.free(name);
            self.allocator.free(value);
            return;
        }
        try self.dynamic.append(self.allocator, .{ .name = name, .value = value });
        self.current_size += entry_size;
    }
};

pub fn freeHeaders(allocator: std.mem.Allocator, headers: []Header) void {
    for (headers) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
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
