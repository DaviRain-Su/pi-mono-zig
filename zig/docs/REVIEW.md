# Zig AI Module - TypeScript Parity Review

## Executive Summary

The Zig AI implementation has a **solid foundation** with most major providers and streaming infrastructure in place, but it is **not yet feature-parity complete** with the TypeScript version. This is a **partial parity port** rather than a full equivalent implementation.

**Recommended approach**: Split the work into two tracks:

- **AI/provider parity hardening**: 1-2 days for the highest-risk contract and provider gaps.
- **Full coding-agent replacement parity**: larger product/runtime work covering extensions, package management, session lifecycle, sharing/export, auth UX, release packaging, and cross-platform tests.

---

## Critical Issues (Must Fix)

### 1. Stream Error Handling Contract Violation ⚠️ CRITICAL

**Problem**: The TypeScript contract specifies that `StreamFunction` must **always return a stream and encode all failures inside it**, never throwing after invocation. Zig providers violate this.

**Current State (Zig)**:
```zig
// openai.zig - setup happens BEFORE returning stream
pub fn stream(...) !Stream {
    const payload = try buildPayload(...);      // Can throw here
    const headers = try buildHeaders(...);      // Can throw here
    const request = try buildRequest(...);      // Can throw here
    return createStream(...);                    // Only NOW returns
}
```

**Expected State (TS)**:
```typescript
const stream = newStream();
try {
  // All work inside stream
  emitDelta(...);
} catch(e) {
  stream.emitError(...);
}
return stream;
```

**Impact**: Zig callers receive hard errors; TS callers get terminal error events. Incompatible error semantics.

**Affected Files**:
- `zig/src/ai/providers/openai.zig`
- `zig/src/ai/providers/anthropic.zig`
- `zig/src/ai/providers/bedrock.zig`
- All provider implementations

**Fix Priority**: 🔴 **Must fix first** - affects all callers

---

### 2. AssistantMessage Model Mismatch ⚠️ CRITICAL

**Problem**: Zig's message model semantically diverges from TypeScript, breaking generic message consumers.

**TypeScript Model**:
```typescript
interface AssistantMessage {
  content: (TextContent | ToolCall | ThinkingContent | ImageContent)[]
  usage?: Usage
}

interface TextContent {
  type: 'text'
  text: string
  textSignature?: string    // ← Signature tracking
}

interface ToolCall {
  type: 'tool_call'
  id: string
  name: string
  input: any
  thoughtSignature?: string // ← Can be nested
}
```

**Zig Model** (Current):
```zig
pub const AssistantMessage = struct {
    content: []const MessageContent,  // Only: text | image | thinking
    tool_calls: []const ToolCall,     // ← Separated! Not in content
    usage: ?Usage = null,
};

// Missing entirely:
// - TextContent.textSignature
// - ToolCall.thoughtSignature
```

**Consequences**:
- Consumers iterating only `content` don't see tool calls
- Signature information lost entirely
- Cannot reconstruct original message ordering
- **This is the single biggest semantic mismatch**

**Affected Files**:
- `zig/src/ai/types.zig` (line: message model definitions)
- `packages/ai/src/types.ts` (reference implementation)

**Fix Priority**: 🔴 **Must fix before any provider completes**

---

### 3. JSON Parsing Robustness Gap

**Problem**: Zig's partial JSON recovery is weaker than TypeScript's multi-strategy approach.

**Zig Strategy** (current):
```zig
fn parseJson(...) ?JsonValue {
    // 1. Try parse whole string
    if (parse(input)) return result;
    // 2. Try longest valid prefix
    if (parseLongestPrefix(input)) return result;
    // 3. Give up → {}
    return EmptyObject;
}
```

**TypeScript Strategy**:
```typescript
// Multiple fallback layers
repairJson(json)
  → parseJsonWithRepair(json)
  → partialJson(json)
  → WASM implementation
  → empty object
```

**Impact**: During streaming, Zig more likely to lose partial tool-call args, invalid escape sequences, raw control characters.

