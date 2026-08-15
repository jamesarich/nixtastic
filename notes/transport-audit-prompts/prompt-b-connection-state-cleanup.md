# PR-B: ConnectionState cleanup

## Branch name
`refactor/connection-state-cleanup`

## Problem 1 — L13: Redundant helper methods
`ConnectionState` (sealed class) has four helper methods — `isConnected()`,
`isConnecting()`, `isDisconnected()`, `isDeviceSleep()` — that duplicate what
Kotlin's `is` check already provides (`state is ConnectionState.Connected`).
These helpers encourage `if (state.isConnected())` instead of exhaustive `when`,
which means new states added to the sealed class won't produce compiler warnings
at call sites.

## Problem 2 — L14: `updateStatusNotification` returns `Any`
`MeshConnectionManager.updateStatusNotification()` returns `Any` because the
Android implementation returns `android.app.Notification` but the interface
lives in KMP `commonMain`. The caller in `MeshService.kt` casts with `as
android.app.Notification`. This is a leaky abstraction.

## Files to modify

### L13
- `core/model/src/commonMain/kotlin/org/meshtastic/core/model/ConnectionState.kt` (lines 32-38)
- All callers of `.isConnected()`, `.isConnecting()`, `.isDisconnected()`,
  `.isDeviceSleep()` — search with `rg 'isConnected\(\)|isConnecting\(\)|isDisconnected\(\)|isDeviceSleep\(\)'`

### L14
- `core/repository/src/commonMain/kotlin/org/meshtastic/core/repository/MeshConnectionManager.kt` (line 43)
- `core/data/src/commonMain/kotlin/org/meshtastic/core/data/manager/MeshConnectionManagerImpl.kt` (line 353)
- `core/repository/src/commonMain/kotlin/org/meshtastic/core/repository/MeshServiceNotifications.kt` (line 31)
- `core/service/src/androidMain/kotlin/org/meshtastic/core/service/MeshService.kt` (line 133)

## What to do

1. Read `AGENTS.md` at the project root for architecture rules and build commands.
2. **L13:**
   a. Search all callers of the four helper methods across the codebase.
   b. Replace each call site with the appropriate `is` check or `when` expression.
   c. Deprecate or remove the helper methods from `ConnectionState`.
   d. If removal is too noisy (many callers), add `@Deprecated` with `ReplaceWith`
      instead and let IDE/lint drive the migration over time.
3. **L14:**
   a. Change `updateStatusNotification()` return type to `Unit`.
   b. In `MeshConnectionManagerImpl`, have the method call
      `notifications.updateServiceStateNotification(...)` internally and not
      return the result.
   c. In `MeshService.kt`, call `connectionManager.updateStatusNotification()`
      for the side effect, and call `notifications.updateServiceStateNotification()`
      directly where the `Notification` object is needed for `startForeground()`.
   d. Alternatively, if the `Notification` object is only needed in one place,
      consider having the notification service handle `startForeground` internally.
   e. Evaluate the cleanest approach by reading the actual call sites first.
4. Run `./gradlew spotlessApply detekt :core:model:allTests :core:data:allTests :app:compileFdroidDebugKotlin`
5. Commit to branch `refactor/connection-state-cleanup` and open a PR.

## Validation
- `./gradlew test allTests` passes
- `./gradlew spotlessCheck detekt` passes
