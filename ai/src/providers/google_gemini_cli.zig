const std = @import("std");
const ai = @import("../root.zig");
const gs = @import("google_shared.zig");

fn jsonStringifyValue(gpa: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var list = std.ArrayList(u8).init(gpa);
    defer list.deinit();
    try std.json.stringify(value, .{}, list.writer());
    return list.toOwnedSlice();
}

fn currentMs() i64 {
    const ts = std.posix.clock_gettime(std.os.linux.CLOCK.REALTIME) catch return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms);
}

fn isRetryableError(status: std.http.Status, error_text: []const u8) bool {
    const code = @intFromEnum(status);
    if (code == 429 or code == 500 or code == 502 or code == 503 or code == 504) return true;
    const lower = std.asciiLowerStringStack(error_text);
    return std.mem.indexOf(u8, lower, "resource_exhausted") != null or
        std.mem.indexOf(u8, lower, "rate_limit") != null or
        std.mem.indexOf(u8, lower, "overloaded") != null or
        std.mem.indexOf(u8, lower, "service_unavailable") != null;
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

fn getDisabledThinkingConfig(model_id: []const u8) std.json.Value {
    if (gs.isGemini3ProModel(model_id)) {
        var o = std.json.ObjectMap.init(std.heap.page_allocator);
        o.put("thinkingLevel", .{ .string = "LOW" }) catch {};
        return std.json.Value{ .object = o };
    }
    if (gs.isGemini3FlashModel(model_id)) {
        var o = std.json.ObjectMap.init(std.heap.page_allocator);
        o.put("thinkingLevel", .{ .string = "MINIMAL" }) catch {};
        return std.json.Value{ .object = o };
    }
    var o = std.json.ObjectMap.init(std.heap.page_allocator);
    o.put("thinkingBudget", .{ .integer = 0 }) catch {};
    return std.json.Value{ .object = o };
}

fn getGeminiCliThinkingLevel(effort: ai.ThinkingLevel, model_id: []const u8) []const u8 {
    if (gs.isGemini3ProModel(model_id)) {
        return switch (effort) {
            .minimal, .low => "LOW",
            .medium, .high, .xhigh => "HIGH",
        };
    }
    return switch (effort) {
        .minimal => "MINIMAL",
        .low => "LOW",
        .medium => "MEDIUM",
        .high, .xhigh => "HIGH",
    };
}

fn buildRequest(gpa: std.mem.Allocator, model: ai.Model, context: ai.Context, options: ?ai.StreamOptions, is_antigravity: bool) !std.json.Value {
    const contents = try gs.convertMessages(gpa, model, context);

    var request = std.json.ObjectMap.init(gpa);
    try request.put("contents", contents);
    if (context.system_prompt) |sp| {
        var si = std.json.ObjectMap.init(gpa);
        try si.put("parts", .{ .array = .{ .items = blk: {
            var arr = std.ArrayList(std.json.Value).init(gpa);
            var pt = std.json.ObjectMap.init(gpa);
            try pt.put("text", .{ .string = gs.sanitizeSurrogates(sp) });
            try arr.append(.{ .object = pt });
            break :blk arr;
        }, .capacity = 1 } });
        try request.put("systemInstruction", .{ .object = si });
    }

    var generation_config = std.json.ObjectMap.init(gpa);
    const opts = options orelse ai.StreamOptions{};
    if (opts.temperature) |t| try generation_config.put("temperature", .{ .float = t });
    if (opts.max_tokens) |mt| try generation_config.put("maxOutputTokens", .{ .integer = mt });

    // thinking config
    if (model.reasoning) {
        // default enabled for gemini cli when reasoning model
        var tc = std.json.ObjectMap.init(gpa);
        try tc.put("includeThoughts", .{ .bool = true });
        // For gemini 3 models, set a level; otherwise budget
        if (gs.isGemini3ProModel(model.id) or gs.isGemini3FlashModel(model.id)) {
            try tc.put("thinkingLevel", .{ .string = "MEDIUM" });
        } else {
            try tc.put("thinkingBudget", .{ .integer = 8192 });
        }
        try generation_config.put("thinkingConfig", .{ .object = tc });
    }

    if (generation_config.count() > 0) {
        try request.put("generationConfig", .{ .object = generation_config });
    } else {
        generation_config.deinit();
    }

    if (context.tools) |tools| {
        try request.put("tools", try gs.convertTools(gpa, tools));
        if (opts.headers) |hv| {
            if (hv.object.get("tool_choice")) |tcv| {
                if (tcv == .string) {
                    var tc = std.json.ObjectMap.init(gpa);
                    var fcc = std.json.ObjectMap.init(gpa);
                    try fcc.put("mode", .{ .string = gs.mapToolChoice(tcv.string) });
                    try tc.put("functionCallingConfig", .{ .object = fcc });
                    try request.put("toolConfig", .{ .object = tc });
                }
            }
        }
    }

    if (opts.session_id) |sid| {
        try request.put("sessionId", .{ .string = sid });
    }

    if (is_antigravity) {
        if (request.get("systemInstruction")) |si| {
            if (si == .object) {
                var parts = std.ArrayList(std.json.Value).init(gpa);
                var pt1 = std.json.ObjectMap.init(gpa);
                try pt1.put("text", .{ .string = "You are Antigravity, a powerful agentic AI coding assistant designed by the Google Deepmind team working on Advanced Agentic Coding.You are pair programming with a USER to solve their coding task. The task may require creating a new codebase, modifying or debugging an existing codebase, or simply answering a question.**Absolute paths only****Proactiveness**" });
                try parts.append(.{ .object = pt1 });
                var pt2 = std.json.ObjectMap.init(gpa);
                try pt2.put("text", .{ .string = "Please ignore following [ignore]You are Antigravity, a powerful agentic AI coding assistant designed by the Google Deepmind team working on Advanced Agentic Coding.You are pair programming with a USER to solve their coding task. The task may require creating a new codebase, modifying or debugging an existing codebase, or simply answering a question.**Absolute paths only****Proactiveness**[/ignore]" });
                try parts.append(.{ .object = pt2 });
                if (si.object.get("parts")) |ps| {
                    if (ps == .array) {
                        for (ps.array.items) |p| try parts.append(p);
                    }
                }
                try si.object.put("role", .{ .string = "user" });
                try si.object.put("parts", .{ .array = .{ .items = parts, .capacity = parts.items.len } });
            }
        }
    }

    var root = std.json.ObjectMap.init(gpa);
    try root.put("project", .{ .string = if (is_antigravity) "antigravity" else "pi-coding-agent" }); // projectId filled outside
    try root.put("model", .{ .string = model.id });
    try root.put("request", .{ .object = request });
    if (is_antigravity) {
        try root.put("requestType", .{ .string = "agent" });
    }
    try root.put("userAgent", .{ .string = if (is_antigravity) "antigravity" else "pi-coding-agent" });
    const req_id = std.fmt.allocPrint(gpa, "{s}-{d}-{d}", .{ if (is_antigravity) "agent" else "pi", currentMs(), std.crypto.random.int(u32) }) catch "pi-0-0";
    try root.put("requestId", .{ .string = req_id });
    gpa.free(req_id);
    return std.json.Value{ .object = root };
}

fn getApiKey(model: ai.Model, opts_api_key: ?[]const u8) ?struct { token: []const u8, project_id: []const u8 } {
    _ = model;
    const raw = opts_api_key orelse (std.process.getEnvVarOwned(std.heap.page_allocator, "GEMINI_CLI_API_KEY") catch return null);
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{}) catch return null;
    const tok = if (parsed.value.object.get("token")) |tv| (if (tv == .string) tv.string else return null) else return null;
    const pid = if (parsed.value.object.get("projectId")) |pv| (if (pv == .string) pv.string else return null) else return null;
    return .{ .token = tok, .project_id = pid };
}

