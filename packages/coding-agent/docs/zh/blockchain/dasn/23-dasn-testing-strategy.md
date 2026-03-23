# DASN 测试验证策略

> 全面的测试方案：单元测试、集成测试、端到端测试与生产验证

---

## 1. 测试金字塔

```
                    ┌─────────┐
                    │  E2E    │  ← 验证完整用户旅程
                    │  (10%)  │
                   ┌┴─────────┴┐
                   │ Integration│  ← 验证协议交互
                   │   (30%)   │
                  ┌┴───────────┴┐
                  │    Unit      │  ← 验证业务逻辑
                  │    (60%)     │
                  └──────────────┘
```

### 测试目标

| 层级 | 目标 | 覆盖率目标 | 执行频率 |
|------|------|-----------|---------|
| **单元测试** | 验证单个函数/模块 | >80% | 每次提交 |
| **集成测试** | 验证模块间交互 | >70% | 每次 PR |
| **E2E 测试** | 验证完整流程 | 核心路径 100% | 每日构建 |
| **混沌测试** | 验证系统韧性 | 关键场景 | 每周 |

---

## 2. 单元测试设计

### 2.1 测试框架选择

```typescript
// vitest.config.ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      exclude: [
        'node_modules/',
        'tests/',
        '**/*.d.ts',
      ],
      thresholds: {
        statements: 80,
        branches: 75,
        functions: 80,
        lines: 80,
      },
    },
    // 并行执行
    pool: 'threads',
    poolOptions: {
      threads: {
        singleThread: false,
      },
    },
  },
});
```

### 2.2 核心模块测试

#### Task Router 测试

```typescript
// tests/unit/task-router.test.ts
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { TaskRouter } from '../../src/core/task-router';
import { MockDASNCore } from '../mocks/core';

describe('TaskRouter', () => {
  let router: TaskRouter;
  let core: MockDASNCore;
  
  beforeEach(() => {
    core = new MockDASNCore();
    router = new TaskRouter(core);
  });
  
  describe('routeInbound', () => {
    it('should route A2A request to DASN task', async () => {
      // Arrange
      const a2aRequest = {
        protocol: 'a2a',
        rawData: {
          id: 'task-1',
          message: { parts: [{ text: 'Generate React component' }] },
        },
      };
      
      // Act
      const result = await router.routeInbound(a2aRequest);
      
      // Assert
      expect(result).toBeDefined();
      expect(core.executeTask).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'code-generation',
          prompt: 'Generate React component',
        })
      );
    });
    
    it('should reject unknown protocol', async () => {
      await expect(
        router.routeInbound({ protocol: 'unknown', rawData: {} })
      ).rejects.toThrow('Unknown protocol: unknown');
    });
    
    it('should validate task requirements', async () => {
      const invalidTask = {
        protocol: 'a2a',
        rawData: {
          id: 'task-2',
          message: { parts: [{ text: '' }] }, // Empty prompt
        },
      };
      
      await expect(
        router.routeInbound(invalidTask)
      ).rejects.toThrow('Empty prompt');
    });
    
    it('should handle task timeout', async () => {
      vi.useFakeTimers();
      
      core.executeTask.mockImplementation(() => 
        new Promise(resolve => setTimeout(resolve, 60000))
      );
      
      const request = {
        protocol: 'a2a',
        rawData: {
          id: 'task-timeout',
          message: { parts: [{ text: 'Slow task' }] },
          requirements: { timeout: 1000 },
        },
      };
      
      const promise = router.routeInbound(request);
      vi.advanceTimersByTime(2000);
      
      await expect(promise).rejects.toThrow('Task timeout');
      
      vi.useRealTimers();
    });
  });
  
  describe('format conversion', () => {
    const testCases = [
      {
        name: 'A2A to DASN',
        input: { protocol: 'a2a', skill: 'code-review' },
        expected: { type: 'code-review', source: 'a2a' },
      },
      {
        name: 'MCP to DASN',
        input: { protocol: 'mcp', tool: 'lint-code' },
        expected: { type: 'linting', source: 'mcp' },
      },
      {
        name: 'DASN native',
        input: { protocol: 'dasn', type: 'testing' },
        expected: { type: 'testing', source: 'dasn' },
      },
    ];
    
    testCases.forEach(({ name, input, expected }) => {
      it(`should convert ${name}`, async () => {
        const transformer = router.getTransformer(input.protocol);
        const result = await transformer.toDASN(input);
        
        expect(result).toMatchObject(expected);
      });
    });
  });
});
```

