# Rebuild App Application Plan Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only Cake command that securely returns the canonical Docker image-switch plan for the running Eramba installation.

**Architecture:** Extend `AutoUpdateLib` with an optional Docker tag input and a forced-refresh image-plan method while keeping all existing no-argument updater callers compatible. A focused Cake command validates its one required option and prints only normalized plan JSON for the host executor.

**Tech Stack:** PHP 8, CakePHP command framework, existing `AutoUpdateLib`, PHPUnit pure unit harness.

## Global Constraints

- Work in `/Users/shrkz1/Sites/eramba`.
- Read the relevant production and test files before RED and state the intended production change before applying it.
- Apply/save only the test change, run the narrow test for valid RED, then apply the stated production change and rerun for GREEN.
- Run application commands inside the `eramba` container; pure unit PHPUnit may use the documented host `composer cake-unit-test` path when dependencies are available.
- Preserve `AutoUpdateLib::check()` behavior for every existing no-argument caller.
- The image-plan lookup must not reuse a response cached for another Docker tag.
- Stdout on success contains one JSON object and no support credentials or package URL.
- Errors use a non-zero command exit code and stderr; they must not emit partial success JSON.

---

## File Map

- `app/upgrade/src/Lib/AutoUpdateLib.php`: adds request-tag propagation, forced refresh, and normalized plan extraction.
- `app/upgrade/src/Command/ImageSwitchPlanCommand.php`: owns CLI option validation and JSON output only.
- `app/upgrade/tests/Unit/Lib/AutoUpdateLibImageSwitchPlanTest.php`: proves request augmentation and plan normalization without Cake bootstrap.
- `app/upgrade/tests/Unit/Command/ImageSwitchPlanCommandTest.php`: proves stdout, stderr, and exit-code behavior with an injected client.

## Task 1: Add a cache-safe image-switch plan method

**Files:**
- Modify: `app/upgrade/src/Lib/AutoUpdateLib.php`
- Create: `app/upgrade/tests/Unit/Lib/AutoUpdateLibImageSwitchPlanTest.php`

**Interfaces:**
- Produces: `AutoUpdateLib::imageSwitchPlan(string $currentImageTag): array|false`.
- Preserves: `AutoUpdateLib::check(?string $dockerImageTag = null, bool $forceRefresh = false): array|false` with no-argument compatibility.
- Produces protected helper: `appendDockerImageTag(array $requestBody, ?string $dockerImageTag): array`.

- [ ] **Step 1: Read the narrow source and state the production change**

Read:

```bash
sed -n '1,380p' app/upgrade/src/Lib/AutoUpdateLib.php
```

State before editing production: “Extend the existing check request with an optional Docker tag, bypass the shared cache for image-plan calls, and normalize only `response.image_switch`.”

- [ ] **Step 2: Write the failing pure unit tests**

Create `AutoUpdateLibImageSwitchPlanTest.php` with tests using this test subclass:

```php
<?php

declare(strict_types=1);

namespace App\Test\Unit\Lib;

use App\Lib\AutoUpdateLib;
use PHPUnit\Framework\TestCase;

class AutoUpdateLibImageSwitchPlanTest extends TestCase
{
    public function testAppendDockerImageTagOmitsNullAndAddsConcreteTag(): void
    {
        $lib = new TestableAutoUpdateLib();
        $base = ['appVersion' => '3.30.0'];

        $this->assertSame($base, $lib->runAppendDockerImageTag($base, null));
        $this->assertSame(
            ['appVersion' => '3.30.0', 'dockerImageTag' => '3.30.0-23'],
            $lib->runAppendDockerImageTag($base, '3.30.0-23'),
        );
    }

    public function testImageSwitchPlanReturnsNormalizedPlan(): void
    {
        $lib = new TestableAutoUpdateLib([
            'success' => true,
            'response' => [
                'image_switch' => [
                    'required' => true,
                    'source_app_version' => '3.30.0',
                    'target_app_version' => '3.30.1',
                    'current_image_tag' => '3.30.0-23',
                    'target_image_tag' => '3.30.1-6',
                    'edition' => 'community',
                    'distribution' => 'registry',
                ],
                'pending' => [['url' => 'https://secret-package.example/update.zip']],
            ],
        ]);

        $plan = $lib->imageSwitchPlan('3.30.0-23');

        $this->assertIsArray($plan);
        $this->assertSame('3.30.1-6', $plan['target_image_tag']);
        $this->assertArrayNotHasKey('pending', $plan);
        $this->assertSame(['3.30.0-23', true], $lib->checkArguments);
    }

    public function testImageSwitchPlanFailsForMalformedContract(): void
    {
        $lib = new TestableAutoUpdateLib([
            'success' => true,
            'response' => ['image_switch' => ['required' => 'yes']],
        ]);

        $this->assertFalse($lib->imageSwitchPlan('3.30.0-23'));
        $this->assertStringContainsString('invalid image switch plan', strtolower($lib->getErrorMessage()));
    }
}

class TestableAutoUpdateLib extends AutoUpdateLib
{
    public array $checkArguments = [];

    public function __construct(private array|false $response = false)
    {
    }

    public function check(?string $dockerImageTag = null, bool $forceRefresh = false)
    {
        $this->checkArguments = [$dockerImageTag, $forceRefresh];

        return $this->response;
    }

    public function runAppendDockerImageTag(array $requestBody, ?string $dockerImageTag): array
    {
        return $this->appendDockerImageTag($requestBody, $dockerImageTag);
    }
}
```

- [ ] **Step 3: Run the narrow test and confirm valid RED**

```bash
composer cake-unit-test -- \
  app/upgrade/tests/Unit/Lib/AutoUpdateLibImageSwitchPlanTest.php
```

If the Composer script does not forward a path, run:

```bash
app/upgrade/vendor/bin/phpunit -c app/upgrade/phpunit.unit.xml.dist \
  app/upgrade/tests/Unit/Lib/AutoUpdateLibImageSwitchPlanTest.php
```

Expected: FAIL because the helper, new signature, and `imageSwitchPlan()` do not exist.

- [ ] **Step 4: Extend the request without changing existing callers**

Change the method signature to:

```php
public function check(?string $dockerImageTag = null, bool $forceRefresh = false)
```

Change cache loading to:

```php
$response = $forceRefresh ? null : Cache::read('server_response', 'updates');
```

After the existing request body is created, call:

```php
$requestBody = $this->appendDockerImageTag($requestBody, $dockerImageTag);
```

Add:

```php
protected function appendDockerImageTag(array $requestBody, ?string $dockerImageTag): array
{
    if ($dockerImageTag !== null) {
        $requestBody['dockerImageTag'] = $dockerImageTag;
    }

    return $requestBody;
}
```

- [ ] **Step 5: Add strict plan extraction**

Add this public method:

```php
public function imageSwitchPlan(string $currentImageTag): array|false
{
    $response = $this->check($currentImageTag, true);
    if ($response === false) {
        return false;
    }

    $plan = $response['response']['image_switch'] ?? null;
    if (!is_array($plan) || !isset($plan['required']) || !is_bool($plan['required'])) {
        $this->setError('Support server returned an invalid image switch plan.');

        return false;
    }

    if ($plan['required'] === false) {
        return ['required' => false];
    }

    $requiredStrings = [
        'source_app_version',
        'target_app_version',
        'current_image_tag',
        'target_image_tag',
        'edition',
        'distribution',
    ];

    foreach ($requiredStrings as $key) {
        if (!isset($plan[$key]) || !is_string($plan[$key]) || trim($plan[$key]) === '') {
            $this->setError('Support server returned an invalid image switch plan.');

            return false;
        }
    }

    return array_intersect_key($plan, array_flip(array_merge(['required'], $requiredStrings)));
}
```

- [ ] **Step 6: Run the narrow test and confirm GREEN**

Run the PHPUnit command from Step 3.

Expected: all three tests PASS.

- [ ] **Step 7: Run existing updater-adjacent unit coverage and commit**

```bash
composer cake-unit-test
git add app/upgrade/src/Lib/AutoUpdateLib.php \
  app/upgrade/tests/Unit/Lib/AutoUpdateLibImageSwitchPlanTest.php
git commit -m "feat: resolve Docker image switch plans"
```

