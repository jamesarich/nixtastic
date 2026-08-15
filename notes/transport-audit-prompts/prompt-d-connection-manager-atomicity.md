# PR-D: Make MeshConnectionManagerImpl.onConnectionChanged atomic

## Branch name
`fix/connection-manager-atomicity`

## Problem
`MeshConnectionManagerImpl.onConnectionChanged()` (line 144) performs a
non-atomic check-then-act: it reads `serviceRepository.connectionState.value`,
compares it with the incoming state, then conditionally calls
`handleConnected()` / `handleDeviceSleep()` / `handleDisconnected()`. If two
state transitions arrive in quick succession (e.g. Connected → DeviceSleep →
Disconnected during a flaky BLE reconnect), the intermediate state can be
missed or applied out of order.

## File to modify
`core/data/src/commonMain/kotlin/org/meshtastic/core/data/manager/MeshConnectionManagerImpl.kt`

Focus on:
- `onRadioConnectionState()` (line 128-142) — maps transport state to effective state
- `onConnectionChanged()` (line 144-167) — the 48-line method with state transitions

## What to do

1. Read `AGENTS.md` at the project root for architecture rules and build commands.
2. Read the full `MeshConnectionManagerImpl.kt` to understand the state machine.
3. Identify the concurrency model:
   - Is `onConnectionChanged()` always called from the same coroutine/dispatcher?
   - Or can it be called from multiple coroutines concurrently?
   - Check how `radioInterfaceService.connectionState` and
     `serviceRepository.connectionState` are collected.
4. Apply one of:
   - **Mutex guard:** Wrap the check-then-act in a `Mutex().withLock { ... }`
     to serialize state transitions.
   - **Channel-based state machine:** Replace the direct method call with a
     `Channel<ConnectionState>` that is consumed by a single coroutine, ensuring
     sequential processing.
   - **compareAndSet:** If using `MutableStateFlow`, leverage its atomicity —
     read `value`, compute next state, and use `update { }` which is atomic.
5. Add a test case that verifies rapid state transitions are processed in order.
   Use `core:testing` fakes and `kotlinx-coroutines-test`.
6. Run `./gradlew spotlessApply detekt :core:data:allTests`
7. Commit to branch `fix/connection-manager-atomicity` and open a PR.

## Validation
- `./gradlew :core:data:allTests` passes (including new test)
- `./gradlew spotlessCheck detekt` passes
- State transitions are now serialized — no more TOCTOU race
