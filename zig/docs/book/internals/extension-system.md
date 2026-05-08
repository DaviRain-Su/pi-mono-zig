---
title: 扩展系统设计研究
---

# 扩展系统设计研究

> 这份文档不是普通的模块卷宗——它是**前瞻设计文档**。
>
> 一半描述：TS 端的扩展系统已经成熟（73 个示例、35+ 钩子、11 个 UI 方法），是必须继承的规格。
> 一半提案：Zig 端的扩展系统应该长什么样、按什么顺序构建、哪些设计决议必须先拍板。
>
> **整本书的"骨架完成"以这份文档为准。**所有未来的上层功能（plan 模式、子 agent、自定义 provider、TUI 游戏插件）都建立在这套机制上。

## §0 · 这份文档要解决的问题

用户原话：

> "核心是这个扩展的设计，即如何去实现它。类似于 TS 版具有的扩展能力，而我们是用 Zig 实现的，所以这一部分我们需要好好研究。后续在扩展的基础上，我们还要在做更多上层功能的开发，所以这个东西需要仔细研究出来。"

翻译成工程问题：

1. **现状盘点**：TS 端扩展系统是什么形状？它支持什么？73 个示例覆盖哪些场景？
2. **差距识别**：Zig 端目前实现了多少？还差什么？
3. **设计提案**：Zig 端应该如何在保持身份（native 性能 + C ABI 友好）的同时，承接 TS 端那个庞大的扩展生态？
4. **路线图**：从 v0.1 草案到 v1.0 冻结，分几步？每一步的产出是什么？

---

## §1 · 继承一份成熟的规格：TS 端的扩展表面

### 1.1 TS 扩展能做什么——按能力分类

| 类别 | 代表能力 | 对应的 TS API |
| --- | --- | --- |
| **工具注册** | 注册 LLM 可调的工具 | `registerTool(def)` |
| **工具拦截** | 在执行前/后修改/拦截 | `on('tool_call')`, `on('tool_result')` |
| **生命周期钩子** | 35+ 事件钩子 | `on(eventName, handler)` |
| **UI 交互** | 11 种弹层/对话/编辑器 | `ctx.ui.{select, confirm, input, custom, ...}()` |
| **斜杠命令** | 自定义 `/command` | `registerCommand(name, handler)` |
| **键盘绑定** | 注册快捷键 | `registerShortcut(key, handler)` |
| **CLI 标志** | 自定义命令行 flag | `registerFlag(name, type)` |
| **Provider 扩展** | 添加 LLM provider | `registerProvider(name, config)` |
| **子 Agent 委派** | 创建有界子 agent | `createSubAgentExtension()` |
| **跨扩展通信** | 事件总线 | `pi.events.emit/on()` |
| **会话状态** | 持久化自定义数据 | `appendEntry(type, data)` |
| **消息渲染** | 自定义消息类型显示 | `registerMessageRenderer(type, fn)` |

**总计**：8 个 API 注册点 + 35+ 事件钩子 + 11 个 UI 方法 = **约 54 个独立扩展点**。

### 1.2 35+ 生命周期钩子的全貌

```mermaid
flowchart TB
    classDef session fill:#1a3a5c,stroke:#3b82f6,color:#fff
    classDef agent fill:#4a3520,stroke:#d97706,color:#fff
    classDef tool fill:#064e3b,stroke:#10b981,color:#fff
    classDef provider fill:#2d1b3d,stroke:#a855f7,color:#fff
    classDef ui fill:#7c2d12,stroke:#ea580c,color:#fff

    SS[session_start<br/>session_before_switch<br/>session_before_fork<br/>session_before_compact<br/>session_compact<br/>session_shutdown<br/>session_before_tree<br/>session_tree]:::session

    AG[before_agent_start<br/>agent_start<br/>agent_end<br/>turn_start<br/>turn_end<br/>message_start<br/>message_update<br/>message_end<br/>model_select<br/>thinking_level_select]:::agent

    TL[tool_call<br/>tool_result<br/>tool_execution_start<br/>tool_execution_update<br/>tool_execution_end<br/>user_bash<br/>input]:::tool

    PR[before_provider_request<br/>after_provider_response<br/>context]:::provider

    UI[resources_discover<br/>(UI events through ctx.ui)]:::ui
```

