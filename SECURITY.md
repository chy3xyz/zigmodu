# 安全策略（Security Policy）

**适用范围**：`chy3xyz/zigmodu` 及其示例、工具。
**版本**：0.39.10 · 状态：**pre-1.0（功能面冻结期）**

---

## 一、报告漏洞

**本文件是本项目唯一的漏洞报告入口。**

请**不要**用 GitHub Security Advisory 的公开表单提交未公开漏洞，
也**不要**在 issue 里公开 PoC——那会给未打补丁的用户一个可利用的窗口。

- **报告方式**：GitHub 私密的
  [Security Advisory](https://github.com/chy3xyz/zigmodu/security/advisories/new)
  （`Report a vulnerability`）
- **响应目标**：3 个工作日内确认收到，14 天内给出修复或缓解方案。

若你不愿用 GitHub 渠道，可直接在仓库主页找到维护者的联系方式并私聊索取加密通道。

### 报告里请包含

| 项 | 为什么需要 |
|---|---|
| 受影响文件:行| 本项目所有证据都是**文件:行** 粒度，没有这行定位无法复核 |
| **复现命令或步骤** | 本项目所有断言都是"读数 + 复现命令"形式，见 `docs/dev/reproducing-evidence.md` |
| 期望行为 vs 实际行为 | 区分"设计如此"与"真缺陷" |
| 影响面 | 是否涉及认证 / 租户隔离 / 密码学 / 解码路径 |

**能写成"插一个必失败断言 → 必红"的报告，优先级最高**——
本项目的门禁可以对任何断言做变异验证，你也可以这样验证我们的修复。

---

## 二、本项目承认的攻击面

这一节是**提前告知**，不是免责。它列出已知的、需要使用者自己设防的地方。

### 框架不负责的（使用者的责任）

| 事项 | 现状 | 使用者该做什么 |
|---|---|---|
| **集群传输机密性** | 帧是**明文 + 逐帧 HMAC-SHA256**（认证 + 完整性，**不是机密性**）。框架**刻意不内嵌 TLS** | 集群端口只放受信二层（VPC / 专线 / localhost）；跨信任边界在边车或 service mesh 终结 mTLS。可跑的参考拓扑：`examples/production-deploy/cluster-sidecar/` |
| **JWT 密钥的机密性** | 框架管轮换（`JwksKeyRing` 双 key 窗）与吊销，**但密钥本身的存储与分发不在框架职责内** | 用 secret 管理器注入，**不要**进仓库或镜像层 |
| **多租户模式的启用** | 租户隔离是 **opt-in**：模型上不声明 `sql_tenant_column` 就没有隔离 | 声明该字段（框架会让越权查询**编译失败**），并读 [`docs/BEST_PRACTICES.md`](docs/BEST_PRACTICES.md) 的租户节 |
| **SQL 输入** | 参数化由 sqlx 层负责；框架不提供字符串拼接的"辅助" | 一律走参数化；`*Unscoped` 变体是**显式的危险操作**，用它们要在 review 里点名 |

### 框架负责且有门禁的

| 面 | 门禁 |
|---|---|
| 随机数来源 | `zig build check`（`check-production.sh`）禁止 `std.Io.random`（失败时退回 pid+墙钟+ASLR）与所有非密码学 PRNG，必须用 `randomSecure` |
| 热路径裸`catch {}` | 同上门禁，热模块内裸吞异常即红 |
| 分配契约 | `src/runtime/alloc_contract_test.zig` 断言 mailbox / ring / HotBus / `send` / 定时器热路径**精确 0 分配** |
| 声明与实现一致 | `src/test/DocsConsistency.zig` 断言文档里的每个符号都存在于 `src/` |

### 明确不做（`⚠️` 标记的实验模块）

Saga、SecurityScanner、DistributedEventBus、ClusterMembership、2PC、Plugin、WebMonitor、HotReloader
**有测试，但没有生产记录**。`README.md`「它不是什么」一节列了全部边界。

---

## 三、支持范围

| 版本 | 状态 |
|---|---|
| **最新 minor（当前 0.39.x）** | 修复 |
| 上一个 minor | 仅安全修复 |
| 更早 | 不支持（0.x 无长期维护承诺，见 `docs/UPGRADING.md`） |

**这是 0.x 的现实**：99 个发布都在 0.x，**没有 LTS，也没有 backport 承诺**。
发布节奏与功能面冻结的约定见 `AGENTS.md`「发布节奏」。

---

## 四、披露口径

修复会进CHANGELOG 的下一批次条目；**致谢与否按报告者意愿**（`CONTRIBUTING.md`）。

**本项目的边界**：目前不标 CVE、不设赏金、不承诺 0.x 的 SLA。
理由是维护结构决定的（见 `GOVERNANCE.md`：单一所有者、无第三方审计）——
**与其让你以为有承诺，不如把边界写清楚**。等治理结构变化，这里会跟着改。