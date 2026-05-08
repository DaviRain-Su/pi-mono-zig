//! Legacy OpenAI Chat Completions SSE parser.
//!
//! This module keeps a custom Chat Completions parser while sharing the generic
//! `ai/shared/sse_loop.zig` outer iterator: it owns Chat Completions-specific
//! delta accumulation, mixed text/thinking/tool-call ordering, and the legacy
//! `AssistantMessage.tool_calls` compatibility copy. Inline `.tool_call`
//! content remains canonical, while `tool_calls` is separately allocated for
//! consumers that still read the legacy field; see `types.freeAssistantMessage`
//! for the freeing contract. Compact `data:{...}` SSE lines are accepted here
//! through the provider-local data-line parser as a Chat Completions tolerance
//! without broadening generic SSE-loop provider behavior.

const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const provider_error = @import("../shared/provider_error.zig");
const provider_json = @import("../shared/provider_json.zig");
const sse_loop = @import("../shared/sse_loop.zig");

const ActiveTextBlock = struct {
    content_index: usize,
    text: std.ArrayList(u8),
};

const ActiveThinkingBlock = struct {
    content_index: usize,
    text: std.ArrayList(u8),
    thinking_signature: ?[]const u8,
};

const ActiveToolCallBlock = struct {
    event_index: usize,
    stream_index: ?usize,
    id: std.ArrayList(u8),
    observed_ids: std.ArrayList([]const u8),
    name: std.ArrayList(u8),
    partial_args: std.ArrayList(u8),
    thought_signature: ?[]const u8 = null,
};

const StreamingBlockKind = enum {
    text,
    thinking,
    tool_call,
};

const StreamingBlockOrderEntry = struct {
    kind: StreamingBlockKind,
    tool_call_index: ?usize = null,
    text_content: ?[]const u8 = null,
};

fn deinitActiveTextBlock(block: *ActiveTextBlock, allocator: std.mem.Allocator) void {
    block.text.deinit(allocator);
}

fn deinitActiveThinkingBlock(block: *ActiveThinkingBlock, allocator: std.mem.Allocator) void {
    block.text.deinit(allocator);
    if (block.thinking_signature) |sig| allocator.free(sig);
}

fn deinitActiveToolCallBlock(allocator: std.mem.Allocator, block: *ActiveToolCallBlock) void {
    block.id.deinit(allocator);
    for (block.observed_ids.items) |id| allocator.free(id);
    block.observed_ids.deinit(allocator);
    block.name.deinit(allocator);
    block.partial_args.deinit(allocator);
    if (block.thought_signature) |sig| allocator.free(sig);
}

const SseParseState = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
    output: types.AssistantMessage,
    text_block: ?ActiveTextBlock = null,
    thinking_block: ?ActiveThinkingBlock = null,
    active_tool_calls: std.ArrayList(ActiveToolCallBlock) = .empty,
    block_order: std.ArrayList(StreamingBlockOrderEntry) = .empty,
    content_blocks: std.ArrayList(types.ContentBlock) = .empty,
    tool_calls: std.ArrayList(types.ToolCall) = .empty,
    tool_calls_transferred: bool = false,
};

fn initSseParseState(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
) SseParseState {
    return .{
        .allocator = allocator,
        .stream_ptr = stream_ptr,
        .model = model,
        .output = .{
            .role = "assistant",
            .content = &[_]types.ContentBlock{},
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = types.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 0,
        },
    };
}

fn deinitSseParseState(state: *SseParseState) void {
    const allocator = state.allocator;
    if (state.text_block) |*block| deinitActiveTextBlock(block, allocator);
    if (state.thinking_block) |*block| deinitActiveThinkingBlock(block, allocator);
    for (state.active_tool_calls.items) |*tool_call| deinitActiveToolCallBlock(allocator, tool_call);
    state.active_tool_calls.deinit(allocator);
    if (state.output.content.len == 0) {
        for (state.block_order.items) |entry| {
            if (entry.text_content) |content| allocator.free(content);
        }
    }
    state.block_order.deinit(allocator);
    state.content_blocks.deinit(allocator);
    if (!state.tool_calls_transferred) {
        for (state.tool_calls.items) |tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            freeJsonValue(allocator, tool_call.arguments);
            if (tool_call.thought_signature) |sig| allocator.free(sig);
        }
        state.tool_calls.deinit(allocator);
    }
}

