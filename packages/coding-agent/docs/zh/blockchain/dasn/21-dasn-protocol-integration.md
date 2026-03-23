# DASN 协议整合实现指南

> 与 ERC-8004、Vouch Protocol、A2A/MCP 的详细整合方案

---

## 整合架构总览

```
┌─────────────────────────────────────────────────────────────────┐
│                        DASN Worker                              │
├─────────────────────────────────────────────────────────────────┤
│  协议适配层 (Adapters)                                            │
│  ┌──────────────┬──────────────┬──────────────┐                │
│  │  ERC-8004    │   Vouch      │  A2A/MCP     │                │
│  │  Adapter     │   Adapter    │  Adapter     │                │
│  └──────┬───────┴──────┬───────┴──────┬───────┘                │
├─────────┼──────────────┼──────────────┼────────────────────────┤
│         │              │              │                        │
│  ┌──────▼──────────────▼──────────────▼──────┐                 │
│  │        DASN Core Runtime (pi-mono)        │                 │
│  │  ┌──────────┐  ┌──────────┐  ┌─────────┐ │                 │
│  │  │  Task    │  │ Worker   │  │Payment  │ │                 │
│  │  │ Executor │  │ Identity │  │Escrow   │ │                 │
│  │  └──────────┘  └──────────┘  └─────────┘ │                 │
│  └───────────────────────────────────────────┘                 │
├─────────────────────────────────────────────────────────────────┤
│  区块链层                                                        │
│  ┌──────────────────┐  ┌──────────────────┐                    │
│  │  Solana/Sui      │  │  Ethereum (可选)  │                    │
│  │  (主链)          │  │  (身份桥接)       │                    │
│  └──────────────────┘  └──────────────────┘                    │
└─────────────────────────────────────────────────────────────────┘
```

---

## 一、ERC-8004 整合

### 1.1 注册 ERC-8004 Agent

```typescript
// src/adapters/erc8004/registry.ts
import { ethers } from 'ethers';
import { ERC8004_ABI } from './abis';

export class ERC8004Adapter {
  private contract: ethers.Contract;
  private provider: ethers.Provider;
  
  constructor(
    contractAddress: string,
    providerUrl: string,
    privateKey?: string
  ) {
    this.provider = new ethers.JsonRpcProvider(providerUrl);
    
    if (privateKey) {
      const wallet = new ethers.Wallet(privateKey, this.provider);
      this.contract = new ethers.Contract(contractAddress, ERC8004_ABI, wallet);
    } else {
      this.contract = new ethers.Contract(contractAddress, ERC8004_ABI, this.provider);
    }
  }
  
  /// 注册 DASN Worker 到 ERC-8004
  async registerWorker(
    workerConfig: DASNWorkerConfig
  ): Promise<{ agentId: string; txHash: string }> {
    // 构建 Agent Card (符合 ERC-8004 格式)
    const agentCard = {
      type: "https://eips.ethereum.org/EIPS/eip-8004#registration-v1",
      name: workerConfig.name,
      description: `DASN Worker - ${workerConfig.specialization.join(', ')}`,
      image: workerConfig.avatarUrl,
      services: [
        {
          name: "A2A",
          endpoint: `${workerConfig.endpoint}/.well-known/agent-card.json`,
          version: "0.3.0"
        },
        {
          name: "MCP",
          endpoint: `${workerConfig.endpoint}/mcp`,
          version: "2025-06-18"
        },
        {
          name: "DASN",
          endpoint: workerConfig.endpoint,
          version: "1.0.0"
        }
      ],
      x402Support: true,
      active: true,
      supportedTrust: ["reputation", "crypto-economic", "dasn-attestation"]
    };
    
    // 上传到 IPFS
    const agentCardUri = await uploadToIPFS(agentCard);
    
    // 链上注册
    const tx = await this.contract.register(agentCardUri);
    const receipt = await tx.wait();
    
    // 解析 agentId 从事件
    const event = receipt.events.find(e => e.event === 'Registered');
    const agentId = event.args.agentId.toString();
    
    return { agentId, txHash: receipt.hash };
  }
  
  /// 更新 Worker 元数据
  async updateMetadata(
    agentId: string,
    key: string,
    value: string
  ): Promise<string> {
    const tx = await this.contract.setMetadata(
      agentId,
      key,
      ethers.toUtf8Bytes(value)
    );
    const receipt = await tx.wait();
    return receipt.hash;
  }
  
  /// 查询 Worker 声誉
  async getReputation(agentId: string): Promise<ReputationSummary> {
    const summary = await this.contract.getReputationSummary(agentId);
    
    return {
      count: summary.count.toNumber(),
      averageRating: Number(summary.summaryValue) / Math.pow(10, summary.summaryValueDecimals),
      totalFeedback: summary.count
    };
  }
  
  /// 提交反馈 (Client 调用)
  async submitFeedback(
    agentId: string,
    rating: number,  // 0-5
    tags: string[],
    feedbackUri: string
  ): Promise<string> {
    // 将 0-5 评分转换为有界数值
    const value = Math.floor(rating * 1e6);  // 6 位小数
    
    const tx = await this.contract.giveFeedback(
      agentId,
      value,
      6,  // decimals
      tags[0] || '',
      tags[1] || '',
      '',  // endpoint
      feedbackUri,
      ethers.keccak256(ethers.toUtf8Bytes(feedbackUri))
    );
    
    const receipt = await tx.wait();
    return receipt.hash;
  }
}
```

