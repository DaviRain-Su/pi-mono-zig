const std = @import("std");
const ai = @import("../root.zig");

fn jsonStringifyValue(gpa: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var list = std.ArrayList(u8).init(gpa);
    defer list.deinit();
    try std.json.stringify(value, .{}, list.writer());
    return list.toOwnedSlice();
}

fn normalizeIdPart(gpa: std.mem.Allocator, id: []const u8) ![]const u8 {
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
    var end = result.len;
    while (end > 0 and result[end - 1] == '_') end -= 1;
    if (end < result.len) {
        const trimmed = try gpa.dupe(u8, result[0..end]);
        gpa.free(result);
        result = trimmed;
    }
    return result;
}

fn shortHash(input: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(input);
    return h.final();
}

fn buildForeignItemId(gpa: std.mem.Allocator, item_id: []const u8) ![]const u8 {
    const hash_val = shortHash(item_id);
    const prefix = "fc_";
    var buf: [128]u8 = undefined;
    const suffix = std.fmt.bufPrint(&buf[prefix.len..], "{x}", .{hash_val}) catch "0";
    const full = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, suffix });
    if (full.len > 64) {
        const truncated = try gpa.dupe(u8, full[0..64]);
        gpa.free(full);
        return truncated;
    }
    return full;
}

fn encodeTextSignatureV1(gpa: std.mem.Allocator, id: []const u8, phase: ?[]const u8) ![]const u8 {
    var obj = std.json.ObjectMap.init(gpa);
    try obj.put("v", .{ .integer = 1 });
    try obj.put("id", .{ .string = id });
    if (phase) |p| try obj.put("phase", .{ .string = p });
    var list = std.ArrayList(u8).init(gpa);
    defer list.deinit();
    try std.json.stringify(std.json.Value{ .object = obj }, .{}, list.writer());
    return list.toOwnedSlice();
}

fn parseTextSignature(gpa: std.mem.Allocator, signature: ?[]const u8) !?struct { id: []const u8, phase: ?[]const u8 } {
    const sig = signature orelse return null;
    if (sig.len > 0 and sig[0] == '{') {
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, sig, .{}) catch return null;
        const v = if (parsed.value.object.get("v")) |vv| (if (vv == .integer) vv.integer else 0) else 0;
        const idv = if (parsed.value.object.get("id")) |iv| (if (iv == .string) iv.string else null) else null;
        if (v == 1 and idv != null) {
            const phase = if (parsed.value.object.get("phase")) |pv| (if (pv == .string) pv.string else null) else null;
            return .{ .id = idv.?, .phase = phase };
        }
        return null;
    }
    return .{ .id = sig, .phase = null };
}

fn resolveCacheRetention(cache_retention: ?ai.CacheRetention) ai.CacheRetention {
    if (cache_retention) |cr| return cr;
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "PI_CACHE_RETENTION")) |v| {
        defer std.heap.page_allocator.free(v);
        if (std.mem.eql(u8, v, "long")) return .long;
    } else |_| {}
    return .short;
}

fn getPromptCacheRetention(base_url: []const u8, cache_retention: ai.CacheRetention) ?[]const u8 {
    if (cache_retention != .long) return null;
    if (std.mem.indexOf(u8, base_url, "api.openai.com") != null) return "24h";
    return null;
}

fn sanitizeSurrogates(text: []const u8) []const u8 {
    // minimal pass: no-op in Zig because strings are already UTF-8
    return text;
}

fn normalizeToolCallId(gpa: std.mem.Allocator, id: []const u8, model: ai.Model, source: ai.AssistantMessage) ![]const u8 {
    const openai_tool_providers = &.{ "openai", "openai-codex", "opencode" };
    var is_openai_provider = false;
    for (openai_tool_providers) |p| {
        if (std.mem.eql(u8, model.provider, p)) {
            is_openai_provider = true;
            break;
        }
    }
    if (!is_openai_provider) {
        return normalizeIdPart(gpa, id);
    }
    if (!std.mem.containsAtLeast(u8, id, 1, "|")) {
        return normalizeIdPart(gpa, id);
    }
    const pipe = std.mem.indexOfScalar(u8, id, '|').?;
    const call_id = id[0..pipe];
    const item_id = id[pipe + 1 ..];
    const norm_call_id = try normalizeIdPart(gpa, call_id);
    const is_foreign = !std.mem.eql(u8, source.provider, model.provider) or !apiEql(source.api, model.api);
    var norm_item_id: []const u8 = undefined;
    if (is_foreign) {
        norm_item_id = try buildForeignItemId(gpa, item_id);
    } else {
        norm_item_id = try normalizeIdPart(gpa, item_id);
    }
    if (!std.mem.startsWith(u8, norm_item_id, "fc_")) {
        const with_prefix = try std.fmt.allocPrint(gpa, "fc_{s}", .{norm_item_id});
        gpa.free(norm_item_id);
        norm_item_id = with_prefix;
    }
    const result = try std.fmt.allocPrint(gpa, "{s}|{s}", .{ norm_call_id, norm_item_id });
    gpa.free(norm_call_id);
    gpa.free(norm_item_id);
    return result;
}

