# Risk Register — Top-N priorities

Ranked highest-risk first. Use this to schedule. Re-rank quarterly or after
each milestone.

## Top 10

Status after M1–M9: content-index stability, stop-reason coercion, Cluster A/Responses/SSE shared-provider work, partial tool-call UX policy, and the priority test-matrix sweep are complete. Remaining risks below are retained for future review passes where their issue references are still open.

### R1 — Memory leaks on aborted / errored streams
- 严重度: P0
- 涉及: `agent_loop.zig` (PartialAssistantAccumulator),
  every provider's SSE error/abort path
- 描述: Recent ownership normalization changed who frees what. Without a
  leak-tracking test that drives every provider through error/abort paths,
  silent leaks are the most likely first regression.
- 修法: ISS-201 (leak test for tool_calls), ISS-401 (abort cleanup).
- 大小: M

### R2 — Tool-call double-free risk
- 严重度: P0
- 涉及: every normalized provider
- 描述: Single-allocation rule (content_blocks owns strings, tool_calls is
  borrow-only) is correct only if `tool_calls.deinit` does not free strings.
  An accidental `freeToolCall` over a borrow-only entry would double-free.
- 修法: ISS-040 (bedrock audit), ISS-403 (clone/deinit pairing audit),
  ISS-501 (debug-mode assert, closed in `902720d3`).
- 大小: S

### R3 — `content_index` reuse / instability
- 严重度: P1
- 涉及: any provider that derives index from `active_blocks.len`
- 描述: Anthropic was just fixed; we must add a regression test (ISS-002)
  and an `EventOrderingGuard` (ISS-504).
- 大小: S

### R4 — Stop-reason coercion drift between providers
- 严重度: P1
- 涉及: every provider
- 描述: 5 providers now have `had_tool_calls and stop == .stop -> .tool_use`
  inline; if a 6th provider gets added without it, behavior diverges.
- 修法: ISS-503 (extract `coerceStopReasonForToolCalls` helper, closed in `c3e7febc`).
- 大小: S

### R5 — Provider duplication accumulating
- 严重度: P1
- 涉及: 5+ provider files
- 描述: `finalizeOutputFromPartials`, `finalizeCurrentBlock`,
  `parseSseStreamLines` outer loops, `mapStopReason`, and `emitRuntimeFailure`
  are duplicated. Every fix must be applied in N places. Recent normalization
  proved this — touched 5 files for one logical change.
- 修法: ISS-300..309 (M3–M6 shared layer migration complete); ISS-310 remains a lower-priority follow-up.
- 大小: L (sequenced into 7 small steps)

### R6 — Partial UI: tool-call-only response shows nothing
- 严重度: P1
- 涉及: `agent_loop.zig` (buildMessage)
- 描述: User sees no message_update during partial tool-call windows.
- 修法: ISS-402 (closed in `902720d3`).
- 大小: S

### R7 — `openai_chat_sse.zig` legacy path landmines
- 严重度: P1
- 涉及: `openai_chat_sse.zig`
- 描述: Only provider that intentionally dual-allocates. Future contributors
  may "normalize" it by accident, breaking compat.
- 修法: ISS-050 (better doc), ISS-051 (compact data line support).
- 大小: S

### R8 — Hook lifecycle ambiguity
- 严重度: P1
- 涉及: `agent_loop.zig` (before_tool_call, after_tool_call)
- 描述: Sequencing in parallel mode and behavior on hook errors is
  undocumented; tests don't pin it down.
- 修法: ISS-404, ISS-409.
- 大小: M

### R9 — `coding_agent/` god-files
- 严重度: P2
- 涉及: `interactive_mode.zig` (6331), `ts_rpc_mode.zig` (6232),
  `package_manager.zig` (5469), `interactive_mode/rendering.zig` (5362)
- 描述: Out of scope for this review pass, but they will eventually need
  splitting. Track here so the roadmap doesn't forget.
- 修法: separate review pass after `ai/` + `agent/` settle.
- 大小: XL

### R10 — Test matrix classification drift
- 严重度: P2
- 涉及: test suite
- 描述: M9 removed all unknown `?` cells and closed the S13/S14/S12/S6/S15
  priority sweep in `902720d3`. Remaining `❌` cells are known lower-priority
  missing coverage and should not regress back to unknown/unjustified entries.
- 修法: ISS-600 and ISS-601 are closed; ISS-602 remains open for a test-add convention.
- 大小: M

---

## Lower-priority watchlist

- `ai/http_client.zig` (2503 LOC) — central but stable
- `model_registry.zig` / `model_discovery.zig` — registry sprawl; revisit
  after providers settle
- `tui/` — defer
- `coding_agent/extensions/` — its own review pass later
