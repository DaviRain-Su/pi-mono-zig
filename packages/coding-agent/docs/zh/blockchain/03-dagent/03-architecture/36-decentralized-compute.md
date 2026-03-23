# 去中心化计算平台全景分析

> EigenCompute、ICP 及其他 TEE 平台对比与 pi-worker 部署策略

---

## 1. EigenCompute 深度分析

### 1.1 项目概述

**官网**: https://deploy-to-eigen-compute.vercel.app

**核心定位**:
> "EigenCompute is a verifiable compute platform by EigenLayer that runs Docker images inside Intel TDX TEEs."

**一句话理解**:
EigenLayer 提供的去中心化云计算服务，应用运行在 Intel TDX 可信执行环境中，支持链上验证。

### 1.2 技术架构

```
用户应用 (Docker)
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│                    Intel TDX TEE                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │               安全飞地 (Enclave)                      │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────┐   │  │
│  │  │   应用代码    │  │   数据        │  │  密钥     │   │  │
│  │  │   (Docker)   │  │   (加密)      │  │  (密封)   │   │  │
│  │  └──────────────┘  └──────────────┘  └──────────┘   │  │
│  │                                                      │  │
│  │  硬件级隔离 - 连宿主机都无法访问                        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
       │
       ▼
链上证明 (Attestation) - 可验证运行环境
       │
       ▼
EigenLayer 网络 - 去中心化算力市场
```

### 1.3 核心特性

| 特性 | 说明 | 意义 |
|------|------|------|
| **Intel TDX** | 硬件级可信执行环境 | 代码和数据对运营商不可见 |
| **链上证明** | Attestation 上链 | 可验证应用确实在 TEE 中运行 |
| **Docker 兼容** | 标准容器部署 | 无需修改现有应用 |
| **公网 IP** | 自动分配 | 可直接访问服务 |
| **持久存储** | 加密存储 | 数据安全保留 |
| **密钥注入** | 加密环境变量 | 安全密钥管理 |

### 1.4 部署流程

```bash
# 1. 安装 CLI
curl -fsSL https://raw.githubusercontent.com/Layr-Labs/eigencloud-tools/master/install-all.sh | bash

# 2. 认证 (以太坊私钥)
ecloud auth login

# 3. 订阅计费
ecloud billing subscribe

# 4. 构建 Docker 镜像 (必须为 linux/amd64)
docker buildx build --platform linux/amd64 \
  -t yourdockerhub/yourapp:v1.0.0 --push .

# 5. 部署到 TEE
ecloud compute app deploy \
  --image-ref yourdockerhub/yourapp:v1.0.0 \
  --env-file .env \
  --instance-type g1-standard-4t \
  --verifiable  # 启用链上验证

# 6. 查看状态
ecloud compute app info --watch
```

### 1.5 实例类型与定价

| 实例类型 | 配置 | 预估价格 | 适合场景 |
|----------|------|----------|----------|
| g1-standard-1t | 1 vCPU, 2GB RAM | $0.01/小时 | 轻量级 Agent |
| g1-standard-2t | 2 vCPU, 4GB RAM | $0.02/小时 | 标准 Agent |
| g1-standard-4t | 4 vCPU, 8GB RAM | $0.04/小时 | 复杂任务 |
| g1-standard-8t | 8 vCPU, 16GB RAM | $0.08/小时 | 高性能需求 |
| g1-gpu-1x | 4 vCPU + GPU | $0.50/小时 | AI 推理 |

**成本估算** (g1-standard-4t):
- 每小时: $0.04
- 每天: $0.96
- 每月: ~$29

### 1.6 对 pi-worker 的意义

**优势**:
- ✅ 硬件级安全 (TEE)
- ✅ 去中心化算力 (EigenLayer)
- ✅ 链上可验证
- ✅ Docker 兼容 (pi-mono 可直接运行)
- ✅ 公网 IP (易于接入网络)

**局限**:
- ❌ 依赖 Intel TDX (硬件限制)
- ❌ 需要 EigenLayer 生态支持
- ❌ 相对早期 (测试网阶段)
- ❌ 成本高于传统 VPS

