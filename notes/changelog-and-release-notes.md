# Changelog and release notes: what the ecosystem actually does

Surveyed 2026-09-18 across twenty Kotlin/JVM/Android repos, by reading files and
`git log -- CHANGELOG.md` rather than docs about them. Written because the
question "should `android` adopt the `org.jetbrains.changelog` plugin the klib
repos just took?" has a clear answer, and the reasoning is worth keeping.

The raw survey is `notes/drafts/changelog-practice-survey-2026.md` (untracked).

## The answer

No. `android` is already on the majority practice and a well-configured
instance of it. The realistic upgrade is a **curated user-facing layer**, not a
different developer changelog.

## The dichotomy is false

The choice is usually framed as generated-from-PR-labels versus contributors
hand-editing `## [Unreleased]`. The dominant practice in serious libraries is
neither: **one maintainer writes the whole section at release time from the git
log, in one commit**. okhttp, okio, wire, kotlinx.coroutines,
kotlinx.serialization, ktor, Kermit and Tusky all show that exact signature.
Zero contributor burden, zero merge conflicts, and the best prose in the survey.
It does not scale past a project with one clear release owner.

So the real axis is **per-PR versus per-release, and who holds the pen** - not
hand-written versus generated. That is what makes the same artifact cheap in
`kzstd` and expensive in `android`.

**Contributors editing the file per PR is rare: two of twenty.** Only the
changelog plugin's own repo (plus its IntelliJ template) and `square/retrofit`.
The plugin's ~3,248 `.kts` usages are overwhelmingly template scaffolding, so
the count badly overstates adoption. By prevalence, generated leads about 3x
(release-drafter 10,944 workflow files).

Corroborating the velocity story: no surveyed repo runs contributor-edited
`[Unreleased]` above ~30 PRs/month. Koin **deleted** its `CHANGELOG.md` in
January 2026 (PR #2308) for "not being updated"; `kable`, `arrow` and
`nowinandroid` have none at all. `android` merged 394 PRs in 30 days.

## The JetBrains flow is a round trip, and the klib repos took half of it

`gradle-changelog-plugin`'s own `build.yml` runs `getChangelog --unreleased` to
create a **draft** release. A human edits and publishes it. `release.yml` then
feeds `github.event.release.body` *back* through
`patchChangelog --release-note-file` and opens a "Changelog update" PR.

The file seeds the body, the human gets the last edit, and the edit is written
back. **That last-edit step is the quality valve**, and it is the part that gets
dropped when the plugin is copied. What landed in `kzstd`, `TAKPacket-SDK`,
`MQTTastic-Client-KMP` and `gradle-flatpak-sources` on 2026-09-18 is the one-way
render - changelog to release body, no draft, no edit-back. Not wrong; the
mechanism minus its quality step.

## Model C: per-change prose stored outside the hot file

Where per-PR authoring actually lives at scale, the prose is never in the shared
file:

- **compose-multiplatform** requires a `## Release Notes` section in the *PR
  description*, checked on `opened/edited/synchronize` by
  `check-release-notes.yml`, aggregated by a 774-line `changelog.main.kts`.
- **androidx** requires a `Relnote:` footer in the *commit message* for anything
  under `src/main/` or `src/commonMain/`, enforced by `requirerelnote.py`.

Both allow an explicit `N/A`. Conflicts are impossible by construction, and rot
is prevented by a blocking check rather than by discipline. Caveat: that
compose-multiplatform action has no bot skip and the repo has no
`renovate.json`, so there is no direct evidence the gate survives
Renovate-scale traffic - the `N/A` escape makes it plausible, not proven.

## Generated quality is entirely a function of the filter

`kable` reads fine on pure release-drafter. `home-assistant/android` has no
`.github/release.yml` at all and its release bodies are dominated by
`@renovate[bot]` lines - same generator, unusable result.

`android` is at the good end: bot authors excluded, eleven labels excluded, four
categories, and `pull-request-target.yml` derives labels from the branch prefix
or a conventional-commit PR title, so the `'*'` catch-all rarely fires. That is
a *better* fit for bot traffic than a required-labels gate, which would block
every Renovate PR lacking a hand-applied label.

## The user-facing track is the real gap

**No surveyed project derives store or in-app notes from PR titles.** It is a
separate artifact at a different altitude, in every case.

`android` has four surfaces, and the effort is inverted:

| surface | content | reach |
| --- | --- | --- |
| GitHub release body | 358 lines of PR titles (v2.8.1) | developers |
| `CHANGELOG.md` | duplicate of the above | nobody |
| Play "what's new" x41 locales | a 100-byte URL pointer | all users |
| `metainfo.xml <release>` | hand-written prose, PR-check gated | Linux desktop |

Two facts worth stating plainly:

- **`CHANGELOG.md` has two writers and no readers.** `update-changelog.yml` per
  push to main, *and* `promote.yml:267` "Stamp CHANGELOG.md for release" - each
  opening its own PR. Twelve such PRs in fourteen days. Nothing reads the file:
  the release body comes from `generate-notes`, not from it.
- **The Play changelog is never uploaded.** `fastlane/Fastfile:28-29` sets
  `skip_upload_metadata: true` and `skip_upload_changelogs: true`, so that
  pointer file and its 41 Crowdin translations are maintained, translated and
  discarded.

The hand-written layer already exists informally - the `> [!NOTE]` prologue on
the v2.8.1 release was typed by hand into a generated body. There is no
mechanism for it: no workflow input, no injection step.

## The strongest comparable

`home-assistant/android` - same velocity, same Renovate load, same
Play/fastlane/Compose stack - independently landed on a two-track split:
unfiltered generated notes for developers, and user-facing copy as **ordinary
translatable string resources** (`strings_changelog.xml`, eleven
`changelog_entry_*` strings, rendered by `ChangelogContent.kt` into an in-app
changelog screen with screenshot tests).

That rides the existing Crowdin pipeline instead of a separate fastlane round,
and yields an in-app "what's new" screen. Cost: one PR per release. Tusky is the
lighter variant - per-`versionCode` fastlane files translated via Weblate into
31 of 48 locales.

## What to do, in order of value

1. Give the user-facing track real content. It is the highest-visibility surface
   and currently says nothing, and nothing is uploaded anyway.
2. Cut `CHANGELOG.md`'s per-push churn - two writers, no readers.
3. Give the hand-written prologue a home, so it stops depending on someone
   remembering to type it into the release page.
4. Only if per-change prose is wanted: model C, in the PR description or a
   commit footer, CI-gated with an `N/A` escape. Never the shared file.

Not on the list: adopting the changelog plugin for `android`.
