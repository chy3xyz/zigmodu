# Multi-Tenant Management System — ZigModu Best Practice Demo

A complete multi-tenant SaaS management system built with **ZigModu v0.13.15** / **Zig 0.17**, demonstrating framework best practices. This is the **flagship runnable example** (see `scripts/ci-integration.sh`).

> **多租户是可选项。** 本示例演示 Tenant → JWT → DataPermission 中间链 + 表级 `tenant_id` 隔离。单租户应用可省略租户中间件，见 [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md) § Multi-Tenancy (Optional) 与 [`examples/basic/`](../basic/)。

## Architecture

```
HTTP Request
  ↓
Middleware Chain (Tenant → JWT → DataPermission)
  ↓
API Routes (/api/v1/...)
  ↓
Service Layer (business logic + validation)
  ↓
Persistence Layer (SQLx/ORM repository)
  ↓
Database (tenants / users / subscriptions / plans)
```

## Module Structure (3 modules)

```
src/modules/
├── tenant/         # Tenant CRUD, tier management, status
│   ├── module.zig  # Declaration: name, dependencies, init/deinit
│   ├── model.zig   # Data structures + sql_table_name
│   ├── persistence.zig  # ORM repository (SQLx)
│   ├── service.zig      # Business logic + validation
│   ├── api.zig          # HTTP routes + JSON handlers
│   └── root.zig         # Barrel exports
├── user/           # User management, tenant-isolated queries
│   └── ... (same 6 files)
└── subscription/   # Plans, subscriptions, billing
    └── ... (same 6 files)
```

## Best Practices Demonstrated

| Practice | Implementation |
|----------|---------------|
| **Module System** | 3 modules, each with 6 standardized files |
| **Comptime Generics** | `TenantService(comptime Persistence: type)` |
| **Tenant Isolation** | All queries scoped by `tenant_id`, X-Tenant-ID header |
| **Error Handling** | RFC 7807 Problem Details via `zigmodu.sendProblem()` |
| **Middleware Chain** | Tenant → JWT → DataPermission ordered middleware |
| **API Versioning** | `/api/v1/` prefix with RouteGroup |
| **Health Probes** | `/health/live` for K8s liveness |
| **Dashboard** | Interactive HTMX + Alpine.js + TailwindCSS dashboard at `/dashboard` |
| **Business Enums** | Type-safe `TenantTier`, `UserRole`, `SubscriptionStatus` |
| **Lifecycle** | `scanModules` → `validateModules` → `startAll` / `stopAll` |
| **Dependency Injection** | Persistence → Service → API chain assembly |
| **Module Declaration** | Each module declares dependencies explicitly |

## Quick Start

```bash
# 1. Navigate
cd examples/tenant-mgmt

# 2. Set environment (default 18080 if unset; avoid conflicting with :8080)
export HTTP_PORT=18080
export JWT_SECRET=dev-secret          # HS256 signing key (AppSecurity + wall clock)
export TENANT_MGMT_SQLITE=:memory:   # or path to file

# 3. Run
zig build run
# → Server starts on http://localhost:18080

# 4. Get a JWT for API calls (from repo root)
# cd ../.. && zig build gen-jwt-token && JWT_SECRET=dev-secret ./zig-out/bin/gen-jwt-token

# 5. Explore
open http://localhost:18080/dashboard
```

## API Reference

### Tenants
| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/v1/tenants` | List all active tenants |
| `POST` | `/api/v1/tenants?name=X&domain=Y&tier=free` | Create tenant |
| `GET` | `/api/v1/tenants/{id}` | Get tenant details |
| `PUT` | `/api/v1/tenants/{id}/tier?tier=pro` | Upgrade/downgrade tier |
| `DELETE` | `/api/v1/tenants/{id}` | Suspend tenant |

### Users
| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/v1/users?tenant_id=1` | List users in tenant |
| `POST` | `/api/v1/users?tenant_id=1&username=X&email=Y&role=admin` | Create user |
| `GET` | `/api/v1/users/{id}?tenant_id=1` | Get user (tenant-isolated) |

### Subscriptions
| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/v1/plans` | List available plans |
| `POST` | `/api/v1/subscriptions?tenant_id=1&plan_id=2` | Subscribe tenant |
| `GET` | `/api/v1/subscriptions/{tenant_id}` | Get tenant subscription |
| `DELETE` | `/api/v1/subscriptions/{id}` | Cancel subscription |

### System
| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health/live` | K8s liveness probe |
| `GET` | `/dashboard` | Interactive monitor dashboard |
| `GET` | `/api/dashboard/modules` | Module list JSON |
| `GET` | `/api/dashboard/stats` | System statistics JSON |
| `GET` | `/api/dashboard/system` | System info JSON |

## Production Deployment

```bash
# Docker
docker compose -f ../../docker-compose.yml up -d

# Or standalone binary
zig build -Doptimize=ReleaseSafe
./zig-out/bin/tenant-mgmt
```

## File Count

```
24 files total:
  6 files/tenant module    (model, persistence, service, api, module, root)
  6 files/user module
  6 files/subscription module
  1 business enums
  1 middleware
  1 main.zig
  1 build.zig + build.zig.zon
  1 init.sql
  1 README.md
```
