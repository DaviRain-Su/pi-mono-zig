# 去中心化 Worker 部署完全指南

> 从个人电脑到企业级集群的部署方案详解

---

## 1. 核心问题解答

### 1.1 "去中心化 = 自己运行服务器？"

**答案：是的，但有多种方式**

```
去中心化的本质是：
├─ 没有单一平台控制所有 Worker
├─ 用户可以选择在哪里运行
├─ 任何人都可以成为 Worker 提供者
└─ 但也意味着需要自己负责运维

对比：
┌─────────────────────────────────────────────────────────────┐
│ 中心化 (Slock.ai/Cloudflare)                                │
│ ├─ 平台运维服务器                                            │
│ ├─ 用户只使用服务                                            │
│ └─ 简单但无控制权                                            │
├─────────────────────────────────────────────────────────────┤
│ 去中心化 (dAgent)                                           │
│ ├─ 用户自己选择服务器                                        │
│ ├─ 可以是自己的电脑/云服务器/数据中心                         │
│ ├─ 有控制权但要自己运维                                       │
│ └─ 或者委托给第三方（但仍保留数据所有权）                      │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 部署方案全景

### 2.1 五层部署模型

```
Level 1: 个人本地 (免费)
├─ 自己的笔记本电脑/台式机
├─ 树莓派/旧电脑
├─ 适合：开发者自用、测试
└─ 成本：$0/月

Level 2: 家庭服务器 (低成本)
├─ 家用 NAS (Synology/QNAP)
├─ 迷你主机 (Intel NUC)
├─ 适合：极客、家庭自动化
└─ 成本：$5-20/月 (电费)

Level 3: VPS/云服务器 (中等成本)
├─ DigitalOcean / Linode / Vultr
├─ AWS EC2 / GCP / Azure
├─ 适合：专业 Agent 服务商
└─ 成本：$20-200/月

Level 4: 专用服务器 (高成本)
├─ 裸金属服务器 (Bare Metal)
├─ GPU 实例 (AWS g4dn, GCP T4)
├─ 适合：高频任务、AI 训练
└─ 成本：$200-2000/月

Level 5: 数据中心/集群 (企业级)
├─ 自建机房
├─ Kubernetes 集群
├─ 适合：企业、大规模服务
└─ 成本：$2000+/月
```

### 2.2 方案对比表

| 方案 | 技术难度 | 稳定性 | 性能 | 成本 | 控制权 | 适合人群 |
|------|---------|--------|------|------|--------|----------|
| **个人电脑** | 低 | 低 | 中 | 免费 | 完全 | 开发者测试 |
| **家用服务器** | 中 | 中 | 中 | 低 | 完全 | 极客 |
| **VPS** | 中 | 高 | 中 | 中 | 高 | 专业开发者 |
| **云服务器** | 中 | 高 | 高 | 中高 | 高 | Agent 服务商 |
| **专用服务器** | 高 | 高 | 很高 | 高 | 完全 | 企业 |
| **托管服务** | 低 | 高 | 高 | 中 | 中 | 普通用户 |

---

## 3. 详细部署方案

### 方案一：个人电脑 (Level 1)

**谁适合**:
- 开发者自用 Agent
- 测试和开发
- 低频任务处理

**硬件要求**:
```yaml
最低配置:
  CPU: 4 核 (Intel i5 / AMD Ryzen 5)
  RAM: 8 GB
  存储: 50 GB SSD
  网络: 10 Mbps 上传

推荐配置:
  CPU: 8 核 (Intel i7 / AMD Ryzen 7)
  RAM: 16 GB
  存储: 100 GB SSD
  网络: 50 Mbps 上传
```

**部署步骤**:

```bash
# 1. 安装 Node.js 18+
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# 2. 安装 dAgent Worker
npm install -g @dagent/worker

# 3. 配置
cat > ~/.dagent/config.yaml <<EOF
worker:
  name: "my-local-worker"
  endpoint: "http://localhost:8080"
  capabilities:
    - code-generation
    - code-review
  pricing:
    model: per_task
    base_price: 5  # USDC
  chain:
    network: sui_mainnet
    wallet: "~/.dagent/wallet.json"
  
  # 本地优化
  local_mode: true
  hibernate_when_idle: true
  idle_timeout: 300  # 5分钟后休眠
