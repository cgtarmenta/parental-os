use std::fs;
use std::net::SocketAddr;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let hash_path = std::env::var("PARENTAL_OS_GUARDIAN_HASH_FILE")
        .unwrap_or_else(|_| "/etc/parental-os/guardian.hash".to_string());
    let expected_hash = fs::read_to_string(&hash_path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && s.len() == 64)
        .or_else(|| {
            fs::read_to_string("/run/parental-os/guardian.hash")
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty() && s.len() == 64)
        })
        .or_else(|| {
            std::env::var("PARENTAL_OS_GUARDIAN_HASH")
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty() && s.len() == 64)
        });

    let port: u16 = std::env::var("PARENTAL_OS_AGENT_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(7420);

    let app = parental_guard_agent::app(expected_hash);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    println!("parental-guard-agent listening on {}", addr);
    axum::serve(listener, app).await?;
    Ok(())
}
