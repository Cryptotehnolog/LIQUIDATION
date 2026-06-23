//! Deterministic paper replay foundation.

use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
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

/// Paper fill model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FillModel {
    /// Conservative fill: recorded trades must cross the limit.
    TradeCross,
    /// Optimistic diagnostic fill: top of book must touch the limit.
    BookTouch,
}

impl FillModel {
    /// Stable version string for replay run hashing.
    #[must_use]
    pub const fn version(self) -> &'static str {
        match self {
            Self::TradeCross => "trade_cross_v1",
            Self::BookTouch => "book_touch_v1",
        }
    }
}

/// Paper order side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OrderSide {
    /// Buy order.
    Buy,
    /// Sell order.
    Sell,
}

/// Paper order evaluated by fill models.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PaperOrder {
    /// Stable order id inside one replay run.
    pub order_id: String,
    /// Order side.
    pub side: OrderSide,
    /// Limit price.
    pub limit_price: Decimal,
    /// Requested quantity.
    pub quantity: Decimal,
    /// Inclusive order creation timestamp in milliseconds.
    pub created_unix_ms: i64,
    /// Exclusive order expiry timestamp in milliseconds.
    pub expires_unix_ms: i64,
}

/// Recorded market trade observation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ObservedTrade {
    /// Trade timestamp in milliseconds.
    pub unix_ms: i64,
    /// Trade price.
    pub price: Decimal,
    /// Trade quantity.
    pub quantity: Decimal,
}

/// Recorded top-of-book observation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ObservedBook {
    /// Book timestamp in milliseconds.
    pub unix_ms: i64,
    /// Best bid price.
    pub best_bid: Option<Decimal>,
    /// Best ask price.
    pub best_ask: Option<Decimal>,
}

/// Paper fill decision.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum FillDecision {
    /// Fill is supported by recorded data.
    Filled {
        /// Fill price.
        price: Decimal,
        /// Fill quantity.
        quantity: Decimal,
        /// Timestamp of the observation that proved reachability.
        unix_ms: i64,
        /// Model used for the decision.
        model_version: String,
    },
    /// Fill is not supported by recorded data.
    NotFilled {
        /// Human-readable reason.
        reason: String,
    },
}

/// Evaluate whether an order was reachable under a paper fill model.
#[must_use]
pub fn evaluate_fill(
    order: &PaperOrder,
    model: FillModel,
    trades: &[ObservedTrade],
    books: &[ObservedBook],
) -> FillDecision {
    match model {
        FillModel::TradeCross => trade_cross(order, trades),
        FillModel::BookTouch => book_touch(order, books),
    }
}

fn trade_cross(order: &PaperOrder, trades: &[ObservedTrade]) -> FillDecision {
    trades
        .iter()
        .filter(|trade| in_order_window(order, trade.unix_ms))
        .filter(|trade| crosses(order.side, trade.price, order.limit_price))
        .min_by_key(|trade| trade.unix_ms)
        .map_or_else(
            || FillDecision::NotFilled {
                reason: "no recorded trade crossed limit inside order window".to_owned(),
            },
            |trade| FillDecision::Filled {
                price: trade.price,
                quantity: order.quantity.min(trade.quantity),
                unix_ms: trade.unix_ms,
                model_version: FillModel::TradeCross.version().to_owned(),
            },
        )
}

fn book_touch(order: &PaperOrder, books: &[ObservedBook]) -> FillDecision {
    books
        .iter()
        .filter(|book| in_order_window(order, book.unix_ms))
        .find_map(|book| {
            let touch = match order.side {
                OrderSide::Buy => book.best_ask.filter(|ask| *ask <= order.limit_price),
                OrderSide::Sell => book.best_bid.filter(|bid| *bid >= order.limit_price),
            };
            touch.map(|price| FillDecision::Filled {
                price,
                quantity: order.quantity,
                unix_ms: book.unix_ms,
                model_version: FillModel::BookTouch.version().to_owned(),
            })
        })
        .unwrap_or_else(|| FillDecision::NotFilled {
            reason: "no recorded book touch crossed limit inside order window".to_owned(),
        })
}

fn in_order_window(order: &PaperOrder, unix_ms: i64) -> bool {
    unix_ms >= order.created_unix_ms && unix_ms < order.expires_unix_ms
}

fn crosses(side: OrderSide, observed_price: Decimal, limit_price: Decimal) -> bool {
    match side {
        OrderSide::Buy => observed_price <= limit_price,
        OrderSide::Sell => observed_price >= limit_price,
    }
}