### 1.2 DASN 扩展 ERC-8004 元数据

```typescript
// 扩展 ERC-8004 Agent Card 添加 DASN 特定字段
interface DASNAgentCard {
  // ERC-8004 标准字段
  type: string;
  name: string;
  description: string;
  services: Service[];
  
  // DASN 扩展字段
  dasn: {
    version: string;
    chain: 'solana' | 'sui' | 'ethereum';
    workerAddress: string;
    specialization: string[];  // ["code-review", "testing"]
    capabilities: Capability[];
    pricing: PricingModel;
    reputation: {
      dasnScore: number;
      completedTasks: number;
      disputeRate: number;
    };
    // 链上证明
    attestations: {
      taskCount: number;
      totalEarnings: string;
      lastActive: string;
    };
  };
}

interface Capability {
  name: string;
  description: string;
  inputSchema: JSONSchema;
  outputSchema: JSONSchema;
  pricePerUnit: string;
}

interface PricingModel {
  type: 'fixed' | 'hourly' | 'per_token';
  basePrice: string;
  currency: 'USDC' | 'SOL' | 'SUI';
}
```

---

## 二、Vouch Protocol 整合

### 2.1 Solana CPI 集成

```rust
// programs/dasn_worker/src/vouch_integration.rs
use anchor_lang::prelude::*;
use vouch_cpi::{AgentIdentity, AgentTier, require_vouch_active, require_vouch_tier};

/// DASN Worker 账户结构
#[account]
pub struct DASNWorker {
    pub owner: Pubkey,
    pub name: String,
    pub vouch_pda: Option<Pubkey>,  // 关联的 Vouch Agent PDA
    pub specialization: Vec<String>,
    pub min_reward: u64,
    pub max_tasks: u64,
    pub active_tasks: u64,
    pub status: WorkerStatus,
}

/// Worker 注册时同时注册 Vouch
pub fn register_worker_with_vouch(
    ctx: Context<RegisterWorkerWithVouch>,
    name: String,
    specialization: Vec<String>,
) -> Result<()> {
    let worker = &mut ctx.accounts.worker;
    let vouch_agent = &ctx.accounts.vouch_agent;
    
    worker.owner = ctx.accounts.owner.key();
    worker.name = name;
    worker.specialization = specialization;
    worker.vouch_pda = Some(vouch_agent.key());
    worker.status = WorkerStatus::Active;
    
    // 验证 Vouch Agent 已激活
    require_vouch_active!(vouch_agent)?;
    
    msg!("Worker registered with Vouch: {}", vouch_agent.key());
    Ok(())
}

/// 任务认领前验证 Vouch 信任等级
pub fn claim_task_with_vouch_check(
    ctx: Context<ClaimTaskWithVouch>,
) -> Result<()> {
    let worker = &ctx.accounts.worker;
    let vouch_agent = &ctx.accounts.vouch_agent;
    let task = &ctx.accounts.task;
    
    // 基础验证
    require!(worker.status == WorkerStatus::Active, ErrorCode::WorkerInactive);
    require!(worker.active_tasks < worker.max_tasks, ErrorCode::WorkerBusy);
    
    // Vouch 验证
    require_vouch_active!(vouch_agent)?;
    
    // 根据任务价值要求不同信任等级
    let required_tier = if task.budget > 1000 * 1_000_000 {  // 1000 USDC
        AgentTier::Verified
    } else if task.budget > 100 * 1_000_000 {  // 100 USDC
        AgentTier::Standard
    } else {
        AgentTier::Basic
    };
    
    require_vouch_tier!(vouch_agent, required_tier)?;
    
    // 检查声誉分数
    require_vouch_reputation!(vouch_agent, 600)?;  // 最低 600/1000
    
    // 防闪电贷：检查等级稳定时间
    require_vouch_tier_stable!(vouch_agent, clock, 300)?;  // 5分钟稳定期
    
    // 执行认领
    task.status = TaskStatus::Claimed;
    task.worker = Some(worker.key());
    worker.active_tasks += 1;
    
    Ok(())
}

/// 任务完成后更新 Vouch 声誉
pub fn complete_task_and_update_vouch(
    ctx: Context<CompleteTaskAndUpdateVouch>,
    quality_score: u8,  // 0-100
) -> Result<()> {
    let worker = &mut ctx.accounts.worker;
    let task = &mut ctx.accounts.task;
    let vouch_agent = &mut ctx.accounts.vouch_agent;
    
    require!(task.worker == Some(worker.key()), ErrorCode::NotTaskWorker);
    require!(task.status == TaskStatus::Submitted, ErrorCode::InvalidTaskStatus);
    
    // 更新任务状态
    task.status = TaskStatus::Accepted;
    worker.active_tasks -= 1;
    worker.completed_tasks += 1;
    
    // 向 Vouch 报告行为
    let behavior_report = BehaviorReport {
        protocol: "dasn",
        action: "task_completed",
        quality_score,
        timestamp: Clock::get()?.unix_timestamp,
    };
    
    vouch_cpi::report_behavior(
        CpiContext::new(
            ctx.accounts.vouch_program.to_account_info(),
            vouch_cpi::ReportBehavior {
                agent: vouch_agent.to_account_info(),
                reporter: worker.to_account_info(),
            },
        ),
        behavior_report,
    )?;
    
    Ok(())
}

#[derive(Accounts)]
pub struct RegisterWorkerWithVouch<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    
    #[account(
        init,
        payer = owner,
        space = 8 + DASNWorker::SIZE,
    )]
    pub worker: Account<'info, DASNWorker>,
    
    /// 已存在的 Vouch Agent PDA
    pub vouch_agent: Account<'info, AgentIdentity>,
    
    pub system_program: Program<'info, System>,
}
```

