use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Json},
};
use serde_json::json;
use std::sync::Arc;

use crate::auth::check_auth;
use crate::AppState;

pub async fn lock_screen(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, StatusCode> {
    if !check_auth(&headers, state.expected_hash.as_deref()) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    // Invoke loginctl lock-sessions
    let _ = std::process::Command::new("loginctl")
        .arg("lock-sessions")
        .status();

    Ok(Json(json!({
        "status": "ok",
        "action": "lock",
        "result": "locked"
    })))
}
