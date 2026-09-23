# SQLx 选择性驱动链接（`-Ddb=` / `.db=`）

ZigModu 默认链接 **sqlite + postgres + mysql**（`-Ddb=all`），保证旧项目与框架自测兼容。小系统 / 单驱动部署应收窄链接，减少系统库依赖与部署面。`-Ddb=none` 全不链驱动（sqlx 走 stub，`DriverNotEnabled` 守卫运行时生效）——用于无 DB 的二进制（如 Windows 交叉编译 agent）或纯测试桩。

**实现**：`examples/_shared/db_link.zig` · `build_options.enable_*` · `src/sqlx/*_c_stub.zig` · `sqlx.DriverFeatures`  
**相关**：[`data.sqlx`](../src/data.zig) · [PRODUCTION_ROADMAP.md](PRODUCTION_ROADMAP.md)（sqlx 维护边界）· [ZENT.md](ZENT.md)（正交 ORM，仍可能链 libsqlite3）  
**跨平台编译**：见 §12（`-Ddb=none` 是默认唯一可行档；带驱动需要目标平台的库 + `SQLITE_*` / `PQ_*` / `MYSQL_*` 覆盖，附实测内存表）

---

## 1. 消费者（package dependency）

```zig
const zigmodu_dep = b.dependency("zigmodu", .{
    .target = target,
    .optimize = optimize,
    .db = "sqlite", // 见下表
});
exe_mod.addImport("zigmodu", zigmodu_dep.module("zigmodu"));
```

不必在应用 `build.zig` 里手写 `linkSystemLibrary("sqlite3")`：zigmodu 根 `build.zig` 会按 `.db=` 链接。

`zmodu scaffold` / `zmodu new` 生成的 `build.zig` 已写入 `.db=`；`--from-db` 按 DSN 推断（见 §6）。

---

## 2. 合法取值

| 值 | 效果 |
|----|------|
| `all`（**默认**） | sqlite + postgres + mysql |
| `sqlite` | 仅 libsqlite3 |
| `postgres` / `postgresql` / `pg` | 仅 libpq |
| `mysql` / `mariadb` | 仅 libmysqlclient |
| 逗号列表 | 如 `sqlite,postgres` |

非法值 → `build.zig` `@panic`（`invalid -Ddb=`）。

框架仓库内也可：

```bash
zig build -Ddb=sqlite
cd examples/tenant-mgmt && zig build -Ddb=sqlite -Doptimize=ReleaseSafe
```

路径依赖示例（`tenant-mgmt` / `shopdemo` / `tenant-shop`）自带同名 `-Ddb=`；zent 示例固定 `Features.sqlite_only`。

---

## 3. 编译期与运行时行为

| 层 | 行为 |
|----|------|
| 链接 | 未启用的驱动 **不** `linkSystemLibrary` |
| C 绑定 | 未启用 → `src/sqlx/{sqlite3,libpq,libmysql}_c_stub.zig` |
| `build_options` | `enable_sqlite` / `enable_postgres` / `enable_mysql` |
| 运行时 | `Client.connect` / `newConn` → `error.DriverNotEnabled` |
| HTTP | `ZigModuError.DriverNotEnabled` → **400 Bad Request** |
| 探测 | `sqlx.DriverFeatures.sqlite` 等；`isEnabled(driver)` |

```zig
var client = try data.Client.open(allocator, io, .{ .driver = .postgres, .host = "..." });
// 若构建时未 enable_postgres：connect 失败为 DriverNotEnabled
```

---

## 4. 测试约定（重要）

| 场景 | `-Ddb=` |
|------|---------|
| 框架 `zig build test` | **必须默认 `all`**（大量单元测试开 SQLite `:memory:`；PG/MySQL live 用 `skipUnlessDb`） |
| 应用 / 示例构建与集成 | 按实际驱动收窄（CI：`scripts/ci-integration.sh` 用 `-Ddb=sqlite`） |
| 本地验证「只链了 sqlite」 | `zig build -Ddb=sqlite` 后 `otool -L` / `ldd` 应无 `libpq` / `libmysqlclient` |

窄化后跑完整测试套件会失败或大量 skip——这是预期，不是驱动 bug。

---

## 5. 体积与依赖预期

在 macOS arm64 上（数量级，随 Zig/优化波动）：

| 产物 | 大约 |
|------|------|
| `examples/basic` ReleaseSmall（sqlite） | ~180–200 KB 未 strip 量级 |
| `tenant-mgmt` ReleaseSmall `all` vs `sqlite` | 差几十 KB；**主要收益是少链系统 dylib** |

不要指望「去掉 postgres/mysql」把二进制砍掉数 MB——客户端库是动态链接的；收益是部署机不必装 libpq/mysqlclient，以及链接器/加载面更小。

---

## 6. Scaffold / CLI

