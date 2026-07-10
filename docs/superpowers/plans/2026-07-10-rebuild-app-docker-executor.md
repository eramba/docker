# Rebuild App Docker Executor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe `./rebuild-app` host command that pins immutable application images and performs a phase-aware Community or Enterprise app-volume rebuild.

**Architecture:** A small Bash launcher delegates focused behavior to common, plan, and Docker/Compose libraries. All target selection and artifact checks happen before mutation; the script automatically recovers only before the first target `eramba` start and records diagnostics instead of downgrading after the migration boundary.

**Tech Stack:** Bash, Docker Engine, Docker Compose, Bats, existing Cake health commands, GitHub Actions.

## Global Constraints

- Work in `/Users/shrkz1/Sites/docker` on `codex/era-1706-rebuild-app`.
- Do not touch `/Users/shrkz1/Sites/eramba` in this implementation phase.
- The production plan provider is `bin/cake image_switch_plan`; until that command ships, real runs must fail during no-downtime preflight.
- Never run `docker compose down --volumes`, `docker system prune`, wildcard volume deletion, or automatic post-migration rollback.
- Delete only the Docker volume mounted at `/var/www/eramba` after verifying it twice.
- Keep MySQL and Redis running during the normal switch.
- Do not log, source, archive, or copy `.env` outside the atomic same-directory replacement operation.
- `--yes` never implies `--backup-confirmed`.
- Community accepts registry delivery only; Enterprise requires `--image-file` and archive delivery.
- Use explicit immutable tags for both `eramba` and `cron`.

---

## File Map

- `rebuild-app`: public CLI, option validation, phase transitions, and top-level traps.
- `lib/rebuild-app/common.sh`: logging, errors, lock, repo update, run metadata, and atomic `.env` tag update.
- `lib/rebuild-app/plan.sh`: invokes and validates the application JSON plan using PHP inside the running container.
- `lib/rebuild-app/docker.sh`: Compose selection, artifact validation, volume discovery, staged service control, and health checks.
- `tests/test_helper.bash`: isolated fake-command environment and common assertions.
- `tests/rebuild-app-options.bats`: CLI, repo-update, no-op, and confirmation behavior.
- `tests/rebuild-app-plan.bats`: plan parsing and target artifact validation.
- `tests/rebuild-app-lifecycle.bats`: exact volume deletion, recovery boundary, staged startup, and diagnostics.
- `docker-compose.simple-install.yml`: Community tag interpolation.
- `docker-compose.simple-install.enterprise.yml`: Enterprise tag interpolation.
- `.gitignore`: ignores runtime `.rebuild-app/` state.
- `.github/workflows/Docker.yml`: runs Bats and a non-destructive compose-config assertion before the existing install job.
- `README.md`: documents supported baseline, Community and Enterprise usage, dry-run, backup gate, and failure behavior.

## Task 1: Pin application images and establish the tested CLI

**Files:**
- Modify: `docker-compose.simple-install.yml`
- Modify: `docker-compose.simple-install.enterprise.yml`
- Create: `rebuild-app`
- Create: `lib/rebuild-app/common.sh`
- Create: `tests/test_helper.bash`
- Create: `tests/rebuild-app-options.bats`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `./rebuild-app [--edition community|enterprise] [--image-file PATH] [--update-repo] [--dry-run] [--yes] [--backup-confirmed]`.
- Produces: `ERAMBA_IMAGE_TAG` interpolation shared by `eramba` and `cron`.
- Produces common functions: `log`, `die`, `acquire_lock`, `release_lock`, `atomic_set_env`, `update_repo_and_reexec`.

- [ ] **Step 1: Prepare RED by reading compose and stating the production change**

Read both compose files and `.gitignore`. State: “Pin `eramba` and `cron` through one `.env` tag and add a no-mutation CLI skeleton whose invalid combinations are executable specifications.” Do not edit production files yet.

- [ ] **Step 2: Create the Bats helper and failing option tests**

`tests/test_helper.bash` creates a temporary copy of `.env`, prepends `tests/fakes/bin` to `PATH`, exports `REBUILD_APP_ROOT`, and removes temporary state in teardown. The option tests execute the real `rebuild-app` and assert:

```bash
@test "community rejects an image archive" {
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --image-file target.tar --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--image-file is only valid for enterprise"* ]]
}

@test "enterprise requires an image archive" {
  run "$REBUILD_APP_ROOT/rebuild-app" --edition enterprise --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--image-file is required for enterprise"* ]]
}

@test "non-interactive mutation requires backup confirmation" {
  run "$REBUILD_APP_ROOT/rebuild-app" --edition community --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"--backup-confirmed is required with --yes"* ]]
}
```

- [ ] **Step 3: Run Bats and confirm valid RED**

```bash
bats tests/rebuild-app-options.bats
```

Expected: FAIL because `rebuild-app` does not exist.

- [ ] **Step 4: Implement compose interpolation and the CLI skeleton**

Use these exact image declarations:

```yaml
image: ghcr.io/eramba/eramba:${ERAMBA_IMAGE_TAG:-latest}
```

```yaml
image: ghcr.io/eramba/eramba-enterprise:${ERAMBA_IMAGE_TAG:-latest}
```

Apply each declaration to both `eramba` and `cron` in the relevant compose result.

Create `rebuild-app` with `#!/usr/bin/env bash`, `set -Eeuo pipefail`, root-relative library loading, explicit defaults, a `while (($#)); do case "$1" ...` parser, and the validations represented by the tests. Unknown options call `die`. Export parsed values using names `EDITION`, `IMAGE_FILE`, `UPDATE_REPO`, `DRY_RUN`, `ASSUME_YES`, and `BACKUP_CONFIRMED`.

Create `common.sh` with these stable interfaces:

```bash
log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

acquire_lock() {
  LOCK_DIR="${ROOT_DIR}/.rebuild-app/lock"
  mkdir -p "${ROOT_DIR}/.rebuild-app"
  mkdir "$LOCK_DIR" 2>/dev/null || die "Another rebuild-app process is running."
}

release_lock() {
  [[ -n "${LOCK_DIR:-}" ]] && rmdir "$LOCK_DIR" 2>/dev/null || true
}
```

Add `.rebuild-app/` to `.gitignore` and make `rebuild-app` executable.

- [ ] **Step 5: Confirm GREEN and compose parity**

```bash
bats tests/rebuild-app-options.bats
ERAMBA_IMAGE_TAG=3.30.1-6 docker compose -f docker-compose.simple-install.yml config --images
ERAMBA_IMAGE_TAG=3.30.1-6 docker compose -f docker-compose.simple-install.yml \
  -f docker-compose.simple-install.enterprise.yml config --images
```

Expected: Bats PASS; Community lists `ghcr.io/eramba/eramba:3.30.1-6` twice and Enterprise lists `ghcr.io/eramba/eramba-enterprise:3.30.1-6` twice.

- [ ] **Step 6: Commit the image and CLI boundary**

```bash
git add .gitignore docker-compose.simple-install.yml \
  docker-compose.simple-install.enterprise.yml rebuild-app \
  lib/rebuild-app/common.sh tests/test_helper.bash tests/rebuild-app-options.bats
git commit -m "feat: pin rebuild app image tags"
```

## Task 2: Resolve and validate the canonical target before downtime

**Files:**
- Modify: `rebuild-app`
- Create: `lib/rebuild-app/plan.sh`
- Create: `lib/rebuild-app/docker.sh`
- Create: `tests/rebuild-app-plan.bats`

**Interfaces:**
- Produces globals: `CURRENT_IMAGE`, `CURRENT_IMAGE_TAG`, `CURRENT_APP_VERSION`, `TARGET_IMAGE_TAG`, `TARGET_APP_VERSION`, `TARGET_IMAGE`, `PLAN_REQUIRED`, `DISTRIBUTION`.
- Produces: `resolve_plan`, `acquire_target_image`, `validate_target_image`, `compose`, `detect_installation`.
- Consumes: one JSON object from `bin/cake image_switch_plan --current-image-tag TAG --format json`.

- [ ] **Step 1: State the production change and add failing plan tests**

State: “Discover the current deployment, request one canonical plan, and validate the complete target artifact before any `.env`, container, or volume mutation.”

Use fake `docker` and `docker compose` binaries to assert:

- a valid required Community plan yields exact target `ghcr.io/eramba/eramba:3.30.1-6`;
- `required:false` exits `0` with `nothing to do`;
- malformed JSON, missing fields, edition mismatch, distribution mismatch, wrong target `VERSION`, wrong repository/tag, or wrong architecture exits before any fake `stop`, `rm`, or `volume rm` call;
- Enterprise calls `docker load --input <path>` and Community calls `docker pull <exact-image>`.

The valid fixture is:

```json
{"required":true,"source_app_version":"3.30.0","target_app_version":"3.30.1","current_image_tag":"3.30.0-23","target_image_tag":"3.30.1-6","edition":"community","distribution":"registry"}
```

- [ ] **Step 2: Run the plan tests and confirm RED**

```bash
bats tests/rebuild-app-plan.bats
```

Expected: FAIL because plan and Docker libraries are absent.

- [ ] **Step 3: Implement compose and installation discovery**

In `docker.sh`, define `COMPOSE_ARGS` from the edition and a wrapper:

```bash
compose() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}
```

`detect_installation()` must inspect the running `eramba` container's configured image, parse only `ghcr.io/eramba/eramba:<tag>` or `ghcr.io/eramba/eramba-enterprise:<tag>`, set edition when not supplied, reject conflicts, and read `/var/www/eramba/app/upgrade/VERSION` with `docker exec`. A missing running container is a hard preflight failure.

- [ ] **Step 4: Implement strict JSON extraction without a host parser**

`resolve_plan()` runs the Cake command inside `eramba`, stores stdout, and extracts fields by piping JSON into PHP inside the same container:

```bash
plan_field() {
  local field=$1
  printf '%s' "$PLAN_JSON" | docker exec -i eramba php -r '
    $data = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
    $field = $argv[1];
    if (!array_key_exists($field, $data) || (!is_string($data[$field]) && !is_bool($data[$field]))) {
        exit(2);
    }
    echo is_bool($data[$field]) ? ($data[$field] ? "true" : "false") : $data[$field];
  ' "$field"
}
```

Required plans validate all six strings plus `required`; no-op validates only `required:false`. The current tag returned by support must equal the detected current tag.

- [ ] **Step 5: Implement artifact acquisition and non-running inspection**

Community calls `docker pull "$TARGET_IMAGE"`. Enterprise calls `docker load --input "$IMAGE_FILE"` and then requires the exact tag locally. Compare `docker image inspect` architecture to `docker info` architecture after normalizing `x86_64|amd64` and `aarch64|arm64`.

Create a temporary container with its entrypoint replaced, copy `/var/www/eramba/app/upgrade/VERSION` to a `mktemp` file, and always remove both in a trap. Require the trimmed file value to equal `TARGET_APP_VERSION`.

- [ ] **Step 6: Confirm GREEN and preflight purity**

```bash
bats tests/rebuild-app-plan.bats
```

Expected: all plan cases PASS; fake command log contains no mutating service/volume call for every rejected plan.

- [ ] **Step 7: Commit target resolution**

```bash
git add rebuild-app lib/rebuild-app/plan.sh lib/rebuild-app/docker.sh \
  tests/rebuild-app-plan.bats
git commit -m "feat: validate canonical rebuild target"
```

## Task 3: Implement the exact volume and pre-migration recovery boundary

**Files:**
- Modify: `rebuild-app`
- Modify: `lib/rebuild-app/common.sh`
- Modify: `lib/rebuild-app/docker.sh`
- Create: `tests/rebuild-app-lifecycle.bats`

**Interfaces:**
- Produces phases: `preflight`, `mutating`, `migration-boundary`, `complete`.
- Produces: `volume_identity CONTAINER DESTINATION`, `atomic_set_env KEY VALUE`, `recover_before_migration`, `stop_application_services`, `remove_verified_app_volume`.

- [ ] **Step 1: Add failing lifecycle safety tests**

Tests assert exact command ordering:

1. snapshot mount identities;
2. write target tag;
3. stop/remove `triggers_caddy`, `cron`, `eramba` only;
4. re-read `/var/www/eramba` mount name;
5. remove exactly that volume;
6. never stop/remove MySQL or Redis.

