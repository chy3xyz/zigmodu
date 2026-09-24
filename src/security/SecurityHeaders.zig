//! Security response headers — HSTS, X-Frame-Options, X-Content-Type-Options,
//! Referrer-Policy.
//!
//! **No Content-Security-Policy here on purpose.** `defaultHeaders` is the
//! CSP-free set: a policy that names no `script-src`/`style-src`/`default-src`
//! breaks inline scripts and third-party assets, so it can only be chosen by
//! the application, not defaulted in. The opt-in middleware
//! (`http_middleware.securityHeaders(null)`) supplies `defaultCsp`
//! (`object-src 'none'; base-uri 'self'; frame-ancestors 'none'`) along with
//! these headers, and takes a caller-supplied slice when a tighter policy is
//! wanted.
//!
//! The middleware lives in `http_middleware.securityHeaders` (canonical);
//! this file keeps the default header data for backwards compatibility
//! (`zigmodu.security.defaultSecurityHeaders`).

const middleware = @import("../api/Middleware.zig");

/// Pre-configured security headers for production deployment (CSP-free).
pub const defaultHeaders = middleware.defaultSecurityHeaders;