fn parseSseLine(line: []const u8) ?std.json.Value {
    const prefix = "data:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    const data = std.mem.trim(u8, if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest, " \r\n");
    if (std.mem.eql(u8, data, "[DONE]")) return null;
    var p = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch return null;
    return p.value;
}

var tool_call_counter: std.atomic.Value(u32) = .init(0);

fn nextToolCallId(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    const n = tool_call_counter.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(gpa, "{s}_{d}_{d}", .{ name, currentMs(), n });
}

fn appendContentBlock(gpa: std.mem.Allocator, output: *ai.AssistantMessage, block: ai.ContentBlock) void {
    const new_content = gpa.realloc(output.content, output.content.len + 1) catch return;
    output.content = new_content;
    output.content[output.content.len - 1] = block;
}

fn finalizeBlock(es: ai.AssistantMessageEventStream, output: *ai.AssistantMessage, block: ai.ContentBlock) void {
    const idx = output.content.len - 1;
    switch (block) {
        .text => es.push(.{ .text_end = .{ .content_index = idx, .content = output.content[idx].text.text, .partial = output.* } }) catch {},
        .thinking => es.push(.{ .thinking_end = .{ .content_index = idx, .content = output.content[idx].thinking.thinking, .partial = output.* } }) catch {},
        else => {},
    }
}