fn apiEql(a: ai.Api, b: ai.Api) bool {
    return switch (a) {
        .known => |ak| switch (b) {
            .known => |bk| ak == bk,
            else => false,
        },
        .custom => |ac| switch (b) {
            .custom => |bc| std.mem.eql(u8, ac, bc),
            else => false,
        },
    };
}

pub fn convertResponsesMessages(gpa: std.mem.Allocator, model: ai.Model, context: ai.Context) !std.json.Value {
    const NormalizeFn = struct {
        fn f(id: []const u8, m: ai.Model, src: ai.AssistantMessage) []const u8 {
            return normalizeToolCallId(std.heap.page_allocator, id, m, src) catch id;
        }
    }.f;

    const msgs = try ai.transform_messages.transformMessages(gpa, context.messages, model, NormalizeFn);
    defer gpa.free(msgs);

    var input = std.json.Array{
        .items = std.ArrayList(std.json.Value).init(gpa),
        .capacity = msgs.len + 1,
    };

    if (context.system_prompt) |sp| {
        const role = if (model.reasoning) "developer" else "system";
        var obj = std.json.ObjectMap.init(gpa);
        try obj.put("role", .{ .string = role });
        try obj.put("content", .{ .string = sanitizeSurrogates(sp) });
        try input.append(.{ .object = obj });
    }

    var msg_index: usize = 0;
    for (msgs) |msg| {
        switch (msg) {
            .user => |u| {
                switch (u.content) {
                    .text => |t| {
                        var obj = std.json.ObjectMap.init(gpa);
                        try obj.put("role", .{ .string = "user" });
                        var arr = std.ArrayList(std.json.Value).init(gpa);
                        var part = std.json.ObjectMap.init(gpa);
                        try part.put("type", .{ .string = "input_text" });
                        try part.put("text", .{ .string = sanitizeSurrogates(t.text) });
                        try arr.append(.{ .object = part });
                        try obj.put("content", .{ .array = .{ .items = arr, .capacity = arr.items.len } });
                        try input.append(.{ .object = obj });
                    },
                    .blocks => |blocks| {
                        var parts = std.ArrayList(std.json.Value).init(gpa);
                        for (blocks) |block| {
                            switch (block) {
                                .text => |t| {
                                    var o = std.json.ObjectMap.init(gpa);
                                    try o.put("type", .{ .string = "input_text" });
                                    try o.put("text", .{ .string = sanitizeSurrogates(t.text) });
                                    try parts.append(.{ .object = o });
                                },
                                .image => |img| {
                                    if (!std.mem.containsAtLeast(u8, model.input, 1, "image")) continue;
                                    var o = std.json.ObjectMap.init(gpa);
                                    try o.put("type", .{ .string = "input_image" });
                                    try o.put("detail", .{ .string = "auto" });
                                    const url = try std.fmt.allocPrint(gpa, "data:{s};base64,{s}", .{ img.mime_type, img.data });
                                    try o.put("image_url", .{ .string = url });
                                    try parts.append(.{ .object = o });
                                },
                                else => {},
                            }
                        }
                        if (parts.items.len > 0) {
                            var obj = std.json.ObjectMap.init(gpa);
                            try obj.put("role", .{ .string = "user" });
                            try obj.put("content", .{ .array = .{ .items = parts, .capacity = parts.items.len } });
                            try input.append(.{ .object = obj });
                        }
                        parts.deinit();
                    },
                }
            },
            .assistant => |a| {
                _ = std.mem.eql(u8, a.provider, model.provider) and std.mem.eql(u8, a.model, model.id) and apiEql(a.api, model.api);
                var is_different_model = false;
                if (std.mem.eql(u8, a.provider, model.provider) and apiEql(a.api, model.api) and !std.mem.eql(u8, a.model, model.id)) {
                    is_different_model = true;
                }
                var output = std.ArrayList(std.json.Value).init(gpa);
                defer output.deinit();
                for (a.content) |block| {
                    switch (block) {
                        .thinking => |th| {
                            if (th.thinking_signature) |sig| {
                                const parsed = std.json.parseFromSlice(std.json.Value, gpa, sig, .{}) catch continue;
                                try output.append(parsed.value);
                            }
                        },
                        .text => |t| {
                            const parsed_sig = try parseTextSignature(gpa, t.text_signature);
                            var msg_id: []const u8 = undefined;
                            var id_owned: ?[]const u8 = null;
                            if (parsed_sig) |ps| {
                                if (ps.id.len <= 64) {
                                    msg_id = ps.id;
                                } else {
                                    id_owned = try std.fmt.allocPrint(gpa, "msg_{x}", .{shortHash(ps.id)});
                                    msg_id = id_owned.?;
                                }
                            } else {
                                id_owned = try std.fmt.allocPrint(gpa, "msg_{d}", .{msg_index});
                                msg_id = id_owned.?;
                            }
                            var obj = std.json.ObjectMap.init(gpa);
                            try obj.put("type", .{ .string = "message" });
                            try obj.put("role", .{ .string = "assistant" });
                            try obj.put("id", .{ .string = msg_id });
                            try obj.put("status", .{ .string = "completed" });
                            if (parsed_sig) |ps| {
                                if (ps.phase) |phase| try obj.put("phase", .{ .string = phase });
                            }
                            var content_arr = std.ArrayList(std.json.Value).init(gpa);
                            var txt_obj = std.json.ObjectMap.init(gpa);
                            try txt_obj.put("type", .{ .string = "output_text" });
                            try txt_obj.put("text", .{ .string = sanitizeSurrogates(t.text) });
                            try txt_obj.put("annotations", .{ .array = .{ .items = std.ArrayList(std.json.Value).init(gpa), .capacity = 0 } });
                            try content_arr.append(.{ .object = txt_obj });
                            try obj.put("content", .{ .array = .{ .items = content_arr, .capacity = content_arr.items.len } });
                            try output.append(.{ .object = obj });
                            if (id_owned) |io| gpa.free(io);
                        },
                        .tool_call => |tc| {
                            const pipe = std.mem.indexOfScalar(u8, tc.id, '|');
                            const call_id = if (pipe) |p| tc.id[0..p] else tc.id;
                            const item_id = if (pipe) |p| tc.id[p + 1 ..] else "";
                            const eff_item_id = if (is_different_model and std.mem.startsWith(u8, item_id, "fc_")) null else item_id;
                            var obj = std.json.ObjectMap.init(gpa);
                            try obj.put("type", .{ .string = "function_call" });
                            try obj.put("call_id", .{ .string = call_id });
                            if (eff_item_id) |eid| {
                                try obj.put("id", .{ .string = eid });
                            }
                            try obj.put("name", .{ .string = tc.name });
                            const args_str = jsonStringifyValue(gpa, tc.arguments) catch "{}";
                            try obj.put("arguments", .{ .string = args_str });
                            try output.append(.{ .object = obj });
                        },
                        else => {},
                    }
                }
                if (output.items.len > 0) {
                    for (output.items) |item| {
                        try input.append(item);
                    }
                }
            },
            .tool_result => |tr| {
                const call_id = blk: {
                    const idx = std.mem.indexOfScalar(u8, tr.tool_call_id, '|');
                    if (idx) |i| break :blk tr.tool_call_id[0..i];
                    break :blk tr.tool_call_id;
                };
                var text_parts = std.ArrayList([]const u8).init(gpa);
                var has_images = false;
                for (tr.content) |block| {
                    switch (block) {
                        .text => |t| try text_parts.append(t.text),
                        .image => has_images = true,
                        else => {},
                    }
                }
                const text_result = try std.mem.join(gpa, "\n", text_parts.items);
                text_parts.deinit();

                var obj = std.json.ObjectMap.init(gpa);
                try obj.put("type", .{ .string = "function_call_output" });
                try obj.put("call_id", .{ .string = call_id });

                if (has_images and std.mem.containsAtLeast(u8, model.input, 1, "image")) {
                    var out_arr = std.ArrayList(std.json.Value).init(gpa);
                    if (text_result.len > 0) {
                        var o = std.json.ObjectMap.init(gpa);
                        try o.put("type", .{ .string = "input_text" });
                        try o.put("text", .{ .string = sanitizeSurrogates(text_result) });
                        try out_arr.append(.{ .object = o });
                    }
                    for (tr.content) |block| {
                        if (block == .image) {
                            const img = block.image;
                            var o = std.json.ObjectMap.init(gpa);
                            try o.put("type", .{ .string = "input_image" });
                            try o.put("detail", .{ .string = "auto" });
                            const url = try std.fmt.allocPrint(gpa, "data:{s};base64,{s}", .{ img.mime_type, img.data });
                            try o.put("image_url", .{ .string = url });
                            try out_arr.append(.{ .object = o });
                        }
                    }
                    try obj.put("output", .{ .array = .{ .items = out_arr, .capacity = out_arr.items.len } });
                } else {
                    const result_text = if (text_result.len > 0) sanitizeSurrogates(text_result) else "(see attached image)";
                    try obj.put("output", .{ .string = result_text });
                }
                try input.append(.{ .object = obj });
            },
        }
        msg_index += 1;
    }

    return std.json.Value{ .array = input };
}

