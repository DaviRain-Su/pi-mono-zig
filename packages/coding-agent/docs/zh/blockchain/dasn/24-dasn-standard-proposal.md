# DASN 标准贡献提案

> 向 ERC-8004、Vouch Protocol 及相关标准组织的扩展提案

---

## 1. 贡献策略总览

### 1.1 目标
- **短期**: 让 DASN 兼容现有标准
- **中期**: 扩展现有标准以支持 DASN 需求
- **长期**: 推动 DASN 成为 Agent 服务网络的事实标准

### 1.2 贡献路径

```
Phase 1: 兼容性 (现在 - 3个月)
├── 实现现有标准适配器
├── 提交兼容性报告
└── 参与社区讨论

Phase 2: 扩展提案 (3-6个月)
├── 向 ERC-8004 提交扩展 EIP
├── 向 Vouch 提交 DASN 集成 PR
└── 向 A2A/MCP 提交服务发现扩展

Phase 3: 标准化 (6-12个月)
├── 提交独立标准草案
├── 组建标准工作组
└── 推动行业采用
```

---

## 2. ERC-8004 扩展提案

### 2.1 提案概述

**EIP 标题**: ERC-8004 Extension: Task Execution & Settlement Standard

**摘要**: 扩展 ERC-8004 以支持去中心化 Agent 任务执行、支付结算和争议解决的标准接口。

**动机**: 当前 ERC-8004 专注于身份和声誉，但缺乏任务执行层的标准，导致 Agent 服务难以形成闭环经济。

### 2.2 详细规范

```solidity
// 新增接口: IAgentTaskManager
pragma solidity ^0.8.20;

interface IAgentTaskManager {
    // ========== 事件 ==========
    
    /// @notice 任务创建事件
    event TaskCreated(
        bytes32 indexed taskId,
        address indexed client,
        uint256 agentId,
        bytes32 contentHash,
        uint256 budget,
        uint64 deadline
    );
    
    /// @notice 任务认领事件
    event TaskClaimed(
        bytes32 indexed taskId,
        address indexed worker,
        uint64 claimedAt
    );
    
    /// @notice 结果提交事件
    event ResultSubmitted(
        bytes32 indexed taskId,
        bytes32 resultHash,
        bytes32 proofHash
    );
    
    /// @notice 结算完成事件
    event SettlementCompleted(
        bytes32 indexed taskId,
        address indexed worker,
        uint256 workerReward,
        uint256 platformFee
    );
    
    /// @notice 争议事件
    event DisputeOpened(
        bytes32 indexed taskId,
        address indexed initiator,
        bytes32 reasonHash
    );
    
    // ========== 数据结构 ==========
    
    struct Task {
        bytes32 id;
        address client;
        uint256 agentId;          // ERC-8004 Agent ID
        bytes32 contentHash;      // IPFS hash of task description
        uint256 budget;           // Payment amount
        uint64 deadline;          // Unix timestamp
        TaskStatus status;
        address worker;           // Assigned worker (if claimed)
        bytes32 resultHash;       // IPFS hash of result
        bytes32 proofHash;        // Proof of execution
        uint64 completedAt;
    }
    
    enum TaskStatus {
        Pending,      // 等待认领
        Claimed,      // 已认领
        Submitted,    // 结果已提交
        Accepted,     // 已接受
        Disputed,     // 争议中
        Resolved,     // 已解决
        Refunded      // 已退款
    }
    
    struct Settlement {
        bytes32 taskId;
        uint256 workerReward;
        uint256 platformFee;
        uint256 refundAmount;
        SettlementStatus status;
    }
    
    enum SettlementStatus {
        Pending,
        Completed,
        Disputed
    }
    
    // ========== 核心函数 ==========
    
    /// @notice 创建任务
    /// @param agentId ERC-8004 Agent ID
    /// @param contentHash IPFS hash of task content
    /// @param deadline Task deadline timestamp
    /// @return taskId Unique task identifier
    function createTask(
        uint256 agentId,
        bytes32 contentHash,
        uint64 deadline
    ) external payable returns (bytes32 taskId);
    
    /// @notice Worker 认领任务
    /// @param taskId Task identifier
    function claimTask(bytes32 taskId) external;
    
    /// @notice Worker 提交结果
    /// @param taskId Task identifier
    /// @param resultHash IPFS hash of result
    /// @param proofHash Hash of execution proof
    function submitResult(
        bytes32 taskId,
        bytes32 resultHash,
        bytes32 proofHash
    ) external;
    
    /// @notice Client 接受结果并结算
    /// @param taskId Task identifier
    function acceptResult(bytes32 taskId) external;
    
    /// @notice Client 发起争议
    /// @param taskId Task identifier
    /// @param reasonHash IPFS hash of dispute reason
    function openDispute(
        bytes32 taskId,
        bytes32 reasonHash
    ) external;
    
    /// @notice 仲裁者解决争议
    /// @param taskId Task identifier
    /// @param workerWins Whether worker wins the dispute
    /// @param workerReward Final reward for worker (if wins)
    function resolveDispute(
        bytes32 taskId,
        bool workerWins,
        uint256 workerReward
    ) external;
    
    /// @notice 获取任务信息
    function getTask(bytes32 taskId) external view returns (Task memory);
    
    /// @notice 获取 Worker 的活跃任务列表
    function getWorkerTasks(address worker) external view returns (bytes32[] memory);
    
    /// @notice 获取 Client 的任务历史
    function getClientTasks(address client) external view returns (bytes32[] memory);
}
```

