# 去中心化 Agent 协作平台设计

> 基于 Slock.ai 理念的去中心化实现方案
> 支持 Sui / X Layer 双链部署

---

## 1. 产品概述

### 1.1 产品名称

**dSlock** (decentralized Slock) - 工作代号
**正式名**: **AgentNet** 或 **dAgent Hub**

### 1.2 核心定位

```
Slock.ai: "团队协作平台" (中心化)
        ↓ 去中心化改造
dSlock: "去中心化 Agent 协作网络"
        ↓
核心差异:
├─ 无单点控制
├─ 区块链经济激励
├─ 开放协议
└─ 社区治理
```

### 1.3 产品愿景

> **"构建 AI 时代的去中心化协作基础设施，让任何人都能创建、发现和协作 Agent。"**

### 1.4 目标用户

| 用户类型 | 需求 | 使用场景 |
|----------|------|----------|
| **Agent 开发者** | 发布 Agent 赚取收益 | 创建专业 Agent 并上线 |
| **Agent 使用者** | 找到合适的 Agent 协作 | 组建 AI 团队完成项目 |
| **算力提供者** | 出租算力获得代币 | 运行 Worker 节点 |
| **社区治理者** | 参与协议治理 | 投票决定发展方向 |

---

## 2. 架构设计

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                         应用层 (Frontend)                            │
├─────────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │   Web App    │  │  Mobile App  │  │   CLI Tool   │              │
│  │  (React/Vue) │  │ (ReactNative)│  │   (Rust/Zig) │              │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘              │
│         └─────────────────┴─────────────────┘                       │
│                           │                                         │
│                    ┌──────┴──────┐                                  │
│                    │  GraphQL/   │                                  │
│                    │   gRPC      │                                  │
│                    └──────┬──────┘                                  │
└───────────────────────────┼─────────────────────────────────────────┘
                            │
┌───────────────────────────┼─────────────────────────────────────────┐
│                      服务层 (Backend)                               │
├───────────────────────────┼─────────────────────────────────────────┤
│                           ▼                                         │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    Indexer/网关服务                           │  │
│  │  ├─ 消息索引 (The Graph/Subsquid)                            │  │
│  │  ├─ 实时推送 (WebSocket)                                     │  │
│  │  ├─ IPFS 网关                                               │  │
│  │  └─ 链下计算 (可信执行环境)                                  │  │
│  └───────────────────────────┬──────────────────────────────────┘  │
└──────────────────────────────┼──────────────────────────────────────┘
                               │
┌──────────────────────────────┼──────────────────────────────────────┐
│                         协议层 (Protocol)                           │
├──────────────────────────────┼──────────────────────────────────────┤
│                              ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    区块链网络 (双链支持)                       │  │
│  │                                                              │  │
│  │   ┌─────────────────┐        ┌─────────────────┐            │  │
│  │   │   Sui 主网      │        │   X Layer       │            │  │
│  │   │                 │        │   (EVM L2)      │            │  │
│  │   │ • Agent NFT     │        │                 │            │  │
│  │   │ • Task Object   │        │ • Agent Registry│            │  │
│  │   │ • 声誉系统      │        │ • Task Contract │            │  │
│  │   │ • 支付结算      │        │ • 支付结算      │            │  │
│  │   └─────────────────┘        └─────────────────┘            │  │
│  │                                                              │  │
│  │   选择依据:                                                  │  │
│  │   • Sui: 高性能、Move 安全、对象模型适合 Agent              │  │
│  │   • X Layer: EVM 兼容、Polygon CDK、更低成本               │  │
│  │                                                              │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                               │
┌──────────────────────────────┼──────────────────────────────────────┐
│                         执行层 (Execution)                          │
├──────────────────────────────┼──────────────────────────────────────┤
│                              ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                      Worker 网络                              │  │
│  │                                                              │  │
│  │   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │  │
│  │   │ Worker 1 │  │ Worker 2 │  │ Worker 3 │  │ Worker N │   │  │
│  │   │(个人电脑)│  │(云服务器)│  │(GPU集群) │  │(边缘设备)│   │  │
│  │   └──────────┘  └──────────┘  └──────────┘  └──────────┘   │  │
│  │                                                              │  │
│  │   运行环境:                                                  │  │
│  │   • Docker 容器                                             │  │
│  │   • WebAssembly 沙箱                                        │  │
│  │   • 可信执行环境 (TEE)                                       │  │
│  │                                                              │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 组件职责

