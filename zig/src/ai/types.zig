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

pub const CacheRetention = enum {
    none,
    short,
    long,
};

pub const Transport = enum {
    sse,
    websocket,
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
};

pub const ImageContent = struct {
    data: []const u8, // base64
    mime_type: []const u8,
};

pub const ThinkingContent = struct {
    thinking: []const u8,
    signature: ?[]const u8 = null,
    redacted: bool = false,
};

pub const ContentBlock = union(enum) {
    text: TextContent,
    image: ImageContent,
    thinking: ThinkingContent,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.Value,
};

pub const UserMessage = struct {
    role: []const u8 = "user",
    content: []const ContentBlock,
    timestamp: i64,
};

pub const AssistantMessage = struct {
    role: []const u8 = "assistant",
    content: []const ContentBlock,
    tool_calls: ?[]const ToolCall = null,
    api: Api,
    provider: Provider,
    model: []const u8,
    response_id: ?[]const u8 = null,
    usage: Usage,
    stop_reason: StopReason,
    error_message: ?[]const u8 = null,
    timestamp: i64,
};

pub const ToolResultMessage = struct {
    role: []const u8 = "toolResult",
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const ContentBlock,
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
    thinking_format: ?[]const u8 = null, // "openai", "openrouter", "zai", "qwen", "qwen-chat-template"
    zai_tool_stream: bool = false,
    supports_strict_mode: bool = true,
    cache_control_format: ?[]const u8 = null, // "anthropic"
    send_session_affinity_headers: bool = false,
};

pub const OpenAIResponsesCompat = struct {
    // Reserved for future use
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
    input_types: []const []const u8, // "text", "image"
    cost: ModelCost = .{},
    context_window: u32,
    max_tokens: u32,
    headers: ?std.StringHashMap([]const u8) = null,
    compat: ?std.json.Value = null, // OpenAICompletionsCompat or OpenAIResponsesCompat
};

pub const StreamOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    transport: Transport = .auto,
    cache_retention: CacheRetention = .short,
    session_id: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,
    /// Optional callback for inspecting or replacing provider payloads before sending.
    /// In Zig, this is a function pointer taking allocator, payload json.Value, model, and returning an optional modified payload.
    on_payload: ?*const fn (std.mem.Allocator, std.json.Value, Model) anyerror!?std.json.Value = null,
    /// Optional callback invoked after an HTTP response is received and before its body stream is consumed.
    on_response: ?*const fn (u16, std.StringHashMap([]const u8), Model) void = null,
    /// Optional abort signal checked during streaming.
    signal: ?*const std.atomic.Value(bool) = null,
    /// Maximum delay in milliseconds to wait for a retry when the server requests a long wait.
    /// Default: 60000 (60 seconds). Set to 0 to disable the cap.
    max_retry_delay_ms: u32 = 60000,
    /// Optional metadata to include in API requests.
    metadata: ?std.json.Value = null,
};

pub const SimpleStreamOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    transport: Transport = .auto,
    cache_retention: CacheRetention = .short,
    session_id: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,
    on_payload: ?*const fn (std.mem.Allocator, std.json.Value, Model) anyerror!?std.json.Value = null,
    on_response: ?*const fn (u16, std.StringHashMap([]const u8), Model) void = null,
    max_retry_delay_ms: u32 = 60000,
    metadata: ?std.json.Value = null,
    signal: ?*const std.atomic.Value(bool) = null,
    reasoning: ?ThinkingLevel = null,
    thinking_budgets: ?std.json.Value = null,

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
            .on_payload = self.on_payload,
            .on_response = self.on_response,
            .max_retry_delay_ms = self.max_retry_delay_ms,
            .metadata = self.metadata,
            .signal = self.signal,
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
    content: ?[]const u8 = null,
    tool_call: ?ToolCall = null,
    message: ?AssistantMessage = null,
    error_message: ?[]const u8 = null,
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
