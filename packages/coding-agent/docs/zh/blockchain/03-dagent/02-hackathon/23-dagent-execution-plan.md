# X Layer Hackathon 项目执行计划

> dAgent on X Layer - 从规划到落地的完整路线图

---

## 1. 核心确认：基于 pi-mono 实现

### 1.1 pi-mono 的角色

```
┌─────────────────────────────────────────────────────────────────┐
│                     dAgent on X Layer                           │
│                     (比赛项目架构)                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    pi-mono Core (复用)                    │  │
│  │                                                           │  │
│  │  ├─ Task Execution Engine                                │  │
│  │  ├─ LLM Integration (OpenAI/Claude)                      │  │
│  │  ├─ Tool System (File/Execute/Web)                       │  │
│  │  ├─ Context Management                                   │  │
│  │  └─ Safety Sandbox                                       │  │
│  │                                                           │  │
│  │  ✅ 复用 80% - 无需改动                                   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                              │                                   │
│                              ▼                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                dAgent Extension (新增)                    │  │
│  │                                                           │  │
│  │  ├─ X Layer Chain Module (Solidity 合约交互)              │  │
│  │  ├─ OKX OnchainOS SDK 集成                                │  │
│  │  ├─ Trading Strategy Engine (交易逻辑)                    │  │
│  │  ├─ Multi-Agent Coordination (Agent 协作)                 │  │
│  │  └─ X Layer Specific Tools (X Layer 专用工具)             │  │
│  │                                                           │  │
│  │  🆕 新增 20% - 比赛重点                                   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                              │                                   │
│                              ▼                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                   X Layer Smart Contract                  │  │
│  │                                                           │  │
│  │  ├─ AgentRegistry.sol (ERC721)                            │  │
│  │  ├─ TaskManager.sol (USDC 支付)                           │  │
│  │  ├─ TradingVault.sol (资产管理)                           │  │
│  │  └─ ReputationSystem.sol (声誉系统)                       │  │
│  │                                                           │  │
│  │  ⛓️ 部署在 X Layer 主网                                   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 代码复用策略

```
复用部分 (80%):
├── pi-coding-agent/
│   ├── src/
│   │   ├── executor.ts       ✅ 任务执行引擎
│   │   ├── tools/
│   │   │   ├── file.ts       ✅ 文件操作
│   │   │   ├── bash.ts       ✅ 命令执行
│   │   │   └── web.ts        ✅ 网络请求
│   │   ├── llm/
│   │   │   ├── openai.ts     ✅ OpenAI 集成
│   │   │   └── anthropic.ts  ✅ Claude 集成
│   │   └── safety/
│   │       └── sandbox.ts    ✅ 安全沙箱
│   └── package.json

新增部分 (20%):
├── dagent-xlayer/
│   ├── src/
│   │   ├── chain/
│   │   │   ├── xlayer.ts     🆕 X Layer 连接
│   │   │   ├── contracts.ts  🆕 合约交互
│   │   │   └── wallet.ts     🆕 钱包管理
│   │   ├── okx/
│   │   │   ├── dex.ts        🆕 DEX API
│   │   │   ├── wallet.ts     🆕 Wallet SDK
│   │   │   └── market.ts     🆕 市场数据
│   │   ├── strategies/
│   │   │   ├── dca.ts        🆕 定投策略
│   │   │   ├── grid.ts       🆕 网格策略
│   │   │   └── arbitrage.ts  🆕 套利策略
│   │   └── coordination/
│   │       ├── agent-pool.ts 🆕 Agent 管理
│   │       └── task-router.ts 🆕 任务路由
│   └── contracts/
│       ├── AgentRegistry.sol
│       ├── TaskManager.sol
│       └── TradingVault.sol
```

---

## 2. 比赛前必须完成的规划

### 2.1 技术架构详细设计

#### 已完成 ✅
- [x] 整体架构规划
- [x] X Layer 特性分析
- [x] 服务定位明确

#### 待完成 📝

**智能合约详细设计**
```
□ AgentRegistry.sol
  □ ERC721 标准实现
  □ Agent 元数据结构
  □ 注册/更新/查询函数
  □ 事件定义
  □ 测试用例

