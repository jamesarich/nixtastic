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

**The committed goldens are exactly reproducible.** Built `splat_cli` from
source (clang 21.1.8, arm64 Darwin), converted the committed `.sdf.gz`
fixtures to the `.s16` pages the CLI reads, and ran Calgary: 4 pages loaded,
9,600 radials, output **byte-identical** to
`golden-engine/calgary_30km.{signal,mask}.u8.gz` — 5,760,000 bytes each.
That validates the goldens, the fixtures, and the conversion in one shot, and
it means a *per-architecture* golden gate can assert exact equality rather
than a tolerance.

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

**2. The ±1 dB tolerance hides more than it looks like it does — but the
risk is libm, not the ISA.** The gate is 99.9 % within ±1 dB, so up to 0.1 %
of pixels may be arbitrarily wrong, and they are: up to **7 dB** on Monterey,
with London at **99.9630 %** — 0.063 points of headroom.

This looked like the port's biggest risk. It was measured this session
instead of assumed. Calgary, built from source and run three ways:

| Comparison | Mask mismatch | Within ±1 dB | Bytes differing | Max Δ |
| --- | --- | --- | --- | --- |
| arm64 vs committed golden | — | — | **0 — byte-identical** | 0 |
| x86_64 vs arm64 | 0.0000 % | 99.9981 % | 1,272 / 5,760,000 | 3 |
| wasm vs native (London, Tier B) | 0.0000 % | 99.9630 % | — | 4 |

Two conclusions, and they point opposite ways to the obvious guess:

- **Cross-ISA divergence is small.** arm64 and x86_64 disagree on 0.022 % of
  bytes, max 3 dB, and the coverage **mask — the most user-visible output —
  is bit-identical**. At 99.9981 % it has ~30× the headroom the wasm build
  already ships with.
- **The variable that matters is the libm implementation, not the
  instruction set.** Both builds above use Apple's libm; only codegen
  differed. The 99.963 % figure is what happens when the *implementation*
  changes (emscripten/musl). So iOS, on Apple's libm, should land near
  byte-identical; **Android on bionic is the real unknown** and should be
  expected to behave like the wasm case — passing, with modest margin.

*Caveat:* the x86_64 run was under Rosetta 2 on Apple silicon, so it isolates
ISA and codegen, not native Intel hardware plus a third libm. Phase 1 still
has to measure bionic directly.

**3. The build suppresses every warning — but the code is UBSan-clean.**
Both `engine/build.sh` and `engine/build_native.sh` pass `-std=gnu++11 -w`.
Not "a few warnings disabled" — all of them, on a 2011 FORTRAN translation,
for the life of the project.

Run this session over Calgary with real terrain (4 pages, relief to 3,145 m,
9,600 radials):

| Build | Result |
| --- | --- |
| `-fsanitize=undefined` | **zero findings** |
| `-fsanitize=address` | **zero findings** |

Both verified non-vacuous: UBSan against a control program that does fire,
and ASan by confirming its build still reproduces the golden byte-for-byte —
which matters, because the failure mode below is a binary that silently
executes nothing. This is the best available phase-0 result and it de-risks
the port considerably.

One caveat, and it is a workspace trap worth its own line. Building these
exposed that a workspace trap worth its own line: **the Nix clang 21.1.8
produces a silently non-functional sanitizer binary on darwin.** It
compiles and links, then runs nothing at all — no output even on the
missing-argument path, and a 25-minute run that ended in a timeout with a
0-byte log. Apple's `/usr/bin/clang++` works. Same class as the `.#apple`
shell problem in `CLAUDE.md`: build sanitizer targets with the system
toolchain, or you will "measure" a program that never executed.

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

## Packaging: ship the wasm, not a native binary per platform

The plan above assumed the distribution unit is C++ compiled per target. After
measuring, that is the *second*-best option. The better one is to treat the
**`.wasm` module as the artifact** and give each platform a thin way to
execute it.

### Why — the determinism is free and total

WebAssembly arithmetic is deterministic by specification. The question is
whether this module's maths actually stays inside that guarantee, and it
does: the compiled module has **exactly three imports** (`__cxa_throw`,
`__abort_js`, `emscripten_resize_heap`) and **none of them is a maths
function**. musl's libm is compiled *into* the 58 KB module, so no `sin`,
`atan2` or `pow` ever escapes to the host.

Verified rather than assumed — Calgary, same `.wasm`, two unrelated engines:

| Runtime | Engine | Result |
| --- | --- | --- |
| Node 22 | V8, JIT | baseline |
| wasmtime 48 | Cranelift, AOT | **byte-identical** |
| Chicory 1.4.0 | pure-JVM bytecode compiler | **byte-identical** |

Three unrelated engines, 5,760,000 bytes of signal and mask each, all
identical, and all landing on exactly the same figures against the native
golden (mask 0.0000 %, 99.9973 % within ±1, max Δ 3).

That collapses the entire risk section of this document:

- **One golden, everywhere.** No per-architecture matrix, no bionic unknown,
  no "is the tolerance wide enough for a third libm" question — because there
  is no third libm. The gate becomes **exact byte equality**, which is a far
  stronger contract than `≥99.9 % within ±1 dB`.
- **The 2011 FORTRAN translation runs in a sandbox.** Bounded linear memory,
  no host heap access. A latent bug traps instead of corrupting the app. With
  JNI, a fault in that code takes the whole process down with no Kotlin frame
  in the report.
- **58 KB, one file**, versus an NDK build producing a `.so` per ABI plus an
  XCFramework per Apple platform.

Honest counterweight: we *measured* the native C++ path's cross-ISA
divergence at 99.9981 % with a bit-identical mask, so determinism is an
elegance-and-maintenance win here, not a rescue. The sandboxing and the
single-artifact packaging are the arguments that stand on their own.

### How each platform runs it

A pure-JVM runtime on Android was the attractive version of this — no NDK, no
JNI, no per-ABI binaries. **It was measured and it does not work.**

### Chicory: correct, and ~50× too slow

Calgary 30 km, same `.wasm`, Chicory 1.4.0 on JDK 21, arm64:

| Runtime | Sweep | vs native |
| --- | --- | --- |
| Native arm64, `clang -O2` | **1.83 s** | 1.0× |
| wasm under Node 22 / V8 | **2.29 s** | 1.25× |
| wasm under wasmtime 48 / Cranelift | (byte-identical output) | — |
| **wasm under Chicory 1.4.0, AOT** | **91.1 s** | **~50×** |

Not a misconfiguration: re-run with `InterpreterFallback.FAIL`, which throws
rather than silently interpreting any function the compiler cannot handle, it
completes in **91.45 s** — so every function really was compiled to JVM
bytecode and 91 s *is* compiled speed. Instantiation is only 0.10 s, so the
cost is all in execution. Upstream is explicit that "be the fastest runtime"
is a non-goal.

A minute and a half for a 30 km estimate on a desktop-class M-series core is
several minutes and a flat battery on a phone. Chicory is out for this
workload. (It would be a fine choice for a small, cold, occasional module —
this is a tight numeric loop over 9,600 radials, the worst case for it.)

Chicory's output is nonetheless **byte-identical to Node/V8**, which is
what makes the determinism claim above as strong as it is.

### What is actually in the wasm that native code cannot replicate

Nothing algorithmic. The module is the *same* C++ — `driver.cpp` plus
unmodified `itwom3.0.cpp` — compiled by a different backend. There is no
logic in it that a native library or a KMP library could not contain.

What it has is **a pinned maths library**. And that surface is tiny. Every
libm call in the whole engine, kernel included:

| Function | Calls | Bit-exact across implementations? |
| --- | --- | --- |
| `sqrt` | 55 | **yes** — IEEE 754 requires correct rounding |
| `floor`, `fabs` | 15 | **yes** — exact by definition |
| `exp`, `pow`, `log10`, `log`, `cos`, `sin`, `acos`, `atan`, `asin` | 178 | **no** — IEEE does not require correct rounding for transcendentals |

So **nine functions** are the entire source of implementation-defined
behaviour. wasm is deterministic here only because emscripten compiles
musl's versions of those nine *into* the module.

Measured, to be sure it is libm and not codegen: rebuilding both
architectures with `-ffp-contract=off` — the flag that should remove
FMA-fusion differences — leaves them **still disagreeing**, 1,278 of
5,760,000 bytes against 1,272 with contraction on. Essentially unchanged, and
the mask stays bit-identical either way. (It does perturb arm64 enough to
stop matching the committed golden, which incidentally shows the goldens were
generated with contraction *on*.)

Since both those builds use Apple's libm on one machine, and Apple ships
separately tuned implementations per architecture, the residual divergence is
the maths library — exactly what the wasm result implies.

**Which means the determinism is replicable natively — and this was tested.**