**Affected Files**:
- `zig/src/ai/json_parse.zig`
- `packages/ai/src/utils/json-parse.ts` (reference)

**Fix Priority**: 🟡 **High** - affects tool use reliability

---

## Provider-Level Gaps

### OpenAI / OpenAI-Compatible

**Missing Options/Compat Fields**:

| Feature | TS Support | Zig Status |
|---------|-----------|-----------|
| `toolChoice` | ✅ Supported | ❌ Missing |
| `reasoningEffort` | ✅ Full enum | ❌ Missing |
| `supportsStore` | ✅ Routing | ❌ Not implemented |
| `supportsDeveloperRole` | ✅ Tracked | ❌ Not tracked |
| `supportsReasoningEffort` | ✅ Compat flag | ❌ Hardcoded |
| `reasoningEffortMap` | ✅ Dynamic | ❌ Static |
| `supportsUsageInStreaming` | ✅ Per-provider | ❌ Assumed |
| `maxTokensField` | ✅ Configurable | ❌ Hardcoded `max_tokens` |
| `requiresToolResultName` | ✅ Tracked | ❌ Assumed true |
| `supportsStrictMode` | ✅ Tracked | ❌ Hardcoded `false` |
| `cacheControlFormat` | ✅ Per-provider | ❌ Single format |
| OpenRouter routing | ✅ Special headers | ❌ Missing |
| Vercel gateway routing | ✅ Special headers | ❌ Missing |
| Long cache retention | ✅ Supported | ❌ Not implemented |

**Affected Files**:
- `zig/src/ai/providers/openai.zig`
- `packages/ai/src/providers/openai.ts` (reference: 500+ lines of compat logic)

**Fix Priority**: 🔴 **Critical** - OpenAI is primary model family

---

### GitHub Copilot (OpenAI-Responses)

**Missing Behavior**: Dynamic header injection

TS Implementation:
```typescript
// packages/ai/src/providers/github-copilot-headers.ts
const headers = {
  'X-Initiator': context.userId,
  'Openai-Intent': 'personal-copilot',
  'Copilot-Vision-Request': isVisionModel ? 'true' : 'false',
};
```

**Zig Status**: ❌ Not found in `openai_responses.zig`

**Impact**: Zig's Copilot routing appears hardcoded; dynamic context headers missing entirely.

**Fix Priority**: 🔴 **High** - affects all Copilot calls

---

### Bedrock (AWS)

**Missing Options**:

| Feature | TS Support | Zig Status |
|---------|-----------|-----------|
| `toolChoice: 'none'` | ✅ Supported | ❌ Only `auto`/`any` |
| `toolChoice: specific_tool` | ✅ Supported | ❌ Missing |
| Per-request `region` | ✅ Override | ❌ Env only |
| Per-request `profile` | ✅ Override | ❌ Not supported |
| Bearer token auth | ✅ Alternate path | ❌ AWS creds only |
| `reasoning` / `thinkingBudgets` | ✅ Full support | ❌ Missing |
| `streamSimpleBedrock` | ✅ Special mapping | ❌ Delegates to `stream` |

**Affected Files**:
- `zig/src/ai/providers/bedrock.zig` (toolChoice, auth paths)
- `packages/ai/src/providers/amazon-bedrock.ts` (reference)

**Fix Priority**: 🔴 **High** - Bedrock is production-critical

---

### Azure OpenAI

**Missing**: Per-request override options

TS supports:
```typescript
options?: {
  azureApiVersion?: string
  azureResourceName?: string
  azureBaseUrl?: string
  azureDeploymentName?: string
}
```

Zig resolves from env/model only. No request-scoped override surface.

**Affected Files**:
- `zig/src/ai/providers/azure_openai_responses.zig`
- `packages/ai/src/providers/azure-openai-responses.ts` (reference)

**Fix Priority**: 🟡 **Medium** - less common than OpenAI

---

### OpenAI Codex

**Missing Features**:

