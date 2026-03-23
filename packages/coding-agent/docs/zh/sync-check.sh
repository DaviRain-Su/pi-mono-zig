#!/bin/bash
# 同步检查脚本 - 检查英文文档是否有更新需要同步翻译
# 用法：./sync-check.sh [--diff]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCS_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(cd "$DOCS_DIR/../../.." && pwd)"

cd "$PROJECT_ROOT"

# 中文文档最后同步时的英文 commit（2026-03-22）
BASE_COMMIT="235b247f1"

# 英文文档列表
ENGLISH_DOCS="
compaction
custom-provider
development
extensions
json
keybindings
models
packages
prompt-templates
providers
rpc
sdk
session
settings
shell-aliases
skills
terminal-setup
termux
themes
tmux
tree
tui
windows
"

show_diff() {
    local doc=$1
    if git diff --quiet "$BASE_COMMIT..HEAD" -- "packages/coding-agent/docs/$doc.md" 2>/dev/null; then
        return 1
    else
        return 0
    fi
}

echo "=== 英文文档同步检查 ==="
echo "基准版本: $BASE_COMMIT (2026-03-22)"
echo ""

updated=0
for doc in $ENGLISH_DOCS; do
    if show_diff "$doc"; then
        echo "📝 $doc.md - 有更新"
        if [ "$1" = "--diff" ]; then
            git diff "$BASE_COMMIT..HEAD" -- "packages/coding-agent/docs/$doc.md" | head -20
            echo ""
        fi
        updated=$((updated + 1))
    fi
done

echo ""
if [ $updated -eq 0 ]; then
    echo "✅ 所有英文文档已是最新，无需同步"
else
    echo "⚠️  $updated 个文档需要同步翻译"
    echo ""
    echo "运行以下命令查看详细差异："
    echo "  ./sync-check.sh --diff"
fi