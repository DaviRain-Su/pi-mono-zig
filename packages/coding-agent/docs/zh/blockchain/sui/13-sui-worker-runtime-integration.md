# Sui Worker Runtime 集成

> pi-worker 与 Sui 链的完整集成方案

---

## 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│                      pi-worker                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │ Task Monitor │  │  Executor    │  │  Submitter   │     │
│  │   (轮询)      │  │ (执行任务)    │  │ (提交结果)    │     │
│  └──────┬───────┘  └──────────────┘  └──────┬───────┘     │
└─────────┼────────────────────────────────────┼───────────────┘
          │                                      │
          │ Sui SDK (TypeScript)                 │
          ▼                                      ▼
┌─────────────────────────────────────────────────────────────┐
│                      Sui 网络                               │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │   Task   │  │ WorkerCap│  │  Result  │  │ Dispute  │   │
│  │  (共享)   │  │ (对象)    │  │  (对象)   │  │ (共享)   │   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 核心组件

### 1. Sui 客户端封装

```typescript
// src/chain/sui-client.ts
import { SuiClient, getFullnodeUrl } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';

export class SuiChainClient {
    private client: SuiClient;
    private keypair: Ed25519Keypair;
    private packageId: string;
    
    constructor(
        network: 'mainnet' | 'testnet' | 'devnet',
        privateKey: string,
        packageId: string,
    ) {
        this.client = new SuiClient({ url: getFullnodeUrl(network) });
        this.keypair = Ed25519Keypair.fromSecretKey(privateKey);
        this.packageId = packageId;
    }
    
    getAddress(): string {
        return this.keypair.getPublicKey().toSuiAddress();
    }
    
    async executeTransaction(tx: Transaction) {
        const result = await this.client.signAndExecuteTransaction({
            transaction: tx,
            signer: this.keypair,
            options: {
                showEffects: true,
                showEvents: true,
            },
        });
        return result;
    }
}
```

### 2. 任务发现服务

```typescript
// src/task/discovery.ts
import { SuiClient } from '@mysten/sui/client';

export class TaskDiscoveryService {
    constructor(
        private client: SuiClient,
        private packageId: string,
    ) {}
    
    /// 获取所有待处理任务
    async getPendingTasks(): Promise<Task[]> {
        // 查询 Task 对象
        const objects = await this.client.getOwnedObjects({
            owner: '0x0', // 共享对象需要特殊查询
            filter: {
                StructType: `${this.packageId}::task::Task`,
            },
            options: {
                showContent: true,
                showType: true,
            },
        });
        
        // 过滤状态为 PENDING 的任务
        return objects.data
            .filter(obj => {
                const status = obj.data?.content?.fields?.status;
                return status === 0; // STATUS_PENDING
            })
            .map(obj => this.parseTask(obj));
    }
    
    /// 监听新任务事件
    async subscribeNewTasks(callback: (task: Task) => void) {
        const unsubscribe = await this.client.subscribeEvent({
            filter: {
                MoveEventType: `${this.packageId}::task::TaskCreated`,
            },
            onMessage: (event) => {
                callback(this.parseTaskFromEvent(event));
            },
        });
        return unsubscribe;
    }
    
    private parseTask(obj: any): Task {
        const fields = obj.data.content.fields;
        return {
            id: obj.data.objectId,
            creator: fields.creator,
            descriptionCid: fields.description_cid,
            budget: BigInt(fields.budget),
            executionBudget: Number(fields.execution_budget),
            status: fields.status,
            requiredCapabilities: fields.required_capabilities,
            expiresAt: Number(fields.expires_at),
        };
    }
}
```

### 3. 任务执行器

