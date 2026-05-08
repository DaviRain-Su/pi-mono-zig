# Zig Codebase Review

This directory tracks an ongoing structural review of `zig/src/`. It is the
single source of truth for "what's wrong, how to fix it, who's working on it".

Other agents can claim work by:

1. `grep -rn '状态: open' zig/docs/review/` to list all unclaimed issues.
2. Pick an issue. Update its `状态:` to `in-progress` and add `负责: <agent-id>`.
3. Implement the fix in a focused commit using the `验证:` hint to confirm.
4. After the commit lands, update `状态:` to `done`/`closed` with the commit hash. Mission workers that are instructed not to commit should still backfill the commit hash once an implementation commit is available.

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
| 01_provider_layer | M1/M9 synced | roadmap-linked provider invariant, ownership, and matrix items closed; remaining open issues are future/full-pass work |
| 02_provider_duplication | M6 complete | M3–M6 shared finalize, Responses common surface, and generic SSE-loop work complete; ISS-310 remains follow-up |
| 03_agent_layer | M7/M8 complete | state-machine doc, hook/allocator guards, reuse/double-finalize guards, and partial-UX policy closed |
| 04_contracts | M1/M2 + backlog follow-up complete | INV-1/2/3/4/5 docs/assertions, stop-reason helper, EventOrderingGuard, consumer exhaustiveness audit, and thought_signature lifecycle docs closed |
| 05_test_matrix | M9 + backlog sweep complete | zero unknown, unclassified missing, or partial cells; priority S13/S14/S12/S6/S15 sweep closed and remaining lower-priority gaps marked Deferred with rationale |
| 06_risk_register | M1–M9 resequenced | top risks annotate completed roadmap items and retained future work |
| 07_refactor_roadmap | M1–M10 planning synced | all M1–M9 roadmap checkboxes closed; M10 is read-only planning only and implementation remains deferred |

## Quality gates per commit

- `cd zig && zig build test` — full unit test suite green
- `cd zig && zig build test-tidy` — no lints
- `npm run check` — top-level checks (if applicable)
- No new `output.tool_calls` allocations (single-allocation rule from
  commit `fde1951f` must not regress).
- No new uses of `active_blocks.items.len` to compute outgoing
  `content_index` (use the provider's incoming `index` field).
