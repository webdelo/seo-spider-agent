-- Run once in the Cloudflare D1 console before publishing worker-module.js.
-- It binds newly issued activation codes to one permitted email and creates an
-- auditable event trail. Existing completed activations remain valid.

ALTER TABLE activation_codes ADD COLUMN intended_email TEXT COLLATE NOCASE;

-- Preserve the audit meaning of codes already used. Old unused generic codes
-- are deliberately revoked: issue fresh, email-bound codes instead.
UPDATE activation_codes
SET intended_email = activated_email
WHERE used_at IS NOT NULL AND intended_email IS NULL;

UPDATE activation_codes
SET revoked = 1
WHERE used_at IS NULL AND intended_email IS NULL;

CREATE INDEX IF NOT EXISTS activation_codes_by_email
ON activation_codes(intended_email, revoked, used_at);

CREATE TABLE IF NOT EXISTS licence_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT COLLATE NOCASE,
  device_id TEXT,
  event TEXT NOT NULL,
  outcome TEXT NOT NULL,
  detail TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS licence_events_by_time
ON licence_events(created_at DESC);

CREATE INDEX IF NOT EXISTS licence_events_by_device
ON licence_events(device_id, created_at DESC);
