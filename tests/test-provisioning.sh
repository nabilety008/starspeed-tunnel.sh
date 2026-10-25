#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

sandbox_new provisioning
src=$SANDBOX/live.cfg
printf 'known-good\n' >"$src"

t_start "backup_file recreates a missing backup directory"
rm -rf -- "$BACKUP"
out=$(bash -c 'source "$1" --help >/dev/null; backup_file "$2"' _ "$SCRIPT" "$src" 2>&1)
path=$(printf '%s\n' "$out" | tail -1)
assert_file "$path" "missing backup directory is recreated and a real backup is written"

t_start "backup_file fails instead of reporting a nonexistent backup"
bad=$SANDBOX/not-a-directory
printf x >"$bad"
if SST_BACKUP="$bad/child" bash -c 'source "$1" --help >/dev/null; backup_file "$2"' _ "$SCRIPT" "$src" >"$SANDBOX/bad.out" 2>&1; then
  t_fail "copy failure returns nonzero"
else
  t_ok "copy failure returns nonzero"
fi
assert_contains "$(cat "$SANDBOX/bad.out")" "backup directory" "backup failure is actionable"
assert_not_contains "$(cat "$SANDBOX/bad.out")" ".cfg.20" "no fake successful backup path is printed"

t_start "changed or untrusted SSH host fingerprints are refused"
export SST_TRUSTED_HOST_FINGERPRINT='SHA256:does-not-match'
if bash -c 'source "$1" --help >/dev/null; ensure_known_hosts 1 198.51.100.10 22' _ "$SCRIPT" >"$SANDBOX/fp.out" 2>&1; then
  t_fail "mismatched fingerprint is rejected"
else
  t_ok "mismatched fingerprint is rejected"
fi
assert_no_file "$SSH_DIR/starspeed-tunnel_iran1" "mismatched key is never installed"

t_start "automatic SSH authentication failure is explicit"
export SST_TRUSTED_HOST_FINGERPRINT='SHA256:b1NvhIYg7LdQRhqTXmfzawcNvAw/zS6XuoK/2Btod7M'
bash -c 'source "$1" --help >/dev/null; ensure_ssh_key 1; ensure_known_hosts 1 198.51.100.10 22' _ "$SCRIPT" >/dev/null 2>&1
if FAKE_SSH_AUTH_FAIL=1 bash -c 'source "$1" --help >/dev/null; authorize_key_remote 1 198.51.100.10 22' _ "$SCRIPT" >"$SANDBOX/auth.out" 2>&1; then
  t_fail "admin SSH authentication failure stops provisioning"
else
  t_ok "admin SSH authentication failure stops provisioning"
fi
assert_contains "$(cat "$SANDBOX/auth.out")" "automatic SSH authorization failed" "authentication error is actionable"

t_start "reverse-port or HAProxy readiness failures are not reported as ready"
bash -c 'source "$1" --help >/dev/null; write_state 1 23457 45438 46101 46102 46103 46104' _ "$SCRIPT" >/dev/null
if FAKE_SSH_HEALTH_FAIL=1 bash -c 'source "$1" --help >/dev/null; remote_tunnel_health 1 198.51.100.10 22' _ "$SCRIPT" >"$SANDBOX/health.out" 2>&1; then
  t_fail "remote health failure returns nonzero"
else
  t_ok "remote health failure returns nonzero"
fi
assert_contains "$(cat "$SANDBOX/health.out")" "verification failed" "reverse-port/HAProxy failure is actionable"

t_start "partial lane startup failure does not restart another node"
: >"$FAKE_SYSTEMD_STATE/starspeed-tunnel-f2-lane1.service.active"
before=$(stat -c %Y "$FAKE_SYSTEMD_STATE/starspeed-tunnel-f2-lane1.service.active")
if FAKE_SYSTEMD_FAIL_ON_START=starspeed-tunnel-f1-lane2.service bash -c 'source "$1" --help >/dev/null; enable_units 1' _ "$SCRIPT" >"$SANDBOX/start.out" 2>&1; then
  t_fail "partial startup failure returns nonzero"
else
  t_ok "partial startup failure returns nonzero"
fi
after=$(stat -c %Y "$FAKE_SYSTEMD_STATE/starspeed-tunnel-f2-lane1.service.active")
assert_eq "$after" "$before" "unrelated node service remains untouched"

sandbox_destroy
summary
