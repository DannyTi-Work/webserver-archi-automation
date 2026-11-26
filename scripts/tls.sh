#!/usr/bin/env bash
# scripts/tls.sh — Let's Encrypt certificates for a domain (Phase 4).
# Usage:
#   bash scripts/tls.sh <domain>                 # production cert
#   LE_STAGING=1 bash scripts/tls.sh <domain>    # staging cert first
#   bash scripts/tls.sh --renew-dry-run          # renewal check, all certificates
#   bash scripts/tls.sh --renew-dry-run <domain>  # renewal check, one certificate
#
# `tls.sh <domain>` scopes its post-issue dry-run to that one lineage with
# --cert-name; only the explicit --renew-dry-run mode checks all domains.
#
# Renewal dry-runs pass --no-random-sleep-on-renew (certbot 2.x): otherwise
# certbot inserts a hidden 1-480s random delay per lineage, which makes a
# panel action time out even when the renewal itself succeeds.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/preflight.sh
source "${SCRIPT_DIR}/../lib/preflight.sh"

log "== tls.sh =="

# --renew-dry-run: verify renewal configuration without issuing a new cert.
# With a domain argument, scope the check to that one lineage; without one,
# check every certificate on the VPS.
if [[ "${1:-}" == "--renew-dry-run" ]]; then
  require_root
  if ! command -v certbot >/dev/null 2>&1; then
    fail "certbot is not installed — run tls.sh <domain> first"
  fi
  renew_target="${2:-}"
  if [[ -n "$renew_target" ]]; then
    is_valid_domain "$renew_target" || fail "invalid domain: $renew_target"
    [[ -f "/etc/letsencrypt/renewal/${renew_target}.conf" ]] || \
      fail "no certificate for $renew_target — run tls.sh $renew_target first"
    log "-- renewal dry-run for $renew_target (this certificate only) --"
    run_root certbot renew --cert-name "$renew_target" --no-random-sleep-on-renew --dry-run
  else
    log "-- renewal dry-run (all certificates) --"
    run_root certbot renew --no-random-sleep-on-renew --dry-run
  fi
  log "-- renewal timer --"
  if systemctl list-timers --no-pager 2>/dev/null | grep -q certbot.timer; then
    info "certbot.timer is active"
  else
    warn "certbot.timer not found — automatic renewal may not run"
  fi
  log "== renewal check complete =="
  exit 0
fi

domain="${1:-}"
if [[ -z "$domain" ]]; then
  printf 'usage: bash scripts/tls.sh <domain> | --renew-dry-run [<domain>]\n' >&2
  exit 2
fi

require_root
load_env || true

# Safety gate: DNS + LE reachability + NTP.
if ! preflight_check tls "$domain"; then
  fail "preflight failed — no changes made"
fi

# 1. Install certbot + nginx plugin if absent.
if ! command -v certbot >/dev/null 2>&1 || \
   ! certbot plugins 2>/dev/null | grep -q 'nginx'; then
  info "installing certbot + nginx plugin"
  run_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx
else
  info "certbot with nginx plugin already installed"
fi

# 2. Choose endpoint. Staging first to avoid production rate limits.
staging_mode=0
[[ "${LE_STAGING:-0}" == "1" ]] && staging_mode=1
staging_args=()
email_arg=()
if (( staging_mode )); then
  staging_args+=(--staging)
  info "using Let's Encrypt STAGING endpoint"
else
  info "using Let's Encrypt PRODUCTION endpoint"
fi

# Drop a stale cert config before issuing. Hestia left a 'webroot' renewal
# config pointing at a deleted path, and a staging cert must never be kept in
# production. A fresh issuance writes authenticator = nginx, which makes
# 'certbot renew --dry-run' work later.
renew_conf="/etc/letsencrypt/renewal/${domain}.conf"
live_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
vhost_conf="/etc/nginx/conf.d/${domain}.conf"
[[ -f /etc/nginx/sites-available/${domain}.conf ]] && \
  vhost_conf="/etc/nginx/sites-available/${domain}.conf"

stale_reason=""
# Detect a vhost left with SSL directives after the cert was deleted.
if [[ -f "$vhost_conf" ]] && grep -q 'ssl_certificate' "$vhost_conf" && \
   [[ ! -f "$live_cert" ]]; then
  stale_reason="vhost references a missing certificate"
elif [[ -f "$renew_conf" ]]; then
  if ! grep -q '^authenticator = nginx' "$renew_conf"; then
    stale_reason="renewal config is not nginx-authenticated (stale/leftover)"
  elif (( ! staging_mode )) && \
       openssl x509 -in "/etc/letsencrypt/live/${domain}/fullchain.pem" -noout -issuer 2>/dev/null | \
         grep -qi staging; then
    stale_reason="existing certificate is from staging"
  elif (( staging_mode )); then
    stale_reason="staging pass requested — replacing any existing certificate"
  fi
