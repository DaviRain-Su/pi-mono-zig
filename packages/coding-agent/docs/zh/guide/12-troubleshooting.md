# 故障排查指南

> 常见问题与优先排查路径。

这篇文档只保留与当前 `pi-mono` 文档和实现比较一致的排查建议，避免把未验证的 CLI 选项、配置文件路径或调试命令写进中文指南。

---

## 1. 启动前先检查什么

遇到问题时，优先先确认这四类信息：

1. 当前使用的是哪个安装/运行方式
   - 全局安装的 `pi`
   - `npx @mariozechner/pi-coding-agent`
   - 仓库内 `./pi-test.sh`
2. 当前终端类型
   - Ghostty / Kitty / WezTerm / iTerm2 / VS Code terminal / tmux
3. 当前 API key 是否存在
4. 当前问题属于哪一类
   - 安装问题
   - 启动问题
   - 模型 / provider 问题
   - 扩展问题
   - 会话 / TUI / 终端问题

---

## 2. 安装与命令问题

### 2.1 `pi` 命令找不到

先确认命令是否存在：

```bash
command -v pi
```

如果没有结果，可按你的使用方式排查：

#### 方式 A：全局安装
```bash
npm install -g @mariozechner/pi-coding-agent
command -v pi
```

#### 方式 B：直接用 npx
```bash
npx @mariozechner/pi-coding-agent
```

#### 方式 C：从源码运行
在仓库根目录执行：
```bash
./pi-test.sh
```

### 2.2 全局安装失败

先检查 Node 版本：

```bash
node --version
```

如果怀疑是 npm 或权限问题，可优先使用：

```bash
npx @mariozechner/pi-coding-agent
```

这样通常可以绕过全局安装权限问题。

---

## 3. Provider / API key 问题

### 3.1 找不到 API key

常见表现：
- provider 初始化失败
- 启动后无法请求模型
- 提示没有找到对应 provider 的凭据

先检查环境变量是否存在，例如：

```bash
echo $ANTHROPIC_API_KEY
echo $OPENAI_API_KEY
echo $GOOGLE_API_KEY
```

如果为空，就需要在 shell 配置文件中补上对应变量。

### 3.2 API key 无效

常见表现：
- 401 Unauthorized
- provider 返回认证失败

处理方式：
- 确认 key 没有多余空格或换行
- 确认当前 shell 已重新加载配置
- 确认 provider 与 key 类型匹配

---

## 4. 模型与 provider 问题

### 4.1 指定模型后无法工作

先确认你传入的是正确的 provider / model 组合，例如：

```bash
pi --provider anthropic --model claude-sonnet-4-20250514
```

如果你使用的是简写模型名，也可以先改成完整模型 ID 再试一次。

### 4.2 thinking level 行为不符合预期

先检查是否显式设置了 thinking level：

```bash
pi --thinking medium
```

并确认当前文档中支持的 thinking level 为：
- `off`
- `minimal`
- `low`
- `medium`
- `high`
- `xhigh`

---

## 5. 会话问题

### 5.1 `/resume` 看不到想要的会话

先确认你是不是在同一个环境中运行：
- 同一个用户
- 同一个配置目录
- 同一种运行方式

会话文件通常位于 `~/.pi/agent/` 目录下的会话存储位置。可以先查看是否真的存在会话文件：

```bash
ls -la ~/.pi/agent/
```

### 5.2 会话过大或上下文变乱

优先使用内置命令，而不是手动改会话文件：

```text
/compact
/fork
/new
/tree
```

推荐排查顺序：
1. 先 `/compact`
2. 如果上下文仍混乱，改用 `/fork`
3. 如果这次任务和当前会话无关，直接 `/new`

---

## 6. 扩展问题

### 6.1 扩展不生效

优先检查：
- 扩展文件路径是否正确
- 扩展是否被 settings / CLI 正确加载
- TypeScript / JavaScript 语法是否有问题

