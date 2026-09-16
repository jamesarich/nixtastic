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

## What to use instead

**Kermit** (Touchlab), the KMP logging library, ships a `LogWriter` per platform
and routes to each one's native sink:

| platform | default writer | reaches |
| --- | --- | --- |
| Apple | `OSLogWriter` | `os_log`, so the **unified log** |
| Android | `LogcatWriter` | Logcat |
| JS | `ConsoleWriter` | browser console |
| other | `CommonWriter` | `println` |

`OSLogWriter` is the whole point: os_log is readable by `pymobiledevice3 syslog`,
Console.app and a sysdiagnose, from a device that is merely connected - no
foreground console attach, no owning stdout, and it keeps working when the app is
backgrounded.

A custom sink is one method:

```kotlin
class YourCustomWriter : LogWriter() {
    override fun log(severity: Severity, message: String, tag: String, throwable: Throwable?) { }
}
```

which is the seam for feeding the monitor app's own on-screen log, or a file on
the headless node, from the same call sites.

**One caveat worth carrying:** Kermit's own `XcodeSeverityWriter` writes
throwables with `println` specifically *to avoid os_log truncating long strings*.
So os_log is right for the stream and wrong for a 500-byte packet dump - keep
frame hexdumps on a writer that does not truncate.

## Why this is worth doing rather than noting

Every bearer measurement this session was read from one of two places: the node's
own stdout, or the firmware's log over the phone API. Where a third view existed -
both ends of a BLE link traced at once - the conclusions held. Where only one
existed, six of them were wrong. Making the Apple side's logs visible without a
console attach is the cheapest way to get a second view on the platform that has
none today.
