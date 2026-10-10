#!/bin/sh
set -eu
exec /usr/local/lib/eramba-deployment/docker-cron-entrypoint.sh "$@"
