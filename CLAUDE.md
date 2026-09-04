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
(`# renovate: datasource=pypi depName=openjarvis`), declared in **both**
`Dockerfile.base`/`Dockerfile.base.gpu` (drives the Rust build) and
`Dockerfile`/`Dockerfile.gpu` (drives the `openjarvis[server]` pip install +
the frontend sdist fetch) — see the base image section below for why it's
in both places and how a mismatch between them is caught.

CI: `docker-ci.yml` template. `smoke_test: bash smoke_test.sh` — runs `test/`
(`node --test`) and then boots each built image and checks the web UI, the
randomUUID polyfill, the CSP, and `RUST_AVAILABLE` (see the plain-HTTP patches
section). Run it locally with `IMAGE=<tag> bash smoke_test.sh`.

## Base image split (`Dockerfile.base` / `Dockerfile.base.gpu`)

**Added 2026-09-04** because the release build (`docker-release.yml`) was
taking close to an hour — mostly the arm64 leg of `maturin build --release`
running under QEMU emulation, twice (plain + GPU image), on every release.

`Dockerfile.base` / `Dockerfile.base.gpu` contain **only** the Rust build
(the `rust-builder` stage) and export nothing but the compiled wheel: their
final stage is `FROM scratch` + `COPY --from=rust-builder /wheels /wheels`,
plus a `/wheels/JARVIS_VERSION` marker file recording which version they were
built against. `rust-builder` has a BuildKit `--mount=type=cache` for cargo's
registry + target dir so the weekly rebuild doesn't recompile every crate
(including rusqlite's bundled SQLite) from zero.

Everything else that used to be candidates for the base image - frontend
build, node-runtime's npm globals, the Python `openjarvis[server]` install,
patches, the CSP fix - **stays in `Dockerfile`/`Dockerfile.gpu`** and runs at
release time. They're fast enough (seconds to low tens of seconds, not
QEMU-emulated-Rust-release-compile slow) that hiding them behind the weekly
base cron wasn't worth two costs: the two-hop Renovate lag described below,
and the risk of a compiled Rust wheel silently drifting out of sync with a
newer PyPI release. Only the Rust compile - the one piece both genuinely slow
*and* safe to cache for a week - lives in the base.

`.github/workflows/release-base.yml` builds and pushes the base images -
weekly (Wed 01:30 UTC), on any push touching `Dockerfile.base*`/`patches/**`,
or manually - as `ghcr.io/m13tlabs/openjarvis-base` /
`docker.io/m13t/openjarvis-base`, tagged `<YYYY.MM.DD>[-gpu]` and
`latest[-gpu]`. It pushes no commits; Renovate discovers the new registry
tags itself.

