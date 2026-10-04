#!/usr/bin/env bash
# Validation logic: ports, hosts, indexes, public keys, setup codes, allocation.
#
# Hostile inputs are passed to the predicates through the TEST_VALUE environment
# variable so that nothing in this file needs to escape them.
#
# shellcheck disable=SC1091  # lib.sh is located at runtime via BASH_SOURCE
# shellcheck disable=SC2016  # single quotes are deliberate: these are literal
#                           # hostile payloads, e.g. valid_host '$(id)'.
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

sandbox_new validation

b64enc() { openssl base64 -A 2>/dev/null || base64 -w0; }

# assert_pred <label> <predicate> <value> <expected y|n>
assert_pred() {
  local label=$1 pred=$2 value=$3 want=$4 got
  got=$(TEST_VALUE=$value bash -c 'set -uo pipefail
    source "$1" --help >/dev/null
    if "$2" "$TEST_VALUE"; then printf y; else printf n; fi' _ "$SCRIPT" "$pred" 2>&1)
  assert_eq "$got" "$want" "$label"
}

# Run a snippet with the script sourced. Snippet must not contain quotes.
eval_in_script() {
  bash -c "set -uo pipefail; source \"\$1\" --help >/dev/null; $2" _ "$SCRIPT" 2>&1
}

# Emit the setup code for foreign #N from the installer itself.
make_code() {
  run_sst --setup-code "$1" 2>/dev/null | tr -d '\r\n'
}

# ---------------------------------------------------------------------------
t_start "script loads and exposes its predicates"
if bash -c 'set -uo pipefail; source "$1" --help >/dev/null && declare -F valid_port valid_host valid_index valid_pubkey >/dev/null' _ "$SCRIPT" 2>&1; then
  t_ok "all validation predicates are defined when sourced"
else
  t_fail "all validation predicates are defined when sourced"
fi

# ---------------------------------------------------------------------------
t_start "valid_port"
assert_pred "22 is a valid port"                     valid_port "22"        y
assert_pred "65535 is a valid port"                  valid_port "65535"     y
assert_pred "1 is a valid port"                      valid_port "1"         y
assert_pred "80 is a valid port"                     valid_port "80"        y
assert_pred "leading zero is read as decimal"        valid_port "08"        y
assert_pred "0 is rejected"                          valid_port "0"         n
assert_pred "65536 is rejected"                      valid_port "65536"     n
assert_pred "non-numeric is rejected"                valid_port "abc"       n
assert_pred "empty is rejected"                      valid_port ""          n
assert_pred "leading space is rejected"              valid_port " 80"       n
assert_pred "trailing text is rejected"              valid_port "80x"       n
assert_pred "shell metacharacters are rejected"      valid_port '$(id)'     n
assert_pred "injected command is rejected"           valid_port '80; id'    n
assert_pred "newline injection is rejected"          valid_port $'80\nid'   n

# ---------------------------------------------------------------------------
t_start "valid_host - IPv4"
assert_pred "dotted quad accepted"                   valid_host "1.2.3.4"          y
assert_pred "broadcast address accepted"             valid_host "255.255.255.255"  y
assert_pred "zero address accepted"                  valid_host "0.0.0.0"          y
assert_pred "octet 256 rejected"                     valid_host "256.1.1.1"        n
assert_pred "three-part address rejected"            valid_host "1.2.3"            n
assert_pred "five-part address rejected"             valid_host "1.2.3.4.5"        n
assert_pred "out-of-range dotted numeric rejected"   valid_host "999.1.1.1"        n

t_start "valid_host - hostname and IPv6"
assert_pred "simple hostname accepted"              valid_host "example.com"           y
assert_pred "hyphenated hostname accepted"          valid_host "a-b.example.co.uk"     y
assert_pred "single label hostname accepted"         valid_host "localhost"             y
assert_pred "IPv6 accepted"                         valid_host "2001:db8::1"           y

t_start "valid_host - injection"
assert_pred "leading-dash ssh option rejected"       valid_host "-oProxyCommand=touch /tmp/x"  n
assert_pred "command injection rejected"             valid_host '1.2.3.4; rm -rf /'    n
assert_pred "command substitution rejected"          valid_host '$(id)'                 n
assert_pred "backtick substitution rejected"         valid_host '`id`'                  n
assert_pred "newline injection rejected"             valid_host $'1.2.3.4\nbind 0.0.0.0:80' n
assert_pred "whitespace rejected"                    valid_host 'host name'             n
assert_pred "host:port rejected"                     valid_host '1.2.3.4:8080'         n
assert_pred "glob rejected"                          valid_host '*'                     n
assert_pred "brace injection rejected"               valid_host '${IFS}'                n

# ---------------------------------------------------------------------------
t_start "valid_index"
assert_pred "1 accepted"                             valid_index "1"           y
assert_pred "2 accepted"                             valid_index "2"           y
assert_pred "0 rejected"                             valid_index "0"           n
assert_pred "3 rejected"                             valid_index "3"           n
assert_pred "empty rejected"                         valid_index ""            n
assert_pred "injection rejected"                     valid_index '1; id'       n

# ---------------------------------------------------------------------------
t_start "valid_pubkey"
assert_pred "ed25519 with comment accepted"    valid_pubkey 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB1pQ0X3+Test user@host' y
assert_pred "rsa accepted"                     valid_pubkey 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQ'                y
assert_pred "ecdsa accepted"                   valid_pubkey 'ecdsa-sha2-nistp256 AAAAE2VjZHNh'                          y
assert_pred "no comment accepted"              valid_pubkey 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB1pQ0X3+Test'       y
assert_pred "garbage rejected"                 valid_pubkey 'not-a-key'                                                n
assert_pred "type without material rejected"   valid_pubkey 'ssh-ed25519'                                              n
assert_pred "unknown key type rejected"        valid_pubkey 'ssh-dss AAAAB3NzaC1kc3M'                                 n
assert_pred "shell chars in comment rejected"  valid_pubkey 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 $(id)'                 n
assert_pred "multi-line key injection rejected" valid_pubkey $'ssh-ed25519 AAAA\nssh-rsa BBBB'                        n
assert_pred "leading dash rejected"            valid_pubkey '-ssh-ed25519 AAAA'                                     n

# ---------------------------------------------------------------------------
t_start "setup code round trip (Iran emits, foreign parses)"
mkdir -p "$STATE"
cat >"$STATE/foreign-1.env" <<EOF
FOREIGN=1
FRONTEND=45438
INBOUND=45438
LANE1=46101
LANE2=46102
LANE3=46103
LANE4=46104
EOF
chmod 600 "$STATE/foreign-1.env"

code=$(make_code 1)
assert_ne "$code" "" "setup code emitted for foreign #1"
if [[ $code =~ ^[A-Za-z0-9+/=]+$ ]]; then
  t_ok "setup code is base64, so it survives copy/paste"
else
  t_fail "setup code is base64, so it survives copy/paste" "got: [$code]"
fi
assert_not_contains "$code" "PRIVATE" "setup code carries no key material"

parsed=$(CODE=$code bash -c 'set -uo pipefail
  source "$1" --help >/dev/null
  if parse_setup_code "$CODE" >/dev/null 2>&1; then
    printf "idx=%s fe=%s in=%s lanes=%s sshport=%s" "$SC_IDX" "$SC_FRONTEND" "$SC_INBOUND" "${SC_LANES[*]}" "$SC_SSH_PORT"
  else
    printf REJECTED
  fi' _ "$SCRIPT" 2>&1)
assert_eq "$parsed" "idx=1 fe=45438 in=45438 lanes=46101 46102 46103 46104 sshport=22" \
  "setup code parses back to identical values"

# ---------------------------------------------------------------------------
t_start "setup code rejects tampering"
reject_code() {
  local label=$1 payload=$2
  local r
  r=$(CODE=$payload bash -c 'set -uo pipefail
    source "$1" --help >/dev/null
    if parse_setup_code "$CODE" >/dev/null 2>&1; then printf ACCEPTED; else printf rejected; fi' _ "$SCRIPT" 2>&1)
  assert_eq "$r" "rejected" "$label"
}

hdr='STARPEED-TUNNEL-SETUP v1'
reject_code "out-of-range frontend port rejected"  "$(printf '%s\nFOREIGN=1\nFRONTEND=99999\nINBOUND=1\nLANE1=1\nLANE2=2\nLANE3=3\nLANE4=4\n' "$hdr" | b64enc)"
reject_code "foreign index 5 rejected"            "$(printf '%s\nFOREIGN=5\nFRONTEND=100\nINBOUND=1\nLANE1=1\nLANE2=2\nLANE3=3\nLANE4=4\n' "$hdr" | b64enc)"
reject_code "missing LANE4 rejected"              "$(printf '%s\nFOREIGN=1\nFRONTEND=100\nINBOUND=1\nLANE1=1\nLANE2=2\nLANE3=3\n' "$hdr" | b64enc)"
reject_code "lane colliding with frontend rejected" "$(printf '%s\nFOREIGN=1\nFRONTEND=100\nINBOUND=1\nLANE1=100\nLANE2=2\nLANE3=3\nLANE4=4\n' "$hdr" | b64enc)"
reject_code "duplicate lane ports rejected"       "$(printf '%s\nFOREIGN=1\nFRONTEND=100\nINBOUND=1\nLANE1=5\nLANE2=5\nLANE3=3\nLANE4=4\n' "$hdr" | b64enc)"
reject_code "unknown key rejected"                "$(printf '%s\nFOREIGN=1\nFRONTEND=100\nINBOUND=1\nLANE1=1\nLANE2=2\nLANE3=3\nLANE4=4\nEVIL=1\n' "$hdr" | b64enc)"
reject_code "wrong version header rejected"       "$(printf 'STARPEED-TUNNEL-SETUP v9\nFOREIGN=1\nFRONTEND=100\nINBOUND=1\nLANE1=1\nLANE2=2\nLANE3=3\nLANE4=4\n' | b64enc)"
reject_code "non-base64 input rejected"           'not base64 at all !!!'
reject_code "empty input rejected"                ''
reject_code "lane with shell metacharacters rejected" "$(printf '%s\nFOREIGN=1\nFRONTEND=100\nINBOUND=1\nLANE1=$(id)\nLANE2=2\nLANE3=3\nLANE4=4\n' "$hdr" | b64enc)"

# ---------------------------------------------------------------------------
t_start "port allocation"
listen_on ''
rm -f "$STATE/foreign-1.env"
alloc=$(eval_in_script '' 'allocate_lanes 1 46000')
assert_eq "$alloc" "46101 46102 46103 46104" "foreign #1 takes the first free block"

listen_on "46101,46102,46103,46104"
alloc=$(eval_in_script '' 'allocate_lanes 1 46000')
assert_eq "$alloc" "46111 46112 46113 46114" "allocation moves past a fully occupied block"

listen_on "46102"
alloc=$(eval_in_script '' 'allocate_lanes 1 46000')
assert_eq "$alloc" "46111 46112 46113 46114" "partially occupied block is skipped, never partially reused"

listen_on ''
alloc2=$(eval_in_script '' 'allocate_lanes 2 46000')
assert_eq "$alloc2" "46201 46202 46203 46204" "foreign #2 is allocated a disjoint block"

t_start "allocation respects ports already recorded in state"
cat >"$STATE/foreign-1.env" <<EOF
FOREIGN=1
FRONTEND=45438
INBOUND=45438
LANE1=46101
LANE2=46102
LANE3=46103
LANE4=46104
EOF
alloc=$(eval_in_script '' 'allocate_lanes 1 46000')
assert_eq "$alloc" "46111 46112 46113 46114" "already-allocated lanes are treated as reserved"
rm -f "$STATE/foreign-1.env"

t_start "lane ports are never hard-coded"
listen_on "46101,46102,46103,46104,46201,46202,46203,46204"
a1=$(eval_in_script '' 'allocate_lanes 1 46000')
a2=$(eval_in_script '' 'allocate_lanes 2 46000')
assert_ne "$a1" "46101 46102 46103 46104" "foreign #1 adapts when the default block is busy"
assert_ne "$a2" "46201 46202 46203 46204" "foreign #2 adapts when the default block is busy"
assert_ne "$a1" "$a2" "the two foreigns never share a block"
listen_on ''

# ---------------------------------------------------------------------------
t_start "state round trip"
bash -c 'set -uo pipefail
  source "$1" --help >/dev/null
  write_state 2 45300 45400 47101 47102 47103 47104' _ "$SCRIPT"
assert_file "$STATE/foreign-2.env" "state file written"

# Some filesystems (Windows/NTFS via Git Bash) ignore chmod entirely, so only
# assert the mode where the sandbox actually honours permission bits.
probe="$SST_BASE/probe"
: >"$probe"; chmod 600 "$probe" 2>/dev/null
if [[ $(stat -c '%a' "$probe" 2>/dev/null) == 600 ]]; then
  assert_eq "$(stat -c '%a' "$STATE/foreign-2.env")" "600" "state file is 0600"
else
  echo "  SKIP state file mode (filesystem does not enforce permissions)"
fi
rm -f "$probe"
assert_eq "$(front_of 2)" "45300" "FRONTEND round trips"
assert_eq "$(inb_of 2)"   "45400" "INBOUND round trips"
assert_eq "$(lane_of 2 1)" "47101" "LANE1 round trips"
assert_eq "$(lane_of 2 4)" "47104" "LANE4 round trips"
assert_eq "$(eval_in_script '' 'if state_valid 2; then echo valid; else echo invalid; fi')" "valid" \
  "well-formed state validates"

t_start "invalid state is rejected"
sed -i 's/^LANE2=.*/LANE2=notaport/' "$STATE/foreign-2.env"
assert_eq "$(eval_in_script '' 'if state_valid 2; then echo valid; else echo invalid; fi')" "invalid" \
  "corrupt lane port invalidates state"
sed -i 's/^LANE2=.*/LANE2=47102/' "$STATE/foreign-2.env"

assert_eq "$(eval_in_script '' 'if state_valid 9; then echo valid; else echo invalid; fi')" "invalid" \
  "state for a non-existent foreign is invalid"

printf 'FOREIGN=3\nFRONTEND=45300\n' >"$STATE/foreign-3.env"
assert_eq "$(eval_in_script '' 'if state_valid 3; then echo valid; else echo invalid; fi')" "invalid" \
  "truncated state file is invalid"
rm -f "$STATE/foreign-3.env"

t_start "state files are data, never executable"
marker=/tmp/sst-pwned
rm -f "$marker"
printf 'FOREIGN=1\nFRONTEND=$(touch %s)\nINBOUND=1\nLANE1=1\nLANE2=2\nLANE3=3\nLANE4=4\n' "$marker" >"$STATE/foreign-1.env"
assert_eq "$(eval_in_script '' 'if state_valid 1; then echo valid; else echo invalid; fi')" "invalid" \
  "state containing command substitution is invalid"
assert_eq "$(eval_in_script '' 'if rebuild_haproxy >/dev/null 2>&1; then echo ok; else echo failed; fi')" "ok" \
  "rebuild tolerates the bad entry"
if [[ ! -e $marker ]]; then
  t_ok "state values are never evaluated (no side effect)"
else
  t_fail "state values are never evaluated (no side effect)" "marker file was created"
  rm -f "$marker"
fi
rm -f "$STATE/foreign-1.env"

printf 'TESTSUMMARY:pass=%d fail=%d\n' "$PASS" "$FAIL"
summary >/dev/null
sandbox_destroy
exit "$FAIL"