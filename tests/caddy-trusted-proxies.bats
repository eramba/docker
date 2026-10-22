#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
}

adapt_caddy() {
  docker run --rm --network none \
    -e "CADDY_TRUSTED_PROXIES=$1" \
    -v "$REPOSITORY_ROOT/Caddyfile:/etc/caddy/Caddyfile:ro" \
    caddy:2.8-alpine caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile \
    2>"$BATS_TEST_TMPDIR/caddy.stderr"
}

@test "Caddy's default configuration trusts no upstream proxies" {
  run adapt_caddy ''
  [ "$status" -eq 0 ]
  jq -e 'all(.apps.http.servers[]; ((.trusted_proxies.ranges // []) | length) == 0)' <<<"$output"
}

@test "Caddy accepts explicit IPv4 and IPv6 proxy ranges with strict chain parsing" {
  run adapt_caddy '10.0.0.5/32 2001:db8::5/128'
  [ "$status" -eq 0 ]
  jq -e 'all(.apps.http.servers[];
    .trusted_proxies.ranges == ["10.0.0.5/32", "2001:db8::5/128"]
    and .trusted_proxies_strict == 1)' <<<"$output"
}

proxy_request() {
  # Append a TLS echo backend to the production Caddyfile. Both ends run on
  # loopback in one network-isolated container; no ports are published.
  config="$BATS_TEST_TMPDIR/Caddyfile"
  cat "$REPOSITORY_ROOT/Caddyfile" > "$config"
  cat >> "$config" <<'CADDY'

:9443 {
	tls /certs/mycert.crt /certs/mycert.key
	respond "xff={http.request.header.X-Forwarded-For};client={client_ip};proto={http.request.header.X-Forwarded-Proto}"
}
CADDY

  docker run --rm --network none \
    -e "CADDY_TRUSTED_PROXIES=$1" \
    -e ERAMBA_UPSTREAM=https://127.0.0.1:9443 \
    -v "$config:/etc/caddy/Caddyfile:ro" \
    -v "$REPOSITORY_ROOT/apache/ssl/mycert.crt:/certs/mycert.crt:ro" \
    -v "$REPOSITORY_ROOT/apache/ssl/mycert.key:/certs/mycert.key:ro" \
    --entrypoint sh caddy:2.8-alpine -ec '
      caddy run --config /etc/caddy/Caddyfile > /tmp/caddy.log 2>&1 &
      caddy_pid=$!
      trap "kill $caddy_pid" EXIT
      for attempt in $(seq 1 30); do
        if result=$(wget --no-check-certificate -qO- \
          --header="X-Forwarded-For: 1.2.3.4, 198.51.100.25" \
          https://127.0.0.1/ 2>/dev/null); then
          printf "%s\n" "$result"
          exit 0
        fi
        sleep 0.1
      done
      cat /tmp/caddy.log
      exit 1
    '
}

@test "Caddy discards forged forwarded addresses from an untrusted caller" {
  run proxy_request ''
  [ "$status" -eq 0 ]
  [ "$output" = 'xff=127.0.0.1;client=127.0.0.1;proto=https' ]
}

@test "Caddy preserves a trusted chain and resolves it from the right over HTTPS" {
  run proxy_request '127.0.0.1/32'
  [ "$status" -eq 0 ]
  [ "$output" = 'xff=1.2.3.4, 198.51.100.25, 127.0.0.1;client=198.51.100.25;proto=https' ]
}
