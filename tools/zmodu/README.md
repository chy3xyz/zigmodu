# ZModu

Code generation tool for ZigModu framework with **Modulith style** architecture.

## Installation

```bash
cd tools/zmodu
zig build install-zmodu
```

Or run directly:
```bash
cd tools/zmodu
zig build run -- <command>
```

## Commands

### `new <name>`
Create a new ZigModu project.

```bash
zmodu new myapp
cd myapp
zig build run
```

### `module <name>`
Generate a module directory with Modulith structure.

```bash
zmodu module user
# Creates: src/modules/user/module.zig
```

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

# Force all tables into a single module
zmodu orm --sql schema.sql --module user --out src/modules

# Generate with zent Schema-as-Code backend
zmodu orm --sql schema.sql --out src/modules --backend zent
```

Creates a complete module directory for each inferred module:

**Sqlx Backend** (default):
```
src/modules/{module}/
├── module.zig       # ZigModu module metadata (init/deinit)
├── model.zig        # Domain models with JSON serialization
├── persistence.zig  # ORM Repository layer (SqlxBackend)
├── service.zig      # Business service with paginated CRUD
└── api.zig          # HTTP API handlers using api.Server.zig
```

**Zent Backend**:
```
src/modules/{module}/
├── module.zig       # ZigModu module metadata (init/deinit)
├── schema.zig       # zent Schema definitions (Schema-as-Code)
└── client.zig       # zent Client helper
```

### `generate <target> [options]`
Unified generator command supporting all targets.

```bash
# Generate empty module
zmodu generate module user

# Generate module from SQL (same as 'orm')
zmodu generate module --sql schema.sql --out src/modules

# Generate event
zmodu generate event order-created

# Generate API within module
zmodu generate api users --module user

# Generate ORM (alias for 'orm')
zmodu generate orm --sql schema.sql
```

## Modulith Architecture

ZModu promotes **Modulith** (Modular Monolith) architecture:

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

### Code Generation
- ✅ PascalCase/camelCase/snake_case sanitization
- ✅ Zig 0.16.0 compatible
- ✅ No external dependencies
- ✅ Fast code generation
- ✅ Unified `generate` command

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

- ✅ PascalCase/camelCase/snake_case sanitization
- ✅ Zig 0.16.0 compatible
- ✅ No external dependencies
- ✅ Fast code generation
- ✅ Spring Modulith package-by-module structure
- ✅ Service + API scaffolding with DI via `ctx.user_data`
- ✅ Pagination support with PageResult
- ✅ Stable JSON field names via jsonStringify
- ✅ Unified `generate` command
