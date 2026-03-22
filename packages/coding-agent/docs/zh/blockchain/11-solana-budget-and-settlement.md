# Solana 预算与结算设计

> 在《Solana MVP 草案》和《Solana Program 指令设计》的基础上，继续细化 Solana 主线里最关键的一层：预算、执行成本、worker 奖励、退款与最终结算的闭合方式。

这篇文档的目标是回答：

- 为什么预算必须拆层
- 执行成本与 worker 奖励如何分账
- 链上与链下如何协作结算
- MVP 阶段如何先做“可闭合”而不是“完全自动化”

---

## 1. 为什么结算设计是 Solana MVP 的核心

如果没有明确的预算与结算设计，任务系统很容易出现以下问题：

1. 不知道模型调用到底花了多少钱
2. 不知道 worker 奖励和模型成本是否混在一起
3. reject / reopen 时不知道哪些钱该退
4. dispute 时无法审计费用是否合理
5. 系统看似能跑，实际无法长期运营

所以对于 Solana MVP：

> 任务发布只是入口，**预算闭合与结算闭合** 才是系统能否成立的底层约束。

---

## 2. 最小预算结构：必须拆成三层

MVP 阶段也不建议只设置一个总金额，而应该至少拆成：

### 2.1 Execution Budget

用于支付：
- LLM token 成本
- 外部 API 成本
- 工具/存储相关成本

### 2.2 Worker Reward

用于支付：
- 完成任务后给 worker 的固定或约定奖励

### 2.3 Platform Fee

用于支付：
- 平台手续费
- reviewer / arbitration fee（MVP 可先为 0）

### 为什么这三层必须分开

如果只写：
- `total_budget = 100 USDC`

你就无法判断：
- 这 100 里多少是模型成本
- 多少是 worker 奖励
- reject 时哪些部分可以退
- settlement 时怎么审计

---

## 3. 推荐的预算结构

建议 `EscrowVault` 或关联预算对象至少能表达：

| 字段 | 说明 |
|------|------|
| `reward_amount` | 任务成功后支付给 worker 的奖励 |
| `execution_budget_cap` | 本任务可消耗的最大执行预算 |
| `platform_fee_cap` | 平台费用上限 |
| `execution_spent` | 已消耗执行成本 |
| `reward_paid` | 已支付奖励 |
| `platform_fee_paid` | 已支付平台费用 |
| `refund_amount` | 最终退款金额 |

### 关键原则

- `cap` 是上限
- `spent` / `paid` 是结算结果
- `refund` 是闭合校验的一部分

---

## 4. 链上与链下的职责分工

MVP 阶段不建议一开始就完全链上计费，而应采用：

### 链上负责
- 锁定预算
- 保证 reward 可支付
- 记录 settlement 结果
- 资金释放与退款

### 链下负责
- 真实模型调用
- usage receipts 记录
- cost summary 聚合
- execution manifest 生成

### 为什么这是更现实的做法

因为如果一开始就想把：
- 每次 token 使用
- 每次 provider 调用
- 每次 retry / fallback

都做成链上逐步记账，会极大提高：
- Program 复杂度
- provider 对接复杂度
- dispute 成本
- 开发周期

所以 MVP 更适合：

> **链上锁预算，链下算成本，链上做最终 settlement。**

---

## 5. 推荐的结算公式

任务结算时，建议满足以下守恒关系：

```text
total_funded
= execution_cost_total
+ worker_reward_paid
+ platform_fee_paid
+ refund_amount
```

### 说明

- `total_funded`：EscrowVault 实际注资总额
- `execution_cost_total`：模型/API/工具等执行成本总额
- `worker_reward_paid`：支付给 worker 的奖励
- `platform_fee_paid`：平台费 / reviewer fee
- `refund_amount`：退回给创建者的余额

### 这是最重要的闭合条件

无论任务成功、失败、reject、partial accept，都应回到这个公式检查。

---

## 6. 三种结算场景

---

## 6.1 成功验收（Accepted）

### 路径

```text
Task: Submitted -> Accepted -> Settled
```

### 结算建议

- `worker_reward_paid = reward_amount`
- `execution_cost_total = 实际 cost summary`
- `platform_fee_paid = 约定平台费`
- 剩余部分退款

### 公式示意

```text
refund_amount = total_funded - execution_cost_total - reward_amount - platform_fee_paid
```

---

## 6.2 结果被拒绝（Rejected）

### 路径

```text
Task: Submitted -> Rejected -> Open / Refunded
```

### 结算建议

这里最关键的是：
- **worker 奖励不一定发放**
- **执行成本不一定可以全退**，因为真实 token 成本可能已经发生

### 推荐做法

- `worker_reward_paid = 0`（MVP 默认）
- `execution_cost_total = 已经发生的真实成本`
- `refund_amount = total_funded - execution_cost_total - platform_fee_paid`

### 为什么 reject 不代表全额退款

因为模型调用成本通常已经实际发生，不可能因为结果不满意就被外部 provider 自动免掉。

---

## 6.3 部分结果可用（未来扩展）

虽然 MVP 可暂不实现，但结构上应预留：
- 部分 reward
- 部分 accept
- partial settlement

例如：
- 分析报告可用，但 patch 不通过
- 结果需要少量补修

这在后续 dispute / reviewer 系统中会很有用。

---

## 7. `cost-summary.json` 最小结构建议

由于 MVP 阶段执行成本主要在链下核算，建议至少输出一份 `cost-summary.json`：

```json
{
  "taskId": "task-123",
  "workerId": "worker-abc",
  "currency": "USDC",
  "providerCosts": [
    {
      "provider": "anthropic",
      "model": "claude-sonnet-4",
      "inputTokens": 12000,
      "outputTokens": 2200,
      "cachedTokens": 4000,
      "totalCost": "0.84"
    }
  ],
  "executionCostTotal": "0.84",
  "generatedAt": "2026-03-22T00:00:00Z"
}
```

### 为什么先做这个文件

因为它可以在不增加链上复杂度的前提下：
- 支撑 settlement
- 支撑 reviewer 审核
- 为后续 x402 / MMP / usage receipts 预留接口

---

## 8. `settle_task` 建议如何处理输入

在 Solana Program 里，`settle_task` 可以接收：

| 参数 | 说明 |
|------|------|
| `execution_cost_total` | 本次任务的执行成本汇总 |
| `worker_reward_paid` | 发给 worker 的奖励 |
| `platform_fee_paid` | 发给平台的费用 |
| `refund_amount` | 退款金额 |
| `cost_summary_uri` | 成本摘要地址 |

### Program 应检查什么

1. 任务状态必须是 `Accepted`（或支持的 rejected/partial 分支）
2. 所有金额必须非负
3. 四项金额必须闭合到 escrow 总资金
4. `worker_reward_paid` 不得超过预设 reward
5. `execution_cost_total` 不得超过 `execution_budget_cap`

---

## 9. 为什么 `execution_budget_cap` 必须强校验

这是防止 worker 乱花预算的核心边界。

### 没有 cap 会发生什么

- worker 可无限调用模型
- 成本远超任务预期
- 最后只能靠人工 dispute
- 预算体系失去意义

### MVP 阶段的正确做法

即使 execution cost 是链下汇总：
- Program 也必须在结算时检查 `execution_cost_total <= execution_budget_cap`
- 超出部分默认不能被结算
- 要么 worker 自己承担，要么进入特殊 review

---

## 10. 推荐的退款策略

### 成功任务
退款 = 未使用 execution budget 的剩余部分

### 被拒绝任务
退款 = 总预算 - 已真实发生 execution cost - 已约定 fee

### 超时任务
可选策略：
- 若几乎没执行 → 大部分退款
- 若已发生执行成本 → 扣除 execution cost 后退款

### 原则

退款不应基于“心情”，而应基于：
- 预算上限
- 已发生成本
- 奖励是否满足发放条件

---

## 11. 与支付层文档的对应关系

Solana 主线里的 budget / settlement 并不是孤立的，它和支付层专题中的：
- `Budget`
- `UsageReceipt`
- `SettlementRecord`
- `Policy`

一一对应。

### 当前 Solana MVP 的现实做法

现在这篇的意思是：
- 链上先实现 `Budget` 与 `SettlementRecord`
- `UsageReceipt` 先主要存在链下
- `Policy` 先以 Program 约束 + worker 运行时约束混合实现

### 未来增强方向

等接入 x402 / MMP 后，可以逐渐让：
- usage receipts 更细粒度
- allowance 更自动化
- settlement 更少依赖人工汇总

---

## 12. MVP 的审计重点

如果有人要审计 Solana MVP，最值得关注：

1. 预算是否拆分清晰
2. settlement 是否守恒
3. reject / reopen / settle 是否存在越权或双花路径
4. `execution_budget_cap` 是否被正确约束
5. refund 是否可能被错误计算

---

## 13. 建议的推进顺序

### 第一阶段
- 固定 reward + execution budget + manual settlement
- 先确保闭合公式成立

### 第二阶段
- 标准化 cost-summary.json
- 更细粒度 usage receipt
- 部分自动校验

### 第三阶段
- 接入 x402 / MMP
- allowance 驱动支付
- provider receipt / challenge / dispute 联动

---

## 14. 一句话总结

**Solana MVP 的预算与结算设计，核心不是“把每一笔 token 成本都立刻上链”，而是先把 `execution budget / worker reward / platform fee / refund` 四层资金关系拆清楚，并让 settlement 在链上严格闭合；只有这一步做稳了，后续才有资格引入更细粒度的支付 rail、receipt 和 dispute 机制。**
