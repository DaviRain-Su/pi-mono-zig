# Bub 与 pi-mono 设计理念对比

> 通过对比 Bub 框架，深入理解 pi-mono 的设计选择。

---

## 概述

**Bub** 和 **pi-mono** 都是优秀的 Agent 框架，但源于不同场景，形成了截然不同的设计理念：

| 框架 | 起源场景 | 核心理念 | 设计重心 |
|------|---------|---------|---------|
| **Bub** | 群组聊天（多人多Agent共存） | "Socialized Agent" | 通用形状、社会化共存 |
| **pi-mono** | 个人编程助手 | "Agent构建Agent" | 代码自举、人在回路 |

---

## 核心定位对比

### Bub：社会化 Agent

```
群组聊天场景
├── 多人同时与 Agent 对话
├── 多个 Agent 同时运行
├── 并发任务、不完整上下文
└── 没有人在等待
```

> "We care less about whether an agent can finish a demo task, and more about whether it can coexist with real people under real conditions."
> 
> — Bub 文档

### pi-mono：编程 Agent

```
个人编程场景
├── 一对一对话
├── 代码为中心
├── 迭代开发、版本控制
└── 人在关键决策点介入
```

> "The core design is 'Agent writes code to extend itself'"
>
> — pi-mono 文档

---

## 架构对比

### Bub：Hook-First 管道

```
┌─────────────────────────────────────────┐
│  统一管道（所有渠道共用）                 │
│                                         │
│  resolve_session                        │
│       ↓                                 │
│  load_state                             │
│       ↓                                 │
│  build_prompt ←── 可覆盖                │
│       ↓                                 │
│  run_model  ←── 可覆盖                  │
│       ↓                                 │
│  save_state                             │
│       ↓                                 │
│  render_outbound                        │
│       ↓                                 │
│  dispatch_outbound                      │
└─────────────────────────────────────────┘
```

**核心代码仅 ~200 行**，所有功能都是插件。

### pi-mono：五层架构

```
┌─────────────────────────────────────────┐
│  Layer 5: Host (TUI/Web)                │
│  - 终端界面、Web 界面                    │
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
│  - Node.js, File System, Network        │
└─────────────────────────────────────────┘
```

**清晰的层次分离**，每层职责明确。

---

## 关键设计差异详解

### 1. 扩展机制

#### Bub：Hook 覆盖

