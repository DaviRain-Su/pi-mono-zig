# 设置

pi 使用 JSON 设置文件，项目设置覆盖全局设置。

| 位置 | 范围 |
|------|------|
| `~/.pi/agent/settings.json` | 全局（所有项目）|
| `.pi/settings.json` | 项目（当前目录）|

直接编辑文件或使用 `/settings` 进行常用选项配置。

## 所有设置

### 模型与思考

| 设置 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `defaultProvider` | string | - | 默认 provider（例如 `"anthropic"`、`"openai"`）|
| `defaultModel` | string | - | 默认模型 ID |
| `defaultThinkingLevel` | string | - | `"off"`、`"minimal"`、`"low"`、`"medium"`、`"high"`、`"xhigh"` |
| `hideThinkingBlock` | boolean | `false` | 隐藏输出中的思考块 |
| `thinkingBudgets` | object | - | 每个思考级别的自定义 token 预算 |

#### thinkingBudgets

```json
{
  "thinkingBudgets": {
    "minimal": 1024,
    "low": 4096,
    "medium": 10240,
    "high": 32768
  }
}
```

### UI 与显示

| 设置 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `theme` | string | `"dark"` | 主题名称（`"dark"`、`"light"` 或自定义）|
| `quietStartup` | boolean | `false` | 隐藏启动标题 |
| `collapseChangelog` | boolean | `false` | 更新后显示简洁变更日志 |
| `doubleEscapeAction` | string | `"tree"` | 双击 escape 的动作：`"tree"`、`"fork"` 或 `"none"` |
| `treeFilterMode` | string | `"default"` | `/tree` 的默认过滤器：`"default"`、`"no-tools"`、`"user-only"`、`"labeled-only"`、`"all"` |
| `editorPaddingX` | number | `0` | 输入编辑器的水平内边距（0-3）|
| `autocompleteMaxVisible` | number | `5` | 自动补全下拉菜单的最大可见项数（3-20）|
| `showHardwareCursor` | boolean | `false` | 显示终端光标 |

### 压缩

| 设置 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `compaction.enabled` | boolean | `true` | 启用自动压缩 |
| `compaction.reserveTokens` | number | `16384` | 为 LLM 响应预留的 token |
| `compaction.keepRecentTokens` | number | `20000` | 保留的近期 token（不被摘要）|

```json
{
  "compaction": {
    "enabled": true,
    "reserveTokens": 16384,
    "keepRecentTokens": 20000
  }
}
```

### 分支摘要

| 设置 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `branchSummary.reserveTokens` | number | `16384` | 分支摘要预留的 token |
| `branchSummary.skipPrompt` | boolean | `false` | 跳过 `/tree` 导航时的"摘要分支？"提示（默认不摘要）|

### 重试

| 设置 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `retry.enabled` | boolean | `true` | 启用瞬态错误的自动重试 |
| `retry.maxRetries` | number | `3` | 最大重试次数 |
| `retry.baseDelayMs` | number | `2000` | 指数退避的基础延迟（2s、4s、8s）|
| `retry.maxDelayMs` | number | `60000` | 失败前最大服务器请求延迟（60s）|

当 provider 请求的延迟超过 `maxDelayMs`（例如 Google 的"配额将在 5 小时后重置"），请求立即失败并显示信息性错误，而不是静默等待。设置为 `0` 禁用上限。

```json
{
  "retry": {
    "enabled": true,
    "maxRetries": 3,
    "baseDelayMs": 2000,
    "maxDelayMs": 60000
  }
}
```

### 消息交付

| 设置 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `steeringMode` | string | `"one-at-a-time"` | 转向消息发送方式：`"all"` 或 `"one-at-a-time"` |
| `followUpMode` | string | `"one-at-a-time"` | 跟进消息发送方式：`"all"` 或 `"one-at-a-time"` |
| `transport` | string | `"sse"` | 支持多种传输的 provider 首选传输：`"sse"`、`"websocket"` 或 `"auto"` |

