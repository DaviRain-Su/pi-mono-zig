# TigerBeetle-Inspired Zig Refactor Plan

This plan adapts TigerBeetle's engineering methods to this Zig implementation. The goal is not to
copy every rule, but to make the refactor measurable, testable, and harder to regress.

## Principles

- Keep parent functions responsible for control flow.
- Move non-branchy logic into focused leaf functions.
- Keep leaf functions pure when state mutation is not required.
- Prefer explicit invariants over implicit assumptions.
- Add guardrails before large refactors, then ratchet them tighter.
- Treat provider contracts, session replay, keybindings, and wire formats as safety boundaries.

## Task List

### 1. Tidy Guardrail

Status: Completed/currently covered.

- Add a Zig tidy step that scans Zig source files.
- Report long functions with file and line locations.
- Start as warning-only to avoid blocking unrelated work.
- Ratchet the threshold down over time.
- Later make selected checks fail in CI.

Acceptance criteria:

- `zig build test-tidy` runs locally.
- The report is deterministic.
- The check does not modify source files.

### 2. Test Root Coverage

Status: Completed/currently covered.

- Extend tidy to find Zig files that contain `test` blocks but are unreachable from known test roots.
- Keep explicit test roots for focused areas such as interactive rendering.
- Add a workflow note: every new split module with tests must be imported by a test root.

Acceptance criteria:

- New module tests cannot silently disappear.
- Rendering-only modules stay covered by `test-tui`.

### 3. Provider Contract Matrix

Status: Completed/currently covered.

- Add a provider stream-contract matrix.
- Assert non-OOM setup/runtime failures become terminal `error_event`.
- Keep API/provider/model metadata checks in the common helper.
- Cover OpenAI, Anthropic, Bedrock, Azure, Codex Responses, Vertex, Google, Mistral, Kimi, and Faux.

Acceptance criteria:

- Every production provider has at least one setup-failure stream test.
- New providers require an explicit matrix entry.

### 4. Wire and Parser Fuzz Smoke

Status: Completed/currently covered. The guardrails are fixed-seed, bounded, and
non-mutating. They currently cover SSE parser chunks, JSON event wire, session
JSONL replay, keybinding parse/match, and extension UI protocol boundaries.

- Add small deterministic fuzz smoke tests for:
  - SSE parser chunks.
  - JSON event wire.
  - session JSONL replay.
  - keybinding parse/match.
  - extension UI protocol.

Acceptance criteria:

- Each fuzzer has a fixed seed smoke mode for CI.
- Failure output includes seed and minimized input where feasible.

## Next Suggested Refactor Step

Continue the screenshot maintainability slices now that the provider registry
boilerplate and the `main.zig` package, run-mode, and extension CLI extraction
slices are complete.
The guarded pure wire/protocol helper extraction and the direct bash subsystem
extraction from `ts_rpc_mode.zig` are now complete. Broader interactive,
extension, provider-parser, and session/RPC decomposition remains later
refactor work.

### 5. Interactive Mode Decomposition

Status: Started/current slice complete. Login/auth flow, session lifecycle, and
slash command routing now live in focused interactive-mode helper modules:
`auth_flow.zig`, `session_lifecycle.zig`, and `command_router.zig`. The parent
interactive loop remains responsible for orchestration, while the extracted
helpers preserve the existing login/logout, session, and command matrix
behavior. Extension bridge coordination remains intentionally deferred because
extension ABI/protocol work is active separately.

- Continue splitting `interactive_mode.zig` by domain:
  - login/auth flow. Completed for the current behavior-preserving slice.
  - session lifecycle. Completed for the current behavior-preserving slice.
  - command routing. Completed for the current behavior-preserving slice.
  - event loop orchestration.
  - extension bridge coordination.
- Keep orchestration functions near the top and push helper logic down or out.

Acceptance criteria:

- New modules have focused tests or are covered by existing focused
  login/logout/session/command fixtures through `zig build test-coding-agent`.
- Event-loop behavior remains covered by existing integration scripts, including
  `test-tui`, `test-vaxis-m8-e2e`, and missing-cwd selector validation.

### 6. Input Dispatch Decomposition

Status: Completed/currently covered for the Task 6 slice. Key-to-action
resolution now lives behind the focused `input_resolution.zig` resolver, while
`input_dispatch.zig` remains the executor/dispatcher for resolved app/editor
actions and input-event message actions. Configured keybindings remain the only
source of non-legacy matching, and legacy defaults are suppressed when an
effective keybinding map rebinds those actions.

