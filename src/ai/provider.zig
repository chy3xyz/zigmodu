const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const http_client = @import("../http/HttpClient.zig");

/// OpenAI-compatible chat provider with DeepSeek cache optimization.
///
/// Cache strategy: implicit prefix caching (DeepSeek V4).
/// Static content (system + tools) FIRST → cached. Dynamic content LAST.
///
/// Thread-safe: rate_limiter protected by mutex.
/// Connection pooling: via shared HttpClient.
pub const AiProvider = struct {
    allocator: std.mem.Allocator,
    http: *http_client.HttpClient,
    endpoint: []const u8,
    api_key: []const u8,
    model: []const u8,

    /// Rate limit (tokens/sec). Set to 0 to disable.
    rate_limiter: ?RateLimiterState = null,

    max_output_tokens: usize = 4096,
    temperature: f64 = 0.7,

    /// Cumulative metrics (monotonic).
    metrics: Metrics = .{},

    pub const RateLimiterState = struct {
        limiter: @import("../resilience/RateLimiter.zig").RateLimiter,
        io: std.Io,
        mutex: std.Io.Mutex,
    };

    pub const Metrics = struct {
        total_requests: usize = 0,
        total_prompt_tokens: usize = 0,
        total_completion_tokens: usize = 0,
        cache_hit_tokens: usize = 0,
        cache_miss_tokens: usize = 0,
        rate_limited_count: usize = 0,
        error_count: usize = 0,
    };

    pub const ChatMsg = struct {
        role: []const u8, // "system", "user", "assistant", "tool"
        content: []const u8,
        name: ?[]const u8 = null, // optional tool name for "tool" role
    };

    pub const ChatResponse = struct {
        content: []const u8, // caller owns, must free with allocator
        role: []const u8 = "assistant",
        prompt_tokens: usize = 0,
        completion_tokens: usize = 0,
        cache_hit_tokens: usize = 0,
        cache_miss_tokens: usize = 0,
        model: []const u8 = "",
    };

    pub fn init(
        allocator: std.mem.Allocator,
        http: *http_client.HttpClient,
        endpoint: []const u8,
        api_key: []const u8,
        model: []const u8,
    ) AiProvider {
        return .{
            .allocator = allocator,
            .http = http,
            .endpoint = endpoint,
            .api_key = api_key,
            .model = model,
        };
    }

    /// Enable rate limiting. tokens_per_sec: max requests per second.
    pub fn enableRateLimit(self: *AiProvider, io: std.Io, tokens_per_sec: u32) !void {
        const limiter = try @import("../resilience/RateLimiter.zig").RateLimiter.init(
            self.allocator, "ai_provider", tokens_per_sec, tokens_per_sec,
        );
        self.rate_limiter = .{ .limiter = limiter, .io = io, .mutex = std.Io.Mutex.init };
    }

    pub fn deinit(self: *AiProvider) void {
        if (self.rate_limiter) |*rl| {
            rl.limiter.deinit();
        }
    }

    /// Send chat messages, return response content. Caller owns ChatResponse.content.
    pub fn chat(self: *AiProvider, messages: []const ChatMsg) !ChatResponse {
        // Rate limit check
        if (self.rate_limiter) |*rl| {
            rl.mutex.lock(rl.io) catch return error.RateLimitLockFailed;
            defer rl.mutex.unlock(rl.io);
            if (!rl.limiter.tryAcquire()) {
                self.metrics.rate_limited_count += 1;
                return error.RateLimited;
            }
        }

        const body = try self.buildRequestBody(messages);
        defer self.allocator.free(body);

        var req = http_client.HttpClient.HttpRequest.init(self.allocator, "POST", self.endpoint);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Authorization", self.api_key);
        try req.setBody(body);

        var resp = try self.http.request(req);
        defer resp.deinit();

        self.metrics.total_requests += 1;

        if (!resp.isSuccess()) {
            self.metrics.error_count += 1;
            if (resp.status_code == 429) return error.RateLimited;
            return error.ProviderError;
        }

        return self.parseResponse(resp.body);
    }

    /// Build JSON request body. Messages MUST be in cache-optimal order:
    /// [system] [tool-defs] [memories] [history] [user-query]
    pub fn buildRequestBody(self: *AiProvider, messages: []const ChatMsg) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        const a = self.allocator;

        try buf.appendSlice(a, "{\"model\":\"");
        try buf.appendSlice(a, self.model);
        try buf.appendSlice(a, "\",\"messages\":[");
        // Messages already ordered by caller for cache prefix stability
        for (messages, 0..) |m, i| {
            if (i > 0) try buf.appendSlice(a, ",");
            try buf.appendSlice(a, "{\"role\":\"");
            try buf.appendSlice(a, m.role);
            try buf.appendSlice(a, "\",\"content\":\"");
            try escapeJson(a, &buf, m.content);
            try buf.appendSlice(a, "\"}");
        }
        try buf.appendSlice(a, "],\"max_tokens\":");
        try buf.print(a, "{d}", .{self.max_output_tokens});
        try buf.appendSlice(a, ",\"temperature\":");
        try buf.print(a, "{d}", .{self.temperature});
        try buf.appendSlice(a, ",\"stream\":false}");

        return buf.toOwnedSlice(a);
    }

    /// Parse response, extracting content and cache metrics.
    fn parseResponse(self: *AiProvider, body: []const u8) !ChatResponse {
        var resp = ChatResponse{ .content = "" };

        // Extract content from choices[0].message.content
        if (std.mem.indexOf(u8, body, "\"content\":\"")) |start| {
            const cs = start + "\"content\":\"".len;
            var i: usize = cs;
            while (i < body.len) : (i += 1) {
                if (body[i] == '"' and (i == 0 or body[i - 1] != '\\')) {
                    resp.content = try self.allocator.dupe(u8, body[cs..i]);
                    break;
                }
            }
        }
        if (resp.content.len == 0) {
            resp.content = try self.allocator.dupe(u8, "");
        }

        // Extract usage
        resp.prompt_tokens = extractIntField(body, "\"prompt_tokens\":") orelse 0;
        resp.completion_tokens = extractIntField(body, "\"completion_tokens\":") orelse 0;
        resp.cache_hit_tokens = extractIntField(body, "\"prompt_cache_hit_tokens\":") orelse 0;
        resp.cache_miss_tokens = extractIntField(body, "\"prompt_cache_miss_tokens\":") orelse 0;
        if (extractStringField(body, "\"model\":\"")) |m| {
            resp.model = m;
        }

        self.metrics.total_prompt_tokens += resp.prompt_tokens;
        self.metrics.total_completion_tokens += resp.completion_tokens;
        self.metrics.cache_hit_tokens += resp.cache_hit_tokens;
        self.metrics.cache_miss_tokens += resp.cache_miss_tokens;

        return resp;
    }

    /// Build cache-optimized message array from components.
    /// Order: system → memories → history → user_query (prefix-stable first).
    pub fn buildMessages(
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        memories: []const []const u8,
        history: []const ChatMsg,
        user_msg: []const u8,
    ) ![]ChatMsg {
        var count: usize = 0;
        if (system_prompt != null) count += 1;
        count += memories.len;
        count += history.len;
        count += 1; // user message

        var msgs = try allocator.alloc(ChatMsg, count);
        var idx: usize = 0;

        // 1. System prompt — static, always cached first
        if (system_prompt) |sp| {
            msgs[idx] = .{ .role = "system", .content = sp };
            idx += 1;
        }

        // 2. Memories — semi-static, prefix-cached within session
        for (memories) |mem| {
            msgs[idx] = .{ .role = "system", .content = mem };
            idx += 1;
        }

        // 3. History — dynamic but prefix-stable (older messages cached)
        for (history) |h| {
            msgs[idx] = h;
            idx += 1;
        }

        // 4. User query — only truly new content
        msgs[idx] = .{ .role = "user", .content = user_msg };

        return msgs;
    }

    /// Estimate tokens for a message array.
    pub fn countTokens(_: *AiProvider, messages: []const ChatMsg) usize {
        return tokenizer.estimateMessages(messages);
    }

    /// Check if messages fit within context budget (conservative: 80% of max).
    pub fn fitsBudget(self: *AiProvider, messages: []const ChatMsg, context_limit: usize) bool {
        const est = tokenizer.estimateMessages(messages);
        return est + self.max_output_tokens < (context_limit * 4 / 5);
    }

    /// Get cache hit ratio (0.0 - 1.0).
    pub fn cacheHitRatio(self: *AiProvider) f64 {
        const total = self.metrics.cache_hit_tokens + self.metrics.cache_miss_tokens;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.metrics.cache_hit_tokens)) / @as(f64, @floatFromInt(total));
    }
};

