# Claude Code 与 pi-mono 对比

> 基于 Claude Code 官方文档的深入对比分析。

---

## 重要说明

**OpenCode 已归档**，其继任者是 **Crush**（由 Charm 开发）。本对比主要聚焦：
- **Claude Code** (Anthropic) - 闭源产品
- **pi-mono** - 开源框架

如需了解 Crush，请参考其官方文档：https://charm.sh/crush/

---

## 核心定位

| 维度 | Claude Code | pi-mono |
|------|-------------|---------|
| **开发商** | Anthropic | 社区 |
| **许可证** | 闭源 | MIT 开源 |
| **目标** | 产品（卖服务） | 框架（卖能力） |
| **Stars** | ~81k | ~500 |
| **核心哲学** | "Agentic coding tool" | "Agent构建Agent" |

---

## 架构对比

### Claude Code：集成式架构

```
┌─────────────────────────────────────────┐
│  Claude Code (闭源)                      │
│                                         │
│  ┌─────────────┐    ┌─────────────┐    │
│  │  TUI 界面   │◄───│  Agent Core │    │
│  │  (自定义)   │    │  (闭源)     │    │
│  └─────────────┘    └──────┬──────┘    │
│                            │           │
│              ┌─────────────┼─────────┐ │
│              ▼             ▼         ▼ │
│         ┌────────┐   ┌────────┐  ┌────┐│
│         │Tools   │   │Skills  │  │MCP ││
│         │(内置)  │   │(扩展)  │  │(外)││
│         └────────┘   └────────┘  └────┘│
└─────────────────────────────────────────┘
```

**特点**：
- 核心逻辑闭源
- 通过官方 API 扩展
- 深度优化 Claude 模型

### pi-mono：分层可扩展架构

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

**特点**：
- 完全开源透明
- 每层可替换
- 原生扩展机制

---

## 功能深度对比

### 1. 持久化指令系统

#### Claude Code：CLAUDE.md + 自动记忆

**CLAUDE.md**：
- 项目级持久化指令
- 自动加载到上下文
- 支持版本控制

```markdown
# CLAUDE.md

## 项目规范
- 使用 TypeScript
- 测试覆盖率 > 80%
- 遵循 Airbnb 代码规范

## 常用命令
- `npm test` - 运行测试
- `npm run build` - 构建项目
```

**自动记忆**：
- 自动积累学习内容
- 跨会话保持
- 用户可控

#### pi-mono：AGENTS.md + Skill

**AGENTS.md**：
- 类似 CLAUDE.md
- 加载到系统提示

**Skill**：
- 渐进式披露
- 按需加载详细内容
- 可版本控制

**对比**：

| 特性 | Claude Code | pi-mono |
|------|-------------|---------|
| 项目级指令 | ✅ CLAUDE.md | ✅ AGENTS.md |
| 自动记忆 | ✅ 内置 | ❌ 需扩展 |
| 渐进加载 | ❌ | ✅ Skill |
| 用户控制 | 中 | 高 |

---

### 2. 扩展机制

#### Claude Code：多层次扩展

**Skills**：
```yaml
# skill.yaml
name: my-skill
description: 描述
```

**Subagents**：
- 专用子代理
- 特定任务优化
- 并行执行

**Hooks**：
- 生命周期钩子
- 自定义行为

**MCP**：
- 外部服务器
- 标准协议

**Plugins**：
```typescript
// 官方插件 SDK
export default definePlugin({
  name: 'my-plugin',
  hooks: {
    beforeRequest: (ctx) => { ... }
  }
});
```

#### pi-mono：原生扩展

```typescript
export default function myExtension(pi: ExtensionAPI) {
  // 工具
  pi.registerTool({...});
  
  // 命令
  pi.registerCommand('cmd', {...});
  
  // 事件拦截
  pi.on('tool_call', async (e) => {...});
}
```

**对比**：

| 扩展方式 | Claude Code | pi-mono |
|---------|-------------|---------|
| Skills | ✅ | ✅ |
| Subagents | ✅ | ❌ |
| Hooks | ✅ | ✅ (事件) |
| MCP | ✅ | ❌ |
| Plugins | ✅ 官方 SDK | ✅ 原生 |
| 热重载 | ❌ | ✅ |

---

### 3. 上下文管理

#### Claude Code：自动管理

- **自动压缩**：达到限制时自动总结
- **记忆系统**：自动积累学习内容
- **线性会话**：单一线性历史

#### pi-mono：用户控制

- **Session Tree**：分支版本控制
- **手动压缩**：`/compact` 命令
- **完整历史**：所有分支保留

**对比**：