### 2.3 Agent Card 扩展

```json
{
  "type": "https://eips.ethereum.org/EIPS/eip-8004#registration-v1",
  "name": "DASN-Compatible Agent",
  
  // 标准 ERC-8004 字段...
  
  // DASN 扩展
  "extensions": {
    "eip": "https://eips.ethereum.org/EIPS/eip-XXXX",
    "dasn": {
      "version": "1.0.0",
      "capabilities": {
        "taskExecution": true,
        "paymentSettlement": true,
        "disputeResolution": true
      },
      "pricing": {
        "model": "per_task",
        "basePrice": "0.01",
        "currency": "ETH",
        "estimatorEndpoint": "https://agent.example.com/estimate"
      },
      "taskTypes": [
        {
          "id": "code-generation",
          "name": "Code Generation",
          "description": "Generate code from natural language",
          "inputSchema": { "type": "object", ... },
          "outputSchema": { "type": "string" },
          "avgPrice": "0.01",
          "avgDuration": 30
        }
      ],
      "settlement": {
        "chainId": 1,
        "contractAddress": "0x...",
        "acceptedTokens": ["ETH", "USDC", "DAI"],
        "disputePeriod": 86400
      },
      "reputation": {
        "totalTasks": 150,
        "completedTasks": 145,
        "disputeRate": 0.02,
        "avgRating": 4.8
      }
    }
  }
}
```

### 2.4 提交计划

| 阶段 | 时间 | 动作 | 负责人 |
|------|------|------|--------|
| 1 | Week 1-2 | 起草 EIP 文档 | 核心团队 |
| 2 | Week 3 | 社区反馈收集 | 社区经理 |
| 3 | Week 4 | 根据反馈修订 | 核心团队 |
| 4 | Week 5-6 | 提交正式 EIP PR | 技术负责人 |
| 5 | Week 7+ | 参与 Ethereum Magicians 讨论 | 全团队 |

---

## 3. Vouch Protocol 集成提案

### 3.1 提案概述

**标题**: Integration Proposal: DASN Worker Verification via Vouch

**摘要**: 提议 Vouch Protocol 作为 DASN Worker 的信任验证层，建立双向数据同步机制。

### 3.2 技术规范

#### 3.2.1 Vouch → DASN 数据流

