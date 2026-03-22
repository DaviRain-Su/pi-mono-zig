# 第8章：你的第一个扩展

> 从零编写、热重载、调试

---

## 8.1 准备工作

### 创建扩展目录

```bash
mkdir -p ~/.pi/extensions/my-first-extension
cd ~/.pi/extensions/my-first-extension
```

### 创建入口文件

```bash
cat > index.ts << 'EOF'
import type { ExtensionAPI } from '@mariozechner/pi-coding-agent';
import { Type } from '@sinclair/typebox';

export default function myFirstExtension(pi: ExtensionAPI) {
  // 你的代码将在这里
  console.log('My first extension loaded!');
}
EOF
```

---

## 8.2 注册第一个工具

编辑 `index.ts`：

```typescript
import type { ExtensionAPI } from '@mariozechner/pi-coding-agent';
import { Type } from '@sinclair/typebox';

export default function myFirstExtension(pi: ExtensionAPI) {
  // 注册一个计算文件行数的工具
  pi.registerTool({
    name: 'count-lines',
    description: 'Count the number of lines in a file',
    parameters: Type.Object({
      path: Type.String({ description: 'Path to the file' }),
    }),
    async execute(toolCallId, args, signal, onUpdate, ctx) {
      // 执行 wc -l 命令
      const result = await ctx.exec('wc', ['-l', args.path]);
      
      // 返回结果
      return {
        content: [
          { type: 'text', text: result.stdout },
        ],
        details: undefined,
      };
    },
  });
}
```

### 测试工具

1. 在 pi 中执行 `/reload`
2. 告诉 Agent："用 count-lines 工具统计 README.md 的行数"
3. 观察工具被调用

---

## 8.3 添加流式更新

让工具在执行过程中报告进度：

```typescript
pi.registerTool({
  name: 'analyze-project',
  description: 'Analyze project structure and report statistics',
  parameters: Type.Object({
    path: Type.String({ description: 'Project root path' }),
  }),
  async execute(toolCallId, args, signal, onUpdate, ctx) {
    // 报告开始
    onUpdate?.({
      content: [{ type: 'text', text: 'Scanning directory structure...' }],
    });

    // 步骤1：统计文件数
    const files = await ctx.exec('find', [args.path, '-type', 'f']);
    const fileCount = files.stdout.split('\n').length - 1;

    onUpdate?.({
      content: [{ type: 'text', text: `Found ${fileCount} files, analyzing types...` }],
    });

    // 步骤2：统计代码行数
    const lines = await ctx.exec('find', [args.path, '-name', '*.ts', '-exec', 'wc', '-l', '{}', '+']);

    // 返回最终结果
    return {
      content: [
        { type: 'text', text: `Files: ${fileCount}\n${lines.stdout}` },
      ],
      details: { fileCount },
    };
  },
});
```

---

## 8.4 注册斜杠命令

添加一个可以直接调用的命令：

```typescript
pi.registerCommand('stats', {
  description: 'Show project statistics',
  async execute(ctx) {
    // 获取当前目录
    const cwd = ctx.cwd;
    
    // 发送消息让 Agent 使用工具
    ctx.sendUserMessage(`Analyze the project at ${cwd} and show statistics`);
  },
});
```

现在在 pi 中输入 `/stats` 即可触发。

---

## 8.5 监听事件

在关键操作时执行自定义逻辑：

```typescript
// 工具调用前拦截
pi.on('tool_call', async (event) => {
  if (event.toolName === 'write' && event.input.path?.includes('.env')) {
    // 可记录告警，不可返回 action: 'warn'
    console.warn('Writing to .env file. Make sure no secrets are exposed.');
  }
});

// 会话切换时记录
pi.on('session_switch', async (event) => {
  console.log(`Switched to session: ${event.sessionPath}`);
});
```

---

## 8.6 调试技巧

### 1. 控制台日志

```typescript
export default function myExtension(pi: ExtensionAPI) {
  console.log('Extension loading...');
  
  pi.registerTool({
    name: 'debug-tool',
    async execute(toolCallId, args, signal, onUpdate, ctx) {
      console.log('Tool called with args:', args);
      console.log('Current directory:', ctx.cwd);
      // ...
      return {
        content: [{ type: 'text', text: 'Debug tool executed' }],
        details: undefined,
      };
    },
  });
}
```