### 2.2 TypeScript SDK 集成

```typescript
// src/adapters/vouch/index.ts
import { Connection, PublicKey } from '@solana/web3.js';
import { AnchorProvider, Program } from '@coral-xyz/anchor';
import { VouchIdl } from './idl';

export class VouchAdapter {
  private program: Program<VouchIdl>;
  private connection: Connection;
  
  constructor(
    connection: Connection,
    programId: PublicKey,
    provider: AnchorProvider
  ) {
    this.connection = connection;
    this.program = new Program(VouchIdl, programId, provider);
  }
  
  /// 查询 Agent 的 Vouch 状态
  async getAgentStatus(ownerPubkey: PublicKey): Promise<VouchStatus> {
    const [agentPda] = PublicKey.findProgramAddressSync(
      [Buffer.from('agent'), ownerPubkey.toBuffer()],
      this.program.programId
    );
    
    try {
      const account = await this.program.account.agentIdentity.fetch(agentPda);
      
      return {
        exists: true,
        status: account.status,
        tier: this.mapTier(account.tier),
        reputationScore: account.reputation.score,
        stakedUsdc: account.stake.usdcAmount.toNumber() / 1_000_000,
        withdrawalCooldown: account.stake.withdrawalCooldown.toNumber(),
        did: `did:sol:${ownerPubkey.toBase58()}`,
      };
    } catch (e) {
      return { exists: false };
    }
  }
  
  /// Worker 注册到 Vouch
  async registerAgent(params: RegisterParams): Promise<string> {
    const tx = await this.program.methods
      .registerAgent(
        params.name,
        params.serviceCategory,
        params.agentCardUrl,
        params.agentCardHash
      )
      .accounts({
        owner: params.owner,
        // ... 其他账户
      })
      .rpc();
    
    return tx;
  }
  
  /// 质押 USDC 提升等级
  async stakeUsdc(
    owner: PublicKey,
    amount: number  // USDC
  ): Promise<string> {
    const tx = await this.program.methods
      .depositStake(new BN(amount * 1_000_000))
      .accounts({
        owner,
        // ... 其他账户
      })
      .rpc();
    
    return tx;
  }
  
  /// 监听声誉变化
  async subscribeToReputationChanges(
    agentPda: PublicKey,
    callback: (score: number) => void
  ): Promise<() => void> {
    return this.program.account.agentIdentity.subscribe(agentPda, 'confirmed')
      .on('change', (account) => {
        callback(account.reputation.score);
      });
  }
  
  private mapTier(tierNumber: number): string {
    const tiers = ['Observer', 'Basic', 'Standard', 'Verified', 'Enterprise'];
    return tiers[tierNumber] || 'Unknown';
  }
}

interface VouchStatus {
  exists: boolean;
  status?: string;
  tier?: string;
  reputationScore?: number;
  stakedUsdc?: number;
  withdrawalCooldown?: number;
  did?: string;
}
```