钩子按"语义阶段"分四组：

| 组 | 数量 | 用途 |
| --- | --- | --- |
| Session lifecycle | 8 | 会话切换、fork、compact、tree 操作 |
| Agent / Message | 10 | Agent 与 LLM 对话生命周期 |
| Tool execution | 7 | 工具执行的所有阶段 + 输入拦截 |
| Provider / Context | 3 | LLM 请求/响应/消息上下文修改 |
| Resources | 1 | 启动时贡献 skill/prompt/theme |

**钩子调用语义**（关键，Zig 必须复刻）：

- **顺序**：按扩展注册顺序串行调用
- **异步**：每个 handler 被 await 完成才走下一个
- **错误隔离**：handler 异常不影响其他扩展，仅记录日志
- **结果链式**：某些钩子（`context`、`tool_call`）后续 handler 看到前一 handler 的修改
- **可取消**：某些"before_X"钩子可以返回 `{ cancel: true }` 短路操作

### 1.3 73 个示例的"广度证据"

73 个示例聚成 18 个类别，证明**扩展不是玩具**——它实际承担了产品级功能：

| 类别 | 数量 | 关键代表 |
| --- | --- | --- |
| 工具注册 / 覆盖 | 7 | `dynamic-tools`, `tool-override` |
| 工具拦截 / 守卫 | 6 | `permission-gate`, `confirm-destructive`, `protected-paths` |
| Provider 扩展 | 3 | `custom-provider-anthropic`, `custom-provider-gitlab-duo` |
| 子 Agent 委派 | 1 | `subagent/` |
| UI 弹层 / 编辑器 | 7 | `modal-editor`, `rainbow-editor`, `custom-header` |
| 消息渲染 | 4 | `message-renderer`, `structured-output` |
| 会话状态 / 导航 | 4 | `bookmark`, `git-checkpoint` |
| 系统提示 / 上下文 | 3 | `prompt-customizer`, `claude-rules` |
| 跨扩展通信 | 2 | `event-bus` |
| 模式覆盖 | 3 | `plan-mode/`, `minimal-mode` |
| 输入/输出变换 | 5 | `input-transform`, `provider-payload` |
| 状态显示 / 通知 | 4 | `status-line`, `model-status` |
| 命令 / CLI | 5 | `commands`, `qna`, `handoff` |
| 终端交互 | 4 | `interactive-shell`, `border-status-editor` |
| 流程守卫 | 3 | `dirty-repo-guard`, `auto-commit-on-exit` |
| **完整 TUI 游戏** | 4 | `snake`, `space-invaders`, `tic-tac-toe`, `doom-overlay/` |
| 测试 / 配套 | 6 | `rpc-demo`, `preset`, `with-deps/` |
| 单一用途 | 7 | `pirate`, `ssh`, `mac-system-theme` |

::: tip 一个值得回味的事实
**有 4 个示例是完整的 TUI 游戏**——`snake.ts`、`space-invaders.ts`、`tic-tac-toe.ts`、`doom-overlay/`。这证明扩展接口足够通用，可以承载**任意复杂的 TUI 应用**。这是好的扩展系统的标志：用户能"在它上面做你完全没想过的事"。
:::

---

## §2 · Zig 端：现在到了哪里

### 2.1 已实现 vs 缺失（按 TS 表面对照）

