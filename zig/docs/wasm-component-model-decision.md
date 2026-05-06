# WASM-005 Component Model Runtime Decision

Status: decision evidence for `WASM-005`

Related artifacts:

- Roadmap: [`wasm-extension-roadmap.md`](wasm-extension-roadmap.md)
- Architecture RFC: [`wasm-extension-architecture-rfc.md`](wasm-extension-architecture-rfc.md)
- WIT v0 contract: [`wasm-tool-wit-v0.md`](wasm-tool-wit-v0.md) and [`../wit/pi-tool-v0.wit`](../wit/pi-tool-v0.wit)
- Native host spike evidence: [`wasm-host-spike-evidence.md`](wasm-host-spike-evidence.md)
- Native host spike source: [`../src/coding_agent/wasm_host_spike.zig`](../src/coding_agent/wasm_host_spike.zig)
- Native fixture: [`../test/fixtures/wasm/native-tool-v0/plugin.wasm`](../test/fixtures/wasm/native-tool-v0/plugin.wasm)

## Scope

This document compares the feasible v1 runtime paths for Pi's tools-only Wasm
extension surface:

1. Extism plugin runtime.
2. Direct WebAssembly Component Model/WIT hosting.
3. A staged path that keeps the v1 author contract pointed at WIT/components
   while using the current core-Wasm/native-host evidence as a bootstrap
   implementation target.

The contract being compared is the same v0 tool contract used by the roadmap:
`metadata()`, `schema()`, and `execute(input-json)` with JSON string payloads.
Bun-hosted TypeScript extension compatibility remains unchanged and out of
scope for replacement.

## Existing Spike Evidence

`WASM-004` attempted Extism first under the project-local dependency policy.
The attempt found no repository-local Extism SDK, C library, or vendored runtime
artifact:

```text
$ npm ls @extism/extism extism --depth=0 --prefix /Users/davirian/dev/active/worktrees/wasm-extension-1nl
pi-monorepo@0.0.3 /Users/davirian/dev/active/worktrees/wasm-extension-1nl
└── (empty)

$ test -d /Users/davirian/dev/active/worktrees/wasm-extension-1nl/zig/vendor/extism && printf 'zig/vendor/extism present\n' || printf 'zig/vendor/extism missing\n'
zig/vendor/extism missing

$ PKG_CONFIG_PATH=/Users/davirian/dev/active/worktrees/wasm-extension-1nl/zig/vendor/extism/lib/pkgconfig:/Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/@extism/extism/lib/pkgconfig pkg-config --exists extism; printf 'pkg-config extism exit=%s\n' "$?"
pkg-config extism exit=1
```

The accepted `WASM-004` substitute is a standalone Zig host spike that loads the
repository-local `plugin.wasm` fixture, validates it is import-free, calls all
three tool exports, validates JSON objects for `metadata` and `schema`, and
compares `execute` against this expected output:

```json
{"ok":true,"tool":"fixture.echo","echo":"native-wasm"}
```

The substitute is not a production VM. It is evidence for the standalone
load/initialize/call shape and integration cost while avoiding global installs
or platform package manager dependencies.

## Component Model Experiment Attempt

The repository already contains the author-facing WIT shape:

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

An equivalent Component Model artifact or host run could not be produced with
the currently installed project-local tooling. Concrete attempted commands:

```text
$ npm ls @bytecodealliance/jco @bytecodealliance/componentize-js wasm-tools wit-bindgen wasmtime wasmer --depth=0 --prefix /Users/davirian/dev/active/worktrees/wasm-extension-1nl
pi-monorepo@0.0.3 /Users/davirian/dev/active/worktrees/wasm-extension-1nl
└── (empty)

$ test -x /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/.bin/jco && /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/.bin/jco --version || { printf 'node_modules/.bin/jco missing or not executable\n'; exit 127; }
node_modules/.bin/jco missing or not executable

$ test -x /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/.bin/componentize-js && /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/.bin/componentize-js --version || { printf 'node_modules/.bin/componentize-js missing or not executable\n'; exit 127; }
node_modules/.bin/componentize-js missing or not executable

$ test -x /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/.bin/wasm-tools && /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/.bin/wasm-tools --version || { printf 'node_modules/.bin/wasm-tools missing or not executable\n'; exit 127; }
node_modules/.bin/wasm-tools missing or not executable
```

