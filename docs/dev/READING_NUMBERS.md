# 读数约定：一个事实一个名字

这份文档回答一个问题：**"这个提交的测试/基准结果是什么？"** 只允许有一个答案。
两个名字指同一个事实（或相反：一个名字指两个事实）就等于没有可证明的读数 ——
本仓库为这件事付过两次代价，两个事故都在下面记着，因为它们的形状还会再来。

适用范围：`scripts/test-fast.sh`（测试计数）、`scripts/check-bench.sh`（基准判据、
候选回退标记、`--explain` / `--ratios`）。判据本身（`THRESHOLD`、两份 baseline 的
数值、`REF_METRICS` 的成员）不在这份文档的讨论范围内，也不因它改变。

---

## 1. 测试计数：规范入口是 `scripts/test-fast.sh`

**只认这两行里的 aggregate 那一行**：

```bash
bash scripts/test-fast.sh --db all --force-run      # 人看：OK 行 + 标签 + 每二进制明细
bash scripts/test-fast.sh --db all --count          # 机器读：stdout 只有一行
```

输出里两（多）个数各自带标签，前缀固定为 `zm-test-count:`：

```
zm-test-count: aggregate 1429/1450 passed skipped=21 binaries=5 db=all filter=none source=build-summary
zm-test-count: main-binary 1315/1336 passed skipped=21 (largest of 5 — locates a failure, NOT the number to quote)
zm-test-count: binary 97/97 passed skipped=0
```

- **`aggregate` = 这个提交的读数。** 要写进报告、PR、基线，抄这一行（`--count` 只印它）。
- **`main-binary` = 最大的那个测试二进制（库套件）。** 它存在只是为了**定位失败**在哪个
  二进制；把它当总数抄下来就是事故 1。它永远是 `main-binary` 或 `binary` 标签，
  不会是 `aggregate`。
- `source=` 说明这个数从哪来，两者不是同一个机制：
  - `source=build-summary`：不带 filter，跑的是 Zig 自带 runner，总数在
    `Build Summary: … N/M tests passed (K skipped)` 那一行，每二进制明细在 summary 树里
    （`+- run test N pass, K skip (M total)`）。
  - `source=zm-test-runner`：带 `--filter`，跑的是 `scripts/test-runner.zig` 的运行期
    filter（唯一能按名字聚焦的方式，见 `docs/BEST_PRACTICES.md`「只跑匹配的测试」）。
    它**跳过无名的 `test { … }` 聚合块**，所以 `selected/total` 会与自带 runner 的
    `passed/total` 差那么几块 —— 两种模式的 **分母今天一致**（1450 用例、5 个二进制、
    `-Ddb=all`），这也是 aggregate 可以跨模式引用的前提。两种来源同时出现时，
    `test-fast.sh` 会把 summary 与逐二进制的和**互相对账**，不一致直接 exit 3。
- 引数时必须**连同 `db=` 与 `filter=` 一起引**（`-Ddb=sqlite` 是另一个套件的另一个数）。

**为什么两个数都印，而不是只印一个**：只印 aggregate 会让"哪个二进制失败了"从日志里
读不出来，而这不是"少一个数"，是换一个地方手工重算（然后又会有人留下一个没有标签的数字）。
所以做法是**两个都印、各自带标签、并且明文写出哪个是读数**：混淆的成本从"读者要想"
变成"抄错标签就是抄错标签"。

**拿不到计数就不许报成功**：解析不到任何计数（典型是热缓存回放 —— `zig build test`
打印 `run test cached`、没有计数）一律 **exit 3**，并提示 `--force-run`。
老版本在这里会 exit 0，与 `docs/BEST_PRACTICES.md` 里"拿不到计数时脚本只会 exit 3
或给出明确的 WARNING，绝不报告成功"写的话相反；现在代码与那句话一致了。

退出码：`0` 跑完并通过 · `1` 有用例失败 · `2` filter 一个都没命中 · `3` 读不到结果 ·
`64` 用法错误。`--count` 沿用同一套码，只是 stdout 只有一行。

### 事故 1（为什么有这一节）

