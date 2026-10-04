#!/usr/bin/env bash
# End-to-end menu flows against a fully fake /etc, systemd, haproxy and ssh.
#
# Covered: Iran setup, idempotent re-run, adding Foreign #2 without disturbing
# #1, foreign-side setup, authorize-key, status, repair, removing one foreign,
# uninstall, and rollback when 'haproxy -c' fails.
#
# shellcheck disable=SC1091  # lib.sh is located at runtime via BASH_SOURCE
# shellcheck disable=SC2012  # sandbox paths are known-safe, ls is fine here
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

sandbox_new integration

# Path names are rebound by every sandbox_new call, so re-export the ones the
# assertions below refer to.
FRAG1=$HAPROXY_DIR/foreign-1.cfg
FRAG2=$HAPROXY_DIR/foreign-2.cfg
UNIT1=$SD/starspeed-tunnel-f1-lane1.service
AUTH=$SSH_DIR/authorized_keys

# ---------------------------------------------------------------------------
t_start "Iran setup creates managed HAProxy config"
out=$(run_menu "$(iran_answers 1 45438 45438)")
assert_file "$HC" "haproxy.cfg created"
assert_file "$FRAG1" "Foreign #1 fragment created"
assert_no_file "$FRAG2" "no Foreign #2 fragment yet"
assert_contains "$(cat "$HC")" "include $FRAG1" "top-level config includes the fragment"
assert_contains "$(cat "$HC")" "starspeed-tunnel managed includes" "managed block is delimited"

t_start "fragment has one frontend, one backend and four distinct lanes"
frag=$(cat "$FRAG1")
assert_contains "$frag" "bind 0.0.0.0:45438" "frontend binds the agreed port"
assert_eq "$(grep -c '^frontend ' <<<"$frag")" "1" "exactly one frontend"
assert_eq "$(grep -c '^backend ' <<<"$frag")" "1" "exactly one lane backend"
assert_eq "$(grep -c '^    server ' <<<"$frag")" "4" "four lane servers"
lanes=$(grep -o '127\.0\.0\.1:[0-9]*' <<<"$frag" | sort -u)
assert_eq "$(wc -l <<<"$lanes")" "4" "all four lane targets are distinct"
assert_contains "$frag" "check inter 2s" "lane health checking enabled"

t_start "no traffic generation, shaping or fake-speed features"
combined=$(cat "$FRAG1" "$HC")
# Matched as whole HAProxy/keyword tokens so ordinary words such as
# "tcplog" or "check" in a comment cannot cause a false positive.
assert_no_grep_text "$combined" '\b(iperf|iperf3|upload|shaping|traffic[- ]?shap)' \
  "no traffic generation in the generated config"
assert_no_grep_text "$combined" '(^|[[:space:]])(tc|qdisc|ifb)[[:space:]]' \
  "no traffic shaping rules in the generated config"
assert_no_grep_text "$combined" '^[[:space:]]*rate[[:space:]]' \
  "no rate limiting in the generated config"
assert_no_grep_text "$combined" '(^|[[:space:]])delay[[:space:]]' \
  "no artificial delay in the generated config"

t_start "Iran enables haproxy at boot"
assert_eq "$("$SST_SYSTEMCTL" is-enabled haproxy)" "enabled" "haproxy enabled at boot"

t_start "Iran setup prints a usable setup code for the foreign"
code=$(grep -oE '[A-Za-z0-9+/=]{20,}' <<<"$out" | tail -1)
if [[ -n $code ]]; then
  t_ok "a setup code was printed for the foreign"
else
  t_fail "a setup code was printed for the foreign"
fi

# ---------------------------------------------------------------------------
t_start "re-running Iran setup is idempotent"
before_hc=$(cat "$HC"); before_frag=$(cat "$FRAG1")
run_menu "$(iran_answers 1 45438 45438)" >/dev/null
assert_eq "$(cat "$HC")" "$before_hc" "haproxy.cfg byte-identical on re-run"
assert_eq "$(cat "$FRAG1")" "$before_frag" "fragment byte-identical on re-run"
assert_eq "$(grep -c 'include ' "$HC")" "1" "no duplicate include lines"
assert_eq "$(grep -c 'managed includes' "$HC")" "2" "exactly one begin/end marker pair"

t_start "re-run does not consume a fresh port allocation"
assert_eq "$(lanes_of 1)" "46101 46102 46103 46104 " "stored lanes are preserved verbatim"