| Feature | TS Support | Zig Status |
|---------|-----------|-----------|
| `textVerbosity` | ✅ 'low'/'medium'/'high' | ❌ Hardcoded 'medium' |
| `websocket` transport | ✅ Auto/SSE/WebSocket | ❌ No WebSocket |
| `sse` transport | ✅ Auto/SSE/WebSocket | ⚠️ Default only |

**Affected Files**:
- `zig/src/ai/providers/openai_codex_responses.zig`
- `packages/ai/src/providers/openai-codex-responses.ts` (reference)

**Fix Priority**: 🟡 **Low** - Codex is legacy

---

### Google Gemini CLI

**Current Implementation Issues**:

**TS Approach**:
```typescript
const projectId = options.projectId || extractFromEnv()
const token = options.token || extractFromEnv()
const retryDelay = extractRetryDelay(response)
```

**Zig Approach** (Current):
```zig
// Expects api_key = JSON string: { "token": "...", "projectId": "..." }
const api_key = try parseApiKeyJson(...);
// No equivalent to extractRetryDelay
// No projectId option equivalent
```

**Gap**: Zig's API surface is a functional subset; no independent `projectId` option.

**Affected Files**:
- `zig/src/ai/providers/google_gemini_cli.zig`
- `packages/ai/src/providers/google-gemini-cli.ts` (reference)

**Fix Priority**: 🟡 **Medium** - less common

---

### Google Vertex

**Missing**: Request-scoped project/location overrides

TS supports:
```typescript
options?: {
  project?: string
  location?: string
}
```

Zig resolves from auth/env; passes `null` in helpers.

**Fix Priority**: 🟡 **Low** - usually env-configured

---

### Mistral

**Missing**: `toolChoice` option

TS has: `toolChoice`, `promptMode`, `reasoningEffort`  
Zig has: `prompt_mode`, `reasoning_effort`  
Zig missing: explicit `toolChoice` handling

**Fix Priority**: 🟡 **Low-Medium** - tool use is less critical for Mistral

---

## API Surface Gaps

### Missing Exports (vs TS `index.ts`)

**Utilities**:
- ❌ `overflow` function (module exists in `shared/overflow.zig` but not re-exported)
- ❌ `getModel(name)` helper
- ❌ `getProviders()` list
- ❌ `getModels()` list
- ❌ `calculateCost(usage)` helper
- ❌ `modelsAreEqual(a, b)` helper
- ❌ Model metadata/stats queries

**Types/Schemas**:
- ⚠️ Provider option types not exposed as public API (TypeBox in TS)
- ❌ OAuth module types (`OAuthConfig`, etc.)
- ❌ Validation helpers

**Affected Files**:
- `zig/src/ai/root.zig`
- `packages/ai/src/index.ts` (reference)

**Note**: TS exports `Type`, `Static`, `TSchema` from TypeBox; Zig won't mirror this 1:1—mark as **intentional non-parity**.

**Fix Priority**: 🟡 **Medium** - nice-to-have utilities

---

## Strengths (What Zig Does Well)

✅ **Model Registry**: Discovery/matching logic is richer than TS  
✅ **Extra Providers**: Includes `kimi.zig` (Kimi model)  
✅ **Testing**: `faux.zig` provider for mocking  
✅ **Streaming Infrastructure**: Event/stream handling is solid  
✅ **Type Safety**: Zig's struct definitions are explicit and verifiable  

---

## Extension Runtime and Full TS Replacement Route

Provider parity is not enough to fully replace the TypeScript implementation. The larger missing surface is the **extension ecosystem**: extension loading, commands, tools, provider registration, OAuth hooks, custom UI, package management, and hot reload.

### Current Gap

Zig currently has resource discovery for extensions, skills, prompts, and themes, and TS-RPC has extension UI request/response wire coverage. That is not the same as executing TS extensions.

Missing or incomplete:

- Extension loader and runtime model
- Extension lifecycle events
- Extension-registered tools, commands, providers, OAuth flows, and hooks
- Extension CLI flags and extension-driven help
- Package-management commands: `install`, `remove`, `uninstall`, `update`, `list`, `config`
- Custom UI injection: widgets, editor components, footer/header, terminal input hooks
- MCP integration through the extension channel

