//! Deterministic paper replay foundation.

use liq_domain::{LiquidationEvent, LiquidationSide, MarketQuote, MarketTrade, MarketVenue};
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

/// Input dataset for one deterministic paper replay run.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PaperReplayInput {
    /// Active Polymarket market metadata.
    pub market: BaselineMarket,
    /// Canonical liquidation events used by the baseline signal.
    pub liquidations: Vec<LiquidationEvent>,
    /// Polymarket top-of-book quotes.
    pub polymarket_quotes: Vec<MarketQuote>,
    /// Polymarket trades used by conservative fill models.
    pub polymarket_trades: Vec<MarketTrade>,
    /// Hyperliquid top-of-book quotes used as hedge evidence.
    pub hyperliquid_quotes: Vec<MarketQuote>,
    /// Hyperliquid trades used as hedge execution evidence.
    pub hyperliquid_trades: Vec<MarketTrade>,
    /// Polymarket entry fill model.
    pub fill_model: FillModel,
    /// Fee and funding assumptions.
    pub fee_schedule: FeeSchedule,
    /// Paper hedge notional in USD for each filled Polymarket signal.
    pub hedge_notional_usd: Decimal,
    /// Conservative hedge slippage penalty per hedge fill.
    pub hedge_slippage_usd: Decimal,
    /// Funding duration charged per hedge fill.
    pub funding_hours: Decimal,
}

/// Paper replay report with `PnL` and risk diagnostics.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PaperReplayReport {
    /// Stable strategy version.
    pub strategy_version: String,
    /// Fill model version used for Polymarket entries.
    pub fill_model_version: String,
    /// Fee schedule version.
    pub fee_schedule_version: String,
    /// Number of strategy signals emitted.
    pub signal_count: u64,
    /// Number of Polymarket paper orders created.
    pub polymarket_orders: u64,
    /// Number of Polymarket fills supported by recorded data.
    pub polymarket_fills: u64,
    /// Number of Hyperliquid hedge attempts after filled Polymarket entries.
    pub hedge_attempts: u64,
    /// Number of Hyperliquid hedge fills supported by recorded data.
    pub hedge_fills: u64,
    /// Filled Polymarket entries without a filled hedge.
    pub unhedged_signals: u64,
    /// Gross realized `PnL` in USD. Settlement is not modelled in v1.
    pub gross_pnl_usd: Decimal,
    /// Total exchange fees in USD.
    pub total_fees_usd: Decimal,
    /// Total funding cost in USD.
    pub total_funding_usd: Decimal,
    /// Total slippage penalty in USD.
    pub total_slippage_usd: Decimal,
    /// Net `PnL` after fees, funding, and slippage.
    pub net_pnl_usd: Decimal,
    /// Maximum drawdown over the replay equity curve.
    pub max_drawdown_usd: Decimal,
    /// Settlement status for prediction-market outcome valuation.
    pub settlement_status: PaperSettlementStatus,
    /// Aggregated reasons explaining why candidate events did not become complete replay trades.
    pub signal_rejection_reasons: Vec<SignalRejectionReason>,
    /// Per-signal diagnostics.
    pub trades: Vec<PaperReplayTrade>,
}

/// Aggregated replay diagnostic explaining missing signals, fills, or hedges.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignalRejectionReason {
    /// Stable machine-readable reason id.
    pub id: String,
    /// Replay stage where the rejection happened.
    pub stage: String,
    /// Short human-readable reason.
    pub label: String,
    /// Number of observations that matched this reason.
    pub count: u64,
    /// Compact diagnostic details for the most recent matching observation.
    pub detail: String,
}

/// Row counts available for one paper replay window.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaperReplayDataCounts {
    /// Canonical liquidation events.
    pub liquidations: usize,
    /// Polymarket quote rows.
    pub polymarket_quotes: usize,
    /// Polymarket trade rows.
    pub polymarket_trades: usize,
    /// Hyperliquid quote rows.
    pub hyperliquid_quotes: usize,
    /// Hyperliquid trade rows.
    pub hyperliquid_trades: usize,
}

impl PaperReplayDataCounts {
    /// Minimum non-empty dataset for a first real paper replay.
    #[must_use]
    pub const fn real_run_minimums() -> Self {
        Self {
            liquidations: 1,
            polymarket_quotes: 1,
            polymarket_trades: 1,
            hyperliquid_quotes: 1,
            hyperliquid_trades: 1,
        }
    }
}

/// Inputs for first-real-run replay preflight.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PaperReplayPreflightInput {
    /// Resolved Polymarket market window.
    pub market: BaselineMarket,
    /// Available stored rows for the replay window.
    pub data_counts: PaperReplayDataCounts,
    /// Required minimum stored rows for this preflight.
    pub minimum_counts: PaperReplayDataCounts,
    /// Requested Polymarket fill model.
    pub fill_model: FillModel,
    /// Fee and funding assumptions used by replay.
    pub fee_schedule: FeeSchedule,
    /// Hedge slippage penalty in USD.
    pub hedge_slippage_usd: Decimal,
    /// Funding duration charged per hedge fill.
    pub funding_hours: Decimal,
    /// Current wall-clock timestamp in milliseconds, when freshness should be checked.
    pub now_unix_ms: Option<i64>,
    /// Maximum allowed market age after `end_unix_ms`, in milliseconds.
    pub market_stale_after_ms: Option<i64>,
    /// Require conservative `trade_cross` fills.
    pub require_trade_cross: bool,
    /// Require at least one non-zero fee/funding/slippage assumption.
    pub require_nonzero_cost_assumptions: bool,
}

/// Fail-closed preflight report for one real paper replay attempt.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaperReplayPreflightReport {
    /// Whether the replay input is good enough for a first real paper replay.
    pub ready_for_replay: bool,
    /// Resolved market.
    pub market: BaselineMarket,
    /// Available stored rows.
    pub data_counts: PaperReplayDataCounts,
    /// Passing capabilities.
    pub capabilities: Vec<ReadinessItem>,
    /// Blocking issues.
    pub blockers: Vec<ReadinessItem>,
    /// Machine-readable condition details.
    pub conditions: Vec<ReadinessCondition>,
}

/// Check whether a replay window is good enough to run as a real paper replay.
#[must_use]
pub fn paper_replay_preflight(input: &PaperReplayPreflightInput) -> PaperReplayPreflightReport {
    let mut capabilities = Vec::new();
    let mut blockers = Vec::new();
    let mut conditions = Vec::new();

    push_market_window_conditions(input, &mut capabilities, &mut blockers, &mut conditions);
    push_replay_count_conditions(input, &mut capabilities, &mut blockers, &mut conditions);
    push_replay_policy_conditions(input, &mut capabilities, &mut blockers, &mut conditions);

    PaperReplayPreflightReport {
        ready_for_replay: blockers.is_empty(),
        market: input.market.clone(),
        data_counts: input.data_counts,
        capabilities,
        blockers,
        conditions,
    }
}

fn push_market_window_conditions(
    input: &PaperReplayPreflightInput,
    capabilities: &mut Vec<ReadinessItem>,
    blockers: &mut Vec<ReadinessItem>,
    conditions: &mut Vec<ReadinessCondition>,
) {
    let duration_ms = input.market.end_unix_ms - input.market.start_unix_ms;
    push_condition(
        capabilities,
        blockers,
        conditions,
        "market_window",
        "end_unix_ms - start_unix_ms == 300000",
        format!(
            "start={} end={} duration_ms={duration_ms}",
            input.market.start_unix_ms, input.market.end_unix_ms
        ),
        input.market.end_unix_ms > input.market.start_unix_ms && duration_ms == 300_000,
    );

    if let (Some(now_unix_ms), Some(stale_after_ms)) =
        (input.now_unix_ms, input.market_stale_after_ms)
    {
        let market_closed = now_unix_ms >= input.market.end_unix_ms;
        push_condition(
            capabilities,
            blockers,
            conditions,
            "market_closed",
            "now_unix_ms >= end_unix_ms",
            format!("now={now_unix_ms} end={}", input.market.end_unix_ms),
            market_closed,
        );

        let age_ms = now_unix_ms - input.market.end_unix_ms;
        push_condition(
            capabilities,
            blockers,
            conditions,
            "market_freshness",
            format!("market age <= {stale_after_ms} ms"),
            format!("age_ms={age_ms}"),
            market_closed && age_ms <= stale_after_ms,
        );
    }
}

fn push_replay_count_conditions(
    input: &PaperReplayPreflightInput,
    capabilities: &mut Vec<ReadinessItem>,
    blockers: &mut Vec<ReadinessItem>,
    conditions: &mut Vec<ReadinessCondition>,
) {
    push_count_condition(
        capabilities,
        blockers,
        conditions,
        "liquidations",
        input.data_counts.liquidations,
        input.minimum_counts.liquidations,
    );
    push_count_condition(
        capabilities,
        blockers,
        conditions,
        "polymarket_quotes",
        input.data_counts.polymarket_quotes,
        input.minimum_counts.polymarket_quotes,
    );
    push_count_condition(
        capabilities,
        blockers,
        conditions,
        "polymarket_trades",
        input.data_counts.polymarket_trades,
        input.minimum_counts.polymarket_trades,
    );
    push_count_condition(
        capabilities,
        blockers,
        conditions,
        "hyperliquid_quotes",
        input.data_counts.hyperliquid_quotes,
        input.minimum_counts.hyperliquid_quotes,
    );
    push_count_condition(
        capabilities,
        blockers,
        conditions,
        "hyperliquid_trades",
        input.data_counts.hyperliquid_trades,
        input.minimum_counts.hyperliquid_trades,
    );
}

fn push_replay_policy_conditions(
    input: &PaperReplayPreflightInput,
    capabilities: &mut Vec<ReadinessItem>,
    blockers: &mut Vec<ReadinessItem>,
    conditions: &mut Vec<ReadinessCondition>,
) {
    if input.require_trade_cross {
        push_condition(
            capabilities,
            blockers,
            conditions,
            "fill_model",
            "fill_model == trade_cross",
            format!("{:?}", input.fill_model),
            input.fill_model == FillModel::TradeCross,
        );
    }

    if input.require_nonzero_cost_assumptions {
        let has_cost = input.fee_schedule.polymarket_maker_bps > Decimal::ZERO
            || input.fee_schedule.polymarket_taker_bps > Decimal::ZERO
            || input.fee_schedule.hyperliquid_maker_bps > Decimal::ZERO
            || input.fee_schedule.hyperliquid_taker_bps > Decimal::ZERO
            || input.fee_schedule.hyperliquid_funding_bps_per_hour > Decimal::ZERO
            || input.hedge_slippage_usd > Decimal::ZERO;
        push_condition(
            capabilities,
            blockers,
            conditions,
            "cost_assumptions",
            "at least one fee/funding/slippage assumption is non-zero",
            format!(
                "pm_maker_bps={} pm_taker_bps={} hl_maker_bps={} hl_taker_bps={} hl_funding_bps_per_hour={} hedge_slippage_usd={}",
                input.fee_schedule.polymarket_maker_bps,
                input.fee_schedule.polymarket_taker_bps,
                input.fee_schedule.hyperliquid_maker_bps,
                input.fee_schedule.hyperliquid_taker_bps,
                input.fee_schedule.hyperliquid_funding_bps_per_hour,
                input.hedge_slippage_usd
            ),
            has_cost,
        );
    }

    if input.fee_schedule.hyperliquid_funding_bps_per_hour > Decimal::ZERO {
        push_condition(
            capabilities,
            blockers,
            conditions,
            "funding_duration",
            "funding_hours > 0 when Hyperliquid funding is non-zero",
            format!("funding_hours={}", input.funding_hours),
            input.funding_hours > Decimal::ZERO,
        );
    }
}

