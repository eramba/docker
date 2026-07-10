#!/usr/bin/env bats

load test_helper

setup() {
  setup_rebuild_app_test
  install_fake_docker
  set_required_community_plan
}

teardown() {
  teardown_rebuild_app_test
}

@test "valid Community plan acquires and validates the exact target" {
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "ghcr.io/eramba/eramba:3.30.1-6"
  assert_log_contains "docker pull ghcr.io/eramba/eramba:3.30.1-6"
  assert_preflight_pure
}

@test "required false is an idempotent no-op" {
  export FAKE_PLAN_JSON='{"required":false}'
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "nothing to do"
  assert_log_excludes "docker pull"
  assert_preflight_pure
}

@test "malformed plan fails before mutation" {
  export FAKE_PLAN_JSON='not json'
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Invalid image switch plan"
  assert_preflight_pure
}

@test "required plan rejects a missing field" {
  export FAKE_PLAN_JSON='{"required":true,"source_app_version":"3.30.0"}'
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Invalid image switch plan"
  assert_preflight_pure
}

@test "plan rejects an edition mismatch" {
  export FAKE_PLAN_JSON='{"required":true,"source_app_version":"3.30.0","target_app_version":"3.30.1","current_image_tag":"3.30.0-23","target_image_tag":"3.30.1-6","edition":"enterprise","distribution":"archive"}'
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Plan edition does not match"
  assert_preflight_pure
}

@test "Community plan rejects a non-registry distribution" {
  export FAKE_PLAN_JSON='{"required":true,"source_app_version":"3.30.0","target_app_version":"3.30.1","current_image_tag":"3.30.0-23","target_image_tag":"3.30.1-6","edition":"community","distribution":"archive"}'
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Community plans require registry distribution"
  assert_preflight_pure
}

@test "target application VERSION must match the plan" {
  export FAKE_TARGET_APP_VERSION=3.30.9
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Target application version does not match"
  assert_preflight_pure
}

@test "target local repository and tag must match the plan" {
  export FAKE_TARGET_REPO_TAG=ghcr.io/eramba/eramba:wrong
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Target image repository or tag does not match"
  assert_preflight_pure
}

@test "target architecture must match the Docker host" {
  export FAKE_TARGET_ARCH=arm64
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Target image architecture does not match"
  assert_preflight_pure
}

@test "Enterprise loads the supplied archive and validates its exact tag" {
  archive="${TEST_TMPDIR}/enterprise.tar"
  : >"$archive"
  export FAKE_CURRENT_IMAGE=ghcr.io/eramba/eramba-enterprise:3.30.0-23
  export FAKE_TARGET_REPO_TAG=ghcr.io/eramba/eramba-enterprise:3.30.1-6
  export FAKE_PLAN_JSON='{"required":true,"source_app_version":"3.30.0","target_app_version":"3.30.1","current_image_tag":"3.30.0-23","target_image_tag":"3.30.1-6","edition":"enterprise","distribution":"archive"}'

  run "$REBUILD_APP_ROOT/rebuild-app" --edition enterprise --image-file "$archive" --dry-run
  [ "$status" -eq 0 ]
  assert_log_contains "docker load --input ${archive}"
  assert_log_excludes "docker pull"
  assert_preflight_pure
}

@test "detected edition conflict fails before plan resolution" {
  export FAKE_CURRENT_IMAGE=ghcr.io/eramba/eramba-enterprise:3.30.0-23
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Requested edition conflicts with the running image"
  assert_log_excludes "image_switch_plan"
  assert_preflight_pure
}

@test "current HTTP failure blocks plan resolution" {
  export FAKE_CURRENT_HTTP_STATUS=1
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Current application HTTP readiness check failed"
  assert_log_excludes "image_switch_plan"
  assert_preflight_pure
}

@test "current config failure blocks plan resolution" {
  export FAKE_CURRENT_CONFIG_STATUS=1
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Current configuration validation failed"
  assert_log_excludes "image_switch_plan"
  assert_preflight_pure
}