EOF

# 4. 启动
dagent worker start

# 5. 后台运行 (使用 PM2)
npm install -g pm2
pm2 start dagent --name worker -- worker start
pm2 save
pm2 startup
```

**网络配置** (如果需要外网访问):
```bash
# 方案 A: ngrok (临时)
npm install -g ngrok
ngrok http 8080
# 获得 https://xxx.ngrok.io

# 方案 B: Cloudflare Tunnel (推荐)
npm install -g cloudflared
cloudflared tunnel create dagent-worker
cloudflared tunnel route dns dagent-worker worker.yourdomain.com
cloudflared tunnel run dagent-worker

# 方案 C: 动态 DNS + 端口转发
# 路由器设置端口转发 8080 -> 你的电脑
# 使用 noip.com 等动态 DNS
```

**优缺点**:
- ✅ 零额外成本
- ✅ 完全控制
- ✅ 数据本地
- ❌ 需要保持开机
- ❌ 网络不稳定
- ❌ IP 变动

---

### 方案二：VPS 云服务器 (Level 3)

**谁适合**:
- 专业 Agent 开发者
- 需要 24/7 在线
- 想要赚取 USDC

**推荐 VPS 服务商**:

| 服务商 | 配置 | 价格 | 特点 |
|--------|------|------|------|
 **DigitalOcean** | 4GB/2CPU | $24/月 | 简单、SSD |
| **Linode** | 4GB/2CPU | $24/月 | 老牌、稳定 |
| **Vultr** | 4GB/2CPU | $24/月 | 按小时计费 |
| **Hetzner** | 8GB/4CPU | €12/月 | 欧洲、便宜 |
| **AWS Lightsail** | 4GB/2CPU | $20/月 | AWS 生态 |

**部署步骤** (以 DigitalOcean 为例):

```bash
# 1. 创建 Droplet (Ubuntu 22.04)
# 选择: 4GB RAM / 2 vCPU / 80GB SSD

# 2. SSH 登录
ssh root@your-droplet-ip

# 3. 安装 Docker
curl -fsSL https://get.docker.com | sh
systemctl enable docker
usermod -aG docker $USER

# 4. 创建配置文件
mkdir -p /opt/dagent
cat > /opt/dagent/config.yaml <<EOF
worker:
  name: "cloud-worker-01"
  endpoint: "0.0.0.0:8080"
  capabilities:
    - code-generation
    - code-review
    - testing
  pricing:
    model: per_task
    base_price: 10
  chain:
    network: sui_mainnet
    wallet: "/opt/dagent/wallet.json"
  
  # 生产优化
  max_concurrent_tasks: 5
  timeout: 300000  # 5分钟
EOF

# 5. 创建钱包
# 保存私钥到 /opt/dagent/wallet.json

# 6. 运行 Worker (Docker)
docker run -d \
  --name dagent-worker \
  --restart unless-stopped \
  -p 8080:8080 \
  -v /opt/dagent:/data \
  -e CONFIG_PATH=/data/config.yaml \
  dagent/worker:latest

# 7. 设置防火墙
ufw allow 8080/tcp
ufw enable

# 8. 设置监控
# 安装 node-exporter 用于 Prometheus 监控
docker run -d \
  --name node-exporter \
  --restart unless-stopped \
  -p 9100:9100 \
  prom/node-exporter
```

**使用 Docker Compose** (推荐):

```yaml
# /opt/dagent/docker-compose.yaml
version: '3.8'

services:
  worker:
    image: dagent/worker:latest
    container_name: dagent-worker
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - ./config.yaml:/data/config.yaml
      - ./wallet.json:/data/wallet.json
      - worker-data:/data/storage
    environment:
      - NODE_ENV=production
      - LOG_LEVEL=info
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  # 可选: 监控
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus-data:/prometheus

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - "3000:3000"
    volumes:
      - grafana-data:/var/lib/grafana

volumes:
  worker-data:
  prometheus-data:
  grafana-data:
```

```bash
# 启动
cd /opt/dagent
docker-compose up -d

# 查看日志
docker-compose logs -f worker

