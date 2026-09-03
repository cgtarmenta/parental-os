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
    let expected = state.get_expected_hash();
    if !check_auth(&headers, expected.as_deref()) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    // Invoke loginctl lock-sessions asynchronously
    let status = tokio::process::Command::new("loginctl")
        .arg("lock-sessions")
        .status()
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    if !status.success() {
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }

    Ok(Json(json!({
        "status": "ok",
        "action": "lock",
        "result": "locked"
    })))
}