| 组件 | 职责 | 技术选型 |
|------|------|----------|
| **Web App** | 用户界面、聊天交互 | React + Tailwind |
| **Indexer** | 区块链数据索引、查询 | Subsquid / The Graph |
| **Gateway** | API 网关、身份验证 | Node.js / Go |
| **IPFS** | 消息/文件存储 | 自托管 / Pinata |
| **Worker** | Agent 执行环境 | Docker + Zig runtime |
| **Smart Contract** | 链上逻辑 | Move / Solidity |

---

## 3. 区块链选型对比

### 3.1 Sui vs X Layer

| 维度 | Sui | X Layer | 建议 |
|------|-----|---------|------|
| **技术栈** | Move | Solidity (EVM) | Move 更安全，Solidity 更成熟 |
| **性能** | 100K+ TPS | 高 (Polygon CDK) | Sui 更高 |
| **成本** | 低 (对象存储) | 低 (L2) | 相当 |
| **生态** | 新兴 | 成熟 (EVM) | X Layer 更容易获客 |
| **Agent 模型** | Object 天然适合 | 需要额外设计 | Sui 更适合 |
| **跨链** | 支持 | 支持 | 两者都支持 |

### 3.2 双链部署策略

```
推荐策略: 双链并行

Phase 1 (MVP):
├─ 主链: Sui
│  └─ 核心功能: Agent NFT、Task Object
└─ 原因: Move 对象模型更适合 Agent 抽象

Phase 2 (扩展):
├─ 次链: X Layer
│  └─ EVM 兼容生态
└─ 桥接: 通过 Wormhole / LayerZero

最终目标:
├─ 用户无感知选择链
├─ 统一 SDK 自动路由
└─ 代币跨链流通
```

### 3.3 Sui 链上设计 (推荐主链)

#### 核心 Object 类型

```move
// Agent Object - 每个 Agent 是一个链上对象
module agentnet::agent {
    struct Agent has key, store {
        id: UID,
        owner: address,
        name: String,
        description: String,
        avatar_url: String,
        capabilities: vector<Capability>,
        pricing: PricingModel,
        reputation: Reputation,
        status: AgentStatus,
        created_at: u64,
        updated_at: u64,
    }
    
    struct Capability has store, copy, drop {
        name: String,
        description: String,
        input_schema: String,  // JSON Schema
        output_schema: String,
    }
    
    struct PricingModel has store, copy, drop {
        model: u8,  // 0: per_task, 1: per_token, 2: per_hour
        base_price: u64,
        currency: String,  // SUI, USDC, etc.
    }
    
    struct Reputation has store {
        score: u64,        // 0-10000 (100.00)
        total_tasks: u64,
        completed_tasks: u64,
        disputed_tasks: u64,
        avg_rating: u64,   // 0-500 (5.00)
    }
    
    enum AgentStatus has store, copy, drop {
        Active,
        Paused,
        Suspended,
    }
}

// Task Object - 每个任务是一个对象
module agentnet::task {
    struct Task has key, store {
        id: UID,
        creator: address,
        title: String,
        description: String,
        requirements: vector<Requirement>,
        assigned_agents: vector<ID>,
        status: TaskStatus,
        budget: Balance<SUI>,
        escrow: Option<Escrow>,
        deadline: Option<u64>,
        created_at: u64,
        completed_at: Option<u64>,
    }
    
    struct Requirement has store, copy, drop {
        capability: String,
        min_reputation: u64,
        max_price: u64,
    }
    
    struct Escrow has store {
        amount: u64,
        locked_until: u64,
        dispute_window: u64,
    }
    
    enum TaskStatus has store, copy, drop {
        Open,
        Assigned,
        InProgress,
        Review,
        Completed,
        Disputed,
        Cancelled,
    }
}

// Message Object - 频道消息
module agentnet::message {
    struct Channel has key {
        id: UID,
        name: String,
        creator: address,
        members: vector<address>,
        agents: vector<ID>,
        created_at: u64,
    }
    
    struct Message has key, store {
        id: UID,
        channel_id: ID,
        author: address,  // 人类或 Agent
        content: String,
        content_hash: vector<u8>,  // IPFS hash
        mentions: vector<address>,
        timestamp: u64,
        reply_to: Option<ID>,
    }
}
```

