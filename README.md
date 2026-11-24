Welcome to eramba's official Github account, for Docker installs please review our website Learning Platform ([eramba.org](https://www.eramba.org/learning/courses/12/episodes/274)) under Docker Install.

The bundled files in `apache/ssl/` are a branded local development certificate intended only for local or simple demo installs. It is signed by a local development CA and will only be trusted on machines where that CA has been installed. Replace it with your own CA-issued certificate and private key for any real deployment.

Eramba and its MCP endpoint share the `PUBLIC_ADDRESS` origin. With the default configuration the application is available at `https://localhost:8443` and MCP at `https://localhost:8443/mcp`; issuer, resource, metadata, and OpenAPI URLs are derived automatically. Do not add separate public MCP URL variables.

Before starting a real deployment, replace `OAUTH2_INTROSPECTION_CLIENT_SECRET` in `.env` with a unique random secret. `ERAMBA_MCP_IMAGE_TAG` defaults to the latest MCP image and can be pinned when required.

## Client IP addresses behind reverse proxies

This configuration requires an Eramba image containing [the Apache client-IP fix](https://github.com/eramba/eramba/pull/6276) (3.31.1 or later). Both Community and Enterprise installations use the same configuration; the Enterprise Compose file inherits it.

The bundled request path is `client -> public_proxy (Caddy) -> eramba (Apache)`. **A fresh standard installation needs no proxy configuration:** Caddy has a reserved internal address and Apache automatically trusts that address. Caddy ignores incoming forwarded headers from untrusted clients.

### Select your Compose files

Run commands from the repository root in the same shell. Select the files for your edition once so subsequent commands use the same configuration.

Community:

```sh
export COMPOSE_FILE=docker-compose.simple-install.yml
```

Enterprise:

```sh
export COMPOSE_FILE=docker-compose.simple-install.yml:docker-compose.simple-install.enterprise.yml
```

### Default network and custom addresses

| `.env` setting | Default | Purpose |
| --- | --- | --- |
| `APP_INTERNAL_SUBNET` | `172.30.50.0/24` | Internal application subnet |
| `APP_INTERNAL_IP_RANGE` | `172.30.50.128/25` | Dynamic address pool for other containers |
| `PUBLIC_PROXY_IP` | `172.30.50.10` | Reserved Caddy address, also used by Apache's default trust list |

The reserved Caddy address is outside the dynamic pool, so it stays available across container recreation. Caddy retains its `host_access` connection and `app_internal` remains internal. Apache trusts Caddy's exact address, not every container on the network.

If the default subnet overlaps your host, LAN, VPN or another Docker network, choose a free subnet and update **all three** values in `.env` together. For example:

```dotenv
APP_INTERNAL_SUBNET=172.30.60.0/24
APP_INTERNAL_IP_RANGE=172.30.60.128/25
PUBLIC_PROXY_IP=172.30.60.10
TRUSTED_PROXIES=
CADDY_TRUSTED_PROXIES=
```

Keep the dynamic pool inside the subnet and the Caddy address inside the subnet but outside that pool. An empty or missing `TRUSTED_PROXIES` automatically follows `PUBLIC_PROXY_IP`; no address discovery or extra Compose file is needed. If you already set a nonempty `TRUSTED_PROXIES`, update that list to include the new Caddy address.

Check the effective configuration before starting or recreating the stack:

```sh
docker compose config --quiet
```

### Upgrading an existing installation

The application network now has explicit IPAM settings. An installation using Docker-assigned addresses must recreate that network once, which causes a brief outage. Choose a maintenance window and check for subnet conflicts first. Keep using the same Compose project and edition files as the existing installation, so its data volumes are reused.

If you previously added the README's `docker-compose.proxy-ip.yml` override, move its subnet, dynamic pool and Caddy address into the three `.env` settings above. Remove that override from `COMPOSE_FILE` only after migrating its other customizations, if any. Do not combine an old IPAM override with the new defaults: Compose may merge both subnet definitions. Any retained custom override must agree with the effective Caddy address and Apache trust list.

With the intended configuration selected, recreate the network and services:

```sh
docker compose down
docker compose up -d
```

**Do not add `--volumes` to `down`**; retain the database and application data volumes. If startup reports an overlapping address pool, select a free subnet in `.env`, update all three network values and retry. Future changes to these network values also require network recreation. Caddy's address remains stable across ordinary container recreation.

Older `.env` files without the new settings use the same defaults. An existing empty `TRUSTED_PROXIES=` now selects Caddy automatically; it no longer disables Apache's client-IP resolution.

### An additional reverse proxy or load balancer

These settings describe separate trust boundaries:

| Setting | Format | Proxies to include |
| --- | --- | --- |
| `TRUSTED_PROXIES` | Comma-separated IP addresses or CIDRs | Empty/unset uses `PUBLIC_PROXY_IP`; a nonempty list replaces that default and must include Caddy plus trusted proxy hops preserved in `X-Forwarded-For` |
| `CADDY_TRUSTED_PROXIES` | Space-separated IP addresses or CIDRs | Only reverse proxies/load balancers in front of Caddy, using their source addresses as seen by Caddy; empty/unset trusts none |

For a trusted external proxy connecting to Caddy from `10.0.0.5`, with the default Caddy address:

```dotenv
TRUSTED_PROXIES=172.30.50.10,10.0.0.5
CADDY_TRUSTED_PROXIES="10.0.0.5/32"
```

For multiple external proxies, include their IPs/CIDRs in both lists, using each setting's separator. Your proxy must append or overwrite `X-Forwarded-For` with the actual connecting client address. Caddy reads trusted chains from right to left; Apache resolves the remaining trusted hops and replaces `X-Forwarded-For` with the resolved client IP before PHP handles the request.

Only trust infrastructure you control. Do not use a catch-all range such as `0.0.0.0/0` or `::/0`, or trust every private network. Anyone able to connect from a trusted address can influence forwarded client information. If Docker/NAT hides the original client's address, trusting a header does not recover it: an upstream proxy must supply it correctly.

`USE_PROXY` / `PROXY_HOST` configure outgoing connections and are unrelated. You do not need to add `TRUST_PROXY` for Apache's IP fix.

### Apply trust changes and verify

A plain `docker compose restart` does not apply changed environment variables. After saving `.env`, recreate only the affected service(s):

```sh
# When CADDY_TRUSTED_PROXIES changes:
docker compose up -d --no-deps --force-recreate public_proxy
# When TRUSTED_PROXIES changes:
docker compose up -d --no-deps --force-recreate eramba
```

If both settings change, run both commands in that order. With the reserved address, recreating Caddy does not require inspecting its IP or updating Apache. For network changes or the first upgrade from dynamic addressing, use the network recreation procedure above instead.

Check Apache's generated configuration and syntax:

```sh
docker compose exec eramba cat /etc/apache2/conf-enabled/remoteip.conf
docker compose exec eramba apachectl -t
```

By default the file should contain `RemoteIPInternalProxy 172.30.50.10` and the `X-Forwarded-For` rewrite. With custom settings it should contain the effective proxy list.

Log in and check that the Eramba access log and User Audit Trail show your client IP. Repeat a request through the same public endpoint with a forged header, for example `curl -k -H 'X-Forwarded-For: 1.2.3.4' https://your-eramba.example/`; the logged IP must remain the actual client address. Also check that login redirects remain HTTPS. The fix applies to subsequent access logs, audit events and session updates; it does not rewrite historical records or add an IP field to the User Bans screen.

### Deliberately disable Apache client-IP resolution

For a custom deployment that needs the previous Apache behavior, use a local Compose override rather than an empty `.env` value. Create `docker-compose.no-proxy-trust.yml`:

```yaml
services:
  eramba:
    environment:
      TRUSTED_PROXIES: ""
```

Append it after your edition's files:

```sh
export COMPOSE_FILE="$COMPOSE_FILE:docker-compose.no-proxy-trust.yml"
docker compose config --quiet
docker compose up -d --no-deps --force-recreate eramba
```

Apache's generated `remoteip.conf` should then be empty. Keep this override in `COMPOSE_FILE` for subsequent commands while you want that behavior.
