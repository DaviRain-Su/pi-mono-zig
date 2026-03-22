# Solana 产品推进路线图

> 在 Solana 主线已经形成从协议、预算、runtime、dispute、market 到 observability 的完整设计后，接下来需要回答的问题是：如果真的做产品，应该按什么阶段推进？

这篇文档的目标不是继续加协议细节，而是把前面的设计文档转成：
- 实际可执行的阶段计划
- 每一阶段的目标、约束、验收标准
- 什么时候可以进入下一阶段

---

## 1. 为什么需要产品路线图

如果没有阶段化推进，团队很容易犯两个错误：

### 错误 A：一开始就想做完整开放网络

表现为：
- 一上来就想做开放 worker 市场
- 一上来就想做 fully on-chain metering
- 一上来就想做完整 dispute / arbitration / attestation

问题：
- 复杂度过高
- 没有真实任务数据校准设计
- 非核心问题太早暴露

### 错误 B：永远停留在内部工具

表现为：
- 一直靠白名单 worker
- 一直人工操作 settlement
- 一直没有 metrics / dispute / reputation

问题：
- 无法验证 market 设计
- 无法判断哪些边界需要产品化
- 难以形成真正平台能力

### 结论

最合理的方式是：
> **沿着一条 Solana-first 主线，分阶段扩展，而不是一步到位。**

---

## 2. 推荐的五阶段路线

建议产品推进至少分为：

1. 阶段 0：内部验证
2. 阶段 1：最小闭环 MVP
3. 阶段 2：有限开放市场
4. 阶段 3：更强支付与验证层
5. 阶段 4：开放网络与更强执行层

---

## 3. 阶段 0：内部验证

### 目标

在完全受控的环境里验证：
- 任务模型是否合理
- `pi-worker` 与 Solana 接入是否顺畅
- artifact / manifest / cost summary 是否够用
- settlement 是否闭合

### 系统特点

- 白名单 creator
- 白名单 worker
- 人工验收
- 人工 settlement 审核
- 不做开放 claim
- 不做复杂 dispute

### 这阶段最重要的不是规模，而是学习

需要回答：
- 哪类任务最常见？
- 哪类 artifact 最有价值？
- cost summary 是否足够解释 execution cost？
- reject 的主要原因是什么？

### 阶段 0 成功标志

- 至少完成一批真实任务
- 没有资金闭合问题
- 没有状态机错误
- worker runtime 与链上状态能稳定对齐

---

## 4. 阶段 1：最小闭环 MVP

### 目标

把阶段 0 的内部试验收敛成稳定可重复的最小产品。

### 必备能力

- `Task / Claim / Result / Escrow / Settlement`
- 手动 accept / reject
- 统一 artifact bundle
- 基础 cost summary
- 基础 dashboard
- timeout / reopen 的最小支持

### 仍然可以刻意不做的内容

- 开放 worker 市场
- 自动 dispute 仲裁
- fully on-chain payment rail
- TEE / decentralized compute

### 适合的用户

- 内部团队
- 紧密合作的 beta 用户
- 少量高信任 task creator / worker

### 阶段 1 成功标志

- 任务发布到 settlement 的路径稳定
- 平均任务完成时间可预测
- reject / reopen / timeout 逻辑可控
- dashboard 能看见主要状态与异常

---

## 5. 阶段 2：有限开放市场

### 目标

开始让系统从“受控任务系统”迈向“受约束的市场系统”。

### 核心变化

- 引入 `WorkerAccount` 与基本 reputation
- claim 不再完全白名单，而是“有资格的 worker 可以 claim”
- 加入 minimum stake / minimum reputation / category compatibility
- 更正式的 worker selection 逻辑

### 这阶段最重要的产品问题

- 什么条件下一个 worker 才有资格接单？
- 什么情况下任务不应开放给所有 worker？
- 如何避免先到先得带来的劣质匹配？

### 需要同步加强的能力

- Task / Worker / Market dashboard
- reject / dispute 数据分析
- 更稳定的 claim 超时回收
- 本地 attempt versioning

### 阶段 2 成功标志

