const std = @import("std");

/// Known API identifiers
pub const KnownApi = enum {
    openai_completions,
    mistral_conversations,
    openai_responses,
    azure_openai_responses,
    openai_codex_responses,
    anthropic_messages,
    bedrock_converse_stream,
    google_generative_ai,
    google_gemini_cli,
    google_vertex,
    faux,
};

/// Known provider names
pub const KnownProvider = enum {
    amazon_bedrock,
    anthropic,
    google,
    google_gemini_cli,
    google_antigravity,
    google_vertex,
    openai,
    azure_openai_responses,
    openai_codex,
    deepseek,
    github_copilot,
    xai,
    groq,
    cerebras,
    openrouter,
    vercel_ai_gateway,
    zai,
    mistral,
    minimax,
    minimax_cn,
    huggingface,
    fireworks,
    opencode,
    opencode_go,
    kimi_coding,
    faux,
};

pub const Api = []const u8;
pub const Provider = []const u8;

pub const ThinkingLevel = enum {
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const AnthropicEffort = enum {
    low,
    medium,
    high,
    xhigh,
    max,
};

pub const AnthropicThinkingDisplay = enum {
    summarized,
    omitted,
};

pub const ThinkingBudgets = struct {
    minimal: u32 = 1024,
    low: u32 = 2048,
    medium: u32 = 8192,
    high: u32 = 16384,
};

pub const AnthropicToolChoice = union(enum) {
    auto,
    any,
    none,
    tool: []const u8,
};

pub const BedrockToolChoice = union(enum) {
    auto,
    any,
    none,
    tool: []const u8,
};

pub const CacheRetention = enum {
    unset,
    none,
    short,
    long,
};

pub const Transport = enum {
    sse,
    websocket,
    websocket_cached,
    auto,
};

pub const StopReason = enum {
    stop,
    length,
    tool_use,
    error_reason,
    aborted,
};

pub const UsageCost = struct {
    input: f64 = 0,
    output: f64 = 0,
    cache_read: f64 = 0,
    cache_write: f64 = 0,
    total: f64 = 0,

    pub fn init() UsageCost {
        return .{};
    }
};

pub const Usage = struct {
    input: u32 = 0,
    output: u32 = 0,
    cache_read: u32 = 0,
    cache_write: u32 = 0,
    total_tokens: u32 = 0,
    cost: UsageCost = .{},

    pub fn init() Usage {
        return .{};
    }
};

pub const TextContent = struct {
    text: []const u8,
    text_signature: ?[]const u8 = null,
};

pub const ImageContent = struct {
    data: []const u8, // base64
    mime_type: []const u8,
};

pub const ThinkingContent = struct {
    thinking: []const u8,
    thinking_signature: ?[]const u8 = null,
    /// Legacy field name kept for stored-session/provider compatibility during
    /// the ordered assistant content migration. Prefer `thinking_signature` for
    /// new code.
    signature: ?[]const u8 = null,
    redacted: bool = false,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.Value,
    thought_signature: ?[]const u8 = null,
};

pub const ContentBlock = union(enum) {
    text: TextContent,
    image: ImageContent,
    thinking: ThinkingContent,
    tool_call: ToolCall,
};

pub fn textSignature(text: TextContent) ?[]const u8 {
    return text.text_signature;
}

pub fn thinkingSignature(thinking: ThinkingContent) ?[]const u8 {
    return thinking.thinking_signature orelse thinking.signature;
}

pub const UserMessage = struct {
    role: []const u8 = "user",
    content: []const ContentBlock,
    timestamp: i64,
};

pub const AssistantMessage = struct {
    role: []const u8 = "assistant",
    content: []const ContentBlock,
    /// TypeScript stores tool-call blocks inline in `content`.
    /// Zig keeps finalized tool calls here as an owned cache because provider and
    /// transform layers frequently need direct access after streaming assembly.
    /// This is an intentional representation deviation; helper code is responsible
    /// for preserving TypeScript-equivalent behavior at API boundaries.
    tool_calls: ?[]const ToolCall = null,
    api: Api,
    provider: Provider,
    model: []const u8,
    response_id: ?[]const u8 = null,
    /// Concrete `chunk.model` when different from the requested `model`
    /// (e.g. OpenRouter `auto` -> `anthropic/...`). Equivalent to
    /// TypeScript `AssistantMessage.responseModel`.
    response_model: ?[]const u8 = null,
    usage: Usage,
    stop_reason: StopReason,
    error_message: ?[]const u8 = null,
    timestamp: i64,
};

pub fn countInlineToolCalls(assistant: AssistantMessage) usize {
    var count: usize = 0;
    for (assistant.content) |block| {
        if (block == .tool_call) count += 1;
    }
    return count;
}

pub fn hasInlineToolCalls(assistant: AssistantMessage) bool {
    return countInlineToolCalls(assistant) > 0;
}

pub fn shouldReplayAssistantInProviderContext(assistant: AssistantMessage) bool {
    return assistant.stop_reason != .error_reason and assistant.stop_reason != .aborted;
}

/// Collects executable tool calls with inline ordered content as source of
/// truth. The returned slice is an owned array of borrowed ToolCall values; free
/// only the slice, not the tool-call fields.
pub fn collectAssistantToolCalls(
    allocator: std.mem.Allocator,
    assistant: AssistantMessage,
) ![]const ToolCall {
    const inline_count = countInlineToolCalls(assistant);
    if (inline_count > 0) {
        var calls = try allocator.alloc(ToolCall, inline_count);
        var index: usize = 0;
        for (assistant.content) |block| {
            if (block == .tool_call) {
                calls[index] = block.tool_call;
                index += 1;
            }
        }
        return calls;
    }

    const legacy = assistant.tool_calls orelse return try allocator.alloc(ToolCall, 0);
    const calls = try allocator.alloc(ToolCall, legacy.len);
    @memcpy(calls, legacy);
    return calls;
}

pub const ToolResultMessage = struct {
    role: []const u8 = "toolResult",
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const ContentBlock,
    details: ?std.json.Value = null,
    is_error: bool = false,
    timestamp: i64,
};

pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

pub const Context = struct {
    system_prompt: ?[]const u8 = null,
    messages: []const Message,
    tools: ?[]const Tool = null,
};

pub const ModelCost = struct {
    input: f64 = 0, // $/million tokens
    output: f64 = 0, // $/million tokens
    cache_read: f64 = 0, // $/million tokens
    cache_write: f64 = 0, // $/million tokens

    pub fn init() ModelCost {
        return .{};
    }
};

pub const OpenAICompletionsCompat = struct {
    supports_store: ?bool = null,
    supports_developer_role: ?bool = null,
    supports_reasoning_effort: ?bool = null,
    reasoning_effort_map: ?std.StringHashMap([]const u8) = null,
    supports_usage_in_streaming: bool = true,
    max_tokens_field: ?[]const u8 = null, // "max_completion_tokens" or "max_tokens"
    requires_tool_result_name: ?bool = null,
    requires_assistant_after_tool_result: ?bool = null,
    requires_thinking_as_text: ?bool = null,
    requires_reasoning_content_on_assistant_messages: ?bool = null,
    thinking_format: ?[]const u8 = null, // "openai", "openrouter", "deepseek", "zai", "qwen", "qwen-chat-template"
    open_router_routing: ?OpenRouterRouting = null,
    vercel_gateway_routing: ?VercelGatewayRouting = null,
    zai_tool_stream: bool = false,
    supports_strict_mode: bool = true,
    cache_control_format: ?[]const u8 = null, // "anthropic"
    send_session_affinity_headers: bool = false,
    supports_long_cache_retention: ?bool = null,
};

pub const OpenAIResponsesCompat = struct {
    send_session_id_header: ?bool = null,
    supports_long_cache_retention: ?bool = null,
};

pub const AnthropicMessagesCompat = struct {
    supports_eager_tool_input_streaming: ?bool = null,
    supports_long_cache_retention: ?bool = null,
};

pub const OpenRouterRouting = struct {
    allow_fallbacks: ?bool = null,
    require_parameters: ?bool = null,
    data_collection: ?[]const u8 = null, // "deny" or "allow"
    zdr: ?bool = null,
    enforce_distillable_text: ?bool = null,
    order: ?[]const []const u8 = null,
    only: ?[]const []const u8 = null,
    ignore: ?[]const []const u8 = null,
    quantizations: ?[]const []const u8 = null,
    sort: ?[]const u8 = null,
    max_price: ?std.json.Value = null,
    preferred_min_throughput: ?std.json.Value = null,
    preferred_max_latency: ?std.json.Value = null,
};

pub const VercelGatewayRouting = struct {
    only: ?[]const []const u8 = null,
    order: ?[]const []const u8 = null,
};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    api: Api,
    provider: Provider,
    base_url: []const u8,
    reasoning: bool = false,
    tool_calling: bool = true,
    loaded: bool = false,
    input_types: []const []const u8, // "text", "image"
    cost: ModelCost = .{},
    context_window: u32,
    max_tokens: u32,
    headers: ?std.StringHashMap([]const u8) = null,
    compat: ?std.json.Value = null, // OpenAICompletionsCompat or OpenAIResponsesCompat
};

