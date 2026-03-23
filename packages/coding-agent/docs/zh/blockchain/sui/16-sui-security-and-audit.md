# Sui 安全与审计清单

> 状态机、权限、结算、Artifact、Market 与 Runtime 的审计重点

---

## 安全原则

### Sui 安全模型

```
┌─────────────────────────────────────────┐
│         Sui 安全层次                     │
├─────────────────────────────────────────┤
│  1. Move 语言安全                        │
│     - 资源不可复制                        │
│     - 静态类型检查                        │
│     - 所有权系统                          │
├─────────────────────────────────────────┤
│  2. 对象模型安全                         │
│     - 访问控制                            │
│     - 共享对象共识                        │
│     - 所有权验证                          │
├─────────────────────────────────────────┤
│  3. 合约逻辑安全                         │
│     - 状态机正确性                        │
│     - 权限检查                            │
│     - 数学安全                            │
├─────────────────────────────────────────┤
│  4. 经济安全                             │
│     - 防止套利                            │
│     - 公平结算                            │
│     - 防女巫攻击                          │
└─────────────────────────────────────────┘
```

---

## 状态机审计

### 状态转换验证

```move
module pi::security {
    use pi::task::Task;
    
    /// 有效状态转换表
    const VALID_TRANSITIONS: vector<vector<u8>> = vector[
        vector[0, 1],  // PENDING -> CLAIMED
        vector[1, 2],  // CLAIMED -> SUBMITTED
        vector[2, 3],  // SUBMITTED -> ACCEPTED
        vector[2, 4],  // SUBMITTED -> REJECTED
        vector[2, 5],  // SUBMITTED -> DISPUTED
        vector[5, 6],  // DISPUTED -> RESOLVED
        vector[0, 7],  // PENDING -> REFUNDED (超时)
        vector[1, 7],  // CLAIMED -> REFUNDED (超时)
        vector[4, 7],  // REJECTED -> REFUNDED
    ];
    
    /// 验证状态转换
    public fun is_valid_transition(
        from: u8,
        to: u8,
    ): bool {
        let i = 0;
        while (i < vector::length(&VALID_TRANSITIONS)) {
            let transition = vector::borrow(&VALID_TRANSITIONS, i);
            if (*vector::borrow(transition, 0) == from && 
                *vector::borrow(transition, 1) == to) {
                return true
            };
            i = i + 1;
        };
        false
    }
}
```

### 状态机测试用例

| 测试 | 输入 | 期望 | 严重级别 |
|------|------|------|---------|
| 正常认领 | PENDING + Worker | CLAIMED | 关键 |
| 重复认领 | CLAIMED + Worker | 拒绝 | 关键 |
| 超时认领 | PENDING + 超时 | 拒绝 | 高 |
| 非 Worker 提交 | CLAIMED + 非 Worker | 拒绝 | 关键 |
| 过期提交 | CLAIMED + 过期 | 拒绝 | 高 |
| 未提交结算 | CLAIMED + 创建者 | 拒绝 | 关键 |
| 已结算退款 | ACCEPTED + 创建者 | 拒绝 | 关键 |

---

## 权限审计

### 权限矩阵

| 函数 | 创建者 | Worker | 任何人 | 验证逻辑 |
|------|--------|--------|--------|---------|
| create_task | ✓ | - | - | 无限制 |
| claim_task | - | ✓ | ✓ | 检查状态 |
| submit_result | - | ✓ | - | WorkerCap 验证 |
| accept_result | ✓ | - | - | 地址比较 |
| reject_result | ✓ | - | - | 地址比较 |
| refund | ✓ | - | - | 地址 + 条件 |
| create_dispute | ✓ | ✓ | - | 参与方 + 状态 |
| vote | - | - | ✓ | Reviewer 质押 |
| resolve_dispute | - | - | ✓ | 时间 + 仲裁 |

### 权限检查实现

```move
/// 严格的权限检查模式
module pi::authorization {
    use sui::tx_context::{Self, TxContext};
    
    /// 验证创建者
    public fun assert_creator(
        creator: address,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == creator, ENotCreator);
    }
    
    /// 验证 Worker (通过能力对象)
    public fun assert_worker(
        cap: &WorkerCap,
        ctx: &TxContext,
    ) {
        assert!(cap.worker == tx_context::sender(ctx), ENotWorker);
    }
    
    /// 验证参与者 (创建者或 Worker)
    public fun assert_participant(
        task: &Task,
        ctx: &TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(
            sender == task.creator || 
            (option::is_some(&task.worker) && sender == option::destroy_some(task.worker)),
            ENotParticipant
        );
    }
}
```

