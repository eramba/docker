#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

  run env -i PATH="$PATH" HOME="$HOME" docker compose \
    --project-directory "$REPOSITORY_ROOT" \
    --env-file "$REPOSITORY_ROOT/.env" \
    -f "$REPOSITORY_ROOT/docker-compose.simple-install.yml" \
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

@test "Apache trusts only the reserved Caddy address by default" {
  for edition in community enterprise; do
    run resolve_compose "$edition" "$REPOSITORY_ROOT/.env"
    [ "$status" -eq 0 ]
    assert_default_proxy "$output"
    if [ "$edition" = enterprise ]; then
      [ "$(jq -r '.services.eramba.image' <<<"$output")" = 'ghcr.io/eramba/eramba-enterprise:latest' ]
    fi
  done
}

@test "Caddy trusts no external proxies by default" {
  [ "$(jq -r '.services.public_proxy.environment.CADDY_TRUSTED_PROXIES' <<<"$COMPOSE_CONFIG")" = "" ]
}

resolve_compose() {
  local edition="$1" env_file="$2"
  shift 2
  local compose_files=(-f "$REPOSITORY_ROOT/docker-compose.simple-install.yml")
  if [ "$edition" = enterprise ]; then
    compose_files+=(-f "$REPOSITORY_ROOT/docker-compose.simple-install.enterprise.yml")
  fi
  env -i PATH="$PATH" HOME="$HOME" "$@" docker compose \
    --project-directory "$REPOSITORY_ROOT" --env-file "$env_file" \
    "${compose_files[@]}" config --format json
}

assert_default_proxy() {
  jq -e '
    .services.eramba.environment.TRUSTED_PROXIES == "172.30.50.10" and
    .services.public_proxy.networks.app_internal.ipv4_address == "172.30.50.10" and
    (.services.public_proxy.networks | has("host_access")) and
    .networks.app_internal.internal == true and
    .networks.app_internal.ipam.config == [{subnet: "172.30.50.0/24", ip_range: "172.30.50.128/25"}]
  ' <<<"$1"
}

@test "Community and Enterprise pass proxy settings to their owning services" {
  for edition in community enterprise; do
    compose_files=(-f "$REPOSITORY_ROOT/docker-compose.simple-install.yml")
    if [ "$edition" = enterprise ]; then
      compose_files+=(-f "$REPOSITORY_ROOT/docker-compose.simple-install.enterprise.yml")
    fi

    run env -i PATH="$PATH" HOME="$HOME" \
      TRUSTED_PROXIES='172.30.50.10,10.0.0.5/32' \
      CADDY_TRUSTED_PROXIES='10.0.0.5/32 2001:db8::5/128' \
      docker compose --project-directory "$REPOSITORY_ROOT" \
      --env-file "$REPOSITORY_ROOT/.env" "${compose_files[@]}" config --format json

    [ "$status" -eq 0 ]
    [ "$(jq -r '.services.eramba.environment.TRUSTED_PROXIES' <<<"$output")" = '172.30.50.10,10.0.0.5/32' ]
    [ "$(jq -r '.services.public_proxy.environment.CADDY_TRUSTED_PROXIES' <<<"$output")" = '10.0.0.5/32 2001:db8::5/128' ]
  done
}

@test "older env files without proxy settings use the bundled Caddy automatically" {
  env_file="$BATS_TEST_TMPDIR/older.env"
  sed '/^TRUSTED_PROXIES=/d; /^CADDY_TRUSTED_PROXIES=/d; /^APP_INTERNAL_SUBNET=/d; /^APP_INTERNAL_IP_RANGE=/d; /^PUBLIC_PROXY_IP=/d' "$REPOSITORY_ROOT/.env" > "$env_file"

  for edition in community enterprise; do
    run resolve_compose "$edition" "$env_file"
    [ "$status" -eq 0 ]
    assert_default_proxy "$output"
    [ "$(jq -r '.services.public_proxy.environment.CADDY_TRUSTED_PROXIES' <<<"$output")" = "" ]
  done
}

@test "empty network and proxy settings use safe defaults" {
  for edition in community enterprise; do
    run resolve_compose "$edition" "$REPOSITORY_ROOT/.env" \
      APP_INTERNAL_SUBNET= APP_INTERNAL_IP_RANGE= PUBLIC_PROXY_IP= TRUSTED_PROXIES=
    [ "$status" -eq 0 ]
    assert_default_proxy "$output"
  done
}

@test "custom Caddy addresses automatically update Apache trust in both editions" {
  env_file="$BATS_TEST_TMPDIR/custom.env"
  sed '/^TRUSTED_PROXIES=/d' "$REPOSITORY_ROOT/.env" > "$env_file"
  for edition in community enterprise; do
    for trust in missing empty; do
      overrides=(APP_INTERNAL_SUBNET=172.30.60.0/24 APP_INTERNAL_IP_RANGE=172.30.60.128/25 PUBLIC_PROXY_IP=172.30.60.10)
      if [ "$trust" = empty ]; then
        overrides+=(TRUSTED_PROXIES=)
      fi
      run resolve_compose "$edition" "$env_file" "${overrides[@]}"
      [ "$status" -eq 0 ]
      jq -e '
        .services.eramba.environment.TRUSTED_PROXIES == "172.30.60.10" and
        .services.public_proxy.networks.app_internal.ipv4_address == "172.30.60.10" and
        (.services.public_proxy.networks | has("host_access")) and
        .networks.app_internal.internal == true and
        .networks.app_internal.ipam.config == [{subnet: "172.30.60.0/24", ip_range: "172.30.60.128/25"}]
      ' <<<"$output"
    done
  done
}

@test "an explicit Compose override can disable Apache proxy trust" {
  override="$BATS_TEST_TMPDIR/no-proxy-trust.yml"
  cat > "$override" <<'YAML'
services:
  eramba:
    environment:
      TRUSTED_PROXIES: ""
YAML
  for edition in community enterprise; do
    compose_files=(-f "$REPOSITORY_ROOT/docker-compose.simple-install.yml")
    if [ "$edition" = enterprise ]; then
      compose_files+=(-f "$REPOSITORY_ROOT/docker-compose.simple-install.enterprise.yml")
    fi
    run env -i PATH="$PATH" HOME="$HOME" docker compose \
      --project-directory "$REPOSITORY_ROOT" --env-file "$REPOSITORY_ROOT/.env" \
      "${compose_files[@]}" -f "$override" config --format json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.services.eramba.environment.TRUSTED_PROXIES' <<<"$output")" = "" ]
  done
}
