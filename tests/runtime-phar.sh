#!/usr/bin/env bash
set -euo pipefail
trap 'printf "PHAR fixture failed at line %s; logs/resources retained.\n" "$LINENO" >&2' ERR
umask 077
image=${1:?local fixture image}
project=${2:?unique eramba-safe-proof-* project}
env_file=${3:?private synthetic environment file}
mode=${4:?success, restored or broken}
[[ "$project" =~ ^eramba-safe-proof-[a-z0-9-]+$ && "$mode" =~ ^(success|restored|broken)$ ]] || exit 64
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
reports="$root/.superpowers/sdd/safe-queue-runtime/$project"
mkdir -p "$reports"
compose=(docker compose --project-directory "$root" --env-file "$env_file" -f docker-compose.simple-install.yml -f tests/runtime-helper-override.yml --project-name "$project")
if [[ "${5:-}" != --reuse-before-reservation ]]; then
    ./bin/eramba-update --install --image "$image" --no-pull --project-name "$project" --env-file "$env_file" --compose-file tests/runtime-helper-override.yml > "$reports/install.log" 2>&1
fi
app=$(ERAMBA_IMAGE="$image" "${compose[@]}" ps -q eramba)
cron=$(ERAMBA_IMAGE="$image" "${compose[@]}" ps -q cron)
mysql=$(ERAMBA_IMAGE="$image" "${compose[@]}" ps -q mysql)
proof=/var/www/eramba/app/upgrade/data/safe-phar-proof
if [[ "${5:-}" == --reuse-before-reservation ]]; then
    [[ $(docker inspect --format '{{.Image}}' "$cron") == $(docker image inspect --format '{{.Id}}' "$image") ]]
    [[ $(docker exec --user www-data "$cron" /usr/local/bin/eramba-deployment status | jq -r .phase) == OPEN ]]
    docker exec "$cron" test ! -e "$proof/reservation.json"
    docker exec "$cron" rm -f "$proof/package.zip"
fi
wait_file() {
    local marker=$1 deadline=$((SECONDS + 180))
    until docker exec "$cron" test -f "$proof/$marker" >/dev/null 2>&1; do
        ((SECONDS < deadline)) || { printf 'Missing PHAR fixture event: %s\n' "$marker" >&2; exit 1; }
        sleep .2
    done
}
docker exec --user www-data "$cron" php /opt/eramba-safe-fixtures/phar-package.php "$mode" > "$reports/package.log" 2>&1
docker exec --user www-data "$cron" php /opt/eramba-safe-fixtures/phar-reserve.php > "$reports/reserve.log" 2>&1
docker cp "$cron:$proof/reservation.json" "$reports/reservation.json" >/dev/null
chmod 600 "$reports/reservation.json"
python3 - "$reports" <<'PY'
import pathlib,json,sys
directory=pathlib.Path(sys.argv[1]); result=json.loads((directory/'reservation.json').read_text())
(directory/'progress.cookies').write_text('# Netscape HTTP Cookie File\n127.0.0.1\tFALSE\t/\tFALSE\t0\teramba_update_progress\t'+result['progressTicket']+'\n')
PY
address=$(docker port "$app" 8082/tcp)
[[ "$address" =~ ^127\.0\.0\.1:[0-9]+$ ]] || exit 1
url="http://$address/updater_output.php"
wait_file package-hook
[[ $(curl --cookie "$reports/progress.cookies" -fsS "$url" | jq -er .phase) == PREPARING ]]
curl --cookie "$reports/progress.cookies" -fsS "$url?view=page" > "$reports/pending.html"
[[ $(curl -sS -o /dev/null -w '%{http_code}' "$url") == 403 ]]
[[ $(curl --cookie "$reports/progress.cookies" -sS -o /dev/null -w '%{http_code}' "http://$address/other") == 503 ]]
! docker exec "$cron" test -f "$proof/migration"
docker exec "$cron" touch "$proof/release-package"
deadline=$((SECONDS + 180))
expected=OPEN
[[ "$mode" != broken ]] || expected=FAILED
until state=$(docker exec --user www-data "$cron" /usr/local/bin/eramba-deployment status) && [[ $(jq -r .phase <<<"$state") == "$expected" ]]; do
    [[ $(jq -r .phase <<<"${state:-null}") != FAILED || "$expected" == FAILED ]] || { printf 'Package remained blocked; inspect retained reports.\n' >&2; exit 1; }
    ((SECONDS < deadline)) || exit 1
    sleep .2
done
printf '%s\n' "$state" > "$reports/final-state.json"
curl --cookie "$reports/progress.cookies" -fsS "$url" > "$reports/final-progress.json"
curl --cookie "$reports/progress.cookies" -fsS "$url?view=page" > "$reports/final.html"
if [[ "$mode" == broken ]]; then
    [[ $(jq -r .status "$reports/final-progress.json") == blocked ]]
    printf 'PASS: incompatible PHAR rollback remained closed and progress reports blocked.\n'
    exit 0
fi
outcome=success
[[ "$mode" != restored ]] || outcome=restored
[[ $(jq -r .status "$reports/final-progress.json") == "$outcome" ]]
if [[ "$mode" == success ]]; then
    wait_file fresh-finalizer
    package_pid=$(docker exec "$cron" cat "$proof/package-hook")
    finalizer_pid=$(docker exec "$cron" cat "$proof/fresh-finalizer")
    [[ "$package_pid" != "$finalizer_pid" ]]
fi
job=$(jq -er .jobId "$reports/reservation.json")
docker exec "$mysql" sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 --user="$MYSQL_USER" --database="$MYSQL_DATABASE" --batch --skip-column-names --execute="$1"' sh "SELECT completed IS NOT NULL FROM queued_jobs WHERE id = $job" > "$reports/job-completed.txt"
[[ $(cat "$reports/job-completed.txt") == 1 ]]
docker exec "$mysql" sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 --user="$MYSQL_USER" --database="$MYSQL_DATABASE" --batch --skip-column-names --execute="SELECT COUNT(*) FROM queued_jobs WHERE completed IS NULL"' > "$reports/pending-jobs.txt"
[[ $(cat "$reports/pending-jobs.txt") == 0 ]]
deadline=$((SECONDS + 60))
until docker exec --user www-data "$app" /usr/local/bin/eramba-deployment web-ready >/dev/null 2>&1; do
    ((SECONDS < deadline)) || exit 1
    sleep .2
done
printf 'PASS: PHAR %s, exact native completion, durable progress outcome and fresh Apache restart.\n' "$mode"
