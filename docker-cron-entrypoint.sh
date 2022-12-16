#!/bin/sh

env >> /etc/environment

crontab -u root /etc/cron.d/eramba-crontab

su -s /bin/bash -c "php /var/www/eramba/app/upgrade/bin/cake.php queue worker end all" www-data

# execute CMD
echo "$@"
exec "$@"
