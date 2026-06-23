//! Configuration loading and validation.

use serde::Deserialize;
use thiserror::Error;

/// Application configuration.
#[derive(Debug, Clone, Deserialize)]
pub struct AppConfig {
    /// Database connection settings.
    pub database: DatabaseConfig,
    /// Source-specific settings.
    pub sources: SourcesConfig,
    /// Backfill feature switches.
    pub backfill: BackfillConfig,
    /// Replay defaults.
    pub replay: ReplayConfig,
    /// Retention windows.
    pub retention: RetentionConfig,
}

/// Database configuration.
#[derive(Debug, Clone, Deserialize)]
pub struct DatabaseConfig {
    /// Environment variable that contains the database URL.
    pub url_env: String,
    /// Database connect timeout in seconds.
    pub connect_timeout_seconds: u16,
}

/// Supported source configuration set.
#[derive(Debug, Clone, Deserialize)]
pub struct SourcesConfig {
    /// Bybit source configuration.
    pub bybit: SourceConfig,
    /// Binance source configuration.
    pub binance: SourceConfig,
    /// OKX source configuration.
    pub okx: SourceConfig,
    /// Polymarket public CLOB market-data configuration.
    pub polymarket: SourceConfig,
    /// Hyperliquid public market-data configuration.
    pub hyperliquid: SourceConfig,
}

/// Single market-data source configuration.
#[derive(Debug, Clone, Deserialize)]
pub struct SourceConfig {
    /// Whether the source is enabled.
    pub enabled: bool,
    /// Source quality string, e.g. `all_events` or `snapshot_only`.
    pub quality: String,
    /// Subscribed symbols.
    pub symbols: Vec<String>,
    /// Circuit breaker threshold.
    pub max_reconnects_per_5min: u16,
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

/// Replay default configuration.
#[derive(Debug, Clone, Deserialize)]
pub struct ReplayConfig {
    /// Primary source used by default strategy replay.
    pub default_primary_source: String,
    /// Lower-priority fallback sources. Empty for MVP.
    pub default_fallback_sources: Vec<String>,
    /// Aggregation policy name.
    pub default_aggregation_policy: String,
    /// Paper-fill model name.
    pub fill_model: String,
    /// Cancel unfilled orders this many seconds before expiry.
    pub order_cancel_window_seconds: u16,
    /// Hedge fill timeout in seconds.
    pub hedge_timeout_seconds: u16,
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

/// Configuration validation error.
#[derive(Debug, Error)]
pub enum ConfigError {
    /// TOML parsing failed.
    #[error("failed to parse config TOML")]
    ParseToml(#[from] toml::de::Error),
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
    /// A source quality string is unknown.
    #[error("{field} has unknown source quality: {actual}")]
    UnknownSourceQuality {
        /// Field name.
        field: &'static str,
        /// Actual value.
        actual: String,
    },
    /// Replay primary source is not usable.
    #[error("default_primary_source must be an enabled source, got {actual}")]
    InvalidPrimarySource {
        /// Actual value.
        actual: String,
    },
    /// A collection field is empty.
    #[error("{field} must not be empty")]
    EmptyCollection {
        /// Field name.
        field: &'static str,
    },
}

impl AppConfig {
    /// Parse configuration from TOML text.
    ///
    /// # Errors
    ///
    /// Returns an error when TOML cannot be deserialized.
    pub fn from_toml_str(input: &str) -> Result<Self, ConfigError> {
        Ok(toml::from_str(input)?)
    }

    /// Validate configuration.
    ///
    /// # Errors
    ///
    /// Returns an error when retention windows, source settings, or
    /// research-disabled capabilities are invalid.
    pub fn validate(&self) -> Result<(), ConfigError> {
        validate_days(
            "hot_raw_retention_days",
            self.retention.hot_raw_retention_days,
            1,
            90,
        )?;
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
        validate_days(
            "connect_timeout_seconds",
            self.database.connect_timeout_seconds,
            1,
            120,
        )?;

        validate_source("sources.bybit", &self.sources.bybit)?;
        validate_source("sources.binance", &self.sources.binance)?;
        validate_source("sources.okx", &self.sources.okx)?;
        validate_source("sources.polymarket", &self.sources.polymarket)?;
        validate_source("sources.hyperliquid", &self.sources.hyperliquid)?;

        if self.backfill.okx_rest_enabled {
            return Err(ConfigError::DisabledByResearch {
                feature: "OKX REST liquidation backfill",
                reason: "official OKX changelog says the endpoint was delisted",
            });
        }

        if !self.source_enabled(&self.replay.default_primary_source) {
            return Err(ConfigError::InvalidPrimarySource {
                actual: self.replay.default_primary_source.clone(),
            });
        }

        Ok(())
    }

