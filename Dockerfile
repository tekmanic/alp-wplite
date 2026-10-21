FROM php:8.5-fpm-alpine

# set version for wordpress and sha1
# DO NOT UPDATE HERE, UPDATE in Makefile
ARG WPLITE_VERSION=7.0.3
ENV WPLITE_VERSION=7.0.3
ARG WPLITE_SHA1=344b74d7cbf13c55ba0f12cad207c06cfee4368a
ENV WPLITE_SHA1=${WPLITE_SHA1}
RUN echo WPLITE_VERSION: ${WPLITE_VERSION} ${WPLITE_SHA1}

ENV WORDPRESS_DEBUG=true

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

RUN set -eux; \
	version=7.0.3 \
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
		# echo 'RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]'; \
		echo 'RewriteBase /'; \
		echo 'RewriteRule ^index\.php$ - [L]'; \
		echo 'RewriteCond %{REQUEST_FILENAME} !-f'; \
		echo 'RewriteCond %{REQUEST_FILENAME} !-d'; \
		echo 'RewriteRule . /index.php [L]'; \
		echo ''; \
		echo '# END WordPress'; \
		echo 'php_value upload_max_filesize 5120M';\
		echo 'php_value post_max_size 5120M';\
		echo 'php_value memory_limit 5120M';\
		echo 'php_value max_execution_time 300';\
		echo 'php_value max_input_time 300';\
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
	chmod -R 1777 wp-content; \
# install the wp-cli tool
	curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
	chmod +x wp-cli.phar && \
	mv wp-cli.phar /usr/local/bin/wp && \
	touch /.firstrun && \
## Nginx Logs
	ln -sf /dev/stdout /var/log/nginx/access.log && \
	ln -sf /dev/stderr /var/log/nginx/error.log && \
	echo "<?php phpinfo(); ?>" > /usr/src/wordpress/info.php

COPY root/ /

WORKDIR /usr/src/wordpress/

# COPY --chown=www-data:www-data wordpress.db /usr/src/wordpress/wp-content/
COPY --chown=www-data:www-data wp-config-docker.php /usr/src/wordpress/wp-config-docker.php

RUN chmod 777 /init.sh /etc/init.d/php-fpm

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

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
	CMD php -r '$s=@fsockopen("127.0.0.1",80); if(!$s){exit(1);} fclose($s);'

ENTRYPOINT ["/init.sh"]
# CMD tail -f /dev/null

LABEL author="tekmanic" \
    version=7.0.3 \
    documentation="https://github.com/tekmanic/alp-wplite" \
    license="MIT"