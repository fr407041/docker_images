#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/claude_router_common.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TASK="${1:?Usage: orchestrate_claude_to_claude.sh <task> [scope_path]}"
SCOPE_PATH="${2:-${REPO_ROOT}}"
MAX_FILES_PER_JOB="${ORCH_MAX_FILES_PER_JOB:-2}"
MAX_JOBS="${ORCH_MAX_JOBS:-3}"
INVENTORY_LIMIT="${ORCH_INVENTORY_LIMIT:-12}"
EXECUTE_WORKERS="${ORCH_EXECUTE_WORKERS:-1}"
WORKER_MODE="${ORCH_WORKER_MODE:-auto}"
MAX_CHILD_INVOCATIONS="${ORCH_MAX_CHILD_INVOCATIONS:-6}"
MAX_RETRIES_PER_JOB="${ORCH_MAX_RETRIES_PER_JOB:-2}"
MAX_FAIL_REPLANS_PER_JOB="${ORCH_MAX_FAIL_REPLANS_PER_JOB:-1}"
RUN_ROOT="${ORCH_RUN_ROOT:-${REPO_ROOT}/orchestrator-claude}"
RUN_ID="${ORCH_RUN_ID:-run-$(date +%Y%m%d-%H%M%S)}"
RUN_DIR="${RUN_ROOT}/${RUN_ID}"
JOBS_DIR="${RUN_DIR}/jobs"
RESULTS_DIR="${RUN_DIR}/results"
mkdir -p "$JOBS_DIR" "$RESULTS_DIR"

export CLAUDE_RUN_DIR="$RUN_DIR"

cleanup_children() {
  bash "${SCRIPT_DIR}/cleanup_claude_children.sh" "$RUN_DIR" "$$" "${PPID:-0}" >/dev/null 2>&1 || true
  ccr_unregister_process "$RUN_DIR" "$$" >/dev/null 2>&1 || true
}

ensure_status_file() {
  local job_file="${1:?job_file required}"
  local status_file="${2:?status_file required}"
  if [[ -f "$status_file" ]]; then
    return 0
  fi

  local result_prefix="${status_file%.status.json}"
  local raw_file="${result_prefix}.raw.txt"
  local exec_log_file="${result_prefix}.exec.log"

  python3 - "$job_file" "$status_file" "$raw_file" "$exec_log_file" <<'PY'
import json
import sys
from pathlib import Path

job_path = Path(sys.argv[1])
status_path = Path(sys.argv[2])
raw_path = Path(sys.argv[3])
log_path = Path(sys.argv[4])

job = json.loads(job_path.read_text(encoding="utf-8"))
raw = raw_path.read_text(encoding="utf-8", errors="ignore") if raw_path.exists() else ""
log = log_path.read_text(encoding="utf-8", errors="ignore") if log_path.exists() else ""
combined = "\n".join([raw, log])

status = "FAILED"
note = "worker exited before writing a status file"
if "CHILD_TIMEOUT" in combined:
    status = "CHILD_TIMEOUT"
    note = "worker timed out before writing status metadata"
elif "CHILD_LIMIT_REACHED" in combined:
    status = "CHILD_LIMIT_REACHED"
    note = "worker hit the child limit before writing status metadata"
elif "OVERFLOW_DETECTED" in combined or "maximum context length" in combined or "output tokens" in combined or "context window" in combined:
    status = "OVERFLOW_DETECTED"
    note = "worker overflowed before writing status metadata"
elif "NEEDS_REPLAN" in combined:
    status = "NEEDS_REPLAN"
    note = "worker requested replan before writing status metadata"

payload = {
    "id": job.get("id", status_path.stem),
    "status": status,
    "scope_path": job.get("scope_path", ""),
    "require_change": job.get("require_change", False),
    "files": job.get("files", []),
    "actual_changed_files": [],
    "actual_changed_count": 0,
    "verification_note": note,
    "raw_file": str(raw_path),
    "exec_log_file": str(log_path),
    "success_check": job.get("success_check", ""),
    "test_command": job.get("test_command", ""),
    "test_executed_command": "",
    "test_output_file": f"{status_path.with_suffix('').with_suffix('')}.test.txt",
    "test_exit_code": 0,
    "exit_code": 1,
    "duration_sec": 0,
}
status_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY
}