---

## 结算安全

### 资金安全原则

```move
module pi::settlement_security {
    /// 结算前检查清单
    public fun pre_settlement_checks(
        task: &Task,
        budget: &Balance<SUI>,
    ): bool {
        // 1. 状态正确
        if (task.status != STATUS_ACCEPTED && 
            task.status != STATUS_RESOLVED) {
            return false
        };
        
        // 2. 预算充足
        if (balance::value(budget) == 0) {
            return false
        };
        
        // 3. Worker 已指定
        if (option::is_none(&task.worker)) {
            return false
        };
        
        true
    }
    
    /// 原子结算
    public fun atomic_settlement(
        budget: &mut Balance<SUI>,
        allocations: vector<Allocation>,
        ctx: &mut TxContext,
    ) {
        let total_allocated = 0u64;
        
        // 验证总分配等于余额
        let i = 0;
        while (i < vector::length(&allocations)) {
            let alloc = vector::borrow(&allocations, i);
            total_allocated = total_allocated + alloc.amount;
            i = i + 1;
        };
        
        assert!(total_allocated == balance::value(budget), EAllocationMismatch);
        
        // 执行转账
        i = 0;
        while (i < vector::length(&allocations)) {
            let alloc = vector::borrow(&allocations, i);
            let coin = coin::take(budget, alloc.amount, ctx);
            transfer::public_transfer(coin, alloc.recipient);
            i = i + 1;
        };
        
        // 验证余额为零
        assert!(balance::value(budget) == 0, ESettlementIncomplete);
    }
}
```

### 防重入保护

```move
/// 结算锁
struct SettlementLock has key {
    id: UID,
    task_id: ID,
    locked: bool,
}

/// 带锁的结算
public entry fun settle_with_lock(
    task: &mut Task,
    lock: &mut SettlementLock,
    ctx: &mut TxContext,
) {
    // 验证锁
    assert!(lock.task_id == object::id(task), ELockMismatch);
    assert!(!lock.locked, EReentrancy);
    
    // 加锁
    lock.locked = true;
    
    // 执行结算逻辑...
    
    // 解锁
    lock.locked = false;
}
```

---

## Artifact 验证

### 链上哈希验证

```move
module pi::artifact {
    use sui::hash;
    
    /// 验证结果哈希
    public fun verify_result_hash(
        result_cid: String,
        expected_hash: vector<u8>,
    ): bool {
        let actual_hash = hash::sha3_256(*string::bytes(&result_cid));
        actual_hash == expected_hash
    }
    
    /// 验证 Usage Receipt
    public fun verify_usage_receipt(
        receipt_cid: String,
        task_budget: u64,
    ): bool {
        // 链下验证：下载 receipt 并验证
        // 链上仅存储 CID
        // 争议时验证
        true
    }
}
```

### 争议期保护

```move
/// 结算必须等待争议期结束
public fun assert_dispute_period_elapsed(
    task: &Task,
    ctx: &TxContext,
) {
    if (option::is_some(&task.dispute_end_time)) {
        let dispute_end = *option::borrow(&task.dispute_end_time);
        assert!(
            tx_context::epoch_timestamp_ms(ctx) > dispute_end,
            EDisputePeriodActive
        );
    };
}
```

---

## 经济安全

### 防套利机制

```move
/// 最小任务金额
const MIN_TASK_BUDGET: u64 = 10000000;  // 0.01 SUI

/// 最大 Worker 奖励比例
const MAX_WORKER_PERCENTAGE: u64 = 95;  // 95%

/// 验证任务预算
public fun validate_budget(
    budget: u64,
    execution_budget: u64,
): bool {
    // 最小金额检查
    if (budget < MIN_TASK_BUDGET) {
        return false
    };
    
    // 执行预算不能超过任务预算的 50%
    if (execution_budget > budget / 2) {
        return false
    };
    
    true
}

/// 验证费用分配
public fun validate_fee_distribution(
    worker_amount: u64,
    platform_amount: u64,
    total: u64,
): bool {
    // 总和检查
    if (worker_amount + platform_amount > total) {
        return false
    };
    
    // Worker 比例检查
    if (worker_amount > (total * MAX_WORKER_PERCENTAGE) / 100) {
        return false
    };
    
    true
}
```

