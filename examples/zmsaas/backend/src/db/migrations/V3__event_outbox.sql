CREATE TABLE IF NOT EXISTS event_outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  topic TEXT NOT NULL,
  payload TEXT NOT NULL,
  status INTEGER NOT NULL DEFAULT 0,
  retry_count INTEGER NOT NULL DEFAULT 0,
  max_retries INTEGER NOT NULL DEFAULT 5,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  error_message TEXT
);
CREATE INDEX IF NOT EXISTS idx_outbox_status_created ON event_outbox (status, created_at);
