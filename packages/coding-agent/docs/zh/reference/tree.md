# 会话树导航

`/tree` 命令提供会话历史的树形导航。

## 概述

会话存储为树，每个条目有 `id` 和 `parentId`。"leaf" 指针跟踪当前位置。`/tree` 让你导航到任意点，并可选择摘要你正在离开的分支。

### 与 `/fork` 的对比

| 特性 | `/fork` | `/tree` |
|------|---------|---------|
| 视图 | 用户消息的扁平列表 | 完整树结构 |
| 操作 | 提取路径到**新会话文件** | 在**同一会话**中更改 leaf |
| 摘要 | 从不 | 可选（用户提示）|
| 事件 | `session_before_fork` / `session_fork` | `session_before_tree` / `session_tree` |

## 树 UI

```
├─ user: "Hello, can you help..."
│  └─ assistant: "Of course! I can..."
│     ├─ user: "Let's try approach A..."
│     │  └─ assistant: "For approach A..."
│     │     └─ [compaction: 12k tokens]
│     │        └─ user: "That worked..."  ← active
│     └─ user: "Actually, approach B..."
│        └─ assistant: "For approach B..."
```

### 控制

| 键 | 操作 |
|-----|------|
| ↑/↓ | 导航（深度优先顺序）|
| ←/→ | 向上/向下翻页 |
| Ctrl+←/Ctrl+→ 或 Alt+←/Alt+→ | 折叠/展开并跳转到分支段之间 |
| Enter | 选择节点 |
| Escape/Ctrl+C | 取消 |
| Ctrl+U | 切换：仅用户消息 |
| Ctrl+O | 切换：显示全部（包括自定义/标签条目）|

`Ctrl+←` 或 `Alt+←` 如果当前节点可折叠则折叠它。可折叠节点是根节点和有可见子节点的分支段起点。如果当前节点不可折叠或已折叠，选择跳转到上一个可见的分支段起点。

`Ctrl+→` 或 `Alt+→` 如果当前节点已折叠则展开它。否则，选择跳转到下一个可见的分支段起点，或者当没有更远的分支点时跳转到分支结束。

### 显示

- 高度：终端高度的一半
- 当前 leaf 标记 `← active`
- 标签内联显示：`[label-name]`
- 可折叠分支起点在连接符中显示 `⊟`。已折叠分支显示 `⊞`
- 活动路径标记 `•` 在适用时出现在折叠指示符后
- 搜索和过滤变更重置所有折叠
- 默认过滤器隐藏 `label` 和 `custom` 条目（在 Ctrl+O 模式显示）
- 子节点按时间戳排序（最旧在前）

## 选择行为

### 用户消息或自定义消息
1. Leaf 设置为所选节点的**父节点**（如果根则为 `null`）
2. 消息文本放入**编辑器**以便重新提交
3. 用户编辑并提交，创建新分支

### 非用户消息（助手、压缩等）
1. Leaf 设置为**所选节点**
2. 编辑器保持为空
3. 用户从该点继续

### 选择根用户消息
如果用户选择第一条消息（无父节点）：
1. Leaf 重置为 `null`（空对话）
2. 消息文本放入编辑器
3. 用户实际上从头开始

## 分支摘要

切换分支时，用户有三个选项：

1. **不摘要** - 立即切换，不进行摘要
2. **摘要** - 使用默认提示生成摘要
3. **带自定义提示摘要** - 打开编辑器输入附加焦点指令，追加到默认摘要提示

### 摘要内容

从旧 leaf 回溯到与目标的共同祖先的路径：

```
A → B → C → D → E → F  ← 旧 leaf
        ↘ G → H        ← 目标
```

被放弃的路径：D → E → F（被摘要）

摘要在以下停止：
1. 共同祖先（始终）
2. 压缩节点（如果先遇到）

### 摘要存储

存储为 `BranchSummaryEntry`：

