// image service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const image_svc = @import("service.zig");

pub const ImageServiceExt = struct {
    svc: *image_svc.ImageService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *image_svc.ImageService, backend: zigmodu.SqlxBackend) ImageServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
