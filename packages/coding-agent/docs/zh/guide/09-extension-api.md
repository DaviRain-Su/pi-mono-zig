# 第9章：扩展 API 详解

> 工具、命令、事件、UI

---

## 9.1 ExtensionAPI 概览

### 核心接口

```typescript
interface ExtensionAPI {
  // 工具注册
  registerTool<T>(tool: ToolDefinition<T>): void;
  
  // 命令注册
  registerCommand(name: string, options: CommandOptions): void;
  
  // 快捷键注册
  registerShortcut(key: KeyId, options: ShortcutOptions): void;
  
  // 事件监听
  on(event: EventType, handler: EventHandler): void;
  
  // Provider 注册
  registerProvider(name: string, config: ProviderConfig): void;
  unregisterProvider(name: string): void;
  
  // 消息发送
  sendMessage(message: CustomMessage): void;
  sendUserMessage(content: string): void;
  appendEntry(type: string, data: unknown): void;
  
  // UI 相关
  ui: ExtensionUIContext;
  
  // 事件总线
  events: EventBus;
}
```

---

## 9.2 工具注册 (registerTool)

### 完整定义

```typescript
interface ToolDefinition<TParams extends TSchema = TSchema, TDetails = unknown> {
  name: string;
  label: string;
  description: string;
  parameters: TParams;
  execute: (
    toolCallId: string,
    params: Static<TParams>,
    signal: AbortSignal | undefined,
    onUpdate?: (partial: ToolResult<TDetails>) => void,
    ctx: ExtensionContext,
  ) => Promise<ToolResult<TDetails>>;
}
```

### 参数详解

#### name

- 必需
- 唯一标识符
- 小写字母、数字、连字符
- 例如：`count-lines`, `deploy-app`

#### description

- 必需
- 告诉 Agent 这个工具做什么
- 何时使用这个工具
- 应该具体、明确

❌ 不好的描述：
```typescript
description: 'A tool for files'
```

✅ 好的描述：
```typescript
description: 'Count the number of lines in a text file. Use when you need to analyze file size or compare code volume between files.'
```

#### parameters

使用 TypeBox 定义参数模式：

```typescript
import { Type } from '@sinclair/typebox';

parameters: Type.Object({
  // 必需参数
  path: Type.String({ 
    description: 'Path to the file' 
  }),
  
  // 可选参数
  recursive: Type.Optional(
    Type.Boolean({ 
      default: false,
      description: 'Count lines in subdirectories' 
    })
  ),
  
  // 枚举参数
  format: Type.String({
    enum: ['simple', 'detailed'],
    default: 'simple',
    description: 'Output format'
  }),
})
```

### execute 函数

#### context 对象

`ctx` 参数是 `ExtensionContext`，包含当前工作目录、会话、模型、I/O 与 UI 能力。
常用字段示例：

```typescript
const cwd = ctx.cwd;
const model = ctx.model;
await ctx.ui.notify('开始扫描');
const result = await ctx.exec('rg', ['TODO', cwd]);
```
```

#### onUpdate 回调

用于流式更新进度：

```typescript
async execute(toolCallId, args, signal, onUpdate, ctx) {
  // 开始
  onUpdate?.({
    content: [{ type: 'text', text: '[analyze-project] Step 1/3: starting' }],
  });

  // 步骤1
  const step1 = await doStep1();
  onUpdate?.({
    content: [{ type: 'text', text: `[analyze-project] Step 1 complete: ${step1.count} items` }],
  });

  // 步骤2
  const step2 = await doStep2();
  onUpdate?.({
    content: [{ type: 'text', text: '[analyze-project] Step 2 complete' }],
  });

  // 完成
  return {
    content: [{ type: 'text', text: 'Done!' }],
    details: { step1, step2 },
  };
}
```

#### 返回值

```typescript
interface ToolResult<TDetails = unknown> {
  // 显示给用户的文本/图片
  content: (TextContent | ImageContent)[];

  // 结构化数据（可选）
  details: TDetails;
}
```

---

## 9.3 命令注册 (registerCommand)

### 基本用法

```typescript
pi.registerCommand('deploy', {
  description: 'Deploy the application',
  execute: async (ctx) => {
    // 命令逻辑
  },
});
```

### 完整选项

```typescript
interface CommandOptions {
  description: string;
  execute: (ctx: ExtensionCommandContext) => Promise<void>;
}

