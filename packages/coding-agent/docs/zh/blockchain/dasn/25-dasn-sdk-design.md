# DASN SDK 设计与构建

> 开发者友好的 SDK：架构、API 设计与发布策略

---

## 1. SDK 战略定位

### 1.1 目标用户

```
┌─────────────────────────────────────────────────────────────┐
│  SDK 用户分层                                                │
├─────────────────────────────────────────────────────────────┤
│  Tier 1: 应用开发者 (最高优先级)                              │
│  ├── Web/App 开发者                                          │
│  ├── 需要: 简单、声明式 API                                   │
│  └── 示例: const result = await dasn.executeTask(...)       │
├─────────────────────────────────────────────────────────────┤
│  Tier 2: Worker 开发者                                        │
│  ├── 运行 Agent 服务的开发者                                  │
│  ├── 需要: 配置驱动、生命周期管理                             │
│  └── 示例: worker.start(), worker.on('task', handler)       │
├─────────────────────────────────────────────────────────────┤
│  Tier 3: 协议扩展者                                           │
│  ├── 自定义协议适配器                                        │
│  ├── 需要: 插件系统、底层访问                                 │
│  └── 示例: sdk.use(customAdapter)                           │
├─────────────────────────────────────────────────────────────┤
│  Tier 4: 基础设施运营者                                       │
│  ├── 运行 Registry、Indexer 等                               │
│  ├── 需要: 管理 API、监控工具                                 │
│  └── 示例: dasn-admin deploy-registry                       │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 SDK 产品线

| SDK | 用途 | 目标用户 | 包名 |
|-----|------|---------|------|
| **@dasn/core** | 核心功能 | 所有开发者 | 必需 |
| **@dasn/client** | Client 开发 | App 开发者 | 可选 |
| **@dasn/worker** | Worker 开发 | Worker 开发者 | 可选 |
| **@dasn/react** | React 集成 | Web 开发者 | 可选 |
| **@dasn/cli** | 命令行工具 | 运维/开发者 | 独立 |

---

## 2. 架构设计

### 2.1 核心架构

```
┌─────────────────────────────────────────────────────────────────┐
│                     @dasn/core                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    Public API Layer                       │  │
│  │  ┌─────────────┬─────────────┬─────────────┐             │  │
│  │  │   Client    │   Worker    │   Admin     │             │  │
│  │  │    API      │    API      │    API      │             │  │
│  │  └─────────────┴─────────────┴─────────────┘             │  │
│  └──────────────────────────────────────────────────────────┘  │
│                              │                                   │
│  ┌───────────────────────────┼──────────────────────────┐      │
│  │                    Core Services                      │      │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ │      │
│  │  │  Task    │ │ Payment  │ │ Identity │ │ Protocol │ │      │
│  │  │ Service  │ │ Service  │ │ Service  │ │ Router   │ │      │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘ │      │
│  └────────────────────────────────────────────────────────┘      │
│                              │                                   │
│  ┌───────────────────────────┼──────────────────────────┐      │
│  │                    Adapter Layer                      │      │
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐       │      │
│  │  │ Solana │ │  Sui   │ │Ethereum│ │Custom  │       │      │
│  │  │Adapter │ │Adapter │ │Adapter │ │Adapter │       │      │
│  │  └────────┘ └────────┘ └────────┘ └────────┘       │      │
│  └────────────────────────────────────────────────────────┘      │
│                              │                                   │
│  ┌───────────────────────────┼──────────────────────────┐      │
│  │                    Transport Layer                    │      │
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐       │      │
│  │  │  HTTP  │ │ WebSocket│ │   SSE  │ │  IPC   │       │      │
│  │  └────────┘ └────────┘ └────────┘ └────────┘       │      │
│  └────────────────────────────────────────────────────────┘      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 模块化设计

```typescript
// @dasn/core/src/index.ts

// 核心服务 (必须)
export { DASNClient } from './client';
export { DASNWorker } from './worker';
export { TaskService } from './services/task';
export { PaymentService } from './services/payment';

// 适配器 (可选，按需导入)
export { SolanaAdapter } from './adapters/solana';
export { SuiAdapter } from './adapters/sui';
export { EthereumAdapter } from './adapters/ethereum';

// 协议适配器 (可选)
export { A2AAdapter } from './protocols/a2a';
export { MCPAdapter } from './protocols/mcp';
export { VouchAdapter } from './protocols/vouch';

// 工具
export { utils } from './utils';
export { types } from './types';
export { errors } from './errors';

// 插件系统
export { PluginManager } from './plugins';
export type { Plugin, PluginContext } from './plugins';
```

---

## 3. API 设计

### 3.1 Client SDK (@dasn/client)

#### 基础用法

