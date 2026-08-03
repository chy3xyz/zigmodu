//! zent Schema-as-code — domain model for the ZigModu + zent demo.
const zent = @import("zent");
const field = zent.core.field;
const edge = zent.core.edge;
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

/// Social-feed demo: Author → posts → comments (two-level nested preload
/// via `WithEdge("posts.comments")`).
pub const Comment = Schema("Comment", .{
    .fields = &.{
        field.Int("post_id"),
        field.String("body"),
    },
});

pub const Post = Schema("Post", .{
    .fields = &.{
        field.Int("author_id"),
        field.String("title"),
    },
    // Per-parent eager load: newest 2 comments per post (edge order/limit).
    .edges = &.{edge.To("comments", Comment).Field("post_id").OrderBy("id").Desc().Limit(2)},
});

pub const Author = Schema("Author", .{
    .fields = &.{field.String("name")},
    .edges = &.{edge.To("posts", Post)},
});

/// Commerce demo: per-product stock with an optimistic-lock version column,
/// decremented atomically via `setExprArgs` (oversell-safe).
pub const Inventory = Schema("Inventory", .{
    .fields = &.{
        field.Int("product_id"),
        field.Int("stock"),
        field.Version("version"),
    },
});
