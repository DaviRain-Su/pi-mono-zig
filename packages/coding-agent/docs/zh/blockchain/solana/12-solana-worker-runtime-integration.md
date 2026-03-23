# Solana Worker Runtime 集成

> 讨论 `pi-worker` / `pi-mono` 如何作为链下 runtime，与 Solana 任务系统稳定对接。

前面的文档已经定义了：
- 任务模型
- 支付层
- artifact
- guardrails
- Solana MVP
- Solana Program 指令与预算结算

这一篇的目标是把这些设计真正连到运行时，回答：

- worker 如何发现任务？
- worker 如何认领任务？
- worker 如何组织执行清单、artifact bundle、cost summary？
- worker 如何处理 accept / reject / reopen / timeout？

---

## 1. 集成边界：链上负责什么，worker 负责什么

### Solana Program 负责
- 任务状态
- escrow 与预算上限
- 认领关系
- 结果承诺
- 验收状态
- settlement 结果

### `pi-worker` 负责
- 读取任务描述
- 选择技能 / 模型 / 工具
- 真正执行 agent loop
- 生成 artifact 与 receipts
- 提交 result commitment
- 等待并响应 accept / reject / reopen

### 一句话

> Solana 决定“这个任务现在处于什么状态”，`pi-worker` 决定“如何把它真正做出来”。

---

## 2. Worker 的最小职责模型

一个最小可运行的 Solana worker 至少应该具备 6 个职责：

1. `task discovery`
2. `task evaluation`
3. `claim execution`
4. `artifact packaging`
5. `result submission`
6. `post-submit monitoring`

---

## 3. 任务发现（task discovery）

### 目标

持续发现链上 `Open` 状态的任务。

### 可选实现方式

#### 方案 A：定时轮询
- 周期性查询符合条件的 `TaskAccount`

优点：
- 简单
- 容易做 MVP

缺点：
- 反应延迟
- 多 worker 时查询压力增加

#### 方案 B：索引器 / 事件流
- 通过 indexer 或自建订阅服务监听任务状态变化

优点：
- 响应更快
- 更适合平台化

缺点：
- 架构更复杂

### MVP 建议

先从 **定时轮询** 开始。

---

## 4. 任务评估（task evaluation）

发现 `Open` 任务后，worker 不应盲目 claim，而应先做本地判断。

### 最小评估维度

- `category` 是否支持
- `deadline` 是否合理
- `execution_budget` 是否足够
- `reward_amount` 是否值得执行
- `spec_uri` 是否可读取
- 本地 policy 是否允许接这个任务

### 建议实现

本地先形成一个 `task viability decision`：

```json
{
  "taskId": "task-123",
  "canClaim": true,
  "reason": "supported_category_and_budget_ok"
}
```

这有助于：
- 调试
- 审计
- 后续多 worker 决策比较

---

## 5. 认领（claim execution）

### Worker 在认领前应准备什么

建议在发起 `claim_task` 前，本地先生成一个初始执行清单：

- `worker version`
- `pi version`
- `runtime type`
- `planned skill set`
- `planned model scope`
- `planned tool scope`
- `taskId`

### 为什么认领前就要有 manifest 雏形

因为：
- claim 不是“随便抢一个单”
- 而是“我准备用这套能力边界来执行这个任务”

### 认领成功后

本地生成工作目录，例如：

```text
runs/
└── task-123/
    ├── manifest.json
    ├── inputs/
    ├── artifacts/
    └── receipts/
```

---

## 6. 执行（agent loop integration）

### 目标

将链上任务转化为 `pi-worker` 可执行的任务上下文。

### 推荐执行流程

1. 下载 `spec_uri`
2. 读取任务描述与 acceptance mode
3. 选择对应 skill / extension / prompt template
4. 构造本轮任务上下文
5. 运行 `pi-worker` / `pi-mono` runtime
6. 收集结果、artifact、usage 数据

### 最关键的集成点

#### 6.1 task-aware context
worker 在运行时应始终知道：
- `taskId`
- `claimId`
- `creator`
- `execution budget cap`
- `worker reward`
- `policy constraints`

#### 6.2 cost-aware execution
运行中应实时检查：
- 已消耗多少预算
- 是否触发 fallback
- 是否接近上限
- 是否需要中止或降级模型

#### 6.3 artifact-aware output
输出不能只是“终端里有一段文本”，而必须形成标准化文件。

---

## 7. Artifact Bundle 组织建议

### 最小目录结构

```text
runs/task-123/
├── manifest.json
├── spec.json / spec.md
├── artifacts/
│   ├── result.json / report.md / patch.diff / playground.html
│   ├── summary.json
│   └── metadata.json
├── receipts/
│   ├── usage-1.json
│   ├── usage-2.json
│   └── cost-summary.json
└── bundle.json
```

### 文件用途

- `manifest.json`：执行边界
- `result.*`：主要交付物
- `summary.json`：链上摘要引用
- `receipts/*`：成本依据
- `bundle.json`：索引整包内容

### 为什么必须目录化

因为后续需要：
- hash
- upload
- replay
- dispute
- settlement

单文件输出很快就不够。

---

## 8. 结果提交（result submission integration）

### Worker 提交前应做什么

建议提交前本地执行以下步骤：

1. 生成 `artifact_hash`
2. 生成 `summary_hash`
3. 生成 `cost-summary.json`
4. 上传 bundle 到外部存储
5. 更新 `manifest.json` 中的最终元数据
6. 调用 `submit_result`

### 提交时最少链上字段

- `artifact_uri`
- `artifact_hash`
- `summary_hash`
- `result_type`
- `cost_summary_uri`
- `execution_manifest_uri`

### 为什么不能先提交链上再整理文件

因为这样容易出现：
- 链上 hash 和最终 artifact 不一致
- dispute 时无法回放
- settlement 依据不稳定

所以正确顺序应该是：
> **先封包，再提交 commitment。**

---

## 9. 提交后的监控（post-submit monitoring）

结果提交以后，worker 还不能马上退出。

### 需要继续监控的状态

- `Accepted`
- `Rejected`
- `Reopened`
- `Settled`
- `Claim expired`

### 为什么要监控

因为这决定：
- 是否要触发 cleanup
- 是否要重新执行
- 是否要写入本地 reputation 记录
- 是否要归档 artifact bundle

### MVP 建议

先做一个简单状态轮询器，周期查询：
- 任务状态
- claim 状态
- settlement 是否完成

---

## 10. Reject / Reopen 的 worker 处理策略

### 被 Reject 时

worker 应：
- 保留当前 bundle
- 标记状态为 `rejected`
- 记录 reject reason uri
- 不立即覆盖旧结果

### 被 Reopen 时

建议：
- 生成新的运行目录或新的 revision
- 不直接覆写旧 `task-123/` 目录

例如：

```text
runs/
└── task-123/
    ├── attempt-1/
    └── attempt-2/
```

这样更适合：
- 对比失败原因
- dispute 回放
- 后续 reputation / metrics 分析

---

## 11. 超时与中断处理

### 11.1 claim 超时

如果 claim 到期但 worker 还未提交：
- Program 侧可允许 `expire_claim`
- worker 侧应停止继续当作有效任务处理

### 11.2 本地执行中断

如果 worker 在执行中崩溃：
- 运行目录应保留中间 artifact
- 下次启动可尝试恢复或至少保留失败记录

### 11.3 预算耗尽

如果 execution budget 接近上限：
- worker 应提前中止
- 生成 partial summary
- 决定是否提交 partial artifact（若协议允许）

---

## 12. `pi-worker` 最值得补的集成能力

如果要把 Solana 主线真正跑起来，`pi-worker` 最值得优先补的是：

### 12.1 chain adapter
- 查询任务
- 认领任务
- 提交结果
- 轮询状态

### 12.2 manifest generator
- 从 task + worker context 生成标准 `manifest.json`

### 12.3 bundle exporter
- 输出统一 artifact bundle
- 统一 hash / upload / metadata

### 12.4 budget meter
- 把 execution budget 接入 runtime 决策
- 接近上限时发出 guardrail 事件

### 12.5 local audit log
- 记录 claim / execution / submit / accept / reject / settle 的本地历史

---

## 13. 与 Solana 主线其他文档的关系

这篇文档位于：

- `09-solana-mvp-design.md`：讲系统级 MVP
- `10-solana-program-instructions.md`：讲 Program 指令
- `11-solana-budget-and-settlement.md`：讲预算闭合
- **本篇**：讲链下 worker 如何真正接 Program

也就是说：

> 09 讲“做什么”
> 10 讲“链上怎么做”
> 11 讲“钱怎么闭合”
> 12 讲“runtime 怎么接进去”

---

## 14. 一句话总结

**Solana Worker Runtime 集成的关键，不只是“让 `pi-worker` 会调几条链上指令”，而是让它能够把任务上下文、预算边界、artifact bundle、cost summary、状态轮询和 post-submit 监控组织成一个稳定的执行闭环；只有做到这一点，Solana 主线才算真正从协议草案走向可运行系统。**
