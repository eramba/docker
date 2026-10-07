#!/usr/bin/env bats

setup_file() {
  docker image inspect caddy:2.8-alpine >/dev/null 2>&1 || docker pull caddy:2.8-alpine >/dev/null
}

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PROXY_TEST_CONTAINER=""
  ALIAS_HEADERS=()
  for first in - _ .; do
    for second in - _ .; do
      [ "$first$second" != '--' ] || continue
      for suffix in For Proto Host Port Prefix; do
        ALIAS_HEADERS+=("X${first}Forwarded${second}$suffix")
      done
      ALIAS_HEADERS+=("X${first}Real${second}IP")
    done
  done
  ALIAS_HEADERS+=(Client_IP Client.IP)
}

teardown() {
  if [ -n "$PROXY_TEST_CONTAINER" ]; then
    docker rm -f "$PROXY_TEST_CONTAINER" >/dev/null
  fi
}

start_proxy() {
  run docker create \
    -p 127.0.0.1::443 -p 127.0.0.1::8081 \
    -e "EXTERNAL_TRUSTED_PROXIES=$1" \
    -e ERAMBA_UPSTREAM=https://127.0.0.1:8080 \
    -e MCP_UPSTREAM=127.0.0.1:8082 \
    caddy:2.8-alpine
  [ "$status" -eq 0 ]
  PROXY_TEST_CONTAINER="$output"
  alias_response=""
  for name in "${ALIAS_HEADERS[@]}"; do
    alias_response+="{http.request.header.$name}|"
  done
  fixture="$(cat "$REPOSITORY_ROOT/tests/fixtures/Caddyfile.proxy-test")"
  printf '%s\n' "${fixture//__FORWARDING_ALIASES__/$alias_response}" >"$BATS_TEST_TMPDIR/Caddyfile"
  docker cp "$REPOSITORY_ROOT/Caddyfile" "$PROXY_TEST_CONTAINER:/etc/caddy/installer.Caddyfile"
  docker cp "$BATS_TEST_TMPDIR/Caddyfile" "$PROXY_TEST_CONTAINER:/etc/caddy/Caddyfile"
  docker cp "$REPOSITORY_ROOT/apache/ssl" "$PROXY_TEST_CONTAINER:/certs"
  run docker start "$PROXY_TEST_CONTAINER"
  [ "$status" -eq 0 ]
  PROXY_PORT="$(docker port "$PROXY_TEST_CONTAINER" 443/tcp | cut -d: -f2)"
  LB_PORT="$(docker port "$PROXY_TEST_CONTAINER" 8081/tcp | cut -d: -f2)"
  for attempt in {1..30}; do
    if curl --fail --silent --insecure --max-time 2 "https://127.0.0.1:$PROXY_PORT/" >/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  docker logs "$PROXY_TEST_CONTAINER" >&2
  return 1
}

validate_proxy() {
  run docker create --network none \
    -e "EXTERNAL_TRUSTED_PROXIES=$1" \
    caddy:2.8-alpine caddy validate --config /etc/caddy/Caddyfile
  [ "$status" -eq 0 ]
  PROXY_TEST_CONTAINER="$output"
  docker cp "$REPOSITORY_ROOT/Caddyfile" "$PROXY_TEST_CONTAINER:/etc/caddy/Caddyfile"
  docker cp "$REPOSITORY_ROOT/apache/ssl" "$PROXY_TEST_CONTAINER:/certs"
  run docker start -a "$PROXY_TEST_CONTAINER"
}

