# Data Foundation Increment 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first working Rust foundation for collecting, normalizing, storing, and dry-running liquidation data without real orders.

**Architecture:** Create a Rust workspace with small crates: `liq-domain` for types, `liq-config` for validated configuration, `liq-connectors` for source adapters and normalizers, `liq-recorder` for SQL migrations and persistence boundaries, `liq-replay` for dry-run checks, and `liq-cli` as the operator entrypoint. The first increment records Bybit as the strategy-grade source and Binance as diagnostic snapshot-only data, with Polymarket and Hyperliquid modeled only as configuration and replay prerequisites.

**Tech Stack:** Rust 2024, Tokio, tokio-tungstenite, serde, thiserror, anyhow, rust_decimal, time, uuid, sqlx with Postgres, TimescaleDB migrations, clap, tracing, cargo-nextest optional after base tests pass.

---

## Scope Boundary

This plan implements the foundation increment only. It does not place real Polymarket orders, real Hyperliquid hedges, Dockerized LightRAG, dashboard UI, OKX adapter, or archive export. Those stay separate implementation plans.

Research decisions included in this plan:

- Bybit is the primary strategy liquidation source.
- Binance is diagnostic snapshot-only.
- OKX REST liquidation backfill is disabled.
- Polymarket fees and Hyperliquid fees/funding are required before decision-grade PnL.
- RAG is control-plane only and not required for collector execution.

## File Structure

Create:

- `.gitignore` - Rust, local env, generated reports, and secret-safe ignores.
- `.env.example` - non-secret example variable names only.
- `Cargo.toml` - workspace root and shared dependencies.
- `rust-toolchain.toml` - stable toolchain pin.
- `rustfmt.toml` - formatting policy.
- `config/default.toml` - default non-secret config.
- `crates/liq-domain/Cargo.toml` - domain crate manifest.
- `crates/liq-domain/src/lib.rs` - strongly typed domain exports.
- `crates/liq-domain/src/liquidation.rs` - canonical liquidation event types.
- `crates/liq-domain/src/source.rs` - source identity and quality enums.
- `crates/liq-config/Cargo.toml` - config crate manifest.
- `crates/liq-config/src/lib.rs` - config load and validation.
- `crates/liq-connectors/Cargo.toml` - connector crate manifest.
- `crates/liq-connectors/src/lib.rs` - connector exports.
- `crates/liq-connectors/src/binance.rs` - Binance forceOrder normalizer.
- `crates/liq-connectors/src/bybit.rs` - Bybit allLiquidation normalizer.
- `crates/liq-connectors/tests/fixtures/binance_force_order.json` - Binance fixture.
- `crates/liq-connectors/tests/fixtures/bybit_all_liquidation.json` - Bybit fixture.
- `crates/liq-connectors/tests/normalization.rs` - fixture-based normalizer tests.
- `crates/liq-recorder/Cargo.toml` - recorder crate manifest.
- `crates/liq-recorder/src/lib.rs` - recorder boundary exports.
- `crates/liq-recorder/src/migrations.rs` - embedded migration runner.
- `crates/liq-recorder/migrations/202606190001_initial.sql` - initial schema.
- `crates/liq-replay/Cargo.toml` - replay crate manifest.
- `crates/liq-replay/src/lib.rs` - replay dry-run validation.
- `crates/liq-cli/Cargo.toml` - CLI crate manifest.
- `crates/liq-cli/src/main.rs` - operator commands.
- `.github/workflows/ci.yml` - GitHub Actions checks.
- `docs/runbooks/local-development.md` - local commands.

Modify:

- `docs/research/status.json` - keep research metadata current if research-dependent decisions change.

## Task 1: Workspace Scaffold

**Files:**

- Modify: `.gitignore`
- Create: `.env.example`
- Create: `Cargo.toml`
- Create: `rust-toolchain.toml`
- Create: `rustfmt.toml`
- Create: `config/default.toml`

- [ ] **Step 1: Create or update the workspace files**

Update `.gitignore` and keep existing RAG/Docker secret ignores:

```gitignore
/infra/lightrag/.env
/infra/lightrag/data/
/target/
/.env
/.env.local
/.sqlx/
/docs/reports/rag/*.tmp
/docs/reports/rag/*.log
*.pdb
*.profraw
*.profdata
```

Create `.env.example`:

```dotenv
LIQ_CONFIG_PATH=config/default.toml
DATABASE_URL=postgres://liquidation:liquidation@127.0.0.1:15433/liquidation
RUST_LOG=info,liq=debug
LIGHTRAG_DATA_PATH=
LIGHTRAG_BACKUP_PATH=
LIGHTRAG_REPORT_PATH=docs/reports/rag
LIGHTRAG_INDEXED_PATHS=docs/
LIQUIDATION_OMNIROUTE_BASE_URL=
LIQUIDATION_FREE_DEEPSEEK_BASE_URL=
```

Create `rust-toolchain.toml`:

```toml
[toolchain]
channel = "stable"
components = ["rustfmt", "clippy"]
```

Create `rustfmt.toml`:

```toml
edition = "2024"
max_width = 100
newline_style = "Windows"
```

