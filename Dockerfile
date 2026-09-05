# OpenJarvis server, installed from the published PyPI release.
#
# The pinned version lives in JARVIS_VERSION so Renovate's Dockerfile _VERSION
# custom manager (github>m13tLabs/renovate-config) can bump it automatically.
# It is a global ARG (re-declared per stage) so the one line drives every stage.
#
# The mandatory openjarvis_rust extension (see below) is NOT compiled here -
# it's pulled from a prebuilt base image (Dockerfile.base / release-base.yml)
# to skip a from-scratch Rust release compile on every release build (that
# used to make this take close to an hour under QEMU for the arm64 leg).
# Everything else still happens right here at release time - it's fast
# enough that hiding it behind the weekly base cron isn't worth the added
# Renovate-bump lag or the risk of it drifting out of sync with whatever
# JARVIS_VERSION this build actually wants; the version check in the Python
# builder stage below turns that risk into a loud build failure instead of a
# silent one.

# renovate: datasource=pypi depName=openjarvis versioning=pep440
ARG JARVIS_VERSION=1.0.3
# renovate: datasource=docker depName=ghcr.io/m13tlabs/openjarvis-base
ARG BASE_VERSION=2026.09.04

# ---------------------------------------------------------------------------
# Rust extension wheel - prebuilt, see the file header above.
# ---------------------------------------------------------------------------
FROM ghcr.io/m13tlabs/openjarvis-base:${BASE_VERSION} AS rust-wheel

# ---------------------------------------------------------------------------
# sdist
#
# Only fetched here for frontend/ - the wheel has no rust/ or frontend/, only
# the sdist does (see Dockerfile.base for why --no-binary is scoped to just
# openjarvis). This is a plain download + tar extract, no compile, so unlike
# the Rust build it isn't worth pulling from the base image too.
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS sdist

ARG JARVIS_VERSION

RUN mkdir -p /src \
 && pip download --no-deps --no-binary openjarvis "openjarvis==${JARVIS_VERSION}" -d /dl \
 && tar xzf /dl/openjarvis-*.tar.gz -C /src --strip-components=1

# ---------------------------------------------------------------------------
# Frontend builder
#
# `jarvis serve` (openjarvis/server/app.py) mounts a web UI at `/` only when
# openjarvis/server/static/ exists - and the PyPI package doesn't ship it. The
# sdist carries the Vite/React SPA source under frontend/; build it here. (The
# @tauri-apps/* deps are for the optional desktop shell and degrade gracefully
# in a plain browser - isTauri() gates them.)
#
# We also inject patches/insecure-context-polyfill.js: OpenJarvis is usually
# served over plain HTTP on a LAN, where secure-context-only APIs the SPA uses
# are missing - crypto.randomUUID (called at store init -> hard crash on load)
# and navigator.clipboard (copy buttons throw). Loaded as a classic <script> in
# <head> so it runs before the app bundle. Covered by test/ and smoke_test.sh.
# ---------------------------------------------------------------------------
FROM node:24-slim AS frontend-builder

COPY --from=sdist /src/frontend /fe
COPY patches/insecure-context-polyfill.js /fe/public/insecure-context-polyfill.js
WORKDIR /fe
# Skip `tsc -b` (the `build` script's type-check step) - esbuild transpiles
# without it and a strict type error must not fail the image build.
# Cache npm's download cache (not node_modules itself - npm ci always wipes
# and reinstalls it) so repeat builds skip re-fetching the registry tarballs.
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    sed -i 's#</head>#    <script src="/insecure-context-polyfill.js"></script>\n  </head>#' index.html \
 && grep -q 'insecure-context-polyfill.js' index.html \
 && npm ci --no-audit --no-fund \
 && npx vite build --outDir /static --emptyOutDir \
 && test -f /static/insecure-context-polyfill.js \
 && grep -q 'insecure-context-polyfill.js' /static/index.html

# ---------------------------------------------------------------------------
# Node.js runtime + MCP stdio shims
#
# `jarvis serve` runs MCP servers configured as stdio transports by spawning
# their `command` (the [tools.mcp] `servers` list in config.toml). Ours are npm
# packages - `mcp-remote` (the GitLab MCP OAuth bridge) and
# `@baruchiro/paperless-mcp` - so the runtime needs Node. Pre-install them
# globally here so the spawn never has to reach the network and the versions
# are pinned + Renovate-visible; the runtime stage copies just `node` + the
# global modules out of this stage.
#
# bullseye (glibc 2.31) on purpose: the copied `node` binary then runs on BOTH
# runtime bases - Debian bookworm (this file) and Ubuntu 22.04 / glibc 2.35
# (Dockerfile.gpu).
# ---------------------------------------------------------------------------
FROM node:24-bullseye-slim AS node-runtime

# renovate: datasource=npm depName=mcp-remote versioning=npm
ARG MCP_REMOTE_VERSION=0.8.3
# renovate: datasource=npm depName=@baruchiro/paperless-mcp versioning=npm
ARG PAPERLESS_MCP_VERSION=2.0.1
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm install -g --no-audit --no-fund \
      "mcp-remote@${MCP_REMOTE_VERSION}" \
      "@baruchiro/paperless-mcp@${PAPERLESS_MCP_VERSION}"

# ---------------------------------------------------------------------------
# Python builder
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS builder

ARG JARVIS_VERSION

COPY --from=rust-wheel /wheels /wheels
COPY --from=frontend-builder /static /static

