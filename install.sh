#!/usr/bin/env bash
# ==========================================================
# RustDesk installer + config (Linux & macOS)  -  v2
# Usage:  curl -fsSL <raw-url>/install.sh | sudo bash
# No-prompt mode:  curl -fsSL <raw-url>/install.sh | sudo RD_NUM=101 bash
# ==========================================================
set -euo pipefail

ID_SERVER="115.240.201.195"
RELAY_SERVER="115.240.201.195"
KEY="NymCTxtQz1kmrYxLH7IYe1uaheTPwsAwyvHU1VPOfx0="
PW_PREFIX="welcome@"

step() { printf '\n>>> %s\n' "$1"; }
die()  { printf '\nSETUP FAILED: %s\n' "$1" >&2; exit 1; }

# Run a command with a hard timeout so nothing can hang the script
run_to() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" ) >/dev/null 2>&1 &
  local watcher=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watcher" >/dev/null 2>&1 || true
  return "$rc"
}

[ "$(id -u)" -eq 0 ] || die "Run with sudo:  curl -fsSL <url> | sudo bash"

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ARCH="x86_64" ;;
  arm64|aarch64) ARCH="aarch64" ;;
  *) die "Unsupported architecture: $ARCH" ;;
esac

# ---------- Ask for the number first (fail early) ----------
step "Password setup"
NUM="${RD_NUM:-}"
if [ -z "$NUM" ]; then
  [ -r /dev/tty ] || die "No terminal available. Run with:  sudo RD_NUM=101 bash install.sh"
  while true; do
    read -r -p "Enter the number for the password (${PW_PREFIX}<number>): " NUM </dev/tty
    NUM="${NUM//[[:space:]]/}"
    [[ "$NUM" =~ ^[0-9]+$ ]] && break
    echo "Numbers only, please."
  done
fi
[[ "$NUM" =~ ^[0-9]+$ ]] || die "RD_NUM must contain digits only."
PASSWORD="${PW_PREFIX}${NUM}"

TOML="rendezvous_server = '${ID_SERVER}:21116'
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = '${ID_SERVER}'
relay-server = '${RELAY_SERVER}'
key = '${KEY}'
"

write_config() { # $1 = dir, $2 = owner (optional)
  mkdir -p "$1"
  printf '%s' "$TOML" > "$1/RustDesk2.toml"
  if [ -n "${2:-}" ]; then chown -R "$2" "$1" 2>/dev/null || true; fi
  echo "Config written: $1"
}

latest_asset_url() { # $1 = grep -E pattern
  curl -fsSL --connect-timeout 30 --max-time 60 \
    https://api.github.com/repos/rustdesk/rustdesk/releases/latest \
    | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 \
    | grep -E "$1" | grep -v -E 'sciter|suse' | head -n1 || true
}

download() { # $1 = url, $2 = output file
  curl -fL --retry 2 --connect-timeout 30 --max-time 600 "$1" -o "$2" \
    || die "Download failed: $1"
  [ "$(wc -c < "$2")" -gt 1000000 ] || die "Downloaded file looks invalid."
}

REAL_USER="${SUDO_USER:-}"
REAL_HOME=""
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
  REAL_HOME="$(eval echo "~$REAL_USER")"
else
  REAL_USER=""
fi

get_id() {
  local out id=""
  for i in 1 2 3 4 5 6; do
    out="$(run_to 20 "$RD" --get-id 2>/dev/null || true)"
    id="$(printf '%s\n' "$out" | grep -E '^[0-9]{6,}$' | head -n1 || true)"
    [ -n "$id" ] && break
    echo "  retry $i/6..." >&2
    sleep 4
  done
  printf '%s' "$id"
}

