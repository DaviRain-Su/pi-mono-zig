# 《pi 中文开发指南》

> 一本关于 pi 的完整技术书籍：从入门到精通，从使用到二次开发。

**版本**：v1.3  
**总页数**：约 29,100+ 行  
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
| 7 | [健康使用指南](./guide/07-healthy-usage.md) | 302 | 15分钟 | 避免 Agent Psychosis、质量优先 |
| 8 | [你的第一个扩展](./guide/08-first-extension.md) | 310 | 40分钟 | 从零编写、热重载、调试 |
| 9 | [扩展 API 详解](./guide/09-extension-api.md) | 585 | 90分钟 | 工具、命令、事件、UI |
| 10 | [提示模板](./guide/10-prompt-templates.md) | 67 | 10分钟 | 模板创建、参数、使用 ✨ |
| 11 | [开发指南](./guide/11-development.md) | 69 | 10分钟 | 设置、Fork、测试、结构 ✨ |
| 12 | [故障排查指南](./guide/12-troubleshooting.md) | 454 | 30分钟 | 常见问题与解决方案 ✨ |
| 15 | [设计决策](./guide/15-design-decisions.md) | 313 | 30分钟 | 为什么这样设计、权衡、未来 |
| 20 | [黑客松获奖策略](./guide/20-hackathon-winning-strategy.md) | - | 参考查阅 | 公链黑客松评判逻辑、选链策略与展示打法 |

**小计**：14 章

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

---

## ⛓️ 区块链专题 (blockchain/)

围绕 `pi-mono` / `pi-worker` 与 Solana、Sui、支付协议、去中心化计算层结合的专题文档。

| 文档 | 内容 |
|------|------|
| [专题总览](./blockchain/00-overview.md) | 这个专题解决什么问题、适合谁读、如何阅读 |
| [专题导航](./blockchain/README.md) | 阅读顺序、主题边界、与核心文档关系 |
| [区块链结合路线图](./blockchain/01-roadmap.md) | 务实版 / Web3-native / 研究版三条路线 |
| [Solana / Sui 任务模型草案](./blockchain/02-task-models-solana-sui.md) | Task / Claim / Result / Escrow / Dispute 等最小对象模型 |
| [区块链 + Agent 的 LLM 支付层设计](./blockchain/03-llm-payment-layer.md) | x402 / MMP / usage receipts / budget / settlement |
| [pi-worker 链上任务执行时序](./blockchain/04-task-execution-flow.md) | 从任务创建到结算的完整执行流 |
| [可验证 Artifact 设计](./blockchain/05-verifiable-artifacts.md) | 结果如何变成可承诺、可校验、可争议的 artifact |
| [Policy 与 Guardrails 设计](./blockchain/06-policy-and-guardrails.md) | 预算、模型、工具、主网动作的边界控制 |
| [TEE 与去中心化计算层](./blockchain/07-tee-and-decentralized-compute.md) | 为什么链本身不适合运行 worker，以及路线 2 的执行平面 |
| [可验证 Receipts 与 Attestation](./blockchain/08-verifiable-receipts-and-attestation.md) | usage receipts、manifest、artifact、attestation 的验证链路 |
| [Solana 专题导航](./blockchain/solana/README.md) | Solana 主线的阅读顺序与目录 |
| [Solana MVP 草案](./blockchain/solana/09-solana-mvp-design.md) | 第一条链的最小账户模型、最小指令集与 worker 接入闭环 |
| [Solana Program 指令设计](./blockchain/solana/10-solana-program-instructions.md) | create/fund/claim/submit/accept/reject/settle 的协议级设计 |
| [Solana 预算与结算设计](./blockchain/solana/11-solana-budget-and-settlement.md) | execution budget、worker reward、refund 与 settlement 闭合方式 |
| [Solana Worker Runtime 集成](./blockchain/solana/12-solana-worker-runtime-integration.md) | task discovery、claim、artifact bundle、submit 与 post-submit 监控 |
| [Solana 争议与声誉设计](./blockchain/solana/13-solana-dispute-and-reputation.md) | dispute 状态机、reviewer 模型与 reputation 指标设计 |
| [Solana 任务市场与 Worker 选择](./blockchain/solana/14-solana-task-market-and-worker-selection.md) | 任务分配、资格认领、specialization 与 stake/reputation 的关系 |
| [Solana 安全与审计清单](./blockchain/solana/15-solana-security-and-audit-checklist.md) | 状态机、authority、结算、artifact、market 与 runtime 的审计重点 |
| [Solana Indexer 与可观测性](./blockchain/solana/16-solana-indexer-and-observability.md) | Task/Worker/Cost/Market 的索引、Dashboard 与告警设计 |
| [Solana 产品推进路线图](./blockchain/solana/17-solana-product-roadmap.md) | 从内部验证、稳定 MVP 到有限市场与开放网络的阶段推进 |
| [Solana 实现清单](./blockchain/solana/18-solana-implementation-checklist.md) | 协议、runtime、运营、支付层的具体实现顺序与阶段清单 |

### Sui 专题 (blockchain/sui/)

