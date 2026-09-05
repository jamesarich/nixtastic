# The bench - shared hardware, and what it does silently

Workspace-owned. The radios on `james-pc`'s USB are **global mutable state**:
one bus, one `firmware/.pio` tree, one set of `/dev/tty*` nodes, shared by
every concurrent agent session regardless of which repo or worktree it thinks
it is standing in. Everything here was learned by losing a build, flashing the
wrong board, or chasing a bug that only existed because a USB cable was
plugged in.

Roster and per-board history: [`node-inventory.md`](./node-inventory.md)
(evidence window 2026-07-02 → 2026-08-26). Live state is the tools'
job - `mcp__meshtastic__list_devices`, `uhubctl`, `/dev/serial/by-id/`.

---

## Every session points at the same firmware checkout

`scripts/lib.sh` writes `MESHTASTIC_FIRMWARE_ROOT="$root/firmware"` into
**both** MCP entry points - the generated `.mcp.json` (`write_mcp_json`) and
the user-scope launcher `bin/meshtastic-mcp-launch` (`write_mcp_launcher`).
Neither is worktree-relative, on purpose: the MCP flash/build tools must reach
a real firmware tree from any cwd on the machine.

The consequence is not documented anywhere the tools print it: **a session
working in `android/.claude/worktrees/whatever` still builds and flashes out of
the primary `firmware/` checkout.** So do concurrent sessions. So does the
`meshtastic-mcp` test suite when a mocked upload leaks.

Two failures seen live on 2026-08-26 during 2.8.0 soak prep:

1. **Another session's build cleans your artifacts.** PlatformIO rewrites
   `project.checksum` and wipes every `.pio/build/*` dir when the env changes.
   A finished 8-minute `seeed-xiao-s3` build vanished between `build_poll`
   returning `status: done` with artifact paths and the next `ls`.
2. **A leaked upload flashes a real board.** A `pytest tests/unit` run inside
   `meshtastic-mcp/.claude/worktrees/fix-flash-upload-port-pinning/` shelled
   out to a genuine `pio run -e meshnology_w10 -t upload --upload-port
   /dev/cu.usbmodem1201` - a macOS path, invalid here - and orphaned it to
   `systemd --user`. An **invalid** `--upload-port` is the guaranteed trigger
   for PlatformIO's auto-detect fallback, so a leaked upload is most dangerous
   exactly when its target does not exist. meshtastic-mcp's own notes record a
   2026-08-25 incident where a 16 MB `meshnology_w10` image boot-looped an 8 MB
   Heltec Wireless Tracker V2.

Before a multi-device flash session: `pgrep -af 'pio run'`, and `ListAgents` if
the harness offers it. If `build_poll` says done, flash **immediately** - do not
assume the artifacts survive the next poll. A stray `pio run -t upload` while
boards are attached is a live threat to hardware, not wasted CPU.

## The port number is not the device; the USB serial is

`/dev/ttyACM*` numbering is assignment order, and it changes on every replug,
power cycle and lockup recovery. Two RAK4631s were on the bus simultaneously on
2026-08-22, separable **only** by USB serial (`7885014CB2C5B186`, the solar
node, vs `E6947CB9383DC08D`, the OTAFIX bench unit). Resolve through
`/dev/serial/by-id/` every time; never carry a port number across a reboot,
a `uhubctl` cycle, or a session boundary.

Two ways the bus loses a node that look like a dead board and are not:

- **Chrome holds it.** A WebSerial grant in an open tab (web-flasher) keeps
  `cdc_acm` bound; the node disappears from other tools while the tab lives.
- **Bootloader vs app enumerate under different names.** The T1000-E appears as
  `Seeed_Studio_T1000-E-BOOT_*` in DFU and under its app identity otherwise, so
  a `by-id` match that "vanished" may just have changed strings.

## Recovering a wedged board

`uhubctl -l <hub> -p <port> -a cycle` (2.6.0 at `/usr/sbin/uhubctl`). Bare
`uhubctl` lists every port with VID:PID and serial. Do this rather than asking
for hands - but know the three outcomes, all confirmed on the same board on
2026-08-26:

| State | Cycle helps? |
| --- | --- |
| Wedged, still enumerated (present in `by-id`, app not answering) | **Yes** - verified, even on a battery-powered T-Deck |
| Fallen off the bus (port reads `power` with no `connect`, or `error -71`) | No - bus power is already irrelevant; needs the board's own switch |
| Not on a hub (root port, e.g. `usb3/3-1`) | No - `uhubctl` cannot reach it. Check `udevadm info -q path -n <port>` first |

An esptool `--after hard-reset` is not a substitute: a deeply wedged ESP32-S3
fails it with "No serial data received" because the ROM is unreachable too.

**Derive the port from the device, never the reverse.**
[`tdeck-watchdog.sh`](./tdeck-watchdog.sh) exists because its first version cut
power to a hub port carrying four unrelated boards. It now reads the wedged
board's USB address out of sysfs, re-reads the serial at that exact address,
and cycles nothing unless it matches - no address, no match, or a hub at that
address means it asks for hands instead.

## nRF52: enter DFU yourself, and test OTA on battery

- `meshtastic --port /dev/ttyACMx --enter-dfu` puts a running node into the UF2
  bootloader. The 1200-baud touch is ignored by 2.8 dev builds. Only ask for a
  physical double-tap when the app is already dead.
- **Unplug the RAK's USB before testing BLE OTA.** On 2026-08-21 an entire
  session of "app-jump wedge", `sd_ble_gap_addr_get` faults and deterministic
  mid-stream drops (351360 / 729528) were USB-connected artifacts: the same
  bootloader and stock app that faulted over USB completed a clean OTA on
  battery. Keep the phone on USB for adb; the radio must be on battery. Treat
  any BLE-OTA failure observed with the radio on USB as unreproduced.

## Known-bad hardware/firmware pairings

- **T-Deck on 2.8.0 MUI locks up every 3–7 minutes** and drops off USB
  enumeration with it. Both units, repeatedly, on `2.8.0.8eda860`
  ([`tdeck-lockups.log`](./tdeck-lockups.log), 2026-08-26). Not yet filed
  upstream - a soak that includes a T-Deck needs auto-recovery armed or it
  will spend the night off the bus.
- **`hw_model` variants hide behind their base board.** A RAK WisMesh Pocket
  reports as plain `rak4631`; the web flasher shares one entry across
  variants, so the flasher's board list is not a reliable identity source.
- **Config order matters.** Set explicit fields *before* applying a channel
  URL - the URL triggers a reboot that interrupts a trailing field write.

## Where the fleet tooling lives

Canonical, in `meshtastic-mcp`:

- `scripts/fleetsuite.sh` (+ `fleetsuite-supervisor.sh`, launchd plists) - on
  `master`. Continuous capture across the attached fleet.
- `src/meshtastic_mcp/cli/mtop.py` + the `soak_status` tool - on
  **`feat/mtop-soak-dashboard`**, 10 commits, unmerged and with no PR as of
  2026-08-27. The btop-style bench dashboard reads FleetSuite's capture.

Superseded prototypes, kept only until that branch lands:
`notes/mtop.py`, `notes/mtop`, `notes/soak-dashboard.py`, `notes/soak-start`,
`notes/soak-nodemap.json`. Do not extend these - extend the branch.
