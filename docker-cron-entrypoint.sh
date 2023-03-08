#!/bin/sh

su -s /bin/bash -c "crontab -u www-data /etc/cron.d/eramba-crontab" www-data

exec docker-php-entrypoint "$@"
