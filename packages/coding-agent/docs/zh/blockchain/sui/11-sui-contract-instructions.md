# Sui 合约指令设计

> Move 合约完整指令集与状态迁移设计

---

## 模块结构

```
sources/
├── task.move          # 核心任务管理
├── worker.move        # Worker 注册与管理
├── escrow.move        # 资金托管与结算
├── dispute.move       # 争议处理
├── reputation.move    # 声誉系统
└── governance.move    # 治理与参数
```

---

## 1. task 模块

### 常量定义

```move
module pi::task {
    // ===== 状态常量 =====
    const STATUS_PENDING: u8 = 0;
    const STATUS_CLAIMED: u8 = 1;
    const STATUS_SUBMITTED: u8 = 2;
    const STATUS_ACCEPTED: u8 = 3;
    const STATUS_REJECTED: u8 = 4;
    const STATUS_DISPUTED: u8 = 5;
    const STATUS_RESOLVED: u8 = 6;
    const STATUS_REFUNDED: u8 = 7;
    const STATUS_EXPIRED: u8 = 8;
    
    // ===== 错误码 =====
    const EInvalidStatus: u64 = 0;
    const ETaskExpired: u64 = 1;
    const ENotCreator: u64 = 2;
    const ENotWorker: u64 = 3;
    const EInvalidCapability: u64 = 4;
    const EInsufficientBudget: u64 = 5;
    const EAlreadyClaimed: u64 = 6;
    const ETimeoutNotReached: u64 = 7;
    const EInvalidInput: u64 = 8;
    const EDisputePeriodActive: u64 = 9;
}
```

### 核心对象

```move
/// 任务对象 - 共享
struct Task has key {
    id: UID,
    creator: address,
    description_cid: String,
    budget: Balance<SUI>,
    execution_budget: u64,
    status: u8,
    worker: Option<address>,
    result_cid: Option<String>,
    usage_receipt_cid: Option<String>,
    created_at: u64,
    expires_at: u64,
    dispute_end_time: Option<u64>,
    required_capabilities: vector<String>,
}

/// Worker 能力对象
struct WorkerCap has key, store {
    id: UID,
    task_id: ID,
    worker: address,
    granted_at: u64,
    expires_at: u64,
}

/// 任务统计 (用于分析)
struct TaskStats has key {
    id: UID,
    total_tasks: u64,
    completed_tasks: u64,
    disputed_tasks: u64,
    total_volume: u64,
}
```

### 指令集

#### 创建任务 (create_task)

```move
public entry fun create_task(
    description_cid: String,
    execution_budget: u64,
    expires_in: u64,
    required_capabilities: vector<String>,
    budget: Coin<SUI>,
    ctx: &mut TxContext,
): ID {
    let task_id = object::new(ctx);
    let id_copy = object::uid_to_inner(&task_id);
    
    let task = Task {
        id: task_id,
        creator: tx_context::sender(ctx),
        description_cid,
        budget: coin::into_balance(budget),
        execution_budget,
        status: STATUS_PENDING,
        worker: option::none(),
        result_cid: option::none(),
        usage_receipt_cid: option::none(),
        created_at: tx_context::epoch_timestamp_ms(ctx),
        expires_at: tx_context::epoch_timestamp_ms(ctx) + expires_in,
        dispute_end_time: option::none(),
        required_capabilities,
    };
    
    transfer::share_object(task);
    
    event::emit(TaskCreated {
        task_id: id_copy,
        creator: tx_context::sender(ctx),
        budget: balance::value(&task.budget),
    });
    
    id_copy
}
```

**输入:**
- `description_cid`: IPFS 内容 ID (任务描述)
- `execution_budget`: LLM token 预算
- `expires_in`: 超时时间 (毫秒)
- `required_capabilities`: 所需能力列表
- `budget`: SUI 代币

**输出:**
- 新创建的 Task ID

**事件:**
- `TaskCreated`

#### 认领任务 (claim_task)

```move
public entry fun claim_task(
    task: &mut Task,
    ctx: &mut TxContext,
): WorkerCap {
    // 前置条件检查
    assert!(task.status == STATUS_PENDING, EInvalidStatus);
    
    let now = tx_context::epoch_timestamp_ms(ctx);
    assert!(now < task.expires_at, ETaskExpired);
    
    let worker = tx_context::sender(ctx);
    
    // 状态更新
    task.status = STATUS_CLAIMED;
    task.worker = option::some(worker);
    
    // 创建能力对象
    let cap = WorkerCap {
        id: object::new(ctx),
        task_id: object::id(task),
        worker,
        granted_at: now,
        expires_at: task.expires_at,
    };
    
    event::emit(TaskClaimed {
        task_id: object::id(task),
        worker,
        granted_at: now,
    });
    
    cap
}
```