create_replan_job() {
  local source_job_file="${1:?source_job_file required}"
  local jobs_dir="${2:?jobs_dir required}"
  local suffix="${3:?suffix required}"
  local hint_prefix="${4:?hint_prefix required}"

  python3 - "$source_job_file" "$jobs_dir" "$suffix" "$hint_prefix" <<'PY'
import json
import sys
from pathlib import Path

job_path = Path(sys.argv[1])
jobs_dir = Path(sys.argv[2])
suffix = sys.argv[3]
hint_prefix = sys.argv[4]

job = json.loads(job_path.read_text(encoding="utf-8"))
files = list(job.get("files", []))
instruction = str(job.get("instruction", ""))
success_check = str(job.get("success_check", "Return a concise result."))
instruction_lower = instruction.lower()
success_lower = success_check.lower()

narrowed_files = [path for path in files if str(path).lower() in instruction_lower or str(path).lower() in success_lower]
if not narrowed_files:
    narrowed_files = files[:1] if files else []
if len(narrowed_files) > 1:
    narrowed_files = narrowed_files[:1]

replan_instruction = (
    f"{hint_prefix}\n\n"
    f"Original instruction:\n{instruction}"
)
payload = {
    "id": f"{job['id']}-{suffix}",
    "scope_path": job.get("scope_path"),
    "title": f"{job.get('title', job['id'])} {suffix}",
    "instruction": replan_instruction,
    "files": narrowed_files,
    "success_check": success_check,
    "require_change": job.get("require_change", False),
    "test_command": job.get("test_command", ""),
    "force_worker_mode": "managed_single_file" if len(narrowed_files) == 1 else "auto",
}
(jobs_dir / f"{payload['id']}.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY
}

ccr_register_main_process "$RUN_DIR" "main_orchestrator" "$SCOPE_PATH"
trap cleanup_children EXIT

cd "${REPO_ROOT}"

INVENTORY_FILE="${RUN_DIR}/inventory.txt"
COMPACT_FILE="${RUN_DIR}/inventory.compact.txt"
PLAN_RAW_FILE="${RUN_DIR}/planner.raw.txt"
PLAN_JSON_FILE="${RUN_DIR}/plan.json"
SUMMARY_FILE="${RUN_DIR}/summary.json"

python3 - "$SCOPE_PATH" <<'PY' >"$INVENTORY_FILE"
import os
import sys

scope = sys.argv[1]
if not os.path.isabs(scope):
    scope = os.path.abspath(scope)

skip_dirs = {
    ".git", ".hg", ".svn", "node_modules", ".venv", "venv",
    "__pycache__", ".mypy_cache", ".pytest_cache", ".next", "dist", "build",
    "orchestrator", "orchestrator-claude", "orchestrator-codex"
}
allowed_ext = {
    ".py", ".js", ".ts", ".tsx", ".jsx", ".json", ".md", ".yml", ".yaml",
    ".sh", ".ps1", ".toml", ".ini", ".cfg", ".txt"
}

for root, dirs, files in os.walk(scope):
    dirs[:] = [d for d in dirs if d not in skip_dirs]
    for name in sorted(files):
        path = os.path.join(root, name)
        rel = os.path.relpath(path, scope)
        _, ext = os.path.splitext(name)
        if ext.lower() in allowed_ext or name in {"Dockerfile", "Makefile"}:
            print(rel.replace("\\", "/"))
PY

TOTAL_FILES="$(wc -l <"$INVENTORY_FILE" | tr -d ' ')"
head -n "$INVENTORY_LIMIT" "$INVENTORY_FILE" >"$COMPACT_FILE"
COMPACT_COUNT="$(wc -l <"$COMPACT_FILE" | tr -d ' ')"

DIRECT_PLAN_GENERATED=1
python3 - "$TASK" "$INVENTORY_FILE" "$PLAN_JSON_FILE" <<'PY' || DIRECT_PLAN_GENERATED=0
import json
import sys
from pathlib import Path

task = sys.argv[1]
inventory_file = Path(sys.argv[2])
plan_file = Path(sys.argv[3])

inventory = [line.strip() for line in inventory_file.read_text(encoding="utf-8").splitlines() if line.strip()]
task_lower = task.lower()
edit_hints = ("fix", "implement", "add", "update", "replace", "modify", "edit", "write", "create", "change", "refactor")

if not any(hint in task_lower for hint in edit_hints):
    sys.exit(1)

matches = []
for rel in inventory:
    rel_lower = rel.lower()
    name_lower = Path(rel).name.lower()
    if rel_lower in task_lower or name_lower in task_lower:
        matches.append(rel)

deduped = []
seen = set()
for item in matches:
    if item not in seen:
        deduped.append(item)
        seen.add(item)

if len(deduped) != 1:
    sys.exit(1)

data = {
    "strategy": "Deterministic single-file managed edit because the task explicitly names one target file.",
    "jobs": [
        {
            "title": f"Managed single-file edit for {deduped[0]}",
            "instruction": task,
            "files": [deduped[0]],
            "success_check": f"{deduped[0]} is updated exactly as requested and validation passes."
        }
    ]
}

plan_file.write_text(json.dumps(data, indent=2), encoding="utf-8")
PY

PLANNER_PROMPT="$(cat <<EOF
You are the main planner for a Claude Code + router orchestration system.

Goal:
Split the user task into at most ${MAX_JOBS} very small child Claude jobs.

Rules:
- Output JSON only.
- Each job may reference at most ${MAX_FILES_PER_JOB} files.
- Prefer the smallest safe batches for low-context execution.
- Use only files from the provided inventory.
- Never ask a child to read an entire folder.
- If the task is broad, create investigation jobs before edit jobs.
- Keep each instruction concise and executable.
- Assume child count is capped and retries are limited, so avoid wasteful job fan-out.

User task:
${TASK}

Scope path:
${SCOPE_PATH}

Inventory sample (${COMPACT_COUNT} of ${TOTAL_FILES} files):
$(cat "$COMPACT_FILE")

Return this exact schema:
{
  "strategy": "one short sentence",
  "jobs": [
    {
      "title": "short title",
      "instruction": "specific worker instruction",
      "files": ["path1", "path2"],
      "success_check": "specific success condition"
    }
  ]
}
EOF
)"

