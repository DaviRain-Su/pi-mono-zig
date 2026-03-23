# 第9章：扩展 API 详解

> 工具、命令、事件、UI，以及 provider / 资源发现 / 模式差异。

---

## 9.1 ExtensionAPI 概览

扩展导出一个默认函数，接收 `ExtensionAPI`：

```typescript
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  // 工具
  pi.registerTool({ ... });

  // 命令
  pi.registerCommand("hello", { ... });

  // 快捷键
  pi.registerShortcut("ctrl+x", { ... });

  // CLI flag
  pi.registerFlag("my-flag", { ... });

  // 事件
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "bash") {
      return { block: true, reason: "disabled" };
    }
  });

  // Provider
  pi.registerProvider("my-proxy", { ... });

  // 消息与会话
  pi.sendMessage({ customType: "note", content: "hello" });
  pi.sendUserMessage("continue with the refactor", { deliverAs: "steer" });
  pi.appendEntry("state", { enabled: true });

  // UI
  pi.ui.notify("Loaded", "info");

  // 事件总线
  pi.events.emit("my-event", { ok: true });
}
```

`ExtensionAPI` 的核心能力可以分为：

- **注册**：工具、命令、快捷键、flag、消息渲染器、provider
- **监听**：会话、agent、turn、message、tool、input 等事件
- **动作**：发送消息、执行命令、切换模型、切换活跃工具、压缩上下文等
- **UI**：对话框、通知、状态栏、页脚、覆盖层、自定义编辑器
- **通信**：扩展间事件总线 `pi.events`

---

## 9.2 工具注册（registerTool）

### 工具定义

```typescript
import { Type } from "@sinclair/typebox";

pi.registerTool({
  name: "count-lines",
  label: "Count Lines",
  description: "Count the number of lines in a text file",
  parameters: Type.Object({
    path: Type.String({ description: "Path to the file" }),
  }),
  async execute(toolCallId, params, signal, onUpdate, ctx) {
    onUpdate?.({
      content: [{ type: "text", text: "Reading file..." }],
    });

    return {
      content: [{ type: "text", text: "42 lines" }],
      details: { lineCount: 42 },
    };
  },
});
```

### 参数说明

- `name`：工具唯一名。若与内置工具同名，可覆盖内置工具
- `label`：TUI 中显示的短名称
- `description`：告诉模型“什么时候该用这个工具”
- `parameters`：TypeBox schema
- `execute()`：执行函数

### execute 函数签名

```typescript
execute(
  toolCallId,
  params,
  signal,
  onUpdate,
  ctx,
) => Promise<ToolResult>
```

### `ctx` 常见能力

`ctx` 是 `ExtensionContext`，常用字段 / 方法包括：

```typescript
const cwd = ctx.cwd;
const model = ctx.model;
const thinking = ctx.getThinkingLevel();
await ctx.exec("rg", ["TODO", cwd]);
ctx.ui.notify("Done", "info");
```

### `onUpdate` 用于流式更新

```typescript
async execute(toolCallId, args, signal, onUpdate, ctx) {
  onUpdate?.({
    content: [{ type: "text", text: "Step 1/3: starting" }],
  });

  const result = await doWork();

  onUpdate?.({
    content: [{ type: "text", text: "Step 2/3: complete" }],
  });

  return {
    content: [{ type: "text", text: "Done!" }],
    details: result,
  };
}
```

### 返回值

```typescript
interface ToolResult<TDetails = unknown> {
  content: (TextContent | ImageContent)[];
  details?: TDetails;
}
```

- `content`：显示给用户，并可作为工具结果进入上下文
- `details`：结构化信息，供 UI、调试、渲染器使用

---

## 9.3 命令注册（registerCommand）

这里是中文文档以前最容易漂移的地方：

> **当前命令注册字段名是 `handler`，不是 `execute`。**

### 真实结构

