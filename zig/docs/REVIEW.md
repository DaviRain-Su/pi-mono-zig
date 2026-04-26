# Zig 实现 Review & 与 TS 版本的 Gap 分析

> 本文档跟踪 `zig/` 下的 Zig 实现与 `packages/coding-agent/`（TS 版）之间的差距。
> 最近一次更新：完成第二轮 review，覆盖 `interactive_mode/*` 拆分后的状态、`agent/root.zig`、
> `coding_agent/tools/bash.zig`、`coding_agent/interactive_mode/rendering.zig`。

---

## 0. 自上次 Review 以来的变化（已完成项）

之前列为 P1 的两个拆分都已完成：

- `interactive_mode.zig` 已拆出多个子模块：
  - `interactive_mode/shared.zig`
  - `interactive_mode/formatting.zig`
  - `interactive_mode/overlays.zig`
  - `interactive_mode/rendering.zig`
  - `interactive_mode/prompt_worker.zig`
  - `interactive_mode/slash_commands.zig`
  - `interactive_mode/input_dispatch.zig`
  - `interactive_mode/clipboard_image.zig`
- `main.zig` 已拆出 `cli/` 下的：
  - `cli/bootstrap.zig`
  - `cli/input_prep.zig`
  - `cli/runtime_prep.zig`
  - `cli/output.zig`

之前 REVIEW 列为缺失但**现在已实现**的功能：

- CLI flags：`--no-builtin-tools`, `--no-context-files`, `--offline`, `--verbose`, `--export`
- slash 命令：`/scoped-models`, `/changelog`
- 剪贴板图片粘贴路径
- 显式 `AppContext` 替代旧的全局 tool runtime
- `bash` 的流式输出 / 超时 / 进程组 kill / 截断 / 安全 temp 全量输出捕获 / 完整测试

---

## 1. 总体结论

- **核心 agent 引擎、内置工具、session、交互式 TUI、auth/providers** 已经接近 TS。
- 真正剩余 gap 集中在 **生态/控制面**：
  - 扩展（extension）运行时
  - 包管理子命令
  - TS-兼容 JSONL RPC
  - 动态 provider / 自定义 UI
  - MCP（经扩展通道）
- **目标 = 独立可用的 Zig coding agent**：剩余 ≈ **1–3 周**（比上次更短）。
- **目标 = 完全替代 TS**：剩余 ≈ **6–10+ 周**（几乎不变；剩下全是最贵的生态层）。

---

## 2. 各模块 Parity（更新版）

| 模块 | 当前 Parity | 变化 | 主要剩余项 |
|---|---:|---|---|
| CLI / bootstrap | **88%** | ↑ | 包管理子命令；TS 风格的 unknown-flag 透传；扩展驱动 help |
| Agent 核心 loop | **82%** | ↑ | 缺扩展 runner / event bus；缺动态 provider/tool 注入 |
| 内置 tools | **82%** | ↑ | bash 不可插拔；结构化 `details` 未向上贯通；无自定义/扩展 tool |
| Sessions / 分支 / 导入导出 / 搜索 | **82%** | ↑ | 运行时替换生命周期；扩展感知的 session hook |
| TUI / interactive | **78%** | ↑↑ | 扩展 widgets / 自定义 editor / footer/header 注入；继续拆分 |
| JSON mode | **88%** | – | wire/schema 兼容性验证；结构化元数据丰度 |
| Providers / auth | **68%** | ↑ | 动态 registry；扩展定义的 provider/OAuth |
| **RPC** | **30%** | – | Zig 是 JSON-RPC 2.0；TS 是自定 JSONL 控制协议 |
| **扩展 / 包管理 / 自定义 UI** | **12%** | – | loader/runner、commands、tools、providers、UI、包 CLI |
| **MCP** | **5%** | – | 当前 Zig 实质上没有 MCP runtime/client/server |

---

## 3. 仍明确缺失的内容

### 3.1 CLI / 包管理
- 包管理子命令：`install` / `remove` / `uninstall` / `update` / `list` / `config`
- TS 风格 `unknownFlags` 透传给扩展（Zig 当前对未知 flag 直接报错）
- 扩展驱动的 help 文本

### 3.2 Agent runtime host
- TS 的 `AgentSessionRuntime` 等 runtime-host 抽象
- 运行时 rebind/替换的生命周期
- 扩展 runner 集成 / runtime services 边界
- 通过扩展的动态 tools / providers / hooks

### 3.3 工具层（具体硬伤）
- **bash 的结构化 `details` 在 `interactive_mode.zig` 的 adapter 被丢弃**
  - 内部已算出 `exit_code` / `timed_out` / `full_output_path` / `truncation`
  - adapter 仅返回 `.content`，TUI/JSON/RPC 拿不到
- **bash 参数命名不兼容 TS**
  - Zig: `timeout_seconds`
  - TS: `timeout`
  - 应像 grep adapter 那样接受别名
