const std = @import("std");
const types = @import("../types.zig");
const openai_responses = @import("openai_responses.zig");
const event_stream = @import("../event_stream.zig");

pub const OpenAICodexResponsesProvider = struct {
    pub const api = "openai-codex-responses";

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        return try openai_responses.OpenAIResponsesProvider.stream(allocator, io, model, context, options);
    }

    pub fn streamSimple(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        return try openai_responses.OpenAIResponsesProvider.streamSimple(allocator, io, model, context, options);
    }
};
