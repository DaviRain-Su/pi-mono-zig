# Zig 实现 Review & 与 TS 版本的 Gap 分析

> 本文档跟踪 `zig/` 下的 Zig 实现与 `packages/coding-agent/`（TS 版）之间的差距。
> 最近一次更新：第三轮 review，覆盖 `agent/agent_loop.zig`、`ai/model_registry.zig`、
> `ai/root.zig`、`coding_agent/config.zig`、`coding_agent/print_mode.zig`、`json_event_wire.zig`。

---

## 0. 自上次 Review 以来的变化（已完成项）

### 一/二轮列出的硬伤已全部修复
- ✅ `interactive_mode.zig` 拆出 `shared / formatting / overlays / rendering / prompt_worker / slash_commands / input_dispatch / clipboard_image`
- ✅ `main.zig` 拆出 `cli/{bootstrap,input_prep,runtime_prep,output}.zig`
- ✅ CLI flags：`--no-builtin-tools` / `--no-context-files` / `--offline` / `--verbose` / `--export`
- ✅ slash 命令：`/scoped-models` / `/changelog`
- ✅ 剪贴板图片粘贴
- ✅ `AppContext` 替代全局 tool runtime
- ✅ `bash` 流式 / 超时 / 进程组 / 截断 / 安全 temp 全量输出 / 完整测试

### 第三轮列出的硬伤也已全部修复
- ✅ **bash `details` 已贯通**：`tool_adapters.zig` 的 `runBashTool` / `forwardBashToolUpdate` 都带 `.details`
- ✅ **bash `timeout` 别名兼容**：`parseArguments` 同时接受 `timeout_seconds` 和 `timeout`
- ✅ **`interactive_mode.zig` 再拆**：新增 `tool_adapters.zig` 与 `session_bootstrap.zig`
- ✅ **`rendering.zig` 锁优化**：`snapshotForRender()` 锁内取快照，渲染移到锁外

### 本轮新落地的大块进展
- ✅ **`agent/agent_loop.zig`**：真正的 agent runtime —— steering / follow-up drain、assistant 流式、tool 执行、before/after hook、并行/串行、abort 传递
- ✅ **`ai/model_registry.zig`**：内置 25+ provider 配置，模型目录扩大，scoped/精确匹配、provider 默认模型、`headers` 与 `compat` 字段
- ✅ **`json_event_wire.zig`**：显式转换 + `validateAgentEventJson` 校验，`assistantMessageEvent` / `partialResult` / `toolResults` / `details` 都有，stop-reason 归一化
- ✅ **`print_mode.zig`**：JSON 模式订阅链路完整，测试覆盖失败 / abort / 工具 / 跨 provider session continuation

---

## 1. 总体结论

- **核心 agent runtime / 内置工具 / session / 交互式 TUI / model registry / JSON wire** 已经接近 TS。
- 真正剩余 gap 集中在 **生态/控制面**：
  - 扩展（extension）运行时
  - 包管理子命令
  - TS-兼容 JSONL 控制协议（prompt/steer/follow_up/abort/get_messages/get_commands…）
  - 动态 provider / 自定义 UI
  - MCP（经扩展通道）
- **目标 = 独立可用的 Zig coding agent**：剩余 ≈ **1–2 周**（较上轮再缩短）。
- **目标 = 完全替代 TS**：剩余 ≈ **6–10+ 周**（生态层基本没动）。

---

## 2. 各模块 Parity（第三轮更新）

| 模块 | 上轮 | 现在 | 备注 |
|---|---:|---:|---|
| CLI / bootstrap | 88% | **89%** | 基本不变 |
| Agent 核心 loop / runtime | 82% | **89%** ↑↑ | `agent_loop.zig` 落地 |
| 内置 tools | 82% | **87%** | bash details/timeout 别名修复 |
| Sessions / 分支 / 导入导出 | 82% | **84%** | print-mode 跨 provider 续会话覆盖 |
| TUI / interactive | 78% | **85%** ↑ | 又一次拆分 + 渲染锁优化 |
| **JSON mode / event wire** | 88% | **93%** ↑ | 校验 + 富 schema |
| Providers / auth / model registry | 68% | **78%** ↑↑ | 注册广度 + 发现机制 |
| **RPC 协议兼容** | 30% | 30% | TS-JSONL 控制面尚缺 |
| **扩展 / 包管理 / 自定义 UI** | 12% | 12% | 生态层未动 |
| **MCP** | 5% | 5% | 未动 |