---

## 三、A2A 协议整合

### 3.1 A2A Agent Card 服务

```typescript
// src/adapters/a2a/server.ts
import express from 'express';
import { DASNWorker } from '../../core/worker';

export class A2AServer {
  private app: express.Application;
  private worker: DASNWorker;
  
  constructor(worker: DASNWorker) {
    this.app = express();
    this.worker = worker;
    this.setupRoutes();
  }
  
  private setupRoutes() {
    // Agent Card (符合 A2A 0.3.0)
    this.app.get('/.well-known/agent-card.json', (req, res) => {
      const agentCard = {
        name: this.worker.config.name,
        description: this.worker.config.description,
        url: this.worker.config.endpoint,
        version: '0.3.0',
        capabilities: {
          streaming: true,
          pushNotifications: false,
          stateTransitionHistory: false,
        },
        skills: this.worker.config.specialization.map(skill => ({
          id: skill,
          name: skill,
          description: `Specialized in ${skill}`,
          tags: [skill, 'dasn', 'pi-worker'],
          examples: [],
        })),
        authentication: {
          schemes: ['api-key', 'dasn-signature'],
        },
        // DASN 扩展
        extensions: {
          dasn: {
            chain: this.worker.config.chain,
            workerAddress: this.worker.config.address,
            reputation: this.worker.getReputation(),
            pricing: this.worker.config.pricing,
          }
        }
      };
      
      res.json(agentCard);
    });
    
    // 任务执行端点
    this.app.post('/a2a/tasks', express.json(), async (req, res) => {
      const { id, message, skill } = req.body;
      
      try {
        // 将 A2A 任务转换为 DASN 任务
        const dasnTask = this.convertA2AToDASN({ id, message, skill });
        
        // 执行
        const result = await this.worker.executeTask(dasnTask);
        
        // 转换回 A2A 格式
        const a2aResponse = this.convertDASNToA2A(result);
        
        res.json({
          id,
          status: { state: 'completed' },
          artifacts: [{
            parts: [{ text: a2aResponse }]
          }]
        });
      } catch (error) {
        res.status(500).json({
          id,
          status: { state: 'failed', message: error.message }
        });
      }
    });
    
    // SSE 流式响应
    this.app.get('/a2a/tasks/:id/stream', (req, res) => {
      res.setHeader('Content-Type', 'text/event-stream');
      res.setHeader('Cache-Control', 'no-cache');
      res.setHeader('Connection', 'keep-alive');
      
      // 实现流式响应...
    });
  }
  
  private convertA2AToDASN(a2aTask: any): DASNTask {
    return {
      id: a2aTask.id,
      type: a2aTask.skill || 'general',
      prompt: a2aTask.message?.parts?.[0]?.text || '',
      context: a2aTask.context,
      requirements: {
        tools: this.mapA2ATools(a2aTask.skill),
        timeout: 300000,
      }
    };
  }
  
  private convertDASNToA2A(result: DASNResult): string {
    return JSON.stringify({
      output: result.output,
      usage: result.usage,
      proof: result.proofUri,
    });
  }
  
  listen(port: number) {
    this.app.listen(port, () => {
      console.log(`A2A server listening on port ${port}`);
    });
  }
}
```

