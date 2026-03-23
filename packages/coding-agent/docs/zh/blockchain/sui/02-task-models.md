# Sui 任务模型设计

> 基于 Sui 对象模型的 Task / Claim / Result / Escrow / Dispute 对象设计

---

## 核心对象关系

```
┌─────────────────┐     创建      ┌─────────────────┐
│   Task (共享)    │──────────────▶│  TaskCreated    │
│  - 任务元数据    │               │  (事件)         │
│  - 赏金余额      │               └─────────────────┘
│  - 状态机       │
└────────┬────────┘
         │ 认领
         ▼
┌─────────────────┐     提交      ┌─────────────────┐
│  WorkerCap      │──────────────▶│  TaskResult     │
│ (能力对象)       │               │  (对象)         │
│  - 权限证明      │               │  - 结果哈希      │
└─────────────────┘               │  - 证明数据      │
                                  └────────┬────────┘
                                           │ 验证
                                           ▼
                                  ┌─────────────────┐
                                  │  EscrowReceipt  │
                                  │  - 结算凭证      │
                                  └─────────────────┘
```

---

## 对象定义

### 1. Task (共享对象)

任务的核心数据结构，作为共享对象存在，允许任何人读取。

```move
module pi::task {
    use sui::object::{Self, UID};
    use sui::balance::Balance;
    use sui::sui::SUI;
    use sui::table::Table;
    
    /// 任务状态枚举
    const STATUS_PENDING: u8 = 0;
    const STATUS_CLAIMED: u8 = 1;
    const STATUS_SUBMITTED: u8 = 2;
    const STATUS_ACCEPTED: u8 = 3;
    const STATUS_DISPUTED: u8 = 4;
    const STATUS_REFUNDED: u8 = 5;
    
    /// 任务对象 - 共享
    struct Task has key {
        id: UID,
        /// 创建者地址
        creator: address,
        /// 任务描述哈希 (IPFS CID)
        description_hash: vector<u8>,
        /// 预算 (SUI tokens)
        budget: Balance<SUI>,
        /// 执行预算 (LLM tokens)
        execution_budget: u64,
        /// 当前状态
        status: u8,
        /// 当前认领者 (可选)
        worker: Option<address>,
        /// 认领时间戳
        claimed_at: Option<u64>,
        /// 超时时间 (秒)
        timeout: u64,
        /// 要求的能力列表
        required_capabilities: vector<vector<u8>>,
        /// 已提交的结果数量
        result_count: u64,
        /// 创建时间
        created_at: u64,
    }
    
    /// 任务创建事件
    struct TaskCreated has copy, drop {
        task_id: address,
        creator: address,
        budget: u64,
        execution_budget: u64,
    }
    
    /// 任务被认领事件
    struct TaskClaimed has copy, drop {
        task_id: address,
        worker: address,
        claimed_at: u64,
    }
}
```

### 2. WorkerCapability (能力对象)

Worker 认领任务后获得的能力对象，证明其执行权限。

```move
module pi::worker {
    use sui::object::{Self, UID};
    
    /// Worker 能力对象 - 可转移给 Worker
    struct WorkerCapability has key, store {
        id: UID,
        /// 对应的任务 ID
        task_id: address,
        /// Worker 地址
        worker: address,
        /// 获得能力的时间
        granted_at: u64,
        /// 过期时间
        expires_at: u64,
    }
    
    /// Worker 注册信息 (可选，用于声誉系统)
    struct WorkerInfo has key {
        id: UID,
        owner: address,
        /// 完成的任务数
        completed_tasks: u64,
        /// 争议次数
        disputes: u64,
        /// 总收益
        total_earnings: u64,
        /// 能力列表
        capabilities: vector<vector<u8>>,
    }
}
```

### 3. TaskResult (对象)

Worker 提交的结果，作为独立对象存在。

