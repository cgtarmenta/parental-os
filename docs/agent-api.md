# parental-os agent API (v1 stub)

Default bind: `127.0.0.1:7420` (see `/etc/parental-os/config.env`).

Auth: `Authorization: Bearer <token>` where token is in `PARENTAL_OS_TOKEN_FILE` (default `/etc/parental-os/agent.token`). Created on first start if missing (mode 0600).

## Endpoints

| Method | Path | Auth | v1 behavior |
|--------|------|------|-------------|
| GET | `/health` | no | `{"status":"ok",...}` |
| GET | `/v1/status` | yes | stub status JSON |
| GET | `/v1/users` | yes | `501 not_implemented` |
| POST | `/v1/allowances` | yes | `501 not_implemented` |

Phase 3 will implement real allowance and user listing against timekpr.
