use anyhow::{Context, anyhow};
use liq_recorder::records::PolymarketMarketRecord;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use time::{Duration, OffsetDateTime, format_description::well_known::Rfc3339};

const DEFAULT_MATCH_TERMS: &[&str] = &["bitcoin", "up or down"];
const DEFAULT_SOURCE: &str = "gamma-api";

#[derive(Debug, Clone)]
pub struct PolymarketMarketFetchFilter {
    pub base_asset: String,
    pub market_type: String,
    pub match_terms: Vec<String>,
    pub window_seconds: i64,
    pub latest_only: bool,
}

impl Default for PolymarketMarketFetchFilter {
    fn default() -> Self {
        Self {
            base_asset: "BTC".to_owned(),
            market_type: "btc_5m".to_owned(),
            match_terms: DEFAULT_MATCH_TERMS
                .iter()
                .map(|term| (*term).to_owned())
                .collect(),
            window_seconds: 300,
            latest_only: true,
        }
    }
}

#[derive(Debug, Clone)]
pub struct PolymarketMarketFetchRequest {
    pub endpoint_url: String,
    pub page_limit: u16,
    pub max_pages: u16,
    pub filter: PolymarketMarketFetchFilter,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GammaMarket {
    id: String,
    question: String,
    slug: String,
    start_date: Option<String>,
    end_date: Option<String>,
    outcomes: Value,
    clob_token_ids: Value,
    active: Option<bool>,
    closed: Option<bool>,
    archived: Option<bool>,
    enable_order_book: Option<bool>,
    accepting_orders: Option<bool>,
    #[serde(flatten)]
    extra: Map<String, Value>,
}

pub fn parse_gamma_markets(payload: &str) -> anyhow::Result<Vec<GammaMarket>> {
    serde_json::from_str(payload).context("failed to parse Polymarket Gamma markets payload")
}

pub fn select_polymarket_markets(
    markets: &[GammaMarket],
    filter: &PolymarketMarketFetchFilter,
) -> anyhow::Result<Vec<PolymarketMarketRecord>> {
    let mut selected = markets
        .iter()
        .filter_map(|market| gamma_market_to_record(market, filter).transpose())
        .collect::<anyhow::Result<Vec<_>>>()?;
    selected.sort_by(|left, right| {
        right
            .start_ts
            .cmp(&left.start_ts)
            .then_with(|| right.end_ts.cmp(&left.end_ts))
            .then_with(|| left.market_id.cmp(&right.market_id))
    });
    if filter.latest_only {
        selected.truncate(1);
    }
    Ok(selected)
}

pub async fn fetch_polymarket_markets(
    request: &PolymarketMarketFetchRequest,
) -> anyhow::Result<Vec<PolymarketMarketRecord>> {
    let client = reqwest::Client::builder()
        .user_agent("LIQUIDATION-dev/0.1")
        .build()
        .context("failed to build Polymarket metadata HTTP client")?;
    let mut all = Vec::new();
    for page in 0..request.max_pages {
        let offset = u32::from(page) * u32::from(request.page_limit);
        let url = paged_url(&request.endpoint_url, request.page_limit, offset);
        let response = client
            .get(&url)
            .send()
            .await
            .with_context(|| format!("failed to fetch Polymarket metadata from {url}"))?
            .error_for_status()
            .with_context(|| format!("Polymarket metadata endpoint returned an error for {url}"))?;
        let payload = response
            .text()
            .await
            .context("failed to read Polymarket metadata response body")?;
        let batch = parse_gamma_markets(&payload)?;
        if batch.is_empty() {
            break;
        }
        all.extend(batch);
    }
    select_polymarket_markets(&all, &request.filter)
}

pub fn selected_markets_from_payload(
    payload: &str,
    filter: &PolymarketMarketFetchFilter,
) -> anyhow::Result<Vec<PolymarketMarketRecord>> {
    let markets = parse_gamma_markets(payload)?;
    select_polymarket_markets(&markets, filter)
}

fn gamma_market_to_record(
    market: &GammaMarket,
    filter: &PolymarketMarketFetchFilter,
) -> anyhow::Result<Option<PolymarketMarketRecord>> {
    let searchable = format!("{} {}", market.question, market.slug).to_lowercase();
    if !filter
        .match_terms
        .iter()
        .all(|term| searchable.contains(&term.to_lowercase()))
    {
        return Ok(None);
    }
    if market.archived.unwrap_or(false) {
        return Ok(None);
    }
    if market.enable_order_book == Some(false) {
        return Ok(None);
    }

    let start_ts = parse_required_time(market.start_date.as_deref(), "startDate")?;
    let end_ts = parse_required_time(market.end_date.as_deref(), "endDate")?;
    if end_ts - start_ts != Duration::seconds(filter.window_seconds) {
        return Ok(None);
    }

    let outcomes = string_array(&market.outcomes).context("invalid outcomes")?;
    let token_ids = string_array(&market.clob_token_ids).context("invalid clobTokenIds")?;
    if outcomes.len() != token_ids.len() {
        return Ok(None);
    }
    let Some(up_token_id) = token_for_outcome(&outcomes, &token_ids, "up") else {
        return Ok(None);
    };
    let Some(down_token_id) = token_for_outcome(&outcomes, &token_ids, "down") else {
        return Ok(None);
    };
    if up_token_id == down_token_id {
        return Ok(None);
    }

    let accepts_orders = market.accepting_orders.unwrap_or(false);
    let status = match (
        market.closed.unwrap_or(false),
        market.active.unwrap_or(false),
        accepts_orders,
    ) {
        (true, _, _) => "closed",
        (false, true, true) => "open",
        (false, true, false) => "active_not_accepting_orders",
        (false, false, _) => "inactive",
    };

    Ok(Some(PolymarketMarketRecord {
        market_id: market.id.clone(),
        slug: Some(market.slug.clone()),
        title: Some(market.question.clone()),
        base_asset: filter.base_asset.clone(),
        market_type: filter.market_type.clone(),
        up_token_id,
        down_token_id,
        start_ts,
        end_ts,
        status: status.to_owned(),
        source: DEFAULT_SOURCE.to_owned(),
        raw_payload: serde_json::to_value(market)
            .context("failed to convert Polymarket metadata to raw payload")?,
    }))
}

fn token_for_outcome(outcomes: &[String], token_ids: &[String], outcome: &str) -> Option<String> {
    outcomes
        .iter()
        .zip(token_ids.iter())
        .find_map(|(candidate, token_id)| {
            candidate
                .eq_ignore_ascii_case(outcome)
                .then(|| token_id.clone())
        })
}

fn parse_required_time(value: Option<&str>, field: &str) -> anyhow::Result<OffsetDateTime> {
    let value = value.with_context(|| format!("missing Polymarket {field}"))?;
    OffsetDateTime::parse(value, &Rfc3339)
        .with_context(|| format!("invalid Polymarket {field}: {value}"))
}

fn string_array(value: &Value) -> anyhow::Result<Vec<String>> {
    match value {
        Value::Array(items) => items
            .iter()
            .map(|item| {
                item.as_str()
                    .map(ToOwned::to_owned)
                    .ok_or_else(|| anyhow!("array item is not a string"))
            })
            .collect(),
        Value::String(encoded) => {
            serde_json::from_str(encoded).context("field is not a JSON string array")
        }
        _ => Err(anyhow!("field is neither an array nor a JSON string array")),
    }
}

fn paged_url(endpoint_url: &str, limit: u16, offset: u32) -> String {
    let separator = if endpoint_url.contains('?') { '&' } else { '?' };
    format!("{endpoint_url}{separator}limit={limit}&offset={offset}")
}

#[cfg(test)]
mod tests {
    use super::*;

    const BTC_5M_MARKET: &str = r#"
    [
      {
        "id": "btc-5m-fixture",
        "question": "Bitcoin Up or Down - June 23, 1:00PM-1:05PM ET",
        "slug": "bitcoin-up-or-down-june-23-1pm-et",
        "startDate": "2026-06-23T17:00:00Z",
        "endDate": "2026-06-23T17:05:00Z",
        "outcomes": "[\"Up\", \"Down\"]",
        "clobTokenIds": "[\"up-token\", \"down-token\"]",
        "active": true,
        "closed": false,
        "archived": false,
        "enableOrderBook": true,
        "acceptingOrders": true
      },
      {
        "id": "btc-15m-fixture",
        "question": "Bitcoin Up or Down - June 23, 1:00PM-1:15PM ET",
        "slug": "bitcoin-up-or-down-june-23-15m-et",
        "startDate": "2026-06-23T17:00:00Z",
        "endDate": "2026-06-23T17:15:00Z",
        "outcomes": "[\"Up\", \"Down\"]",
        "clobTokenIds": "[\"slow-up-token\", \"slow-down-token\"]",
        "active": true,
        "closed": false,
        "archived": false,
        "enableOrderBook": true,
        "acceptingOrders": true
      }
    ]
    "#;

    #[test]
    fn extracts_btc_five_minute_market_from_gamma_payload() {
        let markets = parse_gamma_markets(BTC_5M_MARKET).expect("payload should parse");
        let selected = select_polymarket_markets(&markets, &PolymarketMarketFetchFilter::default())
            .expect("filter should pass");

        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].market_id, "btc-5m-fixture");
        assert_eq!(selected[0].up_token_id, "up-token");
        assert_eq!(selected[0].down_token_id, "down-token");
        assert_eq!(selected[0].market_type, "btc_5m");
        assert_eq!(selected[0].source, "gamma-api");
    }

    #[test]
    fn rejects_incomplete_or_wrong_outcome_markets() {
        let payload = r#"
        [{
          "id": "bad-fixture",
          "question": "Bitcoin Up or Down - bad",
          "slug": "bitcoin-up-or-down-bad",
          "startDate": "2026-06-23T17:00:00Z",
          "endDate": "2026-06-23T17:05:00Z",
          "outcomes": "[\"Yes\", \"No\"]",
          "clobTokenIds": "[\"yes-token\", \"no-token\"]",
          "active": true,
          "closed": false,
          "archived": false,
          "enableOrderBook": true,
          "acceptingOrders": true
        }]
        "#;

        let markets = parse_gamma_markets(payload).expect("payload should parse");
        let selected = select_polymarket_markets(&markets, &PolymarketMarketFetchFilter::default())
            .expect("filter should pass");

        assert!(selected.is_empty());
    }
}