pub const GoogleThinkingOptions = struct {
    enabled: bool = false,
    budget_tokens: ?u32 = null,
    level: ?[]const u8 = null,
};

pub const StreamOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    transport: Transport = .auto,
    cache_retention: CacheRetention = .unset,
    session_id: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,
    /// Optional callback for inspecting or replacing provider payloads before sending.
    /// HTTP request timeout in milliseconds for providers/clients that support it.
    timeout_ms: ?u32 = null,
    /// Maximum retry attempts for providers/clients that support client-side retries.
    max_retries: ?u32 = null,
    /// In Zig, this is a function pointer taking allocator, payload json.Value, model, and returning an optional modified payload.
    on_payload: ?*const fn (std.mem.Allocator, std.json.Value, Model) anyerror!?std.json.Value = null,
    /// Optional callback invoked after an HTTP response is received and before its body stream is consumed.
    on_response: ?*const fn (u16, std.StringHashMap([]const u8), Model) anyerror!void = null,
    /// Optional abort signal checked during streaming.
    signal: ?*const std.atomic.Value(bool) = null,
    /// Maximum delay in milliseconds to wait for a retry when the server requests a long wait.
    /// Default: 60000 (60 seconds). Set to 0 to disable the cap.
    max_retry_delay_ms: u32 = 60000,
    /// Optional metadata to include in API requests.
    metadata: ?std.json.Value = null,
    /// Bedrock Converse region override.
    bedrock_region: ?[]const u8 = null,
    /// Bedrock Converse profile override.
    bedrock_profile: ?[]const u8 = null,
    /// Bedrock Converse bearer token override.
    bedrock_bearer_token: ?[]const u8 = null,
    /// Bedrock Converse tool choice override.
    bedrock_tool_choice: ?BedrockToolChoice = null,
    /// Bedrock Converse reasoning level.
    bedrock_reasoning: ?ThinkingLevel = null,
    /// Bedrock Converse custom thinking budgets.
    bedrock_thinking_budgets: ?ThinkingBudgets = null,
    /// Bedrock Converse interleaved thinking beta toggle.
    bedrock_interleaved_thinking: ?bool = null,
    /// Bedrock Converse thinking display mode.
    bedrock_thinking_display: ?AnthropicThinkingDisplay = null,
    /// Bedrock Converse request metadata.
    bedrock_request_metadata: ?std.json.Value = null,
    /// Google provider tool choice: "auto", "none", or "any".
    google_tool_choice: ?[]const u8 = null,
    /// Google provider thinking configuration.
    google_thinking: ?GoogleThinkingOptions = null,
    /// OpenAI Chat Completions tool_choice override.
    openai_tool_choice: ?std.json.Value = null,
    /// OpenAI Chat Completions reasoning effort level.
    openai_reasoning_effort: ?[]const u8 = null,
    /// Anthropic provider extended thinking enabled/disabled override.
    anthropic_thinking_enabled: ?bool = null,
    /// Anthropic provider token budget for non-adaptive thinking models.
    anthropic_thinking_budget_tokens: ?u32 = null,
    /// Anthropic provider thinking display mode.
    anthropic_thinking_display: ?AnthropicThinkingDisplay = null,
    /// Anthropic provider adaptive thinking effort.
    anthropic_effort: ?AnthropicEffort = null,
    /// Anthropic provider interleaved thinking beta toggle.
    anthropic_interleaved_thinking: ?bool = null,
    /// Anthropic provider tool choice override.
    anthropic_tool_choice: ?AnthropicToolChoice = null,
    /// Responses API reasoning effort level.
    responses_reasoning_effort: ?ThinkingLevel = null,
    /// Responses API reasoning summary level. OpenAI Responses currently accepts values such as "auto", "concise", and "detailed".
    responses_reasoning_summary: ?[]const u8 = null,
    /// Responses API service tier forwarded as service_tier.
    responses_service_tier: ?[]const u8 = null,
    /// OpenAI Codex Responses text verbosity forwarded as text.verbosity.
    responses_text_verbosity: ?[]const u8 = null,
    /// Azure OpenAI Responses API version override forwarded as api-version.
    azure_api_version: ?[]const u8 = null,
    /// Azure OpenAI resource name override used to build the default Azure base URL.
    azure_resource_name: ?[]const u8 = null,
    /// Azure OpenAI base URL override.
    azure_base_url: ?[]const u8 = null,
    /// Azure OpenAI deployment name override used as the Responses model value.
    azure_deployment_name: ?[]const u8 = null,
    /// Mistral prompt mode, e.g. "reasoning".
    mistral_prompt_mode: ?[]const u8 = null,
    /// Mistral reasoning effort, e.g. "high".
    mistral_reasoning_effort: ?[]const u8 = null,
};

