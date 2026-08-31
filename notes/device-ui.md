# device-ui — meshtastic/device-ui

Workspace-local note. This repo has **no agent docs of any kind** — no
`AGENTS.md`, no `CLAUDE.md`, no `CONTRIBUTING.md` — orientation comes from
the code and from here.

- **Role:** MUI, the LVGL touch UI for color devices (T-Deck, mesh-tab,
  portduino native-tft). A *library*, not an app: `firmware` consumes it as
  a **commit-pinned zip** in `platformio.ini` (`meshtastic/device-ui` digest,
  bumped by Renovate). Local development against firmware needs a
  `lib_deps` override (e.g. `symlink://`) in the consuming env.
- **Default branch:** `master` · commits are sentence-style, no prefixes.
- **Shell:** `.#firmware` (same PlatformIO toolchain family).

## Architecture facts (verified 2026-08-31)

- MUI runs **in-process as a phone-API client**: firmware side is
  `PacketAPI : PhoneAPI` (`STATE_PACKET`), fed through `PacketServer`
  queues. It is selected **at runtime** by
  `config.display.displaymode == COLOR` on `HAS_TFT` builds (`t-deck-tft`);
  `DEFAULT` boots classic BaseUI on the same binary.
- **Embedded coexistence:** a USB-serial phone-API client works while MUI
  runs (verified live on T-Deck). **BLE does not**: `PacketAPI::runOnce`
  starves MUI into `programmingMode` whenever `config.bluetooth.enabled`
  is set — the flag, not an active connection. **Portduino has no gate**
  (TCP client + MUI always coexist).
- `USE_PACKET_API` is `#error`-incompatible with
  `MESHTASTIC_PHONEAPI_ACCESS_CONTROL` (lockdown builds).
- Rendering: LVGL (see `lv_conf.h`), RGB565, `LV_USE_SNAPSHOT` disabled.
  Portduino display drivers: X11 / FB / SDL (`DisplayDriverConfig`).

## Cross-repo

- Screen-mirroring work (design#142, firmware#11681): the MUI dirty-rect
  streaming spike taps the LVGL flush callback here; `DisplayFrame`'s
  `rect_*` fields + `Format.RGB565` in protobufs are reserved for it.
