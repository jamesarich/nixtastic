# Develocity OSS rollout — design

Replicate `Meshtastic-Android`'s Develocity configuration ([PR #6531]) across every
Meshtastic repo that can carry it: Build Scans and the remote Build Cache on the OSS
Community instance at <https://community.develocity.cloud>, project ID `meshtastic`.

Date: 2026-08-02. Status: approved, not started.

[PR #6531]: https://github.com/meshtastic/Meshtastic-Android/pull/6531

## Why this lives here

The workspace `.gitignore` is deny-by-default and tracks only `/*.md` and `notes/*.md`.
`notes/` is for orientation on a single repo that publishes no agent docs of its own;
this is a cross-repo plan, so it sits at the root alongside the other workspace
documentation. It is a plan, not standing policy — delete it once the rollout lands.

## Scope

Six Gradle repos, **one PR each**. The workspace rule that commits never mix across
repos is absolute here: each of these is an independent upstream repo with its own
review process, commit style and governance.

| Repo | Build root | `setup-gradle` call sites | Today | Delta beyond the template |
| --- | --- | --- | --- | --- |
| `kzstd` | root, single module | 4 direct | HTTP cache only | none — **pilot** |
| `gradle-flatpak-sources` | root | 4 direct | HTTP cache only | none |
| `MQTTastic-Client-KMP` | root + `build-logic` | 12 via composite action | HTTP cache only | two settings files |
| `meshtastic-sdk` | root + `build-logic` | 9 composite + 1 direct | Develocity 4.5.0 → **`scans.gradle.com`** | migrate server, drop `termsOfUse*`, two settings files |
| `protobufs` | `packages/kmp` | 4 direct | HTTP cache only | subdirectory build, no version catalog |
| `TAKPacket-SDK` | `kotlin/` | 2 direct | HTTP cache only | not yet in the workspace |

### Out of scope, and why

- `firmware` — PlatformIO, no Gradle.
- `meshtastic-backend` — Gradle 7.3.1, predates JDK 21; not worth onboarding a build
  that cannot run on the current toolchain.
- `pluginmeshtastic` — depends on the non-redistributable ATAK SDK; CI cannot build it.
- `meshtastic/python` — spike only, see [Python](#python-spike-no-build-change).
- Develocity-native `testRetry` and Predictive Test Selection. Android configures
  `testRetry` in its convention plugins; that is project-side, independent of this
  settings-side onboarding, and belongs in a separate per-repo decision.

## What android has today (the thing being replicated)

- `build-logic/settings-plugin/src/main/kotlin/MeshtasticDevelocitySettingsPlugin.kt` —
  a `Plugin<Settings>` registered as `meshtastic.develocity`, applying
  `com.gradle.develocity` and `com.gradle.common-custom-user-data-gradle-plugin`, then
  configuring server, `projectId`, scan publishing, obfuscation and the build cache.
- Applied from **both** `settings.gradle.kts` and `build-logic/settings.gradle.kts` —
  an included build does not inherit the root's settings config, and without its own it
  silently drops to local-cache-only.
- Versions from `gradle/libs.versions.toml` (`develocity = "4.5.0"`, `ccud = "2.8.0"`).
- `.github/actions/gradle-setup` takes a `develocity_access_key` input and forwards it
  to `gradle/actions/setup-gradle`; all call sites pass `secrets.DEVELOCITY_ACCESS_KEY`.
- A "Revved up by Develocity" README badge filtered on `rootProjectNames`.

The other repos have no `build-logic` in four of six cases, so reproducing the
settings-plugin structure would mean adding an included build to each repo solely to
hold thirty lines of Develocity config. Instead each repo gets a self-contained script,
which is also how `gradle/build-cache.settings.gradle` is already duplicated across
these same repos today.

## The per-repo change

### 1. `gradle/develocity.settings.gradle` (new; **replaces** `gradle/build-cache.settings.gradle`)

The cache now comes from Develocity, so cache configuration and scan configuration are
one concern and live in one file. `build-cache.settings.gradle` is deleted along with
its `apply(from:)` line.

```groovy
/*
 * Develocity — Build Scans and remote Build Cache on the OSS Community instance
 * (https://community.develocity.cloud), project `meshtastic`.
 *
 * Applied from settings.gradle.kts. Repos with an included build apply it from that
 * build's settings file too: included builds do not inherit the root's configuration,
 * and without their own they silently drop to local-cache-only.
 *
 * Replaces the former self-hosted HttpBuildCache; GRADLE_CACHE_URL / _USERNAME /
 * _PASSWORD are no longer read anywhere.
 */

def isCI = System.getenv("CI") != null

develocity {
    server = "https://community.develocity.cloud"
    projectId = "meshtastic"
    buildScan {
        uploadInBackground = !isCI
        // Unauthenticated builds (fork PRs, developers who never provisioned a key)
        // publish nothing rather than failing.
        publishing.onlyIf { it.authenticated }
        // Fingerprints power cache-miss comparison (CI debugging); skip the payload locally.
        capture { fileFingerprints = isCI }
        // Public instance: no machine identity. Constants on purpose — scans already
        // record OS/CPU and CCUD adds CI metadata. Keep the `if` OUTSIDE the closures:
        // capture-free closures are what the configuration cache can serialize.
        obfuscation {
            ipAddresses { addresses -> addresses.collect { "0.0.0.0" } }
            externalProcessName { "external-process" }
            if (isCI) {
                username { "ci" }
                hostname { "ci-runner" }
            } else {
                username { "local-dev" }
                hostname { "local-machine" }
            }
        }
    }
}

// Resolved outside the buildCache block: inside it the closure delegate is
// BuildCacheConfiguration, which has no `develocity` property.
def develocityBuildCache = develocity.buildCache
def accessKey = System.getenv("DEVELOCITY_ACCESS_KEY")?.trim()

buildCache {
    // Off on CI: runners are ephemeral and every hit comes from the remote anyway.
    local {
        enabled = !isCI
    }
    remote(develocityBuildCache) {
        enabled = true
        // Only authenticated CI writes, so unmerged and fork code cannot poison the cache.
        push = isCI && accessKey != null && !accessKey.isEmpty()
    }
}
```

Two details to confirm during the pilot rather than assume:

- `publishing.onlyIf { it.authenticated }` — the Kotlin form in android is
  `it.isAuthenticated`; the Groovy property access should resolve to the same getter.
- `develocity.buildCache` resolving from an `apply(from:)` script. `meshtastic-sdk`
  already proves Groovy settings scripts configure `develocity {}` correctly under the
  configuration cache, but it does not exercise `remote(develocity.buildCache)`.

### 2. `settings.gradle.kts`

```kotlin
plugins {
    id("com.gradle.develocity") version "4.5.0"
    id("com.gradle.common-custom-user-data-gradle-plugin") version "2.8.0"
}

apply(from = "gradle/develocity.settings.gradle")
```

Literal versions, not the version catalog: a settings `plugins {}` block cannot see
`libs` without android's `build-logic` indirection. Renovate's Gradle manager parses
these. `kzstd` has no `renovate.json`, so either add one or accept manual bumps —
decide during the pilot.

### 3. CI wiring

- Composite-action repos (`meshtastic-sdk`, `MQTTastic-Client-KMP`): add an optional
  `develocity_access_key` input to `.github/actions/gradle-setup/action.yml`, forward it
  to `setup-gradle`'s `develocity-access-key`, and pass
  `secrets.DEVELOCITY_ACCESS_KEY` at every call site.
- Direct call sites: pass `develocity-access-key` inline.
- Remove `GRADLE_CACHE_URL` / `GRADLE_CACHE_USERNAME` / `GRADLE_CACHE_PASSWORD` env
  blocks. Keep any `cache-read-only` / `GRADLE_ENCRYPTION_KEY` plumbing — that governs
  the Actions-side Gradle home cache, not the remote cache.

Every input stays optional, so a build without the secret keeps working — it just
publishes nothing and reads the cache without writing.

### 4. README badge

```markdown
[![Revved up by Develocity](https://img.shields.io/badge/Revved%20up%20by-Develocity-06A0CE?logo=Gradle&labelColor=02303A)](https://community.develocity.cloud/scans?search.rootProjectNames=<ROOT_PROJECT_NAME>)
```

Root project names: `kzstd`, `gradle-flatpak-sources`, `MQTTastic-Client-KMP`,
`meshtastic-sdk`, `protobufs`, `takpacket-sdk`.

### 5. Repository secret (manual, by the repo admin)

`DEVELOCITY_ACCESS_KEY` on each repo, value **including the host prefix**:

```
community.develocity.cloud=<key>
```

Without the `community.develocity.cloud=` prefix the key is silently ignored — PR #6531
calls this the most common onboarding failure. The key comes from the CI service account
the Develocity Solutions team provisioned for the `meshtastic` project (My settings →
Access keys). Whether that account's project membership already covers these repos is
the first thing to confirm; if it does not, the rollout still lands, it just publishes
nothing until the key is valid.

Developers provision their own local key with `./gradlew provisionDevelocityAccessKey`,
signed out of the CI service account.

## Per-repo deltas

**`kzstd`** — pilot. Single module, no `build-logic`, no composite action. Only
`ci.yml` currently reads `GRADLE_CACHE_*`; `release.yml` and `docs.yml` call
`setup-gradle` without it. No `renovate.json`.

**`gradle-flatpak-sources`** — four call sites across `ci.yml`, `publish.yml`,
`snapshot.yml`, `docs.yml`; only `ci.yml` reads `GRADLE_CACHE_*`. This repo publishes
`org.meshtastic.flatpak.sources.settings`, which android consumes — do not disturb the
publishing tasks.

**`MQTTastic-Client-KMP`** — twelve call sites, all via the composite action. Both
`settings.gradle.kts` and `build-logic/settings.gradle.kts` need the plugins block and
the `apply(from:)` (the latter with a `../gradle/...` path).

**`meshtastic-sdk`** — the only repo already on Develocity, but pointed at the default
`scans.gradle.com`. Its existing `gradle/develocity.settings.gradle` is rewritten, not
added. Specifically: remove `termsOfUseUrl` / `termsOfUseAgree` (they apply only to the
public `scans.gradle.com` service and are rejected once a `server` is set), replace
`publishing.onlyIf { isCi }` with the authenticated check so local builds publish too,
bump CCUD 2.7.0 → 2.8.0, and delete `gradle/build-cache.settings.gradle` plus both
`apply(from:)` lines for it. `termsOfUse*` apply only to the public `scans.gradle.com`
service. **Tested 2026-08-02: the plugin does not reject them alongside a configured
`server`** — the build configures fine and still publishes to the configured server, so
removing them is cleanliness rather than a requirement. Both settings files already
declare the two plugins.
This repo has `GOVERNANCE.md`, `CODEOWNERS` and Spec Kit — read them before opening the
PR; the change may need to flow through the spec lifecycle rather than land as an
ad-hoc PR.

**`protobufs`** — the Gradle build is `packages/kmp/`, with its own
`gradle/build-cache.settings.gradle` relative to that directory. Four call sites in
`kmp-pull-request.yml`, `publish-kmp.yml` (two) and `snapshot-kmp.yml`. No
`libs.versions.toml` for that build, which the literal-version approach already
accommodates. Scans cover only the KMP leg of a polyglot repo (buf, deno, cargo) —
expected, worth a line in the PR description. This repo is also vendored as a submodule
in `firmware`; settings-only changes do not affect that.

**`TAKPacket-SDK`** — **not in the workspace.** Prerequisite: clone it and run
`nix run .#sync` so it gets a generated `.envrc` and `.mcp.json`, then
`nix run .#brief -- TAKPacket-SDK` to read its docs (it has a `CLAUDE.md` and
`CODEOWNERS`). The Gradle build is `kotlin/`, with `kotlin/gradle/build-cache.settings.gradle`
and `kotlin/gradle/libs.versions.toml`. Every Gradle step uses
`working-directory: kotlin`. Polyglot repo (C, Swift, Python, C#, TypeScript) — the same
"KMP leg only" caveat applies.

This repo needs the one wiring variant the others do not: `setup-gradle` appears only
twice, both in `ci.yml`, while `release.yml` and `docs.yml` invoke Gradle directly with
`GRADLE_CACHE_*` set as workflow-level `env`. Those jobs have no `setup-gradle` step to
carry `develocity-access-key`, so they take
`DEVELOCITY_ACCESS_KEY: ${{ secrets.DEVELOCITY_ACCESS_KEY }}` as workflow-level `env`
instead — the same variable the plugin reads directly. Audit every repo for this shape
before removing its `GRADLE_CACHE_*` env: a job that loses cache credentials without
gaining a Develocity key ends up with no remote cache at all.

## Sequencing

`kzstd` → `gradle-flatpak-sources` → `MQTTastic-Client-KMP` → `meshtastic-sdk` →
`protobufs` → `TAKPacket-SDK`.

`kzstd` first because it is the smallest surface that still exercises the whole
template: settings change, cache replacement, direct CI call sites, badge, secret. It
proves the two unverified Groovy details above before the file is copied five times.
The two repos with `build-logic` come after, then the two subdirectory builds, then the
repo that first has to join the workspace.

Before touching any repo: `nix run .#brief -- <repo>`, then read that repo's own docs in
precedence order (`.specify/memory/constitution.md` → `AGENTS.md` → `CLAUDE.md` →
`CONTRIBUTING.md`) and match **its** commit and review conventions, not the workspace's.

## Verification

Per repo, before opening the PR:

1. Build twice locally (`./gradlew help`, then again) and confirm the configuration
   cache is **reused** on the second run. The obfuscation closures are the risk.
2. Confirm an unauthenticated local build publishes nothing and does not fail.
3. With a provisioned local key, confirm a scan appears under project `meshtastic`.
4. For `meshtastic-sdk` and `MQTTastic-Client-KMP`, confirm the `build-logic` build also
   reports remote cache activity — not just the root build.

In CI, after the secret is set:

5. Push the branch **to the repo itself, not a fork** — fork PRs cannot read the secret,
   so a fork run proves nothing.
6. Confirm the scan lands at
   `https://community.develocity.cloud/scans?search.rootProjectNames=<name>`.
7. Run CI twice and confirm the second run shows remote cache hits in the scan's
   cache-performance view.
8. Confirm no workflow still references `GRADLE_CACHE_*`.

## Risks

- **The service account may not cover these repos.** Then scans and cache writes are
  silently absent. Mitigated by confirming before the pilot merges, and by the config
  degrading to no-publish rather than failing.

  **2026-08-02, partly answered by the pilot:** access keys are scoped to the
  *server*, not to a project or repo. The key already provisioned for android
  (`$GRADLE_USER_HOME/develocity/keys.properties`, which is workspace-local here and so
  shared by every repo) authenticated `kzstd` scans with no per-repo setup —
  <https://community.develocity.cloud/s/ahh6y3k7esze2>. `projectId` is metadata the
  build declares, not a permission the server grants. So the remaining question is
  narrower than assumed: only whether the CI service account may *write* to the build
  cache from a repo other than android.
- **Losing the self-hosted cache.** If the community instance is unreachable, local
  builds fall back to the local cache and CI (where local cache is off) simply misses.
  Acceptable; it is what android already runs on.
- **Configuration-cache regression** from the Groovy closures. Caught by verification
  step 1, before the template is copied.
- **Rollback** is a revert of a single self-contained PR per repo; the deleted
  `build-cache.settings.gradle` and the `GRADLE_CACHE_*` secrets come back with it. Do
  not delete those repo secrets until every repo has been running on Develocity for a
  while.

## Python spike (no build change)

`meshtastic/python` is Poetry + pytest with a `Makefile` and `pytest.ini` — a good fit
for the agent on paper. But per the [Develocity Python Agent manual], Python support is
beta (0.10.x), off by default and enabled only on request, and publishing to Gradle's
own hosted instance is documented as unsupported. Whether that excludes
`community.develocity.cloud` is the open question.

Deliverable: a tracking issue on `meshtastic/python` recording

- the answer from the Develocity team on whether Python can be enabled for the
  `meshtastic` project on the community instance;
- that the agent wheel is served off-PyPI
  (`develocity_agent-0.10.1-py3-none-any.whl` from `develocity-python-pkgs.gradle.com`),
  so adding it to `poetry.lock` is a supply-chain decision needing a pinned hash;
- that only pytest produces test results, though pip/poetry/pylint/mypy are instrumented;
- the shape the change would take (`.develocity.py` at the repo root with
  `develocity_url` and `project_id`, `DEVELOCITY_ACCESS_KEY` from the same repo secret).

No file in `meshtastic/python` changes until that issue is answered.

**Filed 2026-08-02:** <https://github.com/meshtastic/python/issues/966>. The repo is
otherwise a clean fit — Poetry + pytest, with a CI job that already runs exactly the
toolchain the agent instruments. The blocking question is whether Gradle can enable
Python for project `meshtastic` on the community instance; the supply-chain call on an
off-PyPI beta wheel in `poetry.lock` is the maintainers'.

[Develocity Python Agent manual]: https://docs.develocity.ai/python-agent/