| 命令 | `.db=` |
|------|--------|
| `zmodu new <name>` | `sqlite` |
| `zmodu scaffold --sql …` | `sqlite` |
| `zmodu scaffold --from-db postgresql://…` / `postgres://…` | `postgres` |
| `zmodu scaffold --from-db mysql://…` | `mysql` |
| `zmodu scaffold --from-db …sqlite…` / 路径 / 缺省 | `sqlite` |

生成后仍可手改 `build.zig` 的 `.db=`，或与运行时 DSN 不一致时以 **链接侧** 为准（未链的驱动无法 connect）。

细则：[ZMODU_CLI_INTEGRATION.md](ZMODU_CLI_INTEGRATION.md)。

---

## 7. 路径依赖示例与 `db_link.zig`

仓库根与部分 example 共用 `examples/_shared/db_link.zig`（解析、探测 Homebrew 路径、`link` / `addToOptions`）。

Zig package 路径限制：example **不能** `@import("../_shared/db_link.zig")`。做法：

```text
examples/<name>/db_link.zig  →  symlink → ../_shared/db_link.zig
```

| 平台 | 说明 |
|------|------|
| macOS / Linux | `ln -s ../_shared/db_link.zig db_link.zig`（仓库已提交为 symlink） |
| Windows | 若无创建 symlink：复制 `_shared/db_link.zig` 到该目录；两处需同步修改时优先改 `_shared` 再复制 |

改链接逻辑只改 `_shared/db_link.zig`；各 example 的 symlink 自动跟上。

> **git 依赖消费者**：`build.zig.zon` 的 `.paths` 已包含 `examples/_shared`，
> 因此通过 `git+https://…zigmodu` 拉取的包内自带 `examples/_shared/db_link.zig`
> 与 `zent_helpers.zig`，无需再从源码 clone 复制（换版本也无需重打 workaround）。
> 若消费者直接引用，路径为 `<zigmodu_pkg>/examples/_shared/db_link.zig`。

环境变量（可选）：`PQ_INCLUDE` / `PQ_LIB`、`MYSQL_INCLUDE` / `MYSQL_LIB`（或 `db_link` 内 macOS Homebrew 探测）。

---

## 8. 与 zent 的关系

zent 使用自己的 SQLite / 驱动栈，与 `data.sqlx` **正交**（见 [ZENT.md](ZENT.md)）。

路径依赖示例仍可能 `addImport("zigmodu", …)` 并设置 `build_options`：即便业务只走 zent，zigmodu 模块图仍可能拉入 sqlx 符号——这些示例用 `Features.sqlite_only`，避免再链 pq/mysql。

---

## 9. 维护边界（贡献者）

- **不要**为「选择性链接」物理拆分 `sqlx.zig`；stub + `DriverFeatures` 即可（[PRODUCTION_ROADMAP.md](PRODUCTION_ROADMAP.md)）。
- 新驱动：新 `sqlx/<name>_c.zig` + stub + `db_link` / `build_options` / `DriverFeatures` 登记；默认仍建议 `all` 包含或显式文档说明。
- 默认保持 **`all`**：收窄默认会破坏依赖「三库全链」的下游。

---

## 10. 检查清单

- [ ] 应用 `b.dependency("zigmodu", .{ .db = "…" })` 与真实 DSN 一致  
- [ ] 生产镜像只安装对应客户端库（sqlite 系统库 / libpq / mysqlclient）  
- [ ] CI 应用构建使用收窄 `-Ddb=`；框架 PR 测试保持 `all`  
- [ ] 误开未链接驱动时能收到 `DriverNotEnabled`（而非动态链接器错误）  

---

## 11. 已知限制：libpq 同步查询 × Threaded Io（已修复）

**状态**：已修复（v0.15.22 待发）；完整 async 化列为后续。两个互补缺陷：

### 11.1 libpq 同步查询无超时 → fiber 永久挂死

- **现象**：`queryRowPartial` / `queryRow` 偶发**单 fiber 永久挂死**（server 其他请求正常）。
  曾被误归因于"0 行结果"，实际 0 行只是触发时机巧合——libpq 同步返回与行数无关
  （`queryRowPartial` 0 行走 `error.NotFound` + `defer rows.deinit()`，清理完整）。
- **根因**：Postgres 查询全部同步 `PQexec` / `PQexecParams` / `PQexecPrepared`，
  **无任何超时**（无 `PQsetnonblocking` / `PQexecTimeout`）。Threaded Io 是 M:N
  fiber 池，fiber 内同步阻塞**不可被 io 取消**——单次挂起（网络抖动、服务器慢、
  连接被并发复用导致协议错乱）即永久卡死该 fiber。
