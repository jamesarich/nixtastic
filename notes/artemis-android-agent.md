# artemis - google/artemis as an Android exploration tool

Not a Meshtastic repo. Clone lives **outside** the workspace at
`~/src/artemis`, tracks upstream `main`, no pin. Registered as a **user-scope**
MCP server named `artemis` (`claude mcp remove artemis --scope user` to undo).

Google Pixel-Test-Engineering's autonomous Android agent. Natural language in,
adb actions out, via a multimodal model reading the screen each step. Apache-2.0,
Python/uv. 99%+ on AndroidWorld.

## What it is for here

**Exploration and triage, not scripted assertions.** Reach for it when you do
not already know where a control lives, or when a flow is long enough that a
screenshot per step would bloat the session context. For flows we already know,
the deep links in `driving-android-emulator` memory and the `android_*` MCP
tools are faster, free and deterministic.

It does **not** replace the `android_*` tools in `meshtastic-mcp`. Two reasons,
both checked in the source 2026-09-10:

- **The IDE MCP server exposes no primitives at all.** `python -m mcp_server`
  mounts exactly five tools (`mcp_server/tools/__init__.py`): `mobile_run_task`,
  `mobile_manage_task`, `mobile_inspect_trace`, `mobile_get_device_state`,
  `mobile_diagnose`. It is a delegation interface, not a tap/dump surface. The
  13 low-level adb tools in `artemis/mcp/adb_server.py` are a separate internal
  server the agent talks to itself, and its `tap` is coordinates-only
  (`adb_server.py:188`) either way. So there is **zero overlap** with the
  `android_*` primitives - nothing to replace.
- **No logcat over MCP.** The README claims it collects Logcat; `mcp_server/tools/diagnose.py`
  has none. logcat exists only in `artemis/tools/mobile/log_utils.py`, internal
  to the agent loop. `android_read_logcat` has no counterpart.

Routing an e2e assertion through a vision model to find a button is flaky by
construction. Keep assertions on the deterministic path.

## Running it

**There is no TUI.** The only terminal-UI dependency is `rich` and the README
never claims one; what reads like a TUI is rich-styled output and spinners
during `run` and the frontend build. The real front end is the web UI below.

Key goes in `~/src/artemis/.env` as `GEMINI_API_KEY` (aistudio.google.com/apikey,
free tier covers casual runs). `get_env_file()` resolves that path off the
checkout, not the cwd, so the MCP server finds it wherever Claude Code spawns
it. **The file currently has an empty key** - every `mobile_run_task` fails
until it is filled in. Default model is Gemini; **no Anthropic key needed**,
and there is no Claude-subscription path - `langchain-anthropic` wants a raw
`ANTHROPIC_API_KEY` and bills separately.

```
cd ~/src/artemis
uv run artemis doctor
uv run artemis run "<goal>" --profile flash --locked-app com.geeksville.mesh.fdroid.debug
```

`--locked-app` keeps it inside the package. Use it on the Pixel 6a - that phone
is a bench device, but it is still a real phone.

**The web UI** is `uv run artemis ui`, an Angular "Showcase UI" plus admin
console on `127.0.0.1:8000`. It opens a browser by default, so pass
`--no-open` when driving it from an agent. Ctrl-C in its pane or `uv run
artemis stop` ends it. Three views: **New / Home** launches a task (prompt box,
Flash/Pro toggle, canned demos); **System Setup & Prerequisites** is a live
readiness panel covering python, adb, config, scrcpy, the Gemini key with a
Test Key button, and the attached devices; **Workspace** streams a running
task's log payloads beside the queue and history. The setup panel is the
quickest read on key/device/scrcpy state, faster than `uv run artemis doctor`.

Its device selector lists **every** attached adb device (both the Pixel 6a and
the Pixel 9 Pro showed up here), and it is what picks the target. Keep it on
the 6a per the rule above. An empty `GEMINI_API_KEY` surfaces as an empty key
field, not an error, and a locked phone surfaces as a "Device Is Locked"
banner - both block a run without failing loudly.

**First `ui` launch in a source checkout always builds the frontend.**
`ensure_showcase_built()` skips npm only when `apps/showcase_ui/` is absent,
which means an installed wheel, whose dist is baked at packaging time. In a
clone it runs `npm install` then `ng build` whenever
`apps/showcase_ui/dist/**/index.html` is missing or older than anything under
`src/`, so a pull that touches the frontend makes the next `ui` slow (11s cold
here, but it is npm - do not bank on it). If npm is not on PATH it returns
silently and serves whatever stale `dist/` is there, with no warning.

## Gotchas

- **`./start.sh` writes global MCP config and a `rules.md` into every AI IDE it
  detects.** Never run it. `uv run artemis mcp --generate-config claude` prints
  the snippet instead, which is how the entry above was made.
- **`scrcpy` is per-machine.** Still missing on **james-pc**, where traces
  compile with 0 images and 0 steps and there is no video replay. Everything
  else works. Installed on the **Mac** 2026-09-10 (`brew install scrcpy`,
  scrcpy 4.1; ffmpeg 9.0.1 was already there), which clears the setup panel's
  Video Toolchain card.
- **uiautomator2 installs an ATX agent APK on the device.** Our `uiautomator dump`
  path leaves nothing behind. Worth knowing before pointing it at a phone you
  care about.
