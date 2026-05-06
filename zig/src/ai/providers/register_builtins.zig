const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const event_stream = @import("../event_stream.zig");

const anthropic = @import("anthropic.zig");
const azure_openai_responses = @import("azure_openai_responses.zig");
const bedrock = @import("bedrock.zig");
const google = @import("google.zig");
const google_gemini_cli = @import("google_gemini_cli.zig");
const google_vertex = @import("google_vertex.zig");
const kimi = @import("kimi.zig");
const mistral = @import("mistral.zig");
const openai = @import("openai.zig");
const openai_codex_responses = @import("openai_codex_responses.zig");
const openai_responses = @import("openai_responses.zig");

pub const StreamFunction = *const fn (
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) anyerror!event_stream.AssistantMessageEventStream;

pub const ProviderFns = struct {
    stream: StreamFunction,
    stream_simple: StreamFunction,
};

pub const BuiltInProvider = struct {
    api: types.Api,
    stream: StreamFunction,
    stream_simple: StreamFunction,
};

const DispatchMode = enum {
    stream,
    stream_simple,
};

const LazyProviderState = struct {
    provider: ?ProviderFns = null,
};

const ProviderMetadata = struct {
    api: types.Api,
    default_provider: ProviderFns,
};

const BuiltInProviderError = error{
    UnknownBuiltInApi,
    TestOnlyProviderOverrideUnavailable,
};

const PROVIDER_METADATA = [_]ProviderMetadata{
    .{
        .api = "anthropic-messages",
        .default_provider = .{
            .stream = anthropic.AnthropicProvider.stream,
            .stream_simple = anthropic.AnthropicProvider.streamSimple,
        },
    },
    .{
        .api = "openai-completions",
        .default_provider = .{
            .stream = openai.OpenAIProvider.stream,
            .stream_simple = openai.OpenAIProvider.streamSimple,
        },
    },
    .{
        .api = "kimi-completions",
        .default_provider = .{
            .stream = kimi.KimiProvider.stream,
            .stream_simple = kimi.KimiProvider.streamSimple,
        },
    },
    .{
        .api = "mistral-conversations",
        .default_provider = .{
            .stream = mistral.MistralProvider.stream,
            .stream_simple = mistral.MistralProvider.streamSimple,
        },
    },
    .{
        .api = "openai-responses",
        .default_provider = .{
            .stream = openai_responses.OpenAIResponsesProvider.stream,
            .stream_simple = openai_responses.OpenAIResponsesProvider.streamSimple,
        },
    },
    .{
        .api = "azure-openai-responses",
        .default_provider = .{
            .stream = azure_openai_responses.AzureOpenAIResponsesProvider.stream,
            .stream_simple = azure_openai_responses.AzureOpenAIResponsesProvider.streamSimple,
        },
    },
    .{
        .api = "openai-codex-responses",
        .default_provider = .{
            .stream = openai_codex_responses.OpenAICodexResponsesProvider.stream,
            .stream_simple = openai_codex_responses.OpenAICodexResponsesProvider.streamSimple,
        },
    },
    .{
        .api = "google-generative-ai",
        .default_provider = .{
            .stream = google.GoogleProvider.stream,
            .stream_simple = google.GoogleProvider.streamSimple,
        },
    },
    .{
        .api = "google-gemini-cli",
        .default_provider = .{
            .stream = google_gemini_cli.GoogleGeminiCliProvider.stream,
            .stream_simple = google_gemini_cli.GoogleGeminiCliProvider.streamSimple,
        },
    },
    .{
        .api = "google-vertex",
        .default_provider = .{
            .stream = google_vertex.GoogleVertexProvider.stream,
            .stream_simple = google_vertex.GoogleVertexProvider.streamSimple,
        },
    },
    .{
        .api = "bedrock-converse-stream",
        .default_provider = .{
            .stream = bedrock.BedrockProvider.stream,
            .stream_simple = bedrock.BedrockProvider.streamSimple,
        },
    },
};

var lazy_states = [_]LazyProviderState{.{}} ** PROVIDER_METADATA.len;
var test_overrides = [_]?ProviderFns{null} ** PROVIDER_METADATA.len;

const BUILT_IN_APIS = buildBuiltInApis();
const BUILT_IN_PROVIDERS = buildBuiltInProviders();

pub fn expectedBuiltInApis() []const types.Api {
    return BUILT_IN_APIS[0..];
}

pub fn expectedBuiltInApiCount() usize {
    return BUILT_IN_APIS.len;
}