#### Reputation Aggregator 测试

```typescript
// tests/unit/reputation-aggregator.test.ts
import { describe, it, expect } from 'vitest';
import { ReputationAggregator } from '../../src/core/reputation';

describe('ReputationAggregator', () => {
  let aggregator: ReputationAggregator;
  
  beforeEach(() => {
    aggregator = new ReputationAggregator();
  });
  
  describe('weight calculation', () => {
    it('should calculate weighted average correctly', async () => {
      // 注册模拟数据源
      aggregator.registerSource('source1', {
        getScore: async () => ({ raw: 80, normalized: 80, maxScore: 100, updatedAt: new Date() }),
      }, 0.5);
      
      aggregator.registerSource('source2', {
        getScore: async () => ({ raw: 90, normalized: 90, maxScore: 100, updatedAt: new Date() }),
      }, 0.5);
      
      const result = await aggregator.getAggregateReputation('worker-1');
      
      // (80 * 0.5) + (90 * 0.5) = 85
      expect(result.aggregate.score).toBe(85);
    });
    
    it('should handle missing sources gracefully', async () => {
      aggregator.registerSource('available', {
        getScore: async () => ({ raw: 70, normalized: 70, maxScore: 100, updatedAt: new Date() }),
      }, 0.5);
      
      aggregator.registerSource('failing', {
        getScore: async () => { throw new Error('Network error'); },
      }, 0.5);
      
      const result = await aggregator.getAggregateReputation('worker-1');
      
      // 应该只使用可用数据源，并调整权重
      expect(result.aggregate.score).toBe(70);
      expect(result.metadata.sourceCount).toBe(1);
    });
    
    it('should normalize different scales', async () => {
      // DASN: 0-100, Vouch: 0-1000, ERC-8004: 0-5
      aggregator.registerSource('dasn', {
        getScore: async () => ({ raw: 80, normalized: 80, maxScore: 100, updatedAt: new Date() }),
      });
      
      aggregator.registerSource('vouch', {
        getScore: async () => ({ raw: 750, normalized: 75, maxScore: 1000, updatedAt: new Date() }),
      });
      
      aggregator.registerSource('erc8004', {
        getScore: async () => ({ raw: 4.5, normalized: 90, maxScore: 5, updatedAt: new Date() }),
      });
      
      const result = await aggregator.getAggregateReputation('worker-1');
      
      // 所有分数应该已经标准化到 0-100
      expect(result.sources.dasn.normalized).toBe(80);
      expect(result.sources.vouch.normalized).toBe(75);
      expect(result.sources.erc8004.normalized).toBe(90);
    });
  });
  
  describe('confidence calculation', () => {
    it('should have low confidence with single source', async () => {
      aggregator.registerSource('only', {
        getScore: async () => ({ raw: 80, normalized: 80, maxScore: 100, updatedAt: new Date() }),
      });
      
      const result = await aggregator.getAggregateReputation('worker-1');
      expect(result.aggregate.confidence).toBe(0.5);
    });
    
    it('should have high confidence with multiple sources', async () => {
      aggregator.registerSource('s1', { getScore: async () => ({ raw: 80, normalized: 80, maxScore: 100, updatedAt: new Date() }) });
      aggregator.registerSource('s2', { getScore: async () => ({ raw: 85, normalized: 85, maxScore: 100, updatedAt: new Date() }) });
      aggregator.registerSource('s3', { getScore: async () => ({ raw: 82, normalized: 82, maxScore: 100, updatedAt: new Date() }) });
      
      const result = await aggregator.getAggregateReputation('worker-1');
      expect(result.aggregate.confidence).toBe(0.9);
    });
  });
});
```

### 2.3 测试辅助工具