### 3.2 A2A 客户端 (调用其他 Agent)

```typescript
// src/adapters/a2a/client.ts
import fetch from 'node-fetch';

export class A2AClient {
  private apiKey?: string;
  
  constructor(apiKey?: string) {
    this.apiKey = apiKey;
  }
  
  /// 获取 Agent Card
  async getAgentCard(endpoint: string): Promise<AgentCard> {
    const response = await fetch(`${endpoint}/.well-known/agent-card.json`);
    return response.json();
  }
  
  /// 发送任务
  async sendTask(
    endpoint: string,
    task: TaskRequest
  ): Promise<TaskResponse> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
    };
    
    if (this.apiKey) {
      headers['Authorization'] = `Bearer ${this.apiKey}`;
    }
    
    const response = await fetch(`${endpoint}/a2a/tasks`, {
      method: 'POST',
      headers,
      body: JSON.stringify(task),
    });
    
    return response.json();
  }
  
  /// 流式任务
  async *streamTask(
    endpoint: string,
    task: TaskRequest
  ): AsyncGenerator<TaskUpdate> {
    const response = await fetch(`${endpoint}/a2a/tasks/${task.id}/stream`);
    const reader = response.body.getReader();
    
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      
      const text = new TextDecoder().decode(value);
      const lines = text.split('\n');
      
      for (const line of lines) {
        if (line.startsWith('data: ')) {
          yield JSON.parse(line.slice(6));
        }
      }
    }
  }
}

interface AgentCard {
  name: string;
  description: string;
  capabilities: {
    streaming: boolean;
    pushNotifications: boolean;
  };
  skills: Array<{
    id: string;
    name: string;
    tags: string[];
  }>;
  // DASN 扩展
  extensions?: {
    dasn?: {
      chain: string;
      workerAddress: string;
      reputation: any;
    }
  };
}
```

---

## 四、MCP 协议整合

### 4.1 MCP Server 实现