PLANNER_EXIT=0
PLANNER_PARSE_OK=0

if [[ "$DIRECT_PLAN_GENERATED" = "0" ]]; then
  set +e
  bash "${SCRIPT_DIR}/run_claude_guarded.sh" "$PLANNER_PROMPT" >"$PLAN_RAW_FILE" 2>&1
  PLANNER_EXIT=$?
  set -e

  set +e
  python3 - "$PLAN_RAW_FILE" "$PLAN_JSON_FILE" "$MAX_FILES_PER_JOB" "$MAX_JOBS" <<'PY'
import json
import sys
from pathlib import Path

raw_path, out_path, max_files, max_jobs = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
text = Path(raw_path).read_text(encoding="utf-8", errors="ignore")

decoder = json.JSONDecoder()
candidates = []
for start, ch in enumerate(text):
    if ch != "{":
        continue
    try:
        obj, end = decoder.raw_decode(text[start:])
    except json.JSONDecodeError:
        continue
    if isinstance(obj, dict) and isinstance(obj.get("jobs"), list) and obj["jobs"]:
        candidates.append(obj)

if not candidates:
    sys.exit(1)

data = candidates[-1]
data["jobs"] = data["jobs"][:max_jobs]
for job in data["jobs"]:
    files = job.get("files", [])
    if not isinstance(files, list) or not files:
        sys.exit(1)
    job["files"] = files[:max_files]

Path(out_path).write_text(json.dumps(data, indent=2), encoding="utf-8")
PY
  PLANNER_PARSE_OK=$?
  set -e
fi

if [[ "$PLANNER_PARSE_OK" -ne 0 || ! -s "$PLAN_JSON_FILE" ]]; then
  python3 - "$COMPACT_FILE" "$PLAN_JSON_FILE" "$MAX_FILES_PER_JOB" "$MAX_JOBS" "$TASK" <<'PY'
import json
import sys
from pathlib import Path

compact_file, out_file, max_files, max_jobs, task = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
files = [line.strip() for line in Path(compact_file).read_text(encoding="utf-8").splitlines() if line.strip()]
files = files[:max_files * max_jobs]
jobs = []
for index in range(0, len(files), max_files):
    chunk = files[index:index + max_files]
    job_no = len(jobs) + 1
    jobs.append({
        "title": f"Fallback batch {job_no}",
        "instruction": f"{task} Limit work strictly to the assigned files and summarize concise findings first.",
        "files": chunk,
        "success_check": "Return a concise result for only the assigned files."
    })
data = {
    "strategy": "Fallback deterministic batching because planner JSON was unavailable.",
    "jobs": jobs[:max_jobs]
}
Path(out_file).write_text(json.dumps(data, indent=2), encoding="utf-8")
PY
fi

INITIAL_JOB_COUNT="$(python3 - "$PLAN_JSON_FILE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(len(data.get("jobs", [])))
PY
)"

python3 - "$PLAN_JSON_FILE" "$JOBS_DIR" "$SCOPE_PATH" "$INVENTORY_FILE" <<'PY'
import json
import sys
from pathlib import Path

EDIT_HINTS = (
    "fix", "implement", "add", "update", "replace", "modify",
    "edit", "write", "create", "change", "refactor"
)