- Ignore `DEFAULT_MODEL = "gemini-2.5-flash"` in `artemis/config/constants.py`.
  An actual run picked `gemini-3.8-flash` for the operator and
  `gemini-3.5-flash-lite` for the visual step summarizer.

- **`ARTEMIS_DAEMON_PORT` is in use on james-pc**, so runs fall back to
  standalone mode without the shared scheduler. Single runs are fine;
  binding concurrent runs to different serials is not, until a free port
  goes in the MCP `env` block.
- **A newly registered MCP server is not visible to the session that
  registered it.** `mcp__artemis__*` shows up next session.

## Its verification is structurally fail-open. Never gate on it.

Checked in `artemis/agents/checker/checker.py` 2026-09-10. This is the most
important thing on this page.

- `verdicts_allow_release()` (line 110) filters to `kind == "verify"` and treats
  **`inconclusive` as releasing**. Its own docstring, line 114: *"Assert failures
  never block release."* The `assert` / `verify` distinction does not give test
  semantics.
- Line 433: a failed verdict with vague evidence is **downgraded to
  inconclusive**, which then releases.
- Lines 442 and 457: a check item that never got a verdict defaults to
  **inconclusive**, which then releases.
- `verification_level: "strict"` is *"checkpoints with a larger repair budget"* -
  that is **more** improvisation before halting, not less.

So a run reports success when the Checker could not observe the thing it was
meant to check. That is the `android-tests-that-lie` pattern with a Google
wordmark on it. Treat `report_task_status` and every Checker verdict as a
**hint**, never as a PASS.

`kind` is also assigned by the Checker LLM from the Planner's plan items. There
is no caller-side API to declare "this step is a hard assertion" - only prose in
`task_desc`.

## Replacing the e2e app plane

`meshtastic-e2e`'s `references/journeys.md` calls the app plane "the brittle
part" and prescribes natural-language `<action>` steps executed by an agent
against the live accessibility tree. There is **no runner** for that - not in
the `android` CLI (no `journey` subcommand) and not in `meshtastic-mcp`. The
runner is Claude, inline, spending main-context tokens on every `android layout`
dump, and unmeasured.

Artemis is that runner, purpose-built and measured. A journey `<action>` list
maps near 1:1 onto `task_desc`. This is worth doing, with one hard rule:

**Artemis drives. The recorder decides.** Never let the agent's self-report be
the oracle - see the fail-open section above. The skill already mandates this
("the device plane stays the deterministic oracle"), so the swap does not
weaken it as long as nobody starts trusting `output.md`.

Journey fit:
- `outbound.journey.xml` - **clean.** All app steps, then the recorder asserts
  wire truth independently. This is the one to gate the whole idea on, because
  the recorder can check Artemis's self-report.
- `inbound` and `node-sync` - the device plane must fire **first**, and
  `mobile_run_task` is one-shot and cannot wait on your signal. Either send
  before starting the run, or make the last action a `wait_for_text(TOKEN)`
  with the hop-count deadline from harness rule 2. Workable, but you own the
  interleave race.
- `references/replay-app-features.md` is pure device plane, zero app driving.
  Unaffected.

Apple keeps Claude inline over `apple_sim.*`. One journey format, two runners.
That asymmetry is the price.

**Open question for James, not settled here:** `journeys.md` is titled "the
self-healing app plane" but rules "if an element isn't present, the journey
fails - do not improvise around it". Artemis resolves that toward self-healing.
For interop testing that is arguably right - a redesigned Messages tab should
not fail an inbound-message test - but a journey then stops detecting UI
regressions.

## Gate run, 2026-09-10 - what is actually proven

Pixel 6a (wireless adb), `meshtastic-mcp replay` as the device plane on
`127.0.0.1:4403`, `adb reverse`. Shipped as
`meshtastic-mcp` PR #80 (`feat/e2e-artemis-app-plane`).

**Proven:**
- Artemis found the Connection screen, the Network tab and the "+ Add device
  manually" dialog **unaided** - no coordinates, no resource IDs - typed the
  address and confirmed connected. The replay engine independently logged a
  real client and 102 packets. That is the hard step of the journey, done
  cold.
- A second run composed and sent a token; a separate `uiautomator dump`
  confirmed it on the LongFast channel, independent of Artemis's self-report.
- Given a malformed task (an empty token, my bug) it **correctly failed** the
  assert instead of fabricating a pass. One honest data point; the structural
  fail-open finding above still stands.

**Not proven:**
- Outbound **wire truth**. The `meshtastic-mcp replay` CLI does not log
  app-to-device packets, so the send half is confirmed at the app-render layer
  only. A real radio + recorder, or ToRadio logging in the replay CLI, would
  close it.
- Anything about `inbound` / `node-sync`, whose interleave was never exercised.

**Cost, same phone and app, same steps:**

| Profile | LLM calls | Prompt tokens | Wall clock |
|---|---|---|---|
| Flash | 3 | 24,032 | ~15 s |
| Pro | 97 | 1,669,659 (56% cached) | ~13 min |

~70x. Use Flash for journeys. Pro only when you need its device probes or
`expected_output_desc`.

## Measured, 2026-09-10

One task on the Pixel 6a: "open Meshtastic, go to Nodes, report the first node's
name and battery". Cold start to correct answer in **2 turns, one tap, ~15s, 3 LLM
calls, 24k prompt tokens**. Verified against a raw `uiautomator dump`. It was given
no resource IDs and no coordinates and still found the bottom-nav Nodes icon.

One task is not a benchmark. That was the most discoverable target in the app.
