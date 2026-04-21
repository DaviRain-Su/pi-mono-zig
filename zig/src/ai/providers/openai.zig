const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");

pub const OpenAIProvider = struct {
    pub const api = "openai-completions";

    pub fn stream(
        allocator: std.mem.Allocator,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !void {
        _ = model;
        _ = context;
        _ = options;
        _ = allocator;
        // TODO: Implement OpenAI streaming
    }

    pub fn streamSimple(
        allocator: std.mem.Allocator,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !void {
        _ = model;
        _ = context;
        _ = options;
        _ = allocator;
        // TODO: Implement OpenAI simple streaming
    }
};
