#!/usr/bin/env bash
# Test suite for starspeed-tunnel.sh
#
#   bash tests/run-tests.sh              run everything
#   bash tests/run-tests.sh unit         run only test-unit*.sh
#
# Everything runs in disposable sandboxes with fake systemctl / ss / haproxy /
# ssh-keyscan. No real server, no real /etc, no network, no SSH.

set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091  # lib.sh is located at runtime
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

printf '%s============================================================%s\n' "$BOLD" "$OFF"
printf '%s starspeed-tunnel test suite%s\n' "$BOLD" "$OFF"
printf '%s repo: %s%s\n' "$BOLD" "$REPO_DIR" "$OFF"
printf '%s============================================================%s\n' "$BOLD" "$OFF"

filter=${1:-}

for f in "$TESTS_DIR"/test-*.sh; do
  [[ -e $f ]] || continue
  [[ -n $filter ]] && [[ $f != *"$filter"* ]] && continue
  out=$(bash "$f" 2>&1)
  rc=$?
  printf '%s\n' "$out"
  # Accumulate the child's counters into ours.
  p=$(printf '%s' "$out" | sed -n 's/^TESTSUMMARY:pass=\([0-9]*\).*/\1/p' | tail -n1)
  fl=$(printf '%s' "$out" | sed -n 's/.*fail=\([0-9]*\).*/\1/p' | tail -n1)
  PASS=$((PASS + ${p:-0}))
  FAIL=$((FAIL + ${fl:-0}))
  if [[ $rc -ne 0 ]]; then
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$(basename "$f"): suite exited $rc")
  fi
done

summary
exit $?