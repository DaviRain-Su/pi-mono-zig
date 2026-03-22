# Policy 与 Guardrails 设计

> 面向 `pi-worker` / `pi-mono` 区块链任务系统的边界控制与执行约束设计。

如果没有 policy 与 guardrails，链上任务市场很容易退化成：
- worker 乱花预算
- 使用错误模型
- 修改不该修改的文件
- 调用高风险工具
- 在主网执行不该执行的动作

因此，policy / guardrails 不是可选优化，而是区块链 Agent 系统的基础层。

---

## 1. 为什么区块链场景更需要 guardrails

相比普通开发任务，区块链任务有三个额外风险：

1. **不可逆性**
   - 链上转账、升级、授权、清算通常不可逆

2. **资金风险**
   - 一次错误操作可能直接造成真实资产损失

3. **自动化放大效应**
   - 一旦 worker 获得自动执行能力，错误会被快速放大

所以在这个专题里，guardrails 的目标不是“限制体验”，而是：
- 让自动化在边界内发生
- 让争议时能回溯“系统是否违规”

---

## 2. Policy 与 Guardrails 的区别

### Policy

回答：
> 系统允许做什么、不允许做什么。

例如：
- 允许哪些模型
- 最大预算是多少
- 是否允许 fallback
- 哪些地址可以交互
- 哪些任务必须人工确认

### Guardrails

回答：
> 当运行时接近或越过边界时，如何阻止、提醒、降级或转人工。

例如：
- 超预算自动中止
- 主网操作要求人工确认
- 禁止修改指定目录
- 禁止调用高风险工具

### 一句话区分

- **Policy 是规则**
- **Guardrails 是执行规则的机制**

---

## 3. 最小 policy 分类

建议至少有 5 类 policy：

### 3.1 Budget Policy
- 单任务最大执行成本
- 单次模型调用最大费用
- 最大重试次数
- 是否允许高 reasoning 模式

### 3.2 Model Policy
- 允许哪些 provider
- 允许哪些模型
- 是否允许 fallback model
- 哪些任务只能使用低成本模型

### 3.3 Tool Policy
- 允许哪些工具
- 哪些工具是只读
- 哪些工具必须人工确认
- 哪些工具完全禁止

### 3.4 Scope Policy
- 允许修改哪些目录
- 允许读哪些数据源
- 允许访问哪些仓库 / artifact / dashboard

### 3.5 Chain Action Policy
- 哪些链上地址允许交互
- 哪些合约允许调用
- 最大转账金额
- 主网操作是否必须人工批准

---

## 4. 推荐的 policy 对象字段

| 字段 | 说明 |
|------|------|
| `policyId` | 策略 ID |
| `allowedProviders` | 允许的 provider 列表 |
| `allowedModels` | 允许的模型列表 |
| `maxTaskCost` | 单任务最大成本 |
| `maxSingleCallCost` | 单次最大费用 |
| `maxRetries` | 最大重试次数 |
| `allowFallbackModel` | 是否允许 fallback |
| `allowedTools` | 允许的工具 |
| `blockedTools` | 禁止的工具 |
| `writablePaths` | 可写目录范围 |
| `allowedChains` | 可交互链 |
| `allowedContracts` | 可调用目标 |
| `manualApprovalThreshold` | 超过阈值需人工确认 |
| `mainnetWriteAllowed` | 是否允许主网写操作 |

---

## 5. Guardrails 应该在什么时机触发

### 5.1 请求前（preflight）

在模型调用、工具调用、链上操作前触发：
- 是否超预算
- 是否超模型范围
- 是否使用了被禁工具
- 是否试图写入非法路径

### 5.2 运行中（runtime）

在任务执行过程中持续检查：
- 累计成本是否逼近上限
- 是否发生异常重试
- 是否进入 fallback 模型
- 是否产生异常大输出

### 5.3 提交前（pre-submit）

在结果提交或链上交易提交前检查：
- artifact 是否完整
- manifest 是否齐全
- usage receipts 是否对齐
- 是否需要人工批准

### 5.4 结算前（pre-settlement）

在释放奖励前检查：
- policy 是否被违反
- 是否存在未解决 dispute
- settlement 是否与 receipt 总额一致

---

## 6. `pi-worker` 里最值得优先做的 6 个 guardrails

### 6.1 超预算中止

最基础也最重要：
- 发起请求前检查预算
- 累计接近阈值时提醒
- 超预算后自动中断或降级

### 6.2 主网操作确认

对于：
- transfer
- swap
- upgrade
- governance execute
- admin action

应要求：
- 明确风险说明
- 地址、金额、链名复述
- 人工确认词或 approval token

### 6.3 工具白名单 / 黑名单

例如：
- 只允许 `read` / `bash`
- 禁止 `write` / `edit`
- 或只允许特定链操作工具

### 6.4 可写路径限制

对于代码任务，可设：
- 只允许改某个 package
- 只允许在临时工作目录输出 artifact
- 禁止写系统目录 / secrets 目录

### 6.5 模型降级策略

如果高成本模型不允许继续：
- 自动切换到便宜模型前必须通过 policy
- fallback 需要被记录

### 6.6 重试上限

模型调用失败、网络失败、工具失败都不应无限重试。

建议：
- 每类失败分别设上限
- 重试次数进入 usage / settlement 审计

---

## 7. 链上任务系统里的高风险动作分类

建议至少把动作分三层：

### 低风险
- 读数据
- 读日志
- 读代码
- 生成报告

处理：
- 可自动执行

### 中风险
- 生成 patch
- 生成部署建议
- 生成链上操作计划

处理：
- 可自动执行，但提交前需 review

### 高风险
- 主网写操作
- 转账
- 升级
- 权限变更
- 合约调用

处理：
- 必须人工确认
- 必须记录 approval artifact
- 必须进入审计日志

---

## 8. Guardrails 与 dispute 的关系

guardrails 不只是为了“预防事故”，也为了在 dispute 时回答：

- worker 有没有超越 policy？
- 为什么会执行这次 fallback？
- 为什么重试了 6 次？
- 为什么会触发主网写操作？

因此每一个 guardrail 决策都建议记录：
- trigger reason
- related policy id
- decision（allow / block / degrade / require approval）
- timestamp

---

## 9. 推荐的最小审计记录

对于每次关键 guardrail 事件，建议记录：

| 字段 | 说明 |
|------|------|
| `eventId` | 唯一 ID |
| `taskId` | 所属任务 |
| `claimId` | 所属认领 |
| `policyId` | 命中的策略 |
| `eventType` | budget / model / tool / chain / path |
| `decision` | allow / block / degrade / approval_required |
| `reason` | 触发原因 |
| `timestamp` | 时间 |

这样 dispute 时可以直接回放“系统边界如何工作”。

---

## 10. 推荐推进顺序

### 第一阶段
- Budget policy
- Tool allowlist/blocklist
- 主网操作确认
- 重试上限

### 第二阶段
- 路径写入限制
- fallback policy
- 更细粒度的链上地址 allowlist

### 第三阶段
- 动态 policy
- 按任务类型切换 guardrails
- 更强的 policy-linked dispute review

---

## 11. 一句话总结

**在 `pi-worker + blockchain` 系统里，policy 定义了“允许做什么”，guardrails 保证系统“不会在错误边界外自动化”；没有这一层，链上任务市场只是自动化分发任务，有了这一层，才有可能安全地走向真实资金和主网场景。**
