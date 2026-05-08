# Test Coverage Matrix

This file tracks per-provider × per-scenario test coverage. Cells were audited
against current local Zig tests on 2026-05-08; see the evidence notes below for
the test roots that justify confirmed coverage and N/A decisions.

## Legend
- ✅ — covered by an existing test
- Deferred — intentional lower-priority gap with explicit follow-up/rationale
- N/A — feature not supported by this provider (document why)

## Scenarios

| # | Scenario |
|---|---|
| S1 | Text-only stream |
| S2 | Text + thinking/reasoning stream |
| S3 | Tool-call only |
| S4 | Tool-call + thinking |
| S5 | Multiple tool calls in single stream |
| S6 | Stream aborts mid-event |
| S7 | Malformed JSON tool args (recovery to `{}`) |
| S8 | Provider error frame (non-200) |
| S9 | Empty / zero-event success |
| S10 | Compact `data:{...}` SSE line |
| S11 | OAuth / dynamic header path |
| S12 | Stop reason coercion (.stop → .tool_use when tool_calls present) |
| S13 | content_index stability across block start/stop/start |
| S14 | Leak-tracking allocator passes (no leaks) |
| S15 | EOF mid-block tolerance |

## Matrix

| Provider | S1 | S2 | S3 | S4 | S5 | S6 | S7 | S8 | S9 | S10 | S11 | S12 | S13 | S14 | S15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| anthropic | ✅ | ✅ | Deferred | ✅ | Deferred | ✅ | Deferred | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| openai_responses | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Deferred | ✅ | Deferred | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| openai_codex_responses | ✅ | ✅ | ✅ | Deferred | Deferred | ✅ | Deferred | ✅ | Deferred | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| azure_openai_responses | ✅ | ✅ | ✅ | Deferred | Deferred | ✅ | Deferred | ✅ | Deferred | ✅ | N/A | ✅ | ✅ | ✅ | ✅ |
| openai_chat_sse | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Deferred | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| bedrock | ✅ | ✅ | ✅ | ✅ | Deferred | ✅ | Deferred | ✅ | Deferred | N/A | N/A | ✅ | ✅ | ✅ | ✅ |
| google | ✅ | ✅ | ✅ | ✅ | Deferred | ✅ | Deferred | ✅ | Deferred | ✅ | N/A | ✅ | ✅ | ✅ | ✅ |
| google_vertex | ✅ | ✅ | ✅ | ✅ | Deferred | ✅ | Deferred | ✅ | Deferred | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| google_gemini_cli | ✅ | ✅ | ✅ | ✅ | Deferred | ✅ | Deferred | ✅ | Deferred | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| mistral | ✅ | ✅ | ✅ | ✅ | Deferred | ✅ | Deferred | ✅ | Deferred | ✅ | N/A | ✅ | ✅ | ✅ | ✅ |
| kimi | ✅ | ✅ | ✅ | ✅ | Deferred | ✅ | Deferred | ✅ | Deferred | ✅ | N/A | ✅ | ✅ | ✅ | ✅ |
| cloudflare | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | ✅ | N/A | N/A | N/A | N/A |
| faux | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | N/A | N/A | ✅ | N/A | N/A | N/A | N/A | ✅ | N/A |

## Evidence notes

- `anthropic`: `anthropic.zig` covers text, compact lines, provider error,
  empty-success erroring, thinking+tool, Kimi-compatible repair/tolerance,
  content-index stability, partial EOF, setup/on-payload/on-response failure,
  pre-abort and mid-stream abort, Cloudflare/Copilot-style header paths, and explicit stop-reason
  coercion via `parse anthropic stream coerces end_turn to tool_use when tool
  calls are present`. Standalone first-party tool-only, multiple tool calls,
  and malformed tool-argument recovery remain deferred lower-priority coverage;
  Kimi-compatible repair paths remain covered separately in `anthropic.zig`.
- `openai_responses`: `openai_responses.zig` covers text, reasoning deltas,
  tool calls, multiple/interleaved tool calls, canonical compact-line strictness,
  HTTP/provider errors, Copilot dynamic headers, stop-reason coercion through
  finalized tool output, content-index stability, setup/pre-abort/mid-stream abort paths, and
  EOF mid-block tool-call finalization, leak-tracked parser fixtures, and
  reasoning-plus-multi-tool success through
  `ISS-011 parseSseStreamLines keeps encrypted reasoning with multi-tool outputs`.
  Empty successful streams and malformed tool-arg recovery remain deferred
  lower-priority parser fixtures.
