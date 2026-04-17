# ZigCtl

Code generation tool for ZigModu framework with **Modulith style** architecture.

## Installation

```bash
cd tools/zigctl
zig build install-zigctl
```

Or run directly:
```bash
cd tools/zigctl
zig build run -- <command>
```

## Commands

### `new <name>`
Create a new ZigModu project.

```bash
zigctl new myapp
cd myapp
zig build run
```

### `module <name>`
Generate a module directory with Modulith structure.

```bash
zigctl module user
# Creates: src/modules/user/module.zig
```

### `event <name>`
Generate an event handler.

```bash
zigctl event order-created
# Creates: src/events/order-created.zig
```

### `api <name> [--module <module-name>]`
Generate an API endpoint. Optionally place within a module.

```bash
# Standalone API
zigctl api users
# Creates: src/api/users.zig

# API within a module (Modulith style)
zigctl api users --module user
# Creates: src/modules/user/api_users.zig
```

### `orm`
Generate complete modules from SQL DDL with full CRUD.

```bash
# Auto-partition by table prefix (user_profile → user module)
zigctl orm --sql schema.sql --out src/modules

# Force all tables into a single module
zigctl orm --sql schema.sql --module user --out src/modules
```

Creates a complete module directory for each inferred module:

```
src/modules/{module}/
├── module.zig       # ZigModu module metadata (init/deinit)
├── model.zig        # Domain models with JSON serialization
├── persistence.zig  # ORM Repository layer (SqlxBackend)
├── service.zig      # Business service with paginated CRUD
└── api.zig          # HTTP API handlers using api.Server.zig
```

### `generate <target> [options]`
Unified generator command supporting all targets.

```bash
# Generate empty module
zigctl generate module user

# Generate module from SQL (same as 'orm')
zigctl generate module --sql schema.sql --out src/modules

# Generate event
zigctl generate event order-created

# Generate API within module
zigctl generate api users --module user

# Generate ORM (alias for 'orm')
zigctl generate orm --sql schema.sql
```

## Modulith Architecture

ZigCtl promotes **Modulith** (Modular Monolith) architecture:

- **Package by Module**: Each module is a self-contained directory
- **Explicit Boundaries**: Module dependencies declared in `info.dependencies`
- **Cohesive Structure**: Domain, persistence, service, and API live together

```
src/modules/
├── user/                      # User module
│   ├── module.zig            # Module metadata & lifecycle
│   ├── model.zig             # Domain models
│   ├── persistence.zig       # Repository layer
│   ├── service.zig           # Business logic
│   └── api.zig               # HTTP handlers
├── order/                     # Order module
│   ├── module.zig
│   ├── model.zig
│   ├── persistence.zig
│   ├── service.zig
│   └── api.zig
└── payment/                   # Payment module
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
| INT, INTEGER, BIGINT, SMALLINT, TINYINT, SERIAL | `i64` |
| VARCHAR, TEXT, CHAR, NVARCHAR, JSON, JSONB, UUID | `[]const u8` |
| BOOLEAN, BOOL | `bool` |
| FLOAT, DOUBLE, REAL, NUMERIC, DECIMAL | `f64` |
| DATETIME, TIMESTAMP, DATE, TIME | `[]const u8` |

## Examples

### Complete Workflow

```bash
# 1. Create project
zigctl new ecommerce-app
cd ecommerce-app

# 2. Generate modules manually
zigctl module user
zigctl module order

# 3. Add APIs to modules
zigctl api users --module user
zigctl api orders --module order

# 4. Or generate everything from SQL
zigctl orm --sql schema.sql --out src/modules
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

Running `zigctl orm --sql schema.sql --out src/modules` produces:

```
src/modules/
├── user/
│   ├── module.zig
│   ├── model.zig          # UserProfile with jsonStringify
│   ├── persistence.zig
│   ├── service.zig        # Paginated CRUD
│   └── api.zig            # /user_profiles?page=0&size=10
└── order/
    ├── module.zig
    ├── model.zig
    ├── persistence.zig
    ├── service.zig
    └── api.zig
```

## Features

- ✅ PascalCase/camelCase/snake_case sanitization
- ✅ Zig 0.16.0 compatible
- ✅ No external dependencies
- ✅ Fast code generation
- ✅ Spring Modulith package-by-module structure
- ✅ Service + API scaffolding with DI via `ctx.user_data`
- ✅ Pagination support with PageResult
- ✅ Stable JSON field names via jsonStringify
- ✅ Unified `generate` command
