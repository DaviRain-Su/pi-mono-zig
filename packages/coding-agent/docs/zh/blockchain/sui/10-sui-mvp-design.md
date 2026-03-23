# Sui MVP 草案

> 第一条链的最小对象模型与 Worker 接入闭环

---

## 目标

在 Sui 测试网上部署最小可行产品，验证：
1. Worker 可以发现并认领任务
2. Worker 可以提交结果
3. 创建者可以验收并结算
4. 争议机制可以工作

---

## 最小对象模型

### 核心对象 (3个)

```move
// 1. Task - 共享对象
struct Task has key {
    id: UID,
    creator: address,
    description_cid: String,  // IPFS 内容 ID
    budget: Balance<SUI>,
    status: u8,  // 0=pending, 1=claimed, 2=submitted, 3=accepted, 4=disputed
    worker: Option<address>,
    created_at: u64,
    expires_at: u64,
}

// 2. WorkerCap - 能力对象 (转移给 Worker)
struct WorkerCap has key, store {
    id: UID,
    task_id: ID,
    worker: address,
    expires_at: u64,
}

// 3. Result - 对象 (提交时创建)
struct Result has key {
    id: UID,
    task_id: ID,
    result_cid: String,
    usage_receipt_cid: String,
    submitted_at: u64,
}
```

### 简化设计决策

| 功能 | MVP 版本 | 完整版本 |
|------|---------|---------|
| 任务类型 | 单结果任务 | 多结果支持 |
| 结算 | 即时结算 | 延迟结算 + 托管 |
| 争议 | 简单投票 | 陪审团机制 |
| Worker 声誉 | 无 | 完整声誉系统 |
| 能力要求 | 无 | 链上验证 |
| 支付 token | 仅 SUI | 多 token 支持 |

---

## Move 模块结构

```
sources/
├── task.move          # 核心任务逻辑
├── worker.move        # Worker 管理
├── escrow.move        # 资金托管 (MVP简化版)
└── dispute.move       # 争议处理 (简化版)
```

### task.move (MVP 版本)

```move
module pi::task {
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use std::option::{Self, Option};
    use std::string::String;
    
    // ===== 常量 =====
    const STATUS_PENDING: u8 = 0;
    const STATUS_CLAIMED: u8 = 1;
    const STATUS_SUBMITTED: u8 = 2;
    const STATUS_ACCEPTED: u8 = 3;
    const STATUS_DISPUTED: u8 = 4;
    const STATUS_REFUNDED: u8 = 5;
    
    // ===== 错误码 =====
    const EInvalidStatus: u64 = 0;
    const ETaskExpired: u64 = 1;
    const ENotCreator: u64 = 2;
    const ENotWorker: u64 = 3;
    const EInvalidCapability: u64 = 4;
    
    // ===== 对象定义 =====
    
    struct Task has key {
        id: UID,
        creator: address,
        description_cid: String,
        budget: Balance<SUI>,
        status: u8,
        worker: Option<address>,
        result_cid: Option<String>,
        created_at: u64,
        expires_at: u64,
    }
    
    struct WorkerCap has key, store {
        id: UID,
        task_id: ID,
        worker: address,
        expires_at: u64,
    }
    
    // ===== 事件 =====
    
    struct TaskCreated has copy, drop {
        task_id: ID,
        creator: address,
        budget: u64,
    }
    
    struct TaskClaimed has copy, drop {
        task_id: ID,
        worker: address,
    }
    
    struct ResultSubmitted has copy, drop {
        task_id: ID,
        worker: address,
        result_cid: String,
    }
    
    struct TaskAccepted has copy, drop {
        task_id: ID,
        worker: address,
        payment: u64,
    }
    
    struct TaskRefunded has copy, drop {
        task_id: ID,
        creator: address,
        amount: u64,
    }
    
    // ===== 公共函数 =====
    
    /// 创建新任务
    public entry fun create_task(
        description_cid: String,
        expires_in: u64,  // 毫秒
        budget: Coin<SUI>,
        ctx: &mut TxContext,
    ) {
        let now = tx_context::epoch_timestamp_ms(ctx);
        let task = Task {
            id: object::new(ctx),
            creator: tx_context::sender(ctx),
            description_cid,
            budget: coin::into_balance(budget),
            status: STATUS_PENDING,
            worker: option::none(),
            result_cid: option::none(),
            created_at: now,
            expires_at: now + expires_in,
        };
        
        let task_id = object::id(&task);
        let budget_amount = balance::value(&task.budget);
        
        transfer::share_object(task);
        
        sui::event::emit(TaskCreated {
            task_id,
            creator: tx_context::sender(ctx),
            budget: budget_amount,
        });
    }
    
    /// Worker 认领任务
    public entry fun claim_task(
        task: &mut Task,
        ctx: &mut TxContext,
    ) {
        assert!(task.status == STATUS_PENDING, EInvalidStatus);
        
        let now = tx_context::epoch_timestamp_ms(ctx);
        assert!(now < task.expires_at, ETaskExpired);
        
        let worker = tx_context::sender(ctx);
        task.status = STATUS_CLAIMED;
        task.worker = option::some(worker);
        
        let cap = WorkerCap {
            id: object::new(ctx),
            task_id: object::id(task),
            worker,
            expires_at: task.expires_at,
        };
        
        transfer::transfer(cap, worker);
        
        sui::event::emit(TaskClaimed {
            task_id: object::id(task),
            worker,
        });
    }
    
    /// Worker 提交结果
    public entry fun submit_result(
        task: &mut Task,
        cap: WorkerCap,
        result_cid: String,
        usage_receipt_cid: String,
        ctx: &mut TxContext,
    ) {
        let worker = tx_context::sender(ctx);
        let task_id = object::id(task);
        
        // 验证能力
        assert!(cap.task_id == task_id, EInvalidCapability);
        assert!(cap.worker == worker, ENotWorker);
        assert!(task.status == STATUS_CLAIMED, EInvalidStatus);
        
        let now = tx_context::epoch_timestamp_ms(ctx);
        assert!(now <= cap.expires_at, ETaskExpired);
        
        // 更新任务
        task.status = STATUS_SUBMITTED;
        task.result_cid = option::some(result_cid);
        
        // 销毁能力
        let WorkerCap { id, .. } = cap;
        object::delete(id);
        
        sui::event::emit(ResultSubmitted {
            task_id,
            worker,
            result_cid,
        });
        
        // 忽略 usage_receipt_cid (MVP 仅记录)
        let _ = usage_receipt_cid;
    }
    
    /// 创建者验收结果并结算
    public entry fun accept_result(
        task: &mut Task,
        ctx: &mut TxContext,
    ) {
        let creator = tx_context::sender(ctx);
        assert!(creator == task.creator, ENotCreator);
        assert!(task.status == STATUS_SUBMITTED, EInvalidStatus);
        
        task.status = STATUS_ACCEPTED;
        
        let worker = option::destroy_some(task.worker);
        let payment = balance::value(&task.budget);
        let coin = coin::take(&mut task.budget, payment, ctx);
        
        transfer::public_transfer(coin, worker);
        
        sui::event::emit(TaskAccepted {
            task_id: object::id(task),
            worker,
            payment,
        });
    }
    
    /// 退款（超时或未被认领）
    public entry fun refund(
        task: &mut Task,
        ctx: &mut TxContext,
    ) {
        let creator = tx_context::sender(ctx);
        assert!(creator == task.creator, ENotCreator);
        
        let now = tx_context::epoch_timestamp_ms(ctx);
        let can_refund = 
            (task.status == STATUS_PENDING && now >= task.expires_at) ||
            (task.status == STATUS_CLAIMED && now >= task.expires_at);
        
        assert!(can_refund, EInvalidStatus);
        
        task.status = STATUS_REFUNDED;
        
        let amount = balance::value(&task.budget);
        let coin = coin::take(&mut task.budget, amount, ctx);
        
        transfer::public_transfer(coin, creator);
        
        sui::event::emit(TaskRefunded {
            task_id: object::id(task),
            creator,
            amount,
        });
    }
    
    // ===== 查询函数 =====
    
    public fun get_status(task: &Task): u8 {
        task.status
    }
    
    public fun get_worker(task: &Task): Option<address> {
        task.worker
    }
    
    public fun get_budget(task: &Task): u64 {
        balance::value(&task.budget)
    }
}
```

