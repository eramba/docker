#!/usr/bin/env bash
# The cron container must retain its native monitor while Docker's SIGWINCH stop drains a job.
set -euo pipefail
trap 'printf "Restart fixture failed at line %s; owned resources retained.\n" "$LINENO" >&2' ERR
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
cron=$(ERAMBA_IMAGE="$image" "${compose[@]}" ps -q cron)
proof=/var/www/eramba/app/upgrade/data/safe-update-proof
wait_file() {
    local marker=$1 deadline=$((SECONDS + 90))
    until docker exec "$cron" test -f "$proof/$marker" >/dev/null 2>&1; do
        ((SECONDS < deadline)) || exit 1
        sleep .1
    done
}
workers() {
    docker exec --user www-data "$cron" php -r 'require "/usr/local/lib/eramba-deployment/deployment-bootstrap.php"; $store=erambaDeploymentState(); $workers=[]; foreach ($store->runtimes($store->read()["runtimeIds"]) as $runtime) {if ($runtime["kind"]==="worker") {$workers[$runtime["id"]]=$runtime["retirement"];}} echo json_encode($workers,JSON_THROW_ON_ERROR);'
}
docker exec --user www-data "$cron" php /opt/eramba-safe-fixtures/queue-runtime.php enqueue > "$reports/enqueue.log" 2>&1
wait_file job-started
wait_file descendant-started
workers > "$reports/workers-before.json"
before=$(docker inspect --format '{{.State.StartedAt}}' "$cron")
[[ $(docker inspect --format '{{.Config.StopSignal}}' "$cron") == SIGWINCH ]]
docker restart --timeout 90 "$cron" > "$reports/restart.log" 2>&1 &
restart=$!
# runuser terminates its child after two seconds. A held real job must survive that interval.
sleep 3
[[ $(docker inspect --format '{{.State.StartedAt}}' "$cron") == "$before" ]]
! docker exec "$cron" test -f "$proof/job-finished"
descendant=$(docker exec "$cron" cat "$proof/descendant-pid")
docker exec "$cron" kill -0 "$descendant"
docker exec "$cron" touch "$proof/release-callback" "$proof/release-descendant"
wait "$restart"
[[ $(docker inspect --format '{{.State.StartedAt}}' "$cron") != "$before" ]]
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
[[ $(docker exec --user www-data "$cron" /usr/local/bin/eramba-deployment status | jq -er .phase) == OPEN ]]
printf 'PASS: Docker SIGWINCH restart waited for the held native job and child, recorded normal retirement and started a fresh worker.\n'
