const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const event_stream = @import("../event_stream.zig");
const json_parse = @import("../json_parse.zig");
const finalize = @import("../shared/finalize.zig");
const provider_error = @import("../shared/provider_error.zig");
const provider_json = @import("../shared/provider_json.zig");
const sse_loop = @import("../shared/sse_loop.zig");
const anthropic_request_headers = @import("anthropic_request_headers.zig");
const anthropic_message_stop = @import("anthropic_message_stop.zig");

const AnthropicError = error{
    InvalidAnthropicChunk,
};

const CurrentBlock = union(enum) {
    text: std.ArrayList(u8),
    thinking: struct {
        text: std.ArrayList(u8),
        signature: ?[]const u8,
        redacted: bool,
    },
    tool_call: struct {
        id: []const u8,
        name: []const u8,
        partial_json: std.ArrayList(u8),
    },
};

const BlockEntry = struct {
    anthropic_index: usize,
    event_index: usize,
    block: CurrentBlock,
};

fn shouldTolerateNoncanonicalAnthropicChunk(model: types.Model) bool {
    return anthropic_request_headers.isKimiCodingProvider(model);
}

pub fn parseSseStreamLines(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    streaming: *http_client.StreamingResponse,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !void {
    var output = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    };

    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);

    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);

    var active_blocks = std.ArrayList(BlockEntry).empty;
    defer {
        for (active_blocks.items) |*entry| deinitCurrentBlock(allocator, &entry.block);
        active_blocks.deinit(allocator);
    }

    stream_ptr.push(.{ .event_type = .start });

    var handler = AnthropicSseFrameHandler{
        .allocator = allocator,
        .stream_ptr = stream_ptr,
        .output = &output,
        .content_blocks = &content_blocks,
        .tool_calls = &tool_calls,
        .active_blocks = &active_blocks,
        .model = model,
        .context = context,
        .options = options,
    };
    const loop_result = sse_loop.runFrames(allocator, AnthropicSseFrameHandler, &handler, streaming, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, err);
            return;
        },
    };
    if (loop_result == .stopped) {
        return;
    }

    if (active_blocks.items.len > 0) {
        if (shouldTolerateNoncanonicalAnthropicChunk(model)) {
            try finalizeOutputFromPartials(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model);
            if (output.content.len == 0 and output.tool_calls == null) {
                const error_message = try allocator.dupe(u8, "Provider returned an empty assistant response");
                output.stop_reason = .error_reason;
                output.error_message = error_message;
                stream_ptr.push(.{
                    .event_type = .error_event,
                    .error_message = error_message,
                    .message = output,
                });
                stream_ptr.end(output);
                return;
            }
            stream_ptr.push(.{
                .event_type = .done,
                .message = output,
            });
            stream_ptr.end(output);
            return;
        } else {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, AnthropicError.InvalidAnthropicChunk);
            return;
        }
    }

    if (!shouldTolerateNoncanonicalAnthropicChunk(model) and handler.saw_message_start and !handler.saw_message_stop) {
        const error_message = try allocator.dupe(u8, "Anthropic stream ended before message_stop");
        try emitOwnedAnthropicStreamError(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, error_message);
        return;
    }

    if (content_blocks.items.len == 0 and tool_calls.items.len == 0) {
        const error_message = try allocator.dupe(u8, "Provider returned an empty assistant response");
        output.stop_reason = .error_reason;
        output.error_message = error_message;
        stream_ptr.push(.{
            .event_type = .error_event,
            .error_message = error_message,
            .message = output,
        });
        stream_ptr.end(output);
        return;
    }

    try finalize.finalizeOutput(allocator, &output, .{ .content_blocks = &content_blocks, .tool_calls = &tool_calls }, .{ .content_transfer = .always, .total_tokens = .preserve_or_full_usage, .coerce_stop_reason_for_tool_calls = true });
    finalize.calculateCost(model, &output.usage);
    // Tool calls live inline in output.content; legacy AssistantMessage.tool_calls
    // is intentionally left null. tool_calls ArrayList holds borrow-only copies
    // and tool_calls.deinit only releases its buffer.

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