同一轮里两个子代理各自被交代"测试基线 = 1303 pass / 21 skip"，**两个都错**：
`1303` 是**主二进制**的读数，聚合口径是另一行。两个代理都得先自己跑一次才能纠正我。
形状：**同一个事实有两个名字**，而名字没说自己是哪一个。

---

## 2. 基准：`RE-RUN-BEFORE-FIX` 标记与 `--explain` 手续

`bash scripts/check-bench.sh`（判据、`THRESHOLD`、棘轮、两份 baseline）本身没有变。
**每次运行**（通过或失败）都会多印一块 `references —`：

```
references — recorded and printed, never gated; a reading on one of these is a candidate
  fallback (re-run before changing anything), not something to ignore:
  RE-RUN-BEFORE-FIX  atomic RMW x10M            22.177 →  21.670 ms  0.98x  flat        (control reference; 6 metric(s) divide by it)
  RE-RUN-BEFORE-FIX  StoreForward x10M         120.963 → 122.710 ms  1.01x  flat        (candidate reference; no metric divides by it yet)
  RE-RUN-BEFORE-FIX  Worker drain dedicated x1M 134.000 → 193.880 ms 1.45x MOVED       (hand-off pair; 1.84x run-to-run spread within one machine)
  RE-RUN-BEFORE-FIX  Pooled dispatch x1M        256.200 → 260.100 ms 1.02x  flat        (hand-off pair; …)
  0 of 3 host reference(s) outside the 1.25x host-suspect band — the host did not move in this run
  1 hand-off row(s) MOVED — that pair swings 1.84x/3.09x within one machine by
  construction, so its drift says nothing about the host (docs/RUNTIME.md §12.5).
```

- **`RE-RUN-BEFORE-FIX` 是固定的机器可读标记**，含义是"**候选回退：先重跑再修**"。
  它不是"可以忽略"：它说的是这一行上的读数**在重跑之前不能当作代码的判决**。
- 每行还带**角色标签**，这就是原来只散在注释里的"为什么它不该被门禁"：
  `control reference`（宿主自己的 atomic 成本；门禁它会正好在宿主换代时开火）·
  `candidate reference`（为环形缓冲准备的更近的分母，是否更好是跨宿主的断言）·
  `hand-off pair`（`Worker drain dedicated x1M` / `Pooled dispatch x1M`，相互比较用，
  不设门禁）。角色表在 `REF_METRIC_ROLES` 里（**只影响展示**；成员必须 ⊆ `REF_METRICS`，
  否则脚本直接报错退出，不会让某个指标悄悄获得第二种含义）。
- 偏离记录值的程度决定附加标签，而**只有宿主类角色会给出 `HOST-MOVED`**：
  - **`HOST-MOVED`** = 这条 `control`/`candidate` 参考在**本次运行**里偏离记录值超过
    host-suspect 带（默认 `1.25x`，`BENCH_HOST_SUSPECT` 可覆盖）。它**不门禁**，
    只是把"先看参考"从注释变成输出，并驱动 `--explain` 的结论。
  - **`MOVED`** = 同一件事发生在 `hand-off pair` 上。那一对在**单机内**本来就摆 1.84x /
    3.09x（线程交接），所以它偏了**不是**宿主信号；把它读成"宿主动了"是错的答案，
    这也是两行分开的原因。
  - `flat` = 在带内；`n/a` = 这次运行没测到它。

### 手续（可执行）：这次是噪声还是真回退

```bash
bash scripts/check-bench.sh > /tmp/bench.log 2>&1        # 任何一次红：把整份输出存下来
bash scripts/check-bench.sh --explain /tmp/bench.log     # 问它
```

`--explain` 不编译、不跑套件、不改任何东西，只用保存下来的日志回答两步：

1. **宿主动了吗**：把**每一条**声明的参考与它的记录值并列，标 `HOST-MOVED` / `flat`，
   并给出本次最差偏离。
2. **判据会红在哪**：用与门禁**相同**的清单、相同的 2.0x 重算（告诉你会红在哪几个指标）。

