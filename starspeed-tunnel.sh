#!/usr/bin/env bash
# SC2015: several messages intentionally use `cond && ok A || info B` where A
# and B are two mutually exclusive, always-successful status lines. This is not
# an if/else; the trailing branch must not fire when the first succeeds.
# shellcheck disable=SC2015
#
# starspeed-tunnel.sh - interactive installer for a multi-lane reverse-SSH tunnel
#
#   Client -> Iran public frontend port -> HAProxy -> 4 local reverse-SSH lanes
#          -> Foreign server -> existing Xray inbound
#
# This script only ever *reads* Xray / 3x-ui state. It never creates, edits or
# deletes an Xray inbound, and it never touches an existing "Direct" config.
#
# Target: Ubuntu 22.04 / 24.04, systemd, OpenSSH, HAProxy.
#
set -Eeuo pipefail

APP=starspeed-tunnel
VERSION=1.0.0

# ---------------------------------------------------------------------------
# Paths and tools. Every path and external tool can be overridden through the
# environment so the installer can be exercised in tests without root, without
# systemd and without a real HAProxy.
# ---------------------------------------------------------------------------
SST_BASE=${SST_BASE:-/etc/$APP}
SST_STATE=${SST_STATE:-$SST_BASE/state}
SST_BACKUP=${SST_BACKUP:-$SST_BASE/backups}
SST_HAPROXY_DIR=${SST_HAPROXY_DIR:-$SST_BASE/haproxy}
SST_SD=${SST_SD:-/etc/systemd/system}
SST_HC=${SST_HC:-/etc/haproxy/haproxy.cfg}
SST_SSH_DIR=${SST_SSH_DIR:-/root/.ssh}

SYSTEMCTL=${SST_SYSTEMCTL:-systemctl}
HAPROXY=${SST_HAPROXY:-haproxy}
SS=${SST_SS:-ss}
SSH=${SST_SSH:-ssh}
SSH_KEYGEN=${SST_SSH_KEYGEN:-ssh-keygen}
SSH_KEYSCAN=${SST_SSH_KEYSCAN:-ssh-keyscan}

# Lane / frontend allocation defaults. Ports are *scanned* from here, never
# hard-coded per foreign.
LANE_SCAN_BASE=${SST_LANE_SCAN_BASE:-46000}
LANE_SCAN_STEP=${SST_LANE_SCAN_STEP:-100}
IRAN_SSH_PORT=${SST_IRAN_SSH_PORT:-22}

SETUP_CODE_VERSION=1
HAPROXY_BEGIN='# >>> starspeed-tunnel managed includes >>>'
HAPROXY_END='# <<< starspeed-tunnel managed includes <<<'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

info()  { printf '%s\n' "$*"; }
step()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s  OK%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%swarn%s  %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%serr %s  %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }

hr() { printf '%s\n' "------------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOGFILE=''
LOG_FD_OPEN=0

init_logging() {
  mkdir -p "$SST_BASE" "$SST_STATE" "$SST_BACKUP" "$SST_HAPROXY_DIR"
  chmod 700 "$SST_BASE" "$SST_STATE" 2>/dev/null || true
  chmod 755 "$SST_BACKUP" "$SST_HAPROXY_DIR" 2>/dev/null || true
  LOGFILE=$SST_BASE/install.log
  : >"$LOGFILE"
  chmod 600 "$LOGFILE" 2>/dev/null || true
  # Open the log fd only if it can actually be opened. Note that `exec` makes
  # its redirections permanent, so the write must be tested in a subshell first:
  # attaching 2>/dev/null here would silently discard every later error message.
  if { : >>"$LOGFILE"; } 2>/dev/null; then
    exec 3>>"$LOGFILE"
    LOG_FD_OPEN=1
  fi
}

log() {
  (( LOG_FD_OPEN )) || return 0
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$$" "$*" >&3 2>/dev/null || true
}

on_error() {
  local rc=$? line=${1:-?}
  err "aborted at line $line (exit $rc). Nothing further was changed."
  log "FATAL line=$line rc=$rc"
  exit "$rc"
}

# ---------------------------------------------------------------------------
# Privilege
# ---------------------------------------------------------------------------
require_root() {
  if [[ ${SST_ALLOW_NONROOT:-0} != 1 && ${EUID:-$(id -u)} -ne 0 ]]; then
    die "must run as root (use sudo)"
  fi
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
valid_index() { [[ $1 == 1 || $1 == 2 ]]; }

valid_port() {
  local p=$1
  [[ $p =~ ^[0-9]+$ ]] || return 1
  # 10# forces base 10 so a leading zero (e.g. "080") is not read as octal.
  (( 10#$p >= 1 && 10#$p <= 65535 )) || return 1
  return 0
}

# Accepts IPv4, a conservative IPv6 form, or a DNS hostname. Rejects anything
# that could be read as an option or smuggle shell/HAProxy metacharacters.
valid_host() {
  local h=$1
  [[ -n $h && ${#h} -le 253 ]] || return 1
  [[ $h == -* ]] && return 1
  [[ $h =~ [[:space:]] ]] && return 1

  if [[ $h =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    local o
    for o in "${BASH_REMATCH[@]:1:4}"; do
      (( 10#$o >= 0 && 10#$o <= 255 )) || return 1
    done
    return 0
  fi

  # A dotted-numeric shape that is not a valid IPv4 address (e.g. "1.2.3",
  # "1.2.3.4.5", "999.1.1.1") is never a legitimate hostname either.
  if [[ $h =~ ^[0-9.]+$ && $h == *.* ]]; then
    return 1
  fi

  if [[ $h == *:* && $h =~ ^[0-9A-Fa-f:]+$ ]]; then
    return 0
  fi

  if [[ $h =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]; then
    return 0
  fi

  return 1
}

# A pasted public key line: must be one of ssh-ed25519 / ssh-rsa / ecdsa,
# with a comment field that cannot contain newlines.
valid_pubkey() {
  local k=$1
  [[ $k != *$'\n'* && $k != *$'\r'* ]] || return 1
  # type, base64 blob, then an optional comment restricted to a safe charset so
  # nothing exotic can ever reach authorized_keys or the installer output.
  [[ $k =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)[[:space:]]+[A-Za-z0-9+/=]+$ ]] && return 0
  [[ $k =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)[[:space:]]+[A-Za-z0-9+/=]+[[:space:]]+[A-Za-z0-9._@:+-]*$ ]] && return 0
  return 1
}

# Where prompts are read from. /dev/tty keeps answers out of any piped stdin,
# which is the right behaviour interactively. The test suite points this at a
# file of canned answers instead.
PROMPT_SRC=${SST_PROMPT_SRC:-/dev/tty}
PROMPT_FD=0

# A regular file is opened once on a dedicated fd so repeated reads advance
# through the answer sequence. Anything else (a tty) is reopened per read.
prompt_init() {
  if [[ -n $PROMPT_SRC && $PROMPT_SRC != /dev/* && -f $PROMPT_SRC ]]; then
    exec 4<"$PROMPT_SRC" || return 1
    PROMPT_FD=4
  fi
}

# Set to 1 by prompt_read when the input stream is exhausted. The validating
# prompts use it to fail loudly instead of re-prompting forever, which would
# otherwise hang a non-interactive run.
PROMPT_EOF=0

# prompt_read <varname> <prompt> [default]
prompt_read() {
  local __target=$1 prompt=$2 default=${3:-} __input='' __rc=0
  PROMPT_EOF=0

  if (( PROMPT_FD )); then
    read -r -p "$prompt [$default]: " __input <&$PROMPT_FD || __rc=$?
  else
    read -r -p "$prompt: " __input <"$PROMPT_SRC" || __rc=$?
  fi

  # A non-zero status with no data means the answer stream is exhausted.
  (( __rc != 0 )) && [[ -z $__input ]] && PROMPT_EOF=1

  if [[ -n $default ]]; then
    __input=${__input:-$default}
  fi

  # __input must not be named the same as the target, or printf -v would
  # assign this function's own local and the caller would see nothing.
  printf -v "$__target" '%s' "$__input"
}

# Guard used by every validating prompt: refuse to loop once input is gone.
# Returns 0 while input remains so it is safe to call under `set -e`.
prompt_exhausted() {
  (( PROMPT_EOF )) || return 0
  err "no input available for '$1'; cannot ask the remaining questions"
  exit 1
}

ask() { prompt_read "$1" "$2" "${3:-}"; }

# Each of these loops until the answer satisfies its validator. The scratch
# variable is deliberately named "input" so it never collides with the
# caller's variable name, which printf -v has to be able to target.
# When the answer stream is exhausted they abort rather than re-prompt forever.
ask_index() {
  local __target=$1 prompt=$2 default=${3:-} input
  while :; do
    prompt_read input "$prompt" "$default"
    prompt_exhausted "$prompt"
    if valid_index "$input"; then printf -v "$__target" '%s' "$input"; return 0; fi
    warn "enter 1 or 2"
  done
}

ask_port() {
  local __target=$1 prompt=$2 default=${3:-} input
  while :; do
    prompt_read input "$prompt" "$default"
    prompt_exhausted "$prompt"
    if valid_port "$input"; then printf -v "$__target" '%s' "$input"; return 0; fi
    warn "enter a port number between 1 and 65535"
  done
}

ask_host() {
  local __target=$1 prompt=$2 default=${3:-} input
  while :; do
    prompt_read input "$prompt" "$default"
    prompt_exhausted "$prompt"
    if valid_host "$input"; then printf -v "$__target" '%s' "$input"; return 0; fi
    warn "enter a valid IPv4 address, IPv6 address or hostname"
  done
}

confirm() {
  local prompt=$1 answer=''
  prompt_read answer "$prompt [y/N]"
  prompt_exhausted "$prompt [y/N]"
  [[ ${answer,,} == y ]]
}

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------
# Nanosecond + pid suffix so repeated runs in the same second cannot collide.
backup_file() {
  local src=$1
  [[ -e $src ]] || return 0
  local dst
  dst="$SST_BACKUP/$(basename "$src").$(date -u '+%Y%m%dT%H%M%S').$$.$RANDOM"
  cp -a -- "$src" "$dst"
  log "backup $src -> $dst"
  printf '%s\n' "$dst"
}

list_backups() {
  local dir=$1
  [[ -d $dir ]] || return 0
  ls -1t -- "$dir" 2>/dev/null || true
}

latest_backup() {
  list_backups "$1" | head -n1
}

# ---------------------------------------------------------------------------
# Ports
# ---------------------------------------------------------------------------
port_in_use() {
  local p=$1
  "$SS" -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}\$"
}

# Every port we have already handed out, across all configured foreigns.
state_allocated_ports() {
  local f
  for f in "$SST_STATE"/foreign-*.env; do
    [[ -f $f ]] || continue
    awk -F= '/^(FRONTEND|INBOUND|LANE[1-4])=/{print $2}' "$f"
  done
}

# Ports that appear in the live haproxy config, so we never collide with a
# config this script does not own.
haproxy_listen_ports() {
  [[ -f $SST_HC ]] || return 0
  awk '/^[[:space:]]*bind[[:space:]]/{
         for (i = 2; i <= NF; i++) {
           n = $i
           sub(/^.*:/, "", n)
           sub(/^.*\[/, "", n)
           if (n ~ /^[0-9]+$/) print n
         }
       }' "$SST_HC" 2>/dev/null || true
}

port_reserved() {
  local p=$1
  port_in_use "$p" && return 0
  state_allocated_ports | grep -qx "$p" && return 0
  haproxy_listen_ports | grep -qx "$p" && return 0
  return 1
}

# Find 4 consecutive free lane ports and print them.
#
# $1 = foreign index, $2 = scan base. Foreign $idx owns the block starting at
# base + idx*LANE_SCAN_STEP, and lanes are base+1 .. base+4 so that the block
# boundary itself stays free as a separator. If any of the four is taken the
# whole block is skipped, never partially reused.
allocate_lanes() {
  local idx=$1 start=$2 base cand tries=0
  base=$(( start + idx * LANE_SCAN_STEP ))
  cand=$base
  while (( tries < 500 )); do
    if ! port_reserved $((cand+1)) \
       && ! port_reserved $((cand+2)) \
       && ! port_reserved $((cand+3)) \
       && ! port_reserved $((cand+4)); then
      printf '%s %s %s %s\n' "$((cand+1))" "$((cand+2))" "$((cand+3))" "$((cand+4))"
      return 0
    fi
    cand=$((cand + 10))
    tries=$((tries + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
state_file() { printf '%s/foreign-%s.env' "$SST_STATE" "$1"; }

role_file()  { printf '%s/role' "$SST_STATE"; }

set_role() {
  printf '%s\n' "$1" >"$(role_file)"
  chmod 600 "$(role_file)"
}

get_role() {
  [[ -f $(role_file) ]] && cat "$(role_file)" || printf 'unknown'
}

# Only these keys are ever written, and every value is a validated integer or a
# validated host. Nothing user-supplied is passed through eval/`source`.
write_state() {
  local idx=$1 frontend=$2 inbound=$3
  shift 3
  local lanes=("$@") f
  f=$(state_file "$idx")
  {
    printf 'FOREIGN=%s\n' "$idx"
    printf 'FRONTEND=%s\n' "$frontend"
    printf 'INBOUND=%s\n' "$inbound"
    local j
    for j in 1 2 3 4; do
      printf 'LANE%s=%s\n' "$j" "${lanes[j-1]}"
    done
  } >"$f"
  chmod 600 "$f"
  log "state written: $f frontend=$frontend inbound=$inbound lanes=${lanes[*]}"
}

state_get() {
  local idx=$1 key=$2 f
  f=$(state_file "$idx")
  [[ -f $f ]] || return 1
  awk -F= -v k="$key" '$1==k {print $2; found=1; exit} END{exit !found}' "$f"
}

state_exists() { [[ -f $(state_file "$1") ]]; }

state_frontend() { state_get "$1" FRONTEND; }
state_inbound()  { state_get "$1" INBOUND; }

state_lanes() {
  local idx=$1 j out=()
  for j in 1 2 3 4; do
    out+=( "$(state_get "$idx" "LANE$j")" )
  done
  printf '%s\n' "${out[@]}"
}

configured_foreigns() {
  local f
  for f in "$SST_STATE"/foreign-*.env; do
    [[ -f $f ]] || continue
    basename "$f" .env | sed 's/^foreign-//'
  done
}

foreign_count() { configured_foreigns | grep -c . || true; }

# A state file is only trusted if it parses cleanly.
state_valid() {
  local idx=$1
  state_exists "$idx" || return 1
  valid_index "$idx" || return 1
  valid_port "$(state_frontend "$idx")" || return 1
  valid_port "$(state_inbound "$idx")" || return 1
  local j p
  for j in 1 2 3 4; do
    p=$(state_get "$idx" "LANE$j") || return 1
    valid_port "$p" || return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Setup code (Iran -> Foreign transfer)
# ---------------------------------------------------------------------------
b64enc() { openssl base64 -A 2>/dev/null || base64 -w0; }
b64dec() { openssl base64 -d -A 2>/dev/null || base64 -d; }

# A single base64 blob so the block survives copy/paste through any chat client
# without newline or quoting damage. It carries no secrets.
emit_setup_code() {
  local idx=$1 ip=${2:-} f payload
  f=$(state_file "$idx")
  [[ -f $f ]] || return 1
  payload=$(awk -F= '/^(FOREIGN|FRONTEND|INBOUND|LANE[1-4])=/{printf "%s%s=%s", (n++?"\n":""), $1, $2}' "$f")
  {
    printf 'STARPEED-TUNNEL-SETUP v%s\n' "$SETUP_CODE_VERSION"
    printf '%s\n' "$payload"
    if [[ -n $ip ]]; then printf 'IRAN_IP=%s\n' "$ip"; fi
    printf 'IRAN_SSH_PORT=%s\n' "$IRAN_SSH_PORT"
  } | b64enc
}

# Parses and fully validates a pasted setup code. Returns the fields via
# globals. Rejects anything unexpected rather than partially trusting it.
# SC_INBOUND is part of the public parse result and is asserted by the tests.
# shellcheck disable=SC2034
parse_setup_code() {
  local raw=$1 text
  SC_IDX=''; SC_FRONTEND=''; SC_INBOUND=''; SC_LANES=(); SC_IRAN_IP=''; SC_SSH_PORT="$IRAN_SSH_PORT"

  text=$(printf '%s' "$raw" | tr -d '\r' | b64dec 2>/dev/null) || return 1
  [[ -n $text ]] || return 1

  local first
  first=$(printf '%s\n' "$text" | head -n1)
  [[ $first == "STARPEED-TUNNEL-SETUP v$SETUP_CODE_VERSION" ]] || {
    warn "unrecognised setup code header"; return 1; }

  local line key val seen_f=0 seen_fe=0 seen_in=0 seen_l=0
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    [[ $line == *=* ]] || continue
    key=${line%%=*}
    val=${line#*=}
    case $key in
      FOREIGN)    valid_index "$val" || return 1; SC_IDX=$val; seen_f=1 ;;
      FRONTEND)   valid_port "$val"   || return 1; SC_FRONTEND=$val; seen_fe=1 ;;
      INBOUND)    valid_port "$val"   || return 1; SC_INBOUND=$val; seen_in=1 ;;
      LANE1|LANE2|LANE3|LANE4)
                   valid_port "$val" || return 1
                   SC_LANES[${key#LANE}-1]=$val; seen_l=$((seen_l+1)) ;;
      IRAN_IP)    valid_host "$val"   || return 1; SC_IRAN_IP=$val ;;
      IRAN_SSH_PORT) valid_port "$val" || return 1; SC_SSH_PORT=$val ;;
      *) warn "unexpected key in setup code: $key"; return 1 ;;
    esac
  done <<<"$text"

  (( seen_f && seen_fe && seen_in && seen_l == 4 )) || {
    warn "setup code is missing required fields"; return 1; }

  # No lane may collide with the frontend or with another lane.
  local a
  for a in "${SC_LANES[@]}"; do
    [[ $a != "$SC_FRONTEND" ]] || { warn "setup code lane collides with frontend"; return 1; }
  done
  printf '%s\n' "${SC_LANES[@]}" | sort -u | grep -q . || return 1
  local uniq
  uniq=$(printf '%s\n' "${SC_LANES[@]}" | sort -u | wc -l | tr -d ' ')
  [[ $uniq == 4 ]] || { warn "setup code lanes are not unique"; return 1; }

  # ssh port is used as `-p N`; never let it become an option string.
  valid_port "$SC_SSH_PORT" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
ensure_pkgs() {
  local missing=()
  command -v "$HAPROXY" >/dev/null 2>&1 || missing+=(haproxy)
  command -v "$SYSTEMCTL" >/dev/null 2>&1 || missing+=(systemd)
  command -v "$SS"      >/dev/null 2>&1 || missing+=(iproute2)
  command -v "$SSH"     >/dev/null 2>&1 || missing+=(openssh-client)

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi
  if [[ ${SST_NO_APT:-0} == 1 ]]; then
    die "missing required commands and package installation disabled: ${missing[*]}"
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    die "missing required commands: ${missing[*]} (install them manually)"
  fi

  step "installing packages: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq || die "apt-get update failed"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" \
    || die "apt-get install failed: ${missing[*]}"
}

# ---------------------------------------------------------------------------
# HAProxy config rendering
# ---------------------------------------------------------------------------
fragment_file() { printf '%s/foreign-%s.cfg' "$SST_HAPROXY_DIR" "$1"; }

render_fragment() {
  local idx=$1 frontend lanes
  frontend=$(state_frontend "$idx") || return 1
  mapfile -t lanes < <(state_lanes "$idx")

  {
    printf '# %s foreign #%s - generated, do not edit by hand\n' "$APP" "$idx"
    printf 'frontend %s_f%s\n' "$APP" "$idx"
    printf '    bind 0.0.0.0:%s\n' "$frontend"
    printf '    default_backend %s_lanes_f%s\n' "$APP" "$idx"
    printf 'backend %s_lanes_f%s\n' "$APP" "$idx"
    printf '    balance roundrobin\n'
    printf '    option tcp-check\n'
    local j
    for j in 1 2 3 4; do
      printf '    server %s_f%s_lane%s 127.0.0.1:%s check inter 2s fall 2 rise 2\n' \
        "$APP" "$idx" "$j" "${lanes[j-1]}"
    done
  } >"$(fragment_file "$idx")"
  chmod 644 "$(fragment_file "$idx")"
  log "fragment rendered: $(fragment_file "$idx")"
}

# Remove a previously managed include block, leaving every other line of the
# operator's haproxy.cfg untouched.
strip_managed_block() {
  local file=$1
  # Strip every *complete* begin/end pair, and nothing else:
  #  * an unpaired begin marker must not swallow the rest of the config, so
  #    the lines it opens are emitted when no end marker follows;
  #  * operator lines sitting between two separate managed blocks are kept.
  awk -v b="$HAPROXY_BEGIN" -v e="$HAPROXY_END" '
    { lines[NR] = $0 }
    END {
      i = 1
      while (i <= NR) {
        if (lines[i] == b) {
          j = i + 1
          while (j <= NR && lines[j] != e) j++
          if (j <= NR) { i = j + 1; continue }   # complete pair: drop it
        }
        print lines[i]
        i++
      }
    }
  ' "$file"
}

base_haproxy_cfg() {
  cat <<EOF
# Minimal base configuration created by $APP.
# Everything outside the $APP managed block is yours to edit.
global
    log /dev/log local0
    maxconn 10000

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 2m
    timeout server 2m
EOF
}

# Drop blank lines from the end of a config so that rebuilding a file which
# previously had a managed block appended to it does not accumulate whitespace.
trim_trailing_blank_lines() {
  awk 'NR==1 {first=$0} {buf[NR]=$0}
       END { last=NR
             while (last>=1 && buf[last] ~ /^[[:space:]]*$/) last--
             if (last==0) exit 0
             for (i=1;i<=last;i++) print buf[i] }'
}

# Build a candidate config in a temp file: current operator config with exactly
# one managed include block listing every configured foreign.
build_candidate() {
  local dest=$1 idx first=1

  if [[ -f $SST_HC ]]; then
    # Strip the old block, then drop the blank line that used to separate it from
    # the operator's config, so a rebuild is byte-stable instead of growing one
    # blank line per run.
    strip_managed_block "$SST_HC" | trim_trailing_blank_lines >"$dest"
  else
    base_haproxy_cfg >"$dest"
  fi

  {
    # Exactly one blank line separates the operator's config from the block.
    printf '\n%s\n' "$HAPROXY_BEGIN"
    for idx in $(configured_foreigns); do
      state_valid "$idx" || continue
      printf 'include %s\n' "$(fragment_file "$idx")"
      first=0
    done
    printf '%s\n' "$HAPROXY_END"
  } >>"$dest"

  if (( first == 1 )); then
    warn "no configured foreigns; managed block will be empty"
  fi
  log "candidate config built at $dest"
}

haproxy_validate() {
  local cfg=$1 out
  if ! command -v "$HAPROXY" >/dev/null 2>&1; then
    warn "haproxy binary not available; skipping syntax validation"
    return 0
  fi
  if out=$("$HAPROXY" -c -f "$cfg" 2>&1); then
    return 0
  fi
  printf '%s\n' "$out" >&2
  log "haproxy -c FAILED for $cfg: $out"
  return 1
}

haproxy_active() {
  [[ $(systemctl_is_active haproxy) == active ]]
}

# Apply a validated candidate. On any failure the previous config is restored
# and haproxy is put back the way it was.
apply_candidate() {
  local cand=$1 had_old=0 bak=''

  [[ -f $SST_HC ]] && had_old=1

  if ! haproxy_validate "$cand"; then
    err "candidate configuration failed 'haproxy -c'; it will NOT be activated."
    err "the previous configuration is untouched."
    if (( had_old )); then
      err "current live config remains: $SST_HC"
    fi
    return 1
  fi
  ok "haproxy -c passed validation"

  if (( had_old )); then
    bak=$(backup_file "$SST_HC")
    [[ -n $bak ]] && info "  previous config backed up to $bak"
  fi

  mkdir -p "$(dirname "$SST_HC")"
  cp -a -- "$cand" "$SST_HC"
  chmod 644 "$SST_HC"

  if ! "$SYSTEMCTL" enable haproxy >/dev/null 2>&1; then
    warn "could not enable haproxy at boot"
  fi
  if ! "$SYSTEMCTL" restart haproxy >/dev/null 2>&1; then
    err "haproxy failed to restart with the new configuration; rolling back"
    if (( had_old )) && [[ -n $bak && -f $bak ]]; then
      cp -a -- "$bak" "$SST_HC"
      "$SYSTEMCTL" restart haproxy >/dev/null 2>&1 \
        && warn "rolled back to the previous working configuration" \
        || err "rollback also failed - inspect $SST_HC and $SST_BACKUP manually"
    else
      err "no previous configuration to roll back to"
    fi
    return 1
  fi
  ok "haproxy reloaded with the new configuration"
  return 0
}

# Full Iran-side config refresh: render every fragment, build, validate, apply.
rebuild_haproxy() {
  local idx cand rc=0
  for idx in $(configured_foreigns); do
    state_valid "$idx" || { warn "state for foreign #$idx is invalid; skipped"; continue; }
    render_fragment "$idx" || { warn "could not render fragment for foreign #$idx"; rc=1; }
  done
  (( rc == 0 )) || return 1

  cand=$(mktemp "${TMPDIR:-/tmp}/$APP.cand.XXXXXX")
  build_candidate "$cand"
  apply_candidate "$cand"
  rc=$?
  rm -f -- "$cand"
  return $rc
}

# ---------------------------------------------------------------------------
# systemd helpers
# ---------------------------------------------------------------------------
systemctl_is_active() {
  "$SYSTEMCTL" is-active "$1" 2>/dev/null || true
}

systemctl_is_enabled() {
  "$SYSTEMCTL" is-enabled "$1" 2>/dev/null || true
}

unit_file() { printf '%s/%s-f%s-lane%s.service' "$SST_SD" "$APP" "$1" "$2"; }

unit_exists() { [[ -f $(unit_file "$1" "$2") ]]; }

# ---------------------------------------------------------------------------
# Iran: setup
# ---------------------------------------------------------------------------
check_frontend_port() {
  local idx=$1 port=$2
  if state_valid "$idx" && [[ $(state_frontend "$idx") == "$port" ]]; then
    return 0
  fi
  if port_in_use "$port"; then
    if haproxy_listen_ports | grep -qx "$port"; then
      warn "port $port is already bound by the live haproxy config"
      return 0
    fi
    err "port $port is already in use by another process"
    return 1
  fi
  if state_allocated_ports | grep -qx "$port"; then
    err "port $port is already allocated to another tunnel"
    return 1
  fi
  return 0
}

menu_setup_iran() {
  step "Setup Iran - HAProxy frontends and lane allocation"
  require_cmd awk sed grep
  ensure_pkgs

  local count reply idx frontend inbound existing lanes
  local -a keep=() lane_words=()
  local -a keep=()

  count=$(foreign_count)
  if (( count > 0 )); then
    info "Existing configuration: foreign(s) $(configured_foreigns | tr '\n' ' ')"
    warn "your existing port allocation will be reused and not re-allocated."
    info "Only add the new foreign; existing lanes keep working."
    hr
  fi

  reply=$count
  if (( count < 2 )); then
    ask_index reply "How many foreign servers will tunnel through Iran?" 1
  fi

  for (( idx = 1; idx <= reply; idx++ )); do
    hr
    if state_valid "$idx"; then
      existing=1
    else
      existing=0
    fi

    if (( existing )); then
      frontend=$(state_frontend "$idx")
      inbound=$(state_inbound "$idx")
      lanes=$(state_lanes "$idx" | tr '\n' ' ')
      ok "foreign #$idx already configured - keeping it unchanged"
      info "  frontend : $frontend"
      info "  xray in  : $inbound (on the foreign server)"
      info "  lanes    : $lanes"
      continue
    fi

    step "Foreign #$idx"
    ask_port frontend "Public frontend port on Iran for foreign #$idx"
    ask_port inbound "Xray inbound port on foreign #$idx (used as the lane target)"

    if [[ $frontend == "$inbound" ]]; then
      warn "frontend and xray port are the same number; that is allowed (different hosts)"
    fi

    if ! check_frontend_port "$idx" "$frontend"; then
      err "frontend port $frontend is unusable; foreign #$idx not configured"
      continue
    fi

    if ! lanes=$(allocate_lanes "$idx" "$LANE_SCAN_BASE"); then
      err "could not find 4 free lane ports for foreign #$idx"
      continue
    fi

    ok "allocated lanes: $lanes"
    # allocate_lanes returns four validated numeric ports; split them back into
    # positional args explicitly rather than relying on unquoted expansion.
    read -r -a lane_words <<<"$lanes"
    write_state "$idx" "$frontend" "$inbound" "${lane_words[@]}"
    keep+=( "$idx" )
  done

  hr
  step "Applying HAProxy configuration"
  if ! rebuild_haproxy; then
    err "HAProxy was not reconfigured. Any state written above is kept so you can retry."
    return 1
  fi

  set_role iran
  ok "Iran is configured"

  local f
  for f in $(configured_foreigns); do
    hr
    info "Foreign #$f"
    info "  frontend : $(state_frontend "$f")"
    info "  xray in  : $(state_inbound "$f") (on the foreign server)"
    info "  lanes    : $(state_lanes "$f" | tr '\n' ' ')"
    local code
    if code=$(emit_setup_code "$f"); then
      info ""
      info "  Setup code for foreign #$f - transfer this to the foreign server."
      info "  It contains no passwords or keys."
      printf '  %s\n' "$code"
    fi
    info ""
    info "  On the foreign server run: sudo ./$APP"
    info "  then choose '2) Add / Setup Foreign' and paste the code above."
  done
  info ""
  info "After the foreign prints its SSH public key, authorize it here with"
  info "  sudo ./$APP   ->   3) Authorize Foreign Public Key"
  return 0
}

# ---------------------------------------------------------------------------
# Iran: authorize foreign public key
# ---------------------------------------------------------------------------
menu_authorize_key() {
  step "Authorize a foreign server's SSH public key (run this on Iran)"
  local dir=$SST_SSH_DIR key reply added=0
  local auth="$dir/authorized_keys"

  if ! id -u nobody >/dev/null 2>&1 && ! grep -qE '^sshd' /etc/passwd 2>/dev/null; then
    warn "no sshd account found; is openssh-server installed?"
  fi

  mkdir -p "$dir"
  chmod 700 "$dir"
  touch "$auth"
  chmod 600 "$auth"
  info "Authorized keys file: $auth"
  hr

  while :; do
    prompt_read key "Paste the foreign server's PUBLIC key (or 'q' to finish)"
    prompt_exhausted "Paste the foreign server's PUBLIC key (or 'q' to finish)"
    [[ -z $key ]] && continue
    if [[ ${key,,} == q ]]; then break; fi
    key=${key#"${key%%[![:space:]]*}"}
    key=${key%"${key##*[![:space:]]}"}
    if ! valid_pubkey "$key"; then
      err "that does not look like an OpenSSH public key"
      continue
    fi
    if grep -qxF -- "$key" "$auth"; then
      ok "already authorized (no duplicate added)"
    else
      printf '%s\n' "$key" >>"$auth"
      ok "authorized"
      added=1
    fi
  done

  if (( added )); then
    if command -v systemctl >/dev/null 2>&1; then
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
        || warn "could not reload sshd; authorized_keys is already in place"
    fi
    info ""
    info "Now run '2) Add / Setup Foreign' on the foreign server to start its lanes."
  else
    info "No new keys were added."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Foreign: setup
# ---------------------------------------------------------------------------
ssh_key_path() { printf '%s/%s_f%s' "$SST_SSH_DIR" "$APP" "$1"; }
known_hosts_path() { printf '%s/%s_iran%s' "$SST_SSH_DIR" "$APP" "$1"; }

# Generate a key only when there is not already a usable one.
ensure_ssh_key() {
  local idx=$1 key
  key=$(ssh_key_path "$idx")

  if [[ -f $key && -f $key.pub ]]; then
    if "$SSH_KEYGEN" -y -f "$key" >/dev/null 2>&1; then
      ok "reusing existing healthy SSH key: $key"
      return 0
    fi
    warn "existing key $key is unreadable or corrupt"
    if confirm "Replace it with a new key pair?"; then
      backup_file "$key"; backup_file "$key.pub"
      rm -f -- "$key" "$key.pub"
    else
      err "cannot continue without a usable key"
      return 1
    fi
  fi

  mkdir -p "$SST_SSH_DIR"
  chmod 700 "$SST_SSH_DIR"
  if "$SSH_KEYGEN" -q -t ed25519 -N '' -C "$APP-foreign-$idx" -f "$key" >/dev/null 2>&1; then
    chmod 600 "$key"; chmod 644 "$key.pub"
    ok "generated ED25519 key: $key"
    return 0
  fi
  err "ssh-keygen failed"
  return 1
}

# Populate known_hosts. With StrictHostKeyChecking=yes an empty or partial file
# locks the tunnel out, so this refuses to install a bad file.
ensure_known_hosts() {
  local idx=$1 host=$2 sshport=$3 kh tmp
  kh=$(known_hosts_path "$idx")

  if [[ -s $kh ]] && ssh-keygen -F "[$host]:$sshport" -f "$kh" >/dev/null 2>&1; then
    ok "reusing existing known_hosts entry for $host:$sshport"
    return 0
  fi
  if [[ -s $kh ]] && ssh-keygen -F "$host" -f "$kh" >/dev/null 2>&1; then
    ok "reusing existing known_hosts entry for $host"
    return 0
  fi

  tmp=$(mktemp "${TMPDIR:-/tmp}/$APP.kh.XXXXXX")
  warn "scanning the host key of $host:$sshport (trusted on first use)"
  if ! "$SSH_KEYSCAN" -p "$sshport" -T 10 -H "$host" >"$tmp" 2>/dev/null || [[ ! -s $tmp ]]; then
    rm -f -- "$tmp"
    err "could not obtain the host key of $host:$sshport"
    err "fix routing/firewall, or pre-populate $(known_hosts_path "$idx") by hand,"
    err "then re-run. Continuing with an empty known_hosts would break the tunnel."
    return 1
  fi

  mkdir -p "$SST_SSH_DIR"
  chmod 700 "$SST_SSH_DIR"
  install -m 600 /dev/null "$kh"
  cat -- "$tmp" >>"$kh"
  rm -f -- "$tmp"
  ok "host key of $host:$sshport pinned in $kh"
  info "  Verify it out of band if this host is not already trusted."
  return 0
}

# Does a TCP listener exist on the given local port?
local_listening() {
  local p=$1
  "$SS" -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}\$"
}

write_units() {
  local idx=$1 ip=$2 inb=$3 sshport=$4
  shift 4
  local lanes=("$@")
  local key kh j unit tmp

  key=$(ssh_key_path "$idx")
  kh=$(known_hosts_path "$idx")

  for j in 1 2 3 4; do
    unit=$(unit_file "$idx" "$j")
    # systemd ExecStart has no shell, so quoting is literal; every substituted
    # value was validated above (host charset, integers).
    tmp=$(mktemp "${TMPDIR:-/tmp}/$APP.unit.XXXXXX")
    cat >"$tmp" <<EOF
[Unit]
Description=$APP reverse SSH lane $j of 4 (foreign #$idx)
Documentation=https://github.com/nabilety008/$APP.sh
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$SSH -N -T \\
  -o BatchMode=yes \\
  -o ExitOnForwardFailure=yes \\
  -o ServerAliveInterval=15 \\
  -o ServerAliveCountMax=3 \\
  -o TCPKeepAlive=yes \\
  -o Compression=no \\
  -o ExitOnForwardFailure=yes \\
  -o StrictHostKeyChecking=yes \\
  -o UserKnownHostsFile=$kh \\
  -o IdentitiesOnly=yes \\
  -i $key \\
  -p $sshport \\
  -R 127.0.0.1:${lanes[j-1]}:127.0.0.1:$inb \\
  root@$ip
Restart=always
RestartSec=5
KillMode=process
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
    if [[ -f $unit ]]; then
      if cmp -s "$tmp" "$unit"; then
        rm -f -- "$tmp"
        ok "lane $j unit already up to date"
        continue
      fi
      backup_file "$unit" >/dev/null
      info "  lane $j unit updated"
    else
      info "  lane $j unit created"
    fi
    install -m 644 "$tmp" "$unit"
    rm -f -- "$tmp"
  done

  "$SYSTEMCTL" daemon-reload >/dev/null 2>&1 || warn "daemon-reload failed"
}

enable_units() {
  local idx=$1 j svc
  for j in 1 2 3 4; do
    svc="$APP-f$idx-lane$j.service"
    "$SYSTEMCTL" enable "$svc" >/dev/null 2>&1 || warn "could not enable $svc at boot"
    "$SYSTEMCTL" restart  "$svc" >/dev/null 2>&1 || warn "could not start $svc"
  done
}

menu_setup_foreign() {
  step "Add / Setup a foreign server (run this on the FOREIGN server)"
  require_cmd awk sed grep
  ensure_pkgs

  local ip idx inbound code sshport lanes
  local -a lane_arr=()

  ask_host ip "Iran server IP address or hostname"
  ask_index idx "Which foreign number is this? (match the one you set up on Iran)"

  if state_valid "$idx"; then
    warn "foreign #$idx is already configured on this host:"
    info "  iran  : $(state_get "$idx" IRAN_IP 2>/dev/null || echo '?')"
    info "  lanes : $(state_lanes "$idx" | tr '\n' ' ')"
    info "  xray  : $(state_inbound "$idx")"
    if confirm "Re-run setup for foreign #$idx and overwrite the saved settings?"; then
      info "continuing"
    else
      info "left unchanged. Use '4) Status' or '5) Repair' instead."
      return 0
    fi
  fi

  ask_port inbound "Xray inbound port on THIS foreign server (must already exist)"

  step "Paste the setup code generated by Iran"
  prompt_read code "Setup code (base64)"
  if ! parse_setup_code "$code"; then
    err "setup code is invalid or unreadable"
    info "On Iran run: sudo ./$APP  ->  '1) Setup Iran' to reprint it,"
    info "or '4) Status' to view it without changing anything."
    return 1
  fi
  ok "setup code accepted (foreign #$SC_IDX)"

  if [[ $SC_IDX != "$idx" ]]; then
    err "this setup code is for foreign #$SC_IDX but you selected #$idx"
    return 1
  fi

  if [[ -n $SC_IRAN_IP ]]; then
    if [[ $SC_IRAN_IP != "$ip" ]]; then
      warn "setup code says Iran is $SC_IRAN_IP but you entered $ip"
      if ! confirm "Trust the setup code value ($SC_IRAN_IP)?"; then
        err "aborted; check the Iran address"
        return 1
      fi
      ip=$SC_IRAN_IP
    else
      ok "Iran address in the setup code matches"
    fi
  fi

  sshport=$SC_SSH_PORT
  lane_arr=("${SC_LANES[@]}")
  lanes="${lane_arr[*]}"

  info ""
  info "  iran ip      : $ip:$sshport"
  info "  frontend     : $SC_FRONTEND (on Iran)"
  info "  xray inbound : $inbound (here, read-only - not modified)"
  info "  lane ports   : $lanes (allocated by Iran)"
  info ""

  # Verify the Xray inbound exists. We only listen for it; never configure it.
  if local_listening "$inbound"; then
    ok "Xray inbound is listening on 127.0.0.1:$inbound"
  else
    warn "nothing is listening on 127.0.0.1:$inbound"
    warn "expected: your existing Xray/3x-ui inbound on that port"
    if ! confirm "Continue anyway? (the lane will stay down until Xray listens)"; then
      err "aborted; Xray was not touched"
      return 1
    fi
  fi

  write_state "$idx" "$SC_FRONTEND" "$inbound" "${lane_arr[@]}"
  # Persist the Iran endpoint for status/repair; it is a validated host.
  local f
  f=$(state_file "$idx")
  printf 'IRAN_IP=%s\n' "$ip" >>"$f"
  printf 'IRAN_SSH_PORT=%s\n' "$sshport" >>"$f"
  chmod 600 "$f"
  set_role foreign

  if ! ensure_ssh_key "$idx"; then
    err "no usable SSH key"
    return 1
  fi
  if ! ensure_known_hosts "$idx" "$ip" "$sshport"; then
    err "host key not pinned; refusing to start lanes with an empty known_hosts"
    return 1
  fi

  write_units "$idx" "$ip" "$inbound" "$sshport" "${lane_arr[@]}"
  enable_units "$idx"

  sleep 2
  step "Lane status"
  local j up=0
  for j in 1 2 3 4; do
    if [[ $(systemctl_is_active "$APP-f$idx-lane$j.service") == active ]]; then
      ok "lane $j: UP"
      up=$((up+1))
    else
      warn "lane $j: DOWN  ($(systemctl is-failed "$APP-f$idx-lane$j.service" 2>/dev/null || echo unknown))"
      info "  logs: journalctl -u $APP-f$idx-lane$j.service -n 40 --no-pager"
    fi
  done
  hr
  info "PUBLIC KEY - authorize this on Iran (option 3):"
  cat "$(ssh_key_path "$idx").pub"
  info ""
  info "  $up/4 lanes up. This script does not modify Xray or 3x-ui."
  return 0
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
lane_state() {
  local idx=$1 j lane svc
  j=$2
  lane=$(state_get "$idx" "LANE$j")
  svc="$APP-f$idx-lane$j.service"

  if [[ $(get_role) == iran ]]; then
    if [[ -n $lane ]] && local_listening "$lane"; then
      printf 'Lane %s: %sUP%s (127.0.0.1:%s listening)\n' "$j" "$C_GREEN" "$C_RESET" "$lane"
    else
      printf 'Lane %s: %sDOWN%s (no listener on 127.0.0.1:%s)\n' "$j" "$C_YELLOW" "$C_RESET" "${lane:-?}"
    fi
  else
    if [[ $(systemctl_is_active "$svc") == active ]]; then
      printf 'Lane %s: %sUP%s (%s)\n' "$j" "$C_GREEN" "$C_RESET" "$svc"
    else
      printf 'Lane %s: %sDOWN%s (%s = %s)\n' "$j" "$C_YELLOW" "$C_RESET" "$svc" "$(systemctl_is_active "$svc")"
    fi
  fi
}

show_foreign_status() {
  local idx=$1 frontend inbound j lanes_ready=1 svc

  info "Foreign #$idx"
  if ! state_valid "$idx"; then
    warn "  state file is missing or invalid: $(state_file "$idx")"
    printf '  Overall: %sUNKNOWN%s\n' "$C_YELLOW" "$C_RESET"
    return 1
  fi

  frontend=$(state_frontend "$idx")
  inbound=$(state_inbound "$idx")

  printf '  Frontend: %s:%s\n' "0.0.0.0" "$frontend"
  printf '  Xray destination: 127.0.0.1:%s\n' "$inbound"

  if [[ $(get_role) == iran ]]; then
    if port_in_use "$frontend"; then
      printf '  Frontend listener: %sUP%s\n' "$C_GREEN" "$C_RESET"
    else
      printf '  Frontend listener: %sDOWN%s\n' "$C_YELLOW" "$C_RESET"
    fi
  fi

  for j in 1 2 3 4; do
    lane_state "$idx" "$j"
    svc="$APP-f$idx-lane$j.service"
    if [[ $(get_role) == iran ]]; then
      :
    elif [[ $(systemctl_is_active "$svc") != active ]]; then
      lanes_ready=0
    fi
  done

  if [[ $(get_role) == iran ]]; then
    if haproxy_active; then
      printf '  HAProxy: %sHEALTHY%s (%s)\n' "$C_GREEN" "$C_RESET" "$(systemctl_is_active haproxy)"
    else
      printf '  HAProxy: %s%s%s\n' "$C_YELLOW" "$(systemctl_is_active haproxy)" "$C_RESET"
      lanes_ready=0
    fi
    if haproxy_validate "$SST_HC" >/dev/null 2>&1; then
      printf '  HAProxy config: %svalid%s\n' "$C_GREEN" "$C_RESET"
    else
      printf '  HAProxy config: %sinvalid%s\n' "$C_RED" "$C_RESET"
      lanes_ready=0
    fi
  else
    if local_listening "$inbound"; then
      printf '  Local Xray inbound: %slistening%s on 127.0.0.1:%s\n' "$C_GREEN" "$C_RESET" "$inbound"
    else
      printf '  Local Xray inbound: %sNOT listening%s on 127.0.0.1:%s\n' "$C_YELLOW" "$C_RESET" "$inbound"
      lanes_ready=0
    fi
  fi

  if (( lanes_ready )); then
    printf '  Overall: %sREADY%s\n' "$C_GREEN" "$C_RESET"
  else
    printf '  Overall: %sDEGRADED%s\n' "$C_YELLOW" "$C_RESET"
  fi
  return 0
}

menu_status() {
  local role idx any=0 rc=0
  role=$(get_role)
  hr
  info "StarSpeed tunnel status   (role: $role, version $VERSION)"
  hr

  if [[ $role == iran ]]; then
    printf '  HAProxy: %s   config: %s\n' \
      "$(systemctl_is_active haproxy)" \
      "$(haproxy_validate "$SST_HC" >/dev/null 2>&1 && echo valid || echo invalid)"
    info ""
  fi

  for idx in $(configured_foreigns); do
    [[ -n $idx ]] || continue
    any=1
    show_foreign_status "$idx" || rc=1
    hr
  done

  if (( any == 0 )); then
    info "No tunnels are configured yet."
    info "On Iran choose '1) Setup Iran'; on a foreign choose '2) Add / Setup Foreign'."
    return 0
  fi

  info "Setup codes (safe to transfer; they contain no secrets):"
  for idx in $(configured_foreigns); do
    [[ -n $idx ]] || continue
    printf '  foreign #%s: %s\n' "$idx" "$(emit_setup_code "$idx")"
  done
  info ""
  info "Public keys of foreign servers configured on this host:"
  for idx in 1 2; do
    k=$(ssh_key_path "$idx")
    [[ -f $k.pub ]] && printf '  foreign #%s: %s\n' "$idx" "$(cat "$k.pub")"
  done
  return $rc
}

# ---------------------------------------------------------------------------
# Repair
# ---------------------------------------------------------------------------
repair_iran() {
  local idx fe fixed=0 need=0
  step "Repairing the Iran side"

  # 1. state files
  for idx in $(configured_foreigns); do
    if ! state_valid "$idx"; then
      warn "foreign #$idx state is invalid"
      if confirm "Remove the broken state for foreign #$idx?"; then
        rm -f -- "$(state_file "$idx")"
        need=1
        warn "state removed; re-run '1) Setup Iran' to re-add it"
      fi
    fi
  done

  # 2. fragments + config
  for idx in $(configured_foreigns); do
    state_valid "$idx" || continue
    if [[ ! -f $(fragment_file "$idx") ]]; then
      warn "fragment missing for foreign #$idx"
      need=1
    fi
  done

  # 3. live config health
  if ! haproxy_validate "$SST_HC" >/dev/null 2>&1; then
    err "the live HAProxy configuration does not validate"
    local bak
    bak=$(latest_backup "$SST_BACKUP")
    if [[ -n $bak && -f $bak ]] && haproxy_validate "$bak" >/dev/null 2>&1; then
      warn "a valid backup exists: $bak"
      if confirm "Restore it and restart HAProxy?"; then
        cp -a -- "$bak" "$SST_HC"
        "$SYSTEMCTL" restart haproxy >/dev/null 2>&1 \
          && ok "restored the last known-good configuration" \
          || err "restart failed after restore"
        fixed=1
      fi
    else
      warn "no valid backup found; a rebuild from saved state is required"
      need=1
    fi
  fi

  # 4. rebuild only what is missing / wrong
  if (( need )); then
    if confirm "Rebuild the HAProxy configuration from saved state?"; then
      if rebuild_haproxy; then
        ok "HAProxy configuration rebuilt"
        fixed=1
      else
        err "rebuild failed; the previous configuration was left in place"
        return 1
      fi
    fi
  elif ! haproxy_active; then
    warn "HAProxy is not running"
    if confirm "Start it?"; then
      "$SYSTEMCTL" enable haproxy >/dev/null 2>&1 || true
      if "$SYSTEMCTL" restart haproxy >/dev/null 2>&1; then
        ok "HAProxy started"; fixed=1
      else
        err "HAProxy would not start; run: $HAPROXY -c -f $SST_HC"
      fi
    fi
  fi

  # 5. frontend listener
  for idx in $(configured_foreigns); do
    state_valid "$idx" || continue
    fe=$(state_frontend "$idx")
    if ! port_in_use "$fe"; then
      warn "frontend $fe is not listening"
      if confirm "Restart HAProxy to rebind frontend $fe (foreign #$idx)?"; then
        "$SYSTEMCTL" restart haproxy >/dev/null 2>&1 && { ok "HAProxy restarted"; fixed=1; }
      fi
    fi
  done

  (( fixed )) && ok "Iran repair finished" || info "Iran looks healthy; nothing repaired."
  return 0
}

repair_lane_listener() {
  local idx=$1 j=$2 lane
  lane=$(state_get "$idx" "LANE$j")
  if [[ -n $lane ]] && local_listening "$lane"; then
    ok "foreign #$idx lane $j: listener present on 127.0.0.1:$lane"
    return 0
  fi
  warn "foreign #$idx lane $j: no listener on 127.0.0.1:${lane:-?}"
  info "  On the foreign server: systemctl status $APP-f$idx-lane$j.service"
  return 1
}

repair_foreign() {
  local idx=$1 inb ip sshport lanes j svc
  local -a lane_arr=()
  step "Repairing the foreign side"

  if ! state_valid "$idx"; then
    err "no valid state for foreign #$idx on this host"
    info "Re-run '2) Add / Setup Foreign' with a fresh setup code from Iran."
    return 1
  fi

  inb=$(state_inbound "$idx")
  ip=$(state_get "$idx" IRAN_IP || true)
  sshport=$(state_get "$idx" IRAN_SSH_PORT || echo "$IRAN_SSH_PORT")
  mapfile -t lane_arr < <(state_lanes "$idx")

  if [[ -z $ip ]] || ! valid_host "$ip"; then
    err "the saved Iran address is missing or invalid"
    info "Re-run '2) Add / Setup Foreign' to set it again."
    return 1
  fi

  # 1. local Xray destination
  if local_listening "$inb"; then
    ok "local Xray inbound is listening on 127.0.0.1:$inb"
  else
    warn "local Xray inbound is NOT listening on 127.0.0.1:$inb"
    info "  This script does not create or modify Xray/3x-ui inbounds."
    info "  Start your existing inbound, then re-run this repair."
  fi

  # 2. key material
  ensure_ssh_key "$idx" || return 1
  ensure_known_hosts "$idx" "$ip" "$sshport" || {
    warn "host key could not be refreshed"
  }

  # 3. units
  local need_units=0
  for j in 1 2 3 4; do
    unit_exists "$idx" "$j" || { warn "lane $j unit is missing"; need_units=1; }
  done
  if (( need_units )); then
    if confirm "Recreate the missing lane unit(s)?"; then
      write_units "$idx" "$ip" "$inb" "$sshport" "${lane_arr[@]}"
    else
      warn "skipping unit recreation"
    fi
  else
    info "  units present; refreshing them from saved state"
    write_units "$idx" "$ip" "$inb" "$sshport" "${lane_arr[@]}"
  fi

  # 4. enable + running, per lane only
  for j in 1 2 3 4; do
    svc="$APP-f$idx-lane$j.service"
    [[ -f $(unit_file "$idx" "$j") ]] || continue
    if [[ $(systemctl_is_enabled "$svc") != enabled ]]; then
      warn "$svc is not enabled at boot"
      "$SYSTEMCTL" enable "$svc" >/dev/null 2>&1 && ok "$svc enabled at boot"
    fi
    if [[ $(systemctl_is_active "$svc") != active ]]; then
      warn "$svc is not running"
      if confirm "  Start $svc?"; then
        "$SYSTEMCTL" restart "$svc" >/dev/null 2>&1 \
          && ok "$svc restarted" \
          || warn "$svc still not running; check: journalctl -u $svc -n 40 --no-pager"
      fi
    else
      ok "$svc is running"
    fi
  done

  "$SYSTEMCTL" daemon-reload >/dev/null 2>&1 || true
  return 0
}

menu_repair() {
  step "Repair - check saved state, HAProxy, frontends, lanes and services"
  local role idx any=0
  role=$(get_role)

  if [[ $role == iran ]]; then
    if (( $(foreign_count) == 0 )); then
      warn "Iran has no configured foreigns; nothing to repair."
      return 0
    fi
    repair_iran
    hr
    for idx in $(configured_foreigns); do
      any=1
      show_foreign_status "$idx" || true
      hr
    done
    (( any )) || true
    return 0
  fi

  if [[ $role == foreign ]]; then
    for idx in $(configured_foreigns); do
      [[ -n $idx ]] || continue
      repair_foreign "$idx"
      hr
      show_foreign_status "$idx" || true
      hr
    done
    return 0
  fi

  warn "role is '$role'; cannot tell which side this host is."
  info "Run '1) Setup Iran' on Iran, or '2) Add / Setup Foreign' on a foreign server."
  return 0
}

# ---------------------------------------------------------------------------
# Remove / uninstall
# ---------------------------------------------------------------------------
menu_remove_foreign() {
  step "Remove a foreign tunnel (Xray and 3x-ui are never touched)"
  local idx j svc unit removed=0

  ask_index idx "Which foreign number should be removed?" 1

  if ! state_valid "$idx"; then
    warn "foreign #$idx has no valid saved state on this host"
  else
    info "foreign #$idx:"
    info "  frontend : $(state_frontend "$idx")"
    info "  lanes    : $(state_lanes "$idx" | tr '\n' ' ')"
    info "  xray in  : $(state_inbound "$idx")  (left completely alone)"
  fi

  info ""
  warn "On Iran this also removes the HAProxy frontend/backend for this foreign only."
  if ! confirm "Remove foreign #$idx?"; then
    info "cancelled; nothing changed"
    return 0
  fi

  # Remove only this foreign's units.
  for j in 1 2 3 4; do
    svc="$APP-f$idx-lane$j.service"
    unit=$(unit_file "$idx" "$j")
    if [[ -f $unit ]]; then
      backup_file "$unit" >/dev/null
      rm -f -- "$unit"
      info "  removed $unit"
      removed=1
    fi
    "$SYSTEMCTL" disable --now "$svc" >/dev/null 2>&1 || true
  done
  "$SYSTEMCTL" daemon-reload >/dev/null 2>&1 || true

  # Drop state and fragment.
  rm -f -- "$(state_file "$idx")" "$(fragment_file "$idx")"

  local role; role=$(get_role)
  if [[ $role == iran ]] && haproxy_active_command_available; then
    if rebuild_haproxy; then
      ok "HAProxy reconfigured; other foreigns are untouched"
    else
      err "HAProxy reconfiguration failed; the previous config is still active"
      return 1
    fi
  fi

  (( removed )) && ok "foreign #$idx removed" || ok "foreign #$idx state cleared (nothing was running)"
  info "Xray / 3x-ui and any 'Direct' configuration were not modified."
  return 0
}

haproxy_active_command_available() { command -v "$HAPROXY" >/dev/null 2>&1; }

menu_uninstall() {
  step "Uninstall $APP"
  info "This removes, on this host only:"
  info "  * reverse SSH systemd units (lanes) and their backups"
  info "  * saved state and generated HAProxy fragments"
  info "  * the managed include block inside $SST_HC"
  info ""
  warn "Xray / 3x-ui, its inbounds and any 'Direct' config are NOT touched."
  warn "The SSH keypair for this host is kept by default; you may remove it manually."
  hr

  if ! confirm "Uninstall $APP from this host?"; then
    info "cancelled; nothing changed"
    return 0
  fi

  local role; role=$(get_role)
  local idx j unit removed=0

  for idx in 1 2; do
    for j in 1 2 3 4; do
      unit=$(unit_file "$idx" "$j")
      svc="$APP-f$idx-lane$j.service"
      if [[ -f $unit ]]; then
        backup_file "$unit" >/dev/null
        rm -f -- "$unit"
        removed=1
      fi
      "$SYSTEMCTL" disable --now "$svc" >/dev/null 2>&1 || true
    done
  done
  "$SYSTEMCTL" daemon-reload >/dev/null 2>&1 || true
  (( removed )) && info "  systemd units removed" || info "  no systemd units found"

  # Strip the managed block from haproxy.cfg, leaving all other lines intact.
  if [[ -f $SST_HC ]] && grep -qF "$HAPROXY_BEGIN" "$SST_HC"; then
    backup_file "$SST_HC" >/dev/null
    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/$APP.hc.XXXXXX")
    strip_managed_block "$SST_HC" >"$tmp"
    if haproxy_validate "$tmp"; then
      install -m 644 "$tmp" "$SST_HC"
      "$SYSTEMCTL" restart haproxy >/dev/null 2>&1 \
        && ok "managed include block removed from $SST_HC; haproxy restarted" \
        || warn "haproxy config updated but restart failed"
    else
      warn "stripped config did not validate; leaving $SST_HC untouched"
    fi
    rm -f -- "$tmp"
  else
    info "  no managed block in $SST_HC"
  fi

  rm -f -- "$SST_HAPROXY_DIR"/foreign-*.cfg
  rm -f -- "$SST_STATE"/foreign-*.env "$SST_STATE"/role

  if confirm "Also remove saved backups and logs in $SST_BASE?"; then
    rm -rf -- "$SST_BACKUP" "$LOGFILE"
    info "  backups and log removed"
  else
    info "  backups kept in $SST_BACKUP"
  fi

  if confirm "Remove this host's generated SSH keypair?"; then
    for idx in 1 2; do
      local k; k=$(ssh_key_path "$idx")
      [[ -f $k ]] && { rm -f -- "$k" "$k.pub"; info "  removed $k"; }
      local kh; kh=$(known_hosts_path "$idx")
      [[ -f $kh ]] && { rm -f -- "$kh"; info "  removed $kh"; }
    done
  else
    info "  SSH keypair and known_hosts kept in $SST_SSH_DIR"
  fi

  rmdir "$SST_STATE" "$SST_HAPROXY_DIR" "$SST_BASE" 2>/dev/null || true
  ok "$APP uninstalled from this host (role was: $role)"
  return 0
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
$APP $VERSION - multi-lane reverse SSH tunnel installer

usage: $APP [options]

  (no options)        interactive menu
  --status            print status and exit
  --setup-code N      print the setup code for foreign #N and exit
  --role              print this host's role (iran / foreign / unknown)
  --version           print version
  --help              this text

menu:
  1) Setup Iran
  2) Add / Setup Foreign
  3) Authorize Foreign Public Key
  4) Status
  5) Repair
  6) Remove Foreign
  7) Uninstall
  0) Exit
EOF
}

main() {
  case ${1:-} in
    --help|-h)    usage; return 0 ;;
    --version|-V) printf '%s %s\n' "$APP" "$VERSION"; return 0 ;;
    --role)       get_role; return 0 ;;
  esac

  require_root
  prompt_init
  init_logging
  trap 'on_error $LINENO' ERR

  case ${1:-} in
    --status)
      menu_status
      return $?
      ;;
    --setup-code)
      local idx=${2:-}
      if ! valid_index "$idx"; then die "usage: $APP --setup-code 1|2"; fi
      emit_setup_code "$idx" || die "no valid state for foreign #$idx"
      printf '\n'
      return 0
      ;;
  esac

  local choice
  while :; do
    hr
    printf '%sStarSpeed Tunnel%s  %s(v%s)%s\n' "$C_BOLD" "$C_RESET" "$C_BLUE" "$VERSION" "$C_RESET"
    printf '  role on this host: %s\n' "$(get_role)"
    hr
    printf '  1) Setup Iran\n'
    printf '  2) Add / Setup Foreign\n'
    printf '  3) Authorize Foreign Public Key\n'
    printf '  4) Status\n'
    printf '  5) Repair\n'
    printf '  6) Remove Foreign\n'
    printf '  7) Uninstall\n'
    printf '  0) Exit\n'
    hr
    prompt_read choice "Select"

    case $choice in
      1) menu_setup_iran ;;
      2) menu_setup_foreign ;;
      3) menu_authorize_key ;;
      4) menu_status ;;
      5) menu_repair ;;
      6) menu_remove_foreign ;;
      7) menu_uninstall ;;
      0|"") exit 0 ;;
      *) warn "invalid selection: $choice" ;;
    esac

    if [[ -t 0 ]]; then
      printf '\n'
      read -r -p "Press Enter to continue..." _ || true
    fi
  done
}

main "$@"