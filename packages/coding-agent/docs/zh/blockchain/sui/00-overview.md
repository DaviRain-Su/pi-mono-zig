# Sui 专题总览

> pi-worker 与 Sui 区块链集成的专题文档

---

## 与 Solana 专题的区别

虽然 Solana 和 Sui 都是高性能 Layer 1 区块链，但它们在架构设计上有本质区别：

| 特性 | Solana | Sui |
|------|--------|-----|
| **编程模型** | 账户模型 | 对象模型 |
| **智能合约语言** | Rust (Anchor) | Move |
| **共识机制** | PoH + PoS | Mysticeti (BFT) |
| **交易并行性** | 需要指定账户 | 对象级并行，自动检测 |
| **状态管理** | 账户存储 | 对象所有权 |
| **Gas 模型** | 基于计算单元 | 基于存储 + 计算 |

这些差异影响了 pi-worker 与链的集成方式。

---

## Sui 核心概念

### 对象模型 (Object Model)

Sui 的一切都是对象：

```move
// Sui 中的对象定义示例
struct Task has key, store {
    id: UID,
    creator: address,
    bounty: Balance<SUI>,
    status: u8,  // 0=pending, 1=claimed, 2=completed
}
```

**关键特性：**
- 每个对象有唯一 ID (`UID`)
- 对象有所有者（地址、共享、不可变）
- 交易明确指定输入对象
- 同一交易中的不相关对象可以并行执行

### 所有权类型

```move
// 1. 地址拥有
struct PersonalTask has key {
    id: UID,
    owner: address,
}

// 2. 共享对象（任何人可读写）
struct SharedTaskPool has key {
    id: UID,
}

// 3. 不可变对象
const TASK_RULES: vector<u8> = b"rules...";
```

### 交易类型

| 类型 | 说明 | 延迟 |
|------|------|------|
| **简单交易** | 仅涉及拥有对象，无共享对象 | ~400ms |
| **复杂交易** | 涉及共享对象，需共识 | ~1-2s |
| **程序化交易** | 多操作原子批处理 | 同上 |

---

## pi-worker 在 Sui 上的优势

### 1. 自然适合任务模型

Sui 的对象模型与 pi-worker 的任务概念天然契合：

```
Task Object (共享)
    ├── 创建 → 任何人可读
    ├── 认领 → 所有权转移给 Worker
    ├── 提交 → 状态变更
    └── 结算 → 资金释放
```

### 2. 更低的 Worker 操作延迟

- **任务发现**: 简单查询，无共识延迟
- **任务认领**: 单写操作，~400ms 确认
- **结果提交**: 状态变更，~400ms 确认

### 3. 更好的可组合性

Move 的模块系统允许任务合约轻松组合：

```move
// 任务 + 支付 + 声誉 可组合
use task::TaskManager;
use payment::Escrow;
use reputation::ReputationSystem;
```

---

## 文档结构

### 基础层
- [01-roadmap.md](./01-roadmap.md) - Sui 集成路线图
- [02-task-models.md](./02-task-models.md) - Sui 任务模型设计
- [03-llm-payment-layer.md](./03-llm-payment-layer.md) - LLM 支付层
- [04-task-execution-flow.md](./04-task-execution-flow.md) - 任务执行时序
- [05-verifiable-artifacts.md](./05-verifiable-artifacts.md) - 可验证 Artifact
- [06-policy-and-guardrails.md](./06-policy-and-guardrails.md) - Policy 设计

### Sui 主线
- [10-sui-mvp-design.md](./10-sui-mvp-design.md) - MVP 账户/对象模型
- [11-sui-contract-instructions.md](./11-sui-contract-instructions.md) - Move 合约指令
- [12-sui-budget-and-settlement.md](./12-sui-budget-and-settlement.md) - 预算与结算
- [13-sui-worker-runtime-integration.md](./13-sui-worker-runtime-integration.md) - Worker 集成
- [14-sui-dispute-and-reputation.md](./14-sui-dispute-and-reputation.md) - 争议与声誉
- [15-sui-market-and-selection.md](./15-sui-market-and-selection.md) - 任务市场
- [16-sui-security-and-audit.md](./16-sui-security-and-audit.md) - 安全与审计
- [17-sui-indexer-and-observability.md](./17-sui-indexer-and-observability.md) - 索引与观测
- [18-sui-implementation-checklist.md](./18-sui-implementation-checklist.md) - 实现清单

---

## 阅读顺序建议

1. **快速理解** (30分钟)
   - 本文件 (00-overview.md)
   - 01-roadmap.md - 了解路线图差异

2. **深入设计** (2小时)
   - 02-task-models.md - 理解 Sui 对象模型如何映射任务
   - 10-sui-mvp-design.md - 最小可行对象设计
   - 11-sui-contract-instructions.md - Move 合约核心逻辑

3. **实现细节** (按需)
   - 12-sui-budget-and-settlement.md - 经济模型
   - 13-sui-worker-runtime-integration.md - Worker 接入
   - 18-sui-implementation-checklist.md - 开发清单

---

## 与 Solana 实现的核心差异

### 1. 状态存储

**Solana:**
```rust
// PDA 派生账户
pub struct Task {
    pub creator: Pubkey,
    pub bounty: u64,
}
```

**Sui:**
```move
// 对象，可转移、可共享
struct Task has key, store {
    id: UID,
    creator: address,
    bounty: Balance<SUI>,
}
```

### 2. 权限控制

**Solana:**
```rust
// 手动检查签名
require!(creator == task.creator, Error::Unauthorized);
```

**Sui:**
```move
// Move 语言级所有权检查
assert!(tx_context::sender(ctx) == task.creator, EUnauthorized);
```

### 3. 资金托管

**Solana:**
```rust
// 需要单独的 Token Account
let escrow = TokenAccount::create_pda(...);
```

**Sui:**
```move
// 对象直接持有 Balance
struct Task has key {
    bounty: Balance<SUI>,  // 内嵌托管
}
```

---

## 技术资源

### Sui 官方文档
- [Sui Documentation](https://docs.sui.io/)
- [Move Book](https://move-book.com/)
- [Sui TypeScript SDK](https://sdk.mystenlabs.com/typescript)

### 工具
- **Sui CLI**: `cargo install sui`
- **Move 编译器**: 内置于 Sui CLI
- **测试网**: `sui client switch --env testnet`

### pi 相关
- [Solana 实现对比](../09-solana-mvp-design.md) - 了解 Solana 实现后再看 Sui
- [Worker Runtime](../../guide/08-first-extension.md) - Worker 基础

---

## 当前状态

| 组件 | 状态 | 说明 |
|------|------|------|
| 概念设计 | 📝 进行中 | 本文档及路线图 |
| Move 合约 | ⏳ 待开发 | 需要 Move 开发者 |
| Worker 集成 | ⏳ 待开发 | 依赖合约完成 |
| 测试网部署 | ⏳ 待部署 | 等待合约开发 |

---

*本文档与 pi Sui 集成同步更新*
