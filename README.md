Welcome to eramba's official Github account, for Docker installs please review our website Learning Platform ([eramba.org](https://www.eramba.org/learning/courses/12/episodes/274)) under Docker Install.

The bundled files in `apache/ssl/` are a branded local development certificate intended only for local or simple demo installs. It is signed by a local development CA and will only be trusted on machines where that CA has been installed. Replace it with your own CA-issued certificate and private key for any real deployment.

Eramba and its MCP endpoint share the `PUBLIC_ADDRESS` origin. With the default configuration the application is available at `https://localhost:8443` and MCP at `https://localhost:8443/mcp`; issuer, resource, metadata, and OpenAPI URLs are derived automatically. Do not add separate public MCP URL variables.

`ERAMBA_HOST_PORT` controls the HTTPS port published by Caddy on the Docker host and defaults to `8443`. When changing it, keep `PUBLIC_ADDRESS` aligned with the externally visible origin; the values may intentionally differ when a reverse proxy or load balancer maps a different public port. This changes only the Docker host mapping: Caddy and Eramba continue to use HTTPS port `443` internally, so `apache/ports.conf` and the Apache virtual host do not need to change.

Before starting a real deployment, replace `OAUTH2_INTROSPECTION_CLIENT_SECRET` in `.env` with a unique random secret. `ERAMBA_MCP_IMAGE_TAG` defaults to the latest MCP image and can be pinned when required.