pub fn streamGoogleGeminiCli(model: ai.Model, context: ai.Context, options: ?ai.StreamOptions) ai.AssistantMessageEventStream {
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

    const creds = getApiKey(model, if (options) |o| o.base.api_key else null) orelse {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "Google Cloud Code Assist requires OAuth authentication";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return es;
    };

    const thread = std.Thread.spawn(.{}, geminiCliThread, .{ model, context, options, creds, output, es }) catch |err| {
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

fn geminiCliThread(model: ai.Model, context: ai.Context, options: ?ai.StreamOptions, creds: struct { token: []const u8, project_id: []const u8 }, output: ai.AssistantMessage, es: ai.AssistantMessageEventStream) void {
    const gpa = std.heap.page_allocator;
    const client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    const is_antigravity = std.mem.eql(u8, model.provider, "google-antigravity");
    const endpoints = if (is_antigravity)
        &[_][]const u8{ "https://daily-cloudcode-pa.sandbox.googleapis.com", "https://autopush-cloudcode-pa.sandbox.googleapis.com", "https://cloudcode-pa.googleapis.com" }
    else
        &[_][]const u8{"https://cloudcode-pa.googleapis.com"};

    const base_url = model.base_url orelse endpoints[0];
    const effective_endpoints = if (model.base_url != null) &[_][]const u8{base_url} else endpoints;

    const auth_header = std.fmt.allocPrint(gpa, "Bearer {s}", .{creds.token}) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "OOM";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };
    defer gpa.free(auth_header);

    // Build request body and inject project id at top level
    var body_value = buildRequest(gpa, model, context, options, is_antigravity) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "Failed to build request";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };
    if (body_value.object.get("project")) |pv| {
        if (pv == .string) {
            _ = body_value.object.put("project", .{ .string = creds.project_id }) catch {};
        }
    }

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

    var extra_headers = std.ArrayList(std.http.Client.Header).init(gpa);
    defer extra_headers.deinit();
    extra_headers.append(.{ .name = "Authorization", .value = auth_header }) catch {};
    extra_headers.append(.{ .name = "Content-Type", .value = "application/json" }) catch {};
    extra_headers.append(.{ .name = "Accept", .value = "text/event-stream" }) catch {};

    if (is_antigravity) {
        extra_headers.append(.{ .name = "User-Agent", .value = "antigravity/1.18.4 darwin/arm64" }) catch {};
    } else {
        extra_headers.append(.{ .name = "User-Agent", .value = "google-cloud-sdk vscode_cloudshelleditor/0.1" }) catch {};
        extra_headers.append(.{ .name = "X-Goog-Api-Client", .value = "gl-node/22.17.0" }) catch {};
        extra_headers.append(.{ .name = "Client-Metadata", .value = "{\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}" }) catch {};
    }

    if (std.mem.startsWith(u8, model.id, "claude-") and model.reasoning and is_antigravity) {
        extra_headers.append(.{ .name = "anthropic-beta", .value = "interleaved-thinking-2025-05-14" }) catch {};
    }

    if (options) |opts| {
        if (opts.headers) |oh| {
            var it = oh.object.iterator();
            while (it.next()) |entry| {
                const val = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
                extra_headers.append(.{ .name = entry.key_ptr.*, .value = val }) catch {};
            }
        }
    }

    var endpoint_idx: usize = 0;
    var last_error: ?[]const u8 = null;
    var fetch_res: ?std.http.Client.FetchResult = null;

    // retry loop
    for (0..4) |attempt| {
        if (endpoint_idx >= effective_endpoints.len) break;
        const url = std.fmt.allocPrint(gpa, "{s}/v1internal:streamGenerateContent?alt=sse", .{effective_endpoints[endpoint_idx]}) catch continue;
        defer gpa.free(url);

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

        // read error text
        var err_buf: [4096]u8 = undefined;
        const err_n = res.body.reader().read(&err_buf) catch 0;
        const err_text = if (err_n > 0) err_buf[0..err_n] else "HTTP error";
        last_error = std.fmt.allocPrint(gpa, "Cloud Code Assist API error ({d}): {s}", .{ status_code, extractErrorMessage(err_text) }) catch "HTTP error";

        if ((status_code == 403 or status_code == 404) and endpoint_idx + 1 < effective_endpoints.len) {
            endpoint_idx += 1;
            continue;
        }
        if (isRetryableError(res.status, err_text) and attempt < 3) {
            if (endpoint_idx + 1 < effective_endpoints.len) endpoint_idx += 1;
            std.time.sleep(@as(u64, 1000) * std.time.ns_per_ms * (1 << @as(u6, @intCast(attempt))));
            continue;
        }
        // not retryable
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

    var current_block: ?ai.ContentBlock = null;

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
                    processGeminiCliSseLine(gpa, line, &output, es, &current_block);
                }
                line_buf.clearRetainingCapacity();
            } else {
                line_buf.append(byte) catch {};
            }
        }
    }

    if (current_block) |cb| {
        finalizeBlock(es, &output, cb);
    }

    es.push(.{ .done = .{ .reason = output.stop_reason, .message = output } }) catch {};
    es.end(null);
}

