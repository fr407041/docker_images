# Shared Claude Code + Codex Local LLM Lab

This folder keeps the existing Claude Code + router image and extends it with Codex CLI.

It does not require modifying your global Claude Code, router, Node.js, npm, Docker Desktop, or WSL settings.

## What this image contains

- Ubuntu 22.04
- Node.js + npm
- Claude Code
- Claude Code Router
- Codex CLI
- Python 3 + pytest for a tiny validation repo

## Verified local-LLM path

The verified Codex path is:

- Codex CLI inside Docker
- Windows host Ollama service outside Docker
- OpenAI-compatible endpoint via `host.docker.internal`

Verified override set:

- `openai_base_url = "http://host.docker.internal:11434/v1"`
- `model_provider = "openai"`
- `model = "qwen3:4b"`
- `OPENAI_API_KEY=dummy-key`

This path is verified for:

- endpoint reachability
- Codex startup
- prompt/response execution through the local model
- loading a project-local `config.toml`

It is **not yet a reliable proof of high-quality agentic file editing** with the currently installed small local models.

## Important note about `--oss`

This Codex CLI version supports:

- `--oss`
- `--local-provider ollama`
- `--local-provider lmstudio`

However, in this shared-container topology, the directly verified working path is the OpenAI-compatible endpoint override above.

`--oss --local-provider ollama` may expect local/native Ollama detection instead of only a remote HTTP endpoint, so treat it as a secondary option here.

## Build

```powershell
docker build -t claude-ccr:ubuntu22 .\linux_remote\ubuntu22-claude-ccr
```

Or:

```powershell
cd .\linux_remote\ubuntu22-claude-ccr
docker compose build
```

## Environment check

```powershell
docker run --rm --add-host=host.docker.internal:host-gateway -v "${PWD}:/workspace" claude-ccr:ubuntu22 bash -lc "cd /workspace/linux_remote/ubuntu22-claude-ccr && bash ./scripts/check_env.sh"
```

## Test host Ollama endpoint from the container

```powershell
docker run --rm --add-host=host.docker.internal:host-gateway -v "${PWD}:/workspace" claude-ccr:ubuntu22 bash -lc "cd /workspace/linux_remote/ubuntu22-claude-ccr && bash ./scripts/test_llm_endpoint.sh ollama"
```

## Start Codex against the local OpenAI-compatible endpoint

Interactive:

```powershell
docker run --rm -it --add-host=host.docker.internal:host-gateway -e OPENAI_API_KEY=dummy-key -v "${PWD}:/workspace" claude-ccr:ubuntu22 bash -lc "cd /workspace/linux_remote/ubuntu22-claude-ccr && bash ./scripts/run_codex_openai_compat.sh"
```

Windows double-click launcher:

- `launch-docker-codex.cmd`
- `launch-docker-codex-guarded.cmd`

## Forced guarded mode for token overflow avoidance

If you want a stricter workflow for smaller local models, use:

- `scripts/run_codex_guarded.sh`
- `launch-docker-codex-guarded.cmd`

This mode forces:

- inventory first
- shortlist-first reading
- limited first-pass lines per file
- batch checkpoints before expansion

Example:

```powershell
docker run --rm -it --add-host=host.docker.internal:host-gateway -e OPENAI_API_KEY=dummy-key -v "${PWD}:/workspace" claude-ccr:ubuntu22 bash -lc "cd /workspace/linux_remote/ubuntu22-claude-ccr && bash ./scripts/run_codex_guarded.sh 'Inspect the hello-python repo and only shortlist the first files to edit'"
```

Important:

- this is the practical way to **force decomposition** before the local model expands scope
- it reduces token-overflow risk, but cannot absolutely guarantee zero overflow if the model ignores instructions or a single file is already huge
- for the strongest protection, keep tasks repo-local and explicitly name target folders or files

## Codex master -> Claude worker orchestration

You can also use Codex as the master planner and dispatch small jobs to Claude Code + router as the worker.

Scripts:

- `scripts/orchestrate_codex_to_claude.sh`
- `scripts/worker_claude_router.sh`
- `scripts/evaluate_orchestration.sh`
- `scripts/evaluate_worker_edit.sh`

Flow:

1. Codex reads only a compact inventory.
2. Codex outputs a small JSON job plan.
3. Each job is sent to Claude Code + router with a strict file limit.
4. If a worker reports overflow, the orchestrator retries by splitting that job into single-file jobs.
5. Edit jobs are rejected if the file hash does not actually change.
6. Python test-file jobs can auto-run `python3 -m pytest -q` for verification.

Example:

```bash
bash ./scripts/orchestrate_codex_to_claude.sh "Inspect hello-python and identify the smallest safe change" /workspace/linux_remote/ubuntu22-claude-ccr/hello-python
```

Quantified outputs:

- total files in scope
- compact inventory size
- planned jobs
- average files per job
- max files per job
- breadth reduction percent
- worker overflow count
- worker need-replan count
- worker jobs with verified file changes
- worker false-success blocks
- automatic overflow retry count

Quick evaluation:

```bash
bash ./scripts/evaluate_orchestration.sh
```

Direct worker edit verification:

```bash
bash ./scripts/evaluate_worker_edit.sh
```

## Project-local config examples

- `codex-config/config.toml.example`
  - Verified OpenAI-compatible local endpoint path
- `codex-config/config.oss.example.toml`
  - Example for native OSS mode, not the primary verified route in this Docker topology

## Small hello-python validation

The tiny test repo is under:

- `hello-python/`

The intended Codex task is:

1. Create `hello.py`
2. Add a pytest
3. Run `pytest`

Current result:

- Codex connectivity works
- the currently installed small local models (`qwen3:4b`, `qwen2.5-coder:3b`) are not yet reliable enough to consistently execute the file-editing tool workflow inside Codex
- they may produce a plausible textual summary without actually applying file changes

## Troubleshooting order

1. Confirm Windows host Ollama is running:
   - `http://127.0.0.1:11434/api/tags`
2. Confirm the container sees the host:
   - `bash ./scripts/test_llm_endpoint.sh ollama`
3. Confirm the model exists on the host:
   - `qwen3:4b`
4. If Codex fails in OSS mode, switch to the verified OpenAI-compatible override path.
5. If you see `405 Method Not Allowed` on `ws://.../v1/responses`, note that Codex can fall back from WebSocket transport to HTTPS with Ollama; this warning is expected in the current setup.
6. If `host.docker.internal` fails, use the Windows host LAN IP as a fallback and override `OPENAI_BASE_URL`.
