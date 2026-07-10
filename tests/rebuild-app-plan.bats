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
