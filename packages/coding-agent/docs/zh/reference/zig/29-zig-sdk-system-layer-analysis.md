# Zig SDK 系统层级定位分析

> 从应用库到系统基础设施的清晰界定

---

## 核心问题

**"Zig 版本的 pi-mono 是属于 SDK，还是 Runtime，还是 OS？"**

答案：**都是，但分层次。**

---

## 1. 软件栈层级模型

### 1.1 经典操作系统层级

```
┌─────────────────────────────────────────────┐
│  Layer 4: 应用层 (Applications)              │
│  ├─ Chrome, VS Code, 游戏                   │
│  └─ pi-mono CLI (命令行工具)                 │
├─────────────────────────────────────────────┤
│  Layer 3: 运行时/框架 (Runtime/Framework)    │
│  ├─ Node.js, Python, JVM                    │
│  └─ pi-Runtime (系统服务)                    │
├─────────────────────────────────────────────┤
│  Layer 2: 库/SDK (Libraries/SDK)             │
│  ├─ libc, OpenSSL, TensorFlow               │
│  └─ pi-SDK (开发库)                          │
├─────────────────────────────────────────────┤
│  Layer 1: 操作系统 (Operating System)        │
│  ├─ Linux, Windows, macOS                   │
│  └─ pi-OS (长期愿景)                         │
├─────────────────────────────────────────────┤
│  Layer 0: 硬件 (Hardware)                    │
│  └─ CPU, GPU, NPU, Memory                   │
└─────────────────────────────────────────────┘
```

### 1.2 pi-mono 的分层定位

```
┌──────────────────────────────────────────────────────────────┐
│ Layer 4: 应用层                                               │
│ ├─ pi CLI (Zig 编写，使用 pi-SDK)                            │
│ ├─ pi GUI (React + pi-SDK)                                   │
│ └─ 第三方应用 (集成 pi-SDK)                                   │
├──────────────────────────────────────────────────────────────┤
│ Layer 3: Runtime 层                                           │
│ ├─ pi-daemon (系统服务，Zig 编写)                             │
│ │  ├─ Agent 生命周期管理                                      │
│ │  ├─ 任务调度                                                │
│ │  ├─ 资源分配                                                │
│ │  └─ 进程隔离                                                │
│ └─ pi-kernel (可选内核模块，Zig 编写)                         │
│    ├─ 零拷贝 I/O                                              │
│    └─ 高性能事件通知                                          │
├──────────────────────────────────────────────────────────────┤
│ Layer 2: SDK 层                                               │
│ ├─ pi-sdk-core (Zig 库)                                      │
│ │  ├─ 客户端 API                                              │
│ │  ├─ Worker API                                              │
│ │  ├─ 协议实现 (A2A/MCP/DASN)                                 │
│ │  └─ 类型定义                                                │
│ ├─ pi-sdk-react (React Hooks)                                │
│ └─ pi-sdk-cli (CLI 框架)                                     │
├──────────────────────────────────────────────────────────────┤
│ Layer 1: OS 层 (现在使用 Linux，未来可能 pi-OS)               │
│ ├─ Linux (现在)                                               │
│ └─ pi-OS (长期愿景)                                           │
└──────────────────────────────────────────────────────────────┘
```

---

## 2. SDK (Layer 2) 详解

### 2.1 SDK 的本质

```
SDK (Software Development Kit) 是:
├─ 开发工具集合
│   └─ 编译器、调试器、文档
├─ 库 (Library)
│   └─ 链接到应用程序
├─ API (Application Programming Interface)
│   └─ 定义接口契约
└─ 示例代码
    └─ 最佳实践展示

SDK 不是:
├─ ❌ 独立运行的程序
├─ ❌ 系统服务
├─ ❌ 操作系统
└─ ❌ 完整的解决方案
```

### 2.2 Zig SDK 的具体形态

```
pi-sdk/
├── include/
│   └── pi.h              # C 头文件 (用于 FFI)
├── lib/
│   ├── libpi.a           # 静态库
│   ├── libpi.so          # 动态库 (Linux)
│   └── pi.dll            # 动态库 (Windows)
├── zig/
│   └── pi/
│       ├── client.zig    # 客户端 API
│       ├── worker.zig    # Worker API
│       ├── types.zig     # 类型定义
│       └── protocol.zig  # 协议实现
├── examples/
│   ├── basic_client.zig
│   ├── custom_worker.zig
│   └── react_integration/
└── build.zig.zon         # Zig 包配置
```

### 2.3 SDK 使用示例

```zig
// 应用程序使用 SDK
const pi = @import("pi_sdk");

pub fn main() !void {
    // SDK 提供 API，但不提供服务
    // Runtime 服务需要单独启动
    
    const client = try pi.Client.init(.{
        .runtime_endpoint = "localhost:8080",
        // SDK 只是连接到一个已存在的 Runtime
    });
    
    const result = try client.executeTask("write a function");
    std.log.info("{s}", .{result.output});
}
```

