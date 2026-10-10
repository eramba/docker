Welcome to eramba's official Github account, for Docker installs please review our website Learning Platform ([eramba.org](https://www.eramba.org/learning/courses/12/episodes/274)) under Docker Install.

The bundled files in `apache/ssl/` are a branded local development certificate intended only for local or simple demo installs. It is signed by a local development CA and will only be trusted on machines where that CA has been installed. Replace it with your own CA-issued certificate and private key for any real deployment.

Eramba and its MCP endpoint share the `PUBLIC_ADDRESS` origin. With the default configuration the application is available at `https://localhost:8443` and MCP at `https://localhost:8443/mcp`; issuer, resource, metadata, and OpenAPI URLs are derived automatically. Do not add separate public MCP URL variables.

Before starting a real deployment, replace `OAUTH2_INTROSPECTION_CLIENT_SECRET` in `.env` with a unique random secret. `ERAMBA_MCP_IMAGE_TAG` defaults to the latest MCP image and can be pinned when required.

Use the release's fixed image tag with the update helper:

```sh
./bin/eramba-update --image ghcr.io/eramba/eramba:VERSION
./bin/eramba-update --enterprise --image ghcr.io/eramba/eramba-enterprise:VERSION
./bin/eramba-update --load release.tar --image ghcr.io/eramba/eramba:VERSION
```

The helper keeps MySQL running while native jobs, their supported child processes and accepted HTTP requests finish. It holds a live target-image coordinator across client shutdown and replacement of only the Compose-owned `app` volume, then runs initialization and synchronous post-processing before starting the matching services. It retains `data`, `logs`, database and trigger volumes. The selected image is saved as `ERAMBA_IMAGE` in the selected dotenv file; dotenv is parsed by Compose, never executed by the helper. `jq` and Docker Compose with `--wait` are required.

`--project-name`, `--env-file`, repeatable `--compose-file` overrides and `--drain-timeout` select the installation and positive drain deadline (default 7200 seconds). `--no-pull` uses a previously loaded local image. The deadline does not kill jobs or grant permission to migrate. A timeout, lost coordinator, unknown retirement, or failed preparation retains closed admission and the coordinator container for diagnosis. Inspect its redacted state using `docker exec --user www-data CONTAINER /usr/local/bin/eramba-deployment status`; never delete the retained deployment state or retry through an ordinary startup migration.

For a new installation, use `--install` with a fixed image. This requires absent application/data/database volumes and starts MySQL first. Existing pre-bridge installs require the [controlled legacy bootstrap and recovery procedure](https://github.com/eramba/eramba/blob/3.x/docs/operations/safe-queue-updates.md): fence competing updates and future scheduling, let concrete legacy executions and callbacks finish, retire all DB clients, and establish MySQL quiescence before installing the bridge. The fresh-install flag cannot establish legacy retirement. Recovery and incompatible schema rollback require the same positive fencing and verified backup/restore procedure.

The application image and this Compose/helper release must ship together. The simple-install CI uses the fixed bridge-capable image in the `SAFE_UPDATE_TEST_IMAGE` repository variable. Configure it after publishing the matching application artifact; an old image without the outside-code bridge cannot pass these runtime checks.

The private callback listener on `8081` is available only on the internal Compose network and retains application authentication. It is never published by Caddy. Web startup verifies prepared code; the cron service continuously supervises one native `queue_worker run` worker and uses guarded periodic commands. The preparation service has no application-code-volume mount and no Docker socket.
