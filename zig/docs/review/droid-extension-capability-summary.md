# Droid-like Extension Capability Review

Last updated: 2026-05-06.

## 目标

本总结整理前面对 Factory / Droid 相关文档与 Zig Pi 现状的分析，目标不是在 Zig Pi core 中复刻 Droid，而是确认哪些能力应作为扩展、插件或工作流接入，从而保持 Zig Pi core 小、稳定、可维护。

核心原则：

- Core 保持专注：agent/session loop、tool registry、permission/context、TUI integration、extension host。
- 高层能力插件化：Wiki、Missions、Code Review、Droid Control、Automated QA、Droid Shield 都不应成为 core 概念。
- 扩展面稳定：core 只暴露可组合的注册面、事件面、资源面、UI bridge 和策略钩子。
- 产品能力可替换：不同团队可以用自己的扩展实现 wiki、review、QA 或安全策略。

## 能力分层

建议把 Zig Pi 的 Droid-like 能力拆成六层，越往上越接近产品能力，越不应该进入 core。

1. **Core primitives**
   - agent loop
   - session / context
   - provider / tool event stream
   - headless 执行
   - 基础 read / grep / shell / edit 工具
   - TUI surface
   - artifact / report 输出
   - 权限与策略 hook
   - task / subagent invocation substrate
2. **Extension host**
   - manifest
   - tool / command / slash-command / flag / provider / widget / hook 注册
   - event bus
   - capability declaration
   - extension state storage
3. **Primitive extension services**
   - skills
   - hooks
   - MCP adapters
   - RLM / recursive LM runtime adapters
   - custom droids / subagent definitions
   - context providers
   - artifact writers
   - policy packs
4. **Workflow plugins**
   - Wiki
   - Code Review
   - Missions
   - Automated QA
5. **Automation drivers**
   - browser / terminal / desktop 控制
   - 录屏、截图、TUI 操作
6. **Adapters / cloud / enterprise**
   - GitHub / GitLab 评论
   - CI workflow 安装
   - Wiki 上传
   - 企业策略
   - secret rule 更新

## 基础原语补充

前面的路线图如果只写 Wiki、Review、Missions、QA、Control、Shield，会漏掉一些更基础、但很关键的扩展原语。建议在 workflow 之前补齐这些能力。

| 原语 | Zig Pi 定位 | Core 应提供 | 不进 core 的部分 |
|---|---|---|---|
| Task / subagent | 可组合的后台任务与子代理调用基座 | 启动、取消、超时、输入输出 schema、权限继承、artifact 回传、状态事件 | subagent prompt、角色策略、worker pool 策略、mission planner |
| Recursive / sub-LM call ABI | 让一个 LM 可受控调用 sub-LM 或递归推理 runtime | typed signature、sub-call event、trace、sandbox boundary、budget / recursion limit | RLM runtime、DSPy/Pydantic prompt strategy、domain skills |
| Skill registry | 可安装技能的发现与调用 | skill 发现、metadata、按需注入、禁用模型调用标记 | QA 技能内容、review rubric、具体流程 prompt |
| Hook system | 运行时扩展点 | pre-tool、post-tool、pre-shell、pre-edit、session、provider、model、input hooks | Shield 规则、review 策略、企业 policy |
| Permission broker | 统一权限网关 | allow / deny / ask、权限上下文、审计事件、非交互 fallback | 组织策略、云端审批、安全规则库 |
| Artifact channel | 结构化产物输出 | Markdown / JSON / annotation / image / log / video metadata、路径管理、引用协议 | wiki 内容、QA 报告模板、review 格式 |
| Extension state store | 扩展持久化状态 | per-extension kv / checkpoint / cache、schema version、cleanup | mission graph、wiki index、QA learning DB |
| Context providers | 可注册上下文来源 | repo、git diff、session、selection、open files、external resources 的标准接口 | 具体索引器、云知识库、PR 平台逻辑 |
| Model / provider adapter | 可替换模型后端 | provider registry、credentials lookup、model metadata、stream contract | 第三方 provider 产品策略、云端 routing |
| SCM adapter | Git / PR / MR 输入抽象 | local git diff、commit range、annotation artifact schema | GitHub / GitLab API 调用、评论发布、workflow 安装 |
| Automation driver ABI | 控制浏览器 / 终端 / 桌面的驱动接口 | driver capability、permission gate、evidence artifacts、lifecycle | Playwright / browser 实现、录屏、桌面 app adapter |
| Config / manifest schema | 稳定配置面 | extension manifest version、capabilities、resources、permissions、commands | Factory-branded 配置、产品默认 workflow |

