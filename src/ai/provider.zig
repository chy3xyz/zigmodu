//! OpenAI-compatible chat provider with tool_calls + DeepSeek cache metrics.
//!
//! Cache strategy: static content (system + tools) FIRST → cached; dynamic LAST.
//! Tool calling: pass `ChatOpts.tools_json` (from `SkillRegistry.toOpenAiFunctionsAlloc`).

const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const http_client = @import("../http/HttpClient.zig");
const key_pool = @import("key_pool.zig");

pub const AiProvider = struct {
    allocator: std.mem.Allocator,
    http: *http_client.HttpClient,
    endpoint: []const u8,
    api_key: []const u8,
    model: []const u8,

    /// Optional key pool for automatic key rotation on 401/403/429/402.
    /// When set (via `bindKeyPool`), a key-retryable failure swaps `api_key`
    /// to the next healthy key and retries once. The pool must outlive this
    /// provider (leased keys are borrowed).
    key_pool: ?*key_pool.KeyPool = null,
    key_index: ?usize = null,
    pool_io: ?std.Io = null,

    rate_limiter: ?RateLimiterState = null,
    max_output_tokens: usize = 4096,
    temperature: f64 = 0.7,
    metrics: Metrics = .{},

    pub const RateLimiterState = struct {
        limiter: @import("../resilience/RateLimiter.zig").RateLimiter,
        io: std.Io,
        mutex: std.Io.Mutex,
    };

    pub const Metrics = struct {
        total_requests: std.atomic.Value(usize) = .init(0),
        total_prompt_tokens: std.atomic.Value(usize) = .init(0),
        total_completion_tokens: std.atomic.Value(usize) = .init(0),
        cache_hit_tokens: std.atomic.Value(usize) = .init(0),
        cache_miss_tokens: std.atomic.Value(usize) = .init(0),
        rate_limited_count: std.atomic.Value(usize) = .init(0),
        error_count: std.atomic.Value(usize) = .init(0),
        tool_call_responses: std.atomic.Value(usize) = .init(0),

        /// Plain-field snapshot for external readers — avoids touching atomic
        /// `.load()` per field (and the `{d}` compile error when a Value is
        /// passed to a formatter directly).
        pub fn toStats(self: Metrics) Stats {
            return .{
                .total_requests = self.total_requests.load(.monotonic),
                .total_prompt_tokens = self.total_prompt_tokens.load(.monotonic),
                .total_completion_tokens = self.total_completion_tokens.load(.monotonic),
                .cache_hit_tokens = self.cache_hit_tokens.load(.monotonic),
                .cache_miss_tokens = self.cache_miss_tokens.load(.monotonic),
                .rate_limited_count = self.rate_limited_count.load(.monotonic),
                .error_count = self.error_count.load(.monotonic),
                .tool_call_responses = self.tool_call_responses.load(.monotonic),
            };
        }

        /// Non-atomic mirror of `Metrics` for external readers / logging.
        pub const Stats = struct {
            total_requests: usize = 0,
            total_prompt_tokens: usize = 0,
            total_completion_tokens: usize = 0,
            cache_hit_tokens: usize = 0,
            cache_miss_tokens: usize = 0,
            rate_limited_count: usize = 0,
            error_count: usize = 0,
            tool_call_responses: usize = 0,
        };

        pub fn toPrometheusFormat(self: Metrics, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            try buf.print(allocator, "# HELP zigmodu_ai_provider_requests_total Chat completion requests.\n", .{});
            try buf.print(allocator, "# TYPE zigmodu_ai_provider_requests_total counter\n", .{});
            try buf.print(allocator, "zigmodu_ai_provider_requests_total{{provider=\"{s}\"}} {d}\n", .{ name, self.total_requests.load(.monotonic) });
            try buf.print(allocator, "# HELP zigmodu_ai_provider_prompt_tokens_total Prompt tokens.\n", .{});
            try buf.print(allocator, "# TYPE zigmodu_ai_provider_prompt_tokens_total counter\n", .{});
            try buf.print(allocator, "zigmodu_ai_provider_prompt_tokens_total{{provider=\"{s}\"}} {d}\n", .{ name, self.total_prompt_tokens.load(.monotonic) });
            try buf.print(allocator, "# HELP zigmodu_ai_provider_completion_tokens_total Completion tokens.\n", .{});
            try buf.print(allocator, "# TYPE zigmodu_ai_provider_completion_tokens_total counter\n", .{});
            try buf.print(allocator, "zigmodu_ai_provider_completion_tokens_total{{provider=\"{s}\"}} {d}\n", .{ name, self.total_completion_tokens.load(.monotonic) });
            try buf.print(allocator, "# HELP zigmodu_ai_provider_errors_total Provider errors.\n", .{});
            try buf.print(allocator, "# TYPE zigmodu_ai_provider_errors_total counter\n", .{});
            try buf.print(allocator, "zigmodu_ai_provider_errors_total{{provider=\"{s}\"}} {d}\n", .{ name, self.error_count.load(.monotonic) });
            try buf.print(allocator, "# HELP zigmodu_ai_provider_rate_limited_total Rate limit rejections.\n", .{});
            try buf.print(allocator, "# TYPE zigmodu_ai_provider_rate_limited_total counter\n", .{});
            try buf.print(allocator, "zigmodu_ai_provider_rate_limited_total{{provider=\"{s}\"}} {d}\n", .{ name, self.rate_limited_count.load(.monotonic) });
            try buf.print(allocator, "# HELP zigmodu_ai_provider_tool_call_responses_total Responses containing tool_calls.\n", .{});
            try buf.print(allocator, "# TYPE zigmodu_ai_provider_tool_call_responses_total counter\n", .{});
            try buf.print(allocator, "zigmodu_ai_provider_tool_call_responses_total{{provider=\"{s}\"}} {d}\n", .{ name, self.tool_call_responses.load(.monotonic) });
            return try buf.toOwnedSlice(allocator);
        }
    };

    /// One OpenAI-style tool call (owned strings when returned from `parseResponse`).
    pub const ToolCall = struct {
        id: []const u8,
        name: []const u8,
        arguments: []const u8,
    };

    pub const ChatMsg = struct {
        role: []const u8, // system | user | assistant | tool
        content: []const u8 = "",
        name: ?[]const u8 = null,
        /// Present on `tool` role messages.
        tool_call_id: ?[]const u8 = null,
        /// Present on `assistant` messages that request tools (borrowed; not freed by freeResponse).
        tool_calls: []const ToolCall = &.{},
    };

    pub const ChatOpts = struct {
        /// OpenAI `tools` JSON array (e.g. from SkillRegistry.toOpenAiFunctionsAlloc).
        tools_json: ?[]const u8 = null,
        /// Request `stream:true` for `chatStream` (SSE over `HttpClient.requestStream`).
        stream: bool = false,
    };

    pub const ChatResponse = struct {
        content: []const u8 = "",
        /// Reasoning/thinking-chain text from reasoning models (DeepSeek-R1,
        /// Qwen, …); empty for non-reasoning models. Owned like `content`.
        reasoning_content: []const u8 = "",
        role: []const u8 = "assistant",
        tool_calls: []ToolCall = &.{},
        prompt_tokens: usize = 0,
        completion_tokens: usize = 0,
        cache_hit_tokens: usize = 0,
        cache_miss_tokens: usize = 0,
        model: []const u8 = "",
    };

    pub const StreamDelta = struct {
        content_delta: ?[]const u8 = null,
        /// Incremental `reasoning_content` fragment (reasoning models only).
        reasoning_delta: ?[]const u8 = null,
        /// Set when a streamed tool_calls fragment includes a function name.
        tool_name: ?[]const u8 = null,
        /// Incremental `function.arguments` fragment (may be partial JSON).
        tool_arguments_delta: ?[]const u8 = null,
        done: bool = false,
    };
    pub const OnDelta = *const fn (*anyopaque, StreamDelta) anyerror!void;

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

    pub fn enableRateLimit(self: *AiProvider, io: std.Io, tokens_per_sec: u32) !void {
        const limiter = try @import("../resilience/RateLimiter.zig").RateLimiter.init(
            self.allocator,
            "ai_provider",
            tokens_per_sec,
            tokens_per_sec,
        );
        self.rate_limiter = .{ .limiter = limiter, .io = io, .mutex = std.Io.Mutex.init };
    }

    /// Bind a key pool and the key currently leased from it. `chat`/`chatWith`
    /// will report failures to the pool and, for key-retryable statuses,
    /// rotate to a fresh key and retry once.
    pub fn bindKeyPool(self: *AiProvider, io: std.Io, pool: *key_pool.KeyPool, key_index: usize) void {
        self.key_pool = pool;
        self.key_index = key_index;
        self.pool_io = io;
    }

    /// The key index currently serving this provider (may differ from the
    /// original lease after an auto-rotation inside `chatWith`).
    pub fn currentKeyIndex(self: *const AiProvider) ?usize {
        return self.key_index;
    }

    /// Report success for the key that actually served the request. Prefer
    /// this over `mgr.onSuccess(lease)` when the provider may have rotated
    /// keys internally — the lease would reset the failed key.
    pub fn reportSuccess(self: *AiProvider) void {
        if (self.key_pool) |pool| {
            if (self.pool_io) |pio| {
                if (self.key_index) |idx| pool.onSuccess(pio, idx);
            }
        }
    }

    /// Report a failure for the key that actually served the request.
    pub fn reportError(self: *AiProvider, kind: key_pool.KeyErrorKind) void {
        if (self.key_pool) |pool| {
            if (self.pool_io) |pio| {
                if (self.key_index) |idx| pool.onError(pio, idx, kind);
            }
        }
    }

    pub fn deinit(self: *AiProvider) void {
        if (self.rate_limiter) |*rl| {
            rl.limiter.deinit();
        }
        self.* = undefined;
    }

    /// Free owned fields of a ChatResponse from `chat` / `chatWith` / `chatStream`.
    pub fn freeResponse(self: *AiProvider, resp: *ChatResponse) void {
        if (resp.content.len > 0) self.allocator.free(resp.content);
        if (resp.reasoning_content.len > 0) self.allocator.free(resp.reasoning_content);
        if (resp.model.len > 0) self.allocator.free(resp.model);
        for (resp.tool_calls) |tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.name);
            self.allocator.free(tc.arguments);
        }
        if (resp.tool_calls.len > 0) self.allocator.free(resp.tool_calls);
        resp.* = .{};
    }

    pub fn chat(self: *AiProvider, messages: []const ChatMsg) !ChatResponse {
        return self.chatWith(messages, .{});
    }

    pub fn chatWith(self: *AiProvider, messages: []const ChatMsg, opts: ChatOpts) !ChatResponse {
        if (self.rate_limiter) |*rl| {
            rl.mutex.lock(rl.io) catch return error.RateLimitLockFailed;
            defer rl.mutex.unlock(rl.io);
            if (!rl.limiter.tryAcquire()) {
                _ = self.metrics.rate_limited_count.fetchAdd(1, .monotonic);
                return error.RateLimited;
            }
        }
        return self.chatWithInner(messages, opts);
    }

    /// No rate-limit acquire — internal path shared by `chatWith` (called
    /// after the acquire above) and `chatStream`'s buffered fallback, so a
    /// failed stream doesn't consume a second quota.
    fn chatWithInner(self: *AiProvider, messages: []const ChatMsg, opts: ChatOpts) !ChatResponse {
        // Key-rotation retry loop: on a key-retryable failure (401/403/402/429)
        // swap `api_key` to the pool's next healthy key and retry once.
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const body = try self.buildRequestBody(messages, opts);
            defer self.allocator.free(body);

            var req = http_client.HttpClient.HttpRequest.init(self.allocator, "POST", self.endpoint);
            defer req.deinit();
            try req.setHeader("Content-Type", "application/json");
            try req.setHeader("Authorization", self.api_key);
            try req.setBody(body);

            var http_resp = self.http.request(req) catch |err| {
                _ = self.metrics.error_count.fetchAdd(1, .monotonic);
                if (self.key_pool != null) self.reportError(.network);
                return mapProviderTransportError(err);
            };
            defer http_resp.deinit();

            _ = self.metrics.total_requests.fetchAdd(1, .monotonic);

            if (!http_resp.isSuccess()) {
                _ = self.metrics.error_count.fetchAdd(1, .monotonic);
                const kind = key_pool.KeyErrorKind.fromHttpStatus(http_resp.status_code);
                if (self.key_pool) |pool| {
                    const pio = self.pool_io orelse return mapHttpStatus(http_resp.status_code);
                    if (self.key_index) |idx| pool.onError(pio, idx, kind);
                    if (attempt == 0 and kind.isKeyRetryable()) {
                        if (try pool.acquire(pio)) |lease| {
                            self.api_key = lease.key;
                            self.key_index = lease.key_index;
                            continue; // retry once with the rotated key
                        }
                    }
                }
                return mapHttpStatus(http_resp.status_code);
            }

            const parsed = try self.parseResponse(http_resp.body);
            if (parsed.tool_calls.len > 0) _ = self.metrics.tool_call_responses.fetchAdd(1, .monotonic);
            return parsed;
        }
    }

    /// Stream chat completions (`stream:true`) via HttpClient.requestStream + SSE `data:` lines.
    /// Falls back to buffered `chatWith` if the transport fails before any delta.
    pub fn chatStream(
        self: *AiProvider,
        messages: []const ChatMsg,
        opts: ChatOpts,
        cb_ctx: *anyopaque,
        on_delta: OnDelta,
    ) !ChatResponse {
        if (self.rate_limiter) |*rl| {
            rl.mutex.lock(rl.io) catch return error.RateLimitLockFailed;
            defer rl.mutex.unlock(rl.io);
            if (!rl.limiter.tryAcquire()) {
                _ = self.metrics.rate_limited_count.fetchAdd(1, .monotonic);
                return error.RateLimited;
            }
        }

        var o = opts;
        o.stream = true;
        const body = try self.buildRequestBody(messages, o);
        defer self.allocator.free(body);

        var req = http_client.HttpClient.HttpRequest.init(self.allocator, "POST", self.endpoint);
        defer req.deinit();
        try req.setHeader("Content-Type", "application/json");
        try req.setHeader("Accept", "text/event-stream");
        try req.setHeader("Authorization", self.api_key);
        try req.setBody(body);

        var acc = StreamAccum.init(self.allocator, cb_ctx, on_delta);
        defer acc.deinit();

        var http_resp = self.http.requestStream(req, &acc, StreamAccum.onChunk) catch {
            // Transport failed before useful stream — buffered fallback (ignore transport err kind).
            if (self.key_pool) |pool| {
                if (self.pool_io) |pio| {
                    if (self.key_index) |idx| pool.onError(pio, idx, .network);
                }
            }
            o.stream = false;
            var resp = try self.chatWithInner(messages, o);
            errdefer self.freeResponse(&resp);
            if (resp.reasoning_content.len > 0) {
                try on_delta(cb_ctx, .{ .reasoning_delta = resp.reasoning_content });
            }
            if (resp.content.len > 0) {
                try on_delta(cb_ctx, .{ .content_delta = resp.content });
            }
            for (resp.tool_calls) |tc| {
                try on_delta(cb_ctx, .{ .tool_name = tc.name, .tool_arguments_delta = tc.arguments });
            }
            try on_delta(cb_ctx, .{ .done = true });
            return resp;
        };
        defer http_resp.deinit();

        _ = self.metrics.total_requests.fetchAdd(1, .monotonic);
        if (!http_resp.isSuccess()) {
            _ = self.metrics.error_count.fetchAdd(1, .monotonic);
            if (self.key_pool) |pool| {
                if (self.pool_io) |pio| {
                    if (self.key_index) |idx| {
                        pool.onError(pio, idx, key_pool.KeyErrorKind.fromHttpStatus(http_resp.status_code));
                    }
                }
            }
            return mapHttpStatus(http_resp.status_code);
        }

        try acc.flush();
        if (!acc.saw_done) {
            try on_delta(cb_ctx, .{ .done = true });
        }

        const content = try self.allocator.dupe(u8, acc.content.items);
        errdefer self.allocator.free(content);
        const reasoning = try self.allocator.dupe(u8, acc.reasoning.items);
        errdefer self.allocator.free(reasoning);
        const model = try self.allocator.dupe(u8, acc.model.items);
        errdefer self.allocator.free(model);
        const tool_calls = try acc.takeToolCalls(self.allocator);
        if (tool_calls.len > 0) _ = self.metrics.tool_call_responses.fetchAdd(1, .monotonic);
        return .{
            .content = content,
            .reasoning_content = reasoning,
            .model = model,
            .role = "assistant",
            .tool_calls = tool_calls,
            .prompt_tokens = acc.prompt_tokens,
            .completion_tokens = acc.completion_tokens,
        };
    }

    /// Extract `choices[0].delta.content` from one OpenAI SSE JSON payload (no `data:` prefix).
    pub fn extractStreamDeltaContent(allocator: std.mem.Allocator, json: []const u8) !?[]const u8 {
        return extractStreamDeltaStringField(allocator, json, "content");
    }

    /// Extract `choices[0].delta.reasoning_content` from one SSE payload
    /// (reasoning models only; null when absent).
    pub fn extractStreamDeltaReasoning(allocator: std.mem.Allocator, json: []const u8) !?[]const u8 {
        return extractStreamDeltaStringField(allocator, json, "reasoning_content");
    }

    /// Shared `choices[0].delta.<field>` string extractor (caller frees).
    fn extractStreamDeltaStringField(allocator: std.mem.Allocator, json: []const u8, field: []const u8) !?[]const u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const choices = parsed.value.object.get("choices") orelse return null;
        if (choices != .array or choices.array.items.len == 0) return null;
        const c0 = choices.array.items[0];
        if (c0 != .object) return null;
        const delta = c0.object.get("delta") orelse return null;
        if (delta != .object) return null;
        const content = delta.object.get(field) orelse return null;
        return switch (content) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        };
    }

    /// One streamed tool_calls fragment (`choices[0].delta.tool_calls[i]`).
    pub const StreamToolCallDelta = struct {
        index: usize = 0,
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        arguments: ?[]const u8 = null,

        pub fn deinit(self: StreamToolCallDelta, allocator: std.mem.Allocator) void {
            if (self.id) |s| allocator.free(s);
            if (self.name) |s| allocator.free(s);
            if (self.arguments) |s| allocator.free(s);
        }
    };

    /// Extract streamed `delta.tool_calls` fragments (caller frees each via `deinit`).
    pub fn extractStreamToolCallDeltas(allocator: std.mem.Allocator, json: []const u8) ![]StreamToolCallDelta {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return &.{};
        defer parsed.deinit();
        if (parsed.value != .object) return &.{};
        const choices = parsed.value.object.get("choices") orelse return &.{};
        if (choices != .array or choices.array.items.len == 0) return &.{};
        const c0 = choices.array.items[0];
        if (c0 != .object) return &.{};
        const delta = c0.object.get("delta") orelse return &.{};
        if (delta != .object) return &.{};
        const tcs = delta.object.get("tool_calls") orelse return &.{};
        if (tcs != .array or tcs.array.items.len == 0) return &.{};

        var list = try allocator.alloc(StreamToolCallDelta, tcs.array.items.len);
        var n: usize = 0;
        errdefer {
            for (list[0..n]) |d| d.deinit(allocator);
            allocator.free(list);
        }
        for (tcs.array.items) |item| {
            if (item != .object) continue;
            var d: StreamToolCallDelta = .{};
            if (item.object.get("index")) |idx| {
                d.index = switch (idx) {
                    .integer => |i| if (i < 0) 0 else @intCast(i),
                    else => 0,
                };
            }
            if (item.object.get("id")) |idv| {
                if (idv == .string) d.id = try allocator.dupe(u8, idv.string);
            }
            if (item.object.get("function")) |fnv| {
                if (fnv == .object) {
                    if (fnv.object.get("name")) |nv| {
                        if (nv == .string) d.name = try allocator.dupe(u8, nv.string);
                    }
                    if (fnv.object.get("arguments")) |av| {
                        if (av == .string) d.arguments = try allocator.dupe(u8, av.string);
                    }
                }
            }
            list[n] = d;
            n += 1;
        }
        if (n == 0) {
            allocator.free(list);
            return &.{};
        }
        if (n < list.len) list = try allocator.realloc(list, n);
        return list;
    }

    pub fn buildRequestBody(self: *AiProvider, messages: []const ChatMsg, opts: ChatOpts) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        const a = self.allocator;

        try buf.appendSlice(a, "{\"model\":\"");
        try escapeJson(a, &buf, self.model);
        try buf.appendSlice(a, "\",\"messages\":[");
        for (messages, 0..) |m, i| {
            if (i > 0) try buf.appendSlice(a, ",");
            try buf.appendSlice(a, "{\"role\":\"");
            try buf.appendSlice(a, m.role);
            try buf.appendSlice(a, "\"");
            if (m.tool_call_id) |tid| {
                try buf.appendSlice(a, ",\"tool_call_id\":\"");
                try escapeJson(a, &buf, tid);
                try buf.appendSlice(a, "\"");
            }
            if (m.name) |n| {
                try buf.appendSlice(a, ",\"name\":\"");
                try escapeJson(a, &buf, n);
                try buf.appendSlice(a, "\"");
            }
            try buf.appendSlice(a, ",\"content\":\"");
            try escapeJson(a, &buf, m.content);
            try buf.appendSlice(a, "\"");
            if (m.tool_calls.len > 0) {
                try buf.appendSlice(a, ",\"tool_calls\":[");
                for (m.tool_calls, 0..) |tc, ti| {
                    if (ti > 0) try buf.appendSlice(a, ",");
                    try buf.appendSlice(a, "{\"id\":\"");
                    try escapeJson(a, &buf, tc.id);
                    try buf.appendSlice(a, "\",\"type\":\"function\",\"function\":{\"name\":\"");
                    try escapeJson(a, &buf, tc.name);
                    try buf.appendSlice(a, "\",\"arguments\":\"");
                    try escapeJson(a, &buf, tc.arguments);
                    try buf.appendSlice(a, "\"}}");
                }
                try buf.appendSlice(a, "]");
            }
            try buf.appendSlice(a, "}");
        }
        try buf.appendSlice(a, "]");
        if (opts.tools_json) |tools| {
            try buf.appendSlice(a, ",\"tools\":");
            try buf.appendSlice(a, tools);
        }
        try buf.appendSlice(a, ",\"max_tokens\":");
        try buf.print(a, "{d}", .{self.max_output_tokens});
        try buf.appendSlice(a, ",\"temperature\":");
        try buf.print(a, "{d}", .{self.temperature});
        if (opts.stream) {
            try buf.appendSlice(a, ",\"stream\":true}");
        } else {
            try buf.appendSlice(a, ",\"stream\":false}");
        }
        return try buf.toOwnedSlice(a);
    }

    pub fn parseResponse(self: *AiProvider, body: []const u8) !ChatResponse {
        var resp = ChatResponse{};

        // Prefer structured JSON parse for tool_calls.
        if (std.json.parseFromSlice(std.json.Value, self.allocator, body, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                try self.fillFromJson(&resp, parsed.value.object);
                _ = self.metrics.total_prompt_tokens.fetchAdd(resp.prompt_tokens, .monotonic);
                _ = self.metrics.total_completion_tokens.fetchAdd(resp.completion_tokens, .monotonic);
                _ = self.metrics.cache_hit_tokens.fetchAdd(resp.cache_hit_tokens, .monotonic);
                _ = self.metrics.cache_miss_tokens.fetchAdd(resp.cache_miss_tokens, .monotonic);
                return resp;
            }
        } else |err| {
            std.log.warn("[AiProvider] response JSON parse failed, falling back to content scrape: {}", .{err});
        }

        // Fallback: content string scrape
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
        if (resp.content.len == 0) resp.content = try self.allocator.dupe(u8, "");

        resp.prompt_tokens = extractIntField(body, "\"prompt_tokens\":") orelse 0;
        resp.completion_tokens = extractIntField(body, "\"completion_tokens\":") orelse 0;
        resp.cache_hit_tokens = extractIntField(body, "\"prompt_cache_hit_tokens\":") orelse 0;
        resp.cache_miss_tokens = extractIntField(body, "\"prompt_cache_miss_tokens\":") orelse 0;

        _ = self.metrics.total_prompt_tokens.fetchAdd(resp.prompt_tokens, .monotonic);
        _ = self.metrics.total_completion_tokens.fetchAdd(resp.completion_tokens, .monotonic);
        _ = self.metrics.cache_hit_tokens.fetchAdd(resp.cache_hit_tokens, .monotonic);
        _ = self.metrics.cache_miss_tokens.fetchAdd(resp.cache_miss_tokens, .monotonic);
        return resp;
    }

    fn fillFromJson(self: *AiProvider, resp: *ChatResponse, root: std.json.ObjectMap) !void {
        if (root.get("usage")) |usage_v| {
            if (usage_v == .object) {
                const u = usage_v.object;
                resp.prompt_tokens = jsonInt(u.get("prompt_tokens"));
                resp.completion_tokens = jsonInt(u.get("completion_tokens"));
                resp.cache_hit_tokens = jsonInt(u.get("prompt_cache_hit_tokens"));
                resp.cache_miss_tokens = jsonInt(u.get("prompt_cache_miss_tokens"));
            }
        }
        if (root.get("model")) |m| {
            // dupe: the parsed JSON arena is freed before the response is used.
            if (m == .string) resp.model = try self.allocator.dupe(u8, m.string);
        }
        const choices = root.get("choices") orelse {
            resp.content = try self.allocator.dupe(u8, "");
            return;
        };
        if (choices != .array or choices.array.items.len == 0) {
            resp.content = try self.allocator.dupe(u8, "");
            return;
        }
        const choice0 = choices.array.items[0];
        if (choice0 != .object) {
            resp.content = try self.allocator.dupe(u8, "");
            return;
        }
        const msg = choice0.object.get("message") orelse {
            resp.content = try self.allocator.dupe(u8, "");
            return;
        };
        if (msg != .object) {
            resp.content = try self.allocator.dupe(u8, "");
            return;
        }
        if (msg.object.get("content")) |c| {
            switch (c) {
                .string => |s| resp.content = try self.allocator.dupe(u8, s),
                .null => resp.content = try self.allocator.dupe(u8, ""),
                else => resp.content = try self.allocator.dupe(u8, ""),
            }
        } else {
            resp.content = try self.allocator.dupe(u8, "");
        }
        // Reasoning models (DeepSeek-R1, Qwen, …) put the thinking chain in
        // `message.reasoning_content`. Mirror the content handling exactly.
        const reasoning = try readMsgStringField(msg.object, "reasoning_content", self.allocator);
        resp.reasoning_content = reasoning;
        if (msg.object.get("tool_calls")) |tcs| {
            if (tcs == .array and tcs.array.items.len > 0) {
                var list = try self.allocator.alloc(ToolCall, tcs.array.items.len);
                var n: usize = 0;
                errdefer {
                    for (list[0..n]) |tc| {
                        self.allocator.free(tc.id);
                        self.allocator.free(tc.name);
                        self.allocator.free(tc.arguments);
                    }
                    self.allocator.free(list);
                }
                for (tcs.array.items) |item| {
                    if (item != .object) continue;
                    const id = if (item.object.get("id")) |v| switch (v) {
                        .string => |s| s,
                        else => "",
                    } else "";
                    const fn_obj = item.object.get("function") orelse continue;
                    if (fn_obj != .object) continue;
                    const name = if (fn_obj.object.get("name")) |v| switch (v) {
                        .string => |s| s,
                        else => continue,
                    } else continue;
                    const args = if (fn_obj.object.get("arguments")) |v| switch (v) {
                        .string => |s| s,
                        else => "{}",
                    } else "{}";
                    list[n] = .{
                        .id = try self.allocator.dupe(u8, id),
                        .name = try self.allocator.dupe(u8, name),
                        .arguments = try self.allocator.dupe(u8, args),
                    };
                    n += 1;
                }
                if (n == 0) {
                    self.allocator.free(list);
                } else if (n < list.len) {
                    resp.tool_calls = try self.allocator.realloc(list, n);
                } else {
                    resp.tool_calls = list;
                }
            }
        }
    }

    /// Read a string field from an assistant message object, duplicating it
    /// into `allocator`; missing / null / non-string → owned `""` (no error).
    fn readMsgStringField(msg: std.json.ObjectMap, key: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const v = msg.get(key) orelse return try allocator.dupe(u8, "");
        return switch (v) {
            .string => |s| try allocator.dupe(u8, s),
            else => try allocator.dupe(u8, ""),
        };
    }

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
        count += 1;

        var msgs = try allocator.alloc(ChatMsg, count);
        var idx: usize = 0;
        if (system_prompt) |sp| {
            msgs[idx] = .{ .role = "system", .content = sp };
            idx += 1;
        }
        for (memories) |mem| {
            msgs[idx] = .{ .role = "system", .content = mem };
            idx += 1;
        }
        for (history) |h| {
            msgs[idx] = h;
            idx += 1;
        }
        msgs[idx] = .{ .role = "user", .content = user_msg };
        return msgs;
    }

    pub fn countTokens(_: *AiProvider, messages: []const ChatMsg) usize {
        return tokenizer.estimateMessages(messages);
    }

    pub fn fitsBudget(self: *AiProvider, messages: []const ChatMsg, context_limit: usize) bool {
        const est = tokenizer.estimateMessages(messages);
        return est + self.max_output_tokens < (context_limit * 4 / 5);
    }

    pub fn cacheHitRatio(self: *AiProvider) f64 {
        const total = self.metrics.cache_hit_tokens.load(.monotonic) + self.metrics.cache_miss_tokens.load(.monotonic);
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.metrics.cache_hit_tokens.load(.monotonic))) / @as(f64, @floatFromInt(total));
    }
};