Vendored musl 1.2.5's libm (22 `.c` files: the nine functions, their internal
helpers `__sin`/`__cos`/`__rem_pio2`/`__rem_pio2_large`, the `exp`/`log`/
`log2`/`pow` data tables, and the five `__math_*` error helpers; two tiny
shims for `endian.h` and `features.h`, which musl expects from Linux).
Compiled it and the engine with `-fno-builtin -ffp-contract=off`, and linked
the musl objects ahead of libSystem — confirmed with `nm -m` that all nine
resolve into `__TEXT`, not as dynamic imports.

Calgary, both architectures:

| Build | arm64 vs x86_64 | vs wasm |
| --- | --- | --- |
| Platform libm, default flags | 1,272 / 5,760,000 differ, max 3 | — |
| Platform libm, `-ffp-contract=off` | 1,278 differ, max 2 | — |
| Vendored musl, contract off on engine **only** | 1,119 differ, max 2 | 1,119 differ |
| **Vendored musl, contract off everywhere** | **BYTE-IDENTICAL** | **BYTE-IDENTICAL** |

The third row is the instructive failure: `-ffp-contract=off` has to reach
**musl's own sources too**, not just the engine's. musl's `pow`/`exp`/`log`
are full of `a*b+c`, arm64 fuses them and x86_64 does not, and leaving that
flag off the libm build silently reintroduces the divergence you vendored the
library to remove.

With it applied everywhere, a native build produces **the same bytes as the
wasm build**, on both architectures. That is the whole of what wasm was
buying.

Cost, measured on the same machine:

| Build | Calgary 30 km | vs fastest | Deterministic |
| --- | --- | --- | --- |
| Native, Apple libm | **1.84 s** | 1.00× | no |
| Native, Apple libm, no FMA | 1.84 s | 1.00× | no |
| **Native, vendored musl, no FMA** | **2.45 s** | **1.33×** | **yes** |
| wasm under Node/V8 | 2.29 s | 1.24× | yes |
| wasm under Chicory AOT | 91.1 s | 50× | yes |

**33 % is the price of exact cross-platform determinism**, and it buys
something stronger than the current tolerance gate: the golden becomes an
exact byte comparison instead of "≥99.9 % within ±1 dB".

Two consequences worth planning for:

- **The goldens need a one-time re-baseline** to the vendored build; they were
  generated with Apple's libm and FMA contraction on. Conveniently the wasm
  build already produces exactly the new bytes, so **one golden serves the web
  build and every native target**, and Tier B stops being a tolerance.
- **Still untested:** Android/bionic with the NDK's clang, and real Intel
  silicon rather than Rosetta. The mechanism is proven and the remaining
  variables (compiler build, OS) are far weaker than libm and ISA were — but
  it is a CI matrix job, not an assumption.

Recoverable performance, if 33 % ever matters: vendor only the hot functions,
or use a faster fixed-source libm. Not worth doing speculatively.

### Rethinking the model: ITU-R P.1812 instead of ITM

Everything above assumes the engine must stay SPLAT!'s ITM. Worth questioning,
because ITM is a 1968 statistical model spanning 20 MHz - 20 GHz, and this is a
tool for visualising one ISM band.

**ITU-R P.1812** is the modern answer to exactly this problem: *"a path-specific
propagation prediction method for point-to-area terrestrial services in the
frequency range 30 MHz to 6000 MHz"*. Point-to-area is the site planner's
shape, and 30 MHz - 6 GHz covers every band Meshtastic uses with none of ITM's
dead range. Current revision is P.1812-8; ITM has not moved since 2011.

The decisive difference is not accuracy, it is **validatability**:

| | ITM / ITWOM (today) | ITU-R P.1812 |
| --- | --- | --- |
| Spec | a 2011 C++ file, FORTRAN lineage | a maintained ITU Recommendation |
| Reference implementation | none; the code *is* the spec | official, ITU-R WP 3K approved ([MATLAB/Octave](https://github.com/eeveetza/p1812), [Python](https://github.com/eeveetza/Py1812)) |
| Conformance suite | **none** - we had to generate one | **shipped**: 19 validation profiles, 64 result files |
| Failure localisation | aggregate pixel diff | **74 logged intermediates per case** |

That last row is what changes the argument. The objection to a Kotlin port was
never arithmetic - it was that four goldens cannot validate a reimplementation
of a regime-switching model. P.1812's validation logs carry every intermediate
in the chain (`Lbfs`, `Lbulla`, `Lbulls`, `Ldsph`, `Ld50`, `Ldp`, `Lba`,
`Lbs`, `Lbc`, `Lb` ...), so a port that gets Bullington diffraction right but
spherical-earth diffraction wrong is told *which equation*. Porting ITWOM is a
leap; porting P.1812 is a checklist.

The reference Python core is ~3,180 lines - comparable to `itwom3.0.cpp`'s
2,863, so this is not a line-count win. It is a *traceability* win: each block
maps to a numbered equation in a published Recommendation, and the licence
explicitly permits derivative works.

**This makes a KMP implementation defensible**, which it was not before: one
Kotlin implementation for android, desktop, iOS and web, no NDK, no JNI, no
XCFramework, no per-ABI `.so` - validated against an official suite rather
than against goldens we generated ourselves.

Costs to weigh honestly: it stops being "the same code SPLAT! runs", results
will differ from today's maps (P.1812 is a different model, not a better
implementation of the same one), and Kotlin/Native performance on the radial
sweep is unmeasured.

### Other directions worth knowing about

- **Newer SPLAT! lineage.** [Signal-Server](https://github.com/Cloud-RF/Signal-Server)
  is the actively-maintained SPLAT! derivative (forks updated 2025), adding
  Hata, ECC33, SUI, COST231 and ITU models behind one CLI. Still SPLAT!-shaped.
- **[crc-covlib](https://github.com/ic-crc/crc-covlib)** (Communications
  Research Centre Canada) - C++/Python, implements P.1812-7, P.452, P.2108
  clutter loss, Longley-Rice, plus ML-based path-loss models. The closest
  thing to a modern drop-in for the whole engine.
- **Viewshed instead of a propagation model.** A line-of-sight + Fresnel
  clearance map over a DEM is far lighter than ITM, is a pure geometry problem,
  and is genuinely GPU-friendly (unlike ITM, which is branchy scalar code).
  `gdal_viewshed` and GRASS `r.viewshed` are mature. **But it loses
  diffraction** - and "does it get over that ridge" is precisely what
  Meshtastic users ask. Best as a *fast preview layer* while the real model
  runs, not as the model.
- **Better terrain is a bigger win than a better model.** SRTM (2000, ~10-16 m
  RMSE) vs Copernicus GLO-30 (~4 m RMSE), or USGS 3DEP at 10 m - and 1 m lidar
  in much of the US. The org already has a client-friendly path to modern
  elevation: **Mapterhorn**, which `android` and `apple` already use for
  terrain.
- **Clutter is the weakest input, by far.** Today it is a single scalar height
  applied everywhere. P.1812 takes a *clutter profile*, and ESA WorldCover
  gives 10 m global land cover - forest, urban, water - that maps directly to
  representative clutter heights per pixel. Likely the single largest accuracy
  improvement available, and independent of which model is used.
- **Ground truth nobody else has.** Meshtastic nodes report position and SNR,
  and MQTT carries observed links. Predicted coverage could be validated - and
  calibrated - against links the mesh actually made. No RF library can offer
  that; it is the org's unique asset and it would make any model choice
  defensible with measurements rather than argument.

### Recommended packaging

| Platform | Engine | Native code shipped |
| --- | --- | --- |
| Web | the existing wasm build | none |
| Android | C++, NDK, `.so` per ABI | one library |
| iOS | C++, static lib in an XCFramework | one library |
| Desktop (JVM) | JNI to the same library, or Panama on JDK 22+ | one library |

Plain C++ per target, platform libm, existing tolerance gate. The wasm build
stays as the web target and as a free cross-check.

<details>
<summary>If pinning ever becomes necessary: vendoring musl's libm (tested, works)</summary>

Vendoring nine functions gets the same bytes as wasm with no codegen hop and
ordinary `.a`/`.so` packaging.

| Platform | Engine | Native code shipped |
| --- | --- | --- |
| Web | the existing wasm build | none |
| Android | C++ + vendored musl, NDK, `.so` per ABI | one library |
| iOS | C++ + vendored musl, static lib in an XCFramework | one library |
| Desktop (JVM) | JNI to the same library, or Panama on JDK 22+ | one library |

</details>

<details>
<summary>Superseded: the wasm2c plan</summary>


| Platform | Execution | Native code shipped |
| --- | --- | --- |
| Web | as today | none |
| Android | **wasm2c** → generated C → NDK build, `.so` per ABI | one library |
| iOS | **wasm2c** → generated C → static lib in an XCFramework | one library |
| Desktop (JVM) | JNI to the same library, or Panama on JDK 22+ | one library |

`wasm2c` (from wabt) compiles the module to portable C at *build* time,
preserving wasm semantics — the bundled musl, the bounds checks — at native
speed with no runtime dependency, and no JIT, which iOS forbids anyway.

The wasm module therefore stays the **source of truth and the portable
intermediate representation** — the thing that is specified, tested and
byte-reproducible across runtimes — but it is compiled to native code at
build time rather than executed on device. That is still better than
compiling the C++ per platform, because the C++ route lets libm and codegen
vary and the wasm route provably does not. It just does not get you out of
shipping a native library.

**One thing left to verify:** that `wasm2c` output keeps bit-exact FP.

</details>

### What this changes about the ABI

wasm's import mechanism is better than a C ABI at exactly the thing this
engine needs, and it is worth redesigning around.

Today the client drives the tiling: `splat_page_count` → `splat_page_info` →
`splat_load_page`, which means every client must understand SDF cell order,
west-positive 0–360 longitude, and 1°×1° page geometry. Three clients
reimplementing that is three chances to get it subtly wrong.

**Invert it.** The module *imports* a `fetch_tile(lat, lon) -> ptr` callback;
the host supplies networking, gzip and caching, and the module keeps all the
geodesy. The public API each platform then exposes is one call:

```
coverage(site, radio, environment) -> { grid, bounds, contours, stats }
```

No pages, no radials, no feet, no west-positive longitude — those become
internal. The resumable radial loop stays, but as progress and cancellation
on that one call, which is what Kotlin `Flow` and Swift `AsyncSequence` want
anyway.

And ship the **parameter schema alongside the module** — keys, defaults,
ranges, colour scales, as one JSON document in the same release. That is what
kills the `store.ts` / `SitePlannerParams.kt` / `SitePlannerParameters.swift`
triplication, and it costs nothing once there is a release artifact to attach
it to.

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
| **0** | ~~UBSan + ASan over the native build~~ **done — both clean**. Remaining: commit the `.s16` terrain so the CLI reproduces goldens from a clean checkout (finding 5); widen the corpus — HD, antimeridian, high latitude, and a generated sweep over frequency / climate / resolution / environment (see "Why not a Kotlin/KMP or Swift reimplementation"). | A corpus wide enough to port against. ~1 day. |
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

- **libm divergence on Android (bionic).** Measured down from "biggest
  risk": cross-ISA codegen costs only 0.002 points, but a different libm
  *implementation* costs ~0.04 (the wasm figure). iOS shares Apple's libm and
  should be near-exact; bionic is the one genuine unknown. Mitigation:
  measure it in phase 1, on-device or in an emulator, before any integration
  work — and report the difference distribution, not a pass fraction. If it
  lands under 99.9 %, understand which pixels moved; do not lower the gate.
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

# sanitizers (phase 0) — NOTE: system clang, not the Nix one (see finding 3)
env -u DEVELOPER_DIR -u SDKROOT -u CC -u CXX -u NIX_CC PATH="/usr/bin:/bin" \
  clang++ -O1 -g -std=gnu++11 -w -fsanitize=undefined \
  -o engine/build/splat_cli_ubsan engine/driver.cpp engine/native/main.cpp splat/itwom3.0.cpp
# ...and confirm the instrumentation is live, or a clean result means nothing:
#   int main(){ int x=1,s=33; return x<<s; }   must report a runtime error

# cross-ISA check: same source, two architectures, diff the rasters
clang++ -arch x86_64 -O2 -std=gnu++11 -w -o splat_cli_x86 engine/driver.cpp \
  engine/native/main.cpp splat/itwom3.0.cpp
```

## Related

- [`meshtastic-site-planner/ARCHITECTURE.md`](https://github.com/meshtastic/meshtastic-site-planner/blob/main/ARCHITECTURE.md) — how the web app and engine work today. Accurate except finding 1.
- [`docs/on-device-mobile.md`](https://github.com/meshtastic/meshtastic-site-planner/blob/main/docs/on-device-mobile.md) — the original proposal this plans.
- [`engine/driver.h`](https://github.com/meshtastic/meshtastic-site-planner/blob/main/engine/driver.h) — the C ABI as it stands.
- [`cross-repo-contracts.md`](./cross-repo-contracts.md) — the wire-level contracts this sits beside.
