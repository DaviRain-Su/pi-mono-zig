# 第4章：命令与快捷键

> 所有内置命令、快捷键、设置

---

## 4.1 命令概览

在 pi 中输入 `/` 显示所有可用命令。

### 会话管理

| 命令 | 说明 | 示例 |
|-----|------|------|
| `/new` | 开始新会话 | `/new` |
| `/resume` | 选择历史会话 | `/resume` |
| `/name <name>` | 设置会话名称 | `/name project-xyz` |
| `/session` | 显示会话信息 | `/session` |
| `/tree` | 会话树导航 | `/tree` |
| `/fork` | 从当前分支创建新会话 | `/fork` |

### 模型管理

| 命令 | 说明 | 示例 |
|-----|------|------|
| `/model` | 切换模型 | `/model` |
| `/scoped-models` | 设置可循环模型 | `/scoped-models` |

### 系统设置

| 命令 | 说明 | 示例 |
|-----|------|------|
| `/settings` | 打开设置 | `/settings` |
| `/login` | 登录 provider | `/login` |
| `/logout` | 登出 | `/logout` |
| `/reload` | 重新加载扩展 | `/reload` |
| `/hotkeys` | 显示快捷键 | `/hotkeys` |

### 上下文管理

| 命令 | 说明 | 示例 |
|-----|------|------|
| `/compact` | 压缩会话 | `/compact` |
| `/copy` | 复制最后回复 | `/copy` |
| `/export` | 导出会话 | `/export output.html` |
| `/import` | 导入 JSONL 会话 | `/import ~/.pi/agent/sessions/abc123.jsonl` |
| `/share` | 分享到 gist | `/share` |

### 其他

| 命令 | 说明 | 示例 |
|-----|------|------|
| `/changelog` | 显示更新日志 | `/changelog` |
| `/quit` | 退出 | `/quit` |

---

## 4.2 快捷键

### 全局快捷键

| 快捷键 | 功能 |
|-------|------|
| `Ctrl+C` | 清除输入 / 取消当前操作 |
| `Ctrl+C` (两次) | 退出 pi |
| `Escape` | 取消 / 返回 |
| `Escape` (两次) | 打开 `/tree` |

### 模型相关

| 快捷键 | 功能 |
|-------|------|
| `Ctrl+L` | 打开模型选择器 |
| `Ctrl+P` | 循环到下一个模型 |
| `Shift+Ctrl+P` | 循环到上一个模型 |
| `Shift+Tab` | 循环思考级别 |

### 工具相关

| 快捷键 | 功能 |
|-------|------|
| `Ctrl+O` | 展开/折叠工具输出 |
| `Ctrl+T` | 展开/折叠思考块 |

### 输入相关

| 快捷键 | 功能 |
|-------|------|
| `Enter` | 发送消息 |
| `Shift+Enter` | 换行 |
| `Tab` | 补全路径 |
| `Ctrl+V` | 粘贴图片 |
| `Ctrl+A` | 全选 |
| `Ctrl+G` | 打开外部编辑器 |

### 导航相关

| 快捷键 | 功能 |
|-------|------|
| `Ctrl+↑/↓` | 浏览历史消息 |
| `PageUp/PageDown` | 滚动消息区域 |
| `Home/End` | 跳到输入框开头/结尾 |

---

## 4.3 设置详解

### 设置文件位置

- **全局**: `~/.pi/agent/settings.json`
- **项目**: `.pi/settings.json` (覆盖全局)

### 常用设置

```json
{
  "defaultProvider": "anthropic",
  "defaultModel": "claude-sonnet-4",
  "defaultThinkingLevel": "medium",
  "steeringMode": "one-at-a-time",
  "followUpMode": "one-at-a-time",
  "compaction": {
    "enabled": true,
    "reserveTokens": 16384,
    "keepRecentTokens": 20000
  }
}
```

### 设置项说明

