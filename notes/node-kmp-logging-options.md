# Getting node-kmp's logs out, on every platform

Written 2026-09-16 after a session where the Apple side's logging cost hours.

## The problem, concretely

`GattDebug.enabled = true` makes the Apple link call `gattLog`, which is a
`println`. On Kotlin/Native for iOS that goes to **stdout**, and stdout does not
reach Apple's unified log. So:

- `pymobiledevice3 syslog live` shows **nothing** of it. Two captures were taken
  and read as "the app is silent" before that was understood.
- Only a tool that *owns* the process's stdout sees it -
  `xcrun devicectl device process launch --console --terminate-existing`. Attaching
  to an already-running instance captures nothing, because it foregrounds rather
  than spawns.

That one gap turned a two-minute question - does `didSubscribeTo` fire - into
several rounds of failed captures.

The same shape applies elsewhere: `println` on Android does not reach Logcat's
structured stream, and on the JVM it bypasses whatever the host app uses.

## What was built

`MeshLog` sits in `node-core` with **no logging dependency**: levels, lambda
messages, a `println`, and a `MeshLogSink` a host can attach - an on-screen log, a
file on a headless node, a test's recorder. The sink is the part worth having.

## Kermit was tried and cannot be used here

`co.touchlab:kermit:2.2.0` covers every target this library has, and its
`OSLogWriter` is a real `os_log_with_type` through a cinterop shim. It still had
to be removed: **that cinterop klib fails the Kotlin/Native compiler cache**, and
`linkDebugFrameworkIosArm64` dies with

```
e: Failed to build cache for …/kermit-core-iosArm64Cinterop-os_logMain-2.2.0.klib
```

so the iOS app cannot be built at all. `kotlin.native.cacheKind=none` - JetBrains'
own workaround - did not clear it, and `--no-configuration-cache` is refused
because Isolated Projects requires the configuration cache.

Worth knowing if it is revisited: Kermit's `OSLogWriter()` defaults are
`subsystem=""`, `category=""`, `publicLogging=false`, which emit a `%s` body the
unified log redacts to `<private>` under no subsystem at all. A grep for the app
or tag name can never match those - which is exactly why an earlier reading of
"nothing appears" here was wrong. `OSLogWriter(subsystem = …, category = …,
publicLogging = true)` is the usable form, and `pymobiledevice3 syslog live -s
<subsystem>` the matching capture.

`XcodeSeverityWriter` is **not** a `println`: it extends `OSLogWriter` and only its
throwable path uses one. An earlier note here said otherwise.

## Capturing Apple-side logs today

`xcrun devicectl device process launch --console --terminate-existing` is the only
method measured to work. `--terminate-existing` is not optional: attaching to a
running instance foregrounds it rather than spawning it, and captures nothing.

`MeshLogSink` is the route that avoids the question entirely.

## The trap that cost more than any of this

**The Xcode project has no build phase that runs Gradle.** It links a prebuilt
framework from `monitor/build/bin/iosArm64/debugFramework`, so `xcodebuild`
happily builds an app around a framework that is weeks old - it was nine days
stale here, and several "verified on device" results were measured against a
binary that did not contain the change under test.

Build the framework first, and check its mtime:

```
env -u DEVELOPER_DIR -u SDKROOT -u NIX_CC -u CC -u CXX PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" \
  ./gradlew :monitor:linkDebugFrameworkIosArm64
ls -la monitor/build/bin/iosArm64/debugFramework/Monitor.framework/Monitor
```

The stripped environment is required for the same reason every other Apple tool
needs it here - see `CLAUDE.md` on the Nix `DEVELOPER_DIR` pollution.