其中 **Task / subagent** 是 Missions 的前置原语，但不是 Missions 本身。Core 可以提供“启动一个受控子任务 / 子代理并收集结果”的通用能力；任务拆解、验证策略、worker 角色、mission 状态机都应留在 workflow plugin。

## Pi TS 包生态观察

`https://pi.dev/packages` 显示 Pi 的包系统已经不是单一“内置功能”模型，而是通过 package catalog 分发 extensions、skills、prompt templates、themes。页面显示包可以用 `pi install npm:<package>` 安装，并按 `extension`、`skill`、`theme`、`prompt` 等类型过滤。

值得纳入 Zig Pi 路线图的包生态信号：

- `pi-subagents`
  - 描述为“delegating tasks to subagents with chains, parallel execution, and TUI clarification”。
  - 说明 sub-agent 在 TS 生态中已经作为 package / extension 出现，而不是 core 内置产品功能。
- `pi-mcp-adapter`
  - MCP 作为 extension adapter 接入。
  - 说明第三方协议不应直接进入 core，应通过 extension/adapter 层。
- `context-mode`
  - 提供 context-window 优化、sandboxed code execution、knowledge base、intent-driven search。
  - 说明“上下文优化 / 知识库 / 搜索”这类常见 agent 内置功能，在 Pi 里也适合包化。
- `pi-web-access`、`@ollama/pi-web-search`、`pi-exa`
  - web search / fetch / repo clone / PDF / video 等能力通过工具扩展提供。
- `@plannotator/pi-extension`
  - plan review、annotation、code/PR review 作为扩展包出现。
- `@callumvass/forgeflow-pm`、`@leing2021/super-pi`
  - PM pipeline、compound engineering / iterative workflow 都是更大 workflow package 的例子。

结论：Zig Pi 应延续这个方向。其他 Agent 中常被内置的能力，在 Pi 中优先通过 package / extension 组合接入。Core 不追求“功能全”，而是追求扩展 ABI 稳定、可组合、可审计。

## Extension 组合模型

一个重要架构判断是：更大的 Droid-like 能力不一定是单个 extension，也可以是多个 extension / skill / prompt / adapter 的组合包。

示例组合：

```text
Mission package
  ├─ extension: mission orchestrator
  ├─ extension: task/subagent runner
  ├─ agents: scout / planner / worker / reviewer / validator
  ├─ skills: validation rubric / coding rules / QA steps
  ├─ prompts: implement / review / fix / validate workflows
  ├─ adapter: git / PR / CI integration
  └─ artifact templates: reports / checkpoints / annotations
```

因此，Zig Pi 需要支持“扩展组合成更大扩展”的模型：

- package manifest 能声明多个资源类型。
- extension 可以依赖其他 extension 提供的 capability。
- capability registry 需要支持 discovery，而不是硬编码命令名。
- artifact / state / event bus 需要能标记来源 extension、task、subagent。
- 权限模型需要能按 package、extension、subagent、tool 调用链追踪 provenance。

## Sub-agent 与 Agent-to-Agent 通信

TS 示例 `packages/coding-agent/examples/extensions/subagent/` 已经证明：sub-agent 可以作为 extension 实现。

当前 TS subagent 示例的关键点：

- `index.ts`
  - 注册 `subagent` tool。
  - 支持 single、parallel、chain 三种模式。
  - 通过 `spawn()` 启动独立 `pi` 子进程。
  - 使用 `--mode json -p --no-session` 捕获结构化 JSON event。
  - 从 child stdout 读取 `message_end`、`tool_result_end` 等事件。
  - 使用 `onUpdate` 将子任务进度流回父 agent tool result。
  - 支持 abort，将父级 `AbortSignal` 传播为 child process kill。
  - 收集 usage、model、turns、stderr、exit code、stop reason。
- `agents.ts`
  - 从 `~/.pi/agent/agents/*.md` 和 `.pi/agents/*.md` 发现 agent 定义。
  - agent definition 包括 `name`、`description`、`tools`、`model`、system prompt、source、file path。
  - user agent 默认启用，project agent 需要显式 scope / confirmation。
