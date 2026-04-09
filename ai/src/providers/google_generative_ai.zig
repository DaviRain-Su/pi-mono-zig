const std = @import("std");
const ai = @import("../root.zig");

fn jsonStringifyValue(gpa: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var list = std.ArrayList(u8).init(gpa);
    defer list.deinit();
    try std.json.stringify(value, .{}, list.writer());
    return list.toOwnedSlice();
}

fn sanitizeSurrogates(text: []const u8) []const u8 {
    return text;
}

fn isGemini3ProModel(model_id: []const u8) bool {
    const lower = std.asciiLowerStringStack(model_id);
    // minimal heuristic
    return std.mem.startsWith(u8, lower, "gemini-3") and std.mem.indexOf(u8, lower, "-pro") != null;
}

fn isGemini3FlashModel(model_id: []const u8) bool {
    const lower = std.asciiLowerStringStack(model_id);
    return std.mem.startsWith(u8, lower, "gemini-3") and std.mem.indexOf(u8, lower, "-flash") != null;
}

fn requiresToolCallId(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "claude-") or std.mem.startsWith(u8, model_id, "gpt-oss-");
}

fn getGeminiMajorVersion(model_id: []const u8) ?u32 {
    // simplified: check if starts with gemini-
    const prefix = "gemini-";
    if (!std.mem.startsWith(u8, std.asciiLowerStringStack(model_id), prefix)) return null;
    const rest = model_id[prefix.len..];
    var i: usize = 0;
    while (i < rest.len and !std.ascii.isDigit(rest[i])) i += 1;
    if (i >= rest.len) return null;
    var num: u32 = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {
        num = num * 10 + (rest[i] - '0');
    }
    return num;
}

fn supportsMultimodalFunctionResponse(model_id: []const u8) bool {
    const major = getGeminiMajorVersion(model_id);
    if (major) |m| return m >= 3;
    return true;
}

fn normalizeToolCallId(gpa: std.mem.Allocator, id: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(gpa);
    defer buf.deinit();
    for (id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            try buf.append(c);
        } else {
            try buf.append('_');
        }
    }
    var result = try buf.toOwnedSlice();
    if (result.len > 64) {
        const truncated = try gpa.dupe(u8, result[0..64]);
        gpa.free(result);
        result = truncated;
    }
    return result;
}

fn resolveThoughtSignature(is_same: bool, signature: ?[]const u8) ?[]const u8 {
    if (!is_same) return null;
    if (signature) |s| {
        if (s.len % 4 != 0) return null;
        for (s) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=')) return null;
        }
        return s;
    }
    return null;
}

fn isThinkingPart(part_obj: std.json.ObjectMap) bool {
    if (part_obj.get("thought")) |tv| {
        if (tv == .bool) return tv.bool;
    }
    return false;
}

fn mapToolChoice(choice: []const u8) []const u8 {
    if (std.mem.eql(u8, choice, "none")) return "NONE";
    if (std.mem.eql(u8, choice, "any")) return "ANY";
    return "AUTO";
}

fn mapStopReason(reason: []const u8) ai.StopReason {
    if (std.mem.eql(u8, reason, "STOP")) return .stop;
    if (std.mem.eql(u8, reason, "MAX_TOKENS")) return .length;
    return .err;
}