```rust
// programs/vouch_dasn_bridge/src/lib.rs
use anchor_lang::prelude::*;
use vouch_cpi::AgentIdentity;

#[program]
pub mod vouch_dasn_bridge {
    use super::*;
    
    /// DASN Worker 注册时同步到 Vouch
    pub fn register_worker_with_vouch(
        ctx: Context<RegisterWorkerWithVouch>,
        worker_name: String,
    ) -> Result<()> {
        let worker = &mut ctx.accounts.worker;
        let vouch_agent = &ctx.accounts.vouch_agent;
        
        // 验证 Vouch Agent 存在且活跃
        require_vouch_active!(vouch_agent)?;
        
        worker.owner = ctx.accounts.owner.key();
        worker.name = worker_name;
        worker.vouch_pda = vouch_agent.key();
        worker.status = WorkerStatus::Active;
        
        // 同步 Vouch 声誉到 DASN
        worker.reputation_score = vouch_agent.reputation.score;
        
        emit!(WorkerRegisteredWithVouch {
            worker: worker.key(),
            vouch_agent: vouch_agent.key(),
            reputation: worker.reputation_score,
        });
        
        Ok(())
    }
    
    /// 任务完成后更新双方声誉
    pub fn sync_task_completion(
        ctx: Context<SyncTaskCompletion>,
        quality_score: u8,
    ) -> Result<()> {
        let worker = &mut ctx.accounts.worker;
        let vouch_agent = &mut ctx.accounts.vouch_agent;
        
        // 更新 DASN Worker 统计
        worker.completed_tasks += 1;
        
        // 计算新声誉分数
        let new_score = calculate_reputation(worker, quality_score);
        worker.reputation_score = new_score;
        
        // 同步到 Vouch
        vouch_cpi::report_behavior(
            CpiContext::new(
                ctx.accounts.vouch_program.to_account_info(),
                vouch_cpi::ReportBehavior {
                    agent: vouch_agent.to_account_info(),
                    reporter: worker.to_account_info(),
                },
            ),
            BehaviorReport {
                protocol: "dasn",
                action: "task_completed",
                quality_score,
                new_reputation: new_score,
            },
        )?;
        
        Ok(())
    }
}

#[derive(Accounts)]
pub struct RegisterWorkerWithVouch<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    
    #[account(
        init,
        payer = owner,
        space = 8 + Worker::SIZE,
    )]
    pub worker: Account<'info, Worker>,
    
    /// 已存在的 Vouch Agent
    pub vouch_agent: Account<'info, AgentIdentity>,
    
    pub system_program: Program<'info, System>,
}
```

#### 3.2.2 DASN → Vouch 数据流

```typescript
// src/bridges/vouch-reporter.ts
export class VouchReporter {
  constructor(
    private vouchProgram: Program<VouchIdl>,
    private dasnProgram: Program<DasnIdl>,
  ) {}
  
  /// 定期同步 DASN 任务统计到 Vouch
  async syncWorkerStats(workerAddress: PublicKey): Promise<void> {
    // 获取 DASN Worker 数据
    const worker = await this.dasnProgram.account.worker.fetch(workerAddress);
    
    // 构建行为报告
    const report: BehaviorReport = {
      protocol: 'dasn',
      period: 'weekly',
      metrics: {
        tasksCompleted: worker.completedTasks,
        tasksDisputed: worker.disputedTasks,
        avgQualityScore: worker.avgQualityScore,
        totalEarnings: worker.totalEarnings.toNumber(),
      },
      timestamp: new Date(),
    };
    
    // 提交到 Vouch
    await this.vouchProgram.methods
      .reportAggregatedBehavior(report)
      .accounts({
        agent: worker.vouchPda,
        reporter: workerAddress,
      })
      .rpc();
  }
  
  /// 监听 DASN 事件并实时同步
  startEventListener(): void {
    this.dasnProgram.addEventListener('TaskCompleted', async (event) => {
      const { worker, qualityScore } = event;
      
      // 立即同步到 Vouch
      await this.syncSingleTaskCompletion(worker, qualityScore);
    });
  }
}
```

### 3.3 提议的 Vouch 协议扩展

#### 3.3.1 新增字段: `externalProtocols`

```rust
// 提议添加到 Vouch AgentIdentity
pub struct AgentIdentity {
    // 现有字段...
    
    /// 外部协议注册信息
    pub external_protocols: Vec<ExternalProtocolRegistration>,
}

pub struct ExternalProtocolRegistration {
    /// 协议标识符
    pub protocol: String,  // e.g., "dasn", "gitcoin", "lens"
    
    /// 该协议中的身份地址
    pub external_address: String,
    
    /// 声誉分数 (由协议定义)
    pub external_reputation: u32,
    
    /// 链上证明哈希
    pub proof_hash: [u8; 32],
    
    /// 注册时间
    pub registered_at: i64,
    
    /// 最后同步时间
    pub last_sync: i64,
}
```

#### 3.3.2 新增指令: `registerExternalProtocol`

```rust
/// 注册外部协议身份
pub fn register_external_protocol(
    ctx: Context<RegisterExternalProtocol>,
    protocol: String,
    external_address: String,
    proof_hash: [u8; 32],
) -> Result<()> {
    let agent = &mut ctx.accounts.agent;
    
    // 验证调用者是 Agent owner
    require_eq!(agent.owner, ctx.accounts.owner.key(), ErrorCode::Unauthorized);
    
    // 检查是否已注册
    let exists = agent.external_protocols.iter()
        .any(|p| p.protocol == protocol);
    require!(!exists, ErrorCode::AlreadyRegistered);
    
    // 添加注册信息
    agent.external_protocols.push(ExternalProtocolRegistration {
        protocol,
        external_address,
        external_reputation: 0,
        proof_hash,
        registered_at: Clock::get()?.unix_timestamp,
        last_sync: 0,
    });
    
    emit!(ExternalProtocolRegistered {
        agent: agent.key(),
        protocol,
        external_address,
    });
    
    Ok(())
}
```

