setup_rebuild_app_test() {
  local test_tmp_root="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
  export TEST_TMPDIR
  TEST_TMPDIR="$(mktemp -d "${test_tmp_root}/rebuild-app.XXXXXX")"
  export REBUILD_APP_ROOT
  REBUILD_APP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REBUILD_APP_STATE_DIR="${TEST_TMPDIR}/state"
  export REBUILD_APP_ENV_FILE="${TEST_TMPDIR}/.env"
  export REBUILD_APP_LOCK_DIR="${TEST_TMPDIR}/lock"
  export FAKE_COMMAND_LOG="${TEST_TMPDIR}/commands.log"
  export FAKE_BIN_DIR="${TEST_TMPDIR}/bin"
  mkdir -p "${FAKE_BIN_DIR}"
  export PATH="${FAKE_BIN_DIR}:${PATH}"
  : >"${REBUILD_APP_ENV_FILE}"
  : >"${FAKE_COMMAND_LOG}"
}

teardown_rebuild_app_test() {
  rm -rf "${TEST_TMPDIR}"
}

assert_output_contains() {
  [[ "$output" == *"$1"* ]]
}

assert_log_excludes() {
  ! grep -F -- "$1" "${FAKE_COMMAND_LOG}"
}

assert_log_contains() {
  grep -F -- "$1" "${FAKE_COMMAND_LOG}"
}

mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

