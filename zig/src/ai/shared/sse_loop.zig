const std = @import("std");

const abort_helper = @import("abort_signal.zig");
const http_client = @import("../http_client.zig");
const types = @import("../types.zig");

pub const LoopResult = enum {
    completed,
    stopped,
};

pub fn run(
    comptime Handler: type,
    handler: *Handler,
    streaming: *http_client.StreamingResponse,
    stream_options: ?types.StreamOptions,
) !LoopResult {
    while (true) {
        const maybe_line = streaming.readLine() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try handler.handleRuntimeFailure(err);
                return .stopped;
            },
        };
        const line = maybe_line orelse return .completed;

        if (abort_helper.isRequestedFromOptions(stream_options)) {
            try handler.handleRuntimeFailure(error.RequestAborted);
            return .stopped;
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "event:")) continue;

        const data = handler.extractDataLine(trimmed) orelse continue;
        if (handler.isDoneData(data)) return .completed;

        if (!try handler.handleData(data)) return .stopped;
    }
}

const FixtureHandler = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList([]const u8) = .empty,
    failures: usize = 0,

    fn deinit(self: *FixtureHandler) void {
        for (self.values.items) |value| self.allocator.free(value);
        self.values.deinit(self.allocator);
    }

    pub fn extractDataLine(_: *FixtureHandler, line: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, line, "data: ")) return line[6..];
        if (std.mem.startsWith(u8, line, "data:")) return std.mem.trim(u8, line[5..], " ");
        return null;
    }

    pub fn isDoneData(_: *FixtureHandler, data: []const u8) bool {
        return std.mem.eql(u8, data, "[DONE]");
    }

    pub fn handleData(self: *FixtureHandler, data: []const u8) !bool {
        if (std.mem.eql(u8, data, "stop-now")) return false;
        try self.values.append(self.allocator, try self.allocator.dupe(u8, data));
        return true;
    }

    pub fn handleRuntimeFailure(self: *FixtureHandler, _: anyerror) !void {
        self.failures += 1;
    }
};

test "shared SSE loop skips control lines and preserves provider data-line parser" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(
        u8,
        "event: message\n" ++
            "\n" ++
            " data:{\"compact\":true}\r\n" ++
            "data: {\"canonical\":true}\n" ++
            "data: [DONE]\n" ++
            "data: {\"ignored\":true}\n",
    );
    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var handler = FixtureHandler{ .allocator = allocator };
    defer handler.deinit();

    const result = try run(FixtureHandler, &handler, &streaming, null);
    try std.testing.expectEqual(LoopResult.completed, result);
    try std.testing.expectEqual(@as(usize, 2), handler.values.items.len);
    try std.testing.expectEqualStrings("{\"compact\":true}", handler.values.items[0]);
    try std.testing.expectEqualStrings("{\"canonical\":true}", handler.values.items[1]);
    try std.testing.expectEqual(@as(usize, 0), handler.failures);
}

test "shared SSE loop stops when provider handler emits terminal failure" {
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(
        u8,
        "data: first\n" ++
            "data: stop-now\n" ++
            "data: ignored\n",
    );
    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var handler = FixtureHandler{ .allocator = allocator };
    defer handler.deinit();

    const result = try run(FixtureHandler, &handler, &streaming, null);
    try std.testing.expectEqual(LoopResult.stopped, result);
    try std.testing.expectEqual(@as(usize, 1), handler.values.items.len);
    try std.testing.expectEqualStrings("first", handler.values.items[0]);
}