- `README.md`
  - 示例 agent 包括 scout、planner、worker、reviewer。
  - 示例 prompt workflow 包括 scout → planner → worker、worker → reviewer → worker。

这说明 Zig Pi 未来不应该直接把 Missions 做进 core，但需要比“单 agent”更强的通用底座：

### Orchestrator / Worker / Validator 分工

Droid Mission 任务系统可以理解为：

- **Orchestrator**
  - 拆解目标、分配任务、维护计划、收集结果、决定下一步。
- **Worker**
  - 执行具体开发、搜索、修改、测试、验证步骤。
- **Validator**
  - 审查结果、跑验证、检查 contract、给出 pass / fail / retry 反馈。

这些角色都应该是 subagent definitions 或 workflow plugin 策略，不进入 core。

Core 只需要提供：

- 创建 task / subagent run。
- 给 child agent 限制 tool / model / cwd / permissions。
- 流式接收 child events。
- 支持 parent ↔ child 消息关联。
- 支持 cancellation / timeout / retry / concurrency。
- 产出 parent-child session linkage 与 artifact provenance。

### Agent-to-Agent 通信原语

为了支持 Missions、QA、Review 这类多 agent workflow，建议在 workflow 前补齐通用 A2A 原语：

| 原语 | 作用 | 是否 core |
|---|---|---|
| Task ID / Run ID | 标识一次子任务或子代理运行 | 是 |
| Parent / Child linkage | 记录 parent session、child session、task 来源 | 是 |
| Typed event stream | child progress、tool call、message、artifact、status | 是 |
| Request / response correlation | orchestrator 向 worker / validator 发请求并关联响应 | 是 |
| Mailbox / channel | extension 或 subagent 间传递结构化消息 | Core 提供通道，语义在 extension |
| Shared artifact references | worker 输出，validator 可读取，orchestrator 可汇总 | 是 |
| Permission inheritance | child 默认只能继承 / 收窄父级权限 | 是 |
| Provenance audit | 谁发起、谁执行、用了哪些工具、改了哪些文件 | 是 |
| Role strategy | scout / planner / worker / reviewer / validator prompt 和策略 | 否 |
| Mission graph | task DAG、retry policy、acceptance criteria、validation policy | 否 |

这样 Zig Pi 可以从“单 Agent core”演进为“多 Agent 可编排 substrate”，但仍不把 Mission 产品逻辑塞进 core。

## RLM / Recursive Language Model 关系

`https://github.com/Trampoline-AI/predict-rlm` 的定位不是 Missions，但和 Missions 使用到的“多 agent / 子调用 / 长任务分解”有重叠。

该项目自述为 production-focused self-harnessed LM runtime：让 LM 通过 DSPy signatures 调用 sub-LM，用户定义 typed inputs、outputs、tools，模型自己处理 control flow，并输出可解释 trajectories。它强调：

- 避免 context rot：root LM 通过 REPL / programmatic context 操作保持上下文较小。
- sub-LM 调用：用 Pydantic / DSPy signatures 做 type-safe structured sub-LM invocation。
- async tool calling：可并发执行 sub-LM invocation 与 tool call。
- prompt-optimized skills / tools：技能可以绑定指令、PyPI packages、domain tools。
- file I/O：输入输出可以是 typed `File`。
- traces / trajectories：每次 peek、chunk、sub-call、verification step 可解释，可用于优化。
- RLM-GEPA：可从 traces 优化 RLM skills / AgentSpec。

### 与 Missions 的区别

| 维度 | RLM | Missions |
|---|---|---|
| 核心目的 | 给单个任务提供递归 / self-harnessed LM runtime，让模型自己组织 sub-LM calls | 高层任务系统，包含计划、分工、worker、validator、检查点、验收 |
| 控制流所有者 | 主要由模型在 RLM runtime 内决定 | workflow / mission orchestrator 决定 |
| 典型接口 | typed signature、File、skills、sub_lm、trajectory | task graph、subagents、validator policy、artifact/checkpoint |
| 与 Pi core 的关系 | 应作为 runtime adapter / tool / skill package | 应作为 workflow capability plugin |
| 是否进 core | 否 | 否 |

