# Provider Duplication & Shared Layer Plan

After the recent normalization, the next high-value structural change is
**extracting the duplicated finalize/parse/error helpers** into
`zig/src/ai/shared/` (already exists — just under-used).

The goal: cut 6000+ LOC of near-identical boilerplate across providers, and
make the cross-provider invariant (single-allocation tool_calls, stop_reason
coercion, terminal error frame, content_index stability) **structurally
unrepresentable** — no longer something each provider has to remember.

---

## Existing shared layer

`zig/src/ai/shared/` already contains:

| LOC | File | What it does |
|---:|---|---|
| 379 | `provider_stream.zig` | shared SSE/stream utilities (under-used) |
| 504 | `provider_error.zig` | runtime error → stop_reason mapping (already used) |
| 153 | `provider_json.zig` | JSON parse helpers |
| 1249 | `transform_messages.zig` | wire-format conversion |
| 170 | `simple_options.zig` | options merging |
| 27 | `abort_signal.zig` | cancellation token |
| 140 | `overflow.zig` | stream overflow guard |

`provider_error.zig` is the model to copy — small, focused, reused. The
finalize/parse helpers should follow that style.

---

## Duplication clusters

### Cluster A — shared `finalizeOutput` adapters

Shape: takes (allocator, output, current_block, active_tool_calls,
pending_tool_calls, content_blocks, tool_calls, stream_ptr); finishes any
in-flight block, transfers content_blocks to output.content; tool_calls is
borrow-only.

Sites:
- `openai_responses.zig`
- `openai_codex_responses.zig`
- `azure_openai_responses.zig`
- `bedrock.zig`
- `kimi.zig`
- `anthropic.zig`

Status after M4/M5/M6: the shared transfer/coercion logic lives in
`zig/src/ai/shared/finalize.zig::finalizeOutput`, Responses-style block
finalization lives in `zig/src/ai/shared/responses_api.zig`, and the generic
SSE loop lives in `zig/src/ai/shared/sse_loop.zig`. Cluster A providers retain
small provider-local adapters only for provider-specific current-block flushing,
Bedrock event-index insertion, Responses pending/active tool-call queues, and
runtime/error emission. Those adapters must delegate the final
content-transfer/usage/stop-reason step to `finalize.finalizeOutput`; they must
not reintroduce provider-local ownership-transfer copies.

Intentionally retained outside Cluster A:
- `openai_chat_sse.zig` keeps legacy chat SSE output finalization and its
  `output.tool_calls` compatibility path. This is tracked as an intentional
  exception in `01_provider_layer.md` and `06_risk_register.md`.
- `google.zig`, `google_vertex.zig`, `google_gemini_cli.zig`, and
  `mistral.zig` are not part of the M4 Cluster A migration. Their local output
  finalizers remain future/provider-specific work.

### Cluster B — `finalizeCurrentBlock`

Shape: takes a `CurrentBlock` union (text | thinking | tool_call) and
emits the appropriate `_end` event + appends to content_blocks.

Sites:
- `openai_responses.zig`
- `openai_codex_responses.zig`
- `azure_openai_responses.zig`

The three `*_responses.zig` files have nearly identical impls.

### Cluster C — `parseSseStreamLines` outer loop

Shape: iterate raw response lines, accumulate `event:` + `data:`, dispatch
on blank line, support abort, finalize on EOF.

Sites: nearly every provider. Sufficient variation per provider made a full
parser extraction risky, so the implemented shared surface is a generic line
iterator with provider-supplied data-line/frame handlers. The legacy OpenAI
Chat parser now uses that outer iterator for line reading and abort checks
while keeping Chat Completions delta accumulation and dual-allocation
compatibility local to `openai_chat_sse.zig`.

### Cluster D — `mapStopReason`

Shape: map provider-string → `types.StopReason` enum.

Sites: `anthropic.zig`, `bedrock.zig`, `openai_responses.zig`,
`openai_codex_responses.zig`, `azure_openai_responses.zig`, `mistral.zig`,
`openai_chat_sse.zig`.

Each has its own vocabulary. Do **not** unify into one mapping function;
instead, each stays provider-specific but they all return the same enum.
What can be unified: the *post-mapping* coercion `had_tool_calls and reason
== .stop -> .tool_use`.

### Cluster E — Streaming JSON args repair

Shape: incremental JSON args parsing with fallback to `{}`.

Sites: `openai_chat_sse.zig`, `kimi.zig`, anthropic-style providers.