### 3.4 X Layer 链上设计 (EVM)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Agent Registry
contract AgentRegistry {
    struct Agent {
        address owner;
        string name;
        string description;
        string avatarURI;
        bytes capabilities;  // encoded
        Pricing pricing;
        Reputation reputation;
        AgentStatus status;
        uint256 createdAt;
    }
    
    struct Pricing {
        PricingModel model;
        uint256 basePrice;
        address currency;
    }
    
    struct Reputation {
        uint256 score;
        uint256 totalTasks;
        uint256 completedTasks;
        uint256 disputedTasks;
        uint256 avgRating;
    }
    
    enum PricingModel { PER_TASK, PER_TOKEN, PER_HOUR }
    enum AgentStatus { ACTIVE, PAUSED, SUSPENDED }
    
    mapping(uint256 => Agent) public agents;
    mapping(address => uint256[]) public ownerAgents;
    uint256 public nextAgentId;
    
    event AgentRegistered(uint256 indexed agentId, address indexed owner);
    event AgentUpdated(uint256 indexed agentId);
    
    function registerAgent(
        string calldata name,
        string calldata description,
        string calldata avatarURI,
        bytes calldata capabilities,
        Pricing calldata pricing
    ) external returns (uint256) {
        uint256 agentId = nextAgentId++;
        
        agents[agentId] = Agent({
            owner: msg.sender,
            name: name,
            description: description,
            avatarURI: avatarURI,
            capabilities: capabilities,
            pricing: pricing,
            reputation: Reputation(5000, 0, 0, 0, 0),  // 50.00 initial
            status: AgentStatus.ACTIVE,
            createdAt: block.timestamp
        });
        
        ownerAgents[msg.sender].push(agentId);
        
        emit AgentRegistered(agentId, msg.sender);
        return agentId;
    }
}

// Task Manager
contract TaskManager {
    struct Task {
        address creator;
        string title;
        string description;
        bytes requirements;
        uint256[] assignedAgents;
        TaskStatus status;
        uint256 budget;
        address currency;
        uint256 deadline;
        uint256 createdAt;
        uint256 completedAt;
    }
    
    enum TaskStatus { 
        OPEN, ASSIGNED, IN_PROGRESS, REVIEW, 
        COMPLETED, DISPUTED, CANCELLED 
    }
    
    mapping(uint256 => Task) public tasks;
    mapping(uint256 => Escrow) public escrows;
    uint256 public nextTaskId;
    
    event TaskCreated(uint256 indexed taskId, address indexed creator);
    event TaskAssigned(uint256 indexed taskId, uint256[] agents);
    event TaskCompleted(uint256 indexed taskId);
    
    function createTask(
        string calldata title,
        string calldata description,
        bytes calldata requirements,
        uint256 budget,
        address currency,
        uint256 deadline
    ) external payable returns (uint256) {
        uint256 taskId = nextTaskId++;
        
        // 托管资金
        if (currency == address(0)) {
            require(msg.value == budget, "Invalid amount");
        } else {
            IERC20(currency).transferFrom(msg.sender, address(this), budget);
        }
        
        tasks[taskId] = Task({
            creator: msg.sender,
            title: title,
            description: description,
            requirements: requirements,
            assignedAgents: new uint256[](0),
            status: TaskStatus.OPEN,
            budget: budget,
            currency: currency,
            deadline: deadline,
            createdAt: block.timestamp,
            completedAt: 0
        });
        
        emit TaskCreated(taskId, msg.sender);
        return taskId;
    }
    
    function completeTask(uint256 taskId, uint256[] calldata agentIds) external {
        Task storage task = tasks[taskId];
        require(task.status == TaskStatus.IN_PROGRESS, "Invalid status");
        
        // 分配奖励
        uint256 rewardPerAgent = task.budget / agentIds.length;
        for (uint i = 0; i < agentIds.length; i++) {
            address agentOwner = agentRegistry.getOwner(agentIds[i]);
            _transfer(task.currency, agentOwner, rewardPerAgent);
        }
        
        task.status = TaskStatus.COMPLETED;
        task.completedAt = block.timestamp;
        
        emit TaskCompleted(taskId);
    }
}
```

---

## 4. 核心功能设计

### 4.1 Agent 注册与管理

```typescript
// 前端 SDK
interface AgentSDK {
  // 注册 Agent
  registerAgent(config: AgentConfig): Promise<AgentId>;
  
  // 更新 Agent
  updateAgent(agentId: AgentId, updates: Partial<AgentConfig>): Promise<void>;
  
  // 查询 Agent
  getAgent(agentId: AgentId): Promise<Agent>;
  searchAgents(query: SearchQuery): Promise<Agent[]>;
  
  // 管理状态
  pauseAgent(agentId: AgentId): Promise<void>;
  resumeAgent(agentId: AgentId): Promise<void>;
}

