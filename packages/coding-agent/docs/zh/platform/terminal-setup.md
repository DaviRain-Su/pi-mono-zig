# 终端配置

pi 使用 [Kitty 键盘协议](https://sw.kovidgoyal.net/kitty/keyboard-protocol/) 来可靠地检测修饰键。大多数现代终端都支持此协议，但有些需要配置。

## Kitty、iTerm2

开箱即用，无需配置。

## Ghostty

添加到 Ghostty 配置文件（macOS：`~/Library/Application Support/com.mitchellh.ghostty/config`，Linux：`~/.config/ghostty/config`）：

```
keybind = alt+backspace=text:\x1b\x7f
```

旧版 Claude Code 可能添加过这个 Ghostty 映射：

```
keybind = shift+enter=text:\n
```

该映射发送原始换行符。在 pi 内部，这与 `Ctrl+J` 无法区分，因此 tmux 和 pi 不再看到真正的 `shift+enter` 键事件。

如果你添加该映射只是为了 Claude Code 2.x 或更新版本，可以删除它——除非你想在 tmux 中使用 Claude Code，它仍然需要那个 Ghostty 映射。

如果你想让 `Shift+Enter` 通过该重映射在 tmux 中继续工作，在 `~/.pi/agent/keybindings.json` 中添加 `ctrl+j` 到 `newLine` 绑定：

```json
{
  "newLine": ["shift+enter", "ctrl+j"]
}
```

## WezTerm

创建 `~/.wezterm.lua`：

```lua
local wezterm = require 'wezterm'
local config = wezterm.config_builder()
config.enable_kitty_keyboard = true
return config
```

## VS Code（集成终端）

`keybindings.json` 位置：
- macOS：`~/Library/Application Support/Code/User/keybindings.json`
- Linux：`~/.config/Code/User/keybindings.json`
- Windows：`%APPDATA%\Code\User\keybindings.json`

添加到 `keybindings.json` 以启用多行输入的 `Shift+Enter`：

```json
{
  "key": "shift+enter",
  "command": "workbench.action.terminal.sendSequence",
  "args": { "text": "\u001b[13;2u" },
  "when": "terminalFocus"
}
```

## Windows Terminal

添加到 `settings.json`（Ctrl+Shift+, 或 设置 → 打开 JSON 文件），转发 pi 使用的修饰 Enter 键：

```json
{
  "actions": [
    {
      "command": { "action": "sendInput", "input": "\u001b[13;2u" },
      "keys": "shift+enter"
    },
    {
      "command": { "action": "sendInput", "input": "\u001b[13;3u" },
      "keys": "alt+enter"
    }
  ]
}
```

- `Shift+Enter` 插入新行
- Windows Terminal 默认将 `Alt+Enter` 绑定到全屏。这会阻止 pi 接收到用于跟进队列的 `Alt+Enter`
- 重映射 `Alt+Enter` 为 `sendInput` 会将真实的键序列转发给 pi

如果已有 `actions` 数组，将对象添加到其中。如果旧的全屏行为仍然存在，完全关闭并重新打开 Windows Terminal。

## xfce4-terminal、terminator

这些终端的转义序列支持有限。修饰 Enter 键如 `Ctrl+Enter` 和 `Shift+Enter` 无法与普通 `Enter` 区分，导致 `submit: ["ctrl+enter"]` 等自定义键绑定无法工作。

为获得最佳体验，使用支持 Kitty 键盘协议的终端：
- [Kitty](https://sw.kovidgoyal.net/kitty/)
- [Ghostty](https://ghostty.org/)
- [WezTerm](https://wezfurlong.org/wezterm/)
- [iTerm2](https://iterm2.com/)
- [Alacritty](https://github.com/alacritty/alacritty)（需要编译时启用 Kitty 协议支持）

## IntelliJ IDEA（集成终端）

内置终端的转义序列支持有限。在 IntelliJ 终端中，`Shift+Enter` 无法与 `Enter` 区分。

如果想让硬件光标可见，在运行 pi 前设置 `PI_HARDWARE_CURSOR=1`（默认禁用以保持兼容性）。

建议使用专用终端模拟器以获得最佳体验。