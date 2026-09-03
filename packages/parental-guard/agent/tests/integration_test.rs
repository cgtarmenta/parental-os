use axum::http::{Request, StatusCode};
use tower::ServiceExt;

#[tokio::test]
async fn test_health_endpoint_public() {
    let app = parental_guard_agent::app(Some("dummy_hash".to_string()));
    let response = app
        .oneshot(Request::builder().uri("/health").body(axum::body::Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn test_status_requires_valid_bearer() {
    let secret_hash = "6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b";
    let app = parental_guard_agent::app(Some(secret_hash.to_string()));

    // Unauthorized without header
    let res_no_auth = app.clone()
        .oneshot(Request::builder().uri("/v1/status").body(axum::body::Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(res_no_auth.status(), StatusCode::UNAUTHORIZED);

    // Authorized with matching header
    let res_auth = app
        .oneshot(
            Request::builder()
                .uri("/v1/status")
                .header("Authorization", format!("Bearer {}", secret_hash))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res_auth.status(), StatusCode::OK);
}

#[tokio::test]
async fn test_action_lock_requires_valid_bearer() {
    let secret_hash = "6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b";
    let app = parental_guard_agent::app(Some(secret_hash.to_string()));

    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/actions/lock")
                .header("Authorization", format!("Bearer {}", secret_hash))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
}