t_start "setup preserves unrelated HAProxy configuration"
mkdir -p "$HAPROXY_DIR/conf.d"
printf 'frontend operator_owned\n    bind :9999\n' >"$HAPROXY_DIR/conf.d/operator.cfg"
OPERATOR_INCLUDE="include $HAPROXY_DIR/conf.d/*.cfg"
printf '%s\n' "$OPERATOR_INCLUDE" >>"$HC"
run_menu "$(iran_answers 1 45438 45438)" >/dev/null
assert_file "$HAPROXY_DIR/conf.d/operator.cfg" "operator include untouched"
assert_contains "$(cat "$HC")" "$OPERATOR_INCLUDE" "operator's own include line survived"

# ---------------------------------------------------------------------------
t_start "adding Foreign #2 leaves Foreign #1 byte-identical"
before1=$(cat "$FRAG1")
# Foreign #1 already exists, so the installer asks only for the new foreign.
run_menu "$(iran_answers 2 45439 45439)" >/dev/null
assert_file "$FRAG2" "Foreign #2 fragment created"
assert_contains "$(cat "$FRAG2")" "bind 0.0.0.0:45439" "#2 frontend uses the second port"
assert_contains "$(cat "$HC")" "include $FRAG2" "top-level config now includes both"
assert_eq "$(cat "$FRAG1")" "$before1" "Foreign #1 fragment unchanged"

t_start "the two foreigns share no ports at all"
p1=$(grep -o '[0-9]\{4,5\}' <<<"$(cat "$FRAG1")" | sort -u)
p2=$(grep -o '[0-9]\{4,5\}' <<<"$(cat "$FRAG2")" | sort -u)
assert_eq "$(comm -12 <(printf '%s\n' "$p1") <(printf '%s\n' "$p2") | wc -l)" "0" \
  "no port number appears in both fragments"
assert_ne "$(front_of 1)" "$(front_of 2)" "state records different frontends"
assert_ne "$(lanes_of 1)" "$(lanes_of 2)" "state records different lane blocks"
for i in 1 2; do
  assert_file "$STATE/foreign-$i.env" "state file for foreign #$i exists"
done

# ---------------------------------------------------------------------------
t_start "foreign-side setup writes hardened, independent lane units"
# The foreign host is a different machine, so it gets its own sandbox. It only
# knows the Iran address, its foreign number, its Xray port and the setup code.
CODE1=$(run_sst --setup-code 1 | tr -d '\r\n')
sandbox_new foreignhost
FRAG1=$HAPROXY_DIR/foreign-1.cfg
FRAG2=$HAPROXY_DIR/foreign-2.cfg
UNIT1=$SD/starspeed-tunnel-f1-lane1.service
AUTH=$SSH_DIR/authorized_keys

# The existing Xray inbound must appear to be listening, otherwise the installer
# correctly refuses to proceed.
listen_on "45438"

# Answers: menu 2, Iran IP, foreign number, Xray inbound, setup code.
out=$(run_menu "$(printf '2\n198.51.100.10\n1\n45438\n%s\n' "$CODE1")")
unit=$(cat "$UNIT1")
assert_contains "$unit" "root@198.51.100.10" "unit targets the Iran host"
assert_contains "$unit" "-R 127.0.0.1:46101:127.0.0.1:45438" "lane 1 forwards to the Xray inbound"
assert_contains "$unit" "WantedBy=multi-user.target" "unit starts at boot"
assert_contains "$unit" "Restart=always" "unit restarts on failure"
assert_contains "$unit" "RestartSec=" "restart has a backoff"
assert_contains "$unit" "BatchMode=yes" "unit can never prompt for a password"
assert_contains "$unit" "ExitOnForwardFailure=yes" "unit fails fast when a forward breaks"
assert_contains "$unit" "ServerAliveInterval=" "unit keeps the tunnel alive"
assert_contains "$unit" "ServerAliveCountMax=" "unit gives up after repeated loss"
assert_contains "$unit" "TCPKeepAlive=yes" "unit enables TCP keepalive"
assert_contains "$unit" "UserKnownHostsFile=" "unit pins a dedicated known_hosts"
assert_not_contains "$unit" "StrictHostKeyChecking=no" "host key checking is never disabled"
assert_not_contains "$unit" 'StrictHostKeyChecking=accept-new' "host key checking is never weakened"

t_start "each of the four lanes is a separate unit with its own forward"
for n in 1 2 3 4; do
  assert_file "$SD/starspeed-tunnel-f1-lane$n.service" "lane $n unit exists"
