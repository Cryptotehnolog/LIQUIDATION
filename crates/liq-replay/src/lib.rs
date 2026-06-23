//! Deterministic paper replay foundation.

use liq_domain::{LiquidationEvent, LiquidationSide, MarketQuote, MarketVenue};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, VecDeque};
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
    /// Prediction-market outcome targeted by the baseline strategy.
    pub outcome: Option<PredictionOutcome>,
    /// Inverse Hyperliquid hedge side implied by the prediction outcome.
    pub hedge_side: Option<HedgeSide>,
    /// Liquidation signal type that caused this strategy signal.
    pub source_signal: Option<LiquidationSignalKind>,
    /// Dominant liquidation notional that crossed the strategy threshold.
    pub source_notional_usd: Option<Decimal>,
}

/// Binary prediction-market outcome used by the baseline BTC up/down strategy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PredictionOutcome {
    /// BTC UP outcome.
    Up,
    /// BTC DOWN outcome.
    Down,
}

/// Paper hedge side for the inverse Hyperliquid leg.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HedgeSide {
    /// Long hedge.
    Long,
    /// Short hedge.
    Short,
}

/// Dominant liquidation signal kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LiquidationSignalKind {
    /// Long liquidations dominate, bearish, target DOWN.
    LongLiquidation,
    /// Short liquidations dominate, bullish, target UP.
    ShortLiquidation,
}

/// Active Polymarket BTC 5-minute market metadata required by replay.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BaselineMarket {
    /// Market id or slug.
    pub market_id: String,
    /// Token id for the UP outcome.
    pub up_token_id: String,
    /// Token id for the DOWN outcome.
    pub down_token_id: String,
    /// Inclusive market start timestamp in milliseconds.
    pub start_unix_ms: i64,
    /// Exclusive market end timestamp in milliseconds.
    pub end_unix_ms: i64,
}

/// Event stream consumed by the baseline paper strategy.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum BaselineEvent {
    /// A new Polymarket BTC up/down market became active.
    MarketOpened(BaselineMarket),
    /// Canonical liquidation event.
    Liquidation(LiquidationEvent),
    /// Polymarket top-of-book quote for an outcome token.
    PolymarketQuote(MarketQuote),
}

/// Static baseline strategy parameters ported from the original Python bot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BaselineStrategyConfig {
    /// Minimum dominant liquidation notional for a signal.
    pub liquidation_threshold_min_usd: Decimal,
    /// Maximum dominant liquidation notional; above this the wave is considered missed.
    pub liquidation_threshold_max_usd: Decimal,
    /// Rolling liquidation aggregation window in milliseconds.
    pub liquidation_window_ms: i64,
    /// Pullback percentage applied to the observed Polymarket best ask.
    pub pullback_pct: Decimal,
    /// Minimum allowed Polymarket limit price.
    pub min_polymarket_price: Decimal,
    /// Paper USD allocated to the Polymarket leg.
    pub polymarket_usd_per_position: Decimal,
    /// Cancel or avoid unfilled orders this many milliseconds before market expiry.
    pub order_cancel_window_ms: i64,
}

impl Default for BaselineStrategyConfig {
    fn default() -> Self {
        Self {
            liquidation_threshold_min_usd: Decimal::new(25_000, 0),
            liquidation_threshold_max_usd: Decimal::new(100_000, 0),
            liquidation_window_ms: 10 * 60 * 1_000,
            pullback_pct: Decimal::new(30, 2),
            min_polymarket_price: Decimal::new(1, 2),
            polymarket_usd_per_position: Decimal::new(15, 0),
            order_cancel_window_ms: 60 * 1_000,
        }
    }
}

/// Baseline paper strategy: liquidation cascade signal, Polymarket stink bid,
/// and inverse Hyperliquid hedge intent.
#[derive(Debug, Clone)]
pub struct BaselineStinkBidStrategy {
    config: BaselineStrategyConfig,
    current_market: Option<BaselineMarket>,
    latest_polymarket_quotes: HashMap<String, MarketQuote>,
    liquidation_window: VecDeque<LiquidationWindowItem>,
    signal_fired_for_market: bool,
}

#[derive(Debug, Clone, Copy)]
struct LiquidationWindowItem {
    unix_ms: i64,
    side: LiquidationSide,
    notional_usd: Decimal,
}

impl BaselineStinkBidStrategy {
    /// Create a baseline strategy with explicit static parameters.
    #[must_use]
    pub fn new(config: BaselineStrategyConfig) -> Self {
        Self {
            config,
            current_market: None,
            latest_polymarket_quotes: HashMap::new(),
            liquidation_window: VecDeque::new(),
            signal_fired_for_market: false,
        }
    }

