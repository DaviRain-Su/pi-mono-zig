const std = @import("std");
const ai = @import("../root.zig");

fn currentMs() i64 {
    const ts = std.posix.clock_gettime(std.os.linux.CLOCK.REALTIME) catch return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms);
}

fn extractAccountId(gpa: std.mem.Allocator, token: []const u8) ![]const u8 {
    const first_dot = std.mem.indexOfScalar(u8, token, '.');
    const second_dot = if (first_dot) |f| std.mem.indexOfScalar(u8, token[f + 1 ..], '.') else null;
    if (first_dot == null or second_dot == null) return error.InvalidToken;
    const payload_b64 = token[first_dot.? + 1 .. first_dot.? + 1 + second_dot.?];
    // base64url decode
    const decoder = std.base64.Base64Decoder.init(std.base64.standard_alphabet_chars, '=');
    const len = decoder.calcSizeForSlice(payload_b64) catch return error.InvalidBase64;
    const payload = try gpa.alloc(u8, len);
    defer gpa.free(payload);
    decoder.decode(payload, payload_b64) catch return error.InvalidBase64;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload, .{}) catch return error.InvalidJson;
    const auth_path = "https://api.openai.com/auth";
    if (parsed.value.object.get(auth_path)) |authv| {
        if (authv.object.get("chatgpt_account_id")) |av| {
            if (av == .string) {
                return try gpa.dupe(u8, av.string);
            }
        }
    }
    return error.MissingAccountId;
}

fn clampReasoningEffort(model_id: []const u8, effort: []const u8) []const u8 {
    const id = blk: {
        if (std.mem.indexOfScalar(u8, model_id, '/')) |i| {
            break :blk model_id[i + 1 ..];
        }
        break :blk model_id;
    };
    if ((std.mem.startsWith(u8, id, "gpt-5.2") or std.mem.startsWith(u8, id, "gpt-5.3") or std.mem.startsWith(u8, id, "gpt-5.4")) and std.mem.eql(u8, effort, "minimal")) {
        return "low";
    }
    if (std.mem.eql(u8, id, "gpt-5.1") and std.mem.eql(u8, effort, "xhigh")) {
        return "high";
    }
    if (std.mem.eql(u8, id, "gpt-5.1-codex-mini")) {
        if (std.mem.eql(u8, effort, "high") or std.mem.eql(u8, effort, "xhigh")) return "high";
        return "medium";
    }
    return effort;
}

fn resolveCodexUrl(base_url: ?[]const u8) []const u8 {
    const raw = base_url orelse "https://chatgpt.com/backend-api";
    var end = raw.len;
    while (end > 0 and raw[end - 1] == '/') end -= 1;
    const trimmed = raw[0..end];
    if (std.mem.endsWith(u8, trimmed, "/codex/responses")) return trimmed;
    if (std.mem.endsWith(u8, trimmed, "/codex")) return std.mem.concat(std.heap.page_allocator, u8, &.{ trimmed, "/responses" }) catch trimmed;
    return std.mem.concat(std.heap.page_allocator, u8, &.{ trimmed, "/codex/responses" }) catch trimmed;
}

fn isRetryableError(status: std.http.Status, error_text: []const u8) bool {
    const code = @intFromEnum(status);
    if (code == 429 or code == 500 or code == 502 or code == 503 or code == 504) return true;
    const lower = std.asciiLowerStringStack(error_text);
    return std.mem.indexOf(u8, lower, "rate_limit") != null or
        std.mem.indexOf(u8, lower, "overloaded") != null or
        std.mem.indexOf(u8, lower, "service_unavailable") != null or
        std.mem.indexOf(u8, lower, "upstream_connect") != null or
        std.mem.indexOf(u8, lower, "connection_refused") != null;
}