const StreamAccum = struct {
    allocator: std.mem.Allocator,
    cb_ctx: *anyopaque,
    on_delta: AiProvider.OnDelta,
    carry: std.ArrayList(u8),
    content: std.ArrayList(u8),
    reasoning: std.ArrayList(u8),
    model: std.ArrayList(u8),
    pending_tools: std.ArrayList(PendingTool),
    saw_done: bool = false,
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,

    const PendingTool = struct {
        index: usize,
        id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,
        arguments: std.ArrayList(u8) = .empty,

        fn deinit(self: *PendingTool, allocator: std.mem.Allocator) void {
            self.id.deinit(allocator);
            self.name.deinit(allocator);
            self.arguments.deinit(allocator);
        }
    };

    fn init(allocator: std.mem.Allocator, cb_ctx: *anyopaque, on_delta: AiProvider.OnDelta) StreamAccum {
        return .{
            .allocator = allocator,
            .cb_ctx = cb_ctx,
            .on_delta = on_delta,
            .carry = .empty,
            .content = .empty,
            .reasoning = .empty,
            .model = .empty,
            .pending_tools = .empty,
        };
    }

    fn deinit(self: *StreamAccum) void {
        self.carry.deinit(self.allocator);
        self.content.deinit(self.allocator);
        self.reasoning.deinit(self.allocator);
        self.model.deinit(self.allocator);
        for (self.pending_tools.items) |*t| t.deinit(self.allocator);
        self.pending_tools.deinit(self.allocator);
    }

    fn onChunk(ctx: *anyopaque, chunk: []const u8) anyerror!void {
        const self: *StreamAccum = @ptrCast(@alignCast(ctx));
        try self.carry.appendSlice(self.allocator, chunk);
        try self.drainLines(false);
    }

    fn flush(self: *StreamAccum) !void {
        try self.drainLines(true);
    }

    fn drainLines(self: *StreamAccum, final: bool) !void {
        while (true) {
            const nl = std.mem.indexOfScalar(u8, self.carry.items, '\n') orelse {
                if (final and self.carry.items.len > 0) {
                    try self.handleLine(std.mem.trim(u8, self.carry.items, "\r"));
                    self.carry.clearRetainingCapacity();
                }
                return;
            };
            var line = self.carry.items[0..nl];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            try self.handleLine(line);
            const rest = self.carry.items.len - (nl + 1);
            std.mem.copyForwards(u8, self.carry.items[0..rest], self.carry.items[nl + 1 ..]);
            try self.carry.resize(self.allocator, rest);
        }
    }

    fn handleLine(self: *StreamAccum, line: []const u8) !void {
        if (line.len == 0) return;
        if (!std.mem.startsWith(u8, line, "data:")) return;
        const payload = std.mem.trim(u8, line["data:".len..], " \t");
        if (std.mem.eql(u8, payload, "[DONE]")) {
            self.saw_done = true;
            try self.on_delta(self.cb_ctx, .{ .done = true });
            return;
        }
        if (extractIntField(payload, "\"prompt_tokens\":")) |n| self.prompt_tokens = n;
        if (extractIntField(payload, "\"completion_tokens\":")) |n| self.completion_tokens = n;
        if (extractStringField(payload, "\"model\":")) |m| {
            self.model.clearRetainingCapacity();
            try self.model.appendSlice(self.allocator, m);
        }

        const delta = try AiProvider.extractStreamDeltaContent(self.allocator, payload);
        if (delta) |d| {
            defer self.allocator.free(d);
            if (d.len > 0) {
                try self.content.appendSlice(self.allocator, d);
                try self.on_delta(self.cb_ctx, .{ .content_delta = d });
            }
        }

        const rdelta = try AiProvider.extractStreamDeltaReasoning(self.allocator, payload);
        if (rdelta) |d| {
            defer self.allocator.free(d);
            if (d.len > 0) {
                try self.reasoning.appendSlice(self.allocator, d);
                try self.on_delta(self.cb_ctx, .{ .reasoning_delta = d });
            }
        }

        const tcds = try AiProvider.extractStreamToolCallDeltas(self.allocator, payload);
        defer {
            for (tcds) |d| d.deinit(self.allocator);
            if (tcds.len > 0) self.allocator.free(tcds);
        }
        for (tcds) |d| {
            try self.mergeToolDelta(d);
            try self.on_delta(self.cb_ctx, .{
                .tool_name = d.name,
                .tool_arguments_delta = d.arguments,
            });
        }
    }

    fn mergeToolDelta(self: *StreamAccum, d: AiProvider.StreamToolCallDelta) !void {
        const slot = try self.ensurePending(d.index);
        if (d.id) |id| {
            slot.id.clearRetainingCapacity();
            try slot.id.appendSlice(self.allocator, id);
        }
        if (d.name) |name| {
            try slot.name.appendSlice(self.allocator, name);
        }
        if (d.arguments) |args| {
            try slot.arguments.appendSlice(self.allocator, args);
        }
    }

    fn ensurePending(self: *StreamAccum, index: usize) !*PendingTool {
        for (self.pending_tools.items) |*t| {
            if (t.index == index) return t;
        }
        try self.pending_tools.append(self.allocator, .{ .index = index });
        return &self.pending_tools.items[self.pending_tools.items.len - 1];
    }

    fn takeToolCalls(self: *StreamAccum, allocator: std.mem.Allocator) ![]AiProvider.ToolCall {
        if (self.pending_tools.items.len == 0) return &.{};
        const out = try allocator.alloc(AiProvider.ToolCall, self.pending_tools.items.len);
        errdefer allocator.free(out);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |tc| {
                allocator.free(tc.id);
                allocator.free(tc.name);
                allocator.free(tc.arguments);
            }
        }
        for (self.pending_tools.items) |*t| {
            out[n] = .{
                .id = try allocator.dupe(u8, t.id.items),
                .name = try allocator.dupe(u8, t.name.items),
                .arguments = try allocator.dupe(u8, t.arguments.items),
            };
            n += 1;
        }
        for (self.pending_tools.items) |*t| t.deinit(self.allocator);
        self.pending_tools.clearRetainingCapacity();
        return out;
    }
};

