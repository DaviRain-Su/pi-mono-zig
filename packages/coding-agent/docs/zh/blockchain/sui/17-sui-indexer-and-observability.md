# Sui Indexer 与可观测性

> Task/Worker/Cost/Market 的索引、Dashboard 与告警设计

---

## 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│                        Sui 网络                             │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐       │
│  │  Task   │  │ Worker  │  │Dispute  │  │Payment  │       │
│  │ Events  │  │ Events  │  │ Events  │  │ Events  │       │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘       │
└───────┼────────────┼────────────┼────────────┼─────────────┘
        │            │            │            │
        └────────────┴────────────┴────────────┘
                           │
              ┌────────────▼────────────┐
              │     Sui Indexer         │
              │  (官方或自定义 GraphQL)   │
              └────────────┬────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
┌───────▼────────┐ ┌──────▼────────┐ ┌──────▼────────┐
│   Analytics    │ │   Dashboard   │ │   Alerting    │
│   Database     │ │   (Web UI)    │ │   System      │
│  (PostgreSQL)  │ │  (React/Vue)  │ │  (PagerDuty)  │
└────────────────┘ └───────────────┘ └───────────────┘
```

---

## 索引器方案

### 方案 1: 官方 Indexer (推荐)

```yaml
# docker-compose.yml
version: '3'
services:
  sui-indexer:
    image: mysten/sui-indexer:latest
    environment:
      - DB_URL=postgres://user:pass@postgres:5432/sui_indexer
      - RPC_CLIENT_URL=https://testnet.sui.io
      - MIGRATIONS_DIR=/app/migrations
    depends_on:
      - postgres
      
  postgres:
    image: postgres:15
    environment:
      POSTGRES_USER: user
      POSTGRES_PASSWORD: pass
      POSTGRES_DB: sui_indexer
    volumes:
      - postgres_data:/var/lib/postgresql/data
```

### 方案 2: 自定义轻量 Indexer

```typescript
// src/indexer/light-indexer.ts
import { SuiClient } from '@mysten/sui/client';
import { PrismaClient } from '@prisma/client';

export class LightIndexer {
    private client: SuiClient;
    private db: PrismaClient;
    private packageId: string;
    private cursor?: string;
    
    async start() {
        while (true) {
            try {
                const events = await this.client.queryEvents({
                    query: {
                        MoveEventType: `${this.packageId}::task::`,
                    },
                    cursor: this.cursor,
                    limit: 100,
                });
                
                for (const event of events.data) {
                    await this.processEvent(event);
                }
                
                this.cursor = events.nextCursor;
                
                // 等待下一个区块
                await sleep(1000);
            } catch (error) {
                console.error('Indexer error:', error);
                await sleep(5000);
            }
        }
    }
    
    private async processEvent(event: any) {
        const type = event.type;
        const data = event.parsedJson;
        
        if (type.includes('TaskCreated')) {
            await this.db.task.create({
                data: {
                    id: data.task_id,
                    creator: data.creator,
                    budget: data.budget,
                    status: 'PENDING',
                    createdAt: new Date(event.timestampMs),
                },
            });
        } else if (type.includes('TaskClaimed')) {
            await this.db.task.update({
                where: { id: data.task_id },
                data: {
                    status: 'CLAIMED',
                    worker: data.worker,
                    claimedAt: new Date(event.timestampMs),
                },
            });
        }
        // ... 更多事件类型
    }
}
```

---

## 数据模型

### 索引 Schema

```prisma
// schema.prisma
model Task {
    id              String    @id
    creator         String
    worker          String?
    budget          BigInt
    executionBudget BigInt
    status          TaskStatus
    
    // 时间戳
    createdAt       DateTime
    claimedAt       DateTime?
    submittedAt     DateTime?
    acceptedAt      DateTime?
    disputedAt      DateTime?
    resolvedAt      DateTime?
    
    // 关联
    results         TaskResult[]
    dispute         Dispute?
    
    @@index([status])
    @@index([creator])
    @@index([worker])
    @@index([createdAt])
}

model TaskResult {
    id              String   @id
    taskId          String
    task            Task     @relation(fields: [taskId], references: [id])
    
    resultCid       String
    usageReceiptCid String
    submittedAt     DateTime
    
    @@index([taskId])
}

