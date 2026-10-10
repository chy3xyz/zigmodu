# ZigModu 品质与竞争力评估 · 2026-10

> **取代 [`EVALUATION_REPORT.md`](EVALUATION_REPORT.md)**（那份标v5，评估日期 2026-08-27，
> 测试数 990/1009，12 维给 ~98/100）。那份快照早于 2026-09 起的加固批次，且把当时的版本号
> 填成了后来的 v0.39.10，**分数与其逐维读数一律作废**，保留原地是因为源码注释按路径引用它。
>
> 与 [`dev/v1.0-readiness-v0.35.md`](dev/v1.0-readiness-v0.35.md) 的分工：那份是**逐条差距台账**
> （A/B/C 组，判"能不能叫 1.0"），本文是**加权评分与竞争力定位**（判"值不值得用"）。
> 两者的等级**不可互换**——那份的 ~70% 与本文的 68 分说的是两件事，见 §五。
>
> **口径**：`v0.39.10` · `1008` 提交 · `src/` 284 文件 / 185,550 行 · Zig 0.17.0 · 零外部包依赖。
> **本文所有数字均为实测**，复现命令随附；判定只认代码与命令输出，文档旧结论一律复核不采信。

---

## 一、总分

**68 / 100** —— 技术质量 82，可信度 40。

| 维度 | 分 | 实测依据 |
|---|:--:|---|
| 工程纪律 / 可证伪性 | **88** | 2319/2382 测试实跑通过；`build.zig.zon` 零外部依赖；19 个门禁脚本；deadcode 单调棘轮（`--update` 拒绝增长，`--force` 才准记） |
| 运行时 / 性能设计 | **85** | 有界 mailbox（满了是 `error.Full`）、监督树、三级优先级就绪环、池化、`PrecisionTimer` p50 0 ns / p99 1 µs；分配预算是**契约测试**不是承诺 |
| 架构与覆盖面 | **82** | 28 个域全栈自有实现：HTTP/1.1 + H2 + WS + gRPC + SQLx（PG/MySQL/SQLite）+ Raft + 事件总线 + 集群认证 + 可观测 + AI |
| 文档质量 | **80** | 76 篇 / 28,196 行；DO/DON'T 表密度罕见；**但本文修正过 3 处数字漂移**（见 §四） |
| API 与 DX | **74** | ComptimeRouter（依赖图编译期校验 +拓扑自动生成）、`zmodu doctor`、`zmodu scaffold`；双 `zmodu` 入口等坑已在文档自陈 |
| **真实承载（新增轴）** | **70** | zenaipa 全栈平台 · zasdoor IAM 系统（**79 个后端测试**，吃 JWT/多租户/OIDC/会话吊销）。**扣分项是所有者同一**——见 §3.3 |
| 成熟度 / 稳定性 | **55** | 99 个发布**全在 0.x**；08 月 33 版 / 09 月 48 版 / 10 月 10 天 10 版；破坏性仅 6/99（这点是加分） |
| 生态 / 治理 | **18** | 1008 提交中`Antigravity Agent` 758 / `neox33` 220 / `ZigModu Developer` 29 / **仓库所有者 `chy3xyz` 1**；stars 3 · forks 0 · 外部贡献者 0 |
| 独立验证 | **20** | `README.md:225` 自陈"no independent audit"；所有闭环出自同一批 AI，**包括本文** |

---

## 二、真正的强项

1. **门禁矩阵是同类最认真的**。`ci.yml` 1,378 行 / 14 job：OS matrix、真实 PostgreSQL / MySQL、
   Redis + NATS + Kafka live、soak、benchmark、Windows cross、混合版本对跑。
   `check-test-collection.sh` 防"绿着跑了个空"——`docs/RUNTIME.md:2309` 那句
   `aggregate 6/2056 selected` 正是这条门禁的产物。
2. **无req/s 吹嘘**。README 只以"基线 + ratchet"承诺性能，唯一绝对数字是 h2c 9.3k req/s
   且注明测量口径。比堆benchmark 对比表的框架诚实。