- Split key-to-action resolution from action execution. Completed for main
  editor, autocomplete, parsed input-event follow-up/dequeue, and app/editor
  dispatch paths.
- Keep configurable keybindings as the only source of key matching. Covered by
  resolver tests plus existing input-dispatch configured/rebound behavior tests.
- Add compile-time or tidy checks for `Action` coverage where practical. The
  main app-action executor now uses an exhaustive `Action` switch with explicit
  no-op coverage for overlay-scoped actions, so adding an action requires
  dispatch review at compile time.
- Leave overlay-internal selector key execution behavior-preserving in this
  slice; broader extension bridge coordination and extension ABI/protocol
  refactors remain deferred to their own follow-up work.

Acceptance criteria:

- No hardcoded key checks are introduced.
- Adding an `Action` forces review of dispatch coverage.
- Focused validation: `zig build test-coding-agent` covers resolver behavior,
  configured bindings, rebound old defaults, and dispatch-event message actions.

### 7. Provider Internal Shape

Status: Started/current stream setup-error, owned-header, canonical SSE
data-line, and JSON value lifecycle helper slices complete for low-risk
local-fixture provider paths. `shared/provider_stream.zig` now owns the common
non-OOM setup failure to terminal `error_event` conversion, owned request-header
insertion/merge/deinit helpers, and normalized response header callback lookup
support, plus minimal canonical `data: ` SSE line extraction. Google Generative
AI, Google Vertex, Google Gemini CLI, Mistral, OpenAI Responses, and Azure
OpenAI Responses stream entrypoints use these shared helpers. The current JSON
slice added `shared/provider_json.zig` for provider-owned object
initialization, deep clone, and recursive free support, with provider-local
lifecycle wrappers routed through the shared helper while keeping request
payloads, provider/auth headers, stream state machines, JSON event mapping, and
response mapping provider-local. Responses request/payload mapping, response
event mapping, reasoning parsers and finalization fallbacks, Cloudflare/proxy URL
behavior, Codex Responses, Anthropic/Kimi-compatible tolerance paths, Bedrock
binary event-stream parsing, GitHub Copilot dynamic headers, and extension
ABI/protocols were intentionally left provider-owned or deferred in these slices.

- Move shared HTTP, payload, SSE, and error-conversion helpers into provider support modules.
- Keep provider-specific files focused on API-specific request/response mapping.
- Use the common stream-contract/header/canonical SSE data-line helpers where
  behavior is mechanical. Started with Google Generative AI and Mistral, then
  extended to Google Vertex and Google Gemini CLI with local request,
  normalized-response-header, setup-failure, and partial-before-error coverage.
  The Responses-family mechanical slice then extended OpenAI Responses and Azure
  OpenAI Responses to shared setup-error, owned-header, normalized `on_response`,
  and canonical SSE data-line helpers while preserving the 53-scenario local
  Responses request parity fixtures and provider-owned reasoning/event mapping.
  Later slices should convert additional providers only with local
  request/response fixture coverage.
- Use the common provider JSON lifecycle helpers for mechanical clone/free/empty
  object ownership only; keep buildRequestPayload and response mapping logic in
  provider files.

Converted/deferred provider matrix:

