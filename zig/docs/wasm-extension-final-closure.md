# WASM Extension Final Closure

Status: authoritative final status artifact for `WASM-001` through `WASM-009`

Roadmap context: [`wasm-extension-roadmap.md`](wasm-extension-roadmap.md)

## Final Decision

The roadmap is closed with a staged Wasm path:

1. Existing Bun-hosted TypeScript extensions remain unchanged through the
   compatibility path.
2. Third-party extension artifacts default to Wasm/Wasm Component, with
   `artifact.kind: "wasm-component"` as the intended v1 authoring direction.
3. v0 is tools-only: `metadata`, `schema`, and `execute` with JSON string
   payloads.
4. Capabilities are default-deny and host-enforced. Declarations are requests,
   not approvals, and unapproved or unavailable capabilities produce
   deterministic `denied_capability` diagnostics.
5. Native shared libraries are recommendation-only research output for now and
   remain separately scoped for trusted first-party or performance-critical
   code.

## Milestone Synthesis

### Milestone 1: Architecture, Manifest, and WIT Foundation

`WASM-001`, `WASM-002`, and `WASM-003` established the architecture RFC,
`pi-extension.json` v0 validation, and the stable Tool WIT v0 contract. The
foundation preserves Bun compatibility, defines the lifecycle terms
`discover`, `validate`, `load`, `initialize`, `call`, and `unload`, and
constrains v0 to one Wasm-backed tool with default-deny capabilities.

### Milestone 2: Native Host Spikes and Runtime Decision Evidence

`WASM-004` and `WASM-005` attempted Extism and Component Model paths under the
project-local dependency policy. Extism and direct Component Model hosting were
not available from project-local tooling, so the accepted near-term path is a
standalone Zig native-Wasm fixture host plus a staged WIT/Wasm Component v1
recommendation.

### Milestone 3: Browser Host, Pure Tool, and Package Integration

`WASM-006`, `WASM-007`, `WASM-008`, and the capability consistency follow-up
proved browser-side execution, default-deny denial behavior, migration of the
existing `truncateHead` pure tool to a Wasm fixture, and local package discovery
for `pi-extension.json` without changing Bun package behavior.

### Milestone 4: Native Shared-Library Research and Closure

`WASM-009` compared native shared libraries with Wasm across dynamic loading,
ABI stability, signing, crash isolation, platform packaging, trust boundaries,
and failure modes. The conclusion keeps Wasm/Wasm Component as the third-party
default and scopes native libraries separately.

## Roadmap Traceability

| Item | Final status | Evidence |
| --- | --- | --- |
| `WASM-001` | Complete | [`wasm-extension-architecture-rfc.md`](wasm-extension-architecture-rfc.md); roadmap commit `40c9aaa00b52fe6186094228a55b1879c0965524`; lifecycle, Bun compatibility, manifest/artifact resolution, v1 artifact direction, tools-only v0, and default-deny policy sections. |
| `WASM-002` | Complete | [`../src/coding_agent/wasm_manifest.zig`](../src/coding_agent/wasm_manifest.zig); [`../../packages/coding-agent/src/core/wasm-extension-package.ts`](../../packages/coding-agent/src/core/wasm-extension-package.ts); commit `dcc331d2e2e50a9f76af9f84e96aaca36870b76e`; focused manifest, lifecycle, artifact, capability, and Bun-discovery tests. |
| `WASM-003` | Complete | [`../wit/pi-tool-v0.wit`](../wit/pi-tool-v0.wit); [`wasm-tool-wit-v0.md`](wasm-tool-wit-v0.md); [`../src/coding_agent/wasm_wit_contract.zig`](../src/coding_agent/wasm_wit_contract.zig); commit `0f3a1cf6f9b63d08b04d93621ffe23a5f2e41564`. |
| `WASM-004` | Closed by spike evidence | [`wasm-host-spike-evidence.md`](wasm-host-spike-evidence.md); [`../src/coding_agent/wasm_host_spike.zig`](../src/coding_agent/wasm_host_spike.zig); [`../test/fixtures/wasm/native-tool-v0/plugin.wasm`](../test/fixtures/wasm/native-tool-v0/plugin.wasm); commit `74f27b898abc640656a34fc69c21ce15d464e6e0`. |
| `WASM-005` | Closed by decision | [`wasm-component-model-decision.md`](wasm-component-model-decision.md); commit `e211f8c7cd9f97a478eebf29a0f9e416ce6f73d9`; documented Component Model tooling blockers, output comparability, footprint evidence, and staged v1 recommendation. |
| `WASM-006` | Complete | [`../test/fixtures/wasm/browser-host-v0/index.html`](../test/fixtures/wasm/browser-host-v0/index.html); [`../test/fixtures/wasm/browser-host-v0/browser-wasm-host.js`](../test/fixtures/wasm/browser-host-v0/browser-wasm-host.js); [`../test/fixtures/wasm/browser-host-v0/harness-smoke.mjs`](../test/fixtures/wasm/browser-host-v0/harness-smoke.mjs); commit `93156e403377511a385459ac238bdeca8a48e62f`; agent-browser evidence on port 3120 with cleanup across 3120-3129. |
| `WASM-007` | Complete | [`../src/coding_agent/tools/truncate.zig`](../src/coding_agent/tools/truncate.zig); [`../test/fixtures/wasm/pure-truncate-head-v0/pi-extension.json`](../test/fixtures/wasm/pure-truncate-head-v0/pi-extension.json); [`../test/fixtures/wasm/pure-truncate-head-v0/wasm/plugin.wasm`](../test/fixtures/wasm/pure-truncate-head-v0/wasm/plugin.wasm); commit `931b3903b272a313a86df765c586df94f3ff5164`. |
| `WASM-008` | Complete | [`../../packages/coding-agent/src/core/wasm-extension-package.ts`](../../packages/coding-agent/src/core/wasm-extension-package.ts); [`../../packages/coding-agent/test/package-manager.test.ts`](../../packages/coding-agent/test/package-manager.test.ts); [`../../packages/coding-agent/test/extensions-discovery.test.ts`](../../packages/coding-agent/test/extensions-discovery.test.ts); commit `4f566e0daf702f0f133fedcd437b7792bc6cedf5`. |
| `WASM-009` | Closed by research decision | [`wasm-native-library-research.md`](wasm-native-library-research.md); commit `342173219b867c7dccc9521414c377c07bdfe435`; recommendation-only native-library comparison and default-third-party Wasm conclusion. |

