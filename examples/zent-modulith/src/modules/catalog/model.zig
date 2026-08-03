//! zent Schema-as-code — domain model for the ZigModu + zent demo.
const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const Tenant = Schema("Tenant", .{
    .fields = &.{
        field.String("name"),
        field.String("domain"),
    },
});

pub const Product = Schema("Product", .{
    .fields = &.{
        field.Int("tenant_id"),
        field.String("name"),
        field.Int("price_cents"),
    },
});

/// Data-scope demo entity: row-level access controlled by
/// `zent.data_scope.Policy` (owner_id / dept_id scopes).
pub const Doc = Schema("Doc", .{
    .fields = &.{
        field.Int("tenant_id"),
        field.Int("owner_id"),
        field.Int("dept_id"),
        field.String("title"),
    },
    .policy = zent.data_scope.Policy,
});
