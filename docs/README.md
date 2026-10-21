# zmodu Documentation

zmodu is a compile-time modular application framework and a bounded,
replayable runtime for Zig 0.17.

- Website: https://chy3xyz.github.io/zmodu/
- Repository: https://github.com/chy3xyz/zmodu
- Releases: https://github.com/chy3xyz/zmodu/releases

## Start here

| Page | What it covers |
|------|----------------|
| [Quick start](./guide/QUICK-START.md) | Install, create an app, run the first route |
| [Modules](./guide/MODULITH.md) | Module contract, lifecycle, dependency rules |
| [Routing](./reference/ROUTE_TABLE.md) | Compile-time routes, metadata, auth wiring |
| [Runtime](./reference/RUNTIME.md) | Workers, mailboxes, scheduler, timers, replay |
| [Data](./guide/SQLX_DRIVERS.md) | SQLx drivers, repositories, migrations |
| [Observability](./reference/OBSERVABILITY.md) | Logs, metrics, tracing, health checks |
| [Deployment](./guide/BEST_PRACTICES.md) | Production defaults and operating notes |
| [CLI](./guide/ZMODU_CLI_INTEGRATION.md) | `zmodu` generator and maintenance commands |
| [Upgrading](./reference/UPGRADING.md) | Breaking changes and migration steps |

## Guides

Task-oriented pages live in [`guide/`](./guide/):

- [Quick start](./guide/QUICK-START.md)
- [Modulith](./guide/MODULITH.md)
- [Module layers](./guide/MODULE_LAYERS.md)
- [Events and DI](./guide/EVENTS_DI.md)
- [Logging](./guide/LOGGING.md)
- [Workflow](./guide/WORKFLOW.md)
- [SQLx drivers](./guide/SQLX_DRIVERS.md)
- [Best practices](./guide/BEST_PRACTICES.md)
- [Cluster quick start](./guide/CLUSTER-QUICKSTART.md)
- [CLI integration](./guide/ZMODU_CLI_INTEGRATION.md)
- [Tenant shop example](./guide/MODULITH_TENANT_SHOP.md)

## Reference

Contracts and internals live in `reference/`:

- [Architecture](./reference/ARCHITECTURE.md)
- [API](./reference/API.md)
- [Route table](./reference/ROUTE_TABLE.md)
- [Runtime](./reference/RUNTIME.md)
- [Concurrency](./reference/CONCURRENCY.md)
- [Compile-time budget](./reference/COMPTIME.md)
- [Observability](./reference/OBSERVABILITY.md)
- [Distributed](./reference/DISTRIBUTED.md)
- [Agent runtime](./reference/AGENT_RUNTIME.md)
- [Web4](./reference/WEB4.md)
- [AI boundary](./reference/AI_BOUNDARY.md)
- [API freeze](./reference/API_FREEZE.md)
- [Zent ORM](./reference/ZENT.md)
- [Upgrading](./reference/UPGRADING.md)

## AI

- [AI overview](./ai/AI.md)
- [AI development guide](./ai/AI_DEV_GUIDE.md)
- [Orchestration](./ai/AI_ORCHESTRATION.md)
- [Skills](./ai/AI_SKILLS.md)
- [LLM policies](./ai/LLM_POLICIES.md)
- [MCP](./ai/MCP.md)

## Other

- `dev/` — maintainer notes; not published.
- `archive/` — historical snapshots; not published.