## Cross-Cutting Closure

### Bun/TypeScript Compatibility

The final state preserves the existing Bun compatibility path. The architecture
RFC states that packages without `pi-extension.json` continue through existing
package and Bun extension discovery rules. `WASM-008` adds Wasm package
classification beside that path and keeps the existing `package.json`
`pi.extensions` behavior covered by focused package and extension discovery
tests.

### Default-Deny Capability Policy

The canonical capability ids are `file.read`, `file.write`, `network`, `shell`,
`env`, `model`, `session`, and `ui.notify`. The native validator maps each id to
an explicit enforcement branch, rejects unknown ids, and emits
`denied_capability` for requested-but-unapproved and runtime/import attempts.
The browser harness denies shell and local filesystem requests in both
manifest-request and runtime/import modes.

### Project-Local Dependency Policy

All roadmap evidence uses repository files, project-local package scripts,
vendored fixtures, or temporary local validation processes. Extism and Component
Model attempts are documented as unavailable without adding project-local
runtime/tooling artifacts; no final decision relies on a global runtime or
system package manager installation.

### Lifecycle Diagnostics

The RFC, roadmap, manifest validator, native host spike, and browser harness use
the same lifecycle terms: `discover`, `validate`, `load`, `initialize`, `call`,
and `unload`. Representative discovery, validation, initialization, call, and
capability-denial failures are user-visible deterministic diagnostics rather
than uncaught stack traces. Native unload cleanup evidence is covered by
`wasm_host_spike.zig` test `wasm unload cleanup releases host resources and
unregisters tool`, which deinitializes the host runtime, removes the registered
Wasm tool, and confirms no process/server handle is part of the native host
state.

### README and Public-Docs Gate

The root README and current package docs continue to describe the released
TypeScript extension and package behavior. This roadmap closure does not promote
the Wasm v0 spike surface to public user-facing installation instructions; the
authoritative Wasm status remains in `zig/docs/` until a released product path
is accepted.

## Validation Evidence Summary

The completed handoffs record these validation surfaces:

| Surface | Representative evidence |
| --- | --- |
| Focused Zig foundation tests | `cd zig && zig build test-coding-agent -- --test-filter "wasm manifest"`; `cd zig && zig build test-coding-agent -- --test-filter "pi-extension"`; `cd zig && zig build test-coding-agent -- --test-filter "wasm wit"` |
| Focused Zig host/package/capability tests | `cd zig && zig build test-coding-agent -- --test-filter "extism"`; `cd zig && zig build test-coding-agent -- --test-filter "wasm host"`; `cd zig && zig build test-coding-agent -- --test-filter "wasm unload"`; `cd zig && zig build test-coding-agent -- --test-filter "wasm pure tool"`; `cd zig && zig build test-coding-agent -- --test-filter "wasm package"`; `cd zig && zig build test-coding-agent -- --test-filter "wasm capability"` |
| Focused TypeScript package tests | `cd packages/coding-agent && npx tsx ../../node_modules/vitest/dist/cli.js --run test/package-manager.test.ts`; `cd packages/coding-agent && npx tsx ../../node_modules/vitest/dist/cli.js --run test/extensions-discovery.test.ts` |
| Browser validation | `node zig/test/fixtures/wasm/browser-host-v0/harness-smoke.mjs`; agent-browser sessions on `http://127.0.0.1:3120/zig/test/fixtures/wasm/browser-host-v0/index.html`; pre/post `lsof -nP -iTCP:3120-3129 -sTCP:LISTEN` checks showing cleanup. |
| Repository check after code changes | `npm run check` passed in the final successful handoffs for the implementation features after the web-ui source-resolution blocker was fixed. |

This validation summary intentionally lists only allowed focused commands and
project-local tools.
