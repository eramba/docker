Welcome to eramba's official Github account, for Docker installs please review our website Learning Platform ([eramba.org](https://www.eramba.org/learning/courses/12/episodes/274)) under Docker Install.

The bundled files in `apache/ssl/` are a branded local development certificate intended only for local or simple demo installs. It is signed by a local development CA and will only be trusted on machines where that CA has been installed. Replace it with your own CA-issued certificate and private key for any real deployment.

Eramba and its MCP endpoint share the `PUBLIC_ADDRESS` origin. With the default configuration the application is available at `https://localhost:8443` and MCP at `https://localhost:8443/mcp`; issuer, resource, metadata, and OpenAPI URLs are derived automatically. Do not add separate public MCP URL variables.

Before starting a real deployment, replace `OAUTH2_INTROSPECTION_CLIENT_SECRET` in `.env` with a unique random secret. `ERAMBA_MCP_IMAGE_TAG` defaults to the latest MCP image and can be pinned when required.

## Client IP addresses behind reverse proxies

Use an Eramba image containing [the Apache client-IP fix](https://github.com/eramba/eramba/pull/6276) (3.31.1 or later) before enabling these settings. Both Community and Enterprise installations use the same configuration; the Enterprise Compose file inherits it.

The bundled request path is `client -> public_proxy (Caddy) -> eramba (Apache)`. If you have another reverse proxy or load balancer, it sits in front of `public_proxy`.

Two optional `.env` settings control separate trust boundaries:

| Setting | Format | Proxies to include |
| --- | --- | --- |
| `TRUSTED_PROXIES` | Comma-separated IP addresses or CIDRs | The address of `public_proxy` on `app_internal`, plus any trusted proxy hops preserved in `X-Forwarded-For` |
| `CADDY_TRUSTED_PROXIES` | Space-separated IP addresses or CIDRs | Only your reverse proxies/load balancers in front of `public_proxy`, using their source addresses as seen by Caddy |

Both settings default to empty. Apache then keeps its previous behavior and Caddy ignores incoming forwarded headers. These settings describe **incoming reverse proxies**; `USE_PROXY` / `PROXY_HOST` configure outgoing connections and are unrelated. You do not need to add `TRUST_PROXY` for Apache's IP fix.

### Clients connecting directly to the bundled Caddy

Find Caddy's current address on the internal application network:

```sh
docker inspect public_proxy --format '{{range $name, $network := .NetworkSettings.Networks}}{{println $name $network.IPAddress}}{{end}}'
```

Use the address on the network whose name ends in `app_internal`. For example, if that address is `172.30.50.10`:

```dotenv
TRUSTED_PROXIES=172.30.50.10
CADDY_TRUSTED_PROXIES=
```

The address above is an example, not a default. Docker may assign a different address when containers or networks are recreated. Reserve a stable address using a local Compose override, or recheck it after recreation and update the setting. Prefer an exact proxy address to trusting every container on a shared network.

### An additional reverse proxy or load balancer

If your trusted external proxy connects to Caddy from `10.0.0.5` and Caddy's internal address is `172.30.50.10`:

```dotenv
TRUSTED_PROXIES=172.30.50.10,10.0.0.5
CADDY_TRUSTED_PROXIES="10.0.0.5/32"
```

For multiple external proxies, include their IPs/CIDRs in both lists, using each setting's separator. Your proxy must append or overwrite `X-Forwarded-For` with the actual connecting client address. Caddy reads trusted chains from right to left; Apache resolves the remaining trusted hops and replaces `X-Forwarded-For` with the resolved client IP before PHP handles the request.

Only trust infrastructure you control. Do not use a catch-all range such as `0.0.0.0/0` or `::/0`, or trust every private network. Anyone able to connect from a trusted address can influence forwarded client information. If Docker/NAT hides the original client's address, trusting a header does not recover it: an upstream proxy must supply it correctly.

### Apply and verify

After updating `.env`, recreate the two services so the new environment reaches them. A plain `docker compose restart` does not apply changed environment variables.

Community:

```sh
docker compose -f docker-compose.simple-install.yml up -d --no-deps --force-recreate eramba public_proxy
```

Enterprise:

```sh
docker compose -f docker-compose.simple-install.yml -f docker-compose.simple-install.enterprise.yml up -d --no-deps --force-recreate eramba public_proxy
```

Check Apache's generated configuration and syntax:

```sh
docker compose -f docker-compose.simple-install.yml exec eramba cat /etc/apache2/conf-enabled/remoteip.conf
docker compose -f docker-compose.simple-install.yml exec eramba apachectl -t
```

With `TRUSTED_PROXIES` set, the file should contain the configured `RemoteIPInternalProxy` entries and the `X-Forwarded-For` rewrite. With an empty setting it should be empty. After recreating Caddy, recheck its internal address if you have not reserved one.

Log in and check that the Eramba access log and User Audit Trail show your client IP. Repeat a request through the same public endpoint with a forged header, for example `curl -k -H 'X-Forwarded-For: 1.2.3.4' https://your-eramba.example/`; the logged IP must remain the actual client address. Also check that login redirects remain HTTPS. The fix makes subsequent access logs, audit events, and session updates use the resolved client IP; it does not rewrite historical records or add an IP field to the User Bans screen.
