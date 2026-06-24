#!/usr/bin/env bash
set -euo pipefail

TASK="${1:?Usage: orchestrate_codex_to_claude.sh <task> [scope_path]}"
SCOPE_PATH="${2:-/workspace}"
MAX_FILES_PER_JOB="${ORCH_MAX_FILES_PER_JOB:-3}"
MAX_JOBS="${ORCH_MAX_JOBS:-4}"
INVENTORY_LIMIT="${ORCH_INVENTORY_LIMIT:-24}"
EXECUTE_WORKERS="${ORCH_EXECUTE_WORKERS:-1}"
RUN_ROOT="${ORCH_RUN_ROOT:-/workspace/linux_remote/ubuntu22-claude-ccr/orchestrator}"
RUN_ID="${ORCH_RUN_ID:-run-$(date +%Y%m%d-%H%M%S)}"
RUN_DIR="${RUN_ROOT}/${RUN_ID}"
JOBS_DIR="${RUN_DIR}/jobs"
RESULTS_DIR="${RUN_DIR}/results"
mkdir -p "$JOBS_DIR" "$RESULTS_DIR"

cd /workspace

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
    "orchestrator"
}
allowed_ext = {
    ".py", ".js", ".ts", ".tsx", ".jsx", ".json", ".md", ".yml", ".yaml",
    ".sh", ".ps1", ".toml", ".ini", ".cfg", ".txt"
}

for root, dirs, files in os.walk(scope):
    dirs[:] = [d for d in dirs if d not in skip_dirs]
    for name in sorted(files):
        path = os.path.join(root, name)
        rel = os.path.relpath(path, "/workspace")
        _, ext = os.path.splitext(name)
        if ext.lower() in allowed_ext or name in {"Dockerfile", "Makefile"}:
            print(rel.replace("\\", "/"))
PY

TOTAL_FILES="$(wc -l <"$INVENTORY_FILE" | tr -d ' ')"
head -n "$INVENTORY_LIMIT" "$INVENTORY_FILE" >"$COMPACT_FILE"
COMPACT_COUNT="$(wc -l <"$COMPACT_FILE" | tr -d ' ')"

PLANNER_PROMPT="$(cat <<EOF
You are the master planner for a low-context orchestration system.

Goal:
Split the user task into at most ${MAX_JOBS} small worker jobs for Claude Code.

Rules:
- Output JSON only.
- Each job may reference at most ${MAX_FILES_PER_JOB} files.
- Prefer inspection and editing in the smallest possible batches.
- Use only files from the provided inventory.
- If the task is broad, create investigation jobs before edit jobs.
- Keep each instruction concise and executable.

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

set +e
bash /workspace/linux_remote/ubuntu22-claude-ccr/scripts/run_codex_guarded.sh "$PLANNER_PROMPT" >"$PLAN_RAW_FILE" 2>&1
PLANNER_EXIT=$?
set -e

PLANNER_PARSE_OK=0
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

if [[ "$PLANNER_PARSE_OK" -ne 0 || ! -s "$PLAN_JSON_FILE" ]]; then
  python3 - "$COMPACT_FILE" "$PLAN_JSON_FILE" "$MAX_FILES_PER_JOB" "$MAX_JOBS" "$TASK" <<'PY'
import json
import math
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

def relativize_to_scope(files, scope_path: str):
    scope = Path(scope_path)
    rel_files = []
    for item in files:
        full = Path("/workspace") / item
        try:
            rel_files.append(full.relative_to(scope).as_posix())
        except ValueError:
            rel_files.append(item)
    return rel_files

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
    files = relativize_to_scope(files, scope_path)
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

OVERFLOW_RETRIES=0
WORKERS_RUN=0
WORKERS_OVERFLOWED=0
WORKERS_FAILED=0
WORKERS_NEED_REPLAN=0
WORKERS_WITH_VERIFIED_CHANGES=0
WORKERS_FALSE_SUCCESS_BLOCKED=0

