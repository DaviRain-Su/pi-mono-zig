# pi-mono 多 Agent 架构分析

> 从单 Agent 到多 Agent 系统的演进路径与设计决策

---

## 当前状态确认

### 1.1 pi-mono 是单 Agent 的

```typescript
// 当前架构 (伪代码)
class PICore {
  private worker: SingleWorker;  // ← 只有一个 Worker
  
  async executeTask(task: Task) {
    // 所有任务交给同一个 Worker 处理
    return this.worker.process(task);
  }
}
```

**证据**:
- 配置文件指定单一 `worker` 端点
- 没有 Worker 发现机制
- 没有任务分发逻辑
- 没有 Worker 间通信

### 1.2 为什么是单 Agent？

```
设计选择:
├─ 简化架构 (降低复杂度)
├─ 专注代码生成场景 (一个人用)
├─ 避免分布式问题
└─ 快速验证核心概念

但限制:
├─ 无法横向扩展
├─ 无法处理复杂协作任务
├─ 单点故障
└─ 资源利用率低
```

---

## 多 Agent 是什么？

### 2.1 多 Agent 系统的定义

```
多 Agent 系统 (MAS):
├─ 多个自主 Agent
├─ 分布式环境
├─ 目标可能是协作或竞争
├─ 需要协调机制
└─ 可能出现 emergent behavior
```

### 2.2 多 Agent 的类型

| 类型 | 关系 | 示例 | pi-mono 适用性 |
|------|------|------|---------------|
| **协作型** | 共享目标 | 团队编程 | ✅ 高度适用 |
| **竞争型** | 资源竞争 | 市场竞价 | ⚠️ 有限适用 |
| **混合型** | 既有协作又有竞争 | 开源社区 | ✅ 适用 |
| **层级型** | 上下级关系 | 管理-执行 | ✅ 适用 |

### 2.3 pi-mono 场景下的多 Agent

```
场景 1: 代码生成团队
├─ Architect Agent (架构设计)
├─ Frontend Agent (前端实现)
├─ Backend Agent (后端实现)
├─ QA Agent (测试验证)
└─ Reviewer Agent (代码审查)

场景 2: 多语言支持
├─ Rust Specialist
├─ Zig Specialist
├─ Python Specialist
└─ TypeScript Specialist

场景 3: 并行开发
├─ Agent A 处理模块 A
├─ Agent B 处理模块 B
└─ Agent C 处理模块 C
```

---

## 从单 Agent 到多 Agent 的演进

### 3.1 演进阶段

```
Level 0: 单 Agent (当前)
├─ 一个 Worker
├─ 串行处理
└─ 单机运行

Level 1: 多 Worker (简单并行)
├─ 多个相同 Worker
├─ 负载均衡分发
└─ 仍单机，多进程

Level 2: 多 Agent (异构协作)
├─ 不同特长的 Agent
├─ 任务分解与分配
└─ 需要协调协议

Level 3: 分布式 MAS
├─ 跨机器部署
├─ 网络通信
└─ 容错与一致性

Level 4: 自治生态
├─ Agent 自主发现
├─ 动态组建团队
└─ 市场机制调节
```

### 3.2 Level 2 多 Agent 设计

```zig
// 多 Agent 运行时
pub const MultiAgentRuntime = struct {
    // Agent 注册表
    agents: std.StringHashMap(*Agent),
    
    // 任务路由器
    router: TaskRouter,
    
    // 协调器
    coordinator: Coordinator,
    
    // 通信总线
    bus: MessageBus,
    
    pub fn init() !MultiAgentRuntime {
        return .{
            .agents = std.StringHashMap(*Agent).init(allocator),
            .router = try TaskRouter.init(),
            .coordinator = try Coordinator.init(),
            .bus = try MessageBus.init(),
        };
    }
    
    // 注册 Agent
    pub fn registerAgent(
        self: *MultiAgentRuntime,
        agent: *Agent,
    ) !void {
        try self.agents.put(agent.id, agent);
        
        // 订阅消息
        try self.bus.subscribe(agent.id, agent.inbox);
        
        // 通知其他 Agent
        try self.broadcast(.{
            .type = .agent_joined,
            .agent_id = agent.id,
            .capabilities = agent.capabilities,
        });
    }
    
    // 提交任务
    pub fn submitTask(
        self: *MultiAgentRuntime,
        task: Task,
    ) !TaskHandle {
        // 1. 分解任务
        const subtasks = try self.decomposeTask(task);
        
        // 2. 创建执行计划
        const plan = try self.coordinator.createPlan(subtasks);
        
        // 3. 分配 Agent
        for (plan.steps) |step| {
            const agent = try self.selectAgent(step.required_capability);
            try self.assignTask(agent, step);
        }
        
        return TaskHandle{ .plan_id = plan.id };
    }
    
    // 任务分解
    fn decomposeTask(
        self: *MultiAgentRuntime,
        task: Task,
    ) ![]SubTask {
        // 使用 LLM 或规则引擎分解
        if (task.type == .complex_feature) {
            return &.{
                .{ .type = .architecture_design, .priority = 1 },
                .{ .type = .api_design, .priority = 2 },
                .{ .type = .implementation, .priority = 3 },
                .{ .type = .testing, .priority = 4 },
            };
        }
        
        return &.{.{ .type = task.type, .priority = 1 }};
    }
    
    // Agent 选择
    fn selectAgent(
        self: *MultiAgentRuntime,
        capability: Capability,
    ) !*Agent {
        var best_agent: ?*Agent = null;
        var best_score: f32 = 0;
        
        var it = self.agents.valueIterator();
        while (it.next()) |agent| {
            if (agent.hasCapability(capability)) {
                const score = agent.getLoadScore();
                if (score > best_score) {
                    best_score = score;
                    best_agent = agent.*;
                }
            }
        }
        
        return best_agent orelse error.NoAgentAvailable;
    }
    
    // 广播消息
    fn broadcast(self: *MultiAgentRuntime, message: Message) !void {
        var it = self.agents.keyIterator();
        while (it.next()) |id| {
            try self.bus.send(id.*, message);
        }
    }
};
```

