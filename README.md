# alp-wplite

WordPress + SQLite, on a minimal Alpine base (`php:8.5-fpm-alpine` + nginx + php-fpm + openrc).

- **WordPress:** 7.1.3 (pinned via `ARG WPLITE_VERSION` / `ARG WPLITE_SHA1`; see `.version`)
- **Database:** SQLite via the [sqlite-database-integration](https://github.com/WordPress/sqlite-database-integration) plugin (no MariaDB). The DB lives at `wp-content/wordpress.db`.
- **Web server:** nginx (reverse-proxy-ready) + PHP-FPM.

## Quick start

```bash
make run          # builds + runs on http://localhost:8081
```

Or manually:

```bash
docker build -t alp-wplite:latest .
docker run -d --name alp-wplite -p 8081:80 \
  -e URL="http://localhost:8081" \
  -e TITLE="My Site" \
  -v wplite-content:/usr/src/wordpress/wp-content \
  alp-wplite:latest
```

> **Set `ADMIN_PASSWORD`** to a known value, or the image generates a random one on
> first run and prints it to `docker logs alp-wplite` (there is no static `admin/admin` default).

## Persistence

`wp-content` (themes, plugins, uploads, **and the SQLite DB**) is a declared `VOLUME`.
Mount a named volume (`-v wplite-content:/usr/src/wordpress/wp-content`) so the site
survives container recreation. Without it, the DB is lost on `docker rm`.

## Keeping it updated

`update.sh` rolls the image forward to the latest stable WordPress: it checks
wordpress.org, rebuilds the image with the new version + sha1, recreates the container
(preserving the volume), and verifies the site responds. It's idempotent.

```bash
make update       # or: bash update.sh
```

A weekly cron job (Tuesday 09:00) runs this automatically.

## Hardening

Realistic, container-appropriate hardening (inspired by `deb-wordpress`):

- **No exposed `phpinfo`** — the `/info.php` page was removed.
- **Debug off by default** — `WORDPRESS_DEBUG` is not forced on; set it explicitly to enable.
- **Dangerous PHP functions disabled** — `exec, passthru, shell_exec, system, proc_*, popen, curl_multi_exec, parse_ini_file, show_source`.
- **Realistic upload limits** — 64M upload / 256M memory (was 5GB in the old `.htaccess`, which is inert under nginx anyway; now set in `limits.ini` where it takes effect).
- **Tight file permissions** — `init.sh`/`php-fpm` are `755` (was `777`); `wp-content` is `755` (was `1777`); setuid/setgid bits stripped.
- **Strong admin password** — random if `ADMIN_PASSWORD` is unset (no `admin` default).
- **nginx:**
  - per-IP rate limiting (login `20r/m`, REST API `10r/s`, general `10r/s`) → returns `429`, never a hard ban
  - scanner/malicious User-Agent block (sqlmap, nikto, wpscan, nuclei, …) → `403`
  - `xmlrpc.php` disabled → `403`
  - sensitive files blocked (`wp-config.php`, `.env`, `.git`, `composer.*`, …) → `403`
  - security headers (`X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`)
  - `server_tokens off`, request timeouts
- **Idempotent first-run** — `wp core install` only runs if the site isn't already installed, so recreating the container (e.g. via the update job) never re-initializes a live site.

> **TLS / HSTS:** this container serves plain HTTP on `:80`. Terminate TLS at a reverse
> proxy (which should send `Strict-Transport-Security`) and point `URL` at the public host.
> If behind a proxy, configure nginx `real_ip` so rate limiting sees the true client IP.

## Scanning

```bash
make scan         # trivy HIGH,CRITICAL -> scanresults
```

## Notes

- The SQLite DB plugin is a hard dependency (downloaded from GitHub at first run). If that
  download fails, the container exits with a clear error rather than booting without a DB.
- `wp user application-password create admin "restapi"` creates a REST application password
  on first run (stored in the DB). Remove that line in `root/init.sh` if you don't need it.