const OpenAIChatSseLoopHandler = struct {
    allocator: std.mem.Allocator,
    state: *SseParseState,

    pub fn extractDataLine(_: *OpenAIChatSseLoopHandler, line: []const u8) ?[]const u8 {
        return parseSseLine(line);
    }

    pub fn isDoneData(_: *OpenAIChatSseLoopHandler, data: []const u8) bool {
        return std.mem.eql(u8, data, "[DONE]");
    }

    pub fn handleData(self: *OpenAIChatSseLoopHandler, data: []const u8) !bool {
        const chunk = parseChunk(self.allocator, data) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailureState(self.state, err);
                return false;
            },
        };
        defer if (chunk) |*c| c.deinit();
        if (chunk) |parsed| try processParsedChunk(self.state, parsed.value);
        return true;
    }

    pub fn handleRuntimeFailure(self: *OpenAIChatSseLoopHandler, err: anyerror) !void {
        try emitRuntimeFailureState(self.state, err);
    }
};

pub fn parseSseStreamLines(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    streaming: *http_client.StreamingResponse,
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    var state = initSseParseState(allocator, stream_ptr, model);
    defer deinitSseParseState(&state);

    stream_ptr.push(.{ .event_type = .start });

    var handler = OpenAIChatSseLoopHandler{
        .allocator = allocator,
        .state = &state,
    };
    const loop_result = try sse_loop.run(OpenAIChatSseLoopHandler, &handler, streaming, options);
    if (loop_result == .stopped) return;

    try finishParserState(&state);
}

fn emitRuntimeFailureState(state: *SseParseState, err: anyerror) !void {
    try emitRuntimeFailure(
        state.allocator,
        state.stream_ptr,
        &state.output,
        &state.text_block,
        &state.thinking_block,
        &state.active_tool_calls,
        &state.block_order,
        &state.content_blocks,
        &state.tool_calls,
        &state.tool_calls_transferred,
        err,
    );
}

fn finishParserState(state: *SseParseState) !void {
    const allocator = state.allocator;
    try finishStreamingBlocks(
        allocator,
        &state.text_block,
        &state.thinking_block,
        &state.active_tool_calls,
        &state.block_order,
        &state.content_blocks,
        &state.tool_calls,
        state.stream_ptr,
    );

    if (state.content_blocks.items.len > 0) {
        const blocks = try allocator.alloc(types.ContentBlock, state.content_blocks.items.len);
        for (state.content_blocks.items, 0..) |block, i| blocks[i] = block;
        state.output.content = blocks;
    }

    if (state.tool_calls.items.len > 0) {
        // openai_chat_sse uses dual allocation: tool calls have separate copies
        // in `tool_calls` and inline `content`. The legacy field still owns
        // the ArrayList copies so they are freed via freeAssistantMessage.
        // Inline content is the canonical source consumers read from.
        state.output.tool_calls = try state.tool_calls.toOwnedSlice(allocator);
        state.tool_calls_transferred = true;
        if (state.output.stop_reason == .stop) state.output.stop_reason = .tool_use;
    }

    state.stream_ptr.push(.{ .event_type = .done, .message = state.output });
    state.stream_ptr.end(state.output);
}

fn processParsedChunk(state: *SseParseState, value: std.json.Value) !void {
    var chunk_has_top_level_usage = false;
    if (value.object.get("usage")) |usage_val| {
        if (usage_val == .object) {
            state.output.usage = parseChunkUsage(state.allocator, usage_val, state.model);
            chunk_has_top_level_usage = true;
        }
    }

    if (value.object.get("id")) |id_val| {
        if (id_val == .string and state.output.response_id == null) {
            state.output.response_id = try state.allocator.dupe(u8, id_val.string);
        }
    }

    if (value.object.get("model")) |model_val| {
        if (model_val == .string and model_val.string.len > 0 and state.output.response_model == null) {
            if (!std.mem.eql(u8, model_val.string, state.model.id)) {
                state.output.response_model = try state.allocator.dupe(u8, model_val.string);
            }
        }
    }

    const choices = value.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;

    const choice = choices.array.items[0];
    if (choice != .object) return;

    try processChoiceUsageAndFinish(state, choice, chunk_has_top_level_usage);

    const delta = choice.object.get("delta") orelse return;
    if (delta != .object) return;
    try processDelta(state, delta);
}

fn processChoiceUsageAndFinish(
    state: *SseParseState,
    choice: std.json.Value,
    chunk_has_top_level_usage: bool,
) !void {
    if (!chunk_has_top_level_usage) {
        if (choice.object.get("usage")) |choice_usage| {
            if (choice_usage == .object) {
                state.output.usage = parseChunkUsage(state.allocator, choice_usage, state.model);
            }
        }
    }

    if (choice.object.get("finish_reason")) |finish_reason| {
        if (finish_reason == .string) {
            const result = try mapStopReason(state.allocator, finish_reason.string);
            state.output.stop_reason = result.stop_reason;
            if (result.error_message) |em| {
                if (state.output.error_message) |previous| state.allocator.free(previous);
                state.output.error_message = em;
            }
        }
    }
}

