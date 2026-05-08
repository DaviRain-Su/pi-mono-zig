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
variation where intentionally required. The docs/stale-close follow-up also
validated the pre-existing uncommitted OpenAI Chat SSE diff: legacy
`openai_chat_sse.zig` now uses the shared outer line loop for line reading and
abort checks, while keeping the Chat Completions parser, compact data-line
tolerance, and legacy dual-allocation compatibility local and documented.

**Tasks**:
- [x] ISS-309 implement `runSseLoop` in `ai/shared/sse_loop.zig`
- [x] Keep compact data-line handling explicit in provider-local data-line
  handlers (folds in ISS-051 for OpenAI Chat SSE)
- [x] Migrate kimi → openai_responses → codex → azure → anthropic →
  google → google_vertex → google_gemini_cli → mistral → bedrock
- [x] Last: openai (legacy chat) and openai_chat_sse use the shared outer
  loop while keeping Chat Completions-specific parsing and the documented
  legacy `output.tool_calls` exception local

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

**Goal**: every cell in `05_test_matrix.md` is ✅, N/A, or explicitly
classified as Deferred with a justified owner/rationale instead of unknown `?`.

**Status**: M9 complete in `902720d3`; remaining backlog sweep completed by
`zrb-07-remaining-test-matrix-sweep`. The matrix has zero unknown `?` cells,
zero unclassified missing/partial cells, ISS-600/ISS-601/ISS-602 are closed,
and all remaining lower-priority coverage gaps are marked Deferred under ISS-603.

**Tasks**:
- [x] ISS-600 confirm existing entries
- [x] ISS-601 fill missing cells in priority order
- [x] ISS-602 establish test-add convention
- [ ] ISS-603 deferred lower-priority provider fixture expansion

**Quality gate**: matrix has zero `?`, unclassified missing, or unclassified
partial entries; `zig build test-tidy` statically checks the provider table.

---

## M10 (planning-only) — `coding_agent/` review pass

**Status**: read-only planning complete. This milestone did not implement
any code split, move source files, or change production behavior. It records
the safe future decomposition order for a separate `coding_agent/` review pass
after M1–M9 provider/agent work is already closed.

**Current hotspot inventory** (2026-05-08 line-count scan):

| LOC | Path | Primary risk |
|---:|---|---|
| 6636 | `zig/src/coding_agent/packages/package_manager.zig` | package install/update/remove/config, WASM trust/provenance, settings mutation, external command execution, and tests remain tightly coupled |
| 6333 | `zig/src/coding_agent/interactive_mode.zig` | bootstrap, terminal lifecycle, missing-cwd prompts, auth polling, prompt-worker lifecycle, extension UI service, and the main render/input loop share one orchestration root |
| 6242 | `zig/src/coding_agent/modes/ts_rpc_mode.zig` | exact-byte JSONL RPC, command dispatch, prompt/bash concurrency, deferred responses, session replacement, and extension UI protocol are coupled |
| 5362 | `zig/src/coding_agent/interactive_mode/rendering.zig` | `AppState`, event reducers, snapshot cloning, layout/draw functions, footer/task/chat rendering, extension widgets, images, and bash display state share one render module |
| 3581 | `zig/src/coding_agent/interactive_mode/input_dispatch.zig` | configurable key resolution, overlay routing, editor submission, queue/dequeue, bash shortcuts, external editor, and app actions remain broad |
| 2547 | `zig/src/coding_agent/interactive_mode/slash_commands.zig` | command text builders, settings/session/model mutation, copy/share/export/import IO, and UI status side effects are grouped |

**Future implementation milestones** (deferred; do not claim in M10):

1. **Baseline guardrail inventory** — freeze the relevant local/fixture
   validators and exact-byte fixtures before any split.
   - Likely files: docs/test harness only.
   - Gate: `cd zig && zig build test-coding-agent`,
     `cd zig && zig build test-tui`, and targeted commands below as
     applicable.
2. **Package manager pure boundaries** — extract source classification,
   source normalization, path resolution, version comparison, and settings
   collection before touching install/update side effects.
   - Likely files: `packages/package_manager.zig`,
     `packages/package_command_parser.zig`, `packages/config_selector.zig`,
     new package helper modules.
   - Gate: `cd zig && zig build test-coding-agent`.
3. **Package manager trust/install boundaries** — split WASM validation,
   provenance snapshot/rollback, lockfile writes, and diagnostics from
   npm/git/self-update execution while keeping `executePackageCommand` as the
   facade.
   - Likely files: `packages/package_manager.zig`,
     `packages/provenance_lockfile.zig`, extension WASM manifest helpers.
   - Gate: `cd zig && zig build test-coding-agent`; preserve atomicity and
     redaction assertions.
