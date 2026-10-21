---
layout: home
title: zmodu documentation

hero:
  name: zmodu
  text: Modular applications and a bounded runtime for Zig
  tagline: Routes and dependencies resolve at compile time. Workers, mailboxes and timers stay bounded at run time.
  actions:
    - theme: brand
      text: Quick start
      link: ./guide/QUICK-START
    - theme: alt
      text: Runtime
      link: ./reference/RUNTIME

features:
  - title: Compile-time routing
    details: One route table per module. Auth, permissions and OpenAPI metadata sit next to the handler, and duplicate paths fail before the server starts.
    link: ./reference/ROUTE_TABLE
    linkText: Route table
  - title: Module boundaries
    details: Dependencies are declared and checked at startup. Missing, self and cyclic edges stop the application.
    link: /docs/guide/MODULITH
    linkText: Modules
  - title: Bounded runtime
    details: A worker owns its state, a mailbox owns the handoff, and a full queue returns error.Full instead of growing.
    link: ./reference/RUNTIME
    linkText: Runtime
  - title: Deterministic replay
    details: A controlled clock, random source and event sequence make the same input produce the same order and output.
    link: ./reference/RUNTIME
    linkText: Replay
  - title: Built-in observability
    details: Structured logs, Prometheus metrics and OTLP tracing are part of the framework, not an add-on.
    link: ./reference/OBSERVABILITY
    linkText: Observability
  - title: Data and AI
    details: SQLx, Redis, Kafka and the zent ORM stay at the application layer. Agents, RAG and approvals compose as modules.
    link: ./ai/AI
    linkText: AI
---

# Start

- [Quick start](./guide/QUICK-START.md) — install and run the first route.
- [Modules](./guide/MODULITH.md) — write a module and compose an application.
- [Runtime](./reference/RUNTIME.md) — workers, mailboxes, scheduler and replay.
- [API](./reference/API.md) — the public surface.
- [Upgrading](./reference/UPGRADING.md) — breaking changes and migrations.