fn processDelta(state: *SseParseState, delta: std.json.Value) !void {
    try processTextDelta(state, delta);
    try processReasoningDelta(state, delta);
    try processToolCallDelta(state, delta);
    try processReasoningDetailsDelta(state, delta);
}

fn processTextDelta(state: *SseParseState, delta: std.json.Value) !void {
    const content = delta.object.get("content") orelse return;
    if (content != .string or content.string.len == 0) return;

    if (state.text_block == null) {
        const content_index = state.block_order.items.len;
        state.text_block = .{ .content_index = content_index, .text = std.ArrayList(u8).empty };
        try state.block_order.append(state.allocator, .{ .kind = .text });
        state.stream_ptr.push(.{ .event_type = .text_start, .content_index = @intCast(content_index) });
    }

    if (state.text_block) |*block| {
        try block.text.appendSlice(state.allocator, content.string);
        state.stream_ptr.push(.{
            .event_type = .text_delta,
            .content_index = @intCast(block.content_index),
            .delta = try state.allocator.dupe(u8, content.string),
            .owns_delta = true,
        });
    }
}

fn processReasoningDelta(state: *SseParseState, delta: std.json.Value) !void {
    const reasoning_fields = [_][]const u8{ "reasoning_content", "reasoning", "reasoning_text" };
    var found_reasoning: ?[]const u8 = null;
    var found_reasoning_field: ?[]const u8 = null;
    for (reasoning_fields) |field| {
        if (delta.object.get(field)) |rv| {
            if (rv == .string and rv.string.len > 0) {
                found_reasoning = rv.string;
                found_reasoning_field = field;
                break;
            }
        }
    }

    const reasoning_text = found_reasoning orelse return;
    if (state.thinking_block == null) {
        const content_index = state.block_order.items.len;
        state.thinking_block = .{
            .content_index = content_index,
            .text = std.ArrayList(u8).empty,
            .thinking_signature = try state.allocator.dupe(u8, found_reasoning_field orelse "reasoning"),
        };
        try state.block_order.append(state.allocator, .{ .kind = .thinking });
        state.stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(content_index) });
    }

    if (state.thinking_block) |*block| {
        try block.text.appendSlice(state.allocator, reasoning_text);
        state.stream_ptr.push(.{
            .event_type = .thinking_delta,
            .content_index = @intCast(block.content_index),
            .delta = try state.allocator.dupe(u8, reasoning_text),
            .owns_delta = true,
        });
    }
}

fn processToolCallDelta(state: *SseParseState, delta: std.json.Value) !void {
    const tool_calls_val = delta.object.get("tool_calls") orelse return;
    if (tool_calls_val != .array) return;

    for (tool_calls_val.array.items) |tool_call_item| {
        if (tool_call_item != .object) continue;
        try processToolCallItem(state, tool_call_item);
    }
}

fn processToolCallItem(state: *SseParseState, tool_call_item: std.json.Value) !void {
    // Chat Completions has no explicit content-block lifecycle events, but in
    // plain text/tool/text streams a tool-call delta is the clearest available
    // boundary between adjacent text spans. Close the current text block before
    // opening or updating a tool so later text deltas reopen at a new stable
    // content_index instead of being coalesced into the pre-tool text block.
    //
    // Keep mixed reasoning streams on the legacy accumulator path: without
    // protocol block-end events, closing text while a reasoning accumulator is
    // also open changes established OpenAI-compatible parity ordering.
    if (state.thinking_block == null) {
        try finishActiveTextBlock(state.allocator, &state.text_block, &state.block_order, state.stream_ptr);
    }

    const tc_id = if (tool_call_item.object.get("id")) |id_v|
        if (id_v == .string) id_v.string else null
    else
        null;
    const tc_name = extractToolCallName(tool_call_item);
    const tc_args = extractToolCallArguments(tool_call_item);
    const active_tool_call = try ensureActiveToolCall(
        state.allocator,
        &state.active_tool_calls,
        &state.block_order,
        state.stream_ptr,
        extractToolCallIndex(tool_call_item),
        tc_id,
    );

    if (tc_id) |id| {
        if (id.len > 0 and active_tool_call.id.items.len == 0) try active_tool_call.id.appendSlice(state.allocator, id);
    }
    if (tc_name) |name| {
        if (name.len > 0 and active_tool_call.name.items.len == 0) try active_tool_call.name.appendSlice(state.allocator, name);
    }

    const delta_str = if (tc_args) |args| blk: {
        try active_tool_call.partial_args.appendSlice(state.allocator, args);
        break :blk try state.allocator.dupe(u8, args);
    } else null;
    state.stream_ptr.push(.{
        .event_type = .toolcall_delta,
        .content_index = @intCast(active_tool_call.event_index),
        .delta = delta_str,
        .owns_delta = delta_str != null,
    });
}

