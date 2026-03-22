# 《pi 中文开发指南》

> 一本关于 pi 的完整技术书籍：从入门到精通，从使用到二次开发。

**版本**：v1.0  
**总页数**：约 7,500 行  
**完成度**：100%

---

## 目录结构

```
docs/zh/
├── README.md              # 导航入口
├── BOOK.md                # 本书（当前文件）
├── guide/                 # 📖 使用指南
├── patterns/              # 🎨 设计模式
├── cookbook/              # 🍳 代码食谱
└── reference/             # 📚 技术参考
```

---

## 📖 使用指南 (guide/)

按顺序阅读，从入门到精通。

| # | 章节 | 页数 | 阅读时间 | 内容 |
|---|------|------|---------|------|
| 1 | [pi 是什么](./guide/01-what-is-pi.md) | 198 | 15分钟 | 核心理念、与其他工具对比、快速开始 |
| 2 | [架构故事](./guide/02-architecture-story.md) | 210 | 20分钟 | 用餐厅比喻理解五层架构 |
| 3 | [第一个小时](./guide/03-first-hour.md) | 354 | 25分钟 | 安装、配置、基本使用 |
| 4 | [命令与快捷键](./guide/04-commands.md) | 242 | 20分钟 | 所有内置命令、快捷键、设置 |
| 5 | [会话管理](./guide/05-sessions.md) | 312 | 25分钟 | 树形会话、分支、压缩、导航 |
| 6 | [Skill 系统](./guide/06-skills.md) | 352 | 30分钟 | 使用 Skill、编写 Skill、最佳实践 |
| 7 | [健康使用指南](./guide/07-healthy-usage.md) | 265 | 15分钟 | 避免 Agent Psychosis、质量优先 |
| 8 | [你的第一个扩展](./guide/08-first-extension.md) | 310 | 40分钟 | 从零编写、热重载、调试 |
| 9 | [扩展 API 详解](./guide/09-extension-api.md) | 585 | 90分钟 | 工具、命令、事件、UI |
| 15 | [设计决策](./guide/15-design-decisions.md) | 313 | 30分钟 | 为什么这样设计、权衡、未来 |

**小计**：10 章，约 3,141 行

---

## 🎨 设计模式 (patterns/)

扩展开发的常见模式与最佳实践。

| 章节 | 页数 | 内容 |
|------|------|------|
| [实战模式](./patterns/10-patterns.md) | 590 | 审计日志、待办管理、代码审查、智能重试、缓存、工作流、组合模式 |

---

## 🍳 代码食谱 (cookbook/)

复制即用的代码片段。

| 章节 | 页数 | 内容 |
|------|------|------|
| [Cookbook](./cookbook/11-cookbook.md) | 488 | 工具模板、命令示例、事件监听、UI 交互、文件操作、网络请求、常见模式 |

---

## 📚 技术参考 (reference/)

深度技术细节，按需查阅。

| 文档 | 页数 | 内容 |
|------|------|------|
| [架构概览](./reference/architecture-overview.md) | 144 | 核心架构边界与调用链 |
| [深度架构分析](./reference/deep-dive-architecture.md) | 1,384 | 源码级深度分析（五层架构、数据流、事件系统） |
| [源码架构](./reference/12-source-architecture.md) | 420 | 五层架构详解、数据流、事件系统 |
| [模型系统](./reference/13-model-system.md) | 362 | Provider、注册、路由、自定义 |
| [嵌入与集成](./reference/14-embedding.md) | 261 | SDK、RPC、Web UI |
| [RPC 指南](./reference/embedding-and-rpc.md) | 135 | 集成开发指南 |
| [SDK 指南](./reference/extensions-and-sdks.md) | 223 | 扩展开发实战手册 |
| [Provider 架构](./reference/model-provider-architecture.md) | 150 | 模型系统技术细节 |
| [与 Bub 框架对比](./reference/comparison-bub.md) | 739 | 通过对比理解 pi-mono 设计 |
| [与 Claude Code 对比](./reference/comparison-claude-code.md) | 623 | 与主流工具对比 |
| [与 OpenCode 对比](./reference/comparison-opencode.md) | 884 | 与最热门的开源工具对比 |
| [Zig 生态综合分析](./reference/zig-ecosystem-analysis.md) | 762 | pi-mono Zig 版本演进路线图 |

**小计**：12 个文档，约 6,087 行

---

## 阅读路径推荐

### 🚀 快速入门（1小时）

```
guide/
├── 01-what-is-pi.md        # 15分钟
├── 02-architecture-story.md # 20分钟
└── 03-first-hour.md        # 25分钟
```

### 🛠️ 扩展开发（4小时）

```
guide/
├── 08-first-extension.md   # 40分钟
├── 09-extension-api.md     # 90分钟
└── 15-design-decisions.md  # 30分钟

patterns/
└── 10-patterns.md          # 60分钟

cookbook/
└── 11-cookbook.md          # 参考查阅
```

### 📚 全面掌握（按需查阅）

- 使用问题 → `guide/`
- 代码片段 → `cookbook/`
- 架构理解 → `reference/`
- 设计模式 → `patterns/`

---

## 内容统计

| 分类 | 文件数 | 行数 | 占比 |
|------|--------|------|------|
| 使用指南 | 10 | 3,141 | 39% |
| 技术参考 | 12 | 6,087 | 52% |
| 设计模式 | 1 | 590 | 5% |
| 代码食谱 | 1 | 488 | 4% |
| **总计** | **24** | **~10,500** | **100%** |

---

## 核心亮点

1. **第9章 扩展 API 详解** (585行) - 最详细的技术参考
2. **第10章 实战模式** (590行) - 7个实用设计模式
3. **深度架构分析** (1,384行) - 源码级深度分析
4. **Zig 生态综合分析** (762行) - pi-mono Zig 版本演进路线图
5. **与 OpenCode 对比** (884行) - 与最热门的开源工具对比
6. **与 Claude Code 对比** (623行) - 与主流工具对比
7. **与 Bub 框架对比** (739行) - 通过对比深入理解设计
6. **第3章 第一个小时** (354行) - 完整的入门指南
7. **第6章 Skill 系统** (352行) - Skill 开发完整指南

---

## 外部资源

### 设计理念
- [Armin Ronacher: Pi - The Minimal Agent Within OpenClaw](https://lucumr.pocoo.org/2026/1/31/pi/)
- [Mario Zechner: What if you don't need MCP at all?](https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/)
- [Armin Ronacher: A Language For Agents](https://lucumr.pocoo.org/2026/2/9/a-language-for-agents/)
- [Armin Ronacher: Agent Psychosis](https://lucumr.pocoo.org/2026/1/18/agent-psychosis/)

### 实战案例
- [Armin Ronacher: Advent of Slop](https://lucumr.pocoo.org/2025/12/23/advent-of-slop/)
- [Armin Ronacher: The Final Bottleneck](https://lucumr.pocoo.org/2026/2/13/the-final-bottleneck/)

---

*本书与 pi 代码库同步更新，最后更新时间：2025年3月*
