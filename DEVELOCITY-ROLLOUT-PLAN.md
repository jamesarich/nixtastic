# Develocity OSS Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put every Meshtastic Gradle repo on the OSS Community Develocity instance for Build Scans and remote build caching, replacing each repo's self-hosted HTTP build cache.

**Architecture:** Each repo gets one self-contained `gradle/develocity.settings.gradle` (Groovy) that replaces its `gradle/build-cache.settings.gradle`, applied from `settings.gradle.kts` — and from `build-logic/settings.gradle.kts` too where an included build exists, because included builds do not inherit the root's settings configuration. No shared artifact, no `build-logic` added anywhere it does not already exist. One PR per repo; `kzstd` is the pilot that proves the template.

**Tech Stack:** Gradle 8/9 settings scripts (Groovy), `com.gradle.develocity` 4.5.0, `com.gradle.common-custom-user-data-gradle-plugin` 2.8.0, GitHub Actions (`gradle/actions/setup-gradle@v6`).

**Design doc:** `DEVELOCITY-ROLLOUT.md` in this workspace. Read it before starting.

## Global Constraints

- Server: `https://community.develocity.cloud`. Project ID: `meshtastic`.
- Plugin versions, literal in every settings `plugins {}` block: `com.gradle.develocity` **4.5.0**, `com.gradle.common-custom-user-data-gradle-plugin` **2.8.0**.
- Secret name `DEVELOCITY_ACCESS_KEY`; its value **must** carry the host prefix `community.develocity.cloud=` or the key is silently ignored.
- **One repo per PR. Never mix commits across repos.** Each of these is an independent upstream repo; this workspace is its own repo too.
- Before touching any repo, run `nix run .#brief -- <repo>` from the workspace root and read that repo's own docs in precedence order (`.specify/memory/constitution.md` → `AGENTS.md` → `CLAUDE.md` → `CONTRIBUTING.md`). Match **that repo's** commit and review conventions.
- `kzstd` and `meshtastic-sdk` require DCO sign-off — commit with `git commit -s`.
- Do **not** delete the `GRADLE_CACHE_URL` / `GRADLE_CACHE_USERNAME` / `GRADLE_CACHE_PASSWORD` repository secrets during this rollout. Removing their use from workflows is enough; the secrets are the rollback path.
- Every CI input stays optional. A build with no access key must publish nothing and still succeed.
- Do not add Develocity `testRetry` or Predictive Test Selection. Out of scope.

---

### Task 0: Confirm access-key coverage before writing any config

**Files:** none — this is a prerequisite check whose output changes nothing but the sequencing.

**Interfaces:**
- Produces: a yes/no on whether the `meshtastic` project's CI service account covers repos beyond `Meshtastic-Android`, and the access-key value used in every later task's Step "set the repository secret".

- [ ] **Step 1: Read the android onboarding PR for the exact provisioning flow**

```bash
gh pr view 6531 --repo meshtastic/Meshtastic-Android --json body --jq .body
```

Expected: the three-step flow — CI service-account key from **My settings → Access keys**, repo secret in `host=key` form, `./gradlew provisionDevelocityAccessKey` for local keys.

- [ ] **Step 2: Confirm the android setup is live**

```bash
gh secret list --repo meshtastic/Meshtastic-Android | grep DEVELOCITY_ACCESS_KEY
```

Expected: one row. Then open <https://community.develocity.cloud/scans?search.rootProjectNames=MeshtasticAndroid> and confirm recent scans exist. If they do, the project and service account are working and only the per-repo secret is missing elsewhere.

- [ ] **Step 3: Ask the Develocity Solutions team whether the `meshtastic` project covers the other repos**

Send the six repo names (`kzstd`, `gradle-flatpak-sources`, `MQTTastic-Client-KMP`, `meshtastic-sdk`, `protobufs`, `TAKPacket-SDK`) and ask whether builds from them may publish under project ID `meshtastic` with the existing CI service account, or whether each needs separate onboarding. Ask the Python question from Task 7 in the same message.

- [ ] **Step 4: Record the answer**

Append the answer, dated, to the "Risks" section of `DEVELOCITY-ROLLOUT.md`, then commit in the workspace repo:

```bash
git -C "$MESHTASTIC_WORKSPACE" add DEVELOCITY-ROLLOUT.md
git -C "$MESHTASTIC_WORKSPACE" commit -m "docs: record Develocity project coverage answer"
```

If the answer is "not covered", the rollout still proceeds — the config degrades to publish-nothing — but say so in each PR description so reviewers do not chase a missing scan link.

---

### Task 1: kzstd — the pilot

The smallest repo that still exercises the whole template: settings change, cache replacement, direct CI call sites, badge, secret. Its two unverified Groovy details (`publishing.onlyIf { it.authenticated }` and `develocity.buildCache` resolving from an `apply(from:)` script) must be proven here before the file is copied five times.

**Files:**
- Create: `kzstd/gradle/develocity.settings.gradle`
- Delete: `kzstd/gradle/build-cache.settings.gradle`
- Modify: `kzstd/settings.gradle.kts` (whole file — 11 lines)
- Modify: `kzstd/.github/workflows/ci.yml:17-20` (drop `env:` block), `:40-41` and `:77-78` (two `setup-gradle` steps)
- Modify: `kzstd/.github/workflows/release.yml:46`, `kzstd/.github/workflows/docs.yml:42`
- Modify: `kzstd/README.md:3-7` (badge row)

**Interfaces:**
- Produces: `gradle/develocity.settings.gradle` — the template every later task copies, with only the `apply(from:)` path and root project name differing.

- [ ] **Step 1: Orient in the repo**

```bash
cd "$MESHTASTIC_WORKSPACE" && nix run .#brief -- kzstd
```

Expected: branch `main`, clean tree, and the doc inventory. Read `kzstd/AGENTS.md` and `kzstd/CONTRIBUTING.md` — note the DCO sign-off requirement and that this is deliberately a single-module project with no `build-logic`.

- [ ] **Step 2: Create the branch**

