# 第11章：Cookbook

> 代码片段、复制即用

---

## 目录

- [工具开发](#工具开发)
- [命令注册](#命令注册)
- [事件监听](#事件监听)
- [UI 交互](#ui-交互)
- [文件操作](#文件操作)
- [网络请求](#网络请求)
- [常见模式](#常见模式)

---

## 工具开发

### 基础工具模板

```typescript
import { Type } from '@sinclair/typebox';

pi.registerTool({
  name: 'my-tool',
  description: 'What this tool does',
  parameters: Type.Object({
    param1: Type.String({ description: 'Parameter description' }),
    param2: Type.Optional(Type.Number({ default: 10 })),
  }),
  async execute(toolCallId, args, signal, onUpdate, ctx) {
    // 你的逻辑
    return {
      content: [{ type: 'text', text: 'Result' }],
      details: { /* structured data */ },
    };
  },
});
```

### 带进度报告的工具

```typescript
pi.registerTool({
  name: 'long-task',
  description: 'A long running task',
  parameters: Type.Object({ items: Type.Array(Type.String()) }),
  async execute(toolCallId, args, signal, onUpdate, ctx) {
    const results = [];
    for (let i = 0; i < args.items.length; i++) {
      onUpdate?.({
        content: [{ type: 'text', text: `Processing ${i + 1}/${args.items.length}: ${args.items[i]}` }],
      });

      const result = await processItem(args.items[i]);
      results.push(result);
    }

    return {
      content: [{ type: 'text', text: `Processed ${results.length} items` }],
      details: { results },
    };
  },
});
```

### 返回图片的工具

```typescript
pi.registerTool({
  name: 'screenshot',
  description: 'Take a screenshot of a webpage',
  parameters: Type.Object({ url: Type.String() }),
  async execute(toolCallId, args, signal, onUpdate, ctx) {
    const imagePath = await takeScreenshot(args.url);
    const imageData = await readFile(imagePath);

    return {
      content: [
        { type: 'text', text: `Screenshot of ${args.url}:` },
        {
          type: 'image',
          source: {
            type: 'base64',
            media_type: 'image/png',
            data: imageData.toString('base64'),
          },
        },
      ],
      details: undefined,
    };
  },
});
```

---

## 命令注册

### 基础命令

```typescript
pi.registerCommand('hello', {
  description: 'Say hello',
  async execute(ctx) {
    ctx.sendUserMessage('Hello from my extension!');
  },
});
```

### 带确认的命令

```typescript
pi.registerCommand('deploy', {
  description: 'Deploy to production',
  async execute(ctx) {
    const confirmed = await ctx.ui.confirm(
      'Deploy to Production?',
      'This will affect live users.'
    );
    
    if (confirmed) {
      ctx.sendUserMessage('Deploy to production');
    }
  },
});
```

### 带选择的命令

```typescript
pi.registerCommand('switch-env', {
  description: 'Switch environment',
  async execute(ctx) {
    const env = await ctx.ui.select(
      'Select environment',
      ['dev', 'staging', 'production']
    );
    
    if (env) {
      ctx.sendUserMessage(`Switch to ${env} environment`);
    }
  },
});
```

### 带输入的命令

```typescript
pi.registerCommand('search', {
  description: 'Search in codebase',
  async execute(ctx) {
    const query = await ctx.ui.input('Search query');
    if (query) {
      ctx.sendUserMessage(`Search for "${query}" in the codebase`);
    }
  },
});
```

---

## 事件监听

### 工具调用拦截

```typescript
// 拦截所有工具调用
pi.on('tool_call', async (event) => {
  console.log(`Tool ${event.toolName} called`);
  // 返回 undefined 继续执行
});

// 阻止特定工具
pi.on('tool_call', async (event) => {
  if (event.toolName === 'bash' && event.input.command === 'rm -rf /') {
    return { block: true, reason: 'Dangerous command' };
  }
});

// 记录告警但继续执行
pi.on('tool_call', async (event) => {
  if (event.toolName === 'write' && event.input.path?.includes('.env')) {
    console.warn('Modifying environment file');
  }
});
```

### 工具结果修改

```typescript
pi.on('tool_result', async (event) => {
  if (event.toolName === 'read' && event.input.path === 'package.json') {
    // 增强结果
    return {
      content: [
        ...event.content,
        { type: 'text', text: '\n[Extension] This is a Node.js project' },
      ],
    };
  }
});
```

### 会话事件

```typescript
// 会话开始
pi.on('session_start', async (event) => {
  console.log('Session started:', event.sessionId);
});

// 模型切换
pi.on('model_select', async (event) => {
  console.log(`Model changed: ${event.model.name}`);
});

// 压缩前拦截
pi.on('session_before_compact', async (event) => {
  const confirmed = await pi.ui.confirm(
    'Compact session?',
    'This will summarize old messages.',
  );
  if (!confirmed) {
    return { cancel: true };
  }
});
```

---

## UI 交互

### 通知

```typescript
pi.ui.notify('Operation completed', 'info');
pi.ui.notify('Something went wrong', 'error');
pi.ui.notify('Please check', 'warning');
```

### 状态显示

```typescript
// 设置状态
pi.ui.setStatus('my-extension', 'Processing...');

// 清除状态
pi.ui.setStatus('my-extension', undefined);
```

### 工作消息

```typescript
pi.ui.setWorkingMessage('Analyzing codebase...');
// ... 操作完成后
pi.ui.setWorkingMessage(); // 恢复默认
```

### 自定义组件

```typescript
pi.ui.setWidget('my-widget', [
  'Line 1',
  'Line 2',
  'Line 3',
], { placement: 'aboveEditor' });

// 清除
pi.ui.setWidget('my-widget', undefined);
```

---

## 文件操作

### 读取文件

```typescript
const result = await ctx.exec('cat', ['file.txt']);
const content = result.stdout;
```

### 写入文件

```typescript
await ctx.exec('bash', ['-c', 'echo "content" > file.txt']);
```

### 检查文件存在

```typescript
async function fileExists(path: string, ctx): Promise<boolean> {
  try {
    await ctx.exec('test', ['-f', path]);
    return true;
  } catch {
    return false;
  }
}
```

### 遍历目录

```typescript
const { stdout } = await ctx.exec('find', [path, '-type', 'f', '-name', '*.ts']);
const files = stdout.split('\n').filter(Boolean);
```

---

## 网络请求

### 简单 GET

```typescript
const response = await fetch('https://api.example.com/data');
const data = await response.json();
```

### 带认证的请求

```typescript
const response = await fetch('https://api.example.com/data', {
  headers: {
    'Authorization': `Bearer ${process.env.API_KEY}`,
  },
});
```

### 下载文件

```typescript
const response = await fetch(url);
const buffer = await response.arrayBuffer();
await writeFile(path, Buffer.from(buffer));
```

---

## 常见模式

### 审计日志

```typescript
export default function auditExtension(pi: ExtensionAPI) {
  const auditLog: Array<{ time: number; action: string; details: unknown }> = [];
  
  pi.on('tool_call', async (event) => {
    auditLog.push({
      time: Date.now(),
      action: 'tool_call',
      details: {
        tool: event.toolName,
        input: event.input,
      },
    });
  });
  
  pi.registerCommand('audit', {
    description: 'Show audit log',
    execute: async (ctx) => {
      const recent = auditLog.slice(-10);
      ctx.sendMessage({
        customType: 'audit-log',
        content: JSON.stringify(recent, null, 2),
      });
    },
  });
}
```

### 待办列表

```typescript
interface Todo {
  id: string;
  text: string;
  done: boolean;
}

export default function todoExtension(pi: ExtensionAPI) {
  const todos: Todo[] = [];
  
  pi.registerCommand('todo', {
    description: 'Manage todos',
    execute: async (ctx) => {
      const action = await ctx.ui.select('Action', [
        'Add todo',
        'List todos',
        'Mark done',
      ]);
      
      switch (action) {
        case 'Add todo': {
          const text = await ctx.ui.input('Todo text');
          if (text) {
            todos.push({ id: Date.now().toString(), text, done: false });
            ctx.ui.notify('Todo added', 'info');
          }
          break;
        }
        case 'List todos': {
          const list = todos.map(t => `${t.done ? '✓' : '○'} ${t.text}`).join('\n');
          ctx.sendUserMessage(`Current todos:\n${list}`);
          break;
        }
        case 'Mark done': {
          const todo = await ctx.ui.select(
            'Select todo',
            todos.filter(t => !t.done).map(t => t.text)
          );
          if (todo) {
            const found = todos.find(t => t.text === todo);
            if (found) found.done = true;
          }
          break;
        }
      }
    },
  });
}
```

### 代码审查助手

```typescript
export default function reviewHelper(pi: ExtensionAPI) {
  pi.on('tool_call', async (event) => {
    if (event.toolName === 'write' && event.input.path?.includes('test')) {
      // 提醒写测试
      console.warn('You modified test files. Make sure tests still pass.');
    }
  });
  
  pi.registerCommand('review', {
    description: 'Review recent changes',
    execute: async (ctx) => {
      // 获取 git diff
      const diff = await ctx.exec('git', ['diff', 'HEAD~1']);
      
      // 发送给 Agent 审查
      ctx.sendUserMessage(
        `Please review these changes:\n\n\`\`\`diff\n${diff.stdout}\n\`\`\``
      );
    },
  });
}
```

### 智能重试

```typescript
async function withRetry<T>(
  fn: () => Promise<T>,
  maxRetries = 3,
  delay = 1000
): Promise<T> {
  for (let i = 0; i < maxRetries; i++) {
    try {
      return await fn();
    } catch (err) {
      if (i === maxRetries - 1) throw err;
      await new Promise(r => setTimeout(r, delay * (i + 1)));
    }
  }
  throw new Error('Unreachable');
}

// 使用
const result = await withRetry(async () => {
  return await fetchData();
});
```

---

## 本章小结

- **复制即用**：所有代码片段可直接使用
- **组合创新**：将多个模式组合创造新功能
- **持续积累**：建立自己的代码片段库
