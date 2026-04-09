const std = @import("std");
const types = @import("types.zig");
const event_stream = @import("event_stream.zig");

pub const ApiStreamFunction = *const fn (
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) event_stream.AssistantMessageEventStream;

pub const ApiStreamSimpleFunction = *const fn (
    model: types.Model,
    context: types.Context,
    options: ?types.SimpleStreamOptions,
) event_stream.AssistantMessageEventStream;

pub const ApiProvider = struct {
    api: types.Api,
    stream: ApiStreamFunction,
    stream_simple: ApiStreamSimpleFunction,
};

var registry: std.ArrayList(ApiProvider) = .empty;
var registry_mutex = std.Thread.Mutex{};

pub fn registerApiProvider(provider: ApiProvider) void {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    // Replace if exists
    for (registry.items, 0..) |*p, i| {
        if (apiEql(p.api, provider.api)) {
            registry.items[i] = provider;
            return;
        }
    }
    registry.append(std.heap.page_allocator, provider) catch @panic("OOM");
}

pub fn getApiProvider(api: types.Api) ?ApiProvider {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    for (registry.items) |provider| {
        if (apiEql(provider.api, api)) return provider;
    }
    return null;
}

pub fn getApiProviders() []const ApiProvider {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    return registry.items;
}

pub fn clearApiProviders() void {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    registry.clearRetainingCapacity();
}

fn apiEql(a: types.Api, b: types.Api) bool {
    return switch (a) {
        .known => |ak| switch (b) {
            .known => |bk| ak == bk,
            else => false,
        },
        .custom => |ac| switch (b) {
            .custom => |bc| std.mem.eql(u8, ac, bc),
            else => false,
        },
    };
}

// -- Unified API --

pub fn stream(model: types.Model, context: types.Context, options: ?types.StreamOptions) event_stream.AssistantMessageEventStream {
    const provider = getApiProvider(model.api) orelse @panic("No API provider registered");
    return provider.stream(model, context, options);
}

pub fn streamSimple(model: types.Model, context: types.Context, options: ?types.SimpleStreamOptions) event_stream.AssistantMessageEventStream {
    const provider = getApiProvider(model.api) orelse @panic("No API provider registered");
    return provider.stream_simple(model, context, options);
}

/// Blocking helper: consume the entire `stream()` result.
/// Returns the final AssistantMessage from the stream.
pub fn complete(model: types.Model, context: types.Context, options: ?types.StreamOptions) types.AssistantMessage {
    var es = stream(model, context, options);
    defer es.deinit();
    const result = es.waitResult() orelse return errorMessage(model, "Stream ended without result");
    if (result.len == 0) return errorMessage(model, "Stream returned empty result");
    return result[result.len - 1];
}

/// Blocking helper: consume the entire `streamSimple()` result.
pub fn completeSimple(model: types.Model, context: types.Context, options: ?types.SimpleStreamOptions) types.AssistantMessage {
    var es = streamSimple(model, context, options);
    defer es.deinit();
    const result = es.waitResult() orelse return errorMessage(model, "Stream ended without result");
    if (result.len == 0) return errorMessage(model, "Stream returned empty result");
    return result[result.len - 1];
}

fn errorMessage(model: types.Model, msg: []const u8) types.AssistantMessage {
    return types.AssistantMessage{
        .role = "assistant",
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = .{},
        .stop_reason = .err,
        .error_message = msg,
        .timestamp = 0,
    };
}

test "register and lookup provider" {
    clearApiProviders();
    const dummy_stream: ApiStreamFunction = struct {
        fn f(_: types.Model, _: types.Context, _: ?types.StreamOptions) event_stream.AssistantMessageEventStream {
            unreachable;
        }
    }.f;
    const dummy_simple: ApiStreamSimpleFunction = struct {
        fn f(_: types.Model, _: types.Context, _: ?types.SimpleStreamOptions) event_stream.AssistantMessageEventStream {
            unreachable;
        }
    }.f;

    const provider = ApiProvider{ .api = .{ .known = .faux }, .stream = dummy_stream, .stream_simple = dummy_simple };
    registerApiProvider(provider);

    const looked = getApiProvider(.{ .known = .faux });
    try std.testing.expect(looked != null);
    try std.testing.expect(looked.?.stream == dummy_stream);

    // overwrite
    registerApiProvider(provider);
    try std.testing.expectEqual(@as(usize, 1), getApiProviders().len);

    clearApiProviders();
}
