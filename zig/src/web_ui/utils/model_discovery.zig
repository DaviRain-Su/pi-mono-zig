const common = @import("../common.zig");
pub const descriptor = common.descriptor("model-discovery", "utils/model-discovery.ts", .util);

const std = @import("std");

pub const DiscoveryType = enum {
    ollama,
    llama_cpp,
    vllm,
    lmstudio,
};

pub const DiscoveredModel = struct {
    id: []const u8,
    name: []const u8,
    api: []const u8 = "openai-completions",
    provider: []const u8 = "",
    base_url: []const u8,
    reasoning: bool = false,
    input_image: bool = false,
    context_window: u64 = 8192,
    max_tokens: u64 = 4096,
};

pub fn apiBaseUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    var end = base_url.len;
    while (end > 0 and base_url[end - 1] == '/') : (end -= 1) {}
    const trimmed = base_url[0..end];
    return std.fmt.allocPrint(allocator, "{s}/v1", .{trimmed});
}

pub fn fromOpenAiModel(allocator: std.mem.Allocator, model_id: []const u8, base_url: []const u8, context_window: ?u64, max_tokens: ?u64) !DiscoveredModel {
    return .{
        .id = model_id,
        .name = model_id,
        .base_url = try apiBaseUrl(allocator, base_url),
        .context_window = context_window orelse 8192,
        .max_tokens = max_tokens orelse 4096,
    };
}

pub fn fromVllmModel(allocator: std.mem.Allocator, model_id: []const u8, base_url: []const u8, max_model_len: ?u64) !DiscoveredModel {
    const context_window = max_model_len orelse 8192;
    return .{
        .id = model_id,
        .name = model_id,
        .base_url = try apiBaseUrl(allocator, base_url),
        .context_window = context_window,
        .max_tokens = @min(context_window, 4096),
    };
}

pub fn fromOllamaDetails(allocator: std.mem.Allocator, model_name: []const u8, base_url: []const u8, supports_tools: bool, supports_thinking: bool, context_window: ?u64) !?DiscoveredModel {
    if (!supports_tools) return null;
    const context = context_window orelse 8192;
    return .{
        .id = model_name,
        .name = model_name,
        .base_url = try apiBaseUrl(allocator, base_url),
        .reasoning = supports_thinking,
        .context_window = context,
        .max_tokens = context * 10,
    };
}

pub fn parseDiscoveryType(value: []const u8) ?DiscoveryType {
    if (std.mem.eql(u8, value, "ollama")) return .ollama;
    if (std.mem.eql(u8, value, "llama.cpp")) return .llama_cpp;
    if (std.mem.eql(u8, value, "vllm")) return .vllm;
    if (std.mem.eql(u8, value, "lmstudio")) return .lmstudio;
    return null;
}

test "web-ui model discovery maps OpenAI-compatible metadata" {
    const allocator = std.testing.allocator;
    const model = try fromVllmModel(allocator, "llama", "http://localhost:8000/", 16_384);
    defer allocator.free(model.base_url);
    try std.testing.expectEqualStrings("http://localhost:8000/v1", model.base_url);
    try std.testing.expectEqual(@as(u64, 4096), model.max_tokens);
}

test "web-ui Ollama discovery skips models without tool support" {
    const allocator = std.testing.allocator;
    const skipped = try fromOllamaDetails(allocator, "tiny", "http://localhost:11434", false, false, null);
    try std.testing.expectEqual(@as(?DiscoveredModel, null), skipped);
}