编译命令：
```bash
# 链接 SDK 库
zig build-exe my_app.zig -lpi_sdk

# 运行时依赖
# pi-daemon 必须单独启动
./pi-daemon &  # ← 这是 Runtime
./my_app       # ← 这是使用 SDK 的应用
```

---

## 3. Runtime (Layer 3) 详解

### 3.1 Runtime 的本质

```
Runtime 是:
├─ 独立进程/服务
│   └─ 有自己的生命周期
├─ 资源管理者
│   └─ 分配系统资源
├─ 进程间协调者
│   └─ 多个应用间通信
└─ 系统级服务
    └─ 登录时启动，关机时停止

Runtime 不是:
├─ ❌ 应用代码的一部分
├─ ❌ 静态/动态库
└─ ❌ 用户的业务逻辑
```

### 3.2 pi-Runtime 的具体形态

```
pi-runtime/
├── pi-daemon              # 主服务进程
├── pi-agent-manager       # Agent 管理子服务
├── pi-task-scheduler      # 任务调度子服务
├── pi-message-bus         # 消息总线子服务
└── config/
    └── daemon.yaml        # 配置文件
```

### 3.3 Runtime 与 SDK 的关系

```
┌─────────────────────────────────────────────────────┐
│                    用户应用                          │
│  ┌───────────────────────────────────────────────┐ │
│  │  my_app.zig                                   │ │
│  │  ├─ 业务逻辑                                   │ │
│  │  └─ @import("pi_sdk")  ← 静态链接            │ │
│  └──────────────────────┬────────────────────────┘ │
│                         │ (编译期)                 │
│                         ▼                          │
│  ┌───────────────────────────────────────────────┐ │
│  │  pi-sdk-core (静态/动态库)                     │ │
│  │  ├─ 类型定义                                   │ │
│  │  ├─ 序列化                                     │ │
│  │  └─ 网络通信 (HTTP/WebSocket)                  │ │
│  └──────────────────────┬────────────────────────┘ │
│                         │ (运行时 IPC/网络)        │
│                         ▼                          │
│  ┌───────────────────────────────────────────────┐ │
│  │  pi-daemon (独立进程)                          │ │
│  │  ├─ Agent 管理                                 │ │
│  │  ├─ 任务队列                                   │ │
│  │  ├─ 资源调度                                   │ │
│  │  └─ 权限控制                                   │ │
│  └───────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

### 3.4 Runtime 服务管理

```bash
# systemd 服务示例 (Linux)
# /etc/systemd/system/pi-daemon.service
[Unit]
Description=pi-mono Runtime Daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/pi-daemon
Restart=always
User=pi-runtime
Group=pi-runtime

[Install]
WantedBy=multi-user.target
```

```bash
# 服务管理
sudo systemctl start pi-daemon
sudo systemctl status pi-daemon
sudo systemctl enable pi-daemon  # 开机启动
```

---

## 4. OS (Layer 1) 详解

### 4.1 OS 的本质

```
操作系统是:
├─ 硬件抽象层
│   └─ 驱动程序
├─ 资源分配器
│   └─ CPU/内存/IO
├─ 进程管理器
│   └─ 调度、隔离
├─ 文件系统
│   └─ 持久化存储
└─ 系统调用接口
    └─ 用户态入口

OS 不是:
├─ ❌ 单个应用程序
├─ ❌ 用户态服务
└─ ❌ 库或 SDK
```

### 4.2 pi-OS 的愿景

```
当前: Linux + pi-daemon (用户态)
         ↓
中期: Linux + pi-kernel (混合态)
         ↓
长期: pi-OS (完整操作系统)

pi-OS 组成:
├─ pi-kernel (微内核)
│  ├─ 进程调度
│  ├─ 内存管理
│  ├─ 进程间通信
│  └─ 驱动框架
├─ pi-fs (文件系统)
│  └─ Agent 状态存储
├─ pi-net (网络栈)
│  └─ Agent 通信协议
└─ pi-shell (交互界面)
   └─ 自然语言 Shell
