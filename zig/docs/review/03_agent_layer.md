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
- 位置: `zig/src/agent/agent_loop.zig:189-214` (buildMessage), `~217-235`
  (buildPartialToolCallBlock)
- 现状: When the only block is a tool_call, buildMessage returns an empty
  content slice. UI gets nothing during that window.
- 问题: Streaming UX: user sees nothing while the tool name/args are still
  arriving. The partial placeholder (`id="" name=""`) never surfaces.
- 建议: Decide whether partial tool-call should be visible. Either:
  (a) emit a placeholder `.tool_call` block in content with the partial id/
  name/args so UI can show "running tool: …", or
  (b) document the invisibility as intentional.
- 验证: snapshot test of streamed message_update events.
- 状态: open
- 负责:
- 提交:

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
- 位置: `zig/src/agent/agent_loop.zig:677-723` (executeToolCalls dispatch),
  `~1075-1135` (finalizeExecutedToolCall)
- 现状: `after_tool_call` fires inside tool finalization, after the execute
  callback returns and before `tool_execution_end`.
- 决策: Parallel prepared tools run `after_tool_call` and emit
  `tool_execution_end` in tool completion order, matching the TypeScript
  contract. Tool-result message artifacts and `turn_end.tool_results` remain
  in assistant source order so transcript/context order stays stable.
- 验证: `ISS-404 parallel after_tool_call finalizes in completion order and
  emits messages in source order`.
- 状态: closed
- 负责: cca91a6c-bcf4-4689-ae60-264642a250bd
- 提交: pending (mission workers leave changes uncommitted)

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
- 位置: `zig/src/agent/agent_loop.zig` (PartialAssistantAccumulator.indexFor)
- 现状: We assume `content_index` is stable. Anthropic was just fixed to
  honor that. Other providers using `block_order.items.len` are stable too.
- 问题: If a future provider mistakenly reuses an index, the accumulator
  silently overwrites the prior block.
- 建议: When `indexFor(idx)` returns an existing slot whose state has
  already been "ended" (text_end / thinking_end / toolcall_end seen), log
  or assert. In debug builds, panic.
- 验证: unit test feeding a duplicate-index sequence asserts the new
  guard fires.
- 状态: open
- 负责:
- 提交:

### ISS-407 Arena vs gpa allocator pattern
- 严重度: P1
- 位置: `zig/src/agent/agent_loop.zig` (emitPartialMessageUpdate uses an arena
  for the temporary message)
- 现状: Partial message build uses a per-update arena.
- 问题: If any field of the temporary message references a buffer owned by
  the gpa-side accumulator, that pointer is fine while the arena is live.
  But if the consumer of the `message_update` event retains the pointer
  past the event handler return, it is freed.
- 建议: Document the invariant explicitly: "message_update payload pointers
  are valid only during the event callback; consumers must clone if they
  retain". Add a debug-build canary that scribbles the arena memory after
  the callback returns.
- 验证: doc + debug-mode canary test.
- 状态: closed
- 负责: d4f30d42-47f1-4a82-8004-e76863700da0
- 提交: pending (mission workers leave changes uncommitted)

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
- 现状: Tool finalization can be reached via normal path or error-recovery.
- 问题: If both fire (e.g. tool errored, then aborted), is finalize called
  twice? That would double-free the cloned ToolCall.
- 建议: Add a `finalized: bool` flag on the per-tool record; assert on
  duplicate finalize.
- 验证: leak-tracking test that errors then aborts.
- 状态: open
- 负责:
- 提交:

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
- 位置: new file `zig/src/agent/MODULE.md`
- 建议: Include a state diagram (text-only ASCII) covering:
  start → text/thinking/toolcall partials → tool exec → after-hook → message_end
  with abort/error transitions.
- 验证: docs only.
- 状态: open
- 负责:
- 提交:
