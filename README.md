English | [فارسی](README.fa.md)

# starspeed-tunnel

Interactive installer for a **multi-lane reverse-SSH tunnel** through an Iran
server, designed to carry Xray/3x-ui traffic to one or two foreign servers
without touching the Xray/3x-ui configuration itself.

```
Client -> Iran public frontend port -> HAProxy -> 4 local reverse-SSH lanes
       -> Foreign server -> existing Xray inbound
```

Each foreign server gets **four independent reverse-SSH lanes**. HAProxy
round-robins across them, so a single stalled lane does not take the tunnel
down. Foreign #1 and Foreign #2 are completely independent: separate frontend,
separate Xray destination, separate lane block, separate SSH key, separate
`known_hosts`, separate saved state and separate systemd units.

## What this script will not do

This tool **only ever reads** Xray / 3x-ui state.

* It never creates, edits or deletes an Xray inbound.
* It never touches an existing `Direct` config.
* It never generates fake speed, shapes traffic, or adds artificial delay.
* It never disables host-key checking.

Your existing Xray inbound must already exist and already be listening; the
installer verifies it and refuses to continue otherwise.

## Requirements

Ubuntu 22.04 / 24.04 with `systemd`, OpenSSH client, and HAProxy. The installer
offers to install missing packages via `apt-get`.

Two hosts are involved:

| Host    | Role     | Needs                                    |
| ------- | -------- | ---------------------------------------- |
| Iran    | frontend | public IP, HAProxy, OpenSSH server        |
| Foreign | backend  | OpenSSH client, an existing Xray inbound  |

## Download

Run on the server you are configuring. The explicit `-o` form is used so the
output filename is never derived from the URL path:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/starspeed-tunnel.sh -o starspeed-tunnel.sh
chmod +x starspeed-tunnel.sh
./starspeed-tunnel.sh
```

One-line alternative:

```bash
curl -fsSL https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/starspeed-tunnel.sh -o /root/starspeed-tunnel.sh && chmod +x /root/starspeed-tunnel.sh && /root/starspeed-tunnel.sh
```

To update an existing copy later, re-run the same command and re-apply the
executable bit:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/starspeed-tunnel.sh -o starspeed-tunnel.sh
chmod +x starspeed-tunnel.sh
```

## Usage

```bash
sudo ./starspeed-tunnel.sh            # interactive menu
sudo ./starspeed-tunnel.sh --status   # status only, no changes
sudo ./starspeed-tunnel.sh --setup-code 1
sudo ./starspeed-tunnel.sh --role
sudo ./starspeed-tunnel.sh --version
sudo ./starspeed-tunnel.sh --help     # full option list
```

### 1. On the Iran server

Run the script and choose **`1) Setup Iran`**. It asks how many foreign servers
will tunnel through Iran, then for each one:

* a public frontend port on Iran (the port your clients connect to), and
* the Xray inbound port on the foreign server (the lane target).

It allocates a block of four free lane ports per foreign, generates the HAProxy
fragments, validates the candidate configuration with `haproxy -c`, backs up
the live config, and only then activates it. At the end it prints a **setup
code** for each foreign.

Your clients then connect to the **frontend port** on Iran.

### 2. On each foreign server

Run the script and choose **`2) Add / Setup Foreign`**. Paste:

* the Iran IP address,
* the foreign number that matches Iran,
* the Xray inbound port that already exists on this host,
* the setup code from Iran.

The foreign side generates its own SSH keypair, pins the Iran host key via
`ssh-keyscan`, and installs four hardened systemd units
(`starspeed-tunnel-f<N>-lane<M>.service`). It never prompts for a password:
`BatchMode=yes`, `ExitOnForwardFailure=yes`, `ServerAliveInterval` and
`ServerAliveCountMax` are all set.

### 3. Back on Iran

The foreign prints its SSH **public** key. Choose **`3) Authorize Foreign
Public Key`** on Iran and paste it.

The private key never leaves the foreign server.

### Menu reference