```typescript
// src/task/executor.ts
import { Transaction } from '@mysten/sui/transactions';

export class TaskExecutor {
    constructor(
        private chainClient: SuiChainClient,
        private piRuntime: PiRuntime,
    ) {}
    
    /// 执行完整任务流程
    async executeTask(task: Task): Promise<TaskResult> {
        // 1. 下载任务描述
        const description = await this.downloadFromIPFS(task.descriptionCid);
        
        // 2. 认领任务
        const claimResult = await this.claimTask(task.id);
        const workerCapId = claimResult.workerCapId;
        
        try {
            // 3. 执行任务
            const executionResult = await this.piRuntime.execute({
                prompt: description.prompt,
                tools: description.tools,
                timeout: task.executionBudget,
            });
            
            // 4. 上传结果到 IPFS
            const resultCid = await this.uploadToIPFS({
                output: executionResult.output,
                logs: executionResult.logs,
            });
            
            const receiptCid = await this.uploadToIPFS({
                tokensUsed: executionResult.tokensUsed,
                cost: executionResult.cost,
                duration: executionResult.duration,
            });
            
            // 5. 提交结果
            await this.submitResult(task.id, workerCapId, resultCid, receiptCid);
            
            return {
                success: true,
                resultCid,
                receiptCid,
            };
        } catch (error) {
            // 任务失败，能力对象已消耗
            throw error;
        }
    }
    
    /// 认领任务
    private async claimTask(taskId: string): Promise<{ workerCapId: string }> {
        const tx = new Transaction();
        
        tx.moveCall({
            target: `${this.chainClient.packageId}::task::claim_task`,
            arguments: [
                tx.object(taskId),
            ],
        });
        
        const result = await this.chainClient.executeTransaction(tx);
        
        // 解析返回的 WorkerCap ID
        const workerCapId = result.objectChanges?.find(
            (change: any) => change.objectType?.includes('WorkerCap')
        )?.objectId;
        
        return { workerCapId };
    }
    
    /// 提交结果
    private async submitResult(
        taskId: string,
        workerCapId: string,
        resultCid: string,
        receiptCid: string,
    ) {
        const tx = new Transaction();
        
        tx.moveCall({
            target: `${this.chainClient.packageId}::task::submit_result`,
            arguments: [
                tx.object(taskId),
                tx.object(workerCapId),
                tx.pure.string(resultCid),
                tx.pure.string(receiptCid),
            ],
        });
        
        await this.chainClient.executeTransaction(tx);
    }
}
```

---

## 状态监控

### 链上状态轮询

```typescript
// src/monitor/chain-monitor.ts
export class ChainMonitor {
    private running = false;
    private checkInterval = 5000; // 5秒
    
    constructor(
        private discovery: TaskDiscoveryService,
        private executor: TaskExecutor,
    ) {}
    
    async start() {
        this.running = true;
        
        while (this.running) {
            try {
                // 1. 获取待处理任务
                const pendingTasks = await this.discovery.getPendingTasks();
                
                // 2. 过滤可执行的任务
                const executableTasks = pendingTasks.filter(task =>
                    this.canExecute(task)
                );
                
                // 3. 并行执行任务
                await Promise.all(
                    executableTasks.map(task =>
                        this.executor.executeTask(task).catch(console.error)
                    )
                );
                
            } catch (error) {
                console.error('Monitor error:', error);
            }
            
            await sleep(this.checkInterval);
        }
    }
    
    stop() {
        this.running = false;
    }
    
    private canExecute(task: Task): boolean {
        // 检查能力匹配
        // 检查时间限制
        // 检查预算
        return true;
    }
}
```

### 事件订阅模式

```typescript
// src/monitor/event-listener.ts
export class EventListener {
    private unsubscribers: (() => void)[] = [];
    
    constructor(private client: SuiClient) {}
    
    async start() {
        // 监听任务创建
        const unsub1 = await this.client.subscribeEvent({
            filter: {
                MoveEventType: `${PACKAGE_ID}::task::TaskCreated`,
            },
            onMessage: (event) => {
                this.handleTaskCreated(event);
            },
        });
        this.unsubscribers.push(unsub1);
        
        // 监听任务认领
        const unsub2 = await this.client.subscribeEvent({
            filter: {
                MoveEventType: `${PACKAGE_ID}::task::TaskClaimed`,
            },
            onMessage: (event) => {
                this.handleTaskClaimed(event);
            },
        });
        this.unsubscribers.push(unsub2);
        
        // 监听结果提交
        const unsub3 = await this.client.subscribeEvent({
            filter: {
                MoveEventType: `${PACKAGE_ID}::task::ResultSubmitted`,
            },
            onMessage: (event) => {
                this.handleResultSubmitted(event);
            },
        });
        this.unsubscribers.push(unsub3);
        
        // 监听结算
        const unsub4 = await this.client.subscribeEvent({
            filter: {
                MoveEventType: `${PACKAGE_ID}::settlement::TaskAccepted`,
            },
            onMessage: (event) => {
                this.handleTaskAccepted(event);
            },
        });
        this.unsubscribers.push(unsub4);
    }
    
    stop() {
        this.unsubscribers.forEach(unsub => unsub());
        this.unsubscribers = [];
    }
    
    private handleTaskCreated(event: any) {
        console.log('New task:', event.parsedJson.task_id);
    }
    
    private handleTaskAccepted(event: any) {
        console.log('Task accepted:', event.parsedJson.task_id);
        console.log('Payment:', event.parsedJson.payment);
    }
}
```

