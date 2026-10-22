#!/bin/bash
set -e

server_name="${SERVER_NAME:-localhost}"
url="${URL:-http://localhost:8081}"
title="${TITLE:-"WordPress-Sample-Title"}"
admin_name="${ADMIN_NAME:-admin}"
# Strong admin password: use the provided one, or generate a random one. Never fall
# back to a static weak default like "admin".
if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
	admin_password="${ADMIN_PASSWORD}"
else
	admin_password="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	echo "⚠️  ADMIN_PASSWORD not set — generated a random admin password:"
	echo "   user: ${admin_name}"
	echo "   pass: ${admin_password}"
	echo "   (change it after first login, or set ADMIN_PASSWORD for a known value)"
fi
admin_email="${ADMIN_EMAIL:-admin@domain.com}"
plugins="${PLUGINS:-}"
theme="${THEME:-twentytwentyfour}"
WORDPRESS_ROOT=/usr/src/wordpress
SQLITE_PLUGIN_VERSION="${SQLITE_PLUGIN_VERSION:-2.1.15}"

# Initialize first run
if [[ -e /.firstrun ]]; then
	echo; echo "✨ Enabling the default NGINX site"
	mkdir -p /etc/nginx/sites-enabled
	ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/

	echo; echo "✨ Creating wp-config.php file"
	# Always create wp-config.php from the template if missing. The template has
	# sensible SQLite defaults (DB at wp-content/wordpress.db), so the image works
	# out-of-the-box even with no WORDPRESS_* env vars set.
	if [ ! -s wp-config.php ]; then
		for wpConfigDocker in \
			wp-config-docker.php \
			${WORDPRESS_ROOT}/wp-config-docker.php \
		; do
			if [ -s "$wpConfigDocker" ]; then
				echo >&2 "--> generating wp-config.php from '$wpConfigDocker'"
				# using "awk" to replace all instances of "put your unique phrase here" with a properly unique string (for AUTH_KEY and friends to have safe defaults if they aren't specified with environment variables)
				awk '
					/put your unique phrase here/ {
						cmd = "head -c1m /dev/urandom | sha1sum | cut -d\\  -f1"
						cmd | getline str
						close(cmd)
						gsub("put your unique phrase here", str)
					}
					{ print }
				' "$wpConfigDocker" > wp-config.php
				chown www-data:www-data wp-config.php 2>/dev/null || true
				break
			fi
		done
	fi

	echo; echo "✨ Installing sqlite-database-integration plugin from source (required)"
	# The plugin (and the db.php it produces) persist in the wp-content volume.
	# Only (re)install when db.php is absent — re-extracting over an existing
	# plugin dir breaks the `mv` and, under `set -e`, crashes the container.
	if [[ -f ${WORDPRESS_ROOT}/wp-content/db.php ]]; then
		echo "   sqlite-database-integration already present (persisted in volume) — skipping"
	else
		wget -q --tries=3 --timeout=30 https://github.com/WordPress/sqlite-database-integration/archive/refs/tags/v${SQLITE_PLUGIN_VERSION}.tar.gz \
			|| { echo "ERROR: failed to download sqlite-database-integration v${SQLITE_PLUGIN_VERSION}; the SQLite DB plugin is required for this image" >&2; exit 1; }
		mkdir -p ${WORDPRESS_ROOT}/wp-content/plugins/
		tar xzf v${SQLITE_PLUGIN_VERSION}.tar.gz -C ${WORDPRESS_ROOT}/wp-content/plugins/
		rm v${SQLITE_PLUGIN_VERSION}.tar.gz
		mv ${WORDPRESS_ROOT}/wp-content/plugins/sqlite-database-integration-${SQLITE_PLUGIN_VERSION} ${WORDPRESS_ROOT}/wp-content/plugins/sqlite-database-integration
		mv ${WORDPRESS_ROOT}/wp-content/plugins/sqlite-database-integration/db.copy ${WORDPRESS_ROOT}/wp-content/db.php
	fi

	# Only run the (irreversible) core install + app-password creation if the site
	# is not already installed. The SQLite DB lives in the wp-content volume and
	# survives container recreation, so re-running `wp core install` against an
	# existing site would be wrong. `wp core is-installed` returns non-zero both
	# when the site is absent and when the DB cannot be reached (true first run).
	if ! wp core is-installed --allow-root >/dev/null 2>&1; then
		echo; echo "✨ Running wp core install: --url=${url} --title=${title} --admin_name=${admin_name} --admin_email=${admin_email} --allow-root --skip-email"
		wp core install --url=${url} --title=${title} --admin_name=${admin_name} --admin_password=${admin_password} --admin_email=${admin_email} --allow-root --skip-email
		wp theme install ${theme} --activate --allow-root
		# Enable application passwords + create a REST app password (first run only)
		echo "add_filter( 'wp_is_application_passwords_available', '__return_true' );" >> $WORDPRESS_ROOT/wp-content/themes/${theme}/functions.php
		wp user application-password create admin "restapi" --allow-root
	else
		echo; echo "✨ Site already installed (DB persisted in volume) — skipping core install"
	fi

	# Install/update requested plugins (non-fatal: one bad slug must not wedge boot)
	if [[ -n "$plugins" ]]; then
		for plugin in $plugins; do
			echo "Installing plugin \"$plugin\"..."
			if ! wp plugin install $plugin --activate --allow-root; then
				echo >&2 "Warning: unable to install plugin '$plugin'; continuing startup"
			fi
		done
	fi

	# Ensure www-data (the PHP-FPM runtime user) owns the tree — including the
	# SQLite DB, which `wp core install` creates as root. Without this, WordPress
	# can read but not write the DB (posts/options/comments would fail).
	chown www-data:www-data $WORDPRESS_ROOT -R

	# allow specifying a custom client_max_body_size for nginx
	if [[ -n $NGINX_CLIENT_MAX_BODY_SIZE ]]; then
		sed -i.bak "s/client_max_body_size .*;/client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE};/g" /etc/nginx/nginx.conf
	fi

	# Some incompatible plugins with PHP 8.1 - fixes a bug (guard: only if present)
	if [[ -f $WORDPRESS_ROOT/wp-content/plugins/sqlite-database-integration/wp-includes/sqlite/class-wp-sqlite-token.php ]]; then
		sed -i "s/strtoupper( \$this->value )/strtoupper( \$this->value ?? '' )/g" $WORDPRESS_ROOT/wp-content/plugins/sqlite-database-integration/wp-includes/sqlite/class-wp-sqlite-token.php
	fi

	# Use wp option to setup permalinks (idempotent)
	wp option update permalink_structure '/%postname%/' --allow-root

	rm -f /.firstrun
fi

php-fpm -D
nginx -g "daemon off;"