done
assert_eq "$(grep -l 'ExecStart' "$SD"/starspeed-tunnel-f1-lane*.service | wc -l)" "4" "all four units carry ExecStart"
assert_contains "$(cat "$SD/starspeed-tunnel-f1-lane4.service")" "-R 127.0.0.1:46104:127.0.0.1:45438" \
  "lane 4 forwards to its own port"

t_start "foreign setup enables the units and pins the Iran host key"
for n in 1 2 3 4; do
  assert_eq "$("$SST_SYSTEMCTL" is-active "starspeed-tunnel-f1-lane$n.service")" "active" \
    "lane $n is running"
  assert_eq "$("$SST_SYSTEMCTL" is-enabled "starspeed-tunnel-f1-lane$n.service")" "enabled" \
    "lane $n starts at boot"
done
assert_file "$SSH_DIR/starspeed-tunnel_iran1" "known_hosts written for the Iran host"
assert_not_contains "$(cat "$AUTH" 2>/dev/null)" "PRIVATE" "no private key material in authorized_keys"

t_start "foreign state records the Iran endpoint it must dial"
assert_contains "$(cat "$STATE/foreign-1.env")" "IRAN_IP=198.51.100.10" "Iran address persisted"
assert_contains "$(cat "$STATE/foreign-1.env")" "LANE4=46104" "all four lanes persisted"
assert_file "$SSH_DIR/starspeed-tunnel_f1" "SSH private key generated"
assert_file "$SSH_DIR/starspeed-tunnel_f1.pub" "SSH public key generated"
assert_contains "$(cat "$SSH_DIR/starspeed-tunnel_iran1")" "ssh-ed25519" "host key pinned from keyscan"

t_start "foreign role is recorded"
assert_eq "$(grep -c '^foreign' "$STATE/role" 2>/dev/null)" "1" "role file marks this host as foreign"

t_start "foreign setup is idempotent and reuses a healthy keypair"
before_unit=$(cat "$UNIT1")
# An already-configured foreign is asked for confirmation before the inbound.
out2=$(run_menu "$(printf '2\n198.51.100.10\n1\ny\n45438\n%s\n' "$CODE1")")
assert_eq "$(cat "$UNIT1")" "$before_unit" "re-running produces an identical unit"
assert_contains "$out2" "reusing existing" "existing keypair is reused, not regenerated"

t_start "declining the overwrite leaves the foreign untouched"
# Declined at the confirmation, so no inbound or setup code is needed.
out=$(run_menu "$(printf '2\n198.51.100.10\n1\nn\n')")
assert_contains "$out" "left unchanged" "installer honours a declined re-run"
assert_eq "$(cat "$UNIT1")" "$before_unit" "declined re-run rewrote nothing"

t_start "foreign setup refuses to continue when the host key cannot be scanned"
rm -f "$SSH_DIR/starspeed-tunnel_iran1"
out=$(FAKE_KEYSCAN_FAIL=1 run_menu "$(printf '2\n198.51.100.10\n1\ny\n45438\n%s\n' "$CODE1")")
assert_contains "$out" "host key" "installer explains the host key failure"
assert_no_file "$SSH_DIR/starspeed-tunnel_iran1" "no empty known_hosts left behind"

t_start "a setup code for a different foreign index is rejected"
# Replay foreign #1's own code while claiming to configure #2.
out=$(run_menu "$(printf '2\n198.51.100.10\n2\n45438\n%s\n' "$CODE1")")
assert_contains "$out" "but you selected #2" "index mismatch is refused"
assert_no_file "$STATE/foreign-2.env" "no state written for the mismatched index"

# ---------------------------------------------------------------------------
# Back to the Iran host for the remaining menu entries. Restore the Iran
# configuration this host had before switching sandboxes.
sandbox_new iran
FRAG1=$HAPROXY_DIR/foreign-1.cfg
FRAG2=$HAPROXY_DIR/foreign-2.cfg
UNIT1=$SD/starspeed-tunnel-f1-lane1.service
AUTH=$SSH_DIR/authorized_keys

# Recreate the operator-owned HAProxy include so uninstall can prove it keeps it.
OPERATOR_INCLUDE="include $HAPROXY_DIR/conf.d/*.cfg"
mkdir -p "$HAPROXY_DIR/conf.d"
printf 'frontend operator_owned\n    bind :9999\n' >"$HAPROXY_DIR/conf.d/operator.cfg"

t_start "Iran is reconfigured with both foreigns"
run_menu "$(iran_answers 2 45438 45438 45439 45439)" >/dev/null

