# openjarvis

[![CI](https://github.com/m13tLabs/openjarvis/actions/workflows/ci.yml/badge.svg)](https://github.com/m13tLabs/openjarvis/actions/workflows/ci.yml)
![Docker Pulls](https://img.shields.io/docker/pulls/m13t/openjarvis?link=https%3A%2F%2Fhub.docker.com%2Fr%2Fm13t%2Fopenjarvis)

Container image for **[OpenJarvis](https://open-jarvis.github.io/OpenJarvis/)** — *"Personal AI,
On Personal Devices."* — a local-first personal-AI backend from Stanford's Scaling Intelligence
Lab. It bundles the upstream [`openjarvis`](https://pypi.org/project/openjarvis/) PyPI package
(the `jarvis` CLI) and runs `jarvis serve`: an OpenAI-compatible HTTP API plus a web UI, with
built-in agents, memory, skills and MCP tool support.

This repo contains **only the Docker packaging** — no application code. On top of the upstream
package the image adds the pieces upstream doesn't ship in the wheel: the mandatory
`openjarvis_rust` native extension (compiled from the sdist), the pre-built web UI, plain-HTTP
compatibility patches, and a Node.js runtime with the `mcp-remote` / `paperless-mcp` MCP stdio
servers. See [CLAUDE.md](CLAUDE.md) for the build internals.

---

## Images & tags

| Registry | Image | Base | Notes |
|---|---|---|---|
| Docker Hub | `m13t/openjarvis` | `python:3.12-slim` | CPU |
| GHCR | `ghcr.io/m13tlabs/openjarvis` | `python:3.12-slim` | CPU |
| Docker Hub | `m13t/openjarvis:<tag>-gpu` | `nvidia/cuda:*-runtime-ubuntu22.04` | CUDA — run with `--gpus all` |
| GHCR | `ghcr.io/m13tlabs/openjarvis:<tag>-gpu` | `nvidia/cuda:*-runtime-ubuntu22.04` | CUDA |

Tags: `latest`, plus a semver tag per release (e.g. `0.1.3`). Every pushed image carries a
build provenance attestation. Multi-arch (`linux/amd64`, `linux/arm64`).

---

## Quick start

OpenJarvis needs an inference engine. The simplest is a local [Ollama](https://ollama.com/):

```sh
# 1. an engine with a model pulled
ollama serve &
ollama pull qwen2.5:7b

# 2. minimal config
mkdir -p ~/.openjarvis
cat > ~/.openjarvis/config.toml <<'EOF'
[engine]
default = "ollama"

[engine.ollama]
host = "http://host.docker.internal:11434"

[intelligence]
default_model = "qwen2.5:7b"
EOF

# 3. run
docker run -d --name openjarvis \
  -p 3700:8000 \
  -e OPENJARVIS_API_KEY=change-me \
  -v ~/.openjarvis:/root/.openjarvis \
  --add-host host.docker.internal:host-gateway \
  m13t/openjarvis:latest
```

Then open <http://localhost:3700> for the web UI, or call the API:

```sh
curl http://localhost:3700/v1/chat/completions \
  -H 'Authorization: Bearer change-me' \
  -H 'Content-Type: application/json' \
  -d '{"model": "qwen2.5:7b", "messages": [{"role": "user", "content": "hello"}]}'
```

> **`OPENJARVIS_API_KEY` is required** whenever the server binds to a non-loopback address
> (which it does in the container — `--host 0.0.0.0`). Requests then need
> `Authorization: Bearer $OPENJARVIS_API_KEY`.

---

## docker compose

```yaml
services:
  ollama:
    image: ollama/ollama:latest
    volumes:
      - ollama:/root/.ollama
    # for GPU: add a deploy.resources.reservations.devices nvidia block

  openjarvis:
    image: m13t/openjarvis:latest
    depends_on: [ollama]
    ports:
      - "3700:8000"
    environment:
      OPENJARVIS_API_KEY: ${OPENJARVIS_API_KEY:?set OPENJARVIS_API_KEY}
    volumes:
      - openjarvis:/root/.openjarvis        # config, memory DBs, state, skills
      - ./config.toml:/root/.openjarvis/config.toml:ro
      - mcp-auth:/root/.mcp-auth             # only if you use mcp-remote

volumes:
  ollama:
  openjarvis:
  mcp-auth:
```

With `config.toml` pointing the engine at the compose service:

```toml
[engine]
default = "ollama"

[engine.ollama]
host = "http://ollama:11434"

[intelligence]
default_model = "qwen2.5:7b"
```

---

## Configuration

### Files (all under `/root/.openjarvis`)

| Path | Purpose |
|---|---|
| `config.toml` | engine, model routing, tools, MCP servers, server settings |
| `*.db` / `.state/` | memory backends, agent state, background-task markers |
| `skills/` | skills installed via `jarvis skill` |

Mount the whole directory as a volume so memory and installed skills survive restarts. Mount
`config.toml` read-only on top if you keep it in version control.

### Environment variables

| Variable | Purpose |
|---|---|
| `OPENJARVIS_API_KEY` | **required** — bearer token for the HTTP API (non-loopback bind) |
| `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, … | credentials for cloud engines, if configured in `config.toml` |
| `NPM_CONFIG_CACHE` | preset to `/tmp/.npm` (MCP stdio servers) — override only if needed |

### Cloud / hybrid engine

OpenJarvis is local-first but can route to the cloud. Example `config.toml`:

```toml
[engine]
default = "openai"

[engine.openai]
base_url = "https://api.openai.com/v1"   # or any OpenAI-compatible endpoint
# reads OPENAI_API_KEY from the environment

[intelligence]
default_model = "gpt-4o-mini"
```

Full config reference: <https://open-jarvis.github.io/OpenJarvis/>

---

## GPU image

The `-gpu` tag builds the Rust extension against a CUDA / Ubuntu 22.04 base and runs on the GPU
when the NVIDIA Container Toolkit is present:

```sh
docker run -d --name openjarvis --gpus all \
  -p 3700:8000 \
  -e OPENJARVIS_API_KEY=change-me \
  -v ~/.openjarvis:/root/.openjarvis \
  m13t/openjarvis:latest-gpu
```

Note the model inference itself runs in your **engine** (e.g. Ollama), so point Ollama at the
GPU too — the OpenJarvis GPU build only matters for its own on-device compute (embeddings,
retrieval, local model ops).

---

## HTTP endpoints

| Endpoint | Auth | Purpose |
|---|---|---|
| `GET /` | – | web UI (SPA) |
| `GET /health` | – | health check (used by the container `HEALTHCHECK`) |
| `GET /dashboard` | – | server-rendered savings / telemetry page |
| `GET /docs` | – | API docs |
| `POST /v1/chat/completions` | bearer | OpenAI-compatible chat |
| `GET /v1/models` | bearer | list models |

The image ships a `HEALTHCHECK` hitting `/health`; `docker ps` shows `healthy` once the server
is up (allow ~30 s).

---

## MCP tool servers

`jarvis serve` starts the MCP servers listed under `[tools.mcp]` in `config.toml`. HTTP
transports work out of the box; **stdio** transports spawn a local command, so this image
pre-installs Node.js 22 plus:

- **`mcp-remote`** — OAuth bridge for remote MCP servers (e.g. GitLab). First-run consent needs
  a browser and a persisted `~/.mcp-auth` — do the auth out of band and keep that directory on
  a volume.
- **`@baruchiro/paperless-mcp`** — paperless-ngx integration; reads `PAPERLESS_URL` /
  `PAPERLESS_API_KEY`.

Per-server `env` is honoured (upstream ignores it — this image patches it in), so a stdio entry
can be handed its own token / base URL:

```toml
[tools.mcp]
enabled = true
servers = [
  { command = "paperless-mcp", env = { PAPERLESS_URL = "http://paperless:8000", PAPERLESS_API_KEY = "…" } },
]
```

---

## Building locally

```sh
docker build -t openjarvis:dev .                     # CPU
docker build -t openjarvis:dev-gpu -f Dockerfile.gpu .   # CUDA

# smoke test a built image
IMAGE=openjarvis:dev bash smoke_test.sh
```

The Rust extension compiles from the upstream sdist during the build (~1–2 min). The pinned
upstream version is the `JARVIS_VERSION` ARG (bumped by Renovate); `config.json` is this repo's
own release version, bumped by the `Release` workflow.

---

## Links

- OpenJarvis docs — <https://open-jarvis.github.io/OpenJarvis/>
- OpenJarvis project — <https://scalingintelligence.stanford.edu/blogs/openjarvis/>
- Upstream source — <https://github.com/open-jarvis/OpenJarvis>

## License

The Docker packaging in this repo is MIT. Upstream OpenJarvis is
[Apache 2.0](https://github.com/open-jarvis/OpenJarvis/blob/main/LICENSE).