fn push_count_condition(
    capabilities: &mut Vec<ReadinessItem>,
    blockers: &mut Vec<ReadinessItem>,
    conditions: &mut Vec<ReadinessCondition>,
    id: &str,
    observed: usize,
    required: usize,
) {
    push_condition(
        capabilities,
        blockers,
        conditions,
        id,
        format!("{id} >= {required}"),
        observed.to_string(),
        observed >= required,
    );
}

fn push_condition(
    capabilities: &mut Vec<ReadinessItem>,
    blockers: &mut Vec<ReadinessItem>,
    conditions: &mut Vec<ReadinessCondition>,
    id: &str,
    required: impl Into<String>,
    observed: impl Into<String>,
    passed: bool,
) {
    let required = required.into();
    let observed = observed.into();
    conditions.push(ReadinessCondition {
        id: id.to_owned(),
        required: required.clone(),
        observed: observed.clone(),
        passed,
    });
    let note = format!("required='{required}' observed='{observed}'");
    if passed {
        capabilities.push(ready(id, &note));
    } else {
        blockers.push(blocked(id, &note));
    }
}

/// Prediction-market settlement coverage in a replay report.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PaperSettlementStatus {
    /// Outcome settlement is not included in this replay.
    Unsettled,
}

/// One paper trade diagnostic.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PaperReplayTrade {
    /// Strategy signal.
    pub signal: StrategySignal,
    /// Prediction-market outcome.
    pub outcome: Option<PredictionOutcome>,
    /// Polymarket fill decision.
    pub polymarket_fill: FillDecision,
    /// Hyperliquid hedge fill decision, when a hedge was attempted.
    pub hedge_fill: Option<FillDecision>,
    /// Fees charged to this trade.
    pub fee_usd: Decimal,
    /// Funding charged to this trade.
    pub funding_usd: Decimal,
    /// Slippage charged to this trade.
    pub slippage_usd: Decimal,
    /// Net `PnL` contribution after costs.
    pub net_pnl_usd: Decimal,
    /// Whether the filled Polymarket leg has no filled hedge.
    pub unhedged: bool,
}

/// Paper replay execution error.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum PaperReplayError {
    /// Live trading is not allowed by the paper replay runner.
    #[error(transparent)]
    SafetyGate(#[from] SafetyGateError),
}

/// Run one deterministic baseline paper replay.
///
/// # Errors
///
/// Returns an error when the paper-only safety gate rejects execution.
pub fn run_paper_replay(input: &PaperReplayInput) -> Result<PaperReplayReport, PaperReplayError> {
    PaperOnlyGate::paper_only().ensure_allowed(TradingMode::Paper)?;

    let mut strategy = BaselineStinkBidStrategy::new(BaselineStrategyConfig::default());
    let strategy_version = strategy.version().to_owned();
    let _ = strategy.on_event(&BaselineEvent::MarketOpened(input.market.clone()));

    let mut events = baseline_replay_events(input);
    events.sort_by_key(BaselineReplayEvent::sort_key);

    let mut trades = Vec::new();
    for event in events {
        let signals = match event {
            BaselineReplayEvent::Quote(quote) => {
                strategy.on_event(&BaselineEvent::PolymarketQuote(quote))
            }
            BaselineReplayEvent::Liquidation(liquidation) => {
                strategy.on_event(&BaselineEvent::Liquidation(liquidation.clone()))
            }
        };

        trades.extend(
            signals
                .into_iter()
                .map(|signal| evaluate_paper_signal(input, signal)),
        );
    }

    Ok(build_paper_replay_report(
        input,
        strategy_version,
        input.fill_model.version().to_owned(),
        input.fee_schedule.version.clone(),
        trades,
    ))
}

#[derive(Debug, Clone)]
enum BaselineReplayEvent<'a> {
    Quote(MarketQuote),
    Liquidation(&'a LiquidationEvent),
}

impl BaselineReplayEvent<'_> {
    fn sort_key(&self) -> (i64, u8) {
        match self {
            Self::Quote(quote) => (market_quote_ts_ms(quote), 0),
            Self::Liquidation(event) => (event_ts_ms(event), 1),
        }
    }
}

fn baseline_replay_events(input: &PaperReplayInput) -> Vec<BaselineReplayEvent<'_>> {
    let mut events = Vec::with_capacity(input.polymarket_quotes.len() + input.liquidations.len());
    events.extend(
        input
            .polymarket_quotes
            .iter()
            .cloned()
            .map(BaselineReplayEvent::Quote),
    );
    events.extend(
        input
            .liquidations
            .iter()
            .map(BaselineReplayEvent::Liquidation),
    );
    events
}

