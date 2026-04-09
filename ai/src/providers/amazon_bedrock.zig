const std = @import("std");
const ai = @import("../root.zig");

// =============================================================================
// AWS SigV4 Helpers
// =============================================================================
fn hmacSha256(key: []const u8, msg: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&out, msg, key);
    return out;
}

fn sha256Hash(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

fn hexDigest(hash_bytes: [32]u8, out: *[64]u8) void {
    _ = std.fmt.bufPrint(out, "{s}", .{std.fmt.fmtSliceHexLower(&hash_bytes)}) catch {};
}

fn getSignatureKey(secret_key: []const u8, date_stamp: []const u8, region: []const u8, service: []const u8) [32]u8 {
    const gpa = std.heap.page_allocator;
    const k_secret = std.mem.concat(gpa, u8, &.{ "AWS4", secret_key }) catch return .{};
    defer gpa.free(k_secret);
    const k_date = hmacSha256(k_secret, date_stamp);
    const k_region = hmacSha256(&k_date, region);
    const k_service = hmacSha256(&k_region, service);
    const k_signing = hmacSha256(&k_service, "aws4_request");
    return k_signing;
}

fn signRequest(gpa: std.mem.Allocator, method: []const u8, uri: []const u8, query: []const u8, host: []const u8, payload: []const u8, access_key: []const u8, secret_key: []const u8, session_token: ?[]const u8, region: []const u8, amz_date: []const u8, date_stamp: []const u8) ![]const u8 {
    var canonical_headers_buf: [4096]u8 = undefined;
    var signed_headers: []const u8 = "host;x-amz-date";
    var ch_end: usize = 0;
    ch_end += (std.fmt.bufPrint(canonical_headers_buf[ch_end..], "host:{s}\nx-amz-date:{s}\n", .{ host, amz_date }) catch "").len;
    if (session_token) |st| {
        ch_end += (std.fmt.bufPrint(canonical_headers_buf[ch_end..], "x-amz-security-token:{s}\n", .{st}) catch "").len;
        signed_headers = "host;x-amz-date;x-amz-security-token";
    }
    const canonical_headers = canonical_headers_buf[0..ch_end];

    var payload_hash: [64]u8 = undefined;
    hexDigest(sha256Hash(payload), &payload_hash);

    var cr_buf: [8192]u8 = undefined;
    const canonical_request = std.fmt.bufPrint(&cr_buf, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{ method, uri, query, canonical_headers, signed_headers, payload_hash }) catch return error.FormatError;

    var cr_hash: [64]u8 = undefined;
    hexDigest(sha256Hash(canonical_request), &cr_hash);

    const scope = try std.fmt.allocPrint(gpa, "{s}/{s}/bedrock/aws4_request", .{ date_stamp, region });
    defer gpa.free(scope);

    var sts_buf: [4096]u8 = undefined;
    const string_to_sign = std.fmt.bufPrint(&sts_buf, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ amz_date, scope, cr_hash }) catch return error.FormatError;

    const sig_key = getSignatureKey(secret_key, date_stamp, region, "bedrock");
    const sig = hmacSha256(&sig_key, string_to_sign);
    var sig_hex: [64]u8 = undefined;
    hexDigest(sig, &sig_hex);

    return std.fmt.allocPrint(gpa, "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}", .{ access_key, scope, signed_headers, sig_hex });
}

// =============================================================================
// Event Stream Parser (simplified: operates on full byte array)
// =============================================================================
const EventFrame = struct {
    event_type: []const u8,
    payload: std.json.Value,
};

fn parseEventStream(gpa: std.mem.Allocator, data: []const u8) !std.ArrayList(EventFrame) {
    var frames = std.ArrayList(EventFrame).init(gpa);
    var offset: usize = 0;
    while (offset + 12 <= data.len) {
        const total_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        const headers_len = std.mem.readInt(u32, data[offset + 4 ..][0..4], .big);
        if (total_len < 16 or offset + total_len > data.len) break;

        const payload_start = offset + 12 + headers_len;
        const payload_end = offset + total_len - 4;
        if (payload_start > payload_end) break;

        const payload = data[payload_start..payload_end];

        // Parse headers to find :event-type
        var event_type: []const u8 = "";
        var hoff: usize = offset + 12;
        const h_end = payload_start;
        while (hoff < h_end) {
            const name_len = data[hoff];
            hoff += 1;
            const name = data[hoff..hoff + name_len];
            hoff += name_len;
            const htype = data[hoff];
            hoff += 1;
            switch (htype) {
                0x01 => { hoff += 0; }, // bool true
                0x02 => { hoff += 0; }, // bool false
                0x07 => { hoff += 4; }, // int32
                0x08 => { hoff += 8; }, // int64
                0x0c => { const vlen = std.mem.readInt(u16, data[hoff..][0..2], .big); hoff += 2 + vlen; }, // bytes
                0x0d => {
                    const vlen = std.mem.readInt(u16, data[hoff..][0..2], .big);
                    hoff += 2;
                    const val = data[hoff..hoff + vlen];
                    hoff += vlen;
                    if (std.mem.eql(u8, name, ":event-type")) {
                        event_type = try gpa.dupe(u8, val);
                    }
                },
                else => break,
            }
        }

        if (event_type.len > 0 and payload.len > 0) {
            const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload, .{}) catch null;
            if (parsed) |p| {
                try frames.append(.{ .event_type = event_type, .payload = p.value });
            }
        }
        offset += total_len;
    }
    return frames;
}

