# Web Server Architecture Automation Deploy
## Feature
- LEMP: Linux, Nginx, MySQL/MariaDB and PHP/PHP-FPM
- LAMP: Linux, Apache2, MySQL/MariaDB and PHP/PHP-FPM


## Summary

Automates a fresh Ubuntu VPS into a LEMP server that hosts multiple web domains. Each domain gets its own docroot, logs and MariaDB database/user, with Let's Encrypt TLS. Everything runs through guarded bash scripts: `preflight.sh` checks requirements before anything changes, `setup.sh` installs the base stack, `add-domain.sh` / `tls.sh` / `remove-domain.sh` manage domains, `tests/smoke.sh` verifies the result, and `install.sh` runs the whole flow in one command. The full plan is in `PLAN.md`.

- **Full usage guide:** [`docs/USAGE.md`](docs/USAGE.md)
- **Guided end-to-end test:** `bash tests/manual-test.sh [domain] [--app wordpress|static]`


## Client overview

### What the client provides / what they get

```text
   CLIENT PROVIDES                AUTOMATION                    RESULT
   +---------------+        +---------------------+       +------------------+
   | fresh VPS     |  --->  | preflight checks    |  ---> | LEMP stack       |
   | SSH/root      |        | setup.sh            |       | nginx/PHP/MariaDB|
   | DNS A/AAAA    |        | add-domain.sh <d>   |       | site per domain  |
   | domain name(s)|        | tls.sh <d>          |       | HTTPS cert       |
   | .env secrets  |        | tests/smoke.sh      |       | verified state   |
   +---------------+        +---------------------+       +------------------+
```

### Per-domain isolation

```text
                        INTERNET :80 / :443
                               |
                         +-----+-----+
                         |   nginx   |   (shared)
                         +-----+-----+
                               |
            +------------------+------------------+
            |                                     |
     server_name a.com                    server_name b.com
            |                                     |
   /var/www/a.com/public_html      /var/www/b.com/public_html
   logs/a.com.access.log           logs/b.com.access.log
            |                                     |
            +------------------+------------------+
                               v
                    PHP-FPM shared pool (phase 1)
                               |
            +------------------+------------------+
            v                                     v
     DB: a_com / user a_u                 DB: b_com / user b_u
     (least privilege)                   (least privilege)
```

### Checking phase (preflight)

```text
                              Setup Tools
   +-------------------------------------------------------------------+
   | Checking Phase                                                    |
   |                                                                   |
   |   [Check OS Info]                                                 |
   |          |                                                        |
   |          v                                                        |
   |       <setup.sh> --run--> <preflight.sh> --check--> [Execution     |
   |          |                  (base)         context, OS, package   |
   |          |                                 manager, panel/stack,  |
   |          |                                 conflicts, resources]  |
   |          v                                                        |
   |   [Domain format check]                                           |
   |          |                                                        |
   |          +----------------+----------------+                      |
   |          v                v                v                      |
   |    <add-domain.sh>   <tls.sh>   <remove-domain.sh>                |
   |          |                |                |                      |
   |          v                v                v                      |
   |    [domain format,  [LE reach-    [same safety                    |
   |     DNS, port        ability,      checks before                  |
   |     availability,    NTP sync]     removal]                       |
   |     duplicate-domain]                                             |
   +-------------------------------------------------------------------+
```

### Installer flow (`bash scripts/install.sh [domain...] [--smoke]`)

```text
        +--------------------------------+
        | 1. preflight_check base        |  OS/arch, pkg mgr, panels,
        +---------------+----------------+  ports 80/443, resources
                        | pass (fail -> stop; nothing changed)
                        v
        +--------------------------------+
        | 2. setup.sh                   |  apt, UFW, chrony, nginx,
        +---------------+----------------+  MariaDB, PHP-FPM (gated reloads)
                        | for each domain
                        v
        +--------------------------------+
        | 3. add-domain.sh <domain>      |  docroot, marker, logs, vhost,
        +---------------+----------------+  dedicated DB + user, nginx -t
                        v
        +--------------------------------+
        | 4. tls.sh <domain>             |  certbot staging (LE_STAGING=1)
        +---------------+----------------+  -> production, renew dry-run
                        | --smoke
                        v
        +--------------------------------+
        | 5. tests/smoke.sh              |  HTTPS 200, marker, PHP, DB,
        +--------------------------------+  renewal timer
```

### Domain lifecycle

