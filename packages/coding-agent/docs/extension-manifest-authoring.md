# Extension Manifest Authoring

`pi-extension.json` authoring artifacts document the manifest shape that Zig accepts for TypeScript and process-backed extensions. They are schema-parity references for authors and tests; production TypeScript extension loading still uses the package and extension workflows documented in [Extensions](extensions.md) and [Pi packages](packages.md).

## Supported runtimes

Zig accepts these `pi-extension.v1` runtime kinds:

- `typescript` with a `.ts` or `.js` entrypoint
- `javascript` with a `.js` entrypoint
- `process_jsonl` with an `argv` array entrypoint
- `future` as a non-executable placeholder contract

Zig no longer supports authoring or running Zig, WASM, or native extension runtimes. Do not use `runtime.kind: "wasm"`, `runtime.kind: "native"`, `pi-extension.v0` WASM manifests, native descriptors, dynamic-library paths, provenance principals, or trust-lock policy metadata for new Zig extension work.

## Runtime examples

### TypeScript

```json
{
  "schemaVersion": "pi-extension.v1",
  "id": "com.example.typescript",
  "name": "TypeScript Example",
  "version": "1.0.0",
  "runtime": {
    "kind": "typescript",
    "entrypoint": "src/index.ts"
  },
  "tools": [
    {
      "name": "example.echo",
      "description": "Echo a message.",
      "inputSchema": { "type": "object" }
    }
  ]
}
```

### Process JSONL

```json
{
  "schemaVersion": "pi-extension.v1",
  "id": "com.example.process",
  "name": "Process Example",
  "version": "1.0.0",
  "runtime": {
    "kind": "process_jsonl",
    "entrypoint": {
      "argv": ["node", "host.js"]
    },
    "limits": {
      "timeoutMs": 30000,
      "outputBytes": 1048576,
      "toolScopes": []
    }
  }
}
```

Reference artifacts:

- [v1 authoring schema](schemas/pi-extension.v1.authoring.schema.json)
- [TypeScript authoring types](extension-manifest-authoring.types.ts)

## Declarations

Supported extension declarations include tools, commands, resources, providers, hooks, capabilities, permissions, dependencies, and workflows. Zig normalizes declarations with owner/runtime metadata so the registry and event paths can preserve package identity.

The in-scope UI bridge remains the lower-layer request semantics for `ctx.ui.notify` and `ctx.ui.setStatus`: canonical `extension_ui_request` frames with `method: "notify"` or `method: "setStatus"`, stable fields such as `message`, `notifyType`, `statusKey`, and `statusText`, and exact `responseRequired` handling.

Shortcut authoring follows the interactive dispatch contract: valid shortcuts from enabled extensions dispatch through the normal interactive input path after the registry is ready; reserved built-in bindings remain protected; non-reserved conflicts follow the parity resolver with diagnostics and a single winner; duplicate extension shortcuts resolve deterministically; invalid shortcut strings are ignored or diagnosed safely. Shortcut dispatch preserves the owning extension and command identity rather than dispatching by shortcut string.
