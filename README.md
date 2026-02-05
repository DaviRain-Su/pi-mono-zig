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

Branching (session tree MVP):
```bash
# pick an entryId from the JSONL (e.g. a message/tool_result id)
zig build run -- branch --session /tmp/pi-session.jsonl --to <entryId>

# replay follows current leaf (root -> leaf path)
zig build run -- replay --session /tmp/pi-session.jsonl
```

This currently checks:
- `runs/<runId>/plan.json` exists and is valid
- `runs/<runId>/run.json` exists
- `runs/<runId>/steps/<stepId>.json` exists for every step in the plan
- every step artifact has `ok: true` and matching `runId`

## Example plan

See `examples/hello.plan.json`.