@test "empty external proxy trust accepts the real peer and rejects a forged chain" {
  start_proxy ""
  peer="$(curl --fail --silent --insecure "https://127.0.0.1:$PROXY_PORT/")"
  [ -n "$peer" ]
  [[ "$peer" != *,* ]]
  run curl --fail --silent --insecure "https://127.0.0.1:$PROXY_PORT/" \
    -H 'X-Forwarded-For: 192.0.2.66, 10.40.5.6'
  [ "$status" -eq 0 ]
  [ "$output" = "$peer" ]

  # The loopback LB is also untrusted until explicitly configured.
  run curl --fail --silent "http://127.0.0.1:$LB_PORT/" -H 'X-Forwarded-For: 192.0.2.66'
  [ "$status" -eq 0 ]
  [ "$output" = "127.0.0.1" ]
}

@test "trusted LB resolves from the right and sends one canonical private client address" {
  start_proxy "127.0.0.1/32"
  run curl --fail --silent "http://127.0.0.1:$LB_PORT/" -H 'X-Forwarded-For: 192.0.2.66'
  [ "$status" -eq 0 ]
  [ "$output" = "10.40.5.6" ]

  # Direct callers remain untrusted even when an LB is configured.
  peer="$(curl --fail --silent --insecure "https://127.0.0.1:$PROXY_PORT/")"
  run curl --fail --silent --insecure "https://127.0.0.1:$PROXY_PORT/" \
    -H 'X-Forwarded-For: 192.0.2.66'
  [ "$status" -eq 0 ]
  [ "$output" = "$peer" ]
}

@test "MCP discovery paths still reach MCP through the configured proxy" {
  start_proxy ""
  for path in /mcp /openapi /openapi.json /.well-known/oauth-protected-resource \
    /.well-known/oauth-protected-resource/mcp /.well-known/oauth-authorization-server \
    /.well-known/openid-configuration; do
    run curl --fail --silent --insecure "https://127.0.0.1:$PROXY_PORT$path"
    [ "$status" -eq 0 ]
    [ "$output" = "mcp" ]
  done
}

@test "untrusted peers cannot supply forwarded port prefix or IP aliases" {
  start_proxy "127.0.0.1/32"
  run curl --fail --silent --insecure "https://127.0.0.1:$PROXY_PORT/metadata" \
    -H 'X-Forwarded-Proto: http' -H 'X-Forwarded-Host: attacker.example' \
    -H 'X-Forwarded-Port: 444' -H 'X-Forwarded-Prefix: /attacker' \
    -H 'Forwarded: for=192.0.2.66;proto=http' \
    -H 'X-Real-IP: 192.0.2.66' -H 'Client-IP: 192.0.2.66'
  [ "$status" -eq 0 ]
  [ "$output" = "https|127.0.0.1:$PROXY_PORT|||||" ]
}

@test "trusted LB retains legitimate forwarded scheme host port and prefix" {
  start_proxy "127.0.0.1/32"
  run curl --fail --silent "http://127.0.0.1:$LB_PORT/metadata"
  [ "$status" -eq 0 ]
  [ "$output" = "https|public.example:8443|8443|/grc|for=10.40.5.6;proto=https|10.40.5.6|10.40.5.6" ]
}

@test "external proxy configuration accepts space-separated IPv4 and IPv6 CIDRs" {
  validate_proxy "192.0.2.10/32 2001:db8:1::/64"
  [ "$status" -eq 0 ]
}

@test "underscore and dot aliases never reach application or MCP from direct or trusted peers" {
  start_proxy "127.0.0.1/32"
  headers=()
  for name in "${ALIAS_HEADERS[@]}"; do
    headers+=(-H "$name: spoofed")
  done
  for edge in "https://127.0.0.1:$PROXY_PORT" "http://127.0.0.1:$LB_PORT"; do
    for path in / /mcp; do
      run curl --fail --silent --insecure "$edge$path?alias-test=1" "${headers[@]}"
      [ "$status" -eq 0 ]
      [ -n "$output" ]
      [[ "$output" != *[!\|]* ]]
    done
  done
}

@test "invalid external proxy configuration fails Caddy validation" {
  validate_proxy "192.0.2.10/32 invalid-proxy"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid-proxy"* ]]
}
