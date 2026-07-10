#!/usr/bin/env bats

load test_helper

setup() {
  setup_rebuild_app_test
  install_fake_docker
  set_required_community_plan
  write_current_env
}

teardown() {
  teardown_rebuild_app_test
}

@test "pre-migration failure restores the previous tag and application services" {
  export FAKE_FAIL_MATCH=" rm -f triggers_caddy "

  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --yes --backup-confirmed
  [ "$status" -ne 0 ]
  assert_output_contains "Pre-migration recovery succeeded"
  grep -Fx 'ERAMBA_IMAGE_TAG=3.30.0-23' "$REBUILD_APP_ENV_FILE"
  assert_log_contains "observed-tag-before-stop 3.30.1-6"
  assert_log_contains " up -d eramba cron triggers_caddy"
  assert_log_excludes " volume rm "
}

@test "volume mutation removes only the twice-verified app volume and never mysql or redis" {
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --yes --backup-confirmed
  [ "$status" -eq 0 ]
  assert_output_contains "Rebuild completed successfully"
  assert_log_contains "docker volume rm -- app-volume"
  assert_log_excludes " stop mysql"
  assert_log_excludes " rm -f mysql"
  assert_log_excludes " stop redis"
  assert_log_excludes " rm -f redis"

  triggers_stop=$(grep -n " stop triggers_caddy" "$FAKE_COMMAND_LOG" | head -1 | cut -d: -f1)
  cron_stop=$(grep -n " stop cron" "$FAKE_COMMAND_LOG" | head -1 | cut -d: -f1)
  eramba_stop=$(grep -n " stop eramba" "$FAKE_COMMAND_LOG" | head -1 | cut -d: -f1)
  verification_create=$(grep -n " create --no-deps eramba" "$FAKE_COMMAND_LOG" | head -1 | cut -d: -f1)
  volume_rm=$(grep -n " volume rm -- app-volume" "$FAKE_COMMAND_LOG" | head -1 | cut -d: -f1)
  [ "$triggers_stop" -lt "$cron_stop" ]
  [ "$cron_stop" -lt "$eramba_stop" ]
  [ "$eramba_stop" -lt "$verification_create" ]
  [ "$verification_create" -lt "$volume_rm" ]
  [ "$eramba_stop" -lt "$volume_rm" ]
  grep -Fx 'ERAMBA_IMAGE_TAG=3.30.1-6' "$REBUILD_APP_ENV_FILE"
}

@test "volume identity change aborts without deleting any volume" {
  export FAKE_CHANGED_APP_VOLUME=1

  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --yes --backup-confirmed
  [ "$status" -ne 0 ]
  assert_output_contains "Application volume changed after preflight"
  assert_log_excludes " volume rm "
  grep -Fx 'ERAMBA_IMAGE_TAG=3.30.0-23' "$REBUILD_APP_ENV_FILE"
}

@test "atomic env update preserves permissions and unrelated values" {
  run bash -c '
    set -Eeuo pipefail
    ROOT_DIR=$1
    ENV_FILE=$2
    source "$ROOT_DIR/lib/rebuild-app/common.sh"
    atomic_set_env ERAMBA_IMAGE_TAG 3.30.1-6
  ' bash "$REBUILD_APP_ROOT" "$REBUILD_APP_ENV_FILE"
  [ "$status" -eq 0 ]
  grep -Fx 'ERAMBA_IMAGE_TAG=3.30.1-6' "$REBUILD_APP_ENV_FILE"
  grep -Fx 'DB_PASSWORD=must-not-appear-in-output' "$REBUILD_APP_ENV_FILE"
  [ "$(stat -f '%Lp' "$REBUILD_APP_ENV_FILE")" = 640 ]
}

@test "atomic env update refuses duplicate exact keys" {
  printf '%s\n' 'ERAMBA_IMAGE_TAG=old' 'ERAMBA_IMAGE_TAG=duplicate' >"$REBUILD_APP_ENV_FILE"

  run bash -c '
    set -Eeuo pipefail
    ROOT_DIR=$1
    ENV_FILE=$2
    source "$ROOT_DIR/lib/rebuild-app/common.sh"
    atomic_set_env ERAMBA_IMAGE_TAG target
  ' bash "$REBUILD_APP_ROOT" "$REBUILD_APP_ENV_FILE"
  [ "$status" -ne 0 ]
  assert_output_contains "Duplicate ERAMBA_IMAGE_TAG definitions"
  [ "$(grep -c '^ERAMBA_IMAGE_TAG=' "$REBUILD_APP_ENV_FILE")" -eq 2 ]
}

