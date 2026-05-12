const std = @import("std");
const provider_info = @import("provider_info.zig");

pub const ResolveCliModelResult = struct {
    provider_name: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    warning: ?[]u8 = null,
    error_message: ?[]u8 = null,
    owned_model_name: ?[]u8 = null,

    pub fn deinit(self: *ResolveCliModelResult, allocator: std.mem.Allocator) void {
        if (self.warning) |warning| allocator.free(warning);
        if (self.error_message) |message| allocator.free(message);
        if (self.owned_model_name) |model_name| allocator.free(model_name);
        self.* = undefined;
    }
};

pub fn resolveCliModel(
    allocator: std.mem.Allocator,
    cli_provider: ?[]const u8,
    cli_model: ?[]const u8,
) !ResolveCliModelResult {
    _ = allocator;
    return .{
        .provider_name = cli_provider,
        .model_name = cli_model,
    };
}

pub const DefaultModelForProvider = struct {
    provider: []const u8,
    model: []const u8,
};

/// Per-provider default model identifiers, derived from the canonical
/// `provider_info.PROVIDERS` table. Providers whose `default_model` is null are
/// omitted so this list preserves the exact set of entries the previous
/// hand-maintained array exposed.
pub const default_model_per_provider: []const DefaultModelForProvider = blk: {
    const all = provider_info.PROVIDERS;
    var count: usize = 0;
    for (all) |entry| {
        if (entry.default_model != null) count += 1;
    }
    var result: [count]DefaultModelForProvider = undefined;
    var index: usize = 0;
    for (all) |entry| {
        if (entry.default_model) |default_model| {
            result[index] = .{ .provider = entry.id, .model = default_model };
            index += 1;
        }
    }
    const final = result;
    break :blk &final;
};

pub fn defaultModelForProvider(provider: []const u8) ?[]const u8 {
    return provider_info.defaultModelFor(provider);
}

test "model resolver facade exposes default provider models" {
    try std.testing.expectEqualStrings("gpt-5.4", defaultModelForProvider("openai").?);
}
