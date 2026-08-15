# PR-H: Add want_config handshake to MockInterface

## Branch name
`fix/mock-handshake`

## Problem
`MockInterface` calls `service.onConnect()` directly in `init` (line 71-74)
and immediately sends a full config response via `sendConfigResponse()` without
waiting for a `want_config` message from the app. This skips the two-stage
handshake that real devices perform:

1. App sends `ToRadio { want_config_id = myConfigId }` after connecting
2. Device responds with `MyNodeInfo`, config packets, channels, then
   `CONFIG_COMPLETE_ID`

Because `MockInterface` skips step 1, tests that exercise the handshake flow
(e.g. `MeshConfigFlowManager`) cannot use `MockInterface` to simulate real
device behavior.

`NopInterface` has no handshake at all — it doesn't call `onConnect()` or send
any config. This may be intentional (it's a no-op stub) but should be documented.

## Files to modify
- `core/network/src/commonMain/kotlin/org/meshtastic/core/network/radio/MockInterface.kt`
  - L71-74: `init` block
  - L304-357: `sendConfigResponse()` — sends config without waiting for want_config
  - L60: constructor takes `RadioInterfaceService`
- `core/network/src/commonMain/kotlin/org/meshtastic/core/network/radio/NopInterface.kt`
  - L21-29: add KDoc clarifying it intentionally does nothing

## What to do

1. Read `AGENTS.md` at the project root for architecture rules and build commands.
2. Read `MockInterface.kt` fully to understand the mock data flow.
3. Read `MeshConfigFlowManagerImpl.kt` to understand the real handshake stages.
4. Read the firmware handshake sequence in the proto definitions if needed
   (`core/proto/`).
5. Modify `MockInterface`:
   a. Move `service.onConnect()` from `init` to `start()` (or keep in init if
      M15 hasn't landed yet, but add a TODO).
   b. In `handleSendToRadio()`, intercept `ToRadio.want_config_id`:
      ```kotlin
      override fun handleSendToRadio(p: ByteArray) {
          val toRadio = ToRadio.ADAPTER.decode(p)
          if (toRadio.want_config_id != 0) {
              sendConfigResponse(toRadio.want_config_id)
              return
          }
          // ... existing admin message handling
      }
      ```
   c. Update `sendConfigResponse()` to accept the `configId` and use it as
      the `CONFIG_COMPLETE_ID` in the final response.
   d. Remove the automatic `sendConfigResponse()` call from `init`.
6. Add KDoc to `NopInterface` explaining it's intentionally inert.
7. Run `./gradlew spotlessApply detekt :core:network:allTests`
8. Commit to branch `fix/mock-handshake` and open a PR.

## Validation
- `./gradlew :core:network:allTests` passes
- `./gradlew spotlessCheck detekt` passes
- MockInterface now waits for `want_config` before sending config
- Existing tests that use MockInterface still pass (they may need to send
  `want_config` now — update them if needed)

## Risks
- Tests that depend on MockInterface auto-sending config will break. Update
  them to send `want_config` first.
- If M15 (constructor side-effects) lands first, the `init` block will already
  be cleaned up. Coordinate with PR-G.
