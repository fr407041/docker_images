#!/usr/bin/env bash
set -euo pipefail

ccr_default_run_dir() {
  printf '%s\n' "${CLAUDE_RUN_DIR:-/tmp/claude-orchestrator}"
}

ccr_registry_dir() {
  local run_dir="${1:?run_dir required}"
  printf '%s\n' "${run_dir}/processes"
}

ccr_start_if_enabled() {
  if [[ "${CCR_AUTOSTART:-1}" != "1" ]]; then
    return 0
  fi

  local start_bin="${START_CCR_BIN:-/usr/local/bin/start-ccr}"
  if [[ -x "$start_bin" ]]; then
    "$start_bin" >/dev/null
  fi
}

ccr_register_process() {
  local run_dir="${1:?run_dir required}"
  local role="${2:?role required}"
  local pid="${3:?pid required}"
  local job_id="${4:-}"
  local scope_path="${5:-}"
  local registry_dir
  registry_dir="$(ccr_registry_dir "$run_dir")"
  mkdir -p "$registry_dir"

  python3 - "$registry_dir" "$run_dir" "$role" "$pid" "$job_id" "$scope_path" <<'PY'
import json
import os
import sys
import time
from pathlib import Path

registry_dir = Path(sys.argv[1])
run_dir = sys.argv[2]
role = sys.argv[3]
pid = int(sys.argv[4])
job_id = sys.argv[5]
scope_path = sys.argv[6]

payload = {
    "run_dir": run_dir,
    "role": role,
    "pid": pid,
    "ppid": os.getppid(),
    "job_id": job_id,
    "scope_path": scope_path,
    "created_at": int(time.time()),
}

(registry_dir / f"{pid}.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY
}

ccr_unregister_process() {
  local run_dir="${1:?run_dir required}"
  local pid="${2:?pid required}"
  local metadata_file
  metadata_file="$(ccr_registry_dir "$run_dir")/${pid}.json"
  rm -f "$metadata_file"
}

ccr_register_main_process() {
  local run_dir="${1:?run_dir required}"
  local role="${2:-main_orchestrator}"
  local scope_path="${3:-}"
  ccr_register_process "$run_dir" "$role" "$$" "" "$scope_path"
}

ccr_count_active_children() {
  local run_dir="${1:?run_dir required}"
  local registry_dir
  registry_dir="$(ccr_registry_dir "$run_dir")"
  python3 - "$registry_dir" <<'PY'
import json
import os
import sys
from pathlib import Path

registry_dir = Path(sys.argv[1])
count = 0
for path in registry_dir.glob("*.json"):
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        continue
    role = str(payload.get("role", ""))
    pid = int(payload.get("pid", 0))
    if not role.startswith("child_"):
        continue
    if pid <= 0:
        continue
    try:
        os.kill(pid, 0)
    except OSError:
        continue
    count += 1
print(count)
PY
}

ccr_child_slot_available() {
  local run_dir="${1:?run_dir required}"
  local max_children="${2:?max_children required}"
  local active_children
  active_children="$(ccr_count_active_children "$run_dir")"
  if (( active_children >= max_children )); then
    return 1
  fi
  return 0
}

ccr_cleanup_problem_children() {
  local run_dir="${1:?run_dir required}"
  shift || true
  local registry_dir
  registry_dir="$(ccr_registry_dir "$run_dir")"

  python3 - "$registry_dir" "$run_dir" "$@" <<'PY'
import json
import os
import signal
import sys
import time
from pathlib import Path

registry_dir = Path(sys.argv[1])
run_dir = sys.argv[2]
keep = {int(item) for item in sys.argv[3:] if str(item).isdigit()}
current_pid = os.getpid()
current_ppid = os.getppid()
terminated = 0
skipped = 0

for path in registry_dir.glob("*.json"):
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        path.unlink(missing_ok=True)
        continue

    role = str(payload.get("role", ""))
    pid = int(payload.get("pid", 0))
    if pid <= 0:
        path.unlink(missing_ok=True)
        continue

    if pid in keep or pid in {current_pid, current_ppid}:
        skipped += 1
        continue

    if not role.startswith("child_"):
        skipped += 1
        continue

    try:
        os.kill(pid, 0)
    except OSError:
        path.unlink(missing_ok=True)
        continue

    try:
        os.kill(pid, signal.SIGTERM)
        deadline = time.time() + 2.0
        while time.time() < deadline:
            try:
                os.kill(pid, 0)
            except OSError:
                break
            time.sleep(0.1)
        else:
            os.kill(pid, signal.SIGKILL)
    except OSError:
        pass

    path.unlink(missing_ok=True)
    terminated += 1

print(json.dumps({"run_dir": run_dir, "terminated_children": terminated, "skipped_entries": skipped}))
PY
}

ccr_prune_stale_child_metadata() {
  local run_dir="${1:?run_dir required}"
  local registry_dir
  registry_dir="$(ccr_registry_dir "$run_dir")"

  python3 - "$registry_dir" <<'PY'
import json
import os
import sys
from pathlib import Path

registry_dir = Path(sys.argv[1])
removed = 0
for path in registry_dir.glob("*.json"):
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        path.unlink(missing_ok=True)
        removed += 1
        continue

    role = str(payload.get("role", ""))
    pid = int(payload.get("pid", 0))
    if not role.startswith("child_") or pid <= 0:
        continue

    try:
        os.kill(pid, 0)
    except OSError:
        path.unlink(missing_ok=True)
        removed += 1

print(removed)
PY
}

invoke_claude_router_prompt() {
  local run_dir="${1:?run_dir required}"
  local role="${2:?role required}"
  local output_file="${3:?output_file required}"
  local prompt="${4:?prompt required}"
  local job_id="${5:-}"
  local scope_path="${6:-}"
  local max_children="${CLAUDE_MAX_CHILDREN:-2}"
  local claude_bin="${CLAUDE_BIN:-claude}"
  local claude_bin_extra="${CLAUDE_BIN_EXTRA:-}"
  local model_alias="${CLAUDE_MODEL_ALIAS:-sonnet}"
  local permission_mode="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
  local timeout_sec="${CLAUDE_CHILD_TIMEOUT_SEC:-600}"
  local pid
  local exit_code=0
  local watchdog_pid=""
  local timeout_flag="${output_file}.timeout"

  mkdir -p "$(dirname "$output_file")"
  mkdir -p "$(ccr_registry_dir "$run_dir")"

  export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-local-test-key}"
  export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://127.0.0.1:3456}"
  export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"
  export DISABLE_PROMPT_CACHING="${DISABLE_PROMPT_CACHING:-1}"
  export API_TIMEOUT_MS="${API_TIMEOUT_MS:-600000}"

  if [[ "$role" == child_* ]]; then
    ccr_prune_stale_child_metadata "$run_dir" >/dev/null || true
    if ! ccr_child_slot_available "$run_dir" "$max_children"; then
      cat >"$output_file" <<EOF
STATUS: CHILD_LIMIT_REACHED
FILES:
TESTS: not-run
SUMMARY: child worker cap ${max_children} reached; refusing to start another Claude child for this run.
EOF
      return 79
    fi
  fi

  ccr_start_if_enabled

  local -a cmd
  cmd=("$claude_bin")
  if [[ -n "$claude_bin_extra" ]]; then
    cmd+=("$claude_bin_extra")
  fi
  cmd+=("--bare" "-p" "--model" "$model_alias" "--permission-mode" "$permission_mode" "--output-format" "text")
  if [[ -n "${CLAUDE_SETTINGS_PATH:-}" ]]; then
    cmd+=(--settings "$CLAUDE_SETTINGS_PATH")
  elif [[ -f ".claude/settings.docker.json" ]]; then
    cmd+=(--settings ".claude/settings.docker.json")
  fi
  cmd+=("$prompt")

  "${cmd[@]}" >"$output_file" 2>&1 &
  pid=$!
  ccr_register_process "$run_dir" "$role" "$pid" "$job_id" "$scope_path"

  rm -f "$timeout_flag"
  if [[ "$timeout_sec" != "0" ]]; then
    (
      sleep "$timeout_sec"
      if kill -0 "$pid" >/dev/null 2>&1; then
        : >"$timeout_flag"
        kill -TERM "$pid" >/dev/null 2>&1 || true
        sleep 2
        kill -0 "$pid" >/dev/null 2>&1 && kill -KILL "$pid" >/dev/null 2>&1 || true
      fi
    ) &
    watchdog_pid=$!
  fi

  set +e
  wait "$pid"
  exit_code=$?
  set -e

  if [[ -n "$watchdog_pid" ]]; then
    kill "$watchdog_pid" >/dev/null 2>&1 || true
    wait "$watchdog_pid" >/dev/null 2>&1 || true
  fi

  ccr_unregister_process "$run_dir" "$pid"
  if [[ -f "$timeout_flag" ]]; then
    if ! grep -Eq '^STATUS:\s*' "$output_file" 2>/dev/null; then
      cat >>"$output_file" <<EOF
STATUS: CHILD_TIMEOUT
FILES:
TESTS: not-run
SUMMARY: child Claude invocation timed out and was terminated by the watchdog.
EOF
    fi
    rm -f "$timeout_flag"
    return 124
  fi
  return "$exit_code"
}
