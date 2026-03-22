# 第10章：实战模式

> 常见扩展模式、案例分析

---

## 10.1 模式概述

本章介绍在 pi 扩展开发中常用的设计模式，每个模式包含：
- **问题**：解决什么问题
- **方案**：如何实现
- **示例**：代码实现
- **变体**：常见变体

---

## 10.2 审计日志模式

### 问题
需要记录所有重要操作，用于审计和调试。

### 方案
监听工具调用事件，记录到内存或文件。

### 示例

```typescript
export default function auditExtension(pi: ExtensionAPI) {
  const auditLog: Array<{
    timestamp: number;
    action: string;
    details: unknown;
  }> = [];

  // 记录所有工具调用
  pi.on('tool_call', async (event) => {
    auditLog.push({
      timestamp: Date.now(),
      action: 'tool_call',
      details: {
        tool: event.toolName,
        input: event.input,
      },
    });
  });

  // 记录文件修改
  pi.on('tool_result', async (event) => {
    if (event.toolName === 'write' || event.toolName === 'edit') {
      auditLog.push({
        timestamp: Date.now(),
        action: 'file_modified',
        details: {
          path: event.input.path,
          tool: event.toolName,
        },
      });
    }
  });

  // 提供查询命令
  pi.registerCommand('audit', {
    description: 'Show audit log',
    execute: async (ctx) => {
      const recent = auditLog.slice(-20);
      const formatted = recent.map(entry =>
        `[${new Date(entry.timestamp).toISOString()}] ${entry.action}: ${JSON.stringify(entry.details)}`
      ).join('\n');

      ctx.sendUserMessage(`Recent operations:\n\`\`\`\n${formatted}\n\`\`\``);
    },
  });

  // 定期保存到文件
  setInterval(async () => {
    if (auditLog.length > 0) {
      await saveAuditLog(auditLog);
    }
  }, 60000);
}
```

### 变体

**过滤特定操作**：
```typescript
pi.on('tool_call', async (event) => {
  if (['write', 'edit', 'bash'].includes(event.toolName)) {
    // 只记录危险操作
    auditLog.push({...});
  }
});
```

---

## 10.3 待办管理模式

### 问题
需要在会话中跟踪任务状态。

### 方案
使用自定义 entry 持久化状态。

### 示例

```typescript
interface Todo {
  id: string;
  text: string;
  done: boolean;
  priority: 'low' | 'medium' | 'high';
}