### 3.3 Agent 通信协议

```zig
// Agent 间通信协议 (基于 Actor 模型)
pub const AgentMessage = union(enum) {
    // 任务相关
    assign_task: AssignTask,
    task_completed: TaskCompleted,
    task_failed: TaskFailed,
    
    // 协作相关
    request_help: RequestHelp,
    offer_help: OfferHelp,
    share_context: ShareContext,
    
    // 协调相关
    heartbeat: Heartbeat,
    status_update: StatusUpdate,
    
    // 知识共享
    share_knowledge: ShareKnowledge,
    query_knowledge: QueryKnowledge,
};

// 具体消息类型
pub const AssignTask = struct {
    task_id: []const u8,
    description: []const u8,
    context: TaskContext,
    deadline: ?i64,
    priority: Priority,
};

pub const ShareContext = struct {
    source_agent: []const u8,
    context_type: ContextType,
    data: []const u8,
    relevance_score: f32,
};
```

---

## Zig SDK 的定位澄清

### 4.1 SDK vs Runtime vs OS

```
概念澄清:

┌────────────────────────────────────────────────────────────┐
│                    pi-OS (长期愿景)                         │
│  ┌──────────────────────────────────────────────────────┐ │
│  │              pi-Runtime (系统服务)                    │ │
│  │  ┌────────────────────────────────────────────────┐ │ │
│  │  │           pi-SDK (开发者接口)                    │ │ │
│  │  │  ┌─────────────┐ ┌─────────────┐              │ │ │
│  │  │  │  Client API │ │  Worker API │              │ │ │
│  │  │  └─────────────┘ └─────────────┘              │ │ │
│  │  └────────────────────────────────────────────────┘ │ │
│  └──────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────┘

层级关系:
├─ SDK: 开发者调用 (库)
├─ Runtime: 系统服务 (守护进程)
└─ OS: 完整操作系统
```

### 4.2 Zig SDK 是什么？

```
Zig pi-SDK 是:
├─ 库 (Library)
│   └─ 链接到你的应用
├─ 开发工具 (Toolchain)
│   └─ 编译、调试、部署
├─ 抽象层 (Abstraction)
│   └─ 隐藏底层复杂性
└─ 接口定义 (Interface)
    └─ 与 Runtime/OS 交互

Zig pi-SDK 不是:
├─ ❌ 操作系统
├─ ❌ 运行时服务
├─ ❌ 独立可执行文件
└─ ❌ 完整的系统
```

### 4.3 Zig pi-Runtime 是什么？

```
Zig pi-Runtime 是:
├─ 系统服务 (System Service)
│   └─ 类似 systemd 服务
├─ Agent 管理器
│   └─ 启动、停止、监控 Agent
├─ 资源调度器
│   └─ 分配 CPU/GPU/内存
├─ 通信中间件
│   └─ Agent 间消息路由
└─ 系统接口
    └─ 与内核交互

部署形态:
├─ 用户态: Linux 服务
├─ 混合态: 内核模块 + 用户服务
└─ 内核态: 微内核 (长期)
```

### 4.4 关系图