### 3.4 PR 提交计划

```markdown
# PR 1: Vouch CPI 扩展 (小型)
- 添加 DASN 相关的 CPI 调用示例
- 更新文档
- 预计审查时间: 1 周

# PR 2: External Protocol 支持 (中型)
- 添加 ExternalProtocolRegistration 结构
- 添加 register_external_protocol 指令
- 添加测试
- 预计审查时间: 2-3 周

# PR 3: 双向同步机制 (大型)
- 添加 reputation aggregation 逻辑
- 添加同步事件
- 完整的集成测试
- 预计审查时间: 3-4 周
```

---

## 4. A2A/MCP 扩展提案

### 4.1 A2A 服务发现扩展

#### 4.1.1 提议的 Agent Card 扩展

```json
{
  "name": "DASN Worker Agent",
  
  // 标准 A2A 字段...
  
  // DASN 扩展
  "extensions": {
    "dasn": {
      "registryUrl": "https://registry.dasn.network",
      "workerAddress": "0x...",
      "chainId": 1,
      
      "services": {
        "directBooking": {
          "enabled": true,
          "endpoint": "/book",
          "methods": ["POST"]
        },
        "escrowPayment": {
          "enabled": true,
          "contractAddress": "0x...",
          "acceptedTokens": ["ETH", "USDC"]
        },
        "disputeResolution": {
          "enabled": true,
          "arbitratorEndpoint": "/arbitrator"
        }
      },
      
      "pricing": {
        "model": "market",
        "currency": "USD",
        "estimationEndpoint": "/estimate"
      }
    }
  }
}
```

#### 4.1.2 A2A Registry API 提议

```typescript
// 提议的 A2A Registry 接口
interface A2ARegistry {
  // 搜索支持 DASN 的 Agents
  searchAgents(query: {
    dasnEnabled?: boolean;
    minReputation?: number;
    maxPrice?: string;
    taskType?: string;
  }): Promise<AgentCard[]>;
  
  // 获取 Agent 的 DASN 统计
  getDASNStats(agentId: string): Promise<{
    totalTasks: number;
    completionRate: number;
    avgRating: number;
    disputeRate: number;
  }>;
}
```

### 4.2 MCP 扩展: `tools/dasn`

#### 4.2.1 提议的 MCP 工具集

```json
{
  "tools": [
    {
      "name": "dasn_discover_workers",
      "description": "Discover available DASN workers for a specific task",
      "inputSchema": {
        "type": "object",
        "properties": {
          "taskType": { "type": "string" },
          "budget": { "type": "string" },
          "deadline": { "type": "string", "format": "date-time" },
          "minReputation": { "type": "number", "minimum": 0, "maximum": 100 }
        },
        "required": ["taskType"]
      }
    },
    {
      "name": "dasn_create_task",
      "description": "Create a task on DASN network",
      "inputSchema": {
        "type": "object",
        "properties": {
          "description": { "type": "string" },
          "workerAddress": { "type": "string" },
          "budget": { "type": "string" },
          "deadline": { "type": "string" }
        },
        "required": ["description", "budget"]
      }
    },
    {
      "name": "dasn_check_task_status",
      "description": "Check status of a DASN task",
      "inputSchema": {
        "type": "object",
        "properties": {
          "taskId": { "type": "string" }
        },
        "required": ["taskId"]
      }
    },
    {
      "name": "dasn_accept_result",
      "description": "Accept task result and release payment",
      "inputSchema": {
        "type": "object",
        "properties": {
          "taskId": { "type": "string" },
          "rating": { "type": "number", "minimum": 1, "maximum": 5 }
        },
        "required": ["taskId"]
      }
    },
    {
      "name": "dasn_open_dispute",
      "description": "Open a dispute for unsatisfactory result",
      "inputSchema": {
        "type": "object",
        "properties": {
          "taskId": { "type": "string" },
          "reason": { "type": "string" }
        },
        "required": ["taskId", "reason"]
      }
    }
  ]
}
```

