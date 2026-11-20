# Web Server Architecture Automation — Plan

**Goal:** Automate installation of a LEMP stack (Linux, Nginx, MariaDB, PHP-FPM) with support for multiple web domains on a single VPS. LAMP may come later.

**Implementation decisions (revised):**
- Tool: **Bash shell scripts** with a small shared library — no Ansible, no Python dependency
- Scope: **single VPS**, scripts executed locally on the server (client SSHes in and runs them)
- First iteration: **LEMP only** (LAMP later, reusing the same vhost model)
- TLS: **Let's Encrypt certbot** with real domains (staging endpoint first)
- Test target: **fresh VPS per test run** (reset from snapshot between runs)
- Target OS: **Ubuntu 24.04 LTS**
- Domain isolation: **per-domain docroot + access/error logs + dedicated MariaDB database and user** (shared PHP-FPM pool for phase 1)
- Domain input: **CLI arguments** (`add-domain.sh <domain>`), with an optional `config/domains.conf` list for batch runs
- Secrets: local `.env` file, `chmod 600`, gitignored (no Ansible Vault)
- Idempotency: hand-written guards (check before create); config tests gate every reload

**Tradeoff:** shell scripts have no state engine, so the preflight checks and smoke tests are the safety net. Keep every mutation guarded by a check.

---

## Preflight checks — run before any script does work

Every script starts by sourcing `lib/preflight.sh` and calling `preflight_check <profile>` before touching the system. A standalone `scripts/preflight.sh` lets the client check requirements first:

```bash
bash scripts/preflight.sh
```

**Behavior:** run all checks, print `[OK] / [WARN] / [FAIL]` lines with actionable messages, then exit 1 if any check failed. Nothing mutates the system until preflight passes.

**Profiles:**

| Script                      | Profile  | Checks applied                                                           |
| --------------------------- | -------- | ------------------------------------------------------------------------ |
| `preflight.sh`              | `base`   | Execution context, OS, package manager, panel/stack conflicts, resources |
| `setup.sh`                  | `base`   | Same as above                                                            |
| `add-domain.sh <domain>`    | `domain` | `base` + domain format, DNS, port availability, duplicate-domain check   |
| `tls.sh <domain>`           | `tls`    | `domain` + LE reachability, NTP sync                                     |
| `remove-domain.sh <domain>` | `domain` | Same safety checks before removal                                        |

### 1. Execution context
- Running as root (or with working `sudo`)
- Not inside a container (`systemd-detect-virt`, `/proc/1/comm`) — Docker/LXC is not a valid target for real systemd services
- Supported architecture (`x86_64`, `aarch64`)

### 2. OS
- Read `/etc/os-release`: require `ID=ubuntu`, `VERSION_ID=24.04` (optional later: `debian 12`)
- Unsupported OS/version → fail immediately with the supported-version list

### 3. Package manager
- `apt-get` and `dpkg` present, apt sources reachable, no held lock (`/var/lib/dpkg/lock-frontend`)
- Unsupported package manager (dnf/yum/etc.) → fail with "unsupported platform" message
- Required CLI tools present: `curl`, `dig`/`nslookup`, `systemctl`, `ss`

### 4. Control panel & conflicting stack
- Detect installed panels by path: cPanel (`/usr/local/cpanel`), Plesk (`/usr/local/psa`), CyberPanel (`/usr/local/CyberPanel`), aaPanel (`/www/server/panel`), Webmin (`/usr/share/webmin`), ISPConfig, Hestia, CloudPanel
- **If any panel is found → hard fail.** Panels own nginx/Apache/DB config and overwrite generated vhosts. Message must tell the client to use a clean VPS or the panel's own API
- Detect pre-existing stack packages (`nginx`, `apache2`, `mariadb-server`, `mysql-server`, `php*-fpm`) and listeners on ports 80/443 via `ss -ltnp` → fail or warn, naming the offending process
- Detect leftovers from a previous run (`/etc/nginx/sites-enabled/*`, `/var/www` marker files) → warn about duplicate-domain risk

### 5. Network / TLS prerequisites (domain + TLS profiles)
- Domain format valid; DNS A/AAAA resolves to the VPS public IP (`dig +short`)
- Outbound HTTPS reachable to the Let's Encrypt directory (staging vs production based on `LE_STAGING`)
- Clock/NTP sync OK (`timedatectl show -p NTP --value`) — otherwise cert issuance fails
- Ports 80/443 reachable through the cloud security group (documented client-side check; cannot be verified from inside the VPS)