# The base's wheel was compiled against whatever JARVIS_VERSION was current
# when Dockerfile.base last built - fail loudly instead of installing a
# possibly ABI-mismatched openjarvis_rust/openjarvis[server] combination if
# this build wants a different version.
RUN BASE_JARVIS_VERSION="$(cat /wheels/JARVIS_VERSION)" \
 && if [ "$BASE_JARVIS_VERSION" != "$JARVIS_VERSION" ]; then \
      echo "openjarvis-base wheel was built for JARVIS_VERSION=$BASE_JARVIS_VERSION, this build wants $JARVIS_VERSION - rebuild Dockerfile.base (workflow_dispatch release-base.yml) or bump BASE_VERSION" >&2; \
      exit 1; \
    fi

RUN --mount=type=cache,target=/root/.cache/uv,sharing=locked \
    pip install --no-cache-dir uv \
 && uv pip install --system "openjarvis[server]==${JARVIS_VERSION}" \
 && uv pip install --system /wheels/openjarvis_rust-*.whl \
 && cp -r /static "$(python -c 'import openjarvis.server, pathlib; print(pathlib.Path(openjarvis.server.__file__).parent / "static")')" \
 && rm -rf /wheels /static

# Upstream's MCP stdio loader reads `command`/`args` from each server entry but
# ignores `env`, and StdioTransport spawns the child with no `env=` - so an
# npx shim (mcp-remote, @baruchiro/paperless-mcp v2) can't be handed its token
# / base URL. Patch it in; the assert makes an upstream refactor fail loudly.
COPY patches/mcp-stdio-env.patch /tmp/mcp-stdio-env.patch
RUN apt-get update && apt-get install -y --no-install-recommends patch \
 && rm -rf /var/lib/apt/lists/* \
 && OJ_DIR="$(python -c 'import openjarvis, pathlib; print(pathlib.Path(openjarvis.__file__).parent)')" \
 && patch -p1 --forward -d "$OJ_DIR" < /tmp/mcp-stdio-env.patch \
 && rm /tmp/mcp-stdio-env.patch \
 && python -c "import inspect; from openjarvis.mcp.transport import StdioTransport; assert 'env' in inspect.signature(StdioTransport.__init__).parameters, 'mcp-stdio-env patch did not apply'"

# The server's CSP is a hardcoded `default-src 'self' 'unsafe-inline'
# 'unsafe-eval'` (openjarvis/server/middleware.py) with no knob - it blocks the
# SPA's `data:` webfonts (geist / KaTeX). Widen font-src / img-src to allow them.
RUN CSP_FILE="$(python -c 'import openjarvis.server.middleware as m; print(m.__file__)')" \
 && sed -i "s|default-src 'self' 'unsafe-inline' 'unsafe-eval'|default-src 'self' 'unsafe-inline' 'unsafe-eval'; font-src 'self' data:; img-src 'self' data:|g" "$CSP_FILE"

# Fail the build if the mandatory native extension, the web UI, the polyfill,
# or the CSP fix did not land.
RUN python -c "from openjarvis._rust_bridge import RUST_AVAILABLE; assert RUST_AVAILABLE, 'openjarvis_rust missing'" \
 && python -c "import openjarvis.server, pathlib; d = pathlib.Path(openjarvis.server.__file__).parent / 'static'; assert (d / 'index.html').is_file(), 'frontend static/ missing'; assert (d / 'insecure-context-polyfill.js').is_file(), 'insecure-context polyfill missing'; assert 'insecure-context-polyfill.js' in (d / 'index.html').read_text(), 'polyfill not referenced by index.html'" \
 && python -c "from openjarvis.server.middleware import SECURITY_HEADERS as h; csp = h['Content-Security-Policy']; assert 'font-src' in csp and 'data:' in csp, csp"

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
FROM python:3.12-slim

ARG BUILD_DATE
ARG APP_VERSION

LABEL org.opencontainers.image.authors='Martin Reinhardt (martin@m13t.de)' \
    org.opencontainers.image.created=$BUILD_DATE \
    org.opencontainers.image.version=$APP_VERSION \
    org.opencontainers.image.url='https://hub.docker.com/r/m13t/openjarvis' \
    org.opencontainers.image.documentation='https://github.com/m13tLabs/openjarvis' \
    org.opencontainers.image.source='https://github.com/m13tLabs/openjarvis.git' \
    org.opencontainers.image.licenses='MIT'

# git: `jarvis skill` clones the skill-index repo. curl: the HEALTHCHECK below.
# libstdc++6: the `node` binary copied below links against it and
# python:3.12-slim does not ship it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates libstdc++6 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local /usr/local

# Node.js + the pre-installed MCP stdio shims (see the node-runtime stage).
# npm's own global bin symlinks aren't copied, so recreate the ones we invoke.
COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=node-runtime /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && ln -s ../lib/node_modules/mcp-remote/dist/proxy.js /usr/local/bin/mcp-remote \
 && ln -s "../lib/node_modules/@baruchiro/paperless-mcp/build/index.js" /usr/local/bin/paperless-mcp \
 && node --version && npm --version \
 && node -e "require('/usr/local/lib/node_modules/mcp-remote/package.json'); require('/usr/local/lib/node_modules/@baruchiro/paperless-mcp/package.json')" \
 && test -e /usr/local/bin/mcp-remote && test -e /usr/local/bin/paperless-mcp
ENV NPM_CONFIG_CACHE=/tmp/.npm NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /app

EXPOSE 8000

# /health needs neither auth nor a reachable engine; curl -f exits non-zero on
# any failure, which is all HEALTHCHECK needs.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["curl", "-fsS", "http://localhost:8000/health"]

ENTRYPOINT ["jarvis"]
CMD ["serve", "--host", "0.0.0.0", "--port", "8000"]