- worker 选择开始有质量差异
- 低质量 worker 不会轻易吃掉高价值任务
- 市场开始形成基本供需结构
- reputation 与 stake 逻辑没有明显坏激励

---

## 6. 阶段 3：更强支付与验证层

### 目标

把系统从“链上任务 + 链下粗略记账”推进到“更精细可审计的成本层”。

### 核心变化

- 接入更标准化的 `UsageReceipt`
- 让 `cost-summary.json` 过渡到更细粒度 receipt
- 逐步接入 x402 / MMP 这类 payment rail
- 把 budget / allowance / settlement 联系得更紧

### 为什么这一步在市场化之后做

因为只有在系统真的有足够任务量与成本压力时，你才会知道：
- 哪些成本结构最值得细化
- 哪些 payment rail 真的有必要接
- fallback / retry / cache 命中是否值得精细对账

### 阶段 3 成功标志

- execution cost 解释性明显提高
- receipt 能稳定支持 settlement 与审计
- worker / creator 对费用争议显著减少

---

## 7. 阶段 4：开放网络与更强执行层

### 目标

把 Solana 主线从“受约束市场”推进到更开放的 worker 网络。

### 核心变化

- 更开放的 worker 加入方式
- dispute / arbitration 更成熟
- 更强的 reputation / slashing
- 可考虑 TEE / decentralized compute layer
- attestation / verifiable receipts 进入生产路径

### 为什么这是最后一阶段

因为它要求前面的所有基础都已经稳定：
- 状态机
- settlement
- runtime integration
- artifact bundle
- observability
- market metrics

否则开放网络只会放大问题。

### 阶段 4 成功标志

- worker 网络不依赖少数白名单节点
- dispute 不是手工混乱流程，而是结构化流程
- execution provenance 开始足够可信

---

## 8. 每个阶段最重要的产品问题

### 阶段 0
- 我们到底在解决什么真实任务？

### 阶段 1
- 最小闭环是否稳定、可重复、能解释？

### 阶段 2
- worker 选择逻辑是否开始优于“人工拍脑袋”？

### 阶段 3
- 费用和预算是否开始真正可审计？

### 阶段 4
- 系统能否在更开放条件下仍维持质量与安全？

---

## 9. 什么时候不该进入下一阶段

### 不要从阶段 0 直接跳到阶段 2/3

如果你还不知道：
- 最常见任务类型
- reject 原因
- runtime 失败模式
- artifact 格式是否合理

就不应该过早市场化或支付精细化。

### 不要在阶段 1 还没稳定时引入开放市场

如果现在还经常出现：
- settlement 闭合错误
- claim 超时混乱
- bundle 不稳定
- reject/reopen 逻辑不清

那只会把问题扩散。

### 不要在 receipt 体系不成熟时上复杂 payment rail

如果现在连 cost summary 都不稳定，就还不到接入 x402 / MMP 的最佳时机。

---

## 10. 推荐的阶段验收指标

### 阶段 0 / 1 指标
- task completion rate
- average completion time
- reject rate
- reopen rate
- settlement correctness

### 阶段 2 指标
- worker qualification pass rate
- worker concentration ratio
- average claim success rate
- category coverage

### 阶段 3 指标
- average execution cost variance
- receipt completeness
- refund accuracy
- cost dispute rate

### 阶段 4 指标
- open network worker retention
- dispute resolution latency
- attestation coverage
- slashing / violation rate

---

## 11. 产品推进中的一个重要判断标准

很多团队会问：
- “什么时候该进入下一阶段？”

我的建议是：

> **不是看你“想做什么”，而是看现阶段的错误是否已经被你看见、解释并稳定控制住。**

例如：
- 如果 reject 原因还无法分类，就别急着做 reputation
- 如果 settlement 还经常需要人工修正，就别急着做开放 market
- 如果 observability 还看不出系统瓶颈，就别急着做 TEE

---

## 12. 一句话总结

**Solana 产品路线不应该从“能想象的最终形态”往回倒推，而应该从“最小闭环 + 可观测 + 可解释”一步步向外扩展：先做内部验证，再做稳定 MVP，再做有限市场、支付层、开放网络；每一步都应由真实任务数据和系统稳定性来驱动。**