### 6. Resources
- At least ~2 GB free on `/`, ~1 GB RAM recommended (warn, do not block)

---

## Test-first order

Testing comes before automation. The manual pass on a clean machine defines the acceptance criteria; the shell scripts are then the repeatable version of that pass.

```
Phase 0 → Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 5 → Phase 6
```

---

## Phase 0 — Test harness & manual baseline

The "check first" phase. Verify environment and a hand-installed baseline before writing any automation.

- [ ] Provision a fresh Ubuntu 24.04 VPS; snapshot it (or note the provider image ID) so every test run starts from zero
- [ ] Point DNS A/AAAA records for 2–3 test domains at the VPS IP; verify resolution with `dig`
- [ ] Open ports 22/80/443 in the cloud security group **and** UFW
- [ ] Verify system time sync (chrony) — TLS issuance and logs depend on it
- [ ] Confirm no control panel is installed (preflight will enforce this later)
- [ ] Update apt and install LEMP **by hand**; document every command in `tests/manual-baseline.md`
- [ ] Confirm the manual baseline with smoke checks:
  - [ ] `nginx -t` passes and reload works
  - [ ] A PHP page renders (`phpinfo()` or equivalent marker)
  - [ ] PHP connects to MariaDB
  - [ ] Each test domain serves its own content
- [ ] Record the exact end-state checklist — this becomes the automation's acceptance criteria

---

## Phase 1 — Repo scaffold

- [ ] `lib/common.sh` — shared helpers: logging (`log/info/warn/fail`), `require_root`, `config_test`, `db_user_exists`, idempotent append/create helpers, password generation
- [ ] `lib/preflight.sh` — preflight functions + `preflight_check <profile>` runner (see above)
- [ ] `scripts/preflight.sh` — standalone entry point
- [ ] `config/.env.example` — DB credentials template; real `.env` is `chmod 600` and gitignored
- [ ] `config/domains.conf` — optional one-domain-per-line list for batch runs
- [ ] `.gitignore` — `.env`, `*.retry`, local secrets
- [ ] `README.md` — prerequisites and quick protocols

---

## Phase 2 — `scripts/setup.sh` (base + LEMP)

- [ ] Call `preflight_check base` at the top
- [ ] apt update, base packages (`curl`, `ca-certificates`, `dnsutils`, `unzip`, `git`)
- [ ] UFW: allow SSH/80/443, enable if not already
- [ ] chrony: install, enable, verify sync
- [ ] nginx: install, enable/start; remove default site when appropriate
- [ ] MariaDB: install, enable/start, harden — root via unix_socket auth, drop anonymous users and test database
- [ ] PHP-FPM + `php-mysql` + common extensions (curl, mbstring, xml, zip, gd, intl — adjust to need)
- [ ] Every service change gated: `nginx -t && systemctl reload nginx`, `php-fpm -t && systemctl reload php*-fpm`
- [ ] Idempotency: installed packages and existing config are detected and skipped, never duplicated

---

## Phase 3 — `scripts/add-domain.sh <domain>` (core feature)

- [ ] Call `preflight_check domain` at the top (DNS must resolve to this VPS)
- [ ] Docroot `/var/www/<domain>/public_html` with correct ownership/mode
- [ ] Marker file in docroot (e.g. `<h1><domain></h1>` or `marker.txt`) so smoke tests can prove which site answered
- [ ] Per-domain access/error logs
- [ ] nginx vhost from `templates/nginx-vhost.conf.tpl`: `server_name`, `root`, logs, PHP-FPM fastcgi pass
- [ ] Enable site (`sites-available` → `sites-enabled`)
- [ ] Dedicated MariaDB database + least-privilege user (`GRANT ALL ON <db>.* TO '<user>'@'localhost'`) with credentials from `.env` or generated and stored there
- [ ] `nginx -t` gate → conditional reload; never a blind restart
- [ ] Idempotency: skip site/DB/user creation when they already exist
- [ ] Accept domain as CLI argument; optional batch mode reading `config/domains.conf`

---

## Phase 4 — `scripts/tls.sh <domain>` (certbot)