@test "staged startup verifies eramba then cron then triggers" {
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --yes --backup-confirmed
  [ "$status" -eq 0 ]

  eramba_up=$(grep -n " up -d eramba$" "$FAKE_COMMAND_LOG" | head -1 | cut -d: -f1)
  http_check=$(grep -n " exec .* eramba curl " "$FAKE_COMMAND_LOG" | head -1 | cut -d: -f1)
  config_check=$(grep -n " current_config validate" "$FAKE_COMMAND_LOG" | head -1 | cut -d: -f1)
  health_check=$(grep -n " system_health check" "$FAKE_COMMAND_LOG" | head -1 | cut -d: -f1)
  cron_up=$(grep -n " up -d cron$" "$FAKE_COMMAND_LOG" | head -1 | cut -d: -f1)
  migrations_check=$(grep -n " cron bin/cake migrations status" "$FAKE_COMMAND_LOG" | head -1 | cut -d: -f1)
  triggers_up=$(grep -n " up -d triggers_caddy$" "$FAKE_COMMAND_LOG" | head -1 | cut -d: -f1)
  trigger_health=$(grep -n "State.Health.Status.*triggers_caddy" "$FAKE_COMMAND_LOG" | head -1 | cut -d: -f1)

  [ "$eramba_up" -lt "$http_check" ]
  [ "$http_check" -lt "$config_check" ]
  [ "$config_check" -lt "$health_check" ]
  [ "$health_check" -lt "$cron_up" ]
  [ "$cron_up" -lt "$migrations_check" ]
  [ "$migrations_check" -lt "$triggers_up" ]
  [ "$triggers_up" -lt "$trigger_health" ]
}

@test "migration boundary failure keeps target tag and captures diagnostics without rollback" {
  export FAKE_HTTP_STATUS=1
  export REBUILD_APP_START_TIMEOUT_SECONDS=0
  export REBUILD_APP_POLL_INTERVAL_SECONDS=0

  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --yes --backup-confirmed
  [ "$status" -ne 0 ]
  assert_output_contains "Migration boundary crossed; automatic rollback was not attempted"
  assert_output_contains "Diagnostics:"
  [[ "$output" != *'must-not-appear-in-output'* ]]
  grep -Fx 'ERAMBA_IMAGE_TAG=3.30.1-6' "$REBUILD_APP_ENV_FILE"
  assert_log_excludes " up -d eramba cron triggers_caddy"
  assert_log_excludes " up -d cron"
  assert_log_excludes " up -d triggers_caddy"

  run_dir=$(find "$REBUILD_APP_STATE_DIR/runs" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -n "$run_dir" ]
  grep -Fx 'phase=migration-boundary' "$run_dir/state.txt"
  grep -Fx 'current_image=ghcr.io/eramba/eramba:3.30.0-23' "$run_dir/state.txt"
  grep -Fx 'target_image=ghcr.io/eramba/eramba:3.30.1-6' "$run_dir/state.txt"
  grep -Fx 'current_image_id=sha256:current' "$run_dir/state.txt"
  grep -Fx 'target_image_id=sha256:target' "$run_dir/state.txt"
  ! grep -R -F 'must-not-appear-in-output' "$run_dir"
  [ "$(stat -f '%Lp' "$run_dir")" = 700 ]
  while IFS= read -r file; do
    [ "$(stat -f '%Lp' "$file")" = 600 ]
  done < <(find "$run_dir" -type f)
}

@test "post-boundary preserved volume mismatch fails without restoring old code" {
  export FAKE_CHANGED_PRESERVED_VOLUME=logs

  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --yes --backup-confirmed
  [ "$status" -ne 0 ]
  assert_output_contains "Preserved volume identity changed"
  assert_output_contains "automatic rollback was not attempted"
  grep -Fx 'ERAMBA_IMAGE_TAG=3.30.1-6' "$REBUILD_APP_ENV_FILE"
}