```bash
cd "$MESHTASTIC_WORKSPACE" && nix run .#worktree -- kzstd feat/develocity-oss
```

Work in the printed worktree path for every remaining step in this task.

- [ ] **Step 3: Capture the "before" state so the cache change is measurable**

```bash
./gradlew --stop
./gradlew jvmTest --configuration-cache
```

Expected: a normal build. Note the wall-clock time; it is the comparison point for Step 12.

- [ ] **Step 4: Write the new settings script**

Create `gradle/develocity.settings.gradle`:

```groovy
// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Develocity — Build Scans and remote Build Cache on the OSS Community instance
 * (https://community.develocity.cloud), project `meshtastic`.
 *
 * Replaces the former self-hosted HttpBuildCache: GRADLE_CACHE_URL / _USERNAME /
 * _PASSWORD are no longer read anywhere in this repo.
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

- [ ] **Step 5: Rewrite `settings.gradle.kts`**

Replace the whole file with:

```kotlin
// SPDX-License-Identifier: GPL-3.0-or-later
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

plugins {
    id("com.gradle.develocity") version "4.5.0"
    id("com.gradle.common-custom-user-data-gradle-plugin") version "2.8.0"
}

apply(from = "gradle/develocity.settings.gradle")

rootProject.name = "kzstd"
```

- [ ] **Step 6: Delete the old cache script**

```bash
git rm gradle/build-cache.settings.gradle
```

- [ ] **Step 7: Verify the build still configures — the first real test**

```bash
./gradlew help --configuration-cache
```

Expected: BUILD SUCCESSFUL, and **no** scan URL (no local access key provisioned yet — this proves `publishing.onlyIf { it.authenticated }` degrades correctly). If it fails with `No such property: authenticated`, switch to `publishing.onlyIf { it.isAuthenticated() }`. If it fails with `Could not find property 'buildCache' on ... DevelocityConfiguration` or a delegate error, the `develocity.buildCache` resolution needs `settings.extensions.getByName("develocity").buildCache` instead — fix here and carry the fix into every later task.

- [ ] **Step 8: Verify the configuration cache is reused — the second real test**

```bash
./gradlew help --configuration-cache
```

Expected: `Reusing configuration cache.` in the output. If instead it reports the cache was discarded and names the obfuscation closures, move the closures' captured values out to locals until it stops.

- [ ] **Step 9: Provision a local key and confirm a scan publishes**

```bash
./gradlew provisionDevelocityAccessKey
```

Sign in as **yourself**, not the CI service account (use a private window if already signed in as CI). Then:

```bash
./gradlew help
```

Expected: a `https://community.develocity.cloud/s/...` scan URL. Open it and confirm the scan shows project `meshtastic`, username `local-dev`, hostname `local-machine`, and IP `0.0.0.0`.

- [ ] **Step 10: Update the CI workflows**

In `.github/workflows/ci.yml`, delete the workflow-level `env:` block (lines 17–20):

```yaml
env:
  GRADLE_CACHE_URL: ${{ secrets.GRADLE_CACHE_URL }}
  GRADLE_CACHE_USERNAME: ${{ secrets.GRADLE_CACHE_USERNAME }}
  GRADLE_CACHE_PASSWORD: ${{ secrets.GRADLE_CACHE_PASSWORD }}
```

Then give each of the four `setup-gradle` steps the access key — `ci.yml` (two: the `linux` and `build` jobs), `release.yml`, and `docs.yml`. Each becomes:

```yaml
      - name: Setup Gradle
        uses: gradle/actions/setup-gradle@3f131e8634966bd73d06cc69884922b02e6faf92 # v6.2.0
        with:
          develocity-access-key: ${{ secrets.DEVELOCITY_ACCESS_KEY }}
```

- [ ] **Step 11: Add the README badge**

In `README.md`, add as the last line of the badge row (after the Kotlin Multiplatform badge on line 7):

```markdown
[![Revved up by Develocity](https://img.shields.io/badge/Revved%20up%20by-Develocity-06A0CE?logo=Gradle&labelColor=02303A)](https://community.develocity.cloud/scans?search.rootProjectNames=kzstd)
```

- [ ] **Step 12: Confirm the remote cache actually serves hits**

```bash
./gradlew clean
./gradlew jvmTest
```

Expected: a scan URL. Open it, go to the **Build cache** section, and confirm remote cache reads occurred. Compare against the Step 3 timing. Zero remote hits on a fresh clean means the key has no cache read permission — report that to the Develocity team rather than working around it.

- [ ] **Step 13: Confirm nothing still references the old cache**

```bash
grep -rn "GRADLE_CACHE_\|build-cache.settings.gradle" . --exclude-dir=.git --exclude-dir=build --exclude-dir=.gradle
```

Expected: no output.

- [ ] **Step 14: Run the repo's quality gate**

```bash
./gradlew spotlessCheck detekt apiCheck jvmTest --stacktrace
```

Expected: BUILD SUCCESSFUL. A settings-only change should not move the ABI, so `apiCheck` passing without an `apiDump` is the confirmation.

- [ ] **Step 15: Commit**

```bash
git add gradle/develocity.settings.gradle settings.gradle.kts README.md .github/workflows/
git commit -s -m "$(cat <<'EOF'
ci: publish Build Scans and cache to the OSS Community Develocity instance

Replaces the self-hosted HttpBuildCache with Develocity's remote cache at
community.develocity.cloud under project `meshtastic`, matching the
Meshtastic-Android onboarding. Scans publish only from authenticated builds,
so fork PRs and unprovisioned developers are unaffected; only authenticated
CI runs write to the cache.
EOF
)"
```

- [ ] **Step 16: Set the repository secret**

In `meshtastic/kzstd` → Settings → Secrets and variables → Actions → New repository secret:

- Name: `DEVELOCITY_ACCESS_KEY`
- Value: `community.develocity.cloud=<key from the CI service account>`

The `community.develocity.cloud=` prefix is required.

- [ ] **Step 17: Push to the repo, not a fork, and verify CI**

```bash
git push -u origin feat/develocity-oss
```

