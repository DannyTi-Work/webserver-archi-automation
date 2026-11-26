#!/usr/bin/env bash
# scripts/preflight.sh — standalone "check requirements first" command.
# Usage: bash scripts/preflight.sh [base|domain|add-domain|tls] [domain]
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/preflight.sh
source "${SCRIPT_DIR}/../lib/preflight.sh"

profile="${1:-base}"
domain="${2:-}"

case "$profile" in
  base) ;;
  domain|add-domain|tls)
    if [[ -z "$domain" ]]; then
      printf 'usage: bash scripts/preflight.sh %s <domain>\n' "$profile" >&2
      exit 2
    fi
    ;;
  *)
    printf 'usage: bash scripts/preflight.sh [base|domain|add-domain|tls] [domain]\n' >&2
    exit 2
    ;;
esac

if preflight_check "$profile" "$domain"; then
  exit 0
else
  exit 1
fi
