ALTER TABLE collector_health
    ADD COLUMN IF NOT EXISTS last_payload_ts TIMESTAMPTZ;
