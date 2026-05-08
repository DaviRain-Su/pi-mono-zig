# Test Coverage Matrix

This file tracks per-provider × per-scenario test coverage. Cells were audited
against current local Zig tests on 2026-05-08; see the evidence notes below for
the test roots that justify confirmed coverage and N/A decisions.

## Legend
- ✅ — covered by an existing test
- ❌ — clearly missing, blocks confidence
- ⚠️ — partial / indirect coverage; should be improved
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
| anthropic | ✅ | ⚠️ | ⚠️ | ✅ | ❌ | ✅ | ⚠️ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| openai_responses | ✅ | ⚠️ | ✅ | ❌ | ✅ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| openai_codex_responses | ✅ | ⚠️ | ⚠️ | ❌ | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| azure_openai_responses | ✅ | ✅ | ⚠️ | ❌ | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | N/A | ✅ | ✅ | ✅ | ✅ |
| openai_chat_sse | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| bedrock | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ | ✅ | ❌ | N/A | N/A | ✅ | ✅ | ✅ | ✅ |
| google | ✅ | ⚠️ | ⚠️ | ✅ | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | N/A | ✅ | ✅ | ✅ | ✅ |
| google_vertex | ⚠️ | ✅ | ⚠️ | ✅ | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| google_gemini_cli | ⚠️ | ✅ | ⚠️ | ✅ | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| mistral | ✅ | ⚠️ | ⚠️ | ✅ | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | N/A | ✅ | ✅ | ✅ | ✅ |
| kimi | ⚠️ | ✅ | ✅ | ❌ | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | N/A | ✅ | ✅ | ✅ | ✅ |
| cloudflare | N/A | N/A | N/A | N/A | N/A | N/A | N/A | ⚠️ | N/A | N/A | ✅ | N/A | N/A | N/A | N/A |
| faux | ✅ | ⚠️ | ✅ | ❌ | ❌ | ✅ | N/A | N/A | ❌ | N/A | N/A | N/A | N/A | ✅ | N/A |

## Evidence notes

- `anthropic`: `anthropic.zig` covers text, compact lines, provider error,
  empty-success erroring, thinking+tool, Kimi-compatible repair/tolerance,
  content-index stability, partial EOF, setup/on-payload/on-response failure,
  pre-abort and mid-stream abort, Cloudflare/Copilot-style header paths, and explicit stop-reason
  coercion via `parse anthropic stream coerces end_turn to tool_use when tool
  calls are present`. Current gaps remain for multiple tool calls and
  first-party malformed tool-argument recovery.
- `openai_responses`: `openai_responses.zig` covers text, reasoning deltas,
  tool calls, multiple/interleaved tool calls, canonical compact-line strictness,
  HTTP/provider errors, Copilot dynamic headers, stop-reason coercion through
  finalized tool output, content-index stability, setup/pre-abort/mid-stream abort paths, and
  EOF mid-block tool-call finalization, and leak-tracked parser fixtures. Empty successful streams, malformed tool-arg
  recovery, and full thinking+tool success streams are still missing.
- `openai_codex_responses`: `openai_codex_responses.zig` covers text,
  reasoning, canonical compact-line strictness, account/auth request shaping,
  HTTP/setup/on-payload/on-response errors, content-index stability across
  text/tool/text output items, and stop-reason coercion through
  `finalizeCollectedOutput preserves Codex finalization semantics`, and
  mid-stream abort with partial text preservation. S15 is covered by Codex
  Responses EOF mid-tool finalization. Tool streaming beyond the
  single stability fixture, multiple tool calls, and malformed tool-arg
  recovery remain missing or only indirectly covered.
- `azure_openai_responses`: `azure_openai_responses.zig` covers text,
  reasoning, canonical compact-line strictness, partial terminal error ordering,
  HTTP/setup errors, static Azure auth header handling, and leak-tracked
  finalization, including content-index stability across text/tool/text output
  items, mid-stream abort with partial text preservation, and stop-reason
  coercion through `finalizeCollectedOutput preserves Azure finalization
  semantics`. S15 is covered by Azure Responses EOF mid-tool finalization.
  Azure has no distinct OAuth/dynamic-header S11 path; broader tool
  streaming is still missing.
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
  tool-argument recovery has parser code but no provider test.
