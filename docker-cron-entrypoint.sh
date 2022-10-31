#!/bin/sh

cd /var/www/eramba/app/upgrade/vendor/eramba/docker || exit

su -s /bin/bash -c "printenv | grep DB_ > .env" www-data
su -s /bin/bash -c "printenv | grep CACHE_URL >> .env" www-data
su -s /bin/bash -c "printenv | grep PUBLIC_ADDRESS >> .env" www-data
su -s /bin/bash -c "printenv | grep HTTP_HOST >> .env" www-data

su -s /bin/bash -c "crontab -u www-data /etc/cron.d/eramba-crontab" www-data

exec docker-php-entrypoint "$@"