interface ExtensionCommandContext extends ExtensionContext {
  // 等待 Agent 空闲
  waitForIdle(): Promise<void>;
  
  // 新会话
  newSession(options?: NewSessionOptions): Promise<void>;
  
  // 分叉
  fork(entryId: string): Promise<void>;
  
  // 切换会话
  switchSession(path: string): Promise<void>;
  
  // 发送消息
  sendUserMessage(content: string): void;
  sendMessage(message: CustomMessage): void;
}
```

### 带 UI 交互的命令

```typescript
pi.registerCommand('setup', {
  description: 'Interactive setup wizard',
  execute: async (ctx) => {
    // 选择
    const env = await ctx.ui.select(
      'Select environment',
      ['dev', 'staging', 'production']
    );
    
    if (!env) return; // 用户取消
    
    // 确认
    const confirmed = await ctx.ui.confirm(
      'Confirm deployment?',
      `Deploy to ${env}`
    );
    
    if (!confirmed) return;
    
    // 输入
    const version = await ctx.ui.input(
      'Version tag',
      'v1.0.0'
    );
    
    // 执行
    ctx.sendUserMessage(`Deploy ${version} to ${env}`);
  },
});
```

---

## 9.4 事件监听 (on)

### 事件类型

#### 生命周期事件

```typescript
// Agent 开始
pi.on('agent_start', async (event) => {
  console.log('Agent started');
});

// Agent 结束
pi.on('agent_end', async (event) => {
  console.log('Agent ended');
});

// 轮次开始
pi.on('turn_start', async (event) => {
  console.log('New turn');
});

// 轮次结束
pi.on('turn_end', async (event) => {
  console.log('Turn ended');
});
```

#### 消息事件

```typescript
// 消息开始
pi.on('message_start', async (event) => {
  console.log('Message:', event.message.role);
});

// 消息更新（流式）
pi.on('message_update', async (event) => {
  console.log('Update:', event.assistantMessageEvent.type);
});

// 消息结束
pi.on('message_end', async (event) => {
  console.log('Message complete');
});
```

#### 工具事件

```typescript
// 工具调用前（可拦截）
pi.on('tool_call', async (event) => {
  console.log('Tool:', event.toolName);

  // 阻止执行
  if (event.toolName === 'dangerous') {
    return {
      block: true,
      reason: 'Too dangerous',
    };
  }

  // 仅记录
  if (event.toolName === 'write' && event.input.path === '.env') {
    // 不能返回 warn，改为记录或直接拒绝
    console.warn('Modifying environment file');
  }
});

// 工具结果（可修改）
pi.on('tool_result', async (event) => {
  // 增强结果
  if (event.toolName === 'read') {
    return {
      content: [
        ...event.content,
        { type: 'text', text: '[Extension] File loaded' },
      ],
    };
  }
});
```

#### 会话事件

```typescript
// 会话切换前
pi.on('session_before_switch', async (event) => {
  // 可以通过返回 { cancel: true } 阻止切换
  return { cancel: false };
});

// 压缩前
pi.on('session_before_compact', async (event) => {
  // 返回 { cancel: true } 即可阻止本次压缩
  if (event.branchEntries.length === 0) {
    return { cancel: true };
  }
  return;
});

// Provider 请求前
pi.on('before_provider_request', async (event) => {
  // 修改请求：返回最终 payload 即可生效
  event.payload.headers = {
    ...event.payload.headers,
    'X-Custom': 'value',
  };
  return event.payload;
});
```

### 事件处理器返回值

| 返回值 | 效果 |
|-------|------|
| `undefined` | 继续正常流程 |
| `{}`/`undefined` | 继续正常流程 |
| `{ cancel: true }` | 中断该事件流程 |
| `payload` | 替换/修改事件载荷（如 before_provider_request） |
| `SessionBeforeCompactResult` 中的字段（如 `compaction`）| 覆盖默认返回并继续 |

---

## 9.5 UI 上下文

### 对话框

```typescript
// 选择
const choice = await pi.ui.select(
  'Title',
  ['option1', 'option2', 'option3']
);