```

### 4.3 三层关系总结

| 层级 | 形态 | 生命周期 | 开发者接触 | 示例 |
|------|------|---------|-----------|------|
| **SDK** | 库 (.a/.so) | 应用生命周期 | 直接调用 | `pi.Client.init()` |
| **Runtime** | 服务 (daemon) | 系统生命周期 | 通过 SDK 间接 | `pi-daemon` |
| **OS** | 内核 + 系统 | 硬件生命周期 | 系统调用 | `pi-kernel` |

---

## 5. Zig 在各层的实现

### 5.1 SDK 层 (现在就能做)

```zig
// pi-sdk/src/client.zig
pub const Client = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    runtime_endpoint: []const u8,
    
    pub fn init(config: ClientConfig) !Client {
        return .{
            .allocator = config.allocator,
            .http_client = std.http.Client.init(config.allocator),
            .runtime_endpoint = config.runtime_endpoint,
        };
    }
    
    pub fn executeTask(self: *Client, task: Task) !TaskResult {
        // 通过 HTTP 调用 Runtime API
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/api/v1/tasks",
            .{self.runtime_endpoint}
        );
        defer self.allocator.free(url);
        
        const body = try std.json.stringifyAlloc(self.allocator, task, .{});
        defer self.allocator.free(body);
        
        const response = try self.http_client.post(url, body);
        return try std.json.parse(TaskResult, response);
    }
};
```

### 5.2 Runtime 层 (3-6 个月)

```zig
// pi-runtime/src/daemon.zig
pub const Daemon = struct {
    allocator: std.mem.Allocator,
    agent_manager: AgentManager,
    task_scheduler: TaskScheduler,
    message_bus: MessageBus,
    http_server: std.http.Server,
    
    pub fn run(self: *Daemon) !void {
        // 启动 HTTP 服务
        const address = try std.net.Address.parseIp("0.0.0.0", 8080);
        try self.http_server.listen(address);
        
        std.log.info("pi-daemon listening on {}", .{address});
        
        // 事件循环
        while (self.running) {
            const connection = try self.http_server.accept();
            
            // 处理请求
            const handler = try Handler.init(connection, self);
            try handler.handle();
        }
    }
    
    fn handleSubmitTask(self: *Daemon, request: Request) !Response {
        const task = try std.json.parse(Task, request.body);
        
        // 提交到调度器
        const handle = try self.task_scheduler.submit(task);
        
        return Response{
            .status = .ok,
            .body = try std.json.stringify(.{
                .task_id = handle.id,
                .status = .queued,
            }),
        };
    }
};
```

### 5.3 OS 层 (长期)

```zig
// pi-os/kernel/src/main.zig
const std = @import("std");
const kernel = @import("kernel");

pub fn main() !void {
    // 初始化内核子系统
    try kernel.memory.init();
    try kernel.process.init();
    try kernel.ipc.init();
    try kernel.device.init();
    
    // 启动第一个用户态进程 (pi-init)
    const init = try kernel.process.spawn("/bin/pi-init", &.{});
    try kernel.scheduler.run(init);
}

// 系统调用处理
export fn syscall_handler(num: u32, args: [*]usize) isize {
    return switch (num) {
        1 => sys_agent_create(args[0], args[1]),
        2 => sys_agent_destroy(args[0]),
        3 => sys_task_submit(args[0], args[1]),
        4 => sys_task_wait(args[0], args[1]),
        else => -1,
    };
}
```

---

## 6. 为什么要分层？

### 6.1 关注点分离

```
SDK 层关注点:
├─ 开发者体验
├─ API 设计
├─ 语言绑定
└─ 编译集成

Runtime 层关注点:
├─ 性能优化
├─ 资源管理
├─ 安全性
└─ 稳定性

OS 层关注点:
├─ 硬件抽象
├─ 底层优化
├─ 系统级安全
└─ 标准化接口
```

### 6.2 独立演进

```
SDK 可以频繁更新:
├─ 每周发版
├─ 快速迭代 API
└─ 不影响 Runtime

Runtime 稳定更新:
├─ 月度发版
├─ 向后兼容
└─ 灰度发布

OS 极少更新:
├─ 年度发版
├─ 严格测试
└─ 长期支持
```

### 6.3 灵活部署

```
场景 1: 开发环境
├─ 只需 SDK
└─ 使用 mock Runtime

场景 2: 单机部署
├─ SDK + Runtime
└─ 本地 daemon

场景 3: 集群部署
├─ SDK + 远程 Runtime
└─ 共享 daemon

场景 4: 嵌入式
├─ 裁剪版 SDK
└─ 轻量 Runtime

场景 5: pi-OS
├─ 完整栈
└─ 一体化系统
```

---

## 7. 与现有方案对比

### 7.1 Docker 类比

```
┌──────────────────────────────────────────────────────────┐
│                    Docker 生态                            │
├──────────────────────────────────────────────────────────┤
│  SDK: Docker SDK (各语言绑定)                             │
│  Runtime: dockerd (守护进程)                              │
│  OS: containerd + Linux (或 Windows)                      │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│                    pi-mono 生态                           │
├──────────────────────────────────────────────────────────┤
│  SDK: pi-sdk (Zig 库 + 各语言绑定)                        │
│  Runtime: pi-daemon (系统服务)                            │
│  OS: pi-kernel + Linux (或 pi-OS)                         │
└──────────────────────────────────────────────────────────┘
```

### 7.2 Kubernetes 类比

```
Kubernetes:
├─ kubectl (CLI/SDK)
├─ kube-apiserver (Runtime 入口)
├─ kubelet (Runtime 节点代理)
└─ Linux (OS)

