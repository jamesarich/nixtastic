# The web flasher burns a GPU while sitting idle

Measured 2026-09-17 against the live site, flasher.meshtastic.org, on darwin
(Apple Silicon). Found because an idle background tab held a Chrome helper at 60%
CPU for 38 hours and the machine's GPU sat at ~54%; closing the tab quieted it.

## The measurements

GPU figures are `Device Utilization %` from
`ioreg -r -d 1 -c IOAccelerator`, sampled once a second with the page idle and
in the foreground. Animations were paused and resumed through
`document.getAnimations()`, which is also how the running set was enumerated.

| State | GPU |
| --- | --- |
| Idle page, as shipped | 35-72% |
| All animations paused | **2-3%** |
| `logo-pulse` only | 69-72% |
| `bounce` only | 70-74% |
| Animations running, every `backdrop-filter` stripped | **5-6%** |

## What it means

Neither half is expensive alone. An animation with no blur costs 5%; blurs with
nothing animating cost 2%. Together they cost seventy.

The page carries **109 elements with a `backdrop-filter`**, seven of them visible
at rest. A `backdrop-filter` has to re-blur whatever is behind it whenever those
pixels change, and a continuously running animation changes pixels sixty times a
second - so every frame re-blurs the lot. Which animation does not matter: either
one alone reproduces the full cost, because the cost is the blur, not the motion.

Two animations run on an idle page:

- **`logo-pulse`**, `LogoHeader.vue:339`, on a 96x96 `.logo-glow::before`. It is
  written the way the advice says to write one - `opacity` and `transform` only,
  `will-change`, `translateZ(0)` - and that is the point: a textbook-cheap
  animation still costs 70% of a GPU when it sits under this many blurs.
- **`bounce`**, `Firmware.vue:209`, on a 16x16 `svg`, gated on
  `store.couldntFetchFirmwareApi`. **It was running**, so the firmware API fetch
  had failed - see [`api-slow-swr-timeout-staleness`]: api.meshtastic.org answers
  in 20-60 s against much shorter client deadlines. So the second animation is
  not a design choice at all, it is an error indicator that a slow API leaves
  running forever.

## Why nobody notices

Nothing is visibly wrong. The page looks still. The cost lands on a background
tab, where it reads as fan noise and battery drain rather than as a page doing
something - and the flasher is exactly the sort of page left open while a device
is being set up.

## Where to fix it

The cheapest real fix is to stop the animations rather than remove the blurs,
since the blurs are the visual design and the animations are decoration:

- Honour `prefers-reduced-motion` on both, which is correct anyway and removes the
  cost for everyone who has asked for it.
- Pause them when the tab is hidden (`document.visibilitychange`), which removes
  the 38-hour background case entirely.
- Reconsider an infinite animation as an API-failure indicator. A failure state
  that animates forever is a permanent cost for a transient problem, and this one
  is triggered by a known-slow endpoint.

Reducing the blur count would help too - 109 is a lot for one page - but the
interaction is the defect, and either side of it can be broken.

## During and after a flash - measured

Reproduced 2026-09-17 on the bench: a Heltec V3 (CP2102, `usbserial-0001`) flashed
with the 2.8.1.67e8aaf nightly at 115200, Update rather than full erase, sampling
GPU and Chrome CPU once every two seconds throughout.

| | Baseline | During flash | After it finished | Animations paused |
| --- | --- | --- | --- | --- |
| GPU | 2-8% | **78-87%** | **77-87%** | **1-3%** |
| Renderer | 2-8% | 77-87% | 77-87% | 1-3% |
| GPU memory | ~650 MB | 1200-2622 MB | ~1300 MB | 567 MB |
| Chrome CPU | 1-4% | 43-89% | 44-62% | 2-4% |
| Load | 1.5 | 3.1 | 2.3 | 2.1 |

**It does not release.** The load after the flash completed is the same as during
it, and only stops when the animations are paused by hand. Renderer utilisation
tracks device utilisation one-to-one throughout, and the page has **no canvas
elements**, so this is compositing, not compute and not terminal rendering.

Visible `backdrop-filter` elements go from **7 at rest to 12 during and after a
flash** - the flash modal's full-viewport overlay plus its panels - while
`logo-pulse` and an 8x8 `pulse` status dot keep animating underneath them. Neither
stops when the flash ends.

One confound was found and excluded: the Claude in Chrome extension injects its
own full-viewport animated overlay with its own `backdrop-filter`. Pausing that
alone left GPU at 81-84%, so the cost is the page's.

## It is an Apple Silicon problem

The same test on `james-pc` - Linux, GeForce GTX 1080, Chrome, window visible and
in front - does not reproduce.

| | Apple Silicon | GTX 1080 |
| --- | --- | --- |
| Flasher open, idle, before any flash | 35-72% | **5%** |
| During a flash | 78-87% | **9-13%**, peak 18 |
| After the flash finished, page idle | 77-87% | **10-13%** |
| GPU memory, before -> after | 650 -> ~1300 MB | 1191 -> ~1370 MiB |
| Chrome CPU during flash | 43-89% | 28-39%, peak 162 |

229 samples on the Linux run, none above 40%. Six to eight times the GPU cost for
identical work.

**But it does not return to baseline on Linux either** - 5% before the flash,
10-13% after, holding about 180 MiB more. So the two defects separate cleanly:
the *magnitude* is an Apple Silicon renderer problem, and the *failure to stop* is
application logic that behaves identically everywhere. Elsewhere it is simply too
cheap to notice. `logo-pulse` is unconditional,
so it runs on both; the page, the firmware and the flash were the same.

The likely reason is the renderer. Apple Silicon is tile-based and deferred, and
the macOS counter reports `Tiler Utilization` pegged alongside `Device
Utilization` - a large `backdrop-filter` forces the blurred region through the
tiler every frame. A discrete card with that much fill rate absorbs the same work
without noticing.

So this is not "the flasher burns everyone's GPU". It is severe on Apple Silicon
and mild on a discrete GPU - which still means every Mac and every iOS device, and
those are the machines most likely to be on battery.

The idle finding above explains the *level* - anything that repaints continuously
costs 70% of a GPU while those blurs are on the page, and a flash repaints
constantly: a progress bar, `animate-spin` spinners, and a **full-viewport
`fixed inset-0 backdrop-blur-sm` modal** (`Flash.vue:41`) whose blur covers
everything moving underneath it.

What explains the *not releasing* is a leak in the serial monitor:

- **Neither buffer is bounded.** `serialMonitorStore.terminalBuffer` is an array
  pushed per line and `rawBuffer` a string appended per chunk, with no `slice`,
  `shift`, `splice` or length check anywhere in the store. Both are reactive Pinia
  state.
- **Nothing clears them automatically.** The only resets are `unlockPort` and the
  component's manual clear button.
- **The component never unmounts.** `SerialMonitor.vue:3` renders on
  `isConnected || terminalBuffer.length > 0`. After a session `isConnected` goes
  false, the buffer is non-empty, so the guard stays true - and the xterm
  instance, its renderer, the fit addon and the `rawBuffer` watcher all stay alive
  for the life of the page.

So the cost has no exit condition. The buffer only grows, the terminal that
renders it is never torn down, and the surrounding blurs re-composite on every
repaint it causes.

Two things that look wrong but are not: the `rawBuffer` watcher
(`SerialMonitor.vue:147`) correctly writes only the delta, and the `.loader`
spinner is gated on `isConnected && rawBuffer.length === 0`, so it stops once data
arrives.

Not yet filed upstream.
