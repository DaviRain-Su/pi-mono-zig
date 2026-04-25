# Zig 实现 Review & 与 TS 版本的 Gap 分析

> 本文档跟踪 `zig/` 下的 Zig 实现与 `packages/coding-agent/`（TS 版）之间的差距。
> 上次更新覆盖了对 `zig/src/{main,cli,coding_agent,ai,tui,agent}` 的整体扫读。

---

## 1. 总体结论

- **核心 agent 引擎、内置工具、session、交互式 TUI** 已经接近 TS 版本。
- 主要剩余 gap 集中在 **生态层**：
  - 扩展（extension）运行时
  - 包管理子命令（install/remove/update/list/config）
  - TS-兼容的 JSONL RPC 控制平面
  - provider/auth 广度与动态 registry
  - TUI 末段 polish（scoped models、changelog、扩展 UI 通道、剪贴板图片等）
- **如果目标 = 一个好用的独立 Zig coding agent**：剩余 ≈ **2–4 周**。
- **如果目标 = 完全替代 TS 实现**：剩余 ≈ **6–10+ 周**，绝大部分成本在扩展运行时与 RPC 兼容层。

---

## 2. 各模块 Parity

| 模块 | Parity | 剩余工作量 | 备注 |
|---|---|---|---|
| CLI / bootstrap | 70–80% | M (2–4d) | 缺少若干 flag 与包管理子命令 |
| Agent 核心 loop | 75–85% | M (2–5d) | 流式、工具执行、模式分发已基本到位 |
| 内置 tools | 70–80% | M (3–5d) | 7 个核心工具齐备，polish 与扩展接入未完成 |
| Sessions / 分支 / 导入导出 | 65–75% | M–L (4–7d) | 全局查找、HTML 导出、迁移仍欠缺 |
| Print mode | 80–90% | S (1–2d) | 行为接近，仅事件元数据细节 |
| JSON mode | 80–90% | S–M (1–3d) | 能力到位；wire schema 兼容性未验证 |
| Providers / models / auth | 45–65% | L (1–2w) | OAuth 已真实可用；广度与动态 registry 仍落后 |
| TUI / interactive | 55–70% | L (1–2w) | 交互层已经是认真的实现，缺产品级末端 polish |
| **RPC 协议兼容** | **20–30%** | **L–XL (1–2w+)** | Zig 是干净的 JSON-RPC 2.0；TS 是自定 JSONL 控制协议，两者不兼容 |
| **扩展 / 包管理 / 自定义 UI** | **10–20%** | **XL (3–6w+)** | 最大结构性 gap |
| MCP | 两边都未内置 | 取决于扩展层 | TS 可经扩展加入；Zig 当前不行 |

---

## 3. 已经实现（修正旧 REVIEW 的过时条目）

旧 REVIEW 把以下功能列为缺失，**实际 Zig 已经实现**：

### CLI（`zig/src/cli/args.zig` + `zig/src/main.zig`）
- `--resume`, `--no-session`, `--fork`, `--session-dir`
- `--models`, `--list-models`
- 扩展 / skills / prompt templates / themes 相关 flag
- `@file` 参数
- stdin/TTY 自动检测，自动选择 print/interactive 模式

### 交互模式 slash 命令（`zig/src/coding_agent/interactive_mode.zig`）
- `/settings`, `/import`, `/share`, `/copy`
- `/name`, `/label`, `/hotkeys`
- `/logout`, `/new`
- `/session`, `/tree`, `/fork`, `/clone`, `/export`, `/resume`

### Session 模型（`zig/src/coding_agent/session_manager.zig`）
- `message`, `thinking_level_change`, `model_change`, `compaction`
- `branch_summary`, `custom`, `custom_message`
- `label`, `session_info`

### Edit 工具（`zig/src/coding_agent/tools/edit.zig`）
- `edits[]` 批量编辑
- 兼容旧的 `oldText` / `newText` 单次替换
- 非重叠校验、原文匹配语义

### Auth（`zig/src/coding_agent/auth.zig`）
**不是占位符**，已包含真实的 OAuth / device / browser-flow：
- Anthropic
- GitHub Copilot
- Google Gemini CLI / Cloud Code Assist

### Providers（`zig/src/ai/providers/register_builtins.zig`）
内置注册：
- OpenAI、Anthropic、Mistral、Kimi
- Google、Google Vertex、Google Gemini CLI
- Azure OpenAI Responses、OpenAI Responses、Codex Responses
- Bedrock、Faux

---

## 4. 仍明确缺失的内容

### 4.1 CLI flags
- `--no-builtin-tools`
- `--no-context-files`
- `--offline`
- `--verbose`
- 命令行 `--export <file>`

### 4.2 包管理子命令
- `install`
- `remove` / `uninstall`
- `update`
- `list`
- `config`

