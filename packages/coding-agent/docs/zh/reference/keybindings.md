# 键绑定

所有键盘快捷键都可以通过 `~/.pi/agent/keybindings.json` 自定义。每个动作可以绑定一个或多个键。

配置文件使用与 pi 内部相同的命名空间键绑定 ID，扩展作者在 `keyHint()` 和注入的 `keybindings` 管理器中也使用相同的 ID。

使用前命名空间 ID（如 `cursorUp` 或 `expandTools`）的旧配置会在启动时自动迁移到命名空间 ID。

编辑 `keybindings.json` 后，在 pi 中运行 `/reload` 应用更改，无需重启会话。

## 键格式

`修饰键+键`，修饰键为 `ctrl`、`shift`、`alt`（可组合），键为：

- **字母：** `a-z`
- **数字：** `0-9`
- **特殊：** `escape`、`esc`、`enter`、`return`、`tab`、`space`、`backspace`、`delete`、`insert`、`clear`、`home`、`end`、`pageUp`、`pageDown`、`up`、`down`、`left`、`right`
- **功能：** `f1`-`f12`
- **符号：** `` ` ``、`-`、`=`、`[`、`]`、`\`、`;`、`'`、`,`、`.`、`/`、`!`、`@`、`#`、`$`、`%`、`^`、`&`、`*`、`(`、`)`、`_`、`+`、`|`、`~`、`{`、`}`、`:`、`<`、`>`、`?`

修饰键组合：`ctrl+shift+x`、`alt+ctrl+x`、`ctrl+shift+alt+x`、`ctrl+1` 等。

## 所有动作

### TUI 编辑器光标移动

| 键绑定 ID | 默认 | 描述 |
|----------|------|------|
| `tui.editor.cursorUp` | `up` | 光标上移 |
| `tui.editor.cursorDown` | `down` | 光标下移 |
| `tui.editor.cursorLeft` | `left`、`ctrl+b` | 光标左移 |
| `tui.editor.cursorRight` | `right`、`ctrl+f` | 光标右移 |
| `tui.editor.cursorWordLeft` | `alt+left`、`ctrl+left`、`alt+b` | 光标左移一词 |
| `tui.editor.cursorWordRight` | `alt+right`、`ctrl+right`、`alt+f` | 光标右移一词 |
| `tui.editor.cursorLineStart` | `home`、`ctrl+a` | 移动到行首 |
| `tui.editor.cursorLineEnd` | `end`、`ctrl+e` | 移动到行尾 |
| `tui.editor.jumpForward` | `ctrl+]` | 向前跳转到字符 |
| `tui.editor.jumpBackward` | `ctrl+alt+]` | 向后跳转到字符 |
| `tui.editor.pageUp` | `pageUp` | 向上翻页 |
| `tui.editor.pageDown` | `pageDown` | 向下翻页 |

### TUI 编辑器删除

| 键绑定 ID | 默认 | 描述 |
|----------|------|------|
| `tui.editor.deleteCharBackward` | `backspace` | 删除前一个字符 |
| `tui.editor.deleteCharForward` | `delete`、`ctrl+d` | 删除后一个字符 |
| `tui.editor.deleteWordBackward` | `ctrl+w`、`alt+backspace` | 删除前一个词 |
| `tui.editor.deleteWordForward` | `alt+d`、`alt+delete` | 删除后一个词 |
| `tui.editor.deleteToLineStart` | `ctrl+u` | 删除到行首 |
| `tui.editor.deleteToLineEnd` | `ctrl+k` | 删除到行尾 |

### TUI 输入

| 键绑定 ID | 默认 | 描述 |
|----------|------|------|
| `tui.input.newLine` | `shift+enter` | 插入新行 |
| `tui.input.submit` | `enter` | 提交输入 |
| `tui.input.tab` | `tab` | Tab / 自动补全 |

### TUI Kill Ring

| 键绑定 ID | 默认 | 描述 |
|----------|------|------|
| `tui.editor.yank` | `ctrl+y` | 粘贴最近删除的文本 |
| `tui.editor.yankPop` | `alt+y` | Yank 后循环删除的文本 |
| `tui.editor.undo` | `ctrl+-` | 撤销上次编辑 |

### TUI 剪贴板与选择

| 键绑定 ID | 默认 | 描述 |
|----------|------|------|
| `tui.input.copy` | `ctrl+c` | 复制选择 |
| `tui.select.up` | `up` | 选择上移 |
| `tui.select.down` | `down` | 选择下移 |
| `tui.select.pageUp` | `pageUp` | 列表中向上翻页 |
| `tui.select.pageDown` | `pageDown` | 列表中向下翻页 |
| `tui.select.confirm` | `enter` | 确认选择 |
| `tui.select.cancel` | `escape`、`ctrl+c` | 取消选择 |

