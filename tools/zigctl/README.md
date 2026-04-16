# ZigCtl

Code generation tool for ZigModu framework.

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
Generate a module boilerplate.

```bash
zigctl module user
```

Creates `src/modules/user.zig` with module metadata and lifecycle hooks.

### `event <name>`
Generate an event handler.

```bash
zigctl event order-created
```

Creates `src/events/order-created.zig` with event struct and handler function.

### `api <name>`
Generate an API endpoint with CRUD routes.

```bash
zigctl api users
```

Creates `src/api/users.zig` with GET/POST/PUT/DELETE handlers.

### `orm`
Generate ORM models and repositories from SQL DDL.

```bash
# Auto-partition by table prefix (user_profile → user module)
zigctl orm --sql schema.sql --out src/modules

# Force all tables into a single module
zigctl orm --sql schema.sql --module user --out src/modules
```

Creates `{module}_persistence.zig` with:
- Model structs mapped from SQL columns
- Repository accessors via `zigmodu.orm.Orm(zigmodu.SqlxBackend)`
- A `Persistence` struct to manage backend/orm lifecycle

## Examples

```bash
# Create new project
zigctl new ecommerce-app
cd ecommerce-app

# Generate modules
zigctl module user
zigctl module order
zigctl module payment

# Generate events
zigctl event order-placed
zigctl event payment-completed

# Generate APIs
zigctl api users
zigctl api orders

# Generate ORM from schema
zigctl orm --sql schema.sql --out src/modules
```

## SQL to Zig type mapping

| SQL type | Zig type |
|---|---|
| INT, INTEGER, BIGINT, SMALLINT, TINYINT, SERIAL | `i64` |
| VARCHAR, TEXT, CHAR, NVARCHAR, JSON, JSONB, UUID | `[]const u8` |
| BOOLEAN, BOOL | `bool` |
| FLOAT, DOUBLE, REAL, NUMERIC, DECIMAL | `f64` |
| DATETIME, TIMESTAMP, DATE, TIME | `[]const u8` |
Generate an API endpoint with CRUD routes.

```bash
zigctl api users
```

Creates `src/api/users.zig` with GET/POST/PUT/DELETE handlers.

## Examples

```bash
# Create new project
zigctl new ecommerce-app
cd ecommerce-app

# Generate modules
zigctl module user
zigctl module order
zigctl module payment

# Generate events
zigctl event order-placed
zigctl event payment-completed

# Generate APIs
zigctl api users
zigctl api orders
```

## Features

- ✅ PascalCase/camelCase/snake_case sanitization
- ✅ Zig 0.15.2 compatible
- ✅ No external dependencies
- ✅ Fast code generation