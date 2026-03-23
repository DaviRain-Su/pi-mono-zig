# 扩展

> pi 可以自己创建扩展。你也可以让它按你的工作流直接写一个。

扩展是 TypeScript 模块，用来扩展 pi 的行为。它们可以订阅生命周期事件、注册可被 LLM 调用的自定义工具、添加斜杠命令、注册快捷键和 CLI flag、注入自定义 UI，甚至注册或覆盖 provider。

> **/reload 的放置要求：** 将扩展放在 `~/.pi/agent/extensions/`（全局）或 `.pi/extensions/`（项目级）才能被自动发现，并通过 `/reload` 热重载。`pi -e ./path.ts` 更适合临时测试。

## 核心能力

- **自定义工具**：通过 `pi.registerTool()` 注册可被模型调用的工具
- **事件拦截**：阻止或修改工具调用、注入上下文、定制压缩行为
- **用户交互**：通过 `ctx.ui` 调用选择、确认、输入、通知等对话框
- **自定义 UI 组件**：使用 `ctx.ui.custom()` 构建复杂交互，或用 `setWidget` / `setFooter` / `setHeader` / `setEditorComponent` 定制 TUI
- **自定义命令**：通过 `pi.registerCommand()` 添加 `/mycommand`
- **会话持久化**：使用 `pi.appendEntry()` 保存不会发送给 LLM 的结构化状态
- **自定义渲染**：控制工具调用/结果与自定义消息在 TUI 中的显示方式
- **Provider 扩展**：通过 `registerProvider()` 增加或覆盖 provider

## 典型用例

- 危险命令权限门控（如 `rm -rf`、`sudo`）
- Git checkpoint / session 分叉保护
- 保护 `.env`、`node_modules/` 等路径
- 自定义会话压缩
- 对话摘要命令
- 多步问答、向导、表单式交互
- 带状态的工具（如 todo、连接池）
- 文件监视器、Webhook、CI 集成
- 自定义主题/页脚/覆盖层
- 需要 OAuth 的自定义 provider

示例见：[examples/extensions/](../../../examples/extensions/)

## 目录