---

## Worker 接入流程 (MVP)

### 1. 任务发现

```typescript
// pi-worker 使用 Sui SDK 查询
import { SuiClient } from '@mysten/sui/client';

const client = new SuiClient({ url: 'https://testnet.sui.io' });

// 查询待处理任务
const tasks = await client.getOwnedObjects({
  owner: 'Shared',
  filter: {
    MoveModule: {
      package: PI_PACKAGE_ID,
      module: 'task',
    },
  },
  options: {
    showContent: true,
  },
});

// 过滤状态为 pending 的任务
const pendingTasks = tasks.data.filter(t => 
  t.data.content.fields.status === 0
);
```

### 2. 认领任务

```typescript
// Worker 决定认领
const tx = new Transaction();

tx.moveCall({
  target: `${PI_PACKAGE_ID}::task::claim_task`,
  arguments: [
    tx.object(taskId),  // 共享对象
  ],
});

const result = await client.signAndExecuteTransaction({
  transaction: tx,
  signer: workerKeypair,
});

// WorkerCap 对象会自动转移到 Worker 地址
```

### 3. 执行并提交

```typescript
// Worker 执行任务...
const resultCid = await uploadToIPFS(result);
const receiptCid = await uploadToIPFS(usageReceipt);

// 提交结果（消耗 WorkerCap）
const tx = new Transaction();

const cap = await getWorkerCap(taskId);  // 查询 Worker 拥有的 Cap

tx.moveCall({
  target: `${PI_PACKAGE_ID}::task::submit_result`,
  arguments: [
    tx.object(taskId),
    tx.object(cap.id),
    tx.pure.string(resultCid),
    tx.pure.string(receiptCid),
  ],
});

await client.signAndExecuteTransaction({
  transaction: tx,
  signer: workerKeypair,
});
```

### 4. 结算监听

```typescript
// 监听 TaskAccepted 事件
client.subscribeEvent({
  filter: {
    MoveEventType: `${PI_PACKAGE_ID}::task::TaskAccepted`,
  },
  onMessage: (event) => {
    if (event.parsedJson.task_id === taskId) {
      console.log(`Task ${taskId} accepted, payment: ${event.parsedJson.payment}`);
    }
  },
});
```

---

## 测试网部署步骤

### 1. 环境准备

```bash
# 安装 Sui CLI
cargo install --locked sui

# 连接到测试网
sui client switch --env testnet

# 获取测试网 SUI
sui client faucet
```

### 2. 编译部署

```bash
# 编译
sui move build

# 部署
sui client publish --gas-budget 100000000

# 记录 package ID
export PI_PACKAGE_ID=<部署输出的 package ID>
```

### 3. 测试脚本

```bash
# 创建任务
create_task "QmTest123" 3600000 1000000000

# Worker 认领
claim_task $TASK_ID

# 提交结果
submit_result $TASK_ID $CAP_ID "QmResult456" "QmReceipt789"

# 验收
accept_result $TASK_ID
```

---

## 与 Solana MVP 的对比

| 方面 | Solana MVP | Sui MVP |
|------|-----------|---------|
| **合约代码量** | ~300 行 | ~250 行 |
| **对象/账户数** | 2 个 PDA | 3 个对象 |
| **部署成本** | ~0.5 SOL | ~5 SUI |
| **认领延迟** | ~400ms | ~200ms |
| **提交延迟** | ~400ms | ~200ms |
| **查询复杂度** | 中等 | 简单 |

---

## 下一步

- [11-sui-contract-instructions.md](./11-sui-contract-instructions.md) - 完整指令集
- [18-sui-implementation-checklist.md](./18-sui-implementation-checklist.md) - 实现清单

---

*本文档与 pi Sui MVP 实现同步更新*
