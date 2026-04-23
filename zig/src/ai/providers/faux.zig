const std = @import("std");
const types = @import("../types.zig");
const event_stream = @import("../event_stream.zig");
const api_registry = @import("../api_registry.zig");

pub const DEFAULT_API = "faux";
pub const DEFAULT_PROVIDER = "faux";
const DEFAULT_MODEL_ID = "faux-1";
const DEFAULT_MODEL_NAME = "Faux Model";
const DEFAULT_BASE_URL = "http://localhost:0";
const DEFAULT_MIN_TOKEN_SIZE: usize = 3;
const DEFAULT_MAX_TOKEN_SIZE: usize = 5;
const DEFAULT_TOKENS_PER_SECOND: u32 = 0;
const DEFAULT_CONTEXT_WINDOW: u32 = 128000;
const DEFAULT_MAX_TOKENS: u32 = 16384;

pub const FauxStreamOptions = types.StreamOptions;

pub const FauxModelDefinition = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    reasoning: bool = false,
    input: ?[]const []const u8 = null,
    cost: ?types.ModelCost = null,
    context_window: ?u32 = null,
    max_tokens: ?u32 = null,
};

pub const FauxTokenSize = struct {
    min: ?u32 = null,
    max: ?u32 = null,
};

pub const FauxContentBlock = union(enum) {
    text: []const u8,
    thinking: []const u8,
    tool_call: types.ToolCall,
};

pub const FauxAssistantMessageOptions = struct {
    stop_reason: types.StopReason = .stop,
    error_message: ?[]const u8 = null,
    response_id: ?[]const u8 = null,
    timestamp: ?i64 = null,
};

pub const FauxAssistantMessage = struct {
    content: []const FauxContentBlock,
    stop_reason: types.StopReason = .stop,
    error_message: ?[]const u8 = null,
    response_id: ?[]const u8 = null,
    timestamp: i64,
};

pub const FauxToolCallOptions = struct {
    id: ?[]const u8 = null,
};

pub const FauxResponseFactory = *const fn (
    allocator: std.mem.Allocator,
    context: types.Context,
    options: ?types.StreamOptions,
    call_count: *usize,
    model: types.Model,
) anyerror!FauxAssistantMessage;

pub const FauxResponseStep = union(enum) {
    message: FauxAssistantMessage,
    factory: FauxResponseFactory,
};

pub const RegisterFauxProviderOptions = struct {
    api: ?[]const u8 = null,
    provider: ?[]const u8 = DEFAULT_PROVIDER,
    models: ?[]const FauxModelDefinition = null,
    tokens_per_second: ?u32 = null,
    token_size: ?FauxTokenSize = null,
};

const PromptCacheEntry = struct {
    session_id: []u8,
    prompt: []u8,
};

const FauxProviderState = struct {
    allocator: std.mem.Allocator,
    api: []const u8,
    provider: []const u8,
    source_id: []const u8,
    tokens_per_second: u32,
    min_token_size: usize,
    max_token_size: usize,
    pending_responses: std.ArrayList(FauxResponseStep),
    call_count: usize,
    prompt_cache: std.ArrayList(PromptCacheEntry),
    models: std.ArrayList(types.Model),

    fn deinit(self: *FauxProviderState) void {
        self.pending_responses.deinit(self.allocator);
        for (self.prompt_cache.items) |entry| {
            self.allocator.free(entry.session_id);
            self.allocator.free(entry.prompt);
        }
        self.prompt_cache.deinit(self.allocator);
        self.models.deinit(self.allocator);
        self.allocator.free(self.api);
        self.allocator.free(self.provider);
        self.allocator.free(self.source_id);
    }
};

pub const FauxProviderRegistration = struct {
    state: *FauxProviderState,

    pub fn getModel(self: FauxProviderRegistration) types.Model {
        return self.state.models.items[0];
    }

    pub fn getModelById(self: FauxProviderRegistration, model_id: []const u8) ?types.Model {
        for (self.state.models.items) |model| {
            if (std.mem.eql(u8, model.id, model_id)) return model;
        }
        return null;
    }

    pub fn setResponses(self: FauxProviderRegistration, responses: []const FauxResponseStep) !void {
        self.state.pending_responses.clearRetainingCapacity();
        try appendQueuedResponses(self.state, responses);
    }

    pub fn appendResponses(self: FauxProviderRegistration, responses: []const FauxResponseStep) !void {
        try appendQueuedResponses(self.state, responses);
    }

    pub fn getPendingResponseCount(self: FauxProviderRegistration) usize {
        return self.state.pending_responses.items.len;
    }

    pub fn unregister(self: FauxProviderRegistration) void {
        unregisterProvider(self.state.api);
        api_registry.unregister(self.state.api);
        self.state.deinit();
        self.state.allocator.destroy(self.state);
    }
};

const FauxProviderError = error{
    MissingProviderState,
};

const StreamPlanToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.Value,
    serialized_arguments: []const u8,
};

