# Solana 安全与审计清单

> 当 Solana 主线已经具备任务、claim、result、settlement、runtime、dispute、reputation 与 task market 设计后，接下来最重要的问题就是：如果真的实现这套系统，审计应该重点看什么？

本文提供一份面向协议设计者、实现者和审计者的检查清单。

---

## 1. 为什么这份清单很重要

`pi-worker + Solana` 这类系统不是普通任务列表，它同时涉及：
- 状态机
- 资金流
- result commitment
- runtime integration
- 预算与结算
- dispute / reputation
- worker selection

这意味着风险是叠加的：
- 不只是“合约会不会被盗”
- 还包括“系统规则会不会被绕过”
- 以及“经济激励是否会把系统推向坏结果”

所以审计不能只盯着 token transfer，而要把：
- 协议逻辑
- 运行时边界
- 经济层约束

一起看。

---

## 2. 第一类风险：状态机不一致

### 要检查的问题

1. `Task` 是否只能按合法路径迁移？
2. `Claim` 是否可能在错误状态下继续提交结果？
3. `Accepted` / `Rejected` / `Settled` 是否存在重复或越序执行？
4. `Reopened` 是否可能绕过某些必要检查？
5. `Disputed` 是否会导致状态悬挂、无法继续？

### 典型错误

- `submit_result` 在 task 不是 `Claimed` 时仍可执行
- `settle_task` 在结果未 accept 时就能执行
- `reject_result` 后还能重复提交同一 result
- `claim_task` 在已有有效 claim 时仍能被抢单

### 审计建议

- 把状态迁移画成显式图
- 为每个 instruction 写前置状态断言
- 测边界状态和重复调用路径

---

## 3. 第二类风险：authority / 权限绕过

### 要检查的问题

1. 谁能创建任务？
2. 谁能 funding？
3. 谁能 claim？
4. 谁能 accept / reject？
5. 谁能 settle？
6. 谁能更新 reputation / dispute？

### 典型错误

- 任何人都能 `accept_result`
- worker 可以自己给自己 settle
- creator 可以绕过 result 直接取回 escrow
- 非 claim owner 也能 `submit_result`

### 审计建议

- 每条 instruction 列清 signer 与 authority 关系
- 对所有“敏感状态转移”做越权测试
- 尽量避免隐式 authority 逻辑

---

## 4. 第三类风险：资金不闭合

### 要检查的问题

1. reward、execution budget、platform fee 是否明确拆分？
2. settlement 是否满足资金守恒？
3. refund 计算是否可能为负或溢出？
4. reject / reopen 路径是否会重复占用或释放资金？

### 最关键的审计点

必须检查以下公式是否总成立：

```text
total_funded
= execution_cost_total
+ worker_reward_paid
+ platform_fee_paid
+ refund_amount
```

### 典型错误

- execution cost 与 reward 混用
- 同一任务被结算两次
- 已 reject 的任务仍释放 reward
- refund 忽略了已经发生的 execution cost

### 审计建议

- 为 settlement 写 property-based tests
- 对 accept / reject / dispute / partial 路径分别验证资金闭合

---

## 5. 第四类风险：claim 超时与竞态条件

### 要检查的问题

1. claim 是否有明确超时？
2. claim 超时后，task 如何重新开放？
3. 如果多个 worker 同时 claim，会不会出现竞态？
4. claim 超时后是否还能提交旧结果？

### 典型错误

- claim 过期后老 worker 仍能 `submit_result`
- task 被 reopen 时旧 claim 仍被视为有效
- 双 worker 同时 claim 成功

### 审计建议

- 测试“临界时刻”提交结果
- 测试超时 claim + reopen + 再 claim 的组合路径
- 明确 `claim status` 与 `task status` 的联动规则

---

## 6. 第五类风险：result commitment 不一致

### 要检查的问题

1. `artifact_hash`、`summary_hash`、`manifest_uri` 是否在提交时都存在？
2. 同一结果是否可能被后续文件覆盖？
3. 链上 hash 与链下 bundle 是否可能不一致？
4. reject / dispute 时是否还能重放旧 bundle？

### 典型错误

- 先提交链上 hash，后续又改了 artifact 文件
- 同一 `result_id` 被复用
- `summary_hash` 缺失导致 dispute 时无法快速核对

### 审计建议

- 强化“先封包，再提交 commitment”
- 对 result account 的唯一性和不可篡改性做检查
- 对 artifact bundle 做稳定命名与版本管理

---

## 7. 第六类风险：execution budget 被绕过

### 要检查的问题