@test "current system health failure blocks plan resolution" {
  export FAKE_CURRENT_HEALTH_STATUS=1
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Current system health check failed"
  assert_log_excludes "image_switch_plan"
  assert_preflight_pure
}

@test "current migrations failure blocks plan resolution" {
  export FAKE_CURRENT_MIGRATIONS_STATUS=1
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Current migrations status check failed"
  assert_log_excludes "image_switch_plan"
  assert_preflight_pure
}

@test "duplicate image tag keys fail before target acquisition" {
  printf '%s\n' 'ERAMBA_IMAGE_TAG=first' 'ERAMBA_IMAGE_TAG=second' >"$REBUILD_APP_ENV_FILE"
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Duplicate ERAMBA_IMAGE_TAG definitions"
  assert_log_excludes "image_switch_plan"
  assert_log_excludes "docker pull"
}

@test "plan current image tag must match the running deployment" {
  export FAKE_PLAN_JSON='{"required":true,"source_app_version":"3.30.0","target_app_version":"3.30.1","current_image_tag":"wrong","target_image_tag":"3.30.1-6","edition":"community","distribution":"registry"}'
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Plan current image tag does not match"
  assert_preflight_pure
}

@test "plan source application version must match the running deployment" {
  export FAKE_PLAN_JSON='{"required":true,"source_app_version":"3.29.0","target_app_version":"3.30.1","current_image_tag":"3.30.0-23","target_image_tag":"3.30.1-6","edition":"community","distribution":"registry"}'
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Plan source application version does not match"
  assert_preflight_pure
}

@test "plan target tag must be immutable" {
  export FAKE_PLAN_JSON='{"required":true,"source_app_version":"3.30.0","target_app_version":"3.30.1","current_image_tag":"3.30.0-23","target_image_tag":"latest","edition":"community","distribution":"registry"}'
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "target image tag must be immutable"
  assert_preflight_pure
}

@test "missing running eramba container is a hard preflight failure" {
  export FAKE_ERAMBA_RUNNING=false
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "existing running eramba container is required"
  assert_log_excludes "image_switch_plan"
}

@test "Community pull failure occurs before mutation" {
  export FAKE_PULL_STATUS=1
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Unable to pull target image"
  assert_preflight_pure
}

@test "edition is detected when no override is supplied" {
  export FAKE_PLAN_JSON='{"required":false}'
  run "$REBUILD_APP_ROOT/rebuild-app" --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "nothing to do"
}

@test "Enterprise plan rejects a non-archive distribution" {
  archive="${TEST_TMPDIR}/enterprise.tar"
  : >"$archive"
  export FAKE_CURRENT_IMAGE=ghcr.io/eramba/eramba-enterprise:3.30.0-23
  export FAKE_PLAN_JSON='{"required":true,"source_app_version":"3.30.0","target_app_version":"3.30.1","current_image_tag":"3.30.0-23","target_image_tag":"3.30.1-6","edition":"enterprise","distribution":"registry"}'

  run "$REBUILD_APP_ROOT/rebuild-app" --edition enterprise --image-file "$archive" --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "Enterprise plans require archive distribution"
  assert_preflight_pure
}

@test "Enterprise archive must contain the exact planned image" {
  archive="${TEST_TMPDIR}/enterprise.tar"
  : >"$archive"
  export FAKE_CURRENT_IMAGE=ghcr.io/eramba/eramba-enterprise:3.30.0-23
  export FAKE_PLAN_JSON='{"required":true,"source_app_version":"3.30.0","target_app_version":"3.30.1","current_image_tag":"3.30.0-23","target_image_tag":"3.30.1-6","edition":"enterprise","distribution":"archive"}'
  export FAKE_IMAGE_INSPECT_STATUS=1

  run "$REBUILD_APP_ROOT/rebuild-app" --edition enterprise --image-file "$archive" --dry-run
  [ "$status" -ne 0 ]
  assert_output_contains "archive did not provide the planned image"
  assert_preflight_pure
}