fn convertMessages(gpa: std.mem.Allocator, model: ai.Model, context: ai.Context) !std.json.Value {
    const norm_id = struct {
        fn f(id: []const u8, _m: ai.Model, _src: ai.AssistantMessage) []const u8 {
            _ = _m;
            _ = _src;
            return normalizeToolCallId(std.heap.page_allocator, id) catch id;
        }
    }.f;
    const msgs = try ai.transform_messages.transformMessages(gpa, context.messages, model, norm_id);
    defer gpa.free(msgs);

    var contents = std.ArrayList(std.json.Value).init(gpa);

    for (msgs) |msg| {
        switch (msg) {
            .user => |u| {
                switch (u.content) {
                    .text => |t| {
                        var obj = std.json.ObjectMap.init(gpa);
                        try obj.put("role", .{ .string = "user" });
                        var parts = std.ArrayList(std.json.Value).init(gpa);
                        var pt = std.json.ObjectMap.init(gpa);
                        try pt.put("text", .{ .string = sanitizeSurrogates(t.text) });
                        try parts.append(.{ .object = pt });
                        try obj.put("parts", .{ .array = .{ .items = parts, .capacity = parts.items.len } });
                        try contents.append(.{ .object = obj });
                    },
                    .blocks => |blocks| {
                        var parts = std.ArrayList(std.json.Value).init(gpa);
                        for (blocks) |block| {
                            switch (block) {
                                .text => |t| {
                                    var pt = std.json.ObjectMap.init(gpa);
                                    try pt.put("text", .{ .string = sanitizeSurrogates(t.text) });
                                    try parts.append(.{ .object = pt });
                                },
                                .image => |img| {
                                    if (!std.mem.containsAtLeast(u8, model.input, 1, "image")) continue;
                                    var pt = std.json.ObjectMap.init(gpa);
                                    try pt.put("inlineData", .{ .object = blk: {
                                        var o = std.json.ObjectMap.init(gpa);
                                        try o.put("mimeType", .{ .string = img.mime_type });
                                        try o.put("data", .{ .string = img.data });
                                        break :blk o;
                                    } });
                                    try parts.append(.{ .object = pt });
                                },
                                else => {},
                            }
                        }
                        if (parts.items.len > 0) {
                            var obj = std.json.ObjectMap.init(gpa);
                            try obj.put("role", .{ .string = "user" });
                            try obj.put("parts", .{ .array = .{ .items = parts, .capacity = parts.items.len } });
                            try contents.append(.{ .object = obj });
                        }
                        parts.deinit();
                    },
                }
            },
            .assistant => |a| {
                const is_same = std.mem.eql(u8, a.provider, model.provider) and std.mem.eql(u8, a.model, model.id);
                var parts = std.ArrayList(std.json.Value).init(gpa);
                for (a.content) |block| {
                    switch (block) {
                        .text => |t| {
                            if (t.text.len == 0 or std.mem.trim(u8, t.text, " \t\r\n").len == 0) continue;
                            var pt = std.json.ObjectMap.init(gpa);
                            try pt.put("text", .{ .string = sanitizeSurrogates(t.text) });
                            const sig = resolveThoughtSignature(is_same, t.text_signature);
                            if (sig) |s| try pt.put("thoughtSignature", .{ .string = s });
                            try parts.append(.{ .object = pt });
                        },
                        .thinking => |th| {
                            if (th.thinking.len == 0 or std.mem.trim(u8, th.thinking, " \t\r\n").len == 0) continue;
                            if (is_same) {
                                var pt = std.json.ObjectMap.init(gpa);
                                try pt.put("thought", .{ .bool = true });
                                try pt.put("text", .{ .string = sanitizeSurrogates(th.thinking) });
                                const sig = resolveThoughtSignature(is_same, th.thinking_signature);
                                if (sig) |s| try pt.put("thoughtSignature", .{ .string = s });
                                try parts.append(.{ .object = pt });
                            } else {
                                var pt = std.json.ObjectMap.init(gpa);
                                try pt.put("text", .{ .string = sanitizeSurrogates(th.thinking) });
                                try parts.append(.{ .object = pt });
                            }
                        },
                        .tool_call => |tc| {
                            const include_id = requiresToolCallId(model.id);
                            var pt = std.json.ObjectMap.init(gpa);
                            var fc = std.json.ObjectMap.init(gpa);
                            try fc.put("name", .{ .string = tc.name });
                            try fc.put("args", tc.arguments);
                            if (include_id) try fc.put("id", .{ .string = tc.id });
                            try pt.put("functionCall", .{ .object = fc });
                            const sig = resolveThoughtSignature(is_same, tc.thought_signature);
                            if (sig) |s| try pt.put("thoughtSignature", .{ .string = s });
                            try parts.append(.{ .object = pt });
                        },
                        else => {},
                    }
                }
                if (parts.items.len > 0) {
                    var obj = std.json.ObjectMap.init(gpa);
                    try obj.put("role", .{ .string = "model" });
                    try obj.put("parts", .{ .array = .{ .items = parts, .capacity = parts.items.len } });
                    try contents.append(.{ .object = obj });
                }
                parts.deinit();
            },
            .tool_result => |tr| {
                var text_parts = std.ArrayList([]const u8).init(gpa);
                var has_images = false;
                var image_parts = std.ArrayList(std.json.Value).init(gpa);
                for (tr.content) |block| {
                    switch (block) {
                        .text => |t| try text_parts.append(t.text),
                        .image => |img| {
                            has_images = true;
                            if (std.mem.containsAtLeast(u8, model.input, 1, "image")) {
                                var pt = std.json.ObjectMap.init(gpa);
                                try pt.put("inlineData", .{ .object = blk: {
                                    var o = std.json.ObjectMap.init(gpa);
                                    try o.put("mimeType", .{ .string = img.mime_type });
                                    try o.put("data", .{ .string = img.data });
                                    break :blk o;
                                } });
                                try image_parts.append(.{ .object = pt });
                            }
                        },
                        else => {},
                    }
                }
                const text_result = try std.mem.join(gpa, "\n", text_parts.items);
                text_parts.deinit();
                const has_text = text_result.len > 0;
                const mm_supported = supportsMultimodalFunctionResponse(model.id);

                const include_id = requiresToolCallId(model.id);
                var fr = std.json.ObjectMap.init(gpa);
                try fr.put("name", .{ .string = tr.tool_name });
                const response_val = if (tr.is_error)
                    std.json.Value{ .object = blk: { var o = std.json.ObjectMap.init(gpa); try o.put("error", .{ .string = if (has_text) sanitizeSurrogates(text_result) else "(see attached image)" }); break :blk o; } }
                else
                    std.json.Value{ .object = blk: { var o = std.json.ObjectMap.init(gpa); try o.put("output", .{ .string = if (has_text) sanitizeSurrogates(text_result) else "(see attached image)" }); break :blk o; } };
                try fr.put("response", response_val);
                if (has_images and mm_supported and image_parts.items.len > 0) {
                    try fr.put("parts", .{ .array = .{ .items = image_parts, .capacity = image_parts.items.len } });
                }
                if (include_id) try fr.put("id", .{ .string = tr.tool_call_id });

                var fcp = std.json.ObjectMap.init(gpa);
                try fcp.put("functionResponse", .{ .object = fr });

                // merge into last user content if it already has functionResponse parts
                if (contents.items.len > 0) {
                    if (contents.items[contents.items.len - 1].object.get("role")) |rv| {
                        if (rv == .string and std.mem.eql(u8, rv.string, "user")) {
                            if (contents.items[contents.items.len - 1].object.get("parts")) |pv| {
                                if (pv == .array) {
                                    var has_fr = false;
                                    for (pv.array.items) |p| {
                                        if (p.object.get("functionResponse") != null) {
                                            has_fr = true;
                                            break;
                                        }
                                    }
                                    if (has_fr) {
                                        var arr = pv.array;
                                        try arr.items.append(.{ .object = fcp });
                                        try contents.items[contents.items.len - 1].object.put("parts", .{ .array = arr });
                                        if (!mm_supported and has_images and image_parts.items.len > 0) {
                                            var extra = std.ArrayList(std.json.Value).init(gpa);
                                            var txt = std.json.ObjectMap.init(gpa);
                                            try txt.put("text", .{ .string = "Tool result image:" });
                                            try extra.append(.{ .object = txt });
                                            for (image_parts.items) |ip| try extra.append(ip);
                                            var extra_obj = std.json.ObjectMap.init(gpa);
                                            try extra_obj.put("role", .{ .string = "user" });
                                            try extra_obj.put("parts", .{ .array = .{ .items = extra, .capacity = extra.items.len } });
                                            try contents.append(.{ .object = extra_obj });
                                        }
                                        continue;
                                    }
                                }
                            }
                        }
                    }
                }

                var obj = std.json.ObjectMap.init(gpa);
                try obj.put("role", .{ .string = "user" });
                var arr = std.ArrayList(std.json.Value).init(gpa);
                try arr.append(.{ .object = fcp });
                try obj.put("parts", .{ .array = .{ .items = arr, .capacity = arr.items.len } });
                try contents.append(.{ .object = obj });

                if (!mm_supported and has_images and image_parts.items.len > 0) {
                    var extra = std.ArrayList(std.json.Value).init(gpa);
                    var txt = std.json.ObjectMap.init(gpa);
                    try txt.put("text", .{ .string = "Tool result image:" });
                    try extra.append(.{ .object = txt });
                    for (image_parts.items) |ip| try extra.append(ip);
                    var extra_obj = std.json.ObjectMap.init(gpa);
                    try extra_obj.put("role", .{ .string = "user" });
                    try extra_obj.put("parts", .{ .array = .{ .items = extra, .capacity = extra.items.len } });
                    try contents.append(.{ .object = extra_obj });
                }
            },
        }
    }

    return std.json.Value{ .array = .{ .items = contents, .capacity = contents.items.len } };
}

