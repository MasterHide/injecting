#!/usr/bin/env bash
# inject_config.sh -- production-ready interactive tool for /opt/tblocker/config.yaml
# Features:
#  - update BypassIPS + StorageDir + webhook (token/chat) safely (backup)
#  - optional service restart
#  - manual restart & manual edit option
#  - log viewing (tail + journalctl)
#  - can install itself as global command 'tblock'
#
# Requires: yq (mikefarah/yq v4+)
# Usage: run as normal user; script will use sudo when root is required.
set -euo pipefail
IFS=$'\n\t'

########## Configuration ##########
CONFIG="/opt/tblocker/config.yaml"
BACKUP_DIR="/opt/tblocker/backups"
TMPROOT="$(mktemp -d -t injectcfg.XXXXXX)"
SNIPPET="$TMPROOT/snippet.yaml"
MERGED="$TMPROOT/merged.yaml"
INSTALL_PATH="/usr/local/bin/tblock"   # global command symlink / file
SERVICE_NAME="tblocker"
ACCESS_LOG="/usr/local/x-ui/access.log"
########## End configuration ##########

cleanup() {
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    err "'yq' (mikefarah/yq v4+) is required but not found."
    cat <<'USAGE' >&2

Install example (Linux x86_64):
  sudo wget -O /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  sudo chmod +x /usr/local/bin/yq

Or install from your package manager.
USAGE
    return 1
  fi
}

ensure_config_exists() {
  if [[ ! -f "$CONFIG" ]]; then
    err "Config file not found at $CONFIG"
    return 1
  fi
}

is_root() {
  [[ "$(id -u)" -eq 0 ]]
}

safe_sudo() {
  # run command with sudo if not root
  if is_root; then
    "$@"
  else
    sudo "$@"
  fi
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
# IP addresses to bypass blocking (never blocked)
BypassIPS:
  - "127.0.0.1"
  - "::1"
  # Cloudflare IPv4 ranges
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
  # Cloudflare IPv6 ranges
  - "2400:cb00::/32"
  - "2606:4700::/32"
  - "2803:f800::/32"
  - "2405:b500::/32"
  - "2405:8100::/32"
  - "2a06:98c0::/29"
  - "2c0f:f248::/32"
# - "YOUR_PUBLIC_IP/32" # optional

# Storage directory for block data (persistent state)
StorageDir: "/opt/tblocker"

SendWebhook: true
WebhookURL: "https://api.telegram.org/bot${bot_token}/sendMessage"
WebhookTemplate: '{"chat_id":"'"${chat_id}"'","parse_mode":"HTML","text":"🚨 <b>Torrent Detected!</b>\n\n👤 <b>User:</b> %s\n🌍 <b>IP:</b> %s\n🖥 <b>Server:</b> %s\n⚡️ <b>Action:</b> %s\n⏱️ <b>Duration:</b> %d minutes\n🕒 <b>Time:</b> %s"}'
EOF
}

merge_snippet() {
  # Merge snippet into existing config keeping other keys intact.
  # Uses yq eval-all: original * snippet (snippet overrides keys present)
  yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$CONFIG" "$SNIPPET" > "$MERGED"
}

validate_merged() {
  if [[ ! -s "$MERGED" ]]; then
    err "Merged file is empty or invalid."
    return 1
  fi
  # optional: try to parse merged with yq to ensure valid YAML
  if ! yq eval '.' "$MERGED" >/dev/null 2>&1; then
    err "Merged YAML failed to parse with yq."
    return 1
  fi
  return 0
}

install_merged() {
  # replace original with merged and preserve ownership/permissions from backup (best-effort)
  local backup="$1"
  cp "$MERGED" "$CONFIG"
  if [[ -f "$backup" ]]; then
    chmod --reference="$backup" "$CONFIG" || true
    chown --reference="$backup" "$CONFIG" || true
  fi
  log "Config successfully written to $CONFIG"
}

restart_service() {
  log "Attempting to restart $SERVICE_NAME service..."
  if safe_sudo systemctl restart "$SERVICE_NAME" 2>/dev/null; then
    log "systemctl restart $SERVICE_NAME OK"
    return 0
  fi

  log "Restart failed; trying start fallback..."
  if safe_sudo systemctl start "$SERVICE_NAME" 2>/dev/null; then
    log "systemctl start $SERVICE_NAME OK"
    return 0
  fi

  err "Could not restart or start $SERVICE_NAME via systemctl. The service may not exist or systemd may be unavailable."
  return 1
}

