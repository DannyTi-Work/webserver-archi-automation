# Manual baseline — Phase 0

The "check first" phase. This is **not automation**: you install LEMP by hand on a fresh Ubuntu 24.04 VPS and record what you did. This document is the deliverable — its end-state checklist becomes the acceptance criteria that Phases 1–5 must reproduce.

All commands below are executed **on the VPS**, from its terminal (provider console or an SSH terminal session). Nothing here runs on the developer machine.

---

## 0. Fill in your values first

```bash
# Edit these before you start (from the VPS terminal; keep this file in the repo on your dev machine)
VPS_IP="203.0.113.10"          # public IPv4 of the VPS
DOMAIN1="test1.example.com"
DOMAIN2="test2.example.com"
DOMAIN3="test3.example.com"    # optional third domain
DB_PASS="$(openssl rand -base64 24)"   # generated per-domain DB password; record it in your password manager
SNAPSHOT_ID="..."              # provider snapshot / image ID taken before any changes
```

If you use `sudo` instead of a root shell, prefix the commands below with `sudo` (or run `sudo -i` first).

---

## 1. Provider-side setup (not on the VPS)

- [ ] Provision a **fresh Ubuntu 24.04 LTS** VPS (no control panel, no pre-installed stack).
- [ ] Take a snapshot and record its ID in `SNAPSHOT_ID` — every test run must start from zero.
- [ ] Point DNS **A** (and, if available, **AAAA**) records for `DOMAIN1`–`DOMAIN3` at `$VPS_IP`.
- [ ] Open **22 / 80 / 443** in the cloud security group. UFW is handled in step 4.
- [ ] Confirm from your dev machine that DNS resolves before continuing:

```bash
dig +short A "$DOMAIN1" @8.8.8.8
dig +short AAAA "$DOMAIN1" @8.8.8.8
```

Expected: the A record matches `$VPS_IP`.

---

## 2. Verify the environment (on the VPS)

```bash
cat /etc/os-release
# Expect: ID=ubuntu, VERSION_ID="24.04"

hostnamectl
uname -m
# Expect: x86_64 or aarch64

timedatectl
chronyc tracking 2>/dev/null || echo "chrony not installed yet"
ss -ltnp
# Expect: nothing listening on :80 / :443 yet

# Confirm no control panel is installed (preflight will hard-fail on these later)
for p in /usr/local/cpanel /usr/local/psa /usr/local/CyberPanel /www/server/panel \
         /usr/share/webmin /usr/local/hestia; do
  [ -e "$p" ] && echo "PANEL FOUND: $p" || echo "absent: $p"
done
```

---

## 3. Base packages + time sync

```bash
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y curl ca-certificates dnsutils unzip git chrony

systemctl enable --now chrony
chronyc tracking
timedatectl show -p NTP --value
# Expect: NTP status "yes" — TLS issuance in Phase 4 depends on this
```

---

## 4. Firewall (UFW)

```bash
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status numbered
```

Expected: 22/tcp, 80/tcp, 443/tcp all `ALLOW IN`.

---

## 5. nginx

```bash
apt install -y nginx
systemctl enable --now nginx

# Remove the default site so it cannot answer for our domains
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx
systemctl status nginx --no-pager
```

Record: `nginx -t` output (`syntax is ok` / `test is successful`).

---

## 6. MariaDB (hand-hardened)

```bash
apt install -y mariadb-server
systemctl enable --now mariadb

# Ubuntu 24.04 uses unix_socket auth for root by default — verify it
mariadb -e "SELECT user, host, plugin FROM mysql.user WHERE user = 'root';"
# Expect: root@localhost with unix_socket (or auth_socket)

# Drop anonymous users and the test database
mariadb -e "DELETE FROM mysql.user WHERE User='';
            DROP DATABASE IF EXISTS test;
            DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
            FLUSH PRIVILEGES;"

mariadb -e "SELECT user, host FROM mysql.user;"
# Expect: no empty user, no test db
```

---

## 7. PHP-FPM

```bash
apt install -y php-fpm php-mysql php-cli php-curl php-mbstring php-xml php-zip php-gd php-intl

php -v
php-fpm8.3 -t
systemctl status php8.3-fpm --no-pager
```

