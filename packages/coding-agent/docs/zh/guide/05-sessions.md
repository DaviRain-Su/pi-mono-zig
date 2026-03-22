# 第5章：会话管理

> 树形会话、分支、压缩、导航

---

## 5.1 会话概念

### 什么是会话

会话是 pi 中一次完整的工作流程，包含：
- 所有消息历史
- 文件引用和修改
- 工具调用记录
- 自定义元数据

### 会话存储

会话文件保存在 `~/.pi/agent/sessions/`，格式为 JSONL：

```
~/.pi/agent/sessions/
  └── --home-user-projects-myapp--/
      ├── session-abc123.jsonl
      ├── session-def456.jsonl
      └── ...
```

---

## 5.2 树形结构

### 线性 vs 树形

传统对话是线性的：
```
消息1 → 消息2 → 消息3 → 消息4
```

pi 的会话是树形的：
```
          消息1
            │
      ┌─────┴─────┐
    消息2A      消息2B
      │           │
    消息3A      消息3B
                │
              消息4B（当前位置）
```

### 树形结构的优势

1. **安全实验**：尝试新想法不会破坏主线
2. **方案对比**：并行尝试多种解决方案
3. **错误恢复**：随时回到之前的决策点
4. **历史保留**：所有尝试都被记录，不会丢失

---

## 5.3 使用 /tree 导航

### 打开树视图

```
/tree
```

或按 `Escape` 两次。

### 树视图界面

```
┌─ Session Tree ─────────────────────────┐
│                                         │
│  [root] Initial commit                 │
│    ├─ [A] Add user auth                │
│    │   └─ [A1] Fix login bug    ← current
│    └─ [B] Alternative approach         │
│        └─ [B1] Use JWT                 │
│                                         │
│  [←/→] Navigate  [Enter] Select        │
│  [Ctrl+←/→] Jump branch  [l] Label     │
└─────────────────────────────────────────┘
```

### 导航操作

| 按键 | 操作 |
|-----|------|
| `↑/↓` | 上下移动 |
| `←/→` | 展开/折叠 |
| `Enter` | 选择当前节点继续 |
| `Ctrl+←/→` | 跳转到兄弟分支 |
| `l` | 添加标签 |
| `Escape` | 取消 |

### 实践示例

场景：你在开发一个登录功能，尝试了两种方案。

```
你: 实现用户登录功能
Agent: [实现了方案A]

你: /tree
    [选择 root，创建分支]
    
你: 用另一种方式实现登录
Agent: [实现了方案B]

你: /tree
    [可以在方案A和方案B之间切换比较]
    
你: [选择方案B继续]
Agent: [基于方案B继续开发]
```

---

## 5.4 分支操作

### 创建分支 (/fork)

从当前位置创建新会话：

```
/fork
```

选择要复制的历史节点，新会话将包含到该节点的所有历史。

### 使用场景

1. **主线开发**：当前会话继续主线
2. **实验分支**：/fork 创建实验会话
3. **对比选择**：实验成功后，可以选择合并思路

### 命令行分叉

```bash
pi --fork ~/.pi/agent/sessions/abc123.jsonl
```

---

## 5.5 会话压缩 (/compact)

### 为什么压缩

长会话会消耗大量上下文窗口。压缩将旧消息摘要，释放空间。

### 手动压缩

```
/compact
```

或带自定义提示：

```
/compact 保留所有API设计讨论，压缩实现细节
```

### 自动压缩

在 `settings.json` 中启用：

```json
{
  "compaction": {
    "enabled": true,
    "reserveTokens": 16384,
    "keepRecentTokens": 20000
  }
}
```

触发条件：
- 上下文接近上限时
- 发生上下文溢出错误时

### 压缩效果

压缩前：
```
[消息1] 用户: 你好
[消息2] 助手: 你好！有什么可以帮忙？
[消息3] 用户: 帮我写一个函数
[消息4] 助手: [100行代码实现]
[消息5] 用户: 修改一下
[消息6] 助手: [100行修改后代码]
...
[消息50] 用户: 最新修改
```

压缩后：
```
[摘要] 之前讨论了函数实现，经历了3次迭代，最终实现了...
[消息48] 用户: ...
[消息49] 助手: ...
[消息50] 用户: 最新修改
```

### 压缩策略

- 保留最近 N 条消息（默认6条）
- 摘要更早的消息
- 保留关键决策点

---

## 5.6 会话文件格式

### JSONL 结构

每行一个 JSON 对象：

```jsonl
{"type":"session","id":"abc123","timestamp":"2025-01-15T10:00:00Z","cwd":"/project"}
{"type":"message","id":"msg1","parentId":null,"message":{"role":"user","content":"你好"}}
{"type":"message","id":"msg2","parentId":"msg1","message":{"role":"assistant","content":"你好！"}}
{"type":"model_change","id":"evt1","parentId":"msg2","provider":"anthropic","modelId":"claude-4"}
{"type":"compaction","id":"compact1","parentId":"evt1","summary":"之前讨论了...","firstKeptEntryId":"msg48"}
```

### Entry 类型

| 类型 | 说明 |
|-----|------|
| `session` | 会话头信息 |
| `message` | 用户或助手消息 |
| `model_change` | 模型切换记录 |
| `thinking_level_change` | 思考级别切换 |
| `compaction` | 压缩点 |
| `branch_summary` | 分支摘要 |
| `custom` | 扩展自定义数据 |
| `label` | 标签 |

---

## 5.7 导入导出

### 导出会话

```
/export output.html
```

生成 HTML 文件，包含：
- 完整对话历史
- 代码高亮
- 可分享的格式

### 分享到 Gist

```
/share
```

上传到 GitHub Gist，生成分享链接。

### 复制内容

```
/copy
```

复制最后一条助手回复到剪贴板。

---

## 5.8 会话管理最佳实践

### 1. 定期命名

```
/name feature-user-auth
```

方便后续查找。

### 2. 重要节点打标签

在 `/tree` 视图中按 `l` 添加标签：
- `v1-working` - 第一个可用版本
- `before-refactor` - 重构前
- `api-finalized` - API 确定

### 3. 及时分叉

重大决策前 `/fork`，保留探索空间。

### 4. 适度压缩

长会话定期 `/compact`，保持上下文高效。

### 5. 清理旧会话

定期清理不再需要的会话文件：

```bash
ls -lt ~/.pi/agent/sessions/*/
# 删除旧的
rm ~/.pi/agent/sessions/--path--/session-old.jsonl
```

---

## 本章小结

- **树形结构**：安全实验、方案对比、错误恢复
- **/tree**：可视化导航，选择历史节点继续
- **/fork**：创建分支，并行探索
- **/compact**：压缩旧消息，释放上下文
- **命名和标签**：管理大量会话
