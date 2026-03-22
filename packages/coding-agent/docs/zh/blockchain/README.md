# pi-mono × 区块链专题

> 讨论 `pi-mono` / `pi-worker` 作为链下 Agent Runtime，与 Solana、Sui、支付协议、去中心化计算层结合的专题文档。

这个专题不讨论“把 `pi-worker` 直接部署到链上运行”，而是讨论：

- 如何让 `pi-worker` 作为链下 worker 接入链上任务系统
- 如何把 Solana / Sui 用作任务、支付、权限与声誉层
- 如何处理 LLM token 成本、usage receipts、budget 与 settlement
- 如何从务实版逐步演进到 Web3-native 和更可验证的研究版架构

---

## 阅读顺序建议

建议先阅读：[00-overview.md](./00-overview.md)


1. [区块链结合路线图](./01-roadmap.md)
   - 先理解三条路线：务实版 / Web3-native / 研究版

2. [Solana / Sui 任务模型草案](./02-task-models-solana-sui.md)
   - 看 Task / Claim / Result / Escrow / Dispute 如何建模

3. [区块链 + Agent 的 LLM 支付层设计](./03-llm-payment-layer.md)
   - 看 x402 / MMP / receipt / budget / settlement 如何补齐经济闭环

4. [pi-worker 链上任务执行时序](./04-task-execution-flow.md)
   - 看任务、预算、认领、执行、计费、验收与结算如何串起来

5. [可验证 Artifact 设计](./05-verifiable-artifacts.md)
   - 看结果文件如何变成可承诺、可校验、可争议的 artifact

6. [Policy 与 Guardrails 设计](./06-policy-and-guardrails.md)
   - 看预算、模型、工具、路径、主网动作如何受策略约束

7. [TEE 与去中心化计算层](./07-tee-and-decentralized-compute.md)
   - 看路线 2 为什么需要单独执行平面，以及 TEE / worker network 的位置

8. [可验证 Receipts 与 Attestation](./08-verifiable-receipts-and-attestation.md)
   - 看 usage receipts、manifest、artifact 和 attestation 如何形成更强验证链路

9. [Solana MVP 草案](./09-solana-mvp-design.md)
   - 看第一条链如何以最小账户模型跑通任务、认领、结果提交与链上结算

10. [Solana Program 指令设计](./10-solana-program-instructions.md)
   - 看最小 instruction 集、状态迁移、PDA 关系与 Program 层 guardrails

11. [Solana 预算与结算设计](./11-solana-budget-and-settlement.md)
   - 看 execution budget、worker reward、refund 与 settlement 如何闭合

12. [Solana Worker Runtime 集成](./12-solana-worker-runtime-integration.md)
   - 看 `pi-worker` 如何发现任务、组织 bundle、提交结果并持续监控状态

13. [Solana 争议与声誉设计](./13-solana-dispute-and-reputation.md)
   - 看 dispute 如何结构化进入状态机，以及 reputation 如何从隐性印象变成显性指标

14. [Solana 任务市场与 Worker 选择](./14-solana-task-market-and-worker-selection.md)
   - 看任务如何分配，以及 capability / reputation / stake 如何影响 worker 选择

15. [Solana 安全与审计清单](./15-solana-security-and-audit-checklist.md)
   - 看协议、资金、结果承诺、runtime 集成与市场规则的审计重点

16. [Solana Indexer 与可观测性](./16-solana-indexer-and-observability.md)
   - 看链上状态、worker 运行、成本与市场健康度如何被观测、查询与告警

17. [Solana 产品推进路线图](./17-solana-product-roadmap.md)
   - 看从内部验证到有限开放市场、支付层增强、开放网络的阶段化推进方式

18. [Solana 实现清单](./18-solana-implementation-checklist.md)
   - 看真正开始开发时，协议、runtime、运营、支付层各自应按什么顺序落地

---

## 专题的核心观点

### 1. 区块链不是 `pi-worker` 的运行宿主

`pi-worker` 仍适合运行在：
- Cloudflare
- 普通云
- TEE / 去中心化执行网络

而链上更适合做：
- 任务登记
- 支付结算
- 权限与预算控制
- 声誉与 staking
- dispute / challenge

### 2. 任务层和支付层必须分开设计

- 任务层回答：谁接活、谁交付、谁验收
- 支付层回答：谁为 token 成本买单、如何限额、如何审计

### 3. 路线图应逐步推进

- **路线 1：务实版** → 先验证需求和闭环
- **路线 2：Web3-native** → 再网络化 worker 与支付轨道
- **路线 3：研究版** → 最后研究更可验证、可组合的 agent primitive

---

## 当前专题文档结构

### 总体路线与基础模型
- [01-roadmap.md](./01-roadmap.md)
- [02-task-models-solana-sui.md](./02-task-models-solana-sui.md)
- [03-llm-payment-layer.md](./03-llm-payment-layer.md)
- [04-task-execution-flow.md](./04-task-execution-flow.md)
- [05-verifiable-artifacts.md](./05-verifiable-artifacts.md)
- [06-policy-and-guardrails.md](./06-policy-and-guardrails.md)
- [07-tee-and-decentralized-compute.md](./07-tee-and-decentralized-compute.md)
- [08-verifiable-receipts-and-attestation.md](./08-verifiable-receipts-and-attestation.md)

### Solana 主线
- [09-solana-mvp-design.md](./09-solana-mvp-design.md)
- [10-solana-program-instructions.md](./10-solana-program-instructions.md)
- [11-solana-budget-and-settlement.md](./11-solana-budget-and-settlement.md)
- [12-solana-worker-runtime-integration.md](./12-solana-worker-runtime-integration.md)
- [13-solana-dispute-and-reputation.md](./13-solana-dispute-and-reputation.md)
- [14-solana-task-market-and-worker-selection.md](./14-solana-task-market-and-worker-selection.md)
- [15-solana-security-and-audit-checklist.md](./15-solana-security-and-audit-checklist.md)
- [16-solana-indexer-and-observability.md](./16-solana-indexer-and-observability.md)
- [17-solana-product-roadmap.md](./17-solana-product-roadmap.md)
- [18-solana-implementation-checklist.md](./18-solana-implementation-checklist.md)

---

## 与其他文档的关系

- `../reference/architecture-overview.md`
  - 解释 `pi-mono` 的核心架构与数据流
- `../guide/06-skills.md`
  - 解释 Skill 如何承载链上团队知识与 runbook
- `../guide/15-design-decisions.md`
  - 解释为什么仍然需要源码理解与事件治理

这个 `blockchain/` 目录是在这些基础之上的**垂直方案专题**。
