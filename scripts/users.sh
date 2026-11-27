#!/usr/bin/env bash
# scripts/users.sh — Hestia-style user accounts with OS-level isolation.
# Usage:
#   bash scripts/users.sh --json
#   bash scripts/users.sh create <user> [--role admin|user] [--password PASS]
#   bash scripts/users.sh ensure <user>       # repair a missing FPM pool
#   bash scripts/users.sh suspend <user>
#   bash scripts/users.sh unsuspend <user>
#   bash scripts/users.sh delete <user> [--yes] [--force]
#   bash scripts/users.sh passwd <user> [--password PASS]
#
# Each user gets a real Linux account, a dedicated PHP-FPM pool and a home
# directory. Domains/databases record an OWNER so they can be scoped to a user.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/preflight.sh
source "${SCRIPT_DIR}/../lib/preflight.sh"

USERS_DIR="/var/lib/wsa/users"
DOMAIN_META_DIR="/var/lib/wsa/databases"   # DB metadata lives here
SITE_META_DIR="/var/lib/wsa/sites"         # domain ownership metadata

valid_user() { [[ "${1:-}" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; }

json_escape() {
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

meta_path() { printf '%s/%s.meta' "$USERS_DIR" "$1"; }

meta_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2- || true
}

write_meta() {
  local user="$1" role="$2" state="$3" home_dir="$4" socket="$5" pool="$6"
  run_root install -d -m 0755 "$USERS_DIR"
  local tmp
  tmp="$(mktemp)"
  printf 'USER=%s\nROLE=%s\nSTATE=%s\nHOME_DIR=%s\nFPM_SOCKET=%s\nPOOL_CONF=%s\nDB_PREFIX=%s_\n' \
    "$user" "$role" "$state" "$home_dir" "$socket" "$pool" "$user" > "$tmp"
  run_root install -o root -g root -m 0644 "$tmp" "$(meta_path "$user")"
  rm -f "$tmp"
}

meta_set() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" > "$tmp"
  run_root install -o root -g root -m 0644 "$tmp" "$file"
  rm -f "$tmp"
}

php_pool_details() {
  PHPM_VER="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)"
  [[ -n "$PHPM_VER" ]] || fail "cannot detect PHP version"
  PHPM_POOL_DIR="/etc/php/${PHPM_VER}/fpm/pool.d"
  PHPM_FPM_BIN="$(command -v "php-fpm${PHPM_VER}" || command -v php-fpm || true)"
  [[ -n "$PHPM_FPM_BIN" ]] || fail "php-fpm binary not found"
  PHPM_SERVICE="php${PHPM_VER}-fpm"
}

fpm_gate_and_reload() {
  config_test "php-fpm (user pool)" "$PHPM_FPM_BIN" -t
  reload_service "$PHPM_SERVICE"
}

# shadow-utils locks /etc/passwd (and /etc/group) while editing accounts. A
# concurrent useradd/userdel can make it fail with "cannot lock /etc/passwd;
# try again later". Retry briefly instead of failing the whole panel action.
account_op() {
  local label="$1"; shift
  local attempt
  for attempt in 1 2 3 4 5; do
    if run_root "$@"; then
      return 0
    fi
    if [[ -f /etc/passwd.lock || -f /etc/group.lock ]]; then
      info "account database locked, retrying $label ($attempt/5)"
      sleep 2
    else
      return 1
    fi
  done
  warn "account database stayed locked while trying to $label — try again later"
  return 1
}

# Render a user's PHP-FPM pool from metadata. Used by create and by ensure
# (which repairs a missing pool, e.g. after an interrupted delete).
write_pool() {
  local user="$1" socket="$2" home_dir="$3" pool="$4" tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<POOL
[${user}]
user = ${user}
group = ${user}
listen = ${socket}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 10s
pm.max_requests = 500
chdir = ${home_dir}
POOL
  run_root install -o root -g root -m 0644 "$tmp" "$pool"
  rm -f "$tmp"
}

# Count domains / databases owned by a user (from their metadata).
owned_count() {
  local user="$1" n=0 meta
  for meta in "$SITE_META_DIR"/*.meta "$DOMAIN_META_DIR"/*.meta; do
    [[ -f "$meta" ]] || continue
    [[ "$(grep -m1 '^OWNER=' "$meta" 2>/dev/null | cut -d= -f2-)" == "$user" ]] && n=$((n + 1))
  done
  printf '%s' "$n"
}

lock_user_dbs() {
  local user="$1" mode="$2" meta dbu
  for meta in "$SITE_META_DIR"/*.meta "$DOMAIN_META_DIR"/*.meta; do
    [[ -f "$meta" ]] || continue
    [[ "$(grep -m1 '^OWNER=' "$meta" 2>/dev/null | cut -d= -f2-)" == "$user" ]] || continue
    dbu="$(grep -m1 '^DB_USER=' "$meta" 2>/dev/null | cut -d= -f2-)"
    [[ -n "$dbu" ]] || continue
    if db_user_exists "$dbu"; then
      run_root mariadb -e "ALTER USER '$(sql_quote "$dbu")'@'localhost' ACCOUNT ${mode};"
      info "database user $dbu ${mode,,}"
    fi
  done
}

# ---------------------------------------------------------------------------
# --json: inventory for the panel's Users tab
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--json" ]]; then
  require_root
  printf '{"users":['
  first=1
  if [[ -d "$USERS_DIR" ]]; then
    for meta in "$USERS_DIR"/*.meta; do
      [[ -f "$meta" ]] || continue
      user="$(meta_get "$meta" USER)"
      [[ -n "$user" ]] || continue
      role="$(meta_get "$meta" ROLE)"; state="$(meta_get "$meta" STATE)"
      socket="$(meta_get "$meta" FPM_SOCKET)"
      (( first )) || printf ','
      first=0
      printf '{"user":"%s","role":"%s","state":"%s","socket":"%s","owned":%s,"os_user":%s}' \
        "$(json_escape "$user")" "$(json_escape "$role")" "$(json_escape "$state")" \
        "$(json_escape "$socket")" "$(owned_count "$user")" \
        "$(id -u "$user" >/dev/null 2>&1 && printf 1 || printf 0)"
    done
  fi
  printf ']}\n'
  exit 0
fi

cmd="${1:-}"
[[ -n "$cmd" ]] || { printf 'usage: users.sh <--json|create|ensure|suspend|unsuspend|delete|passwd> ...\n' >&2; exit 2; }
shift

case "$cmd" in
  create)
    user="${1:-}"
    valid_user "$user" || fail "invalid user name: '${user:-<empty>}' (lowercase letters/digits/-/_; max 32)"
    shift
    role="user"; pass=""
    while (( $# )); do
      case "$1" in
        --role) role="${2:-}"; shift 2 ;;
        --password) pass="${2:-}"; shift 2 ;;
        *) fail "unknown option: $1" ;;
      esac
    done
    [[ "$role" == "admin" || "$role" == "user" ]] || fail "invalid role: $role"
    require_root
    load_env || true
    [[ ! -f "$(meta_path "$user")" ]] || { info "user $user already managed — nothing to do"; exit 0; }
    if id -u "$user" >/dev/null 2>&1; then
      fail "Linux user $user already exists — refusing to take it over"
    fi
    php_pool_details
    home_dir="/home/${user}"
    socket="/run/php/${user}-fpm.sock"
    pool="${PHPM_POOL_DIR}/${user}.conf"

    info "creating Linux user $user"
    account_op "create user $user" useradd --home-dir "$home_dir" --create-home --shell /usr/sbin/nologin "$user" || \
      fail "could not create Linux user $user — account database may be locked"

    if [[ -z "$pass" ]]; then
      pass="$(gen_password)"
      printf '%s\n' "$pass" > "${USERS_DIR}/${user}.password"
    fi
    run_root install -d -m 0700 "$USERS_DIR"
    run_root htpasswd -nbB "$user" "$pass" > "${USERS_DIR}/${user}.htpasswd"
    run_root chmod 0600 "${USERS_DIR}/${user}.htpasswd"
    [[ -f "${USERS_DIR}/${user}.password" ]] && run_root chmod 0600 "${USERS_DIR}/${user}.password"

    write_pool "$user" "$socket" "$home_dir" "$pool"
    fpm_gate_and_reload
    write_meta "$user" "$role" active "$home_dir" "$socket" "$pool"
    if [[ -f "${USERS_DIR}/${user}.password" ]]; then
      info "generated login password saved at ${USERS_DIR}/${user}.password (mode 600)"
    fi
    log "done: user $user (role $role, socket $socket)"
    ;;

  ensure)
    # Repair an existing managed user whose pool file went missing.
    user="${1:-}"
    valid_user "$user" || fail "invalid user: $user"
    [[ -f "$(meta_path "$user")" ]] || fail "user $user is not managed by WSA"
    require_root
    php_pool_details
    state="$(meta_get "$(meta_path "$user")" STATE)"
    [[ "$state" == "active" ]] || fail "user $user is $state — unsuspend it first"
    socket="$(meta_get "$(meta_path "$user")" FPM_SOCKET)"
    home_dir="$(meta_get "$(meta_path "$user")" HOME_DIR)"
    pool="$(meta_get "$(meta_path "$user")" POOL_CONF)"
    [[ -n "$socket" && -n "$pool" ]] || fail "incomplete metadata for user $user"
    if [[ ! -f "$pool" ]]; then
      write_pool "$user" "$socket" "${home_dir:-/home/$user}" "$pool"
      fpm_gate_and_reload
      info "restored missing PHP-FPM pool for $user"
    else
      info "PHP-FPM pool already present for $user"
    fi
    id -u "$user" >/dev/null 2>&1 || fail "Linux user $user is missing — recreate the user"
    for _wait in 1 2 3 4 5; do
      [[ -S "$socket" ]] && break
      sleep 1
    done
    [[ -S "$socket" ]] || warn "socket $socket not present yet — pool will start on first use"
    log "done: user $user ready"
    ;;

  suspend|unsuspend)
    user="${1:-}"
    valid_user "$user" || fail "invalid user: $user"
    [[ -f "$(meta_path "$user")" ]] || fail "user $user is not managed by WSA"
    require_root
    php_pool_details
    state="active"; src_suffix=""; dst_suffix=""
    if [[ "$cmd" == "suspend" ]]; then
      state="suspended"; src_suffix=""; dst_suffix=".disabled"
      lock_user_dbs "$user" LOCK
    else
      src_suffix=".disabled"; dst_suffix=""
      lock_user_dbs "$user" UNLOCK
    fi
    pool="$(meta_get "$(meta_path "$user")" POOL_CONF)"
    if [[ -n "$pool" && -f "${pool}${src_suffix}" ]]; then
      run_root mv -f "${pool}${src_suffix}" "${pool}${dst_suffix}"
      info "PHP-FPM pool ${pool}${dst_suffix:-} ${state}"
      fpm_gate_and_reload
    else
      info "no pool file to ${cmd} for $user"
    fi
    meta_set "$(meta_path "$user")" STATE "$state"
    log "done: user $user $state"
    ;;

  delete)
    user="${1:-}"
    valid_user "$user" || fail "invalid user: $user"
    shift
    assume_yes=0; force=0
    while (( $# )); do
      case "$1" in
        --yes) assume_yes=1; shift ;;
        --force) force=1; shift ;;
        *) fail "unknown option: $1" ;;
      esac
    done
    [[ -f "$(meta_path "$user")" ]] || fail "user $user is not managed by WSA"
    require_root
    php_pool_details
    count="$(owned_count "$user")"
    if (( count > 0 )) && (( ! force )); then
      fail "user $user still owns $count resource(s) — remove them first or use --force"
    fi
    if (( ! assume_yes )); then
      warn "about to PERMANENTLY delete user: $user"
      printf 'type the user name to confirm: '
      read -r confirm
      [[ "$confirm" == "$user" ]] || fail "confirmation did not match — nothing deleted"
    fi
    pool="$(meta_get "$(meta_path "$user")" POOL_CONF)"
    for p in "$pool" "${pool}.disabled"; do
      [[ -n "$p" && -f "$p" ]] && run_root rm -f "$p"
    done
    fpm_gate_and_reload
    if id -u "$user" >/dev/null 2>&1; then
      account_op "delete user $user" userdel -r "$user" || warn "could not remove Linux user $user — remove it manually"
    fi
    run_root rm -f "$(meta_path "$user")" "${USERS_DIR}/${user}.htpasswd" "${USERS_DIR}/${user}.password"
    log "done: user $user deleted"
    ;;

  passwd)
    user="${1:-}"
    valid_user "$user" || fail "invalid user: $user"
    shift
    pass=""
    while (( $# )); do
      case "$1" in
        --password) pass="${2:-}"; shift 2 ;;
        *) fail "unknown option: $1" ;;
      esac
    done
    [[ -f "$(meta_path "$user")" ]] || fail "user $user is not managed by WSA"
    [[ -n "$pass" ]] || fail "--password is required"
    require_root
    run_root install -d -m 0700 "$USERS_DIR"
    run_root htpasswd -nbB "$user" "$pass" > "${USERS_DIR}/${user}.htpasswd"
    run_root chmod 0600 "${USERS_DIR}/${user}.htpasswd"
    log "done: password updated for $user"
    ;;

  *)
    printf 'usage: users.sh <--json|create|ensure|suspend|unsuspend|delete|passwd> ...\n' >&2
    exit 2
    ;;
esac