```text
   add-domain.sh --> nginx -t gate --> HTTP site live
        |                                   |
        |                                   v
        |                        tls.sh (LE_STAGING=1 -> staging)
        |                                   |
        |                                   v
        |                        tls.sh (production cert)
        |                                   |
        |                                   v
        |                        smoke.sh (verify marker/PHP/DB)
        |                                   |
        +<-------- remove-domain.sh --------+
                  (confirm; disable vhost; drop DB/user; nginx -t)
```

### Safety / test loop

```text
   snapshot --> preflight --> install --> smoke --> reset from snapshot
                   |            |          |
              fail-fast    gated reloads   no duplicate
              (no mutation) nginx -t /     vhosts/DB/users
                           php-fpm -t
```

## Prerequisites

- A fresh **Ubuntu 24.04 LTS** VPS (VM/bare metal, not a container), root or passwordless sudo
- DNS A/AAAA records for each domain pointing at the VPS IP
- Ports 22/80/443 open in the cloud security group
- Scripts are executed **on the VPS itself** — see `PLAN.md` (no remote SSH installer)
- Copy the repo to the VPS (`git clone`), then run the commands in its terminal

## Quick protocols

All commands below run on the VPS, from the repo directory.

### One command (default)

```bash
# Base LEMP + one or more domains + TLS + optional smoke, all in one go
bash scripts/install.sh example.com --smoke

# From config/domains.conf instead of CLI args (no domain argument)
bash scripts/install.sh --smoke

# Staging cert first, then production (per domain)
LE_STAGING=1 bash scripts/install.sh example.com --smoke

# Provision a WordPress site instead of the static marker page
bash scripts/prepare-wordpress.sh                       # once: download shared template
bash scripts/add-domain.sh example.com --app wordpress  # copy template + wp-config.php
bash scripts/install.sh example.com --app wordpress --smoke
```

### Step by step (same flow, manually)

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
bash tests/smoke.sh example.com

# 4. Renewal check
bash scripts/tls.sh --renew-dry-run

# 5. Remove a domain
bash scripts/remove-domain.sh example.com
```

Secrets live in `<repo_dir>/.env` — the root of whichever checkout you run the scripts from (e.g. `/root/webserver-archi-automation/.env` after a `git clone`). Copy `config/.env.example` to `.env` (or `config/.env`), set mode `600`, and never commit it. `.env` is gitignored, so `git pull` does not carry it — copy it into a new checkout before replacing an old one.

### Removing a domain

`remove-domain.sh` is destructive and asks for confirmation — it disables the vhost, removes the docroot and per-domain logs, drops the dedicated database and user, removes the credential from `.env`, and reloads nginx behind `nginx -t`. To skip the prompt (automation):

```bash
bash scripts/remove-domain.sh example.com --yes
```

Re-running it on an already-removed domain is a no-op.

### Rollback notes

- Take a provider snapshot before the first install; restore it from the provider console if the stack breaks.
- Every service change is gated by `nginx -t` / `php-fpm8.x -t` — a failed config test leaves the previously running config live.
- A failed `add-domain.sh` / `tls.sh` run leaves earlier domains untouched.
- To recover one domain: re-create it with `add-domain.sh <domain>` (and `tls.sh <domain>` for HTTPS); all steps are idempotent.

### Let's Encrypt caveats

- Use `LE_STAGING=1 bash scripts/tls.sh <domain>` for the first pass. Staging certs are untrusted by browsers but do not count against production rate limits.
- Only flip to production once staging is green. The script reissues automatically if it detects a staging cert.
- `www.<domain>` is included only if it resolves to the VPS.
- Renewal is handled by `certbot.timer`; verify with `bash scripts/tls.sh --renew-dry-run`.

### WordPress sites

WordPress is provisioned from a shared, read-only template, not downloaded per site:

```bash
# Download once into /var/lib/wsa/wordpress (no-op if already present; --update refreshes)
bash scripts/prepare-wordpress.sh

# Add a domain with WordPress instead of the static marker page
bash scripts/add-domain.sh example.com --app wordpress
```

`add-domain.sh` copies the template into the docroot and generates `wp-config.php` from that domain's database credentials, with per-domain salts and table prefix. Existing site content is never overwritten on re-run. In `config/domains.conf` batch mode, use `example.com|wordpress` per line (plain `example.com` stays static). Updating the shared template affects only **new** domains — existing sites update via wp-admin / wp-cli.

The web admin panel (Phase 8) exposes this as a **Deploy WordPress** action.

### Path to LAMP

Only the package list and the vhost template are stack-coupled. The domain pattern — docroot, per-domain logs, dedicated database + least-privilege user — is shared. LAMP support can be added later by an Apache variant of `setup.sh` and a matching vhost template, without changing `add-domain.sh`'s domain/DB model.