### 时间锁保护

```move
/// 最小争议期
const MIN_DISPUTE_PERIOD: u64 = 86400000;  // 24小时

/// 最大任务超时
const MAX_TASK_TIMEOUT: u64 = 2592000000;  // 30天

/// 验证时间参数
public fun validate_timing(
    timeout: u64,
    dispute_period: u64,
): bool {
    if (timeout > MAX_TASK_TIMEOUT) {
        return false
    };
    
    if (dispute_period < MIN_DISPUTE_PERIOD) {
        return false
    };
    
    true
}
```

---

## 审计检查清单

### 代码审计

- [ ] **权限检查**
  - [ ] 所有修改状态的函数都有权限检查
  - [ ] 使用 `assert!` 而非 `if` + abort
  - [ ] 错误信息清晰

- [ ] **状态机**
  - [ ] 所有状态转换都经过验证
  - [ ] 没有死状态
  - [ ] 终止状态正确

- [ ] **资金安全**
  - [ ] 所有资金转移都可追踪
  - [ ] 余额检查严格
  - [ ] 防止整数溢出

- [ ] **数学运算**
  - [ ] 乘除顺序正确 (先乘后除)
  - [ ] 使用 `sui::math` 的 `mul_div`
  - [ ] 避免精度损失

### 测试审计

- [ ] **单元测试覆盖**
  - [ ] 每个公共函数都有测试
  - [ ] 边界条件测试
  - [ ] 错误路径测试

- [ ] **集成测试**
  - [ ] 完整任务生命周期
  - [ ] 争议流程
  - [ ] 并发场景

- [ ] **模糊测试**
  - [ ] 随机输入测试
  - [ ] 状态机探索

### 部署审计

- [ ] **升级安全**
  - [ ] 升级权限控制
  - [ ] 状态迁移测试
  - [ ] 回滚计划

- [ ] **参数验证**
  - [ ] 费用参数合理
  - [ ] 时间参数合理
  - [ ] 质押要求合理

---

## 常见漏洞与防护

### 1. 重入攻击

```move
// 危险：外部调用前未修改状态
public fun dangerous_withdraw(
    account: &mut Account,
    ctx: &mut TxContext,
) {
    let amount = account.balance;
    // 外部调用
    transfer::public_transfer(coin::take(&mut account.coin, amount, ctx), sender);
    // 状态修改在后
    account.balance = 0;
}

// 安全：先修改状态
public fun safe_withdraw(
    account: &mut Account,
    ctx: &mut TxContext,
) {
    let amount = account.balance;
    // 先修改状态
    account.balance = 0;
    // 再外部调用
    transfer::public_transfer(coin::take(&mut account.coin, amount, ctx), sender);
}
```

### 2. 整数溢出

```move
// 使用 safe math
public fun safe_add(a: u64, b: u64): u64 {
    assert!(a <= 18446744073709551615u64 - b, EOverflow);
    a + b
}

// 或使用标准库
use sui::math::add;
```

### 3. 权限提升

```move
// 危险：依赖外部传入的地址
public fun dangerous_action(
    claimed_owner: address,  // 不可信
    ctx: &mut TxContext,
) {
    // 应该使用 tx_context::sender(ctx)
}
```

---

## 与 Solana 的安全对比

| 漏洞类型 | Solana | Sui |
|----------|--------|-----|
| **重入攻击** | 需要手动防护 | Move 资源模型天然防护 |
| **整数溢出** | 自动回绕 | 自动 abort (debug) |
| **未初始化账户** | 常见漏洞 | Move 强制初始化 |
| **权限绕过** | 签名验证 | 对象所有权 |
| **CPI 攻击** | 需要验证 | 无 CPI 等效概念 |

---

## 下一步

- [17-sui-indexer-and-observability.md](./17-sui-indexer-and-observability.md) - 索引与可观测性
- [18-sui-implementation-checklist.md](./18-sui-implementation-checklist.md) - 实现清单

---

*本文档与 pi Sui 安全审计同步更新*
