# 中文文档同步状态

此文件追踪中文翻译与英文原文的同步状态。

## 同步方法

当英文文档更新时，运行以下命令检查差异：

```bash
# 检查英文文档是否有更新
cd packages/coding-agent/docs
git log -1 --format="%H %cs" -- <filename>.md

# 或批量检查所有文档
git log -1 --format="%H %cs" -- *.md
```

## 版本记录

| 英文原文 | 中文翻译 | 最后同步日期 | 英文 Commit |
|---------|---------|-------------|------------|
| `compaction.md` | `zh/reference/compaction.md` | 2026-03-22 | 235b247f1 |
| `custom-provider.md` | `zh/reference/custom-provider.md` | 2026-03-22 | 235b247f1 |
| `development.md` | `zh/guide/11-development.md` | 2026-03-22 | 235b247f1 |
| `extensions.md` | `zh/reference/extensions.md` | 2026-03-23 | 235b247f1 |
| `json.md` | `zh/reference/json-mode.md` | 2026-03-22 | 235b247f1 |
| `keybindings.md` | `zh/reference/keybindings.md` | 2026-03-22 | 235b247f1 |
| `models.md` | `zh/reference/models.md` | 2026-03-22 | 235b247f1 |
| `packages.md` | `zh/reference/packages.md` | 2026-03-22 | 235b247f1 |
| `prompt-templates.md` | `zh/guide/10-prompt-templates.md` | 2026-03-22 | 235b247f1 |
| `providers.md` | `zh/reference/providers.md` | 2026-03-22 | 235b247f1 |
| `rpc.md` | `zh/reference/rpc.md` | 2026-03-22 | 235b247f1 |
| `sdk.md` | `zh/reference/extensions-and-sdks.md` | 覆盖 | - |
| `session.md` | `zh/guide/05-sessions.md` | 覆盖 | - |
| `settings.md` | `zh/reference/settings.md` | 2026-03-22 | 235b247f1 |
| `shell-aliases.md` | `zh/reference/shell-aliases.md` | 2026-03-22 | 235b247f1 |
| `skills.md` | `zh/guide/06-skills.md` | 覆盖 | - |
| `terminal-setup.md` | `zh/platform/terminal-setup.md` | 2026-03-22 | 235b247f1 |
| `termux.md` | `zh/platform/termux.md` | 2026-03-22 | 235b247f1 |
| `themes.md` | `zh/reference/themes.md` | 2026-03-22 | 235b247f1 |
| `tmux.md` | `zh/platform/tmux.md` | 2026-03-22 | 235b247f1 |
| `tree.md` | `zh/reference/tree.md` | 2026-03-22 | 235b247f1 |
| `tui.md` | `zh/reference/tui.md` | 2026-03-22 | 235b247f1 |
| `windows.md` | `zh/platform/windows.md` | 2026-03-22 | 235b247f1 |

## 同步检查脚本

```bash
#!/bin/bash
# 检查英文文档是否有更新

CDIR="packages/coding-agent/docs"
ENGLISH_DOCS=$(ls $CDIR/*.md 2>/dev/null | xargs -I{} basename {} .md)

for doc in $ENGLISH_DOCS; do
    LAST_COMMIT=$(git log -1 --format="%cs" -- "$CDIR/$doc.md" 2>/dev/null)
    echo "$doc.md: $LAST_COMMIT"
done
```

## 同步翻译流程

1. **检测更新**：运行上述脚本或检查 git log
2. **对比差异**：`git diff <old_commit>..HEAD -- <file>.md`
3. **翻译更新**：修改对应的中文文档
4. **更新状态**：更新此文件的版本记录表

## 特殊情况

### 覆盖式文档

部分英文文档由中文文档覆盖（更详细或整合版）：

| 英文 | 中文替代 | 说明 |
|-----|---------|------|
| `extensions.md` | `reference/extensions.md` | 完整翻译，2100+ 行 |
| `sdk.md` | `reference/extensions-and-sdks.md` | 整合到 SDK 指南 |
| `session.md` | `guide/05-sessions.md` | 整合到会话管理章节 |
| `skills.md` | `guide/06-skills.md` | 整合到 Skill 系统章节 |

这些文档需要对照英文原文检查是否有新增内容需要补充。

---

*最后更新：2026-03-23*