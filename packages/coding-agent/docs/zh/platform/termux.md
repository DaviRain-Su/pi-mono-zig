# Termux (Android) 配置

pi 可以通过 [Termux](https://termux.dev/) 在 Android 上运行，Termux 是 Android 的终端模拟器和 Linux 环境。

## 前置要求

1. 从 GitHub 或 F-Droid 安装 [Termux](https://github.com/termux/termux-app#installation)（不要从 Google Play 安装，那个版本已废弃）
2. 从 GitHub 或 F-Droid 安装 [Termux:API](https://github.com/termux/termux-api#installation)，用于剪贴板和其他设备集成

## 安装

```bash
# 更新包
pkg update && pkg upgrade

# 安装依赖
pkg install nodejs termux-api git

# 安装 pi
npm install -g @mariozechner/pi-coding-agent

# 创建配置目录
mkdir -p ~/.pi/agent

# 运行 pi
pi
```

## 剪贴板支持

在 Termux 中运行时，剪贴板操作使用 `termux-clipboard-set` 和 `termux-clipboard-get`。需要安装 Termux:API 应用才能使用这些功能。

Termux **不支持**图片剪贴板（`ctrl+v` 粘贴图片功能无法使用）。

## Termux 示例 AGENTS.md

创建 `~/.pi/agent/AGENTS.md` 帮助 Agent 理解 Termux 环境：

```markdown
# Agent 环境：Android Termux

## 位置
- **OS**：Android（Termux 终端模拟器）
- **Home**：`/data/data/com.termux/files/home`
- **Prefix**：`/data/data/com.termux/files/usr`
- **共享存储**：`/storage/emulated/0`（Downloads、Documents 等）

## 打开 URL
```bash
termux-open-url "https://example.com"
```

## 打开文件
```bash
termux-open file.pdf          # 用默认应用打开
termux-open -c image.jpg      # 选择应用
```

## 剪贴板
```bash
termux-clipboard-set "text"   # 复制
termux-clipboard-get          # 粘贴
```

## 通知
```bash
termux-notification -t "标题" -c "内容"
```

## 设备信息
```bash
termux-battery-status         # 电池信息
termux-wifi-connectioninfo    # WiFi 信息
termux-telephony-deviceinfo   # 设备信息
```

## 分享
```bash
termux-share -a send file.txt # 分享文件
```

## 其他实用命令
```bash
termux-toast "消息"        # 快速 Toast 弹窗
termux-vibrate                # 振动设备
termux-tts-speak "hello"      # 语音合成
termux-camera-photo out.jpg   # 拍照
```

## 注意
- 需要 Termux:API 应用才能使用 `termux-*` 命令
- 使用 `pkg install termux-api` 安装命令行工具
- 访问 `/storage/emulated/0` 需要运行 `termux-setup-storage` 授权
```

## 限制

- **无图片剪贴板**：Termux 剪贴板 API 只支持文本
- **无原生二进制**：某些可选的原生依赖（如剪贴板模块）在 Android ARM64 上不可用，安装时会跳过
- **存储访问**：要访问 `/storage/emulated/0`（Downloads 等），需要运行一次 `termux-setup-storage` 授权

## 常见问题

### 剪贴板不工作

确保两个应用都已安装：
1. Termux（从 GitHub 或 F-Droid）
2. Termux:API（从 GitHub 或 F-Droid）

然后安装命令行工具：
```bash
pkg install termux-api
```

### 共享存储权限被拒绝

运行一次以授权存储权限：
```bash
termux-setup-storage
```

### Node.js 安装问题

如果 npm 失败，尝试清理缓存：
```bash
npm cache clean --force
```