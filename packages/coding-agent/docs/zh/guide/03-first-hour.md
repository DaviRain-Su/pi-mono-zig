# 第3章：第一个小时

> 安装、认证、启动与第一轮交互。

---

## 3.1 系统要求

### 必需

- **Node.js**：>= 20
- **操作系统**：macOS、Linux、或 Windows（建议 WSL2）

### 推荐

- **现代终端**：iTerm2、Ghostty、Kitty、Windows Terminal、WezTerm 等
- **Git**：用于版本管理
- **Chrome 或默认浏览器**：用于 `/login` 打开 OAuth 页面

平台细节可继续看：

- [Windows](../platform/windows.md)
- [Termux](../platform/termux.md)
- [tmux](../platform/tmux.md)
- [终端设置](../platform/terminal-setup.md)

---

## 3.2 安装

### 全局安装

```bash
npm install -g @mariozechner/pi-coding-agent
```

### 验证安装

```bash
pi --version
```

### 更新

```bash
npm update -g @mariozechner/pi-coding-agent
```

### 卸载

```bash
npm uninstall -g @mariozechner/pi-coding-agent
```

如果你只想临时试用，也可以：

```bash
npx @mariozechner/pi-coding-agent
```

---

## 3.3 首次认证与配置

pi 支持两种主流认证方式：

- **API key**
- **订阅 / OAuth 登录**（通过 `/login`）

### 方式一：环境变量

在 shell 配置文件中添加 API key，例如：

```bash
# Anthropic
export ANTHROPIC_API_KEY=sk-ant-...

# OpenAI
export OPENAI_API_KEY=sk-...

# Google Gemini
export GEMINI_API_KEY=...
```

然后重新加载 shell：

```bash
source ~/.zshrc
```

或：

```bash
source ~/.bashrc
```

### 方式二：使用 `/login`

```bash
pi
```

进入交互界面后输入：

```text
/login
```

当前内置订阅 / OAuth 路线主要包括：

- Anthropic Claude Pro / Max
- OpenAI ChatGPT Plus / Pro（Codex）
- GitHub Copilot
- Google Gemini CLI
- Google Antigravity

### 方式三：配置默认模型

创建或编辑：

- `~/.pi/agent/settings.json`

示例：

```json
{
  "defaultProvider": "anthropic",
  "defaultModel": "claude-sonnet-4"
}
```

更完整的 provider 设置见：

- [Provider 参考](../reference/providers.md)
- [模型参考](../reference/models.md)

---

## 3.4 启动 pi

### 最常见的启动方式

```bash
# 在当前目录启动
pi

# 指定 provider / model
pi --provider anthropic --model claude-sonnet-4

# 继续最近会话
pi -c

# 选择历史会话
pi -r

# 不保存会话
pi --no-session

# 非交互执行
pi -p "summarize this repository"

# RPC 模式
pi --mode rpc
```

### 常用参数

| 参数 | 说明 |
|------|------|
| `-c, --continue` | 继续最近会话 |
| `-r, --resume` | 选择历史会话 |
| `--no-session` | 临时模式，不保存会话 |
| `--session <path>` | 使用指定会话文件 |
| `--fork <path|id>` | 从已有会话分叉 |
| `--provider <name>` | 指定 provider |
| `--model <pattern>` | 指定模型或模型模式 |
| `--thinking <level>` | 设置 thinking level |
| `--mode rpc` | RPC 模式 |
| `--print, -p` | 非交互模式 |
| `--extension <path>` | 临时加载扩展 |

完整参数以这些来源为准：

- `pi --help`
- `packages/coding-agent/README.md`
- `packages/coding-agent/src/cli/args.ts`

---

## 3.5 界面导览

pi 的交互界面从上到下通常包括：

### 启动头部

显示：

- 常用快捷键提示
- 已加载的 `AGENTS.md`
- prompt templates
- skills
- extensions

### 消息区

这里会显示：

- 用户消息
- 助手回复
- 工具调用与工具结果
- 通知与错误
- 扩展 UI

### 编辑器

你在这里输入消息。

常见能力：

