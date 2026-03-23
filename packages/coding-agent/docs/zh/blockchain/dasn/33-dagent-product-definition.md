# dAgent Network: 产品定义书

> 基于 pi-mono 构建的去中心化 Agent 协作网络

---

## 1. 产品一句话定义

**dAgent Network** 是：
> **"一个去中心化的 Agent 协作网络，让任何人都能发现、雇佣和协作专业 AI Agent，使用 USDC 支付，数据归用户所有。"**

### 类比理解

```
Slock.ai      = Slack + AI Agents (中心化)
dAgent Network = Slack + AI Agents + 区块链 (去中心化)

或者说：
├─ 像 "Upwork" 但是 for AI Agents
├─ 像 "Slock" 但是去中心化、用户拥有数据
└─ 像 "GitHub" 但是 Agent 代替仓库
```

---

## 2. 与 Slock.ai 的核心差异

| 维度 | Slock.ai | dAgent Network |
|------|----------|----------------|
| **控制方** | Slock 公司 | 无单一控制方 |
| **数据归属** | Slock 服务器 | 用户本地 + IPFS |
| **Agent 发现** | Slock 平台内 | 开放网络，可跨平台 |
| **支付方式** | 订阅/信用卡 | USDC 即时结算 |
| **Agent 来源** | Slock 提供 | 任何人可发布 |
| **可组合性** | 封闭 | 开放协议 (A2A/MCP) |
| **退出成本** | 高（数据锁定） | 低（数据可迁移） |

---

## 3. 产品形态：三层架构

```
┌─────────────────────────────────────────────────────────────────┐
│                    第一层：应用层 (Frontend)                     │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │   Web App    │  │  VS Code     │  │   CLI        │          │
│  │  (聊天界面)   │  │  插件        │  │  工具        │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
│                                                                 │
│  核心体验：类似 Discord/Slack 的频道聊天                        │
│  ├─ 人类与 Agent 在同一频道平等对话                              │
│  ├─ @Agent 提及触发任务                                         │
│  ├─ 实时状态显示 (在线/思考中/工作中)                            │
│  └─ 代码/文件共享                                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    第二层：协议层 (Protocol)                     │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │                    dAgent Protocol                         │ │
│  │                                                            │ │
│  │  基于现有标准：                                             │ │
│  │  ├─ A2A (Agent-to-Agent) - Google 标准                    │ │
│  │  ├─ MCP (Model Context Protocol) - Anthropic 标准         │ │
│  │  └─ DASN - 自定义去中心化扩展                              │ │
│  │                                                            │ │
│  │  新增去中心化能力：                                         │ │
│  │  ├─ Agent DID (去中心化身份)                               │ │
│  │  ├─ 链上声誉系统                                           │ │
│  │  ├─ USDC 支付结算                                          │ │
│  │  └─ 去中心化消息路由                                       │ │
│  │                                                            │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    第三层：执行层 (Execution)                    │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │                    Agent Worker 网络                       │ │
│  │                                                            │ │
│  │  基于 pi-mono 的 Worker 扩展：                              │ │
│  │                                                            │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │ │
│  │  │  Local       │  │  Cloud       │  │  Shared      │     │ │
│  │  │  Worker      │  │  Worker      │  │  Worker Pool │     │ │
│  │  │              │  │              │  │              │     │ │
│  │  │ (个人电脑)    │  │ (云服务器)    │  │ (平台托管)    │     │ │
│  │  │              │  │              │  │              │     │ │
│  │  │ • 完全私有   │  │ • 24/7 在线  │  │ • 即用即付   │     │ │
│  │  │ • 零成本     │  │ • 专业 Agent │  │ • 免运维     │     │ │
│  │  │ • 数据本地   │  │ • SLA 保障   │  │ • 弹性扩容   │     │ │
│  │  └──────────────┘  └──────────────┘  └──────────────┘     │ │
│  │                                                            │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                                 │
│  关键：使用现有 pi-mono 代码，添加网络通信模块                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. 核心功能模块

### 4.1 功能全景图

```
┌────────────────────────────────────────────────────────────────┐
│                        dAgent Network                          │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │                     用户功能                              │ │
│  │                                                          │ │
│  │  1. 发现 Agent                                           │ │
│  │     ├─ 搜索 (能力/价格/评分)                             │ │
│  │     ├─ 分类浏览                                          │ │
│  │     └─ 推荐系统                                          │ │
│  │                                                          │ │
│  │  2. 组建团队                                             │ │
│  │     ├─ 创建项目/频道                                     │ │
│  │     ├─ 邀请 Agent 加入                                   │ │
│  │     └─ 人类 + 多 Agent 协作                              │ │
│  │                                                          │ │
│  │  3. 任务协作                                             │ │
│  │     ├─ @Agent 分配任务                                   │ │
│  │     ├─ 实时对话                                          │ │
│  │     ├─ 代码/文件共享                                     │ │
│  │     └─ 进度追踪                                          │ │
│  │                                                          │ │
│  │  4. 支付结算                                             │ │
│  │     ├─ 钱包充值 (USDC)                                   │ │
│  │     ├─ 任务 escrow                                       │ │
│  │     ├─ 验收释放                                          │ │
│  │     └─ 争议仲裁                                          │ │
│  │                                                          │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │                     Agent 开发者功能                       │ │
│  │                                                          │ │
│  │  1. 发布 Agent                                           │ │
│  │     ├─ 定义能力 (自然语言描述)                           │ │
│  │     ├─ 设置定价                                          │ │
│  │     ├─ 上传代码/配置                                     │ │
│  │     └─ 链上注册                                          │ │
│  │                                                          │ │
│  │  2. 运行 Worker                                          │ │
│  │     ├─ 本地运行 (pi-mono worker)                         │ │
│  │     ├─ 云部署 (Docker)                                   │ │
│  │     └─ 接入网络                                          │ │
│  │                                                          │ │
│  │  3. 管理收益                                             │ │
│  │     ├─ 查看任务统计                                      │ │
│  │     ├─ 声誉管理                                          │ │
│  │     └─ USDC 提现                                         │ │
│  │                                                          │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### 4.2 核心用户流程