pub const SimpleStreamOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    transport: Transport = .auto,
    cache_retention: CacheRetention = .unset,
    session_id: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,
    timeout_ms: ?u32 = null,
    max_retries: ?u32 = null,
    on_payload: ?*const fn (std.mem.Allocator, std.json.Value, Model) anyerror!?std.json.Value = null,
    on_response: ?*const fn (u16, std.StringHashMap([]const u8), Model) anyerror!void = null,
    max_retry_delay_ms: u32 = 60000,
    metadata: ?std.json.Value = null,
    signal: ?*const std.atomic.Value(bool) = null,
    reasoning: ?ThinkingLevel = null,
    thinking_budgets: ?ThinkingBudgets = null,
    bedrock_region: ?[]const u8 = null,
    bedrock_profile: ?[]const u8 = null,
    bedrock_bearer_token: ?[]const u8 = null,
    bedrock_tool_choice: ?BedrockToolChoice = null,
    bedrock_interleaved_thinking: ?bool = null,
    bedrock_thinking_display: ?AnthropicThinkingDisplay = null,
    bedrock_request_metadata: ?std.json.Value = null,
    google_tool_choice: ?[]const u8 = null,
    google_thinking: ?GoogleThinkingOptions = null,
    openai_tool_choice: ?std.json.Value = null,
    openai_reasoning_effort: ?[]const u8 = null,
    azure_api_version: ?[]const u8 = null,
    azure_resource_name: ?[]const u8 = null,
    azure_base_url: ?[]const u8 = null,
    azure_deployment_name: ?[]const u8 = null,
    mistral_prompt_mode: ?[]const u8 = null,
    mistral_reasoning_effort: ?[]const u8 = null,

    /// Convert SimpleStreamOptions to StreamOptions
    pub fn toStreamOptions(self: SimpleStreamOptions) StreamOptions {
        return .{
            .temperature = self.temperature,
            .max_tokens = self.max_tokens,
            .api_key = self.api_key,
            .transport = self.transport,
            .cache_retention = self.cache_retention,
            .session_id = self.session_id,
            .headers = self.headers,
            .timeout_ms = self.timeout_ms,
            .max_retries = self.max_retries,
            .on_payload = self.on_payload,
            .on_response = self.on_response,
            .max_retry_delay_ms = self.max_retry_delay_ms,
            .metadata = self.metadata,
            .signal = self.signal,
            .bedrock_region = self.bedrock_region,
            .bedrock_profile = self.bedrock_profile,
            .bedrock_bearer_token = self.bedrock_bearer_token,
            .bedrock_tool_choice = self.bedrock_tool_choice,
            .bedrock_reasoning = self.reasoning,
            .bedrock_thinking_budgets = self.thinking_budgets,
            .bedrock_interleaved_thinking = self.bedrock_interleaved_thinking,
            .bedrock_thinking_display = self.bedrock_thinking_display,
            .bedrock_request_metadata = self.bedrock_request_metadata,
            .google_tool_choice = self.google_tool_choice,
            .google_thinking = self.google_thinking,
            .openai_tool_choice = self.openai_tool_choice,
            .openai_reasoning_effort = self.openai_reasoning_effort,
            .anthropic_thinking_enabled = null,
            .anthropic_thinking_budget_tokens = null,
            .anthropic_thinking_display = null,
            .anthropic_effort = null,
            .anthropic_interleaved_thinking = null,
            .anthropic_tool_choice = null,
            .responses_reasoning_effort = self.reasoning,
            .responses_text_verbosity = null,
            .azure_api_version = self.azure_api_version,
            .azure_resource_name = self.azure_resource_name,
            .azure_base_url = self.azure_base_url,
            .azure_deployment_name = self.azure_deployment_name,
            .mistral_prompt_mode = self.mistral_prompt_mode,
            .mistral_reasoning_effort = self.mistral_reasoning_effort,
        };
    }
};

