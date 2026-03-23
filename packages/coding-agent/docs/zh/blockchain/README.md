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

9. [Solana 专题导航](./solana/README.md)
   - 看 Solana 主线的阅读顺序与目录

10. [Solana MVP 草案](./solana/09-solana-mvp-design.md)
   - 看第一条链如何以最小账户模型跑通任务、认领、结果提交与链上结算

11. [Solana Program 指令设计](./solana/10-solana-program-instructions.md)
   - 看最小 instruction 集、状态迁移、PDA 关系与 Program 层 guardrails

12. [Solana 预算与结算设计](./solana/11-solana-budget-and-settlement.md)
   - 看 execution budget、worker reward、refund 与 settlement 如何闭合

13. [Solana Worker Runtime 集成](./solana/12-solana-worker-runtime-integration.md)
   - 看 `pi-worker` 如何发现任务、组织 bundle、提交结果并持续监控状态

14. [Solana 争议与声誉设计](./solana/13-solana-dispute-and-reputation.md)
   - 看 dispute 如何结构化进入状态机，以及 reputation 如何从隐性印象变成显性指标

15. [Solana 任务市场与 Worker 选择](./solana/14-solana-task-market-and-worker-selection.md)
   - 看任务如何分配，以及 capability / reputation / stake 如何影响 worker 选择

16. [Solana 安全与审计清单](./solana/15-solana-security-and-audit-checklist.md)
   - 看协议、资金、结果承诺、runtime 集成与市场规则的审计重点

17. [Solana Indexer 与可观测性](./solana/16-solana-indexer-and-observability.md)
   - 看链上状态、worker 运行、成本与市场健康度如何被观测、查询与告警

18. [Solana 产品推进路线图](./solana/17-solana-product-roadmap.md)
   - 看从内部验证到有限开放市场、支付层增强、开放网络的阶段化推进方式

19. [Solana 实现清单](./solana/18-solana-implementation-checklist.md)
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

## 文档列表

### 基础层
- [01-roadmap.md](./01-roadmap.md) - 区块链结合路线图
- [02-task-models-solana-sui.md](./02-task-models-solana-sui.md)
- [03-llm-payment-layer.md](./03-llm-payment-layer.md)
- [04-task-execution-flow.md](./04-task-execution-flow.md)
- [05-verifiable-artifacts.md](./05-verifiable-artifacts.md)
- [06-policy-and-guardrails.md](./06-policy-and-guardrails.md)
- [07-tee-and-decentralized-compute.md](./07-tee-and-decentralized-compute.md)
- [08-verifiable-receipts-and-attestation.md](./08-verifiable-receipts-and-attestation.md)

### Solana 主线
- [solana/README.md](./solana/README.md)
- [solana/09-solana-mvp-design.md](./solana/09-solana-mvp-design.md)
- [solana/10-solana-program-instructions.md](./solana/10-solana-program-instructions.md)
- [solana/11-solana-budget-and-settlement.md](./solana/11-solana-budget-and-settlement.md)
- [solana/12-solana-worker-runtime-integration.md](./solana/12-solana-worker-runtime-integration.md)
- [solana/13-solana-dispute-and-reputation.md](./solana/13-solana-dispute-and-reputation.md)
- [solana/14-solana-task-market-and-worker-selection.md](./solana/14-solana-task-market-and-worker-selection.md)
- [solana/15-solana-security-and-audit-checklist.md](./solana/15-solana-security-and-audit-checklist.md)
- [solana/16-solana-indexer-and-observability.md](./solana/16-solana-indexer-and-observability.md)
- [solana/17-solana-product-roadmap.md](./solana/17-solana-product-roadmap.md)
- [solana/18-solana-implementation-checklist.md](./solana/18-solana-implementation-checklist.md)

### Sui 子专题
- [sui/README.md](./sui/README.md)
- [sui/00-overview.md](./sui/00-overview.md)
- [sui/02-task-models.md](./sui/02-task-models.md)
- [sui/10-sui-mvp-design.md](./sui/10-sui-mvp-design.md)
- [sui/11-sui-contract-instructions.md](./sui/11-sui-contract-instructions.md)
- [sui/12-sui-budget-and-settlement.md](./sui/12-sui-budget-and-settlement.md)
- [sui/13-sui-worker-runtime-integration.md](./sui/13-sui-worker-runtime-integration.md)
- [sui/14-sui-dispute-and-reputation.md](./sui/14-sui-dispute-and-reputation.md)
- [sui/15-sui-market-and-selection.md](./sui/15-sui-market-and-selection.md)
- [sui/16-sui-security-and-audit.md](./sui/16-sui-security-and-audit.md)
- [sui/17-sui-indexer-and-observability.md](./sui/17-sui-indexer-and-observability.md)
- [sui/18-sui-implementation-checklist.md](./sui/18-sui-implementation-checklist.md)

### DASN 研究线
- [dasn/README.md](./dasn/README.md)
- [dasn/19-dasn-vision.md](./dasn/19-dasn-vision.md)
- [dasn/20-agent-protocols-analysis.md](./dasn/20-agent-protocols-analysis.md)
- [dasn/21-dasn-protocol-integration.md](./dasn/21-dasn-protocol-integration.md)
- [dasn/22-dasn-prototype-design.md](./dasn/22-dasn-prototype-design.md)
- [dasn/23-dasn-testing-strategy.md](./dasn/23-dasn-testing-strategy.md)
- [dasn/24-dasn-standard-proposal.md](./dasn/24-dasn-standard-proposal.md)
- [dasn/25-dasn-sdk-design.md](./dasn/25-dasn-sdk-design.md)
- [dasn/31-decentralized-agent-platform-design.md](./dasn/31-decentralized-agent-platform-design.md) - 去中心化 Agent 协作平台设计 (Sui/X Layer) 🆕
- [dasn/32-dagent-hub-economic-and-worker-model.md](./dasn/32-dagent-hub-economic-and-worker-model.md) - 稳定币支付与 Worker 部署模型 🆕
- [dasn/33-dagent-product-definition.md](./dasn/33-dagent-product-definition.md) - dAgent Network 产品定义书 (基于 pi-mono) 🆕

### 产品实现线
- [dasn/31-decentralized-agent-platform-design.md](./dasn/31-decentralized-agent-platform-design.md) - dAgent Hub 产品完整设计 (Sui/X Layer) 🆕
- [dasn/32-dagent-hub-economic-and-worker-model.md](./dasn/32-dagent-hub-economic-and-worker-model.md) - 稳定币支付与 Worker 部署模型 🆕
- [dasn/33-dagent-product-definition.md](./dasn/33-dagent-product-definition.md) - dAgent Network 产品定义书 (基于 pi-mono) 🆕

---

## 与其他文档的关系

- `../reference/architecture-overview.md`
  - 解释 `pi-mono` 的核心架构与数据流
- `../guide/06-skills.md`
  - 解释 Skill 如何承载链上团队知识与 runbook
- `../guide/15-design-decisions.md`
  - 解释为什么仍然需要源码理解与事件治理

这个 `blockchain/` 目录是在这些基础之上的**垂直方案专题**。
