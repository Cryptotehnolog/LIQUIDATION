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

        let err = validate_dry_run(&request).expect_err("invalid range must fail");
        assert!(err.to_string().contains("end_unix_ms"));
    }
}