fn finishActiveTextBlock(
    allocator: std.mem.Allocator,
    text_block: *?ActiveTextBlock,
    block_order: *std.ArrayList(StreamingBlockOrderEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    if (text_block.*) |*block| {
        const content = try allocator.dupe(u8, block.text.items);
        errdefer allocator.free(content);
        if (block.content_index >= block_order.items.len) return error.InvalidContentIndex;
        block_order.items[block.content_index].text_content = content;
        stream_ptr.push(.{
            .event_type = .text_end,
            .content_index = @intCast(block.content_index),
            .content = content,
        });
        deinitActiveTextBlock(block, allocator);
        text_block.* = null;
    }
}

fn extractToolCallName(tool_call_item: std.json.Value) ?[]const u8 {
    if (tool_call_item.object.get("function")) |func_v| {
        if (func_v == .object) {
            if (func_v.object.get("name")) |name_v| {
                if (name_v == .string) return name_v.string;
            }
        }
    }
    return null;
}

fn extractToolCallArguments(tool_call_item: std.json.Value) ?[]const u8 {
    if (tool_call_item.object.get("function")) |func_v| {
        if (func_v == .object) {
            if (func_v.object.get("arguments")) |args_v| {
                if (args_v == .string) return args_v.string;
            }
        }
    }
    return null;
}

fn processReasoningDetailsDelta(state: *SseParseState, delta: std.json.Value) !void {
    const reasoning_details_val = delta.object.get("reasoning_details") orelse return;
    if (reasoning_details_val != .array) return;

    for (reasoning_details_val.array.items) |detail| {
        if (detail != .object) continue;
        try processReasoningDetail(state, detail);
    }
}

fn processReasoningDetail(state: *SseParseState, detail: std.json.Value) !void {
    const detail_type = if (detail.object.get("type")) |t| if (t == .string) t.string else null else null;
    if (detail_type == null or !std.mem.eql(u8, detail_type.?, "reasoning.encrypted")) return;

    const detail_id = if (detail.object.get("id")) |id_v|
        if (id_v == .string and id_v.string.len > 0) id_v.string else null
    else
        null;
    if (detail_id == null) return;

    const detail_data = if (detail.object.get("data")) |d_v|
        if (d_v == .string and d_v.string.len > 0) d_v.string else null
    else
        null;
    if (detail_data == null) return;

    for (state.active_tool_calls.items) |*tool_call| {
        if (std.mem.eql(u8, tool_call.id.items, detail_id.?)) {
            if (tool_call.thought_signature) |old| state.allocator.free(old);
            tool_call.thought_signature = try std.json.Stringify.valueAlloc(state.allocator, detail, .{});
            break;
        }
    }
}

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    text_block: *?ActiveTextBlock,
    thinking_block: *?ActiveThinkingBlock,
    active_tool_calls: *std.ArrayList(ActiveToolCallBlock),
    block_order: *std.ArrayList(StreamingBlockOrderEntry),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    tool_calls_transferred: *bool,
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    try finishStreamingBlocks(
        allocator,
        text_block,
        thinking_block,
        active_tool_calls,
        block_order,
        content_blocks,
        tool_calls,
        stream_ptr,
    );

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
    text_block: *?ActiveTextBlock,
    thinking_block: *?ActiveThinkingBlock,
    active_tool_calls: *std.ArrayList(ActiveToolCallBlock),
    block_order: *std.ArrayList(StreamingBlockOrderEntry),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    tool_calls_transferred: *bool,
    err: anyerror,
) !void {
    try finalizeOutputFromPartials(
        allocator,
        output,
        text_block,
        thinking_block,
        active_tool_calls,
        block_order,
        content_blocks,
        tool_calls,
        tool_calls_transferred,
        stream_ptr,
    );
    provider_error.emitTerminalRuntimeFailure(stream_ptr, output, err);
}

fn extractToolCallIndex(tool_call_value: std.json.Value) ?usize {
    if (tool_call_value != .object) return null;
    const index_value = tool_call_value.object.get("index") orelse return null;
    if (index_value != .integer or index_value.integer < 0) return null;
    return @intCast(index_value.integer);
}

fn activeToolCallHasObservedId(tool_call: *const ActiveToolCallBlock, id: []const u8) bool {
    if (id.len == 0) return false;
    if (std.mem.eql(u8, tool_call.id.items, id)) return true;
    for (tool_call.observed_ids.items) |observed_id| {
        if (std.mem.eql(u8, observed_id, id)) return true;
    }
    return false;
}

