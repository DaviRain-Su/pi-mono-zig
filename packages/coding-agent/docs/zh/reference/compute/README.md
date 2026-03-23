# Compute / Worker 基础设施研究线

> 围绕 `pi-worker` / `dAgent Worker` 的执行平面、部署位置、Cloudflare Worker 对比、去中心化计算平台与基础设施选择的研究文档。

---

## 这组文档解决什么问题

这条研究线不直接讨论链上 Task / Escrow / Dispute 等协议对象，而是回答执行层与基础设施层的问题：

- `pi-worker` 跑在 Cloudflare Worker 上意味着什么
- 去中心化 Worker 与中心化 serverless 平台的差异是什么
- 如果要让 Worker 真正去中心化，部署模型应该如何设计
- EigenCompute、ICP、Akash、TEE 平台等到底分别适合什么场景

因此，这个目录更适合被理解为：

> **`pi-worker` / Agent Runtime 的 Compute / Worker / Deployment 基础设施研究线**

而不是区块链协议专题本身。

---

## 与其他文档的关系

### 与 `../zig/`
- `zig/` 更偏系统层、Runtime、SDK、多 Agent 抽象
- 本目录更偏执行平面与基础设施落地

### 与 `../../blockchain/`
- `blockchain/` 关注任务、支付、声誉、争议与协议设计
- 本目录关注 Worker 实际跑在哪里、如何部署、如何验证执行环境

### 与本目录
- `compute/` 更偏 Cloudflare vs 去中心化、部署模型、算力平台比较
- 重点不是链上建模，而是执行基础设施选型

---

## 推荐阅读顺序

1. [34-cloudflare-worker-vs-decentralized.md](./34-cloudflare-worker-vs-decentralized.md)
   - 先理解 Cloudflare Worker 与去中心化 Worker 的架构差异

2. [35-decentralized-worker-deployment-guide.md](./35-decentralized-worker-deployment-guide.md)
   - 看从个人电脑到企业级集群的部署路径

3. [36-decentralized-compute-platforms-analysis.md](./36-decentralized-compute-platforms-analysis.md)
   - 看 EigenCompute、ICP 等平台的优缺点与适配性

4. [37-comprehensive-decentralized-compute-landscape.md](./37-comprehensive-decentralized-compute-landscape.md)
   - 看更广义的去中心化计算版图与多生态选择

---

## 文档列表

- [34-cloudflare-worker-vs-decentralized.md](./34-cloudflare-worker-vs-decentralized.md) - Cloudflare Worker vs 去中心化 Worker 分析
- [35-decentralized-worker-deployment-guide.md](./35-decentralized-worker-deployment-guide.md) - 去中心化 Worker 部署完全指南
- [36-decentralized-compute-platforms-analysis.md](./36-decentralized-compute-platforms-analysis.md) - 去中心化计算平台全景分析
- [37-comprehensive-decentralized-compute-landscape.md](./37-comprehensive-decentralized-compute-landscape.md) - 去中心化计算平台全景扫描

---

## 一句话总结

**如果说 `blockchain/` 讨论的是“任务与支付协议如何成立”，那么这个 `compute/` 目录讨论的就是“这些 Agent / Worker 实际应该跑在哪、怎么跑、以及该选什么执行基础设施”。**