**前置条件:**
- Task.status == PENDING
- 当前时间 < expires_at

**后置条件:**
- Task.status = CLAIMED
- Task.worker = caller
- 创建 WorkerCap

#### 提交结果 (submit_result)

```move
public entry fun submit_result(
    task: &mut Task,
    cap: WorkerCap,
    result_cid: String,
    usage_receipt_cid: String,
    ctx: &mut TxContext,
) {
    // 验证能力
    assert!(cap.task_id == object::id(task), EInvalidCapability);
    assert!(cap.worker == tx_context::sender(ctx), ENotWorker);
    
    // 状态检查
    assert!(task.status == STATUS_CLAIMED, EInvalidStatus);
    
    let now = tx_context::epoch_timestamp_ms(ctx);
    assert!(now <= cap.expires_at, ETaskExpired);
    
    // 更新任务
    task.status = STATUS_SUBMITTED;
    task.result_cid = option::some(result_cid);
    task.usage_receipt_cid = option::some(usage_receipt_cid);
    
    // 设置争议期 (例如 24 小时)
    task.dispute_end_time = option::some(now + 86400000);
    
    // 销毁能力对象
    let WorkerCap { id, .. } = cap;
    object::delete(id);
    
    event::emit(ResultSubmitted {
        task_id: object::id(task),
        worker: tx_context::sender(ctx),
        result_cid,
        submitted_at: now,
    });
}
```

#### 接受结果 (accept_result)

```move
public entry fun accept_result(
    task: &mut Task,
    ctx: &mut TxContext,
) {
    let caller = tx_context::sender(ctx);
    assert!(caller == task.creator, ENotCreator);
    assert!(task.status == STATUS_SUBMITTED, EInvalidStatus);
    
    task.status = STATUS_ACCEPTED;
    
    let worker = option::destroy_some(task.worker);
    let payment = balance::value(&task.budget);
    let coin = coin::take(&mut task.budget, payment, ctx);
    
    transfer::public_transfer(coin, worker);
    
    event::emit(TaskAccepted {
        task_id: object::id(task),
        worker,
        payment,
    });
}
```

#### 拒绝结果 (reject_result)

```move
public entry fun reject_result(
    task: &mut Task,
    ctx: &mut TxContext,
) {
    assert!(tx_context::sender(ctx) == task.creator, ENotCreator);
    assert!(task.status == STATUS_SUBMITTED, EInvalidStatus);
    
    task.status = STATUS_REJECTED;
    
    event::emit(TaskRejected {
        task_id: object::id(task),
        creator: task.creator,
    });
}
```

#### 退款 (refund)

```move
public entry fun refund(
    task: &mut Task,
    ctx: &mut TxContext,
) {
    assert!(tx_context::sender(ctx) == task.creator, ENotCreator);
    
    let now = tx_context::epoch_timestamp_ms(ctx);
    
    // 检查退款条件
    let can_refund = 
        (task.status == STATUS_PENDING && now >= task.expires_at) ||
        (task.status == STATUS_REJECTED) ||
        (task.status == STATUS_CLAIMED && now >= task.expires_at);
    
    assert!(can_refund, EInvalidStatus);
    
    task.status = STATUS_REFUNDED;
    
    let amount = balance::value(&task.budget);
    let coin = coin::take(&mut task.budget, amount, ctx);
    
    transfer::public_transfer(coin, task.creator);
    
    event::emit(TaskRefunded {
        task_id: object::id(task),
        creator: task.creator,
        amount,
    });
}
```

---

## 2. worker 模块

### 对象定义

```move
module pi::worker {
    /// Worker 注册信息
    struct WorkerInfo has key {
        id: UID,
        owner: address,
        name: String,
        capabilities: vector<String>,
        total_tasks: u64,
        completed_tasks: u64,
        disputed_tasks: u64,
        total_earnings: u64,
        reputation_score: u64,  // 0-10000
        registered_at: u64,
        last_active: u64,
    }
    
    /// Worker 状态 (是否在线)
    struct WorkerStatus has key {
        id: UID,
        worker: address,
        is_online: bool,
        last_heartbeat: u64,
    }
}
```

### 指令集