### Cluster F — `emitRuntimeFailure`

Shape: call `finalizeOutputFromPartials`, set `output.stop_reason` and
`output.error_message` from `provider_error.runtimeStopReason/Message`,
push terminal frame.

Sites: `openai_responses.zig`, `openai_codex_responses.zig`,
`azure_openai_responses.zig`, `kimi.zig`. Already mostly factored — just
needs a single shared wrapper.

---

## Proposed shared API

### `zig/src/ai/shared/finalize.zig`

Implemented in M3 by commits `bb0edc86` through `632d0c79`.

```zig
/// Append a finalized inline tool_call block. Single allocation: content_blocks
/// owns the strings; tool_calls keeps a borrow-only copy.
pub fn appendInlineToolCall(
    allocator: std.mem.Allocator,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    owned_tool_call: types.ToolCall,
) !void;

/// Insert a finalized inline tool_call block at a provider-supplied content
/// index while keeping the same borrow-only tool_calls copy.
pub fn insertInlineToolCall(
    allocator: std.mem.Allocator,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    insert_index: usize,
    owned_tool_call: types.ToolCall,
) !void;
```

M4 added a small state wrapper plus provider-selectable finalization modes:

```zig
pub const FinalizeState = struct {
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
};

pub const ContentTransferMode = enum {
    when_output_empty,
    always,
};

pub const TotalTokenMode = enum {
    preserve,
    preserve_or_input_output,
    preserve_or_full_usage,
};

pub const FinalizeOutputOptions = struct {
    content_transfer: ContentTransferMode = .when_output_empty,
    total_tokens: TotalTokenMode = .preserve_or_input_output,
    coerce_stop_reason_for_tool_calls: bool = false,
};

/// Move content_blocks into output.content, leave output.tool_calls null.
/// Coerce output.stop_reason from .stop to .tool_use if any tool calls were
/// emitted. Idempotent.
pub fn finalizeOutput(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    state: FinalizeState,
    options: FinalizeOutputOptions,
) !void;
```

### `zig/src/ai/shared/responses_api.zig` (new)

OpenAI-Responses-style finalize-current-block helper for the three
`*_responses.zig` providers.

```zig
pub const CurrentBlock = union(enum) {
    text: TextBlockState,
    thinking: ThinkingBlockState,
    tool_call: ToolCallBlockState,
};

pub fn finalizeCurrentBlock(
    allocator: std.mem.Allocator,
    abort: ?abort_signal.AbortSignal,
    current_block: *?CurrentBlock,
    state: FinalizeState,
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void;
```

### `zig/src/ai/shared/sse_loop.zig`

Generic outer SSE iterator. Providers supply typed handlers for either
single-line `data:` streams or frame-oriented SSE streams.

```zig
pub fn run(
    comptime Handler: type,
    handler: *Handler,
    streaming: *http_client.StreamingResponse,
    stream_options: ?types.StreamOptions,
) !LoopResult;

pub fn runFrames(
    allocator: std.mem.Allocator,
    comptime Handler: type,
    handler: *Handler,
    streaming: *http_client.StreamingResponse,
    stream_options: ?types.StreamOptions,
) !LoopResult;
```

### `zig/src/ai/shared/runtime_error.zig` (new — small)

Wraps the shared "emit terminal failure" pattern.

```zig
pub fn emitTerminal(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    state: FinalizeState,
    err: anyerror,
) !void;
```

---

## Migration plan

Order matters. Each step must keep `zig build test` green.

### Step 1 — `appendInlineToolCall` helper
- Add `zig/src/ai/shared/finalize.zig`.
- Migrate **only `bedrock.zig`** to use it (smallest blast radius).
- Run `zig build test-bedrock-parity`.
- Commit.

### Step 2 — Migrate the three `*_responses.zig` to `appendInlineToolCall`
- One commit per provider.
- Verify with `zig build test-openai-responses-parity` after each.

### Step 3 — Migrate `kimi.zig` and `anthropic.zig`
- One commit each.
- Verify with `zig build test-ai`.

### Step 4 — `finalizeOutput` unification
- Replace Cluster A provider-local output ownership transfer with calls to the
  shared helper.
- Done for bedrock, anthropic, kimi, openai_responses,
  openai_codex_responses, and azure_openai_responses.

### Step 5 — `responses_api.finalizeCurrentBlock`
- Extract for the three `*_responses.zig` providers.
- One commit per provider.

