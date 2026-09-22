-- Run once in the Cloudflare D1 console, or with `wrangler d1 execute`.
-- A licence is provisioned by the owner before its user registers.
CREATE TABLE IF NOT EXISTS licenses (
  email TEXT PRIMARY KEY COLLATE NOCASE,
  status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'revoked')),
  max_devices INTEGER NOT NULL DEFAULT 2 CHECK(max_devices BETWEEN 1 AND 10),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS users (
  email TEXT PRIMARY KEY COLLATE NOCASE,
  password_salt TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS devices (
  device_id TEXT PRIMARY KEY,
  email TEXT NOT NULL COLLATE NOCASE,
  device_name TEXT NOT NULL,
  revoked INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY(email) REFERENCES users(email)
);

CREATE INDEX IF NOT EXISTS devices_by_user ON devices(email, revoked);

-- One-time activation codes. Only SHA-256 hashes are ever stored here; the
-- human-readable codes are issued separately and must not be added to source.
CREATE TABLE IF NOT EXISTS activation_codes (
  code_hash TEXT PRIMARY KEY,
  intended_email TEXT NOT NULL COLLATE NOCASE,
  revoked INTEGER NOT NULL DEFAULT 0,
  used_at TEXT,
  activated_email TEXT COLLATE NOCASE,
  activated_device_id TEXT,
  expires_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS activations (
  device_id TEXT PRIMARY KEY,
  code_hash TEXT NOT NULL UNIQUE,
  email TEXT NOT NULL COLLATE NOCASE,
  device_name TEXT NOT NULL,
  revoked INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY(code_hash) REFERENCES activation_codes(code_hash)
);

CREATE INDEX IF NOT EXISTS activations_by_email ON activations(email, revoked);

CREATE TABLE IF NOT EXISTS licence_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT COLLATE NOCASE,
  device_id TEXT,
  event TEXT NOT NULL,
  outcome TEXT NOT NULL,
  detail TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS licence_events_by_time ON licence_events(created_at DESC);
CREATE INDEX IF NOT EXISTS licence_events_by_device ON licence_events(device_id, created_at DESC);

-- Example: issue a licence before a customer creates their account.
-- INSERT INTO licenses (email, max_devices) VALUES ('customer@example.com', 2);