fn mapHttpStatus(status: u16) anyerror {
    return switch (status) {
        401, 403 => error.AuthError,
        429 => error.RateLimited,
        500, 502, 503, 504 => error.UpstreamError,
        else => error.ProviderError,
    };
}

fn mapProviderTransportError(err: anyerror) anyerror {
    return switch (err) {
        error.TlsHandshakeFailed => error.TlsHandshakeFailed,
        error.DnsFailed => error.DnsFailed,
        error.ConnectionRefused => error.ConnectionRefused,
        error.NetworkUnreachable => error.NetworkUnreachable,
        error.Timeout => error.Timeout,
        error.RateLimited => error.RateLimited,
        else => error.ConnectionError,
    };
}

fn jsonInt(v: ?std.json.Value) usize {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        .float => |f| if (f < 0) 0 else @intFromFloat(f),
        else => 0,
    };
}

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

/// Extract a JSON string field value, e.g. `"model":"deepseek-chat"`.
/// Returns the value (not owned) or null when absent.
fn extractStringField(body: []const u8, field: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, body, field) orelse return null;
    var i = start + field.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len or body[i] != '"') return null;
    const vs = i + 1;
    const end = std.mem.indexOfScalarPos(u8, body, vs, '"') orelse return null;
    return body[vs..end];
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
    try std.testing.expectEqualStrings("new question", msgs[4].content);
}

