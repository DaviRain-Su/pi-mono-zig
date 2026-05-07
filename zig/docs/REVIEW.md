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
- interactive input dispatch has a distinct key-resolution module, a focused
  overlay-input helper for model/session/tree/scoped-model selector keys, and an
  exhaustive app-action executor, preserving configurable keybinding behavior
- active-operation status rendering has a focused formatting helper for spinner,
  elapsed, retry countdown, and cancel/interrupt hint text while the render
  pipeline remains owned by `rendering.zig`
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
- built-in provider registry boilerplate in `register_builtins.zig` is now
  metadata-driven: one table generates the built-in API list, registry entries,
  lazy-load state lookup, test override lookup, and comptime stream /
  streamSimple dispatch wrappers while preserving public registry behavior
- package-command dispatch is now isolated in `cli/package_command_dispatch.zig`
  so `main.zig` keeps pre-parse package precedence without owning cwd,
  agent-dir, package-manager invocation, stdout/stderr, and exit-code plumbing
- prepared CLI run-mode routing is now isolated in `cli/run_mode_dispatch.zig`
  so `main.zig` keeps the runCli orchestration boundary while print/json/RPC/
  TS-RPC/interactive dispatch, prepared missing-cwd preflight, session opening,
  stdout/stderr routing, and exit-code behavior live in a focused helper
- extension CLI sidecar flag preprocessing and live registry dumping are now
  isolated in `cli/extension_cli.zig` so `main.zig` preserves top-level
  argument precedence and run-mode orchestration without owning extension flag
  registry state, parsed flag retention, registry dump enablement, or extension
  host setup/shutdown diagnostics
- TS-RPC direct bash execution is now isolated in `modes/ts_rpc_bash.zig`,
  preserving the server-owned command dispatch, deferred queue ordering, and
  TS-RPC wire response boundary
- TS-RPC state/model/message JSON writing and parsing helpers are now isolated
  in `modes/ts_rpc_state_json.zig`, preserving exact response bytes, queue
  text arrays, image payload parsing, and server-owned command/extension UI
  ordering in `ts_rpc_mode.zig`
- OpenAI Chat request/message payload construction is now isolated in
  `providers/openai_chat_payload.zig`, preserving request JSON parity,
  tool-call normalization, cache-retention payload behavior, and provider-owned
  stream/SSE parser behavior in `openai.zig`
- package config selector state, settings-backed load/save, TUI rendering, and
  keyboard navigation are now isolated in
  `coding_agent/packages/config_selector.zig`, preserving package command
  parsing, non-interactive config toggles, config persistence, stdout/stderr,
  and exit-code behavior in `package_manager.zig`
- session JSONL header/entry data types, parse/write codec helpers,
  message/content JSON conversion, and owned-value cleanup/clone helpers are
  now isolated in `coding_agent/sessions/session_jsonl.zig`, preserving
  storage bytes, replay/search/tree/fork/context behavior, parent metadata, and
  corrupted-line compatibility policy in `session_manager.zig`
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

### Register Built-ins Metadata Dispatch

Resolved for the current maintainability slice. `register_builtins.zig` no
longer keeps separate state variables, override fields, loader functions, and
stream/streamSimple wrapper functions for every built-in provider. A single
provider metadata table now drives:

- built-in API list generation
- built-in provider registry entry generation
- lazy-load state indexing
- test override lookup/clearing
- comptime-generated stream and streamSimple dispatch wrappers

Focused tests pin the built-in API count/order/uniqueness, registry entry order,
override clearing, per-provider lazy-load semantics, and stream/streamSimple
wrapper coverage for every built-in provider. Later screenshot maintainability
boundaries are intentionally separate and recorded below.

### CLI Package Command Dispatch

Resolved for the current maintainability slice. `main.zig` now delegates
pre-parse package command handling to `cli/package_command_dispatch.zig`.
The extracted helper owns package-command detection, parse/execute handoff,
cwd override or real-cwd resolution, `PI_CODING_AGENT_DIR`/agent-dir
resolution, stdout/stderr forwarding, TTY detection, and exit-code mapping.

