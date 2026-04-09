# pi-mono Zig 重写项目任务规划

## 项目背景
将 [badlogic/pi-mono](https://github.com/badlogic/pi-mono) 这个 TypeScript monorepo 使用 **Zig 语言**重写实现。
原始项目包含以下 7 个包：
- `pi-ai`: 多 provider 统一 LLM API
- `pi-agent-core`: Agent 运行时（状态管理、事件流、工具调用）
- `pi-tui`: 终端 UI 库（差异渲染）
- `pi-coding-agent`: 交互式编程 Agent CLI（核心产品）
- `pi-mom`: Slack Bot
- `pi-web-ui`: Web Chat UI 组件
- `pi-pods`: vLLM GPU Pod 管理 CLI

## 重写策略
1. 按**依赖顺序**从底层包向上层实现。
2. 优先实现 **pi-ai → pi-agent-core → pi-tui → pi-coding-agent 核心链路**，其他包可后置。
3. Zig 特性：手动内存管理（Arena 为主）、`std.json`/`std.http` 替代 npm 包、跨平台 TUI 基于 `std.io` + ANSI escape sequences。

---

## 任务清单

### Phase 0: 基础设施 (Priority: P0)
- [ ] **0.1 初始化 Zig 项目结构**
  - 建立 `build.zig` + `build.zig.zon` 的多模块 workspace 布局
  - 各模块：`ai/`, `agent/`, `tui/`, `coding-agent/`, `mom/`, `pods/`, `shared/`
  - 统一 `build.zig` 中导出 `zig fetch` 可用的模块
- [ ] **0.2 公共类型与工具 (`shared/`)**
  - JSON Schema 极简替代（无需 TypeBox，目标自足）
  - 通用事件流通道（`std.Thread` + `std.atomic.Queue`/`Channel`）
  - 路径/文件 helper、HTTP client wrapper（`std.http.Client`）
  - 配置加载（环境变量 + YAML/JSON）

---

### Phase 1: `pi-ai` → `ai/` (P0)
- [ ] **1.1 Core Types & Streaming Abstractions**
  - 对齐 TS 类型：`Message`, `AssistantMessage`, `ToolResultMessage`, `Context`, `Model`, `Tool`
  - 实现流事件枚举：`text_start`/`text_delta`/`text_end`、`toolcall_start`/`delta`/`end`、`thinking_*`、`done`、`error`
  - 构建 `EventStream` 与 `StreamFn` 抽象
- [ ] **1.2 Provider Registry & Unified API**
  - `registerApiProvider` / `getProviders` / `getModels` / `getModel`
  - `stream()` / `complete()` / `streamSimple()` / `completeSimple()` 多态分发
  - 环境变量 API Key 解析（对齐 README 中的环境变量表）
- [ ] **1.3 Provider Implementations（逐个实现）**
  | Provider | 复杂度 | 说明 |
  |----------|--------|------|
  | `faux` | L | 用于测试的内存 provider，先实现以利后续测试 |
  | `anthropic-messages` | M | SSE 流 + Tool 调用 |
  | `openai-completions` | M | OpenAI 兼容 API，含大量 `compat` 逻辑 |
  | `openai-responses` | M | OpenAI Responses API |
  | `google-generative-ai` | M | Gemini API |
  | `azure-openai-responses` | L | Azure 变体 |
  | `google-vertex` | L | Vertex AI |
  | `mistral-conversations` | L | Mistral |
  | `amazon-bedrock` | H | AWS 签名 v4 + Converse 流 |
  | 其他 OAuth (Copilot, Codex, Gemini CLI) | H | 需实现 OAuth/PKCE/token 刷新 |
- [ ] **1.4 Tool Validation**
  - 用 Zig 实现轻量 JSON Schema validator（支持 `object`/`string`/`number`/`array`/`boolean`）
  - `validateToolArguments` 和 `validateToolCall`
- [ ] **1.5 Context Serialization & Cross-Provider Handoff**
  - 消息序列化/反序列化（JSON）
  - thinking 块自动转 `<thinking>` 标签的兼容性处理
- [ ] **1.6 Tests**
  - 单元测试：事件流、工具验证、faux provider
  - 集成测试：至少覆盖 anthropic / openai / google 三家的流式对话+工具调用

---

### Phase 2: `pi-agent-core` → `agent/` (P0)
- [ ] **2.1 Agent Types**
  - `AgentMessage`、`AgentTool`、`AgentState`、`AgentEvent`、`AgentContext`、`AgentLoopConfig`
  - 自定义消息扩展机制（用 Zig `union` + `tag` 模拟 declaration merging）
- [ ] **2.2 Agent Loop (`agent-loop`)**
  - `runAgentLoop` / `runAgentLoopContinue`
  - 嵌套循环：外层 follow-up、内层 turn + steering
  - `streamAssistantResponse`（消息转换 → LLM 调用）
  - `executeToolCalls`（支持 `sequential` / `parallel` 模式）
- [ ] **2.3 Agent Class (`agent`)**
  - 状态与队列管理（`steeringQueue`、`followUpQueue`）
  - 事件订阅系统（listener + async barrier）
  - 生命周期：`prompt()`、`continue()`、`abort()`、`reset()`、`waitForIdle()`
  - `beforeToolCall` / `afterToolCall` hooks
- [ ] **2.4 Proxy / Stream Wrapper**
  - `streamProxy` 或等价的自定义后端代理接口
- [ ] **2.5 Tests**
  - 模拟 faux provider 的事件序列断言（如 prompt → agent_start → turn_start → ... → agent_end）
  - 工具调用顺序/并行测试
  - steering / follow-up 测试

---

### Phase 3: `pi-tui` → `tui/` (P0)
- [ ] **3.1 Terminal Abstraction**
  - `Terminal` interface：raw mode、resize、Kitty protocol query、Windows VT input、光标控制
  - `ProcessTerminal` 实现（基于 `std.io` 文件描述符）
  - `StdinBuffer`：输入序列分片 + bracketed paste
- [ ] **3.2 Key Handling**
  - `parseKey` / `matchesKey` / `isKeyRelease`
  - Kitty keyboard escape sequence 解析
- [ ] **3.3 Component System (`TUI` + `Container`)**
  - `Component` interface：`render(width)`、`handleInput`、`invalidate`
  - `Container`、`Focusable`、`CURSOR_MARKER`
  - 差异渲染：对比 `previousLines` 与当前 lines，仅输出 diff
  - Overlay 系统（定位、焦点、显隐）
- [ ] **3.4 Built-in Components**
  - `Box`、`Text`、`Spacer`
  - `Editor`（含 kill-ring、undo-stack）
  - `Input`（单行输入 + autocomplete 接口）
  - `Markdown`（简化 markdown 渲染，支持 ANSI）
  - `SelectList`、`SettingsList`
  - `Image`（Kitty / iTerm2 image protocol）
  - `Loader`、`CancellableLoader`
- [ ] **3.5 Utilities**
  - `visibleWidth`、`truncateToWidth`、`wrapTextWithAnsi`
  - `fuzzyMatch` / `fuzzyFilter`
  - `KeybindingsManager`
- [ ] **3.6 Tests**
  - 差异渲染快照测试
  - 输入解析 roundtrip 测试
  - 组件渲染宽度边界测试

---

### Phase 4: `pi-coding-agent` → `coding-agent/` (P0)
- [ ] **4.1 CLI 入口 (`cli`)**
  - 参数解析（对齐 TS 的 `Args`：`--model`、文件参数、`--session`、`--resume`、`--continue`、`--fork` 等）
  - 环境配置目录（`.pi`）
  - 初始消息构建（文件处理 + stdin pipe + 图片 downscale）
- [ ] **4.2 Core Services**
  - `SettingsManager`：配置加载与错误收集
  - `SessionManager`：会话 CRUD、fork、全局搜索
  - `ModelRegistry` / `ModelResolver`：模型选择、作用域模型
  - `AuthStorage`：API Key / OAuth 凭证本地存储（JSON 文件）
- [ ] **4.3 Tools (`core/tools`)**
  从 TS `allTools` 逐一对等迁移到 Zig：
  - `read`（含 offset/limit、图片 resize、截断提示）
  - `bash`（含 timeout、尾部截断、temp file）
  - `edit`（exact replacement + diff 生成）
  - `write`（文件写入）
  - `grep`（ripgrep 封装）
  - `find`（文件搜索）
  - `ls`（目录列表）
- [ ] **4.4 Agent Session Runtime**
  - `AgentSession`、`AgentSessionRuntime`、`AgentSessionServices`
  - 系统提示词组装、工具注入、扩展系统（hooks / extensions）
- [ ] **4.5 Modes**
  - `print-mode`：非 TTY 输出（文本/JSON）
  - `rpc-mode`：JSONL RPC
  - `interactive-mode`：TUI 主循环（最复杂，依赖 `pi-tui`）
- [ ] **4.6 Interactive TUI Mode**
  - 消息列表渲染（User / Assistant / Tool / Image）
  - 底部输入框（Editor + 斜杠命令 / model 选择器）
  - 工具执行实时渲染（bash spinner、文件 diff、图片预览）
  - 会话选择器、设置面板、Model Scope 选择器
  - 主题系统（dark/light + 自定义 JSON theme）
- [ ] **4.7 Tests & Dogfooding**
  - CLI arg 单元测试
  - 各 tool 本地文件系统 mock 测试
  - 端到端：用 `faux` provider 跑完整交互回合

---

### Phase 5: `pi-mom` / `pi-pods` / `pi-web-ui` (P1)
- [ ] **5.1 `mom/` — Slack Bot**
  - 事件监听（Slack Events API / Socket Mode）
  - 消息代理到 coding-agent
- [ ] **5.2 `pods/` — vLLM Pod CLI**
  - SSH 远程命令执行
  - 模型配置管理
- [ ] **5.3 `web-ui/` — Web UI（可选）**
  - 若保留：用 Zig 编译为 WASM + JS shim 提供 Web 组件
  - 或作为 P2 长期目标，先放弃 Web 层聚焦 CLI

---

## 关键技术决策

| 领域 | 决策 |
|------|------|
| **内存管理** | 以 `std.heap.ArenaAllocator` 为顶层分配器，长生命周期对象用 `gpa`，流式数据块及时释放 |
| **并发** | Agent loop 与 TUI 各自运行在独立线程；通过阻塞 channel / mutex 传递事件 |
| **HTTP / SSE** | `std.http.Client` + 自定义 SSE parser；不支持 async/await，用同步读流 + 独立线程 |
| **JSON** | `std.json`（Zig 原生），Schema 校验手写精简 validator |
| **图片处理** | 可选：调用系统 `ffmpeg` / `magick` 或嵌入 stb_image 等 C 库做 resize |
| **diff 渲染** | 移植核心逻辑，ANSI 高亮自实现 |
| **OAuth / HTTPS** | `std.crypto.tls.Client` + `std.http.Client`；OAuth flow 用浏览器打开 + local redirect server |
| **外部命令** | `std.process.Child` 封装 ripgrep、sed、bash |

---

## 里程碑

| 阶段 | 目标 | 可验证成果 |
|------|------|-----------|
| M0 | Phase 0 完成 | `zig build` 成功，各模块可被 `import` |
| M1 | Phase 1 完成 | `ai` 模块通过集成测试（faux + 1 个真实 provider） |
| M2 | Phase 2 完成 | `agent` 模块通过事件序列与工具执行测试 |
| M3 | Phase 3 完成 | `tui` 差异渲染与组件系统跑通 demo |
| M4 | Phase 4 完成 | 可运行 `zig build run -- "Hello"` 并完整完成一次对话+工具调用 |
| M5 | Phase 5 可选 | Slack bot / pods CLI 可用 |

---

## 风险与注意事项

1. **OAuth 复杂度**：GitHub Copilot、OpenAI Codex 的 OAuth 流程在 Zig 中需手写 PKCE + token 刷新，建议延后。
2. **TUI 复杂度**：差异渲染、Kitty protocol、Windows 控制台兼容是最大工时黑洞，建议先做最小可用版（无 Kitty image）再迭代。
3. **图片处理**：Zig 生态缺少原生图像处理库，初期可先用外部命令（ImageMagick）降级方案。
4. **AWS Bedrock**：签名算法 v4 需精确实现，若时间有限可初始跳过。
5. **测试策略**：依赖真实 LLM 的测试成本高，优先用 `faux` provider 做回归测试。