pub const EventType = enum {
    start,
    text_start,
    text_delta,
    text_end,
    thinking_start,
    thinking_delta,
    thinking_end,
    toolcall_start,
    toolcall_delta,
    toolcall_end,
    done,
    error_event,
};

pub const AssistantMessageEvent = struct {
    event_type: EventType,
    content_index: ?u32 = null,
    delta: ?[]const u8 = null,
    owns_delta: bool = false,
    content: ?[]const u8 = null,
    tool_call: ?ToolCall = null,
    message: ?AssistantMessage = null,
    error_message: ?[]const u8 = null,

    pub fn deinitTransient(self: AssistantMessageEvent, allocator: std.mem.Allocator) void {
        if (self.owns_delta) {
            if (self.delta) |delta| allocator.free(delta);
        }
    }
};

test "Usage defaults" {
    const usage = Usage.init();
    try std.testing.expectEqual(@as(u32, 0), usage.input);
    try std.testing.expectEqual(@as(u32, 0), usage.output);
    try std.testing.expectEqual(@as(u32, 0), usage.cache_read);
    try std.testing.expectEqual(@as(u32, 0), usage.cache_write);
    try std.testing.expectEqual(@as(u32, 0), usage.total_tokens);
    try std.testing.expectEqual(@as(f64, 0), usage.cost.input);
    try std.testing.expectEqual(@as(f64, 0), usage.cost.output);
    try std.testing.expectEqual(@as(f64, 0), usage.cost.cache_read);
    try std.testing.expectEqual(@as(f64, 0), usage.cost.cache_write);
    try std.testing.expectEqual(@as(f64, 0), usage.cost.total);
}

