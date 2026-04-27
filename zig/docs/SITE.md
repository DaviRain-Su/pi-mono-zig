# 官网部署说明

`zig/docs/index.html` 是 Pi Agent (Zig 版) 的项目主页，纯静态单页面，无需构建。

## 文件清单

```
zig/docs/
  index.html        # 主页（含完整样式与内容）
  REVIEW.md         # 详细 review，可链接进主页
  SITE.md           # 本文件
  .nojekyll         # 告诉 GitHub Pages 跳过 Jekyll
```

## GitHub Pages 部署

GitHub Pages 默认从仓库根的 `/` 或 `/docs/` 提供服务，不能直接指到子目录 `zig/docs/`。
有三种方式部署：

### 方式 1：把 docs 软链/复制到仓库根（最简单）

在仓库根添加一个 `docs/` 软链或专门的发布目录：

```bash
# 仓库根
ln -s zig/docs docs
```

然后在 GitHub 仓库 Settings → Pages 选择：
- Source: `Deploy from a branch`
- Branch: `main` / Folder: `/docs`

### 方式 2：用 GitHub Actions 部署（推荐）

`.github/workflows/pages.yml`：

```yaml
name: Deploy site
on:
  push:
    branches: [main]
    paths: ["zig/docs/**"]
  workflow_dispatch:

permissions:
  pages: write
  id-token: write

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/configure-pages@v5
      - uses: actions/upload-pages-artifact@v3
        with:
          path: zig/docs
      - id: deployment
        uses: actions/deploy-pages@v4
```

仓库 Settings → Pages → Source 选 `GitHub Actions`。

### 方式 3：单独的 gh-pages 分支

```bash
git subtree push --prefix zig/docs origin gh-pages
```

仓库 Settings → Pages → Source: `Deploy from a branch` / Branch: `gh-pages` / `/`。

## 自定义域名（可选）

在 `zig/docs/` 下加一个 `CNAME` 文件，单行写域名：

```
pi-agent.example.com
```

DNS 加 CNAME 指向 `<user>.github.io`。

## REVIEW.md 渲染

`index.html` 里有指向 `REVIEW.html` 的链接。GitHub Pages 不会自动把 Markdown 转成 HTML
（因为开了 `.nojekyll`）。两种处理：

1. **简单做法**：把链接改成 `REVIEW.md`，GitHub 网页端可直接渲染。
2. **正式做法**：用 GitHub Actions 跑 `pandoc` 或类似工具把 `REVIEW.md` → `REVIEW.html`，
   作为构建步骤的一部分。

## 本地预览

```bash
cd zig/docs
python3 -m http.server 8080
# 浏览器打开 http://localhost:8080
```

或：

```bash
npx serve zig/docs
```