pub fn builtInProviders() []const BuiltInProvider {
    return BUILT_IN_PROVIDERS[0..];
}

pub fn resetLazyState() void {
    lazy_states = [_]LazyProviderState{.{}} ** PROVIDER_METADATA.len;
}

pub fn clearProviderOverrides() void {
    if (builtin.is_test) {
        test_overrides = [_]?ProviderFns{null} ** PROVIDER_METADATA.len;
    }
    resetLazyState();
}

pub fn setProviderOverride(api: types.Api, provider: ProviderFns) BuiltInProviderError!void {
    if (!builtin.is_test) return BuiltInProviderError.TestOnlyProviderOverrideUnavailable;

    const index = providerIndexForApi(api) orelse return BuiltInProviderError.UnknownBuiltInApi;
    test_overrides[index] = provider;
    resetLazyState();
}

pub fn isLoaded(api: types.Api) bool {
    const index = providerIndexForApi(api) orelse return false;
    return lazy_states[index].provider != null;
}

fn buildBuiltInApis() [PROVIDER_METADATA.len]types.Api {
    var apis: [PROVIDER_METADATA.len]types.Api = undefined;
    inline for (PROVIDER_METADATA, 0..) |metadata, index| {
        apis[index] = metadata.api;
    }
    return apis;
}

fn buildBuiltInProviders() [PROVIDER_METADATA.len]BuiltInProvider {
    var providers: [PROVIDER_METADATA.len]BuiltInProvider = undefined;
    inline for (PROVIDER_METADATA, 0..) |metadata, index| {
        providers[index] = .{
            .api = metadata.api,
            .stream = streamWrapper(index, .stream),
            .stream_simple = streamWrapper(index, .stream_simple),
        };
    }
    return providers;
}

fn providerIndexForApi(api: types.Api) ?usize {
    for (PROVIDER_METADATA, 0..) |metadata, index| {
        if (std.mem.eql(u8, api, metadata.api)) return index;
    }
    return null;
}

fn streamWrapper(comptime index: usize, comptime mode: DispatchMode) StreamFunction {
    return struct {
        fn call(
            allocator: std.mem.Allocator,
            io: std.Io,
            model: types.Model,
            context: types.Context,
            options: ?types.StreamOptions,
        ) anyerror!event_stream.AssistantMessageEventStream {
            return dispatchLazy(index, mode, allocator, io, model, context, options);
        }
    }.call;
}

fn dispatchLazy(
    comptime index: usize,
    comptime mode: DispatchMode,
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    const state = &lazy_states[index];
    if (state.provider == null) {
        state.provider = loadProvider(index);
    }

    const provider = state.provider.?;
    return switch (mode) {
        .stream => try provider.stream(allocator, io, model, context, options),
        .stream_simple => try provider.stream_simple(allocator, io, model, context, options),
    };
}

fn loadProvider(comptime index: usize) ProviderFns {
    if (builtin.is_test) {
        if (test_overrides[index]) |provider| return provider;
    }
    return PROVIDER_METADATA[index].default_provider;
}

fn testOverrideForApi(api: types.Api) ?ProviderFns {
    const index = providerIndexForApi(api) orelse return null;
    return test_overrides[index];
}

fn dummyLazyStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    _: types.Context,
    _: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    _ = allocator;
    var stream_instance = event_stream.createAssistantMessageEventStream(std.heap.page_allocator, io);
    stream_instance.push(.{
        .event_type = .done,
        .message = .{
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "lazy provider response" } },
            },
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = types.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        },
    });
    return stream_instance;
}

fn buildSourceAssistantMessage(
    allocator: std.mem.Allocator,
    api: []const u8,
    provider: []const u8,
    model_id: []const u8,
) !types.AssistantMessage {
    var tool_arguments = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_arguments.put(allocator, try allocator.dupe(u8, "city"), .{ .string = try allocator.dupe(u8, "Berlin") });

    const tool_calls = try allocator.alloc(types.ToolCall, 1);
    tool_calls[0] = .{
        .id = "tool-1",
        .name = "get_weather",
        .arguments = .{ .object = tool_arguments },
    };

    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = "I will check the weather." } };

    return .{
        .content = content,
        .tool_calls = tool_calls,
        .api = api,
        .provider = provider,
        .model = model_id,
        .usage = types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 2,
    };
}