| 文档 | 内容 |
|------|------|
| [专题导航](./blockchain/sui/README.md) | Sui 专题目录与快速开始 |
| [Sui 总览](./blockchain/sui/00-overview.md) | Sui 与 Solana 的核心差异、对象模型介绍 |
| [Sui 任务模型](./blockchain/sui/02-task-models.md) | Task / WorkerCap / Result / Escrow / Dispute 对象设计 |
| [Sui MVP 设计](./blockchain/sui/10-sui-mvp-design.md) | 最小可行对象模型与 Worker 接入闭环 |
| [Sui 合约指令](./blockchain/sui/11-sui-contract-instructions.md) | Move 合约完整指令集与状态迁移 |
| [Sui 预算结算](./blockchain/sui/12-sui-budget-and-settlement.md) | 执行预算、Worker 奖励、退款设计 |
| [Sui Worker 集成](./blockchain/sui/13-sui-worker-runtime-integration.md) | pi-worker 与 Sui 链的完整集成 |
| [Sui 争议声誉](./blockchain/sui/14-sui-dispute-and-reputation.md) | 争议状态机、Reviewer、声誉指标 |
| [Sui 任务市场](./blockchain/sui/15-sui-market-and-selection.md) | 任务分配、Worker 选择、定价 |
| [Sui 安全审计](./blockchain/sui/16-sui-security-and-audit.md) | 状态机、权限、结算、Artifact 审计 |
| [Sui 可观测性](./blockchain/sui/17-sui-indexer-and-observability.md) | Indexer、Dashboard、告警 |
| [Sui 实现清单](./blockchain/sui/18-sui-implementation-checklist.md) | 完整实现路线图与检查清单 |

### DASN 研究线 (blockchain/dasn/)

| 文档 | 内容 |
|------|------|
| [专题导航](./blockchain/dasn/README.md) | DASN 研究线的边界、关系与推荐阅读顺序 |
| [DASN 愿景](./blockchain/dasn/19-dasn-vision.md) | 去中心化 Agent 服务网络的角色分层与经济模型 |
| [Agent 协议标准分析](./blockchain/dasn/20-agent-protocols-analysis.md) | ERC-8004、Vouch、Solana Registries 等协议对比 |
| [DASN 协议整合实现](./blockchain/dasn/21-dasn-protocol-integration.md) | DASN 与现有协议栈的整合实现方向 |
| [DASN 原型设计](./blockchain/dasn/22-dasn-prototype-design.md) | 多协议 Worker / 网络原型设计 |
| [DASN 测试策略](./blockchain/dasn/23-dasn-testing-strategy.md) | 原型验证、测试框架与实验设计 |
| [DASN 标准提案](./blockchain/dasn/24-dasn-standard-proposal.md) | 面向标准化推进的提案抽象 |
| [DASN SDK 设计](./blockchain/dasn/25-dasn-sdk-design.md) | SDK 层接口、开发者体验与生态接入 |
| [去中心化 Agent 协作平台设计](./blockchain/dasn/31-decentralized-agent-platform-design.md) | 从协议研究走向协作平台产品化的整体方案 |
| [稳定币支付与 Worker 部署模型](./blockchain/dasn/32-dagent-hub-economic-and-worker-model.md) | USDC 支付模型、平台费结构与 Worker 部署分层 |
| [dAgent Network 产品定义书](./blockchain/dasn/33-dagent-product-definition.md) | 产品一句话定义、核心功能、用户路径与 pi-mono 复用边界 |

---

## 💻 平台配置 (platform/)

不同平台的配置指南。

| 文档 | 内容 |
|------|------|
| [Windows 配置](./platform/windows.md) | Git Bash、Cygwin、WSL 配置 ✨ |
| [Termux](./platform/termux.md) | Android Termux 安装与使用 ✨ |
| [终端配置](./platform/terminal-setup.md) | Kitty、iTerm2、Ghostty、WezTerm 等终端正确配置 ✨ |
| [tmux 配置](./platform/tmux.md) | tmux 扩展键配置 ✨ |

---

## 📚 技术参考 (reference/)

深度技术细节，按需查阅。