- **独立可用**：≈ **90%**
- **完全替代 TS**：功能 ≈ 60–65%，生态层依旧落后

---

## 3. 仍明确缺失的内容

### 3.1 CLI / 包管理
- `install` / `remove` / `uninstall` / `update` / `list` / `config`
- TS 风格 `unknownFlags` 透传给扩展（Zig 当前对未知 flag 直接报错）
- 扩展驱动的 help

### 3.2 Agent runtime host
- TS 的 `AgentSessionRuntime` 等 runtime-host 抽象
- 运行时 rebind/替换的生命周期
- 扩展 runner 集成 / runtime services 边界
- 通过扩展的动态 tools / providers / hooks

### 3.3 TS-兼容 JSONL RPC
当前 Zig 是干净的 JSON-RPC 2.0，缺以下控制语义：
- prompt / steer / follow_up / abort
- get/set model
- thinking / compaction / retry / bash 控制
- session 切换 / fork / clone / export
- `get_messages` / `get_commands`
- 扩展 UI request/response 通道

### 3.4 扩展 / 包 / 自定义 UI
- 扩展加载器/运行模型、命令、event bus
- 自定义 tools / providers / OAuth
- 扩展 UI requests / widgets / 编辑器 / footer 注入
- 完整 SDK / embed 故事

### 3.5 MCP
- 无 client / server / runtime 集成

---

## 4. 第三轮新发现的问题（待修）

### 4.1 `agent_loop.zig` 并行模式不是真·流式
- parallel 模式下每个 task 的 update **被缓冲**，所有线程 join 后才一次性 emit
- 结果是"并行执行"了但没有"并行流式 UX"
- **影响**：当前 Zig 版的 JSON/TUI 在并行 tool 场景下体验落后
- **修法**：把 update 通道改为线程安全的实时 emit，缓冲只在 sequential mode 用

### 4.2 toolcall 流式事件未对齐 text/thinking
- `streamAssistantResponse` 处理了 `text` / `thinking`
- `toolcall_start / delta / end` 没有同等待遇
- **影响**：JSON event 的 93% 富度被"差最后一公里"卡住
- **修法**：在 streaming 路径补 toolcall 三种 event

### 4.3 `coding_agent/config.zig` 在生产路径调 `ai.model_registry.resetForTesting()`
- 名字带 `forTesting` 的 hook 出现在 runtime 加载路径
- **影响**：架构异味，多 runtime / embed / 热重载场景下会冲突
- **修法**：引入显式 `clear()` / `reload()` API，把 testing-only hook 隔离

### 4.4 `config.zig` 大量 `catch {}` 静默吞错
- provider 注册 / 模型发现 / 模型注册都被吞掉
- **影响**：config 配错时用户看不到提示
- **修法**：收集到 `[]ConfigError` 列表，启动后统一告警；或用 logger 记录

### 4.5 全局可变状态新增项
- `ai/model_registry.zig` 的 `default_registry` 单例
- `coding_agent/print_mode.zig` 的 `active_abort_signal`
- 这些和早先的 `tui/keys.zig::kitty_protocol_active`、
  `interactive_mode/rendering.zig::active_resize_backend` 同类
- **修法**：能用显式 context 穿透就别用全局；signal handler 类的可保留但隔离

### 4.6 tool 结果时间戳仍是 0
- 小问题，但暴露了元数据贯通还有死角

### 4.7 `print_mode.zig` 的 abort watcher 是 2ms 轮询线程
- 简陋但能用；后续考虑 self-pipe / eventfd

