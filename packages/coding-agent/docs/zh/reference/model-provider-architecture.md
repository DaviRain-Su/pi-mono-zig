# Provider 与模型系统架构（`pi-ai` + `ModelRegistry`）

本页仅描述**技术内核**，用于二次开发时快速定位扩展点。

## 1. 核心类型（单向契约）

### `@mariozechner/pi-ai/src/types.ts`

关键类型：

- `KnownApi`：已知 provider api 字符串，如
  - `openai-completions`
  - `anthropic-messages`
  - `google-generative-ai`
  - `openai-responses`
  - `azure-openai-responses`
  - `openai-codex-responses`
  - 等
- `KnownProvider`：已知 provider id，如 `anthropic`, `openai`, `google`, `xai` ...
- `Api` / `Provider`：可扩展为字符串，以保证自定义 provider 可扩展。
- `Model<TApi extends Api>`：包含 `id/provider/api/baseUrl/reasoning/contextWindow/maxTokens/cost/headers/compat`。
- `StreamFn`：统一的 stream 协议函数。

### 事件与语义

`AssistantMessageEvent` 的最终终止事件是：
- `done`：返回最终成功消息
- `error`：返回 `stopReason: aborted | error`

`AssistantMessageEventStream` 只在 `done/error` 后收敛 `result()`，这一点决定了上层不能再通过 promise reject 做错误分支。

## 2. Registry 路径（`api-registry.ts`）

`api-registry` 的职责是 provider 生命周期：

- `registerApiProvider(apiProvider, sourceId?)`
- `getApiProvider(api)`
- `getApiProviders()`
- `unregisterApiProviders(sourceId)`
- `clearApiProviders()`

`registerApiProvider` 会包装 provider stream：
- 每次调用先校验 `model.api === api`
- 不匹配时抛出固定错误：`Mismatched api: ${model.api} expected ${api}`

**设计要点**：
- 约束放在入口层，避免 provider 实现拿到错模型。
- 支持多个源头动态注册（内置 + 扩展）。

## 3. 模型构建与查询（`getModels/getProviders`）

`models.generated.ts` 提供内置 provider/model 列表。

`packages/ai/src/models.ts` 在运行时：
- 加载并构建 `modelRegistry`（Map）
- 按 `provider/id` 查询
- 获取能力列表 `getModels(provider)`、`getProviders()`
- 计算 token 成本 `calculateCost(model, usage)`

## 4. 编码态 provider 链路

### 4.1 内置 provider 加载
- `providers/register-builtins.ts` 引入各 provider 文件
- 文件内通过懒加载（`import`）保证按需初始化
- `registerBuiltInApiProviders()` 在 `stream.ts` 首行执行，确保调用 `stream()` 永远有可用 provider（除特殊定制场景）

### 4.2 动态 provider 与模型（`ModelRegistry`）

`packages/coding-agent/src/core/model-registry.ts` 连接应用层模型需求：
- 读取 `models.json`
- 校验 schema（AJV + TypeBox）
- 应用 provider-level override（`baseUrl/headers/compat/apiKey`）
- 应用 model-level override（`modelOverrides`）
- 支持运行时 `registerProvider(name, config)` / `unregisterProvider(name)`
- 与 `AuthStorage` 关联，返回对应 API key

核心方法：
- `getAll()`：全部模型（内置+自定义）
- `getAvailable()`：只返回有鉴权的模型
- `find(provider, modelId)`：按键查找
- `getApiKey(model)` / `getApiKeyForProvider(provider)`
- `isUsingOAuth(model)`

## 5. `models.json` 校验与覆盖规则（重要）

`ModelsConfig` 里 `providers` 是核心映射：

- 当 `models` 为空时（覆盖-only）：必须至少存在 `baseUrl/compat/modelOverrides/models` 中至少一种。
- 当 `models` 非空时（自定义模型）：
  - provider 必须有 `baseUrl`
  - 需具备鉴权（`apiKey`，或自定义流程）
- model 级可覆盖 `api`；若 model 未给 `api`，会回退 provider-level `api`

常见错误（均有固定文本）：
- `must specify "baseUrl", "compat", "modelOverrides", or "models"`
- `"baseUrl" is required when defining custom models`
- `"apiKey" is required when defining custom models`
- `no "api" specified`
- `model missing "id"`
- `invalid contextWindow` / `invalid maxTokens`

## 6. 扩展层 `registerProvider` 的行为差异

`ModelRegistry.registerProvider(name, config)` 与 extension API 本质一致。

三类输入语义：

1. `models` 有内容
   - 清空该 provider 原有模型
   - 解析 `ProviderModelConfig[]` 并加入
   - 若有 `oauth.modifyModels` 且已认证，动态调整模型
2. 仅 `baseUrl/headers/compat/apiKey`
   - 覆盖现有模型的连接配置（不换模型列表）
3. 带 `streamSimple`
   - 注册自定义 stream（如完全自研 OpenAI 兼容层）
   - `api` 必填，否则抛错

`unregisterProvider` 会清理并触发 `refresh()`，恢复被覆盖的内置 provider。

## 7. 环境变量与动态值解析

`resolveConfigValue` / `resolveHeaders`（`core/resolve-config-value.ts`）支持：
- 形如 `!command` 的 shell 命令前缀：执行命令返回 stdout（缓存）
- 普通字符串优先按环境变量解析

这对 `apiKey`、`headers.Authorization`、自定义字段非常实用。

## 8. OAuth 与自定义 API key 的边界

- OAuth 流程通过 `pi-ai/oauth` 与 `AuthStorage` 串联。
- `ModelRegistry` 对有 OAuth 的 provider：
  - 注册时 `registerOAuthProvider`
  - 请求 token 时走 `modelRegistry.getApiKeyForProvider`

在 `createAgentSession` 的 `Agent` 初始化中，`getApiKey` 异常处理会给出重试/重登提示。

## 9. 嵌入建议

- 若是“平台集成新模型”且想保持统一路由：优先用 `pi.registerProvider(...)`。
- 若是“完全定制 API payload”：使用 `streamSimple`，并确保 `done/error` 事件语义正确。
- 禁止在上层做“吞掉 provider 报错再继续”的逻辑，统一保留事件语义。

## 10. 你应优先审阅的文件（按顺序）

1. `packages/ai/src/types.ts`
2. `packages/ai/src/stream.ts`
3. `packages/ai/src/api-registry.ts`
4. `packages/ai/src/providers/register-builtins.ts`
5. `packages/coding-agent/src/core/model-registry.ts`
6. `packages/coding-agent/src/core/resolve-config-value.ts`
