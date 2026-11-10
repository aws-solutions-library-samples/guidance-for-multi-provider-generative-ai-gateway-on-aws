#!/usr/bin/env bash
# Minimal post-deploy check that the infrastructure brought LiteLLM up
# correctly. It does not test LiteLLM features.
#
#   deploy/smoke-test.sh [options] <gateway-url>
#
# Checks: LiteLLM is alive, the database is connected, a call without a key
# is refused, an authenticated call works, the database schema exists, and
# (with --model) one real completion succeeds.
#
# The key comes from the LITELLM_KEY environment variable or, with
# --key-secret-arn, is fetched from Secrets Manager into a shell variable at
# runtime. The script is designed not to echo or log it or pass it as a process
# argument: curl reads it from a config file (mode 600, removed on exit).
set -uo pipefail

usage() {
  cat <<'EOF'
Minimal post-deploy smoke test for the gateway infrastructure.

Usage:
  LITELLM_KEY=<key> deploy/smoke-test.sh [options] <gateway-url>
  deploy/smoke-test.sh --key-secret-arn <arn> [options] <gateway-url>
  deploy/smoke-test.sh --self-test

Checks (in order):
  1. liveliness            GET /health/liveliness returns 200
  2. readiness             GET /health/readiness reports the database connected
  3. unauthenticated call  GET /v1/models without a key returns 401
  4. authenticated call    GET /v1/models with the key returns 200
  5. schema migrated       GET /key/list returns 200 (healthy even endpoints
                           pass on an unmigrated database; this does not).
                           Needs an admin key such as the master key; with an
                           application key (403) the check is skipped
  6. completion            (only with --model) one chat completion returns 200

Options:
  --key-secret-arn <arn>  Fetch the key from this Secrets Manager secret at
                          runtime instead of reading LITELLM_KEY (needs aws CLI).
  --model <model>         Also run one real completion against this model.
  --cacert <file>         Verify TLS against this CA certificate (PEM), for
                          example the root of a private certificate authority.
  --insecure              Skip TLS verification (self-signed trial certificates).
                          Prefer --cacert.
  --self-test             Offline self-test: start a local stub gateway with
                          python3 and run every check against it. No AWS, no
                          deployment needed.
  -h, --help              Show this help.

The script is designed not to echo or log the key, or pass it as a process argument visible in ps.

Exit codes: 0 all checks passed, 1 at least one check failed, 2 usage or
prerequisite error.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 2
}

URL=""
MODEL=""
KEY_SECRET_ARN=""
INSECURE=false
CACERT=""
SELF_TEST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key-secret-arn | --model | --cacert)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; die "$1 needs a value."; }
      case "$1" in
        --key-secret-arn) KEY_SECRET_ARN="$2" ;;
        --model) MODEL="$2" ;;
        --cacert) CACERT="$2" ;;
      esac
      shift 2 ;;
    --insecure) INSECURE=true; shift ;;
    --self-test) SELF_TEST=true; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option '$1'" ;;
    *)
      [[ -z "$URL" ]] || { usage >&2; die "unexpected argument '$1'"; }
      URL="$1"; shift ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "curl is required but not installed."
[[ -z "$CACERT" || "$INSECURE" != true ]] || die "--cacert and --insecure cannot be combined."
[[ -z "$CACERT" || -r "$CACERT" ]] || die "--cacert file not readable: $CACERT"

# ---------------------------------------------------------------------------
# Cleanup: the curl config holding the key, and the self-test stub if any.
# ---------------------------------------------------------------------------
CURL_CFG=""
STUB_PID=""
STUB_DIR=""
trap '
  [[ -n "$CURL_CFG" ]] && rm -f "$CURL_CFG"
  [[ -n "$STUB_PID" ]] && { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; }
  [[ -n "$STUB_DIR" ]] && rm -rf "$STUB_DIR"
' EXIT

# ---------------------------------------------------------------------------
# Self-test: a local python3 stub that behaves like a healthy gateway.
# ---------------------------------------------------------------------------
start_stub() {
  command -v python3 >/dev/null 2>&1 || die "--self-test needs python3."
  STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-gateway-smoke.XXXXXX")"
  cat >"$STUB_DIR/stub.py" <<'EOF'
import http.server
import os

KEY = os.environ["STUB_KEY"]
PORT = int(os.environ["STUB_PORT"])


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body=b"{}"):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        return self.headers.get("Authorization") == "Bearer " + KEY

    def do_GET(self):
        if self.path == "/health/liveliness":
            self._send(200, b'"I\'m alive!"')
        elif self.path == "/health/readiness":
            self._send(200, b'{"status": "connected", "db": "connected"}')
        elif self.path in ("/v1/models", "/key/list"):
            self._send(200 if self._authed() else 401)
        else:
            self._send(404)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/v1/chat/completions":
            self._send(200 if self._authed() else 401)
        else:
            self._send(404)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