- 输入 `/`：命令补全
- 输入 `@`：项目文件引用
- `Shift+Enter`：换行
- `Ctrl+V`：粘贴图片（Windows 终端常见为 `Alt+V`）
- 边框颜色会反映当前 thinking level

### 页脚

页脚通常显示：

- 当前工作目录
- 会话名
- 总 token / cache 使用量
- 成本
- context 使用情况
- 当前模型

如果安装了扩展，编辑器、页脚、widget 和 overlay 也可能被扩展接管或增强。

---

## 3.6 基本交互

### 发送消息

直接输入自然语言，然后按 `Enter`：

```text
> 帮我总结这个仓库的结构
```

### 多行输入

按 `Shift+Enter`：

```text
> 帮我创建一个函数，要求：
  1. 接收用户 ID
  2. 查询数据库
  3. 返回用户信息
```

### 引用文件

输入 `@` 触发文件补全：

```text
> 请解释 @src/components/Button.tsx 的作用
```

### 执行 Bash 命令

pi 支持两种命令前缀：

- `!command`：执行命令，并把输出发送给 LLM
- `!!command`：执行命令，但**不**把输出发送给 LLM

例如：

```text
> !ls -la
```

```text
> !!git status
```

这两种方式非常适合：

- 快速把目录结构送进上下文
- 先本地确认状态，再决定是否让模型看到输出

---

## 3.7 第一个任务

下面用一个保守、现实的例子熟悉基本流程。

### 步骤 1：让 pi 先理解仓库

```text
> 先阅读这个项目的 README，并总结目录结构
```

### 步骤 2：引用具体文件继续问

```text
> 请结合 @package.json 和 @src/index.ts 解释启动入口
```

### 步骤 3：让 pi 做一个小修改

```text
> 帮我把这个函数拆成两个更小的函数，并保持行为不变
```

### 步骤 4：继续追问

```text
> 解释你刚才为什么这样拆分，并列出潜在风险
```

这个顺序比“一上来就让它搭完整应用”更适合第一小时，因为你能更快建立：

- 消息输入习惯
- 文件引用习惯
- 命令与工具调用的心智模型
- 会话连续追问的感觉

---

## 3.8 会话与退出

### 会话保存

默认情况下，会话会自动保存到：

- `~/.pi/agent/sessions/`

### 退出

可以使用：

```text
/quit
```

或：

- `Ctrl+C` 清空编辑器
- `Ctrl+C` 连按两次退出

### 继续会话

```bash
pi -c
pi -r
```

如果你不想保存当前过程，可以从一开始就用：

```bash
pi --no-session
```

---

## 3.9 常见问题

### Q: 安装失败怎么办？

```bash
node --version
```

确认 Node.js 版本至少为 20。

如果只是快速试用，可以改用：

```bash
npx @mariozechner/pi-coding-agent
```

### Q: API key 设置了，但仍不可用？

先检查：

- 环境变量名是否正确
- shell 是否已重新加载
- 当前 provider 是否真的使用该 key

可进一步参考：

- [Provider 参考](../reference/providers.md)
- [故障排查](./12-troubleshooting.md)

### Q: `/login` 没有我想要的 provider？

不是所有 provider 都走 OAuth。很多 provider 只支持 API key。

### Q: 启动后没反应或很慢？

优先检查：

- 网络连接
- provider 认证状态
- 当前模型是否可用
- 是否在一个很大的仓库里启动

必要时可试：

```bash
pi --no-session
```

或：

```bash
pi --verbose
```

---

## 3.10 下一步

继续阅读：

- [第4章：命令与快捷键](./04-commands.md)
- [第5章：会话管理](./05-sessions.md)
- [第6章：Skill 系统](./06-skills.md)
- [第9章：扩展 API](./09-extension-api.md)

---

## 本章小结

- 安装：`npm install -g @mariozechner/pi-coding-agent`
- 认证：环境变量或 `/login`
- 启动：`pi`、`pi -c`、`pi -r`、`pi -p`
- 基本交互：消息、文件引用、命令前缀 `!` / `!!`
- 第一小时重点：先学会与现有项目协作，而不是追求一次性完成大任务
