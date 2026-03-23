# Sui 任务市场与 Worker 选择

> 任务分配、资格认领、Specialization 与 Stake/Reputation 的关系

---

## 市场机制概览

Sui 的对象模型为任务市场提供了高效的基础设施：

```
┌─────────────────────────────────────────────────────────────┐
│                        任务市场                              │
├─────────────────────────────────────────────────────────────┤
│  任务池 (共享对象)                                           │
│  ├── 按类型索引                                               │
│  ├── 按难度索引                                               │
│  ├── 按奖励排序                                               │
│  └── 按时间排序                                               │
├─────────────────────────────────────────────────────────────┤
│  Worker 池                                                  │
│  ├── 在线状态 (动态对象)                                       │
│  ├── 能力标签                                                │
│  ├── 声誉分数                                                │
│  └── 质押金额                                                │
└─────────────────────────────────────────────────────────────┘
```

---

## 任务索引系统

### 多维度索引

```move
module pi::market {
    use sui::object::{UID, ID};
    use sui::table::{Self, Table};
    use sui::vec_set::{Self, VecSet};
    
    /// 任务市场索引 - 共享对象
    struct TaskMarket has key {
        id: UID,
        
        // 按状态索引
        pending_tasks: VecSet<ID>,
        claimed_tasks: Table<ID, address>,  // task_id -> worker
        
        // 按类型索引
        tasks_by_type: Table<String, VecSet<ID>>,
        
        // 按难度索引
        tasks_by_difficulty: Table<u8, VecSet<ID>>,
        
        // 按奖励范围索引
        tasks_by_reward: Table<u64, VecSet<ID>>,  // bucket -> tasks
        
        // 总统计
        total_tasks: u64,
        total_workers: u64,
    }
    
    /// Worker 市场信息
    struct WorkerMarketInfo has key {
        id: UID,
        worker: address,
        
        // 在线状态
        is_online: bool,
        last_heartbeat: u64,
        
        // 能力
        capabilities: VecSet<String>,
        
        // 市场参数
        min_reward: u64,
        max_concurrent_tasks: u64,
        current_tasks: u64,
        
        // 声誉与质押
        reputation_score: u64,
        staked_amount: u64,
    }
}
```

### 索引更新

```move
/// 添加任务到市场索引
public fun index_task(
    market: &mut TaskMarket,
    task_id: ID,
    task_type: String,
    difficulty: u8,
    reward: u64,
) {
    // 添加到待处理集合
    vec_set::insert(&mut market.pending_tasks, task_id);
    
    // 按类型索引
    if (!table::contains(&market.tasks_by_type, task_type)) {
        table::add(&mut market.tasks_by_type, task_type, vec_set::empty());
    };
    let type_set = table::borrow_mut(&mut market.tasks_by_type, task_type);
    vec_set::insert(type_set, task_id);
    
    // 按难度索引
    if (!table::contains(&market.tasks_by_difficulty, difficulty)) {
        table::add(&mut market.tasks_by_difficulty, difficulty, vec_set::empty());
    };
    let diff_set = table::borrow_mut(&mut market.tasks_by_difficulty, difficulty);
    vec_set::insert(diff_set, task_id);
    
    // 按奖励范围索引 (每 0.1 SUI 一个 bucket)
    let reward_bucket = reward / 100000000;
    if (!table::contains(&market.tasks_by_reward, reward_bucket)) {
        table::add(&mut market.tasks_by_reward, reward_bucket, vec_set::empty());
    };
    let reward_set = table::borrow_mut(&mut market.tasks_by_reward, reward_bucket);
    vec_set::insert(reward_set, task_id);
    
    market.total_tasks = market.total_tasks + 1;
}

/// 从索引移除 (任务被认领)
public fun remove_from_index(
    market: &mut TaskMarket,
    task_id: ID,
    worker: address,
) {
    vec_set::remove(&mut market.pending_tasks, &task_id);
    table::add(&mut market.claimed_tasks, task_id, worker);
}
```

---

## Worker 选择算法

### 链下选择 (推荐)

