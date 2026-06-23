CREATE TABLE IF NOT EXISTS market_quotes (
    event_id UUID NOT NULL,
    venue TEXT NOT NULL,
    source_event_id TEXT NOT NULL,
    instrument_id TEXT NOT NULL,
    symbol TEXT NOT NULL,
    best_bid NUMERIC,
    best_bid_size NUMERIC,
    best_ask NUMERIC,
    best_ask_size NUMERIC,
    exchange_ts TIMESTAMPTZ NOT NULL,
    received_ts TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, received_ts)
);

SELECT create_hypertable('market_quotes', 'received_ts', if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS market_quote_keys (
    venue TEXT NOT NULL,
    source_event_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (venue, source_event_id)
);

CREATE TABLE IF NOT EXISTS market_trades (
    event_id UUID NOT NULL,
    venue TEXT NOT NULL,
    source_event_id TEXT NOT NULL,
    instrument_id TEXT NOT NULL,
    symbol TEXT NOT NULL,
    side TEXT NOT NULL,
    price NUMERIC NOT NULL,
    quantity NUMERIC NOT NULL,
    notional_usd NUMERIC,
    exchange_ts TIMESTAMPTZ NOT NULL,
    received_ts TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, received_ts)
);

SELECT create_hypertable('market_trades', 'received_ts', if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS market_trade_keys (
    venue TEXT NOT NULL,
    source_event_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (venue, source_event_id)
);