| Option | Action |
| ------ | ------ |
| `1` | Setup Iran - allocate frontends/lanes and write HAProxy config |
| `2` | Add / Setup Foreign - runs on the foreign server |
| `3` | Authorize Foreign Public Key - runs on Iran |
| `4` | Status - lanes, frontends, HAProxy health |
| `5` | Repair - rebuild missing fragments/units from saved state |
| `6` | Remove Foreign - remove one foreign only |
| `7` | Uninstall - remove only starspeed-managed files |
| `0` | Exit |

## Safety properties

* **HAProxy is validated before activation.** A candidate config is written to
  a temporary file and checked with `haproxy -c`. If it fails, the live config
  is left untouched and the previous working configuration is kept.
* **Backups before every rewrite.** Prior copies are kept under
  `/etc/starspeed-tunnel/backups`.
* **Your own HAProxy config is preserved.** Only a single delimited managed
  block (`# >>> starspeed-tunnel managed includes >>>` /
  `# <<< starspeed-tunnel managed includes <<<`) is written, replaced or
  stripped. Everything outside it is yours, and re-running is byte-stable.
* **Strict host-key checking stays on.** Each foreign pins the Iran host key in
  its own `known_hosts` file.
* **Setup codes carry no secrets.** They are base64 text containing only the
  allocation (index, frontend, lanes, SSH port).
* **State files are data, never code.** Values are validated before use and
  never `eval`'d or expanded as commands.
* **Idempotent.** Re-running setup, repair or uninstall converges rather than
  duplicating units or includes.

## Files it manages

```
/etc/starspeed-tunnel/
  state/foreign-N.env        per-foreign saved state
  state/role                 iran | foreign
  haproxy/foreign-N.cfg      per-foreign HAProxy fragment
  backups/                   timestamped backups
/etc/systemd/system/starspeed-tunnel-f<N>-lane<M>.service
/root/.ssh/starspeed-tunnel_f<N>        private key (foreign only)
/root/.ssh/starspeed-tunnel_f<N>.pub    public key (foreign only)
/root/.ssh/starspeed-tunnel_iran<N>    pinned Iran host key (foreign only)
```

## Uninstall

Option `7` removes only files this project created: the systemd lane units,
the saved state, the generated HAProxy fragments, and the managed include block
inside `haproxy.cfg`. Unrelated HAProxy configuration, and anything belonging to
Xray / 3x-ui, is left alone. The SSH keypair is kept by default.

## Tests

The test suite runs entirely against disposable sandboxes with fake `systemctl`,
`ss`, `haproxy` and `ssh-keyscan`. It never touches a real `/etc`, real systemd,
a real HAProxy, the network, or SSH.

```bash
bash tests/run-tests.sh          # everything
bash tests/run-tests.sh unit     # validation/allocation/state only
bash tests/syntax-check.sh       # bash -n over every shell file
```

## Troubleshooting

Run **`4) Status`** first. It reports, per foreign, the frontend, the Xray
destination, each lane, and HAProxy health without printing any secret.

If HAProxy will not start, validate manually:

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```

Option **`5) Repair`** rebuilds a deleted fragment or unit from saved state, and
offers to restore the last known-good backup when the live config no longer
validates.

<a id="support-starspeed-tunnel"></a>

## ❤️ Support starspeed-tunnel

If starspeed-tunnel is useful to you and you'd like to support its continued
development, you can help support future improvements, maintenance, testing,
and releases.

### 🇮🇷 Support from Iran

[Support starspeed-tunnel on Daramet](https://daramet.com/nabilety)

[Support starspeed-tunnel on HamiBash](https://hamibash.com/nabilety008)
### 🌍 International Support

**USDT — BNB Smart Chain (BEP20)**

`0x3A09DAc6A09A3760F063EBfBF6D523737BD498A5`

**USDT — TRON (TRC20)**

`TEmsoP2M9gZBymrc73z8NXdcy4LK2Qzkig`

> Please verify both the wallet address and selected network before sending.
> Cryptocurrency transactions may be irreversible.

## License

MIT. See [LICENSE](LICENSE).