结论：RLM 更像 “recursive sub-LM runtime adapter” 或 “self-harnessed execution engine”，不是 Missions 本体。它可以成为 Missions、QA、Review、Wiki 的底层执行策略之一，也可以作为独立 capability package 存在。

### 在 Zig Pi 中的建议定位

RLM 应放在 primitive extension services 和 workflow plugin 之间：

```text
Core primitives
  └─ typed tool / provider / task / artifact / sandbox primitives

RLM adapter package
  ├─ extension: register `rlm` / `predict_rlm` tool or slash command
  ├─ skill: /rlm build ... prompt workflow
  ├─ runtime: Python / WASM / external process sandbox
  ├─ typed signatures: input/output schema bridge
  ├─ sub-LM calls: routed through provider registry or external runtime
  ├─ artifacts: trajectory, trace, files, structured output
  └─ optional optimizer: GEPA / trace-based skill optimization

Workflow packages
  ├─ Missions can choose RLM as one worker/validator implementation
  ├─ QA can use RLM for spreadsheet/PDF/browser evidence tasks
  ├─ Review can use RLM for structured audit passes
  └─ Wiki can use RLM for recursive repo summarization
```

Core 不需要内置 RLM，只需要让 extension 能安全接入这类 runtime：

- typed schema bridge：DSPy / Pydantic / JSON Schema / TypeBox 互转。
- sub-call trace event：记录 sub-LM call、tool call、verification step。
- recursion / budget guard：限制 sub-call 深度、并发、token / cost。
- sandbox runner：外部 Python / WASM runtime 的生命周期、权限、文件访问。
- artifact channel：保存 trajectory、structured outputs、generated files。
- provider routing：sub_lm 可走 Pi provider registry，也可由外部 runtime 代理。
- optimizer hook：把 traces 交给 GEPA 或类似 optimizer，但优化逻辑不进 core。

### 对路线图的影响

RLM 值得加入路线图，但位置应是：

- 不是 Phase 6 Missions。
- 应放在 Phase 1 的 primitive substrate 之后，作为 Phase 2 前后可选的 runtime adapter。
- 它依赖 task / subagent substrate、typed tool schema、artifact channel、sandbox runner、provider routing。
- 后续 Missions 可以把 RLM runtime 当作一种 worker / validator execution backend。

## Kimi Code / OpenCode 能力观察

Kimi Code CLI 与 OpenCode 都强化了同一个方向：coding agent 的竞争力不只是“内置更多功能”，而是把 agent loop 暴露成稳定协议、可组合资源和可审计权限边界。它们值得借鉴，但大多数能力仍应进入 Pi 的 extension / package 层。

### Kimi Code CLI

Kimi Code CLI 文档中值得关注的能力：

- **Wire Protocol**
  - `--wire` 暴露基于 JSON-RPC 2.0 的双向协议，用于 custom UI、IDE ACP 接入、自动化测试。
  - 支持 initialize handshake、外部 tool definitions、hook subscriptions、streamed tool call、approval response、subagent event、plan display、steer input 等事件。
  - 对 Pi 的启发：core 应沉淀一个稳定 headless / wire event contract；具体 HTTP、ACP、IDE、Web UI adapter 不进 core。
- **Hooks**
  - 支持 PreToolUse、PostToolUse、PostToolUseFailure、UserPromptSubmit、Stop、StopFailure、SessionStart、SessionEnd、SubagentStart、SubagentStop、PreCompact、PostCompact、Notification 等生命周期事件。
  - hook command 通过 stdin 接收结构化上下文，exit code 决定后续行为。
  - 对 Pi 的启发：core 需要 hook bus、matcher、权限上下文、阻断 / 审计结果；格式化、安全策略、通知、结束验证等都做成 hook packages。
- **Skills**
  - 使用 `SKILL.md` 作为跨工具知识 / workflow 格式，支持 user / project / generic 目录发现，如 `~/.config/agents/skills/`、`.agents/skills/`，并兼容 `.kimi`、`.claude`、`.codex` 等目录。
  - 支持 `/skill:<name>` 显式加载，也有 flow skills：通过 Mermaid / D2 描述多步自动化流程并用 `/flow:<name>` 执行。
  - 对 Pi 的启发：skill registry 应支持跨工具目录、metadata、按需注入、显式 invocation；flow skill 应作为 workflow package，不是 core 状态机。
