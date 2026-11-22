#!/usr/bin/env bash
# scripts/remove-domain.sh — remove one provisioned domain (Phase 6).
# Usage: bash scripts/remove-domain.sh <domain> [--yes]
#        --yes skips the interactive confirmation (for automation).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/preflight.sh
source "${SCRIPT_DIR}/../lib/preflight.sh"

domain="${1:-}"
assume_yes=0
[[ "${2:-}" == "--yes" ]] && assume_yes=1
if [[ -z "$domain" ]]; then
  printf 'usage: bash scripts/remove-domain.sh <domain> [--yes]\n' >&2
  exit 2
fi

log "== remove-domain.sh =="

# Same safety profile as add-domain: format/DNS must still be valid.
if ! preflight_check domain "$domain"; then
  fail "preflight failed — nothing was removed"
fi
require_root
load_env || true

slug="$(domain_slug "$domain")"
db="${slug}_db"
dbuser="${slug}_u"
docroot="/var/www/${domain}"
vhost_sites="/etc/nginx/sites-available/${domain}.conf"
link_sites="/etc/nginx/sites-enabled/${domain}.conf"
vhost_confd="/etc/nginx/conf.d/${domain}.conf"
vhost=""
for candidate in "$link_sites" "$vhost_sites" "$vhost_confd"; do
  if run_root test -e "$candidate" || run_root test -L "$candidate"; then
    vhost="$candidate"
    break
  fi
done

# Nothing to do? Idempotent success.
if [[ -z "$vhost" ]] && ! run_root test -d "$docroot" && \
   ! db_exists "$db" && ! db_user_exists "$dbuser"; then
  info "$domain: no vhost, docroot, DB or user found — nothing to remove"
  log "== remove-domain complete =="
  exit 0
fi

# Explicit confirmation.
if (( ! assume_yes )); then
  warn "about to PERMANENTLY remove: $domain"
  printf 'type the domain name to confirm: '
  read -r confirm
  [[ "$confirm" == "$domain" ]] || fail "confirmation did not match — nothing removed"
fi

# 1. Disable the vhost (remove symlink/file) before touching data.
if [[ -n "$vhost" ]]; then
  run_root rm -f "$vhost"
  info "vhost disabled: $vhost"
  # Remove the sites-available source too when the enabled link was removed.
  if [[ "$vhost" == "$link_sites" ]] && run_root test -e "$vhost_sites"; then
    run_root rm -f "$vhost_sites"
    info "vhost config removed: $vhost_sites"
  fi
else
  info "no vhost found — skipping"
fi

# 2. nginx config gate BEFORE reload — if it fails, config is left untouched.
config_test "nginx" nginx -t
reload_service nginx

# 3. Remove docroot + per-domain logs.
if run_root test -d "$docroot"; then
  run_root rm -rf "$docroot"
  info "docroot removed: $docroot"
else
  info "docroot absent: $docroot"
fi
for logfile in "/var/log/nginx/${domain}.access.log" "/var/log/nginx/${domain}.error.log"; do
  if run_root test -e "$logfile"; then
    run_root rm -f "$logfile"
    info "log removed: $logfile"
  fi
done

# 4. Drop the dedicated DB + least-privilege user.
if db_user_exists "$dbuser"; then
  run_root mariadb -e "DROP USER '$(sql_quote "$dbuser")'@'localhost';"
  info "database user dropped: $dbuser"
else
  info "database user absent: $dbuser"
fi
if db_exists "$db"; then
  run_root mariadb -e "DROP DATABASE \`${db}\`;"
  info "database dropped: $db"
else
  info "database absent: $db"
fi
unset_env_var "DB_PASS_${slug}"
run_root chmod 600 "${REPO_ROOT}/.env" 2>/dev/null || true
info "credential entry removed from .env"

log ""
log "== remove-domain complete: $domain =="
