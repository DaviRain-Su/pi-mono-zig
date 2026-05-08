# Refactor Roadmap

Sequence of milestones. Each milestone:

- has a single goal
- lands in 1–N small commits, each with green `zig build test`
- ends with a measurable invariant added (test, comment, or assert)

Rule: never start milestone N+1 if milestone N's quality gate is red.

---

## M1 — Lock down current invariants (defensive)

**Goal**: ensure the recent ownership normalization can't silently regress.

**Status**: complete. Closure evidence is in `daad6dbd` (provider stream
invariants/tool-call ownership matrix), `c3e7febc` (shared stop-reason helper),
and `902720d3` (Anthropic content-index regression plus INV-1/INV-2/INV-3/INV-4/INV-5
contract docs/assertions).

**Tasks**:
- [x] ISS-002 add `content_index` stability regression test for Anthropic
- [x] ISS-200 verify `provider_stream_contract_matrix_test.zig` covers
  cross-provider invariants; extend if not
- [x] ISS-201 add leak-tracking test that drives every provider through a
  tool-call stream
- [x] ISS-500 document INV-1 in `types.zig`
- [x] ISS-501 debug-mode assert in `freeAssistantMessage`
- [x] ISS-502 document INV-2/3/4/5 in `event_stream.zig`

**Files changed**: tests + small docs/asserts in `types.zig`,
`event_stream.zig`. No provider logic changes beyond tests/contract guards.

**Expected delta**: +400 LOC tests, +40 LOC asserts/docs.

**Quality gate**:
- `zig build test` green in the implementation commits
- New leak-tracking test green for all providers (covered by
  `provider_tool_call_ownership_matrix_test.zig` debug-allocator matrix; the
  Cloudflare helper surface is N/A because it does not own an independent
  assistant-message stream)
- Anthropic content_index regression test green

---

## M2 — Extract `coerceStopReasonForToolCalls`

**Goal**: kill stop-reason drift permanently.

**Status**: complete in `c3e7febc`.

**Tasks**:
- [x] ISS-503 add helper in `ai/shared/`
- [x] Replace inline `had_tool_calls and stop == .stop -> .tool_use` in:
  anthropic, bedrock, openai_responses, openai_codex_responses,
  azure_openai_responses, kimi, mistral

**Quality gate**:
- `zig build test-ai` green in the implementation commit
- `zig build test-openai-responses-parity` green in the implementation commit
- `zig build test-bedrock-parity` green in the implementation commit

**Expected delta**: −60 LOC, +20 LOC.

---

## M3 — Shared finalize layer (Step 1–3 of duplication plan)

**Goal**: introduce `appendInlineToolCall` and migrate all 5+ providers off
their inline duplications.

**Status**: complete. Verification/bookkeeping pass confirmed helper adoption
in `bedrock`, `openai_responses`, `openai_codex_responses`,
`azure_openai_responses`, `kimi`, and `anthropic`. Current-branch evidence is
`377e700f`, `ae65e44a`, `5dbaba13`, `129576f2`, `5cb714d0`, `60fd0f92`, and
`1f9bbcda`; older per-step issue entries retain their original short commit
references where available.

**Tasks**:
- [x] ISS-300 add `zig/src/ai/shared/finalize.zig`
- [x] ISS-301..306 migrate bedrock → openai_responses → codex → azure → kimi
  → anthropic (one commit each)

**Quality gate** (after each commit):
- `zig build test-{provider}-parity` green where applicable
- `zig build test-ai` green
- Diff each provider before/after: only the tool-call-finalize block changed

**Final verification**:
- `cd zig && zig build test-ai`
- `cd zig && zig build test-openai-responses-parity`
- `cd zig && zig build test-bedrock-parity`
- `cd zig && zig build test-tidy`
- `npm run check`

**Expected delta**: −300 LOC across 6 providers, +150 LOC shared helper.

---

## M4 — Unify `finalizeOutput`

**Goal**: collapse the Cluster A copies of output ownership-transfer logic
into one shared helper.

**Status**: complete. Verification confirmed shared `finalizeOutput`
adoption in `bedrock`, `anthropic`, `kimi`, `openai_responses`,
`openai_codex_responses`, and `azure_openai_responses`. Remaining local
functions in those providers are provider-specific block-flush/error adapters
that delegate the output ownership-transfer step to
`shared/finalize.zig::finalizeOutput`, not retained copies of the shared
transfer helper. Outside Cluster A, `openai_chat_sse`, `google`,
`google_vertex`, `google_gemini_cli`, and `mistral` intentionally keep local
finalizers for future/provider-specific work. Evidence: `3306500c`.

**Tasks**:
- [x] ISS-307 implement `finalizeOutput` in `shared/finalize.zig`
- [x] Migrate Cluster A providers (bedrock, anthropic, kimi,
  openai_responses, openai_codex_responses, azure_openai_responses)

**Quality gate**: same as M3.

**Final verification**:
- `cd zig && zig build test-ai`
- `cd zig && zig build test-openai-responses-parity`
- `cd zig && zig build test-bedrock-parity`
- `cd zig && zig build test-tidy`
- `npm run check`

**Expected delta**: −150 LOC, +50 LOC shared.

---

## M5 — Responses-API common surface

**Goal**: collapse the three `*_responses.zig` files' near-identical
`finalizeCurrentBlock` and per-event handlers.