---

## 2. ICP (Internet Computer) 分析

### 2.1 项目概述

**官网**: https://internetcomputer.org

**核心定位**:
> "World Computer" - 去中心化的云计算平台，可以运行完整 Web 应用。

**一句话理解**:
一个去中心化的"世界计算机"，可以直接在链上运行后端代码，无需传统服务器。

### 2.2 技术架构

```
传统架构:
Frontend (React) ──► Backend API ──► Database
                         │
                         ▼
                    AWS/GCP Server

ICP 架构:
Frontend (React) ──► Canister (智能合约 + 后端 + 存储)
                         │
                         ▼
              ICP Subnet (去中心化节点)
```

### 2.3 核心概念: Canister

```
Canister = 智能合约 + WebAssembly 运行时 + 存储

特点:
├─ 使用 Motoko 或 Rust 编写
├─ 编译为 WebAssembly
├─ 在 ICP 节点上运行
├─ 自动持久化存储
├─ 可支付自己的计算费用 (反向 Gas)
└─ 支持 HTTP 接口 (直接访问)
```

### 2.4 部署 pi-worker 到 ICP

**方案 A: 直接移植 (困难)**
```rust
// 将 pi-mono 改写为 Rust/Motoko
// 运行在 Canister 中
// 挑战: 无法直接调用 OpenAI API (HTTP 限制)
```

**方案 B: 混合架构 (推荐)**
```
ICP Canister:
├─ Agent 注册信息
├─ 任务队列管理
├─ 支付结算逻辑
└─ 前端 UI

外部 Worker:
├─ 运行在传统服务器/VPS
├─ 轮询 ICP 获取任务
├─ 执行 pi-mono 逻辑
└─ 返回结果到 ICP

        ┌─────────────────┐
        │   ICP Canister  │
        │   (任务管理)     │
        └────────┬────────┘
                 │ 轮询
                 ▼
        ┌─────────────────┐
        │  Worker Server  │
        │  (pi-mono 执行)  │
        └─────────────────┘
```

**代码示例**:
```rust
// ICP Canister (Rust)
#[ic_cdk::update]
fn submit_task(prompt: String, budget: u64) -> TaskId {
    let task = Task {
        id: next_id(),
        prompt,
        budget,
        status: TaskStatus::Pending,
        created_at: ic_cdk::api::time(),
    };
    
    TASKS.with(|t| t.borrow_mut().insert(task.id, task));
    
    // 通知 Worker (通过 HTTP 或轮询)
    notify_workers();
    
    task.id
}

#[ic_cdk::query]
fn get_pending_tasks() -> Vec<Task> {
    TASKS.with(|t| {
        t.borrow()
            .iter()
            .filter(|(_, task)| task.status == TaskStatus::Pending)
            .map(|(_, task)| task.clone())
            .collect()
    })
}

#[ic_cdk::update]
fn submit_result(task_id: TaskId, result: String) {
    // Worker 调用此函数提交结果
    // 验证 Worker 身份
    // 释放支付
}
```

```typescript
// Worker (Node.js) 轮询 ICP
import { Actor, HttpAgent } from '@dfinity/agent';
import { idlFactory } from './declarations/dagent_canister';

class ICPWorker {
  private actor: any;
  
  async init() {
    const agent = new HttpAgent({ host: 'https://ic0.app' });
    this.actor = Actor.createActor(idlFactory, {
      agent,
      canisterId: 'aaaaa-aa',
    });
  }
  
  async pollTasks() {
    // 每 5 秒轮询一次
    setInterval(async () => {
      const tasks = await this.actor.get_pending_tasks();
      
      for (const task of tasks) {
        if (this.canHandle(task)) {
          await this.executeAndSubmit(task);
        }
      }
    }, 5000);
  }
  
  async executeAndSubmit(task: Task) {
    // 使用 pi-mono 执行
    const result = await piMono.execute(task.prompt);
    
    // 提交到 ICP
    await this.actor.submit_result(task.id, result);
  }
}
```

### 2.5 ICP 优缺点