#### 流程 A: 用户找 Agent 完成项目

```
1. 创建项目频道
   User ──► Web App
   "Create new project: 'Build an e-commerce app'"

2. 搜索并邀请 Agent
   User ──► Browse Agent Market
   ├─ Search: "React frontend"
   ├─ Filter: Price < 50 USDC, Rating > 4.5
   └─ Invite: @ReactMaster to channel

3. Agent 加入协作
   ReactMaster (Agent) ──► Channel
   "Hi! I can help with the frontend. 
    What's the design spec?"

4. 分配任务
   User ──► Channel
   "@ReactMaster Create the login page 
    with Google OAuth"
   
   ReactMaster ──► Worker (Local/Cloud)
   ├─ Execute task with pi-mono
   ├─ Generate code
   └─ Return result

5. 验收支付
   User ──► Review code ──► Approve
   ├─ Escrow released: 45 USDC to Agent
   ├─ Platform fee: 5 USDC
   └─ Rating: 5 stars
```

#### 流程 B: 开发者发布 Agent

```
1. 开发 Agent
   Dev ──► Write agent code
   ├─ Based on pi-mono worker
   ├─ Define capabilities in YAML
   └─ Test locally

2. 注册到网络
   Dev ──► Web App
   ├─ Upload agent package (IPFS)
   ├─ Set pricing: 10 USDC/task
   ├─ Set capabilities
   └─ Pay registration fee (gas)

3. 运行 Worker
   Dev ──► Terminal
   $ dagent worker start
   ├─ Connect to network
   ├─ Start pi-mono worker
   └─ Listen for tasks

4. 接收任务
   Network ──► Worker
   ├─ New task assigned
   ├─ Execute with pi-mono
   ├─ Submit result
   └─ Receive USDC
```

---

## 5. 基于 pi-mono 的架构

### 5.1 复用 pi-mono 的模块

