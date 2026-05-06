# Pi Tool WIT v0

Status: stable foundation contract for `WASM-003`

Stable source path: [`zig/wit/pi-tool-v0.wit`](../wit/pi-tool-v0.wit)

## Package and World

The v0 WIT package is `package pi:extension@0.1.0` and the exported world is
`world tool-v0`. Extension authors implement the `tool` interface exported by
that world.

```wit
package pi:extension@0.1.0;

interface tool {
    metadata: func() -> string;
    schema: func() -> string;
    execute: func(input-json: string) -> string;
}

world tool-v0 {
    export tool;
}
```

## Exported Plugin Functions

All v0 payloads are JSON string values. The host validates
`pi-extension.json` before loading the Wasm artifact, then calls these exports:

| Export | JSON string contract | Manifest cross-check |
| --- | --- | --- |
| `metadata()` | Returns a JSON object describing the extension/tool identity, display name, version, and description. | Must agree with `schemaVersion: "pi-extension.v0"`, extension `id`, `name`, `version`, `description`, and `tool.id` / `tool.description`. |
| `schema()` | Returns a JSON object containing the tool input and output schemas. | Must describe the same contract as `tool.inputSchema` and `tool.outputSchema`. |
| `execute(input-json: string)` | Accepts a JSON string that conforms to `tool.inputSchema` and returns a JSON string that conforms to `tool.outputSchema`, or a deterministic JSON error object. | The callable tool identity is `tool.id`; execution is allowed only after `artifact.kind: "wasm-component"` and `artifact.path` validation succeeds. |

The manifest field `capabilities` is also part of the same contract: declared
values are requests, not approvals, and omitted capabilities grant no ambient
authority.

## No v0 Host Functions

No v0 host functions are exposed to Wasm plugins. In v0, the WIT world exports
only the plugin-side `metadata`, `schema`, and `execute` functions and provides
no host callbacks for:

- file access: `file.read`, `file.write`
- shell/process access: `shell`
- network access: `network`
- environment access: `env`
- model/session access: `model`, `session`
- UI notification access: `ui.notify`

This matches the manifest validator's default-deny capability vocabulary.
Requested capabilities remain denied until a later host contract adds explicit
approval semantics and enforcement branches.

## Deferred Non-Tool Surfaces

The v0 surface is tools-only. Commands, widgets, editor hooks, provider
registration, shortcuts, themes, prompts, skills, model/session mutation, UI
hooks, shell access, filesystem access, network access, and environment access
are deferred to later contracts.

Hosts must reject v0 manifest declarations for non-tool surfaces, or ignore
runtime-only non-tool attempts, with deterministic diagnostics. In both cases
the behavior must be rejected or ignored deterministically and must not register
commands, widgets, editor hooks, provider registration, or other deferred
surfaces as a side effect of loading a v0 Wasm tool.
