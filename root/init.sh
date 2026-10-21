#!/bin/bash
set -e

server_name="${SERVER_NAME:-localhost}"
url="${URL:-http://localhost:8081}"
title="${TITLE:-"WordPress-Sample-Title"}"
admin_name="${ADMIN_NAME:-admin}"
admin_password="${ADMIN_PASSWORD:-admin}"
admin_email="${ADMIN_EMAIL:-admin@domain.com}"
plugins="${PLUGINS:-}"
theme="${THEME:-twentytwentyfour}"
WORDPRESS_ROOT=/usr/src/wordpress
SQLITE_PLUGIN_VERSION="${SQLITE_PLUGIN_VERSION:-2.1.15}"

# Initialize first run
if [[ -e /.firstrun ]]; then
	echo; echo "✨ Enabling the default NGINX site"
	mkdir /etc/nginx/sites-enabled
	ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/

	echo; echo "✨ Creating wp-config.php file"
	wpEnvs=( "${!WORDPRESS_@}" )
	if [ ! -s wp-config.php ] && [ "${#wpEnvs[@]}" -gt 0 ]; then
		for wpConfigDocker in \
			wp-config-docker.php \
			${WORDPRESS_ROOT}/wp-config-docker.php \
		; do
			if [ -s "$wpConfigDocker" ]; then
				echo >&2 "--> copying '$wpConfigDocker' (${wpEnvs[*]})"
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
				if [ "$uid" = '0' ]; then
					# attempt to ensure that wp-config.php is owned by the run user
					# could be on a filesystem that doesn't allow chown (like some NFS setups)
					chown "$user:$group" wp-config.php || true
				fi
				break
			fi
		done
	fi

	echo; echo "✨ Installing sqlite-database-integration plugin from source"
	wget https://github.com/WordPress/sqlite-database-integration/archive/refs/tags/v${SQLITE_PLUGIN_VERSION}.tar.gz
	mkdir -p ${WORDPRESS_ROOT}/wp-content/plugins/
	tar xzf v${SQLITE_PLUGIN_VERSION}.tar.gz -C ${WORDPRESS_ROOT}/wp-content/plugins/
	rm v${SQLITE_PLUGIN_VERSION}.tar.gz
	mv ${WORDPRESS_ROOT}/wp-content/plugins/sqlite-database-integration-${SQLITE_PLUGIN_VERSION} ${WORDPRESS_ROOT}/wp-content/plugins/sqlite-database-integration
	mv ${WORDPRESS_ROOT}/wp-content/plugins/sqlite-database-integration/db.copy ${WORDPRESS_ROOT}/wp-content/db.php
	
	# Execute the PHP script
	echo; echo "✨ Running wp core install: --url=${url} --title=${title} --admin_name=${admin_name} --admin_password=${admin_password} --admin_email=${admin_email} --allow-root --skip-email"
	wp core install --url=${url} --title=${title} --admin_name=${admin_name} --admin_password=${admin_password} --admin_email=${admin_email} --allow-root --skip-email
	wp theme install ${theme} --activate --allow-root
	if [[ -n "$plugins" ]]; then
		for plugin in $plugins; do
			echo "Installing plugin \"$plugin\"..."
			if ! wp plugin install $plugin --activate --allow-root; then
				echo >&2 "Warning: unable to install plugin '$plugin'; continuing startup"
			fi
		done
	fi
	chown www-data:www-data $WORDPRESS_ROOT -R
	# fi

	# allow specifying a custom client_max_body_size for nginx
	if [[ -n $NGINX_CLIENT_MAX_BODY_SIZE ]]; then
		sed -i.bak "s/client_max_body_size .*;/client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE};/g" /etc/nginx/nginx.conf
	fi

	# Some incompatible plugins with PHP 8.1 - fixes a bug
	sed -i "s/strtoupper( \$this->value )/strtoupper( \$this->value ?? '' )/g" $WORDPRESS_ROOT/wp-content/plugins/sqlite-database-integration/wp-includes/sqlite/class-wp-sqlite-token.php

	# Enable application passwords by adding this code to functions.php
	echo "add_filter( 'wp_is_application_passwords_available', '__return_true' );" >> $WORDPRESS_ROOT/wp-content/themes/${theme}/functions.php

	# Use wp option to setup permalinks and configuration app_pass
	wp option update permalink_structure '/%postname%/' --allow-root
	wp user application-password create admin "restapi" --allow-root

	rm -f /.firstrun
fi

php-fpm -D
nginx -g "daemon off;"