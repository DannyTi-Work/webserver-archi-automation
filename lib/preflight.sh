#!/usr/bin/env bash
# lib/preflight.sh — requirement checks run before any script mutates the system.
# Usage: source this file, then call: preflight_check <base|domain|add-domain|tls> [domain]
# Prints [OK] / [WARN] / [FAIL] lines. Returns 1 if any check failed.

if [[ -n "${_PREFLIGHT_SH_LOADED:-}" ]]; then
  return 0
fi
_PREFLIGHT_SH_LOADED=1

_PREFLIGHT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_PREFLIGHT_DIR}/common.sh"

PF_FAILS=0
PF_WARNS=0

pf_info() { printf '[INFO] %s\n' "$*"; }
pf_ok()   { printf '[OK]   %s\n' "$*"; }
pf_warn() { printf '[WARN] %s\n' "$*"; PF_WARNS=$((PF_WARNS + 1)); }
pf_fail() { printf '[FAIL] %s\n' "$*"; PF_FAILS=$((PF_FAILS + 1)); }

# ---------------------------------------------------------------------------
# 1. Execution context
# ---------------------------------------------------------------------------
pf_execution_context() {
  if (( EUID == 0 )); then
    pf_ok "running as root"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    pf_ok "passwordless sudo available"
  else
    pf_fail "run as root or provide passwordless sudo"
  fi

  local virt=""
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt="$(systemd-detect-virt 2>/dev/null || true)"
  fi
  case "$virt" in
    docker|lxc|lxc-container|systemd-nspawn|openvz|vserver|rkt|podman)
      pf_fail "container detected ($virt) — use a VM or bare metal with real systemd"
      ;;
    kvm|qemu|none|*)
      pf_ok "not a container (virtualization: ${virt:-unknown})"
      ;;
  esac

  local pid1=""
  if [[ -r /proc/1/comm ]]; then
    pid1="$(</proc/1/comm)"
    if [[ "$pid1" == "systemd" ]]; then
      pf_ok "PID 1 is systemd"
    else
      pf_warn "PID 1 is '$pid1', not systemd — service management may not work"
    fi
  fi

  case "$(uname -m)" in
    x86_64|aarch64) pf_ok "architecture: $(uname -m)" ;;
    *) pf_fail "unsupported architecture: $(uname -m) (supported: x86_64, aarch64)" ;;
  esac
}

# ---------------------------------------------------------------------------
# 2. OS
# ---------------------------------------------------------------------------
pf_os() {
  local id="" version=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    id="${ID:-}"
    version="${VERSION_ID:-}"
  fi
  if [[ "$id" == "ubuntu" && "$version" == "24.04" ]]; then
    pf_ok "OS: Ubuntu $version"
  else
    pf_fail "unsupported OS: ${id:-unknown} ${version:-unknown} — supported: Ubuntu 24.04 LTS"
  fi
}

# ---------------------------------------------------------------------------
# 3. Package manager
# ---------------------------------------------------------------------------
pf_package_manager() {
  local tool
  local missing=""
  for tool in apt-get dpkg; do
    command -v "$tool" >/dev/null 2>&1 || missing="${missing} ${tool}"
  done
  if [[ -n "$missing" ]]; then
    pf_fail "missing package manager tools:${missing}"
    return
  fi
  pf_ok "apt-get and dpkg present"

  if command -v fuser >/dev/null 2>&1; then
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
      pf_fail "dpkg lock is held by another process — wait for it to finish"
    else
      pf_ok "no held dpkg lock"
    fi
  else
    pf_warn "fuser not available — cannot verify dpkg lock"
  fi

  local sources=0
  [[ -s /etc/apt/sources.list ]] && sources=1
  if compgen -G '/etc/apt/sources.list.d/*.sources' >/dev/null || \
     compgen -G '/etc/apt/sources.list.d/*.list' >/dev/null; then
    sources=1
  fi
  if (( sources )); then
    pf_ok "apt sources configured"
  else
    pf_warn "no apt sources found — apt update may fail"
  fi

  missing=""
  for tool in curl systemctl ss; do
    command -v "$tool" >/dev/null 2>&1 || missing="${missing} ${tool}"
  done
  if command -v dig >/dev/null 2>&1; then
    pf_ok "tool: dig"
  elif command -v nslookup >/dev/null 2>&1; then
    pf_ok "tool: nslookup"
  else
    missing="${missing} dig/nslookup"
  fi
  if [[ -n "$missing" ]]; then
    pf_fail "missing required CLI tools:${missing}"
  else
    pf_ok "required CLI tools present (curl, dig/nslookup, systemctl, ss)"
  fi
}

