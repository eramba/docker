#!/bin/sh

su -s /bin/bash -c "printenv | grep DB_ > /var/www/eramba/.env" www-data
su -s /bin/bash -c "printenv | grep CACHE_URL >> /var/www/eramba/.env" www-data
su -s /bin/bash -c "printenv | grep USE_PROXY >> /var/www/eramba/.env" www-data
su -s /bin/bash -c "printenv | grep PROXY_ >> /var/www/eramba/.env" www-data

su -s /bin/bash -c "crontab -u www-data /etc/cron.d/eramba-crontab" www-data

exec docker-php-entrypoint "$@"
