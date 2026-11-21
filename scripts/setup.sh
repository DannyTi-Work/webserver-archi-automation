#!/usr/bin/env bash
# scripts/setup.sh — base system + LEMP stack (Phase 2).
# Runs on the VPS itself. Safe to re-run: packages, services and config are guarded.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/preflight.sh
source "${SCRIPT_DIR}/../lib/preflight.sh"

# ---------------------------------------------------------------------------
# Safety gate — nothing mutates until preflight passes.
# ---------------------------------------------------------------------------
if ! preflight_check base; then
  fail "preflight failed — no changes were made"
fi
require_root

MARK_DIR="/var/lib/webserver-archi-automation"

# ---------------------------------------------------------------------------
# Small idempotency helpers (kept local to setup.sh; shared helpers live in lib/common.sh)
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

service_active()  { systemctl is-active --quiet "$1"; }
service_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

enable_service() {
  local svc="$1"
  if service_enabled "$svc"; then
    info "$svc already enabled"
  else
    run_root systemctl enable "$svc"
  fi
  if service_active "$svc"; then
    info "$svc already running"
  else
    run_root systemctl start "$svc"
  fi
}

reload_service() {
  local svc="$1"
  if service_active "$svc"; then
    run_root systemctl reload "$svc"
  else
    info "$svc not active — skipping reload"
  fi
}

log "== setup.sh: base + LEMP =="

# ---------------------------------------------------------------------------
# 1. apt + base packages
# ---------------------------------------------------------------------------
info "updating apt index"
run_root apt-get update -qq
ensure_packages curl ca-certificates dnsutils unzip git

# ---------------------------------------------------------------------------
# 2. UFW — allow SSH before enabling to avoid lockout
# ---------------------------------------------------------------------------
ensure_packages ufw
run_root ufw allow 22/tcp   >/dev/null
run_root ufw allow 80/tcp   >/dev/null
run_root ufw allow 443/tcp  >/dev/null
# ufw.service can be "active" while the firewall itself is disabled (ENABLED=no),
# so check rules state, not the systemd unit.
if run_root ufw status 2>/dev/null | grep -q '^Status: active'; then
  info "UFW already active"
else
  run_root ufw --force enable >/dev/null
  info "UFW enabled"
fi

# ---------------------------------------------------------------------------
# 3. chrony — time sync (TLS issuance depends on it)
# ---------------------------------------------------------------------------
ensure_packages chrony
enable_service chrony
synced=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  state="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  [[ -z "$state" ]] && state="$(timedatectl show -p NTP --value 2>/dev/null || true)"
  if [[ "$state" == "yes" ]]; then
    synced=1
    break
  fi
  sleep 2
done
if (( synced )); then
  info "clock synchronized"
else
  warn "clock not yet synchronized — cert issuance in Phase 4 may fail until it is"
fi

# ---------------------------------------------------------------------------
# 4. nginx
# ---------------------------------------------------------------------------
ensure_packages nginx
enable_service nginx

if [[ -L /etc/nginx/sites-enabled/default || -e /etc/nginx/sites-enabled/default ]]; then
  run_root rm -f /etc/nginx/sites-enabled/default
  info "removed nginx default site"
else
  info "nginx default site already absent"
fi

config_test "nginx" nginx -t
reload_service nginx

# ---------------------------------------------------------------------------
# 5. MariaDB — install, enable, harden (once)
# ---------------------------------------------------------------------------
ensure_packages mariadb-server
enable_service mariadb

if run_root test -f "${MARK_DIR}/mariadb-hardened"; then
  info "MariaDB already hardened — skipping"
else
  root_plugin="$(run_root mariadb -N -B -e \
    "SELECT plugin FROM mysql.user WHERE user='root' AND host='localhost';" 2>/dev/null || true)"
  case "$root_plugin" in
    unix_socket|auth_socket)
      info "MariaDB root uses socket auth"
      ;;
    *)
      warn "MariaDB root plugin is '${root_plugin:-unknown}' — setting unix_socket auth"
      run_root mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;"
      ;;
  esac

  run_root mariadb <<'SQL'
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
SQL

  run_root install -d -m 0750 "$MARK_DIR"
  run_root touch "${MARK_DIR}/mariadb-hardened"
  info "MariaDB hardened (anonymous users and test database removed)"
fi

# ---------------------------------------------------------------------------
# 6. PHP-FPM + extensions
# ---------------------------------------------------------------------------
ensure_packages php-fpm php-cli php-mysql php-curl php-mbstring php-xml php-zip php-gd php-intl

php_ver="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)"
if [[ -z "$php_ver" ]]; then
  fail "could not determine PHP version after install"
fi
fpm_service="php${php_ver}-fpm"
if command -v "php-fpm${php_ver}" >/dev/null 2>&1; then
  fpm_bin="php-fpm${php_ver}"
else
  fpm_bin="php-fpm"
fi

enable_service "$fpm_service"
config_test "php-fpm ($fpm_bin)" "$fpm_bin" -t
reload_service "$fpm_service"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log ""
log "== setup complete =="
info "PHP ${php_ver}, FPM service ${fpm_service}, socket /run/php/php${php_ver}-fpm.sock"
info "nginx: $(systemctl is-active nginx), MariaDB: $(systemctl is-active mariadb), ${fpm_service}: $(systemctl is-active "$fpm_service")"
info "next: bash scripts/add-domain.sh <domain>  (Phase 3)"
