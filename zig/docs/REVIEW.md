# Zig AI Module - TypeScript Parity Review

## Executive Summary

The Zig AI implementation has a **solid foundation** with most major providers and streaming infrastructure in place, but it is **not yet feature-parity complete** with the TypeScript version. This is a **partial parity port** rather than a full equivalent implementation.

**Recommended approach**: Treat this as a **parity-hardening pass (L: 1–2 days)**, starting with contract mismatches and highest-value provider gaps.

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
| **Total**: | ~60% | | ~2-3d |

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
