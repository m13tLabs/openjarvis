#!/usr/bin/env bash
#
# Smoke test for the built OpenJarvis image. Run by the `docker-ci.yml`
# template's "Smoke test" step with $IMAGE set to the freshly built local tag,
# once per Dockerfile.
#
#   IMAGE=m13t/openjarvis:local bash smoke_test.sh
#
# Guards the things that have actually broken here:
#   - the `jarvis` entrypoint / version
#   - the insecure-context polyfill (unit-tested + served + wired into <head>)
#   - the CSP allowing the SPA's data: webfonts
#   - the web UI mounting at / with real JS assets
#   - the mandatory openjarvis_rust native extension
set -euo pipefail

: "${IMAGE:?IMAGE must be set to the image tag under test}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${SMOKE_PORT:-18000}"
BASE="http://localhost:${PORT}"
NET="ojsmoke-$$"
APP="ojsmoke-app-$$"
ENGINE="ojsmoke-engine-$$"

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

cleanup() {
  docker rm -f "$APP" "$ENGINE" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
step "jarvis entrypoint"
docker run --rm "$IMAGE" --version | grep -qE '^jarvis, version '
pass "jarvis --version"

# ---------------------------------------------------------------------------
step "insecure-context polyfill — unit tests"
if command -v node >/dev/null 2>&1; then
  node --test "$HERE/test/insecure-context-polyfill.test.mjs"
  pass "node --test"
else
  echo "  node not found — skipping unit tests (CI runners have it)"
fi

# ---------------------------------------------------------------------------
step "boot container (with a fake engine so serve will start)"
docker network create "$NET" >/dev/null

docker run -d --name "$ENGINE" --network "$NET" \
  -v "$HERE/test/mock-ollama.py:/mock-ollama.py:ro" \
  python:3.12-slim python /mock-ollama.py >/dev/null

CFG="$(mktemp -d)/config.toml"
cat > "$CFG" <<EOF
[engine]
default = "ollama"
[engine.ollama]
host = "http://${ENGINE}:11434"
[intelligence]
default_model = "smoke:latest"
[server]
host = "0.0.0.0"
port = 8000
[tools.mcp]
enabled = false
EOF

docker run -d --name "$APP" --network "$NET" \
  -e OPENJARVIS_API_KEY=ci-smoke-key \
  -v "$CFG:/root/.openjarvis/config.toml:ro" \
  -p "${PORT}:8000" "$IMAGE" >/dev/null

for i in $(seq 1 60); do
  if curl -fsS "${BASE}/health" >/dev/null 2>&1; then break; fi
  if [ "$i" = 60 ]; then echo "server never became healthy"; docker logs "$APP"; exit 1; fi
  sleep 1
done
pass "GET /health -> 200"

# ---------------------------------------------------------------------------
step "web UI is served at /"
BODY=$(curl -fsS "$BASE/")
grep -q '<div id="root">' <<<"$BODY"
grep -qE '/assets/index-[A-Za-z0-9_-]+\.js' <<<"$BODY"
pass "GET / serves the SPA shell"

ASSET=$(grep -oE '/assets/index-[A-Za-z0-9_-]+\.js' <<<"$BODY" | head -1)
CT=$(curl -fsS -o /dev/null -w '%{content_type}' "${BASE}${ASSET}")
case "$CT" in
  *javascript*) pass "JS asset served as $CT (not text/html)" ;;
  *) echo "  FAIL: $ASSET served as '$CT'"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
step "insecure-context polyfill — served & wired before the app bundle"
grep -q '/insecure-context-polyfill.js' <<<"$BODY"
POLY_AT=$(awk '/insecure-context-polyfill\.js/ {print NR; exit}' <<<"$BODY")
APP_AT=$(awk '/src="\/assets\/index-/ {print NR; exit}' <<<"$BODY")
if [ -z "$POLY_AT" ] || [ -z "$APP_AT" ] || [ "$POLY_AT" -ge "$APP_AT" ]; then
  echo "  FAIL: polyfill (line ${POLY_AT:-?}) must load before app module (line ${APP_AT:-?})"; exit 1
fi
pass "polyfill <script> precedes the app module in index.html"

PCT=$(curl -fsS -o /dev/null -w '%{http_code} %{content_type}' "${BASE}/insecure-context-polyfill.js")
case "$PCT" in
  200\ *javascript*) pass "GET /insecure-context-polyfill.js -> $PCT" ;;
  *) echo "  FAIL: polyfill asset -> '$PCT'"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
step "Content-Security-Policy allows the SPA's data: webfonts"
CSP=$(curl -fsS -D - -o /dev/null "$BASE/" | tr -d '\r' | grep -i '^content-security-policy:' || true)
[ -n "$CSP" ] || { echo "  FAIL: no Content-Security-Policy header"; exit 1; }
echo "  $CSP"
grep -qiE 'font-src[^;]*data:' <<<"$CSP" || { echo "  FAIL: font-src does not allow data:"; exit 1; }
grep -qiE 'img-src[^;]*data:'  <<<"$CSP" || { echo "  FAIL: img-src does not allow data:"; exit 1; }
pass "font-src / img-src allow data:"

# The CSS the SPA actually ships embeds fonts as data: URIs — make sure that
# assumption still holds, otherwise the CSP check above is meaningless.
CSS=$(grep -oE '/assets/index-[A-Za-z0-9_-]+\.css' <<<"$BODY" | head -1)
if [ -n "$CSS" ]; then
  if curl -fsS "${BASE}${CSS}" | grep -q 'url(data:font'; then
    pass "shipped CSS embeds data: fonts (CSP fix is load-bearing)"
  else
    echo "  note: shipped CSS no longer embeds data: fonts"
  fi
fi

# ---------------------------------------------------------------------------
step "mandatory openjarvis_rust native extension"
docker exec "$APP" sh -c \
  'python -c "from openjarvis._rust_bridge import RUST_AVAILABLE; assert RUST_AVAILABLE" 2>/dev/null \
   || python3 -c "from openjarvis._rust_bridge import RUST_AVAILABLE; assert RUST_AVAILABLE"'
pass "RUST_AVAILABLE is True"

# ---------------------------------------------------------------------------
step "Node.js + MCP stdio shims"
docker exec "$APP" node --version | grep -qE '^v22\.'
pass "node v22 on PATH"
docker exec "$APP" sh -c 'command -v npx >/dev/null && command -v mcp-remote >/dev/null && command -v paperless-mcp >/dev/null'
pass "npx / mcp-remote / paperless-mcp resolve"

# ---------------------------------------------------------------------------
step "MCP stdio transport honours a per-server env (patches/mcp-stdio-env.patch)"
docker exec "$APP" sh -c \
  'python  -c "import inspect;from openjarvis.mcp.transport import StdioTransport as T;assert \"env\" in inspect.signature(T.__init__).parameters" 2>/dev/null \
   || python3 -c "import inspect;from openjarvis.mcp.transport import StdioTransport as T;assert \"env\" in inspect.signature(T.__init__).parameters"'
pass "StdioTransport.__init__ takes env"

printf '\n\033[32mALL SMOKE TESTS PASSED\033[0m\n'