然后给**一个 token**：

| token | 含义 | `--explain` 退出码 |
|---|---|---|
| `RE-RUN-BEFORE-FIX` | 同一轮里某条参考超出 suspect 带 → 上面的数字是宿主的，不是代码的。先重跑。 | 0 |
| `REAL-REGRESSION-CANDIDATE` | 参考全部 `flat`、指标照样动了 → 宿主解释不了。重跑确认一次，再去看代码。 | 1 |
| `NO-BREACH` | 没有超过 2.0x 的指标，没什么可解释。 | 0 |
| 读不了日志 | 没有 `[med3]` 行 / 没有 baseline。 | 3 |

**这些退出码是手续的答案，不是门禁的判决**：门禁仍然只是"不带参数跑
`scripts/check-bench.sh`"，仍然只在超 `THRESHOLD` 时失败。多份日志可以一起给
（`--explain a.log b.log`），任一份是 `REAL-REGRESSION-CANDIDATE` 就 exit 1 ——
"8 次运行里 1 次超带"这种形状正是事故 2。

### 事故 2（这套手续针对的形状）

`check-bench.sh` 报 `findById x10K/x20K` 慢 2.1×。同一轮里机器参考
`atomic RMW x10M` 自己从 22.2 ms 涨到 **35.8 ms**（1.61×），所有比值同步掉到 ~0.6×。
机器静下来重跑即 exit 0。

两个原因必须一起看：**（a）** 1.61× 在门禁自己的 host note（2.0×）之内，所以
"参考动了"这条信号**从来不会进入输出**；**（b）** 那条经验只写在注释里。
所以现在：参考块**每次都印**，suspect 带 `1.25x` 比 `THRESHOLD` **更窄**（参考是宿主
最简单的循环，单机逐次漂移是百分之几：本机 12 次运行里 `atomic RMW` 在 1.04× 内、
环形比值 max/min 1.083×），`HOST-MOVED` 与 `--explain` 都指向"先重跑"。

---

## 3. 跨宿主：`--ratios`（决定环形缓冲该除哪个参考）

`RingBuffer SPSC x1M` 除 `atomic RMW x10M` 还是除 `StoreForward x10M`，**单机证明不了**：
候选参考的意义就在"哪个在宿主换代时离散更小"。所以给出的是**手续**，不是结论，
也不设默认 —— 换参考是 `NORMALIZED_METRICS` 里一个名字的编辑加上每个机器类各一次
`--update`（写在 `check-bench.sh` 头部）。

```bash
# 1) 每个机器类各留 ≥2 份日志（本机直接跑；CI 那类下载 Benchmark job 的日志，
#    那个 job 也跑 check-bench.sh，所以它的 job log 直接就是可读输入）
for i in 1 2; do bash scripts/check-bench.sh > /tmp/ratios/laptop-$i.log 2>&1; done
gh run view <run-id> --log > /tmp/ratios/ci-1.log      # 或从 job artifact 里取

# 2) 并排看：每个输入能表达的 (指标, 参考) 比值 + 按 (指标, 参考, 宿主) 的离散
bash scripts/check-bench.sh --ratios /tmp/ratios/*.log scripts/bench-baseline.ci.json
```

输出形状（真实一次运行，`spread` 组里 n<2 的印 `n/a`；`--ratios` 只列
`NORMALIZED_METRICS`（被除的那 6 个指标）——参考换名字才会动到它们的除数）：

```
metrics considered: 6 — the ratio-gated list, because a reference change moves
  exactly these denominators: 1L x10M events, HotBus 8sub x1M, Mailbox full-path x10M, ...

== /tmp/ratios/laptop-1.log (1 run(s))
   host: region=? cpu=Apple M1 Pro cores=10
   RingBuffer SPSC x1M        / atomic RMW x10M            = 0.50854  (measured)
   RingBuffer SPSC x1M        / StoreForward x10M          = 0.08981  (measured)
   ...

spread over every input, grouped by (metric, reference, host) — no conclusion is drawn here:
  metric                     reference                  host                                 n       min       max   max/min
  RingBuffer SPSC x1M        atomic RMW x10M            bench-baseline.ci.json (recorde...   1   0.05240   0.05240       n/a
  RingBuffer SPSC x1M        atomic RMW x10M            region=? cpu=Apple M1 Pro cores=10   1   0.50854   0.50854       n/a
  RingBuffer SPSC x1M        StoreForward x10M          region=? cpu=Apple M1 Pro cores=10   1   0.08981   0.08981       n/a
```

