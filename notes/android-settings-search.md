# Android settings search: what the field-metadata registry actually gives us

Measured 2026-09-14 against `protobufs` `feat/field-metadata-fill`
(PR #1082, stacked on #1081 and #952), published locally as
`org.meshtastic:protobufs:2.8.1-fieldmeta-SNAPSHOT` and consumed from an
`android` worktree with `-PuseMavenLocal=1`.

The prompt is [Meshtastic-Apple #2487](https://github.com/meshtastic/Meshtastic-Apple/pull/2487),
which builds settings search on that registry. The question was whether android
should follow it. The answer is yes for the index and no for the text, and the
measurement below is why.

## The registry resolves from android today

`feature/settings` `commonMain` compiles against it with no shim. All four
shapes typecheck: the field accessor (`Config.PositionConfig.rx_gpio`), the
enum accessor (`role.metadata`), and the dynamic `get` / `forType` / `forEnum`.
The published artifact carries `FieldMetadataRegistry` and its top-level
accessors; `:feature:settings:dependencies` resolves the local version
transitively, including through `takpacket-sdk`, with no version conflict.

The pin bump is spike-only and is held with `git update-index
--skip-worktree`. Nothing here may merge with a `~/.m2`-only version.

## Coverage, measured

`feature/settings/.../radio` holds **192** preference controls.

| | |
| --- | ---: |
| controls joined to a registry entry | 150 |
| controls with no message/field binding the extractor could see | 34 |
| controls whose message attribution is wrong (extractor limit, not a gap) | 8 |
| registry field entries | 244 |
| reachable from an android control | 149 |
| **no android control at all** | **95** |

Of the 150 joined controls the registry supplies a label for 140 and a
description for 118. So the *structure* is essentially complete: for almost
every control android already has, the schema knows which message and field it
edits.

## The text comes from the schema, and 71 labels have to be re-translated

**Decision (James, 2026-09-14): the schema is the single source of truth for
this copy.** Where android's wording disagrees, android's wording changes and
the translators re-adjust. The measurement below is therefore a cost estimate,
not an argument against.

The checked-in map is the artifact to measure, not the extractor that seeded
it, and the map has since been audited down from 137 entries to 127 sound ones.
Against it now: **127 mapped, 127 resolved, 58 reworded, 32 case-only, 0
unresolved, 0 collisions, 0 shared, 9 unit loss**, so **90** source strings
change and 9 are blocked until the UI composes `label` + `unit`. The
earlier figure of 71 came from a different join over extractor-derived controls
and is not reproducible from anything checked in; do not cite it.
Android is on Crowdin with
`**/composeResources/values/strings.xml` as the source, so changing an English
source value flags that key for re-translation in every locale: 90 strings
across **39 locales**, of which 58 are rewordings and 32 only change
capitalisation. A further 9 are blocked, not applied: the schema label drops a
quantity the android string carries, so `Device metrics update interval` would
become `Device Metrics`. Those need `label` and `unit` composed at the UI
before they can be schema-driven.

The mechanism that makes this stick, rather than diverging again next quarter:
generate the English side of `values/strings.xml` for proto-backed controls
from `FieldMetadataRegistry` instead of hand-writing it. Crowdin keeps working
unchanged, `stringResource` stays the call at the UI so the house rule holds,
and hand-editing a generated English value can then be made a CI failure
rather than a silent fork. Nothing runs `checkSettingsStrings` yet - wiring it
into `check` is part of landing the sync, not done in the spike.

### Direction: android adopts the schema wording, the schema is not edited

**Decision (James, 2026-09-14):** do not rewrite labels in `protobufs` to match
android. Android changes to whatever the schema already says. A schema wording
pass was prepared and reverted unapplied, so #1082 stays purely additive
against #1081 and nothing of garth's copy moves.

The consequence is that android inherits some labels that are weaker than what
it shows today, because Apple's rows sit under a section header that supplies
context a standalone android row does not have:

| field | android today | schema, and what android will show |
| --- | --- | --- |
| `detection_trigger_type` | Detection trigger type | `TriggerType` |
| `inputbroker_pin_a` | GPIO pin for rotary encoder A port | `Pin A` |
| `use_pullup` | Use INPUT_PULLUP mode | `Uses pullup resistor` |
| `i2s_ws` | I2S word select | `I2S WS` |

Accepted deliberately: one wording everywhere beats a better wording in one
client. Any of these can be improved later by a schema change, which is then
picked up by every client at once, which is the whole point.

One of the 71 goes the other way and android is simply wrong today.
`AudioConfig.bitrate` is labelled "CODEC2 sample rate" in android, while the
proto doc reads *"The codec2 bitrate to encode at. Sample rate is always 8
kHz."* Bitrate and sample rate are different quantities. Adopting the schema
label fixes a real mislabel for free.

## What android actually gains

- **field to screen mapping** - which of the 25 destinations owns a given
  control. Android has no such map today; `ConfigRoute`/`ModuleRoute` stop at
  the screen.
- **`diy_only` / `admin_only`** - control-level visibility. `ModuleRoute`
  already gates whole screens on `isSupported(Capabilities)` and
  `isApplicable(Role)`; these extend the same idea one level down. Android has
  no `diy_only` handling at all right now.
- **a feature-gap list** - the 95 fields with no android control, concentrated
  in `MeshBeaconConfig` (7), `TrafficManagementConfig` (5),
  `NetworkConfig.IpV4Config` (4), `SecurityConfig` (4).
- **one English wording per setting across every client**, which is the point
  of the exercise. Note the limit: convergence reaches **English only**.
  `field_metadata.proto` says so itself - the English is the source string and
  translations live in each consuming app's catalogue. Android is on Crowdin
  with 39 `values-*` dirs; apple has no Crowdin config and uses
  `Localizable.xcstrings`. The translated catalogues stay per-client forks.
  Nor does a fix reach clients *at once*: android consumes a published artifact
  pinned in `libs.versions.toml`, and the most recent protobufs tag gap was 72
  days (v2.7.26 to v2.8.0), with a TAKPacket-SDK republish hop in between.

### The alternative that was not taken

Ship only machine-readable metadata in the schema - the field-to-screen
mapping, `diy_only`, `admin_only`, `unit` - and leave all copy client-side.
That keeps 102 translated strings untouched and costs only the one thing the
measurements above show the schema is weakest at: it would not converge the
English. Given that convergence is English-only anyway, this is a real option
and is rejected by decision rather than by evidence.

## What is not there yet

`keywords` is populated on **6 of 198 field entries** (a seventh sits on an
enum value; the registry's 335 backing vals are 198 fields plus 137 enum
values), and on only 1 of the controls android shows. Search synonyms are the one index input the schema does not yet
carry. Under the single-source-of-truth rule that makes it a schema pass, not
an android-local curation, and it is worth doing before ranking is built, since
Apple's ranking weights keywords as a distinct tier.

## What the seeding pass actually got wrong

The map was seeded by the heuristic this note warns about, so it was audited
against the schema and the sources. Ten of 137 entries were wrong, and each
class now has a check that fails rather than a comment that warns:

- `adc_multiplier_override` bound a switch over `override > 0` to a field it
  does not own.
- `send_bell` was bound to `DetectionSensorConfig` when its control edits
  `CannedMessageConfig`; both messages declare that field name, which is the
  plausible-looking mis-binding that name similarity and message-per-file
  checks cannot catch. Only the two-resources-one-field check found it.
- six resources are rendered by more than one screen, `password` by five.
- two controls render the negation of their field.

## Extractor caveat

The control-to-field join reads `formState.value.copy(<field> = ...)` inside
each preference block. The first attempt anchored on any `copy(` and produced
25 false joins onto `keyboardType`, because an `EditTextPreference` block also
contains `keyboardOptions.copy(keyboardType = ...)`. That is the same failure
that put `label: "Enabled"` on five `TrafficManagementConfig` fields in
protobufs #1081, from the same shape of heuristic. Anchoring on the form-state
write cut it to 8 residual mis-attributions, all from taking the most frequent
message per file. Any script that seeds annotations this way needs a duplicate
or implausibility check, not just a regex.

## Related

- [`cross-repo-contracts.md`](./cross-repo-contracts.md)
- [`wire-builders-only-migration.md`](./wire-builders-only-migration.md) - the
  Kotlin accessor shapes and why the enum one dispatches on the receiver.