| 文档 | 行数 | 内容 |
|------|------|------|
| [架构概览](./reference/architecture-overview.md) | 144 | 核心架构边界与调用链 |
| [深度架构分析](./reference/deep-dive-architecture.md) | 1,384 | 源码级深度分析（五层架构、数据流、事件系统） |
| [源码架构](./reference/12-source-architecture.md) | 420 | 五层架构详解、数据流、事件系统 |
| [扩展开发](./reference/extensions.md) | 2,100+ | 完整扩展 API 参考 |
| [模型系统](./reference/13-model-system.md) | 362 | Provider、注册、路由、自定义 |
| [嵌入与集成](./reference/14-embedding.md) | 261 | SDK、RPC、Web UI |
| [RPC 模式](./reference/rpc.md) | 1,354 | JSON 协议完整参考 ✨ |
| [自定义 Provider](./reference/custom-provider.md) | 596 | 注册新模型 Provider ✨ |
| [设置参考](./reference/settings.md) | 234 | 完整设置配置表 ✨ |
| [树形导航](./reference/tree.md) | 228 | /tree 命令详解 ✨ |
| [会话压缩](./reference/compaction.md) | 392 | 自动压缩与分支摘要算法 ✨ |
| [JSON 模式](./reference/json-mode.md) | 79 | 事件流输出格式 ✨ |
| [TUI 组件](./reference/tui.md) | 887 | 自定义组件开发 ✨ |
| [主题配置](./reference/themes.md) | 295 | 自定义 TUI 颜色 ✨ |
| [键绑定](./reference/keybindings.md) | 173 | 所有快捷键配置 ✨ |
| [Provider 配置](./reference/providers.md) | 195 | 订阅、API Key、云服务商 ✨ |
| [Shell 别名](./reference/shell-aliases.md) | 13 | 启用 bash 别名 ✨ |
| [框架对比](./reference/comparison-bub.md) | 739 | 与 Bub 框架对比 |
| [框架对比](./reference/comparison-claude-code.md) | 623 | 与 Claude Code 对比 |
| [框架对比](./reference/comparison-opencode.md) | 884 | 与 OpenCode 对比 |
| [Zig 生态](./reference/zig-ecosystem-analysis.md) | 762 | Zig 版本演进路线图 |
| [Zig / Runtime / Multi-Agent 研究线](./reference/zig/README.md) | 导航 | Zig 化、多 Agent、SDK / Runtime 研究入口 |
| [pi-mono + Zig 愿景](./reference/zig/26-pi-mono-zig-vision.md) | - | Zig 愿景与系统基础设施思考 |
| [Zig 技术深潜](./reference/zig/27-zig-pi-technical-deep-dive.md) | - | 内存、零拷贝、安全隔离等技术问题 |
| [多 Agent 架构](./reference/zig/28-pi-mono-multi-agent-architecture.md) | - | 从单 Agent 到多 Agent 的演进 |
| [SDK / Runtime / OS 分层](./reference/zig/29-zig-sdk-system-layer-analysis.md) | - | 系统层级定位与职责边界 |
| [Slock.ai 分析](./reference/zig/30-slock-ai-analysis.md) | - | 外部 Agent 协作平台对比与启发 |
| [Compute / Worker 基础设施研究线](./reference/compute/README.md) | 导航 | Worker 执行平面、部署模型与平台选型入口 |
| [Cloudflare Worker vs 去中心化 Worker](./reference/compute/34-cloudflare-worker-vs-decentralized.md) | - | 中心化 serverless 与去中心化 Worker 的架构对比 |
| [去中心化 Worker 部署指南](./reference/compute/35-decentralized-worker-deployment-guide.md) | - | 从个人电脑到企业级集群的部署路径 |
| [去中心化计算平台分析](./reference/compute/36-decentralized-compute-platforms-analysis.md) | - | EigenCompute、ICP 等平台分析 |
| [去中心化计算平台全景扫描](./reference/compute/37-comprehensive-decentralized-compute-landscape.md) | - | 多生态去中心化计算方案全景 |

**小计**：21 个文档

---

## 阅读路径推荐

### 🚀 快速入门（1小时）

```
guide/
├── 01-what-is-pi.md        # 15分钟
├── 02-architecture-story.md # 20分钟
├── 03-first-hour.md        # 25分钟
└── 12-troubleshooting.md   # 参考查阅
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
- 区块链专题 → `blockchain/`
  - Solana 方案 → `blockchain/solana/*.md`
  - Sui 方案 → `blockchain/sui/*.md`

---

## 内容统计

| 分类 | 文件数 | 行数 | 占比 |
|------|--------|------|------|
| 使用指南 | 14 | ~4,900 | 12% |
| 技术参考 | 35 | ~17,300 | 40% |
| 区块链专题 | 45 | ~25,600 | 65% |
| 设计模式 | 1 | 590 | 2% |
| 代码食谱 | 1 | 484 | 1% |
| 平台配置 | 4 | ~307 | 1% |
| **总计** | **101** | **~43,500+** | **100%** |

✨ = 新增翻译

---

## 核心亮点

1. **扩展开发完整指南** (2,100+行) - 最全面的扩展开发参考
2. **Sui 专题文档** (4,900+行，11篇) - Sui 区块链集成完整方案
3. **区块链专题** (18,400+行，35篇) - Solana + Sui 双链完整方案
4. **第9章 扩展 API 详解** (585行) - 详细的技术参考
5. **第10章 实战模式** (590行) - 7个实用设计模式
6. **深度架构分析** (1,384行) - 源码级深度分析
7. **Zig 生态综合分析** (762行) - pi-mono Zig 版本演进路线图
8. **与 OpenCode 对比** (884行) - 与最热门的开源工具对比
9. **与 Claude Code 对比** (623行) - 与主流工具对比
10. **与 Bub 框架对比** (739行) - 通过对比深入理解设计
11. **第3章 第一个小时** (354行) - 完整的入门指南
12. **第6章 Skill 系统** (352行) - Skill 开发完整指南
13. **故障排查指南** (454行) - 全面问题解决方案

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

*本书与 pi 代码库同步更新，最后更新时间：2026年3月23日 (v1.3 Sui 专题完整版)*
