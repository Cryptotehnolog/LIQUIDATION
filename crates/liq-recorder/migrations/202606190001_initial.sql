CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE IF NOT EXISTS raw_source_events (
    id BIGSERIAL PRIMARY KEY,
    source TEXT NOT NULL,
    source_event_id TEXT NOT NULL,
    source_quality TEXT NOT NULL,
    symbol TEXT NOT NULL,
    exchange_ts TIMESTAMPTZ NOT NULL,
    received_ts TIMESTAMPTZ NOT NULL,
    payload JSONB NOT NULL,
    payload_sha256 TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (source, source_event_id)
);

SELECT create_hypertable('raw_source_events', 'received_ts', if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS liquidation_events (
    event_id UUID PRIMARY KEY,
    source TEXT NOT NULL,
    source_event_id TEXT NOT NULL,
    source_quality TEXT NOT NULL,
    symbol TEXT NOT NULL,
    side TEXT NOT NULL,
    price NUMERIC NOT NULL,
    quantity NUMERIC NOT NULL,
    notional_usd NUMERIC NOT NULL,
    exchange_ts TIMESTAMPTZ NOT NULL,
    received_ts TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (source, source_event_id)
);

SELECT create_hypertable('liquidation_events', 'received_ts', if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS archive_manifests (
    id UUID PRIMARY KEY,
    parquet_schema_version INTEGER NOT NULL,
    source TEXT NOT NULL,
    time_range_start TIMESTAMPTZ NOT NULL,
    time_range_end TIMESTAMPTZ NOT NULL,
    row_count BIGINT NOT NULL,
    payload_bytes BIGINT NOT NULL,
    file_checksum_sha256 TEXT NOT NULL,
    verification_status TEXT NOT NULL,
    retry_count INTEGER NOT NULL DEFAULT 0,
    corrupted_files JSONB NOT NULL DEFAULT '[]'::jsonb,
    canonical_deletion_watermark TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    verified_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS collector_health (
    id BIGSERIAL PRIMARY KEY,
    source TEXT NOT NULL,
    symbol TEXT NOT NULL,
    status TEXT NOT NULL,
    reconnects_5m INTEGER NOT NULL DEFAULT 0,
    last_event_ts TIMESTAMPTZ,
    checked_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

SELECT create_hypertable('collector_health', 'checked_at', if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS replay_runs (
    id UUID PRIMARY KEY,
    input_hash TEXT NOT NULL UNIQUE,
    strategy_version TEXT NOT NULL,
    fill_model_version TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    status TEXT NOT NULL
);