Fork PRs cannot read the secret, so a fork run proves nothing. Watch the run:

```bash
gh run watch --repo meshtastic/kzstd
```

Expected: green, with a scan at <https://community.develocity.cloud/scans?search.rootProjectNames=kzstd> showing username `ci` and hostname `ci-runner`.

- [ ] **Step 18: Re-run CI and confirm cache hits**

```bash
gh run rerun --repo meshtastic/kzstd $(gh run list --repo meshtastic/kzstd --branch feat/develocity-oss --limit 1 --json databaseId --jq '.[0].databaseId')
```

Expected: the second run's scan shows remote cache hits and a shorter build time. This is the whole point of the change; if it is absent, do not proceed to Task 2.

- [ ] **Step 19: Open the PR**

```bash
gh pr create --repo meshtastic/kzstd --base main --title "ci: onboard to the OSS Community Develocity instance" --body "..."
```

Body must state: what moved (scans + cache to `community.develocity.cloud`, project `meshtastic`), that `GRADLE_CACHE_*` secrets are now unused but deliberately not deleted, that the `DEVELOCITY_ACCESS_KEY` secret is already set, and links to the before/after scans from Step 18.

---

### Task 2: gradle-flatpak-sources

**Files:**
- Create: `gradle-flatpak-sources/gradle/develocity.settings.gradle`
- Delete: `gradle-flatpak-sources/gradle/build-cache.settings.gradle`
- Modify: `gradle-flatpak-sources/settings.gradle.kts`
- Modify: `.github/workflows/ci.yml` (drop `GRADLE_CACHE_*` env; one `setup-gradle`), `publish.yml`, `snapshot.yml`, `docs.yml` (one `setup-gradle` each)
- Modify: `gradle-flatpak-sources/README.md` (badge row)

**Interfaces:**
- Consumes: the `gradle/develocity.settings.gradle` template proven in Task 1, including any Groovy fix made in Task 1 Step 7.

- [ ] **Step 1: Orient and branch**

```bash
cd "$MESHTASTIC_WORKSPACE" && nix run .#brief -- gradle-flatpak-sources
cd "$MESHTASTIC_WORKSPACE" && nix run .#worktree -- gradle-flatpak-sources feat/develocity-oss
```

This repo has no `AGENTS.md`; its orientation note is `notes/gradle-flatpak-sources.md` in the workspace. It publishes `org.meshtastic.flatpak.sources.settings`, which `Meshtastic-Android` consumes — do not touch the publishing tasks.

- [ ] **Step 2: Create `gradle/develocity.settings.gradle`**

```groovy
/*
 * Develocity — Build Scans and remote Build Cache on the OSS Community instance
 * (https://community.develocity.cloud), project `meshtastic`.
 *
 * Replaces the former self-hosted HttpBuildCache: GRADLE_CACHE_URL / _USERNAME /
 * _PASSWORD are no longer read anywhere in this repo.
 */

def isCI = System.getenv("CI") != null

develocity {
    server = "https://community.develocity.cloud"
    projectId = "meshtastic"
    buildScan {
        uploadInBackground = !isCI
        publishing.onlyIf { it.authenticated }
        capture { fileFingerprints = isCI }
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

def develocityBuildCache = develocity.buildCache
def accessKey = System.getenv("DEVELOCITY_ACCESS_KEY")?.trim()

buildCache {
    local {
        enabled = !isCI
    }
    remote(develocityBuildCache) {
        enabled = true
        push = isCI && accessKey != null && !accessKey.isEmpty()
    }
}
```

- [ ] **Step 3: Rewrite `settings.gradle.kts`**

```kotlin
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}

plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
    id("com.gradle.develocity") version "4.5.0"
    id("com.gradle.common-custom-user-data-gradle-plugin") version "2.8.0"
}

apply(from = "gradle/develocity.settings.gradle")

rootProject.name = "gradle-flatpak-sources"
include(":plugin")
```

- [ ] **Step 4: Delete the old cache script**

```bash
git rm gradle/build-cache.settings.gradle
```

- [ ] **Step 5: Verify configuration and CC reuse**

```bash
./gradlew help --configuration-cache
./gradlew help --configuration-cache
```

Expected: both succeed; the second prints `Reusing configuration cache.`

- [ ] **Step 6: Confirm a scan publishes**

```bash
./gradlew help
```

Expected: a `community.develocity.cloud/s/...` URL (the local key from Task 1 Step 9 is machine-wide, in `~/.gradle/develocity/keys.properties`).

- [ ] **Step 7: Update the four workflows**

Remove the `GRADLE_CACHE_*` `env:` block from `ci.yml`. Give the `setup-gradle` step in each of `ci.yml`, `publish.yml`, `snapshot.yml`, `docs.yml`:

```yaml
        with:
          develocity-access-key: ${{ secrets.DEVELOCITY_ACCESS_KEY }}
```

merged into any `with:` block already present rather than added as a second one.

- [ ] **Step 8: Add the README badge**

```markdown
[![Revved up by Develocity](https://img.shields.io/badge/Revved%20up%20by-Develocity-06A0CE?logo=Gradle&labelColor=02303A)](https://community.develocity.cloud/scans?search.rootProjectNames=gradle-flatpak-sources)
```

- [ ] **Step 9: Verify nothing references the old cache and the build passes**

```bash
grep -rn "GRADLE_CACHE_\|build-cache.settings.gradle" . --exclude-dir=.git --exclude-dir=build --exclude-dir=.gradle
./gradlew build
```

Expected: no grep output; BUILD SUCCESSFUL.

- [ ] **Step 10: Commit, set the secret, push, verify**

```bash
git add gradle/develocity.settings.gradle settings.gradle.kts README.md .github/workflows/
git commit -m "ci: publish Build Scans and cache to the OSS Community Develocity instance"
git push -u origin feat/develocity-oss
```

Set `DEVELOCITY_ACCESS_KEY` = `community.develocity.cloud=<key>` on `meshtastic/gradle-flatpak-sources`, then confirm the CI scan appears under `search.rootProjectNames=gradle-flatpak-sources` and open the PR.

