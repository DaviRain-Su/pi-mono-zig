# Zig / pi-mono 研究线

> 围绕 `pi-mono` 的 Zig 化、系统层级定位、多 Agent 演进、SDK / Runtime 分层，以及与外部 Agent 平台对比的研究文档。

---

## 这组文档解决什么问题

这条研究线不直接讨论当前 `pi` 的日常使用，而是回答更偏中长期演进的问题：

- 如果 `pi-mono` 用 Zig 重写，会得到什么样的系统能力边界
- `pi-mono` 应该被理解为 SDK、Runtime，还是更接近系统基础设施
- 从单 Agent 到多 Agent，需要补哪些运行时与协调层能力
- 与 Slock.ai 这类 Agent 协作平台相比，`pi-mono` / `pi-worker` 的差异是什么

因此，这个目录更适合被理解为：

> **`pi-mono` 的 Zig / Runtime / Multi-Agent / System Layer 研究线**

而不是当前实现文档的直接补充。

---

## 与其他文档的关系

### 与 `../architecture-overview.md`
- `architecture-overview.md` 解释当前 `pi-mono` 的实现边界
- 本目录讨论的是更激进的未来演进形态

### 与 `../../blockchain/`
- `blockchain/` 关注链下 worker 与链上任务/支付/声誉系统的结合
- 本目录更关注 runtime、OS、SDK、多 Agent 与系统层抽象

### 与本目录
- `zig/` 更偏未来架构研究、系统工程视角与产品/平台边界判断
- 重点不是“今天怎么用”，而是“下一代 pi 系统应该长成什么样”

---

## 推荐阅读顺序

1. [26-pi-mono-zig-vision.md](./26-pi-mono-zig-vision.md)
   - 先理解为什么会从 Zig 讨论到系统层能力

2. [27-zig-pi-technical-deep-dive.md](./27-zig-pi-technical-deep-dive.md)
   - 看内存、零拷贝、安全隔离等技术细节

3. [28-pi-mono-multi-agent-architecture.md](./28-pi-mono-multi-agent-architecture.md)
   - 看从单 Agent 到多 Agent 的演进路径

4. [29-zig-sdk-system-layer-analysis.md](./29-zig-sdk-system-layer-analysis.md)
   - 看 SDK / Runtime / OS 的层级界定

5. [30-slock-ai-analysis.md](./30-slock-ai-analysis.md)
   - 看外部 Agent 协作产品对 DASN / pi-worker 的启发

---

## 文档列表

- [26-pi-mono-zig-vision.md](./26-pi-mono-zig-vision.md) - pi-mono + Zig 愿景与系统内核化思考
- [27-zig-pi-technical-deep-dive.md](./27-zig-pi-technical-deep-dive.md) - Zig 技术深度分析
- [28-pi-mono-multi-agent-architecture.md](./28-pi-mono-multi-agent-architecture.md) - 多 Agent 架构演进
- [29-zig-sdk-system-layer-analysis.md](./29-zig-sdk-system-layer-analysis.md) - SDK / Runtime / OS 分层定位
- [30-slock-ai-analysis.md](./30-slock-ai-analysis.md) - Slock.ai 深度分析与对比

---

## 一句话总结

**如果说当前 `reference/` 主要解释的是“pi 今天是怎么工作的”，那么这个 `zig/` 目录讨论的就是“pi 将来可能演化成什么样的系统基础设施”。**
