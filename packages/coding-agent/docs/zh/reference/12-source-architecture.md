# 第12章：源码架构

> 五层架构详解、数据流、事件系统

---

## 12.1 架构总览

### 五层架构

```
┌─────────────────────────────────────────┐
│  Layer 5: Host Layer (宿主层)            │
│  - packages/tui (终端 UI)               │
│  - packages/web-ui (Web UI)             │
├─────────────────────────────────────────┤
│  Layer 4: Application Layer (应用层)     │
│  - packages/coding-agent                │
│  - AgentSession, ExtensionRunner        │
│  - SessionManager, ModelRegistry        │
├─────────────────────────────────────────┤
│  Layer 3: Agent Core (Agent 核心)        │
│  - packages/agent                       │
│  - Agent, AgentLoop                     │
│  - AgentTool, AgentState                │
├─────────────────────────────────────────┤
│  Layer 2: AI Abstraction (AI 抽象层)     │
│  - packages/ai                          │
│  - stream, api-registry                 │
│  - Provider implementations             │
├─────────────────────────────────────────┤
│  Layer 1: Infrastructure (基础设施)      │
│  - Node.js, TypeScript                  │
│  - File system, Network                 │
└─────────────────────────────────────────┘
```

### 核心文件位置

| 组件 | 文件路径 |
|-----|---------|
| AgentSession | `packages/coding-agent/src/core/agent-session.ts` |
| Agent | `packages/agent/src/agent.ts` |
| AgentLoop | `packages/agent/src/agent-loop.ts` |
| ExtensionRunner | `packages/coding-agent/src/core/extensions/runner.ts` |
| ExtensionAPI | `packages/coding-agent/src/core/extensions/types.ts` |
| ModelRegistry | `packages/coding-agent/src/core/model-registry.ts` |
| SessionManager | `packages/coding-agent/src/core/session-manager.ts` |
| stream | `packages/ai/src/stream.ts` |
| api-registry | `packages/ai/src/api-registry.ts` |

---

## 12.2 数据流详解

### 完整数据流

```
User Input
    │
    ▼
┌─────────────────┐
│  Input Layer    │  TUI / Web / RPC / SDK
│  (Mode Adapter) │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  AgentSession   │────→│ ExtensionRunner │  Event interception
│  .prompt()      │     │  (before/after) │
└────────┬────────┘     └─────────────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  Agent          │────→│ SessionManager  │  Persistence
│  .prompt()      │     │  (appendEntry)  │
└────────┬────────┘     └─────────────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  AgentLoop      │────→│  Tool Execution │  Parallel/Sequential
│  runAgentLoop() │     │  (AgentTool)    │
└────────┬────────┘     └─────────────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  streamSimple() │────→│  API Provider   │  OpenAI/Anthropic/etc
│  (packages/ai)  │     │  (HTTP/WebSocket)
└─────────────────┘     └─────────────────┘
```

### 关键转换点

1. **AgentMessage → Message** (`convertToLlm`)
   - 过滤非 LLM 兼容消息
   - 转换附件格式
   - 处理自定义消息类型

2. **AssistantMessageEvent → AgentEvent**
   - `text_delta` → `message_update`
   - `toolcall_start` → `tool_execution_start`
   - `done/error` → `agent_end`

3. **ToolResult → AgentMessage**
   - 工具执行结果转为消息
   - 添加到上下文

---

## 12.3 事件系统

### 事件类型层次

```
AgentEvent (packages/agent)
├── agent_start / agent_end
├── turn_start / turn_end
├── message_start / message_update / message_end
└── tool_execution_start / tool_execution_update / tool_execution_end

AgentSessionEvent (extends AgentEvent)
├── auto_compaction_start / auto_compaction_end
└── auto_retry_start / auto_retry_end

ExtensionEvent
├── session_* (session lifecycle)
├── context (context injection)
├── before_provider_request (request interception)
├── tool_call / tool_result (tool interception)
└── input (input interception)
```

### 事件处理流程

```
Event emitted
    │
    ▼
┌─────────────────┐
│ ExtensionRunner │  Collect all handlers
│  .emit()        │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Execute handlers│  Sequential or Parallel
│  (async)        │  based on event type
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Aggregate       │  Merge results
│  results        │  (block/continue/modify)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Apply to core   │  Update state / Block action
│  logic          │
└─────────────────┘
```

### 拦截示例

```typescript
// Tool call can be blocked
pi.on('tool_call', async (event) => {
  if (isDangerous(event)) {
    return { block: true, reason: 'Too dangerous' };
  }
});

// Tool result can be modified
pi.on('tool_result', async (event) => {
  return {
    content: [...event.content, { type: 'text', text: '[Modified]' }],
  };
});

// Provider request can be modified
pi.on('before_provider_request', async (event) => {
  event.payload.headers['X-Custom'] = 'value';
  return event.payload;
});
```