export default function todoExtension(pi: ExtensionAPI) {
  let todos: Todo[] = [];

  // 加载时恢复状态
  pi.on('session_start', async () => {
    // 从自定义 entry 恢复
    const saved = await loadTodos();
    if (saved) todos = saved;
  });

  pi.registerCommand('todo', {
    description: 'Manage todos',
    execute: async (ctx) => {
      const action = await ctx.ui.select('Action', [
        'Add todo',
        'List todos',
        'Mark done',
        'Delete todo',
      ]);

      switch (action) {
        case 'Add todo': {
          const text = await ctx.ui.input('Todo text');
          const priority = await ctx.ui.select('Priority', ['low', 'medium', 'high']);

          if (text) {
            const todo: Todo = {
              id: Date.now().toString(),
              text,
              done: false,
              priority: priority as 'low' | 'medium' | 'high',
            };
            todos.push(todo);
            saveTodos(todos);
            ctx.ui.notify('Todo added', 'info');
          }
          break;
        }

        case 'List todos': {
          const list = todos
            .sort((a, b) => (a.done === b.done ? 0 : a.done ? 1 : -1))
            .map(t => `${t.done ? '✓' : '○'} [${t.priority}] ${t.text}`)
            .join('\n');
          ctx.sendUserMessage(`Todos:\n${list || 'No todos'}`);
          break;
        }

        case 'Mark done': {
          const pending = todos.filter(t => !t.done);
          if (pending.length === 0) {
            ctx.ui.notify('No pending todos', 'info');
            break;
          }
          const todo = await ctx.ui.select(
            'Select todo to complete',
            pending.map(t => t.text)
          );
          if (todo) {
            const found = todos.find(t => t.text === todo);
            if (found) {
              found.done = true;
              saveTodos(todos);
              ctx.ui.notify('Todo completed!', 'info');
            }
          }
          break;
        }

        case 'Delete todo': {
          const todo = await ctx.ui.select(
            'Select todo to delete',
            todos.map(t => t.text)
          );
          if (todo) {
            todos = todos.filter(t => t.text !== todo);
            saveTodos(todos);
            ctx.ui.notify('Todo deleted', 'info');
          }
          break;
        }
      }
    },
  });

  // 持久化函数
  async function saveTodos(todos: Todo[]) {
    pi.appendEntry('todos', todos);
  }

  async function loadTodos(): Promise<Todo[] | null> {
    // 从 session 读取自定义 entry
    // 实际实现取决于 session 访问 API
    return null;
  }
}
```

---

## 10.4 代码审查模式

### 问题
需要在提交前自动检查代码问题。

### 方案
拦截写操作，进行静态分析。

### 示例

```typescript
export default function reviewExtension(pi: ExtensionAPI) {
  // 定义检查规则
  const rules = [
    {
      name: 'no-console',
      pattern: /console\.(log|warn|error)/,
      message: 'Remove console statements before commit',
      severity: 'warning',
    },
    {
      name: 'no-todo',
      pattern: /TODO|FIXME|XXX/,
      message: 'Unresolved TODO/FIXME found',
      severity: 'warning',
    },
    {
      name: 'no-debugger',
      pattern: /debugger;/,
      message: 'Remove debugger statement',
      severity: 'error',
    },
  ];

  pi.on('tool_result', async (event) => {
    if (event.toolName !== 'write' && event.toolName !== 'edit') {
      return;
    }

    const content = extractTextContent(event.content);
    const issues = [];

    for (const rule of rules) {
      if (rule.pattern.test(content)) {
        issues.push({
          rule: rule.name,
          message: rule.message,
          severity: rule.severity,
        });
      }
    }

    if (issues.length > 0) {
      const errorCount = issues.filter(i => i.severity === 'error').length;
      const warningCount = issues.filter(i => i.severity === 'warning').length;

      return {
        content: [
          ...event.content,
          {
            type: 'text',
            text: `\n⚠️ Code Review (${errorCount} errors, ${warningCount} warnings):\n` +
                  issues.map(i => `  ${i.severity === 'error' ? '🔴' : '🟡'} ${i.message}`).join('\n'),
          },
        ],
      };
    }
  });

  // 手动审查命令
  pi.registerCommand('review', {
    description: 'Review recent changes',
    execute: async (ctx) => {
      const diff = await ctx.exec('git', ['diff', 'HEAD~1', '--name-only']);
      const files = diff.stdout.split('\n').filter(Boolean);

      if (files.length === 0) {
        ctx.ui.notify('No changes to review', 'info');
        return;
      }

      ctx.sendUserMessage(
        `Please review these changed files:\n${files.map(f => `- ${f}`).join('\n')}`
      );
    },
  });
}
```

---

## 10.5 智能重试模式

### 问题
某些操作可能失败，需要自动重试。

### 方案
包装执行函数，添加重试逻辑。

### 示例

```typescript
async function withRetry<T>(
  fn: () => Promise<T>,
  options: {
    maxRetries?: number;
    delay?: number;
    backoff?: number;
    onRetry?: (attempt: number, error: Error) => void;
  } = {}
): Promise<T> {
  const {
    maxRetries = 3,
    delay = 1000,
    backoff = 2,
    onRetry,
  } = options;

  let lastError: Error;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error as Error;

      if (attempt === maxRetries) {
        throw lastError;
      }

      const waitTime = delay * Math.pow(backoff, attempt - 1);
      onRetry?.(attempt, lastError);
      await new Promise(r => setTimeout(r, waitTime));
    }
  }

  throw lastError!;
}

// 使用示例
pi.registerTool({
  name: 'fetch-with-retry',
  description: 'Fetch URL with automatic retry',
  parameters: Type.Object({
    url: Type.String(),
    retries: Type.Number({ default: 3 }),
  }),
  async execute(toolCallId, args, signal, onUpdate, ctx) {
    const result = await withRetry(
      async () => {
        const response = await fetch(args.url);
        if (!response.ok) {
          throw new Error(`HTTP ${response.status}`);
        }
        return response.text();
      },
      {
        maxRetries: args.retries,
        onRetry: (attempt, error) => {
          onUpdate?.({
            content: [{ type: 'text', text: `Retry ${attempt}/${args.retries}: ${error.message}` }],
          });
        },
      },
    );

    return {
      content: [{ type: 'text', text: result }],
      details: undefined,
    };
  },
});
```

---

## 10.6 缓存模式

### 问题
某些操作昂贵，需要缓存结果。

### 方案
使用内存或文件缓存。

### 示例

```typescript
class SimpleCache<T> {
  private cache = new Map<string, { value: T; expiry: number }>();

  get(key: string): T | undefined {
    const entry = this.cache.get(key);
    if (!entry) return undefined;
    if (Date.now() > entry.expiry) {
      this.cache.delete(key);
      return undefined;
    }
    return entry.value;
  }

  set(key: string, value: T, ttlMs: number): void {
    this.cache.set(key, {
      value,
      expiry: Date.now() + ttlMs,
    });
  }

  clear(): void {
    this.cache.clear();
  }
}