### Decision: Support Existing TS Extensions

If the goal is to replace TS while preserving the existing extension ecosystem, Zig needs a JavaScript runtime boundary. The pragmatic path is:

- Use **Bun as a child process** first.
- Do not embed Bun initially; Bun's C embedding surface is still not the right first integration point.
- Treat Bun upgrades as compatibility upgrades.
- Keep Zig as the host for tools, TUI, sessions, RPC, auth, and provider orchestration.

### Phase 1: Bun Extension Host

Run a single Bun child process that loads all TS extensions:

```text
Zig host process
  └─ spawn ─→ Bun child process (extension-host.ts)
                 ├─ load installed extensions
                 ├─ maintain extension lifecycle
                 └─ communicate with Zig over stdio
```

Protocol recommendation:

- JSON-RPC over stdio
- LSP-style framing:

```text
Content-Length: <bytes>\r\n
\r\n
<json payload>
```

Core method groups:

- Zig → Bun: `host/initialize`, `host/shutdown`, `extensions/load`, `extensions/unload`, `extensions/reload`, `extensions/list`, `tool/invoke`, `command/run`, `provider/complete`, `ui/event`
- Bun → Zig: `register/tool`, `register/command`, `register/provider`, `register/oauth`, `register/ui`, `session/append`, `session/query`, `agent/emit`, `host/log`, `host/fs`, `host/shell`, `ui/request`

Streaming should use `{ stream_id }` plus `stream/chunk`, `stream/end`, and `stream/cancel` notifications.

### Extension Manifest

Use an explicit manifest so permissions and capabilities are visible before activation:

```jsonc
{
  "id": "my-extension",
  "version": "1.0.0",
  "type": "node",
  "entry": "./dist/index.js",
  "engines": { "pi-agent": "^1.0" },
  "capabilities": {
    "tools": [],
    "commands": [],
    "providers": [],
    "ui": []
  },
  "permissions": {
    "fs": { "read": ["${workspace}"], "write": [] },
    "net": { "domains": ["api.example.com"] },
    "shell": false
  }
}
```

Suggested install layout:

```text
~/.pi/
  bun/bun-1.1.x/
  extensions/<ext-id>@<version>/
  extension-host/host.ts
  config.json
```

Package management can start simple:

```text
pi install <pkg> ~= cd ~/.pi/extensions/<id> && bun install <pkg>
```

### Permissions

Default-deny is the right model. Permissions should be merged from:

- Extension manifest
- User/project config
- Runtime approval prompts

Interception points:

- FS through `host/fs`
- Shell through `host/shell`
- Network through Bun allow-listing where feasible, or through host-mediated APIs for sensitive cases

### Hot Reload

The child-process boundary gives Zig better reload semantics than the TS monolith.

Single extension reload:

```text
Zig → extensions/unload { id }
        ↓
Bun host:
  1. call onDeactivate()
  2. remove that extension's tools, commands, providers, UI registrations
  3. clear import/require cache
        ↓
Zig → extensions/load { id }
        ↓
Bun host:
  1. re-import entrypoint
  2. call onActivate()
  3. re-register capabilities
```

Full reload:

- Iterate `extensions/list`
- Unload and reload all enabled extensions
- Trigger after settings or package changes

Hard reload:

```text
Zig:
  1. mark current Bun process as draining
  2. wait for in-flight RPC to complete, with timeout
  3. terminate old process
  4. spawn new Bun process
  5. run host/initialize and reload extension set
  6. swap Zig client handle
```

This supports:

- Recovery from Bun crashes
- Clearing leaked JS state
- Switching bundled Bun versions
- `/reload-extensions --hard`

### Phase 2: Native High-Value Extensions

Once usage data exists, rewrite the most-used extensions as native Zig capabilities:

- Keep names and behavior compatible.
- Prefer built-ins for hot paths.
- Leave long-tail TS extensions on the Bun bridge.

This phase should be data-driven rather than speculative.

