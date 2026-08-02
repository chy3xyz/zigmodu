# SQLx 选择性驱动链接（`-Ddb=` / `.db=`）

ZigModu 默认链接 **sqlite + postgres + mysql**（`-Ddb=all`），保证旧项目与框架自测兼容。小系统 / 单驱动部署应收窄链接，减少系统库依赖与部署面。

**实现**：`examples/_shared/db_link.zig` · `build_options.enable_*` · `src/sqlx/*_c_stub.zig` · `sqlx.DriverFeatures`  
**相关**：[`data.sqlx`](../src/data.zig) · [PRODUCTION_ROADMAP.md](PRODUCTION_ROADMAP.md)（sqlx 维护边界）· [ZENT.md](ZENT.md)（正交 ORM，仍可能链 libsqlite3）

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
