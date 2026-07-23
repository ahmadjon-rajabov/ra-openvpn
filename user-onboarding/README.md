# User Onboarding RA-OpenVPN

Setup instructions for connecting to **ra-openvpn** from Windows, macOS, or Linux.

> **Prerequisite for all platforms:** you must be connected to **eduVPN** before connecting to ra-openvpn. The ra-openvpn server is only reachable through the TU Dresden network.

---

## What files do you need?

> Your personal **`<yourname>.ovpn`** file will be sent to you separately by
the administrator through a secure channel (do not share it —
it contains your private key).

Beyond that, what you download from this folder depends on your OS:

| Platform     | Files to download from this folder                             |
|--------------|----------------------------------------------------------------|
| **Windows**  | *(nothing — your `.ovpn` file is enough)*                      |
| **macOS**    | *(nothing — your `.ovpn` file is enough)*                      |
| **Linux**    | `ra-nm-import.sh`, `ra-nm-cleanup.sh`, `90-ra-openvpn-route`   |
| **Linux**    | `ra-diagnose.sh` — only if you're asked to send diagnostics    |

---

## Reference: what each file does

| File                     | Platform    | Purpose                                                                                       |
|--------------------------|-------------|-----------------------------------------------------------------------------------------------|
| `<yourname>.ovpn`        | All         | Your personal ra-openvpn configuration and embedded keys. Issued by the administrator.        |
| `ra-nm-import.sh`        | Linux only  | One-time setup script: imports your `.ovpn` into NetworkManager and installs a route helper.  |
| `ra-nm-cleanup.sh`       | Linux only  | Undoes everything `ra-nm-import.sh` did. Use when removing ra-openvpn from your laptop.       |
| `90-ra-openvpn-route`    | Linux only  | NetworkManager dispatcher script installed by `ra-nm-import.sh`. Not run directly.            |
| `ra-diagnose.sh`         | Linux/macOS | Diagnostic tool. Run only when troubleshooting a broken connection to share output with the admin. |
| `README.md`              | All         | This document.                                                                                |

Windows users need only their `.ovpn` file. macOS users need the `.ovpn` and,
if troubleshooting, `ra-diagnose.sh`. Linux users need all four scripts.

---

## Windows

### One-time setup

1. Install **[OpenVPN Connect](https://openvpn.net/client/)** (the official
   Windows client) if not already installed.
