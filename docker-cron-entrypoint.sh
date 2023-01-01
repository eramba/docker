#!/bin/sh

env >> /etc/environment

crontab -u www-data -r
crontab -u root /etc/cron.d/eramba-crontab

# Run Post Install CMD to generate app_local.php file with unique SALT and other defaults.
su -s /bin/bash -c "php /var/www/eramba/composer.phar run-script post-install-cmd --working-dir=/var/www/eramba --no-interaction" www-data

su -s /bin/bash -c "php /var/www/eramba/app/upgrade/bin/cake.php queue worker end all" www-data

# execute CMD
echo "$@"
exec "$@"
