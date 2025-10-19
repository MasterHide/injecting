#!/usr/bin/env bash
# inject_config.sh -- interactive helper for /opt/tblocker/config.yaml
#
# Features:
#  - Installs required packages (yq, nano, curl, wget, systemd utils) if missing
#  - Ensures config and directories exist
#  - Update BypassIPS + StorageDir + webhook (token/chat) safely (with backup)
#  - Manual restart / manual edit options
#  - Log viewing (tail + journalctl)
#  - Can install itself globally as "tblock"

set -euo pipefail
IFS=$'\n\t'

########## Configuration ##########
CONFIG="/opt/tblocker/config.yaml"
BACKUP_DIR="/opt/tblocker/backups"
TMPROOT="$(mktemp -d -t injectcfg.XXXXXX)"
SNIPPET="$TMPROOT/snippet.yaml"
MERGED="$TMPROOT/merged.yaml"
INSTALL_PATH="/usr/local/bin/tblock"
SERVICE_NAME="tblocker"
ACCESS_LOG="/usr/local/x-ui/access.log"
########## End configuration ##########

cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

log() { printf '[INFO] %s\n' "$*"; }
err() { printf '[ERROR] %s\n' "$*" >&2; }

is_root() { [[ "$(id -u)" -eq 0 ]]; }
safe_sudo() { if is_root; then "$@"; else sudo "$@"; fi; }

# ---------- Dependency check ----------
install_requirements() {
  log "Checking and installing required packages..."
  if ! command -v curl >/dev/null 2>&1; then safe_sudo apt-get update -y && safe_sudo apt-get install -y curl; fi
  if ! command -v wget >/dev/null 2>&1; then safe_sudo apt-get install -y wget; fi
  if ! command -v nano >/dev/null 2>&1; then safe_sudo apt-get install -y nano; fi
  if ! command -v systemctl >/dev/null 2>&1; then safe_sudo apt-get install -y systemd; fi
  if ! command -v /usr/local/bin/yq >/dev/null 2>&1; then
    log "Installing yq (mikefarah v4)..."
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64) BIN="yq_linux_amd64" ;;
      aarch64) BIN="yq_linux_arm64" ;;
      armv7l) BIN="yq_linux_arm" ;;
      *) BIN="yq_linux_amd64"; log "Unknown arch $ARCH, defaulting to amd64";;
    esac
    safe_sudo wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/latest/download/${BIN}"
    safe_sudo chmod +x /usr/local/bin/yq
  fi
  log "Dependencies ready."
}

require_config() {
  if [[ ! -d "$(dirname "$CONFIG")" ]]; then
    log "Creating config directory $(dirname "$CONFIG")..."
    safe_sudo mkdir -p "$(dirname "$CONFIG")"
  fi
  if [[ ! -f "$CONFIG" ]]; then
    log "Config file not found, creating empty $CONFIG..."
    safe_sudo touch "$CONFIG"
    safe_sudo chmod 644 "$CONFIG"
  fi

  # Ensure required base keys exist with defaults
  /usr/local/bin/yq -i '
    .LogFile = (.LogFile // "/usr/local/x-ui/access.log") |
    .BlockDuration = (.BlockDuration // 10) |
    .TorrentTag = (.TorrentTag // "TORRENT") |
    .BlockMode = (.BlockMode // "nft")
  ' "$CONFIG"
}

create_backup() {
  mkdir -p "$BACKUP_DIR"
  TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
  BACKUP_PATH="$BACKUP_DIR/config.yaml.bak.$TIMESTAMP"
  cp -a "$CONFIG" "$BACKUP_PATH"
  log "Backup created: $BACKUP_PATH"
}

build_snippet() {
  local bot_token="$1"
  local chat_id="$2"
  cat > "$SNIPPET" <<EOF
BypassIPS:
  - "127.0.0.1"
  - "::1"
  - "103.21.244.0/22"
  - "103.22.200.0/22"
  - "103.31.4.0/22"
  - "104.16.0.0/13"
  - "104.24.0.0/14"
  - "108.162.192.0/18"
  - "131.0.72.0/22"
  - "141.101.64.0/18"
  - "162.158.0.0/15"
  - "172.64.0.0/13"
  - "173.245.48.0/20"
  - "188.114.96.0/20"
  - "190.93.240.0/20"
  - "197.234.240.0/22"
  - "198.41.128.0/17"
  - "2400:cb00::/32"
  - "2606:4700::/32"
  - "2803:f800::/32"
  - "2405:b500::/32"
  - "2405:8100::/32"
  - "2a06:98c0::/29"
  - "2c0f:f248::/32"

StorageDir: "/opt/tblocker"
SendWebhook: true
WebhookURL: "https://api.telegram.org/bot${bot_token}/sendMessage"
WebhookTemplate: |
  {"chat_id":"${chat_id}","parse_mode":"HTML","text":"🚨 <b>Torrent Detected!</b>\n\n👤 <b>User:</b> %s\n🌍 <b>IP:</b> %s\n🖥 <b>Server:</b> %s\n⚡️ <b>Action:</b> %s\n⏱️ <b>Duration:</b> %d minutes\n🕒 <b>Time:</b> %s"}
EOF
}

merge_snippet() {
  /usr/local/bin/yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$CONFIG" "$SNIPPET" > "$MERGED"
}

validate_merged() {
  [[ -s "$MERGED" ]] || { err "Merged file is empty."; return 1; }
  /usr/local/bin/yq eval '.' "$MERGED" >/dev/null || { err "Merged YAML invalid."; return 1; }
}

install_merged() {
  local backup="$1"
  cp "$MERGED" "$CONFIG"
  [[ -f "$backup" ]] && { chmod --reference="$backup" "$CONFIG" || true; chown --reference="$backup" "$CONFIG" || true; }
  log "Config updated: $CONFIG"
}

restart_service() {
  log "Restarting $SERVICE_NAME..."
  if safe_sudo systemctl restart "$SERVICE_NAME" 2>/dev/null; then
    log "$SERVICE_NAME restarted."
  else
    log "Restart failed, trying start..."
    safe_sudo systemctl start "$SERVICE_NAME" || err "Service could not be started."
  fi
}

prompt_token_chatid() {
  local bot chat
  read -rp "Enter Telegram bot token: " bot
  read -rp "Enter Telegram chat id: " chat
  bot="${bot//[[:space:]]/}"
  chat="${chat//[[:space:]]/}"
  [[ -z "$bot" || -z "$chat" ]] && { err "Both required."; return 1; }
  printf '%s\n%s\n' "$bot" "$chat"
}

# ---------- Menu actions ----------
menu_update_config() {
  require_config
  local bot chat
  # FIX: read directly into vars instead of process substitution
  if ! read_values=$(prompt_token_chatid); then return 1; fi
  bot=$(echo "$read_values" | sed -n 1p)
  chat=$(echo "$read_values" | sed -n 2p)

  create_backup
  # Remove old doc-comment lines about "additional parameters"
  safe_sudo sed -i '/^# For additional parameters/d;/^# Для дополнительных параметров/d' "$CONFIG"
  build_snippet "$bot" "$chat"
  merge_snippet
  validate_merged || { cp -a "$BACKUP_PATH" "$CONFIG"; return 1; }

  # Verify chat_id is not empty
  chat_in_merged=$(/usr/local/bin/yq -r '.WebhookTemplate' "$MERGED" | grep -o '"chat_id":"[^"]*"' | cut -d'"' -f4)
  if [[ -z "$chat_in_merged" ]]; then
    err "chat_id not injected correctly; restoring backup."
    cp -a "$BACKUP_PATH" "$CONFIG"
    return 1
  fi

  install_merged "$BACKUP_PATH"
  read -rp "Restart $SERVICE_NAME now? [Y/n]: " yn
  [[ "${yn:-Y}" =~ ^[Yy]$ ]] && restart_service
}

menu_manual_restart() { restart_service; }
menu_manual_edit() { safe_sudo nano "$CONFIG"; }
menu_tail_access_log() { [[ -f "$ACCESS_LOG" ]] && tail -f "$ACCESS_LOG" || err "Log not found."; }
menu_journalctl_follow() { safe_sudo journalctl -u "$SERVICE_NAME" -f; }
menu_install_global() { safe_sudo cp -a "$(readlink -f "${BASH_SOURCE[0]}")" "$INSTALL_PATH"; safe_sudo chmod +x "$INSTALL_PATH"; log "Installed as $INSTALL_PATH"; }

# ---------- Menu ----------
main_menu() {
  while true; do
    echo
    echo "================ tblock menu ================"
    echo "1) Update config (BypassIPS + webhook)"
    echo "2) Manual restart $SERVICE_NAME"
    echo "3) Edit config manually (nano)"
    echo "4) Tail $ACCESS_LOG"
    echo "5) journalctl -u $SERVICE_NAME -f"
    echo "6) Install globally as 'tblock'"
    echo "7) Exit"
    echo "============================================="
    read -rp "Choose [1-7]: " opt
    case "$opt" in
      1) menu_update_config ;;
      2) menu_manual_restart ;;
      3) menu_manual_edit ;;
      4) menu_tail_access_log ;;
      5) menu_journalctl_follow ;;
      6) menu_install_global ;;
      7) log "Bye."; break ;;
      *) echo "Invalid choice." ;;
    esac
  done
}

# ---------- Main ----------
install_requirements
require_config
log "Starting tblock helper..."
main_menu