# ---------------------------------------------------------------------------
# 4. Control panel & conflicting stack
# ---------------------------------------------------------------------------
pf_panel_conflicts() {
  local panel
  local found=""
  local -a panels=(
    /usr/local/cpanel
    /usr/local/psa
    /usr/local/CyberPanel
    /www/server/panel
    /usr/share/webmin
    /usr/local/ispconfig
    /usr/local/hestia
    /usr/local/hestiacp
    /opt/cloudpanel
  )
  for panel in "${panels[@]}"; do
    [[ -e "$panel" ]] && found="${found} ${panel}"
  done
  if [[ -n "$found" ]]; then
    pf_fail "control panel installed:${found} — use a clean VPS or the panel's own API"
  else
    pf_ok "no control panel detected"
  fi

  # apache2/mysql-server conflict with our LEMP stack; nginx/mariadb/php-fpm
  # are what setup.sh installs, so on a re-run they are expected (warn, not fail).
  local pattern
  local conflicting=""
  local expected=""
  for pattern in apache2 mysql-server; do
    # shellcheck disable=SC2086
    if dpkg -l $pattern 2>/dev/null | grep -q '^ii'; then
      conflicting="${conflicting} ${pattern}"
    fi
  done
  for pattern in nginx mariadb-server 'php*-fpm'; do
    # shellcheck disable=SC2086
    if dpkg -l $pattern 2>/dev/null | grep -q '^ii'; then
      expected="${expected} ${pattern}"
    fi
  done
  if [[ -n "$conflicting" ]]; then
    pf_fail "conflicting stack packages:${conflicting} — start from a clean VPS"
  elif [[ -n "$expected" ]]; then
    pf_warn "LEMP packages already present:${expected} — setup.sh will skip/reuse them"
  else
    pf_ok "no pre-existing LEMP/LAMP stack packages"
  fi

  local listeners nginx_listeners other_listeners
  listeners="$(ss -ltnp 2>/dev/null | awk 'NR>1 && ($4 ~ /:80$/ || $4 ~ /:443$/) {print $4 " (" $NF ")"}')"
  nginx_listeners="$(printf '%s\n' "$listeners" | grep -i nginx || true)"
  other_listeners="$(printf '%s\n' "$listeners" | grep -iv nginx || true)"
  if [[ -n "$other_listeners" ]]; then
    pf_fail "ports 80/443 in use by a non-nginx process: ${other_listeners}"
  elif [[ -n "$nginx_listeners" ]]; then
    pf_warn "ports 80/443 already used by nginx: ${nginx_listeners} — expected on a re-run"
  else
    pf_ok "ports 80/443 free"
  fi

  local leftovers=""
  if compgen -G '/etc/nginx/sites-enabled/*' >/dev/null; then
    leftovers="${leftovers} /etc/nginx/sites-enabled/*"
  fi
  if compgen -G '/var/www/*' >/dev/null; then
    leftovers="${leftovers} /var/www/*"
  fi
  if [[ -n "$leftovers" ]]; then
    pf_warn "possible leftovers from a previous run:${leftovers} — duplicate-domain risk"
  else
    pf_ok "no previous-run leftovers"
  fi
}

