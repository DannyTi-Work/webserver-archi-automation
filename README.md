# Web Server Architecture Automation Deploy
## Feature
- LEMP: Linux, Nginx, MySQL/MariaDB and PHP/PHP-FPM
- LAMP: Linux, Apache2, MySQL/MariaDB and PHP/PHP-FPM


## Summary

Automates a fresh Ubuntu VPS into a LEMP server that hosts multiple web domains. Each domain gets its own docroot, logs and MariaDB database/user, with Let's Encrypt TLS. Everything runs through guarded bash scripts: `preflight.sh` checks requirements before anything changes, `setup.sh` installs the base stack, `add-domain.sh` / `tls.sh` / `remove-domain.sh` manage domains, `tests/smoke.sh` verifies the result, and `install.sh` runs the whole flow in one command. The full plan is in `PLAN.md`.

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