```typescript
// tests/helpers/factories.ts
import { faker } from '@faker-js/faker';

export class TaskFactory {
  static create(overrides: Partial<Task> = {}): Task {
    return {
      id: faker.string.uuid(),
      source: 'dasn',
      protocol: 'dasn-1.0',
      type: faker.helpers.arrayElement(['code-generation', 'code-review', 'testing']),
      prompt: faker.lorem.paragraph(),
      context: {},
      requirements: {
        tools: [],
        timeout: 300000,
      },
      priority: faker.number.int({ min: 0, max: 100 }),
      createdAt: new Date(),
      sourceData: {},
      ...overrides,
    };
  }
  
  static createMany(count: number): Task[] {
    return Array.from({ length: count }, () => this.create());
  }
}

export class WorkerFactory {
  static create(overrides: Partial<WorkerConfig> = {}): WorkerConfig {
    return {
      name: faker.person.fullName(),
      description: faker.lorem.sentence(),
      endpoint: faker.internet.url(),
      specialization: faker.helpers.arrayElements(['code', 'test', 'doc'], 2),
      capabilities: [
        {
          name: 'generate-code',
          description: 'Generate code',
          inputSchema: { type: 'object' },
          outputSchema: { type: 'string' },
          pricePerUnit: '1000000',
        },
      ],
      maxConcurrentTasks: 5,
      minReward: '10000000',
      ...overrides,
    };
  }
}

// tests/helpers/matchers.ts
import { expect } from 'vitest';

expect.extend({
  toBeValidTask(received) {
    const valid = received.id && received.type && received.prompt;
    return {
      pass: valid,
      message: () => `expected ${received} to be a valid task`,
    };
  },
  
  toBeWithinRange(received: number, floor: number, ceiling: number) {
    const pass = received >= floor && received <= ceiling;
    return {
      pass,
      message: () =>
        `expected ${received} to be within range ${floor} - ${ceiling}`,
    };
  },
});

declare module 'vitest' {
  interface Assertion<T = any> {
    toBeValidTask(): T;
    toBeWithinRange(floor: number, ceiling: number): T;
  }
}
```

---

## 3. 集成测试设计

### 3.1 测试环境

```yaml
# docker-compose.test.yml
version: '3.8'

services:
  # 测试数据库
  test-db:
    image: postgres:15-alpine
    environment:
      POSTGRES_DB: dasn_test
      POSTGRES_USER: test
      POSTGRES_PASSWORD: test
    ports:
      - "5433:5432"
    tmpfs:
      - /var/lib/postgresql/data

  # 测试 Redis
  test-redis:
    image: redis:7-alpine
    ports:
      - "6380:6379"

  # Solana 本地验证器
  solana-test-validator:
    image: solana-labs/solana:v1.17
    command: >
      solana-test-validator
      --reset
      --quiet
      --rpc-port 8899
    ports:
      - "8899:8899"

  # 测试 Runner
  test-runner:
    build:
      context: .
      dockerfile: Dockerfile.test
    environment:
      - NODE_ENV=test
      - DATABASE_URL=postgresql://test:test@test-db:5432/dasn_test
      - REDIS_URL=redis://test-redis:6379
      - SOLANA_RPC_URL=http://solana-test-validator:8899
    depends_on:
      - test-db
      - test-redis
      - solana-test-validator
    volumes:
      - ./coverage:/app/coverage
```

### 3.2 协议集成测试

