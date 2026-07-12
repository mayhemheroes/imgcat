#!/usr/bin/env bash
#
# mayhem/test.sh — RUN imgcat's upstream functional test suite (tests/run), already built by
# mayhem/build.sh (`make imgcat`). This is the project's OWN golden-output suite: it invokes the
# CLI across every colour depth / resize / half-height option and diffs stdout against the checked-in
# `tests/out/**` known-answer files (assert_eq), plus assert_ok / assert_fail cases. It asserts
# BEHAVIOUR, not just exit status — a no-op/exit(0) patch flips the assert_fail cases and mismatches
# every golden diff, so it fails. Emits a CTRF summary and exits non-zero iff any case failed.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

IMGCAT_BIN="$SRC/imgcat"
if [ ! -x "$IMGCAT_BIN" ]; then
  echo "test.sh: $IMGCAT_BIN missing — mayhem/build.sh must build it first" >&2
  exit 1
fi

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Run the suite; capture output and strip ANSI colour so we can parse the counts.
raw="$(bash "$SRC/tests/run" "$IMGCAT_BIN" 2>&1)"; rc=$?
clean="$(printf '%s\n' "$raw" | sed -E 's/\x1b\[[0-9;]*m//g')"
printf '%s\n' "$clean"

passed=0; failed=0
if printf '%s\n' "$clean" | grep -qE '[0-9]+/[0-9]+ tests failed'; then
  line="$(printf '%s\n' "$clean" | grep -oE '[0-9]+/[0-9]+ tests failed' | tail -1)"
  failed="$(printf '%s' "$line" | sed -E 's#([0-9]+)/([0-9]+).*#\1#')"
  total="$(printf '%s' "$line" | sed -E 's#([0-9]+)/([0-9]+).*#\2#')"
  passed=$(( total - failed ))
elif printf '%s\n' "$clean" | grep -qE '[0-9]+ tests passed'; then
  passed="$(printf '%s\n' "$clean" | grep -oE '[0-9]+ tests passed' | tail -1 | grep -oE '^[0-9]+')"
  failed=0
else
  # No recognizable summary — the runner itself broke; report one failure so this fails loudly.
  echo "test.sh: could not parse tests/run output (runner error?)" >&2
  emit_ctrf "imgcat-tests-run" 0 1
  exit 1
fi

emit_ctrf "imgcat-tests-run" "$passed" "$failed"
