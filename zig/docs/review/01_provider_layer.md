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
- 现状: After commit `fde1951f`, `finalizeOutputFromPartials` no longer
  populates `output.tool_calls`, but the function exists in two different
  shapes (happy-path and error-path) that share most logic.
- 问题: Future regressions easy. Prefer extracting a single helper.
- 建议: Extract the shared core; have happy-path and `emitRuntimeFailure`
  both call it.
- 验证: `zig build test-openai-responses-parity`.
- 状态: open
- 负责:
- 提交:

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
- 建议: Once shared layer (see `02_provider_duplication.md`) lands, replace
  this function body with a call into it.
- 验证: existing parity tests.
- 状态: open
- 负责:
- 提交:

---

### `azure_openai_responses.zig` (1859 LOC)

#### ISS-030 Same finalize-from-partials extraction as ISS-010
- 严重度: P2
- 位置: `zig/src/ai/providers/azure_openai_responses.zig`
- 建议: same as ISS-010/020.
- 状态: open
- 负责:
- 提交:

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
- 现状: After commit `fde1951f`, the `.tool_call` branch reuses
  `final_tool_call` directly in content_blocks (no clone). 
- 问题: Need to confirm `tool_calls.deinit` does not free strings owned by
  content_blocks.
- 建议: Read tool_calls.deinit call site; confirm it only frees the list
  buffer.
- 验证: existing `zig build test-bedrock-parity` already passes; add a
  `defer std.testing.expectEqualStrings(...)` after deinit to prove strings
  remain valid (in a leak-tracking allocator test).
- 状态: open
- 负责:
- 提交:

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
- 现状: Comment explains the dual-allocation; but it is the ONLY exception to
  the cross-provider invariant.
- 问题: Anyone normalizing in the future needs to know this. The
  `tool_calls_transferred` flag invariant should be restated near every
  consumer site.
- 建议: Add a doc comment block at the top of the file restating "this is
  the legacy chat completions path, dual allocation is intentional, see
  `freeAssistantMessage` for the freeing contract".
- 验证: docs only.
- 状态: open
- 负责:
- 提交:

#### ISS-051 Compact `data:{...}` SSE line not accepted
- 严重度: P1
- 位置: `zig/src/ai/providers/openai_chat_sse.zig:443-450` (parseSseLine)
- 现状: Only accepts the literal prefix `"data: "` with the trailing space.
- 问题: Some compatible providers (Anthropic-style) emit `data:{...}` without
  a space. Anthropic's parser tolerates this; OpenAI chat does not.
- 建议: Accept both `data:` and `data: `. Mirror anthropic.zig's parsing.
- 验证: extend openai chat sse test with compact data line fixture.
- 状态: open
- 负责:
- 提交:

---

### `kimi.zig` (1486 LOC)

#### ISS-060 Verify behavior change after placeholder-text removal
- 严重度: P0
- 位置: `zig/src/ai/providers/kimi.zig:841-870` (finishCurrentBlock)
- 现状: Commit `fde1951f` removed empty placeholder text block when
  finalizing tool call; tool call now goes directly to content_blocks.
- 问题: Any consumer that previously skipped empty text blocks may now mis-
  count or mis-render. Verify on-device or via fixture.
- 建议: Add a kimi-specific snapshot test that the final content has exactly
  one `.tool_call` block (no zero-length text).
- 验证: new test under provider_smoke_test.zig or a kimi test file.
- 状态: open
- 负责:
- 提交:

#### ISS-061 Tool-call-only response: stop_reason coercion path
- 严重度: P1
- 位置: `zig/src/ai/providers/kimi.zig` (final done emit)
- 现状: After this round, `had_tool_calls and stop_reason == .stop ->
  .tool_use` coercion is in place.
- 问题: Pre-existing kimi tests may or may not cover this; needs a regression.
- 建议: Add a fixture: stream emits text + tool_use, server-reported
  stop=stop, expect output.stop_reason==.tool_use.
- 验证: provider_smoke_test.zig.
- 状态: open
- 负责:
- 提交:

---

### `mistral.zig` (1799 LOC)

#### ISS-070 Audit normalize-tool-call invariants
- 严重度: P1
- 位置: `zig/src/ai/providers/mistral.zig`
- 现状: Believed already normalized; not touched in `fde1951f`.
- 问题: Confirm by reading. Specifically: does mistral leave
  `output.tool_calls` null? Does it use single-allocation pattern?
- 建议: Read finalize/SSE-end paths. If anything diverges, file new ISS.
- 验证: existing tests + add explicit "tool_calls is null" assertion.
- 状态: open
- 负责:
- 提交:

---

### `google.zig` / `google_vertex.zig` / `google_gemini_cli.zig`

#### ISS-080 Already-normalized assertion + documentation
- 严重度: P2
- 位置: `zig/src/ai/providers/google*.zig`
- 现状: Believed normalized (per oracle survey).
- 问题: Add an explicit comment "tool calls live inline; legacy field intentionally null" near finalize path so it is greppable like the other normalized providers.
- 验证: docs only.
- 状态: open
- 负责:
- 提交:

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
- 现状: Mock provider used in tests.
- 问题: If faux uses the OLD shape (with `output.tool_calls` populated), it
  will mask regressions in tests that rely on it.
- 建议: Read finalize path; confirm faux emits inline tool_call only.
- 验证: provider_smoke_test.zig.
- 状态: open
- 负责:
- 提交:

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