def requires_change(text: str) -> bool:
    lowered = text.lower()
    return any(hint in lowered for hint in EDIT_HINTS)

def normalize_files(files, inventory_paths):
    normalized = []
    inventory_set = set(inventory_paths)
    basename_map = {}
    for path in inventory_paths:
        basename_map.setdefault(Path(path).name, []).append(path)

    for raw in files:
        candidate = str(raw).replace("\\", "/").strip()
        if candidate in inventory_set:
            normalized.append(candidate)
            continue
        trimmed = candidate.lstrip("./")
        if trimmed in inventory_set:
            normalized.append(trimmed)
            continue
        basename = Path(candidate).name
        matches = basename_map.get(basename, [])
        if len(matches) == 1:
            normalized.append(matches[0])
    deduped = []
    seen = set()
    for item in normalized:
        if item not in seen:
            deduped.append(item)
            seen.add(item)
    return deduped

def infer_test_command(files, scope_path: str) -> str:
    scope = Path(scope_path)
    has_pyproject = (scope / "pyproject.toml").exists()
    if not has_pyproject:
        return ""
    if files and all(path.startswith("tests/") and path.endswith(".py") for path in files):
        return "python3 -m pytest -q"
    return ""

plan_path, jobs_dir, scope_path, inventory_file = sys.argv[1], Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
inventory_paths = [line.strip() for line in inventory_file.read_text(encoding="utf-8").splitlines() if line.strip()]
data = json.loads(Path(plan_path).read_text(encoding="utf-8"))
for idx, job in enumerate(data.get("jobs", []), start=1):
    instruction = job["instruction"]
    success_check = job.get("success_check", "Return a concise result.")
    files = normalize_files(job.get("files", []), inventory_paths)
    if not files:
        continue
    payload = {
        "id": f"job-{idx:03d}",
        "scope_path": scope_path,
        "title": job["title"],
        "instruction": instruction,
        "files": files,
        "success_check": success_check,
        "require_change": requires_change(instruction) or requires_change(success_check),
        "test_command": infer_test_command(files, scope_path)
    }
    (jobs_dir / f"job-{idx:03d}.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY

WORKERS_RUN=0
WORKERS_OVERFLOWED=0
WORKERS_FAILED=0
WORKERS_NEED_REPLAN=0
WORKERS_WITH_VERIFIED_CHANGES=0
WORKERS_FALSE_SUCCESS_BLOCKED=0
WORKERS_CHILD_LIMIT_BLOCKED=0
WORKERS_TIMED_OUT=0
OVERFLOW_RETRIES=0
CHILD_INVOCATION_LIMIT_HIT=0
FAIL_REPLAN_ATTEMPTS=0
WORKERS_FAILED_REPLANNED=0
REPLAN_LOOP_GUARD_HIT=0

if [[ "$EXECUTE_WORKERS" = "1" ]]; then
  for job_file in "$JOBS_DIR"/job-*.json; do
    [[ -f "$job_file" ]] || continue

    if (( WORKERS_RUN >= MAX_CHILD_INVOCATIONS )); then
      CHILD_INVOCATION_LIMIT_HIT=1
      break
    fi

    WORKERS_RUN=$((WORKERS_RUN + 1))
    require_change="$(jq -r '.require_change // false' "$job_file")"
    file_count="$(jq '.files | length' "$job_file")"
    worker_script="${SCRIPT_DIR}/worker_claude_router.sh"
    if [[ "$WORKER_MODE" = "managed_single_file" ]]; then
      worker_script="${SCRIPT_DIR}/worker_claude_router_managed_single_file.sh"
    elif [[ "$WORKER_MODE" = "auto" && "$require_change" = "true" && "$file_count" -eq 1 ]]; then
      worker_script="${SCRIPT_DIR}/worker_claude_router_managed_single_file.sh"
    fi

    bash "$worker_script" "$job_file" >/dev/null || true
    status_file="${RESULTS_DIR}/$(basename "${job_file%.json}").status.json"
    ensure_status_file "$job_file" "$status_file"
    job_status="$(jq -r '.status' "$status_file")"
    actual_changed_count="$(jq -r '.actual_changed_count // 0' "$status_file")"
    verification_note="$(jq -r '.verification_note // empty' "$status_file")"

    if [[ "$actual_changed_count" -gt 0 ]]; then
      WORKERS_WITH_VERIFIED_CHANGES=$((WORKERS_WITH_VERIFIED_CHANGES + 1))
    fi
    if [[ "$verification_note" = "claimed success without verified file change" && "$job_status" = "FAILED" ]]; then
      WORKERS_FALSE_SUCCESS_BLOCKED=$((WORKERS_FALSE_SUCCESS_BLOCKED + 1))
    fi

    if [[ "$job_status" = "CHILD_LIMIT_REACHED" ]]; then
      WORKERS_CHILD_LIMIT_BLOCKED=$((WORKERS_CHILD_LIMIT_BLOCKED + 1))
    elif [[ "$job_status" = "OVERFLOW_DETECTED" ]]; then
      WORKERS_OVERFLOWED=$((WORKERS_OVERFLOWED + 1))
      if [[ "$file_count" -gt 1 && "$OVERFLOW_RETRIES" -lt "$MAX_RETRIES_PER_JOB" ]]; then
        OVERFLOW_RETRIES=$((OVERFLOW_RETRIES + 1))
        python3 - "$job_file" "$JOBS_DIR" <<'PY'
import json
import sys
from pathlib import Path

job_path = Path(sys.argv[1])
jobs_dir = Path(sys.argv[2])
job = json.loads(job_path.read_text(encoding="utf-8"))
base_id = job["id"]
instruction_lower = str(job.get("instruction", "")).lower()
success_lower = str(job.get("success_check", "")).lower()
retry_files = []
for file_path in job["files"]:
    file_lower = str(file_path).lower()
    if file_lower in instruction_lower or file_lower in success_lower:
        retry_files.append(file_path)
if not retry_files:
    retry_files = list(job["files"])

for idx, file_path in enumerate(retry_files, start=1):
    payload = {
        "id": f"{base_id}-retry-{idx:02d}",
        "scope_path": job.get("scope_path"),
        "title": f"{job['title']} retry {idx}",
        "instruction": job["instruction"],
        "files": [file_path],
        "success_check": job.get("success_check", "Return a concise result."),
        "require_change": job.get("require_change", False),
        "test_command": job.get("test_command", "")
    }
    (jobs_dir / f"{payload['id']}.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY
        for retry_job in "$JOBS_DIR"/"$(basename "${job_file%.json}")"-retry-*.json; do
          [[ -f "$retry_job" ]] || continue
          if (( WORKERS_RUN >= MAX_CHILD_INVOCATIONS )); then
            CHILD_INVOCATION_LIMIT_HIT=1
            break
          fi
          WORKERS_RUN=$((WORKERS_RUN + 1))
          retry_require_change="$(jq -r '.require_change // false' "$retry_job")"
          retry_file_count="$(jq '.files | length' "$retry_job")"
          retry_worker_script="${SCRIPT_DIR}/worker_claude_router.sh"
          if [[ "$WORKER_MODE" = "managed_single_file" ]]; then
            retry_worker_script="${SCRIPT_DIR}/worker_claude_router_managed_single_file.sh"
          elif [[ "$WORKER_MODE" = "auto" && "$retry_require_change" = "true" && "$retry_file_count" -eq 1 ]]; then
            retry_worker_script="${SCRIPT_DIR}/worker_claude_router_managed_single_file.sh"
          fi

          bash "$retry_worker_script" "$retry_job" >/dev/null || true
          retry_status_file="${RESULTS_DIR}/$(basename "${retry_job%.json}").status.json"
          ensure_status_file "$retry_job" "$retry_status_file"
          retry_status="$(jq -r '.status' "$retry_status_file")"
          retry_changed_count="$(jq -r '.actual_changed_count // 0' "$retry_status_file")"
          retry_verification_note="$(jq -r '.verification_note // empty' "$retry_status_file")"

          if [[ "$retry_changed_count" -gt 0 ]]; then
            WORKERS_WITH_VERIFIED_CHANGES=$((WORKERS_WITH_VERIFIED_CHANGES + 1))
          fi
          if [[ "$retry_verification_note" = "claimed success without verified file change" && "$retry_status" = "FAILED" ]]; then
            WORKERS_FALSE_SUCCESS_BLOCKED=$((WORKERS_FALSE_SUCCESS_BLOCKED + 1))
          fi
          if [[ "$retry_status" = "CHILD_LIMIT_REACHED" ]]; then
            WORKERS_CHILD_LIMIT_BLOCKED=$((WORKERS_CHILD_LIMIT_BLOCKED + 1))
          elif [[ "$retry_status" = "OVERFLOW_DETECTED" ]]; then
            WORKERS_OVERFLOWED=$((WORKERS_OVERFLOWED + 1))
          elif [[ "$retry_status" = "FAILED" ]]; then
            WORKERS_FAILED=$((WORKERS_FAILED + 1))
          elif [[ "$retry_status" = "NEEDS_REPLAN" ]]; then
            WORKERS_NEED_REPLAN=$((WORKERS_NEED_REPLAN + 1))
          fi
        done
      fi
    elif [[ "$job_status" = "NEEDS_REPLAN" ]]; then
      WORKERS_NEED_REPLAN=$((WORKERS_NEED_REPLAN + 1))
      if [[ "$require_change" = "true" && "$MAX_FAIL_REPLANS_PER_JOB" -gt 0 ]]; then
        FAIL_REPLAN_ATTEMPTS=$((FAIL_REPLAN_ATTEMPTS + 1))
        create_replan_job \
          "$job_file" \
          "$JOBS_DIR" \
          "needs-replan-01" \
          "REPLAN_HINT: the previous child Claude attempt requested a narrower plan. Do not repeat the same broad approach. Shrink scope to the smallest safe file set and return the minimum viable result."
        replan_job="${JOBS_DIR}/$(basename "${job_file%.json}")-needs-replan-01.json"
        if [[ -f "$replan_job" ]]; then
          if (( WORKERS_RUN >= MAX_CHILD_INVOCATIONS )); then
            CHILD_INVOCATION_LIMIT_HIT=1
            REPLAN_LOOP_GUARD_HIT=1
          else
            WORKERS_RUN=$((WORKERS_RUN + 1))
            replan_file_count="$(jq '.files | length' "$replan_job")"
            forced_mode="$(jq -r '.force_worker_mode // "auto"' "$replan_job")"
            replan_worker_script="${SCRIPT_DIR}/worker_claude_router.sh"
            if [[ "$forced_mode" = "managed_single_file" || "$replan_file_count" -eq 1 ]]; then
              replan_worker_script="${SCRIPT_DIR}/worker_claude_router_managed_single_file.sh"
            fi
            bash "$replan_worker_script" "$replan_job" >/dev/null || true
            replan_status_file="${RESULTS_DIR}/$(basename "${replan_job%.json}").status.json"
            ensure_status_file "$replan_job" "$replan_status_file"
            replan_status="$(jq -r '.status' "$replan_status_file")"
            replan_changed_count="$(jq -r '.actual_changed_count // 0' "$replan_status_file")"
            if [[ "$replan_changed_count" -gt 0 ]]; then
              WORKERS_WITH_VERIFIED_CHANGES=$((WORKERS_WITH_VERIFIED_CHANGES + 1))
            fi
            if [[ "$replan_status" = "CHILD_LIMIT_REACHED" ]]; then
              WORKERS_CHILD_LIMIT_BLOCKED=$((WORKERS_CHILD_LIMIT_BLOCKED + 1))
              REPLAN_LOOP_GUARD_HIT=1
            elif [[ "$replan_status" = "CHILD_TIMEOUT" ]]; then
              WORKERS_TIMED_OUT=$((WORKERS_TIMED_OUT + 1))
              WORKERS_FAILED=$((WORKERS_FAILED + 1))
              REPLAN_LOOP_GUARD_HIT=1
            elif [[ "$replan_status" = "OVERFLOW_DETECTED" ]]; then
              WORKERS_OVERFLOWED=$((WORKERS_OVERFLOWED + 1))
              REPLAN_LOOP_GUARD_HIT=1
            elif [[ "$replan_status" = "NEEDS_REPLAN" ]]; then
              REPLAN_LOOP_GUARD_HIT=1
            elif [[ "$replan_status" = "FAILED" ]]; then
              WORKERS_FAILED=$((WORKERS_FAILED + 1))
              REPLAN_LOOP_GUARD_HIT=1
            fi
          fi
        else
          WORKERS_FAILED=$((WORKERS_FAILED + 1))
          REPLAN_LOOP_GUARD_HIT=1
        fi
      fi
    elif [[ "$job_status" = "FAILED" || "$job_status" = "CHILD_TIMEOUT" ]]; then
      if [[ "$job_status" = "CHILD_TIMEOUT" ]]; then
        WORKERS_TIMED_OUT=$((WORKERS_TIMED_OUT + 1))
      fi
      if [[ "$require_change" = "true" && "$MAX_FAIL_REPLANS_PER_JOB" -gt 0 ]]; then
        FAIL_REPLAN_ATTEMPTS=$((FAIL_REPLAN_ATTEMPTS + 1))
        WORKERS_FAILED_REPLANNED=$((WORKERS_FAILED_REPLANNED + 1))
        create_replan_job \
          "$job_file" \
          "$JOBS_DIR" \
          "fail-replan-01" \
          "REPLAN_HINT: the previous child Claude attempt failed. Do not repeat the same broad approach. Narrow scope aggressively, work only on the listed file, and return the smallest safe result."
        replan_job="${JOBS_DIR}/$(basename "${job_file%.json}")-fail-replan-01.json"
        if [[ -f "$replan_job" && "$CHILD_INVOCATION_LIMIT_HIT" -eq 0 ]]; then
          if (( WORKERS_RUN >= MAX_CHILD_INVOCATIONS )); then
            CHILD_INVOCATION_LIMIT_HIT=1
            REPLAN_LOOP_GUARD_HIT=1
          else
            WORKERS_RUN=$((WORKERS_RUN + 1))
            replan_file_count="$(jq '.files | length' "$replan_job")"
            forced_mode="$(jq -r '.force_worker_mode // "auto"' "$replan_job")"
            replan_worker_script="${SCRIPT_DIR}/worker_claude_router.sh"
            if [[ "$forced_mode" = "managed_single_file" || "$replan_file_count" -eq 1 ]]; then
              replan_worker_script="${SCRIPT_DIR}/worker_claude_router_managed_single_file.sh"
            fi
            bash "$replan_worker_script" "$replan_job" >/dev/null || true
            replan_status_file="${RESULTS_DIR}/$(basename "${replan_job%.json}").status.json"
            ensure_status_file "$replan_job" "$replan_status_file"
            replan_status="$(jq -r '.status' "$replan_status_file")"
            replan_changed_count="$(jq -r '.actual_changed_count // 0' "$replan_status_file")"
            replan_verification_note="$(jq -r '.verification_note // empty' "$replan_status_file")"
            if [[ "$replan_changed_count" -gt 0 ]]; then
              WORKERS_WITH_VERIFIED_CHANGES=$((WORKERS_WITH_VERIFIED_CHANGES + 1))
            fi
            if [[ "$replan_verification_note" = "claimed success without verified file change" && "$replan_status" = "FAILED" ]]; then
              WORKERS_FALSE_SUCCESS_BLOCKED=$((WORKERS_FALSE_SUCCESS_BLOCKED + 1))
            fi
            if [[ "$replan_status" = "CHILD_LIMIT_REACHED" ]]; then
              WORKERS_CHILD_LIMIT_BLOCKED=$((WORKERS_CHILD_LIMIT_BLOCKED + 1))
              REPLAN_LOOP_GUARD_HIT=1
            elif [[ "$replan_status" = "CHILD_TIMEOUT" ]]; then
              WORKERS_TIMED_OUT=$((WORKERS_TIMED_OUT + 1))
              WORKERS_FAILED=$((WORKERS_FAILED + 1))
              REPLAN_LOOP_GUARD_HIT=1
            elif [[ "$replan_status" = "OVERFLOW_DETECTED" ]]; then
              WORKERS_OVERFLOWED=$((WORKERS_OVERFLOWED + 1))
              REPLAN_LOOP_GUARD_HIT=1
            elif [[ "$replan_status" = "NEEDS_REPLAN" ]]; then
              WORKERS_NEED_REPLAN=$((WORKERS_NEED_REPLAN + 1))
              REPLAN_LOOP_GUARD_HIT=1
            elif [[ "$replan_status" = "FAILED" ]]; then
              WORKERS_FAILED=$((WORKERS_FAILED + 1))
              REPLAN_LOOP_GUARD_HIT=1
            fi
          fi
        else
          WORKERS_FAILED=$((WORKERS_FAILED + 1))
          REPLAN_LOOP_GUARD_HIT=1
        fi
      else
        WORKERS_FAILED=$((WORKERS_FAILED + 1))
      fi
    fi
  done
fi

JOB_COUNT="$(find "$JOBS_DIR" -maxdepth 1 -name 'job-*.json' | wc -l | tr -d ' ')"
MAX_FILES_IN_JOB="$(python3 - "$JOBS_DIR" <<'PY'
import json
import sys
from pathlib import Path

jobs_dir = Path(sys.argv[1])
counts = []
for path in jobs_dir.glob("job-*.json"):
    job = json.loads(path.read_text(encoding="utf-8"))
    counts.append(len(job.get("files", [])))
print(max(counts) if counts else 0)
PY
)"
AVG_FILES_PER_JOB="$(python3 - "$JOBS_DIR" <<'PY'
import json
import sys
from pathlib import Path

jobs_dir = Path(sys.argv[1])
counts = []
for path in jobs_dir.glob("job-*.json"):
    job = json.loads(path.read_text(encoding="utf-8"))
    counts.append(len(job.get("files", [])))
print(f"{(sum(counts) / len(counts)):.2f}" if counts else "0.00")
PY
)"
if [[ "$TOTAL_FILES" -gt 0 ]]; then
  BREADTH_REDUCTION="$(python3 - "$TOTAL_FILES" "$MAX_FILES_IN_JOB" <<'PY'
