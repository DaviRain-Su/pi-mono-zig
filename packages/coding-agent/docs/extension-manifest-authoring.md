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
