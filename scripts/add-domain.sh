#!/usr/bin/env bash
# scripts/add-domain.sh — provision one web domain (Phase 3, core feature).
# Usage: bash scripts/add-domain.sh <domain> [--app wordpress|static] [--db-pass PASSWORD]
#        (no domain) -> batch mode reading config/domains.conf (domain or domain|app)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/preflight.sh
source "${SCRIPT_DIR}/../lib/preflight.sh"

# This is when user runs add-domain.sh with a single domain argument, 
# e.g. `bash scripts/add-domain.sh example.com`.
# optional flags:
#   --app wordpress|static (default static)
#   --db-pass PASSWORD (optional, will generate if not provided)
#   --db NAME (attach an existing database created by scripts/databases.sh)
#   -h|--help (show usage)
domain=""
app=""
db_pass=""
db_name_opt=""
while (( $# )); do
  case "$1" in
    --app)
      app="${2:-}"
      shift 2
      ;;
    --db-pass)
      db_pass="${2:-}"
      shift 2
      ;;
    --db)
      db_name_opt="${2:-}"
      shift 2
      ;;
    -h|--help)
      printf 'usage: bash scripts/add-domain.sh <domain> [--app wordpress|static] [--db-pass PASSWORD] [--db NAME]\n'
      exit 0
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$domain" ]] || fail "unexpected argument: $1"
      domain="$1"
      shift
      ;;
  esac
done
if [[ -n "$app" && "$app" != "wordpress" && "$app" != "static" ]]; then
  fail "invalid --app value: $app (use wordpress or static)"
fi