const StreamPlanBlock = union(enum) {
    text: []const u8,
    thinking: []const u8,
    tool_call: StreamPlanToolCall,
};

const StreamPlan = struct {
    stream: *event_stream.AssistantMessageEventStream,
    blocks: []const StreamPlanBlock,
    final_message: types.AssistantMessage,
    signal: ?*const std.atomic.Value(bool),
    tokens_per_second: u32,
    min_token_size: usize,
    max_token_size: usize,
};

var faux_registry: std.StringHashMap(*FauxProviderState) = undefined;
var faux_registry_initialized = false;
var faux_source_count: usize = 0;
var faux_tool_call_count: usize = 0;

pub fn fauxText(text: []const u8) FauxContentBlock {
    return .{ .text = text };
}

pub fn fauxThinking(thinking: []const u8) FauxContentBlock {
    return .{ .thinking = thinking };
}

pub fn fauxToolCall(
    allocator: std.mem.Allocator,
    name: []const u8,
    arguments: std.json.Value,
    options: FauxToolCallOptions,
) !FauxContentBlock {
    const id = if (options.id) |provided|
        try allocator.dupe(u8, provided)
    else
        try nextToolCallId(allocator);

    return .{ .tool_call = .{
        .id = id,
        .name = try allocator.dupe(u8, name),
        .arguments = try cloneJsonValue(allocator, arguments),
    } };
}

pub fn fauxAssistantMessage(content: []const FauxContentBlock, options: FauxAssistantMessageOptions) FauxAssistantMessage {
    return .{
        .content = content,
        .stop_reason = options.stop_reason,
        .error_message = options.error_message,
        .response_id = options.response_id,
        .timestamp = options.timestamp orelse @as(i64, 0),
    };
}

fn ensureRegistry() void {
    if (!faux_registry_initialized) {
        faux_registry = std.StringHashMap(*FauxProviderState).init(std.heap.page_allocator);
        faux_registry_initialized = true;
    }
}

fn registerInStateMap(state: *FauxProviderState) !void {
    ensureRegistry();
    try faux_registry.put(state.api, state);
}

fn lookupState(api: []const u8) ?*FauxProviderState {
    if (!faux_registry_initialized) return null;
    return faux_registry.get(api);
}

fn unregisterProvider(api: []const u8) void {
    if (!faux_registry_initialized) return;
    _ = faux_registry.remove(api);
}

fn nextSourceId(allocator: std.mem.Allocator) ![]u8 {
    faux_source_count += 1;
    return try std.fmt.allocPrint(allocator, "faux-provider-{d}", .{faux_source_count});
}

fn nextToolCallId(allocator: std.mem.Allocator) ![]u8 {
    faux_tool_call_count += 1;
    return try std.fmt.allocPrint(allocator, "tool-{d}", .{faux_tool_call_count});
}

fn appendQueuedResponses(state: *FauxProviderState, responses: []const FauxResponseStep) !void {
    for (responses) |response| {
        try state.pending_responses.append(state.allocator, response);
    }
}

fn estimateTokens(text: []const u8) u32 {
    return @as(u32, @intCast((text.len + 3) / 4));
}

fn maxUsize(a: usize, b: usize) usize {
    return if (a > b) a else b;
}

fn minUsize(a: usize, b: usize) usize {
    return if (a < b) a else b;
}

fn chunkDelayMs(chunk: []const u8, tokens_per_second: u32) u64 {
    if (tokens_per_second == 0) return 0;
    const tokens = estimateTokens(chunk);
    if (tokens == 0) return 0;
    return (@as(u64, tokens) * 1000 + tokens_per_second - 1) / tokens_per_second;
}

fn sleepForChunk(chunk: []const u8, tokens_per_second: u32) void {
    _ = chunk;
    _ = tokens_per_second;
}

fn isAbortRequested(signal: ?*const std.atomic.Value(bool)) bool {
    return if (signal) |abort_signal| abort_signal.load(.seq_cst) else false;
}

fn writeJsonString(writer: anytype, value: std.json.Value) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn contentToText(allocator: std.mem.Allocator, content: []const types.ContentBlock) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    for (content, 0..) |block, index| {
        if (index > 0) try writer.writeAll("\n");
        switch (block) {
            .text => |text| try writer.writeAll(text.text),
            .image => |image| try writer.print("[image:{s}:{d}]", .{ image.mime_type, image.data.len }),
            .thinking => |thinking| try writer.writeAll(thinking.thinking),
        }
    }

    return try allocator.dupe(u8, out.written());
}

fn assistantContentToText(allocator: std.mem.Allocator, content: []const FauxContentBlock) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    for (content, 0..) |block, index| {
        if (index > 0) try writer.writeAll("\n");
        switch (block) {
            .text => |text| try writer.writeAll(text),
            .thinking => |thinking| try writer.writeAll(thinking),
            .tool_call => |tool_call| {
                try writer.print("{s}:", .{tool_call.name});
                try writeJsonString(writer, tool_call.arguments);
            },
        }
    }

    return try allocator.dupe(u8, out.written());
}

