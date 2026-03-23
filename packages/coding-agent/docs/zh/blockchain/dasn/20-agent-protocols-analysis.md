# Agent 协议标准全景分析

> ERC-8004、Solana Agent Registries、Vouch Protocol 与 DASN 的对比分析

---

## 协议标准总览

```
┌─────────────────────────────────────────────────────────────────────┐
                        Agent 协议栈全景                                │
├─────────────────────────────────────────────────────────────────────┤
│  应用层                                                               │
│  ├── A2A (Google) - Agent-to-Agent 通信                              │
│  └── MCP (Anthropic) - Model Context Protocol                        │
├─────────────────────────────────────────────────────────────────────┤
│  身份与信任层 (新兴)                                                   │
│  ├── ERC-8004 (以太坊) - Trustless Agents                           │
│  ├── AEA/MCP Registries (Solana) - openSVM                          │
│  ├── Vouch Protocol (Solana) - Trust Layer                          │
│  └── DASN (pi-mono) - 去中心化 Agent 服务网络                         │
├─────────────────────────────────────────────────────────────────────┤
│  支付层                                                               │
│  ├── x402 (以太坊) - HTTP 402 Payment                               │
│  └── 原生 SPL Token (Solana)                                         │
├─────────────────────────────────────────────────────────────────────┤
│  数据层                                                               │
│  ├── IPFS / Arweave - 去中心化存储                                   │
│  └── 链上存储 (智能合约)                                              │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 一、ERC-8004 (以太坊)

### 核心定位
**Trustless Agents** - 无信任 Agent 身份与声誉标准

> "使用区块链在组织边界之间发现、选择和交互 Agent，无需预先存在的信任"

### 三个核心注册表

```solidity
// 1. Identity Registry (身份注册表)
- ERC-721 NFT 作为 Agent 唯一标识
- agentURI 指向 Agent Card JSON
- 支持 ENS、DID 绑定

// 2. Reputation Registry (声誉注册表)
- 有界数值评分 (int128 + decimals)
- 标签系统 (tag1, tag2)
- 可撤销反馈
- 支持响应 (Response)

// 3. Validation Registry (验证注册表)
- 任务完成证明
- 输出正确性验证
- 约束满足证明
// ⚠️ 仍在设计阶段
```

### Agent Card 结构

```json
{
  "type": "https://eips.ethereum.org/EIPS/eip-8004#registration-v1",
  "name": "myAgentName",
  "description": "...",
  "services": [
    {"name": "A2A", "endpoint": "...", "version": "0.3.0"},
    {"name": "MCP", "endpoint": "...", "version": "2025-06-18"},
    {"name": "x402", "endpoint": "..."}
  ],
  "supportedTrust": ["reputation", "crypto-economic", "tee-attestation"]
}
```

### 关键特性

| 特性 | 说明 |
|------|------|
| **标准层级** | 应用层标准 (ERC) |
| **链选择** | 以太坊为主，可跨链 |
| **身份模型** | ERC-721 NFT |
| **声誉模型** | 评分 + 标签 |
| **验证模型** | 开放式，多策略 |
| **支付集成** | x402 |
| **通信协议** | A2A, MCP |

### 优势
- ✅ 机构背书 (MetaMask, Ethereum Foundation, Google, Coinbase)
- ✅ 与现有标准集成 (A2A, MCP, x402, ENS)
- ✅ 模块化信任模型
- ✅ 可验证的链上声誉

### 局限
- ❌ 仅解决身份/信任，不解决执行
- ❌ 以太坊 Gas 成本较高
- ❌ 验证注册表仍在设计
- ❌ 无内置经济激励机制

---

## 二、AEA/MCP Solana Registries (openSVM)

### 核心定位
**Solana 上的 Agent 和 MCP 服务器注册协议**

> "为发现和验证自主 AI Agent 和 Model Context Protocol 服务器提供基础设施"

### 架构设计

```rust
// Agent Registry Program
pub struct AgentRegistryEntryV1 {
    pub agent_id: String,                    // 唯一标识
    pub name: String,
    pub description: String,
    pub agent_version: String,
    pub provider_name: Option<String>,
    pub service_endpoints: Vec<ServiceEndpoint>,  // A2A/MCP/HTTP
    pub skills: Vec<AgentSkill>,
    pub capabilities_flags: u32,             // 能力标志
    pub security_info_uri: Option<String>,
    pub extended_metadata_uri: Option<String>,  // IPFS
}

