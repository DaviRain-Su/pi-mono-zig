# Zig vs TypeScript Parity Review

Last updated: 2026-05-06.

This review reflects the current Zig implementation in this repository. It
replaces the older "provider stub / early rewrite" assessment. The Zig version
now has a real CLI, interactive TUI, provider registry, session manager,
tools, JSON event wire, TS-RPC parity harnesses, and a Bun-backed TypeScript
extension compatibility layer.

## Executive Summary

The Zig implementation is now usable for the main coding-agent workflows:

- interactive mode and print mode
- interactive-mode login/auth, session lifecycle, and slash command routing
  are split into focused Zig helper modules while preserving current behavior
- interactive input dispatch has a distinct key-resolution module and an
  exhaustive app-action executor, preserving configurable keybinding behavior
- JSON event output
- TS-RPC mode with golden parity coverage
- session create / continue / resume / fork / clone
- missing-cwd preflight and interactive selector
- built-in tools: read, write, edit, bash, grep, find, ls
- provider routing across OpenAI, Anthropic, Mistral, Kimi, Google, Vertex,
  Gemini CLI, Bedrock, Azure Responses, Codex Responses, GitHub Copilot,
  MiniMax, Hugging Face, Fireworks, OpenRouter, Vercel AI Gateway, Z.AI,
  Groq, Cerebras, xAI, OpenCode, and faux
- shared provider stream setup-error/header/canonical SSE data-line support has
  started, with Google Generative AI, Google Vertex, Google Gemini CLI, and
  Mistral, OpenAI Responses, and Azure OpenAI Responses using common non-OOM
  setup failure conversion, owned request-header insertion/merge/deinit helpers,
  normalized `on_response` header lookup, and canonical `data: ` extraction
  while keeping provider-specific auth headers, request/payload mapping, and
  stream state machines provider-owned
- provider-owned JSON value lifecycle support now has shared clone/free/empty
  object helpers used by provider payload and replay helpers without moving
  provider-specific request or response mapping
- extension host process boundary and registration surface for tools,
  commands, shortcuts, flags, providers, widgets, editor hooks, header/footer
  hooks, terminal input hooks, and package-management commands
- `/share`, export HTML/JSONL, image normalization, and clipboard image paste

Full TypeScript replacement is close, but not complete. The remaining gaps are
mostly native MCP scope and continued extension/provider edge-case verification.

## Current Status

| Area | Status | Replacement Risk |
|---|---|---:|
| Core agent runtime | Mostly complete. Prompt, tools, retry, compaction, abort, queue steering, and TS-RPC parity scenarios are covered. | Low |
| JSON event wire | Mostly complete. CLI JSON output is schema validated and TS-RPC goldens cover the public wire. | Low |
| CLI / bootstrap | Mostly complete. `--print`, `--mode json`, `--mode ts-rpc`, session flags, export, package commands, and extension flags are implemented. | Low |
| Interactive TUI | Mostly complete. Rendering, selectors, session tree, fork selector, clipboard image, missing-cwd selector, and M8 smoke coverage exist. | Low |
| Sessions | Mostly complete. Session v3, parent linkage, cross-provider continuation, HTML/JSONL export, and missing-cwd handling are present. | Low |
| Built-in tools | Mostly complete. File mutation queue serializes same-file writes while allowing different-file parallelism. | Low |
| Providers / auth | Good coverage for major providers, including standalone Moonshot, Cloudflare, Xiaomi, Kimi, and compatible-provider catalog entries. | Low |
| TS extensions | Core compatibility layer is implemented. Dynamic refresh, malformed registration isolation, and reload cleanup now have targeted regression coverage. | Low |
| MCP | Not native-complete; expected to flow through extension compatibility for now. | Medium |
| Linux CI | `ubuntu-latest` installs Zig/tools and runs build-graph/tool smoke checks, but full `zig build`/`zig build test` stays on macOS until the Zig 0.16.0 Linux `build-exe` SEGV is fixed upstream. | Medium |

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

### P1: Native MCP Still Future Scope

MCP is not native-complete. It is expected to flow through the TypeScript
extension compatibility layer for now, with native MCP tracked as future scope.

### P2: Continued Extension Edge-Case Verification

The extension registration surface is broad and implemented, with targeted
coverage for dynamic refresh, unregister/re-register ordering, malformed
registration isolation, flag help fallback, and reload cleanup. Remaining work is
ongoing parity hardening as new TypeScript extension behaviors are added.

### P2: Linux CI Full Build/Test Blocked by Zig 0.16.0

`ubuntu-latest` currently keeps the Zig toolchain and external-tool checks in
CI, but skips full `zig build` and `zig build test`.

Reason:

- Zig 0.16.0 terminates with `signal SEGV` while compiling the `pi` executable
  in Debug mode on GitHub-hosted Ubuntu.
- macOS remains the blocking full build/test lane with the same Zig version.

Recommended follow-up:

- Re-enable Linux full build/test after upgrading to a stable Zig release that
  fixes the upstream Linux `build-exe` crash.

## Not Currently Blocking

### Bedrock Stream Contract

Resolved. Bedrock now uses the same non-fallible setup-failure emission shape as
other providers.

### Vertex ADC Auth Detection

Resolved. Zig now checks `GOOGLE_APPLICATION_CREDENTIALS` file existence and
falls back to the default ADC path under the user's home directory.

### Env API Key Mapping

Resolved for the mappings previously identified as missing. The remaining
provider work is ongoing smoke coverage, not env key mappings.

### OpenAI/Codex/Azure Responses Setup Errors

Resolved. Azure Responses and Codex Responses now use the stream wrapper pattern
and have setup-failure tests. OpenAI Responses uses the wrapper pattern and has direct setup-failure smoke coverage.

### Provider Support Helpers

Started. The first provider-internal-shape slices introduced
`zig/src/ai/shared/provider_stream.zig` for common setup failure conversion,
owned request-header insertion/merge/deinit helpers, and normalized response
header callback lookup. The SSE line-support slice added only minimal canonical
`data: ` extraction there, with deterministic helper coverage. The low-risk
Google Generative AI, Google Vertex, Google Gemini CLI, Mistral, OpenAI
Responses, and Azure OpenAI Responses stream entrypoints use the shared stream,
header, and data-line helpers with local capture/on-response/partial-before-error
coverage and Responses request parity coverage. The JSON lifecycle slice added
`shared/provider_json.zig` for
provider-owned JSON object initialization, deep clone, and recursive free
support, then routed provider-local lifecycle helpers through it. Provider-
specific request/response mapping and stream state machines remain in provider
files, and Responses reasoning parsers/finalization fallback, Codex Responses,
Cloudflare/proxy URL behavior, Anthropic/Kimi-compatible tolerance paths,
Bedrock binary event-stream parsing, GitHub Copilot dynamic headers, and
extension protocols remain provider-owned or deferred.

Current provider helper/deferred-path matrix:

| Provider group/path | Helper status | Required local evidence |
| --- | --- | --- |
| Google Generative AI, Google Vertex, Google Gemini CLI, Mistral | Shared setup-error, owned-header, normalized response-header, and canonical SSE `data: ` helpers are adopted for mechanical paths only. | `zig build test-ai` covers local request/header/setup-failure/stream fixtures. |
| OpenAI Responses and Azure OpenAI Responses | Shared setup-error, owned-header, normalized `on_response`, and canonical SSE data-line helpers are adopted. Request/payload mapping, response event mapping, reasoning streaming, and finalization fallback remain provider-owned. | `zig build test-ai` plus `zig build test-openai-responses-parity`. |
| Kimi and Anthropic/Kimi-compatible tolerance | Deferred/provider-owned. Kimi noncanonical `data:` tolerance, malformed JSON repair, unknown/control envelopes, orphan tool deltas, partial EOF finalization, and first-party Anthropic strictness are guarded by focused tests. | `zig build test-ai`, especially the Anthropic/Kimi-compatible parser fixtures in `anthropic.zig`. |
| Bedrock Converse Stream | Deferred/provider-owned. Binary event-stream parsing, partial-block finalization, provider exceptions, and SigV4 signing stay on the Bedrock path. | `zig build test-ai` plus `zig build test-bedrock-parity`. |
| Cloudflare routing and GitHub Copilot dynamic headers | Deferred/provider-owned. Cloudflare base URL/proxy resolution and Copilot initiator/vision headers remain in boundary helpers and request builders. | `zig build test-ai` plus `zig build test-openai-responses-parity` for Responses Copilot scenarios. |

## Recommended Next Work Order

1. Continue native MCP design/implementation planning.
2. Keep adding extension/provider parity regressions as TypeScript behavior evolves.
3. Expand provider smoke matrices for newly registered standalone providers without using real credentials.
4. Re-enable Linux full build/test once a stable Zig compiler release fixes the Ubuntu `build-exe` SEGV.

## Verification Assets

Deterministic fixed-seed fuzz smoke guardrails now cover parser, wire, session,
keybinding, and extension protocol boundaries.

Useful existing harnesses:

- `zig build test`
- `zig build test-coding-agent`
- `zig build test-tui`
- `zig build test-cross-area`
- `zig build test-ts-rpc-parity`
- `zig build test-tidy`
- `zig build test-ai`
- `zig build test-openai-responses-parity`
- `zig build test-bedrock-parity`
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

- keep native MCP as future scope
- continue extension/provider parity hardening as TypeScript behavior evolves
- restore Linux full build/test after the Zig Linux compiler crash is fixed

Forward-looking extension architecture work is tracked separately in
`zig/docs/wasm-extension-roadmap.md`. That roadmap covers the language-neutral
Wasm extension direction inspired by Tree-sitter's declarative source plus
compiled artifact model, while this review remains focused on current
TypeScript parity status.