- `openai_codex_responses`: `openai_codex_responses.zig` covers text,
  reasoning, canonical compact-line strictness, account/auth request shaping,
  HTTP/setup/on-payload/on-response errors, content-index stability across
  text/tool/text output items, and stop-reason coercion through
  `finalizeCollectedOutput preserves Codex finalization semantics`, and
  mid-stream abort with partial text preservation. S15 is covered by Codex
  Responses EOF mid-tool finalization. Thinking+tool, multiple tool calls,
  malformed tool-arg recovery, and empty-success behavior are deferred because
  they duplicate shared Responses parser semantics unless a Codex-specific
  regression appears.
- `azure_openai_responses`: `azure_openai_responses.zig` covers text,
  reasoning, canonical compact-line strictness, partial terminal error ordering,
  HTTP/setup errors, static Azure auth header handling, and leak-tracked
  finalization, including content-index stability across text/tool/text output
  items, mid-stream abort with partial text preservation, and stop-reason
  coercion through `finalizeCollectedOutput preserves Azure finalization
  semantics`. S15 is covered by Azure Responses EOF mid-tool finalization.
  Azure has no distinct OAuth/dynamic-header S11 path; broader thinking+tool,
  multi-tool, malformed-argument, and empty-success coverage is deferred because
  the shared Responses parser already carries the generic success/error paths.
- `openai_chat_sse`: `openai.zig` and `openai_chat_sse.zig` cover text,
  reasoning, tool-only, mixed thinking/text/tool, multiple interleaved tool
  calls, mid-stream abort, HTTP errors, empty usage-only success, compact
  `data:{...}` lines, Cloudflare/Copilot routing, and stop-reason coercion.
  S13 is covered by `openai_chat_sse keeps text content indexes stable around
  tool boundaries`: although Chat Completions lacks explicit block lifecycle
  events, the Zig parser now treats a tool-call delta as a text boundary for
  plain text/tool/text streams, emits `text_end` before `toolcall_start`, and
  reopens later text at a new stable content index. Mixed reasoning streams
  remain on the legacy parity path because closing text while reasoning is
  concurrently open changes established OpenAI-compatible ordering. S15 is
  covered by an EOF text+tool partial-stream fixture. Malformed
  tool-argument recovery has parser code but its dedicated provider fixture is
  deferred until a Chat-specific regression requires it.
- `bedrock`: `bedrock.zig` covers raw and binary Bedrock streams with text,
  thinking, tool-only, mixed thinking/text/tool, provider exceptions, HTTP
  status errors, abort finalization, explicit stop-reason coercion through
  `parseEventStreamFrames coerces end_turn to tool_use when tool calls are
  present`, content-index stability across thinking/text/tool/text block
  indexes, and EOF/invalid-terminal partial handling. SSE compact lines and
  OAuth/dynamic headers are N/A for Bedrock's binary/raw event-stream path.
  Multi-tool, malformed-argument, and empty-success fixtures remain deferred
  because the binary event-stream path already has representative tool/error
  coverage and no user-facing regression for those lower-priority shapes.
- `google`, `google_vertex`, `google_gemini_cli`: the Google-family files cover
  text or mixed response parsing, thinking+tool flows, HTTP/setup/auth errors,
  canonical compact-line strictness, partial terminal errors, mid-stream aborts, and
  Google/Vertex/Gemini CLI stop-reason coercion. Their mixed parser fixtures
  now assert stable thinking/tool/text content indexes, and EOF mid-text
  fixtures finalize partial output without a terminal `[DONE]`. Vertex and Gemini CLI have
  credential/OAuth-like header paths; plain Google API-key auth does not have a
  distinct S11 path. Multiple tool calls, malformed tool args, and empty-success
  fixtures remain deferred lower-priority coverage for each Google-family entry.
- `mistral`: `mistral.zig` covers text, mixed thinking+tool, HTTP/setup errors,
  canonical compact-line strictness, content-index stability across
  thinking/tool/text blocks, stop-to-tool-use coercion in `parse stream emits
  thinking and tool call events`, partial terminal errors, and mid-stream
  abort with partial text preservation. S15 is covered by an EOF text+tool
  partial-stream fixture. Multiple tools, malformed tool-arg recovery, and
  empty-success behavior remain deferred lower-priority coverage. Mistral S11 is N/A because the Zig
  provider uses API-key/static-auth request shaping and has no distinct OAuth
  or dynamic-header path.
- `kimi`: `kimi.zig` covers thinking+text, tool-only, compact data lines, HTTP
  and setup errors, standalone stop-reason coercion, partial terminal errors,
  and mid-stream abort with partial text preservation. Kimi
  Anthropic-compatible tolerance is covered in `anthropic.zig`. Standalone Kimi
  S15 is covered by an EOF text+tool partial-stream fixture.
  Standalone Kimi content-index stability is
  covered by a thinking/tool/text fixture. Kimi S11 is N/A because standalone
  Kimi API-key auth does not have a separate OAuth or dynamic-header code path.
  Standalone multi-tool, malformed-argument, and empty-success fixtures remain
  deferred lower-priority coverage because the active Kimi regressions are in
  the Anthropic-compatible path and already have focused fixtures.