// 使用示例
const apiCache = new SimpleCache<string>();

pi.registerTool({
  name: 'cached-api-call',
  description: 'API call with caching',
  parameters: Type.Object({
    endpoint: Type.String(),
    cacheTtl: Type.Number({ default: 60000 }), // 1 minute
  }),
  async execute(toolCallId, args, signal, onUpdate, ctx) {
    const cached = apiCache.get(args.endpoint);
    if (cached) {
      return {
        content: [{ type: 'text', text: cached + '\n[Cached]' }],
      };
    }

    const result = await fetchApi(args.endpoint);
    apiCache.set(args.endpoint, result, args.cacheTtl);

    return {
      content: [{ type: 'text', text: result }],
    };
  },
});
```

---

## 10.7 工作流模式

### 问题
需要引导用户完成多步骤流程。

### 方案
使用状态机管理流程。

### 示例

```typescript
export default function workflowExtension(pi: ExtensionAPI) {
  type DeployState =
    | { step: 'select-env' }
    | { step: 'confirm'; env: string }
    | { step: 'running'; env: string; version: string }
    | { step: 'complete'; env: string };

  let state: DeployState = { step: 'select-env' };

  pi.registerCommand('deploy', {
    description: 'Deploy with guided workflow',
    execute: async (ctx) => {
      // Step 1: 选择环境
      const env = await ctx.ui.select('Select environment', [
        'development',
        'staging',
        'production',
      ]);

      if (!env) return;
      state = { step: 'confirm', env };

      // Step 2: 确认
      const confirmed = await ctx.ui.confirm(
        'Confirm deployment',
        `Deploy to ${env}?`
      );

      if (!confirmed) {
        state = { step: 'select-env' };
        return;
      }

      // Step 3: 执行
      const version = `v${Date.now()}`;
      state = { step: 'running', env, version };

      ctx.ui.setWorkingMessage(`Deploying ${version} to ${env}...`);

      try {
        await ctx.exec('deploy-script', [env, version]);
        state = { step: 'complete', env };
        ctx.ui.notify('Deployment complete!', 'info');
      } catch (error) {
        ctx.ui.notify('Deployment failed', 'error');
        state = { step: 'select-env' };
      } finally {
        ctx.ui.setWorkingMessage();
      }
    },
  });
}
```

---

## 10.8 组合模式

### 问题
需要组合多个工具完成复杂任务。

### 方案
创建一个协调工具。

### 示例

```typescript
pi.registerTool({
  name: 'refactor-component',
  description: 'Refactor a React component with full workflow',
  parameters: Type.Object({
    path: Type.String(),
    goal: Type.String(),
  }),
  async execute(toolCallId, args, signal, onUpdate, ctx) {
    // Step 1: 读取原文件
    onUpdate?.({ content: [{ type: 'text', text: 'Reading component...' }] });
    const original = await ctx.exec('read', [args.path]);

    // Step 2: 分析
    onUpdate?.({ content: [{ type: 'text', text: 'Analyzing structure...' }] });
    const analysis = await analyzeComponent(original.stdout);

    // Step 3: 生成新代码
    onUpdate?.({ content: [{ type: 'text', text: 'Generating refactored code...' }] });
    const newCode = await generateRefactoredCode(analysis, args.goal);

    // Step 4: 备份原文件
    onUpdate?.({ content: [{ type: 'text', text: 'Creating backup...' }] });
    await ctx.exec('bash', ['-c', `cp ${args.path} ${args.path}.backup`]);

    // Step 5: 写入新代码
    onUpdate?.({ content: [{ type: 'text', text: 'Applying changes...' }] });
    await ctx.exec('write', [args.path, newCode]);

    // Step 6: 验证
    onUpdate?.({ content: [{ type: 'text', text: 'Running tests...' }] });
    const testResult = await ctx.exec('npm', ['test', '--', args.path]);

    return {
      content: [
        { type: 'text', text: 'Refactoring complete!' },
        { type: 'text', text: `Tests: ${testResult.exitCode === 0 ? '✓ Passed' : '✗ Failed'}` },
      ],
      details: { analysis, backupPath: `${args.path}.backup` },
    };
  },
});
```

---

## 本章小结

| 模式 | 用途 | 关键 API |
|-----|------|---------|
| 审计日志 | 记录操作 | `pi.on('tool_call')` |
| 待办管理 | 任务跟踪 | `pi.appendEntry()`, `pi.registerCommand()` |
| 代码审查 | 自动检查 | `pi.on('tool_result')` |
| 智能重试 | 容错处理 | `withRetry()` 包装 |
| 缓存 | 性能优化 | `SimpleCache` 类 |
| 工作流 | 引导流程 | 状态机 + `ctx.ui` |
| 组合 | 复杂任务 | 协调多个工具 |
