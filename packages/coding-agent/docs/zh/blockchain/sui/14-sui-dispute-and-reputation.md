# Sui 争议与声誉设计

> 争议状态机、Reviewer 模型与声誉指标设计

---

## 争议机制概览

Sui 的对象模型为争议处理提供了天然优势：

```
┌─────────────┐    create_dispute    ┌─────────────┐
│   Task      │─────────────────────▶│  Dispute    │
│  SUBMITTED  │                      │   (共享)     │
└─────────────┘                      └──────┬──────┘
                                            │
                              vote          │
                              (Reviewer)    ▼
                              ┌─────────────┐
                              │   Voting    │
                              │   Period    │
                              └──────┬──────┘
                                     │
                              resolve│
                                     ▼
                              ┌─────────────┐
                              │   Resolved  │
                              │  (资金分配)  │
                              └─────────────┘
```

---

## 争议对象设计

### 核心对象

```move
module pi::dispute {
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::vec_set::{Self, VecSet};
    use std::string::String;
    use std::option::{Self, Option};
    
    // ===== 状态常量 =====
    const STATUS_OPEN: u8 = 0;
    const STATUS_VOTING: u8 = 1;
    const STATUS_RESOLVED: u8 = 2;
    
    // ===== 错误码 =====
    const EInvalidStatus: u64 = 0;
    const ENotEligible: u64 = 1;
    const EAlreadyVoted: u64 = 2;
    const EVotingEnded: u64 = 3;
    const EVotingNotEnded: u64 = 4;
    const EInvalidTaskStatus: u64 = 5;
    
    /// 争议对象 - 共享
    struct Dispute has key {
        id: UID,
        task_id: ID,
        initiator: address,
        reason_cid: String,
        status: u8,
        created_at: u64,
        voting_deadline: u64,
        
        // 投票统计
        votes_for_worker: u64,
        votes_for_creator: u64,
        total_voting_power: u64,
        
        // 投票记录 (投票人 -> 投票详情)
        votes: Table<address, Vote>,
        
        // 结果
        resolution: Option<bool>,  // true=worker wins
        resolved_at: Option<u64>,
        resolver: Option<address>,
    }
    
    /// 投票详情
    struct Vote has store, copy, drop {
        voter: address,
        support_worker: bool,
        weight: u64,
        timestamp: u64,
        rationale_cid: Option<String>,  // IPFS 链接到理由
    }
    
    /// 争议配置
    struct DisputeConfig has key {
        id: UID,
        min_stake_to_vote: u64,
        voting_period_ms: u64,
        min_voters: u64,
        quorum_percentage: u64,  // 比如 51
    }
}
```

---

## 争议生命周期

### 1. 发起争议

```move
public entry fun create_dispute(
    task: &mut Task,
    reason_cid: String,
    config: &DisputeConfig,
    ctx: &mut TxContext,
): ID {
    // 验证任务状态
    assert!(task::get_status(task) == task::STATUS_SUBMITTED(), EInvalidTaskStatus);
    
    let now = tx_context::epoch_timestamp_ms(ctx);
    let caller = tx_context::sender(ctx);
    
    // 验证争议期
    let dispute_end = option::destroy_some(task::get_dispute_end_time(task));
    assert!(now <= dispute_end, EVotingEnded);
    
    // 更新任务状态
    task::set_status(task, task::STATUS_DISPUTED());
    
    // 创建争议对象
    let dispute = Dispute {
        id: object::new(ctx),
        task_id: object::id(task),
        initiator: caller,
        reason_cid,
        status: STATUS_OPEN,
        created_at: now,
        voting_deadline: now + config.voting_period_ms,
        votes_for_worker: 0,
        votes_for_creator: 0,
        total_voting_power: 0,
        votes: table::new(ctx),
        resolution: option::none(),
        resolved_at: option::none(),
        resolver: option::none(),
    };
    
    let dispute_id = object::id(&dispute);
    transfer::share_object(dispute);
    
    event::emit(DisputeCreated {
        dispute_id,
        task_id: object::id(task),
        initiator: caller,
        voting_deadline: now + config.voting_period_ms,
    });
    
    dispute_id
}
```

### 2. 投票机制