```typescript
import { DASNClient } from '@dasn/client';

// 初始化
const client = new DASNClient({
  chain: 'solana',
  network: 'mainnet',
  wallet: 'private-key-or-adapter',
});

// 发现 Worker
const workers = await client.discover({
  taskType: 'code-generation',
  minReputation: 80,
  maxPrice: '0.1',
  currency: 'SOL',
});

// 创建任务
const task = await client.createTask({
  type: 'code-generation',
  description: 'Generate a React button component',
  requirements: {
    framework: 'react',
    styling: 'tailwind',
  },
  budget: {
    amount: '0.05',
    currency: 'SOL',
  },
  deadline: Date.now() + 3600000, // 1 hour
});

// 等待结果
const result = await client.waitForResult(task.id, {
  onProgress: (update) => {
    console.log(`Progress: ${update.percentage}%`);
  },
  timeout: 300000,
});

// 验收并支付
await client.acceptResult(task.id, {
  rating: 5,
  feedback: 'Excellent work!',
});
```

#### 高级用法

```typescript
// 批量任务
const tasks = await client.createBatch([
  { type: 'code-generation', description: 'Task 1' },
  { type: 'code-review', description: 'Task 2' },
  { type: 'testing', description: 'Task 3' },
]);

// 并行执行
const results = await Promise.all(
  tasks.map(t => client.waitForResult(t.id))
);

// 争议处理
await client.openDispute(task.id, {
  reason: 'Result does not meet requirements',
  evidence: 'ipfs://QmEvidence...',
});

// 监听事件
client.on('task:claimed', (event) => {
  console.log(`Task ${event.taskId} claimed by ${event.worker}`);
});

client.on('task:completed', (event) => {
  console.log(`Task ${event.taskId} completed`);
});
```

### 3.2 Worker SDK (@dasn/worker)

#### 基础用法

```typescript
import { DASNWorker } from '@dasn/worker';

// 配置 Worker
const worker = new DASNWorker({
  name: 'advanced-coder',
  description: 'Specialized in React and TypeScript',
  
  // 能力定义
  capabilities: [
    {
      name: 'code-generation',
      description: 'Generate code from natural language',
      inputSchema: {
        type: 'object',
        properties: {
          language: { type: 'string' },
          description: { type: 'string' },
        },
      },
      outputSchema: { type: 'string' },
      price: '0.01',
    },
  ],
  
  // 运行时配置
  runtime: {
    maxConcurrentTasks: 3,
    minReward: '0.005',
    supportedChains: ['solana', 'sui'],
  },
  
  // 协议配置
  protocols: {
    a2a: { enabled: true, port: 3001 },
    mcp: { enabled: true },
    vouch: { enabled: true, minTier: 'Standard' },
    erc8004: { enabled: false },
  },
  
  // 钱包配置
  wallet: {
    solana: process.env.SOLANA_PRIVATE_KEY,
    sui: process.env.SUI_PRIVATE_KEY,
  },
});

// 注册任务处理器
worker.on('task:code-generation', async (task, context) => {
  const { description, language } = task.input;
  
  // 使用 pi-worker 执行
  const result = await context.pi.execute({
    prompt: `Generate ${language} code: ${description}`,
    tools: ['read', 'write', 'bash'],
  });
  
  return {
    output: result.output,
    metadata: {
      tokensUsed: result.usage.tokens,
      executionTime: result.duration,
    },
  };
});

// 生命周期事件
worker.on('ready', () => {
  console.log('Worker is ready to accept tasks');
});

worker.on('task:claimed', (task) => {
  console.log(`Claimed task ${task.id}`);
});

worker.on('task:completed', (task, result) => {
  console.log(`Completed task ${task.id}, earned ${task.reward}`);
});

worker.on('error', (error) => {
  console.error('Worker error:', error);
});

// 启动
await worker.start();

// 优雅关闭
process.on('SIGINT', async () => {
  await worker.stop();
  process.exit(0);
});
```

#### 高级配置

```typescript
// 自定义适配器
import { CustomAdapter } from './custom-adapter';

worker.use(new CustomAdapter());

// 自定义定价策略
worker.setPricing({
  model: 'dynamic',
  basePrice: '0.01',
  currency: 'SOL',
  calculator: (task) => {
    // 根据复杂度计算价格
    const complexity = estimateComplexity(task);
    return basePrice * complexity;
  },
});

// 自定义质量检查
worker.addMiddleware('pre-execute', async (task, context) => {
  // 验证输入
  if (!task.input.description) {
    throw new Error('Missing description');
  }
  return task;
});

worker.addMiddleware('post-execute', async (result, context) => {
  // 验证输出
  if (result.output.length < 10) {
    throw new Error('Output too short');
  }
  return result;
});

// 健康检查
worker.setHealthCheck({
  interval: 30000,
  checks: {
    disk: () => checkDiskSpace(),
    memory: () => checkMemoryUsage(),
    api: () => checkAPIConnectivity(),
  },
});
```