fn extractIntField(body: []const u8, field: []const u8) ?usize {
    const start = std.mem.indexOf(u8, body, field) orelse return null;
    const vs = start + field.len;
    var i: usize = vs;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len) return null;
    var n: usize = 0;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {
        n = n * 10 + (body[i] - '0');
    }
    return n;
}

fn extractStringField(body: []const u8, field: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, body, field) orelse return null;
    const vs = start + field.len;
    if (std.mem.indexOf(u8, body[vs..], "\"")) |end| {
        return body[vs .. vs + end];
    }
    return null;
}

fn escapeJson(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
}

test "AiProvider buildMessages cache order" {
    const a = std.testing.allocator;
    const history = &[_]AiProvider.ChatMsg{
        .{ .role = "user", .content = "old question" },
        .{ .role = "assistant", .content = "old answer" },
    };
    const memories = &[_][]const u8{"User prefers short answers"};

    const msgs = try AiProvider.buildMessages(a, "You are helpful.", memories, history, "new question");
    defer a.free(msgs);

    try std.testing.expectEqual(@as(usize, 5), msgs.len);
    try std.testing.expectEqualStrings("system", msgs[0].role);
    try std.testing.expectEqualStrings("You are helpful.", msgs[0].content);
    try std.testing.expectEqualStrings("system", msgs[1].role);
    try std.testing.expectEqualStrings("User prefers short answers", msgs[1].content);
    try std.testing.expectEqualStrings("user", msgs[2].role); // history
    try std.testing.expectEqualStrings("user", msgs[4].role);
    try std.testing.expectEqualStrings("new question", msgs[4].content);
}