fn recordObservedToolCallId(
    allocator: std.mem.Allocator,
    tool_call: *ActiveToolCallBlock,
    id: []const u8,
) !void {
    if (id.len == 0) return;
    if (activeToolCallHasObservedId(tool_call, id)) return;
    const id_copy = try allocator.dupe(u8, id);
    errdefer allocator.free(id_copy);
    try tool_call.observed_ids.append(allocator, id_copy);
}

fn ensureActiveToolCall(
    allocator: std.mem.Allocator,
    active_tool_calls: *std.ArrayList(ActiveToolCallBlock),
    block_order: *std.ArrayList(StreamingBlockOrderEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    stream_index: ?usize,
    id: ?[]const u8,
) !*ActiveToolCallBlock {
    if (stream_index) |index| {
        for (active_tool_calls.items) |*tool_call| {
            if (tool_call.stream_index != null and tool_call.stream_index.? == index) {
                if (id) |tool_call_id| {
                    if (tool_call.id.items.len > 0) try recordObservedToolCallId(allocator, tool_call, tool_call_id);
                }
                return tool_call;
            }
        }
    }

    if (id) |tool_call_id| {
        if (tool_call_id.len > 0) {
            for (active_tool_calls.items) |*tool_call| {
                if (activeToolCallHasObservedId(tool_call, tool_call_id)) {
                    if (stream_index != null and tool_call.stream_index == null) {
                        tool_call.stream_index = stream_index;
                    }
                    return tool_call;
                }
            }
        }
    }

    const event_index = block_order.items.len;
    const tool_call_index = active_tool_calls.items.len;
    try active_tool_calls.append(allocator, .{
        .event_index = event_index,
        .stream_index = stream_index,
        .id = std.ArrayList(u8).empty,
        .observed_ids = std.ArrayList([]const u8).empty,
        .name = std.ArrayList(u8).empty,
        .partial_args = std.ArrayList(u8).empty,
    });
    try block_order.append(allocator, .{
        .kind = .tool_call,
        .tool_call_index = tool_call_index,
    });
    stream_ptr.push(.{
        .event_type = .toolcall_start,
        .content_index = @intCast(event_index),
    });
    return &active_tool_calls.items[active_tool_calls.items.len - 1];
}

fn finishStreamingBlocks(
    allocator: std.mem.Allocator,
    text_block: *?ActiveTextBlock,
    thinking_block: *?ActiveThinkingBlock,
    active_tool_calls: *std.ArrayList(ActiveToolCallBlock),
    block_order: *std.ArrayList(StreamingBlockOrderEntry),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    for (block_order.items, 0..) |entry, content_index| {
        switch (entry.kind) {
            .text => {
                if (entry.text_content) |content| {
                    try content_blocks.append(allocator, types.ContentBlock{ .text = .{ .text = content } });
                    continue;
                }
                const block = text_block.* orelse continue;
                if (block.content_index != content_index) continue;
                const content = try allocator.dupe(u8, block.text.items);
                try content_blocks.append(allocator, types.ContentBlock{ .text = .{ .text = content } });
                stream_ptr.push(.{
                    .event_type = .text_end,
                    .content_index = @intCast(content_index),
                    .content = content,
                });
            },
            .thinking => {
                const block = thinking_block.* orelse continue;
                const content = try allocator.dupe(u8, block.text.items);
                try content_blocks.append(allocator, types.ContentBlock{
                    .thinking = .{
                        .thinking = content,
                        .thinking_signature = if (block.thinking_signature) |sig| try allocator.dupe(u8, sig) else null,
                        .redacted = false,
                    },
                });
                stream_ptr.push(.{
                    .event_type = .thinking_end,
                    .content_index = @intCast(content_index),
                    .content = content,
                });
            },
            .tool_call => {
                const tool_call_index = entry.tool_call_index orelse continue;
                if (tool_call_index >= active_tool_calls.items.len) continue;
                const tool_call = &active_tool_calls.items[tool_call_index];
                const id = try allocator.dupe(u8, std.mem.trim(u8, tool_call.id.items, " "));
                errdefer allocator.free(id);
                const name = try allocator.dupe(u8, std.mem.trim(u8, tool_call.name.items, " "));
                errdefer allocator.free(name);
                const args_str = std.mem.trim(u8, tool_call.partial_args.items, " ");
                const args = try parseStreamingJsonToValue(allocator, args_str);
                errdefer freeJsonValue(allocator, args);
                // Transfer thought_signature ownership from the active block to
                // the final tool call; null out the active block field so
                // deinitActiveToolCallBlock does not double-free.
                const thought_sig = tool_call.thought_signature;
                tool_call.thought_signature = null;
                const final_tool_call = types.ToolCall{
                    .id = id,
                    .name = name,
                    .arguments = args,
                    .thought_signature = thought_sig,
                };
                try tool_calls.append(allocator, final_tool_call);
                try content_blocks.append(allocator, types.ContentBlock{ .tool_call = .{
                    .id = try allocator.dupe(u8, final_tool_call.id),
                    .name = try allocator.dupe(u8, final_tool_call.name),
                    .arguments = try cloneJsonValue(allocator, final_tool_call.arguments),
                    .thought_signature = if (thought_sig) |sig| try allocator.dupe(u8, sig) else null,
                } });
                stream_ptr.push(.{
                    .event_type = .toolcall_end,
                    .content_index = @intCast(tool_call.event_index),
                    .tool_call = final_tool_call,
                });
            },
        }
    }

    if (text_block.*) |*block| {
        deinitActiveTextBlock(block, allocator);
        text_block.* = null;
    }
    if (thinking_block.*) |*block| {
        deinitActiveThinkingBlock(block, allocator);
        thinking_block.* = null;
    }
    for (active_tool_calls.items) |*tool_call| {
        deinitActiveToolCallBlock(allocator, tool_call);
    }
    active_tool_calls.clearRetainingCapacity();
    block_order.clearRetainingCapacity();
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
    return provider_json.cloneValue(allocator, value);
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    provider_json.freeValue(allocator, value);
}

pub fn parseChunkUsage(
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

    // Resolve cached token source matching TypeScript precedence:
    // prompt_tokens_details.cached_tokens ?? prompt_cache_hit_tokens ?? 0
    // A boolean flag is needed because cached_tokens=0 is a valid explicit value
    // that must not trigger the fallback (matching TS nullish coalescing semantics).
    var reported_cached_tokens: u32 = 0;
    var found_cached_tokens = false;
    var cache_write_tokens: u32 = 0;

    if (usage_val.object.get("prompt_tokens_details")) |details| {
        if (details == .object) {
            if (details.object.get("cached_tokens")) |ct| {
                if (ct == .integer) {
                    reported_cached_tokens = @as(u32, @intCast(ct.integer));
                    found_cached_tokens = true;
                }
            }
            if (details.object.get("cache_write_tokens")) |cwt| {
                if (cwt == .integer) cache_write_tokens = @as(u32, @intCast(cwt.integer));
            }
        }
    }

    // Fallback: prompt_cache_hit_tokens when prompt_tokens_details.cached_tokens
    // is absent. This matches TypeScript:
    // rawUsage.prompt_tokens_details?.cached_tokens ?? rawUsage.prompt_cache_hit_tokens ?? 0
    if (!found_cached_tokens) {
        if (usage_val.object.get("prompt_cache_hit_tokens")) |pcht| {
            if (pcht == .integer) reported_cached_tokens = @as(u32, @intCast(pcht.integer));
        }
    }

    if (usage_val.object.get("completion_tokens_details")) |details| {
        if (details == .object) {
            _ = details.object.get("reasoning_tokens");
        }
    }

    // Normalize cache read: subtract cache writes if present
    // Some OpenAI-compatible providers (observed on OpenRouter) report cached_tokens
    // as (previous hits + current writes). In that case, remove cacheWrite from cacheRead.
    // Clamp at zero: u32 subtraction would underflow, so guard with a comparison.
    const normalized_cache_read = if (reported_cached_tokens >= cache_write_tokens)
        reported_cached_tokens - cache_write_tokens
    else
        @as(u32, 0);

    // Saturating subtraction: when cache tokens exceed prompt_tokens, clamp input to zero.
    // Using a comparison guard because u32 subtraction would wrap on underflow,
    // and @max(0, wrapped_u32) cannot recover from the wrap.
    const cache_total = normalized_cache_read + cache_write_tokens;
    const input = if (cache_total >= prompt_tokens) @as(u32, 0) else prompt_tokens - cache_total;
    const output = completion_tokens;

    usage.input = input;
    usage.output = output;
    usage.cache_read = normalized_cache_read;
    usage.cache_write = cache_write_tokens;
    usage.total_tokens = input + output + normalized_cache_read + cache_write_tokens;

    return usage;
}

pub fn mapStopReason(
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

/// Parse an OpenAI Chat SSE byte slice and return the final AssistantMessage.
/// This is a test/parity helper that wraps the existing SSE stream parser.
/// The caller owns the returned message; free with the same allocator used for parsing.
pub fn parseSseAssistantMessageFromSlice(
    allocator: std.mem.Allocator,
    io: std.Io,
    sse_data: []const u8,
    model: types.Model,
) !types.AssistantMessage {
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    // The StreamingResponse takes ownership of `body`; duplicate so caller keeps theirs.
    const body_copy = try allocator.dupe(u8, sse_data);
    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body_copy,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);
    return stream.result() orelse return error.MissingAssistantMessage;
}

/// Parse SSE line and extract JSON data
pub fn parseSseLine(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "data: ")) return line[6..];
    if (std.mem.startsWith(u8, line, "data:")) return std.mem.trim(u8, line[5..], " ");
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

