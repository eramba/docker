#FROM php:8.1-apache as pre-build
#
#RUN apt-get update && apt upgrade -y \
#	&& apt install -y apt-utils vim wget curl libicu-dev libicu-dev libzip-dev libjpeg62-turbo-dev libpng-dev \
#     libfreetype6-dev libbz2-dev libldap2-dev libcurl4-openssl-dev openssl libssl-dev cron wkhtmltopdf zip unzip git
#RUN pecl install -o -f redis-5.3.7
#RUN rm -rf /tmp/pear
#RUN docker-php-ext-install -j$(nproc) intl gd
#RUN docker-php-ext-install bz2 pdo_mysql zip exif ldap exif sysvsem
#RUN docker-php-ext-enable redis
#
#RUN cp -s /usr/bin/wkhtmltopdf /usr/local/bin/wkhtmltopdf

## base
FROM ghcr.io/eramba/php:8.1-apache as base

# Install rsync
RUN apt-get update && apt-get install -y rsync

# Setup vhost
COPY ./docker/apache/vhost.conf /etc/apache2/sites-available/000-default.conf

# Setup php
COPY ./docker/php/php.ini /usr/local/etc/php/php.ini

# Setup Cron tasks for eramba, hourly daily yearly cron with worker starting up every 10 minutes
COPY ./docker/crontab/crontab /etc/cron.d/eramba-crontab

RUN chmod 0644 /etc/cron.d/eramba-crontab
RUN chown www-data: /etc/cron.d/eramba-crontab
RUN crontab -u www-data /etc/cron.d/eramba-crontab
# Create the log file to be able to run tail
RUN touch /var/log/cron.log
RUN chown www-data: /var/log/cron.log
RUN chmod +w /var/log/cron.log

RUN chmod gu+rw /var/run
RUN chmod gu+s /usr/sbin/cron

RUN a2enmod rewrite

RUN mkdir /var/www/.composer
RUN mkdir -p /var/www/.cache/composer
RUN mkdir /var/www/.ssh

RUN chown www-data: -R /var/www/


## app
FROM base as eramba

ARG COMPOSER=composer.json
ARG UID=33
ARG GID=33
ARG UNAME=www-data

## To be able to specify composer.json file for a build.
ENV COMPOSER=${COMPOSER}

COPY ./docker/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

COPY --chown=$UNAME:$UNAME . /var/www/eramba

RUN --mount=type=ssh,uid=$UID,gid=$GID su -s /bin/bash -c "mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts" $UNAME
RUN --mount=type=ssh,uid=$UID,gid=$GID su -s /bin/bash -c "ssh -T git@github.com 2>&1 | tee /dev/null" $UNAME
RUN --mount=type=ssh,uid=$UID,gid=$GID su -s /bin/bash -c "cd /var/www/eramba && php composer.phar clearcache" $UNAME
RUN --mount=type=ssh,uid=$UID,gid=$GID su -s /bin/bash -c "cd /var/www/eramba && php composer.phar install --prefer-dist --no-interaction --ignore-platform-reqs" $UNAME

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["apache2-foreground"]