fn buildThinkingAssistantMessage(
    allocator: std.mem.Allocator,
    api: []const u8,
    provider: []const u8,
    model_id: []const u8,
) !types.AssistantMessage {
    const content = try allocator.alloc(types.ContentBlock, 2);
    content[0] = .{ .thinking = .{ .thinking = "Need to add the values first." } };
    content[1] = .{ .text = .{ .text = "The answer is 4." } };

    return .{
        .content = content,
        .api = api,
        .provider = provider,
        .model = model_id,
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 2,
    };
}

fn buildToolResultMessage(allocator: std.mem.Allocator) !types.ToolResultMessage {
    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = "Berlin is 17C and sunny." } };
    return .{
        .tool_call_id = "tool-1",
        .tool_name = "get_weather",
        .content = content,
        .timestamp = 3,
    };
}

fn buildToolHandoffContext(
    allocator: std.mem.Allocator,
    api: []const u8,
    provider: []const u8,
    model_id: []const u8,
) !types.Context {
    const messages = try allocator.alloc(types.Message, 4);
    const user_content = try allocator.alloc(types.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "What's the weather in Berlin?" } };

    const follow_up_content = try allocator.alloc(types.ContentBlock, 1);
    follow_up_content[0] = .{ .text = .{ .text = "It is 17C and sunny in Berlin." } };

    messages[0] = .{
        .user = .{
            .content = user_content,
            .timestamp = 1,
        },
    };
    messages[1] = .{ .assistant = try buildSourceAssistantMessage(allocator, api, provider, model_id) };
    messages[2] = .{ .tool_result = try buildToolResultMessage(allocator) };
    messages[3] = .{
        .assistant = .{
            .content = follow_up_content,
            .api = api,
            .provider = provider,
            .model = model_id,
            .usage = types.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 4,
        },
    };

    return .{
        .system_prompt = "You are a careful assistant.",
        .messages = messages,
    };
}

fn buildThinkingHandoffContext(
    allocator: std.mem.Allocator,
    api: []const u8,
    provider: []const u8,
    model_id: []const u8,
) !types.Context {
    const messages = try allocator.alloc(types.Message, 2);
    const user_content = try allocator.alloc(types.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "What is 2 + 2?" } };

    messages[0] = .{
        .user = .{
            .content = user_content,
            .timestamp = 1,
        },
    };
    messages[1] = .{ .assistant = try buildThinkingAssistantMessage(allocator, api, provider, model_id) };

    return .{
        .system_prompt = "Think step by step.",
        .messages = messages,
    };
}

fn testModelForApi(api: []const u8) types.Model {
    const text_input = &[_][]const u8{"text"};
    const text_and_image_input = &[_][]const u8{ "text", "image" };

    if (std.mem.eql(u8, api, "anthropic-messages")) {
        return .{
            .id = "claude-3-7-sonnet",
            .name = "Claude 3.7 Sonnet",
            .api = api,
            .provider = "anthropic",
            .base_url = "https://api.anthropic.com/v1",
            .reasoning = true,
            .input_types = text_and_image_input,
            .context_window = 200000,
            .max_tokens = 8192,
        };
    }

    if (std.mem.eql(u8, api, "mistral-conversations")) {
        return .{
            .id = "mistral-medium-latest",
            .name = "Mistral Medium",
            .api = api,
            .provider = "mistral",
            .base_url = "https://api.mistral.ai/v1",
            .reasoning = true,
            .input_types = text_and_image_input,
            .context_window = 131072,
            .max_tokens = 32768,
        };
    }

    if (std.mem.eql(u8, api, "openai-responses")) {
        return .{
            .id = "gpt-5-mini",
            .name = "GPT-5 Mini",
            .api = api,
            .provider = "openai",
            .base_url = "https://api.openai.com/v1",
            .reasoning = true,
            .input_types = text_and_image_input,
            .context_window = 200000,
            .max_tokens = 16384,
        };
    }

    if (std.mem.eql(u8, api, "azure-openai-responses")) {
        return .{
            .id = "gpt-5-mini",
            .name = "Azure GPT-5 Mini",
            .api = api,
            .provider = "azure-openai-responses",
            .base_url = "https://example.openai.azure.com/openai/v1",
            .reasoning = true,
            .input_types = text_and_image_input,
            .context_window = 200000,
            .max_tokens = 16384,
        };
    }

    if (std.mem.eql(u8, api, "openai-codex-responses")) {
        return .{
            .id = "codex-mini-latest",
            .name = "Codex Mini",
            .api = api,
            .provider = "openai-codex",
            .base_url = "https://chatgpt.com/backend-api",
            .reasoning = true,
            .input_types = text_input,
            .context_window = 200000,
            .max_tokens = 16384,
        };
    }

    if (std.mem.eql(u8, api, "google-generative-ai")) {
        return .{
            .id = "gemini-2.5-pro",
            .name = "Gemini 2.5 Pro",
            .api = api,
            .provider = "google",
            .base_url = "https://generativelanguage.googleapis.com/v1beta",
            .reasoning = true,
            .input_types = text_and_image_input,
            .context_window = 1048576,
            .max_tokens = 65536,
        };
    }

    if (std.mem.eql(u8, api, "google-gemini-cli")) {
        return .{
            .id = "gemini-cli-pro",
            .name = "Gemini CLI Pro",
            .api = api,
            .provider = "google-gemini-cli",
            .base_url = "https://cloudcode-pa.googleapis.com",
            .reasoning = true,
            .input_types = text_and_image_input,
            .context_window = 1048576,
            .max_tokens = 65536,
        };
    }

    if (std.mem.eql(u8, api, "google-vertex")) {
        return .{
            .id = "gemini-2.5-pro",
            .name = "Vertex Gemini 2.5 Pro",
            .api = api,
            .provider = "google-vertex",
            .base_url = "https://us-central1-aiplatform.googleapis.com/v1/projects/test/locations/us-central1/publishers/google",
            .reasoning = true,
            .input_types = text_and_image_input,
            .context_window = 1048576,
            .max_tokens = 65536,
        };
    }

    if (std.mem.eql(u8, api, "bedrock-converse-stream")) {
        return .{
            .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
            .name = "Bedrock Claude 3.7 Sonnet",
            .api = api,
            .provider = "amazon-bedrock",
            .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
            .reasoning = true,
            .input_types = text_and_image_input,
            .context_window = 200000,
            .max_tokens = 8192,
        };
    }

    return .{
        .id = "gpt-4.1-mini",
        .name = "GPT-4.1 Mini",
        .api = api,
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = text_and_image_input,
        .context_window = 128000,
        .max_tokens = 16384,
    };
}