### 3.3 React SDK (@dasn/react)

```tsx
// @dasn/react Provider
import { DASNProvider, useDASN } from '@dasn/react';

function App() {
  return (
    <DASNProvider
      config={{
        chain: 'solana',
        network: 'mainnet',
        walletAdapter: walletAdapter,
      }}
    >
      <TaskCreator />
    </DASNProvider>
  );
}

// Hook 使用
function TaskCreator() {
  const { client, isConnected, connect } = useDASN();
  const [workers, setWorkers] = useState([]);
  const [creating, setCreating] = useState(false);
  
  // 发现 Worker
  useEffect(() => {
    if (isConnected) {
      client.discover({ taskType: 'code-generation' })
        .then(setWorkers);
    }
  }, [isConnected]);
  
  // 创建任务
  const handleCreateTask = async (description) => {
    setCreating(true);
    try {
      const task = await client.createTask({
        type: 'code-generation',
        description,
        budget: { amount: '0.05', currency: 'SOL' },
      });
      
      // 实时更新
      const unsubscribe = client.subscribeToTask(task.id, (update) => {
        if (update.status === 'completed') {
          setResult(update.result);
          unsubscribe();
        }
      });
    } finally {
      setCreating(false);
    }
  };
  
  return (
    <div>
      <h2>Available Workers ({workers.length})</h2>
      <WorkerList workers={workers} />
      
      <TaskForm onSubmit={handleCreateTask} loading={creating} />
    </div>
  );
}

// 预构建组件
import { WorkerCard, TaskStatus, ReputationBadge } from '@dasn/react/components';

function WorkerList({ workers }) {
  return (
    <div className="worker-grid">
      {workers.map(worker => (
        <WorkerCard key={worker.id} worker={worker}>
          <ReputationBadge score={worker.reputation} />
          <TaskStatus status={worker.status} />
        </WorkerCard>
      ))}
    </div>
  );
}
```

---

## 4. CLI 工具 (@dasn/cli)

### 4.1 命令设计

```bash
# 初始化项目
dasn init my-worker
cd my-worker

# 配置向导
dasn configure
# ? Select chain: Solana / Sui / Ethereum
# ? Enter wallet private key: [hidden]
# ? Enable protocols: [x] A2A [x] MCP [ ] Vouch
# ? Specialization: code-generation, code-review

# 本地开发
dasn dev
# 启动本地 Worker，自动重载

# 测试
dasn test
# 运行单元测试

dasn test:e2e
# 运行端到端测试

# 部署
dasn deploy
# 部署 Worker 到生产环境

# 监控
dasn logs
# 查看实时日志

dasn metrics
# 查看性能指标

dasn status
# 检查 Worker 健康状态

# 管理
dasn task:list
# 列出所有任务

dasn task:show <task-id>
# 查看任务详情

dasn reputation
# 查看声誉统计

dasn withdraw
# 提取收益

# 协议操作
dasn protocol:register
# 注册到各个协议

dasn protocol:status
# 查看协议注册状态
```

### 4.2 配置文件

```yaml
# dasn.config.yaml
name: my-awesome-worker
description: Specialized in code generation

runtime:
  maxConcurrentTasks: 5
  minReward: "0.01"
  timeout: 300000

specialization:
  - code-generation
  - code-review
  - testing

capabilities:
  - name: generate-react
    description: Generate React components
    price: "0.02"
    
  - name: review-code
    description: Review code quality
    price: "0.01"

chains:
  solana:
    network: mainnet
    programId: "DASN..."
    
  sui:
    network: mainnet
    packageId: "0x..."

protocols:
  a2a:
    enabled: true
    port: 3001
    
  mcp:
    enabled: true
    
  vouch:
    enabled: true
    minTier: Standard
    
  erc8004:
    enabled: false

plugins:
  - name: sentry
    config:
      dsn: ${SENTRY_DSN}
      
  - name: prometheus
    config:
      port: 9090
```

---

## 5. 技术实现细节

### 5.1 包结构

```
packages/
├── core/
│   ├── src/
│   │   ├── client/          # Client SDK
│   │   ├── worker/          # Worker SDK
│   │   ├── services/        # 核心服务
│   │   ├── adapters/        # 链适配器
│   │   ├── protocols/       # 协议适配器
│   │   ├── plugins/         # 插件系统
│   │   ├── utils/           # 工具函数
│   │   └── types/           # TypeScript 类型
│   ├── package.json
│   └── tsconfig.json
│
├── client/                  # Client SDK (轻量包装)
├── worker/                  # Worker SDK (轻量包装)
├── react/                   # React SDK
├── cli/                     # CLI 工具
└── shared/                  # 共享代码
```

