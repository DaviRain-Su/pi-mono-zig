---
title: 导言
---

# 导言

这本书的目标只有一个：**让你能从零亲手写出一个 AI 编码代理**。

我们以 [`pi-mono`](https://github.com/DaviRain-Su/pi-mono-zig) 这个真实项目作为蓝本——它是一个用 TypeScript 写成、正在被 Zig 重写的 AI 编码代理。你跟着这本书走完，会得到两件东西：

1. **概念**：什么是 LLM、Tool Calling、Agent Loop、Provider 抽象、扩展机制；
2. **代码**：每一章的概念都会在仓库里有对应的可运行代码（TypeScript 与 Zig 双版本对照）。

## 这本书写给谁

- **想入门 AI Agent 工程的开发者**：你听过 ChatGPT、Claude，但不确定"从 API 到 Agent"中间发生了什么。
- **正在或想转向 Zig 的人**：你想看一个真实、非玩具规模的 Zig 项目是怎么写的。
- **从 TypeScript/Node.js 看向系统编程的人**：每个抽象都给出 TS 和 Zig 两种实现，对照着看比单独看任何一种都更有效。

## 章节地图

| 章 | 主题 | 你将学到 |
| --- | --- | --- |
| 1 | 什么是 AI Agent | LLM 与 Agent 的边界、循环 vs 一次性调用 |
| 2 | LLM API 的本质 | messages、tokens、streaming、SSE |
| 3 | Tool Calling | function schema、tool_use、tool_result |
| 4 | Provider 抽象 | OpenAI / Anthropic / Google 的差异如何抹平 |
| 5 | Agent Loop | 状态机、轮次、终止条件 |
| 6 | Coding Agent | 文件 IO、shell、安全边界 |
| 7 | 扩展机制 | WASM、子 Agent、能力边界 |
| 8 | TUI 与会话 | 流式输出、回放、可中断 |

::: tip 阅读方式
每一章都遵循同一个结构：**概念 → 图 → 最小代码 → 仓库里完整代码的导览**。如果只想要概念，看前两节就够；想动手，跟着第三节抄一遍。
:::

::: info 你需要的前置知识
- 任何一门主流编程语言到能写小项目的程度
- 知道 HTTP 是什么、JSON 是什么
- **不**需要懂 Zig，我们会边用边讲
- **不**需要做过机器学习
:::

准备好了？我们从第 1 章开始：[**什么是 AI Agent →**](./what-is-an-agent)