#### 注册 Worker

```move
public entry fun register_worker(
    name: String,
    capabilities: vector<String>,
    ctx: &mut TxContext,
) {
    let worker = tx_context::sender(ctx);
    let now = tx_context::epoch_timestamp_ms(ctx);
    
    let info = WorkerInfo {
        id: object::new(ctx),
        owner: worker,
        name,
        capabilities,
        total_tasks: 0,
        completed_tasks: 0,
        disputed_tasks: 0,
        total_earnings: 0,
        reputation_score: 5000,  // 初始分数
        registered_at: now,
        last_active: now,
    };
    
    let status = WorkerStatus {
        id: object::new(ctx),
        worker,
        is_online: true,
        last_heartbeat: now,
    };
    
    transfer::transfer(info, worker);
    transfer::share_object(status);
}
```

#### 更新状态

```move
public entry fun heartbeat(
    status: &mut WorkerStatus,
    ctx: &mut TxContext,
) {
    assert!(status.worker == tx_context::sender(ctx), ENotOwner);
    
    status.last_heartbeat = tx_context::epoch_timestamp_ms(ctx);
    status.is_online = true;
}
```

---

## 3. escrow 模块

### 对象定义

```move
module pi::escrow {
    /// 托管账户
    struct EscrowAccount has key {
        id: UID,
        task_id: ID,
        amount: Balance<SUI>,
        creator: address,
        worker: address,
        status: u8,  // 0=held, 1=released, 2=refunded
        created_at: u64,
    }
}
```

### 指令集

#### 创建托管

```move
public entry fun create_escrow(
    task: &Task,
    amount: Coin<SUI>,
    ctx: &mut TxContext,
): ID {
    let escrow = EscrowAccount {
        id: object::new(ctx),
        task_id: object::id(task),
        amount: coin::into_balance(amount),
        creator: task.creator,
        worker: option::destroy_some(task.worker),
        status: 0,
        created_at: tx_context::epoch_timestamp_ms(ctx),
    };
    
    let id = object::id(&escrow);
    transfer::share_object(escrow);
    id
}
```

#### 释放资金

```move
public entry fun release(
    escrow: &mut EscrowAccount,
    ctx: &mut TxContext,
) {
    assert!(escrow.status == 0, EInvalidStatus);
    
    let amount = balance::value(&escrow.amount);
    let coin = coin::take(&mut escrow.amount, amount, ctx);
    
    escrow.status = 1;
    transfer::public_transfer(coin, escrow.worker);
}
```

---

## 4. dispute 模块

### 对象定义

```move
module pi::dispute {
    /// 争议对象
    struct Dispute has key {
        id: UID,
        task_id: ID,
        initiator: address,
        reason_cid: String,
        status: u8,  // 0=open, 1=voting, 2=resolved
        created_at: u64,
        voting_deadline: u64,
        votes_for_worker: u64,
        votes_for_creator: u64,
        voters: vector<address>,
        resolution: Option<bool>,  // true=worker wins
    }
    
    /// 投票记录
    struct Vote has store {
        voter: address,
        support_worker: bool,
        weight: u64,
    }
}
```

### 指令集

#### 发起争议

```move
public entry fun create_dispute(
    task: &mut Task,
    reason_cid: String,
    ctx: &mut TxContext,
): ID {
    assert!(task.status == STATUS_SUBMITTED, EInvalidStatus);
    
    let now = tx_context::epoch_timestamp_ms(ctx);
    
    // 检查争议期
    if (option::is_some(&task.dispute_end_time)) {
        assert!(now <= *option::borrow(&task.dispute_end_time), EDisputePeriodEnded);
    };
    
    task.status = STATUS_DISPUTED;
    
    let dispute = Dispute {
        id: object::new(ctx),
        task_id: object::id(task),
        initiator: tx_context::sender(ctx),
        reason_cid,
        status: 0,
        created_at: now,
        voting_deadline: now + 259200000,  // 3天
        votes_for_worker: 0,
        votes_for_creator: 0,
        voters: vector::empty(),
        resolution: option::none(),
    };
    
    let id = object::id(&dispute);
    transfer::share_object(dispute);
    
    event::emit(DisputeCreated {
        dispute_id: id,
        task_id: object::id(task),
        initiator: tx_context::sender(ctx),
    });
    
    id
}
```

#### 投票