1. `execution_budget_cap` 是否在 settlement 时强校验？
2. 超预算的结果是否还能被正常结算？
3. retry / fallback 是否可能导致隐藏费用膨胀？
4. cost summary 是否可能被伪造或漏记？

### 典型错误

- 只检查 `reward_amount`，不检查 execution cost
- worker 超预算后仍能 claim 成功并拿全额 reward
- cost summary 纯凭 worker 自报，无额外核查

### 审计建议

- 至少保证 settlement 时不允许超预算闭合
- 要求 cost summary 与 receipt / manifest 有可对照关系
- 对 retry / fallback 的成本路径单独测试

---

## 8. 第七类风险：dispute 流程失效或被滥用

### 要检查的问题

1. dispute 开启后 settlement 是否正确冻结？
2. dispute 是否可能永远不结束？
3. 谁能 resolve dispute？
4. partial resolution 是否会引入新的资金不闭合？

### 典型错误

- dispute 期间资金仍可释放
- 谁都能 `resolve_dispute`
- resolution 状态没有同步回 task / settlement

### 审计建议

- dispute 状态机单独建模
- 测试 Open / Reviewing / Resolved 全路径
- 测试 Accept / Reject / Partial resolution 的分支逻辑

---

## 9. 第八类风险：reputation 被操纵

### 要检查的问题

1. reputation 更新是否只在合法事件后发生？
2. 是否存在刷分路径？
3. 是否存在 claim 后不执行但不扣分的漏洞？
4. dispute 胜负是否与 reputation 正确联动？

### 典型错误

- accept / reject 外的路径也会错误更新 reputation
- reopened 任务重复累计正向分数
- timeout 没有进入惩罚逻辑

### 审计建议

- 原始指标与 score 分开
- 所有 reputation 更新都绑定到具体事件
- 为 reopen / retry / dispute 设计防重复累计规则

---

## 10. 第九类风险：task market 激励失衡

### 要检查的问题

1. 是否只靠先到先得，导致抢单垄断？
2. stake 是否被过度当作质量代理？
3. specialization 是否完全没有被表达？
4. 低质量 worker 是否能长期占据任务？

### 这类问题为什么也是审计问题

因为它们虽然不一定是智能合约漏洞，但会导致：
- 系统质量下降
- 优质 worker 流失
- creator 信任下降
- 经济激励扭曲

### 审计 / 设计建议

- 能力、声誉、stake 分层处理
- 先过滤，再排序
- 重要任务不要一开始就完全开放抢单

---

## 11. 第十类风险：runtime 集成断层

### 要检查的问题

1. worker 本地 manifest / receipts / artifact 是否稳定落盘？
2. 结果提交前是否真正完成封包？
3. reject / reopen 是否会覆盖旧 attempt？
4. claim 超时后 worker 是否仍继续执行旧任务？

### 典型错误

- worker 只在内存中持有中间状态
- 程序崩溃后无法重建 bundle
- reject 后 attempt-1 被 attempt-2 覆盖

### 审计建议

- 检查运行目录版本化
- 检查 claim / attempt / result 的映射关系
- 检查 post-submit monitoring 与 cleanup 逻辑

---

## 12. 推荐的审计顺序

### 第一轮：协议级
- task / claim / result / settlement 状态机
- authority
- escrow 资金闭合

### 第二轮：经济级
- execution budget
- reward / refund
- reopen / reject / dispute 激励是否合理

### 第三轮：运行时级
- manifest
- artifact bundle
- receipts
- worker 本地状态与链上状态是否对齐

### 第四轮：市场级
- worker selection
- reputation 更新逻辑
- anti-spam / anti-Sybil / anti-monopoly

---

## 13. 最小审计清单（可直接用于 review）

- [ ] 每条 instruction 是否有清晰前置状态？
- [ ] 每条 instruction 是否有清晰 authority？
- [ ] settlement 是否资金闭合？
- [ ] claim 超时是否能正确处理？
- [ ] result hash / summary hash / manifest uri 是否强制存在？
- [ ] execution budget cap 是否强校验？
- [ ] dispute 状态是否会冻结 settlement？
- [ ] reputation 是否只在合法事件后更新？
- [ ] worker 本地 bundle 是否可回放？
- [ ] task market 规则是否避免明显坏激励？

---

## 14. 一句话总结

**对 `pi-worker + Solana` 系统的审计，不应只把它当作一个 escrow 合约来看，而应把它视为“状态机 + 资金流 + result commitment + runtime integration + market rules”的复合系统；真正的安全，不只是防止资产被盗，还包括防止协议逻辑、执行边界与经济激励被系统性绕过。**