```typescript
// src/adapters/mcp/server.ts
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { DASNWorker } from '../../core/worker';

export class MCPAdapter {
  private server: Server;
  private worker: DASNWorker;
  
  constructor(worker: DASNWorker) {
    this.worker = worker;
    
    this.server = new Server(
      {
        name: `dasn-worker-${worker.config.name}`,
        version: '1.0.0',
      },
      {
        capabilities: {
          tools: {},
        },
      }
    );
    
    this.setupHandlers();
  }
  
  private setupHandlers() {
    // 列出可用工具
    this.server.setRequestHandler(ListToolsRequestSchema, async () => {
      return {
        tools: this.worker.config.specialization.map(skill => ({
          name: `dasn_${skill}`,
          description: `Execute ${skill} task via DASN Worker`,
          inputSchema: {
            type: 'object',
            properties: {
              prompt: {
                type: 'string',
                description: 'The task description',
              },
              context: {
                type: 'object',
                description: 'Additional context',
              },
            },
            required: ['prompt'],
          },
        })),
      };
    });
    
    // 执行工具
    this.server.setRequestHandler(CallToolRequestSchema, async (request) => {
      const { name, arguments: args } = request.params;
      
      // 提取技能名称
      const skill = name.replace('dasn_', '');
      
      // 创建 DASN 任务
      const task: DASNTask = {
        type: skill,
        prompt: args.prompt as string,
        context: args.context as Record<string, any>,
        requirements: {
          tools: [skill],
          timeout: 300000,
        },
      };
      
      try {
        // 执行
        const result = await this.worker.executeTask(task);
        
        return {
          content: [
            {
              type: 'text',
              text: result.output,
            },
          ],
          isError: false,
        };
      } catch (error) {
        return {
          content: [
            {
              type: 'text',
              text: `Error: ${error.message}`,
            },
          ],
          isError: true,
        };
      }
    });
  }
  
  async run() {
    const transport = new StdioServerTransport();
    await this.server.connect(transport);
    console.log('MCP server running on stdio');
  }
}
```

### 4.2 MCP 客户端 (发现和使用工具)

```typescript
// src/adapters/mcp/client.ts
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

export class MCPDiscoveryAdapter {
  private clients: Map<string, Client> = new Map();
  
  /// 连接到 MCP Server
  async connectToServer(serverId: string, command: string, args: string[]): Promise<Client> {
    const transport = new StdioClientTransport({
      command,
      args,
    });
    
    const client = new Client(
      {
        name: 'dasn-discovery-client',
        version: '1.0.0',
      },
      {
        capabilities: {},
      }
    );
    
    await client.connect(transport);
    this.clients.set(serverId, client);
    
    return client;
  }
  
  /// 发现可用工具
  async discoverTools(serverId: string): Promise<Tool[]> {
    const client = this.clients.get(serverId);
    if (!client) throw new Error(`Server ${serverId} not connected`);
    
    const response = await client.listTools();
    return response.tools;
  }
  
  /// 调用工具
  async callTool(
    serverId: string,
    toolName: string,
    args: Record<string, any>
  ): Promise<ToolResult> {
    const client = this.clients.get(serverId);
    if (!client) throw new Error(`Server ${serverId} not connected`);
    
    return await client.callTool({
      name: toolName,
      arguments: args,
    });
  }
  
  /// 关闭连接
  async disconnect(serverId: string) {
    const client = this.clients.get(serverId);
    if (client) {
      await client.close();
      this.clients.delete(serverId);
    }
  }
}

interface Tool {
  name: string;
  description?: string;
  inputSchema: any;
}

interface ToolResult {
  content: Array<{ type: string; text: string }>;
  isError?: boolean;
}
```

---

## 五、统一适配器层

### 5.1 协议路由器

