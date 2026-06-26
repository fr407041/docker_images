# Claude Router Orchestrator

This repository focuses only on the `Claude Code + router -> child Claude Code + router` orchestration pattern.

It is designed to reduce token overflow risk by forcing narrow child jobs, limiting child creation, and recovering from bad worker behavior without killing the main orchestrator.

## Scope

Included:
- main Claude/router planning and child dispatch
- child count cap
- safe cleanup that only targets `child_*` processes
- overflow retry with smaller file scope
- `NEEDS_REPLAN` recovery
- timeout recovery
- false-success blocking
- repeated-replan loop guard
- Linux one-click bundle installer
- fresh Ubuntu Docker image smoke test

Excluded on purpose:
- Claude Code installation flow
- Claude Code Router installation flow
- router model setting changes
- open-source model selection flow

## Core scripts

- `scripts/orchestrate_claude_to_claude.sh`
- `scripts/run_claude_guarded.sh`
- `scripts/worker_claude_router.sh`
- `scripts/worker_claude_router_managed_single_file.sh`
- `scripts/claude_router_common.sh`
- `scripts/cleanup_claude_children.sh`

## Failure handling

- Overflow on multi-file child jobs:
  split into smaller retry jobs
- Too many child processes:
  block new child creation with `CLAUDE_MAX_CHILDREN`
- Broken child cleanup:
  cleanup only targets `child_*` registry entries and skips the main process
- Child timeout:
  watchdog terminates the child and lets the main orchestrator rewrite or stop safely
- Child says `SUCCESS` but changed nothing:
  worker downgrades the result to `FAILED`
- Child keeps asking for replan:
  main triggers `replan_loop_guard_hit` instead of infinite redispatch
- Planner returns bad JSON:
  main falls back to deterministic small-batch planning

## Linux bundle install

Assumption:
- target machine already has `bash`, `python3`, `jq`, `claude`, and router startup support

Install:

```bash
bash ./scripts/install_claude_router_orchestrator_bundle.sh /opt/claude_orchestrator
```

Run a minimal edit flow:

```bash
cd /opt/claude_orchestrator
bash ./scripts/orchestrate_claude_to_claude.sh \
  "Edit tests/test_placeholder.py so it contains a deterministic assertion assert 1 + 1 == 2 and keep the file minimal." \
  ./examples/hello-python
```

## Fresh-image smoke test

Build and validate the bundle in a fresh Ubuntu image:

```bash
bash ./scripts/smoke_bundle_in_fresh_image.sh
```

Run this from a Linux shell environment.
If you invoke this script directly from Windows PowerShell without a working local `bash` runtime, the host shell can fail before the Docker-based smoke test even starts.

The smoke test installs the bundle into a clean image and runs:
- single-file managed edit
- multi-round overflow recovery
- child limit protection
- fail-replan recovery
- timeout recovery
- bad planner fallback
- needs-replan recovery
- false-success blocking
- repeated-replan loop guard

## Real integration smoke test

Use this only on a Linux machine that already has a working `claude` CLI and an already-running Claude Code Router.

This test does not install Claude, does not install router, and does not rewrite router model settings.

```bash
bash ./scripts/smoke_real_claude_router_integration.sh
```

This script is also intended to be launched from Linux, or from inside a Linux container or VM that already has `bash`.

Optional:
- pass a custom project root as the first argument
- pass a custom task as the second argument
- set `CCR_HEALTH_URL` if your router health endpoint is not `http://127.0.0.1:3456/health`
- set `ALLOW_AUTOSTART=1` together with `START_CCR_BIN=/your/existing/router-start-command` if you explicitly want the script to start your already-configured router command

## Mock validation scripts

- `scripts/evaluate_claude_single_file.sh`
- `scripts/evaluate_claude_multi_round.sh`
- `scripts/evaluate_claude_child_limits.sh`
- `scripts/evaluate_claude_fail_replan.sh`
- `scripts/evaluate_claude_timeout_recovery.sh`
- `scripts/evaluate_claude_bad_planner.sh`
- `scripts/evaluate_claude_needs_replan.sh`
- `scripts/evaluate_claude_false_success_guard.sh`
- `scripts/evaluate_claude_replan_loop_guard.sh`

## Verified on 2026-06-25

Fresh Ubuntu Docker image validation completed for the Linux bundle with:
- successful bundle install into a new path
- multi-round mock orchestration execution
- bounded child creation
- safe child cleanup without killing main
- recovery from overflow, timeout, failure, false success, and repeated replan cases