---

### Task 3: MQTTastic-Client-KMP

First repo with an included build. The `build-logic` build needs its own copy of the configuration — without it, it silently drops to local-cache-only.

**Files:**
- Create: `MQTTastic-Client-KMP/gradle/develocity.settings.gradle`
- Delete: `MQTTastic-Client-KMP/gradle/build-cache.settings.gradle`
- Modify: `MQTTastic-Client-KMP/settings.gradle.kts`, `MQTTastic-Client-KMP/build-logic/settings.gradle.kts`
- Modify: `.github/actions/gradle-setup/action.yml` (new input), `.github/workflows/ci.yml` (9 call sites + env), `docs.yml` (1), `release.yml` (2)
- Modify: `MQTTastic-Client-KMP/README.md` (badge row)

**Interfaces:**
- Consumes: the template from Task 1.
- Produces: the composite-action input shape (`develocity_access_key`) that Task 4 reuses.

- [ ] **Step 1: Orient and branch**

```bash
cd "$MESHTASTIC_WORKSPACE" && nix run .#brief -- MQTTastic-Client-KMP
cd "$MESHTASTIC_WORKSPACE" && nix run .#worktree -- MQTTastic-Client-KMP feat/develocity-oss
```

Read `AGENTS.md`. Conventional commits; no DCO requirement found.

- [ ] **Step 2: Create `gradle/develocity.settings.gradle`**

```groovy
/*
 * Copyright (c) 2026 Meshtastic LLC
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * Develocity — Build Scans and remote Build Cache on the OSS Community instance
 * (https://community.develocity.cloud), project `meshtastic`.
 *
 * Applied from BOTH settings files: the build-logic included build does not
 * inherit the root's configuration, and without its own it silently drops to
 * local-cache-only.
 *
 * Replaces the former self-hosted HttpBuildCache: GRADLE_CACHE_URL / _USERNAME /
 * _PASSWORD are no longer read anywhere in this repo.
 */

def isCI = System.getenv("CI") != null

develocity {
    server = "https://community.develocity.cloud"
    projectId = "meshtastic"
    buildScan {
        uploadInBackground = !isCI
        publishing.onlyIf { it.authenticated }
        capture { fileFingerprints = isCI }
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

def develocityBuildCache = develocity.buildCache
def accessKey = System.getenv("DEVELOCITY_ACCESS_KEY")?.trim()

buildCache {
    local {
        enabled = !isCI
    }
    remote(develocityBuildCache) {
        enabled = true
        push = isCI && accessKey != null && !accessKey.isEmpty()
    }
}
```

- [ ] **Step 3: Wire the root settings file**

In `settings.gradle.kts`, extend the `plugins {}` block and swap the applied script:

```kotlin
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
    id("com.gradle.develocity") version "4.5.0"
    id("com.gradle.common-custom-user-data-gradle-plugin") version "2.8.0"
}

apply(from = "gradle/develocity.settings.gradle")
```

replacing the existing `apply(from = "gradle/build-cache.settings.gradle")` line.

- [ ] **Step 4: Wire the included build's settings file**

`build-logic/settings.gradle.kts` needs the same two plugins and the script applied with a parent-relative path:

```kotlin
plugins {
    id("com.gradle.develocity") version "4.5.0"
    id("com.gradle.common-custom-user-data-gradle-plugin") version "2.8.0"
}

apply(from = "../gradle/develocity.settings.gradle")
```

Replace any existing `apply(from = "../gradle/build-cache.settings.gradle")` line.

- [ ] **Step 5: Delete the old cache script**

```bash
git rm gradle/build-cache.settings.gradle
```

- [ ] **Step 6: Verify both builds configure and reuse the CC**

```bash
./gradlew help
./gradlew help
```

This repo already sets `org.gradle.configuration-cache=true`, so no flag is needed. Expected: the second run prints `Reusing configuration cache.`

- [ ] **Step 7: Confirm the included build is covered**

```bash
./gradlew --stop
./gradlew help --info 2>&1 | grep -i "build cache\|develocity" | head -20
```

Expected: build-cache configuration reported for `build-logic` as well as the root. A `build-logic` line saying local-only means Step 4 did not take effect.

- [ ] **Step 8: Add the composite-action input**

In `.github/actions/gradle-setup/action.yml`, add to `inputs:`:

```yaml
  develocity_access_key:
    description: 'Access key for the OSS Community Develocity Instance (Build Scan publishing and remote cache writes)'
    required: false
```

and to the `Setup Gradle` step's `with:`:

```yaml
        develocity-access-key: ${{ inputs.develocity_access_key }}
```

- [ ] **Step 9: Pass the secret at all twelve call sites**

Every `uses: ./.github/actions/gradle-setup` in `ci.yml` (9), `docs.yml` (1) and `release.yml` (2) gets:

```yaml
        with:
          develocity_access_key: ${{ secrets.DEVELOCITY_ACCESS_KEY }}
```

merged into an existing `with:` block where one is present. Then delete the `GRADLE_CACHE_*` `env:` blocks from all three workflows.

- [ ] **Step 10: Add the README badge**

```markdown
[![Revved up by Develocity](https://img.shields.io/badge/Revved%20up%20by-Develocity-06A0CE?logo=Gradle&labelColor=02303A)](https://community.develocity.cloud/scans?search.rootProjectNames=MQTTastic-Client-KMP)
```

- [ ] **Step 11: Verify and commit**

```bash
grep -rn "GRADLE_CACHE_\|build-cache.settings.gradle" . --exclude-dir=.git --exclude-dir=build --exclude-dir=.gradle
./gradlew build
git add gradle/develocity.settings.gradle settings.gradle.kts build-logic/settings.gradle.kts README.md .github/
git commit -m "ci: publish Build Scans and cache to the OSS Community Develocity instance"
```

Expected: no grep output; BUILD SUCCESSFUL.

- [ ] **Step 12: Set the secret, push, verify both scans**