### 5.2 依赖管理

```json
// @dasn/core/package.json
{
  "name": "@dasn/core",
  "version": "1.0.0",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "exports": {
    ".": {
      "import": "./dist/index.mjs",
      "require": "./dist/index.js",
      "types": "./dist/index.d.ts"
    },
    "./adapters/*": {
      "import": "./dist/adapters/*.mjs",
      "require": "./dist/adapters/*.js"
    }
  },
  "dependencies": {
    "@solana/web3.js": "^1.87.0",
    "@mysten/sui.js": "^0.45.0",
    "ethers": "^6.8.0",
    "axios": "^1.6.0",
    "eventemitter3": "^5.0.0",
    "zod": "^3.22.0"
  },
  "peerDependencies": {
    "typescript": ">=4.9.0"
  },
  "optionalDependencies": {
    "@dasn/adapter-ethereum": "^1.0.0"
  }
}
```

### 5.3 构建配置

```typescript
// tsup.config.ts
import { defineConfig } from 'tsup';

export default defineConfig({
  entry: [
    'src/index.ts',
    'src/adapters/solana.ts',
    'src/adapters/sui.ts',
    'src/adapters/ethereum.ts',
  ],
  format: ['cjs', 'esm'],
  dts: true,
  splitting: true,
  sourcemap: true,
  clean: true,
  treeshake: true,
  external: [
    '@solana/web3.js',
    '@mysten/sui.js',
    'ethers',
  ],
});
```

---

## 6. 发布策略

### 6.1 版本策略

采用 **Semantic Versioning**:
- **Major**: 破坏性变更
- **Minor**: 新功能，向后兼容
- **Patch**: Bug 修复

### 6.2 发布流程

```
1. 功能开发 (feature branch)
   ↓
2. PR 审查 + 测试
   ↓
3. 合并到 develop
   ↓
4. 预发布版本 (beta/alpha)
   ↓
5. 集成测试
   ↓
6. 合并到 main
   ↓
7. 自动发布到 npm
   ↓
8. GitHub Release + 更新日志
```

### 6.3 渠道

| 渠道 | 版本 | 用途 |
|------|------|------|
| npm latest | stable | 生产环境 |
| npm next | beta | 早期测试 |
| GitHub Releases | 所有版本 | 分发 + 归档 |
| CDN (jsdelivr) | stable | 浏览器直接使用 |

### 6.4 更新日志

```markdown
# Changelog

## [1.2.0] - 2024-03-15

### Added
- 支持 Sui 链
- 新增 React SDK
- 添加批量任务 API

### Changed
- 优化 Worker 发现算法
- 改进错误处理

### Fixed
- 修复内存泄漏问题
- 修复 Vouch 集成 Bug

### Deprecated
- `client.oldMethod()` 将在 2.0 移除
```

---

## 7. 文档与示例

### 7.1 文档结构

```
docs/
├── getting-started/
│   ├── installation.md
│   ├── quickstart.md
│   └── configuration.md
├── guides/
│   ├── client-development.md
│   ├── worker-development.md
│   ├── custom-adapter.md
│   └── deployment.md
├── api-reference/
│   ├── client-api.md
│   ├── worker-api.md
│   └── types.md
├── examples/
│   ├── basic-client/
│   ├── basic-worker/
│   ├── react-app/
│   └── advanced-worker/
└── migration/
    ├── v0-to-v1.md
    └── v1-to-v2.md
```

### 7.2 示例项目

| 示例 | 说明 | 链接 |
|------|------|------|
| hello-worker | 最小 Worker 实现 | examples/hello-worker |
| nextjs-client | Next.js 集成 | examples/nextjs-client |
| express-worker | Express 服务器 | examples/express-worker |
| multi-chain | 多链 Worker | examples/multi-chain |

---

## 8. 社区与生态

### 8.1 插件市场

```typescript
// 官方插件
@dasn/plugin-sentry      // 错误追踪
@dasn/plugin-prometheus  // 监控指标
@dasn/plugin-logdna      // 日志收集

// 社区插件
dasn-plugin-custom-pricing
dasn-plugin-telegram-notify
dasn-plugin-discord-presence
```

### 8.2 模板

```bash
# 使用模板创建项目
dasn init --template react-client my-app
dasn init --template advanced-worker my-worker

# 可用模板
- basic-worker
- advanced-worker
- react-client
- nextjs-fullstack
- cli-tool
```

---

*本文档与 DASN SDK 开发同步更新*
