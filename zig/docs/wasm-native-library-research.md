# WASM-009 Native Shared-Library Research

Status: recommendation-only research artifact for `WASM-009`

Related artifacts:

- Roadmap: [`wasm-extension-roadmap.md`](wasm-extension-roadmap.md)
- Architecture RFC: [`wasm-extension-architecture-rfc.md`](wasm-extension-architecture-rfc.md)
- WIT v0 contract: [`wasm-tool-wit-v0.md`](wasm-tool-wit-v0.md) and
  [`../wit/pi-tool-v0.wit`](../wit/pi-tool-v0.wit)
- Native Wasm host spike evidence:
  [`wasm-host-spike-evidence.md`](wasm-host-spike-evidence.md)
- Component runtime decision:
  [`wasm-component-model-decision.md`](wasm-component-model-decision.md)

## Scope

This document is research and recommendation only. It does not accept, design,
or implement a native `.so`, `.dylib`, or `.dll` loader for Pi extensions.

The question is whether native shared-library extensions should change the
extension-format default chosen by the Wasm roadmap. The evaluated native path
is constrained to possible future trusted first-party or performance-critical
integrations. It is not evaluated as an untrusted third-party plugin format.

## Recommendation

Keep Wasm or Wasm Components as the default third-party extension format.
Native shared libraries do not overturn that default because the research
evidence favors Wasm for trust boundaries, crash containment, cross-platform
packaging, and default-deny host capability enforcement.

If Pi later needs native shared-library support, scope it as a separate feature
for trusted first-party or explicitly approved performance-critical extensions.
That feature would need its own manifest kind, signing policy, per-platform
packaging plan, loader lifecycle, crash recovery strategy, ABI versioning
contract, and user/project approval model. It should not be accepted as part of
the `WASM-009` research evidence.

## Evidence Inputs

Repository evidence:

- `wasm-extension-architecture-rfc.md` fixes the additive Wasm path, preserves
  Bun TypeScript compatibility, keeps v0 tools-only, and states that native
  shared libraries are research-only unless separately accepted.
- `wasm-tool-wit-v0.md` documents the stable tool contract:
  `metadata()`, `schema()`, and `execute(input-json)` with JSON string payloads
  and no v0 host functions.
- `wasm-host-spike-evidence.md` records the standalone native Wasm fixture host
  and the Extism blocker under the project-local dependency policy.
- `wasm-component-model-decision.md` recommends a staged v1 path that keeps the
  authoring direction pointed at WIT plus `artifact.kind: "wasm-component"`.
- `packages/coding-agent/docs/extensions.md` and `packages.md` document that
  current TypeScript extensions and packages run with full system access and
  must remain a separate Bun compatibility path.

External platform evidence consulted:

| Area | Source | Durable finding used here |
| --- | --- | --- |
| Linux dynamic loading | `dlopen(3)` on man7.org | Native shared objects are loaded into the calling process and resolved through platform loader rules. |
| Windows DLL loading | Microsoft Learn, "Dynamic-link library search order" and "Dynamic-Link Library Security" | Fully qualified DLL paths are the safer loading mode; otherwise Windows searches a defined set of directories, creating loader-search and substitution risk. |
| macOS signing and loading | Apple Developer documentation/forums for Hardened Runtime and library validation | Hardened Runtime library validation constrains which signed code a process can load; weakening it expands the trust boundary. |
| Wasm sandboxing | webassembly.org security documentation and W3C Wasm Core 2.0/3.0 materials | Wasm execution is defined around isolated linear memories and host-mediated imports. |
| WASI capability direction | wasi.dev introduction and capability-oriented runtime docs | System access is modeled through explicit host-provided interfaces rather than ambient process authority. |

## Comparison Matrix

