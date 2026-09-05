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
require_cmd junit-to-ctrf

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
  wrap_node_junit "$raw" "$xml" "$file" || true
  return "$rc"
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

junit-to-ctrf '/logs/verifier/base-*.xml' \
  -o /logs/verifier/base-ctrf.json -t node --use-suite-name >> "$RUN_LOG" 2>&1
junit-to-ctrf '/logs/verifier/new-*.xml' \
  -o /logs/verifier/new-ctrf.json -t node --use-suite-name >> "$RUN_LOG" 2>&1

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