fn buildRequestBody(gpa: std.mem.Allocator, model: ai.Model, context: ai.Context, options: ?ai.StreamOptions) !std.json.Value {
    const input = try ai.openai_responses_provider.convertResponsesMessages(gpa, model, context);

    var obj = std.json.ObjectMap.init(gpa);
    try obj.put("model", .{ .string = model.id });
    try obj.put("store", .{ .bool = false });
    try obj.put("stream", .{ .bool = true });
    try obj.put("instructions", if (context.system_prompt) |sp| .{ .string = sp } else .{ .string = "" });
    try obj.put("input", input);
    try obj.put("tool_choice", .{ .string = "auto" });
    try obj.put("parallel_tool_calls", .{ .bool = true });

    const opts = options orelse ai.StreamOptions{};
    if (opts.temperature) |t| {
        try obj.put("temperature", .{ .float = t });
    }
    if (opts.session_id) |sid| {
        try obj.put("prompt_cache_key", .{ .string = sid });
    }

    var text_obj = std.json.ObjectMap.init(gpa);
    const verbosity: []const u8 = blk: {
        if (opts.headers) |hv| {
            if (hv.object.get("text_verbosity")) |tv| {
                if (tv == .string) break :blk tv.string;
            }
        }
        break :blk "medium";
    };
    try text_obj.put("verbosity", .{ .string = verbosity });
    try obj.put("text", .{ .object = text_obj });

    var include_arr = std.ArrayList(std.json.Value).init(gpa);
    try include_arr.append(.{ .string = "reasoning.encrypted_content" });
    try obj.put("include", .{ .array = .{ .items = include_arr, .capacity = 1 } });

    if (context.tools) |tools| {
        try obj.put("tools", try ai.openai_responses_provider.convertResponsesTools(gpa, tools));
    }

    if (opts.reasoning_effort) |effort| {
        var reasoning_obj = std.json.ObjectMap.init(gpa);
        try reasoning_obj.put("effort", .{ .string = clampReasoningEffort(model.id, effort) });
        try reasoning_obj.put("summary", .{ .string = opts.reasoning_summary orelse "auto" });
        try obj.put("reasoning", .{ .object = reasoning_obj });
    }

    return std.json.Value{ .object = obj };
}

fn getApiKey(options_api_key: ?[]const u8) ?[]const u8 {
    if (options_api_key) |k| return k;
    return std.process.getEnvVarOwned(std.heap.page_allocator, "OPENAI_CODEX_API_KEY") catch null;
}

fn normalizeCodexEvent(event: std.json.Value) std.json.Value {
    const event_type = if (event.object.get("type")) |tv| (if (tv == .string) tv.string else "") else "";
    if (std.mem.eql(u8, event_type, "response.done")) {
        _ = event.object.put("type", .{ .string = "response.completed" }) catch {};
        if (event.object.get("response")) |rv| {
            if (rv == .object) {
                _ = rv.object.put("status", .{ .string = "completed" }) catch {};
            }
        }
    } else if (std.mem.eql(u8, event_type, "response.incomplete")) {
        _ = event.object.put("type", .{ .string = "response.completed" }) catch {};
        if (event.object.get("response")) |rv| {
            if (rv == .object) {
                _ = rv.object.put("status", .{ .string = "incomplete" }) catch {};
            }
        }
    }
    return event;
}

pub fn streamOpenAICodexResponses(model: ai.Model, context: ai.Context, options: ?ai.StreamOptions) ai.AssistantMessageEventStream {
    const gpa = std.heap.page_allocator;
    var es = ai.createAssistantMessageEventStream(gpa) catch @panic("OOM");

    const output = ai.AssistantMessage{
        .role = "assistant",
        .content = &[_]ai.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = currentMs(),
    };

    const api_key = getApiKey(if (options) |o| o.base.api_key else null) orelse {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "No API key for provider";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return es;
    };

    const account_id = extractAccountId(gpa, api_key) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "Failed to extract accountId from token";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return es;
    };

    const thread = std.Thread.spawn(.{}, codexResponsesThread, .{ model, context, options, api_key, account_id, output, es }) catch |err| {
        gpa.free(account_id);
        var o = output;
        o.stop_reason = .err;
        o.error_message = @errorName(err);
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return es;
    };
    thread.detach();
    return es;
}