Add failure fixtures before and after volume removal. Both must restore the prior tag and recreate original application services because the target `eramba` start has not yet been attempted. A changed second-read volume name must abort without `docker volume rm`.

- [ ] **Step 2: Run lifecycle tests and confirm RED**

```bash
bats tests/rebuild-app-lifecycle.bats --filter 'pre-migration|volume|mysql|redis'
```

Expected: FAIL because mutation/recovery functions do not exist.

- [ ] **Step 3: Implement atomic `.env` mutation**

`atomic_set_env ERAMBA_IMAGE_TAG "$TARGET_IMAGE_TAG"` must reject more than one exact key, write to a same-directory `mktemp`, preserve the original numeric mode, replace or append one line with `awk`, and `mv` atomically. It must register the previous presence/value in memory without logging other `.env` content. A paired `restore_image_tag` restores only that key.

- [ ] **Step 4: Implement exact volume identity checks**

`volume_identity()` uses `docker inspect` Mounts to return `Name|CreatedAt` for one exact destination. Snapshot these destinations:

- `eramba:/var/www/eramba`
- `eramba:/var/www/eramba/app/upgrade/data`
- `eramba:/var/www/eramba/app/upgrade/logs`
- `mysql:/var/lib/mysql`
- `triggers_caddy:/data/eramba_trigger_storage`

Before deletion, re-read the application volume name and require it to match the snapshot. Invoke `docker volume rm -- "$APP_VOLUME_NAME"` with one argument only.

- [ ] **Step 5: Implement pre-boundary recovery and confirm GREEN**

Set `PHASE=mutating` immediately before `.env` mutation. The EXIT/ERR trap calls `recover_before_migration` only while this phase is active. Recovery restores the previous tag and runs Compose `up -d eramba cron triggers_caddy`; it reports recovery success/failure but preserves the original non-zero exit.

Run:

```bash
bats tests/rebuild-app-lifecycle.bats --filter 'pre-migration|volume|mysql|redis'
```

Expected: PASS.

- [ ] **Step 6: Commit the reversible mutation phase**

```bash
git add rebuild-app lib/rebuild-app/common.sh lib/rebuild-app/docker.sh \
  tests/rebuild-app-lifecycle.bats
git commit -m "feat: protect rebuild app volumes"
```

## Task 4: Add staged startup and post-boundary diagnostics

**Files:**
- Modify: `rebuild-app`
- Modify: `lib/rebuild-app/common.sh`
- Modify: `lib/rebuild-app/docker.sh`
- Modify: `tests/rebuild-app-lifecycle.bats`

**Interfaces:**
- Produces: `start_and_verify_eramba`, `start_and_verify_cron`, `start_and_verify_triggers`, `capture_diagnostics`.
- Consumes existing commands: `current_config validate`, `system_health check`, `migrations status`, and trigger health.

- [ ] **Step 1: Add failing staged-start and boundary tests**

Assert that target startup order is exactly:

1. `compose up -d eramba`;
2. application-local HTTP wait with finite timeout;
3. target application `VERSION`, `current_config validate`, `system_health check`;
4. `compose up -d cron` then `migrations status` in cron;
5. `compose up -d triggers_caddy` then healthy status.

Inject failure after the first target `up -d eramba`. Assert that the old tag is not restored, old services are not started, MySQL/Redis remain untouched, and diagnostics include the phase, old/target image refs, volume identities, compose state, and service logs without `.env` content.

- [ ] **Step 2: Run staged lifecycle tests and confirm RED**

```bash
bats tests/rebuild-app-lifecycle.bats --filter 'staged|migration boundary|diagnostics'
```

Expected: FAIL because staged startup and diagnostics are absent.

- [ ] **Step 3: Implement the conservative boundary**

Set `PHASE=migration-boundary` immediately before invoking `compose up -d eramba`. The error trap must never call `restore_image_tag` or `recover_before_migration` in this or later phases.

Use bounded polling with configurable `REBUILD_APP_START_TIMEOUT_SECONDS`, default `300`, and two-second intervals. Run checks through `docker exec -w /var/www/eramba/app/upgrade -u www-data`.

- [ ] **Step 4: Implement non-secret diagnostics**

