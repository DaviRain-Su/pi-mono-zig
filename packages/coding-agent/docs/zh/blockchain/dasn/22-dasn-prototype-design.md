# DASN 多协议 Worker 原型设计

> 支持 ERC-8004、Vouch、A2A、MCP 的 Worker 架构设计

---

## 1. 原型目标

### 1.1 核心目标
构建一个**生产级原型**，验证以下假设：
1. Worker 可以同时注册到多个协议并保持身份一致性
2. 不同协议的 Client 可以无缝调用同一个 Worker
3. 多源声誉可以合理聚合
4. 经济激励机制可以有效运转

### 1.2 成功标准
| 指标 | 目标值 | 验证方法 |
|------|--------|----------|
| 协议注册成功率 | >95% | 自动化测试 |
| 跨协议任务执行 | 支持 A2A/MCP/DASN | 端到端测试 |
| 声誉聚合延迟 | <5秒 | 性能测试 |
| 任务完成率 | >90% | 生产数据 |
| 争议率 | <5% | 监控指标 |

---

## 2. 架构设计

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        Worker Node                              │
├─────────────────────────────────────────────────────────────────┤
│  API Gateway (Ingress)                                          │
│  ├── /a2a/*          → A2A Handler                              │
│  ├── /mcp            → MCP Handler (SSE)                        │
│  ├── /dasn/*         → DASN Handler                             │
│  └── /.well-known/*  → Discovery Handlers                       │
├─────────────────────────────────────────────────────────────────┤
│  Protocol Adapters (协议适配层)                                  │
│  ┌─────────────┬─────────────┬─────────────┐                   │
│  │ A2A Adapter │ MCP Adapter │ DASN Adapter│                   │
│  │ (Inbound)   │ (Inbound)   │ (Inbound)   │                   │
│  └──────┬──────┴──────┬──────┴──────┬──────┘                   │
│         │             │             │                          │
│  ┌──────▼─────────────▼─────────────▼──────┐                   │
│  │         Task Router (任务路由器)         │                   │
│  │  - 协议格式转换                          │                   │
│  │  - 任务去重                              │                   │
│  │  - 优先级排序                            │                   │
│  └──────────────────┬──────────────────────┘                   │
├─────────────────────┼───────────────────────────────────────────┤
│                     │                                           │
│  ┌──────────────────▼──────────────────────┐                   │
│  │      DASN Core (核心业务逻辑)            │                   │
│  │  ┌──────────┐ ┌──────────┐ ┌─────────┐ │                   │
│  │  │  Task    │ │ Worker   │ │ Payment │ │                   │
│  │  │ Queue    │ │ Identity │ │ Manager │ │                   │
│  │  └────┬─────┘ └────┬─────┘ └────┬────┘ │                   │
│  │       └───────────┬┴───────────┘       │                   │
│  │                   │                     │                   │
│  │       ┌───────────▼───────────┐        │                   │
│  │       │   pi-worker Runtime   │        │                   │
│  │       │  (Execution Engine)   │        │                   │
│  │       └───────────────────────┘        │                   │
│  └────────────────────────────────────────┘                   │
├─────────────────────────────────────────────────────────────────┤
│  Protocol Clients (协议客户端 - Outbound)                        │
│  ┌─────────────┬─────────────┬─────────────┐                   │
│  │ ERC-8004    │   Vouch     │   A2A       │                   │
│  │ Client      │   Client    │   Client    │                   │
│  │ (Registry)  │   (Verify)  │   (Call)    │                   │
│  └─────────────┴─────────────┴─────────────┘                   │
├─────────────────────────────────────────────────────────────────┤
│  Data Layer                                                     │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐         │
│  │  SQLite  │ │  IPFS    │ │  Redis   │ │  Chain   │         │
│  │ (Local)  │ │ (Files)  │ │ (Cache)  │ │ (State)  │         │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘         │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 模块职责

| 模块 | 职责 | 输入 | 输出 |
|------|------|------|------|
| **API Gateway** | 协议接入 | HTTP/SSE 请求 | 标准化内部消息 |
| **Protocol Adapters** | 格式转换 | 协议特定格式 | DASN 标准格式 |
| **Task Router** | 任务调度 | 多个来源任务 | 有序任务队列 |
| **DASN Core** | 业务逻辑 | 任务定义 | 执行结果+证明 |
| **Protocol Clients** | 外部交互 | 内部事件 | 链上操作/外部调用 |
| **Data Layer** | 数据持久化 | 应用数据 | 存储+索引 |

### 2.3 数据流设计

#### 场景 1: A2A Client 调用 Worker

```
1. Client A2A Request
   ↓
2. API Gateway (/a2a/tasks)
   ↓
3. A2A Adapter (JSON → DASN Task)
   ↓
4. Task Router (去重/优先级)
   ↓
5. DASN Core (验证+执行)
   ├─ 5.1 检查 Vouch 信任等级
   ├─ 5.2 检查预算/质押
   ├─ 5.3 调用 pi-worker 执行
   └─ 5.4 生成结果证明
   ↓
6. DASN Adapter (DASN Result → A2A Response)
   ↓
7. A2A Response to Client
```

#### 场景 2: Worker 注册到多协议

```
1. Worker Startup
   ↓
2. Register to DASN (主链)
   ├─ 2.1 Create Worker PDA
   ├─ 2.2 Deposit Stake
   └─ 2.3 Publish Capabilities
   ↓
3. Register to Vouch (并行)
   ├─ 3.1 Create Agent Identity
   ├─ 3.2 Deposit USDC Stake
   └─ 3.3 Link DASN Worker
   ↓
4. Register to ERC-8004 (并行)
   ├─ 4.1 Mint ERC-721
   ├─ 4.2 Upload Agent Card
   └─ 4.3 Link DASN/Vouch IDs
   ↓
5. Start A2A/MCP Servers
   ↓
6. Health Check Loop
```

---

## 3. 核心组件设计

### 3.1 配置系统

```typescript
// config.schema.ts
import { z } from 'zod';

export const WorkerConfigSchema = z.object({
  // Worker 基础配置
  worker: z.object({
    name: z.string().min(3).max(50),
    description: z.string().max(500),
    endpoint: z.string().url(),
    specialization: z.array(z.string()).min(1),
    capabilities: z.array(z.object({
      name: z.string(),
      description: z.string(),
      inputSchema: z.any(),
      outputSchema: z.any(),
      pricePerUnit: z.string(), // 字符串避免精度问题
    })),
    maxConcurrentTasks: z.number().int().min(1).max(100).default(5),
    minReward: z.string().default('10000000'), // 0.01 SOL
  }),
  
  // DASN 主链配置 (Solana)
  dasn: z.object({
    chain: z.enum(['solana', 'sui']).default('solana'),
    network: z.enum(['mainnet', 'testnet', 'devnet']).default('devnet'),
    privateKey: z.string(), // 或从环境变量读取
    programId: z.string(),
    stakeAmount: z.string().default('1000000000'), // 1 SOL
  }),
  
  // ERC-8004 配置 (可选)
  erc8004: z.object({
    enabled: z.boolean().default(false),
    network: z.enum(['mainnet', 'sepolia']).default('sepolia'),
    contractAddress: z.string().optional(),
    privateKey: z.string().optional(),
    rpcUrl: z.string().url().optional(),
  }).optional(),
  
  // Vouch 配置 (可选)
  vouch: z.object({
    enabled: z.boolean().default(false),
    programId: z.string().optional(),
    minTier: z.enum(['Observer', 'Basic', 'Standard', 'Verified']).default('Basic'),
    minReputation: z.number().default(500),
    stakeAmount: z.number().default(100), // USDC
  }).optional(),
  
  // A2A 配置
  a2a: z.object({
    enabled: z.boolean().default(true),
    port: z.number().default(3001),
    path: z.string().default('/a2a'),
    agentCardPath: z.string().default('/.well-known/agent-card.json'),
  }),
  
  // MCP 配置
  mcp: z.object({
    enabled: z.boolean().default(true),
    transport: z.enum(['stdio', 'sse']).default('stdio'),
    port: z.number().optional(), // SSE 模式需要
  }),
  
  // 存储配置
  storage: z.object({
    type: z.enum(['sqlite', 'postgres']).default('sqlite'),
    url: z.string().default('sqlite://./data/worker.db'),
  }),
  
  // 外部服务
  external: z.object({
    ipfsGateway: z.string().url().default('https://ipfs.io'),
    rpcFallback: z.array(z.string().url()).optional(),
  }),
});

export type WorkerConfig = z.infer<typeof WorkerConfigSchema>;
```

### 3.2 任务队列系统

```typescript
// task-queue.ts
import { EventEmitter } from 'events';

export interface Task {
  id: string;
  source: 'dasn' | 'a2a' | 'mcp' | 'direct';
  protocol: string; // 'a2a-0.3.0', 'mcp-2025-06-18', 'dasn-1.0'
  type: string;
  prompt: string;
  context?: Record<string, any>;
  attachments?: Attachment[];
  requirements: TaskRequirements;
  budget?: Budget;
  deadline?: Date;
  priority: number; // 0-100
  createdAt: Date;
  
  // 源协议特定数据
  sourceData: {
    a2a?: A2ATaskData;
    mcp?: MCPTaskData;
    dasn?: DASNTaskData;
  };
}

export interface TaskQueue {
  // 队列管理
  enqueue(task: Task): Promise<void>;
  dequeue(): Promise<Task | null>;
  peek(): Promise<Task | null>;
  
  // 状态管理
  updateStatus(taskId: string, status: TaskStatus): Promise<void>;
  getStatus(taskId: string): Promise<TaskStatus>;
  
  // 优先级调整
  bumpPriority(taskId: string, delta: number): Promise<void>;
  
  // 监控
  getQueueDepth(): Promise<number>;
  getMetrics(): Promise<QueueMetrics>;
}

export class RedisTaskQueue extends EventEmitter implements TaskQueue {
  private redis: Redis;
  private processing: Map<string, Task> = new Map();
  
  constructor(redisUrl: string) {
    super();
    this.redis = new Redis(redisUrl);
  }
  
  async enqueue(task: Task): Promise<void> {
    // 1. 序列化任务
    const serialized = JSON.stringify(task);
    
    // 2. 使用 Sorted Set 按优先级存储
    await this.redis.zadd(
      'task:queue',
      task.priority,
      task.id
    );
    
    // 3. 存储完整任务数据
    await this.redis.setex(
      `task:data:${task.id}`,
      86400, // 24小时过期
      serialized
    );
    
    // 4. 触发事件
    this.emit('task:enqueued', task);
  }
  
  async dequeue(): Promise<Task | null> {
    // 1. 获取最高优先级任务
    const result = await this.redis.zpopmax('task:queue', 1);
    if (!result || result.length === 0) return null;
    
    const [taskId, score] = result;
    
    // 2. 获取完整数据
    const data = await this.redis.get(`task:data:${taskId}`);
    if (!data) return null;
    
    const task: Task = JSON.parse(data);
    
    // 3. 标记为处理中
    this.processing.set(taskId, task);
    await this.updateStatus(taskId, 'PROCESSING');
    
    return task;
  }
  
  async updateStatus(taskId: string, status: TaskStatus): Promise<void> {
    await this.redis.setex(
      `task:status:${taskId}`,
      86400,
      status
    );
    this.emit('task:statusChanged', { taskId, status });
  }
}
```

### 3.3 协议路由器

```typescript
// protocol-router.ts
export class ProtocolRouter {
  private adapters: Map<string, ProtocolAdapter> = new Map();
  private transformers: Map<string, ProtocolTransformer> = new Map();
  
  constructor(private core: DASNCore) {}
  
  registerAdapter(protocol: string, adapter: ProtocolAdapter) {
    this.adapters.set(protocol, adapter);
  }
  
  registerTransformer(protocol: string, transformer: ProtocolTransformer) {
    this.transformers.set(protocol, transformer);
  }
  
  // 入口: 任何协议的任务都经过这里
  async routeInbound(request: InboundRequest): Promise<InboundResponse> {
    const { protocol, rawData } = request;
    
    // 1. 获取转换器
    const transformer = this.transformers.get(protocol);
    if (!transformer) {
      throw new Error(`Unknown protocol: ${protocol}`);
    }
    
    // 2. 转换为 DASN 标准格式
    const dasnTask = await transformer.toDASN(rawData);
    
    // 3. 验证
    await this.validateTask(dasnTask);
    
    // 4. 提交到核心
    const dasnResult = await this.core.executeTask(dasnTask);
    
    // 5. 转换回源协议格式
    const response = await transformer.fromDASN(dasnResult);
    
    return response;
  }
  
  // 出口: 调用外部协议
  async routeOutbound(
    targetProtocol: string,
    call: OutboundCall
  ): Promise<OutboundResult> {
    const adapter = this.adapters.get(targetProtocol);
    if (!adapter) {
      throw new Error(`Adapter not found: ${targetProtocol}`);
    }
    
    return await adapter.execute(call);
  }
  
  private async validateTask(task: DASNTask): Promise<void> {
    // 验证 Worker 有能力执行
    const canExecute = this.core.worker.hasCapability(task.type);
    if (!canExecute) {
      throw new Error(`Worker cannot execute task type: ${task.type}`);
    }
    
    // 验证预算足够
    if (task.budget && task.budget.amount < this.core.config.minReward) {
      throw new Error('Budget below minimum');
    }
    
    // 验证 deadline 合理
    if (task.deadline && task.deadline < new Date()) {
      throw new Error('Deadline already passed');
    }
  }
}

interface ProtocolAdapter {
  name: string;
  version: string;
  execute(call: OutboundCall): Promise<OutboundResult>;
}

interface ProtocolTransformer {
  toDASN(rawData: any): Promise<DASNTask>;
  fromDASN(result: DASNResult): Promise<any>;
}
```

### 3.4 声誉聚合器

```typescript
// reputation-aggregator.ts
export class ReputationAggregator {
  private sources: Map<string, ReputationSource> = new Map();
  private weights: Map<string, number> = new Map();
  
  constructor() {
    // 默认权重
    this.weights.set('dasn', 0.5);
    this.weights.set('vouch', 0.3);
    this.weights.set('erc8004', 0.2);
  }
  
  registerSource(name: string, source: ReputationSource, weight?: number) {
    this.sources.set(name, source);
    if (weight !== undefined) {
      this.weights.set(name, weight);
    }
  }
  
  async getAggregateReputation(workerId: string): Promise<AggregateReputation> {
    const scores: Map<string, ReputationScore> = new Map();
    
    // 1. 并行查询所有源
    const promises = Array.from(this.sources.entries()).map(
      async ([name, source]) => {
        try {
          const score = await source.getScore(workerId);
          scores.set(name, score);
        } catch (e) {
          console.warn(`Failed to get reputation from ${name}:`, e);
        }
      }
    );
    
    await Promise.all(promises);
    
    // 2. 计算加权分数
    let totalScore = 0;
    let totalWeight = 0;
    
    for (const [name, score] of scores) {
      const weight = this.weights.get(name) || 0;
      totalScore += score.normalized * weight;
      totalWeight += weight;
    }
    
    const aggregateScore = totalWeight > 0 ? totalScore / totalWeight : 0;
    
    // 3. 计算置信度 (基于数据源数量和质量)
    const confidence = this.calculateConfidence(scores);
    
    return {
      aggregate: {
        score: aggregateScore,
        confidence,
        lastUpdated: new Date(),
      },
      sources: Object.fromEntries(scores),
      metadata: {
        weights: Object.fromEntries(this.weights),
        sourceCount: scores.size,
      },
    };
  }
  
  private calculateConfidence(scores: Map<string, ReputationScore>): number {
    const count = scores.size;
    if (count === 0) return 0;
    if (count >= 3) return 0.9;
    if (count === 2) return 0.7;
    return 0.5;
  }
}

interface ReputationSource {
  name: string;
  getScore(workerId: string): Promise<ReputationScore>;
}

interface ReputationScore {
  raw: number;        // 源协议原始分数
  normalized: number; // 标准化到 0-100
  maxScore: number;   // 该协议最大可能分数
  updatedAt: Date;
  proof?: string;     // 链上证明链接
}
```

---

## 4. 部署架构

### 4.1 本地开发环境

```yaml
# docker-compose.dev.yml
version: '3.8'

services:
  # Worker 应用
  worker:
    build:
      context: .
      dockerfile: Dockerfile.dev
    ports:
      - "3000:3000"  # DASN API
      - "3001:3001"  # A2A API
    volumes:
      - ./src:/app/src
      - ./data:/app/data
      - ./config.yaml:/app/config.yaml
    environment:
      - NODE_ENV=development
      - DASN_PRIVATE_KEY=${DASN_PRIVATE_KEY}
      - REDIS_URL=redis://redis:6379
    depends_on:
      - redis
      - ipfs
    networks:
      - dasn-network

  # Redis 缓存+队列
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    volumes:
      - redis-data:/data
    networks:
      - dasn-network

  # IPFS 节点 (可选)
  ipfs:
    image: ipfs/kubo:latest
    ports:
      - "5001:5001"  # API
      - "8080:8080"  # Gateway
    volumes:
      - ipfs-data:/data/ipfs
    networks:
      - dasn-network

  # 监控
  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9090:9090"
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml
    networks:
      - dasn-network

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3002:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    networks:
      - dasn-network

volumes:
  redis-data:
  ipfs-data:

networks:
  dasn-network:
    driver: bridge
```

### 4.2 生产环境

```yaml
# docker-compose.prod.yml
version: '3.8'

services:
  worker-api:
    build:
      context: .
      dockerfile: Dockerfile
    deploy:
      replicas: 2
      resources:
        limits:
          cpus: '2'
          memory: 4G
    ports:
      - "3000"
    environment:
      - NODE_ENV=production
      - DATABASE_URL=${DATABASE_URL}
      - REDIS_URL=${REDIS_URL}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  worker-executor:
    build:
      context: .
      dockerfile: Dockerfile.executor
    deploy:
      replicas: 3
      resources:
        limits:
          cpus: '4'
          memory: 8G
    environment:
      - NODE_ENV=production
      - API_URL=http://worker-api:3000
    # 执行器需要特权运行 pi-worker
    privileged: true

  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
      - ./ssl:/etc/nginx/ssl
    depends_on:
      - worker-api
```

---

## 5. 实施路线图

### Phase 1: 基础框架 (Week 1)
- [ ] 项目初始化 (TypeScript + Node.js)
- [ ] 配置系统实现
- [ ] DASN Core 基础结构
- [ ] SQLite 数据库层

### Phase 2: 单协议实现 (Week 2)
- [ ] DASN 原生协议完整实现
- [ ] Solana 链交互
- [ ] 基础 Task Queue
- [ ] 本地测试网部署

### Phase 3: 多协议适配 (Week 3)
- [ ] A2A Adapter 实现
- [ ] MCP Adapter 实现
- [ ] Protocol Router 实现
- [ ] 格式转换器

### Phase 4: 外部协议整合 (Week 4)
- [ ] Vouch Protocol 集成
- [ ] ERC-8004 集成 (可选)
- [ ] 声誉聚合器
- [ ] 统一身份管理

### Phase 5: 生产准备 (Week 5-6)
- [ ] Docker 容器化
- [ ] 监控告警
- [ ] 性能优化
- [ ] 文档完善

---

## 6. 风险评估

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|---------|
| 协议标准变更 | 中 | 高 | 适配器模式隔离变化 |
| 链上 Gas 波动 | 高 | 中 | 动态 Gas 估算+重试 |
| Worker 作恶 | 低 | 高 | 质押+声誉+争议机制 |
| 性能瓶颈 | 中 | 中 | 水平扩展+缓存 |
| 依赖库漏洞 | 低 | 高 | 定期安全审计 |

---

*本文档与 DASN 原型实现同步更新*