Create root `Cargo.toml`:

```toml
[workspace]
resolver = "3"
members = []

[workspace.package]
edition = "2024"
rust-version = "1.85"
license = "MIT"
repository = "https://github.com/Cryptotehnolog/LIQUIDATION"

[workspace.dependencies]
anyhow = "1"
async-trait = "0.1"
clap = { version = "4", features = ["derive", "env"] }
rust_decimal = { version = "1", features = ["serde-with-str"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sqlx = { version = "0.8", features = ["runtime-tokio", "postgres", "migrate", "time", "uuid", "rust_decimal", "json"] }
thiserror = "2"
time = { version = "0.3", features = ["formatting", "macros", "parsing", "serde"] }
tokio = { version = "1", features = ["macros", "rt-multi-thread", "signal", "time"] }
tokio-tungstenite = { version = "0.26", features = ["rustls-tls-webpki-roots"] }
toml = "0.8"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "fmt", "json"] }
uuid = { version = "1", features = ["serde", "v5"] }

[workspace.lints.rust]
unsafe_code = "warn"
missing_docs = "warn"

[workspace.lints.clippy]
correctness = "deny"
suspicious = "warn"
complexity = "warn"
perf = "warn"
style = "warn"
pedantic = "warn"
```

Create `config/default.toml`:

```toml
[database]
url_env = "DATABASE_URL"
connect_timeout_seconds = 10

[sources.bybit]
enabled = true
quality = "all_events"
symbols = ["BTCUSDT"]
max_reconnects_per_5min = 5

[sources.binance]
enabled = true
quality = "snapshot_only"
symbols = ["btcusdt"]
max_reconnects_per_5min = 5

[backfill]
binance_enabled = false
bybit_enabled = false
okx_rest_enabled = false

[replay]
default_primary_source = "bybit"
default_aggregation_policy = "primary_only"
fill_model = "trade_cross"
order_cancel_window_seconds = 60
hedge_timeout_seconds = 10

[retention]
hot_raw_retention_days = 14
canonical_events_retention_days = 30
collector_health_retention_days = 7
```

- [ ] **Step 2: Run workspace metadata check**

Run:

```powershell
cargo metadata --format-version 1
```

Expected: command succeeds with an empty workspace member list. Later tasks add crates to `members` before each crate is tested.

- [ ] **Step 3: Commit scaffold**

Run:

```powershell
git add .gitignore .env.example Cargo.toml rust-toolchain.toml rustfmt.toml config/default.toml
git commit -m "chore: scaffold rust workspace config"
```

## Task 2: Domain Crate

**Files:**

- Create: `crates/liq-domain/Cargo.toml`
- Create: `crates/liq-domain/src/lib.rs`
- Create: `crates/liq-domain/src/source.rs`
- Create: `crates/liq-domain/src/liquidation.rs`
- Modify: `Cargo.toml`

- [ ] **Step 1: Write domain crate manifest**

Modify root `Cargo.toml`:

```toml
[workspace]
resolver = "3"
members = [
  "crates/liq-domain",
]
```

Keep the existing `[workspace.package]`, `[workspace.dependencies]`, `[workspace.lints.rust]`, and `[workspace.lints.clippy]` sections unchanged.

Create `crates/liq-domain/Cargo.toml`:

```toml
[package]
name = "liq-domain"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true
license.workspace = true
repository.workspace = true

[dependencies]
rust_decimal.workspace = true
serde.workspace = true
thiserror.workspace = true
time.workspace = true
uuid.workspace = true

[lints]
workspace = true
```

- [ ] **Step 2: Write source quality types**

Create `crates/liq-domain/src/source.rs`:

```rust
//! Source identity and quality metadata.

use serde::{Deserialize, Serialize};

/// Supported market-data sources.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    /// Bybit derivatives.
    Bybit,
    /// Binance USD-M futures.
    Binance,
}

/// Quality semantics for a source stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceQuality {
    /// Source claims all liquidation events for the subscribed symbol.
    AllEvents,
    /// Source emits a snapshot or latest/largest event per time window.
    SnapshotOnly,
    /// Source is derived from another source and must not fill gaps silently.
    Derived,
}

impl Source {
    /// Stable lowercase identifier for storage and logs.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Bybit => "bybit",
            Self::Binance => "binance",
        }
    }
}
```

- [ ] **Step 3: Write liquidation domain types**

Create `crates/liq-domain/src/liquidation.rs`:

```rust
//! Canonical liquidation event model.

use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::source::{Source, SourceQuality};

/// Liquidated side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LiquidationSide {
    /// Long position was liquidated.
    Long,
    /// Short position was liquidated.
    Short,
}

/// Canonical normalized liquidation event.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LiquidationEvent {
    /// Deterministic event id generated from source and source event identity.
    pub event_id: Uuid,
    /// Source venue.
    pub source: Source,
    /// Source-specific event id or deterministic payload hash.
    pub source_event_id: String,
    /// Source quality semantics.
    pub source_quality: SourceQuality,
    /// Exchange symbol as received or canonicalized by adapter.
    pub symbol: String,
    /// Liquidated side.
    pub side: LiquidationSide,
    /// Liquidation price.
    pub price: Decimal,
    /// Liquidated quantity in base units when available.
    pub quantity: Decimal,
    /// USD notional. Required for strategy aggregation.
    pub notional_usd: Decimal,
    /// Exchange event timestamp.
    pub exchange_ts: OffsetDateTime,
    /// Local receive timestamp.
    pub received_ts: OffsetDateTime,
}

impl LiquidationEvent {
    /// Returns receive latency in milliseconds.
    #[must_use]
    pub fn latency_ms(&self) -> i128 {
        (self.received_ts - self.exchange_ts).whole_milliseconds()
    }
}
```

- [ ] **Step 4: Write domain exports**

Create `crates/liq-domain/src/lib.rs`:

```rust
//! Shared domain types for LIQUIDATION.

pub mod liquidation;
pub mod source;

pub use liquidation::{LiquidationEvent, LiquidationSide};
pub use source::{Source, SourceQuality};
```

- [ ] **Step 5: Run domain tests**

Run:

```powershell
cargo test -p liq-domain
```

Expected: pass with zero tests compiled successfully.

- [ ] **Step 6: Commit domain crate**

Run:

```powershell
git add crates/liq-domain
git commit -m "feat: add liquidation domain types"
```

## Task 3: Config Validation Crate

**Files:**

- Create: `crates/liq-config/Cargo.toml`
- Create: `crates/liq-config/src/lib.rs`
- Modify: `Cargo.toml`

- [ ] **Step 1: Register crate and write failing config tests**

Modify root `Cargo.toml` workspace members:

```toml
members = [
  "crates/liq-config",
  "crates/liq-domain",
]
```

Create `crates/liq-config/src/lib.rs` with tests first:

```rust
//! Configuration loading and validation.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_zero_retention() {
        let cfg = AppConfig {
            retention: RetentionConfig {
                hot_raw_retention_days: 0,
                canonical_events_retention_days: 30,
                collector_health_retention_days: 7,
            },
            ..AppConfig::test_default()
        };

        let err = cfg.validate().expect_err("zero retention must fail");
        assert!(err.to_string().contains("hot_raw_retention_days"));
    }

    #[test]
    fn rejects_okx_rest_backfill() {
        let cfg = AppConfig {
            backfill: BackfillConfig {
                binance_enabled: false,
                bybit_enabled: false,
                okx_rest_enabled: true,
            },
            ..AppConfig::test_default()
        };

        let err = cfg.validate().expect_err("OKX REST backfill must fail");
        assert!(err.to_string().contains("OKX REST liquidation backfill"));
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
cargo test -p liq-config
```

Expected: FAIL because `AppConfig`, `RetentionConfig`, and `BackfillConfig` are not defined.

- [ ] **Step 3: Add config manifest**

Create `crates/liq-config/Cargo.toml`:

```toml
[package]
name = "liq-config"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true
license.workspace = true
repository.workspace = true

[dependencies]
serde.workspace = true
thiserror.workspace = true
toml.workspace = true

[lints]
workspace = true
```

- [ ] **Step 4: Implement config types and validation**

Replace `crates/liq-config/src/lib.rs` with:

