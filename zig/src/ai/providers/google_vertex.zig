const std = @import("std");
const types = @import("../types.zig");
const google = @import("google.zig");
const event_stream = @import("../event_stream.zig");

pub const GoogleVertexProvider = struct {
    pub const api = "google-vertex";

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        return try google.GoogleProvider.stream(allocator, io, model, context, options);
    }

    pub fn streamSimple(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        return try google.GoogleProvider.streamSimple(allocator, io, model, context, options);
    }
};