t_start "authorizing a foreign public key is idempotent"
mkdir -p "$SSH_DIR"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONE test-1\n' >"$AUTH"
run_menu "1" >/dev/null
assert_contains "$(cat "$AUTH")" "AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONE" "existing key retained"
run_menu "1" >/dev/null
assert_eq "$(grep -c 'AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONE' "$AUTH")" "1" "key not duplicated on re-authorize"

t_start "malformed public keys are rejected"
before=$(cat "$AUTH")
run_menu "$(printf 'not-a-key\n\nq\n')" >/dev/null
assert_eq "$(cat "$AUTH")" "$before" "no garbage appended to authorized_keys"

t_start "authorized_keys is never writable as a group or world"
probe="$SSH_DIR/probe"; : >"$probe"; chmod 600 "$probe" 2>/dev/null
if [[ $(stat -c '%a' "$probe" 2>/dev/null) == 600 ]]; then
  assert_eq "$(stat -c '%a' "$AUTH")" "600" "authorized_keys is 0600"
else
  echo "  SKIP authorized_keys mode (filesystem does not enforce permissions)"
fi
rm -f "$probe"

t_start "Iran still has both foreigns configured"
assert_file "$FRAG1" "Foreign #1 fragment present"
assert_file "$FRAG2" "Foreign #2 fragment present"
assert_eq "$(grep -c 'include ' "$HC")" "2" "both fragments included"

# ---------------------------------------------------------------------------
t_start "status reports lanes without leaking secrets"
out=$(run_sst --status)
assert_contains "$out" "45438" "status shows foreign #1 frontend port"
assert_contains "$out" "45439" "status shows foreign #2 frontend port"
assert_not_contains "$out" "BEGIN OPENSSH PRIVATE KEY" "status never prints private key material"
assert_not_contains "$out" "PRIVATE KEY-----" "status contains no private key block"

t_start "setup code round trips the exact Iran allocation"
code=$(run_sst --setup-code 1 | tr -d '\r\n')
assert_ne "$code" "" "setup code emitted"
decoded=$(printf '%s' "$code" | base64 -d 2>/dev/null || printf '%s' "$code" | openssl base64 -d -A 2>/dev/null)
assert_contains "$decoded" "FRONTEND=$(front_of 1)" "code carries the exact frontend"
assert_contains "$decoded" "LANE4=$(lane_of 1 4)" "code carries the exact lane 4"
assert_not_contains "$decoded" "PRIVATE" "code carries no key material"

t_start "each foreign gets a distinct setup code"
code2=$(run_sst --setup-code 2 | tr -d '\r\n')
assert_ne "$code" "$code2" "codes differ per foreign"
dec2=$(printf '%s' "$code2" | base64 -d 2>/dev/null)
assert_contains "$dec2" "FOREIGN=2" "code for #2 declares index 2"

# ---------------------------------------------------------------------------
t_start "repair rebuilds a deleted fragment from saved state"
rm -f "$FRAG2"
# Repair asks: rebuild? then (per foreign) restart HAProxy for a frontend that is
# not listening. Accept the rebuild, decline the pointless restarts.
run_menu "$(printf '5\ny\nn\nn\n')" >/dev/null
assert_file "$FRAG2" "repair regenerated the missing fragment"
assert_file "$FRAG1" "repair kept Foreign #1"
assert_contains "$(cat "$FRAG2")" "bind 0.0.0.0:45439" "regenerated fragment kept the right frontend"
assert_contains "$(cat "$HC")" "include $FRAG2" "rebuilt config includes the restored fragment"

t_start "repair is safe to run twice"
f1=$(cat "$FRAG1"); f2=$(cat "$FRAG2")
run_menu "5" >/dev/null
assert_eq "$(cat "$FRAG1")" "$f1" "second repair left Foreign #1 alone"
assert_eq "$(cat "$FRAG2")" "$f2" "second repair left Foreign #2 alone"

# ---------------------------------------------------------------------------
t_start "an invalid HAProxy candidate is never activated"
hc_before=$(cat "$HC")
frag_before=$(cat "$FRAG2")
# FAILVALIDATE makes the fake 'haproxy -c' reject the candidate.
printf '    # FAILVALIDATE\n' >>"$FRAG2"
out=$(run_menu "$(printf '5\ny\n')")
assert_contains "$out" "does not validate" "repair reports the broken live config"
assert_eq "$(cat "$HC")" "$hc_before" "live config untouched when validation fails"

