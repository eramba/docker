#!/bin/sh

su -s /bin/bash -c "printenv | grep DB_ > /tmp/eramba.env" www-data
su -s /bin/bash -c "printenv | grep CACHE_URL >> /tmp/eramba.env" www-data
su -s /bin/bash -c "printenv | grep PUBLIC_ADDRESS >> /tmp/eramba.env" www-data
su -s /bin/bash -c "printenv | grep HTTP_HOST >> /tmp/eramba.env" www-data
su -s /bin/bash -c "printenv | grep USE_PROXY >> /tmp/eramba.env" www-data
su -s /bin/bash -c "printenv | grep PROXY_ >> /tmp/eramba.env" www-data

su -s /bin/bash -c "crontab -u www-data /etc/cron.d/eramba-crontab" www-data

exec docker-php-entrypoint "$@"
