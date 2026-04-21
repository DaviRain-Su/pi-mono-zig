const std = @import("std");
const types = @import("types.zig");

pub const StreamFunction = *const fn (
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) anyerror!void;

pub const ApiProvider = struct {
    api: types.Api,
    stream: StreamFunction,
    stream_simple: StreamFunction,
};

var registry: std.StringHashMap(ApiProvider) = undefined;
var initialized = false;

pub fn init() void {
    if (initialized) return;
    registry = std.StringHashMap(ApiProvider).init(std.heap.page_allocator);
    initialized = true;
}

pub fn register(provider: ApiProvider) !void {
    init();
    try registry.put(provider.api, provider);
}

pub fn get(api: types.Api) ?ApiProvider {
    init();
    return registry.get(api);
}

pub fn getApiCount() usize {
    init();
    return registry.count();
}

pub fn clear() void {
    init();
    registry.clearAndFree();
}

test "registry basic operations" {
    clear();

    const dummy_stream: StreamFunction = struct {
        fn f(_: std.mem.Allocator, _: types.Model, _: types.Context, _: ?types.StreamOptions) anyerror!void {}
    }.f;

    try register(.{
        .api = "openai-completions",
        .stream = dummy_stream,
        .stream_simple = dummy_stream,
    });

    try std.testing.expectEqual(@as(usize, 1), getApiCount());

    const provider = get("openai-completions");
    try std.testing.expect(provider != null);
    try std.testing.expectEqualStrings("openai-completions", provider.?.api);

    const not_found = get("nonexistent");
    try std.testing.expect(not_found == null);
}
