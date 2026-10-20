#!/usr/bin/env bash
# Safe, idempotent bootstrap for StarSpeed Tunnel.
set -Eeuo pipefail

APP=starspeed-tunnel
RAW_URL=${SST_INSTALL_URL:-https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/starspeed-tunnel.sh}
INSTALL_DIR=${SST_INSTALL_DIR:-/usr/local/sbin}
INSTALL_PATH=${SST_INSTALL_PATH:-$INSTALL_DIR/$APP}
OS_RELEASE=${SST_INSTALL_OS_RELEASE:-/etc/os-release}
FETCHER=${SST_INSTALL_FETCHER:-auto}
tmp=''

if [[ ${1:-} == --lang ]]; then
  case ${2:-} in
    en|fa) ;;
    *) printf 'starspeed-tunnel installer: usage: install.sh [--lang en|fa]\n' >&2; exit 1 ;;
  esac
fi

msg() {
  local key=$1 detail=${2:-}
  case $key in
      root) printf 'must run as root (use sudo)' ;;
      os_meta) printf 'cannot read OS metadata: %s' "$detail" ;;
      unsupported) printf 'unsupported operating system: %s (supported: Ubuntu 22.04/24.04)' "$detail" ;;
      missing_cmd) printf 'required command not found: %s' "$detail" ;;
      temp) printf 'cannot create secure temporary download' ;;
      download) printf 'download failed (%s)' "$detail" ;;
      downloader) printf 'curl or wget is required' ;;
      empty) printf 'downloaded file is empty' ;;
      read) printf 'cannot read downloaded file' ;;
      entrypoint) printf 'downloaded file is not the StarSpeed Bash entrypoint' ;;
      syntax) printf 'downloaded script failed syntax validation' ;;
      identity) printf 'downloaded script identity check failed' ;;
      fetcher) printf 'invalid downloader: %s' "$detail" ;;
      installed) printf 'StarSpeed Tunnel installed: %s' "$detail" ;;
  esac
}
die() { printf 'starspeed-tunnel installer: %s\n' "$(msg "$@")" >&2; exit 1; }
cleanup() { [[ -z $tmp ]] || rm -f -- "$tmp"; }
trap cleanup EXIT

if [[ ${SST_INSTALL_ALLOW_NONROOT:-0} != 1 && ${EUID:-$(id -u)} -ne 0 ]]; then
  die root
fi
for required in bash mktemp mkdir chmod mv grep; do
  command -v "$required" >/dev/null 2>&1 || die missing_cmd "$required"
done
[[ -r $OS_RELEASE ]] || die os_meta "$OS_RELEASE"
# shellcheck disable=SC1090
. "$OS_RELEASE"
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} =~ ^(22\.04|24\.04)$ ]] ||
  die unsupported "${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-unknown}}"

mkdir -p -- "$INSTALL_DIR"
tmp=$(mktemp "$INSTALL_DIR/.${APP}.tmp.XXXXXX") || die temp

case $FETCHER in
  auto)
    if command -v curl >/dev/null 2>&1; then FETCHER=curl
    elif command -v wget >/dev/null 2>&1; then FETCHER=wget
    else die downloader
    fi ;;
  curl|wget) command -v "$FETCHER" >/dev/null 2>&1 || die missing_cmd "$FETCHER" ;;
  *) die fetcher "$FETCHER" ;;
esac
if [[ $FETCHER == curl ]]; then
  curl -fL --retry 3 --connect-timeout 15 --output "$tmp" "$RAW_URL" || die download curl
else
  wget --https-only --tries=3 --timeout=30 --output-document="$tmp" "$RAW_URL" || die download wget
fi

[[ -s $tmp ]] || die empty
IFS= read -r first_line <"$tmp" || die read
[[ $first_line == '#!/usr/bin/env bash' || $first_line == '#!/bin/bash' ]] ||
  die entrypoint
bash -n "$tmp" || die syntax
grep -q '^APP=starspeed-tunnel$' "$tmp" || die identity

chmod 0755 "$tmp"
mv -f -- "$tmp" "$INSTALL_PATH"
tmp=''
printf '%s\n' "$(msg installed "$INSTALL_PATH")"

# `--lang fa` is passed through for its compatibility notice; the launched menu
# is English in every case.
if [[ ${1:-} == --lang ]]; then
  "$INSTALL_PATH" --lang "$2"
  shift 2
fi
exec "$INSTALL_PATH" "$@"
