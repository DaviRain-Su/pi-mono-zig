# Extension Manifest Authoring

`pi-extension.json` authoring artifacts are schema-parity references for Zig SDK
and package validators. They are not used to implement TypeScript runtime
execution behavior.

## WASM SDK manifest

The standalone Zig WASM template uses:

- `schemaVersion: "pi-extension.v0"`
- `artifact.kind: "wasm-component"`
- one `tool` with object `inputSchema` and `outputSchema`
- `capabilities` from the canonical grant vocabulary
- bounded `resourceLimits`

The canonical grant vocabulary is exactly:

`file.read`, `file.write`, `network.request`, `shell.run`, `env.read`,
`model.call`, `session.read`, `session.write`, `ui.notify`, `tool.use`,
`agent.spawn`, and `agent.delegate`.

Legacy shorthand such as `network`, `shell`, `env`, `model`, or `session` is
historical only and is not valid normative manifest or policy vocabulary.

Reference artifacts:

- [WASM example](examples/pi-extension-wasm-v0.json)
- [WASM JSON schema](schemas/pi-extension.v0.schema.json)

## Native authoring manifest

Native authoring docs/types describe the `pi-extension.v1` manifest shape that
Zig validators currently accept for native runtime metadata:

- `runtime.kind: "native"`
- `runtime.entrypoint.descriptor` for the approved native descriptor boundary
- `runtime.limits.timeoutMs`, `runtime.limits.outputBytes`, and
  `runtime.limits.toolScopes`
- `tools[].name`, optional `description`, and object `inputSchema`/`parameters`
- normalized owner/runtime metadata on declarations

Native manifests must not use direct dynamic-library path fields such as
`library_path`, `dynamic_library_path`, or `remote_url` in this authoring shape.
Direct native dynamic-library path authoring is outside the Phase 1 product
surface; native package metadata stays behind the approved descriptor/artifact
boundary.

Reference artifacts:

- [Native example](examples/pi-extension-native-v1.json)
- [Native/WASM v1 authoring schema](schemas/pi-extension.v1.authoring.schema.json)
- [TypeScript authoring types](extension-manifest-authoring.types.ts)

## Policy principal metadata

Digest-bound package policy principals include scope, source identity, package
identity, runtime kind, package-root digest, selected artifact digest, and native
artifact selector metadata when applicable. Name-only, path-only, and
cross-scope principals are documentation-only examples here and do not authorize
packages.

## Phase 1 scope boundaries

These authoring artifacts describe lower-layer extension substrate parity. They
do not enable Web Simulator, Workflow/Wiki/QA/Review product presets,
marketplace flows, publisher/signing flows, remote package/runtime URLs, or
direct native dynamic-library path authoring.

The in-scope UI bridge is limited to the lower-layer request semantics for
`ctx.ui.notify` and `ctx.ui.setStatus`: canonical `extension_ui_request` frames
with `method: "notify"` or `method: "setStatus"`, stable fields such as
`message`, `notifyType`, `statusKey`, and `statusText`, and exact
`responseRequired` handling. Full product UI surfaces such as selectors,
editors, overlays, widgets, Web Simulator, and marketplace/signing UX are
deferred to separate product work.

Shortcut authoring follows the Phase 1 interactive dispatch contract: valid
shortcuts from enabled extensions dispatch through the normal interactive input
path after the registry is ready; reserved built-in bindings remain protected;
non-reserved conflicts follow the parity resolver with diagnostics and a single
winner; duplicate extension shortcuts resolve deterministically; invalid
shortcut strings are ignored or diagnosed safely. Shortcut dispatch preserves
the owning extension and command identity rather than dispatching by shortcut
string.
