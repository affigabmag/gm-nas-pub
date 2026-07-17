# gm-nas-pub

Public autoinstall **seed** for the [gm-nas](https://github.com/affigabmag/gm-nas)
home NAS appliance. This repo exists only so Ubuntu's installer can fetch the
seed over plain HTTP at build time.

## ⚠️ Public repo — no secrets

These files are world-readable. They contain **only**:
- an SSH **public** key (safe to publish)
- non-sensitive install config

Never commit passwords, password hashes, Tailscale authkeys, or private keys here.

## Files

| File | Purpose |
|---|---|
| `user-data` | Ubuntu 24.04 autoinstall config (disk, user, packages, post-install) |
| `meta-data` | cloud-init instance metadata (near-empty, required by nocloud) |

## How it's used

Boot the Ubuntu Server 24.04 install USB, then at the GRUB menu press `e` and
append to the `linux` line:

```
autoinstall ds=nocloud-net;s=https://raw.githubusercontent.com/affigabmag/gm-nas-pub/main/
```

The installer fetches `user-data` + `meta-data` from the raw URL and runs
unattended (Ethernet required for internet access during install).

Full design + build docs live in the private [gm-nas](https://github.com/affigabmag/gm-nas) repo.
