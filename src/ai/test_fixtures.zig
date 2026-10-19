//! Test-only fixtures shared by the AI ops modules.
//!
//! Production code never imports this file. The outbox table is recreated by
//! each test that exercises an outbox-emitting flow; the definition lives here
//! so a schema change is one edit, not twenty-seven.

pub const outbox_table_sql = "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)";