// 确认
const confirmed = await pi.ui.confirm(
  'Title',
  'Message'
);

// 输入
const text = await pi.ui.input(
  'Title',
  'placeholder'
);

// 编辑器
const code = await pi.ui.editor(
  'Edit code',
  'initial content'
);
```

### 通知

```typescript
pi.ui.notify('Operation complete', 'info');
pi.ui.notify('Something went wrong', 'error');
pi.ui.notify('Please check', 'warning');
```

### 状态显示

```typescript
// 设置状态
pi.ui.setStatus('my-extension', 'Processing...');

// 清除状态
pi.ui.setStatus('my-extension', undefined);

// 工作消息
pi.ui.setWorkingMessage('Analyzing codebase...');
pi.ui.setWorkingMessage(); // 恢复默认
```

### 自定义组件

```typescript
// 设置 widget
pi.ui.setWidget('my-widget', [
  'Line 1',
  'Line 2',
  'Line 3',
], { placement: 'aboveEditor' });

// 清除 widget
pi.ui.setWidget('my-widget', undefined);

// 自定义 footer
pi.ui.setFooter((tui, theme, data) => {
  return new CustomFooter(tui, theme, data);
});
```

---

## 9.6 Provider 注册

### 基本用法

```typescript
pi.registerProvider('my-proxy', {
  baseUrl: 'https://proxy.example.com',
  api: 'openai-completions',
  apiKey: 'PROXY_API_KEY',
  models: [
    {
      id: 'custom-model',
      name: 'Custom Model',
      reasoning: true,
      input: ['text', 'image'],
      contextWindow: 128000,
      maxTokens: 4096,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    },
  ],
});
```

### 配置选项

```typescript
interface ProviderConfig {
  // 基础 URL
  baseUrl?: string;
  
  // API 类型
  api?: Api;
  
  // API Key（环境变量名或值）
  apiKey?: string;
  
  // 自定义 headers
  headers?: Record<string, string>;
  
  // 是否添加 Authorization header
  authHeader?: boolean;
  
  // 模型列表
  models?: ProviderModelConfig[];
  
  // 自定义 stream handler（高级）
  streamSimple?: StreamFunction;
}
```

---

## 9.7 事件总线

### 跨扩展通信

```typescript
// 扩展 A：发送事件
pi.events.emit('my-event', { data: 'value' });

// 扩展 B：监听事件
pi.events.on('my-event', (data) => {
  console.log('Received:', data);
});
```

### 使用场景

- 扩展间数据共享
- 状态同步
- 协作功能

---

## 9.8 完整示例

```typescript
import type { ExtensionAPI } from '@mariozechner/pi-coding-agent';
import { Type } from '@sinclair/typebox';

export default function comprehensiveExtension(pi: ExtensionAPI) {
  // 1. 注册工具
  pi.registerTool({
    name: 'analyze-deps',
    description: 'Analyze project dependencies',
    parameters: Type.Object({
      depth: Type.Number({ default: 1 }),
    }),
    async execute(toolCallId, args, signal, onUpdate, ctx) {
      onUpdate?.({
        content: [{ type: 'text', text: 'Reading package.json...' }],
      });

      const pkg = await ctx.exec('cat', ['package.json']);
      const deps = JSON.parse(pkg.stdout).dependencies || {};

      return {
        content: [{ type: 'text', text: `Found ${Object.keys(deps).length} dependencies` }],
        details: { deps },
      };
    },
  });
  
  // 2. 注册命令
  pi.registerCommand('deps', {
    description: 'Show project dependencies',
    execute: async (ctx) => {
      ctx.sendUserMessage('Analyze project dependencies');
    },
  });
  
  // 3. 监听事件
  pi.on('tool_call', async (event) => {
    if (event.toolName === 'write' && event.input.path === 'package.json') {
      // 建议：记录并继续，或者返回 { block: true, reason } 强制阻止
    }
  });
  
  // 4. 使用 UI
  pi.ui.notify('Extension loaded', 'info');
}
```

---

## 本章小结

- **registerTool**：定义 Agent 可调用的工具
- **registerCommand**：创建斜杠命令
- **pi.on**：监听和拦截事件
- **pi.ui**：与用户交互
- **registerProvider**：添加自定义模型
- **pi.events**：跨扩展通信
