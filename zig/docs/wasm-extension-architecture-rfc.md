# Pi Wasm Extension Architecture RFC

Status: accepted foundation decision for `WASM-001`

Roadmap context: [`wasm-extension-roadmap.md`](wasm-extension-roadmap.md)

## Purpose

This RFC records the architecture decisions for Pi's Wasm extension path. It is
not a replacement for the roadmap; the roadmap remains the task and status
tracker for `WASM-001` through `WASM-009`.

The Wasm path is additive. Existing Bun-hosted TypeScript extensions,
`package.json` `pi.extensions`, conventional extension directories, and
explicit `--extension` loading continue to work unchanged through the current
Bun compatibility host.

## Decisions

1. Pi keeps two extension paths during the transition:
   - the existing Bun-hosted TypeScript extension host for current packages and
     rich extension surfaces
   - a new Wasm tool host for language-neutral, sandboxable tools
2. Wasm v0 is tools-only. Commands, widgets, editor hooks, provider
   registration, model/session access, UI hooks, shell, filesystem, network,
   and environment access are absent unless a later contract adds and tests
   them.
3. The intended v1 default third-party artifact format is a WebAssembly Component
   using WIT (`artifact.kind: "wasm-component"`). v0 host spikes may
   use core Wasm or Extism-shaped plugin artifacts as decision evidence, but
   those spike formats do not make native shared libraries the third-party
   default.
4. Native shared libraries remain research-only for `WASM-009` and, if ever
   accepted, must be scoped separately for trusted first-party or
   performance-critical cases.
5. Capabilities are default-deny and host-enforced. Manifest declarations are
   requests, not approvals.

## Compatibility Boundary

The Bun compatibility path is preserved as the source of truth for existing
TypeScript extensions. Wasm discovery must not reinterpret existing
`package.json` `pi` manifests, conventional TypeScript extension directories,
or `--extension` inputs as Wasm packages.

Observable compatibility outcomes:

- a package without `pi-extension.json` continues through the existing package
  and Bun extension discovery rules
- a TypeScript extension can still register tools, commands, providers, hooks,
  widgets, shortcuts, and flags through the Bun host
- Wasm package discovery runs beside, not before or instead of, the Bun path
- validation failures in a Wasm manifest do not disable unrelated Bun
  extensions from the same settings scope

## Package Manifest and Artifact Resolution

`pi-extension.json` lives at the root of a Wasm extension package. The package
root is the directory containing that manifest, whether the package is installed
from a local path, git source, npm source, or a project-local fixture.

The v0 manifest describes exactly one Wasm-backed tool and its artifact. The
manifest owns Wasm-specific metadata; TypeScript extension packages continue to
use the existing `package.json` `pi` shape.

Artifact resolution rules:

1. `artifact.path` is resolved relative to the `pi-extension.json` package root.
2. Absolute paths are rejected.
3. Empty paths, parent-directory escapes, platform-specific separator escapes,
   and paths outside the package root are rejected before load or install
   success.
4. Hosts canonicalize the package root and artifact path before accepting the
   artifact. If symlink resolution leaves the package root, validation fails.
5. Artifact kind is explicit. The intended v1 stable kind is
   `wasm-component`; v0 spike fixtures may document a core-Wasm or Extism
   adapter kind only as runtime decision evidence.
6. Installers, native hosts, and browser hosts must pass the same normalized
   artifact path and tool id through their handoff.

Illustrative v0 shape:

```json
{
  "manifestVersion": "0",
  "id": "example-tool",
  "name": "Example Tool",
  "version": "0.1.0",
  "description": "A single Wasm-backed Pi tool.",
  "artifact": {
    "kind": "wasm-component",
    "path": "wasm/example-tool.wasm"
  },
  "tool": {
    "id": "example.tool",
    "description": "Runs an example JSON-to-JSON operation.",
    "inputSchema": {},
    "outputSchema": {}
  },
  "capabilities": []
}
```

The later manifest schema feature owns the exact schema and diagnostics. This
RFC fixes the architecture-level constraints that schema must enforce.

## Lifecycle Contract

Every Wasm host implementation uses the same lifecycle terms. Each stage has a
user-visible success or failure outcome.