const AnthropicSseFrameHandler = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    saw_message_start: bool = false,
    saw_message_stop: bool = false,

    pub fn handleFrame(self: *AnthropicSseFrameHandler, sse_event: []const u8, data: []const u8) !bool {
        const event_finished = try processAnthropicSseEvent(
            self.allocator,
            self.stream_ptr,
            sse_event,
            data,
            self.output,
            self.content_blocks,
            self.tool_calls,
            self.active_blocks,
            self.model,
            self.context,
            self.options,
            &self.saw_message_start,
            &self.saw_message_stop,
        );
        return !event_finished;
    }

    pub fn handleRuntimeFailure(self: *AnthropicSseFrameHandler, err: anyerror) !void {
        try emitRuntimeFailure(
            self.allocator,
            self.stream_ptr,
            self.output,
            self.content_blocks,
            self.tool_calls,
            self.active_blocks,
            self.model,
            err,
        );
    }
};

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
) !void {
    while (active_blocks.items.len > 0) {
        var entry = active_blocks.orderedRemove(0);
        defer deinitCurrentBlock(allocator, &entry.block);
        switch (entry.block) {
            .text => |text| {
                const owned = try allocator.dupe(u8, text.items);
                try content_blocks.append(allocator, .{ .text = .{ .text = owned } });
                stream_ptr.push(.{ .event_type = .text_end, .content_index = @intCast(entry.event_index), .content = owned });
            },
            .thinking => |thinking| {
                const text = try allocator.dupe(u8, thinking.text.items);
                const signature = if (thinking.signature) |sig| try allocator.dupe(u8, sig) else null;
                try content_blocks.append(allocator, .{ .thinking = .{ .thinking = text, .signature = signature, .redacted = thinking.redacted } });
                stream_ptr.push(.{ .event_type = .thinking_end, .content_index = @intCast(entry.event_index), .content = text });
            },
            .tool_call => |tool| {
                var parsed_arguments = try json_parse.parseStreamingJson(allocator, tool.partial_json.items);
                defer parsed_arguments.deinit();
                const arguments = try provider_json.cloneValue(allocator, parsed_arguments.value);
                const final_tool_call = blk: {
                    errdefer provider_json.freeValue(allocator, arguments);
                    const id = try allocator.dupe(u8, tool.id);
                    errdefer allocator.free(id);
                    const name = try allocator.dupe(u8, tool.name);
                    errdefer allocator.free(name);
                    break :blk types.ToolCall{
                        .id = id,
                        .name = name,
                        .arguments = arguments,
                    };
                };
                try finalize.appendInlineToolCall(allocator, content_blocks, tool_calls, final_tool_call);
                stream_ptr.push(.{ .event_type = .toolcall_end, .content_index = @intCast(entry.event_index), .tool_call = final_tool_call });
            },
        }
    }

    try finalize.finalizeOutput(allocator, output, .{ .content_blocks = content_blocks, .tool_calls = tool_calls }, .{ .content_transfer = .when_output_empty, .total_tokens = .preserve_or_full_usage, .coerce_stop_reason_for_tool_calls = false });
    finalize.calculateCost(model, &output.usage);
    // Tool calls are emitted inline; legacy field intentionally null.
}
fn emitRuntimeFailure(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    err: anyerror,
) !void {
    try finalizeOutputFromPartials(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model);
    provider_error.emitTerminalRuntimeFailure(stream_ptr, output, err);
}

fn isAnthropicMessageSseEvent(event_name: []const u8) bool {
    return std.mem.eql(u8, event_name, "message_start") or
        std.mem.eql(u8, event_name, "message_delta") or
        std.mem.eql(u8, event_name, "message_stop") or
        std.mem.eql(u8, event_name, "content_block_start") or
        std.mem.eql(u8, event_name, "content_block_delta") or
        std.mem.eql(u8, event_name, "content_block_stop");
}