# ==================== LINUX ====================
if [ "$OS" = "Linux" ]; then
  RD="$(command -v rustdesk || true)"

  if [ -z "$RD" ]; then
    step "Installing RustDesk"
    TMP="$(mktemp -d)"
    if command -v apt-get >/dev/null 2>&1; then
      URL="$(latest_asset_url "${ARCH}\.deb$")"; [ -n "$URL" ] || die "No .deb found for $ARCH"
      download "$URL" "$TMP/rustdesk.deb"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y -o DPkg::Lock::Timeout=120 || true
      apt-get install -y -o DPkg::Lock::Timeout=120 "$TMP/rustdesk.deb" || die "apt install failed."
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
      URL="$(latest_asset_url "${ARCH}\.rpm$")"; [ -n "$URL" ] || die "No .rpm found for $ARCH"
      download "$URL" "$TMP/rustdesk.rpm"
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y "$TMP/rustdesk.rpm" || die "dnf install failed."
      else
        yum install -y "$TMP/rustdesk.rpm" || die "yum install failed."
      fi
    else
      die "Only apt (Debian/Ubuntu) and dnf/yum (Fedora/RHEL) are supported."
    fi
    rm -rf "$TMP"
    RD="$(command -v rustdesk || true)"
    [ -n "$RD" ] || die "rustdesk binary not found after install."
  else
    echo "RustDesk already installed: $RD"
  fi

  step "Stopping RustDesk before writing config"
  systemctl stop rustdesk 2>/dev/null || true
  pkill -x rustdesk 2>/dev/null || true
  sleep 2

  step "Writing server configuration"
  write_config "/root/.config/rustdesk"
  if [ -n "$REAL_HOME" ]; then write_config "$REAL_HOME/.config/rustdesk" "$REAL_USER"; fi

  step "Starting service"
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable rustdesk >/dev/null 2>&1 || true
  systemctl restart rustdesk || die "Could not start rustdesk service (is systemd available?)."
  for i in 1 2 3 4 5 6 7 8 9 10; do
    systemctl is-active --quiet rustdesk && break
    sleep 2
  done
  systemctl is-active --quiet rustdesk || die "rustdesk service is not running."
  sleep 5

  step "Setting permanent password"
  run_to 30 "$RD" --password "$PASSWORD" >/dev/null 2>&1 || die "Setting the password failed or timed out."
  sleep 2

  step "Retrieving RustDesk ID"
  RD_ID="$(get_id)"

# ==================== macOS ====================
elif [ "$OS" = "Darwin" ]; then
  APP="/Applications/RustDesk.app"
  RD="$APP/Contents/MacOS/RustDesk"

  pkill -x RustDesk 2>/dev/null || true
  sleep 1

  if [ ! -x "$RD" ]; then
    step "Installing RustDesk"
    URL="$(latest_asset_url "${ARCH}\.dmg$")"; [ -n "$URL" ] || die "No .dmg found for $ARCH"
    TMP="$(mktemp -d)"
    download "$URL" "$TMP/rustdesk.dmg"
    MNT="$(hdiutil attach "$TMP/rustdesk.dmg" -nobrowse -readonly -noverify 2>/dev/null | grep -o '/Volumes/.*' | head -n1 || true)"
    [ -n "$MNT" ] || die "Could not mount the .dmg."
    rm -rf "$APP"
    cp -R "$MNT/RustDesk.app" /Applications/ || die "Could not copy RustDesk.app."
    hdiutil detach "$MNT" -quiet || true
    rm -rf "$TMP"
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
    [ -x "$RD" ] || die "RustDesk not found after install."
  else
    echo "RustDesk already installed: $APP"
  fi

  step "Writing server configuration"
  write_config "/var/root/Library/Preferences/com.carriez.RustDesk"
  if [ -n "$REAL_HOME" ]; then write_config "$REAL_HOME/Library/Preferences/com.carriez.RustDesk" "$REAL_USER"; fi

  step "Setting permanent password"
  run_to 30 "$RD" --password "$PASSWORD" >/dev/null 2>&1 || die "Setting the password failed or timed out."
  sleep 2

  step "Retrieving RustDesk ID"
  RD_ID="$(get_id)"

  if [ -n "$REAL_USER" ]; then
    sudo -u "$REAL_USER" open -a RustDesk >/dev/null 2>&1 || true
  else
    open -a RustDesk >/dev/null 2>&1 || true
  fi
else
  die "Unsupported OS: $OS"
fi

[ -n "${RD_ID:-}" ] || die "Could not read RustDesk ID."

printf '\n========================================\n RUSTDESK SETUP COMPLETE\n========================================\n'
echo "ID          : $RD_ID"
echo "Password    : $PASSWORD"
echo "ID Server   : $ID_SERVER"
echo "Relay Server: $RELAY_SERVER"
echo "Key         : $KEY"
if [ "$OS" = "Darwin" ]; then
  echo
  echo "macOS: grant Accessibility + Screen Recording to RustDesk in"
  echo "System Settings > Privacy & Security, or remote control will not work."
fi