```rust
//! Configuration loading and validation.

use serde::Deserialize;
use thiserror::Error;

/// Application configuration.
#[derive(Debug, Clone, Deserialize)]
pub struct AppConfig {
    /// Retention configuration.
    pub retention: RetentionConfig,
    /// Backfill configuration.
    pub backfill: BackfillConfig,
}

/// Retention configuration in days.
#[derive(Debug, Clone, Deserialize)]
pub struct RetentionConfig {
    /// Hot raw payload retention.
    pub hot_raw_retention_days: u16,
    /// Canonical event retention.
    pub canonical_events_retention_days: u16,
    /// Collector health retention.
    pub collector_health_retention_days: u16,
}

/// Backfill feature switches.
#[derive(Debug, Clone, Deserialize)]
pub struct BackfillConfig {
    /// Binance market liquidation backfill.
    pub binance_enabled: bool,
    /// Bybit REST liquidation backfill.
    pub bybit_enabled: bool,
    /// OKX REST liquidation backfill.
    pub okx_rest_enabled: bool,
}

/// Configuration validation error.
#[derive(Debug, Error)]
pub enum ConfigError {
    /// A numeric field is outside the accepted range.
    #[error("{field} must be between {min} and {max}, got {actual}")]
    Range {
        /// Field name.
        field: &'static str,
        /// Minimum accepted value.
        min: u16,
        /// Maximum accepted value.
        max: u16,
        /// Actual value.
        actual: u16,
    },
    /// Disabled feature was requested.
    #[error("{feature} is disabled by research decision: {reason}")]
    DisabledByResearch {
        /// Feature name.
        feature: &'static str,
        /// Reason.
        reason: &'static str,
    },
}

impl AppConfig {
    /// Validate configuration.
    ///
    /// # Errors
    ///
    /// Returns an error when retention windows are invalid or a research-disabled
    /// capability is enabled.
    pub fn validate(&self) -> Result<(), ConfigError> {
        validate_days("hot_raw_retention_days", self.retention.hot_raw_retention_days, 1, 90)?;
        validate_days(
            "canonical_events_retention_days",
            self.retention.canonical_events_retention_days,
            1,
            365,
        )?;
        validate_days(
            "collector_health_retention_days",
            self.retention.collector_health_retention_days,
            1,
            90,
        )?;

        if self.backfill.okx_rest_enabled {
            return Err(ConfigError::DisabledByResearch {
                feature: "OKX REST liquidation backfill",
                reason: "official OKX changelog says the endpoint was delisted",
            });
        }

        Ok(())
    }

    #[cfg(test)]
    fn test_default() -> Self {
        Self {
            retention: RetentionConfig {
                hot_raw_retention_days: 14,
                canonical_events_retention_days: 30,
                collector_health_retention_days: 7,
            },
            backfill: BackfillConfig {
                binance_enabled: false,
                bybit_enabled: false,
                okx_rest_enabled: false,
            },
        }
    }
}

fn validate_days(
    field: &'static str,
    actual: u16,
    min: u16,
    max: u16,
) -> Result<(), ConfigError> {
    if (min..=max).contains(&actual) {
        Ok(())
    } else {
        Err(ConfigError::Range {
            field,
            min,
            max,
            actual,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_zero_retention() {
        let cfg = AppConfig {
            retention: RetentionConfig {
                hot_raw_retention_days: 0,
                canonical_events_retention_days: 30,
                collector_health_retention_days: 7,
            },
            ..AppConfig::test_default()
        };

        let err = cfg.validate().expect_err("zero retention must fail");
        assert!(err.to_string().contains("hot_raw_retention_days"));
    }

    #[test]
    fn rejects_okx_rest_backfill() {
        let cfg = AppConfig {
            backfill: BackfillConfig {
                binance_enabled: false,
                bybit_enabled: false,
                okx_rest_enabled: true,
            },
            ..AppConfig::test_default()
        };

        let err = cfg.validate().expect_err("OKX REST backfill must fail");
        assert!(err.to_string().contains("OKX REST liquidation backfill"));
    }
}
```

- [ ] **Step 5: Run config tests**

Run:

```powershell
cargo test -p liq-config
```

Expected: PASS.

- [ ] **Step 6: Commit config crate**

Run:

```powershell
git add crates/liq-config
git commit -m "feat: add validated configuration"
```

## Task 4: Connector Normalizers

**Files:**

- Create: `crates/liq-connectors/Cargo.toml`
- Create: `crates/liq-connectors/src/lib.rs`
- Create: `crates/liq-connectors/src/binance.rs`
- Create: `crates/liq-connectors/src/bybit.rs`
- Create: `crates/liq-connectors/tests/fixtures/binance_force_order.json`
- Create: `crates/liq-connectors/tests/fixtures/bybit_all_liquidation.json`
- Create: `crates/liq-connectors/tests/normalization.rs`
- Modify: `Cargo.toml`

- [ ] **Step 1: Register crate and add connector fixtures**

Modify root `Cargo.toml` workspace members:

```toml
members = [
  "crates/liq-config",
  "crates/liq-connectors",
  "crates/liq-domain",
]
```

Create `crates/liq-connectors/tests/fixtures/binance_force_order.json`:

```json
{
  "e": "forceOrder",
  "E": 1718750000000,
  "o": {
    "s": "BTCUSDT",
    "S": "SELL",
    "p": "65000.00",
    "q": "0.100"
  }
}
```

Create `crates/liq-connectors/tests/fixtures/bybit_all_liquidation.json`:

```json
{
  "topic": "allLiquidation.BTCUSDT",
  "ts": 1718750000500,
  "data": [
    {
      "T": 1718750000000,
      "s": "BTCUSDT",
      "S": "Sell",
      "v": "0.100",
      "p": "65000.00"
    }
  ]
}
```

- [ ] **Step 2: Write failing normalizer tests**

Create `crates/liq-connectors/tests/normalization.rs`:

```rust
use liq_connectors::{binance, bybit};
use liq_domain::{LiquidationSide, Source, SourceQuality};
use time::OffsetDateTime;

#[test]
fn bybit_normalizes_all_liquidation_event() {
    let payload = include_str!("fixtures/bybit_all_liquidation.json");
    let received_ts = OffsetDateTime::from_unix_timestamp(1_718_750_001).unwrap();

    let events = bybit::normalize_all_liquidation(payload, received_ts).unwrap();

    assert_eq!(events.len(), 1);
    assert_eq!(events[0].source, Source::Bybit);
    assert_eq!(events[0].source_quality, SourceQuality::AllEvents);
    assert_eq!(events[0].side, LiquidationSide::Long);
    assert_eq!(events[0].notional_usd.to_string(), "6500.00000");
}

#[test]
fn binance_normalizes_snapshot_force_order_as_diagnostic() {
    let payload = include_str!("fixtures/binance_force_order.json");
    let received_ts = OffsetDateTime::from_unix_timestamp(1_718_750_001).unwrap();

    let event = binance::normalize_force_order(payload, received_ts).unwrap();

    assert_eq!(event.source, Source::Binance);
    assert_eq!(event.source_quality, SourceQuality::SnapshotOnly);
    assert_eq!(event.side, LiquidationSide::Long);
    assert_eq!(event.notional_usd.to_string(), "6500.00000");
}
```

