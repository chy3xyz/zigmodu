pub const Container = @import("di/Container.zig").Container;
pub const ScopedContainer = @import("di/Container.zig").ScopedContainer;

// Configuration
pub const ConfigLoader = @import("config/Loader.zig").ConfigLoader;
pub const ModuleConfig = @import("config/Loader.zig").ModuleConfig;
pub const ConfigManager = @import("config/ConfigManager.zig").ConfigManager;

// Logging
pub const ModuleLogger = @import("log/ModuleLogger.zig").ModuleLogger;
pub const LogScope = @import("log/ModuleLogger.zig").LogScope;

// Testing
pub const ModuleTestContext = @import("test/ModuleTest.zig").ModuleTestContext;
pub const createMockModule = @import("test/ModuleTest.zig").createMockModule;
