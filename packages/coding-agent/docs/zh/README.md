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
│   ├── 10-prompt-templates.md     # 提示模板 ✨ 新增
│   ├── 11-development.md          # 开发指南 ✨ 新增
│   ├── 12-troubleshooting.md      # 故障排查指南 ✨ 新增
│   └── 15-design-decisions.md     # 设计决策
├── patterns/              # 🎨 设计模式
│   └── 10-patterns.md             # 实战模式
├── cookbook/              # 🍳 代码食谱
│   └── 11-cookbook.md             # Cookbook
├── blockchain/            # ⛓️ 区块链专题 ✨ 新目录
│   ├── README.md                   # 专题导航
│   ├── 00-overview.md              # 专题总览
│   ├── 01-roadmap.md               # 区块链结合路线图
│   ├── 02-task-models-solana-sui.md # Solana / Sui 任务模型草案
│   ├── 03-llm-payment-layer.md     # 区块链 + Agent 的 LLM 支付层设计
│   ├── 04-task-execution-flow.md   # pi-worker 链上任务执行时序
│   ├── 05-verifiable-artifacts.md  # 可验证 Artifact 设计
│   ├── 06-policy-and-guardrails.md # Policy 与 Guardrails 设计
│   ├── 07-tee-and-decentralized-compute.md # TEE 与去中心化计算层
│   ├── 08-verifiable-receipts-and-attestation.md # 可验证 Receipts 与 Attestation
│   ├── solana/                       # ☀️ Solana 专题 ✨ 新目录
│   │   ├── README.md                 # Solana 专题导航
│   │   ├── 09-solana-mvp-design.md   # Solana MVP 草案
│   │   ├── 10-solana-program-instructions.md # Solana Program 指令设计
│   │   ├── 11-solana-budget-and-settlement.md # Solana 预算与结算设计
│   │   ├── 12-solana-worker-runtime-integration.md # Solana Worker Runtime 集成
│   │   ├── 13-solana-dispute-and-reputation.md # Solana 争议与声誉设计
│   │   ├── 14-solana-task-market-and-worker-selection.md # Solana 任务市场与 Worker 选择
│   │   ├── 15-solana-security-and-audit-checklist.md # Solana 安全与审计清单
│   │   ├── 16-solana-indexer-and-observability.md # Solana Indexer 与可观测性
│   │   ├── 17-solana-product-roadmap.md # Solana 产品推进路线图
│   │   └── 18-solana-implementation-checklist.md # Solana 实现清单
│   └── sui/                          # 🌊 Sui 专题 ✨ 完整
│       ├── README.md                 # Sui 专题导航
│       ├── 00-overview.md            # Sui 总览
│       ├── 02-task-models.md         # Sui 任务模型
│       ├── 10-sui-mvp-design.md      # Sui MVP 设计
│       ├── 11-sui-contract-instructions.md # 合约指令
│       ├── 12-sui-budget-and-settlement.md # 预算结算
│       ├── 13-sui-worker-runtime-integration.md # Worker 集成
│       ├── 14-sui-dispute-and-reputation.md # 争议声誉
│       ├── 15-sui-market-and-selection.md # 任务市场
│       ├── 16-sui-security-and-audit.md # 安全审计
│       ├── 17-sui-indexer-and-observability.md # 可观测性
│       └── 18-sui-implementation-checklist.md # 实现清单
├── platform/              # 💻 平台配置 ✨ 新目录
│   ├── windows.md                 # Windows 配置
│   ├── termux.md                  # Android Termux
│   ├── terminal-setup.md          # 终端配置
│   └── tmux.md                    # tmux 配置
└── reference/             # 📚 技术参考
    ├── architecture-overview.md          # 架构概览
    ├── deep-dive-architecture.md         # 深度架构分析
    ├── 12-source-architecture.md         # 源码架构
    ├── 13-model-system.md                # 模型系统
    ├── 14-embedding.md                   # 嵌入与集成
    ├── extensions.md                     # 扩展开发完整指南 ✨
    ├── rpc.md                            # RPC 模式 ✨
    ├── custom-provider.md                # 自定义 Provider ✨
    ├── models.md                         # 自定义模型配置 ✨
    ├── packages.md                       # Pi 包管理 ✨
    ├── settings.md                        # 设置参考 ✨
    ├── tree.md                            # 树形导航 ✨
    ├── compaction.md                     # 会话压缩 ✨
    ├── json-mode.md                      # JSON 模式 ✨
    ├── tui.md                            # TUI 组件 ✨
    ├── themes.md                         # 主题配置 ✨
    ├── keybindings.md                    # 键绑定 ✨
    ├── providers.md                      # Provider 配置 ✨
    ├── shell-aliases.md                  # Shell 别名 ✨
    ├── extensions-and-sdks.md            # SDK 指南
    ├── model-provider-architecture.md    # Provider 架构
    ├── comparison-bub.md                 # 与 Bub 框架对比
    ├── comparison-claude-code.md         # 与 Claude Code 对比
    ├── comparison-opencode.md            # 与 OpenCode 对比
    ├── zig-ecosystem-analysis.md         # Zig 生态综合分析与演进规划
    └── zig/                              # 🧠 Zig / Runtime / Multi-Agent 研究线 ✨ 新目录
        ├── README.md                     # 研究线导航
        ├── 26-pi-mono-zig-vision.md      # pi-mono + Zig 愿景
        ├── 27-zig-pi-technical-deep-dive.md # Zig 技术深潜
        ├── 28-pi-mono-multi-agent-architecture.md # 多 Agent 架构
        ├── 29-zig-sdk-system-layer-analysis.md # SDK / Runtime / OS 分层
        └── 30-slock-ai-analysis.md       # Slock.ai 分析