fn expectJsonArrayField(value: std.json.Value, field: []const u8) !void {
    const array_value = value.object.get(field) orelse return error.MissingField;
    try std.testing.expect(array_value == .array);
    try std.testing.expect(array_value.array.items.len > 0);
}

fn validateHandoffPayload(allocator: std.mem.Allocator, model: types.Model, context: types.Context) !void {
    if (std.mem.eql(u8, model.api, "anthropic-messages") or std.mem.eql(u8, model.api, "bedrock-converse-stream")) {
        const payload = try anthropic.buildRequestPayload(allocator, model, context, null);
        try expectJsonArrayField(payload, "messages");
        return;
    }

    if (std.mem.eql(u8, model.api, "google-generative-ai") or
        std.mem.eql(u8, model.api, "google-vertex"))
    {
        const payload = try google.buildRequestPayload(allocator, model, context, null);
        try expectJsonArrayField(payload, "contents");
        return;
    }

    if (std.mem.eql(u8, model.api, "google-gemini-cli")) {
        const payload = try google_gemini_cli.buildRequestPayload(allocator, model, context, "project-1", null);
        const request = payload.object.get("request") orelse return error.MissingField;
        try std.testing.expect(request == .object);
        try expectJsonArrayField(request, "contents");
        return;
    }

    if (std.mem.eql(u8, model.api, "mistral-conversations")) {
        const payload = try mistral.buildRequestPayload(allocator, model, context, null);
        try expectJsonArrayField(payload, "messages");
        return;
    }

    const payload = try openai.buildRequestPayload(allocator, model, context, null);
    try expectJsonArrayField(payload, "messages");
}

test "built-in api list matches TypeScript registry count" {
    try std.testing.expectEqual(@as(usize, 11), expectedBuiltInApiCount());
    try std.testing.expectEqual(expectedBuiltInApiCount(), expectedBuiltInApis().len);

    const expected_order = [_][]const u8{
        "anthropic-messages",
        "openai-completions",
        "kimi-completions",
        "mistral-conversations",
        "openai-responses",
        "azure-openai-responses",
        "openai-codex-responses",
        "google-generative-ai",
        "google-gemini-cli",
        "google-vertex",
        "bedrock-converse-stream",
    };
    try std.testing.expectEqual(expected_order.len, expectedBuiltInApiCount());
    for (expectedBuiltInApis(), 0..) |api, index| {
        try std.testing.expectEqualStrings(expected_order[index], api);
        try std.testing.expectEqualStrings(api, builtInProviders()[index].api);
        for (expectedBuiltInApis()[0..index]) |prior_api| {
            try std.testing.expect(!std.mem.eql(u8, api, prior_api));
        }
    }
}

