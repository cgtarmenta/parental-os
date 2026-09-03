pub mod actions;
pub mod auth;

use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Json},
    routing::{get, post},
    Router,
};
use serde_json::json;
use std::sync::Arc;

pub use actions::lock_screen;
pub use auth::check_auth;

#[derive(Clone)]
pub struct AppState {
    pub expected_hash: Option<String>,
}

pub fn app(expected_hash: Option<String>) -> Router {
    let state = Arc::new(AppState { expected_hash });
    Router::new()
        .route("/health", get(health))
        .route("/v1/status", get(status))
        .route("/v1/actions/lock", post(lock_screen))
        .with_state(state)
}

async fn health() -> impl IntoResponse {
    Json(json!({
        "status": "ok",
        "service": "parental-guard-agent"
    }))
}

async fn status(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, StatusCode> {
    if !check_auth(&headers, state.expected_hash.as_deref()) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(Json(json!({
        "service": "parental-guard-agent",
        "version": "0.2.0",
        "status": "active"
    })))
}