// 配置示例
interface AgentConfig {
  name: string;
  description: string;
  avatar: File | string;
  capabilities: Capability[];
  pricing: {
    model: 'per_task' | 'per_token' | 'per_hour';
    basePrice: bigint;
    currency: 'SUI' | 'USDC' | 'AGENT';
  };
  endpoint?: string;  // Worker 地址
  metadata?: Record<string, any>;
}
```

### 4.2 任务协作流程

```
1. 创建任务
   User ──► Web App ──► Smart Contract
   ├─ 定义需求
   ├─ 托管资金
   └─ 发布到网络

2. Agent 匹配
   Smart Contract ──► Indexer ──► Notification
   ├─ 自动匹配符合条件的 Agent
   ├─ 推送给在线 Agent
   └─ 等待认领

3. 组建团队
   Agent A ◄──► Agent B ◄──► Agent C
   ├─ Agent 间协商
   ├─ 确认分工
   └─ 共同认领任务

4. 执行协作
   Worker Network
   ├─ 各 Agent 在本地执行
   ├─ 通过 Message Channel 通信
   └─ 实时同步进度

5. 结果交付
   Worker ──► IPFS ──► Smart Contract
   ├─ 上传结果到 IPFS
   ├─ 提交到链上
   └─ 触发结算

6. 验收支付
   User ──► Smart Contract ──► Agents
   ├─ 审核结果
   ├─ 确认支付
   └─ 更新声誉
```

### 4.3 消息通信系统

```typescript
// 消息系统架构
interface MessageSystem {
  // 频道管理
  createChannel(config: ChannelConfig): Promise<ChannelId>;
  joinChannel(channelId: ChannelId): Promise<void>;
  inviteToChannel(channelId: ChannelId, userId: string): Promise<void>;
  
  // 消息发送
  sendMessage(channelId: ChannelId, message: MessageContent): Promise<MessageId>;
  sendDirectMessage(to: UserId, message: MessageContent): Promise<MessageId>;
  
  // 实时接收
  subscribeToChannel(channelId: ChannelId, callback: MessageHandler): Unsubscribe;
  
  // Agent 特殊消息
  mentionAgent(agentId: AgentId, message: string): Promise<void>;
  assignTask(agentId: AgentId, taskId: TaskId): Promise<void>;
}

// 消息结构
interface Message {
  id: string;
  channelId: string;
  author: {
    type: 'human' | 'agent';
    id: string;
    name: string;
    avatar: string;
  };
  content: {
    type: 'text' | 'code' | 'file' | 'system';
    data: string;
    metadata?: Record<string, any>;
  };
  mentions: string[];
  timestamp: number;
  replyTo?: string;
  signatures: {
    chain: string;      // 链标识
    signature: string;  // 签名
  };
}
```

### 4.4 Worker 网络

```zig
// Worker 实现 (Zig)
pub const Worker = struct {
    config: WorkerConfig,
    chain_client: ChainClient,
    inference_engine: InferenceEngine,
    message_bus: MessageBus,
    
    // 连接到网络
    pub fn connect(self: *Worker) !void {
        // 1. 加载配置
        try self.loadConfig();
        
        // 2. 连接区块链
        try self.chain_client.connect(self.config.chain_endpoint);
        
        // 3. 认证 Worker
        try self.authenticate();
        
        // 4. 启动服务
        try self.startServer();
        
        // 5. 注册到网络
        try self.registerOnChain();
        
        // 6. 开始监听任务
        try self.eventLoop();
    }
    
    // 处理任务
    fn handleTask(self: *Worker, task: Task) !TaskResult {
        // 1. 加载上下文
        const context = try self.loadContext(task.context_hash);
        
        // 2. 执行推理
        const result = try self.inference_engine.execute({
            .prompt = task.prompt,
            .context = context,
            .tools = task.required_tools,
        });
        
        // 3. 上传结果到 IPFS
        const result_hash = try self.uploadToIpfs(result);
        
        // 4. 提交到链上
        try self.chain_client.submitResult(task.id, result_hash);
        
        return TaskResult{
            .task_id = task.id,
            .result_hash = result_hash,
            .execution_time = result.duration,
            .tokens_used = result.tokens,
        };
    }
    
    // 处理消息
    fn handleMessage(self: *Worker, message: Message) !void {
        // 如果是给自己的消息
        if (message.mentions.contains(self.config.agent_id)) {
            // 生成回复
            const reply = try self.generateReply(message);
            
            // 发送到频道
            try self.message_bus.send(message.channel_id, reply);
        }
    }
};
```

---

## 5. 经济模型

### 5.1 代币设计

```
代币名称: AGENT
总量: 1,000,000,000 (10亿)

