# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
## [0.6.4] - 2026-04-19



### Fixed

- `zig build test` now works reliably by using direct `zig test` invocation

  - Workaround for Zig 0.16.0 server-mode test runner EndOfStream issue

- All 194 tests passing (189 passed, 5 skipped)



### Changed

- **LRU Cache** rewritten with true LRU eviction (HashMap + access order list)

  - `get()` now returns `*V` pointer for zero-copy access

- **HTTP Server** added `max_concurrent` limit to prevent unbounded thread growth

- **DI Container** added `getComptime()` for compile-time type-safe resolution



## [0.6.3] - 2026-04-19



### Added

- **DistributedEventBus** fully implemented with heartbeat mechanism

- **HotReloader** runtime module update detection with `Io.sleep` polling

- **WebSocketServer** metrics broadcast capability

- **PluginManager** stabilized (removed EXPERIMENTAL marker)



### Fixed

- **Io.net API** migration to Zig 0.16.0 format across all modules

  - `address.listen(io, opts)` instead of `std.Io.net.listen(&address, io, opts)`

  - `address.connect(io, opts)` instead of `std.Io.net.Stream.connect(&address, io, opts)`

  - Fixed in: `api/Server.zig`, `core/DistributedEventBus.zig`, `core/WebMonitor.zig`, `core/WebSocket.zig`, `http/HttpClient.zig`, `redis/redis.zig`



## [0.6.2] - 2026-04-19



### Changed

- **zmodu CLI** zent backend aligned with zent v0.1.1 API

  - Chain-style field definition: `field.Int("id").Unique().Required()`

  - Smart `TimeMixin` generation for `created_at`/`updated_at` fields

  - Support for `.Default()` and `.Unique()` modifiers



## [0.6.1] - 2026-04-19
## [0.4.0] - 2025-04-15

### Added
- **Distributed Capabilities**
  - `DistributedEventBus` for cross-node event communication
  - `ClusterMembership` for node discovery and health checking
  - `PasRaftAdapter` for Raft consensus (leader election, log replication)
  - `DistributedTransaction` for saga-based transactions

- **Transport Protocols**
  - `GrpcTransport` for high-performance RPC
  - `MqttTransport` for IoT message queuing
  - `HttpClient` with connection pooling and retry policy
  - `Router` for HTTP routing with middleware

- **Resilience Patterns**
  - `CircuitBreaker` with state management (closed/open/half-open)
  - `CircuitBreakerRegistry` for managing multiple breakers
  - `RateLimiter` with token bucket algorithm
  - `RateLimiterRegistry` for per-client limiting

- **Observability**
  - `DistributedTracer` compatible with OpenTelemetry
  - Jaeger and Zipkin export support
  - `PrometheusMetrics` with Counter, Gauge, Histogram, Summary
  - `AutoInstrumentation` for automatic module instrumentation
  - `StructuredLogger` with JSON formatting

- **Security**
  - `JwtModule` for JWT token generation and verification
  - `SecurityScanner` for static code analysis
  - `SecurityRule` for custom vulnerability detection

- **Configuration**
  - `YamlToml` parser for YAML configuration files
  - `TomlLoader` for TOML configuration files
  - `ExternalizedConfig` with priority-based loading
  - File watching and hot-reload support

- **Developer Experience**
  - `HotReloader` for runtime module updates
  - `PluginManager` for dynamic extension loading
  - `WebMonitor` for HTTP dashboard
  - `ArchitectureTester` for design rule validation

- **Testing**
  - `IntegrationTest` framework with HTTP and DB testing
  - `Benchmark` for performance benchmarking
  - `ModulithTest` for full application testing

- **Documentation**
  - Complete API reference (`docs/API.md`)
  - Best practices guide with progressive architecture evolution
  - Code completeness assessment report

### Changed
- Restructured project documentation
- Removed internal development docs
- Updated README.md with complete feature overview

## [0.3.0] - 2025-04-10

### Added
- YAML and TOML configuration support
- WebSocket support for real-time monitoring
- Module hot-reloading capability
- Plugin system for dynamic extensions
- Web monitoring interface
- Event store for event sourcing
- Transactional events with saga pattern
- Module capabilities and boundary enforcement

### Fixed
- Memory management improvements
- Error handling enhancements
- Build system optimizations

## [0.2.0] - 2025-04-08

### Added
- `CacheManager` for local caching with eviction policies
- `TaskScheduler` for cron and interval tasks
- `Database` abstraction with transaction support
- `Repository` pattern for data access
- `HealthEndpoint` for application health checks
- `ModuleCanvas` for module visualization
- `ModuleCapabilities` for API boundary definition
- `ModuleContract` for formal module contracts
- `C4ModelGenerator` for architecture diagrams

### Changed
- Improved module scanning performance
- Enhanced dependency validation logic
- Updated example applications

## [0.1.0] - 2025-04-08

### Added
- Core framework implementation
- Module definition and registration system
- Compile-time module scanning with `@hasDecl`
- Module dependency validation
- Event bus with type-safe publish/subscribe
- Lifecycle management (startAll/stopAll)
- PlantUML documentation generation
- Dependency injection container (`Container`, `ScopedContainer`)
- Configuration loader for JSON files
- Module logger with context
- Module testing utilities (`ModuleTestContext`)
- Example application demonstrating all features
- Build system configuration for Zig 0.16.0
- Unit tests for all major components
- README in English and Chinese
- Contributing guidelines
- MIT License

### Technical Details
- **Zig Version:** 0.16.0
- **Memory Management:** Explicit allocator pattern
- **Error Handling:** Zig error union types
- **Testing:** Built-in test runner

[Unreleased]: https://github.com/knot3bot/zigmodu/compare/v0.6.4...HEAD
[0.6.4]: https://github.com/knot3bot/zigmodu/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/knot3bot/zigmodu/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/knot3bot/zigmodu/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/knot3bot/zigmodu/compare/v0.4.0...v0.6.1
[0.4.0]: https://github.com/knot3bot/zigmodu/compare/v0.3.0...v0.4.0
[0.4.0]: https://github.com/knot3bot/zigmodu/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/knot3bot/zigmodu/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/knot3bot/zigmodu/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/knot3bot/zigmodu/releases/tag/v0.1.0