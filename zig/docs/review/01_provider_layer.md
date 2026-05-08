# Provider Layer Issues — `zig/src/ai/providers/`

This file lists concrete, actionable issues in each provider implementation.
Findings come from:

- the recent `fde1951f fix(zig): harden provider tool call ownership` commit
- the prior `a3153ebc fix(zig): normalize provider tool call ownership` follow-up
- the `content_index` reuse fix in `anthropic.zig` (uses incoming `index` now)

This doc is **seeded with known issues** but **not exhaustive**. A subsequent
agent should do a full per-provider read-through and append.

---

## Cross-provider invariants (must hold after recent commits)

The following must be true for every provider that finalizes a streaming
assistant message. New code that violates these is a regression.

1. **Single allocation for tool calls.** Tool call strings (`id`, `name`) and
   `arguments` JSON are owned by **`output.content[*].tool_call`** only. The
   in-flight `tool_calls: ArrayList(types.ToolCall)` is borrow-only — it
   exists for length checks and stop-reason coercion. `tool_calls.deinit(...)`
   must only free the list buffer.
2. **`output.tool_calls` is null** for every normalized provider. The single
   intentional exception is `openai_chat_sse.zig` (legacy compat — see its
   in-file comment and `tool_calls_transferred` flag).
3. **Stop reason coercion**: when tool calls were emitted and the upstream
   stop_reason is `.stop`, coerce to `.tool_use`. This is provider-side, not
   agent-side.
4. **Outgoing `content_index`** must be stable for the lifetime of the stream.
   It must not be derived from `active_blocks.items.len` (which shrinks on
   `orderedRemove`). Use the provider's incoming `index` field, or a persistent
   monotonic counter.

---

## Provider-by-provider issues

### `anthropic.zig` (3951 LOC)

#### ISS-001 Verify reasoning/thinking signature handling on EOF
- 严重度: P1
- 位置: `zig/src/ai/providers/anthropic.zig:1706-1863` (parseSseStreamLines tail; finalize on EOF)
- 现状: When stream ends mid-thinking block (no `content_block_stop`), the
  code finalizes "tolerantly". Need to confirm `signature` field is preserved
  vs dropped.
- 问题: If a redacted-thinking block ends without explicit stop, the
  signature may leak or be lost, which can break replay + audit.
- 建议: Add an EOF-mid-thinking test fixture; assert signature is present in
  the final `output.content[*].thinking.signature`.
- 验证: extend `zig build test-ai` with new test in
  `provider_smoke_test.zig` or a dedicated thinking-tail test.
- 状态: open
- 负责:
- 提交:

#### ISS-002 Add regression test for `content_index` stability
- 严重度: P1
- 位置: `zig/src/ai/providers/anthropic.zig` (`ISS-002 Anthropic content_index remains stable after block removal`)
- 现状: Regression coverage exists for the text-stop/tool-start sequence that previously risked reusing `active_blocks.items.len` after removal.
- 问题: Closed for this roadmap pass; future refactors must preserve provider incoming `index` as the event content index.
- 建议: Keep the regression test with any Anthropic block-lifecycle refactor.
- 验证: `cd zig && zig build test-ai`
- 状态: closed
- 负责: review-roadmap-documentation-bookkeeping-sync
- 提交: 902720d3

#### ISS-003 Document `shouldTolerateNoncanonicalAnthropicChunk` policy
- 严重度: P2
- 位置: `zig/src/ai/providers/anthropic.zig` (model-keyed tolerance check)
- 现状: Policy is keyed off `model.id` heuristics inline.
- 问题: Hard to discover which providers this targets (Kimi, others?). New
  contributors will not know they need to extend it.
- 建议: Move tolerance rules to a small named registry or comment block at
  top of file listing each rule + reason.
- 验证: docs only; build still passes.
- 状态: open
- 负责:
- 提交:

### `openai_responses.zig` (3714 LOC)