- `measured` 行两个数都来自同一次运行；`recorded` 行来自某份 baseline 自己的比值。
  **没有的数字印 `n/a`，绝不推导** —— 一个没测过的数就是猜，而这份手续存在的意义
  就是把猜排除在外。
- 结论部分只印离散，**不替调用者下结论**，也不选默认参考。要下结论需要：同一提交、
  每个宿主类 ≥2 次运行（n≥2 才有 `max/min`），然后比较 `RingBuffer SPSC x1M` 在两列
  `max/min` 上的差别，还要看它在两个宿主类之间的差值。
- 现有输入（只是输入，不是结论）：本机 12 次运行 `ring/atomic` 0.4698–0.5086（6.6%）、
  `ring/StoreForward` 0.08658–0.09028（4.3%）；CI baseline 里 `ring/atomic` = 0.0524，
  而 Xeon 那次是 0.0386（26% 离散）。

---

## 4. 一页速查

| 问题 | 唯一入口 | 抄哪个数 |
|---|---|---|
| 这个提交测试通过吗 | `bash scripts/test-fast.sh --db all --force-run`（机器读 `--count`） | `zm-test-count: aggregate …` |
| 哪个二进制失败了 | 同一次输出，或 `--filter` 聚焦 | `zm-test-count: main-binary …` / `binary …` |
| 基准过不过 | `bash scripts/check-bench.sh` | 退出码 + `FAIL:`/`OK:` 行 |
| 这次红是真回退吗 | `bash scripts/check-bench.sh --explain <log>` | `RE-RUN-BEFORE-FIX` / `REAL-REGRESSION-CANDIDATE` |
| 参考/hand-off 那一行怎么读 | 同一次输出的 `references —` 块 | `RE-RUN-BEFORE-FIX` + `HOST-MOVED`/`flat` |
| 环形缓冲该除哪个参考 | `bash scripts/check-bench.sh --ratios <log…> [baseline.json…]` | 离散表（`max/min` 列），自己判断 |

## 一条边界：`REAL-REGRESSION-CANDIDATE` 什么时候**不成立**

`--explain` 的 `REAL-REGRESSION-CANDIDATE` 是这样推的：**声明的参考都 `flat`、指标却动了 ⇒ 宿主解释不了**。
这个推理**依赖一个前提**：**至少有一个声明的参考与那条指标共享瓶颈**。不满足时它**不成立**。

**实测的例子（不是推测）**：`TimerWheel x100K`。

| | 值 | 对基线 6.808 |
|---|---|---|
| 满载那一次 | 15.35 ms | **2.25×**（`--explain` 判 `REAL-REGRESSION-CANDIDATE`，参考全 `flat`） |
| 立刻重跑 | 8.55 ms | **1.26×** |
| 本会话早先 8 次 | 6.94–8.79 ms | 1.02–1.29× |

**中间没有任何代码改动。** 原因是瓶颈不同：这条指标是**内存/页路径**受限的（每次新建轮 → `nodes` 增长
~14.75 MB → first-touch 每一个新页），而控制参考 `atomic RMW x10M` 是个 **cache-local 小循环** ——
机器被压时前者会慢、后者不会。

**所以对这类"没有参考能为它作证"的指标，正确读法是**：

```bash
for i in 1 2 3 4 5; do bash scripts/check-bench.sh > /tmp/b-$i.log 2>&1; done
bash scripts/check-bench.sh --ratios /tmp/b-*.log scripts/bench-baseline.json   # 比分布，不比单点
```

`--explain` 的 token **不能**给它定罪；它只能告诉你"这条读数在单次采样里越了 2.0×"。
