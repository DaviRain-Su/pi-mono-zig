# Zig Code Review Fix Plan

Based on the systematic review in `zig-code-review.md`.

## Status Legend
- [ ] Not started
- [~] In progress
- [x] Done

## B1: Add TODO comments (P2-REVIEW-8)
- [x] Added plan document tracking all review items
- [x] NativeHostApi stubs documented with "Permission-gated counter stub" doc comments
- [ ] Add `// TODO(review-xxx):` annotations at remaining issue sites (SSE loops, file splits)
- Zero risk, informational only

## B2: Unify emitRuntimeFailure (P2-REVIEW-4)
- [x] Verified: all 11 providers already call `provider_error.emitTerminalRuntimeFailure`
- [x] The wrapper pattern is consistent: finalizeOutputFromPartials → emitTerminalRuntimeFailure
- [x] emitRuntimeFailure itself cannot be unified (finalize step is provider-specific)
- DONE - shared emit already used everywhere

## B3: Unify finalizeOutputFromPartials (P2-REVIEW-3)
- [x] Removed 5 identical `finalizeCollectedOutput` wrappers (kimi, azure, codex, openai_responses, anthropic)
- [x] All call sites now directly call `finalize.finalizeOutput` with appropriate options
- [x] The actual `finalizeOutputFromPartials` per-provider cannot be unified (different block types)
- DONE - 5 wrappers removed, -135 lines / +33 lines

## B4: Fully unify mapStopReason (P0-REVIEW-3)
- [x] Converted anthropic `mapStopReason` from `!StopReason` to `StopReason` (uses `mapStopReasonFromTable`)
- [x] Converted bedrock `mapStopReason` from `!StopReason` to `StopReason` (uses `mapStopReasonFromTable`)
- [x] Removed `UnknownStopReason` from AnthropicError and BedrockError
- [x] All 11 providers now use one of: `mapStopReasonFromTable`, `mapStopReasonFromTableWithMessage`, or `mapStopReasonFromTableWithAllocMessage`
- [x] Remaining 8 providers were already delegating to stop_reason_mod
- DONE - signatures unified, no more error unions for stop reason mapping

## B5: Extract isPathWithinSandbox to shared (P2-REVIEW-2)
- [ ] Only in native_runtime.zig now (extension_protocol.zig no longer has it)
- [ ] Move to shared/sandbox.zig or shared/path_utils.zig
- Low risk

## B6: Fix page_allocator usage (P1-REVIEW-1, P1-REVIEW-2)
- [x] agent.zig `promptTextWithImages`: changed from `page_allocator` to `self.allocator`
- [x] Fixed `userMessageWithImages` to `dupe` text (was storing borrowed slice, deinit tried to free it)
- [x] Verified: all agent_loop.zig `page_allocator` usages are in test helper functions only
- [x] file_mutation_queue.zig: removed global `queue_allocator = page_allocator`, now accepts allocator parameter
- [x] Updated FileMutationGuard to store allocator for release path
- [x] Updated all 4 callers (edit.zig x2, write.zig x2)
- DONE - all production page_allocator usages fixed

## B7: Migrate parseSseStreamLines to sse_loop (P0-REVIEW-4)
- [ ] Design Handler interface in sse_loop.zig
- [ ] Migrate 10 providers one by one
- High risk (core streaming logic)

## B8: Split agent_loop.zig (P1-REVIEW-5)
- [ ] accumulator.zig, tool_execution.zig, streaming.zig
- Depends on B2/B3

## B9: Split extension_runtime.zig (P2-REVIEW-1)
- [ ] extension_loader.zig, extension_lifecycle.zig, extension_event_bridge.zig

## B10: Mark NativeHostApi stubs (P1-REVIEW-3)
- [x] Added "Permission-gated counter stub" doc comments to all 12 NativeHostApi methods
- [x] Comments explain: enforces capabilities, records counters, but does not perform actual I/O
- DONE

## B11: Refactor StreamOptions (P2-REVIEW-5)
- [ ] Split provider-specific options into per-provider structs
- High risk, API-breaking