- [ ] **Step 3: Run tests to verify failure**

Run:

```powershell
cargo test -p liq-connectors --test normalization
```

Expected: FAIL because `liq-connectors` does not exist.

- [ ] **Step 4: Add connector manifest and exports**

Create `crates/liq-connectors/Cargo.toml`:

```toml
[package]
name = "liq-connectors"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true
license.workspace = true
repository.workspace = true

[dependencies]
liq-domain = { path = "../liq-domain" }
rust_decimal.workspace = true
serde.workspace = true
serde_json.workspace = true
thiserror.workspace = true
time.workspace = true
uuid.workspace = true

[lints]
workspace = true
```

Create `crates/liq-connectors/src/lib.rs`:

```rust
//! Source adapters and normalizers.

pub mod binance;
pub mod bybit;

use thiserror::Error;

/// Connector normalization error.
#[derive(Debug, Error)]
pub enum ConnectorError {
    /// JSON payload could not be parsed.
    #[error("invalid json payload")]
    Json(#[from] serde_json::Error),
    /// Decimal value could not be parsed.
    #[error("invalid decimal field {field}: {value}")]
    Decimal {
        /// Field name.
        field: &'static str,
        /// Invalid value.
        value: String,
    },
    /// Required field is missing.
    #[error("missing field {0}")]
    Missing(&'static str),
    /// Timestamp is invalid.
    #[error("invalid timestamp {0}")]
    Timestamp(i64),
}
```

- [ ] **Step 5: Implement Binance normalizer**

Create `crates/liq-connectors/src/binance.rs`:

```rust
//! Binance forceOrder normalizer.

use liq_domain::{LiquidationEvent, LiquidationSide, Source, SourceQuality};
use rust_decimal::Decimal;
use serde::Deserialize;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::ConnectorError;

#[derive(Debug, Deserialize)]
struct BinancePayload {
    #[serde(rename = "E")]
    event_time_ms: i64,
    #[serde(rename = "o")]
    order: BinanceOrder,
}

#[derive(Debug, Deserialize)]
struct BinanceOrder {
    #[serde(rename = "s")]
    symbol: String,
    #[serde(rename = "S")]
    side: String,
    #[serde(rename = "p")]
    price: String,
    #[serde(rename = "q")]
    quantity: String,
}

/// Normalize a Binance forceOrder snapshot.
///
/// # Errors
///
/// Returns an error when JSON, decimal, or timestamp fields are invalid.
pub fn normalize_force_order(
    payload: &str,
    received_ts: OffsetDateTime,
) -> Result<LiquidationEvent, ConnectorError> {
    let parsed: BinancePayload = serde_json::from_str(payload)?;
    let price = parse_decimal("price", &parsed.order.price)?;
    let quantity = parse_decimal("quantity", &parsed.order.quantity)?;
    let exchange_ts = OffsetDateTime::from_unix_timestamp(parsed.event_time_ms / 1000)
        .map_err(|_| ConnectorError::Timestamp(parsed.event_time_ms))?;

    let side = match parsed.order.side.as_str() {
        "SELL" => LiquidationSide::Long,
        "BUY" => LiquidationSide::Short,
        _ => return Err(ConnectorError::Missing("o.S")),
    };

    let source_event_id = format!(
        "binance:{}:{}:{}:{}",
        parsed.order.symbol, parsed.event_time_ms, parsed.order.side, parsed.order.quantity
    );

    Ok(LiquidationEvent {
        event_id: deterministic_event_id(&source_event_id),
        source: Source::Binance,
        source_event_id,
        source_quality: SourceQuality::SnapshotOnly,
        symbol: parsed.order.symbol,
        side,
        price,
        quantity,
        notional_usd: price * quantity,
        exchange_ts,
        received_ts,
    })
}

fn deterministic_event_id(source_event_id: &str) -> Uuid {
    Uuid::new_v5(&Uuid::NAMESPACE_URL, source_event_id.as_bytes())
}

fn parse_decimal(field: &'static str, value: &str) -> Result<Decimal, ConnectorError> {
    value.parse::<Decimal>().map_err(|_| ConnectorError::Decimal {
        field,
        value: value.to_owned(),
    })
}
```

- [ ] **Step 6: Implement Bybit normalizer**

Create `crates/liq-connectors/src/bybit.rs`:

```rust
//! Bybit allLiquidation normalizer.

use liq_domain::{LiquidationEvent, LiquidationSide, Source, SourceQuality};
use rust_decimal::Decimal;
use serde::Deserialize;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::ConnectorError;

#[derive(Debug, Deserialize)]
struct BybitPayload {
    data: Vec<BybitLiquidation>,
}

#[derive(Debug, Deserialize)]
struct BybitLiquidation {
    #[serde(rename = "T")]
    event_time_ms: i64,
    #[serde(rename = "s")]
    symbol: String,
    #[serde(rename = "S")]
    side: String,
    #[serde(rename = "v")]
    quantity: String,
    #[serde(rename = "p")]
    price: String,
}

/// Normalize a Bybit allLiquidation message.
///
/// # Errors
///
/// Returns an error when JSON, decimal, or timestamp fields are invalid.
pub fn normalize_all_liquidation(
    payload: &str,
    received_ts: OffsetDateTime,
) -> Result<Vec<LiquidationEvent>, ConnectorError> {
    let parsed: BybitPayload = serde_json::from_str(payload)?;
    parsed
        .data
        .into_iter()
        .map(|item| normalize_item(item, received_ts))
        .collect()
}

fn normalize_item(
    item: BybitLiquidation,
    received_ts: OffsetDateTime,
) -> Result<LiquidationEvent, ConnectorError> {
    let price = parse_decimal("p", &item.price)?;
    let quantity = parse_decimal("v", &item.quantity)?;
    let exchange_ts = OffsetDateTime::from_unix_timestamp(item.event_time_ms / 1000)
        .map_err(|_| ConnectorError::Timestamp(item.event_time_ms))?;

    let side = match item.side.as_str() {
        "Sell" => LiquidationSide::Long,
        "Buy" => LiquidationSide::Short,
        _ => return Err(ConnectorError::Missing("S")),
    };

    let source_event_id = format!(
        "bybit:{}:{}:{}:{}",
        item.symbol, item.event_time_ms, item.side, item.quantity
    );

    Ok(LiquidationEvent {
        event_id: deterministic_event_id(&source_event_id),
        source: Source::Bybit,
        source_event_id,
        source_quality: SourceQuality::AllEvents,
        symbol: item.symbol,
        side,
        price,
        quantity,
        notional_usd: price * quantity,
        exchange_ts,
        received_ts,
    })
}

fn deterministic_event_id(source_event_id: &str) -> Uuid {
    Uuid::new_v5(&Uuid::NAMESPACE_URL, source_event_id.as_bytes())
}

fn parse_decimal(field: &'static str, value: &str) -> Result<Decimal, ConnectorError> {
    value.parse::<Decimal>().map_err(|_| ConnectorError::Decimal {
        field,
        value: value.to_owned(),
    })
}
```

- [ ] **Step 7: Run connector tests**

Run:

```powershell
cargo test -p liq-connectors --test normalization
```

Expected: PASS.

- [ ] **Step 8: Commit connector normalizers**

Run:

```powershell
git add crates/liq-connectors
git commit -m "feat: normalize bybit and binance liquidations"
```

## Task 5: Recorder Schema

**Files:**

- Create: `crates/liq-recorder/Cargo.toml`
- Create: `crates/liq-recorder/src/lib.rs`
- Create: `crates/liq-recorder/src/migrations.rs`
- Create: `crates/liq-recorder/migrations/202606190001_initial.sql`
- Modify: `Cargo.toml`

- [ ] **Step 1: Register crate and add recorder manifest**

Modify root `Cargo.toml` workspace members:

```toml
members = [
  "crates/liq-config",
  "crates/liq-connectors",
  "crates/liq-domain",
  "crates/liq-recorder",
]
```

Create `crates/liq-recorder/Cargo.toml`:

```toml
[package]
name = "liq-recorder"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true
license.workspace = true
repository.workspace = true

[dependencies]
anyhow.workspace = true
sqlx.workspace = true

[lints]
workspace = true
```

- [ ] **Step 2: Add initial migration**

Create `crates/liq-recorder/migrations/202606190001_initial.sql`:

```sql
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
```

- [ ] **Step 3: Add migration runner**

Create `crates/liq-recorder/src/migrations.rs`:

```rust
//! Database migration runner.

use sqlx::{PgPool, migrate::Migrator};

static MIGRATOR: Migrator = sqlx::migrate!("./migrations");

/// Run embedded migrations.
///
/// # Errors
///
/// Returns an error when a migration cannot be applied.
pub async fn run(pool: &PgPool) -> Result<(), sqlx::migrate::MigrateError> {
    MIGRATOR.run(pool).await
}
```

Create `crates/liq-recorder/src/lib.rs`:

```rust
//! Durable recording boundaries for raw and canonical data.

pub mod migrations;
```

- [ ] **Step 4: Run recorder build**

Run:

```powershell
cargo check -p liq-recorder
```

Expected: PASS.

- [ ] **Step 5: Commit recorder schema**

Run:

```powershell
git add crates/liq-recorder
git commit -m "feat: add recorder schema migrations"
```

## Task 6: Replay Dry-Run Crate

**Files:**

- Create: `crates/liq-replay/Cargo.toml`
- Create: `crates/liq-replay/src/lib.rs`
- Modify: `Cargo.toml`

- [ ] **Step 1: Register crate and write failing dry-run tests**

Modify root `Cargo.toml` workspace members:

```toml
members = [
  "crates/liq-config",
  "crates/liq-connectors",
  "crates/liq-domain",
  "crates/liq-recorder",
  "crates/liq-replay",
]
```