install_fake_docker() {
  cat >"${FAKE_BIN_DIR}/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -u

{
  printf 'docker'
  printf ' %q' "$@"
  printf '\n'
} >>"${FAKE_COMMAND_LOG}"

args=" $* "

if [[ "$1" == inspect && "$args" == *".State.Running"* ]]; then
  printf '%s\n' "${FAKE_ERAMBA_RUNNING:-true}"
elif [[ "$1" == inspect && "$args" == *".State.Health.Status"* ]]; then
  printf '%s\n' "${FAKE_TRIGGER_HEALTH:-healthy}"
elif [[ "$1" == inspect && "$args" == *".Mounts"* ]]; then
  container="${!#}"
  if [[ "$container" == eramba && -f "${TEST_TMPDIR}/eramba-removed" ]]; then
    printf 'No such container: eramba\n' >&2
    exit 1
  fi
  if [[ "$args" == *"/var/www/eramba/app/upgrade/data"* ]]; then
    if [[ -f "${TEST_TMPDIR}/target-started" && "${FAKE_CHANGED_PRESERVED_VOLUME:-}" == data ]]; then
      printf '%s\n' changed-data-volume
    else
      printf '%s\n' data-volume
    fi
  elif [[ "$args" == *"/var/www/eramba/app/upgrade/logs"* ]]; then
    if [[ -f "${TEST_TMPDIR}/target-started" && "${FAKE_CHANGED_PRESERVED_VOLUME:-}" == logs ]]; then
      printf '%s\n' changed-logs-volume
    else
      printf '%s\n' logs-volume
    fi
  elif [[ "$args" == *"/var/lib/mysql"* ]]; then
    if [[ -f "${TEST_TMPDIR}/target-started" && "${FAKE_CHANGED_PRESERVED_VOLUME:-}" == db ]]; then
      printf '%s\n' changed-db-volume
    else
      printf '%s\n' db-volume
    fi
  elif [[ "$args" == *"/data/eramba_trigger_storage"* ]]; then
    if [[ -f "${TEST_TMPDIR}/target-started" && "${FAKE_CHANGED_PRESERVED_VOLUME:-}" == trigger ]]; then
      printf '%s\n' changed-trigger-storage-volume
    else
      printf '%s\n' trigger-storage-volume
    fi
  elif [[ "$args" == *"/var/www/eramba"* ]]; then
    counter_file="${TEST_TMPDIR}/app-volume-reads"
    count=0
    [[ ! -f "$counter_file" ]] || count=$(<"$counter_file")
    count=$((count + 1))
    printf '%s\n' "$count" >"$counter_file"
    if [[ -f "${TEST_TMPDIR}/target-started" ]]; then
      if [[ "${FAKE_APP_VOLUME_REUSED:-0}" == 1 ]]; then
        printf '%s\n' app-volume
      else
        printf '%s\n' new-app-volume
      fi
    elif [[ "${FAKE_CHANGED_APP_VOLUME:-0}" == 1 && "$count" -gt 1 ]]; then
      printf '%s\n' unexpected-app-volume
    else
      printf '%s\n' app-volume
    fi
  else
    printf 'Unknown mount query for %s: %s\n' "$container" "$*" >&2
    exit 97
  fi
elif [[ "$1" == inspect && "$args" == *".Config.Image"* ]]; then
  container="${!#}"
  if [[ -f "${TEST_TMPDIR}/target-started" && ( "$container" == eramba || "$container" == cron ) ]]; then
    printf '%s\n' "${FAKE_TARGET_IMAGE:-ghcr.io/eramba/eramba:3.30.1-6}"
  else
    printf '%s\n' "${FAKE_CURRENT_IMAGE:-ghcr.io/eramba/eramba:3.30.0-23}"
  fi
elif [[ "$1" == exec && "$args" == *" image_switch_plan "* ]]; then
  if [[ -n "${FAKE_PLAN_JSON:-}" ]]; then
    printf '%s\n' "$FAKE_PLAN_JSON"
  else
    printf '%s\n' '{"required":false}'
  fi
elif [[ "$1" == exec && "$args" == *" php -r "* ]]; then
  field="${!#}"
  python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
    value=data[sys.argv[1]]
    if not isinstance(value, (str, bool)):
        raise ValueError()
    print(str(value).lower() if isinstance(value, bool) else value)
except Exception:
    raise SystemExit(2)' "$field"
elif [[ "$1" == exec && "$args" == *" cat /var/www/eramba/app/upgrade/VERSION "* ]]; then
  if [[ -f "${TEST_TMPDIR}/target-started" ]]; then
    printf '%s\n' "${FAKE_RUNNING_TARGET_APP_VERSION:-3.30.1}"
  else
    printf '%s\n' "${FAKE_CURRENT_APP_VERSION:-3.30.0}"
  fi
elif [[ "$1" == exec && "$args" == *" curl "* ]]; then
  if [[ -f "${TEST_TMPDIR}/target-started" ]]; then
    exit "${FAKE_TARGET_HTTP_STATUS:-0}"
  fi
  exit "${FAKE_CURRENT_HTTP_STATUS:-0}"
elif [[ "$1" == exec && "$args" == *" current_config validate "* ]]; then
  if [[ -f "${TEST_TMPDIR}/target-started" ]]; then
    exit "${FAKE_TARGET_CONFIG_STATUS:-0}"
  fi
  exit "${FAKE_CURRENT_CONFIG_STATUS:-0}"
elif [[ "$1" == exec && "$args" == *" system_health check "* ]]; then
  if [[ -f "${TEST_TMPDIR}/target-started" ]]; then
    exit "${FAKE_TARGET_HEALTH_STATUS:-0}"
  fi
  exit "${FAKE_CURRENT_HEALTH_STATUS:-0}"
elif [[ "$1" == exec && "$args" == *" migrations status "* ]]; then
  if [[ -f "${TEST_TMPDIR}/target-started" ]]; then
    exit "${FAKE_TARGET_MIGRATIONS_STATUS:-0}"
  fi
  exit "${FAKE_CURRENT_MIGRATIONS_STATUS:-0}"
elif [[ "$1" == pull ]]; then
  exit "${FAKE_PULL_STATUS:-0}"
elif [[ "$1" == load ]]; then
  exit "${FAKE_LOAD_STATUS:-0}"
elif [[ "$1" == image && "$2" == inspect && "$args" == *".Architecture"* ]]; then
  printf '%s\n' "${FAKE_TARGET_ARCH:-amd64}"
elif [[ "$1" == image && "$2" == inspect && "$args" == *".RepoTags"* ]]; then
  printf '["%s"]\n' "${FAKE_TARGET_REPO_TAG:-ghcr.io/eramba/eramba:3.30.1-6}"
elif [[ "$1" == image && "$2" == inspect && "$args" == *".Id"* ]]; then
  image_ref="${!#}"
  if [[ "$image_ref" == "${FAKE_CURRENT_IMAGE:-ghcr.io/eramba/eramba:3.30.0-23}" ]]; then
    printf '%s\n' "${FAKE_CURRENT_IMAGE_ID:-sha256:current}"
  else
    printf '%s\n' "${FAKE_TARGET_IMAGE_ID:-sha256:target}"
  fi
elif [[ "$1" == image && "$2" == inspect ]]; then
  exit "${FAKE_IMAGE_INSPECT_STATUS:-0}"
elif [[ "$1" == info && "$args" == *".Architecture"* ]]; then
  printf '%s\n' "${FAKE_DOCKER_ARCH:-x86_64}"
elif [[ "$1" == create ]]; then
  printf '%s\n' fake-target-container
elif [[ "$1" == cp ]]; then
  destination="${!#}"
  printf '%s\n' "${FAKE_TARGET_APP_VERSION:-3.30.1}" >"$destination"
elif [[ "$1" == rm && "${2:-}" == -f ]]; then
  exit 0
elif [[ "$1" == logs ]]; then
  printf 'bounded log for %s\n' "${!#}"
  exit 0
elif [[ "$1" == volume && "$2" == inspect ]]; then
  volume_name="${!#}"
  printf '%s-created\n' "$volume_name"
elif [[ "$1" == volume && "$2" == rm ]]; then
  exit "${FAKE_VOLUME_RM_STATUS:-0}"
elif [[ "$1" == compose ]]; then
  if [[ "$args" == *" stop "* ]]; then
    current_tag=$(awk -F= '$1 == "ERAMBA_IMAGE_TAG" { print substr($0, index($0, "=") + 1) }' "$REBUILD_APP_ENV_FILE")
    printf 'observed-tag-before-stop %s\n' "$current_tag" >>"${FAKE_COMMAND_LOG}"
  fi
  if [[ "$args" == *" up -d eramba "* || "$args" == *" up -d eramba" ]]; then
    rm -f "${TEST_TMPDIR}/eramba-removed"
    : >"${TEST_TMPDIR}/target-started"
  fi
  if [[ "$args" == *" create --no-deps eramba"* ]]; then
    rm -f "${TEST_TMPDIR}/eramba-removed"
  fi
  if [[ "$args" == *" rm -f eramba"* ]]; then
    : >"${TEST_TMPDIR}/eramba-removed"
  fi
  if [[ -n "${FAKE_FAIL_MATCH:-}" && "$args" == *"${FAKE_FAIL_MATCH}"* ]]; then
    exit 42
  fi
  if [[ "$args" == *" ps "* || "$args" == *" ps" ]]; then
    printf 'NAME STATUS\neramba running\n'
  fi
  exit 0
else
  printf 'Unexpected fake docker call: %s\n' "$*" >&2
  exit 98
fi
FAKE_DOCKER
  chmod +x "${FAKE_BIN_DIR}/docker"
}

