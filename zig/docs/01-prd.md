# Zig Native Rewrite - Product Requirements Document

## 1. Overview

### 1.1 Project Name
pi-mono Zig Native Implementation

### 1.2 Goal
Create a native Zig executable that replicates the core functionality of the TypeScript `packages/ai` module, eventually replacing the Node.js runtime dependency for the AI assistant CLI.

### 1.3 Scope
- **In Scope**: Core AI streaming infrastructure, JSON parsing, HTTP client, event streaming, provider abstractions (starting with OpenAI)
- **Out of Scope**: Full TUI implementation, web-ui, agent orchestration (Phase 2), coding-agent logic

### 1.4 Target Platform
- macOS (ARM64/x64)
- Linux (x64/ARM64)
- Windows (x64) - Phase 2

## 2. Background

The existing `pi-mono` repository is a TypeScript monorepo running on Node.js. While functional, it has:
- Large binary sizes due to Node.js bundling
- Startup latency from JS interpretation
- Complex dependency tree
- Memory overhead from V8

A Zig native implementation provides:
- Single static binary (< 10MB)
- Near-instant startup
- Direct memory control
- Cross-compilation simplicity

## 3. Requirements

### 3.1 Functional Requirements

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| FR-1 | Parse streaming JSON with partial fallback | P0 | Done |
| FR-2 | HTTP client with SSE support | P0 | Done |
| FR-3 | Event stream for async message delivery | P0 | Done |
| FR-4 | OpenAI provider (chat completions) | P0 | In Progress |
| FR-5 | Provider registry for multiple APIs | P1 | Done |
| FR-6 | Model/type definitions matching TS | P0 | Done |
| FR-7 | CLI argument parsing | P1 | Pending |
| FR-8 | Configuration file support | P2 | Pending |
| FR-9 | Environment variable integration | P2 | Pending |

### 3.2 Non-Functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| NFR-1 | Binary size | < 10MB (stripped) |
| NFR-2 | Startup time | < 50ms |
| NFR-3 | Memory usage | < 50MB baseline |
| NFR-4 | Test coverage | > 80% |
| NFR-5 | Zig version | 0.16.0 |

## 4. User Stories

### 4.1 As a developer
- I want to run `zig build` and get a working binary
- I want to run `zig build test` and see all tests pass
- I want to compare TS and Zig output side-by-side

### 4.2 As an end user
- I want a single binary I can download and run
- I want sub-100ms response times for simple queries
- I want the same API compatibility as the TS version

## 5. Constraints

- Must coexist with TypeScript implementation (gradual replacement)
- Must pass same test cases as TypeScript version
- Must use Zig 0.16.0 APIs (not 0.15.x)
- No external C dependencies (pure Zig where possible)

## 6. Success Criteria

- [ ] All core types compile and pass tests
- [ ] OpenAI provider can stream a real response
- [ ] Output matches TypeScript implementation for same input
- [ ] Binary size < 10MB
- [ ] 100% of unit tests pass

## 7. Risks

| Risk | Mitigation |
|------|-----------|
| Zig 0.16 API instability | Pin to exact version, use skill reference |
| HTTP client complexity | Start with std.http, migrate to libcurl if needed |
| SSE parsing edge cases | Extensive test coverage with real API responses |
| Async/await differences | Use explicit state machines instead of async |