```typescript
interface RegisteredCommand {
  name: string;
  description?: string;
  getArgumentCompletions?: (argumentPrefix: string) => AutocompleteItem[] | null;
  handler: (args: string, ctx: ExtensionCommandContext) => Promise<void>;
}
```

### 基本示例

```typescript
pi.registerCommand("deps", {
  description: "Show project dependencies",
  handler: async (args, ctx) => {
    ctx.sendUserMessage(`Analyze dependencies ${args}`.trim());
  },
});
```

### 带 UI 的命令

```typescript
pi.registerCommand("setup", {
  description: "Interactive setup wizard",
  handler: async (args, ctx) => {
    const env = await ctx.ui.select("Select environment", ["dev", "staging", "production"]);
    if (!env) return;

    const confirmed = await ctx.ui.confirm("Confirm deployment?", `Deploy to ${env}`);
    if (!confirmed) return;

    const version = await ctx.ui.input("Version tag", "v1.0.0");
    ctx.sendUserMessage(`Deploy ${version} to ${env}`);
  },
});
```

### `ExtensionCommandContext` 能做什么

除了普通 `ExtensionContext` 的能力，还包含：

- `waitForIdle()`
- `newSession()`
- `fork()`
- `switchSession()`
- `sendUserMessage()`
- `sendMessage()`

---

## 9.4 快捷键与 CLI flag

### 快捷键

```typescript
pi.registerShortcut("ctrl+x", {
  description: "Run custom action",
  handler: async (ctx) => {
    ctx.ui.notify("Triggered", "info");
  },
});
```

### CLI flag

```typescript
pi.registerFlag("my-flag", {
  description: "Enable my extension mode",
  type: "boolean",
  default: false,
});

const value = pi.getFlag("my-flag");
```

flag 类型：
- `boolean`
- `string`

---

## 9.5 事件监听（on）

### 当前可监听事件

```typescript
pi.on("resources_discover", ...)
pi.on("session_directory", ...)
pi.on("session_start", ...)
pi.on("session_before_switch", ...)
pi.on("session_switch", ...)
pi.on("session_before_fork", ...)
pi.on("session_fork", ...)
pi.on("session_before_compact", ...)
pi.on("session_compact", ...)
pi.on("session_shutdown", ...)
pi.on("session_before_tree", ...)
pi.on("session_tree", ...)
pi.on("context", ...)
pi.on("before_provider_request", ...)
pi.on("before_agent_start", ...)
pi.on("agent_start", ...)
pi.on("agent_end", ...)
pi.on("turn_start", ...)
pi.on("turn_end", ...)
pi.on("message_start", ...)
pi.on("message_update", ...)
pi.on("message_end", ...)
pi.on("tool_execution_start", ...)
pi.on("tool_execution_update", ...)
pi.on("tool_execution_end", ...)
pi.on("model_select", ...)
pi.on("tool_call", ...)
pi.on("tool_result", ...)
pi.on("user_bash", ...)
pi.on("input", ...)
```

### 常见示例

#### Agent 事件

```typescript
pi.on("agent_start", async (_event) => {
  console.log("Agent started");
});

pi.on("turn_end", async (_event) => {
  console.log("Turn ended");
});
```

#### 消息事件

```typescript
pi.on("message_start", async (event) => {
  console.log("Message role:", event.message.role);
});

pi.on("message_update", async (event) => {
  console.log("Streaming event:", event.assistantMessageEvent.type);
});
```

#### 工具事件

```typescript
pi.on("tool_call", async (event) => {
  if (event.toolName === "dangerous") {
    return {
      block: true,
      reason: "Too dangerous",
    };
  }
});

pi.on("tool_result", async (event) => {
  if (event.toolName === "read") {
    return {
      content: [
        ...event.content,
        { type: "text", text: "[Extension] File loaded" },
      ],
    };
  }
});
```

#### 会话 / Provider 事件

