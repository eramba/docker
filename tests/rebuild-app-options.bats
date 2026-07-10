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
