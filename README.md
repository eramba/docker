Welcome to eramba's official Github account, for Docker installs please review our website Learning Platform ([eramba.org](https://www.eramba.org/learning/courses/12/episodes/274)) under Docker Install.

The bundled files in `apache/ssl/` are a branded local development certificate intended only for local or simple demo installs. It is signed by a local development CA and will only be trusted on machines where that CA has been installed. Replace it with your own CA-issued certificate and private key for any real deployment.

## Rebuild the application image

`./rebuild-app` replaces the application image and `/var/www/eramba` code volume using the canonical image-switch plan returned by the running Eramba application. The running image must include `bin/cake image_switch_plan`. Installations older than that baseline must follow the documented manual image-switch procedure once before using this command; there is no target-tag override.

Review the complete plan without changing `.env`, containers, or volumes:

```bash
./rebuild-app --dry-run
```

Run an interactive Community rebuild:

```bash
./rebuild-app
```

Enterprise archives must be downloaded manually before the rebuild:

```bash
./rebuild-app --edition enterprise \
  --image-file eramba-enterprise-<tag>-amd64.tar
```

Update a clean, attached Docker checkout with `git pull --ff-only` before preflight:

```bash
./rebuild-app --update-repo
```

For non-interactive execution, both the plan and a current recoverable backup must be confirmed explicitly:

```bash
./rebuild-app --yes --backup-confirmed
```

The command pulls the exact Community image or validates the exact image loaded from an Enterprise archive before downtime. During a normal rebuild, MySQL and Redis stay running. Only the twice-verified volume mounted at `/var/www/eramba` is removed; database, application data, logs, and trigger-storage volumes are preserved. Eramba completes its migration-aware startup and health checks before cron and triggers are started.

Failures before the first target `eramba` start restore the previous image tag and application services automatically. After that migration boundary, the command does not downgrade application code because database migrations may already have run. It keeps unverified dependent services stopped and writes private diagnostics under `.rebuild-app/runs/`; review those diagnostics and the database restore requirements before attempting recovery.
