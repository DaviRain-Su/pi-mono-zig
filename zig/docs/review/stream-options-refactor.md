# StreamOptions Refactor Design (B11)

## Problem

`StreamOptions` has 43 fields, 29 of which are provider-specific. This creates:
- Cognitive overhead: consumers see irrelevant fields
- Maintenance burden: adding a provider field requires changes in 3+ places
- Type safety loss: generic code cannot distinguish provider-specific from generic options

## Current Field Breakdown

- Generic (14): temperature, max_tokens, api_key, transport, cache_retention,
  session_id, headers, timeout_ms, max_retries, on_payload, on_response,
  signal, max_retry_delay_ms, metadata
- Provider-specific (29):
  - anthropic: 6 fields
  - bedrock: 9 fields
  - azure: 4 fields
  - google: 2 fields
  - mistral: 2 fields
  - openai: 2 fields
  - responses: 4 fields

## Proposed Design

### New Types

```zig
pub const AnthropicStreamOptions = struct {
    thinking_enabled: ?bool = null,
    thinking_budget_tokens: ?u32 = null,
    thinking_display: ?AnthropicThinkingDisplay = null,
    effort: ?AnthropicEffort = null,
    interleaved_thinking: ?bool = null,
    tool_choice: ?AnthropicToolChoice = null,
};

pub const BedrockStreamOptions = struct {
    region: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    bearer_token: ?[]const u8 = null,
    tool_choice: ?BedrockToolChoice = null,
    reasoning: ?ThinkingLevel = null,
    thinking_budgets: ?ThinkingBudgets = null,
    interleaved_thinking: ?bool = null,
    thinking_display: ?AnthropicThinkingDisplay = null,
    request_metadata: ?std.json.Value = null,
};

pub const AzureStreamOptions = struct {
    api_version: ?[]const u8 = null,
    resource_name: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    deployment_name: ?[]const u8 = null,
};

pub const GoogleStreamOptions = struct {
    tool_choice: ?[]const u8 = null,
    thinking: ?GoogleThinkingOptions = null,
};

pub const MistralStreamOptions = struct {
    prompt_mode: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
};

pub const OpenAIChatStreamOptions = struct {
    tool_choice: ?std.json.Value = null,
    reasoning_effort: ?[]const u8 = null,
};

pub const ResponsesStreamOptions = struct {
    reasoning_effort: ?ThinkingLevel = null,
    reasoning_summary: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    text_verbosity: ?[]const u8 = null,
};

pub const ProviderStreamOptions = union(enum) {
    none,
    anthropic: AnthropicStreamOptions,
    azure: AzureStreamOptions,
    bedrock: BedrockStreamOptions,
    google: GoogleStreamOptions,
    mistral: MistralStreamOptions,
    openai: OpenAIChatStreamOptions,
    responses: ResponsesStreamOptions,
};
```

### Modified StreamOptions

```zig
pub const StreamOptions = struct {
    // Generic fields only (14)
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    transport: Transport = .auto,
    cache_retention: CacheRetention = .unset,
    session_id: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,
    timeout_ms: ?u32 = null,
    max_retries: ?u32 = null,
    on_payload: ?*const fn (...) ... = null,
    on_response: ?*const fn (...) ... = null,
    signal: ?*const std.atomic.Value(bool) = null,
    max_retry_delay_ms: u32 = 60000,
    metadata: ?std.json.Value = null,

    provider: ProviderStreamOptions = .none,
};
```

### Migration Strategy

1. **Phase 1**: Add new types alongside existing fields (backward compatible)
2. **Phase 2**: Update provider `stream()` functions to read from `options.provider.*`
3. **Phase 3**: Update `stream.zig` to populate `options.provider.*` instead of flat fields
4. **Phase 4**: Update `SimpleStreamOptions.toStreamOptions()` mapping
5. **Phase 5**: Remove old flat fields from `StreamOptions`

### Access Pattern Change

Before:
```zig
if (options.anthropic_thinking_enabled) |enabled| { ... }
```

After:
```zig
if (options.provider == .anthropic) {
    if (options.provider.anthropic.thinking_enabled) |enabled| { ... }
}
```

Or with helper:
```zig
if (options.providerAs(.anthropic)) |anthropic| {
    if (anthropic.thinking_enabled) |enabled| { ... }
}
```

### Files to Change

- `src/ai/types.zig` — type definitions
- `src/ai/stream.zig` — option population (~30 field accesses)
- `src/ai/shared/simple_options.zig` — toStreamOptions mapping
- `src/ai/providers/anthropic.zig` — 6 field accesses
- `src/ai/providers/bedrock.zig` — 9 field accesses
- `src/ai/providers/azure_openai_responses.zig` — 4 field accesses
- `src/ai/providers/google.zig` — 2 field accesses
- `src/ai/providers/google_vertex.zig` — 2 field accesses
- `src/ai/providers/google_gemini_cli.zig` — 2 field accesses
- `src/ai/providers/mistral.zig` — 2 field accesses
- `src/ai/providers/openai_chat_payload.zig` — 2 field accesses
- `src/ai/providers/openai_codex_responses.zig` — 4 field accesses
- `src/ai/providers/openai_responses.zig` — 3 field accesses

Total: ~13 files, ~60 field access changes
