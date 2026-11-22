#!/usr/bin/env bash
# lib/common.sh — shared helpers sourced by every automation script.
# Usage: source "${REPO_ROOT}/lib/common.sh"
# Do not execute this file directly.

if [[ -n "${_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
_COMMON_SH_LOADED=1

COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${COMMON_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Privilege handling
#   require_root() accepts root or passwordless sudo and sets SUDO for run_root.
#   run_root() must wrap every mutating command.
# ---------------------------------------------------------------------------
SUDO=()

require_root() {
  if (( EUID == 0 )); then
    SUDO=()
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    SUDO=(sudo -n)
    return 0
  fi
  fail "must run as root or with passwordless sudo (try: sudo bash $0)"
}

run_root() {
  "${SUDO[@]}" "$@"
}

# Reload a service only when it is active (paired with config_test gates).
reload_service() {
  local svc="$1"
  if systemctl is-active --quiet "$svc"; then
    run_root systemctl reload "$svc"
  else
    info "$svc not active — skipping reload"
  fi
}

# ---------------------------------------------------------------------------
# Config test gate — never reload/restart a service without this passing.
#   config_test "nginx" nginx -t
# ---------------------------------------------------------------------------
config_test() {
  local label="$1"
  shift
  if run_root "$@"; then
    info "${label}: config OK"
  else
    fail "${label}: config test FAILED — refusing to reload/restart"
  fi
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
is_valid_domain() {
  local domain="${1:-}"
  [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

# Convert a domain to a safe MariaDB identifier, e.g. test1.example.com -> test1_example_com
domain_slug() {
  local slug="${1//./_}"
  slug="${slug//-/_}"
  printf '%s\n' "$slug"
}

# ---------------------------------------------------------------------------
# MariaDB helpers (root uses unix_socket auth on Ubuntu 24.04)
# ---------------------------------------------------------------------------
sql_quote() {
  printf '%s' "${1:-}" | sed "s/'/''/g"
}

db_user_exists() {
  local user="$1"
  local host="${2:-localhost}"
  local count
  count="$(run_root mariadb -N -B -e \
    "SELECT COUNT(*) FROM mysql.user WHERE user='$(sql_quote "$user")' AND host='$(sql_quote "$host")';" \
    2>/dev/null || printf '0')"
  [[ "$count" != "0" ]]
}

db_exists() {
  local db="$1"
  local count
  count="$(run_root mariadb -N -B -e \
    "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(sql_quote "$db")';" \
    2>/dev/null || printf '0')"
  [[ "$count" != "0" ]]
}

# ---------------------------------------------------------------------------
# Idempotent file helpers
# ---------------------------------------------------------------------------
ensure_dir() {
  mkdir -p -- "$1"
}

# Set KEY=VALUE in an env file, replacing an existing line for KEY (no duplicates).
set_env_var() {
  local key="$1" value="$2" file="${3:-${REPO_ROOT}/.env}"
  ensure_dir "$(dirname -- "$file")"
  touch -- "$file"
  local tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    index($0, k "=") == 1 {
      if (!done) { print k "=" v; done = 1 }
      next
    }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Append $2 to $1 only if not already present (exact-line match). Always returns 0.
append_line_once() {
  local file="$1"
  local line="$2"
  ensure_dir "$(dirname -- "$file")"
  touch -- "$file"
  if grep -Fqx -- "$line" "$file"; then
    return 0
  fi
  printf '%s\n' "$line" >> "$file"
}

# Write stdin to $1 only if the file does not exist. Always returns 0.
write_file_once() {
  local file="$1"
  if [[ -e "$file" ]]; then
    return 0
  fi
  ensure_dir "$(dirname -- "$file")"
  cat > "$file"
}

symlink_if_missing() {
  local target="$1"
  local link="$2"
  if [[ -e "$link" || -L "$link" ]]; then
    return 0
  fi
  ensure_dir "$(dirname -- "$link")"
  ln -s -- "$target" "$link"
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
gen_password() {
  local len="${1:-24}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '/+=\n' | head -c "$len"
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$len"
  fi
}

# Source the first available local .env (repo root, then config/). Never commit it.
load_env() {
  local candidate
  for candidate in "${REPO_ROOT}/.env" "${REPO_ROOT}/config/.env"; do
    if [[ -f "$candidate" ]]; then
      set -a
      # shellcheck disable=SC1090
      source "$candidate"
      set +a
      return 0
    fi
  done
  return 1
}
