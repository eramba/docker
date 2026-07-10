# Rebuild App Support Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing support release tree with a backward-compatible, canonical Docker image-switch plan.

**Architecture:** Store one approved immutable Docker tag on each legacy support release. When `check-update` receives the caller's current Docker tag, resolve either a same-version image rebuild or the first allowed pending application release and append an `image_switch` object without changing legacy responses for callers that omit the new field.

**Tech Stack:** Laravel 12, PHP 8.3, Eloquent, Nova 5, PHPUnit 11, support-database connection.

## Global Constraints

- Work in `/Users/shrkz1/Sites/licenses-backend`.
- Run PHP, Artisan, PHPUnit, and Pint inside the local `web` Docker service.
- Keep `/api/check-update` Basic-auth behavior and the existing legacy response envelope unchanged.
- Requests without `dockerImageTag` must receive the current response shape and package-download URL behavior.
- Production customer plans may reference only `production` releases.
- Never infer or compare Docker targets using semver, lexical ordering, GitHub `latest`, or registry discovery.
- A missing tag on the required release is a safe API failure; never skip to a later release.
- Do not expose registry credentials, support credentials, or Enterprise download URLs.

---

## File Map

- `database/migrations/2026_07_10_120000_add_docker_image_tag_to_support_releases_table.php`: adds the nullable support-database column.
- `app/Models/LegacySupport/SupportRelease.php`: makes the column writable and exposes typed distribution helpers.
- `app/Nova/LegacySupportRelease.php`: lets release administrators set the approved tag.
- `app/Services/LegacySupport/LegacySupportReleaseService.php`: resolves the one allowed image-switch target.
- `app/Services/LegacySupport/LegacySupportUpdateService.php`: normalizes `dockerImageTag` and passes it into release resolution.
- `tests/Feature/LegacySupportApiContractTest.php`: owns the support SQLite fixture and full API contract coverage.

## Task 1: Persist approved Docker image tags

**Files:**
- Create: `database/migrations/2026_07_10_120000_add_docker_image_tag_to_support_releases_table.php`
- Modify: `app/Models/LegacySupport/SupportRelease.php`
- Modify: `app/Nova/LegacySupportRelease.php`
- Modify: `tests/Feature/LegacySupportApiContractTest.php`

**Interfaces:**
- Produces: `SupportRelease::$docker_image_tag: ?string`
- Produces: `SupportRelease::dockerDistribution(): string`, returning `registry` for Community and `archive` for Enterprise.
- Consumes: existing `support.releases` rows and `type` values `community|enterprise`.

- [ ] **Step 1: Add a failing metadata persistence test**

Add the following test to `LegacySupportApiContractTest` and add `docker_image_tag` to its `createSupportSchema()` releases table and `insertSupportRelease()` defaults only after RED is confirmed:

```php
public function test_support_release_persists_approved_docker_image_tag(): void
{
    $releaseId = $this->insertSupportRelease([
        'type' => 'community',
        'docker_image_tag' => '3.30.1-6',
    ]);

    $release = \App\Models\LegacySupport\SupportRelease::query()->findOrFail($releaseId);

    $this->assertSame('3.30.1-6', $release->docker_image_tag);
    $this->assertSame('registry', $release->dockerDistribution());

    $release->type = 'enterprise';
    $this->assertSame('archive', $release->dockerDistribution());
}
```

- [ ] **Step 2: Run the narrow test and confirm valid RED**

Run:

```bash
docker compose -f docker-compose.yml -f docker-compose.web.yml run --rm web \
  php artisan test --compact tests/Feature/LegacySupportApiContractTest.php \
  --filter=test_support_release_persists_approved_docker_image_tag
```

Expected: FAIL because the test support schema/model does not yet define `docker_image_tag` or `dockerDistribution()`.

- [ ] **Step 3: Add the support-database migration**