test "UsageCost construction" {
    const cost = UsageCost{ .input = 1.5, .output = 2.0, .cache_read = 0.75, .cache_write = 1.0, .total = 5.25 };
    try std.testing.expectEqual(@as(f64, 1.5), cost.input);
    try std.testing.expectEqual(@as(f64, 2.0), cost.output);
    try std.testing.expectEqual(@as(f64, 0.75), cost.cache_read);
    try std.testing.expectEqual(@as(f64, 1.0), cost.cache_write);
    try std.testing.expectEqual(@as(f64, 5.25), cost.total);
}

test "Message union" {
    const user_msg = Message{ .user = .{
        .content = &[1]ContentBlock{.{ .text = .{ .text = "hello" } }},
        .timestamp = 1234567890,
    } };
    try std.testing.expectEqualStrings("user", user_msg.user.role);
}

test "KnownApi enum completeness" {
    // Ensure all variants compile by switching over them
    const api = KnownApi.openai_completions;
    const str = switch (api) {
        .openai_completions => "openai-completions",
        .mistral_conversations => "mistral-conversations",
        .openai_responses => "openai-responses",
        .azure_openai_responses => "azure-openai-responses",
        .openai_codex_responses => "openai-codex-responses",
        .anthropic_messages => "anthropic-messages",
        .bedrock_converse_stream => "bedrock-converse-stream",
        .google_generative_ai => "google-generative-ai",
        .google_gemini_cli => "google-gemini-cli",
        .google_vertex => "google-vertex",
        .faux => "faux",
    };
    try std.testing.expectEqualStrings("openai-completions", str);
}