The focused project-local WIT consistency command does run:

```text
$ cd /Users/davirian/dev/active/worktrees/wasm-extension-1nl/zig && zig build test-coding-agent -- --test-filter "wasm wit"
exit 0
```

That proves the WIT/documented contract is present and cross-checked, but it
does not prove a real Component Model guest artifact can be built or a
Component Model instance can be hosted directly by Zig.

External tooling note: Bytecode Alliance's Component Model documentation
describes `jco` as a JavaScript tool for running and transpiling WebAssembly
components to ECMAScript. That supports the browser path as a likely future
tooling option, but `jco` is not currently installed as a project-local
dependency in this repository.

## Output Comparability

| Contract surface | Extism path | Direct Component Model path | Staged core-Wasm/WIT path |
| --- | --- | --- | --- |
| `metadata()` | Not runnable project-locally because Extism runtime is absent. The blocker is documented in `wasm-host-spike-evidence.md`. | Not runnable project-locally because component build/host tooling is absent. The WIT declaration exists. | Runnable through the native fixture; tests validate a JSON object with `id`, `name`, `version`, and `description`. |
| `schema()` | Not runnable project-locally for the same Extism blocker. | Not runnable project-locally for the same Component Model tooling blocker. | Runnable through the native fixture; tests validate a JSON object with `inputSchema` and `outputSchema`. |
| `execute(input-json)` | Not runnable project-locally for the same Extism blocker. | Not runnable project-locally for the same Component Model tooling blocker. | Runnable through the native fixture; tests compare `{"ok":true,"tool":"fixture.echo","echo":"native-wasm"}`. |
| Comparable output evidence | Infeasible without adding/vendoring Extism. | Infeasible without adding project-local Component Model tooling and a Zig host runtime. | Available today with `cd zig && zig build test-coding-agent -- --test-filter "wasm host"`. |

## Decision Matrix

| Axis | Extism | Direct Component Model | Staged path |
| --- | --- | --- | --- |
| Type safety | Uses a simple JSON-string plugin contract that matches the v0 spike but does not provide WIT-level typed records or variants. | Best long-term type story because WIT can evolve from JSON strings to typed records/variants without changing the host concept. | Keeps the manifest/WIT contract stable while accepting JSON strings for v0; allows later typed WIT without blocking near-term host work. |
| Tooling maturity | Mature plugin concept, but no project-local SDK/runtime exists in this repo. Production use would require vendored `libextism` artifacts and platform packaging. | Tooling exists externally around WIT/components, including `jco`, but no required project-local packages or Zig Component Model host are present here. | Uses existing Zig stdlib tests and repository-local fixtures now; can add `jco`, `componentize-js`, or a runtime later as project-local dependencies when approved. |
| Browser support | Extism's native host does not directly satisfy the browser-host milestone; a separate browser adapter would still be needed. | Browser path is promising through component-to-JS tooling such as `jco`, but browsers do not remove the need for project-local component tooling and capability-denial tests. | Most compatible with staged `WASM-006`: keep capability-free JSON tools simple, then validate browser execution with approved project-local tooling. |
| Zig host complexity | Zig integration needs C ABI/linking or dynamic loading for `libextism`, plugin lifetime management, and per-platform artifacts. | Highest immediate Zig complexity: the host needs Component Model canonical ABI support or an embedded runtime that can instantiate components and WIT worlds. | Lowest immediate complexity: the current standalone host spike already proves load/initialize/call shape for a constrained fixture while deferring production runtime choice. |
| Package size/runtime footprint | Not measurable in this repo because no project-local Extism package/library is installed. Expected footprint includes `libextism` plus per-platform packaging. | Not measurable in this repo because `jco`, `componentize-js`, `wasm-tools`, `wit-bindgen`, and `wasmtime` are absent. | Measured fixture is 682 bytes. Runtime footprint is Zig stdlib test code only for the spike; production footprint remains scoped to the eventual runtime decision. |
| Spike evidence | Extism-specific attempted commands and blockers are recorded. No successful Extism host run is available project-locally. | WIT source and consistency tests exist, but component build/host commands are blocked by missing project-local tooling. | Successful focused host and WIT checks exist with repository-local fixture/source and no global dependency requirement. |

