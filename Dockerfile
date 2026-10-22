FROM php:8.5-fpm-alpine

# set version for wordpress and sha1
# These are the build-time defaults. The weekly update job (update.sh) rolls the
# image forward by rebuilding with:
#   docker build --build-arg WPLITE_VERSION=<latest> --build-arg WPLITE_SHA1=<sha1>
# so the version is fully parameterized (no hardcoded copies to keep in sync).
ARG WPLITE_VERSION=7.1.3
ARG WPLITE_SHA1=491a78c7676b15dffcc69130c6054b8f49228a91
ENV WPLITE_VERSION=${WPLITE_VERSION}
ENV WPLITE_SHA1=${WPLITE_SHA1}
RUN echo "WPLITE_VERSION: ${WPLITE_VERSION} ${WPLITE_SHA1}"

# NOTE: WORDPRESS_DEBUG is intentionally NOT forced on. It defaults to off (see
# wp-config-docker.php). Set WORDPRESS_DEBUG=true at runtime to enable debugging.

# persistent dependencies
RUN set -eux; \
	## NGINX User
	adduser -u 1011 -h /var/www -s /bin/false -D xyz && \
	addgroup xyz users && \
	apk add --no-cache \
		openrc \
# in theory, docker-entrypoint.sh is POSIX-compliant, but priority is a working, consistent image
		bash \
# Ghostscript is required for rendering PDF previews
		ghostscript \
# Alpine package for "imagemagick" contains ~120 .so files, see: https://github.com/docker-library/wordpress/pull/497
		imagemagick \
# sqlite3 is required for the sqlite database plugin
		sqlite \
		sqlite-dev \
# php-pdo_sqlite is required for the sqlite database plugin
		php-pdo_sqlite \
# nginx is required for the nginx webserver
		nginx \
	;

# install the PHP extensions we need (https://make.wordpress.org/hosting/handbook/handbook/server-environment/#php-extensions)
RUN set -ex; \
	\
	apk add --no-cache --virtual .build-deps \
		$PHPIZE_DEPS \
		freetype-dev \
		icu-dev \
		imagemagick-dev \
		libjpeg-turbo-dev \
		libpng-dev \
		libwebp-dev \
		libzip-dev \
	; \
	\
	docker-php-ext-configure gd \
		--with-freetype \
		--with-jpeg \
		--with-webp \
	; \
	docker-php-ext-install -j "$(nproc)" \
		bcmath \
		exif \
		gd \
		intl \
		mysqli \
		zip \
		pdo \
		pdo_sqlite \
	; \
	pecl channel-update pecl.php.net; \
	pecl install imagick-3.8.1; \
	docker-php-ext-enable imagick; \
	\
# some misbehaving extensions end up outputting to stdout 🙈 (https://github.com/docker-library/wordpress/issues/669#issuecomment-993945967)
	out="$(php -r 'exit(0);')"; \
	[ -z "$out" ]; \
	err="$(php -r 'exit(0);' 3>&1 1>&2 2>&3)"; \
	[ -z "$err" ]; \
	\
	extDir="$(php -r 'echo ini_get("extension_dir");')"; \
	[ -d "$extDir" ]; \
	runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive "$extDir" \
			| tr ',' '\n' \
			| sort -u \
			| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
	)"; \
	apk add --no-network --virtual .wordpress-phpexts-rundeps $runDeps; \
	apk del --no-network .build-deps; \
	\
	! { ldd "$extDir"/*.so | grep 'not found'; }; \
# check for output like "PHP Warning:  PHP Startup: Unable to load dynamic library 'foo' (tried: ...)
	err="$(php --version 3>&1 1>&2 2>&3)"; \
	[ -z "$err" ]

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN set -eux; \
	{ \
		echo 'opcache.memory_consumption=128'; \
		echo 'opcache.interned_strings_buffer=8'; \
		echo 'opcache.max_accelerated_files=4000'; \
		echo 'opcache.revalidate_freq=2'; \
	} > /usr/local/etc/php/conf.d/opcache-recommended.ini
# https://wordpress.org/support/article/editing-wp-config-php/#configure-error-logging
RUN { \
# https://www.php.net/manual/en/errorfunc.constants.php
# https://github.com/docker-library/wordpress/issues/420#issuecomment-517839670
		echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
		echo 'display_errors = Off'; \
		echo 'display_startup_errors = Off'; \
		echo 'log_errors = On'; \
		echo 'error_log = /dev/stderr'; \
		echo 'log_errors_max_len = 1024'; \
		echo 'ignore_repeated_errors = On'; \
		echo 'ignore_repeated_source = Off'; \
		echo 'html_errors = Off'; \
	} > /usr/local/etc/php/conf.d/error-logging.ini

# Security hardening: disable dangerous PHP functions (mirrors deb-wordpress).
# These are not needed by WordPress at runtime and are common post-exploitation
# / RCE vectors. (phpinfo is left enabled so plugin "system status" pages work;
# the exposed /info.php page is removed instead.)
RUN { \
		echo 'disable_functions = exec,passthru,shell_exec,system,proc_open,proc_close,proc_terminate,popen,curl_multi_exec,parse_ini_file,show_source'; \
	} > /usr/local/etc/php/conf.d/security-hardening.ini

