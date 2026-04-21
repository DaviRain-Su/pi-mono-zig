# Task Breakdown - Zig Native Implementation

## Completed Tasks

### Phase 1: Foundation
- [x] Create `zig/` directory structure
- [x] Set up `build.zig` with test runner
- [x] Implement core types (`types.zig`)
- [x] Implement API registry (`api_registry.zig`)
- [x] Implement JSON parser (`json_parse.zig`)
- [x] Implement HTTP client (`http_client.zig`)
- [x] Implement EventStream (`event_stream.zig`)

### Phase 2: Provider Infrastructure
- [x] Create OpenAI provider stub
- [x] Implement request payload builder
- [x] Implement SSE line parser
- [x] Implement chunk parser

### Phase 3: Documentation
- [x] Create PRD (`01-prd.md`)
- [x] Create Architecture Design (`02-architecture.md`)
- [x] Create Technical Spec (`03-technical-spec.md`)

## Pending Tasks

### Phase 4: OpenAI Streaming (Current)
- [ ] Implement HTTP request with streaming
- [ ] Connect HTTP response to EventStream
- [ ] Parse SSE chunks into events
- [ ] Handle text_delta events
- [ ] Handle thinking_delta events
- [ ] Handle toolcall events
- [ ] Handle done/error events
- [ ] **Estimated**: 4-6 hours

### Phase 5: Testing & Comparison
- [ ] Create comparison test script (TS vs Zig)
- [ ] Record TS output for sample prompts
- [ ] Verify Zig output matches TS
- [ ] Add property tests for JSON parser
- [ ] **Estimated**: 2-3 hours

### Phase 6: CLI Entry
- [ ] Parse command line arguments
- [ ] Load configuration file
- [ ] Read environment variables
- [ ] Select provider and model
- [ ] Stream output to stdout
- [ ] **Estimated**: 3-4 hours

### Phase 7: Additional Providers
- [ ] Anthropic provider stub
- [ ] Google provider stub
- [ ] Azure OpenAI provider stub
- [ ] **Estimated**: 2-3 hours per provider

### Phase 8: Polish
- [ ] Error handling and user messages
- [ ] Logging framework
- [ ] Signal handling (Ctrl+C)
- [ ] Configuration validation
- [ ] **Estimated**: 2-3 hours

## Task Dependencies

```
Foundation (Done)
    ↓
Provider Infrastructure (Done)
    ↓
OpenAI Streaming (Current) → Testing & Comparison
    ↓
CLI Entry
    ↓
Additional Providers (parallel)
    ↓
Polish
```

## Time Estimates

| Phase | Estimated | Actual | Remaining |
|-------|-----------|--------|-----------|
| Foundation | 4h | 4h | 0h |
| Provider Infra | 3h | 3h | 0h |
| Documentation | 2h | 2h | 0h |
| OpenAI Streaming | 5h | 0h | 5h |
| Testing | 3h | 0h | 3h |
| CLI Entry | 4h | 0h | 4h |
| Additional Providers | 6h | 0h | 6h |
| Polish | 3h | 0h | 3h |
| **Total** | **30h** | **9h** | **21h** |

## Next Task

**OpenAI Streaming Implementation**

Priority: P0
Estimated: 4-6 hours
Blocked by: None

Steps:
1. Implement `stream()` function in OpenAI provider
2. Build HTTP request with proper headers
3. Parse SSE response line by line
4. Convert JSON chunks to AssistantMessageEvent
5. Push events to EventStream
6. Handle completion and errors
