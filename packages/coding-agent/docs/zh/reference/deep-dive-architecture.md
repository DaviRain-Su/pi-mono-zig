# pi 技术架构深度解析

> 基于源码的完整技术剖析，面向深度二次开发者和架构设计者。

## 目录

1. [核心架构分层](#1-核心架构分层)
2. [数据流与事件系统](#2-数据流与事件系统)
3. [扩展系统深度解析](#3-扩展系统深度解析)
4. [工具系统与执行模型](#4-工具系统与执行模型)
5. [会话管理与持久化](#5-会话管理与持久化)
6. [模型系统与Provider架构](#6-模型系统与provider架构)
7. [资源加载与生命周期](#7-资源加载与生命周期)
8. [二次开发实战指南](#8-二次开发实战指南)

---

## 1. 核心架构分层

### 1.1 五层架构详解

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 5: 宿主层 (Host Layer)                                    │
│  ├─ packages/tui      - 终端UI (交互模式)                        │
│  └─ packages/web-ui   - Web组件 (浏览器嵌入)                     │
├─────────────────────────────────────────────────────────────────┤
│  Layer 4: 应用层 (Application Layer)                             │
│  └─ packages/coding-agent                                        │
│     ├─ AgentSession   - 会话控制中枢                             │
│     ├─ ExtensionRunner- 扩展运行时                               │
│     ├─ SessionManager - 会话持久化                               │
│     └─ ModelRegistry  - 模型管理                                 │
├─────────────────────────────────────────────────────────────────┤
│  Layer 3: Agent核心 (Agent Core)                                 │
│  └─ packages/agent                                               │
│     ├─ Agent          - 状态机与事件分发                         │
│     ├─ AgentLoop      - LLM调用与工具循环                        │
│     └─ AgentTool      - 工具抽象接口                             │
├─────────────────────────────────────────────────────────────────┤
│  Layer 2: AI抽象层 (AI Abstraction)                              │
│  └─ packages/ai                                                  │
│     ├─ stream.ts      - 统一流式接口                             │
│     ├─ api-registry.ts- Provider注册中心                         │
│     └─ providers/     - 各Provider实现                           │
├─────────────────────────────────────────────────────────────────┤
│  Layer 1: 基础设施 (Infrastructure)                              │
│  └─ Node.js / TypeScript / 文件系统 / 网络层                      │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 关键设计原则

**单向依赖原则**
- 上层可以依赖下层，下层不可反向依赖
- `web-ui` → `coding-agent` → `agent` → `ai`
- 通过事件系统解耦层间通信

**事件驱动架构**
- 所有状态变更通过事件传播
- UI层只订阅事件，不直接调用核心逻辑
- 支持多消费者（一个事件可被多个扩展处理）

**可测试性设计**
- 每层都有清晰的接口边界
- 依赖注入支持Mock替换
- `AgentSession` 可在无UI环境下运行

---

## 2. 数据流与事件系统

### 2.1 完整数据流图谱

```
用户输入
    │
    ▼
┌─────────────────┐
│  Input Layer    │  ← TUI / Web UI / RPC / SDK
│  (模式适配层)    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  AgentSession   │────→│  ExtensionRunner │ ← 扩展事件拦截
│  .prompt()      │     │  (before/after)  │
└────────┬────────┘     └─────────────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  Agent          │────→│  SessionManager  │ ← 持久化到JSONL
│  .prompt()      │     │  (appendEntry)   │
└────────┬────────┘     └─────────────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  AgentLoop      │────→│  工具执行        │
│  runAgentLoop() │     │  (并发/串行)     │
└────────┬────────┘     └─────────────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  streamSimple() │────→│  Provider        │
│  (ai层)         │     │  (OpenAI/Anthropic等)
└─────────────────┘     └─────────────────┘
```

### 2.2 事件类型体系

```typescript
// 核心事件层级
AgentEvent                    // packages/agent
├── agent_start/agent_end     // 会话生命周期
├── turn_start/turn_end       // 单次LLM调用
├── message_start/update/end  // 消息流
└── tool_execution_*          // 工具执行

AgentSessionEvent             // packages/coding-agent (扩展)
├── AgentEvent (继承)
├── auto_compaction_*         // 自动压缩
└── auto_retry_*              // 自动重试

ExtensionEvent                // 扩展系统事件
├── session_*                 // 会话操作
├── context                   // 上下文注入
├── before_provider_request   // 请求拦截
├── tool_call/tool_result     // 工具拦截
└── input                     // 输入拦截
```

### 2.3 事件处理时序

```
时间轴 ──────────────────────────────────────────────►

用户输入
    │
    ▼
┌─────────────┐
│ input事件   │ ← 扩展可拦截/修改输入
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ agent_start │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ turn_start  │
└──────┬──────┘
       │
       ▼
┌─────────────┐     ┌─────────────┐
│ message_*   │────→│ 流式输出    │
└──────┬──────┘     └─────────────┘
       │
       ▼
┌─────────────┐     ┌─────────────┐
│ tool_call   │────→│ 扩展可block │
└──────┬──────┘     └─────────────┘
       │
       ▼
┌─────────────┐
│ tool执行    │ ← 并发或串行
└──────┬──────┘
       │
       ▼
┌─────────────┐     ┌─────────────┐
│ tool_result │────→│ 扩展可覆盖  │
└──────┬──────┘     │ 结果内容    │
       │            └─────────────┘
       ▼
┌─────────────┐
│ turn_end    │ ←  steering消息在此插入
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ agent_end   │ ←  followUp消息触发新一轮
└─────────────┘
```

---

## 3. 扩展系统深度解析

### 3.1 ExtensionRuntime 架构

```typescript
// 扩展运行时核心结构
interface ExtensionRuntime {
  // 工具注册表
  tools: Map<string, RegisteredTool>;
  
  // 命令注册表
  commands: Map<string, RegisteredCommand>;
  
  // 事件处理器
  handlers: Map<EventType, Handler[]>;
  
  // UI上下文（交互模式可用）
  uiContext?: ExtensionUIContext;
  
  // 共享事件总线
  events: EventBus;
}
```

### 3.2 扩展加载生命周期

```
1. 发现阶段 (Discovery)
   └─ DefaultResourceLoader 扫描路径
      ├─ ~/.pi/extensions/          (全局)
      ├─ <cwd>/.pi/extensions/      (项目级)
      ├─ --extension 参数路径        (命令行)
      └─ package.json piConfig       (包配置)

2. 加载阶段 (Loading)
   └─ extensions/loader.ts
      └─ jiti 动态加载 TypeScript
         ├─ 支持 ESM/CJS
         ├─ 支持热重载
         └─ 错误隔离（单扩展失败不影响其他）

3. 初始化阶段 (Initialization)
   └─ ExtensionRunner.loadExtensions()
      ├─ 调用 extensionFactory(pi)
      ├─ 收集注册信息
      └─ 绑定到 runtime

4. 绑定阶段 (Binding)
   └─ ExtensionRunner.bindCore()
      ├─ 注入 actions (sendMessage, setModel等)
      ├─ 注入 contextActions (isIdle, abort等)
      └─ 刷新 provider 注册

5. 运行阶段 (Runtime)
   └─ 事件触发时调用 handlers
```

### 3.3 扩展API能力矩阵

| API | 用途 | 触发时机 | 返回值影响 |
|-----|------|----------|-----------|
| `pi.registerTool()` | 注册LLM可调工具 | 初始化时 | - |
| `pi.registerCommand()` | 注册斜杠命令 | 初始化时 | - |
| `pi.registerShortcut()` | 注册快捷键 | 初始化时 | - |
| `pi.on('tool_call')` | 拦截工具调用 | 每次调用 | 可block |
| `pi.on('tool_result')` | 修改工具结果 | 每次调用 | 可覆盖结果 |
| `pi.on('before_provider_request')` | 修改请求payload | 每次LLM调用 | 可修改payload |
| `pi.on('context')` | 注入上下文 | 每次prompt | 可添加消息 |
| `pi.on('session_before_*')` | 拦截会话操作 | 操作前 | 可cancel |
| `pi.events.emit()` | 跨扩展通信 | 任意 | - |

### 3.4 扩展间通信机制

```typescript
// 方式1: 通过 EventBus (推荐)
// 扩展A
pi.events.emit('my-extension:data', { foo: 'bar' });

// 扩展B
pi.events.on('my-extension:data', (data) => {
  console.log(data.foo); // 'bar'
});

// 方式2: 通过自定义Entry (持久化)
pi.appendEntry('my-state', { key: 'value' });
// 在其他扩展或后续会话中读取

// 方式3: 通过文件系统 (大数据)
// 扩展约定好文件路径格式
```

---

## 4. 工具系统与执行模型

### 4.1 工具定义结构

```typescript
// 工具定义 (TypeBox Schema)
interface ToolDefinition<TParams extends TSchema> {
  name: string;
  description: string;
  parameters: TParams;
  
  // 执行函数
  execute: (
    toolCallId: string,
    args: Static<TParams>,
    signal: AbortSignal | undefined,
    onUpdate?: (update: { content: (TextContent | ImageContent)[]; details?: unknown }) => void,
    context: ToolContext,
  ) => Promise<ToolResult>;
}

// 执行上下文
interface ToolContext {
  cwd: string;                    // 当前工作目录
  model?: Model<any>;            // 当前模型
  settings: SettingsManager;     // 设置
  // ... 其他上下文
}

// 执行结果
interface ToolResult {
  content: (TextContent | ImageContent)[];
  details?: unknown;             // 结构化详情
  isError?: boolean;
}
```

### 4.2 工具执行并发模型

```
┌─────────────────────────────────────────┐
│           Tool Execution Mode           │
├─────────────────────────────────────────┤
│  "parallel" (默认)                      │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐   │
│  │ Tool A  │ │ Tool B  │ │ Tool C  │   │
│  │ (async) │ │ (async) │ │ (async) │   │
│  └────┬────┘ └────┬────┘ └────┬────┘   │
│       └───────────┴───────────┘         │
│                   │                     │
│                   ▼                     │
│            Promise.all()                │
│                   │                     │
│                   ▼                     │
│            统一返回结果                  │
├─────────────────────────────────────────┤
│  "sequential"                           │
│  ┌─────────┐    ┌─────────┐    ┌─────┐ │
│  │ Tool A  │───→│ Tool B  │───→│ ... │ │
│  └─────────┘    └─────────┘    └─────┘ │
│  按定义顺序串行执行                       │
└─────────────────────────────────────────┘
```

### 4.3 工具与扩展的协作

```typescript
// 扩展注册工具示例
export default function myExtension(pi) {
  // 注册一个自定义工具
  pi.registerTool({
    name: 'deploy',
    description: 'Deploy the current project',
    parameters: Type.Object({
      environment: Type.String({ enum: ['dev', 'prod'] }),
      version: Type.Optional(Type.String()),
    }),
    
    async execute(toolCallId, args, signal, onUpdate, ctx) {
      // 流式更新
      onUpdate?.({ content: [{ type: 'text', text: 'Building Docker image...' }] });

      // 执行部署逻辑
      const result = await deploy(args.environment, args.version);

      return {
        content: [{ type: 'text', text: `Deployed to ${args.environment}` }],
        details: result,
      };
    },
  });
  
  // 拦截工具调用进行审计
  pi.on('tool_call', async (event) => {
    if (event.toolName === 'deploy' && event.input.environment === 'prod') {
      // 生产部署需要确认
      const confirmed = await pi.ui.confirm(
        'Deploy to Production?',
        'This will affect live users.'
      );
      if (!confirmed) {
        return { block: true, reason: 'User cancelled' };
      }
    }
  });
}
```

---

## 5. 会话管理与持久化

### 5.1 会话树数据结构

```typescript
// 会话文件结构 (JSONL)
// 第1行: SessionHeader
{
  "type": "session",
  "id": "uuid",
  "timestamp": "2025-01-15T10:00:00Z",
  "cwd": "/project/path",
  "parentSession": "parent-uuid"  // fork时设置
}

// 后续行: SessionEntry (树节点)
interface SessionEntry {
  id: string;           // 唯一标识
  parentId?: string;    // 父节点 (null为根)
  type: EntryType;
  timestamp: string;
}

type EntryType =
  | 'message'           // 用户/助手消息
  | 'thinking_level_change'
  | 'model_change'
  | 'compaction'        // 压缩点
  | 'branch_summary'    // 分支摘要
  | 'custom'            // 扩展自定义数据
  | 'label';            // 书签标记
```

### 5.2 树导航与分支

```
会话树可视化:

Entry 1 (root)
    │
    ├── Entry 2 ── Entry 3 ── Entry 4 (leaf A)
    │
    ├── Entry 5 ── Entry 6 (leaf B)
    │
    └── Entry 7 ── Entry 8 ── Entry 9 (leaf C, current)

操作:
- navigate(Entry 6): 切换到leaf B路径，不删除历史
- fork(Entry 3): 从Entry 3创建新会话文件
- compact: 在指定位置插入compaction entry，前面消息转为摘要
```

### 5.3 Compaction机制详解

```typescript
// CompactionEntry 结构
interface CompactionEntry {
  type: 'compaction';
  id: string;
  parentId: string;
  
  // 压缩摘要
  summary: string;
  
  // 保留的最早entry
  firstKeptEntryId: string;
  
  // 压缩前token数
  tokensBefore: number;
  
  timestamp: string;
}

// 重建上下文时的处理
function buildSessionContext(leaf: SessionEntry): Context {
  const path = getPathToRoot(leaf);  // 从leaf到root的路径
  
  // 找到compaction点
  const compactionIdx = path.findIndex(e => e.type === 'compaction');
  
  if (compactionIdx >= 0) {
    // 1. 先添加compaction摘要作为system消息
    messages.push(createSummaryMessage(compaction.summary));
    
    // 2. 添加firstKeptEntryId之后的保留消息
    const keptEntries = path.slice(compactionIdx + 1);
    messages.push(...keptEntries.map(toMessage));
  } else {
    // 无压缩，添加全部消息
    messages.push(...path.map(toMessage));
  }
  
  return messages;
}
```

### 5.4 自动压缩触发条件

```typescript
// 压缩策略
interface CompactionStrategy {
  // 阈值触发: 当使用率达到阈值时主动压缩
  thresholdPercent: number;  // 默认 80%
  
  // 溢出恢复: 当API返回context overflow错误时
  overflowRecovery: boolean;  // 默认 true
  
  // 保留最近N条消息不压缩
  keepRecentMessages: number;  // 默认 6
}

// 触发流程
1. 每次turn_end检查token使用量
2. 如果 usage > thresholdPercent * contextWindow:
   - 触发 auto_compaction_start
   - 调用LLM生成摘要
   - 插入compaction entry
   - 触发 auto_compaction_end
3. 如果API返回context overflow:
   - 立即压缩 (更激进的策略)
   - 自动重试当前请求
```

---

## 6. 模型系统与Provider架构

### 6.1 模型定义与能力声明

```typescript
interface Model<TApi extends Api> {
  id: string;                    // 模型ID
  name: string;                  // 显示名称
  provider: string;              // 提供商
  api: TApi;                     // API类型
  
  // 能力声明
  reasoning: boolean;            // 支持思考模式
  input: ('text' | 'image')[];   // 输入类型
  contextWindow: number;         // 上下文窗口
  maxTokens: number;             // 最大输出token
  
  // 成本 (每百万token)
  cost: {
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
  };
  
  // OpenAI兼容性设置
  compat?: OpenAICompletionsCompat | OpenAIResponsesCompat;
  
  // 连接配置
  baseUrl?: string;
  headers?: Record<string, string>;
}
```

### 6.2 Provider注册与路由

```typescript
// packages/ai/src/api-registry.ts

// Provider注册
export function registerApiProvider<TApi extends Api>(
  provider: ApiProvider<TApi>
): void;

// 调用时路由
export function streamSimple<TApi extends Api>(
  model: Model<TApi>,
  context: Context,
  options?: SimpleStreamOptions
): AssistantMessageEventStream {
  const provider = getApiProvider(model.api);
  return provider.streamSimple(model, context, options);
}

// Provider实现示例
interface ApiProvider<TApi extends Api> {
  api: TApi;
  stream: StreamFunction<TApi, StreamOptions>;
  streamSimple: StreamFunction<TApi, SimpleStreamOptions>;
}
```

### 6.3 自定义Provider接入

```typescript
// 方式1: 通过models.json (静态配置)
// ~/.pi/agent/models.json
{
  "providers": {
    "my-proxy": {
      "baseUrl": "https://proxy.example.com/v1",
      "apiKey": "MY_API_KEY",  // 或环境变量名
      "api": "openai-completions",
      "models": [
        {
          "id": "gpt-4-custom",
          "name": "GPT-4 (Custom)",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 128000,
          "maxTokens": 4096,
          "cost": { "input": 30, "output": 60, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}

// 方式2: 通过扩展动态注册 (代码)
pi.registerProvider('my-proxy', {
  baseUrl: 'https://proxy.example.com',
  api: 'anthropic-messages',
  apiKey: 'MY_API_KEY',
  headers: { 'X-Custom-Header': 'value' },
  models: [...],
});

// 方式3: 完全自定义stream (高级)
pi.registerProvider('custom', {
  api: 'custom-api',
  streamSimple: async (model, context, options) => {
    // 完全自定义实现
    const stream = new AssistantMessageEventStream();
    
    // 调用自定义API
    const response = await myCustomApiCall(model, context);
    
    // 转换为标准事件
    stream.push({ type: 'text_delta', delta: response.text, partial: {...} });
    stream.push({ type: 'done', message: finalMessage });
    
    return stream;
  },
});
```

### 6.4 模型选择与切换

```typescript
// 模型切换流程
class AgentSession {
  async setModel(model: Model<any>): Promise<boolean> {
    // 1. 检查API key可用性
    const apiKey = await this._modelRegistry.getApiKey(model);
    if (!apiKey) return false;
    
    // 2. 触发扩展事件
    const result = await this._extensionRunner?.emit('model_select', { model });
    
    // 3. 更新Agent状态
    this.agent.setModel(model);
    
    // 4. 记录到会话树
    this.sessionManager.appendModelChange(model);
    
    // 5. 触发事件
    this._emit({ type: 'model_select', model, ... });
    
    return true;
  }
  
  // 循环切换 (Ctrl+P)
  cycleModel(direction: 'forward' | 'backward'): ModelCycleResult {
    // 优先使用scopedModels (命令行--models指定)
    // 否则使用所有可用模型
    const models = this._scopedModels.length > 0 
      ? this._scopedModels 
      : this._modelRegistry.getAvailable();
    
    // 循环索引
    const currentIdx = models.findIndex(m => modelsAreEqual(m.model, current));
    const nextIdx = (currentIdx + (direction === 'forward' ? 1 : -1)) % models.length;
    
    return this.setModel(models[nextIdx].model);
  }
}
```

---

## 7. 资源加载与生命周期

### 7.1 DefaultResourceLoader 架构

```typescript
class DefaultResourceLoader implements ResourceLoader {
  // 资源类型
  private extensionsResult: LoadExtensionsResult;
  private skills: Skill[];
  private prompts: PromptTemplate[];
  private themes: Theme[];
  private agentsFiles: Array<{ path: string; content: string }>;
  
  // 加载顺序 (优先级从高到低)
  async reload(): Promise<void> {
    // 1. 扩展 (extensions/)
    this.extensionsResult = await loadExtensions([
      ...this.additionalExtensionPaths,
      `${cwd}/.pi/extensions/`,
      `${agentDir}/extensions/`,
    ]);
    
    // 2. 技能 (skills/)
    this.skills = await loadSkills([
      ...this.additionalSkillPaths,
      `${cwd}/.pi/skills/`,
      `${agentDir}/skills/`,
    ]);
    
    // 3. 提示模板 (prompts/)
    this.prompts = await loadPromptTemplates([
      ...this.additionalPromptPaths,
      `${cwd}/.pi/prompts/`,
      `${agentDir}/prompts/`,
    ]);
    
    // 4. 主题 (themes/)
    this.themes = await loadThemes([
      ...this.additionalThemePaths,
      `${cwd}/.pi/themes/`,
      `${agentDir}/themes/`,
    ]);
    
    // 5. AGENTS.md 上下文文件
    this.agentsFiles = loadProjectContextFiles(cwd);
  }
}
```

### 7.2 Skill系统

```typescript
// Skill定义
interface Skill {
  name: string;
  description: string;
  content: string;      // 提示内容
  filePath: string;     // 源文件路径
}

// 使用方式
// 1. 在消息中使用 <skill> 标签
const message = `<skill name="code-review" location="file.ts">
请审查这段代码的质量
</skill>

function example() { ... }`;

// 2. 解析并展开
function parseSkillBlock(text: string): ParsedSkillBlock | null {
  const match = text.match(
    /^<skill name="([^"]+)" location="([^"]+)">\n([\s\S]*?)\n<\/skill>(?:\n\n([\s\S]+))?$/
  );
  return match ? {
    name: match[1],
    location: match[2],
    content: match[3],
    userMessage: match[4]?.trim(),
  } : null;
}

// 3. 展开为系统提示的一部分
function expandSkill(skill: Skill, location: string, userContent: string): string {
  return skill.content
    .replace(/\{\{LOCATION\}\}/g, location)
    .replace(/\{\{CONTENT\}\}/g, userContent);
}
```

### 7.3 Prompt Template系统

```typescript
// 提示模板定义
interface PromptTemplate {
  name: string;
  description: string;
  template: string;
  filePath: string;
}

// 使用方式
// 用户输入: /refactor
// 展开为模板内容
function expandPromptTemplate(
  template: PromptTemplate,
  userArgs: string,
  context: { cwd: string; files: string[] }
): string {
  return template.template
    .replace(/\{\{args\}\}/g, userArgs)
    .replace(/\{\{cwd\}\}/g, context.cwd);
}
```

---

## 8. 核心设计理念与哲学

### 8.1 "Agent构建Agent"的架构哲学

pi 的设计哲学源自一个核心观察：**LLM擅长编写和运行代码，应该拥抱这一点**。

这与传统软件扩展模型有本质区别：

| 传统方式 | pi的方式 |
|---------|---------|
| 下载社区扩展/MCP | 让Agent自己编写扩展 |
| 复杂的工具协议 | 简单的Bash+代码执行 |
| 预定义功能集 | 按需生成功能，用完即弃 |
| 静态配置 | 动态自修改 |

**关键架构决策**：

1. **最小核心，最大扩展性**
   - 核心只有4个工具：Read、Write、Edit、Bash
   - 系统提示极短，不占用上下文
   - 所有高级功能通过扩展/技能实现

2. **自举能力（Self-hosting）**
   - pi可以用自己扩展自己
   - 扩展可以热重载，Agent可以写代码→测试→迭代
   - 会话树结构支持"支线任务"模式：修复工具→切回主线

3. **渐进式披露（Progressive Disclosure）**
   - Skills只有描述常驻上下文，完整内容按需加载
   - 避免一次性加载大量工具描述污染上下文

### 8.2 为什么不是MCP

pi**故意**不支持MCP作为核心机制（虽然可以通过扩展添加）：

| MCP的问题 | pi的解决方案 |
|----------|-------------|
| 工具需在会话开始时加载 | 扩展可热重载，工具可动态注册 |
| 工具描述占用大量上下文 | Skills渐进式披露，扩展按需加载 |
| 难以修改已有工具行为 | 直接让Agent修改扩展源码 |
| 协议复杂 | Bash+代码，简单直接 |

**推荐替代方案**：
- 使用 `mcporter` 将MCP工具暴露为CLI接口
- 或用Skill封装常用功能（如浏览器自动化用CDP而非Playwright MCP）

### 8.3 开发模式选择

| 场景 | 推荐方式 | 入口文件 | 说明 |
|------|---------|---------|------|
| 添加自定义工具 | Extension | `extensions/my-tools/index.ts` | 适合需要UI交互或复杂逻辑 |
| 快速功能封装 | Skill | `.pi/skills/my-skill.md` | 适合纯提示工程+脚本 |
| 修改系统提示 | AGENTS.md | 项目根目录或 `~/.pi/agent/` | 项目特定上下文 |
| 自定义主题 | Theme文件 | `.pi/themes/my-theme.ts` | TUI外观定制 |
| 嵌入现有应用 | SDK | `createAgentSession()` | Node.js程序集成 |
| 跨进程集成 | RPC模式 | `pi --mode rpc` | 跨语言/跨机器 |
| Web界面 | Web UI组件 | `@mariozechner/pi-web-ui` | 浏览器嵌入 |

### 8.4 Skill vs Extension 选择指南

**使用Skill当**：
- 功能主要是提示工程（"如何审查代码"）
- 需要配合简单的辅助脚本
- 希望渐进式加载，不常驻上下文
- 功能相对独立，不需要复杂UI

**使用Extension当**：
- 需要自定义TUI组件（spinner、表格、文件选择器）
- 需要拦截事件（工具调用、请求修改）
- 需要注册快捷键或斜杠命令
- 需要持久化状态到会话

**典型Skill示例**：
```markdown
---
name: browser-automation
description: Use Chrome DevTools Protocol for browser automation. 
  Use when you need to scrape web pages, test web apps, or take screenshots.
---

# Browser Automation

## Prerequisites
Chrome must be running with remote debugging:
```bash
./start-chrome.sh
```

## Navigate
```bash
./navigate.js https://example.com
```

## Execute JavaScript
```bash
./eval.js 'document.title'
```

## Screenshot
```bash
./screenshot.js > screenshot.png
```
```

**典型Extension示例**：
- `/todos` - 带TUI的待办管理
- `/review` - 代码审查界面（类似Codex的commit review）
- `/files` - 文件列表与快速预览

### 8.2 完整Extension示例

```typescript
// extensions/my-extension/index.ts
import type { ExtensionAPI, ExtensionContext } from '@mariozechner/pi-coding-agent';
import { Type } from '@sinclair/typebox';

export default function myExtension(pi: ExtensionAPI) {
  // ========== 1. 注册工具 ==========
  pi.registerTool({
    name: 'my-api-call',
    description: 'Call my internal API',
    parameters: Type.Object({
      endpoint: Type.String(),
      method: Type.String({ enum: ['GET', 'POST'] }),
      body: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
    }),
    async execute(toolCallId, args, signal, onUpdate, ctx) {
      onUpdate?.({ content: [{ type: 'text', text: 'Calling API...' }] });

      const result = await fetch(`${process.env.MY_API_URL}${args.endpoint}`, {
        method: args.method,
        headers: { 'Authorization': `Bearer ${process.env.MY_API_KEY}` },
        body: args.body ? JSON.stringify(args.body) : undefined,
      });

      const data = await result.json();

      return {
        content: [{ type: 'text', text: JSON.stringify(data, null, 2) }],
        details: { status: result.status, headers: Object.fromEntries(result.headers) },
      };
    },
  });
  
  // ========== 2. 注册命令 ==========
  pi.registerCommand('deploy', {
    description: 'Deploy current project',
    async execute(ctx) {
      await ctx.waitForIdle();
      
      const env = await ctx.ui.select('Select environment', ['dev', 'staging', 'prod']);
      if (!env) return;
      
      if (env === 'prod') {
        const confirmed = await ctx.ui.confirm(
          'Deploy to Production?',
          'This will affect live users.'
        );
        if (!confirmed) return;
      }
      
      // 发送用户消息触发agent
      ctx.sendUserMessage(`Deploy to ${env}`);
    },
  });
  
  // ========== 3. 注册快捷键 ==========
  pi.registerShortcut('ctrl+d', {
    description: 'Quick deploy',
    async handler(ctx) {
      ctx.sendUserMessage('Deploy to dev');
    },
  });
  
  // ========== 4. 事件监听 ==========
  // 拦截工具调用
  pi.on('tool_call', async (event) => {
    if (event.toolName === 'write' && event.input.path?.includes('production')) {
      // 审计日志
      console.log(`[AUDIT] File write to production path: ${event.input.path}`);
    }
  });
  
  // 修改工具结果
  pi.on('tool_result', async (event) => {
    if (event.toolName === 'my-api-call' && event.isError) {
      // 增强错误信息
      return {
        content: [
          { type: 'text', text: 'API call failed. Retrying with fallback...' },
          ...event.content,
        ],
      };
    }
  });
  
  // 请求拦截
  pi.on('before_provider_request', async (event) => {
    // 添加自定义header
    event.payload.headers['X-Request-ID'] = generateRequestId();
    return { payload: event.payload };
  });
  
  // 上下文注入
  pi.on('context', async (event) => {
    // 添加项目特定的上下文
    const projectInfo = await loadProjectInfo(ctx.cwd);
    return {
      messages: [
        {
          role: 'system',
          content: `Project: ${projectInfo.name}\nTech stack: ${projectInfo.stack.join(', ')}`,
        },
      ],
    };
  });
  
  // ========== 5. 自定义Provider ==========
  pi.registerProvider('my-company', {
    baseUrl: 'https://ai.mycompany.com',
    api: 'openai-completions',
    apiKey: 'COMPANY_API_KEY',  // 环境变量名
    models: [
      {
        id: 'company-llm',
        name: 'Company LLM',
        reasoning: false,
        input: ['text'],
        contextWindow: 32000,
        maxTokens: 4096,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
  });
}
```

### 8.3 SDK嵌入示例

```typescript
// 嵌入到现有Node应用
import { createAgentSession } from '@mariozechner/pi-coding-agent';
import { getModel } from '@mariozechner/pi-ai';

async function main() {
  const { session } = await createAgentSession({
    cwd: '/my/project',
    model: getModel('anthropic', 'claude-sonnet-4'),
    thinkingLevel: 'medium',
  });
  
  // 订阅所有事件
  session.subscribe((event) => {
    switch (event.type) {
      case 'message_update':
        // 流式输出
        if (event.assistantMessageEvent.type === 'text_delta') {
          process.stdout.write(event.assistantMessageEvent.delta);
        }
        break;
        
      case 'tool_execution_start':
        console.log(`\n[Tool] ${event.toolName} starting...`);
        break;
        
      case 'tool_execution_end':
        console.log(`[Tool] ${event.toolName} completed`);
        break;
        
      case 'agent_end':
        console.log('\n[Done]');
        break;
    }
  });
  
  // 发送消息
  await session.prompt('Refactor the auth module to use JWT');
  
  // 等待完成
  await session.waitForIdle();
  
  // 获取会话统计
  const stats = session.getStats();
  console.log(`Tokens: ${stats.tokens.total}, Cost: $${stats.cost.toFixed(4)}`);
}
```

### 8.4 RPC模式集成

```typescript
// 启动RPC服务器
import { spawn } from 'child_process';

const rpcProcess = spawn('pi', ['--mode', 'rpc', '--cwd', '/project'], {
  stdio: ['pipe', 'pipe', 'pipe'],
});

// 发送命令
function sendCommand(command: object) {
  rpcProcess.stdin.write(JSON.stringify(command) + '\n');
}

// 读取响应
const rl = createInterface(rpcProcess.stdout);
rl.on('line', (line) => {
  const event = JSON.parse(line);
  
  switch (event.type) {
    case 'response':
      console.log('Command response:', event);
      break;
      
    case 'message_update':
      // 处理流式输出
      break;
      
    case 'agent_end':
      console.log('Agent finished');
      break;
  }
});

// 使用示例
sendCommand({
  type: 'prompt',
  id: '1',
  content: 'Explain this code',
  streamingBehavior: 'steer',
});
```

### 8.5 实际扩展示例参考

Armin Ronacher分享的扩展实践（可作为开发参考）：

| 扩展 | 功能 | 技术点 |
|------|------|--------|
| `/answer` | 提取Agent回复中的问题，重新格式化为输入框 | TUI组件、消息解析 |
| `/todos` | 待办列表管理，存储在`.pi/todos/` | 文件持久化、TUI列表 |
| `/review` | 代码审查界面（类似Codex） | 会话树分支、diff展示 |
| `/control` | 一个Agent向另一个Agent发送prompt | 多Agent实验 |
| `/files` | 会话中修改/引用的文件列表 | 会话分析、文件操作 |

Nico的贡献：
- `subagent`扩展 - 子Agent支持
- `interactive-shell` - 在TUI overlay中运行交互式CLI

### 8.6 调试与开发技巧

```typescript
// 1. 扩展热重载
// 修改扩展后执行 /reload 命令

// 2. 事件日志（按事件类型逐个监听）
pi.on('agent_start', () => {
  console.log('[Extension Event] agent_start');
});

pi.on('session_before_switch', (event) => {
  console.log('[Extension Event] session_before_switch', event);
});

// 3. 工具测试模式
pi.registerTool({
  name: 'test-tool',
  // ...
  async execute(toolCallId, args, signal, onUpdate, ctx) {
    // 模拟延迟
    await new Promise(r => setTimeout(r, 1000));
    
    // 返回测试数据
    return {
      content: [{ type: 'text', text: 'Test result' }],
      details: { args, cwd: ctx.cwd },
    };
  },
});

// 4. 条件断点
pi.on('tool_call', async (event) => {
  if (event.toolName === 'write' && event.input.path === 'debug.txt') {
    debugger;  // 在此处断点
  }
});

// 5. 让Agent帮你写扩展
// 告诉Agent："创建一个扩展，添加一个/xxx命令，功能是..."
// Agent会：
// - 在extensions/目录创建文件
// - 使用/reload加载
// - 测试并迭代修复
```

### 8.7 延伸阅读：Agent友好的代码设计

Armin Ronacher在[A Language For Agents](https://lucumr.pocoo.org/2026/2/9/a-language-for-agents/)中探讨了什么样的编程语言特性对Agent友好。虽然这是关于语言设计的讨论，但其中的观点对编写Agent友好的扩展和Skill同样有启发：

**本地推理优先**
- 代码应该易于局部理解，不依赖过多上下文
- pi的4个基础工具（Read/Write/Edit/Bash）就是最小化的本地操作
- 扩展应该保持功能单一，避免复杂的跨文件依赖

**可发现性（Greppable）**
- 符号应该易于grep，避免复杂的重导出（barrel files）和别名
- Skill/Extension的目录结构应该扁平、直观
- 使用明确的命名，而非缩写或隐喻

**显式优于隐式**
- 类型、副作用应该明确可见
- 避免隐式的全局状态或依赖注入
- 工具参数使用显式的Schema定义（TypeBox）

**简单确定的工具链**
- 构建、测试、lint应该统一且确定
- 避免"有时能运行"的状态（如TypeScript类型错误但可运行）
- pi的Bash工具让Agent可以直接调用简单命令，无需复杂配置

**对扩展开发的实际建议**：
- 保持扩展代码简单直接，避免宏和复杂抽象
- 使用明确的文件结构，避免深层嵌套
- 提供清晰的错误信息和日志，帮助Agent理解状态
- 测试应该是确定性的，避免依赖外部状态

### 8.8 健康使用Agent：避免"Agent Psychosis"

Armin Ronacher在[Agent Psychosis: Are We Going Insane?](https://lucumr.pocoo.org/2026/1/18/agent-psychosis/)中探讨了Agent编程的心理健康和社会影响。这篇文章对pi用户有重要警示意义：

**"Slop Loop"陷阱**
- 无监督的Agent循环会产生大量低质量代码（"vibeslop"）
- 多巴胺驱动的提示循环让人误以为自己很高效
- 实际上产出的代码可能难以维护或根本无法使用

**pi的设计如何帮助避免这个问题**

| 问题 | pi的解决方案 |
|------|-------------|
| 无监督的Agent循环 | 会话树结构强制人在关键决策点介入（/tree, /fork） |
| 上下文丢失 | Session持久化让Agent"记住"之前的推理 |
| 代码质量不可见 | 紧凑的TUI展示token使用、成本、工具输出 |
| 无法回滚 | 分支和导航功能允许实验后回退 |
| 缺乏现实检验 | 鼓励使用/review分支进行代码审查 |

**健康使用建议**

1. **保持人在回路中（Human-in-the-loop）**
   - 使用`/tree`定期回顾会话历史
   - 在关键决策点手动确认（如生产部署）
   - 不要让Agent无限制地循环

2. **质量优先于速度**
   - 使用`/review`分支进行代码审查
   - 让Agent解释"为什么"而不仅是"做什么"
   - 对复杂变更使用fork进行实验

3. **管理Token消耗**
   - pi显示每次交互的token和成本
   - 使用compact控制上下文长度
   - 避免无意义的重复提示

4. **对外贡献的责任**
   - 向开源项目提交PR前，确保自己理解代码
   - 考虑提交prompt而非代码，让他人可复现
   - 尊重维护者的时间，避免"一分钟生成，一小时审查"

**关键洞察**

> "AI agents are amazing and a huge productivity boost. They are also massive slop machines if you turn off your brain and let go completely."

pi的设计哲学正是为了**保持人的主导权**：
- 最小工具集迫使人明确意图
- 会话树让人掌控流程
- 成本显示让人意识到资源消耗
- 扩展系统让人按需定制，而非被动接受

---

## 9. 总结

pi的架构设计体现了以下核心理念：

1. **分层清晰**: 五层架构各司其职，通过事件系统解耦
2. **扩展优先**: 几乎所有功能都可通过扩展定制，无需修改核心
3. **事件驱动**: 统一的事件系统支持多消费者和拦截模式
4. **可测试性**: 每层都有清晰的接口，支持独立测试
5. **多模式支持**: 同一核心支持TUI、Web、RPC、SDK多种使用方式
6. **自举能力**: Agent可以编写、测试、迭代自己的扩展
7. **最小核心**: 4个基础工具 + 短系统提示，其余通过扩展实现

### 二次开发的关键入口

- **扩展开发**: `packages/coding-agent/src/core/extensions/types.ts`
- **SDK使用**: `packages/coding-agent/src/core/sdk.ts`
- **模型定制**: `packages/coding-agent/src/core/model-registry.ts`
- **工具开发**: `packages/coding-agent/src/core/tools/index.ts`
- **Skill开发**: `packages/coding-agent/docs/skills.md`

### 推荐阅读顺序

1. 理解哲学：`architecture-overview.md` → 本文第8.1-8.2节
2. 学习扩展：`extensions-and-sdks.md` → 本文第3节
3. 深入架构：`deep-dive-architecture.md`（本文）
4. 实战参考：Armin的文章 + 本文第8.5节扩展示例

### 8.9 实战案例：Advent of Code 完全自动化

Armin Ronacher在[Advent of Slop: A Guest Post by Claude](https://lucumr.pocoo.org/2025/12/23/advent-of-slop/)中记录了一个完整的Agent自动化案例：让Claude Code独立完成Advent of Code 2025的全部12天题目。

**工作流设置**
- 使用`web-browser` skill让Agent访问adventofcode.com
- Agent自主阅读题目、获取输入、编写解法、提交答案
- 人类只在每天开始时"激活"Agent，其余完全自主

**优化阶段（关键洞察）**
完成解题后，Armin要求Agent将所有解法优化到总运行时间<1秒：

| 题目 | 初始方案 | 优化后 | 技术点 |
|------|---------|--------|--------|
| Day 09 | O(n³) 矩形检查 | O(log²n) Fenwick树 + 二分搜索 | 数据结构优化 |
| Day 10 | O(2ⁿ) 暴力枚举 | O(n³) 高斯消元（GF(2)） | 线性代数 |
| Day 08 | 重复计算距离 | 位打包 + LRU缓存 + 并查集优化 | 缓存与位运算 |
| Day 12 | 回溯搜索（NP完全） | O(1) 面积检查（利用题目特性） | 问题分析 |

**对pi用户的启示**

1. **Skill的威力**：web-browser skill让Agent能自主获取信息，无需人工复制粘贴
2. **迭代优化模式**：先求正确，再求效率——pi的会话树完美支持这种工作流
3. **人在回路的价值**：Armin每天"激活"Agent，保持监督；优化阶段的人类指导是关键
4. **工具即能力**：Agent的能力边界由其工具决定，pi的扩展系统让这种边界可扩展

**与pi的对应**

```
Claude Code + web-browser skill  ≈  pi + browser-tools skill
Daily activation                 ≈  pi的会话树导航
Optimization phase               ≈  /tree分支 + /review
Input generators                 ≈  pi让Agent自己写工具脚本
```

这个案例展示了Agent编程的理想工作流：人类设定目标和约束，Agent自主执行，关键决策点人类介入，最终结果可验证、可复现。


### 8.10 最终瓶颈：审查与责任

Armin Ronacher在[The Final Bottleneck](https://lucumr.pocoo.org/2026/2/13/the-final-bottleneck/)中提出了一个核心问题：当代码编写速度远超审查速度时，会发生什么？

**历史瓶颈转移**
```
纺织业：织布 → 纺纱 → 纤维 → 棉花采摘
软件业：汇编 → 高级语言 → 框架 → AI生成代码
```

每次瓶颈移除，创新发生在下游。现在AI移除了"编写代码"的瓶颈，审查成为新的瓶颈。

**OpenClaw的现状**
- 2,500+ 开放PR
- 输入速度远超处理能力
- 累积失败（accumulating failure）

**pi的应对策略**

| 策略 | pi的实现 | 说明 |
|------|---------|------|
| 节流（Throttling） | OSS Weekend、PR自动关闭 | 限制输入速度 |
| 信任机制 | 只有受信任贡献者的PR才被接受 | 质量预筛选 |
| 人在回路 | 会话树、分支、审查 | 强制人类介入关键点 |

**核心洞察**

> "I too am the bottleneck now. But you know what? Two years ago, I too was the bottleneck. I was the bottleneck all along."

机器没有改变一个根本事实：**人类承担责任**。只要人类是责任的最终承担者，人类就是瓶颈。

**对pi设计的启示**

1. **不要追求无限制的速度**
   - pi不鼓励"让Agent无限循环"
   - 每次交互都有成本显示（token/金钱）
   - 会话树强制人在决策点介入

2. **质量先于数量**
   - `/review`分支进行代码审查
   - `/tree`导航让历史可回溯、可理解
   - 扩展系统让工具可审计、可修改

3. **责任不可转移**
   - 机器不能承担责任
   - pi的设计让人类始终掌握最终决策权
   - 不是"AI替我做"，而是"AI帮我做，我负责"

**与工业革命的对比**

纺织业自动化后，个体织工不再对单匹布负责，责任转移到工厂整体。

软件业是否会走向"一次性塑料软件"（single-use plastic software）？Armin认为不会，因为：
- 软件不是消费品，是基础设施
- 代码需要维护，不是用完即弃
- 社会会要求有人对软件负责

pi的设计正是为了**可持续的AI辅助编程**：快，但不过度；自动化，但有人负责。