```

---

## 阅读路径

### 🚀 快速入门（1小时）

按顺序阅读 guide/ 前3章：
1. [pi 是什么](./guide/01-what-is-pi.md) - 15分钟
2. [架构故事](./guide/02-architecture-story.md) - 20分钟
3. [第一个小时](./guide/03-first-hour.md) - 25分钟

遇到问题？查阅 [故障排查指南](./guide/12-troubleshooting.md)

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
- **平台配置**：platform/
- **框架对比**：
  - [与 Bub 框架对比](./reference/comparison-bub.md)
  - [与 Claude Code 对比](./reference/comparison-claude-code.md)
  - [与 OpenCode 对比](./reference/comparison-opencode.md)
- **区块链专题**：
  - [专题总览](./blockchain/00-overview.md)
  - [专题导航](./blockchain/README.md)
  - 基础层：路线图、任务模型、支付层、执行流、artifact、guardrails、TEE、receipts
  - Solana 主线：[专题导航](./blockchain/solana/README.md)，以及 MVP、Program 指令、预算结算、runtime 集成、dispute、market、audit、observability、product roadmap、implementation checklist
  - Sui 专题：[总览](./blockchain/sui/00-overview.md)、[任务模型](./blockchain/sui/02-task-models.md)、[MVP 设计](./blockchain/sui/10-sui-mvp-design.md)
  - DASN 研究线：[专题导航](./blockchain/dasn/README.md)、[愿景](./blockchain/dasn/19-dasn-vision.md)、[协议分析](./blockchain/dasn/20-agent-protocols-analysis.md)、[去中心化 Agent 协作平台设计](./blockchain/dasn/31-decentralized-agent-platform-design.md)
- **演进规划**：
  - [Zig 生态综合分析](./reference/zig-ecosystem-analysis.md) - pi-mono Zig 版本演进路线图
  - [Zig / Runtime / Multi-Agent 研究线导航](./reference/zig/README.md)
  - [pi-mono + Zig 愿景](./reference/zig/26-pi-mono-zig-vision.md)
  - [Zig 技术深潜](./reference/zig/27-zig-pi-technical-deep-dive.md)
  - [多 Agent 架构](./reference/zig/28-pi-mono-multi-agent-architecture.md)
  - [SDK / Runtime / OS 分层](./reference/zig/29-zig-sdk-system-layer-analysis.md)
  - [Slock.ai 分析](./reference/zig/30-slock-ai-analysis.md)

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

*本书与 pi 代码库同步更新，最后更新时间：2026年3月23日 (v1.9 USDC+Worker 部署模型)*