Create `crates/liq-replay/src/lib.rs`:

```rust
//! Replay dry-run validation.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dry_run_rejects_empty_source_set() {
        let request = DryRunRequest {
            sources: Vec::new(),
            start_unix_ms: 1,
            end_unix_ms: 2,
        };

        let err = validate_dry_run(&request).expect_err("empty sources must fail");
        assert!(err.to_string().contains("at least one source"));
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
cargo test -p liq-replay
```

Expected: FAIL because dry-run types are not implemented.

- [ ] **Step 3: Add replay manifest**

Create `crates/liq-replay/Cargo.toml`:

```toml
[package]
name = "liq-replay"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true
license.workspace = true
repository.workspace = true

[dependencies]
thiserror.workspace = true

[lints]
workspace = true
```

- [ ] **Step 4: Implement dry-run validation**

Replace `crates/liq-replay/src/lib.rs` with:

```rust
//! Replay dry-run validation.

use thiserror::Error;

/// Dry-run request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DryRunRequest {
    /// Source ids included in replay.
    pub sources: Vec<String>,
    /// Inclusive start timestamp in milliseconds.
    pub start_unix_ms: i64,
    /// Exclusive end timestamp in milliseconds.
    pub end_unix_ms: i64,
}

/// Dry-run validation error.
#[derive(Debug, Error)]
pub enum DryRunError {
    /// No source was selected.
    #[error("at least one source is required")]
    EmptySources,
    /// Time range is invalid.
    #[error("end_unix_ms must be greater than start_unix_ms")]
    InvalidTimeRange,
}

/// Validate replay inputs without executing strategy transitions.
///
/// # Errors
///
/// Returns an error when sources or time range are invalid.
pub fn validate_dry_run(request: &DryRunRequest) -> Result<(), DryRunError> {
    if request.sources.is_empty() {
        return Err(DryRunError::EmptySources);
    }

    if request.end_unix_ms <= request.start_unix_ms {
        return Err(DryRunError::InvalidTimeRange);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dry_run_rejects_empty_source_set() {
        let request = DryRunRequest {
            sources: Vec::new(),
            start_unix_ms: 1,
            end_unix_ms: 2,
        };

        let err = validate_dry_run(&request).expect_err("empty sources must fail");
        assert!(err.to_string().contains("at least one source"));
    }

    #[test]
    fn dry_run_rejects_invalid_time_range() {
        let request = DryRunRequest {
            sources: vec!["bybit".to_owned()],
            start_unix_ms: 2,
            end_unix_ms: 2,
        };

        let err = validate_dry_run(&request).expect_err("invalid time range must fail");
        assert!(err.to_string().contains("end_unix_ms"));
    }
}
```

- [ ] **Step 5: Run replay tests**

Run:

```powershell
cargo test -p liq-replay
```

Expected: PASS.

- [ ] **Step 6: Commit replay dry-run**

Run:

```powershell
git add crates/liq-replay
git commit -m "feat: add replay dry-run validation"
```

## Task 7: CLI Entrypoint

**Files:**

- Create: `crates/liq-cli/Cargo.toml`
- Create: `crates/liq-cli/src/main.rs`
- Modify: `Cargo.toml`

- [ ] **Step 1: Register crate and add CLI manifest**

Modify root `Cargo.toml` workspace members:

```toml
members = [
  "crates/liq-cli",
  "crates/liq-config",
  "crates/liq-connectors",
  "crates/liq-domain",
  "crates/liq-recorder",
  "crates/liq-replay",
]
```

Create `crates/liq-cli/Cargo.toml`:

```toml
[package]
name = "liq-cli"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true
license.workspace = true
repository.workspace = true

[dependencies]
anyhow.workspace = true
clap.workspace = true
liq-replay = { path = "../liq-replay" }
tracing.workspace = true
tracing-subscriber.workspace = true

[[bin]]
name = "liq"
path = "src/main.rs"

[lints]
workspace = true
```

- [ ] **Step 2: Implement CLI dry-run command**

Create `crates/liq-cli/src/main.rs`:

```rust
//! LIQUIDATION operator CLI.

use anyhow::Context;
use clap::{Parser, Subcommand};
use liq_replay::{DryRunRequest, validate_dry_run};
use tracing::info;

#[derive(Debug, Parser)]
#[command(name = "liq")]
#[command(about = "LIQUIDATION operator CLI")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Replay commands.
    Replay {
        #[command(subcommand)]
        command: ReplayCommand,
    },
}

#[derive(Debug, Subcommand)]
enum ReplayCommand {
    /// Validate replay inputs without executing strategy transitions.
    DryRun {
        /// Source id. Repeat for multiple sources.
        #[arg(long = "source")]
        source: Vec<String>,
        /// Inclusive start timestamp in milliseconds.
        #[arg(long)]
        start_unix_ms: i64,
        /// Exclusive end timestamp in milliseconds.
        #[arg(long)]
        end_unix_ms: i64,
    },
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("info").init();
    let cli = Cli::parse();

    match cli.command {
        Command::Replay {
            command:
                ReplayCommand::DryRun {
                    source,
                    start_unix_ms,
                    end_unix_ms,
                },
        } => {
            let request = DryRunRequest {
                sources: source,
                start_unix_ms,
                end_unix_ms,
            };
            validate_dry_run(&request).context("replay dry-run validation failed")?;
            info!("replay dry-run validation passed");
            println!("dry-run ok");
        }
    }

    Ok(())
}
```

