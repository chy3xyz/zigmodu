// article service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const article_svc = @import("service.zig");

pub const ArticleServiceExt = struct {
    svc: *article_svc.ArticleService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *article_svc.ArticleService, backend: zigmodu.SqlxBackend) ArticleServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