fn codexResponsesThread(model: ai.Model, context: ai.Context, options: ?ai.StreamOptions, api_key: []const u8, account_id: []const u8, output: ai.AssistantMessage, es: ai.AssistantMessageEventStream) void {
    const gpa = std.heap.page_allocator;
    defer gpa.free(account_id);
    const client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    const url = std.mem.concat(gpa, u8, &.{resolveCodexUrl(model.base_url)}) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "OOM";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };
    defer gpa.free(url);

    const body_value = buildRequestBody(gpa, model, context, options) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "Failed to build request body";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };

    var body_list = std.ArrayList(u8).init(gpa);
    defer body_list.deinit();
    std.json.stringify(body_value, .{}, body_list.writer()) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "Failed to serialize request";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };

    const auth_header = std.fmt.allocPrint(gpa, "Bearer {s}", .{api_key}) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "OOM";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };
    defer gpa.free(auth_header);

    var extra_headers = std.ArrayList(std.http.Client.Header).init(gpa);
    defer extra_headers.deinit();
    extra_headers.append(.{ .name = "Authorization", .value = auth_header }) catch {};
    extra_headers.append(.{ .name = "chatgpt-account-id", .value = account_id }) catch {};
    extra_headers.append(.{ .name = "OpenAI-Beta", .value = "responses=experimental" }) catch {};
    extra_headers.append(.{ .name = "accept", .value = "text/event-stream" }) catch {};
    extra_headers.append(.{ .name = "content-type", .value = "application/json" }) catch {};
    extra_headers.append(.{ .name = "originator", .value = "pi" }) catch {};
    extra_headers.append(.{ .name = "User-Agent", .value = "pi" }) catch {};

    // Merge model.headers
    if (model.headers) |mh| {
        var it = mh.object.iterator();
        while (it.next()) |entry| {
            const val = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
            extra_headers.append(.{ .name = entry.key_ptr.*, .value = val }) catch {};
        }
    }

    // Merge options.headers last
    if (options) |opts| {
        if (opts.headers) |oh| {
            var it = oh.object.iterator();
            while (it.next()) |entry| {
                const val = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
                extra_headers.append(.{ .name = entry.key_ptr.*, .value = val }) catch {};
            }
        }
    }

    var last_error: ?[]const u8 = null;
    var fetch_res: ?std.http.Client.FetchResult = null;

    for (0..4) |attempt| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const aa = arena.allocator();

        const res = client.fetch(aa, .{
            .location = .{ .url = url },
            .method = .POST,
            .extra_headers = extra_headers.items,
            .payload = body_list.items,
        }) catch |err| {
            last_error = std.fmt.allocPrint(gpa, "{s}", .{@errorName(err)}) catch "error";
            if (attempt < 3) {
                std.time.sleep(@as(u64, 1000) * std.time.ns_per_ms * (1 << @as(u6, @intCast(attempt))));
            }
            continue;
        };

        const status_code = @intFromEnum(res.status);
        if (status_code >= 200 and status_code < 300) {
            fetch_res = res;
            break;
        }

        var err_buf: [4096]u8 = undefined;
        const err_n = res.body.reader().read(&err_buf) catch 0;
        const err_text = if (err_n > 0) err_buf[0..err_n] else "HTTP error";
        last_error = std.fmt.allocPrint(gpa, "HTTP {d}: {s}", .{ status_code, extractErrorMessage(err_text) }) catch "HTTP error";

        if (isRetryableError(res.status, err_text) and attempt < 3) {
            std.time.sleep(@as(u64, 1000) * std.time.ns_per_ms * (1 << @as(u6, @intCast(attempt))));
            continue;
        }
        break;
    }

    const res = fetch_res orelse {
        var o = output;
        o.stop_reason = .err;
        o.error_message = last_error orelse "Failed after retries";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };

    es.push(.{ .start = .{ .partial = output } }) catch {
        es.end(null);
        return;
    };

    var buf: [4096]u8 = undefined;
    var reader = res.body.reader();
    var line_buf = std.ArrayList(u8).init(gpa);
    defer line_buf.deinit();

    while (true) {
        const n = reader.read(&buf) catch {
            var o = output;
            o.stop_reason = .err;
            o.error_message = "Read error";
            es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
            es.end(null);
            return;
        };
        if (n == 0) break;

        for (buf[0..n]) |byte| {
            if (byte == '\n') {
                const line = std.mem.trim(u8, line_buf.items, " \r\n");
                if (line.len > 0) {
                    if (ai.openai_responses_provider.parseSseLine(line)) |event| {
                        const normalized = normalizeCodexEvent(event);
                        ai.openai_responses_provider.processResponsesSseLine(gpa, std.json.Value{ .object = normalized.object }, &output, es, model);
                    }
                }
                line_buf.clearRetainingCapacity();
            } else {
                line_buf.append(byte) catch {};
            }
        }
    }

    es.push(.{ .done = .{ .reason = output.stop_reason, .message = output } }) catch {};
    es.end(null);
}

