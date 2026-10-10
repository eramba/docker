#!/usr/bin/env bash
# Real Linux/PHP/native queue/Apache/MySQL proof. Inputs are locally built fixture images.
set -euo pipefail
trap 'printf "Runtime fixture failed at line %s; logs/resources retained.\n" "$LINENO" >&2' ERR
umask 077
base_image=${1:?base fixture image}
target_image=${2:?target fixture image with proof migration}
project=${3:?unique eramba-safe-proof-* project}
env_file=${4:?private synthetic environment file}
[[ "$project" =~ ^eramba-safe-proof-[a-z0-9-]+$ ]] || exit 64
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
reports="$root/.superpowers/sdd/safe-queue-runtime/$project"
mkdir -p "$reports"
compose=(docker compose --project-directory "$root" --env-file "$env_file" -f docker-compose.simple-install.yml -f tests/runtime-helper-override.yml --project-name "$project")
configuration=$(ERAMBA_IMAGE="$base_image" "${compose[@]}" config --format json)
jq -e '.services.eramba.environment.DB_HOST == "mysql" and .services.eramba.environment.DB_DATABASE == "queue_proof"' <<<"$configuration" >/dev/null
data_volume=$(jq -er '.volumes.data.name' <<<"$configuration")
app_volume=$(jq -er '.volumes.app.name' <<<"$configuration")
! docker volume inspect "$data_volume" >/dev/null 2>&1 || { printf 'Fixture project already has data; choose a fresh project.\n' >&2; exit 1; }
printf 'Runtime fixture: project=%s data=%s app=%s\n' "$project" "$data_volume" "$app_volume"
./bin/eramba-update --install --image "$base_image" --no-pull --project-name "$project" --env-file "$env_file" --compose-file tests/runtime-helper-override.yml > "$reports/install.log" 2>&1
app=$(ERAMBA_IMAGE="$base_image" "${compose[@]}" ps -q eramba)
cron=$(ERAMBA_IMAGE="$base_image" "${compose[@]}" ps -q cron)
mysql=$(ERAMBA_IMAGE="$base_image" "${compose[@]}" ps -q mysql)
proof=/var/www/eramba/app/upgrade/data/safe-update-proof
wait_file() {
    local file=$1 deadline=$((SECONDS + 60))
    until docker exec "$cron" test -f "$proof/$file" >/dev/null 2>&1; do
        ((SECONDS < deadline)) || { printf 'Missing runtime event: %s\n' "$file" >&2; exit 1; }
        sleep .1
    done
}
state_phase() { docker exec --user www-data "$cron" /usr/local/bin/eramba-deployment status | jq -er .phase; }
wait_phase() {
    local phase=$1 deadline=$((SECONDS + 60)) current
    until current=$(state_phase) && [[ "$current" == "$phase" ]]; do
        [[ "$current" != FAILED ]] || { printf 'Preparation failed before %s; see retained logs.\n' "$phase" >&2; exit 1; }
        ((SECONDS < deadline)) || exit 1
        sleep .1
    done
}
sql_events() {
    docker exec "$mysql" sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 --user="$MYSQL_USER" --database="$MYSQL_DATABASE" --batch --skip-column-names --execute="SELECT event FROM safe_update_probe ORDER BY id"'
}
docker exec --user www-data "$cron" php /opt/eramba-safe-fixtures/queue-runtime.php enqueue > "$reports/enqueue.log" 2>&1
wait_file job-started
wait_file descendant-started
address=$(docker port "$app" 80/tcp)
[[ "$address" =~ ^127\.0\.0\.1:[0-9]+$ ]] || exit 1
url="http://$address/__safe-update/http.php"
curl --connect-timeout 5 --max-time 120 -fsS "$url?mode=hold" > "$reports/held-http.log" 2>&1 &
http=$!
wait_file http-started
docker exec --user www-data "$cron" php /opt/eramba-safe-fixtures/queue-runtime.php expire > "$reports/expired-heartbeat.log" 2>&1
./bin/eramba-update --image "$target_image" --no-pull --project-name "$project" --env-file "$env_file" --compose-file tests/runtime-helper-override.yml --drain-timeout 120 > "$reports/update.log" 2>&1 &
update=$!
wait_phase DRAINING
[[ $(curl -sS -o "$reports/forged-public.json" -w '%{http_code}' -H 'X-Eramba-Private-Origin: 1' "$url?mode=callback") == 503 ]]
[[ $(docker exec "$app" curl -sS -o /dev/null -w '%{http_code}' -X POST 'http://127.0.0.1:8081/__safe-update/http.php?mode=callback') == 401 ]]
docker volume inspect "$app_volume" >/dev/null
! sql_events | rg -q '^migration-started$'
docker exec "$cron" touch "$proof/release-callback"
wait_file callback-finished
wait_file followup-queued
[[ $(state_phase) == DRAINING ]]
! sql_events | rg -q '^migration-started$'
docker exec "$cron" touch "$proof/release-descendant"
wait_file job-finished
wait_phase QUIESCING
! sql_events | rg -q '^migration-started$'
docker volume inspect "$app_volume" >/dev/null
docker exec "$app" touch "$proof/release-http"
wait "$http"
wait "$update"
# The original clients are now removed; follow-up work must execute under target code.
cron=$(ERAMBA_IMAGE="$target_image" "${compose[@]}" ps -q cron)
wait_file followup-finished
sql_events > "$reports/events.txt"
python3 - "$reports/events.txt" <<'PY'
import pathlib,sys
events=pathlib.Path(sys.argv[1]).read_text().splitlines()
migration=events.index('migration-started')
for event in ('job-finished','descendant-finished','http-finished','callback-finished','followup-queued'):
    assert events.index(event) < migration, (event,events)
assert migration < events.index('followup-finished'), events
print('PASS: native job, descendant, authenticated callback and admitted HTTP all finished before the real migration; queued follow-up ran afterwards.')
PY
[[ $(docker volume inspect --format '{{index .Labels "com.docker.compose.project"}}' "$data_volume") == "$project" ]]
if docker run --rm --user www-data --entrypoint /usr/local/bin/eramba-deployment \
    --env "DB_HOST=$(jq -er '.services.eramba.environment.DB_HOST' <<<"$configuration")" \
    --env "DB_PORT=$(jq -r '.services.eramba.environment.DB_PORT // "3306"' <<<"$configuration")" \
    --env "DB_DATABASE=$(jq -er '.services.eramba.environment.DB_DATABASE' <<<"$configuration")" \
    --env "DB_USERNAME=$(jq -er '.services.eramba.environment.DB_USERNAME' <<<"$configuration")" \
    -v "$data_volume:/var/www/eramba/app/upgrade/data" "$base_image" verify-ready >/dev/null 2>&1; then
    stale=0
else
    stale=$?
fi
[[ "$stale" == 75 ]]
printf 'PASS: data retained and stale base-image startup refused. Resources remain for inspection; clean up only project %s.\n' "$project"
