const persist = @import("persistence.zig");
const model = @import("model.zig");

const max_field: usize = 1024;

pub const CreativeService = struct {
    store: *persist.CreativeStore,

    pub fn init(store: *persist.CreativeStore) CreativeService {
        return .{ .store = store };
    }

    pub fn draft(self: *CreativeService, d: model.CreativeDraft) !i64 {
        try validateDraft(d);
        return try self.store.createDraft(d);
    }

    pub fn publish(self: *CreativeService, id: i64, price_cents: i64) !void {
        if (id <= 0 or price_cents < 0) return error.InvalidInput;
        const item = (try self.store.get(id)) orelse return error.NotFound;
        defer self.store.freeDto(item);
        try requireField(item.problem);
        try requireField(item.solution);
        try requireField(item.world);
        try self.store.publish(id, price_cents);
    }

    pub fn listPublished(self: *CreativeService) ![]model.CreativeDto {
        return try self.store.listPublished();
    }

    pub fn get(self: *CreativeService, id: i64) !?model.CreativeDto {
        return try self.store.get(id);
    }

    pub fn freeDto(self: *CreativeService, d: model.CreativeDto) void {
        self.store.freeDto(d);
    }

    pub fn freeList(self: *CreativeService, rows: []model.CreativeDto) void {
        self.store.freeList(rows);
    }
};

fn validateDraft(d: model.CreativeDraft) !void {
    if (d.owner_did.len == 0) return error.InvalidOwner;
    if (d.title.len == 0 or d.slug.len == 0) return error.InvalidTitle;
    try requireField(d.problem);
    try requireField(d.solution);
    try requireField(d.world);
}

fn requireField(s: []const u8) !void {
    if (s.len == 0 or s.len > max_field) return error.InvalidDomainField;
}
