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

const BuiltInProviderError = error{
    UnknownBuiltInApi,
    TestOnlyProviderOverrideUnavailable,
};

var openai_state = LazyProviderState{};
var kimi_state = LazyProviderState{};
var anthropic_state = LazyProviderState{};
var mistral_state = LazyProviderState{};
var openai_responses_state = LazyProviderState{};
var azure_openai_responses_state = LazyProviderState{};
var openai_codex_responses_state = LazyProviderState{};
var google_state = LazyProviderState{};
var google_gemini_cli_state = LazyProviderState{};
var google_vertex_state = LazyProviderState{};
var bedrock_state = LazyProviderState{};

const Overrides = struct {
    openai: ?ProviderFns = null,
    kimi: ?ProviderFns = null,
    anthropic: ?ProviderFns = null,
    mistral: ?ProviderFns = null,
    openai_responses: ?ProviderFns = null,
    azure_openai_responses: ?ProviderFns = null,
    openai_codex_responses: ?ProviderFns = null,
    google: ?ProviderFns = null,
    google_gemini_cli: ?ProviderFns = null,
    google_vertex: ?ProviderFns = null,
    bedrock: ?ProviderFns = null,
};

var test_overrides = Overrides{};

const BUILT_IN_APIS = [_]types.Api{
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

const BUILT_IN_PROVIDERS = [_]BuiltInProvider{
    .{
        .api = "anthropic-messages",
        .stream = streamAnthropic,
        .stream_simple = streamSimpleAnthropic,
    },
    .{
        .api = "openai-completions",
        .stream = streamOpenAI,
        .stream_simple = streamSimpleOpenAI,
    },
    .{
        .api = "kimi-completions",
        .stream = streamKimi,
        .stream_simple = streamSimpleKimi,
    },
    .{
        .api = "mistral-conversations",
        .stream = streamMistral,
        .stream_simple = streamSimpleMistral,
    },
    .{
        .api = "openai-responses",
        .stream = streamOpenAIResponses,
        .stream_simple = streamSimpleOpenAIResponses,
    },
    .{
        .api = "azure-openai-responses",
        .stream = streamAzureOpenAIResponses,
        .stream_simple = streamSimpleAzureOpenAIResponses,
    },
    .{
        .api = "openai-codex-responses",
        .stream = streamOpenAICodexResponses,
        .stream_simple = streamSimpleOpenAICodexResponses,
    },
    .{
        .api = "google-generative-ai",
        .stream = streamGoogle,
        .stream_simple = streamSimpleGoogle,
    },
    .{
        .api = "google-gemini-cli",
        .stream = streamGoogleGeminiCli,
        .stream_simple = streamSimpleGoogleGeminiCli,
    },
    .{
        .api = "google-vertex",
        .stream = streamGoogleVertex,
        .stream_simple = streamSimpleGoogleVertex,
    },
    .{
        .api = "bedrock-converse-stream",
        .stream = streamBedrock,
        .stream_simple = streamSimpleBedrock,
    },
};

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
    openai_state = .{};
    kimi_state = .{};
    anthropic_state = .{};
    mistral_state = .{};
    openai_responses_state = .{};
    azure_openai_responses_state = .{};
    openai_codex_responses_state = .{};
    google_state = .{};
    google_gemini_cli_state = .{};
    google_vertex_state = .{};
    bedrock_state = .{};
}

pub fn clearProviderOverrides() void {
    if (builtin.is_test) {
        test_overrides = .{};
    }
    resetLazyState();
}

pub fn setProviderOverride(api: types.Api, provider: ProviderFns) BuiltInProviderError!void {
    if (!builtin.is_test) return BuiltInProviderError.TestOnlyProviderOverrideUnavailable;

    if (std.mem.eql(u8, api, "openai-completions")) {
        test_overrides.openai = provider;
    } else if (std.mem.eql(u8, api, "kimi-completions")) {
        test_overrides.kimi = provider;
    } else if (std.mem.eql(u8, api, "anthropic-messages")) {
        test_overrides.anthropic = provider;
    } else if (std.mem.eql(u8, api, "mistral-conversations")) {
        test_overrides.mistral = provider;
    } else if (std.mem.eql(u8, api, "openai-responses")) {
        test_overrides.openai_responses = provider;
    } else if (std.mem.eql(u8, api, "azure-openai-responses")) {
        test_overrides.azure_openai_responses = provider;
    } else if (std.mem.eql(u8, api, "openai-codex-responses")) {
        test_overrides.openai_codex_responses = provider;
    } else if (std.mem.eql(u8, api, "google-generative-ai")) {
        test_overrides.google = provider;
    } else if (std.mem.eql(u8, api, "google-gemini-cli")) {
        test_overrides.google_gemini_cli = provider;
    } else if (std.mem.eql(u8, api, "google-vertex")) {
        test_overrides.google_vertex = provider;
    } else if (std.mem.eql(u8, api, "bedrock-converse-stream")) {
        test_overrides.bedrock = provider;
    } else {
        return BuiltInProviderError.UnknownBuiltInApi;
    }
    resetLazyState();
}