fn testModel(base_url: []const u8) types.Model {
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

test "openai_chat_sse parses data lines and chunks" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqualStrings("{\"foo\": 123}", parseSseLine("data: {\"foo\": 123}").?);
    try std.testing.expectEqualStrings("{\"foo\": 123}", parseSseLine("data:{\"foo\": 123}").?);
    try std.testing.expect(parseSseLine("event: start") == null);

    try std.testing.expect((try parseChunk(allocator, "[DONE]")) == null);
    try std.testing.expect((try parseChunk(allocator, "")) == null);

    const valid = try parseChunk(allocator, "{\"foo\": 123}");
    defer if (valid) |*v| v.deinit();
    try std.testing.expect(valid != null);
    try std.testing.expect(valid.?.value == .object);
}

test "openai_chat_sse accepts compact data lines in chat completions stream" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    const body =
        "event: message\n" ++
        "\n" ++
        "data:{\"id\":\"chatcmpl_compact\",\"model\":\"gpt-4\",\"choices\":[{\"delta\":{\"content\":\"compact\"}}]}\n" ++
        "data:{\"choices\":[{\"finish_reason\":\"stop\",\"delta\":{}}]}\n" ++
        "data:[DONE]\n";

    const body_copy = try allocator.dupe(u8, body);
    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body_copy,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, testModel("https://api.openai.com/v1"), null);
    while (stream.next()) |event| event.deinitTransient(allocator);

    const message = stream.result() orelse return error.MissingAssistantMessage;
    defer types.freeAssistantMessage(allocator, message);

    try std.testing.expectEqual(@as(usize, 1), message.content.len);
    try std.testing.expectEqualStrings("compact", message.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.stop, message.stop_reason);
    try std.testing.expectEqualStrings("chatcmpl_compact", message.response_id.?);
}