fi

# Other vhosts can reuse this certificate — notably the Phase 8 panel vhost
# on :8083. `certbot delete` removes the cert files but leaves their SSL
# directives behind, so `nginx -t` would fail before a replacement can be
# issued. Move those vhosts out of nginx's config tree for the duration of the
# swap; the EXIT trap puts them back even if issuance fails. The domain's own
# vhost is excluded because it is restored from the template below.
cert_swap_dir=""
cert_swap_restored=0

swap_borrowed_vhosts() {
  local cfg base saved idx=0 resolved_cfg resolved_own
  for cfg in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*.conf \
             /etc/nginx/sites-available/*.conf; do
    [[ -f "$cfg" || -L "$cfg" ]] || continue
    grep -qF "/etc/letsencrypt/live/${domain}/" "$cfg" 2>/dev/null || continue
    resolved_cfg="$(readlink -f -- "$cfg" 2>/dev/null || printf '%s' "$cfg")"
    resolved_own="$(readlink -f -- "$vhost_conf" 2>/dev/null || printf '%s' "$vhost_conf")"
    [[ "$resolved_cfg" == "$resolved_own" ]] && continue
    if [[ -z "$cert_swap_dir" ]]; then
      cert_swap_dir="$(mktemp -d /tmp/wsa-tls-cert-swap.XXXXXX)"
    fi
    base="$(basename -- "$cfg")"
    saved="${cert_swap_dir}/${idx}-${base}"
    printf '%s' "$cfg" > "${saved}.path"
    run_root mv -f -- "$cfg" "$saved"
    info "temporarily disabled vhost reusing the cert: $cfg"
    idx=$((idx + 1))
  done
}

restore_borrowed_vhosts() {
  (( cert_swap_restored )) && return 0
  cert_swap_restored=1
  [[ -n "$cert_swap_dir" && -d "$cert_swap_dir" ]] || return 0
  local saved target
  for saved in "${cert_swap_dir}"/*; do
    [[ -f "$saved" && "$saved" != *.path ]] || continue
    target="$(cat -- "${saved}.path" 2>/dev/null || true)"
    [[ -n "$target" ]] || continue
    run_root mkdir -p -- "$(dirname -- "$target")"
    run_root mv -f -- "$saved" "$target"
    rm -f -- "${saved}.path"
    info "restored vhost reusing the cert: $target"
  done
  rmdir -- "$cert_swap_dir" 2>/dev/null || true
}
trap restore_borrowed_vhosts EXIT

if [[ -n "$stale_reason" ]]; then
  info "removing existing cert ($stale_reason)"
  run_root certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 || true
  swap_borrowed_vhosts

  # certbot's --nginx plugin leaves SSL directives in the vhost pointing at
  # the deleted cert. Restore a clean HTTP-only vhost from the template first.
  tpl="${SCRIPT_DIR}/../templates/nginx-vhost.conf.tpl"
  [[ -f "$tpl" ]] || tpl="${REPO_ROOT}/templates/nginx-vhost.conf.tpl"
  fpm_socket="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1 || true)"
  if [[ -n "$fpm_socket" && -f "$tpl" ]]; then
    # Match add-domain.sh: include www.<domain> only when it resolves here,
    # otherwise the placeholder would be written literally into server_name
    # and status.sh would report "__SERVER_NAMES__" as a bogus domain.
    server_names="${domain}"
    www_ip="$(dig +short A "www.${domain}" @8.8.8.8 2>/dev/null | head -1 || true)"
    [[ -n "$www_ip" ]] && server_names="${domain} www.${domain}"
    clean_tmp="$(mktemp)"
    sed -e "s|__DOMAIN__|${domain}|g" \
        -e "s|__SERVER_NAMES__|${server_names}|g" \
        -e "s|__DOCROOT__|/var/www/${domain}/public_html|g" \
        -e "s|__PHP_SOCKET__|${fpm_socket}|g" \
        "$tpl" > "$clean_tmp"
    if [[ -d /etc/nginx/sites-available ]]; then
      run_root install -m 0644 "$clean_tmp" "/etc/nginx/sites-available/${domain}.conf"
    else
      run_root install -m 0644 "$clean_tmp" "/etc/nginx/conf.d/${domain}.conf"
    fi
    rm -f "$clean_tmp"
    info "restored clean HTTP-only vhost for $domain"
    config_test "nginx (post-restore)" nginx -t
    reload_service nginx
  fi
fi
if [[ -n "${LE_EMAIL:-}" ]]; then
  email_arg=(--email "$LE_EMAIL")
else
  email_arg=(--register-unsafely-without-email)
fi

# Only request www.<domain> if it actually resolves to this VPS — otherwise
# HTTP-01 validation for the www name would fail.
domain_args=(-d "$domain")
www_ip="$(dig +short A "www.${domain}" @8.8.8.8 2>/dev/null | head -1 || true)"
if [[ -n "$www_ip" ]]; then
  domain_args+=(-d "www.${domain}")
  info "including www.${domain} in certificate (resolves to $www_ip)"
else
  warn "www.${domain} does not resolve — requesting certificate for $domain only"
fi

# Gate nginx config before certbot rewrites it (after any stale cleanup).
config_test "nginx (pre-certbot)" nginx -t

# Install an EXISTING certificate into a vhost that lost its TLS directives
# (e.g. after remove-domain + add-domain recreated an HTTP-only vhost). This
# never re-issues — renewals update the same files and the deploy hook reloads
# nginx, so no Let's Encrypt quota is consumed just to restore the config.
deploy_existing_cert() {
  local tpl fpm tmp server_names
  tpl="${SCRIPT_DIR}/../templates/nginx-vhost-tls.conf.tpl"
  [[ -f "$tpl" ]] || tpl="${REPO_ROOT}/templates/nginx-vhost-tls.conf.tpl"
  [[ -f "$tpl" ]] || fail "TLS vhost template missing: templates/nginx-vhost-tls.conf.tpl"
  fpm="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1 || true)"
  [[ -n "$fpm" ]] || fail "no PHP-FPM socket found — was setup.sh run?"
  server_names="$domain"
  [[ " ${domain_args[*]} " == *" -d www.${domain} "* ]] && server_names="${domain} www.${domain}"
  tmp="$(mktemp)"
  sed -e "s|__DOMAIN__|${domain}|g" \
      -e "s|__SERVER_NAMES__|${server_names}|g" \
      -e "s|__DOCROOT__|/var/www/${domain}/public_html|g" \
      -e "s|__PHP_SOCKET__|${fpm}|g" \
      "$tpl" > "$tmp"
  run_root install -m 0644 "$tmp" "$vhost_conf"
  rm -f "$tmp"
  info "installed existing certificate into $vhost_conf (no re-issuance)"
  config_test "nginx (post-deploy)" nginx -t
  reload_service nginx
}

# 4. Issue the certificate. certbot --nginx edits vhosts and reloads nginx.
log "-- issuing certificate for $domain --"
# Detect whether the domain's vhost already has certbot's TLS directives.
vhost_has_tls=0
if [[ -f "$vhost_conf" ]] && grep -q 'ssl_certificate' "$vhost_conf"; then
  vhost_has_tls=1
fi

if [[ -f "$renew_conf" ]] && (( vhost_has_tls )); then
  # Cert and vhost are both in place — nothing to issue or deploy.
  info "existing certificate is valid and deployed — skipping issuance"
elif [[ -f "$renew_conf" ]]; then
  # Valid cert exists but vhost lost its TLS directives — install it instead
  # of burning a renewal against Let's Encrypt.
  info "existing certificate is valid but not deployed — installing it"
  deploy_existing_cert
else
  run_root certbot --nginx --non-interactive --agree-tos \
    --cert-name "$domain" \
    "${email_arg[@]}" "${staging_args[@]}" \
    "${domain_args[@]}"
fi

# The replacement cert now exists — put back any vhosts that were moved aside
# so they are covered by the post-certbot config test and reload below.
restore_borrowed_vhosts

# 5. Gate nginx config after certbot, then conditional reload.
config_test "nginx (post-certbot)" nginx -t
reload_service nginx

# 6. Verify HTTPS 200 and HTTP -> HTTPS redirect.
log "-- verification --"
https_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://${domain}/" || true)"
info "HTTPS ${domain}: ${https_code}"
if [[ -z "${LE_STAGING:-0}" || "${LE_STAGING:-0}" != "1" ]]; then
  redirect="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 15 "http://${domain}/" || true)"
  info "HTTP -> HTTPS: ${redirect}"
else
  info "staging cert: skipping strict HTTP-redirect assertion"
fi

# 7. Renewal dry-run — scoped to THIS certificate only. A bare `certbot renew`
# walks every lineage on the VPS (other sites and the reused panel cert), which
# is not what "add TLS for <domain>" should do. Use the explicit
# `--renew-dry-run` mode when an all-domain renewal check is actually wanted.
log "-- renewal dry-run (this certificate only) --"
run_root certbot renew --cert-name "$domain" --no-random-sleep-on-renew --dry-run

# 8. Renewal timer.
log "-- renewal timer --"
if systemctl list-timers --no-pager 2>/dev/null | grep -q certbot.timer; then
  info "certbot.timer is active"
else
  warn "certbot.timer not found — automatic renewal may not run"
fi

log "== tls complete for $domain =="