model Worker {
    address         String   @id
    name            String
    
    // 统计
    totalTasks      Int      @default(0)
    completedTasks  Int      @default(0)
    disputedTasks   Int      @default(0)
    totalEarnings   BigInt   @default(0)
    
    // 声誉
    reputationScore Int      @default(5000)
    
    // 状态
    isOnline        Boolean  @default(false)
    lastHeartbeat   DateTime?
    
    // 能力
    capabilities    String[]
    
    @@index([reputationScore])
    @@index([isOnline])
}

model Dispute {
    id              String   @id
    taskId          String   @unique
    task            Task     @relation(fields: [taskId], references: [id])
    
    initiator       String
    reasonCid       String
    status          DisputeStatus
    
    votesForWorker  Int      @default(0)
    votesForCreator Int      @default(0)
    
    createdAt       DateTime
    resolvedAt      DateTime?
    resolution      Boolean?
    
    @@index([status])
}

model MarketMetrics {
    id              Int      @id @default(autoincrement())
    timestamp       DateTime @default(now())
    
    // 任务统计
    pendingTasks    Int
    claimedTasks    Int
    completedTasks24h Int
    
    // Worker 统计
    onlineWorkers   Int
    activeWorkers24h Int
    
    // 经济指标
    totalVolume24h  BigInt
    avgTaskValue    BigInt
    
    @@index([timestamp])
}

enum TaskStatus {
    PENDING
    CLAIMED
    SUBMITTED
    ACCEPTED
    REJECTED
    DISPUTED
    RESOLVED
    REFUNDED
}

enum DisputeStatus {
    OPEN
    VOTING
    RESOLVED
}
```

---

## Dashboard 设计

### 核心指标

```typescript
// src/dashboard/metrics.ts
export class MetricsService {
    constructor(private db: PrismaClient) {}
    
    /// 实时指标
    async getRealtimeMetrics() {
        const [
            pendingTasks,
            onlineWorkers,
            todayVolume,
            activeDisputes,
        ] = await Promise.all([
            this.db.task.count({ where: { status: 'PENDING' } }),
            this.db.worker.count({ where: { isOnline: true } }),
            this.getTodayVolume(),
            this.db.dispute.count({ where: { status: { in: ['OPEN', 'VOTING'] } } }),
        ]);
        
        return {
            pendingTasks,
            onlineWorkers,
            todayVolume,
            activeDisputes,
            healthScore: this.calculateHealthScore({
                pendingTasks,
                onlineWorkers,
            }),
        };
    }
    
    /// Worker 排行榜
    async getWorkerLeaderboard(limit = 10) {
        return this.db.worker.findMany({
            orderBy: [
                { reputationScore: 'desc' },
                { completedTasks: 'desc' },
            ],
            take: limit,
            select: {
                address: true,
                name: true,
                completedTasks: true,
                totalEarnings: true,
                reputationScore: true,
            },
        });
    }
    
    /// 任务趋势
    async getTaskTrends(days = 7) {
        const startDate = new Date();
        startDate.setDate(startDate.getDate() - days);
        
        return this.db.task.groupBy({
            by: ['createdAt'],
            where: {
                createdAt: { gte: startDate },
            },
            _count: { id: true },
            orderBy: { createdAt: 'asc' },
        });
    }
}
```

### Web Dashboard (React)

```tsx
// components/Dashboard.tsx
import { useQuery } from '@tanstack/react-query';
import { LineChart, BarChart, StatsCard } from './components';