test "openai_chat_sse maps stop reasons" {
    const allocator = std.testing.allocator;

    const stop = try mapStopReason(allocator, "stop");
    try std.testing.expectEqual(types.StopReason.stop, stop.stop_reason);
    try std.testing.expect(stop.error_message == null);

    const length = try mapStopReason(allocator, "length");
    try std.testing.expectEqual(types.StopReason.length, length.stop_reason);
    try std.testing.expect(length.error_message == null);

    const tools = try mapStopReason(allocator, "tool_calls");
    try std.testing.expectEqual(types.StopReason.tool_use, tools.stop_reason);
    try std.testing.expect(tools.error_message == null);

    const unknown = try mapStopReason(allocator, "content_filter");
    defer if (unknown.error_message) |message| allocator.free(message);
    try std.testing.expectEqual(types.StopReason.error_reason, unknown.stop_reason);
    try std.testing.expectEqualStrings("Provider finish_reason: content_filter", unknown.error_message.?);
}

test "openai_chat_sse normalizes usage cache writes" {
    const allocator = std.testing.allocator;
    const usage_json = "{\"prompt_tokens\":100,\"completion_tokens\":50,\"prompt_tokens_details\":{\"cached_tokens\":20,\"cache_write_tokens\":10}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, usage_json, .{});
    defer parsed.deinit();

    const usage = parseChunkUsage(allocator, parsed.value, testModel("https://api.openai.com/v1"));
    try std.testing.expectEqual(@as(u32, 80), usage.input);
    try std.testing.expectEqual(@as(u32, 50), usage.output);
    try std.testing.expectEqual(@as(u32, 10), usage.cache_read);
    try std.testing.expectEqual(@as(u32, 10), usage.cache_write);
    try std.testing.expectEqual(@as(u32, 150), usage.total_tokens);
}

test "openai_chat_sse keeps interleaved indexed tool arguments separated" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(u8, "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"arguments\":\"{\\\"unit\\\":\\\"\"}},{\"index\":0,\"function\":{\"arguments\":\"{\\\"city\\\":\\\"Ber\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_city\",\"function\":{\"name\":\"get_city\",\"arguments\":\"lin\\\"}\"}},{\"index\":1,\"id\":\"call_unit\",\"function\":{\"name\":\"get_unit\",\"arguments\":\"C\\\"}\"}}]}}]}\n" ++
        "data: [DONE]\n");

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, testModel("https://api.openai.com/v1"), null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_delta, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_delta, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_delta, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_delta, stream.next().?.event_type);

    const unit_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, unit_end.event_type);
    try std.testing.expectEqualStrings("call_unit", unit_end.tool_call.?.id);
    try std.testing.expectEqualStrings("C", unit_end.tool_call.?.arguments.object.get("unit").?.string);

    const city_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, city_end.event_type);
    try std.testing.expectEqualStrings("call_city", city_end.tool_call.?.id);
    try std.testing.expectEqualStrings("Berlin", city_end.tool_call.?.arguments.object.get("city").?.string);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(@as(usize, 2), done.message.?.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_unit", done.message.?.content[0].tool_call.id);
    try std.testing.expectEqualStrings("call_city", done.message.?.content[1].tool_call.id);
}