□ TaskManager.sol
  □ 任务生命周期管理
  □ USDC 支付逻辑
  □ 费用分配机制
  □ 争议处理
  □ 测试用例

□ TradingVault.sol
  □ 资产管理逻辑
  □ 授权机制
  □ 风险控制
  □ 紧急暂停
  □ 测试用例
```

**API 接口设计**
```typescript
// 需要设计的接口

// Agent 管理
POST   /api/agents              // 注册 Agent
GET    /api/agents/:id          // 获取 Agent 信息
PUT    /api/agents/:id          // 更新 Agent
GET    /api/agents              // 列表查询

// 任务管理
POST   /api/tasks               // 创建任务
GET    /api/tasks/:id           // 获取任务状态
POST   /api/tasks/:id/result    // 提交结果
POST   /api/tasks/:id/complete  // 完成任务

// 交易相关 (OKX 集成)
GET    /api/market/price        // 获取价格
POST   /api/trade/execute       // 执行交易
GET    /api/portfolio/:address  // 获取投资组合

// WebSocket 实时推送
WS     /ws/tasks                // 任务状态推送
WS     /ws/market               // 市场价格推送
```

**数据库设计**
```sql
-- 需要设计的数据库表

-- Agent 表
CREATE TABLE agents (
    id SERIAL PRIMARY KEY,
    chain_id VARCHAR(66) UNIQUE, -- 链上 ID
    owner_address VARCHAR(42),
    name VARCHAR(255),
    description TEXT,
    capabilities JSONB,
    pricing_model VARCHAR(50),
    base_price DECIMAL(18, 8),
    reputation_score INTEGER DEFAULT 500,
    total_tasks INTEGER DEFAULT 0,
    status VARCHAR(20) DEFAULT 'active',
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- 任务表
CREATE TABLE tasks (
    id SERIAL PRIMARY KEY,
    chain_id VARCHAR(66) UNIQUE,
    creator_address VARCHAR(42),
    agent_id INTEGER REFERENCES agents(id),
    task_type VARCHAR(50),
    prompt TEXT,
    budget_usdc DECIMAL(18, 8),
    status VARCHAR(20) DEFAULT 'pending',
    result_cid VARCHAR(100),
    created_at TIMESTAMP DEFAULT NOW(),
    completed_at TIMESTAMP
);

-- 交易记录表
CREATE TABLE trades (
    id SERIAL PRIMARY KEY,
    task_id INTEGER REFERENCES tasks(id),
    tx_hash VARCHAR(66),
    from_token VARCHAR(42),
    to_token VARCHAR(42),
    amount_in DECIMAL(18, 8),
    amount_out DECIMAL(18, 8),
    executed_at TIMESTAMP DEFAULT NOW()
);
```

---

### 2.2 团队分工规划

#### 最小可行团队 (3人)

```
角色 1: 智能合约工程师
├─ 职责:
│  ├─ 编写 Solidity 合约
│  ├─ 部署到 X Layer
│  ├─ 编写测试用例
│  └─ 安全审计配合
├─ 技能要求:
│  ├─ Solidity 精通
│  ├─ Hardhat/Foundry
│  ├─ OpenZeppelin 库
│  └─ X Layer/EVM 熟悉
└─ 工作量: 40% 时间

角色 2: 全栈开发者 (前端 + 后端)
├─ 职责:
│  ├─ Web App 开发 (React)
│  ├─ API 服务开发 (Node.js)
│  ├─ OKX Wallet 集成
│  ├─ 链上数据索引
│  └─ 部署运维
├─ 技能要求:
│  ├─ React/TypeScript
│  ├─ Node.js/Express
│  ├─ Web3/ethers.js
│  ├─ PostgreSQL
│  └─ Vercel/AWS
└─ 工作量: 40% 时间

角色 3: AI/策略工程师
├─ 职责:
│  ├─ 基于 pi-mono 开发 Worker
│  ├─ 实现交易策略 (DCA/Grid)
│  ├─ 集成 OKX DEX API
│  ├─ 设计 Agent 能力模型
│  └─ 演示 Demo 准备
├─ 技能要求:
│  ├─ Node.js/TypeScript
│  ├─ 量化交易基础
│  ├─ LLM API (OpenAI)
│  ├─ Docker
│  └─ 演讲能力
└─ 工作量: 20% 时间
```

#### 理想团队 (4-5人)

```
+ 角色 4: 产品经理/设计师
  ├─ UI/UX 设计
  ├─ 产品文档
  ├─ 演示材料准备
  └─ 社区运营

+ 角色 5: 智能合约审计 (外部顾问)
  ├─ 合约安全检查
  ├─ 优化建议
  └─ 赛前审查
```

---

### 2.3 开发时间表 (4周冲刺)

#### Week 1: 基础搭建 (Day 1-7)

```
Day 1: 项目启动
□ 团队对齐会议
□ 代码仓库初始化
□ 开发环境配置
□ X Layer 测试网水龙头申请

Day 2-3: 智能合约开发 (Part 1)
□ AgentRegistry.sol 实现
□ 基础测试用例
□ 部署到 X Layer 测试网

Day 4-5: 智能合约开发 (Part 2)
□ TaskManager.sol 实现
□ USDC 支付逻辑
□ 部署到测试网

Day 6-7: Worker 基础
□  fork pi-mono 代码
□ 添加 X Layer 连接模块
□ 基础配置
```

#### Week 2: 核心功能 (Day 8-14)

```
Day 8-9: TradingVault 合约
□ 资产管理逻辑
□ 授权机制
□ 部署测试

Day 10-11: OKX 集成 (Part 1)
□ DEX API SDK 封装
□ 价格查询功能
□ 市场数据获取

Day 12-13: OKX 集成 (Part 2)
□ 交易执行功能
□ 订单管理
□ 错误处理

Day 14: 策略开发
□ DCA 策略实现
□ 基础回测
```

#### Week 3: 前后端 + 集成 (Day 15-21)

```
Day 15-16: Web App 基础
□ React 项目初始化
□ OKX Wallet 连接
□ 基础 UI 组件

Day 17-18: API 服务
□ Node.js 后端搭建
□ 数据库连接
□ 基础 CRUD API

Day 19-20: 前端页面
□ Agent 市场页面
□ 任务管理页面
□ 投资组合页面

Day 21: 集成测试
□ 端到端流程测试
□ Bug 修复
```

#### Week 4: 优化 + 演示 (Day 22-30)

```
Day 22-24: 主网部署
□ 合约部署到 X Layer 主网
□ 配置生产环境
□ 主网测试

Day 25-26: 性能优化
□ Gas 优化
□ 前端性能优化
□ 缓存策略

Day 27-28: Demo 准备
□ 3 分钟演示脚本
□ 演示视频录制
□ PPT 制作

Day 29: 文档完善
□ README 完善
□ 技术文档
□ 演示检查

Day 30: 提交
□ 最终代码检查
□ 提交所有材料
□ 休息准备答辩
```

---

### 2.4 风险管理计划

#### 技术风险

| 风险 | 可能性 | 影响 | 应对策略 |
|------|--------|------|----------|
| **智能合约漏洞** | 中 | 高 | 1. 使用成熟库 (OpenZeppelin)<br>2. 简化逻辑，避免复杂<br>3. 预留时间审计<br>4. 准备备用方案 |
| **OKX API 不稳定** | 低 | 中 | 1. 缓存价格数据<br>2. 优雅降级<br>3. 模拟数据备用 |
| **X Layer 拥堵** | 低 | 中 | 1. Gas 优化<br>2. 批量操作<br>3. 非关键操作延后 |
| **pi-mono 适配问题** | 中 | 高 | 1. 提前测试<br>2. 准备替代方案<br>3. 简化功能 |
| **合约部署失败** | 低 | 高 | 1. 测试网充分测试<br>2. 准备部署脚本<br>3. 预留 Gas |

#### 进度风险

| 风险 | 可能性 | 影响 | 应对策略 |
|------|--------|------|----------|
| **进度落后** | 高 | 高 | 1. 设定 MVP 范围<br>2. 优先级排序<br>3. 砍次要功能<br>4. 每日站会 |
| **团队沟通不畅** | 中 | 中 | 1. 每日同步<br>2. 使用项目管理工具<br>3. 明确接口约定 |
| **技术栈不熟悉** | 中 | 中 | 1. 提前学习<br>2. 寻找导师<br>3. 简化技术方案 |

#### 外部风险

| 风险 | 可能性 | 影响 | 应对策略 |
|------|--------|------|----------|
| **比赛规则变更** | 低 | 高 | 1. 关注官方通知<br>2. 保持灵活<br>3. 多手准备 |
| **X Layer 网络问题** | 低 | 高 | 1. 测试网多测试<br>2. 准备演示视频<br>3. 离线演示方案 |
| **OKX API 限制** | 中 | 中 | 1. 提前申请 API Key<br>2. 控制调用频率<br>3. 申请更高限额 |

---

### 2.5 资源清单

#### 开发资源

```
基础设施:
□ GitHub 组织/仓库
□ Vercel 账号 (前端部署)
□ Railway/Render 账号 (后端部署)
□ PostgreSQL 数据库 (Railway/AWS RDS)
□ IPFS 节点/Pinata 账号

测试网资源:
□ X Layer Sepolia 测试币
  └─ 获取: https://www.okx.com/xlayer/faucet
□ X Layer Mainnet 主网币 (少量)
  └─ 从 OKX 交易所提币
□ OKX API Key (测试 + 生产)
  └─ 申请: https://www.okx.com/account/my-api

开发工具:
□ Hardhat/Foundry (合约开发)
□ Node.js 18+ (后端)
□ React + TypeScript (前端)
□ Docker (Worker 部署)
□ VS Code + 插件
```

#### 学习资源

```
X Layer 相关:
□ X Layer 官方文档
  └─ https://www.okx.com/xlayer/docs
□ X Layer 开发者指南
□ OKX OnchainOS SDK 文档
  └─ https://www.okx.com/learn/onchainos-our-ai-toolkit-for-developers

OKX DEX API:
□ OKX DEX API 文档
  └─ https://www.okx.com/web3/build/docs/waas/dex-introduction
□ OKX Wallet 集成文档

智能合约:
□ OpenZeppelin 文档
□ Solidity by Example
□ X Layer 合约示例

比赛相关:
□ 比赛官方文档
□ 往届获奖项目分析
□ 评委背景研究
```

---

### 2.6 演示准备清单

#### Demo 场景设计

```
场景 1: 注册 Agent (30秒)
□ 展示 Agent 市场
□ 选择 "DCA Trading Agent"
□ 查看 Agent 详情和历史业绩

场景 2: 雇佣 Agent (60秒)
□ 点击 "Hire Agent"
□ 输入投资金额 (1000 USDC)
□ OKX Wallet 签名确认
□ 展示链上交易

场景 3: 策略执行 (60秒)
□ 展示 Agent 自动执行 DCA
□ 显示交易记录
□ 展示收益计算
□ 实时价格监控

场景 4: 收益提取 (30秒)
□ 用户请求提取收益
□ Agent 结算
□ USDC 到账
```

#### 演示材料

```
□ 3 分钟演示视频
  ├─ 1080p 画质
  ├─ 清晰音频
  ├─ 字幕
  └─ 上传到 YouTube/优酷

□ PPT 演示文稿
  ├─ 项目介绍 (1页)
  ├─ 问题定义 (1页)
  ├─ 解决方案 (2页)
  ├─ 技术架构 (1页)
  ├─ Demo 展示 (1页)
  ├─ 商业模式 (1页)
  ├─ 团队介绍 (1页)
  └─ 未来规划 (1页)

□ Live Demo 备用
  ├─ 主网部署地址
  ├─ 测试账号
  ├─ 演示数据准备
  └─ 离线视频备用

□ 项目文档
  ├─ README.md (GitHub)
  ├─ API 文档
  ├─ 部署指南
  └─ 架构设计文档
```

---

### 2.7 社区与推广计划

#### 赛前 (建立关注度)

```
Week 1-2: 预热
□ 在 X Layer Discord 介绍项目
□ 发布技术博客 (规划/架构)
□ Twitter 分享进展 (带 #XLayer #AIAgent 标签)
□ 联系 OKX 开发者关系团队

Week 3-4: 持续更新
□ 每日 Twitter 更新进展
□ 发布技术难点解决方案
□ 邀请社区成员测试
□ 收集反馈并展示改进
```

#### 赛中 (展示实力)

```
□ 每日更新开发进展
□ 分享遇到的挑战和解决方案
□ 展示代码质量
□ 感谢支持者和贡献者
□ 邀请大家试用 Demo
```

#### 赛后 (持续运营)

```
□ 发布比赛回顾
□ 感谢评委和社区
□ 公布获奖结果
□ 宣布后续发展计划
□ 建立长期社区 (Discord/Telegram)
```

---

## 3. 关键决策点

### 3.1 技术决策

| 决策 | 选项 A | 选项 B | 推荐 | 理由 |
|------|--------|--------|------|------|
| **合约框架** | Hardhat | Foundry | Foundry | 测试更快，更适合比赛 |
| **前端框架** | React | Vue | React | 生态更丰富 |
| **后端语言** | Node.js | Go | Node.js | 团队熟悉，与 pi-mono 一致 |
| **数据库** | PostgreSQL | MongoDB | PostgreSQL | 关系型更适合金融业务 |
| **部署平台** | Vercel | AWS | Vercel | 简单快速，适合 Demo |
| **Worker 部署** | Docker | 直接 Node.js | Docker | 标准化，易于展示 |

### 3.2 功能优先级

```
P0 - 必须有 (MVP):
□ AgentRegistry 合约
□ TaskManager 合约 + USDC 支付
□ 基础 Worker (pi-mono + X Layer)
□ 前端 Agent 市场
□ OKX Wallet 集成

P1 - 重要 (影响获奖):
□ TradingVault 合约
□ DCA 策略实现
□ 价格监控
□ 投资组合面板

P2 - 加分项 (有时间再做):
□ Grid 策略
□ 套利策略
□ 多 Agent 协作
□ 高级分析图表

P3 - 延后 (比赛后):
□ 移动端适配
□ 多语言支持
□ 社交功能
□ 高级风控
```

---

## 4. 检查清单 (Checklist)

### 提交前检查

```
□ 代码相关
  □ 所有代码已 push 到 GitHub
  □ README.md 完整 (包含安装/运行说明)
  □ 合约已部署到 X Layer 主网
  □ 合约地址在 README 中注明
  □ 前端已部署 (Vercel)
  □ 测试网演示可用

□ 文档相关
  □ 项目介绍文档
  □ 技术架构文档
  □ API 文档
  □ 演示视频 (3分钟)
  □ PPT 演示文稿

□ 演示相关
  □ Demo 视频已录制并上传
  □ Live Demo 备用方案
  □ 演示脚本已准备
  □ 测试数据已准备
  □ 演示账号已准备

□ 社区相关
  □ Twitter 账号已建立
  □ 至少 3 条预热推文
  □ Discord/Telegram 群组已建立
  □ 已联系 X Layer 社区

□ 合规相关
  □ 代码无敏感信息 (私钥等)
  □ 使用开源许可证 (MIT)
  □ 引用第三方代码已注明
```

---

## 5. 时间管理建议

### 每日节奏

```
09:00 - 09:30: 站会 (同步进度/问题)
09:30 - 12:30: 专注开发 (核心功能)
12:30 - 14:00: 午餐 + 休息
14:00 - 18:00: 专注开发 (集成/测试)
18:00 - 19:00: 晚餐
19:00 - 21:00: 学习/文档/社区互动
21:00 - 22:00: 代码审查 + 明日计划

周末: 至少休息半天，避免 burnout
```

### 关键里程碑

```
Week 1 结束:
□ 合约部署到测试网
□ Worker 基础框架跑通

Week 2 结束:
□ OKX API 集成完成
□ 基础策略实现

Week 3 结束:
□ 前端可用
□ 端到端流程跑通

Week 4 Day 25:
□ 主网部署完成
□ Demo 视频录制完成

Week 4 Day 30:
□ 所有材料提交
□ 准备答辩
```

---

## 6. 常见陷阱与避免

### 陷阱 1: 过度设计

```
❌ 错误: 想做一个完美的系统，包含所有功能
✅ 正确: 聚焦 MVP，先让核心流程跑通

避免方法:
- 严格遵守 P0/P1/P2 优先级
- 设定 "功能冻结日" (Week 3 Day 21)
- 接受不完美，追求可用
```

### 陷阱 2: 忽视演示

```
❌ 错误: 只关注代码，最后随便准备演示
✅ 正确: 从 Day 1 就思考如何演示

避免方法:
- 每周练习一次演示
- 准备多个演示场景
- 录制视频备用
```

### 陷阱 3: 主网部署太晚

```
❌ 错误: Week 4 才尝试主网部署
✅ 正确: Week 3 就开始主网测试

避免方法:
- Week 2 就开始准备主网部署脚本
- Week 3 必须完成主网部署
- 预留时间处理主网问题
```

### 陷阱 4: 团队沟通不畅

```
❌ 错误: 各做各的，最后集成不上
✅ 正确: 每日同步，接口先行

避免方法:
- 每日站会必须参加
- 接口文档先写后做
- 频繁集成测试
```

---

## 7. 成功标准

### 最低成功 (必须达到)

```
□ X Layer 主网部署成功
□ 基础功能可用 (雇佣 Agent + 执行任务)
□ 演示视频完成
□ 代码开源
□ 提交所有材料
```

### 期望成功 (争取达到)

```
□ 所有 P0 功能完成
□ 部分 P1 功能完成
□ Live Demo 流畅
□ 社区关注度 > 100 人
□ 获得 X Layer 官方转发
```

### 超越成功 (惊喜)

```
□ 所有 P0 + P1 功能完成
□ 获得比赛奖项
□ 社区关注度 > 500 人
□ 收到投资意向
□ 决定继续长期运营
```

---

## 8. 下一步行动

### 立即执行 (今天)

```
□ 1. 确认团队成员和时间投入
□ 2. 创建项目 GitHub 仓库
□ 3. 申请 X Layer 测试币
□ 4. 申请 OKX API Key
□ 5. 创建项目 Twitter 账号
□ 6. 加入 X Layer Discord
□ 7. 制定详细 Week 1 计划
```

### 本周完成

```
□ 1. 完成智能合约初步设计
□ 2. 完成 API 接口设计
□ 3. 搭建开发环境
□ 4. 编写第一个测试合约
□ 5. 发布第一条预热推文
```

---

## 总结

### 核心要点

1. **基于 pi-mono**: 复用 80% 核心代码，专注 20% X Layer 适配
2. **聚焦 Trading**: 利用 X Layer + OKX 生态优势，专注 DeFi/Trading
3. **MVP 优先**: 确保核心功能可用，次要功能延后
4. **演示导向**: 从 Day 1 就准备演示，不只是写代码
5. **社区参与**: 积极互动，建立关注度，争取官方支持

### 最终检查

```
准备好了吗？
├─ 团队齐了吗？
├─ 时间有了吗？
├─ 资源申请了吗？
├─ 计划清晰了吗？
└─ 决心坚定了吗？

如果都是 YES，那就开始吧！
```

---

*本文档与 dAgent X Layer Hackathon 项目执行同步更新*