    fn source_enabled(&self, source: &str) -> bool {
        match source {
            "bybit" => self.sources.bybit.enabled,
            "binance" => self.sources.binance.enabled,
            "okx" => self.sources.okx.enabled,
            "polymarket" => self.sources.polymarket.enabled,
            "hyperliquid" => self.sources.hyperliquid.enabled,
            _ => false,
        }
    }

    #[cfg(test)]
    fn test_default() -> Self {
        Self {
            database: DatabaseConfig {
                url_env: "DATABASE_URL".to_owned(),
                connect_timeout_seconds: 10,
            },
            sources: SourcesConfig {
                bybit: SourceConfig {
                    enabled: true,
                    quality: "all_events".to_owned(),
                    symbols: vec!["BTCUSDT".to_owned()],
                    max_reconnects_per_5min: 5,
                },
                binance: SourceConfig {
                    enabled: true,
                    quality: "snapshot_only".to_owned(),
                    symbols: vec!["btcusdt".to_owned()],
                    max_reconnects_per_5min: 5,
                },
                okx: SourceConfig {
                    enabled: false,
                    quality: "websocket_only".to_owned(),
                    symbols: vec!["BTC-USDT-SWAP".to_owned()],
                    max_reconnects_per_5min: 5,
                },
                polymarket: SourceConfig {
                    enabled: false,
                    quality: "websocket_only".to_owned(),
                    symbols: Vec::new(),
                    max_reconnects_per_5min: 5,
                },
                hyperliquid: SourceConfig {
                    enabled: false,
                    quality: "websocket_only".to_owned(),
                    symbols: vec!["BTC".to_owned()],
                    max_reconnects_per_5min: 5,
                },
            },
            backfill: BackfillConfig {
                binance_enabled: false,
                bybit_enabled: false,
                okx_rest_enabled: false,
            },
            replay: ReplayConfig {
                default_primary_source: "bybit".to_owned(),
                default_fallback_sources: Vec::new(),
                default_aggregation_policy: "primary_only".to_owned(),
                fill_model: "trade_cross".to_owned(),
                order_cancel_window_seconds: 60,
                hedge_timeout_seconds: 10,
            },
            retention: RetentionConfig {
                hot_raw_retention_days: 14,
                canonical_events_retention_days: 30,
                collector_health_retention_days: 7,
            },
        }
    }
}

fn validate_source(field: &'static str, source: &SourceConfig) -> Result<(), ConfigError> {
    if source.enabled && source.symbols.is_empty() {
        return Err(ConfigError::EmptyCollection { field });
    }
    validate_days(
        "max_reconnects_per_5min",
        source.max_reconnects_per_5min,
        1,
        60,
    )?;
    match source.quality.as_str() {
        "all_events" | "snapshot_only" | "derived" | "websocket_only" | "unknown" => Ok(()),
        _ => Err(ConfigError::UnknownSourceQuality {
            field,
            actual: source.quality.clone(),
        }),
    }
}

fn validate_days(field: &'static str, actual: u16, min: u16, max: u16) -> Result<(), ConfigError> {
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

    #[test]
    fn parses_and_validates_default_config() {
        let cfg = AppConfig::from_toml_str(include_str!("../../../config/default.toml"))
            .expect("default config must parse");

        cfg.validate().expect("default config must be valid");
        assert_eq!(cfg.replay.default_primary_source, "bybit");
        assert!(cfg.sources.bybit.enabled);
        assert_eq!(cfg.sources.binance.quality, "snapshot_only");
        assert!(!cfg.sources.okx.enabled);
        assert_eq!(cfg.sources.okx.quality, "websocket_only");
        assert!(!cfg.sources.polymarket.enabled);
        assert!(cfg.sources.polymarket.symbols.is_empty());
        assert!(!cfg.sources.hyperliquid.enabled);
        assert_eq!(cfg.sources.hyperliquid.symbols, ["BTC"]);
    }
}
