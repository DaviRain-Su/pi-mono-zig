# Zig Code Review Fix Plan

Based on the systematic review in `zig-code-review.md`.

## Status Legend
- [ ] Not started
- [~] In progress
- [x] Done

## B1: Add TODO comments (P2-REVIEW-8)
- [x] Added plan document tracking all review items
- [x] NativeHostApi stubs documented with "Permission-gated counter stub" doc comments
- [x] TODO(review-B7) on parseSseStreamLines (azure_openai_responses.zig)
- [x] TODO(review-B8) on agent_loop.zig
- [x] TODO(review-B9) on extension_runtime.zig
- [x] TODO(review-B11) on StreamOptions in types.zig
- DONE

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
- [x] Created `ai/shared/sandbox.zig` with `isPathWithinSandbox` and `isSafeRelativePathSuffix`
- [x] Exported via `ai.shared.sandbox` in `ai/root.zig`
- [x] Removed local functions and tests from `native_runtime.zig`
- [x] Updated `ensureSandboxPath` to use `sandbox.isPathWithinSandbox`
- [x] Tests moved to shared module with broader coverage
- DONE

## B6: Fix page_allocator usage (P1-REVIEW-1, P1-REVIEW-2)
- [x] agent.zig `promptTextWithImages`: changed from `page_allocator` to `self.allocator`
- [x] Fixed `userMessageWithImages` to `dupe` text (was storing borrowed slice, deinit tried to free it)
- [x] Verified: all agent_loop.zig `page_allocator` usages are in test helper functions only
- [x] file_mutation_queue.zig: removed global `queue_allocator = page_allocator`, now accepts allocator parameter
- [x] Updated FileMutationGuard to store allocator for release path
- [x] Updated all 4 callers (edit.zig x2, write.zig x2)
- DONE - all production page_allocator usages fixed

## B7: Migrate parseSseStreamLines to sse_loop (P0-REVIEW-4)
- [x] VERIFIED: All 10 providers already use sse_loop.run() or sse_loop.runFrames()
- [x] azure_openai_responses, bedrock, google, google_vertex, google_gemini_cli,
      kimi, mistral, openai_chat_sse, openai_codex_responses, openai_responses
      all delegate SSE outer loop to shared sse_loop module
- [x] anthropic uses sse_loop.runFrames() for frame-based SSE
- [x] The remaining parseSseStreamLines wrappers handle provider-specific state
      setup and finalization — this per-provider variation is legitimate
- DONE - misleading TODO comment removed from azure_openai_responses.zig

## B8: Split agent_loop.zig (P1-REVIEW-5)
- [x] Extracted json_schema.zig (~200 LOC of JSON schema validation)
- [ ] Extract accumulator.zig (PartialAssistantAccumulator, PartialToolCallBlock, PartialContentBlock)
- [ ] Extract tool_execution.zig (executeToolCalls, prepareToolCall, parallel execution)
- [ ] Extract streaming.zig (streamAssistantResponse, streamSimpleForAgentLoop)
- DONE for Phase 1 - remaining extractions are lower priority

## B9: Split extension_runtime.zig (P2-REVIEW-1)
- [x] Extracted lifecycle_support.zig (~130 LOC of lifecycle matrix definitions)
- [ ] Extract policy_key.zig (policy lookup helpers)
- [ ] Extract extension_loader.zig, extension_lifecycle.zig, extension_event_bridge.zig
- DONE for Phase 1 - remaining extractions are lower priority

## B10: Mark NativeHostApi stubs (P1-REVIEW-3)
- [x] Added "Permission-gated counter stub" doc comments to all 12 NativeHostApi methods
- [x] Comments explain: enforces capabilities, records counters, but does not perform actual I/O
- DONE

## B11: Refactor StreamOptions (P2-REVIEW-5)
- [x] Added ProviderStreamOptions union with 7 provider variants
- [x] Added provider field to StreamOptions (backward-compatible)
- [x] Migrated toStreamOptions() to populate provider union
- [x] Migrated ALL providers to read from provider union:
  - mistral, google (x3), openai_chat_payload, openai_responses,
    openai_codex_responses, azure_openai_responses, anthropic, bedrock
- [x] Updated stream.zig to populate provider union
- [ ] Phase 5: Remove flat fields from StreamOptions (future breaking change)
- DONE for Phase 1-4 - all providers migrated
