# Refactor Roadmap

Sequence of milestones. Each milestone:

- has a single goal
- lands in 1–N small commits, each with green `zig build test`
- ends with a measurable invariant added (test, comment, or assert)

Rule: never start milestone N+1 if milestone N's quality gate is red.

---

## M1 — Lock down current invariants (defensive)

**Goal**: ensure the recent ownership normalization can't silently regress.

**Tasks**:
- [ ] ISS-002 add `content_index` stability regression test for Anthropic
- [ ] ISS-200 verify `provider_stream_contract_matrix_test.zig` covers
  cross-provider invariants; extend if not
- [ ] ISS-201 add leak-tracking test that drives every provider through a
  tool-call stream
- [ ] ISS-500 document INV-1 in `types.zig`
- [ ] ISS-501 debug-mode assert in `freeAssistantMessage`
- [ ] ISS-502 document INV-2/3/4/5 in `event_stream.zig`

**Files changed**: tests + small docs/asserts in `types.zig`,
`event_stream.zig`. No provider logic changes.

**Expected delta**: +400 LOC tests, +40 LOC asserts/docs.

**Quality gate**:
- `zig build test` green
- New leak-tracking test green for all providers
- Anthropic content_index regression test green

---

## M2 — Extract `coerceStopReasonForToolCalls`

**Goal**: kill stop-reason drift permanently.

**Tasks**:
- [ ] ISS-503 add helper in `ai/shared/`
- [ ] Replace inline `had_tool_calls and stop == .stop -> .tool_use` in:
  anthropic, bedrock, openai_responses, openai_codex_responses,
  azure_openai_responses, kimi, mistral

**Quality gate**:
- `zig build test-ai` green
- `zig build test-openai-responses-parity` green
- `zig build test-bedrock-parity` green

**Expected delta**: −60 LOC, +20 LOC.

---

## M3 — Shared finalize layer (Step 1–3 of duplication plan)

**Goal**: introduce `appendInlineToolCall` and migrate all 5+ providers off
their inline duplications.

**Status**: complete. Verification/bookkeeping pass confirmed helper adoption
in `bedrock`, `openai_responses`, `openai_codex_responses`,
`azure_openai_responses`, `kimi`, and `anthropic`.

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
finalizers for future/provider-specific work.

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

**Tasks**:
- [ ] ISS-308 implement `responses_api.finalizeCurrentBlock` in
  `ai/shared/responses_api.zig`
- [ ] Migrate openai_responses, codex, azure (one commit each)

**Quality gate**:
- `zig build test-openai-responses-parity` green for each
- visible code reduction in the three files

**Expected delta**: −600 LOC across the three, +250 LOC shared.

---

## M6 — Generic SSE outer loop (most invasive; do last)

**Goal**: extract the outer SSE iterator. Risky because every provider has
small variations.

**Tasks**:
- [ ] ISS-309 implement `runSseLoop` in `ai/shared/sse_loop.zig`
- [ ] Add `accept_compact_data_lines` flag (folds in ISS-051)
- [ ] Migrate kimi → openai_responses → codex → azure → anthropic →
  google → google_vertex → google_gemini_cli → mistral → bedrock
- [ ] Last: openai (legacy chat) and openai_chat_sse (intentional exception
  may keep its own)

**Quality gate**:
- every provider's existing tests green at each step
- abort/error paths still tested
- compact `data:{...}` lines accepted by openai_chat_sse via the flag

**Expected delta**: −800 LOC, +300 LOC shared.

---

## M7 — `agent_loop.zig` state-machine documentation + guards

**Goal**: pin down agent_loop semantics. Not splitting yet — just hardening.

**Tasks**:
- [ ] ISS-412 write `zig/src/agent/MODULE.md` with state diagram
- [ ] ISS-407 document arena-vs-gpa allocator policy + add canary
- [ ] ISS-404 document hook ordering for parallel exec
- [ ] ISS-406 add reuse-guard in `PartialAssistantAccumulator.indexFor`
- [ ] ISS-410 add `finalized: bool` flag + double-finalize assert

**Quality gate**: existing tests + new tests for guards.

**Expected delta**: +150 LOC tests/asserts, +1 doc file.

---

## M8 — `agent_loop.zig` partial-UX fix

**Goal**: surface partial tool-call to UI (or document why it shouldn't).

**Tasks**:
- [ ] ISS-402 decide policy and implement
- [ ] add streaming snapshot test asserting `message_update` payloads

**Expected delta**: small.

---

## M9 — Test matrix completion

**Goal**: every cell in `05_test_matrix.md` is ✅ or N/A.

**Tasks**:
- [ ] ISS-600 confirm existing entries
- [ ] ISS-601 fill ❌ in priority order

**Quality gate**: matrix has zero `?` entries.

---

## M10 (post-`ai`/`agent`) — `coding_agent/` review pass

**Out of scope for this round.** Listed so we don't forget. Likely starts
with `interactive_mode.zig` (6331 LOC) and `ts_rpc_mode.zig` (6232 LOC)
splits.

---

## Cumulative impact estimate

| Milestone | LOC delta | Risk | Tests added |
|---|---:|---|---|
| M1 | +440 | Low | many |
| M2 | -40 | Low | small |
| M3 | -150 | Med | small |
| M4 | -100 | Med | small |
| M5 | -350 | Med-High | per-provider |
| M6 | -500 | High | substantial |
| M7 | +150 | Low | guard tests |
| M8 | small | Low-Med | snapshot |
| M9 | only tests | Low | matrix |
| M10 | TBD | High | TBD |

**Net (M1–M9)**: ~−550 LOC of duplication, +~700 LOC of shared/tests/docs,
plus ~30 explicit new invariants pinned by tests or asserts.

---

## How to claim and track

Update this file's checkbox state, plus the originating issue's `状态:` and
`负责:` fields, and the commit hash in `提交:`. Keep `README.md`'s status
table in sync each milestone.