| Dimension | Native shared library | Wasm / Wasm Component | Research conclusion |
| --- | --- | --- | --- |
| Dynamic loading | Uses platform loaders such as `dlopen`, `dyld`, or `LoadLibrary`. Loading places plugin code in the Pi process with native symbols, constructors, thread-local state, and loader side effects. Search path rules, rpaths, dependency lookup, and transitive native libraries become part of plugin acceptance. | Loads a Wasm artifact through an explicit runtime adapter after manifest validation. Imports are declared by the module/component and can be rejected before initialization. The current v0 contract exposes no host functions. | Native loading is viable for trusted code but has more ambient loader behavior. Wasm better matches the roadmap lifecycle: validate before load, bind capabilities during initialize, call through a constrained contract. |
| ABI stability | Requires a C ABI or per-language ABI boundary, explicit struct layout/versioning, allocator ownership rules, string lifetime rules, callback conventions, thread-safety rules, and symbol-version migration. C++/Rust/Zig compiler ABI details cannot be treated as stable plugin contracts without a C-compatible shim. | WIT and the Component Model provide an interface description that can evolve independently of a guest source language. v0 JSON strings are less type-rich but stable across language toolchains and can move toward typed records later. | Native ABI design would be a separate compatibility project. Wasm keeps the extension ABI language-neutral and better aligned with the existing WIT v0/v1 direction. |
| Signing and provenance | Must satisfy platform-specific signing and notarization. macOS Hardened Runtime/library validation may reject third-party libraries unless signing policy is aligned or validation is disabled. Windows and Linux need their own provenance and distribution verification. | Wasm artifacts can still be signed or checksummed by package policy, but execution does not depend on the host process accepting arbitrary platform-native code signatures. The same artifact format can be validated before runtime instantiation. | Native signing is possible, but the policy is per-platform and loader-coupled. Wasm gives Pi a single package-level verification point before execution. |
| Crash isolation | A native plugin runs in the Pi process by default. Segfaults, illegal instructions, memory corruption, allocator misuse, data races, deadlocks in constructors/destructors, or aborts can crash or corrupt the host. Recovering requires out-of-process hosting or a much heavier supervisor model. | A Wasm runtime can trap plugin faults and report deterministic load/initialize/call diagnostics. Linear memory and host-mediated imports reduce memory-unsafety impact on the Pi process, though runtime bugs remain possible. | Crash and memory-unsafety impact is the strongest reason not to make native libraries the third-party default. |
| Platform packaging | Requires separate artifacts for macOS/Linux/Windows, CPU architecture, libc/toolchain variants, signing/notarization, loader paths, and native transitive dependencies. Tests must cover each target loader. | A Wasm module/component is designed as a portable binary target. Runtime availability is still a dependency, but the plugin package does not need per-OS native binary variants for the same tool logic. | Native packaging is appropriate only when platform-specific performance or APIs are the point of the extension. Default third-party tooling should remain Wasm. |
| Trust boundary | Native code inherits the process trust boundary unless Pi moves it out of process and mediates all I/O. A manifest can describe intended permissions, but the loader cannot prevent arbitrary syscalls, filesystem access, process spawning, or memory inspection in-process. | Wasm starts with no ambient authority in the roadmap. v0 exposes no host functions, unknown capabilities are validation errors, and requested capabilities remain denied unless a later host feature grants them explicitly. | Native shared libraries are a trusted-code mechanism. Wasm is the correct default for untrusted or third-party code. |
| Failure modes | Loader errors can include missing transitive libraries, incompatible architecture, symbol mismatch, constructor failure, code-signing rejection, search-path hijack, global state collision, host crash, and undefined behavior after unload. Many failures are platform-specific. | Failure modes are lifecycle-scoped: discovery, manifest validation, artifact load, initialization, call, and unload diagnostics. Plugin faults can be converted into structured traps/errors when the runtime supports them. | Wasm produces failures that fit Pi's documented lifecycle and are easier to make user-visible and deterministic. |
| Bun compatibility | A native plugin path would be a third extension mechanism beside Bun and Wasm. Without tight separation it could confuse package discovery and risk reinterpreting existing `package.json` extension packages. | The RFC already defines Wasm discovery beside, not before or instead of, the Bun compatibility path. `pi-extension.json` is the Wasm package marker. | Adding native libraries would require a separate marker and cannot reuse `pi-extension.json` acceptance rules without a new scoped design. |