import sys
total_files = int(sys.argv[1])
max_files = int(sys.argv[2])
ratio = 1 - (max_files / total_files)
print(f"{ratio * 100:.1f}")
PY
)"
else
  BREADTH_REDUCTION="0.0"
fi

jq -n \
  --arg run_id "$RUN_ID" \
  --arg task "$TASK" \
  --arg scope_path "$SCOPE_PATH" \
  --arg strategy "$(jq -r '.strategy' "$PLAN_JSON_FILE")" \
  --arg worker_mode "$WORKER_MODE" \
  --argjson planner_exit "$PLANNER_EXIT" \
  --argjson planner_parse_ok "$PLANNER_PARSE_OK" \
  --arg planner_raw_file "$PLAN_RAW_FILE" \
  --arg plan_json_file "$PLAN_JSON_FILE" \
  --arg jobs_dir "$JOBS_DIR" \
  --arg results_dir "$RESULTS_DIR" \
  --argjson total_files "$TOTAL_FILES" \
  --argjson compact_inventory_files "$COMPACT_COUNT" \
  --argjson initial_job_count "$INITIAL_JOB_COUNT" \
  --argjson job_count "$JOB_COUNT" \
  --argjson max_files_in_job "$MAX_FILES_IN_JOB" \
  --argjson workers_run "$WORKERS_RUN" \
  --argjson workers_overflowed "$WORKERS_OVERFLOWED" \
  --argjson workers_failed "$WORKERS_FAILED" \
  --argjson workers_need_replan "$WORKERS_NEED_REPLAN" \
  --argjson workers_with_verified_changes "$WORKERS_WITH_VERIFIED_CHANGES" \
  --argjson workers_false_success_blocked "$WORKERS_FALSE_SUCCESS_BLOCKED" \
  --argjson workers_child_limit_blocked "$WORKERS_CHILD_LIMIT_BLOCKED" \
  --argjson workers_timed_out "$WORKERS_TIMED_OUT" \
  --argjson overflow_retries "$OVERFLOW_RETRIES" \
  --argjson child_invocation_limit_hit "$CHILD_INVOCATION_LIMIT_HIT" \
  --argjson fail_replan_attempts "$FAIL_REPLAN_ATTEMPTS" \
  --argjson workers_failed_replanned "$WORKERS_FAILED_REPLANNED" \
  --argjson replan_loop_guard_hit "$REPLAN_LOOP_GUARD_HIT" \
  --arg max_child_invocations "$MAX_CHILD_INVOCATIONS" \
  --arg avg_files_per_job "$AVG_FILES_PER_JOB" \
  --arg breadth_reduction_percent "$BREADTH_REDUCTION" \
  '{
    run_id: $run_id,
    task: $task,
    scope_path: $scope_path,
    strategy: $strategy,
    worker_mode: $worker_mode,
    planner_exit: $planner_exit,
    planner_parse_ok: ($planner_parse_ok == 0),
    planner_raw_file: $planner_raw_file,
    plan_json_file: $plan_json_file,
    jobs_dir: $jobs_dir,
    results_dir: $results_dir,
    metrics: {
      total_files_in_scope: $total_files,
      compact_inventory_files: $compact_inventory_files,
      initial_planned_jobs: $initial_job_count,
      planned_jobs_after_retries: $job_count,
      avg_files_per_job: $avg_files_per_job,
      max_files_in_job: $max_files_in_job,
      breadth_reduction_percent: $breadth_reduction_percent,
      workers_run: $workers_run,
      workers_overflowed: $workers_overflowed,
      workers_failed: $workers_failed,
      workers_need_replan: $workers_need_replan,
      workers_with_verified_changes: $workers_with_verified_changes,
      workers_false_success_blocked: $workers_false_success_blocked,
      workers_child_limit_blocked: $workers_child_limit_blocked,
      workers_timed_out: $workers_timed_out,
      overflow_retries: $overflow_retries,
      child_invocation_limit_hit: $child_invocation_limit_hit,
      fail_replan_attempts: $fail_replan_attempts,
      workers_failed_replanned: $workers_failed_replanned,
      replan_loop_guard_hit: $replan_loop_guard_hit,
      max_child_invocations: $max_child_invocations
    }
  }' >"$SUMMARY_FILE"

jq . "$SUMMARY_FILE"