| Stage | Responsibilities | Externally observable outcome |
| --- | --- | --- |
| `discover` | Locate `pi-extension.json` at a package root while leaving Bun discovery unchanged. Classify the package as a Wasm package candidate. | The package is listed as a Wasm candidate with its manifest path, or ignored by Wasm discovery without affecting Bun extension loading. |
| `validate` | Parse the manifest, validate the version, one-tool shape, schema fields, artifact kind, canonical capability ids, and package-relative artifact path. Resolve symlinks before accepting the artifact. | A valid manifest produces a normalized tool id and artifact path. Invalid input produces deterministic diagnostics with a lifecycle phase and field path or parse location. |
| `load` | Prepare or instantiate the validated artifact through the selected runtime adapter. No plugin code is loaded before validation succeeds. | Success creates an isolated runtime/plugin handle. Failure reports a load-phase diagnostic and does not register a callable tool. |
| `initialize` | Read plugin metadata and schema exports, bind the approved capability set, and verify the v0 tool contract. v0 exposes no host functions. | Success records tool metadata/schema and an approved capability set. Failure reports an initialization diagnostic and unloads any partial runtime state. |
| `call` | Invoke the tool `execute` export with a JSON string input and return a JSON string result or structured error diagnostic. | Callers receive deterministic JSON output or a call-phase diagnostic. Capability attempts outside the approved set are denied by the host. |
| `unload` | Release runtime/plugin resources and remove any Wasm tool registration. Stop temporary processes or browser harness state owned by the host. | After unload, the tool is no longer callable and no stale runtime handle, temporary listener, or registration remains. |

## Tool Surface v0

Wasm v0 exposes one tool with three plugin exports:

- `metadata() -> string`
- `schema() -> string`
- `execute(input_json: string) -> string`

The strings are JSON payloads for v0. This keeps the first host spikes simple
and permits Extism/core-Wasm evidence while the Component Model path is
validated. The v1 direction remains WIT plus Wasm Component semantics.

Non-tool surfaces are deferred. v0 manifests that declare commands, widgets,
editor hooks, provider registration, model/session mutation, shell, filesystem,
network, environment, or UI access as plugin surfaces must fail validation or
be ignored with deterministic diagnostics, according to the manifest schema
feature.

## Capability Policy and Approval Semantics

Wasm extensions start with no ambient authority. The canonical v0 capability ids
are:

- `file.read`
- `file.write`
- `network`
- `shell`
- `env`
- `model`
- `session`
- `ui.notify`

Capability semantics:

1. Omitted capabilities grant nothing.
2. Declared capabilities are requests only.
3. Requested capabilities remain denied until an explicit user or project
   approval record grants that exact capability to the extension/tool identity.
4. Unknown capability strings are validation errors.
5. Host enforcement is mandatory. A manifest, WIT declaration, or plugin import
   cannot grant authority by itself.
6. Browser hosts may reject capabilities that cannot be safely implemented in
   the browser, even when requested.
7. Denials are deterministic diagnostics that include the capability id and
   lifecycle phase.

For v0, no host functions are exposed to Wasm plugins, so the only accepted
capability set for executable tools is empty unless a later host feature adds a
specific enforcement branch and tests for approvals and denials.

Canonical capability ids map one-to-one to host enforcement branches. Native
and browser hosts must use the same `denied_capability` category for
requested-but-unapproved declarations and runtime/import attempts:

| Capability id | Enforcement branch | Browser runtime/import fixture |
| --- | --- | --- |
| `file.read` | `filesystem.read` | `pi:filesystem/read` |
| `file.write` | `filesystem.write` | `pi:filesystem/write` |
| `network` | `network.request` | `pi:network/fetch` |
| `shell` | `shell.process` | `pi:shell/run` |
| `env` | `environment.variable` | `pi:environment/get` |
| `model` | `model.call` | `pi:model/call` |
| `session` | `session.state` | `pi:session/get` |
| `ui.notify` | `ui.notification` | `pi:ui/notify` |

## Validation and Dependency Policy

All Wasm architecture, spike, and validation work must use project-local
dependencies, vendored fixtures, or temporary directories. The design must not
require Homebrew/global installs, real provider credentials, paid APIs, or
persistent services.

Docs-only changes to this RFC do not require code validators. When later
features change Zig or TypeScript implementation files, they must run the
focused validators required by the roadmap feature and repository guidance.

## Roadmap Traceability

This RFC provides the architecture decision record for `WASM-001`. Later
roadmap items supply the schema, WIT, runtime spike, browser host, package
integration, migrated tool, native-library research, and final closure evidence.

Traceability from this RFC:

- `WASM-001`: lifecycle, Bun compatibility, v1 artifact direction, manifest
  location, artifact resolution, tools-only v0, and default-deny capability
  policy
- `WASM-002`: manifest schema must enforce the one-tool shape, artifact rules,
  canonical capabilities, and deterministic diagnostics recorded here
- `WASM-003`: Tool WIT v0 must expose only metadata, schema, and execute with
  JSON payloads
- `WASM-004` and `WASM-005`: runtime spikes must decide whether the v1 path can
  use Wasm Components directly or needs a staged core-Wasm/Extism bootstrap
- `WASM-006` through `WASM-008`: browser, pure-tool, and package flows must use
  the same manifest, artifact, lifecycle, and capability terms
- `WASM-009`: native shared-library research must not change the third-party
  default without concrete evidence and a separate trust-boundary decision