## Trust Boundary Analysis

### Third-party extensions

Third-party extensions should be assumed untrusted or only partially trusted.
Native shared libraries are not a good default for that class because in-process
native code can use the host process authority directly. A manifest declaration
does not sandbox syscalls, environment access, filesystem reads, network calls,
or host memory access once native code is executing in the process.

Wasm better matches the current extension contract:

- manifest validation happens before load or install success
- v0 exposes a single tool surface
- v0 exposes no host functions
- capabilities are default-deny and host-enforced
- browser and native hosts can deny unavailable capabilities deterministically

### Trusted first-party or performance-critical extensions

Native shared libraries may be reasonable for code that Pi maintainers ship,
sign, test, and version with the host, especially when the extension must call
platform APIs, reuse mature native libraries, or meet performance requirements
that are not practical in Wasm.

That path must be separately scoped. Minimum acceptance requirements would be:

1. A native-specific manifest kind distinct from Wasm artifacts.
2. A stable C ABI with explicit version negotiation and ownership rules.
3. Platform-specific signing and provenance verification.
4. A packaging matrix for OS, architecture, libc/toolchain, and transitive
   native dependencies.
5. Deterministic loader diagnostics for missing dependencies, bad signatures,
   incompatible ABI versions, and missing symbols.
6. A crash containment decision: either accept host-process crash risk for
   trusted first-party code or run native plugins out-of-process.
7. A permission model that states native plugins are trusted code and must not
   be treated as sandboxed by manifest capability declarations alone.

## Failure Mode Detail

| Native failure | Host impact | Wasm contrast |
| --- | --- | --- |
| Missing transitive library | Load fails on one platform even if the top-level plugin is present. Diagnostics depend on loader behavior. | Manifest/artifact validation can reject the declared artifact before runtime success; imports can be checked before initialization. |
| Wrong architecture or ABI version | Loader or first symbol call fails; undefined behavior is possible if the ABI version is not negotiated correctly. | WIT/component metadata and manifest version checks can fail deterministically before call. |
| Code-signing or notarization mismatch | macOS/Windows policy can reject load or require weakening validation. | Package-level signature/hash policy can be host-defined without disabling platform library validation. |
| Constructor or global initializer side effects | Plugin code can execute during load before Pi has bound permissions. | The roadmap requires validation before load; Wasm imports/capabilities can be denied before initialization. |
| Memory corruption or abort | Can corrupt or terminate the Pi process. | Runtime traps can be surfaced as load/initialize/call diagnostics, with host memory outside guest linear memory protected by the runtime boundary. |
| Unload hazards | Dangling callbacks, background threads, leaked global state, and allocator mismatch can survive `dlclose`/unload. | Runtime handle teardown can release plugin state and remove registrations; unload still needs tests, but the state boundary is narrower. |
| Search-path substitution | A loader may find a different library than intended if paths are not fully controlled. | Artifact path normalization and symlink-escape checks are already part of the Wasm manifest contract. |

## Decision

For `WASM-009`, native shared libraries remain a deferred, trusted-code
research path. They are not accepted as a third-party extension default and no
native loader implementation is part of this feature.

The extension roadmap should continue with:

1. Bun-hosted TypeScript extensions unchanged through the compatibility path.
2. Wasm/Wasm Component as the default third-party extension artifact direction.
3. Tools-only v0 with default-deny host capabilities.
4. A separately scoped native shared-library proposal only if a concrete
   first-party or performance-critical use case justifies the additional ABI,
   signing, packaging, crash-isolation, and trust-boundary work.
