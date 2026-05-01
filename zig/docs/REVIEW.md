# Zig vs TypeScript Parity Review

## Executive Summary

This document reflects the current state of the Zig implementation relative to
the TypeScript implementation in this repository as of 2026-05-01.

The Zig rewrite is no longer a "provider stub" project. It already has:

- core AI/provider implementations
- interactive mode and print mode
- session persistence and TS-RPC parity fixtures
- resource discovery for extensions, skills, prompts, and themes
- a process boundary for extension-host communication
- clipboard image paste plumbing
- a basic `/share` flow

The remaining work is narrower and more concrete than the previous review
described. The biggest remaining gaps are:

1. provider stream contract cleanup
2. extension ecosystem parity
3. session lifecycle edge-case parity
4. `/share` behavior parity
5. image normalization and resize parity
6. package-management and extension CLI parity

The most important product decision is already made and should not be
re-litigated in this document:

- We are preserving the existing TypeScript extension ecosystem.
- Zig is the host runtime.
- Bun provides extension execution for compatibility with existing TS
  extensions.
- We are not replacing that with a new native-only extension API as the primary
  path.

---

## What Is Already Done

The previous version of this review overstated several gaps that are no longer
accurate.

### No Longer Open

- Ordered assistant content is present in Zig, including inline `tool_call`
  blocks in `content`, plus `text_signature` and `thought_signature` support in
  the AI types.
- OpenAI Responses Copilot dynamic-header behavior exists in the Zig provider.
- Bedrock parity is materially stronger than an early-stub state and already
  has dedicated parity fixtures.
- TS-RPC parity is not hypothetical; there are golden fixtures and parity
  scripts in `zig/test/`.
- Zig interactive mode already supports sessions, overlays, theme switching,
  clipboard image paste, `/share`, and session-tree flows.
- Zig has an extension-host process boundary already; the gap is extension API
  parity, not the absence of a host concept.

### Scope Correction

The right question is no longer "does Zig have an interactive/runtime shell at
all?" The right question is:

- where does behavior still differ in user-visible ways
- where do existing TS extensions still fail to run or register correctly
- where does the runtime contract still diverge enough to break replacement

---

## Current Blocking Gaps

## 1. Stream Contract Cleanup

### Status

Partially fixed, but still not fully aligned with the TS `StreamFunction`
contract.

TypeScript contract:

- `stream()` must return an event stream once invoked
- request/runtime failures should be encoded inside that returned stream
- callers should not receive late provider setup errors as hard throws

Reference:

- `packages/ai/src/types.ts`

### Current Zig State

`bedrock.zig` already wraps setup work more defensively and converts setup
failures into stream errors.

However, `openai.zig`, `openai_responses.zig`, and `anthropic.zig` still do
substantial `try` work before they can safely guarantee a returned stream in all
non-OOM failure paths.

Affected files:

- `zig/src/ai/providers/openai.zig`
- `zig/src/ai/providers/openai_responses.zig`
- `zig/src/ai/providers/anthropic.zig`

### Why It Matters

This is a replacement blocker because TS callers and Zig callers do not yet
share identical failure semantics. The difference shows up in retries, stream
cleanup, UI teardown, and error rendering.

### Priority

Critical.

---

## 2. Extension Ecosystem Parity

### Status

This is the largest remaining parity area.

Important clarification:

- The problem is not "Zig needs a new native extension system first."
- The problem is "Zig must host the existing TS extension ecosystem through Bun
  with enough API compatibility to preserve current behavior."

### Chosen Architecture

This repository has already chosen the correct direction:

- Zig owns TUI, sessions, tools, auth, RPC, and provider orchestration.
- Bun executes TS extensions in a child-process compatibility layer.
- Existing TS extension APIs remain the compatibility target.

This means the review should explicitly reject a rewrite-first strategy such as:

- inventing a separate Zig-native extension API and asking extensions to port
- treating TS extensions as legacy-only or optional
- redefining extension capability semantics before Bun compatibility exists

### What Zig Already Has

- resource discovery for extensions and package resources
- extension-host child-process lifecycle
- extension UI request/response protocol framing

### What Is Still Missing

Compared with the current TS extension surface, parity is still incomplete for:

- `registerTool(...)`
- `registerCommand(...)`
- `registerShortcut(...)`
- `registerFlag(...)`
- `registerProvider(...)` and `unregisterProvider(...)`
- extension CLI flag parsing and help integration
- extension-driven tool registry refresh semantics
- extension package install/update/remove/list/config flows
- extension widgets, custom editor hooks, header/footer injection, and terminal
  input hooks at the Bun compatibility layer