server.serve_forever()
EOF
  KEY="sk-smoke-self-test-$$"
  local port tries=0
  port=$(((RANDOM % 16000) + 49152))
  STUB_KEY="$KEY" STUB_PORT="$port" python3 -I "$STUB_DIR/stub.py" >/dev/null 2>&1 &
  STUB_PID=$!
  URL="http://127.0.0.1:${port}"
  until [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL/health/liveliness")" == "200" ]]; do
    kill -0 "$STUB_PID" 2>/dev/null || die "self-test stub failed to start (port ${port} taken?). Re-run."
    tries=$((tries + 1))
    [[ $tries -lt 50 ]] || die "self-test stub did not come up."
    sleep 0.2
  done
  MODEL="stub-model"
  echo "Self-test: stub gateway at $URL"
}

# ---------------------------------------------------------------------------
# The key: env var or Secrets Manager, into a curl config file (never argv).
# ---------------------------------------------------------------------------
if [[ "$SELF_TEST" == true ]]; then
  [[ -z "$URL" && -z "$KEY_SECRET_ARN" ]] || die "--self-test takes no URL and no --key-secret-arn."
  start_stub
else
  [[ -n "$URL" ]] || { usage >&2; die "gateway URL is required."; }
  URL="${URL%/}"
  if [[ -n "$KEY_SECRET_ARN" ]]; then
    command -v aws >/dev/null 2>&1 || die "--key-secret-arn needs the aws CLI."
    KEY="$(aws secretsmanager get-secret-value --secret-id "$KEY_SECRET_ARN" \
      --query SecretString --output text)" || die "could not read the key from Secrets Manager."
  else
    KEY="${LITELLM_KEY:-}"
  fi
  [[ -n "$KEY" ]] || die "set LITELLM_KEY or pass --key-secret-arn."
fi

umask 077
CURL_CFG="$(mktemp "${TMPDIR:-/tmp}/llm-gateway-smoke-hdr.XXXXXX")"
KEY="${KEY//\\/\\\\}"
KEY="${KEY//\"/\\\"}"
printf 'header = "Authorization: Bearer %s"\n' "$KEY" >"$CURL_CFG"
unset KEY

# tls_args: appends the TLS verification options to the caller's args array.
tls_args() {
  [[ "$INSECURE" == true ]] && args+=(-k)
  [[ -n "$CACERT" ]] && args+=(--cacert "$CACERT")
  return 0
}

# code_noauth <curl-args...>: status code, no key sent.
code_noauth() {
  local args=(-s -o /dev/null -w '%{http_code}' --max-time 60)
  tls_args
  curl "${args[@]}" "$@"
}

# code_auth <curl-args...>: status code, key sent via the config file.
code_auth() {
  local args=(-s -o /dev/null -w '%{http_code}' --max-time 60 -K "$CURL_CFG")
  tls_args
  curl "${args[@]}" "$@"
}

# body_noauth <curl-args...>: response body, no key sent.
body_noauth() {
  local args=(-s --max-time 60)
  tls_args
  curl "${args[@]}" "$@"
}

FAILED=0
check() { # name expected actual
  if [[ "$3" == "$2" ]]; then
    echo "PASS  $1 ($3)"
  else
    echo "FAIL  $1 (expected $2, got $3)"
    FAILED=1
  fi
}

check "liveliness" 200 "$(code_noauth "$URL/health/liveliness")"

READINESS="$(body_noauth "$URL/health/readiness")"
if echo "$READINESS" | grep -q '"db":"connected"\|"db": "connected"'; then
  echo "PASS  readiness (db connected)"
else
  echo "FAIL  readiness: ${READINESS:-no response}"
  FAILED=1
fi

check "unauthenticated call refused" 401 "$(code_noauth "$URL/v1/models")"
check "authenticated call" 200 "$(code_auth "$URL/v1/models")"
# Health endpoints report healthy even on an unmigrated database: prove the
# schema is there with a call that touches it.
# /key/list is an admin route: an application key gets 403, which says nothing
# about the schema, so the check is skipped rather than failed.
KEY_LIST="$(code_auth "$URL/key/list")"
if [[ "$KEY_LIST" == "403" ]]; then
  echo "SKIP  schema migrated (key list): needs an admin key such as the master key (got 403)"
else
  check "schema migrated (key list)" 200 "$KEY_LIST"
fi

if [[ -n "$MODEL" ]]; then
  BODY="$(printf '{"model":"%s","max_tokens":20,"messages":[{"role":"user","content":"What is 2 + 2?"}]}' "$MODEL")"
  check "completion with $MODEL" 200 \
    "$(code_auth -H 'Content-Type: application/json' -d "$BODY" "$URL/v1/chat/completions")"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "Smoke test passed."
else
  echo "Smoke test FAILED." >&2
fi
exit "$FAILED"