/// Venue for execution cost modelling.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeeVenue {
    /// Polymarket CLOB leg.
    Polymarket,
    /// Hyperliquid hedge leg.
    Hyperliquid,
}

/// Maker/taker role.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LiquidityRole {
    /// Maker execution.
    Maker,
    /// Taker execution.
    Taker,
}

/// Versioned fee schedule assumptions.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FeeSchedule {
    /// Version used in replay input hashes and reports.
    pub version: String,
    /// Polymarket maker fee in basis points.
    pub polymarket_maker_bps: Decimal,
    /// Polymarket taker fee in basis points.
    pub polymarket_taker_bps: Decimal,
    /// Hyperliquid maker fee in basis points.
    pub hyperliquid_maker_bps: Decimal,
    /// Hyperliquid taker fee in basis points.
    pub hyperliquid_taker_bps: Decimal,
    /// Funding or holding cost in basis points per hour.
    pub hyperliquid_funding_bps_per_hour: Decimal,
}

impl FeeSchedule {
    /// Conservative v1 defaults: explicit zero Polymarket fee assumption plus
    /// configurable Hyperliquid/funding values supplied by caller later.
    #[must_use]
    pub fn paper_v1() -> Self {
        Self {
            version: "paper_fee_schedule_v1".to_owned(),
            polymarket_maker_bps: Decimal::ZERO,
            polymarket_taker_bps: Decimal::ZERO,
            hyperliquid_maker_bps: Decimal::ZERO,
            hyperliquid_taker_bps: Decimal::ZERO,
            hyperliquid_funding_bps_per_hour: Decimal::ZERO,
        }
    }

    fn execution_bps(&self, venue: FeeVenue, role: LiquidityRole) -> Decimal {
        match (venue, role) {
            (FeeVenue::Polymarket, LiquidityRole::Maker) => self.polymarket_maker_bps,
            (FeeVenue::Polymarket, LiquidityRole::Taker) => self.polymarket_taker_bps,
            (FeeVenue::Hyperliquid, LiquidityRole::Maker) => self.hyperliquid_maker_bps,
            (FeeVenue::Hyperliquid, LiquidityRole::Taker) => self.hyperliquid_taker_bps,
        }
    }
}

/// One execution cost input.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExecutionCostInput {
    /// Venue.
    pub venue: FeeVenue,
    /// Liquidity role.
    pub role: LiquidityRole,
    /// Execution notional in USD.
    pub notional_usd: Decimal,
    /// Slippage penalty in USD.
    pub slippage_usd: Decimal,
    /// Funding/holding duration in hours.
    pub funding_hours: Decimal,
}

/// Execution cost output.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExecutionCost {
    /// Exchange/trading fee in USD.
    pub fee_usd: Decimal,
    /// Funding/holding cost in USD.
    pub funding_usd: Decimal,
    /// Slippage penalty in USD.
    pub slippage_usd: Decimal,
    /// Total cost in USD.
    pub total_usd: Decimal,
}

/// Calculate fees, funding, and slippage for one execution.
#[must_use]
pub fn calculate_execution_cost(
    schedule: &FeeSchedule,
    input: &ExecutionCostInput,
) -> ExecutionCost {
    let fee_usd = basis_points(
        input.notional_usd,
        schedule.execution_bps(input.venue, input.role),
    );
    let funding_usd = if input.venue == FeeVenue::Hyperliquid {
        basis_points(
            input.notional_usd,
            schedule.hyperliquid_funding_bps_per_hour * input.funding_hours,
        )
    } else {
        Decimal::ZERO
    };
    let total_usd = fee_usd + funding_usd + input.slippage_usd;
    ExecutionCost {
        fee_usd,
        funding_usd,
        slippage_usd: input.slippage_usd,
        total_usd,
    }
}

fn basis_points(notional: Decimal, bps: Decimal) -> Decimal {
    notional * bps / Decimal::new(10_000, 0)
}

/// Trading mode requested by an operator command.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TradingMode {
    /// Paper-only simulation.
    Paper,
    /// Live order placement.
    Live,
}

/// Paper-only safety gate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PaperOnlyGate {
    allow_live: bool,
}

impl PaperOnlyGate {
    /// Build fail-closed paper-only gate.
    #[must_use]
    pub const fn paper_only() -> Self {
        Self { allow_live: false }
    }

    /// Validate that requested execution mode is allowed.
    ///
    /// # Errors
    ///
    /// Returns an error when live trading is requested while the gate is closed.
    pub fn ensure_allowed(self, mode: TradingMode) -> Result<(), SafetyGateError> {
        if matches!(mode, TradingMode::Live) && !self.allow_live {
            return Err(SafetyGateError::LiveTradingDisabled);
        }
        Ok(())
    }
}

/// Safety gate error.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum SafetyGateError {
    /// Live trading is intentionally disabled.
    #[error("live trading is disabled: paper-only safety gate is closed")]
    LiveTradingDisabled,
}

/// Minimal strategy trait for deterministic replay.
pub trait Strategy<Event> {
    /// Stable strategy version.
    fn version(&self) -> &'static str;
    /// Process one event and return generated signals.
    fn on_event(&mut self, event: &Event) -> Vec<StrategySignal>;
}

/// Strategy signal emitted by a replay strategy.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StrategySignal {
    /// Stable signal id within a replay run.
    pub signal_id: String,
    /// Instrument or market symbol.
    pub symbol: String,
    /// Intended side.
    pub side: OrderSide,
    /// Limit price for paper entry.
    pub limit_price: Decimal,
    /// Signal quantity.
    pub quantity: Decimal,
    /// Signal creation timestamp in milliseconds.
    pub created_unix_ms: i64,
    /// Signal expiry timestamp in milliseconds.
    pub expires_unix_ms: i64,
}

/// Replay inputs included in deterministic hashing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReplayInput {
    /// Strategy version.
    pub strategy_version: String,
    /// Fill model.
    pub fill_model: FillModel,
    /// Fee schedule version.
    pub fee_schedule_version: String,
    /// Included source ids.
    pub sources: Vec<String>,
    /// Inclusive start timestamp in milliseconds.
    pub start_unix_ms: i64,
    /// Exclusive end timestamp in milliseconds.
    pub end_unix_ms: i64,
    /// Ordered strategy/fill parameters.
    pub parameters: BTreeMap<String, String>,
}

/// Deterministically hash replay inputs.
///
/// # Errors
///
/// Returns an error if replay input serialization fails.
pub fn replay_input_hash(input: &ReplayInput) -> Result<String, serde_json::Error> {
    let bytes = serde_json::to_vec(input)?;
    let digest = Sha256::digest(bytes);
    Ok(format!("{digest:x}"))
}

/// Strategy readiness report for fail-closed operator checks.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StrategyReadinessReport {
    /// Whether baseline strategy implementation is allowed to start.
    pub ready_for_strategy: bool,
    /// Implemented pre-strategy capabilities.
    pub capabilities: Vec<ReadinessItem>,
    /// Remaining blockers.
    pub blockers: Vec<ReadinessItem>,
}

/// One readiness item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadinessItem {
    /// Stable item id.
    pub id: String,
    /// Human-readable status.
    pub status: String,
    /// Short note.
    pub note: String,
}

impl StrategyReadinessReport {
    /// Current code-level pre-strategy readiness.
    #[must_use]
    pub fn current_foundation() -> Self {
        Self {
            ready_for_strategy: false,
            capabilities: vec![
                ready(
                    "market_data_domain",
                    "Polymarket/Hyperliquid market-data domain types exist",
                ),
                ready(
                    "fee_funding_model",
                    "fee, funding, and slippage components are explicit",
                ),
                ready(
                    "deterministic_replay_hash",
                    "input_hash covers strategy, fill, fees, sources, range, and params",
                ),
                ready(
                    "fill_model",
                    "trade_cross and diagnostic book_touch are implemented",
                ),
                ready(
                    "paper_only_safety_gate",
                    "live trading fails closed by default",
                ),
            ],
            blockers: vec![
                blocked(
                    "polymarket_live_probe",
                    "public Polymarket recorder probe is not implemented yet",
                ),
                blocked(
                    "hyperliquid_market_data_probe",
                    "Hyperliquid hedge market-data probe is not implemented yet",
                ),
                blocked(
                    "baseline_strategy_port",
                    "Python baseline strategy has not been ported to Rust yet",
                ),
            ],
        }
    }
}

fn ready(id: &str, note: &str) -> ReadinessItem {
    ReadinessItem {
        id: id.to_owned(),
        status: "ready".to_owned(),
        note: note.to_owned(),
    }
}