```typescript
// tests/integration/protocol-integration.test.ts
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { TestEnvironment } from '../helpers/test-env';
import { DASNWorker } from '../../src/worker';

describe('Protocol Integration', () => {
  let env: TestEnvironment;
  let worker: DASNWorker;
  
  beforeAll(async () => {
    env = await TestEnvironment.create({
      chains: ['solana'],
      protocols: ['a2a', 'mcp', 'vouch'],
    });
    
    worker = await env.createWorker({
      name: 'test-worker',
      specialization: ['code-generation'],
    });
    
    await worker.start();
  }, 120000);
  
  afterAll(async () => {
    await worker.stop();
    await env.destroy();
  });
  
  describe('Vouch Protocol Integration', () => {
    it('should register worker to Vouch', async () => {
      const vouchClient = env.getVouchClient();
      
      const result = await vouchClient.registerAgent({
        name: worker.config.name,
        owner: worker.address,
      });
      
      expect(result.tx).toBeDefined();
      
      // 验证链上状态
      const agent = await vouchClient.getAgentByOwner(worker.address);
      expect(agent.status).toBe('Active');
      expect(agent.name).toBe(worker.config.name);
    });
    
    it('should verify trust level before task', async () => {
      // Worker 尝试认领高价值任务
      const highValueTask = await env.createTask({
        budget: '1000000000', // 1000 USDC
      });
      
      // Worker 只有 Basic tier (需要 Standard)
      await expect(
        worker.claimTask(highValueTask.id)
      ).rejects.toThrow('Insufficient trust tier');
      
      // Worker 质押更多提升到 Standard
      await env.vouchStake(worker.address, 500); // 500 USDC
      
      // 现在可以认领
      const result = await worker.claimTask(highValueTask.id);
      expect(result.success).toBe(true);
    });
    
    it('should report behavior after task completion', async () => {
      const task = await env.createTask({ budget: '100000000' });
      
      await worker.claimTask(task.id);
      await worker.submitResult(task.id, 'output');
      await env.acceptTask(task.id);
      
      // 验证 Vouch 声誉更新
      const reputation = await env.getVouchReputation(worker.address);
      expect(reputation.score).toBeGreaterThan(500); // 默认 500
    });
  });
  
  describe('A2A Protocol Integration', () => {
    it('should serve Agent Card', async () => {
      const response = await fetch(
        `${worker.endpoint}/.well-known/agent-card.json`
      );
      
      expect(response.status).toBe(200);
      
      const card = await response.json();
      expect(card.name).toBe(worker.config.name);
      expect(card.capabilities.streaming).toBe(true);
      expect(card.extensions?.dasn).toBeDefined();
    });
    
    it('should handle A2A task end-to-end', async () => {
      const a2aClient = env.getA2AClient();
      
      const result = await a2aClient.sendTask(worker.endpoint, {
        id: 'test-task-a2a-1',
        message: {
          parts: [{ text: 'Generate a function to calculate fibonacci' }],
        },
        skill: 'code-generation',
      });
      
      expect(result.status.state).toBe('completed');
      expect(result.artifacts).toHaveLength(1);
      expect(result.artifacts[0].parts[0].text).toContain('fibonacci');
    });
    
    it('should stream progress for long tasks', async () => {
      const a2aClient = env.getA2AClient();
      const updates: any[] = [];
      
      for await (const update of a2aClient.streamTask(worker.endpoint, {
        id: 'stream-task-1',
        message: { parts: [{ text: 'Complex task' }] },
      })) {
        updates.push(update);
      }
      
      expect(updates.length).toBeGreaterThan(1);
      expect(updates[updates.length - 1].status.state).toBe('completed');
    });
  });
  
  describe('Multi-Protocol Coexistence', () => {
    it('should accept tasks from multiple protocols simultaneously', async () => {
      // 同时从 A2A 和 MCP 发送任务
      const [a2aResult, mcpResult] = await Promise.all([
        env.a2aClient.sendTask(worker.endpoint, {
          id: 'multi-1',
          message: { parts: [{ text: 'A2A task' }] },
        }),
        env.mcpClient.callTool(worker.mcpEndpoint, 'generate-code', {
          prompt: 'MCP task',
        }),
      ]);
      
      expect(a2aResult.status.state).toBe('completed');
      expect(mcpResult.isError).toBe(false);
    });
    
    it('should maintain consistent identity across protocols', async () => {
      // 从 A2A Agent Card 获取 DID
      const card = await env.a2aClient.getAgentCard(worker.endpoint);
      const a2aDid = card.extensions?.dasn?.did;
      
      // 从 Vouch 获取 DID
      const vouchAgent = await env.vouchClient.getAgentByOwner(worker.address);
      const vouchDid = vouchAgent.did;
      
      // 从 ERC-8004 获取 (如果启用)
      if (env.erc8004Enabled) {
        const erc8004Agent = await env.erc8004Client.getAgent(worker.erc8004Id);
        expect(erc8004Agent.did).toBeOneOf([a2aDid, vouchDid]);
      }
      
      // DIDs 应该一致
      expect(a2aDid).toBe(vouchDid);
    });
  });
});
```

### 3.3 区块链交互测试

