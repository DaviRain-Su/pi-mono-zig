# WASM-004 Native Wasm Host Spike Evidence

## Scope

WASM-004 is isolated to a standalone Zig-side host spike. It does not register with the coding-agent extension registry, does not start a session, does not use provider configuration, and requires no API key or external service. No agent/session runtime integration is part of this spike.

## Extism Project-Local Attempt

Extism was attempted first under the project-local dependency policy. The repository currently has no project-local Extism SDK, C library, or vendored runtime artifact to link from Zig.

Attempted commands and blocker evidence:

```text
$ npm ls @extism/extism extism --depth=0 --prefix /Users/davirian/dev/active/worktrees/wasm-extension-1nl
pi-monorepo@0.0.3 /Users/davirian/dev/active/worktrees/wasm-extension-1nl
└── (empty)

$ test -d /Users/davirian/dev/active/worktrees/wasm-extension-1nl/zig/vendor/extism && printf 'zig/vendor/extism present\n' || printf 'zig/vendor/extism missing\n'
zig/vendor/extism missing

$ PKG_CONFIG_PATH=/Users/davirian/dev/active/worktrees/wasm-extension-1nl/zig/vendor/extism/lib/pkgconfig:/Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/@extism/extism/lib/pkgconfig pkg-config --exists extism; printf 'pkg-config extism exit=%s\n' "$?"
pkg-config extism exit=1
```

Blocker: using Extism from Zig would require adding a project-local Extism package/library or vendoring `libextism` headers and dynamic/static libraries for each supported platform. A global/Homebrew `extism` install is explicitly outside the mission boundary, so the spike uses the native Wasm substitute below.

## Native Wasm Substitute

The substitute is `zig/src/coding_agent/wasm_host_spike.zig` plus the repository-local plugin fixture `zig/test/fixtures/wasm/native-tool-v0/plugin.wasm`.

The fixture is a small core Wasm module with no imports and an exported memory. It exports `metadata`, `metadata_len`, `schema`, `schema_len`, `execute`, and `execute_len`. The standalone Zig host validates the Wasm header, import-free shape, required exports, constant-return function bodies, data segments, and JSON payloads. It calls the three required exports through a deliberately tiny fixture interpreter that resolves exported constant-return functions and reads the returned JSON strings from Wasm memory.

Runtime/dependency constraints:

- Project-local only: the fixture is checked into the repository and tests run with Zig stdlib only.
- No runtime dynamic libraries are required for the native substitute.
- No platform package manager, global `extism`, `wasmtime`, `wasm-tools`, or `wit-bindgen` is required.
- The substitute intentionally supports only this deterministic fixture ABI; it is evidence for Zig host integration cost, not a production runtime.

Integration cost and platform/package notes:

- Extism production use would add platform-specific `libextism` packaging, dynamic-library loading/linking, and CI artifact management.
- Direct production Wasm execution needs a real runtime or Component Model host; the fixture interpreter is not a general Wasm VM.
- The native substitute demonstrates the standalone load/call/JSON-validation flow without introducing agent/session coupling.
