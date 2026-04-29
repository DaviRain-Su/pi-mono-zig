const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const provider_error = @import("../shared/provider_error.zig");
const transform_messages = @import("../shared/transform_messages.zig");

pub const OpenAIProvider = struct {
    pub const api = "openai-completions";

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        var event_stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
        errdefer event_stream_instance.deinit();

        // Build request payload
        const payload = try buildRequestPayload(allocator, model, context, options);
        defer freeJsonValue(allocator, payload);

        // Serialize payload to JSON
        var json_out: std.Io.Writer.Allocating = .init(allocator);
        const json_writer = &json_out.writer;
        defer json_out.deinit();

        try std.json.Stringify.value(payload, .{}, json_writer);

        // Build HTTP request
        var headers = try buildRequestHeaders(allocator, model, options);
        defer deinitOwnedHeaders(allocator, &headers);

        const req = http_client.HttpRequest{
            .method = .POST,
            .url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{model.base_url}),
            .headers = headers,
            .body = json_out.written(),
            .timeout_ms = if (options) |opts| opts.timeout_ms orelse 0 else 0,
            .aborted = if (options) |opts| opts.signal else null,
        };
        defer allocator.free(req.url);

        // Send request and process response
        var client = try http_client.HttpClient.init(allocator, io);
        defer client.deinit();

        var streaming = try client.requestStreaming(req);
        defer streaming.deinit();

        if (streaming.status != 200) {
            const response_body = try streaming.readAllBounded(allocator, provider_error.MAX_PROVIDER_ERROR_BODY_READ_BYTES);
            defer allocator.free(response_body);
            try provider_error.pushHttpStatusError(allocator, &event_stream_instance, model, streaming.status, response_body);
            return event_stream_instance;
        }

        // Parse SSE stream incrementally from lines
        try parseSseStreamLines(allocator, &event_stream_instance, &streaming, model);

        return event_stream_instance;
    }

    pub fn streamSimple(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        return try stream(allocator, io, model, context, options);
    }
};

/// Current block being streamed
const CurrentBlock = union(enum) {
    text: std.ArrayList(u8),
    thinking: struct {
        text: std.ArrayList(u8),
        signature: ?[]const u8,
    },
    tool_call: struct {
        id: std.ArrayList(u8),
        name: std.ArrayList(u8),
        partial_args: std.ArrayList(u8),
    },
};

fn deinitCurrentBlock(block: *CurrentBlock, allocator: std.mem.Allocator) void {
    switch (block.*) {
        .text => |*t| t.deinit(allocator),
        .thinking => |*th| {
            th.text.deinit(allocator);
            if (th.signature) |sig| allocator.free(sig);
        },
        .tool_call => |*tc| {
            tc.id.deinit(allocator);
            tc.name.deinit(allocator);
            tc.partial_args.deinit(allocator);
        },
    }
}

/// Free allocated fields within an AssistantMessageEvent.
/// Note: this only frees fields that are exclusively owned by this event.
/// The `done` event's message content is shared with earlier events and should NOT be freed here.
fn freeEvent(allocator: std.mem.Allocator, event: types.AssistantMessageEvent) void {
    if (event.owns_delta) {
        if (event.delta) |d| allocator.free(d);
    }
    // Do NOT free event.content or event.message - they are shared with content_blocks
    if (event.error_message) |em| allocator.free(em);
}

