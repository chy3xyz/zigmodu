const std = @import("std");

pub const TenantStatus = enum(i32) {
    active = 1,
    suspended = 0,
};

pub const TenantTier = enum {
    free,
    pro,
    enterprise,

    pub fn fromString(s: []const u8) TenantTier {
        if (std.mem.eql(u8, s, "pro")) return .pro;
        if (std.mem.eql(u8, s, "enterprise")) return .enterprise;
        return .free;
    }

    pub fn toString(self: TenantTier) []const u8 {
        return switch (self) {
            .free => "free",
            .pro => "pro",
            .enterprise => "enterprise",
        };
    }
};

pub const UserRole = enum {
    admin,
    staff,
    customer,

    pub fn fromString(s: []const u8) UserRole {
        if (std.mem.eql(u8, s, "admin")) return .admin;
        if (std.mem.eql(u8, s, "staff")) return .staff;
        return .customer;
    }

    pub fn toString(self: UserRole) []const u8 {
        return switch (self) {
            .admin => "admin",
            .staff => "staff",
            .customer => "customer",
        };
    }
};

pub const OrderStatus = enum {
    pending,
    paid,
    cancelled,
    fulfilled,

    pub fn toString(self: OrderStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .paid => "paid",
            .cancelled => "cancelled",
            .fulfilled => "fulfilled",
        };
    }
};

pub const PaymentStatus = enum {
    pending,
    succeeded,
    failed,

    pub fn toString(self: PaymentStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .succeeded => "succeeded",
            .failed => "failed",
        };
    }
};