fn messageToText(allocator: std.mem.Allocator, message: types.Message) ![]u8 {
    switch (message) {
        .user => |user| return contentToText(allocator, user.content),
        .assistant => |assistant| {
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            const writer = &out.writer;

            const content_text = try contentToText(allocator, assistant.content);
            defer allocator.free(content_text);
            try writer.writeAll(content_text);

            if (assistant.tool_calls) |tool_calls| {
                for (tool_calls) |tool_call| {
                    if (out.written().len > 0) try writer.writeAll("\n");
                    try writer.print("{s}:", .{tool_call.name});
                    try writeJsonString(writer, tool_call.arguments);
                }
            }

            return try allocator.dupe(u8, out.written());
        },
        .tool_result => |tool_result| {
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            const writer = &out.writer;
            try writer.writeAll(tool_result.tool_name);

            if (tool_result.content.len > 0) {
                try writer.writeAll("\n");
                const content_text = try contentToText(allocator, tool_result.content);
                defer allocator.free(content_text);
                try writer.writeAll(content_text);
            }

            return try allocator.dupe(u8, out.written());
        },
    }
}

fn serializeContext(allocator: std.mem.Allocator, context: types.Context) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    var needs_separator = false;
    if (context.system_prompt) |system_prompt| {
        try writer.print("system:{s}", .{system_prompt});
        needs_separator = true;
    }

    for (context.messages) |message| {
        if (needs_separator) try writer.writeAll("\n\n");
        try writer.print("{s}:", .{@tagName(message)});
        const text = try messageToText(allocator, message);
        defer allocator.free(text);
        try writer.writeAll(text);
        needs_separator = true;
    }

    if (context.tools) |tools| {
        if (tools.len > 0) {
            if (needs_separator) try writer.writeAll("\n\n");
            try writer.writeAll("tools:");
            try std.json.Stringify.value(std.json.Value{ .array = try toolsToJsonArray(allocator, tools) }, .{}, writer);
        }
    }

    return try allocator.dupe(u8, out.written());
}

fn toolsToJsonArray(allocator: std.mem.Allocator, tools: []const types.Tool) !std.json.Array {
    var array = std.json.Array.init(allocator);
    for (tools) |tool| {
        var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool.name) });
        try object.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, tool.description) });
        try object.put(allocator, try allocator.dupe(u8, "parameters"), try cloneJsonValue(allocator, tool.parameters));
        try array.append(.{ .object = object });
    }
    return array;
}

fn findPromptCacheEntry(state: *FauxProviderState, session_id: []const u8) ?*PromptCacheEntry {
    for (state.prompt_cache.items) |*entry| {
        if (std.mem.eql(u8, entry.session_id, session_id)) return entry;
    }
    return null;
}

fn commonPrefixLength(a: []const u8, b: []const u8) usize {
    const limit = @min(a.len, b.len);
    var index: usize = 0;
    while (index < limit and a[index] == b[index]) : (index += 1) {}
    return index;
}

fn estimatePromptUsage(
    allocator: std.mem.Allocator,
    state: *FauxProviderState,
    context: types.Context,
    options: ?types.StreamOptions,
) !types.Usage {
    const prompt_text = try serializeContext(allocator, context);
    defer allocator.free(prompt_text);

    var usage = types.Usage.init();
    const prompt_tokens = estimateTokens(prompt_text);
    usage.input = prompt_tokens;

    if (options) |stream_options| {
        if (stream_options.session_id) |session_id| {
            if (stream_options.cache_retention != .none) {
                if (findPromptCacheEntry(state, session_id)) |existing| {
                    const cached_chars = commonPrefixLength(existing.prompt, prompt_text);
                    usage.cache_read = estimateTokens(existing.prompt[0..cached_chars]);
                    usage.cache_write = if (prompt_text.len > cached_chars)
                        estimateTokens(prompt_text[cached_chars..])
                    else
                        0;
                    usage.input = if (prompt_tokens > usage.cache_read) prompt_tokens - usage.cache_read else 0;
                    state.allocator.free(existing.prompt);
                    existing.prompt = try state.allocator.dupe(u8, prompt_text);
                } else {
                    try state.prompt_cache.append(state.allocator, .{
                        .session_id = try state.allocator.dupe(u8, session_id),
                        .prompt = try state.allocator.dupe(u8, prompt_text),
                    });
                    usage.cache_write = prompt_tokens;
                }
            }
        }
    }

    usage.total_tokens = usage.input + usage.output + usage.cache_read + usage.cache_write;
    return usage;
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) anyerror!std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |v| return .{ .bool = v },
        .integer => |v| return .{ .integer = v },
        .float => |v| return .{ .float = v },
        .number_string => |v| return .{ .number_string = try allocator.dupe(u8, v) },
        .string => |v| return .{ .string = try allocator.dupe(u8, v) },
        .array => |v| {
            var array = std.json.Array.init(allocator);
            for (v.items) |item| {
                try array.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = array };
        },
        .object => |v| {
            var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            var iterator = v.iterator();
            while (iterator.next()) |entry| {
                try object.put(
                    allocator,
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try cloneJsonValue(allocator, entry.value_ptr.*),
                );
            }
            return .{ .object = object };
        },
    }
}