```move
public entry fun vote(
    dispute: &mut Dispute,
    support_worker: bool,
    ctx: &mut TxContext,
) {
    assert!(dispute.status == 0 || dispute.status == 1, EInvalidStatus);
    
    let now = tx_context::epoch_timestamp_ms(ctx);
    assert!(now <= dispute.voting_deadline, EVotingEnded);
    
    let voter = tx_context::sender(ctx);
    assert!(!vector::contains(&dispute.voters, &voter), EAlreadyVoted);
    
    // 简化的投票权重 (实际应基于声誉)
    let weight = 1;
    
    if (support_worker) {
        dispute.votes_for_worker = dispute.votes_for_worker + weight;
    } else {
        dispute.votes_for_creator = dispute.votes_for_creator + weight;
    };
    
    vector::push_back(&mut dispute.voters, voter);
    dispute.status = 1;
}
```

#### 解决争议

```move
public entry fun resolve_dispute(
    dispute: &mut Dispute,
    task: &mut Task,
    ctx: &mut TxContext,
) {
    assert!(dispute.status == 1, EInvalidStatus);
    assert!(tx_context::epoch_timestamp_ms(ctx) > dispute.voting_deadline, EVotingNotEnded);
    
    let worker_wins = dispute.votes_for_worker > dispute.votes_for_creator;
    
    dispute.resolution = option::some(worker_wins);
    dispute.status = 2;
    
    if (worker_wins) {
        task.status = STATUS_RESOLVED;
        // 资金释放给 Worker
    } else {
        task.status = STATUS_REFUNDED;
        // 资金退还给 Creator
    };
    
    event::emit(DisputeResolved {
        dispute_id: object::id(dispute),
        task_id: dispute.task_id,
        worker_wins,
    });
}
```

---

## 5. reputation 模块

### 指令集

```move
module pi::reputation {
    use pi::worker::WorkerInfo;
    use pi::task::Task;
    
    /// 更新 Worker 声誉
    public fun update_reputation(
        worker: &mut WorkerInfo,
        task: &Task,
        success: bool,
    ) {
        worker.total_tasks = worker.total_tasks + 1;
        worker.last_active = tx_context::epoch_timestamp_ms(ctx);
        
        if (success) {
            worker.completed_tasks = worker.completed_tasks + 1;
            // 增加声誉分数
            worker.reputation_score = min(10000, worker.reputation_score + 100);
        } else {
            worker.disputed_tasks = worker.disputed_tasks + 1;
            // 减少声誉分数
            worker.reputation_score = max(0, worker.reputation_score - 200);
        };
        
        worker.total_earnings = worker.total_earnings + task.payment;
    }
    
    /// 计算任务成功率
    public fun success_rate(worker: &WorkerInfo): u64 {
        if (worker.total_tasks == 0) {
            return 0
        };
        (worker.completed_tasks * 10000) / worker.total_tasks
    }
}
```

---

## 状态转换图

```
┌─────────┐    create     ┌─────────┐
│  None   │──────────────▶│ PENDING │
└─────────┘               └────┬────┘
                               │
                    claim      │
                    (WorkerCap)│
                               ▼
┌─────────┐    submit     ┌─────────┐
│EXPIRED  │◀──────────────│ CLAIMED │
│(refund) │               └────┬────┘
└─────────┘                    │
                               │ submit_result
                               ▼
┌─────────┐   accept      ┌─────────┐
│REFUNDED │◀──────────────│SUBMITTED│
│         │               └────┬────┘
└─────────┘                    │
      ▲                        │ reject/dispute
      │                        ▼
      │                   ┌─────────┐
      │                   │DISPUTED │
      │                   └────┬────┘
      │                        │
      │                   resolve
      │                        ▼
      └──────────────────┐┌─────────┐
                         └│RESOLVED │
                          └─────────┘
```

---

## 与 Solana 的对比

| 特性 | Solana | Sui |
|------|--------|-----|
| **指令定义** | `#[derive(Accounts)]` | Move 函数参数 |
| **状态验证** | 手动检查 | 类型系统 +
| **权限控制** | 签名验证 | 对象所有权 |
| **事件** | `emit!` 宏 | `event::emit` |
| **错误处理** | `require!` | `assert!` |
| **并发安全** | 手动指定账户 | 对象自动隔离 |

---

## 下一步

- [12-sui-budget-and-settlement.md](./12-sui-budget-and-settlement.md) - 预算与结算设计
- [13-sui-worker-runtime-integration.md](./13-sui-worker-runtime-integration.md) - Worker 集成

---

*本文档与 pi Sui 合约实现同步更新*
