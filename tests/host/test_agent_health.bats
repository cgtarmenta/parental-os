#!/usr/bin/env bats

setup() {
  export PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  PORT=17420
  TOKEN_DIR="$(mktemp -d)"
  echo "test-token-123" >"$TOKEN_DIR/agent.token"
  STATE="$(mktemp -d)"
  python3 "$PARENTAL_OS_ROOT/overlays/usr/lib/parental-os/agent/server.py" \
    --bind 127.0.0.1 --port "$PORT" \
    --token-file "$TOKEN_DIR/agent.token" \
    --state-dir "$STATE" &
  export AGENT_PID=$!
  export PORT TOKEN_DIR STATE
  sleep 0.5
}

teardown() {
  kill "$AGENT_PID" 2>/dev/null || true
  rm -rf "$TOKEN_DIR" "$STATE"
}

@test "GET /health returns ok without token" {
  run curl -sf "http://127.0.0.1:${PORT}/health"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok"'* ]] || [[ "$output" == *'ok'* ]]
}

@test "GET /v1/status without token is 401" {
  run curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/v1/status"
  [ "$output" = "401" ]
}

@test "GET /v1/status with token works" {
  run curl -sf -H "Authorization: Bearer test-token-123" "http://127.0.0.1:${PORT}/v1/status"
  [ "$status" -eq 0 ]
}

@test "POST /v1/allowances returns 501" {
  code="$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Bearer test-token-123" \
    "http://127.0.0.1:${PORT}/v1/allowances")"
  [ "$code" = "501" ]
}
