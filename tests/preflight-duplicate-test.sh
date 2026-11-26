#!/usr/bin/env bash
# tests/preflight-duplicate-test.sh — unit test for the duplicate-domain gate.
# Runs locally or on the VPS. Uses temp directories via PF_* overrides, so it
# never reads or writes real nginx / docroot paths.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/preflight.sh
source "${REPO_ROOT}/lib/preflight.sh"

PASS=0; FAIL=0
ok() { printf '[OK]   %s\n' "$*"; PASS=$((PASS + 1)); }
no() { printf '[FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export PF_SITES_ENABLED_DIR="${tmp}/sites-enabled"
export PF_NGINX_CONFD_DIR="${tmp}/conf.d"
export PF_WEB_ROOT="${tmp}/www"
mkdir -p "$PF_SITES_ENABLED_DIR" "$PF_NGINX_CONFD_DIR" "$PF_WEB_ROOT"

DOMAIN="taken.example.test"
FRESH="fresh.example.test"

# Stub unrelated checks so each case isolates only the duplicate-domain result.
pf_execution_context() { :; }
pf_os() { :; }
pf_package_manager() { :; }
pf_panel_conflicts() { :; }
pf_resources() { :; }
pf_nginx_defaults() { :; }
pf_domain_format() { :; }
pf_domain_dns() { :; }
pf_ports_client_side() { :; }
pf_le_reachability() { :; }
pf_ntp() { :; }

expect() {
  local label="$1" want_rc="$2" want_text="$3" profile="$4" domain="$5"
  local out rc
  out="$(preflight_check "$profile" "$domain" 2>&1)"; rc=$?
  if (( rc != want_rc )); then
    no "$label — exit $rc (expected $want_rc)"
    printf '%s\n' "$out" | sed 's/^/    /'
    return
  fi
  if [[ -n "$want_text" ]] && ! grep -qF "$want_text" <<<"$out"; then
    no "$label — missing text: $want_text"
    printf '%s\n' "$out" | sed 's/^/    /'
    return
  fi
  ok "$label"
}

clean_artifacts() {
  rm -rf "${PF_WEB_ROOT:?}/${DOMAIN}" \
         "${PF_SITES_ENABLED_DIR:?}/${DOMAIN}" \
         "${PF_SITES_ENABLED_DIR:?}/${DOMAIN}.conf" \
         "${PF_NGINX_CONFD_DIR:?}/${DOMAIN}.conf"
}

# 1. A fresh domain passes the add profile.
clean_artifacts
expect "add-domain: fresh domain passes" 0 "not yet configured" add-domain "$FRESH"

# 2. A leftover docroot hard-fails the add profile.
clean_artifacts
mkdir -p "${PF_WEB_ROOT}/${DOMAIN}"
expect "add-domain: docroot duplicate fails" 1 "refusing to add" add-domain "$DOMAIN"

# 3. A leftover sites-enabled symlink (.conf) hard-fails the add profile.
clean_artifacts
ln -s /etc/nginx/sites-available/taken "${PF_SITES_ENABLED_DIR}/${DOMAIN}.conf"
expect "add-domain: symlink duplicate fails" 1 "refusing to add" add-domain "$DOMAIN"

# 4. A leftover conf.d vhost hard-fails the add profile.
clean_artifacts
: > "${PF_NGINX_CONFD_DIR}/${DOMAIN}.conf"
expect "add-domain: conf.d duplicate fails" 1 "refusing to add" add-domain "$DOMAIN"

# 5. The same artifacts only warn on the domain profile (remove-domain.sh path).
expect "domain: duplicate only warns" 0 "existing resources detected" domain "$DOMAIN"

# 6. tls.sh also stays tolerant of an existing domain.
expect "tls: duplicate only warns" 0 "existing resources detected" tls "$DOMAIN"

# 7. An unknown profile is still rejected.
expect "unknown profile rejected" 1 "unknown preflight profile" bogus "$DOMAIN"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
