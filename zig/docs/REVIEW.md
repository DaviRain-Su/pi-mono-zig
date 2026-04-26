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

- 阶段 1：**8–13 周**（约 2–3 个月，含隐藏工作量更可能 **12–16 周**）
- 阶段 2：持续，无固定工期
- 阶段 3：**2–3 周**（按需启动）

依赖顺序：阶段 1 必须先完成（否则没扩展生态可用），阶段 2/3 可并行推进。
**未先做阶段 1 就去做 providers/MCP/UI 会反复返工。**

---

### 6.B 路线 B 阶段 1 详细设计

下面把阶段 1 拆到可以直接开工的颗粒度。

#### 6.B.1 进程模型

```
Zig 宿主进程
  └─ spawn ─→ Bun 子进程 (extension-host.ts)
                 ├─ 加载所有已安装扩展
                 ├─ 维护扩展实例生命周期
                 └─ 通过 stdio 与 Zig 通信

通信通道：
  - Zig → Bun: 子进程 stdin
  - Bun → Zig: 子进程 stdout
  - Bun 日志:   子进程 stderr（Zig 旁路收集）
```

要点：
- **一个 Bun 子进程承载所有扩展**（不是每扩展一进程），扩展之间共享 Bun runtime。
- 启动时机：Zig 宿主初始化后惰性 spawn，第一次需要扩展时才起。
- 关闭时机：Zig 宿主退出前发送 `shutdown` 通知，超时则 SIGTERM 强杀。

#### 6.B.2 协议（JSON-RPC over stdio + 长度前缀）

帧格式（避免 stdout 输出乱掉行边界）：
```
Content-Length: <bytes>\r\n
\r\n
<json payload>
```

这是 LSP 同款帧格式，库现成，调试友好。

消息类型：
- **Request**（双向都能发）：`{ jsonrpc, id, method, params }`
- **Response**：`{ jsonrpc, id, result | error }`
- **Notification**（无 id，无回包）：`{ jsonrpc, method, params }`

#### 6.B.3 核心方法分类

**Zig → Bun（宿主调扩展）**
| 方法 | 用途 |
|---|---|
| `host/initialize` | 握手、传配置、扩展目录 |
| `host/shutdown` | 优雅退出 |
| `extensions/load` | 加载某个扩展 |
| `extensions/unload` | 卸载某个扩展 |
| `extensions/reload` | 热重载 |
| `extensions/list` | 已加载列表 |
| `tool/invoke` | 调用扩展注册的 tool |
| `command/run` | 调用扩展注册的 slash command |
| `provider/complete` | 调用扩展注册的 provider |
| `ui/event` | 把 UI 事件转发给扩展 |

**Bun → Zig（扩展调宿主）**
| 方法 | 用途 |
|---|---|
| `register/tool` | 扩展声明它提供的 tool |
| `register/command` | 声明 slash command |
| `register/provider` | 声明 provider |
| `register/oauth` | 声明 OAuth 流程 |
| `register/ui` | 声明 UI widget / footer / header |
| `session/append` | 写入 session entry |
| `session/query` | 读 session 历史 |
| `agent/emit` | 发 event |
| `host/log` | 日志（Zig 决定怎么输出） |
| `host/fs` | 受权限控制的 FS 访问 |
| `ui/request` | 向 TUI 请求（弹 overlay 等） |

注意：**所有"注册"调用都是幂等的，且必须在 `extensions/load` 处理期间完成**。
load 返回后注册集合冻结，避免运行期偷偷改 tool 列表。

#### 6.B.4 流式与事件

很多 method 是流式的（tool 输出、provider 流式 token、session entry 增量）。
方案：

- 对流式调用，response 只回 `{ stream_id }`，后续走 notification：
  - `stream/chunk` `{ stream_id, data }`
  - `stream/end` `{ stream_id, ok | error }`
- 调用方可发 `stream/cancel` `{ stream_id }` 取消。

这样不引入 WebSocket / SSE 复杂度，单 stdio 通道就能跑。

#### 6.B.5 扩展 manifest

每个扩展一个 `package.json` + 一个 `extension.json`：

```jsonc
// extension.json
{
  "id": "my-extension",
  "version": "1.0.0",
  "type": "node",                  // 阶段 3 后还会有 "wasm"
  "entry": "./dist/index.js",
  "engines": { "pi-agent": "^1.0" },
  "capabilities": {
    "tools": ["my_tool"],
    "commands": ["/my-cmd"],
    "providers": ["my-provider"],
    "ui": ["footer"]
  },
  "permissions": {
    "fs": { "read": ["${workspace}"], "write": [] },
    "net": { "domains": ["api.example.com"] },
    "shell": false
  }
}
```