**优势**:
- ✅ 完全去中心化 (无服务器)
- ✅ 反向 Gas 费 (用户无需付 Gas)
- ✅ WebSpeed (低延迟)
- ✅ 链上存储
- ✅ 成熟生态

**局限**:
- ❌ 学习曲线陡峭 (Motoko/Rust)
- ❌ 计算限制 (Cycle 消耗)
- ❌ HTTP 调用限制
- ❌ 不适合长时间运行任务
- ❌ 无法直接运行 Docker

---

## 3. 其他 TEE/去中心化计算平台

### 3.1 平台对比

| 平台 | 技术 | 特点 | 成熟度 | pi-worker 适配 |
|------|------|------|--------|----------------|
| **EigenCompute** | Intel TDX | 硬件 TEE，链上证明 | 早期 | ⭐⭐⭐⭐ |
| **ICP** | WebAssembly | 世界计算机，完全去中心化 | 成熟 | ⭐⭐ |
| **Phala Network** | Intel SGX | 隐私计算，波卡生态 | 中等 | ⭐⭐⭐⭐ |
| **Secret Network** | Intel SGX | 隐私智能合约，Cosmos | 成熟 | ⭐⭐⭐ |
| **Oasis Network** | Intel SGX | 隐私计算，模块化 | 中等 | ⭐⭐⭐ |
| **Akash Network** | Kubernetes | 去中心化云服务 (无 TEE) | 成熟 | ⭐⭐⭐⭐⭐ |
| **Golem** | Docker | P2P 计算市场 | 中等 | ⭐⭐⭐ |
| **iExec** | Intel SGX | 企业级去中心化计算 | 中等 | ⭐⭐⭐ |

### 3.2 重点推荐：Phala Network

**定位**: 波卡生态的 TEE 云计算平台

**特点**:
```
├─ 基于 Intel SGX
├─ 支持 Docker 容器
├─ 与波卡生态互通
├─ 较低成本
└─ 中文社区活跃
```

**部署示例**:
```bash
# Phala 使用类似于 Docker Compose
# 定义 phala-compose.yaml
version: '3'
services:
  pi-worker:
    image: dagent/worker:latest
    environment:
      - CHAIN=phala
      - WORKER_ID=${WORKER_ID}
    
# 部署到 Phala 网络
phala deploy phala-compose.yaml
```

### 3.3 重点推荐：Akash Network

**定位**: "Airbnb for Compute" - 去中心化云服务

**特点**:
```
├─ 基于 Kubernetes
├─ 无 TEE (软件级隔离)
├─ 极低成本 (比 AWS 便宜 80%)
├─ Docker 原生支持
├─ 成熟稳定
└─ 使用 AKT 代币 (可转换为 USDC)
```

**部署示例**:
```yaml
# deploy.yaml (Akash SDL)
version: "2.0"
services:
  dagent-worker:
    image: dagent/worker:latest
    expose:
      - port: 8080
        as: 80
        to:
          - global: true
    env:
      - WORKER_NAME=akash-worker-01
      - CHAIN=sui
    
deployment:
  dagent-worker:
    akash:
      profile: dagent-worker
      count: 1

profiles:
  compute:
    dagent-worker:
      resources:
        cpu:
          units: 4
        memory:
          size: 8Gi
        storage:
          size: 100Gi
  placement:
    akash:
      pricing:
        dagent-worker:
          denom: uakt
          amount: 1000
```

**成本对比** (4 vCPU, 8GB RAM):
```
AWS EC2:     $0.10/小时 = $72/月
DigitalOcean: $0.06/小时 = $43/月
Akash:        $0.01/小时 = $7/月  (节省 85%)
```

---

## 4. pi-worker 多平台部署策略

### 4.1 统一抽象层

