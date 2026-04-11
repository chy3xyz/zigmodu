# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial implementation of core module system
- Module dependency validation (compile-time and runtime)
- Type-safe event bus for inter-module communication
- Automatic PlantUML documentation generation
- Dependency injection container
- JSON configuration loader
- Module-specific logging utilities
- Module testing utilities
- Example application with order/payment/inventory modules
- Comprehensive test suite
- MIT License
- Contributing guidelines

## [0.1.0] - 2025-04-08

### Added
- Core framework implementation
- Module definition and registration system
- Compile-time module scanning with `@hasDecl`
- Module dependency validation
- Event bus with type-safe publish/subscribe
- Lifecycle management (startAll/stopAll)
- PlantUML documentation generation
- Dependency injection container (`Container`, `ModuleContainer`)
- Configuration loader for JSON files
- Module logger with context
- Module testing utilities (`ModuleTestContext`)
- Example application demonstrating all features
- Build system configuration for Zig 0.15.2
- Unit tests for all major components
- README in English and Chinese
- Contributing guidelines
- MIT License

### Technical Details
- **Zig Version:** 0.15.2
- **Dependencies:** zio 0.9.0+
- **Memory Management:** Explicit allocator pattern
- **Error Handling:** Zig error union types
- **Testing:** Built-in test runner

### Known Limitations
- YAML/TOML configuration not yet supported (zig-yaml dependency unavailable)
- Module hot-reloading not implemented
- Distributed event bus not implemented
- Web monitoring interface not implemented

[Unreleased]: https://github.com/yourusername/zigmodu/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/yourusername/zigmodu/releases/tag/v0.1.0