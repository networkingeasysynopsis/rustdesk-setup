# RustDesk Setup: One-Line Installer (Windows, Linux, macOS)

Installs RustDesk, points it at your **self-hosted server** (ID server, relay server, key), sets a **permanent password**, and prints the RustDesk ID, all with a single command.

---

##  Repository Structure

```
rustdesk-setup/
├── install.ps1   # Windows installer (PowerShell)
├── install.sh    # Linux + macOS installer (bash)
└── README.md     # This guide
```

| File | Platform | Run as |
|------|----------|--------|
| `install.ps1` | Windows 10 / 11 / Server | PowerShell **as Administrator** |
| `install.sh`  | Linux (Debian/Ubuntu, Fedora/RHEL) and macOS (Intel + Apple Silicon) | `sudo` |

---

##  Quick Start

### Windows

Open **PowerShell as Administrator** and run:

```powershell
irm https://raw.githubusercontent.com/networkingeasysynopsis/rustdesk-setup/main/install.ps1 | iex
```

### Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/networkingeasysynopsis/rustdesk-setup/main/install.sh | sudo bash
```

These commands use the GitHub account `networkingeasysynopsis`. If you move the repo, change the username in the links.

### What you will be asked

One question only:

```
Enter the number for the password (<prefix><number>):
```

Type digits only (for example `101`). The permanent password becomes **prefix + number**.
In `install.ps1` the prefix is `welcome@`, so `101` gives `welcome@101`.

> Keep the prefix **identical in both scripts** (`install.ps1` and `install.sh`), otherwise Windows and Linux/macOS machines will get different password styles.

---

##  Configuration (top of each script)

| Variable | Meaning | Default in script |
|----------|---------|-------------------|
| `IDServer` / `ID_SERVER` | Your hbbs (ID/rendezvous) server IP or domain | your server IP |
| `RelayServer` / `RELAY_SERVER` | Your hbbr (relay) server | same as ID server |
| `Key` / `KEY` | Public key of your server (`id_ed25519.pub`) | your server key |
| `PwPrefix` / `PW_PREFIX` | Fixed part of the permanent password | `welcome@` (Windows) |

Edit these only at the top of the file. Nothing else needs to change.

---

##  What `install.ps1` Does (Windows)

| Step | Action |
|------|--------|
| 1 | Forces TLS 1.2 for downloads |
| 2 | Checks that PowerShell is running as Administrator |
| 3 | Asks for the password number (digits only, fails early) |
| 4 | Looks for an existing install in `Program Files` |
| 5 | If missing: queries the GitHub API for the **latest** `rustdesk-*-x86_64.exe` |
| 6 | Downloads it to `%TEMP%`, checks size, verifies the **Authenticode signature** |
| 7 | Runs `--silent-install`, then deletes the installer |
| 8 | Installs and starts the **RustDesk Windows service** if missing |
| 9 | Stops RustDesk, writes `RustDesk2.toml` (ID server, relay, key) |
| 10 | Starts the service, sets the permanent password, reads the ID |
| 11 | Prints ID, password, servers and key |

Config is written to **two places**:

- `C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config` (used by the service, so unattended access works at the login screen)
- `%APPDATA%\RustDesk\config` (used by the logged-in user's UI)

---

##  What `install.sh` Does (Linux + macOS)

| Step | Linux | macOS |
|------|-------|-------|
| Root check | `sudo` required | `sudo` required |
| Password | Asks for number | Asks for number |
| Install | Downloads `.deb` (apt) or `.rpm` (dnf/yum) for your CPU | Downloads `.dmg`, copies `RustDesk.app` to `/Applications` |
| Config path | `~/.config/rustdesk/RustDesk2.toml` (root and the sudo user) | `~/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml` (root and the sudo user) |
| Service | `systemctl enable --now rustdesk` | App is launched |
| Password and ID | `rustdesk --password` and `--get-id` | same, via the app binary |

CPU types supported: `x86_64` and `arm64/aarch64`.

---

##  Verify After Installation

1. The script prints **ID** and **Password**. Note them down.
2. Open RustDesk. The bottom status should say **Ready**.
3. Open **Settings > Network (ID/Relay server)** and confirm the ID server, relay server and key match your values.
4. From another PC, enter the ID and the permanent password to connect.

Useful checks:

```powershell
# Windows
Get-Service RustDesk
```

```bash
# Linux
systemctl status rustdesk
```

---

##  Server Firewall Checklist

On the machine running hbbs/hbbr, open:

| Port | Protocol | Purpose |
|------|----------|---------|
| 21115 | TCP | NAT type test |
| 21116 | TCP + **UDP** | ID / rendezvous server |
| 21117 | TCP | Relay server |
| 21118 / 21119 | TCP | Web client (optional) |

If the client stays on "Connecting..." the cause is almost always a closed port or a wrong key.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `Run PowerShell as Administrator.` | Right-click PowerShell, then **Run as administrator** |
| `Installer signature is not valid` | Download was blocked or corrupted. Re-run, or check antivirus/proxy |
| `Could not find Windows installer in latest release` | GitHub rate-limited you or changed asset names. Wait and retry |
| `Could not read RustDesk ID` | Service not running yet. Run `Start-Service RustDesk`, wait 10 s, run the script again |
| Status stays "Not ready" | Wrong key/IP, or ports 21115-21117 blocked |
| Password not accepted | Check the prefix and number. Re-run the script to reset it |
| macOS: black screen / no control | Grant **Accessibility** and **Screen Recording** in System Settings > Privacy & Security (cannot be scripted) |
| Linux: no unattended access | Wayland limits RustDesk. Use an X11 session for best results |
| `curl` or `irm` blocked | Corporate proxy or firewall. Download the file manually and run it locally |

Running a downloaded script locally:

```powershell
# Windows (if execution policy blocks it)
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

```bash
# Linux / macOS
sudo bash install.sh
```

---

##  Updating the Scripts

1. Open the file on GitHub and click the **pencil** icon.
2. Change the value (server IP, key, prefix) and click **Commit changes**.
3. The one-line command always fetches the latest version from `main`.

---


##  Uninstall

**Windows**

```powershell
Stop-Service RustDesk
& "$env:ProgramFiles\RustDesk\rustdesk.exe" --uninstall
```

**Linux**

```bash
sudo apt remove rustdesk      # Debian/Ubuntu
sudo dnf remove rustdesk      # Fedora/RHEL
```

**macOS:** quit RustDesk and drag `RustDesk.app` from `/Applications` to the Trash.

---