test "AiProvider buildRequestBody includes tools" {
    const a = std.testing.allocator;
    var http = http_client.HttpClient.init(a, std.testing.io, 1, 5000);
    defer http.deinit();
    var p = AiProvider.init(a, &http, "https://api.test/v1", "Bearer sk-xxx", "deepseek-v4-flash");

    const msgs = &[_]AiProvider.ChatMsg{
        .{ .role = "user", .content = "Hi" },
    };
    const tools =
        \\[{"type":"function","function":{"name":"ping","description":"pong","parameters":{"type":"object","properties":{},"required":[]}}}]
    ;
    const body = try p.buildRequestBody(msgs, .{ .tools_json = tools });
    defer a.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"ping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
}

test "AiProvider parseResponse tool_calls" {
    const a = std.testing.allocator;
    var http = http_client.HttpClient.init(a, std.testing.io, 1, 5000);
    defer http.deinit();
    var p = AiProvider.init(a, &http, "https://api.test/v1", "sk-xxx", "deepseek-v4-flash");

    const body =
        \\{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"x\"}"}}]}}],"usage":{"prompt_tokens":10,"completion_tokens":2}}
    ;
    var resp = try p.parseResponse(body);
    defer p.freeResponse(&resp);

    try std.testing.expectEqual(@as(usize, 1), resp.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", resp.tool_calls[0].id);
    try std.testing.expectEqualStrings("lookup", resp.tool_calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, resp.tool_calls[0].arguments, "q") != null);
}

