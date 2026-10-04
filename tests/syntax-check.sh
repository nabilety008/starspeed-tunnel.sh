#!/usr/bin/env bash
# Syntax-check every shell file in the repository.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

rc=0
while IFS= read -r -d '' f; do
  if bash -n "$f" 2>/tmp/sstest.synerr; then
    printf '  ok    %s\n' "$f"
  else
    printf '  FAIL  %s\n' "$f"
    sed 's/^/          /' /tmp/sstest.synerr
    rc=1
  fi
done < <(find . -path ./.git -prune -o \( -name '*.sh' -o -path './tests/stubs/*' \) -type f -print0)

exit $rc