# 更新
docker-compose pull
docker-compose up -d
```

**优缺点**:
- ✅ 24/7 在线
- ✅ 固定 IP
- ✅ 专业稳定
- ❌ 需要运维知识
- ❌ 月费 $20-50
- ❌ 需要配置安全

---

### 方案三：Kubernetes 集群 (Level 5)

**谁适合**:
- Agent 服务商 (公司)
- 需要管理多个 Worker
- 要求弹性扩缩容

**架构图**:
```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌───────────────────────────────────────────────────────┐ │
│  │                 Ingress Controller                     │ │
│  │              (Nginx / Traefik / Cilium)                │ │
│  └───────────────────────┬───────────────────────────────┘ │
│                          │                                  │
│  ┌───────────────────────┴───────────────────────────────┐ │
│  │                 Worker Service                         │ │
│  │                    (Load Balancer)                     │ │
│  └───────────────────────┬───────────────────────────────┘ │
│                          │                                  │
│         ┌────────────────┼────────────────┐                 │
│         ▼                ▼                ▼                 │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐       │
│  │  Worker Pod  │ │  Worker Pod  │ │  Worker Pod  │       │
│  │      1       │ │      2       │ │      N       │       │
│  └──────────────┘ └──────────────┘ └──────────────┘       │
│                                                             │
│  HPA (Horizontal Pod Autoscaler):                           │
│  ├─ minReplicas: 3                                          │
│  ├─ maxReplicas: 100                                        │
│  └─ targetCPUUtilizationPercentage: 70                      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**部署配置**:

```yaml
# worker-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dagent-worker
  labels:
    app: dagent-worker
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
        ports:
        - containerPort: 8080
        env:
        - name: NODE_ENV
          value: "production"
        - name: WORKER_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        resources:
          requests:
            memory: "4Gi"
            cpu: "2000m"
          limits:
            memory: "8Gi"
            cpu: "4000m"
        volumeMounts:
        - name: config
          mountPath: /data/config.yaml
          subPath: config.yaml
        - name: wallet
          mountPath: /data/wallet.json
          subPath: wallet.json
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
      volumes:
      - name: config
        configMap:
          name: dagent-config
      - name: wallet
        secret:
          secretName: dagent-wallet

---
# HPA 自动扩缩容
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: dagent-worker-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: dagent-worker
  minReplicas: 3
  maxReplicas: 100
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 100
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60

---
# Service
apiVersion: v1
kind: Service
metadata:
  name: dagent-worker-service
spec:
  selector:
    app: dagent-worker
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8080
  type: ClusterIP

---
# Ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dagent-worker-ingress
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  tls:
  - hosts:
    - worker.yourdomain.com
    secretName: worker-tls
  rules:
  - host: worker.yourdomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: dagent-worker-service
            port:
              number: 80
```

**部署命令**:
```bash
# 1. 创建命名空间
kubectl create namespace dagent

# 2. 创建配置和密钥
kubectl create configmap dagent-config \
  --from-file=config.yaml \
  -n dagent

kubectl create secret generic dagent-wallet \
  --from-file=wallet.json \
  -n dagent

# 3. 部署
kubectl apply -f worker-deployment.yaml -n dagent

# 4. 查看状态
kubectl get pods -n dagent -w
kubectl logs -f deployment/dagent-worker -n dagent

# 5. 监控
kubectl top pods -n dagent
```

**K8s 托管服务选项**:

| 服务商 | 价格 | 特点 |
|--------|------|------|
| **AWS EKS** | $72/月 + 资源 | 企业级、复杂 |
| **GCP GKE** | 免费控制平面 | 易用、集成好 |
| **Azure AKS** | 免费控制平面 | 微软生态 |
| **DigitalOcean K8s** | $12/节点 | 简单、便宜 |
| **Linode K8s** | $12/节点 | 老牌稳定 |

**优缺点**:
- ✅ 弹性扩缩容
- ✅ 高可用
- ✅ 专业运维
- ❌ 复杂度高
- ❌ 成本 $100+/月
- ❌ 需要 K8s 知识

---

## 4. 成本对比分析

### 4.1 月度成本估算

| 方案 | 硬件/服务 | 电费/网络 | 总成本 | 适合任务量 |
|------|----------|----------|--------|-----------|
| **个人电脑** | $0 | $10 | $10 | < 100 任务/月 |
| **VPS (4GB)** | $24 | $0 | $24 | 100-500 任务/月 |
| **VPS (8GB)** | $48 | $0 | $48 | 500-2000 任务/月 |
| **云服务器** | $100-500 | $0 | $100-500 | 2000+ 任务/月 |
| **K8s 集群** | $200+ | $0 | $200+ | 企业级 |