## Footprint Evidence

Measured or scoped-out footprint evidence:

```text
$ wc -c /Users/davirian/dev/active/worktrees/wasm-extension-1nl/zig/test/fixtures/wasm/native-tool-v0/plugin.wasm
682 /Users/davirian/dev/active/worktrees/wasm-extension-1nl/zig/test/fixtures/wasm/native-tool-v0/plugin.wasm

$ for path in /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/@bytecodealliance/jco /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/@bytecodealliance/componentize-js /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/wasm-tools /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/wit-bindgen /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/wasmtime; do if [ -e "$path" ]; then du -sh "$path"; else printf '%s missing\n' "$path"; fi; done
/Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/@bytecodealliance/jco missing
/Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/@bytecodealliance/componentize-js missing
/Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/wasm-tools missing
/Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/wit-bindgen missing
/Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/wasmtime missing
```

Therefore only the staged fixture footprint is measured today. Extism and direct
Component Model runtime footprints are explicitly scoped out until their
runtime packages are added or vendored project-locally.

## V1 Recommendation

Recommend the staged path for v1:

1. Keep the v1 authoring and manifest direction as WIT plus
   `artifact.kind: "wasm-component"`.
2. Do not select Extism as the v1 default runtime today because the repository
   has no project-local Extism runtime and production use would add
   platform-specific library packaging.
3. Do not select direct Component Model hosting as immediately implementable
   today because the repository has WIT definitions but lacks project-local
   component build/host tooling and a proven Zig Component Model host.
4. Continue with the existing JSON-string WIT/core-Wasm fixture as the bootstrap
   compatibility layer for native and browser spikes, then promote the artifact
   from staged core-Wasm to real Wasm Component once project-local component
   tooling and browser-host evidence exist.

This recommendation preserves Bun compatibility, keeps the default third-party
format aimed at Wasm Components, avoids global installs, and lets the next
milestones validate browser execution, capability denial, package handoff, and
pure-tool migration without committing to an unproven runtime dependency.

## Validation Commands

Commands used for this decision:

```text
/Users/davirian/.factory/missions/b2809ef6-1bb2-40b6-9497-e73bd78e6ff8/init.sh
cd /Users/davirian/dev/active/worktrees/wasm-extension-1nl/zig && zig build test-coding-agent -- --test-filter "loadFromExtensionPaths reads sidecar manifest and registers flags"
cd /Users/davirian/dev/active/worktrees/wasm-extension-1nl/zig && zig build test-coding-agent -- --test-filter "wasm wit"
cd /Users/davirian/dev/active/worktrees/wasm-extension-1nl/zig && zig build test-coding-agent -- --test-filter "wasm host"
npm ls @bytecodealliance/jco @bytecodealliance/componentize-js wasm-tools wit-bindgen wasmtime wasmer --depth=0 --prefix /Users/davirian/dev/active/worktrees/wasm-extension-1nl
test -x /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/.bin/jco && /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/.bin/jco --version || { printf 'node_modules/.bin/jco missing or not executable\n'; exit 127; }
test -x /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/.bin/componentize-js && /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/.bin/componentize-js --version || { printf 'node_modules/.bin/componentize-js missing or not executable\n'; exit 127; }
test -x /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/.bin/wasm-tools && /Users/davirian/dev/active/worktrees/wasm-extension-1nl/node_modules/.bin/wasm-tools --version || { printf 'node_modules/.bin/wasm-tools missing or not executable\n'; exit 127; }
wc -c /Users/davirian/dev/active/worktrees/wasm-extension-1nl/zig/test/fixtures/wasm/native-tool-v0/plugin.wasm
```

No code or package files were changed for `WASM-005`, so `npm run check` is not
required by the feature gate.