| 特性 | Claude Code | pi-mono |
|------|-------------|---------|
| 压缩 | 自动 | 手动 |
| 分支 | ❌ | ✅ |
| 历史保留 | 选择性 | 完整 |
| 用户控制 | 低 | 高 |

---

### 4. 工具系统

#### Claude Code：内置 + 扩展

**内置工具**：
- 文件操作（读/写/编辑）
- Bash 执行
- 代码搜索
- Git 操作
- 网页获取

**工具使用**：
- 自动选择
- 并行执行
- 结果反馈

#### pi-mono：极简 + 扩展

**内置工具**（4个）：
- Read
- Write
- Edit
- Bash

**扩展工具**：
- 通过 Extension 注册
- 自定义逻辑
- 流式更新

**对比**：

| 特性 | Claude Code | pi-mono |
|------|-------------|---------|
| 内置工具 | 丰富 | 极简 |
| 工具发现 | 自动 | 显式注册 |
| 并行执行 | ✅ | ✅ |
| 自定义工具 | 通过 MCP/Plugin | 原生支持 |

---

### 5. 模型支持

#### Claude Code：Claude 专属

- **锁定 Claude 模型**
- 深度优化
- 无法切换其他模型

#### pi-mono：多模型

- **任意模型**：通过 Provider 配置
- **切换模型**：`/model` 命令
- **自定义 Provider**：完全开放

**对比**：

| 特性 | Claude Code | pi-mono |
|------|-------------|---------|
| Claude | ✅ 原生 | ✅ 配置 |
| GPT | ❌ | ✅ |
| Gemini | ❌ | ✅ |
| 本地模型 | ❌ | ✅ |
| 切换成本 | N/A | 显示 |

---

### 6. 开发体验

#### Claude Code：产品体验

- **安装简单**：一行命令
- **开箱即用**：无需配置
- **自动更新**：官方推送
- **文档完善**：官方支持

#### pi-mono：框架体验

- **热重载**：`/reload` 即时生效
- **成本透明**：实时显示 token/费用
- **完全控制**：可修改任何部分
- **学习曲线**：需要了解架构

**对比**：

| 特性 | Claude Code | pi-mono |
|------|-------------|---------|
| 安装 | 简单 | 简单 |
| 配置 | 最少 | 较多 |
| 热重载 | ❌ | ✅ |
| 成本显示 | ❌ | ✅ |
| 自定义 | 受限 | 完全 |

---

## 独特功能对比

### Claude Code 独有

| 功能 | 说明 |
|------|------|
| **自动记忆** | 自动积累学习内容 |
| **Subagents** | 专用子代理 |
| **Claude 优化** | 深度模型优化 |
| **商业支持** | 官方技术支持 |

### pi-mono 独有

| 功能 | 说明 |
|------|------|
| **热重载** | 扩展修改即时生效 |
| **会话树** | 分支版本控制 |
| **成本透明** | 实时显示费用 |
| **完全开源** | 可修改任何部分 |

---

## 适用场景

| 场景 | 推荐 | 理由 |
|------|------|------|
| **快速上手** | Claude Code | 开箱即用 |
| **企业团队** | Claude Code | 商业支持 |
| **深度定制** | pi-mono | 完全控制 |
| **学习架构** | pi-mono | 开源透明 |
| **扩展开发** | pi-mono | 热重载 |
| **多模型对比** | pi-mono | 灵活切换 |
| **预算敏感** | pi-mono | 控制成本 |

---

## 迁移指南

### Claude Code → pi-mono

**1. 概念映射**

| Claude Code | pi-mono |
|-------------|---------|
| CLAUDE.md | AGENTS.md |
| Skills | Skills |
| Subagents | 需自行实现 |
| MCP | 需扩展支持 |
| Plugins | Extensions |

**2. 工作流调整**

```
Claude Code:        pi-mono:
自动压缩     →      手动 /compact
线性历史     →      /tree 分支管理
自动记忆     →      显式上下文管理
```

**3. 扩展迁移**

- Skills：格式兼容，直接复制
- Plugins：需重写为 Extension
- MCP：需包装为原生扩展

---

## 总结

| 维度 | Claude Code | pi-mono |
|------|-------------|---------|
| **定位** | 产品 | 框架 |
| **开源** | ❌ | ✅ |
| **易用性** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| **灵活性** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **扩展性** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **成本透明** | ❌ | ✅ |
| **热重载** | ❌ | ✅ |

**选择建议**：
- **要省心** → Claude Code
- **要控制** → pi-mono

两者不是竞争关系，而是**不同层次的选择**。

---

## 参考链接

- **Claude Code**: https://github.com/anthropics/claude-code
- **Claude Code 文档**: https://code.claude.com/docs
- **pi-mono**: https://github.com/badlogic/pi-mono
- **pi-mono 中文文档**: ../guide/