# Batch mode: read config/domains.conf when no domain argument is given.
declare -a domains=()
declare -a domain_apps=()
if [[ -z "$domain" ]]; then
  if [[ ! -f "${REPO_ROOT}/config/domains.conf" ]]; then
    fail "no domain given and config/domains.conf not found"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    if [[ -z "$line" ]]; then
      continue
    fi
    d="${line%%|*}"
    a="${line#*|}"
    if [[ "$a" == "$line" ]]; then
      a=""
    fi
    if [[ -n "$app" ]]; then
      a="$app"
    fi
    [[ -z "$a" ]] && a="static"
    domains+=("$d")
    domain_apps+=("$a")
  done < "${REPO_ROOT}/config/domains.conf"
  if (( ${#domains[@]} == 0 )); then
    fail "config/domains.conf has no domains"
  fi
else
  domains+=("$domain")
  domain_apps+=("${app:-static}")
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

for i in "${!domains[@]}"; do
  domain="${domains[$i]}"
  dom_app="${domain_apps[$i]}"
  log ""
  log "-- domain: $domain (app: $dom_app) --"

  # Safety gate — DNS must resolve to this VPS; an existing domain is a hard fail.
  if ! preflight_check add-domain "$domain"; then
    fail "preflight failed for $domain — no changes made for this domain"
  fi

  slug="$(domain_slug "$domain")"
  db="${slug}_db"
  dbuser="${slug}_u"
  db_env_key="DB_PASS_${slug}"
  own_db=1
  db_meta=""
  if [[ -n "$db_name_opt" ]]; then
    # Attach an existing database from Database management instead of creating
    # a dedicated one. Its credentials come from the managed DB's .env entry.
    db_meta="/var/lib/wsa/databases/${db_name_opt}.meta"
    [[ -f "$db_meta" ]] || fail "database $db_name_opt is not managed by WSA — create it with scripts/databases.sh first"
    db="$(grep -m1 '^DB_NAME=' "$db_meta" | cut -d= -f2-)"
    dbuser="$(grep -m1 '^DB_USER=' "$db_meta" | cut -d= -f2-)"
    db_env_key="$(grep -m1 '^ENV_KEY=' "$db_meta" | cut -d= -f2-)"
    [[ -n "$db" && -n "$dbuser" && -n "$db_env_key" ]] || fail "incomplete metadata for database $db_name_opt"
    own_db=0
    info "using existing managed database: $db (user $dbuser)"
  fi
  docroot="/var/www/${domain}/public_html"
  vhost_name="${domain}.conf"

  # 1. Resolve the DB password first — the marker file needs it.
  pass_var="$db_env_key"
  if [[ -z "$db_pass" ]]; then
    db_pass="${!pass_var:-}"
  fi
  if [[ -z "$db_pass" ]]; then
    if (( own_db )); then
      db_pass="$(gen_password)"
      set_env_var "$db_env_key" "$db_pass"
      run_root chmod 600 "${REPO_ROOT}/.env"
      info "generated DB password stored in .env as $db_env_key"
    else
      fail "no password for $db in .env ($db_env_key) — rotate it in Database management"
    fi
  fi
  db_pass_sql="$(sql_quote "$db_pass")"
  pass_escaped="$(printf '%s' "$db_pass" | sed -e 's/[\\&|]/\\&/g')"

  # 2. Docroot.
  run_root mkdir -p "$docroot"
  run_root chown -R www-data:www-data "/var/www/${domain}"
  run_root chmod -R 755 "/var/www/${domain}"

  # 3. App-specific content.
  if [[ "$dom_app" == "wordpress" ]]; then
    wp_template="/var/lib/wsa/wordpress"
    if [[ ! -f "${wp_template}/wp-settings.php" ]]; then
      fail "WordPress template missing at $wp_template — run scripts/prepare-wordpress.sh first"
    fi
    if run_root test -f "${docroot}/wp-settings.php"; then
      info "WordPress already present in $docroot — skipping copy (preserving content)"
    else
      run_root cp -a "${wp_template}/." "${docroot}/"
      info "WordPress template copied into $docroot"
    fi
    run_root chown -R www-data:www-data "$docroot"
    run_root find "$docroot" -type d -exec chmod 0755 {} +
    run_root find "$docroot" -type f -exec chmod 0644 {} +

    wp_config="${docroot}/wp-config.php"
    if run_root test -f "$wp_config"; then
      # Re-assert the DB password if .env was regenerated but the site config
      # was preserved — otherwise MariaDB and wp-config.php drift apart.
      if run_root grep -qF "define( 'DB_PASSWORD', '${db_pass}' );" "$wp_config"; then
        info "wp-config.php already exists and credentials match — skipping"
      else
        run_root sed -i "s|define( 'DB_PASSWORD', '[^']*' );|define( 'DB_PASSWORD', '${pass_escaped}' );|" "$wp_config"
        info "wp-config.php DB password re-asserted to match .env"
      fi
    else
      if [[ -f "${SCRIPT_DIR}/../templates/wp-config.php.tpl" ]]; then
        wptpl="${SCRIPT_DIR}/../templates/wp-config.php.tpl"
      else
        wptpl="${REPO_ROOT}/templates/wp-config.php.tpl"
      fi
      salts_tmp="$(mktemp)"
      : > "$salts_tmp"
      for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
                 AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        printf "define( '%s', '%s' );\n" "$key" "$(gen_password 48)" >> "$salts_tmp"
      done
      wc_tmp="$(mktemp)"
      sed -e "s|__DB_NAME__|${db}|g" \
          -e "s|__DB_USER__|${dbuser}|g" \
          -e "s|__DB_PASSWORD__|${db_pass}|g" \
          -e "s|__TABLE_PREFIX__|${slug}_wp_|g" \
          "$wptpl" > "$wc_tmp"
      wc_final="$(mktemp)"
      awk -v s="$salts_tmp" '
        index($0, "__SALTS__") {
          while ((getline line < s) > 0) print line
          close(s)
          next
        }
        { print }
      ' "$wc_tmp" > "$wc_final"
      run_root install -o www-data -g www-data -m 0640 "$wc_final" "$wp_config"
      rm -f "$salts_tmp" "$wc_tmp" "$wc_final"
      info "wp-config.php generated for $domain (prefix ${slug}_wp_)"
    fi
  else
    # Static site marker: proves which vhost answered, PHP works, DB is reachable.
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
    sed -i "s|__DB_PASS__|${pass_escaped}|" "$marker_tmp"
    if run_root test -f "${docroot}/index.php" && \
       run_root cmp -s "$marker_tmp" "${docroot}/index.php"; then
      info "marker file already up to date — skipping"
    else
      run_root install -o www-data -g www-data -m 0644 "$marker_tmp" "${docroot}/index.php"
      info "marker file created/updated at ${docroot}/index.php"
    fi
    rm -f "$marker_tmp"
  fi

  # 4. Database + least-privilege user. With --db, the database already exists
  #    in Database management — just record that this domain now uses it.

  run_root install -d -m 0755 /var/lib/wsa/databases
  if (( own_db )); then
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
    meta_tmp="$(mktemp)"
    printf 'DB_NAME=%s\nDB_USER=%s\nENV_KEY=%s\nATTACHED_TO=%s\n' \
      "$db" "$dbuser" "$db_env_key" "$domain" > "$meta_tmp"
    run_root install -o root -g root -m 0644 "$meta_tmp" "/var/lib/wsa/databases/${db}.meta"
    rm -f "$meta_tmp"
    info "database $db registered in Database management (attached to $domain)"
  else
    meta_tmp="$(mktemp)"
    awk -v v="$domain" '
      index($0, "ATTACHED_TO=") == 1 { print "ATTACHED_TO=" v; done = 1; next }
      { print }
      END { if (!done) print "ATTACHED_TO=" v }
    ' "$db_meta" > "$meta_tmp"
    run_root install -o root -g root -m 0644 "$meta_tmp" "$db_meta"
    rm -f "$meta_tmp"
    info "database $db attached to $domain"
  fi

  # 4. nginx vhost from template.
  if [[ -f "${SCRIPT_DIR}/../templates/nginx-vhost.conf.tpl" ]]; then
    tpl="${SCRIPT_DIR}/../templates/nginx-vhost.conf.tpl"
  else
    tpl="${REPO_ROOT}/templates/nginx-vhost.conf.tpl"
  fi
  # Include www.<domain> in server_name when it resolves to this VPS so
  # certbot can install a certificate covering both names.
  server_names="${domain}"
  www_ip="$(dig +short A "www.${domain}" @8.8.8.8 2>/dev/null | head -1 || true)"
  if [[ -n "$www_ip" ]]; then
    server_names="${domain} www.${domain}"
  fi
  vhost_tmp="$(mktemp)"
  sed -e "s|__DOMAIN__|${domain}|g" \
      -e "s|__SERVER_NAMES__|${server_names}|g" \
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

  if run_root test -f "$target"; then
    if run_root grep -q 'ssl_certificate' "$target"; then
      # certbot owns the TLS directives now — never overwrite them.
      info "vhost is TLS-enabled: $target — skipping (preserving certbot config)"
    elif run_root cmp -s "$vhost_tmp" "$target"; then
      info "vhost already up to date: $target — skipping"
    else
      run_root install -m 0644 "$vhost_tmp" "$target"
      info "vhost updated: $target"
    fi
  else
    run_root install -m 0644 "$vhost_tmp" "$target"
    info "vhost created: $target"
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

  log "done: $domain (app $dom_app, docroot $docroot, DB $db, user $dbuser)"
done

log ""
log "== add-domain complete =="
