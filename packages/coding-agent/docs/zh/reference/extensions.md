
## 示例参考

所有示例在 [examples/extensions/](../examples/extensions/)。

| 示例 | 说明 | 关键 API |
|---------|-------------|----------|
| **工具** |||
| `hello.ts` | 最小工具注册 | `registerTool` |
| `question.ts` | 带用户交互的工具 | `registerTool`, `ui.select` |
| `questionnaire.ts` | 多步向导工具 | `registerTool`, `ui.custom` |
| `todo.ts` | 带持久化的有状态工具 | `registerTool`, `appendEntry`, `renderResult`, 会话事件 |
| `dynamic-tools.ts` | 启动后和命令期间注册工具 | `registerTool`, `session_start`, `registerCommand` |
| `truncated-tool.ts` | 输出截断示例 | `registerTool`, `truncateHead` |
| `tool-override.ts` | 覆盖内置 read 工具 | `registerTool`（与内置同名） |
| **命令** |||
| `pirate.ts` | 每轮修改系统提示 | `registerCommand`, `before_agent_start` |
| `summarize.ts` | 对话摘要命令 | `registerCommand`, `ui.custom` |
| `handoff.ts` | 跨 provider 模型切换 | `registerCommand`, `ui.editor`, `ui.custom` |
| `qna.ts` | 带自定义 UI 的问答 | `registerCommand`, `ui.custom`, `setEditorText` |
| `send-user-message.ts` | 注入用户消息 | `registerCommand`, `sendUserMessage` |
| `reload-runtime.ts` | 重载命令和 LLM 工具切换 | `registerCommand`, `ctx.reload()`, `sendUserMessage` |
| `shutdown-command.ts` | 优雅关闭命令 | `registerCommand`, `shutdown()` |
| **事件与门控** |||
| `permission-gate.ts` | 阻止危险命令 | `on("tool_call")`, `ui.confirm` |
| `protected-paths.ts` | 阻止写入特定路径 | `on("tool_call")` |
| `confirm-destructive.ts` | 确认会话更改 | `on("session_before_switch")`, `on("session_before_fork")` |
| `dirty-repo-guard.ts` | 脏 git 仓库时警告 | `on("session_before_*")`, `exec` |
| `input-transform.ts` | 转换用户输入 | `on("input")` |
| `model-status.ts` | 响应模型更改 | `on("model_select")`, `setStatus` |
| `provider-payload.ts` | 检查或修补 provider payload | `on("before_provider_request")` |
| `system-prompt-header.ts` | 显示系统提示信息 | `on("agent_start")`, `getSystemPrompt` |
| `claude-rules.ts` | 从文件加载规则 | `on("session_start")`, `on("before_agent_start")` |
| `file-trigger.ts` | 文件监视器触发消息 | `sendMessage` |
| **压缩与会话** |||
| `custom-compaction.ts` | 自定义压缩摘要 | `on("session_before_compact")` |
| `trigger-compact.ts` | 手动触发压缩 | `compact()` |
| `git-checkpoint.ts` | 轮次时 git stash | `on("turn_end")`, `on("session_fork")`, `exec` |
| `auto-commit-on-exit.ts` | 退出时提交 | `on("session_shutdown")`, `exec` |
| **UI 组件** |||
| `status-line.ts` | 页脚状态指示器 | `setStatus`, 会话事件 |
| `custom-footer.ts` | 完全替换页脚 | `registerCommand`, `setFooter` |
| `custom-header.ts` | 替换启动标题 | `on("session_start")`, `setHeader` |
| `modal-editor.ts` | Vim 风格模态编辑器 | `setEditorComponent`, `CustomEditor` |
| `rainbow-editor.ts` | 自定义编辑器样式 | `setEditorComponent` |
| `widget-placement.ts` | 编辑器上方/下方的小部件 | `setWidget` |
| `overlay-test.ts` | 覆盖组件 | `ui.custom` with overlay options |
| `overlay-qa-tests.ts` | 全面覆盖测试 | `ui.custom`, 所有覆盖选项 |
| `notify.ts` | 简单通知 | `ui.notify` |
| `timed-confirm.ts` | 带超时的对话框 | `ui.confirm` with timeout/signal |
| `mac-system-theme.ts` | 自动切换主题 | `setTheme`, `exec` |
| **复杂扩展** |||
| `plan-mode/` | 完整计划模式实现 | 所有事件类型, `registerCommand`, `registerShortcut`, `registerFlag`, `setStatus`, `setWidget`, `sendMessage`, `setActiveTools` |
| `preset.ts` | 可保存预设（模型、工具、思考） | `registerCommand`, `registerShortcut`, `registerFlag`, `setModel`, `setActiveTools`, `setThinkingLevel`, `appendEntry` |
| `tools.ts` | 切换工具开关 UI | `registerCommand`, `setActiveTools`, `SettingsList`, 会话事件 |
| **远程与沙盒** |||
| `ssh.ts` | SSH 远程执行 | `registerFlag`, `on("user_bash")`, `on("before_agent_start")`, 工具操作 |
| `interactive-shell.ts` | 持久 shell 会话 | `on("user_bash")` |
| `sandbox/` | 沙盒工具执行 | 工具操作 |
| `subagent/` | 生成子 agent | `registerTool`, `exec` |
| **游戏** |||
| `snake.ts` | 贪吃蛇游戏 | `registerCommand`, `ui.custom`, 键盘处理 |
| `space-invaders.ts` | 太空侵略者游戏 | `registerCommand`, `ui.custom` |
| `doom-overlay/` | 覆盖中的 Doom | `ui.custom` with overlay |
| **Providers** |||
| `custom-provider-anthropic/` | 自定义 Anthropic 代理 | `registerProvider` |
| `custom-provider-gitlab-duo/` | GitLab Duo 集成 | `registerProvider` with OAuth |
| **消息与通信** |||
| `message-renderer.ts` | 自定义消息渲染 | `registerMessageRenderer`, `sendMessage` |
| `event-bus.ts` | 扩展间事件 | `pi.events` |
| **会话元数据** |||
| `session-name.ts` | 为选择器命名会话 | `setSessionName`, `getSessionName` |
| `bookmark.ts` | 为 /tree 添加书签条目 | `setLabel` |
| **杂项** |||
| `antigravity-image-gen.ts` | 图像生成工具 | `registerTool`, Google Antigravity |
| `inline-bash.ts` | 工具调用中的内联 bash | `on("tool_call")` |
| `bash-spawn-hook.ts` | 执行前调整 bash 命令、cwd 和环境 | `createBashTool`, `spawnHook` |
| `with-deps/` | 带 npm 依赖的扩展 | 带 `package.json` 的包结构 |