- `cloudflare`: Cloudflare is a routing/helper surface over OpenAI/Anthropic
  compatible providers, not an independent stream parser. `cloudflare.zig`,
  `provider_smoke_test.zig`, `openai.zig`, and `anthropic.zig` cover provider
  recognition, environment placeholder substitution/failure, Gateway routing,
  auth metadata, and terminal setup errors. Provider HTTP/error-frame semantics
  are carried by the routed OpenAI/Anthropic rows, so Cloudflare S8 is N/A.
- `faux`: `faux.zig` covers queued text, inline-only tool-call events,
  text/thinking/tool aborts, explicit aborted assistant messages, and
  leak-tracked in-memory streaming. Its ISS-110 fixture asserts final faux
  assistant messages keep tool calls inline and leave legacy `tool_calls` null.
  `review matrix faux streams thinking multiple tools and empty success` covers
  success thinking, thinking+tool, multiple tool calls, and empty success.
  Parser-specific malformed JSON, SSE compact lines, provider error frames,
  OAuth/dynamic-header paths, stop-frame coercion, content-index reuse, and
  EOF-mid-block scenarios are N/A for the in-memory faux provider.
- `S14 leak tracking`: `provider_tool_call_ownership_matrix_test.zig` drives
  every built-in production provider plus faux/Kimi-compatible fixture entries
  through local tool-call streams under a debug allocator. It asserts
  normalized providers keep inline-only ownership, the OpenAI Chat-compatible
  legacy exception keeps separately allocated copies, and all per-event/message
  allocations are released. Faux is covered as an inline-only in-memory
  provider, not a legacy exception. Cloudflare is N/A for S14 because it is a routing
  helper surface with no independent assistant-message stream ownership; the
  routed OpenAI/Anthropic provider rows carry the ownership coverage.

## Deferred coverage ledger

All deferred cells are lower-priority local-fixture follow-ups. They are not
unknown cells, and `zig build test-tidy` now fails if the matrix regresses to an
unclassified missing/partial/unknown marker in the provider table.

| Provider | Deferred scenarios | Rationale / owner |
|---|---|---|
| anthropic | S3, S5, S7 | First-party Anthropic already has mixed thinking+tool, stop/coercion, EOF, abort, compact-line, and error coverage. Tool-only/multi-tool/malformed-argument first-party fixtures are lower-priority because Kimi-compatible repair/tolerance paths carry the active regression coverage. Tracked by ISS-603. |
| openai_responses | S7, S9 | Shared Responses parser has rich text/reasoning/tool/multi-tool coverage; malformed-argument and empty-success edge cases are deferred until they expose a provider-specific behavior difference. Tracked by ISS-603. |
| openai_codex_responses | S4, S5, S7, S9 | Codex has account/auth and shared Responses finalization coverage. Complex thinking+tool, multiple tool, malformed-argument, and empty-success Codex-specific fixtures are deferred because generic Responses semantics are already covered elsewhere. Tracked by ISS-603. |
| azure_openai_responses | S4, S5, S7, S9 | Azure has auth/setup/error/reasoning/finalization coverage. Complex tool/reasoning and empty/malformed parser shapes duplicate shared Responses parser semantics unless an Azure-specific regression appears. Tracked by ISS-603. |
| openai_chat_sse | S7 | Chat SSE malformed-argument fallback has parser code and broad tool coverage; a dedicated provider fixture remains deferred until a Chat-specific failure shape is found. Tracked by ISS-603. |
| bedrock | S5, S7, S9 | Bedrock binary/raw event-stream fixtures cover representative tool, thinking, error, EOF, and abort paths. Additional multi-tool, malformed-argument, and empty-success binary fixtures are deferred lower-priority work. Tracked by ISS-603. |
| google / google_vertex / google_gemini_cli | S5, S7, S9 | Google-family parsers have text, thinking+tool, auth/setup/error, compact-line, abort, stop, content-index, and EOF coverage. Multiple tool, malformed-argument, and empty-success fixtures are deferred for future local-fixture expansion. Tracked by ISS-603. |
| mistral | S5, S7, S9 | Mistral has text, thinking+tool, setup/error, compact-line, content-index, stop, abort, and EOF coverage. Multiple tool, malformed-argument, and empty-success fixtures remain deferred lower-priority tests. Tracked by ISS-603. |
| kimi | S5, S7, S9 | Standalone Kimi has text/thinking/tool/error/abort/EOF coverage; active malformed/noncanonical Kimi regressions live in the Anthropic-compatible Kimi path and have focused fixtures. Standalone multi-tool, malformed-argument, and empty-success tests are deferred. Tracked by ISS-603. |