- [ ] Call `preflight_check tls` at the top (DNS + LE reachability + NTP)
- [ ] Install certbot + nginx plugin if absent
- [ ] Issue one cert per domain: `certbot --nginx -d <domain> [-d www.<domain>]`
- [ ] First passes against the Let's Encrypt **staging endpoint** to avoid production rate limits; toggle with `LE_STAGING=1`
- [ ] Flip to production once staging is green
- [ ] Verify renewal: `certbot renew --dry-run`
- [ ] Confirm the renewal timer (`systemctl list-timers | grep certbot`) is active
- [ ] Confirm HTTPS vhosts serve 200 and HTTP redirects to HTTPS
- [ ] Support `--renew-dry-run` as a quick protocol command

---

## Phase 5 — Verification

- [ ] `tests/smoke.sh` — for each domain:
  - [ ] HTTPS (443) returns 200
  - [ ] Response contains that domain's marker content (proves vhost routing, not the default site)
  - [ ] PHP executes (not served as plain text)
  - [ ] DB connectivity from PHP (small probe script per domain)
  - [ ] Optional: security headers present
- [ ] Idempotency: run `setup.sh` and `add-domain.sh` twice; second run must skip everything (no duplicate vhosts/users/DBs)
- [ ] Preflight failure drill: simulate unsupported OS / panel present / port occupied → preflight must fail before any change
- [ ] Failure injection: deliberately break an nginx config → script must fail at `nginx -t` and leave the previous config live
- [ ] Full reset-from-snapshot → run → smoke cycle, repeated, to prove the whole flow is reproducible

---

## Phase 6 — Removal & docs

- [ ] `scripts/remove-domain.sh <domain>`: disable vhost (`sites-enabled` → remove), remove docroot/logs, drop MariaDB DB/user, reload nginx behind config test; require explicit confirmation
- [ ] README quick protocols (see below) and prerequisites: fresh VPS, sudo/SSH access, DNS A/AAAA records, ports 22/80/443
- [ ] How to add a domain, how to remove a domain, rollback notes (snapshot before changes; `nginx -t` gating; restore from snapshot on failure)
- [ ] Let's Encrypt rate-limit caveat and staging-endpoint usage
- [ ] Note the path to LAMP: only the package list and vhost template are stack-coupled; the domain pattern (docroot/logs/DB/user) is shared

---

## Quick protocols

```bash
# 0. Check requirements first (OS, package manager, control panel, conflicts)
bash scripts/preflight.sh

# 1. Fresh VPS: install base + LEMP
bash scripts/setup.sh

# 2. Add and secure a domain
bash scripts/add-domain.sh example.com
LE_STAGING=1 bash scripts/tls.sh example.com   # first pass: staging
bash scripts/tls.sh example.com                # then production

# 3. Verify everything
bash tests/smoke.sh

# 4. Renewal check
bash scripts/tls.sh --renew-dry-run

# 5. Remove a domain
bash scripts/remove-domain.sh example.com
```

---

## Key risks / notes

- **Let's Encrypt rate limits** — develop against the staging endpoint; production only for final verification.
- **Secrets** — `.env` with mode 600, gitignored; never commit credentials.
- **Control panels** — hard fail in preflight; they own web config and conflict with generated vhosts.
- **Forgotten DNS** — the most common "script failure" is DNS not pointing at the VPS; preflight checks `dig` before every TLS step.
- **Snapshot/reset procedure** — depends on the VPS provider; document the exact steps once known.
- **PHP-FPM isolation** — phase 1 uses a shared pool; per-domain pools + unix users are a follow-up if stronger isolation is needed.
- **Client-side execution** — assumed scripts run on the VPS itself. If a client-side SSH wrapper is added later, preflight needs an extra local section (SSH reachability, repo path, `scp` availability).

---

## Target repo layout

```
webserver-archi-automation/
├── PLAN.md                     # this file
├── README.md                   # quick protocols + prerequisites
├── .gitignore                  # .env, *.retry, local secrets
├── lib/
│   ├── common.sh               # shared idempotent helpers
│   └── preflight.sh            # OS/package manager/panel/network checks
├── config/
│   ├── domains.conf            # optional one-domain-per-line list
│   └── .env.example            # DB credentials template
├── scripts/
│   ├── preflight.sh            # "check requirements first" command
│   ├── setup.sh                # base + LEMP
│   ├── add-domain.sh           # vhost + DB + marker
│   ├── tls.sh                  # certbot per domain + renewal
│   └── remove-domain.sh
├── templates/
│   └── nginx-vhost.conf.tpl
└── tests/
    ├── manual-baseline.md      # documented hand-install steps
    └── smoke.sh                # per-domain smoke checks
```