pub fn isLoaded(api: types.Api) bool {
    if (std.mem.eql(u8, api, "openai-completions")) return openai_state.provider != null;
    if (std.mem.eql(u8, api, "kimi-completions")) return kimi_state.provider != null;
    if (std.mem.eql(u8, api, "anthropic-messages")) return anthropic_state.provider != null;
    if (std.mem.eql(u8, api, "mistral-conversations")) return mistral_state.provider != null;
    if (std.mem.eql(u8, api, "openai-responses")) return openai_responses_state.provider != null;
    if (std.mem.eql(u8, api, "azure-openai-responses")) return azure_openai_responses_state.provider != null;
    if (std.mem.eql(u8, api, "openai-codex-responses")) return openai_codex_responses_state.provider != null;
    if (std.mem.eql(u8, api, "google-generative-ai")) return google_state.provider != null;
    if (std.mem.eql(u8, api, "google-gemini-cli")) return google_gemini_cli_state.provider != null;
    if (std.mem.eql(u8, api, "google-vertex")) return google_vertex_state.provider != null;
    if (std.mem.eql(u8, api, "bedrock-converse-stream")) return bedrock_state.provider != null;
    return false;
}

fn dispatchLazy(
    state: *LazyProviderState,
    loader: *const fn () ProviderFns,
    mode: DispatchMode,
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    if (state.provider == null) {
        state.provider = loader();
    }

    const provider = state.provider.?;
    return switch (mode) {
        .stream => try provider.stream(allocator, io, model, context, options),
        .stream_simple => try provider.stream_simple(allocator, io, model, context, options),
    };
}

fn loadOpenAIProvider() ProviderFns {
    return (if (builtin.is_test) test_overrides.openai else null) orelse .{
        .stream = openai.OpenAIProvider.stream,
        .stream_simple = openai.OpenAIProvider.streamSimple,
    };
}

fn loadKimiProvider() ProviderFns {
    return (if (builtin.is_test) test_overrides.kimi else null) orelse .{
        .stream = kimi.KimiProvider.stream,
        .stream_simple = kimi.KimiProvider.streamSimple,
    };
}

fn loadAnthropicProvider() ProviderFns {
    return (if (builtin.is_test) test_overrides.anthropic else null) orelse .{
        .stream = anthropic.AnthropicProvider.stream,
        .stream_simple = anthropic.AnthropicProvider.streamSimple,
    };
}

fn loadMistralProvider() ProviderFns {
    return (if (builtin.is_test) test_overrides.mistral else null) orelse .{
        .stream = mistral.MistralProvider.stream,
        .stream_simple = mistral.MistralProvider.streamSimple,
    };
}

fn loadOpenAIResponsesProvider() ProviderFns {
    return (if (builtin.is_test) test_overrides.openai_responses else null) orelse .{
        .stream = openai_responses.OpenAIResponsesProvider.stream,
        .stream_simple = openai_responses.OpenAIResponsesProvider.streamSimple,
    };
}

fn loadAzureOpenAIResponsesProvider() ProviderFns {
    return (if (builtin.is_test) test_overrides.azure_openai_responses else null) orelse .{
        .stream = azure_openai_responses.AzureOpenAIResponsesProvider.stream,
        .stream_simple = azure_openai_responses.AzureOpenAIResponsesProvider.streamSimple,
    };
}

fn loadOpenAICodexResponsesProvider() ProviderFns {
    return (if (builtin.is_test) test_overrides.openai_codex_responses else null) orelse .{
        .stream = openai_codex_responses.OpenAICodexResponsesProvider.stream,
        .stream_simple = openai_codex_responses.OpenAICodexResponsesProvider.streamSimple,
    };
}

fn loadGoogleProvider() ProviderFns {
    return (if (builtin.is_test) test_overrides.google else null) orelse .{
        .stream = google.GoogleProvider.stream,
        .stream_simple = google.GoogleProvider.streamSimple,
    };
}

