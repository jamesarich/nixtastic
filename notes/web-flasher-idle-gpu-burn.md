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

Not yet filed upstream.
