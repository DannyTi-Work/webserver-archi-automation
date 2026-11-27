#!/usr/bin/env bash
# scripts/setup-panel.sh — install the Phase 8 web admin panel on the VPS.
# Usage: bash scripts/setup-panel.sh
#   Requires config/panel.conf (gitignored, mode 600) — copy from
#   config/panel.conf.example and set PANEL_DOMAIN to the apex domain whose
#   existing Let's Encrypt certificate the panel reuses on PANEL_PORT.
#   Safe to re-run: every file is installed only when its content changes.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
require_root

log "== setup-panel.sh =="

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------
pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

ensure_packages() {
  local missing=() pkg
  for pkg in "$@"; do
    pkg_installed "$pkg" || missing+=("$pkg")
  done
  if (( ${#missing[@]} )); then
    info "installing packages: ${missing[*]}"
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  else
    info "packages already present: $*"
  fi
}

enable_service() {
  local svc="$1"
  if ! systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    run_root systemctl enable "$svc"
  fi
  if ! systemctl is-active --quiet "$svc"; then
    run_root systemctl start "$svc"
  fi
  info "$svc enabled and running"
}

install_if_changed() {
  local src="$1" dest="$2" mode="$3"
  if run_root test -f "$dest" && run_root cmp -s "$src" "$dest"; then
    info "unchanged: $dest"
  else
    run_root install -m "$mode" "$src" "$dest"
    info "installed: $dest"
  fi
}

# ---------------------------------------------------------------------------
# 1. Read and validate config/panel.conf
# ---------------------------------------------------------------------------
CONFIG="${REPO_ROOT}/config/panel.conf"
if [[ ! -f "$CONFIG" ]]; then
  fail "config/panel.conf missing — copy config/panel.conf.example to config/panel.conf, chmod 600, set PANEL_DOMAIN"
fi

conf() {
  local key="$1" line val
  line="$(grep -m1 "^${key}=" "$CONFIG" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 1
  val="${line#*=}"
  val="${val#\"}"; val="${val%\"}"
  val="${val#\'}"; val="${val%\'}"
  printf '%s' "$val"
}

PANEL_DOMAIN="$(conf PANEL_DOMAIN || true)"
PANEL_PORT="$(conf PANEL_PORT || printf '8083')"
ADMIN_PATH="$(conf ADMIN_PATH || printf '/_wsa-admin')"
BASIC_AUTH_USER="$(conf BASIC_AUTH_USER || printf 'admin')"
HTPASSWD_FILE="$(conf HTPASSWD_FILE || printf '/etc/nginx/.wsa-panel-htpasswd')"
SESSION_SECRET_FILE="$(conf SESSION_SECRET_FILE || printf '/etc/wsa/panel-session.key')"
RATE_LIMIT_RATE="$(conf RATE_LIMIT_RATE || printf '10r/m')"
PANEL_ROOT="$(conf PANEL_ROOT || printf '/srv/wsa-panel/public')"
WP_TEMPLATE_DIR="$(conf WP_TEMPLATE_DIR || printf '/var/lib/wsa/wordpress')"
PANEL_ACCESS_LOG="$(conf PANEL_ACCESS_LOG || printf '/var/log/nginx/wsa-panel.access.log')"
PANEL_ERROR_LOG="$(conf PANEL_ERROR_LOG || printf '/var/log/nginx/wsa-panel.error.log')"
SUDOERS_FILE="$(conf SUDOERS_FILE || printf '/etc/sudoers.d/wsa-panel')"
FAIL2BAN_ENABLED="$(conf FAIL2BAN_ENABLED || printf '1')"
FAIL2BAN_MAXRETRY="$(conf FAIL2BAN_MAXRETRY || printf '5')"
FAIL2BAN_FINDTIME="$(conf FAIL2BAN_FINDTIME || printf '600')"
FAIL2BAN_BANTIME="$(conf FAIL2BAN_BANTIME || printf '3600')"
PHP_FPM_SOCKET="$(conf PHP_FPM_SOCKET || true)"

is_valid_domain "$PANEL_DOMAIN" || fail "invalid PANEL_DOMAIN: '${PANEL_DOMAIN:-<empty>}'"
resolved="$(dig +short A "$PANEL_DOMAIN" @8.8.8.8 2>/dev/null | head -1 || true)"
[[ -n "$resolved" ]] || fail "PANEL_DOMAIN $PANEL_DOMAIN does not resolve to this VPS"

cert_dir="/etc/letsencrypt/live/${PANEL_DOMAIN}"
if [[ ! -f "${cert_dir}/fullchain.pem" || ! -f "${cert_dir}/privkey.pem" ]]; then
  fail "no certificate for PANEL_DOMAIN=$PANEL_DOMAIN — run: bash scripts/tls.sh $PANEL_DOMAIN"
fi
info "reusing certificate: ${cert_dir}/fullchain.pem"

if [[ -z "$PHP_FPM_SOCKET" ]]; then
  for s in /run/php/php*-fpm.sock; do
    [[ -S "$s" ]] && { PHP_FPM_SOCKET="$s"; break; }
  done
fi
[[ -n "$PHP_FPM_SOCKET" && -S "$PHP_FPM_SOCKET" ]] || fail "no PHP-FPM socket found — was setup.sh run?"
info "PHP-FPM socket: $PHP_FPM_SOCKET"

# ---------------------------------------------------------------------------
# 2. nginx vhost from template
# ---------------------------------------------------------------------------
tpl="${REPO_ROOT}/templates/nginx-panel.conf.tpl"
[[ -f "$tpl" ]] || fail "template missing: $tpl"
rendered="$(mktemp)"
sed -e "s|__PANEL_DOMAIN__|${PANEL_DOMAIN}|g" \
    -e "s|__PANEL_PORT__|${PANEL_PORT}|g" \
    -e "s|__ADMIN_PATH__|${ADMIN_PATH}|g" \
    -e "s|__PANEL_ROOT__|${PANEL_ROOT}|g" \
    -e "s|__CERT_FULLCHAIN__|${cert_dir}/fullchain.pem|g" \
    -e "s|__CERT_PRIVKEY__|${cert_dir}/privkey.pem|g" \
    -e "s|__HTPASSWD_FILE__|${HTPASSWD_FILE}|g" \
    -e "s|__PHP_FPM_SOCKET__|${PHP_FPM_SOCKET}|g" \
    -e "s|__RATE_LIMIT_RATE__|${RATE_LIMIT_RATE}|g" \
    -e "s|__PANEL_ACCESS_LOG__|${PANEL_ACCESS_LOG}|g" \
    -e "s|__PANEL_ERROR_LOG__|${PANEL_ERROR_LOG}|g" \
    "$tpl" > "$rendered"
install_if_changed "$rendered" /etc/nginx/conf.d/panel.conf 0644
rm -f "$rendered"

# ---------------------------------------------------------------------------
# 3. Panel PHP files, outside every site docroot
# ---------------------------------------------------------------------------
PANEL_PHP_DIR="${PANEL_ROOT%/}${ADMIN_PATH%/}"
run_root install -d -m 0755 "$PANEL_PHP_DIR"
for f in bootstrap.php index.php actions.php; do
  [[ -f "${SCRIPT_DIR}/panel/${f}" ]] || fail "panel file missing: scripts/panel/${f}"
  install_if_changed "${SCRIPT_DIR}/panel/${f}" "${PANEL_PHP_DIR}/${f}" 0644
done
# Tell the copied PHP files where the real checkout lives (config, scripts).
local_cfg="$(mktemp)"
ACTION_LOG="$(conf ACTION_LOG || printf '/var/log/wsa-panel/actions.log')"
printf '<?php\ndefine("WSA_REPO_ROOT", "%s");\ndefine("WSA_PANEL_DOMAIN", "%s");\ndefine("WSA_PANEL_PORT", "%s");\ndefine("WSA_ADMIN_PATH", "%s");\ndefine("WSA_ACTION_LOG", "%s");\n' \
  "$REPO_ROOT" "$PANEL_DOMAIN" "$PANEL_PORT" "$ADMIN_PATH" "$ACTION_LOG" > "$local_cfg"
run_root install -o root -g www-data -m 0640 "$local_cfg" "${PANEL_PHP_DIR}/config.local.php"
rm -f "$local_cfg"

# Action log: directory writable by www-data so PHP can append successes and
# failures. Keep an existing log on re-runs (do not truncate history).
run_root install -d -o root -g www-data -m 0750 "$(dirname -- "$ACTION_LOG")"
if run_root test -e "$ACTION_LOG"; then
  run_root chown root:www-data "$ACTION_LOG"
  run_root chmod 0660 "$ACTION_LOG"   # group must be writable: PHP-FPM appends as www-data
else
  run_root install -o root -g www-data -m 0660 /dev/null "$ACTION_LOG"
fi
info "panel PHP installed at $PANEL_PHP_DIR (action log: $ACTION_LOG)"

# ---------------------------------------------------------------------------
# 4. Basic Auth (bcrypt) — keep an existing password on re-runs
# ---------------------------------------------------------------------------
if ! command -v htpasswd >/dev/null 2>&1 && ! pkg_installed apache2-utils; then
  ensure_packages apache2-utils
fi
if run_root test -f "$HTPASSWD_FILE"; then
  info "htpasswd file already exists — existing password preserved: $HTPASSWD_FILE"
  run_root chown root:www-data "$HTPASSWD_FILE"
  run_root chmod 0640 "$HTPASSWD_FILE"
else
  if [[ -n "${PANEL_PASSWORD:-}" ]]; then
    auth_pw="$PANEL_PASSWORD"
  else
    auth_pw="$(gen_password 20)"
  fi
  printf '%s\n' "$auth_pw" | run_root htpasswd -B -i -c "$HTPASSWD_FILE" "$BASIC_AUTH_USER"
  # nginx worker processes (www-data) open auth_basic_user_file, not the master.
  run_root chown root:www-data "$HTPASSWD_FILE"
  run_root chmod 0640 "$HTPASSWD_FILE"
  if [[ -z "${PANEL_PASSWORD:-}" ]]; then
    info "generated Basic Auth password for '${BASIC_AUTH_USER}': ${auth_pw}"
  fi
fi

# ---------------------------------------------------------------------------
# 5. CSRF/session secret, readable only by root and PHP-FPM
# ---------------------------------------------------------------------------
if run_root test -f "$SESSION_SECRET_FILE"; then
  info "session secret already present: $SESSION_SECRET_FILE"
else
  run_root install -d -m 0750 "$(dirname -- "$SESSION_SECRET_FILE")"
  secret_tmp="$(mktemp)"
  printf '%s\n' "$(gen_password 48)" > "$secret_tmp"
  run_root install -o root -g www-data -m 0640 "$secret_tmp" "$SESSION_SECRET_FILE"
  rm -f "$secret_tmp"
  info "session secret generated: $SESSION_SECRET_FILE"
fi

# ---------------------------------------------------------------------------
# 6. sudoers drop-in limited to the panel-called scripts
# ---------------------------------------------------------------------------
sudo_src="${REPO_ROOT}/config/sudoers-panel.conf.example"
[[ -f "$sudo_src" ]] || fail "sudoers template missing: $sudo_src"
rendered="$(mktemp)"
sed "s|__REPO_ROOT__|${REPO_ROOT}|g" "$sudo_src" > "$rendered"
visudo -c -f "$rendered" >/dev/null 2>&1 || fail "rendered sudoers config failed validation — nothing installed"
install_if_changed "$rendered" "$SUDOERS_FILE" 0440
rm -f "$rendered"

# ---------------------------------------------------------------------------
# 7. Firewall — add the panel port; cloud security group is manual
# ---------------------------------------------------------------------------
run_root ufw allow "${PANEL_PORT}/tcp" >/dev/null
info "UFW allows ${PANEL_PORT}/tcp — open TCP ${PANEL_PORT} in the cloud security group manually"

# ---------------------------------------------------------------------------
# 7b. PHP-FPM sandbox exception
# ---------------------------------------------------------------------------
# Panel actions call these scripts via sudo from inside PHP-FPM. The packaged
# unit uses ProtectSystem=full, which makes /etc read-only; sudo changes the
# UID but the read-only mount namespace is inherited, so certbot's lock file
# (/etc/letsencrypt/.certbot.lock) and nginx vhost writes fail with EROFS.
if [[ "$PHP_FPM_SOCKET" =~ /run/php/php([0-9]+\.[0-9]+)-fpm\.sock$ ]]; then
  fpm_service="php${BASH_REMATCH[1]}-fpm"
else
  fpm_service="php-fpm"
fi
fpm_dropin_dir="/etc/systemd/system/${fpm_service}.service.d"
fpm_dropin="${fpm_dropin_dir}/10-wsa-panel.conf"
dropin_tmp="$(mktemp)"
cat > "$dropin_tmp" <<'EOF'
[Service]
# Required for panel actions that call sudo-guarded scripts: certbot needs
# /etc/letsencrypt writable, nginx vhosts live under /etc/nginx, and user
# management writes PHP-FPM pool configs under /etc/php.
ReadWritePaths=/etc/letsencrypt /etc/nginx /etc/php
EOF
if run_root test -f "$fpm_dropin" && run_root cmp -s "$dropin_tmp" "$fpm_dropin"; then
  info "php-fpm sandbox drop-in already up to date"
else
  run_root install -d -m 0755 "$fpm_dropin_dir"
  run_root install -m 0644 "$dropin_tmp" "$fpm_dropin"
  run_root systemctl daemon-reload
  run_root systemctl restart "$fpm_service"
  info "installed php-fpm sandbox exception; restarted $fpm_service"
fi
rm -f "$dropin_tmp"

# ---------------------------------------------------------------------------
# 8. Optional fail2ban jail for Basic Auth failures on the panel log
# ---------------------------------------------------------------------------
if [[ "$FAIL2BAN_ENABLED" == "1" ]]; then
  ensure_packages fail2ban
  jail="$(mktemp)"
  cat > "$jail" <<EOF
[wsa-panel]
enabled  = true
filter   = nginx-http-auth
port     = ${PANEL_PORT}
logpath  = ${PANEL_ERROR_LOG}
maxretry = ${FAIL2BAN_MAXRETRY}
findtime = ${FAIL2BAN_FINDTIME}
bantime  = ${FAIL2BAN_BANTIME}
backend  = auto
EOF
  run_root install -d -m 0755 /etc/fail2ban/jail.d
  install_if_changed "$jail" /etc/fail2ban/jail.d/wsa-panel.conf 0644
  rm -f "$jail"
  enable_service fail2ban
fi

# ---------------------------------------------------------------------------
# 9. Renewal hook — reload nginx so :8083 picks up renewed certificates
# ---------------------------------------------------------------------------
hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
run_root install -d -m 0755 "$hook_dir"
hook="$(mktemp)"
cat > "$hook" <<'HOOK'
#!/bin/sh
# Reload nginx after cert renewal so the panel listener uses the new cert.
nginx -t >/dev/null 2>&1 && systemctl reload nginx
HOOK
install_if_changed "$hook" "${hook_dir}/wsa-panel-reload" 0755
rm -f "$hook"

# ---------------------------------------------------------------------------
# 10. Config gate and conditional reload
# ---------------------------------------------------------------------------
config_test "nginx (panel)" nginx -t
reload_service nginx

log ""
log "== panel setup complete =="
info "URL: https://${PANEL_DOMAIN}:${PANEL_PORT}${ADMIN_PATH}/"
info "Basic Auth user: ${BASIC_AUTH_USER}"
info "Remember: open TCP ${PANEL_PORT} in the provider's cloud security group"
