# 开发指南

更多指南见 [AGENTS.md](../../../AGENTS.md)。

## 设置

```bash
git clone https://github.com/badlogic/pi-mono
cd pi-mono
npm install
```

从源码运行：

```bash
./pi-test.sh
```

## Fork / 重命名

通过 `package.json` 配置：

```json
{
  "piConfig": {
    "name": "pi",
    "configDir": ".pi"
  }
}
```

为你的 fork 更改 `name`、`configDir` 和 `bin` 字段。影响 CLI 横幅、配置路径和环境变量名。

## 路径解析

三种执行模式：npm install、独立二进制、从源码 tsx 运行。

**始终使用 `src/config.ts`** 获取包资源：

```typescript
import { getPackageDir, getThemeDir } from "./config.js";
```

永远不要直接使用 `__dirname` 获取包资源。

## 调试命令

`/debug`（隐藏命令）写入 `~/.pi/agent/pi-debug.log`：
- 带 ANSI 代码的渲染 TUI 行
- 发送给 LLM 的最后消息

## 测试

本仓库的具体开发与测试规则以根目录 `AGENTS.md` 为准。

常见开发检查：

```bash
npm run check
```

说明：
- 代码改动后优先运行 `npm run check`
- 不要默认运行 `npm test` 或 `npm run build`
- 只有在明确需要时，才从对应 package 目录运行特定测试文件

## 项目结构

```
packages/
  ai/           # LLM provider 抽象
  agent/        # Agent 循环和消息类型
  tui/          # 终端 UI 组件
  coding-agent/ # CLI 和交互模式
```