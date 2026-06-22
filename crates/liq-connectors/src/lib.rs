//! Exchange connector normalizers.

pub mod binance;
pub mod bybit;
pub mod okx;

use thiserror::Error;

/// Connector normalization error.
#[derive(Debug, Error)]
pub enum ConnectorError {
    /// JSON payload could not be parsed.
    #[error("invalid JSON payload")]
    Json(#[from] serde_json::Error),
    /// Decimal field could not be parsed.
    #[error("{field} has invalid decimal value: {value}")]
    Decimal {
        /// Field name.
        field: &'static str,
        /// Invalid value.
        value: String,
    },
    /// Timestamp field is outside supported range.
    #[error("invalid millisecond timestamp: {0}")]
    Timestamp(i64),
    /// Required field is missing or semantically unknown.
    #[error("missing or unsupported field: {0}")]
    Missing(&'static str),
}
