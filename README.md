English | [فارسی](README.fa.md)

# StarSpeed Tunnel

Interactive installer for a **multi-lane reverse-SSH tunnel** through an Iran
server, designed to carry Xray/3x-ui traffic from one or two foreign servers
without ever touching the Xray/3x-ui configuration itself.

```
Client -> Iran public frontend port -> HAProxy -> 4 local reverse-SSH lanes
       -> Foreign server -> existing Xray inbound
```

Each foreign server gets **four independent reverse-SSH lanes**. HAProxy
round-robins across them, so a single stalled lane cannot take the tunnel down.
Foreign #1 and Foreign #2 are fully independent: separate frontend, separate
Xray destination, separate lane block, separate SSH key, separate `known_hosts`,
separate saved state and separate systemd units.

Version 1.1.0 adds a fully bilingual menu (English / Persian), step-by-step
setup wizards with a confirmation summary before anything is applied, an
at-a-glance status header, and a read-only-first diagnose & repair flow.

## 1. Features

* **Two guided wizards** - one for the Iran side, one for each foreign server.
* **Bilingual interface** - English and Persian (Farsi), switchable at runtime.
* **Setup codes** - a short base64 string carries each foreign's allocation; no
  secrets inside.
* **Four reverse-SSH lanes per foreign** with HAProxy round-robin failover.
* **Safe by construction** - candidate HAProxy config is validated with
  `haproxy -c` before activation; the live config is backed up first.
* **Idempotent** - re-running setup, repair or uninstall converges instead of
  duplicating units or config blocks.
* **Honest status** - per-foreign frontend, Xray destination, every lane, and
  HAProxy health, with no secret ever printed.
* **Read-only diagnostics first** - repair reports what is wrong before it asks
  permission to change anything.

## 2. Architecture

```
+---------+   public      +----------+  reverse SSH   +-----------+
| Client  | --> :FRONTEND |  Iran    | ==== LANE1..4=> |  Foreign  |
+---------+               |  HAProxy |= round robin == |  Xray in  |
                          +----------+                +-----------+
```

* The client connects to a **public frontend port on Iran**.
* HAProxy balances that frontend across **four reverse-SSH lanes**.
* Each lane is an `ssh -R` forward from the foreign server back into Iran.
* The foreign server forwards the lane to its **existing local Xray inbound**.

The lockstep is deliberate: Iran owns the public port and the lane allocation;
the foreign server owns the SSH key and the Xray destination.

## 3. Requirements

Ubuntu 22.04 / 24.04 with `systemd`, the OpenSSH client, and HAProxy. The
installer offers to install missing packages via `apt-get`.

| Host    | Role     | Needs                                     |
| ------- | -------- | ----------------------------------------- |
| Iran    | frontend | public IP, HAProxy, OpenSSH server         |
| Foreign | backend  | OpenSSH client, an existing Xray inbound   |

## 4. Install / Download

