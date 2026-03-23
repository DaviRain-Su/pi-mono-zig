# Sui 预算与结算设计

> 执行预算、Worker 奖励、退款与结算闭合

---

## 概述

Sui 的 Gas 模型与 Solana 不同，影响预算设计：

| 特性 | Solana | Sui |
|------|--------|-----|
| **Gas 计算** | 计算单元 (CU) | 按存储 + 计算 |
| **存储费用** | 租金 (可退还) | 永久存储费用 |
| **Gas 对象** | 不需要 | 必须提供 |
| **预算预估** | 相对固定 | 需要预计算 |

---

## 预算模型

### 双层预算

```
┌─────────────────────────────────────────┐
│           任务总预算 (Total Budget)        │
├─────────────────────────────────────────┤
│  执行预算 (Execution Budget)              │
│  ├── LLM API 调用费用                      │
│  ├── Token 使用量                          │
│  └── 工具执行成本                          │
├─────────────────────────────────────────┤
│  Worker 奖励 (Worker Reward)              │
│  ├── 基础奖励                              │
│  ├── 质量奖金                              │
│  └── 时效奖金                              │
├─────────────────────────────────────────┤
│  平台费用 (Platform Fee) ~5-10%           │
├─────────────────────────────────────────┤
│  争议储备 (Dispute Reserve) ~2-5%         │
└─────────────────────────────────────────┘
```

### Move 实现

```move
module pi::budget {
    use sui::balance::Balance;
    use sui::sui::SUI;
    
    /// 预算分配
    struct BudgetAllocation has store {
        execution_budget: u64,      // LLM tokens
        worker_reward: u64,         // SUI
        platform_fee: u64,          // SUI
        dispute_reserve: u64,       // SUI
    }
    
    /// 创建预算分配
    public fun allocate_budget(
        total_budget: u64,
        execution_budget: u64,
    ): BudgetAllocation {
        let platform_fee = (total_budget * 5) / 100;  // 5%
        let dispute_reserve = (total_budget * 3) / 100;  // 3%
        let worker_reward = total_budget - platform_fee - dispute_reserve;
        
        BudgetAllocation {
            execution_budget,
            worker_reward,
            platform_fee,
            dispute_reserve,
        }
    }
}
```

---

## 结算流程

### 1. 正常结算流程

```
创建任务
    │
    ▼
┌─────────────────┐
│ 资金锁定在 Task  │
│ 对象中           │
└────────┬────────┘
         │
    任务完成
         │
         ▼
┌─────────────────┐
│ 创建者验收        │
│ accept_result()  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 资金分配          │
├── Worker: 92%    │
├── Platform: 5%   │
└── Reserve: 3%   │
         │
         ▼
┌─────────────────┐
│ 结算完成          │
└─────────────────┘
```

### 2. Move 实现

```move
module pi::settlement {
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::tx_context::TxContext;
    
    /// 平台费用接收地址
    const PLATFORM_ADDRESS: address = @0x...;
    
    /// 争议储备池
    struct DisputePool has key {
        id: UID,
        balance: Balance<SUI>,
    }
    
    /// 正常结算
    public fun settle_accepted(
        budget: &mut Balance<SUI>,
        worker: address,
        ctx: &mut TxContext,
    ) {
        let total = balance::value(budget);
        
        // 计算分配
        let platform_fee = (total * 5) / 100;
        let dispute_reserve = (total * 3) / 100;
        let worker_reward = total - platform_fee - dispute_reserve;
        
        // 分配给 Worker
        let worker_coin = coin::take(budget, worker_reward, ctx);
        transfer::public_transfer(worker_coin, worker);
        
        // 平台费用
        let platform_coin = coin::take(budget, platform_fee, ctx);
        transfer::public_transfer(platform_coin, PLATFORM_ADDRESS);
        
        // 争议储备 (留在对象中或转入池)
        let reserve_coin = coin::take(budget, dispute_reserve, ctx);
        // 转入争议池...
    }
    
    /// 退款结算
    public fun settle_refund(
        budget: &mut Balance<SUI>,
        creator: address,
        ctx: &mut TxContext,
    ) {
        let amount = balance::value(budget);
        let coin = coin::take(budget, amount, ctx);
        transfer::public_transfer(coin, creator);
    }
    
    /// 争议解决结算
    public fun settle_dispute(
        budget: &mut Balance<SUI>,
        worker: address,
        creator: address,
        worker_wins: bool,
        ctx: &mut TxContext,
    ) {
        let total = balance::value(budget);
        
        if (worker_wins) {
            // Worker 获胜：获得 90%，创建者获得 10% 退款
            let worker_amount = (total * 90) / 100;
            let refund_amount = total - worker_amount;
            
            let worker_coin = coin::take(budget, worker_amount, ctx);
            transfer::public_transfer(worker_coin, worker);
            
            let refund_coin = coin::take(budget, refund_amount, ctx);
            transfer::public_transfer(refund_coin, creator);
        } else {
            // 创建者获胜：全额退款
            settle_refund(budget, creator, ctx);
        }
    }
}
```