fn extractErrorMessage(error_text: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, error_text, .{}) catch return error_text;
    if (parsed.value.object.get("error")) |errv| {
        if (errv.object.get("message")) |mv| {
            if (mv == .string) return mv.string;
        }
    }
    return error_text;
}

pub fn streamSimpleOpenAICodexResponses(model: ai.Model, context: ai.Context, options: ?ai.types.SimpleStreamOptions) ai.AssistantMessageEventStream {
    const api_key = getApiKey(if (options) |o| o.base.api_key else null);
    const base = ai.simple_options.buildBaseOptions(model, options, api_key);
    const reasoning_effort = if (ai.supportsXhigh(model)) (if (options) |o| o.reasoning else null) else ai.simple_options.clampReasoning(if (options) |o| o.reasoning else null);

    var stream_opts = base;
    if (reasoning_effort) |re| {
        switch (re) {
            .minimal => stream_opts.reasoning_effort = "minimal",
            .low => stream_opts.reasoning_effort = "low",
            .medium => stream_opts.reasoning_effort = "medium",
            .high => stream_opts.reasoning_effort = "high",
            .xhigh => stream_opts.reasoning_effort = "xhigh",
        }
    }
    return streamOpenAICodexResponses(model, context, stream_opts);
}

pub fn registerOpenAICodexResponsesProvider() void {
    ai.registerApiProvider(.{
        .api = .{ .known = .openai_codex_responses },
        .stream = streamOpenAICodexResponses,
        .stream_simple = streamSimpleOpenAICodexResponses,
    });
}

test "openai_codex_responses compiles and registers" {
    registerOpenAICodexResponsesProvider();
}

test "buildRequestBody includes codex-specific fields" {
    const gpa = std.testing.allocator;
    const model = ai.Model{
        .id = "gpt-5.1-codex",
        .name = "Codex",
        .api = .{ .known = .openai_codex_responses },
        .provider = .{ .known = .openai },
        .max_tokens = 32000,
    };
    const context = ai.Context{
        .system_prompt = "You are a coding assistant.",
        .messages = &[_]ai.Message{ ai.Message{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } } },
    };
    const body = try buildRequestBody(gpa, model, context, .{ .temperature = 0.7, .max_tokens = 4096 });
    try std.testing.expectEqualStrings("gpt-5.1-codex", body.object.get("model").?.string);
    try std.testing.expect(body.object.get("parallel_tool_calls").?.bool == true);
    try std.testing.expectEqualStrings("auto", body.object.get("tool_choice").?.string);
    try std.testing.expect(body.object.get("text") != null);
}
