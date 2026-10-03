#!/usr/bin/env bash
set -Eeuo pipefail
APP=starspeed-tunnel; BASE=/etc/$APP; STATE=$BASE/state; BK=$BASE/backups; SD=/etc/systemd/system; HC=/etc/haproxy/haproxy.cfg
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
mkdir -p "$BASE" "$STATE" "$BK"
ask(){ local n=$1 q=$2 d=${3:-} x; read -r -p "$q${d:+ [$d]}: " x; printf -v "$n" %s "${x:-$d}"; }
free(){ ! ss -lnt | awk '{print $4}' | grep -Eq "[:.]$1$"; }
backup(){ [[ -f "$1" ]] && cp -a "$1" "$BK/$(basename "$1").$(date +%s)"; }
pkgs(){ apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"; }

iran(){
 pkgs haproxy openssh-server; backup "$HC"; local n i f inb base j
 ask n "Number of foreign servers (1/2)" 1; [[ $n =~ ^[12]$ ]] || return
 cat >"$BASE/haproxy.cfg" <<EOF
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
 for ((i=1;i<=n;i++)); do
  ask f "Foreign #$i - public port on Iran"
  ask inb "Foreign #$i - Xray inbound port on Foreign"
  free "$f" || { echo "Port $f busy"; return; }
  base=$((46000+i*100))
  while ! (free $((base+1)) && free $((base+2)) && free $((base+3)) && free $((base+4))); do base=$((base+10)); done
  cat >>"$BASE/haproxy.cfg" <<EOF

frontend tunnel_$i
    bind 0.0.0.0:$f
    default_backend lanes_$i
backend lanes_$i
    balance roundrobin
    option tcp-check
    server lane1 127.0.0.1:$((base+1)) check inter 2s fall 2 rise 2
    server lane2 127.0.0.1:$((base+2)) check inter 2s fall 2 rise 2
    server lane3 127.0.0.1:$((base+3)) check inter 2s fall 2 rise 2
    server lane4 127.0.0.1:$((base+4)) check inter 2s fall 2 rise 2
EOF
  printf 'FRONTEND=%s\nINBOUND=%s\nLANES="%s %s %s %s"\n' "$f" "$inb" $((base+1)) $((base+2)) $((base+3)) $((base+4)) >"$STATE/f$i"
 done
 cp "$BASE/haproxy.cfg" "$HC"; haproxy -c -f "$HC"; systemctl enable --now haproxy; systemctl restart haproxy
 echo "Iran ready. Run this script on each Foreign. Use menu 2 here to authorize its PUBLIC key."
 for ((i=1;i<=n;i++)); do echo "Foreign #$i: $(tr '\n' ' ' <"$STATE/f$i")"; done
}

auth(){
 mkdir -p /root/.ssh; chmod 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
 echo "Paste Foreign PUBLIC key:"; IFS= read -r k; [[ $k == ssh-* ]] || { echo "Invalid key"; return; }
 grep -qxF "$k" /root/.ssh/authorized_keys || echo "$k" >>/root/.ssh/authorized_keys; echo "Authorized."
}

foreign(){
 pkgs openssh-client; local ip idx inb base key known j p svc
 ask ip "Iran IP"; ask idx "Foreign number (1/2)" 1; ask inb "Xray inbound port on THIS Foreign"
 [[ $idx =~ ^[12]$ ]] || return
 ss -lnt | awk '{print $4}' | grep -Eq "[:.]$inb$" || { echo "WARNING: :$inb is not listening."; read -r -p "Continue? [y/N] " x; [[ ${x,,} == y ]] || return; }
 base=$((46000+idx*100)); key=/root/.ssh/${APP}_f$idx; known=/root/.ssh/${APP}_iran$idx
 mkdir -p /root/.ssh; chmod 700 /root/.ssh; [[ -f $key ]] || ssh-keygen -q -t ed25519 -N '' -f "$key"
 echo "=== PUBLIC KEY ==="; cat "$key.pub"; echo "Add it on Iran with menu 2."; read -r -p "Press Enter after authorization..." _
 ssh-keyscan -H "$ip" >"$known" 2>/dev/null; chmod 600 "$known"
 for j in 1 2 3 4; do
  p=$((base+j)); svc=$SD/${APP}-f${idx}-lane$j.service; backup "$svc"
  cat >"$svc" <<EOF
[Unit]
Description=StarSpeed Reverse SSH F$idx Lane$j
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/bin/ssh -NT -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes -o Compression=no -o IPQoS=throughput -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known -i $key -R 127.0.0.1:$p:127.0.0.1:$inb root@$ip
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
 done
 systemctl daemon-reload
 for j in 1 2 3 4; do systemctl enable --now ${APP}-f${idx}-lane$j.service; done
 sleep 2; for j in 1 2 3 4; do printf "lane$j: "; systemctl is-active ${APP}-f${idx}-lane$j.service || true; done
}

status(){
 echo "=== HAProxy ==="; systemctl is-active haproxy 2>/dev/null || true
 [[ -f $HC ]] && haproxy -c -f "$HC" 2>/dev/null || true
 echo "=== Tunnel services ==="; systemctl list-units --type=service --all "$APP-*" --no-pager 2>/dev/null || true
 echo "=== Relevant listeners ==="; ss -lntp | grep -E ':(45[0-9]{3}|46[0-9]{3})\b' || true
}

remove(){
 local i j; ask i "Foreign number to remove (1/2)"
 for j in 1 2 3 4; do systemctl disable --now ${APP}-f${i}-lane$j.service 2>/dev/null || true; rm -f $SD/${APP}-f${i}-lane$j.service; done
 systemctl daemon-reload; echo "Reverse SSH services removed; Xray unchanged."
}

while :; do
 echo; echo "StarSpeed Multi-Lane Tunnel"
 echo "1) Setup Iran (1 or 2 Foreign)"
 echo "2) Authorize Foreign public key (Iran)"
 echo "3) Setup Foreign"
 echo "4) Status"
 echo "5) Remove Foreign tunnel services"
 echo "0) Exit"
 read -r -p "Select: " c
 case $c in 1) iran;;2) auth;;3) foreign;;4) status;;5) remove;;0) exit;;*) echo "Invalid";; esac
done