fn buildStreamPlan(
    state: *FauxProviderState,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    response: FauxAssistantMessage,
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !*StreamPlan {
    const allocator = std.heap.page_allocator;
    const blocks = try allocator.alloc(StreamPlanBlock, response.content.len);

    var content_count: usize = 0;
    var tool_call_count: usize = 0;
    for (response.content) |block| {
        switch (block) {
            .text, .thinking => content_count += 1,
            .tool_call => tool_call_count += 1,
        }
    }

    const content_blocks = try allocator.alloc(types.ContentBlock, content_count);
    const tool_calls = if (tool_call_count > 0) try allocator.alloc(types.ToolCall, tool_call_count) else null;

    var content_index: usize = 0;
    var tool_call_index: usize = 0;
    for (response.content, 0..) |block, index| {
        switch (block) {
            .text => |text| {
                const owned = try allocator.dupe(u8, text);
                blocks[index] = .{ .text = owned };
                content_blocks[content_index] = .{ .text = .{ .text = owned } };
                content_index += 1;
            },
            .thinking => |thinking| {
                const owned = try allocator.dupe(u8, thinking);
                blocks[index] = .{ .thinking = owned };
                content_blocks[content_index] = .{ .thinking = .{ .thinking = owned } };
                content_index += 1;
            },
            .tool_call => |tool_call| {
                const id = try allocator.dupe(u8, tool_call.id);
                const name = try allocator.dupe(u8, tool_call.name);
                const arguments = try cloneJsonValue(allocator, tool_call.arguments);
                const serialized_arguments = try std.json.Stringify.valueAlloc(allocator, arguments, .{});

                blocks[index] = .{ .tool_call = .{
                    .id = id,
                    .name = name,
                    .arguments = arguments,
                    .serialized_arguments = serialized_arguments,
                } };

                tool_calls.?[tool_call_index] = .{
                    .id = id,
                    .name = name,
                    .arguments = try cloneJsonValue(allocator, tool_call.arguments),
                };
                tool_call_index += 1;
            },
        }
    }

    const assistant_text = try assistantContentToText(allocator, response.content);
    defer allocator.free(assistant_text);

    var usage = try estimatePromptUsage(std.heap.page_allocator, state, context, options);
    usage.output = estimateTokens(assistant_text);
    usage.total_tokens = usage.input + usage.output + usage.cache_read + usage.cache_write;

    const final_message = types.AssistantMessage{
        .content = content_blocks,
        .tool_calls = tool_calls,
        .api = state.api,
        .provider = state.provider,
        .model = model.id,
        .response_id = if (response.response_id) |response_id| try allocator.dupe(u8, response_id) else null,
        .usage = usage,
        .stop_reason = response.stop_reason,
        .error_message = if (response.error_message) |error_message| try allocator.dupe(u8, error_message) else null,
        .timestamp = response.timestamp,
    };

    const plan = try allocator.create(StreamPlan);
    plan.* = .{
        .stream = stream_ptr,
        .blocks = blocks,
        .final_message = final_message,
        .signal = if (options) |stream_options| stream_options.signal else null,
        .tokens_per_second = state.tokens_per_second,
        .min_token_size = state.min_token_size,
        .max_token_size = state.max_token_size,
    };
    return plan;
}

fn emitChunks(
    plan: *StreamPlan,
    event_type: types.EventType,
    content_index: usize,
    full_text: []const u8,
) bool {
    const min_chars = maxUsize(1, plan.min_token_size * 4);
    const max_chars = maxUsize(min_chars, plan.max_token_size * 4);
    var offset: usize = 0;
    var chunk_index: usize = 0;

    while (offset < full_text.len) {
        const span = if (plan.min_token_size == plan.max_token_size)
            min_chars
        else
            minUsize(max_chars, maxUsize(min_chars, (plan.min_token_size + (chunk_index % (plan.max_token_size - plan.min_token_size + 1))) * 4));
        const end = @min(full_text.len, offset + span);
        const chunk = full_text[offset..end];
        sleepForChunk(chunk, plan.tokens_per_second);
        if (isAbortRequested(plan.signal)) return false;
        plan.stream.push(.{
            .event_type = event_type,
            .content_index = @as(u32, @intCast(content_index)),
            .delta = chunk,
        });
        offset = end;
        chunk_index += 1;
    }

    if (full_text.len == 0) {
        plan.stream.push(.{
            .event_type = event_type,
            .content_index = @as(u32, @intCast(content_index)),
            .delta = "",
        });
    }

    return true;
}

fn makeAbortedMessage(message: types.AssistantMessage) types.AssistantMessage {
    return .{
        .content = message.content,
        .tool_calls = message.tool_calls,
        .api = message.api,
        .provider = message.provider,
        .model = message.model,
        .response_id = message.response_id,
        .usage = message.usage,
        .stop_reason = .aborted,
        .error_message = "Request was aborted",
        .timestamp = 0,
    };
}

fn emitAbort(plan: *StreamPlan) void {
    const aborted = makeAbortedMessage(plan.final_message);
    plan.stream.push(.{
        .event_type = .error_event,
        .error_message = aborted.error_message,
        .message = aborted,
    });
    plan.stream.end(aborted);
}

fn runStreamPlan(plan: *StreamPlan) void {
    if (isAbortRequested(plan.signal)) {
        emitAbort(plan);
        return;
    }

    plan.stream.push(.{
        .event_type = .start,
        .message = types.AssistantMessage{
            .content = &[_]types.ContentBlock{},
            .tool_calls = null,
            .api = plan.final_message.api,
            .provider = plan.final_message.provider,
            .model = plan.final_message.model,
            .response_id = plan.final_message.response_id,
            .usage = plan.final_message.usage,
            .stop_reason = plan.final_message.stop_reason,
            .error_message = plan.final_message.error_message,
            .timestamp = plan.final_message.timestamp,
        },
    });

    for (plan.blocks, 0..) |block, index| {
        switch (block) {
            .thinking => |thinking| {
                plan.stream.push(.{ .event_type = .thinking_start, .content_index = @as(u32, @intCast(index)) });
                if (!emitChunks(plan, .thinking_delta, index, thinking)) {
                    emitAbort(plan);
                    return;
                }
                plan.stream.push(.{
                    .event_type = .thinking_end,
                    .content_index = @as(u32, @intCast(index)),
                    .content = thinking,
                });
            },
            .text => |text| {
                plan.stream.push(.{ .event_type = .text_start, .content_index = @as(u32, @intCast(index)) });
                if (!emitChunks(plan, .text_delta, index, text)) {
                    emitAbort(plan);
                    return;
                }
                plan.stream.push(.{
                    .event_type = .text_end,
                    .content_index = @as(u32, @intCast(index)),
                    .content = text,
                });
            },
            .tool_call => |tool_call| {
                plan.stream.push(.{
                    .event_type = .toolcall_start,
                    .content_index = @as(u32, @intCast(index)),
                });
                if (!emitChunks(plan, .toolcall_delta, index, tool_call.serialized_arguments)) {
                    emitAbort(plan);
                    return;
                }
                plan.stream.push(.{
                    .event_type = .toolcall_end,
                    .content_index = @as(u32, @intCast(index)),
                    .tool_call = .{
                        .id = tool_call.id,
                        .name = tool_call.name,
                        .arguments = tool_call.arguments,
                    },
                });
            },
        }
    }

    if (plan.final_message.stop_reason == .error_reason or plan.final_message.stop_reason == .aborted) {
        plan.stream.push(.{
            .event_type = .error_event,
            .error_message = plan.final_message.error_message,
            .message = plan.final_message,
        });
        plan.stream.end(plan.final_message);
        return;
    }

    plan.stream.push(.{
        .event_type = .done,
        .message = plan.final_message,
    });
    plan.stream.end(plan.final_message);
}

fn createErrorMessage(
    api: []const u8,
    provider: []const u8,
    model: []const u8,
    message: []const u8,
) types.AssistantMessage {
    return .{
        .content = &[_]types.ContentBlock{},
        .tool_calls = null,
        .api = api,
        .provider = provider,
        .model = model,
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = message,
        .timestamp = 0,
    };
}

fn invokeOnResponse(options: ?types.StreamOptions, model: types.Model) void {
    if (options) |stream_options| {
        if (stream_options.on_response) |callback| {
            var headers = std.StringHashMap([]const u8).init(std.heap.page_allocator);
            defer headers.deinit();
            callback(200, headers, model);
        }
    }
}

pub const FauxProvider = struct {
    pub const api = DEFAULT_API;

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        _ = allocator;

        var stream_instance = event_stream.createAssistantMessageEventStream(std.heap.page_allocator, io);
        errdefer stream_instance.deinit();

        const state = lookupState(model.api) orelse return FauxProviderError.MissingProviderState;
        invokeOnResponse(options, model);

        const step = if (state.pending_responses.items.len > 0)
            state.pending_responses.orderedRemove(0)
        else
            null;
        state.call_count += 1;

        if (step == null) {
            const error_message = createErrorMessage(state.api, state.provider, model.id, "No more faux responses queued");
            stream_instance.push(.{
                .event_type = .error_event,
                .error_message = error_message.error_message,
                .message = error_message,
            });
            stream_instance.end(error_message);
            return stream_instance;
        }

        const resolved = switch (step.?) {
            .message => |message| message,
            .factory => |factory| factory(std.heap.page_allocator, context, options, &state.call_count, model) catch |err| {
                const error_text = @errorName(err);
                const error_message = createErrorMessage(state.api, state.provider, model.id, error_text);
                stream_instance.push(.{
                    .event_type = .error_event,
                    .error_message = error_message.error_message,
                    .message = error_message,
                });
                stream_instance.end(error_message);
                return stream_instance;
            },
        };

        const plan = try buildStreamPlan(state, model, context, options, resolved, &stream_instance);
        const thread = try std.Thread.spawn(.{}, runStreamPlan, .{plan});
        thread.detach();
        return stream_instance;
    }

    pub fn streamSimple(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        return stream(allocator, io, model, context, options);
    }
};

