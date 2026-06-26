#!/usr/bin/env bash
set -euo pipefail

JOB_FILE="${1:?Usage: worker_claude_router_managed_single_file.sh <job.json>}"
WORKDIR="${CLAUDE_WORKDIR:-/workspace}"
RESULTS_DIR="${WORKER_RESULTS_DIR:-$(dirname "$JOB_FILE")/../results}"
mkdir -p "$RESULTS_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/claude_router_common.sh"

JOB_ID="$(jq -r '.id' "$JOB_FILE")"
JOB_SCOPE="$(jq -r '.scope_path // empty' "$JOB_FILE")"
TASK="$(jq -r '.instruction' "$JOB_FILE")"
FILES_JSON="$(jq -c '.files' "$JOB_FILE")"
FILE_COUNT="$(jq '.files | length' "$JOB_FILE")"
TARGET_FILE="$(jq -r '.files[0] // empty' "$JOB_FILE")"
SUCCESS_CHECK="$(jq -r '.success_check // "Keep the reply concise and report what changed."' "$JOB_FILE")"
REQUIRE_CHANGE="$(jq -r '.require_change // false' "$JOB_FILE")"
TEST_COMMAND="$(jq -r '.test_command // empty' "$JOB_FILE")"
RUN_DIR="${CLAUDE_RUN_DIR:-$(dirname "$JOB_FILE")/..}"
RESULT_PREFIX="${RESULTS_DIR}/${JOB_ID}"
RAW_FILE="${RESULT_PREFIX}.raw.txt"
EXEC_LOG_FILE="${RESULT_PREFIX}.exec.log"
STATUS_FILE="${RESULT_PREFIX}.status.json"
BEFORE_FILE="${RESULT_PREFIX}.before.json"
AFTER_FILE="${RESULT_PREFIX}.after.json"
TEST_OUTPUT_FILE="${RESULT_PREFIX}.test.txt"
APPLIED_FILE="${RESULT_PREFIX}.applied.txt"

if [[ "$FILE_COUNT" -ne 1 || -z "$TARGET_FILE" ]]; then
  echo "Managed single-file worker requires exactly one target file." >&2
  exit 2
fi

if [[ -n "$JOB_SCOPE" ]]; then
  cd "$JOB_SCOPE"
else
  cd "$WORKDIR"
fi

python3 - "$JOB_FILE" "$BEFORE_FILE" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

job = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
out = Path(sys.argv[2])
state = []
for rel in job.get("files", []):
    path = Path(rel)
    entry = {"path": rel, "exists": path.exists()}
    if path.exists() and path.is_file():
        entry["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    state.append(entry)
out.write_text(json.dumps(state, indent=2), encoding="utf-8")
PY

read -r -d '' WORKER_PROMPT <<EOF || true
You are the managed single-file worker Claude agent behind a main Claude orchestrator.

Assigned job id: ${JOB_ID}
Target file: ${TARGET_FILE}

Task:
${TASK}

Hard limits:
- Do not inspect or modify any file except ${TARGET_FILE}.
- Do not emit long reasoning.
- If you need more files, reply with NEEDS_REPLAN.
- If context pressure appears, reply with OVERFLOW_DETECTED.
- You are not responsible for applying the edit directly.
- Instead, you must return the exact final contents for the target file.

Success check:
${SUCCESS_CHECK}

Validation command:
${TEST_COMMAND:-not-run}

Additional rules:
- Return code only for the target file. Do not include prose inside the file content.
- If the target file is a Python test file and the validation command uses pytest, include at least one function named like test_*.
- Prefer the smallest valid file that satisfies the task.
- Do not add scaffolding or examples unless the task explicitly asks for them.

Return format exactly:
STATUS: <SUCCESS|NEEDS_REPLAN|OVERFLOW_DETECTED|CHILD_LIMIT_REACHED|CHILD_TIMEOUT|FAILED>
FILES: ${TARGET_FILE}
TESTS: <what should be run or not-run>
SUMMARY: <one short paragraph>
CONTENT_PATH: ${TARGET_FILE}
CONTENT_START
<entire final file content here>
CONTENT_END

If you cannot provide safe final file contents, return FAILED and omit the content block.
EOF

START_TS="$(date +%s)"
set +e
invoke_claude_router_prompt "$RUN_DIR" "child_managed_worker" "$RAW_FILE" "$WORKER_PROMPT" "$JOB_ID" "${JOB_SCOPE:-$WORKDIR}"
EXIT_CODE=$?
set -e
cp "$RAW_FILE" "$EXEC_LOG_FILE"
END_TS="$(date +%s)"
DURATION_SEC="$((END_TS - START_TS))"

if [[ ! -f "$RAW_FILE" ]]; then
  : >"$RAW_FILE"
fi

PARSE_JSON="$(python3 - "$RAW_FILE" "$TARGET_FILE" "$APPLIED_FILE" <<'PY'
import json
import re
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore")
target = sys.argv[2]
applied_file = Path(sys.argv[3])
target_name = Path(target).name.lower()
is_pytest_target = target_name.startswith("test_") and target_name.endswith(".py")

status_match = re.search(r'(?im)^STATUS:\s*(\S+)\s*$', raw)
path_match = re.search(r'(?im)^CONTENT_PATH:\s*(.+?)\s*$', raw)
block_match = re.search(r'CONTENT_START\r?\n(.*?)\r?\nCONTENT_END', raw, re.S)

data = {
    "status_line": status_match.group(1) if status_match else "",
    "content_path": path_match.group(1).strip() if path_match else "",
    "has_content": bool(block_match),
    "path_matches": bool(path_match and path_match.group(1).strip() == target),
}
if block_match:
    content = block_match.group(1)
    stripped = content.strip()
    fence_match = re.fullmatch(r"```[A-Za-z0-9_-]*\r?\n(.*?)\r?\n```", stripped, re.S)
    if fence_match:
        content = fence_match.group(1)
    applied_file.write_text(content, encoding="utf-8")
    data["content_bytes"] = len(content.encode("utf-8"))
else:
    content = ""
    if is_pytest_target and "def test_" not in content:
        content = ""
    data["content_bytes"] = 0

print(json.dumps(data))
PY
)"