- bash 仅 POSIX 后端（`/bin/sh` / 进程组 / `/tmp/pi-bash-*`），无 pluggable `BashOperations` / `spawnHook`
- 无自定义/扩展 tool 路径

### 3.4 TS-兼容 JSONL RPC
当前 Zig 是干净的 JSON-RPC 2.0，缺以下控制语义：
- prompt / steer / follow_up / abort
- get/set model
- thinking / compaction / retry / bash 控制
- session 切换 / fork / clone / export
- `get_messages` / `get_commands`
- 扩展 UI request/response 通道

### 3.5 扩展 / 包 / 自定义 UI
- 扩展加载器/运行模型、命令、event bus
- 自定义 tools / providers / OAuth
- 扩展 UI requests / widgets / 编辑器 / footer 注入
- 完整 SDK / embed 故事

### 3.6 TUI 末段
- 扩展 widgets / 自定义编辑器 / footer/header 注入
- 自定义 message renderer / tool renderer
- `rendering.zig` 渲染期持锁过久（建议"锁内取快照、锁外渲染"）

### 3.7 MCP
- 无 client / server / runtime 集成
- 只有零星的 auth scope 引用，不算支持

---

## 4. 单文件 Code Review（本轮新增）

### `zig/src/agent/root.zig`
- **质量：高**。干净的 re-export barrel，稳定 agent 包公共边界。
- 无明显问题，低风险。

### `zig/src/coding_agent/interactive_mode.zig`
- **方向正确，但仍偏大**：仍混合 orchestration、tool adapter、session 打开、参数 helper、re-export 墙、tests。
- 拆分进度估计 **~65–75%**。
- 下一步最有价值的拆分：tool adapters + session-open/bootstrap helpers。
- adapter 一致性问题：`grep` 已支持 legacy alias（`ignoreCase` / `ignore_case`），`bash` 没桥接 `timeout` ↔ `timeout_seconds`。
- 工具结果的 `.details` 没向上贯通。

### `zig/src/coding_agent/interactive_mode/rendering.zig`
- **拆分成功**：`AppState` 内存所有权、锁纪律、render helpers 都比之前清晰。
- 主要 caveat：
  1. `ScreenComponent.renderInto` **在锁内做 chat/prompt/footer/autocomplete 的渲染与分配** —— 工具流较多时会拖慢更新。
  2. `pub var active_resize_backend` 是进程级单例（signal handler 需要，但仍是可变全局）。
- 后续可继续拆为：`app_state.zig` / `screen.zig` / `terminal_backend.zig`。

### `zig/src/coding_agent/tools/bash.zig`
- **本轮最强的新文件**：测试覆盖好，timeout / 截断 / stderr / 进程组 kill / 流式更新都是真材实料。
- 主要 caveat：
  1. POSIX-only 世界观，缺 pluggable backend。
  2. `details` 计算了但上层没用上。
  3. `timeout_seconds` 与 TS 的 `timeout` 不兼容。

---

## 5. 内部工程建议（仍适用）

### 已部分完成
- ~~P1：拆分 `main.zig`~~ ✅
- ~~P1：拆分 `interactive_mode.zig`~~ 🟡（仍需再拆一次）

### 仍要做
- **P2 — 全局可变状态**
  - `tui/keys.zig` 的 `kitty_protocol_active`
  - `interactive_mode/rendering.zig` 的 `active_resize_backend`
  - 建议尽量用显式 context 穿透（`AppContext` 已是好示例）
- **P3 — TUI API 边角**
  - `Box` 边框只在 `theme != null` 时渲染：`border_style = .single` 在无 theme 时静默无边框，应解耦或显式报错。
  - `theme.zig` 颜色解析对非法值静默忽略，应该 fail loudly。
  - 动态分发使用 `*anyopaque` + `anyerror` 实用但放弃部分编译期保证，注意控制范围。
- **P4 — 构建脚本**
  - `test-cross-area` 直接 shell 出 `bash`，Windows 不便携。
  - 外部工具（`rg`, `fd`）检查范围较广，可缩到真正需要的 step。

---

## 6. 推荐路线图

### 路线 A：独立 Zig coding agent（**推荐先走完，约 1–3 周**）

按 ROI 排序：

1. **bash 工具的 `details` 一路透到 TUI/JSON/RPC** —— S，回报大
2. **bash 参数兼容 `timeout` 别名** —— XS
3. **再拆一次 `interactive_mode.zig`**（tool adapters + session-open helpers）—— M
4. **`rendering.zig` 锁内取快照、锁外渲染** —— S–M
5. **provider / 模型 / auth UX polish** —— M
6. **JSON 输出契约校验**（与 TS 对齐 schema）—— S–M
7. **TUI 末段细节**（剪贴板图片体验、队列模式等小项）—— S

