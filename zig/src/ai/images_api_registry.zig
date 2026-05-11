const std = @import("std");
const types = @import("types.zig");
const image_builtins = @import("providers/images/register_builtins.zig");

pub const ImagesFunction = *const fn (
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.ImagesModel,
    context: types.ImagesContext,
    options: ?types.ImagesOptions,
) anyerror!types.AssistantImages;

pub const ImagesApiProvider = struct {
    api: types.ImagesApi,
    generate_images: ImagesFunction,
};

var registry: std.StringHashMap(ImagesApiProvider) = undefined;
var initialized = false;

pub fn init() void {
    if (initialized) return;
    registry = std.StringHashMap(ImagesApiProvider).init(std.heap.page_allocator);
    registerBuiltIns();
    initialized = true;
}

pub fn register(provider: ImagesApiProvider) !void {
    init();
    try registry.put(provider.api, provider);
}

pub fn get(api: types.ImagesApi) ?ImagesApiProvider {
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

pub fn resetForTesting() void {
    if (initialized) registry.clearAndFree();
    initialized = false;
}

pub fn resetToBuiltIns() void {
    init();
    registry.clearAndFree();
    registerBuiltIns();
}

fn registerBuiltIns() void {
    for (image_builtins.builtInProviders()) |provider| {
        registry.put(provider.api, provider) catch @panic("failed to register built-in images provider");
    }
}

test "built-in images providers are registered on first init" {
    resetForTesting();
    defer clear();

    try std.testing.expectEqual(image_builtins.expectedBuiltInApiCount(), getApiCount());
    for (image_builtins.expectedBuiltInApis()) |api| {
        try std.testing.expect(get(api) != null);
    }
}
