# OpenAI Codex WebSocket Transport

Status: implemented in `zig/src/ai/providers/openai_codex_responses.zig`.

The `openai-codex-responses` provider supports four wire transports for the
Codex Responses stream. Pick one with the `transport` field on
`StreamOpenAICodexResponsesOptions`.

## Transports

- `.sse` — legacy server-sent events over HTTPS. The original transport;
  always available and the most compatible with intermediaries.
- `.websocket` — single-call WebSocket upgrade. Failures are terminal: any
  transport-class or protocol error surfaces as an `error_event` on the
  stream. Use when you want WebSocket framing without fallback.
- `.websocket_cached` — WebSocket with per-session connection caching.
  Reuses an idle socket across calls when the request body shape matches and
  the new `input` is a prefix-extension of the previous one. See
  [Cache semantics](#cache-semantics) below.
- `.auto` (default) — try `.websocket_cached` first and fall back to `.sse`
  per session on transport-class errors. See
  [Fallback semantics](#fallback-semantics) below.

## Fallback semantics

`.auto` falls back from WebSocket to SSE on, and only on, transport-class
errors — connection refused, TLS handshake failures, abrupt socket close
before any protocol message, upgrade-request rejected, etc. Application and
protocol errors continue to surface as a normal `error_event` and do not
trigger fallback:

- `response.failed` payloads from the server
- explicit `error` envelopes inside the stream
- protocol-level WebSocket close frames carrying an application status

A failed WebSocket attempt is recorded per session id. Subsequent `.auto`
calls for the same session skip the WebSocket upgrade entirely and go
straight to SSE, so a transient WebSocket failure does not cost an extra
round-trip on every follow-up turn.

When fallback engages, a `provider_transport_failure` diagnostic envelope is
appended to the assistant message so callers can attribute the degraded
transport in logs and UI.

## Cache semantics

`.websocket_cached` (and the WebSocket leg of `.auto`) reuses an existing
idle socket when all of the following are true:

- the request targets the same `(base_url, model, session_id)` as the cached
  socket;
- the request body has the same shape (same auxiliary fields, same tool set,
  same instructions) as the prior body recorded with the cache entry;
- the new `input` array is a strict prefix-extension of the prior `input`
  array — the head matches element-for-element and only the tail is new.

When all three hold, the wire payload is rewritten to
`{ ...body, previous_response_id, input: delta }` where `delta` is the
prefix-extension tail and `previous_response_id` is the id returned by the
prior turn. The server side of Codex Responses then resumes from
`previous_response_id` rather than replaying the full conversation.

Cache entries have a 5-minute idle TTL. An entry is evicted when:

- the TTL elapses with no use;
- the next request body fails the shape/prefix check (a new socket is opened
  for that turn and replaces the entry);
- the cached socket reports a transport-class error;
- the application explicitly clears the cache (see
  [Cleanup](#cleanup) below).

## Cleanup

```zig
// Drop cached sockets for a single session, e.g. when ending a chat:
openai_codex_responses.closeOpenAICodexWebSocketSessions(session_id, io);

// Drop every cached socket for every session, e.g. at process shutdown:
openai_codex_responses.closeOpenAICodexWebSocketSessions(null, io);
```

The function is safe to call when no entries exist and is the only supported
way to tear down cached connections from outside the provider.

## Diagnostics

The `provider_transport_failure` diagnostic appended by `.auto` fallback has
`type = "provider_transport_failure"` and carries the originating error
class, the attempted transport, and a brief human-readable message. Surface
it in your UI when you want users to see that a WebSocket attempt failed and
the session continued over SSE.

## Defaults and recommendations

- New callers should leave `transport` unset; the default `.auto` is the
  intended path.
- Use `.websocket_cached` explicitly when you have your own fallback strategy
  and want failures to surface immediately rather than retry on SSE.
- Use `.sse` to opt out of WebSocket entirely (e.g. in environments where
  intermediaries strip the upgrade).
- Use `.websocket` only for tests or diagnostics where you want WebSocket
  framing without either cache reuse or fallback.