```typescript
// tests/integration/chain-interaction.test.ts
import { describe, it, expect } from 'vitest';
import { Connection, Keypair, PublicKey } from '@solana/web3.js';
import { AnchorProvider, Program } from '@coral-xyz/anchor';

describe('Solana Chain Integration', () => {
  let connection: Connection;
  let provider: AnchorProvider;
  let program: Program<DasnIdl>;
  
  beforeAll(async () => {
    connection = new Connection('http://localhost:8899', 'confirmed');
    const wallet = Keypair.generate();
    
    // 请求空投
    await connection.requestAirdrop(wallet.publicKey, 10 * 1e9);
    
    provider = new AnchorProvider(connection, new Wallet(wallet), {});
    program = new Program(idl, programId, provider);
  });
  
  it('should register worker on-chain', async () => {
    const workerKeypair = Keypair.generate();
    
    await program.methods
      .registerWorker('test-worker', ['code'])
      .accounts({
        worker: workerKeypair.publicKey,
        owner: provider.wallet.publicKey,
      })
      .signers([workerKeypair])
      .rpc();
    
    // 验证账户创建
    const account = await program.account.worker.fetch(
      workerKeypair.publicKey
    );
    
    expect(account.name).toBe('test-worker');
    expect(account.status).toEqual({ active: {} });
  });
  
  it('should handle task lifecycle', async () => {
    // 1. 创建任务
    const taskKeypair = Keypair.generate();
    await program.methods
      .createTask('Generate code', new BN(1000000))
      .accounts({
        task: taskKeypair.publicKey,
        creator: provider.wallet.publicKey,
      })
      .signers([taskKeypair])
      .rpc();
    
    // 2. Worker 认领
    const worker = await createTestWorker();
    await program.methods
      .claimTask()
      .accounts({
        task: taskKeypair.publicKey,
        worker: worker.publicKey,
      })
      .rpc();
    
    let task = await program.account.task.fetch(taskKeypair.publicKey);
    expect(task.status).toEqual({ claimed: {} });
    
    // 3. 提交结果
    await program.methods
      .submitResult('const x = 1;')
      .accounts({
        task: taskKeypair.publicKey,
        worker: worker.publicKey,
      })
      .rpc();
    
    task = await program.account.task.fetch(taskKeypair.publicKey);
    expect(task.status).toEqual({ submitted: {} });
    expect(task.result).toBe('const x = 1;');
  });
  
  it('should handle payment settlement', async () => {
    const creatorBalanceBefore = await connection.getBalance(creator.publicKey);
    const workerBalanceBefore = await connection.getBalance(worker.publicKey);
    
    // 创建并完成任务
    const task = await createAndCompleteTask({ budget: 1e9 });
    
    // 结算
    await program.methods
      .settlePayment()
      .accounts({
        task: task.publicKey,
        creator: creator.publicKey,
        worker: worker.publicKey,
      })
      .rpc();
    
    // 验证余额变化
    const creatorBalanceAfter = await connection.getBalance(creator.publicKey);
    const workerBalanceAfter = await connection.getBalance(worker.publicKey);
    
    expect(workerBalanceAfter).toBeGreaterThan(workerBalanceBefore);
    expect(creatorBalanceAfter).toBeLessThan(creatorBalanceBefore);
  });
});
```

---

## 4. 端到端 (E2E) 测试

### 4.1 场景测试

