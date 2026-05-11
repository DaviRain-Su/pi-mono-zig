const common = @import("../../common.zig");
pub const descriptor = common.descriptor("custom-providers-store", "storage/stores/custom-providers-store.ts", .storage);

const std = @import("std");
const types = @import("../types.zig");

pub const STORE_NAME = "custom-providers";

pub const AutoDiscoveryProviderType = enum {
    ollama,
    llama_cpp,
    vllm,
    lmstudio,
};

pub const CustomProviderType = enum {
    ollama,
    llama_cpp,
    vllm,
    lmstudio,
    openai_completions,
    openai_responses,
    anthropic_messages,
};

pub const CustomProvider = struct {
    id: []const u8,
    name: []const u8,
    provider_type: CustomProviderType,
    base_url: []const u8,
    api_key: ?[]const u8 = null,
};

pub fn getConfig() types.StoreConfig {
    return .{ .name = STORE_NAME };
}

pub fn isAutoDiscoveryProvider(provider_type: CustomProviderType) bool {
    return switch (provider_type) {
        .ollama, .llama_cpp, .vllm, .lmstudio => true,
        else => false,
    };
}

pub fn parseProviderType(value: []const u8) ?CustomProviderType {
    if (std.mem.eql(u8, value, "ollama")) return .ollama;
    if (std.mem.eql(u8, value, "llama.cpp")) return .llama_cpp;
    if (std.mem.eql(u8, value, "vllm")) return .vllm;
    if (std.mem.eql(u8, value, "lmstudio")) return .lmstudio;
    if (std.mem.eql(u8, value, "openai-completions")) return .openai_completions;
    if (std.mem.eql(u8, value, "openai-responses")) return .openai_responses;
    if (std.mem.eql(u8, value, "anthropic-messages")) return .anthropic_messages;
    return null;
}

test "web-ui custom providers distinguish discovery and manual types" {
    try std.testing.expect(isAutoDiscoveryProvider(.ollama));
    try std.testing.expect(!isAutoDiscoveryProvider(.openai_completions));
    try std.testing.expectEqual(CustomProviderType.anthropic_messages, parseProviderType("anthropic-messages").?);
}