## Test-add convention

- Provider-specific wire/parser behavior belongs in the provider file that owns
  the parser (`zig/src/ai/providers/<provider>.zig`) so private parser helpers
  remain directly testable with local `StreamingResponse` fixtures.
- Shared ownership/error invariants that cut across providers belong in shared
  matrix roots such as `provider_stream_contract_matrix_test.zig` and
  `provider_tool_call_ownership_matrix_test.zig`.
- Routing/helper surfaces such as Cloudflare should not duplicate independent
  parser scenarios; they should test routing/auth/setup behavior and rely on the
  routed provider rows for stream-parser coverage.
- In-memory provider semantics such as Faux should test provider behavior in
  `faux.zig` and mark parser-only scenarios N/A instead of pretending to cover
  SSE/HTTP-specific failure modes.

## M9 closure

M9 is complete for the review-roadmap scope, and the remaining backlog sweep is
triaged: the matrix has zero unknown `?` cells, zero unclassified missing or
partial cells, every N/A entry has a justification in the evidence notes, and
all remaining lower-priority gaps are marked `Deferred` with ISS-603 ownership.
The S13/S14/S12/S6/S15 priority sweep remains closed.

## Action items

### ISS-600 Confirm matrix entries by reading existing tests
- 严重度: P2
- 位置: `zig/src/ai/providers/*` test sections, `provider_smoke_test.zig`,
  `provider_stream_contract_matrix_test.zig`
- 建议: For every formerly unknown matrix cell, read the corresponding test.
  Update the cell.
- 验证: docs only.
- 状态: closed
- 负责: b3f3368b-a4b7-40f8-b53a-da67d0652925
- 提交: 902720d3

### ISS-601 Fill missing cells in priority order
- 严重度: P1
- 位置: provider test files
- 建议: Implement missing scenarios. Priority:
  1. ~~S13 content_index stability across providers~~ (closed by focused local
     fixtures/finalization tests for Anthropic, Responses-family providers,
     Bedrock, Google-family providers, Mistral, OpenAI Chat, and Kimi;
     Cloudflare/Faux remain N/A as routing/in-memory surfaces)
  2. ~~S14 leak-tracking allocator across providers~~ (closed by
     `provider_tool_call_ownership_matrix_test.zig` debug-allocator coverage)
  3. ~~S12 stop_reason coercion (.stop → .tool_use)~~ (closed by focused
     local provider fixtures/finalization tests for Anthropic, Responses-family
     providers, Bedrock, Google-family providers, Mistral, OpenAI Chat, and
     Kimi; Cloudflare/Faux remain N/A as routing/in-memory surfaces)
  4. ~~S6 abort mid-stream~~ (closed by local delayed SSE fixtures that abort
     after partial text for Anthropic, Responses-family providers,
     Google-family providers, Mistral, Kimi, OpenAI Chat, Bedrock, and Faux;
     Cloudflare remains N/A as routing surface)
  5. ~~S15 EOF mid-block~~ (closed by local EOF partial-stream fixtures for
     Responses-family providers, OpenAI Chat SSE, Google-family providers,
     Mistral, and Kimi; Anthropic/Bedrock were already covered, and
     Cloudflare/Faux remain N/A)
- 验证: each new test plus existing parity targets.
- 状态: closed for the M9 priority sweep; remaining lower-priority gaps are
  reclassified as `Deferred` and tracked by ISS-603.
- 负责: 07fa7938-a12a-4f83-97d8-37faee17b89b
- 提交: 902720d3

### ISS-602 Establish a test-add convention
- 严重度: P2
- 位置: `zig/docs/review/05_test_matrix.md`
- 建议: Document where each scenario test lives (per-provider file vs
  shared matrix). Avoid drift.
- 验证: docs only.
- 状态: closed
- 负责: b6c8f7b5-3abe-41d2-ae87-40b483d1ecd6
- 提交:

### ISS-603 Deferred lower-priority provider fixture expansion
- 严重度: P3
- 位置: `zig/src/ai/providers/*` test sections and shared provider matrix tests
- 建议: Add local fixtures for deferred cells when touching the corresponding
  provider parser for other reasons, or when a user-visible regression points
  at that exact shape. Keep each batch narrow and local-fixture only.
- 验证: targeted provider test plus `cd zig && zig build test-ai`.
- 状态: open
- 负责: backlog
- 提交:
