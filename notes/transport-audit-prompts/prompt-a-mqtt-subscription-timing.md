# PR-A: Fix MQTT subscription timing

## Branch name
`fix/mqtt-subscription-timing`

## Problem
In `MQTTRepositoryImpl.kt`, after creating the `MQTTClient` and launching
`runSuspend()` in a coroutine, the code calls `yield()` before subscribing
to topics. `yield()` is not a reliable synchronization primitive — it only
suspends if there is another coroutine ready to run on the same dispatcher.
On a lightly loaded dispatcher, `yield()` returns immediately and the
subscription attempt races with the client's connection establishment.

## File to modify
`core/network/src/commonMain/kotlin/org/meshtastic/core/network/repository/MQTTRepositoryImpl.kt`

## What to do

1. Read `AGENTS.md` at the project root for architecture rules and build commands.
2. Read the full `MQTTRepositoryImpl.kt` to understand the client lifecycle.
3. Replace the `yield()` call with a proper connection-readiness signal:
   - Add a `CompletableDeferred<Unit>` (e.g. `connectionReady`) that is completed
     inside the `clientJob` launch block after `runSuspend()` has been called
     (KMQTT's `runSuspend()` blocks once the client is connected and processing).
   - Actually, `runSuspend()` is a blocking loop — it doesn't return until
     disconnect. The real signal is that `MQTTClient` has been constructed and
     the coroutine has started `runSuspend()`. Look at KMQTT's `MQTTClient` API
     to find the right hook. If there's no callback, use a `connected` callback
     or a short structured delay with logging, rather than bare `yield()`.
   - The safest approach may be to move the `subscribe()` calls into the
     `clientJob` launch block, right after client construction but before
     `runSuspend()`. KMQTT's `subscribe()` queues subscriptions that are sent
     once the connection is established, so calling subscribe before `runSuspend()`
     should work. Verify this by reading the KMQTT source or docs.
4. Add a KDoc comment explaining the subscription timing contract.
5. Run `./gradlew spotlessApply detekt :core:network:compileKotlinJvm :core:network:allTests`
6. Commit to branch `fix/mqtt-subscription-timing` and open a PR.

## Validation
- `./gradlew :core:network:allTests` passes
- `./gradlew spotlessCheck detekt` passes
- No behavioral change for callers — subscriptions should still work, just reliably