fn parseSseStreamLines(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    streaming: *http_client.StreamingResponse,
    model: types.Model,
) !void {
    var output = types.AssistantMessage{
        .role = "assistant",
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    };

    stream_ptr.push(.{
        .event_type = .start,
    });

    var current_block: ?CurrentBlock = null;
    defer if (current_block) |*b| deinitCurrentBlock(b, allocator);

    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);

    var tool_calls = std.ArrayList(types.ToolCall).empty;
    var tool_calls_transferred = false;
    defer {
        if (!tool_calls_transferred) {
            for (tool_calls.items) |tool_call| {
                allocator.free(tool_call.id);
                allocator.free(tool_call.name);
                freeJsonValue(allocator, tool_call.arguments);
            }
            tool_calls.deinit(allocator);
        }
    }

    while (true) {
        const maybe_line = streaming.readLine() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(
                    allocator,
                    stream_ptr,
                    &output,
                    &current_block,
                    &content_blocks,
                    &tool_calls,
                    &tool_calls_transferred,
                    err,
                );
                return;
            },
        };
        const line = maybe_line orelse break;
        const data = parseSseLine(line) orelse continue;

        if (std.mem.eql(u8, data, "[DONE]")) {
            break;
        }

        const chunk = parseChunk(allocator, data) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(
                    allocator,
                    stream_ptr,
                    &output,
                    &current_block,
                    &content_blocks,
                    &tool_calls,
                    &tool_calls_transferred,
                    err,
                );
                return;
            },
        };
        defer if (chunk) |*c| c.deinit();

        if (chunk == null) continue;

        const value = chunk.?.value;

        // Extract usage from chunk (may be present even without choices)
        if (value.object.get("usage")) |usage_val| {
            if (usage_val == .object) {
                output.usage = parseChunkUsage(allocator, usage_val, model);
            }
        }

        // Extract response_id from chunk
        if (value.object.get("id")) |id_val| {
            if (id_val == .string and output.response_id == null) {
                output.response_id = try allocator.dupe(u8, id_val.string);
            }
        }

        // Extract choices from chunk
        const choices = value.object.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;

        const choice = choices.array.items[0];
        if (choice != .object) continue;

        // Handle usage in choice (some providers like Moonshot)
        if (choice.object.get("usage")) |choice_usage| {
            if (choice_usage == .object) {
                output.usage = parseChunkUsage(allocator, choice_usage, model);
            }
        }

        // Handle finish_reason
        if (choice.object.get("finish_reason")) |finish_reason| {
            if (finish_reason == .string) {
                const result = try mapStopReason(allocator, finish_reason.string);
                output.stop_reason = result.stop_reason;
                if (result.error_message) |em| {
                    if (output.error_message) |previous| allocator.free(previous);
                    output.error_message = em;
                }
            }
        }

        const delta = choice.object.get("delta") orelse continue;
        if (delta != .object) continue;

        // Handle text content
        if (delta.object.get("content")) |content| {
            if (content == .string and content.string.len > 0) {
                if (current_block == null or current_block.? != .text) {
                    try finishCurrentBlock(&current_block, &content_blocks, &tool_calls, stream_ptr, allocator);
                    current_block = CurrentBlock{ .text = std.ArrayList(u8).empty };
                    stream_ptr.push(.{
                        .event_type = .text_start,
                        .content_index = @intCast(content_blocks.items.len),
                    });
                }

                if (current_block) |*block| {
                    if (block.* == .text) {
                        try block.text.appendSlice(allocator, content.string);
                        stream_ptr.push(.{
                            .event_type = .text_delta,
                            .content_index = @intCast(content_blocks.items.len),
                            .delta = try allocator.dupe(u8, content.string),
                            .owns_delta = true,
                        });
                    }
                }
            }
        }

        // Handle reasoning/thinking content
        const reasoning_fields = [_][]const u8{ "reasoning_content", "reasoning", "reasoning_text" };
        var found_reasoning: ?[]const u8 = null;
        for (reasoning_fields) |field| {
            if (delta.object.get(field)) |rv| {
                if (rv == .string and rv.string.len > 0) {
                    found_reasoning = rv.string;
                    break;
                }
            }
        }

        if (found_reasoning) |reasoning_text| {
            if (current_block == null or current_block.? != .thinking) {
                try finishCurrentBlock(&current_block, &content_blocks, &tool_calls, stream_ptr, allocator);
                current_block = CurrentBlock{
                    .thinking = .{
                        .text = std.ArrayList(u8).empty,
                        .signature = null,
                    },
                };
                stream_ptr.push(.{
                    .event_type = .thinking_start,
                    .content_index = @intCast(content_blocks.items.len),
                });
            }

            if (current_block) |*block| {
                if (block.* == .thinking) {
                    try block.thinking.text.appendSlice(allocator, reasoning_text);
                    stream_ptr.push(.{
                        .event_type = .thinking_delta,
                        .content_index = @intCast(content_blocks.items.len),
                        .delta = try allocator.dupe(u8, reasoning_text),
                        .owns_delta = true,
                    });
                }
            }
        }

        // Handle tool calls
        if (delta.object.get("tool_calls")) |tool_calls_val| {
            if (tool_calls_val == .array) {
                for (tool_calls_val.array.items) |tool_call_item| {
                    if (tool_call_item != .object) continue;

                    const tc_id = if (tool_call_item.object.get("id")) |id_v|
                        if (id_v == .string) id_v.string else null
                    else
                        null;

                    const tc_name = if (tool_call_item.object.get("function")) |func_v| blk: {
                        if (func_v == .object) {
                            if (func_v.object.get("name")) |name_v| {
                                if (name_v == .string) break :blk name_v.string;
                            }
                        }
                        break :blk null;
                    } else null;

                    const tc_args = if (tool_call_item.object.get("function")) |func_v| blk: {
                        if (func_v == .object) {
                            if (func_v.object.get("arguments")) |args_v| {
                                if (args_v == .string) break :blk args_v.string;
                            }
                        }
                        break :blk null;
                    } else null;

                    // Check if we need to start a new tool call
                    const need_new_block = blk: {
                        if (current_block == null) break :blk true;
                        if (current_block.? != .tool_call) break :blk true;
                        if (tc_id) |id| {
                            const current_id = std.mem.trim(u8, current_block.?.tool_call.id.items, " ");
                            if (current_id.len > 0 and !std.mem.eql(u8, current_id, id)) break :blk true;
                        }
                        break :blk false;
                    };

                    if (need_new_block) {
                        try finishCurrentBlock(&current_block, &content_blocks, &tool_calls, stream_ptr, allocator);
                        current_block = CurrentBlock{
                            .tool_call = .{
                                .id = std.ArrayList(u8).empty,
                                .name = std.ArrayList(u8).empty,
                                .partial_args = std.ArrayList(u8).empty,
                            },
                        };
                        stream_ptr.push(.{
                            .event_type = .toolcall_start,
                            .content_index = @intCast(content_blocks.items.len),
                        });
                    }

                    if (current_block) |*block| {
                        if (block.* == .tool_call) {
                            if (tc_id) |id| {
                                block.tool_call.id.clearRetainingCapacity();
                                try block.tool_call.id.appendSlice(allocator, id);
                            }
                            if (tc_name) |name| {
                                block.tool_call.name.clearRetainingCapacity();
                                try block.tool_call.name.appendSlice(allocator, name);
                            }
                            var delta_str: ?[]const u8 = null;
                            if (tc_args) |args| {
                                try block.tool_call.partial_args.appendSlice(allocator, args);
                                if (args.len > 0) {
                                    delta_str = try allocator.dupe(u8, args);
                                }
                            }
                            stream_ptr.push(.{
                                .event_type = .toolcall_delta,
                                .content_index = @intCast(content_blocks.items.len),
                                .delta = delta_str,
                                .owns_delta = delta_str != null,
                            });
                        }
                    }
                }
            }
        }
    }

    // Finish any remaining block
    try finishCurrentBlock(&current_block, &content_blocks, &tool_calls, stream_ptr, allocator);

    // Build output content from content_blocks
    if (content_blocks.items.len > 0) {
        const blocks = try allocator.alloc(types.ContentBlock, content_blocks.items.len);
        for (content_blocks.items, 0..) |block, i| {
            blocks[i] = block;
        }
        output.content = blocks;
    }

    if (tool_calls.items.len > 0) {
        output.tool_calls = try tool_calls.toOwnedSlice(allocator);
        tool_calls_transferred = true;
        if (output.stop_reason == .stop) output.stop_reason = .tool_use;
    }

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    tool_calls_transferred: *bool,
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    try finishCurrentBlock(current_block, content_blocks, tool_calls, stream_ptr, allocator);

    if (content_blocks.items.len > 0 and output.content.len == 0) {
        const blocks = try allocator.alloc(types.ContentBlock, content_blocks.items.len);
        for (content_blocks.items, 0..) |block, i| {
            blocks[i] = block;
        }
        output.content = blocks;
    }

    if (tool_calls.items.len > 0 and output.tool_calls == null) {
        output.tool_calls = try tool_calls.toOwnedSlice(allocator);
        tool_calls_transferred.* = true;
    }
}

fn emitRuntimeFailure(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    tool_calls_transferred: *bool,
    err: anyerror,
) !void {
    try finalizeOutputFromPartials(
        allocator,
        output,
        current_block,
        content_blocks,
        tool_calls,
        tool_calls_transferred,
        stream_ptr,
    );
    output.stop_reason = provider_error.runtimeStopReason(err);
    output.error_message = provider_error.runtimeErrorMessage(err);
    provider_error.pushTerminalRuntimeError(stream_ptr, output.*);
}

fn finishCurrentBlock(
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    allocator: std.mem.Allocator,
) !void {
    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |text| {
                const content = try allocator.dupe(u8, text.items);
                try content_blocks.append(allocator, types.ContentBlock{ .text = .{ .text = content } });
                stream_ptr.push(.{
                    .event_type = .text_end,
                    .content_index = @intCast(content_blocks.items.len - 1),
                    .content = content,
                });
            },
            .thinking => |thinking| {
                const content = try allocator.dupe(u8, thinking.text.items);
                try content_blocks.append(allocator, types.ContentBlock{
                    .thinking = .{
                        .thinking = content,
                        .signature = if (thinking.signature) |sig| try allocator.dupe(u8, sig) else null,
                        .redacted = false,
                    },
                });
                stream_ptr.push(.{
                    .event_type = .thinking_end,
                    .content_index = @intCast(content_blocks.items.len - 1),
                    .content = content,
                });
            },
            .tool_call => |tc| {
                const id = try allocator.dupe(u8, std.mem.trim(u8, tc.id.items, " "));
                errdefer allocator.free(id);
                const name = try allocator.dupe(u8, std.mem.trim(u8, tc.name.items, " "));
                errdefer allocator.free(name);
                const args_str = std.mem.trim(u8, tc.partial_args.items, " ");
                const args = try parseStreamingJsonToValue(allocator, args_str);
                errdefer freeJsonValue(allocator, args);
                const final_tool_call = types.ToolCall{
                    .id = id,
                    .name = name,
                    .arguments = args,
                };
                try tool_calls.append(allocator, final_tool_call);
                try content_blocks.append(allocator, types.ContentBlock{
                    .text = .{ .text = "" }, // Placeholder - tool calls stored separately
                });
                stream_ptr.push(.{
                    .event_type = .toolcall_end,
                    .content_index = @intCast(content_blocks.items.len - 1),
                    .tool_call = final_tool_call,
                });
            },
        }
        deinitCurrentBlock(block, allocator);
        current_block.* = null;
    }
}