// =============================================================================
// Request Building
// =============================================================================
fn resolveCacheRetention(cache_retention: ?ai.CacheRetention) ai.CacheRetention {
    if (cache_retention) |cr| return cr;
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "PI_CACHE_RETENTION")) |v| {
        defer std.heap.page_allocator.free(v);
        if (std.mem.eql(u8, v, "long")) return .long;
    } else |_| {}
    return .short;
}

fn supportsPromptCaching(model: ai.Model) bool {
    const id = std.asciiLowerStringStack(model.id);
    if (!std.mem.containsAtLeast(u8, id, 1, "claude")) {
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "AWS_BEDROCK_FORCE_CACHE")) |v| {
            defer std.heap.page_allocator.free(v);
            if (std.mem.eql(u8, v, "1")) return true;
        } else |_| {}
        return false;
    }
    if (std.mem.containsAtLeast(u8, id, 1, "-4-") or std.mem.containsAtLeast(u8, id, 1, "-4.")) return true;
    if (std.mem.containsAtLeast(u8, id, 1, "claude-3-7-sonnet")) return true;
    if (std.mem.containsAtLeast(u8, id, 1, "claude-3-5-haiku")) return true;
    return false;
}

fn supportsThinkingSignature(model: ai.Model) bool {
    const id = std.asciiLowerStringStack(model.id);
    return std.mem.containsAtLeast(u8, id, 1, "anthropic.claude") or std.mem.containsAtLeast(u8, id, 1, "anthropic/claude");
}

fn mapImageFormat(mime_type: []const u8) []const u8 {
    if (std.mem.eql(u8, mime_type, "image/jpeg") or std.mem.eql(u8, mime_type, "image/jpg")) return "jpeg";
    if (std.mem.eql(u8, mime_type, "image/png")) return "png";
    if (std.mem.eql(u8, mime_type, "image/gif")) return "gif";
    if (std.mem.eql(u8, mime_type, "image/webp")) return "webp";
    return "png";
}

fn normalizeToolCallId(id: []const u8) []const u8 {
    const result = normalizeToolCallIdAlloc(std.heap.page_allocator, id) catch id;
    return result;
}