Create the migration with this complete body:

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::connection('support')->table('releases', function (Blueprint $table): void {
            $table->string('docker_image_tag')->nullable()->after('version_pre_release');
        });
    }

    public function down(): void
    {
        Schema::connection('support')->table('releases', function (Blueprint $table): void {
            $table->dropColumn('docker_image_tag');
        });
    }
};
```

- [ ] **Step 4: Extend the model, Nova field, and test fixture**

Add `docker_image_tag` to `SupportRelease::$fillable` and add:

```php
public function dockerDistribution(): string
{
    return $this->type === 'community' ? 'registry' : 'archive';
}
```

Add this Nova field immediately after `Version`:

```php
Text::make('Docker Image Tag', 'docker_image_tag')
    ->rules('nullable', 'max:255')
    ->help('Approved immutable Docker tag, for example 3.30.1-6.')
    ->sortable(),
```

In `LegacySupportApiContractTest::createSupportSchema()`, add:

```php
$table->string('docker_image_tag')->nullable();
```

In `insertSupportRelease()` defaults, add:

```php
'docker_image_tag' => null,
```

- [ ] **Step 5: Run the narrow test and confirm GREEN**

Run the command from Step 2.

Expected: PASS.

- [ ] **Step 6: Format and commit the metadata boundary**

Run:

```bash
docker compose -f docker-compose.yml -f docker-compose.web.yml run --rm web \
  vendor/bin/pint --dirty --format agent
git add database/migrations/2026_07_10_120000_add_docker_image_tag_to_support_releases_table.php \
  app/Models/LegacySupport/SupportRelease.php \
  app/Nova/LegacySupportRelease.php \
  tests/Feature/LegacySupportApiContractTest.php
git commit -m "feat: store approved Docker release tags"
```

## Task 2: Resolve same-version image switches and no-op plans

**Files:**
- Modify: `app/Services/LegacySupport/LegacySupportReleaseService.php`
- Modify: `app/Services/LegacySupport/LegacySupportUpdateService.php`
- Modify: `tests/Feature/LegacySupportApiContractTest.php`

**Interfaces:**
- Consumes: `dockerImageTag: ?string` from the legacy request payload.
- Produces: `response.image_switch.required: bool` only when `dockerImageTag` was supplied.
- Produces when required: `source_app_version`, `target_app_version`, `current_image_tag`, `target_image_tag`, `edition`, and `distribution` strings.

- [ ] **Step 1: Add failing API tests for same-version switch and no-op**

Add two feature tests using a Community support stat and a `3.30.0` production release whose `docker_image_tag` is `3.30.0-23`:

```php
public function test_check_update_returns_same_version_image_switch_for_old_docker_tag(): void
{
    $this->insertSupportStat(['client_id' => 'app-1', 'type' => 'community']);
    $this->insertSupportRelease([
        'version' => '3.30.0',
        'version_major' => 3,
        'version_minor' => 30,
        'version_patch' => 0,
        'type' => 'community',
        'status' => 'production',
        'docker_image_tag' => '3.30.0-23',
    ]);

    $this->withBasicAuth('app-1', '')
        ->postJson('/api/check-update', [
            'appVersion' => '3.30.0',
            'dbVersion' => '20260710',
            'phpVersion' => '8.3.0',
            'dockerImageTag' => '3.30.0-22',
        ])
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('response.updates', false)
        ->assertJsonPath('response.image_switch.required', true)
        ->assertJsonPath('response.image_switch.source_app_version', '3.30.0')
        ->assertJsonPath('response.image_switch.target_app_version', '3.30.0')
        ->assertJsonPath('response.image_switch.current_image_tag', '3.30.0-22')
        ->assertJsonPath('response.image_switch.target_image_tag', '3.30.0-23')
        ->assertJsonPath('response.image_switch.edition', 'community')
        ->assertJsonPath('response.image_switch.distribution', 'registry');
}

public function test_check_update_returns_noop_for_approved_docker_tag(): void
{
    $this->insertSupportStat(['client_id' => 'app-1', 'type' => 'community']);
    $this->insertSupportRelease([
        'version' => '3.30.0',
        'version_major' => 3,
        'version_minor' => 30,
        'version_patch' => 0,
        'type' => 'community',
        'status' => 'production',
        'docker_image_tag' => '3.30.0-23',
    ]);

    $this->withBasicAuth('app-1', '')
        ->postJson('/api/check-update', [
            'appVersion' => '3.30.0',
            'dockerImageTag' => '3.30.0-23',
        ])
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertExactJson([
            'success' => true,
            'message' => null,
            'response' => [
                'updates' => false,
                'image_switch' => ['required' => false],
            ],
        ]);
}
```

- [ ] **Step 2: Run both tests and confirm RED**

Run:

```bash
docker compose -f docker-compose.yml -f docker-compose.web.yml run --rm web \
  php artisan test --compact tests/Feature/LegacySupportApiContractTest.php \
  --filter='test_check_update_returns_(same_version_image_switch|noop)'