test "AiProvider parseResponse content" {
    const a = std.testing.allocator;
    var http = http_client.HttpClient.init(a, std.testing.io, 1, 5000);
    defer http.deinit();
    var p = AiProvider.init(a, &http, "https://api.test/v1", "sk-xxx", "deepseek-v4-flash");

    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"Hello!"}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_cache_hit_tokens":8,"prompt_cache_miss_tokens":2},"model":"deepseek-v4-flash"}
    ;
    var resp = try p.parseResponse(body);
    defer p.freeResponse(&resp);

    try std.testing.expectEqualStrings("Hello!", resp.content);
    try std.testing.expectEqual(@as(usize, 10), resp.prompt_tokens);
    // Non-reasoning model: reasoning_content is empty, not garbage.
    try std.testing.expectEqual(@as(usize, 0), resp.reasoning_content.len);
}

test "AiProvider parseResponse reasoning_content" {
    const a = std.testing.allocator;
    var http = http_client.HttpClient.init(a, std.testing.io, 1, 5000);
    defer http.deinit();
    var p = AiProvider.init(a, &http, "https://api.test/v1", "sk-xxx", "deepseek-r1");

    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"Final answer","reasoning_content":"Let me think step by step"}}],"usage":{"prompt_tokens":12,"completion_tokens":4}}
    ;
    var resp = try p.parseResponse(body);
    defer p.freeResponse(&resp);

    try std.testing.expectEqualStrings("Final answer", resp.content);
    try std.testing.expectEqualStrings("Let me think step by step", resp.reasoning_content);
}

