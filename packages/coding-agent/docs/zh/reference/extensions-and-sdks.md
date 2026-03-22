# 二次开发手册(扩展、SDK、Provider):中文版

本手册面向:
- 想写 **extension** 的开发者
- 想把 pi 嵌入现有系统的开发者
- 想接入自定义模型/provider 的平台团队

文档聚焦**工程可落地动作**,给出推荐实现路径与关键文件。

---

## 1. 扩展系统入口

扩展通过 `extension` 文件导出 `export default function (pi) { ... }`。
在 `pi` 对象上可使用的 API 在 `packages/coding-agent/src/core/extensions/types.ts` 的 `ExtensionAPI` 与文档 `packages/coding-agent/docs/extensions.md` 中定义。

核心接口(常用):

- `pi.registerTool(...)`
- `pi.registerCommand(...)`
- `pi.registerShortcut(...)`
- `pi.registerFlag(...)`
- `pi.registerProvider(...)`
- `pi.unregisterProvider(...)`
- `pi.registerMessageRenderer(...)`
- `pi.events`(如需跨扩展共享事件总线)
- `pi.on(...)`

扩展执行流程:
1. 由 `DefaultResourceLoader` 在启动时搜集 extension 路径。
2. `extensions/loader.ts` 用 `jiti` 动态加载,支持 package.json / 文件夹 / 目录入口。
3. `ExtensionRunner` 执行 `loadExtensions` 后统一绑定上下文。
4. 命令行/运行时阶段通过 runner 分发事件。

## 2. 资源发现与装载模型(关键)

`DefaultResourceLoader` 是标准入口,典型加载顺序:
- 全局用户扩展(默认路径,非交互/静态)
- 项目级扩展(`cwd/.pi/extensions`)
- 命令行 `--extension` 参数路径
- `package.json` 里的自定义来源(`piConfig` 相关)

推荐做法:
- 优先将"可共享能力"放进扩展(工具/命令/快捷键)。
- 将"环境依赖型能力"写在 host 应用侧(RPC/web host)以避免重复。

## 3. 工具开发(`registerTool`)

`registerTool` 的工具会进入 `Agent` tool loop,具备统一生命周期:
- 用户/模型可见;
- 执行器需返回 `content/details`;
- 支持流式中间结果回调。

你应该在 `context` 中拿到:
- `cwd`(当前会话工作目录)
- `agent` 运行状态(是否空闲、是否有队列)
- `model` / `settings` 等

最佳实践:
- 长任务使用 `onUpdate` 输出进度。
- 统一抛错(`isError`)并返回可读文本块,避免主机渲染阻塞。

## 4. 命令与 UI Hook

### 4.1 命令注册
- `registerCommand(name, { description, execute })`
- 可用于快速触发会话动作(如 `/mycmd`)
- 命令上下文是 `ExtensionCommandContext`(包含 `waitForIdle/newSession/fork/...`)

### 4.2 快捷键与 CLI flag
- `registerShortcut` 适合绑定交互动作
- `registerFlag` 适合 CLI 开关(`--xxx`)

### 4.3 事件钩子
常见扩展事件:
- `agent_start/agent_end`
- `turn_start/turn_end`
- `tool_call/tool_result`
- `message_start/message_update/message_end`
- `session_before_switch/session_before_fork/session_before_compact`
- `before_provider_request`
- `context`

`agent.ts` 与 `agent-session.ts` 会在关键节点触发事件;
在扩展侧可以用于:
- 审计/计时
- 阻断策略(`before_provider_request`、`session_before_compact`)
- 自定义上下文注入

## 5. `pi.registerProvider` / 自定义模型

`ProviderConfig` 的核心用途有三种:

1. **替换现有 provider 的连接参数**
   - 只传 `baseUrl/headers` 时,默认覆盖现有 provider 的模型连接参数。
2. **提供新的 provider+模型集合**
   - `models` 存在时,会替换该 provider 名下所有模型。
3. **自定义 stream handler(高级)**
   - 提供 `streamSimple` 实现时,可完全接管请求/响应转发。

`registerProvider` 与 `unregisterProvider` 调用后会即时生效,不需重启(除文件级 reload 外)。

### 5.1 Provider 注册常见配置
```ts
pi.registerProvider("corp-proxy", {
  baseUrl: "https://proxy.example/v1",
  api: "anthropic-messages",
  apiKey: "CORP_PROXY_API_KEY", // 环境变量名或字面值
  headers: {
    "X-Team": "alpha",
  },
  models: [
    {
      id: "claude-4.0",
      name: "Claude (Corp Proxy)",
      reasoning: true,
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 200000,
      maxTokens: 16384,
    },
  ],
});
```

注意:
- `models` 模式下,定义模型时 `baseUrl` 与鉴权字段应满足校验。
- `models` 中可设置 `api` 覆盖 provider 默认 `api`。

## 6. SDK 嵌入(Node/TS)

`createAgentSession()` 位于 `packages/coding-agent/src/core/sdk.ts`。