- **修复（v0.15.22）**：`SO_RCVTIMEO` socket 读超时（`Config.query_timeout_ms`，
  默认 30s，0=禁用）——内核级 per-read 空闲超时，同步 `PQexec*` 不再能永久
  挂死；`connect_timeout=10` 覆盖连接阶段；超时后连接由池 ping / 单连接重连
  路径回收。完整非阻塞化（`PQsetnonblocking` + 轮询）列为后续优化。

### 11.2 ConnPool 等待 × Threaded Io worker 耗尽 → 间歇性 Timeout

- **机制**：`std.Io.Mutex`/`Condition` 在 Threaded 下基于 `Thread.futexWait`
  （真 OS futex，**阻塞整个 worker 线程**，非 fiber 让出）。`ConnPool.acquire`
  池满路径 `waiter.cond.waitTimeout(...)`——并发数 > worker 线程数（CPU 数）且
  池满时，所有 worker 阻塞在 futex 等待唤醒，release 的 fiber 无空闲 worker 可
  调度 → 等待者只能靠 `max_wait_ms` 超时自醒 → **高并发下间歇性 `error.Timeout`**
  （本应成功放行）。
- **修复（v0.15.22）**：等待改 **50ms 分段 futex** + 段间响应取消/池关闭
  （原单次长 futex 不可中断）；`max_wait_ms` 语义不变。注意 Threaded Io
  M:N 模型下 fiber 等待仍占用 worker——高并发（>CPU 数）池满场景的彻底
  解决需整体查询链 async 化（后续大项）。
- **通用教训**：Threaded Io 的 fiber 内**任何**同步阻塞（`posix.poll/read`、
  `mutex.lock`、同步 libpq）都可能阻塞 worker——应用层默认禁止（见
  `docs/BEST_PRACTICES.md`「Threaded Io 下的同步阻塞」）。  

---

## 12. 跨平台编译（cross-compile）

**一句话**：跨编译**默认只能用 `-Ddb=none`**；带驱动要自己提供**目标平台**的库并覆盖搜索路径，
否则报 `unable to find dynamic system library 'sqlite3' using strategy 'paths_first'`。

### 12.1 为什么默认不行

`examples/_shared/db_link.zig` 的 `detectPqPaths` / `detectMysqlPaths` 是**主机**启发式
（macOS 探 Homebrew、Linux 探 `/usr/include/{postgresql,mariadb}`），`link()` 又无条件
`linkSystemLibrary` —— 于是交叉编译时 Zig 去**目标**的默认路径找 `libpq` / `libmysqlclient` /
`libsqlite3`，那里什么都没有。CI 的 `windows-cross` job 就是照这个约束写的：
`zig build -Ddb=none -Dtarget=x86_64-windows`。

两条常被忽略的相邻事实：

- **跨目标跑不了测试**：`the host system (...) is unable to run foreign binaries`。
  所以跨编译不要走 `test` / `soak` / `runtime-stress` —— 那是内存最贵的一条路（见 12.4）。
- **没被用到的依赖会被链接器丢掉**：`zig build -Dtarget=… -Ddb=sqlite` 对
  `examples/basic` 会**成功**，但产物 `ldd` 里没有 `libsqlite3`（程序不引用 sqlx 符号，
  `--as-needed` 语义把它丢了）。要验证依赖真的进去了，得用**真的用库**的示例（如
  `tenant-mgmt`），或在目标机上 `ldd` 确认。

### 12.2 环境变量覆盖（目标平台库）

| 驱动 | 变量 | 说明 |
|---|---|---|
| postgres | `PQ_INCLUDE` / `PQ_LIB` | 已有；指向**目标**的 include / lib 目录 |
| mysql | `MYSQL_INCLUDE` / `MYSQL_LIB` | 已有；同上 |
| sqlite | `SQLITE_INCLUDE` / `SQLITE_LIB` | **新增**；至少给 `SQLITE_LIB`（sqlx 用 `extern` 绑定，头文件通常不需要） |

只给 lib 目录即可；给 include 会同时加 `addSystemIncludePath`。

### 12.3 实测可用的配方（本机 aarch64-macOS，容器里的 aarch64 Debian 库）

```bash
# 1) 从目标平台（或容器/sysroot）取出真库
docker run --rm -v /tmp/sqlite-linux:/out debian:bookworm-slim \
  sh -c 'cp -L /usr/lib/$(uname -m)-linux-gnu/libsqlite3.so.0* /out/'

# 2) (a) musl 目标：Zig 对 aarch64-linux 的默认 libc 就是 musl，直接可用
SQLITE_LIB=/tmp/sqlite-linux zig build -Dtarget=aarch64-linux -Ddb=sqlite

# 2) (b) glibc 目标：必须写 glibc 版本，且与库的符号版本匹配
SQLITE_LIB=/tmp/sqlite-linux zig build -Dtarget=aarch64-linux-gnu.2.34 -Ddb=sqlite

# 3) 验证（真用库的示例 + 目标机 ldd）
cd examples/tenant-mgmt && SQLITE_LIB=/tmp/sqlite-linux zig build \
  -Ddb=sqlite -Dtarget=aarch64-linux-gnu.2.34 -p /tmp/out
docker run --rm -v /tmp/out:/x <同样的目标镜像> ldd /x/bin/tenant-mgmt | grep sqlite
# → libsqlite3.so.0 => /lib/aarch64-linux-gnu/libsqlite3.so.0
```

