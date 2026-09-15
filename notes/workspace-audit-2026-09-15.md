# Workspace audit - friction, stale instructions, Nix practice (2026-09-15)

Sweep of the workspace itself: recent session transcripts for friction, the
agent docs for stale or wrong instructions, the flake for Nix anti-patterns,
and the dev shells against what each repo's CI actually declares. Every
finding below was reproduced on this machine on 2026-09-15; claims I could not
reproduce are in section 6 so they are not re-investigated.

Method for the friction half: 104 session transcripts under
`~/.claude/projects/-Users-james-nixtastic/` plus every other workspace slug,
digested to user turns, Bash commands and `is_error` tool results - 2508 user
turns, 26798 Bash calls, 1007 errors since 2026-08-25. Frequency, not anecdote,
is what ranks the list.

**Status after the fix pass (same day).** Findings 1, 2, 4, 5, 7, 8, 9 and most
of 10 are applied and committed; finding 3 is half done. The gate
(`nix flake check --all-systems --no-build`, built `nix flake check` including
`tools-tests`) passes on the updated lock, and `nix run .#doctor` is clean at 0
warnings. Two new fixtures - `T38` (direnv trust) and `T39` (launcher gc roots)
- cover the new behaviour. What is left is listed under "Still open" at the
bottom; the short version is that **one decision is yours**: whether the weekly
lock workflow may merge its own PR.

---

## 1. `.#apple` breaks real Xcode, and the shell is the right place to fix it

**Applied.** The highest-value item, because the workaround was five lines of
`env -u` that a human or agent had to retype at every single invocation.

`CLAUDE.md` devotes a paragraph to "Any active Nix shell breaks `apple`'s real
Xcode builds" and prescribes:

```
env -u DEVELOPER_DIR -u SDKROOT -u CC -u CXX -u LD -u AR -u NM -u RANLIB \
    -u STRIP -u NIX_CC PATH="/usr/bin:/bin:/usr/sbin:/sbin" xcodebuild …
```

Measured inside `nix develop .#apple` before the change:

| var | value |
| --- | --- |
| `DEVELOPER_DIR` | `/nix/store/…-apple-sdk-14.4` |
| `SDKROOT` | `…/MacOSX.platform/Developer/SDKs/MacOSX.sdk` |
| `CC` / `CXX` | `clang` → `/nix/store/…-clang-wrapper-21.1.8/bin/clang` |
| `xcrun` | `/nix/store/…-xcbuild-0.1.1-unstable-2019-11-20-xcrun/bin/xcrun` |

