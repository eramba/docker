#!/bin/sh

# cron starts every job with an almost empty environment. Save the container
# environment once, shell-quoted, so each crontab line can load it with ".".
# This replaces parsing .env in crontab, which broke on comments and on values
# with spaces. HOME and the working directory stay those of the job's user.
(umask 027; unset HOME PWD OLDPWD SHLVL; export -p > /etc/eramba-cron.env)
chown root:www-data /etc/eramba-cron.env
chmod 0640 /etc/eramba-cron.env

su -s /bin/bash -c "crontab -u www-data /etc/cron.d/eramba-crontab" www-data

exec docker-php-entrypoint "$@"
