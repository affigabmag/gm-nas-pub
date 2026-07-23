# gm-nas-pub

Public files for the [gm-nas](https://github.com/affigabmag/gm-nas) home NAS
appliance: the autoinstall seed, the `gmnas` control menu + its helper
scripts, the WiFi setup portal, and the post-setup welcome web app. Public
because the offline install flow fetches some of these over plain HTTP, and
because none of it is sensitive (see below).

## ⚠️ Public repo — no secrets

These files are world-readable. They contain **only**:
- an SSH **public** key (safe to publish)
- non-sensitive install/service config

Never commit passwords, password hashes, Tailscale authkeys, or private keys here.

## How install actually works (offline-first)

1. **Boot a Ventoy USB** carrying the Ubuntu Server ISO + an autoinstall seed
   (built from `user-data` in the private `gm-nas` repo's `cidata-seed/`,
   using `release.sh`). The offline install runs with **zero network** —
   `network: ethernets: {}` deliberately brings up no interfaces, so a flaky
   WiFi/tether can't abort the install. Everything needed offline (the
   `gmnas` menu + helper scripts below) is embedded in the seed as a base64
   tarball and unpacked into the installed system directly — no network
   fetch during install at all.
2. First boot drops into the **`gmnas` control menu** (auto-launched on
   console login). From there: join WiFi, then **Resume install** — this is
   the point where `gm-install-all.sh` actually reaches out to the internet,
   installing the rest of the packages (Samba, Cockpit, NFS, ttyd,
   NetworkManager, `lynx`, `dialog`) and fetching this repo's other
   files (welcome app, WiFi setup portal, systemd units) fresh from GitHub.
3. **First-time wizard** (menu item `h`, or the one-shot `u` "Auto-complete
   install") broadcasts a `GMNas-Setup` WiFi AP; connecting a phone opens a
   captive portal (`ui/index.html`) to pick the box's permanent home WiFi.
4. Once on home WiFi, the box's **welcome app** (`welcome/app.py`, served on
   `http://<hostname>.local`) handles account creation, file shares, and
   installing Cockpit / Tailscale / Syncthing.

## Files

| Path | Purpose |
|---|---|
| `user-data`, `meta-data` | cloud-init autoinstall seed (public/production variant) |
| `gmnas.sh` | The `gmnas` control menu — arrow-key + letter-key navigable, most actions render inside a `dialog` box; a full all-dialog "Boxed menu" variant is also built in |
| `join-wifi.sh` | Joins WiFi; offline-capable (networkd + wpa_supplicant) before NetworkManager exists, prefers `nmcli` once it does |
| `gm-install-all.sh` | "Resume install" — the step that actually needs internet: installs the rest of the packages + fetches the welcome app / WiFi portal / systemd units |
| `gm-resume-usb.sh` | Same, over a phone USB tether instead of WiFi |
| `gm-update.sh` | Refreshes the helper scripts from GitHub without reinstalling |
| `gm-usb.sh` | Mount a USB drive / apply edits from the Ventoy pen |
| `gm-benchmark.sh` | Quick CPU/RAM/disk score ("Windows/Linux Experience Index" style) |
| `reset-setup.sh`, `factory-reset.sh` | Replay the first-boot WiFi/wizard flow (reset-setup keeps the account+shares; factory-reset wipes them too) |
| `save-fail-log.sh` | Run from a shell during a **failed** offline install (before it retries) — saves `/var/log/installer`, `journalctl`, `dmesg` onto the Ventoy USB, since the installer's own logs live in the wiped-every-attempt live environment |
| `ui/` | The `GMNas-Setup` captive-portal WiFi setup page (served by `wifi-connect`) |
| `welcome/app.py` | Post-setup web app: admin account, Samba shares, Cockpit/Tailscale/Syncthing installs |
| `files/` | systemd unit files fetched by `gm-install-all.sh` |

## Full docs

Design + build docs, session changelogs, and the offline-install architecture
live in the private [gm-nas](https://github.com/affigabmag/gm-nas) repo
(`doc/`).
