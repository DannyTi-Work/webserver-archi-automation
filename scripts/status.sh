#!/usr/bin/env bash
# scripts/status.sh — machine-readable state dump for the web panel (Phase 8).
# Usage: bash scripts/status.sh [--json]
#   (no flag) : human-readable stack summary + domain table.
#   --json    : full state object consumed by scripts/panel/index.php.
#
# JSON contract (stable — the panel depends on these keys):
# {
#   "stack": {
#     "nginx": "active|inactive|failed|unknown",
#     "mariadb": "active|inactive|failed|unknown",
#     "php_fpm": "active|inactive|failed|unknown",
#     "php_version": "8.3", "fpm_service": "php8.3-fpm",
#     "certbot_timer": "active|inactive|failed|unknown",
#     "ufw": "active|inactive|unknown",
#     "default_reject": "present|absent"  (managed default_server config)
#   },
#   "domains": [
#     {
#       "domain": "...", "app": "static|wordpress", "wp_version": "",
#       "docroot": "...", "vhost_path": "...",
#       "database": "...", "db_user": "...",
#       "db_present": 0|1, "db_user_present": 0|1,
#       "cert_present": 0|1, "cert_expiry": "...", "cert_days_left": 0,
#       "cert_issuer": "...",
#       "http_status": "...", "https_status": "...",
#       "php_version": "...", "fpm_socket": "...",
#       "logs": {"access": "...", "error": "..."},
#       "last_access_log_line": "...", "last_error_log_line": "..."
#     }
#   ]
# }
# wp_version and cert_expiry/cert_days_left are "" when unavailable;
# cert_days_left is negative once the certificate has expired.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

json=0
[[ "${1:-}" == "--json" ]] && json=1

# ---------------------------------------------------------------------------
# Stack state
# ---------------------------------------------------------------------------
service_state() {
  local state
  state="$(systemctl is-active "$1" 2>/dev/null || true)"
  case "$state" in
    active|inactive|failed) printf '%s' "$state" ;;
    *)                      printf 'unknown' ;;
  esac
}

php_ver="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)"
[[ -z "$php_ver" ]] && php_ver="unknown"
fpm_socket="/run/php/php${php_ver}-fpm.sock"
if [[ ! -S "$fpm_socket" ]]; then
  for s in /run/php/php*-fpm.sock; do
    [[ -S "$s" ]] && { fpm_socket="$s"; break; }
  done
fi
if [[ "$php_ver" == "unknown" ]]; then
  fpm_service="unknown"
else
  fpm_service="php${php_ver}-fpm"
fi
if [[ "$fpm_socket" =~ /run/php/php([0-9]+\.[0-9]+)-fpm\.sock$ ]]; then
  fpm_service="php${BASH_REMATCH[1]}-fpm"
fi

stack_nginx="$(service_state nginx)"
stack_mariadb="$(service_state mariadb)"
stack_php_fpm="$(service_state "$fpm_service")"
stack_certbot="$(service_state certbot.timer)"
stack_ufw="$(ufw status 2>/dev/null | sed -n 's/^Status: //p' || true)"
[[ -z "$stack_ufw" ]] && stack_ufw="unknown"

default_reject="absent"
[[ -f /etc/nginx/conf.d/00-default-reject.conf ]] && default_reject="present"

# ---------------------------------------------------------------------------
# WordPress version: wp-cli first, then the site's own version.php, then the
# shared template metadata as a last resort (new sites copied from it).
# ---------------------------------------------------------------------------
wp_version_for() {
  local docroot="$1" ver=""
  if command -v wp >/dev/null 2>&1; then
    ver="$(wp core version --path="$docroot" --allow-root 2>/dev/null || true)"
  fi
  if [[ -z "$ver" && -f "${docroot}/wp-includes/version.php" ]]; then
    ver="$(grep -E '\$wp_version[[:space:]]*=' "${docroot}/wp-includes/version.php" 2>/dev/null \
      | head -1 | sed -E "s/.*'([^']+)'.*/\1/")"
  fi
  if [[ -z "$ver" && -f /var/lib/wsa/wordpress/.wsa-meta ]]; then
    ver="$(grep '^version=' /var/lib/wsa/wordpress/.wsa-meta 2>/dev/null | head -1 | cut -d= -f2)"
  fi
  printf '%s' "$ver"
}

# ---------------------------------------------------------------------------
# Domains — collect from both nginx layouts.
# ---------------------------------------------------------------------------
declare -a vhosts=()
for d in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*.conf; do
  [[ -f "$d" ]] || continue
  base="$(basename "$d")"
  # panel.conf is the Phase 8 admin listener, not a customer domain.
  [[ "$base" == "default.conf" || "$base" == "zz-sites-enabled.conf" || \
     "$base" == "panel.conf" || "$base" == "00-default-reject.conf" ]] && continue
  vhosts+=("$d")
done

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

cert_days_left() {
  local expiry="$1" exp_epoch
  [[ -z "$expiry" ]] && { printf ''; return 0; }
  exp_epoch="$(date -d "$expiry" +%s 2>/dev/null || true)"
  [[ -z "$exp_epoch" ]] && { printf ''; return 0; }
  printf '%s' "$(( (exp_epoch - $(date +%s)) / 86400 ))"
}

emit_json() {
  local d="$1" first="$2"
  local domain slug docroot vhost db dbuser db_present user_present
  local cert_path cert_present cert_expiry cert_issuer days_left
  local http_code https_code app wp_ver
  local access_log error_log last_access last_error

  domain="$(grep -m1 'server_name' "$d" | sed -E 's/.*server_name[[:space:]]+//; s/;.*//' | awk '{print $1}')"
  [[ -z "$domain" ]] && domain="$(basename "$d" .conf)"
  slug="$(domain_slug "$domain")"
  docroot="/var/www/${domain}/public_html"
  owner="admin"
  site_meta="/var/lib/wsa/sites/${domain}.meta"
  if [[ -f "$site_meta" ]]; then
    meta_docroot="$(grep -m1 '^DOCROOT=' "$site_meta" | cut -d= -f2-)"
    meta_owner="$(grep -m1 '^OWNER=' "$site_meta" | cut -d= -f2-)"
    [[ -n "$meta_docroot" ]] && docroot="$meta_docroot"
    [[ -n "$meta_owner" ]] && owner="$meta_owner"
  fi
  vhost="$d"
  db="${slug}_db"
  dbuser="${slug}_u"
  db_present=0; user_present=0
  db_exists "$db" 2>/dev/null && db_present=1
  db_user_exists "$dbuser" 2>/dev/null && user_present=1

  cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
  cert_present=0; cert_expiry=""; cert_issuer=""; days_left=""
  if [[ -f "$cert_path" ]]; then
    cert_present=1
    cert_expiry="$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)"
    cert_issuer="$(openssl x509 -in "$cert_path" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
    days_left="$(cert_days_left "$cert_expiry")"
  fi

  app="static"
  wp_ver=""
  [[ -f "${docroot}/wp-config.php" ]] && app="wordpress"
  [[ "$app" == "wordpress" ]] && wp_ver="$(wp_version_for "$docroot")"

  http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://${domain}/" 2>/dev/null)" || http_code="000"
  https_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${domain}/" 2>/dev/null)" || https_code="000"

  access_log="/var/log/nginx/${domain}.access.log"
  error_log="/var/log/nginx/${domain}.error.log"
  last_access=""; last_error=""
  [[ -f "$access_log" ]] && last_access="$(tail -1 "$access_log" 2>/dev/null || true)"
  [[ -f "$error_log" ]] && last_error="$(tail -1 "$error_log" 2>/dev/null || true)"

  printf '%s{\n' "$first"
  printf '  "domain": "%s",\n' "$(json_escape "$domain")"
  printf '  "owner": "%s",\n' "$(json_escape "$owner")"
  printf '  "app": "%s",\n' "$app"
  printf '  "wp_version": "%s",\n' "$(json_escape "$wp_ver")"
  printf '  "docroot": "%s",\n' "$(json_escape "$docroot")"
  printf '  "vhost_path": "%s",\n' "$(json_escape "$vhost")"
  printf '  "database": "%s",\n' "$db"
  printf '  "db_user": "%s",\n' "$dbuser"
  printf '  "db_present": %s,\n' "$db_present"
  printf '  "db_user_present": %s,\n' "$user_present"
  printf '  "cert_present": %s,\n' "$cert_present"
  printf '  "cert_expiry": "%s",\n' "$(json_escape "$cert_expiry")"
  printf '  "cert_days_left": "%s",\n' "$days_left"
  printf '  "cert_issuer": "%s",\n' "$(json_escape "$cert_issuer")"
  printf '  "http_status": "%s",\n' "$http_code"
  printf '  "https_status": "%s",\n' "$https_code"
  printf '  "php_version": "%s",\n' "$(json_escape "$php_ver")"
  printf '  "fpm_socket": "%s",\n' "$(json_escape "$fpm_socket")"
  printf '  "logs": {"access": "%s", "error": "%s"},\n' \
    "$(json_escape "$access_log")" "$(json_escape "$error_log")"
  printf '  "last_access_log_line": "%s",\n' "$(json_escape "$last_access")"
  printf '  "last_error_log_line": "%s"\n' "$(json_escape "$last_error")"
  printf '}'
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if (( json )); then
  printf '{\n'
  printf '  "stack": {\n'
  printf '    "nginx": "%s",\n' "$stack_nginx"
  printf '    "mariadb": "%s",\n' "$stack_mariadb"
  printf '    "php_fpm": "%s",\n' "$stack_php_fpm"
  printf '    "php_version": "%s",\n' "$(json_escape "$php_ver")"
  printf '    "fpm_service": "%s",\n' "$(json_escape "$fpm_service")"
  printf '    "certbot_timer": "%s",\n' "$stack_certbot"
  printf '    "ufw": "%s",\n' "$stack_ufw"
  printf '    "default_reject": "%s"\n' "$default_reject"
  printf '  },\n'
  printf '  "domains": [\n'
  first=1
  for v in "${vhosts[@]}"; do
    (( first )) || printf ',\n'
    emit_json "$v" "    "
    first=0
  done
  printf '\n  ]\n}\n'
  exit 0
fi

printf 'STACK  nginx=%s  mariadb=%s  php-fpm=%s  certbot.timer=%s  ufw=%s  default-reject=%s  (PHP %s, %s)\n' \
  "$stack_nginx" "$stack_mariadb" "$stack_php_fpm" "$stack_certbot" "$stack_ufw" \
  "$default_reject" "$php_ver" "$fpm_service"
printf '\n'
printf '%-36s %-10s %-8s %-6s %-8s %-6s %-8s\n' \
  "DOMAIN" "APP" "WP_VER" "DB" "CERT" "HTTP" "HTTPS"
printf '%-36s %-10s %-8s %-6s %-8s %-6s %-8s\n' \
  "------" "---" "------" "---" "----" "----" "-----"
for v in "${vhosts[@]}"; do
  domain="$(grep -m1 'server_name' "$v" | sed -E 's/.*server_name[[:space:]]+//; s/;.*//' | awk '{print $1}')"
  [[ -z "$domain" ]] && domain="$(basename "$v" .conf)"
  slug="$(domain_slug "$domain")"
  docroot="/var/www/${domain}/public_html"
  app="static"; wp_ver=""
  [[ -f "${docroot}/wp-config.php" ]] && app="wordpress"
  [[ "$app" == "wordpress" ]] && wp_ver="$(wp_version_for "$docroot")"
  db="${slug}_db"
  db_state="no"; db_exists "$db" 2>/dev/null && db_state="yes"
  cert_state="no"
  [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && cert_state="yes"
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://${domain}/" 2>/dev/null)" || http_code="000"
  https_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${domain}/" 2>/dev/null)" || https_code="000"
  printf '%-36s %-10s %-8s %-6s %-8s %-6s %-8s\n' \
    "$domain" "$app" "$wp_ver" "$db_state" "$cert_state" "$http_code" "$https_code"
done