| TS 能力 | Zig 状态 | 详情 |
| --- | --- | --- |
| 工具注册 | ✅ 已实现 | `ExtensionRegistry.registerTool` 三种 runtime 都支持 |
| 工具的三个 export（metadata/schema/execute） | ✅ 已实现 | WASM v0 contract 验证通过 |
| 35 个事件钩子 | 🟡 部分 ~40% | 仅约 15 个；缺 `tool_call`/`tool_result`/`message_update`/`input` 等核心 |
| 11 个 UI 方法 | ❌ 缺失 | 完全没有 |
| 自定义斜杠命令 | ❌ 缺失 | 计划在 MCP 风格 commands 里 |
| 键盘绑定 | ❌ 缺失 | TUI 还没暴露给扩展 |
| 自定义 CLI 标志 | 🟡 部分 | 有枚举式 ExtensionFlags，但不是动态的 |
| Provider 注册 | 🟡 部分 | 内部注册表存在；扩展 API 没暴露 |
| 子 Agent 委派 | 🟡 部分 | agent.spawn 框架存在；扩展 hook 没接 |
| 跨扩展事件总线 | ❌ 缺失 | 完全没有 |
| 工具自定义渲染 | ❌ 缺失 | TS 有 renderCall/renderResult |
| 消息渲染钩子 | ❌ 缺失 | 完全没有 |
| 会话持久化（appendEntry） | ✅ 已实现 | `SessionManager.appendCustomEntry` |
| 默认拒绝的能力检查 | ✅ 已实现 | 12 个 capability + Principal |
| WASM v0 工具 | ✅ 已实现 | 自实现解释器（spike），fixture 验证通过 |

**整体覆盖率：约 35%**——核心机制（注册表、能力、WASM 加载）有了，但**事件系统的覆盖度严重不足，UI 完全空白**。

### 2.2 三种 runtime 的当前形态

```mermaid
flowchart LR
    classDef ok fill:#064e3b,stroke:#10b981,color:#fff
    classDef partial fill:#78350f,stroke:#d97706,color:#fff
    classDef stub fill:#7f1d1d,stroke:#dc2626,color:#fff

    Native[native runtime<br/>Zig fn ptr]:::ok
    Wasm[wasm runtime<br/>自实现 spike]:::partial
    Process[process_jsonl<br/>子进程 + JSONL]:::ok
    Remote[remote runtime<br/>占位]:::stub

    Native -->|工具集成测试用| Use1[内部使用]
    Wasm -->|JSON 字符串桥接| Use2[实验]
    Process -->|TS 扩展走这条| Use3[实际使用]
    Remote -->|未实现| Use4[空]
```

::: warning 实际状况
**`process_jsonl` 是当前唯一被实际使用的扩展运行时**——TS 写的扩展通过子进程跑。`native` 和 `wasm` 都是为未来准备的。这意味着如果要在 Zig 重写中保留 TS 扩展的 73 个示例，**短期路径只有 process_jsonl**。
:::

---

## §3 · 已锁的 5 条 RFC 决议

仓库 `zig/docs/wasm-extension-*.md` 和 `wasm-component-model-decision.md` 已经做了基础架构层的拍板：

| # | 决议 | 来源 | 含义 |
| --- | --- | --- | --- |
| **R-1** | 不用 Extism / 不用 Component Model（v0 阶段） | `wasm-component-model-decision.md` | 工具链不就位（jco / componentize-js / wasmtime 都不在 project-local），暂时用 JSON 字符串自实现 |
| **R-2** | 保留 Bun TS 扩展通路 | `wasm-extension-architecture-rfc.md` | 兼容性边界——TS 扩展不会被强制重写 |
| **R-3** | WASM v0 仅工具，无 UI / 命令 / provider | `wasm-extension-final-closure.md` | v0 的 wasm 只能注册工具，其他扩展点不开放 |
| **R-4** | 默认拒绝的 8 个 canonical capabilities | `wasm-extension-architecture-rfc.md` | host 强制；manifest 只能"申请"，最终决定权在 host |
| **R-5** | v1 目标产物 = WASM Component + WIT | `wasm-component-model-decision.md` | 长期方向，v0 的 JSON 字符串只是过渡 |