典型流程:

```ts
import { createAgentSession } from "@mariozechner/pi-coding-agent";

const { session } = await createAgentSession({
  cwd: process.cwd(),
});

session.subscribe((ev) => {
  if (ev.type === "message_update") {
    // 可按 event.assistantMessageEvent 渲染流式文本
  }
});

await session.prompt("Hello");
```

适合二次开发的能力:
- 事件订阅(`session.subscribe`)
- 手动继续/队列:`steer` / `followUp`
- 会话切换、fork、tree navigate(`session.switchSession` / `fork` / `navigateTree`)
- 模型控制(`session.setModel` / `setThinkingLevel` / `cycleModel`)

### 6.1 与 `@mariozechner/pi-agent-core` 差异
- `createAgentSession` 会把 **资源系统 + 扩展系统 + 命令体系** 全部装配好。
- 直接实例化 `Agent` 则只拿到纯 core 能力,需要你手工实现扩展、模型/会话/工具适配。

## 7. Web UI 嵌入(前端侧)

若你在浏览器场景做嵌入:
- 使用 `@mariozechner/pi-web-ui` 的 `ChatPanel` / `AgentInterface`。
- 通过 `onApiKeyRequired` 提示输入 provider key。
- 若是 Node 环境,可用 `session` 直接绑定;若浏览器,考虑 `RpcClient` + 自定义子进程/服务端桥接。

参考:
- `packages/web-ui/README.md`
- `./embedding-and-rpc.md`

## 8. 常见坑位(请优先检查)

1. **流错误不要 throw**:provider/agent stream contract 需要事件化返回,不要用异常中断主循环。
2. **命令扩展不可直接 queue**:`extension` 命令通常直接执行,不走 `steer/followUp` 队列约束。
3. **树和会话边界**:在 switch/fork 后不要自行重置 `Agent` 消息,优先使用 `session` 提供的 API。
4. **模型名与 API 匹配**:provider 注册错误会在 runtime 报 `Mismatched api...`。
5. **UI 差异**:TUI 与 Web 的事件同源,但输入/快捷键是适配层差异,不要把 UI 假设硬编码到核心。

## 9. "少即是多"：工具集成的实用原则（参考实践）

从实际开发经验看，扩展工具时常见一个问题是"工具过多导致上下文污染"。可执行脚本（Bash/Node）+ 小而专注的 README 常常比复杂的统一协议层更稳定：

- **最小化入口**：每个工具模块只做一件事，例如"启动浏览器"、"导航 URL"、"执行一段 JS"、"截图"。
- **低上下文开销**：与一份 13k~18k token 的大型工具协议相比，精简 README + 代码执行能力可显著减少 prompt 干扰。
- **可组合输出**：工具可输出文件路径/日志/中间产物到磁盘，避免每次都把大块结果塞回对话。
- **可快速扩展**：需要新能力时，优先新增一两个脚本并在 README 补充调用方式，不必改动平台主干。
- **跨会话复用**：把工具脚本放到固定目录并配置 PATH，给不同代理都能共享一套工具集。

结合 `pi` 的扩展模型，推荐实践：
- 把工具描述做成 **短小可读的文档块**（例如项目内的 `browser-tools/README.md` 风格）；
- 在运行前通过命令提示用户读取该 README；
- 用 `registerTool` 暴露"命令名 + 参数 + 例子"，把真正逻辑放在脚本里；
- 对敏感操作（网络、文件系统）在扩展侧加最小权限检查。

该文章核心观点也适配到 pi：
- 优先在 `extensions/` 与 `skills/` 中实现可维护、轻量、可迭代的工具链；
- 不追求"万能工具"，追求"按任务最小充分"的工具集合。

### 9.1 为什么不是MCP

pi **故意** 不将MCP作为核心机制（虽然可以通过扩展添加）。关键区别：

| MCP的问题 | pi的解决方案 |
|----------|-------------|
| 工具需在会话开始时加载 | 扩展可热重载，工具可动态注册 |
| 工具描述占用大量上下文 | Skills渐进式披露，扩展按需加载 |
| 难以修改已有工具行为 | 直接让Agent修改扩展源码 |
| 协议复杂 | Bash+代码，简单直接 |

**推荐做法**：
- 使用 `mcporter` 将MCP工具暴露为CLI接口
- 或用Skill封装功能（如浏览器自动化直接用CDP而非Playwright MCP）
- 让Agent自己编写工具脚本，而非下载预构建的MCP服务器

## 10. 推荐阅读顺序

1. `packages/coding-agent/src/core/extensions/types.ts`(类型与可用 API)
2. `packages/coding-agent/src/core/extensions/runner.ts`(事件分发与注册生效时序)
3. `packages/coding-agent/docs/extensions.md`(英文官方说明)
4. `packages/coding-agent/src/core/model-registry.ts`(provider 注册、models.json 规则)
5. `./model-provider-architecture.md`(本仓库 provider 与 model 的中文架构)
