#!/bin/sh

cd /var/www/eramba || exit

# Run Post Install CMD to generate app_local.php file with unique SALT and other defaults.
su -s /bin/bash -c "php composer.phar run-script post-install-cmd --no-interaction" www-data

# syncing dir structure into /data folder from /data_template
su -s /bin/bash -c "rsync -rv app/upgrade/data_template/ app/upgrade/data/" www-data

# when deploying a code or DB migration change and you want the "old workers" based on the old code
# to not process any new incoming jobs after deployment.
su -s /bin/bash -c "php app/upgrade/bin/cake.php queue worker end all -q" www-data

# Lets activate maintenance mode
#su -s /bin/bash -c "php app/upgrade/bin/cake.php setup.maintenance_mode activate" www-data

# Either load a clean database if eramba is deployed for the first time
# or migrate and update to the latest database version if switching to a new/different image, if applicable,
# otherwise if not possible to update due to broken DB history sync, the process will exit with error.
su -s /bin/bash -c "php app/upgrade/bin/cake.php database initialize" www-data || exit

# Lets de-activate maintenance mode
#su -s /bin/bash -c "php app/upgrade/bin/cake.php setup.maintenance_mode deactivate" www-data

# Initialize a worker with the deployment so we won't have to wait for the cron to kick in which can take up to 10 minutes.
#su -s /bin/bash -c "php app/upgrade/bin/cake.php queue run -v" www-data 2>&1 &

exec docker-php-entrypoint "$@"