```typescript
// tests/e2e/scenarios.test.ts
import { describe, it, expect, beforeAll } from 'vitest';
import { E2EEnvironment } from '../helpers/e2e-env';

describe('E2E Scenarios', () => {
  let env: E2EEnvironment;
  
  beforeAll(async () => {
    env = await E2EEnvironment.create();
    await env.deployContracts();
    await env.startWorkers(3); // 启动 3 个 Worker
  }, 300000);
  
  describe('Scenario 1: Client posts task → Worker executes → Client accepts', () => {
    it('should complete full happy path', async () => {
      // 1. Client 发布任务
      const client = env.createClient();
      const task = await client.createTask({
        type: 'code-generation',
        prompt: 'Generate a React button component',
        budget: '100000000', // 0.1 SOL
      });
      
      // 2. 等待 Worker 认领 (最长 30 秒)
      const claimedTask = await env.waitForTaskClaimed(task.id, 30000);
      expect(claimedTask.worker).toBeDefined();
      
      // 3. 等待执行完成
      const completedTask = await env.waitForTaskCompleted(task.id, 60000);
      expect(completedTask.result).toContain('button');
      
      // 4. Client 验收
      await client.acceptResult(task.id);
      
      // 5. 验证支付
      const settlement = await env.getSettlement(task.id);
      expect(settlement.status).toBe('completed');
      expect(settlement.workerReward).toBeGreaterThan(0);
    });
  });
  
  describe('Scenario 2: Dispute resolution flow', () => {
    it('should handle dispute end-to-end', async () => {
      const client = env.createClient();
      const worker = env.getWorker(0);
      
      // 1. 创建任务
      const task = await client.createTask({
        type: 'code-review',
        prompt: 'Review this code',
        budget: '500000000',
      });
      
      // 2. Worker 完成但 Client 不满意
      await worker.claimAndComplete(task.id, 'LGTM'); // 敷衍的结果
      
      // 3. Client 发起争议
      await client.openDispute(task.id, 'Review is too brief');
      
      // 4. Reviewer 投票
      const reviewers = await env.getReviewers(5);
      await Promise.all(
        reviewers.map(r => r.vote(task.id, 'support_client'))
      );
      
      // 5. 等待争议解决
      const resolvedTask = await env.waitForDisputeResolved(task.id, 120000);
      
      // 6. 验证结果 (Client 胜诉，退款)
      expect(resolvedTask.dispute.winner).toBe('client');
      expect(resolvedTask.settlement.refundAmount).toBe(task.budget);
    });
  });
  
  describe('Scenario 3: Worker reputation growth', () => {
    it('should build reputation over multiple tasks', async () => {
      const worker = env.getWorker(0);
      
      // 初始声誉
      const initialRep = await worker.getReputation();
      expect(initialRep.score).toBe(500); // 默认
      
      // 完成 10 个任务
      for (let i = 0; i < 10; i++) {
        const client = env.createClient();
        const task = await client.createTask({
          type: 'code-generation',
          budget: '100000000',
        });
        
        await worker.claimAndComplete(task.id, 'function test() {}');
        await client.acceptResult(task.id);
      }
      
      // 验证声誉提升
      const finalRep = await worker.getReputation();
      expect(finalRep.score).toBeGreaterThan(initialRep.score);
      expect(finalRep.completedTasks).toBe(10);
    });
  });
  
  describe('Scenario 4: Multi-protocol client', () => {
    it('should serve clients using different protocols', async () => {
      const worker = env.getWorker(0);
      
      // DASN 原生 Client
      const dasnClient = env.createDASNClient();
      const dasnTask = await dasnClient.createTask({ prompt: 'DASN task' });
      
      // A2A Client
      const a2aClient = env.createA2AClient();
      const a2aTask = await a2aClient.sendTask(worker.a2aEndpoint, {
        message: { parts: [{ text: 'A2A task' }] },
      });
      
      // MCP Client
      const mcpClient = env.createMCPClient();
      const mcpResult = await mcpClient.callTool(worker.mcpEndpoint, 'generate-code', {
        prompt: 'MCP task',
      });
      
      // 所有任务都应该成功
      await expect(env.waitForTaskCompleted(dasnTask.id)).resolves.toBeDefined();
      expect(a2aTask.status.state).toBe('completed');
      expect(mcpResult.isError).toBe(false);
    });
  });
});
```

### 4.2 性能测试

```typescript
// tests/e2e/performance.test.ts
import { describe, it, expect } from 'vitest';
import { loadTest } from '../helpers/load-testing';

describe('Performance Tests', () => {
  it('should handle 100 concurrent tasks', async () => {
    const results = await loadTest({
      concurrentTasks: 100,
      duration: 60,
      workers: 5,
    });
    
    expect(results.successRate).toBeGreaterThan(0.95);
    expect(results.avgLatency).toBeLessThan(5000); // 5秒
    expect(results.p99Latency).toBeLessThan(15000); // 15秒
  });
  
  it('should maintain throughput under load', async () => {
    const metrics = await loadTest({
      rps: 10, // 每秒 10 个请求
      duration: 120,
    });
    
    expect(metrics.actualRps).toBeGreaterThan(8); // 至少达到 80%
    expect(metrics.errorRate).toBeLessThan(0.05);
  });
  
  it('should recover from worker failure', async () => {
    // 杀死一个 Worker
    await env.killWorker(0);
    
    // 任务应该被其他 Worker 接手
    const task = await env.createTask();
    const completed = await env.waitForTaskCompleted(task.id, 30000);
    
    expect(completed.worker).not.toBe(env.getWorker(0).address);
  });
});
```

