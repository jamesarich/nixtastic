# PR-C: Replace lateinit var scope + start() with constructor injection

## Branch name
`refactor/manager-scope-injection`

## Problem
14+ manager classes in `core/data` follow the same anti-pattern:

```kotlin
class FooManagerImpl : FooManager {
    private lateinit var scope: CoroutineScope
    override fun start(scope: CoroutineScope) {
        this.scope = scope
        // begin collecting flows, launching coroutines, etc.
    }
}
```

This is fragile — calling any method before `start()` crashes with
`UninitializedPropertyAccessException`. The `start()` call is a manual
lifecycle ceremony that every host (`MeshService`, desktop `Main.kt`) must
remember to perform in the right order.

## Files to modify (14 impl + 14 interface pairs)

### Implementations (`core/data/src/commonMain/.../manager/`)
- `MeshConnectionManagerImpl.kt` (L85, L93)
- `MeshConfigFlowManagerImpl.kt` (L60, L66)
- `PacketHandlerImpl.kt` (L70, L82)
- `NodeManagerImpl.kt` (L63, L91)
- `MeshDataHandlerImpl.kt` (L98, L100)
- `MeshMessageProcessorImpl.kt` (L57, L78)
- `MeshActionHandlerImpl.kt` (L68, L70)
- `MeshConfigHandlerImpl.kt` (L44, L52)
- `CommandSenderImpl.kt` (L63, L74)
- `StoreForwardPacketHandlerImpl.kt` (L49, L51)
- `MqttManagerImpl.kt` (L40)
- `NeighborInfoHandlerImpl.kt` (L40, L46)
- `TelemetryPacketHandlerImpl.kt` (L53, L58)
- `TracerouteHandlerImpl.kt` (L46, L50)

### Interfaces (`core/repository/src/commonMain/.../`)
- `MeshConnectionManager.kt` (L25)
- `MeshConfigFlowManager.kt` (L28)
- `PacketHandler.kt` (L27)
- `NodeManager.kt` (L55)
- `MeshDataHandler.kt` (L27)
- `MeshMessageProcessor.kt` (L25)
- `MeshActionHandler.kt` (L29)
- `MeshConfigHandler.kt` (L31)
- `CommandSender.kt` (L31)
- `StoreForwardPacketHandler.kt` (L26)
- `NeighborInfoHandler.kt` (L26)
- `TelemetryPacketHandler.kt` (L26)
- `TracerouteHandler.kt` (L26)

### Callers of `start(scope)` — the orchestration point
- `core/service/src/commonMain/.../SharedRadioInterfaceService.kt` or
  wherever all managers are started with a shared scope
- `core/service/src/androidMain/.../MeshService.kt`
- `desktop/src/main/kotlin/.../` — desktop startup

## What to do

1. Read `AGENTS.md` at the project root for architecture rules and build commands.
2. Read one or two representative managers (e.g. `MeshConnectionManagerImpl`,
   `PacketHandlerImpl`) to understand the pattern fully.
3. Find WHERE `start(scope)` is called for each manager — there should be a
   central orchestration point.
4. Choose the migration strategy:
   - **Option A (recommended): Inject a `CoroutineScope` via Koin.** Define a
     Koin qualifier for the service scope (e.g. `@Named("serviceScope")`) and
     inject it as a constructor parameter. This eliminates `start()` entirely.
     The scope is created by the service/host and provided to Koin before the
     manager graph is resolved.
   - **Option B: Constructor parameter without DI.** Pass `scope` as a
     constructor parameter. This requires the factories/callers to pass it
     explicitly.
   - Option A is preferred because these managers are already Koin-managed
     singletons. The scope can be provided as a Koin definition at startup.
5. For each manager:
   a. Replace `private lateinit var scope` with `private val scope` constructor param.
   b. Remove the `start(scope: CoroutineScope)` method from the interface.
   c. Move any initialization logic from `start()` into an `init` block or
      a lazy-started flow collection.
   d. Update the Koin module to provide the scope.
6. Update the orchestration point to no longer call `start()` on each manager.
7. Run `./gradlew spotlessApply detekt :core:data:allTests :core:service:allTests :app:compileFdroidDebugKotlin :desktop:compileKotlin`
8. Commit to branch `refactor/manager-scope-injection` and open a PR.

## Validation
- `./gradlew test allTests` passes
- `./gradlew spotlessCheck detekt` passes
- No `lateinit var scope` remaining in `core/data`

## Risks
- The `start()` method may do more than just set the scope — it may register
  observers or launch initial work. Moving this to `init` could change timing.
  Audit each `start()` body carefully.
- Koin scope lifecycle must match the service lifecycle. If the service is
  recreated, the scope (and all managers) must be recreated too.