- **Custom Plugins**
  - `plugin.json` 声明轻量本地 executable tools，可从本地目录、ZIP、Git 仓库安装；插件可同时附带 `SKILL.md`。
  - 文档明确区分：Skills 是知识 / 规范，Plugins 是可执行工具；MCP 更适合长驻服务或复杂跨进程工具。
  - 对 Pi 的启发：Pi package manifest 应同时支持 prompt/skill/tool resources；本地工具插件需要 schema、权限、安装来源与 provenance。
- **Agents / Subagents**
  - agent YAML 定义 system prompt、tools、exclude tools、subagents；支持 `extend` 继承；system prompt 模板可引用工作目录、AGENTS.md、skills 等内置变量。
  - 对 Pi 的启发：自定义 agent / subagent definition 属于 primitive extension service；core 只负责受控启动、权限继承、事件回传。
- **ACP / IDE / Web / Trace visualizer**
  - Kimi 将 CLI core 通过 Wire 接到 Shell UI、ACP server、IDE、Web UI，并提供 `kimi vis` 这类 trace 可视化入口。
  - 对 Pi 的启发：core 只产出 trace / event / artifact；可视化与 IDE adapter 都应是外部 adapter。

### OpenCode

OpenCode 文档中值得关注的能力：

- **Headless server + OpenAPI + SSE**
  - `opencode serve` 启动 HTTP server，暴露 OpenAPI 3.1 spec；提供 session、message、file、command、config、provider、agent、tool、LSP、formatter、MCP、TUI、auth、event 等 endpoint。
  - `/event` 和 `/global/event` 是 SSE event stream；`/tui/*` endpoint 可从外部驱动 TUI，例如 append / submit prompt、打开 help / sessions / models、执行命令、toast、control request / response。
  - 对 Pi 的启发：core 应有统一 session/control/event model；HTTP/OpenAPI/SSE 是 adapter，适合放在 package。
- **Agent model**
  - 区分 primary agents 与 subagents；内置 build、plan、general、explore、compaction、title、summary 等 agent；agent 可用 JSON 或 Markdown frontmatter 配置。
  - agent 配置包含 description、temperature、max steps、disable、prompt、model、mode、hidden、permissions、task permissions、color、top_p 等。
  - 对 Pi 的启发：role strategy 不进 core；core 需要 task/subagent substrate、agent metadata schema、session tree 与权限收窄。
- **Permission model**
  - 支持全局 permission、per-agent override、Markdown agent frontmatter permission，以及具体 bash command pattern 的 allow / ask / deny。
  - 对 Pi 的启发：permission broker 必须是 core 安全边界；组织规则、agent 默认策略、命令 pattern pack 可外置。
- **Configurable UX surface**
  - docs 暴露 themes、keybinds、commands、formatters、LSP servers、MCP servers、ACP support、agent skills、custom tools、plugins、SDK、server、share、GitHub / GitLab。
  - 对 Pi 的启发：这些都是 extension catalog / adapter catalog；core 只需要稳定 registry、capability discovery 与 event/resource contract。
- **Share / platform adapters**
  - conversation sharing、GitHub/GitLab 等平台集成属于可选 product / cloud layer。
  - 对 Pi 的启发：不要让 core 理解分享链接、PR 平台或云同步语义；使用 SCM/cloud adapters。

### 加入 Zig Pi 路线图的调整

| 能力 | 推荐定位 | 说明 |
|---|---|---|
| Wire / headless control protocol | Core primitive + transport adapters | Core 维护稳定 session/event/control schema；JSON-RPC、HTTP、SSE、ACP、IDE 都是 adapter |
| Lifecycle hook bus | Core primitive | hook 点、matcher、阻断结果、审计事件进 core；具体 hook scripts / policy packs 外置 |
| Cross-tool skills | Primitive extension service | 支持 `SKILL.md` / `.agents/skills` 等跨工具发现，prompt 内容不进 core |
| Flow skills / graph workflows | Workflow plugin | Mermaid/D2/JSON DAG 可作为 workflow package；不要变成 core mission graph |
| Local executable plugins | Extension package | tool schema、permission、source provenance 由 core 支撑；脚本与安装管理外置 |
| Agent / subagent definitions | Primitive extension service | 角色、prompt、model、tool policy 外置；core 负责受控 task run |
| HTTP/OpenAPI/SSE server | Adapter package | 依赖 core wire contract，不应绑死在 core |
| TUI remote-control endpoint | Adapter / automation capability | 可作为 Control / QA / IDE integration 的底层 adapter |
| Per-agent permission override | Core permission broker + policy package | core 做决策与审计；默认策略由 agent package 声明 |
| Trace visualizer / share | Artifact / cloud package | core 输出 trace/artifact；可视化和分享外置 |