// MCP Server Registry Program
pub struct McpServerRegistryEntryV1 {
    pub server_id: String,
    pub name: String,
    pub service_endpoint: String,
    pub onchain_tool_definitions: Vec<McpToolDefinition>,
    pub onchain_resource_definitions: Vec<McpResourceDefinition>,
    pub full_capabilities_uri: Option<String>,
}
```

### 混合存储模型

```
链上 (Solana):
├── 核心身份数据
├── 端点 URL
├── 能力标志
└── 元数据哈希

链下 (IPFS):
├── 详细描述
├── 完整能力定义
├── 文档
└── 扩展元数据
```

### 关键特性

| 特性 | 说明 |
|------|------|
| **标准层级** | 基础设施层 (链上程序) |
| **链选择** | Solana 专用 |
| **身份模型** | PDA (Program Derived Address) |
| **存储模型** | 混合 (链上+IPFS) |
| **发现机制** | PDA 派生查找 + 事件索引 |
| **技能注册** | 支持结构化技能定义 |
| **MCP 支持** | 原生 MCP 服务器注册 |

### 优势
- ✅ Solana 高性能/低成本
- ✅ 专门的 MCP 服务器注册
- ✅ 结构化技能定义
- ✅ PDA 直接查找 (无索引器也可)
- ✅ 混合存储降低成本

### 局限
- ❌ 无内置声誉系统
- ❌ 无经济激励机制
- ❌ 无支付层集成
- ❌ Solana 生态系统局限

---

## 三、Vouch Protocol (Solana)

### 核心定位
**Solana 上 AI Agent 的信任层**

> "链上身份和行为声誉。免费使用。任何协议可通过 CPI 验证 Agent 信任。任何 AI 模型可通过 MCP 发现 Agent。"

### 三层信任模型

```rust
// 1. 身份层 (Identity)
pub struct AgentIdentity {
    pub owner: Pubkey,
    pub name: String,
    pub service_category: String,
    pub agent_card_url: String,
    pub agent_card_hash: [u8; 32],  // SHA-256
    pub did: String,  // did:sol:<pubkey>
}

// 2. 经济层 (Economic)
pub struct AgentStake {
    pub usdc_amount: u64,
    pub tier: AgentTier,  // Observer/Basic/Standard/Verified/Enterprise
    pub withdrawal_cooldown: i64,  // 1-90 天
}

// 3. 声誉层 (Reputation)
pub struct AgentReputation {
    pub score: u16,  // 0-1000
    pub cross_protocol_reports: Vec<BehaviorReport>,
}
```

### 信任等级 (Tiers)

| 等级 | USDC 质押 | 说明 |
|------|----------|------|
| Observer | $0 | 仅身份+声誉 |
| Basic | 可配置 | 基础承诺 |
| Standard | 可配置 | 标准信任 |
| Verified | 可配置 | 高信任 |
| Enterprise | 可配置 | 企业级 |

### 集成方式

```rust
// 1. CPI 集成 (链上程序)
require_vouch_active!(ctx.accounts.agent);
require_vouch_tier!(ctx.accounts.agent, AgentTier::Standard);
require_vouch_reputation!(ctx.accounts.agent, 600);

// 2. TypeScript SDK (链下)
const agent = await registry.fetchAgentByOwner(pk);
if (agent.status === "Active" && agent.tier === "Standard") {
  // 验证通过
}