| 设置项 | 类型 | 说明 |
|-------|------|------|
| `defaultProvider` | string | 默认 provider |
| `defaultModel` | string | 默认模型 |
| `defaultThinkingLevel` | string | 默认思考级别 (off/minimal/low/medium/high/xhigh) |
| `compaction.enabled` | boolean | 自动压缩是否开启 |
| `compaction.reserveTokens` | number | 压缩时保留的上下文 token |
| `compaction.keepRecentTokens` | number | 需要保留的最近消息 token |
| `steeringMode` | string | steering 消息模式 (one-at-a-time/all) |
| `followUpMode` | string | follow-up 消息模式 (one-at-a-time/all) |
| `enableSkillCommands` | boolean | 启用 skill 命令 |
| `blockImages` | boolean | 阻止图片输入 |
| `theme` | string | 主题名称 |

---

## 4.4 自定义快捷键

### 配置文件

编辑 `~/.pi/agent/keybindings.json`：

```json
{
  "app.model.select": "ctrl+m",
  "app.tools.expand": "ctrl+e",
  "custom.mycommand": "ctrl+shift+x"
}
```

### 可用 keybinding ID

参考 `packages/coding-agent/docs/keybindings.md` 获取完整列表。

---

## 4.5 命令行选项

### 启动选项

```bash
pi [options] [@files...] [messages...]

Options:
  -c, --continue                  继续最近的会话
  -r, --resume                    选择历史会话
  --provider <name>                Provider 名称（默认 google）
  --model <pattern>                模型名或模式（支持 provider/id）
  --api-key <key>                  Provider API Key（或使用环境变量）
  --system-prompt <text>           系统提示词
  --append-system-prompt <text>    追加系统提示词（用于测试）
  --mode <mode>                    输出模式: text（默认）, json, rpc
  --print, -p                      非交互模式，执行后退出
  --no-session                     不保存会话（临时模式）
  --session <path>                 指定会话文件
  --fork <path>                    从会话分叉
  --session-dir <dir>              会话目录
  --models <patterns>              Ctrl+P 循环模型白名单（逗号分隔）
  --no-tools                       禁用内置工具
  --tools <tools>                  指定启用工具（read,bash,edit,write,grep,find,ls）
  --thinking <level>               思考级别: off/minimal/low/medium/high/xhigh
  --extension, -e <path>           加载额外扩展（可重复）
  --no-extensions, -ne            禁用扩展自动发现（-e 仍可用）
  --skill <path>                   加载 skill 文件或目录
  --prompt-template <path>         加载 prompt template（可重复）
  --no-skills, -ns                 禁用 skills
  --no-prompt-templates, -np       禁用 prompt template
  --theme <path>                   加载主题（可重复）
  --no-themes                      禁用主题自动发现
  --export <file>                  导出会话到 HTML 后退出
  --list-models [search]           列出可用模型
  --verbose                        打开详细日志
  --offline                        禁止启动时网络请求（设置 PI_OFFLINE=1）
  --help, -h                       显示帮助
  --version, -v                    显示版本号
```

### 示例

```bash
# 继续会话
pi -c

# 从特定会话分叉
pi --fork ~/.pi/agent/sessions/abc123.jsonl

# 临时模式，指定模型
pi --no-session --model claude-opus-4

# 加载额外扩展
pi --extension ./my-extension
```

---

## 4.6 实用技巧

### 快速切换模型

```
Ctrl+L          # 打开模型选择器
Ctrl+P          # 快速循环
```

### 消息队列

```
Enter           # 发送 steering 消息（当前轮次后插入）
Alt+Enter       # 发送 follow-up 消息（所有完成后插入）
```

### 文件引用

```
@               # 触发文件补全
@src/           # 补全 src 目录下的文件
Tab             # 确认补全
```

### Bash 快捷执行

```
!ls -la         # 执行并发送结果到上下文
!!ls -la        # 执行但不发送结果
```

---

## 本章小结

- **命令**: `/` 开头，Tab 补全
- **快捷键**: Ctrl/Shift 组合，可自定义
- **设置**: JSON 配置，全局或项目级
- **启动选项**: 灵活控制会话和行为
