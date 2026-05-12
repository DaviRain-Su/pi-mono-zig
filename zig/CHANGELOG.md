# Changelog

## [Unreleased]

### Breaking Changes

- Refactored `StreamOptions` provider-specific configuration: replaced ~30 flat per-provider fields (e.g. `bedrock_region`, `anthropic_thinking_enabled`, `responses_reasoning_effort`, `google_thinking`, `mistral_prompt_mode`, `openai_reasoning_effort`, `azure_api_version`) with a composable `provider: ProviderStreamOptions` struct of optionals. Set provider-specific options via `.provider = .{ .bedrock = .{ .region = "us-west-2" } }`. The previous `union(enum)` design couldn't represent multi-provider stacks like `azure-openai-responses` (which needs both `azure` and `responses` configuration on the same request); the new struct allows them to coexist. All seven providers (Mistral, Google, OpenAI Chat, Azure, Anthropic, Responses, Bedrock) migrated; `*Options()` helpers now read directly from the union without flat-field fallback. `SimpleStreamOptions` similarly slimmed — provider-specific flat fields removed, leaving only generic options plus `reasoning` / `thinking_budgets` which fan out to `provider.bedrock` and `provider.responses` via `toStreamOptions`.

### Changed

- Replaced the Zig interactive missing stored-cwd stderr/stdin prompt with a full TUI Continue/Cancel selector that mirrors the TypeScript `ExtensionSelectorComponent` flow used by `promptForMissingSessionCwd`, with tuistory coverage for prompt rendering, cancel, escape, and continue paths. Cancel exits without mutating the session file; continue persists the launch cwd only after explicit confirmation.
- Unified per-provider metadata into a single `provider_info.PROVIDERS` table covering `id`, `display_name`, `default_model`, `missing_api_key_message`, `env_var`, `env_vars`, `default_api`, `prefer_initial`, and `oauth_default_client_id`. Replaces four formerly-separate per-provider lookups (display names, default-model map, missing-API-key messages, env-key static map) and the `model_resolver.zig` / `provider_display_names.zig` shims with one canonical row per provider. Bespoke conditional auth logic (`google-vertex` ADC, `amazon-bedrock` multi-credential AND-conjunction) continues to live in `env_api_keys.zig`; per-provider streaming continues to live in `providers/*.zig`. Cross-check tests assert the row table agrees with the model registry and the auth-layer OAuth client table.
- Encoded per-provider env-var fallback chains as data on `provider_info`. The `env_vars` field is an ordered priority list (e.g. `ANTHROPIC_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`); resolution returns the first non-empty value. Providers with sentinel-return semantics, filesystem probes (ADC), or AND-conjunction across heterogeneous env vars remain in their bespoke `env_api_keys.zig` branches.
- Recorded built-in public OAuth client ids on `provider_info` for providers that ship a hard-coded "public" OAuth application (Anthropic Claude Pro/Max, GitHub Copilot, OpenAI Codex). Providers whose OAuth flow requires an end-user-supplied client id leave the field null and continue to rely on the on-disk `oauth-clients.json` config; an auth-layer cross-check test asserts agreement between `provider_info` and the `AuthProviderInfo` table.

### Fixed

- Treat anthropic streams that end before `message_stop` as errors rather than silent stops. Premature transport closure now surfaces an `error_event` instead of looking like a normal completion to downstream accumulators.
- Apply openai `service_tier` cost multipliers (`priority`, `flex`, `scale`) to usage cost calculation so per-request totals match the billed price for non-default service tiers.
- Regenerate google `functionCall` ids on collision within a single response so duplicate ids emitted by Gemini no longer collapse two tool calls into one downstream.
- Coalesce openai chat completions `text → tool_call → text` runs into a single text block so the second text fragment is no longer dropped when a tool call interleaves narration.
- Coalesce kimi `text → tool_call → text` runs into a single text block to match the openai-chat fix.
- Calculate anthropic per-request cost on `message_start` once cache_creation/cache_read counts are known, instead of deferring to `message_delta` where only the output tokens are reported. Fixes under-counted costs for cache-heavy requests.

### Added

- User-supplied `models.json` is now parsed as JSONC: `//` line comments, `/* */` block comments, and trailing commas before `}` / `]` are stripped before `std.json.parseFromSlice`, so users can annotate their config and leave trailing commas without breaking the loader. String literals are preserved verbatim. Mirrors TS commit bb25a394 (#4162). Internal JSON paths (session JSONL, RPC payloads, etc.) are untouched.
- Wired `EventOrderingGuard` into `AssistantMessageEventStream.push()` for debug builds. Every event the stream receives is validated against ISS-502 / INV-3 ordering invariants (`_start → _delta* → _end`, content_index stability, terminal event ordering). Violations panic so providers and callers surface ordering bugs in CI rather than letting them reach downstream accumulators silently. Release builds skip the guard entirely. `error_event` terminals are intentionally allowed with open blocks (stream-level provider errors like throttling/service_unavailable can fire mid-block; downstream accumulators reset state on error rather than relying on synthetic `_end` events).
- Added a Codex WebSocket transport stack for `openai-codex-responses`. New `transport` option accepts `.sse` (legacy SSE-over-HTTPS), `.websocket`, `.websocket_cached`, and `.auto` (default). `.auto` opens a WebSocket and falls back to SSE per-session on transport-class errors while leaving application/protocol errors (`response.failed`, `error`) untouched. `.websocket_cached` reuses an idle socket within a 5-minute TTL when the request body shape matches and new input is a prefix-extension of the prior body, rewriting the wire payload to `{ ...body, previous_response_id, input: delta }`. Diagnostics: when fallback engages, a `provider_transport_failure` envelope is appended to the assistant message. Cleanup: `closeOpenAICodexWebSocketSessions(session_id)` clears the cache for a session. Backed by a new minimal in-tree WebSocket client module and a `TestWebSocketServer` test harness with multi-connection scripting.

### Removed

- Removed unused `KnownApi` and `KnownProvider` enums from `zig/src/ai/types.zig`. Both had drifted from the runtime API/provider registry (`kimi-completions` registered without an enum variant; `together` provider used in 18 model rows with no enum variant) and had no production references — all dispatch already routes through string keys via `api_registry.get([]const u8)`.

### Fixed

- Routed Zig `--mode rpc` to the TypeScript-compatible JSONL RPC protocol, kept the legacy JSON-RPC implementation available as `--mode json-rpc`, and added Zig CLI aliases for `-mode rpc`, `-t`, and `-nt`.
- Improved Zig TUI day/night theme contrast, exposed `/theme` in slash command suggestions, and left terminal mouse reporting off by default so native text selection/copy works while bracketed paste remains enabled.
- Fixed blank Chinese IME commits in the Zig interactive TUI input box on Linux Ghostty + Fcitx by suppressing Kitty keyboard protocol enablement for Ghostty while preserving other terminals.
- The Zig missing stored-cwd preflight now runs before `runtime_prep.prepareCliRuntime` in non-interactive and interactive resume/open flows. Runtime config, resource bundle, context file, system prompt, provider auth, and tool construction failures can no longer preempt the missing-cwd diagnostic or the Continue/Cancel TUI selector. The early Continue path is recorded so the deeper interactive bootstrap does not prompt twice, and `readSessionHeader` now uses a bounded streaming first-line read instead of loading the entire session file.
