#!/usr/bin/env bash
# Shared helpers for the starspeed-tunnel test suite.
#
# Every test runs against a disposable sandbox: its own BASE dir, its own
# systemd unit dir, its own haproxy.cfg and its own fake systemd/ss/haproxy
# state. Nothing touches the real /etc, the real systemd, or any server.

set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
SCRIPT=$REPO_DIR/starspeed-tunnel.sh
STUBS=$TESTS_DIR/stubs

PASS=0
FAIL=0
FAILED_TESTS=()
CURRENT_TEST=''

# shellcheck disable=SC2034  # YELLOW is exported for suites that use it.
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
# shellcheck disable=SC2034
if [[ ! -t 1 ]]; then RED=''; GREEN=''; YELLOW=''; BOLD=''; OFF=''; fi

# --------------------------------------------------------------------------
# assertions
# --------------------------------------------------------------------------
t_start() {
  CURRENT_TEST=$1
  printf '\n%s--- %s%s\n' "$BOLD" "$1" "$OFF"
}

t_ok()   { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$GREEN" "$OFF" "$1"; }
t_fail() {
  FAIL=$((FAIL+1))
  FAILED_TESTS+=("$CURRENT_TEST: $1")
  printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"
  [[ $# -gt 1 ]] && printf '       %s\n' "$2"
  return 0
}

assert_eq() {
  local got=$1 want=$2 msg=$3
  if [[ $got == "$want" ]]; then t_ok "$msg"
  else t_fail "$msg" "expected: [$want]  got: [$got]"; fi
}

assert_ne() {
  local got=$1 unwanted=$2 msg=$3
  if [[ $got != "$unwanted" ]]; then t_ok "$msg"
  else t_fail "$msg" "should not equal: [$unwanted]"; fi
}

assert_contains() {
  local hay=$1 needle=$2 msg=$3
  if [[ $hay == *"$needle"* ]]; then t_ok "$msg"
  else t_fail "$msg" "missing: [$needle]"; fi
}

assert_not_contains() {
  local hay=$1 needle=$2 msg=$3
  if [[ $hay != *"$needle"* ]]; then t_ok "$msg"
  else t_fail "$msg" "unexpectedly present: [$needle]"; fi
}

assert_file() {
  if [[ -f $1 ]]; then t_ok "$2"; else t_fail "$2" "no such file: $1"; fi
}

assert_no_file() {
  if [[ ! -e $1 ]]; then t_ok "$2"; else t_fail "$2" "file should not exist: $1"; fi
}

assert_grep() {
  local file=$1 pat=$2 msg=$3
  if [[ -f $file ]] && grep -Eq -- "$pat" "$file"; then t_ok "$msg"
  else t_fail "$msg" "pattern not found in $file: $pat"; fi
}

assert_no_grep() {
  local file=$1 pat=$2 msg=$3
  if [[ ! -f $file ]] || ! grep -Eq -- "$pat" "$file"; then t_ok "$msg"
  else t_fail "$msg" "pattern unexpectedly found in $file: $pat"; fi
}

# Assert that a pattern does not appear anywhere in a text blob.
assert_no_grep_text() {
  local text=$1 pat=$2 msg=$3
  if grep -Eiq -- "$pat" <<<"$text"; then
    t_fail "$msg" "pattern unexpectedly matched: $pat"
    grep -Ein -- "$pat" <<<"$text" | head -3 | sed 's/^/       /'
  else
    t_ok "$msg"
  fi
}

# --------------------------------------------------------------------------
# sandbox
# --------------------------------------------------------------------------
SANDBOX=''

# Create a fresh sandbox. Sets BASE/STATE/BACKUP/HAPROXY_DIR/SD/HC/SSH_DIR and
# FAKE_SYSTEMD_STATE / FAKE_SS_LISTEN, and exports the tool overrides.
sandbox_new() {
  local name=${1:-sb}
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/sstest.${name}.XXXXXX")
  export BASE=$SANDBOX/etc
  export STATE=$BASE/state
  export BACKUP=$BASE/backups
  export HAPROXY_DIR=$BASE/haproxy
  export SD=$SANDBOX/units
  export HC=$SANDBOX/haproxy/haproxy.cfg
  export SSH_DIR=$SANDBOX/ssh
  export FAKE_SYSTEMD_STATE=$SANDBOX/systemd
  export FAKE_SS_LISTEN=''
  mkdir -p "$STATE" "$BACKUP" "$HAPROXY_DIR" "$SD" "$SSH_DIR" "$FAKE_SYSTEMD_STATE" "$(dirname "$HC")"

  export SST_BASE=$BASE
  export SST_STATE=$STATE
  export SST_BACKUP=$BACKUP
  export SST_HAPROXY_DIR=$HAPROXY_DIR
  export SST_SD=$SD
  export SST_HC=$HC
  export SST_SSH_DIR=$SSH_DIR
  export SST_SYSTEMCTL="$STUBS/systemctl"
  export SST_HAPROXY="$STUBS/haproxy"
  export SST_SS="$STUBS/ss"
  export SST_SSH_KEYSCAN="$STUBS/ssh-keyscan"
  export SST_ALLOW_NONROOT=1
  export SST_NO_APT=1
  export FAKE_KEYSCAN_FAIL=0
  unset FAKE_HAPROXY_FORBIDDEN_PORTS
  unset FAKE_HAPROXY_FAIL_FILE
}

sandbox_destroy() {
  [[ -n $SANDBOX && -d $SANDBOX ]] && rm -rf -- "$SANDBOX"
  SANDBOX=''
}

# Pretend the given TCP ports are already bound.
listen_on() { export FAKE_SS_LISTEN=$1; }

# Make haproxy -c fail, to exercise rollback.
haproxy_break() { export FAKE_HAPROXY_FORBIDDEN_PORTS=$1; }

# Feed a canned answer sequence to the interactive menu and capture output.
# Answers are one per line; a trailing 0 always exits the menu loop.
run_menu() {
  local answers=$1; shift
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/sst-answers.XXXXXX")
  printf '%s\n%s\n' "$answers" '0' >"$f"
  SST_PROMPT_SRC=$f "$SCRIPT" "$@" 2>&1
  rm -f "$f"
}

# Run a non-menu command line, e.g. --status or --setup-code 1.
run_sst() {
  SST_PROMPT_SRC=/dev/null "$SCRIPT" "$@" 2>&1
}

# Answer sequence for menu "1) Setup Iran".
#   iran_answers 1 45438 45438          -> one foreign, frontend 45438, inbound 45438
#   iran_answers 2 45438 45438 45439 45439
# The menu selection itself is included, so the sequence is complete.
# Answer sequence for menu "1) Setup Iran".
#   iran_answers 1 45438 45438      -> one foreign
#   iran_answers 2 45439 45439      -> "2" foreigns, but only the NEW one is
#                                      prompted for, since already-configured
#                                      foreigns are reused without asking.
iran_answers() {
  local count=$1; shift
  printf '1\n%s\n' "$count"   # menu selection, then total number of foreigns
  printf '%s\n' "$@"          # frontend/inbound pairs for the new foreigns only
}

# Confirmations are consumed only when actually asked, so allow a generous
# number of y answers and append them to another sequence.
with_confirms() {
  local n=$1; shift
  local out=$*' '
  local i
  for (( i = 0; i < n; i++ )); do out+=$'y '; done
  printf '%s' "$out"
}

# Answer sequence for menu_setup_foreign: foreign IP, setup code.
foreign_answers() {
  printf '%s\n%s\n' "$1" "$2"
}

# Extract a value from a state file.
lane_of()  { awk -F= -v k="LANE$2" '$1==k {print $2}' "$STATE/foreign-$1.env"; }
front_of() { awk -F= '$1=="FRONTEND" {print $2}' "$STATE/foreign-$1.env"; }
inb_of()   { awk -F= '$1=="INBOUND"  {print $2}' "$STATE/foreign-$1.env"; }
lanes_of() { local n; for n in 1 2 3 4; do lane_of "$1" "$n"; done | tr '\n' ' '; }

# Listeners reported by the fake ss, e.g. for asserting what the installer
# asked HAProxy to bind.
frag() { cat "$HAPROXY_DIR/fragments/starspeed-$1.cfg" 2>/dev/null; }

summary() {
  printf '\n%s============================================================%s\n' "$BOLD" "$OFF"
  printf '%s  RESULTS: %d passed, %d failed%s\n' "$BOLD" "$PASS" "$FAIL" "$OFF"
  if (( FAIL > 0 )); then
    printf '%s  failures:%s\n' "$RED" "$OFF"
    local f
    for f in "${FAILED_TESTS[@]}"; do printf '    - %s\n' "$f"; done
    return 1
  fi
  printf '%s  all tests passed%s\n' "$GREEN" "$OFF"
  return 0
}