# ---------------------------------------------------------------------------
# 5. Network / TLS prerequisites
# ---------------------------------------------------------------------------
pf_domain_format() {
  local domain="${1:-}"
  if is_valid_domain "$domain"; then
    pf_ok "domain format: $domain"
  else
    pf_fail "invalid domain format: '${domain:-<none>}'"
  fi
}

pf_domain_dns() {
  local domain="${1:-}"
  [[ -z "$domain" ]] && return 0

  local resolved=""
  if command -v dig >/dev/null 2>&1; then
    resolved="$(dig +short A "$domain" 2>/dev/null | head -1)"
    [[ -z "$resolved" ]] && resolved="$(dig +short AAAA "$domain" 2>/dev/null | head -1)"
  elif command -v nslookup >/dev/null 2>&1; then
    resolved="$(nslookup "$domain" 2>/dev/null | awk '/^Address: / {print $2; exit}')"
  fi
  if [[ -z "$resolved" ]]; then
    pf_fail "DNS for $domain does not resolve"
    return
  fi

  local public_ip=""
  if command -v curl >/dev/null 2>&1; then
    public_ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [[ -z "$public_ip" ]] && \
      public_ip="$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -1 || true)"
  fi

  # The local resolver may be overridden by /etc/hosts (e.g. 127.0.1.1 for the
  # VPS hostname). Query a public resolver as well before declaring a mismatch.
  local public_resolved=""
  if command -v dig >/dev/null 2>&1; then
    public_resolved="$(dig +short A "$domain" @8.8.8.8 2>/dev/null | head -1 || true)"
    [[ -z "$public_resolved" ]] && \
      public_resolved="$(dig +short AAAA "$domain" @8.8.8.8 2>/dev/null | head -1 || true)"
  fi

  if [[ -z "$public_ip" ]]; then
    pf_warn "DNS for $domain resolves to $resolved; could not verify VPS public IP"
  elif [[ "$resolved" == "$public_ip" || "$public_resolved" == "$public_ip" ]]; then
    pf_ok "DNS for $domain points to this VPS ($public_ip)"
  else
    pf_fail "DNS for $domain resolves to $resolved (public: ${public_resolved:-none}), but VPS public IP is $public_ip"
  fi
}

pf_ports_client_side() {
  pf_info "ports 80/443 in the cloud security group must be checked at the provider (not verifiable inside the VPS)"
}

pf_le_reachability() {
  local url="https://acme-v02.api.letsencrypt.org/directory"
  [[ "${LE_STAGING:-0}" == "1" ]] && url="https://acme-staging-v02.api.letsencrypt.org/directory"
  if curl -fsS --max-time 10 -o /dev/null "$url" 2>/dev/null; then
    pf_ok "Let's Encrypt directory reachable: $url"
  else
    pf_fail "Let's Encrypt directory unreachable: $url"
  fi
}

pf_ntp() {
  local ntp=""
  if command -v timedatectl >/dev/null 2>&1; then
    ntp="$(timedatectl show -p NTP --value 2>/dev/null || true)"
  fi
  if [[ "$ntp" == "yes" ]]; then
    pf_ok "NTP sync enabled"
  else
    pf_fail "NTP sync is not enabled — cert issuance may fail (run timedatectl set-ntp true)"
  fi
}

