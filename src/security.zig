//! Security domain: auth, RBAC, API keys, secrets, password, JWT.
//! Import directly: `const security = @import("zigmodu").security;`

/// Auth + authorization + encryption bundle; `AppSecurity` wires it to an app.
pub const SecurityModule = @import("security/SecurityModule.zig").SecurityModule;
/// Production security bundle tied to the wall clock + HTTP middleware helpers.
pub const AppSecurity = @import("security/AppSecurity.zig").AppSecurity;
/// Legacy JWT/RBAC middleware barrel — it writes only `auth_info`.
pub const auth = @import("security/AuthMiddleware.zig");
/// RBAC model: roles, menus, data scopes, role↔permission tables.
pub const Rbac = @import("security/Rbac.zig");
/// SQLite-backed role→permission loader for catalog JWT (Path A).
pub const CatalogPermDb = @import("security/CatalogPermDb.zig");
/// Role→permission pairs for a custom `CatalogPermissionLoader`.
pub const RolePermissionTable = Rbac.RolePermissionTable;
/// PBKDF2-HMAC-SHA256 password hashing/verification (100K iterations).
pub const PasswordEncoder = @import("security/PasswordEncoder.zig").PasswordEncoder;
/// API-key middleware factory backed by an in-memory key store.
pub const ApiKeyAuth = @import("security/ApiKeyAuth.zig").apiKeyAuth;
/// API-key middleware whose key→identity lookup comes from your loader/DB.
pub const ApiKeyAuthWithLoader = @import("security/ApiKeyAuth.zig").apiKeyAuthWithLoader;
/// Creates API keys: prefixed public id plus hashed secret.
pub const ApiKeyGenerator = @import("security/ApiKeyAuth.zig").ApiKeyGenerator;
/// API-key auth settings (header name, hashing, scopes).
pub const ApiKeyConfig = @import("security/ApiKeyAuth.zig").ApiKeyConfig;
/// Static checks: hardcoded secrets, weak crypto, unsafe config drift.
pub const SecurityScanner = @import("security/SecurityScanner.zig").SecurityScanner;
/// Flags dependencies with known-vulnerable versions or suspicious patterns.
pub const DependencyScanner = @import("security/SecurityScanner.zig").DependencyScanner;
/// Validates security config: JWT secret strength, CORS, cookie flags.
pub const SecurityConfigValidator = @import("security/SecurityScanner.zig").SecurityConfigValidator;
/// Secret lookup with source precedence env > file > Vault KV v2.
pub const SecretsManager = @import("secrets/SecretsManager.zig").SecretsManager;
/// A resolved secret: key, value, and the source it came from.
pub const SecretEntry = @import("secrets/SecretsManager.zig").SecretsManager.SecretEntry;
/// Source precedence for secrets: env(0) > file > vault > default.
pub const SecretsSourcePriority = @import("secrets/SecretsManager.zig").SecretsSourcePriority;
/// Baseline security headers (CSP/HSTS/X-Frame-Options…) to attach to responses.
pub const defaultSecurityHeaders = @import("security/SecurityHeaders.zig").defaultHeaders;
/// Normalizes a user-supplied path and rejects traversal escapes.
pub const sanitizePath = @import("security/PathSanitizer.zig").sanitizePath;
/// Throttles auth endpoints to blunt credential stuffing and brute force.
pub const authRateLimitMiddleware = @import("security/SecurityModule.zig").authRateLimitMiddleware;
/// JWKS key ring: sign with the active kid, verify with any (key rotation).
pub const JwksKeyRing = @import("security/JwksKeyRing.zig").JwksKeyRing;