fn processAnthropicSseEvent(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    sse_event: []const u8,
    data: []const u8,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    saw_message_start: *bool,
    saw_message_stop: *bool,
) !bool {
    if (data.len == 0) return false;
    if (std.mem.eql(u8, std.mem.trim(u8, data, " \t\r\n"), "[DONE]")) return true;
    const tolerate_noncanonical = shouldTolerateNoncanonicalAnthropicChunk(model);
    if (sse_event.len > 0 and
        !std.mem.eql(u8, sse_event, "error") and
        !isAnthropicMessageSseEvent(sse_event))
    {
        return false;
    }

    var parsed = parseAnthropicSseJson(allocator, data, tolerate_noncanonical) catch |err| {
        if (std.mem.eql(u8, sse_event, "error")) {
            try emitAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, data);
            return true;
        }
        return err;
    };
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .object) return AnthropicError.InvalidAnthropicChunk;

    if (std.mem.eql(u8, sse_event, "error")) {
        const error_message = try formatAnthropicStreamError(allocator, value, data);
        try emitOwnedAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, error_message);
        return true;
    }

    const event_type = value.object.get("type") orelse {
        if (value.object.get("error") != null) {
            const error_message = try formatAnthropicStreamError(allocator, value, data);
            try emitOwnedAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, error_message);
            return true;
        }
        if (tolerate_noncanonical) return false;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (event_type != .string) {
        if (tolerate_noncanonical) return false;
        return AnthropicError.InvalidAnthropicChunk;
    }

    if (std.mem.eql(u8, event_type.string, "message_start")) {
        saw_message_start.* = true;
        if (value.object.get("message")) |message_value| {
            if (message_value == .object) {
                if (message_value.object.get("id")) |id_value| {
                    if (id_value == .string and output.response_id == null) {
                        output.response_id = try allocator.dupe(u8, id_value.string);
                    }
                }
                if (message_value.object.get("usage")) |usage_value| {
                    updateUsage(&output.usage, usage_value);
                    finalize.calculateCost(model, &output.usage);
                }
            }
        }
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "content_block_start")) {
        try handleContentBlockStart(allocator, active_blocks, stream_ptr, value, context, options, tolerate_noncanonical);
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "content_block_delta")) {
        try handleContentBlockDelta(allocator, active_blocks, stream_ptr, value, tolerate_noncanonical);
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "content_block_stop")) {
        try handleContentBlockStop(allocator, active_blocks, content_blocks, tool_calls, stream_ptr, value, tolerate_noncanonical);
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "message_delta")) {
        if (value.object.get("delta")) |delta_value| {
            if (delta_value == .object) {
                if (delta_value.object.get("stop_reason")) |stop_reason| {
                    if (stop_reason == .string) try anthropic_message_stop.applyProviderStopReason(allocator, output, stop_reason.string);
                }
            }
        }
        if (value.object.get("usage")) |usage_value| {
            updateUsage(&output.usage, usage_value);
        }
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "message_stop")) {
        saw_message_stop.* = true;
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "ping")) {
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "error")) {
        const error_message = try formatAnthropicStreamError(allocator, value, data);
        try emitOwnedAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, error_message);
        return true;
    }

    return false;
}

fn parseAnthropicSseJson(
    allocator: std.mem.Allocator,
    data: []const u8,
    tolerate_noncanonical: bool,
) !std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (tolerate_noncanonical) {
        return json_parse.parseJsonWithRepair(allocator, trimmed);
    }
    return std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{ .allocate = .alloc_always });
}

fn emitAnthropicStreamError(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    data: []const u8,
) !void {
    const detail = try provider_error.sanitizeProviderErrorDetail(allocator, data);
    defer allocator.free(detail);
    const error_message = try std.fmt.allocPrint(allocator, "Provider stream error: {s}", .{detail});
    try emitOwnedAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, error_message);
}