fn parseStreamingJsonToValue(allocator: std.mem.Allocator, input: []const u8) !std.json.Value {
    if (input.len == 0) return std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) };
    const parsed = json_parse.parseStreamingJson(allocator, input) catch {
        return std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) };
    };
    defer parsed.deinit();
    // Need to clone the value since parsed will be deinit'd
    return cloneJsonValue(allocator, parsed.value);
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) anyerror!std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| return .{ .integer = i },
        .float => |f| return .{ .float = f },
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var new_arr = std.json.Array.init(allocator);
            errdefer new_arr.deinit();
            for (arr.items) |item| {
                try new_arr.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            errdefer new_obj.deinit(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key_copy);
                try new_obj.put(allocator, key_copy, try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            return .{ .object = new_obj };
        },
        .number_string => |ns| return .{ .number_string = try allocator.dupe(u8, ns) },
    }
}

fn parseChunkUsage(
    allocator: std.mem.Allocator,
    usage_val: std.json.Value,
    model: types.Model,
) types.Usage {
    _ = allocator;
    _ = model;

    var usage = types.Usage.init();

    if (usage_val != .object) return usage;

    const prompt_tokens = if (usage_val.object.get("prompt_tokens")) |v|
        if (v == .integer) @as(u32, @intCast(v.integer)) else @as(u32, 0)
    else
        @as(u32, 0);

    const completion_tokens = if (usage_val.object.get("completion_tokens")) |v|
        if (v == .integer) @as(u32, @intCast(v.integer)) else @as(u32, 0)
    else
        @as(u32, 0);

    var cache_read_tokens: u32 = 0;
    var cache_write_tokens: u32 = 0;

    if (usage_val.object.get("prompt_tokens_details")) |details| {
        if (details == .object) {
            if (details.object.get("cached_tokens")) |ct| {
                if (ct == .integer) cache_read_tokens = @as(u32, @intCast(ct.integer));
            }
            if (details.object.get("cache_write_tokens")) |cwt| {
                if (cwt == .integer) cache_write_tokens = @as(u32, @intCast(cwt.integer));
            }
        }
    }

    if (usage_val.object.get("completion_tokens_details")) |details| {
        if (details == .object) {
            _ = details.object.get("reasoning_tokens");
        }
    }

    // Normalize cache read: subtract cache writes if present
    const normalized_cache_read = if (cache_write_tokens > 0)
        @max(@as(u32, 0), cache_read_tokens - cache_write_tokens)
    else
        cache_read_tokens;

    const input = @max(@as(u32, 0), prompt_tokens - normalized_cache_read - cache_write_tokens);
    const output = completion_tokens;

    usage.input = input;
    usage.output = output;
    usage.cache_read = normalized_cache_read;
    usage.cache_write = cache_write_tokens;
    usage.total_tokens = input + output + normalized_cache_read + cache_write_tokens;

    return usage;
}

fn mapStopReason(
    allocator: std.mem.Allocator,
    reason: []const u8,
) !struct { stop_reason: types.StopReason, error_message: ?[]const u8 } {
    if (std.mem.eql(u8, reason, "stop") or std.mem.eql(u8, reason, "end")) return .{ .stop_reason = .stop, .error_message = null };
    if (std.mem.eql(u8, reason, "length")) return .{ .stop_reason = .length, .error_message = null };
    if (std.mem.eql(u8, reason, "tool_calls") or std.mem.eql(u8, reason, "function_call")) return .{ .stop_reason = .tool_use, .error_message = null };
    return .{
        .stop_reason = .error_reason,
        .error_message = try std.fmt.allocPrint(allocator, "Provider finish_reason: {s}", .{reason}),
    };
}

/// Removes unpaired Unicode surrogate characters from text.
/// Valid paired surrogates (proper emoji) are preserved.
pub fn sanitizeSurrogates(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    // In-place filtering: scan for unpaired surrogates and remove them
    // High surrogates: 0xD800-0xDBFF
    // Low surrogates: 0xDC00-0xDFFF
    // This is a simplified version that works on UTF-8 encoded text.
    // Surrogates in UTF-8 appear as 3-byte sequences: ED A0 80-ED AF BF (high) or ED B0 80-ED BF BF (low)
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        // Check for 3-byte UTF-8 surrogate sequence
        if (i + 2 < text.len and text[i] == 0xED) {
            const is_high = text[i + 1] >= 0xA0 and text[i + 1] <= 0xAF;
            const is_low = text[i + 1] >= 0xB0 and text[i + 1] <= 0xBF;

            if (is_high) {
                // Check if followed by low surrogate
                if (i + 5 < text.len and text[i + 3] == 0xED and text[i + 4] >= 0xB0 and text[i + 4] <= 0xBF) {
                    // Valid pair, keep both
                    try result.appendSlice(allocator, text[i .. i + 6]);
                    i += 6;
                    continue;
                }
                // Unpaired high surrogate, skip
                i += 3;
                continue;
            } else if (is_low) {
                // Unpaired low surrogate (not preceded by high), skip
                // Note: if we got here, the preceding bytes were not a valid high surrogate
                i += 3;
                continue;
            }
        }

        // Regular byte, keep it
        try result.append(allocator, text[i]);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

/// Recursively free a JSON value and all its children, including ObjectMap keys.
/// Use this only for values where ALL keys and strings were allocated by the same allocator.
fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number_string => |ns| allocator.free(ns),
        .array => |arr| {
            for (arr.items) |item| {
                freeJsonValue(allocator, item);
            }
            var arr_mut = arr;
            arr_mut.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var obj_mut = obj;
            obj_mut.deinit(allocator);
        },
        else => {},
    }
}

/// Build the request payload for OpenAI chat completions API
pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    const transformed_messages = try transform_messages.transformMessages(
        allocator,
        context.messages,
        model,
        &normalizeToolCallId,
    );
    defer transform_messages.freeMessages(allocator, transformed_messages);

    var messages = std.json.Array.init(allocator);
    errdefer messages.deinit();

    // Determine if we should use developer role for reasoning models
    const use_developer_role = model.reasoning and !isNonStandardProvider(model);

    // Add system prompt if present
    if (context.system_prompt) |system| {
        const role = if (use_developer_role) "developer" else "system";
        const sanitized = try sanitizeSurrogates(allocator, system);
        defer allocator.free(sanitized);
        try messages.append(std.json.Value{ .object = try buildMessageObject(allocator, role, sanitized) });
    }

    // Add conversation messages
    for (transformed_messages) |msg| {
        switch (msg) {
            .user => |user_msg| {
                try messages.append(try buildUserMessage(allocator, model, user_msg));
            },
            .assistant => |assistant_msg| {
                try messages.append(try buildAssistantMessage(allocator, model, assistant_msg));
            },
            .tool_result => |tool_result| {
                try messages.append(try buildToolResultMessage(allocator, model, tool_result));
            },
        }
    }

    var payload = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer payload.deinit(allocator);

    try payload.put(allocator, try allocator.dupe(u8, "model"), std.json.Value{ .string = try allocator.dupe(u8, model.id) });
    try payload.put(allocator, try allocator.dupe(u8, "messages"), std.json.Value{ .array = messages });
    try payload.put(allocator, try allocator.dupe(u8, "stream"), std.json.Value{ .bool = true });

    // Add stream_options.include_usage
    var stream_options = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer stream_options.deinit(allocator);
    try stream_options.put(allocator, try allocator.dupe(u8, "include_usage"), std.json.Value{ .bool = true });
    try payload.put(allocator, try allocator.dupe(u8, "stream_options"), std.json.Value{ .object = stream_options });

    if (options) |opts| {
        if (opts.temperature) |temp| {
            try payload.put(allocator, try allocator.dupe(u8, "temperature"), std.json.Value{ .float = temp });
        }
        if (opts.max_tokens) |max| {
            try payload.put(allocator, try allocator.dupe(u8, "max_tokens"), std.json.Value{ .integer = @intCast(max) });
        }
    }

    // Add tools if present
    if (context.tools) |tools| {
        if (tools.len > 0) {
            var tools_array = std.json.Array.init(allocator);
            errdefer tools_array.deinit();
            for (tools) |tool| {
                try tools_array.append(try buildToolObject(allocator, tool));
            }
            try payload.put(allocator, try allocator.dupe(u8, "tools"), std.json.Value{ .array = tools_array });
        }
    }

    return std.json.Value{ .object = payload };
}

