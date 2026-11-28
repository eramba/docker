#!/usr/bin/env bats

# Cron jobs must receive the container environment, whatever .env contains.
# Set ERAMBA_CRON_TEST_IMAGE to test against a local image instead of pulling.

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  IMAGE="${ERAMBA_CRON_TEST_IMAGE:-ghcr.io/eramba/eramba:latest}"
}

run_in_cron_container() {
  docker run --rm --network none \
    --entrypoint /docker-cron-entrypoint.sh \
    -v "$REPOSITORY_ROOT/docker-cron-entrypoint.sh:/docker-cron-entrypoint.sh:ro" \
    -v "$REPOSITORY_ROOT/crontab/crontab:/etc/cron.d/eramba-crontab:ro" \
    -v "$REPOSITORY_ROOT/.env:/var/www/docker.env:ro" \
    "$@"
}

# Runs every crontab job line the way cron does: as www-data, under /bin/sh,
# with an empty environment. The eramba command is swapped for the given
# command and the log redirect is dropped, so the job prints to stdout.
run_crontab_jobs_with() {
  local command="$1"
  shift
  run run_in_cron_container "$@" "$IMAGE" sh -c '
    grep -vE "^(#|\$)" /etc/cron.d/eramba-crontab |
      sed -E -e "s#^@[a-z]+ ##" -e t -e "s#^([^ ]+ ){5}##" |
      sed -E -e "s#/bin/sh /var/www/eramba/app/upgrade/bin/cake [^)]*#$1#" -e "s# >> /var/log/cron.log 2>&1\$##" |
      while IFS= read -r job; do
        env -i PATH=/usr/bin:/bin su -s /bin/sh www-data -c "$job" || exit 1
      done' sh "$command"
}

@test "every crontab job gets container variables with spaces, quotes and #" {
  local value="pa ss 'w\$rd \"#not a comment\""

  run_crontab_jobs_with "printenv DB_PASSWORD" -e DB_PASSWORD="$value"

  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  for line in "${lines[@]}"; do
    [ "$line" = "$value" ]
  done
}

@test "every crontab job gets container variables with a newline" {
  run_crontab_jobs_with "printenv MULTI_LINE" -e MULTI_LINE="$(printf 'line one\nline two')"

  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 8 ]
  for i in 0 2 4 6; do
    [ "${lines[$i]}" = "line one" ]
    [ "${lines[$((i + 1))]}" = "line two" ]
  done
}

@test "saved cron environment is private to www-data and keeps the job's HOME" {
  run run_in_cron_container "$IMAGE" sh -c '
    stat -c "%U:%G %a" /etc/eramba-cron.env
    grep -c "^export HOME=" /etc/eramba-cron.env || true'

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "root:www-data 640" ]
  [ "${lines[1]}" = "0" ]
}
