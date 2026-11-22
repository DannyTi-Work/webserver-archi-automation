# Using the toolchain

Every command runs **on the VPS** as root, from the repo directory.

## Mental model

```text
/root/wsa/                  repo (scripts you run)
/var/www/<domain>/          per-domain docroot
/etc/nginx/conf.d/          per-domain vhost
/var/log/nginx/<domain>.*   per-domain logs
/var/lib/wsa/wordpress/     shared WordPress template (read-only)
/root/wsa/.env              per-domain DB passwords (0600, gitignored)
/etc/letsencrypt/           certificates (NOT removed by remove-domain.sh)
```

The stack (nginx, MariaDB, PHP-FPM, UFW, chrony, certbot) is installed **once**.
Domains are added and removed on top of it.

## Command reference

| What you want | Command |
| --- | --- |
| Check the machine is suitable | `bash scripts/preflight.sh` |
| Install base + LEMP | `bash scripts/setup.sh` |
| Add a static site | `bash scripts/add-domain.sh example.com` |
| Add a WordPress site | `bash scripts/add-domain.sh blog.example.com --app wordpress` |
| Download / refresh the WP template | `bash scripts/prepare-wordpress.sh [--update]` |
| Enable HTTPS | `bash scripts/tls.sh example.com` |
| Test HTTPS on staging first | `LE_STAGING=1 bash scripts/tls.sh example.com` |
| Check renewal works | `bash scripts/tls.sh --renew-dry-run` |
| Verify a site | `bash tests/smoke.sh example.com` |
| Remove a site | `bash scripts/remove-domain.sh example.com` |
| Do everything at once | `bash scripts/install.sh example.com --smoke` |

## Before you start

1. **DNS first.** `example.com` must resolve to the VPS IP *before* `add-domain.sh`;
   preflight compares `dig` against the VPS public IP and hard-fails otherwise.
   `www.example.com` is optional and is included in the certificate only when it resolves.
2. **Root.** All mutating scripts need root or passwordless sudo.
3. **Ports 22/80/443** open at the cloud provider (UFW is handled by `setup.sh`).

## First install, one command

```bash
cd /root/wsa
bash scripts/install.sh example.com --smoke
```

Runs preflight → setup → add-domain → tls → smoke and stops at the first failure.
Re-running is safe: everything already present is skipped.

## Step by step

```bash
bash scripts/preflight.sh                       # read-only, expect 0 failures
bash scripts/setup.sh                           # install / verify LEMP
bash scripts/add-domain.sh example.com          # vhost + DB + user + marker
LE_STAGING=1 bash scripts/tls.sh example.com    # staging certificate first
bash scripts/tls.sh example.com                 # then production
bash tests/smoke.sh example.com
```

## Adding sites

Static (default) — creates a marker page that proves vhost, PHP and DB work:

```bash
bash scripts/add-domain.sh example.com
```

WordPress — copies the shared template and generates `wp-config.php` with that
domain's credentials, unique salts and table prefix:

```bash
bash scripts/prepare-wordpress.sh                 # once; --update to refresh
bash scripts/add-domain.sh blog.example.com --app wordpress
```

Finish the install at `https://blog.example.com/wp-admin/install.php`.

Batch mode — edit `config/domains.conf`, then run without arguments:

```conf
example.com
blog.example.com|wordpress
```

```bash
bash scripts/add-domain.sh
bash scripts/install.sh --smoke
```

## Verifying

```bash
bash tests/smoke.sh example.com    # one domain
bash tests/smoke.sh                # all domains from config/domains.conf
```

Manual equivalents:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://example.com/
curl -sS https://example.com/     # static: <h1> + "PHP OK" + "DB OK"
curl -sSI https://example.com/    # headers
```

## TLS notes

- `LE_STAGING=1` issues an untrusted staging certificate; browsers warn, but it does
  not consume production rate limits. Do staging first.
- The production run detects a staging certificate and replaces it.
- Renewal is automatic (`certbot.timer`); verify with `bash scripts/tls.sh --renew-dry-run`.

## Removing a site

```bash
bash scripts/remove-domain.sh example.com        # asks you to retype the domain
bash scripts/remove-domain.sh example.com --yes  # no prompt
```

Removes the vhost, docroot, per-domain logs, database, DB user and the `.env`
credential, then reloads nginx behind `nginx -t`.

> **Certificates are not removed.** To clean them up too:
> `certbot delete --cert-name example.com --non-interactive`

> **DNS gotcha.** Removal re-runs the `domain` preflight, which includes the DNS
> check. If the A record was already deleted, removal fails — restore DNS
> temporarily or clean up by hand.

## Idempotency

Every script is safe to re-run: installed packages, services, vhosts, databases,
DB users and WordPress content are detected and skipped. The only value that gets
rewritten is `wp-config.php`'s DB password when `.env` and MariaDB drift apart.

## Updating the tool on the VPS

A manual copy (e.g. `/root/wsa`) does not track the repo. Either re-copy the files
or keep a clone:

```bash
git clone https://github.com/DannyTi-Work/webserver-archi-automation.git /root/wsa-git
cd /root/wsa-git && git pull --ff-only
```

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `[FAIL] DNS ... does not resolve` | A record missing or not propagated |
| `[FAIL] control panel installed` | Hestia / cPanel / etc. present — use a clean VPS |
| `[FAIL] conflicting stack packages` | `apache2` or `mysql-server` installed |
| `502 Bad Gateway` | PHP-FPM down or socket group mismatch (re-run `setup.sh`) |
| `DB FAIL` on the marker page | `.env` password ≠ MariaDB user (re-run `add-domain.sh`) |
| WordPress "Error establishing a database connection" | same as above |
| Browser "Unable to connect" on `https://` | certificate not issued yet — use `http://` or run `tls.sh` |
| certbot "Could not automatically find a matching server block" | `www.` resolves but is missing from `server_name` — re-run `add-domain.sh` |