#### ISS-010 finalizeOutputFromPartials still mixed with happy path
- 严重度: P2
- 位置: `zig/src/ai/providers/openai_responses.zig:640-658`
- 现状: Closed by the shared finalize/output and Responses API migration.
  `openai_responses.zig` aliases `responses_api.finalizeCurrentBlock` and its
  local `finalizeOutputFromPartials` adapter delegates the ownership transfer,
  total-token handling, and stop-reason coercion to
  `ai/shared/finalize.zig::finalizeOutput`.
- 问题: Closed for this roadmap pass; the remaining local adapter is
  provider-specific block flushing/error glue, not a retained copy of shared
  output-transfer logic.
- 建议: Keep the adapter delegating to `finalize.finalizeOutput` during future
  Responses refactors.
- 验证: `cd zig && zig build test-ai`.
- 状态: closed
- 负责: review-roadmap-documentation-bookkeeping-sync;
  5efa68c7-6d00-41ab-829c-96d19377c89c stale-doc verification
- 提交: 3306500c, 902720d3

#### ISS-011 Confirm reasoning detail attached to correct tool call when
multiple tool calls in flight
- 严重度: P1
- 位置: `zig/src/ai/providers/openai_responses.zig` (reasoning_details handler)
- 现状: Reasoning details are attached to active tool calls by id match.
- 问题: If two tool calls have overlapping id windows (rare but observed
  with parallel functions), the wrong tool may receive the
  `thought_signature`.
- 建议: Add a multi-tool-call+reasoning fixture.
- 验证: new test under provider_smoke_test.zig.
- 状态: open
- 负责:
- 提交:

---

### `openai_codex_responses.zig` (2237 LOC)

#### ISS-020 Same finalize-from-partials extraction as ISS-010
- 严重度: P2
- 位置: `zig/src/ai/providers/openai_codex_responses.zig` (finalizeOutputFromPartials)
- 现状: Closed by the shared finalize/output and Responses API migration.
  `openai_codex_responses.zig` aliases `responses_api.finalizeCurrentBlock`
  and its local finalization adapter delegates to
  `ai/shared/finalize.zig::finalizeOutput`.
- 建议: Keep the provider-local adapter limited to Codex-specific block
  flushing and terminal-error glue.
- 验证: `cd zig && zig build test-ai`.
- 状态: closed
- 负责: review-roadmap-documentation-bookkeeping-sync;
  5efa68c7-6d00-41ab-829c-96d19377c89c stale-doc verification
- 提交: 3306500c, 902720d3

---

### `azure_openai_responses.zig` (1859 LOC)

#### ISS-030 Same finalize-from-partials extraction as ISS-010
- 严重度: P2
- 位置: `zig/src/ai/providers/azure_openai_responses.zig`
- 现状: Closed by the shared finalize/output and Responses API migration.
  `azure_openai_responses.zig` aliases `responses_api.finalizeCurrentBlock`
  and its local finalization adapter delegates to
  `ai/shared/finalize.zig::finalizeOutput`.
- 建议: Keep the provider-local adapter limited to Azure-specific block
  flushing and terminal-error glue.
- 验证: `cd zig && zig build test-ai`.
- 状态: closed
- 负责: review-roadmap-documentation-bookkeeping-sync;
  5efa68c7-6d00-41ab-829c-96d19377c89c stale-doc verification
- 提交: 3306500c, 902720d3

#### ISS-031 Verify Azure-specific header / endpoint handling vs OpenAI
- 严重度: P2
- 位置: `zig/src/ai/providers/azure_openai_responses.zig` (request building)
- 现状: Azure requires `api-version` query param + `api-key` header.
- 问题: Diff between Azure and OpenAI may have subtle env-var mismatches.
- 建议: Audit env-key resolution chain, add regression test for invalid Azure
  config (missing api-version, missing endpoint).
- 验证: smoke test extended.
- 状态: open
- 负责:
- 提交:

---

### `bedrock.zig` (3670 LOC)