### 2. 条件断点

```typescript
pi.on('tool_call', async (event) => {
  if (event.toolName === 'write' && event.input.path === 'debug.txt') {
    debugger; // 在此处断点
  }
});
```

### 3. 事件日志

```typescript
// 记录关键事件（按类型逐个注册）
pi.on('message_end', (event) => {
  console.log('[Message]', event.message.role, event.message.id);
});

pi.on('tool_execution_end', (event) => {
  console.log('[Tool]', event.toolName, event.toolCallId, event.isError ? 'failed' : 'ok');
});
```

---

## 8.7 热重载工作流

开发扩展的推荐流程：

```
1. 编辑代码
      ↓
2. 在 pi 中执行 /reload
      ↓
3. 测试新功能
      ↓
4. 有问题？回到步骤1
      ↓
5. 满意了？提交到 git
```

### 让 Agent 帮你调试

告诉 pi：
> "我的扩展在 ~/.pi/extensions/my-first-extension/，帮我检查一下为什么 count-lines 工具返回空结果"

Agent 会：
1. 读取你的代码
2. 分析问题
3. 提出修复建议或直接修改

---

## 8.8 完整示例

```typescript
import type { ExtensionAPI } from '@mariozechner/pi-coding-agent';
import { Type } from '@sinclair/typebox';

export default function projectHelper(pi: ExtensionAPI) {
  // 工具：批量重命名
  pi.registerTool({
    name: 'batch-rename',
    description: 'Batch rename files matching a pattern',
    parameters: Type.Object({
      pattern: Type.String({ description: 'Glob pattern to match' }),
      from: Type.String({ description: 'String to replace' }),
      to: Type.String({ description: 'Replacement string' }),
      dryRun: Type.Boolean({ default: true }),
    }),
    async execute(toolCallId, args, signal, onUpdate, ctx) {
      const { stdout } = await ctx.exec('find', ['.', '-name', args.pattern, '-type', 'f']);
      const files = stdout.split('\n').filter(Boolean);
      
      const changes = [];
      for (const file of files) {
        const newName = file.replace(args.from, args.to);
        if (file !== newName) {
          changes.push({ from: file, to: newName });
          if (!args.dryRun) {
            await ctx.exec('mv', [file, newName]);
          }
        }
      }
      
      return {
        content: [{
          type: 'text',
          text: args.dryRun 
            ? `Dry run - would rename:\n${changes.map(c => `${c.from} -> ${c.to}`).join('\n')}`
            : `Renamed ${changes.length} files`,
        }],
        details: { changes },
      };
    },
  });

  // 命令：快速重命名
  pi.registerCommand('rename', {
    description: 'Batch rename files',
    async execute(ctx) {
      const pattern = await ctx.ui.input('File pattern', '*.txt');
      const from = await ctx.ui.input('Replace');
      const to = await ctx.ui.input('With');
      
      if (pattern && from && to) {
        ctx.sendUserMessage(`Use batch-rename to replace "${from}" with "${to}" in ${pattern}`);
      }
    },
  });

  // 审计：记录所有写操作
  pi.on('tool_call', async (event) => {
    if (event.toolName === 'write' || event.toolName === 'edit') {
      console.log(`[AUDIT] ${event.toolName}: ${event.input.path}`);
    }
  });
}
```

---

## 8.9 下一步

- 学习更多 API：[第9章：扩展 API 详解](./09-extension-api.md)
- 查看常见模式：[第10章：实战模式](../patterns/10-patterns.md)
- 复制代码片段：[第11章：Cookbook](../cookbook/11-cookbook.md)

---

## 本章小结

- **扩展结构**：`~/.pi/extensions/name/index.ts`
- **三大能力**：registerTool、registerCommand、pi.on
- **开发流程**：编辑 → /reload → 测试 → 迭代
- **调试方法**：console.log、debugger、事件日志
- **秘密武器**：让 Agent 帮你调试扩展
