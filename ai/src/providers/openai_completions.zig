const std = @import("std");
const ai = @import("../root.zig");
const shared = @import("shared");

pub const OpenAICompletionsOptions = struct {
    base: ai.types.StreamOptions = .{},
    reasoning_effort: ?[]const u8 = null,
    tool_choice: ?std.json.Value = null,
};

fn currentMs() i64 {
    const ts = std.posix.clock_gettime(std.os.linux.CLOCK.REALTIME) catch return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms);
}

fn getApiKey(options: ?ai.types.StreamOptions) ?[]const u8 {
    if (options) |o| {
        if (o.api_key) |k| return k;
    }
    return null;
}

fn buildUrl(model: ai.Model) []const u8 {
    if (model.base_url) |url| {
        return url;
    }
    return switch (model.provider) {
        .known => |k| switch (k) {
            .kimi_coding => "https://api.moonshot.cn/v1",
            .mistral => "https://api.mistral.ai/v1",
            .openai => "https://api.openai.com/v1",
            else => "https://api.openai.com/v1",
        },
        else => "https://api.openai.com/v1",
    };
}

// Convert ai.Context messages to OpenAI chat completion format.
fn buildRequestBody(gpa: std.mem.Allocator, model: ai.Model, context: ai.Context, options: ?OpenAICompletionsOptions) !std.json.Value {
    var messages = std.array_list.Managed(std.json.Value).init(gpa);
    // Note: memory allocated via gpa is not freed here since body is returned

    if (context.system_prompt) |sp| {
        var obj = std.json.ObjectMap.init(gpa);
        try obj.put("role", .{ .string = try gpa.dupe(u8, "system") });
        try obj.put("content", .{ .string = try gpa.dupe(u8, sp) });
        try messages.append(.{ .object = obj });
    }

    for (context.messages) |msg| {
        switch (msg) {
            .user => |u| {
                var obj = std.json.ObjectMap.init(gpa);
                try obj.put("role", .{ .string = try gpa.dupe(u8, "user") });
                switch (u.content) {
                    .text => |t| {
                        try obj.put("content", .{ .string = try gpa.dupe(u8, t) });
                    },
                    .blocks => |blocks| {
                        var arr = std.array_list.Managed(std.json.Value).init(gpa);
                        for (blocks) |block| {
                            switch (block) {
                                .text => |txt| {
                                    var part = std.json.ObjectMap.init(gpa);
                                    try part.put("type", .{ .string = try gpa.dupe(u8, "text") });
                                    try part.put("text", .{ .string = try gpa.dupe(u8, txt.text) });
                                    try arr.append(.{ .object = part });
                                },
                                .image => |img| {
                                    var part = std.json.ObjectMap.init(gpa);
                                    try part.put("type", .{ .string = try gpa.dupe(u8, "image_url") });
                                    var url_obj = std.json.ObjectMap.init(gpa);
                                    const url = try std.fmt.allocPrint(gpa, "data:{s};base64,{s}", .{ img.mime_type, img.data });
                                    try url_obj.put("url", .{ .string = url });
                                    try part.put("image_url", .{ .object = url_obj });
                                    try arr.append(.{ .object = part });
                                },
                                else => {},
                            }
                        }
                        try obj.put("content", .{ .array = arr });
                    },
                }
                try messages.append(.{ .object = obj });
            },
            .assistant => |a| {
                var obj = std.json.ObjectMap.init(gpa);
                try obj.put("role", .{ .string = try gpa.dupe(u8, "assistant") });
                var text_parts = std.ArrayList(u8).empty;
                defer text_parts.deinit(gpa);
                var tool_calls = std.array_list.Managed(std.json.Value).init(gpa);
                for (a.content) |block| {
                    switch (block) {
                        .text => |txt| {
                            try text_parts.appendSlice(gpa, txt.text);
                        },
                        .thinking => |th| {
                            try text_parts.appendSlice(gpa, th.thinking);
                        },
                        .tool_call => |tc| {
                            var tc_obj = std.json.ObjectMap.init(gpa);
                            try tc_obj.put("id", .{ .string = try gpa.dupe(u8, tc.id) });
                            var fn_obj = std.json.ObjectMap.init(gpa);
                            try fn_obj.put("name", .{ .string = try gpa.dupe(u8, tc.name) });
                            const args_str = try std.fmt.allocPrint(gpa, "{f}", .{std.json.fmt(tc.arguments, .{})});
                            try fn_obj.put("arguments", .{ .string = args_str });
                            try tc_obj.put("function", .{ .object = fn_obj });
                            try tool_calls.append(.{ .object = tc_obj });
                        },
                        else => {},
                    }
                }
                if (text_parts.items.len > 0) {
                    try obj.put("content", .{ .string = text_parts.toOwnedSlice(gpa) catch unreachable });
                } else {
                    try obj.put("content", .{ .null = {} });
                }
                if (tool_calls.items.len > 0) {
                    try obj.put("tool_calls", .{ .array = tool_calls });
                    // If content is null but tool_calls present, some APIs require non-null content
                    if (text_parts.items.len == 0) {
                        _ = obj.swapRemove("content");
                        try obj.put("content", .{ .string = try gpa.dupe(u8, "") });
                    }
                }
                try messages.append(.{ .object = obj });
            },
            .tool_result => |tr| {
                var obj = std.json.ObjectMap.init(gpa);
                try obj.put("role", .{ .string = try gpa.dupe(u8, "tool") });
                try obj.put("tool_call_id", .{ .string = try gpa.dupe(u8, tr.tool_call_id) });
                try obj.put("name", .{ .string = try gpa.dupe(u8, tr.tool_name) });
                var content_parts = std.ArrayList(u8).empty;
                for (tr.content) |block| {
                    switch (block) {
                        .text => |txt| try content_parts.appendSlice(gpa, txt.text),
                        .image => |img| {
                            const note = try std.fmt.allocPrint(gpa, "[image:{s}]", .{img.mime_type});
                            try content_parts.appendSlice(gpa, note);
                        },
                        else => {},
                    }
                }
                try obj.put("content", .{ .string = content_parts.toOwnedSlice(gpa) catch unreachable });
                try messages.append(.{ .object = obj });
            },
        }
    }

    var body = std.json.ObjectMap.init(gpa);
    try body.put("model", .{ .string = try gpa.dupe(u8, model.id) });
    try body.put("stream", .{ .bool = true });
    // Copy messages array into body before messages array is deinitialized
    var messages_copy = try std.array_list.Managed(std.json.Value).initCapacity(gpa, messages.items.len);
    for (messages.items) |m| messages_copy.appendAssumeCapacity(m);
    try body.put("messages", .{ .array = messages_copy });

    if (options) |opts| {
        if (opts.base.max_tokens) |mt| {
            try body.put("max_completion_tokens", .{ .integer = @intCast(mt) });
        }
        if (opts.base.temperature) |t| {
            try body.put("temperature", .{ .float = t });
        }
        if (opts.reasoning_effort) |re| {
            try body.put("reasoning_effort", .{ .string = try gpa.dupe(u8, re) });
        }
    }

    if (context.tools) |tools| {
        var tools_arr = std.array_list.Managed(std.json.Value).init(gpa);
        for (tools) |tool| {
            var tool_obj = std.json.ObjectMap.init(gpa);
            try tool_obj.put("type", .{ .string = try gpa.dupe(u8, "function") });
            var fn_obj = std.json.ObjectMap.init(gpa);
            try fn_obj.put("name", .{ .string = try gpa.dupe(u8, tool.name) });
            try fn_obj.put("description", .{ .string = try gpa.dupe(u8, tool.description) });
            try fn_obj.put("parameters", tool.parameters);
            try tool_obj.put("function", .{ .object = fn_obj });
            try tools_arr.append(.{ .object = tool_obj });
        }
        try body.put("tools", .{ .array = tools_arr });
    }

    return .{ .object = body };
}