fn evaluate_paper_signal(input: &PaperReplayInput, signal: StrategySignal) -> PaperReplayTrade {
    let polymarket_order = PaperOrder {
        order_id: format!("{}:polymarket", signal.signal_id),
        side: signal.side,
        limit_price: signal.limit_price,
        quantity: signal.quantity,
        created_unix_ms: signal.created_unix_ms,
        expires_unix_ms: signal.expires_unix_ms,
    };
    let polymarket_trades =
        observed_trades_for_instrument(&input.polymarket_trades, &signal.symbol);
    let polymarket_books = observed_books_for_instrument(&input.polymarket_quotes, &signal.symbol);
    let polymarket_fill = evaluate_fill(
        &polymarket_order,
        input.fill_model,
        &polymarket_trades,
        &polymarket_books,
    );

    let polymarket_cost = if let FillDecision::Filled {
        price, quantity, ..
    } = &polymarket_fill
    {
        calculate_execution_cost(
            &input.fee_schedule,
            &ExecutionCostInput {
                venue: FeeVenue::Polymarket,
                role: LiquidityRole::Maker,
                notional_usd: *price * *quantity,
                slippage_usd: Decimal::ZERO,
                funding_hours: Decimal::ZERO,
            },
        )
    } else {
        zero_execution_cost()
    };

    let hedge_fill = if matches!(polymarket_fill, FillDecision::Filled { .. }) {
        Some(evaluate_hedge_fill(input, &signal))
    } else {
        None
    };
    let hedge_cost = if matches!(hedge_fill, Some(FillDecision::Filled { .. })) {
        calculate_execution_cost(
            &input.fee_schedule,
            &ExecutionCostInput {
                venue: FeeVenue::Hyperliquid,
                role: LiquidityRole::Taker,
                notional_usd: input.hedge_notional_usd,
                slippage_usd: input.hedge_slippage_usd,
                funding_hours: input.funding_hours,
            },
        )
    } else {
        zero_execution_cost()
    };

    let fee_usd = polymarket_cost.fee_usd + hedge_cost.fee_usd;
    let funding_usd = polymarket_cost.funding_usd + hedge_cost.funding_usd;
    let slippage_usd = polymarket_cost.slippage_usd + hedge_cost.slippage_usd;
    let net_pnl_usd = -(fee_usd + funding_usd + slippage_usd);
    let unhedged = matches!(polymarket_fill, FillDecision::Filled { .. })
        && !matches!(hedge_fill, Some(FillDecision::Filled { .. }));

    PaperReplayTrade {
        outcome: signal.outcome,
        signal,
        polymarket_fill,
        hedge_fill,
        fee_usd,
        funding_usd,
        slippage_usd,
        net_pnl_usd,
        unhedged,
    }
}

fn evaluate_hedge_fill(input: &PaperReplayInput, signal: &StrategySignal) -> FillDecision {
    let Some(trade) = input
        .hyperliquid_trades
        .iter()
        .filter(|trade| is_btc_hedge_trade(trade))
        .filter(|trade| market_trade_ts_ms(trade) >= signal.created_unix_ms)
        .filter(|trade| market_trade_ts_ms(trade) < signal.expires_unix_ms)
        .min_by_key(|trade| market_trade_ts_ms(trade))
    else {
        return FillDecision::NotFilled {
            reason: "no recorded Hyperliquid trade available inside hedge window".to_owned(),
        };
    };

    FillDecision::Filled {
        price: trade.price,
        quantity: trade.quantity,
        unix_ms: market_trade_ts_ms(trade),
        model_version: "hyperliquid_market_trade_v1".to_owned(),
    }
}

fn is_btc_hedge_trade(trade: &MarketTrade) -> bool {
    trade.instrument_id.eq_ignore_ascii_case("BTC")
        || trade.instrument_id.eq_ignore_ascii_case("BTC-PERP")
        || trade.symbol.eq_ignore_ascii_case("BTC")
        || trade.symbol.eq_ignore_ascii_case("BTC-PERP")
}

fn build_paper_replay_report(
    input: &PaperReplayInput,
    strategy_version: String,
    fill_model_version: String,
    fee_schedule_version: String,
    trades: Vec<PaperReplayTrade>,
) -> PaperReplayReport {
    let signal_count = usize_to_u64(trades.len());
    let polymarket_orders = signal_count;
    let polymarket_fills = usize_to_u64(
        trades
            .iter()
            .filter(|trade| matches!(trade.polymarket_fill, FillDecision::Filled { .. }))
            .count(),
    );
    let hedge_attempts = usize_to_u64(
        trades
            .iter()
            .filter(|trade| trade.hedge_fill.is_some())
            .count(),
    );
    let hedge_fills = usize_to_u64(
        trades
            .iter()
            .filter(|trade| matches!(trade.hedge_fill, Some(FillDecision::Filled { .. })))
            .count(),
    );
    let unhedged_signals = usize_to_u64(trades.iter().filter(|trade| trade.unhedged).count());
    let total_fees_usd = trades.iter().map(|trade| trade.fee_usd).sum();
    let total_funding_usd = trades.iter().map(|trade| trade.funding_usd).sum();
    let total_slippage_usd = trades.iter().map(|trade| trade.slippage_usd).sum();
    let gross_pnl_usd = Decimal::ZERO;
    let net_pnl_usd = gross_pnl_usd - total_fees_usd - total_funding_usd - total_slippage_usd;
    let max_drawdown_usd = max_drawdown(trades.iter().map(|trade| trade.net_pnl_usd));
    let signal_rejection_reasons = explain_signal_rejections(input, &trades);

    PaperReplayReport {
        strategy_version,
        fill_model_version,
        fee_schedule_version,
        signal_count,
        polymarket_orders,
        polymarket_fills,
        hedge_attempts,
        hedge_fills,
        unhedged_signals,
        gross_pnl_usd,
        total_fees_usd,
        total_funding_usd,
        total_slippage_usd,
        net_pnl_usd,
        max_drawdown_usd,
        settlement_status: PaperSettlementStatus::Unsettled,
        signal_rejection_reasons,
        trades,
    }
}

#[derive(Debug, Clone)]
struct RejectionAccumulator {
    stage: &'static str,
    label: &'static str,
    count: u64,
    detail: String,
}

const REJECTION_STAGE_SIGNAL_GATE: &str = "signal_gate";
const REJECTION_STAGE_ENTRY_FILL: &str = "entry_fill";
const REJECTION_STAGE_HEDGE_FILL: &str = "hedge_fill";
const REJECTION_STAGE_EXPIRY: &str = "expiry";

fn explain_signal_rejections(
    input: &PaperReplayInput,
    trades: &[PaperReplayTrade],
) -> Vec<SignalRejectionReason> {
    let mut reasons = BTreeMap::<&'static str, RejectionAccumulator>::new();
    explain_missing_strategy_signals(input, &mut reasons);
    explain_incomplete_trade_execution(trades, &mut reasons);

    let mut reasons = reasons
        .into_iter()
        .map(|(id, reason)| SignalRejectionReason {
            id: id.to_owned(),
            stage: reason.stage.to_owned(),
            label: reason.label.to_owned(),
            count: reason.count,
            detail: reason.detail,
        })
        .collect::<Vec<_>>();
    reasons.sort_by(|left, right| {
        rejection_stage_rank(&left.stage)
            .cmp(&rejection_stage_rank(&right.stage))
            .then_with(|| left.id.cmp(&right.id))
    });
    reasons
}

fn rejection_stage_rank(stage: &str) -> u8 {
    match stage {
        REJECTION_STAGE_SIGNAL_GATE => 0,
        REJECTION_STAGE_ENTRY_FILL => 1,
        REJECTION_STAGE_HEDGE_FILL => 2,
        REJECTION_STAGE_EXPIRY => 3,
        _ => 4,
    }
}

fn explain_missing_strategy_signals(
    input: &PaperReplayInput,
    reasons: &mut BTreeMap<&'static str, RejectionAccumulator>,
) {
    let config = BaselineStrategyConfig::default();
    let mut latest_polymarket_quotes = HashMap::<String, MarketQuote>::new();
    let mut liquidation_window = VecDeque::<LiquidationWindowItem>::new();
    let mut signal_fired = false;

    let mut events = baseline_replay_events(input);
    events.sort_by_key(BaselineReplayEvent::sort_key);

    for event in events {
        match event {
            BaselineReplayEvent::Quote(quote) => {
                track_polymarket_quote(&mut latest_polymarket_quotes, quote);
            }
            BaselineReplayEvent::Liquidation(liquidation) => {
                signal_fired = explain_liquidation_candidate(
                    input,
                    liquidation,
                    &config,
                    &mut liquidation_window,
                    &latest_polymarket_quotes,
                    signal_fired,
                    reasons,
                );
            }
        }
    }
}

fn track_polymarket_quote(
    latest_polymarket_quotes: &mut HashMap<String, MarketQuote>,
    quote: MarketQuote,
) {
    if quote.venue == MarketVenue::Polymarket {
        latest_polymarket_quotes.insert(quote.instrument_id.clone(), quote);
    }
}

fn explain_liquidation_candidate(
    input: &PaperReplayInput,
    liquidation: &LiquidationEvent,
    config: &BaselineStrategyConfig,
    liquidation_window: &mut VecDeque<LiquidationWindowItem>,
    latest_polymarket_quotes: &HashMap<String, MarketQuote>,
    signal_fired: bool,
    reasons: &mut BTreeMap<&'static str, RejectionAccumulator>,
) -> bool {
    if signal_fired {
        push_rejection(
            reasons,
            "signal_already_fired",
            REJECTION_STAGE_SIGNAL_GATE,
            "signal already fired for market",
            format!(
                "market_id={} event_ts_ms={}",
                input.market.market_id,
                event_ts_ms(liquidation)
            ),
        );
        return true;
    }
    if !is_btc_symbol(&liquidation.symbol) {
        push_rejection(
            reasons,
            "non_btc_liquidation",
            REJECTION_STAGE_SIGNAL_GATE,
            "non-BTC liquidation ignored",
            format!("symbol={}", liquidation.symbol),
        );
        return false;
    }

    let event_unix_ms = event_ts_ms(liquidation);
    liquidation_window.push_back(LiquidationWindowItem {
        unix_ms: event_unix_ms,
        side: liquidation.side,
        notional_usd: liquidation.notional_usd,
    });
    prune_liquidation_window(
        liquidation_window,
        event_unix_ms,
        config.liquidation_window_ms,
    );

    if input.market.end_unix_ms - event_unix_ms <= config.order_cancel_window_ms {
        push_rejection(
            reasons,
            "order_cancel_window",
            REJECTION_STAGE_EXPIRY,
            "too close to market expiry",
            format!(
                "event_ts_ms={} market_end_ms={} cancel_window_ms={}",
                event_unix_ms, input.market.end_unix_ms, config.order_cancel_window_ms
            ),
        );
        return false;
    }

    let long_total = window_notional_for_side(liquidation_window, LiquidationSide::Long);
    let short_total = window_notional_for_side(liquidation_window, LiquidationSide::Short);
    let Some((token_id, dominant_notional)) =
        explain_select_signal_token(config, long_total, short_total, &input.market)
    else {
        push_liquidation_band_rejection(config, long_total, short_total, reasons);
        return false;
    };

    if let Some(best_ask) = explain_target_quote(
        token_id,
        dominant_notional,
        latest_polymarket_quotes,
        reasons,
    ) {
        return can_build_polymarket_order(config, best_ask, reasons);
    }
    false
}

fn explain_target_quote(
    token_id: &str,
    dominant_notional: Decimal,
    latest_polymarket_quotes: &HashMap<String, MarketQuote>,
    reasons: &mut BTreeMap<&'static str, RejectionAccumulator>,
) -> Option<Decimal> {
    let Some(quote) = latest_polymarket_quotes.get(token_id) else {
        push_rejection(
            reasons,
            "missing_polymarket_quote",
            REJECTION_STAGE_ENTRY_FILL,
            "missing Polymarket quote for target token",
            format!("token_id={token_id} dominant_notional_usd={dominant_notional}"),
        );
        return None;
    };
    let Some(best_ask) = quote.best_ask else {
        push_rejection(
            reasons,
            "missing_polymarket_best_ask",
            REJECTION_STAGE_ENTRY_FILL,
            "missing Polymarket best ask",
            format!("token_id={token_id} dominant_notional_usd={dominant_notional}"),
        );
        return None;
    };
    Some(best_ask)
}

fn can_build_polymarket_order(
    config: &BaselineStrategyConfig,
    best_ask: Decimal,
    reasons: &mut BTreeMap<&'static str, RejectionAccumulator>,
) -> bool {
    let limit_price = (best_ask * (Decimal::ONE - config.pullback_pct)).round_dp(4);
    if calculate_polymarket_shares(
        config.polymarket_usd_per_position,
        limit_price.max(config.min_polymarket_price),
    )
    .is_some()
    {
        return true;
    }
    push_rejection(
        reasons,
        "invalid_polymarket_pullback_price",
        REJECTION_STAGE_ENTRY_FILL,
        "invalid Polymarket pullback price",
        format!("best_ask={best_ask} limit_price={limit_price}"),
    );
    false
}

fn explain_incomplete_trade_execution(
    trades: &[PaperReplayTrade],
    reasons: &mut BTreeMap<&'static str, RejectionAccumulator>,
) {
    for trade in trades {
        if let FillDecision::NotFilled { reason } = &trade.polymarket_fill {
            push_rejection(
                reasons,
                "polymarket_entry_not_filled",
                REJECTION_STAGE_ENTRY_FILL,
                "Polymarket entry not filled",
                reason.clone(),
            );
        }
        if let Some(FillDecision::NotFilled { reason }) = &trade.hedge_fill {
            push_rejection(
                reasons,
                "hyperliquid_hedge_not_filled",
                REJECTION_STAGE_HEDGE_FILL,
                "Hyperliquid hedge not filled",
                reason.clone(),
            );
        }
    }
}

fn explain_select_signal_token<'a>(
    config: &BaselineStrategyConfig,
    long_total: Decimal,
    short_total: Decimal,
    market: &'a BaselineMarket,
) -> Option<(&'a str, Decimal)> {
    if within_signal_band(
        long_total,
        config.liquidation_threshold_min_usd,
        config.liquidation_threshold_max_usd,
    ) && long_total > short_total
    {
        return Some((&market.down_token_id, long_total));
    }
    if within_signal_band(
        short_total,
        config.liquidation_threshold_min_usd,
        config.liquidation_threshold_max_usd,
    ) && short_total > long_total
    {
        return Some((&market.up_token_id, short_total));
    }
    None
}

fn push_liquidation_band_rejection(
    config: &BaselineStrategyConfig,
    long_total: Decimal,
    short_total: Decimal,
    reasons: &mut BTreeMap<&'static str, RejectionAccumulator>,
) {
    let dominant_notional = long_total.max(short_total);
    let reason_id = if dominant_notional < config.liquidation_threshold_min_usd {
        "liquidation_notional_below_threshold"
    } else if dominant_notional > config.liquidation_threshold_max_usd {
        "liquidation_notional_above_threshold"
    } else {
        "no_dominant_liquidation_side"
    };
    let label = match reason_id {
        "liquidation_notional_below_threshold" => "liquidation notional below threshold",
        "liquidation_notional_above_threshold" => "liquidation notional above threshold",
        _ => "no dominant liquidation side",
    };
    push_rejection(
        reasons,
        reason_id,
        REJECTION_STAGE_SIGNAL_GATE,
        label,
        format!(
            "long_total={} short_total={} dominant_notional_usd={} min={} max={}",
            long_total,
            short_total,
            dominant_notional,
            config.liquidation_threshold_min_usd,
            config.liquidation_threshold_max_usd
        ),
    );
}

fn prune_liquidation_window(
    liquidation_window: &mut VecDeque<LiquidationWindowItem>,
    now_unix_ms: i64,
    window_ms: i64,
) {
    let cutoff = now_unix_ms - window_ms;
    while liquidation_window
        .front()
        .is_some_and(|item| item.unix_ms < cutoff)
    {
        liquidation_window.pop_front();
    }
}

fn window_notional_for_side(
    liquidation_window: &VecDeque<LiquidationWindowItem>,
    side: LiquidationSide,
) -> Decimal {
    liquidation_window
        .iter()
        .filter(|item| item.side == side)
        .map(|item| item.notional_usd)
        .sum()
}

fn push_rejection(
    reasons: &mut BTreeMap<&'static str, RejectionAccumulator>,
    id: &'static str,
    stage: &'static str,
    label: &'static str,
    detail: String,
) {
    reasons
        .entry(id)
        .and_modify(|reason| {
            reason.count = reason.count.saturating_add(1);
            reason.detail.clone_from(&detail);
        })
        .or_insert_with(|| RejectionAccumulator {
            stage,
            label,
            count: 1,
            detail,
        });
}

fn observed_trades_for_instrument(
    trades: &[MarketTrade],
    instrument_id: &str,
) -> Vec<ObservedTrade> {
    trades
        .iter()
        .filter(|trade| trade.instrument_id == instrument_id)
        .map(|trade| ObservedTrade {
            unix_ms: market_trade_ts_ms(trade),
            price: trade.price,
            quantity: trade.quantity,
        })
        .collect()
}

fn observed_books_for_instrument(quotes: &[MarketQuote], instrument_id: &str) -> Vec<ObservedBook> {
    quotes
        .iter()
        .filter(|quote| quote.instrument_id == instrument_id)
        .map(|quote| ObservedBook {
            unix_ms: market_quote_ts_ms(quote),
            best_bid: quote.best_bid,
            best_ask: quote.best_ask,
        })
        .collect()
}

fn zero_execution_cost() -> ExecutionCost {
    ExecutionCost {
        fee_usd: Decimal::ZERO,
        funding_usd: Decimal::ZERO,
        slippage_usd: Decimal::ZERO,
        total_usd: Decimal::ZERO,
    }
}

fn max_drawdown(changes: impl IntoIterator<Item = Decimal>) -> Decimal {
    let mut equity = Decimal::ZERO;
    let mut peak = Decimal::ZERO;
    let mut drawdown = Decimal::ZERO;
    for change in changes {
        equity += change;
        peak = peak.max(equity);
        drawdown = drawdown.max(peak - equity);
    }
    drawdown
}

fn usize_to_u64(value: usize) -> u64 {
    u64::try_from(value).unwrap_or(u64::MAX)
}

fn market_quote_ts_ms(quote: &MarketQuote) -> i64 {
    timestamp_ms(quote.received_ts.unix_timestamp_nanos())
}