### 4.8 `agent_loop.zig` 的所有权/分配器面广
- 手动 clone/deinit 多，回归风险高
- **建议**：加重点测试覆盖 parallel + hook 覆盖 + abort 三类路径

---

## 5. 单文件 Code Review（本轮）

### `zig/src/agent/agent_loop.zig`
- **质量：好，但现在是最该加固的高杠杆文件**。
- 编排清晰：prompt 入口 / assistant 流式 / tool 准备 / 执行 / 结果定型分得开。
- hook 点（`before_tool_call` / `after_tool_call` / context transforms）实用且可扩展。
- 主要问题：见 §4.1 / §4.2 / §4.6 / §4.8。

### `zig/src/ai/model_registry.zig`
- **质量：好**。clone/deinit 纪律好，匹配 API（精确 / scoped / 默认）实用。
- 主要问题：
  - `default_registry` 全局单例（§4.5）
  - 线性扫描（当前规模 OK）
  - `isAlias()` / `isBetterMatch()` 模糊匹配略脆，未来会有惊喜

### `zig/src/ai/root.zig`
- **质量：高**。barrel 干净。
- 小异味：`providers` 公共面没把 registry 里 25+ 内置 provider 一一镜像，可能让维护者困惑（非功能问题）。

### `zig/src/coding_agent/config.zig`
- **质量：中–好，但本轮最该清理的文件**。
- 优点：merged settings、offline-aware discovery、provider override / model list / compat / headers / cost / input types、`lookupApiKey()` 干净合并 auth-token 与 provider-key。
- 主要问题：
  - §4.3 `resetForTesting()` 被生产路径调用
  - §4.4 大量 `catch {}`
  - 配置加载会改全局 registry —— 多 runtime 场景下隐患

### `zig/src/coding_agent/print_mode.zig`
- **质量：好**。紧凑、可读，JSON 模式订阅链路完整。
- 测试覆盖好：失败 / abort / 工具 / 跨 provider session continuation。
- 小问题：§4.7（轮询 abort）+ §4.5（`active_abort_signal` 全局）。

---

## 6. 内部工程建议（更新版）

### 已部分完成
- ~~P1：拆分 `main.zig`~~ ✅
- ~~P1：拆分 `interactive_mode.zig`~~ 🟡（barrel 仍可继续瘦身）
- ~~P1：bash `details` 贯通 + `timeout` 别名~~ ✅
- ~~P1：`rendering.zig` 锁优化~~ ✅

### 仍要做
- **P2 — 全局可变状态**（§4.5）
- **P2 — `resetForTesting` 在生产路径**（§4.3）
- **P2 — `catch {}` 静默吞错**（§4.4）
- **P2 — 并行 tool 真·流式**（§4.1）
- **P2 — toolcall 流式事件补齐**（§4.2）
- **P3 — JSON 输出 golden 兼容性测试**（钉死 wire 契约）
- **P3 — TUI API 边角**：`Box` 边框依赖 theme、`theme.zig` 颜色解析静默忽略
- **P4 — 构建脚本**：`test-cross-area` shell 出 `bash`，Windows 不便携

---

## 7. 推荐路线图

### 路线 A：独立 Zig coding agent（**推荐先走完，约 1–2 周**）

按 ROI 排序：

1. **agent_loop 并行模式改真·流式** —— **M**，回报大
2. **toolcall 流式事件补齐** —— **S**，让 JSON event 真正完整
3. **去掉 `resetForTesting` 在生产路径**，引入 `clear/reload` —— **S**
4. **`catch {}` → 结构化 error 收集** —— **S–M**
5. **JSON 输出 golden 测试** —— **S–M**
6. **provider/auth UX 末段 polish** —— **M**
7. **TUI 末段细节**（剪贴板图片体验、队列模式等）—— **S**

### 路线 B：完全替代 TS（三阶段策略）

**前提决策已锁定**：必须兼容现有 TS 扩展生态 → 必须嵌一个 JS 运行时。
**选型**：Bun（已生产可用，Node API 兼容度远好于 Deno；当前 Bun 的 C embed API 仍在演进，
所以**先用子进程模式**集成，不内嵌）。