    fn on_market_opened(&mut self, market: BaselineMarket) {
        self.current_market = Some(market);
        self.signal_fired_for_market = false;
        self.liquidation_window.clear();
    }

    fn on_polymarket_quote(&mut self, quote: MarketQuote) {
        if quote.venue == MarketVenue::Polymarket {
            self.latest_polymarket_quotes
                .insert(quote.instrument_id.clone(), quote);
        }
    }

    fn on_liquidation(&mut self, event: &LiquidationEvent) -> Vec<StrategySignal> {
        if self.signal_fired_for_market || !is_btc_symbol(&event.symbol) {
            return Vec::new();
        }

        let event_unix_ms = event_ts_ms(event);
        self.liquidation_window.push_back(LiquidationWindowItem {
            unix_ms: event_unix_ms,
            side: event.side,
            notional_usd: event.notional_usd,
        });
        self.prune_liquidations(event_unix_ms);

        let Some(market) = self.current_market.as_ref() else {
            return Vec::new();
        };
        if market.end_unix_ms - event_unix_ms <= self.config.order_cancel_window_ms {
            return Vec::new();
        }

        let long_total = self.window_notional(LiquidationSide::Long);
        let short_total = self.window_notional(LiquidationSide::Short);
        let Some((signal_kind, notional, outcome, hedge_side, token_id)) =
            self.select_signal(long_total, short_total, market)
        else {
            return Vec::new();
        };
        let Some(quote) = self.latest_polymarket_quotes.get(token_id) else {
            return Vec::new();
        };
        let Some(best_ask) = quote.best_ask else {
            return Vec::new();
        };
        let limit_price = self.stink_bid_price(best_ask);
        let Some(quantity) =
            calculate_polymarket_shares(self.config.polymarket_usd_per_position, limit_price)
        else {
            return Vec::new();
        };

        self.signal_fired_for_market = true;
        vec![StrategySignal {
            signal_id: format!("{}:{}:{}", Self::VERSION, market.market_id, event_unix_ms),
            symbol: token_id.to_owned(),
            side: OrderSide::Buy,
            limit_price,
            quantity,
            created_unix_ms: event_unix_ms,
            expires_unix_ms: market.end_unix_ms - self.config.order_cancel_window_ms,
            outcome: Some(outcome),
            hedge_side: Some(hedge_side),
            source_signal: Some(signal_kind),
            source_notional_usd: Some(notional),
        }]
    }

    fn prune_liquidations(&mut self, now_unix_ms: i64) {
        let cutoff = now_unix_ms - self.config.liquidation_window_ms;
        while self
            .liquidation_window
            .front()
            .is_some_and(|item| item.unix_ms < cutoff)
        {
            self.liquidation_window.pop_front();
        }
    }

    fn window_notional(&self, side: LiquidationSide) -> Decimal {
        self.liquidation_window
            .iter()
            .filter(|item| item.side == side)
            .map(|item| item.notional_usd)
            .sum()
    }

    fn select_signal<'a>(
        &self,
        long_total: Decimal,
        short_total: Decimal,
        market: &'a BaselineMarket,
    ) -> Option<(
        LiquidationSignalKind,
        Decimal,
        PredictionOutcome,
        HedgeSide,
        &'a str,
    )> {
        if within_signal_band(
            long_total,
            self.config.liquidation_threshold_min_usd,
            self.config.liquidation_threshold_max_usd,
        ) && long_total > short_total
        {
            return Some((
                LiquidationSignalKind::LongLiquidation,
                long_total,
                PredictionOutcome::Down,
                HedgeSide::Long,
                &market.down_token_id,
            ));
        }
        if within_signal_band(
            short_total,
            self.config.liquidation_threshold_min_usd,
            self.config.liquidation_threshold_max_usd,
        ) && short_total > long_total
        {
            return Some((
                LiquidationSignalKind::ShortLiquidation,
                short_total,
                PredictionOutcome::Up,
                HedgeSide::Short,
                &market.up_token_id,
            ));
        }
        None
    }

    fn stink_bid_price(&self, best_ask: Decimal) -> Decimal {
        let candidate = (best_ask * (Decimal::ONE - self.config.pullback_pct)).round_dp(4);
        candidate.max(self.config.min_polymarket_price)
    }

    const VERSION: &'static str = "baseline_stink_bid_v1";
}