fn blocked(id: &str, note: &str) -> ReadinessItem {
    ReadinessItem {
        id: id.to_owned(),
        status: "blocked".to_owned(),
        note: note.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal::Decimal;

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

    #[test]
    fn trade_cross_fills_only_when_trade_crosses_limit() {
        let order = buy_order(50);
        let decision = evaluate_fill(
            &order,
            FillModel::TradeCross,
            &[ObservedTrade {
                unix_ms: 20,
                price: Decimal::new(49, 2),
                quantity: Decimal::new(10, 0),
            }],
            &[],
        );

        assert!(matches!(decision, FillDecision::Filled { .. }));
    }

    #[test]
    fn trade_cross_rejects_book_only_touch() {
        let order = buy_order(50);
        let decision = evaluate_fill(
            &order,
            FillModel::TradeCross,
            &[],
            &[ObservedBook {
                unix_ms: 20,
                best_bid: Some(Decimal::new(48, 2)),
                best_ask: Some(Decimal::new(49, 2)),
            }],
        );

        assert!(matches!(decision, FillDecision::NotFilled { .. }));
    }

    #[test]
    fn book_touch_is_optimistic_diagnostic() {
        let order = buy_order(50);
        let decision = evaluate_fill(
            &order,
            FillModel::BookTouch,
            &[],
            &[ObservedBook {
                unix_ms: 20,
                best_bid: Some(Decimal::new(48, 2)),
                best_ask: Some(Decimal::new(49, 2)),
            }],
        );

        assert!(matches!(decision, FillDecision::Filled { .. }));
    }

    #[test]
    fn execution_cost_separates_fee_funding_and_slippage() {
        let schedule = FeeSchedule {
            hyperliquid_taker_bps: Decimal::new(5, 0),
            hyperliquid_funding_bps_per_hour: Decimal::new(1, 0),
            ..FeeSchedule::paper_v1()
        };
        let cost = calculate_execution_cost(
            &schedule,
            &ExecutionCostInput {
                venue: FeeVenue::Hyperliquid,
                role: LiquidityRole::Taker,
                notional_usd: Decimal::new(1000, 0),
                slippage_usd: Decimal::new(25, 1),
                funding_hours: Decimal::new(2, 0),
            },
        );

        assert_eq!(cost.fee_usd, Decimal::new(5, 1));
        assert_eq!(cost.funding_usd, Decimal::new(2, 1));
        assert_eq!(cost.slippage_usd, Decimal::new(25, 1));
        assert_eq!(cost.total_usd, Decimal::new(32, 1));
    }

    #[test]
    fn paper_only_gate_blocks_live_mode() {
        let err = PaperOnlyGate::paper_only()
            .ensure_allowed(TradingMode::Live)
            .expect_err("live mode must fail closed");

        assert_eq!(err, SafetyGateError::LiveTradingDisabled);
    }

    #[test]
    fn replay_input_hash_changes_when_fill_model_changes() {
        let mut input = replay_input();
        let first = replay_input_hash(&input).expect("hash must serialize");
        input.fill_model = FillModel::BookTouch;
        let second = replay_input_hash(&input).expect("hash must serialize");

        assert_ne!(first, second);
    }

    #[test]
    fn readiness_report_is_honest_about_remaining_live_blockers() {
        let report = StrategyReadinessReport::current_foundation();

        assert!(!report.ready_for_strategy);
        assert!(
            report
                .capabilities
                .iter()
                .any(|item| item.id == "paper_only_safety_gate")
        );
        assert!(
            report
                .blockers
                .iter()
                .any(|item| item.id == "polymarket_live_probe")
        );
    }

    fn buy_order(limit_cents: i64) -> PaperOrder {
        PaperOrder {
            order_id: "order-1".to_owned(),
            side: OrderSide::Buy,
            limit_price: Decimal::new(limit_cents, 2),
            quantity: Decimal::new(1, 0),
            created_unix_ms: 10,
            expires_unix_ms: 30,
        }
    }

    fn replay_input() -> ReplayInput {
        ReplayInput {
            strategy_version: "baseline_v0".to_owned(),
            fill_model: FillModel::TradeCross,
            fee_schedule_version: "paper_fee_schedule_v1".to_owned(),
            sources: vec!["bybit".to_owned(), "polymarket".to_owned()],
            start_unix_ms: 1,
            end_unix_ms: 2,
            parameters: BTreeMap::from([("pullback_pct".to_owned(), "0.02".to_owned())]),
        }
    }
}