```typescript
pi.on("session_before_switch", async (_event) => {
  return { cancel: false };
});

pi.on("session_before_compact", async (event) => {
  if (event.branchEntries.length === 0) {
    return { cancel: true };
  }
});

pi.on("before_provider_request", async (event) => {
  event.payload.headers = {
    ...event.payload.headers,
    "X-Custom": "value",
  };
  return event.payload;
});
```

### 事件返回值的语义

| 返回值 | 效果 |
|-------|------|
| `undefined` | 保持默认行为 |
| `{ block: true, reason }` | 阻止工具调用 |
| `{ cancel: true }` | 取消会话切换 / fork / compact / tree 等流程 |
| 修改后的 payload | 替换 provider 请求载荷 |
| `SessionBeforeCompactResult` 等结构化返回 | 覆盖部分默认行为 |

---

## 9.6 UI 上下文

### 对话框

```typescript
const choice = await pi.ui.select("Title", ["option1", "option2"]);
const confirmed = await pi.ui.confirm("Title", "Message");
const text = await pi.ui.input("Title", "placeholder");
const code = await pi.ui.editor("Edit code", "initial content");
```

### 通知

```typescript
pi.ui.notify("Operation complete", "info");
pi.ui.notify("Something went wrong", "error");
pi.ui.notify("Please check", "warning");
```

### 状态显示与 Widget

```typescript
pi.ui.setStatus("my-extension", "Processing...");
pi.ui.setStatus("my-extension", undefined);

pi.ui.setWidget("my-widget", ["Line 1", "Line 2"], { placement: "aboveEditor" });
pi.ui.setWidget("my-widget", undefined);
```

### 页脚 / 标题 / 编辑器替换

```typescript
pi.ui.setFooter((tui, theme, data) => new CustomFooter(tui, theme, data));
pi.ui.setHeader((tui, theme, data) => new CustomHeader(tui, theme, data));
pi.ui.setEditorComponent((tui, theme, data) => new CustomEditor(tui, theme, data));
```

复杂交互和覆盖层通常通过 `pi.ui.custom()` 构建。

---

## 9.7 Provider 注册

### 基本用法

```typescript
pi.registerProvider("my-proxy", {
  baseUrl: "https://proxy.example.com",
  apiKey: "PROXY_API_KEY",
  api: "openai-completions",
  models: [
    {
      id: "custom-model",
      name: "Custom Model",
      reasoning: true,
      input: ["text", "image"],
      contextWindow: 128000,
      maxTokens: 4096,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    },
  ],
});
```

### ProviderConfig 要点

```typescript
interface ProviderConfig {
  baseUrl?: string;
  apiKey?: string;
  api?: Api;
  streamSimple?: StreamFunction;
  headers?: Record<string, string>;
  authHeader?: boolean;
  models?: ProviderModelConfig[];
  oauth?: {
    name: string;
    login(callbacks): Promise<OAuthCredentials>;
    refreshToken(credentials): Promise<OAuthCredentials>;
    getApiKey(credentials): string;
    modifyModels?(models, credentials): Model[];
  };
}
```

### unregisterProvider

```typescript
pi.unregisterProvider("my-proxy");
```

可移除通过扩展注册的 provider，并恢复之前被覆盖的内置模型。

---

## 9.8 消息、会话与状态

### sendMessage

发送自定义消息到会话：

```typescript
pi.sendMessage(
  {
    customType: "build-status",
    content: "Build started",
    display: "Build started",
  },
  { deliverAs: "nextTurn" },
);
```

可用投递方式：
- `steer`
- `followUp`
- `nextTurn`

### sendUserMessage

```typescript
pi.sendUserMessage("Continue with the migration", { deliverAs: "steer" });
```

### appendEntry

```typescript
pi.appendEntry("my-state", { enabled: true, lastRun: Date.now() });
```

这类条目会写入 session，用于扩展状态持久化，但不会直接发送给 LLM。

### 会话元数据