---

## Gas 费用预估

### 各操作 Gas 成本 (测试网估算)

| 操作 | 存储费用 | 计算费用 | 总费用 (SUI) |
|------|---------|---------|-------------|
| create_task | ~0.001 | ~0.0001 | ~0.0011 |
| claim_task | ~0.0005 | ~0.0001 | ~0.0006 |
| submit_result | ~0.0005 | ~0.0001 | ~0.0006 |
| accept_result | ~0.0001 | ~0.0001 | ~0.0002 |
| create_dispute | ~0.001 | ~0.0001 | ~0.0011 |
| vote | ~0.0003 | ~0.0001 | ~0.0004 |

### 预算预留建议

```move
/// Gas 预留常量
const GAS_RESERVE_CREATE: u64 = 2000000;    // 0.002 SUI
const GAS_RESERVE_CLAIM: u64 = 1000000;     // 0.001 SUI
const GAS_RESERVE_SUBMIT: u64 = 1000000;    // 0.001 SUI
const GAS_RESERVE_SETTLE: u64 = 500000;     // 0.0005 SUI
```

---

## 动态定价

### 基于难度的定价

```move
module pi::pricing {
    /// 任务难度等级
    const DIFFICULTY_EASY: u8 = 1;
    const DIFFICULTY_MEDIUM: u8 = 2;
    const DIFFICULTY_HARD: u8 = 3;
    const DIFFICULTY_EXPERT: u8 = 4;
    
    /// 计算任务价格
    public fun calculate_price(
        base_price: u64,
        difficulty: u8,
        estimated_tokens: u64,
        urgency_hours: u64,
    ): u64 {
        // 难度系数
        let difficulty_multiplier = match difficulty {
            1 => 100,  // 1x
            2 => 150,  // 1.5x
            3 => 250,  // 2.5x
            4 => 400,  // 4x
            _ => 100,
        };
        
        // 紧急系数 (24小时内)
        let urgency_multiplier = if (urgency_hours <= 24) {
            150  // 1.5x
        } else if (urgency_hours <= 72) {
            120  // 1.2x
        } else {
            100  // 1x
        };
        
        // Token 成本估算 (~$0.01 per 1K tokens)
        let token_cost = (estimated_tokens * 10000) / 1000000;
        
        let base = base_price + token_cost;
        (base * difficulty_multiplier * urgency_multiplier) / 10000
    }
}
```

---

## 争议储备池

### 设计