# Realistic PHP upload/execution limits. The .htaccess php_value directives do NOT
# apply under nginx+php-fpm, so set them here where they actually take effect.
RUN { \
		echo 'upload_max_filesize = 64M'; \
		echo 'post_max_size = 64M'; \
		echo 'memory_limit = 256M'; \
		echo 'max_execution_time = 120'; \
		echo 'max_input_time = 120'; \
	} > /usr/local/etc/php/conf.d/limits.ini

RUN set -eux; \
	version=${WPLITE_VERSION} \
	sha1=${WPLITE_SHA1}; \
	\
	curl -o wordpress.tar.gz -fL "https://wordpress.org/wordpress-$version.tar.gz"; \
	echo "$sha1 *wordpress.tar.gz" | sha1sum -c -; \
	\
# upstream tarballs include ./wordpress/ so this gives us /usr/src/wordpress
	tar -xzf wordpress.tar.gz -C /usr/src/; \
	rm wordpress.tar.gz; \
	\
# https://wordpress.org/support/article/htaccess/
	[ ! -e /usr/src/wordpress/.htaccess ]; \
	{ \
		echo '# BEGIN WordPress'; \
		echo ''; \
		echo 'RewriteEngine On'; \
		echo 'RewriteRule ^(.*) - [E=HTTP_AUTHORIZATION:%1]'; \
		echo 'RewriteCond %{HTTP:Authorization} ^(.*)'; \
		echo 'RewriteBase /'; \
		echo 'RewriteRule ^index\.php$ - [L]'; \
		echo 'RewriteCond %{REQUEST_FILENAME} !-f'; \
		echo 'RewriteCond %{REQUEST_FILENAME} !-d'; \
		echo 'RewriteRule . /index.php [L]'; \
		echo ''; \
		echo '# END WordPress'; \
		# (kept in sync with limits.ini; inert under nginx, used if run under Apache)
		echo 'php_value upload_max_filesize 64M';\
		echo 'php_value post_max_size 64M';\
		echo 'php_value memory_limit 256M';\
		echo 'php_value max_execution_time 120';\
		echo 'php_value max_input_time 120';\
	} > /usr/src/wordpress/.htaccess; \
	\
	chown -R www-data:www-data /usr/src/wordpress; \
# pre-create wp-content (and single-level children) for folks who want to bind-mount themes, etc so permissions are pre-created properly instead of root:root
# wp-content/cache: https://github.com/docker-library/wordpress/issues/534#issuecomment-705733507
	mkdir wp-content; \
	for dir in /usr/src/wordpress/wp-content/*/ cache; do \
		dir="$(basename "${dir%/}")"; \
		mkdir "wp-content/$dir"; \
	done; \
	chown -R www-data:www-data wp-content; \
	# 755 (was 1777): wp-content is owned by www-data, so it does not need to be
	# world-writable. Bind-mount users should chown the host dir to www-data (uid 33).
	chmod -R 755 wp-content; \
# install the wp-cli tool
	curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
	chmod +x wp-cli.phar && \
	mv wp-cli.phar /usr/local/bin/wp && \
	touch /.firstrun && \
## Nginx Logs
	ln -sf /dev/stdout /var/log/nginx/access.log && \
	ln -sf /dev/stderr /var/log/nginx/error.log

COPY root/ /

WORKDIR /usr/src/wordpress/

COPY --chown=www-data:www-data wp-config-docker.php /usr/src/wordpress/wp-config-docker.php

# 755 (was 777): the entrypoint and init script need to be executable, not world-writable.
RUN chmod 755 /init.sh /etc/init.d/php-fpm

# reduce privilege-escalation surface from utilities not needed at runtime
RUN set -eux; \
	for f in \
		/usr/bin/chage \
		/usr/bin/chfn \
		/usr/bin/chsh \
		/usr/bin/expiry \
		/usr/bin/gpasswd \
		/usr/bin/mount \
		/usr/bin/newgrp \
		/usr/bin/passwd \
		/usr/bin/su \
		/usr/bin/umount \
		/usr/lib/mysql/plugin/auth_pam_tool_dir/auth_pam_tool \
		/usr/sbin/unix_chkpwd \
	; do \
		if [ -e "$f" ]; then chmod ug-s "$f"; fi; \
	done

# Remove any remaining setuid/setgid bits to prevent privilege escalation (mirrors deb-wordpress)
RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# Persist wp-content (themes, plugins, uploads, and the SQLite database at
# wp-content/wordpress.db) so it survives container recreation (docker rm + docker
# run). Without this, the DB lives in the container's writable layer and is deleted
# when the container is removed. Mount a named volume to keep it, e.g.:
#   -v wplite-content:/usr/src/wordpress/wp-content
VOLUME /usr/src/wordpress/wp-content

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
	CMD php -r '$s=@fsockopen("127.0.0.1",80); if(!$s){exit(1);} fclose($s);'

ENTRYPOINT ["/init.sh"]

LABEL author="tekmanic" \
    version=${WPLITE_VERSION} \
    documentation="https://github.com/tekmanic/alp-wplite" \
    license="MIT"