4. **TS-RPC extension UI boundary** — extract pending extension UI request
   state, timeout/cancel cleanup, host UI request translation, and correlated
   response forwarding.
   - Likely files: `modes/ts_rpc_mode.zig`, `modes/ts_rpc_wire.zig`, new
     `modes/ts_rpc_extension_ui.zig`.
   - Gate: `cd zig && zig build test-ts-rpc-parity` with a timeout of at
     least 600 seconds plus `cd zig && zig build test-coding-agent`.
5. **TS-RPC command-family boundaries** — split prompt/queue, model/thinking,
   config, session lifecycle, export/stats, and extension command-context
   handlers after extension UI request correlation is stable.
   - Likely files: `modes/ts_rpc_mode.zig`, `modes/ts_rpc_state_json.zig`,
     new command-family helpers.
   - Gate: `cd zig && zig build test-ts-rpc-parity` and focused golden
     fixture diffs under `zig/test/golden/ts-rpc/`.
6. **Rendering state/reducer boundary** — move `AppState` ownership,
   snapshot cloning, active-operation state, and agent/retry/compaction event
   reducers away from draw/layout code without changing output bytes.
   - Likely files: `interactive_mode/rendering.zig`,
     `interactive_mode/chat_items.zig`,
     `interactive_mode/active_operation_rendering.zig`, new state/reducer
     helpers.
   - Gate: `cd zig && zig build test-tui`,
     `cd zig && zig build test-vaxis-m8-e2e`.
7. **Rendering layout/component boundaries** — after state is isolated, split
   footer, task panel, queued messages, chat viewport, prompt composition, and
   extension widget drawing into focused modules.
   - Likely files: `interactive_mode/rendering.zig`,
     `interactive_mode/chat_rendering.zig`,
     `interactive_mode/prompt_rendering.zig`,
     `interactive_mode/render_text.zig`, new layout helpers.
   - Gate: `cd zig && zig build test-tui`,
     `cd zig && zig build test-vaxis-m8-e2e`.
8. **Input action executors** — extract bash shortcut, queue/dequeue,
   external editor, paste/image, and overlay confirmation side effects while
   preserving configurable keybinding resolution as the only key source.
   - Likely files: `interactive_mode/input_dispatch.zig`,
     `interactive_mode/input_resolution.zig`,
     `interactive_mode/overlay_input.zig`, new action helpers.
   - Gate: `cd zig && zig build test-tui`,
     `cd zig && zig build test-cross-area`,
     `cd zig && zig build test-missing-cwd-selector`.
9. **Slash command families** — extract pure help/hotkeys/changelog text
   builders first, then session/model/settings/copy/share/export/import
   handlers with explicit mutation boundaries.
   - Likely files: `interactive_mode/slash_commands.zig`,
     `interactive_mode/command_router.zig`,
     `interactive_mode/session_lifecycle.zig`, new command-family helpers.
   - Gate: `cd zig && zig build test-coding-agent`,
     `cd zig && zig build test-tui`.
10. **Interactive main-loop split last** — only after rendering, input,
    command, session/auth, and extension UI boundaries are stable; keep
    `runInteractiveMode` as the public facade.
    - Likely files: `interactive_mode.zig`,
      `interactive_mode/session_bootstrap.zig`,
      `interactive_mode/auth_flow.zig`,
      `interactive_mode/extension_ui_bridge.zig`.
    - Gate: `cd zig && zig build test-tui`,
      `cd zig && zig build test-vaxis-m8-e2e`,
      `cd zig && zig build test-cross-area`,
      `cd zig && zig build test-missing-cwd-selector`.

**Dependencies and sequencing boundaries**:

- Do not start broad `runInteractiveMode` decomposition before render/input,
  slash-command, session/auth, and extension UI helpers are stable.
- Do not move TS-RPC deferred response flushing, prompt-task concurrency, or
  bash-task ordering until exact-byte TS-RPC parity fixtures cover the target
  behavior.
- Do not weaken package provenance rollback, digest-bound trust, policy
  diagnostics, or redaction behavior while splitting package helpers.
- Do not introduce hardcoded key checks; app/editor behavior must continue to
  resolve through configurable keybindings.
- Do not call real providers, real OAuth flows, or dev servers. Use faux/local
  fixtures only.
- Defer extension ABI/protocol redesign, provider parser changes, release
  packaging behavior changes, and any command semantic changes unless a later
  approved feature explicitly scopes them.

**M10 quality gate for this planning milestone**:

- Planning/status artifacts only.
- `git diff --stat`/`git status --porcelain` must show no M10 production-source
  implementation changes.
- Feature verification remains `npm run check`.

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
| M10 | docs only | High | none | read-only planning complete; implementation deferred |

**Net (M1–M9)**: ~−550 LOC of duplication, +~700 LOC of shared/tests/docs,
plus ~30 explicit new invariants pinned by tests or asserts.

---

## How to claim and track

M1–M9 are closed. M10 is now only a recorded plan for a future
`coding_agent/` review pass; implementation must remain deferred until a new
feature explicitly approves one of the future milestones above.
