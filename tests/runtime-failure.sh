#!/usr/bin/env bash
# Real isolated MySQL and process-loss evidence; auxiliary services are fixture stubs.
set -euo pipefail
trap 'printf "Failure fixture stopped at line %s; owned logs/resources retained.\n" "$LINENO" >&2' ERR
umask 077
base=${1:?base fixture image}
target=${2:?target fixture image}
project=${3:?unique eramba-safe-proof-* project}
env_file=${4:?private synthetic environment}
mode=${5:?database-sleep, database-statement, coordinator-loss, hard-kill or sync-failure}
[[ "$project" =~ ^eramba-safe-proof-[a-z0-9-]+$ && "$mode" =~ ^(database-sleep|database-statement|coordinator-loss|hard-kill|sync-failure)$ ]] || exit 64
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
reports="$root/.superpowers/sdd/safe-queue-runtime/$project"
mkdir -p "$reports"
compose=(docker compose --project-directory "$root" --env-file "$env_file" -f docker-compose.simple-install.yml -f tests/runtime-helper-override.yml --project-name "$project")
./bin/eramba-update --install --image "$base" --no-pull --project-name "$project" --env-file "$env_file" --compose-file tests/runtime-helper-override.yml > "$reports/install.log" 2>&1
app=$(ERAMBA_IMAGE="$base" "${compose[@]}" ps -q eramba)
cron=$(ERAMBA_IMAGE="$base" "${compose[@]}" ps -q cron)
mysql=$(ERAMBA_IMAGE="$base" "${compose[@]}" ps -q mysql)
proof=/var/www/eramba/app/upgrade/data/safe-update-proof
sql() { docker exec "$mysql" sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 --user="$MYSQL_USER" --database="$MYSQL_DATABASE" --batch --skip-column-names --execute="$1"' sh "$1"; }
wait_file() {
    local file=$1 container=${2:-$cron} deadline=$((SECONDS + 90))
    until docker exec "$container" test -f "$proof/$file" >/dev/null 2>&1; do
        ((SECONDS < deadline)) || exit 1
        sleep .1
    done
}
coordinator() { docker ps -a --filter "label=com.docker.compose.project=$project" --filter label=com.docker.compose.service=deployment_prepare --format '{{.ID}}'; }
phase() {
    if [[ $(docker inspect --format '{{.State.Running}}' "$1") == true ]]; then
        docker exec --user www-data "$1" /usr/local/bin/eramba-deployment status | jq -er .phase
    else
        docker run --rm --user www-data --entrypoint /usr/local/bin/eramba-deployment \
            -v "${project}_data:/var/www/eramba/app/upgrade/data" "$target" status | jq -er .phase
    fi
}
wait_phase() {
    local wanted=$1 container=$2 deadline=$((SECONDS + 90))
    until [[ $(phase "$container") == "$wanted" ]]; do
        ((SECONDS < deadline)) || exit 1
        sleep .1
    done
}
kind=setup
[[ "$mode" != coordinator-loss && "$mode" != hard-kill ]] || kind=enqueue
docker exec --user www-data "$cron" php /opt/eramba-safe-fixtures/queue-runtime.php "$kind" > "$reports/setup.log" 2>&1
if [[ "$kind" == enqueue ]]; then
    wait_file job-started
    wait_file descendant-started
fi
if [[ "$mode" == database-* ]]; then
    probe_mode=${mode#database-}
    probe=$(ERAMBA_IMAGE="$base" "${compose[@]}" run -d --no-deps database_probe "$probe_mode")
    wait_file database-probe-started "$probe"
    probe_id=$(docker exec "$probe" cat "$proof/database-probe-id")
    [[ "$probe_id" =~ ^[1-9][0-9]*$ ]]
fi
timeout=90
[[ "$mode" != hard-kill ]] || timeout=15
./bin/eramba-update --image "$target" --no-pull --project-name "$project" --env-file "$env_file" --compose-file tests/runtime-helper-override.yml --drain-timeout "$timeout" > "$reports/update.log" 2>&1 &
update=$!
[[ "$kind" != enqueue ]] || wait_phase DRAINING "$app"
deadline=$((SECONDS + 60))
until owner=$(coordinator) && [[ -n "$owner" ]]; do
    ((SECONDS < deadline)) || exit 1
    sleep .1
done
until operation=$(docker exec --user www-data "$owner" cat /tmp/eramba-deployment-host/intent.json 2>/dev/null | jq -er .operationId); do
    ((SECONDS < deadline)) || exit 1
    sleep .1
done
if [[ "$mode" == coordinator-loss ]]; then
    [[ $(docker inspect --format '{{.Image}}' "$owner") == $(docker image inspect --format '{{.Id}}' "$target") ]]
    docker kill --signal KILL "$owner" >/dev/null
    if wait "$update"; then exit 1; fi
    docker exec "$cron" touch "$proof/release-callback" "$proof/release-descendant"
    wait_file job-finished
    # Completion/free owner flock cannot erase the interrupted operation.
    if ./bin/eramba-update --image "$target" --no-pull --project-name "$project" --env-file "$env_file" --compose-file tests/runtime-helper-override.yml --drain-timeout 5 > "$reports/rival.log" 2>&1; then exit 1; fi
    [[ $(docker exec --user www-data "$app" php -r 'require "/usr/local/lib/eramba-deployment/deployment-bootstrap.php"; echo erambaDeploymentState()->read()["operation"]["id"];') == "$operation" ]]
    [[ $(phase "$app") != OPEN ]]
    [[ $(sql "SELECT COUNT(*) FROM safe_update_probe WHERE event='migration-started'") == 0 ]]
    docker volume inspect "${project}_app" >/dev/null
    printf 'PASS: coordinator loss remained closed after actual job completion; rival preparation could not take over or replace source.\n'
    exit 0
fi
if [[ "$mode" == hard-kill ]]; then
    pid=$(sql "SELECT p.pid FROM queue_processes p JOIN queued_jobs j ON j.workerkey=p.workerkey WHERE j.reference='safe-update-proof-main' AND j.completed IS NULL")
    [[ "$pid" =~ ^[1-9][0-9]*$ ]]
    docker exec "$cron" sh -c 'tr "\000" " " < "/proc/$1/cmdline"' sh "$pid" | rg -q 'cake.php queue_worker run'
    descendant=$(docker exec "$cron" cat "$proof/descendant-pid")
    docker exec "$cron" kill -0 "$descendant"
    docker exec "$cron" kill -KILL "$pid"
    if wait "$update"; then exit 1; fi
    wait_phase FAILED "$app"
    [[ $(sql "SELECT COUNT(*) FROM safe_update_probe WHERE event='migration-started'") == 0 ]]
    docker volume inspect "${project}_app" >/dev/null
    printf 'PASS: actual native parent killed with a live descendant; uncertainty prevented migration and application-volume replacement.\n'
    exit 0
fi
if [[ "$mode" == sync-failure ]]; then
    if wait "$update"; then exit 1; fi
    [[ $(phase "$owner") == FAILED ]]
    [[ $(sql "SELECT COUNT(*) FROM safe_update_probe WHERE event='migration-started'") == 1 ]]
    docker cp "$owner:/tmp/eramba-deployment-host/intent.json" "$reports/intent.json" >/dev/null
    [[ $(jq -er .operationId "$reports/intent.json") == "$operation" ]]
    printf 'PASS: real fresh synchronization failure after migration kept admission closed.\n'
    exit 0
fi
wait_phase PREPARING "$owner"
# The host switch is allowed only after registered execution retires. This independent
# client remains visible to the coordinator's own-account database check.
deadline=$((SECONDS + 60))
until docker exec "$owner" test -f /tmp/eramba-deployment-host/permit.json >/dev/null 2>&1 && \
    (( $(sql "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER=SUBSTRING_INDEX(CURRENT_USER(),'@',1) AND ID<>CONNECTION_ID()") >= 2 )); do
    ((SECONDS < deadline)) || exit 1
    sleep .1
done
# Observe the DB check itself after host permit, rather than merely an earlier drain phase.
for observation in 1 2 3; do
    [[ $(phase "$owner") == PREPARING ]]
    [[ $(sql "SELECT COUNT(*) FROM safe_update_probe WHERE event='migration-started'") == 0 ]]
    if docker exec "$owner" pgrep -f '^/usr/local/bin/php /var/www/eramba/app/upgrade/bin/cake.php database initialize$' >/dev/null; then exit 1; fi
    sleep .2
done
[[ $(sql "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID=$probe_id") == 1 ]]
[[ $(sql "SELECT COUNT(*) FROM safe_update_probe WHERE event='migration-started'") == 0 ]]
if [[ "$mode" == database-statement ]]; then
    [[ $(sql "SELECT COMMAND FROM information_schema.PROCESSLIST WHERE ID=$probe_id") == Query ]]
    sql "KILL QUERY $probe_id" >/dev/null
else
    [[ $(sql "SELECT COMMAND FROM information_schema.PROCESSLIST WHERE ID=$probe_id") == Sleep ]]
    docker exec "$probe" touch "$proof/release-database-probe"
fi
[[ $(docker wait "$probe") == 0 ]]
[[ $(sql "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID=$probe_id") == 0 ]]
wait "$update"
[[ $(sql "SELECT COUNT(*) FROM safe_update_probe WHERE event='migration-started'") == 1 ]]
printf 'PASS: remaining MySQL %s blocked real migration until server-side retirement.\n' "${mode#database-}"