`capabilities` 仅作声明，**实际能力以 `register/*` 调用为准**，但宿主可以在 manifest 与
register 不一致时拒绝加载或告警。

#### 6.B.6 安装路径与 Bun 锁定

```
~/.pi/
  bun/
    bun-1.1.x/                    # 自带 Bun，按版本号目录
  extensions/
    <ext-id>@<version>/
      extension.json
      package.json
      node_modules/               # 由 bun install 填充
      dist/
  extension-host/
    host.ts                       # Zig 自带的 host 脚本
  config.json
```

包管理：`pi install <pkg>` ≈ `cd ~/.pi/extensions/<id> && bun install <pkg>`。

#### 6.B.7 权限模型

扩展权限**默认拒绝**，从三处汇总：

1. `extension.json.permissions` 声明
2. 用户在 `~/.pi/config.json` 里允许或拒绝
3. 运行时弹窗（首次访问敏感资源时）

宿主侧拦截点：
- **FS**：扩展走 `host/fs`，Zig 校验路径白名单
- **网络**：Bun 启动时通过 `--allow-net=...` 限制（Bun 已支持类 Deno 的权限 flag）
- **Shell**：扩展不允许直接 `child_process.spawn`，必须走 `host/shell`，Zig 决定是否放行

#### 6.B.8 与 TS 现有扩展 API 的对齐

阶段 1 的核心交付物是一个 **`@pi-agent/sdk`** npm 包，给扩展作者写 TS 时引入：

```ts
import { defineExtension, defineTool } from "@pi-agent/sdk";

export default defineExtension({
  id: "my-ext",
  tools: [
    defineTool({
      name: "my_tool",
      schema: { ... },
      async run(params, ctx) {
        ctx.log("hello");
        return { content: "..." };
      },
    }),
  ],
});
```

`@pi-agent/sdk` 内部把 `defineTool` 等翻译成 `register/tool` JSON-RPC 调用。
**TS 现有扩展只要换成这个 SDK，就能在 Zig 宿主下跑**。

如果当前 TS 版的 SDK 已经是同名同 shape，那直接复用，不再造新的。
**关键动作**：开工前，把 TS 现有 SDK 的所有公开签名导出成 `.d.ts`，作为 Zig 宿主的实现契约。

#### 6.B.9 错误处理与崩溃恢复

- **Bun 子进程崩溃**：Zig 监听退出码，记录 stderr，标记所有扩展为"unloaded"，向 TUI
  发提示，不影响主流程。
- **重启策略**：用户主动 `/reload-extensions`，或 Zig 在下一次需要扩展时惰性重启。
- **单个扩展抛错**：Bun host 用 `try/catch` 包住，回 `error` response，Zig 记录但不
  传染其他扩展。
- **协议错误**：收到不识别的 method 回 `MethodNotFound`，不识别的 id 回 `InvalidRequest`。
  连续 N 次协议错误则视为 host 行为异常，重启。

#### 6.B.10 测试策略

- **协议层**：用 Mock Bun host（一个 Zig 写的回放器）跑契约测试。
- **集成层**：跑一个真实 hello-world 扩展，覆盖 tool / command / provider / 流式 /
  错误 / 取消六类场景。
- **回归层**：从 TS 仓库选 3–5 个真实扩展，作为冒烟用例。
- **性能层**：单次 RPC < 5ms（本机 stdio），流式 chunk 延迟 < 10ms。

#### 6.B.11 阶段 1 工期细分（修正版）

| 子任务 | 估时 |
|---|---|
| 协议（帧格式 + JSON-RPC + 流式 + 取消） | 1 周 |
| Bun 子进程生命周期（启动/关闭/崩溃恢复） | 1 周 |
| Zig 端 binding（method 路由、`host/*` 实现） | 2 周 |
| TS 端 host.ts + `@pi-agent/sdk` | 2 周 |
| 权限模型（FS/Net/Shell 拦截） | 1 周 |
| 包管理（`pi install/remove/update/list/config`） | 1 周 |
| 扩展 manifest + 安装目录管理 | 0.5 周 |
| TS 扩展 API 契约对齐（按 `.d.ts` 实现） | 2–3 周 |
| 真实扩展联调（含意外坑） | 2–3 周 |
| 测试套件 | 1 周 |
| **合计** | **13.5–16.5 周** |

比初版的 8–13 周更接近真实数字。

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
