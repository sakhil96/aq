#!/bin/bash
# Verifier entrypoint (canonical frame). Patching and grading live in
# tests/grader.py; this script owns the task-specific part: run the suites,
# write machine-readable reports under /logs/verifier/, and apply any report
# fixups before grading. Edit ONLY between the RUN TESTS markers.
set -uo pipefail
trap 'if [ ! -f /logs/verifier/reward.json ] && [ ! -f /logs/verifier/reward.txt ]; then mkdir -p /logs/verifier; echo -1 > /logs/verifier/reward.txt; fi' EXIT
log() { echo "[verifier] $*"; }
cd /app || { mkdir -p /logs/verifier; exit 6; }

python3 /tests/grader.py prepare || exit $?
[ -f /logs/verifier/reward.json ] && exit 0   # model.patch didn't apply -> graded 0

# Canonical raw-output log: send every suite's combined stdout+stderr here
# (use run_log, or pipe through tee -a "$RUN_LOG" when feeding a reporter) so
# the reason a test failed is never lost. Never silence a test run.
export RUN_LOG=/logs/verifier/run.log
: > "$RUN_LOG" 2>/dev/null || true
run_log() { echo "+ $*" >> "$RUN_LOG" 2>/dev/null; "$@" 2>&1 | tee -a "$RUN_LOG"; return "${PIPESTATUS[0]}"; }

# >>> RUN TESTS (task-specific) <<<
require_cmd() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing $1; PATH=$PATH"; exit 127; }; }
require_cmd node
require_cmd python3

NEW_FILES=(
  test/close/closeStages.test.js
  test/close/monthClose.test.js
)

# Node 20 emits test cases directly below <testsuites>. Wrap each file's
# report in a path-named suite so CTRF names are stable and collision-free.
wrap_node_junit() {
  local raw="$1" out="$2" suite="$3"
  [ -s "$raw" ] || return 1
  {
    sed -n '1p' "$raw"
    printf '<testsuites>\n<testsuite name="%s">\n' "$suite"
    sed '1,2d;$d' "$raw"
    printf '</testsuite>\n</testsuites>\n'
  } > "$out"
}

run_node_file() {
  local mode="$1" ordinal="$2" file="$3"
  local raw="/logs/verifier/${mode}-${ordinal}.raw"
  local xml="/logs/verifier/${mode}-${ordinal}.xml"
  node --test \
    --test-reporter=spec --test-reporter-destination=stdout \
    --test-reporter=junit --test-reporter-destination="$raw" \
    "$file" 2>&1 | tee -a "$RUN_LOG"
  local rc="${PIPESTATUS[0]}"
  printf '[verifier] %s exit status=%d file=%s\n' \
    "$mode" "$rc" "$file" | tee -a "$RUN_LOG"
  wrap_node_junit "$raw" "$xml" "$file" || true
  return "$rc"
}

