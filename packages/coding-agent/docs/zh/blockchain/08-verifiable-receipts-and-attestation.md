# 可验证 Receipts 与 Attestation

> 讨论 `pi-worker` / `pi-mono` 在区块链任务系统中，如何让 usage receipts、执行清单和 attestation 逐步形成更强的可验证链路。

本文承接：
- LLM 支付层
- 可验证 artifact
- Policy / Guardrails
- TEE / 去中心化执行层

目标是回答：

- receipt 不只是账单，怎样变成可验证证据？
- attestation 能证明什么，不能证明什么？
- dispute 时，哪些材料应该被回放和审计？

---

## 1. 为什么单有 receipts 还不够

在前一篇支付层设计中，我们已经定义了 `UsageReceipt`：
- provider
- model
- inputTokens
- outputTokens
- cachedTokens
- totalCost
- requestHash
- paymentReceiptUri

这已经足以支持：
- 预算扣减
- settlement
- cost accounting

但如果系统进一步进入：
- dispute
- challenge
- 开放 worker 网络
- reputation 约束

就会出现新的问题：
- 这个 receipt 是真实的吗？
- 它和这次任务结果真的对应吗？
- 它是不是在承诺的运行环境里产生的？
- 是否发生了 policy 违规或未声明 fallback？

这就是“可验证 receipts”要解决的问题。

---

## 2. 什么是可验证 receipt

普通 receipt 只是一个账单记录。

可验证 receipt 至少应该满足：

1. **可归因**
   - 能关联 task / claim / worker / artifact

2. **可承诺**
   - 自身有 hash / signature / commitment

3. **可回放**
   - dispute 时能回看这次调用的上下文摘要

4. **可审核**
   - 能检查是否符合 policy 与预算边界

---

## 3. receipt 的三级成熟度

### Level 1：Accounting Receipt

只用于内部记账：
- token 数量
- 价格
- 调用时间
- provider/model

用途：
- 预算控制
- settlement

限制：
- 可信度依赖平台自己说了算

### Level 2：Committed Receipt

在 accounting 基础上，再增加：
- receipt hash
- request hash
- result/manifest 关联
- 可能的 provider 回执 URI

用途：
- dispute 初步复核
- 更好的审计与对账

### Level 3：Attested Receipt

在 committed 基础上，再增加：
- TEE attestation
- signed execution metadata
- 环境承诺（runtime / version / policy snapshot）

用途：
- 开放 worker 网络
- 更强 challenge / dispute
- 更高可信度的 reputation 与 settlement

---

## 4. attestation 能证明什么

这是最容易被夸大的部分，必须说清楚。

### attestation 更适合证明

- 运行发生在某个声明的执行环境中
- 使用的是某个声明的 runtime 版本
- 产生了某组声明的 metadata / manifest / receipts
- 这组输出是在该环境里导出的

### attestation 不能直接证明

- 模型回答一定正确
- 报告结论一定合理
- patch 一定无 bug
- 人类业务判断一定正确

所以：

> attestation 提高的是“执行可信度”，不是“语义正确性保证”。

---

## 5. receipt、artifact、manifest 三者必须绑在一起

如果要让 dispute 有意义，这三层不能分离：

### 5.1 Execution Manifest

回答：
- 这次任务是怎么跑的？
- 用了哪些模型 / skills / extensions / tools / policy？

### 5.2 Usage Receipts

回答：
- 花了多少钱？
- 哪些 provider / model 被调用了？
- 是否有 fallback / retry / cache 命中？

### 5.3 Result Artifact

回答：
- 最终交付了什么？
- report / patch / json / html 的 hash 是多少？

### 三者的关系

```text
manifest -> 描述执行边界
receipts -> 描述成本与调用轨迹
artifact -> 描述最终结果
```

只有三者绑定在一起，系统才能真正回答：
- 这份结果花了多少钱
- 是否在允许的边界里产生
- 是否值得支付和记 reputational credit

---

## 6. 一个最小 attestation bundle

建议最少组织成这样：

```text
bundle/
├── manifest.json
├── receipts.json
├── result.json / report.md / patch.diff / playground.html
├── metadata.json
└── attestation.json
```

### `attestation.json` 建议字段

| 字段 | 说明 |
|------|------|
| `attestationId` | 唯一 ID |
| `workerId` | 所属 worker |
| `runtimeType` | cloud / tee / decentralized |
| `runtimeVersion` | worker runtime 版本 |
| `manifestHash` | manifest 哈希 |
| `receiptsHash` | receipts 哈希 |
| `artifactHash` | 结果哈希 |
| `policyHash` | policy snapshot 哈希 |
| `signatureOrProofUri` | 签名或证明地址 |

---

## 7. dispute 时应该回放什么

如果出现 dispute，建议至少回放以下材料：

1. `Task` 与 `Policy`
2. `Claim` 与 `WorkerIdentity`
3. `ExecutionManifest`
4. `UsageReceipts`
5. `Artifact bundle`
6. `Attestation metadata`
7. `Settlement summary`

### 为什么不是只看结果

因为 dispute 不只是“结果对不对”，还可能涉及：
- 是否超预算
- 是否违规 fallback
- 是否调用了未授权工具
- 是否在错误环境里执行
- 是否存在异常重试或费用膨胀

---

## 8. 一个逐步增强的验证路径

### 阶段 1：哈希级承诺

- 记录 artifact hash
- 记录 receipts hash
- 记录 manifest hash

### 阶段 2：结构化校验

- manifest schema
- receipt schema
- artifact bundle schema
- settlement consistency check

### 阶段 3：attestation + challenge

- TEE / execution attestation
- dispute challenge window
- reviewer / arbiter system
- 更强 reputation/slash 机制

---

## 9. 推荐给 `pi-worker` 的能力补充

### 9.1 manifest snapshotting
- 每次执行保存 manifest 快照
- 版本化 skills / extensions / provider routing

### 9.2 receipt hashing
- 每轮调用结束后都能计算 receipt hash
- 最终汇总生成 receipts bundle hash

### 9.3 bundle export
- 能一键导出 artifact + manifest + receipts + metadata

### 9.4 attestation integration point
- 预留把 TEE / external proof 接入进 bundle 的位置

---

## 10. 一句话总结

**receipt 解决“花了多少钱”，artifact 解决“交付了什么”，manifest 解决“怎么执行的”，attestation 解决“是否在承诺环境里执行”；把这四层串起来，`pi-worker + blockchain` 才能逐步从记账系统走向更强的可验证执行系统。**
