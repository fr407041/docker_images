#!/usr/bin/env python3
import json
import os
import re
import time
import sys
from pathlib import Path


def last_argument() -> str:
    if len(sys.argv) <= 1:
        return ""
    return sys.argv[-1]


def extract_inventory(prompt: str):
    inventory = []
    seen_header = False
    for line in prompt.splitlines():
        stripped = line.strip()
        if stripped.startswith("Inventory sample"):
            seen_header = True
            continue
        if not seen_header:
            continue
        if stripped.startswith("Return this exact schema:"):
            break
        if "/" in stripped or stripped.endswith(".py") or stripped.endswith(".md"):
            inventory.append(stripped)
    return inventory


def emit_planner(prompt: str):
    bad_planner = os.environ.get("MOCK_CLAUDE_BAD_PLANNER", "0") == "1"
    if bad_planner:
        print("planner output unavailable ### not-json ###")
        return

    task_match = re.search(r"User task:\n(.*?)\n\nScope path:", prompt, re.S)
    task = task_match.group(1).strip() if task_match else "Task unavailable"
    inventory = extract_inventory(prompt)
    normalized = [line.strip() for line in inventory if line.strip()]

    if "tests/test_placeholder.py" in task:
        jobs = [
            {
                "title": "Managed single-file edit for tests/test_placeholder.py",
                "instruction": task,
                "files": ["tests/test_placeholder.py"],
                "success_check": "tests/test_placeholder.py is updated exactly as requested and validation passes.",
            }
        ]
    elif "tests/test_math_utils.py" in task:
        jobs = [
            {
                "title": "Review math helper and target test together",
                "instruction": task,
                "files": ["src/math_utils.py", "tests/test_math_utils.py"],
                "success_check": "tests/test_math_utils.py is updated exactly as requested and pytest passes.",
            }
        ]
    else:
        chosen = normalized[:2] if normalized else ["README.md"]
        jobs = [
            {
                "title": "Fallback narrow inspection batch",
                "instruction": task,
                "files": chosen,
                "success_check": "Return a concise result for only the assigned files.",
            }
        ]

    print(json.dumps({"strategy": "Mock planner kept file scope intentionally small.", "jobs": jobs}, indent=2))


def count_allowed_files(prompt: str):
    match = re.search(r"Allowed files:\n(.*?)\n\nHard limits:", prompt, re.S)
    if not match:
        return []
    return [line.strip() for line in match.group(1).splitlines() if line.strip()]


def edit_file(path_text: str, content: str):
    path = Path(path_text)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def emit_managed_response(prompt: str):
    fail_pattern = os.environ.get("MOCK_CLAUDE_FAIL_PATTERN", "0") == "1"
    fake_success_no_change = os.environ.get("MOCK_CLAUDE_FAKE_SUCCESS_NO_CHANGE", "0") == "1"
    repeat_needs_replan = os.environ.get("MOCK_CLAUDE_REPEAT_NEEDS_REPLAN", "0") == "1"
    if fail_pattern and "REPLAN_HINT:" not in prompt:
        print("STATUS: FAILED")
        print("FILES: not-applied")
        print("TESTS: not-run")
        print("SUMMARY: mock managed worker forced a failure so the orchestrator must rewrite the task.")
        return
    if repeat_needs_replan:
        print("STATUS: NEEDS_REPLAN")
        print("FILES: not-applied")
        print("TESTS: not-run")
        print("SUMMARY: mock managed worker keeps asking for replan so the orchestrator must stop looping.")
        return
    if fake_success_no_change:
        target_match = re.search(r"CONTENT_PATH:\s*(.+)", prompt)
        target = target_match.group(1).strip() if target_match else "unknown"
        print("STATUS: SUCCESS")
        print(f"FILES: {target}")
        print("TESTS: not-run")
        print("SUMMARY: mock managed worker claimed success but intentionally returned no content block.")
        return

    target_match = re.search(r"CONTENT_PATH:\s*(.+)", prompt)
    target = target_match.group(1).strip() if target_match else ""

    if target.endswith("tests/test_placeholder.py"):
        content = "def test_placeholder():\n    assert 1 + 1 == 2\n"
    elif target.endswith("tests/test_math_utils.py"):
        content = "from src.math_utils import add\n\n\ndef test_add():\n    assert add(1, 1) == 2\n"
    else:
        print("STATUS: FAILED")
        print(f"FILES: {target}")
        print("TESTS: not-run")
        print("SUMMARY: mock managed worker does not know how to build this file.")
        return

    print("STATUS: SUCCESS")
    print(f"FILES: {target}")
    print("TESTS: suggested validation only")
    print("SUMMARY: mock managed worker returned deterministic final file content.")
    print(f"CONTENT_PATH: {target}")
    print("CONTENT_START")
    print(content, end="")
    print("CONTENT_END")


