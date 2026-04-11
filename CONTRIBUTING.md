# Contributing to ZigModu

First off, thank you for considering contributing to ZigModu! It's people like you that make ZigModu such a great tool.

## Code of Conduct

This project and everyone participating in it is governed by our commitment to:
- Being respectful and inclusive
- Welcoming newcomers
- Focusing on constructive feedback
- Prioritizing the community's success

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check the existing issues to see if the problem has already been reported. When you are creating a bug report, please include as many details as possible:

- **Use a clear and descriptive title**
- **Describe the exact steps to reproduce the problem**
- **Provide specific examples to demonstrate the steps**
- **Describe the behavior you observed and what behavior you expected**
- **Include code samples and Zig version information**

Example:
```
**Zig Version:** 0.15.2
**ZigModu Version:** 0.1.0
**OS:** macOS 14.0

**Steps to Reproduce:**
1. Define a module with circular dependency
2. Run `zig build`
3. See error

**Expected Behavior:**
Clear error message about circular dependency

**Actual Behavior:**
Compiler panic with stack trace
```

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion, please include:

- **Use a clear and descriptive title**
- **Provide a step-by-step description of the suggested enhancement**
- **Provide specific examples to demonstrate the enhancement**
- **Explain why this enhancement would be useful**

### Pull Requests

1. Fork the repository
2. Create a new branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Run the tests (`zig build test`)
5. Commit your changes (`git commit -m 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

## Development Setup

### Prerequisites

- Zig 0.15.2 or later
- Git

### Building the Project

```bash
# Clone your fork
git clone https://github.com/yourusername/zigmodu.git
cd zigmodu

# Build the project
zig build

# Run tests
zig build test

# Run the example
zig build run
```

### Project Structure

```
zigmodu/
├── src/              # Source code
│   ├── api/          # Public API
│   ├── core/         # Core implementation
│   ├── di/           # Dependency injection
│   ├── config/       # Configuration
│   ├── log/          # Logging
│   └── test/         # Testing utilities
├── example/          # Example application
├── docs/             # Documentation
└── benchmarks/       # Performance benchmarks
```

## Coding Standards

### Zig Style Guide

We follow the official Zig style conventions:

- **Indentation:** 4 spaces (no tabs)
- **Line length:** Max 100 characters
- **Naming:**
  - Functions: `camelCase`
  - Types: `PascalCase`
  - Constants: `snake_case`
  - Variables: `snake_case`

Example:
```zig
const MyStruct = struct {
    field_name: i32,
    
    pub fn doSomething(self: *MyStruct) !void {
        const local_var = 42;
        try someFunction(local_var);
    }
};
```

### Code Quality

- **Explicit error handling** - Always handle errors explicitly
- **Memory safety** - Proper allocation and deallocation
- **Documentation** - Document public APIs with doc comments
- **Tests** - Add tests for new functionality

### Documentation

Public APIs should be documented:

```zig
/// Represents a business module in the application.
/// Modules can have dependencies and lifecycle hooks.
pub const Module = struct {
    /// Unique name of the module
    name: []const u8,
    
    /// Human-readable description
    description: []const u8 = "",
    
    /// List of module names this module depends on
    dependencies: []const []const u8 = &.{},
};
```

## Testing Guidelines

### Writing Tests

All new functionality should include tests:

```zig
test "feature description" {
    const allocator = std.testing.allocator;
    
    // Setup
    var obj = try MyType.init(allocator);
    defer obj.deinit();
    
    // Test
    try obj.doSomething();
    
    // Assert
    try std.testing.expectEqual(expected, actual);
}
```

### Test Categories

1. **Unit tests** - Test individual functions
2. **Integration tests** - Test module interactions
3. **Example tests** - Test example applications

Run specific test categories:
```bash
# All tests
zig build test

# Specific module tests
zig test src/core/Module.zig
```

## Commit Message Guidelines

We follow conventional commits:

- `feat:` New feature
- `fix:` Bug fix
- `docs:` Documentation changes
- `style:` Code style changes (formatting)
- `refactor:` Code refactoring
- `test:` Test additions or corrections
- `chore:` Build process or auxiliary tool changes

Example:
```
feat: add event bus for inter-module communication

- Implement type-safe event bus
- Add subscribe/publish methods
- Include unit tests
```

## Release Process

1. Update version in `build.zig.zon`
2. Update `CHANGELOG.md`
3. Create a git tag: `git tag v0.x.x`
4. Push tag: `git push origin v0.x.x`
5. Create GitHub release with notes

## Getting Help

- **Discord:** [Zig Discord](https://discord.gg/zig)
- **GitHub Issues:** For bug reports and feature requests
- **Discussions:** For questions and ideas

## Recognition

Contributors will be recognized in our README.md and release notes.

Thank you for contributing to ZigModu! 🎉