Run on the server you are configuring. The explicit `-o` form is used so the
output filename is never derived from the URL path:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/starspeed-tunnel.sh -o starspeed-tunnel.sh
chmod +x starspeed-tunnel.sh
./starspeed-tunnel.sh
```

To update an existing copy later, re-run the same command and re-apply the
executable bit.

## 5. Quick start

Three short steps, in this order:

1. **On Iran** choose `1) Setup Iran Server`, tell it how many foreign servers
   there are, then confirm the summary. Copy each printed **setup code**.
2. **On each foreign server** choose `2) Setup Foreign Server`, paste the setup
   code, then type the Iran address. The foreign prints its SSH public key.
3. **Back on Iran** choose `3) Authorize Foreign SSH Key` and paste that public
   key. The tunnel is now live.

## 6. Iran server setup

Choose **`1) Setup Iran Server`**. The wizard:

* shows any existing configuration and reuses its port allocation unchanged;
* asks how many foreign servers will tunnel through Iran (1 or 2);
* for each **new** foreign, asks a public frontend port on Iran and the Xray
  inbound port used on that foreign server;
* allocates a block of four free lane ports per foreign;
* prints a **configuration summary** and asks you to confirm it;
* only after confirmation does it write state, render the fragments, validate
  the whole candidate with `haproxy -c`, back up the live config, and reload.

If you decline the confirmation, nothing is written and nothing changes.

Your clients then connect to the **frontend port** on Iran.

## 7. Foreign server setup

Choose **`2) Setup Foreign Server`**. The wizard is **code-first**:

* paste the **setup code** from Iran; the foreign index, frontend and lane
  allocation are read straight from it;
* if this host is already configured you may keep the existing setup or
  overwrite it (a declined overwrite changes nothing);
* type the **Iran address** (the code does not carry it);
* confirm the summary to apply.

The foreign side then generates its own SSH keypair, pins the Iran host key via
`ssh-keyscan`, and installs four hardened systemd units named
`starspeed-tunnel-f<N>-lane<M>.service`. It never prompts for a password:
`BatchMode=yes`, `ExitOnForwardFailure=yes`, `ServerAliveInterval` and
`ServerAliveCountMax` are all set.

## 8. Authorize the SSH key

The foreign server prints its SSH **public** key. On Iran choose
**`3) Authorize Foreign SSH Key`** and paste it (or `q` to finish).

The private key never leaves the foreign server.

## 9. Status

Choose **`4) Tunnel Status`**, or run `--status` for a non-interactive report.
The header shows your role, the number of configured foreigns, and HAProxy (on
Iran) or the count of running lanes (on a foreign). Per foreign you get:

* the frontend port and Xray destination;
* the state of every lane;
* HAProxy health and config validity (on Iran);
* SSH authorized-key count on Iran, or Iran host-key presence on a foreign.

Status is **read-only** and never prints private key material. It also surfaces
the last few errors from the install log, if any.

## 10. Diagnose & repair

Choose **`5) Diagnose & Repair`**. It runs **read-only checks first** and lists
what it proposes to change; nothing is modified until you confirm each step. It
can:

* remove a broken state file (with confirmation);
* rebuild a missing fragment or unit from saved state;
* restore the last known-good HAProxy backup when the live config no longer
  validates;
* rebind a frontend that is not listening.

## 11. Removing a foreign and uninstalling

* **`6) Remove Foreign Tunnel`** removes a single foreign: its state, fragment,
  lane units and managed block section. Other foreigns are untouched.
* **`9) Uninstall`** removes only files this project created - the lane units,
  saved state, generated fragments and the managed block inside `haproxy.cfg`.
  Unrelated HAProxy configuration and anything belonging to Xray / 3x-ui are
  left alone. The SSH keypair is kept by default.

## 12. Menu reference

| Option | Action |
| ------ | ------ |
| `1` | Setup Iran Server - allocate frontends/lanes and write HAProxy config |
| `2` | Setup Foreign Server - runs on the foreign server (code-first) |
| `3` | Authorize Foreign SSH Key - runs on Iran |
| `4` | Tunnel Status - lanes, frontends, HAProxy health |
| `5` | Diagnose & Repair - read-only checks first, then repair |
| `6` | Remove Foreign Tunnel - remove one foreign only |
| `7` | Help & Documentation - architecture, ports, setup codes |
| `8` | Settings & Language - choose English or Persian |
| `9` | Uninstall - remove only StarSpeed-managed files |
| `0` | Exit |

Command-line options:

```bash
sudo ./starspeed-tunnel.sh            # interactive menu
sudo ./starspeed-tunnel.sh --status   # status only, no changes
sudo ./starspeed-tunnel.sh --setup-code 1
sudo ./starspeed-tunnel.sh --role
sudo ./starspeed-tunnel.sh --lang fa  # set display language
sudo ./starspeed-tunnel.sh --version
sudo ./starspeed-tunnel.sh --help     # full option list
```

## 13. Language

The interface ships in **English** and **Persian**. Priority at startup:

1. the `SST_LANG` environment variable (`en` or `fa`);
2. the saved setting in `/etc/starspeed-tunnel/lang`;
3. the system locale (`LC_ALL` / `LANG`, matching `fa*`).

Switch languages any time from **`8) Settings & Language`**, or with
`--lang en|fa`. Menu, wizard, status, help and settings labels are translated;
low-level diagnostic messages stay in English so logs and support remain
consistent.

## 14. Safety properties

* **HAProxy is validated before activation.** A candidate config is checked with
  `haproxy -c`; if it fails, the live config is left untouched.
* **Backups before every rewrite** under `/etc/starspeed-tunnel/backups`.
* **Your own HAProxy config is preserved.** Only a single delimited managed
  block (`# >>> starspeed-tunnel managed includes >>>` /
  `# <<< starspeed-tunnel managed includes <<<`) is written, replaced or
  stripped. Re-running is byte-stable.
* **Strict host-key checking stays on.** Each foreign pins the Iran host key in
  its own `known_hosts`.
* **Setup codes carry no secrets** - only the allocation (index, frontend,
  lanes, SSH port).
* **State files are data, never code.** Values are validated and never `eval`'d.
* **Xray / 3x-ui are read-only** - the tool never creates, edits or deletes an
  inbound, never disables host-key checking, and adds no traffic shaping or
  artificial delay.

## 15. Files, tests, troubleshooting and license

**Files it manages**

```
/etc/starspeed-tunnel/
  state/foreign-N.env        per-foreign saved state
  state/role                 iran | foreign
  lang                       saved display language
  haproxy/foreign-N.cfg      per-foreign HAProxy fragment
  backups/                   timestamped backups
  install.log                log file
/etc/systemd/system/starspeed-tunnel-f<N>-lane<M>.service
/root/.ssh/starspeed-tunnel_f<N>        private key (foreign only)
/root/.ssh/starspeed-tunnel_f<N>.pub    public key (foreign only)
/root/.ssh/starspeed-tunnel_iran<N>    pinned Iran host key (foreign only)
```

**Tests** - the suite runs against disposable sandboxes with fake `systemctl`,
`ss`, `haproxy` and `ssh-keyscan`. It never touches a real `/etc`, real
systemd, a real HAProxy, the network or SSH.

```bash
bash tests/run-tests.sh          # everything
bash tests/run-tests.sh unit     # validation/allocation/state only
bash tests/syntax-check.sh       # bash -n over every shell file
```

**Troubleshooting** - run **`4) Tunnel Status`** first. If HAProxy will not
start, validate manually:

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```

Then run **`5) Diagnose & Repair`** to rebuild a deleted fragment or unit from
saved state, or restore the last known-good backup.

**License** - MIT. See [LICENSE](LICENSE).

<a id="support-starspeed-tunnel"></a>

## ❤️ Support StarSpeed Tunnel

If StarSpeed Tunnel is useful to you and you'd like to support its continued
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
