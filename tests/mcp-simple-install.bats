#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  render_compose
}

render_compose() {
  run env -i PATH="$PATH" HOME="$HOME" docker compose \
    --project-directory "$REPOSITORY_ROOT" \
    --env-file "$REPOSITORY_ROOT/tests/fixtures/compose.env" \
    -f "$REPOSITORY_ROOT/docker-compose.simple-install.yml" \
    "$@" \
    config --format json

  [ "$status" -eq 0 ]
  COMPOSE_CONFIG="$output"
}

@test "simple install keeps release app images and uses the latest MCP image" {
  [ "$(jq -r '.services.eramba.image' <<<"$COMPOSE_CONFIG")" = "ghcr.io/eramba/eramba:latest" ]
  [ "$(jq -r '.services.cron.image' <<<"$COMPOSE_CONFIG")" = "ghcr.io/eramba/eramba:latest" ]
  [ "$(jq -r '.services.triggers_caddy.image' <<<"$COMPOSE_CONFIG")" = "ghcr.io/eramba/eramba-triggers:latest" ]
  [ "$(jq -r '.services.mcp_server.image' <<<"$COMPOSE_CONFIG")" = "ghcr.io/eramba/eramba-mcp-server:latest" ]
}

@test "Caddy is the only published application edge" {
  [ "$(jq -r '(.services.eramba.ports // []) | length' <<<"$COMPOSE_CONFIG")" -eq 0 ]
  [ "$(jq -r '(.services.mcp_server.ports // []) | length' <<<"$COMPOSE_CONFIG")" -eq 0 ]
  [ "$(jq -r '.services.public_proxy.ports | length' <<<"$COMPOSE_CONFIG")" -eq 1 ]
  [ "$(jq -r '.services.public_proxy.ports[0] | "\(.published):\(.target)"' <<<"$COMPOSE_CONFIG")" = "8443:443" ]
}

@test "MCP derives public metadata from PUBLIC_ADDRESS and introspects internally" {
  [ "$(jq -r '.services.mcp_server.environment.PUBLIC_ADDRESS' <<<"$COMPOSE_CONFIG")" = "https://localhost:8443" ]
  [ "$(jq -r '.services.mcp_server.environment.ERAMBA_OAUTH_INTROSPECTION_URL' <<<"$COMPOSE_CONFIG")" = "https://eramba:443/oauth2/introspect" ]

  for override in MCP_PUBLIC_URL MCP_RESOURCE ERAMBA_OAUTH_ISSUER OAUTH2_ISSUER OAUTH2_RESOURCE; do
    [ "$(jq -r --arg name "$override" '.services.mcp_server.environment | has($name)' <<<"$COMPOSE_CONFIG")" = "false" ]
  done
}

@test "Caddy receives the bundled TLS certificate and key" {
  [ "$(jq -r '[.services.public_proxy.volumes[].target] | index("/certs/mycert.crt") != null' <<<"$COMPOSE_CONFIG")" = "true" ]
  [ "$(jq -r '[.services.public_proxy.volumes[].target] | index("/certs/mycert.key") != null' <<<"$COMPOSE_CONFIG")" = "true" ]
}

@test "application trust follows the fixed Caddy address on the internal network" {
  [ "$(jq -r '.services.eramba.environment.TRUST_PROXY' <<<"$COMPOSE_CONFIG")" = "1" ]
  [ "$(jq -r '.services.eramba.environment.TRUSTED_PROXIES' <<<"$COMPOSE_CONFIG")" = "172.30.250.2/32" ]
  [ "$(jq -r '.services.public_proxy.networks.app_internal.ipv4_address' <<<"$COMPOSE_CONFIG")" = "172.30.250.2" ]
  [ "$(jq -r '.networks.app_internal.ipam.config[0].subnet' <<<"$COMPOSE_CONFIG")" = "172.30.250.0/24" ]
  [ "$(jq -r '.networks.app_internal.ipam.config[0].ip_range' <<<"$COMPOSE_CONFIG")" = "172.30.250.128/25" ]
  [ "$(jq -r '.networks.app_internal.internal' <<<"$COMPOSE_CONFIG")" = "true" ]
  [ "$(jq -r '.services.public_proxy.environment.EXTERNAL_TRUSTED_PROXIES' <<<"$COMPOSE_CONFIG")" = "" ]
}

@test "custom proxy address and external trust survive the enterprise overlay" {
  cat >"$BATS_TEST_TMPDIR/proxies.env" <<'ENV'
APP_INTERNAL_SUBNET=10.70.8.0/24
APP_INTERNAL_DYNAMIC_RANGE=10.70.8.128/25
PUBLIC_PROXY_IP=10.70.8.25
EXTERNAL_TRUSTED_PROXIES=192.0.2.10/32 2001:db8:1::/64
ENV
  render_compose --env-file "$BATS_TEST_TMPDIR/proxies.env" \
    -f "$REPOSITORY_ROOT/docker-compose.simple-install.enterprise.yml"

  [ "$(jq -r '.services.eramba.image' <<<"$COMPOSE_CONFIG")" = "ghcr.io/eramba/eramba-enterprise:latest" ]
  [ "$(jq -r '.services.eramba.environment.TRUSTED_PROXIES' <<<"$COMPOSE_CONFIG")" = "10.70.8.25/32" ]
  [ "$(jq -r '.services.public_proxy.networks.app_internal.ipv4_address' <<<"$COMPOSE_CONFIG")" = "10.70.8.25" ]
  [ "$(jq -r '.networks.app_internal.ipam.config[0].subnet' <<<"$COMPOSE_CONFIG")" = "10.70.8.0/24" ]
  [ "$(jq -r '.networks.app_internal.ipam.config[0].ip_range' <<<"$COMPOSE_CONFIG")" = "10.70.8.128/25" ]
  [ "$(jq -r '.services.public_proxy.environment.EXTERNAL_TRUSTED_PROXIES' <<<"$COMPOSE_CONFIG")" = "192.0.2.10/32 2001:db8:1::/64" ]
  [ "$(jq -r '.services.eramba.environment.TRUST_PROXY' <<<"$COMPOSE_CONFIG")" = "1" ]
}
