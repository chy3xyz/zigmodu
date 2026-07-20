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
