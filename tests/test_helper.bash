setup_rebuild_app_test() {
  export TEST_TMPDIR
  TEST_TMPDIR="$(mktemp -d "${BATS_TEST_TMPDIR}/rebuild-app.XXXXXX")"
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
elif [[ "$1" == inspect && "$args" == *".Mounts"* ]]; then
  container="${!#}"
  if [[ "$args" == *"/var/www/eramba/app/upgrade/data"* ]]; then
    printf '%s\n' data-volume
  elif [[ "$args" == *"/var/www/eramba/app/upgrade/logs"* ]]; then
    printf '%s\n' logs-volume
  elif [[ "$args" == *"/var/lib/mysql"* ]]; then
    printf '%s\n' db-volume
  elif [[ "$args" == *"/data/eramba_trigger_storage"* ]]; then
    printf '%s\n' trigger-storage-volume
  elif [[ "$args" == *"/var/www/eramba"* ]]; then
    counter_file="${TEST_TMPDIR}/app-volume-reads"
    count=0
    [[ ! -f "$counter_file" ]] || count=$(<"$counter_file")
    count=$((count + 1))
    printf '%s\n' "$count" >"$counter_file"
    if [[ "${FAKE_CHANGED_APP_VOLUME:-0}" == 1 && "$count" -gt 1 ]]; then
      printf '%s\n' unexpected-app-volume
    else
      printf '%s\n' app-volume
    fi
  else
    printf 'Unknown mount query for %s: %s\n' "$container" "$*" >&2
    exit 97
  fi
elif [[ "$1" == inspect && "$args" == *".Config.Image"* ]]; then
  printf '%s\n' "${FAKE_CURRENT_IMAGE:-ghcr.io/eramba/eramba:3.30.0-23}"
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
  printf '%s\n' "${FAKE_CURRENT_APP_VERSION:-3.30.0}"
elif [[ "$1" == pull ]]; then
  exit "${FAKE_PULL_STATUS:-0}"
elif [[ "$1" == load ]]; then
  exit "${FAKE_LOAD_STATUS:-0}"
elif [[ "$1" == image && "$2" == inspect && "$args" == *".Architecture"* ]]; then
  printf '%s\n' "${FAKE_TARGET_ARCH:-amd64}"
elif [[ "$1" == image && "$2" == inspect && "$args" == *".RepoTags"* ]]; then
  printf '["%s"]\n' "${FAKE_TARGET_REPO_TAG:-ghcr.io/eramba/eramba:3.30.1-6}"
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
  if [[ -n "${FAKE_FAIL_MATCH:-}" && "$args" == *"${FAKE_FAIL_MATCH}"* ]]; then
    exit 42
  fi
  exit 0
else
  printf 'Unexpected fake docker call: %s\n' "$*" >&2
  exit 98
fi
FAKE_DOCKER
  chmod +x "${FAKE_BIN_DIR}/docker"
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