Set `DEVELOCITY_ACCESS_KEY` = `community.develocity.cloud=<key>` on `meshtastic/MQTTastic-Client-KMP`, push the branch to the repo, and confirm scans appear for **both** root project names — `MQTTastic-Client-KMP` and `build-logic` — then open the PR.

---

### Task 4: meshtastic-sdk

The only repo already on Develocity, but pointed at the default `scans.gradle.com`. This is a rewrite, not an addition. It also has `GOVERNANCE.md`, `CODEOWNERS` and Spec Kit — check whether the change is expected to flow through the spec lifecycle before opening an ad-hoc PR.

**Files:**
- Modify (rewrite): `meshtastic-sdk/gradle/develocity.settings.gradle`
- Delete: `meshtastic-sdk/gradle/build-cache.settings.gradle`
- Modify: `meshtastic-sdk/settings.gradle.kts`, `meshtastic-sdk/build-logic/settings.gradle.kts`
- Modify: `.github/actions/gradle-setup/action.yml`, `.github/workflows/ci.yml` (8 composite call sites + env), `release.yml` (1 composite + env), `docs.yml` (1 direct `setup-gradle`)
- Modify: `meshtastic-sdk/README.md` (badge row)

**Interfaces:**
- Consumes: the template from Task 1 and the composite-action input shape from Task 3 Step 8.

- [ ] **Step 1: Orient and branch**

```bash
cd "$MESHTASTIC_WORKSPACE" && nix run .#brief -- meshtastic-sdk
cd "$MESHTASTIC_WORKSPACE" && nix run .#worktree -- meshtastic-sdk feat/develocity-oss
```

Read `.specify/memory/constitution.md` first (it outranks the other docs), then `AGENTS.md`, `GOVERNANCE.md`, `CONTRIBUTING.md`. DCO sign-off is required here — use `git commit -s`. Conventional Commits are encouraged.

- [ ] **Step 2: Rewrite `gradle/develocity.settings.gradle`**

Replace the whole file. The changes from what is there now: `server` and `projectId` are set; `termsOfUseUrl`/`termsOfUseAgree` are gone (they apply only to the public `scans.gradle.com` service); publishing is gated on authentication rather than `isCi`, so local builds publish too; obfuscation is added; and the build cache moves here from `build-cache.settings.gradle`.

```groovy
/*
 * Meshtastic — open source mesh radio
 * Copyright © 2026 Meshtastic LLC
 *
 * Licensed under the GPL-3.0-or-later license (see LICENSE or https://www.gnu.org/licenses/gpl-3.0.html)
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/*
 * Develocity — Build Scans and remote Build Cache on the OSS Community instance
 * (https://community.develocity.cloud), project `meshtastic`.
 *
 * Applied from BOTH settings files: the build-logic included build does not
 * inherit the root's configuration, and without its own it silently drops to
 * local-cache-only.
 *
 * Replaces the former self-hosted HttpBuildCache: GRADLE_CACHE_URL / _USERNAME /
 * _PASSWORD are no longer read anywhere in this repo.
 */

def isCI = System.getenv("CI") != null

develocity {
    server = "https://community.develocity.cloud"
    projectId = "meshtastic"
    buildScan {
        uploadInBackground = !isCI
        publishing.onlyIf { it.authenticated }
        capture { fileFingerprints = isCI }
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

def develocityBuildCache = develocity.buildCache
def accessKey = System.getenv("DEVELOCITY_ACCESS_KEY")?.trim()

buildCache {
    local {
        enabled = !isCI
    }
    remote(develocityBuildCache) {
        enabled = true
        push = isCI && accessKey != null && !accessKey.isEmpty()
    }
}
```

- [ ] **Step 3: Update both settings files**

In `settings.gradle.kts`, bump CCUD and drop the cache apply — the block becomes:

```kotlin
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
    id("com.gradle.develocity") version "4.5.0"
    id("com.gradle.common-custom-user-data-gradle-plugin") version "2.8.0"
}

apply(from = "gradle/develocity.settings.gradle")
```

Delete the `apply(from = "gradle/build-cache.settings.gradle")` line. Make the same two edits in `build-logic/settings.gradle.kts`, where the paths are `../gradle/develocity.settings.gradle` and the removed line is `../gradle/build-cache.settings.gradle`.

- [ ] **Step 4: Delete the old cache script**

```bash
git rm gradle/build-cache.settings.gradle
```

- [ ] **Step 5: Verify configuration, CC reuse, and that `termsOfUse*` are truly gone**

```bash
./gradlew help
./gradlew help
```

This repo sets `org.gradle.configuration-cache=true`. Expected: both succeed, second reuses the CC, and a scan URL points at `community.develocity.cloud` — **not** `scans.gradle.com`. A `gradle.com` URL means the `server` line did not take.

- [ ] **Step 6: Confirm the included build is covered**

```bash
./gradlew --stop
./gradlew help --info 2>&1 | grep -i "build cache\|develocity" | head -20
```

Expected: build-cache configuration reported for `build-logic` as well as the root.

- [ ] **Step 7: Add the composite-action input**

In `.github/actions/gradle-setup/action.yml`, add to `inputs:`:

```yaml
  develocity_access_key:
    description: 'Access key for the OSS Community Develocity Instance (Build Scan publishing and remote cache writes)'
    required: false
```

and to the `Setup Gradle` step's `with:`:

```yaml
        develocity-access-key: ${{ inputs.develocity_access_key }}
```

- [ ] **Step 8: Pass the secret at all ten call sites**

Nine `uses: ./.github/actions/gradle-setup` (8 in `ci.yml`, 1 in `release.yml`) get `develocity_access_key: ${{ secrets.DEVELOCITY_ACCESS_KEY }}`. The one direct `gradle/actions/setup-gradle` in `docs.yml` gets `develocity-access-key: ${{ secrets.DEVELOCITY_ACCESS_KEY }}` (note the hyphens — it is the action's own input, not the composite's). Delete the `GRADLE_CACHE_*` `env:` blocks from `ci.yml` and `release.yml`.

- [ ] **Step 9: Add the README badge**