def emit_worker_response(prompt: str):
    allowed = count_allowed_files(prompt)
    overflow_on_multi = os.environ.get("MOCK_CLAUDE_OVERFLOW_ON_MULTI_FILE", "0") == "1"
    fail_pattern = os.environ.get("MOCK_CLAUDE_FAIL_PATTERN", "0") == "1"
    needs_replan_pattern = os.environ.get("MOCK_CLAUDE_NEEDS_REPLAN_ON_MULTI_FILE", "0") == "1"
    fake_success_no_change = os.environ.get("MOCK_CLAUDE_FAKE_SUCCESS_NO_CHANGE", "0") == "1"
    repeat_needs_replan = os.environ.get("MOCK_CLAUDE_REPEAT_NEEDS_REPLAN", "0") == "1"

    if overflow_on_multi and len(allowed) > 1:
        print("STATUS: OVERFLOW_DETECTED")
        print(f"FILES: {', '.join(allowed)}")
        print("TESTS: not-run")
        print("SUMMARY: mock worker simulated overflow on a multi-file batch.")
        return

    if repeat_needs_replan:
        print("STATUS: NEEDS_REPLAN")
        print(f"FILES: {', '.join(allowed)}")
        print("TESTS: not-run")
        print("SUMMARY: mock worker keeps asking for a narrower replan so the orchestrator must stop looping.")
        return

    if needs_replan_pattern and len(allowed) > 1 and "REPLAN_HINT:" not in prompt:
        print("STATUS: NEEDS_REPLAN")
        print(f"FILES: {', '.join(allowed)}")
        print("TESTS: not-run")
        print("SUMMARY: mock worker requested a narrower replan for the broad multi-file batch.")
        return

    if fail_pattern and "REPLAN_HINT:" not in prompt:
        print("STATUS: FAILED")
        print(f"FILES: {', '.join(allowed)}")
        print("TESTS: not-run")
        print("SUMMARY: mock worker forced a failure so the orchestrator must rewrite the task.")
        return

    if fake_success_no_change:
        print("STATUS: SUCCESS")
        print(f"FILES: {', '.join(allowed)}")
        print("TESTS: not-run")
        print("SUMMARY: mock worker claimed success but intentionally changed nothing.")
        return

    instruction_match = re.search(r"Task:\n(.*?)\n\nAllowed files:", prompt, re.S)
    instruction = instruction_match.group(1).strip() if instruction_match else ""
    instruction_lower = instruction.lower()

    if "tests/test_placeholder.py" in instruction and allowed:
        edit_file(allowed[-1], "def test_placeholder():\n    assert 1 + 1 == 2\n")
        print("STATUS: SUCCESS")
        print(f"FILES: {allowed[-1]}")
        print("TESTS: pytest -q")
        print("SUMMARY: mock worker rewrote the placeholder test.")
        return

    if "deterministic assertion assert 1 + 1 == 2" in instruction_lower:
        for candidate in allowed:
            if candidate.endswith("tests/test_placeholder.py"):
                edit_file(candidate, "def test_placeholder():\n    assert 1 + 1 == 2\n")
                print("STATUS: SUCCESS")
                print(f"FILES: {candidate}")
                print("TESTS: pytest -q")
                print("SUMMARY: mock worker found the target test through fallback batching and rewrote it.")
                return

    if "tests/test_math_utils.py" in instruction:
        for candidate in allowed:
            if candidate.endswith("tests/test_math_utils.py"):
                edit_file(candidate, "from src.math_utils import add\n\n\ndef test_add():\n    assert add(1, 1) == 2\n")
                print("STATUS: SUCCESS")
                print(f"FILES: {candidate}")
                print("TESTS: pytest -q")
                print("SUMMARY: mock worker updated the math test after a narrow retry.")
                return

    print("STATUS: SUCCESS")
    print(f"FILES: {', '.join(allowed)}")
    print("TESTS: not-run")
    print("SUMMARY: mock worker completed an inspection-only batch.")


def main():
    prompt = last_argument()
    sleep_sec = int(os.environ.get("MOCK_CLAUDE_SLEEP_SEC", "0"))
    if sleep_sec > 0 and "REPLAN_HINT:" not in prompt:
        time.sleep(sleep_sec)
    if "Return this exact schema:" in prompt:
        emit_planner(prompt)
        return
    if "CONTENT_START" in prompt and "CONTENT_END" in prompt:
        emit_managed_response(prompt)
        return
    emit_worker_response(prompt)


if __name__ == "__main__":
    main()