### Phase 3: Native Dynamic Extensions

If native extensions become important, use a dynamic loading story:

| Mechanism | Fit |
|---|---|
| `.so` / `.dylib` with stable C ABI | Fast, but ABI evolution is costly |
| Wasm | Best portability and sandboxing tradeoff |
| Compile-time registration | Simple, but poor user experience |

Recommended default: **Wasm**.

### Expected Effort

| Task | Estimate |
|---|---:|
| JSON-RPC framing, streaming, cancellation | 1 week |
| Bun child-process lifecycle and hard reload | 1.5-2 weeks |
| Zig host bindings and method routing | 2 weeks |
| `extension-host.ts` and SDK contract | 2 weeks |
| Permission model | 1 week |
| Package-management CLI | 1 week |
| Manifest and install layout | 0.5 week |
| TS extension API parity | 2-3 weeks |
| Real extension integration | 2-3 weeks |
| Tests and regression harness | 1 week |
| **Total** | **13-16.5 weeks** |

### Extension Route Summary

The implementation can become independently useful without this work, but it cannot fully replace TS until the extension runtime is solved. Provider parity is a short hardening pass; ecosystem parity is the long pole.

---

## Additional Coding-Agent Gaps Not Covered Above

The sections above focus on AI provider parity and extension execution. A full TS replacement also needs the outer coding-agent product surface. These gaps are lower than core stream/message correctness, but they are user-visible and should be tracked explicitly.

### CLI, Package, and Tool Bootstrap

TypeScript has a package-management path through `package-manager-cli.ts` and `DefaultPackageManager`:

- `install`, `remove` / `uninstall`, `update`, `list`, and `config`
- package path resolution for built-in resources and installed packages
- migration-aware resource loading
- extension/package config selection UI

Zig currently has resource discovery and config loading, but the package-management command surface is not equivalent. This matters because extension parity depends on a stable install/update story.

Tool bootstrap is also not equivalent:

- TS uses `utils/tools-manager.ts` to provision tools such as `rg` and `fd` when needed.
- Zig build/runtime currently assumes external tools are already present or validates them at build time.
- A release binary should either bundle required tools, auto-install them, or gracefully degrade with exact remediation.

Version/update UX is another missing layer:

- TS runs startup version checks and records install-version state.
- Zig currently exposes static version metadata.
- A native replacement needs either the same update prompts or an explicit decision to omit them.

### Interactive UX and Session Sharing

The Zig TUI covers many core flows, but several high-traffic TS interactive features are not yet equivalent:

- `/share` in TS creates a secret GitHub gist and viewer URL; Zig currently copies a markdown transcript.
- TS export HTML includes viewer templates, sidebar behavior, share anchors, and custom tool renderers; Zig export/share parity needs visual and attachment-level checks.
- TS clipboard image paste goes through native clipboard bindings plus format conversion, EXIF orientation handling, and image resizing. Zig has clipboard image plumbing, but full format/orientation/resize parity should be verified.
- TS footer/header/status surfaces include OAuth subscription state, telemetry/update hints, extension status, and richer command hints.
- TS interactive mode has more extension-driven UI surfaces than the wire protocol alone: widgets above/below editor, custom editor components, custom footers/headers, terminal input hooks, shortcut registration, and custom renderers.

### Session Runtime and Lifecycle

TS centralizes behavior in `AgentSession`, `AgentSessionRuntime`, and session services. Zig has session manager/runtime pieces, but a parity review should still cover lifecycle semantics:

- new session, fork, switch, reload, and reconnect behavior
- missing-session-cwd prompts and cross-project session handling
- session cwd validation before tool execution
- event subscription/replay behavior across interactive, print, and RPC modes
- output guard behavior for stdout ownership in print/RPC modes
- diagnostics, timings, and structured runtime telemetry

This is important because many parity bugs will not show up in provider unit tests; they appear when switching sessions, resuming old sessions, or running RPC and TUI modes against the same persisted data.

### Auth and Model Registry UX

