# dAgent Hub: 稳定币支付与 Worker 部署模型

> 基于 USDC 的经济模型与 Worker 运行位置深度分析

---

## 1. 经济模型调整：使用 USDC

### 1.1 为什么不发代币？

| 顾虑 | 说明 | 解决方案 |
|------|------|----------|
| **监管风险** | 代币可能被视为证券 | 使用稳定币合规 |
| **复杂性** | 代币经济学设计困难 | 直接法币计价 |
| **流动性** | 新代币流动性差 | USDC 已广泛流通 |
| **用户门槛** | 需要理解代币价值 | USDC = 美元，直观 |
| **开发成本** | 需要质押、治理等 | 专注核心功能 |

### 1.2 USDC 支付模型

```
支付流程:
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Client    │────►│   Escrow    │────►│   Worker    │
│  (USDC)     │     │  Contract   │     │  (USDC)     │
└─────────────┘     └─────────────┘     └─────────────┘
       │                   │                   │
       │ 1. 充值           │ 2. 托管           │ 3. 结算
       │ 100 USDC          │ 任务完成          │ 95 USDC
       │                   │                   │
       ▼                   ▼                   ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ Platform    │     │ Insurance   │     │ Dispute     │
│ Fee: 5%     │     │ Fund: 5%    │     │ Resolver    │
└─────────────┘     └─────────────┘     └─────────────┘
```

### 1.3 费用结构设计

| 角色 | 收入 | 说明 |
|------|------|------|
| **Worker** | 90% | 完成任务获得 |
| **平台** | 5% | 协议维护、开发 |
| **保险基金** | 5% | 争议赔付、风险缓冲 |

**示例**: 100 USDC 的任务
- Worker 获得: 90 USDC
- 平台收入: 5 USDC
- 保险基金: 5 USDC

### 1.4 链上实现 (Sui)

```move
module dagent::payment {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    
    // 使用原生 USDC (通过 Wormhole 跨链)
    struct USDC has drop {}
    
    struct Escrow has key, store {
        id: UID,
        task_id: ID,
        client: address,
        worker: address,
        amount: Balance<USDC>,
        platform_fee: Balance<USDC>,
        insurance_fee: Balance<USDC>,
        status: EscrowStatus,
        created_at: u64,
        deadline: u64,
    }
    
    enum EscrowStatus has store, copy, drop {
        Locked,
        Released,      // 正常完成
        Disputed,      // 争议中
        Refunded,      // 退款给 Client
        Slashed,       // 惩罚 Worker
    }
    
    // 常量
    const PLATFORM_FEE_BPS: u64 = 500;  // 5% = 500 basis points
    const INSURANCE_FEE_BPS: u64 = 500; // 5%
    
    // 创建托管
    public fun create_escrow(
        task_id: ID,
        worker: address,
        payment: Coin<USDC>,
        deadline: u64,
        ctx: &mut TxContext,
    ): Escrow {
        let amount = coin::value(&payment);
        let platform_fee_amount = amount * PLATFORM_FEE_BPS / 10000;
        let insurance_fee_amount = amount * INSURANCE_FEE_BPS / 10000;
        let worker_amount = amount - platform_fee_amount - insurance_fee_amount;
        
        let mut payment_balance = coin::into_balance(payment);
        
        Escrow {
            id: object::new(ctx),
            task_id,
            client: tx_context::sender(ctx),
            worker,
            amount: balance::split(&mut payment_balance, worker_amount),
            platform_fee: balance::split(&mut payment_balance, platform_fee_amount),
            insurance_fee: payment_balance, // 剩余部分
            status: EscrowStatus::Locked,
            created_at: tx_context::epoch_timestamp_ms(ctx),
            deadline,
        }
    }
    
    // 释放资金给 Worker
    public fun release(
        escrow: &mut Escrow,
        ctx: &mut TxContext,
    ) {
        assert!(escrow.status == EscrowStatus::Locked, EInvalidStatus);
        
        // 转移 Worker 奖励
        let worker_payment = coin::from_balance(
            balance::withdraw_all(&mut escrow.amount),
            ctx
        );
        transfer::public_transfer(worker_payment, escrow.worker);
        
        // 平台费用转到国库
        let platform_coin = coin::from_balance(
            balance::withdraw_all(&mut escrow.platform_fee),
            ctx
        );
        transfer::public_transfer(platform_coin, @treasury);
        
        // 保险基金
        let insurance_coin = coin::from_balance(
            balance::withdraw_all(&mut escrow.insurance_fee),
            ctx
        );
        transfer::public_transfer(insurance_coin, @insurance_fund);
        
        escrow.status = EscrowStatus::Released;
    }
    
    // 争议解决
    public fun resolve_dispute(
        escrow: &mut Escrow,
        worker_wins: bool,
        ctx: &mut TxContext,
    ) {
        assert!(escrow.status == EscrowStatus::Disputed, EInvalidStatus);
        
        if (worker_wins) {
            // Worker 获得全部 (扣除费用)
            release(escrow, ctx);
        } else {
            // 退款给 Client
            let refund_amount = balance::value(&escrow.amount) 
                + balance::value(&escrow.platform_fee)
                + balance::value(&escrow.insurance_fee);
            
            let refund = coin::from_balance(
                balance::withdraw_all(&mut escrow.amount),
                ctx
            );
            balance::join(coin::balance_mut(&mut refund), 
                balance::withdraw_all(&mut escrow.platform_fee));
            balance::join(coin::balance_mut(&mut refund),
                balance::withdraw_all(&mut escrow.insurance_fee));
            
            transfer::public_transfer(refund, escrow.client);
            escrow.status = EscrowStatus::Refunded;
        }
    }
}
```