::: info 已有 8 capabilities → 现在扩到 12
RFC 时是 8 个 capabilities（file.read, file.write, network, shell, env, model, session, ui.notify）。`coding_agent` 卷宗 §6 显示当前代码已经扩到 **12 个**（多了 `tool.use`, `agent.spawn`, `agent.delegate`, `session_read/write` 拆分）。RFC 文档需要回填更新。
:::

---

## §4 · 三个必须现在拍板的架构问题

R-1 ~ R-5 是过去的决议，但还有**三个必须现在决定**的开放问题，它们决定了扩展系统的基本形态：

### Q1 · 扩展机制的"主路径"是 process_jsonl 还是 WASM？

```mermaid
flowchart TB
    classDef now fill:#064e3b,stroke:#10b981,color:#fff
    classDef future fill:#1a3a5c,stroke:#3b82f6,color:#fff

    subgraph "选项 A：process_jsonl 主路径"
        A1[今天就能跑 73 个 TS 示例]:::now
        A2[扩展用任何语言写都行]:::now
        A3[OS 级隔离, 安全度 OK]:::now
        A4[启动慢 ~50-200ms]:::now
        A5[长期不需要 WASM 工具链]:::now
    end

    subgraph "选项 B：WASM 主路径"
        B1[启动快 ~5ms]:::future
        B2[沙箱更细粒度（内存上限）]:::future
        B3[但工具链还没就绪]:::future
        B4[v1 目标长期合理]:::future
    end
```

**我的提案：双轨并行，process_jsonl 作为 v0/v0.5 的主路径，WASM 作为 v1.0 目标**。

理由：

1. TS 端 73 个示例**必须能在 v0.5 跑**，否则迁移期生态会撕裂。WASM v0 限制（仅工具、无 UI）盖不住 TS 用例。
2. WASM 工具链投资（jco / componentize-js / wasmtime 集成）大；今天就投不划算，等 1-2 个真实 binding 落地再投。
3. process_jsonl 的实现已经在用，不需要新工作量。

### Q2 · UI 扩展表面到底要不要"完整移植"？

TS 有 11 个 UI 方法（dialog / overlay / editor / header / footer / 等）。这些深度依赖 TS TUI 库。Zig 有自己的 TUI（在 `zig/src/tui/`）。

```mermaid
flowchart LR
    classDef yes fill:#064e3b,stroke:#10b981,color:#fff
    classDef partial fill:#78350f,stroke:#d97706,color:#fff
    classDef no fill:#7f1d1d,stroke:#dc2626,color:#fff

    A[选项 A：完整移植 11 个]:::yes
    A --> A1[兼容 6 个 UI 重度示例]
    A --> A2[巨大的工作量]
    A --> A3[Zig TUI 必须先达到 TS 同等表达力]

    B[选项 B：子集移植]:::partial
    B --> B1[只做 select/confirm/input/notify]
    B --> B2[复杂的 overlay/editor 让 TS 扩展走 process_jsonl 时回调 TS UI]
    B --> B3[v0.5 可达]

    C[选项 C：完全跳过]:::no
    C --> C1[扩展不能动 UI]
    C --> C2[snake.ts / doom-overlay 这类示例无法迁移]
    C --> C3[扩展生态严重受限]
```

**我的提案：B（子集移植）+ 一种"UI 透传"机制**。

具体：

- Zig 原生扩展（native runtime）能调 4 个基本 UI 方法（`select`、`confirm`、`input`、`notify`），定义在 `pi_ui.h` 中
- 复杂 UI 重度的扩展继续走 process_jsonl，让 TS host 进程渲染 UI（Zig 主进程通过 RPC 把屏幕区域 "借给" 子进程）
- v0.5 后再决定是否扩到完整 11 方法

### Q3 · 35 个钩子要不要全实现？还是分阶段？