pub fn registerFauxProvider(
    allocator: std.mem.Allocator,
    options: RegisterFauxProviderOptions,
) !FauxProviderRegistration {
    const api_name = try allocator.dupe(u8, options.api orelse DEFAULT_API);
    errdefer allocator.free(api_name);

    const provider_name = try allocator.dupe(u8, options.provider orelse DEFAULT_PROVIDER);
    errdefer allocator.free(provider_name);

    const token_size = options.token_size orelse FauxTokenSize{};
    const configured_min = @as(usize, token_size.min orelse DEFAULT_MIN_TOKEN_SIZE);
    const configured_max = @as(usize, token_size.max orelse DEFAULT_MAX_TOKEN_SIZE);
    const min_token_size = maxUsize(1, minUsize(configured_min, configured_max));
    const max_token_size = maxUsize(min_token_size, configured_max);

    const state = try allocator.create(FauxProviderState);
    errdefer allocator.destroy(state);

    state.* = .{
        .allocator = allocator,
        .api = api_name,
        .provider = provider_name,
        .source_id = try nextSourceId(allocator),
        .tokens_per_second = options.tokens_per_second orelse DEFAULT_TOKENS_PER_SECOND,
        .min_token_size = min_token_size,
        .max_token_size = max_token_size,
        .pending_responses = .empty,
        .call_count = 0,
        .prompt_cache = .empty,
        .models = .empty,
    };

    const definitions = options.models orelse &[_]FauxModelDefinition{.{
        .id = DEFAULT_MODEL_ID,
        .name = DEFAULT_MODEL_NAME,
        .reasoning = false,
        .input = &[_][]const u8{ "text", "image" },
        .cost = .{},
        .context_window = DEFAULT_CONTEXT_WINDOW,
        .max_tokens = DEFAULT_MAX_TOKENS,
    }};

    for (definitions) |definition| {
        try state.models.append(allocator, .{
            .id = definition.id,
            .name = definition.name orelse definition.id,
            .api = state.api,
            .provider = state.provider,
            .base_url = DEFAULT_BASE_URL,
            .reasoning = definition.reasoning,
            .input_types = definition.input orelse &[_][]const u8{ "text", "image" },
            .cost = definition.cost orelse .{},
            .context_window = definition.context_window orelse DEFAULT_CONTEXT_WINDOW,
            .max_tokens = definition.max_tokens orelse DEFAULT_MAX_TOKENS,
        });
    }

    try registerInStateMap(state);
    try api_registry.register(.{
        .api = state.api,
        .stream = FauxProvider.stream,
        .stream_simple = FauxProvider.streamSimple,
    });

    return .{ .state = state };
}

