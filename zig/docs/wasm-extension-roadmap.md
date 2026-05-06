# WASM Extension Roadmap

This document tracks the forward-looking extension architecture work for Pi's
Zig implementation. `REVIEW.md` remains the current parity/status document;
this file is for future extension-system tasks that should be easy to import
into a task tracker.

## Goal

Move from a Bun-centered TypeScript extension runtime toward a language-neutral
extension system:

- Extensions declare their tools, commands, permissions, and metadata.
- Implementations compile to a portable artifact, primarily WebAssembly.
- The Zig CLI, Bun compatibility layer, and future Web UI can load the same
  extension artifact where host capabilities allow it.
- Bun remains the compatibility path for existing TypeScript extensions.

Tree-sitter is the reference pattern, not the implementation dependency:

- A small declarative source describes an extension surface.
- A build step produces a loadable native or Wasm artifact.
- The host dynamically loads the artifact without changing core code.

References:

- Tree-sitter build supports shared libraries and Wasm modules:
  https://tree-sitter.github.io/tree-sitter/cli/build.html
- WebAssembly Component Model and WIT:
  https://github.com/WebAssembly/component-model/blob/main/design/mvp/WIT.md
- Extism Host SDK and plugin model:
  https://extism.org/docs/concepts/host-sdk/
- Wassette as an AI-tools reference:
  https://github.com/microsoft/wassette
- Architecture RFC for `WASM-001`:
  [wasm-extension-architecture-rfc.md](wasm-extension-architecture-rfc.md)
- Final authoritative status for `WASM-001` through `WASM-009`:
  [wasm-extension-final-closure.md](wasm-extension-final-closure.md)

## Non-Goals

- Do not remove Bun support in the first version.
- Do not make native `.so` / `.dylib` / `.dll` the default third-party format.
- Do not expose unrestricted file, network, shell, or environment access to
  plugins.
- Do not require extension authors to use Zig.

## Architecture Direction

### Default Extension Artifact

The default third-party artifact should be a Wasm module or Wasm Component.
Any language is acceptable if it can compile to the required ABI or WIT world:

- Zig
- Rust
- Go / TinyGo
- C / C++
- AssemblyScript
- other languages with viable Wasm Component tooling

The host supports the interface, not the source language.

### Compatibility Layer

Existing Bun-hosted TypeScript extensions continue to work through the current
extension host. WASM support should be added beside it:

```text
Pi Zig core
  |-- Bun extension host       # compatibility path for TS/npm extensions
  |-- Wasm extension host      # language-neutral native extension path
  `-- future Web UI host       # browser-capability subset
```

### Native Shared Libraries

Native shared libraries may be useful for trusted first-party extensions or
performance-critical local integrations. They are not the default package
format because ABI stability, sandboxing, signing, and cross-platform
distribution are harder than with Wasm.

## Proposed Package Shape

```text
my-extension/
  pi-extension.json
  wit/
    pi-tool.wit
  wasm/
    plugin.wasm
  examples/
    input.json
    output.json
  README.md
```

`pi-extension.json` should contain:

- extension id, name, version, and description
- artifact path and artifact kind
- declared tools / commands / widgets
- requested host capabilities
- optional runtime constraints

## Initial Tool Interface

The first version should target tools only. Commands, widgets, editor hooks,
and provider registration can come later.

Sketch:

```wit
package pi:extension;

interface tool {
    metadata: func() -> string;
    schema: func() -> string;
    execute: func(input-json: string) -> string;
}