**踩过的坑**：只写 `-Dtarget=aarch64-linux-gnu`（不带版本）而库是 Debian bookworm 的，
会得到一屏 `undefined reference: pthread_join@GLIBC_2.34`、`stat64@GLIBC_2.33` ——
Zig 用的 glibc stub 版本比库旧。补上 `.2.34` 即通。**库与目标 ABI 要同源**：musl 目标配
glibc 编的 `.so` 能链上（Zig 不校验库自身的依赖），但目标机上仍然缺 glibc，属于错误组合。

### 12.4 两个操作陷阱

- **跨编译务必带 `-p <独立前缀>`**（或 `.zig-cache` 之外的 prefix）。不带的话产物会覆盖
  `zig-out/bin/*` 成**目标平台的 ELF**，随后任何跑本地二进制的脚本都会炸——实测
  `zig build -Dtarget=aarch64-linux` 之后再跑 `bash scripts/check-deadcode.sh` 得到
  `OSError: [Errno 8] Exec format error: './zig-out/bin/zmodu'`；`zig build zmodu`
  重建本地产物即恢复。
- **`zig build docs` 的产物是构建输出**（`docs/modules.{puml,json,md}`），已在 `.gitignore`
  里；该步不参与 `test`/`check`，所以 CI 专门加了一条 `zig build docs` 守卫——它曾经
  烂了两处（`std.heap.GeneralPurposeAllocator` 已删除、`generateDocs` 变成 4 参）而无人发现。

### 12.5 内存：实测对照与降内存配方

同一份源码、同一目标（`aarch64-macOS → x86_64-linux`）、每个配置独立冷缓存，
`--summary all` 的 MaxRSS 峰值（目标取 `benchmark-build`，只编译不运行）：

| 配置 | 峰值 | 耗时 |
|---|---|---|
| Debug | 266 MiB | 6s |
| Debug（热缓存，第二次） | **31 MiB** | ~0s |
| Debug `-fincremental` 冷 / 热 | 283 / 273 MiB | 8 / 4s |
| **ReleaseSmall** | **419 MiB** | 19s |
| **ReleaseSafe** | **858 MiB** | 50s |
| **ReleaseFast** | 862–892 MiB | 59–98s |
| 只编产物（默认 `install`，惰性分析） | 207 MiB | 17s |
| 原生 Debug（同目标作对照） | 266–602 MiB | 6–13s |
| 原生 `test` 全量编译（CI/发布日志） | **~1 GiB** | ~21s |

结论（按收益排序）：

1. **决定内存的是 `-Doptimize=`，不是"跨"**：ReleaseSafe/Fast 的 LLVM 优化把峰值抬到
   Debug 的 ~3 倍（0.86 GB vs 0.27 GB）。跨编译只要产物、不需要 fast/safe 语义时用
   **`-Doptimize=ReleaseSmall`**（0.42 GB）或 Debug。
2. **别走 `test`**：全量分析（`refAllDecls`）的测试二进制是唯一上 1 GB 的路径，而跨目标
   本来就跑不了测试。CI 的 cross job 只编库不是偷懒，是唯一合理的做法。
3. **缓存是最大杠杆**：热缓存 31 MiB / ~0s。`--cache-dir` / `ZIG_LOCAL_CACHE_DIR` 放本地
   SSD；CI 上缓存命中与否直接决定内存与时间。
4. **内存受限机器/runner**：`zig build … -j2 --maxrss 1G --skip-oom-steps`。
   `--maxrss` 让 build runner 按内存预算节流并发，`--skip-oom-steps` 是"超预算跳过"
   而不是被 OOM kill。注意 **`-j1` 对峰值没有稳定收益**（实测 207→240、346→581，方向
   甚至相反）——它压的是总量与可预测性，不是单 job 峰值。
5. **`-fincremental` 是拿内存换重编速度**：冷启动无收益（283 vs 266），热起来后峰值反而
   高于普通热缓存（273 vs 31）。频繁重编时开，省内存时不开。
6. **系统层**：容器 `--memory` + swap、`ulimit -v`；真要跑全量测试编译（1 GB 级）就选
   ≥4 GB 的 runner。

> 数字来源：本机 aarch64-macOS + Zig 0.17.0-dev.2151，样本有限（Debug/原生组有波动，
> 原生 Debug 一次测到 602 MiB），**按数量级使用**，不要当精确基线。
