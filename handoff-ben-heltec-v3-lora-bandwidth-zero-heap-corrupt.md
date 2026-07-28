# Bug: `bandwidth=0` in a custom (non-preset) LoRa config triggers `numFreqSlots`/`Slot time` unsigned-overflow, `SX126x init result -8`, and a `CORRUPT HEAP` report — firmware `2.8.0.510e979`

**Reporter:** James · **Date:** 2026-07-09
**Handoff to:** @thebentern
**Found while:** bench-testing Meshtastic-Android PR [#6170](https://github.com/meshtastic/Meshtastic-Android/pull/6170) (channel-import atomicity) — **unrelated to that PR**. The trigger is any admin `set_config(lora=...)` / channel-URL import that carries a custom LoRa config with `use_preset=false` and `bandwidth` left at its protobuf zero-value. The PR's transaction mechanism just happened to be the vehicle that got a malformed config to the radio in my test; the bug is in how firmware validates/applies LoRa config, independent of the transport.

## TL;DR

Firmware clamps `coding_rate` and `spread_factor` to safe defaults when they're `0` (proto default / unset), logging an explicit `WARN Invalid ... setting to ...` for each. It does **not** do the same for `bandwidth`. A LoRa config with `use_preset=false` and `bandwidth=0` sails through validation, then feeds a frequency-slot calculation that divides/derives by bandwidth, producing `numFreqSlots: 4294967295` and `Slot time: 4294967295 msec` — the exact bit pattern of `UINT32_MAX` (`0xFFFFFFFF`), the textbook signature of an unsigned integer divide-by-zero (or an equivalent all-ones saturation) that silently wrapped instead of trapping. RadioLib's `SX126x` `begin()`/`setBandwidth()` correctly rejects `0` (`SX126x init result -8`, i.e. `RADIOLIB_ERR_INVALID_BANDWIDTH`), but firmware doesn't check that return value — it logs it and keeps going, ending in a still-broken radio (`Bandwidth set to 0.000000`, `Power output set to 22`) instead of aborting or falling back to a safe default. A `CORRUPT HEAP: Bad head` report from the ESP-IDF heap allocator fired in the same window, which is the part I'd flag as most serious — this smells like the bogus `numFreqSlots` value feeding into an array size/index somewhere downstream, not just a display glitch.

## Environment

| | |
|---|---|
| Firmware | `2.8.0.510e979` |
| Board / env | Heltec V3 (`HELTEC_V3`, ESP32-S3), radio `SX126xInterface(cs=8, irq=14, rst=12, busy=13)` |
| Node | `0x483ba531` |
| Transport | BLE (NimBLE), admin session over an `AdminMessage` `begin_edit_settings`/`commit_edit_settings` transaction |
| Client | Meshtastic-Android, `com.geeksville.mesh.fdroid.debug`, PR #6170 branch — but see TL;DR, the client/PR is not the root cause |
| Reproduced | Once, live, on this unit. **Not yet confirmed on other boards/chips** (nRF52/LR11xx/etc.) or on a from-scratch `set_config` call outside the transaction path — see "What I haven't verified" below. |

## Repro

I hit this via a channel-URL import (`https://meshtastic.org/e/#...`, the same format a real QR code produces), but the underlying trigger is just: **send an admin `set_config` with `lora.use_preset=false` and `lora.bandwidth` unset/`0`.**

### Minimal reproducer (no Android app needed)

```python
import base64
from meshtastic.protobuf import apponly_pb2, config_pb2

cs = apponly_pb2.ChannelSet()
p = cs.settings.add()
p.name = "E2ETest6170"
p.psk = bytes(range(1, 33))
p.channel_num = 0
s = cs.settings.add()
s.name = "E2ESecond"
s.psk = bytes([0xAA]) * 16
s.channel_num = 0

# use_preset left unset -> false. bandwidth/spread_factor/coding_rate left unset -> 0.
cs.lora_config.region = config_pb2.Config.LoRaConfig.RegionCode.US
cs.lora_config.modem_preset = config_pb2.Config.LoRaConfig.ModemPreset.LONG_FAST
cs.lora_config.hop_limit = 5
cs.lora_config.tx_enabled = True

raw = cs.SerializeToString()
b64 = base64.urlsafe_b64encode(raw).decode("ascii").replace("=", "")
print(f"https://meshtastic.org/e/#{b64}")
# -> https://meshtastic.org/e/#Ci8SIAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gGgtFMkVUZXN0NjE3MAodEhCqqqqqqqqqqqqqqqqqqqqqGglFMkVTZWNvbmQSBjgBQAVIAQ
```

Feed that URL to the device (`iface.localNode.setURL(url)` via the Python CLI, or paste/scan it in any app — the Android channel-import dialog surfaced it as `Hop Limit: 7 -> 5`, `Use Preset: true -> false`, which is the tell that `use_preset` silently flipped to `false` because the imported `lora_config` didn't set it).

Confirmed the trigger is specifically `bandwidth=0`: re-running the identical flow later with the same `use_preset=false` but an **explicit** `bandwidth=250, spread_factor=11, coding_rate=5` did **not** reproduce — clean radio re-init, `config.lora.bandwidth: 250` on readback, no heap warning, no `numFreqSlots` overflow.

### Serial trace (trimmed to the relevant window; timestamps/uptime as logged)

```
INFO  | 14:02:34 262215 [Router] Client set config
DEBUG | 14:02:34 262215 [Router] LoRa config, region is not LORA_24, applying directly
INFO  | 14:02:34 262215 [Router] Set config: LoRa
WARN  | 14:02:34 262215 [Router] Invalid coding_rate 0, setting to 5
WARN  | 14:02:34 262215 [Router] Invalid spread_factor 0, setting to 11
INFO  | 14:02:34 262215 [Router] Delay save of changes to disk until the open transaction is committed
                                                        ← note: NO "Invalid bandwidth 0" warning — bandwidth is not validated
...
INFO  | 14:02:35 262216 [Router] Handle admin payload 65
INFO  | 14:02:35 262216 [Router] Disable bluetooth until reboot
WARN  | 14:02:55 262236 [Router] BLE onRead(301): timeout waiting for data after 19920 ms, 4000 tries, giving up and returning 0-size response
[BLEServer.cpp:866] handleGATTServerEvent(): subscribe event; attr_handle=8, subscribed: false
[BLEServer.cpp:866] handleGATTServerEvent(): subscribe event; attr_handle=20, subscribed: false
[BLECharacteristic.cpp:1029] setSubscribe(): New subscribe value for conn: 1 val: 0
[BLEServer.cpp:866] handleGATTServerEvent(): subscribe event; attr_handle=23, subscribed: false
[BLECharacteristic.cpp:1029] setSubscribe(): New subscribe value for conn: 1 val: 0
CORRUPT HEAP: Bad head at 0x3fceda60. Expected 0xabba1234 got 0x3fce9724
INFO  | 14:02:55 262236 [Router] BLE disconnected
INFO  | 14:02:55 262236 [Router] Commit transaction for edited settings
INFO  | 14:02:55 262236 [Router] Save changes to disk
INFO  | 14:02:55 262236 [Router] Wanted region 1, using US
INFO  | 14:02:55 262236 [Router] Radio freq=902.000, config.lora.frequency_offset=0.000
INFO  | 14:02:55 262236 [Router] Set radio: region=US, name=E2ETest6170, config=0, ch=99094799, power=30
INFO  | 14:02:55 262236 [Router] newRegion->freqStart -> newRegion->freqEnd: 902.000000 -> 928.000000 (26.000000 MHz)
INFO  | 14:02:55 262236 [Router] numFreqSlots: 4294967295 x 0.000kHz          ← 0xFFFFFFFF
INFO  | 14:02:55 262236 [Router] channel_num: 99094800
INFO  | 14:02:55 262236 [Router] frequency: 902.000000
INFO  | 14:02:55 262236 [Router] Slot time: 4294967295 msec, preamble time: 4294967295 msec   ← 0xFFFFFFFF again
ERROR | 14:02:55 262236 [Router] NOTE! Record critical error 7 at src/mesh/SX126xInterface.cpp:223
INFO  | 14:02:55 262236 [Router] Final Tx power: 22 dBm
DEBUG | 14:02:55 262236 [Router] Save to disk 31
...
INFO  | 14:02:56 262238 [Router] Reboot in 7 seconds
```

Then on the reboot that follows (same broken config now persisted and reloaded from `/prefs/config.proto`):

```
INFO  | ??:??:?? 2 Set radio: region=US, name=E2ETest6170, config=0, ch=99094799, power=30
INFO  | ??:??:?? 2 numFreqSlots: 4294967295 x 0.000kHz
INFO  | ??:??:?? 2 channel_num: 99094800
INFO  | ??:??:?? 2 Slot time: 4294967295 msec, preamble time: 4294967295 msec
INFO  | ??:??:?? 2 SX126x init result -8
INFO  | ??:??:?? 2 Frequency set to 902.000000
INFO  | ??:??:?? 2 Bandwidth set to 0.000000
INFO  | ??:??:?? 2 Power output set to 22
```

`SX126x init result -8` persists across the reboot too — the radio comes up in this broken state and stays there (I did not test whether it can transmit/receive at all in this condition; treat radio functionality as unverified-broken, not just "cosmetically wrong").

## What I think is happening (educated guess, not a code read)

1. Something in the region/frequency-slot setup path (near the `numFreqSlots`/`Slot time`/`preamble time` log block, likely `RadioInterface.cpp` or the SX126x-family `init()`) computes slot count and/or slot time as a function of `1 / bandwidth` or `range / bandwidth` without a zero-check. `bandwidth=0` → unsigned division wraps to `0xFFFFFFFF` (or the compiler/hardware saturates), which is exactly what both `numFreqSlots` and `Slot time`/`preamble time` show, in lockstep — too clean a match to be coincidence.
2. That bogus `numFreqSlots` (or `channel_num`, itself derived and also huge/non-sensical at `99094800`) likely feeds an array size or index calculation downstream — a very plausible mechanism for the `CORRUPT HEAP` report that fires in the same window, though I haven't traced the exact allocation site.
3. Separately, RadioLib's own `SX126x::setBandwidth()`/`begin()` correctly detects the invalid `0` bandwidth and returns `RADIOLIB_ERR_INVALID_BANDWIDTH` (`-8`) — confirmed by the logged `SX126x init result -8` — but the caller in `SX126xInterface.cpp` (the "Record critical error 7" site, line ~223, is the closest named anchor I have) logs the failure and continues initializing anyway (`Bandwidth set to 0.000000`, `Power output set to 22`) rather than bailing out or substituting a safe default bandwidth.

## Ruled out / narrowed

- **Not specific to the Android channel-import path or PR #6170.** The transaction wrapper (`begin_edit_settings`/`commit_edit_settings`) just delivered the malformed `set_config(lora=...)` in the same session as a channel replacement; a plain one-shot `set_config` with the same `lora_config` should reproduce it identically (untested by me, but the failure is entirely inside the LoRa-config-apply/radio-reinit path, after the transaction/admin layer is done with it).
- **Not `use_preset` alone.** `use_preset=false` with an explicit non-zero `bandwidth` (`250`, `spread_factor=11`, `coding_rate=5`) does **not** reproduce — clean re-init, correct `config.lora.bandwidth` on readback via `get_config`. The trigger is specifically the zero-value `bandwidth` field slipping through where `coding_rate`/`spread_factor` are already guarded.
- **Not a one-off flaky heap report.** I hit this on the very first live test and it correlated exactly with the `numFreqSlots`/`Slot time` overflow values every time I read the log for that run; I didn't get a second independent repro attempt at the *exact* same config (subsequent tests deliberately set a valid bandwidth to unblock my own testing), so "always reproduces" is not yet double-confirmed — see below.

## What I haven't verified (be honest about scope)

- Only tested on **one board** (Heltec V3 / ESP32-S3 / SX126x). Unknown whether other radio families (SX1262 elsewhere, LR11xx, SX128x/2.4GHz path) hit the same code path or have their own zero-bandwidth guards.
- Did not attempt a **second** independent repro run with the exact same `bandwidth=0` config — I moved on to unblock my own (unrelated) test once I'd identified the cause. Worth a maintainer re-run to confirm determinism before treating the heap corruption as guaranteed-reproducible.
- Did not check whether the radio is fully dead (no TX/RX) or partially degraded in this state — I only observed the log output, not actual over-the-air behavior post-corruption.
- Have not traced the actual source line for the `numFreqSlots`/`Slot time` computation or the heap-corruption allocation site — the line/file references above (`SX126xInterface.cpp:223`) are only what firmware itself logged, not something I confirmed by reading the source.

## Ask

1. Add the same "invalid input, clamp/reject with a `WARN`" treatment `coding_rate`/`spread_factor` already get, for `bandwidth == 0` on a custom (non-preset) LoRa config — ideally rejecting the whole config (don't commit/reboot into a known-broken radio state) rather than clamping to a guessed value, since a silently-substituted bandwidth is its own footgun.
2. Check the return value of the RadioLib `SX126x` init/`setBandwidth()` call at the `SX126xInterface.cpp:223` "critical error 7" site and actually handle failure (abort init / surface a client-visible error) instead of logging and continuing into a half-configured radio.
3. If you can reproduce the heap corruption, I'd treat that as the higher-priority half of this report — a client (buggy or malicious) sending an incomplete custom LoRa config shouldn't be able to get anywhere near heap corruption. Happy to help narrow down the allocation site if you point me at the frequency-slot calc code.

I have the full raw serial capture for the run above and can re-run the exact reproducer (with or without an app in the loop) on request — just say what additional data would help.
