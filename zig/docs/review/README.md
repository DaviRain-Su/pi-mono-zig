# Zig Codebase Review

This directory tracks an ongoing structural review of `zig/src/`. It is the
single source of truth for "what's wrong, how to fix it, who's working on it".

Other agents can claim work by:

1. `grep -rn '状态: open' zig/docs/review/` to list all unclaimed issues.
2. Pick an issue. Update its `状态:` to `in-progress` and add `负责: <agent-id>`.
3. Implement the fix in a focused commit using the `验证:` hint to confirm.
4. After the commit lands, update `状态:` to `done` with the commit hash.

## Severity levels

- **P0** — correctness bug, undefined behavior, memory leak, security risk, or
  observable user-visible regression. Fix before anything else.
- **P1** — semantic bug masked by missing tests; ownership/lifetime
  inconsistency; fragile parser path; cross-provider contract drift.
- **P2** — duplication that begs extraction; naming/structure improvements;
  documentation gaps; test coverage holes.

## Issue schema

Every finding must use this exact schema so it is greppable:

```
### ISS-NNN <one-line title>
- 严重度: [P0|P1|P2]
- 位置: <relative/path.zig:line-line>
- 现状: <quote of current behavior, optional code snippet>
- 问题: <why this is wrong / what can break>
- 建议: <fix sketch — file/function level, not full code>
- 验证: <`zig build test-xxx` target, or "add new test under tests/..."> 
- 状态: open
- 负责:
- 提交:
```

`ISS-NNN` is a globally-unique number across the whole review. Allocate the
next free number when adding a new finding (don't reuse).

## Files

- [`00_module_map.md`](./00_module_map.md) — directory layout, LOC, hotspots.
- [`01_provider_layer.md`](./01_provider_layer.md) — `ai/providers/*` issues.
- [`02_provider_duplication.md`](./02_provider_duplication.md) — extraction
  candidates and proposed shared module surface.
- [`03_agent_layer.md`](./03_agent_layer.md) — `agent/*` issues
  (state machine, tool execution, partial messages).
- [`04_contracts.md`](./04_contracts.md) — `ai/types.zig`, `ai/event_stream.zig`
  cross-cutting contract issues.
- [`05_test_matrix.md`](./05_test_matrix.md) — provider × scenario coverage,
  gaps to fill.
- [`06_risk_register.md`](./06_risk_register.md) — top-N highest-risk areas
  ordered for sequencing.
- [`07_refactor_roadmap.md`](./07_refactor_roadmap.md) — milestones with goal,
  files, expected delta, validation gates.

## Status (high-level)

| Doc | Phase | Coverage |
|---|---|---|
| 00_module_map | scanned | full repo LOC, no TODO/FIXME found anywhere |
| 01_provider_layer | seeded | issues seeded from recent normalize commit thread; needs full pass |
| 02_provider_duplication | M4 verified | shared output finalization migration complete; M5+ still open |
| 03_agent_layer | seeded | partial accumulator + tool exec known issues; needs full pass |
| 04_contracts | seeded | types.zig + event_stream.zig need explicit invariants doc |
| 05_test_matrix | empty | gather from existing tests |
| 06_risk_register | seeded | top-10 picked from above; resequence as items close |
| 07_refactor_roadmap | M4 verified | M4 checked off; continue with M5 Responses API common surface |

## Quality gates per commit

- `cd zig && zig build test` — full unit test suite green
- `cd zig && zig build test-tidy` — no lints
- `npm run check` — top-level checks (if applicable)
- No new `output.tool_calls` allocations (single-allocation rule from
  commit `fde1951f` must not regress).
- No new uses of `active_blocks.items.len` to compute outgoing
  `content_index` (use the provider's incoming `index` field).