```typescript
// src/market/selection.ts
export class WorkerSelector {
    /// 为任务选择最佳 Worker
    async selectWorkerForTask(
        task: Task,
        candidates: WorkerProfile[],
    ): Promise<WorkerProfile | null> {
        // 过滤不符合条件的
        const eligible = candidates.filter(w =>
            w.isOnline &&
            w.currentTasks < w.maxConcurrentTasks &&
            w.reputationScore >= this.minReputation &&
            w.stakedAmount >= this.minStake &&
            this.hasRequiredCapabilities(w, task.requiredCapabilities)
        );
        
        if (eligible.length === 0) return null;
        
        // 计算综合分数
        const scored = eligible.map(w => ({
            worker: w,
            score: this.calculateScore(w, task),
        }));
        
        // 排序并返回最佳
        scored.sort((a, b) => b.score - a.score);
        return scored[0].worker;
    }
    
    /// 计算 Worker 分数
    private calculateScore(worker: WorkerProfile, task: Task): number {
        // 声誉权重: 40%
        const reputationScore = worker.reputationScore / 10000 * 0.4;
        
        // 质押权重: 20%
        const stakeScore = Math.min(worker.stakedAmount / 1000000000, 1) * 0.2;
        
        // 能力匹配权重: 20%
        const capabilityScore = this.calculateCapabilityMatch(
            worker.capabilities,
            task.requiredCapabilities
        ) * 0.2;
        
        // 负载权重: 10% (倾向于空闲 Worker)
        const loadScore = (1 - worker.currentTasks / worker.maxConcurrentTasks) * 0.1;
        
        // 响应速度权重: 10%
        const responseScore = this.calculateResponseScore(worker) * 0.1;
        
        return reputationScore + stakeScore + capabilityScore + loadScore + responseScore;
    }
}
```

### 链上资格验证

```move
/// 检查 Worker 是否有资格认领特定任务
public fun check_eligibility(
    worker_info: &WorkerMarketInfo,
    task: &Task,
    min_reputation: u64,
    min_stake: u64,
): bool {
    // 检查在线状态
    if (!worker_info.is_online) return false;
    
    // 检查负载
    if (worker_info.current_tasks >= worker_info.max_concurrent_tasks) return false;
    
    // 检查声誉
    if (worker_info.reputation_score < min_reputation) return false;
    
    // 检查质押
    if (worker_info.staked_amount < min_stake) return false;
    
    // 检查能力匹配
    let required = task::get_required_capabilities(task);
    let i = 0;
    while (i < vector::length(&required)) {
        let cap = vector::borrow(&required, i);
        if (!vec_set::contains(&worker_info.capabilities, cap)) {
            return false
        };
        i = i + 1;
    };
    
    true
}
```

---

## 动态定价

### 基于供需的价格调整

```move
module pi::pricing {
    /// 市场状态
    struct MarketState has key {
        id: UID,
        
        // 供需指标
        pending_task_count: u64,
        online_worker_count: u64,
        
        // 价格乘数 (10000 = 1x)
        price_multiplier: u64,
        
        // 历史数据
        avg_task_completion_time: u64,
        avg_worker_response_time: u64,
        
        last_updated: u64,
    }
    
    /// 计算动态价格
    public fun calculate_dynamic_price(
        state: &MarketState,
        base_price: u64,
    ): u64 {
        // 供需比
        let ratio = if (state.online_worker_count > 0) {
            (state.pending_task_count * 10000) / state.online_worker_count
        } else {
            20000  // 无 Worker 时高价
        };
        
        // 动态调整
        let multiplier = if (ratio > 15000) {
            // 供不应求: 1.5x - 2x
            15000 + min(5000, (ratio - 15000) / 2)
        } else if (ratio < 5000) {
            // 供过于求: 0.8x - 1x
            8000 + (ratio * 2000) / 5000
        } else {
            // 平衡: 1x
            10000
        };
        
        (base_price * multiplier) / 10000
    }
}
```

---

## Worker 注册与发现

### Worker 注册流程

```move
/// Worker 注册
public entry fun register_worker(
    market: &mut TaskMarket,
    capabilities: vector<String>,
    min_reward: u64,
    max_concurrent: u64,
    ctx: &mut TxContext,
) {
    let worker = tx_context::sender(ctx);
    
    let info = WorkerMarketInfo {
        id: object::new(ctx),
        worker,
        is_online: true,
        last_heartbeat: tx_context::epoch_timestamp_ms(ctx),
        capabilities: vec_set::from_vec(capabilities),
        min_reward,
        max_concurrent_tasks: max_concurrent,
        current_tasks: 0,
        reputation_score: 5000,  // 初始值
        staked_amount: 0,
    };
    
    transfer::share_object(info);
    
    market.total_workers = market.total_workers + 1;
}

/// 心跳更新在线状态
public entry fun heartbeat(
    info: &mut WorkerMarketInfo,
    ctx: &mut TxContext,
) {
    assert!(info.worker == tx_context::sender(ctx), ENotOwner);
    
    info.last_heartbeat = tx_context::epoch_timestamp_ms(ctx);
    info.is_online = true;
}

/// 检查 Worker 是否仍然在线 (链下调用)
public fun check_online(info: &WorkerMarketInfo, current_time: u64): bool {
    // 5分钟无心跳视为离线
    (current_time - info.last_heartbeat) < 300000
}
```

---

## 任务匹配策略

### 最佳匹配算法

