# Cross-repo contracts

The wire-level facts that hold true across every client and the firmware at
once - protobuf rules, the phone↔device envelope, MQTT topics, release order.
Repo-specific mechanics belong in that repo, or in its note beside this one.

Rescued 2026-08 from `~/Desktop/copilot-space-drafts` on the Linux host: the
corpus behind a **"Meshtastic Cross-Platform" GitHub Copilot Space**, written
2026-05. It had no other backing store - `meshtastic/.github` carries only
`LICENSE`, `README.md` and `profile`, and an org-wide code search for both
"Copilot Space" and "Protobuf Contract Reference" returns nothing. The drafts
said changes went "through PRs in `meshtastic/.github`"; no such PR was ever
opened.

Every claim below was re-verified against the repos as they stand in 2026-08
before being written down. Three of the originals did not survive that pass and
are recorded at the bottom, because a wrong contract is worse than a missing
one.

## Source-of-truth order

1. **`protobufs`** - the canonical wire format. Everything else implements it.
2. **`firmware`** - the reference implementation of mesh behaviour. Where the
   proto comment is ambiguous, firmware is what the network actually does.
3. **Clients** - `android`, `apple`, `meshtastic-python`, `web`, and
   `meshtastic-sdk` beneath the first two.

This is an ordering for resolving *disagreements*, not a reading list. What to
read before editing a given repo is [`CLAUDE.md`](../CLAUDE.md) → Protocol.

## The phone↔device envelope

Application payloads nest, and each layer belongs to a different repo's
concern:

```
app payload (TextMessage, Position, Telemetry, …)
  └─ Data          portnum + payload bytes      ← portnums.proto routes it
      └─ MeshPacket    to, from, channel, encrypted payload
          └─ ToRadio / FromRadio                ← client ↔ device only
```

`ToRadio` and `FromRadio` never travel over LoRa. They are the local API
envelope between a client and the radio it is attached to, over BLE, USB serial
or TCP.

The connection handshake is what every client and every fake radio has to
implement: the client sends `want_config_id`, the device streams its config,
`MyNodeInfo` and the node DB, and terminates with `config_complete_id` carrying
that same id (`mesh.proto`, fields 3 and 7). `meshtastic-mcp`'s `replay_start`
serves exactly this handshake, which is why a capture can stand in for a radio.

Compatibility is advertised, not negotiated: `MyNodeInfo.min_app_version`
(field 11) is the minimum client build the device will talk to. Clients compare
their own build against it and tell the user to update - there is no
downgrade path.

## Changing a proto

The blast radius is firmware, both apps, the SDK and the Python library
simultaneously, so:

- **Never reuse or reassign a field number**, including for fields that look
  unused. Some peer on the mesh is still emitting the old meaning.
- **Deprecate, don't delete.** Mark `[deprecated = true]` and say when and why
  in a comment. `module_config.proto`'s `json_enabled` (field 6) is the worked
  example - deprecated in place, number retired.
- **nanopb annotations are firmware memory.** `max_size`, `max_count` and
  `fixed_length` size real buffers on constrained targets. Changing one is a
  firmware change wearing a proto's clothes.
- **New message types get a new portnum** in `portnums.proto` rather than an
  overload of an existing one. Overloading breaks every receiver that routes
  on portnum alone.

`buf lint` runs offline; `buf generate` needs network for the remote plugin.
The mechanics are in [`notes/protobufs.md`](./protobufs.md), the workflow in
[`README.md`](../README.md) → Recipes.

## MQTT

Topics are built in `firmware/src/mqtt/MQTT.h`, and the root is configurable
(`moduleConfig.mqtt.root`, default `msh`):

| Topic | Carries |
| --- | --- |
| `{root}/2/e/{channel_id}/{gateway_id}` | encrypted `ServiceEnvelope` - the normal path |
| `{root}/2/e/PKI/{gateway_id}` | PKI-addressed traffic; firmware subscribes `…/PKI/+` |
| `{root}/2/map/` | protobuf `MapReport` |

Every mesh message on MQTT is wrapped in a `ServiceEnvelope` (`mqtt.proto`):
`packet` (1), `channel_id` (2), `gateway_id` (3). The packet inside is
encrypted with the **same channel key as over the air** - MQTT is a transport,
not a trust boundary. Two consequences that bite:

- The default channel key is well known. Traffic on the default channel over
  MQTT is public, wherever the broker is.
- A packet arriving over MQTT may have crossed the internet from another
  continent. Never treat MQTT arrival as evidence of RF proximity.

## Release order

Wire-format changes roll out in dependency order, so no client ships support
for something firmware cannot yet do:

1. `protobufs` - merge and tag
2. `firmware` - bump the pointer, implement, release
3. clients - take the new protos, implement, release

**How each repo consumes `protobufs` differs, and this is the part the original
drafts got wrong.** Only two repos vendor it as a git submodule:
`firmware/protobufs` and `meshtastic-python/protobufs`. `android` consumes a
**published Maven artifact** - `org.meshtastic:protobufs`, Wire-generated KMP
models, pinned in `gradle/libs.versions.toml` (currently a
`2.7.26.142-gf3c374d-SNAPSHOT` build). There is no proto submodule in `android`
and its `.gitmodules` is empty; a bump there is a version bump, not a
`git submodule update`.

**Tags are forever.** The meshtastic org enforces an org-level ruleset that
blocks tag deletion (`GH013` on `push :refs/tags/x`), and releases are
immutable - a tag once used by a release can never get a new release. Verify
the version is right *before* pushing the tag; a botched one can only be
removed by an org admin in the web UI (found 2026-07-17 cleaning up a bad
v0.1.3 in gradle-flatpak-sources). `gh` tokens without `admin:org` cannot
even view the ruleset.

## Dropped from the original drafts

- **The feature-parity matrix.** Ten rows of ✅/⚠️/❌ across five clients,
  self-described as "best-effort", never refreshed after 2026-05. A parity
  table nobody re-verifies reads as authority and is wrong within a release.
- **Org-wide branch-prefix conventions.** The drafts asserted `feat/`, `fix/`,
  `chore/`… as org policy. The repos disagree in practice -
  [`CLAUDE.md`](../CLAUDE.md)'s repo table records per-repo commit style, and
  `firmware` (sentence-style, ad-hoc prefixes), `protobufs` (mixed) and
  `TAKPacket-SDK` (imperative with a detailed body) each do their own thing.
  Match the repo, not an org rule that was never adopted.
- **The `{root}/2/json/…` topic.** Its config switch, `json_enabled`, is
  deprecated in `module_config.proto` and no `jsonTopic` exists in the firmware
  MQTT source. Treat protobuf as the only format.

Also dropped as duplication rather than error: the repo inventory (superseded
by [`CLAUDE.md`](../CLAUDE.md), which `nix run .#brief` keeps honest) and the
"never assume, read the repo's docs first" preamble, which is that file's
Protocol section.
