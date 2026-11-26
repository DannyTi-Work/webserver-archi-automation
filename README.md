# Web Server Architecture Automation Deploy
## Feature
- LEMP: Linux, Nginx, MySQL/MariaDB and PHP/PHP-FPM
- LAMP: Linux, Apache2, MySQL/MariaDB and PHP/PHP-FPM


## Summary

Automates a fresh Ubuntu VPS into a LEMP server that hosts multiple web domains. Each domain gets its own docroot, logs and MariaDB database/user, with Let's Encrypt TLS. Every action is an independent module: `preflight.sh` checks requirements before anything changes, `setup.sh` installs the base stack, `add-domain.sh` / `tls.sh` / `remove-domain.sh` manage domains, `prepare-wordpress.sh` provisions the shared WordPress template, `status.sh` reports state as JSON, and `tests/smoke.sh` verifies the result. The full plan is in `PLAN.md`.

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

### Fail-closed default server

`setup.sh` installs a managed `/etc/nginx/conf.d/00-default-reject.conf` (from `templates/nginx-default-reject.conf.tpl`). Any request whose `Host` matches no `server_name` is dropped on :80 (`return 444`) or refused during the TLS handshake on :443 (`ssl_reject_handshake on`). This prevents a domain **without** TLS from being served by another domain's HTTPS vhost on a shared IP. It is installed idempotently behind `nginx -t`; a conflicting `default_server` elsewhere makes setup warn and skip rather than break nginx. `scripts/status.sh` reports it as `default_reject: present|absent`.

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
   |     dup -> hard FAIL]                                             |
   +-------------------------------------------------------------------+
```

### Actions (independent modules)

```text
        +-------------------------------------------+
        | preflight.sh [base|domain|add-domain|tls] |  OS/arch, pkg mgr, panels,
        +-------------------+------------------------+  DNS, ports, LE reachability
                            | (read-only; fail -> nothing changes)
                            v
        +--------------------------------+
        | setup.sh                      |  apt, UFW, chrony, nginx,
        +-------------------+------------+  MariaDB, PHP-FPM (gated reloads)
                            | one-time, idempotent
                            v
        +--------------------------------+
        | prepare-wordpress.sh [--update]|  shared WP template (once)
        +-------------------+------------+
                            |
            +---------------+---------------+
            v               v               v
    +---------------+ +-------------+ +------------------+
    | add-domain.sh | | tls.sh      | | remove-domain.sh |
    | -app wordpress| | staging/prod| | confirm + drop   |
    +-------+-------+ +------+------+ +---------+--------+
            |                |                  |
            +--------+-------+------------------+
                     v
        +--------------------------------+
        | tests/smoke.sh [domain ...]   |  HTTPS 200, marker/WP, PHP, DB,
        +--------------------------------+  redirect
                     |
                     v
        +--------------------------------+
        | status.sh [--json]            |  inventory: app, DB, cert, logs
        +--------------------------------+
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
   snapshot --> preflight --> setup --> add-domain --> tls --> smoke --> reset
                   |            |           |            |        |
              fail-fast    gated reloads  no duplicate  renew check  verified
              (no mutation) nginx -t /    vhosts/DB/    dry-run      state
                           php-fpm -t     users
```

## Prerequisites

- A fresh **Ubuntu 24.04 LTS** VPS (VM/bare metal, not a container), root or passwordless sudo
- DNS A/AAAA records for each domain pointing at the VPS IP
- Ports 22/80/443 open in the cloud security group
- Scripts are executed **on the VPS itself** — see `PLAN.md` (no remote SSH installer)
- Copy the repo to the VPS (`git clone`), then run the commands in its terminal

## Quick protocols

All commands below run on the VPS, from the repo directory. Each action is a separate module — run only what you need.

### Build the stack (once)

```bash
bash scripts/preflight.sh        # check requirements first (read-only)
bash scripts/setup.sh            # base + LEMP
```

### Add a domain

```bash
bash scripts/add-domain.sh example.com                      # static site
bash scripts/add-domain.sh blog.example.com --app wordpress # WordPress site

# batch: one entry per line in config/domains.conf, then no arguments
bash scripts/add-domain.sh
```

### Secure it with TLS

```bash
LE_STAGING=1 bash scripts/tls.sh example.com   # staging first
bash scripts/tls.sh example.com                # then production
bash scripts/tls.sh --renew-dry-run            # renewal check
```

### Verify and inspect

```bash
bash tests/smoke.sh example.com        # full check for one domain
bash tests/smoke.sh                    # all domains from config/domains.conf
bash scripts/status.sh                 # human-readable inventory
bash scripts/status.sh --json          # JSON inventory for the panel
```

### Remove a domain

```bash
bash scripts/remove-domain.sh example.com
```

### WordPress template

```bash
bash scripts/prepare-wordpress.sh          # download once
bash scripts/prepare-wordpress.sh --update # refresh template (new sites only)
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

### Web admin panel

```bash
bash scripts/setup-panel.sh      # install panel vhost (:8083), auth, sudoers, UFW, renewal hook
bash scripts/uninstall-panel.sh  # remove panel only — sites, certs and stack stay intact
```

The panel is served on port **8083** with basic auth. Its dashboard uses `status.sh --json` to list domains (app type, DB/user, cert expiry, logs), and its actions call the same guarded scripts through a sudoers drop-in limited to those script paths. CSRF tokens protect POST actions; see `config/panel.conf.example` for the admin path and credentials.

### Path to LAMP

Only the package list and the vhost template are stack-coupled. The domain pattern — docroot, per-domain logs, dedicated database + least-privilege user — is shared. LAMP support can be added later by an Apache variant of `setup.sh` and a matching vhost template, without changing `add-domain.sh`'s domain/DB model.
