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

## What was built, and what was measured

`MeshLog` now sits in `node-core`, backed by Kermit (an `implementation`
dependency, so no consumer is made to depend on its types). It offers `d/i/w/e`
with lambda messages and a `MeshLogSink` a host can add - an on-screen log, a file
on a headless node, a test's recorder. `gattLog` routes through it.

Kermit 2.2.0 covers every target this library has, the two Linux ones included.

### Three things measured on the iPad, in order

1. **`println` reaches stdout only.** A `devicectl … --console
   --terminate-existing` launch showed eight `MNGATT` lines; `pymobiledevice3
   syslog live` showed none of them. Attaching to an already-running instance
   captures nothing at all - it foregrounds rather than spawns.
2. **Kermit's iOS default is not os_log.** `platformLogWriter()` there is the
   Xcode writer, which is a `println`, so routing through Kermit changed nothing:
   still eight lines on the console, still zero in `syslog`.
3. **`OSLogWriter` did not help either.** Named explicitly through an
   `expect/actual`, rebuilt and installed: still zero in `pymobiledevice3 syslog`,
   and no `MeshMonitor{…}` subsystem of ours appears there at all - the only
   subsystems present are Apple's own frameworks.

Whether that third one is os_log's default redaction of dynamic strings, subsystem
filtering, or the relay simply not carrying third-party os_log, is **not
isolated**. What is settled is the practical part.

### So, for capturing Apple-side logs today

Use `xcrun devicectl device process launch --console --terminate-existing`. It is
the only method measured to work, and the `--terminate-existing` is not optional.

`MeshLogSink` is the path that does not depend on any of this: have the monitor
app write its own log to a file or the screen, and read that.

## Why it was worth doing anyway

Every bearer measurement this session was read from one of two places, and where
a third view existed - both ends of a BLE link traced at once - the conclusions
held. Where only one did, eight of them were wrong. `MeshLog` is the seam that
makes a second view possible on every platform; the Apple *transport* for it is
still open.
