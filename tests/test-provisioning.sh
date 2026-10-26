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

t_start "Xray listener detection accepts wildcard binds"
export FAKE_SS_LISTEN=45438
for bind in 0.0.0.0 '*' '[::]'; do
  export FAKE_SS_BIND=$bind
  if bash -c 'source "$1" --help >/dev/null; local_listening 45438' _ "$SCRIPT"; then
    t_ok "wildcard listener $bind is detected"
  else
    t_fail "wildcard listener $bind is detected"
  fi
done

t_start "unavailable Xray listener remains degraded"
export FAKE_SS_LISTEN=''
export SST_READY_ATTEMPTS=1 SST_READY_INITIAL_DELAY=0
if bash -c 'source "$1" --help >/dev/null; wait_for_local_listener 45438' _ "$SCRIPT" >"$SANDBOX/xray-down.out" 2>&1; then
  t_fail "missing Xray listener fails readiness"
else
  t_ok "missing Xray listener fails readiness"
fi

t_start "delayed Xray startup is accepted within bounded retries"
export FAKE_SS_DIR=$SANDBOX/listeners
mkdir -p "$FAKE_SS_DIR"
( sleep 1; : >"$FAKE_SS_DIR/45438" ) &
if SST_READY_ATTEMPTS=3 SST_READY_INITIAL_DELAY=1 bash -c 'source "$1" --help >/dev/null; wait_for_local_listener 45438' _ "$SCRIPT" >/dev/null 2>&1; then
  t_ok "delayed listener becomes ready"
else
  t_fail "delayed listener becomes ready"
fi
unset FAKE_SS_DIR FAKE_SS_BIND

t_start "foreign status never reports READY when Xray is absent"
export FAKE_SS_LISTEN=''
bash -c 'source "$1" --help >/dev/null; set_role foreign; for n in 1 2 3 4; do "$SST_SYSTEMCTL" start "starspeed-tunnel-f1-lane$n.service"; done; show_foreign_status 1' _ "$SCRIPT" >"$SANDBOX/status.out" 2>&1
assert_contains "$(cat "$SANDBOX/status.out")" "Tunnel Status: DEGRADED" "status definitions include actual Xray reachability"

t_start "an immediately closed reverse target fails forwarding health"
if FAKE_TCP_PROBE_FAIL=1 bash -c 'source "$1" --help >/dev/null; tcp_forward_healthy 127.0.0.1 45001' _ "$SCRIPT"; then
  t_fail "closed reverse target is rejected"
else
  t_ok "closed reverse target is rejected"
fi

t_start "WebSocket probe accepts 101 immediately and rejects a wrong path"
cat >"$SANDBOX/python3" <<'SH'
#!/usr/bin/env bash
exec python "$@"
SH
chmod +x "$SANDBOX/python3"
cat >"$SANDBOX/ws-server.py" <<'PY'
import socket,sys,time
s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(2)
open(sys.argv[1],'w').write(str(s.getsockname()[1]))
for _ in range(2):
    c,_=s.accept(); data=b''
    while b'\r\n\r\n' not in data: data+=c.recv(4096)
    if data.startswith(b'GET /ok '):
        c.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
        time.sleep(1)
    else:
        c.sendall(b'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n')
    c.close()
PY
PATH="$SANDBOX:$PATH" python3 "$SANDBOX/ws-server.py" "$SANDBOX/ws-port" & wspid=$!
for _ in 1 2 3 4 5; do [[ -s $SANDBOX/ws-port ]] && break; sleep .2; done
wsport=$(cat "$SANDBOX/ws-port")
if MSYS2_ARG_CONV_EXCL='*' PATH="$SANDBOX:$PATH" bash -c 'source "$1" --help >/dev/null; verify_public_websocket 127.0.0.1 "$2" /ok' _ "$SCRIPT" "$wsport"; then
  t_ok "HTTP 101 is success even when the upgraded socket stays open"
else
  t_fail "HTTP 101 is success even when the upgraded socket stays open"
fi
if MSYS2_ARG_CONV_EXCL='*' PATH="$SANDBOX:$PATH" bash -c 'source "$1" --help >/dev/null; verify_public_websocket 127.0.0.1 "$2" /wrong' _ "$SCRIPT" "$wsport"; then
  t_fail "wrong WebSocket path is rejected"
else
  t_ok "wrong WebSocket path is rejected"
fi
wait "$wspid"

sandbox_destroy
summary