fn processGeminiCliSseLine(gpa: std.mem.Allocator, line: []const u8, output: *ai.AssistantMessage, es: ai.AssistantMessageEventStream, current_block: *?ai.ContentBlock) void {
    const chunk = parseSseLine(line) orelse return;
    const response_data = blk: {
        if (chunk.object.get("response")) |rv| {
            if (rv == .object) break :blk rv.object;
        }
        break :blk null;
    };
    if (response_data == null) return;

    if (response_data.get("responseId")) |rv| {
        if (rv == .string and output.response_id == null) {
            output.response_id = rv.string;
        }
    }

    if (response_data.get("candidates")) |cv| {
        if (cv == .array and cv.array.items.len > 0) {
            const candidate = cv.array.items[0];
            if (candidate.object.get("content")) |contentv| {
                if (contentv.object.get("parts")) |partsv| {
                    if (partsv == .array) {
                        for (partsv.array.items) |part| {
                            if (part == .object) {
                                processGeminiCliPart(gpa, part.object, output, es, current_block);
                            }
                        }
                    }
                }
            }
            if (candidate.object.get("finishReason")) |frv| {
                if (frv == .string) {
                    output.stop_reason = gs.mapStopReasonString(frv.string);
                    const has_toolcall = blk: {
                        for (output.content) |b| {
                            if (b == .tool_call) break :blk true;
                        }
                        break :blk false;
                    };
                    if (has_toolcall and output.stop_reason == .stop) {
                        output.stop_reason = .tool_use;
                    }
                }
            }
        }
    }

    if (response_data.get("usageMetadata")) |um| {
        const prompt_tok = if (um.object.get("promptTokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;
        const cached_tok = if (um.object.get("cachedContentTokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;
        const candidates_tok = if (um.object.get("candidatesTokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;
        const thoughts_tok = if (um.object.get("thoughtsTokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;
        const total_tok = if (um.object.get("totalTokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;
        output.usage = .{
            .input = if (prompt_tok > cached_tok) prompt_tok - cached_tok else 0,
            .output = candidates_tok + thoughts_tok,
            .cache_read = cached_tok,
            .cache_write = 0,
            .total_tokens = total_tok,
        };
    }
}

fn processGeminiCliPart(gpa: std.mem.Allocator, part_obj: std.json.ObjectMap, output: *ai.AssistantMessage, es: ai.AssistantMessageEventStream, current_block: *?ai.ContentBlock) void {
    const is_thinking = gs.isThinkingPart(part_obj);

    if (part_obj.get("text")) |tv| {
        if (tv == .string) {
            const txt = tv.string;
            if (txt.len == 0 or std.mem.trim(u8, txt, " \t\r\n").len == 0) return;
            const needs_switch = blk: {
                if (current_block.*) |cb| {
                    if (is_thinking and cb != .thinking) break :blk true;
                    if (!is_thinking and cb != .text) break :blk true;
                }
                break :blk false;
            };
            if (current_block.* == null or needs_switch) {
                if (current_block.*) |cb| finalizeBlock(es, output, cb);
                if (is_thinking) {
                    appendContentBlock(gpa, output, .{ .thinking = .{ .thinking = "" } });
                    es.push(.{ .thinking_start = .{ .content_index = output.content.len - 1, .partial = output.* } }) catch {};
                    current_block.* = .{ .thinking = .{ .thinking = "" } };
                } else {
                    appendContentBlock(gpa, output, .{ .text = .{ .text = "" } });
                    es.push(.{ .text_start = .{ .content_index = output.content.len - 1, .partial = output.* } }) catch {};
                    current_block.* = .{ .text = .{ .text = "" } };
                }
            }
            const idx = output.content.len - 1;
            if (is_thinking) {
                output.content[idx].thinking.thinking = std.fmt.allocPrint(gpa, "{s}{s}", .{ output.content[idx].thinking.thinking, txt }) catch output.content[idx].thinking.thinking;
                if (part_obj.get("thoughtSignature")) |sigv| {
                    if (sigv == .string) output.content[idx].thinking.thinking_signature = sigv.string;
                }
                es.push(.{ .thinking_delta = .{ .content_index = idx, .delta = txt, .partial = output.* } }) catch {};
            } else {
                output.content[idx].text.text = std.fmt.allocPrint(gpa, "{s}{s}", .{ output.content[idx].text.text, txt }) catch output.content[idx].text.text;
                if (part_obj.get("thoughtSignature")) |sigv| {
                    if (sigv == .string) output.content[idx].text.text_signature = sigv.string;
                }
                es.push(.{ .text_delta = .{ .content_index = idx, .delta = txt, .partial = output.* } }) catch {};
            }
        }
    }

    if (part_obj.get("functionCall")) |fcv| {
        if (fcv == .object) {
            if (current_block.*) |cb| {
                finalizeBlock(es, output, cb);
                current_block.* = null;
            }
            const name = if (fcv.object.get("name")) |nv| (if (nv == .string) nv.string else "") else "";
            const args = if (fcv.object.get("args")) |av| av else std.json.Value{ .object = std.json.ObjectMap.init(gpa) };
            var provided_id: ?[]const u8 = null;
            if (fcv.object.get("id")) |iv| {
                if (iv == .string) provided_id = iv.string;
            }
            const needs_new_id = blk: {
                if (provided_id) |pid| {
                    for (output.content) |b| {
                        if (b == .tool_call and std.mem.eql(u8, b.tool_call.id, pid)) break :blk true;
                    }
                    break :blk false;
                }
                break :blk true;
            };
            const tool_id = if (needs_new_id) (nextToolCallId(gpa, name) catch "") else (provided_id orelse "");
            var tc = ai.ToolCall{ .id = tool_id, .name = name, .arguments = args };
            if (part_obj.get("thoughtSignature")) |sigv| {
                if (sigv == .string) tc.thought_signature = sigv.string;
            }
            appendContentBlock(gpa, output, .{ .tool_call = tc });
            const idx = output.content.len - 1;
            es.push(.{ .toolcall_start = .{ .content_index = idx, .partial = output.* } }) catch {};
            const args_str = jsonStringifyValue(gpa, args) catch "";
            es.push(.{ .toolcall_delta = .{ .content_index = idx, .delta = args_str, .partial = output.* } }) catch {};
            es.push(.{ .toolcall_end = .{ .content_index = idx, .tool_call = tc, .partial = output.* } }) catch {};
        }
    }
}

pub fn streamSimpleGoogleGeminiCli(model: ai.Model, context: ai.Context, options: ?ai.types.SimpleStreamOptions) ai.AssistantMessageEventStream {
    const api_key = getApiKey(model, if (options) |o| o.base.api_key else null);
    const base = ai.simple_options.buildBaseOptions(model, options, if (api_key) |c| c.token else null);

    _ = model.reasoning;
    return streamGoogleGeminiCli(model, context, base);
}

pub fn registerGoogleGeminiCliProvider() void {
    ai.registerApiProvider(.{
        .api = .{ .known = .google_gemini_cli },
        .stream = streamGoogleGeminiCli,
        .stream_simple = streamSimpleGoogleGeminiCli,
    });
}

test "google_gemini_cli compiles and registers" {
    registerGoogleGeminiCliProvider();
}

test "buildRequest wraps request for Cloud Code Assist" {
    const gpa = std.testing.allocator;
    const model = ai.Model{
        .id = "gemini-1.5-pro",
        .name = "Gemini",
        .api = .{ .known = .google_gemini_cli },
        .provider = .{ .known = .google },
        .max_tokens = 8192,
    };
    const context = ai.Context{
        .messages = &[_]ai.Message{ ai.Message{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } } },
    };
    const req = try buildRequest(gpa, model, context, null, false);
    try std.testing.expectEqualStrings("pi-coding-agent", req.object.get("userAgent").?.string);
    try std.testing.expect(req.object.get("requestId") != null);
    try std.testing.expectEqualStrings("gemini-1.5-pro", req.object.get("model").?.string);
    const inner = req.object.get("request").?.object;
    try std.testing.expect(inner.get("contents") != null);
}