test "KnownProvider enum completeness" {
    const provider = KnownProvider.openai;
    const str = switch (provider) {
        .amazon_bedrock => "amazon-bedrock",
        .anthropic => "anthropic",
        .google => "google",
        .google_gemini_cli => "google-gemini-cli",
        .google_antigravity => "google-antigravity",
        .google_vertex => "google-vertex",
        .openai => "openai",
        .azure_openai_responses => "azure-openai-responses",
        .openai_codex => "openai-codex",
        .deepseek => "deepseek",
        .github_copilot => "github-copilot",
        .xai => "xai",
        .groq => "groq",
        .cerebras => "cerebras",
        .openrouter => "openrouter",
        .vercel_ai_gateway => "vercel-ai-gateway",
        .zai => "zai",
        .mistral => "mistral",
        .minimax => "minimax",
        .minimax_cn => "minimax-cn",
        .huggingface => "huggingface",
        .fireworks => "fireworks",
        .opencode => "opencode",
        .opencode_go => "opencode-go",
        .kimi_coding => "kimi-coding",
        .faux => "faux",
    };
    try std.testing.expectEqualStrings("openai", str);
}

test "ContentBlock union variants" {
    const text_block = ContentBlock{ .text = .{ .text = "hello" } };
    try std.testing.expectEqualStrings("hello", text_block.text.text);

    const image_block = ContentBlock{ .image = .{ .data = "base64data", .mime_type = "image/png" } };
    try std.testing.expectEqualStrings("base64data", image_block.image.data);
    try std.testing.expectEqualStrings("image/png", image_block.image.mime_type);

    const thinking_block = ContentBlock{ .thinking = .{ .thinking = "thinking text", .signature = "sig", .redacted = true } };
    try std.testing.expectEqualStrings("thinking text", thinking_block.thinking.thinking);
    try std.testing.expectEqualStrings("sig", thinking_block.thinking.signature.?);
    try std.testing.expect(thinking_block.thinking.redacted);
}

test "AssistantMessage with responseId" {
    const msg = AssistantMessage{
        .content = &[_]ContentBlock{},
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4",
        .usage = Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1234567890,
    };
    try std.testing.expectEqualStrings("assistant", msg.role);
}

test "OpenAICompletionsCompat parity fields" {
    const compat = OpenAICompletionsCompat{
        .requires_reasoning_content_on_assistant_messages = true,
        .open_router_routing = .{
            .allow_fallbacks = false,
        },
        .vercel_gateway_routing = .{
            .only = &[_][]const u8{"openai"},
        },
        .supports_long_cache_retention = false,
    };
    try std.testing.expectEqual(true, compat.requires_reasoning_content_on_assistant_messages.?);
    try std.testing.expectEqual(false, compat.open_router_routing.?.allow_fallbacks.?);
    try std.testing.expectEqual(@as(usize, 1), compat.vercel_gateway_routing.?.only.?.len);
    try std.testing.expectEqualStrings("openai", compat.vercel_gateway_routing.?.only.?[0]);
    try std.testing.expectEqual(false, compat.supports_long_cache_retention.?);
}

test "StreamOptions parity timeout and retries" {
    const options = StreamOptions{
        .timeout_ms = 30_000,
        .max_retries = 4,
    };
    try std.testing.expectEqual(@as(u32, 30_000), options.timeout_ms.?);
    try std.testing.expectEqual(@as(u32, 4), options.max_retries.?);
}

test "Model with cost and compat" {
    const model = Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .cost = .{ .input = 30.0, .output = 60.0, .cache_read = 15.0, .cache_write = 30.0 },
        .context_window = 8192,
        .max_tokens = 4096,
        .compat = null,
    };
    try std.testing.expectEqualStrings("gpt-4", model.id);
    try std.testing.expect(model.reasoning);
    try std.testing.expectEqual(@as(f64, 30.0), model.cost.input);
    try std.testing.expectEqual(@as(f64, 60.0), model.cost.output);
    try std.testing.expectEqual(@as(f64, 15.0), model.cost.cache_read);
    try std.testing.expectEqual(@as(f64, 30.0), model.cost.cache_write);
    try std.testing.expectEqual(@as(usize, 2), model.input_types.len);
}

test {
    _ = @import("shared/simple_options.zig");
    _ = @import("shared/transform_messages.zig");
    _ = @import("shared/overflow.zig");
}
