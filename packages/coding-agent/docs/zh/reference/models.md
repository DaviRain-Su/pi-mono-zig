# 自定义模型

通过 `~/.pi/agent/models.json` 添加自定义 provider 和模型（Ollama、vLLM、LM Studio、代理）。

## 目录

- [最小示例](#最小示例)
- [完整示例](#完整示例)
- [支持的 API](#支持的-api)
- [Provider 配置](#provider-配置)
- [模型配置](#模型配置)
- [覆盖内置 Provider](#覆盖内置-provider)
- [按模型覆盖](#按模型覆盖)
- [OpenAI 兼容性](#openai-兼容性)

## 最小示例

对于本地模型（Ollama、LM Studio、vLLM），每个模型只需要 `id`：

```json
{
  "providers": {
    "ollama": {
      "baseUrl": "http://localhost:11434/v1",
      "api": "openai-completions",
      "apiKey": "ollama",
      "models": [
        { "id": "llama3.1:8b" },
        { "id": "qwen2.5-coder:7b" }
      ]
    }
  }
}
```

`apiKey` 是必需的但 Ollama 会忽略它，所以任何值都可以。

某些 OpenAI 兼容服务器不理解用于支持推理模型的角色。对于这些 provider，设置 `compat.supportsDeveloperRole` 为 `false`，这样 pi 会将系统提示作为 `system` 消息发送。如果服务器也不支持 `reasoning_effort`，同时设置 `compat.supportsReasoningEffort` 为 `false`。

可以在 provider 级别设置 `compat` 以应用到所有模型，或在模型级别覆盖特定模型。这通常适用于 Ollama、vLLM、SGLang 和类似的 OpenAI 兼容服务器。

```json
{
  "providers": {
    "ollama": {
      "baseUrl": "http://localhost:11434/v1",
      "api": "openai-completions",
      "apiKey": "ollama",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [
        {
          "id": "gpt-oss:20b",
          "reasoning": true
        }
      ]
    }
  }
}
```

## 完整示例

需要特定值时覆盖默认值：

```json
{
  "providers": {
    "ollama": {
      "baseUrl": "http://localhost:11434/v1",
      "api": "openai-completions",
      "apiKey": "ollama",
      "models": [
        {
          "id": "llama3.1:8b",
          "name": "Llama 3.1 8B (Local)",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 128000,
          "maxTokens": 32000,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
```

每次打开 `/model` 时文件会重新加载。可在会话期间编辑；无需重启。

## 支持的 API

| API | 描述 |
|-----|------|
| `openai-completions` | OpenAI Chat Completions（最兼容）|
| `openai-responses` | OpenAI Responses API |
| `anthropic-messages` | Anthropic Messages API |
| `google-generative-ai` | Google Generative AI |

在 provider 级别设置 `api`（所有模型的默认值）或在模型级别设置（覆盖特定模型）。

## Provider 配置

| 字段 | 描述 |
|-----|------|
| `baseUrl` | API 端点 URL |
| `api` | API 类型（见上文）|
| `apiKey` | API key（见值解析）|
| `headers` | 自定义头（见值解析）|
| `authHeader` | 设置 `true` 自动添加 `Authorization: Bearer <apiKey>` |
| `models` | 模型配置数组 |
| `modelOverrides` | 此 provider 上内置模型的按模型覆盖 |

### 值解析

`apiKey` 和 `headers` 字段支持三种格式：

- **Shell 命令：** `"!command"` 执行并使用 stdout
  ```json
  "apiKey": "!security find-generic-password -ws 'anthropic'"
  "apiKey": "!op read 'op://vault/item/credential'"
  ```
- **环境变量：** 使用命名变量的值
  ```json
  "apiKey": "MY_API_KEY"
  ```
- **字面值：** 直接使用
  ```json
  "apiKey": "sk-..."
  ```

### 自定义头

```json
{
  "providers": {
    "custom-proxy": {
      "baseUrl": "https://proxy.example.com/v1",
      "apiKey": "MY_API_KEY",
      "api": "anthropic-messages",
      "headers": {
        "x-portkey-api-key": "PORTKEY_API_KEY",
        "x-secret": "!op read 'op://vault/item/secret'"
      },
      "models": [...]
    }
  }
}
```

## 模型配置

| 字段 | 必需 | 默认值 | 描述 |
|------|------|--------|------|
| `id` | 是 | — | 模型标识符（传递给 API）|
| `name` | 否 | `id` | 人类可读的模型标签。用于匹配（`--model` 模式）和显示在模型详情/状态文本中。 |
| `api` | 否 | provider 的 `api` | 覆盖此模型的 provider API |
| `reasoning` | 否 | `false` | 是否支持扩展思考 |
| `input` | 否 | `["text"]` | 输入类型：`["text"]` 或 `["text", "image"]` |
| `contextWindow` | 否 | `128000` | 上下文窗口大小（token）|
| `maxTokens` | 否 | `16384` | 最大输出 token |
| `cost` | 否 | 全零 | `{"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}`（每百万 token）|
| `compat` | 否 | provider 的 `compat` | OpenAI 兼容性覆盖。当两者都设置时与 provider 级别的 `compat` 合并。 |

当前行为：
- `/model` 和 `--list-models` 按模型 `id` 列出条目。
- 配置的 `name` 用于模型匹配和详情/状态文本。

## 覆盖内置 Provider

通过代理路由内置 provider，无需重新定义模型：

```json
{
  "providers": {
    "anthropic": {
      "baseUrl": "https://my-proxy.example.com/v1"
    }
  }
}
```

所有内置 Anthropic 模型保持可用。现有的 OAuth 或 API key 认证继续工作。

要合并自定义模型到内置 provider，包含 `models` 数组：

```json
{
  "providers": {
    "anthropic": {
      "baseUrl": "https://my-proxy.example.com/v1",
      "apiKey": "ANTHROPIC_API_KEY",
      "api": "anthropic-messages",
      "models": [...]
    }
  }
}
```

合并语义：
- 内置模型被保留。
- 自定义模型按 `id` 在 provider 内 upsert。
- 如果自定义模型 `id` 匹配内置模型 `id`，自定义模型替换该内置模型。
- 如果自定义模型 `id` 是新的，它会被添加到内置模型旁边。

## 按模型覆盖

使用 `modelOverrides` 自定义特定内置模型，而无需替换 provider 的完整模型列表。

```json
{
  "providers": {
    "openrouter": {
      "modelOverrides": {
        "anthropic/claude-sonnet-4": {
          "name": "Claude Sonnet 4 (Bedrock Route)",
          "compat": {
            "openRouterRouting": {
              "only": ["amazon-bedrock"]
            }
          }
        }
      }
    }
  }
}
```

`modelOverrides` 支持每个模型的这些字段：`name`、`reasoning`、`input`、`cost`（部分）、`contextWindow`、`maxTokens`、`headers`、`compat`。

行为说明：
- `modelOverrides` 应用于内置 provider 模型。
- 未知模型 ID 被忽略。
- 可以将 provider 级别的 `baseUrl`/`headers` 与 `modelOverrides` 组合。
- 如果为 provider 也定义了 `models`，自定义模型在内置覆盖后合并。相同 `id` 的自定义模型会替换覆盖后的内置模型条目。

## OpenAI 兼容性

对于部分 OpenAI 兼容的 provider，使用 `compat` 字段。

- Provider 级别的 `compat` 对该 provider 下的所有模型设置默认值。
- 模型级别的 `compat` 覆盖该模型的 provider 级别值。

```json
{
  "providers": {
    "local-llm": {
      "baseUrl": "http://localhost:8080/v1",
      "api": "openai-completions",
      "compat": {
        "supportsUsageInStreaming": false,
        "maxTokensField": "max_tokens"
      },
      "models": [...]
    }
  }
}
```

| 字段 | 描述 |
|------|------|
| `supportsStore` | Provider 支持 `store` 字段 |
| `supportsDeveloperRole` | 使用 `developer` vs `system` 角色 |
| `supportsReasoningEffort` | 支持 `reasoning_effort` 参数 |
| `reasoningEffortMap` | 将 pi 思考级别映射到 provider 特定的 `reasoning_effort` 值 |
| `supportsUsageInStreaming` | 支持 `stream_options: { include_usage: true }`（默认：`true`）|
| `maxTokensField` | 使用 `max_completion_tokens` 或 `max_tokens` |
| `requiresToolResultName` | 在工具结果消息中包含 `name` |
| `requiresAssistantAfterToolResult` | 在工具结果后的用户消息前插入助手消息 |
| `requiresThinkingAsText` | 将思考块转换为纯文本 |
| `thinkingFormat` | 使用 `reasoning_effort`、`zai`、`qwen` 或 `qwen-chat-template` 思考参数 |
| `supportsStrictMode` | 在工具定义中包含 `strict` 字段 |
| `openRouterRouting` | 传递给 OpenRouter 用于模型/provider 选择的 OpenRouter 路由配置 |
| `vercelGatewayRouting` | 用于 provider 选择的 Vercel AI Gateway 路由配置（`only`、`order`）|

`qwen` 使用顶层 `enable_thinking`。对于需要 `chat_template_kwargs.enable_thinking` 的本地 Qwen 兼容服务器，使用 `qwen-chat-template`。

示例：

```json
{
  "providers": {
    "openrouter": {
      "baseUrl": "https://openrouter.ai/api/v1",
      "apiKey": "OPENROUTER_API_KEY",
      "api": "openai-completions",
      "models": [
        {
          "id": "openrouter/anthropic/claude-3.5-sonnet",
          "name": "OpenRouter Claude 3.5 Sonnet",
          "compat": {
            "openRouterRouting": {
              "order": ["anthropic"],
              "fallbacks": ["openai"]
            }
          }
        }
      ]
    }
  }
}
```

Vercel AI Gateway 示例：

```json
{
  "providers": {
    "vercel-ai-gateway": {
      "baseUrl": "https://ai-gateway.vercel.sh/v1",
      "apiKey": "AI_GATEWAY_API_KEY",
      "api": "openai-completions",
      "models": [
        {
          "id": "moonshotai/kimi-k2.5",
          "name": "Kimi K2.5 (Fireworks via Vercel)",
          "reasoning": true,
          "input": ["text", "image"],
          "cost": { "input": 0.6, "output": 3, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 262144,
          "maxTokens": 262144,
          "compat": {
            "vercelGatewayRouting": {
              "only": ["fireworks", "novita"],
              "order": ["fireworks", "novita"]
            }
          }
        }
      ]
    }
  }
}
```