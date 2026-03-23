# DASN 研究线

> 围绕 DASN（Decentralized Agent Service Network，去中心化 Agent 服务网络）的愿景、协议标准、集成方式、原型实现、测试策略与 SDK 设计。

---

## 这组文档解决什么问题

这条文档线不再只讨论 `pi-worker + Solana/Sui` 的单链任务执行与结算，而是进一步上升到：

- Agent 服务网络应该如何定义
- 现有 Agent 协议标准如何对接
- DASN 与 ERC-8004 / Vouch / MCP / A2A 等协议是什么关系
- 如果把 `pi-mono` 推向更完整的协议层与 SDK 层，应如何抽象

因此，这个目录更适合被理解为：

> **`pi-mono` 区块链专题的研究线 / 愿景线 / 标准化线**

而不是 Solana 或 Sui 的实现细节补充。

---

## 与其他子专题的关系

### 与 `../solana/`
- `solana/` 更偏实现路线
- 关注任务、预算、结算、runtime、审计、可观测性

### 与 `../sui/`
- `sui/` 更偏对象模型与 Move 合约实现
- 是另一条链实现的平行方案

### 与本目录
- `dasn/` 更偏网络层抽象、协议标准、研究设计与 SDK
- 重点不在单链落地，而在跨链与标准化抽象

---

## 推荐阅读顺序

1. [19-dasn-vision.md](./19-dasn-vision.md)
   - 先理解 DASN 的整体愿景、角色分层和经济模型

2. [20-agent-protocols-analysis.md](./20-agent-protocols-analysis.md)
   - 看现有协议生态：ERC-8004、Solana 注册协议、Vouch 等

3. [21-dasn-protocol-integration.md](./21-dasn-protocol-integration.md)
   - 看 DASN 与这些协议如何衔接

4. [22-dasn-prototype-design.md](./22-dasn-prototype-design.md)
   - 看一个可运行原型如何设计

5. [23-dasn-testing-strategy.md](./23-dasn-testing-strategy.md)
   - 看测试、验证和实验方法

6. [24-dasn-standard-proposal.md](./24-dasn-standard-proposal.md)
   - 看标准提案层的抽象方向

7. [25-dasn-sdk-design.md](./25-dasn-sdk-design.md)
   - 看 SDK 层如何为未来生态提供开发接口

---

## 文档列表

- [19-dasn-vision.md](./19-dasn-vision.md) - DASN 愿景与网络分层
- [20-agent-protocols-analysis.md](./20-agent-protocols-analysis.md) - Agent 协议标准全景分析
- [21-dasn-protocol-integration.md](./21-dasn-protocol-integration.md) - DASN 协议整合实现
- [22-dasn-prototype-design.md](./22-dasn-prototype-design.md) - DASN 原型设计
- [23-dasn-testing-strategy.md](./23-dasn-testing-strategy.md) - DASN 测试策略
- [24-dasn-standard-proposal.md](./24-dasn-standard-proposal.md) - DASN 标准提案
- [25-dasn-sdk-design.md](./25-dasn-sdk-design.md) - DASN SDK 设计

---

## 一句话总结

**如果说 `solana/` 和 `sui/` 关注的是“怎么把 pi-worker 放到具体链上跑起来”，那么 `dasn/` 关注的就是“如何把这些能力抽象成一个可扩展、可互操作、可标准化的去中心化 Agent 服务网络”。**