- [快速开始](#快速开始)
- [扩展位置](#扩展位置)
- [可用导入](#可用导入)
- [编写扩展](#编写扩展)
  - [扩展组织方式](#扩展组织方式)
- [事件](#事件)
  - [生命周期概览](#生命周期概览)
  - [会话事件](#会话事件)
  - [Agent 事件](#agent-事件)
  - [工具事件](#工具事件)
- [ExtensionContext](#extensioncontext)
- [ExtensionCommandContext](#extensioncommandcontext)
- [ExtensionAPI 方法](#extensionapi-方法)
- [状态管理](#状态管理)
- [自定义工具](#自定义工具)
- [自定义 UI](#自定义-ui)
- [资源来源与命令消歧](#资源来源与命令消歧)
- [模式差异](#模式差异)
- [错误处理](#错误处理)
- [示例参考](#示例参考)

## 快速开始

创建 `~/.pi/agent/extensions/my-extension.ts`：

```typescript
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";

export default function (pi: ExtensionAPI) {
  // 监听事件
  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.notify("Extension loaded!", "info");
  });

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "bash" && event.input.command?.includes("rm -rf")) {
      const ok = await ctx.ui.confirm("Dangerous!", "Allow rm -rf?");
      if (!ok) return { block: true, reason: "Blocked by user" };
    }
  });

  // 注册工具
  pi.registerTool({
    name: "greet",
    label: "Greet",
    description: "Greet someone by name",
    parameters: Type.Object({
      name: Type.String({ description: "Name to greet" }),
    }),
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      return {
        content: [{ type: "text", text: `Hello, ${params.name}!` }],
        details: {},
      };
    },
  });

  // 注册命令
  pi.registerCommand("hello", {
    description: "Say hello",
    handler: async (args, ctx) => {
      ctx.ui.notify(`Hello ${args || "world"}!`, "info");
    },
  });
}
```

临时测试：

```bash
pi -e ./my-extension.ts
```

## 扩展位置

> **安全提示：** 扩展拥有与你当前进程相同的系统权限，并可执行任意代码。仅安装可信来源的扩展。

自动发现位置：

| 位置 | 作用域 |
|------|--------|
| `~/.pi/agent/extensions/*.ts` | 全局 |
| `~/.pi/agent/extensions/*/index.ts` | 全局（目录） |
| `.pi/extensions/*.ts` | 项目级 |
| `.pi/extensions/*/index.ts` | 项目级（目录） |

也可以通过 `settings.json` 指定额外路径：

```json
{
  "packages": [
    "npm:@foo/bar@1.0.0",
    "git:github.com/user/repo@v1"
  ],
  "extensions": [
    "/path/to/local/extension.ts",
    "/path/to/local/extension/dir"
  ]
}
```

要通过 npm 或 git 分发扩展，请见 [packages.md](packages.md)。

## 可用导入

| 包 | 作用 |
|----|------|
| `@mariozechner/pi-coding-agent` | 扩展类型（`ExtensionAPI`、`ExtensionContext`、事件类型等） |
| `@sinclair/typebox` | 工具参数 schema |
| `@mariozechner/pi-ai` | AI 工具类（如 `StringEnum`） |
| `@mariozechner/pi-tui` | 自定义 TUI 组件 |

普通 npm 依赖也可使用。将 `package.json` 放在扩展目录（或其父目录）旁边，执行 `npm install` 后即可从 `node_modules/` 导入。

Node.js 内置模块（如 `node:fs`、`node:path`）同样可用。

## 编写扩展

扩展导出一个默认函数，接收 `ExtensionAPI`：

```typescript
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.on("event_name", async (event, ctx) => {
    const ok = await ctx.ui.confirm("Title", "Are you sure?");
    ctx.ui.notify("Done!", "info");
    ctx.ui.setStatus("my-ext", "Processing...");
    ctx.ui.setWidget("my-ext", ["Line 1", "Line 2"]);
  });

  pi.registerTool({ ... });
  pi.registerCommand("name", { ... });
  pi.registerShortcut("ctrl+x", { ... });
  pi.registerFlag("my-flag", { ... });
}
```

pi 使用 [jiti](https://github.com/unjs/jiti) 加载扩展，因此 TypeScript 可直接运行，无需预编译。

### 扩展组织方式

**单文件**：

```text
~/.pi/agent/extensions/
└── my-extension.ts
```

**目录 + index.ts**：

```text
~/.pi/agent/extensions/
└── my-extension/
    ├── index.ts
    ├── tools.ts
    └── utils.ts
```

**带依赖的包结构**：

```text
~/.pi/agent/extensions/
└── my-extension/
    ├── package.json
    ├── package-lock.json
    ├── node_modules/
    └── src/
        └── index.ts
```

示例 `package.json`：

```json
{
  "name": "my-extension",
  "dependencies": {
    "zod": "^3.0.0",
    "chalk": "^5.0.0"
  },
  "pi": {
    "extensions": ["./src/index.ts"]
  }
}
```

## 事件

### 生命周期概览

```text
pi 启动（CLI）
  │
  ├─► session_directory（仅 CLI 启动期，无 ctx）
  └─► session_start
      │
      ▼
用户发送 prompt
  │
  ├─► 检查扩展命令（如命中，优先执行）
  ├─► input（可拦截、转换或完全处理）
  ├─► skill / prompt template 展开
  ├─► before_agent_start
  ├─► agent_start
  ├─► message_start / message_update / message_end
  │
  │   turn 循环（只要模型继续调用工具）
  │   ├─► turn_start
  │   ├─► context
  │   ├─► before_provider_request
  │   ├─► tool_execution_start
  │   ├─► tool_call
  │   ├─► tool_execution_update
  │   ├─► tool_result
  │   ├─► tool_execution_end
  │   └─► turn_end
  │
  └─► agent_end
```

### 当前可监听事件

- `resources_discover`
- `session_directory`
- `session_start`
- `session_before_switch`
- `session_switch`
- `session_before_fork`
- `session_fork`
- `session_before_compact`
- `session_compact`
- `session_shutdown`
- `session_before_tree`
- `session_tree`
- `context`
- `before_provider_request`
- `before_agent_start`
- `agent_start`
- `agent_end`
- `turn_start`
- `turn_end`
- `message_start`
- `message_update`
- `message_end`
- `tool_execution_start`
- `tool_execution_update`
- `tool_execution_end`
- `model_select`
- `tool_call`
- `tool_result`
- `user_bash`
- `input`

### 常见事件示例

```typescript
pi.on("agent_start", async (_event) => {
  console.log("Agent started");
});

pi.on("message_update", async (event) => {
  console.log("Streaming:", event.assistantMessageEvent.type);
});

pi.on("tool_call", async (event) => {
  if (event.toolName === "dangerous") {
    return { block: true, reason: "Too dangerous" };
  }
});

pi.on("session_before_switch", async (_event) => {
  return { cancel: false };
});

pi.on("before_provider_request", async (event) => {
  event.payload.headers = {
    ...event.payload.headers,
    "X-Custom": "value",
  };
  return event.payload;
});
```

## ExtensionContext

`ExtensionContext` 是扩展回调的运行时上下文。常见能力包括：

- `cwd`：当前工作目录
- `model`：当前模型
- `ui`：用户交互上下文
- `exec()`：执行命令
- `getActiveTools()` / `setActiveTools()`
- `getCommands()`
- `getThinkingLevel()` / `setThinkingLevel()`
- `setModel()`
- `reload()`
- `shutdown()`
- `compact()`
- `getSystemPrompt()`

常见用法：

```typescript
pi.on("session_start", async (_event, ctx) => {
  const cwd = ctx.cwd;
  const result = await ctx.exec("git", ["status", "--short"]);
  if (result.stdout.trim()) {
    ctx.ui.notify("Repository is dirty", "warning");
  }
});
```

## ExtensionCommandContext

命令处理器收到的是 `ExtensionCommandContext`，它扩展了 `ExtensionContext`，并额外提供会话与消息控制能力，例如：

- `waitForIdle()`
- `newSession()`
- `fork()`
- `switchSession()`
- `sendUserMessage()`
- `sendMessage()`

注意：命令注册使用的字段名是 `handler`，不是 `execute`。

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

## ExtensionAPI 方法

### registerTool

注册可被 LLM 调用的工具：

```typescript
pi.registerTool({
  name: "count-lines",
  label: "Count Lines",
  description: "Count lines in a text file",
  parameters: Type.Object({
    path: Type.String({ description: "Path to file" }),
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

### registerCommand

注册斜杠命令。当前真实签名等价于：

```typescript
interface RegisteredCommand {
  name: string;
  description?: string;
  getArgumentCompletions?: (argumentPrefix: string) => AutocompleteItem[] | null;
  handler: (args: string, ctx: ExtensionCommandContext) => Promise<void>;
}
```

示例：

```typescript
pi.registerCommand("deps", {
  description: "Show project dependencies",
  handler: async (args, ctx) => {
    ctx.sendUserMessage(`Analyze project dependencies ${args}`.trim());
  },
});
```

### registerShortcut / registerFlag

```typescript
pi.registerShortcut("ctrl+x", {
  description: "Do something",
  handler: async (ctx) => {
    ctx.ui.notify("Triggered", "info");
  },
});

pi.registerFlag("my-flag", {
  description: "Enable my extension mode",
  type: "boolean",
  default: false,
});
```

### sendMessage / sendUserMessage / appendEntry

```typescript
pi.sendMessage(
  {
    customType: "my-status",
    content: "Background job started",
    display: "Background job started",
  },
  { deliverAs: "nextTurn" },
);

pi.sendUserMessage("Please continue with the refactor", { deliverAs: "steer" });

pi.appendEntry("my-extension-state", { enabled: true });
```

- `sendMessage()` 发送自定义消息，可选择：`steer` / `followUp` / `nextTurn`
- `sendUserMessage()` 总是触发 turn，在 streaming 时可指定 `deliverAs: "steer" | "followUp"`
- `appendEntry()` 仅写入会话状态，不发送给 LLM

### registerProvider / unregisterProvider

可添加新 provider、覆盖现有 provider 的 `baseUrl`，或注册 OAuth provider。

```typescript
pi.registerProvider("my-proxy", {
  baseUrl: "https://proxy.example.com",
  apiKey: "PROXY_API_KEY",
  api: "anthropic-messages",
  models: [
    {
      id: "claude-sonnet-4-20250514",
      name: "Claude 4 Sonnet (proxy)",
      reasoning: false,
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 200000,
      maxTokens: 16384,
    },
  ],
});

pi.unregisterProvider("my-proxy");
```

## 状态管理

扩展可通过以下方式管理持久状态：

- `appendEntry()`：存储结构化状态
- `setSessionName()` / `getSessionName()`：维护显示名称
- `setLabel(entryId, label)`：给 `/tree` 条目打标签
- 自定义消息类型 + `registerMessageRenderer()`：渲染自定义 session 内容

## 自定义工具

工具定义要点：

- `name` 必须唯一；如果与内置工具同名，可覆盖内置工具
- `description` 要告诉模型“什么时候用这个工具”
- `parameters` 使用 TypeBox 定义
- `execute()` 返回：
  - `content`：显示给用户 / 送回模型的结果
  - `details`：结构化附加信息

## 自定义 UI

### 常见对话框

```typescript
const choice = await pi.ui.select("Title", ["option1", "option2"]);
const confirmed = await pi.ui.confirm("Title", "Message");
const text = await pi.ui.input("Title", "placeholder");
const code = await pi.ui.editor("Edit code", "initial content");
```

### 通知 / 状态 / Widget

```typescript
pi.ui.notify("Operation complete", "info");
pi.ui.setStatus("my-extension", "Processing...");
pi.ui.setStatus("my-extension", undefined);
pi.ui.setWidget("my-widget", ["Line 1", "Line 2"], { placement: "aboveEditor" });
pi.ui.setWidget("my-widget", undefined);
```

### 自定义 UI / Footer / Header / Editor

```typescript
pi.ui.setFooter((tui, theme, data) => new CustomFooter(tui, theme, data));
pi.ui.setHeader((tui, theme, data) => new CustomHeader(tui, theme, data));
pi.ui.setEditorComponent((tui, theme, data) => new CustomEditor(tui, theme, data));
```

复杂交互通常通过 `pi.ui.custom()` 完成，覆盖层（overlay）、确认框超时、被动 overlay 等都见示例目录。

## 资源来源与命令消歧

最新 pi 会为资源记录来源信息（source provenance），包括：

- 扩展命令
- Prompt templates
- Skills
- Themes
- 工具定义

这意味着：

- 当出现重名命令时，系统会基于来源信息做消歧和诊断
- 扩展注册的命令会带 `sourceInfo`
- `getCommands()` 返回的是 `SlashCommandInfo[]`，其中包含：
  - `name`
  - `description`
  - `source`（`extension` / `prompt` / `skill`）
  - `sourceInfo`

实践建议：

- 命令名称尽量加命名空间或功能前缀
- 不要假设“同名命令一定只有一个来源”
- 调试加载冲突时，优先查看资源 diagnostics 和命令来源

## 模式差异

### Interactive 模式

支持全部 TUI / 对话框 / 自定义组件能力。

### RPC 模式

扩展可以运行，但 UI 能力是受限的：

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
- `setWidget()` 的 component factory 形式
- `getEditorText()` 无法同步获取真实宿主编辑器值

### Print / JSON 模式

不应假设存在交互式 TUI。依赖对话框、overlay、编辑器替换等行为的扩展应当提供降级路径或直接退出。

## 错误处理

- 扩展抛出的错误会显示为诊断事件或通知
- 工具执行中的错误建议转成 `isError` 语义清晰的结果，而不是让整个扩展崩溃
- 对可能被阻止的操作（如危险 bash）优先返回 `{ block: true, reason }`

## 示例参考

所有示例在 [examples/extensions/](../../../examples/extensions/)。

| 示例 | 说明 | 关键 API |
|---------|-------------|----------|
| **工具** |||
| `hello.ts` | 最小工具注册 | `registerTool` |
| `question.ts` | 带用户交互的工具 | `registerTool`, `ui.select` |
| `questionnaire.ts` | 多步向导工具 | `registerTool`, `ui.custom` |
| `todo.ts` | 带持久化的有状态工具 | `registerTool`, `appendEntry`, `renderResult`, 会话事件 |
| `dynamic-tools.ts` | 启动后和命令期间注册工具 | `registerTool`, `session_start`, `registerCommand` |
| `truncated-tool.ts` | 输出截断示例 | `registerTool`, `truncateHead` |
| `tool-override.ts` | 覆盖内置 read 工具 | `registerTool`（与内置同名） |
| **命令** |||
| `pirate.ts` | 每轮修改系统提示 | `registerCommand`, `before_agent_start` |
| `summarize.ts` | 对话摘要命令 | `registerCommand`, `ui.custom` |
| `handoff.ts` | 跨 provider 模型切换 | `registerCommand`, `ui.editor`, `ui.custom` |
| `qna.ts` | 带自定义 UI 的问答 | `registerCommand`, `ui.custom`, `setEditorText` |
| `send-user-message.ts` | 注入用户消息 | `registerCommand`, `sendUserMessage` |
| `reload-runtime.ts` | 重载命令和 LLM 工具切换 | `registerCommand`, `ctx.reload()`, `sendUserMessage` |
| `shutdown-command.ts` | 优雅关闭命令 | `registerCommand`, `shutdown()` |
| **事件与门控** |||
| `permission-gate.ts` | 阻止危险命令 | `on("tool_call")`, `ui.confirm` |
| `protected-paths.ts` | 阻止写入特定路径 | `on("tool_call")` |
| `confirm-destructive.ts` | 确认会话更改 | `on("session_before_switch")`, `on("session_before_fork")` |
| `dirty-repo-guard.ts` | 脏 git 仓库时警告 | `on("session_before_*")`, `exec` |
| `input-transform.ts` | 转换用户输入 | `on("input")` |
| `model-status.ts` | 响应模型更改 | `on("model_select")`, `setStatus` |
| `provider-payload.ts` | 检查或修补 provider payload | `on("before_provider_request")` |
| `system-prompt-header.ts` | 显示系统提示信息 | `on("agent_start")`, `getSystemPrompt` |
| `claude-rules.ts` | 从文件加载规则 | `on("session_start")`, `on("before_agent_start")` |
| `file-trigger.ts` | 文件监视器触发消息 | `sendMessage` |
| **压缩与会话** |||
| `custom-compaction.ts` | 自定义压缩摘要 | `on("session_before_compact")` |
| `trigger-compact.ts` | 手动触发压缩 | `compact()` |
| `git-checkpoint.ts` | 轮次时 git stash | `on("turn_end")`, `on("session_fork")`, `exec` |
| `auto-commit-on-exit.ts` | 退出时提交 | `on("session_shutdown")`, `exec` |
| **UI 组件** |||
| `status-line.ts` | 页脚状态指示器 | `setStatus`, 会话事件 |
| `custom-footer.ts` | 完全替换页脚 | `registerCommand`, `setFooter` |
| `custom-header.ts` | 替换启动标题 | `on("session_start")`, `setHeader` |
| `modal-editor.ts` | Vim 风格模态编辑器 | `setEditorComponent`, `CustomEditor` |
| `rainbow-editor.ts` | 自定义编辑器样式 | `setEditorComponent` |
| `widget-placement.ts` | 编辑器上方/下方的小部件 | `setWidget` |
| `overlay-test.ts` | 覆盖组件 | `ui.custom` with overlay options |
| `overlay-qa-tests.ts` | 全面覆盖测试 | `ui.custom`, 所有覆盖选项 |
| `notify.ts` | 简单通知 | `ui.notify` |
| `timed-confirm.ts` | 带超时的对话框 | `ui.confirm` with timeout/signal |
| `mac-system-theme.ts` | 自动切换主题 | `setTheme`, `exec` |
| **复杂扩展** |||
| `plan-mode/` | 完整计划模式实现 | 所有事件类型, `registerCommand`, `registerShortcut`, `registerFlag`, `setStatus`, `setWidget`, `sendMessage`, `setActiveTools` |
| `preset.ts` | 可保存预设（模型、工具、思考） | `registerCommand`, `registerShortcut`, `registerFlag`, `setModel`, `setActiveTools`, `setThinkingLevel`, `appendEntry` |
| `tools.ts` | 切换工具开关 UI | `registerCommand`, `setActiveTools`, `SettingsList`, 会话事件 |
| **远程与沙盒** |||
| `ssh.ts` | SSH 远程执行 | `registerFlag`, `on("user_bash")`, `on("before_agent_start")`, 工具操作 |
| `interactive-shell.ts` | 持久 shell 会话 | `on("user_bash")` |
| `sandbox/` | 沙盒工具执行 | 工具操作 |
| `subagent/` | 生成子 agent | `registerTool`, `exec` |
| **游戏** |||
| `snake.ts` | 贪吃蛇游戏 | `registerCommand`, `ui.custom`, 键盘处理 |
| `space-invaders.ts` | 太空侵略者游戏 | `registerCommand`, `ui.custom` |
| `doom-overlay/` | 覆盖中的 Doom | `ui.custom` with overlay |
| **Providers** |||
| `custom-provider-anthropic/` | 自定义 Anthropic 代理 | `registerProvider` |
| `custom-provider-gitlab-duo/` | GitLab Duo 集成 | `registerProvider` with OAuth |
| **消息与通信** |||
| `message-renderer.ts` | 自定义消息渲染 | `registerMessageRenderer`, `sendMessage` |
| `event-bus.ts` | 扩展间事件 | `pi.events` |
| **会话元数据** |||
| `session-name.ts` | 为选择器命名会话 | `setSessionName`, `getSessionName` |
| `bookmark.ts` | 为 /tree 添加书签条目 | `setLabel` |
| **杂项** |||
| `antigravity-image-gen.ts` | 图像生成工具 | `registerTool`, Google Antigravity |
| `inline-bash.ts` | 工具调用中的内联 bash | `on("tool_call")` |
| `bash-spawn-hook.ts` | 执行前调整 bash 命令、cwd 和环境 | `createBashTool`, `spawnHook` |
| `with-deps/` | 带 npm 依赖的扩展 | 带 `package.json` 的包结构 |
