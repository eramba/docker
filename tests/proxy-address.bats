#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  network_id=
  proxy_id=
  peer_id=
}

teardown() {
  [ -z "$proxy_id" ] || docker rm -f "$proxy_id" >/dev/null
  [ -z "$peer_id" ] || docker rm -f "$peer_id" >/dev/null
  [ -z "$network_id" ] || docker network rm "$network_id" >/dev/null
}

create_proxy_network() {
  # Try production defaults first. If another installation uses that subnet,
  # exercise the documented custom-network configuration instead.
  local attempt octet config subnet pool result
  local overrides=()
  for attempt in $(seq 0 10); do
    if [ "$attempt" -gt 0 ]; then
      octet=$((100 + ($$ + attempt) % 100))
      overrides=(APP_INTERNAL_SUBNET="172.30.$octet.0/24" APP_INTERNAL_IP_RANGE="172.30.$octet.128/25" PUBLIC_PROXY_IP="172.30.$octet.10")
    fi
    config=$(env -i PATH="$PATH" HOME="$HOME" "${overrides[@]}" docker compose \
      --project-directory "$REPOSITORY_ROOT" --env-file "$REPOSITORY_ROOT/.env" \
      -f "$REPOSITORY_ROOT/docker-compose.simple-install.yml" config --format json) || return 1
    proxy_ip=$(jq -er '.services.public_proxy.networks.app_internal.ipv4_address' <<<"$config") || return 1
    subnet=$(jq -er '.networks.app_internal.ipam.config[0].subnet' <<<"$config") || return 1
    pool=$(jq -er '.networks.app_internal.ipam.config[0].ip_range' <<<"$config") || return 1
    if result=$(docker network create --internal --subnet "$subnet" --ip-range "$pool" \
      --label eramba.proxy-test=address "eramba-proxy-test-$$-$attempt" 2>&1); then
      network_id="$result"
      return 0
    fi
    case "$result" in
      *"Pool overlaps"*) ;;
      *) printf '%s\n' "$result" >&2; return 1 ;;
    esac
  done
  printf 'No free proxy-test subnet found\n' >&2
  return 1
}

container_ip() {
  docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"
}

@test "the reserved Caddy address survives recreation alongside a dynamic peer" {
  create_proxy_network
  peer_id=$(docker run -d --network "$network_id" caddy:2.8-alpine sleep 120)
  peer_ip=$(container_ip "$peer_id")
  [ -n "$peer_ip" ]
  [ "$peer_ip" != "$proxy_ip" ]

  proxy_id=$(docker run -d --network "$network_id" --ip "$proxy_ip" caddy:2.8-alpine sleep 120)
  [ "$(container_ip "$proxy_id")" = "$proxy_ip" ]
  docker rm -f "$proxy_id" >/dev/null
  proxy_id=
  proxy_id=$(docker run -d --network "$network_id" --ip "$proxy_ip" caddy:2.8-alpine sleep 120)
  [ "$(container_ip "$proxy_id")" = "$proxy_ip" ]
  [ "$(container_ip "$peer_id")" = "$peer_ip" ]
  [ "$(docker inspect --format '{{.State.Running}}' "$peer_id")" = true ]
}