### 1.5 平台可持续运营

```
收入来源:
├─ 每笔交易 5% 平台费
├─ 保险基金投资收益
└─ 企业版订阅 (未来)

支出:
├─ 开发团队
├─ 服务器/索引器
├─ 安全审计
└─ 市场推广

盈亏平衡点:
假设平均任务金额 50 USDC
平台费 = 2.5 USDC/任务
若月运营成本 10,000 USDC
需要 4,000 任务/月 = 133 任务/天
```

---

## 2. Worker 运行位置分析

### 2.1 可选方案对比

| 方案 | 控制度 | 成本 | 性能 | 可用性 | 隐私 | 适合场景 |
|------|--------|------|------|--------|------|----------|
| **用户本地** | 高 | 低 | 中 | 低 | 极高 | 个人开发者 |
| **自托管云** | 中 | 中 | 高 | 高 | 高 | 专业 Agent |
| **Worker 即服务** | 低 | 按需 | 高 | 极高 | 中 | 普通用户 |
| **混合模式** | 灵活 | 灵活 | 灵活 | 高 | 可选 | 全场景 |

### 2.2 推荐：混合部署模型

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Worker 部署模型                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Tier 1: 个人本地 Worker (Community)                                │
│  ├─ 运行位置: 用户个人电脑/笔记本                                    │
│  ├─ 硬件要求: 8GB RAM, 50GB 存储                                     │
│  ├─ 适用: 开发者自用 Agent                                           │
│  ├─ 收益: 低 (仅自用或偶尔出租)                                      │
│  └─ 命令: dagent worker start --local                               │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Tier 2: 专业 Worker Node (Professional)                            │
│  ├─ 运行位置: 云服务器 (AWS/GCP/阿里云)                              │
│  ├─ 硬件要求: 32GB RAM, GPU (可选), 高速网络                          │
│  ├─ 适用: 专业 Agent 服务商                                          │
│  ├─ 收益: 中-高 (专业定价)                                           │
│  └─ 特点: 24/7 在线, SLA 保障                                        │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Tier 3: 托管 Worker (Managed)                                      │
│  ├─ 运行位置: 平台运营的服务器集群                                    │
│  ├─ 硬件要求: 企业级 GPU 集群                                         │
│  ├─ 适用: 不想运维的普通用户                                         │
│  ├─ 成本: 按使用量付费                                               │
│  └─ 特点: 一键部署, 零运维                                           │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.3 详细方案设计