prompt_token_chatid() {
  local bot token chat
  read -rp "Enter Telegram bot token (format 123456:ABC-...): " bot
  read -rp "Enter Telegram chat id (numeric or @channel): " chat
  # Basic non-empty check:
  if [[ -z "$bot" || -z "$chat" ]]; then
    err "Bot token and chat id are required."
    return 1
  fi
  printf '%s\n%s\n' "$bot" "$chat"
}

menu_update_config() {
  require_yq || return 1
  ensure_config_exists || return 1

  # Prompt and get values
  local bot chat
  if ! read -r bot chat < <(prompt_token_chatid); then
    return 1
  fi

  create_backup
  build_snippet "$bot" "$chat"
  merge_snippet

  if ! validate_merged; then
    # restore from backup just in case
    cp -a "$BACKUP_PATH" "$CONFIG" || true
    err "Merge validation failed; backup restored. Aborting."
    return 1
  fi

  install_merged "$BACKUP_PATH"

  # Ask whether to restart
  read -rp "Do you want to restart the $SERVICE_NAME service now? [Y/n]: " yn
  yn="${yn:-Y}"
  if [[ "$yn" =~ ^([yY]) ]]; then
    restart_service || err "Service restart failed. Check logs."
  else
    log "Skipped restart. Use 'tblock' -> Restart service or run: sudo systemctl restart $SERVICE_NAME"
  fi
  return 0
}

menu_manual_restart() {
  read -rp "Run 'sudo systemctl restart $SERVICE_NAME' now? [Y/n]: " yn
  yn="${yn:-Y}"
  if [[ "$yn" =~ ^([yY]) ]]; then
    restart_service || err "Service restart failed."
  else
    log "Manual restart canceled."
  fi
}

menu_manual_edit() {
  ensure_config_exists || return 1
  log "Opening $CONFIG in nano. Save and exit to return to menu."
  safe_sudo nano "$CONFIG"
  log "Done editing."
}

menu_tail_access_log() {
  if [[ ! -f "$ACCESS_LOG" ]]; then
    err "Access log not found at $ACCESS_LOG"
    return 1
  fi
  log "Tailing access log: $ACCESS_LOG (Ctrl-C to stop)"
  tail -f "$ACCESS_LOG"
}

menu_journalctl_follow() {
  log "Following journalctl for unit: $SERVICE_NAME (Ctrl-C to stop)"
  safe_sudo journalctl -u "$SERVICE_NAME" -f
}

menu_install_global() {
  # install this script to /usr/local/bin/tblock (copy)
  local me
  me="$(readlink -f "${BASH_SOURCE[0]}")"
  if [[ ! -f "$me" ]]; then
    err "Cannot locate current script file."
    return 1
  fi

  log "Installing global command to $INSTALL_PATH (requires sudo/root)..."
  safe_sudo cp -a "$me" "$INSTALL_PATH"
  safe_sudo chmod +x "$INSTALL_PATH"
  log "Installed. You can now run the menu with: tblock"
}

menu_print_help() {
  cat <<EOF
tblock - interactive helper for /opt/tblocker/config.yaml

Options:
  1) Update config (replace BypassIPS + StorageDir + webhook)
  2) Manual restart tblocker service
  3) Edit config manually (nano /opt/tblocker/config.yaml)
  4) Tail access log: tail -f $ACCESS_LOG
  5) Follow service logs: sudo journalctl -u $SERVICE_NAME -f
  6) Install this script as global command 'tblock' (copies script to $INSTALL_PATH)
  7) Exit
EOF
}

main_menu() {
  while true; do
    echo
    echo "================ tblock menu ================"
    echo "1) Update config (BypassIPS + webhook)"
    echo "2) Manual restart tblocker service"
    echo "3) Open /opt/tblocker/config.yaml in nano (manual edit)"
    echo "4) tail -f $ACCESS_LOG"
    echo "5) sudo journalctl -u $SERVICE_NAME -f"
    echo "6) Install this script as global command 'tblock'"
    echo "7) Exit"
    echo "============================================="
    read -rp "Choose an option [1-7]: " opt
    case "$opt" in
      1) menu_update_config ;;
      2) menu_manual_restart ;;
      3) menu_manual_edit ;;
      4) menu_tail_access_log ;;
      5) menu_journalctl_follow ;;
      6) menu_install_global ;;
      7) log "Bye."; break ;;
      *) echo "Invalid choice. Pick 1..7." ;;
    esac
  done
}

# If invoked with "install" arg, just install globally and exit
if [[ "${1:-}" == "install" ]]; then
  menu_install_global
  exit $?
fi

# Start: check yq but do not abort if missing until needed (we will check before update)
log "Starting tblock helper..."
main_menu