fn emitOwnedAnthropicStreamError(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    error_message: []const u8,
) !void {
    try finalizeOutputFromPartials(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model);
    output.stop_reason = .error_reason;
    output.error_message = error_message;
    stream_ptr.push(.{
        .event_type = .error_event,
        .error_message = error_message,
        .message = output.*,
    });
    stream_ptr.end(output.*);
}

fn formatAnthropicStreamError(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    raw: []const u8,
) ![]u8 {
    if (value == .object) {
        if (value.object.get("error")) |error_value| {
            if (error_value == .object) {
                const error_type = if (error_value.object.get("type")) |type_value|
                    if (type_value == .string) type_value.string else "error"
                else
                    "error";
                const message = if (error_value.object.get("message")) |message_value|
                    if (message_value == .string) message_value.string else raw
                else
                    raw;
                const detail = try provider_error.sanitizeProviderErrorDetail(allocator, message);
                defer allocator.free(detail);
                return std.fmt.allocPrint(allocator, "{s}: {s}", .{ error_type, detail });
            }
        }
        if (value.object.get("message")) |message_value| {
            if (message_value == .string) return provider_error.sanitizeProviderErrorDetail(allocator, message_value.string);
        }
    }
    const detail = try provider_error.sanitizeProviderErrorDetail(allocator, raw);
    defer allocator.free(detail);
    return std.fmt.allocPrint(allocator, "Provider stream error: {s}", .{detail});
}

fn handleContentBlockStart(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
    context: types.Context,
    options: ?types.StreamOptions,
    tolerate_noncanonical: bool,
) !void {
    const index_value = value.object.get("index") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (index_value != .integer) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const anthropic_index: usize = @intCast(index_value.integer);
    const content_block = value.object.get("content_block") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (content_block != .object) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const block_type = content_block.object.get("type") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (block_type != .string) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }

    const event_index = anthropic_index;
    if (std.mem.eql(u8, block_type.string, "text")) {
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .text = std.ArrayList(u8).empty },
        });
        stream_ptr.push(.{ .event_type = .text_start, .content_index = @intCast(event_index) });
        return;
    }

    if (std.mem.eql(u8, block_type.string, "thinking")) {
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .thinking = .{
                .text = std.ArrayList(u8).empty,
                .signature = null,
                .redacted = false,
            } },
        });
        stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(event_index) });
        return;
    }

    if (std.mem.eql(u8, block_type.string, "redacted_thinking")) {
        const signature = if (content_block.object.get("data")) |data_value|
            if (data_value == .string) try allocator.dupe(u8, data_value.string) else null
        else
            null;
        var text = std.ArrayList(u8).empty;
        try text.appendSlice(allocator, "[Reasoning redacted]");
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .thinking = .{
                .text = text,
                .signature = signature,
                .redacted = true,
            } },
        });
        stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(event_index) });
        return;
    }

    if (std.mem.eql(u8, block_type.string, "tool_use")) {
        const id_value = content_block.object.get("id") orelse return AnthropicError.InvalidAnthropicChunk;
        const name_value = content_block.object.get("name") orelse return AnthropicError.InvalidAnthropicChunk;
        if (id_value != .string or name_value != .string) return AnthropicError.InvalidAnthropicChunk;
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .tool_call = .{
                .id = try allocator.dupe(u8, id_value.string),
                .name = try normalizeIncomingToolName(allocator, name_value.string, context.tools, options),
                .partial_json = std.ArrayList(u8).empty,
            } },
        });
        stream_ptr.push(.{ .event_type = .toolcall_start, .content_index = @intCast(event_index) });
        return;
    }
}