junit_to_ctrf() {
  local pattern="$1"
  local output="$2"

  python3 - "$pattern" "$output" <<'PY'
import glob
import json
import math
import os
import re
import sys
import xml.etree.ElementTree as ET

pattern, output = sys.argv[1:3]
tests = []
counts = {"passed": 0, "failed": 0, "skipped": 0}
raw_counts = {"failure": 0, "error": 0, "skipped": 0}


def local_name(tag):
    return tag.rsplit("}", 1)[-1]


def milliseconds(value):
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        return 0
    if not math.isfinite(seconds) or seconds < 0:
        return 0
    return int(math.floor(seconds * 1000 + 0.5))


def joined(values):
    result = []
    for value in values:
        value = value.strip()
        if value and value not in result:
            result.append(value)
    return "\n".join(result)


def add_test(case, suites):
    case_name = (case.get("name") or "").strip()
    if not case_name:
        return

    markers = [
        (local_name(child.tag), child)
        for child in case
        if local_name(child.tag) in ("failure", "error", "skipped")
    ]
    errors = [child for kind, child in markers if kind == "error"]
    failures = [child for kind, child in markers if kind == "failure"]
    skipped = [child for kind, child in markers if kind == "skipped"]

    if errors:
        raw_status, status, details = "error", "failed", errors + failures
    elif failures:
        raw_status, status, details = "failure", "failed", failures
    elif skipped:
        raw_status, status, details = "skipped", "skipped", skipped
    else:
        raw_status, status, details = "passed", "passed", []

    file_suite = suites[0] if suites else ""
    result = {
        "name": f"{file_suite}: {case_name}" if file_suite else case_name,
        "status": status,
        "duration": milliseconds(case.get("time")),
        "rawStatus": raw_status,
    }

    if suites:
        result["suite"] = list(suites)
    file_path = (case.get("file") or "").strip() or file_suite
    if file_path:
        result["filePath"] = file_path

    if details:
        marker_types = joined((marker.get("type") or "") for marker in details)
        messages = joined((marker.get("message") or "") for marker in details)
        traces = joined("".join(marker.itertext()) for marker in details)
        if marker_types:
            result["type"] = marker_types
        if messages:
            result["message"] = messages
        if traces:
            result["trace"] = traces

    for tag in ("system-out", "system-err"):
        lines = []
        for child in case:
            if local_name(child.tag) == tag:
                lines.extend("".join(child.itertext()).splitlines())
        if lines:
            result["stdout" if tag == "system-out" else "stderr"] = lines

    counts[status] += 1
    if raw_status in raw_counts:
        raw_counts[raw_status] += 1
    tests.append(result)


def walk_suite(suite, parents=()):
    label = (suite.get("name") or "").strip()
    suites = (*parents, label) if label else parents
    for child in suite:
        tag = local_name(child.tag)
        if tag == "testcase":
            add_test(child, suites)
        elif tag == "testsuite":
            walk_suite(child, suites)


def natural_key(path):
    return tuple(
        (1, int(part)) if part.isdigit() else (0, part)
        for part in re.split(r"(\d+)", path)
    )


paths = sorted(glob.glob(pattern), key=natural_key)
for path in paths:
    try:
        root = ET.parse(path).getroot()
        if local_name(root.tag) == "testsuite":
            walk_suite(root)
        else:
            for child in root:
                if local_name(child.tag) == "testsuite":
                    walk_suite(child)
                elif local_name(child.tag) == "testcase":
                    add_test(child, ())
    except (OSError, ET.ParseError) as error:
        print(
            f"[verifier] WARNING: cannot parse JUnit report {path}: {error}",
            file=sys.stderr,
        )

duration = sum(test["duration"] for test in tests)
report = {
    "reportFormat": "CTRF",
    "specVersion": "1.0.0",
    "results": {
        "tool": {"name": "node"},
        "summary": {
            "tests": len(tests),
            "passed": counts["passed"],
            "failed": counts["failed"],
            "skipped": counts["skipped"],
            "pending": 0,
            "other": 0,
            "start": 0,
            "stop": 0,
            "duration": duration,
            "suites": len({
                tuple(test.get("suite", ()))
                for test in tests
            }),
            "extra": raw_counts,
        },
        "tests": tests,
    },
}

os.makedirs(os.path.dirname(output) or ".", exist_ok=True)
with open(output, "w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=2, ensure_ascii=False)
    handle.write("\n")

print(
    f"[verifier] wrote {len(tests)} CTRF results "
    f"from {len(paths)} JUnit files to {output}"
)
PY
}

rm -f /logs/verifier/base-*.xml /logs/verifier/base-*.raw \
  /logs/verifier/new-*.xml /logs/verifier/new-*.raw \
  /logs/verifier/base-ctrf.json /logs/verifier/new-ctrf.json

set +e
base_i=0
while IFS= read -r file; do
  run_node_file base "$base_i" "$file"
  base_i=$((base_i + 1))
done < <(find test -type f -name '*.test.js' \
  ! -path 'test/close/closeStages.test.js' \
  ! -path 'test/close/monthClose.test.js' | LC_ALL=C sort)

for i in "${!NEW_FILES[@]}"; do
  run_node_file new "$i" "${NEW_FILES[$i]}"
done

junit_to_ctrf '/logs/verifier/base-*.xml' \
  /logs/verifier/base-ctrf.json >> "$RUN_LOG" 2>&1
junit_to_ctrf '/logs/verifier/new-*.xml' \
  /logs/verifier/new-ctrf.json >> "$RUN_LOG" 2>&1

ctrf_check() {
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; then
    log "CTRF ok: $1"
  else
    log "WARNING: CTRF missing/invalid: $1"
    rm -f "$1"
  fi
}
ctrf_check /logs/verifier/base-ctrf.json
ctrf_check /logs/verifier/new-ctrf.json
set -e
# >>> END RUN TESTS <<<

# Surface raw suite output into stdout (the harness captures it) so failures
# stay debuggable even when a framework report omits the reason.
_seen=""
for _rl in "$RUN_LOG" /logs/verifier/*_run.log /logs/verifier/*-run.log /logs/verifier/*.log /logs/verifier/*.out; do
  [ -f "$_rl" ] && [ -s "$_rl" ] || continue
  case " $_seen " in *" $_rl "*) continue ;; esac
  case "${_rl##*/}" in *convert*.log|ctrf*.log|junit*.log) continue ;; esac
  _seen="$_seen $_rl"
  echo "===== raw suite output: ${_rl##*/} ====="
  cat "$_rl"
done 2>/dev/null
echo "===== grade ====="

python3 /tests/grader.py grade
log "reward.json=$(cat /logs/verifier/reward.json 2>/dev/null)"

# Uniform top level: keep only the canonical artifacts in /logs/verifier and
# move every framework-native report/log under reports/.
mkdir -p /logs/verifier/reports 2>/dev/null
for _f in /logs/verifier/*; do
  case "${_f##*/}" in
    reward.json|reward.txt|ctrf.json|run.log|test-stdout.txt|reports) continue ;;
  esac
  [ -f "$_f" ] && mv -f "$_f" /logs/verifier/reports/ 2>/dev/null
done