Create `.rebuild-app/runs/<UTC timestamp>/` at mode `0700`; files use `0600`. Store a generated state summary, `docker compose ps`, `docker inspect` for service/image/mount metadata, and bounded `docker logs --tail 500` output. Never call `docker compose config` after failure because it can render resolved secret environment values.

- [ ] **Step 5: Confirm GREEN and full shell coverage**

```bash
bats tests/rebuild-app-lifecycle.bats
bats tests/rebuild-app-options.bats tests/rebuild-app-plan.bats
bash -n rebuild-app lib/rebuild-app/common.sh lib/rebuild-app/plan.sh lib/rebuild-app/docker.sh
```

Expected: all tests PASS and Bash syntax checks exit `0`.

- [ ] **Step 6: Commit staged startup and diagnostics**

```bash
git add rebuild-app lib/rebuild-app/common.sh lib/rebuild-app/docker.sh \
  tests/rebuild-app-lifecycle.bats
git commit -m "feat: stage rebuild app startup"
```

## Task 5: CI, documentation, and integration readiness

**Files:**
- Modify: `.github/workflows/Docker.yml`
- Modify: `README.md`
- Modify only if verification finds defects: executor/test files from Tasks 1-4.

**Interfaces:**
- Produces CI gate for shell tests and compose interpolation.
- Documents the baseline requirement and the absence of an unsafe target override.

- [ ] **Step 1: Add a CI shell-test job before the install job**

Add `shell_tests` on Ubuntu 22.04 that checks out the repo, installs `bats`, runs all three Bats files, runs `bash -n`, and asserts Community/Enterprise images under `ERAMBA_IMAGE_TAG=3.30.1-6`. Make `simple_install` depend on `shell_tests`.

- [ ] **Step 2: Document exact operator workflows**

README sections must include:

```bash
./rebuild-app --dry-run
./rebuild-app
./rebuild-app --edition enterprise --image-file eramba-enterprise-<tag>-amd64.tar
./rebuild-app --update-repo
./rebuild-app --yes --backup-confirmed
```

State that pre-baseline images must use the documented manual procedure once, Enterprise download remains manual, MySQL/Redis stay running, only the app volume is replaced, and post-boundary recovery requires operator review.

- [ ] **Step 3: Run all local non-destructive verification**

```bash
bats tests/rebuild-app-options.bats tests/rebuild-app-plan.bats tests/rebuild-app-lifecycle.bats
bash -n rebuild-app lib/rebuild-app/common.sh lib/rebuild-app/plan.sh lib/rebuild-app/docker.sh
ERAMBA_IMAGE_TAG=3.30.1-6 docker compose -f docker-compose.simple-install.yml config >/dev/null
ERAMBA_IMAGE_TAG=3.30.1-6 docker compose -f docker-compose.simple-install.yml \
  -f docker-compose.simple-install.enterprise.yml config >/dev/null
git diff --check
```

Expected: all commands exit `0`.

- [ ] **Step 4: Run the published-image integration gate when the baseline exists**

After the support contract is deployed and a baseline image contains `image_switch_plan`, run the real switch fixture and assert unchanged identities for `db-data`, `data`, `logs`, and trigger storage; a changed app-volume identity; target tag/version; successful application/cron/trigger health; and a second-run no-op.

Until the baseline exists, mark this release gate as blocked rather than adding a target override or bypass to production code.

- [ ] **Step 5: Commit CI and operator documentation**

```bash
git add .github/workflows/Docker.yml README.md
git commit -m "docs: add rebuild app operator workflow"
```

## Plan Completion Gate

- Both compose variants pin `eramba` and `cron` to one persisted immutable tag.
- Every mutating behavior has a Bats test that was observed RED before implementation.
- Invalid/missing plans and artifacts fail before downtime.
- Only the verified `/var/www/eramba` volume is removed.
- MySQL and Redis are never intentionally stopped during a normal switch.
- Pre-boundary failures restore the previous tag/services; post-boundary failures never downgrade automatically.
- Diagnostics contain no `.env` data.
- All Bats, Bash syntax, compose config, and diff checks pass.
- Real integration remains gated on the separately released Eramba `image_switch_plan` baseline.
