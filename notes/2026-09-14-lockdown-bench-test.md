# Lockdown bench test — RAK4631 + android/desktop (2026-09-14)

Dusting off lockdown and exercising it end to end on the attached nRF node.

## State of the feature: merged everywhere

Not a branch any more — all three planes are on their default branches.

| Repo | Branch | Lockdown present |
| --- | --- | --- |
| `protobufs` | `master` @ `723a31e` | `LockdownAuth lockdown_auth = 104` (admin.proto), `LockdownStatus lockdown_status = 18` (mesh.proto) |
| `firmware` | `develop` @ `f5158f5` | `src/security/{EncryptedStorage,LockdownDisplay,APProtect}.cpp`, PhoneAPI + AdminModule gating |
| `android` | `main` @ `4ddf8f8fa` | `feature/settings/lockdown/*`, `LockdownCoordinatorImpl`, `LockdownState` |

`origin/feature/rak4631-lockdown` in firmware is **stale** (behind develop, last merge predates
the current code). Do not build from it — develop is the live implementation.

## Wire compatibility: verified, no drift

Field numbers are identical between firmware's `protobufs` submodule (`3808a39`) and
`protobufs` master, and both descend from `ae5ccf5` (the commit that added the messages):

- `AdminMessage.lockdown_auth = 104`
- `FromRadio.lockdown_status = 18`

android pins `org.meshtastic:protobufs 2.8.0.35-g3b3df2a-SNAPSHOT`; `3b3df2a` is a descendant
of `79185c6`, so **android's pin does include `State.DISABLED = 5`**.

## No build env enables lockdown

No variant or `.ini` sets `MESHTASTIC_ENABLE_LOCKDOWN`. It defaults to 0 on `ARCH_NRF52` and
`configuration.h` then `#undef`s the whole feature set. So a lockdown build is opt-in at the
command line; there is nothing to check out.

Build used (no repo edit needed — PlatformIO appends `PLATFORMIO_BUILD_FLAGS` to `build_flags`):

```sh
PLATFORMIO_BUILD_FLAGS="-DMESHTASTIC_ENABLE_LOCKDOWN=1 -DMESHTASTIC_LOCKDOWN_DEBUG=1" \
  pio run -e rak4631
```

`MESHTASTIC_LOCKDOWN_DEBUG=1` is **mandatory on a dev board**: without it
`MESHTASTIC_ENABLE_APPROTECT` is defined and the firmware performs a one-way UICR APPROTECT
burn once provisioned, permanently killing SWD.

(Note when grepping a build log: PlatformIO appends `PLATFORMIO_BUILD_FLAGS` such that each
flag appears **twice** on a single `g++` line. That is harmless, not a doubled definition.)

Verified compiled out two ways, not assumed:
- every `NRF_UICR->APPROTECT` write in `src/security/APProtect.cpp` sits inside
  `#ifdef MESHTASTIC_ENABLE_APPROTECT`;
- the linked ELF contains **zero** occurrences of `"debug port will be disabled"` and
  `"APPROTECT written"`, while carrying 45 `Lockdown` strings.

## Bench result

Node: `olm3c rak solar`, RAK4631, nodeNum 1023534160, 117 nodes, US / LONG_FAST.
Flashed `2.8.0.8eda860` (stock) -> `2.8.1.f5158f5` (lockdown build) over serial DFU.

- Config snapshot `rak4631-pre-lockdown-20260914` taken before the flash;
  `config_diff` after the flash is **`identical: true`** — i.e. config *as read back over the
  phone API* is unchanged. (This compares proto payloads over the API, not flash contents; the
  at-rest encryption state was not measured here.) Expected: storage only becomes encrypted
  once a passphrase is provisioned.
- On client connect the firmware emits exactly one `FromRadio.lockdown_status`:

  ```
  lockdown_status { state: 5 }   # DISABLED
  ```

  Correct: lockdown-capable build, no passphrase provisioned, so it behaves as stock and the
  client renders the toggle OFF. `DISABLED` is deliberately distinct from `NEEDS_PROVISION`,
  which is only used mid-enable.

## Finding: meshtastic-python cannot decode a lockdown build's status

The PyPI `meshtastic` lib's bundled `mesh_pb2` knows only `State` 0–4:

```
0 STATE_UNSPECIFIED  1 NEEDS_PROVISION  2 LOCKED  3 UNLOCKED  4 UNLOCK_FAILED
```