test "AiProvider buildRequestBody" {
    const a = std.testing.allocator;
    var http = http_client.HttpClient.init(a, std.testing.io, 1, 5000);
    defer http.deinit();
    var p = AiProvider.init(a, &http, "https://api.test/v1", "Bearer sk-xxx", "deepseek-v4-flash");

    const msgs = &[_]AiProvider.ChatMsg{
        .{ .role = "system", .content = "You are helpful." },
        .{ .role = "user", .content = "Hi" },
    };
    const body = try p.buildRequestBody(msgs);
    defer a.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "deepseek-v4-flash") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
}

test "AiProvider parseResponse" {
    const a = std.testing.allocator;
    var http = http_client.HttpClient.init(a, std.testing.io, 1, 5000);
    defer http.deinit();
    var p = AiProvider.init(a, &http, "https://api.test/v1", "sk-xxx", "deepseek-v4-flash");

    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"Hello!"}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_cache_hit_tokens":8,"prompt_cache_miss_tokens":2},"model":"deepseek-v4-flash"}
    ;
    const resp = try p.parseResponse(body);
    defer a.free(resp.content);

    try std.testing.expectEqualStrings("Hello!", resp.content);
    try std.testing.expectEqual(@as(usize, 10), resp.prompt_tokens);
    try std.testing.expectEqual(@as(usize, 2), resp.completion_tokens);
    try std.testing.expectEqual(@as(usize, 8), resp.cache_hit_tokens);
    try std.testing.expectEqual(@as(usize, 2), resp.cache_miss_tokens);
}

test "AiProvider countTokens" {
    const a = std.testing.allocator;
    var http = http_client.HttpClient.init(a, std.testing.io, 1, 5000);
    defer http.deinit();
    var p = AiProvider.init(a, &http, "https://api.test/v1", "sk-xxx", "deepseek-v4-flash");

    const msgs = &[_]AiProvider.ChatMsg{
        .{ .role = "system", .content = "You are helpful." },
        .{ .role = "user", .content = "Hello, how are you?" },
    };
    const tokens = p.countTokens(msgs);
    try std.testing.expect(tokens > 5);
    try std.testing.expect(tokens < 50);
}

test "AiProvider fitsBudget" {
    const a = std.testing.allocator;
    var http = http_client.HttpClient.init(a, std.testing.io, 1, 5000);
    defer http.deinit();
    var p = AiProvider.init(a, &http, "https://api.test/v1", "sk-xxx", "deepseek-v4-flash");

    const msgs = &[_]AiProvider.ChatMsg{
        .{ .role = "system", .content = "You are helpful." },
        .{ .role = "user", .content = "Hi" },
    };
    try std.testing.expect(p.fitsBudget(msgs, 128000)); // 128K context
}

test "AiProvider cacheHitRatio" {
    const a = std.testing.allocator;
    var http = http_client.HttpClient.init(a, std.testing.io, 1, 5000);
    defer http.deinit();
    var p = AiProvider.init(a, &http, "https://api.test/v1", "sk-xxx", "deepseek-v4-flash");

    p.metrics.cache_hit_tokens = 80;
    p.metrics.cache_miss_tokens = 20;
    const ratio = p.cacheHitRatio();
    try std.testing.expect(ratio >= 0.79 and ratio <= 0.81);
}