// 3. MCP 工具 (AI 模型)
const result = await mcp.callTool("verify_agent", { ownerPubkey });
```

### 关键特性

| 特性 | 说明 |
|------|------|
| **标准层级** | 基础设施层 (信任层) |
| **链选择** | Solana 专用 |
| **身份模型** | PDA + W3C DID |
| **经济模型** | USDC 质押 + 等级 |
| **声誉模型** | 0-1000 分数 + 行为报告 |
| **验证方式** | CPI / SDK / MCP |
| **可提取性** | 全额可提取 (7天冷却期) |

### 优势
- ✅ 免费使用
- ✅ 无 KYC
- ✅ 多集成方式 (CPI/SDK/MCP/DID)
- ✅ 双信任信号 (质押+声誉)
- ✅ 防闪电贷 (冷却期)
- ✅ 符合多个标准 (W3C DID, A2A, MCP)

### 局限
- ❌ 仅解决信任，不解决执行协调
- ❌ 声誉算法中心化 (由协议定义)
- ❌ 无内置争议解决
- ❌ 无任务分配机制

---

## 四、协议对比矩阵

| 维度 | ERC-8004 | AEA/MCP Registries | Vouch Protocol | DASN (pi-mono) |
|------|----------|-------------------|----------------|----------------|
| **定位** | 身份/声誉标准 | Agent/MCP 注册 | 信任层 | 完整服务网络 |
| **层级** | 应用层 (ERC) | 基础设施 | 基础设施 | 应用+经济层 |
| **链** | 以太坊 | Solana | Solana | Solana/Sui |
| **身份** | ERC-721 | PDA | PDA+DID | Worker 对象 |
| **声誉** | 评分+标签 | ❌ | 分数+行为 | 任务历史+评分 |
| **经济** | ❌ | ❌ | 质押(可退) | 质押+奖励+惩罚 |
| **任务** | ❌ | ❌ | ❌ | 核心功能 |
| **支付** | x402 集成 | ❌ | ❌ | 内置结算 |
| **争议** | ❌ | ❌ | ❌ | 仲裁机制 |
| **执行** | ❌ | ❌ | ❌ | pi-worker |

---

## 五、DASN 与现有协议的整合

### 整合策略

DASN 不是替代，而是**整合与扩展**：

```
┌────────────────────────────────────────────────────────────┐
│  DASN 架构 (整合版)                                          │
├────────────────────────────────────────────────────────────┤
│  应用层                                                       │
│  ├── A2A / MCP - 通信标准 (复用)                              │
│  └── pi-worker - 执行引擎 (独创)                              │
├────────────────────────────────────────────────────────────┤
│  身份与信任层                                                  │
│  ├── ERC-8004 (以太坊) - 可选身份标准                          │
│  ├── Vouch (Solana) - 可选信任验证                             │
│  └── DASN Worker Registry - 核心身份+声誉+经济                 │
├────────────────────────────────────────────────────────────┤
│  任务协调层 (DASN 核心)                                        │
│  ├── Task Marketplace - 任务发布与发现                          │
│  ├── Worker Selection - 选择算法                               │
│  ├── Payment Escrow - 资金托管                                 │
│  └── Dispute Resolution - 争议仲裁                             │
├────────────────────────────────────────────────────────────┤
│  区块链层                                                     │
│  ├── Solana - 主链 (高性能)                                   │
│  ├── Sui - 备选 (对象模型优势)                                 │
│  └── 跨链桥 - 未来扩展                                        │
└────────────────────────────────────────────────────────────┘
```

### 具体整合方式

#### 1. 身份层整合

```typescript
// DASN Worker 可以同时注册多个身份系统
interface WorkerIdentity {
  // DASN 核心身份
  dasnId: string;
  
  // 可选: ERC-8004 (以太坊)
  erc8004Id?: string;  // ERC-721 tokenId
  
  // 可选: Vouch (Solana)
  vouchPda?: string;
  
  // 可选: AEA Registry
  aeaAgentId?: string;
  
  // 统一标识
  did?: string;  // did:sol:... 或 did:eth:...
}
```

#### 2. 信任层整合

```typescript
// 多源声誉聚合
interface WorkerReputation {
  // DASN 内部声誉
  dasnScore: number;
  completedTasks: number;
  disputeRate: number;
  
  // 外部声誉 (可选)
  erc8004Rating?: number;  // 来自 ERC-8004 Reputation Registry
  vouchScore?: number;     // 来自 Vouch Protocol
  vouchTier?: string;      // Vouch 等级
  
  // 聚合分数
  aggregateScore(): number {
    // 加权平均
    return (this.dasnScore * 0.6) + 
           ((this.vouchScore || 500) * 0.4);
  }
}
```

#### 3. 通信层整合

```typescript
// Worker 支持多种通信协议
class DASNWorker {
  // A2A 支持
  async handleA2ARequest(request: A2ARequest): Promise<A2AResponse> {
    // 解析为 DASN 任务
    const task = this.convertFromA2A(request);
    const result = await this.execute(task);
    return this.convertToA2A(result);
  }
  
  // MCP 支持
  async handleMCPToolCall(call: MCPToolCall): Promise<MCPResult> {
    // 将 MCP 工具调用映射为 DASN 能力
    const capability = this.mapMCPTool(call.name);
    return await this.executeCapability(capability, call.args);
  }
  
  // DASN 原生协议
  async handleDASNTask(task: DASNTask): Promise<DASNResult> {
    // 直接执行
    return await this.execute(task);
  }
}
```

---

## 六、DASN 的差异化优势

### 1. 完整闭环

| 协议 | 身份 | 信任 | 任务 | 支付 | 争议 | 执行 |
|------|------|------|------|------|------|------|
| ERC-8004 | ✅ | ✅ | ❌ | ⚠️ | ❌ | ❌ |
| AEA Registries | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Vouch | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| **DASN** | **✅** | **✅** | **✅** | **✅** | **✅** | **✅** |

### 2. 执行层优势

**其他协议**: 只定义"如何发现 Agent"
**DASN**: 定义"如何执行任务并保证质量"

```
标准协议流程:
发现 Agent → 连接 Agent → ??? (执行细节未定义)

DASN 流程:
发布任务 → 市场匹配 → Worker 执行 → 链下证明 → 链上结算 → 声誉更新
         ↑_______________________________________________↓
                    完整闭环，每个环节都有定义
```

### 3. 经济模型创新

**其他协议**: 身份注册费或无偿
**DASN**: 服务即挖矿

```
Worker 通过提供高质量服务获得奖励:
- 任务完成奖励 (80-90%)
- 质量奖金 (基于声誉)
- 时效奖金 (快速完成)
- 长期声誉价值 (接单优先级)
```

### 4. 专业化分工

**其他协议**: Agent 是通用概念
**DASN**: Worker 是专业服务商

```
DASN Worker 可以专业化:
- 前端代码专家
- 智能合约审计师
- 测试用例生成器
- 文档撰写专家

Client 可以根据需求匹配最佳 Worker
```

---

## 七、未来整合路线图

### Phase 1: 协议兼容 (3个月)
- [ ] 支持 ERC-8004 Agent Card 格式
- [ ] 支持 Vouch Protocol 信任验证
- [ ] 支持 A2A 通信协议
- [ ] 支持 MCP 工具调用

### Phase 2: 跨链身份 (6个月)
- [ ] 以太坊 <> Solana 身份桥
- [ ] 统一 DID 解析
- [ ] 跨链声誉聚合

### Phase 3: 标准影响 (12个月)
- [ ] 向 ERC-8004 贡献任务执行标准
- [ ] 提出 DASN 作为 Agent 服务网络标准
- [ ] 与 Vouch 深度合作 (内置支持)

---

## 八、关键洞察

### 协议演进趋势

```
2024: MCP/A2A 定义通信标准
2025: ERC-8004/Vouch 定义身份/信任标准
2026: DASN 定义服务经济标准 ← 我们在这里
2027: 完整 Agent 互联网协议栈
```

### 每层的关键问题

| 层级 | 核心问题 | 当前状态 |
|------|---------|---------|
| 通信 | Agent 如何对话？ | ✅ MCP/A2A 解决 |
| 身份 | Agent 是谁？ | ✅ ERC-8004/Vouch 解决 |
| 信任 | 能否信任？ | ⚠️ 部分解决 |
| 执行 | 任务如何完成？ | ❌ 未解决 (DASN 解决) |
| 经济 | 如何付费？ | ❌ 未标准化 |
| 争议 | 出问题怎么办？ | ❌ 未解决 (DASN 解决) |

### DASN 的战略位置

DASN 填补了**最上层**的空白：
- 不是替代底层标准
- 而是**整合+扩展**底层标准
- 构建**完整的经济网络**

---

## 参考资源

### 协议文档
- [ERC-8004 EIP](https://eips.ethereum.org/EIPS/eip-8004)
- [AEA/MCP Solana Registries](https://github.com/openSVM/aeamcp)
- [Vouch Protocol](https://www.vouchprotocol.xyz/)

### DASN 相关
- [DASN 愿景](./19-dasn-vision.md)
- [Solana 专题](./)
- [Sui 专题](./sui/)

---

*本文档与 Agent 协议标准演进同步更新*
