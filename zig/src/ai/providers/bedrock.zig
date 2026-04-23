const std = @import("std");
const types = @import("../types.zig");
const anthropic = @import("anthropic.zig");
const event_stream = @import("../event_stream.zig");

pub const BedrockProvider = struct {
    pub const api = "bedrock-converse-stream";

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        return try anthropic.AnthropicProvider.stream(allocator, io, model, context, options);
    }

    pub fn streamSimple(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        return try anthropic.AnthropicProvider.streamSimple(allocator, io, model, context, options);
    }
};