test "AiProvider extractStreamDeltaReasoning" {
    const a = std.testing.allocator;
    const json =
        \\{"choices":[{"delta":{"reasoning_content":"chain of thought"},"index":0}]}
    ;
    const d = try AiProvider.extractStreamDeltaReasoning(a, json);
    try std.testing.expect(d != null);
    defer a.free(d.?);
    try std.testing.expectEqualStrings("chain of thought", d.?);

    // Absent field → null (non-reasoning stream deltas).
    const plain =
        \\{"choices":[{"delta":{"content":"Hi"}}]}
    ;
    try std.testing.expect((try AiProvider.extractStreamDeltaReasoning(a, plain)) == null);
}

test "AiProvider StreamAccum accumulates reasoning_content" {
    const a = std.testing.allocator;
    const Ctx = struct {
        parts: std.ArrayList([]const u8),
        allocator: std.mem.Allocator,

        fn onDelta(ctx: *anyopaque, d: AiProvider.StreamDelta) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (d.reasoning_delta) |c| {
                try self.parts.append(self.allocator, try self.allocator.dupe(u8, c));
            }
        }
    };
    var ctx = Ctx{ .parts = .empty, .allocator = a };
    defer {
        for (ctx.parts.items) |p| a.free(p);
        ctx.parts.deinit(a);
    }

    var acc = StreamAccum.init(a, &ctx, Ctx.onDelta);
    defer acc.deinit();

    const chunk1 = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Let me\"}}]}\n";
    const chunk2 = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\" think\"}}]}\ndata: [DONE]\n";
    try StreamAccum.onChunk(&acc, chunk1);
    try StreamAccum.onChunk(&acc, chunk2);
    try acc.flush();

    try std.testing.expectEqual(@as(usize, 2), ctx.parts.items.len);
    try std.testing.expectEqualStrings("Let me", ctx.parts.items[0]);
    try std.testing.expectEqualStrings(" think", ctx.parts.items[1]);
    try std.testing.expectEqualStrings("Let me think", acc.reasoning.items);
    // Non-reasoning chunks leave reasoning empty.
    try std.testing.expectEqualStrings("", acc.content.items);
}