PARSED_STATUS_LINE="$(python3 - "$PARSE_JSON" <<'PY'
import json, sys
print(json.loads(sys.argv[1]).get("status_line", ""))
PY
)"
HAS_CONTENT="$(python3 - "$PARSE_JSON" <<'PY'
import json, sys
print(str(json.loads(sys.argv[1]).get("has_content", False)).lower())
PY
)"
PATH_MATCHES="$(python3 - "$PARSE_JSON" <<'PY'
import json, sys
print(str(json.loads(sys.argv[1]).get("path_matches", False)).lower())
PY
)"

STATUS="SUCCESS"
if [[ "$PARSED_STATUS_LINE" = "CHILD_LIMIT_REACHED" || $EXIT_CODE -eq 79 ]]; then
  STATUS="CHILD_LIMIT_REACHED"
elif [[ "$PARSED_STATUS_LINE" = "CHILD_TIMEOUT" || $EXIT_CODE -eq 124 ]]; then
  STATUS="CHILD_TIMEOUT"
elif [[ "$PARSED_STATUS_LINE" = "OVERFLOW_DETECTED" ]]; then
  STATUS="OVERFLOW_DETECTED"
elif [[ "$PARSED_STATUS_LINE" = "NEEDS_REPLAN" ]]; then
  STATUS="NEEDS_REPLAN"
elif [[ "$PARSED_STATUS_LINE" = "FAILED" || $EXIT_CODE -ne 0 ]]; then
  STATUS="FAILED"
elif [[ "$PARSED_STATUS_LINE" = "SUCCESS" ]]; then
  STATUS="SUCCESS"
elif grep -Eiq 'maximum context length|output tokens|token overflow|context window' "$EXEC_LOG_FILE"; then
  STATUS="OVERFLOW_DETECTED"
else
  STATUS="FAILED"
fi

if [[ "$STATUS" = "SUCCESS" ]]; then
  if [[ "$HAS_CONTENT" != "true" || "$PATH_MATCHES" != "true" ]]; then
    STATUS="FAILED"
  else
    cp "$APPLIED_FILE" "$TARGET_FILE"
  fi
fi

python3 - "$JOB_FILE" "$AFTER_FILE" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

job = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
out = Path(sys.argv[2])
state = []
for rel in job.get("files", []):
    path = Path(rel)
    entry = {"path": rel, "exists": path.exists()}
    if path.exists() and path.is_file():
        entry["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    state.append(entry)
out.write_text(json.dumps(state, indent=2), encoding="utf-8")
PY

ACTUAL_CHANGED_FILES="$(python3 - "$BEFORE_FILE" "$AFTER_FILE" <<'PY'
import json
import sys
from pathlib import Path

before = {item["path"]: item for item in json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))}
after = {item["path"]: item for item in json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))}
changed = []
for path, prev in before.items():
    curr = after.get(path, {})
    if prev.get("exists") != curr.get("exists") or prev.get("sha256") != curr.get("sha256"):
        changed.append(path)
