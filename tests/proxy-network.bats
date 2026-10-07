#!/usr/bin/env bats

setup_file() {
  docker image inspect caddy:2.8-alpine >/dev/null 2>&1 || docker pull caddy:2.8-alpine >/dev/null
}

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  TEST_NETWORK=""
  TEST_CONTAINERS=()
}

teardown() {
  for container in "${TEST_CONTAINERS[@]}"; do
    docker rm -f "$container" >/dev/null
  done
  if [ -n "$TEST_NETWORK" ]; then
    docker network rm "$TEST_NETWORK" >/dev/null
  fi
}

@test "dynamic services can start before Caddy without taking its reserved IPv4 address" {
  run env -i PATH="$PATH" HOME="$HOME" docker compose \
    --project-directory "$REPOSITORY_ROOT" \
    --env-file "$REPOSITORY_ROOT/tests/fixtures/compose.env" \
    -f "$REPOSITORY_ROOT/docker-compose.simple-install.yml" config --format json
  [ "$status" -eq 0 ]
  config="$output"
  subnet="$(jq -r '.networks.app_internal.ipam.config[0].subnet' <<<"$config")"
  dynamic_range="$(jq -r '.networks.app_internal.ipam.config[0].ip_range' <<<"$config")"
  proxy_ip="$(jq -r '.services.public_proxy.networks.app_internal.ipv4_address' <<<"$config")"

  run docker network create --internal --subnet "$subnet" --ip-range "$dynamic_range" "eramba-proxy-allocation-$$"
  [ "$status" -eq 0 ]
  TEST_NETWORK="$output"

  # Model services that Compose starts before public_proxy. A pool covering the
  # whole subnet would allocate .2 here and prevent Caddy from starting.
  for service in mysql eramba; do
    run docker create --network "$TEST_NETWORK" --entrypoint sh caddy:2.8-alpine -c 'sleep 300'
    [ "$status" -eq 0 ]
    TEST_CONTAINERS+=("$output")
    run docker start "${TEST_CONTAINERS[${#TEST_CONTAINERS[@]}-1]}"
    [ "$status" -eq 0 ]
  done

  run docker create --network "$TEST_NETWORK" --ip "$proxy_ip" --entrypoint sh caddy:2.8-alpine -c 'sleep 300'
  [ "$status" -eq 0 ]
  TEST_CONTAINERS+=("$output")
  run docker start "${TEST_CONTAINERS[2]}"
  [ "$status" -eq 0 ]
  run docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${TEST_CONTAINERS[2]}"
  [ "$status" -eq 0 ]
  [ "$output" = "$proxy_ip" ]
}
