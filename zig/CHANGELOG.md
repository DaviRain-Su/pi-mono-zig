# Changelog

## [Unreleased]

### Breaking Changes

- Refactored `StreamOptions` provider-specific configuration: replaced ~30 flat per-provider fields (e.g. `bedrock_region`, `anthropic_thinking_enabled`, `responses_reasoning_effort`, `google_thinking`, `mistral_prompt_mode`, `openai_reasoning_effort`, `azure_api_version`) with a composable `provider: ProviderStreamOptions` struct of optionals. Set provider-specific options via `.provider = .{ .bedrock = .{ .region = "us-west-2" } }`. The previous `union(enum)` design couldn't represent multi-provider stacks like `azure-openai-responses` (which needs both `azure` and `responses` configuration on the same request); the new struct allows them to coexist. All seven providers (Mistral, Google, OpenAI Chat, Azure, Anthropic, Responses, Bedrock) migrated; `*Options()` helpers now read directly from the union without flat-field fallback. `SimpleStreamOptions` similarly slimmed — provider-specific flat fields removed, leaving only generic options plus `reasoning` / `thinking_budgets` which fan out to `provider.bedrock` and `provider.responses` via `toStreamOptions`.

### Changed

- Replaced the Zig interactive missing stored-cwd stderr/stdin prompt with a full TUI Continue/Cancel selector that mirrors the TypeScript `ExtensionSelectorComponent` flow used by `promptForMissingSessionCwd`, with tuistory coverage for prompt rendering, cancel, escape, and continue paths. Cancel exits without mutating the session file; continue persists the launch cwd only after explicit confirmation.

### Added

- Wired `EventOrderingGuard` into `AssistantMessageEventStream.push()` for debug builds. Every event the stream receives is validated against ISS-502 / INV-3 ordering invariants (`_start → _delta* → _end`, content_index stability, terminal event ordering). Violations panic so providers and callers surface ordering bugs in CI rather than letting them reach downstream accumulators silently. Release builds skip the guard entirely. `error_event` terminals are intentionally allowed with open blocks (stream-level provider errors like throttling/service_unavailable can fire mid-block; downstream accumulators reset state on error rather than relying on synthetic `_end` events).

### Removed

- Removed unused `KnownApi` and `KnownProvider` enums from `zig/src/ai/types.zig`. Both had drifted from the runtime API/provider registry (`kimi-completions` registered without an enum variant; `together` provider used in 18 model rows with no enum variant) and had no production references — all dispatch already routes through string keys via `api_registry.get([]const u8)`.

### Fixed

- Routed Zig `--mode rpc` to the TypeScript-compatible JSONL RPC protocol, kept the legacy JSON-RPC implementation available as `--mode json-rpc`, and added Zig CLI aliases for `-mode rpc`, `-t`, and `-nt`.
- Improved Zig TUI day/night theme contrast, exposed `/theme` in slash command suggestions, and left terminal mouse reporting off by default so native text selection/copy works while bracketed paste remains enabled.
- Fixed blank Chinese IME commits in the Zig interactive TUI input box on Linux Ghostty + Fcitx by suppressing Kitty keyboard protocol enablement for Ghostty while preserving other terminals.
- The Zig missing stored-cwd preflight now runs before `runtime_prep.prepareCliRuntime` in non-interactive and interactive resume/open flows. Runtime config, resource bundle, context file, system prompt, provider auth, and tool construction failures can no longer preempt the missing-cwd diagnostic or the Continue/Cancel TUI selector. The early Continue path is recorded so the deeper interactive bootstrap does not prompt twice, and `readSessionHeader` now uses a bounded streaming first-line read instead of loading the entire session file.