fn collectEventTypes(stream_instance: *event_stream.AssistantMessageEventStream, allocator: std.mem.Allocator) ![]types.EventType {
    var events: std.ArrayList(types.EventType) = .empty;
    errdefer events.deinit(allocator);

    while (stream_instance.next()) |event| {
        try events.append(allocator, event.event_type);
    }

    return try events.toOwnedSlice(allocator);
}

fn collectToolCallDeltas(stream_instance: *event_stream.AssistantMessageEventStream, allocator: std.mem.Allocator) ![]u8 {
    var deltas: std.ArrayList(u8) = .empty;
    errdefer deltas.deinit(allocator);

    while (stream_instance.next()) |event| {
        if (event.event_type == .toolcall_delta) {
            if (event.delta) |delta| try deltas.appendSlice(allocator, delta);
        }
    }

    return try deltas.toOwnedSlice(allocator);
}

test "estimateTokens uses ceil len over four" {
    try std.testing.expectEqual(@as(u32, 0), estimateTokens(""));
    try std.testing.expectEqual(@as(u32, 1), estimateTokens("abcd"));
    try std.testing.expectEqual(@as(u32, 2), estimateTokens("abcde"));
}

test "registerFauxProvider queues responses and estimates usage" {
    const allocator = std.testing.allocator;
    const registration = try registerFauxProvider(allocator, .{});
    defer registration.unregister();

    const hello_blocks = [_]FauxContentBlock{fauxText("hello")};
    const world_blocks = [_]FauxContentBlock{fauxText("world!")};
    try registration.setResponses(&[_]FauxResponseStep{
        .{ .message = fauxAssistantMessage(hello_blocks[0..], .{}) },
        .{ .message = fauxAssistantMessage(world_blocks[0..], .{}) },
    });

    const context = types.Context{
        .system_prompt = "sys",
        .messages = &[_]types.Message{.{ .user = .{
            .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hello user" } }},
            .timestamp = 1,
        } }},
    };

    var first_stream = try FauxProvider.stream(allocator, std.Io.failing, registration.getModel(), context, null);
    defer first_stream.deinit();
    _ = try collectEventTypes(&first_stream, allocator);
    const first = first_stream.result().?;
    try std.testing.expectEqualStrings("hello", first.content[0].text.text);
    try std.testing.expectEqual(@as(u32, 2), first.usage.output);

    var second_stream = try FauxProvider.stream(allocator, std.Io.failing, registration.getModel(), context, null);
    defer second_stream.deinit();
    _ = try collectEventTypes(&second_stream, allocator);
    const second = second_stream.result().?;
    try std.testing.expectEqualStrings("world!", second.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 0), registration.getPendingResponseCount());
    try std.testing.expectEqual(@as(usize, 2), registration.state.call_count);

    var exhausted_stream = try FauxProvider.stream(allocator, std.Io.failing, registration.getModel(), context, null);
    defer exhausted_stream.deinit();
    _ = try collectEventTypes(&exhausted_stream, allocator);
    const exhausted = exhausted_stream.result().?;
    try std.testing.expectEqual(types.StopReason.error_reason, exhausted.stop_reason);
    try std.testing.expectEqualStrings("No more faux responses queued", exhausted.error_message.?);
    try std.testing.expectEqual(@as(usize, 3), registration.state.call_count);
}