### Step 6 — `sse_loop.runSseLoop`
- This is bigger and riskier. Save for last.
- First migrate `kimi.zig` (smallest), then `*_responses.zig`, then
  `anthropic.zig` (preserve tolerance modes).

### Step 7 — `emitTerminal` consolidation
- Trivial wrapper; can land at any time after Step 1.

---

## Issue tracker

### ISS-300 Step 1: introduce `shared/finalize.zig` with `appendInlineToolCall`
- 严重度: P2
- 位置: new file `zig/src/ai/shared/finalize.zig`
- 建议: implement the API as documented above.
- 验证: `zig build test-bedrock-parity` + `zig build test-ai`.
- 状态: done
- 负责: 25c1e9f9-c8ea-4ee8-80d7-c533966cace3 verification
- 提交: bb0edc86

### ISS-301 Step 2a: migrate `bedrock.zig` to use `appendInlineToolCall`
- 严重度: P2
- 位置: `zig/src/ai/providers/bedrock.zig` (collectOutputFromPartials,
  finalizeOutputFromPartials, handleContentBlockStop tool_call branches)
- 状态: done
- 负责: 25c1e9f9-c8ea-4ee8-80d7-c533966cace3 verification
- 提交: e1b62ef2

### ISS-302 Step 2b: migrate `openai_responses.zig`
- 严重度: P2
- 位置: `zig/src/ai/providers/openai_responses.zig`
- 状态: done
- 负责: 25c1e9f9-c8ea-4ee8-80d7-c533966cace3 verification
- 提交: d2021dec

### ISS-303 Step 2c: migrate `openai_codex_responses.zig`
- 严重度: P2
- 位置: `zig/src/ai/providers/openai_codex_responses.zig`
- 状态: done
- 负责: 25c1e9f9-c8ea-4ee8-80d7-c533966cace3 verification
- 提交: dd8c0c8c

### ISS-304 Step 2d: migrate `azure_openai_responses.zig`
- 严重度: P2
- 位置: `zig/src/ai/providers/azure_openai_responses.zig`
- 状态: done
- 负责: 25c1e9f9-c8ea-4ee8-80d7-c533966cace3 verification
- 提交: fae46df5

### ISS-305 Step 3a: migrate `kimi.zig`
- 严重度: P2
- 位置: `zig/src/ai/providers/kimi.zig`
- 状态: done
- 负责: 25c1e9f9-c8ea-4ee8-80d7-c533966cace3 verification
- 提交: b498c1e9

### ISS-306 Step 3b: migrate `anthropic.zig`
- 严重度: P2
- 位置: `zig/src/ai/providers/anthropic.zig`
- 状态: done
- 负责: 25c1e9f9-c8ea-4ee8-80d7-c533966cace3 verification
- 提交: 632d0c79

### ISS-307 Step 4: unify `finalizeOutput` across Cluster A providers
- 严重度: P2
- 位置: every provider listed in Cluster A
- 状态: done
- 负责: bc5ff419-1758-411e-9a13-c25494e4ed9c verification
- 提交: 3306500c

### ISS-308 Step 5: extract `finalizeCurrentBlock` for `*_responses.zig`
- 严重度: P2
- 位置: `openai_responses.zig`, `openai_codex_responses.zig`, `azure_openai_responses.zig`, `zig/src/ai/shared/responses_api.zig`
- 状态: done
- 负责: review-roadmap-documentation-bookkeeping-sync
- 提交: 3306500c

### ISS-309 Step 6: extract generic `runSseLoop`
- 严重度: P2
- 位置: many — see plan and `zig/src/ai/shared/sse_loop.zig`
- 建议: The M6 migration is complete for the review-roadmap scope. Preserve
  provider-local dispatch/data-line differences. Legacy OpenAI Chat now uses
  `sse_loop.run` for the outer line loop and abort checks, but keeps compact
  `data:{...}` tolerance in its `OpenAIChatSseLoopHandler.extractDataLine`
  implementation rather than broadening generic loop behavior.
- 状态: done
- 负责: review-roadmap-documentation-bookkeeping-sync;
  5efa68c7-6d00-41ab-829c-96d19377c89c verified the pre-existing OpenAI Chat
  SSE diff
- 提交: 3306500c, 902720d3; pending mission handoff for OpenAI Chat SSE
  uncommitted diff

### ISS-310 Step 7: `emitTerminal` consolidation
- 严重度: P2
- 位置: `openai_responses.zig`, `openai_codex_responses.zig`,
  `azure_openai_responses.zig`, `kimi.zig`
- 状态: open
- 负责:
- 提交:
