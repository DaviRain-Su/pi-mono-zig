# Solana 实现清单

> 作为 Solana 主线专题的收口文档：把前面的路线图、协议、runtime、支付、market、audit、observability 文档整理成一份实际可执行的实现清单。

这篇文档不再新增大的设计概念，而是回答：

- 真要开始做，先做哪些模块？
- 哪些模块必须先有，哪些可以延后？
- 每一阶段的代码、协议、运行时和运营准备分别是什么？

---

## 1. 实现原则

在开始实现前，先确认三条原则：

### 1.1 先闭环，再扩展

优先实现：
- 一条完整可走通的任务链路

而不是优先实现：
- 开放市场
- TEE
- attestation
- 完整 dispute 网络

### 1.2 先看得见，再自动化

如果没有：
- indexer
- dashboard
- 本地 bundle
- cost summary
- 基本告警

就不要太早追求“自动化更强”。

### 1.3 先人工兜底，再逐步放开

MVP 阶段建议：
- 手动 accept / reject
- 手动 settlement 审核
- 白名单 worker
- 高风险动作禁止自动化

---

## 2. 第一阶段：最小闭环实现（必须先完成）

这一阶段的目标是：

> 从 `create_task` 到 `settle_task` 跑通一条真实可执行闭环。

### 2.1 Solana Program 必做

- [ ] `TaskAccount`
- [ ] `ClaimAccount`
- [ ] `EscrowVault`
- [ ] `ResultAccount`
- [ ] `SettlementAccount`

### 2.2 Program 指令必做

- [ ] `create_task`
- [ ] `fund_task`
- [ ] `claim_task`
- [ ] `submit_result`
- [ ] `accept_result`
- [ ] `reject_result`
- [ ] `settle_task`

### 2.3 Program 约束必做

- [ ] task 状态机前置检查
- [ ] authority 检查
- [ ] settlement 资金闭合检查
- [ ] `execution_budget_cap` 校验
- [ ] claim 超时字段与基本处理

### 2.4 Worker 侧必做

- [ ] 轮询 `Open` 任务
- [ ] 本地 claim 决策
- [ ] 下载 `spec_uri`
- [ ] 执行任务
- [ ] 生成 artifact bundle
- [ ] 生成 `manifest.json`
- [ ] 生成 `cost-summary.json`
- [ ] 调用 `submit_result`
- [ ] 轮询 accept / reject / settle

### 2.5 存储侧必做

- [ ] 外部 artifact 存储
- [ ] bundle upload 机制
- [ ] `artifact_hash` / `summary_hash` 生成

### 2.6 验收标准

- [ ] 至少完成一批真实任务
- [ ] 无资金闭合错误
- [ ] 无越权 accept / settle 问题
- [ ] reject / reopen 路径可用

---

## 3. 第二阶段：基础可观测性与运营能力

闭环跑通以后，下一步不是立刻开放市场，而是先把系统“看见”。

### 3.1 Indexer 必做

- [ ] Task 状态索引
- [ ] Claim 状态索引
- [ ] Result / Settlement 索引
- [ ] Worker 基本指标索引

### 3.2 Dashboard 必做

- [ ] Task Dashboard
- [ ] Worker Dashboard
- [ ] Cost Dashboard

### 3.3 告警必做

- [ ] Claimed 任务长期未提交告警
- [ ] Submitted 长期未审核告警
- [ ] execution budget 异常消耗告警
- [ ] timeout / reject 异常波动告警

### 3.4 Worker 侧补充

- [ ] 结构化事件输出
- [ ] attempt versioning
- [ ] 本地失败恢复或至少保留失败记录

### 3.5 验收标准

- [ ] 运营侧能快速看见卡住任务
- [ ] 能定位 timeout / reject 的主要原因
- [ ] 能按 worker 和 category 看执行质量

---

## 4. 第三阶段：质量控制与边界强化

当系统稳定运行后，优先强化：
- guardrails
- auditability
- security

### 4.1 必做 guardrails

- [ ] execution budget 接近阈值时中止 / 降级
- [ ] tool allowlist / blocklist
- [ ] 可写路径限制
- [ ] 主网高风险动作强确认
- [ ] retry 上限

### 4.2 必做审计准备

- [ ] artifact / manifest / receipts 的稳定关联
- [ ] reject / reopen / settle 的日志链路
- [ ] result hash 与 bundle 一致性检查

### 4.3 安全检查必做

- [ ] authority 测试
- [ ] settlement 资金守恒测试
- [ ] claim 竞态 / 超时测试
- [ ] budget cap 绕过测试

### 4.4 验收标准

- [ ] 主要风险动作都有硬约束
- [ ] 审计能回放主要执行路径
- [ ] 已知坏路径有测试覆盖

---

## 5. 第四阶段：争议与声誉

当系统开始出现更多 worker 和更复杂任务时，再把隐性的 review 流程显性化。

### 5.1 Program 扩展必做

- [ ] `DisputeAccount`
- [ ] `ReputationAccount`
- [ ] `open_dispute`
- [ ] `resolve_dispute`
- [ ] `update_reputation`

### 5.2 Worker / runtime 补充

- [ ] 每次 attempt 独立保存 bundle
- [ ] reject / dispute 原因结构化记录
- [ ] 本地 reputation / outcome 可导出

### 5.3 Review 流程必做

- [ ] reviewer / arbiter 模型明确
- [ ] dispute 时冻结 settlement
- [ ] resolution 与 settlement / reputation 绑定

### 5.4 验收标准

- [ ] dispute 可被结构化处理
- [ ] reputation 不再依赖人工印象
- [ ] reject / dispute 不会导致资金或状态悬挂

---

## 6. 第五阶段：有限开放任务市场

只有在 dispute / reputation / observability 比较稳定后，才建议开始 market 化。

### 6.1 Program / 协议扩展

- [ ] minimum reputation check
- [ ] minimum stake check
- [ ] category compatibility check
- [ ] worker metadata / capability declaration

### 6.2 调度层补充

- [ ] eligibility filter
- [ ] ranking 逻辑
- [ ] 重要任务不走完全先到先得

### 6.3 运营指标必做

- [ ] worker concentration
- [ ] task coverage by category
- [ ] claim quality / reject / timeout distribution

### 6.4 验收标准

- [ ] market 能区分高低质量 worker
- [ ] 不出现明显抢单垄断
- [ ] specialization 开始生效

---

## 7. 第六阶段：支付层增强

到这一步，系统才值得继续细化：
- usage receipts
- allowance
- x402 / MMP
- 更强 cost accounting

### 7.1 必做基础

- [ ] receipt schema 稳定化
- [ ] provider / model / cost 归因稳定
- [ ] `cost-summary.json` 向更细粒度 receipts 过渡

### 7.2 支付 rail 集成前提

- [ ] settlement 经常性正确
- [ ] retry / fallback / cache 命中已经可观测
- [ ] 预算和 refund 逻辑已稳定

### 7.3 验收标准

- [ ] 成本争议显著减少
- [ ] receipt 能支持 settlement 审计
- [ ] allowance / budget 的边界更自动化

---

## 8. 第七阶段：更开放的执行层（保留为后续）

最后才进入：
- TEE
- decentralized compute
- 更强 attestation
- 更开放 worker 网络

### 前置条件

- [ ] 任务市场稳定
- [ ] receipt / artifact / manifest 完整
- [ ] dispute 机制成熟
- [ ] observability 足够强

### 为什么放最后

因为开放执行层会把所有已有问题放大。

---

## 9. 一份“先做什么、后做什么”的最短顺序

如果团队资源有限，建议严格按这个顺序：

1. [ ] Task / Claim / Result / Escrow / Settlement
2. [ ] create/fund/claim/submit/accept/reject/settle
3. [ ] artifact bundle + manifest + cost summary
4. [ ] indexer + dashboard + 告警
5. [ ] guardrails + security tests
6. [ ] dispute + reputation
7. [ ] market selection
8. [ ] richer receipts + payment rail
9. [ ] TEE / decentralized compute

---

## 10. 开始实现前的检查清单

### 协议层
- [ ] 状态机是否画清楚？
- [ ] 账户与 authority 是否列清楚？
- [ ] settlement 是否可闭合？

### 运行时层
- [ ] worker 是否知道 taskId / claimId / budget cap？
- [ ] bundle 结构是否稳定？
- [ ] submit 前是否先封包？

### 运营层
- [ ] 是否能看见卡住任务？
- [ ] 是否能看见 reject / timeout 模式？
- [ ] 是否能看见成本异常？

### 产品层
- [ ] 阶段目标是否足够小？
- [ ] 是否明确哪些功能暂不做？
- [ ] 是否有真实用户/任务来源验证？

---

## 11. 一句话总结

**Solana 实现的关键，不是把所有想法一次性实现，而是先把“最小闭环 + 可观测 + 可审计 + 可控制”做稳，再逐步扩展到 dispute、market、receipt 和开放执行层；这份清单的目的，就是让团队在真正开始开发时知道哪一步必须先做，哪一步必须后做。**
