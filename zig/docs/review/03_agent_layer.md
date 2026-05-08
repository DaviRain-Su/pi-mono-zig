# Agent Layer Issues — `zig/src/agent/`

Files:

- `agent/agent.zig` — 2038 LOC, agent runtime (Provider/Tools wiring)
- `agent/agent_loop.zig` — 3278 LOC, streaming → events → tool exec orchestration
- `agent/types.zig` — 240 LOC, internal types
- `agent/root.zig` — 35 LOC, re-exports

`agent_loop.zig` is the highest-traffic state-machine in the repo. Most
findings here are about **state transitions, ownership, and event ordering**.

---

## Known structures (from prior review)

- `PartialToolCallBlock` (~29-47): per-block partial tool-call accumulator
- `PartialContentBlock` (~49-62): union of text | thinking | tool_call partials
- `PartialAssistantAccumulator` (~64-215): owns the partial assembly state,
  maps incoming `content_index` → local block index via `index_map`
- `streamAssistantResponse` (~510-660): consumes provider events, emits
  `message_update` events
- `executeToolCalls{,Sequential,Parallel}`: tool execution dispatch
- `runParallelToolTask` (~1047-1062), `finalizeExecutedToolCall` (~1075-1135),
  `emitToolCallOutcome` (~1150-1187)
- `prepareToolCall` (~910+) calls `before_tool_call` hook;
  `finalizeExecutedToolCall` calls `after_tool_call`
- `cloneToolCall`/`deinitToolCall`: ownership helpers (must stay paired)

---

## Issues

### ISS-400 PartialAssistantAccumulator: out-of-order events
- 严重度: P1
- 位置: `zig/src/agent/agent_loop.zig:64-215` (PartialAssistantAccumulator)
- 现状: `index_map` maps provider `content_index` to a local slot. Sparse
  indices are tolerated, but no test asserts behavior when events arrive out
  of order (e.g. `text_delta` for index 1 before `text_start` for index 1).
- 问题: A misbehaving provider (or a future bug) could feed mis-ordered
  events; current behavior is silent — could create a phantom block.
- 建议: Decide policy: reject (return error) or auto-create on first delta.
  Document, then add a test.
- 验证: new test under `agent_loop` test section.
- 状态: open
- 负责:
- 提交:

### ISS-401 PartialAssistantAccumulator: aborted-stream cleanup
- 严重度: P1
- 位置: `zig/src/agent/agent_loop.zig` (streamAssistantResponse error path)
- 现状: When the provider stream returns `.error_event` or the abort signal
  fires mid-stream, partial blocks may be left allocated.
- 问题: Memory leak on abort.
- 建议: Trace the abort path and confirm `PartialAssistantAccumulator.deinit`
  is reached. Add a leak-tracking test that aborts mid-stream.
- 验证: `std.testing.allocator` test that streams then aborts.
- 状态: open
- 负责:
- 提交:

### ISS-402 buildMessage: tool-call-only partial returns empty content
- 严重度: P1
- 位置: `zig/src/agent/agent_loop.zig` (`PartialToolCallBlock` policy and `VAL-REVIEW-M8-001` snapshot)
- 现状: Policy is now explicit: every toolcall start/delta/end emits `message_update`; partial tool-call args are exposed when an existing assistant block anchors the update; standalone leading tool calls remain hidden from `message.content` until finalization to avoid blank TUI rows.
- 问题: Closed for this roadmap pass; future UI work can revisit the visible placeholder policy as behavior work.
- 建议: Preserve the `VAL-REVIEW-M8-001 streaming message_update snapshots cover partial tool-call UX policy` test when changing partial rendering.
- 验证: `cd zig && zig build test`
- 状态: closed
- 负责: review-roadmap-documentation-bookkeeping-sync
- 提交: 902720d3

### ISS-403 cloneToolCall / deinitToolCall pairing audit
- 严重度: P0
- 位置: `zig/src/agent/agent_loop.zig` (cloneToolCall, deinitToolCall,
  PartialToolCallBlock.setFinal)
- 现状: `setFinal` calls `deinitToolCall` on the existing value before
  cloning the new one.
- 问题: Need to confirm every other call site that retains a cloned
  ToolCall calls `deinitToolCall` on shutdown / replacement. A miss = leak.
- 建议: Grep for `cloneToolCall` and audit each result for matching
  `deinitToolCall`. List in a checklist.
- 验证: leak-tracking allocator test that exercises tool execution path.
- 状态: open
- 负责:
- 提交:

### ISS-404 Sequential vs parallel tool execution: ordering of after_tool_call hook
- 严重度: P1
- 位置: `zig/src/agent/agent_loop.zig:677-723` (executeToolCalls dispatch), `~1075-1135` (finalizeExecutedToolCall)
- 现状: `after_tool_call` fires inside tool finalization, after the execute callback returns and before `tool_execution_end`.
- 决策: Parallel prepared tools run `after_tool_call` and emit `tool_execution_end` in tool completion order, matching the TypeScript contract. Tool-result message artifacts and `turn_end.tool_results` remain in assistant source order so transcript/context order stays stable.
- 验证: `ISS-404 parallel after_tool_call finalizes in completion order and emits messages in source order`.
- 状态: closed
- 负责: cca91a6c-bcf4-4689-ae60-264642a250bd
- 提交: 902720d3