```mermaid
flowchart TB
    classDef p0 fill:#7f1d1d,stroke:#dc2626,color:#fff
    classDef p1 fill:#78350f,stroke:#d97706,color:#fff
    classDef p2 fill:#1a3a5c,stroke:#3b82f6,color:#fff
    classDef p3 fill:#064e3b,stroke:#10b981,color:#fff

    P0["Phase 0 (现在)<br/>session_start, agent_start/end<br/>~5 个钩子"]:::p0
    P1["Phase 1 (v0.5)<br/>+ tool_call, tool_result, message_*, turn_*<br/>~15 个钩子"]:::p1
    P2["Phase 2 (v0.7)<br/>+ before_provider_request, context, input<br/>~25 个钩子"]:::p2
    P3["Phase 3 (v1.0)<br/>+ session_before_*, model_select, resources_discover<br/>~35 个钩子"]:::p3

    P0 --> P1 --> P2 --> P3
```

**我的提案**：4 阶段递进，**Phase 1（v0.5）是关键里程碑**——`tool_call` 和 `tool_result` 是 73 个示例里使用最多的钩子，没这两个扩展系统就是空架子。

---

## §5 · 推荐设计：三层扩展模型

把上面三个问题的答案合起来，扩展系统应该是这样：

```mermaid
flowchart TB
    classDef tier1 fill:#064e3b,stroke:#10b981,color:#fff
    classDef tier2 fill:#1a3a5c,stroke:#3b82f6,color:#fff
    classDef tier3 fill:#4a3520,stroke:#d97706,color:#fff

    Subgraph[" "]
    Host["Zig Host<br/>(Agent + Tools + Sessions)"]

    Tier1["Tier 1 · Native Extensions<br/>Zig fn ptr / 编译期注册<br/>完全信任 / 性能最高<br/>用例：内置 plan 模式、内部测试"]:::tier1

    Tier2["Tier 2 · Process_JSONL Extensions<br/>子进程 + JSONL stdio<br/>能力检查 / 任意语言<br/>用例：TS/Python/Go 扩展<br/>承接 73 个 TS 示例"]:::tier2

    Tier3["Tier 3 · WASM Extensions<br/>自实现解释器 (v0/0.5)<br/>未来 wasmtime + Component Model (v1.0)<br/>用例：跨平台沙箱工具<br/>v0 限制：仅工具"]:::tier3

    Host --- Tier1
    Host --- Tier2
    Host --- Tier3
```

### 5.1 三层的差异

| 维度 | Tier 1 (native) | Tier 2 (process_jsonl) | Tier 3 (wasm) |
| --- | --- | --- | --- |
| 安全度 | 无沙箱（编译期受控） | OS 进程隔离 | WASM 沙箱 |
| 性能 | 最快（纳秒） | 中（毫秒，IPC） | 中（毫秒，解释器） |
| 启动延迟 | 0 | 50-200ms（spawn） | 5-50ms（load） |
| 语言 | 只能 Zig | 任意 | 编译到 WASM 的 |
| 何时用 | 内置功能 / 性能关键 | 现有 TS 生态 / 多语言 | 跨平台 / 强沙箱需求 |
| 接口稳定性 | 编译期 | JSONL 协议 | WIT 契约 |

### 5.2 三层共用的"骨架"

不管哪一层，扩展都要回答**同样 4 个问题**：

```
1. 我是谁？               → ExtensionId, runtime_kind, package_root
2. 我想要什么权限？        → declared_capabilities (12 grants 的子集)
3. 我能干什么？            → registered_tools / hooks / commands / ...
4. 我什么时候被调用？      → 35 个生命周期钩子的订阅
```

这 4 个答案统一塞进一个 `ExtensionDescriptor` 数据结构，**三层 runtime 解析自己的产物（fn ptr / JSON / WASM 模块）填充这同一个 struct**。这样上层（Agent loop / Tool dispatcher）不用关心 runtime 类型——它只看 `ExtensionDescriptor`。

---

## §6 · 钩子分类与命名标准

35 个钩子按命名风格统一成 4 组：