```move
module pi::dispute_pool {
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::coin::Coin;
    
    /// 争议储备池 - 共享对象
    struct DisputePool has key {
        id: UID,
        balance: Balance<SUI>,
        total_contributed: u64,
        total_distributed: u64,
    }
    
    /// 贡献记录
    struct Contribution has copy, drop, store {
        task_id: ID,
        amount: u64,
        timestamp: u64,
    }
    
    /// 初始化池
    fun init(ctx: &mut TxContext) {
        let pool = DisputePool {
            id: object::new(ctx),
            balance: balance::zero(),
            total_contributed: 0,
            total_distributed: 0,
        };
        transfer::share_object(pool);
    }
    
    /// 存入争议储备
    public fun contribute(
        pool: &mut DisputePool,
        amount: Coin<SUI>,
        task_id: ID,
        ctx: &mut TxContext,
    ) {
        let value = coin::value(&amount);
        balance::join(&mut pool.balance, coin::into_balance(amount));
        pool.total_contributed = pool.total_contributed + value;
        
        event::emit(Contribution {
            task_id,
            amount: value,
            timestamp: tx_context::epoch_timestamp_ms(ctx),
        });
    }
    
    /// 从池中分配资金 (仅治理)
    public fun distribute(
        pool: &mut DisputePool,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext,
    ): Coin<SUI> {
        // 权限检查...
        pool.total_distributed = pool.total_distributed + amount;
        coin::take(&mut pool.balance, amount, ctx)
    }
}
```

---

## Worker 奖励计算

### 基础 + 绩效模型

```
Worker 奖励 = 基础奖励 × 质量系数 × 时效系数 + 额外奖金

基础奖励 = 任务预算 × 92%

质量系数:
- 创建者评分 5星: 1.2x
- 创建者评分 4星: 1.1x
- 创建者评分 3星: 1.0x
- 创建者评分 <3星: 0.8x

时效系数:
- 提前 50% 时间: 1.3x
- 提前 25% 时间: 1.15x
- 按时: 1.0x
- 超时: 0.8x (每超 10% 减少 0.1)
```

### Move 实现

```move
module pi::reward {
    /// 计算 Worker 奖励
    public fun calculate_reward(
        base_reward: u64,
        quality_score: u8,      // 1-5
        time_ratio: u64,        // 实际用时/预计用时 (百分比)
    ): u64 {
        // 质量系数
        let quality_multiplier = match quality_score {
            5 => 120,
            4 => 110,
            3 => 100,
            2 => 80,
            1 => 60,
            _ => 100,
        };
        
        // 时效系数
        let time_multiplier = if (time_ratio <= 50) {
            130
        } else if (time_ratio <= 75) {
            115
        } else if (time_ratio <= 100) {
            100
        } else if (time_ratio <= 110) {
            90
        } else if (time_ratio <= 120) {
            80
        } else {
            70
        };
        
        let reward = (base_reward * quality_multiplier * time_multiplier) / 10000;
        reward
    }
}
```

---

## 结算时序

### 正常流程时序

```
T+0:    任务创建，资金锁定
        │
T+1:    Worker 认领
        │
T+N:    Worker 提交结果
        │
T+N+1:  创建者验收
        │
        ├── 验收通过
        │   └── 立即结算 (Worker 92%, Platform 5%, Reserve 3%)
        │
        └── 验收拒绝
            └── 进入争议流程
```

### 争议流程时序

```
T+N:    提交结果
        │
T+N+X:  创建者发起争议 (X < 争议期)
        │
T+N+X+3d: 投票结束
        │
        ├── Worker 胜
        │   └── Worker 90%, Creator 10%
        │
        └── Creator 胜
            └── Creator 100%
```

---

## 与 Solana 的对比

| 方面 | Solana | Sui |
|------|--------|-----|
| **资金托管** | 需要单独 Token Account | 对象直接持有 Balance |
| **结算延迟** | ~400ms | ~200ms (简单交易) |
| **Gas 成本** | ~0.000005 SOL | ~0.001 SUI |
| **存储成本** | 租金 (可回收) | 永久 (不可回收) |
| **批处理** | 需要自定义指令 | 原生 PTB 支持 |

---

## 下一步

- [13-sui-worker-runtime-integration.md](./13-sui-worker-runtime-integration.md) - Worker Runtime 集成
- [14-sui-dispute-and-reputation.md](./14-sui-dispute-and-reputation.md) - 争议与声誉

---

*本文档与 pi Sui 结算实现同步更新*