Provider code is only one part of auth parity. TS also has a dynamic model registry and auth storage behavior that extension providers can modify:

- extension-registered OAuth providers for `/login`
- OAuth token refresh with storage locking
- model modification after OAuth credentials are available
- API-key login provider display names
- auth guidance and env-var help text

Known areas to verify or implement in Zig:

- OpenAI Codex subscription/OAuth account flow, not just API payload compatibility
- Google Antigravity OAuth/provider registration
- Cloudflare Workers AI env vars and account-id guidance
- `auth.json` compatibility and migrations
- dynamic provider registration from extensions

### Model Catalog Freshness

TS has a generated model catalog and provider-specific model generation scripts. Zig has a curated/static provider list plus runtime discovery in some places.

Open questions:

- Which model list is authoritative for Zig releases?
- Should Zig consume TS-generated metadata, generate its own, or rely on provider discovery?
- How are deprecations, aliases, default models, context windows, image limits, and tool support kept fresh?

Without this strategy, Zig can pass API smoke tests but drift quickly in model selection UX.

### Protocol and SDK Surface

TS exposes typed RPC/client surfaces and uses RPC in multiple modes. Zig has `rpc_mode` and `ts_rpc_mode`, but the parity checklist should include:

- exhaustive command matrix for every TS RPC command
- `get_commands` returning extension, prompt, and skill commands rather than only static built-ins
- client-side SDK/type equivalent, or an explicit decision that Zig is server-only
- golden fixtures for unknown command errors, cancellation, and stream interleaving

### Security and Sandbox Semantics

The extension host proposal introduces a permission model, but TS parity also includes runtime decisions around shell, filesystem, hooks, and user-bash interception.

Track these as separate requirements:

- default-deny extension permissions
- project/user-level permission overrides
- host-mediated shell and filesystem access
- audit/logging for extension actions
- safe cancellation and timeout behavior for extension calls
- sandbox environment restoration for packaged/binary execution

### Binary, Release, and Platform Parity

TS has Bun binary-specific support, bundled export assets, optional native clipboard bindings, and platform-specific fallback paths. Zig should explicitly cover:

- release artifact layout and bundled resources
- macOS/Linux clipboard support parity
- external tool availability in packaged builds
- config/resource path resolution for installed binaries
- update/release channel story
- cross-platform smoke tests for first-run, login, tool use, export, and share

### Testing Gaps

Current Zig tests cover substantial core behavior, including TS-RPC scenarios, but the uncovered parity areas need their own harnesses:

- real extension smoke test through the Bun host
- package install/update/list/remove lifecycle test
- `/share` gist or intentional markdown-only non-parity test
- clipboard image fixtures for PNG/JPEG/WebP, EXIF orientation, and resize limits
- export HTML visual fixture comparison
- session fork/switch/reload/reconnect regression tests
- full RPC command matrix against TS fixtures
- packaged binary first-run smoke tests on each target platform

---

## Recommended Fix Order

### Phase 1: Core Contracts (Day 1 AM)
1. [ ] Fix stream error handling: catch all setup errors, emit as stream events
2. [ ] Restructure `AssistantMessage` to match TS model (add signatures)
3. [ ] Upgrade JSON parsing (add repair strategies)

### Phase 2: Critical Providers (Day 1 PM)
1. [ ] OpenAI: Add `toolChoice`, `reasoningEffort`, `supportsStore`, strict mode support
2. [ ] GitHub Copilot: Implement dynamic header injection
3. [ ] Bedrock: Add `toolChoice: none/specific`, region/profile overrides
4. [ ] Azure: Add request-scoped override options

### Phase 3: Secondary Providers (Day 2)
1. [ ] OpenAI Codex: Add `textVerbosity`, WebSocket transport option
2. [ ] Google Gemini CLI: Support independent `projectId` option
3. [ ] Mistral: Add `toolChoice` handling

### Phase 4: Polish (Day 2 PM)
1. [ ] Add missing utility exports
2. [ ] Document intentional non-parity areas
3. [ ] Add parity test fixtures

