# OpenCode (anomalyco) 与 pi-mono 深度对比

> 分析当前最热门的开源 AI 编程助手 OpenCode (~127k stars)，理解其与 pi-mono 的设计差异。

---

## 概述

| 项目 | OpenCode | pi-mono |
|------|----------|---------|
| **开发商** | Anomaly Co | 社区 |
| **Stars** | ~127,000 | ~500 |
| **语言** | TypeScript (Bun) | TypeScript (Node) |
| **许可证** | 开源 (未明确) | MIT |
| **定位** | 开源 Claude Code 替代品 | 可扩展 Agent 框架 |
| **架构** | Client/Server | 分层架构 |

---

## 核心架构对比

### OpenCode：Client/Server 架构

```
┌─────────────────────────────────────────┐
│  Client Layer (多前端)                   │
│  ├── TUI (Terminal) - SolidJS           │
│  ├── Web UI - SolidJS                   │
│  └── Desktop (Tauri)                    │
├─────────────────────────────────────────┤
│  Server Layer (Bun)                      │
│  ├── Agent Core                         │
│  ├── LSP Integration                    │
│  ├── MCP Support                        │
│  └── Plugin System                      │
├─────────────────────────────────────────┤
│  Provider Layer                          │
│  ├── OpenCode Zen (推荐)                │
│  ├── Claude                             │
│  ├── OpenAI                             │
│  ├── Google                             │
│  └── Local Models                       │
└─────────────────────────────────────────┘
```

**核心设计**：
- **Client/Server 分离**：TUI 只是客户端之一
- **多前端支持**：Terminal/Web/Desktop
- **Bun 运行时**：高性能 JavaScript 运行时
- **SolidJS + opentui**：终端 UI 框架

### pi-mono：分层架构

```
┌─────────────────────────────────────────┐
│  Layer 5: Host (TUI/Web)                │
├─────────────────────────────────────────┤
│  Layer 4: Application                   │
│  - AgentSession, ExtensionRunner        │
├─────────────────────────────────────────┤
│  Layer 3: Agent Core                    │
│  - Agent, AgentLoop, AgentTool          │
├─────────────────────────────────────────┤
│  Layer 2: AI Abstraction                │
│  - stream, api-registry, Providers      │
├─────────────────────────────────────────┤
│  Layer 1: Infrastructure                │
└─────────────────────────────────────────┘
```

**核心设计**：
- **五层分离**：每层职责明确
- **单进程**：TUI 与核心紧耦合
- **Node.js 生态**：兼容性优先
- **原生扩展**：TypeScript 直接扩展

---

## 功能深度对比

### 1. 多前端支持

#### OpenCode：真正的多前端

```typescript
// 架构设计支持任意客户端
Server (port 4096)
  ├── TUI Client    # 终端界面
  ├── Web Client    # 浏览器
  ├── Desktop App   # Tauri 包装
  └── Mobile App    # 未来可能
```

**关键能力**：
- TUI 只是客户端之一
- 可以远程驱动（手机控制电脑上的 OpenCode）
- Web 界面与 TUI 功能对等

#### pi-mono：TUI 为主

```typescript
// TUI 与核心紧耦合
Interactive Mode (TUI)
  └── AgentSession

Print Mode
  └── AgentSession

RPC Mode
  └── AgentSession (外部访问)
```

**限制**：
- Web UI 是独立实现
- 没有真正的 Client/Server 分离

**对比**：

| 特性 | OpenCode | pi-mono |
|------|----------|---------|
| TUI | ✅ | ✅ |
| Web UI | ✅ 内置 | ✅ 独立包 |
| Desktop | ✅ Tauri | ❌ |
| 远程控制 | ✅ | ❌ |
| 多客户端同时 | ✅ | ❌ |

---

### 2. Agent 系统

#### OpenCode：多 Agent 设计

```typescript
// 内置 Agents
- "build"   # 默认，完全访问
- "plan"    # 只读，分析规划
- "general" # 子代理，复杂搜索

// 切换方式
Tab 键切换
```

**plan agent**：
- 默认拒绝文件编辑
- 执行命令前询问权限
- 适合探索不熟悉的代码库

#### pi-mono：单 Agent + 扩展

```typescript
// 通过扩展实现不同行为
// 没有内置多 Agent
// 可以通过扩展模拟
```

**对比**：

| 特性 | OpenCode | pi-mono |
|------|----------|---------|
| 内置 Agents | ✅ 3个 | ❌ |
| Agent 切换 | Tab 键 | 需扩展 |
| 权限控制 | Agent 级别 | 工具级别 |
| 子代理 | ✅ @general | 需实现 |