Expected: unit suite PASS; existing no-argument calls compile and run unchanged.

## Task 2: Add the read-only Cake command

**Files:**
- Create: `app/upgrade/src/Command/ImageSwitchPlanCommand.php`
- Create: `app/upgrade/tests/Unit/Command/ImageSwitchPlanCommandTest.php`

**Interfaces:**
- Consumes: `AutoUpdateLib::imageSwitchPlan(string): array|false`.
- Produces command: `bin/cake image_switch_plan --current-image-tag <tag> --format json`.
- Produces stdout: one compact JSON object on success.
- Produces exit code `0` on valid required/no-op plan and non-zero on option or lookup failure.

- [ ] **Step 1: Read the command/test pattern and state the production change**

```bash
sed -n '1,130p' app/upgrade/src/Command/SystemHealthCheckCommand.php
sed -n '1,230p' app/upgrade/tests/Unit/Command/TranslationsAiFillMissingCommandTest.php
```

State: “Add one injected read-only command that validates a current tag and serializes only the normalized image plan.”

- [ ] **Step 2: Write failing command tests**

Create a test with injected `FakeImageSwitchAutoUpdateLib`, `StubConsoleOutput` for stdout/stderr, and `Arguments` instances. Cover these exact assertions:

```php
public function testCommandPrintsOnlyPlanJson(): void
{
    $client = new FakeImageSwitchAutoUpdateLib([
        'required' => true,
        'source_app_version' => '3.30.0',
        'target_app_version' => '3.30.1',
        'current_image_tag' => '3.30.0-23',
        'target_image_tag' => '3.30.1-6',
        'edition' => 'community',
        'distribution' => 'registry',
    ]);
    [$io, $stdout, $stderr] = $this->consoleIo();
    $command = new ImageSwitchPlanCommand(null, $client);

    $code = $command->execute(new Arguments([], [
        'current-image-tag' => '3.30.0-23',
        'format' => 'json',
    ], []), $io);

    $this->assertSame(Command::CODE_SUCCESS, $code);
    $this->assertSame('3.30.1-6', json_decode($stdout->output(), true, flags: JSON_THROW_ON_ERROR)['target_image_tag']);
    $this->assertSame('', $stderr->output());
    $this->assertSame('3.30.0-23', $client->receivedTag);
}
```

Also test missing/blank `current-image-tag`, unsupported format, and a fake client returning `false` with `getErrorMessage()` equal to `Support unavailable`; each must return `CODE_ERROR`, keep stdout empty, and write a concise stderr error.

- [ ] **Step 3: Run the command test and confirm RED**

```bash
app/upgrade/vendor/bin/phpunit -c app/upgrade/phpunit.unit.xml.dist \
  app/upgrade/tests/Unit/Command/ImageSwitchPlanCommandTest.php
```

Expected: FAIL because `ImageSwitchPlanCommand` is absent.

- [ ] **Step 4: Implement the complete command contract**

Create the command with this structure:

```php
<?php

declare(strict_types=1);

namespace App\Command;

use App\Lib\AutoUpdateLib;
use Cake\Command\Command;
use Cake\Console\Arguments;
use Cake\Console\CommandFactoryInterface;
use Cake\Console\ConsoleIo;
use Cake\Console\ConsoleOptionParser;
use JsonException;

class ImageSwitchPlanCommand extends Command
{
    private AutoUpdateLib $autoUpdateLib;

    public function __construct(
        ?CommandFactoryInterface $factory = null,
        ?AutoUpdateLib $autoUpdateLib = null,
    ) {
        parent::__construct($factory);
        $this->autoUpdateLib = $autoUpdateLib ?? new AutoUpdateLib();
    }

    public static function defaultName(): string
    {
        return 'image_switch_plan';
    }

    public function buildOptionParser(ConsoleOptionParser $parser): ConsoleOptionParser
    {
        return parent::buildOptionParser($parser)
            ->setDescription('Return the canonical Docker image switch plan.')
            ->addOption('current-image-tag', [
                'help' => 'Current immutable Docker image tag or latest for an unpinned install.',
                'required' => true,
            ])
            ->addOption('format', [
                'help' => 'Output format.',
                'choices' => ['json'],
                'default' => 'json',
            ]);
    }

    public function execute(Arguments $args, ConsoleIo $io): ?int
    {
        $tag = trim((string)$args->getOption('current-image-tag'));
        if ($tag === '') {
            $io->err('Current Docker image tag is required.');

            return static::CODE_ERROR;
        }

        if ($args->getOption('format') !== 'json') {
            $io->err('Only json output is supported.');

            return static::CODE_ERROR;
        }

        $plan = $this->autoUpdateLib->imageSwitchPlan($tag);
        if ($plan === false) {
            $io->err($this->autoUpdateLib->getErrorMessage());

            return static::CODE_ERROR;
        }

        try {
            $io->out(json_encode($plan, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES));
        } catch (JsonException $exception) {
            $io->err('Image switch plan could not be encoded.');

            return static::CODE_ERROR;
        }

        return static::CODE_SUCCESS;
    }
}
```