export function Dashboard() {
    const { data: metrics } = useQuery({
        queryKey: ['metrics'],
        queryFn: () => fetch('/api/metrics/realtime').then(r => r.json()),
        refetchInterval: 5000,
    });
    
    const { data: trends } = useQuery({
        queryKey: ['trends'],
        queryFn: () => fetch('/api/metrics/trends').then(r => r.json()),
    });
    
    return (
        <div className="dashboard">
            <div className="stats-grid">
                <StatsCard
                    title="待处理任务"
                    value={metrics?.pendingTasks}
                    trend="+5%"
                />
                <StatsCard
                    title="在线 Worker"
                    value={metrics?.onlineWorkers}
                    trend="+2"
                />
                <StatsCard
                    title="24h 交易量"
                    value={`${metrics?.todayVolume / 1e9} SUI`}
                    trend="+12%"
                />
                <StatsCard
                    title="活跃争议"
                    value={metrics?.activeDisputes}
                    alert={metrics?.activeDisputes > 10}
                />
            </div>
            
            <div className="charts-grid">
                <LineChart
                    title="任务趋势"
                    data={trends?.taskTrends}
                />
                <BarChart
                    title="Worker 活跃度"
                    data={trends?.workerActivity}
                />
            </div>
        </div>
    );
}
```

---

## 告警系统

### 告警规则

```yaml
# alerts.yaml
alerts:
  - name: high_pending_tasks
    condition: pending_tasks > 100
    duration: 5m
    severity: warning
    message: "待处理任务过多: {{value}}"
    
  - name: low_online_workers
    condition: online_workers < 5
    duration: 10m
    severity: critical
    message: "在线 Worker 数量过低: {{value}}"
    
  - name: high_dispute_rate
    condition: dispute_rate > 10%
    duration: 1h
    severity: warning
    message: "争议率过高: {{value}}%"
    
  - name: system_health_low
    condition: health_score < 50
    duration: 5m
    severity: critical
    message: "系统健康分数过低: {{value}}"
    
  - name: large_task_created
    condition: task_budget > 10000 SUI
    duration: 0s
    severity: info
    message: "大额任务创建: {{value}} SUI"
```

### 告警服务

```typescript
// src/alerts/alert-service.ts
export class AlertService {
    private rules: AlertRule[];
    private channels: NotificationChannel[];
    
    async checkAndAlert(metrics: Metrics) {
        for (const rule of this.rules) {
            const triggered = this.evaluateRule(rule, metrics);
            
            if (triggered) {
                await this.sendAlert(rule, metrics);
            }
        }
    }
    
    private async sendAlert(rule: AlertRule, metrics: Metrics) {
        const message = this.formatMessage(rule, metrics);
        
        for (const channel of this.channels) {
            await channel.send({
                severity: rule.severity,
                title: rule.name,
                message,
                timestamp: new Date(),
            });
        }
    }
}

// Slack 通知
class SlackChannel implements NotificationChannel {
    async send(alert: Alert) {
        const color = alert.severity === 'critical' ? 'danger' : 
                      alert.severity === 'warning' ? 'warning' : 'good';
        
        await fetch(this.webhookUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                attachments: [{
                    color,
                    title: alert.title,
                    text: alert.message,
                    footer: `pi-worker-alerts • ${alert.timestamp}`,
                }],
            }),
        });
    }
}
```

---

## 日志与追踪

### 结构化日志

```typescript
// src/logging/logger.ts
import { createLogger, format, transports } from 'winston';

export const logger = createLogger({
    format: format.combine(
        format.timestamp(),
        format.json(),
    ),
    defaultMeta: {
        service: 'pi-worker-sui',
        version: process.env.VERSION,
    },
    transports: [
        new transports.Console(),
        new transports.File({ filename: 'logs/error.log', level: 'error' }),
        new transports.File({ filename: 'logs/combined.log' }),
    ],
});

// 使用
logger.info('Task claimed', {
    taskId: '0x1234',
    worker: '0x5678',
    duration: 1234,
});

logger.error('Task execution failed', {
    taskId: '0x1234',
    error: error.message,
    stack: error.stack,
});
```

### 性能追踪

```typescript
// src/tracing/performance.ts
export class PerformanceTracer {
    startSpan(name: string): Span {
        return {
            name,
            startTime: Date.now(),
            end: () => {
                const duration = Date.now() - this.startTime;
                logger.info('Span completed', {
                    span: name,
                    duration,
                });
            },
        };
    }
}

// 使用
const span = tracer.startSpan('task_execution');
try {
    await executeTask(task);
} finally {
    span.end();
}
```

---

## 与 Solana 的对比

| 方面 | Solana | Sui |
|------|--------|-----|
| **官方 Indexer** | QuickNode, Helius | 官方 GraphQL |
| **事件查询** | `getSignaturesForAddress` | `queryEvents` |
| **数据延迟** | ~400ms | ~200ms-2s |
| **历史数据** | 需要索引器 | 官方支持 |
| **订阅** | WebSocket | WebSocket |

---

## 下一步

- [18-sui-implementation-checklist.md](./18-sui-implementation-checklist.md) - 实现清单

---

*本文档与 pi Sui 可观测性实现同步更新*