fn mapStopReason(reason: ?[]const u8) ai.StopReason {
    if (reason == null) return .stop;
    const r = reason.?;
    if (std.mem.eql(u8, r, "stop")) return .stop;
    if (std.mem.eql(u8, r, "length")) return .length;
    if (std.mem.eql(u8, r, "tool_calls")) return .tool_use;
    return .stop;
}

fn parseChunkUsage(usage_val: std.json.Value) ai.Usage {
    var usage = ai.Usage{};
    if (usage_val != .object) return usage;
    const obj = usage_val.object;
    if (obj.get("prompt_tokens")) |v| {
        if (v == .integer) usage.input = @intCast(v.integer);
        if (v == .float) usage.input = @intFromFloat(v.float);
    }
    if (obj.get("completion_tokens")) |v| {
        if (v == .integer) usage.output = @intCast(v.integer);
        if (v == .float) usage.output = @intFromFloat(v.float);
    }
    if (obj.get("total_tokens")) |v| {
        if (v == .integer) usage.total_tokens = @intCast(v.integer);
        if (v == .float) usage.total_tokens = @intFromFloat(v.float);
    }
    return usage;
}

pub fn streamOpenAICompletions(model: ai.Model, context: ai.Context, options: ?ai.types.StreamOptions) ai.AssistantMessageEventStream {
    const gpa = std.heap.page_allocator;
    var es = ai.createAssistantMessageEventStream(gpa) catch @panic("OOM");

    const output = ai.AssistantMessage{
        .role = "assistant",
        .content = &.{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = currentMs(),
    };

    const api_key = getApiKey(options);
    const base_url = buildUrl(model);
    const io = if (options) |o| o.io else null;

    const thread = std.Thread.spawn(.{}, struct {
        fn run(e: *ai.AssistantMessageEventStream, m: ai.Model, c: ai.Context, o: ?ai.types.StreamOptions, out_: ai.AssistantMessage, key: ?[]const u8, url: []const u8, io_: ?std.Io) !void {
            var out = out_;
            const g = std.heap.page_allocator;
            const opts = if (o) |so| OpenAICompletionsOptions{ .base = so } else OpenAICompletionsOptions{};

            const body_val = try buildRequestBody(g, m, c, opts);
            const body_str = try std.fmt.allocPrint(g, "{f}", .{std.json.fmt(body_val, .{})});
            defer g.free(body_str);

            const client_io = io_ orelse return error.MissingIo;
            var client = std.http.Client{ .allocator = g, .io = client_io };
            defer client.deinit();

            const full_url = try std.fmt.allocPrint(g, "{s}/chat/completions", .{url});
            defer g.free(full_url);
            const full_uri = try std.Uri.parse(full_url);

            var auth_header: ?[]u8 = null;
            if (key) |k| {
                auth_header = try std.fmt.allocPrint(g, "Bearer {s}", .{k});
            }
            var extra_headers: []const std.http.Header = &.{};
            if (auth_header) |a| {
                extra_headers = &[_]std.http.Header{.{ .name = "Authorization", .value = a }};
            }

            var body_writer_alloc = std.Io.Writer.Allocating.init(g);
            defer body_writer_alloc.deinit();

            const fetch_result = try client.fetch(.{
                .location = .{ .uri = full_uri },
                .method = .POST,
                .payload = body_str,
                .headers = .{
                    .content_type = .{ .override = "application/json" },
                },
                .extra_headers = extra_headers,
                .response_writer = &body_writer_alloc.writer,
            });

            const body = body_writer_alloc.toOwnedSlice() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            defer g.free(body);

            if (fetch_result.status.class() != .success) {
                var err_out = out;
                err_out.stop_reason = .err;
                err_out.error_message = try std.fmt.allocPrint(g, "HTTP {d}: {s}", .{ @intFromEnum(fetch_result.status), body });
                e.push(.{ .err_event = .{ .reason = .err, .err_msg = err_out } });
                e.end(err_out);
                return;
            }

            e.push(.{ .start = .{ .partial = out } });

            var current_text_block: ?ai.ContentBlock = null;
            var current_tool_block: ?ai.ContentBlock = null;
            var current_tool_index: usize = 0;
            var line_it = std.mem.splitSequence(u8, body, "\n");
            while (line_it.next()) |line| {
                const data = shared.http.parseSseData(line) orelse continue;
                const chunk = shared.http.parseSseJsonLine(data, g) catch continue;

                if (chunk.object.get("usage")) |usage_val| {
                    out.usage = parseChunkUsage(usage_val);
                }
                const choices = chunk.object.get("choices") orelse continue;
                if (choices != .array or choices.array.items.len == 0) continue;
                const choice = choices.array.items[0];
                if (choice != .object) continue;

                if (choice.object.get("finish_reason")) |fr| {
                    if (fr == .string) {
                        out.stop_reason = mapStopReason(fr.string);
                    }
                }

                const delta = choice.object.get("delta") orelse continue;
                if (delta != .object) continue;

                if (delta.object.get("content")) |dc| {
                    if (dc == .string) {
                        const text = dc.string;
                        if (text.len > 0) {
                            if (current_text_block == null) {
                                current_text_block = .{ .text = .{ .text = "" } };
                                var new_content = try g.alloc(ai.ContentBlock, out.content.len + 1);
                                @memcpy(new_content[0..out.content.len], out.content);
                                new_content[out.content.len] = current_text_block.?;
                                out.content = new_content;
                                e.push(.{ .text_start = .{ .content_index = out.content.len - 1, .partial = out } });
                            }
                            const idx = out.content.len - 1;
                            const old = out.content[idx].text.text;
                            const combined = try std.fmt.allocPrint(g, "{s}{s}", .{ old, text });
                            if (old.len > 0) g.free(old);
                            out.content[idx].text.text = combined;
                            e.push(.{ .text_delta = .{ .content_index = idx, .delta = text, .partial = out } });
                        }
                    }
                }

                if (delta.object.get("tool_calls")) |tcs| {
                    if (tcs == .array) {
                        for (tcs.array.items) |tc_delta| {
                            if (tc_delta != .object) continue;
                            const tc_obj = tc_delta.object;
                            const tc_id_val = tc_obj.get("id");
                            const tc_fn_val = tc_obj.get("function");
                            const tc_id = if (tc_id_val) |v| (if (v == .string) v.string else "") else "";
                            var tc_name: []const u8 = "";
                            var tc_args_delta: []const u8 = "";
                            if (tc_fn_val) |fnv| {
                                if (fnv == .object) {
                                    if (fnv.object.get("name")) |nv| {
                                        if (nv == .string) tc_name = nv.string;
                                    }
                                    if (fnv.object.get("arguments")) |av| {
                                        if (av == .string) tc_args_delta = av.string;
                                    }
                                }
                            }

                            if (current_tool_block == null or
                                (tc_id.len > 0 and !std.mem.eql(u8, out.content[current_tool_index].tool_call.id, tc_id)))
                            {
                                if (current_tool_block != null) {
                                    // finalize previous tool call
                                    e.push(.{ .toolcall_end = .{ .content_index = current_tool_index, .tool_call = out.content[current_tool_index].tool_call, .partial = out } });
                                }
                                current_tool_block = .{ .tool_call = .{ .id = tc_id, .name = tc_name, .arguments = .{ .object = std.json.ObjectMap.init(g) } } };
                                var new_content = try g.alloc(ai.ContentBlock, out.content.len + 1);
                                @memcpy(new_content[0..out.content.len], out.content);
                                new_content[out.content.len] = current_tool_block.?;
                                out.content = new_content;
                                current_tool_index = out.content.len - 1;
                                e.push(.{ .toolcall_start = .{ .content_index = current_tool_index, .partial = out } });
                            }

                            if (tc_args_delta.len > 0) {
                                e.push(.{ .toolcall_delta = .{ .content_index = current_tool_index, .delta = tc_args_delta, .partial = out } });
                                // Try to parse partial arguments
                                var arena = std.heap.ArenaAllocator.init(g);
                                defer arena.deinit();
                                if (std.json.parseFromSlice(std.json.Value, arena.allocator(), tc_args_delta, .{})) |parsed| {
                                    out.content[current_tool_index].tool_call.arguments = parsed.value;
                                } else |_| {}
                            }
                        }
                    }
                }
            }

            if (current_text_block != null) {
                e.push(.{ .text_end = .{ .content_index = out.content.len - 1, .content = out.content[out.content.len - 1].text.text, .partial = out } });
            }
            if (current_tool_block != null) {
                e.push(.{ .toolcall_end = .{ .content_index = current_tool_index, .tool_call = out.content[current_tool_index].tool_call, .partial = out } });
            }

            if (out.stop_reason == .err or out.stop_reason == .aborted) {
                e.push(.{ .err_event = .{ .reason = out.stop_reason, .err_msg = out } });
                e.end(out);
                return;
            }

            e.push(.{ .done = .{ .reason = out.stop_reason, .message = out } });
            e.end(out);
        }
    }.run, .{ &es, model, context, options, output, api_key, base_url, io }) catch @panic("OOM");
    thread.detach();

    return es;
}

pub fn streamSimpleOpenAICompletions(model: ai.Model, context: ai.Context, options: ?ai.types.SimpleStreamOptions) ai.AssistantMessageEventStream {
    return streamOpenAICompletions(model, context, if (options) |o| o.base else null);
}

pub fn registerOpenAICompletionsProvider() void {
    ai.registerApiProvider(.{
        .api = .{ .known = .openai_completions },
        .stream = streamOpenAICompletions,
        .stream_simple = streamSimpleOpenAICompletions,
    });
}