const OpenAICompat = struct {
    requires_thinking_as_text: bool = false,
    requires_reasoning_content_on_assistant_messages: bool = false,
};

fn getCompat(model: types.Model) OpenAICompat {
    return .{
        .requires_thinking_as_text = compatBoolField(model.compat, "requiresThinkingAsText") orelse false,
        .requires_reasoning_content_on_assistant_messages = compatBoolField(model.compat, "requiresReasoningContentOnAssistantMessages") orelse false,
    };
}

fn compatBoolField(compat: ?std.json.Value, key: []const u8) ?bool {
    const value = compat orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

fn isNonStandardProvider(model: types.Model) bool {
    const provider = model.provider;
    const base_url = model.base_url;

    if (std.mem.eql(u8, provider, "cerebras") or
        std.mem.eql(u8, provider, "xai") or
        std.mem.eql(u8, provider, "zai") or
        std.mem.eql(u8, provider, "opencode"))
    {
        return true;
    }

    if (std.mem.indexOf(u8, base_url, "cerebras.ai") != null or
        std.mem.indexOf(u8, base_url, "api.x.ai") != null or
        std.mem.indexOf(u8, base_url, "chutes.ai") != null or
        std.mem.indexOf(u8, base_url, "deepseek.com") != null or
        std.mem.indexOf(u8, base_url, "api.z.ai") != null or
        std.mem.indexOf(u8, base_url, "opencode.ai") != null)
    {
        return true;
    }

    return false;
}

fn buildRequestHeaders(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitOwnedHeaders(allocator, &headers);

    try putOwnedHeader(allocator, &headers, "Content-Type", "application/json");
    try putOwnedHeader(allocator, &headers, "Accept", "text/event-stream");

    const api_key = if (options) |opts| opts.api_key orelse "" else "";
    if (std.mem.trim(u8, api_key, &std.ascii.whitespace).len > 0) {
        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
        defer allocator.free(auth_header);
        try putOwnedHeader(allocator, &headers, "Authorization", auth_header);
    }

    try mergeHeaders(allocator, &headers, model.headers);
    if (options) |stream_options| {
        try mergeHeaders(allocator, &headers, stream_options.headers);
    }

    return headers;
}

fn putOwnedHeader(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    if (headers.fetchRemove(name)) |removed| {
        allocator.free(removed.key);
        allocator.free(removed.value);
    }
    try headers.put(try allocator.dupe(u8, name), try allocator.dupe(u8, value));
}

fn mergeHeaders(
    allocator: std.mem.Allocator,
    target: *std.StringHashMap([]const u8),
    source: ?std.StringHashMap([]const u8),
) !void {
    if (source) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            try putOwnedHeader(allocator, target, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

fn deinitOwnedHeaders(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

fn normalizeToolCallId(
    allocator: std.mem.Allocator,
    id: []const u8,
    model: types.Model,
    source: types.AssistantMessage,
) ![]const u8 {
    _ = source;

    if (std.mem.indexOfScalar(u8, id, '|')) |separator_index| {
        const prefix = id[0..separator_index];
        return sanitizeOpenAIToolCallId(allocator, prefix);
    }

    if (std.mem.eql(u8, model.provider, "openai")) {
        const trimmed = if (id.len > 40) id[0..40] else id;
        return try allocator.dupe(u8, trimmed);
    }

    return try allocator.dupe(u8, id);
}

fn sanitizeOpenAIToolCallId(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (id) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-') {
            try result.append(allocator, byte);
        } else {
            try result.append(allocator, '_');
        }
        if (result.items.len == 40) break;
    }

    return try result.toOwnedSlice(allocator);
}

fn buildUserMessage(allocator: std.mem.Allocator, model: types.Model, user_msg: types.UserMessage) !std.json.Value {
    // Check if message contains images
    var has_images = false;
    for (user_msg.content) |block| {
        if (block == .image) {
            has_images = true;
            break;
        }
    }

    // Check if model supports images
    var model_supports_images = false;
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) {
            model_supports_images = true;
            break;
        }
    }

    if (has_images and model_supports_images) {
        // Build content as array of parts
        var content_parts = std.json.Array.init(allocator);
        errdefer content_parts.deinit();

        for (user_msg.content) |block| {
            switch (block) {
                .text => |text| {
                    const sanitized = try sanitizeSurrogates(allocator, text.text);
                    defer allocator.free(sanitized);
                    var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    errdefer part.deinit(allocator);
                    try part.put(allocator, try allocator.dupe(u8, "type"), std.json.Value{ .string = try allocator.dupe(u8, "text") });
                    try part.put(allocator, try allocator.dupe(u8, "text"), std.json.Value{ .string = try allocator.dupe(u8, sanitized) });
                    try content_parts.append(std.json.Value{ .object = part });
                },
                .image => |image| {
                    var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    errdefer part.deinit(allocator);
                    try part.put(allocator, try allocator.dupe(u8, "type"), std.json.Value{ .string = try allocator.dupe(u8, "image_url") });

                    const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.mime_type, image.data });
                    defer allocator.free(url);

                    var image_url = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    errdefer image_url.deinit(allocator);
                    try image_url.put(allocator, try allocator.dupe(u8, "url"), std.json.Value{ .string = try allocator.dupe(u8, url) });
                    try part.put(allocator, try allocator.dupe(u8, "image_url"), std.json.Value{ .object = image_url });
                    try content_parts.append(std.json.Value{ .object = part });
                },
                .thinking => continue, // User messages shouldn't have thinking blocks
            }
        }

        var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        errdefer obj.deinit(allocator);
        try obj.put(allocator, try allocator.dupe(u8, "role"), std.json.Value{ .string = try allocator.dupe(u8, "user") });
        try obj.put(allocator, try allocator.dupe(u8, "content"), std.json.Value{ .array = content_parts });
        return std.json.Value{ .object = obj };
    } else {
        // Plain text content
        var text_parts = std.ArrayList(u8).empty;
        defer text_parts.deinit(allocator);

        for (user_msg.content) |block| {
            switch (block) {
                .text => |text| {
                    if (text_parts.items.len > 0) {
                        try text_parts.appendSlice(allocator, "\n");
                    }
                    try text_parts.appendSlice(allocator, text.text);
                },
                .image => {
                    if (!model_supports_images) {
                        if (text_parts.items.len > 0) {
                            try text_parts.appendSlice(allocator, "\n");
                        }
                        try text_parts.appendSlice(allocator, "(image omitted: model does not support images)");
                    }
                },
                .thinking => continue,
            }
        }

        const sanitized = try sanitizeSurrogates(allocator, text_parts.items);
        defer allocator.free(sanitized);
        return std.json.Value{ .object = try buildMessageObject(allocator, "user", sanitized) };
    }
}