# Detect artifacts left by a previous add-domain.sh run. The lookup paths are
# overridable so this check can be unit-tested without touching the system.
# Mode "fail" is used by the add-domain profile (a duplicate add is an error);
# the default "warn" keeps tls.sh and remove-domain.sh tolerant of domains
# that must already exist.
pf_duplicate_domain() {
  local domain="${1:-}"
  local mode="${2:-warn}"
  [[ -z "$domain" ]] && return 0
  local sites_dir="${PF_SITES_ENABLED_DIR:-/etc/nginx/sites-enabled}"
  local confd_dir="${PF_NGINX_CONFD_DIR:-/etc/nginx/conf.d}"
  local web_root="${PF_WEB_ROOT:-/var/www}"
  local found=""
  [[ -e "${sites_dir}/${domain}" || -L "${sites_dir}/${domain}" ]] && found="${found} nginx site"
  [[ -e "${sites_dir}/${domain}.conf" || -L "${sites_dir}/${domain}.conf" ]] && found="${found} nginx site"
  [[ -e "${confd_dir}/${domain}.conf" ]] && found="${found} nginx conf"
  [[ -e "${web_root}/${domain}" ]] && found="${found} docroot"
  # Hestia-style user layout: /var/www/<user>/<domain>
  for candidate in "${web_root}"/*/"${domain}"; do
    [[ -e "$candidate" ]] && found="${found} docroot" && break
  done
  if [[ -n "$found" ]]; then
    if [[ "$mode" == "fail" ]]; then
      pf_fail "duplicate domain $domain already has:${found} — refusing to add an existing domain"
    else
      pf_warn "domain $domain already has:${found} — existing resources detected"
    fi
  else
    pf_ok "domain $domain not yet configured"
  fi
}

# ---------------------------------------------------------------------------
# 6. Resources
# ---------------------------------------------------------------------------
pf_resources() {
  local free_mb total_mb
  free_mb="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')"
  total_mb="$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')"
  if [[ -n "$free_mb" ]] && (( free_mb >= 2048 )); then
    pf_ok "disk space: ${free_mb} MB free on /"
  else
    pf_warn "less than 2 GB free on / (${free_mb:-unknown} MB)"
  fi
  if [[ -n "$total_mb" ]] && (( total_mb >= 1024 )); then
    pf_ok "RAM: ${total_mb} MB"
  else
    pf_warn "less than 1 GB RAM (${total_mb:-unknown} MB) — recommended: 1 GB"
  fi
}

# ---------------------------------------------------------------------------
# 7. nginx default server (managed by setup.sh)
# ---------------------------------------------------------------------------
pf_nginx_defaults() {
  local reject="/etc/nginx/conf.d/00-default-reject.conf"
  if [[ -f "$reject" ]] && grep -q 'default_server' "$reject"; then
    pf_ok "managed default-reject config installed"
  else
    pf_warn "no managed default_server config — unmatched Hosts fall back to the first server block"
  fi
  local others
  others="$(grep -RlE 'listen[[:space:]]+([^;]*[[:space:]])?default_server' \
    /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*.conf 2>/dev/null \
    | grep -vF "$reject" || true)"
  [[ -n "$others" ]] && pf_warn "other default_server declarations: ${others//$'\n'/ }"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
preflight_check() {
  local profile="${1:-base}"
  local domain="${2:-}"

  PF_FAILS=0
  PF_WARNS=0
  printf '== preflight profile: %s ==\n' "$profile"

  pf_execution_context
  pf_os
  pf_package_manager
  pf_panel_conflicts
  pf_resources
  pf_nginx_defaults

  case "$profile" in
    base)
      ;;
    domain)
      pf_domain_format "$domain"
      pf_domain_dns "$domain"
      pf_ports_client_side
      pf_duplicate_domain "$domain"        # warn: remove-domain.sh needs the domain to exist
      ;;
    add-domain)
      pf_domain_format "$domain"
      pf_domain_dns "$domain"
      pf_ports_client_side
      pf_duplicate_domain "$domain" fail   # hard fail: never add a domain twice
      ;;
    tls)
      pf_domain_format "$domain"
      pf_domain_dns "$domain"
      pf_ports_client_side
      pf_duplicate_domain "$domain"        # warn: tls.sh needs the domain to exist
      pf_le_reachability
      pf_ntp
      ;;
    *)
      pf_fail "unknown preflight profile: $profile (use base, domain, add-domain, or tls)"
      ;;
  esac

  printf '== preflight result: %d failure(s), %d warning(s) ==\n' "$PF_FAILS" "$PF_WARNS"
  (( PF_FAILS == 0 ))
}
