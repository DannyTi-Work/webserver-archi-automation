#!/usr/bin/env bash
# scripts/status.sh — machine-readable inventory of every provisioned domain (Phase 8).
# Usage: bash scripts/status.sh [--json]
#   Default: human-readable table.
#   --json : emit a JSON document (array of domain objects) for web control panels.
#
# Each domain object contains:
#   domain, app (static|wordpress), docroot, vhost_path,
#   database, db_user, db_present, db_user_present,
#   cert (present|missing), cert_expiry, cert_issuer,
#   http_status, https_status,
#   php_version, fpm_socket,
#   logs {access, error}, last_access_log_line, last_error_log_line
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

json=0
[[ "${1:-}" == "--json" ]] && json=1

php_ver="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)"
fpm_socket="/run/php/php${php_ver}-fpm.sock"

# Collect domains from both nginx layouts.
declare -a vhosts=()
for d in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*.conf; do
  [[ -f "$d" ]] || continue
  base="$(basename "$d")"
  [[ "$base" == "default.conf" || "$base" == "zz-sites-enabled.conf" ]] && continue
  vhosts+=("$d")
done

# Emit JSON for one domain.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

emit_json() {
  local d="$1" first="$2"
  local domain slug docroot vhost db dbuser db_present user_present
  local cert_path cert_present cert_expiry cert_issuer
  local http_code https_code
  local access_log error_log last_access last_error
  local app="static"
  domain="$(grep -m1 'server_name' "$d" | sed -E 's/.*server_name[[:space:]]+//; s/;.*//' | awk '{print $1}')"
  [[ -z "$domain" ]] && domain="$(basename "$d" .conf)"
  slug="$(domain_slug "$domain")"
  docroot="/var/www/${domain}/public_html"
  vhost="$d"
  db="${slug}_db"
  dbuser="${slug}_u"
  db_present=0; user_present=0
  if db_exists "$db" 2>/dev/null; then db_present=1; fi
  if db_user_exists "$dbuser" 2>/dev/null; then user_present=1; fi

  cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
  cert_present=0; cert_expiry=""; cert_issuer=""
  if [[ -f "$cert_path" ]]; then
    cert_present=1
    cert_expiry="$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)"
    cert_issuer="$(openssl x509 -in "$cert_path" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
  fi

  [[ -f "${docroot}/wp-config.php" ]] && app="wordpress"

  http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://${domain}/" 2>/dev/null || echo 000)"
  https_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${domain}/" 2>/dev/null || echo 000)"

  access_log="/var/log/nginx/${domain}.access.log"
  error_log="/var/log/nginx/${domain}.error.log"
  last_access=""
  last_error=""
  [[ -f "$access_log" ]] && last_access="$(tail -1 "$access_log" 2>/dev/null || true)"
  [[ -f "$error_log" ]] && last_error="$(tail -1 "$error_log" 2>/dev/null || true)"

  printf '%s{\n' "$first"
  printf '  "domain": "%s",\n' "$(json_escape "$domain")"
  printf '  "app": "%s",\n' "$app"
  printf '  "docroot": "%s",\n' "$(json_escape "$docroot")"
  printf '  "vhost_path": "%s",\n' "$(json_escape "$vhost")"
  printf '  "database": "%s",\n' "$db"
  printf '  "db_user": "%s",\n' "$dbuser"
  printf '  "db_present": %s,\n' "$db_present"
  printf '  "db_user_present": %s,\n' "$user_present"
  printf '  "cert_present": %s,\n' "$cert_present"
  printf '  "cert_expiry": "%s",\n' "$(json_escape "$cert_expiry")"
  printf '  "cert_issuer": "%s",\n' "$(json_escape "$cert_issuer")"
  printf '  "http_status": "%s",\n' "$http_code"
  printf '  "https_status": "%s",\n' "$https_code"
  printf '  "php_version": "%s",\n' "$php_ver"
  printf '  "fpm_socket": "%s",\n' "$fpm_socket"
  printf '  "logs": {"access": "%s", "error": "%s"},\n' "$access_log" "$error_log"
  printf '  "last_access_log_line": "%s",\n' "$(json_escape "$last_access")"
  printf '  "last_error_log_line": "%s"\n' "$(json_escape "$last_error")"
  printf '}'
}

if (( json )); then
  printf '[\n'
  first=1
  for v in "${vhosts[@]}"; do
    (( first )) || printf ',\n'
    emit_json "$v" ""
    first=0
  done
  printf '\n]\n'
  exit 0
fi

printf '%-40s %-10s %-6s %-8s %-6s %-8s\n' "DOMAIN" "APP" "DB" "CERT" "HTTP" "HTTPS"
printf '%-40s %-10s %-6s %-8s %-6s %-8s\n' "------" "---" "---" "----" "----" "-----"
for v in "${vhosts[@]}"; do
  domain="$(grep -m1 'server_name' "$v" | sed -E 's/.*server_name[[:space:]]+//; s/;.*//' | awk '{print $1}')"
  [[ -z "$domain" ]] && domain="$(basename "$v" .conf)"
  slug="$(domain_slug "$domain")"
  docroot="/var/www/${domain}/public_html"
  app="static"; [[ -f "${docroot}/wp-config.php" ]] && app="wordpress"
  db="${slug}_db"
  db_state="no"; db_exists "$db" 2>/dev/null && db_state="yes"
  cert_state="no"
  [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && cert_state="yes"
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://${domain}/" 2>/dev/null || echo 000)"
  https_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${domain}/" 2>/dev/null || echo 000)"
  printf '%-40s %-10s %-6s %-8s %-6s %-8s\n' "$domain" "$app" "$db_state" "$cert_state" "$http_code" "$https_code"
done