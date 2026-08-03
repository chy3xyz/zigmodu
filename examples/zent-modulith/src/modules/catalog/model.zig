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
        // Validators run automatically on create/update (v0.25).
        field.String("name").NotEmpty().Length(1, 100),
        field.Int("price_cents"),
        // Large optional field: list endpoints can project it away.
        field.String("description").Optional(),
    },
    // AuditMixin auto-fills created_by/updated_by from the client's
    // PrivacyContext.user_id (v0.25).
    .mixins = &.{zent.core.mixin.AuditMixin},
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
        // Edge-filter demo (v0.23): hidden comments are never eager-loaded.
        field.Bool("hidden"),
        // v0.22 audit timestamps: dialect-aware epoch DEFAULT; explicit
        // values are honored (used by the keyset-cursor demo below).
        field.Time("created_at"),
    },
});

pub const Post = Schema("Post", .{
    .fields = &.{
        field.Int("author_id"),
        field.String("title"),
    },
    // Per-parent eager load: newest 2 *visible* comments per post — the
    // WhereRaw filter (v0.23) applies before order/limit, so limits rank
    // filtered rows only.
    .edges = &.{edge.To("comments", Comment)
        .Field("post_id")
        .WhereRaw("\"hidden\" = ?", &.{.{ .bool = false }})
        .OrderBy("id")
        .Desc()
        .Limit(2)},
    // Soft delete + restore demo (v0.26).
    .mixins = &.{zent.core.mixin.SoftDeleteMixin},
    .soft_delete = true,
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

/// Transaction-orchestration demo (v0.24): order placement runs an outer
/// transaction, an inner savepoint (re-entrant beginTx) for the stock
/// decrement, and collects events delivered after commit.
pub const Order = Schema("Order", .{
    .fields = &.{
        field.Int("tenant_id"),
        field.Int("product_id"),
        field.Int("qty"),
        field.Int("total_cents"),
        field.String("status"),
        field.Time("created_at"),
    },
});

/// Distributed-id + sensitive-masking demo (v0.24): uuid primary key
/// (time-ordered uuidv7) and a Sensitive api_key that must never be
/// serialized raw — APIs use `toMaskedJson`.
pub const Account = Schema("Account", .{
    .fields = &.{
        field.UUID("id"),
        field.String("name"),
        field.String("api_key").Sensitive(),
    },
});