Record the PHP version (8.3 on Ubuntu 24.04) and the FPM socket path:

```bash
ls -l /run/php/php8.3-fpm.sock
```

---

## 8. One domain by hand (repeat for each test domain)

Replace `DOMAIN` with the actual domain each time. Keep a copy of every command you run — this is what Phase 3 (`add-domain.sh`) will reproduce.

```bash
DOMAIN="$DOMAIN1"
DOCROOT="/var/www/${DOMAIN}/public_html"

# 8a. Docroot + marker file that also probes PHP and MariaDB
mkdir -p "$DOCROOT"
cat > "${DOCROOT}/index.php" <<PHP
<?php
echo "<h1>${DOMAIN}</h1>\n";
echo "PHP OK: " . PHP_VERSION . "<br>\n";
\$db = @new mysqli('localhost', '${DOMAIN//./_}_u', '${DB_PASS}', '${DOMAIN//./_}_db');
echo \$db->connect_error ? "DB FAIL: " . \$db->connect_error : "DB OK";
PHP
chown -R www-data:www-data "/var/www/${DOMAIN}"
chmod -R 755 "/var/www/${DOMAIN}"

# 8b. Database + least-privilege user
DB="${DOMAIN//./_}_db"
USER="${DOMAIN//./_}_u"
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS ${DB};
CREATE USER IF NOT EXISTS '${USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL ON ${DB}.* TO '${USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# 8c. nginx vhost (HTTP only — TLS comes in Phase 4)
cat > "/etc/nginx/sites-available/${DOMAIN}" <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};
    root ${DOCROOT};
    index index.php index.html;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log  /var/log/nginx/${DOMAIN}.error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINX

ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"

nginx -t && systemctl reload nginx
```

Record any deviations (e.g. different PHP socket, extra extensions).

---

## 9. Manual smoke checks

```bash
# Config test passes and reload works
nginx -t && systemctl reload nginx

# Per domain: HTTP 200, marker content, PHP executes, DB connects
for DOMAIN in "$DOMAIN1" "$DOMAIN2" "$DOMAIN3"; do
  [ -z "$DOMAIN" ] && continue
  echo "--- ${DOMAIN} ---"
  curl -sS -o /dev/null -w "HTTP %{http_code}\n" "http://${DOMAIN}/"
  curl -sS "http://${DOMAIN}/index.php"
  echo
done
```

For each domain confirm:

- [ ] `HTTP 200`
- [ ] Response contains `<h1>$DOMAIN</h1>` — proves the **correct vhost** answered, not the default site
- [ ] Response contains `PHP OK` — PHP executed, not served as plain text
- [ ] Response contains `DB OK` — PHP connected to that domain's MariaDB database
- [ ] A different domain returns a different marker — domains are isolated

---

## 10. End-state checklist (acceptance criteria for the automation)

Record this exactly; Phases 1–5 must reach the same state from a fresh VPS:

- [ ] Ubuntu 24.04, fresh snapshot restored before the run
- [ ] No control panel installed; no pre-existing `nginx` / `apache2` / `mariadb-server` / `php*-fpm` stack
- [ ] Ports 22/80/443 open in the cloud security group **and** UFW
- [ ] `chrony` enabled, NTP sync OK
- [ ] `nginx -t` passes and reload works
- [ ] PHP page renders and executes (not plain text)
- [ ] PHP connects to MariaDB
- [ ] Each test domain serves its own marker content (per-domain docroot, logs, DB/user)
- [ ] MariaDB hardened: root via unix_socket, no anonymous users, no test database
- [ ] TLS is **not** part of this baseline — it is verified in Phase 4 (`tls.sh`)

---

## 11. Notes / rollback

```text
Snapshot ID / image ID:  ______________________
Domains used:            ______________________
PHP version / FPM socket:______________________
Date of manual pass:     ______________________
Deviations from the plan:______________________
```

If the VPS gets into a bad state during the manual pass, restore the snapshot and repeat from step 1. That reset-from-snapshot cycle is exactly what Phase 5 repeats to prove the automation is reproducible.