基于 [pluggy](https://pluggy.readthedocs.io/) 的 hook 系统：

```python
from bub import hookimpl

class MyPlugin:
    @hookimpl
    def build_prompt(self, message, session_id, state):
        # 覆盖默认的 prompt 构建
        return f"[custom] {message['content']}"
    
    @hookimpl
    async def run_model(self, prompt, session_id, state):
        # 覆盖默认的模型调用
        return await my_custom_llm(prompt)
```

**特点**：
- 运行时 hook 优先级
- 后注册的插件优先
- 任何 hook 都可覆盖
- 无需了解内部实现

#### pi-mono：API 注册

通过 TypeScript API 显式注册：

```typescript
export default function myExtension(pi: ExtensionAPI) {
  // 注册工具
  pi.registerTool({
    name: 'my-tool',
    description: '...',
    parameters: Type.Object({...}),
    execute: async (toolCallId, args, signal, onUpdate, ctx) => {...},
  });
  
  // 注册命令
  pi.registerCommand('my-cmd', {
    description: '...',
    execute: async (ctx) => {...},
  });
  
  // 监听事件
  pi.on('tool_call', async (event) => {...});
}
```

**特点**：
- 编译时类型安全
- 显式注册，清晰可控
- 事件可拦截、可修改
- 需要了解 API 设计

**对比**：

| 维度 | Bub | pi-mono |
|------|-----|---------|
| 灵活性 | 极高（任何 hook 可覆盖） | 高（限定 API） |
| 类型安全 | 运行时 | 编译时 |
| 学习成本 | 低（了解 hook 名即可） | 中（需了解 API） |
| 可维护性 | 依赖文档 | 类型提示 |

---

### 2. 上下文管理

#### Bub：Tape（磁带）

Append-only 的事实记录：

```
[t1] User: 帮我写代码
[t2] Agent: 写了函数 foo()
[t3] Anchor: phase=implementation  ← 阶段标记
[t4] User: 改一下
[t5] Agent: 修改完成
```

**核心理念**：
> "Context is not baggage to carry forever — it is a working set, constructed when needed and let go when done."

- **按需组装**：不是累积，而是构造
- **Anchors 标记**：阶段转换点
- **用完即弃**：不保留完整历史

#### pi-mono：Session Tree（会话树）

分支版本控制：

```
          [root]
            │
    ┌───────┴───────┐
 [branch A]      [branch B]
    │                │
 [继续开发]        [实验新方案]
    │                │
 [v1完成]         [实验失败]
                       │
                   [回到A]
```

**核心理念**：
> "Safe experimentation through branching"

- **安全实验**：尝试不破坏主线
- **方案对比**：并行探索多种方案
- **完整历史**：所有尝试都被记录
- **人在回路**：关键决策点强制介入

**对比**：

| 维度 | Bub Tape | pi-mono Session Tree |
|------|----------|---------------------|
| 数据模型 | Append-only log | Tree with branches |
| 历史保留 | 选择性（按需构造） | 完整保留 |
| 实验支持 | 通过 Anchor 标记 | 通过 /fork 分支 |
| 适用场景 | 多任务、快速切换 | 深度迭代、方案对比 |
| 内存效率 | 高（不累积） | 中（压缩机制） |

---

### 3. Skill 系统

#### Bub：严格验证

```yaml
---
name: my-skill              # 必须匹配目录名
description: 描述           # ≤1024字符
metadata:                   # string→string
  key: value
---

# SKILL.md 内容
```

**验证规则**：
- 目录名必须匹配 `name`
- `name` 必须符合 `^[a-z0-9]+(?:-[a-z0-9]+)*$`
- `name` 长度 ≤ 64
- `description` 长度 ≤ 1024
- `metadata` 必须是 `string→string`

**发现路径**：
1. project: `.agents/skills`
2. user: `~/.agents/skills`
3. builtin: `src/skills`

#### pi-mono：渐进披露

```yaml
---
name: my-skill
description: 简短描述（常驻上下文）
---

# 详细内容（按需加载）
```

**特点**：
- 宽松解析
- 描述常驻系统提示
- 完整内容按需加载
- 渐进式披露

**对比**：

| 维度 | Bub | pi-mono |
|------|-----|---------|
| 验证严格度 | 高 | 低 |
| 命名规范 | 强制 kebab-case | 无强制 |
| 上下文管理 | 完整加载 | 渐进披露 |
| 质量保障 | 前置验证 | 后置使用 |

---

### 4. 多用户/多渠道支持

#### Bub：原生多用户

```python
# 统一管道，渠道无关
async def process_inbound(self, inbound: Envelope):
    # 无论 CLI、Telegram 还是自定义渠道
    # 都走相同的 hook 管道
    ...

# 渠道通过 hook 提供
@hookimpl
def provide_channels(self, message_handler):
    return [TelegramChannel(...), CliChannel(...)]
```

**设计**：
- 渠道通过 `provide_channels` hook 注册
- 统一 `process_inbound()` 处理
- Hooks 不知道自己在哪个渠道

#### pi-mono：Mode 抽象

```typescript
// packages/coding-agent/src/modes/
├── interactive/          # TUI 模式
│   └── interactive-mode.ts
├── print-mode.ts         # 打印模式
├── rpc/                  # RPC 模式
│   └── rpc-mode.ts
└── rpc.ts
```

**设计**：
- 不同 mode 独立实现
- 共享核心 AgentSession
- 通过 SDK/RPC/Web UI 暴露

**对比**：

| 维度 | Bub | pi-mono |
|------|-----|---------|
| 多用户 | 原生支持 | 单用户为主 |
| 渠道扩展 | Hook 注册 | Mode 实现 |
| 复杂度 | 低（统一管道） | 中（Mode 分离） |
| 适用场景 | 群组、多Agent | 个人、编程 |

---

## 技术栈对比

| 方面 | Bub | pi-mono |
|------|-----|---------|
| **语言** | Python | TypeScript |
| **包管理** | uv/pip | npm |
| **扩展机制** | pluggy hooks | TypeScript API |
| **CLI 框架** | Typer | 自定义 TUI |
| **配置** | 环境变量 | settings.json |
| **类型系统** | 运行时 | 编译时 |
| **内置 UI** | CLI only | TUI + Web UI |
| **模型抽象** | 直接 HTTP | packages/ai |

---

## 设计哲学对比

### Bub：Context as Working Set

```
传统：Context = 累积的历史
Bub：  Context = 按需构造的工作集

优势：
- 不累积 baggage
- 快速切换上下文
- 适合多任务场景

代价：
- 可能丢失历史细节
- 需要精心设计 Anchor
```

### pi-mono：Context as Version Control

```
传统：Context = 线性历史
pi：   Context = 版本控制树

优势：
- 安全实验
- 完整可追溯
- 强制人在回路

代价：
- 需要管理分支
- 压缩机制复杂
```

---

## 相互借鉴

### Bub 可以借鉴 pi-mono

| pi-mono 特性 | Bub 应用价值 |
|-------------|-------------|
| **会话树** | 比 Tape 更适合复杂任务迭代 |
| **热重载** | 提升开发体验 |
| **TUI 界面** | 当前只有 CLI，可补充 |
| **成本显示** | 透明化 token 消耗 |

### pi-mono 可以借鉴 Bub

| Bub 特性 | pi-mono 应用价值 |
|---------|-----------------|
| **Hook-first** | 简化扩展 API 设计 |
| **严格 Skill 验证** | 提高 Skill 质量 |
| **多用户原生** | 扩展应用场景 |
| **轻量核心** | 减少概念负担 |

---

## 适用场景推荐

| 场景 | 推荐框架 | 理由 |
|------|---------|------|
| 群组聊天机器人 | **Bub** | 原生多用户支持 |
| 个人编程助手 | **pi-mono** | 代码为中心的设计 |
| 多 Agent 协作 | **Bub** | 社会化 Agent 设计 |
| 代码迭代开发 | **pi-mono** | 会话树 + 热重载 |
| 快速原型 | 两者皆可 | 都支持快速扩展 |
| 生产级系统 | **pi-mono** | 类型安全 + 完整架构 |
| 教育/学习 | **pi-mono** | 清晰的架构层次 |

---

## 总结

| 维度 | Bub | pi-mono |
|------|-----|---------|
| **一句话** | 社会化 Agent 的通用形状 | 自举式编程 Agent |
| **核心创新** | Hook-first + Tape 上下文 | 会话树 + 热重载扩展 |
| **最佳场景** | 群组/多用户/多 Agent | 个人编程/代码迭代 |
| **架构复杂度** | 极简（~200行核心） | 完整（五层架构） |
| **扩展灵活性** | 极高 | 高 |
| **类型安全** | 运行时 | 编译时 |

两者代表了 Agent 框架设计的两个方向：

- **Bub** 偏向**社会化、通用化**——让 Agent 能在复杂的人类环境中共存
- **pi-mono** 偏向**专业化、自举化**——让 Agent 能编写代码扩展自己

选择取决于你的核心场景：是**多人协作的开放环境**，还是**深度迭代的编程工作流**。

---

## 性能对比

### 启动时间

| 指标 | Bub | pi-mono |
|------|-----|---------|
| **冷启动** | ~100ms (Python) | ~500ms (Node.js) |
| **扩展加载** | 动态 import | 文件扫描 + jiti |
| **Skill 发现** | 扫描 3 个目录 | 扫描 2 个目录 |

**分析**：
- Bub 的 Python 启动更快，但扩展加载在首次调用时延迟
- pi-mono 的 Node.js 启动较慢，但 TypeScript 编译缓存后稳定

### 运行时性能

| 场景 | Bub | pi-mono |
|------|-----|---------|
| **单轮对话** | ~50ms (hook 调用) | ~80ms (事件分发) |
| **工具执行** | 同步/异步自动适配 | 显式 async/await |
| **上下文切换** | 极快 (Tape 按需) | 中等 (Session 加载) |
| **并发处理** | 原生 async | 单用户顺序 |

**分析**：
- Bub 的 hook 系统轻量，适合高频多用户场景
- pi-mono 的事件系统更重，但提供更强的拦截能力

### 内存占用

| 指标 | Bub | pi-mono |
|------|-----|---------|
| **基础内存** | ~30MB (Python) | ~100MB (Node.js) |
| **每会话开销** | ~1MB (Tape 按需) | ~5MB (Session 树) |
| **扩展内存** | 运行时加载 | 启动时加载 |

**分析**：
- Bub 内存效率更高，适合多会话场景
- pi-mono 内存占用大，但功能更完整

### 扩展开发性能

| 指标 | Bub | pi-mono |
|------|-----|---------|
| **热重载** | 需重启 | `/reload` 即时 |
| **类型检查** | 运行时 | 编译时 |
| **调试体验** | pdb/ipdb | Chrome DevTools |
| **反馈周期** | 慢（需重启） | 快（即时重载） |

**pi-mono 优势**：热重载是核心设计，开发体验显著优于 Bub。

---

## 生态系统对比

### 核心项目

| 项目 | Bub | pi-mono |
|------|-----|---------|
| **主仓库** | bubbuild/bub | badlogic/pi-mono |
| **Stars** | ~100 | ~500 |
| **语言** | Python | TypeScript |
| **包管理** | uv/pip | npm |
| **CLI** | Typer | 自定义 TUI |

### 扩展/插件生态

| 类型 | Bub | pi-mono |
|------|-----|---------|
| **官方扩展** | 少（内置为主） | 多（GitHub 搜索） |
| **社区扩展** | 早期 | 较成熟 |
| **Skill 市场** | 无 | 无 |
| **工具库** | 依赖 Python 生态 | 依赖 npm 生态 |

**分析**：
- Bub 处于早期，生态尚未建立
- pi-mono 有更活跃的社区和更多示例

### 集成支持

| 集成 | Bub | pi-mono |
|------|-----|---------|
| **Telegram** | ✅ 原生 | ❌ 需扩展 |
| **Discord** | ❌ 需实现 | ❌ 需扩展 |
| **Web UI** | ❌ 无 | ✅ 内置 |
| **VS Code** | ❌ 无 | ✅ 扩展 |
| **SDK** | ❌ 无 | ✅ 完整 |
| **RPC** | ❌ 无 | ✅ 内置 |

**分析**：
- Bub 专注聊天渠道（Telegram）
- pi-mono 专注开发体验（Web UI/VS Code/SDK）

### 文档与学习资源

| 资源 | Bub | pi-mono |
|------|-----|---------|
| **官方文档** | 简洁 | 完整 |
| **API 文档** | 源码注释 | 类型定义 |
| **教程** | 少 | 多 |
| **示例项目** | 少 | 多 |
| **中文文档** | 无 | ✅ 完整 |

**分析**：
- Bub 文档简洁但不够详细
- pi-mono 中文文档是显著优势

### 社区活跃度

| 指标 | Bub | pi-mono |
|------|-----|---------|
| **GitHub Issues** | 少 | 活跃 |
| **Discord/论坛** | 无 | 无 |
| **贡献者** | 少 | 多 |
| **更新频率** | 早期快速迭代 | 稳定 |

---

## 迁移指南

### 从 Bub 迁移到 pi-mono

#### 场景：需要更好的开发体验

**1. 扩展迁移**

Bub Hook:
```python
from bub import hookimpl

class MyPlugin:
    @hookimpl
    def build_prompt(self, message, session_id, state):
        return f"[custom] {message['content']}"
```

pi-mono 等价:
```typescript
export default function myExtension(pi: ExtensionAPI) {
  // 通过事件拦截实现类似效果
  pi.on('before_provider_request', async (event) => {
    // 修改请求
    return { payload: modifiedPayload };
  });
}
```

**2. Skill 迁移**

Bub Skill:
```yaml
---
name: my-skill
description: ...
---
# 内容
```

pi-mono Skill:
```yaml
---
name: my-skill
description: ...
---
# 内容（相同格式）
```

**注意**：pi-mono 的 Skill 验证更宽松，可能需要调整。

**3. 工具迁移**

Bub Tool:
```python
from bub.tools import tool

@tool
def my_tool(arg: str) -> str:
    return f"result: {arg}"
```

pi-mono Tool:
```typescript
pi.registerTool({
  name: 'my-tool',
  description: '...',
  parameters: Type.Object({ arg: Type.String() }),
  execute: async (toolCallId, args, signal, onUpdate, ctx) => ({
    content: [{ type: 'text', text: `result: ${args.arg}` }]
  }),
});
```

**4. 会话管理适应**

- Bub: Tape 按需构造 → pi-mono: Session Tree 完整保留
- 使用 `/tree` 和 `/fork` 替代 Anchor 标记
- 适应分支思维而非阶段标记

### 从 pi-mono 迁移到 Bub

#### 场景：需要多用户/群组支持

**1. 扩展迁移**

pi-mono Extension:
```typescript
export default function myExtension(pi: ExtensionAPI) {
  pi.registerTool({...});
  pi.registerCommand('cmd', {...});
}
```

Bub 等价:
```python
from bub import hookimpl

class MyPlugin:
    @hookimpl
    def build_prompt(self, message, session_id, state):
        # 工具通过 import 副作用注册
        from . import tools
        return prompt
    
    @hookimpl
    def register_cli_commands(self, app):
        # 注册 CLI 命令
        pass
```

**2. 事件系统适应**

- pi-mono: 丰富的事件类型（agent_start, tool_call, ...）
- Bub: 简化的 hook 系统（build_prompt, run_model, ...）
- 需要重新设计拦截逻辑

**3. UI 适应**

- pi-mono: 丰富的 TUI（输入框、状态栏、快捷键）
- Bub: 仅 CLI 输出
- 需要适应更简单的交互模式

**4. 会话管理适应**

- pi-mono: Session Tree 分支管理 → Bub: Tape 按需构造
- 放弃分支思维，改用 Anchor 标记阶段
- 适应更轻量的上下文管理

### 混合使用策略

#### 场景：同时需要两种能力

**方案 1：Bub 作为后端，pi-mono 作为前端**
```
用户 → pi-mono TUI → Bub RPC API → 模型
```

**方案 2：按场景选择**
- 群组场景：Bub
- 编程场景：pi-mono

**方案 3：提取公共逻辑**
- Skill 文件格式兼容
- 工具定义可共享
- 业务逻辑抽象为库

---

## 决策流程图

```
开始
  │
  ├── 需要群组/多用户支持？
  │   ├── 是 → Bub
  │   └── 否 →
  │       ├── 需要热重载开发体验？
  │       │   ├── 是 → pi-mono
  │       │   └── 否 →
  │       │       ├── 需要类型安全？
  │       │       │   ├── 是 → pi-mono
  │       │       │   └── 否 →
  │       │       │       ├── 偏好 Python？
  │       │       │       │   ├── 是 → Bub
   │       │       │       │   └── 否 → pi-mono
  │       │       │       └──
  │       │       └──
  │       └──
  └──
```

---

## 参考链接

- **Bub**: https://github.com/bubbuild/bub
- **Bub 架构文档**: https://bub.build/docs/architecture
- **Tape 系统**: https://tape.systems
- **pi-mono**: https://github.com/badlogic/pi-mono
- **pi-mono 中文文档**: ../guide/
