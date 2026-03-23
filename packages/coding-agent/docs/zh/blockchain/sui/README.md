# Sui 专题文档

> pi-worker 与 Sui 区块链集成的完整技术文档

---

## 概述

本目录包含 pi-worker 与 Sui 区块链集成的完整技术文档。Sui 是一个高性能的 Layer 1 区块链，使用 Move 语言和对象模型，与 Solana 的账户模型有本质区别。

### Sui 的核心优势

- **对象模型**: 天然适合表示任务、结果等实体
- **低延迟**: 简单交易 ~200ms 确认
- **并行执行**: 对象级自动并行
- **Move 安全**: 资源导向编程防止双花

---

## 文档结构

### 基础概念
- [00-overview.md](./00-overview.md) - Sui 专题总览，与 Solana 的对比
- [02-task-models.md](./02-task-models.md) - Task / Claim / Result / Escrow / Dispute 对象设计

### 实现文档
- [10-sui-mvp-design.md](./10-sui-mvp-design.md) - MVP 对象模型与 Worker 接入闭环
- [11-sui-contract-instructions.md](./11-sui-contract-instructions.md) - Move 合约完整指令集 ✨
- [12-sui-budget-and-settlement.md](./12-sui-budget-and-settlement.md) - 预算与结算设计 ✨
- [13-sui-worker-runtime-integration.md](./13-sui-worker-runtime-integration.md) - Worker Runtime 集成 ✨
- [14-sui-dispute-and-reputation.md](./14-sui-dispute-and-reputation.md) - 争议与声誉设计 ✨
- [15-sui-market-and-selection.md](./15-sui-market-and-selection.md) - 任务市场与 Worker 选择 ✨
- [16-sui-security-and-audit.md](./16-sui-security-and-audit.md) - 安全与审计清单 ✨
- [17-sui-indexer-and-observability.md](./17-sui-indexer-and-observability.md) - 索引与可观测性 ✨
- [18-sui-implementation-checklist.md](./18-sui-implementation-checklist.md) - 实现清单 ✨

---

## 快速开始

### 1. 了解基础 (30分钟)
阅读 [00-overview.md](./00-overview.md) 理解 Sui 与 Solana 的核心差异。

### 2. 理解对象模型 (1小时)
阅读 [02-task-models.md](./02-task-models.md) 掌握 Task、WorkerCap、Result 等核心对象设计。

### 3. 查看 MVP 实现 (2小时)
阅读 [10-sui-mvp-design.md](./10-sui-mvp-design.md) 了解最小可行产品如何工作。

### 4. 准备开发
阅读 [18-sui-implementation-checklist.md](./18-sui-implementation-checklist.md) 按清单开始实现。

---

## 与 Solana 专题的关系

```
blockchain/
├── solana/           # Solana 实现 (参考)
├── sui/              # Sui 实现 (本目录)
└── shared/           # 共享概念 (待创建)
    ├── payment-layer.md
    ├── tee-integration.md
    └── cross-chain.md
```

Sui 实现参考 Solana 的设计，但针对 Sui 的对象模型进行了优化。

---

## 技术栈

- **语言**: Move
- **SDK**: `@mysten/sui`
- **CLI**: `sui`
- **测试网**: Sui Testnet
- **主网**: Sui Mainnet (未来)

---

## 当前状态

| 文档 | 状态 | 完成度 | 行数 |
|------|------|--------|------|
| 00-overview.md | ✅ 完成 | 100% | 214 |
| 02-task-models.md | ✅ 完成 | 100% | 380 |
| 10-sui-mvp-design.md | ✅ 完成 | 100% | 463 |
| 11-sui-contract-instructions.md | ✅ 完成 | 100% | 614 |
| 12-sui-budget-and-settlement.md | ✅ 完成 | 100% | 384 |
| 13-sui-worker-runtime-integration.md | ✅ 完成 | 100% | 483 |
| 14-sui-dispute-and-reputation.md | ✅ 完成 | 100% | 523 |
| 15-sui-market-and-selection.md | ✅ 完成 | 100% | 462 |
| 16-sui-security-and-audit.md | ✅ 完成 | 100% | 456 |
| 17-sui-indexer-and-observability.md | ✅ 完成 | 100% | 454 |
| 18-sui-implementation-checklist.md | ✅ 完成 | 100% | 454 |

**Sui 专题总计**: 11 个文件，~4,900+ 行

---

## 外部资源

### Sui 官方
- [Sui Documentation](https://docs.sui.io/)
- [Move Book](https://move-book.com/)
- [Sui TypeScript SDK](https://sdk.mystenlabs.com/typescript)

### pi 相关
- [Solana 实现](../09-solana-mvp-design.md) - 对比参考
- [Worker Runtime](../../guide/08-first-extension.md) - Worker 基础
- [扩展开发](../../reference/extensions.md) - 扩展开发指南

---

*本文档与 pi Sui 集成同步更新，最后更新时间：2026年3月23日*