Focused tests prove non-package argv returns to normal CLI parsing, local and
user package scopes still use cwd and agent-dir paths correctly, and `runCli`
still routes `pi install --help` to package-command help before the normal CLI
parser can treat it as top-level help or prompt input. The follow-up run-mode
routing slice is recorded below.

### Package Config Selector Boundary

Resolved for the current large-file decomposition slice. The bare `pi config`
interactive selector now lives in `coding_agent/packages/config_selector.zig`.
The helper owns `ConfigKind`, selector entries/state, settings-backed selector
load/save, vaxis rendering, and key handling for Up/Down, Space, Enter, Esc,
`q`, and Ctrl-C. `package_manager.zig` still owns parse/dispatch, non-TTY config
listing, `--toggle` behavior, package install/list/remove/update/self-update
logic, stdout/stderr, and exit codes.

Existing package-manager config selector tests continue to exercise selector
navigation, toggle/save/cancel behavior, scope handling, and stdout/stderr
fallback behavior through `zig build test-coding-agent`.

### Session JSONL Codec Boundary

Resolved for the current large-file decomposition slice. Session JSONL header
and entry data types, exact-line serialization, line parsing, message/content
JSON conversion, compaction summary encoding, custom message payload handling,
and related owned-value cleanup/clone helpers now live in
`coding_agent/sessions/session_jsonl.zig`.

`session_manager.zig` still owns session creation/opening, persistence timing,
corrupted-line warning output, label maps, replay ordering, search indexing,
tree/fork mutation, context reconstruction, missing-cwd integration, and
session lifecycle orchestration. Focused codec tests pin representative
existing JSONL lines byte-for-byte, while session-manager tests continue to
cover replay, search, labels, branch summaries, custom entries, context
exclusion, corruption tolerance, and tree/fork behavior.

### CLI Run Mode Dispatch

Resolved for the current maintainability slice. `main.zig` now delegates the
prepared CLI execution branch to `cli/run_mode_dispatch.zig`. The extracted
helper owns print/json prompt validation, the post-runtime non-interactive
missing-cwd preflight, provider/auth resolution, non-interactive session
opening, interactive launch options, print/json/RPC/TS-RPC dispatch, TS-RPC
extension-host options, stdout/stderr forwarding, and returned exit codes.

The early pre-runtime missing-cwd preflight and RPC/TS-RPC prompt/`@file`
restrictions remain in `main.zig` before runtime preparation, preserving their
ordering relative to provider/resource failures. Focused tests pin those
RPC/TS-RPC restrictions while the cross-area and TS-RPC parity validators cover
the black-box routing behavior. The remaining screenshot maintainability
boundary has started with the guarded pure wire/protocol extraction from
`ts_rpc_mode.zig`: `coding_agent/ts_rpc_wire.zig` owns known command metadata,
input CR/LF framing, TypeScript-shaped parse diagnostics, response frame
serialization, JSON string escaping, and extension UI request frame
serialization. Broader `ts_rpc_mode.zig` command dispatch, session lifecycle,
and extension UI correlation/cancel/timeout handling remain deferred.

### CLI Extension Flag and Registry Dump Boundary

Resolved for the current maintainability slice. `main.zig` now delegates
extension sidecar flag registry loading, help flag snapshot conversion, unknown
long-flag validation, parsed CLI flag value retention for extension state, and
the live M11 extension registry dump path to `cli/extension_cli.zig`.

The extracted helper owns registry dump enablement checks, runtime argv/cwd
preparation, host ready/drain/shutdown handling, parsed flag application into
the live registry, JSON snapshot writing, and shutdown-failure diagnostics.
`main.zig` still owns package-command precedence, top-level help/version
ordering, export/list-model routing, missing-cwd preflight, and the prepared
run-mode dispatch boundary. Focused helper tests and existing `runCli` tests
pin sidecar flag help/preprocessing, unregistered flag diagnostics, live
registry snapshot JSON, unregister behavior, stdout/stderr, exit codes, and the
shutdown-failure path.

### TS-RPC Direct Bash Boundary