```typescript
// 定义统一接口
interface ComputeBackend {
  // 部署应用
  deploy(config: DeployConfig): Promise<Deployment>;
  
  // 获取状态
  getStatus(deploymentId: string): Promise<Status>;
  
  // 获取日志
  getLogs(deploymentId: string): Promise<Log[]>;
  
  // 更新应用
  upgrade(deploymentId: string, newConfig: DeployConfig): Promise<void>;
  
  // 销毁应用
  destroy(deploymentId: string): Promise<void>;
  
  // 获取成本
  getCostEstimate(config: DeployConfig): Promise<CostEstimate>;
}

// EigenCompute 实现
class EigenComputeBackend implements ComputeBackend {
  private cli: EigenCloudCLI;
  
  async deploy(config: DeployConfig) {
    // 使用 ecloud CLI
    const result = await this.cli.deploy({
      image: config.image,
      env: config.env,
      instanceType: config.resources.cpu > 4 ? 'g1-standard-4t' : 'g1-standard-2t',
      verifiable: config.tee || false,
    });
    
    return {
      id: result.appId,
      endpoint: result.publicIp,
      teeAttestation: result.attestation,
    };
  }
  
  // ... 其他方法
}

// Akash 实现
class AkashBackend implements ComputeBackend {
  private client: AkashClient;
  
  async deploy(config: DeployConfig) {
    // 生成 SDL
    const sdl = this.generateSDL(config);
    
    // 创建部署
    const deployment = await this.client.createDeployment(sdl);
    
    // 等待租约
    const lease = await this.client.awaitLease(deployment);
    
    return {
      id: deployment.dseq,
      endpoint: lease.uri,
      provider: lease.provider,
    };
  }
  
  // ... 其他方法
}

// ICP 实现 (混合模式)
class ICPBackend implements ComputeBackend {
  private actor: any;
  
  async deploy(config: DeployConfig) {
    // 在 ICP 注册 Worker
    const workerId = await this.actor.register_worker({
      name: config.name,
      capabilities: config.capabilities,
      endpoint: config.externalEndpoint, // Worker 实际运行在外部
    });
    
    return {
      id: workerId,
      endpoint: `https://${this.canisterId}.ic0.app`,
      type: 'icp-hybrid',
    };
  }
}
```

### 4.2 部署配置示例

```yaml
# dagent-deployment.yaml
version: "1.0"

worker:
  name: "my-dagent-worker"
  image: "dagent/worker:v1.0.0"
  
  capabilities:
    - code-generation
    - code-review
    - testing
  
  resources:
    cpu: 4
    memory: 8GB
    storage: 100GB
    gpu: false
  
  chain:
    network: sui_mainnet
    wallet: "${WALLET_PRIVATE_KEY}"
  
  # 选择后端平台
  backend:
    # 选项 1: EigenCompute (TEE + 验证)
    eigencompute:
      enabled: true
      instance_type: g1-standard-4t
      verifiable: true
      region: us-east
    
    # 选项 2: Akash (低成本)
    akash:
      enabled: false
      denom: uakt
      max_price: 1000  # uakt per block
    
    # 选项 3: ICP (混合)
    icp:
      enabled: false
      canister_id: "aaaaa-aa"
      external_worker: true

  # 环境变量
  env:
    LOG_LEVEL: info
    MAX_CONCURRENT_TASKS: 5
    OPENAI_API_KEY: "${OPENAI_API_KEY}"
```

### 4.3 CLI 多平台部署

```bash
# 部署到 EigenCompute
dagent deploy --backend eigencompute --config dagent-deployment.yaml

# 部署到 Akash
dagent deploy --backend akash --config dagent-deployment.yaml

# 部署到 ICP (混合模式)
dagent deploy --backend icp --config dagent-deployment.yaml

# 部署到本地 (开发测试)
dagent deploy --backend local

# 查看所有部署
dagent deployments list

# 切换平台
dagent deployments migrate <deployment-id> --to akash
```

---

## 5. 平台选择决策树

### 5.1 根据需求选择

```
需要硬件级安全 (TEE)?
├─ 是 → 预算充足?
│   ├─ 是 → EigenCompute (Intel TDX, 链上验证)
│   └─ 否 → Phala Network (Intel SGX, 波卡生态)
└─ 否 → 需要完全去中心化?
    ├─ 是 → 需要运行完整后端?
    │   ├─ 是 → ICP (Canister 运行)
    │   └─ 否 → Akash (K8s 容器)
    └─ 否 → 追求最低成本?
        ├─ 是 → Akash (比 AWS 便宜 85%)
        └─ 否 → 传统 VPS (DigitalOcean/Linode)
