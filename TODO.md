# TODO：pi-mono-zig 与 `packages/coding-agent` TS 对齐清单

> 目标：让 Zig 实现逐步靠齐 TS 的会话/compaction/CLI 语义。
> 当前约定：可直接勾选。

## 进度说明
- ✅ 已完成（可先不改）
- 🟨 部分对齐（有实现但未完整）
- ❌ 未对齐（尚未实现）
- [ ] 未完成/待实现
- [x] 已完成

## 0) 已确认已对齐（先验验收）
- [x] `list` / `tree` / `show` / `replay` 的核心输出与测试链路可用且稳定。
- [x] `--dry-run` 的 `compact` 不改写文件。
- [x] `label` 为非业务结构，不参与非 verbose 的上下文。
- [x] `tokens` 估算优先级：`usageTotalTokens > tokensEst > heuristic`。
- [x] Zig 0.16 I/O/API 兼容（`std.process.Init`、`std.Io`、`trimStart`）。

---

## 1) P0 - 会话数据模型与会话上下文（最高优先）

### 1.1 `SessionEntry` 语义对齐（文件：`src/session_types.zig`）
- [x] `thinking_level_change` 条目：`thinkingLevel`。
- [x] `model_change` 条目：`provider`、`modelId`。
- [x] `compaction` 条目：`firstKeptEntryId`、`tokensBefore`、`details`、`fromHook`。
- [x] `branch_summary` 条目：`fromId`、`details`、`fromHook`。
- [x] `custom` 条目：`customType`、`data`（不进 LLM 上下文）。
- [x] `custom_message` 条目：`customType`、`content`、`details`、`display`（可进上下文）。
- [x] `session_info` 条目：`name`。

### 1.2 session header 与迁移（文件：`src/session_manager.zig` + `src/session_types.zig`）
- [x] `SessionHeader` 加 `version`。
- [x] 实现 `parentSession` 字段（用于 fork）支持。
- [ ] 增加基础迁移：`v1 -> v2 -> v3`（或至少兼容旧头与旧字段）。

### 1.3 上下文构建（文件：`src/session_manager.zig`）
- [x] 引入 `buildSessionContext` 近似 TS 语义：
  - [x] 按 `leaf` 到根构建路径。
  - [x] 将 `compaction` 转为 summary message + 保留区间 messages。
  - [x] 将 `branch_summary` 转为可供 LLM 使用的上下文消息。
  - [x] 将 `custom_message` 转为上下文消息。
  - [x] 过滤掉 `custom`（不进上下文）。

---

## 2) P0 - Compact / Branch Summarization（最高优先）

### 2.1 Compact 语义（文件：`src/main.zig`、`src/session_manager.zig`）
- [ ] 用 TS 风格 `CompactionPreparation` 流程重构：
  - [ ] 从上一次 compaction 之后开始统计。
  - [ ] 找 cut point（支持 `keepRecentTokens`/`keep_recent` 的 window 策略）。
  - [ ] 处理 `isSplitTurn` 场景（turn 未完成分割）。
- [ ] `compact` 持久化条目使用 `compaction` 类型（而非普通 summary）
  - [ ] 字段包含：`firstKeptEntryId`、`tokensBefore`。
  - [ ] 持久化 `details`（至少 file read/edit 轨迹）。
- [ ] 若 TS token 来源可接入，优先走 `tokensBefore`/provider usage 路径；否则保持 fallback 估算。

### 2.2 Branch summary（文件：`src/session_manager.zig`、`src/main.zig`）
- [ ] 在分支切换时支持 `branchWithSummary`。
- [ ] 生成 `branch_summary` 并写入上下文树（含 `fromId` + 可选 `details`）。
- [ ] 与 compaction 一致处理 `details` 文件轨迹累计。

### 2.3 自动压缩触发策略（文件：`src/main.zig`）
- [ ] 对齐 TS 的触发公式：`contextTokens > contextWindow - reserveTokens`。
- [ ] `reserveTokens/keepRecentTokens` 配置可配置化（不必先 1:1，但要结构化）。

---

## 3) P1 - 会话管理与命令能力

### 3.1 会话目录与生命周期（文件：`src/session_manager.zig`）
- [ ] `SessionManager.create`/`open`/`continueRecent` 对齐
- [ ] `list`（当前 cwd）/`listAll`（跨项目）接口。
- [ ] `findMostRecentSession`/会话排序。
- [ ] `SessionInfo` 采集（id、path、cwd、name、modified、firstMessage）。
- [ ] 支持 in-memory 模式。

### 3.2 会话标记与分支（文件：`src/session_manager.zig`）
- [ ] `appendLabelChange` 语义（可清除 label）。
- [ ] `getLabel/getBranch` 等查询 API。
- [ ] `createBranchedSession`（fork/export 分支路径）。

### 3.3 `SessionInfo` 元数据（文件：`src/session_manager.zig`）
- [ ] 支持 `appendSessionInfo`。
- [ ] `getSessionName` 返回最近一次名称。

### 3.4 CLI 命令对齐（文件：`src/main.zig`）
- [ ] `--resume`、`--continue`、`--session` 查找规则（ID 前缀匹配/跨路径确认）。
- [ ] `--session-dir` 默认目录策略。
- [ ] `show` 输出按条目分类对齐（可继续强化）。

---

## 4) P1 - compact/branch 之外的 TS 主 CLI 生态

### 4.1 运行模式（文件：`src/main.zig`）
- [ ] `print` / `text` / `rpc` 模式入口。
- [ ] 与 stdin/piped 输入行为一致。

### 4.2 设置与模型解析前置（文件：`src/main.zig`）
- [ ] 初始 `SettingsManager` / `ModelRegistry` / `parseArgs` 二段解析。
- [ ] `--provider` `--model` `--models` 及模式化模型选择。
- [ ] `--list-models` 展示能力。

---

## 5) P0/P1 - 模型、工具与扩展（核心差距）

### 5.1 模型接入（文件：`src/mock_model.zig` / 新 `model` 适配）
- [ ] 用真实 provider 后端替代纯 mock 流。
- [ ] 对齐 `thinkingLevel`（off/minimal/low/medium/high/xhigh）。

### 5.2 工具系统（文件：`src/tools.zig`）
- [ ] 补齐/接入 TS 工具映射：`read` / `bash` / `edit` / `write` + 可扩展。
- [ ] 与 `SessionEntry` 的 tool_call/result args 结构对齐（payload 可扩展）。

### 5.3 扩展生态（文件：`src/main.zig`）
- [ ] 加载 extension / skill / theme / template 的入口。
- [ ] extension flag 注册与未知 flag 分发。

---

## 6) P2 - 收敛与回归

- [ ] 补齐 session/compaction/branch 的单测（最少涵盖 parse、迁移、上下文构建、split-turn）。
- [ ] 提供 `README` 与实现状态同步（“MVP”说明 + 已对齐范围）。
- [ ] 每完成一项及时打勾并补对应验收测试。

---

## 里程碑（建议）

- **M1（短期）**：完成第 1/2 节 P0 核心清单。
- **M2（中期）**：完成第 3/4 节 P1 结构化会话能力。
- **M3（长期）**：完成第 5/6 节生态接入。

_Last updated: 2026-02-15_