world tool-world {
    export tool;
}
```

The JSON strings keep the first spike simple and compatible with Extism. A
later Component Model version can move to richer WIT records and variants.

## Permission Model

Plugins start with no ambient authority. Host capabilities must be explicit:

- file read
- file write
- network
- shell
- environment variables
- model / LLM calls
- session state
- UI notifications

Each capability needs:

- manifest declaration
- user/project approval path
- host-side enforcement
- test coverage for denial and malformed requests

## Task Backlog

### WASM-001: Write Extension Architecture RFC

Status: complete

Scope:

- Document Bun compatibility plus Wasm native extension host.
- Define lifecycle states: discover, validate, load, initialize, call, unload.
- Define where manifests live and how package installation resolves artifacts.

Evidence:

- [`wasm-extension-architecture-rfc.md`](wasm-extension-architecture-rfc.md)
  records the architecture decisions for lifecycle stages, Bun compatibility,
  v1 artifact direction, package manifest location, artifact resolution,
  tools-only v0, and default-deny capabilities.

Acceptance criteria:

- RFC names the v1 artifact format.
- RFC explains how existing Bun extensions continue to work.
- RFC lists host capabilities and the default deny policy.

### WASM-002: Define Tool Manifest v0

Status: complete

Scope:

- Add a JSON manifest schema for one Wasm-backed tool.
- Include id, version, description, input schema, output schema, artifact path,
  and requested capabilities.

Acceptance criteria:

- A fixture manifest validates successfully.
- Invalid missing fields produce deterministic diagnostics.
- Manifest parsing has unit tests.

Evidence:

- [`../src/coding_agent/wasm_manifest.zig`](../src/coding_agent/wasm_manifest.zig)
  validates `pi-extension.json` v0 for exactly one Wasm-backed tool, including
  required fields, wrong types, malformed JSON, unsupported versions,
  zero/multiple/non-tool declarations, default-deny capabilities, unknown
  capabilities, artifact kind/path checks, and symlink escapes.
- [`../../packages/coding-agent/src/core/wasm-extension-package.ts`](../../packages/coding-agent/src/core/wasm-extension-package.ts)
  provides the TypeScript package-side Wasm manifest classification and handoff.
- Focused evidence includes `wasm manifest`, `pi-extension`, and
  `extensions-discovery.test.ts` validation, plus repository check success after
  the web-ui source-resolution blocker was fixed.

### WASM-003: Define Tool WIT v0

Status: complete

Scope:

- Add a minimal WIT package for tool metadata, schema, and execute.
- Keep JSON string payloads for v0.

Acceptance criteria:

- WIT lives in a stable path under `zig/` or a future shared package.
- The document explains which functions are exported by the plugin.
- The document explains which host functions are intentionally absent in v0.

Evidence:

- [`../wit/pi-tool-v0.wit`](../wit/pi-tool-v0.wit) defines the stable
  `pi:extension@0.1.0` / `tool-v0` WIT contract.
- [`wasm-tool-wit-v0.md`](wasm-tool-wit-v0.md) explains the JSON string
  `metadata`, `schema`, and `execute` exports, absent host functions, deferred
  non-tool surfaces, and manifest cross-checks.

### WASM-004: Extism Host Spike

Status: closed by spike evidence

Scope:

- Load a simple Wasm plugin from Zig.
- Call `metadata`, `schema`, and `execute`.
- Pass JSON input and return JSON output.

Acceptance criteria:

- Runs as a standalone Zig build step or test harness.
- No agent/session integration yet.
- Records integration cost and runtime dependency requirements.

Evidence:

- [`wasm-host-spike-evidence.md`](wasm-host-spike-evidence.md) records the
  Extism project-local attempts, blocker output, runtime dependency constraints,
  and native Wasm substitute rationale.
- [`../src/coding_agent/wasm_host_spike.zig`](../src/coding_agent/wasm_host_spike.zig)
  and [`../test/fixtures/wasm/native-tool-v0/plugin.wasm`](../test/fixtures/wasm/native-tool-v0/plugin.wasm)
  provide the standalone host spike and repository-local plugin fixture.
- Focused evidence includes `extism` and `wasm host` Zig filters and repository
  check success.

### WASM-005: Component Model Host Spike

Status: closed by decision

Scope:

- Build an equivalent tool using WIT and Component Model tooling.
- Compare the same example against the Extism spike.

Acceptance criteria:

- Decision document compares type safety, tooling maturity, browser support,
  Zig host complexity, and package size.
- Output recommends either Extism for v1, direct Component Model for v1, or a
  staged path.

Evidence:

- [`wasm-component-model-decision.md`](wasm-component-model-decision.md)
  documents project-local Component Model tooling attempts, output
  comparability, required comparison axes, footprint evidence, and the staged
  v1 recommendation.
- The staged recommendation keeps the authoring direction pointed at WIT plus
  `artifact.kind: "wasm-component"` while using core-Wasm fixture evidence for
  near-term host and browser validation.

### WASM-006: Browser Host Spike

Status: complete

Scope:

- Load the same Wasm tool in a browser-side harness.
- Execute only capability-free tools.

Acceptance criteria:

- The same artifact runs in Zig host and browser host, or the incompatibility
  is documented.
- Browser host denies unavailable capabilities such as shell and local FS.

Evidence:

- [`../test/fixtures/wasm/browser-host-v0/index.html`](../test/fixtures/wasm/browser-host-v0/index.html),
  [`../test/fixtures/wasm/browser-host-v0/browser-wasm-host.js`](../test/fixtures/wasm/browser-host-v0/browser-wasm-host.js),
  and [`../test/fixtures/wasm/browser-host-v0/harness-smoke.mjs`](../test/fixtures/wasm/browser-host-v0/harness-smoke.mjs)
  implement and smoke-test the browser host harness.
- Agent-browser evidence validated client-side `WebAssembly.instantiate`
  execution, valid fixture output, shell/filesystem denial in manifest-request
  and runtime/import modes, zero execution API requests, and cleanup across
  ports `3120-3129`.

### WASM-007: Migrate One Pure Tool

Status: complete

Scope:

- Choose one pure tool that does not require file, shell, or network access.
- Implement it as a Wasm extension.

Acceptance criteria:

- Tool behavior matches the existing implementation.
- Fixture tests cover success and malformed input.
- The package demonstrates the intended authoring workflow.

Evidence:

- The selected existing implementation is
  [`../src/coding_agent/tools/truncate.zig`](../src/coding_agent/tools/truncate.zig)
  `truncateHead`.
- The migrated package fixture is
  [`../test/fixtures/wasm/pure-truncate-head-v0/pi-extension.json`](../test/fixtures/wasm/pure-truncate-head-v0/pi-extension.json)
  plus [`../test/fixtures/wasm/pure-truncate-head-v0/wasm/plugin.wasm`](../test/fixtures/wasm/pure-truncate-head-v0/wasm/plugin.wasm).
- Focused evidence includes the `wasm pure tool` Zig filter, browser harness
  parity, artifact hash evidence, and repository check success.

### WASM-008: Package Manager Integration Plan

Status: complete

Scope:

- Decide how `pi install` recognizes and installs Wasm extension packages.
- Define local path support first; registry support later.

Acceptance criteria:

- Local path install discovers `pi-extension.json`.
- Artifact validation happens before install is considered successful.
- Existing Bun package install behavior is unchanged.

Evidence:

- [`../../packages/coding-agent/src/core/wasm-extension-package.ts`](../../packages/coding-agent/src/core/wasm-extension-package.ts)
  classifies local `pi-extension.json` packages, validates artifacts before
  install success, and exposes normalized artifact/tool handoff data.
- [`../../packages/coding-agent/test/package-manager.test.ts`](../../packages/coding-agent/test/package-manager.test.ts)
  covers local Wasm package discovery, invalid artifact rejection before
  persistence/success, valid repository fixtures, and unchanged Bun package
  behavior.
- [`../../packages/coding-agent/test/extensions-discovery.test.ts`](../../packages/coding-agent/test/extensions-discovery.test.ts)
  covers Bun discovery isolation for Wasm package directories.

### WASM-009: Native Shared Library Research

Status: closed by research decision

Scope:

- Document whether trusted native extensions are worth supporting.
- Compare dynamic loading, ABI stability, signing, crash isolation, and
  platform packaging against Wasm.

Acceptance criteria:

- Result is a recommendation, not implementation.
- Third-party default remains Wasm unless the research proves otherwise.

Evidence:

- [`wasm-native-library-research.md`](wasm-native-library-research.md)
  compares native shared libraries against Wasm across dynamic loading, ABI
  stability, signing, crash isolation, platform packaging, trust boundaries, and
  failure modes.
- The research keeps Wasm/Wasm Component as the default third-party extension
  format and scopes native shared libraries separately for trusted first-party
  or performance-critical code.

## Final Closure

All roadmap items are complete or closed with evidence. The final synthesis,
cross-milestone decisions, validation evidence summary, Bun compatibility
confirmation, default-deny capability confirmation, project-local dependency
audit, lifecycle diagnostic consistency notes, and README/public-docs gate are
recorded in
[`wasm-extension-final-closure.md`](wasm-extension-final-closure.md).

## Suggested Execution Order

1. WASM-001
2. WASM-002
3. WASM-003
4. WASM-004
5. WASM-005
6. WASM-006
7. WASM-007
8. WASM-008
9. WASM-009

