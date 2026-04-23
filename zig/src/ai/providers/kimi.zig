const std = @import("std");
const types = @import("../types.zig");
const openai = @import("openai.zig");
const event_stream = @import("../event_stream.zig");

pub const KimiProvider = struct {
    pub const api = "kimi-completions";

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        return try openai.OpenAIProvider.stream(allocator, io, model, context, options);
    }

    pub fn streamSimple(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        return try openai.OpenAIProvider.streamSimple(allocator, io, model, context, options);
    }
};