t_start "repair recovers once the fragment is fixed"
grep -v 'FAILVALIDATE' "$FRAG2" >"$FRAG2.tmp" && mv "$FRAG2.tmp" "$FRAG2"
run_menu "$(printf '5\nn\nn\nn\n')" >/dev/null
assert_eq "$(cat "$FRAG2")" "$frag_before" "fragment restored after the fix"
assert_contains "$(cat "$HC")" "include $FRAG2" "live config includes both foreigns again"

t_start "a backup exists whenever the config was rewritten"
assert_ne "$(ls -1 "$BACKUP" 2>/dev/null | wc -l)" "0" "at least one backup was written"

# The operator's own include is appended only now, so earlier assertions that
# count include lines see exactly the two managed fragments.
printf '%s\n' "$OPERATOR_INCLUDE" >>"$HC"
assert_contains "$(cat "$HC")" "$OPERATOR_INCLUDE" "operator include coexists with the managed block"

# ---------------------------------------------------------------------------
# Removal runs on the Iran host; the Foreign lane units live on the foreign
# server, so only Iran-side state is checked here.
t_start "removing Foreign #2 keeps Foreign #1 fully intact"
one_before=$(cat "$FRAG1")
run_menu "$(printf '6\n2\ny\n')" >/dev/null
assert_no_file "$FRAG2" "Foreign #2 fragment removed"
assert_no_file "$STATE/foreign-2.env" "Foreign #2 state removed"
assert_eq "$(cat "$FRAG1")" "$one_before" "Foreign #1 fragment untouched"
assert_contains "$(cat "$HC")" "include $FRAG1" "Foreign #1 still included"
assert_not_contains "$(cat "$HC")" "include $FRAG2" "Foreign #2 include removed"

t_start "removal requires confirmation"
run_menu "$(printf '6\n1\nn\n')" >/dev/null
assert_file "$FRAG1" "declined removal changed nothing"
assert_file "$STATE/foreign-1.env" "declined removal kept the state file"

t_start "removing Foreign #1 after #2 is gone leaves a valid config"
run_menu "$(printf '6\n1\ny\n')" >/dev/null
assert_no_file "$FRAG1" "Foreign #1 fragment removed"
assert_no_file "$STATE/foreign-1.env" "Foreign #1 state removed"
assert_contains "$(cat "$HC")" "managed includes" "managed block still well-formed with no foreigns"

t_start "a removed foreign can be added again cleanly"
run_menu "$(iran_answers 2 45438 45438 45439 45439)" >/dev/null  # fresh host: both prompted
assert_file "$FRAG1" "Foreign #1 recreated"
assert_file "$FRAG2" "Foreign #2 recreated"
assert_eq "$(front_of 1)" "45438" "Foreign #1 kept its original frontend"
assert_ne "$(front_of 1)" "$(front_of 2)" "frontends are still distinct"

# ---------------------------------------------------------------------------
t_start "uninstall is declined safely"
cfg_before=$(cat "$HC")
run_menu "$(printf '7\nn\n')" >/dev/null
assert_contains "$(run_menu "$(printf '7\nn\n')")" "nothing changed" "declining is honoured"
assert_eq "$(cat "$HC")" "$cfg_before" "declined uninstall changed nothing"
assert_file "$FRAG1" "declined uninstall kept the fragment"

t_start "uninstall removes only starspeed-managed files"
# Menu 7, confirm, then decline removing backups.
run_menu "$(printf '7\ny\nn\n')" >/dev/null
assert_no_file "$FRAG1" "#1 fragment removed"
assert_no_file "$FRAG2" "#2 fragment removed"
assert_no_file "$UNIT1" "lane unit removed"
assert_file "$HAPROXY_DIR/conf.d/operator.cfg" "operator include preserved"
if [[ -f $HC ]]; then
  assert_not_contains "$(cat "$HC")" "starspeed-tunnel managed includes" "managed block stripped"
  assert_contains "$(cat "$HC")" "$OPERATOR_INCLUDE" "operator config still intact"
fi

t_start "uninstall never touches Xray or 3x-ui state"
assert_no_file "$SD/xray.service" "no xray unit created"
assert_no_file "$SD/x-ui.service" "no 3x-ui unit created"
assert_no_file "$SANDBOX/etc/xray" "no xray state created"
assert_no_file "$SANDBOX/etc/3x-ui" "no 3x-ui state created"

printf 'TESTSUMMARY:pass=%d fail=%d\n' "$PASS" "$FAIL"
summary >/dev/null
sandbox_destroy
exit "$FAIL"