fn loadGoogleGeminiCliProvider() ProviderFns {
    return (if (builtin.is_test) test_overrides.google_gemini_cli else null) orelse .{
        .stream = google_gemini_cli.GoogleGeminiCliProvider.stream,
        .stream_simple = google_gemini_cli.GoogleGeminiCliProvider.streamSimple,
    };
}

fn loadGoogleVertexProvider() ProviderFns {
    return (if (builtin.is_test) test_overrides.google_vertex else null) orelse .{
        .stream = google_vertex.GoogleVertexProvider.stream,
        .stream_simple = google_vertex.GoogleVertexProvider.streamSimple,
    };
}

fn loadBedrockProvider() ProviderFns {
    return (if (builtin.is_test) test_overrides.bedrock else null) orelse .{
        .stream = bedrock.BedrockProvider.stream,
        .stream_simple = bedrock.BedrockProvider.streamSimple,
    };
}

fn streamOpenAI(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&openai_state, loadOpenAIProvider, .stream, allocator, io, model, context, options);
}

fn streamSimpleOpenAI(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&openai_state, loadOpenAIProvider, .stream_simple, allocator, io, model, context, options);
}

fn streamKimi(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&kimi_state, loadKimiProvider, .stream, allocator, io, model, context, options);
}

fn streamSimpleKimi(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&kimi_state, loadKimiProvider, .stream_simple, allocator, io, model, context, options);
}

fn streamAnthropic(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&anthropic_state, loadAnthropicProvider, .stream, allocator, io, model, context, options);
}

fn streamSimpleAnthropic(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&anthropic_state, loadAnthropicProvider, .stream_simple, allocator, io, model, context, options);
}

fn streamMistral(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&mistral_state, loadMistralProvider, .stream, allocator, io, model, context, options);
}

fn streamSimpleMistral(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&mistral_state, loadMistralProvider, .stream_simple, allocator, io, model, context, options);
}

fn streamOpenAIResponses(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&openai_responses_state, loadOpenAIResponsesProvider, .stream, allocator, io, model, context, options);
}

fn streamSimpleOpenAIResponses(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&openai_responses_state, loadOpenAIResponsesProvider, .stream_simple, allocator, io, model, context, options);
}

fn streamAzureOpenAIResponses(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&azure_openai_responses_state, loadAzureOpenAIResponsesProvider, .stream, allocator, io, model, context, options);
}

fn streamSimpleAzureOpenAIResponses(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&azure_openai_responses_state, loadAzureOpenAIResponsesProvider, .stream_simple, allocator, io, model, context, options);
}

fn streamOpenAICodexResponses(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&openai_codex_responses_state, loadOpenAICodexResponsesProvider, .stream, allocator, io, model, context, options);
}

fn streamSimpleOpenAICodexResponses(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&openai_codex_responses_state, loadOpenAICodexResponsesProvider, .stream_simple, allocator, io, model, context, options);
}

fn streamGoogle(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&google_state, loadGoogleProvider, .stream, allocator, io, model, context, options);
}

fn streamSimpleGoogle(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&google_state, loadGoogleProvider, .stream_simple, allocator, io, model, context, options);
}

fn streamGoogleGeminiCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&google_gemini_cli_state, loadGoogleGeminiCliProvider, .stream, allocator, io, model, context, options);
}

fn streamSimpleGoogleGeminiCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&google_gemini_cli_state, loadGoogleGeminiCliProvider, .stream_simple, allocator, io, model, context, options);
}

fn streamGoogleVertex(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&google_vertex_state, loadGoogleVertexProvider, .stream, allocator, io, model, context, options);
}

fn streamSimpleGoogleVertex(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&google_vertex_state, loadGoogleVertexProvider, .stream_simple, allocator, io, model, context, options);
}

fn streamBedrock(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&bedrock_state, loadBedrockProvider, .stream, allocator, io, model, context, options);
}

fn streamSimpleBedrock(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return try dispatchLazy(&bedrock_state, loadBedrockProvider, .stream_simple, allocator, io, model, context, options);
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
    var stream_instance = try streamOpenAI(
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
    try std.testing.expect(test_overrides.openai != null);
    try std.testing.expect(test_overrides.kimi == null);

    clearProviderOverrides();
    try std.testing.expect(test_overrides.openai == null);
    try std.testing.expect(!isLoaded("openai-completions"));

    try setProviderOverride("kimi-completions", .{
        .stream = dummyLazyStream,
        .stream_simple = dummyLazyStream,
    });
    try std.testing.expect(test_overrides.openai == null);
    try std.testing.expect(test_overrides.kimi != null);
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