`DISABLED = 5` is missing. This is **not** merely a stale PyPI wheel — `meshtastic-python`'s
own `protobufs` submodule is pinned at `da60cee`, which is **not** a descendant of `79185c6`,
so the repo itself lacks the value.

Since a lockdown-capable device sends `state: 5` to **every** client on **every** connect, any
Python-side code that resolves the enum name raises:

```
ValueError: Enum State has no name defined for value 5
```

Reproduced directly against the node with a `_handleFromRadio` hook (see bench result above).
The raw field still decodes, because protobuf retains an unknown enum number — so only code
that *names* the value is affected. **Not tested:** whether `meshtastic --info` itself trips
this; the CLI was not run against the node.

Fix is a `protobufs` submodule bump in `meshtastic-python`. `labeltastic` and `meshtastic-mcp`
both sit downstream of that library.

## Non-finding, checked and cleared

- **Android's toggle on stock 2.8 firmware.** `Capabilities.supportsLockdown` is a pure
  version gate (`atLeast(V2_8_0)`), so the row is visible on *any* 2.8+ device including stock
  builds with lockdown compiled out. That is safe, not a bug: such a device sends no
  `LockdownStatus`, android stays in `LockdownState.None`, and `toggleEnabled` admits only
  `Disabled`/`NeedsProvision`/`Unlocked` — so the switch renders greyed out and un-actionable.
- **BLE pairing lockout.** `configuration.h` says lockdown gates "pairing-PIN handling", but no
  BLE/pairing code is actually gated on `MESHTASTIC_LOCKDOWN`. Enabling lockdown from a phone
  does not change bonding, so there is no screenless-board lockout risk.

## Known gap (documented in-tree, restated here)

`LockdownDisplay.h` says display redaction is wired **only** into `graphics/Screen.cpp`.
InkHUD, `graphics/niche/` and `device-ui` still render content under lockdown. Headless boards
like this RAK are unaffected.

---

# CRITICAL: provisioning lost the entire device config

Observed **once**, on `olm3c rak solar` (RAK4631, `2.8.1.f5158f5`, lockdown build), 2026-09-14.
The node was fully recovered — see *Recovery* below — but the failure is severe enough that
**lockdown must not be provisioned on any node whose config matters** until it is understood.

## What was sent

A single local admin `AdminMessage.lockdown_auth` over USB serial, first-time provision:

```
lockdown_auth { passphrase: "benchtest123", boots_remaining: 3 }
```

Sent as a ToRadio `ADMIN_APP` packet to the node's own nodenum. Nothing else.

## What the firmware logged (captured via `security.debug_log_api_enabled` + `FromRadio.log_record`)

```
EncryptedStorage: Provisioning complete
Lockdown: storage unlocked, await reload before client visibility
Lockdown: reload config after unlock
Load /prefs/nodes.proto … Loaded          (also device/config/module/channels)
Can't open/read /prefs/uiconfig.proto
Lockdown: Saving unencrypted segments to encrypted storage (mask=0x1f)
EncryptedStorage: Encrypted /prefs/config.proto   (180 bytes plaintext)
EncryptedStorage: Encrypted /prefs/module.proto   (130 bytes plaintext)
EncryptedStorage: Encrypted /prefs/channels.proto (55 bytes plaintext)
Opening /prefs/device.proto, fullAtomic=1          <-- client disconnected around here
```

So the provision itself succeeded and the encrypt-in-place pass started.

## What the device looked like afterwards

On every subsequent connect, including after a clean reboot:

- `lockdown_status` = **`DISABLED`**, not `LOCKED`. `DISABLED` means
  `EncryptedStorage::isLockdownActive()` is false, i.e. **`/prefs/.dek` is not present** —
  see the root-cause section: nothing deleted it, it was never durably written.
- Config had reverted to **defaults**, while the data files had been encrypted:

  | | before | after |
  | --- | --- | --- |
  | primary channel | `olm3sh` | `(default)` |
  | `lora.channel_num` | 20 | 0 |
  | `mqtt.root` | `msh/US` | `msh` |
  | `security.public_key` | `pDOTNLSo…` | regenerated |
  | telemetry / canned-message / ambient-lighting | set | lost |

  (Node count also read 117 before and 31 after, but that is **not** evidence of loss:
  `nodes.proto` loaded cleanly in the post-unlock reload, and the count has since climbed
  31 → 32 on its own, i.e. the device is simply re-learning the mesh. See
  [[phone-nodedb-grows-independently]] — node count is a bad instrument.)

  The owner name (`olm3c rak solar` / ⛅) was lost too.

