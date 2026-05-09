<p align="center">
  <a href="https://pi.dev">
    <img alt="pi logo" src="https://pi.dev/logo-auto.svg" width="128">
  </a>
</p>
<p align="center">
  <a href="https://discord.com/invite/3cU7Bz4UPx"><img alt="Discord" src="https://img.shields.io/badge/discord-community-5865F2?style=flat-square&logo=discord&logoColor=white" /></a>
</p>
<p align="center">
  <a href="https://pi.dev">pi.dev</a> domain graciously donated by
  <br /><br />
  <a href="https://exe.dev"><img src="packages/coding-agent/docs/images/exy.png" alt="Exy mascot" width="48" /><br />exe.dev</a>
</p>

> New issues and PRs from new contributors are auto-closed by default. Maintainers review auto-closed issues daily. See [CONTRIBUTING.md](CONTRIBUTING.md).

---

# Pi Agent Harness Mono Repo

This is the home of the pi agent harness project including our self extensible coding agent.

* **[@earendil-works/pi-coding-agent](packages/coding-agent)**: Interactive coding agent CLI
* **[@earendil-works/pi-agent-core](packages/agent)**: Agent runtime with tool calling and state management
* **[@earendil-works/pi-ai](packages/ai)**: Unified multi-provider LLM API (OpenAI, Anthropic, Google, …)

To learn more about pi:

* [Visit pi.dev](https://pi.dev), the project website with demos
* [Read the documentation](https://pi.dev/docs/latest), but you can also ask the agent to explain itself

## Share your OSS coding agent sessions

If you use pi or other coding agents for open source work, please share your sessions.

Public OSS session data helps improve coding agents with real-world tasks, tool use, failures, and fixes instead of toy benchmarks.

For the full explanation, see [this post on X](https://x.com/badlogicgames/status/2037811643774652911).

To publish sessions, use [`badlogic/pi-share-hf`](https://github.com/badlogic/pi-share-hf). Read its README.md for setup instructions. All you need is a Hugging Face account, the Hugging Face CLI, and `pi-share-hf`.

You can also watch [this video](https://x.com/badlogicgames/status/2041151967695634619), where I show how I publish my `pi-mono` sessions.

I regularly publish my own `pi-mono` work sessions here:

- [badlogicgames/pi-mono on Hugging Face](https://huggingface.co/datasets/badlogicgames/pi-mono)

## All Packages

| Package | Description |
|---------|-------------|
| **[@earendil-works/pi-ai](packages/ai)** | Unified multi-provider LLM API (OpenAI, Anthropic, Google, etc.) |
| **[@earendil-works/pi-agent-core](packages/agent)** | Agent runtime with tool calling and state management |
| **[@earendil-works/pi-coding-agent](packages/coding-agent)** | Interactive coding agent CLI |
| **[@earendil-works/pi-tui](packages/tui)** | Terminal UI library with differential rendering |
| **[@earendil-works/pi-web-ui](packages/web-ui)** | Web components for AI chat interfaces |

## Extension substrate

The coding agent includes a static Zig native runtime adapter and a local WASM, `process_jsonl`, and native runtime substrate. The substrate provides generic enforcement boundaries and child-agent readiness for sub-agent extensions.

Bounded Sub-agent execution v0 adds product-neutral `sub_agent.delegate` and `/sub-agent` paths for a single bounded child execution, including limit, cancellation, and replay semantics. It does not include Workflow, Wiki, QA, or Review presets.

Extension policy/config substrate adds canonical extension identities and persistent `extensionPolicies` with user/project policy merge. Policies default deny unless approved grants and resource limits allow execution, and denial diagnostics are auditable.

Package trust/provenance for local extensions records validated package identity in a scope-local `extensions.lock.json`. Install and update compute manifest/package-root provenance, package-root SHA-256, and WASM artifact SHA-256 when applicable; load-time resolution rechecks those values before TypeScript import or WASM runtime handoff and reports drift without refreshing trust.

Package-backed policies are bound to the locked digest identity, so stale, cross-scope, or legacy non-digest policy keys cannot authorize changed packages. The TypeScript and Zig implementations share the same digest/principal shape and are covered by package-manager, resource-loader, runner, and TS/Zig parity checks.

Extension lifecycle hardening keeps capabilities in the extension layer while the core exposes only neutral substrate boundaries. Startup, teardown, cleanup, and timeout ordering are deterministic; extension-host APIs require policy gates; runtime adapters enforce declared capabilities; reserved sub-agent names and unsupported schema versions fail closed; and diagnostics use canonical envelopes with secret redaction.

The Zig Extension SDK and package authoring substrate is complete for standalone extensions. Authors can start from the Zig SDK template for WASM component tools or ship native dynamic packages with per-platform artifacts, then install, update, and remove them locally through the package lifecycle.

Local extension packages rely on lock/provenance verification, package-root and artifact digests, current-platform native artifact selection, scope discovery through the normal Zig CLI/agent tool registry, digest-bound policy gating, drift/denial/conflict omission diagnostics, runtime handoff, and invocation through normal session tool-call paths. The completed substrate remains Zig-only and does not change production TypeScript source behavior.

Phase 1 TS↔Zig extension parity is complete for the lower-layer extension substrate. The Zig native/session paths forward canonical underscore event names such as `session_start`, `agent_start`, `message_update`, `tool_execution_end`, `resources_discover`, `model_select`, and `thinking_level_select`; extension shortcuts dispatch through the configurable interactive input path; and the lower-layer UI bridge covers `ctx.ui.notify` and `ctx.ui.setStatus` request/response semantics. The `process_jsonl` runtime remains the current compatibility path for the TypeScript extension ecosystem, while WASM and native package authoring are local Zig substrate paths.

Product surfaces that depend on higher-level UI or distribution remain deferred: Web Simulator, Workflow/Wiki/QA/Review presets, marketplace flows, publisher/signing flows, remote package/runtime URLs, direct dynamic-library path authoring as a public product surface, and full selector/editor/overlay/widget UI parity.

Platform CI keeps macOS as the full Zig test runner, Windows as a build target, and Linux as an external-tool smoke gate until the Zig 0.16.0 Linux build-exe SIGSEGV is resolved. `test-ts-rpc-parity` is a local parity gate and requires host `libsimdjson`.

CLI-only validation for this substrate:

```bash
cd zig && zig build test-coding-agent
cd zig && zig build test-ts-rpc-parity
cd zig && zig build test-tidy
cd zig && zig build test
npm run check
```

Local extension-substrate validation requires Zig 0.16.0, Node/npm dependencies installed, `rg` and `fd` on `PATH`, and host `libsimdjson` for the standalone TS-RPC parity target. No provider credentials, web servers, package registries, signing services, marketplace endpoints, or browser/Web Simulator services are required.

## Chat bot workflows

For Slack/chat automation and workflows see [earendil-works/pi-chat](https://github.com/earendil-works/pi-chat).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines and [AGENTS.md](AGENTS.md) for project-specific rules (for both humans and agents).

## Development

```bash
npm install          # Install all dependencies
npm run build        # Build all packages
npm run check        # Lint, format, and type check
./test.sh            # Run tests (skips LLM-dependent tests without API keys)
./pi-test.sh         # Run pi from sources (can be run from any directory)
```

> **Note:** `npm run check` requires `npm run build` to be run first. The web-ui package uses `tsc` which needs compiled `.d.ts` files from dependencies.

### Zig implementation external tools

The native Zig CLI under `zig/` shells out to a few external executables:

- `rg` (`ripgrep`) for the coding-agent `grep` tool
- `fd` for the coding-agent `find` tool

`zig build`, `zig build test`, and the related Zig build steps verify that both tools are available on `PATH` and fail early with a clear error message if either one is missing.

```bash
brew install ripgrep fd
```

## License

MIT
