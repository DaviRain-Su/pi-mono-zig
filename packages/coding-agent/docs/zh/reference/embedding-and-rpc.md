# 嵌入与 RPC 协议（Node / Web）

本页给出两种推荐接入方式：
1. 同进程 SDK（推荐，低延迟、最稳定）
2. RPC 子进程协议（跨语言、跨进程或沙箱隔离）

---

## 1. 直接 SDK 接入（优先）

通过 `createAgentSession()` 创建可复用 `AgentSession`，避免再包装一次命令分发。

```ts
import { createAgentSession } from "@mariozechner/pi-coding-agent";

const { session } = await createAgentSession();

session.subscribe((ev) => {
  if (ev.type === "message_update" && ev.assistantMessageEvent.type === "text_delta") {
    process.stdout.write(ev.assistantMessageEvent.delta);
  }
});

await session.prompt("请帮我检查当前目录结构");
```

可直接使用的控制 API：
- `prompt / steer / followUp`
- `setModel` / `cycleModel`
- `compact / abortCompaction`
- `switchSession / fork / navigateTree`
- `newSession / abort / waitForIdle`

### 1.1 与 web-ui 的映射
- `web-ui` 组件接收的是 `pi-agent-core` 风格事件（`message_update`/`agent_end` 等）。
- 你可将同一 `Agent`/`AgentSession` 适配到自定义组件，无需改底层 loop。

关键文件：
- `packages/web-ui/src/components/AgentInterface.ts`
- `packages/web-ui/src/components/ChatPanel.ts`

## 2. RPC 模式（跨进程）

### 2.1 入口与生命周期
- 运行模式：`pi --mode rpc`
- 通信：
  - 输入：`stdin` JSONL（每行 JSON）
  - 输出：`stdout` JSONL（事件 + 命令响应）

`runRpcMode(session)` 在启动时会：
- 重定向 `process.stdout.write` 到底层 `stderr`，然后通过 `serializeJsonLine` 输出协议对象
- `process.stdin` 仅处理 JSON 命令
- 订阅 `session.subscribe`，把 `AgentSession` 事件原样转发

### 2.2 协议对象（精简）

请求字段常见类型（`RpcCommand`）：
- `prompt`、`steer`、`follow_up`
- `abort`
- `new_session`
- `get_state`
- `set_model`、`cycle_model`
- `compact`、`set_auto_compaction`
- `set_auto_retry`、`abort_retry`
- `bash`
- `switch_session`、`fork`
- `get_messages`
- `set_session_name`
- `get_commands`

响应：
- 所有命令返回 `type: "response"`
- `id` 可用于关联请求

事件：
- 由 `session.subscribe` 输出原始 `AgentEvent`/`AgentSessionEvent`

注意：
- `prompt` 在 streaming 中需提供 `streamingBehavior`：`steer` 或 `followUp`

### 2.3 客户端示例要点（`RpcClient`）

`packages/coding-agent/src/modes/rpc/rpc-client.ts` 封装了：
- 启动子进程
- `attachJsonlLineReader`
- `prompt`/`steer`/`follow_up`/`set_model` 等方法

你可直接复用这些方法，或者自行实现最小 `spawn + readline`。

## 3. 事件与错误一致性（跨模式关键）

无论 UI 是否在本地，建议主机端以事件为准：
- `prompt` 成功只代表已入队，不代表任务完成。
- 完成与终态应以：
  - `agent_end`
  - `auto_retry_end`
  - `auto_compaction_end`
  观察。

错误不应通过 `throw`/异常泄漏主流程：
- provider 层错误 -> `done/error`
- session 层重试/退避 -> `auto_retry_*`
- compact 失败 -> `auto_compaction_end`（含 `errorMessage`）

## 4. 与 web-ui 的嵌入边界

### 4.1 推荐结构
- **服务端**：运行 `coding-agent`（SDK/Node）或 `pi --mode rpc`
- **前端**：web-ui + 会话层状态
- **模型鉴权**：在 host 侧统一注入，避免前端持有 provider secret

### 4.2 浏览器代理策略
`web-ui/utils/proxy-utils.ts` 决定是否走 CORS proxy：
- `shouldUseProxyForProvider(provider, apiKey)`
- OpenAI-compat 与 `zai/openai-codex/anthropic` 有兼容处理

请将 provider URL 转发策略固定在前端/网关层，core 层不应夹杂浏览器实现。

## 5. 调试建议

- RPC 调试时记录 stdin/stdout 原文（逐行 JSON）。
- 端到端建议打印：
  - `runRpcMode` 产出事件顺序
  - 对应 `sessionId` + `messageCount`
  - `model/provider` 切换事件

- 可复现 CLI 流程后再切 RPC，避免在协议上二次踩坑。

## 6. 接口文件清单

- `packages/coding-agent/src/modes/rpc/rpc-types.ts`（命令/响应类型）
- `packages/coding-agent/src/modes/rpc/rpc-mode.ts`（服务端实现）
- `packages/coding-agent/src/modes/rpc/rpc-client.ts`（客户端实现）
- `packages/coding-agent/docs/rpc.md`（英文说明）
- `packages/coding-agent/src/modes/rpc/jsonl.ts`（序列化）