```move
module pi::result {
    use sui::object::{Self, UID};
    
    /// 任务结果对象
    struct TaskResult has key {
        id: UID,
        /// 对应任务 ID
        task_id: address,
        /// 提交者 (Worker)
        submitter: address,
        /// 结果内容哈希 (IPFS CID)
        result_hash: vector<u8>,
        /// 使用证明哈希
        usage_proof_hash: vector<u8>,
        /// 提交时间
        submitted_at: u64,
        /// 声明的成本
        claimed_cost: u64,
    }
    
    /// 结果提交事件
    struct ResultSubmitted has copy, drop {
        task_id: address,
        result_id: address,
        submitter: address,
        result_hash: vector<u8>,
    }
}
```

### 4. EscrowReceipt (对象)

结算凭证，证明资金托管状态。

```move
module pi::escrow {
    use sui::object::{Self, UID};
    use sui::balance::Balance;
    use sui::sui::SUI;
    
    /// 托管收据
    struct EscrowReceipt has key {
        id: UID,
        /// 任务 ID
        task_id: address,
        /// 托管金额
        amount: Balance<SUI>,
        /// Worker 应得
        worker_share: u64,
        /// 平台费用
        platform_fee: u64,
        /// 创建者退款
        refund_amount: u64,
        /// 创建时间
        created_at: u64,
    }
    
    /// 结算完成事件
    struct SettlementCompleted has copy, drop {
        task_id: address,
        worker: address,
        amount: u64,
    }
}
```

### 5. Dispute (共享对象)

争议对象，需要共享以便多方参与。

```move
module pi::dispute {
    use sui::object::{Self, UID};
    use sui::table::Table;
    
    /// 争议状态
    const DISPUTE_OPEN: u8 = 0;
    const DISPUTE_VOTING: u8 = 1;
    const DISPUTE_RESOLVED: u8 = 2;
    
    /// 争议对象 - 共享
    struct Dispute has key {
        id: UID,
        /// 任务 ID
        task_id: address,
        /// 发起者
        initiator: address,
        /// 争议原因哈希
        reason_hash: vector<u8>,
        /// 状态
        status: u8,
        /// 创建时间
        created_at: u64,
        /// 投票截止时间
        voting_deadline: u64,
        /// 投票记录 (投票人 -> 投票)
        votes: Table<address, bool>,
        /// 支持票数 (Worker 胜)
        votes_for_worker: u64,
        /// 反对票数 (创建者胜)
        votes_for_creator: u64,
    }
    
    /// 争议创建事件
    struct DisputeCreated has copy, drop {
        dispute_id: address,
        task_id: address,
        initiator: address,
    }
}
```

---

## 状态机

```
                    ┌─────────────┐
         ┌─────────▶│   Pending   │◀────────┐
         │          │  (等待认领)  │         │
         │          └──────┬──────┘         │
         │                 │ claim()        │ timeout
         │                 ▼                │
         │          ┌─────────────┐         │
         │          │   Claimed   │─────────┘
         │          │ (已被认领)   │  release()
         │          └──────┬──────┘
         │                 │ submit_result()
         │                 ▼
         │          ┌─────────────┐
         │          │  Submitted  │
         │          │ (结果已提交) │
         │          └──────┬──────┘
         │         ┌───────┴───────┐
         │         │               │
         ▼         ▼               ▼
   ┌─────────┐ ┌─────────┐  ┌──────────┐
   │Disputed │ │Accepted │  │ Rejected │
   │(争议中)  │ │(已接受)  │  │(已拒绝)  │
   └────┬────┘ └────┬────┘  └────┬─────┘
        │           │            │
        │    ┌──────┘            │
        │    │                   │
        ▼    ▼                   ▼
   ┌─────────────┐         ┌─────────────┐
   │  Resolved   │         │  Refunded   │
   │  (已解决)    │         │  (已退款)    │
   └─────────────┘         └─────────────┘
```

---

## 关键函数设计

### 创建任务