fn market_trade_ts_ms(trade: &MarketTrade) -> i64 {
    timestamp_ms(trade.received_ts.unix_timestamp_nanos())
}

fn timestamp_ms(nanos: i128) -> i64 {
    let millis = nanos / 1_000_000;
    match i64::try_from(millis) {
        Ok(value) => value,
        Err(_) if millis.is_negative() => i64::MIN,
        Err(_) => i64::MAX,
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

    #[test]
    fn paper_replay_runs_baseline_and_reports_net_pnl_and_risk() {
        let market = baseline_market();
        let input = PaperReplayInput {
            market: market.clone(),
            liquidations: vec![liquidation(
                LiquidationSide::Long,
                Decimal::new(25_000, 0),
                1_500,
            )],
            polymarket_quotes: vec![polymarket_quote(
                &market.down_token_id,
                Decimal::new(50, 2),
                1_000,
            )],
            polymarket_trades: vec![market_trade(
                MarketVenue::Polymarket,
                &market.down_token_id,
                Decimal::new(35, 2),
                Decimal::new(429, 1),
                1_600,
            )],
            hyperliquid_quotes: vec![market_quote(
                MarketVenue::Hyperliquid,
                "BTC-PERP",
                Decimal::new(65_100, 0),
                1_400,
            )],
            hyperliquid_trades: vec![market_trade(
                MarketVenue::Hyperliquid,
                "BTC-PERP",
                Decimal::new(65_120, 0),
                Decimal::new(1, 4),
                1_700,
            )],
            fill_model: FillModel::TradeCross,
            fee_schedule: FeeSchedule {
                hyperliquid_taker_bps: Decimal::new(5, 0),
                hyperliquid_funding_bps_per_hour: Decimal::new(1, 0),
                ..FeeSchedule::paper_v1()
            },
            hedge_notional_usd: Decimal::new(15, 0),
            hedge_slippage_usd: Decimal::new(10, 2),
            funding_hours: Decimal::new(1, 0),
        };

        let report = run_paper_replay(&input).expect("paper replay must run");

        assert_eq!(report.strategy_version, "baseline_stink_bid_v1");
        assert_eq!(report.signal_count, 1);
        assert_eq!(report.polymarket_orders, 1);
        assert_eq!(report.polymarket_fills, 1);
        assert_eq!(report.hedge_attempts, 1);
        assert_eq!(report.hedge_fills, 1);
        assert_eq!(report.unhedged_signals, 0);
        assert_eq!(report.gross_pnl_usd, Decimal::ZERO);
        assert_eq!(report.total_fees_usd, Decimal::new(75, 4));
        assert_eq!(report.total_funding_usd, Decimal::new(15, 4));
        assert_eq!(report.total_slippage_usd, Decimal::new(10, 2));
        assert_eq!(report.net_pnl_usd, Decimal::new(-1090, 4));
        assert_eq!(report.max_drawdown_usd, Decimal::new(1090, 4));
        assert_eq!(report.settlement_status, PaperSettlementStatus::Unsettled);
        assert_eq!(report.trades.len(), 1);
        assert_eq!(report.trades[0].outcome, Some(PredictionOutcome::Down));
        assert!(matches!(
            report.trades[0].polymarket_fill,
            FillDecision::Filled { .. }
        ));
    }

    #[test]
    fn paper_replay_explains_zero_signal_when_liquidations_are_below_threshold() {
        let market = baseline_market();
        let input = PaperReplayInput {
            market: market.clone(),
            liquidations: vec![liquidation(
                LiquidationSide::Long,
                Decimal::new(4_615, 0),
                1_500,
            )],
            polymarket_quotes: vec![polymarket_quote(
                &market.down_token_id,
                Decimal::new(50, 2),
                1_000,
            )],
            polymarket_trades: vec![market_trade(
                MarketVenue::Polymarket,
                &market.down_token_id,
                Decimal::new(35, 2),
                Decimal::new(429, 1),
                1_600,
            )],
            hyperliquid_quotes: vec![market_quote(
                MarketVenue::Hyperliquid,
                "BTC-PERP",
                Decimal::new(65_100, 0),
                1_400,
            )],
            hyperliquid_trades: vec![market_trade(
                MarketVenue::Hyperliquid,
                "BTC-PERP",
                Decimal::new(65_120, 0),
                Decimal::new(1, 4),
                1_700,
            )],
            fill_model: FillModel::TradeCross,
            fee_schedule: FeeSchedule::paper_v1(),
            hedge_notional_usd: Decimal::new(15, 0),
            hedge_slippage_usd: Decimal::ZERO,
            funding_hours: Decimal::ZERO,
        };

        let report = run_paper_replay(&input).expect("paper replay must run");

        assert_eq!(report.signal_count, 0);
        assert!(report.signal_rejection_reasons.iter().any(|reason| {
            reason.id == "liquidation_notional_below_threshold"
                && reason.stage == "signal_gate"
                && reason.count == 1
                && reason.detail.contains("min=25000")
        }));
    }

    #[test]
    fn paper_replay_preflight_blocks_empty_or_stale_real_run_inputs() {
        let report = paper_replay_preflight(&PaperReplayPreflightInput {
            market: baseline_market(),
            data_counts: PaperReplayDataCounts {
                liquidations: 0,
                polymarket_quotes: 1,
                polymarket_trades: 1,
                hyperliquid_quotes: 1,
                hyperliquid_trades: 1,
            },
            minimum_counts: PaperReplayDataCounts::real_run_minimums(),
            fill_model: FillModel::TradeCross,
            fee_schedule: FeeSchedule {
                hyperliquid_taker_bps: Decimal::new(5, 0),
                hyperliquid_funding_bps_per_hour: Decimal::new(1, 0),
                ..FeeSchedule::paper_v1()
            },
            hedge_slippage_usd: Decimal::new(10, 2),
            funding_hours: Decimal::new(1, 0),
            now_unix_ms: Some(20 * 60 * 1_000),
            market_stale_after_ms: Some(5 * 60 * 1_000),
            require_trade_cross: true,
            require_nonzero_cost_assumptions: true,
        });

        assert!(!report.ready_for_replay);
        assert!(report.blockers.iter().any(|item| item.id == "liquidations"));
        assert!(
            report
                .blockers
                .iter()
                .any(|item| item.id == "market_freshness")
        );
    }

    #[test]
    fn paper_replay_preflight_accepts_complete_real_run_inputs() {
        let report = paper_replay_preflight(&PaperReplayPreflightInput {
            market: baseline_market(),
            data_counts: PaperReplayDataCounts {
                liquidations: 2,
                polymarket_quotes: 3,
                polymarket_trades: 4,
                hyperliquid_quotes: 5,
                hyperliquid_trades: 6,
            },
            minimum_counts: PaperReplayDataCounts::real_run_minimums(),
            fill_model: FillModel::TradeCross,
            fee_schedule: FeeSchedule {
                hyperliquid_taker_bps: Decimal::new(5, 0),
                hyperliquid_funding_bps_per_hour: Decimal::new(1, 0),
                ..FeeSchedule::paper_v1()
            },
            hedge_slippage_usd: Decimal::new(10, 2),
            funding_hours: Decimal::new(1, 0),
            now_unix_ms: Some(6 * 60 * 1_000),
            market_stale_after_ms: Some(5 * 60 * 1_000),
            require_trade_cross: true,
            require_nonzero_cost_assumptions: true,
        });

        assert!(report.ready_for_replay);
        assert_eq!(report.blockers, Vec::new());
        assert_eq!(report.data_counts.polymarket_trades, 4);
    }

    #[test]
    fn paper_replay_preflight_blocks_unclosed_market_window() {
        let report = paper_replay_preflight(&PaperReplayPreflightInput {
            market: baseline_market(),
            data_counts: PaperReplayDataCounts {
                liquidations: 2,
                polymarket_quotes: 3,
                polymarket_trades: 4,
                hyperliquid_quotes: 5,
                hyperliquid_trades: 6,
            },
            minimum_counts: PaperReplayDataCounts::real_run_minimums(),
            fill_model: FillModel::TradeCross,
            fee_schedule: FeeSchedule {
                hyperliquid_taker_bps: Decimal::new(5, 0),
                hyperliquid_funding_bps_per_hour: Decimal::new(1, 0),
                ..FeeSchedule::paper_v1()
            },
            hedge_slippage_usd: Decimal::new(10, 2),
            funding_hours: Decimal::new(1, 0),
            now_unix_ms: Some(2 * 60 * 1_000),
            market_stale_after_ms: Some(5 * 60 * 1_000),
            require_trade_cross: true,
            require_nonzero_cost_assumptions: true,
        });

        assert!(!report.ready_for_replay);
        assert!(
            report
                .blockers
                .iter()
                .any(|item| item.id == "market_closed")
        );
        assert!(
            report
                .blockers
                .iter()
                .any(|item| item.id == "market_freshness")
        );
    }

    #[test]
    fn paper_replay_does_not_fill_hedge_with_non_btc_trade() {
        let market = baseline_market();
        let mut non_btc_trade = market_trade(
            MarketVenue::Hyperliquid,
            "ETH-PERP",
            Decimal::new(3_500, 0),
            Decimal::new(1, 2),
            1_700,
        );
        non_btc_trade.symbol = "ETH-PERP".to_owned();
        let input = PaperReplayInput {
            market: market.clone(),
            liquidations: vec![liquidation(
                LiquidationSide::Long,
                Decimal::new(25_000, 0),
                1_500,
            )],
            polymarket_quotes: vec![polymarket_quote(
                &market.down_token_id,
                Decimal::new(50, 2),
                1_000,
            )],
            polymarket_trades: vec![market_trade(
                MarketVenue::Polymarket,
                &market.down_token_id,
                Decimal::new(35, 2),
                Decimal::new(429, 1),
                1_600,
            )],
            hyperliquid_quotes: vec![market_quote(
                MarketVenue::Hyperliquid,
                "BTC-PERP",
                Decimal::new(65_100, 0),
                1_400,
            )],
            hyperliquid_trades: vec![non_btc_trade],
            fill_model: FillModel::TradeCross,
            fee_schedule: FeeSchedule::paper_v1(),
            hedge_notional_usd: Decimal::new(15, 0),
            hedge_slippage_usd: Decimal::new(10, 2),
            funding_hours: Decimal::new(1, 0),
        };

        let report = run_paper_replay(&input).expect("paper replay must run");

        assert_eq!(report.hedge_attempts, 1);
        assert_eq!(report.hedge_fills, 0);
        assert_eq!(report.unhedged_signals, 1);
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
        market_quote(MarketVenue::Polymarket, token_id, best_ask, unix_ms)
    }

    fn market_quote(
        venue: MarketVenue,
        instrument_id: &str,
        best_ask: Decimal,
        unix_ms: i64,
    ) -> liq_domain::MarketQuote {
        liq_domain::MarketQuote {
            event_id: uuid::Uuid::nil(),
            venue,
            source_event_id: format!("quote:{instrument_id}:{unix_ms}"),
            instrument_id: instrument_id.to_owned(),
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

    fn market_trade(
        venue: MarketVenue,
        instrument_id: &str,
        price: Decimal,
        quantity: Decimal,
        unix_ms: i64,
    ) -> liq_domain::MarketTrade {
        liq_domain::MarketTrade {
            event_id: uuid::Uuid::nil(),
            venue,
            source_event_id: format!("trade:{instrument_id}:{unix_ms}"),
            instrument_id: instrument_id.to_owned(),
            symbol: "BTC".to_owned(),
            side: liq_domain::TradeSide::Buy,
            price,
            quantity,
            notional_usd: Some(price * quantity),
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