### 4.3 TS-兼容 JSONL RPC 控制平面
当前 Zig RPC 走标准 JSON-RPC 2.0：`initialize` / `chat` / `complete` / `stream` / `$/cancelRequest`。
TS 走自定 JSONL，覆盖大量会话/运行时控制：
- prompt / steer / follow_up / abort
- get/set model
- 思考强度控制
- 压缩控制、重试控制
- bash 控制
- session 切换 / fork / clone / export
- `get_messages` / `get_commands`
- 扩展 UI request/response 通道

### 4.4 扩展运行时 & 生态
- 扩展加载/运行模型、扩展命令
- 自定义 tools
- 扩展 event bus
- 扩展 UI requests / widgets / 编辑器集成
- 扩展注册的 providers / OAuth
- 包管理流程（与 4.2 联动）
- 更完整的 SDK / embed 故事

### 4.5 TUI 末段
- `/scoped-models`
- `/changelog`
- 扩展驱动的 UI / 编辑器 / 自定义 widget
- 队列模式、进阶编辑器行为
- 剪贴板图片粘贴等细节交互

### 4.6 Provider / auth 广度
- 更广的 provider 目录与 registry surface
- 与 auth/可用性挂钩的动态注册
- 更完善的 auth 存储与 provider UX
- 扩展定义的 provider/OAuth

### 4.7 工具 polish
- `bash`：流式进度/上报、可插拔 backend 行为
- `write`：变更队列与更丰富的 preview
- `read`：图片/运行时处理更完善
- 自定义/扩展工具路径

---

## 5. 与 Zig 实现本身相关的内部建议（非 TS gap）

这些是上一轮代码 review 的留底，仍然适用：

### P1 — 大文件拆分
- `zig/src/main.zig`：CLI 解析、stdin 检测、运行时准备、provider 解析、模式分发全部混在一起。
  建议拆为 `cli/bootstrap.zig` / `cli/input_prep.zig` / `cli/runtime_prep.zig` / `cli/output.zig`，`main.zig` 仅做组合。
- `zig/src/coding_agent/interactive_mode.zig`：过大。
  建议按 渲染、输入分发、slash 命令、overlay/selector、prompt worker 拆分。

### P2 — 全局可变状态
- `interactive_mode.zig` 中的 `global_tool_runtime`，未配置时 `@panic("tool runtime not configured")` 偏脆弱。
- `tui/keys.zig` 的 `kitty_protocol_active`。
- 建议引入轻量 `AppContext` / `RuntimeContext` 显式穿透，而非进程级全局。

### P3 — TUI API 边角
- `Box` 的边框只在 `theme != null` 时渲染：`border_style = .single` 在无 theme 时静默无边框，应解耦或显式报错。
- `theme.zig` 颜色解析对非法值静默忽略，应该 fail loudly。
- 动态分发使用 `*anyopaque` + `anyerror` 实用但放弃了部分编译期保证，注意控制范围。

### P4 — 构建脚本
- `build.zig` 整体良好。
- `test-cross-area` 直接 shell 出 `bash`，Windows 不便携。
- 外部工具 (`rg`, `fd`) 检查范围较广，可缩到真正需要的 step。

---

## 6. 推荐路线图

### 路线 A：独立 Zig coding agent（推荐先走完）
1. CLI flag 与导出补齐：`--no-builtin-tools` / `--no-context-files` / `--offline` / `--verbose` / `--export` —— **2–4d**
2. Provider / 模型 / auth polish：广度 + 动态 registry —— **4–8d**
3. TUI polish：scoped models、changelog、剪贴板图片、队列模式 —— **4–7d**
4. Session 行为 polish：全局查找、HTML 导出、迁移 —— **2–4d**
5. 工具 polish：bash 流式、write 队列、read 图片/运行时 —— **2–4d**

总量 ≈ **2–4 周**。

### 路线 B：完全替代 TS（按依赖排序）
1. **TS-兼容 RPC 层**：解锁外部集成 —— 1–2w
2. **扩展运行时 + 自定义工具**：解锁大量"功能"是经由扩展提供的 —— 3–6+w
3. **包管理子命令**：使扩展生态可用 —— 与 (2) 联动
4. **provider/auth 广度 + registry parity**：在扩展可承载后再做更划算 —— 1–3w
5. **TUI 末段 polish**：scoped models、changelog、扩展 UI、自定义编辑器 —— 1–2w

总量 ≈ **6–10+ 周**。

---

## 7. 注意事项

- **不要把旧 REVIEW 的百分比当真**：很多条目已经过时（见 §3）。
- **"功能存在 ≠ wire 兼容"**：JSON mode、RPC 两边都"有"，但协议不同。
- **不要为扩展 parity 过度投入**，除非确实需要。它是最大的时间黑洞。
- **Auth 不要再当成空壳**：Zig 的 OAuth 已可用，问题在广度与扩展接入。

---

## 8. 一句话总结

> Zig 在 coding-agent 内核与交互层已接近 TS；剩下的真实 gap 是 **TS 的生态层**：包管理、扩展运行时、provider/auth 广度，以及 TS-兼容 RPC。
