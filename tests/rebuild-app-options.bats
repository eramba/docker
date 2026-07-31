#!/usr/bin/env bats

load test_helper

setup() {
  setup_rebuild_app_test
}

teardown() {
  teardown_rebuild_app_test
}

@test "community rejects an image archive" {
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --image-file target.tar --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "--image-file is only valid for enterprise"
}

@test "enterprise requires an image archive" {
  run "$REBUILD_APP_ROOT/rebuild-app" --edition enterprise --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "--image-file is required for enterprise"
}

@test "non-interactive mutation requires backup confirmation" {
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --yes
  [ "$status" -ne 0 ]
  assert_output_contains "--backup-confirmed is required with --yes"
}

@test "unknown options are rejected" {
  run "$REBUILD_APP_ROOT/rebuild-app" --target-tag 3.30.1-6
  [ "$status" -ne 0 ]
  assert_output_contains "Unknown option: --target-tag"
}

@test "safe repository update pulls fast-forward once and re-executes" {
  install_fake_git
  install_fake_docker
  export FAKE_PLAN_JSON='{"required":false}'

  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --update-repo --dry-run
  [ "$status" -eq 0 ]
  [ "$(grep -c 'git -C .* pull --ff-only' "$FAKE_COMMAND_LOG")" -eq 1 ]
  assert_log_contains "image_switch_plan"
}

@test "repository update rejects a dirty checkout before Docker preflight" {
  install_fake_git
  export FAKE_GIT_STATUS=' M README.md'

  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --update-repo --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "clean checkout"
  assert_log_excludes "docker inspect"
}

@test "repository update rejects a detached checkout before Docker preflight" {
  install_fake_git
  export FAKE_GIT_DETACHED=1

  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --update-repo --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "attached branch"
  assert_log_excludes "docker inspect"
}

@test "repository update rejects a non-fast-forward pull before Docker preflight" {
  install_fake_git
  export FAKE_GIT_PULL_STATUS=1

  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --update-repo --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "git pull --ff-only failed"
  assert_log_excludes "docker inspect"
}

@test "existing installation lock rejects concurrent execution" {
  install_fake_docker
  mkdir -p "$REBUILD_APP_LOCK_DIR"

  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Another rebuild-app process is running"
  assert_log_excludes "docker inspect"
}

@test "backup-confirmed does not bypass interactive plan confirmation" {
  install_fake_docker
  set_required_community_plan
  write_current_env

  run bash -c 'printf "no\n" | "$1" --edition community --backup-confirmed' bash "$REBUILD_APP_ROOT/rebuild-app"
  [ "$status" -ne 0 ]
  assert_output_contains "Deployment plan was not confirmed"
  assert_log_excludes " compose stop "
  grep -Fx 'ERAMBA_IMAGE_TAG=3.30.0-23' "$REBUILD_APP_ENV_FILE"
}