```move
/// Reviewer 信息
struct ReviewerInfo has key {
    id: UID,
    owner: address,
    staked_amount: u64,
    reputation_score: u64,
    total_votes_cast: u64,
    correct_votes: u64,
}

public entry fun vote(
    dispute: &mut Dispute,
    reviewer: &ReviewerInfo,
    support_worker: bool,
    rationale_cid: Option<String>,
    config: &DisputeConfig,
    ctx: &mut TxContext,
) {
    // 验证争议状态
    assert!(dispute.status == STATUS_OPEN || dispute.status == STATUS_VOTING, EInvalidStatus);
    
    let now = tx_context::epoch_timestamp_ms(ctx);
    assert!(now <= dispute.voting_deadline, EVotingEnded);
    
    let voter = tx_context::sender(ctx);
    
    // 验证投票资格
    assert!(reviewer.owner == voter, ENotEligible);
    assert!(reviewer.staked_amount >= config.min_stake_to_vote, ENotEligible);
    assert!(!table::contains(&dispute.votes, voter), EAlreadyVoted);
    
    // 计算投票权重 (基于质押 + 声誉)
    let weight = calculate_voting_weight(reviewer);
    
    // 记录投票
    let vote = Vote {
        voter,
        support_worker,
        weight,
        timestamp: now,
        rationale_cid,
    };
    
    table::add(&mut dispute.votes, voter, vote);
    dispute.total_voting_power = dispute.total_voting_power + weight;
    
    if (support_worker) {
        dispute.votes_for_worker = dispute.votes_for_worker + weight;
    } else {
        dispute.votes_for_creator = dispute.votes_for_creator + weight;
    };
    
    dispute.status = STATUS_VOTING;
    
    // 检查是否达到仲裁条件
    if (can_resolve(dispute, config) {
        dispute.status = STATUS_RESOLVED;
        resolve_dispute_internal(dispute, ctx);
    };
    
    event::emit(VoteCast {
        dispute_id: object::id(dispute),
        voter,
        support_worker,
        weight,
    });
}

/// 计算投票权重
fun calculate_voting_weight(reviewer: &ReviewerInfo): u64 {
    // 基础权重 = 质押金额
    let base_weight = reviewer.staked_amount;
    
    // 声誉加成 (最高 2x)
    let reputation_multiplier = 100 + (reviewer.reputation_score / 100);
    let reputation_multiplier = if (reputation_multiplier > 200) {
        200
    } else {
        reputation_multiplier
    };
    
    (base_weight * reputation_multiplier) / 100
}

/// 检查是否可以解决
fun can_resolve(dispute: &Dispute, config: &DisputeConfig): bool {
    // 最小投票人数
    if (table::length(&dispute.votes) < config.min_voters) {
        return false
    };
    
    // 达到法定人数
    let total_votes = dispute.votes_for_worker + dispute.votes_for_creator;
    let quorum = (dispute.total_voting_power * config.quorum_percentage) / 100;
    
    total_votes >= quorum
}
```

### 3. 解决争议

```move
public entry fun resolve_dispute(
    dispute: &mut Dispute,
    config: &DisputeConfig,
    ctx: &mut TxContext,
) {
    assert!(dispute.status == STATUS_VOTING, EInvalidStatus);
    
    let now = tx_context::epoch_timestamp_ms(ctx);
    assert!(now > dispute.voting_deadline, EVotingNotEnded);
    
    resolve_dispute_internal(dispute, ctx);
}

fun resolve_dispute_internal(
    dispute: &mut Dispute,
    ctx: &mut TxContext,
) {
    let now = tx_context::epoch_timestamp_ms(ctx);
    let resolver = tx_context::sender(ctx);
    
    // 确定结果
    let worker_wins = dispute.votes_for_worker > dispute.votes_for_creator;
    
    dispute.resolution = option::some(worker_wins);
    dispute.resolved_at = option::some(now);
    dispute.resolver = option::some(resolver);
    dispute.status = STATUS_RESOLVED;
    
    // 奖励正确的投票者
    reward_correct_voters(dispute, worker_wins, ctx);
    
    event::emit(DisputeResolved {
        dispute_id: object::id(dispute),
        task_id: dispute.task_id,
        worker_wins,
        votes_for_worker: dispute.votes_for_worker,
        votes_for_creator: dispute.votes_for_creator,
    });
}

/// 奖励正确的投票者
fun reward_correct_voters(
    dispute: &Dispute,
    worker_wins: bool,
    ctx: &mut TxContext,
) {
    // 计算奖励池 (来自争议储备)
    let reward_pool = get_dispute_reward_pool(dispute.task_id);
    
    // 统计正确票数
    let correct_votes = if (worker_wins) {
        dispute.votes_for_worker
    } else {
        dispute.votes_for_creator
    };
    
    // 分配奖励给正确的投票者
    let votes = &dispute.votes;
    let i = 0;
    while (i < table::length(votes)) {
        let (voter, vote) = table::get_idx(votes, i);
        if (vote.support_worker == worker_wins) {
            let reward = (vote.weight * reward_pool) / correct_votes;
            transfer::public_transfer(
                coin::from_balance(balance::create(reward), ctx),
                voter
            );
            
            // 更新 Reviewer 声誉
            update_reviewer_reputation(voter, true);
        } else {
            // 惩罚错误的投票者
            update_reviewer_reputation(voter, false);
        };
        i = i + 1;
    };
}
```

