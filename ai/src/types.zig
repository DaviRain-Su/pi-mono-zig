const std = @import("std");

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
    faux, // added for testing parity
};

pub const Api = union(enum) {
    known: KnownApi,
    custom: []const u8,
};

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

pub const Provider = union(enum) {
    known: KnownProvider,
    custom: []const u8,
};

pub const ThinkingLevel = enum {
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const ThinkingBudgets = struct {
    minimal: u32 = 1024,
    low: u32 = 2048,
    medium: u32 = 8192,
    high: u32 = 16384,
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
    err,
    aborted,
};

pub const TextContent = struct {
    text: []const u8,
    text_signature: ?[]const u8 = null,
};

pub const ThinkingContent = struct {
    thinking: []const u8,
    thinking_signature: ?[]const u8 = null,
    redacted: bool = false,
};

pub const ImageContent = struct {
    data: []const u8, // base64
    mime_type: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.Value,
    thought_signature: ?[]const u8 = null,
};

pub const ContentBlock = union(enum) {
    text: TextContent,
    thinking: ThinkingContent,
    image: ImageContent,
    tool_call: ToolCall,
};

pub const Usage = struct {
    input: u32 = 0,
    output: u32 = 0,
    cache_read: u32 = 0,
    cache_write: u32 = 0,
    total_tokens: u32 = 0,
    cost: Cost = .{},

    pub const Cost = struct {
        input: f64 = 0,
        output: f64 = 0,
        cache_read: f64 = 0,
        cache_write: f64 = 0,
        total: f64 = 0,
    };
};

pub const UserMessage = struct {
    role: []const u8 = "user",
    content: ContentBlocks,
    timestamp: i64 = 0,

    pub const ContentBlocks = union(enum) {
        text: []const u8,
        blocks: []const ContentBlock,
    };
};

pub const AssistantMessage = struct {
    role: []const u8 = "assistant",
    content: []ContentBlock,
    api: Api,
    provider: Provider,
    model: []const u8,
    response_id: ?[]const u8 = null,
    usage: Usage,
    stop_reason: StopReason,
    error_message: ?[]const u8 = null,
    timestamp: i64 = 0,
};

pub const ToolResultMessage = struct {
    role: []const u8 = "toolResult",
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []ContentBlock, // text or image
    details: ?std.json.Value = null,
    is_error: bool = false,
    timestamp: i64 = 0,
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

pub const StreamOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    signal: ?*anyopaque = null, // placeholder for abort signal abstraction
    api_key: ?[]const u8 = null,
    transport: Transport = .sse,
    cache_retention: CacheRetention = .short,
    session_id: ?[]const u8 = null,
    max_retry_delay_ms: ?u32 = 60000,
    headers: ?std.json.Value = null,
    metadata: ?std.json.Value = null,
    io: ?std.Io = null,
    // Provider-specific extensions
    reasoning_effort: ?[]const u8 = null,
    reasoning_summary: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    store: ?bool = null,
    include: ?[]const []const u8 = null,
    prompt_cache_retention: ?[]const u8 = null,
    prompt_cache_key: ?[]const u8 = null,
    top_p: ?f32 = null,
    top_k: ?u32 = null,
};

pub const SimpleStreamOptions = struct {
    base: StreamOptions = .{},
    reasoning: ?ThinkingLevel = null,
    thinking_budgets: ?std.json.Value = null, // placeholder
};

pub const OpenAICompletionsCompat = struct {
    supports_store: ?bool = null,
    supports_developer_role: ?bool = null,
    supports_reasoning_effort: ?bool = null,
    reasoning_effort_map: ?std.json.Value = null,
    supports_usage_in_streaming: bool = true,
    max_tokens_field: enum { max_completion_tokens, max_tokens } = .max_completion_tokens,
    requires_tool_result_name: ?bool = null,
    requires_assistant_after_tool_result: ?bool = null,
    requires_thinking_as_text: ?bool = null,
    thinking_format: enum { openai, openrouter, zai, qwen, qwen_chat_template } = .openai,
    zai_tool_stream: bool = false,
    supports_strict_mode: bool = true,
};

pub const OpenAIResponsesCompat = struct {};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    api: Api,
    provider: Provider,
    base_url: ?[]const u8 = null,
    reasoning: bool = false,
    input_types: []const []const u8 = &.{"text"},
    cost: Cost = .{},
    context_window: u32 = 0,
    max_tokens: u32 = 0,
    headers: ?std.json.Value = null,
    compat: ?std.json.Value = null,

    pub const Cost = struct {
        input: f64 = 0,
        output: f64 = 0,
        cache_read: f64 = 0,
        cache_write: f64 = 0,
    };
};

pub const Context = struct {
    system_prompt: ?[]const u8 = null,
    messages: []const Message,
    tools: ?[]const Tool = null,
};
