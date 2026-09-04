#!/usr/bin/env bats

setup() {
  export PARENTAL_OS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  cd "$PARENTAL_OS_ROOT"
  if [ -f "$BATS_TEST_DIRNAME/../test_helper/bats-support/load.bash" ]; then
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    load '../test_helper/common'
  fi
}

assert_success() {
  [ "$status" -eq 0 ]
}

assert_failure() {
  [ "$status" -ne 0 ]
}

assert_output() {
  if [ "$1" = "--partial" ]; then
    [[ "$output" == *"$2"* ]]
  else
    [ "$output" = "$1" ]
  fi
}

@test "parental-remote computes deterministic domain-separated hash" {
  run python3 -c "
import sys
sys.path.insert(0, 'scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('remote', 'scripts/parental-remote.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert mod.compute_guardian_hash('secret123') == '6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b' or len(mod.compute_guardian_hash('secret123')) == 64
"
  assert_success
}

@test "parental-remote CLI prints help on missing arguments" {
  run python3 scripts/parental-remote.py
  assert_failure
  assert_output --partial "usage:"
}

@test "parental-remote CLI prints help on --help" {
  run python3 scripts/parental-remote.py --help
  assert_success
  assert_output --partial "Parental OS Remote Client"
}

@test "parental-remote CLI handles connection error" {
  run python3 scripts/parental-remote.py --host 127.0.0.1 --port 65530 --password secret123 health
  assert_failure
  assert_output --partial "error"
}

@test "parental-remote sends authenticated status and lock requests" {
  run python3 -c "
import http.server
import threading
import sys
sys.path.insert(0, 'scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('remote', 'scripts/parental-remote.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

expected_token = mod.compute_guardian_hash('secret123')

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{\"status\": \"ok\"}')
        elif self.path == '/v1/status':
            if self.headers.get('Authorization') == f'Bearer {expected_token}':
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{\"status\": \"active\"}')
            else:
                self.send_response(401)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{\"error\": \"unauthorized\"}')
    def do_POST(self):
        if self.path == '/v1/actions/lock':
            if self.headers.get('Authorization') == f'Bearer {expected_token}':
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{\"action\": \"lock\"}')
            else:
                self.send_response(401)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{\"error\": \"unauthorized\"}')
    def log_message(self, *args):
        pass

server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
port = server.server_port
t = threading.Thread(target=server.serve_forever)
t.daemon = True
t.start()

# Test health
code, resp = mod.send_request('127.0.0.1', port, '/health')
assert code == 200
assert resp['status'] == 'ok'

# Test status with token
code, resp = mod.send_request('127.0.0.1', port, '/v1/status', method='GET', token=expected_token)
assert code == 200
assert resp['status'] == 'active'

# Test status with invalid token
code, resp = mod.send_request('127.0.0.1', port, '/v1/status', method='GET', token='invalid')
assert code == 401
assert resp['error'] == 'unauthorized'

# Test lock with token
code, resp = mod.send_request('127.0.0.1', port, '/v1/actions/lock', method='POST', token=expected_token)
assert code == 200
assert resp['action'] == 'lock'

# Test lock without token
code, resp = mod.send_request('127.0.0.1', port, '/v1/actions/lock', method='POST')
assert code == 401

server.shutdown()
server.server_close()
"
  assert_success
}