```typescript
// src/adapters/router.ts
import { ERC8004Adapter } from './erc8004';
import { VouchAdapter } from './vouch';
import { A2AServer, A2AClient } from './a2a';
import { MCPAdapter } from './mcp';

export class ProtocolRouter {
  private adapters: {
    erc8004?: ERC8004Adapter;
    vouch?: VouchAdapter;
    a2aClient?: A2AClient;
    mcpDiscovery?: MCPDiscoveryAdapter;
  } = {};
  
  constructor(private worker: DASNWorker) {}
  
  /// 初始化所有适配器
  async initialize(config: AdapterConfig) {
    // ERC-8004
    if (config.erc8004) {
      this.adapters.erc8004 = new ERC8004Adapter(
        config.erc8004.contractAddress,
        config.erc8004.providerUrl,
        config.erc8004.privateKey
      );
    }
    
    // Vouch
    if (config.vouch) {
      this.adapters.vouch = new VouchAdapter(
        config.vouch.connection,
        config.vouch.programId,
        config.vouch.provider
      );
    }
    
    // A2A Client
    if (config.a2a) {
      this.adapters.a2aClient = new A2AClient(config.a2a.apiKey);
    }
    
    // MCP Discovery
    if (config.mcp) {
      this.adapters.mcpDiscovery = new MCPDiscoveryAdapter();
    }
  }
  
  /// 注册 Worker 到所有支持的协议
  async registerEverywhere(): Promise<RegistrationResults> {
    const results: RegistrationResults = {};
    
    // ERC-8004
    if (this.adapters.erc8004) {
      try {
        const erc8004 = await this.adapters.erc8004.registerWorker({
          name: this.worker.config.name,
          specialization: this.worker.config.specialization,
          endpoint: this.worker.config.endpoint,
          avatarUrl: this.worker.config.avatarUrl,
        });
        results.erc8004 = { success: true, agentId: erc8004.agentId };
      } catch (e) {
        results.erc8004 = { success: false, error: e.message };
      }
    }
    
    // Vouch
    if (this.adapters.vouch) {
      try {
        const vouchTx = await this.adapters.vouch.registerAgent({
          name: this.worker.config.name,
          serviceCategory: 'ai-services',
          agentCardUrl: `${this.worker.config.endpoint}/.well-known/agent-card.json`,
          agentCardHash: await this.hashAgentCard(),
          owner: this.worker.config.ownerPubkey,
        });
        results.vouch = { success: true, tx: vouchTx };
      } catch (e) {
        results.vouch = { success: false, error: e.message };
      }
    }
    
    // 启动 A2A Server
    const a2aServer = new A2AServer(this.worker);
    a2aServer.listen(this.worker.config.a2aPort || 3001);
    results.a2a = { success: true, port: this.worker.config.a2aPort };
    
    // 启动 MCP Server
    const mcpAdapter = new MCPAdapter(this.worker);
    mcpAdapter.run();
    results.mcp = { success: true };
    
    return results;
  }
  
  /// 查询 Worker 在所有协议的声誉
  async getUnifiedReputation(workerAddress: string): Promise<UnifiedReputation> {
    const reputation: UnifiedReputation = {
      dasn: await this.worker.getReputation(),
    };
    
    // ERC-8004
    if (this.adapters.erc8004) {
      try {
        reputation.erc8004 = await this.adapters.erc8004.getReputation(workerAddress);
      } catch (e) {
        reputation.erc8004 = { error: e.message };
      }
    }
    
    // Vouch
    if (this.adapters.vouch) {
      try {
        const vouchStatus = await this.adapters.vouch.getAgentStatus(
          new PublicKey(workerAddress)
        );
        reputation.vouch = vouchStatus;
      } catch (e) {
        reputation.vouch = { error: e.message };
      }
    }
    
    // 计算聚合分数
    reputation.aggregate = this.calculateAggregateScore(reputation);
    
    return reputation;
  }
  
  private calculateAggregateScore(rep: UnifiedReputation): number {
    let total = rep.dasn.score * 0.5;  // DASN 权重 50%
    
    if (rep.vouch?.reputationScore) {
      total += (rep.vouch.reputationScore / 1000 * 100) * 0.3;  // Vouch 权重 30%
    }
    
    if (rep.erc8004?.averageRating) {
      total += (rep.erc8004.averageRating * 20) * 0.2;  // ERC-8004 权重 20%
    }
    
    return Math.min(100, total);
  }
}

interface AdapterConfig {
  erc8004?: {
    contractAddress: string;
    providerUrl: string;
    privateKey?: string;
  };
  vouch?: {
    connection: Connection;
    programId: PublicKey;
    provider: AnchorProvider;
  };
  a2a?: {
    apiKey?: string;
  };
  mcp?: boolean;
}

interface RegistrationResults {
  erc8004?: { success: boolean; agentId?: string; error?: string };
  vouch?: { success: boolean; tx?: string; error?: string };
  a2a?: { success: boolean; port?: number; error?: string };
  mcp?: { success: boolean; error?: string };
}

interface UnifiedReputation {
  dasn: { score: number; completedTasks: number; disputeRate: number };
  erc8004?: any;
  vouch?: any;
  aggregate?: number;
}
```

