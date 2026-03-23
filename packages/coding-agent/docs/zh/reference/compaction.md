# 会话压缩与分支摘要

LLM 的上下文窗口有限。当对话变得太长时，pi 使用压缩来摘要旧内容，同时保留近期工作。本文涵盖自动压缩和分支摘要。

**源文件**（[pi-mono](https://github.com/badlogic/pi-mono)）：
- [`packages/coding-agent/src/core/compaction/compaction.ts`](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/compaction/compaction.ts) - 自动压缩逻辑
- [`packages/coding-agent/src/core/compaction/branch-summarization.ts`](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/compaction/branch-summarization.ts) - 分支摘要
- [`packages/coding-agent/src/core/compaction/utils.ts`](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/compaction/utils.ts) - 共享工具（文件跟踪、序列化）
- [`packages/coding-agent/src/core/session-manager.ts`](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/session-manager.ts) - 条目类型（`CompactionEntry`、`BranchSummaryEntry`）
- [`packages/coding-agent/src/core/extensions/types.ts`](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/extensions/types.ts) - 扩展事件类型

如需在项目中使用 TypeScript 定义，检查 `node_modules/@mariozechner/pi-coding-agent/dist/`。

## 概述

pi 有两种摘要机制：

| 机制 | 触发 | 目的 |
|-----|------|------|
| 压缩 | 上下文超过阈值，或 `/compact` | 摘要旧消息释放上下文 |
| 分支摘要 | `/tree` 导航 | 切换分支时保留上下文 |

两者使用相同的结构化摘要格式，并累积跟踪文件操作。

## 压缩

### 触发时机

自动压缩在以下情况触发：

```
contextTokens > contextWindow - reserveTokens
```

默认 `reserveTokens` 为 16384 token（可在 `~/.pi/agent/settings.json` 或 `<项目目录>/.pi/settings.json` 配置）。这为 LLM 响应预留空间。

也可通过 `/compact [instructions]` 手动触发，可选 instructions 用于聚焦摘要。

### 工作原理

1. **找到切分点**：从最新消息向后遍历，累积 token 估算直到达到 `keepRecentTokens`（默认 20k，可配置）
2. **提取消息**：从上次压缩（或开始）到切分点收集消息
3. **生成摘要**：调用 LLM 以结构化格式摘要
4. **追加条目**：保存带摘要和 `firstKeptEntryId` 的 `CompactionEntry`
5. **重新加载**：会话重新加载，使用摘要 + 从 `firstKeptEntryId` 开始的消息

```
压缩前：

  entry:  0     1     2     3      4     5     6      7      8     9
        ┌─────┬─────┬─────┬─────┬──────┬─────┬─────┬──────┬──────┬─────┐
        │ hdr │ usr │ ass │ tool │ usr │ ass │ tool │ tool │ ass │ tool│
        └─────┴─────┴─────┴──────┴─────┴─────┴──────┴──────┴─────┴─────┘
                └────────┬───────┘ └──────────────┬──────────────┘
               messagesToSummarize            kept messages
                                   ↑
                          firstKeptEntryId (entry 4)

压缩后（追加新条目）：

  entry:  0     1     2     3      4     5     6      7      8     9     10
        ┌─────┬─────┬─────┬─────┬──────┬─────┬─────┬──────┬──────┬─────┬─────┐
        │ hdr │ usr │ ass │ tool │ usr │ ass │ tool │ tool │ ass │ tool│ cmp │
        └─────┴─────┴─────┴──────┴─────┴─────┴──────┴──────┴─────┴─────┴─────┘
               └──────────┬──────┘ └──────────────────────┬───────────────────┘
                 not sent to LLM                    sent to LLM
                                                     ↑
                                          starts from firstKeptEntryId

LLM 看到的内容：

  ┌────────┬─────────┬─────┬─────┬──────┬──────┬─────┬──────┐
  │ system │ summary │ usr │ ass │ tool │ tool │ ass │ tool │
  └────────┴─────────┴─────┴─────┴──────┴──────┴─────┴──────┘
       ↑         ↑      └─────────────────┬────────────────┘
    prompt   from cmp          messages from firstKeptEntryId
```

### 分割 Turn

一个 "turn" 从用户消息开始，包含所有助手响应和工具调用，直到下一个用户消息。通常，压缩在 turn 边界切分。

当单个 turn 超过 `keepRecentTokens` 时，切分点落在 turn 中间的助手消息。这是 "分割 turn"：

```
分割 turn（单个巨大 turn 超过预算）：

  entry:  0     1     2      3     4      5      6     7      8
        ┌─────┬─────┬─────┬──────┬─────┬──────┬──────┬─────┬──────┐
        │ hdr │ usr │ ass │ tool │ ass │ tool │ tool │ ass │ tool │
        └─────┴─────┴─────┴──────┴─────┴──────┴──────┴─────┴──────┘
                ↑                                     ↑
         turnStartIndex = 1                  firstKeptEntryId = 7
                │                                     │
                └──── turnPrefixMessages (1-6) ───────┘
                                                      └── kept (7-8)

  isSplitTurn = true
  messagesToSummarize = []  （之前没有完整 turn）
  turnPrefixMessages = [usr, ass, tool, ass, tool, tool]
```

对于分割 turn，pi 生成两个摘要并合并：
1. **历史摘要**：之前的上下文（如有）
2. **Turn 前缀摘要**：分割 turn 的早期部分

### 切分点规则

有效切分点是：
- 用户消息
- 助手消息
- BashExecution 消息
- 自定义消息（custom_message、branch_summary）

永不在工具结果处切分（它们必须与工具调用一起）。

### CompactionEntry 结构

定义在 [`session-manager.ts`](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/session-manager.ts)：

```typescript
interface CompactionEntry<T = unknown> {
  type: "compaction";
  id: string;
  parentId: string;
  timestamp: number;
  summary: string;
  firstKeptEntryId: string;
  tokensBefore: number;
  fromHook?: boolean;  // 如果由扩展提供（旧字段名）
  details?: T;         // 实现特定数据
}

// 默认压缩使用此 details（来自 compaction.ts）：
interface CompactionDetails {
  readFiles: string[];
  modifiedFiles: string[];
}
```

扩展可在 `details` 中存储任何 JSON 可序列化数据。默认压缩跟踪文件操作，但自定义扩展实现可使用自己的结构。

见 [`prepareCompaction()`](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/compaction/compaction.ts) 和 [`compact()`](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/compaction/compaction.ts) 实现。

## 分支摘要

### 触发时机

使用 `/tree` 导航到不同分支时，pi 提供摘要你正在离开的工作。这会将左分支的上下文注入到新分支。

### 工作原理

1. **找到共同祖先**：旧位置和新位置共享的最深节点
2. **收集条目**：从旧叶子回溯到共同祖先
3. **按预算准备**：包含 token 预算内的消息（最新优先）
4. **生成摘要**：用结构化格式调用 LLM
5. **追加条目**：在导航点保存 `BranchSummaryEntry`

```
导航前的树：

         ┌─ B ─ C ─ D (旧叶子，被放弃)
    A ───┤
         └─ E ─ F (目标)

共同祖先：A
要摘要的条目：B, C, D

带摘要导航后：

         ┌─ B ─ C ─ D ─ [B,C,D 的摘要]
    A ───┤
         └─ E ─ F (新叶子)
```

### 累积文件跟踪

压缩和分支摘要都累积跟踪文件。生成摘要时，pi 从以下提取文件操作：
- 被摘要消息中的工具调用
- 之前压缩或分支摘要的 `details`（如有）

这意味着文件跟踪跨多次压缩或嵌套分支摘要累积，保留读写文件的完整历史。

### BranchSummaryEntry 结构

定义在 [`session-manager.ts`](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/session-manager.ts)：

```typescript
interface BranchSummaryEntry<T = unknown> {
  type: "branch_summary";
  id: string;
  parentId: string;
  timestamp: number;
  summary: string;
  fromId: string;      // 导航来源的条目
  fromHook?: boolean;  // 如果由扩展提供（旧字段名）
  details?: T;        // 实现特定数据
}

// 默认分支摘要使用此 details（来自 branch-summarization.ts）：
interface BranchSummaryDetails {
  readFiles: string[];
  modifiedFiles: string[];
}
```

与压缩相同，扩展可在 `details` 中存储自定义数据。

见 [`collectEntriesForBranchSummary()`](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/compaction/branch-summarization.ts)、[`prepareBranchEntries()`](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/compaction/branch-summarization.ts) 和 [`generateBranchSummary()`](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/compaction/branch-summarization.ts) 实现。

## 摘要格式

压缩和分支摘要使用相同的结构化格式：

```markdown
## 目标
[用户想要完成什么]

## 约束与偏好
- [用户提到的要求]

## 进度
### 已完成
- [x] [已完成任务]

### 进行中
- [ ] [当前工作]

### 阻塞
- [问题，如有]

## 关键决策
- **[决策]**: [理由]

## 下一步
1. [接下来应该做什么]

## 关键上下文
- [继续所需数据]

<read-files>
path/to/file1.ts
path/to/file2.ts
</read-files>

<modified-files>
path/to/changed.ts
</modified-files>
```

### 消息序列化

摘要前，消息通过 [`serializeConversation()`](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/compaction/utils.ts) 序列化为文本：

```
[User]: 他们说了什么
[Assistant thinking]: 内部推理
[Assistant]: 响应文本
[Assistant tool calls]: read(path="foo.ts"); edit(path="bar.ts", ...)
[Tool result]: 工具输出
```

这防止模型将其视为要继续的对话。

工具结果在序列化时截断为 2000 字符。超出限制的内容替换为标记，指示截断了多少字符。这使摘要请求保持在合理的 token 预算内，因为工具结果（尤其是 `read` 和 `bash`）通常是上下文大小的最大贡献者。

## 通过扩展自定义摘要

扩展可拦截并自定义压缩和分支摘要。见 [`extensions/types.ts`](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/extensions/types.ts) 事件类型定义。

### session_before_compact

自动压缩或 `/compact` 前触发。可取消或提供自定义摘要。见类型文件中的 `SessionBeforeCompactEvent` 和 `CompactionPreparation`。

```typescript
pi.on("session_before_compact", async (event, ctx) => {
  const { preparation, branchEntries, customInstructions, signal } = event;

  // preparation.messagesToSummarize - 要摘要的消息
  // preparation.turnPrefixMessages - 分割 turn 前缀（如果 isSplitTurn）
  // preparation.previousSummary - 之前压缩的摘要
  // preparation.fileOps - 提取的文件操作
  // preparation.tokensBefore - 压缩前的上下文 token
  // preparation.firstKeptEntryId - 保留消息开始位置
  // preparation.settings - 压缩设置

  // branchEntries - 当前分支上的所有条目（用于自定义状态）
  // signal - AbortSignal（传递给 LLM 调用）

  // 取消：
  return { cancel: true };

  // 自定义摘要：
  return {
    compaction: {
      summary: "你的摘要...",
      firstKeptEntryId: preparation.firstKeptEntryId,
      tokensBefore: preparation.tokensBefore,
      details: { /* 自定义数据 */ },
    }
  };
});
```

#### 将消息转换为文本

要用自己的模型生成摘要，使用 `serializeConversation` 转换消息：

```typescript
import { convertToLlm, serializeConversation } from "@mariozechner/pi-coding-agent";

pi.on("session_before_compact", async (event, ctx) => {
  const { preparation } = event;
  
  // 将 AgentMessage[] 转换为 Message[]，然后序列化为文本
  const conversationText = serializeConversation(
    convertToLlm(preparation.messagesToSummarize)
  );
  // 返回：
  // [User]: 消息文本
  // [Assistant thinking]: 思考内容
  // [Assistant]: 响应文本
  // [Assistant tool calls]: read(path="..."); bash(command="...")
  // [Tool result]: 输出文本

  // 现在发送给你的模型进行摘要
  const summary = await myModel.summarize(conversationText);
  
  return {
    compaction: {
      summary,
      firstKeptEntryId: preparation.firstKeptEntryId,
      tokensBefore: preparation.tokensBefore,
    }
  };
});
```

见 [custom-compaction.ts](../../../examples/extensions/custom-compaction.ts) 完整示例，使用不同模型。

### session_before_tree

`/tree` 导航前触发。无论用户是否选择摘要都会触发。可取消导航或提供自定义摘要。

```typescript
pi.on("session_before_tree", async (event, ctx) => {
  const { preparation, signal } = event;

  // preparation.targetId - 导航目标
  // preparation.oldLeafId - 当前位置（被放弃）
  // preparation.commonAncestorId - 共同祖先
  // preparation.entriesToSummarize - 将被摘要的条目
  // preparation.userWantsSummary - 用户是否选择摘要

  // 完全取消导航：
  return { cancel: true };

  // 提供自定义摘要（仅当 userWantsSummary 为 true 时使用）：
  if (preparation.userWantsSummary) {
    return {
      summary: {
        summary: "你的摘要...",
        details: { /* 自定义数据 */ },
      }
    };
  }
});
```

见类型文件中的 `SessionBeforeTreeEvent` 和 `TreePreparation`。

## 设置

在 `~/.pi/agent/settings.json` 或 `<项目目录>/.pi/settings.json` 配置压缩：

```json
{
  "compaction": {
    "enabled": true,
    "reserveTokens": 16384,
    "keepRecentTokens": 20000
  }
}
```

| 设置 | 默认值 | 描述 |
|-----|-------|------|
| `enabled` | `true` | 启用自动压缩 |
| `reserveTokens` | `16384` | 为 LLM 响应预留的 token |
| `keepRecentTokens` | `20000` | 保留的近期 token（不被摘要）|

使用 `"enabled": false` 禁用自动压缩。仍可通过 `/compact` 手动压缩。