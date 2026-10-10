#!/usr/bin/env bash
# Exercise the actual cloud worker entrypoint and SIGTERM with a held native job/child.
set -euo pipefail
trap 'printf "Standalone worker fixture failed at line %s; owned resources retained.\n" "$LINENO" >&2' ERR
umask 077
image=${1:?current fixture image}
project=${2:?unique eramba-safe-proof-* project}
env_file=${3:?private synthetic environment}
[[ "$project" =~ ^eramba-safe-proof-[a-z0-9-]+$ ]] || exit 64
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
reports="$root/.superpowers/sdd/safe-queue-runtime/$project"
mkdir -p "$reports"
compose=(docker compose --project-directory "$root" --env-file "$env_file" -f docker-compose.simple-install.yml -f tests/runtime-helper-override.yml --project-name "$project")
./bin/eramba-update --install --image "$image" --no-pull --project-name "$project" --env-file "$env_file" --compose-file tests/runtime-helper-override.yml > "$reports/install.log" 2>&1
ERAMBA_IMAGE="$image" "${compose[@]}" stop cron > "$reports/cron-stop.log" 2>&1
ERAMBA_IMAGE="$image" "${compose[@]}" config --format json | jq '{services:{standalone_worker:(.services.cron | .entrypoint=null | .command=["/queue-worker.sh","php","/var/www/eramba/app/upgrade/bin/cake.php","queue_worker","run","-v"] | .stop_signal="SIGTERM" | .restart="no" | .healthcheck={disable:true} | del(.depends_on,.links) | .volumes |= map(select(.target != "/docker-cron-entrypoint.sh" and .target != "/etc/cron.d/eramba-crontab" and .target != "/var/www/docker.env")))}}' > "$reports/standalone.json"
compose+=(-f "$reports/standalone.json")
ERAMBA_IMAGE="$image" "${compose[@]}" up -d --no-deps standalone_worker > "$reports/worker-start.log" 2>&1
worker=$(ERAMBA_IMAGE="$image" "${compose[@]}" ps -q standalone_worker)
proof=/var/www/eramba/app/upgrade/data/safe-update-proof
wait_file() {
    local marker=$1 deadline=$((SECONDS + 90))
    until docker exec "$worker" test -f "$proof/$marker" >/dev/null 2>&1; do
        ((SECONDS < deadline)) || exit 1
        sleep .1
    done
}
workers() {
    docker exec --user www-data "$worker" php -r 'require "/usr/local/lib/eramba-deployment/deployment-bootstrap.php"; $store=erambaDeploymentState(); $workers=[]; foreach ($store->runtimes($store->read()["runtimeIds"]) as $runtime) {if ($runtime["kind"]==="worker") {$workers[$runtime["id"]]=$runtime["retirement"];}} echo json_encode($workers,JSON_THROW_ON_ERROR);'
}
docker exec --user www-data "$worker" php /opt/eramba-safe-fixtures/queue-runtime.php enqueue > "$reports/enqueue.log" 2>&1
wait_file job-started
wait_file descendant-started
workers > "$reports/workers-before.json"
docker stop --signal SIGTERM --timeout 90 "$worker" > "$reports/worker-stop.log" 2>&1 &
stop=$!
# A normal long job must survive runuser's former two-second forced-kill interval.
sleep 3
[[ $(docker inspect --format '{{.State.Running}}' "$worker") == true ]]
! docker exec "$worker" test -f "$proof/job-finished"
descendant=$(docker exec "$worker" cat "$proof/descendant-pid")
docker exec "$worker" kill -0 "$descendant"
docker exec "$worker" touch "$proof/release-callback" "$proof/release-descendant"
wait "$stop"
[[ $(docker inspect --format '{{.State.ExitCode}}' "$worker") == 0 ]]
docker start "$worker" > "$reports/worker-restart.log"
wait_file job-finished
wait_file followup-finished
workers > "$reports/workers-after.json"
python3 - "$reports" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); before=json.loads((p/'workers-before.json').read_text()); after=json.loads((p/'workers-after.json').read_text())
live=[key for key,value in before.items() if value=='live']; assert live
assert all(after[key]=='normal' for key in live), (before,after)
assert all(value!='uncertain' for value in after.values()), after
assert any(key not in before and value=='live' for key,value in after.items()), after
PY
[[ $(docker exec --user www-data "$worker" /usr/local/bin/eramba-deployment status | jq -er .phase) == OPEN ]]
printf 'PASS: standalone cloud worker SIGTERM waited for the real held native job and child, recorded normal retirement and processed follow-up after restart.\n'