test "openai_chat_sse keeps text content indexes stable around tool boundaries" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"choices\":[{\"delta\":{\"content\":\"before \"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_weather\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}}]}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"after\"}}]}\n" ++
            "data: {\"choices\":[{\"finish_reason\":\"tool_calls\",\"delta\":{}}]}\n" ++
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

    try parseSseStreamLines(allocator, &stream, &streaming, testModel("https://api.openai.com/v1"), null);

    const start = stream.next().?;
    try std.testing.expectEqual(types.EventType.start, start.event_type);

    const first_text_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_start, first_text_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), first_text_start.content_index.?);

    const first_text_delta = stream.next().?;
    defer first_text_delta.deinitTransient(allocator);
    try std.testing.expectEqual(types.EventType.text_delta, first_text_delta.event_type);
    try std.testing.expectEqual(@as(u32, 0), first_text_delta.content_index.?);
    try std.testing.expectEqualStrings("before ", first_text_delta.delta.?);

    const first_text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, first_text_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), first_text_end.content_index.?);
    try std.testing.expectEqualStrings("before ", first_text_end.content.?);

    const tool_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_start.content_index.?);

    const tool_delta = stream.next().?;
    defer tool_delta.deinitTransient(allocator);
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_delta.content_index.?);

    const second_text_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_start, second_text_start.event_type);
    try std.testing.expectEqual(@as(u32, 2), second_text_start.content_index.?);

    const second_text_delta = stream.next().?;
    defer second_text_delta.deinitTransient(allocator);
    try std.testing.expectEqual(types.EventType.text_delta, second_text_delta.event_type);
    try std.testing.expectEqual(@as(u32, 2), second_text_delta.content_index.?);
    try std.testing.expectEqualStrings("after", second_text_delta.delta.?);

    const tool_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_end.content_index.?);
    try std.testing.expectEqualStrings("call_weather", tool_end.tool_call.?.id);

    const second_text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, second_text_end.event_type);
    try std.testing.expectEqual(@as(u32, 2), second_text_end.content_index.?);
    try std.testing.expectEqualStrings("after", second_text_end.content.?);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 3), done.message.?.content.len);
    try std.testing.expectEqualStrings("before ", done.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("call_weather", done.message.?.content[1].tool_call.id);
    try std.testing.expectEqualStrings("Berlin", done.message.?.content[1].tool_call.arguments.object.get("city").?.string);
    try std.testing.expectEqualStrings("after", done.message.?.content[2].text.text);

    const message = stream.result() orelse return error.MissingAssistantMessage;
    defer types.freeAssistantMessage(allocator, message);

    try std.testing.expectEqual(null, stream.next());
}

test "openai_chat_sse finalizes text and tool call on EOF mid-block" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"id\":\"chatcmpl_eof\",\"choices\":[{\"delta\":{\"content\":\"before tool\"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_eof\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"query\\\":\\\"local\\\"}\"}}]}}]}\n",
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

    try parseSseStreamLines(allocator, &stream, &streaming, testModel("https://api.openai.com/v1"), null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    const text_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_start, text_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_start.content_index.?);
    const text_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_delta.content_index.?);
    try std.testing.expectEqualStrings("before tool", text_delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_end.content_index.?);
    try std.testing.expectEqualStrings("before tool", text_end.content.?);

    const tool_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_start.content_index.?);
    const tool_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_delta.content_index.?);
    const tool_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_end.content_index.?);
    try std.testing.expectEqualStrings("call_eof", tool_end.tool_call.?.id);
    try std.testing.expectEqualStrings("lookup", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("local", tool_end.tool_call.?.arguments.object.get("query").?.string);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqualStrings("chatcmpl_eof", done.message.?.response_id.?);
    try std.testing.expectEqual(@as(usize, 2), done.message.?.content.len);
    try std.testing.expectEqualStrings("before tool", done.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("lookup", done.message.?.content[1].tool_call.name);
    try std.testing.expectEqualStrings("local", done.message.?.content[1].tool_call.arguments.object.get("query").?.string);
    try std.testing.expect(stream.next() == null);
}
