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
    token.as_bytes().ct_eq(expected.as_bytes()).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    #[test]
    fn test_valid_bearer_token() {
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", HeaderValue::from_static("Bearer abc123def"));
        assert!(check_auth(&headers, Some("abc123def")));
    }

    #[test]
    fn test_invalid_bearer_token() {
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", HeaderValue::from_static("Bearer wrong"));
        assert!(!check_auth(&headers, Some("abc123def")));
    }

    #[test]
    fn test_missing_auth_header() {
        let headers = HeaderMap::new();
        assert!(!check_auth(&headers, Some("abc123def")));
    }

    #[test]
    fn test_non_bearer_header() {
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", HeaderValue::from_static("Basic abc123def"));
        assert!(!check_auth(&headers, Some("abc123def")));
    }

    #[test]
    fn test_missing_expected_hash() {
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", HeaderValue::from_static("Bearer abc123def"));
        assert!(!check_auth(&headers, None));
    }
}