pub fn convertResponsesTools(gpa: std.mem.Allocator, tools: []const ai.Tool) !std.json.Value {
    var arr = std.ArrayList(std.json.Value).init(gpa);
    for (tools) |tool| {
        var obj = std.json.ObjectMap.init(gpa);
        try obj.put("type", .{ .string = "function" });
        try obj.put("name", .{ .string = tool.name });
        try obj.put("description", .{ .string = tool.description });
        try obj.put("parameters", tool.parameters);
        try obj.put("strict", .{ .bool = false });
        try arr.append(.{ .object = obj });
    }
    return std.json.Value{ .array = .{ .items = arr, .capacity = arr.items.len } };
}

fn getApiKey(model: ai.Model, options_api_key: ?[]const u8) ?[]const u8 {
    _ = model;
    if (options_api_key) |k| return k;
    return std.process.getEnvVarOwned(std.heap.page_allocator, "OPENAI_API_KEY") catch null;
}

fn buildParams(gpa: std.mem.Allocator, model: ai.Model, context: ai.Context, options: ?ai.StreamOptions) !std.json.Value {
    const input = try convertResponsesMessages(gpa, model, context);

    var obj = std.json.ObjectMap.init(gpa);
    try obj.put("model", .{ .string = model.id });
    try obj.put("input", input);
    try obj.put("stream", .{ .bool = true });
    try obj.put("store", .{ .bool = options.?.store orelse false });

    const opts = options orelse ai.StreamOptions{};
    const cache_retention = resolveCacheRetention(opts.cache_retention);

    if (cache_retention != .none) {
        if (opts.session_id) |sid| {
            try obj.put("prompt_cache_key", .{ .string = sid });
        }
        if (getPromptCacheRetention(model.base_url orelse "", cache_retention)) |pcr| {
            try obj.put("prompt_cache_retention", .{ .string = pcr });
        }
    }

    if (opts.max_tokens) |mt| {
        try obj.put("max_output_tokens", .{ .integer = mt });
    }
    if (opts.temperature) |t| {
        try obj.put("temperature", .{ .float = t });
    }
    if (opts.service_tier) |st| {
        try obj.put("service_tier", .{ .string = st });
    }
    if (opts.top_p) |tp| {
        try obj.put("top_p", .{ .float = tp });
    }

    if (context.tools) |tools| {
        try obj.put("tools", try convertResponsesTools(gpa, tools));
    }

    if (model.reasoning) {
        const has_reasoning = opts.reasoning_effort != null or opts.reasoning_summary != null;
        if (has_reasoning) {
            var ro = std.json.ObjectMap.init(gpa);
            try ro.put("effort", .{ .string = opts.reasoning_effort orelse "medium" });
            try ro.put("summary", .{ .string = opts.reasoning_summary orelse "auto" });
            try obj.put("reasoning", .{ .object = ro });
            var include_arr = std.ArrayList(std.json.Value).init(gpa);
            try include_arr.append(.{ .string = "reasoning.encrypted_content" });
            try obj.put("include", .{ .array = .{ .items = include_arr, .capacity = 1 } });
        } else if (!std.mem.eql(u8, model.provider, "github-copilot")) {
            var ro = std.json.ObjectMap.init(gpa);
            try ro.put("effort", .{ .string = "none" });
            try obj.put("reasoning", .{ .object = ro });
        }
    }

    return std.json.Value{ .object = obj };
}

