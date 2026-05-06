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

Status: Completed/currently covered.

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

Status: Completed/currently covered.

- Extend tidy to find Zig files that contain `test` blocks but are unreachable from known test roots.
- Keep explicit test roots for focused areas such as interactive rendering.
- Add a workflow note: every new split module with tests must be imported by a test root.

Acceptance criteria:

- New module tests cannot silently disappear.
- Rendering-only modules stay covered by `test-tui`.

### 3. Provider Contract Matrix

Status: Completed/currently covered.

- Add a provider stream-contract matrix.
- Assert non-OOM setup/runtime failures become terminal `error_event`.
- Keep API/provider/model metadata checks in the common helper.
- Cover OpenAI, Anthropic, Bedrock, Azure, Codex Responses, Vertex, Google, Mistral, Kimi, and Faux.

Acceptance criteria:

- Every production provider has at least one setup-failure stream test.
- New providers require an explicit matrix entry.

### 4. Wire and Parser Fuzz Smoke

Status: Completed/currently covered. The guardrails are fixed-seed, bounded, and
non-mutating. They currently cover SSE parser chunks, JSON event wire, session
JSONL replay, keybinding parse/match, and extension UI protocol boundaries.

- Add small deterministic fuzz smoke tests for:
  - SSE parser chunks.
  - JSON event wire.
  - session JSONL replay.
  - keybinding parse/match.
  - extension UI protocol.

Acceptance criteria:

- Each fuzzer has a fixed seed smoke mode for CI.
- Failure output includes seed and minimized input where feasible.

## Next Suggested Refactor Step

Start Task 5/6 decomposition only after the completed guardrails above remain in
place. Provider internals and session/RPC decomposition remain later refactor
steps.

### 5. Interactive Mode Decomposition

Status: Started/current slice complete. Login/auth flow, session lifecycle, and
slash command routing now live in focused interactive-mode helper modules:
`auth_flow.zig`, `session_lifecycle.zig`, and `command_router.zig`. The parent
interactive loop remains responsible for orchestration, while the extracted
helpers preserve the existing login/logout, session, and command matrix
behavior. Extension bridge coordination remains intentionally deferred because
extension ABI/protocol work is active separately.

- Continue splitting `interactive_mode.zig` by domain:
  - login/auth flow. Completed for the current behavior-preserving slice.
  - session lifecycle. Completed for the current behavior-preserving slice.
  - command routing. Completed for the current behavior-preserving slice.
  - event loop orchestration.
  - extension bridge coordination.
- Keep orchestration functions near the top and push helper logic down or out.

Acceptance criteria:

- New modules have focused tests or are covered by existing focused
  login/logout/session/command fixtures through `zig build test-coding-agent`.
- Event-loop behavior remains covered by existing integration scripts, including
  `test-tui`, `test-vaxis-m8-e2e`, and missing-cwd selector validation.

### 6. Input Dispatch Decomposition

Status: Completed/currently covered for the Task 6 slice. Key-to-action
resolution now lives behind the focused `input_resolution.zig` resolver, while
`input_dispatch.zig` remains the executor/dispatcher for resolved app/editor
actions and input-event message actions. Configured keybindings remain the only
source of non-legacy matching, and legacy defaults are suppressed when an
effective keybinding map rebinds those actions.

- Split key-to-action resolution from action execution. Completed for main
  editor, autocomplete, parsed input-event follow-up/dequeue, and app/editor
  dispatch paths.
- Keep configurable keybindings as the only source of key matching. Covered by
  resolver tests plus existing input-dispatch configured/rebound behavior tests.
- Add compile-time or tidy checks for `Action` coverage where practical. The
  main app-action executor now uses an exhaustive `Action` switch with explicit
  no-op coverage for overlay-scoped actions, so adding an action requires
  dispatch review at compile time.
- Leave overlay-internal selector key execution behavior-preserving in this
  slice; broader extension bridge coordination and extension ABI/protocol
  refactors remain deferred to their own follow-up work.

Acceptance criteria:

- No hardcoded key checks are introduced.
- Adding an `Action` forces review of dispatch coverage.
- Focused validation: `zig build test-coding-agent` covers resolver behavior,
  configured bindings, rebound old defaults, and dispatch-event message actions.

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