```markdown
[![Revved up by Develocity](https://img.shields.io/badge/Revved%20up%20by-Develocity-06A0CE?logo=Gradle&labelColor=02303A)](https://community.develocity.cloud/scans?search.rootProjectNames=meshtastic-sdk)
```

- [ ] **Step 10: Verify and commit**

```bash
grep -rn "GRADLE_CACHE_\|build-cache.settings.gradle\|scans.gradle.com\|termsOfUse" . --exclude-dir=.git --exclude-dir=build --exclude-dir=.gradle
./gradlew build
git add gradle/develocity.settings.gradle settings.gradle.kts build-logic/settings.gradle.kts README.md .github/
git commit -s -m "ci: move Build Scans and cache to the OSS Community Develocity instance"
```

Expected: no grep output; BUILD SUCCESSFUL.

- [ ] **Step 11: Set the secret, push, verify**

Set `DEVELOCITY_ACCESS_KEY` = `community.develocity.cloud=<key>` on `meshtastic/meshtastic-sdk`, push to the repo, confirm scans for both `meshtastic-sdk` and `build-logic`, and open the PR. Call out in the body that scans moved off `scans.gradle.com`, so old scan links will not gain new siblings.

---

### Task 5: protobufs

The Gradle build is `packages/kmp/`; everything is relative to that directory. This is a polyglot repo (buf, deno, cargo) — Develocity covers only the KMP leg.

**Files:**
- Create: `protobufs/packages/kmp/gradle/develocity.settings.gradle`
- Delete: `protobufs/packages/kmp/gradle/build-cache.settings.gradle`
- Modify: `protobufs/packages/kmp/settings.gradle.kts`
- Modify: `.github/workflows/kmp-pull-request.yml` (1 `setup-gradle` + env), `publish-kmp.yml` (2 + env), `snapshot-kmp.yml` (1 + env)
- Modify: `protobufs/README.md` (badge row)

**Interfaces:**
- Consumes: the template from Task 1.

- [ ] **Step 1: Orient and branch**

```bash
cd "$MESHTASTIC_WORKSPACE" && nix run .#brief -- protobufs
cd "$MESHTASTIC_WORKSPACE" && nix run .#worktree -- protobufs feat/develocity-oss
```

Default branch is `master`, not `main`. This repo has no `AGENTS.md`; read `notes/protobufs.md` in the workspace. Commit style is mixed — match recent history in `packages/kmp/`. It is also vendored as a submodule in `firmware`; a settings-only change does not affect that, but say so in the PR body.

- [ ] **Step 2: Create `packages/kmp/gradle/develocity.settings.gradle`**

```groovy
/*
 * Develocity — Build Scans and remote Build Cache on the OSS Community instance
 * (https://community.develocity.cloud), project `meshtastic`.
 *
 * Covers the KMP leg of this repo only; the buf, deno and cargo builds are
 * unaffected.
 *
 * Replaces the former self-hosted HttpBuildCache: GRADLE_CACHE_URL / _USERNAME /
 * _PASSWORD are no longer read anywhere in this repo.
 */

def isCI = System.getenv("CI") != null

develocity {
    server = "https://community.develocity.cloud"
    projectId = "meshtastic"
    buildScan {
        uploadInBackground = !isCI
        publishing.onlyIf { it.authenticated }
        capture { fileFingerprints = isCI }
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

def develocityBuildCache = develocity.buildCache
def accessKey = System.getenv("DEVELOCITY_ACCESS_KEY")?.trim()

buildCache {
    local {
        enabled = !isCI
    }
    remote(develocityBuildCache) {
        enabled = true
        push = isCI && accessKey != null && !accessKey.isEmpty()
    }
}
```

- [ ] **Step 3: Rewrite `packages/kmp/settings.gradle.kts`**

```kotlin
pluginManagement {
    repositories {
        google()
        gradlePluginPortal()
        mavenCentral()
    }
}

plugins {
    id("com.gradle.develocity") version "4.5.0"
    id("com.gradle.common-custom-user-data-gradle-plugin") version "2.8.0"
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

apply(from = "gradle/develocity.settings.gradle")

rootProject.name = "protobufs"
```

`pluginManagement` must stay first. The relative order of `plugins {}` and `dependencyResolutionManagement` is not load-bearing — `gradle-flatpak-sources` has them the other way round and configures fine — so keep whichever order reads better and let Step 5 catch a mistake.

- [ ] **Step 4: Delete the old cache script**

```bash
git rm packages/kmp/gradle/build-cache.settings.gradle
```

- [ ] **Step 5: Verify configuration and CC reuse**

```bash
cd packages/kmp
./gradlew help --configuration-cache
./gradlew help --configuration-cache
```

This build does not enable the configuration cache in `gradle.properties`, so the flag is required. Expected: both succeed; the second prints `Reusing configuration cache.`

- [ ] **Step 6: Confirm a scan publishes**

```bash
./gradlew help
```

Expected: a `community.develocity.cloud/s/...` URL, with root project name `protobufs`.

- [ ] **Step 7: Update the three workflows**

Delete the `GRADLE_CACHE_*` `env:` blocks from `kmp-pull-request.yml`, `publish-kmp.yml` and `snapshot-kmp.yml`. Give each of the four `setup-gradle` steps:

```yaml
        with:
          develocity-access-key: ${{ secrets.DEVELOCITY_ACCESS_KEY }}
```

merged into an existing `with:` block where present.

- [ ] **Step 8: Add the README badge**

```markdown
[![Revved up by Develocity](https://img.shields.io/badge/Revved%20up%20by-Develocity-06A0CE?logo=Gradle&labelColor=02303A)](https://community.develocity.cloud/scans?search.rootProjectNames=protobufs)
```

- [ ] **Step 9: Verify and commit**

```bash
cd "$(git rev-parse --show-toplevel)"
grep -rn "GRADLE_CACHE_\|build-cache.settings.gradle" . --exclude-dir=.git --exclude-dir=build --exclude-dir=.gradle
(cd packages/kmp && ./gradlew build)
git add packages/kmp/gradle/develocity.settings.gradle packages/kmp/settings.gradle.kts README.md .github/workflows/
git commit -m "ci: publish KMP Build Scans and cache to the OSS Community Develocity instance"
```