2. Connect to **[eduVPN](https://www.eduvpn.org/client-apps/)** first (via the eduVPN Windows client).
3. Open OpenVPN Connect → **File** tab → drag & drop `<yourname>.ovpn` onto
   the window, or click **Browse** and select it.
4. Click **Connect** (toggle switch).

### Daily use

1. Connect **eduVPN**.
2. Open OpenVPN Connect → toggle **`<yourname>`** on.

### Verify

Open PowerShell:

```powershell
ping 192.168.5.1
ping 192.168.7.1
```

---

## macOS

### One-time setup

1. Install **[Tunnelblick](https://tunnelblick.net/)** (free, open-source OpenVPN client for macOS) or **[OpenVPN Connect](https://openvpn.net/client/)**.
2. Connect to **[eduVPN](https://www.eduvpn.org/client-apps/)** first (via the eduVPN macOS client).
3. Double-click `<yourname>.ovpn` — Tunnelblick will offer to install it. Choose Only Me unless you need multi-user access.
4. Click the Tunnelblick menu-bar icon → **Connect `<yourname>`**.

### Daily use

1. Connect **eduVPN**.
2. Tunnelblick/OpenVPN Connect menu-bar icon → **Connect `<yourname>`**.

### Verify

Open Terminal:

```bash
### Verify
ping -c 3 192.168.5.1
ping -c 3 192.168.7.1
```

---

## Linux 

Linux needs one extra setup step because NetworkManager's OpenVPN plugin does not, by default, correctly handle the routing when eduVPN is stacked underneath. The `ra-nm-import.sh` script fixes this automatically.

### Prerequisites (most users can skip)

- Ubuntu with GNOME + NetworkManager (default installation).
- The GNOME OpenVPN plugin for NetworkManager:
  ```bash
  sudo apt install network-manager-openvpn-gnome
  ```

### One-time setup

1. Connect to **[eduVPN](https://www.eduvpn.org/client-apps/)** first
2. **Download the three Linux scripts** into a new folder:
   - `ra-nm-import.sh`
   - `ra-nm-cleanup.sh`
   - `90-ra-openvpn-route`
3. Place your `<yourname>.ovpn`** in the same folder.
4. Open a terminal in new folder and run:

```bash
sudo ./ra-nm-import.sh ./<yourname>.ovpn
```

Expected output:

```bash
Connection '<yourname>' (…) successfully added.
Route to <server-ip> installed via <gateway> on tun0.
Imported NM connection '<yourname>'.
Wrote config      /etc/ra-openvpn/client.env
Installed dispatcher /etc/NetworkManager/dispatcher.d/90-ra-openvpn-route
   Toggle the VPN on from the Network menu.
```

### Daily use

1. Ensure **eduVPN** is connected (top-right network menu → toggle on).
2. Open **VPN Connections** → toggle **`<yourname>`** on.
4. To disconnect, toggle it off in the same menu.

### Verify

Open Terminal:

```bash
ping -c 3 192.168.5.1
ping -c 3 192.168.7.1
```

---

## What was installed on your system 

| Path | Removed by cleanup? |
|----|-------------------------------------------------------|
| NetworkManager connection profile `<yourname>`    |    ✅  |
| `/etc/ra-openvpn/client.env`                      |    ✅  |
| `/etc/NetworkManager/dispatcher.d/90-ra-openvpn-route`|✅  |
| A `/32` route to the ra-openvpn server via `tun0` |    ✅  |

> Nothing else is changed. eduVPN's configuration, system DNS, firewall rules, and default routes are all untouched.

## Uninstall

```bash
sudo ./ra-nm-cleanup.sh ./<yourname>.ovpn
```

or, if you no longer have the .ovpn file:

```bash
sudo ./ra-nm-cleanup.sh <yourname>
```

## Troubleshooting

### Quick checklist (all platforms)

1. Is **eduVPN** connected? ra-openvpn requires it.
2. Is your `.ovpn` file the **latest one** issued to you? Old files stop working after key rotation.
3. Is the ra-openvpn client actually connected (not just "trying")?

### Linux — VPN connects but no ping to lab subnets

```bash
ip route | grep 192.168     # should list 192.168.5/6/7.0/24 via tun1
ip route get 192.168.7.1    # should say "dev tun1"
```

> If missing or wrong, run `ra-nm-cleanup.sh` and re-run `ra-nm-import.sh`.

### Linux — VPN drops seconds after connecting

```bash
sudo journalctl -u NetworkManager -n 100 | grep -E 'policy|Connection reset'
```

> If you see policy: set `<yourname>` … as default for IPv4 routing, re-run the cleanup + import cycle.

### Anything weirder — capture diagnostics

The `ra-diagnose.sh` script takes a full state snapshot of your network configuration and OpenVPN state. Send the output file to the ra-openvpn administrator. Usage: 

```bash 
sudo bash ra-diagnose.sh <label>
```

Where `<label>` is a short descriptor of what state you're capturing. Recommended labels for a typical troubleshooting session:

| When to capture | Suggested label |
|---------------|---------------------------------------------------|
| Before doing anything (baseline) | `round1-before` |
| Right after ra-openvpn connects successfully | `round1-connected` |
| After you `Ctrl+C` or disconnect the VPN | `round1-after-disconnect` |
| Before your second connection attempt | `round2-before-retry` |
| When the second attempt fails | `round2-failed` |

Each run creates a timestamped file under `/tmp/ovpn-diag/`. Send the whole directory:

```bash
tar czf ovpn-diag-$(date +%Y%m%d).tar.gz /tmp/ovpn-diag/
```

Then email the resulting .tar.gz to the administrator.

## FAQ

**Q: Will these changes affect other VPNs or my network settings?** No. All changes are narrowly scoped: one new VPN profile, one /32 route to the ra-openvpn server, and (on Linux) one dispatcher script that only reacts to the eduVPN interface. System-wide DNS, default route, and firewall are untouched.

**Q: Do I need to run `ra-nm-import.sh` every time?** No. Once per laptop, then daily use is a GUI toggle.

**Q: The ra-openvpn server IP changed. What do I do?** Ask the administrator for a new `.ovpn`. On Linux, run `ra-nm-cleanup.sh` against the old file, then `ra-nm-import.sh` against the new one. On Windows/macOS, just re-import the new `.ovpn` into your client.

**Q: Can I use ra-openvpn from a Linux CLI instead of the GUI?** Yes: `sudo openvpn --config <yourname>.ovpn`. But `NetworkManager` works after one-time setup, so most users won't need the CLI.

**Q: I'm on Fedora / Arch / another Linux distro. Will ra-nm-import.sh work?** Officially tested on Ubuntu 22.04 and 24.04. Fedora and Arch use the same `NetworkManager` dispatcher layout, so it should work — but is not verified. Report issues to the administrator with **ra-diagnose.sh** output.