---

## 5. 测试自动化

### 5.1 CI/CD 集成

```yaml
# .github/workflows/test.yml
name: Test Suite

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  unit-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - uses: actions/setup-node@v3
        with:
          node-version: '18'
          cache: 'npm'
      
      - run: npm ci
      
      - run: npm run test:unit -- --coverage
      
      - uses: codecov/codecov-action@v3
        with:
          files: ./coverage/lcov.info

  integration-test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:15
        env:
          POSTGRES_PASSWORD: postgres
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
        ports:
          - 5432:5432
      redis:
        image: redis:7
        ports:
          - 6379:6379
    steps:
      - uses: actions/checkout@v3
      
      - run: npm ci
      
      - run: npm run test:integration
        env:
          DATABASE_URL: postgresql://postgres:postgres@localhost:5432/test
          REDIS_URL: redis://localhost:6379

  e2e-test:
    runs-on: ubuntu-latest
    needs: [unit-test, integration-test]
    steps:
      - uses: actions/checkout@v3
      
      - run: docker-compose -f docker-compose.test.yml up --abort-on-container-exit
      
      - run: npm run test:e2e
```

### 5.2 测试报告

```typescript
// scripts/generate-test-report.ts
import { generateReport } from 'vitest/reporters';

async function generateReport() {
  const report = await generateReport({
    outputFile: './test-results/report.html',
    include: [
      'unit',
      'integration',
      'e2e',
    ],
    metrics: {
      coverage: true,
      performance: true,
      flakiness: true,
    },
  });
  
  // 发送通知
  if (report.summary.failed > 0) {
    await sendSlackNotification({
      channel: '#alerts',
      text: `⚠️ ${report.summary.failed} tests failed`,
      attachments: [{
        color: 'danger',
        fields: [
          { title: 'Total', value: report.summary.total, short: true },
          { title: 'Passed', value: report.summary.passed, short: true },
          { title: 'Failed', value: report.summary.failed, short: true },
          { title: 'Coverage', value: `${report.coverage.lines}%`, short: true },
        ],
      }],
    });
  }
}
```

---

## 6. 生产验证

### 6.1 金丝雀发布

```typescript
// scripts/canary-deploy.ts
async function canaryDeploy() {
  // 1. 部署 1 个 Worker 到新版本
  const canaryWorker = await deployWorker({
    version: '2.0.0-canary',
    replicas: 1,
    label: 'canary',
  });
  
  // 2. 路由 5% 流量到新版本
  await setTrafficSplit({
    stable: 0.95,
    canary: 0.05,
  });
  
  // 3. 监控 30 分钟
  const metrics = await monitorCanary({
    duration: 30 * 60 * 1000,
    thresholds: {
      errorRate: 0.01,
      latencyP99: 5000,
      successRate: 0.99,
    },
  });
  
  // 4. 决策
  if (metrics.healthy) {
    // 逐步增加流量
    await gradualRollout({
      steps: [0.25, 0.5, 0.75, 1.0],
      interval: 10 * 60 * 1000, // 10 分钟
    });
  } else {
    // 回滚
    await rollback();
    throw new Error('Canary failed');
  }
}
```

### 6.2 持续监控

```yaml
# monitoring/alerts.yml
alerts:
  - name: high_error_rate
    condition: error_rate > 0.05
    duration: 5m
    severity: critical
    
  - name: low_task_completion_rate
    condition: completion_rate < 0.8
    duration: 10m
    severity: warning
    
  - name: worker_offline
    condition: worker_heartbeat > 5m
    severity: warning
    
  - name: dispute_spike
    condition: dispute_rate > 0.1
    duration: 1h
    severity: critical
```

---

*本文档与 DASN 测试策略同步更新*