- `bedrock`: `bedrock.zig` covers raw and binary Bedrock streams with text,
  thinking, tool-only, mixed thinking/text/tool, provider exceptions, HTTP
  status errors, abort finalization, explicit stop-reason coercion through
  `parseEventStreamFrames coerces end_turn to tool_use when tool calls are
  present`, content-index stability across thinking/text/tool/text block
  indexes, and EOF/invalid-terminal partial handling. SSE compact lines and
  OAuth/dynamic headers are N/A for Bedrock's binary/raw event-stream path.
- `google`, `google_vertex`, `google_gemini_cli`: the Google-family files cover
  text or mixed response parsing, thinking+tool flows, HTTP/setup/auth errors,
  canonical compact-line strictness, partial terminal errors, mid-stream aborts, and
  Google/Vertex/Gemini CLI stop-reason coercion. Their mixed parser fixtures
  now assert stable thinking/tool/text content indexes, and EOF mid-text
  fixtures finalize partial output without a terminal `[DONE]`. Vertex and Gemini CLI have
  credential/OAuth-like header paths; plain Google API-key auth does not have a
  distinct S11 path.
- `mistral`: `mistral.zig` covers text, mixed thinking+tool, HTTP/setup errors,
  canonical compact-line strictness, content-index stability across
  thinking/tool/text blocks, stop-to-tool-use coercion in `parse stream emits
  thinking and tool call events`, partial terminal errors, and mid-stream
  abort with partial text preservation. S15 is covered by an EOF text+tool
  partial-stream fixture. The current tests do not prove multiple
  tools or malformed tool-arg recovery. Mistral S11 is N/A because the Zig
  provider uses API-key/static-auth request shaping and has no distinct OAuth
  or dynamic-header path.
- `kimi`: `kimi.zig` covers thinking+text, tool-only, compact data lines, HTTP
  and setup errors, standalone stop-reason coercion, partial terminal errors,
  and mid-stream abort with partial text preservation. Kimi
  Anthropic-compatible tolerance is covered in `anthropic.zig`, but standalone
  Kimi still lacks multi-tool and malformed tool-arg tests. Standalone Kimi
  S15 is covered by an EOF text+tool partial-stream fixture.
  Standalone Kimi content-index stability is
  covered by a thinking/tool/text fixture. Kimi S11 is N/A because standalone
  Kimi API-key auth does not have a separate OAuth or dynamic-header code path.
- `cloudflare`: Cloudflare is a routing/helper surface over OpenAI/Anthropic
  compatible providers, not an independent stream parser. `cloudflare.zig`,
  `provider_smoke_test.zig`, `openai.zig`, and `anthropic.zig` cover provider
  recognition, environment placeholder substitution/failure, Gateway routing,
  auth metadata, and terminal setup errors.
- `faux`: `faux.zig` covers queued text, tool-call events, text/thinking/tool
  aborts, explicit aborted assistant messages, and leak-tracked in-memory
  streaming. Parser-specific malformed JSON, SSE compact lines, provider error
  frames, OAuth/dynamic-header paths, stop-frame coercion, content-index reuse,
  and EOF-mid-block scenarios are N/A for the in-memory faux provider.
- `S14 leak tracking`: `provider_tool_call_ownership_matrix_test.zig` drives
  every built-in production provider plus faux/Kimi-compatible fixture entries
  through local tool-call streams under a debug allocator. It asserts
  normalized providers keep inline-only ownership, the OpenAI Chat-compatible
  legacy exception keeps separately allocated copies, and all per-event/message
  allocations are released. Cloudflare is N/A for S14 because it is a routing
  helper surface with no independent assistant-message stream ownership; the
  routed OpenAI/Anthropic provider rows carry the ownership coverage.

## M9 closure

M9 is complete for the review-roadmap scope: the matrix has zero unknown `?` cells, every N/A entry has a justification in the evidence notes, and the S13/S14/S12/S6/S15 priority sweep is closed. Remaining `❌` cells are known lower-priority missing coverage, not unclassified unknowns.

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

### ISS-601 Fill ❌ cells in priority order
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
- 状态: closed for the M9 priority sweep; remaining ❌ cells are known missing
  coverage outside the priority gaps filled by this milestone.
- 负责: 07fa7938-a12a-4f83-97d8-37faee17b89b
- 提交: 902720d3

### ISS-602 Establish a test-add convention
- 严重度: P2
- 位置: `zig/docs/review/05_test_matrix.md`
- 建议: Document where each scenario test lives (per-provider file vs
  shared matrix). Avoid drift.
- 验证: docs only.
- 状态: open
- 负责:
- 提交:
