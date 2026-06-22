//! Read-only collector dashboard server.

use std::{net::SocketAddr, path::PathBuf, sync::Arc};

use anyhow::{Context, anyhow};
use axum::{
    Json, Router,
    extract::{Query, State},
    http::StatusCode,
    response::{Html, IntoResponse, Response},
    routing::get,
};
use liq_recorder::{
    records::{CollectorDashboardHistory, CollectorDashboardMetrics, CollectorHistorySample},
    repository,
};
use serde::Deserialize;
use sqlx::{PgPool, postgres::PgPoolOptions};
use time::Duration;
use tokio::net::TcpListener;
use tracing::info;

const INDEX_HTML: &str = include_str!("../assets/dashboard/index.html");

/// Dashboard server arguments.
pub(crate) struct DashboardArgs {
    pub(crate) bind: String,
    pub(crate) database_url: Option<String>,
    pub(crate) window_minutes: i64,
    pub(crate) poll_seconds: u64,
    pub(crate) fixture_path: Option<PathBuf>,
}

#[derive(Clone)]
struct DashboardState {
    pool: Option<PgPool>,
    fixture_path: Option<PathBuf>,
    window_minutes: i64,
    index_html: Arc<String>,
}

#[derive(Debug, Deserialize)]
struct CollectorStatusQuery {
    window_minutes: Option<i64>,
}

struct DashboardError(anyhow::Error);

impl IntoResponse for DashboardError {
    fn into_response(self) -> Response {
        let body = Json(serde_json::json!({
            "error": self.0.to_string(),
        }));
        (StatusCode::INTERNAL_SERVER_ERROR, body).into_response()
    }
}

impl<E> From<E> for DashboardError
where
    E: Into<anyhow::Error>,
{
    fn from(error: E) -> Self {
        Self(error.into())
    }
}

/// Serve the read-only collector dashboard until Ctrl+C.
///
/// # Errors
///
/// Returns an error if the bind address is invalid, the database cannot be
/// reached, fixture JSON cannot be read, or the HTTP server fails.
pub(crate) async fn serve_dashboard(args: DashboardArgs) -> anyhow::Result<()> {
    let bind = args
        .bind
        .parse::<SocketAddr>()
        .with_context(|| format!("invalid dashboard bind address: {}", args.bind))?;
    let pool = match (&args.fixture_path, args.database_url.as_deref()) {
        (Some(_), _) => None,
        (None, Some(database_url)) => Some(
            PgPoolOptions::new()
                .max_connections(5)
                .connect(database_url)
                .await
                .context("failed to connect to database for dashboard")?,
        ),
        (None, None) => {
            return Err(anyhow!(
                "--database-url or DATABASE_URL is required unless --fixture-path is set"
            ));
        }
    };

    let state = DashboardState {
        pool,
        fixture_path: args.fixture_path,
        window_minutes: args.window_minutes.max(1),
        index_html: Arc::new(INDEX_HTML.replace(
            "__POLL_MS__",
            &(args.poll_seconds.max(1) * 1000).to_string(),
        )),
    };
    let app = Router::new()
        .route("/", get(index))
        .route("/healthz", get(healthz))
        .route("/api/collector/status", get(collector_status))
        .route("/api/collector/history", get(collector_history))
        .with_state(state);

    let listener = TcpListener::bind(bind)
        .await
        .with_context(|| format!("failed to bind dashboard at {bind}"))?;
    info!("collector dashboard listening at http://{bind}");
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await
        .context("collector dashboard server failed")
}

async fn index(State(state): State<DashboardState>) -> Html<String> {
    Html((*state.index_html).clone())
}

async fn healthz() -> &'static str {
    "ok"
}

async fn collector_status(
    State(state): State<DashboardState>,
    Query(query): Query<CollectorStatusQuery>,
) -> Result<Json<CollectorDashboardMetrics>, DashboardError> {
    let metrics = if let Some(path) = &state.fixture_path {
        let body = tokio::fs::read_to_string(path)
            .await
            .with_context(|| format!("failed to read dashboard fixture: {}", path.display()))?;
        serde_json::from_str::<CollectorDashboardMetrics>(&body)
            .with_context(|| format!("failed to parse dashboard fixture: {}", path.display()))?
    } else {
        let pool = state
            .pool
            .as_ref()
            .ok_or_else(|| anyhow!("dashboard database pool is not configured"))?;
        repository::collector_dashboard_metrics(
            pool,
            repository::MetricsWindow::minutes(
                query.window_minutes.unwrap_or(state.window_minutes),
            ),
        )
        .await
        .context("failed to read collector dashboard metrics")?
    };
    Ok(Json(metrics))
}

async fn collector_history(
    State(state): State<DashboardState>,
    Query(query): Query<CollectorStatusQuery>,
) -> Result<Json<CollectorDashboardHistory>, DashboardError> {
    let window_minutes = query.window_minutes.unwrap_or(state.window_minutes).max(1);
    let history = if let Some(path) = &state.fixture_path {
        let body = tokio::fs::read_to_string(path)
            .await
            .with_context(|| format!("failed to read dashboard fixture: {}", path.display()))?;
        let metrics = serde_json::from_str::<CollectorDashboardMetrics>(&body)
            .with_context(|| format!("failed to parse dashboard fixture: {}", path.display()))?;
        history_from_fixture(&metrics)
    } else {
        let pool = state
            .pool
            .as_ref()
            .ok_or_else(|| anyhow!("dashboard database pool is not configured"))?;
        repository::collector_dashboard_history(
            pool,
            repository::MetricsWindow::minutes(window_minutes),
        )
        .await
        .context("failed to read collector dashboard history")?
    };
    Ok(Json(history))
}

fn history_from_fixture(metrics: &CollectorDashboardMetrics) -> CollectorDashboardHistory {
    let mut samples = Vec::new();
    for source in &metrics.sources {
        for offset in [120_i64, 60, 0] {
            samples.push(CollectorHistorySample {
                source: source.source.clone(),
                symbol: source.symbol.clone(),
                checked_at: source.checked_at - Duration::seconds(offset),
                status: source.status.clone(),
                freshness_ms: source
                    .freshness_ms
                    .map(|freshness| freshness.saturating_add(offset * 1000)),
                last_latency_ms: Some(
                    source
                        .latency_bucket_ge_1000_ms
                        .checked_mul(1000)
                        .unwrap_or_default()
                        .max(25),
                ),
                reconnects_5m: source.reconnects_5m,
                messages_received: source.messages_received.saturating_sub(offset),
                normalized_events: source.normalized_events,
            });
        }
    }
    CollectorDashboardHistory {
        window_seconds: metrics.window_seconds,
        samples,
    }
}