3. **把架构规则交给编译器**。租户隔离写进 `sql_tenant_column` 变成编译期强制；
   `.pooled` 给`run` 型 worker 直接 `@compileError`。这是真正的差异化——
   文档里的规则会烂，编译器的不会。
4. **破坏性变更率 6/99**，且 `release.sh` 强制版本 / tag / CHANGELOG 三处一致，
   `check-release-tag.sh` + CI `release-verify` 双向把守。
5. **诚实文化**。§12.7「刻意还没有的」、README「它不是什么（采用前先定价）」、
   `TimerWheel x100K` 双峰"判定不修"并降级为候选回归——愿意写"这条我没做"的文档，
   比声称全绿的文档可信。

---

## 三、扣分项（按严重度）

### 3.1 独立验证缺失（B-14，唯一硬伤）

所有"已闭环"仍出自同一批 AI 维护者。`README.md:225-226` 自己写着：

> Every "done" here was produced by the same maintainers and their AI agents;
> **there has been no independent audit.**

第 150 批做到的是**可复现**（`docs/dev/reproducing-evidence.md` + artifact），
但"可复现"与"被验证"之间隔着一个人。这条不是靠继续写代码能关的。

### 3.2 治理（外部信任视角 ≈ 10%）

1 008 个提交里仓库所有者只有 1 个（还是 `Antigravity Agent` 之外的个人号`chy3xyz`），
stars 3 / forks 0 / 外部贡献者 0。**这不是代码质量问题，是"出问题时没人能帮你"的问题**——
这个差距与代码水平无关，因此它单独把总分从 82 拉到 68。

> **但要说清一个反例**：框架**已有真实下游承载**（见 §五"已验证可用"），
> 所以它不是"没人用的 toy"。扣分针对的是**贡献结构**，不是**采用度**——
> 这两件事在早期经常被混为一谈。

### 3.3 已验证可用：真实下游承载

框架不是自娱自乐——**已公开的两个下游项目**证明它在真实项目里跑得动：