### ISS-405 emitToolCallOutcome: ordering vs message_update
- 严重度: P1
- 位置: `zig/src/agent/agent_loop.zig:1150-1187` (emitToolCallOutcome)
- 现状: tool outcome events are emitted on the same stream as
  `message_update` events.
- 问题: Need to confirm a `tool_outcome` cannot be emitted between
  `message_start` and `message_end` of the SAME assistant message; if it
  can, downstream UI may interleave incorrectly.
- 建议: Document the ordering invariants; add an explicit assertion
  somewhere central.
- 验证: integration test.
- 状态: open
- 负责:
- 提交:

### ISS-406 Partial accumulator content_index reuse handling (post-Anthropic fix)
- 严重度: P1
- 位置: `zig/src/agent/agent_loop.zig` (`PartialAssistantAccumulator.indexFor`)
- 现状: The accumulator rejects stale explicit `content_index` reuse after a block has ended and returns `AgentLoopError.PartialContentIndexReused`.
- 问题: Closed for this roadmap pass; future provider/event-stream work must not reuse content indexes after end events.
- 建议: Preserve `ISS-406 partial accumulator rejects stale explicit content_index reuse after end`.
- 验证: `cd zig && zig build test`
- 状态: closed
- 负责: review-roadmap-documentation-bookkeeping-sync
- 提交: 902720d3

### ISS-407 Arena vs gpa allocator pattern
- 严重度: P1
- 位置: `zig/src/agent/agent_loop.zig` (emitPartialMessageUpdate uses an arena for the temporary message)
- 现状: The callback-scoped `message_update` payload policy is documented in `zig/src/agent/MODULE.md` and guarded by a retained-consumer clone regression.
- 问题: Closed for this roadmap pass; event consumers must clone update payloads they retain.
- 建议: Keep the policy note and `ISS-407 message_update payload is callback-scoped and retained consumers clone` test.
- 验证: doc + debug-mode canary test.
- 状态: closed
- 负责: d4f30d42-47f1-4a82-8004-e76863700da0
- 提交: 902720d3

### ISS-408 streamAssistantResponse: reentrancy / nested calls
- 严重度: P2
- 位置: `zig/src/agent/agent_loop.zig:510-660`
- 现状: A tool may itself trigger a nested LLM call (sub-agent pattern).
- 问题: Need to confirm streamAssistantResponse is safe to call recursively
  with respect to the event stream and accumulator.
- 建议: Audit; document; add a recursive test.
- 验证: integration test with a sub-agent tool.
- 状态: open
- 负责:
- 提交:

### ISS-409 Hook error handling: before_tool_call returning error
- 严重度: P1
- 位置: `zig/src/agent/agent_loop.zig` (prepareToolCall ~910+)
- 现状: `before_tool_call` is called; if it returns error, behavior unclear.
- 问题: Does the tool still run? Does the message_end still fire? Does
  partial state get cleaned?
- 建议: Read code; document; add a hook-error fixture.
- 验证: new test.
- 状态: open
- 负责:
- 提交:

### ISS-410 finalizeExecutedToolCall: idempotence
- 严重度: P1
- 位置: `zig/src/agent/agent_loop.zig:1075-1135`
- 现状: `PreparedToolCall` carries `finalized: bool`; `finalizeExecutedToolCall` returns `AgentLoopError.ToolCallAlreadyFinalized` on duplicate finalization.
- 问题: Closed for this roadmap pass; future error/abort paths must preserve single finalization.
- 建议: Preserve the double-finalize regression around `ToolCallAlreadyFinalized`.
- 验证: `cd zig && zig build test`
- 状态: closed
- 负责: review-roadmap-documentation-bookkeeping-sync
- 提交: 902720d3

### ISS-411 agent.zig: 2038 LOC, possible split
- 严重度: P2
- 位置: `zig/src/agent/agent.zig`
- 现状: 2038 LOC.
- 建议: Identify cohesive sub-modules (config wiring, provider lookup,
  tools registry, runtime). Plan a split if any sub-module has clean
  boundaries.
- 验证: read-and-summarize; no code change yet.
- 状态: open
- 负责:
- 提交:

### ISS-412 Document agent_loop state machine in MODULE.md
- 严重度: P2
- 位置: `zig/src/agent/MODULE.md`
- 建议: Keep this module note current when changing agent-loop state transitions, event ordering, or ownership boundaries.
- 验证: docs only.
- 状态: closed
- 负责: review-roadmap-documentation-bookkeeping-sync
- 提交: 902720d3