---

### 3. 扩展机制

#### OpenCode：Plugin SDK

```typescript
// packages/plugin/src/index.ts
export type Plugin = (input: PluginInput) => Promise<Hooks>

export type PluginInput = {
  client: ReturnType<typeof createOpencodeClient>
  project: Project
  directory: string
  worktree: string
  serverUrl: URL
  $: BunShell
}

// 工具定义
export function tool<Args extends z.ZodRawShape>(input: {
  description: string
  args: Args
  execute(args: z.infer<z.ZodObject<Args>>, context: ToolContext): Promise<string>
}) {
  return input
}
```

**特点**：
- 官方 Plugin SDK
- Zod 类型安全
- Bun Shell 集成
- Auth 钩子支持

#### pi-mono：原生 Extension

```typescript
// 直接注册，无需 SDK
export default function myExtension(pi: ExtensionAPI) {
  pi.registerTool({
    name: 'my-tool',
    description: '...',
    parameters: Type.Object({...}),
    execute: async (toolCallId, args, signal, onUpdate, ctx) => {...}
  })
}
```

**对比**：

| 特性 | OpenCode | pi-mono |
|------|----------|---------|
| 扩展方式 | Plugin SDK | 原生 API |
| 类型安全 | Zod | TypeBox |
| 热重载 | ❌ | ✅ |
| 包管理 | npm (发布) | 文件系统 |
| 认证集成 | ✅ 内置 | ❌ |
| Shell 集成 | BunShell | 内置 exec |

---

### 4. LSP 集成

#### OpenCode：原生 LSP

```
内置 LSP 支持
├── 代码补全
├── 跳转到定义
├── 查找引用
└── 类型信息
```

**特点**：
- 开箱即用
- 自动检测项目 LSP
- 为 Agent 提供代码智能

#### pi-mono：无原生 LSP

```
需通过扩展实现
或依赖外部工具
```

**对比**：

| 特性 | OpenCode | pi-mono |
|------|----------|---------|
| LSP 支持 | ✅ 原生 | ❌ |
| 代码补全 | ✅ | ❌ |
| 类型信息 | ✅ | ❌ |

---

### 5. MCP 支持

#### OpenCode：原生 MCP

```typescript
// 内置 MCP 支持
// packages/opencode/src/mcp/
```

**特点**：
- 内置 MCP 客户端
- 支持 stdio/http/sse
- 工具自动发现

#### pi-mono：无 MCP

```
设计理念：Agent 写代码扩展自己
不依赖外部 MCP 服务器
```

**对比**：

| 特性 | OpenCode | pi-mono |
|------|----------|---------|
| MCP 客户端 | ✅ | ❌ |
| MCP 服务器 | 可消费 | 理念不同 |
| 工具生态 | MCP + Plugin | 原生扩展 |

---

### 6. 模型支持

#### OpenCode：Provider 无关

```
推荐：OpenCode Zen (官方)
支持：
- Claude
- OpenAI
- Google
- Local Models
```

**特点**：
- Provider 无关设计
- 通过 models.dev 管理模型列表
- 可切换任意模型

#### pi-mono：完全开放

```
任意 Provider
任意模型
完全自定义
```

**对比**：

| 特性 | OpenCode | pi-mono |
|------|----------|---------|
| 官方推荐 | OpenCode Zen | 无 |
| Claude | ✅ | ✅ |
| GPT | ✅ | ✅ |
| Gemini | ✅ | ✅ |
| 本地模型 | ✅ | ✅ |
| 自定义 Provider | ✅ | ✅ |

---

### 7. 开发体验

#### OpenCode：Bun 生态

```bash
# 开发
bun install
bun dev

# 调试
bun run --inspect=ws://localhost:6499/ dev
```

**特点**：
- Bun 运行时（高性能）
- SolidJS 响应式
- 复杂的调试设置

#### pi-mono：Node 生态

```bash
# 开发
npm install
npm run dev

# 热重载
/reload
```

**特点**：
- Node.js 兼容
- 热重载即时
- 简单调试

**对比**：

| 特性 | OpenCode | pi-mono |
|------|----------|---------|
| 运行时 | Bun | Node |
| 热重载 | ❌ | ✅ |
| 调试 | 复杂 | 简单 |
| 构建 | 需要 | 不需要 |
| 包大小 | 较大 | 较小 |

---

## 独特功能对比

### OpenCode 独有