Resolved for the current maintainability slice. `ts_rpc_mode.zig` now delegates
direct bash task/result/output reader state, UTF-8 sanitization, retained-log
and truncation handling, process execution, and cancellation lifecycle helpers
to `coding_agent/modes/ts_rpc_bash.zig`. `ts_rpc_mode.zig` still owns the
`bash` / `abort_bash` command dispatch points, response framing callbacks,
deferred response priority/flush ordering, session replacement ordering, and
extension host event loop semantics.

Focused coding-agent tests continue to pin exact BashResult bytes,
sanitization, truncation/retained logs, cancellation cleanup, live command-loop
behavior, and the generated TypeScript bash-control fixture. The live TS-RPC
parity harness remains the black-box guardrail for TS-vs-Zig direct bash wire
bytes.

### TS-RPC State/Message JSON Boundary

Resolved for the current large-file decomposition slice. `ts_rpc_mode.zig` now
delegates state, message, model, available-model, compaction-result,
session-stat, fork-message, queue-text, thinking/queue-name, and image payload
JSON helpers to `coding_agent/modes/ts_rpc_state_json.zig`.

`ts_rpc_mode.zig` still owns command dispatch, response framing, deferred
response priority and flush ordering, direct bash routing, session replacement,
and extension UI request/response correlation. Focused helper tests pin stable
model JSON and image parsing, while coding-agent and TS-RPC parity fixtures
continue to guard exact public bytes, deferred queue behavior, direct bash
boundaries, and extension UI flow ordering.

### OpenAI Chat Payload Boundary

Resolved for the current maintainability slice. `openai.zig` now delegates
OpenAI Chat request/message payload construction to
`providers/openai_chat_payload.zig`. The helper owns system/developer/user/
assistant/tool-result message JSON construction, tool-call id/argument
normalization, cache-retention payload fields, compat payload switches, and the
OpenAI Chat request snapshot payload helper used by parity fixtures.

`openai.zig` still owns provider authentication, request headers, request URL
construction, Cloudflare/Copilot routing, HTTP streaming, `on_response`, stream
contract error mapping, and the OpenAI Chat SSE parser/state machine. Chat SSE
parser extraction remains explicitly deferred to a parser-focused slice with
local parity fixtures.

### Extension Registry Snapshot Boundary

Resolved for the current large-file decomposition slice.
`extension_registry.zig` now delegates deterministic registry snapshot JSON
construction to `extensions/extension_registry_snapshot.zig`. The helper owns
snapshot root assembly, per-surface JSON value construction, optional string
fields, flag/default value conversion, injection hook serialization, and owned
JSON value cleanup used by CLI/TS-RPC registry dumps.

`extension_registry.zig` still owns registry mutation APIs, host frame
application, provider/tool/command/shortcut/flag/capability/widget
registration, unregister behavior, provider auth-state registration, UI hook
lifecycle mutation, command resolution, and runtime-facing surface counts.
Further registry extraction remains deferred to separately guarded slices so
extension ABI/protocol and runtime lifecycle behavior stay unchanged.

### Overlay Input Boundary

Resolved for the current large-file decomposition slice.
`input_dispatch.zig` now delegates model, session, tree, and scoped-model
overlay-specific interactive key handling to `interactive_mode/overlay_input.zig`.
The helper owns overlay search editing, configured overlay action matching,
model scope toggling, session sort/scope/path/rename/delete navigation,
scoped-model toggle/reorder/save handling, and tree filter/fold/label/summary
key handling.

`input_dispatch.zig` still owns main `handleInputKeyWithModifiers` orchestration,
selector commit side effects, editor submission, broad app-action dispatch,
queue/dequeue behavior, auth-flow input, and extension-dialog routing. Further
input-dispatch decomposition remains deferred to separately guarded slices.

### Active Operation Rendering Boundary

Resolved for the current large-file decomposition slice.
`rendering.zig` now delegates pure active-operation display formatting to
`interactive_mode/active_operation_rendering.zig`. The helper owns active
operation display kinds/snapshots, spinner frame selection, elapsed-time
calculation, retry countdown text, and interrupt/cancel hint formatting.

`rendering.zig` still owns `AppState`, active-operation lifecycle mutation,
screen/task/footer drawing, terminal layout, markdown/chat rendering, and
completion cleanup. Further rendering decomposition remains deferred to
separately guarded slices.

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