```
session.{start, end, before_compact, before_fork, before_switch, before_tree, compact, tree}
agent.{before_start, start, end, model_select, thinking_select}
turn.{start, end, message_start, message_update, message_end}
tool.{call, result, execution_start, execution_update, execution_end}
input.{user_text, user_bash}
provider.{before_request, after_response, context}
resources.{discover}
```

::: tip 命名规则
- **`X.before_Y`** = 可取消的 pre-hook，返回 `{ cancel: true, reason }` 短路
- **`X.Y`** = 通知性钩子，返回值忽略
- **数据修改钩子** = 接受 mutable 引用，handler 修改后续 handler 见到的是新版

这套规则与 TS 端语义完全等价，但**命名分隔符更系统化**（点号代替下划线分隔区段）——这是 Zig 风格的小改进。
:::

### 6.1 钩子签名（C ABI 视角）

每个钩子最终落到 C ABI 上是这个统一形态：

```c
typedef int (*pi_hook_fn)(
    void*                 user_data,
    pi_hook_event_type_t  type,
    const pi_hook_event_t* event,    /* opaque, type-specific getters */
    pi_hook_result_t*      out_result /* nullable; for cancellable hooks */
);

pi_status_t pi_extension_subscribe(
    pi_extension_t*  ext,
    pi_hook_event_type_t type,
    pi_hook_fn       fn,
    void*            user_data
);
```

**一个回调函数处理所有事件类型**——通过 `type` 分发，通过 type-specific getter 拿数据。这避免在 C ABI 上炸出 35 个不同形状的回调签名。

---

## §7 · UI 扩展模型（Tier 2 透传方案）

```mermaid
sequenceDiagram
    participant Ext as Tier 2 Extension<br/>(子进程, TS)
    participant Host as Zig Host
    participant TUI as Zig TUI

    Ext->>Host: JSONL: {"method":"ui.confirm", "id":1, "prompt":"Delete?"}
    Host->>TUI: 渲染 confirm 对话框
    TUI->>Host: 用户选了 yes/no
    Host->>Ext: JSONL: {"id":1, "result": true}
    Ext->>Ext: 继续执行
```

**关键设计**：UI 调用通过 JSONL 协议双向传递。Zig host 接收 `ui.X` 消息→调用本地 TUI 渲染→把结果送回扩展。这意味着：

- **Zig TUI 只需要实现 4 个基本 UI 方法**（select / confirm / input / notify）
- **复杂 UI（overlay / editor / custom）通过 RPC 委派给 TS 子进程自己渲染**——主进程"借出"屏幕区域
- **Tier 1 native 扩展直接调 Zig TUI 函数**，不走 RPC

这避免了 Zig TUI 必须达到 TS TUI 完整表达力的工作量。

---

## §8 · 能力边界（与 §6 of coding_agent 卷宗对齐）

扩展请求能力，host 决定是否授予：

```mermaid
flowchart LR
    M[Manifest declares<br/>'I want shell, network'] --> Host
    Host{Policy approve?}
    Host -->|yes| G[Grant in Principal]
    Host -->|no| D[Deny load / show diagnostic]
    G --> Run[Extension runs]
    Run --> Op[Operation: shell.run]
    Op --> Check{Principal has shell?}
    Check -->|yes| Exec[Execute]
    Check -->|no| Reject[is_error: Permission denied]
```

**两次检查**：
1. **加载时**：manifest 的 `requires` 与 host policy 的 `approved_grants` 求交，差集若非空则拒绝加载
2. **运行时**：每次工具/操作执行检查 Principal 是否有需要的 grant

**与 D-3 决议一致**：内置工具也走这套——内置 Principal 默认全 12 grant，host 可收紧。

---

## §9 · 五阶段路线图

