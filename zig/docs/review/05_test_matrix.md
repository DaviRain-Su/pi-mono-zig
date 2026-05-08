# Test Coverage Matrix

This file tracks per-provider × per-scenario test coverage. Cells are seeded
from the recent oracle survey; many are `?` and need a follow-up agent to
confirm by reading existing tests.

## Legend
- ✅ — covered by an existing test
- ❌ — clearly missing, blocks confidence
- ⚠️ — partial / indirect coverage; should be improved
- ? — unknown; reader needs to confirm
- N/A — feature not supported by this provider (document why)

## Scenarios

| # | Scenario |
|---|---|
| S1 | Text-only stream |
| S2 | Text + thinking/reasoning stream |
| S3 | Tool-call only |
| S4 | Tool-call + thinking |
| S5 | Multiple tool calls in single stream |
| S6 | Stream aborts mid-event |
| S7 | Malformed JSON tool args (recovery to `{}`) |
| S8 | Provider error frame (non-200) |
| S9 | Empty / zero-event success |
| S10 | Compact `data:{...}` SSE line |
| S11 | OAuth / dynamic header path |
| S12 | Stop reason coercion (.stop → .tool_use when tool_calls present) |
| S13 | content_index stability across block start/stop/start |
| S14 | Leak-tracking allocator passes (no leaks) |
| S15 | EOF mid-block tolerance |

## Matrix

| Provider | S1 | S2 | S3 | S4 | S5 | S6 | S7 | S8 | S9 | S10 | S11 | S12 | S13 | S14 | S15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| anthropic | ✅ | ✅ | ✅ | ✅ | ? | ? | ? | ✅ | ✅ | ✅ | ⚠️ | ? | ❌ | ? | ⚠️ |
| openai_responses | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| openai_codex_responses | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| azure_openai_responses | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| openai_chat_sse | ? | ? | ? | ? | ? | ? | ✅ | ? | ? | ❌ | ? | ? | ? | ? | ? |
| bedrock | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | N/A | ? | ? | ? | ? |
| google | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| google_vertex | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| google_gemini_cli | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| mistral | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| kimi | ? | ? | ? | ? | ? | ? | ? | ? | ? | ⚠️ | N/A | ❌ | ? | ? | ? |
| cloudflare | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| faux | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | N/A | ? | ? | ? | ? |

## Action items

### ISS-600 Confirm matrix entries by reading existing tests
- 严重度: P2
- 位置: `zig/src/ai/providers/*` test sections, `provider_smoke_test.zig`,
  `provider_stream_contract_matrix_test.zig`
- 建议: For every `?`, read the corresponding test. Update the cell.
- 验证: docs only.
- 状态: open
- 负责:
- 提交:

### ISS-601 Fill ❌ cells in priority order
- 严重度: P1
- 位置: provider test files
- 建议: Implement missing scenarios. Priority:
  1. S13 content_index stability across providers (recent regression area)
  2. S14 leak-tracking allocator across providers
  3. S12 stop_reason coercion (.stop → .tool_use)
  4. S6 abort mid-stream
  5. S15 EOF mid-block
- 验证: each new test plus existing parity targets.
- 状态: open
- 负责:
- 提交:

### ISS-602 Establish a test-add convention
- 严重度: P2
- 位置: `zig/docs/review/05_test_matrix.md`
- 建议: Document where each scenario test lives (per-provider file vs
  shared matrix). Avoid drift.
- 验证: docs only.
- 状态: open
- 负责:
- 提交:
