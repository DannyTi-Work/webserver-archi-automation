#!/usr/bin/env bash
# scripts/databases.sh — manage MariaDB databases independently of domains.
# Usage:
#   bash scripts/databases.sh --json
#   bash scripts/databases.sh create <name> [--user USER] [--pass PASS]
#   bash scripts/databases.sh delete <name> [--yes] [--force]
#   bash scripts/databases.sh attach <db> <domain>
#
# A created database is recorded under /var/lib/wsa/databases/<name>.meta so
# the panel can list it and know whether a domain is using it. "attach" wires
# an existing (possibly empty) database into a WordPress site's wp-config.php.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/preflight.sh
source "${SCRIPT_DIR}/../lib/preflight.sh"

META_DIR="/var/lib/wsa/databases"

json_escape() {
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

valid_db_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_]{1,60}$ ]]
}

meta_path() { printf '%s/%s.meta' "$META_DIR" "$1"; }

meta_get() {
  local name="$1" key="$2" file
  file="$(meta_path "$name")"
  [[ -f "$file" ]] || return 0
  grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2- || true
}

meta_set() {
  local name="$1" key="$2" value="$3" file tmp
  file="$(meta_path "$name")"
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

write_meta() {
  local name="$1" user="$2" env_key="$3" attached="${4:--}" owner="${5:-admin}"
  run_root install -d -m 0755 "$META_DIR"
  local tmp
  tmp="$(mktemp)"
  printf 'DB_NAME=%s\nDB_USER=%s\nENV_KEY=%s\nATTACHED_TO=%s\nOWNER=%s\n' \
    "$name" "$user" "$env_key" "$attached" "$owner" > "$tmp"
  run_root install -o root -g root -m 0644 "$tmp" "$(meta_path "$name")"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# --json: inventory for the panel's Databases tab
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--json" ]]; then
  require_root
  load_env || true
  printf '{"databases":['
  first=1
  if [[ -d "$META_DIR" ]]; then
    for meta in "$META_DIR"/*.meta; do
      [[ -f "$meta" ]] || continue
      name="$(meta_get "$(basename "$meta" .meta)" DB_NAME)"
      user="$(meta_get "$(basename "$meta" .meta)" DB_USER)"
      env_key="$(meta_get "$(basename "$meta" .meta)" ENV_KEY)"
      attached="$(meta_get "$(basename "$meta" .meta)" ATTACHED_TO)"
      owner="$(meta_get "$(basename "$meta" .meta)" OWNER)"
      [[ -z "$name" ]] && continue
      db_present=0; user_present=0; pass_present=0
      db_exists "$name" 2>/dev/null && db_present=1
      [[ -n "$user" ]] && db_user_exists "$user" 2>/dev/null && user_present=1
      if [[ -n "$env_key" ]] && [[ -n "${!env_key:-}" ]]; then pass_present=1; fi
      (( first )) || printf ','
      first=0
      printf '{"name":"%s","user":"%s","env_key":"%s","password_present":%d,"attached_to":"%s","owner":"%s","db_present":%d,"user_present":%d}' \
        "$(json_escape "$name")" "$(json_escape "$user")" "$(json_escape "$env_key")" \
        "$pass_present" "$(json_escape "${attached:--}")" "$(json_escape "${owner:-admin}")" \
        "$db_present" "$user_present"
    done
  fi
  printf ']}\n'
  exit 0
fi

log "== databases.sh =="

cmd="${1:-}"
[[ -n "$cmd" ]] || { printf 'usage: databases.sh <--json|create|delete|attach> ...\n' >&2; exit 2; }
shift

case "$cmd" in
  create)
    name="${1:-}"
    valid_db_name "$name" || fail "invalid database name: '${name:-<empty>}' (use letters, digits, underscore; max 60)"
    shift
    user=""; pass=""; owner=""
    while (( $# )); do
      case "$1" in
        --user) user="${2:-}"; shift 2 ;;
        --pass) pass="${2:-}"; shift 2 ;;
        --owner) owner="${2:-}"; shift 2 ;;
        *) fail "unknown option: $1" ;;
      esac
    done
    require_root
    load_env || true
    if [[ -n "$owner" ]]; then
      owner_meta="/var/lib/wsa/users/${owner}.meta"
      [[ -f "$owner_meta" ]] || fail "user $owner is not managed by WSA"
      [[ "$(grep -m1 '^STATE=' "$owner_meta" | cut -d= -f2-)" == "active" ]] || fail "user $owner is suspended"
      prefix="$(grep -m1 '^DB_PREFIX=' "$owner_meta" | cut -d= -f2-)"
      name="${prefix}${name}"
      valid_db_name "$name" || fail "prefixed database name is invalid: $name"
    else
      owner="admin"
    fi
    valid_db_name "${user:-${name}_u}" || fail "invalid database user"
    user="${user:-${name}_u}"
    env_key="DB_PASS_DB_${name}"
    if [[ -z "$pass" ]]; then
      pass="${!env_key:-}"
    fi
    if [[ -z "$pass" ]]; then
      pass="$(gen_password)"
      set_env_var "$env_key" "$pass"
      info "generated password stored in .env as $env_key"
    else
      set_env_var "$env_key" "$pass"
    fi
    run_root chmod 600 "${REPO_ROOT}/.env" 2>/dev/null || true
    pass_sql="$(sql_quote "$pass")"

    if db_exists "$name"; then
      info "database already exists: $name — skipping"
    else
      run_root mariadb -e "CREATE DATABASE \`${name}\`;"
      info "database created: $name"
    fi
    if db_user_exists "$user"; then
      run_root mariadb -e "ALTER USER '$(sql_quote "$user")'@'localhost' IDENTIFIED BY '${pass_sql}';"
      info "database user exists: $user — password re-asserted"
    else
      run_root mariadb -e "CREATE USER '$(sql_quote "$user")'@'localhost' IDENTIFIED BY '${pass_sql}';"
      info "database user created: $user"
    fi
    run_root mariadb -e "GRANT ALL ON \`${name}\`.* TO '$(sql_quote "$user")'@'localhost'; FLUSH PRIVILEGES;"
    attached="-"
    [[ -f "$(meta_path "$name")" ]] && attached="$(meta_get "$name" ATTACHED_TO)"
    write_meta "$name" "$user" "$env_key" "$attached" "$owner"
    log "done: database $name (user $user, env $env_key)"
    ;;

  delete)
    name="${1:-}"
    valid_db_name "$name" || fail "invalid database name: $name"
    shift
    assume_yes=0; force=0
    while (( $# )); do
      case "$1" in
        --yes) assume_yes=1; shift ;;
        --force) force=1; shift ;;
        *) fail "unknown option: $1" ;;
      esac
    done
    require_root
    load_env || true
    [[ -f "$(meta_path "$name")" ]] || fail "database $name is not managed by WSA — refusing to delete"
    attached="$(meta_get "$name" ATTACHED_TO)"
    if [[ -n "$attached" && "$attached" != "-" ]] && (( ! force )); then
      fail "database $name is attached to $attached — detach it first (or use --force)"
    fi
    user="$(meta_get "$name" DB_USER)"
    env_key="$(meta_get "$name" ENV_KEY)"
    if (( ! assume_yes )); then
      warn "about to PERMANENTLY delete database: $name"
      printf 'type the database name to confirm: '
      read -r confirm
      [[ "$confirm" == "$name" ]] || fail "confirmation did not match — nothing deleted"
    fi
    if [[ -n "$user" ]] && db_user_exists "$user"; then
      run_root mariadb -e "DROP USER '$(sql_quote "$user")'@'localhost';"
      info "database user dropped: $user"
    fi
    if db_exists "$name"; then
      run_root mariadb -e "DROP DATABASE \`${name}\`;"
      info "database dropped: $name"
    fi
    [[ -n "$env_key" ]] && unset_env_var "$env_key"
    run_root chmod 600 "${REPO_ROOT}/.env" 2>/dev/null || true
    run_root rm -f "$(meta_path "$name")"
    log "done: database $name deleted"
    ;;

  attach)
    db="${1:-}"
    domain="${2:-}"
    valid_db_name "$db" || fail "invalid database name: $db"
    is_valid_domain "$domain" || fail "invalid domain: $domain"
    require_root
    load_env || true
    [[ -f "$(meta_path "$db")" ]] || fail "database $db is not managed by WSA"
    db_exists "$db" || fail "database $db does not exist"
    docroot="/var/www/${domain}/public_html"
    wp_config="${docroot}/wp-config.php"
    [[ -f "$wp_config" ]] || fail "no WordPress config at $wp_config — add the site first (App=wordpress)"
    user="$(meta_get "$db" DB_USER)"
    env_key="$(meta_get "$db" ENV_KEY)"
    pass="${!env_key:-}"
    [[ -n "$user" && -n "$pass" ]] || fail "credentials missing in .env for $db ($env_key)"
    pass_escaped="$(printf '%s' "$pass" | sed -e 's/[\\&|]/\\&/g')"
    run_root sed -i \
      -e "s|define( 'DB_NAME', '[^']*' );|define( 'DB_NAME', '$(sql_quote "$db")' );|" \
      -e "s|define( 'DB_USER', '[^']*' );|define( 'DB_USER', '$(sql_quote "$user")' );|" \
      -e "s|define( 'DB_PASSWORD', '[^']*' );|define( 'DB_PASSWORD', '${pass_escaped}' );|" \
      "$wp_config"
    # A domain uses one DB at a time — release any previous attachment.
    for meta in "$META_DIR"/*.meta; do
      [[ -f "$meta" ]] || continue
      [[ "$meta" == "$(meta_path "$db")" ]] && continue
      if [[ "$(grep -m1 '^ATTACHED_TO=' "$meta" | cut -d= -f2-)" == "$domain" ]]; then
        old_tmp="$(mktemp)"
        awk '{ if (index($0,"ATTACHED_TO=")==1) print "ATTACHED_TO=-"; else print }' "$meta" > "$old_tmp"
        run_root install -o root -g root -m 0644 "$old_tmp" "$meta"
        rm -f "$old_tmp"
        info "detached previous database $(basename "$meta" .meta) from $domain"
      fi
    done
    meta_set "$db" ATTACHED_TO "$domain"
    info "attached database $db (user $user) to WordPress at $domain"
    log "done: $db -> $domain"
    ;;

  *)
    printf 'usage: databases.sh <--json|create|delete|attach> ...\n' >&2
    exit 2
    ;;
esac