`Dockerfile` / `Dockerfile.gpu` pull the wheel via `ARG BASE_VERSION`
(Renovate-bumped via `# renovate: datasource=docker
depName=ghcr.io/m13tlabs/openjarvis-base`; GPU's value already carries the
`-gpu` suffix since it's a distinct tag family) → `FROM
openjarvis-base:${BASE_VERSION} AS rust-wheel`, then do their own small
`sdist` stage (plain `pip download --no-binary openjarvis` + `tar` - no
compile, just needed for `frontend/`) before the frontend/node-runtime/Python
stages that used to live in the base.

**Version-skew guard**: since the wheel (base, built at whatever
`JARVIS_VERSION` was current then) and `openjarvis[server]` (installed fresh
here, at *this* build's `JARVIS_VERSION`) can now point at different
releases, the Python builder stage compares `/wheels/JARVIS_VERSION` against
its own `ARG JARVIS_VERSION` and **fails the build loudly** on a mismatch
rather than shipping a possibly ABI-incompatible `openjarvis_rust` /
`openjarvis[server]` pair. If you see that error: either bump `BASE_VERSION`
to a base built against the version you want, or trigger `release-base.yml`
to rebuild the base against the current `JARVIS_VERSION` first.

**Bootstrapping gotcha**: the base images don't exist until `release-base.yml`
has run at least once *against this design* - re-run it (`workflow_dispatch`)
whenever `Dockerfile.base`/`Dockerfile.base.gpu` change shape, before relying
on `ci.yml` or cutting a release, otherwise `Dockerfile`'s `COPY --from=rust-wheel
/wheels /wheels` fails with `"/wheels": not found` (that's exactly what an
image built from an older Dockerfile.base shape looks like). Also worth a
one-time check after the first push: the `openjarvis-base` GHCR package
should be public (matches this repo's visibility) so `docker-ci.yml`'s
unauthenticated build job can pull it.

Consequence for `JARVIS_VERSION` bumps: a Renovate PR bumping it in
`Dockerfile`/`Dockerfile.gpu` (the Python install / frontend sdist) lands and
can merge immediately - no base rebuild needed for that. Only a *Rust*-side
change (`rust/` workspace content, or wanting the wheel itself rebuilt
against a newer `JARVIS_VERSION`) needs `Dockerfile.base`/`Dockerfile.base.gpu`
bumped and a base rebuild before `BASE_VERSION` in the thin Dockerfiles is
worth bumping too - and until it is, the version-skew guard above fails the
build rather than shipping the mismatch silently.

Keep `Dockerfile.base` and `Dockerfile.base.gpu` in sync with each other, and
`Dockerfile`/`Dockerfile.gpu` in sync with each other, the same way the two
top-level Dockerfiles always needed to be - same stages, CUDA vs. slim bases.

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
workspace (17 crates) *and* the `frontend/` SPA source. Both Dockerfiles
download it once in `rust-builder` and the `frontend-builder` stage
`COPY --from=rust-builder /src/frontend`. So both Dockerfiles:

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

## The web UI (`frontend-builder` stage)

`jarvis serve` (`openjarvis/server/app.py`) mounts an SPA at `/` **only if
`openjarvis/server/static/` exists** — and the PyPI package doesn't ship it, so
without this stage `GET /` is a 404 (only `/dashboard` — a server-rendered
savings/telemetry page — and `/docs` work).

The sdist carries the SPA source under `frontend/` (Vite + React + PWA; its
`vite.config.ts` `outDir` is literally `../src/openjarvis/server/static`). The
`frontend-builder` stage (`node:22-slim`) does `npm ci` + `npx vite build
--outDir /static`, and the Python builder `cp`s that into the installed
package's `server/static/`. The build asserts `server/static/index.html` exists.

- **`npx vite build`, not `npm run build`** — the `build` script is `tsc -b &&
  vite build`; we skip `tsc -b` so a strict type error upstream can't fail the
  image. esbuild transpiles without it.
- The `@tauri-apps/*` deps are for the optional desktop shell; `isTauri()`
  gates them and the web build degrades gracefully (skips the desktop setup
  wizard, disables autostart/global-shortcut, etc.).
- `node:22-slim` in `frontend-builder` is JS-only and arch-independent — the
  same stage works for `Dockerfile` and `Dockerfile.gpu`.
- Chunk-size warning ("larger than 500 kB") is upstream and cosmetic.

### Plain-HTTP patches (the SPA assumes a secure context / permissive CSP)

OpenJarvis is an *on-device* assistant almost always reached over **plain HTTP
on a LAN hostname** (`http://share.box:3700`), not HTTPS. Several browser APIs
the SPA uses only exist in a
[secure context](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts)
(HTTPS / localhost). The build patches:

1. **`crypto.randomUUID is not a function` + broken copy buttons** —
   `frontend/src/lib/store.ts` calls `crypto.randomUUID()` at store-init → the
   whole app crashes on load; `navigator.clipboard` is `undefined` → the
   "copy" buttons throw on click. `frontend-builder` copies
   `patches/insecure-context-polyfill.js` into `frontend/public/` and `sed`s a
   classic `<script src=…>` into `<head>` (runs before the module bundle). It
   builds `crypto.randomUUID` from `crypto.getRandomValues` and
   `navigator.clipboard.writeText` from `document.execCommand('copy')` — both
   available in insecure contexts. (`crypto.subtle` in `analytics.ts` is also
   secure-context-only but it's `try/catch`ed and analytics is opt-in + off by
   default, so it degrades silently — not polyfilled.)
2. **CSP blocks the `data:` webfonts** — the server sends a hardcoded
   `Content-Security-Policy: default-src 'self' 'unsafe-inline' 'unsafe-eval'`
   (`openjarvis/server/middleware.py`, no config knob), and the built CSS
   embeds geist / KaTeX fonts as `data:` URIs. The Python builder `sed`s
   `font-src 'self' data:; img-src 'self' data:` onto that string.

Both are covered:
- `test/insecure-context-polyfill.test.mjs` — `node --test`, runs the polyfill
  in a VM context with `randomUUID` / `navigator.clipboard` removed and checks
  it produces unique well-formed v4 UUIDs, falls the clipboard back to
  `execCommand`, and doesn't clobber native impls.
- `smoke_test.sh` (the CI `smoke_test`) — boots the image (with `test/mock-ollama.py`
  as a fake engine so `serve` will start) and asserts: `/` serves the SPA, the
  polyfill script is served and precedes the app module in `index.html`, the
  CSP response header allows `data:` fonts/images, the shipped CSS actually
  still uses `data:` fonts (so the CSP check stays load-bearing), JS assets
  have a script content-type, and `RUST_AVAILABLE`.
- Both Dockerfiles also hard-assert all of the above at build time.

If either `sed` stops matching (upstream reformats `index.html` or
`middleware.py`), the build fails on the `grep -q` / assert rather than
silently shipping the bug.

## Runtime image extras

Beyond the upstream package, the runtime stage adds:

- **`git`** — `jarvis skill` clones the skill-index repo (`github.com/openjarvis/skill-index.git`).
- **`curl`** — for the `HEALTHCHECK` (`GET /health`; that endpoint needs neither
  auth nor a reachable engine). `curl -f` exits non-zero on any failure, which
  is all HEALTHCHECK needs — kept as JSON exec form to satisfy hadolint DL3025.
- **Node.js 22 + `mcp-remote` + `@baruchiro/paperless-mcp`** — see the MCP
  stdio section below.
- **`libstdc++6`** — the copied `node` binary links against it and
  `python:3.12-slim` doesn't ship it (the CUDA base does, but it's added there
  too for parity).

Deliberately **not** added (not needed for `serve` / the `orchestrator` agent,
only bloat): `faster-whisper`/`[speech]`, `torch`/`[dev]` SFT-GRPO training.
The frontend is prebuilt into `static/` at image-build time, so no Node is
needed to *serve* the UI — the Node in the runtime is purely for MCP stdio
servers (below).

## MCP stdio servers (Node.js in the runtime)

`jarvis serve` runs each entry in `config.toml`'s `[tools.mcp].servers` (a JSON
array) through `openjarvis/mcp/loader.py`: an entry with `url` → HTTP transport;
an entry with `command` → **`StdioTransport`, which `subprocess.Popen`s
`[command] + args`**. Our infra config (`infrastructure/home/share` →
`openjarvis_mcp`) uses stdio entries that shell out to npm packages, so the
runtime needs Node:

- **`node-runtime` stage** (`FROM node:22-bullseye-slim`) `npm install -g`s
  **`mcp-remote`** (`MCP_REMOTE_VERSION`, Renovate `datasource=npm`) — the
  GitLab MCP OAuth bridge — and **`@baruchiro/paperless-mcp`**
  (`PAPERLESS_MCP_VERSION`). The runtime stage copies just `/usr/local/bin/node`
  + `/usr/local/lib/node_modules` out of it and recreates the four bin symlinks
  we invoke (`npm`, `npx`, `mcp-remote`, `paperless-mcp`).
- **bullseye, not `node:22-slim`** — a bookworm (glibc 2.36) `node` binary
  won't run on `Dockerfile.gpu`'s Ubuntu-22.04 base (glibc 2.35). The bullseye
  binary (glibc 2.31) runs on both. Same class of bug as the Rust wheel's
  `manylinux_2_36` note above.
- **`patches/mcp-stdio-env.patch`** — upstream's loader reads `command`/`args`
  from each server entry but **ignores `env`**, and `StdioTransport` spawns the
  child with no `env=`. So an npx shim can't be handed its API token / base URL
  / CA path. The patch wires `cfg["env"]` → `StdioTransport(env=)` →
  `Popen(env={**os.environ, **cfg_env})`. Applied with `patch -p1` against the
  installed package in the Python builder stage; the build then asserts the new
  `env` kwarg exists, so an upstream refactor fails the build instead of
  silently dropping the feature. **`@baruchiro/paperless-mcp` v2 reads
  `PAPERLESS_URL` / `PAPERLESS_API_KEY` from the environment** (the old
  `paperless-mcp <url> <token>` positional form was v1, and the bare
  `paperless-mcp` npm name is unpublished — it's `@baruchiro/paperless-mcp`
  now), so without this patch the stdio paperless server can't work at all.
- **`mcp-remote` OAuth is still a headless problem** — it wants a browser for
  the consent step and a persistent `~/.mcp-auth` for the token. `--static-oauth-client-metadata`
  only covers client registration. First-run auth has to be done out of band and
  the token dir kept on a volume; nothing in this image solves that.
- Covered by `smoke_test.sh` ("Node.js + MCP stdio shims", "MCP stdio transport
  honours a per-server env") and the build-time asserts in both Dockerfiles.

## Consuming side (infra repo)

Deployed by `infrastructure/home/share` → `ansible/roles/localai` as the
`ai_openjarvis` container (port `3700:8000`). That repo's `CLAUDE.md` documents
the config (`/root/.openjarvis/config.toml`), the `OPENJARVIS_API_KEY`
non-loopback-bind requirement, and the shared engine/MCP vars.