```typescript
pi.setSessionName("feature-refactor");
const name = pi.getSessionName();
pi.setLabel(entryId, "milestone");
```

---

## 9.9 资源来源与命令消歧

这是最新代码里相对新的能力之一。

pi 现在会为以下资源记录来源信息（source provenance）：

- slash commands
- prompt templates
- skills
- themes
- tools

这使系统能够：

- 在出现重名命令时做消歧
- 在诊断中告诉你某个命令 / 工具 / 资源来自哪里
- 在 `getCommands()`、工具列表、资源 diagnostics 中暴露来源信息

相关类型：

```typescript
interface SlashCommandInfo {
  name: string;
  description?: string;
  source: "extension" | "prompt" | "skill";
  sourceInfo: SourceInfo;
}
```

实践建议：

- 命令名尽量避免过于通用的单词
- 有多个扩展协同时，主动做命名空间区分
- 调试“为什么执行了错误命令”时，优先检查命令来源信息

---

## 9.10 事件总线

### 跨扩展通信

```typescript
// 扩展 A
pi.events.emit("my-event", { data: "value" });

// 扩展 B
pi.events.on("my-event", (data) => {
  console.log("Received:", data);
});
```

典型用途：
- 扩展间共享状态
- UI 协作
- 事件广播
- 多个扩展之间松耦合联动

---

## 9.11 模式差异

### Interactive 模式

支持完整 TUI 能力：
- 对话框
- overlay
- widget
- footer / header
- editor replacement
- custom UI

### RPC 模式

支持一部分 UI：

**支持：**
- `select`
- `confirm`
- `input`
- `editor`
- `notify`
- `setStatus`
- `setTitle`
- `setEditorText`
- `setWidget`（仅字符串数组）

**不支持或受限：**
- `setWorkingMessage`
- `setFooter`
- `setHeader`
- `setEditorComponent`
- `ui.custom()`
- `setWidget()` 的组件工厂形式
- `getEditorText()` 无法同步返回宿主编辑器实际内容

### Print / JSON 模式

不要假设存在可交互 TUI。需要用户对话框、自定义编辑器、overlay 的扩展都应提供降级路径。

---

## 9.12 完整示例

```typescript
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";

export default function comprehensiveExtension(pi: ExtensionAPI) {
  pi.registerTool({
    name: "analyze-deps",
    label: "Analyze Deps",
    description: "Analyze project dependencies",
    parameters: Type.Object({
      depth: Type.Number({ default: 1 }),
    }),
    async execute(toolCallId, args, signal, onUpdate, ctx) {
      onUpdate?.({
        content: [{ type: "text", text: "Reading package.json..." }],
      });

      const pkg = await ctx.exec("cat", ["package.json"]);
      const deps = JSON.parse(pkg.stdout).dependencies || {};

      return {
        content: [{ type: "text", text: `Found ${Object.keys(deps).length} dependencies` }],
        details: { deps },
      };
    },
  });

  pi.registerCommand("deps", {
    description: "Show project dependencies",
    handler: async (args, ctx) => {
      ctx.sendUserMessage("Analyze project dependencies");
    },
  });

  pi.on("tool_call", async (event) => {
    if (event.toolName === "write" && event.input.path === "package.json") {
      return { block: true, reason: "package.json is protected" };
    }
  });

  pi.ui.notify("Extension loaded", "info");
}
```

---

## 本章小结

- `registerTool`：定义模型可调用工具
- `registerCommand`：创建斜杠命令（字段名是 `handler`）
- `pi.on`：监听和拦截完整生命周期事件
- `pi.ui`：与用户交互、定制界面
- `registerProvider`：注册或覆盖 provider
- `sendMessage` / `sendUserMessage` / `appendEntry`：控制会话内容与扩展状态
- `pi.events`：扩展间通信
- 资源来源信息和命令消歧已成为正式能力，需要在大型扩展系统中考虑
