# 第14章：嵌入与集成

> SDK、RPC、Web UI

---

## 14.1 集成方式概览

| 方式 | 适用场景 | 复杂度 | 延迟 |
|-----|---------|--------|------|
| **SDK** | Node.js 应用嵌入 | 低 | 最低 |
| **RPC** | 跨进程/跨语言 | 中 | 低 |
| **Web UI** | 浏览器应用 | 中 | 中 |

---

## 14.2 SDK 集成

### 安装

```bash
npm install @mariozechner/pi-coding-agent
```

### 基础用法

```typescript
import { createAgentSession } from '@mariozechner/pi-coding-agent';

const { session } = await createAgentSession({
  cwd: '/path/to/project',
});

// 订阅事件
session.subscribe((event) => {
  switch (event.type) {
    case 'message_update':
      // 流式输出
      console.log(event.assistantMessageEvent);
      break;
    case 'agent_end':
      console.log('Done');
      break;
  }
});

// 发送消息
await session.prompt('Hello');
```

### 完整配置

```typescript
const { session, extensionsResult } = await createAgentSession({
  // 路径
  cwd: process.cwd(),
  agentDir: '~/.pi/agent',
  
  // 模型
  model: getModel('anthropic', 'claude-sonnet-4'),
  thinkingLevel: 'medium',
  
  // 工具
  tools: [readTool, bashTool],
  customTools: [myCustomTool],
  
  // 资源加载
  resourceLoader: myResourceLoader,
  
  // 会话
  sessionManager: mySessionManager,
  settingsManager: mySettingsManager,
});
```

### 控制 API

```typescript
// 会话控制
await session.prompt('message');
await session.steer('message');      // 插队消息
await session.followUp('message');   // 后续消息

// 模型控制
await session.setModel(newModel);
session.cycleModel('forward');

// 会话管理
await session.switchSession(path);
await session.fork();
await session.navigateTree(targetId);

// 其他
await session.compact();
session.abort();
await session.waitForIdle();
```

---

## 14.3 RPC 集成

### 启动 RPC 模式

```bash
pi --mode rpc --cwd /project
```

### 协议格式

**请求** (stdin):
```json
{ "type": "prompt", "id": "1", "content": "Hello" }
```

**响应** (stdout):
```json
{ "type": "response", "id": "1", "ok": true }
```

**事件** (stdout):
```json
{ "type": "message_update", "assistantMessageEvent": {...} }
```

### 命令类型

| 命令 | 说明 |
|-----|------|
| `prompt` | 发送消息 |
| `steer` | 插队消息 |
| `follow_up` | 后续消息 |
| `abort` | 中止 |
| `new_session` | 新会话 |
| `get_state` | 获取状态 |
| `set_model` | 设置模型 |
| `compact` | 压缩会话 |
| `switch_session` | 切换会话 |
| `fork` | 分叉 |

### 客户端示例

```typescript
import { spawn } from 'child_process';
import { RpcClient } from '@mariozechner/pi-coding-agent';

// 启动 RPC 进程
const process = spawn('pi', ['--mode', 'rpc', '--cwd', '/project']);

// 创建客户端
const client = new RpcClient(process);

// 发送命令
await client.prompt('Hello');

// 监听事件
client.onEvent((event) => {
  console.log(event.type);
});
```

---

## 14.4 Web UI 集成

### 安装

```bash
npm install @mariozechner/pi-web-ui
```

### 基础用法

```typescript
import { 
  ChatPanel, 
  AgentInterface,
  AppStorage,
  IndexedDBStorageBackend,
} from '@mariozechner/pi-web-ui';

// 设置存储
const backend = new IndexedDBStorageBackend({
  dbName: 'my-app',
  version: 1,
  stores: [...],
});

const storage = new AppStorage(...);
setAppStorage(storage);

// 创建 Agent
const agent = new Agent({
  initialState: {
    systemPrompt: 'You are helpful.',
    model: getModel('anthropic', 'claude-sonnet-4'),
    messages: [],
    tools: [],
  },
});

// 创建 UI
const chatPanel = new ChatPanel();
await chatPanel.setAgent(agent, {
  onApiKeyRequired: async (provider) => {
    // 提示输入 API key
  },
});

document.body.appendChild(chatPanel);
```

### 自定义组件

```typescript
import { AgentInterface } from '@mariozechner/pi-web-ui';

const agentInterface = document.createElement('agent-interface') as AgentInterface;
agentInterface.session = agent;
agentInterface.enableAttachments = true;
agentInterface.enableModelSelector = true;
```

---

## 14.5 选择集成方式

### 决策树

```
需要嵌入现有 Node.js 应用？
├── 是 → 使用 SDK
└── 否 → 需要跨进程/跨语言？
    ├── 是 → 使用 RPC
    └── 否 → 需要浏览器 UI？
        ├── 是 → 使用 Web UI
        └── 否 → 使用 CLI
```

### 场景推荐

| 场景 | 推荐方式 |
|-----|---------|
| IDE 插件 | SDK |
| CI/CD 集成 | RPC |
| 团队协作平台 | RPC + Web UI |
| 个人工具 | CLI |
| 浏览器插件 | Web UI |

---

## 本章小结

- **SDK**: Node.js 应用直接嵌入，最简单
- **RPC**: 跨进程通信，JSONL 协议
- **Web UI**: 浏览器组件，可定制
- **选择**: 根据场景和技术栈决定

---

*详细集成指南请参考 [embedding-and-rpc.md](./embedding-and-rpc.md)*
