# OpenJarvis server, installed from the published PyPI release.
#
# The pinned version lives in JARVIS_VERSION so Renovate's Dockerfile _VERSION
# custom manager (github>m13tLabs/renovate-config) can bump it automatically.
# It is a global ARG (re-declared per stage) so the one line drives every stage.

# renovate: datasource=pypi depName=openjarvis versioning=pep440
ARG JARVIS_VERSION=1.0.3

# ---------------------------------------------------------------------------
# Rust extension builder
#
# openjarvis/_rust_bridge.py treats the compiled `openjarvis_rust` module as
# MANDATORY - the SQLite/BM25/ColBERT memory backends have no Python fallback
# and raise at request time without it. The PyPI package is pure-Python
# (py3-none-any at every version) and there is no openjarvis-rust on PyPI, but
# the sdist ships the full `rust/` workspace, so build the extension from there
# and carry the wheel forward.
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS rust-builder

ARG JARVIS_VERSION

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential curl ca-certificates pkg-config \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir maturin

# The wheel has no `rust/` dir; the sdist does. --no-binary forces the sdist.
RUN mkdir -p /src \
 && pip download --no-deps --no-binary :all: "openjarvis==${JARVIS_VERSION}" -d /dl \
 && tar xzf /dl/openjarvis-*.tar.gz -C /src --strip-components=1

# rust/rust-toolchain.toml pins channel 1.88 (the workspace needs let-chains +
# is_multiple_of); rustup installs/selects it automatically on the first build.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup.sh \
 && sh /tmp/rustup.sh -y --default-toolchain none --profile minimal \
 && rm /tmp/rustup.sh
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /src/rust
RUN maturin build --release \
      --manifest-path crates/openjarvis-python/Cargo.toml \
      --out /wheels

# ---------------------------------------------------------------------------
# Python builder
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS builder

ARG JARVIS_VERSION

COPY --from=rust-builder /wheels /wheels

RUN pip install --no-cache-dir uv \
 && uv pip install --system "openjarvis[server]==${JARVIS_VERSION}" \
 && uv pip install --system /wheels/openjarvis_rust-*.whl \
 && rm -rf /wheels

# Fail the build if the mandatory native extension did not actually land.
RUN python -c "from openjarvis._rust_bridge import RUST_AVAILABLE; assert RUST_AVAILABLE, 'openjarvis_rust missing'"

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
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local /usr/local
WORKDIR /app

EXPOSE 8000

# /health needs neither auth nor a reachable engine; curl -f exits non-zero on
# any failure, which is all HEALTHCHECK needs.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["curl", "-fsS", "http://localhost:8000/health"]

ENTRYPOINT ["jarvis"]
CMD ["serve", "--host", "0.0.0.0", "--port", "8000"]
