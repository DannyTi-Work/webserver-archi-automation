#!/usr/bin/env bash
# tests/manual-test.sh — guided end-to-end test of the toolchain.
# Run ON THE VPS as root, from the repo directory.
#
# Usage:
#   bash tests/manual-test.sh [domain] [--app wordpress|static] [--yes] [--keep]
#
#   domain          domain to provision and remove (default: <public-ip>.nip.io)
#   --app           static (default) or wordpress
#   --yes           do not ask before destructive steps
#   --keep          leave the domain provisioned at the end (skip removal)
#
# Each phase prints [OK] / [FAIL] / [SKIP]. Nothing destructive happens without
# confirmation unless --yes is passed.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

PASS=0; FAIL=0; SKIP=0
ok()   { printf '[OK]   %s\n' "$*"; PASS=$((PASS + 1)); }
no()   { printf '[FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '[SKIP] %s\n' "$*"; SKIP=$((SKIP + 1)); }
step() { printf '\n=== %s ===\n' "$*"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi; }

DOMAIN=""
APP="static"
ASSUME_YES=0
KEEP=0
while (( $# )); do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *)  [[ -z "$DOMAIN" ]] || { printf 'unexpected argument: %s\n' "$1" >&2; exit 2; }; DOMAIN="$1"; shift ;;
  esac
done

if [[ "$APP" != "static" && "$APP" != "wordpress" ]]; then
  printf 'invalid --app: %s (use static or wordpress)\n' "$APP" >&2
  exit 2
fi

# Default domain: nip.io wildcard pointing at this VPS public IP.
if [[ -z "$DOMAIN" ]]; then
  ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    printf 'could not detect public IP; pass a domain explicitly\n' >&2
    exit 2
  fi
  DOMAIN="${ip//./-}.nip.io"
fi

printf 'manual test\n  repo:   %s\n  domain: %s\n  app:    %s\n' "$REPO_ROOT" "$DOMAIN" "$APP"

confirm() {
  local prompt="$1"
  (( ASSUME_YES )) && return 0
  local answer
  read -r -p "${prompt} [y/N] " answer || return 1
  [[ "$answer" == [yY]* ]]
}

if (( ! ASSUME_YES )) && [[ ! -t 0 ]]; then
  printf 'not a terminal: re-run with --yes to skip prompts\n' >&2
  exit 2
fi

# ---------------------------------------------------------------------------
step "1. Environment"
# ---------------------------------------------------------------------------
check "running as root" test "$(id -u)" = 0
for f in scripts/preflight.sh scripts/setup.sh scripts/add-domain.sh scripts/tls.sh \
         scripts/remove-domain.sh scripts/install.sh tests/smoke.sh \
         templates/nginx-vhost.conf.tpl; do
  check "present: $f" test -f "${REPO_ROOT}/$f"
done
for f in "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/lib/*.sh "${REPO_ROOT}"/tests/*.sh; do
  check "syntax: $(basename "$f")" bash -n "$f"
done
if [[ "$APP" == "wordpress" ]]; then
  check "present: scripts/prepare-wordpress.sh" test -f "${REPO_ROOT}/scripts/prepare-wordpress.sh"
  check "present: templates/wp-config.php.tpl" test -f "${REPO_ROOT}/templates/wp-config.php.tpl"
fi

# ---------------------------------------------------------------------------
step "2. Preflight (base) — read only"
# ---------------------------------------------------------------------------
if ( cd "$REPO_ROOT" && bash scripts/preflight.sh base >/tmp/mt-preflight.log 2>&1 ); then
  ok "preflight base passed"
else
  no "preflight base failed — see /tmp/mt-preflight.log"
  grep -E '^\[FAIL\]' /tmp/mt-preflight.log || true
fi

# ---------------------------------------------------------------------------
step "3. Stack state"
# ---------------------------------------------------------------------------
for svc in nginx mariadb chrony; do
  check "service active: $svc" systemctl is-active --quiet "$svc"
done
php_ver="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)"
if [[ -n "$php_ver" ]]; then
  ok "php version: $php_ver"
  check "service active: php${php_ver}-fpm" systemctl is-active --quiet "php${php_ver}-fpm"
  check "fpm socket present" test -S "/run/php/php${php_ver}-fpm.sock"
else
  no "php not installed"
fi
check "nginx -t passes" nginx -t

# ---------------------------------------------------------------------------
step "4. DNS for $DOMAIN"
# ---------------------------------------------------------------------------
if [[ "$DOMAIN" == *.nip.io ]]; then
  ok "nip.io domain — DNS resolves dynamically (no setup needed)"
else
  resolved="$(dig +short A "$DOMAIN" @8.8.8.8 2>/dev/null | head -1)"
  public_ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    no "DNS does not resolve: $DOMAIN"
  elif [[ -n "$public_ip" && "$resolved" != "$public_ip" ]]; then
    no "DNS points to $resolved, this VPS is $public_ip"
  else
    ok "DNS resolves to this VPS ($resolved)"
  fi
fi

# ---------------------------------------------------------------------------
step "5. Provision $DOMAIN ($APP)"
# ---------------------------------------------------------------------------
slug="${DOMAIN//./_}"; slug="${slug//-/_}"
docroot="/var/www/${DOMAIN}/public_html"

if confirm "Provision $DOMAIN now?"; then
  if [[ "$APP" == "wordpress" ]] && [[ ! -f /var/lib/wsa/wordpress/wp-settings.php ]]; then
    printf -- '-- downloading shared WordPress template --\n'
    bash "${REPO_ROOT}/scripts/prepare-wordpress.sh" || no "prepare-wordpress.sh failed"
  fi

  if ( cd "$REPO_ROOT" && bash scripts/add-domain.sh "$DOMAIN" --app "$APP" >/tmp/mt-add.log 2>&1 ); then
    ok "add-domain.sh completed"
  else
    no "add-domain.sh failed — see /tmp/mt-add.log"
    grep -E '^\[(FAIL|WARN)\]' /tmp/mt-add.log | tail -5 || true
  fi

  check "docroot exists" test -d "$docroot"
  check "vhost exists" bash -c "ls /etc/nginx/conf.d/${DOMAIN}.conf /etc/nginx/sites-available/${DOMAIN}.conf >/dev/null 2>&1"
  check "database exists" bash -c "mariadb -N -B -e \"SHOW DATABASES LIKE '${slug}_db'\" | grep -q ."
  check "db user exists" bash -c "mariadb -N -B -e \"SELECT user FROM mysql.user WHERE user='${slug}_u'\" | grep -q ."
  check "one .env password entry" bash -c "test \"\$(grep -c '^DB_PASS_${slug}=' '${REPO_ROOT}/.env')\" = 1"

  if [[ "$APP" == "wordpress" ]]; then
    check "wp-config.php present" test -f "${docroot}/wp-config.php"
    check "wp-settings.php present" test -f "${docroot}/wp-settings.php"
    check "wp-config has per-domain prefix" grep -q "${slug}_wp_" "${docroot}/wp-config.php"
    check "wp-config has 8 salts" bash -c "test \"\$(grep -cE \"^define\\( '(AUTH|SECURE_AUTH|LOGGED_IN|NONCE)_(KEY|SALT)'\" '${docroot}/wp-config.php')\" = 8"
  else
    check "marker page present" test -f "${docroot}/index.php"
  fi
else
  skip "provisioning skipped by user"
fi

# ---------------------------------------------------------------------------
step "6. HTTP before TLS"
# ---------------------------------------------------------------------------
http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "http://${DOMAIN}/" 2>/dev/null || true)"
if [[ "$http_code" =~ ^(200|301|302)$ ]]; then
  ok "http://${DOMAIN}/ -> ${http_code}"
else
  no "http://${DOMAIN}/ -> '${http_code}'"
fi

# ---------------------------------------------------------------------------
step "7. TLS (production)"
# ---------------------------------------------------------------------------
if confirm "Issue a production certificate for $DOMAIN now?"; then
  if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    if ( cd "$REPO_ROOT" && bash scripts/tls.sh "$DOMAIN" >/tmp/mt-tls.log 2>&1 ); then
      ok "tls.sh completed"
    else
      no "tls.sh failed — see /tmp/mt-tls.log"
      grep -E '^\[(FAIL|WARN)\]' /tmp/mt-tls.log | tail -5 || true
    fi
  else
    skip "certificate already present for $DOMAIN"
  fi

  check "certificate file exists" test -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  check "vhost has ssl_certificate" bash -c "grep -q ssl_certificate /etc/nginx/conf.d/${DOMAIN}.conf"
  https_code="$(curl -LsS -o /dev/null -w '%{http_code}' --max-time 20 "https://${DOMAIN}/" 2>/dev/null || true)"
  if [[ "$https_code" == "200" ]]; then
    ok "https://${DOMAIN}/ -> 200"
  else
    no "https://${DOMAIN}/ -> '${https_code}'"
  fi
  redirect="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 15 "http://${DOMAIN}/" 2>/dev/null || true)"
  if [[ "$redirect" =~ ^30[1237]\ https:// ]]; then
    ok "http -> https redirect: ${redirect}"
  else
    no "http -> https redirect: '${redirect}'"
  fi
else
  skip "TLS skipped by user"
fi

# ---------------------------------------------------------------------------
step "8. Smoke test"
# ---------------------------------------------------------------------------
if ( cd "$REPO_ROOT" && bash tests/smoke.sh "$DOMAIN" >/tmp/mt-smoke.log 2>&1 ); then
  ok "tests/smoke.sh passed"
  grep -E '^\[(OK|WARN)\]' /tmp/mt-smoke.log | sed 's/^/       /' || true
else
  no "tests/smoke.sh failed — see /tmp/mt-smoke.log"
  grep -E '^\[FAIL\]' /tmp/mt-smoke.log || true
fi

# ---------------------------------------------------------------------------
step "9. Idempotency (re-run add-domain)"
# ---------------------------------------------------------------------------
vhost_count_before="$(ls /etc/nginx/conf.d/"${DOMAIN}".conf /etc/nginx/sites-available/"${DOMAIN}".conf 2>/dev/null | wc -l)"
if ( cd "$REPO_ROOT" && bash scripts/add-domain.sh "$DOMAIN" --app "$APP" >/tmp/mt-rerun.log 2>&1 ); then
  ok "second add-domain.sh run completed"
else
  no "second add-domain.sh run failed — see /tmp/mt-rerun.log"
fi
vhost_count_after="$(ls /etc/nginx/conf.d/"${DOMAIN}".conf /etc/nginx/sites-available/"${DOMAIN}".conf 2>/dev/null | wc -l)"
check "no duplicate vhost" test "$vhost_count_before" = "$vhost_count_after"
check "no duplicate .env entry" bash -c "test \"\$(grep -c '^DB_PASS_${slug}=' '${REPO_ROOT}/.env')\" = 1"
check "single database" bash -c "test \"\$(mariadb -N -B -e \"SHOW DATABASES LIKE '${slug}_db'\" | wc -l)\" = 1"
check "single db user" bash -c "test \"\$(mariadb -N -B -e \"SELECT user FROM mysql.user WHERE user='${slug}_u'\" | wc -l)\" = 1"

# ---------------------------------------------------------------------------
step "10. Removal"
# ---------------------------------------------------------------------------
if (( KEEP )); then
  skip "--keep: domain left provisioned"
elif confirm "Remove $DOMAIN now (docroot, logs, database, DB user)?"; then
  if ( cd "$REPO_ROOT" && bash scripts/remove-domain.sh "$DOMAIN" --yes >/tmp/mt-remove.log 2>&1 ); then
    ok "remove-domain.sh completed"
  else
    no "remove-domain.sh failed — see /tmp/mt-remove.log"
  fi
  check "docroot removed" bash -c "test ! -d '/var/www/${DOMAIN}'"
  check "vhost removed" bash -c "test ! -f /etc/nginx/conf.d/${DOMAIN}.conf"
  check "database removed" bash -c "test -z \"\$(mariadb -N -B -e \"SHOW DATABASES LIKE '${slug}_db'\")\""
  check "db user removed" bash -c "test -z \"\$(mariadb -N -B -e \"SELECT user FROM mysql.user WHERE user='${slug}_u'\")\""
  check ".env entry removed" bash -c "test \"\$(grep -c '^DB_PASS_${slug}=' '${REPO_ROOT}/.env' 2>/dev/null || echo 0)\" = 0"
  check "nginx still valid" nginx -t

  if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    if confirm "Also delete the leftover certificate for $DOMAIN?"; then
      if certbot delete --cert-name "$DOMAIN" --non-interactive >/dev/null 2>&1; then
        ok "certificate deleted"
      else
        no "certbot delete failed"
      fi
    else
      skip "certificate kept (remove with: certbot delete --cert-name $DOMAIN)"
    fi
  fi
else
  skip "removal skipped by user"
fi

# ---------------------------------------------------------------------------
step "Summary"
# ---------------------------------------------------------------------------
printf 'PASS=%d  FAIL=%d  SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
if (( FAIL > 0 )); then
  printf 'Some checks failed. Logs: /tmp/mt-*.log\n' >&2
  exit 1
fi
printf 'All checks passed.\n'
exit 0
