# Pi 包

> pi 可以帮你创建 pi 包。让它打包你的扩展、技能、提示模板或主题。

Pi 包将扩展、技能、提示模板和主题打包在一起，通过 npm 或 git 分享。包可以在 `package.json` 的 `pi` 键下声明资源，或使用约定目录。

## 目录

- [安装和管理](#安装和管理)
- [包来源](#包来源)
- [创建 Pi 包](#创建-pi-包)
- [包结构](#包结构)
- [依赖管理](#依赖管理)
- [包过滤](#包过滤)
- [启用和禁用资源](#启用和禁用资源)
- [作用域和去重](#作用域和去重)

## 安装和管理

> **安全：** Pi 包以完整的系统访问权限运行。扩展执行任意代码，技能可以指示模型执行任何操作，包括运行可执行文件。安装第三方包前请审查源代码。

```bash
pi install npm:@foo/bar@1.0.0
pi install git:github.com/user/repo@v1
pi install https://github.com/user/repo  # 原始 URL 也可以
pi install /absolute/path/to/package
pi install ./relative/path/to/package

pi remove npm:@foo/bar
pi list    # 显示设置中已安装的包
pi update  # 更新所有未固定的包
```

默认情况下，`install` 和 `remove` 写入全局设置（`~/.pi/agent/settings.json`）。使用 `-l` 写入项目设置（`.pi/settings.json`）。项目设置可以与团队共享，pi 在启动时自动安装任何缺失的包。

要试用包而不安装，使用 `--extension` 或 `-e`。这会安装到临时目录，仅当前运行有效：

```bash
pi -e npm:@foo/bar
pi -e git:github.com/user/repo
```

## 包来源

Pi 在设置和 `pi install` 中接受三种来源类型。

### npm

```
npm:@scope/pkg@1.2.3
npm:pkg
```

- 带版本号的规格会被固定，`pi update` 会跳过。
- 全局安装使用 `npm install -g`。
- 项目安装在 `.pi/npm/` 下。
- 在 `settings.json` 中设置 `npmCommand` 以将 npm 包查找和安装操作固定到特定的包装器命令，如 `mise` 或 `asdf`。

示例：

```json
{
  "npmCommand": ["mise", "exec", "node@20", "--", "npm"]
}
```

### git

```
git:github.com/user/repo@v1
git:git@github.com:user/repo@v1
https://github.com/user/repo@v1
ssh://git@github.com/user/repo@v1
```

- 没有 `git:` 前缀时，只接受协议 URL（`https://`、`http://`、`ssh://`、`git://`）。
- 有 `git:` 前缀时，接受简写格式，包括 `github.com/user/repo` 和 `git@github.com:user/repo`。
- HTTPS 和 SSH URL 都支持。
- SSH URL 自动使用配置的 SSH 密钥（遵循 `~/.ssh/config`）。
- 对于非交互运行（例如 CI），可以设置 `GIT_TERMINAL_PROMPT=0` 禁用凭据提示，并设置 `GIT_SSH_COMMAND`（例如 `ssh -o BatchMode=yes -o ConnectTimeout=5`）快速失败。
- 引用会固定包，`pi update` 会跳过。
- 克隆到 `~/.pi/agent/git/<host>/<path>`（全局）或 `.pi/git/<host>/<path>`（项目）。
- 如果存在 `package.json`，克隆或拉取后运行 `npm install`。

**SSH 示例：**
```bash
# git@host:path 简写（需要 git: 前缀）
pi install git:git@github.com:user/repo

# ssh:// 协议格式
pi install ssh://git@github.com/user/repo

# 带版本引用
pi install git:git@github.com:user/repo@v1.0.0
```

### 本地路径

```
/absolute/path/to/package
./relative/path/to/package
```

本地路径指向磁盘上的文件或目录，添加到设置时不会复制。相对路径相对于它们出现的设置文件解析。如果路径是文件，则作为单个扩展加载。如果是目录，pi 使用包规则加载资源。

## 创建 Pi 包

在 `package.json` 中添加 `pi` 清单或使用约定目录。包含 `pi-package` 关键字以便发现。

```json
{
  "name": "my-package",
  "keywords": ["pi-package"],
  "pi": {
    "extensions": ["./extensions"],
    "skills": ["./skills"],
    "prompts": ["./prompts"],
    "themes": ["./themes"]
  }
}
```

路径相对于包根目录。数组支持 glob 模式和 `!exclusions`。

### Gallery 元数据

[包画廊](https://shittycodingagent.ai/packages) 显示带有 `pi-package` 标签的包。添加 `video` 或 `image` 字段以显示预览：

```json
{
  "name": "my-package",
  "keywords": ["pi-package"],
  "pi": {
    "extensions": ["./extensions"],
    "video": "https://example.com/demo.mp4",
    "image": "https://example.com/screenshot.png"
  }
}
```

- **video**：仅 MP4。桌面端悬停时自动播放。点击打开全屏播放器。
- **image**：PNG、JPEG、GIF 或 WebP。显示为静态预览。

如果两者都设置，视频优先。

## 包结构

### 约定目录

如果没有 `pi` 清单，pi 从这些目录自动发现资源：

- `extensions/` 加载 `.ts` 和 `.js` 文件
- `skills/` 递归查找 `SKILL.md` 文件夹并加载顶级 `.md` 文件作为技能
- `prompts/` 加载 `.md` 文件
- `themes/` 加载 `.json` 文件

## 依赖管理

第三方运行时依赖应放在 `package.json` 的 `dependencies` 中。不注册扩展、技能、提示模板或主题的依赖也应放在 `dependencies` 中。当 pi 从 npm 或 git 安装包时，它运行 `npm install`，所以这些依赖会自动安装。

Pi 为扩展和技能打包核心包。如果你导入任何这些，将它们放在 `peerDependencies` 中并使用 `"*"` 范围，不要打包它们：`@mariozechner/pi-ai`、`@mariozechner/pi-agent-core`、`@mariozechner/pi-coding-agent`、`@mariozechner/pi-tui`、`@sinclair/typebox`。

其他 pi 包必须打包在你的 tarball 中。将它们添加到 `dependencies` 和 `bundledDependencies`，然后通过 `node_modules/` 路径引用它们的资源。Pi 加载具有独立模块根的包，所以独立安装不会冲突或共享模块。

示例：

```json
{
  "dependencies": {
    "shitty-extensions": "^1.0.1"
  },
  "bundledDependencies": ["shitty-extensions"],
  "pi": {
    "extensions": ["extensions", "node_modules/shitty-extensions/extensions"],
    "skills": ["skills", "node_modules/shitty-extensions/skills"]
  }
}
```

## 包过滤

使用设置中的对象形式过滤包加载的内容：

```json
{
  "packages": [
    "npm:simple-pkg",
    {
      "source": "npm:my-package",
      "extensions": ["extensions/*.ts", "!extensions/legacy.ts"],
      "skills": [],
      "prompts": ["prompts/review.md"],
      "themes": ["+themes/legacy.json"]
    }
  ]
}
```

`+path` 和 `-path` 是相对于包根目录的精确路径。

- 省略某键则加载该类型的全部。
- 使用 `[]` 则加载该类型的无。
- `!pattern` 排除匹配项。
- `+path` 强制包含精确路径。
- `-path` 强制排除精确路径。
- 过滤器叠加在清单之上。它们缩窄已允许的内容。

## 启用和禁用资源

使用 `pi config` 启用或禁用已安装包和本地目录中的扩展、技能、提示模板和主题。适用于全局（`~/.pi/agent`）和项目（`.pi/`）作用域。

## 作用域和去重

包可以同时出现在全局和项目设置中。如果同一包出现在两者中，项目条目优先。标识由以下确定：

- npm：包名
- git：仓库 URL（不带引用）
- 本地：解析后的绝对路径