#### ISS-040 finalizeOutputFromPartials normalized this round; verify no
double-free path remains
- 严重度: P1
- 位置: `zig/src/ai/providers/bedrock.zig:2200-2230`
- 现状: Closed by source audit and the provider ownership matrix. Bedrock
  finalizes tool calls through `finalize.insertInlineToolCall` /
  `finalize.finalizeOutput`, leaves `AssistantMessage.tool_calls` null, and
  keeps the local `tool_calls` ArrayList as borrow-only bookkeeping. Existing
  Bedrock fixtures assert tool-call-only final output has one inline
  `.tool_call` and null legacy `tool_calls`; terminal-error fixtures also
  preserve null legacy ownership.
- 问题: Closed for this backlog pass; future Bedrock parser refactors must keep
  the inline-only ownership comment and `provider_tool_call_ownership_matrix`
  row in sync.
- 建议: Keep Bedrock parser fixtures plus the shared ownership matrix green.
- 验证: `cd zig && zig build test-ai`.
- 状态: closed
- 负责: zrb-01-kimi-placeholder-and-provider-invariant-audit
- 提交: pending mission handoff (uncommitted by mission rule)

#### ISS-041 Bedrock-specific stop_reason coercion alignment
- 严重度: P1
- 位置: `zig/src/ai/providers/bedrock.zig` (mapStopReason)
- 现状: Bedrock has its own stop_reason vocabulary (`tool_use`, `end_turn`,
  `max_tokens`, `stop_sequence`, `guardrail_intervened`, `content_filtered`).