#### 阶段 1：Bun 作为扩展运行时（兼容期，**约 12–16 周**）

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

#### 阶段 1+2+3 合计

- 阶段 1：**12–16 周**（约 3–4 个月）
- 阶段 2：持续，无固定工期
- 阶段 3：**2–3 周**（按需启动）

依赖顺序：阶段 1 必须先完成。**未先做阶段 1 就去做 providers/MCP/UI 会反复返工。**

---

### 7.B 路线 B 阶段 1 详细设计

#### 7.B.1 进程模型

```
Zig 宿主进程
  └─ spawn ─→ Bun 子进程 (extension-host.ts)
                 ├─ 加载所有已安装扩展
                 ├─ 维护扩展实例生命周期
                 └─ 通过 stdio 与 Zig 通信
```

- 单 Bun 子进程承载所有扩展，扩展共享 Bun runtime
- 启动惰性、关闭走 `shutdown` 通知 + 超时 SIGTERM

#### 7.B.2 协议（JSON-RPC over stdio + 长度前缀）

帧格式（LSP 同款）：
```
Content-Length: <bytes>\r\n
\r\n
<json payload>
```

消息类型：Request / Response / Notification（双向都能发）。

#### 7.B.3 核心方法分类

**Zig → Bun**：`host/initialize` `host/shutdown` `extensions/{load,unload,reload,list}` `tool/invoke` `command/run` `provider/complete` `ui/event`
**Bun → Zig**：`register/{tool,command,provider,oauth,ui}` `session/{append,query}` `agent/emit` `host/{log,fs}` `ui/request`

注册调用幂等且必须在 `extensions/load` 期间完成。

#### 7.B.4 流式与事件

`{ stream_id }` + `stream/chunk` / `stream/end` / `stream/cancel` notification。

#### 7.B.5 扩展 manifest

```jsonc
{
  "id": "my-extension",
  "version": "1.0.0",
  "type": "node",
  "entry": "./dist/index.js",
  "engines": { "pi-agent": "^1.0" },
  "capabilities": { "tools": [...], "commands": [...], "providers": [...], "ui": [...] },
  "permissions": {
    "fs": { "read": ["${workspace}"], "write": [] },
    "net": { "domains": ["api.example.com"] },
    "shell": false
  }
}
```

#### 7.B.6 安装路径

```
~/.pi/
  bun/bun-1.1.x/
  extensions/<ext-id>@<version>/
  extension-host/host.ts
  config.json
```

包管理：`pi install <pkg>` ≈ `cd ~/.pi/extensions/<id> && bun install <pkg>`。

#### 7.B.7 权限模型

默认拒绝；汇总自 manifest / `~/.pi/config.json` / 运行时弹窗。
拦截点：FS（`host/fs`）、Net（Bun `--allow-net`）、Shell（`host/shell`）。

#### 7.B.8 与 TS 现有扩展 API 对齐

核心交付物：**`@pi-agent/sdk`** npm 包。
开工前先把 TS 现有 SDK 的所有公开签名导出成 `.d.ts`，作为 Zig 宿主实现契约。

#### 7.B.9 错误处理与崩溃恢复

- Bun 子进程崩溃：监听退出码 + stderr，标记扩展全 unloaded，TUI 提示。
- 单扩展抛错：host 端 try/catch 包住，不传染。
- 协议错误：N 次后视为异常重启。

#### 7.B.10 热重载

进程模式**完整支持热重载**，能力上对齐甚至超过 TS 版。三档：

**档 1：单个扩展热重载（最常用，不重启 Bun）**

```
Zig → extensions/unload { id }
        ↓
Bun host:
  1. 调扩展 onDeactivate() 钩子
  2. 从注册表移除该扩展的 tool / command / provider
  3. 清掉 import / require cache 里它的模块
        ↓
Zig → extensions/load { id }
        ↓
Bun host:
  1. 重新 import 入口
  2. 调 onActivate()
  3. 重新 register/*
```

