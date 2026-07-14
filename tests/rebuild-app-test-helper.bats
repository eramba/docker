#!/usr/bin/env bats

@test "test setup falls back when BATS_TEST_TMPDIR is unavailable" {
  run env -u BATS_TEST_TMPDIR \
    TMPDIR="$BATS_TEST_TMPDIR" \
    BATS_TEST_DIRNAME="$BATS_TEST_DIRNAME" \
    bash -e -c '
      source "$1"
      setup_rebuild_app_test
      test -d "$TEST_TMPDIR"
      teardown_rebuild_app_test
    ' bash "$BATS_TEST_DIRNAME/test_helper.bash"

  [ "$status" -eq 0 ]
}