---

## 声誉系统

### Worker 声誉

```move
module pi::reputation {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::TxContext;
    
    /// Worker 声誉记录
    struct WorkerReputation has key {
        id: UID,
        worker: address,
        
        // 基础统计
        total_tasks: u64,
        completed_tasks: u64,
        disputed_tasks: u64,
        
        // 质量指标
        total_rating_sum: u64,  // 所有评分的总和
        rating_count: u64,
        
        // 计算声誉
        reputation_score: u64,  // 0-10000
        
        // 时间衰减
        last_active: u64,
        streak_completed: u64,  // 连续完成数
    }
    
    /// 声誉事件
    struct ReputationUpdated has copy, drop {
        worker: address,
        old_score: u64,
        new_score: u64,
        reason: u8,  // 0=task, 1=dispute, 2=timeout
    }
    
    /// 初始化声誉记录
    public entry fun register_worker_reputation(
        ctx: &mut TxContext,
    ) {
        let rep = WorkerReputation {
            id: object::new(ctx),
            worker: tx_context::sender(ctx),
            total_tasks: 0,
            completed_tasks: 0,
            disputed_tasks: 0,
            total_rating_sum: 0,
            rating_count: 0,
            reputation_score: 5000,  // 初始中等声誉
            last_active: tx_context::epoch_timestamp_ms(ctx),
            streak_completed: 0,
        };
        
        transfer::transfer(rep, tx_context::sender(ctx));
    }
    
    /// 完成任务后更新
    public fun update_on_completion(
        rep: &mut WorkerReputation,
        rating: u8,  // 1-5
        ctx: &mut TxContext,
    ) {
        let old_score = rep.reputation_score;
        
        rep.total_tasks = rep.total_tasks + 1;
        rep.completed_tasks = rep.completed_tasks + 1;
        rep.total_rating_sum = rep.total_rating_sum + (rating as u64);
        rep.rating_count = rep.rating_count + 1;
        rep.streak_completed = rep.streak_completed + 1;
        rep.last_active = tx_context::epoch_timestamp_ms(ctx);
        
        // 计算新声誉
        rep.reputation_score = calculate_score(rep);
        
        event::emit(ReputationUpdated {
            worker: rep.worker,
            old_score,
            new_score: rep.reputation_score,
            reason: 0,
        });
    }
    
    /// 争议后更新
    public fun update_on_dispute(
        rep: &mut WorkerReputation,
        worker_won: bool,
        ctx: &mut TxContext,
    ) {
        let old_score = rep.reputation_score;
        
        rep.total_tasks = rep.total_tasks + 1;
        rep.disputed_tasks = rep.disputed_tasks + 1;
        rep.streak_completed = 0;  // 重置连续完成
        
        if (worker_won) {
            // 争议胜诉，小幅加分
            rep.reputation_score = min(10000, rep.reputation_score + 100);
        } else {
            // 争议败诉，大幅扣分
            rep.reputation_score = if (rep.reputation_score > 500) {
                rep.reputation_score - 500
            } else {
                0
            };
        };
        
        rep.last_active = tx_context::epoch_timestamp_ms(ctx);
        
        event::emit(ReputationUpdated {
            worker: rep.worker,
            old_score,
            new_score: rep.reputation_score,
            reason: 1,
        });
    }
    
    /// 计算声誉分数
    fun calculate_score(rep: &WorkerReputation): u64 {
        if (rep.total_tasks == 0) {
            return 5000
        };
        
        // 基础分数 (完成任务率)
        let completion_rate = (rep.completed_tasks * 10000) / rep.total_tasks;
        
        // 质量分数 (平均评分)
        let quality_score = if (rep.rating_count > 0) {
            (rep.total_rating_sum * 2000) / rep.rating_count  // 5分制转 10000
        } else {
            5000
        };
        
        // 连续性加成
        let streak_bonus = min(1000, rep.streak_completed * 50);
        
        // 加权平均
        let score = (completion_rate * 40 + quality_score * 40) / 100 + streak_bonus;
        
        min(10000, score)
    }
    
    /// 检查 Worker 是否有资格接任务
    public fun is_eligible(rep: &WorkerReputation, min_score: u64): bool {
        rep.reputation_score >= min_score
    }
}
```