---

## 六、配置示例

```yaml
# config.yaml - 完整协议整合配置
worker:
  name: "advanced-coding-agent"
  endpoint: "https://worker1.dasn.network"
  specialization:
    - "code-generation"
    - "code-review"
    - "testing"
  
  # DASN 配置
  dasn:
    chain: "solana"
    privateKey: ${DASN_PRIVATE_KEY}
    minReward: 10000000  # 0.01 SOL
    maxTasks: 5
  
  # ERC-8004 配置 (可选)
  erc8004:
    enabled: true
    contractAddress: "0x..."
    providerUrl: "https://ethereum-rpc.com"
    privateKey: ${ETH_PRIVATE_KEY}
  
  # Vouch 配置 (可选)
  vouch:
    enabled: true
    programId: "Vouch..."
    requiredTier: "Standard"
    minReputation: 600
  
  # A2A 配置
  a2a:
    enabled: true
    port: 3001
  
  # MCP 配置
  mcp:
    enabled: true

# 其他协议发现配置
discovery:
  # 自动发现其他 A2A Agents
  a2aRegistry: "https://a2a-registry.io"
  
  # 自动发现 MCP Servers
  mcpRegistry: "https://mcp-registry.io"
  
  # 跨链 Worker 发现
  dasnRegistry: "https://api.dasn.network/workers"
```

---

## 七、测试与验证

```typescript
// tests/integration/protocol-integration.test.ts
import { describe, it, expect, beforeAll } from 'vitest';
import { ProtocolRouter } from '../../src/adapters/router';
import { MockDASNWorker } from '../mocks/worker';

describe('Protocol Integration', () => {
  let router: ProtocolRouter;
  let worker: MockDASNWorker;
  
  beforeAll(async () => {
    worker = new MockDASNWorker();
    router = new ProtocolRouter(worker);
    
    await router.initialize({
      erc8004: {
        contractAddress: process.env.ERC8004_CONTRACT!,
        providerUrl: 'https://sepolia.infura.io/v3/...',
      },
      vouch: {
        connection: new Connection('https://api.devnet.solana.com'),
        programId: new PublicKey('Vouch...'),
        provider: mockProvider,
      },
      a2a: {},
      mcp: true,
    });
  });
  
  it('should register to all protocols', async () => {
    const results = await router.registerEverywhere();
    
    expect(results.erc8004?.success).toBe(true);
    expect(results.vouch?.success).toBe(true);
    expect(results.a2a?.success).toBe(true);
    expect(results.mcp?.success).toBe(true);
  });
  
  it('should query unified reputation', async () => {
    const reputation = await router.getUnifiedReputation(worker.address);
    
    expect(reputation.dasn).toBeDefined();
    expect(reputation.aggregate).toBeGreaterThan(0);
  });
  
  it('should handle A2A task', async () => {
    const a2aClient = new A2AClient();
    const agentCard = await a2aClient.getAgentCard(worker.endpoint);
    
    expect(agentCard.extensions?.dasn).toBeDefined();
    
    const result = await a2aClient.sendTask(worker.endpoint, {
      id: 'test-task-1',
      message: { parts: [{ text: 'Generate a React component' }] },
      skill: 'code-generation',
    });
    
    expect(result.status.state).toBe('completed');
  });
});
```

---

*本文档与 DASN 协议整合实现同步更新*