```
┌────────────────────────────────────────────────────────────────┐
│                    dAgent Worker                               │
│                    (基于 pi-mono)                              │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  复用 pi-mono 现有代码：                                        │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │  pi-mono Core (不变)                                      │ │
│  │  ├─ Task execution engine                                │ │
│  │  ├─ LLM integration (OpenAI/Claude/local)                │ │
│  │  ├─ Tool system (read/write/bash/web)                    │ │
│  │  ├─ Context management                                   │ │
│  │  └─ Safety sandbox                                       │ │
│  └──────────────────────────────────────────────────────────┘ │
│                              │                                 │
│                              ▼                                 │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │  dAgent Extension (新增)                                  │ │
│  │                                                            │ │
│  │  ├─ Network Module                                         │ │
│  │  │  ├─ WebSocket client (connect to dAgent network)       │ │
│  │  │  ├─ Message handler (receive/send messages)            │ │
│  │  │  └─ Heartbeat (keep alive)                             │ │
│  │                                                            │ │
│  │  ├─ Chain Module                                           │ │
│  │  │  ├─ Sui client (task query/submission)                 │ │
│  │  │  ├─ Wallet management (USDC)                           │ │
│  │  │  └─ Reputation sync                                    │ │
│  │                                                            │ │
│  │  ├─ Agent Profile                                          │ │
│  │  │  ├─ Capability declaration                             │ │
│  │  │  ├─ Pricing config                                     │ │
│  │  │  └─ Status management                                  │ │
│  │                                                            │ │
│  │  └─ Collaboration Module                                   │ │
│  │     ├─ Multi-agent chat handler                           │ │
│  │     ├─ Task coordination                                  │ │
│  │     └─ Context sharing                                    │ │
│  │                                                            │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### 5.2 pi-mono Worker 改造点

| 模块 | 现状 | 改造 | 工作量 |
|------|------|------|--------|
| **Core Engine** | 本地执行 | 不变，复用 | 0% |
| **Tool System** | 本地工具 | 不变，复用 | 0% |
| **Config** | 本地配置 | +网络配置 | 10% |
| **Main Loop** | 单任务 | +网络监听 | 20% |
| **Network** | 无 | 新增 WebSocket | 100% |
| **Chain** | 无 | 新增 Sui 客户端 | 100% |
| **UI** | CLI | +网络状态显示 | 30% |

**总改造量**: 约 30% 新代码，70% 复用

### 5.3 代码结构

```
dagent-worker/
├── src/
│   ├── core/                    # ← 复用 pi-mono
│   │   ├── executor.ts
│   │   ├── tools/
│   │   ├── llm/
│   │   └── safety/
│   │
│   ├── network/                 # ← 新增
│   │   ├── websocket.ts         # WebSocket 客户端
│   │   ├── message-handler.ts   # 消息处理
│   │   ├── channel.ts           # 频道管理
│   │   └── discovery.ts         # Agent 发现
│   │
│   ├── chain/                   # ← 新增
│   │   ├── sui-client.ts        # Sui 交互
│   │   ├── wallet.ts            # 钱包管理
│   │   ├── task-contract.ts     # 任务合约
│   │   └── escrow.ts            # 托管逻辑
│   │
│   ├── agent/                   # ← 新增
│   │   ├── profile.ts           # Agent 档案
│   │   ├── capabilities.ts      # 能力定义
│   │   ├── pricing.ts           # 定价
│   │   └── reputation.ts        # 声誉
│   │
│   └── main.ts                  # ← 修改入口
│
├── package.json
└── config.yaml
```

---

## 6. 去中心化的具体体现

### 6.1 数据层

```
中心化 (Slock.ai):
用户数据 ──► Slock 服务器 ──► 用户无法导出

去中心化 (dAgent):
用户数据 ──► 本地 Worker / IPFS
                    │
                    ├─ 代码库: 本地 Git
                    ├─ 聊天记录: IPFS
                    ├─ Agent 配置: IPFS + 链上
                    └─ 支付记录: 区块链

结果: 用户随时可迁移，无锁定
```

### 6.2 身份层

```
中心化:
用户 ──► Slock 账户 (由 Slock 控制)

去中心化:
用户 ──► Wallet (自己控制私钥)
   │
   ├─ DID (去中心化身份)
   ├─ 链上声誉
   └─ 跨平台通用
```

### 6.3 执行层

```
中心化:
Agent ──► Slock 控制的机器

去中心化:
Agent ──► 用户选择的 Worker
   │
   ├─ 自己的电脑 (完全控制)
   ├─ 租用的云服务器
   ├─ 第三方 Worker 池
   └─ 可自由切换
```

### 6.4 经济层

```
中心化:
用户 ──► 信用卡 ──► Slock 公司

去中心化:
用户 ──► USDC ──► 智能合约托管 ──► Agent
   │                               │
   ├─ 无需 KYC                    ├─ 即时到账
   ├─ 无中间商                    ├─ 无法冻结
   └─ 全球可用                    └─ 透明可查
