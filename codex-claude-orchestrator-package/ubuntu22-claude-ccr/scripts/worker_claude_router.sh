#!/usr/bin/env bash
set -euo pipefail

JOB_FILE="${1:?Usage: worker_claude_router.sh <job.json>}"
WORKDIR="${CLAUDE_WORKDIR:-/workspace}"
RESULTS_DIR="${WORKER_RESULTS_DIR:-$(dirname "$JOB_FILE")/../results}"
mkdir -p "$RESULTS_DIR"

/usr/local/bin/start-ccr >/dev/null

export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-local-test-key}"
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://127.0.0.1:3456}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"
export DISABLE_PROMPT_CACHING="${DISABLE_PROMPT_CACHING:-1}"
export API_TIMEOUT_MS="${API_TIMEOUT_MS:-600000}"

JOB_ID="$(jq -r '.id' "$JOB_FILE")"
JOB_SCOPE="$(jq -r '.scope_path // empty' "$JOB_FILE")"
TASK="$(jq -r '.instruction' "$JOB_FILE")"
FILES_JSON="$(jq -c '.files' "$JOB_FILE")"
FILES_TEXT="$(jq -r '.files[]' "$JOB_FILE")"
SUCCESS_CHECK="$(jq -r '.success_check // "Keep the reply concise and report what changed."' "$JOB_FILE")"
REQUIRE_CHANGE="$(jq -r '.require_change // false' "$JOB_FILE")"
TEST_COMMAND="$(jq -r '.test_command // empty' "$JOB_FILE")"
RESULT_PREFIX="${RESULTS_DIR}/${JOB_ID}"
RAW_FILE="${RESULT_PREFIX}.raw.txt"
STATUS_FILE="${RESULT_PREFIX}.status.json"
BEFORE_FILE="${RESULT_PREFIX}.before.json"
AFTER_FILE="${RESULT_PREFIX}.after.json"
TEST_OUTPUT_FILE="${RESULT_PREFIX}.test.txt"

if [[ -n "$JOB_SCOPE" ]]; then
  cd "$JOB_SCOPE"
else
  cd "$WORKDIR"
fi

python3 - "$JOB_FILE" "$BEFORE_FILE" <<'PY'
import hashlib
import json
import os
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
You are the worker agent behind a Codex master orchestrator.

Assigned job id: ${JOB_ID}

Task:
${TASK}

Allowed files:
${FILES_TEXT}

Hard limits:
- Only inspect and modify the assigned files unless a missing dependency is absolutely required.
- If you need more files, stop and reply with NEEDS_REPLAN plus the exact missing file paths.
- Keep the response short.
- If you detect context pressure or output pressure, stop and reply with OVERFLOW_DETECTED.
- If this task requires edits, you must actually modify the assigned file set before returning SUCCESS.
- Do not describe a hypothetical patch. Apply the patch first, then report the real result.

Success check:
${SUCCESS_CHECK}

This job requires real file changes:
${REQUIRE_CHANGE}

Return format:
STATUS: <SUCCESS|NEEDS_REPLAN|OVERFLOW_DETECTED|FAILED>
FILES: <comma-separated paths>
TESTS: <what you ran or not-run>
SUMMARY: <one short paragraph>
EOF

START_TS="$(date +%s)"
set +e
claude --bare -p --model "${CLAUDE_MODEL_ALIAS:-sonnet}" --permission-mode "${CLAUDE_PERMISSION_MODE:-bypassPermissions}" --output-format text "$WORKER_PROMPT" >"$RAW_FILE" 2>&1
EXIT_CODE=$?
set -e
END_TS="$(date +%s)"
DURATION_SEC="$((END_TS - START_TS))"

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

RAW_TEXT="$(cat "$RAW_FILE")"
STATUS="SUCCESS"
if grep -Eiq 'maximum context length|output tokens|token overflow|context window|OVERFLOW_DETECTED' "$RAW_FILE"; then
  STATUS="OVERFLOW_DETECTED"
elif grep -Eiq '^STATUS:\s*NEEDS_REPLAN' "$RAW_FILE"; then
  STATUS="NEEDS_REPLAN"
elif [[ $EXIT_CODE -ne 0 ]] || grep -Eiq '^STATUS:\s*FAILED' "$RAW_FILE"; then
  STATUS="FAILED"
elif grep -Eiq '^STATUS:\s*SUCCESS' "$RAW_FILE"; then
  STATUS="SUCCESS"
fi

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
if [[ "$REQUIRE_CHANGE" = "true" && "$ACTUAL_CHANGED_COUNT" -eq 0 ]]; then
  VERIFICATION_NOTE="claimed success without verified file change"
elif [[ "$REQUIRE_CHANGE" = "false" ]]; then
  VERIFICATION_NOTE="inspection-only or non-edit job"
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
  --arg success_check "$SUCCESS_CHECK" \
  --arg test_command "$TEST_COMMAND" \
  --arg test_executed_command "$TEST_EXECUTED_COMMAND" \
  --arg test_output_file "$TEST_OUTPUT_FILE" \
  --arg verification_note "$VERIFICATION_NOTE" \
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
    success_check: $success_check,
    test_command: $test_command,
    test_executed_command: $test_executed_command,
    test_output_file: $test_output_file,
    test_exit_code: $test_exit_code,
    exit_code: $exit_code,
    duration_sec: $duration_sec
  }' >"$STATUS_FILE"

cat "$RAW_FILE"