---

## 12.4 状态管理

### AgentState

```typescript
interface AgentState {
  systemPrompt: string;
  model: Model<Api>;
  thinkingLevel: ThinkingLevel;
  tools: AgentTool<any>[];
  messages: AgentMessage[];
  isStreaming: boolean;
  streamMessage: AssistantMessage | null;
  pendingToolCalls: Set<string>;
  error: Error | undefined;
}
```

### 状态流转

```
IDLE
  │
  ▼ (prompt called)
STREAMING
  │
  ├──► TOOL_CALLS_PENDING ──► EXECUTING_TOOLS ──► back to STREAMING
  │
  ▼ (done/error)
IDLE
```

### 持久化

SessionManager 将状态持久化为 JSONL：

```jsonl
{"type":"session","id":"abc","timestamp":"2025-01-15T10:00:00Z"}
{"type":"message","id":"m1","parentId":null,"message":{...}}
{"type":"message","id":"m2","parentId":"m1","message":{...}}
{"type":"model_change","id":"e1","parentId":"m2","provider":"anthropic",...}
```

---

## 12.5 扩展系统

### 加载流程

```
1. Discovery (DefaultResourceLoader)
   - ~/.pi/extensions/
   - <cwd>/.pi/extensions/
   - --extension paths
      │
      ▼
2. Loading (loader.ts)
   - jiti dynamic import
   - Error isolation
      │
      ▼
3. Initialization (ExtensionRunner.loadExtensions)
   - Call extensionFactory(pi)
   - Collect registrations
      │
      ▼
4. Binding (ExtensionRunner.bindCore)
   - Inject actions
   - Inject contextActions
   - Flush pending providers
      │
      ▼
5. Runtime
   - Event dispatch
   - Tool execution
```

### 扩展运行时

```typescript
interface ExtensionRuntime {
  // Registrations
  tools: Map<string, RegisteredTool>;
  commands: Map<string, RegisteredCommand>;
  handlers: Map<EventType, Handler[]>;
  
  // Context
  uiContext?: ExtensionUIContext;
  commandContextActions?: ExtensionCommandContextActions;
  
  // Communication
  events: EventBus;
}
```

---

## 12.6 工具执行

### 执行模式

```typescript
type ToolExecutionMode = 'parallel' | 'sequential';
```

**Parallel** (default):
```
Tool A ──┐
Tool B ──┼──► Wait all ──► Results
Tool C ──┘
```

**Sequential**:
```
Tool A ──► Result A ──► Tool B ──► Result B ──► ...
```

### 执行流程

```
tool_call event emitted
    │
    ▼
Extension handlers (can block)
    │
    ▼
AgentTool.execute()
    │
    ▼
Tool execution (with onUpdate callbacks)
    │
    ▼
tool_result event emitted
    │
    ▼
Extension handlers (can modify)
    │
    ▼
Result added to messages
```

---

## 12.7 模型调用

### Provider 注册

```typescript
// Built-in providers
registerBuiltInApiProviders();

// Custom providers from extensions
pi.registerProvider('custom', { ... });
```

### 调用流程

```
AgentLoop
    │
    ▼
streamSimple(model, context, options)
    │
    ▼
getApiProvider(model.api)
    │
    ▼
provider.streamSimple(model, context, options)
    │
    ▼
HTTP request to provider
    │
    ▼
EventStream (text_delta, toolcall_*, done/error)
    │
    ▼
AgentEvent conversion
```

---

## 12.8 调试技巧

### 日志

```typescript
// Extension logging
console.log('[MyExtension]', 'Message');

// Event tracing（按需注册事件）
pi.on('agent_start', () => {
  console.log('[Event] agent_start');
});

pi.on('tool_execution_end', (event) => {
  console.log('[Event] tool_execution_end', event.toolName, event.toolCallId);
});
```

### 状态检查

```typescript
// In extension
pi.registerCommand('debug', {
  execute: async (ctx) => {
    const tools = pi.getActiveTools();
    const commands = pi.getCommands();
    ctx.sendUserMessage(`Tools: ${tools.join(', ')}`);
  },
});
```

### 断点

```typescript
pi.on('tool_call', async (event) => {
  if (event.toolName === 'target') {
    debugger; // DevTools breakpoint
  }
});
```

---

## 本章小结

- **五层架构**：Host → Application → Agent Core → AI → Infrastructure
- **数据流**：Input → Session → Agent → Loop → Stream → Provider
- **事件系统**：Hierarchical, interceptable, modifiable
- **状态管理**：AgentState (memory) + SessionManager (disk)
- **扩展系统**：Discovery → Load → Init → Bind → Runtime
- **工具执行**：Parallel/Sequential with interception hooks

---

*详细源码分析请参考 [deep-dive-architecture.md](./deep-dive-architecture.md)*