### 4.2 盈亏平衡点

假设平均任务价格 20 USDC，Worker 获得 90% = 18 USDC:

| 方案 | 月成本 | 盈亏任务数 | 每天需要 |
|------|--------|-----------|---------|
| 个人电脑 | $10 | 1 任务 | 0.3 任务 |
| VPS (4GB) | $24 | 2 任务 | 0.7 任务 |
| VPS (8GB) | $48 | 3 任务 | 1 任务 |
| 云服务器 | $200 | 12 任务 | 4 任务 |
| K8s | $500 | 28 任务 | 9 任务 |

**结论**: 只要每天有 1-2 个任务，VPS 就能盈亏平衡。

---

## 5. 选择建议

### 5.1 决策树

```
你是开发者吗？
├─ 是 → 有闲置电脑吗？
│   ├─ 是 → 本地运行 (免费)
│   └─ 否 → 购买 VPS ($24/月)
└─ 否 → 需要 24/7 在线吗？
    ├─ 是 → 需要多 Worker 吗？
    │   ├─ 是 → Kubernetes ($200+/月)
    │   └─ 否 → VPS ($24/月)
    └─ 否 → 使用托管服务 (平台提供)
```

### 5.2 分阶段建议

```
阶段 1: 测试验证
├─ 本地电脑
├─ 免费
└─ 验证 Agent 能力

阶段 2: 上线运营
├─ VPS (DigitalOcean/Linode)
├─ $24-48/月
└─ 开始赚取 USDC

阶段 3: 规模扩大
├─ 云服务器或 K8s
├─ $100+/月
└─ 处理大量任务

阶段 4: 企业级
├─ 多区域部署
├─ 专用服务器
└─ 企业 SLA
```

---

## 6. 常见问题

### Q1: 我没有服务器，能参与吗？

**A**: 可以，选择：
1. 先用个人电脑测试
2. 购买便宜的 VPS ($12/月起)
3. 等待平台提供托管服务

### Q2: 服务器在国外，会有延迟吗？

**A**: 
- 选择靠近用户的服务器区域
- 建议：美国用户 → 美国服务器，亚洲用户 → 新加坡/东京服务器
- 或者运行多个区域节点

### Q3: 如何确保服务器不宕机？

**A**:
- 使用 `systemd` 或 `pm2` 自动重启
- 配置健康检查
- 使用 Docker 简化部署
- 监控 + 告警 (Prometheus + Grafana)

### Q4: 数据安全吗？

**A**:
- 数据存储在你自己的服务器
- 使用防火墙 (ufw/iptables)
- 定期备份钱包
- 敏感配置用环境变量/密钥管理

### Q5: 可以多个 Worker 在一台服务器吗？

**A**: 可以，使用 Docker 容器化：
```bash
docker run -d -p 8081:8080 dagent/worker --name worker-1
docker run -d -p 8082:8080 dagent/worker --name worker-2
docker run -d -p 8083:8080 dagent/worker --name worker-3
```

---

## 7. 总结

### 去中心化 ≠ 必须自己维护机房

```
去中心化的真正含义：
├─ 你可以选择任何基础设施
├─ 可以是自己的电脑
├─ 可以是租用的云服务器
├─ 可以是托管服务 (只要数据可控)
└─ 关键是选择权在用户，不是强制平台
```

### 推荐入门路径

```
1. 本地测试 (免费)
   $ npm install -g @dagent/worker
   $ dagent worker start

2. 购买 VPS ($24/月)
   DigitalOcean / Linode / Vultr

3. Docker 部署
   $ docker run dagent/worker

4. 赚取 USDC
   每天 1-2 个任务即可盈亏平衡

5. 扩大规模
   根据需要升级配置
```

---

## 参考链接

- [DigitalOcean](https://www.digitalocean.com/)
- [Linode](https://www.linode.com/)
- [Docker Docs](https://docs.docker.com/)
- [Kubernetes Docs](https://kubernetes.io/docs/)

---

*本文档与 dAgent Worker 部署指南同步更新*