要点：
- Bun ESM 用动态 `import(...?v=<bumped>)` 强制重新解析；CJS 用 `delete require.cache[...]`
- 扩展若需要保留状态，自己实现 `serialize()` / `restore()`，由 host 在 unload→load 之间转交

**档 2：全部扩展热重载**：遍历 `extensions/list`，逐个 unload + load。
适合配置或扩展列表变更。

**档 3：整个 Bun 子进程重启（drain & swap）**

进程边界送的额外能力：

```
Zig:
  1. 标记当前 Bun 子进程为 "draining"
  2. 等待 in-flight RPC 完成（或超时强杀）
  3. SIGTERM 老进程
  4. spawn 新 Bun 子进程
  5. 重新 host/initialize + 重载扩展集合
  6. 切换 Zig 端 client 句柄
```

优势：
- 彻底干净：清空 JS 内存泄漏 / 奇怪状态 / Bun 自身 bug
- **能换 Bun 版本**：下载新二进制后重启即生效
- 调试友好：用户 `/reload-extensions --hard` 一键归零

**触发方式**（建议都实现）：

1. 手动：slash 命令 `/reload-extensions [name]` 或 `/reload-extensions --hard`
2. 文件监听：扩展目录变化自动重载（宿主侧 `inotify` / `fsevents` 即可）
3. 包管理后：`pi install/update <pkg>` 完成自动 reload 对应扩展
4. 崩溃自愈：Bun 子进程异常退出 → Zig 自动 spawn 新进程 + 恢复扩展集合

**与 TS 版能力对比**：

| 能力 | TS 版 | Zig + Bun 子进程 |
|---|---|---|
| 单扩展热重载 | ✅ | ✅ |
| 全部扩展热重载 | ✅ | ✅ |
| 整个 runtime 重启 | ⚠️ 等于重启自己 | ✅ 更干净（进程边界） |
| 崩溃自愈 | ❌ runtime 崩 = 进程崩 | ✅ 白送 |

**额外工期**：约 **1 周**（合并进 §7.B.11 的 "Bun 子进程生命周期"，从 1 周扩到 1.5–2 周）。

#### 7.B.11 测试策略

- 协议层：Mock host 回放
- 集成层：hello-world 扩展跑通 6 类场景
- 回归层：从 TS 仓库选 3–5 个真实扩展冒烟
- 性能层：单 RPC < 5ms，流式 chunk 延迟 < 10ms

#### 7.B.12 阶段 1 工期细分

| 子任务 | 估时 |
|---|---|
| 协议（帧格式 + JSON-RPC + 流式 + 取消） | 1 周 |
| Bun 子进程生命周期 | 1 周 |
| Zig 端 binding（method 路由、`host/*` 实现） | 2 周 |
| TS 端 host.ts + `@pi-agent/sdk` | 2 周 |
| 权限模型（FS/Net/Shell） | 1 周 |
| 包管理 CLI | 1 周 |
| 扩展 manifest + 安装目录 | 0.5 周 |
| TS 扩展 API 契约对齐 | 2–3 周 |
| 真实扩展联调（含意外坑） | 2–3 周 |
| 测试套件 | 1 周 |
| **合计** | **13.5–16.5 周** |

---

## 8. 注意事项

- **不要把功能"存在" 当作"wire 兼容"**：JSON mode、RPC 两边都"有"，但协议不同。
- **Auth 已不是空壳**：Anthropic / GitHub Copilot / Google Gemini CLI 真实 OAuth 已可用。
- **bash / details / 流式 / 锁优化** 都已修，下一阶段重点是**控制面 + 静默错误**。
- **TS 是移动靶**：要"零 gap"先锁定一个 TS 版本号作为对齐基线，后续定期 rebase。

---

## 9. 一句话总结

> Zig 的 coding-agent 内核、交互层、工具、auth、model registry、JSON event wire 都已接近 TS；
> 剩下的真实 gap 是 **TS 的生态层** 和 **少量并行/静默错误硬伤**。
> 独立可用只剩 1–2 周 polish；要完全替代 TS 仍需 12–16 周（路线 B 阶段 1）。