#### 方案 A: 个人本地 Worker

**谁适合**: 开发者，有闲置机器

**运行方式**:
```bash
# 安装
npm install -g @dagent/worker

# 启动本地 Worker
dagent worker start
# 或 Docker
docker run -d \
  -v ~/.dagent:/data \
  -p 8080:8080 \
  dagent/worker:latest

# 配置
# ~/.dagent/config.yaml
worker:
  name: "my-worker"
  capabilities:
    - code-generation
    - code-review
  pricing:
    model: per_task
    base_price: 5  # 5 USDC
  auto_start: true
  hibernate_when_idle: true
```

**技术实现**:
```zig
// 本地 Worker 守护进程
pub const LocalWorker = struct {
    config: WorkerConfig,
    status: WorkerStatus,
    
    pub fn start(self: *LocalWorker) !void {
        // 1. 加载配置
        try self.loadConfig();
        
        // 2. 注册到网络
        try self.registerWithChain();
        
        // 3. 启动 HTTP 服务
        try self.startServer(8080);
        
        // 4. 设置休眠策略
        try self.setupHibernation();
        
        std.log.info("Worker running at http://localhost:8080");
    }
    
    // 休眠策略：空闲 5 分钟后休眠
    fn setupHibernation(self: *LocalWorker) !void {
        var timer = try std.time.Timer.start();
        
        while (true) {
            std.time.sleep(60 * std.time.ns_per_s); // 每分钟检查
            
            if (self.lastActivity.elapsed() > 5 * 60) {
                // 进入休眠
                try self.hibernate();
            }
        }
    }
    
    fn hibernate(self: *LocalWorker) !void {
        // 保存状态到磁盘
        try self.saveState();
        
        // 释放内存
        self.inference_engine.unload();
        
        // 保持网络连接，但降低资源占用
        self.status = .hibernating;
        
        std.log.info("Worker hibernated, waiting for tasks...");
    }
    
    // 收到任务时唤醒
    pub fn wakeUp(self: *LocalWorker) !void {
        if (self.status == .hibernating) {
            // 恢复状态
            try self.loadState();
            try self.inference_engine.load();
            self.status = .active;
            
            std.log.info("Worker woke up!");
        }
    }
};
```

**优缺点**:
- ✅ 零运营成本
- ✅ 数据完全私有
- ✅ 无托管风险
- ❌ 需要保持在线
- ❌ 网络不稳定
- ❌ 个人机器性能有限

#### 方案 B: 专业 Worker Node

**谁适合**: 专业 Agent 服务商，有运维能力

**运行方式**:
```bash
# 使用 Terraform 部署到云
terraform apply -f dagent-worker.tf

# 或 Kubernetes
kubectl apply -f dagent-worker.yaml
```

**Terraform 配置**:
```hcl
# dagent-worker.tf
provider "aws" {
  region = "us-west-2"
}

resource "aws_instance" "dagent_worker" {
  ami           = "ami-0c55b159cbfafe1f0"
  instance_type = "g4dn.xlarge"  # GPU 实例
  
  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y docker.io
              
              docker run -d \
                --gpus all \
                -e PRIVATE_KEY=${var.worker_private_key} \
                -e CHAIN_ENDPOINT=${var.chain_endpoint} \
                -v /data/dagent:/data \
                dagent/worker-gpu:latest
              EOF
  
  tags = {
    Name = "dagent-worker-${var.worker_name}"
  }
}
```

**Kubernetes 配置**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dagent-worker
spec:
  replicas: 3
  selector:
    matchLabels:
      app: dagent-worker
  template:
    metadata:
      labels:
        app: dagent-worker
    spec:
      containers:
      - name: worker
        image: dagent/worker:latest
        resources:
          requests:
            memory: "8Gi"
            cpu: "4"
          limits:
            memory: "16Gi"
            cpu: "8"
            nvidia.com/gpu: 1
        env:
        - name: WORKER_NAME
          value: "professional-worker-01"
        - name: CHAIN_ENDPOINT
          value: "https://rpc.sui.io"
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: dagent-worker-pvc
```

**收益模型**:
```
成本:
├─ AWS g4dn.xlarge: $0.526/小时
├─ 存储 (500GB): $50/月
└─ 网络: $0.09/GB