test "AiProvider countTokens and fitsBudget" {
    const a = std.testing.allocator;
    var http = http_client.HttpClient.init(a, std.testing.io, 1, 5000);
    defer http.deinit();
    var p = AiProvider.init(a, &http, "https://api.test/v1", "sk-xxx", "deepseek-v4-flash");

    const msgs = &[_]AiProvider.ChatMsg{
        .{ .role = "system", .content = "You are helpful." },
        .{ .role = "user", .content = "Hello, how are you?" },
    };
    try std.testing.expect(p.countTokens(msgs) > 5);
    try std.testing.expect(p.fitsBudget(msgs, 128000));
}

test "AiProvider extractStreamDeltaContent" {
    const a = std.testing.allocator;
    const json =
        \\{"choices":[{"delta":{"content":"Hi"},"index":0}]}
    ;
    const d = try AiProvider.extractStreamDeltaContent(a, json);
    try std.testing.expect(d != null);
    defer a.free(d.?);
    try std.testing.expectEqualStrings("Hi", d.?);
}

test "AiProvider extractStreamToolCallDeltas accumulates" {
    const a = std.testing.allocator;
    const j1 =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"lookup","arguments":""}}]}}]}
    ;
    const j2 =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"q\":1}"}}]}}]}
    ;
    const d1 = try AiProvider.extractStreamToolCallDeltas(a, j1);
    defer {
        for (d1) |x| x.deinit(a);
        if (d1.len > 0) a.free(d1);
    }
    try std.testing.expectEqual(@as(usize, 1), d1.len);
    try std.testing.expectEqualStrings("lookup", d1[0].name.?);

    var acc = StreamAccum.init(a, undefined, struct {
        fn nop(_: *anyopaque, _: AiProvider.StreamDelta) anyerror!void {}
    }.nop);
    defer acc.deinit();
    try acc.mergeToolDelta(d1[0]);
    const d2 = try AiProvider.extractStreamToolCallDeltas(a, j2);
    defer {
        for (d2) |x| x.deinit(a);
        if (d2.len > 0) a.free(d2);
    }
    try acc.mergeToolDelta(d2[0]);
    const tcs = try acc.takeToolCalls(a);
    defer {
        for (tcs) |tc| {
            a.free(tc.id);
            a.free(tc.name);
            a.free(tc.arguments);
        }
        if (tcs.len > 0) a.free(tcs);
    }
    try std.testing.expectEqual(@as(usize, 1), tcs.len);
    try std.testing.expectEqualStrings("c1", tcs[0].id);
    try std.testing.expectEqualStrings("lookup", tcs[0].name);
    try std.testing.expectEqualStrings("{\"q\":1}", tcs[0].arguments);
}

