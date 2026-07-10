# Eramba Docker Rebuild App Design

**Issue:** ERA-1706

**Date:** 2026-07-10

**Status:** Approved design

## Summary

Add a safe host-side `./rebuild-app` command to the Eramba Docker repository. The command obtains one canonical image-switch plan from the existing support update system, validates the target image before downtime, replaces only the application code volume, starts the application before its dependent workers, and verifies the resulting deployment.

The workflow supports Community images pulled from GHCR and Enterprise images supplied as downloaded archives. It does not duplicate release-order rules in shell code, use mutable `latest` tags as deployment state, create database backups, or automatically roll back after a target container may have started database migrations.

## Goals

- Replace the documented manual image-switch sequence with one guided command.
- Prevent unsupported version jumps using the existing canonical release tree.
- Support application-version upgrades and Docker rebuilds that retain the same application version.
- Keep MySQL, Redis, user data, application data, logs, and trigger storage intact.
- Minimize downtime by acquiring and validating the target image before stopping application services.
- Produce deterministic diagnostics and recovery information on failure.
- Remain backward-compatible with existing application update clients.

## Non-goals

- Creating, retaining, or pruning database backups.
- Downloading authenticated Enterprise archives from the customer portal.
- Automatically rolling back after the target application container has started.
- Removing old Docker images.
- Updating Docker Engine, Docker Compose, or the host operating system.
- Supporting a fresh installation or reconstructing a deployment whose current `eramba` container is unavailable.

## Current Lifecycle

The current compose definition runs `eramba` and `cron` from mutable `latest` tags and mounts the same named `app` volume at `/var/www/eramba`. The documented image-switch procedure stops the stack, removes that volume, pulls a versioned image, retags it as `latest`, and starts the stack.

On the next `eramba` start, the image entrypoint populates the new application volume and runs `database initialize`. That command can apply structural, data, and plugin migrations before Apache starts. The safe rollback boundary is therefore the first start attempt of the target `eramba` container, not the completion of the health checks.

The support backend already resolves allowed application updates from its `releases` table. It follows mandatory-next-release links and production/development visibility rules and returns the ordered pending release tree from `/api/check-update`.

## Architecture

### 1. Canonical image-switch metadata

Extend the existing support `releases` record with a nullable `docker_image_tag` value. The value identifies the approved Docker artifact for that application release, for example `3.30.1-6`.

A release may receive a newer approved Docker tag without changing its application version. Updating `docker_image_tag` on the existing release therefore represents a runtime-only image switch without creating a fake application release.

The existing release type determines the image repository and delivery mechanism:

- `community`: `ghcr.io/eramba/eramba:<docker_image_tag>`, delivered through the registry.
- `enterprise`: `ghcr.io/eramba/eramba-enterprise:<docker_image_tag>`, delivered as a customer-supplied archive.

Expose the field in the existing release administration UI. Production image-switch plans may reference only production releases with non-empty Docker metadata.

### 2. Backward-compatible support API contract

Add an optional `dockerImageTag` string to the existing `/api/check-update` request. Existing clients that omit it retain the current response contract.

When `dockerImageTag` is present, add an `image_switch` object under `response`:

```json
{
  "image_switch": {
    "required": true,
    "source_app_version": "3.30.0",
    "target_app_version": "3.30.1",
    "current_image_tag": "3.30.0-23",
    "target_image_tag": "3.30.1-6",
    "edition": "community",
    "distribution": "registry"
  }
}
```

When the deployment is already on the approved artifact, return:

```json
{
  "image_switch": {
    "required": false
  }
}
```

The resolver selects exactly one target:

1. Resolve the current release using the existing application version and installation type.
2. If the current release has an approved `docker_image_tag` different from the reported tag, return a same-version image switch.
3. Otherwise resolve the first release in the existing allowed pending tree.
4. If that first pending release has Docker metadata, return it as the target.
5. If the required current or next release lacks Docker metadata, return a safe metadata-missing error. Never skip to a later release and never infer a target from semver or `latest`.

An incoming `latest` tag is considered different from the approved immutable tag. The first successful run pins the deployment; later runs become idempotent.

### 3. Read-only application plan command

Add a read-only Cake command:

```bash
bin/cake image_switch_plan --current-image-tag <tag> --format json
```

The command uses the application's existing support credentials and update client. It sends the current app, database, PHP, MySQL, and Docker image versions to `/api/check-update`, then emits only the normalized `image_switch` contract. It never prints support credentials or unrelated update package URLs.

The plan request must be fresh or cached by all request inputs, including `current-image-tag`. A response cached for another Docker tag must not be reused.

Exit codes:

- `0`: a valid plan was returned, including `required: false`.
- non-zero: authentication, connectivity, invalid response, missing metadata, or other plan resolution failure.

The Docker executor treats any non-zero result or malformed JSON as a hard preflight failure.

### 4. Docker compose image contract

Replace the mutable application image tags with a persisted interpolation value:

```yaml
image: ghcr.io/eramba/eramba:${ERAMBA_IMAGE_TAG:-latest}
```

The Enterprise overlay uses the same variable with the Enterprise repository. Both `eramba` and `cron` must resolve to the same repository and tag.

`ERAMBA_IMAGE_TAG` is stored in the installation's existing `.env`. The executor updates only this key using an atomic same-directory replacement, preserves file permissions, refuses duplicate definitions, and never logs or copies the rest of `.env`.

## User Interface

The primary interactive command is:

```bash
./rebuild-app
```

Supported options in the first release:

- `--edition community|enterprise`: override edition detection when needed.
- `--image-file <path>`: required for an Enterprise plan.
- `--update-repo`: update the Docker checkout before preflight.
- `--dry-run`: resolve and validate the complete plan without changing `.env`, containers, or volumes.
- `--yes`: accept the deployment plan in non-interactive execution.
- `--backup-confirmed`: explicitly confirm a current recoverable backup in non-interactive execution.

`--yes` does not imply `--backup-confirmed`. A non-interactive mutation requires both flags.

The executor auto-detects the edition from the current container image repository. If detection is impossible or conflicts with `--edition`, it exits before any mutation. Enterprise execution requires a readable archive path; Community execution rejects `--image-file`.

`--update-repo` is opt-in. It requires a clean checkout and performs only `git pull --ff-only` before Docker preflight. After a successful pull, the launcher re-executes the updated script with the original public arguments and an internal loop-prevention marker. Dirty, detached, or diverged checkouts fail without touching the deployment.

## Execution Flow

### Phase A: no-downtime preflight

1. Acquire a per-installation lock using an atomic lock directory.
2. Validate required commands, Docker daemon access, Docker Compose support, `.env`, and the resolved compose configuration.
3. Optionally perform the safe repository update and re-exec.
4. Require an existing running `eramba` container and identify:
   - edition and compose file set;
   - current image repository, tag, and image ID/digest;
   - current application version;
   - the exact volume mounted at `/var/www/eramba`;
   - the persistent volumes that must not change.
5. Run the current deployment checks:
   - application-local HTTP readiness;
   - `current_config validate`;
   - `system_health check`;
   - `migrations status`.
6. Request and validate the canonical image-switch plan.
7. Exit successfully with `nothing to do` when `required` is false.
8. Acquire the target artifact:
   - Community: pull the exact registry reference.
   - Enterprise: load the supplied archive and require the expected repository/tag to appear.
9. Create a temporary container from the target image without running its normal entrypoint. Read its application `VERSION`, then remove the temporary container.
10. Require the target image application version, repository, architecture, and tag to match the plan.
11. Print the current and target versions, image references, affected containers, exact removable volume, and preserved volumes.
12. Require explicit plan and backup confirmation. `--dry-run` exits successfully here.

No application container or volume changes occur during Phase A.

### Phase B: reversible pre-migration mutation

1. Record non-secret recovery metadata under `.rebuild-app/runs/<timestamp>/` with mode `0700` for the directory and `0600` for files.
2. Atomically write the target `ERAMBA_IMAGE_TAG` to `.env`.
3. Stop and remove `triggers_caddy`, `cron`, and `eramba` in that order. Keep MySQL and Redis running.
4. Re-resolve the recorded application volume and require it to match the preflight value.
5. Remove only that application volume.

If any failure occurs before the target `eramba` start is attempted, restore the previous image tag, recreate the original application services from the recorded image, and report whether recovery succeeded. The database has not been exposed to target migrations at this point.

### Phase C: migration boundary and staged startup

1. Start only `eramba` with the target tag. Compose may ensure its MySQL and Redis dependencies exist, but it must not start `cron` or `triggers_caddy` yet.
2. Once this start is attempted, mark the run as having crossed the migration boundary.
3. Wait with a finite timeout for the entrypoint and application-local HTTP endpoint.
4. Run `current_config validate`, `system_health check`, and the application version check.
5. Start `cron`, wait for it, and run `migrations status` from the cron container.
6. Start `triggers_caddy` and require its health check to pass.
7. Verify that the running `eramba` and `cron` containers use the planned repository and tag.
8. Verify that the preserved volume identities match the preflight snapshot and the application volume identity changed.
9. Write a successful run summary and release the lock.

## Failure Handling

