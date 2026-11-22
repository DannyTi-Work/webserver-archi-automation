#!/usr/bin/env bash
# scripts/prepare-wordpress.sh — download WordPress once into a shared template (Phase 7).
# Usage: bash scripts/prepare-wordpress.sh [--update]
#   The template lives at /var/lib/wsa/wordpress, outside every docroot.
#   Re-running without --update is a no-op.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
require_root

WP_DIR="/var/lib/wsa/wordpress"
META="${WP_DIR}/.wsa-meta"
UPDATE=0
[[ "${1:-}" == "--update" ]] && UPDATE=1

if [[ -f "$META" ]] && (( ! UPDATE )); then
  info "WordPress template already present: $WP_DIR"
  sed 's/^/    /' "$META"
  exit 0
fi

log "== prepare-wordpress.sh =="
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

url="https://wordpress.org/latest.tar.gz"
info "downloading $url"
curl -fsSL --max-time 180 "$url" -o "${tmp}/latest.tar.gz"

sha="$(sha256sum "${tmp}/latest.tar.gz" | awk '{print $1}')"
tar -xzf "${tmp}/latest.tar.gz" -C "$tmp"
if [[ ! -f "${tmp}/wordpress/wp-settings.php" ]]; then
  fail "downloaded archive does not contain WordPress"
fi
version="$(grep -E '\$wp_version[[:space:]]*=' "${tmp}/wordpress/wp-includes/version.php" \
  2>/dev/null | head -1 | sed -E "s/.*'([^']+)'.*/\1/")"
[[ -n "$version" ]] || version="unknown"

if (( UPDATE )) && [[ -d "$WP_DIR" ]]; then
  run_root rm -rf "$WP_DIR"
fi
run_root install -d -m 0755 /var/lib/wsa
run_root install -d -m 0755 "$WP_DIR"
run_root cp -a "${tmp}/wordpress/." "${WP_DIR}/"
run_root chown -R root:root "$WP_DIR"
run_root find "$WP_DIR" -type d -exec chmod 0755 {} +
run_root find "$WP_DIR" -type f -exec chmod 0644 {} +

printf 'version=%s\nsha256=%s\nsource=%s\n' "$version" "$sha" "$url" > "${tmp}/meta"
run_root install -m 0644 "${tmp}/meta" "$META"

log "== WordPress template ready: $WP_DIR (version $version) =="