pub fn mapStopReason(status: []const u8) ai.StopReason {
    if (std.mem.eql(u8, status, "completed")) return .stop;
    if (std.mem.eql(u8, status, "incomplete")) return .length;
    if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "cancelled")) return .err;
    return .stop;
}

pub fn parseSseLine(line: []const u8) ?std.json.Value {
    const prefix = "data:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    const data = std.mem.trim(u8, if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest, " \r\n");
    if (std.mem.eql(u8, data, "[DONE]")) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch return null;
    return parsed.value;
}

fn getServiceTierCostMultiplier(service_tier: ?[]const u8) f32 {
    if (service_tier) |st| {
        if (std.mem.eql(u8, st, "flex")) return 0.5;
        if (std.mem.eql(u8, st, "priority")) return 2.0;
    }
    return 1.0;
}

fn applyServiceTierPricing(usage: *ai.Usage, service_tier: ?[]const u8) void {
    const multiplier = getServiceTierCostMultiplier(service_tier);
    if (multiplier == 1.0) return;
    usage.cost.input *= multiplier;
    usage.cost.output *= multiplier;
    usage.cost.cache_read *= multiplier;
    usage.cost.cache_write *= multiplier;
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
}

pub fn streamOpenAIResponses(model: ai.Model, context: ai.Context, options: ?ai.StreamOptions) ai.AssistantMessageEventStream {
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

    const thread = std.Thread.spawn(.{}, openaiResponsesThread, .{ model, context, options, api_key, output, es }) catch |err| {
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

fn openaiResponsesThread(model: ai.Model, context: ai.Context, options: ?ai.StreamOptions, api_key: []const u8, output: ai.AssistantMessage, es: ai.AssistantMessageEventStream) void {
    const gpa = std.heap.page_allocator;
    const client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    const base_url = model.base_url orelse "https://api.openai.com";
    const url = std.fmt.allocPrint(gpa, "{s}/v1/responses", .{base_url}) catch {
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
    extra_headers.append(.{ .name = "Accept", .value = "text/event-stream" }) catch {};

    // Merge model.headers
    if (model.headers) |mh| {
        var it = mh.object.iterator();
        while (it.next()) |entry| {
            const val = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
            extra_headers.append(.{ .name = entry.key_ptr.*, .value = val }) catch {};
        }
    }

    // GitHub Copilot dynamic headers
    if (std.mem.eql(u8, model.provider, "github-copilot")) {
        const initiator = blk: {
            if (context.messages.len > 0) {
                const last = context.messages[context.messages.len - 1];
                if (last != .user) break :blk "agent";
            }
            break :blk "user";
        };
        extra_headers.append(.{ .name = "X-Initiator", .value = initiator }) catch {};
        extra_headers.append(.{ .name = "Openai-Intent", .value = "conversation-edits" }) catch {};
        const has_images = blk: {
            for (context.messages) |msg| {
                switch (msg) {
                    .user => |u| {
                        if (u.content == .blocks) {
                            for (u.content.blocks) |b| {
                                if (b == .image) break :blk true;
                            }
                        }
                    },
                    .tool_result => |tr| {
                        for (tr.content) |b| {
                            if (b == .image) break :blk true;
                        }
                    },
                    else => {},
                }
            }
            break :blk false;
        };
        if (has_images) {
            extra_headers.append(.{ .name = "Copilot-Vision-Request", .value = "true" }) catch {};
        }
    }

    // Merge options.headers last so they override
    if (options) |opts| {
        if (opts.headers) |oh| {
            var it = oh.object.iterator();
            while (it.next()) |entry| {
                const val = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
                extra_headers.append(.{ .name = entry.key_ptr.*, .value = val }) catch {};
            }
        }
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const fetch_res = client.fetch(aa, .{
        .location = .{ .url = url },
        .method = .POST,
        .extra_headers = extra_headers.items,
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
                    processResponsesSseLine(gpa, line, &output, es, model);
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

pub fn processResponsesSseLine(gpa: std.mem.Allocator, line: []const u8, output: *ai.AssistantMessage, es: ai.AssistantMessageEventStream, model: ai.Model) void {
    const event = parseSseLine(line) orelse return;
    const event_type = if (event.object.get("type")) |tv| (if (tv == .string) tv.string else "") else "";

    if (std.mem.eql(u8, event_type, "response.created")) {
        if (event.object.get("response")) |rv| {
            if (rv.object.get("id")) |idv| {
                if (idv == .string) output.response_id = idv.string;
            }
        }
    } else if (std.mem.eql(u8, event_type, "response.output_item.added")) {
        if (event.object.get("item")) |item| {
            const item_type = if (item.object.get("type")) |tv| (if (tv == .string) tv.string else "") else "";
            if (std.mem.eql(u8, item_type, "reasoning")) {
                appendContentBlock(gpa, output, .{ .thinking = .{ .thinking = "" } });
                es.push(.{ .thinking_start = .{ .content_index = output.content.len - 1, .partial = output.* } }) catch {};
            } else if (std.mem.eql(u8, item_type, "message")) {
                appendContentBlock(gpa, output, .{ .text = .{ .text = "" } });
                es.push(.{ .text_start = .{ .content_index = output.content.len - 1, .partial = output.* } }) catch {};
            } else if (std.mem.eql(u8, item_type, "function_call")) {
                const call_id = if (item.object.get("call_id")) |cv| (if (cv == .string) cv.string else "") else "";
                const item_id = if (item.object.get("id")) |iv| (if (iv == .string) iv.string else "") else "";
                const name = if (item.object.get("name")) |nv| (if (nv == .string) nv.string else "") else "";
                const id_full = std.fmt.allocPrint(gpa, "{s}|{s}", .{ call_id, item_id }) catch "||";
                appendContentBlock(gpa, output, .{ .tool_call = .{ .id = id_full, .name = name, .arguments = .{ .object = std.json.ObjectMap.init(gpa) } } });
                es.push(.{ .toolcall_start = .{ .content_index = output.content.len - 1, .partial = output.* } }) catch {};
            }
        }
    } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.added")) {
        // TODO: track summary parts on current reasoning item
    } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta")) {
        if (output.content.len == 0) return;
        const idx = output.content.len - 1;
        if (output.content[idx] == .thinking) {
            if (event.object.get("delta")) |dv| {
                if (dv == .string) {
                    output.content[idx].thinking.thinking = std.fmt.allocPrint(gpa, "{s}{s}", .{ output.content[idx].thinking.thinking, dv.string }) catch output.content[idx].thinking.thinking;
                    es.push(.{ .thinking_delta = .{ .content_index = idx, .delta = dv.string, .partial = output.* } }) catch {};
                }
            }
        }
    } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.done")) {
        if (output.content.len == 0) return;
        const idx = output.content.len - 1;
        if (output.content[idx] == .thinking) {
            output.content[idx].thinking.thinking = std.fmt.allocPrint(gpa, "{s}\n\n", .{output.content[idx].thinking.thinking}) catch output.content[idx].thinking.thinking;
            es.push(.{ .thinking_delta = .{ .content_index = idx, .delta = "\n\n", .partial = output.* } }) catch {};
        }
    } else if (std.mem.eql(u8, event_type, "response.content_part.added")) {
        // content parts tracked implicitly
    } else if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
        if (output.content.len == 0) return;
        const idx = output.content.len - 1;
        if (output.content[idx] == .text) {
            if (event.object.get("delta")) |dv| {
                if (dv == .string) {
                    output.content[idx].text.text = std.fmt.allocPrint(gpa, "{s}{s}", .{ output.content[idx].text.text, dv.string }) catch output.content[idx].text.text;
                    es.push(.{ .text_delta = .{ .content_index = idx, .delta = dv.string, .partial = output.* } }) catch {};
                }
            }
        }
    } else if (std.mem.eql(u8, event_type, "response.refusal.delta")) {
        if (output.content.len == 0) return;
        const idx = output.content.len - 1;
        if (output.content[idx] == .text) {
            if (event.object.get("delta")) |dv| {
                if (dv == .string) {
                    output.content[idx].text.text = std.fmt.allocPrint(gpa, "{s}{s}", .{ output.content[idx].text.text, dv.string }) catch output.content[idx].text.text;
                    es.push(.{ .text_delta = .{ .content_index = idx, .delta = dv.string, .partial = output.* } }) catch {};
                }
            }
        }
    } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
        if (output.content.len == 0) return;
        const idx = output.content.len - 1;
        if (output.content[idx] == .tool_call) {
            if (event.object.get("delta")) |dv| {
                if (dv == .string) {
                    es.push(.{ .toolcall_delta = .{ .content_index = idx, .delta = dv.string, .partial = output.* } }) catch {};
                }
            }
        }
    } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
        if (output.content.len == 0) return;
        const idx = output.content.len - 1;
        if (output.content[idx] == .tool_call) {
            if (event.object.get("arguments")) |av| {
                if (av == .string) {
                    const parsed = std.json.parseFromSlice(std.json.Value, gpa, av.string, .{}) catch output.content[idx].tool_call.arguments;
                    output.content[idx].tool_call.arguments = parsed.value;
                }
            }
        }
    } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
        if (output.content.len == 0) return;
        const idx = output.content.len - 1;
        if (event.object.get("item")) |item| {
            const item_type = if (item.object.get("type")) |tv| (if (tv == .string) tv.string else "") else "";
            if (std.mem.eql(u8, item_type, "reasoning")) {
                if (output.content[idx] == .thinking) {
                    var summary_text = std.ArrayList(u8).init(gpa);
                    if (item.object.get("summary")) |sarr| {
                        if (sarr == .array) {
                            for (sarr.array.items) |part| {
                                if (part.object.get("text")) |tv| {
                                    if (tv == .string) {
                                        if (summary_text.items.len > 0) try summary_text.appendSlice("\n\n");
                                        try summary_text.appendSlice(tv.string);
                                    }
                                }
                            }
                        }
                    }
                    const sig_str = jsonStringifyValue(gpa, item) catch "";
                    output.content[idx].thinking.thinking = summary_text.items;
                    output.content[idx].thinking.thinking_signature = sig_str;
                    es.push(.{ .thinking_end = .{ .content_index = idx, .content = summary_text.items, .partial = output.* } }) catch {};
                }
            } else if (std.mem.eql(u8, item_type, "message")) {
                if (output.content[idx] == .text) {
                    const item_id = if (item.object.get("id")) |iv| (if (iv == .string) iv.string else "") else "";
                    const phase = if (item.object.get("phase")) |pv| (if (pv == .string) pv.string else null) else null;
                    const sig_str = encodeTextSignatureV1(gpa, item_id, phase) catch null;
                    output.content[idx].text.text_signature = sig_str;
                    es.push(.{ .text_end = .{ .content_index = idx, .content = output.content[idx].text.text, .partial = output.* } }) catch {};
                }
            } else if (std.mem.eql(u8, item_type, "function_call")) {
                if (output.content[idx] == .tool_call) {
                    if (item.object.get("arguments")) |av| {
                        if (av == .string) {
                            const parsed = std.json.parseFromSlice(std.json.Value, gpa, av.string, .{}) catch output.content[idx].tool_call.arguments;
                            output.content[idx].tool_call.arguments = parsed.value;
                        }
                    }
                }
                es.push(.{ .toolcall_end = .{ .content_index = idx, .tool_call = output.content[idx].tool_call, .partial = output.* } }) catch {};
            }
        }
    } else if (std.mem.eql(u8, event_type, "response.completed")) {
        if (event.object.get("response")) |rv| {
            if (rv.object.get("id")) |idv| {
                if (idv == .string) output.response_id = idv.string;
            }
            if (rv.object.get("usage")) |usage| {
                const input_tokens = if (usage.object.get("input_tokens")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;
                const cached_tokens: u32 = blk: {
                    if (usage.object.get("input_tokens_details")) |d| {
                        if (d.object.get("cached_tokens")) |cv| {
                            break :blk if (cv == .integer) @as(u32, @intCast(cv.integer)) else 0;
                        }
                    }
                    break :blk 0;
                };
                const output_tokens = if (usage.object.get("output_tokens")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;
                const total_tokens = if (usage.object.get("total_tokens")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;
                output.usage = .{
                    .input = if (input_tokens > cached_tokens) input_tokens - cached_tokens else 0,
                    .output = output_tokens,
                    .cache_read = cached_tokens,
                    .cache_write = 0,
                    .total_tokens = total_tokens,
                };
                ai.calculateCost(model, &output.usage);
                const service_tier = blk: {
                    if (rv.object.get("service_tier")) |sv| {
                        if (sv == .string) break :blk sv.string;
                    }
                    break :blk null;
                };
                applyServiceTierPricing(&output.usage, service_tier);
            }
            if (rv.object.get("status")) |sv| {
                if (sv == .string) {
                    output.stop_reason = mapStopReason(sv.string);
                }
            }
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
    } else if (std.mem.eql(u8, event_type, "error")) {
        const code = if (event.object.get("code")) |v| (if (v == .string) v.string else "unknown") else "unknown";
        const msg = if (event.object.get("message")) |v| (if (v == .string) v.string else "Unknown error") else "Unknown error";
        output.error_message = std.fmt.allocPrint(gpa, "Error Code {s}: {s}", .{ code, msg }) catch "Unknown error";
        output.stop_reason = .err;
    } else if (std.mem.eql(u8, event_type, "response.failed")) {
        var err_msg: []const u8 = "Unknown error (no error details in response)";
        if (event.object.get("response")) |res| {
            if (res.object.get("error")) |err_obj| {
                const ec = if (err_obj.object.get("code")) |cv| (if (cv == .string) cv.string else "unknown") else "unknown";
                const em = if (err_obj.object.get("message")) |mv| (if (mv == .string) mv.string else "no message") else "no message";
                err_msg = std.fmt.allocPrint(gpa, "{s}: {s}", .{ ec, em }) catch err_msg;
            } else if (res.object.get("incomplete_details")) |idetails| {
                const reason = if (idetails.object.get("reason")) |rv| (if (rv == .string) rv.string else null) else null;
                if (reason) |r| {
                    err_msg = std.fmt.allocPrint(gpa, "incomplete: {s}", .{r}) catch err_msg;
                }
            }
        }
        output.stop_reason = .err;
        output.error_message = err_msg;
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

pub fn streamSimpleOpenAIResponses(model: ai.Model, context: ai.Context, options: ?ai.types.SimpleStreamOptions) ai.AssistantMessageEventStream {
    const api_key = getApiKey(model, if (options) |o| o.base.api_key else null);
    const base = ai.simple_options.buildBaseOptions(model, options, api_key);
    const reasoning_effort = if (ai.supportsXhigh(model)) (if (options) |o| o.reasoning else null) else ai.simple_options.clampReasoning(if (options) |o| o.reasoning else null);
    const reasoning_summary: ?[]const u8 = null;

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
    if (reasoning_summary) |rs| {
        stream_opts.reasoning_summary = rs;
    }
    return streamOpenAIResponses(model, context, stream_opts);
}



pub fn registerOpenAIResponsesProvider() void {
    ai.registerApiProvider(.{
        .api = .{ .known = .openai_responses },
        .stream = streamOpenAIResponses,
        .stream_simple = streamSimpleOpenAIResponses,
    });
}

test "openai_responses provider compiles and registers" {
    registerOpenAIResponsesProvider();
}

test "buildParams includes reasoning and include fields" {
    const gpa = std.testing.allocator;
    const model = ai.Model{
        .id = "gpt-5",
        .name = "GPT-5",
        .api = .{ .known = .openai_responses },
        .provider = .{ .known = .openai },
        .reasoning = true,
        .max_tokens = 32000,
    };
    const opts = ai.StreamOptions{ .reasoning_effort = "high", .reasoning_summary = "detailed" };
    const params = try buildParams(gpa, model, ai.Context{ .messages = &[_]ai.Message{} }, opts);
    defer {
        // We do not deep-free the JSON Value to keep tests short-lived
    }
    if (params.object.get("reasoning")) |rv| {
        try std.testing.expect(rv.object.get("effort").?.string[0] == 'h');
    } else {
        return error.MissingReasoning;
    }
    if (params.object.get("include")) |iv| {
        try std.testing.expectEqualStrings("reasoning.encrypted_content", iv.array.items[0].string);
    } else {
        return error.MissingInclude;
    }
}

test "normalizeToolCallId splits and normalizes OpenAI-style ids" {
    const gpa = std.testing.allocator;
    const model = ai.Model{
        .id = "gpt-5",
        .name = "GPT-5",
        .api = .{ .known = .openai_responses },
        .provider = .{ .known = .openai },
        .max_tokens = 32000,
    };
    const source = ai.AssistantMessage{ .role = "assistant", .content = &[_]ai.ContentBlock{}, .api = model.api, .provider = model.provider, .model = model.id, .usage = .{}, .stop_reason = .stop, .timestamp = 0 };
    const id = "call_abc|item_xyz";
    const result = try normalizeToolCallId(gpa, id, model, source);
    defer gpa.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "call_abc|fc_"));
}

test "encodeTextSignatureV1 roundtrip" {
    const gpa = std.testing.allocator;
    const sig = try encodeTextSignatureV1(gpa, "msg_123", "commentary");
    defer gpa.free(sig);
    const parsed = try parseTextSignature(gpa, sig);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqualStrings("msg_123", parsed.?.id);
    try std.testing.expectEqualStrings("commentary", parsed.?.phase.?);
}