fn convertTools(gpa: std.mem.Allocator, tools: []const ai.Tool) !std.json.Value {
    var declarations = std.ArrayList(std.json.Value).init(gpa);
    for (tools) |tool| {
        var obj = std.json.ObjectMap.init(gpa);
        try obj.put("name", .{ .string = tool.name });
        try obj.put("description", .{ .string = tool.description });
        try obj.put("parameters", tool.parameters);
        try declarations.append(.{ .object = obj });
    }
    var outer = std.json.ObjectMap.init(gpa);
    try outer.put("functionDeclarations", .{ .array = .{ .items = declarations, .capacity = declarations.items.len } });
    var arr = std.ArrayList(std.json.Value).init(gpa);
    try arr.append(.{ .object = outer });
    return std.json.Value{ .array = .{ .items = arr, .capacity = arr.items.len } };
}

fn getGoogleBudget(model_id: []const u8, effort: ai.ThinkingLevel, custom_budgets: ?ai.ThinkingBudgets) i64 {
    if (custom_budgets) |cb| {
        return switch (effort) {
            .minimal => @intCast(cb.minimal),
            .low => @intCast(cb.low),
            .medium => @intCast(cb.medium),
            .high, .xhigh => @intCast(cb.high),
        };
    }
    if (std.mem.indexOf(u8, model_id, "2.5-pro") != null) {
        return switch (effort) {
            .minimal => 128,
            .low => 2048,
            .medium => 8192,
            .high, .xhigh => 32768,
        };
    }
    if (std.mem.indexOf(u8, model_id, "2.5-flash") != null) {
        return switch (effort) {
            .minimal => 128,
            .low => 2048,
            .medium => 8192,
            .high, .xhigh => 24576,
        };
    }
    return -1;
}