- 问题: Need to confirm `guardrail_intervened` and `content_filtered` map to
  `.error_reason` (matching anthropic's `refusal` / `sensitive`).
- 建议: Add a stop-reason mapping unit test.
- 验证: `zig build test-bedrock-parity`.
- 状态: open
- 负责:
- 提交:

---

### `openai_chat_sse.zig` (934 LOC) — INTENTIONAL EXCEPTION

#### ISS-050 Document why `output.tool_calls` is dual-allocated here
- 严重度: P2
- 位置: `zig/src/ai/providers/openai_chat_sse.zig:577-666` (finishStreamingBlocks)
- 现状: The file header now states that OpenAI Chat Completions keeps a custom
  parser, uses the shared SSE outer iterator only for line/abort handling, and
  intentionally preserves the separately allocated legacy
  `AssistantMessage.tool_calls` compatibility copy while inline `.tool_call`
  content remains canonical. `finishParserState` also repeats the freeing
  contract at the transfer site.
- 问题: Closed for this review pass; future normalizations must preserve this
  documented exception unless the legacy compatibility field is intentionally
  removed everywhere.
- 建议: Keep the file-header and transfer-site comments in sync with any future
  `types.freeAssistantMessage` ownership-contract changes.
- 验证: static review of `zig/src/ai/providers/openai_chat_sse.zig` header and
  transfer-site comments; `cd zig && zig build test-ai`.
- 状态: closed
- 负责: 5efa68c7-6d00-41ab-829c-96d19377c89c
- 提交: pending mission handoff (uncommitted by mission rule)

#### ISS-051 Compact `data:{...}` SSE line not accepted
- 严重度: P1
- 位置: `zig/src/ai/providers/openai_chat_sse.zig:443-450` (parseSseLine)
- 现状: `parseSseLine` accepts both `"data: "` and compact `"data:"` prefixes,
  and `openai_chat_sse accepts compact data lines in chat completions stream`
  covers compact data after an `event:` control line.
- 问题: Closed for this review pass; compact Chat Completions data-line
  tolerance is intentionally local to `openai_chat_sse`'s provider handler and
  does not broaden canonical generic SSE-loop parsing.
- 建议: Keep the compact-line fixture whenever the OpenAI Chat SSE parser or
  shared SSE-loop handler is refactored.
- 验证: `cd zig && zig build test-ai`.
- 状态: closed
- 负责: 5efa68c7-6d00-41ab-829c-96d19377c89c
- 提交: pending mission handoff (uncommitted by mission rule)

---

### `kimi.zig` (1486 LOC)

#### ISS-060 Verify behavior change after placeholder-text removal
- 严重度: P0
- 位置: `zig/src/ai/providers/kimi.zig:841-870` (finishCurrentBlock)
- 现状: Closed by the Kimi parser fixture
  `ISS-060 ISS-061 parseSseStream omits placeholder text for tool-call-only
  response and coerces stop reason`. The fixture finalizes a tool-call-only
  Kimi stream and asserts the final assistant message contains exactly one
  inline `.tool_call` block, no zero-length text placeholder, and null legacy
  `tool_calls`.
- 问题: Closed for this backlog pass; the intended behavior is no placeholder
  text block for tool-call-only final content.
- 建议: Keep the named Kimi fixture with any `finishCurrentBlock` refactor.
- 验证: `cd zig && zig build test-ai`.
- 状态: closed
- 负责: zrb-01-kimi-placeholder-and-provider-invariant-audit
- 提交: pending mission handoff (uncommitted by mission rule)

#### ISS-061 Tool-call-only response: stop_reason coercion path
- 严重度: P1
- 位置: `zig/src/ai/providers/kimi.zig` (final done emit)
- 现状: Closed by the same ISS-060/061 Kimi fixture. It feeds a provider
  `finish_reason: "stop"` with finalized tool output and asserts
  `output.stop_reason == .tool_use`.
- 问题: Closed for this backlog pass; stop-to-tool-use coercion is provider
  finalization behavior, not an agent-loop repair.
- 建议: Keep the fixture and `finalize.finalizeOutput(...,
  .coerce_stop_reason_for_tool_calls = true)` wiring together.
- 验证: `cd zig && zig build test-ai`.
- 状态: closed
- 负责: zrb-01-kimi-placeholder-and-provider-invariant-audit
- 提交: pending mission handoff (uncommitted by mission rule)

---

### `mistral.zig` (1799 LOC)

#### ISS-070 Audit normalize-tool-call invariants
- 严重度: P1
- 位置: `zig/src/ai/providers/mistral.zig`
- 现状: Closed by source audit plus `provider_tool_call_ownership_matrix`.
  Mistral materializes tool calls inline in `content_slots`, leaves
  `output.tool_calls` null, and uses the `tool_calls` ArrayList only for
  borrow-only stop-reason bookkeeping. Existing stream fixtures assert
  content-index stability and stop-to-tool-use coercion; the shared matrix
  asserts Mistral is normalized inline-only under a debug allocator.
- 问题: Closed for this backlog pass; no Mistral-specific legacy exception was
  found.
- 建议: Keep the Mistral matrix row and parser fixtures with future
  `active_tool_calls` refactors.
- 验证: `cd zig && zig build test-ai`.
- 状态: closed
- 负责: zrb-01-kimi-placeholder-and-provider-invariant-audit
- 提交: pending mission handoff (uncommitted by mission rule)

---

### `google.zig` / `google_vertex.zig` / `google_gemini_cli.zig`

#### ISS-080 Already-normalized assertion + documentation
- 严重度: P2
- 位置: `zig/src/ai/providers/google*.zig`
- 现状: Closed by source audit, per-provider assertions, and the ownership
  matrix. `google.zig`, `google_vertex.zig`, and `google_gemini_cli.zig`
  append `functionCall` responses as inline `.tool_call` content, use local
  `tool_calls` arrays only for stop-reason coercion, and leave the legacy
  `AssistantMessage.tool_calls` field null. The direct Google fixture already
  asserts null legacy ownership; the shared matrix covers all three Google
  family APIs under a debug allocator.
- 问题: Closed for this backlog pass; future Google-family parser work should
  keep inline ownership comments/fixtures greppable where provider-local
  finalization differs.
- 建议: Keep Google-family rows in `provider_tool_call_ownership_matrix_test.zig`.
- 验证: `cd zig && zig build test-ai`.
- 状态: closed
- 负责: zrb-01-kimi-placeholder-and-provider-invariant-audit
- 提交: pending mission handoff (uncommitted by mission rule)

---

### `cloudflare.zig` (212 LOC)

#### ISS-090 Verify single-pass implementation has no tool call handling gap
- 严重度: P2
- 位置: `zig/src/ai/providers/cloudflare.zig`
- 现状: 212 LOC — possibly incomplete vs other providers.
- 建议: Audit feature parity matrix (thinking? tool_calls? abort?). Document
  any explicit unsupported features.
- 验证: extend test-matrix doc.
- 状态: open
- 负责:
- 提交:

---

### `openai.zig` (2303 LOC) and `openai_chat_payload.zig` (1139 LOC)

#### ISS-100 Audit relationship to openai_chat_sse.zig
- 严重度: P2
- 位置: `zig/src/ai/providers/openai.zig`, `openai_chat_payload.zig`
- 现状: Three files (openai, openai_chat_sse, openai_chat_payload) split
  responsibilities; relationship not explicitly documented.
- 建议: Add a header comment in each describing what it owns and what it
  borrows from the others.
- 验证: docs only.
- 状态: open
- 负责:
- 提交:

---

### `faux.zig` (1425 LOC)

#### ISS-110 Confirm faux provider mirrors normalized invariants
- 严重度: P1
- 位置: `zig/src/ai/providers/faux.zig`
- 现状: Closed by normalizing the in-memory faux provider and updating its
  focused fixture. Faux now streams tool-call events from inline content and
  finalizes `AssistantMessage.tool_calls = null`, matching the normalized
  provider invariant instead of masking regressions with the old legacy cache.
  `ISS-110 faux tool-call thought signature stays inline-only` asserts the
  thought signature survives on the inline block and the legacy field is null.
- 问题: Closed for this backlog pass; faux is no longer a legacy exception.
- 建议: Keep faux's own fixture and the shared ownership matrix aligned.
- 验证: `cd zig && zig build test-ai`.
- 状态: closed
- 负责: zrb-01-kimi-placeholder-and-provider-invariant-audit
- 提交: pending mission handoff (uncommitted by mission rule)

---

## Generic / cross-provider follow-ups

### ISS-200 Add provider-stream-contract matrix test
- 严重度: P1
- 位置: `zig/src/coding_agent/tests/provider_stream_contract_matrix_test.zig`
- 现状: The matrix covers every built-in API plus faux/Kimi-compatible fixtures and asserts setup/runtime failures become terminal `error_event` streams with API/provider/model metadata.
- 建议: Keep new provider additions covered by the matrix or make any N/A routing/helper surface explicit.
- 验证: `cd zig && zig build test-coding-agent`
- 状态: closed
- 负责: review-roadmap-documentation-bookkeeping-sync
- 提交: daad6dbd

### ISS-201 Add a leak-tracking allocator test for tool_calls deinit
- 严重度: P1
- 位置: `zig/src/ai/providers/provider_tool_call_ownership_matrix_test.zig`
- 现状: A local provider override matrix drives built-in production providers, faux, and Kimi-compatible fixture entries through tool-call streams under a debug allocator.
- 建议: Keep new provider additions covered by the matrix or explicitly justify N/A helper surfaces such as Cloudflare.
- 验证: `cd zig && zig build test-ai`
- 状态: closed
- 负责: 43b9a826-f859-43e5-8fe7-57519aa10b1a
- 提交: daad6dbd

### ISS-202 Documented unsupported-feature matrix
- 严重度: P2
- 位置: `zig/docs/review/05_test_matrix.md`
- 建议: Keep the provider/scenario matrix updated as provider features change; helper/routing surfaces must have explicit N/A notes.
- 状态: closed
- 负责: review-roadmap-documentation-bookkeeping-sync
- 提交: 902720d3