### Phase 5: Product Runtime Parity (Multi-week)
1. [ ] Decide whether package management and extension installation are in Zig scope
2. [ ] Implement or explicitly defer `/share` gist/viewer URL parity
3. [ ] Verify clipboard image conversion, EXIF orientation, and resize parity
4. [ ] Add session lifecycle parity tests for new/fork/switch/reload/reconnect
5. [ ] Define model catalog generation/freshness strategy
6. [ ] Define native release layout, bundled resources, external tool strategy, and update UX
7. [ ] Add packaged binary first-run smoke tests per target platform

---

## Verification Strategy

### Golden Test Approach

Create a **cross-language parity harness**:

**Fixture Format**:
```json
{
  "model": "gpt-4",
  "context": ["<system>", "<user message>"],
  "options": { "temperature": 0.7, "toolChoice": "auto" }
}
```

**Test Process**:
1. TS emits: request payload + event stream
2. Zig emits: request payload + event stream  
3. Compare normalized outputs
4. Assert request JSON matches (with field ordering tolerance)
5. Assert event stream structure matches

**Golden Fixtures Location**: `zig/tests/fixtures/parity/`

**CI Integration**: Add to main test suite; run before release.

---

## Risks & Guardrails

### Risks
- 🔴 **Silent behavioral drift**: Split message model breaks generic consumers
- 🔴 **Provider regressions**: Adding options without golden tests → production bugs
- 🟡 **False parity confidence**: Provider exists but behavior is incomplete
- 🟡 **Edge case failures**: Copilot, Bedrock, Cloudflare likely to fail first

### Guardrails
- [ ] Add payload golden tests per provider
- [ ] Add stream golden tests (text, thinking, tool calls, errors)
- [ ] Maintain parity checklist per provider (not just "ported"/"not ported")
- [ ] Document known non-parity as intentional decisions
- [ ] Run cross-language fixture tests in CI

---

## Summary Table: Parity Status

| Area | Status | Priority | Effort |
|------|--------|----------|--------|
| Stream error contract | 🔴 Broken | CRITICAL | M |
| AssistantMessage model | 🔴 Diverged | CRITICAL | L |
| JSON parsing | 🟡 Weak | HIGH | S |
| OpenAI compat | 🟡 Partial | CRITICAL | M |
| GitHub Copilot headers | ❌ Missing | HIGH | S |
| Bedrock options | 🟡 Partial | HIGH | M |
| Azure overrides | ❌ Missing | MEDIUM | S |
| Codex features | 🟡 Partial | LOW | S |
| Gemini CLI | 🟡 Partial | MEDIUM | S |
| Mistral toolChoice | ❌ Missing | LOW-MED | S |
| API exports | ❌ Partial | MEDIUM | S |
| Extension runtime | ❌ Missing | CRITICAL for TS replacement | XL |
| Package management | ❌ Missing/partial | HIGH | L |
| Tool bootstrap | 🟡 Partial | HIGH | M |
| `/share` gist flow | ❌ Different behavior | MEDIUM | M |
| Export HTML parity | 🟡 Needs verification | MEDIUM | M |
| Clipboard image processing | 🟡 Needs verification | MEDIUM | M |
| Session lifecycle parity | 🟡 Needs verification | HIGH | L |
| Auth/model registry UX | 🟡 Partial | HIGH | L |
| Model catalog freshness | 🟡 Unclear | MEDIUM | M |
| Binary/release/platform parity | 🟡 Unclear | HIGH | L |
| **AI/provider subtotal** | ~60% | | ~2-3d |
| **Full coding-agent replacement subtotal** | materially lower | | multi-week |

---

## Next Steps

1. **Consensus check**: Agree on whether full parity is the goal or intentional subset
2. **Phase 1 spike**: Tackle stream contracts + message model (most blocking)
3. **Provider prioritization**: Which providers are production-critical for your use case?
4. **Testing framework**: Set up golden fixture harness before adding features

---

**Last Updated**: 2024  
**Reviewer**: AI Code Review  
**Status**: Ready for discussion & prioritization
