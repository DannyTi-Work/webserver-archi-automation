#!/usr/bin/env bash
# scripts/uninstall-panel.sh — remove the Phase 8 web admin panel.
# Usage: bash scripts/uninstall-panel.sh [--yes] [--purge-config]
#   --yes          skip the typed confirmation (for automation)
#   --purge-config also delete config/panel.conf (gitignored local settings)
#
# Removes only panel artifacts. Site vhosts, docroots, databases, certificates
# (including the apex cert the panel reused) and the LEMP stack are untouched.
# Files are backed up before deletion so a manual rollback is possible.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
require_root

assume_yes=0
purge_config=0
while (( $# )); do
  case "$1" in
    --yes)          assume_yes=1; shift ;;
    --purge-config) purge_config=1; shift ;;
    -h|--help)
      printf 'usage: bash scripts/uninstall-panel.sh [--yes] [--purge-config]\n'
      exit 0
      ;;
    *) fail "unknown option: $1" ;;
  esac
done

log "== uninstall-panel.sh =="

# ---------------------------------------------------------------------------
# Read panel.conf for paths (missing file -> documented defaults)
# ---------------------------------------------------------------------------
CONFIG="${REPO_ROOT}/config/panel.conf"
conf() {
  local key="$1" line val
  [[ -f "$CONFIG" ]] || return 1
  line="$(grep -m1 "^${key}=" "$CONFIG" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 1
  val="${line#*=}"
  val="${val#\"}"; val="${val%\"}"
  val="${val#\'}"; val="${val%\'}"
  printf '%s' "$val"
}

PANEL_PORT="$(conf PANEL_PORT || printf '8083')"
ADMIN_PATH="$(conf ADMIN_PATH || printf '/_wsa-admin')"
PANEL_ROOT="$(conf PANEL_ROOT || printf '/srv/wsa-panel/public')"
HTPASSWD_FILE="$(conf HTPASSWD_FILE || printf '/etc/nginx/.wsa-panel-htpasswd')"
SESSION_SECRET_FILE="$(conf SESSION_SECRET_FILE || printf '/etc/wsa/panel-session.key')"
SUDOERS_FILE="$(conf SUDOERS_FILE || printf '/etc/sudoers.d/wsa-panel')"

# Refuse unsafe derived paths before any rm.
[[ -n "$PANEL_ROOT" && "$PANEL_ROOT" == /* && "$PANEL_ROOT" != "/" ]] || \
  fail "unsafe PANEL_ROOT: '${PANEL_ROOT}'"
[[ -n "$ADMIN_PATH" && "$ADMIN_PATH" == /* && "$ADMIN_PATH" != "/" ]] || \
  fail "unsafe ADMIN_PATH: '${ADMIN_PATH}'"
PANEL_PHP_DIR="${PANEL_ROOT%/}${ADMIN_PATH%/}"
[[ "$PANEL_PHP_DIR" != /var/www/* && "$PANEL_PHP_DIR" != "$REPO_ROOT" ]] || \
  fail "refusing to remove unsafe panel directory: $PANEL_PHP_DIR"

VHOST="/etc/nginx/conf.d/panel.conf"
JAIL="/etc/fail2ban/jail.d/wsa-panel.conf"
HOOK="/etc/letsencrypt/renewal-hooks/deploy/wsa-panel-reload"
declare -a targets=(
  "$SUDOERS_FILE"
  "$VHOST"
  "$JAIL"
  "$HOOK"
  "$PANEL_PHP_DIR"
  "$HTPASSWD_FILE"
  "$SESSION_SECRET_FILE"
)

found=0
for path in "${targets[@]}"; do
  if run_root test -e "$path" || run_root test -L "$path"; then found=1; fi
done
ufw_rule=0
ufw status 2>/dev/null | grep -q "${PANEL_PORT}/tcp" && ufw_rule=1
if (( ! found )) && (( ! ufw_rule )) && [[ ! -f "$CONFIG" || $purge_config -eq 0 ]]; then
  info "no panel artifacts found — nothing to remove"
  exit 0
fi

if (( ! assume_yes )); then
  warn "about to PERMANENTLY remove the web admin panel and its secrets"
  printf 'type "uninstall" to confirm: '
  read -r confirm
  [[ "$confirm" == "uninstall" ]] || fail "confirmation did not match — nothing removed"
fi

# ---------------------------------------------------------------------------
# 1. Back up everything before deleting it
# ---------------------------------------------------------------------------
backup_dir="/var/lib/webserver-archi-automation/panel-uninstall-$(date +%Y%m%d-%H%M%S)"
run_root install -d -m 0700 "$backup_dir"
for path in "${targets[@]}"; do
  if run_root test -e "$path" || run_root test -L "$path"; then
    run_root mkdir -p "${backup_dir}$(dirname -- "$path")"
    run_root cp -a -- "$path" "${backup_dir}${path}"
  fi
done
info "backup created: $backup_dir"

# ---------------------------------------------------------------------------
# 2. Revoke panel privilege first, then disable the listener
# ---------------------------------------------------------------------------
if run_root test -e "$SUDOERS_FILE" || run_root test -L "$SUDOERS_FILE"; then
  run_root rm -f "$SUDOERS_FILE"
  info "sudoers drop-in removed: $SUDOERS_FILE (no reload needed — sudo reads it per call)"
fi

if run_root test -e "$JAIL" || run_root test -L "$JAIL"; then
  run_root rm -f "$JAIL"
  info "fail2ban jail removed: $JAIL"
  if systemctl is-active --quiet fail2ban; then
    run_root systemctl reload fail2ban
    info "fail2ban reloaded"
  fi
fi

if run_root test -e "$VHOST" || run_root test -L "$VHOST"; then
  run_root rm -f "$VHOST"
  info "panel vhost removed: $VHOST"
fi

# ---------------------------------------------------------------------------
# 3. Remove panel files and secrets
# ---------------------------------------------------------------------------
if run_root test -d "$PANEL_PHP_DIR"; then
  run_root rm -rf -- "$PANEL_PHP_DIR"
  info "panel PHP directory removed: $PANEL_PHP_DIR"
fi
for path in "$HTPASSWD_FILE" "$SESSION_SECRET_FILE" "$HOOK"; do
  if run_root test -e "$path" || run_root test -L "$path"; then
    run_root rm -f -- "$path"
    info "removed: $path"
  fi
done
# Remove /etc/wsa only if the uninstall left it empty.
if run_root test -d /etc/wsa && run_root test -z "$(ls -A /etc/wsa 2>/dev/null)"; then
  run_root rmdir /etc/wsa
  info "removed empty directory: /etc/wsa"
fi

# ---------------------------------------------------------------------------
# 4. Firewall rule
# ---------------------------------------------------------------------------
if (( ufw_rule )); then
  run_root ufw delete allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || \
    warn "could not remove UFW rule for ${PANEL_PORT}/tcp — remove it manually"
  info "UFW rule removed: ${PANEL_PORT}/tcp"
fi

# ---------------------------------------------------------------------------
# 5. Optional config purge (last, so failures above keep the settings)
# ---------------------------------------------------------------------------
if (( purge_config )) && [[ -f "$CONFIG" ]]; then
  # Ensure the backup destination directory exists (the startup backup loop
  # only covers targets[], which does not include config/panel.conf).
  run_root mkdir -p "${backup_dir}$(dirname -- "$CONFIG")"
  if run_root cp -a -- "$CONFIG" "${backup_dir}${CONFIG}"; then
    run_root rm -f -- "$CONFIG"
    info "panel config purged: $CONFIG"
  else
    warn "could not back up $CONFIG — keeping it; remove manually if desired"
  fi
else
  info "panel config kept: $CONFIG (use --purge-config to delete it)"
fi

# ---------------------------------------------------------------------------
# 6. nginx config gate, then conditional reload
# ---------------------------------------------------------------------------
config_test "nginx (panel uninstall)" nginx -t
reload_service nginx

log ""
log "== panel uninstall complete =="
info "sites, their certificates and the LEMP stack were not touched"
info "backup of removed files: $backup_dir"