```

### 5.2 场景推荐

| 场景 | 推荐平台 | 理由 |
|------|----------|------|
| **企业级安全** | EigenCompute | 硬件 TEE + 链上证明 |
| **极低成本** | Akash | 比传统云便宜 80%+ |
| **完全去中心化** | ICP | 无服务器，链上运行 |
| **波卡生态** | Phala | 生态互通，SGX 成熟 |
| **快速启动** | VPS | 简单直接，无需学习 |

---

## 6. 综合建议

### 6.1 dAgent Network 部署策略

```
Phase 1: MVP (现在 - 3个月)
├─ 主平台: VPS (DigitalOcean/Linode)
├─ 原因: 简单快速，成本可控
├─ 目标: 验证产品假设
└─ 成本: $24-48/月

Phase 2: 扩展 (3-6个月)
├─ 添加: Akash Network
├─ 原因: 低成本，Docker 兼容
├─ 目标: 降低 Worker 运营成本
└─ 成本: $5-10/月 (比 VPS 省 70%)

Phase 3: 安全增强 (6-12个月)
├─ 添加: EigenCompute (可选)
├─ 原因: TEE 安全保障
├─ 目标: 企业客户信任
└─ 成本: $30-50/月

Phase 4: 完全去中心化 (12个月+)
├─ 添加: ICP 混合模式
├─ 原因: 完全链上逻辑
├─ 目标: 最大化去中心化
└─ 成本: 按实际使用
```

### 6.2 推荐架构

```
生产环境 (Production):
├─ 主部署: Akash Network (80%)
│  └─ 理由: 成本最低，成熟稳定
├─ 备份: VPS (15%)
│  └─ 理由: Akash 无可用时兜底
└─ 高端: EigenCompute (5%)
   └─ 理由: 企业级安全需求

开发环境 (Development):
└─ 本地 Docker
   └─ 零成本，快速迭代
```

### 6.3 成本优化

```
目标: 每月处理 1000 个任务

方案 A: 纯 VPS
├─ 4 台 VPS (4GB): $96/月
├─ 处理: 1000 任务
└─ 平均: $0.096/任务

方案 B: 纯 Akash
├─ 4 台 Akash (4GB): $28/月
├─ 处理: 1000 任务
└─ 平均: $0.028/任务

方案 C: 混合 (推荐)
├─ 3 台 Akash: $21/月
├─ 1 台 VPS: $24/月
├─ 处理: 1000 任务
└─ 平均: $0.045/任务
    ├─ 节省 53% vs 纯 VPS
    └─ 有 VPS 作为可靠备份
```

---

## 7. 总结

### 关键洞察

| 平台 | 核心优势 | 主要局限 | 适用阶段 |
|------|----------|----------|----------|
| **EigenCompute** | 硬件 TEE，链上验证 | 早期，较贵 | 企业级 (后期) |
| **ICP** | 完全去中心化 | 学习曲线陡峭 | 混合模式 (中期) |
| **Akash** | 极低成本，Docker 原生 | 无 TEE | 主力平台 (现在) |
| **Phala** | SGX 成熟，波卡生态 | 知名度较低 | 备选 (可选) |

### 一句话建议

> **先用 Akash Network (低成本 + Docker 兼容) 启动，逐步引入 EigenCompute (TEE 安全) 和 ICP (完全去中心化)，构建分层去中心化计算网络。**

### 实施优先级

1. **现在**: VPS (快速启动)
2. **1个月**: Akash (降低成本)
3. **3个月**: EigenCompute (企业安全)
4. **6个月**: ICP (混合增强)

---

## 参考链接

- [EigenCompute](https://deploy-to-eigen-compute.vercel.app)
- [ICP](https://internetcomputer.org)
- [Akash Network](https://akash.network)
- [Phala Network](https://phala.network)
- [Secret Network](https://scrt.network)

---

*本文档与 dAgent 去中心化计算策略同步更新*
