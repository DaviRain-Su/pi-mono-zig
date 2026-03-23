# Shell 别名

pi 以非交互模式运行 bash（`bash -c`），默认不展开别名。

要启用你的 shell 别名，添加到 `~/.pi/agent/settings.json`：

```json
{
  "shellCommandPrefix": "shopt -s expand_aliases\neval \"$(grep '^alias ' ~/.zshrc)\""
}
```

根据你的 shell 配置文件调整路径（`~/.zshrc`、`~/.bashrc` 等）。