fn buildAssistantMessage(allocator: std.mem.Allocator, model: types.Model, assistant_msg: types.AssistantMessage) !std.json.Value {
    const compat = getCompat(model);

    var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer obj.deinit(allocator);
    try obj.put(allocator, try allocator.dupe(u8, "role"), std.json.Value{ .string = try allocator.dupe(u8, "assistant") });

    var text_parts = std.ArrayList(u8).empty;
    defer text_parts.deinit(allocator);
    var thinking_parts = std.ArrayList(u8).empty;
    defer thinking_parts.deinit(allocator);
    var reasoning_field_name: ?[]const u8 = null;

    for (assistant_msg.content) |block| {
        switch (block) {
            .text => |text| {
                if (text_parts.items.len > 0) {
                    try text_parts.appendSlice(allocator, "\n");
                }
                try text_parts.appendSlice(allocator, text.text);
            },
            .thinking => |thinking| {
                const trimmed = std.mem.trim(u8, thinking.thinking, " \t\r\n");
                if (trimmed.len == 0 and thinking.signature == null) continue;
                if (compat.requires_thinking_as_text) {
                    if (trimmed.len == 0) continue;
                    if (thinking_parts.items.len > 0) {
                        try thinking_parts.appendSlice(allocator, "\n\n");
                    }
                    try thinking_parts.appendSlice(allocator, thinking.thinking);
                } else if (thinking.signature) |signature| {
                    if (trimmed.len > 0) {
                        if (reasoning_field_name == null) reasoning_field_name = signature;
                        if (reasoning_field_name != null and std.mem.eql(u8, reasoning_field_name.?, signature)) {
                            if (thinking_parts.items.len > 0) {
                                try thinking_parts.appendSlice(allocator, "\n");
                            }
                            try thinking_parts.appendSlice(allocator, thinking.thinking);
                        }
                    }
                }
            },
            .image => continue,
        }
    }

    if (compat.requires_thinking_as_text and thinking_parts.items.len > 0) {
        if (text_parts.items.len > 0) {
            try thinking_parts.appendSlice(allocator, "\n\n");
            try thinking_parts.appendSlice(allocator, text_parts.items);
        }
        text_parts.clearRetainingCapacity();
        try text_parts.appendSlice(allocator, thinking_parts.items);
    }

    const content = if (text_parts.items.len > 0) try sanitizeSurrogates(allocator, text_parts.items) else try allocator.dupe(u8, "");
    defer allocator.free(content);
    try obj.put(allocator, try allocator.dupe(u8, "content"), std.json.Value{ .string = try allocator.dupe(u8, content) });

    if (!compat.requires_thinking_as_text and thinking_parts.items.len > 0 and reasoning_field_name != null) {
        const sanitized_reasoning = try sanitizeSurrogates(allocator, thinking_parts.items);
        defer allocator.free(sanitized_reasoning);
        try obj.put(
            allocator,
            try allocator.dupe(u8, reasoning_field_name.?),
            std.json.Value{ .string = try allocator.dupe(u8, sanitized_reasoning) },
        );
    } else if (compat.requires_reasoning_content_on_assistant_messages and model.reasoning and obj.get("reasoning_content") == null) {
        try obj.put(allocator, try allocator.dupe(u8, "reasoning_content"), std.json.Value{ .string = try allocator.dupe(u8, "") });
    }

    // Add tool_calls if present
    if (assistant_msg.tool_calls) |tool_calls| {
        var tc_array = std.json.Array.init(allocator);
        errdefer tc_array.deinit();
        for (tool_calls) |tc| {
            var tc_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            errdefer tc_obj.deinit(allocator);
            try tc_obj.put(allocator, try allocator.dupe(u8, "id"), std.json.Value{ .string = try allocator.dupe(u8, tc.id) });
            try tc_obj.put(allocator, try allocator.dupe(u8, "type"), std.json.Value{ .string = try allocator.dupe(u8, "function") });

            var func_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            errdefer func_obj.deinit(allocator);
            try func_obj.put(allocator, try allocator.dupe(u8, "name"), std.json.Value{ .string = try allocator.dupe(u8, tc.name) });

            const args_owned = try std.json.Stringify.valueAlloc(allocator, tc.arguments, .{});
            defer allocator.free(args_owned);
            try func_obj.put(allocator, try allocator.dupe(u8, "arguments"), std.json.Value{ .string = try allocator.dupe(u8, args_owned) });

            try tc_obj.put(allocator, try allocator.dupe(u8, "function"), std.json.Value{ .object = func_obj });
            try tc_array.append(std.json.Value{ .object = tc_obj });
        }
        try obj.put(allocator, try allocator.dupe(u8, "tool_calls"), std.json.Value{ .array = tc_array });
    }

    return std.json.Value{ .object = obj };
}

fn buildToolResultMessage(allocator: std.mem.Allocator, model: types.Model, tool_result: types.ToolResultMessage) !std.json.Value {
    var text_parts = std.ArrayList(u8).empty;
    defer text_parts.deinit(allocator);

    var has_images = false;
    for (tool_result.content) |block| {
        switch (block) {
            .text => |text| {
                if (text_parts.items.len > 0) {
                    try text_parts.appendSlice(allocator, "\n");
                }
                try text_parts.appendSlice(allocator, text.text);
            },
            .image => {
                has_images = true;
            },
            .thinking => continue,
        }
    }

    const content = if (text_parts.items.len > 0)
        try sanitizeSurrogates(allocator, text_parts.items)
    else if (has_images)
        try allocator.dupe(u8, "(see attached image)")
    else
        try allocator.dupe(u8, "");
    defer allocator.free(content);

    var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer obj.deinit(allocator);
    try obj.put(allocator, try allocator.dupe(u8, "role"), std.json.Value{ .string = try allocator.dupe(u8, "tool") });
    try obj.put(allocator, try allocator.dupe(u8, "content"), std.json.Value{ .string = try allocator.dupe(u8, content) });
    try obj.put(allocator, try allocator.dupe(u8, "tool_call_id"), std.json.Value{ .string = try allocator.dupe(u8, tool_result.tool_call_id) });

    // Add name if required by provider
    if (tool_result.tool_name.len > 0) {
        try obj.put(allocator, try allocator.dupe(u8, "name"), std.json.Value{ .string = try allocator.dupe(u8, tool_result.tool_name) });
    }

    // If there are images and model supports them, add as separate user message
    var model_supports_images = false;
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) {
            model_supports_images = true;
            break;
        }
    }

    if (has_images and model_supports_images) {
        // This is a simplified approach - in full implementation we'd need to
        // return multiple messages. For now, just include the text content.
        // Images from tool results would be added in a subsequent user message.
    }

    return std.json.Value{ .object = obj };
}

