#!/usr/bin/env bash
set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

BOOTSTRAP=$REPO_DIR/install.sh
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/tools"
cat >"$TMPROOT/tools/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
out=''
while (($#)); do
  case $1 in
    --output) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cp "$SST_TEST_PAYLOAD" "$out"
EOF
chmod +x "$TMPROOT/tools/curl"
cat >"$TMPROOT/tools/wget" <<'EOF'
#!/usr/bin/env bash
set -eu
out=''
while (($#)); do
  case $1 in
    --output-document=*) out=${1#*=}; shift ;;
    *) shift ;;
  esac
done
cp "$SST_TEST_PAYLOAD" "$out"
EOF
chmod +x "$TMPROOT/tools/wget"

t_start 'bootstrap source is English-only'
if grep -Eq '[؀-ۿ]' "$BOOTSTRAP"; then t_fail 'bootstrap contains no Persian/Arabic script'; else t_ok 'bootstrap contains no Persian/Arabic script'; fi

make_os() {
  local version=${1:-24.04}
  printf 'ID=ubuntu\nVERSION_ID="%s"\nPRETTY_NAME="Ubuntu %s"\n' "$version" "$version" >"$TMPROOT/os-release"
}

make_payload() {
  cat >"$TMPROOT/payload.sh" <<'EOF'
#!/usr/bin/env bash
APP=starspeed-tunnel
printf '%s\n' "$*" >>"$SST_TEST_EXEC_LOG"
EOF
}

run_bootstrap() {
  SST_INSTALL_ALLOW_NONROOT=1 \
  SST_INSTALL_OS_RELEASE="$TMPROOT/os-release" \
  SST_INSTALL_DIR="$TMPROOT/bin" \
  SST_INSTALL_URL="https://example.invalid/starspeed-tunnel.sh" \
  SST_TEST_EXEC_LOG="$TMPROOT/exec.log" \
  SST_TEST_PAYLOAD="$TMPROOT/payload.sh" \
  PATH="$TMPROOT/tools:$PATH" \
  bash "$BOOTSTRAP" "$@"
}

t_start 'bootstrap installs and launches a validated download'
make_os; make_payload; mkdir -p "$TMPROOT/bin"
run_bootstrap --status >/dev/null
assert_file "$TMPROOT/bin/starspeed-tunnel" 'entrypoint installed'
assert_eq "$(tail -n1 "$TMPROOT/exec.log")" '--status' 'arguments passed to entrypoint'

t_start '--lang fa remains compatible and still launches the entrypoint'
: >"$TMPROOT/exec.log"
run_bootstrap --lang fa >/dev/null
assert_eq "$(sed -n '1p' "$TMPROOT/exec.log")" '--lang fa' 'compatibility option passed through'
assert_eq "$(sed -n '2p' "$TMPROOT/exec.log")" '' 'menu launched after compatibility notice'

t_start '--lang en and default both launch an English menu'
: >"$TMPROOT/exec.log"
run_bootstrap --lang en >/dev/null
assert_eq "$(sed -n '1p' "$TMPROOT/exec.log")" '--lang en' 'English language persisted'
assert_eq "$(sed -n '2p' "$TMPROOT/exec.log")" '' 'English menu launched'
: >"$TMPROOT/exec.log"
run_bootstrap >/dev/null
assert_eq "$(cat "$TMPROOT/exec.log")" '' 'default launch passes no language override'

t_start 'wget downloads and launches the same validated entrypoint'
: >"$TMPROOT/exec.log"
SST_INSTALL_FETCHER=wget run_bootstrap --status >/dev/null
assert_eq "$(tail -n1 "$TMPROOT/exec.log")" '--status' 'wget path launches entrypoint'

t_start 'repeated install replaces only the executable'
mkdir -p "$TMPROOT/config"; printf 'keep\n' >"$TMPROOT/config/state"
run_bootstrap --status >/dev/null
assert_eq "$(cat "$TMPROOT/config/state")" 'keep' 'unrelated persistent configuration preserved'

t_start 'unsupported operating system fails before download/install'
make_os 20.04
if run_bootstrap --status >"$TMPROOT/unsupported.out" 2>&1; then
  t_fail 'unsupported OS rejected' 'bootstrap unexpectedly succeeded'
else
  t_ok 'unsupported OS rejected'
fi
assert_contains "$(cat "$TMPROOT/unsupported.out")" 'unsupported operating system' 'clear unsupported OS error'

t_start 'installer errors remain English with --lang fa'
if run_bootstrap --lang fa --status >"$TMPROOT/fa-error.out" 2>&1; then
  t_fail 'unsupported OS rejected with --lang fa' 'bootstrap unexpectedly succeeded'
else
  t_ok 'unsupported OS rejected with --lang fa'
fi
assert_contains "$(cat "$TMPROOT/fa-error.out")" 'unsupported operating system' 'error remains English'

t_start 'invalid download never replaces a working install'
make_os; cp "$TMPROOT/bin/starspeed-tunnel" "$TMPROOT/known-good"
printf '<html>error</html>\n' >"$TMPROOT/payload.sh"
if run_bootstrap --status >"$TMPROOT/invalid.out" 2>&1; then
  t_fail 'invalid download rejected' 'bootstrap unexpectedly succeeded'
else
  t_ok 'invalid download rejected'
fi
if cmp -s "$TMPROOT/bin/starspeed-tunnel" "$TMPROOT/known-good"; then
  t_ok 'existing executable preserved after failed validation'
else
  t_fail 'existing executable preserved after failed validation'
fi

summary
exit $?