### Reviewer 声誉

```move
/// Reviewer 声誉
struct ReviewerReputation has key {
    id: UID,
    reviewer: address,
    staked_amount: u64,
    total_votes: u64,
    correct_votes: u64,
    accuracy_score: u64,  // 0-10000
    reputation_score: u64,  // 综合分数
}

/// 更新 Reviewer 声誉
public fun update_reviewer_on_vote(
    rep: &mut ReviewerReputation,
    correct: bool,
    ctx: &mut TxContext,
) {
    rep.total_votes = rep.total_votes + 1;
    
    if (correct) {
        rep.correct_votes = rep.correct_votes + 1;
    };
    
    // 更新准确率
    rep.accuracy_score = (rep.correct_votes * 10000) / rep.total_votes;
    
    // 综合分数 = 准确率 60% + 参与度 40%
    let participation = min(10000, (rep.total_votes * 100) / 100);  // 100票满
    rep.reputation_score = (rep.accuracy_score * 60 + participation * 40) / 100;
}
```

---

## 质押与惩罚

### Worker 质押

```move
module pi::staking {
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::coin::Coin;
    
    /// Worker 质押
    struct WorkerStake has key {
        id: UID,
        worker: address,
        amount: Balance<SUI>,
        staked_at: u64,
        locked_until: u64,
    }
    
    /// 质押
    public entry fun stake(
        amount: Coin<SUI>,
        lock_period: u64,
        ctx: &mut TxContext,
    ) {
        let stake = WorkerStake {
            id: object::new(ctx),
            worker: tx_context::sender(ctx),
            amount: coin::into_balance(amount),
            staked_at: tx_context::epoch_timestamp_ms(ctx),
            locked_until: tx_context::epoch_timestamp_ms(ctx) + lock_period,
        };
        
        transfer::share_object(stake);
    }
    
    /// 惩罚 (争议败诉)
    public fun slash(
        stake: &mut WorkerStake,
        percentage: u64,  // 0-100
        ctx: &mut TxContext,
    ): Coin<SUI> {
        let slash_amount = (balance::value(&stake.amount) * percentage) / 100;
        let slashed = coin::take(&mut stake.amount, slash_amount, ctx);
        
        event::emit(WorkerSlashed {
            worker: stake.worker,
            amount: slash_amount,
            percentage,
        });
        
        slashed
    }
}
```

---

## 声誉衰减机制

```move
/// 应用时间衰减
public fun apply_decay(
    rep: &mut WorkerReputation,
    ctx: &mut TxContext,
) {
    let now = tx_context::epoch_timestamp_ms(ctx);
    let days_inactive = (now - rep.last_active) / 86400000;
    
    if (days_inactive > 30) {
        // 超过30天不活跃，每天衰减 1%
        let decay = (days_inactive - 30) * 100;  // 每天 1%
        let decay = if (decay > 3000) { 3000 } else { decay };  // 最大 30%
        
        rep.reputation_score = rep.reputation_score * (10000 - decay) / 10000;
    };
}
```

---

## 与 Solana 的对比

| 方面 | Solana | Sui |
|------|--------|-----|
| **争议对象** | PDA 账户 | 共享对象 |
| **投票存储** | 单独账户 | Table (链上 Map) |
| **声誉查询** | 账户读取 | 对象读取 |
| **质押管理** | Token Account | Balance |
| **惩罚执行** | 转账 | 销毁或转移 |

---

## 下一步

- [15-sui-market-and-selection.md](./15-sui-market-and-selection.md) - 任务市场与 Worker 选择
- [16-sui-security-and-audit.md](./16-sui-security-and-audit.md) - 安全与审计

---

*本文档与 pi Sui 争议与声誉实现同步更新*