---

## 错误处理与重试

### 交易失败处理

```typescript
// src/utils/retry.ts
export async function executeWithRetry<T>(
    fn: () => Promise<T>,
    maxRetries = 3,
): Promise<T> {
    let lastError: Error;
    
    for (let i = 0; i < maxRetries; i++) {
        try {
            return await fn();
        } catch (error: any) {
            lastError = error;
            
            // 检查错误类型
            if (error.message.includes('InvalidStatus')) {
                // 状态错误，不重试
                throw error;
            }
            
            if (error.message.includes('ETaskExpired')) {
                // 任务过期，不重试
                throw error;
            }
            
            // 网络错误，等待后重试
            const delay = Math.pow(2, i) * 1000;
            console.log(`Retry ${i + 1}/${maxRetries} after ${delay}ms`);
            await sleep(delay);
        }
    }
    
    throw lastError!;
}
```

### Gas 管理

```typescript
// src/utils/gas-manager.ts
export class GasManager {
    constructor(
        private client: SuiClient,
        private address: string,
    ) {}
    
    async checkAndRefill(minBalance: bigint = 1000000000n): Promise<void> {
        const balance = await this.client.getBalance({
            owner: this.address,
        });
        
        if (BigInt(balance.totalBalance) < minBalance) {
            console.warn('Low SUI balance:', balance.totalBalance);
            // 发送警报或自动补充
        }
    }
    
    async estimateGas(tx: Transaction): Promise<bigint> {
        const dryRun = await this.client.dryRunTransactionBlock({
            transactionBlock: tx,
        });
        return BigInt(dryRun.effects.gasUsed.computationCost) +
               BigInt(dryRun.effects.gasUsed.storageCost);
    }
}
```

---

## 配置示例

### Worker 配置文件

```yaml
# config.yaml
chain:
  type: sui
  network: testnet
  packageId: "0x1234..."
  rpcUrl: "https://testnet.sui.io"
  
wallet:
  privateKey: ${SUI_PRIVATE_KEY}
  
worker:
  name: "pi-worker-01"
  capabilities:
    - "code-generation"
    - "code-review"
    - "documentation"
  maxConcurrentTasks: 3
  minReward: 100000000  # 0.1 SUI
  
execution:
  defaultTimeout: 300000  # 5分钟
  maxTokens: 100000
  
monitoring:
  pollInterval: 5000
  healthCheckInterval: 30000
```

### 启动脚本

```typescript
// src/index.ts
import { loadConfig } from './config';
import { SuiChainClient } from './chain/sui-client';
import { TaskDiscoveryService } from './task/discovery';
import { TaskExecutor } from './task/executor';
import { ChainMonitor } from './monitor/chain-monitor';
import { EventListener } from './monitor/event-listener';

async function main() {
    const config = loadConfig();
    
    // 初始化链客户端
    const chainClient = new SuiChainClient(
        config.chain.network,
        config.wallet.privateKey,
        config.chain.packageId,
    );
    
    console.log('Worker address:', chainClient.getAddress());
    
    // 初始化服务
    const discovery = new TaskDiscoveryService(
        chainClient.client,
        config.chain.packageId,
    );
    
    const piRuntime = new PiRuntime(config.execution);
    
    const executor = new TaskExecutor(
        chainClient,
        piRuntime,
    );
    
    const monitor = new ChainMonitor(discovery, executor);
    const eventListener = new EventListener(chainClient.client);
    
    // 启动
    await monitor.start();
    await eventListener.start();
    
    console.log('pi-worker started');
    
    // 优雅退出
    process.on('SIGINT', async () => {
        console.log('Shutting down...');
        monitor.stop();
        eventListener.stop();
        process.exit(0);
    });
}

main().catch(console.error);
```

---

## 与 Solana Worker 的对比

| 方面 | Solana | Sui |
|------|--------|-----|
| **SDK** | `@solana/web3.js` | `@mysten/sui` |
| **交易构造** | `Transaction` | `Transaction` |
| **事件监听** | `onLogs` | `subscribeEvent` |
| **对象查询** | `getAccountInfo` | `getObject` |
| **并发模型** | 手动管理 | 对象自动隔离 |
| **确认时间** | ~400ms | ~200-1000ms |

---

## 下一步

- [14-sui-dispute-and-reputation.md](./14-sui-dispute-and-reputation.md) - 争议与声誉
- [18-sui-implementation-checklist.md](./18-sui-implementation-checklist.md) - 实现清单

---

*本文档与 pi Sui Worker 实现同步更新*