| Provider group/path | Current status | Guardrail evidence |
| --- | --- | --- |
| Google Generative AI, Google Vertex, Google Gemini CLI | Converted to shared setup-error, owned-header, normalized response-header, and canonical SSE `data: ` helpers where behavior is mechanical. Provider auth, request payload, and response mapping stay provider-local. | `cd zig && zig build test-ai`; Google-family request, on-response, setup-failure, and partial-before-error fixtures. |
| Mistral | Converted to shared setup-error, owned-header, normalized response-header, and canonical SSE `data: ` helpers. Provider-specific stream mapping stays in `mistral.zig`. | `cd zig && zig build test-ai`; Mistral local stream/helper fixtures. |
| OpenAI Responses and Azure OpenAI Responses | Converted only for mechanical setup-error, owned-header, normalized `on_response`, and canonical SSE data-line helpers. Request/payload mapping, response event mapping, reasoning parsers, and finalization fallback remain provider-owned. | `cd zig && zig build test-ai`; `cd zig && zig build test-openai-responses-parity`. |
| Kimi and Anthropic/Kimi-compatible tolerance | Deferred/provider-owned. Do not replace Kimi noncanonical SSE tolerance or Anthropic-compatible repair behavior with generic canonical SSE handling without a separate assignment and local fixtures. | `cd zig && zig build test-ai`; Kimi repair, noncanonical chunk, orphan tool delta, partial EOF, and first-party Anthropic strictness tests in `anthropic.zig`. |
| Bedrock Converse Stream | Deferred/provider-owned. Do not extract binary event-stream parsing/signing into generic stream helpers in this phase. | `cd zig && zig build test-ai`; `cd zig && zig build test-bedrock-parity`; Bedrock binary event-stream and SigV4 fixtures. |
| Cloudflare routing and GitHub Copilot dynamic headers | Deferred/provider-owned. Cloudflare/proxy URL resolution and Copilot dynamic header inference stay in provider boundary helpers and provider request builders. | `cd zig && zig build test-ai`; `cd zig && zig build test-openai-responses-parity`; Cloudflare provider smoke and Copilot dynamic-header fixtures. |

Acceptance criteria:

- Provider setup paths are contract-uniform.
- Shared helpers have direct unit tests.
- Current Google-family slice verification: `cd zig && zig build test-ai`,
  `cd zig && zig build test-coding-agent`, and `npm run check`.
- Current Responses-family slice verification: `cd zig && zig build test-ai`,
  `cd zig && zig build test-openai-responses-parity`, and `npm run check`.
- Deferred-path guardrail slice verification: `cd zig && zig build test-ai`,
  `cd zig && zig build test-openai-responses-parity`,
  `cd zig && zig build test-bedrock-parity`, and `npm run check`.

### 8. Screenshot Maintainability Slices

Status: Started/current `register_builtins.zig`, `main.zig` package-command
plus run-mode dispatch, `main.zig` extension flag/registry-dump dispatch, the
first guarded `ts_rpc_mode.zig` wire helper slice, and the TS-RPC direct bash
subsystem slice complete.
`zig/src/ai/providers/register_builtins.zig` now uses a single provider
metadata table to generate the built-in API list, built-in provider registry
entries, lazy-load state lookup, test override lookup, and comptime stream /
streamSimple dispatch wrappers. The public registry helpers, built-in API
ordering/count, uniqueness, lazy-load state semantics, `setProviderOverride`,
`isLoaded`, and provider stream contract matrix behavior are preserved.
`main.zig` now delegates pre-parse package-command handling to
`zig/src/cli/package_command_dispatch.zig`, preserving the `runCli` call
surface while keeping package command detection, cwd/agent-dir resolution,
package-manager invocation options, stdout/stderr routing, and exit-code
mapping in a focused helper.
`main.zig` now also delegates prepared CLI run-mode dispatch to
`zig/src/cli/run_mode_dispatch.zig`, preserving interactive vs print/json/RPC/
TS-RPC selection, the post-runtime non-interactive missing-cwd preflight before
provider/auth/tool setup, RPC/TS-RPC routing, stdout/stderr routing, and
exit-code behavior.
`main.zig` now also delegates extension CLI sidecar flag registry loading,
unknown long-flag validation, parsed extension flag value retention, registry
dump enablement checks, and live extension host registry dumping to
`zig/src/cli/extension_cli.zig`. The parent CLI still owns top-level argument
precedence, help/version ordering, package pre-dispatch, missing-cwd preflight,
and run-mode orchestration; the helper owns the focused extension flag/dump
boundary while preserving registry dump JSON, stdout/stderr, exit codes, and
extension host shutdown diagnostics.
`ts_rpc_mode.zig` now delegates focused wire/protocol helpers to
`zig/src/coding_agent/ts_rpc_wire.zig`: known command metadata, LF/CR input
framing, TypeScript-shaped JSON parse diagnostics, base response frame
serialization, JSON string escaping, and extension UI request frame
serialization.
`ts_rpc_mode.zig` now also delegates direct bash task/result/output reader
state, UTF-8 sanitization, retained-log/truncation handling, process execution,
and cancellation lifecycle helpers to
`zig/src/coding_agent/modes/ts_rpc_bash.zig`. The server still owns command
dispatch, deferred response priority/flush policy, session lifecycle, and
extension host request correlation/cancel/timeout behavior.
`openai.zig` now delegates OpenAI Chat request/message payload construction to
`zig/src/ai/providers/openai_chat_payload.zig`: system/developer/user/
assistant/tool-result message conversion, tool-call argument/id normalization,
cache-retention payload fields, compat payload switches, and request snapshot
payload parity helpers live behind that focused boundary. `openai.zig` still
owns provider authentication, request headers, URL/Cloudflare/Copilot routing,
HTTP streaming, response callbacks, stream contracts, and the OpenAI Chat SSE
parser/state machine.