### 终端与图片

| 设置 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `terminal.showImages` | boolean | `true` | 在终端中显示图片（如果支持）|
| `terminal.clearOnShrink` | boolean | `false` | 内容缩小时清除空行（可能导致闪烁）|
| `images.autoResize` | boolean | `true` | 将图片调整到最大 2000x2000 |
| `images.blockImages` | boolean | `false` | 阻止所有图片发送给 LLM |

### Shell

| 设置 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `shellPath` | string | - | 自定义 shell 路径（例如 Windows 上的 Cygwin）|
| `shellCommandPrefix` | string | - | 每个 bash 命令的前缀（例如 `"shopt -s expand_aliases"`）|
| `npmCommand` | string[] | - | 用于 npm 包查找/安装操作的命令 argv（例如 `["mise", "exec", "node@20", "--", "npm"]`）|

```json
{
  "npmCommand": ["mise", "exec", "node@20", "--", "npm"]
}
```

`npmCommand` 用于所有 npm 包管理器操作，包括 `npm root -g`、安装、卸载和 git 包内的 `npm install`。使用与进程启动方式完全相同的 argv 样式条目。

### 模型循环

| 设置 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `enabledModels` | string[] | - | Ctrl+P 循环的模型模式（与 `--models` CLI 标志格式相同）|

```json
{
  "enabledModels": ["claude-*", "gpt-4o", "gemini-2*"]
}
```

### Markdown

| 设置 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `markdown.codeBlockIndent` | string | `"  "` | 代码块的缩进 |

### 资源

这些设置定义从哪里加载扩展、技能、提示和主题。

`~/.pi/agent/settings.json` 中的路径相对于 `~/.pi/agent` 解析。`.pi/settings.json` 中的路径相对于 `.pi` 解析。支持绝对路径和 `~`。

| 设置 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `packages` | array | `[]` | 加载资源的 npm/git 包 |
| `extensions` | string[] | `[]` | 本地扩展文件路径或目录 |
| `skills` | string[] | `[]` | 本地技能文件路径或目录 |
| `prompts` | string[] | `[]` | 本地提示模板路径或目录 |
| `themes` | string[] | `[]` | 本地主题文件路径或目录 |
| `enableSkillCommands` | boolean | `true` | 将技能注册为 `/skill:name` 命令 |

数组支持 glob 模式和排除。使用 `!pattern` 排除。使用 `+path` 强制包含精确路径，使用 `-path` 强制排除精确路径。

#### packages

字符串形式从包加载所有资源：

```json
{
  "packages": ["pi-skills", "@org/my-extension"]
}
```

对象形式过滤要加载的资源：

```json
{
  "packages": [
    {
      "source": "pi-skills",
      "skills": ["brave-search", "transcribe"],
      "extensions": []
    }
  ]
}
```

详见 [packages.md](packages.md)。

## 示例

```json
{
  "defaultProvider": "anthropic",
  "defaultModel": "claude-sonnet-4-20250514",
  "defaultThinkingLevel": "medium",
  "theme": "dark",
  "compaction": {
    "enabled": true,
    "reserveTokens": 16384,
    "keepRecentTokens": 20000
  },
  "retry": {
    "enabled": true,
    "maxRetries": 3
  },
  "enabledModels": ["claude-*", "gpt-4o"],
  "packages": ["pi-skills"]
}
```

## 项目覆盖

项目设置（`.pi/settings.json`）覆盖全局设置。嵌套对象会合并：

```json
// ~/.pi/agent/settings.json（全局）
{
  "theme": "dark",
  "compaction": { "enabled": true, "reserveTokens": 16384 }
}

// .pi/settings.json（项目）
{
  "compaction": { "reserveTokens": 8192 }
}

// 结果
{
  "theme": "dark",
  "compaction": { "enabled": true, "reserveTokens": 8192 }
}
```