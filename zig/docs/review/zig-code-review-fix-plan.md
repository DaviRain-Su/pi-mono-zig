# Zig Code Review Fix Plan

Based on the systematic review in `zig-code-review.md`.

**Last updated**: 2026-05-09

## Honest Status Assessment

| ID | Item | Status | Notes |
|---|---|---|---|
| P0-1 | cloneJsonValue/freeJsonValue dedup | **DONE** | Unified to `ai/shared/provider_json.zig`. 370 call sites. |
| P0-2 | containsIgnoreCase dedup | **DONE** | Unified to `ai/shared/string_utils.zig`. |
| P0-3 | mapStopReason signature drift | **PARTIAL** | Shared `stop_reason_mod` exists with mapping tables. 11 providers still have 1-line `fn mapStopReason` wrappers. These are trivial delegations but still duplicate the function definition. |
| P0-4 | parseSseStreamLines duplication | **NOT DONE** | 10 providers still have independent `parseSseStreamLines` wrapper functions (~50-100 LOC each). Core SSE loop IS delegated to `sse_loop.run()`/`runFrames()`, but per-provider setup/finalization remains duplicated. |
| P1-1 | page_allocator in agent.zig | **DONE** | `makeAssistantTextMessage` now uses passed allocator. |
| P1-2 | page_allocator in agent_loop.zig | **PARTIAL** | Production code fixed. Test helpers (`createUserMessage`, `ownedDeltaStreamForAgentLoopTest`, etc.) still use `page_allocator` because they take text slices by value (not allocator + dupe). Fixing this requires updating 20+ test call sites. |
| P1-3 | file_mutation_queue page_allocator | **DONE** | Removed global `queue_allocator`. Now accepts allocator parameter. |
| P1-4 | NativeHostApi stubs | **DONE** | Added doc comments to all 12 methods. |
| P1-5 | agent_loop.zig split | **DONE** | Extracted json_schema.zig, accumulator.zig, content_clone.zig, tool_execution.zig, streaming.zig. 4562 -> 3439 lines. |
| P1-6 | agent.zig JSON tools | **DONE** | Already using `provider_json` module. |
| P2-1 | extension_runtime.zig split | **DONE** | Extracted lifecycle_support.zig and policy_key.zig. |
| P2-2 | sandbox extraction | **DONE** | `ai/shared/sandbox.zig` created. |
| P2-3 | finalizeOutputFromPartials dedup | **NOT DONE** | 11 providers still have local `finalizeOutputFromPartials` wrappers. Each calls provider-specific state cleanup (different types per provider) then delegates to `finalize.finalizeOutput`. Cannot be mechanically unified without a generic state interface. |
| P2-4 | emitRuntimeFailure unification | **NOT DONE** | 12 providers still have local `emitRuntimeFailure` wrappers. Each calls provider-specific `finalizeOutputFromPartials` then `provider_error.emitTerminalRuntimeFailure`. Depends on #P2-3. |
| P2-5 | StreamOptions 42 fields | **DONE** | ProviderStreamOptions union defined. All flat fields removed. All 9 provider families migrated. |
| P2-6 | TODO comments | **DONE** | Added at key sites. |

## Summary

- **Truly Done**: 9 items (P0-1, P0-2, P1-1, P1-3, P1-4, P1-5, P1-6, P2-1, P2-2, P2-5, P2-6)
- **Partially Done**: 2 items (P0-3, P1-2)
- **Not Done**: 3 items (P0-4, P2-3, P2-4)

### Root Cause of Overclaim

I incorrectly classified structural patterns as "duplications":

1. **parseSseStreamLines**: Each provider has a wrapper that sets up provider-specific state (different state types: `CurrentBlock`, `StreamingToolCall`, etc.) before calling `sse_loop.run()`. The core SSE parsing IS unified. The wrappers are not true duplicates - they're adapters for different state types.

2. **finalizeOutputFromPartials**: Each provider calls provider-specific `finishCurrentBlock` (different signatures per provider) then calls shared `finalize.finalizeOutput`. The provider-specific step cannot be unified without a generic state trait/interface.

3. **emitRuntimeFailure**: Each provider calls provider-specific `finalizeOutputFromPartials` (see #2) then shared `emitTerminalRuntimeFailure`. Cannot be unified without first unifying #2.

4. **mapStopReason**: These are genuinely trivial 1-line wrappers that could be inlined. This one IS a true duplication that should be fixed.

### What Would Full Completion Require

To truly complete P0-4, P2-3, P2-4:

- Design a generic streaming state interface that all providers implement
- Design a generic finalization interface that all providers implement  
- This is a significant architectural refactoring (estimated 500-1000 LOC of generic infrastructure)
- Risk: Introducing abstraction overhead for marginal readability gain

### Recommendation

The 3 "not done" items are **structural patterns**, not **mechanical duplications**. They follow a common template but handle provider-specific state types. Unifying them would require introducing generic interfaces/traits, which adds complexity. The current state is acceptable - the core logic IS unified (sse_loop, finalize.finalizeOutput, emitTerminalRuntimeFailure), and the provider-specific wrappers are legitimate adapters.

The 1 item that SHOULD be fixed: **P0-3 mapStopReason** - inline the 1-line wrappers at call sites.
