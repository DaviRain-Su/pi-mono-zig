# Zig vs TypeScript Parity Review

Last updated: 2026-05-05.

This review reflects the current Zig implementation in this repository. It
replaces the older "provider stub / early rewrite" assessment. The Zig version
now has a real CLI, interactive TUI, provider registry, session manager,
tools, JSON event wire, TS-RPC parity harnesses, and a Bun-backed TypeScript
extension compatibility layer.

## Executive Summary

The Zig implementation is now usable for the main coding-agent workflows:

- interactive mode and print mode
- JSON event output
- TS-RPC mode with golden parity coverage
- session create / continue / resume / fork / clone
- missing-cwd preflight and interactive selector
- built-in tools: read, write, edit, bash, grep, find, ls
- provider routing across OpenAI, Anthropic, Mistral, Kimi, Google, Vertex,
  Gemini CLI, Bedrock, Azure Responses, Codex Responses, GitHub Copilot,
  MiniMax, Hugging Face, Fireworks, OpenRouter, Vercel AI Gateway, Z.AI,
  Groq, Cerebras, xAI, OpenCode, and faux
- extension host process boundary and registration surface for tools,
  commands, shortcuts, flags, providers, widgets, editor hooks, header/footer
  hooks, terminal input hooks, and package-management commands
- `/share`, export HTML/JSONL, image normalization, and clipboard image paste

Full TypeScript replacement is close, but not complete. The remaining gaps are
mostly provider catalog deltas, one runtime-contract consistency issue, Linux CI
compiler instability, and extension edge-case verification.

## Current Status

| Area | Status | Replacement Risk |
|---|---|---:|
| Core agent runtime | Mostly complete. Prompt, tools, retry, compaction, abort, queue steering, and TS-RPC parity scenarios are covered. | Low |
| JSON event wire | Mostly complete. CLI JSON output is schema validated and TS-RPC goldens cover the public wire. | Low |
| CLI / bootstrap | Mostly complete. `--print`, `--mode json`, `--mode ts-rpc`, session flags, export, package commands, and extension flags are implemented. | Low |
| Interactive TUI | Mostly complete. Rendering, selectors, session tree, fork selector, clipboard image, missing-cwd selector, and M8 smoke coverage exist. | Low |
| Sessions | Mostly complete. Session v3, parent linkage, cross-provider continuation, HTML/JSONL export, and missing-cwd handling are present. | Low |
| Built-in tools | Mostly complete. File mutation queue serializes same-file writes while allowing different-file parallelism. | Low |
| Providers / auth | Good coverage for major providers, but TS `KnownProvider` still has standalone provider names Zig does not model. | Medium |
| TS extensions | Core compatibility layer is implemented. Dynamic refresh semantics still need tighter end-to-end regression coverage. | Medium |
| MCP | Not native-complete; expected to flow through extension compatibility for now. | Medium |
| Linux CI | Workflow is green, but Linux Zig build/test is skipped because Zig 0.16.0 SEGVs during `build-exe` on `ubuntu-latest`. | Medium |

## Confirmed Resolved Since Earlier Reviews

The following older review findings are no longer current:

- Azure Responses and Codex Responses now use `streamProduction` and return
  terminal `error_event` on setup/runtime failures instead of leaking hard
  errors.
- Bedrock's `emitSetupRuntimeFailure` now matches the shared provider contract:
  no allocator argument and `void` return.
- Zig env auth mappings now include DeepSeek, Moonshot, Cloudflare, Xiaomi
  token-plan variables, MiniMax, and other provider env vars present in TS.
- Vertex ADC auth detection now checks credential file existence and the
  default ADC file path instead of only checking for a non-empty env var.
- Setup-failure smoke tests exist for Google, Vertex, Gemini CLI, Mistral,
  Kimi, Azure Responses, and Codex Responses.
- TS-RPC parity is not hypothetical; it is covered by `zig/test/ts-rpc-parity.sh`
  and golden fixtures.
- Bun-hosted extension communication is implemented and exercised by the M6
  extension-host parity fixture.
- Package CLI parity is implemented for install, remove/uninstall, update,
  list, and config.
- `/share`, export HTML, image normalization, clipboard image paste, and
  session lifecycle edge cases are implemented.

## Remaining Gaps

### P0: Abort Memory Ordering Is Still Non-Uniform

`zig/src/ai/stream.zig` still loads the abort signal with `.monotonic`, while
provider-level paths and `zig/src/ai/shared/provider_error.zig` use `.seq_cst`.

Impact:

- The pre-provider abort check may observe a different ordering contract than
  provider/runtime paths.
- This is a small but real runtime-contract inconsistency.

Recommended fix:

- Pick one ordering, preferably `.seq_cst` for consistency, and apply it across
  `stream.zig`, `provider_error.zig`, and provider-local helpers.

### P1: TS KnownProvider Catalog Still Leads Zig

Zig has provider configs and routing for the main providers, including MiniMax.
However, the Zig `KnownProvider` enum and built-in model registry still do not
fully mirror the TS `KnownProvider` list.

Still missing as standalone Zig provider/catalog entries:

