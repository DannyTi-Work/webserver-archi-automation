#!/usr/bin/env bash
# scripts/install.sh — one-command installer (Phase: installer).
# Usage: bash scripts/install.sh [domain ...] [--smoke] [--app wordpress|static]
#   no domain  -> read config/domains.conf (domain or domain|app)
#   --smoke    -> run tests/smoke.sh at the end
#   --app      -> passed through to add-domain.sh (default static)
#   LE_STAGING=1 -> staging pass first for each domain, then production.
# Runs on the VPS. Stops on the first failing step; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/preflight.sh
source "${SCRIPT_DIR}/../lib/preflight.sh"

declare -a domains=()
declare -a domain_apps=()
run_smoke=0
app=""
while (( $# )); do
  case "$1" in
    --smoke) run_smoke=1; shift ;;
    --app) app="${2:-}"; shift 2 ;;
    -h|--help)
      printf 'usage: bash scripts/install.sh [domain ...] [--smoke] [--app wordpress|static]\n'
      exit 0
      ;;
    *) domains+=("$1"); shift ;;
  esac
done
if [[ -n "$app" && "$app" != "wordpress" && "$app" != "static" ]]; then
  fail "invalid --app value: $app (use wordpress or static)"
fi
if [[ -n "$app" ]]; then
  for _d in "${domains[@]}"; do domain_apps+=("$app"); done
fi

log "== install.sh: one-command installer =="

# 0. Preflight base before any mutation.
if ! preflight_check base; then
  fail "preflight failed — nothing was changed"
fi

# 1. Base + LEMP.
log "-- step 1/4: setup.sh (base + LEMP) --"
bash "${SCRIPT_DIR}/setup.sh"

# 2. Domains: CLI args or batch config.
if (( ${#domains[@]} == 0 )); then
  config="${REPO_ROOT}/config/domains.conf"
  if [[ -f "$config" ]]; then
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
    done < "$config"
  fi
fi

# Prepare the shared WordPress template once if any domain uses WordPress.
need_wp=0
for a in "${domain_apps[@]}"; do
  [[ "$a" == "wordpress" ]] && need_wp=1
done
if (( need_wp )); then
  log "-- preparing shared WordPress template --"
  bash "${SCRIPT_DIR}/prepare-wordpress.sh"
fi

# 3. Per domain: add, then TLS (staging first when LE_STAGING=1, then production).
step=2
for i in "${!domains[@]}"; do
  domain="${domains[$i]}"
  dom_app="${domain_apps[$i]:-static}"
  log "-- step ${step}: add-domain.sh ${domain} (app: ${dom_app}) --"
  bash "${SCRIPT_DIR}/add-domain.sh" "$domain" --app "$dom_app"
  step=$((step + 1))

  if [[ "${LE_STAGING:-0}" == "1" ]]; then
    log "-- step ${step}: tls.sh ${domain} (STAGING first) --"
    LE_STAGING=1 bash "${SCRIPT_DIR}/tls.sh" "$domain"
    step=$((step + 1))
  fi

  log "-- step ${step}: tls.sh ${domain} (production) --"
  bash "${SCRIPT_DIR}/tls.sh" "$domain"
  step=$((step + 1))
done

# 4. Smoke test when requested (needs at least one domain).
if (( run_smoke )); then
  if (( ${#domains[@]} == 0 )); then
    warn "--smoke requested but no domains were provided — skipping"
  else
    log "-- final step: tests/smoke.sh --"
    bash "${REPO_ROOT}/tests/smoke.sh" "${domains[@]}"
  fi
fi

log "== install complete =="
if (( ${#domains[@]} )); then
  info "domains: ${domains[*]}"
else
  info "no domains provisioned (base stack only)"
fi
