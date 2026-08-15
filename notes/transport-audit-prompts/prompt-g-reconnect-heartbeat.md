# PR-G: Extract reconnect policy, shared HeartbeatSender, remove constructor side-effects

## Branch name
`refactor/reconnect-heartbeat-lifecycle`

## Problems

### M4: BleRadioInterface.connect() is 130 lines
The `connect()` method in `BleRadioInterface` (lines 212-339) contains the
entire reconnect state machine: scan-or-bond decision, settle delay, failure
counting, exponential backoff, stable-connection detection, and disconnect
handling. This should be extracted into a testable `ReconnectPolicy` or
`ReconnectStrategy` class.

### M5: HeartbeatSender duplicated across 4 transports
The heartbeat/keepAlive pattern is copy-pasted across:
- `BleRadioInterface.keepAlive()` (L447-470) — sends ToRadio heartbeat with
  nonce, schedules delayed drain via `requestDrain()`
- `SerialInterface.keepAlive()` (L118-127) — sends ToRadio heartbeat
- `SerialTransport.keepAlive()` (L142-148) — sends ToRadio heartbeat
- `TCPInterface.keepAlive()` (L84-87) → `TcpTransport.sendHeartbeat()` (L150-153)

All create a `ToRadio { heartbeat = Heartbeat { ... } }` and encode it. The
scheduling is done by `SharedRadioInterfaceService.startHeartbeat()` (L255-266).

Extract a common `HeartbeatSender` that takes a `sendBytes: (ByteArray) -> Unit`
lambda and optionally an `afterHeartbeat: suspend () -> Unit` callback (for
BLE's `requestDrain()`).

### M15: Constructor side-effects
Four transport classes trigger connection in their `init` block:
- `BleRadioInterface` (L174-176): `init { connect() }`
- `SerialInterface` (L37-39): `init { connect() }`
- `TCPInterface` (L66-68): `init { connect() }`
- `MockInterface` (L71-74): `init { ... service.onConnect() }`

This means creating the object immediately starts I/O. The factory cannot
create-then-configure-then-start. Move connection initiation to an explicit
`start()` method or have the factory call `connect()` after construction.

## Files to modify

### M4 — Reconnect policy
- `core/network/src/commonMain/.../radio/BleRadioInterface.kt` (L64-96 constants,
  L212-339 connect method)
- NEW: `core/network/src/commonMain/.../radio/BleReconnectPolicy.kt`

### M5 — HeartbeatSender
- `core/network/src/commonMain/.../radio/BleRadioInterface.kt` (L447-470)
- `core/network/src/androidMain/.../radio/SerialInterface.kt` (L118-127)
- `core/network/src/jvmMain/.../SerialTransport.kt` (L142-148)
- `core/network/src/jvmAndroidMain/.../radio/TCPInterface.kt` (L84-87)
- `core/network/src/jvmAndroidMain/.../transport/TcpTransport.kt` (L150-153)
- `core/service/src/commonMain/.../SharedRadioInterfaceService.kt` (L255-266)
- `core/repository/src/commonMain/.../RadioTransport.kt` (L33)
- NEW: `core/network/src/commonMain/.../transport/HeartbeatSender.kt`

### M15 — Constructor side-effects
- `core/network/src/commonMain/.../radio/BleRadioInterface.kt` (L174-176)
- `core/network/src/androidMain/.../radio/SerialInterface.kt` (L37-39)
- `core/network/src/jvmAndroidMain/.../radio/TCPInterface.kt` (L66-68)
- `core/network/src/commonMain/.../radio/MockInterface.kt` (L71-74)
- `core/network/src/commonMain/.../radio/BaseRadioTransportFactory.kt`
  (where transports are constructed — must call `start()` after creation)
- `desktop/src/main/kotlin/.../radio/DesktopRadioTransportFactory.kt`

## What to do

1. Read `AGENTS.md` at the project root for architecture rules and build commands.
2. **M15 first** (enables the other two):
   a. Add `fun start()` to the `RadioTransport` interface (or use a
      `Startable` interface / convention).
   b. Move `init { connect() }` from each transport to a `start()` method.
   c. Update `BaseRadioTransportFactory.createTransport()` and
      `DesktopRadioTransportFactory` to call `transport.start()` after creation.
   d. `MockInterface` should call `service.onConnect()` in `start()`, not `init`.
3. **M5 next:**
   a. Create `HeartbeatSender` in `core/network/src/commonMain/.../transport/`:
      ```kotlin
      class HeartbeatSender(
          private val sendToRadio: (ByteArray) -> Unit,
          private val afterHeartbeat: (suspend () -> Unit)? = null,
      ) {
          suspend fun sendHeartbeat() { ... }
      }
      ```
   b. Replace `keepAlive()` in each transport with delegation to `HeartbeatSender`.
   c. Keep the `keepAlive()` method on `RadioTransport` but have it delegate.
4. **M4 last:**
   a. Extract the reconnect loop from `BleRadioInterface.connect()` into
      `BleReconnectPolicy`:
      ```kotlin
      class BleReconnectPolicy(
          private val maxFailures: Int,
          private val settleDelay: Duration,
          private val backoffStrategy: (attempt: Int) -> Duration,
      ) {
          suspend fun execute(attempt: suspend () -> BleConnectionState): BleConnectionState
      }
      ```
   b. `BleRadioInterface.connect()` should become a thin wrapper that creates
      a `BleReconnectPolicy` and calls `policy.execute { ... }`.
   c. Write tests for the policy in `core/network/src/commonTest/`.
5. Run `./gradlew spotlessApply detekt :core:network:allTests :core:service:allTests :app:compileFdroidDebugKotlin :desktop:compileKotlin`
6. Commit to branch `refactor/reconnect-heartbeat-lifecycle` and open a PR.

## Validation
- `./gradlew test allTests` passes
- `./gradlew spotlessCheck detekt` passes
- `rg 'init\s*\{' core/network/src --include '*.kt'` shows no transport
  classes calling `connect()` in `init`
- `rg 'keepAlive|sendHeartbeat' core/network/src --include '*.kt'` shows
  heartbeat logic centralized in `HeartbeatSender`
- New tests for `BleReconnectPolicy` pass

## Risks
- M15 changes the transport lifecycle contract — every factory call site must
  be updated to call `start()`.
- HeartbeatSender must handle the BLE-specific `requestDrain()` callback
  without coupling to BLE.
- Must run BEFORE PR-F (transport architecture rename) to minimize conflicts.
