use axum::http::HeaderMap;
use subtle::ConstantTimeEq;

pub fn check_auth(headers: &HeaderMap, expected_hash: Option<&str>) -> bool {
    let Some(expected) = expected_hash else {
        return false;
    };
    let Some(auth_header) = headers.get("Authorization").and_then(|h| h.to_str().ok()) else {
        return false;
    };
    if !auth_header.starts_with("Bearer ") {
        return false;
    }
    let token = auth_header["Bearer ".len()..].trim();
    if expected.is_empty() || token.is_empty() || expected.len() != 64 {
        return false;
    }
    token.as_bytes().ct_eq(expected.as_bytes()).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    const VALID_HASH: &str = "6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b";

    #[test]
    fn test_valid_bearer_token() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {}", VALID_HASH)).unwrap(),
        );
        assert!(check_auth(&headers, Some(VALID_HASH)));
    }

    #[test]
    fn test_invalid_bearer_token() {
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", HeaderValue::from_static("Bearer wrong"));
        assert!(!check_auth(&headers, Some(VALID_HASH)));
    }

    #[test]
    fn test_missing_auth_header() {
        let headers = HeaderMap::new();
        assert!(!check_auth(&headers, Some(VALID_HASH)));
    }

    #[test]
    fn test_non_bearer_header() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "Authorization",
            HeaderValue::from_str(&format!("Basic {}", VALID_HASH)).unwrap(),
        );
        assert!(!check_auth(&headers, Some(VALID_HASH)));
    }

    #[test]
    fn test_missing_expected_hash() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {}", VALID_HASH)).unwrap(),
        );
        assert!(!check_auth(&headers, None));
    }

    #[test]
    fn test_empty_token_and_empty_expected_hash() {
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", HeaderValue::from_static("Bearer "));
        assert!(!check_auth(&headers, Some("")));
    }

    #[test]
    fn test_empty_token_with_valid_expected() {
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", HeaderValue::from_static("Bearer "));
        assert!(!check_auth(&headers, Some(VALID_HASH)));
    }

    #[test]
    fn test_short_expected_hash() {
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", HeaderValue::from_static("Bearer short"));
        assert!(!check_auth(&headers, Some("short")));
    }
}