| 项目 | 性质 | zigmodu 用法 | 证据强度 |
|---|---|---|---|
| [**zenaipa**](https://github.com/chy3xyz/zenaipa) | 全栈管理平台（Zig + SolidJS，单二进制） | HTTP / security / AI / resilience / Application 生命周期；依赖用 **git tag + content hash 双锁**（`zigmodu-0.39.9-U40vs30XlQC-...`） | 中——**依赖锁定姿势正确**，说明使用者懂供应链 |
| [**zasdoor**](https://github.com/chy3xyz/zasdoor) | **IAM/身份系统**：OAuth2/OIDC、MFA、SIWE、组织/项目/应用/角色 | 直接吃框架的 security 面：JWT / 多租户 / OIDC EdDSA+JWKS / 会话吊销 / 口令策略与锁定 | **高——79 个后端测试**（含 IAM/OAuth/MFA/web3 路由、JWT 多租户、联邦 IdP、密码策略） |

两条值得记下的细节：

1. **zasdoor 是高安全要求的场景**（身份与访问管理）。它选择用本框架承载，
   且**自己写了 79 个后端测试**——**框架的边界被真实业务逻辑反复压过**，
   这比任何自证 benchmark 都有说服力。
2. **两个项目的提交身份是 `shimonenator`**，与 zigmodu 仓库里的
   `Antigravity Agent` / `chy3xyz` 不同。虽是同一所有者名下，但**至少不是自审自签一个身份**。

**必须同时说清的三件事**（否则这个加分会被误读）：

- **所有者相同**：三个仓库都是 `chy3xyz`。这是**框架作者的 dogfooding**，
  不是第三方采用。
- **B-14 判定不变**：同一所有者 + 同一身份链，验证的是"作者能交付"，
  而 B-14 要求的是"**有人能推翻我们的结论**"。dogfooding 压出 bug 的能力很强，
  但**它不能替代独立审计**——因为作者自己选择实现方案，也自己判断实现对不对。
- **版本落差是真实风险**：zasdoor 声明 `zigmodu v0.15.44`、zenaipa 徽章写 `v0.20.1`
  （实际依赖已是 0.39.9）。**下游跑的是 0.x 的老版本**，这也侧面印证了
  §3.4 的判断——**碎片化版本让用户不敢升级**。

### 3.4 发布节奏是陀螺

99 个版本**全部在 0.x**，近月 1–2 次/天。语义化版本在 0.x 下被当成了 CI 计数器。
后果是真实的：生产团队看到 `zigmodu` 出现在依赖树里会犹豫——因为它显然还不打算稳定。
（反直觉的是，**破坏性只有 6/99**，说明这不是"重构频繁"，而是"发得勤"。）

### 3.5 A 组剩余（5 条，多为有界定界）

| # | 条目 | 现状 | 能否写代码关掉 |
|---|---|---|---|
| A-2 | 集群机密性 | 框架侧**定界不内嵌 TLS**（`ClusterAuth.zig:9-14`，`TlsConfig` 已删）；但边车已从图纸变成可跑物：`examples/production-deploy/cluster-sidecar/`（第 150 批，nginx stream mTLS + `gen-certs.sh` + 六组断言） | 部分 —— 机密性仍是**部署责任** |
| A-3 | kid 帧内协商 / 控制面下发 / 轮换持久化 | 集群面轮换撤销第 110 批落地 + 第 153 批运维 runbook；HTTP 侧 `JwksKeyRing` 只有 `addKey/getKey/getPrimaryKey/count`——**无 remove、无持久化、无 JWKS 端点** | 三条均"判定不做" |
| A-6 | 公平性加权 + Distributed Worker 统一 | 优先级**已落地**（`runtime.zig:113,230,1694`）；**加权仍未做**（`RUNTIME.md:710` 明说"没有测量就不加旋钮"）；`Distributed Worker` 在 `src/` 零命中 | 加权可做，Distributed Worker 不做 |
| A-7 | `ws_uring` 真实行为 | 解析器已并轨、两个缺陷已修；**真 io_uring 只能在 Linux 上验** | 不能（需 CI Linux 腿） |
| A-8 | `ConcurrentError` 分支 | `testing.io` 的 `concurrent_limit = unlimited`，**树内构造不出该分支** | 不能（需改 std） |
| A-9 | 混合版本形状 | `ci-mixed-version.sh:42-45` 仍只认 `refuse` / `interop` 两种 | 可做（加形状） |

### 3.6 文档 vs 代码（已部分修正）

见 §四。**注意 `docs/PRODUCTION_ROADMAP.md:133` 的标题是「阶段 9 —（演进中）」，
而 `AGENTS.md:454` 写「phases 1–9 ✅」——两处口径仍不一致**，本文不替它们做决定，只标出来。

---

## 四、本次修正的数字漂移（批 154，已提交 `39f45de`）

评估过程中实测发现三处文档落后于代码。**代码本身无缺陷**，全部按实测值改写：

| 项 | 原值 | 实测 | 依据 |
|---|:--:|:--:|---|
| deadcode 基线 | 28 | **32**（src 30 + tools 2） | `scripts/deadcode-baseline.json` items 计数 |
| test artifact 数 | 6 | **8** | `build.zig` 挂 `test_step` 的 `addTest`；与测试输出 8 行 `run test` 一一对应 |
| runtime gauge 数 | 25（13+6+6） | **31**（13+9+9） | 唯一 gauge 名计数；`CHANGELOG.md:8361` 早已记「从 25 条变 31 条」 |

同源衍生项一并修正：`6 条 pool_*` → 9 条、`5 个 test artifact` → 8、
`1450 用例 / 5 个二进制` → `2382 / 8`（含 `docs/dev/READING_NUMBERS.md` 这个"数字怎么读"的权威口径）。

**刻意未改**：`CHANGELOG.md` 历史条目、`dev/v1.0-readiness-v0.35.md:127`——
后者是v0.35 时期的审计快照，记录的是**当时**的实测值，改它反而破坏"当时这么写"的事实。

---

## 五、竞争力定位

### vs 其他 Zig 框架（zigg / zable / ghost）

**碾压级领先。** 功能宽度、运行时工程化、门禁纪律不在同一量级。
Zig 生态里它基本是唯一有生产野心的项目。**这一档没有竞争压力。**

### vs Go gin/echo · Java Spring · .NET

代码质量与设计**不落下风**，运行时抽象的完整度甚至更好。
但**生态与信任差距是数量级的**：0 外部贡献者、0 fork、0 独立验证。

**不过"没有验证"≠"没有使用者"**（见 §3.3）：

- 它**已被真实项目承载**——zenaipa（全栈管理平台）与 zasdoor（IAM/身份系统，
  79 个后端测试）都跑在它上面，且后者的安全场景直接吃它的 security 面。
  这比"star 数低"有意义得多：**star 是许愿，承载是使用。**
- 但**采用者与作者同属一个所有者**，因此这只支撑"框架能用"，不支撑"框架可信"。
- 结论：**适合个人 / 内部项目，且现在就有比"个人项目"更硬的理由去用它；
  但不适合作为关键生产依赖或对外承诺SLA 的组件。**

### 分域完成度（判断，非评分）

| 域 | 完成度 | 距 1.0 差什么 |
|---|:--:|---|
| Application（模块 / DI / HTTP / DB / 安全） | **~95%** | 基本无阻塞项；**已被 zasdoor 的 IAM 场景验证过边界** |
| Runtime 原语 | ~90% | 公平性加权、Distributed Worker 统一 |
| 集群（Raft / bus） | ~80% | 机密性（已定界）、HTTP 侧 kid 下发/持久化 |
| 可验证性 / 证据 | ~75% | **独立验证**（真实承载已具备，第三方审计仍无） |
| 量化 / 低延迟 | ~60% | affinity 未到 `spawn`、无 NUMA、无加权优先级 |
| 治理 / 可持续性 | ~10% | 不是技术能修的 |

> **与 `dev/v1.0-readiness-v0.35.md` 的 ~70% 不冲突**：那份给70% 是因为它把 **B-11 记为未关**，
> 而 B-11 已在第 153 批关闭（`ci.yml:960` refuse 形状 + `:971` interop 形状，两种形状都进夜间CI，
> 各自带日志 artifact）。**本文按今天的实况重算，不沿用那份的台账结论。**

---

## 六、复现本文所有读数

```bash
# 规模
find src -name '*.zig' | xargs cat | wc -l          # 185,550
git log --oneline | wc -l                           # 1008
python3 -c "import json;print(len(json.load(open('scripts/deadcode-baseline.json'))['items']))"  # 32
grep -c "addTest(b, test_step" build.zig            # 8
grep -rhoE '"zigmodu_runtime_[a-z_]+"' src/ | sort -u | wc -l   # 31

# 测试（注意：缓存重放不产生计数，必须 --force-run）
bash scripts/test-fast.sh --db all --force-run
# → zm-test-count: aggregate 2319/2382 passed skipped=63 binaries=8

# 门禁
bash scripts/check-deadcode.sh                      # OK: src+tools within baseline (32)
bash scripts/check-production.sh
bash scripts/check-test-collection.sh
```

**提交者构成**：`git shortlog -sn`

---

## 七、一句话

**技术分 82，可信度分 40，加权 68。** 作为"极高质量的单人/AI 作品"名副其实；
**且已被真实项目承载**（zenaipa / zasdoor，见 §3.3）——这不是"没人用的 toy"。
作为"可以押生产的框架"，还差 **B-14（独立验证）** 与 **C-16（治理）** 两关——
而这两关都不是靠继续写代码能解决的。1.0 方案见 [`dev/v1.0-roadmap-1.0.md`](dev/v1.0-roadmap-1.0.md)。