**Status**: complete in `3306500c`. The shared Responses surface lives in
`zig/src/ai/shared/responses_api.zig`, and `openai_responses`, Codex Responses,
and Azure Responses all call the shared `finalizeCurrentBlock` path.

**Tasks**:
- [x] ISS-308 implement `responses_api.finalizeCurrentBlock` in
  `ai/shared/responses_api.zig`
- [x] Migrate openai_responses, codex, azure (one commit each)

**Quality gate**:
- `zig build test-openai-responses-parity` green for each
- visible code reduction in the three files

**Expected delta**: −600 LOC across the three, +250 LOC shared.

---

## M6 — Generic SSE outer loop (most invasive; do last)

**Goal**: extract the outer SSE iterator. Risky because every provider has
small variations.

**Status**: complete for the M6 review-roadmap scope. `3306500c` introduced
`ai/shared/sse_loop.zig`; `902720d3` completed the remaining provider hardening
and coverage pass across Responses-family, Anthropic/Kimi-compatible, Google,
Mistral, Bedrock, and legacy OpenAI Chat paths while preserving provider-local
variation where intentionally required.

**Tasks**:
- [x] ISS-309 implement `runSseLoop` in `ai/shared/sse_loop.zig`
- [x] Add `accept_compact_data_lines` flag (folds in ISS-051)
- [x] Migrate kimi → openai_responses → codex → azure → anthropic →
  google → google_vertex → google_gemini_cli → mistral → bedrock
- [x] Last: openai (legacy chat) and openai_chat_sse (intentional exception
  may keep its own)

**Quality gate**:
- every provider's existing tests green at each step
- abort/error paths still tested
- compact `data:{...}` lines accepted by openai_chat_sse via the flag

**Expected delta**: −800 LOC, +300 LOC shared.

---

## M7 — `agent_loop.zig` state-machine documentation + guards

**Goal**: pin down agent_loop semantics. Not splitting yet — just hardening.

**Status**: complete in `902720d3`. The state-machine note was added at
`zig/src/agent/MODULE.md`, arena-vs-GPA and hook-ordering contracts are pinned,
and reuse/double-finalize guards have focused tests.

**Tasks**:
- [x] ISS-412 write `zig/src/agent/MODULE.md` with state diagram
- [x] ISS-407 document arena-vs-gpa allocator policy + add canary
- [x] ISS-404 document hook ordering for parallel exec
- [x] ISS-406 add reuse-guard in `PartialAssistantAccumulator.indexFor`
- [x] ISS-410 add `finalized: bool` flag + double-finalize assert

**Quality gate**: existing tests + new tests for guards.

**Expected delta**: +150 LOC tests/asserts, +1 doc file.

---

## M8 — `agent_loop.zig` partial-UX fix

**Goal**: surface partial tool-call to UI (or document why it shouldn't).

**Status**: complete in `902720d3`. The selected policy is documented in
`agent_loop.zig`: streaming clients receive `message_update` snapshots for
partial tool calls, while a standalone leading tool call remains hidden from
`message.content` until finalization to avoid a blank TUI row. A snapshot test
pins this behavior.

**Tasks**:
- [x] ISS-402 decide policy and implement
- [x] add streaming snapshot test asserting `message_update` payloads

**Expected delta**: small.

---

## M9 — Test matrix completion

**Goal**: every cell in `05_test_matrix.md` is ✅ or N/A, or explicitly
classified with a justified partial/missing marker instead of unknown `?`.

**Status**: complete in `902720d3`. The matrix has zero unknown `?` cells,
ISS-600 is closed, and ISS-601 closed the M9 priority sweep for S13/S14/S12/S6/S15.
Remaining ❌ cells are known missing lower-priority coverage, not unknown cells.

**Tasks**:
- [x] ISS-600 confirm existing entries
- [x] ISS-601 fill ❌ in priority order

**Quality gate**: matrix has zero `?` entries.

---

## M10 (post-`ai`/`agent`) — `coding_agent/` review pass

**Out of scope for this round / post-ai-agent.** Listed so we don't forget.
Likely starts with `interactive_mode.zig` (6331 LOC) and `ts_rpc_mode.zig`
(6232 LOC) splits. M10 is not claimed as completed by the M1–M9 bookkeeping
closure.

---

## Cumulative impact estimate

| Milestone | LOC delta | Risk | Tests added | Status |
|---|---:|---|---|---|
| M1 | +440 | Low | many | complete |
| M2 | -40 | Low | small | complete |
| M3 | -150 | Med | small | complete |
| M4 | -100 | Med | small | complete |
| M5 | -350 | Med-High | per-provider | complete |
| M6 | -500 | High | substantial | complete |
| M7 | +150 | Low | guard tests | complete |
| M8 | small | Low-Med | snapshot | complete |
| M9 | only tests/docs | Low | matrix | complete |
| M10 | TBD | High | TBD | post-ai-agent / out of scope |

**Net (M1–M9)**: ~−550 LOC of duplication, +~700 LOC of shared/tests/docs,
plus ~30 explicit new invariants pinned by tests or asserts.

---

## How to claim and track

M1–M9 are closed. Future work should use the remaining open issue entries for
post-roadmap gaps, and M10 should stay explicitly post-ai-agent until a new
review pass is assigned.