结论：Kimi 和 OpenCode 都证明 Pi 应优先把 **wire/event protocol、hook bus、permission broker、skill registry、task/subagent substrate、artifact/trace channel** 做稳，而不是把 IDE、Web、GitHub、Flow、Trace UI 或具体 agent roles 做进 core。

## Factory / Droid 文档能力归类

| 能力 | Zig Pi 定位 | 不进 core 的部分 | 需要 core 暴露的原语 |
|---|---|---|---|
| Wiki | workflow plugin + optional cloud / SCM adapter | wiki 生成器、索引器、上传、GitHub Wiki sync、auto-refresh workflow | repo 读取、artifact 输出、slash command、CI adapter hook |
| CLI Code Review (`/review`) | 本地 workflow plugin / skill | review prompt、review heuristics、交互菜单、结果模板 | diff / commit 读取、report artifact、slash command、模型调用 |
| Droid Exec Code Review | headless workflow + CI / SCM adapter | GitHub / GitLab workflow 细节、评论发布、review depth 策略、安全扫描 preset | headless mode、JSON output、SCM diff adapter、annotation artifact |
| Droid Control | automation-driver plugin | browser / desktop / TUI automation 实现、录制 / 视频管线、外部依赖安装 | driver capability、permission gate、screenshot / log / video artifact |
| Automated QA skills | workflow plugin that composes Control drivers | QA 问卷、子技能生成、失败学习、报告模板、CI YAML | skill registry、automation driver invocation、structured artifact / report |
| Droid Shield | security / policy extension + optional enterprise / cloud layer | secret rules DB、云扫描、企业管理、false-positive 服务 | pre-tool / pre-shell / pre-edit / pre-commit / pre-push hooks、redaction、deny / allow policy |
| Missions | high-level workflow orchestration plugin | mission task graph schema、product UI、worker strategy、validation policy | session tree、event bus、subagent / task adapter、artifact / checkpoint state |
| Custom droids / subagents | primitive extension service | droid prompt、角色定义、worker strategy、调度策略 | task / subagent invocation substrate、权限继承、artifact 回传 |
| Skills / hooks / MCP | primitive extension service | 具体 skill 内容、第三方协议产品逻辑、workflow prompt | registry、resource discovery、event bus、permission gate |
| RLM / recursive LM runtime | runtime adapter + optional workflow strategy | predict-rlm runtime、DSPy/Pydantic prompt strategy、GEPA optimization、domain skills | typed schema bridge、sub-LM event stream、sandbox runner、artifact/trace channel、budget guard |

结论：这些都是 Droid 产品层能力，不应该直接进入 Zig Pi core。Zig Pi 只需要有足够稳定的扩展基础设施，让这些能力可以由插件声明、注册、执行和展示。

## Zig Pi 当前已有的扩展基础

当前代码已经有较多适合作为扩展边界的模块：

- `zig/src/coding_agent/extension_registry.zig`
  - 已有工具、命令、快捷键、flag、provider、UI hook、widget、message renderer、resource discovery 注册面。
  - 适合作为继续承载扩展元数据的中心。
- `zig/src/coding_agent/extension_host.zig`
  - JSONL host protocol、runtime registry、UI request、event frame、registry snapshot。
  - 适合继续接收 live extension frame。
- `zig/src/coding_agent/resources.zig`
  - 已支持 extensions、skills、prompts、themes、packages。
  - 适合作为 Wiki / QA / prompt pack / skill pack 的静态资源发现入口。
- `zig/src/coding_agent/interactive_mode/extension_ui_bridge.zig`
  - 已支持 extension slash command dispatch、UI request、dialog、status、editor interaction。
  - 适合承载 Missions / Review / Control 这类交互式工作流。
- `zig/src/coding_agent/extension_events.zig`
  - 已定义 session、agent、message、tool、model、input 等事件类型。
  - 适合作为工作流插件观察 agent 生命周期的事件面。