### 路线 B：完全替代 TS（三阶段策略）

**前提决策已锁定**：必须兼容现有 TS 扩展生态 → 必须嵌一个 JS 运行时。
**选型**：Bun（已生产可用，Node API 兼容度远好于 Deno；当前 Bun 的 C embed API 仍在演进，
所以**先用子进程模式**集成，不内嵌）。

#### 阶段 1：Bun 作为扩展运行时（兼容期，**约 8–13 周**）

让 Zig 宿主 spawn 一个 Bun 子进程跑 `extension-host.ts`，扩展在 Bun 里加载，
通过 stdio JSON-RPC 与 Zig 通信。这样**Bun 升级 = 兼容性升级**，零维护成本。

具体工作：

1. Bun 子进程协议 + 扩展 host 脚本 —— **2–3 周**
2. TS 扩展 API 契约对齐（Zig 端按 TS 现有签名实现）—— **2–4 周**
3. TS-兼容 JSONL RPC（顺手做了）—— **1–2 周**
4. 包管理（直接调 `bun install` / `npm install`）—— **1 周**
5. 真实扩展联调 —— **2–3 周**

要点：
- **Bun 版本锁定**：自带 Bun 或下载到 `~/.pi/bun/`，避免用户机器版本漂移。
- **子进程崩溃恢复**：Bun 死掉不能拖死 Zig 宿主，要能重载扩展。
- **传输格式**：JSON 够用；高频流式（如 token-by-token）需批处理或换 MessagePack /
  length-prefixed framing。

#### 阶段 2：把热门扩展原生化（数据驱动，持续进行）

- 加埋点统计扩展使用频率。
- top N 用 Zig 重写成内置或"原生扩展"，同名同接口，用户无感切换。
- 收益：性能、体积、不依赖 Bun 子进程。
- 这个阶段没固定工期，按需求推进。

#### 阶段 3：Zig 原生扩展的动态加载（**约 2–3 周**）

当原生扩展数量上来后，需要一个动态加载机制。**推荐 Wasm**：

| 机制 | 难度 | 适合度 |
|---|---|---|
| `.so` / `.dylib` + 稳定 C ABI | 中 | 性能最好；ABI 演进麻烦 |
| **Wasm** | 中 | 沙箱好、跨平台、Zig 工具链天然契合 |
| 编译期注册（rebuild 才能加） | 低 | 最简单；用户体验差 |

选 Wasm 的理由：
- Zig 自己支持 wasm32 target，写扩展与写宿主工具链一致。
- 沙箱、跨平台分发、热加载都天然。
- 此阶段不再追求"复用 TS 生态"，Wasm 的劣势消失。

#### 最终架构

```
┌─────────────────────────────────────────┐
│           Zig coding-agent              │
│  ┌─────────────────────────────────┐    │
│  │ 内置 tools / agent / TUI / RPC  │    │
│  └─────────────────────────────────┘    │
│                  │                      │
│         ┌────────┴────────┐             │
│         │ 扩展加载器       │             │
│         └────┬───────┬────┘             │
│              │       │                  │
│   ┌──────────▼──┐ ┌──▼────────────┐     │
│   │ Wasm runtime│ │ Bun 子进程     │     │
│   │ (原生扩展)  │ │ (TS 扩展兼容) │     │
│   └─────────────┘ └────────────────┘    │
└─────────────────────────────────────────┘
```

扩展元数据声明类型（`type: "wasm"` / `type: "node"`），加载器分发即可。

#### 阶段 1+2+3 合计

- 阶段 1：**8–13 周**（约 2–3 个月）
- 阶段 2：持续，无固定工期
- 阶段 3：**2–3 周**（按需启动）

依赖顺序：阶段 1 必须先完成（否则没扩展生态可用），阶段 2/3 可并行推进。
**未先做阶段 1 就去做 providers/MCP/UI 会反复返工。**

---

## 7. 注意事项

- **不要把功能"存在" 当作"wire 兼容"**：JSON mode、RPC 两边都"有"，但协议不同。
- **Auth 已不是空壳**：Anthropic / GitHub Copilot / Google Gemini CLI 真实 OAuth 已可用，问题在广度和扩展接入。
- **不要为扩展 parity 过度投入**，除非确实需要。它是最大的时间黑洞，且影响整体架构选型。
- **bash 是当前最容易拿到 parity 提升的工具**：`details` 透传 + `timeout` 别名两步就能显著改善 TUI/JSON 表现。

---

## 8. 一句话总结

> Zig 的 coding-agent 内核、交互层、工具与 auth 都已接近 TS；
> 剩下的真实 gap 是 **TS 的生态层**：扩展运行时、包管理、TS-兼容 JSONL RPC、动态 provider/UI、MCP。
> 独立可用只剩 1–3 周 polish；要完全替代 TS 仍需 6–10+ 周。
