# ZModu

Code generation tool for ZigModu framework with **Modulith style** architecture.

## Installation

### Via npm (recommended)

```bash
npm install -g @chy3xyz/zmodu
zmodu --help
```

### Via Zig build

```bash
cd tools/zmodu
zig build install-zmodu
```

Or run directly:
```bash
cd tools/zmodu
zig build run -- <command>
```

### Via manual download

Download the latest binary from [GitHub Releases](https://github.com/knot3bot/zigmodu/releases) for your platform.

### Exit codes
- **0** — 成功  
- **1** — 未知子命令（如打错 `zmodu foo`），或运行期失败（如 **SQL 路径不可读**、SQL 解析内存错误、一般 I/O 错误等）  
- **2** — 参数不合法：缺参、未知 flag、`--sql`/`--out` 等缺少值、`help`/`version` 后跟多余参数、**SQL 文件中没有任何 `CREATE TABLE`** 等（POSIX 惯例：misuse）  
- **3** — 目标生成文件已存在且未传 **`--force`**（可脚本区分于其它失败）

## Commands

### `new <name>`
Create a new ZigModu project.

```bash
zmodu new myapp
cd myapp
zig build run
```

### `module <name>`
Generate a module directory with Modulith structure. `module.zig` matches the framework contract in [AGENTS.md](../../AGENTS.md) (`zigmodu.api.Module`, `init` / `deinit`, optional `.is_internal`) and uses the same template as **`zmodu orm` (sqlx)**: [module.zig.tpl](src/templates/orm/sqlx/module.zig.tpl).

```bash
zmodu module user
# Creates: src/modules/user/module.zig, src/modules/user/root.zig
```

`root.zig` 与 ORM 一致作为 barrel 入口；ORM sqlx 会再生成 `model` / `persistence` 等。仅搭建模块时可在同一目录后运行 `zmodu orm` 补全。

支持参数：
- `--dry-run`: 只预览将写入的文件与大小，不落盘
- `--force`: 允许覆盖已存在文件（默认遇到已存在文件会报错并退出）

### `event <name>`
Generate an event handler.

```bash
zmodu event order-created
# Creates: src/events/order-created.zig
```

### `api <name> [--module <module-name>]`
Generate an API endpoint. Optionally place within a module.

```bash
# Standalone API
zmodu api users
# Creates: src/api/users.zig

# API within a module (Modulith style)
zmodu api users --module user
# Creates: src/modules/user/api_users.zig
```

### `orm`
Generate complete modules from SQL DDL with full CRUD.

```bash
# Auto-partition by table prefix (user_profile → user module)
zmodu orm --sql schema.sql --out src/modules

# Preview without writing
zmodu orm --sql schema.sql --out src/modules --dry-run

# Regenerate and overwrite existing files (default: error if file exists)
zmodu orm --sql schema.sql --out src/modules --force

# Force all tables into a single module
zmodu orm --sql schema.sql --module user --out src/modules

# Generate with zent Schema-as-Code backend
zmodu orm --sql schema.sql --out src/modules --backend zent
```

Creates a complete module directory for each inferred module:

**Sqlx Backend** (default):
```
src/modules/{module}/
├── root.zig         # Barrel re-exports (model, persistence, service, api, module)
├── module.zig       # ZigModu module metadata (init/deinit)
├── model.zig        # Structs + `sql_table_name` + `jsonStringify` (ORM table mapping)
├── persistence.zig  # `SqlxBackend` + `Orm(SqlxBackend)` repository accessors
├── service.zig      # Paginated list + CRUD delegating to repositories
└── api.zig          # `http_server` routes, `ctx.bindJson` / `ctx.jsonStruct` / `sendError`
```

Static layout for SQLx is maintained under **`tools/zmodu/src/templates/orm/sqlx/`** (embedded at compile time). Adjust headers/footers there instead of editing long strings in `main.zig`.

**Zent Backend**:
```
src/modules/{module}/
├── root.zig         # Barrel: schema, client, module
├── module.zig       # ZigModu module metadata (init/deinit)
├── schema.zig       # zent `Schema(...)` definitions (Schema-as-Code)
└── client.zig       # `makeClient` + `buildGraph` wiring
```

Static shell for Zent lives under **`tools/zmodu/src/templates/orm/zent/`**; per-table `Schema` bodies are still emitted from `main.zig`.

### `generate <target> [options]`
Unified generator command supporting all targets.

```bash
# Generate empty module
zmodu generate module user

# Generate module from SQL (same as 'orm')
zmodu generate module --sql schema.sql --out src/modules

# 与 `zmodu orm` 相同：`--dry-run` / `--force` 写在 `--sql …` 之后即可透传
zmodu generate module --sql schema.sql --out src/modules --dry-run
zmodu generate orm --sql schema.sql --out src/modules --force

# Generate event
zmodu generate event order-created

# Generate API within module
zmodu generate api users --module user

# Generate ORM (alias for 'orm')
zmodu generate orm --sql schema.sql
```

`generate module --sql …` 与 `generate orm …` 与 `zmodu orm` 共用同一套参数解析；不认识的选项会报错退出（不会静默忽略）。

**ORM / SQL 细节**：读入的 SQL 会先去掉 **UTF-8 BOM** 与首尾空白再解析；`--out` 不允许含 **`..`** 段；`--module` 与 `zmodu module <name>` 的名称须为**单一路径段**（不能含 `/`、`\` 或 `..`）。**`--dry-run`** 且文件为空、无 `CREATE TABLE` 时只打 **warn** 并退出 **0**（不落盘）；非 dry-run 仍报错退出 **2**。

## Modulith Architecture

ZModu promotes **Modulith** (Modular Monolith) architecture:

- **Package by Module**: Each module is a self-contained directory
- **Explicit Boundaries**: Module dependencies declared in `info.dependencies`
- **Cohesive Structure**: Domain, persistence, service, and API live together (SQLx); or schema + client (Zent)

**SQLx** (default `zmodu orm`):

```
src/modules/
├── user/                      # User module
│   ├── root.zig              # Barrel imports for the module
│   ├── module.zig            # Module metadata & lifecycle
│   ├── model.zig             # Domain models
│   ├── persistence.zig       # Repository layer
│   ├── service.zig           # Business logic
│   └── api.zig               # HTTP handlers
├── order/                     # Order module
│   ├── root.zig
│   ├── module.zig
│   ├── model.zig
│   ├── persistence.zig
│   ├── service.zig
│   └── api.zig
└── payment/                   # Payment module
    └── ...
```

**Zent** (`--backend zent`):

```
src/modules/
├── billing/
│   ├── root.zig              # schema, client, module
│   ├── module.zig
│   ├── schema.zig            # zent Schema(...)
│   └── client.zig            # makeClient + buildGraph
└── ...
```

## Generated Features

### Pagination

List endpoints support pagination via query parameters:
- `page` — Page number starting from 0 (default: 0)
- `size` — Items per page (default: 10)

```bash
GET /user_profiles?page=0&size=10
```

Response:
```json
{
  "items": [...],
  "page": 0,
  "size": 10,
  "total": 100
}
```

### Stable JSON Field Names

Generated models use `jsonStringify()` with original SQL column names:
- Database: `user_name` → JSON: `"user_name"` (not `"userName"`)
- Ensures API stability when refactoring schema

### SQL to Zig Type Mapping

| SQL type | Zig type |
|---|---|
| INT, INTEGER, BIGINT, SMALLINT, TINYINT, SERIAL | `i64` (or `?i64` if nullable) |
| VARCHAR, TEXT, CHAR, NVARCHAR, JSON, JSONB, UUID | `[]const u8` / `?[]const u8` |
| BOOLEAN, BOOL | `bool` / `?bool` |
| FLOAT, DOUBLE, REAL, NUMERIC, DECIMAL | `f64` / `?f64` |
| DATETIME, TIMESTAMP, DATE, TIME | `[]const u8` / `?[]const u8` |

`PRIMARY KEY` columns are always emitted as non-optional. Each model declares `pub const sql_table_name` so `zigmodu.orm` uses the real SQL table name (snake_case).

## Examples

### Complete Workflow

```bash
# 1. Create project
zmodu new ecommerce-app
cd ecommerce-app

# 2. Generate modules manually
zmodu module user
zmodu module order

# 3. Add APIs to modules
zmodu api users --module user
zmodu api orders --module order

# 4. Or generate everything from SQL
zmodu orm --sql schema.sql --out src/modules
```

### Example SQL Schema

```sql
CREATE TABLE user_profile (
    id BIGINT PRIMARY KEY COMMENT 'ID',
    user_name VARCHAR(255) NOT NULL COMMENT '用户名',
    email VARCHAR(255) NOT NULL COMMENT '邮箱',
    created_at TIMESTAMP COMMENT '创建时间'
);

CREATE TABLE order_item (
    id BIGINT PRIMARY KEY,
    user_id BIGINT NOT NULL,
    total DECIMAL(10,2) NOT NULL
);
```

Running `zmodu orm --sql schema.sql --out src/modules` produces:

```
src/modules/
├── user/
│   ├── root.zig
│   ├── module.zig
│   ├── model.zig          # UserProfile + sql_table_name + jsonStringify
│   ├── persistence.zig
│   ├── service.zig        # Paginated CRUD
│   └── api.zig            # bindJson + jsonStruct + sendError
└── order/
    ├── root.zig
    ├── module.zig
    ├── model.zig
    ├── persistence.zig
    ├── service.zig
    └── api.zig
```

Same SQL with `zmodu orm --sql schema.sql --out src/modules --backend zent` infers modules by table prefix and emits:

```
src/modules/
├── user/
│   ├── root.zig
│   ├── module.zig
│   ├── schema.zig            # UserProfile, OrderItem as zent Schema
│   └── client.zig
└── order/
    ├── root.zig
    ├── module.zig
    ├── schema.zig
    └── client.zig
```

## Features

### Code Generation
- ✅ PascalCase/camelCase/snake_case sanitization
- ✅ Zig 0.16.0 compatible
- ✅ No external dependencies
- ✅ Fast code generation
- ✅ Unified `generate` command
- ✅ `zmodu module <name>` emits the same `module.zig` shape as SQLx ORM (`zigmodu.api.Module`, `init` / `deinit`, templates under `src/templates/orm/sqlx/`)

### Backend Support
- ✅ **Sqlx Backend** - Full CRUD with HTTP API
- ✅ **Zent Backend** - Schema-as-Code with compile-time type safety

### Module Features
- ✅ Spring Modulith package-by-module structure
- ✅ Service + API scaffolding with DI via `ctx.user_data`
- ✅ Pagination support with PageResult
- ✅ Stable JSON field names via jsonStringify

### Zent Backend Features
- ✅ Schema-as-Code definition directly in Zig
- ✅ Full static type safety via comptime code generation
- ✅ Automatic TimeMixin for created_at/updated_at
- ✅ Type-safe query and mutation builders
- ✅ Graph traversal queries for relationships
