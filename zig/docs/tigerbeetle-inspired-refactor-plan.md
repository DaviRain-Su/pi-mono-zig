# TigerBeetle-Inspired Zig Refactor Plan

This plan adapts TigerBeetle's engineering methods to this Zig implementation. The goal is not to
copy every rule, but to make the refactor measurable, testable, and harder to regress.

## Principles

- Keep parent functions responsible for control flow.
- Move non-branchy logic into focused leaf functions.
- Keep leaf functions pure when state mutation is not required.
- Prefer explicit invariants over implicit assumptions.
- Add guardrails before large refactors, then ratchet them tighter.
- Treat provider contracts, session replay, keybindings, and wire formats as safety boundaries.

## Task List

### 1. Tidy Guardrail

- Add a Zig tidy step that scans Zig source files.
- Report long functions with file and line locations.
- Start as warning-only to avoid blocking unrelated work.
- Ratchet the threshold down over time.
- Later make selected checks fail in CI.

Acceptance criteria:

- `zig build test-tidy` runs locally.
- The report is deterministic.
- The check does not modify source files.

### 2. Test Root Coverage

- Extend tidy to find Zig files that contain `test` blocks but are unreachable from known test roots.
- Keep explicit test roots for focused areas such as interactive rendering.
- Add a workflow note: every new split module with tests must be imported by a test root.

Acceptance criteria:

- New module tests cannot silently disappear.
- Rendering-only modules stay covered by `test-tui`.

### 3. Provider Contract Matrix

- Add a provider stream-contract matrix.
- Assert non-OOM setup/runtime failures become terminal `error_event`.
- Keep API/provider/model metadata checks in the common helper.
- Cover OpenAI, Anthropic, Bedrock, Azure, Codex Responses, Vertex, Google, Mistral, Kimi, and Faux.

Acceptance criteria:

- Every production provider has at least one setup-failure stream test.
- New providers require an explicit matrix entry.

### 4. Wire and Parser Fuzz Smoke

- Add small deterministic fuzz smoke tests for:
  - SSE parser chunks.
  - JSON event wire.
  - session JSONL replay.
  - keybinding parse/match.
  - extension UI protocol.

Acceptance criteria:

- Each fuzzer has a fixed seed smoke mode for CI.
- Failure output includes seed and minimized input where feasible.

### 5. Interactive Mode Decomposition

- Continue splitting `interactive_mode.zig` by domain:
  - login/auth flow.
  - session lifecycle.
  - command routing.
  - event loop orchestration.
  - extension bridge coordination.
- Keep orchestration functions near the top and push helper logic down or out.

Acceptance criteria:

- New modules have focused tests.
- Event-loop behavior remains covered by existing integration scripts.

### 6. Input Dispatch Decomposition

- Split key-to-action resolution from action execution.
- Keep configurable keybindings as the only source of key matching.
- Add compile-time or tidy checks for `Action` coverage where practical.

Acceptance criteria:

- No hardcoded key checks are introduced.
- Adding an `Action` forces review of dispatch coverage.

### 7. Provider Internal Shape

- Move shared HTTP, payload, SSE, and error-conversion helpers into provider support modules.
- Keep provider-specific files focused on API-specific request/response mapping.
- Use the common stream-contract wrapper everywhere.

Acceptance criteria:

- Provider setup paths are contract-uniform.
- Shared helpers have direct unit tests.

### 8. Session and RPC Decomposition

- Split session parse, replay, persistence, compaction, and display formatting.
- Split `ts_rpc_mode.zig` by wire encoding, session lifecycle, extension UI bridge, and command handling.

Acceptance criteria:

- Session replay tests cover old and current JSONL shapes.
- RPC wire tests stay byte- or semantic-parity checked against TypeScript fixtures.

## Ratchet Policy

The tidy step starts with warnings. A check becomes blocking only after:

- The current codebase is below the threshold.
- CI has run the warning-only version for at least one cycle.
- The threshold is documented in this file.

Initial thresholds:

- Function length warning: greater than 160 lines.
- Future target: 120 lines, then 90 lines for new code.

