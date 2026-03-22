# 可验证 Artifact 设计

> 讨论 `pi-worker` / `pi-mono` 在链上任务系统里产出的结果，如何从“普通文件”提升为可承诺、可校验、可争议的 artifact。

如果没有 artifact 设计，链上任务系统就只能停留在“worker 说它做完了”。而要进入：
- dispute
- challenge
- reputation
- policy enforcement
- 更强的自动验收

就必须把结果设计成可验证 artifact。

---

## 1. 什么是 artifact

在本专题里，artifact 指的是：

> worker 执行任务后产出的、可以被外部引用、复核、哈希、归档和验收的结果载体。

典型 artifact 包括：
- Markdown 报告
- Git patch / diff
- JSON 结构化输出
- HTML playground
- 测试结果文件
- 审计日志
- 执行 manifest
- usage receipts 汇总

---

## 2. 为什么要“可验证”

普通文件只能“看一眼”，可验证 artifact 才能支持：

1. **链上承诺**
   - 把 hash 提交上链，而不是全文上链

2. **争议与复核**
   - dispute 时能确认“这就是当时提交的那个结果”

3. **结果归因**
   - 结果能追溯到某次任务、某个 claim、某个 worker

4. **自动验收**
   - 对一部分结果可以脚本化验证，而不只是人工 review

---

## 3. artifact 的最小分类

建议先把 artifact 分成 5 大类：

### 3.1 Report 类
- Markdown 报告
- 分析摘要
- 风险说明
- 设计建议

特点：
- 人工可读性强
- 自动验证难度高
- 最适合 hash + reviewer 审核

### 3.2 Patch 类
- git diff
- patch 文件
- 代码修改建议

特点：
- 可被测试系统消费
- 更适合进入自动验收链路
- 容易与 commit / diff hash 关联

### 3.3 Structured Output 类
- JSON
- CSV
- schema 化结果
- 参数表

特点：
- 最适合自动验证
- 最适合 challenge / compare / replay

### 3.4 Interactive / HTML 类
- HTML playground
- 交互式架构图
- 参数调整界面

特点：
- 人机协作价值高
- 自动验证中等难度
- 更适合作为辅助 artifact

### 3.5 Execution / Audit 类
- execution manifest
- usage receipts
- tool trace
- 审计日志

特点：
- 不是任务目标本身
- 但对 dispute / accounting / policy 检查极其关键

---

## 4. 一个 artifact 至少应该包含什么元信息

无论类型如何，建议每个 artifact 至少具备以下元信息：

| 字段 | 说明 |
|------|------|
| `artifactId` | 唯一标识 |
| `taskId` | 所属任务 |
| `claimId` | 所属认领 |
| `workerId` | 产出该结果的 worker |
| `artifactType` | report / patch / json / html / log |
| `uri` | 外部存储位置 |
| `hash` | 内容哈希 |
| `createdAt` | 生成时间 |
| `mimeType` | 文件类型 |
| `version` | artifact schema 版本 |

### 为什么 `version` 重要

如果未来要做：
- 自动验收器升级
- dispute 回放
- 跨 worker 结果比较

你必须知道这个 artifact 是按哪个 schema 生成的。

---

## 5. 推荐的承诺方式

### 5.1 不要把全文直接写链上

尤其是：
- 报告
- diff
- HTML
- 大型 JSON

建议链上只写：
- `artifactHash`
- `summaryHash`
- `uri`
- `type`

### 5.2 推荐组合

```text
artifactUri      -> 实际内容
artifactHash     -> 原文 hash
summaryHash      -> 摘要 hash
manifestHash     -> 执行清单 hash
```

这样可以支持：
- 快速比对摘要
- 需要时下载原文复核
- dispute 时关联 manifest 与 receipts

---

## 6. 哪些 artifact 最适合自动验收

### 高适合度

#### JSON 结构化结果
例如：
- 风险列表
- 参数建议
- 地址分类
- 交易路径结果

原因：
- 可 schema 校验
- 可字段级比较
- 可被 challenge system 消费

#### Patch / Diff
例如：
- 自动生成补丁
- 配置修复建议
- 脚本变更

原因：
- 可跑测试
- 可跑 lint / typecheck
- 可与预期路径比对

### 中适合度

#### HTML playground
例如：
- 架构图
- 参数控制面板
- 可交互布局

原因：
- 可做基本结构检查
- 但高质量判断仍需人工

### 低适合度

#### 长篇分析报告
原因：
- 自动验证难
- 仍依赖 reviewer 或 arbitration

---

## 7. artifact 与 `pi-worker` 的关系

### 7.1 为什么不能只提交“最终答案”

`pi-worker` 的价值不只是写出一句结果，而是可能产出：
- 推理过程的摘要
- 使用了哪些 skill / extension
- 哪些工具产生了哪些中间产物
- 最终交付物与验证材料

### 7.2 建议的 artifact bundle

对于一个任务，建议至少形成一个 bundle：

```text
bundle/
├── manifest.json
├── result.json / report.md / patch.diff
├── summary.json
├── receipts.json
└── metadata.json
```

这样：
- 交付物和验证材料在一起
- 争议时不需要重新拼装上下文

---

## 8. 可验证 artifact 的三级成熟度

### Level 1：可承诺

要求：
- 有 hash
- 有 uri
- 能确认“这就是提交的结果”

适合：
- MVP

### Level 2：可校验

要求：
- 有 schema
- 有自动检查脚本
- 结果能被脚本部分验证

适合：
- 平台化阶段

### Level 3：可挑战

要求：
- artifact 与 receipt / manifest / policy 可以关联
- challenge 方能指出具体不一致
- 系统支持 dispute resolution

适合：
- 更成熟的开放 worker 网络

---

## 9. artifact 与支付层的关系

artifact 不是孤立存在的，它和支付层必须关联。

### 关键关系

- `artifactHash` 对应某次执行结果
- `executionManifest` 说明用了哪些模型 / skills / tools
- `UsageReceipt` 说明花了多少钱
- `SettlementRecord` 说明如何清算

如果这几层无法关联，就会出现：
- 不知道这份报告对应哪次收费
- 不知道这个 patch 是否由超预算执行产生
- dispute 时无法审计成本合理性

---

## 10. 适合链上存什么，不适合存什么

### 适合链上存
- artifact hash
- summary hash
- result type
- manifest hash
- 验收状态
- settlement 摘要

### 不适合链上存
- 长报告全文
- diff 全文
- 大型 HTML
- 大量日志
- usage 明细原文

这些内容应放在链下存储，再通过 hash 与链上状态关联。

---

## 11. 推荐推进顺序

### 第一阶段
- 为每个任务结果生成 artifact hash
- 链上只记录 result commitment

### 第二阶段
- 统一 artifact bundle 结构
- 引入 JSON schema / patch validation

### 第三阶段
- artifact 与 manifest / receipts / policy 联动
- 支持 challenge / dispute / replay

---

## 12. 一句话总结

**可验证 artifact 的本质，是把 `pi-worker` 的“输出文件”提升为“可被承诺、可被校验、可被争议、可与支付和任务状态关联的结果对象”；没有这层设计，链上任务系统很难从人工信任走向可审计与可扩展。**