test "registerFauxProvider simulates prompt caching per session id" {
    const allocator = std.testing.allocator;
    const registration = try registerFauxProvider(allocator, .{});
    defer registration.unregister();

    const first_blocks = [_]FauxContentBlock{fauxText("first")};
    const second_blocks = [_]FauxContentBlock{fauxText("second")};
    const third_blocks = [_]FauxContentBlock{fauxText("third")};
    try registration.setResponses(&[_]FauxResponseStep{
        .{ .message = fauxAssistantMessage(first_blocks[0..], .{}) },
        .{ .message = fauxAssistantMessage(second_blocks[0..], .{}) },
        .{ .message = fauxAssistantMessage(third_blocks[0..], .{}) },
    });

    var context = types.Context{
        .system_prompt = "Be concise.",
        .messages = &[_]types.Message{.{ .user = .{
            .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hello" } }},
            .timestamp = 1,
        } }},
    };

    var first_stream = try FauxProvider.stream(allocator, std.Io.failing, registration.getModel(), context, .{
        .session_id = "session-1",
        .cache_retention = .short,
    });
    defer first_stream.deinit();
    _ = try collectEventTypes(&first_stream, allocator);
    const first = first_stream.result().?;
    try std.testing.expectEqual(@as(u32, 0), first.usage.cache_read);
    try std.testing.expect(first.usage.cache_write > 0);

    const second_messages = [_]types.Message{
        .{ .user = .{ .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hello" } }}, .timestamp = 1 } },
        .{ .assistant = first },
        .{ .user = .{ .content = &[_]types.ContentBlock{.{ .text = .{ .text = "follow up" } }}, .timestamp = 2 } },
    };
    context.messages = second_messages[0..];

    var second_stream = try FauxProvider.stream(allocator, std.Io.failing, registration.getModel(), context, .{
        .session_id = "session-1",
        .cache_retention = .short,
    });
    defer second_stream.deinit();
    _ = try collectEventTypes(&second_stream, allocator);
    const second = second_stream.result().?;
    try std.testing.expect(second.usage.cache_read > 0);

    var third_stream = try FauxProvider.stream(allocator, std.Io.failing, registration.getModel(), context, .{
        .session_id = "session-2",
        .cache_retention = .short,
    });
    defer third_stream.deinit();
    _ = try collectEventTypes(&third_stream, allocator);
    const third = third_stream.result().?;
    try std.testing.expectEqual(@as(u32, 0), third.usage.cache_read);
    try std.testing.expect(third.usage.cache_write > 0);
}

test "registerFauxProvider emits all event types for thinking text and tool calls" {
    const allocator = std.testing.allocator;
    const registration = try registerFauxProvider(allocator, .{ .token_size = .{ .min = 1, .max = 1 } });
    defer registration.unregister();

    var args_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try args_object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, "hi") });
    try args_object.put(allocator, try allocator.dupe(u8, "count"), .{ .integer = 12 });
    const tool_block = try fauxToolCall(allocator, "echo", .{ .object = args_object }, .{ .id = "tool-1" });

    const blocks = [_]FauxContentBlock{
        fauxThinking("go"),
        fauxText("ok"),
        tool_block,
    };
    try registration.setResponses(&[_]FauxResponseStep{.{ .message = fauxAssistantMessage(blocks[0..], .{ .stop_reason = .tool_use }) }});

    var stream_instance = try FauxProvider.stream(allocator, std.Io.failing, registration.getModel(), .{
        .messages = &[_]types.Message{.{ .user = .{
            .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hi" } }},
            .timestamp = 1,
        } }},
    }, null);
    defer stream_instance.deinit();

    const events = try collectEventTypes(&stream_instance, allocator);
    defer allocator.free(events);
    try std.testing.expectEqualSlices(types.EventType, &[_]types.EventType{
        .start,
        .thinking_start,
        .thinking_delta,
        .thinking_end,
        .text_start,
        .text_delta,
        .text_end,
        .toolcall_start,
        .toolcall_delta,
        .toolcall_delta,
        .toolcall_delta,
        .toolcall_delta,
        .toolcall_delta,
        .toolcall_end,
        .done,
    }, events);

    var delta_stream = try FauxProvider.stream(allocator, std.Io.failing, registration.getModel(), .{
        .messages = &[_]types.Message{.{ .user = .{
            .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hi again" } }},
            .timestamp = 2,
        } }},
    }, null);
    defer delta_stream.deinit();
    const tool_call_deltas = try collectToolCallDeltas(&delta_stream, allocator);
    defer allocator.free(tool_call_deltas);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, tool_call_deltas, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hi", parsed.value.object.get("text").?.string);
}