fn buildToolObject(allocator: std.mem.Allocator, tool: types.Tool) !std.json.Value {
    var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer obj.deinit(allocator);
    try obj.put(allocator, try allocator.dupe(u8, "type"), std.json.Value{ .string = try allocator.dupe(u8, "function") });

    var func_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer func_obj.deinit(allocator);
    try func_obj.put(allocator, try allocator.dupe(u8, "name"), std.json.Value{ .string = try allocator.dupe(u8, tool.name) });
    try func_obj.put(allocator, try allocator.dupe(u8, "description"), std.json.Value{ .string = try allocator.dupe(u8, tool.description) });
    try func_obj.put(allocator, try allocator.dupe(u8, "parameters"), try cloneJsonValue(allocator, tool.parameters));
    try func_obj.put(allocator, try allocator.dupe(u8, "strict"), std.json.Value{ .bool = false });

    try obj.put(allocator, try allocator.dupe(u8, "function"), std.json.Value{ .object = func_obj });
    return std.json.Value{ .object = obj };
}

fn buildMessageObject(allocator: std.mem.Allocator, role: []const u8, content: []const u8) !std.json.ObjectMap {
    var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer obj.deinit(allocator);
    try obj.put(allocator, try allocator.dupe(u8, "role"), std.json.Value{ .string = try allocator.dupe(u8, role) });
    try obj.put(allocator, try allocator.dupe(u8, "content"), std.json.Value{ .string = try allocator.dupe(u8, content) });
    return obj;
}

/// Parse SSE line and extract JSON data
pub fn parseSseLine(line: []const u8) ?[]const u8 {
    const prefix = "data: ";
    if (std.mem.startsWith(u8, line, prefix)) {
        return line[prefix.len..];
    }
    return null;
}

/// Parse a streaming chunk from OpenAI
/// Returns a parsed JSON value or null. Caller must call `.deinit()` on the result.
pub fn parseChunk(allocator: std.mem.Allocator, data: []const u8) !?std.json.Parsed(std.json.Value) {
    if (data.len == 0 or std.mem.eql(u8, data, "[DONE]")) {
        return null;
    }
    return try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
}

test "buildRequestPayload basic" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const context = types.Context{
        .system_prompt = "You are a helpful assistant.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1234567890,
            } },
        },
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer freeJsonValue(allocator, payload);

    try std.testing.expect(payload == .object);
    const model_val = payload.object.get("model").?;
    try std.testing.expectEqualStrings("gpt-4", model_val.string);

    const messages = payload.object.get("messages").?;
    try std.testing.expect(messages == .array);
    try std.testing.expectEqual(@as(usize, 2), messages.array.items.len);

    // Check stream_options.include_usage
    const stream_options = payload.object.get("stream_options").?;
    try std.testing.expect(stream_options == .object);
    const include_usage = stream_options.object.get("include_usage").?;
    try std.testing.expect(include_usage == .bool);
    try std.testing.expect(include_usage.bool);
}

test "buildRequestPayload with developer role for reasoning model" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "o1-preview",
        .name = "O1 Preview",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 32768,
    };

    const context = types.Context{
        .system_prompt = "You are a reasoning assistant.",
        .messages = &[_]types.Message{},
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer freeJsonValue(allocator, payload);

    const messages = payload.object.get("messages").?;
    try std.testing.expectEqual(@as(usize, 1), messages.array.items.len);

    const first_msg = messages.array.items[0];
    try std.testing.expect(first_msg == .object);
    const role = first_msg.object.get("role").?;
    try std.testing.expectEqualStrings("developer", role.string);
}

test "buildRequestPayload with tools" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    var tool_schema = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) };
    defer freeJsonValue(allocator, tool_schema);
    try tool_schema.object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });

    const tools = &[_]types.Tool{
        .{
            .name = "get_weather",
            .description = "Get the weather for a location",
            .parameters = tool_schema,
        },
    };

    const context = types.Context{
        .system_prompt = null,
        .messages = &[_]types.Message{},
        .tools = tools,
    };

    {
        const payload = try buildRequestPayload(allocator, model, context, null);
        defer freeJsonValue(allocator, payload);

        const tools_val = payload.object.get("tools").?;
        try std.testing.expect(tools_val == .array);
        try std.testing.expectEqual(@as(usize, 1), tools_val.array.items.len);

        const tool = tools_val.array.items[0];
        try std.testing.expect(tool == .object);
        const tool_type = tool.object.get("type").?;
        try std.testing.expectEqualStrings("function", tool_type.string);
    }

    const schema_type = tool_schema.object.get("type").?;
    try std.testing.expectEqualStrings("object", schema_type.string);
    try tool_schema.object.put(allocator, try allocator.dupe(u8, "required"), .{ .array = std.json.Array.init(allocator) });
}

test "buildRequestPayload with image content" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-4-vision",
        .name = "GPT-4 Vision",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const context = types.Context{
        .system_prompt = null,
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "What's in this image?" } },
                    .{ .image = .{ .data = "base64data", .mime_type = "image/png" } },
                },
                .timestamp = 1234567890,
            } },
        },
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer freeJsonValue(allocator, payload);

    const messages = payload.object.get("messages").?;
    const user_msg = messages.array.items[0];
    try std.testing.expect(user_msg == .object);

    const content = user_msg.object.get("content").?;
    try std.testing.expect(content == .array);
    try std.testing.expectEqual(@as(usize, 2), content.array.items.len);

    const image_part = content.array.items[1];
    try std.testing.expect(image_part == .object);
    const part_type = image_part.object.get("type").?;
    try std.testing.expectEqualStrings("image_url", part_type.string);
}

test "parseSseLine" {
    const line = "data: {\"foo\": 123}";
    const result = parseSseLine(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{\"foo\": 123}", result.?);

    const no_data = "event: start";
    const no_result = parseSseLine(no_data);
    try std.testing.expect(no_result == null);
}

test "parseChunk" {
    const allocator = std.testing.allocator;

    const done = try parseChunk(allocator, "[DONE]");
    try std.testing.expect(done == null);

    const empty = try parseChunk(allocator, "");
    try std.testing.expect(empty == null);

    const valid = try parseChunk(allocator, "{\"foo\": 123}");
    defer if (valid) |*v| v.deinit();
    try std.testing.expect(valid != null);
    try std.testing.expect(valid.?.value == .object);
}

test "mapStopReason" {
    const allocator = std.testing.allocator;

    const r1 = try mapStopReason(allocator, "stop");
    try std.testing.expectEqual(types.StopReason.stop, r1.stop_reason);
    try std.testing.expect(r1.error_message == null);

    const r2 = try mapStopReason(allocator, "length");
    try std.testing.expectEqual(types.StopReason.length, r2.stop_reason);
    try std.testing.expect(r2.error_message == null);

    const r3 = try mapStopReason(allocator, "tool_calls");
    try std.testing.expectEqual(types.StopReason.tool_use, r3.stop_reason);
    try std.testing.expect(r3.error_message == null);

    const r4 = try mapStopReason(allocator, "content_filter");
    defer if (r4.error_message) |message| allocator.free(message);
    try std.testing.expectEqual(types.StopReason.error_reason, r4.stop_reason);
    try std.testing.expect(r4.error_message != null);
    try std.testing.expectEqualStrings("Provider finish_reason: content_filter", r4.error_message.?);

    const reason = "unknown_reason";
    const r5 = try mapStopReason(allocator, reason);
    defer if (r5.error_message) |message| allocator.free(message);
    try std.testing.expectEqual(types.StopReason.error_reason, r5.stop_reason);
    try std.testing.expect(r5.error_message != null);
    try std.testing.expectEqualStrings("Provider finish_reason: unknown_reason", r5.error_message.?);
    try std.testing.expect(r5.error_message.?.ptr != reason.ptr);
}

test "sanitizeSurrogates preserves valid emoji" {
    const allocator = std.testing.allocator;
    // "🙈" in UTF-8: F0 9F 99 88 (not surrogates, it's a 4-byte sequence)
    const text = "Hello 🙈 World";
    const result = try sanitizeSurrogates(allocator, text);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(text, result);
}

test "sanitizeSurrogates removes unpaired surrogate bytes with caller allocator" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 'A', 0xED, 0xA0, 0x80, 'B', 0xED, 0xB0, 0x80, 'C' };
    const result = try sanitizeSurrogates(allocator, &input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ABC", result);
}