```

Expected: FAIL because `image_switch` is absent.

- [ ] **Step 3: Pass the normalized request tag into release resolution**

Change the `LegacySupportUpdateService` call to:

```php
$resolved = $this->releaseService->checkForUpdates(
    $identity,
    $this->clean($payload['appVersion'] ?? null),
    $this->clean($payload['dbVersion'] ?? null),
    $this->clean($payload['phpVersion'] ?? null),
    $this->clean($payload['dockerImageTag'] ?? null),
);
```

Extend the release-service signature with `?string $dockerImageTag = null`.

- [ ] **Step 4: Implement the exact plan serializer**

Add this private method to `LegacySupportReleaseService`:

```php
private function imageSwitchPlan(
    SupportRelease $source,
    SupportRelease $target,
    string $currentImageTag,
): array {
    return [
        'required' => true,
        'source_app_version' => $source->version,
        'target_app_version' => $target->version,
        'current_image_tag' => $currentImageTag,
        'target_image_tag' => $target->docker_image_tag,
        'edition' => $target->type,
        'distribution' => $target->dockerDistribution(),
    ];
}
```

Build a response array before each previous early return. When `$dockerImageTag === null`, do not add `image_switch`. When it is present and differs from the current release metadata, attach `imageSwitchPlan($currentRelease, $currentRelease, $dockerImageTag)`. When it matches and there are no pending releases, attach `['required' => false]`.

- [ ] **Step 5: Run both tests and confirm GREEN**

Run the command from Step 2.

Expected: PASS.

- [ ] **Step 6: Commit the same-version contract**

```bash
git add app/Services/LegacySupport/LegacySupportReleaseService.php \
  app/Services/LegacySupport/LegacySupportUpdateService.php \
  tests/Feature/LegacySupportApiContractTest.php
git commit -m "feat: resolve Docker image switch plans"
```

## Task 3: Resolve next-release plans and fail closed

**Files:**
- Modify: `app/Services/LegacySupport/LegacySupportReleaseService.php`
- Modify: `tests/Feature/LegacySupportApiContractTest.php`

**Interfaces:**
- Consumes: the existing ordered pending release tree.
- Produces: one target only; the current release is preferred for a same-version rebuild, otherwise `pending[0]`.
- Produces: legacy failure envelope when required Docker metadata is missing.

- [ ] **Step 1: Add failing next-release and metadata tests**

Add coverage for:

```php
public function test_check_update_returns_first_allowed_pending_release_image(): void
{
    $this->insertSupportStat(['client_id' => 'app-1', 'type' => 'community']);
    $this->insertSupportRelease([
        'version' => '3.30.0',
        'version_major' => 3,
        'version_minor' => 30,
        'version_patch' => 0,
        'type' => 'community',
        'docker_image_tag' => '3.30.0-23',
    ]);
    $this->insertSupportRelease([
        'version' => '3.30.1',
        'version_major' => 3,
        'version_minor' => 30,
        'version_patch' => 1,
        'type' => 'community',
        'docker_image_tag' => '3.30.1-6',
    ]);

    $this->withBasicAuth('app-1', '')
        ->postJson('/api/check-update', [
            'appVersion' => '3.30.0',
            'dockerImageTag' => '3.30.0-23',
        ])
        ->assertOk()
        ->assertJsonPath('response.image_switch.target_app_version', '3.30.1')
        ->assertJsonPath('response.image_switch.target_image_tag', '3.30.1-6');
}

