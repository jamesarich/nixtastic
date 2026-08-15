# PR-E: Unify dual connectionState flows

## Branch name
`refactor/unify-connection-state`

## Problem
Connection state is tracked independently at two layers:

1. **Transport layer:** `RadioInterfaceService.connectionState: StateFlow<ConnectionState>`
   (in `SharedRadioInterfaceService._connectionState`)
2. **Service layer:** `ServiceRepository.connectionState: StateFlow<ConnectionState>`
   (in `ServiceRepositoryImpl._connectionState`)

`MeshConnectionManagerImpl` consumes BOTH (lines 95 and 98), reconciles them,
and dispatches to `onConnectionChanged()`. ViewModels and UI use the service
layer's flow via `ServiceRepository`. This dual-source architecture means:
- State can temporarily diverge between layers
- Consumers must know which flow to observe
- The reconciliation logic in `MeshConnectionManagerImpl` is the only place
  keeping them in sync — a fragile single point of coordination

## Files involved

### Core state declarations
- `core/repository/src/commonMain/.../RadioInterfaceService.kt` (L33)
- `core/service/src/commonMain/.../SharedRadioInterfaceService.kt` (L80-81)
- `core/repository/src/commonMain/.../ServiceRepository.kt` (L38, L45)
- `core/service/src/commonMain/.../ServiceRepositoryImpl.kt` (L46-51)

### Consumers
- `core/data/src/commonMain/.../MeshConnectionManagerImpl.kt` (L95, L98, L145)
- `core/model/src/commonMain/.../RadioController.kt` (L32)
- `core/service/src/commonMain/.../DirectRadioControllerImpl.kt` (L66-67)
- `core/service/src/androidMain/.../AndroidRadioControllerImpl.kt` (L44-45)
- `core/ui/src/commonMain/.../UIViewModel.kt` (L245-246)
- `core/ui/src/commonMain/.../ConnectionsViewModel.kt` (L46)

### BLE-specific state (separate concern)
- `core/ble/src/commonMain/.../BleConnection.kt` (L48 — `BleConnectionState`)
- `core/ble/src/commonMain/.../KableBleConnection.kt` (L108-114)
- `core/network/src/commonMain/.../BleRadioInterface.kt` (L255, L263, L268)

### Test fakes
- `core/testing/src/commonMain/.../FakeRadioInterfaceService.kt` (L37-38)
- `core/testing/src/commonMain/.../FakeServiceRepository.kt` (L34-38)
- `core/testing/src/commonMain/.../FakeRadioController.kt` (L33-34)

## What to do

1. Read `AGENTS.md` at the project root for architecture rules and build commands.
2. Read `MeshConnectionManagerImpl.kt` to understand how it reconciles both flows.
3. Read `SharedRadioInterfaceService.kt` and `ServiceRepositoryImpl.kt` to
   understand what sets each flow and when.
4. Design a unified state flow:
   - **Option A (recommended):** Keep one canonical `StateFlow<ConnectionState>`
     on `ServiceRepository`. Have `SharedRadioInterfaceService` update
     `ServiceRepository.setConnectionState()` directly when transport state
     changes (it may already do this). Remove the duplicate
     `RadioInterfaceService.connectionState` or make it `internal`.
   - **Option B:** Keep both but make the transport-layer flow `internal` and
     ensure only `MeshConnectionManagerImpl` reads it, converting to the
     service-layer flow. Add KDoc making the contract explicit.
   - Option A is cleaner but higher risk. Option B is safer for this PR.
5. Update test fakes to match.
6. Run `./gradlew spotlessApply detekt :core:data:allTests :core:service:allTests :core:ui:allTests :app:compileFdroidDebugKotlin`
7. Commit to branch `refactor/unify-connection-state` and open a PR.

## Validation
- `./gradlew test allTests` passes
- `./gradlew spotlessCheck detekt` passes
- Grep confirms no consumer uses the transport-layer flow when it should use
  the service-layer flow (or vice versa)

## Risks
- This is a cross-cutting change touching `core/repository`, `core/service`,
  `core/data`, `core/ui`, and `core/model`. Test thoroughly.
- `BleConnectionState` (Kable-level) is a SEPARATE concern from
  `ConnectionState` (app-level). Do not conflate them.
- Must run after PR-D (connection manager atomicity) to avoid conflicts on
  `MeshConnectionManagerImpl.kt`.
