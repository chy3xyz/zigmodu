# 复现发布证据（B-14 的低成本半程）

> **这份文档存在的理由**：`v1.0-readiness-v0.35.md` 的 B-14 指出，仓库里所有"已闭环"
> 判定都出自同一批 AI 自证。彻底关上 B-14 需要**第二个独立的人/团队/工具链**真跑一遍；
> 在那之前，这里先把"自证"变成"**任何人可复现、可下载、可推翻**"——每条证据给出：
> 本地一条命令、夜间 CI 的对应 artifact、以及"通过"长什么样。
>
> 前提：Zig **0.17.0**（CI 锁定版本，`.github/workflows/ci.yml` → `ZIG_VERSION`），
> 仓库根下执行，沙箱缓存一律 `export ZIG_GLOBAL_CACHE_DIR=.zig-global-cache`。

## 一览

| 证据 | 本地复现 | 夜间 CI artifact（`nightly-soak-<sha>`，留存 30 天） | 通过信号 |
|------|---------|------------------------------------------------------|---------|
| HTTP + 多租户 soak | `zig build soak -Dsoak-clients=64 -Dsoak-iterations=200` | `soak.log` | 租户隔离零串扰、RSS/线程不增长，exit 0 |
| 集群 soak（选举/复制/总线不变量） | `zig build soak-cluster`（预算可用 `SOAK_CLUSTER_RSS_BUDGET_MIB` 覆盖） | `soak-cluster.log` | seq 无洞无重、三份日志逐字节一致、fd/RSS/线程不增长 |
| Runtime stress（监督树/池/定时器） | `bash scripts/runtime-stress-record.sh [duration_ms] [history_path]` | `runtime-stress.log` + `runtime-stress-history.jsonl` | 守恒断言全过、零分配违例，history 追加一行 schema-v1 JSON |
| 混合版本集群对跑（B-11） | `bash scripts/ci-mixed-version.sh`（`MIXED_OLD_REF=v0.32.0`，`MIXED_EXPECT=refuse\|interop`） | `mixed-version.log` | refuse：旧节点帧/握手被**可 grep 地**拒绝且新节点正常选举复制；interop：单 mesh 单 leader、零拒绝；SIGTERM 全部 exit 0 |
| CL/TE 走私端到端（B-15） | `cd examples/production-deploy/smuggling-e2e && ./run.sh`（无 docker 自动跳过；`--require` 强制） | —（push 门禁自行执行） | nginx 转发日志与后端分发日志**逐条相等** |
| 集群 mTLS 边车拓扑（A-2） | `cd examples/production-deploy/cluster-sidecar && ./run.sh`（同上 skip/`--require` 约定） | —（按需本地跑） | 唯一选主 + mesh 全连 + 明文绕过被拒 + 无证书握手被拒 + 干净退出 |
| Fuzz（有界） | `zig build test --fuzz=2000 -Ddb=all -Dtest-llvm=true --test-timeout 300s` | —（同夜间 job 日志） | exit 0；x86_64 上 **必须**带 `-Dtest-llvm=true`（默认后端不产 sancov 覆盖段，见 `ci.yml` Fuzz 步注释） |
| Bench 基线 + 分配预算（B-13） | `bash scripts/check-bench.sh`（`THRESHOLD=2.0`，基线 `bench-baseline.ci.json`） | benchmark job 日志 | 32 条基线全在门内、32 条 `max_alloc_per_op` 预算零违例 |

## 下载夜间 artifact

夜间 job 每次跑完上传一份 `nightly-soak-<commit-sha>`（30 天留存，`ci.yml` "Upload nightly
soak/stress logs" 步，`if: always()`——**红的那晚日志一定在**）：

```bash
# 找到最近一次夜间运行
gh run list --workflow ci.yml --event schedule --limit 5

# 直接按名字下载某次提交的 artifact
gh run download -n nightly-soak-<sha>
# 或先定位 run 再下载它的全部 artifact
gh run download <run-id>
```

解开后就是上表第三列的那组文件。`runtime-stress-history.jsonl` 是 **commit → stress 结果**
的时间序列，读回趋势：

```bash
python3 scripts/runtime_stress_trend.py runtime-stress-history.jsonl
# 多晚的序列直接拼接再喂：cat a.jsonl b.jsonl | python3 scripts/runtime_stress_trend.py /dev/stdin
```

## 复现时的口径说明（别踩坑）

- **所有等待都是有界轮询**：hang 住 = 失败，不会永远卡住 CI——复现出 hang 本身就是有效证据。
- `ci-mixed-version.sh` 会在浅克隆里自己 fetch 旧 tag；`MIXED_EXPECT=interop` 只对
  "wire 字节没变过"的版本对成立（如 v0.38.0 × master），对 v0.32.0 用 `refuse`。
- 宿主演播读数（调度延迟、allocator 页驻留）**只打印不断言**；macOS 与 Linux runner 的
  RSS 形状不同，`soak-cluster` 的 RSS 预算就是为此显式提到 192 MiB 的（见该步注释）。
- 没有 docker 的机器上 `smuggling-e2e/run.sh` 打印 skip 并 exit 0——**那不算复现过**，
  要证据就加 `--require`。
- fuzz 的 `--fuzz=2000` 上界是刻意的：不带界的 `--fuzz` 会打开 webui 永不退出。

## 这份文档**没有**关上 B-14

脚本公开 + artifact 可下载只解决"**能不能**被独立验证"，不等于"**已经被**独立验证"。
B-14 在 readiness 文档里维持"未关"，直到出现第一个**非本批 AI** 的复现记录
（issue / PR / 第三方报告均可，届时把链接挂进 `v1.0-readiness` 的 B-14 跟进注）。