| 功能 | 说明 |
|------|------|
| **Client/Server** | 真正的 C/S 架构 |
| **多前端** | TUI/Web/Desktop |
| **LSP 原生** | 代码智能 |
| **MCP 原生** | 工具生态 |
| **Bun 运行时** | 高性能 |
| **多 Agent** | build/plan/general |

### pi-mono 独有

| 功能 | 说明 |
|------|------|
| **热重载** | 扩展修改即时生效 |
| **会话树** | 分支版本控制 |
| **成本透明** | 实时显示费用 |
| **完全控制** | 可修改任何部分 |
| **极简核心** | 4个基础工具 |

---

## 适用场景

| 场景 | 推荐 | 理由 |
|------|------|------|
| **远程开发** | OpenCode | C/S 架构，可远程控制 |
| **Web 界面** | OpenCode | 内置 Web UI |
| **代码智能** | OpenCode | 原生 LSP |
| **MCP 生态** | OpenCode | 原生支持 |
| **热重载开发** | pi-mono | 即时生效 |
| **深度定制** | pi-mono | 完全开源 |
| **学习架构** | pi-mono | 清晰分层 |
| **极简部署** | pi-mono | 单包部署 |

---

## 架构哲学对比

### OpenCode：现代全栈

```
设计理念：
- 多前端是现代应用的标配
- Client/Server 分离是正确架构
- LSP 是代码工具的基础
- MCP 是工具集成的未来
- Bun 是高性能 JavaScript 的未来
```

### pi-mono：极简可控

```
设计理念：
- 简单比复杂好
- 可控比方便好
- 透明比隐藏好
- 热重载是开发体验的核心
- Agent 应该自举
```

---

## 性能对比

| 指标 | OpenCode | pi-mono |
|------|----------|---------|
| **启动时间** | 中等 (Bun) | 快 (Node) |
| **内存占用** | 较高 | 中等 |
| **UI 响应** | 极快 (SolidJS) | 快 |
| **构建时间** | 需要 | 不需要 |
| **包大小** | 较大 | 较小 |

---

## 生态系统

| 维度 | OpenCode | pi-mono |
|------|----------|---------|
| **Stars** | ~127k | ~500 |
| **社区** | 活跃 (Discord) | 较小 |
| **文档** | 完善 | 中文完整 |
| **插件** | SDK 发布 | 文件系统 |
| **商业** | 可能有 | 无 |

---

## 迁移指南

### OpenCode → pi-mono

**1. 架构适应**

```
OpenCode:              pi-mono:
Client/Server    →     单进程
多前端           →     TUI 为主
LSP 原生         →     需扩展
MCP 工具         →     原生扩展
```

**2. 扩展迁移**

```typescript
// OpenCode Plugin
export default definePlugin({
  tools: [{
    name: 'my-tool',
    execute: async (args, ctx) => {...}
  }]
})

// pi-mono Extension
export default function myExtension(pi) {
  pi.registerTool({
    name: 'my-tool',
    execute: async (toolCallId, args, signal, onUpdate, ctx) => {...}
  })
}
```

**3. 工作流调整**

- 放弃 Web UI → 使用 TUI
- 放弃 LSP → 使用外部编辑器
- 适应热重载 → 提升开发效率

### pi-mono → OpenCode

**1. 架构升级**

```
pi-mono:               OpenCode:
单进程           →     Client/Server
TUI 为主         →     多前端
原生扩展         →     Plugin SDK
热重载           →     重新构建
```

**2. 扩展迁移**

- 重写为 Plugin SDK
- 发布到 npm
- 处理认证集成

**3. 功能增强**

- 获得 LSP 支持
- 获得 Web UI
- 获得 MCP 生态

---

## 总结

| 维度 | OpenCode | pi-mono |
|------|----------|---------|
| **架构** | 现代 C/S | 经典分层 |
| **功能** | 丰富 | 精简 |
| **性能** | 高 | 中 |
| **复杂度** | 高 | 低 |
| **可控性** | 中 | 高 |
| **生态** | 大 | 小 |

**选择建议**：

- **要功能全面** → OpenCode
- **要简单可控** → pi-mono
- **要远程/Web** → OpenCode
- **要热重载** → pi-mono

两者代表了不同的设计哲学：
- **OpenCode**：现代全栈，功能优先
- **pi-mono**：极简可控，透明优先

---

## 参考链接

- **OpenCode**: https://github.com/anomalyco/opencode
- **OpenCode 官网**: https://opencode.ai
- **OpenCode 文档**: https://opencode.ai/docs
- **models.dev**: https://github.com/anomalyco/models.dev
- **pi-mono**: https://github.com/badlogic/pi-mono
- **pi-mono 中文文档**: ../guide/