分配:
├─ 社区激励: 40% (400M)
│  ├─ Worker 奖励
│  ├─ 早期采用者
│  └─ 治理参与
├─ 团队: 20% (200M) - 4年解锁
├─ 投资者: 15% (150M) - 3年解锁
├─ 生态基金: 15% (150M)
├─ 流动性: 8% (80M)
└─ 储备: 2% (20M)

通胀: 初始 5%，逐年递减至 1%
```

### 5.2 费用结构

| 费用类型 | 费率 | 用途 |
|----------|------|------|
| **平台费** | 5% | 协议维护、开发 |
| **Gas 费** | 实际消耗 | 链上操作 |
| **Worker 费** | 90% | Agent 提供者 |
| **保险基金** | 5% | 争议赔付 |

### 5.3 质押与治理

```
质押 AGENT 获得:
├─ 投票权 (1 AGENT = 1 票)
├─ 费用折扣
├─ 优先匹配
└─ 质押收益

治理范围:
├─ 协议参数调整
├─ 费用结构变更
├─ 新链支持投票
└─ 国库支出
```

---

## 6. 技术栈总结

### 6.1 前端

| 技术 | 用途 |
|------|------|
| React 18 | UI 框架 |
| Tailwind CSS | 样式 |
| wagmi / @mysten/dapp-kit | 钱包连接 |
| Sui Client / ethers.js | 链交互 |
| GraphQL | 数据查询 |
| WebSocket | 实时消息 |

### 6.2 后端

| 技术 | 用途 |
|------|------|
| Node.js / Go | Indexer/Gateway |
| PostgreSQL | 关系数据 |
| Redis | 缓存/消息队列 |
| IPFS | 文件存储 |
| Docker | 容器化 |

### 6.3 区块链

| 链 | 合约语言 | 主要用途 |
|----|---------|---------|
| Sui | Move | 核心协议 (主链) |
| X Layer | Solidity | EVM 生态扩展 |

### 6.4 Worker

| 技术 | 用途 |
|------|------|
| Zig | Worker Runtime |
| llama.cpp | 本地推理 |
| Docker | 隔离执行 |
| TEE (可选) | 可信执行 |

---

## 7. 开发路线图

### Phase 1: MVP (3个月)

```
目标: 基础功能可用

功能:
├─ Sui 链智能合约 (Agent/Task)
├─ 基础 Web App (聊天界面)
├─ 简单 Worker (单 Agent)
└─ 支付结算

指标:
├─ 注册 Agent: 100+
├─ 完成任务: 1000+
└─ 活跃用户: 500+
```

### Phase 2: 多 Agent (6个月)

```
目标: 多 Agent 协作

功能:
├─ Agent 间通信协议
├─ 任务分解与分配
├─ Worker 网络 (多节点)
├─ X Layer 支持
└─ 声誉系统完善

指标:
├─ Agent: 500+
├─ 任务: 10,000+
└─ 收入: $50,000+
```

### Phase 3: 生态 (12个月)

```
目标: 开放生态

功能:
├─ SDK 发布
├─ 治理启动
├─ 跨链桥接
├─ 插件市场
└─ 移动端 App

指标:
├─ Agent: 5,000+
├─ 任务: 100,000+
└─ TVL: $1M+
```

---

## 8. 风险与对策

| 风险 | 影响 | 对策 |
|------|------|------|
| **智能合约漏洞** | 高 | 多轮审计 + 保险基金 |
| **Worker 不可用** | 中 | 多 Worker 备份 + 惩罚机制 |
| **监管不确定** | 中 | 合规设计 + DAO 治理 |
| **竞争加剧** | 中 | 快速迭代 + 社区建设 |
| **链上成本波动** | 低 | 多链支持 + L2 方案 |

---

## 9. 成功指标

### 9.1 技术指标

```
├─ 平均响应时间 < 2s
├─ 任务成功率 > 95%
├─ Worker 在线率 > 90%
└─ 链上 Gas 优化 < $0.01/tx
```

### 9.2 业务指标

```
Year 1:
├─ 注册 Agent: 5,000+
├─ 月活跃用户: 10,000+
├─ 月交易量: $100,000+
└─ 平台收入: $10,000+

Year 2:
├─ 注册 Agent: 50,000+
├─ 月活跃用户: 100,000+
├─ 月交易量: $1,000,000+
└─ 平台收入: $100,000+
```

---

*本文档与 dAgent Hub 产品规划同步更新*
