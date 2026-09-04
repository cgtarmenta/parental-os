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
    let lock_cmd = std::env::var("PARENTAL_OS_LOCK_CMD").unwrap_or_else(|_| "loginctl".to_string());
    let mut cmd = tokio::process::Command::new(&lock_cmd);
    if lock_cmd == "loginctl" {
        cmd.arg("lock-sessions");
    }
    let status = cmd
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