test "AiProvider StreamAccum parses SSE lines" {
    const a = std.testing.allocator;
    const Ctx = struct {
        parts: std.ArrayList([]const u8),
        done: bool = false,
        allocator: std.mem.Allocator,

        fn onDelta(ctx: *anyopaque, d: AiProvider.StreamDelta) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (d.done) {
                self.done = true;
                return;
            }
            if (d.content_delta) |c| {
                try self.parts.append(self.allocator, try self.allocator.dupe(u8, c));
            }
        }
    };
    var ctx = Ctx{ .parts = .empty, .allocator = a };
    defer {
        for (ctx.parts.items) |p| a.free(p);
        ctx.parts.deinit(a);
    }

    var acc = StreamAccum.init(a, &ctx, Ctx.onDelta);
    defer acc.deinit();

    const chunk1 = "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n";
    const chunk2 = "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\ndata: [DONE]\n";
    try StreamAccum.onChunk(&acc, chunk1);
    try StreamAccum.onChunk(&acc, chunk2);
    try acc.flush();

    try std.testing.expect(ctx.done);
    try std.testing.expectEqual(@as(usize, 2), ctx.parts.items.len);
    try std.testing.expectEqualStrings("Hel", ctx.parts.items[0]);
    try std.testing.expectEqualStrings("lo", ctx.parts.items[1]);
    try std.testing.expectEqualStrings("Hello", acc.content.items);
}

test "AiProvider cacheHitRatio" {
    const a = std.testing.allocator;
    var http = http_client.HttpClient.init(a, std.testing.io, 1, 5000);
    defer http.deinit();
    var p = AiProvider.init(a, &http, "https://api.test/v1", "sk-xxx", "deepseek-v4-flash");
    p.metrics.cache_hit_tokens.store(80, .monotonic);
    p.metrics.cache_miss_tokens.store(20, .monotonic);
    const ratio = p.cacheHitRatio();
    try std.testing.expect(ratio >= 0.79 and ratio <= 0.81);
}

test "AiProvider metrics toPrometheusFormat" {
    const a = std.testing.allocator;
    var m = AiProvider.Metrics{ .total_requests = .init(3), .total_prompt_tokens = .init(10), .error_count = .init(1) };
    const out = try m.toPrometheusFormat(a, "main");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_ai_provider_requests_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "provider=\"main\"") != null);
}