```
┌───────────────────────────────────────────────────────────────┐
│                        应用场景                               │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐   │
│  │   Web App    │    │   CLI Tool   │    │  Embedded    │   │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘   │
│         │                   │                   │           │
│         └───────────────────┼───────────────────┘           │
│                             ▼                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                  pi-SDK (Zig)                        │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐     │  │
│  │  │   Client   │  │   Worker   │  │   Admin    │     │  │
│  │  └────────────┘  └────────────┘  └────────────┘     │  │
│  └─────────────────────────┬────────────────────────────┘  │
│                            │                                │
│         ┌──────────────────┼──────────────────┐            │
│         ▼                  ▼                  ▼            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │   HTTP API   │  │   IPC/Unix   │  │   eBPF       │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
│                            │                                │
│                            ▼                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                 pi-Runtime (Zig)                     │  │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐             │  │
│  │  │  Agent   │ │  Task    │ │  Message │             │  │
│  │  │ Manager  │ │ Scheduler│ │   Bus    │             │  │
│  │  └──────────┘ └──────────┘ └──────────┘             │  │
│  └─────────────────────────┬────────────────────────────┘  │
│                            │                                │
│         ┌──────────────────┼──────────────────┐            │
│         ▼                  ▼                  ▼            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │ Linux Kernel │  │   Android    │  │   pi-Kernel  │     │
│  │   (现在)     │  │   (未来)     │  │  (长期)      │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

---

## 多 Agent Zig SDK 设计

### 5.1 客户端 SDK

```zig
// 客户端使用多 Agent 系统
const pi = @import("pi");

pub fn main() !void {
    // 连接到 Runtime
    const runtime = try pi.Runtime.connect("localhost:8080");
    
    // 创建任务
    const task = pi.Task{
        .description = "Build a web app with auth and database",
        .requirements = .{
            .frontend = .react,
            .backend = .rust,
            .database = .postgresql,
        },
    };
    
    // 提交任务 - Runtime 自动分解并分配
    const handle = try runtime.submitTask(task);
    
    // 监听进度
    while (try handle.nextUpdate()) |update| {
        switch (update) {
            .agent_assigned => |a| std.log.info("Agent {s} assigned to {s}", .{a.agent_id, a.subtask}),
            .subtask_completed => |s| std.log.info("Completed: {s}", .{s.description}),
            .progress => |p| std.log.info("Progress: {d}%", .{p.percentage}),
            .completed => |result| {
                std.log.info("Done! Result: {s}", .{result.output});
                break;
            },
        }
    }
}
```

### 5.2 Worker SDK

```zig
// Worker 加入多 Agent 系统
const pi = @import("pi_worker");

pub fn main() !void {
    // 创建 Worker Agent
    var agent = try pi.Agent.init(.{
        .id = "rust-specialist-01",
        .capabilities = &.{
            .{ .name = "rust_backend", .level = .expert },
            .{ .name = "database_design", .level = .intermediate },
        },
        .max_concurrent_tasks = 3,
    });
    
    // 注册到 Runtime
    const runtime = try pi.Runtime.connect("runtime.pi.local:8080");
    try runtime.registerAgent(&agent);
    
    // 处理任务
    while (true) {
        const task = try agent.receiveTask();
        
        // 如果需要协作
        if (task.requires_collaboration) {
            const partner = try runtime.findAgent("frontend_specialist");
            try agent.requestCollaboration(partner, task);
        }
        
        // 执行任务
        const result = try executeTask(task);
        
        // 报告结果
        try agent.completeTask(task.id, result);
    }
}

fn executeTask(task: pi.Task) !pi.Result {
    // 实际执行逻辑
    // 可以调用 pi-worker 或其他工具
}
```

### 5.3 运行时 API

```zig
// 运行时暴露的接口
pub const Runtime = struct {
    // Agent 管理
    pub fn registerAgent(self: *Runtime, agent: *Agent) !void;
    pub fn unregisterAgent(self: *Runtime, agent_id: []const u8) !void;
    pub fn listAgents(self: *Runtime) ![]AgentInfo;
    pub fn getAgent(self: *Runtime, id: []const u8) ?*Agent;
    
    // 任务管理
    pub fn submitTask(self: *Runtime, task: Task) !TaskHandle;
    pub fn cancelTask(self: *Runtime, task_id: []const u8) !void;
    pub fn getTaskStatus(self: *Runtime, task_id: []const u8) !TaskStatus;
    
    // 协作
    pub fn findAgent(
        self: *Runtime,
        capability: Capability,
    ) !?*Agent;
    pub fn createTeam(
        self: *Runtime,
        requirements: []Capability,
    ) !Team;
    
    // 消息
    pub fn broadcast(self: *Runtime, message: Message) !void;
    pub fn sendTo(self: *Runtime, agent_id: []const u8, message: Message) !void;
};
```

---

## 多 Agent 协调机制

### 6.1 协调模式

```zig
// 中心化协调 (适合小规模)
pub const CentralizedCoordinator = struct {
    runtime: *Runtime,
    
    pub fn coordinate(self: *CentralizedCoordinator, task: Task) !void {
        // Runtime 决定一切
        const plan = try self.createPlan(task);
        for (plan.steps) |step| {
            const agent = try self.selectBestAgent(step);
            try self.assign(agent, step);
        }
    }
};

