CREATE TABLE IF NOT EXISTS polymarket_markets (
    market_id TEXT PRIMARY KEY,
    slug TEXT,
    title TEXT,
    base_asset TEXT NOT NULL,
    market_type TEXT NOT NULL,
    up_token_id TEXT NOT NULL,
    down_token_id TEXT NOT NULL,
    start_ts TIMESTAMPTZ NOT NULL,
    end_ts TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL,
    source TEXT NOT NULL,
    raw_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (market_id <> ''),
    CHECK (base_asset <> ''),
    CHECK (market_type <> ''),
    CHECK (up_token_id <> ''),
    CHECK (down_token_id <> ''),
    CHECK (up_token_id <> down_token_id),
    CHECK (end_ts > start_ts)
);

CREATE INDEX IF NOT EXISTS polymarket_markets_latest_idx
    ON polymarket_markets (base_asset, market_type, start_ts DESC, end_ts DESC);