print(json.dumps(changed))
PY
)"
ACTUAL_CHANGED_COUNT="$(python3 - "$ACTUAL_CHANGED_FILES" <<'PY'
import json
import sys
print(len(json.loads(sys.argv[1])))
PY
)"

TEST_EXIT_CODE=0
TEST_EXECUTED_COMMAND="$TEST_COMMAND"
if [[ -n "$TEST_COMMAND" ]]; then
  set +e
  bash -lc "$TEST_COMMAND" >"$TEST_OUTPUT_FILE" 2>&1
  TEST_EXIT_CODE=$?
  set -e
  if [[ "$TEST_EXIT_CODE" -eq 127 && "$TEST_COMMAND" = pytest* ]]; then
    TEST_EXECUTED_COMMAND="python3 -m ${TEST_COMMAND}"
    set +e
    bash -lc "$TEST_EXECUTED_COMMAND" >"$TEST_OUTPUT_FILE" 2>&1
    TEST_EXIT_CODE=$?
    set -e
  fi
fi

if [[ "$STATUS" = "SUCCESS" && "$REQUIRE_CHANGE" = "true" && "$ACTUAL_CHANGED_COUNT" -eq 0 ]]; then
  STATUS="FAILED"
fi
if [[ "$STATUS" = "SUCCESS" && -n "$TEST_COMMAND" && "$TEST_EXIT_CODE" -ne 0 ]]; then
  STATUS="FAILED"
fi

VERIFICATION_NOTE="verified"
if [[ "$STATUS" = "CHILD_LIMIT_REACHED" ]]; then
  VERIFICATION_NOTE="child worker cap blocked a new Claude child"
elif [[ "$STATUS" = "CHILD_TIMEOUT" ]]; then
  VERIFICATION_NOTE="child worker timed out before producing a usable result"
elif [[ "$REQUIRE_CHANGE" = "true" && "$ACTUAL_CHANGED_COUNT" -eq 0 ]]; then
  VERIFICATION_NOTE="claimed success without verified file change"
elif [[ -n "$TEST_COMMAND" && "$TEST_EXIT_CODE" -ne 0 ]]; then
  VERIFICATION_NOTE="file changed but verification command failed"
fi

jq -n \
  --arg id "$JOB_ID" \
  --arg status "$STATUS" \
  --arg scope_path "${JOB_SCOPE:-$WORKDIR}" \
  --argjson require_change "$REQUIRE_CHANGE" \
  --argjson files "$FILES_JSON" \
  --argjson actual_changed_files "$ACTUAL_CHANGED_FILES" \
  --arg raw_file "$RAW_FILE" \
  --arg exec_log_file "$EXEC_LOG_FILE" \
  --arg success_check "$SUCCESS_CHECK" \
  --arg test_command "$TEST_COMMAND" \
  --arg test_executed_command "$TEST_EXECUTED_COMMAND" \
  --arg test_output_file "$TEST_OUTPUT_FILE" \
  --arg verification_note "$VERIFICATION_NOTE" \
  --arg parse_json "$PARSE_JSON" \
  --argjson exit_code "$EXIT_CODE" \
  --argjson duration_sec "$DURATION_SEC" \
  --argjson actual_changed_count "$ACTUAL_CHANGED_COUNT" \
  --argjson test_exit_code "$TEST_EXIT_CODE" \
  '{
    id: $id,
    status: $status,
    scope_path: $scope_path,
    require_change: $require_change,
    files: $files,
    actual_changed_files: $actual_changed_files,
    actual_changed_count: $actual_changed_count,
    verification_note: $verification_note,
    raw_file: $raw_file,
    exec_log_file: $exec_log_file,
    success_check: $success_check,
    test_command: $test_command,
    test_executed_command: $test_executed_command,
    test_output_file: $test_output_file,
    test_exit_code: $test_exit_code,
    parse_json: ($parse_json | fromjson),
    exit_code: $exit_code,
    duration_sec: $duration_sec
  }' >"$STATUS_FILE"

cat "$RAW_FILE"