test "lazy wrapper loads provider on first stream call" {
    clearProviderOverrides();
    defer clearProviderOverrides();

    try setProviderOverride("openai-completions", .{
        .stream = dummyLazyStream,
        .stream_simple = dummyLazyStream,
    });

    try std.testing.expect(!isLoaded("openai-completions"));

    const model = testModelForApi("openai-completions");
    const provider = builtInProviders()[providerIndexForApi("openai-completions").?];
    var stream_instance = try provider.stream(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        null,
    );
    defer stream_instance.deinit();

    while (stream_instance.next()) |_| {}

    try std.testing.expect(isLoaded("openai-completions"));
    const result = stream_instance.result().?;
    try std.testing.expectEqualStrings("lazy provider response", result.content[0].text.text);
    try std.testing.expect(!isLoaded("anthropic-messages"));
}

test "provider override fixture clears between same-process uses" {
    clearProviderOverrides();
    defer clearProviderOverrides();

    try setProviderOverride("openai-completions", .{
        .stream = dummyLazyStream,
        .stream_simple = dummyLazyStream,
    });
    try std.testing.expect(testOverrideForApi("openai-completions") != null);
    try std.testing.expect(testOverrideForApi("kimi-completions") == null);

    clearProviderOverrides();
    try std.testing.expect(testOverrideForApi("openai-completions") == null);
    try std.testing.expect(!isLoaded("openai-completions"));

    try setProviderOverride("kimi-completions", .{
        .stream = dummyLazyStream,
        .stream_simple = dummyLazyStream,
    });
    try std.testing.expect(testOverrideForApi("openai-completions") == null);
    try std.testing.expect(testOverrideForApi("kimi-completions") != null);
}

test "metadata dispatch wrappers cover every built-in provider" {
    clearProviderOverrides();
    defer clearProviderOverrides();

    for (builtInProviders()) |provider| {
        try setProviderOverride(provider.api, .{
            .stream = dummyLazyStream,
            .stream_simple = dummyLazyStream,
        });
        try std.testing.expect(!isLoaded(provider.api));

        const model = testModelForApi(provider.api);
        var stream_instance = try provider.stream(
            std.testing.allocator,
            std.Io.failing,
            model,
            .{ .messages = &[_]types.Message{} },
            null,
        );
        defer stream_instance.deinit();
        while (stream_instance.next()) |_| {}
        try std.testing.expect(isLoaded(provider.api));
        const result = stream_instance.result().?;
        try std.testing.expectEqualStrings("lazy provider response", result.content[0].text.text);

        resetLazyState();
        try std.testing.expect(!isLoaded(provider.api));
        var simple_stream_instance = try provider.stream_simple(
            std.testing.allocator,
            std.Io.failing,
            model,
            .{ .messages = &[_]types.Message{} },
            null,
        );
        defer simple_stream_instance.deinit();
        while (simple_stream_instance.next()) |_| {}
        try std.testing.expect(isLoaded(provider.api));
        const simple_result = simple_stream_instance.result().?;
        try std.testing.expectEqualStrings("lazy provider response", simple_result.content[0].text.text);
    }
}

test "cross-provider handoff payload builders accept tool and thinking contexts" {
    const source_specs = [_]struct {
        api: []const u8,
        provider: []const u8,
        model_id: []const u8,
    }{
        .{ .api = "openai-completions", .provider = "openai", .model_id = "gpt-4.1-mini" },
        .{ .api = "anthropic-messages", .provider = "anthropic", .model_id = "claude-3-7-sonnet" },
        .{ .api = "google-generative-ai", .provider = "google", .model_id = "gemini-2.5-pro" },
        .{ .api = "mistral-conversations", .provider = "mistral", .model_id = "mistral-medium-latest" },
    };

    for (source_specs) |source| {
        for (expectedBuiltInApis()) |target_api| {
            {
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const allocator = arena.allocator();

                const context = try buildToolHandoffContext(allocator, source.api, source.provider, source.model_id);
                try validateHandoffPayload(allocator, testModelForApi(target_api), context);
            }

            {
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const allocator = arena.allocator();

                const context = try buildThinkingHandoffContext(allocator, source.api, source.provider, source.model_id);
                try validateHandoffPayload(allocator, testModelForApi(target_api), context);
            }
        }
    }
}