fn handleContentBlockDelta(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
    tolerate_noncanonical: bool,
) !void {
    const index_value = value.object.get("index") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (index_value != .integer) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const anthropic_index: usize = @intCast(index_value.integer);
    const delta_value = value.object.get("delta") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (delta_value != .object) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const delta_type = delta_value.object.get("type") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (delta_type != .string) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    var entry: *BlockEntry = undefined;
    if (findActiveBlockIndex(active_blocks, anthropic_index)) |found_index| {
        entry = &active_blocks.items[found_index];
    } else {
        if (tolerate_noncanonical) {
            if (!isSupportedAnthropicDeltaType(delta_type.string)) return;
            if (std.mem.eql(u8, delta_type.string, "input_json_delta")) return;
            entry = try createImplicitActiveBlock(allocator, active_blocks, stream_ptr, anthropic_index, delta_type.string);
        } else {
            return AnthropicError.InvalidAnthropicChunk;
        }
    }

    if (std.mem.eql(u8, delta_type.string, "text_delta")) {
        const text_value = delta_value.object.get("text") orelse {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        };
        if (text_value != .string) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block != .text) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        try entry.block.text.appendSlice(allocator, text_value.string);
        stream_ptr.push(.{
            .event_type = .text_delta,
            .content_index = @intCast(entry.event_index),
            .delta = try allocator.dupe(u8, text_value.string),
            .owns_delta = true,
        });
        return;
    }

    if (std.mem.eql(u8, delta_type.string, "thinking_delta")) {
        const thinking_value = delta_value.object.get("thinking") orelse {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        };
        if (thinking_value != .string) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block != .thinking) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        try entry.block.thinking.text.appendSlice(allocator, thinking_value.string);
        stream_ptr.push(.{
            .event_type = .thinking_delta,
            .content_index = @intCast(entry.event_index),
            .delta = try allocator.dupe(u8, thinking_value.string),
            .owns_delta = true,
        });
        return;
    }

    if (std.mem.eql(u8, delta_type.string, "signature_delta")) {
        const signature_value = delta_value.object.get("signature") orelse {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        };
        if (signature_value != .string) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block != .thinking) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block.thinking.signature) |existing| {
            const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, signature_value.string });
            allocator.free(existing);
            entry.block.thinking.signature = combined;
        } else {
            entry.block.thinking.signature = try allocator.dupe(u8, signature_value.string);
        }
        return;
    }

    if (std.mem.eql(u8, delta_type.string, "input_json_delta")) {
        const partial_json = delta_value.object.get("partial_json") orelse {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        };
        if (partial_json != .string) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block != .tool_call) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        try entry.block.tool_call.partial_json.appendSlice(allocator, partial_json.string);
        stream_ptr.push(.{
            .event_type = .toolcall_delta,
            .content_index = @intCast(entry.event_index),
            .delta = try allocator.dupe(u8, partial_json.string),
            .owns_delta = true,
        });
        return;
    }
}

fn isSupportedAnthropicDeltaType(delta_type: []const u8) bool {
    return std.mem.eql(u8, delta_type, "text_delta") or
        std.mem.eql(u8, delta_type, "thinking_delta") or
        std.mem.eql(u8, delta_type, "signature_delta") or
        std.mem.eql(u8, delta_type, "input_json_delta");
}

fn createImplicitActiveBlock(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    anthropic_index: usize,
    delta_type: []const u8,
) !*BlockEntry {
    const event_index = anthropic_index;
    if (std.mem.eql(u8, delta_type, "text_delta")) {
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .text = std.ArrayList(u8).empty },
        });
        stream_ptr.push(.{ .event_type = .text_start, .content_index = @intCast(event_index) });
        return &active_blocks.items[active_blocks.items.len - 1];
    }
    if (std.mem.eql(u8, delta_type, "thinking_delta") or std.mem.eql(u8, delta_type, "signature_delta")) {
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .thinking = .{
                .text = std.ArrayList(u8).empty,
                .signature = null,
                .redacted = false,
            } },
        });
        stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(event_index) });
        return &active_blocks.items[active_blocks.items.len - 1];
    }
    return AnthropicError.InvalidAnthropicChunk;
}