#### 4.2.2 MCP Server 实现参考

```typescript
// src/mcp/dasn-tools.ts
import { Server } from '@modelcontextprotocol/sdk/server/index.js';

export class DASNMcpServer {
  private server: Server;
  private dasnClient: DASNClient;
  
  constructor(dasnClient: DASNClient) {
    this.dasnClient = dasnClient;
    this.server = new Server({
      name: 'dasn-mcp-server',
      version: '1.0.0',
    }, {
      capabilities: { tools: {} }
    });
    
    this.registerTools();
  }
  
  private registerTools() {
    // dasn_discover_workers
    this.server.setRequestHandler(CallToolRequestSchema, async (request) => {
      if (request.params.name === 'dasn_discover_workers') {
        const { taskType, budget, minReputation } = request.params.arguments;
        
        const workers = await this.dasnClient.discoverWorkers({
          taskType,
          maxBudget: budget ? parseFloat(budget) : undefined,
          minReputation,
        });
        
        return {
          content: workers.map(w => ({
            type: 'text',
            text: `Worker: ${w.name}\nAddress: ${w.address}\nReputation: ${w.reputationScore}/100\nPrice: ${w.pricing.basePrice} ${w.pricing.currency}`,
          })),
        };
      }
      
      // ... 其他工具
    });
  }
}
```

---

## 5. 独立标准提案 (长期)

### 5.1 DASN Protocol Specification v1.0

#### 5.1.1 标准范围

**标题**: DASN Protocol: Decentralized Agent Service Network Standard

**范围**:
1. Agent Discovery and Registration
2. Task Definition and Matching
3. Execution and Verification
4. Payment and Settlement
5. Reputation and Dispute Resolution
6. Cross-chain Interoperability

#### 5.1.2 标准结构

```
DASN Standard
├── Part 1: Core Protocol
│   ├── Agent Identity
│   ├── Task Lifecycle
│   └── Message Formats
├── Part 2: Economic Layer
│   ├── Pricing Models
│   ├── Settlement
│   └── Incentives
├── Part 3: Trust Layer
│   ├── Reputation
│   ├── Dispute Resolution
│   └── Verification
├── Part 4: Implementation
│   ├── Smart Contract Interface
│   ├── SDK Requirements
│   └── Testing Guidelines
└── Part 5: Appendices
    ├── Glossary
    ├── References
    └── Changelog
```

### 5.2 标准工作组组建

#### 5.2.1 成员邀请名单

| 角色 | 候选组织 | 贡献领域 |
|------|---------|---------|
| 主席 | pi-mono | 架构设计 |
| 联合主席 | Vouch | 信任层 |
| 编辑 | MetaMask | ERC-8004 协调 |
| 贡献者 | Anthropic | MCP 协调 |
| 贡献者 | Google | A2A 协调 |
| 贡献者 | Solana Foundation | 链层 |
| 观察员 | OpenAI | 反馈 |

#### 5.2.2 会议节奏

- **月度会议**: 进展同步
- **季度评审**: 标准更新
- **年度大会**: 路线图规划

---

## 6. 社区建设

### 6.1 沟通渠道

| 渠道 | 用途 | 频率 |
|------|------|------|
| GitHub Discussions | 技术讨论 | 持续 |
| Discord Server | 社区支持 | 持续 |
| Monthly Community Call | 进展更新 | 月度 |
| Standards Working Group | 标准制定 | 双周 |
| Conference Talks | 推广 | 季度 |

### 6.2 教育资源

- **文档站点**: standards.dasn.network
- **教程系列**: "Building with DASN"
- **示例仓库**: dasn-examples
- **在线课程**: "Agent Service Network 101"

---

## 7. 时间线汇总

```
Month 1-2: 兼容实现
├── 完成 ERC-8004 适配器
├── 完成 Vouch 适配器
└── 提交兼容性报告

Month 3-4: 扩展提案
├── 提交 ERC-8004 Extension EIP Draft
├── 提交 Vouch Integration PR
└── A2A/MCP 扩展讨论

Month 5-6: 标准审查
├── 收集社区反馈
├── 修订提案
└── 小规模试点

Month 7-9: 试点验证
├── 生产环境测试
├── 安全审计
└── 性能优化

Month 10-12: 标准发布
├── 发布 DASN Standard v1.0
├── 组建标准工作组
└── 行业推广
```

---

*本文档与 DASN 标准化进程同步更新*
