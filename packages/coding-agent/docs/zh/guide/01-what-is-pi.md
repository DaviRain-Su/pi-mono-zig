# 第1章：pi 是什么

> 核心理念、与其他工具对比、快速开始

---

## 1.1 一句话定义

**pi 是一个极简核心（4个工具）+ 无限扩展（Agent 自写代码）的 AI 编程助手。**

它不是 IDE 插件，不是代码补全工具，而是一个**能与你在终端对话、理解你的意图、执行代码并迭代改进**的编程伙伴。

---

## 1.2 核心设计哲学

### "Agent 构建 Agent"

传统软件：人类编写代码 → 编译 → 运行

pi 的方式：人类描述意图 → Agent 编写代码 → 执行 → 迭代

关键洞察：**Agent 擅长写代码，让它写代码来扩展自己**。

### 四个基础工具

pi 的核心只有这 4 个工具：

| 工具 | 功能 | 示例 |
|-----|------|------|
| `read` | 读取文件内容 | `read src/index.ts` |
| `write` | 写入新文件 | `write config.json "{}"` |
| `edit` | 修改现有文件 | `edit src/index.ts` |
| `bash` | 执行 shell 命令 | `bash npm test` |

**为什么只有 4 个？**

因为 Agent 可以用 `bash` 执行任何命令，用 `write/edit` 创建新工具。4 个工具足够构建任何功能，同时保持上下文最小。

### 自举能力

pi 可以用自己扩展自己：

1. 你告诉 pi："帮我创建一个代码检查工具"
2. pi 在 `~/.pi/extensions/my-linter/` 创建文件
3. 你执行 `/reload`
4. 新工具立即可用

这不是下载预构建的扩展，而是**Agent 根据你的需求现场编写**。

---

## 1.3 与其他工具的对比

### pi vs Copilot / Codeium

| | Copilot | pi |
|--|---------|-----|
| 交互方式 | 代码补全 | 对话式 |
| 上下文 | 当前文件 | 整个项目 + 会话历史 |
| 工具 | 无 | 读写文件、执行命令 |
| 迭代 | 手动 | 自动执行测试并修复 |

**类比**：Copilot 是自动补全的副驾驶，pi 是能独立执行任务的搭档。

### pi vs Claude Code / Cursor

| | Claude Code | pi |
|--|-------------|-----|
| 核心工具 | 内置多种工具 | 4 个基础工具 |
| 扩展方式 | 预设功能 | 自写扩展 |
| 会话管理 | 线性历史 | 树形分支 |
| 开源 | 否 | 是 |

**类比**：Claude Code 是功能丰富的瑞士军刀，pi 是可塑形的黏土。

### pi vs MCP (Model Context Protocol)

| | MCP | pi |
|--|-----|-----|
| 工具获取 | 下载预构建服务器 | Agent 现场编写 |
| 协议复杂度 | 需要学习协议 | Bash + 代码 |
| 上下文占用 | 工具描述常驻 | Skill 渐进式披露 |
| 修改难度 | 需理解服务器代码 | 直接让 Agent 修改 |

**关键区别**：MCP 是"下载工具"，pi 是"让 Agent 写工具"。

---

## 1.4 快速开始

### 安装

```bash
npm install -g @mariozechner/pi-coding-agent
```

### 首次运行

```bash
pi
```

你会看到：
1. 启动界面，显示快捷键和已加载的扩展
2. 底部状态栏：当前目录、模型、token 使用
3. 输入框等待你的消息

### 第一个对话

**你**：帮我创建一个统计代码行数的工具

**pi**：
```
我来帮你创建一个代码行数统计工具。

<write path="~/.pi/extensions/line-counter/index.ts">
import { Type } from '@sinclair/typebox';

export default function (pi) {
  pi.registerTool({
    name: 'count-lines',
    description: 'Count lines of code in a directory',
    parameters: Type.Object({
      path: Type.String({ description: 'Directory to analyze' }),
      extension: Type.Optional(Type.String({ description: 'File extension filter' })),
    }),
    async execute(toolCallId, args, signal, onUpdate, ctx) {
      const { stdout } = await ctx.exec('find', [args.path, '-name', args.extension || '*', '-type', 'f', '-exec', 'wc', '-l', '{}', '+']);
      return {
        content: [{ type: 'text', text: stdout }],
      };
    },
  });
}
</write>

工具已创建。执行 `/reload` 加载它。
```

**你**：/reload

**pi**：扩展已重新加载。现在你可以使用 `count-lines` 工具了。

**你**：用刚才的工具统计 src 目录的 TypeScript 文件

**pi**：
```
<count-lines path="src" extension="*.ts" />

执行结果：
  42 src/index.ts
  15 src/utils.ts
  57 total
```

---

## 1.5 核心概念速览

### Skill（技能）

- **是什么**：提示工程 + 辅助脚本的组合
- **存放位置**：`~/.pi/skills/` 或项目 `.pi/skills/`
- **使用方式**：`/skill:name` 或 Agent 自动识别
- **特点**：渐进式披露，只有描述常驻上下文

### Extension（扩展）

- **是什么**：TypeScript 代码，可注册工具、命令、事件处理器
- **存放位置**：`~/.pi/extensions/`
- **使用方式**：自动加载，热重载
- **特点**：功能强大，可自定义 UI

### Session（会话）

- **是什么**：树形结构的对话历史
- **特点**：
  - 分支（fork）：从任意点创建新分支
  - 导航（navigate）：回到历史任意点
  - 压缩（compact）：摘要旧消息节省上下文

---

## 1.6 下一步

- 想了解架构？阅读 [第2章：架构故事](./02-architecture-story.md)
- 想马上使用？阅读 [第3章：第一个小时](./03-first-hour.md)
- 想写扩展？跳到 [第8章：你的第一个扩展](./08-first-extension.md)

---

## 本章小结

- **pi = 4 个基础工具 + 无限自写扩展**
- **核心哲学**：Agent 构建 Agent
- **与 MCP 的区别**：写代码 vs 下载工具
- **关键特性**：树形会话、热重载、渐进式披露