| Phase | 版本 | 内容 | 完成判据 |
| --- | --- | --- | --- |
| **Phase 0** | 当前 | WASM v0 fixture 验证通过；process_jsonl 已经能跑 TS 扩展 | ✅ 已完成 |
| **Phase 1** | v0.2 | 实现 §6 的 `tool.call` / `tool.result` / `message.*` / `turn.*` 钩子（约 15 个）；这是 73 示例里依赖最重的 | ⬜ 1-2 周工作 |
| **Phase 2** | v0.5 | 4 个基本 UI 方法（confirm/select/input/notify）暴露给 Tier 2；JSONL UI 透传机制 | ⬜ 2-3 周工作 |
| **Phase 3** | v0.7 | 自定义斜杠命令 + 键盘绑定；动态 Provider 注册；事件总线 | ⬜ 2-3 周工作 |
| **Phase 4** | v1.0 | 35 个钩子全覆盖；wasmtime 集成 + WIT Component Model | ⬜ 大块工作（5-8 周） |

::: tip 关键里程碑
**Phase 1（v0.2）是真正的"扩展系统能用了"分水岭**——`tool.call` + `tool.result` 钩子让 `permission-gate`、`tool-override`、`confirm-destructive` 这一组拦截类扩展能跑，这是产品级的安全/治理基线。
:::

---

## §10 · 待拍板的设计抉择

在开 Phase 1 实现之前，下面几个问题必须先有答案：

| # | 问题 | 我的提案 | 你需要拍板的 |
| --- | --- | --- | --- |
| **D-7** | 主路径是 process_jsonl 还是 WASM？（§Q1） | 双轨：v0/v0.5 主推 process_jsonl，v1.0 引入 wasmtime | OK 还是想集中精力一条路 |
| **D-8** | UI 表面策略？（§Q2） | 子集 + JSONL 透传 | 同意还是想完整移植 |
| **D-9** | 钩子覆盖节奏？（§Q3） | 4 阶段（5→15→25→35） | 节奏 OK 还是要更激进 |
| **D-10** | 钩子签名是 35 个不同函数 vs 1 个统一函数？ | 1 个统一函数 + type 分发 + getter | 同意 |
| **D-11** | 命名规则：`session.start` 还是 `session_start`？ | 点号分段（`session.start`） | 同意 |
| **D-12** | Tier 1 native 扩展是否暴露给第三方？ | 不暴露——只用于内置功能 | 同意还是想开放 |

---

## §11 · 下一步建议

按工作流排：

1. **拍 D-7 ~ D-12**——这一步必须先做，否则后续工作发散
2. **回填 RFC 文档**——把 capability 从 8 改成 12，把这份设计研究的结论同步进 RFC
3. **更新 `pi.h`**——加上 `pi_extension_subscribe` 等钩子相关的 API
4. **写第 7 章「扩展机制」**——把这份研究的概念部分翻译成教学版
5. **进 Phase 1 实现**——`tool.call` / `tool.result` / `message.*` 钩子在 Zig 里跑通

---

## §12 · 这份文档与其他文档的关系

```mermaid
flowchart LR
    classDef rfc fill:#1a3a5c,stroke:#3b82f6,color:#fff
    classDef internals fill:#4a3520,stroke:#d97706,color:#fff
    classDef chapter fill:#064e3b,stroke:#10b981,color:#fff
    classDef this fill:#7c2d12,stroke:#ea580c,color:#fff

    R1[wasm-extension-*.md<br/>(已有 RFC)]:::rfc
    R2[wasm-component-model-decision.md]:::rfc
    I1[coding_agent 卷宗 §5]:::internals
    THIS[本文档<br/>extension-system.md]:::this
    C7[第 7 章 扩展机制<br/>(待写)]:::chapter

    R1 -->|被本文档引用| THIS
    R2 -->|被本文档引用| THIS
    I1 -->|被本文档引用| THIS
    THIS -->|提供概念基础| C7
    THIS -->|D-7~D-12 决议| Future[Phase 1 实现]
```

---

::: info 文档状态
- 创建：2026-05-08
- 类别：前瞻设计研究（不是单纯的现状描述）
- 关联：所有 7 份 wasm-* RFC + coding_agent 卷宗 §5 + 设计决议 D-1~D-6
- 下一步：等 D-7~D-12 拍板
:::