// 去中心化协调 (适合大规模)
pub const DecentralizedCoordinator = struct {
    // Agent 自主协商
    pub fn negotiate(self: *DecentralizedCoordinator, task: Task) !void {
        // 广播任务需求
        try self.broadcast(.{ .type = .task_available, .task = task });
        
        // 收集意向
        const bids = try self.collectBids(1000); // 1秒超时
        
        // 选择最优组合
        const team = try self.selectOptimalTeam(bids, task);
        
        // 分配任务
        for (team.members) |agent| {
            try agent.assign(task.subtaskFor(agent.capabilities));
        }
    }
};

// 市场机制协调
pub const MarketCoordinator = struct {
    // Agent 竞价
    pub fn auction(self: *MarketCoordinator, task: Task) !void {
        var auction = Auction.init(task);
        
        // 收集报价
        while (auction.isOpen()) {
            const bid = try auction.receiveBid();
            try auction.evaluate(bid);
        }
        
        // 分配给出价最优组合
        const winners = auction.getWinners();
        for (winners) |winner| {
            try winner.agent.assign(task);
        }
    }
};
```

### 6.2 共识机制

```zig
// 当多个 Agent 需要达成一致时
pub const Consensus = struct {
    // Raft/PBFT 简化版
    pub fn propose(
        self: *Consensus,
        proposal: Proposal,
    ) !ConsensusResult {
        // 发送给所有参与者
        for (self.participants) |participant| {
            try participant.send(.{ .type = .propose, .data = proposal });
        }
        
        // 收集投票
        var votes: u32 = 0;
        const threshold = self.participants.len / 2 + 1;
        
        while (votes < threshold) {
            const response = try self.receive(5000);
            if (response.type == .accept) {
                votes += 1;
            } else if (response.type == .reject) {
                return error.ProposalRejected;
            }
        }
        
        // 提交
        try self.commit(proposal);
        return .committed;
    }
};
```

---

## 实施策略

### 7.1 渐进式演进

```
Phase 1: SDK 层多 Agent (3个月)
├─ 在 SDK 中实现 Agent 管理
├─ 单 Runtime，多 Agent 逻辑
├─ 保持向后兼容
└─ 验证多 Agent 价值

Phase 2: Runtime 多 Agent (6个月)
├─ Runtime 支持多 Agent 注册
├─ 实现基本协调算法
├─ 任务分解与分配
└─ 单机多进程

Phase 3: 分布式多 Agent (12个月)
├─ 跨网络通信
├─ 分布式协调
├─ 容错与恢复
└─ 多机部署

Phase 4: 自治生态 (长期)
├─ Agent 自主发现
├─ 动态团队组建
├─ 市场机制
└─ 经济激励
```

### 7.2 与现有系统兼容

```zig
// 单 Agent 模式继续支持
pub const BackwardCompat = struct {
    // 包装单 Agent 为 Multi-Agent
    pub fn wrapSingleAgent(agent: *SingleAgent) !*MultiAgentAdapter {
        const adapter = try MultiAgentAdapter.init(agent);
        
        // 注册到 Runtime
        try runtime.registerAgent(adapter.asAgent());
        
        return adapter;
    }
};
```

---

## 总结

### 关键澄清

1. **pi-mono 目前确实是单 Agent**
   - 单 Worker，串行处理
   - 这是设计选择，不是技术限制

2. **多 Agent 是必然方向**
   - 复杂任务需要协作
   - 性能需要并行
   - 生态系统需要多样性

3. **Zig SDK 是库，不是 Runtime**
   - SDK = 开发者接口 (链接到应用)
   - Runtime = 系统服务 (独立进程)
   - OS = 完整系统 (长期愿景)

4. **分层架构**
   ```
   应用 → SDK → Runtime → OS/Kernel
   ```

### 下一步行动

```
1. 验证多 Agent 需求
   └─ 收集用户场景

2. 设计协调协议
   └─ 消息格式、状态机、共识

3. 实现 MVP
   └─ Level 2 多 Agent (单机)

4. 集成到 Zig SDK
   └─ 开发者友好的 API

5. 逐步扩展
   └─ 分布式、自治、市场
```

---

*本文档与 pi-mono 多 Agent 架构演进同步更新*