test "buildRequestHeaders merges model and option headers" {
    const allocator = std.testing.allocator;

    var model_headers = std.StringHashMap([]const u8).init(allocator);
    defer model_headers.deinit();
    try model_headers.put("X-Model", "model");
    try model_headers.put("X-Shared", "model");

    var option_headers = std.StringHashMap([]const u8).init(allocator);
    defer option_headers.deinit();
    try option_headers.put("X-Option", "option");
    try option_headers.put("X-Shared", "option");

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
        .headers = model_headers,
    };

    var headers = try buildRequestHeaders(allocator, model, .{
        .api_key = "test-key",
        .headers = option_headers,
    });
    defer deinitOwnedHeaders(allocator, &headers);

    try std.testing.expectEqualStrings("application/json", headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("Bearer test-key", headers.get("Authorization").?);
    try std.testing.expectEqualStrings("text/event-stream", headers.get("Accept").?);
    try std.testing.expectEqualStrings("model", headers.get("X-Model").?);
    try std.testing.expectEqualStrings("option", headers.get("X-Option").?);
    try std.testing.expectEqualStrings("option", headers.get("X-Shared").?);

    var anonymous_headers = try buildRequestHeaders(allocator, model, .{});
    defer deinitOwnedHeaders(allocator, &anonymous_headers);
    try std.testing.expect(anonymous_headers.get("Authorization") == null);
}

test "buildRequestPayload transforms orphaned tool calls and normalizes ids" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 16384,
    };

    const assistant_arguments = std.json.Value{
        .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}),
    };
    defer freeJsonValue(allocator, assistant_arguments);

    const assistant = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .tool_calls = &[_]types.ToolCall{.{
            .id = "call_1|fc_1",
            .name = "weather",
            .arguments = assistant_arguments,
        }},
        .api = "openai-responses",
        .provider = "openai",
        .model = "gpt-5",
        .usage = types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 1,
    };

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .assistant = assistant },
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Continue" } }},
                .timestamp = 2,
            } },
        },
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer freeJsonValue(allocator, payload);

    const messages = payload.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), messages.len);

    const assistant_message = messages[0].object;
    const tool_calls = assistant_message.get("tool_calls").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tool_calls.len);
    try std.testing.expectEqualStrings("call_1", tool_calls[0].object.get("id").?.string);

    const synthetic_tool_result = messages[1].object;
    try std.testing.expectEqualStrings("tool", synthetic_tool_result.get("role").?.string);
    try std.testing.expectEqualStrings("call_1", synthetic_tool_result.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings("No result provided", synthetic_tool_result.get("content").?.string);

    const user_message = messages[2].object;
    try std.testing.expectEqualStrings("user", user_message.get("role").?.string);
}

test "buildRequestPayload omits empty tools array" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const context = types.Context{
        .messages = &[_]types.Message{},
        .tools = &[_]types.Tool{},
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer freeJsonValue(allocator, payload);

    try std.testing.expect(payload.object.get("tools") == null);
}

test "buildAssistantMessage separates thinking from text" {
    const allocator = std.testing.allocator;

    var compat = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try compat.put(allocator, try allocator.dupe(u8, "requiresThinkingAsText"), .{ .bool = false });
    try compat.put(allocator, try allocator.dupe(u8, "requiresReasoningContentOnAssistantMessages"), .{ .bool = true });
    const compat_value = std.json.Value{ .object = compat };
    defer freeJsonValue(allocator, compat_value);

    const model = types.Model{
        .id = "deepseek-reasoner",
        .name = "DeepSeek Reasoner",
        .api = "openai-completions",
        .provider = "deepseek",
        .base_url = "https://api.deepseek.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 32768,
        .compat = compat_value,
    };

    const assistant = types.AssistantMessage{
        .content = &[_]types.ContentBlock{
            .{ .thinking = .{ .thinking = "internal reasoning", .signature = "reasoning_content" } },
            .{ .text = .{ .text = "final answer" } },
        },
        .api = "openai-completions",
        .provider = "deepseek",
        .model = "deepseek-reasoner",
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };

    const message = try buildAssistantMessage(allocator, model, assistant);
    defer freeJsonValue(allocator, message);

    try std.testing.expectEqualStrings("final answer", message.object.get("content").?.string);
    try std.testing.expectEqualStrings("internal reasoning", message.object.get("reasoning_content").?.string);
}

test "stream respects pre-aborted signal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var aborted = std.atomic.Value(bool).init(true);

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "http://127.0.0.1:1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    try std.testing.expectError(
        error.RequestAborted,
        OpenAIProvider.stream(allocator, io, model, context, .{
            .api_key = "test-key",
            .signal = &aborted,
        }),
    );
}

test "stream emits single terminal sanitized error for HTTP status" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"error\":\"quota exceeded\",\"Authorization\":\"Bearer sk-live-secret\",\"request_id\":\"req_random_123456789\",\"trace\":\"/Users/alice/pi/trace.zig:1\"}");
    try body.appendNTimes(allocator, 'x', 900);

    var server = try provider_error.TestStatusServer.init(
        io,
        429,
        "Too Many Requests",
        "x-request-id: req_header_secret\r\n",
        body.items,
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream_instance = try OpenAIProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream_instance.deinit();

    const event = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 429: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "quota exceeded") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "[truncated]") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-live-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expectEqualStrings("openai-completions", event.message.?.api);
    try std.testing.expectEqualStrings("openai", event.message.?.provider);
    try std.testing.expectEqualStrings("gpt-4", event.message.?.model);
    try std.testing.expect(stream_instance.next() == null);

    const result = stream_instance.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(event.message.?.stop_reason, result.stop_reason);
    try std.testing.expectEqual(event.message.?.usage.total_tokens, result.usage.total_tokens);
}

const RuntimeFailureServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    first_chunk: []const u8,
    second_chunk: []const u8,
    delay_ms: u64,
    thread: ?std.Thread = null,

    fn init(io: std.Io, first_chunk: []const u8, second_chunk: []const u8, delay_ms: u64) !RuntimeFailureServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .first_chunk = first_chunk,
            .second_chunk = second_chunk,
            .delay_ms = delay_ms,
        };
    }

    fn start(self: *RuntimeFailureServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *RuntimeFailureServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    fn url(self: *const RuntimeFailureServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }

    fn run(self: *RuntimeFailureServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => std.debug.panic("runtime failure server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);

        readRequestHead(stream) catch |err| std.debug.panic("runtime failure server read failed: {}", .{err});
        writeResponse(self, stream) catch {};
    }

    fn readRequestHead(stream: std.Io.net.Stream) !void {
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);
        var tail = [_]u8{ 0, 0, 0, 0 };
        var count: usize = 0;

        while (true) {
            const byte = try reader.interface.takeByte();
            tail[count % tail.len] = byte;
            count += 1;

            if (count >= 4) {
                const start_index = count % tail.len;
                const ordered = [_]u8{
                    tail[start_index],
                    tail[(start_index + 1) % tail.len],
                    tail[(start_index + 2) % tail.len],
                    tail[(start_index + 3) % tail.len],
                };
                if (std.mem.eql(u8, &ordered, "\r\n\r\n")) break;
            }
        }
    }

    fn writeResponse(self: *RuntimeFailureServer, stream: std.Io.net.Stream) !void {
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        const total_len = self.first_chunk.len + self.second_chunk.len;
        try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{total_len},
        );
        try writer.interface.flush();
        try writer.interface.writeAll(self.first_chunk);
        try writer.interface.flush();
        if (self.delay_ms > 0) {
            std.Io.sleep(self.io, .fromMilliseconds(@intCast(self.delay_ms)), .awake) catch {};
        }
        try writer.interface.writeAll(self.second_chunk);
        try writer.interface.flush();
    }
};

fn runtimeFailureTestModel(base_url: []const u8) types.Model {
    return .{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };
}

fn runtimeFailureContext() types.Context {
    return .{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };
}

test "parseSseStreamLines preserves partial text before malformed event JSON terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n" ++
            "data: {not-json}\n" ++
            "data: [DONE]\n",
    );

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimeFailureTestModel("https://api.openai.com/v1"));

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);

    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial", delta.delta.?);

    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial", text_end.content.?);

    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings(terminal.error_message.?, terminal.message.?.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
}

test "stream preserves partial text before timeout terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var server = try RuntimeFailureServer.init(
        io,
        "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n",
        "data: [DONE]\n",
        500,
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var stream = try OpenAIProvider.stream(allocator, io, runtimeFailureTestModel(url), runtimeFailureContext(), .{
        .api_key = "test-key",
        .timeout_ms = 100,
    });
    defer stream.deinit();

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial", delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream.next().?.event_type);

    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("Timeout", terminal.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);
}

test "stream preserves partial text before mid-stream abort terminal event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var server = try RuntimeFailureServer.init(
        io,
        "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n",
        "data: [DONE]\n",
        500,
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var abort_signal = std.atomic.Value(bool).init(false);
    const abort_thread = try std.Thread.spawn(.{}, struct {
        fn run(signal: *std.atomic.Value(bool), test_io: std.Io) void {
            std.Io.sleep(test_io, .fromMilliseconds(50), .awake) catch {};
            signal.store(true, .seq_cst);
        }
    }.run, .{ &abort_signal, io });
    defer abort_thread.join();

    var stream = try OpenAIProvider.stream(allocator, io, runtimeFailureTestModel(url), runtimeFailureContext(), .{
        .api_key = "test-key",
        .signal = &abort_signal,
    });
    defer stream.deinit();

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial", delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream.next().?.event_type);

    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("Request was aborted", terminal.error_message.?);
    try std.testing.expectEqual(types.StopReason.aborted, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);
}

test "parseSseStream with tool calls" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(u8, "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_123\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"NYC\\\"}\"}}]}}]}\n" ++
        "data: [DONE]\n");
    // body is owned by StreamingResponse, do not free here

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model);

    // Should emit start, toolcall_start, toolcall_delta, toolcall_end, done
    const event1 = stream.next().?;
    defer freeEvent(allocator, event1);
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream.next().?;
    defer freeEvent(allocator, event2);
    try std.testing.expectEqual(types.EventType.toolcall_start, event2.event_type);

    const event3 = stream.next().?;
    defer freeEvent(allocator, event3);
    try std.testing.expectEqual(types.EventType.toolcall_delta, event3.event_type);

    const event4 = stream.next().?;
    defer freeEvent(allocator, event4);
    try std.testing.expectEqual(types.EventType.toolcall_end, event4.event_type);
    try std.testing.expect(event4.tool_call != null);
    try std.testing.expectEqualStrings("get_weather", event4.tool_call.?.name);

    const event5 = stream.next().?;
    defer freeEvent(allocator, event5);
    try std.testing.expectEqual(types.EventType.done, event5.event_type);
    try std.testing.expect(event5.message != null);
    try std.testing.expectEqual(types.StopReason.tool_use, event5.message.?.stop_reason);
    try std.testing.expect(event5.message.?.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), event5.message.?.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_123", event5.message.?.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("get_weather", event5.message.?.tool_calls.?[0].name);
}

test "parseSseStream with reasoning content" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(u8, "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Let me think...\"}}]}\n" ++
        "data: [DONE]\n");
    // body is owned by StreamingResponse, do not free here

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "deepseek-reasoner",
        .name = "DeepSeek Reasoner",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model);

    const event1 = stream.next().?;
    defer freeEvent(allocator, event1);
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream.next().?;
    defer freeEvent(allocator, event2);
    try std.testing.expectEqual(types.EventType.thinking_start, event2.event_type);

    const event3 = stream.next().?;
    defer freeEvent(allocator, event3);
    try std.testing.expectEqual(types.EventType.thinking_delta, event3.event_type);
    try std.testing.expectEqualStrings("Let me think...", event3.delta.?);

    const event4 = stream.next().?;
    defer freeEvent(allocator, event4);
    try std.testing.expectEqual(types.EventType.thinking_end, event4.event_type);

    const event5 = stream.next().?;
    defer freeEvent(allocator, event5);
    try std.testing.expectEqual(types.EventType.done, event5.event_type);
}

test "parseSseStream with usage" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(u8, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20}}\n" ++
        "data: [DONE]\n");
    // body is owned by StreamingResponse, do not free here

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model);

    const event1 = stream.next().?;
    defer freeEvent(allocator, event1);
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream.next().?;
    defer freeEvent(allocator, event2);
    try std.testing.expectEqual(types.EventType.done, event2.event_type);

    const result = stream.result().?;
    try std.testing.expectEqual(@as(u32, 10), result.usage.input);
    try std.testing.expectEqual(@as(u32, 20), result.usage.output);
}

test "parseChunkUsage" {
    const allocator = std.testing.allocator;

    const usage_json = "{\"prompt_tokens\":100,\"completion_tokens\":50,\"prompt_tokens_details\":{\"cached_tokens\":20,\"cache_write_tokens\":10},\"completion_tokens_details\":{\"reasoning_tokens\":5}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, usage_json, .{});
    defer parsed.deinit();

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const usage = parseChunkUsage(allocator, parsed.value, model);

    // input = 100 - 10 (cache read after subtracting write) - 10 (cache write) = 80
    // Wait: normalized_cache_read = 20 - 10 = 10
    // input = 100 - 10 - 10 = 80
    // output = 50 because completion_tokens already includes reasoning_tokens
    try std.testing.expectEqual(@as(u32, 80), usage.input);
    try std.testing.expectEqual(@as(u32, 50), usage.output);
    try std.testing.expectEqual(@as(u32, 10), usage.cache_read);
    try std.testing.expectEqual(@as(u32, 10), usage.cache_write);
    try std.testing.expectEqual(@as(u32, 150), usage.total_tokens);
}