`mkShellNoCC` does not prevent this: the vars come from nixpkgs' `apple-sdk`
**setup hook**, which propagates through any darwin shell
([NixOS/nixpkgs#355486](https://github.com/NixOS/nixpkgs/issues/355486), still
open; `unset DEVELOPER_DIR SDKROOT` is the accepted workaround and nothing has
landed upstream). The `xcrun` on PATH is an xcbuild stub from **2019**.

The shellHook now unsets the ten vars and drops only the xcbuild `xcrun` entry
from PATH - a blanket `/usr/bin` prepend would shadow the Nix `git`/`gh`/`rg`
the shell exists to provide. Verified after:

```
DEVELOPER_DIR <unset>   xcrun      /usr/bin/xcrun
SDKROOT       <unset>   xcodebuild /usr/bin/xcodebuild
CC/CXX/NIX_CC <unset>   git        /nix/store/…-git-2.55.0/bin/git
                        swiftlint  /nix/store/…-swiftlint-0.65.0/bin/swiftlint

$ xcrun --sdk macosx --show-sdk-path
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk
```

That last call is the exact one `CLAUDE.md` documents as failing with `unable
to find sdk: 'macosx'`. Re-verified through the path agents actually use, not
just `nix develop` - see finding 2 for why that mattered:

```
$ just in apple xcrun --sdk macosx --show-sdk-path
/Applications/Xcode.app/…/MacOSX26.5.sdk
```

**Follow-up - the fix makes prose stale in nine places.** The rule should become
"the `.#apple` shell handles this; in some *other* Nix shell on darwin the
incantation still applies." `grep -rln DEVELOPER_DIR` finds it in:

- `CLAUDE.md` (the canonical bullet)
- `notes/`: `ble-mesh-transport.md`, `wifi-aware-cross-platform.md`,
  `handoff-multi-transport.md`
- memories: `ble-mesh-interop-bench`, `driving-desktop-app`,
  `firmware-native-tests-on-macos`, `james-pc-nix-gotchas`, `kmp-build-gotchas`

Left for a docs pass so the shell fix and the prose land separately - but all
nine need the same edit, and the memories matter most because they are what a
fresh session reads.

## 2. `direnv exec` - the prescribed non-interactive path - was dead in 7 of 19 repos

**Applied.** Found while verifying finding 1 through the path agents actually
use rather than through `nix develop`.

`CLAUDE.md` is explicit: "The direnv hook fires only in interactive shells -
scripts and agent subshells get no repo environment, so Gradle silently runs
unpinned. From non-interactive contexts use `direnv exec <repo-or-worktree>
<cmd>`." `just in` and `just wt` are built on exactly that. It did not work:

```
$ just in apple xcrun --sdk macosx --show-sdk-path
direnv: error /Users/james/nixtastic/apple/.envrc is blocked. Run `direnv allow`
```

Surveying `direnv status` across every primary checkout - `Found RC allowed 0`
means allowed, `1` means blocked - **7 of 19 were blocked**: `device-ui`,
`apple`, `gradle-flatpak-sources`, `labeltastic`, `protobufs`, `design`,
`meshtastic`. Plus 2 of 48 worktrees (`apple/feat-bootloader-factory-erase`,
`device-ui/screen-mirror-poc`).

A blocked `.envrc` fails loudly when you run `just in`, but the *interactive*
shell just silently has no repo environment - which is the same class of
failure as everything else in the "fails silently" list. All nine files are
`sync`-generated (checked before allowing), so `direnv allow`ing them is safe;
done for all nine.

Why `doctor` missed it: it checks that each `.envrc` names the right shell
(`envrc shells   66 file(s) match the table`) but never asks whether direnv
will actually *load* it.

**Both halves are now automated.** `.#sync` allows every `.envrc` carrying its
own generated header - primary checkouts and the worktrees it adopts rather
than creates - never an `.envrc-workspace` sidecar and never a hand-written or
upstream-tracked file, which are judgements about someone else's content.
`doctor` gained an `envrc allowed` line that reports rather than fixes, so the
two do not race. Idempotent and silent in a steady state. Fixture: `T38`.

The fixture earned its keep immediately: it caught that `.#sync` adopts stray
worktrees and writes their `.envrc` without allowing it - a hole one directory
over from the one I set out to fix. `.#worktree` had been allowing its own
since it was written; that asymmetry is why 7 of 19 primary checkouts were
blocked but only 2 of 48 worktrees.

## 3. The weekly `flake.lock` bump has been stalled for 22 days

**Half applied. The lock is current; the loop is not fixed - that part needs
your call.**

The lock was brought forward by hand instead: nixpkgs `e5bdc4a` (2026-08-16) →
`ef34387` (2026-09-13), committed after the full gate plus spot-checks of every
shell the update moves (`.#api` still resolves pnpm 9.15.9, `.#apple` still
hands `xcrun` the real Xcode SDK, `.#sync` regenerated the launcher and its
four gc roots onto the new store paths - uv went 0.12.3 → 0.12.11 and the roots
followed, which is finding 8 working end to end through a real update).

That clears the 28 days of drift but not the cause.

`.github/workflows/update-flake-lock.yml` exists precisely because
"repeatability decays without a loop." The loop's last mile is broken:

- PR **#5** `chore: nix flake update (weekly)` has been **open since
  2026-08-24**. The schedule force-pushes it weekly (last: 2026-09-14).
- `gh pr view 5` → `statusCheckRollup: []`, `mergeStateStatus: UNKNOWN`. The
  `ci` run against it is `action_required`, duration **0s** - it never started.
- `flake.lock` on `main` is nixpkgs `1786862985` (**2026-08-17**); the PR branch
  carries `1789286504` (2026-09-14). **28 days of drift.**

The workflow's own comment predicts the cause - a PR opened with `GITHUB_TOKEN`
does not trigger other workflows - and answers it by validating *inside* the
scheduled run (that run is green, 2m30s). But nothing publishes that result to
the PR, so the PR permanently *looks* unverified and never gets merged. PRs #1
and #2 merged; #5 is where the habit lapsed.

`main` is not branch-protected, so the fix is cheap. **I could not apply it:**
editing the workflow to merge its own PR is refused here as "merge without
review", and that is the right call for a policy decision rather than a bug.
Pick one and I will wire it:

- **(a) Merge it directly from the workflow.** The validation already ran and
  passed two steps earlier; `peter-evans/create-pull-request` can be followed by
  `gh pr merge --squash`, or the job can push to `main` and skip the PR. Most
  deterministic for a single-maintainer repo. Note the same `GITHUB_TOKEN` rule
  means a push to `main` triggers no `ci` run either - the bump commit lands
  without a badge. That is acceptable precisely because the validation ran
  in-workflow; it is not acceptable as a silent gap, so say so in the commit.
- **(b) Publish a check run** so the PR shows green and stays a review gate.

Either way the lock stops ageing. Recommend (a): the validation that matters
already runs two steps earlier in the same job, and the PR is worth keeping
(rather than pushing straight to `main`) only for the readable, revertable
diff. Note the badge gap is the same either way - a `GITHUB_TOKEN` push to
`main` triggers no `ci` run either.

PR #5 needs no action: its branch lock is now byte-identical to `main`'s
(nixpkgs `ef34387`, verified with `git diff origin/update-flake-lock main --
flake.lock`), so the branch carries no delta and the next scheduled run has
nothing to push. It closes itself.

## 4. `just brief --short` - advertised every session, broken every session

**Applied.** The `SessionStart` orient hook injects into *every* session:

```
just brief --short a b c     one line per repo
```

`scripts/brief.sh` accepts `[--short] <repo>...`, but the recipe was
`brief repo:` - one required positional. So:

```
$ just brief --short android apple
error: justfile does not contain recipe `android`
```

Changed to `brief *ARGS:`. Verified working. The one-line-per-repo form is what
made section 5 of this audit cheap, and it had been unreachable via the spelling
the hook teaches.

## 5. `pnpm` floats, and it has broken `api` outright

**Applied.** `.#api` now pins pnpm 9.15.9 via the override below, and
`pnpm install` in that shell works (2.2s, lockfile untouched). `.#docs` and
`.#webflasher` stay on floating `pkgs.pnpm` - both verified to install cleanly
on 11, and pinning them would add a version to carry for nothing.

A second repo turned out to need the same pin for a different reason - see
finding 10's `meshtastic-site-planner` entry - so the derivation is shared.

The `CI=true` idea was dropped on reflection: pinning 9 removes the NO_TTY
abort outright, and the variable is read by biome and vitest too. Not worth
changing their behaviour to fix something that no longer happens.

Original analysis: The flake pins six JDKs across three Gradle mechanisms and pins
`nodejs_22`/`nodejs_24` explicitly, then uses bare `pkgs.pnpm` in `.#api`,
`.#docs` and `.#webflasher`. That attribute now resolves to **11.21.0** and
moves with every `nix flake update`. The `.#docs` comment concedes the
fragility - "nixpkgs' pnpm as of 2026-08-19 … verified with `pnpm --version`
in this shell" - and it has since drifted from 11.19.0 to 11.21.0.

| repo | lockfile | CI pins | shell ships | works? |
| --- | --- | --- | --- | --- |
| `api` | `lockfileVersion: '9.0'` | pnpm **9** | pnpm **11.21.0** | **no** |
| `web-flasher` | `lockfileVersion: '9.0'` | pnpm **9** | pnpm **11.21.0** | yes |
| `meshtastic` (docs) | `packageManager: pnpm@11.19.0` | - | pnpm **11.21.0** | yes |

Measured, each against a scratch copy of the repo's own `package.json` +
`pnpm-lock.yaml`, using CI's flags (`pnpm install --ignore-scripts`, `CI=true`):

- **`api` + pnpm 11.21.0** → fails. Four `@buf/meshtastic_api.*` entries have
  no `integrity` field, and pnpm 11 rejects the lockfile:
  `The lockfile contains entries that the active policies reject.`
- **`api` + pnpm 10.34.5** → same failure
  (`ERR_PNPM_MISSING_TARBALL_INTEGRITY`).
- **`api` + pnpm 9.15.9** → **succeeds in 12s, lockfile untouched.**
- **`web-flasher` + pnpm 11.21.0** → succeeds in 13s.

So this is not a general "pin pnpm 9 everywhere" problem: it is specific to the
`@buf` registry packages in `api`'s lockfile, which predate pnpm 10's stricter
integrity policy. `api` CI is green because it pins pnpm 9 - the shell is the
only place that is wrong.

`pkgs.pnpm_9` is **not** available: it evaluates to
`error: 'pnpm_9' was removed because it reached EOL on 2026-04-30`. An explicit
version override is, and it builds and works:

```nix
pnpm9 = pkgs.pnpm_10.overrideAttrs (o: rec {
  version = "9.15.9";
  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/pnpm/-/pnpm-${version}.tgz";
    hash = "sha256-z4anrXZEBjldQoam0J1zBxFyCsxtk+nc6ax6xNxKKKc=";
  };
});
```

**Recommendation:** use that in `.#api` only, with a comment saying it tracks
`api`'s CI pin and can go away when `api` regenerates its lockfile without the
integrity-less `@buf` entries (which is the real upstream fix, and worth an
`api` issue). Leave `.#webflasher` and `.#docs` on `pkgs.pnpm` - both work
today, and pinning them buys nothing but another version to carry. Not applied
here because it is a third change to `flake.nix` in one pass and deserves its
own `just check`.

Two side-findings from the same tests, both unapplied:

- **pnpm 11 is agent-hostile without `CI=true`.** The first `api` attempt died
  on `[ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY] Aborted removal of modules
  directory due to no TTY` - pnpm wants to purge a `node_modules` written by a
  different major and refuses to do it unattended. Every agent tool call is
  non-TTY. Exporting `CI=true` in the pnpm shells would remove a whole class of
  confusing failure.
- **The node pin does not cover pnpm.** In `.#api`:

  ```
  shell node:   v22.23.2
  pnpm shebang: #!/nix/store/…-nodejs-slim-24.19.0/bin/node
  ```

  `api/package.json` declares `"node": "22.x"`, so every pnpm-run script
  executes on a node the shell did not pin and the repo does not claim to
  support - pnpm says so itself (`WARN Unsupported engine: wanted {"node":
  "22.x"} (current v24.19.0)`). `pkgs.pnpm.override { nodejs = pkgs.nodejs_22; }`
  closes it. Same question applies to `.#webflasher`.

## 6. Leads that dissolved - do not re-investigate

Recorded because each looked alarming in the transcript digest and each is fine.

- **74 sessions under `-private-var-folders-…-T`.** Not stray work in a temp
  cwd. Every one is 26 lines and opens `You are a conversation title
  generator` - Claude Code's own title-generation sessions. No workspace
  relevance.
- **~90 sessions under `-Users-james-StudioProjects-Meshtastic-Android-*`.**
  A second clone outside the workspace would be a real problem. It does not
  exist: `~/StudioProjects/Meshtastic-Android` is gone (migrated into
  `nixtastic/android`), and the newest real timestamp in those transcripts is
  **2026-08-13**. Recent file mtimes misled the first pass; transcript
  timestamps are the truth.
- **"nixpkgs 26.11 dropped Intel macOS support outright (it throws on eval)"**
  - the `systems` comment in `flake.nix`. Verified accurate: 26.11 drops
  `x86_64-darwin` following Apple's Intel deprecation, errors on eval, and
  points users at 26.05.
- **`nix fmt` not gated.** It is, twice: `checks.<system>.formatter` (so
  `just check` covers it) and a separate `format` CI job that runs `nix fmt`
  then `git diff --exit-code`.
- **19 repos, 19 branches.** `nix run .#brief -- --short` over every row of the
  `CLAUDE.md` table matches the declared branch exactly. `protobufs` PR #1027
  (Develocity) is still open, so that claim holds too.

## 7. The memory index: a renderer bug and an over-budget line

**Applied - two separate problems, and only fixing one would have left the
warning standing.** `nix run .#doctor` warned `MEMORY.md 22766 bytes, 1 entries
over 200 chars`.

**(a) The tag was rendered twice.**

```
- [uConsole BLE is legacy-only](…) - [darwin] [darwin] The uConsole CM5 BLE …
- [firmware native tests on Linux](…) - [james-pc] [james-pc] firmware native …
```

`scripts/memory.sh` prepends `[$machine] ` unconditionally, and these two
memories also carry the tag inside their own `description:`. Fixed at the
renderer so it cannot recur, whatever a description contains:

```awk
tag = (mach != "" && index(desc, "[" mach "] ") != 1) ? "[" mach "] " : ""
```

with a `T19` fixture (`tagged-desc`) asserting the tag is not rendered twice.
`checks.aarch64-darwin.tools-tests` passes.

**(b) That was not why the line was over budget.** The uConsole line was 268
chars; removing the duplicate tag brings it to 259, still over the 200 the
`memory-index-line-budget` rule sets. The description itself was too long.
Shortened it (and dropped the now-redundant literal tag from the other), then
re-ran `.#sync`:

```
ok    memory index       22680 bytes, 167 entries, none over 200 chars
all clear (0 warning(s))
```

## 8. The MCP launcher's store paths are rooted only by accident

**Applied.** `.#sync` now registers an indirect gc root per store path the
launcher names, under `.cache/mcp-gcroot/`, using the *ambient* `nix-store` so
the root reaches this machine's daemon rather than a client pinned in
`runtimeInputs`. `doctor` compares the roots against what the launcher
currently names, so a flake update that moves both without a `sync` is visible
rather than a bomb waiting for the next gc. Proven through the real update in
finding 3. Fixture: `T39`, including the negative case.

Original analysis: `bin/meshtastic-mcp-launch` is
generated by `.#sync` and hard-codes raw store paths:

```
export UV_PYTHON="/nix/store/…-python3-3.13.15/bin/python3"
export LD_LIBRARY_PATH="/nix/store/…-clang-21.1.8-lib/lib:/nix/store/…-zlib-1.3.2/lib"
exec "/nix/store/…-uv-0.12.3/bin/uv" run --directory …
```

`nix-store --query --roots` says those paths *are* alive - but every root is a
nix-direnv profile belonging to some other directory:

```
/Users/james/nixtastic/meshtastic-mcp/.direnv/flake-profile-8a1d86e4…
/Users/james/nixtastic/meshtastic-python/.direnv/flake-profile-8a1d86e4…
```

Nothing roots them on the launcher's behalf. Deleting `meshtastic-mcp/.direnv`,
running `direnv prune`, or regenerating that `.envrc` drops the root, and the
next `nix store gc` takes `uv` with it - after which the *stable* path the whole
design is built around fails with a store path that no longer exists. That is
the classic Nix anti-pattern: a generated script referencing the store with no
GC root of its own.

**Fix:** have `.#sync` write a real root next to the launcher -
`nix build --out-link .cache/mcp-launcher-root <expr>` - and point
`UV_PYTHON`/`uv` at the symlink. One `sync` change plus a fixture.

## 9. `.DS_Store` escapes the deny-by-default

**Applied.** `.gitignore` opens with `/*` and the comment "a new file is
untracked until whitelisted." True at the root, false below it: `!/plugin/`,
`!/notes/` and `!/scripts/` re-include *everything* under those directories,
`.DS_Store` included - which is why `git status` opened this session with
`?? plugin/.DS_Store`. Added an explicit `.DS_Store` deny above the
whitelist block, where no later negation undoes it.

## 10. Smaller items

- **`meshtastic-site-planner` is cloned but unknown to the workspace** -
  **adopted.** It is a real org repo (`meshtastic/meshtastic-site-planner`,
  site.meshtastic.org): Vite + Vue 3 + TypeScript + vitest, with SPLAT!'s ITM
  propagation model compiled to WebAssembly and run in a Web Worker pool. It
  had sat at the workspace root undeclared since 2026-09, so `brief` answered
  `unknown repo`, `sync` never gave it a `.envrc`, and `doctor`'s "19 cloned,
  each with a shell" did not count it. Not a bystander either - the flat
  coverage-query contract it grew in its #74 is the hand-off to the apps.
  Now a table row plus a `.#siteplanner` shell (Node 24, matching its CI).
  It needs pnpm 9 for its own reason, unrelated to `api`'s: **pnpm 11 stopped
  reading the `pnpm.overrides` block from `package.json`** (it moved to
  `pnpm-workspace.yaml`), so an install against the committed lockfile dies on
  `ERR_PNPM_LOCKFILE_CONFIG_MISMATCH`. pnpm 9.15.9 installs in 3s, lockfile
  untouched. `doctor` now reports 20 repos.
- **The `.#design` banner named `meshtastic_design_standards_latest.md` as
  "the authoritative spec"** - **reworded.** `CLAUDE.md` says to link the
  standards *by directory*, "never a version file and never `..._latest.md`",
  which GitHub serves as 35 bytes over HTTP. The banner now names the
  directory and keeps `_latest.md` only where it is true, for a local read.
- **`doctor` should report reapable worktrees** - **deliberately not added.**
  Both cheap local signals lie. HEAD-is-an-ancestor-of-the-default-branch
  finds **0 of the 14** `--gc` reports, because they were all squash-merged.
  Branch-gone-from-origin finds 0 too, because the remote-tracking refs are
  stale without a `--prune` fetch. A green line that means nothing is worse
  than no line, so `--gc` stays the only thing that answers this - it queries
  PRs, which is why it is correct and why `doctor` cannot cheaply copy it.
  Run `nix run .#worktree -- --gc --apply` periodically; 14 are reapable now.
- **`python3` 3.14.7 leaks into every non-Python shell** (`.#api`, `.#docs`,
  `.#design`, `.#protobufs`, `.#webflasher`), while `.#python` correctly pins
  3.13.15. Memory `apple-build-docs-python314-color` already records 3.14
  corrupting `apple`'s `build-docs.sh`. Left alone: nothing in those shells is
  supposed to call `python3`, and removing it means tracking down which
  package pulls it in. Worth a look if something starts blaming Python.
- **`web-flasher` CI runs node 18 and 20; `.#webflasher` ships node 22.** Left
  alone - the shell is the looser environment, so a break lands in CI rather
  than locally, which is backwards but not urgent. Fixing it properly means
  deciding whether the repo should move up rather than the shell down.
- **The Gradle queue guard false-positives on quoted strings.** It strips
  heredoc bodies already, but a command containing the literal `./gradlew ` in
  a quoted argument (a `grep` for it, an `echo`) is denied. Hit once here.
  Left alone deliberately: the 42 blocks in the transcript window were
  *genuine* unqueued invocations by agents in `android` worktrees, which is a
  teaching problem, not a matching one. The rule is taught only by the deny
  message, so every fresh agent pays one round-trip to learn it - that belongs
  in `android`'s orient output, and is a different change from tightening the
  regex.

## 11. Research: is the workspace shaped wrong for Nix?

Short answer: no, and I would not take any of the common "upgrades."

The current shape - one root flake, `devShells` per toolchain, per-repo
generated `.envrc` using `nix-direnv`, tool scripts as real files in
`scripts/` assembled by `writeShellApplication`, `mkShellNoCC` where no
compiler is needed, `--all-systems --no-build` eval plus a built `flake check`
in CI - is exactly what current guidance describes as the mature 2026 pattern
for a polyglot multi-repo workspace: a central flake with multiple dev shells
so subprojects share one store, and nix-direnv caching the profile so entering
a shell is milliseconds rather than an evaluation.

Considered and declined:

- **`devenv` / `flake-parts` / `numtide/devshell`.** These buy module-system
  ergonomics for a flake that has outgrown a single file. At 1459 lines with
  heavy load-bearing comments, `flake.nix` has not. Adopting one adds an input
  to keep current and moves every shell definition into a DSL, in exchange for
  structure the file already gets from plain attrsets. The comments *are* the
  documentation here; a rewrite would cost more than it returns.
- **`androidenv.composeAndroidPackages`.** The declarative way to get an
  Android SDK. This workspace deliberately uses a real
  `~/Library/Android/sdk` reconciled by `.#bootstrap-sdk` against
  `android-sdk-packages.txt`, because Android Studio and `adb` need a writable,
  licence-accepted SDK that `androidenv`'s read-only store copy is poor at.
  Correct call; leave it.
- **Pinning `nixpkgs` to a release branch instead of `nixos-unstable`.**
  Tempting for determinism, but the lock is what provides determinism - the
  branch only sets how fast the lock *could* move. The real problem is
  finding 3 (the lock is not moving at all), not the branch choice.
- **`cachix` / a binary cache.** CI is pure evaluation plus a handful of
  `writeShellApplication` derivations and finishes in ~2 minutes. Nothing to
  cache.

The two genuine Nix-practice gaps this audit found are finding 8 (a generated
script holding store paths with no GC root) and finding 5 (one tool left
floating in a flake that pins everything else) - both narrow, both fixable
without changing the workspace's shape.

---

## Still open

One decision, then two long-tail items.

1. **Yours: may the weekly workflow merge its own lock PR?** (finding 3). The
   edit is four lines - `id: cpr` on the create-pull-request step, then
   `gh pr merge ${{ steps.cpr.outputs.pull-request-number }} --squash
   --delete-branch` gated on that output. Refused here as "merge without
   review", correctly - it is a policy choice. Until it lands the lock ages
   again. PR #5 itself needs nothing: its lock now matches `main` exactly.
2. **File the `@buf` lockfile entries upstream in `api`** - four
   `@buf/meshtastic_*` entries with no `integrity` field. That is the real fix;
   the pnpm 9 pin in `.#api` exists only to work around it and should be
   removed when `api`'s lockfile is regenerated.
3. **Reap the 14 merged worktrees**: `nix run .#worktree -- --gc --apply`.
   Left undone because removing checkouts is not mine to do unasked.

## What changed on disk

Nine commits on `main`, unpushed. Gate green on the updated lock
(`nix flake check --all-systems --no-build`, built `nix flake check` including
`tools-tests`), `nix run .#doctor` at 0 warnings, 20 repos.

| commit | change |
| --- | --- |
| `fix(apple)` | shellHook strips the Xcode-breaking vars (1) |
| `fix(brief)` | `brief *ARGS:` so `--short` and multiple repos work (4) |
| `fix(memory)` | machine tag rendered once, `T19` fixture (7a) |
| `chore(gitignore)` | explicit `.DS_Store` deny (9) |
| `notes(workspace)` | this note |
| `fix(sync)` | direnv trust for generated `.envrc`, `doctor` line, `T38` (2) |
| `feat(sync)` | gc roots for the launcher's store paths, `doctor` line, `T39` (8) |
| `fix(api)` | pnpm 9.15.9 pin (5) |
| `feat(siteplanner)` | adopt `meshtastic-site-planner`, `.#siteplanner` shell (10) |
| `docs` | Xcode rule, `.#design` banner, repo table row (1, 10) |
| `chore` | `nix flake update` - nixpkgs 2026-08-16 → 2026-09-13 (3) |

Outside the repo: three memories reworded so they no longer prescribe the
`env -u` incantation for `.#apple` (`james-pc-nix-gotchas`,
`kmp-build-gotchas`, `ble-mesh-interop-bench`), and two memory descriptions
shortened for the index budget (7b). `notes/ack-authenticity-audit.md` is a
concurrent session's work and was deliberately left untracked.