Relevant TS references:

- `packages/coding-agent/src/core/extensions/types.ts`
- `packages/coding-agent/src/core/extensions/loader.ts`
- `packages/coding-agent/src/core/agent-session.ts`
- `packages/coding-agent/src/package-manager-cli.ts`

Relevant Zig references:

- `zig/src/coding_agent/extension_host.zig`
- `zig/src/coding_agent/resources.zig`
- `zig/src/cli/args.zig`

### Concrete Current Gaps

#### CLI flag parity

TS accepts unknown `--flags` so extension flags can be registered and consumed
later. Zig currently treats unknown `--...` options as parse errors.

That blocks extension flags such as plan-mode style switches and any Bun-hosted
extension CLI integration.

#### Package-management parity

TS exposes:

- `install`
- `remove`
- `uninstall`
- `update`
- `list`
- `config`

Zig currently has resource loading and package path awareness, but not the same
user-facing command surface.

### Priority

Critical for full replacement.

---

## 3. Session Lifecycle Edge Cases

### Status

Core session persistence exists in Zig, but one important TS safety behavior is
still missing.

### Missing Session CWD Guard

TS explicitly checks whether the stored session cwd still exists before
resuming/opening a persisted session. In interactive mode it prompts the user to
continue in the current cwd; in non-interactive flows it fails clearly.

Reference:

- `packages/coding-agent/src/core/session-cwd.ts`
- `packages/coding-agent/src/main.ts`

Current Zig bootstrap always passes `cwd_override = options.cwd` when opening a
session path.

Reference:

- `zig/src/coding_agent/interactive_mode/session_bootstrap.zig`

### Why It Matters

Without this guard, resuming an old session after moving or deleting the
original project can silently redirect the session into the current repository.
That is a real correctness and safety issue for:

- resumed sessions
- forked sessions
- cross-project work
- tool execution rooted in the wrong cwd

### Remaining Lifecycle Verification Work

Beyond the missing cwd prompt, Zig still needs explicit parity coverage for:

- new session
- fork
- resume
- reconnect
- reload
- switching between persisted session files

### Priority

High.

---

## 4. `/share` Behavior Parity

### Status

Zig has `/share`, but not the same behavior as TS.

### Current Difference

Zig:

- builds a markdown transcript
- copies it to the clipboard

TS:

- writes a temporary export
- creates a secret GitHub gist through `gh`
- builds a viewer URL using `PI_SHARE_VIEWER_URL`
- shows both gist and viewer URL

Relevant files:

- `zig/src/coding_agent/interactive_mode/slash_commands.zig`
- `packages/coding-agent/src/modes/interactive/interactive-mode.ts`
- `packages/coding-agent/src/config.ts`

### Decision Required

This needs to be resolved explicitly, not left ambiguous.

One of these must become project policy:

1. Full parity: Zig also creates gist + viewer URL.
2. Intentional non-parity: markdown-to-clipboard remains the Zig behavior.

Until that decision is documented, users will continue to experience a visible
behavior mismatch.

### Priority

Medium-high.

---

## 5. Clipboard Image Normalization and Resize Parity

### Status

Zig supports clipboard image paste, but still lacks the normalization pipeline
used by TS.

### TS Behavior

TS image handling includes:

- EXIF orientation correction
- resizing to fit payload limits
- format conversion tradeoffs such as JPEG fallback
- dimension-note generation when resized

Relevant files:

- `packages/coding-agent/src/utils/exif-orientation.ts`
- `packages/coding-agent/src/utils/image-resize.ts`
- `packages/coding-agent/src/cli/file-processor.ts`

### Current Zig Behavior

Zig currently:

- reads clipboard image bytes
- detects or assigns mime type
- base64-encodes the image content

Relevant file:

- `zig/src/coding_agent/interactive_mode/clipboard_image.zig`

### Why It Matters

This creates real parity failures for:

- phone photos with EXIF rotation
- large screenshots
- providers with strict image payload limits
- coordinate mapping after resize

### Priority

Medium-high.

---

## 6. Package and CLI Surface Parity

### Status

Zig CLI covers core runtime flags, but not the TS operational surface.

### Missing TS Surface

TS CLI supports:

- package-management commands
- extension CLI flags
- extension-aware help text
- package configuration entrypoints

Zig CLI currently supports:

- runtime mode flags
- session flags
- tool allowlists
- resource path flags
- model listing