Remaining boundaries:

- Further `ts_rpc_mode.zig` decomposition remains deferred beyond these guarded
  wire/protocol and direct-bash helper extractions. Do not move extension
  ABI/protocol, session lifecycle, extension UI response/cancel/timeout
  behavior, deferred queue ordering, or broad command dispatch without a
  separately assigned guarded slice.
- OpenAI Chat SSE parser extraction remains deferred. Do not move
  `parseSseStreamLines` or related streaming response state out of `openai.zig`
  without a separately assigned parser-focused slice and local parity fixtures.
- Broad interactive-mode, extension-registry, provider parser/state-machine,
  session, build-graph, and extension ABI/interface decomposition remains
  deferred unless assigned explicitly.

Acceptance criteria:

- `register_builtins.zig` metadata drives all built-in registry outputs and
  dispatch wrappers without provider-specific override or `isLoaded` chains.
- Focused tests prove built-in API order, count, uniqueness, override clearing,
  per-provider lazy-load state, and stream/streamSimple wrapper coverage.
- `main.zig` delegates package-command dispatch before standard CLI parsing,
  and focused tests prove package help precedence plus cwd/agent-dir scope
  resolution through the extracted helper.
- `main.zig` delegates prepared run-mode dispatch after initial input
  preparation, and focused tests prove RPC/TS-RPC prompt and `@file`
  restrictions remain pre-runtime while parity validators cover print/json/RPC/
  TS-RPC flow behavior.
- `main.zig` delegates extension flag preprocessing and registry dumping to a
  focused CLI helper, and focused tests prove sidecar flag help/preprocessing,
  unknown flag diagnostics, dump enablement checks, live registry snapshots,
  unregister behavior, and shutdown-failure diagnostics remain unchanged.
- Verification for the completed provider registry slice:
  `cd zig && zig build test-ai`,
  `cd zig && zig build test-coding-agent`, and `npm run check`.
- Verification for the completed package-dispatch slice:
  `cd zig && zig build test` and `npm run check`.
- Verification for the completed run-mode dispatch slice:
  `cd zig && zig build test`,
  `cd zig && zig build test-cross-area`,
  `cd zig && zig build test-ts-rpc-parity`, and `npm run check`.
- Verification for the completed first TS-RPC wire helper slice:
  `cd zig && zig build test-coding-agent`,
  `cd zig && zig build test-ts-rpc-parity`, and `npm run check`.
- Verification for the completed TS-RPC direct bash subsystem slice:
  `cd zig && zig build test-coding-agent`,
  `cd zig && zig build test-ts-rpc-parity`,
  `cd zig && zig build test-tidy`, and `npm run check`.
- Verification for the completed OpenAI Chat payload boundary:
  `cd zig && zig build test-ai`,
  `cd zig && zig build test-openai-chat-parity`,
  `cd zig && zig build test-tidy`, and `npm run check`.
- Verification for the completed main CLI extension flag/registry-dump slice:
  `cd zig && zig build test`,
  `cd zig && zig build test-ts-rpc-parity`,
  `cd zig && zig build test-tidy`, and `npm run check`.

### 9. Session and RPC Decomposition

- Split session parse, replay, persistence, compaction, and display formatting.
- Split `ts_rpc_mode.zig` by wire encoding, session lifecycle, extension UI bridge, and command handling.

Acceptance criteria:

- Session replay tests cover old and current JSONL shapes.
- RPC wire tests stay byte- or semantic-parity checked against TypeScript fixtures.

## Ratchet Policy

The tidy step starts with warnings. A check becomes blocking only after:

- The current codebase is below the threshold.
- CI has run the warning-only version for at least one cycle.
- The threshold is documented in this file.

Initial thresholds:

- Function length warning: greater than 160 lines.
- Future target: 120 lines, then 90 lines for new code.