**The combination is the bug.** Either half alone is survivable:
- DEK present + files encrypted → reports `LOCKED`, operator unlocks with the passphrase.
- DEK absent + files plaintext → normal unprovisioned device.

What happened instead is DEK **absent** while the files had been **encrypted**, so the firmware
could not read its own config, silently fell back to defaults, and then persisted those
defaults. At that point the original config is unrecoverable from the device: there is no
passphrase prompt to answer, because the device no longer believes it is in lockdown.

## Root cause: the DEK was never durable. Provisioning is not crash-safe.

The obvious theory — that the USB-CDC link drop ran teardown which rolled the provision back and
deleted the key — is **ruled out by the source**:

- `/prefs/.dek` has exactly **one** deletion site in the tree:
  `EncryptedStorage::removeLockdownArtifacts()` (`EncryptedStorage.cpp:1785`), whose own comment
  calls deleting it "the commit point: lockdown is now off".
- That function has exactly **one** caller: `NodeDB::disableLockdownToPlaintext()`
  (`NodeDB.cpp:3037`), which early-returns unless `EncryptedStorage::isUnlocked()` and only runs
  after an explicit `lockdown_auth { disable: true }`.

**No disable was ever sent in this session.** So nothing in the firmware deleted the DEK. The
only remaining explanation is that the DEK file **never reached durable flash**, while the
encrypt-in-place pass had already rewritten `config.proto`, `module.proto` and `channels.proto`.

That makes this a **crash-safety / ordering defect in provisioning**, not a teardown bug:
`provisionPassphrase()` reports "Provisioning complete" and the encrypt pass proceeds on the
strength of it, but the key that makes those files readable is not committed durably first. Any
interruption in that window — the observed client disconnect, a watchdog, a power loss on a
*solar* node — leaves encrypted data and no key.

The correct fix direction is the same invariant the disable path already gets right: the DEK
write must be the committed, fsync'd, verified-readable step **before** a single byte of user
data is encrypted, and ideally re-verified by reading it back after the encrypt pass.

### Full attempt sequence (matters — earlier attempts may have left partial state)

| # | boot | result |
| --- | --- | --- |
| 1 | boot A | no status frame returned (client closed before the reply) |
| 2 | boot A | `UNLOCK_FAILED backoff=5` |
| 3 | boot A | `UNLOCK_FAILED backoff=5` |
| 4 | boot B (after reboot) | **succeeded** — "Provisioning complete", encrypt pass ran, config lost |

Attempts 1–3 all failed *inside* `provisionPassphrase()` (it has no backoff check), i.e. in one
of `deriveEphemeralKEK` / `generateDEK` / `deriveKEK` / `saveDEK`. **`saveDEK()` failing is
exactly the step whose durability is in question here**, so it is plausible those three attempts
and the eventual loss share one root cause. Whether attempts 1–3 left a partial or half-written
`.dek` that attempt 4 then built on is unknown and should be part of the repro.

## A second, probably related oddity

The first three provision attempts, all on one boot, were **rejected** with
`UNLOCK_FAILED backoff=5` — before any passphrase had ever been set. `provisionPassphrase()`
contains no backoff check, so the rejection came from inside it (one of
`deriveEphemeralKEK` / `generateDEK` / `deriveKEK` / `saveDEK`), while the `backoff=5` in the
status came from `getBackoffSecondsRemaining()` reading a **missing** `/prefs/.backoff`, which
the H4 audit note says deliberately returns max-attempts. The identical request succeeded on the
next boot. So first-time provisioning appears to be **not reliable within a boot**, and the
failure is reported to the client as "wrong passphrase + backoff", which is misleading — the
operator has not typed anything wrong.

## Recovery (what restored the node)

1. Channels: the sibling bench node `olm3c cardputer` (`/dev/ttyACM1`) still had the same
   channel set, so its `getURL(includeAll=True)` restored `olm3sh` + `IROMesh` **with PSKs**.
   Without a second node on the same channel this would have been permanent loss.
2. Config: `config_snapshot rak4631-pre-lockdown-20260914`, taken before flashing, replayed
   field by field.
3. Identity: `security.public_key` / `private_key` rewritten from that snapshot, so the node
   keeps its PKI identity and other nodes' first-wins trust stays valid.
4. Owner: `set_owner "olm3c rak solar" ⛅`.
5. `security.debug_log_api_enabled` returned to `false`.

