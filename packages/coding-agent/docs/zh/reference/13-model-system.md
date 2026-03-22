# 第13章：模型系统

> Provider、注册、路由、自定义

---

## 13.1 模型抽象

### Model 接口

```typescript
interface Model<TApi extends Api> {
  id: string;                    // 模型ID
  name: string;                  // 显示名称
  provider: string;              // 提供商
  api: TApi;                     // API类型
  
  // 能力
  reasoning: boolean;            // 支持思考模式
  input: ('text' | 'image')[];   // 输入类型
  contextWindow: number;         // 上下文窗口
  maxTokens: number;             // 最大输出
  
  // 成本（每百万token）
  cost: {
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
  };
  
  // 兼容性设置
  compat?: OpenAICompletionsCompat | OpenAIResponsesCompat;
  
  // 连接配置
  baseUrl?: string;
  headers?: Record<string, string>;
}
```

### API 类型

```typescript
type KnownApi =
  | 'openai-completions'
  | 'openai-responses'
  | 'anthropic-messages'
  | 'google-generative-ai'
  | 'azure-openai-responses'
  | 'openai-codex-responses'
  | ...
```

---

## 13.2 Provider 架构

### Provider 注册

```typescript
// packages/ai/src/api-registry.ts

interface ApiProvider<TApi extends Api> {
  api: TApi;
  stream: StreamFunction<TApi, StreamOptions>;
  streamSimple: StreamFunction<TApi, SimpleStreamOptions>;
}

function registerApiProvider<TApi extends Api>(
  provider: ApiProvider<TApi>,
  sourceId?: string
): void;
```

### 内置 Provider

| Provider | API 类型 | 说明 |
|---------|---------|------|
| anthropic | anthropic-messages | Claude 系列 |
| openai | openai-completions | GPT 系列 |
| openai | openai-responses | ChatGPT / Codex |
| google | google-generative-ai | Gemini 系列 |
| azure | azure-openai-responses | Azure OpenAI |
| ... | ... | ... |

### 路由流程

```
streamSimple(model, context, options)
    │
    ▼
getApiProvider(model.api)
    │
    ▼
provider.streamSimple(model, context, options)
    │
    ▼
HTTP/WebSocket request
```

---

## 13.3 ModelRegistry

### 职责

- 加载内置模型
- 加载自定义模型（models.json）
- 管理 Provider 覆盖
- 解析 API Key

### 配置方式

#### 方式1：models.json

```json
{
  "providers": {
    "my-proxy": {
      "baseUrl": "https://proxy.example.com",
      "api": "anthropic-messages",
      "apiKey": "PROXY_API_KEY",
      "models": [
        {
          "id": "claude-custom",
          "name": "Claude (Custom)",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 200000,
          "maxTokens": 4096,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
```

#### 方式2：扩展注册

```typescript
pi.registerProvider('corp', {
  baseUrl: 'https://ai.corp.com',
  api: 'openai-completions',
  apiKey: 'CORP_API_KEY',
  models: [...],
});
```

### 配置覆盖规则

```
内置模型 < models.json 覆盖 < 扩展注册覆盖
```

---

## 13.4 自定义 Provider

### 简单覆盖

```typescript
// 只覆盖连接参数
pi.registerProvider('anthropic', {
  baseUrl: 'https://proxy.example.com',
  headers: { 'X-Custom': 'value' },
});
```

### 完整自定义

```typescript
// 自定义模型集合
pi.registerProvider('my-ai', {
  baseUrl: 'https://my-ai.com',
  api: 'openai-completions',
  apiKey: 'MY_API_KEY',
  models: [
    {
      id: 'custom-llm',
      name: 'Custom LLM',
      reasoning: false,
      input: ['text'],
      contextWindow: 32000,
      maxTokens: 4096,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    },
  ],
});
```

### 完全自定义 Stream

```typescript
pi.registerProvider('custom-api', {
  api: 'custom-api',
  streamSimple: async (model, context, options) => {
    const stream = new AssistantMessageEventStream();
    
    // 调用自定义API
    const response = await fetch(model.baseUrl, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${options.apiKey}` },
      body: JSON.stringify({
        messages: context.messages,
        model: model.id,
      }),
    });
    
    // 转换响应为事件
    const reader = response.body.getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      
      // 解析并推送事件
      stream.push({ type: 'text_delta', delta: value, partial: {...} });
    }
    
    stream.push({ type: 'done', message: finalMessage });
    return stream;
  },
});
```

---

## 13.5 API Key 解析

### 解析规则

```typescript
// 1. 命令前缀 ("!command")
"!/usr/bin/security find-generic-password -s api-key"
→ 执行命令，使用 stdout

// 2. 环境变量
"ANTHROPIC_API_KEY"
→ process.env.ANTHROPIC_API_KEY

// 3. 字面量
"sk-ant-..."
→ 直接使用
```

### 配置示例

```json
{
  "providers": {
    "anthropic": {
      "apiKey": "!~/bin/get-api-key anthropic"
    }
  }
}
```

---

## 13.6 模型选择

### 内置模型

```typescript
import { getModel } from '@mariozechner/pi-ai';

const model = getModel('anthropic', 'claude-sonnet-4');
```

### 模型切换

```typescript
// 在扩展中
await ctx.setModel(newModel);

// 在 pi 中
/model
```

### 模型循环

```typescript
// 配置 scoped models
pi --models claude-sonnet-4,gpt-4o,gemini-pro

// 快捷键切换
Ctrl+P         // 下一个
Shift+Ctrl+P   // 上一个
```

---

## 13.7 思考级别

### 级别定义

```typescript
type ThinkingLevel = 'off' | 'minimal' | 'low' | 'medium' | 'high' | 'xhigh';
```

### 模型支持

| 模型 | 支持的级别 |
|-----|----------|
| Claude 4 | off, minimal, low, medium, high, xhigh |
| GPT-4o | off, low, medium, high |
| Gemini | off, low, medium, high |

### 切换方式

```typescript
// 在扩展中
pi.setThinkingLevel('high');

// 在 pi 中
Shift+Tab   // 循环级别
/settings   // 设置默认
```

---

## 13.8 成本追踪

### Token 计算

```typescript
// packages/ai/src/models.ts
function calculateCost(
  model: Model<Api>,
  usage: { input: number; output: number; cacheRead?: number; cacheWrite?: number }
): number {
  const { cost } = model;
  return (
    (usage.input / 1e6) * cost.input +
    (usage.output / 1e6) * cost.output +
    (usage.cacheRead / 1e6) * (cost.cacheRead || 0) +
    (usage.cacheWrite / 1e6) * (cost.cacheWrite || 0)
  );
}
```

### 显示

状态栏显示：
```
12k/200k tokens | $0.023
```

---

## 本章小结

- **Model 接口**：统一抽象，能力声明
- **Provider 注册**：内置 + 自定义
- **ModelRegistry**：配置加载、覆盖规则
- **API Key 解析**：命令/环境变量/字面量
- **思考级别**：模型特定的推理控制
- **成本追踪**：Token 和费用计算

---

*详细模型配置请参考 [model-provider-architecture.md](./model-provider-architecture.md)*