test "registerFauxProvider supports abort before the first chunk" {
    const allocator = std.testing.allocator;
    const registration = try registerFauxProvider(allocator, .{ .tokens_per_second = 100, .token_size = .{ .min = 3, .max = 3 } });
    defer registration.unregister();

    const blocks = [_]FauxContentBlock{fauxText("abcdefghijklmnopqrstuvwxyz")};
    try registration.setResponses(&[_]FauxResponseStep{.{ .message = fauxAssistantMessage(blocks[0..], .{}) }});

    var abort_signal = std.atomic.Value(bool).init(true);
    var stream_instance = try FauxProvider.stream(allocator, std.Io.failing, registration.getModel(), .{
        .messages = &[_]types.Message{.{ .user = .{
            .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hi" } }},
            .timestamp = 1,
        } }},
    }, .{ .signal = &abort_signal, .cache_retention = .none });
    defer stream_instance.deinit();

    const events = try collectEventTypes(&stream_instance, allocator);
    defer allocator.free(events);
    try std.testing.expectEqualSlices(types.EventType, &[_]types.EventType{.error_event}, events);
    try std.testing.expectEqual(types.StopReason.aborted, stream_instance.result().?.stop_reason);
}

test "registerFauxProvider supports aborting mid tool call stream" {
    const allocator = std.testing.allocator;
    const registration = try registerFauxProvider(allocator, .{ .tokens_per_second = 100, .token_size = .{ .min = 3, .max = 3 } });
    defer registration.unregister();

    var args_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try args_object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, "abcdefghijklmnopqrstuvwxyz") });
    const tool_block = try fauxToolCall(allocator, "echo", .{ .object = args_object }, .{ .id = "tool-99" });
    const blocks = [_]FauxContentBlock{tool_block};
    try registration.setResponses(&[_]FauxResponseStep{.{ .message = fauxAssistantMessage(blocks[0..], .{ .stop_reason = .tool_use }) }});

    var abort_signal = std.atomic.Value(bool).init(false);
    var stream_instance = try FauxProvider.stream(allocator, std.Io.failing, registration.getModel(), .{
        .messages = &[_]types.Message{.{ .user = .{
            .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hi" } }},
            .timestamp = 1,
        } }},
    }, .{ .signal = &abort_signal, .cache_retention = .none });
    defer stream_instance.deinit();

    var saw_delta = false;
    var saw_end = false;
    var saw_error = false;
    while (stream_instance.next()) |event| {
        switch (event.event_type) {
            .toolcall_delta => {
                if (!saw_delta) {
                    saw_delta = true;
                    abort_signal.store(true, .seq_cst);
                }
            },
            .toolcall_end => saw_end = true,
            .error_event => saw_error = true,
            else => {},
        }
    }

    try std.testing.expect(saw_delta);
    try std.testing.expect(!saw_end);
    try std.testing.expect(saw_error);
    try std.testing.expectEqual(types.StopReason.aborted, stream_instance.result().?.stop_reason);
}

test "registerFauxProvider unregisters from the provider registry" {
    const allocator = std.testing.allocator;
    const registration = try registerFauxProvider(allocator, .{ .api = "faux:test" });
    const model = registration.getModel();
    try std.testing.expect(api_registry.get(model.api) != null);
    registration.unregister();
    try std.testing.expect(api_registry.get(model.api) == null);
}