fn normalizeToolCallIdAlloc(gpa: std.mem.Allocator, id: []const u8) ![]const u8 {
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

fn buildSystemPrompt(gpa: std.mem.Allocator, system_prompt: ?[]const u8, model: ai.Model, cache_retention: ai.CacheRetention) ?std.json.Value {
    const sp = system_prompt orelse return null;
    var blocks = std.ArrayList(std.json.Value).init(gpa);
    var txt = std.json.ObjectMap.init(gpa);
    try txt.put("text", .{ .string = sp });
    try blocks.append(.{ .object = txt });
    if (cache_retention != .none and supportsPromptCaching(model)) {
        var cp = std.json.ObjectMap.init(gpa);
        try cp.put("cachePoint", .{ .object = blk: {
            var o = std.json.ObjectMap.init(gpa);
            try o.put("type", .{ .string = "default" });
            break :blk o;
        } });
        try blocks.append(.{ .object = cp });
    }
    return std.json.Value{ .array = .{ .items = blocks, .capacity = blocks.items.len } };
}

fn convertMessages(gpa: std.mem.Allocator, model: ai.Model, context: ai.Context, cache_retention: ai.CacheRetention) !std.json.Value {
    const norm_fn = struct {
        fn f(id: []const u8, _m: ai.Model, _src: ai.AssistantMessage) []const u8 {
            _ = _m;
            _ = _src;
            return normalizeToolCallIdAlloc(std.heap.page_allocator, id) catch id;
        }
    }.f;
    const msgs = try ai.transform_messages.transformMessages(gpa, context.messages, model, norm_fn);
    defer gpa.free(msgs);

    var result = std.ArrayList(std.json.Value).init(gpa);
    var i: usize = 0;
    while (i < msgs.len) : (i += 1) {
        const m = msgs[i];
        switch (m) {
            .user => |u| {
                var content = std.ArrayList(std.json.Value).init(gpa);
                switch (u.content) {
                    .text => |t| {
                        var obj = std.json.ObjectMap.init(gpa);
                        try obj.put("text", .{ .string = t.text });
                        try content.append(.{ .object = obj });
                    },
                    .blocks => |blocks| {
                        for (blocks) |b| {
                            switch (b) {
                                .text => |t| {
                                    var obj = std.json.ObjectMap.init(gpa);
                                    try obj.put("text", .{ .string = t.text });
                                    try content.append(.{ .object = obj });
                                },
                                .image => |img| {
                                    var obj = std.json.ObjectMap.init(gpa);
                                    try obj.put("image", .{ .object = blk: {
                                        var o = std.json.ObjectMap.init(gpa);
                                        try o.put("format", .{ .string = mapImageFormat(img.mime_type) });
                                        try o.put("source", .{ .object = blk2: {
                                            var o2 = std.json.ObjectMap.init(gpa);
                                            try o2.put("bytes", .{ .string = img.data });
                                            break :blk2 o2;
                                        } });
                                        break :blk o;
                                    } });
                                    try content.append(.{ .object = obj });
                                },
                                else => {},
                            }
                        }
                    },
                }
                var msg = std.json.ObjectMap.init(gpa);
                try msg.put("role", .{ .string = "user" });
                try msg.put("content", .{ .array = .{ .items = content, .capacity = content.items.len } });
                try result.append(.{ .object = msg });
            },
            .assistant => |a| {
                if (a.content.len == 0) continue;
                var content = std.ArrayList(std.json.Value).init(gpa);
                for (a.content) |c| {
                    switch (c) {
                        .text => |t| {
                            if (t.text.len == 0 or std.mem.trim(u8, t.text, " \t\r\n").len == 0) continue;
                            var obj = std.json.ObjectMap.init(gpa);
                            try obj.put("text", .{ .string = t.text });
                            try content.append(.{ .object = obj });
                        },
                        .tool_call => |tc| {
                            var obj = std.json.ObjectMap.init(gpa);
                            try obj.put("toolUse", .{ .object = blk: {
                                var o = std.json.ObjectMap.init(gpa);
                                try o.put("toolUseId", .{ .string = tc.id });
                                try o.put("name", .{ .string = tc.name });
                                try o.put("input", tc.arguments);
                                break :blk o;
                            } });
                            try content.append(.{ .object = obj });
                        },
                        .thinking => |th| {
                            if (th.thinking.len == 0 or std.mem.trim(u8, th.thinking, " \t\r\n").len == 0) continue;
                            if (supportsThinkingSignature(model) and th.thinking_signature != null and th.thinking_signature.?.len > 0) {
                                var obj = std.json.ObjectMap.init(gpa);
                                try obj.put("reasoningContent", .{ .object = blk: {
                                    var o = std.json.ObjectMap.init(gpa);
                                    try o.put("reasoningText", .{ .object = blk2: {
                                        var o2 = std.json.ObjectMap.init(gpa);
                                        try o2.put("text", .{ .string = th.thinking });
                                        try o2.put("signature", .{ .string = th.thinking_signature.? });
                                        break :blk2 o2;
                                    } });
                                    break :blk o;
                                } });
                                try content.append(.{ .object = obj });
                            } else {
                                var obj = std.json.ObjectMap.init(gpa);
                                try obj.put("reasoningContent", .{ .object = blk: {
                                    var o = std.json.ObjectMap.init(gpa);
                                    try o.put("reasoningText", .{ .object = blk2: {
                                        var o2 = std.json.ObjectMap.init(gpa);
                                        try o2.put("text", .{ .string = th.thinking });
                                        break :blk2 o2;
                                    } });
                                    break :blk o;
                                } });
                                try content.append(.{ .object = obj });
                            }
                        },
                        else => {},
                    }
                }
                if (content.items.len == 0) continue;
                var msg = std.json.ObjectMap.init(gpa);
                try msg.put("role", .{ .string = "assistant" });
                try msg.put("content", .{ .array = .{ .items = content, .capacity = content.items.len } });
                try result.append(.{ .object = msg });
            },
            .tool_result => {
                var tool_results = std.ArrayList(std.json.Value).init(gpa);
                // collect consecutive tool results
                var j = i;
                while (j < msgs.len and msgs[j] == .tool_result) : (j += 1) {
                    const tm = msgs[j].tool_result;
                    var tr_content = std.ArrayList(std.json.Value).init(gpa);
                    for (tm.content) |b| {
                        switch (b) {
                            .text => |t| {
                                var obj = std.json.ObjectMap.init(gpa);
                                try obj.put("text", .{ .string = t.text });
                                try tr_content.append(.{ .object = obj });
                            },
                            .image => |img| {
                                var obj = std.json.ObjectMap.init(gpa);
                                try obj.put("image", .{ .object = blk: {
                                    var o = std.json.ObjectMap.init(gpa);
                                    try o.put("format", .{ .string = mapImageFormat(img.mime_type) });
                                    try o.put("source", .{ .object = blk2: {
                                        var o2 = std.json.ObjectMap.init(gpa);
                                        try o2.put("bytes", .{ .string = img.data });
                                        break :blk2 o2;
                                    } });
                                    break :blk o;
                                } });
                                try tr_content.append(.{ .object = obj });
                            },
                            else => {},
                        }
                    }
                    var obj = std.json.ObjectMap.init(gpa);
                    try obj.put("toolResult", .{ .object = blk: {
                        var o = std.json.ObjectMap.init(gpa);
                        try o.put("toolUseId", .{ .string = tm.tool_call_id });
                        try o.put("content", .{ .array = .{ .items = tr_content, .capacity = tr_content.items.len } });
                        try o.put("status", .{ .string = if (tm.is_error) "error" else "success" });
                        break :blk o;
                    } });
                    try tool_results.append(.{ .object = obj });
                }
                i = j - 1;
                var msg = std.json.ObjectMap.init(gpa);
                try msg.put("role", .{ .string = "user" });
                try msg.put("content", .{ .array = .{ .items = tool_results, .capacity = tool_results.items.len } });
                try result.append(.{ .object = msg });
            },
        }
    }

    if (cache_retention != .none and supportsPromptCaching(model) and result.items.len > 0) {
        if (result.items[result.items.len - 1].object.get("role")) |rv| {
            if (rv == .string and std.mem.eql(u8, rv.string, "user")) {
                if (result.items[result.items.len - 1].object.get("content")) |cv| {
                    if (cv == .array) {
                        var cp = std.json.ObjectMap.init(gpa);
                        try cp.put("cachePoint", .{ .object = blk: {
                            var o = std.json.ObjectMap.init(gpa);
                            try o.put("type", .{ .string = "default" });
                            break :blk o;
                        } });
                        var arr = cv.array;
                        try arr.items.append(.{ .object = cp });
                        try result.items[result.items.len - 1].object.put("content", .{ .array = arr });
                    }
                }
            }
        }
    }

    return std.json.Value{ .array = .{ .items = result, .capacity = result.items.len } };
}

fn convertToolConfig(gpa: std.mem.Allocator, tools: ?[]const ai.Tool, tool_choice: ?std.json.Value) ?std.json.Value {
    if (tools == null or tools.?.len == 0) return null;
    const t = tools.?;
    var bedrock_tools = std.ArrayList(std.json.Value).init(gpa);
    for (t) |tool| {
        var obj = std.json.ObjectMap.init(gpa);
        try obj.put("toolSpec", .{ .object = blk: {
            var o = std.json.ObjectMap.init(gpa);
            try o.put("name", .{ .string = tool.name });
            try o.put("description", .{ .string = tool.description });
            try o.put("inputSchema", .{ .object = blk2: {
                var o2 = std.json.ObjectMap.init(gpa);
                try o2.put("json", tool.parameters);
                break :blk2 o2;
            } });
            break :blk o;
        } });
        try bedrock_tools.append(.{ .object = obj });
    }
    var tc = std.json.ObjectMap.init(gpa);
    try tc.put("tools", .{ .array = .{ .items = bedrock_tools, .capacity = bedrock_tools.items.len } });
    if (tool_choice) |choice_val| {
        if (choice_val == .string) {
            const choice = choice_val.string;
            if (std.mem.eql(u8, choice, "auto")) {
                try tc.put("toolChoice", .{ .object = blk: { var o = std.json.ObjectMap.init(gpa); try o.put("auto", .{ .object = std.json.ObjectMap.init(gpa) }); break :blk o; } });
            } else if (std.mem.eql(u8, choice, "any")) {
                try tc.put("toolChoice", .{ .object = blk: { var o = std.json.ObjectMap.init(gpa); try o.put("any", .{ .object = std.json.ObjectMap.init(gpa) }); break :blk o; } });
            } else if (std.mem.eql(u8, choice, "none")) {
                // omit tools entirely above, but if we reached here keep default
            }
        } else if (choice_val == .object) {
            if (choice_val.object.get("type")) |tyv| {
                if (tyv == .string and std.mem.eql(u8, tyv.string, "tool")) {
                    if (choice_val.object.get("name")) |nv| {
                        if (nv == .string) {
                            try tc.put("toolChoice", .{ .object = blk: {
                                var o = std.json.ObjectMap.init(gpa);
                                try o.put("tool", .{ .object = blk2: {
                                    var o2 = std.json.ObjectMap.init(gpa);
                                    try o2.put("name", nv);
                                    break :blk2 o2;
                                } });
                                break :blk o;
                            } });
                        }
                    }
                }
            }
        }
    }
    return std.json.Value{ .object = tc };
}

fn supportsAdaptiveThinking(model_id: []const u8) bool {
    const id = std.asciiLowerStringStack(model_id);
    return std.mem.containsAtLeast(u8, id, 1, "opus-4-6") or std.mem.containsAtLeast(u8, id, 1, "opus-4.6") or std.mem.containsAtLeast(u8, id, 1, "sonnet-4-6") or std.mem.containsAtLeast(u8, id, 1, "sonnet-4.6");
}

fn mapThinkingLevelToEffort(level: ai.ThinkingLevel, model_id: []const u8) []const u8 {
    return switch (level) {
        .minimal, .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => if (supportsAdaptiveThinking(model_id)) "max" else "high",
    };
}

fn buildAdditionalModelRequestFields(gpa: std.mem.Allocator, model: ai.Model, options: ?ai.StreamOptions) ?std.json.Value {
    const opts = options orelse return null;
    if (!model.reasoning or opts.reasoning == null) return null;
    const id = std.asciiLowerStringStack(model.id);
    if (std.mem.containsAtLeast(u8, id, 1, "anthropic.claude") or std.mem.containsAtLeast(u8, id, 1, "anthropic/claude")) {
        if (supportsAdaptiveThinking(model.id)) {
            var obj = std.json.ObjectMap.init(gpa);
            try obj.put("thinking", .{ .object = blk: { var o = std.json.ObjectMap.init(gpa); try o.put("type", .{ .string = "adaptive" }); break :blk o; } });
            try obj.put("output_config", .{ .object = blk: {
                var o = std.json.ObjectMap.init(gpa);
                try o.put("effort", .{ .string = mapThinkingLevelToEffort(opts.reasoning.?, model.id) });
                break :blk o;
            } });
            return std.json.Value{ .object = obj };
        }
        var obj = std.json.ObjectMap.init(gpa);
        var tc = std.json.ObjectMap.init(gpa);
        try tc.put("type", .{ .string = "enabled" });
        const default_budget: u32 = switch (opts.reasoning.?) {
            .minimal => 1024,
            .low => 2048,
            .medium => 8192,
            .high, .xhigh => 16384,
        };
        try tc.put("budget_tokens", .{ .integer = default_budget });
        try obj.put("thinking", .{ .object = tc });
        return std.json.Value{ .object = obj };
    }
    return null;
}

fn mapStopReason(reason: ?[]const u8) ai.StopReason {
    if (reason) |r| {
        if (std.mem.eql(u8, r, "end_turn") or std.mem.eql(u8, r, "stop_sequence")) return .stop;
        if (std.mem.eql(u8, r, "max_tokens") or std.mem.eql(u8, r, "model_context_window_exceeded")) return .length;
        if (std.mem.eql(u8, r, "tool_use")) return .tool_use;
    }
    return .err;
}

// =============================================================================
// Stream processing
// =============================================================================
const Block = struct {
    typ: enum { text, thinking, tool_call },
    index: ?usize,
    text: ?[]const u8,
    thinking: ?[]const u8,
    thinking_signature: ?[]const u8,
    tool_id: ?[]const u8,
    tool_name: ?[]const u8,
    arguments: ?std.json.Value,
    partial_json: ?[]const u8,
};

fn handleContentBlockStart(event_type: []const u8, gpa: std.mem.Allocator, payload: std.json.Value, blocks: *std.ArrayList(Block), output: *ai.AssistantMessage, es: ai.AssistantMessageEventStream) void {
    _ = event_type;
    const start = if (payload.object.get("start")) |sv| (if (sv == .object) sv.object else return) else return;
    const index = if (payload.object.get("contentBlockIndex")) |iv| (if (iv == .integer) @as(usize, @intCast(iv.integer)) else return) else return;

    if (start.get("toolUse")) |tuv| {
        if (tuv == .object) {
            const tool_id = if (tuv.object.get("toolUseId")) |tv| (if (tv == .string) tv.string else "") else "";
            const name = if (tuv.object.get("name")) |nv| (if (nv == .string) nv.string else "") else "";
            const block = Block{
                .typ = .tool_call,
                .index = index,
                .tool_id = tool_id,
                .tool_name = name,
                .arguments = .{ .object = std.json.ObjectMap.init(gpa) },
                .partial_json = "",
                .text = null,
                .thinking = null,
                .thinking_signature = null,
            };
            blocks.append(block) catch {};
            appendContentBlock(gpa, output, .{ .tool_call = .{ .id = tool_id, .name = name, .arguments = .{ .object = std.json.ObjectMap.init(gpa) } } });
            es.push(.{ .toolcall_start = .{ .content_index = output.content.len - 1, .partial = output.* } }) catch {};
        }
    }
}

fn handleContentBlockDelta(gpa: std.mem.Allocator, payload: std.json.Value, blocks: *std.ArrayList(Block), output: *ai.AssistantMessage, es: ai.AssistantMessageEventStream) void {
    const content_block_index = if (payload.object.get("contentBlockIndex")) |iv| (if (iv == .integer) @as(usize, @intCast(iv.integer)) else return) else return;
    const delta = if (payload.object.get("delta")) |dv| (if (dv == .object) dv.object else return) else return;

    var found_idx: ?usize = null;
    var block_idx: usize = 0;
    for (blocks.items) |*b| {
        if (b.index == @as(isize, @intCast(content_block_index)) or b.index == @as(?isize, @intCast(content_block_index))) {
            found_idx = block_idx;
            break;
        }
        block_idx += 1;
    }
    // Fallback: find by position in output.content if index not tracked
    if (found_idx == null and content_block_index < output.content.len) {
        found_idx = content_block_index;
        // ensure blocks array has entry
        switch (output.content[content_block_index]) {
            .text => blocks.append(.{ .typ = .text, .index = content_block_index, .text = "" }) catch {},
            .thinking => blocks.append(.{ .typ = .thinking, .index = content_block_index, .thinking = "" }) catch {},
            .tool_call => |tc| blocks.append(.{ .typ = .tool_call, .index = content_block_index, .tool_id = tc.id, .tool_name = tc.name, .arguments = tc.arguments, .partial_json = "" }) catch {},
            else => {},
        }
    }
    if (found_idx == null) {
        // create text block implicitly
        blocks.append(.{ .typ = .text, .index = content_block_index, .text = "" }) catch {};
        appendContentBlock(gpa, output, .{ .text = .{ .text = "" } });
        es.push(.{ .text_start = .{ .content_index = output.content.len - 1, .partial = output.* } }) catch {};
        found_idx = blocks.items.len - 1;
    }

    const idx = found_idx.?;
    if (delta.get("text")) |tv| {
        if (tv == .string) {
            if (blocks.items[idx].typ != .text) return;
            blocks.items[idx].text = std.fmt.allocPrint(gpa, "{s}{s}", .{ blocks.items[idx].text orelse "", tv.string }) catch blocks.items[idx].text;
            output.content[idx].text.text = blocks.items[idx].text.?;
            es.push(.{ .text_delta = .{ .content_index = idx, .delta = tv.string, .partial = output.* } }) catch {};
        }
    } else if (delta.get("toolUse")) |tuv| {
        if (tuv == .object) {
            if (blocks.items[idx].typ != .tool_call) return;
            if (tuv.object.get("input")) |iv| {
                if (iv == .string) {
                    const new_partial = std.fmt.allocPrint(gpa, "{s}{s}", .{ blocks.items[idx].partial_json orelse "", iv.string }) catch blocks.items[idx].partial_json;
                    blocks.items[idx].partial_json = new_partial;
                    const parsed = std.json.parseFromSlice(std.json.Value, gpa, new_partial.?, .{}) catch null;
                    if (parsed) |p| {
                        blocks.items[idx].arguments = p.value;
                        output.content[idx].tool_call.arguments = p.value;
                    }
                    es.push(.{ .toolcall_delta = .{ .content_index = idx, .delta = iv.string, .partial = output.* } }) catch {};
                }
            }
        }
    } else if (delta.get("reasoningContent")) |rcv| {
        if (rcv == .object) {
            if (blocks.items[idx].typ != .thinking) {
                // create thinking block
                blocks.items[idx] = .{ .typ = .thinking, .index = content_block_index, .thinking = "" };
                appendContentBlock(gpa, output, .{ .thinking = .{ .thinking = "" } });
                es.push(.{ .thinking_start = .{ .content_index = output.content.len - 1, .partial = output.* } }) catch {};
                // adjust idx to last
                found_idx = output.content.len - 1;
            }
            const tidx = found_idx.?;
            if (rcv.object.get("reasoningText")) |rtv| {
                if (rtv == .object) {
                    if (rtv.object.get("text")) |tv2| {
                        if (tv2 == .string) {
                            blocks.items[tidx].thinking = std.fmt.allocPrint(gpa, "{s}{s}", .{ blocks.items[tidx].thinking orelse "", tv2.string }) catch blocks.items[tidx].thinking;
                            output.content[tidx].thinking.thinking = blocks.items[tidx].thinking.?;
                            es.push(.{ .thinking_delta = .{ .content_index = tidx, .delta = tv2.string, .partial = output.* } }) catch {};
                        }
                    }
                    if (rtv.object.get("signature")) |sv| {
                        if (sv == .string) {
                            blocks.items[tidx].thinking_signature = std.fmt.allocPrint(gpa, "{s}{s}", .{ blocks.items[tidx].thinking_signature orelse "", sv.string }) catch blocks.items[tidx].thinking_signature;
                            output.content[tidx].thinking.thinking_signature = blocks.items[tidx].thinking_signature;
                        }
                    }
                }
            }
        }
    }
}

fn handleContentBlockStop(gpa: std.mem.Allocator, payload: std.json.Value, blocks: *std.ArrayList(Block), output: *ai.AssistantMessage, es: ai.AssistantMessageEventStream) void {
    const content_block_index = if (payload.object.get("contentBlockIndex")) |iv| (if (iv == .integer) @as(usize, @intCast(iv.integer)) else return) else return;
    var idx: ?usize = null;
    for (blocks.items, 0..) |*b, i| {
        if (b.index) |bi| {
            if (bi == content_block_index) {
                idx = i;
                b.index = null;
                break;
            }
        }
    }
    if (idx == null) {
        if (content_block_index < output.content.len) idx = content_block_index else return;
    }
    const i = idx.?;
    switch (blocks.items[i].typ) {
        .text => es.push(.{ .text_end = .{ .content_index = i, .content = output.content[i].text.text, .partial = output.* } }) catch {},
        .thinking => es.push(.{ .thinking_end = .{ .content_index = i, .content = output.content[i].thinking.thinking, .partial = output.* } }) catch {},
        .tool_call => {
            if (blocks.items[i].partial_json) |pj| {
                const parsed = std.json.parseFromSlice(std.json.Value, gpa, pj, .{}) catch null;
                if (parsed) |p| {
                    output.content[i].tool_call.arguments = p.value;
                }
            }
            es.push(.{ .toolcall_end = .{ .content_index = i, .tool_call = output.content[i].tool_call, .partial = output.* } }) catch {};
        },
    }
}

fn handleMetadata(payload: std.json.Value, model: ai.Model, output: *ai.AssistantMessage) void {
    if (payload.object.get("usage")) |um| {
        if (um == .object) {
            output.usage.input = if (um.object.get("inputTokens")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;
            output.usage.output = if (um.object.get("outputTokens")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;
            output.usage.cache_read = if (um.object.get("cacheReadInputTokens")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;
            output.usage.cache_write = if (um.object.get("cacheWriteInputTokens")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;
            output.usage.total_tokens = if (um.object.get("totalTokens")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else output.usage.input + output.usage.output;
            ai.calculateCost(model, &output.usage);
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

// =============================================================================
// Main stream
// =============================================================================
fn getCredentials() ?struct { access_key: []const u8, secret_key: []const u8, session_token: ?[]const u8 } {
    const access = std.process.getEnvVarOwned(std.heap.page_allocator, "AWS_ACCESS_KEY_ID") catch return null;
    const secret = std.process.getEnvVarOwned(std.heap.page_allocator, "AWS_SECRET_ACCESS_KEY") catch return null;
    const session = std.process.getEnvVarOwned(std.heap.page_allocator, "AWS_SESSION_TOKEN") catch null;
    return .{ .access_key = access, .secret_key = secret, .session_token = session };
}

fn getRegion(options_region: ?[]const u8) []const u8 {
    if (options_region) |r| return r;
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "AWS_REGION")) |v| return v;
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "AWS_DEFAULT_REGION")) |v| return v;
    return "us-east-1";
}

pub fn streamBedrock(model: ai.Model, context: ai.Context, options: ?ai.StreamOptions) ai.AssistantMessageEventStream {
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

    const creds = getCredentials() orelse {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "AWS credentials not found (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return es;
    };

    const thread = std.Thread.spawn(.{}, bedrockThread, .{ model, context, options, creds, output, es }) catch |err| {
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

fn bedrockThread(model: ai.Model, context: ai.Context, options: ?ai.StreamOptions, creds: struct { access_key: []const u8, secret_key: []const u8, session_token: ?[]const u8 }, output: ai.AssistantMessage, es: ai.AssistantMessageEventStream) void {
    const gpa = std.heap.page_allocator;
    const client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    const region2 = getRegion(null);
    const host = std.fmt.allocPrint(gpa, "bedrock-runtime.{s}.amazonaws.com", .{region2}) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "OOM";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };
    defer gpa.free(host);

    const cache_retention = resolveCacheRetention(if (options) |o| o.cache_retention else null);

    const body = blk: {
        var obj = std.json.ObjectMap.init(gpa);
        try obj.put("modelId", .{ .string = model.id });
        try obj.put("messages", try convertMessages(gpa, model, context, cache_retention));
        if (buildSystemPrompt(gpa, context.system_prompt, model, cache_retention)) |spv| {
            try obj.put("system", spv);
        }
        var inference = std.json.ObjectMap.init(gpa);
        if (options) |opts| {
            if (opts.max_tokens) |mt| try inference.put("maxTokens", .{ .integer = mt });
            if (opts.temperature) |t| try inference.put("temperature", .{ .float = t });
        }
        if (inference.count() > 0) {
            try obj.put("inferenceConfig", .{ .object = inference });
        } else inference.deinit();

        if (convertToolConfig(gpa, context.tools, if (options) |o| o.headers else null)) |tcv| {
            try obj.put("toolConfig", tcv);
        }
        if (buildAdditionalModelRequestFields(gpa, model, options)) |amrf| {
            try obj.put("additionalModelRequestFields", amrf);
        }
        break :blk std.json.Value{ .object = obj };
    };

    var body_list = std.ArrayList(u8).init(gpa);
    defer body_list.deinit();
    std.json.stringify(body, .{}, body_list.writer()) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "Failed to serialize request";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };

    const now = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(std.time.nanoTimestamp(), std.time.ns_per_s)) };
    const dt = std.time.epoch.secondsToDatetime(now.secs);
    const date_iso = std.fmt.allocPrint(gpa, "{d:0>4}{d:0>2}{d:0>2}", .{ dt.year, dt.month, dt.day }) catch "20260101";
    const amz_date = std.fmt.allocPrint(gpa, "{s}T{d:0>2}{d:0>2}{d:0>2}Z", .{ date_iso, dt.hour, dt.minute, dt.second }) catch "20260101T000000Z";
    defer gpa.free(date_iso);
    defer gpa.free(amz_date);

    // URI encode model id (simple slash -> %2F)
    const encoded_model = std.mem.replaceOwned(u8, gpa, model.id, "/", "%2F") catch model.id;
    defer if (encoded_model.ptr != model.id.ptr) gpa.free(encoded_model);
    const uri = std.fmt.allocPrint(gpa, "/model/{s}/converse-stream", .{encoded_model}) catch "/model/error/converse-stream";
    defer gpa.free(uri);

    const auth = signRequest(gpa, "POST", uri, "", host, body_list.items, creds.access_key, creds.secret_key, creds.session_token, region2, amz_date, date_iso) catch |err| {
        var o = output;
        o.stop_reason = .err;
        o.error_message = std.fmt.allocPrint(gpa, "SigV4 error: {s}", .{@errorName(err)}) catch "SigV4 error";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };
    defer gpa.free(auth);

    const url = std.fmt.allocPrint(gpa, "https://{s}{s}", .{ host, uri }) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "OOM";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };
    defer gpa.free(url);

    var extra_headers = std.ArrayList(std.http.Client.Header).init(gpa);
    defer extra_headers.deinit();
    extra_headers.append(.{ .name = "host", .value = host }) catch {};
    extra_headers.append(.{ .name = "x-amz-date", .value = amz_date }) catch {};
    extra_headers.append(.{ .name = "Authorization", .value = auth }) catch {};
    extra_headers.append(.{ .name = "content-type", .value = "application/json" }) catch {};
    if (creds.session_token) |st| {
        extra_headers.append(.{ .name = "x-amz-security-token", .value = st }) catch {};
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

    // Read entire binary event stream body
    var body_data = std.ArrayList(u8).init(gpa);
    defer body_data.deinit();
    var buf: [4096]u8 = undefined;
    var reader = fetch_res.body.reader();
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
        body_data.appendSlice(buf[0..n]) catch {};
    }

    var blocks = std.ArrayList(Block).init(gpa);
    defer blocks.deinit();

    const frames = parseEventStream(gpa, body_data.items) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "Failed to parse event stream";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };
    for (frames.items) |frame| {
        if (std.mem.eql(u8, frame.event_type, "messageStart")) {
            // already pushed start
        } else if (std.mem.eql(u8, frame.event_type, "contentBlockStart")) {
            handleContentBlockStart("contentBlockStart", gpa, frame.payload, &blocks, &output, es);
        } else if (std.mem.eql(u8, frame.event_type, "contentBlockDelta")) {
            handleContentBlockDelta(gpa, frame.payload, &blocks, &output, es);
        } else if (std.mem.eql(u8, frame.event_type, "contentBlockStop")) {
            handleContentBlockStop(gpa, frame.payload, &blocks, &output, es);
        } else if (std.mem.eql(u8, frame.event_type, "messageStop")) {
            if (frame.payload.object.get("stopReason")) |srv| {
                if (srv == .string) {
                    output.stop_reason = mapStopReason(srv.string);
                }
            }
        } else if (std.mem.eql(u8, frame.event_type, "metadata")) {
            handleMetadata(frame.payload, model, &output);
        } else if (std.mem.startsWith(u8, frame.event_type, "internalServerException") or
            std.mem.startsWith(u8, frame.event_type, "modelStreamErrorException") or
            std.mem.startsWith(u8, frame.event_type, "validationException") or
            std.mem.startsWith(u8, frame.event_type, "throttlingException") or
            std.mem.startsWith(u8, frame.event_type, "serviceUnavailableException"))
        {
            var o = output;
            o.stop_reason = .err;
            o.error_message = std.fmt.allocPrint(gpa, "Bedrock {s}", .{frame.event_type}) catch frame.event_type;
            es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
            es.end(null);
            return;
        }
    }

    for (blocks.items) |*b| {
        b.index = null;
    }

    if (output.stop_reason == .err or output.stop_reason == .aborted) {
        var o = output;
        es.push(.{ .err_event = .{ .reason = o.stop_reason, .err_msg = o } }) catch {};
        es.end(null);
        return;
    }

    es.push(.{ .done = .{ .reason = output.stop_reason, .message = output } }) catch {};
    es.end(null);
}

pub fn streamSimpleBedrock(model: ai.Model, context: ai.Context, options: ?ai.types.SimpleStreamOptions) ai.AssistantMessageEventStream {
    const base = ai.simple_options.buildBaseOptions(model, options, null);
    if (options) |opts| {
        if (opts.reasoning) |re| {
            if (model.id.includes("anthropic.claude") or model.id.includes("anthropic/claude")) {
                if (!supportsAdaptiveThinking(model.id)) {
                    const adjusted = ai.simple_options.adjustMaxTokensForThinking(base.max_tokens orelse 0, model.max_tokens, re, null);
                    var s = base;
                    s.max_tokens = adjusted.max_tokens;
                    return streamBedrock(model, context, s);
                }
            }
            var s = base;
            s.reasoning = re;
            return streamBedrock(model, context, s);
        }
    }
    return streamBedrock(model, context, base);
}

pub fn registerAmazonBedrockProvider() void {
    ai.registerApiProvider(.{
        .api = .{ .known = .bedrock_converse_stream },
        .stream = streamBedrock,
        .stream_simple = streamSimpleBedrock,
    });
}

test "amazon_bedrock compiles and registers" {
    registerAmazonBedrockProvider();
}

test "sigv4 signing produces Authorization header" {
    const gpa = std.testing.allocator;
    const auth = try signRequest(gpa, "POST", "/model/test/converse-stream", "", "bedrock-runtime.us-east-1.amazonaws.com", "{}", "AKID", "SECRET", null, "us-east-1", "20260101T000000Z", "20260101");
    defer gpa.free(auth);
    try std.testing.expect(std.mem.startsWith(u8, auth, "AWS4-HMAC-SHA256 Credential="));
    try std.testing.expect(std.mem.indexOf(u8, auth, "Signature=") != null);
}

test "event stream parser extracts event type and payload" {
    const gpa = std.testing.allocator;
    // Build a minimal AWS Event Stream frame
    // headers: :event-type = "messageStop" (type 0x0d string)
    // payload: JSON {"stopReason":"end_turn"}
    var frame = std.ArrayList(u8).init(gpa);
    defer frame.deinit();
    const payload = "{\"stopReason\":\"end_turn\"}";
    const header_name = ":event-type";
    const header_value = "messageStop";
    const headers_len: u32 = @intCast(1 + header_name.len + 1 + 2 + header_value.len);
    const total_len: u32 = @intCast(12 + headers_len + payload.len + 4);

    try frame.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, total_len)));
    try frame.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, headers_len)));
    // prelude CRC placeholder (0)
    try frame.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
    // header
    try frame.append(@intCast(header_name.len));
    try frame.appendSlice(header_name);
    try frame.append(0x0d); // string type
    try frame.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, @as(u16, @intCast(header_value.len)))));
    try frame.appendSlice(header_value);
    // payload
    try frame.appendSlice(payload);
    // message CRC placeholder (0)
    try frame.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));

    const frames = try parseEventStream(gpa, frame.items);
    defer {
        for (frames.items) |f| gpa.free(f.event_type);
        frames.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), frames.items.len);
    try std.testing.expectEqualStrings("messageStop", frames.items[0].event_type);
    if (frames.items[0].payload.object.get("stopReason")) |srv| {
        try std.testing.expectEqualStrings("end_turn", srv.string);
    } else {
        return error.MissingStopReason;
    }
}

