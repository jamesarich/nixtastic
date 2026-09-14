# KMP / Kotlin/Native toolchain research, 2026-09-13

Read against the question "should node-kmp bump its JDK, and does a JetBrains
JDK buy anything". Sources are the live kotlinlang.org docs (dated August 2026
where they carry a date), the Kotlin 2.4.0 what's-new and 2.4.20 release
notes, Gradle 9.7.1's compatibility page, and the Compose Multiplatform,
Compose Hot Reload and JetBrains Runtime release pages on GitHub.

## Versions in play

| Thing | Current | node-kmp | android |
|---|---|---|---|
| Kotlin | 2.4.20 | 2.4.20 | 2.4.20 |
| Gradle | 9.7.1 (runs on JVM 17 to 26, toolchains to 26) | 9.7.1 | 9.7.1 |
| Compose Multiplatform | 1.12.0 stable, 1.13.0-alpha01 (2026-09-10) | 1.12.0 | 1.12.0 |
| Compose Hot Reload | 1.2.0 stable (JBR 25 default), 1.3.0-alpha01 | not applied | applied |
| JetBrains Runtime | 25.0.4.1b583.48 (2026-08-24) | none | JBR 25 via foojay |

Kotlin 2.4.0 added Java 26 bytecode. Gradle 9.4+ runs on and targets 26. So
nothing in the toolchain caps node-kmp at 21; the cap is self-imposed and the
reasons for it are downstream (see "bytecode target" below).

## Findings that change or confirm the earlier advice

1. **The Compose Hot Reload docs on kotlinlang.org are stale.** They still say
   "the latest JetBrains Runtime supports only Java 21; Java 22 or newer gives a
   linkage error". The 1.2.0 release notes (2026-07-23) say "JBR 25 by default,
   with `compose.reload.jbr.min.version` to set the minimum", and android runs
   hot reload on JBR 25 with `jvmTarget = 25` today. Trust the release notes.
   The JBR is still mandatory: a non-JetBrains JDK has no enhanced class
   redefinition and the plugin refuses it.

2. **Compose 1.13.0-alpha01 adds AppCDS and AOT for desktop distributables**
   (PR #5644, `compose.desktop.application.aot { mode = ... }`). Four modes:
   `AppCdsAuto` (JDK 19+, archive built on the end user's first run),
   `AppCdsPrebuild` (JDK 21+, training run at package time), `AotPrebuild`
   (JDK 25+, JEP 514, training run at package time). Measured 3.8x to 4.8x
   cold-start speedup on a small app. This is the first concrete thing a 25
   *bundled runtime* buys `monitor`, and it is a packaging-runtime choice, not a
   compile-target choice: the jar can stay at bytecode 21. The training run
   needs a display, so CI would need Xvfb.

3. **`jvmToolchain` and `jvmTarget` are officially separable.** The Kotlin
   Gradle docs: the toolchain "sets `compilerOptions.jvmTarget` to the
   toolchain's JDK version if the user doesn't set the `jvmTarget` option
   explicitly". android's `KotlinAndroid.kt` (toolchain 25, target 21) is the
   documented pattern. Also: "JS and Native tasks don't use toolchains. The
   Kotlin compiler always runs on the JDK the Gradle daemon is running on", so
   `gradle-daemon-jvm.properties` is what governs the Kotlin/Native compiles.

4. **Kotlin 2.4.20 turns on `invokedynamic` `when` generation by default for
   JVM targets 21+** (KT-78079) and **enables Kotlin/Native incremental
   compilation by default** (KT-86657). Both land at the pins node-kmp already
   has; no bump needed to get them.

5. **`macosX64` is deprecated since Kotlin 2.3.20.** node-kmp only declares
   `macosArm64` (Tier 1), so it is unaffected. Kable still declares `macosX64`
   and builds its JVM natives on `macos-15-intel`; worth a heads-up upstream
   at some point. `linuxX64` and `linuxArm64` are Tier 2 (compiled on CI,
   tests only on x64); `mingwX64` is Tier 2 with tests.

6. **Kotlin/Native 2.4.0 raised minimum Apple targets** to iOS 15 and macOS 12,
   moved to LLVM 21, and made the concurrent mark-and-sweep GC the default
   (`kotlin.native.binary.gc=pmcs` reverts). The devirtualisation memory fix
   halves link-release memory.

7. **Swift export is Alpha** (roadmap: Beta next): suspend functions become
   Swift `async`, `Flow` becomes `AsyncSequence`, sealed classes become Swift
   enums; generics erase to bounds; direct integration only. Not a reason to
   move the apple adapter off the Objective-C framework yet, but it is the
   path once it is Beta. Swift Package Import (`swiftPMDependencies {}`)
   landed in 2.4.0.

8. **Cross-compiling Apple klibs from Linux works except with cinterop.** The
   publishing doc: klibs for Apple targets build on any host, but "libraries
   or dependent modules with cinterop dependencies" need a Mac. That is exactly
   `node-desktop-ble-macos` (the `jni.def` cinterop), so its klib, its ABI dump
   and any publish that includes it stay Mac-only. Publish everything from one
   host to avoid Maven Central duplicate rejections.

9. **C interop is still Beta** (`@ExperimentalForeignApi` on every generated
   declaration). Nothing on the roadmap about JVM-side interop, FFM or JNI
   from Kotlin/Native; the roadmap's native items are Swift export, native
   compiler caches in release mode, Xcode debugger integration and parallel
   native tasks without configuration cache. The macOS JNI bridge stays
   hand-written for the foreseeable future.

10. **JetBrains Runtime 25 is being actively rebased and its Wayland toolkit is
    still getting fixes** (JBR-10273 "IDE window never appears with WLToolkit on
    GNOME Wayland" fixed in 25.0.4b508, pointer and popup fixes in b583). So
    WLToolkit is real but not settled; the AWT-over-XWayland path the workspace
    already uses for `hotRun` remains the safe default.

11. **jpackage needs JDK 17+, and ProGuard on JDK 25 needs ProGuard 7.8.0+**
    (`buildTypes.release.proguard.version.set("7.8.0")`). The native
    distribution doc does not mention the JBR or jmods at all; the JEP 493
    jmods trap android hit is undocumented there.

## What this means for node-kmp

- Keep `jvmToolchain(21)` and bytecode 21 for the libraries and the headless
  jar. The Pi and uConsole run distro JDKs, and the Maven consumers will run
  whatever they run.
- For `monitor` only, pin the packaging toolchain to vendor JetBrains and apply
  hot reload. JBR 21 satisfies it today; JBR 25 is the default the plugin
  expects and is what the workspace already provisions.
- When 1.13.0 goes stable, bundle a 25 runtime for `monitor` and turn on
  `AppCdsPrebuild` (or `AotPrebuild` on 25). That is where a 25 runtime pays,
  and it needs no change to the library targets.
- Add `gradle/gradle-daemon-jvm.properties` so the JDK that runs the
  Kotlin/Native compiler is explicit.
- Any FFM adoption forces bytecode 22+ and is therefore a fleet decision, not
  a toolchain one.

## Corrections to the earlier answer

- The claim that Compose Hot Reload works with "JBR 21" was right, but the
  kotlinlang docs currently say only 21 is supported, which is wrong; 1.2.0
  defaults to JBR 25.
- FFM being "the FFI upgrade that fits node-kmp" stands, but note the 2.4.20
  notes show no movement on any Kotlin-side story for it.