if [[ "$EXECUTE_WORKERS" = "1" ]]; then
  for job_file in "$JOBS_DIR"/job-*.json; do
    [[ -f "$job_file" ]] || continue
    WORKERS_RUN=$((WORKERS_RUN + 1))
    bash /workspace/linux_remote/ubuntu22-claude-ccr/scripts/worker_claude_router.sh "$job_file" >/dev/null || true
    status_file="${RESULTS_DIR}/$(basename "${job_file%.json}").status.json"
    job_status="$(jq -r '.status' "$status_file")"
    actual_changed_count="$(jq -r '.actual_changed_count // 0' "$status_file")"
    verification_note="$(jq -r '.verification_note // empty' "$status_file")"
    if [[ "$actual_changed_count" -gt 0 ]]; then
      WORKERS_WITH_VERIFIED_CHANGES=$((WORKERS_WITH_VERIFIED_CHANGES + 1))
    fi
    if [[ "$verification_note" = "claimed success without verified file change" ]]; then
      WORKERS_FALSE_SUCCESS_BLOCKED=$((WORKERS_FALSE_SUCCESS_BLOCKED + 1))
    fi
    if [[ "$job_status" = "OVERFLOW_DETECTED" ]]; then
      WORKERS_OVERFLOWED=$((WORKERS_OVERFLOWED + 1))
      file_count="$(jq '.files | length' "$job_file")"
      if [[ "$file_count" -gt 1 ]]; then
        OVERFLOW_RETRIES=$((OVERFLOW_RETRIES + 1))
        python3 - "$job_file" "$JOBS_DIR" <<'PY'
import json
import sys
from pathlib import Path

job_path = Path(sys.argv[1])
jobs_dir = Path(sys.argv[2])
job = json.loads(job_path.read_text(encoding="utf-8"))
base_id = job["id"]
for idx, file_path in enumerate(job["files"], start=1):
    payload = {
        "id": f"{base_id}-retry-{idx:02d}",
        "scope_path": job.get("scope_path"),
        "title": f"{job['title']} retry {idx}",
        "instruction": job["instruction"],
        "files": [file_path],
        "success_check": job.get("success_check", "Return a concise result."),
        "require_change": job.get("require_change", False)
    }
    (jobs_dir / f"{payload['id']}.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY
        for retry_job in "$JOBS_DIR"/"$(basename "${job_file%.json}")"-retry-*.json; do
          [[ -f "$retry_job" ]] || continue
          WORKERS_RUN=$((WORKERS_RUN + 1))
          bash /workspace/linux_remote/ubuntu22-claude-ccr/scripts/worker_claude_router.sh "$retry_job" >/dev/null || true
          retry_status_file="${RESULTS_DIR}/$(basename "${retry_job%.json}").status.json"
          retry_status="$(jq -r '.status' "$retry_status_file")"
          retry_changed_count="$(jq -r '.actual_changed_count // 0' "$retry_status_file")"
          retry_verification_note="$(jq -r '.verification_note // empty' "$retry_status_file")"
          if [[ "$retry_changed_count" -gt 0 ]]; then
            WORKERS_WITH_VERIFIED_CHANGES=$((WORKERS_WITH_VERIFIED_CHANGES + 1))
          fi
          if [[ "$retry_verification_note" = "claimed success without verified file change" ]]; then
            WORKERS_FALSE_SUCCESS_BLOCKED=$((WORKERS_FALSE_SUCCESS_BLOCKED + 1))
          fi
          if [[ "$retry_status" = "OVERFLOW_DETECTED" ]]; then
            WORKERS_OVERFLOWED=$((WORKERS_OVERFLOWED + 1))
          elif [[ "$retry_status" = "FAILED" ]]; then
            WORKERS_FAILED=$((WORKERS_FAILED + 1))
          fi
        done
      fi
    elif [[ "$job_status" = "NEEDS_REPLAN" ]]; then
      WORKERS_NEED_REPLAN=$((WORKERS_NEED_REPLAN + 1))
    elif [[ "$job_status" = "FAILED" ]]; then
      WORKERS_FAILED=$((WORKERS_FAILED + 1))
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
  --argjson overflow_retries "$OVERFLOW_RETRIES" \
  --arg avg_files_per_job "$AVG_FILES_PER_JOB" \
  --arg breadth_reduction_percent "$BREADTH_REDUCTION" \
  '{
    run_id: $run_id,
    task: $task,
    scope_path: $scope_path,
    strategy: $strategy,
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
      overflow_retries: $overflow_retries
    }
  }' >"$SUMMARY_FILE"

jq . "$SUMMARY_FILE"