```typescript
interface BranchSummaryEntry {
  type: "branch_summary";
  id: string;
  parentId: string;      // 新 leaf 位置
  timestamp: string;
  fromId: string;        // 我们放弃的旧 leaf
  summary: string;       // LLM 生成的摘要
  details?: unknown;     // 可选的 hook 数据
}
```

## 实现

### AgentSession.navigateTree()

```typescript
async navigateTree(
  targetId: string,
  options?: {
    summarize?: boolean;
    customInstructions?: string;
    replaceInstructions?: boolean;
    label?: string;
  }
): Promise<{ editorText?: string; cancelled: boolean }>
```

选项：
- `summarize`：是否生成被放弃分支的摘要
- `customInstructions`：摘要器的自定义指令
- `replaceInstructions`：如果为 true，`customInstructions` 替换默认提示而不是追加
- `label`：附加到分支摘要条目的标签（如果不摘要则附加到目标条目）

流程：
1. 验证目标，检查无操作（目标 === 当前 leaf）
2. 查找旧 leaf 和目标之间的共同祖先
3. 收集要摘要的条目（如果请求）
4. 触发 `session_before_tree` 事件（hook 可以取消或提供摘要）
5. 如果需要运行默认摘要器
6. 通过 `branch()` 或 `branchWithSummary()` 切换 leaf
7. 更新 agent：`agent.replaceMessages(sessionManager.buildSessionContext().messages)`
8. 触发 `session_tree` 事件
9. 通过会话事件通知自定义工具
10. 如果选择了用户消息，返回带 `editorText` 的结果

### SessionManager

- `getLeafUuid(): string | null` - 当前 leaf（如果为空则 null）
- `resetLeaf(): void` - 将 leaf 设为 null（用于根用户消息导航）
- `getTree(): SessionTreeNode[]` - 完整树，子节点按时间戳排序
- `branch(id)` - 更改 leaf 指针
- `branchWithSummary(id, summary)` - 更改 leaf 并创建摘要条目

### InteractiveMode

`/tree` 命令显示 `TreeSelectorComponent`，然后：
1. 提示摘要
2. 调用 `session.navigateTree()`
3. 清除并重新渲染聊天
4. 如果适用则设置编辑器文本

## Hook 事件

### `session_before_tree`

```typescript
interface TreePreparation {
  targetId: string;
  oldLeafId: string | null;
  commonAncestorId: string | null;
  entriesToSummarize: SessionEntry[];
  userWantsSummary: boolean;
  customInstructions?: string;
  replaceInstructions?: boolean;
  label?: string;
}

interface SessionBeforeTreeEvent {
  type: "session_before_tree";
  preparation: TreePreparation;
  signal: AbortSignal;
}

interface SessionBeforeTreeResult {
  cancel?: boolean;
  summary?: { summary: string; details?: unknown };
  customInstructions?: string;    // 覆盖自定义指令
  replaceInstructions?: boolean;  // 覆盖替换模式
  label?: string;                 // 覆盖标签
}
```

扩展可以通过从 `session_before_tree` 处理器返回 `customInstructions`、`replaceInstructions` 和 `label` 来覆盖它们。

### `session_tree`

```typescript
interface SessionTreeEvent {
  type: "session_tree";
  newLeafId: string | null;
  oldLeafId: string | null;
  summaryEntry?: BranchSummaryEntry;
  fromHook?: boolean;
}
```

### 示例：自定义摘要器

```typescript
export default function(pi: HookAPI) {
  pi.on("session_before_tree", async (event, ctx) => {
    if (!event.preparation.userWantsSummary) return;
    if (event.preparation.entriesToSummarize.length === 0) return;
    
    const summary = await myCustomSummarizer(event.preparation.entriesToSummarize);
    return { summary: { summary, details: { custom: true } } };
  });
}
```

## 错误处理

- 摘要失败：取消导航，显示错误
- 用户中止（Escape）：取消导航
- Hook 返回 `cancel: true`：静默取消导航