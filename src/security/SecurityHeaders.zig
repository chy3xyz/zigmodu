//! Security response headers — HSTS, X-Frame-Options, X-Content-Type-Options,
//! CSP, Referrer-Policy.
//!
//! The middleware lives in `http_middleware.securityHeaders` (canonical);
//! this file keeps the default header data for backwards compatibility
//! (`zigmodu.security.defaultSecurityHeaders`).

const middleware = @import("../api/Middleware.zig");

/// Pre-configured security headers for production deployment.
pub const defaultHeaders = middleware.defaultSecurityHeaders;