```typescript
// src/market/matcher.ts
export class TaskMatcher {
    /// 批量匹配任务和 Worker
    async matchTasksAndWorkers(
        tasks: Task[],
        workers: WorkerProfile[],
    ): Promise<Match[]> {
        const matches: Match[] = [];
        
        // 按奖励排序任务 (优先匹配高价值任务)
        const sortedTasks = tasks.sort((a, b) => 
            Number(b.budget - a.budget)
        );
        
        // 可用 Worker 池
        const availableWorkers = workers.filter(w => 
            w.isOnline && w.currentTasks < w.maxConcurrentTasks
        );
        
        for (const task of sortedTasks) {
            const bestWorker = this.findBestMatch(task, availableWorkers);
            
            if (bestWorker) {
                matches.push({ task, worker: bestWorker });
                
                // 更新 Worker 负载
                bestWorker.currentTasks++;
                if (bestWorker.currentTasks >= bestWorker.maxConcurrentTasks) {
                    // 从可用池移除
                    const idx = availableWorkers.indexOf(bestWorker);
                    availableWorkers.splice(idx, 1);
                }
            }
        }
        
        return matches;
    }
    
    /// 查找最佳匹配
    private findBestMatch(
        task: Task,
        workers: WorkerProfile[],
    ): WorkerProfile | null {
        let bestWorker: WorkerProfile | null = null;
        let bestScore = 0;
        
        for (const worker of workers) {
            // 基础过滤
            if (worker.minReward > task.budget) continue;
            if (!this.hasCapabilities(worker, task)) continue;
            
            // 计算匹配分数
            const score = this.calculateMatchScore(worker, task);
            
            if (score > bestScore) {
                bestScore = score;
                bestWorker = worker;
            }
        }
        
        return bestWorker;
    }
}
```

---

## 质押与声誉的关系

### 质押 tiers

```move
/// 质押等级
const TIER_1_STAKE: u64 = 1000000000;      // 1 SUI
const TIER_2_STAKE: u64 = 10000000000;     // 10 SUI
const TIER_3_STAKE: u64 = 100000000000;    // 100 SUI

/// 根据质押获取奖励加成
public fun get_stake_multiplier(staked: u64): u64 {
    if (staked >= TIER_3_STAKE) {
        150  // 1.5x
    } else if (staked >= TIER_2_STAKE) {
        125  // 1.25x
    } else if (staked >= TIER_1_STAKE) {
        110  // 1.1x
    } else {
        100  // 1x
    }
}

/// 根据声誉获取任务优先级
public fun get_reputation_priority(score: u64): u8 {
    if (score >= 9000) {
        5  // 最高优先级
    } else if (score >= 7000) {
        4
    } else if (score >= 5000) {
        3
    } else if (score >= 3000) {
        2
    } else {
        1  // 最低优先级
    }
}
```

---

## 市场健康指标

### 监控指标

```move
/// 市场健康状态
struct MarketHealth has copy, drop {
    // 供需
    pending_tasks: u64,
    active_workers: u64,
    tasks_per_worker: u64,
    
    // 效率
    avg_claim_time: u64,      // 任务发布到认领的平均时间
    avg_completion_time: u64, // 任务认领到完成的平均时间
    
    // 质量
    dispute_rate: u64,        // 争议率 (万分比)
    avg_satisfaction: u64,    // 平均满意度 (0-10000)
    
    // 经济
    total_volume_24h: u64,
    avg_task_value: u64,
    price_volatility: u64,
}

/// 计算市场健康分数
public fun calculate_health_score(health: &MarketHealth): u64 {
    // 供需平衡 (30%)
    let supply_demand_score = if (health.tasks_per_worker < 3) {
        10000  // 理想: 每个 Worker < 3 个任务
    } else if (health.tasks_per_worker < 10) {
        10000 - (health.tasks_per_worker - 3) * 500
    } else {
        0
    };
    
    // 效率 (30%)
    let efficiency_score = if (health.avg_claim_time < 60000) {
        10000
    } else {
        10000 - min(5000, (health.avg_claim_time - 60000) / 100)
    };
    
    // 质量 (20%)
    let quality_score = 10000 - health.dispute_rate * 10;
    let quality_score = if (quality_score > 10000) { 10000 } else { quality_score };
    
    // 活跃度 (20%)
    let activity_score = min(10000, health.total_volume_24h / 1000000000);  // 每 10 SUI = 1 分
    
    (supply_demand_score * 30 + efficiency_score * 30 + quality_score * 20 + activity_score * 20) / 100
}
```

---

## 与 Solana 的对比

| 方面 | Solana | Sui |
|------|--------|-----|
| **任务索引** | 链下索引器 | 链上 Table + VecSet |
| **Worker 状态** | 账户数据 | 对象字段 |
| **匹配算法** | 链下计算 | 链下为主，链上验证 |
| **资格检查** | 签名验证 | 对象读取 |
| **更新频率** | 受限于区块时间 | 简单交易快速确认 |

---

## 下一步

- [16-sui-security-and-audit.md](./16-sui-security-and-audit.md) - 安全与审计
- [17-sui-indexer-and-observability.md](./17-sui-indexer-and-observability.md) - 索引与可观测性

---

*本文档与 pi Sui 市场实现同步更新*