fn handleContentBlockStop(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
    tolerate_noncanonical: bool,
) !void {
    const index_value = value.object.get("index") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (index_value != .integer) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const anthropic_index: usize = @intCast(index_value.integer);

    const remove_index = findActiveBlockIndex(active_blocks, anthropic_index) orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    var entry = active_blocks.orderedRemove(remove_index);
    defer deinitCurrentBlock(allocator, &entry.block);

    switch (entry.block) {
        .text => |text| {
            const owned = try allocator.dupe(u8, text.items);
            try content_blocks.append(allocator, .{ .text = .{ .text = owned } });
            stream_ptr.push(.{
                .event_type = .text_end,
                .content_index = @intCast(entry.event_index),
                .content = owned,
            });
        },
        .thinking => |thinking| {
            const text = try allocator.dupe(u8, thinking.text.items);
            const signature = if (thinking.signature) |sig| try allocator.dupe(u8, sig) else null;
            try content_blocks.append(allocator, .{ .thinking = .{
                .thinking = text,
                .signature = signature,
                .redacted = thinking.redacted,
            } });
            stream_ptr.push(.{
                .event_type = .thinking_end,
                .content_index = @intCast(entry.event_index),
                .content = text,
            });
        },
        .tool_call => |tool| {
            var parsed_arguments = try json_parse.parseStreamingJson(allocator, tool.partial_json.items);
            defer parsed_arguments.deinit();
            const arguments = try provider_json.cloneValue(allocator, parsed_arguments.value);
            const final_tool_call = blk: {
                errdefer provider_json.freeValue(allocator, arguments);
                const id = try allocator.dupe(u8, tool.id);
                errdefer allocator.free(id);
                const name = try allocator.dupe(u8, tool.name);
                errdefer allocator.free(name);
                break :blk types.ToolCall{
                    .id = id,
                    .name = name,
                    .arguments = arguments,
                };
            };
            try finalize.appendInlineToolCall(allocator, content_blocks, tool_calls, final_tool_call);
            stream_ptr.push(.{
                .event_type = .toolcall_end,
                .content_index = @intCast(entry.event_index),
                .tool_call = final_tool_call,
            });
        },
    }
}

fn updateUsage(usage: *types.Usage, usage_value: std.json.Value) void {
    if (usage_value != .object) return;
    if (usage_value.object.get("input_tokens")) |value| {
        if (value == .integer) usage.input = @intCast(value.integer);
    }
    if (usage_value.object.get("output_tokens")) |value| {
        if (value == .integer) usage.output = @intCast(value.integer);
    }
    if (usage_value.object.get("cache_read_input_tokens")) |value| {
        if (value == .integer) usage.cache_read = @intCast(value.integer);
    }
    if (usage_value.object.get("cache_creation_input_tokens")) |value| {
        if (value == .integer) usage.cache_write = @intCast(value.integer);
    }
    usage.total_tokens = usage.input + usage.output + usage.cache_read + usage.cache_write;
}

fn findActiveBlockIndex(active_blocks: *const std.ArrayList(BlockEntry), anthropic_index: usize) ?usize {
    for (active_blocks.items, 0..) |entry, index| {
        if (entry.anthropic_index == anthropic_index) return index;
    }
    return null;
}

fn deinitCurrentBlock(allocator: std.mem.Allocator, block: *CurrentBlock) void {
    switch (block.*) {
        .text => |*text| text.deinit(allocator),
        .thinking => |*thinking| {
            textDeinit(allocator, &thinking.text);
            if (thinking.signature) |signature| allocator.free(signature);
        },
        .tool_call => |*tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            tool_call.partial_json.deinit(allocator);
        },
    }
}

fn textDeinit(allocator: std.mem.Allocator, text: *std.ArrayList(u8)) void {
    text.deinit(allocator);
}

fn normalizeIncomingToolName(
    allocator: std.mem.Allocator,
    name: []const u8,
    tools: ?[]const types.Tool,
    options: ?types.StreamOptions,
) ![]const u8 {
    _ = options;
    if (tools) |available_tools| {
        for (available_tools) |tool| {
            if (std.ascii.eqlIgnoreCase(tool.name, name)) {
                return try allocator.dupe(u8, tool.name);
            }
        }
    }
    return try allocator.dupe(u8, name);
}