### 应用程序

注意：这里列的是底层 keybinding ID 与默认映射。像“`Ctrl+C` 连按两次退出”与“`Escape` 连按两次打开 `/tree`”这类交互，属于应用层行为叠加，并不简单等于单个 keybinding ID。

| 键绑定 ID | 默认 | 描述 |
|----------|------|------|
| `app.interrupt` | `escape` | 取消 / 中止 |
| `app.clear` | `ctrl+c` | 清空编辑器 |
| `app.exit` | `ctrl+d` | 退出（当编辑器为空时）|
| `app.suspend` | `ctrl+z` | 挂起到后台 |
| `app.editor.external` | `ctrl+g` | 在外部编辑器打开（`$VISUAL` 或 `$EDITOR`）|
| `app.clipboard.pasteImage` | `ctrl+v`（Windows 上 `alt+v`）| 从剪贴板粘贴图片 |

### 会话

| 键绑定 ID | 默认 | 描述 |
|----------|------|------|
| `app.session.new` | *(无)* | 开始新会话（`/new`）|
| `app.session.tree` | *(无)* | 打开会话树导航器（`/tree`）|
| `app.session.fork` | *(无)* | 分叉当前会话（`/fork`）|
| `app.session.resume` | *(无)* | 打开会话恢复选择器（`/resume`）|
| `app.session.togglePath` | `ctrl+p` | 切换路径显示 |
| `app.session.toggleSort` | `ctrl+s` | 切换排序模式 |
| `app.session.toggleNamedFilter` | `ctrl+n` | 切换仅命名过滤 |
| `app.session.rename` | `ctrl+r` | 重命名会话 |
| `app.session.delete` | `ctrl+d` | 删除会话 |
| `app.session.deleteNoninvasive` | `ctrl+backspace` | 当查询为空时删除会话 |

### 模型与思考

| 键绑定 ID | 默认 | 描述 |
|----------|------|------|
| `app.model.select` | `ctrl+l` | 打开模型选择器 |
| `app.model.cycleForward` | `ctrl+p` | 切换到下一个模型 |
| `app.model.cycleBackward` | `shift+ctrl+p` | 切换到上一个模型 |
| `app.thinking.cycle` | `shift+tab` | 循环思考级别 |
| `app.thinking.toggle` | `ctrl+t` | 折叠或展开思考块 |

### 显示与消息队列

| 键绑定 ID | 默认 | 描述 |
|----------|------|------|
| `app.tools.expand` | `ctrl+o` | 折叠或展开工具输出 |
| `app.message.followUp` | `alt+enter` | 队列跟进消息 |
| `app.message.dequeue` | `alt+up` | 将队列消息恢复到编辑器 |

### 树导航

| 键绑定 ID | 默认 | 描述 |
|----------|------|------|
| `app.tree.foldOrUp` | `ctrl+left`、`alt+left` | 折叠当前分支段，或跳转到上一段开始 |
| `app.tree.unfoldOrDown` | `ctrl+right`、`alt+right` | 展开当前分支段，或跳转到下一段开始或分支结束 |

## 自定义配置

创建 `~/.pi/agent/keybindings.json`：

```json
{
  "tui.editor.cursorUp": ["up", "ctrl+p"],
  "tui.editor.cursorDown": ["down", "ctrl+n"],
  "tui.editor.deleteWordBackward": ["ctrl+w", "alt+backspace"]
}
```

每个动作可以有单个键或键数组。用户配置覆盖默认值。

### Emacs 示例

```json
{
  "tui.editor.cursorUp": ["up", "ctrl+p"],
  "tui.editor.cursorDown": ["down", "ctrl+n"],
  "tui.editor.cursorLeft": ["left", "ctrl+b"],
  "tui.editor.cursorRight": ["right", "ctrl+f"],
  "tui.editor.cursorWordLeft": ["alt+left", "alt+b"],
  "tui.editor.cursorWordRight": ["alt+right", "alt+f"],
  "tui.editor.deleteCharForward": ["delete", "ctrl+d"],
  "tui.editor.deleteCharBackward": ["backspace", "ctrl+h"],
  "tui.input.newLine": ["shift+enter", "ctrl+j"]
}
```

### Vim 示例

```json
{
  "tui.editor.cursorUp": ["up", "alt+k"],
  "tui.editor.cursorDown": ["down", "alt+j"],
  "tui.editor.cursorLeft": ["left", "alt+h"],
  "tui.editor.cursorRight": ["right", "alt+l"],
  "tui.editor.cursorWordLeft": ["alt+left", "alt+b"],
  "tui.editor.cursorWordRight": ["alt+right", "alt+w"]
}
```