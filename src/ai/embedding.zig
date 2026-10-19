//! OpenAI-compatible embeddings.
//!
//! `ai.rag` deliberately leaves the embedding call to the application (an
//! embedding model is a provider-specific HTTP endpoint). This module is the
//! common case: `POST /v1/embeddings` with `{"model", "input", "dimensions?"}`,
//! batched, with the response parsed into `[][]f32` ready for `VectorIndex`.
//!
//! It is a thin client, not a vector store: no caching, no retries beyond the
//! HTTP client's own, no key rotation (wrap it in a `ProviderRegistry`-style
//! caller if you need those).

const std = @import("std");
const http_client = @import("../http/HttpClient.zig");
const retriever = @import("retriever.zig");

pub const OpenAiEmbeddings = struct {
    allocator: std.mem.Allocator,
    http: *http_client.HttpClient,
    /// Full endpoint, e.g. `https://api.openai.com/v1/embeddings`.
    endpoint: []const u8,
    api_key: []const u8,
    model: []const u8 = "text-embedding-3-small",
    /// Optional `dimensions` (OpenAI text-embedding-3+ supports shortening).
    dims: ?usize = null,

    pub const Result = struct {
        /// One vector per input, in request order.
        embeddings: [][]f32,
        prompt_tokens: usize = 0,
        total_tokens: usize = 0,

        pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
            for (self.embeddings) |v| allocator.free(v);
            allocator.free(self.embeddings);
            self.* = undefined;
        }
    };

    /// Embed a batch. The caller owns the result (`deinit`).
    pub fn embed(
        self: *OpenAiEmbeddings,
        allocator: std.mem.Allocator,
        inputs: []const []const u8,
    ) !Result {
        if (inputs.len == 0) return .{ .embeddings = &.{} };
        const body = try buildRequestBody(allocator, self.model, self.dims, inputs);
        defer allocator.free(body);

        var req = http_client.HttpClient.HttpRequest.init(allocator, "POST", self.endpoint);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Authorization", self.api_key);
        try req.setBody(body);

        var resp = try self.http.request(req);
        defer resp.deinit();
        if (!resp.isSuccess()) return error.EmbeddingRequestFailed;
        return parseResponse(allocator, resp.body, inputs.len);
    }

    /// Embed one text and hand back just its vector (freed by the caller).
    /// This is the shape `Retriever.retrieveScopedFn` needs.
    pub fn embedOne(
        self: *OpenAiEmbeddings,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) ![]f32 {
        var one = [_][]const u8{text};
        var result = try self.embed(allocator, &one);
        defer {
            for (result.embeddings[1..]) |v| allocator.free(v);
            allocator.free(result.embeddings);
        }
        return result.embeddings[0];
    }
};

/// `EmbedFn` adapter: `IndexRetriever.embed_ctx = &adapter`, `embed_fn =
/// Adapter.embed`.
pub const Adapter = struct {
    impl: *OpenAiEmbeddings,

    pub fn embed(ctx: *anyopaque, allocator: std.mem.Allocator, text: []const u8) anyerror![]f32 {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        return self.impl.embedOne(allocator, text);
    }
};

/// Request body for the batch (`{"model":…,"input":[…],"dimensions":N?}`).
pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    dims: ?usize,
    inputs: []const []const u8,
) ![]u8 {
    const Payload = struct {
        model: []const u8,
        input: []const []const u8,
        dimensions: ?usize = null,
    };
    // `emit_null_optional_fields = false`: the API treats an absent
    // `dimensions` and a null one the same, but omitting it keeps the request
    // body exactly the documented shape.
    return std.json.Stringify.valueAlloc(allocator, Payload{
        .model = model,
        .input = inputs,
        .dimensions = dims,
    }, .{ .emit_null_optional_fields = false });
}

/// Parse `{"data":[{"embedding":[…]},…],"usage":{…}}`.
///
/// Validates that the count matches the request and that every vector has the
/// same non-zero length — a length mismatch between vectors would make
/// `VectorIndex` reject the second insert, so it is refused here with the index
/// of the offending row.
pub fn parseResponse(allocator: std.mem.Allocator, body: []const u8, expected: usize) !OpenAiEmbeddings.Result {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const data = (root.get("data") orelse return error.InvalidEmbeddingResponse).array;
    if (data.items.len != expected) return error.EmbeddingCountMismatch;

    var out = try allocator.alloc([]f32, data.items.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |v| allocator.free(v);
        allocator.free(out);
    }
    var dims: usize = 0;
    for (data.items, 0..) |item, i| {
        const arr = (item.object.get("embedding") orelse return error.InvalidEmbeddingResponse).array;
        if (arr.items.len == 0) return error.EmptyEmbedding;
        if (i == 0) {
            dims = arr.items.len;
        } else if (arr.items.len != dims) return error.EmbeddingDimensionMismatch;
        const vec = try allocator.alloc(f32, arr.items.len);
        errdefer allocator.free(vec);
        for (arr.items, 0..) |v, k| vec[k] = switch (v) {
            .float => |f| @floatCast(f),
            .integer => |n| @floatFromInt(n),
            else => return error.InvalidEmbeddingResponse,
        };
        out[built] = vec;
        built += 1;
    }

    var prompt_tokens: usize = 0;
    var total_tokens: usize = 0;
    if (root.get("usage")) |usage| {
        if (usage == .object) {
            if (usage.object.get("prompt_tokens")) |v| if (v == .integer) {
                prompt_tokens = @intCast(v.integer);
            };
            if (usage.object.get("total_tokens")) |v| if (v == .integer) {
                total_tokens = @intCast(v.integer);
            };
        }
    }
    return .{ .embeddings = out, .prompt_tokens = prompt_tokens, .total_tokens = total_tokens };
}

test "buildRequestBody carries model, inputs and optional dimensions" {
    const allocator = std.testing.allocator;
    const body = try buildRequestBody(allocator, "text-embedding-3-small", 256, &.{ "a", "b" });
    defer allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("text-embedding-3-small", parsed.value.object.get("model").?.string);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("input").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 256), parsed.value.object.get("dimensions").?.integer);

    const no_dims = try buildRequestBody(allocator, "m", null, &.{"x"});
    defer allocator.free(no_dims);
    try std.testing.expect(std.mem.indexOf(u8, no_dims, "dimensions") == null);
}

test "parseResponse builds vectors and validates count/dimensions" {
    const allocator = std.testing.allocator;
    const ok =
        \\{"data":[{"embedding":[0.1,0.2]},{"embedding":[0.3,0.4]}],"usage":{"prompt_tokens":5,"total_tokens":5}}
    ;
    var res = try parseResponse(allocator, ok, 2);
    defer res.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), res.embeddings.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), res.embeddings[1][0], 1e-6);
    try std.testing.expectEqual(@as(usize, 5), res.prompt_tokens);

    try std.testing.expectError(error.EmbeddingCountMismatch, parseResponse(allocator,
        \\{"data":[{"embedding":[0.1]}]}
    , 2));
    try std.testing.expectError(error.EmbeddingDimensionMismatch, parseResponse(allocator,
        \\{"data":[{"embedding":[0.1]},{"embedding":[0.1,0.2]}]}
    , 2));
}