impl Strategy<BaselineEvent> for BaselineStinkBidStrategy {
    fn version(&self) -> &'static str {
        Self::VERSION
    }

    fn on_event(&mut self, event: &BaselineEvent) -> Vec<StrategySignal> {
        match event {
            BaselineEvent::MarketOpened(market) => {
                self.on_market_opened(market.clone());
                Vec::new()
            }
            BaselineEvent::Liquidation(event) => self.on_liquidation(event),
            BaselineEvent::PolymarketQuote(quote) => {
                self.on_polymarket_quote(quote.clone());
                Vec::new()
            }
        }
    }
}

fn is_btc_symbol(symbol: &str) -> bool {
    symbol.to_ascii_uppercase().contains("BTC")
}

fn event_ts_ms(event: &LiquidationEvent) -> i64 {
    let millis = event.received_ts.unix_timestamp_nanos() / 1_000_000;
    match i64::try_from(millis) {
        Ok(value) => value,
        Err(_) if millis.is_negative() => i64::MIN,
        Err(_) => i64::MAX,
    }
}

fn within_signal_band(value: Decimal, min: Decimal, max: Decimal) -> bool {
    value >= min && value <= max
}

fn calculate_polymarket_shares(dollar_amount: Decimal, price: Decimal) -> Option<Decimal> {
    if price <= Decimal::ZERO {
        return None;
    }

    let minimum_shares = Decimal::new(5, 0);
    let minimum_notional = Decimal::ONE;
    let share_step = Decimal::new(1, 1);

    let mut shares = (dollar_amount / price).round_dp(1);
    if shares < minimum_shares {
        shares = minimum_shares;
    }
    if shares * price < minimum_notional {
        let shares_for_dollar = (minimum_notional / price).round_dp(1);
        shares = shares_for_dollar.max(minimum_shares);
    }
    if shares * price < minimum_notional {
        shares += share_step;
    }

    if shares * price < minimum_notional || shares < minimum_shares {
        None
    } else {
        Some(shares)
    }
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

/// Market-data evidence observed in durable storage.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct MarketDataReadiness {
    /// Polymarket quote rows inside the readiness window.
    pub polymarket_quotes: i64,
    /// Polymarket trade rows inside the readiness window.
    pub polymarket_trades: i64,
    /// Hyperliquid quote rows inside the readiness window.
    pub hyperliquid_quotes: i64,
    /// Hyperliquid trade rows inside the readiness window.
    pub hyperliquid_trades: i64,
}

/// Detailed readiness output for operators and dashboard/debug tooling.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StrategyReadinessExplanation {
    /// Normal readiness report.
    pub report: StrategyReadinessReport,
    /// Raw storage evidence used by readiness conditions.
    pub evidence: MarketDataReadiness,
    /// Per-condition explanation with required and observed values.
    pub conditions: Vec<ReadinessCondition>,
}

/// One machine-readable readiness condition.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadinessCondition {
    /// Stable condition id.
    pub id: String,
    /// Required condition.
    pub required: String,
    /// Observed value.
    pub observed: String,
    /// Whether the condition passed.
    pub passed: bool,
}

impl MarketDataReadiness {
    fn has_polymarket_probe(self) -> bool {
        self.polymarket_quotes > 0 || self.polymarket_trades > 0
    }

    fn has_hyperliquid_probe(self) -> bool {
        self.hyperliquid_quotes > 0 && self.hyperliquid_trades > 0
    }
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
                ready(
                    "baseline_strategy_port",
                    "baseline liquidation stink-bid strategy is implemented in Rust",
                ),
            ],
            blockers: vec![
                blocked(
                    "polymarket_live_probe",
                    "no Polymarket market-data rows observed in readiness window",
                ),
                blocked(
                    "hyperliquid_market_data_probe",
                    "no Hyperliquid quote/trade rows observed in readiness window",
                ),
            ],
        }
    }

    /// Build readiness report from observed market-data evidence.
    #[must_use]
    pub fn from_market_data(readiness: MarketDataReadiness) -> Self {
        let mut report = Self::current_foundation();

        if readiness.has_polymarket_probe() {
            move_blocker_to_capability(
                &mut report,
                "polymarket_live_probe",
                "Polymarket market-data rows exist in readiness window",
            );
        }
        if readiness.has_hyperliquid_probe() {
            move_blocker_to_capability(
                &mut report,
                "hyperliquid_market_data_probe",
                "Hyperliquid quote and trade rows exist in readiness window",
            );
        }

        report.ready_for_strategy = report.blockers.is_empty();
        report
    }
}

