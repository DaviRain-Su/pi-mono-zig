# pi-mono-zig

A Zig re-implementation of the **core runtime** ideas from `pi-mono`.

> Scope (MVP): a small, auditable **plan runner** with tool execution + run artifacts.
> Not a 1:1 rewrite of the entire TypeScript monorepo.

## MVP features

- `plan.json` input (`schema`, `workflow`, `steps[]`)
- deterministic topo execution (dependsOn)
- built-in tools: `echo`, `sleep_ms`
- fail-closed: missing deps / cycles => error
- artifacts:
  - `runs/<runId>/plan.json`
  - `runs/<runId>/run.json`
  - `runs/<runId>/steps/<stepId>.json`

## Build

```bash
zig build
```

## Run

```bash
zig build run -- run --plan examples/hello.plan.json
```

## Verify a run (artifact chain)

```bash
zig build run -- verify --run <runId>
```

## Chat loop (TS-style: messages + tools + session log)

This is a *minimal* AgentLoop clone (uses a deterministic mock model).

JSONL entries are now structured (not just plain messages):
- `type: session`
- `type: message`
- `type: tool_call`
- `type: tool_result`
- `type: leaf` (tracks current leaf for branching)

```bash
# creates/extends a JSONL session
zig build run -- chat --session /tmp/pi-session.jsonl

# replay the JSONL log
zig build run -- replay --session /tmp/pi-session.jsonl
```

Try:
- `echo: hello`
- `sh: ls` (only if you pass `--allow-shell`)

Branching + labels (session tree MVP):
```bash
# list current leaf path (shows entryIds)
zig build run -- list --session /tmp/pi-session.jsonl

# label a node
zig build run -- label --session /tmp/pi-session.jsonl --to <entryId> --label ROOT

# branch leaf to an earlier node
zig build run -- branch --session /tmp/pi-session.jsonl --to <entryId>

# branch leaf to root (before first entry)
zig build run -- branch --session /tmp/pi-session.jsonl --root

# branch and append a branch_summary node (auto summary if --summary omitted)
zig build run -- branch-with-summary --session /tmp/pi-session.jsonl --to <entryId>

# branch to root and append a branch_summary node
zig build run -- branch-with-summary --session /tmp/pi-session.jsonl --root

# replay follows current leaf (root -> leaf path)
zig build run -- replay --session /tmp/pi-session.jsonl

# persist context state entries (TS-style)
zig build run -- set-model --session /tmp/pi-session.jsonl --provider anthropic --model claude-sonnet-4-5
zig build run -- set-thinking --session /tmp/pi-session.jsonl --level high

# show full details for one entry
zig build run -- show --session /tmp/pi-session.jsonl --id <entryId>

# show full session tree ("*" marks current leaf path)
zig build run -- tree --session /tmp/pi-session.jsonl

# compact current leaf path (TS-style summary marker + keep-last boundary)
zig build run -- compact --session /tmp/pi-session.jsonl --keep-last 8

# preview compaction summary without writing
zig build run -- compact --session /tmp/pi-session.jsonl --keep-last 8 --dry-run

# TS-aligned structured summary (markdown)
zig build run -- compact --session /tmp/pi-session.jsonl --keep-last 8 --dry-run --structured md

# Update an existing structured summary (naive merge):
# - ensures Next Steps / In Progress placeholders are actionable
# - appends new snippets into Critical Context
zig build run -- compact --session /tmp/pi-session.jsonl --keep-last 8 --structured md --update

# Keep last N complete turn-groups (TS-like) instead of last N entries
zig build run -- compact --session /tmp/pi-session.jsonl --keep-last-groups 2 --structured md

# Record thresholds in the summary stats (manual compaction)
zig build run -- compact --session /tmp/pi-session.jsonl --keep-last-groups 2 --structured md --max-chars 8000 --max-tokens-est 2000

# structured summary (json)
zig build run -- compact --session /tmp/pi-session.jsonl --keep-last 8 --dry-run --structured json

# auto-compact while chatting (char/tokens boundary since last summary)
# (uses the same TS-style compaction logic as manual compact, with usage+trailing estimate)
zig build run -- chat --session /tmp/pi-session.jsonl --auto-compact --max-chars 8000 --keep-last 8
```

This currently checks:
- `runs/<runId>/plan.json` exists and is valid
- `runs/<runId>/run.json` exists
- `runs/<runId>/steps/<stepId>.json` exists for every step in the plan
- every step artifact has `ok: true` and matching `runId`

## Example plan

See `examples/hello.plan.json`.
