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

## Example plan

See `examples/hello.plan.json`.
