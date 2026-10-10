#!/usr/bin/env bats
setup() {
  UPDATE_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  UPDATE_TEST_DIR="$(mktemp -d)"
  export UPDATE_CALLS="$UPDATE_TEST_DIR/calls"
  export UPDATE_FAILURE="" UPDATE_REPEAT="" UPDATE_IMAGE_CHANGED="" UPDATE_DATABASE_CHANGED="" UPDATE_OVERRIDE_IMAGE="" UPDATE_DRAINED_TARGET=""
  mkdir "$UPDATE_TEST_DIR/bin"
  cp "$UPDATE_ROOT/tests/fixtures/docker-update-recorder" "$UPDATE_TEST_DIR/bin/docker"
  chmod +x "$UPDATE_TEST_DIR/bin/docker"
  export PATH="$UPDATE_TEST_DIR/bin:$PATH"
  printf 'DB_PASSWORD=fixture-only\n' > "$UPDATE_TEST_DIR/.env"
}
teardown() { rm -rf "$UPDATE_TEST_DIR"; }
update_image() { "$UPDATE_ROOT/bin/eramba-update" --project-name fixture --env-file "$UPDATE_TEST_DIR/.env" --image ghcr.io/eramba/eramba:bridge-test "$@"; }

@test "drain precedes client stop and app-only volume replacement while owner remains alive" {
  run update_image
  [ "$status" -eq 0 ]
  drained=$(rg -n 'host-drained' "$UPDATE_CALLS" | head -n1 | cut -d: -f1)
  stopped=$(rg -n ' stop ' "$UPDATE_CALLS" | head -n1 | cut -d: -f1)
  replaced=$(rg -n 'volume rm fixture_app' "$UPDATE_CALLS" | cut -d: -f1)
  permitted=$(rg -n 'host-permit' "$UPDATE_CALLS" | cut -d: -f1)
  [ "$drained" -lt "$stopped" ]
  [ "$stopped" -lt "$replaced" ]
  [ "$replaced" -lt "$permitted" ]
  ! rg -q 'stop.*mysql|down|volume rm.*(db-data|data|logs)' "$UPDATE_CALLS"
}
@test "timeout stops before client removal or preparation permission" {
  export UPDATE_FAILURE=drain
  run update_image --drain-timeout 1
  [ "$status" -ne 0 ]
  ! rg -q ' stop |volume rm|host-permit' "$UPDATE_CALLS"
}
@test "offline load does not pull" {
  touch "$UPDATE_TEST_DIR/release.tar"
  run update_image --load "$UPDATE_TEST_DIR/release.tar"
  [ "$status" -eq 0 ]
  rg -q 'load --input' "$UPDATE_CALLS"
  ! rg -q '^pull' "$UPDATE_CALLS"
}
@test "matching prepared code is a no-op" {
  export UPDATE_REPEAT=1
  run update_image
  [ "$status" -eq 0 ]
  ! rg -q 'prepare-host| stop |volume rm' "$UPDATE_CALLS"
  rg -q '^ERAMBA_IMAGE=ghcr.io/eramba/eramba:bridge-test$' "$UPDATE_TEST_DIR/.env"
}
@test "changed image with matching code still drains and replaces app volume" {
  export UPDATE_REPEAT=1 UPDATE_IMAGE_CHANGED=1
  run update_image
  [ "$status" -eq 0 ]
  rg -q 'prepare-host|volume rm fixture_app' "$UPDATE_CALLS"
}
@test "same image and code cannot skip preparation after database scope changes" {
  export UPDATE_REPEAT=1 UPDATE_DATABASE_CHANGED=1
  run update_image
  [ "$status" -ne 0 ]
  ! rg -q 'prepare-host| stop |volume rm|host-permit' "$UPDATE_CALLS"
}
@test "explicit local image does not pull" {
  run update_image --no-pull
  [ "$status" -eq 0 ]
  ! rg -q '^pull' "$UPDATE_CALLS"
}
@test "foreign app volume ownership refuses deletion and permit" {
  export UPDATE_FAILURE=ownership
  run update_image
  [ "$status" -ne 0 ]
  ! rg -q 'volume rm|host-permit' "$UPDATE_CALLS"
}
@test "enterprise image is carried through the dedicated preparation service" {
  run "$UPDATE_ROOT/bin/eramba-update" --project-name fixture --env-file "$UPDATE_TEST_DIR/.env" --enterprise --image ghcr.io/eramba/eramba-enterprise:bridge-test
  [ "$status" -eq 0 ]
  rg -q 'prepare-host ghcr.io/eramba/eramba-enterprise:bridge-test' "$UPDATE_CALLS"
}
@test "mutable latest cannot authorize an update" {
  run "$UPDATE_ROOT/bin/eramba-update" --env-file "$UPDATE_TEST_DIR/.env" --image ghcr.io/eramba/eramba:latest
  [ "$status" -ne 0 ]
  [ ! -s "$UPDATE_CALLS" ]
}

@test "a Compose override cannot select a different coordinator image" {
  export UPDATE_OVERRIDE_IMAGE=1
  run update_image
  [ "$status" -ne 0 ]
  ! rg -q 'prepare-host| stop |volume rm|host-permit' "$UPDATE_CALLS"
}

@test "drained target must equal the selected image code before client removal" {
  export UPDATE_DRAINED_TARGET=1
  run update_image
  [ "$status" -ne 0 ]
  ! rg -q ' stop |volume rm|host-permit' "$UPDATE_CALLS"
}