Expected: no grep output; BUILD SUCCESSFUL.

- [ ] **Step 10: Set the secret, push, verify**

Set `DEVELOCITY_ACCESS_KEY` = `community.develocity.cloud=<key>` on `meshtastic/protobufs`, push to the repo (base branch `master`), confirm the CI scan under `search.rootProjectNames=protobufs`, and open the PR.

---

### Task 6: TAKPacket-SDK

Not yet in the workspace, and the one repo where some jobs run Gradle without `setup-gradle` — those need the access key as plain `env` instead.

**Files:**
- Create: `TAKPacket-SDK/kotlin/gradle/develocity.settings.gradle`
- Delete: `TAKPacket-SDK/kotlin/gradle/build-cache.settings.gradle`
- Modify: `TAKPacket-SDK/kotlin/settings.gradle.kts`
- Modify: `.github/workflows/ci.yml` (2 `setup-gradle` + env), `release.yml` (env only — no `setup-gradle`), `docs.yml` (env only — no `setup-gradle`)
- Modify: `TAKPacket-SDK/README.md` (badge row)

**Interfaces:**
- Consumes: the template from Task 1.

- [ ] **Step 1: Bring the repo into the workspace**

```bash
cd "$MESHTASTIC_WORKSPACE"
git clone git@github.com:meshtastic/TAKPacket-SDK.git
nix run .#sync
nix run .#brief -- TAKPacket-SDK
```

`.#sync` generates the `.envrc` and `.mcp.json` a hand-rolled clone would lack. `brief` prints the branch and doc inventory; read the repo's `CLAUDE.md` and `CONTRIBUTING.md` before editing. This step is workspace plumbing, not part of the PR.

- [ ] **Step 2: Branch**

```bash
cd "$MESHTASTIC_WORKSPACE" && nix run .#worktree -- TAKPacket-SDK feat/develocity-oss
```

- [ ] **Step 3: Create `kotlin/gradle/develocity.settings.gradle`**

```groovy
/*
 * Develocity — Build Scans and remote Build Cache on the OSS Community instance
 * (https://community.develocity.cloud), project `meshtastic`.
 *
 * Covers the Kotlin leg of this repo only; the C, Swift, Python, C# and
 * TypeScript builds are unaffected.
 *
 * Replaces the former self-hosted HttpBuildCache: GRADLE_CACHE_URL / _USERNAME /
 * _PASSWORD are no longer read anywhere in this repo.
 */

def isCI = System.getenv("CI") != null

develocity {
    server = "https://community.develocity.cloud"
    projectId = "meshtastic"
    buildScan {
        uploadInBackground = !isCI
        publishing.onlyIf { it.authenticated }
        capture { fileFingerprints = isCI }
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

def develocityBuildCache = develocity.buildCache
def accessKey = System.getenv("DEVELOCITY_ACCESS_KEY")?.trim()

buildCache {
    local {
        enabled = !isCI
    }
    remote(develocityBuildCache) {
        enabled = true
        push = isCI && accessKey != null && !accessKey.isEmpty()
    }
}
```

- [ ] **Step 4: Rewrite `kotlin/settings.gradle.kts`**

```kotlin
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

plugins {
    id("com.gradle.develocity") version "4.5.0"
    id("com.gradle.common-custom-user-data-gradle-plugin") version "2.8.0"
}

apply(from = "gradle/develocity.settings.gradle")

rootProject.name = "takpacket-sdk"
```

- [ ] **Step 5: Delete the old cache script**

```bash
git rm kotlin/gradle/build-cache.settings.gradle
```

- [ ] **Step 6: Verify configuration and CC reuse**

```bash
cd kotlin
./gradlew help --configuration-cache
./gradlew help --configuration-cache
```

This build does not enable the configuration cache in `gradle.properties`, so the flag is required. Expected: both succeed; the second prints `Reusing configuration cache.`

- [ ] **Step 7: Confirm a scan publishes**

```bash
./gradlew help
```

Expected: a `community.develocity.cloud/s/...` URL, with root project name `takpacket-sdk`.

- [ ] **Step 8: Update `ci.yml` — the `setup-gradle` variant**

Replace the workflow-level `env:` entries `GRADLE_CACHE_URL` / `GRADLE_CACHE_USERNAME` / `GRADLE_CACHE_PASSWORD` with nothing, and give both `setup-gradle` steps:

```yaml
        with:
          develocity-access-key: ${{ secrets.DEVELOCITY_ACCESS_KEY }}
```

- [ ] **Step 9: Update `release.yml` and `docs.yml` — the env-only variant**

These workflows invoke `./gradlew` directly with `working-directory: kotlin` and no `setup-gradle` step, so there is no action input to set. Replace their `GRADLE_CACHE_*` workflow-level `env:` entries with the variable the Develocity plugin reads itself:

```yaml
env:
  DEVELOCITY_ACCESS_KEY: ${{ secrets.DEVELOCITY_ACCESS_KEY }}
```

Without this, those jobs would lose their old cache credentials and gain nothing — no remote cache at all.

- [ ] **Step 10: Add the README badge**

```markdown
[![Revved up by Develocity](https://img.shields.io/badge/Revved%20up%20by-Develocity-06A0CE?logo=Gradle&labelColor=02303A)](https://community.develocity.cloud/scans?search.rootProjectNames=takpacket-sdk)
```

- [ ] **Step 11: Verify and commit**

```bash
cd "$(git rev-parse --show-toplevel)"
grep -rn "GRADLE_CACHE_\|build-cache.settings.gradle" . --exclude-dir=.git --exclude-dir=build --exclude-dir=.gradle
(cd kotlin && ./gradlew build)
git add kotlin/gradle/develocity.settings.gradle kotlin/settings.gradle.kts README.md .github/workflows/
git commit -m "ci: publish Kotlin Build Scans and cache to the OSS Community Develocity instance"
```