install_fake_git() {
  cat >"${FAKE_BIN_DIR}/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -u

{
  printf 'git'
  printf ' %q' "$@"
  printf '\n'
} >>"${FAKE_COMMAND_LOG}"

if [[ "${1:-}" == -C ]]; then
  shift 2
fi

case "${1:-}" in
  status)
    printf '%s' "${FAKE_GIT_STATUS:-}"
    ;;
  symbolic-ref)
    if [[ "${FAKE_GIT_DETACHED:-0}" == 1 ]]; then
      exit 1
    fi
    printf '%s\n' refs/heads/codex/era-1706-rebuild-app
    ;;
  pull)
    exit "${FAKE_GIT_PULL_STATUS:-0}"
    ;;
  *)
    printf 'Unexpected fake git call: %s\n' "$*" >&2
    exit 98
    ;;
esac
FAKE_GIT
  chmod +x "${FAKE_BIN_DIR}/git"
}

install_fail_second_mv() {
  cat >"${FAKE_BIN_DIR}/mv" <<'FAKE_MV'
#!/usr/bin/env bash
set -u
counter_file="${TEST_TMPDIR}/mv-count"
count=0
[[ ! -f "$counter_file" ]] || count=$(<"$counter_file")
count=$((count + 1))
printf '%s\n' "$count" >"$counter_file"
if ((count >= 2)); then
  exit 1
fi
exec /bin/mv "$@"
FAKE_MV
  chmod +x "${FAKE_BIN_DIR}/mv"
}

set_required_community_plan() {
  export FAKE_PLAN_JSON='{"required":true,"source_app_version":"3.30.0","target_app_version":"3.30.1","current_image_tag":"3.30.0-23","target_image_tag":"3.30.1-6","edition":"community","distribution":"registry"}'
}

write_current_env() {
  cat >"${REBUILD_APP_ENV_FILE}" <<'ENV'
DB_PASSWORD=must-not-appear-in-output
ERAMBA_IMAGE_TAG=3.30.0-23
PUBLIC_ADDRESS=https://example.test
ENV
  chmod 640 "${REBUILD_APP_ENV_FILE}"
}

assert_preflight_pure() {
  assert_log_excludes " compose stop "
  assert_log_excludes " compose rm "
  assert_log_excludes " volume rm "
}