```move
public entry fun create_task(
    description_hash: vector<u8>,
    execution_budget: u64,
    timeout: u64,
    required_capabilities: vector<vector<u8>>,
    budget_coin: Coin<SUI>,
    ctx: &mut TxContext,
) {
    let task = Task {
        id: object::new(ctx),
        creator: tx_context::sender(ctx),
        description_hash,
        budget: coin::into_balance(budget_coin),
        execution_budget,
        status: STATUS_PENDING,
        worker: option::none(),
        claimed_at: option::none(),
        timeout,
        required_capabilities,
        result_count: 0,
        created_at: tx_context::epoch_timestamp_ms(ctx),
    };
    
    // 共享对象，任何人可读取
    transfer::share_object(task);
}
```

### 认领任务

```move
public entry fun claim_task(
    task: &mut Task,
    ctx: &mut TxContext,
) {
    // 检查状态
    assert!(task.status == STATUS_PENDING, ETaskNotPending);
    
    // 检查是否超时
    let now = tx_context::epoch_timestamp_ms(ctx);
    assert!(now < task.created_at + task.timeout, ETaskExpired);
    
    let worker = tx_context::sender(ctx);
    
    // 更新任务
    task.status = STATUS_CLAIMED;
    task.worker = option::some(worker);
    task.claimed_at = option::some(now);
    
    // 创建 Worker 能力对象
    let capability = WorkerCapability {
        id: object::new(ctx),
        task_id: object::id_address(task),
        worker,
        granted_at: now,
        expires_at: now + task.timeout,
    };
    
    // 转移给 Worker
    transfer::transfer(capability, worker);
}
```

### 提交结果

```move
public entry fun submit_result(
    task: &mut Task,
    capability: WorkerCapability,
    result_hash: vector<u8>,
    usage_proof_hash: vector<u8>,
    claimed_cost: u64,
    ctx: &mut TxContext,
) {
    // 验证能力
    let task_id = object::id_address(task);
    assert!(capability.task_id == task_id, EInvalidCapability);
    assert!(capability.worker == tx_context::sender(ctx), ENotWorker);
    
    // 检查状态
    assert!(task.status == STATUS_CLAIMED, ETaskNotClaimed);
    
    // 检查是否超时
    let now = tx_context::epoch_timestamp_ms(ctx);
    assert!(now <= capability.expires_at, ECapabilityExpired);
    
    // 创建结果对象
    let result = TaskResult {
        id: object::new(ctx),
        task_id,
        submitter: capability.worker,
        result_hash,
        usage_proof_hash,
        submitted_at: now,
        claimed_cost,
    };
    
    // 更新任务
    task.status = STATUS_SUBMITTED;
    task.result_count = task.result_count + 1;
    
    // 销毁能力对象 (已使用)
    let WorkerCapability { id, .. } = capability;
    object::delete(id);
    
    // 共享结果对象
    transfer::share_object(result);
}
```

---

## 与 Solana 设计的对比

| 方面 | Solana | Sui |
|------|--------|-----|
| **任务存储** | PDA 账户 | 共享对象 |
| **Worker 权限** | 签名验证 | 能力对象 |
| **结果提交** | 账户写入 | 新对象创建 |
| **并行执行** | 需手动指定 | 对象级自动 |
| ** gas 成本** | 按计算单元 | 按存储 + 计算 |

### Sui 的优势

1. **更自然的权限模型**
   - Move 的能力模式比 Solana 的签名检查更清晰

2. **更低的读取延迟**
   - 简单查询无需共识，响应更快

3. **更好的资源管理**
   - 对象自动追踪，无需手动管理账户生命周期

4. **原生批处理**
   - Programmable Transaction Blocks (PTB) 支持复杂操作

---

## 下一步

- [04-task-execution-flow.md](./04-task-execution-flow.md) - 完整执行时序
- [11-sui-contract-instructions.md](./11-sui-contract-instructions.md) - Move 合约完整指令集

---

*本文档与 pi Sui 集成设计同步更新*