fn getGemini3ThinkingLevel(effort: ai.ThinkingLevel, model_id: []const u8) []const u8 {
    if (isGemini3ProModel(model_id)) {
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

fn buildParams(gpa: std.mem.Allocator, model: ai.Model, context: ai.Context, options: ?ai.StreamOptions) !std.json.Value {
    const contents = try convertMessages(gpa, model, context);

    var obj = std.json.ObjectMap.init(gpa);
    try obj.put("contents", contents);

    var generation_config = std.json.ObjectMap.init(gpa);
    const opts = options orelse ai.StreamOptions{};
    if (opts.temperature) |t| try generation_config.put("temperature", .{ .float = t });
    if (opts.max_tokens) |mt| try generation_config.put("maxOutputTokens", .{ .integer = mt });
    if (opts.top_p) |tp| try generation_config.put("topP", .{ .float = tp });
    if (opts.top_k) |tk| try generation_config.put("topK", .{ .integer = tk });
    if (generation_config.count() > 0) {
        try obj.put("generationConfig", .{ .object = generation_config });
    } else {
        // don't leak empty map if not used
        generation_config.deinit();
    }

    if (context.system_prompt) |sp| {
        var si = std.json.ObjectMap.init(gpa);
        try si.put("role", .{ .string = "user" });
        var parts = std.ArrayList(std.json.Value).init(gpa);
        var pt = std.json.ObjectMap.init(gpa);
        try pt.put("text", .{ .string = sanitizeSurrogates(sp) });
        try parts.append(.{ .object = pt });
        try si.put("parts", .{ .array = .{ .items = parts, .capacity = parts.items.len } });
        try obj.put("systemInstruction", .{ .object = si });
    }

    if (context.tools) |tools| {
        try obj.put("tools", try convertTools(gpa, tools));
        if (opts.headers) |hv| {
            // use headers json as a vehicle for tool_choice if present under key "tool_choice"
            if (hv.object.get("tool_choice")) |tcv| {
                if (tcv == .string) {
                    var tc = std.json.ObjectMap.init(gpa);
                    var fcc = std.json.ObjectMap.init(gpa);
                    try fcc.put("mode", .{ .string = mapToolChoice(tcv.string) });
                    try tc.put("functionCallingConfig", .{ .object = fcc });
                    try obj.put("toolConfig", .{ .object = tc });
                }
            }
        }
    }

    if (model.reasoning) {
        // simplified thinking config handling derived from simple options
        // full reasoning-specific options are passed via stream options reasoning_effort field
        // but here we default to enabled with a budget if model supports reasoning.
        // For a fully aligned implementation, additional provider-specific option struct would be
        // needed. We use a minimal default for now.
        var tc = std.json.ObjectMap.init(gpa);
        try tc.put("includeThoughts", .{ .bool = true });
        try tc.put("thinkingBudget", .{ .integer = 8192 });
        try obj.put("thinkingConfig", .{ .object = tc });
    }

    return std.json.Value{ .object = obj };
}

fn getApiKey(model: ai.Model, opts_api_key: ?[]const u8) ?[]const u8 {
    _ = model;
    if (opts_api_key) |k| return k;
    return std.process.getEnvVarOwned(std.heap.page_allocator, "GEMINI_API_KEY") catch null;
}

fn parseSseLine(line: []const u8) ?std.json.Value {
    const prefix = "data:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    const data = std.mem.trim(u8, if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest, " \r\n");
    if (std.mem.eql(u8, data, "[DONE]")) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch return null;
    return parsed.value;
}

var tool_call_counter: std.atomic.Value(u32) = .init(0);

fn nextToolCallId(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    const n = tool_call_counter.fetchAdd(1, .monotonic);
    const ms = currentMs();
    return std.fmt.allocPrint(gpa, "{s}_{d}_{d}", .{ name, ms, n });
}

pub fn streamGoogleGenerativeAI(model: ai.Model, context: ai.Context, options: ?ai.StreamOptions) ai.AssistantMessageEventStream {
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

    const api_key = getApiKey(model, if (options) |o| o.base.api_key else null) orelse {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "No API key for provider";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return es;
    };

    const thread = std.Thread.spawn(.{}, googleThread, .{ model, context, options, api_key, output, es }) catch |err| {
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

fn googleThread(model: ai.Model, context: ai.Context, options: ?ai.StreamOptions, api_key: []const u8, output: ai.AssistantMessage, es: ai.AssistantMessageEventStream) void {
    const gpa = std.heap.page_allocator;
    const client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    const base_url = model.base_url orelse "https://generativelanguage.googleapis.com";
    const url = std.fmt.allocPrint(gpa, "{s}/v1beta/models/{s}:streamGenerateContent?alt=sse&key={s}", .{ base_url, model.id, api_key }) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "OOM";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };
    defer gpa.free(url);

    const params = buildParams(gpa, model, context, options) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "Failed to build request params";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };

    var body_list = std.ArrayList(u8).init(gpa);
    defer body_list.deinit();
    std.json.stringify(params, .{}, body_list.writer()) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "Failed to serialize request";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const fetch_res = client.fetch(aa, .{
        .location = .{ .url = url },
        .method = .POST,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "text/event-stream" },
        },
        .payload = body_list.items,
    }) catch |err| {
        var o = output;
        o.stop_reason = .err;
        o.error_message = @errorName(err);
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };

    if (fetch_res.status != .ok) {
        var o = output;
        o.stop_reason = .err;
        o.error_message = std.fmt.allocPrint(gpa, "HTTP {d}", .{@intFromEnum(fetch_res.status)}) catch "HTTP error";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    }

    es.push(.{ .start = .{ .partial = output } }) catch {
        es.end(null);
        return;
    };

    var buf: [4096]u8 = undefined;
    var reader = fetch_res.body.reader();
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
                    processGoogleSseLine(gpa, line, &output, es, model, &current_block);
                }
                line_buf.clearRetainingCapacity();
            } else {
                line_buf.append(byte) catch {};
            }
        }
    }

    if (current_block) |cb| {
        finalizeCurrentBlock(es, &output, cb);
    }

    es.push(.{ .done = .{ .reason = output.stop_reason, .message = output } }) catch {};
    es.end(null);
}

