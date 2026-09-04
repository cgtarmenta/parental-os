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

pub fn resolve_dynamic_hash() -> Option<String> {
    let hash_path = std::env::var("PARENTAL_OS_GUARDIAN_HASH_FILE")
        .unwrap_or_else(|_| "/etc/parental-os/guardian.hash".to_string());
    std::fs::read_to_string(&hash_path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && s.len() == 64)
        .or_else(|| {
            std::fs::read_to_string("/run/parental-os/guardian.hash")
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty() && s.len() == 64)
        })
        .or_else(|| {
            std::env::var("PARENTAL_OS_GUARDIAN_HASH")
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty() && s.len() == 64)
        })
}

impl AppState {
    pub fn get_expected_hash(&self) -> Option<String> {
        match &self.expected_hash {
            Some(h) => Some(h.clone()),
            None => resolve_dynamic_hash(),
        }
    }
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
    let expected = state.get_expected_hash();
    if !check_auth(&headers, expected.as_deref()) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(Json(json!({
        "service": "parental-guard-agent",
        "version": "0.2.0",
        "status": "active"
    })))
}