Final `config_diff` vs the snapshot is clean apart from `localConfig.lora.fem_lna_mode:
NOT_PRESENT`, which is a **new field in 2.8.1**, not a loss. `my_node_num` never changed.

**The snapshot did not cover channels or owner.** Snapshot both before touching lockdown again.

## Status of the node now

Left on the lockdown build (`2.8.1.f5158f5`, `MESHTASTIC_ENABLE_LOCKDOWN=1
MESHTASTIC_LOCKDOWN_DEBUG=1`), **unprovisioned**, reporting `DISABLED`. In that state it
behaves exactly like stock firmware. APPROTECT was never burned — SWD is intact.

**One loose end for the mesh, not the node:** between the provision (~11:04) and the key restore
(~11:11) the node transmitted on `olm3sh` under its **normal nodenum** but with a **regenerated**
PKI keypair. Any peer that heard it in that window has first-wins trust pinned to the wrong key
and will fail DMs to it until that peer's radio clears the entry — see
[[first-wins-key-trust-model]]. The original keypair is now restored, so no further drift.

---

# App plane (android / desktop)

## Unit tests: green

`:core:data:jvmTest :core:model:jvmTest :core:service:jvmTest --tests "*Lockdown*"` →
**BUILD SUCCESSFUL, 38 passed, 0 failed** across `LockdownCoordinatorImplTest`,
`LockdownStateTest`, `LockdownPassphraseStoreImplTest`, plus `CapabilitiesTest` and
`CommandSenderImplTest`. (Beware when grepping that log: five test *names* contain the string
`UNLOCK_FAILED`, so a naive `grep -c FAILED` reports phantom failures.)

Coverage includes the states this bench run exercised on real hardware — `UNLOCK_FAILED` with
and without backoff, auto-unlock passphrase clearing, and backoff handling.

## Desktop app: builds and runs, interaction not verified

`:desktopApp:run` builds and launches on this box (`--no-daemon` with `DISPLAY`/`XAUTHORITY`
exported, per the shared-daemon headless trap). It came up on the Connection screen scanning
Bluetooth.

**Driving it was not achieved.** This box has no `xdotool`/`ydotool`/`wtype` installed;
`xdotool` pulled from nixpkgs injects clicks, but under mutter/XWayland the window could not be
repositioned fully onscreen (`windowmove` is honoured only partially — y clamped at 789 of a
1200px screen) and pointer coordinates do not round-trip (`mousemove 80 80` →
`getmouselocation` reports `179,926`). So the lockdown row was never reached in the UI.

Therefore the android/desktop lockdown UI is verified by **code read + unit tests only**, not
by interaction. The specific claims that remain un-exercised on a real UI:
- the toggle rendering OFF-but-actionable against a `DISABLED` device;
- the blocking passphrase dialog against a `LOCKED` device;
- `LockdownSessionStatus` rendering boots-remaining / expiry.

If this matters, the tractable path is the Compose hot-reload MCP (`:desktopApp:hotRunAsync`,
semantic clicks by node id) rather than synthetic OS events — see [[driving-desktop-app]].

# Artifacts

- Firmware worktree: `firmware/.claude/worktrees/test-lockdown-bench`, branch
  `test/lockdown-bench` off `origin/develop`. **No source changes** — the lockdown flags were
  passed via `PLATFORMIO_BUILD_FLAGS`, so the tree is clean. Built UF2:
  `.pio/build/rak4631/firmware-rak4631-2.8.1.f5158f5.uf2`.
- Config snapshot: `rak4631-pre-lockdown-20260914` (MCP snapshot store).

# What to do next, in order

1. **Fix provisioning's commit ordering** — this is the blocker; nothing else should be built
   on top of lockdown until it is done. The DEK must be durably committed and read back
   *before* any user data is encrypted. Reproduce on a scratch nRF52 with log capture running
   throughout, and instrument `saveDEK()` specifically: attempts 1–3 failing inside
   `provisionPassphrase()` and the eventual "encrypted data, no key" outcome are plausibly the
   same defect.
2. **Bump `meshtastic-python`'s `protobufs` submodule** off `da60cee` so the Python side can
   see `LockdownStatus.State.DISABLED` and send `LockdownAuth.disable` at all.
3. Investigate why first-time provisioning fails within a boot and reports it as
   `UNLOCK_FAILED` + backoff, which points the operator at the wrong cause.