Failures before Phase B do not cause downtime. Failures in Phase B attempt automatic pre-migration recovery.

After the target `eramba` start is attempted, the executor must not automatically start the old application image or restore the old tag. Target migrations may be partially or fully applied, and an automatic code downgrade could compound the failure.

For a post-boundary failure, the executor:

- leaves MySQL and Redis available;
- keeps `cron` and `triggers_caddy` stopped unless they already passed their staged startup checks;
- captures compose state and logs for `eramba`, `cron`, MySQL, and triggers without printing `.env`;
- records the old and target image references, image IDs, application versions, volume identities, failed step, and exit status;
- prints the diagnostics directory and a recovery summary that requires operator review and, when necessary, database restore.

Signals and unexpected exits release the lock. They use the same phase-aware recovery rule and never perform a post-boundary automatic rollback.

## Security and Data Safety

- Never invoke `docker compose down --volumes`, `docker system prune`, or wildcard volume deletion.
- Discover the removable application volume from the running container mount destination and verify it again immediately before deletion.
- Never print, copy, source into logs, or include `.env` values in diagnostics.
- Pass support credentials only through the existing application update client.
- Accept only the exact repository, immutable tag, application version, edition, and architecture returned by the plan.
- Do not accept a newer tag merely because it compares higher lexically or semantically.
- Require an explicit backup confirmation, while leaving backup implementation and retention to the existing documented process.

## Testing Strategy

### Support backend

Feature tests cover:

- an old Docker tag for the same application release;
- the first allowed next application release;
- mandatory-next-release routing;
- production versus development visibility;
- current approved tag producing `required: false`;
- `latest` producing an immutable target;
- missing current or next release Docker metadata;
- an old request without `dockerImageTag` retaining the existing response shape and download behavior;
- Community and Enterprise distribution values.

### Eramba application

Focused command and update-client tests cover:

- exact normalized JSON for a required switch and no-op;
- propagation of the current Docker tag into the request;
- cache separation or forced refresh by current tag;
- authentication, network, malformed-response, and metadata errors;
- non-zero failure exit codes;
- absence of credentials and package URLs from stdout and stderr.

### Docker executor

Bats tests use controlled `git`, `docker`, and `docker compose` fakes to cover:

- option validation and edition detection;
- safe repository update and re-exec;
- dirty, detached, and diverged repository failures;
- plan parsing, no-op, dry-run, and confirmation rules;
- Community pull and Enterprise load validation;
- target version, repository, tag, and architecture mismatch;
- exact volume discovery and deletion protection;
- every failure point before and after the migration boundary;
- atomic `.env` update and pre-boundary restoration;
- idempotent repeated execution.

The executor requires no host JSON parser. It may use PHP inside the running application container to validate and extract the plan during Phase A.

### Integrated release test

After the support contract and plan command are available in a published baseline image, CI performs a real Community switch from that supported baseline to the next approved production image. The test proves that:

- only the application volume identity changes;
- database, data, logs, and trigger-storage volume identities remain unchanged;
- MySQL and Redis remain available;
- `eramba` passes migrations and health checks before cron starts;
- `cron` passes `migrations status`;
- triggers become healthy;
- the final image tag and application version match the canonical plan;
- a repeated run returns `nothing to do`.

Enterprise uses the same orchestration tests with an archive-loaded fixture. A production-like Enterprise smoke test validates the real archive path before release.

## Rollout Order

1. Add and populate `docker_image_tag` for the supported current and next releases in the support backend, expose it in release administration, and deploy the backward-compatible API contract.
2. Add the Eramba `image_switch_plan` command and release the first baseline image that supports it.
3. Add the compose tag interpolation, executor, tests, and documentation to the Docker repository.
4. Run the integrated Community and Enterprise release tests.
5. Document that installations older than the baseline must use the existing manual procedure once to reach the baseline. No unsafe target override is included solely to bridge old versions.

## Acceptance Criteria

- One interactive `./rebuild-app` command completes a supported Community or Enterprise image switch.
- The target is selected exclusively by the canonical support release tree and Docker metadata.
- Same-version Docker rebuilds and next-version upgrades are both represented.
- The executor performs all artifact and health validation possible before downtime.
- MySQL and Redis stay running during a normal switch.
- Only the volume mounted at `/var/www/eramba` is deleted.
- `eramba` completes its migration-aware startup before cron and triggers start.
- No automatic rollback occurs after the target container start is attempted.
- Failures produce non-secret phase-aware diagnostics and recovery information.
- Existing update clients that omit `dockerImageTag` continue to work unchanged.
- Re-running the command on the approved tag is a safe no-op.