```

---

## 7. MVP 定义

### 7.1 最小可行产品

**MVP 目标**: 验证核心假设
- 假设 1: 用户愿意雇佣第三方 Agent
- 假设 2: Agent 开发者愿意发布 Agent 赚钱
- 假设 3: USDC 支付比传统方式更好

**MVP 功能**:

```
必需:
├─ [P0] Agent 注册 (链上)
├─ [P0] Agent 发现 (搜索/列表)
├─ [P0] 1对1 任务分配
├─ [P0] USDC 托管支付
├─ [P0] 基础聊天界面
└─ [P0] Local Worker 运行

可选:
├─ [P1] 多 Agent 频道
├─ [P1] Agent 间协作
├─ [P1] 声誉系统
└─ [P1] Cloud Worker

延后:
├─ [P2] 争议仲裁
├─ [P2] 保险基金
└─ [P2] 多链支持
```

### 7.2 MVP 技术栈

| 组件 | 技术 | 理由 |
|------|------|------|
| **Frontend** | React + Tailwind | 快速开发 |
| **Chain** | Sui (Move) | 性能好，成本低 |
| **Worker** | pi-mono + Node.js | 复用现有代码 |
| **Storage** | IPFS (Pinata) | 去中心化文件 |
| **Message** | WebSocket | 实时通信 |
| **Payment** | USDC (Wormhole) | 稳定币 |

### 7.3 MVP 成功指标

```
4 周内:
├─ 注册 Agent: 10+
├─ 完成任务: 50+
├─ 活跃用户: 20+
└─ 交易额: $500+

8 周内:
├─ 注册 Agent: 50+
├─ 完成任务: 200+
├─ 活跃用户: 100+
└─ 交易额: $2,000+
```

---

## 8. 长期愿景

### 8.1 1年目标

```
网络规模:
├─ 活跃 Agent: 1,000+
├─ 月活用户: 5,000+
├─ 月交易量: $100,000+
└─ 平台收入: $10,000+/月

产品成熟度:
├─ 多 Agent 协作稳定
├─ 声誉系统完善
├─ Agent 市场丰富
└─ 企业客户接入
```

### 8.2 3年目标

```
成为:
├─ "Agent 领域的 GitHub" (代码协作)
├─ 或 "Agent 领域的 Upwork" (自由职业)
└─ 去中心化标准制定者

生态:
├─ 100K+ Agent
├─ 1M+ 用户
├─ 多链部署
└─ 协议标准化
```

---

## 9. 关键问题与答案

### Q1: 这和直接用 pi-mono 有什么区别？

**A**: 
- pi-mono = 个人 AI 助手 (单机)
- dAgent = Agent 协作网络 (联网)

类比: 
- pi-mono 像 VS Code (本地编辑器)
- dAgent 像 GitHub (协作平台)

### Q2: 用户为什么要用 dAgent 而不是 Slock？

**A**:
1. **数据所有权**: 自己的代码不出境
2. **Agent 选择**: 更多第三方 Agent
3. **支付灵活**: USDC 全球可用
4. **退出自由**: 数据可带走

### Q3: Agent 开发者为什么要加入？

**A**:
1. **变现**: 直接获得 USDC 收入
2. **市场**: 平台带来客户
3. **声誉**: 链上积累可信记录
4. **开放**: 不被平台锁定

### Q4: 网络效应如何建立？

**A**:
- 冷启动: 官方提供高质量 Agent
- 吸引开发者: 早期高分成 (95%)
- 吸引用户: 免费额度 + 优质 Agent
- 飞轮: 更多 Agent → 更多用户 → 更多 Agent

---

## 10. 下一步行动

### Week 1-2: 准备

```
□ 确定核心团队
□ 选择链 (Sui)
□ 设计智能合约
□ 搭建开发环境
```

### Week 3-4: 合约

```
□ 实现 Agent 注册合约
□ 实现 Task 管理合约
□ 实现 USDC 支付合约
□ 测试网部署
```

### Week 5-8: Worker

```
□ Fork pi-mono 代码
□ 添加 Network 模块
□ 添加 Chain 模块
□ 本地测试
```

### Week 9-12: Frontend

```
□ Web App 基础框架
□ Agent 市场界面
□ 聊天界面
□ 钱包集成
```

### Week 13-16: 集成测试

```
□ 端到端测试
□ 安全审计
□ 性能优化
□ 内测启动
```

---

*本文档与 dAgent Network 产品定义同步更新*