如果你在交互模式中修改了扩展，先尝试：

```text
/reload
```

### 6.2 工具调用异常

先区分是哪一层出错：
- 工具根本没注册成功
- 工具注册成功，但 LLM 没调用
- 工具被调用了，但执行报错

建议排查：
1. 看扩展注册代码是否执行
2. 看工具 `name`、`description`、`parameters` 是否足够清晰
3. 看执行阶段是否抛出了异常

如果需要写更细的扩展排查说明，优先参考：
- `../reference/extensions.md`
- `../guide/09-extension-api.md`

---

## 7. 终端 / TUI 问题

### 7.1 快捷键不工作

先不要急着怀疑 pi 本身，优先检查终端：
- 是否支持 Kitty keyboard protocol
- 是否被 tmux / VS Code terminal / Windows Terminal 拦截
- 是否有自定义终端映射覆盖了按键

优先参考：
- `../platform/terminal-setup.md`
- `../platform/tmux.md`
- `../reference/keybindings.md`

### 7.2 `Shift+Enter` / `Alt+Enter` 行为异常

这是最常见的终端兼容问题之一。

建议：
1. 先查终端配置
2. 再查是否有 tmux
3. 最后再查 pi 键绑定

### 7.3 TUI 显示异常或重绘问题

先缩小问题范围：
- 换一个终端试试
- 退出 tmux 再试一次
- 在同一台机器上用 `./pi-test.sh` 对照验证

如果不同终端表现不同，通常不是 agent 核心逻辑问题，而是终端能力差异。

---

## 8. 开发与源码运行问题

### 8.1 从源码运行时报错

先确认你在仓库根目录，并且依赖已经安装：

```bash
npm install
./pi-test.sh
```

如果是开发流程相关问题，优先参考：
- `../../../AGENTS.md`
- `./11-development.md`

### 8.2 改完代码后怎么做基本检查

按照仓库规则，代码改动后优先运行：

```bash
npm run check
```

不要默认运行：
- `npm run build`
- `npm test`

除非你有明确理由，并且符合仓库当前开发规则。

---

## 9. 性能与上下文问题

### 9.1 感觉响应慢

先区分慢在哪里：
- 模型本身响应慢
- 上下文太大
- 工具执行慢
- 网络慢

通用处理方式：
1. 先 `/compact`
2. 必要时 `/new` 或 `/fork`
3. 改用更快的模型
4. 检查网络与 provider 状态

### 9.2 上下文越来越难控制

这是正常现象，不一定是 bug。

建议把这些命令当成常规工具：
- `/compact`
- `/fork`
- `/tree`
- `/resume`

---

## 10. 最实用的排查方法

如果你不确定问题在哪，最稳妥的顺序是：

1. **换最小环境重试**
   - 新开一个终端
   - 不进 tmux
   - 不加载复杂扩展
   - 从仓库根目录 `./pi-test.sh` 跑

2. **缩小变量**
   - 只保留一个 provider
   - 只保留一个简单 prompt
   - 暂时不加载自定义扩展

3. **区分是哪一层的问题**
   - 终端层
   - 配置层
   - provider / model 层
   - extension 层
   - session / context 层

很多问题只要做到这三步，就能快速定位。

---

## 11. 获取帮助时建议附带的信息

如果需要在 issue 或讨论中反馈问题，建议附带：

- pi 版本
- Node.js 版本
- 操作系统
- 终端类型
- 是否使用 tmux / Ghostty / VS Code terminal
- 使用的是源码运行、npx 还是全局安装
- 复现步骤
- 期望行为
- 实际行为
- 相关错误输出

---

## 12. 一句话总结

**排查 pi 问题时，最重要的不是马上去改配置文件，而是先区分问题是在终端、provider、扩展、会话还是源码运行层；先用最小环境复现，再按层缩小范围，通常比堆命令更有效。**