- [ ] **Step 3: Run CLI validation failure**

Run:

```powershell
cargo run -p liq-cli -- replay dry-run --start-unix-ms 1 --end-unix-ms 2
```

Expected: non-zero exit with `at least one source is required`.

- [ ] **Step 4: Run CLI validation success**

Run:

```powershell
cargo run -p liq-cli -- replay dry-run --source bybit --start-unix-ms 1 --end-unix-ms 2
```

Expected: stdout contains `dry-run ok`.

- [ ] **Step 5: Commit CLI**

Run:

```powershell
git add crates/liq-cli
git commit -m "feat: add replay dry-run cli"
```

## Task 8: CI And Local Runbook

**Files:**

- Create: `.github/workflows/ci.yml`
- Create: `docs/runbooks/local-development.md`

- [ ] **Step 1: Add CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: ["main"]
  pull_request:

jobs:
  rust:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt, clippy
      - name: cargo fmt
        run: cargo fmt --all --check
      - name: cargo clippy
        run: cargo clippy --workspace --all-targets -- -D clippy::correctness -D clippy::suspicious -D clippy::perf -D clippy::complexity -D clippy::style
      - name: cargo test
        run: cargo test --workspace
```

- [ ] **Step 2: Add local development runbook**

Create `docs/runbooks/local-development.md`:

```markdown
# Local Development Runbook

## Цель

Локально проверять foundation-инкремент без real trading и без изменения Docker
контейнеров второго проекта.

## Проверки Rust

```powershell
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D clippy::correctness -D clippy::suspicious -D clippy::perf -D clippy::complexity -D clippy::style
cargo test --workspace
cargo run -p liq-cli -- replay dry-run --source bybit --start-unix-ms 1 --end-unix-ms 2
```

## Docker safety

Перед запуском инфраструктуры читать `docs/runbooks/docker-safety.md`.

Не выполнять:

```powershell
docker system prune
docker volume prune
docker compose down --remove-orphans
```

## Что улучшить или автоматизировать

- Добавить `cargo nextest`.
- Добавить `cargo audit`.
- Добавить `gitleaks`.
- Добавить weekly long-running load test после появления collector runtime.
```

- [ ] **Step 3: Run local checks**

Run:

```powershell
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D clippy::correctness -D clippy::suspicious -D clippy::perf -D clippy::complexity -D clippy::style
cargo test --workspace
```

Expected: all pass.

- [ ] **Step 4: Commit CI and runbook**

Run:

```powershell
git add .github/workflows/ci.yml docs/runbooks/local-development.md
git commit -m "ci: add rust foundation checks"
```

## Task 9: Final Verification

**Files:**

- Verify: entire workspace

- [ ] **Step 1: Run full verification**

Run:

```powershell
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D clippy::correctness -D clippy::suspicious -D clippy::perf -D clippy::complexity -D clippy::style
cargo test --workspace
cargo run -p liq-cli -- replay dry-run --source bybit --start-unix-ms 1 --end-unix-ms 2
```

Expected:

- formatting check passes;
- clippy exits without correctness, suspicious, perf, complexity, or style failures;
- all tests pass;
- CLI prints `dry-run ok`.

- [ ] **Step 2: Check forbidden placeholders**

Run:

```powershell
rg -n "TB[D]|TO[D]O|FIXM[E]|PLACEHOLDE[R]|should probabl[y]" .
```

Expected: no matches in source, config, docs, or CI files.

- [ ] **Step 3: Confirm Docker was not touched**

Run:

```powershell
docker ps --format "{{.Names}} {{.Status}} {{.Ports}}"
```

Expected: existing second-project containers are still running. No new container is required by this increment.

- [ ] **Step 4: Commit any verification-only documentation correction**

If verification reveals a command mismatch in `docs/runbooks/local-development.md`, fix the exact command and commit:

```powershell
git add docs/runbooks/local-development.md
git commit -m "docs: correct local development commands"
```

## Self-Review

Spec coverage:

- Rust workspace: Task 1.
- Type-safe domain model: Task 2.
- Config validation and OKX REST backfill rejection: Task 3.
- Bybit/Binance normalization with fixtures: Task 4.
- Recorder schema for raw, canonical, health, replay runs: Task 5.
- Replay dry-run validation: Task 6.
- Operator CLI: Task 7.
- CI and local runbook: Task 8.
- Final checks: Task 9.

Known gaps intentionally excluded from this increment:

- Live WebSocket runtime loops.
- Actual TimescaleDB container.
- Real persistence insert methods.
- Polymarket market-data collector.
- Hyperliquid hedge model.
- Archive export and verification.
- RAG container deployment.
- Dashboard UI.

These gaps are not defects in this plan; they are separate increments after the foundation compiles and validates core contracts.
