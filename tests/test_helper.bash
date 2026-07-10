setup_rebuild_app_test() {
  export TEST_TMPDIR
  TEST_TMPDIR="$(mktemp -d "${BATS_TEST_TMPDIR}/rebuild-app.XXXXXX")"
  export REBUILD_APP_ROOT
  REBUILD_APP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REBUILD_APP_STATE_DIR="${TEST_TMPDIR}/state"
  export REBUILD_APP_ENV_FILE="${TEST_TMPDIR}/.env"
  export REBUILD_APP_LOCK_DIR="${TEST_TMPDIR}/lock"
  export FAKE_COMMAND_LOG="${TEST_TMPDIR}/commands.log"
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
