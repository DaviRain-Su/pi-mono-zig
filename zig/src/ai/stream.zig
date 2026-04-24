const std = @import("std");
const api_registry = @import("api_registry.zig");
const event_stream = @import("event_stream.zig");
const model_registry = @import("model_registry.zig");
const simple_options_mod = @import("shared/simple_options.zig");
const types = @import("types.zig");

const EntryFunctionError = error{
    ProviderNotFound,
    MissingCompletionResult,
};

pub fn stream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    const provider = api_registry.get(model.api) orelse return EntryFunctionError.ProviderNotFound;
    return try provider.stream(allocator, io, model, context, options);
}

pub fn complete(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !types.AssistantMessage {
    var stream_instance = try stream(allocator, io, model, context, options);
    defer stream_instance.deinit();

    while (stream_instance.next()) |event| {
        defer event.deinitTransient(allocator);
    }

    return stream_instance.result() orelse EntryFunctionError.MissingCompletionResult;
}

pub fn streamSimple(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.SimpleStreamOptions,
) !event_stream.AssistantMessageEventStream {
    const stream_options = if (options) |simple_options| blk: {
        var mapped = simple_options.toStreamOptions();
        applyResponsesSimpleOptions(&mapped, model, simple_options.reasoning);
        applyMistralSimpleOptions(&mapped, model, simple_options.reasoning);
        break :blk mapped;
    } else null;
    return try stream(allocator, io, model, context, stream_options);
}

pub fn completeSimple(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.SimpleStreamOptions,
) !types.AssistantMessage {
    const stream_options = if (options) |simple_options| blk: {
        var mapped = simple_options.toStreamOptions();
        applyResponsesSimpleOptions(&mapped, model, simple_options.reasoning);
        applyMistralSimpleOptions(&mapped, model, simple_options.reasoning);
        break :blk mapped;
    } else null;
    return try complete(allocator, io, model, context, stream_options);
}

fn applyMistralSimpleOptions(
    stream_options: *types.StreamOptions,
    model: types.Model,
    reasoning: ?types.ThinkingLevel,
) void {
    if (reasoning == null) return;
    if (!model.reasoning) return;
    if (!std.mem.eql(u8, model.api, "mistral-conversations")) return;

    if (std.mem.eql(u8, model.id, "mistral-small-2603") or std.mem.eql(u8, model.id, "mistral-small-latest")) {
        stream_options.mistral_reasoning_effort = "high";
    } else {
        stream_options.mistral_prompt_mode = "reasoning";
    }
}

fn applyResponsesSimpleOptions(
    stream_options: *types.StreamOptions,
    model: types.Model,
    reasoning: ?types.ThinkingLevel,
) void {
    if (reasoning == null) return;
    if (!model.reasoning) return;
    if (!std.mem.eql(u8, model.api, "openai-responses") and
        !std.mem.eql(u8, model.api, "openai-codex-responses") and
        !std.mem.eql(u8, model.api, "azure-openai-responses"))
    {
        return;
    }

    stream_options.responses_reasoning_effort = if (model_registry.supportsXhigh(model))
        reasoning.?
    else
        simple_options_mod.clampReasoning(reasoning).?;
}

const RecordingState = struct {
    stream_calls: usize = 0,
    stream_simple_calls: usize = 0,
    saw_max_tokens: ?u32 = null,
    saw_temperature: ?f32 = null,
    saw_api_key: ?[]const u8 = null,
    saw_responses_reasoning_effort: ?types.ThinkingLevel = null,
    saw_mistral_prompt_mode: ?[]const u8 = null,
    saw_mistral_reasoning_effort: ?[]const u8 = null,
    response_text: []const u8 = "recorded response",
};

var recording_state = RecordingState{};

fn resetRecordingState() void {
    recording_state = .{};
}

fn recordingStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    _: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    _ = allocator;
    _ = io;
    recording_state.stream_calls += 1;
    if (options) |stream_options| {
        recording_state.saw_max_tokens = stream_options.max_tokens;
        recording_state.saw_temperature = stream_options.temperature;
        recording_state.saw_api_key = stream_options.api_key;
        recording_state.saw_responses_reasoning_effort = stream_options.responses_reasoning_effort;
        recording_state.saw_mistral_prompt_mode = stream_options.mistral_prompt_mode;
        recording_state.saw_mistral_reasoning_effort = stream_options.mistral_reasoning_effort;
    }

    const result_allocator = std.heap.page_allocator;
    const text = try result_allocator.dupe(u8, recording_state.response_text);
    const content = try result_allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };

    var stream_instance = event_stream.createAssistantMessageEventStream(std.testing.allocator, std.Io.failing);
    stream_instance.push(.{
        .event_type = .done,
        .message = .{
            .content = content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = types.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        },
    });
    return stream_instance;
}

fn recordingStreamSimple(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    recording_state.stream_simple_calls += 1;
    return recordingStream(allocator, io, model, context, options);
}

fn ownedDeltaStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    _: types.Context,
    _: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    const result_allocator = std.heap.page_allocator;
    const text = try result_allocator.dupe(u8, "owned delta complete");
    const content = try result_allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    stream_instance.push(.{ .event_type = .start });
    stream_instance.push(.{ .event_type = .text_start, .content_index = 0 });
    stream_instance.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = try allocator.dupe(u8, "owned "),
        .owns_delta = true,
    });
    stream_instance.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = try allocator.dupe(u8, "delta "),
        .owns_delta = true,
    });
    stream_instance.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = try allocator.dupe(u8, "complete"),
        .owns_delta = true,
    });
    stream_instance.push(.{
        .event_type = .done,
        .message = .{
            .content = content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = types.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        },
    });
    return stream_instance;
}

