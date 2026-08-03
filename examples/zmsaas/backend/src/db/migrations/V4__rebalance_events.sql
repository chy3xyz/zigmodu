CREATE TABLE IF NOT EXISTS rebalance_events (
  idempotency_key TEXT PRIMARY KEY,
  org_id INTEGER NOT NULL,
  from_shard INTEGER NOT NULL,
  to_shard INTEGER NOT NULL,
  migrated INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