fn finalizeCurrentBlock(es: ai.AssistantMessageEventStream, output: *ai.AssistantMessage, block: ai.ContentBlock) void {
    const idx = output.content.len - 1;
    switch (block) {
        .text => es.push(.{ .text_end = .{ .content_index = idx, .content = output.content[idx].text.text, .partial = output.* } }) catch {},
        .thinking => es.push(.{ .thinking_end = .{ .content_index = idx, .content = output.content[idx].thinking.thinking, .partial = output.* } }) catch {},
        else => {},
    }
}

fn processGoogleSseLine(gpa: std.mem.Allocator, line: []const u8, output: *ai.AssistantMessage, es: ai.AssistantMessageEventStream, model: ai.Model, current_block: *?ai.ContentBlock) void {
    const chunk = parseSseLine(line) orelse return;

    // responseId
    if (chunk.object.get("responseId")) |rv| {
        if (rv == .string and output.response_id == null) {
            output.response_id = rv.string;
        }
    }

    // candidates
    if (chunk.object.get("candidates")) |cv| {
        if (cv == .array and cv.array.items.len > 0) {
            const candidate = cv.array.items[0];
            // content.parts
            if (candidate.object.get("content")) |contentv| {
                if (contentv.object.get("parts")) |partsv| {
                    if (partsv == .array) {
                        for (partsv.array.items) |part| {
                            if (part == .object) {
                                processGooglePart(gpa, part.object, output, es, current_block);
                            }
                        }
                    }
                }
            }
            // finishReason
            if (candidate.object.get("finishReason")) |frv| {
                if (frv == .string) {
                    output.stop_reason = mapStopReason(frv.string);
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

    // usageMetadata
    if (chunk.object.get("usageMetadata")) |um| {
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
        ai.calculateCost(model, &output.usage);
    }
}

fn processGooglePart(gpa: std.mem.Allocator, part_obj: std.json.ObjectMap, output: *ai.AssistantMessage, es: ai.AssistantMessageEventStream, current_block: *?ai.ContentBlock) void {
    const is_thinking = isThinkingPart(part_obj);
    const thought_sig = if (part_obj.get("thoughtSignature")) |tv| (if (tv == .string) tv.string else null) else null;

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
                if (current_block.*) |cb| {
                    finalizeCurrentBlock(es, output, cb);
                }
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
                if (thought_sig) |sig| output.content[idx].thinking.thinking_signature = sig;
                es.push(.{ .thinking_delta = .{ .content_index = idx, .delta = txt, .partial = output.* } }) catch {};
            } else {
                output.content[idx].text.text = std.fmt.allocPrint(gpa, "{s}{s}", .{ output.content[idx].text.text, txt }) catch output.content[idx].text.text;
                if (thought_sig) |sig| output.content[idx].text.text_signature = sig;
                es.push(.{ .text_delta = .{ .content_index = idx, .delta = txt, .partial = output.* } }) catch {};
            }
        }
    }

    if (part_obj.get("functionCall")) |fcv| {
        if (fcv == .object) {
            if (current_block.*) |cb| {
                finalizeCurrentBlock(es, output, cb);
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
            if (thought_sig) |sig| tc.thought_signature = sig;
            appendContentBlock(gpa, output, .{ .tool_call = tc });
            const idx = output.content.len - 1;
            es.push(.{ .toolcall_start = .{ .content_index = idx, .partial = output.* } }) catch {};
            const args_str = jsonStringifyValue(gpa, args) catch "";
            es.push(.{ .toolcall_delta = .{ .content_index = idx, .delta = args_str, .partial = output.* } }) catch {};
            es.push(.{ .toolcall_end = .{ .content_index = idx, .tool_call = tc, .partial = output.* } }) catch {};
        }
    }
}

fn appendContentBlock(gpa: std.mem.Allocator, output: *ai.AssistantMessage, block: ai.ContentBlock) void {
    const new_content = gpa.realloc(output.content, output.content.len + 1) catch return;
    output.content = new_content;
    output.content[output.content.len - 1] = block;
}

fn currentMs() i64 {
    const ts = std.posix.clock_gettime(std.os.linux.CLOCK.REALTIME) catch return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms);
}

pub fn streamSimpleGoogleGenerativeAI(model: ai.Model, context: ai.Context, options: ?ai.types.SimpleStreamOptions) ai.AssistantMessageEventStream {
    const api_key = getApiKey(model, if (options) |o| o.base.api_key else null);
    const base = ai.simple_options.buildBaseOptions(model, options, api_key);

    const stream_opts = base;
    _ = model.reasoning; // reasoning defaults handled in buildParams
    return streamGoogleGenerativeAI(model, context, stream_opts);
}

pub fn registerGoogleGenerativeAIProvider() void {
    ai.registerApiProvider(.{
        .api = .{ .known = .google_generative_ai },
        .stream = streamGoogleGenerativeAI,
        .stream_simple = streamSimpleGoogleGenerativeAI,
    });
}

test "google_generative_ai compiles and registers" {
    registerGoogleGenerativeAIProvider();
}

test "buildParams contains generationConfig and tools" {
    const gpa = std.testing.allocator;
    const model = ai.Model{
        .id = "gemini-1.5-pro",
        .name = "Gemini",
        .api = .{ .known = .google_generative_ai },
        .provider = .{ .known = .google },
        .reasoning = false,
        .max_tokens = 8192,
    };
    const tool = ai.Tool{ .name = "Read", .description = "Read file", .parameters = .{ .object = std.json.ObjectMap.init(gpa) } };
    const context = ai.Context{
        .messages = &[_]ai.Message{ ai.Message{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } } },
        .tools = &[_]ai.Tool{tool},
    };
    const params = try buildParams(gpa, model, context, .{ .temperature = 0.5, .max_tokens = 1024 });
    try std.testing.expect(params.object.get("generationConfig") != null);
    try std.testing.expect(params.object.get("tools") != null);
    const tools_arr = params.object.get("tools").?;
    try std.testing.expectEqualStrings("Read", tools_arr.array.items[0].object.get("functionDeclarations").?.array.items[0].object.get("name").?.string);
}
