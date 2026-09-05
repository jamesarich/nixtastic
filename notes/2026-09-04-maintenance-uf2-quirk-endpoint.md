# Maintenance-UF2 quirk endpoint, consumed by every client - cross-repo umbrella

Status: planned (dry run, not approved) | unproven: everything below
Started: 2026-09-04

Dry run of `nixtastic:meshtastic-cross-repo`. No worktree was created and no
repo was edited. Scope was taken as confirmed on instruction.

## Goal

The request: "add a maintenance-UF2 quirk endpoint to the api and consume it
in the clients." The api half already exists: `resource/maintenanceUf2`
(erase images + OTAFIX board map, digest-pinned) and
`resource/bootloaderOtaQuirks` (per-`hwModel` flags) are live on
`api.meshtastic.org` and `apiv2.meshtastic.org`, both answering 200 as of
2026-09-04. `android` consumes both (#6803) with a bundled seed and a SHA-256
check before any UF2 write. What remains is the consumer side in `apple`
(hand-mirrored constants) and `web-flasher` (hard-coded `/uf2/` paths, no
digest). This note treats "add the endpoint" as landed and scopes the change
as: make the two remaining clients consume the manifest under android's
trust model, and touch the api only if that work exposes a schema gap.

## Repos touched

| repo | change | branch / worktree | verification | landed (SHA or PR) |
| --- | --- | --- | --- | --- |
| api | producer, already landed. No new route. Only if a client needs a field the manifest lacks: edit `data/maintenanceUf2.json` + `src/lib/maintenanceUf2.ts` types, run `pnpm validate:maintenance-uf2`. Watch the emit-path trap (any `.ts` outside `src/` moves the entry point). | none yet | `pnpm build`, `pnpm validate:maintenance-uf2` | n/a (already live) |
| android | verify-only consumer. Confirm `androidApp/src/main/assets/maintenance_uf2.json` and `device_bootloader_ota_quirks.json` match api data; the scheduled-updates action refreshes them. Code changes only if the schema changes. | none yet | `nixtastic:android-baseline` via `gradle-runner` | n/a unless schema changes |
| apple | replace the compile-time table in `Meshtastic/Model/Firmware/MaintenanceUF2.swift` (14 OTAFIX boards + 2 nRF52 erase images, all SHAs equal to the api's; no rp2040 entry) with a fetch of `resource/maintenanceUf2` through `MeshtasticAPI.swift`, a bundled seed for offline, SHA-256 verified before write. Consumers: `BootloaderUpgradeView.swift` / `FactoryEraseView.swift`. Add `bootloaderOtaQuirks` if the OTA flow gates on it. | none yet | Swift Testing in `MeshtasticTests/` (`MaintenanceUF2Tests.swift`); Xcode only, not runnable on this host | |
| web-flasher | `stores/deviceStore.ts:158-160` hard-codes `/uf2/pico_erase.uf2`, `/uf2/nrf_erase2.uf2`, `/uf2/nrf_erase_sd7_3.uf2`. Fetch the manifest via `stores/store.ts`, select by arch + SoftDevice, verify sha256 with SubtleCrypto before flashing. Decide: keep serving images from `public/uf2/` (manifest for digests only) or pull from the api's `resource/maintenanceUf2/asset/:file`. Add the OTAFIX nudge the drag-and-drop UF2 flow lacks. Types in `types/`, i18n for any new text. | none yet | `pnpm test:run` (Vitest), browser check via `pnpm dev` | |

Out of scope, and why:

- `Adafruit_nRF52_Bootloader_OTAFIX`: no new release; the manifest already
  pins `0.9.2-OTAFIX2.3-BP1.5`.
- `meshtastic` (docs): no user-visible behaviour change; the flows already
  exist, only their data source moves.
- `firmware`, `protobufs`, `meshtastic-sdk`, `meshtastic-python`: no wire
  change.

## Contract changes

None to the wire. The contract consumed is the existing JSON manifest,
`manifestVersion: 1`:

- `erase.nrf52.<softdevice>` and `erase.rp2040`: `fileName`, `sha256`,
  optional `expectedFirstTargetAddress`.
- `otafixBase` + `otafixReleaseTag`, `otafixByBoardId.<INFO_UF2 board id>`:
  `otafixBoardSlug`, `sha256`. The slug vocabulary is OTAFIX's, not
  platformio's; `otafixSupportedTargets` is the platformio list.
- `resource/bootloaderOtaQuirks`: `devices[]` of `hwModel`, `hwModelSlug`,
  `requiresBootloaderUpgradeForOta`, `infoUrl`.

Compatibility rule, proposed here and not yet in
`notes/cross-repo-contracts.md`: additive fields only, `manifestVersion`
bumps on any shape change, clients ignore unknown keys. Trust model per
workspace `CLAUDE.md`: digest-pinned manifest with a bundled seed, never
compile-time constants. Checked 2026-09-04: every SHA in apple's
`MaintenanceUF2.swift` (14 OTAFIX boards, both nRF52 erase images) matches
the api data; apple carries no rp2040 erase entry, which the api does. So
for nRF52 the migration is behaviour-preserving at the bytes level.

## Preconditions found at brief time

- All four primary checkouts are clean but behind origin: api `-3`, android
  `-9`, apple `-2`, web-flasher `-7`. Not fetched or fast-forwarded in the
  dry run. Fetch before cutting worktrees.
- Two open PRs rewrite the files this work would touch: apple #2393 "Move the
  API endpoints to apiv2" (`MeshtasticAPI.swift`, `Firmware.swift`) and
  web-flasher #429 "point the flasher at apiv2" (`stores/store.ts`,
  `firmwareStore.ts`). Both hosts serve the resources, so the choice of host
  is theirs; branch from those PRs or land after them to avoid conflicts.
- android has 7 active worktrees, web-flasher 3. Cut new ones with
  `nix run .#worktree`, never reuse.

## Release order

1. api: nothing to publish unless a schema gap surfaces. If it does, land it
   first, redeploy, and confirm both hosts return the new shape before any
   client pins it.
2. android: refresh the bundled seeds if step 1 changed anything; otherwise a
   verify-only pass, no PR.
3. apple: after #2393 lands. Conventional-style subject, imperative mood, PR
   to `main`, rebase before PR. Constitution check in the PR body.
4. web-flasher: after #429 lands. Conventional commits, PR to `main`.

Steps 3 and 4 are independent of each other.

## Open questions / unproven

- Is a single merged per-board "quirk" endpoint wanted, or is the current pair
  (`maintenanceUf2` + `bootloaderOtaQuirks`) the intended shape? This note
  assumes the pair. A merge would be an api schema change plus an android
  migration and belongs in a separate scoping pass.
- web-flasher image source: keep `public/uf2/` or switch to the api-served
  asset route? The api vendors the same images. Decide at plan time.
- apple verification cannot run on this host; everything there stays
  unproven until built and tested under Xcode on the Mac.
- Nothing has been proven on a device. Cross-plane check, when the work
  lands: erase + OTAFIX upgrade on the bench RAK from each client, on
  battery, per the BLE-OTA memory.