pi-mono:
├─ pi CLI (CLI/SDK)
├─ pi-gateway (Runtime 入口)
├─ pi-daemon (Runtime 节点代理)
└─ Linux/pi-OS (OS)
```

---

## 8. 实施路线图

### 8.1 Phase 1: SDK (现在 - 3个月)

```
目标: 提供开发者友好的库

交付物:
├─ pi-sdk-core (Zig)
├─ pi-sdk-node (Node.js 绑定)
├─ pi-sdk-python (Python 绑定)
└─ 文档与示例

使用方式:
const pi = @import("pi_sdk");
const client = try pi.Client.init(...);
```

### 8.2 Phase 2: Runtime (3-9个月)

```
目标: 提供系统级服务

交付物:
├─ pi-daemon (Zig 编写)
├─ systemd 集成
├─ 监控与日志
└─ 集群支持

使用方式:
systemctl start pi-daemon
# SDK 自动连接
```

### 8.3 Phase 3: Kernel 模块 (9-18个月)

```
目标: 性能关键路径内核化

交付物:
├─ pi-kernel (Linux 内核模块)
├─ eBPF 程序
├─ 零拷贝 I/O
└─ 安全加固

使用方式:
insmod pi-kernel.ko
# 自动被 Runtime 使用
```

### 8.4 Phase 4: pi-OS (18个月+)

```
目标: 完整的 AI 原生操作系统

交付物:
├─ pi-kernel (微内核)
├─ pi-fs (Agent 文件系统)
├─ pi-net (Agent 网络协议)
└─ pi-shell (自然语言 Shell)

使用方式:
启动盘安装 pi-OS
# 开箱即用
```

---

## 9. 关键决策点

### 9.1 现在做什么？

```
立即开始:
├─ ✅ Zig SDK 设计
├─ ✅ Runtime 架构设计
└─ ✅ 两者接口定义

3 个月内:
├─ 🔄 SDK MVP 实现
├─ 🔄 Mock Runtime
└─ 🔄 开发者反馈

6 个月内:
├─ ⏳ Real Runtime
├─ ⏳ 单机部署
└─ ⏳ 性能基准

长期:
├─ ⏸ Kernel 模块
├─ ⏸ pi-OS
└─ ⏸ 硬件合作
```

### 9.2 技术选型

| 决策 | 选项 | 选择 | 理由 |
|------|------|------|------|
| SDK 语言 | Zig / Rust / Go | **Zig** | 跨平台，C 互操作 |
| Runtime 语言 | Zig / Rust | **Zig** | 一致性，零成本 |
| Kernel 语言 | Zig / C / Rust | **Zig** | 统一技术栈 |
| 通信协议 | gRPC / HTTP/3 / Custom | **HTTP/3** | 成熟，穿透性好 |
| 序列化 | Protobuf / MessagePack / Cap'n Proto | **MessagePack** | 平衡效率与易用 |

---

## 10. 总结

### 一句话回答

> **Zig 版本的 pi-mono 是 SDK + Runtime + 未来可能的 OS，三者分层但统一技术栈。**

### 层次定位

```
┌────────────────────────────────────────────────────┐
│  Layer 4: 应用                                      │
│  ├─ pi CLI (使用 SDK)                              │
│  └─ 第三方应用 (使用 SDK)                          │
├────────────────────────────────────────────────────┤
│  Layer 3: Runtime                                   │
│  └─ pi-daemon (Zig 系统服务)                       │
├────────────────────────────────────────────────────┤
│  Layer 2: SDK                                       │
│  └─ pi-sdk (Zig 库 + 多语言绑定)                   │
├────────────────────────────────────────────────────┤
│  Layer 1: OS                                        │
│  ├─ Linux (现在)                                   │
│  └─ pi-OS (长期)                                   │
└────────────────────────────────────────────────────┘
```

### 当前状态 vs 目标

| 层级 | 当前 | 目标 |
|------|------|------|
| **SDK** | Node.js 库 | **Zig 库 + 多语言绑定** |
| **Runtime** | 无 (内嵌在应用中) | **独立 pi-daemon** |
| **OS** | Linux | **Linux + pi-kernel → pi-OS** |

### 下一步

1. **设计 SDK 接口** - 开发者友好的 API
2. **实现 Runtime MVP** - 基础的 Agent 管理
3. **定义层间契约** - SDK 与 Runtime 的通信协议
4. **验证架构** - 实际项目验证分层设计

---

*本文档与 pi-mono 系统架构设计同步更新*
