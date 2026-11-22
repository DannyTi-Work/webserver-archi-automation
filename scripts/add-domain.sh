#!/usr/bin/env bash
# scripts/add-domain.sh — provision one web domain (Phase 3, core feature).
# Usage: bash scripts/add-domain.sh <domain> [--db-pass PASSWORD]
#        (no domain) -> batch mode reading config/domains.conf
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/preflight.sh
source "${SCRIPT_DIR}/../lib/preflight.sh"

domain="${1:-}"
if [[ "${2:-}" == "--db-pass" ]]; then
  db_pass="${3:-}"
else
  db_pass=""
fi

# Batch mode: read config/domains.conf when no domain argument is given.
declare -a domains=()
if [[ -z "$domain" ]]; then
  if [[ ! -f "${REPO_ROOT}/config/domains.conf" ]]; then
    fail "no domain given and config/domains.conf not found"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] && domains+=("$line")
  done < "${REPO_ROOT}/config/domains.conf"
  if (( ${#domains[@]} == 0 )); then
    fail "config/domains.conf has no domains"
  fi
else
  domains+=("$domain")
fi

log "== add-domain.sh =="

# require_root sets the SUDO array used by run_root; load_env is best-effort.
require_root
load_env || true

# Resolve PHP-FPM socket at runtime (8.3 on Ubuntu packages, 8.6 here, etc.).
detect_php_socket() {
  local ver sock
  if command -v php >/dev/null 2>&1; then
    ver="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)"
    sock="/run/php/php${ver}-fpm.sock"
    if [[ -S "$sock" ]]; then
      printf '%s' "$sock"
      return 0
    fi
  fi
  for sock in /run/php/php*-fpm.sock; do
    [[ -S "$sock" ]] && { printf '%s' "$sock"; return 0; }
  done
  return 1
}

fpm_socket="$(detect_php_socket || true)"
if [[ -z "$fpm_socket" ]]; then
  fail "no PHP-FPM socket found in /run/php — was setup.sh run?"
fi

# nginx layout: Ubuntu uses sites-available/sites-enabled; nginx.org uses conf.d.
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
if [[ -d "$NGINX_AVAIL" && -d "$NGINX_ENABLED" ]]; then
  vhost_layout="sites"
else
  vhost_layout="confd"
fi

# Ensure an include for sites-enabled exists in conf.d layout.
if [[ "$vhost_layout" == "confd" ]] && \
   ! grep -Rqs 'sites-enabled' /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf 2>/dev/null; then
  run_root tee /etc/nginx/conf.d/zz-sites-enabled.conf >/dev/null <<'CONF'
include /etc/nginx/sites-enabled/*.conf;
CONF
  info "added nginx include for /etc/nginx/sites-enabled/*.conf"
fi

for domain in "${domains[@]}"; do
  log ""
  log "-- domain: $domain --"

  # Safety gate — DNS must resolve to this VPS, duplicate check warns.
  if ! preflight_check domain "$domain"; then
    fail "preflight failed for $domain — no changes made for this domain"
  fi

  slug="$(domain_slug "$domain")"
  db="${slug}_db"
  dbuser="${slug}_u"
  docroot="/var/www/${domain}/public_html"
  vhost_name="${domain}.conf"

  # 1. Resolve the DB password first — the marker file needs it.
  pass_var="DB_PASS_${slug}"
  if [[ -z "$db_pass" ]]; then
    db_pass="${!pass_var:-}"
  fi
  if [[ -z "$db_pass" ]]; then
    db_pass="$(gen_password)"
    set_env_var "DB_PASS_${slug}" "$db_pass"
    run_root chmod 600 "${REPO_ROOT}/.env"
    info "generated DB password stored in .env as DB_PASS_${slug}"
  fi
  db_pass_sql="$(sql_quote "$db_pass")"

  # 2. Docroot.
  run_root mkdir -p "$docroot"
  run_root chown -R www-data:www-data "/var/www/${domain}"
  run_root chmod -R 755 "/var/www/${domain}"

  # 3. Marker file that proves which vhost answered, PHP works, DB is reachable.
  marker_tmp="$(mktemp)"
  cat > "$marker_tmp" <<PHP
<?php
echo "<h1>${domain}</h1>\n";
echo "PHP OK: " . PHP_VERSION . "<br>\n";
try {
    \$db = new mysqli('localhost', '${dbuser}', '__DB_PASS__', '${db}');
    echo "DB OK";
} catch (Throwable \$e) {
    echo "DB FAIL: " . \$e->getMessage();
}
PHP
  # Replace the password placeholder safely (escapes for sed replacement).
  pass_escaped="$(printf '%s' "$db_pass" | sed -e 's/[\\&|]/\\&/g')"
  sed -i "s|__DB_PASS__|${pass_escaped}|" "$marker_tmp"
  if run_root test -f "${docroot}/index.php" && \
     run_root cmp -s "$marker_tmp" "${docroot}/index.php"; then
    info "marker file already up to date — skipping"
  else
    run_root install -o www-data -g www-data -m 0644 "$marker_tmp" "${docroot}/index.php"
    info "marker file created/updated at ${docroot}/index.php"
  fi
  rm -f "$marker_tmp"

  # 4. Database + least-privilege user.

  if ! db_exists "$db"; then
    run_root mariadb -e "CREATE DATABASE \`${db}\`;"
    info "database created: $db"
  else
    info "database already exists: $db — skipping"
  fi
  if ! db_user_exists "$dbuser"; then
    run_root mariadb -e "CREATE USER '${dbuser}'@'localhost' IDENTIFIED BY '${db_pass_sql}';"
    info "database user created: $dbuser"
  else
    # Re-assert credential so .env and MariaDB never drift (e.g. .env was lost
    # and a new password was generated on a re-run).
    run_root mariadb -e "ALTER USER '${dbuser}'@'localhost' IDENTIFIED BY '${db_pass_sql}';"
    info "database user exists: $dbuser — password re-asserted"
  fi
  run_root mariadb -e "GRANT ALL ON \`${db}\`.* TO '${dbuser}'@'localhost'; FLUSH PRIVILEGES;"

  # 4. nginx vhost from template.
  if [[ -f "${SCRIPT_DIR}/../templates/nginx-vhost.conf.tpl" ]]; then
    tpl="${SCRIPT_DIR}/../templates/nginx-vhost.conf.tpl"
  else
    tpl="${REPO_ROOT}/templates/nginx-vhost.conf.tpl"
  fi
  vhost_tmp="$(mktemp)"
  sed -e "s|__DOMAIN__|${domain}|g" \
      -e "s|__DOCROOT__|${docroot}|g" \
      -e "s|__PHP_SOCKET__|${fpm_socket}|g" \
      "$tpl" > "$vhost_tmp"

  if [[ "$vhost_layout" == "sites" ]]; then
    run_root mkdir -p "$NGINX_AVAIL" "$NGINX_ENABLED"
    target="${NGINX_AVAIL}/${vhost_name}"
    link="${NGINX_ENABLED}/${vhost_name}"
  else
    target="/etc/nginx/conf.d/${vhost_name}"
    link=""
  fi

  if run_root test -f "$target" && run_root cmp -s "$vhost_tmp" "$target"; then
    info "vhost already up to date: $target — skipping"
  else
    run_root install -m 0644 "$vhost_tmp" "$target"
    if run_root test -f "$target"; then
      info "vhost updated: $target"
    else
      info "vhost created: $target"
    fi
  fi
  rm -f "$vhost_tmp"

  if [[ -n "$link" ]]; then
    if run_root test -e "$link" || run_root test -L "$link"; then
      info "site already enabled: $link"
    else
      run_root ln -s "$target" "$link"
      info "site enabled: $link"
    fi
  fi

  # 5. Config-test gate, then conditional reload (never a blind restart).
  config_test "nginx" nginx -t
  reload_service nginx

  log "done: $domain (docroot $docroot, DB $db, user $dbuser)"
done

log ""
log "== add-domain complete =="
