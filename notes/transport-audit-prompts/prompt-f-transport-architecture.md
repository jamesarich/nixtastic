# PR-F: Transport architecture — rename, flatten factory, extract callback

## Branch name
`refactor/transport-architecture`

## Problems

### L3: Mixed naming `*Interface` vs `*Transport`
Legacy Android classes use `*Interface` (e.g. `BleRadioInterface`,
`TCPInterface`, `SerialInterface`, `StreamInterface`, `MockInterface`,
`NopInterface`). Newer KMP classes use `*Transport` (e.g. `TcpTransport`,
`SerialTransport`). The contract interface is `RadioTransport`. All
implementations should follow the `*Transport` convention.

### M2: Redundant InterfaceSpec/InterfaceFactory layer
The `InterfaceSpec<T>` / `InterfaceFactory` abstraction adds an unnecessary
indirection layer between `RadioTransportFactory` and the actual transport
constructors. There are 6 `*InterfaceSpec` classes and 4 `*InterfaceFactory`
classes that could be collapsed into direct creation inside
`AndroidRadioTransportFactory`.

### M3: RadioTransportCallback extraction
Transport implementations accept the full `RadioInterfaceService` as a
constructor parameter, but they only use 3 methods: `onConnect()`,
`onDisconnect(isPermanent)`, and `handleFromRadio(bytes)`. This couples
transports to the service layer unnecessarily. Extract a
`RadioTransportCallback` interface with just these 3 methods.

### H1: Decouple TCPInterface from StreamInterface
`TCPInterface` extends `StreamInterface` but bypasses it entirely — it
overrides `handleSendToRadio` to delegate to `TcpTransport`, overrides
`sendBytes` as a no-op, and creates a dead `StreamFrameCodec`. The inheritance
exists only to get access to `service: RadioInterfaceService` and the
`onDeviceDisconnect()` lifecycle. After M3 extracts `RadioTransportCallback`,
`TCPInterface` can compose `TcpTransport` directly without inheriting
`StreamInterface`.

## Rename map

| Current | New | File |
|---------|-----|------|
| `BleRadioInterface` | `BleRadioTransport` | `core/network/src/commonMain/.../radio/BleRadioInterface.kt` |
| `StreamInterface` | `StreamTransport` | `core/network/src/commonMain/.../radio/StreamInterface.kt` |
| `TCPInterface` | `TcpRadioTransport` | `core/network/src/jvmAndroidMain/.../radio/TCPInterface.kt` |
| `SerialInterface` | `SerialRadioTransport` | `core/network/src/androidMain/.../radio/SerialInterface.kt` |
| `MockInterface` | `MockRadioTransport` | `core/network/src/commonMain/.../radio/MockInterface.kt` |
| `NopInterface` | `NopRadioTransport` | `core/network/src/commonMain/.../radio/NopInterface.kt` |
| `InterfaceSpec` | DELETE | `core/network/src/commonMain/.../radio/InterfaceSpec.kt` |
| `InterfaceFactory` | DELETE | `core/network/src/androidMain/.../radio/InterfaceFactory.kt` |
| `MockInterfaceSpec` | DELETE | `core/network/src/commonMain/.../radio/MockInterfaceSpec.kt` |
| `NopInterfaceSpec` | DELETE | `core/network/src/commonMain/.../radio/NopInterfaceSpec.kt` |
| `SerialInterfaceSpec` | DELETE | `core/network/src/androidMain/.../radio/SerialInterfaceSpec.kt` |
| `TCPInterfaceSpec` | DELETE | `core/network/src/androidMain/.../radio/TCPInterfaceSpec.kt` |
| `MockInterfaceFactory` | DELETE or merge | `core/network/src/commonMain/.../radio/MockInterfaceFactory.kt` |
| `NopInterfaceFactory` | DELETE or merge | `core/network/src/commonMain/.../radio/NopInterfaceFactory.kt` |
| `SerialInterfaceFactory` | DELETE or merge | `core/network/src/androidMain/.../radio/SerialInterfaceFactory.kt` |
| `TCPInterfaceFactory` | DELETE or merge | `core/network/src/androidMain/.../radio/TCPInterfaceFactory.kt` |

## Files with ripple-effect updates
- `core/network/src/androidMain/.../radio/AndroidRadioTransportFactory.kt`
- `core/network/src/commonMain/.../radio/BaseRadioTransportFactory.kt`
- `desktop/src/main/kotlin/.../radio/DesktopRadioTransportFactory.kt`
- `core/service/src/commonMain/.../SharedRadioInterfaceService.kt`
- `core/model/src/commonMain/.../InterfaceId.kt`
- `core/repository/src/commonMain/.../RadioTransportFactory.kt`
- `core/network/src/commonTest/.../BleRadioInterfaceTest.kt`
- `core/network/src/commonTest/.../StreamInterfaceTest.kt` (if exists)

## What to do

1. Read `AGENTS.md` at the project root for architecture rules and build commands.
2. **M3 first:** Create `RadioTransportCallback` interface in `core/repository`:
   ```kotlin
   interface RadioTransportCallback {
       fun onConnect()
       fun onDisconnect(isPermanent: Boolean)
       fun handleFromRadio(bytes: ByteArray)
   }
   ```
   Have `SharedRadioInterfaceService` implement it. Update all transport
   constructors to accept `RadioTransportCallback` instead of
   `RadioInterfaceService`. Transports that also need `serviceScope` can
   accept a `CoroutineScope` parameter separately.
3. **H1 next:** Rewrite `TCPInterface` (now `TcpRadioTransport`) to compose
   `TcpTransport` via delegation instead of inheriting `StreamInterface`.
   It should implement `RadioTransport` directly, delegate send/receive to
   `TcpTransport`, and call `RadioTransportCallback` for lifecycle events.
4. **M2 next:** Delete `InterfaceSpec`, `InterfaceFactory`, and all `*Spec`
   classes. Move address validation and transport creation logic directly
   into `AndroidRadioTransportFactory.createPlatformTransport()` using a
   `when (interfaceId)` block.
5. **L3 last:** Rename all `*Interface` classes to `*Transport`. Rename files
   to match. Update all imports and references.
6. Run `./gradlew spotlessApply detekt :core:network:compileKotlinJvm :core:network:allTests :app:compileFdroidDebugKotlin :desktop:compileKotlin`
7. Commit to branch `refactor/transport-architecture` and open a PR.

## Validation
- `./gradlew test allTests` passes
- `./gradlew spotlessCheck detekt` passes
- `rg 'Interface\b' core/network/src --include '*.kt' -l` shows no legacy
  `*Interface` class names (only `RadioTransportCallback` interface)
- No transport class imports `RadioInterfaceService` directly

## Risks
- This is the largest single refactor. High merge conflict potential.
- Must run AFTER PR-G (which also touches transport constructors).
- `InterfaceId` enum may still use legacy names — decide whether to rename
  the enum variants too (e.g. `InterfaceId.SERIAL` is fine, but the enum
  class name could become `TransportId`).
- `RadioInterfaceService` itself keeps its name — it's a service, not a
  transport. Only the transport implementations get renamed.
