# openjarvis (Docker image) — Claude Notes

> **Always update this file** when learning something new about this repo — build
> gotchas, upstream quirks, and lessons from debugging sessions.

## What this repo is

Just the Docker packaging for the upstream **`openjarvis`** PyPI package
(`openjarvis[server]`, the `jarvis` CLI — "OpenJarvis, modular AI assistant
backend"). No application code of our own. Publishes:

- `docker.io/m13t/openjarvis` + `ghcr.io/m13tlabs/openjarvis` — plain (`Dockerfile`, `python:3.12-slim`)
- same, `-gpu` suffix — CUDA build (`Dockerfile.gpu`, `nvidia/cuda:*-runtime-ubuntu22.04`, run with `--gpus all`)

`config.json` (`{"version": "0.1.0"}`) is the repo's own release version, bumped
by the `Release` workflow (`docker-release.yml` template). `JARVIS_VERSION` is
the upstream PyPI version, a global `ARG` bumped by Renovate
(`# renovate: datasource=pypi depName=openjarvis`).

CI: `docker-ci.yml` template, smoke test `docker run "$IMAGE" --version | grep -qE '^jarvis, version '` (ENTRYPOINT is `jarvis`).

## The mandatory Rust extension (`openjarvis_rust`)

**This is the one non-obvious thing about the build.** `openjarvis/_rust_bridge.py`
treats the compiled `openjarvis_rust` module as **mandatory**:

- The SQLite / BM25 / ColBERT memory backends (`tools/storage/sqlite.py`,
  `bm25.py`) have **no Python fallback** — they raise `MemoryBackendUnavailable`
  / `ImportError` at request time without it. `think` / `http_request` /
  `shell_exec` / `file_read` / `security.ssrf` / `security.boundary` *do* have
  Python fallbacks.
- Without it the memory backends 500 at request time; `think` /
  `http_request` / `shell_exec` / `file_read` / `security.*` fall back to Python.

**Verify the fix worked** with `python -c "from openjarvis._rust_bridge import
RUST_AVAILABLE; print(RUST_AVAILABLE)"` — that's the real signal (the build
also runs it as an assertion). **Ignore `jarvis doctor`'s "Rust extension:
building (run in background)" line** — `_bg_state.get_status()` just reports
`pending` whenever `~/.openjarvis/.state/extension-built` is absent, and nothing
writes that marker for a *prebuilt* extension. No `cargo`/`maturin` process
actually spawns (verified); the line is cosmetic.

The **PyPI package is pure-Python** (`openjarvis-<v>-py3-none-any.whl`, at every
version including dev builds — `pyproject.toml` build-backend is `hatchling`, not
maturin). There is **no `openjarvis-rust` package on PyPI**, and `maturin` is
only in the `[dev]` extra.

But the **sdist** (`openjarvis-<v>.tar.gz`, ~42 MB) ships the full `rust/`
workspace (17 crates). So both Dockerfiles:

1. `pip download --no-deps --no-binary :all:` the sdist, `tar --strip-components=1` it.
2. `rustup` with `--default-toolchain none` — `rust/rust-toolchain.toml` pins
   **channel 1.88** (workspace uses let-chains + `is_multiple_of`, both 1.88
   stabilizations; older stable fails with cryptic E0658 deep in deps). rustup
   installs/selects it automatically on the first `cargo`/`maturin` run.
3. `maturin build --release --manifest-path crates/openjarvis-python/Cargo.toml`
   → `openjarvis_rust-0.1.0-cp3XX-cp3XX-manylinux_*.whl` in `/wheels`.
4. Python builder stage installs `openjarvis[server]` then that wheel, and
   asserts `from openjarvis._rust_bridge import RUST_AVAILABLE` — the build
   fails loudly if the extension didn't land.

### Gotchas

- **Rust compile is ~1–2 min** and needs `build-essential` + `pkg-config`
  (`rusqlite` is `features = ["bundled"]` — compiles SQLite from C; `reqwest`
  is `rustls-tls` so no OpenSSL needed).
- **`pyo3` is not abi3** (`Cargo.toml`: `features = ["extension-module"]`, no
  `abi3-py3XX`), so the wheel is **Python-version-specific**. The rust-builder
  stage's Python **must match the runtime stage's Python**:
  - `Dockerfile`: everything is `python:3.12-slim` → cp312 wheel. Fine.
  - `Dockerfile.gpu`: runtime is Ubuntu 22.04 `python3` = **3.10**, glibc 2.35.
    The rust-builder **must also be the CUDA/Ubuntu-22.04 base** (not
    `python:3.10-slim`, which is Debian glibc 2.36 → `manylinux_2_36` wheel that
    won't install on glibc 2.35). That's why `Dockerfile.gpu` has three
    `FROM nvidia/cuda:...` stages.
- The maturin wheel filename's arch varies (`x86_64` in CI, `aarch64` on Apple
  Silicon) — the install globs `openjarvis_rust-*.whl`.
- `JARVIS_VERSION` is a **global `ARG`** (declared once before the first `FROM`,
  re-declared bare `ARG JARVIS_VERSION` in each stage that needs it) so the one
  Renovate-managed line drives every stage.

## Runtime image extras

Beyond the upstream package, the runtime stage adds:

- **`git`** — `jarvis skill` clones the skill-index repo (`github.com/openjarvis/skill-index.git`).
- **`curl`** — for the `HEALTHCHECK` (`GET /health`; that endpoint needs neither
  auth nor a reachable engine). `curl -f` exits non-zero on any failure, which
  is all HEALTHCHECK needs — kept as JSON exec form to satisfy hadolint DL3025.

Deliberately **not** added (not needed for `serve` / the `orchestrator` agent,
only bloat): Node.js (only `ClaudeCodeAgent` + WhatsApp Baileys bridge),
`faster-whisper`/`[speech]`, `torch`/`[dev]` SFT-GRPO training.

## Consuming side (infra repo)

Deployed by `infrastructure/home/share` → `ansible/roles/localai` as the
`ai_openjarvis` container (port `3700:8000`). That repo's `CLAUDE.md` documents
the config (`/root/.openjarvis/config.toml`), the `OPENJARVIS_API_KEY`
non-loopback-bind requirement, and the shared engine/MCP vars.
