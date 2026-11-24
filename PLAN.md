	# Web Server Architecture Automation — Plan

**Goal:** Automate installation of a LEMP stack (Linux, Nginx, MariaDB, PHP-FPM) with support for multiple web domains on a single VPS. LAMP may come later.

**Implementation decisions (revised):**
- Tool: **Bash shell scripts** with a small shared library — no Ansible, no Python dependency
- Scope: **single VPS**; scripts are executed **on the VPS itself** (in the VPS terminal, via provider console or an SSH terminal session). The repo is copied onto the VPS and the scripts run there; no client-side / remote SSH installer.
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
Phase 0 → Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 5 → Phase 6 → Phase 7 → Phase 8
```

---

## Phase 0 — Test harness & manual baseline

The "check first" phase. Verify environment and a hand-installed baseline before writing any automation.

Phase 0 is performed on the VPS itself, not on the developer's machine. From your dev machine (e.g. CachyOS) you only edit files, copy the repo to the VPS, and write `tests/manual-baseline.md`; all commands below run in the VPS terminal. A provider web console is fine — SSH is just a way to open that same terminal.

- [x] Provision a fresh Ubuntu 24.04 VPS; snapshot it (or note the provider image ID) so every test run starts from zero
- [ ] Point DNS A/AAAA records for 2–3 test domains at the VPS IP; verify resolution with `dig`
- [x] Open ports 22/80/443 in the cloud security group **and** UFW
- [x] Verify system time sync (chrony) — TLS issuance and logs depend on it
- [x] Confirm no control panel is installed (preflight will enforce this later)
- [ ] Update apt and install LEMP **by hand**; document every command in `tests/manual-baseline.md`
- [ ] Confirm the manual baseline with smoke checks:
  - [ ] `nginx -t` passes and reload works
  - [ ] A PHP page renders (`phpinfo()` or equivalent marker)
  - [ ] PHP connects to MariaDB
  - [ ] Each test domain serves its own content
- [x] Record the exact end-state checklist — this becomes the automation's acceptance criteria

> Progress note: the VPS was verified as a clean Ubuntu 24.04.5 (no panel/stack), UFW active with 22/80/443, NTP synchronized. `tests/manual-baseline.md` documents the intended hand-install commands and the end-state checklist. The by-hand install and the manual smoke pass were replaced by the Phase 2 automation; a provider snapshot was not taken before those changes. DNS records for the test domains are still to be confirmed with `dig`.

---

## Phase 1 — Repo scaffold

- [x] `lib/common.sh` — shared helpers: logging (`log/info/warn/fail`), `require_root`, `config_test`, `db_user_exists`, idempotent append/create helpers, password generation
- [x] `lib/preflight.sh` — preflight functions + `preflight_check <profile>` runner (see above)
- [x] `scripts/preflight.sh` — standalone entry point
- [x] `config/.env.example` — DB credentials template; real `.env` is `chmod 600` and gitignored
- [x] `config/domains.conf` — optional one-domain-per-line list for batch runs
- [x] `.gitignore` — `.env`, `*.retry`, local secrets
- [x] `README.md` — prerequisites and quick protocols

---

## Phase 2 — `scripts/setup.sh` (base + LEMP)

- [x] Call `preflight_check base` at the top
- [x] apt update, base packages (`curl`, `ca-certificates`, `dnsutils`, `unzip`, `git`)
- [x] UFW: allow SSH/80/443, enable if not already
- [x] chrony: install, enable, verify sync
- [x] nginx: install, enable/start; remove default site when appropriate
- [x] MariaDB: install, enable/start, harden — root via unix_socket auth, drop anonymous users and test database
- [x] PHP-FPM + `php-mysql` + common extensions (curl, mbstring, xml, zip, gd, intl — adjust to need)
- [x] Every service change gated: `nginx -t && systemctl reload nginx`, `php-fpm -t && systemctl reload php*-fpm`
- [x] Idempotency: installed packages and existing config are detected and skipped, never duplicated

---

## Phase 3 — `scripts/add-domain.sh <domain>` (core feature)

- [x] Call `preflight_check domain` at the top (DNS must resolve to this VPS)
- [x] Docroot `/var/www/<domain>/public_html` with correct ownership/mode
- [x] Marker file in docroot (e.g. `<h1><domain></h1>` or `marker.txt`) so smoke tests can prove which site answered
- [x] Per-domain access/error logs
- [x] nginx vhost from `templates/nginx-vhost.conf.tpl`: `server_name`, `root`, logs, PHP-FPM fastcgi pass
- [x] Enable site (`sites-available` → `sites-enabled`; on nginx.org layout the vhost goes in `conf.d/` directly)
- [x] Dedicated MariaDB database + least-privilege user (`GRANT ALL ON <db>.* TO '<user>'@'localhost'`) with credentials from `.env` or generated and stored there
- [x] `nginx -t` gate → conditional reload; never a blind restart
- [x] Idempotency: skip site/DB/user creation when they already exist
- [x] Accept domain as CLI argument; optional batch mode reading `config/domains.conf`

---

## Phase 4 — `scripts/tls.sh <domain>` (certbot)

- [x] Call `preflight_check tls` at the top (DNS + LE reachability + NTP)
- [x] Install certbot + nginx plugin if absent
- [x] Issue one cert per domain: `certbot --nginx -d <domain> [-d www.<domain>]` (www only when it resolves)
- [x] First passes against the Let's Encrypt **staging endpoint** to avoid production rate limits; toggle with `LE_STAGING=1`
- [x] Flip to production once staging is green
- [x] Verify renewal: `certbot renew --dry-run`
- [x] Confirm the renewal timer (`systemctl list-timers | grep certbot`) is active
- [x] Confirm HTTPS vhosts serve 200 and HTTP redirects to HTTPS
- [x] Support `--renew-dry-run` as a quick protocol command
- [x] Managed default server (`templates/nginx-default-reject.conf.tpl`, installed by `setup.sh`): unmatched Hosts fail closed on :80 (`return 444`) and :443 (`ssl_reject_handshake`) so a domain without TLS can never fall through to another domain's HTTPS vhost

---

## Phase 5 — Verification

- [x] `tests/smoke.sh` — for each domain: *(written and run on the VPS, 0 failures)*
  - [x] HTTPS (443) returns 200
  - [x] Response contains that domain's marker content (proves vhost routing, not the default site)
  - [x] PHP executes (not served as plain text)
  - [x] DB connectivity from PHP (small probe script per domain)
  - [ ] Optional: security headers present
- [x] Idempotency: run `setup.sh` and `add-domain.sh` twice; second run must skip everything (no duplicate vhosts/users/DBs) — verified across repeated runs
- [x] Preflight failure drill: unsupported OS (CachyOS) and panel present (Hestia) both verified to fail before any change; non-nginx port-occupied path implemented but not simulated
- [x] Failure injection: break an unrelated nginx config → `add-domain.sh` fails at `nginx -t` (exit 1) and the live site stays 200; also verified TLS-enabled vhosts are preserved on rerun
- [ ] Full reset-from-snapshot → run → smoke cycle, repeated, to prove the whole flow is reproducible

> Note on reset-from-snapshot: this is a **manual, client-side procedure**. The client reinstalls/restores a clean Ubuntu 24.04 snapshot at their provider before each full-cycle run, then runs the full flow and smoke checks. This project has no provider API access, so the automated suite covers everything except the reset itself. The checkbox stays open until the repeated clean-slate cycle is performed and reported by the client. Removing it does not affect project functionality: one VPS with multiple domains, automated LEMP (later LAMP), certbot TLS, per-domain isolation and idempotency are all independent of this test.

---

## Phase 6 — Removal & docs

- [x] `scripts/remove-domain.sh <domain>`: disable vhost (`sites-enabled` → remove), remove docroot/logs, drop MariaDB DB/user, reload nginx behind config test; require explicit confirmation
- [x] README quick protocols (see below) and prerequisites: fresh VPS, sudo/SSH access, DNS A/AAAA records, ports 22/80/443
- [x] How to add a domain, how to remove a domain, rollback notes (snapshot before changes; `nginx -t` gating; restore from snapshot on failure)
- [x] Let's Encrypt rate-limit caveat and staging-endpoint usage
- [x] Note the path to LAMP: only the package list and vhost template are stack-coupled; the domain pattern (docroot/logs/DB/user) is shared

---

## Phase 7 — WordPress app provisioning (shared template)

- [x] `scripts/prepare-wordpress.sh` — download WordPress once into `/var/lib/wsa/wordpress/` (root-owned, dirs 0755 / files 0644), record version + sha256, `--update` refreshes; no-op if already present
- [x] `templates/wp-config.php.tpl` — placeholders for DB name/user/password/table-prefix + salts
- [x] `scripts/add-domain.sh` accepts `--app wordpress|static` (default `static`, preserving Phase 3 behaviour)
- [x] With `--app wordpress`: copy shared template into docroot, render `wp-config.php` from the domain's DB/user/password, generate per-domain salts + unique table prefix, `chown www-data`
- [x] vhost + DB/user + `nginx -t` gate continue exactly as in Phase 3
- [x] `config/domains.conf` accepts optional `domain|app` second field (plain `domain` still valid)
- [x] each action stays a standalone module — no central orchestrator; the step-by-step protocol chains them manually
- [x] `tests/smoke.sh` becomes app-aware: detect `wp-config.php`; for WordPress check `wp-login.php` 200 + WordPress signature, DB via `wp db check` if wp-cli exists (else WARN); static sites keep marker checks
- [x] Idempotency: skip if WordPress already present; never overwrite existing site content

---

## Phase 8 — Web admin panel (`scripts/panel/`)

- [x] `scripts/panel/index.php` — dashboard: stack state, per-domain list (docroot, cert status, logs), cert expiry per domain; shows app type (static / WordPress) and WP version where available
- [x] `scripts/panel/actions.php` — action endpoints: add domain, TLS per domain, renew, smoke, remove domain, **Deploy WordPress** (calls `prepare-wordpress.sh` once then `add-domain.sh --app wordpress <domain>`); each calls the existing script through `sudo`, inheriting preflight + idempotency; allow choosing app type (static / wordpress) when adding a domain. Shared session/CSRF/sudo helpers live in `scripts/panel/bootstrap.php`.
- [x] `scripts/status.sh` — machine-readable state dump: stack state, domains with app type + WP version, cert expiry (via `certbot certificates` or openssl), latest log lines; used by the panel
- [x] `config/panel.conf.example` — panel options (admin path, port, basic-auth, optional WordPress template path default `/var/lib/wsa/wordpress`); real `panel.conf` is gitignored
- [ ] Security: passwordless sudo rule limited to the specific script paths; basic auth on the admin path + optional IP restriction; domain args validated by `add-domain.sh` itself; POST actions carry a CSRF token; privileged panel actions run only through the existing sudo-limited scripts
- [ ] README quick protocols — document the panel URL and how to log in; note the admin path and the Deploy WordPress action

---

## Quick protocols

Every command below is executed **on the VPS**. Copy the repo onto the VPS first, then run them in its terminal; do not run this toolchain from a laptop/desktop.

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

## Action modules (no central orchestrator)

There is deliberately **no** one-command installer. Every action is an independent module with its own preflight gate and idempotency guard, chained manually through the Quick protocols above:

| Module | Action |
| --- | --- |
| `scripts/preflight.sh` | read-only requirement checks |
| `scripts/setup.sh` | base + LEMP (one-time) |
| `scripts/prepare-wordpress.sh` | shared WordPress template (one-time) |
| `scripts/add-domain.sh` | vhost + docroot + DB/user + app content |
| `scripts/tls.sh` | staging → production cert, renewal check |
| `scripts/remove-domain.sh` | full domain teardown behind confirmation |
| `scripts/status.sh` | domain inventory (human / JSON) |
| `tests/smoke.sh` | end-to-end verification |
| `scripts/panel/*`, `setup-panel.sh`, `uninstall-panel.sh` | optional web UI |

Benefits: each step can be run alone, failures are isolated, and adding an action never changes the others. The cost is that multi-domain setup requires running the domain modules per domain (or via `config/domains.conf` batch mode in `add-domain.sh`).

---

## Key risks / notes

- **Let's Encrypt rate limits** — develop against the staging endpoint; production only for final verification.
- **Secrets** — `.env` with mode 600, gitignored; never commit credentials. It lives at `<repo_dir>/.env` (root of whichever checkout the scripts run from) — not at a fixed path. Since it is untracked, copy it into a new checkout before replacing an old one.
- **Control panels** — hard fail in preflight; they own web config and conflict with generated vhosts.
- **Forgotten DNS** — the most common "script failure" is DNS not pointing at the VPS; preflight checks `dig` before every TLS step.
- **Snapshot/reset procedure** — depends on the VPS provider; document the exact steps once known.
- **PHP-FPM isolation** — phase 1 uses a shared pool; per-domain pools + unix users are a follow-up if stronger isolation is needed.
- **Shared WordPress template** — updating the shared template affects only **new** domains; existing sites update via wp-admin / wp-cli.
- **Execution context** — every action module runs on the VPS itself. No client-side SSH wrapper or remote-install path is planned. Running the scripts on the dev machine (e.g. CachyOS) will correctly fail preflight at the OS / package-manager checks.

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
│   ├── domains.conf            # optional domain list (domain or domain|app)
│   ├── .env.example            # DB credentials template
│   ├── panel.conf.example      # admin panel options (path, port, auth, WP template)
│   └── sudoers-panel.conf.example  # sudoers drop-in limited to panel-called scripts
├── scripts/
│   ├── preflight.sh            # "check requirements first" command
│   ├── setup.sh                # base + LEMP
│   ├── add-domain.sh           # vhost + DB + marker (--app wordpress|static)
│   ├── tls.sh                  # certbot per domain + renewal
│   ├── prepare-wordpress.sh    # one-time shared WordPress template download
│   ├── status.sh               # machine-readable state dump (panel, smoke)
│   ├── setup-panel.sh          # install panel vhost, auth, sudoers, UFW, renewal hook
│   ├── uninstall-panel.sh      # remove panel artifacts; keep sites, certs and stack
│   ├── panel/
│   │   ├── bootstrap.php       # config, CSRF, sudo exec helpers
│   │   ├── index.php           # dashboard
│   │   └── actions.php         # action endpoints
│   └── remove-domain.sh
├── templates/
│   ├── nginx-vhost.conf.tpl
│   ├── nginx-panel.conf.tpl    # public panel listener (:8083)
│   └── wp-config.php.tpl       # WordPress config template
└── tests/
    ├── manual-baseline.md      # documented hand-install steps
    └── smoke.sh                # per-domain smoke checks
```
