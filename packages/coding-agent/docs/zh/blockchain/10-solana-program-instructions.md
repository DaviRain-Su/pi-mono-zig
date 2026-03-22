# Solana Program 指令设计

> 在《Solana MVP 草案》的基础上，继续向协议层细化：Solana Program 应该暴露哪些最小 instruction，它们的输入、状态迁移与约束如何设计。

本文重点不是 Rust 代码，而是：
- instruction 粒度
- 状态迁移
- 账户关系
- 约束与 guardrails

目标是让这条 Solana 主线从“系统想法”进入“协议草案”。

---

## 1. 设计原则

Solana 版 Program 建议遵守以下 5 个原则：

### 1.1 状态迁移最小化

每个 instruction 只负责：
- 一个清晰动作
- 一个明确状态变化
- 尽量少的副作用

这样更适合：
- 审计
- dispute
- future replay

### 1.2 链上只存关键状态

Program 不应直接存：
- 长报告
- 大 patch
- HTML playground 全文
- usage receipt 全量原文

链上建议只存：
- 状态
- 金额
- hash
- uri
- authority 关系

### 1.3 预算与奖励分开

Program 层必须区分：
- `execution_budget`
- `worker_reward`
- `platform_fee`

否则 settlement 与 dispute 无法说清。

### 1.4 先人工验收，再自动化

MVP 阶段的 instruction 设计应优先支持：
- manual acceptance
- manual reopen
- manual reject

而不是一开始就追求 fully automated validation。

### 1.5 为 dispute / reputation 预留扩展点

即使第一阶段不实现完整 dispute，也应该在账户关系和字段设计中预留：
- rejection reason
- settlement reason
- result linkage
- worker identity linkage

---

## 2. 最小账户关系回顾

本文默认使用以下账户：

- `TaskAccount`
- `WorkerAccount`
- `ClaimAccount`
- `EscrowVault`
- `ResultAccount`
- `SettlementAccount`

后续可扩展：
- `ReputationAccount`
- `DisputeAccount`
- `PolicyAccount`
- `AllowanceAccount`

---

## 3. 最小 instruction 列表

MVP 建议至少有 7 条 instruction：

1. `create_task`
2. `fund_task`
3. `claim_task`
4. `submit_result`
5. `accept_result`
6. `reject_result`
7. `settle_task`

后续增强可加：
- `reopen_task`
- `cancel_claim`
- `expire_claim`
- `open_dispute`
- `resolve_dispute`
- `update_reputation`

---

## 4. `create_task`

### 作用

由任务创建者初始化一个任务，但任务此时可以还是 `Draft`，尚未开放领取。

### 输入建议

| 参数 | 说明 |
|------|------|
| `task_id` | 唯一任务标识 |
| `title` | 标题 |
| `category` | analysis / patch / report / plan |
| `spec_uri` | 任务说明地址 |
| `reward_amount` | worker 奖励 |
| `execution_budget` | 执行预算上限 |
| `deadline_ts` | 截止时间 |
| `acceptance_mode` | MVP 建议只支持 manual |

### 账户

- signer: `creator`
- writable: `TaskAccount`
- optional: `EscrowVault`（可只初始化不注资）

### 状态变化

```text
Task: [new] -> Draft
```

### 约束

- `reward_amount > 0`
- `execution_budget >= 0`
- `deadline_ts` 必须晚于当前时间
- `spec_uri` 非空

---

## 5. `fund_task`

### 作用

向 escrow 注资，并将任务从 `Draft` 激活到 `Open`。

### 输入建议

| 参数 | 说明 |
|------|------|
| `token_mint` | 结算代币 |
| `reward_amount` | 注入 reward 部分 |
| `execution_budget` | 注入 execution 部分 |
| `platform_fee` | 平台费用（可选） |

### 账户

- signer: `creator`
- writable: `TaskAccount`
- writable: `EscrowVault`
- token accounts / token program

### 状态变化

```text
Task: Draft -> Open
Escrow: Funded
```

### 约束

- 只能由 `creator` 调用
- 任务必须是 `Draft`
- 注资金额需与任务金额一致或覆盖任务需求

### 为什么单独拆出这条 instruction

因为任务创建与资金锁定最好分开：
- 便于先编辑任务草稿
- 便于检查预算后再开放领取

---

## 6. `claim_task`

### 作用

由 worker 认领任务，生成独立 `ClaimAccount`。

### 输入建议

| 参数 | 说明 |
|------|------|
| `claim_id` | claim 唯一标识 |
| `execution_manifest_uri` | 初始执行清单地址（可为空，后补） |
| `expire_at` | 认领超时时间 |

### 账户

- signer: `worker owner`
- readonly: `WorkerAccount`
- writable: `TaskAccount`
- writable: `ClaimAccount`

### 状态变化

```text
Task: Open -> Claimed
Claim: [new] -> Active
```

### 约束

- `Task.status == Open`
- 当前无有效 claim
- `deadline_ts` 未过期
- worker 支持该任务类型
- 如启用 staking：worker 质押需达标

### 为什么不要直接把 worker 写进 Task 就结束

因为后续需要：
- claim 超时
- claim 作废
- 结果与 claim 绑定
- 多次重开与多轮认领

---

## 7. `submit_result`

### 作用

worker 执行完成后，提交结果承诺与相关 metadata。

### 输入建议

| 参数 | 说明 |
|------|------|
| `result_id` | 结果唯一 ID |
| `artifact_uri` | 结果 bundle 地址 |
| `artifact_hash` | 结果哈希 |
| `summary_hash` | 摘要哈希 |
| `result_type` | report / patch / json / html |
| `cost_summary_uri` | 费用摘要地址 |
| `execution_manifest_uri` | 最终执行清单地址 |

### 账户

- signer: `worker owner`
- writable: `TaskAccount`
- writable: `ClaimAccount`
- writable: `ResultAccount`

### 状态变化

```text
Claim: Active -> Submitted
Task: Claimed -> Submitted
```

### 约束

- 只有当前 claim 对应 worker 可提交
- 任务必须是 `Claimed`
- claim 未超时
- `artifact_hash` / `summary_hash` 必须非空

### 注意点

MVP 阶段不建议把 usage receipts 全塞链上，保留：
- `cost_summary_uri`
- 结果 hash
- manifest uri

就足够。

---

## 8. `accept_result`

### 作用

由任务创建者或指定 reviewer 人工验收通过结果。

### 输入建议

| 参数 | 说明 |
|------|------|
| `accept_reason_uri` | 可选的验收说明 |

### 账户

- signer: `creator` 或 `reviewer`
- writable: `TaskAccount`
- readonly: `ResultAccount`
- writable: `SettlementAccount`（可延迟到 `settle_task`）

### 状态变化

```text
Task: Submitted -> Accepted
```

### 约束

- 任务必须处于 `Submitted`
- 调用者必须有验收权限

### 为什么 accept 与 settle 分开

这样更灵活：
- 先确认结果
- 再执行资金释放
- 便于 settlement 逻辑独立审计

---

## 9. `reject_result`

### 作用

拒绝结果，并给出拒绝原因；MVP 阶段允许任务重新开放。

### 输入建议

| 参数 | 说明 |
|------|------|
| `reject_reason_uri` | 拒绝原因地址 |
| `reopen` | 是否重新开放任务 |

### 账户

- signer: `creator` 或 `reviewer`
- writable: `TaskAccount`
- writable: `ClaimAccount`
- readonly: `ResultAccount`

### 状态变化

两种推荐路径：

#### 方案 A：先变 Rejected，再手动 reopen
```text
Task: Submitted -> Rejected
```

#### 方案 B：直接 reopen（MVP 更省指令）
```text
Task: Submitted -> Open
Claim: Submitted -> Cancelled / Closed
```

### 我的建议

MVP 可以先采用 **方案 B**，减少状态复杂度；
后续 dispute 正式加入后，再独立出 `Rejected` / `Disputed`。

---

## 10. `settle_task`

### 作用

在 accept 后释放奖励与剩余预算，并记录 settlement 结果。

### 输入建议

| 参数 | 说明 |
|------|------|
| `execution_cost_total` | 本任务执行成本总额 |
| `worker_reward_paid` | 实际发放给 worker 的奖励 |
| `platform_fee_paid` | 平台费用 |
| `refund_amount` | 退回给创建者的金额 |

### 账户

- signer: creator / reviewer / protocol authority（按设计选择）
- writable: `TaskAccount`
- writable: `EscrowVault`
- writable: `SettlementAccount`
- worker / creator token accounts

### 状态变化

```text
Task: Accepted -> Settled
Escrow: Locked -> Released / Refunded
Settlement: [new] -> Final
```

### 约束

- 只有 `Accepted` 的任务可结算
- `execution_cost_total + worker_reward_paid + platform_fee_paid + refund_amount`
  必须与 escrow 资金闭合

### MVP 简化建议

第一阶段：
- `execution_cost_total` 由链下 `cost-summary.json` 汇总后人工确认
- Program 先只负责最终发放与记账，不做链上逐次计费

---

## 11. 推荐的 PDA 关系

建议按以下种子派生：

### `TaskAccount`
```text
a["task", task_id]
```

### `WorkerAccount`
```text
a["worker", worker_owner]
```

### `ClaimAccount`
```text
a["claim", task_id, claim_id]
```

### `EscrowVault`
```text
a["escrow", task_id]
```

### `ResultAccount`
```text
a["result", task_id, result_id]
```

### `SettlementAccount`
```text
a["settlement", task_id]
```

这样好处是：
- 查询路径清晰
- 每个 task 的相关对象容易聚合
- 方便前端 / indexer / worker 监听

---

## 12. Program 层最重要的 5 个 guardrails

### 12.1 状态机约束
每个 instruction 只能在合法状态下执行。

### 12.2 authority 约束
- creator 只能创建 / funding / accept / reject
- worker 只能 claim / submit
- 其他角色不应越权

### 12.3 资金闭合约束
settlement 必须保证资金守恒。

### 12.4 时间约束
- 认领超时
- 任务截止
- 结果提交窗口

### 12.5 hash/uri 非空约束
关键 artifact 承诺字段不能缺失。

---

## 13. `pi-worker` 与 Program 的最小接口需求

为了稳定接入 Solana Program，worker 至少要支持：

1. 查询 `Open` 任务
2. 读取 `spec_uri`
3. 生成 `execution_manifest`
4. 生成 artifact bundle
5. 生成 `cost-summary.json`
6. 调用 `claim_task` / `submit_result`
7. 监听 accept / reject / settle 结果

---

## 14. 从 MVP 到下一阶段的指令扩展

下一阶段可以新增：

### `reopen_task`
显式从 `Rejected` 重新开放。

### `expire_claim`
超时 claim 由任何人或 keeper 触发关闭。

### `open_dispute`
结果被 challenge 时进入 dispute 分支。

### `resolve_dispute`
由 reviewer / arbiter 决定 accept / reject / slash。

### `update_reputation`
从 settlement 或 dispute 结果中更新声誉。

---

## 15. 一句话总结

**Solana MVP Program 的核心不是做一个庞杂的“全功能 agent 合约”，而是把 `create_task / fund_task / claim_task / submit_result / accept_result / reject_result / settle_task` 这组最小 instruction 设计清楚，让任务状态、资金状态、结果承诺和 worker 认领形成可审计、可扩展、可逐步演进的协议骨架。**
