#!/usr/bin/env bash
# tests/smoke.sh — verify a provisioned domain end-to-end (Phase 5).
# Usage: bash tests/smoke.sh [domain ...]
#        (no args) -> read domains from config/domains.conf
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ok()   { printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }

declare -a domains=()
if (( $# == 0 )); then
  if [[ -f "${REPO_ROOT}/config/domains.conf" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="$(printf '%s' "$line" | tr -d '[:space:]')"
      [[ -n "$line" ]] && domains+=("$line")
    done < "${REPO_ROOT}/config/domains.conf"
  fi
else
  domains=("$@")
fi
if (( ${#domains[@]} == 0 )); then
  printf 'usage: bash tests/smoke.sh <domain> [domain ...]\n' >&2
  exit 2
fi

FAILS=0
printf '== smoke test: %d domain(s) ==\n' "${#domains[@]}"

for domain in "${domains[@]}"; do
  printf -- '-- %s --\n' "$domain"
  body="$(mktemp)"

  # 1. HTTPS returns 200.
  code="$(curl -sS -o "$body" -w '%{http_code}' --max-time 20 "https://${domain}/" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    ok "HTTPS 443: 200"
  else
    fail "HTTPS 443: expected 200, got '${code}'"
  fi

  # 2. Marker content proves the correct vhost answered (not the default site).
  if grep -q "<h1>${domain}</h1>" "$body"; then
    ok "marker: response contains <h1>${domain}</h1>"
  else
    fail "marker: domain marker not found in response"
  fi

  # 3. PHP executes rather than being served as plain text.
  if grep -q 'PHP OK:' "$body"; then
    ok "PHP: executed (marker reports PHP version)"
  else
    fail "PHP: page did not execute / PHP marker missing"
  fi

  # 4. DB connectivity from the per-domain PHP probe.
  if grep -q 'DB OK' "$body"; then
    ok "DB: PHP connected to MariaDB"
  else
    fail "DB: PHP probe did not report DB OK"
  fi

  # 5. HTTP redirects to HTTPS.
  redirect="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 "http://${domain}/" 2>/dev/null || true)"
  if [[ "$redirect" =~ ^30[1237]\ https:// ]]; then
    ok "HTTP -> HTTPS redirect: ${redirect}"
  else
    fail "HTTP -> HTTPS redirect: expected 30x https://, got '${redirect}'"
  fi

  # 6. Optional: security headers (warn only).
  headers="$(curl -sSI --max-time 20 "https://${domain}/" 2>/dev/null || true)"
  sec=""
  for h in Strict-Transport-Security X-Content-Type-Options X-Frame-Options; do
    echo "$headers" | grep -qi "^${h}:" && sec="${sec} ${h}"
  done
  if [[ -n "$sec" ]]; then
    ok "security headers present:${sec}"
  else
    warn "no security headers detected (optional)"
  fi

  rm -f "$body"
done

printf '== smoke result: %d failure(s) ==\n' "$FAILS"
(( FAILS == 0 ))
