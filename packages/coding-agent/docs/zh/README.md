# pi 中文开发指南

> 一本关于 pi 的完整技术书籍：从入门到精通，从使用到二次开发。

---

## 30秒了解 pi

**一句话**：极简核心（4个工具）+ 无限扩展（Agent 自写代码）的 AI 编程助手。

**为什么不同**：
- 不是"下载扩展"，而是**让 Agent 写扩展**
- 不是"学习 MCP 协议"，而是**Bash + 代码**
- 不是"黑盒运行"，而是**会话树可控、可回溯**

**快速体验**：
```bash
npm install -g @mariozechner/pi-coding-agent
pi
# 然后告诉它："帮我创建一个检查代码风格的工具"
```

---

## 文档结构

```
docs/zh/
├── README.md              # 本文档 - 导航入口
├── BOOK.md                # 书籍总览
├── guide/                 # 📖 使用指南（按顺序阅读）
│   ├── 01-what-is-pi.md           # pi 是什么
│   ├── 02-architecture-story.md   # 架构故事
│   ├── 03-first-hour.md           # 第一个小时
│   ├── 04-commands.md             # 命令与快捷键
│   ├── 05-sessions.md             # 会话管理
│   ├── 06-skills.md               # Skill 系统
│   ├── 07-healthy-usage.md        # 健康使用指南
│   ├── 08-first-extension.md      # 你的第一个扩展
│   ├── 09-extension-api.md        # 扩展 API 详解
│   └── 15-design-decisions.md     # 设计决策
├── patterns/              # 🎨 设计模式
│   └── 10-patterns.md             # 实战模式
├── cookbook/              # 🍳 代码食谱
│   └── 11-cookbook.md             # Cookbook
└── reference/             # 📚 技术参考
    ├── architecture-overview.md          # 架构概览
    ├── deep-dive-architecture.md         # 深度架构分析
    ├── 12-source-architecture.md         # 源码架构
    ├── 13-model-system.md                # 模型系统
    ├── 14-embedding.md                   # 嵌入与集成
    ├── embedding-and-rpc.md              # RPC 指南
    ├── extensions-and-sdks.md            # SDK 指南
    ├── model-provider-architecture.md    # Provider 架构
    ├── comparison-bub.md                 # 与 Bub 框架对比
    ├── comparison-claude-code.md         # 与 Claude Code 对比
    ├── comparison-opencode.md            # 与 OpenCode 对比
    └── zig-ecosystem-analysis.md         # Zig 生态综合分析与演进规划
```

---

## 阅读路径

### 🚀 快速入门（1小时）

按顺序阅读 guide/ 前3章：
1. [pi 是什么](./guide/01-what-is-pi.md) - 15分钟
2. [架构故事](./guide/02-architecture-story.md) - 20分钟
3. [第一个小时](./guide/03-first-hour.md) - 25分钟

### 🛠️ 扩展开发（4小时）

1. [你的第一个扩展](./guide/08-first-extension.md) - 40分钟
2. [扩展 API 详解](./guide/09-extension-api.md) - 90分钟
3. [实战模式](./patterns/10-patterns.md) - 60分钟
4. [Cookbook](./cookbook/11-cookbook.md) - 参考查阅
5. [设计决策](./guide/15-design-decisions.md) - 30分钟

### 📚 全面掌握（按需查阅）

- **使用问题**：guide/ 目录
- **代码片段**：cookbook/
- **架构理解**：reference/
- **设计模式**：patterns/
- **框架对比**：
  - [与 Bub 框架对比](./reference/comparison-bub.md)
  - [与 Claude Code 对比](./reference/comparison-claude-code.md)
  - [与 OpenCode 对比](./reference/comparison-opencode.md)
- **演进规划**：
  - [Zig 生态综合分析](./reference/zig-ecosystem-analysis.md) - pi-mono Zig 版本演进路线图

---

## 核心设计理念

pi 遵循 **"Agent构建Agent"** 的哲学：

- **最小核心**：只有4个基础工具（Read/Write/Edit/Bash），极短系统提示
- **最大扩展性**：所有高级功能通过扩展/技能实现
- **自举能力**：Agent可以编写、测试、迭代自己的扩展
- **热重载支持**：扩展修改后 `/reload` 立即生效，无需重启
- **渐进式披露**：Skills只有描述常驻上下文，完整内容按需加载

**为什么不是MCP？** pi故意不将MCP作为核心机制——Agent可以直接编写代码扩展自己，比下载预构建服务器更自然。

---

## 外部参考

### 设计理念
- [Armin Ronacher: Pi - The Minimal Agent Within OpenClaw](https://lucumr.pocoo.org/2026/1/31/pi/) - pi设计理念与实践
- [Mario Zechner: What if you don't need MCP at all?](https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/) - 为什么Skill优于MCP
- [Armin Ronacher: A Language For Agents](https://lucumr.pocoo.org/2026/2/9/a-language-for-agents/) - Agent友好的代码设计原则
- [Armin Ronacher: Agent Psychosis](https://lucumr.pocoo.org/2026/1/18/agent-psychosis/) - 健康使用Agent的警示与建议

### 实战案例
- [Armin Ronacher: Advent of Slop](https://lucumr.pocoo.org/2025/12/23/advent-of-slop/) - Claude完全自主完成Advent of Code 2025
- [Armin Ronacher: The Final Bottleneck](https://lucumr.pocoo.org/2026/2/13/the-final-bottleneck/) - 代码审查成为新瓶颈的思考

---

## 维护与贡献

- 新增中文文档请统一放在 `docs/zh/` 目录
- 与实现关联紧密的文档建议保留架构图和数据流说明
- 变更时同时检查对应英文原文，避免文档与实现漂移
- 欢迎提交 PR 补充更多实战案例和模式

---

*本书与 pi 代码库同步更新，最后更新时间：2025年3月*