test "stream routes to registered provider" {
    api_registry.clear();
    defer api_registry.clear();
    resetRecordingState();
    recording_state.response_text = "hello from stream";

    try api_registry.register(.{
        .api = "recording:test:stream",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const model = types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:stream",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var stream_instance = try stream(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        null,
    );
    defer stream_instance.deinit();
    while (stream_instance.next()) |_| {}

    const result = stream_instance.result().?;
    try std.testing.expectEqualStrings("hello from stream", result.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), recording_state.stream_calls);
    try std.testing.expectEqual(@as(usize, 0), recording_state.stream_simple_calls);
}

test "streamSimple maps simple options and routes through stream" {
    api_registry.clear();
    defer api_registry.clear();
    resetRecordingState();
    recording_state.response_text = "simple complete";

    try api_registry.register(.{
        .api = "recording:test",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const model = types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var stream_instance = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        .{
            .temperature = 0.25,
            .max_tokens = 42,
            .api_key = "test-key",
        },
    );
    defer stream_instance.deinit();
    while (stream_instance.next()) |_| {}

    try std.testing.expectEqual(@as(usize, 1), recording_state.stream_calls);
    try std.testing.expectEqual(@as(usize, 0), recording_state.stream_simple_calls);
    try std.testing.expectEqual(@as(?u32, 42), recording_state.saw_max_tokens);
    try std.testing.expectEqual(@as(?f32, 0.25), recording_state.saw_temperature);
    try std.testing.expectEqualStrings("test-key", recording_state.saw_api_key.?);
    try std.testing.expect(recording_state.saw_mistral_prompt_mode == null);
    try std.testing.expect(recording_state.saw_mistral_reasoning_effort == null);
}

test "streamSimple maps Mistral reasoning to provider options" {
    api_registry.clear();
    defer api_registry.clear();

    try api_registry.register(.{
        .api = "mistral-conversations",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const medium_model = types.Model{
        .id = "mistral-medium-latest",
        .name = "Mistral Medium",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
        .max_tokens = 32768,
    };

    resetRecordingState();
    var medium_stream = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        medium_model,
        .{ .messages = &[_]types.Message{} },
        .{ .reasoning = .medium },
    );
    defer medium_stream.deinit();
    while (medium_stream.next()) |_| {}

    try std.testing.expectEqualStrings("reasoning", recording_state.saw_mistral_prompt_mode.?);
    try std.testing.expect(recording_state.saw_mistral_reasoning_effort == null);

    const small_model = types.Model{
        .id = "mistral-small-latest",
        .name = "Mistral Small",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
        .max_tokens = 32768,
    };

    resetRecordingState();
    var small_stream = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        small_model,
        .{ .messages = &[_]types.Message{} },
        .{ .reasoning = .high },
    );
    defer small_stream.deinit();
    while (small_stream.next()) |_| {}

    try std.testing.expect(recording_state.saw_mistral_prompt_mode == null);
    try std.testing.expectEqualStrings("high", recording_state.saw_mistral_reasoning_effort.?);
}

test "streamSimple preserves xhigh reasoning for Codex GPT-5.5" {
    api_registry.clear();
    defer api_registry.clear();
    resetRecordingState();

    try api_registry.register(.{
        .api = "openai-codex-responses",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const model = types.Model{
        .id = "gpt-5.5",
        .name = "Codex GPT-5.5",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    var stream_instance = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        .{ .reasoning = .xhigh },
    );
    defer stream_instance.deinit();

    _ = stream_instance.next();
    try std.testing.expectEqual(@as(?types.ThinkingLevel, .xhigh), recording_state.saw_responses_reasoning_effort);
}

test "complete returns final assistant message" {
    api_registry.clear();
    defer api_registry.clear();
    resetRecordingState();
    recording_state.response_text = "hello from complete";

    try api_registry.register(.{
        .api = "recording:test:complete",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const model = types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:complete",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    const result = try complete(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        null,
    );

    try std.testing.expectEqualStrings("hello from complete", result.content[0].text.text);
}

test "complete frees owned streaming deltas after consumption" {
    api_registry.clear();
    defer api_registry.clear();

    try api_registry.register(.{
        .api = "recording:test:owned-delta",
        .stream = ownedDeltaStream,
        .stream_simple = ownedDeltaStream,
    });

    const model = types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:owned-delta",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    const result = try complete(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        null,
    );

    try std.testing.expectEqualStrings("owned delta complete", result.content[0].text.text);
}

test "completeSimple returns final assistant message from simple options" {
    api_registry.clear();
    defer api_registry.clear();
    resetRecordingState();
    recording_state.response_text = "simple complete";

    try api_registry.register(.{
        .api = "recording:test:complete-simple",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const model = types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:complete-simple",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    const result = try completeSimple(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        .{ .max_tokens = 7 },
    );

    try std.testing.expectEqualStrings("simple complete", result.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), recording_state.stream_calls);
    try std.testing.expectEqual(@as(usize, 0), recording_state.stream_simple_calls);
}