Expected: no grep output; BUILD SUCCESSFUL.

- [ ] **Step 12: Set the secret, push, verify both workflow shapes**

Set `DEVELOCITY_ACCESS_KEY` = `community.develocity.cloud=<key>` on `meshtastic/TAKPacket-SDK` and push to the repo. Confirm a scan from `ci.yml` (the `setup-gradle` path). Then confirm the env-only path works too — trigger `docs.yml` (`gh workflow run docs.yml --repo meshtastic/TAKPacket-SDK`) and check that its build also produced a scan. If only the `ci.yml` scans appear, Step 9 did not take. Then open the PR.

---

### Task 7: Python spike — answer, do not implement

No file in `meshtastic/python` changes. The deliverable is a tracking issue.

**Files:**
- Modify: `DEVELOCITY-ROLLOUT.md` (record the answer in the Python section)

**Interfaces:**
- Consumes: the Develocity team contact from Task 0 Step 3.

- [ ] **Step 1: Confirm the current state of the Python agent**

Read <https://docs.develocity.ai/python-agent/> and record: the current agent version, whether it is still beta, and the exact wording on hosted-instance support. As of 2026-08-02 it is beta at 0.10.1, distributed as `develocity_agent-0.10.1-py3-none-any.whl` from `develocity-python-pkgs.gradle.com` rather than PyPI, with Python support disabled server-side by default.

- [ ] **Step 2: Confirm what `meshtastic/python` would need**

```bash
gh api repos/meshtastic/python/contents/pyproject.toml --jq .content | base64 -d | head -60
gh api repos/meshtastic/python/contents/.github/workflows/ci.yml --jq .content | base64 -d | grep -n "pytest\|poetry" | head
```

Expected: Poetry-managed, pytest-driven (the repo has `pytest.ini`, `poetry.lock`, a `Makefile`). Record which CI job runs the tests.

- [ ] **Step 3: Get the answer from the Develocity team**

Ask whether Python Build Scan publishing can be enabled for project `meshtastic` on `community.develocity.cloud`, given the docs state that publishing to Gradle's own hosted instance is unsupported. This should ride along with Task 0 Step 3 rather than being a separate contact.

- [ ] **Step 4: File the tracking issue**

```bash
gh issue create --repo meshtastic/python \
  --title "Evaluate Develocity Build Scans for the Python client" \
  --body "..."
```

The body must record: the answer from Step 3; that the agent is beta and served off-PyPI, so adding it to `poetry.lock` is a supply-chain decision requiring a pinned hash; that only pytest produces test results (pip, poetry, pylint and mypy are instrumented but contribute no test data); and the shape the change would take — a `.develocity.py` at the repo root setting `develocity_url` and `project_id`, with `DEVELOCITY_ACCESS_KEY` from a repo secret in the same form as the Gradle repos.

- [ ] **Step 5: Record the outcome and commit**

Update the Python section of `DEVELOCITY-ROLLOUT.md` with the answer and the issue link:

```bash
git -C "$MESHTASTIC_WORKSPACE" add DEVELOCITY-ROLLOUT.md
git -C "$MESHTASTIC_WORKSPACE" commit -m "docs: record the Develocity Python spike outcome"
```

---

### Task 8: Close out the rollout in the workspace

**Files:**
- Modify: `CLAUDE.md` (the workspace router), `DEVELOCITY-ROLLOUT.md`
- Delete (eventually): `DEVELOCITY-ROLLOUT.md`, `DEVELOCITY-ROLLOUT-PLAN.md`

**Interfaces:**
- Consumes: the merged state of Tasks 1–7.

- [ ] **Step 1: Confirm every PR merged and every repo publishes**

```bash
for r in kzstd gradle-flatpak-sources MQTTastic-Client-KMP meshtastic-sdk protobufs TAKPacket-SDK; do
  echo "== $r =="
  gh pr list --repo "meshtastic/$r" --state merged --search "Develocity" --limit 3 --json number,title --jq '.[] | "\(.number) \(.title)"'
done
```

Expected: one merged PR per repo. Then open each `search.rootProjectNames=` link and confirm scans from the default branch, not just the feature branch.

- [ ] **Step 2: Add the cross-repo fact to the workspace router**

`CLAUDE.md`'s "Fails silently" section is where facts like this belong. Add:

```markdown
- **Develocity is repo-scoped, not org-scoped** — every Gradle repo carries its
  own `gradle/develocity.settings.gradle` and its own `DEVELOCITY_ACCESS_KEY`
  secret, whose value must start `community.develocity.cloud=` or the key is
  silently ignored. A repo missing the secret still builds; it just publishes
  no scan and never writes the cache.
```

- [ ] **Step 3: Verify the doc claim by running its command**

Workspace docs rot when prose outruns code, so check the claim rather than trusting it:

```bash
cd "$MESHTASTIC_WORKSPACE"
for r in kzstd gradle-flatpak-sources MQTTastic-Client-KMP meshtastic-sdk; do
  echo "== $r =="; ls "$r"/gradle/develocity.settings.gradle 2>/dev/null || echo MISSING
done
ls protobufs/packages/kmp/gradle/develocity.settings.gradle TAKPacket-SDK/kotlin/gradle/develocity.settings.gradle
```

Expected: six paths, no `MISSING`.

- [ ] **Step 4: Decide on the old cache secrets**

The `GRADLE_CACHE_URL` / `_USERNAME` / `_PASSWORD` repo secrets are now unused but are the rollback path. Leave them for at least one release cycle across all six repos, then decide whether to remove them and decommission the self-hosted cache server. Record the decision and its date in `CLAUDE.md` — not here, since this file is going away.

- [ ] **Step 5: Remove the rollout docs**

```bash
cd "$MESHTASTIC_WORKSPACE"
git rm DEVELOCITY-ROLLOUT.md DEVELOCITY-ROLLOUT-PLAN.md
git commit -m "docs: retire the Develocity rollout plan, now complete"
```

These are plan documents, not standing policy; the durable facts live in `CLAUDE.md` after Step 2.