- [ ] **Step 5: Run command tests and confirm GREEN**

Run the command from Step 3.

Expected: all command cases PASS.

- [ ] **Step 6: Verify Cake discovers the command**

With the local application container running:

```bash
docker exec -w /var/www/eramba/app/upgrade -u www-data eramba \
  bin/cake image_switch_plan --help
```

Expected: help lists `--current-image-tag` and only `json` as the output choice.

- [ ] **Step 7: Commit the command**

```bash
git add app/upgrade/src/Command/ImageSwitchPlanCommand.php \
  app/upgrade/tests/Unit/Command/ImageSwitchPlanCommandTest.php
git commit -m "feat: expose image switch plan command"
```

## Task 3: Regression and baseline-image gate

**Files:**
- Modify only if tests expose a defect: files from Tasks 1-2.

**Interfaces:**
- Verifies the final `image_switch_plan` command consumed by the Docker executor plan.

- [ ] **Step 1: Run the complete pure unit suite**

```bash
composer cake-unit-test
```

Expected: PASS.

- [ ] **Step 2: Run targeted static analysis**

Use the repository's PHPStan command against the changed command and library paths. If the repository exposes only the standard script, run:

```bash
composer phpstan -- app/upgrade/src/Lib/AutoUpdateLib.php \
  app/upgrade/src/Command/ImageSwitchPlanCommand.php
```

Expected: exit `0`; if the Composer wrapper does not forward paths, run its documented narrow equivalent rather than a broader unrelated suite.

- [ ] **Step 3: Exercise a live no-secret output check**

Against a test support endpoint containing Docker metadata:

```bash
docker exec -w /var/www/eramba/app/upgrade -u www-data eramba \
  bin/cake image_switch_plan --current-image-tag latest --format json
```

Expected: one JSON object containing `required`; output contains neither `url`, `client_key`, `password`, nor authorization data.

- [ ] **Step 4: Record the rollout floor**

The first published Community and Enterprise images containing this command become the baseline supported by `./rebuild-app`. Record their immutable tags in the release handoff and populate those tags on the matching support release rows before the Docker executor ships.

- [ ] **Step 5: Commit any test-driven corrections**

If Steps 1-3 required changes:

```bash
git add app/upgrade/src/Lib/AutoUpdateLib.php \
  app/upgrade/src/Command/ImageSwitchPlanCommand.php \
  app/upgrade/tests/Unit/Lib/AutoUpdateLibImageSwitchPlanTest.php \
  app/upgrade/tests/Unit/Command/ImageSwitchPlanCommandTest.php
git commit -m "fix: harden image switch plan output"
```

If no files changed, do not create an empty commit.

## Plan Completion Gate

- `image_switch_plan` is auto-discovered by Cake and requires a current tag.
- The command forces a cache-safe support request containing `dockerImageTag`.
- Existing no-argument `AutoUpdateLib::check()` consumers remain compatible.
- Required and no-op plans serialize as one compact JSON object.
- Malformed, unavailable, or unauthorized responses exit non-zero without partial JSON.
- Pure unit tests and targeted PHPStan pass.
- A baseline immutable image containing the command is published only after the support contract is deployed.
