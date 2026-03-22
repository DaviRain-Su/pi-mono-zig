# 第3章：第一个小时

> 安装、配置、基本使用

---

## 3.1 系统要求

### 必需

- **Node.js**: >= 20.0.0
- **操作系统**: macOS、Linux、或 Windows (WSL2)
- **Chrome 浏览器**: 用于需要登录的网站（可选但推荐）

### 推荐

- **Git**: 用于代码版本控制
- **VS Code**: 推荐的编辑器，配合 pi 使用
- **终端**: iTerm2 (macOS)、Windows Terminal (Windows)、或 GNOME Terminal (Linux)

---

## 3.2 安装

### 全局安装（推荐）

```bash
npm install -g @mariozechner/pi-coding-agent
```

### 验证安装

```bash
pi --version
# 输出类似: 0.12.0
```

### 更新

```bash
npm update -g @mariozechner/pi-coding-agent
```

### 卸载

```bash
npm uninstall -g @mariozechner/pi-coding-agent
```

---

## 3.3 首次配置

### 方式一：环境变量（推荐）

在你的 shell 配置文件（`~/.zshrc` 或 `~/.bashrc`）中添加：

```bash
# Anthropic Claude
export ANTHROPIC_API_KEY=sk-ant-api03-...

# 或 OpenAI
export OPENAI_API_KEY=sk-...

# 或 Google Gemini
export GOOGLE_API_KEY=...
```

然后重新加载配置：

```bash
source ~/.zshrc  # 或 ~/.bashrc
```

### 方式二：使用 /login 命令

```bash
pi
```

在 pi 中输入：

```
/login
```

选择 provider，按提示操作：

```
? Select provider: (Use arrow keys)
❯ anthropic 
  openai 
  google 
  github-copilot 
  ...
```

### 方式三：配置文件

创建 `~/.pi/agent/settings.json`：

```json
{
  "defaultProvider": "anthropic",
  "defaultModel": "claude-sonnet-4"
}
```

---

## 3.4 启动 pi

### 基本启动

```bash
# 在当前目录启动
pi

# 指定目录启动
pi /path/to/project

# 继续上次会话
pi -c

# 选择历史会话
pi -r
```

### 启动选项

| 选项 | 说明 |
|-----|------|
| `-c, --continue` | 继续最近的会话 |
| `-r, --resume` | 选择历史会话 |
| `--no-session` | 不保存会话（临时模式） |
| `--session <path>` | 指定会话文件 |
| `--fork <path>` | 从会话分叉 |
| `--model <model>` | 指定模型 |
| `--extension <path>` | 加载额外扩展 |

---

## 3.5 界面导览

### 启动界面

```
┌─────────────────────────────────────────────────────────┐
│  pi 0.12.0                                         │
│  ─────────────────────────────────────────────────────  │
│  AGENTS.md: 3 loaded                                      │
│  Extensions: 5 loaded                                     │
│  Skills: 12 available                                     │
│  Prompts: 3 available                                     │
│  ─────────────────────────────────────────────────────  │
│  Hotkeys: Ctrl+L=model  Ctrl+P=cycle  Ctrl+O=expand     │
│  Commands: /new /resume /tree /fork /quit              │
└─────────────────────────────────────────────────────────┘
```

### 消息区域

显示对话历史：
- 用户消息（白色）
- 助手消息（绿色）
- 工具调用（蓝色）
- 工具结果（灰色）
- 系统通知（黄色）

### 输入框

底部输入区域：
- 显示当前工作目录
- 边框颜色表示思考级别（灰色=off，蓝色=low，紫色=medium，红色=high）
- 输入 `/` 显示命令补全
- 输入 `@` 显示文件补全

### 状态栏

```
~/projects/my-app  |  session: abc123  |  12k/200k tokens  |  $0.023  |  claude-sonnet-4
```

显示：
- 当前目录
- 会话ID
- Token 使用量 / 上下文窗口
- 当前成本
- 当前模型

---

## 3.6 基本交互

### 发送消息

1. 在输入框输入你的需求
2. 按 `Enter` 发送
3. 等待 Agent 响应

示例：

```
> 帮我创建一个 React 组件，显示用户列表
```

### 多行输入

按 `Shift+Enter` 换行：

```
> 帮我创建一个函数，要求：
  1. 接受用户ID参数
  2. 查询数据库
  3. 返回用户信息
```

### 引用文件

输入 `@` 触发文件补全：

```
> 请解释 @src/components/Button.tsx 的作用
```

### 执行 Bash 命令

在消息中输入 `!` 执行命令：

```
> 查看当前目录结构 !ls -la
```

或在输入框直接输入：

```
> !npm test
```

---

## 3.7 第一个任务

让我们完成一个完整任务：创建一个待办事项应用。

### 步骤1：创建项目

```
> 帮我创建一个待办事项应用，使用 React + TypeScript
```

Agent 会：
1. 检查当前目录
2. 创建项目结构
3. 初始化 package.json
4. 安装依赖
5. 创建组件文件

### 步骤2：查看结果

```
> 显示项目结构 !tree -L 2
```

### 步骤3：运行应用

```
> 启动开发服务器 !npm run dev
```

### 步骤4：迭代改进

```
> 给待办事项添加完成状态切换功能
```

---

## 3.8 保存和退出

### 保存会话

会话自动保存到 `~/.pi/agent/sessions/`。

### 退出

```
/quit
```

或按 `Ctrl+C` 两次。

### 继续会话

```bash
# 继续最近的会话
pi -c

# 选择历史会话
pi -r
```

---

## 3.9 常见问题

### Q: 安装失败怎么办？

```bash
# 检查 Node.js 版本
node --version  # 需要 >= 20.0.0

# 清理 npm 缓存
npm cache clean --force

# 使用 npx 临时运行
npx @mariozechner/pi-coding-agent
```

### Q: API Key 无效？

- 检查环境变量是否正确设置
- 确认 key 没有过期
- 检查是否有足够的额度

### Q: 启动后没有响应？

- 检查网络连接
- 查看 `~/.pi/agent/logs/` 中的日志
- 尝试 `--no-session` 临时模式

### Q: 如何更新到最新版本？

```bash
npm update -g @mariozechner/pi-coding-agent
```

---

## 3.10 下一步

- 学习所有命令：[第4章：命令与快捷键](./04-commands.md)
- 理解会话管理：[第5章：会话管理](./05-sessions.md)
- 开始使用 Skill：[第6章：Skill 系统](./06-skills.md)

---

## 本章小结

- **安装**: `npm install -g @mariozechner/pi-coding-agent`
- **配置**: 环境变量或 `/login`
- **启动**: `pi` 或 `pi /path/to/project`
- **界面**: 消息区、输入框、状态栏
- **交互**: 发送消息、引用文件、执行命令