假设 70% 利用率:
月成本 = 0.526 * 24 * 30 * 0.7 + 50 = ~$315

收入:
├─ 平均任务价格: 20 USDC
├─ 平台费: 10% (2 USDC)
├─ Worker 获得: 18 USDC
└─ 需要 18 任务/天 盈亏平衡
```

#### 方案 C: 托管 Worker (Worker as a Service)

**谁适合**: 普通用户，不想运维

**运行方式**:
```bash
# 在平台一键部署
dagent deploy --tier standard

# Tier 选项:
# - hobby: 共享资源, $0.01/小时
# - standard: 专用 CPU, $0.05/小时
# - pro: GPU 实例, $0.50/小时
```

**平台架构**:
```
用户 ──► dAgent Hub 平台 ──► Worker 集群
         (管理面)            (执行面)
         
管理面:
├─ 用户注册 Worker
├─ 配置 Agent 能力
├─ 设置定价
└─ 查看收益

执行面:
├─ Kubernetes 集群
├─ 自动扩缩容
├─ 负载均衡
└─ 资源隔离
```

**计费模型**:
| Tier | 配置 | 价格 | 适合 |
|------|------|------|------|
| Hobby | 共享 CPU, 2GB RAM | $0.01/小时 | 测试、低频任务 |
| Standard | 4 vCPU, 8GB RAM | $0.05/小时 | 日常使用 |
| Pro | 8 vCPU, 32GB RAM, GPU | $0.50/小时 | 复杂任务 |
| Enterprise | 定制 | 按需 | 企业客户 |

### 2.4 Worker 发现与路由

```
用户请求 ──► 智能路由器 ──► 选择最优 Worker
              │
              ├─ 本地 Worker (如果在线)
              ├─ 专业 Worker (按评分/价格)
              └─ 托管 Worker (保底)

选择策略:
1. 首选本地 Worker (隐私优先)
2. 次选历史好评 Worker (质量优先)
3. 最后选低价 Worker (成本优先)
```

---

## 3. 混合模式实施路线图

### Phase 1: 本地 Worker MVP (2个月)

```
目标: 让开发者能在本地运行 Worker

功能:
├─ Zig Worker Runtime
├─ Docker 一键启动
├─ USDC 支付合约
└─ 基础 Web UI

目标用户: 开发者自用
```

### Phase 2: 专业 Worker (4个月)

```
目标: 支持云部署的专业 Worker

功能:
├─ Terraform/K8s 模板
├─ Worker 市场 (发现/评价)
├─ SLA 保障机制
└─ 自动扩缩容

目标用户: Agent 服务商
```

### Phase 3: 托管 Worker (6个月)

```
目标: 提供托管服务

功能:
├─ 一键部署
├─ 按需计费
├─ 多租户隔离
└─ 企业版支持

目标用户: 普通用户/企业
```

---

## 4. 关键决策总结

### 4.1 经济模型

| 决策 | 选择 | 理由 |
|------|------|------|
| **支付代币** | USDC | 合规、稳定、易理解 |
| **费用分配** | 90/5/5 | Worker 为主，平台可持续 |
| **最低任务价** | 1 USDC | 覆盖链上成本 |
| **结算周期** | 即时 | 区块链优势 |

### 4.2 Worker 模型

| 场景 | 推荐方案 | 理由 |
|------|----------|------|
| **个人开发者** | 本地 Worker | 零成本、隐私好 |
| **Agent 团队** | 专业 Worker | 稳定、可扩展 |
| **普通用户** | 托管 Worker | 零运维 |
| **企业客户** | 混合 + 私有部署 | 合规、安全 |

---

## 5. 下一步行动

1. **实现 USDC 支付合约** (Sui)
2. **开发本地 Worker MVP** (Zig)
3. **设计 Worker 发现协议**
4. **构建基础 Web UI**
5. **内测验证**

---

*本文档与 dAgent Hub 产品实现同步更新*
