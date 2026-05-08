# Cross-Cutting Contract Issues

Files in scope:

- `zig/src/ai/types.zig` (764 LOC)
- `zig/src/ai/event_stream.zig` (402 LOC)
- `zig/src/ai/stream.zig` (1247 LOC)

These define the contracts every provider and `agent_loop` must obey. They
are the right place to **encode invariants as types or asserts** so future
changes can't silently break them.

---

## Invariants that should be explicit

### INV-1 — `AssistantMessage.tool_calls` is null after normalization
- After commit `fde1951f`, every provider except `openai_chat_sse.zig` leaves
  `tool_calls = null`. Inline `.tool_call` blocks in `content` are the
  canonical source.
- **Currently**: encoded only in comments scattered across providers.
- **Should be**: a documented invariant in `types.zig` near the field
  definition; ideally a debug-mode assert in `freeAssistantMessage` that
  warns if both `tool_calls != null` and any `content[i] == .tool_call`.

### INV-2 — `Event.content_index` is stable for the stream lifetime
- An index assigned to a `text_start` / `thinking_start` / `toolcall_start`
  uniquely identifies that block until its matching `_end`. Indices are
  never reused.
- **Currently**: implicit; depends on each provider's discipline.
- **Should be**: documented invariant near `Event.content_index` in
  `event_stream.zig` (or wherever `Event` lives). Optional: a
  `DebugIndexTracker` wrapper for tests.

### INV-3 — Event ordering for a single block
- `_start → _delta* → _end`. No `_delta` without a preceding `_start`. No
  second `_start` for the same index without an `_end` first.
- **Currently**: implicit.
- **Should be**: doc + a `std.debug.assert` in the stream consumer.

### INV-4 — `done` is the last event for a successful stream
- After `done`, no further events for that stream.
- **Currently**: implicit.

### INV-5 — `error_event` terminates the stream
- After `error_event`, no further events. `output.error_message` is set,
  `output.stop_reason` is set to a terminal error reason.
- **Currently**: implicit; some providers set both, some only one.

### INV-6 — Stop reason coercion
- If any tool calls were emitted and the upstream stop reason is `.stop`,
  coerce to `.tool_use`. Provider-side, not agent-side.
- **Currently**: implemented per-provider (and recently corrected in
  `azure_openai_responses.zig`, `openai_codex_responses.zig`, `kimi.zig`).
- **Should be**: a small shared helper `coerceStopReason(stop_reason,
  had_tool_calls)` in `ai/shared/`.

### INV-7 — Allocator ownership
- Every owned slice/string in `AssistantMessage` is allocated with the
  `allocator` passed into the provider's `stream()` call. `freeAssistantMessage`
  is the only deallocator.
- **Currently**: implicit; not asserted.

---

## Issues

### ISS-500 Document INV-1 in types.zig
- 严重度: P1
- 位置: `zig/src/ai/types.zig` (AssistantMessage definition)
- 建议: Keep the doc comment above `tool_calls` synchronized with INV-1 and the legacy OpenAI Chat SSE exception.
- 验证: docs only.
- 状态: closed
- 负责: review-roadmap-documentation-bookkeeping-sync
- 提交: 902720d3

### ISS-501 Add debug-mode assert for INV-1 in freeAssistantMessage
- 严重度: P1
- 位置: `zig/src/ai/types.zig` (freeAssistantMessage)
- 建议: Preserve `assertNoInvalidDualOwnedToolCalls` so normalized providers cannot alias inline and legacy tool-call storage in debug tests.
- 验证: existing tests.
- 状态: closed
- 负责: review-roadmap-documentation-bookkeeping-sync
- 提交: 902720d3

### ISS-502 Document INV-2 / INV-3 / INV-4 / INV-5 in event_stream.zig
- 严重度: P1
- 位置: `zig/src/ai/event_stream.zig` (Event / EventType definitions)
- 建议: Keep the top-of-file invariant block synchronized with event stream behavior.
- 验证: docs only.
- 状态: closed
- 负责: review-roadmap-documentation-bookkeeping-sync
- 提交: 902720d3

### ISS-503 Extract `coerceStopReason` helper
- 严重度: P1
- 位置: `zig/src/ai/shared/provider_error.zig::coerceStopReasonForToolCalls`
- 建议: New providers that emit tool calls should use the shared helper instead of reintroducing inline coercion.
- 验证: existing parity tests.
- 状态: closed
- 负责: review-roadmap-documentation-bookkeeping-sync
- 提交: c3e7febc

### ISS-504 Add a debug-mode `EventOrderingGuard` for INV-3
- 严重度: P2
- 位置: new file `zig/src/ai/event_stream_guard.zig`
- 建议: Wraps `AssistantMessageEventStream` and tracks per-content_index
  state (start_seen, end_seen). Asserts ordering. Only active in debug.
- 验证: `EventOrderingGuard` tests cover valid interleaved provider-style
  text/thinking/tool-call ordering plus delta-before-start, end-before-start,
  duplicate start, content-index reuse, kind drift, delta-after-end, terminal
  with open block, and post-terminal event violations.
- 状态: closed
- 负责: zrb-06-event-ordering-guard-and-stopreason-audit
- 提交:

### ISS-505 stream.zig vs event_stream.zig responsibility split
- 严重度: P2
- 位置: `zig/src/ai/stream.zig` (1247 LOC), `zig/src/ai/event_stream.zig` (402 LOC)
- 现状: Two files; relationship not obviously documented.
- 建议: Add a top-comment in each describing what it owns. If overlap
  exists, plan a consolidation.
- 验证: docs only.
- 状态: open
- 负责:
- 提交:

### ISS-506 ToolCall.thought_signature ownership and lifecycle
- 严重度: P1
- 位置: `zig/src/ai/types.zig` (ToolCall.thought_signature)
- 现状: Optional encrypted reasoning attached to a tool call. Some providers
  set it (openai_chat_sse, openai_responses with `reasoning_details`).
  Anthropic uses signature on thinking blocks, not on tool calls.
- 问题: Cross-provider semantics drift. Document who sets it, who reads it,
  and the freeing rule (allocator.dupe → free in deinitToolCall).
- 建议: Add a comment block near the field definition.
- 验证: `ToolCall.thought_signature` now documents provider allocation,
  same-model replay preservation, cross-model dropping, and deinit ownership.
- 状态: closed
- 负责: zrb-06-event-ordering-guard-and-stopreason-audit
- 提交:

### ISS-507 StopReason exhaustiveness on the consumer side
- 严重度: P2
- 位置: `zig/src/ai/types.zig` (StopReason enum) + agent_loop.zig consumers
- 建议: Verify every consumer uses an exhaustive switch on `StopReason`
  (no `else =>` arms that would silently absorb a future variant).
- 验证: Consumer audit removed broad `else` arms from user-visible
  `StopReason` handling in `print_mode.zig`, `provider_config.zig`, and
  `interactive_mode/rendering.zig`; existing string serializers and session
  JSONL/RPC helpers were already exhaustive or direct two-terminal-reason
  predicates.
- 状态: closed
- 负责: zrb-06-event-ordering-guard-and-stopreason-audit
- 提交:
