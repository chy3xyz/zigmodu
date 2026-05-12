//! Security domain: auth, RBAC, API keys, secrets, password, JWT.
//! Import directly: `const security = @import("zigmodu").security;`

pub const SecurityModule = @import("security/SecurityModule.zig").SecurityModule;
pub const auth = @import("security/AuthMiddleware.zig");
pub const Rbac = @import("security/Rbac.zig");
pub const PasswordEncoder = @import("security/PasswordEncoder.zig").PasswordEncoder;
pub const ApiKeyAuth = @import("security/ApiKeyAuth.zig").apiKeyAuth;
pub const ApiKeyAuthWithLoader = @import("security/ApiKeyAuth.zig").apiKeyAuthWithLoader;
pub const ApiKeyGenerator = @import("security/ApiKeyAuth.zig").ApiKeyGenerator;
pub const ApiKeyConfig = @import("security/ApiKeyAuth.zig").ApiKeyConfig;
pub const SecurityScanner = @import("security/SecurityScanner.zig").SecurityScanner;
pub const DependencyScanner = @import("security/SecurityScanner.zig").DependencyScanner;
pub const SecurityConfigValidator = @import("security/SecurityScanner.zig").SecurityConfigValidator;
pub const SecretsManager = @import("secrets/SecretsManager.zig").SecretsManager;
pub const SecretEntry = @import("secrets/SecretsManager.zig").SecretsManager.SecretEntry;
pub const SecretsSourcePriority = @import("secrets/SecretsManager.zig").SecretsSourcePriority;