## 建议的最小新增抽象

建议先增加一个轻量的 `capability` 注册面，而不是直接实现 Wiki / Missions / Review 等功能。

### Capability 元数据

扩展可以声明自己提供的高层能力，例如：

- `wiki`
- `mission`
- `review`
- `qa`
- `control`
- `shield`
- `workflow`

建议字段：

| 字段 | 用途 |
|---|---|
| `id` | 稳定唯一标识 |
| `kind` | 能力类型，如 `wiki`、`mission`、`review` |
| `title` | UI / registry dump 展示名称 |
| `description` | 简短说明 |
| `command` | 可选 slash command 入口 |
| `resourcePath` | 可选资源、技能或索引路径 |
| `extensionPath` | 来源扩展路径 |

### JSONL frame

扩展 host 可以增加：

```json
{"type":"register_capability","id":"repo-wiki","kind":"wiki","title":"Repository Wiki","description":"Generate and browse codebase wiki","command":"wiki","extensionPath":"wiki/extension.ts"}
{"type":"unregister_capability","id":"repo-wiki"}
```

这只扩展 registry 的观测与发现能力，不改变 agent loop、不改变工具执行、不引入产品逻辑。

## 依赖顺序

### Phase 0：稳定扩展合约

- 固定 extension manifest、registry、event bus、capability model。
- 明确 tool、command、slash command、hook、artifact、policy、task / subagent 的 ABI / API。
- Core 只承诺稳定边界，不承诺任何 Factory-branded workflow。

### Phase 1：基础 primitive extensions

- 补齐 skill registry、hook system、permission broker、artifact channel、extension state store。
- 增加 task / subagent invocation substrate：受控启动、取消、超时、输入输出、artifact 回传。
- 增加 context provider 与 SCM diff adapter 的最小本地实现。
- 增加 typed signature / schema bridge 与 sub-call trace event，为 RLM / sub-LM runtime adapter 做准备。
- 这一阶段不实现 Missions，只提供 Missions 未来需要的底座。

### Phase 2：本地只读 workflow

- 先做本地 `/review` 与本地 Wiki 生成插件。
- 输出 Markdown / JSON artifacts，不接云、不发评论、不写 CI。
- 验证 extension host、artifact、diff / repo context 是否足够。
- 可选增加 RLM adapter spike：通过 extension 调用外部 `predict-rlm` / Python runtime，产出 typed output 和 trajectory artifact。

### Phase 3：Headless + SCM / CI adapters

- 添加 headless review workflow：PR / MR diff 输入、JSON / annotation 输出。
- GitHub / GitLab 发布评论、CI 安装 workflow 都是 adapter。
- Core 不理解 PR、MR、review depth、security severity 语义。

### Phase 4：Droid Control + QA

- Control 作为 automation driver 插件接入。
- Automated QA 作为 skill / workflow 调用 Control。
- 输出截图、日志、视频、结构化报告。
- browser driver、terminal recorder、video pipeline 等外部依赖不进入 core。

### Phase 5：Shield 安全层

- 先实现本地 policy hook 与 secret scan extension。
- 再加企业策略、云端规则同步、组织级控制 adapter。
- Core 只维护默认安全边界和 hook 点。

### Phase 6：Missions

- `/missions` 是 workflow plugin，依赖前面所有原语。
- Mission 状态、检查点、验证 worker、子任务调度都在扩展层。
- Core 只提供 session tree、events、task / subagent adapter、artifact channel。

## 明确禁止进入 core

- Wiki 内容生成 / 上传 / 同步。
- Code review prompt、heuristics、review depth / security preset。
- GitHub / GitLab / CI 平台逻辑。
- Browser / desktop / TUI automation 实现。
- QA 问卷、失败学习、报告模板。
- Droid Shield 规则库、云扫描、企业策略 UI。
- Missions 产品逻辑、任务图 schema、验证策略。
- Custom droid 角色 prompt、subagent worker strategy、任务拆解策略。
- MCP server 产品逻辑、第三方 API adapter 业务规则。
- RLM runtime、DSPy/Pydantic prompt strategy、GEPA optimization、domain skill implementation。
- 任何硬编码 Factory / Droid 品牌命令；应由插件注册。

## Missions 层级定位

Missions 不应该进 Zig Pi core。它属于高层 orchestration capability，也就是扩展能力 / 产品工作流层。

推荐分层：

1. **Core**
   - agent loop、session、tools、TUI、provider、权限边界、extension API。
2. **Primitive extensions**
   - MCP、hooks、skills、custom droids、Task / subagent、tool registry。
3. **Workflow capabilities**
   - Missions：依赖 skills + custom droids + Task / subagents + validation workers。
   - Wiki：依赖 repo analysis + cloud / upload 或本地 artifact writer。
   - Review：依赖 git diff tools + review rubric + optional PR integration。
   - Droid Control：依赖 browser / terminal automation drivers + evidence artifacts。
4. **Cloud / enterprise capabilities**
   - cloud session sync、Factory computers、readiness dashboard、org policy、analytics。

如果要做 Missions，应先把 Task / subagent、skills、hooks、权限模型这些 primitives 做稳，然后 Missions 作为可安装 / 可启用的 capability plugin 实现。

## 后续实现任务清单

### 1. Registry 层

- 在 `extension_registry.zig` 添加 `ExtensionCapability`。
- 在 `Registry` 中增加 `capabilities` 列表。
- 实现：
  - `registerCapability`
  - `unregisterCapability`
  - `findCapabilityIndex`
- 在 `deinit` 中释放 capability 内存。
- 在 registry snapshot JSON 中输出 `capabilities`。

### 2. Host protocol 层

- 在 `extension_host.zig` 的 registry frame 类型中加入：
  - `register_capability`
  - `unregister_capability`
- 在 `ProtocolState.onMessage` 中将 capability frame 计入 applied registry frames。
- 保持未知或 malformed frame 的容错行为不变。

### 3. 测试

建议增加 focused tests：

- registry 可注册 capability。
- 重复注册同一 `id` 会替换旧 metadata。
- unregister 可删除并返回正确布尔值。
- malformed `register_capability` 被忽略。
- snapshot JSON 包含 `capabilities`。
- host protocol 能接收 live `register_capability` frame 并计数。

### 4. 不应在第一步做的事

不要在第一步实现这些产品功能：

- Wiki 生成器
- Missions 编排器
- PR review agent
- QA runner
- browser / desktop automation
- enterprise security policy engine

这些应该在 capability 注册面稳定后，作为独立 extension / workflow 逐个落地。

## 推荐架构边界

```text
Zig Pi core
  ├─ agent/session loop
  ├─ built-in tool execution
  ├─ permission/context/resource primitives
  ├─ task/subagent invocation substrate
  ├─ artifact/report channel
  ├─ TUI rendering primitives
  └─ extension host / registry / events

Extensions
  ├─ skills/hooks/MCP adapters
  ├─ RLM / recursive LM runtime adapters
  ├─ custom droid and subagent definitions
  ├─ wiki capability
  ├─ mission/workflow capability
  ├─ review capability
  ├─ QA skill packs
  ├─ control automation tools
  └─ shield/policy hooks
```

核心判断：Zig Pi core 只需要知道“有一个扩展声明了一种 capability，并且它可能有命令、资源或 UI 入口”；core 不需要知道 wiki、mission、review 的业务语义。

## 文件与风险提示

后续实现前需要注意当前工作区已有外部修改，避免覆盖他人工作：

- `zig/src/coding_agent/interactive_mode.zig`
- `zig/src/coding_agent/interactive_mode/rendering.zig`
- `zig/src/coding_agent/interactive_mode/slash_commands.zig`
- `zig/src/main.zig`
- `zig/src/coding_agent/extension_host.zig`

尤其 `extension_host.zig` 已被外部修改，后续编辑前必须重新读取最新内容。

## 验证建议

文档修改不需要跑 Zig 测试。实现 capability registry 后建议运行：

```bash
zig build test-coding-agent
zig build test-tidy -Dtidy-fail-on-warning=true
```

如果触及 TS-RPC 或 live extension host 行为，再补充：

```bash
zig build test-ts-rpc-parity
```

## 最终结论

Zig Pi 要支持 Droid-like 能力，最重要的不是把 Droid 的产品功能搬进 core，而是把扩展边界设计稳定。建议先实现 / 加固 extension host + artifact + hook / capability contract，然后用 `/review` 和本地 Wiki 作为最小 workflow 插件验证架构；Missions、Control、QA、Shield 都排在稳定扩展 ABI 之后。
