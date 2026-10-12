---
layout: home

hero:
  name: ZigModu
  text: A modular framework for Zig
  tagline: Build services as modules — compose, route, observe, evolve.
  actions:
    - theme: brand
      text: Read the documentation
      link: /README
    - theme: alt
      text: Architecture
      link: /ARCHITECTURE
    - theme: alt
      text: Quick Start
      link: /QUICK-START

features:
  - title: Modulith, not microservices
    details: Compose modules in one process while keeping their boundaries honest. Extract a service later if the boundary was real.
    link: /MODULITH
    linkText: Modulith
  - title: Explicit routing
    details: One route table, resolved at comptime. No reflection, no string dispatch, no ambient registration.
    link: /ROUTE_TABLE
    linkText: Route table
  - title: Built-in observability
    details: Structured logging and Prometheus metrics with fairness guarantees across priority pools.
    link: /OBSERVABILITY
    linkText: Observability
  - title: Distributed when needed
    details: A Raft implementation with mixed-version compatibility and mutation-tested invariants.
    link: /DISTRIBUTED
    linkText: Distributed
---

## Where to go next

The **[documentation index](./dev/archive/README.md)** is the full map — it lists every document
by role, so an agent or a newcomer can pick a path without guessing.

Start with **[AGENTS.md](https://github.com/chy3xyz/zigmodu/blob/master/AGENTS.md)**
if you are driving this repository with an LLM: it is the canonical doc map,
including the DO / DON'T list and the auth Path A rules.
