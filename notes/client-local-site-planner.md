# Client-local site planner

A plan for computing RF coverage **on the client** — Android, Apple and the
desktop app — instead of driving the hosted planner through a headless
browser. The web planner stays; it becomes a fourth consumer of one shared
engine rather than the thing every other client remote-controls.

Spans `meshtastic-site-planner`, `android`, `apple`, and whatever repo the
engine ends up in. Written 2026-09-16. It is the execution plan for
[`docs/on-device-mobile.md`](https://github.com/meshtastic/meshtastic-site-planner/blob/main/docs/on-device-mobile.md),
whose open questions are now answerable — and one of whose assumptions was
wrong.

Part 1 is an **independent audit** of the existing engine, because the plan
rests on whether that engine can be trusted and the answer was not obvious
from its own documentation. Part 2 is the plan.

---

# Part 1 — Audit of the existing engine

Everything below was verified against primary sources in this session, not
taken from `ARCHITECTURE.md`. Where a claim in the repo held up, that is
stated; where it did not, that is stated too.

## Verified — these claims are true

**The ITM kernel really is unmodified SPLAT! 1.4.2.** The repo says
`splat/itwom3.0.cpp` is "compiled unmodified". The `splat` submodule points
at `github.com/jmcmellen/splat` — a third-party fork, pinned at `08f06f5`
(2015-08-18, itself a merge of `jsr38/master`), which is *not* an obviously
trustworthy chain. So it was checked against the source:

```
canonical splat-1.4.2.tar.bz2, fetched from www.qsl.net/kd2bd/splat.html
  itwom3.0.cpp  md5 9e03fd5afea43397ce41301a4b14de44
vendored submodule
  itwom3.0.cpp  md5 9e03fd5afea43397ce41301a4b14de44
```

Byte-identical. `splat.cpp` is identical too. The fork introduced no changes
to the model.

**`driver.cpp`'s citations are accurate.** Its header claims specific SPLAT!
line numbers for the functions it ported. Seven were spot-checked against
canonical 1.4.2 and all seven land exactly on the named function:

| Cited | Line 222 | 238 | 250 | 436 | 492 | 509 | 582 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Actual | `arccos` | `ReduceAngle` | `LonDiff` | `GetElevation` | `Distance` | `Azimuth` | `ReadPath` |

**Tier A goldens are genuinely independent, not circular.** The four
`test/fixtures/golden/*.tif` files were harvested from the *legacy FastAPI /
SPLAT! backend* via `test/fixtures/generate.sh` (docker compose, POST each
case, save the GeoTIFF). They are not regenerated from the engine under test.
The script is honest that the backend has since been deleted from the repo.

**Tier B runs for real, and asserts real things.** `test/golden/wasm_golden.test.ts`
compares the wasm engine against the native goldens with exact geometry
equality, `maskMismatch ≤ 0.1 %`, `≥99.9 %` of jointly-covered pixels within
±1 dB — and an `expect(joint).toBeGreaterThan(0)` guard so it cannot pass
vacuously. Run this session:

| Case | Mask mismatch | Within ±1 | Joint pixels | **Max diff** |
| --- | --- | --- | --- | --- |
| calgary_30km | 0.0000 % | 99.9973 % | 524,799 | 3 |
| cape_town_20km | 0.0000 % | 99.9926 % | 176,553 | 4 |
| london_15km | 0.0000 % | **99.9630 %** | 132,518 | 4 |
| monterey_25km | 0.0000 % | 99.9930 % | 285,046 | **7** |

**The goldens run on complete real terrain.** `loadPageData()` returns `null`
for a missing page, which would silently degrade a case to sea level and make
both sides agree on nothing. Instrumented directly: every case needs 2–4
pages and **zero are missing**. The ten committed `.sdf.gz` files cover the
four cases exactly, including the London prime-meridian wrap
(`51:52:359:0` + `51:52:0:1`) and Cape Town's southern-hemisphere
west-positive conversion.

**The slice-invariance test is real.** `test/engine/slices.test.ts` runs a
full sweep, runs four slices, merges first-touch, and byte-compares both mask
and signal buffers. Not a smoke test.

**CI's reproducibility guard is real.** It rebuilds the wasm from source in
the pinned `emscripten/emsdk:4.0.20` image and runs `git diff --exit-code
src/engine/generated`.

## Findings — what does not hold up

**1. Tier A is not a gate, despite the table calling it one.**
`ARCHITECTURE.md` presents Tier A with a "Gate" column and measured numbers.
It is not in CI: it needs `scripts/compare_golden.py`, GDAL, and
`test/fixtures/terrain.s16/` — which is not committed. It was measured once,
by hand, and **the backend it measured against has been deleted from the
repo**. Nothing re-checks it and nothing can, without resurrecting an old
commit and a Docker image. Treat "100.000 % mask agreement" as a historical
measurement, not a standing guarantee.

**2. The ±1 dB tolerance hides more than it looks like it does.** The gate is
99.9 % within ±1 dB, so up to 0.1 % of pixels may be arbitrarily wrong — and
they are, up to **7 dB** on Monterey. More importantly **London sits at
99.9630 %, which is 0.063 percentage points of headroom** over the floor.
That margin exists between two libm implementations (macOS and
emscripten/musl). A third — bionic on Android, Apple's on iOS — is a coin
flip against that margin. This converts the ARM64 port's biggest risk from
speculative to quantified, and it is the single most important number in
this document.

**3. The build suppresses every warning.** Both `engine/build.sh` and
`engine/build_native.sh` pass `-std=gnu++11 -w`. Not "a few warnings
disabled" — all of them, on a 2011 FORTRAN translation, for the entire life
of the project. No sanitizer has ever been run over it (a UBSan/ASan build
was started this session; result appended below when it lands).

**4. `driver.cpp` carries avoidable C-isms.** `Page` holds raw
`short*`/`unsigned char*` from `calloc`; constants are `#define`; the
`std::vector<Engine*>` handle table never reuses or frees a slot, so handles
grow without bound — irrelevant for one page load, wrong for an app that runs
many estimates across a session.

**5. The native CLI and the test fixtures read different terrain formats.**
`splat_cli --terrain` wants raw `.s16` pages; the committed fixtures are
`.sdf.gz` (SPLAT!'s ASCII SDF). The CLI silently reports "no terrain file,
sea level" and carries on. That is why Tier A cannot be re-run from a clean
checkout, and it is a trap for anyone who assumes a CLI run reproduces a
golden.

## Verdict

**The engine is trustworthy; the harness around it is thinner than it
claims.** The physics is provably stock SPLAT! 1.4.2, the port is accurately
documented, and the tests that run assert real things on real data. What is
missing is exactly the scaffolding a multi-platform build needs: no warnings,
no sanitizers, no multi-architecture golden gate, and a Tier A tier that can
no longer be executed.

That is a good starting position. Nothing here needs to be thrown away for
correctness reasons — but nothing here has been tested on ARM64 either, and
finding 2 says that is not a formality.

---

# Part 2 — The plan

## Why do this at all

Every client today reaches coverage through a browser:

| Host | Mechanism | Result returns |
| --- | --- | --- |
| android (both flavours) | 319-line headless `WebView`, `addJavascriptInterface("__meshtasticNative")`, 45 s timeout | automatically, as a GeoJSON layer |
| apple | 260-line `WKWebView`, JS shim injected `.atDocumentStart` (WKWebView has no `addJavascriptInterface`) | automatically, as a GeoJSON layer |
| desktop | system browser | **by hand** — export `.geojson`, re-import via the layers sheet |

`CoverageEstimateRunner.swift` states the premise in its header: *"There is
no headless params→GeoJSON HTTP API; the planner is a client-side WASM
SPLAT!/ITM simulator, so coverage is only ever computed in a WebView."* True
as a deployment fact, false as an architectural one — the engine builds
natively today, and that build is what generates the goldens.

What the change buys, in order of weight:

1. **Offline.** Every path today needs `site.meshtastic.org` *and* the
   terrain bucket reachable at the moment the user wants an answer.
   Meshtastic users plan coverage where neither is true.
2. **Desktop and F-Droid get coverage properly** — desktop currently makes
   the user export and re-import a file, because putting JCEF back into the
   jlink'd runtime measured ~3.5× the size of the whole application.
3. **The WebView plumbing goes.** Android's is load-bearing in ways that read
   as a warning: `alpha(0)` but must stay attached and 280 dp or WebGL never
   gets a context; a deferred retry for the system-WebView provider-update
   race; `shouldOverrideUrlLoading` locking navigation to the planner's
   origin so nothing else can reach `onCoverage`.
4. **One parameter schema.** Defaults and validation ranges exist three times
   — `src/store.ts`, `SitePlannerParams.kt` (131 lines),
   `SitePlannerParameters.swift` (227 lines) — kept in sync by comments that
   name the source file. Nothing enforces it.

## Rewrite the engine, freeze the kernel

The brief is "don't carry in broken old code; make it modern and efficient."
Part 1 says that is satisfiable everywhere except one file:

- **`driver.cpp` (1,079 lines) gets rewritten** — findings 3 and 4 above are
  the specification for what changes.
- **`itwom3.0.cpp` (2,863 lines) is frozen.** It is not old code to clean up;
  it is the *conformance oracle*, now provably stock SPLAT! 1.4.2. Every
  golden is defined by what it computes. Modernise it and there is nothing
  left to be correct against.

So: `itwom3.0.cpp` becomes a vendored, pinned dependency in its own build
target with its own flags (`-w` stays *there*, and nowhere else), reached
only through a typed interface. Nothing else inherits its era.

A clean-room modern ITM is a legitimate later goal, gated on widening the
golden corpus first — four scenarios cannot validate a reimplementation of a
model this branchy. Listed as an optional phase, not scoped here.

## Four constraints that decide whether "modern" breaks parity

### 1. Floating-point determinism — the quantified risk

Finding 2 is the whole of it: London has 0.063 points of margin against the
99.9 % floor, and that margin is currently spent on a two-libm disagreement.
Android's bionic and Apple's libm are two more.

**Rules:** pin `-ffp-contract=off` on every target (clang defaults to `on`,
so ARM64 fuses multiply-add where x86_64 may not, and wasm has no FMA at
all); forbid `-ffast-math` and `-ffinite-math-only` outright; run the golden
gate on **every** architecture in CI, not one.

**And re-baseline the tolerance honestly.** If ARM64 lands at 99.91 %, the
right response is to understand which pixels moved and why — not to lower the
gate until it passes. Phase 1 should report the *distribution* of differences,
not just the pass fraction.

### 2. Undefined behaviour in the oracle

Finding 3: never sanitised. UB that produces stable output on x86_64 can
produce *differently* stable output on ARM64, which would look like a porting
bug and is not one. One CI job under `-fsanitize=undefined,address` over the
native golden run. This is phase 0 because it changes the FP plan if it finds
anything.

### 3. First-touch merge survives threads only if outputs stay per-slice

The N-worker result is bit-identical today because each worker owns a
contiguous slice of the canonical radial order and merging is first-touch in
ascending slice order — verified by a real byte-comparison test.

Native threads sharing one set of elevation pages is safe: elevation is
read-only, and that is the memory win (1× instead of N×; HD is ~26 MB/page
against a 16-page cap, so 416 MB — on a phone, that is the number that
matters). The **output** mask and signal grids are different: N threads
writing one shared buffer destroys the ordering invariant. Per-slice output
buffers plus the ordered merge stay.

Write this where the optimiser will find it, or someone deduplicates the
buffers and the invariant test is the only thing that notices.

### 4. The terrain seam is I/O versus math

`on-device-mobile.md` recommends moving terrain into C++. Right for the
*transform*, wrong for the pipeline:

- **Into the core:** the GDAL-style area-weighted downsample and the
  `srtm2sdf` / `srtm2sdf-hd` transforms. Pure functions, ~400 lines of TS,
  pinned byte-for-byte by `terrain.s16/` and the `*_1201_avg_i2le` goldens.
- **Stays host-side:** fetching `.hgt.gz` and gunzipping. Every platform has
  a networking stack and a gzip decoder; dragging zlib into the core costs a
  dependency on three toolchains and buys nothing.

Seam: `splat_make_page(const int16_t *raw3601, int ippd, int16_t *out)`.
Bytes in, engine page out. The web app calls it through wasm and deletes its
own transform.

**Fix finding 5 while here:** one terrain input format shared by the CLI, the
tests and the apps, and a `--terrain` that *fails loudly* on a missing page
instead of quietly substituting sea level.

## Shape

```
        ┌──────────────────────────────────────────────┐
        │ oracle/   itwom3.0.cpp — FROZEN, vendored,    │
        │           own target, own flags (-w)          │
        │           md5 9e03fd5a… == SPLAT! 1.4.2       │
        └──────────────────────────────────────────────┘
                              ▲ typed interface only
        ┌──────────────────────────────────────────────┐
        │ core/     new C++20: pages, region, radial    │
        │           sweep, rasterize, contours,         │
        │           terrain transform                   │
        │           -Wall -Wextra -Wpedantic -Werror    │
        └──────────────────────────────────────────────┘
                              ▲
        ┌──────────────────────────────────────────────┐
        │ abi/      C ABI — versioned params struct,    │
        │           SI units, resumable sweep           │
        └──────────────────────────────────────────────┘
           ▲              ▲              ▲          ▲
      JNI shim      Swift module    Emscripten    (desktop
      + Kotlin      map + Swift     + TS           via JNI)
```

**No KMP in the middle.** It is the reflex in this workspace and it is wrong
here: apple consumes no Kotlin — `project.yml` has no KMP artifact, and
`TAKPacket-SDK` ships apple a *hand-written Swift* implementation under
`swift/` beside the Kotlin one. A C ABI reaches both platforms without it.

### What changes at the ABI

`splat_create` takes sixteen positional doubles and two ints, with heights
**in feet** because the legacy backend wrote QTH files without the meters
suffix. That quirk must stay reproducible; it should not be the ABI's native
unit.

- A versioned `splat_params_v1` struct, not a positional list — adding a
  parameter stops being a breaking change for four callers.
- SI at the boundary: metres, watts, Hz. The feet round-trip becomes an
  explicit `legacy_tx_height_as_feet` flag, which is what the goldens set and
  the UI does not. `src/engine/params.ts` already models the distinction.
- **Contours move into the core.** `coverageContours()` is d3-contour today;
  marching squares over a `uint8` grid is a couple of hundred lines of C++,
  and it makes the contract **params + pages in, GeoJSON out**. All four
  consumers then render identical bands, and apple feeds `MKGeoJSONDecoder`
  straight into the polygon-overlay pipeline it already built for PMTiles.

### Toolchain baseline

C++20 everywhere. Individual C++23 features — `std::mdspan` is the obvious
want for the `[ippd][ippd]` grids — are gated on the *intersection* of
Emscripten 4.0.20's clang, the chosen NDK's clang, and Xcode 26's libc++.
The CI matrix decides; this note deliberately asserts no list, because a
stale one here would be worse than none.

CMake ≥3.28, one preset per target. `-Wall -Wextra -Wpedantic -Werror` on
`core/` and `abi/`; the oracle target is the only `-w` exemption. The golden
gate is a CTest target that runs on every architecture.

Packaging: Android via `externalNativeBuild` + a prefab AAR — android has
**no** native build today (`ndkVersion` and `externalNativeBuild` appear
nowhere), so this is greenfield; Apple as an XCFramework behind a SwiftPM
binary target, the channel `TAKPacket-SDK` already uses; wasm as today,
against the new ABI.

## Where the engine lives

**Recommendation: extract it.** `engine/` + `splat/` + `test/fixtures/`
become their own org repo; site-planner becomes a wasm consumer of a released
version.

The reason is the goldens — they are the engine's contract, not the web app's,
and four consumers will pin versions independently (Maven, SwiftPM, npm/wasm).
The org runs this shape already for `kzstd` and `MQTTastic-Client-KMP`.

The counter-argument is real: engine and web app are developed together, CI
rebuilds the wasm and fails on drift, and splitting adds a release hop to
every engine change. If James would rather not, keep it in site-planner and
publish artifacts from there — worse ergonomics, no blocker.

## Phases

| # | Work | Output |
| --- | --- | --- |
| **0** | UBSan/ASan over the existing native build; FP-flag audit; restore a runnable Tier A (fix finding 5, commit the terrain the CLI needs); widen the corpus — HD, antimeridian, high latitude. | A finding, and a corpus wide enough to port against. ~1–2 days. |
| **1** | New `core/` + `abi/` + CMake presets; golden gate green on x86_64 **and** arm64, reporting the difference *distribution*, not just pass/fail. | The engine, measured, on two architectures. |
| **2** | Terrain transform into `core/`; web app calls it via wasm; `srtm.ts`'s transform deleted. | One terrain implementation. |
| **3** | Android: prefab AAR, JNI shim, Kotlin API, on-disk page cache, in-app golden parity test. `SitePlannerRunner.kt` deleted. | Coverage on-device, both flavours. |
| **4** | Apple: XCFramework, Swift over the C ABI (no shim needed), same cache and parity test. `CoverageEstimateRunner.swift` deleted. | Coverage on-device. |
| **5** | Desktop: the same JNI path on the host architecture. | Coverage in-app, no browser, no export/re-import. |
| **6** | "Download this region for offline" — terrain pages, shared with the basemap-pack work. | The actual product goal. |
| **N** | *Optional, gated on phase 0's corpus:* clean-room modern ITM. | Not scoped here. |

Phase 1 ships nothing to a user. Phase 3 is the first release that does.

## Decisions James owes

- [ ] **Extract the engine into its own repo**, or keep it in site-planner
      and publish from there?
- [ ] **SI units at the ABI**, with the legacy feet quirk as an explicit
      flag? (Recommended; goldens keep the quirk either way.)
- [ ] **Is Tier A worth restoring?** It cannot currently be run — the backend
      is deleted. Options: resurrect it from an old commit and pin a Docker
      image, treat the *native* goldens as the new root of trust, or accept
      that parity-with-legacy was a migration-era guarantee that has served
      its purpose. This decides how much phase 0 costs.
- [ ] **Terrain source stays SRTM / AWS `elevation-tiles-prod`** (what the
      goldens pin) or moves to Mapterhorn, which android and apple already
      use for terrain? Moving re-baselines every golden. No recommendation —
      it depends on the answer above.
- [ ] **Clean-room ITM later, or never?** Affects phase 0's corpus investment.

## Risks

- **FP/libm divergence exceeds tolerance on ARM64.** No longer speculative:
  London has 0.063 points of margin. Mitigation: measure in phases 0–1,
  before any app integration, and report distributions.
- **Tier A is unrecoverable if nobody resurrects the backend soon.** Every
  month makes the old commit harder to build (Docker base images, Python
  deps). Mitigation: decide now, in phase 0.
- **AWS `elevation-tiles-prod` is a free public good** with the same failure
  class as CARTO — which just defaced every keyless tile it served.
  Mitigation: the *page format* is the contract, not the URL; a mirror
  becomes a data change, and the phase-6 cache blunts an outage.
- **Three-way schema drift persists until phases 3–4.** Mitigation: it is
  independent of everything here — publish the query contract as one JSON
  file now, vendored by each app with a test asserting the copy matches.
  Worth doing even if none of the rest happens.

## Appendix — reproducing the audit

```bash
# kernel provenance
curl -O https://www.qsl.net/kd2bd/splat-1.4.2.tar.bz2 && tar xjf splat-1.4.2.tar.bz2
git submodule update --init --depth 1 splat
diff splat-1.4.2/itwom3.0.cpp splat/itwom3.0.cpp   # expect: no output

# Tier B, with the real numbers printed per case
pnpm exec vitest run test/golden --reporter=verbose

# sanitizers (phase 0)
clang++ -O1 -g -std=gnu++11 -w -fsanitize=undefined,address \
  -o engine/build/splat_cli_san engine/driver.cpp engine/native/main.cpp splat/itwom3.0.cpp
```

## Related

- [`meshtastic-site-planner/ARCHITECTURE.md`](https://github.com/meshtastic/meshtastic-site-planner/blob/main/ARCHITECTURE.md) — how the web app and engine work today. Accurate except finding 1.
- [`docs/on-device-mobile.md`](https://github.com/meshtastic/meshtastic-site-planner/blob/main/docs/on-device-mobile.md) — the original proposal this plans.
- [`engine/driver.h`](https://github.com/meshtastic/meshtastic-site-planner/blob/main/engine/driver.h) — the C ABI as it stands.
- [`cross-repo-contracts.md`](./cross-repo-contracts.md) — the wire-level contracts this sits beside.
