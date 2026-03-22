# pi 二次开发：架构总览

> 目标读者：希望基于源码做二次开发、嵌入、或自定义扩展的开发者。

本页给出 `pi` 的关键架构边界与调用链。内容以技术层面为主，避免停留在「可用命令」级别，便于你直接修改代码。

## 1. 分层边界（重要）

代码库是「**三层核心 + 两个宿主层**」结构：

1. **`packages/ai`**：模型与 provider 抽象层
   - 统一模型类型（`Model<Api>`）、provider 约定（`KnownApi`/`KnownProvider`）、流/完整调用。
   - 注册中心位于 `api-registry.ts`，所有 LLM API 通过 `stream/complete` 与 `streamSimple/completeSimple` 走统一入口。

2. **`packages/agent`**：通用 Agent Core
   - 维护 `AgentState`、转接 `convertToLlm`、tool loop、tool 并发与事件。
   - 以 `AgentEvent` 为事件总线，处理工具执行生命周期。

3. **`packages/coding-agent`**：应用层（CLI/嵌入工厂）
   - 聚合会话、资源（prompt/template/skills/themes）、扩展、模型注册、会话树与 compaction。
   - `AgentSession` 是此层的核心：在不同运行模式中复用同一控制面。

4. **`packages/tui`**：终端 UI 层（交互模式）
   - 以事件驱动渲染，向 `coding-agent` 的 `interactive` 模式提供终端交互。

5. **`packages/web-ui`**：浏览器 UI 层（组件化）
   - 用于嵌入式前端，消费同一 `AgentSession` / `AgentEvent` 语义。

## 2. 一条 prompt 的关键数据流（最常用路径）

### 2.1 入口
- 用户从 TUI 打字、web-ui 点击发送，或 RPC 命令发送。
- 最终都会通过 `AgentSession` 的 `prompt()`（或 `steer/follow_up`）进入内核。

### 2.2 编排
1. `AgentSession.prompt(...)`
   - 执行 prompt template 扩展、权限检查。
   - 通过内部 `Agent` 的 `prompt()` 进入流转。
2. `Agent.prompt(...)`
   - 在 `convertToLlm` 后形成兼容 LLM 的 `Message[]`。
   - 调用 `streamSimple(...)`：
      - `agent.ts` -> `this.state.model` + `this.streamFn`。
      - 最终落入 `@mariozechner/pi-ai` 的 `stream`。
3. `@mariozechner/pi-ai` 路由到 provider
   - 通过 `model.api` 从 `api-registry` 获取 provider。
   - 调用该 provider 的 `streamSimple`/`stream`。
4. 结果回流
   - Provider 持续产出 `AssistantMessageEvent`（`text_delta`、`toolcall_*`、`done/error`）。
   - `pi-agent-core` 把流事件转为 `AgentEvent`。
   - `AgentSession` 持久化并触发会话/扩展事件。
5. UI 消费
   - TUI/Web UI 订阅 `session.subscribe(...)` / `agent.subscribe(...)` 进行渲染与状态更新。

### 2.3 工具调用时序（简化）
- `assistant` 消息里出现 `toolCall`：
  - `tool_call` 扩展事件可 `block`。
  - 通过 `AgentTool` 执行（可并发或串行）。
  - `tool_call`/`tool_result` 与 `tool_execution_start/update/end` 事件同步通知。
  - 结果可在 `tool_result` 中覆盖 `content/details/isError`。
- 工具结果作为 `toolResult` 写回上下文并继续 loop。
  - 重型或结构化数据建议输出到临时文件/对象文件，再由后续步骤按需读取，减少对话上下文污染。

## 3. 会话与树结构（`SessionManager`）

### 3.1 持久化格式
- 文件为 JSONL，第一行为 `session` header。
- 后续每条 entry 均带 `id / parentId`，形成树。
- 类型包括：
  - `message`
  - `thinking_level_change`
  - `model_change`
  - `compaction`
  - `branch_summary`
  - `custom` / `custom_message` / `label` / `session_info`

### 3.2 树与导航
- `leafId` 指向当前“树位点”（叶子）。
- `navigate` 并不删历史，而是更新指针。
- `fork` / `switch_session` 会生成/切换到新文件并保留历史关系（通过 header `parentSession`）。
- `buildSessionContext(...)` 按当前 `leaf` 沿父链重建上下文。

### 3.3 截断与压缩
- Context overflow 与接近上限会触发 compaction。
- compaction 以 `compaction` entry 记录摘要与 `firstKeptEntryId`，并保留可复现上下文路径。
- `AgentSession` 同时支持手动 compact 与 auto compaction。

## 4. 运行模式（Mode）与统一会话层

`AgentSession` 作为同一个状态机，可被下列模式复用：
- `interactive`（TUI）
- `print`
- `rpc`（stdin/stdout 协议）
- SDK 直接使用（`createAgentSession`）

三类模式共用：
- `AgentSession`（消息、模型、会话状态）
- `Agent`（LLM loop）
- `subscribe` 事件语义

不同模式只负责 I/O 适配：
- TUI 负责快捷键、渲染和编辑器。
- RPC 负责 JSONL 协议与子进程边界。
- web-ui 组件负责组件化展示。

## 5. 关键事件语义

### 5.1 Agent 核心事件（`@mariozechner/pi-agent-core`）
- 生命周期：`agent_start/agent_end`、`turn_start/turn_end`
- 消息：`message_start/message_update/message_end`
- 工具：`tool_execution_start/tool_execution_update/tool_execution_end`

### 5.2 会话级增强事件（`AgentSessionEvent`）
- 除核心事件外，新增：
  - `auto_compaction_start/auto_compaction_end`
  - `auto_retry_start/auto_retry_end`

### 5.3 扩展事件
`agent.start` 与会话关键动作前后会触发扩展事件，核心实现中 `extension` 通知优先于本地状态更新（便于拦截或附加 side effect）。

## 6. 错误模型（不能擅自改变）

核心约束是：**错误优先走事件流，不破坏会话收敛**。
- `StreamFunction` / `StreamFn` 约定：失败不抛异常，而是通过 `done/error` 携带最终 `AssistantMessage`。
- 固定文本如：
  - `Mismatched api: ${model.api} expected ${api}`（provider 注册保护）
  - `Cannot continue: no messages in context`
  - `Cannot continue from message role: assistant`
  - `Tool ${toolCall.name} not found`
  - `Tool execution was blocked`

## 7. 为什么能稳定二次开发

1. 核心交互逻辑集中在 `agent-core`，避免各模式重复。
2. 会话、模型、扩展能力在 `coding-agent` 做统一抽象，便于共享扩展。
3. 事件协议贯穿三层，UI 可以替换不改核心。
4. 模型/Provider 是可插拔注册链路，不需要修改主干。
5. 会话树与自定义 entry 机制支持“可追溯+可回放”。

后续建议先阅读：
- `extensions-and-sdks.md`
- `../sdk.md`
- `../extensions.md`
- `../rpc.md`
- `../src/core/agent-session.ts`