impl StrategyReadinessExplanation {
    /// Build an explain report from observed market-data evidence.
    #[must_use]
    pub fn from_market_data(readiness: MarketDataReadiness) -> Self {
        let report = StrategyReadinessReport::from_market_data(readiness);
        let conditions = vec![
            ReadinessCondition {
                id: "baseline_strategy_port".to_owned(),
                required: "code capability present".to_owned(),
                observed: "implemented".to_owned(),
                passed: true,
            },
            ReadinessCondition {
                id: "polymarket_live_probe".to_owned(),
                required: "polymarket_quotes > 0 OR polymarket_trades > 0".to_owned(),
                observed: format!(
                    "quotes={} trades={}",
                    readiness.polymarket_quotes, readiness.polymarket_trades
                ),
                passed: readiness.has_polymarket_probe(),
            },
            ReadinessCondition {
                id: "hyperliquid_market_data_probe".to_owned(),
                required: "hyperliquid_quotes > 0 AND hyperliquid_trades > 0".to_owned(),
                observed: format!(
                    "quotes={} trades={}",
                    readiness.hyperliquid_quotes, readiness.hyperliquid_trades
                ),
                passed: readiness.has_hyperliquid_probe(),
            },
        ];

        Self {
            report,
            evidence: readiness,
            conditions,
        }
    }

    /// Build an explain report without database evidence.
    #[must_use]
    pub fn current_foundation() -> Self {
        Self::from_market_data(MarketDataReadiness {
            polymarket_quotes: 0,
            polymarket_trades: 0,
            hyperliquid_quotes: 0,
            hyperliquid_trades: 0,
        })
    }
}

fn move_blocker_to_capability(report: &mut StrategyReadinessReport, id: &str, note: &str) {
    if let Some(position) = report.blockers.iter().position(|item| item.id == id) {
        let mut item = report.blockers.remove(position);
        "ready".clone_into(&mut item.status);
        note.clone_into(&mut item.note);
        report.capabilities.push(item);
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
    use time::OffsetDateTime;

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
                .capabilities
                .iter()
                .any(|item| item.id == "baseline_strategy_port")
        );
        assert!(
            report
                .blockers
                .iter()
                .any(|item| item.id == "polymarket_live_probe")
        );
    }

    #[test]
    fn readiness_report_closes_market_data_blockers_from_observed_rows() {
        let report = StrategyReadinessReport::from_market_data(MarketDataReadiness {
            polymarket_quotes: 1,
            polymarket_trades: 1,
            hyperliquid_quotes: 1,
            hyperliquid_trades: 1,
        });

        assert!(report.ready_for_strategy);
        assert!(
            report
                .capabilities
                .iter()
                .any(|item| item.id == "polymarket_live_probe")
        );
        assert!(
            report
                .capabilities
                .iter()
                .any(|item| item.id == "hyperliquid_market_data_probe")
        );
        assert!(
            report
                .blockers
                .iter()
                .all(|item| item.id != "polymarket_live_probe")
        );
        assert!(
            report
                .blockers
                .iter()
                .all(|item| item.id != "hyperliquid_market_data_probe")
        );
        assert!(report.blockers.is_empty());
    }

    #[test]
    fn readiness_report_closes_polymarket_probe_with_quote_evidence() {
        let report = StrategyReadinessReport::from_market_data(MarketDataReadiness {
            polymarket_quotes: 1,
            polymarket_trades: 0,
            hyperliquid_quotes: 0,
            hyperliquid_trades: 0,
        });

        assert!(
            report
                .capabilities
                .iter()
                .any(|item| item.id == "polymarket_live_probe")
        );
        assert!(
            report
                .blockers
                .iter()
                .all(|item| item.id != "polymarket_live_probe")
        );
        assert!(
            report
                .blockers
                .iter()
                .any(|item| item.id == "hyperliquid_market_data_probe")
        );
    }

    #[test]
    fn baseline_strategy_buys_down_after_dominant_long_liquidations() {
        let market = baseline_market();
        let mut strategy = BaselineStinkBidStrategy::new(BaselineStrategyConfig::default());

        assert!(
            strategy
                .on_event(&BaselineEvent::MarketOpened(market.clone()))
                .is_empty()
        );
        assert!(
            strategy
                .on_event(&BaselineEvent::PolymarketQuote(polymarket_quote(
                    &market.down_token_id,
                    Decimal::new(50, 2),
                    1_000
                )))
                .is_empty()
        );

        let signals = strategy.on_event(&BaselineEvent::Liquidation(liquidation(
            LiquidationSide::Long,
            Decimal::new(25_000, 0),
            1_500,
        )));

        assert_eq!(signals.len(), 1);
        let signal = &signals[0];
        assert_eq!(signal.symbol, market.down_token_id);
        assert_eq!(signal.side, OrderSide::Buy);
        assert_eq!(signal.limit_price, Decimal::new(35, 2));
        assert_eq!(signal.quantity, Decimal::new(429, 1));
        assert_eq!(signal.outcome, Some(PredictionOutcome::Down));
        assert_eq!(signal.hedge_side, Some(HedgeSide::Long));
        assert_eq!(
            signal.source_signal,
            Some(LiquidationSignalKind::LongLiquidation)
        );
    }

    #[test]
    fn baseline_strategy_buys_up_after_dominant_short_liquidations() {
        let market = baseline_market();
        let mut strategy = BaselineStinkBidStrategy::new(BaselineStrategyConfig::default());

        strategy.on_event(&BaselineEvent::MarketOpened(market.clone()));
        strategy.on_event(&BaselineEvent::PolymarketQuote(polymarket_quote(
            &market.up_token_id,
            Decimal::new(40, 2),
            1_000,
        )));

        let signals = strategy.on_event(&BaselineEvent::Liquidation(liquidation(
            LiquidationSide::Short,
            Decimal::new(30_000, 0),
            1_500,
        )));

        assert_eq!(signals.len(), 1);
        let signal = &signals[0];
        assert_eq!(signal.symbol, market.up_token_id);
        assert_eq!(signal.limit_price, Decimal::new(28, 2));
        assert_eq!(signal.outcome, Some(PredictionOutcome::Up));
        assert_eq!(signal.hedge_side, Some(HedgeSide::Short));
        assert_eq!(
            signal.source_signal,
            Some(LiquidationSignalKind::ShortLiquidation)
        );
    }

    #[test]
    fn readiness_explain_reports_counts_conditions_and_baseline_capability() {
        let explanation = StrategyReadinessExplanation::from_market_data(MarketDataReadiness {
            polymarket_quotes: 1,
            polymarket_trades: 0,
            hyperliquid_quotes: 3,
            hyperliquid_trades: 4,
        });

        assert!(explanation.report.ready_for_strategy);
        assert_eq!(explanation.evidence.polymarket_quotes, 1);
        assert!(explanation.conditions.iter().any(|condition| {
            condition.id == "baseline_strategy_port"
                && condition.required == "code capability present"
                && condition.observed == "implemented"
        }));
        assert!(explanation.conditions.iter().any(|condition| {
            condition.id == "hyperliquid_market_data_probe"
                && condition.passed
                && condition.observed.contains("quotes=3 trades=4")
        }));
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

    fn baseline_market() -> BaselineMarket {
        BaselineMarket {
            market_id: "btc-updown-5m=1000".to_owned(),
            up_token_id: "up-token".to_owned(),
            down_token_id: "down-token".to_owned(),
            start_unix_ms: 1_000,
            end_unix_ms: 301_000,
        }
    }

    fn polymarket_quote(
        token_id: &str,
        best_ask: Decimal,
        unix_ms: i64,
    ) -> liq_domain::MarketQuote {
        liq_domain::MarketQuote {
            event_id: uuid::Uuid::nil(),
            venue: liq_domain::MarketVenue::Polymarket,
            source_event_id: format!("quote:{token_id}:{unix_ms}"),
            instrument_id: token_id.to_owned(),
            symbol: "btc-updown".to_owned(),
            best_bid: Some(best_ask - Decimal::new(1, 2)),
            best_bid_size: Some(Decimal::new(10, 0)),
            best_ask: Some(best_ask),
            best_ask_size: Some(Decimal::new(10, 0)),
            exchange_ts: OffsetDateTime::from_unix_timestamp(unix_ms / 1_000)
                .expect("fixture timestamp"),
            received_ts: OffsetDateTime::from_unix_timestamp(unix_ms / 1_000)
                .expect("fixture timestamp"),
        }
    }

    fn liquidation(
        side: LiquidationSide,
        notional_usd: Decimal,
        unix_ms: i64,
    ) -> liq_domain::LiquidationEvent {
        liq_domain::LiquidationEvent {
            event_id: uuid::Uuid::nil(),
            source: liq_domain::Source::Bybit,
            source_event_id: format!("liq:{side:?}:{unix_ms}"),
            source_quality: liq_domain::SourceQuality::AllEvents,
            symbol: "BTCUSDT".to_owned(),
            side,
            price: Decimal::new(65_000, 0),
            quantity: Decimal::new(1, 0),
            notional_usd,
            exchange_ts: OffsetDateTime::from_unix_timestamp(unix_ms / 1_000)
                .expect("fixture timestamp"),
            received_ts: OffsetDateTime::from_unix_timestamp(unix_ms / 1_000)
                .expect("fixture timestamp"),
        }
    }
}