- `moonshotai`
- `moonshotai-cn`
- `cloudflare-workers-ai`
- `cloudflare-ai-gateway`
- `xiaomi`
- `xiaomi-token-plan-cn`
- `xiaomi-token-plan-ams`
- `xiaomi-token-plan-sgp`

Notes:

- Kimi covers the Moonshot CN API path for the existing Kimi provider, but it is
  not the same as exposing TS-compatible `moonshotai` / `moonshotai-cn`
  provider names.
- Cloudflare helpers exist and are wired into OpenAI/Anthropic-compatible
  provider paths, but Cloudflare is not yet a first-class standalone provider in
  Zig.
- Env var mappings for these providers are already present in
  `zig/src/ai/env_api_keys.zig`; the remaining work is type/model/provider
  registration and provider routing.

### P1: Missing `ModelThinkingLevel = "off"` Type Parity

TypeScript distinguishes:

```ts
type ThinkingLevel = "minimal" | "low" | "medium" | "high" | "xhigh";
type ModelThinkingLevel = "off" | ThinkingLevel;
```

Zig currently exposes `ThinkingLevel` without an AI model-level `"off"` state in
`zig/src/ai/types.zig`. The coding-agent layer has an `off` thinking level, but
the AI model type surface still cannot represent TS model metadata exactly.

Impact:

- Generated or imported model metadata that uses `"off"` cannot round-trip
  exactly through Zig's AI type layer.

### P2: Provider Setup-Failure Test Coverage Has One Known Hole

Canonical setup-failure smoke tests now exist for most providers, but
`zig/src/ai/providers/openai_responses.zig` still lacks the explicit
`stream returns error_event on setup failure` regression test.

Impact:

- The implementation uses the correct wrapper pattern, but the regression is
  not pinned as directly as the other providers.

### P2: Extension Dynamic Refresh Needs Narrower E2E Coverage

The extension registration surface is broad and implemented:

- tools
- commands
- shortcuts
- flags
- providers
- widgets
- editor hooks
- header/footer hooks
- terminal input hooks

Remaining verification work:

- dynamic tool/provider refresh after re-registration
- unregister/re-register ordering
- help text formatting parity for extension flags
- failure isolation when an extension host emits malformed registration events

### P2: Linux CI Is Green By Skipping Zig Build/Test

`ubuntu-latest` currently installs dependencies and verifies external tools, but
skips `zig build` and `zig build test`.

Reason:

- Zig 0.16.0 currently terminates with `signal SEGV` during `zig build-exe` on
  `ubuntu-latest`.
- The workflow keeps macOS as the blocking full build/test lane.

Recommended follow-up:

- When a stable Zig release containing the upstream fix is available, update the
  workflow and restore Linux build/test.

## Not Currently Blocking

### Bedrock Stream Contract

Resolved. Bedrock now uses the same non-fallible setup-failure emission shape as
other providers.

### Vertex ADC Auth Detection

Resolved. Zig now checks `GOOGLE_APPLICATION_CREDENTIALS` file existence and
falls back to the default ADC path under the user's home directory.

### Env API Key Mapping

Resolved for the mappings previously identified as missing. The remaining
provider gap is registration/routing/catalog parity, not env key lookup.

### OpenAI/Codex/Azure Responses Setup Errors

Resolved. Azure Responses and Codex Responses now use the stream wrapper pattern
and have setup-failure tests. OpenAI Responses uses the wrapper pattern; only the
explicit smoke test is still missing.

## Recommended Next Work Order

1. Fix abort memory ordering in `zig/src/ai/stream.zig`.
2. Add the missing OpenAI Responses setup-failure smoke test.
3. Add TS-compatible standalone provider names for Moonshot, Cloudflare, and
   Xiaomi families.
4. Add model-level `"off"` thinking parity to the Zig AI type/model metadata
   path.
5. Backfill extension dynamic-refresh E2E tests with real Bun-hosted fixture
   extensions.
6. Re-enable Linux Zig build/test once a stable Zig compiler release fixes the
   Ubuntu `build-exe` SEGV.

## Verification Assets

Useful existing harnesses:

- `zig build test`
- `zig build test-coding-agent`
- `zig build test-cross-area`
- `zig build test-ts-rpc-parity`
- `zig/test/openai-chat-parity.sh`
- `zig/test/openai-responses-parity.sh`
- `zig/test/bedrock-parity.sh`
- `zig/test/vaxis-m8-e2e.sh`
- `zig/test/missing-cwd-selector.sh`

## Final Position

The Zig rewrite is no longer an experiment or a partial provider port. It is a
mostly functional native implementation with strong parity coverage for the
main product paths.

The remaining work is narrower than before:

- close the last runtime-contract inconsistency
- align provider catalog/type metadata with TS
- harden extension dynamic-refresh behavior
- restore Linux CI build/test when the Zig compiler issue is fixed

Forward-looking extension architecture work is tracked separately in
`zig/docs/wasm-extension-roadmap.md`. That roadmap covers the language-neutral
Wasm extension direction inspired by Tree-sitter's declarative source plus
compiled artifact model, while this review remains focused on current
TypeScript parity status.
