#!/usr/bin/env bash
# Negative preflight against an existing owned fixture: no coordinator/client/volume mutation.
set -euo pipefail
umask 077
image=${1:?selected fixture image}
other=${2:?different fixture image}
project=${3:?existing eramba-safe-proof-* project}
env_file=${4:?private synthetic environment}
[[ "$project" =~ ^eramba-safe-proof-[a-z0-9-]+$ ]] || exit 64
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
reports="$root/.superpowers/sdd/safe-queue-runtime/$project/override-rejection"
mkdir -p "$reports"
compose=(docker compose --project-directory "$root" --env-file "$env_file" -f docker-compose.simple-install.yml -f tests/runtime-helper-override.yml --project-name "$project")
snapshot() {
    local container
    for container in $(docker ps -aq --filter "label=com.docker.compose.project=$project"); do
        docker inspect --format '{{.Id}} {{.Image}} {{.State.StartedAt}} {{.State.Running}}' "$container"
    done | sort
    docker volume ls --filter "label=com.docker.compose.project=$project" --format '{{.Name}}' | sort
}
snapshot > "$reports/before"
for mode in image database data source bridge entrypoint; do
    case "$mode" in
        image) jq -n --arg image "$other" '{services:{deployment_prepare:{image:$image}}}' ;;
        database) printf '%s\n' '{"services":{"deployment_prepare":{"environment":{"DB_DATABASE":"different_fixture_database"}}}}' ;;
        data) printf '%s\n' '{"services":{"deployment_prepare":{"volumes":[{"type":"volume","source":"different_fixture_data","target":"/var/www/eramba/app/upgrade/data"}]}},"volumes":{"different_fixture_data":{}}}' ;;
        source) printf '%s\n' '{"services":{"deployment_prepare":{"volumes":[{"type":"volume","source":"app","target":"/var/www/eramba"}]}}}' ;;
        bridge) printf '%s\n' '{"services":{"deployment_prepare":{"volumes":[{"type":"volume","source":"app","target":"/usr/local/lib/eramba-deployment"}]}}}' ;;
        entrypoint) printf '%s\n' '{"services":{"deployment_prepare":{"entrypoint":["/bin/true"]}}}' ;;
    esac > "$reports/$mode.json"
    if ./bin/eramba-update --image "$image" --no-pull --project-name "$project" --env-file "$env_file" --compose-file tests/runtime-helper-override.yml --compose-file "$reports/$mode.json" > "$reports/$mode.log" 2>&1; then
        printf 'Invalid %s override was accepted.\n' "$mode" >&2
        exit 1
    fi
    rg -q 'override differs|overrides violate' "$reports/$mode.log"
    snapshot > "$reports/after"
    cmp "$reports/before" "$reports/after"
done
app=$(ERAMBA_IMAGE="$image" "${compose[@]}" ps -q eramba)
[[ $(docker exec --user www-data "$app" /usr/local/bin/eramba-deployment status | jq -er .phase) == OPEN ]]
printf 'PASS: real Compose image, database, data, application/bridge source and entrypoint overrides were rejected before any coordinator/client/volume mutation.\n'
