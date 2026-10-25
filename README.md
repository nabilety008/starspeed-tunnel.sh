English | [فارسی](README.fa.md)

# StarSpeed Tunnel

Safe, interactive multi-lane reverse-SSH tunneling through an Iran server for
existing Xray/3x-ui inbounds. The tool manages HAProxy, SSH lanes and systemd
units; it does not modify Xray/3x-ui.

## Key features

- Four independent reverse-SSH lanes per foreign server.
- HAProxy round-robin balancing and lane failover.
- Guided setup for one Iran server and up to two foreign servers.
- Validation and timestamped backups before HAProxy changes.
- Idempotent setup, repair and removal.
- Strict SSH host-key checking and secret-free setup codes.
- Automatic key authorization, lane startup and bounded readiness checks.
- English-only CLI for consistent SSH terminal rendering.

## Quick Install / Run

### Install & Run (curl — Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/install.sh | sudo bash
```

### Install & Run (wget — Alternative)

```bash
wget -qO- https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/install.sh | sudo bash
```

### Run Only (Already Installed)

```bash
sudo /usr/local/sbin/starspeed-tunnel
```

The installer validates the complete download and atomically installs it at
`/usr/local/sbin/starspeed-tunnel`. Reinstallation updates only the executable;
configuration under `/etc/starspeed-tunnel` is preserved.

## Supported operating systems

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Ubuntu 26.04 LTS

Required components are Bash, systemd, OpenSSH and HAProxy. Missing runtime
packages can be installed through APT. The tool does not alter UFW, nftables or
iptables rules.

## How it works

```text
Client -> Iran public frontend -> HAProxy -> 4 reverse-SSH lanes
       -> Foreign server -> existing Xray inbound
```

The Iran server owns the public frontend and lane allocation. Each foreign
server owns its SSH key, pinned Iran host key, four systemd units and Xray
destination. Foreign servers remain isolated from one another.

## Configuration guide

1. On Iran, select `1) Setup Iran Server`, enter the public frontend and
   existing foreign Xray port, confirm, then copy the generated setup code.
2. Verify the Iran SSH host-key fingerprint through a trusted channel. The
   foreign server can use an already-authorized `ssh-agent`/key, an identity set
   with `SST_ADMIN_IDENTITY`, or one secure one-time OpenSSH password prompt.
3. Select `2) Setup Foreign Server`, paste the setup code and trusted SHA256
   fingerprint, then confirm. The tool authorizes its dedicated restricted key,
   starts only that node's lanes, and verifies the reverse listeners, HAProxy,
   frontend and TCP path automatically. WebSocket is also probed when detected.
4. `Tunnel Ready` is printed only after all required checks pass. Menu option
   `3` remains available solely for advanced recovery.

The Xray inbound must already exist and be listening. Setup codes contain port
allocation only—never credentials or private keys.

## Advanced usage

| Menu | Action |
| --- | --- |
| `1` | Configure the Iran frontend and HAProxy lanes |
| `2` | Configure a foreign server from a setup code |
| `3` | Authorize a foreign SSH public key on Iran |
| `4` | Show read-only tunnel status |
| `5` | Diagnose first, then offer scoped repairs |
| `6` | Remove one foreign tunnel |
| `7` | Show built-in help |
| `8` | Show language compatibility information |
| `9` | Remove only StarSpeed-managed files |

Useful options:

```bash
sudo /usr/local/sbin/starspeed-tunnel --status
sudo /usr/local/sbin/starspeed-tunnel --setup-code 1
sudo /usr/local/sbin/starspeed-tunnel --role
sudo /usr/local/sbin/starspeed-tunnel --help
```

The CLI is English-only. `--lang en` works normally; `--lang fa` remains
accepted for backward compatibility, prints an English notice and opens the
English menu.

Managed files are stored under `/etc/starspeed-tunnel`; lane units are named
`starspeed-tunnel-f<N>-lane<M>.service`. Foreign SSH material is stored in
`/root/.ssh/starspeed-tunnel_*`. Xray/3x-ui configuration remains read-only.

## Troubleshooting

1. Run menu option `4) Tunnel Status`.
2. Validate HAProxy if its service or frontend is down:

   ```bash
   sudo haproxy -c -f /etc/haproxy/haproxy.cfg
   ```

3. Use menu option `5) Diagnose & Repair` to rebuild managed fragments or units
   from saved state, or restore a known-good backup.

Common causes:

- `nothing is listening on 127.0.0.1:<port>`: the foreign Xray inbound is not
  listening; StarSpeed does not create or alter it.
- `Lane N: DOWN`: inspect the corresponding foreign systemd lane service.
- `host key not pinned`: verify the displayed SHA256 fingerprint out of band;
  unknown or changed keys are never accepted automatically.
- `automatic SSH authorization failed`: load an existing Iran administrative
  key into `ssh-agent`, run once with `SST_ADMIN_IDENTITY=/secure/key/path`, or
  use the one-time password prompt. The credential is never stored.

Tests run in disposable sandboxes:

```bash
bash tests/run-tests.sh
bash tests/syntax-check.sh
```

## License

MIT — see [LICENSE](LICENSE).