public function test_check_update_fails_when_required_release_has_no_docker_metadata(): void
{
    $this->insertSupportStat(['client_id' => 'app-1', 'type' => 'community']);
    $this->insertSupportRelease([
        'version' => '3.30.0',
        'version_major' => 3,
        'version_minor' => 30,
        'version_patch' => 0,
        'type' => 'community',
        'docker_image_tag' => null,
    ]);

    $this->withBasicAuth('app-1', '')
        ->postJson('/api/check-update', [
            'appVersion' => '3.30.0',
            'dockerImageTag' => 'latest',
        ])
        ->assertOk()
        ->assertJsonPath('success', false)
        ->assertJsonPath('message', 'Docker image metadata is not configured for release 3.30.0.');
}
```

Add `test_check_update_image_plan_honours_mandatory_next_release()`: create the mandatory target first, set its ID as `mandatory_next_update` on the current release, also create a normal patch candidate, and assert `target_image_tag` equals the mandatory target tag rather than the patch tag.

Add `test_check_update_image_plan_uses_archive_distribution_for_enterprise()`: authenticate an Enterprise customer, create current and next Enterprise production releases with Docker tags, send the approved current tag, and assert `response.image_switch.edition` is `enterprise` and `response.image_switch.distribution` is `archive`.

- [ ] **Step 2: Run the focused contract group and confirm RED**

Run:

```bash
docker compose -f docker-compose.yml -f docker-compose.web.yml run --rm web \
  php artisan test --compact tests/Feature/LegacySupportApiContractTest.php \
  --filter='test_check_update_.*docker|test_check_update_returns_first_allowed'
```

Expected: at least the next-release and missing-metadata assertions FAIL.

- [ ] **Step 3: Implement fail-closed target selection**

Import `LegacySupportException` and add:

```php
private function requireDockerMetadata(SupportRelease $release): void
{
    if ($release->docker_image_tag !== null && trim($release->docker_image_tag) !== '') {
        return;
    }

    throw new LegacySupportException(sprintf(
        'Docker image metadata is not configured for release %s.',
        $release->version,
    ));
}
```

After same-version resolution, select only `$pendingReleases[0]`, call `requireDockerMetadata()` on it, and return `imageSwitchPlan($currentRelease, $pendingReleases[0], $dockerImageTag)`. Do not scan later pending releases.

- [ ] **Step 4: Prove old clients are unchanged**

Run the existing download contract test without `dockerImageTag`:

```bash
docker compose -f docker-compose.yml -f docker-compose.web.yml run --rm web \
  php artisan test --compact tests/Feature/LegacySupportApiContractTest.php \
  --filter=test_check_update_returns_customer_safe_pending_release_with_download_url
```

Expected: PASS with no `response.image_switch` key and a valid first-release download URL.

- [ ] **Step 5: Run the full legacy support API contract and Pint**

```bash
docker compose -f docker-compose.yml -f docker-compose.web.yml run --rm web \
  php artisan test --compact tests/Feature/LegacySupportApiContractTest.php
docker compose -f docker-compose.yml -f docker-compose.web.yml run --rm web \
  vendor/bin/pint --dirty --format agent
```

Expected: all tests PASS; Pint exits `0`.

- [ ] **Step 6: Validate the migration against the configured support connection**

```bash
docker compose -f docker-compose.yml -f docker-compose.web.yml run --rm web \
  php artisan migrate:status --database=support --no-interaction
```

Expected: the new migration is listed as pending before deployment or completed in a migrated test environment; no connection or syntax error occurs.

- [ ] **Step 7: Commit the completed support contract**

```bash
git add app/Services/LegacySupport/LegacySupportReleaseService.php \
  tests/Feature/LegacySupportApiContractTest.php
git commit -m "test: cover Docker image switch release routing"
```

## Plan Completion Gate

- The migration, model, Nova field, resolver, and request normalization are committed.
- The full `LegacySupportApiContractTest` passes in the Docker web service.
- A request without `dockerImageTag` is byte-for-byte compatible at the JSON-structure level.
- Same-version, next-release, mandatory-release, Community, Enterprise, no-op, and missing-metadata cases are proven.
- `git diff --check` and `vendor/bin/pint --dirty --format agent` pass.
- Deploy this support contract and populate baseline `docker_image_tag` values before executing the Eramba application plan.