test "convertMessages includes cache point for claude" {
    const gpa = std.testing.allocator;
    const model = ai.Model{
        .id = "anthropic.claude-3-7-sonnet",
        .name = "Claude",
        .api = .{ .known = .bedrock_converse_stream },
        .provider = .{ .known = .amazon_bedrock },
        .max_tokens = 4096,
    };
    const context = ai.Context{
        .system_prompt = "You are helpful.",
        .messages = &[_]ai.Message{
            ai.Message{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } },
        },
    };
    const msgs = try convertMessages(gpa, model, context, .short);
    defer {
        // JSON arrays allocate their backing list; freeing the Value isn't easy without deep free.
        // For test we rely on page_allocator and leak tracking disabled for this scope.
    }
    try std.testing.expect(msgs == .array);
    try std.testing.expectEqual(@as(usize, 1), msgs.array.items.len);
    const last_content = msgs.array.items[0].object.get("content").?;
    var has_cache = false;
    for (last_content.array.items) |block| {
        if (block.object.get("cachePoint") != null) {
            has_cache = true;
            break;
        }
    }
    try std.testing.expect(has_cache);
}

test "convertMessages merges consecutive tool results" {
    const gpa = std.testing.allocator;
    const model = ai.Model{
        .id = "anthropic.claude-3-5-haiku",
        .name = "Claude",
        .api = .{ .known = .bedrock_converse_stream },
        .provider = .{ .known = .amazon_bedrock },
        .max_tokens = 4096,
    };
    const empty_args = std.json.ObjectMap.init(gpa);
    const tc = ai.ToolCall{ .id = "tc1", .name = "Read", .arguments = std.json.Value{ .object = empty_args } };
    var content = [_]ai.ContentBlock{.{ .tool_call = tc }};
    const msgs = &[_]ai.Message{
        .{ .assistant = .{
            .role = "assistant",
            .content = @constCast(&content),
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        } },
        .{ .tool_result = .{
            .tool_call_id = "tc1",
            .tool_name = "Read",
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "ok1" } }},
            .timestamp = 0,
        } },
        .{ .tool_result = .{
            .tool_call_id = "tc2",
            .tool_name = "Read",
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "ok2" } }},
            .timestamp = 0,
        } },
    };
    const context2 = ai.Context{ .messages = msgs };
    const out = try convertMessages(gpa, model, context2, .none);
    try std.testing.expectEqual(@as(usize, 2), out.array.items.len);
    const user_msg = out.array.items[1];
    const user_content = user_msg.object.get("content").?;
    try std.testing.expectEqual(@as(usize, 2), user_content.array.items.len);
}