But it does not yet mirror the extension/package operational interface used by
the TS product.

Relevant files:

- `zig/src/cli/args.zig`
- `zig/src/main.zig`
- `packages/coding-agent/src/cli/args.ts`
- `packages/coding-agent/src/package-manager-cli.ts`

### Priority

High, because it directly blocks Bun-hosted extension compatibility and package
workflows.

---

## Secondary Gaps

These are real, but they are below the six areas above.

### Export HTML Parity

Zig has export support, but viewer-level parity still needs verification against
TS HTML output, tool rendering, anchors, and attachment behavior.

### Auth and Model Registry UX

The provider/auth core is present, but the review should still track:

- extension-driven provider registration through the Bun path
- auth guidance/help-text equivalence
- login/logout behavior parity in all modes

### Release/Binary Parity

Still needs explicit product decisions for:

- bundled resources
- external tool strategy
- packaged first-run behavior
- update/version UX

---

## Non-Goals

To avoid future churn, the following are not open design questions in this
review unless the project explicitly changes direction.

### Not a Goal: Replace TS Extensions With a New Primary Native API

Native Zig or Wasm extensions may still be useful later for hot paths or
performance-sensitive built-ins, but that is not the primary parity route.

Primary route:

- Bun executes TS extensions
- Zig hosts and mediates them
- API compatibility follows the current TS extension model

### Not a Goal: Pretend Old Gaps Are Still Blocking

This review should not continue to claim missing parity for areas already landed,
such as:

- inline assistant tool-call content
- signature fields in AI message types
- basic interactive mode
- TS-RPC parity infrastructure
- basic extension-host process support

---

## Recommended Work Order

## Phase 1: Runtime Contract Fixes

1. Finish `StreamFunction` error-path cleanup for `openai`, `openai_responses`,
   and `anthropic`.
2. Add regression coverage proving stream-return semantics match TS for
   non-OOM setup failures.

## Phase 2: Session Safety

1. Implement missing-session-cwd detection in Zig session bootstrap.
2. Add interactive and non-interactive parity tests.
3. Add fork/resume/reconnect lifecycle regression coverage.

## Phase 3: Bun Extension Compatibility

1. Keep Bun as the chosen extension execution layer.
2. Add extension flag passthrough in Zig CLI.
3. Expose extension/package commands with TS-compatible behavior.
4. Close the registration gap for tools, commands, flags, and providers through
   the Bun compatibility boundary.

## Phase 4: User-Visible Product Parity

1. Decide and document `/share` parity policy.
2. Implement gist/viewer flow if full parity is required.
3. Add EXIF-orientation, resize, and payload-limit handling for clipboard and
   file images.
4. Verify export HTML parity.

## Phase 5: Packaging and Release

1. Define packaged binary resource layout.
2. Define external tool strategy.
3. Add first-run smoke tests per target platform.

---

## Verification Strategy

The remaining parity work should be verified with narrow regression harnesses,
not broad aspirational checklists.

### Required Harnesses

- provider setup-failure stream-contract tests
- session cwd missing-path tests
- Bun-hosted extension smoke tests using real TS fixture extensions
- extension flag parsing and help-text tests
- package install/remove/update/list/config tests
- `/share` parity tests for whichever policy is chosen
- image-orientation and resize fixture tests
- export HTML fixture comparisons

### Existing Assets To Build On

- `zig/test/ts-rpc-parity.sh`
- `zig/test/openai-chat-parity.sh`
- `zig/test/openai-responses-parity.sh`
- `zig/test/bedrock-parity.sh`

---

## Summary Table

| Area | Current Status | Replacement Risk | Priority |
|---|---|---:|---:|
| Provider stream contract | Partial mismatch | High | Critical |
| Bun-hosted TS extension parity | Incomplete | High | Critical |
| Session cwd safety | Missing guard | High | High |
| Package/CLI extension surface | Incomplete | High | High |
| `/share` behavior | Different behavior | Medium | Medium-high |
| Clipboard image normalization | Incomplete | Medium | Medium-high |
| Export HTML parity | Needs verification | Medium | Medium |
| Auth/model UX parity | Partial | Medium | Medium |
| Release/binary parity | Needs product decisions | Medium | Medium |

---

## Final Position

The Zig rewrite is much further along than the previous review suggested.

The current blocker is not "build an interactive agent from scratch." The
current blocker is "close a short list of high-impact runtime and product gaps
while preserving the TS extension ecosystem through Bun."

That should remain the working strategy until the project explicitly decides
otherwise.
