# Transport Audit — Parallel Agent Prompts

These prompts are designed to spin up parallel workspace agents to implement the
remaining architectural changes from the BLE/transport audit (PR #5071).

## Dependency graph

```
Wave 1 (fully parallel — zero file overlap):
  PR-A: MQTT subscription timing (H7)
  PR-B: ConnectionState cleanup (L13 + L14)
  PR-C: Manager lifecycle — lateinit scope (L12)

Wave 2 (parallel after Wave 1):
  PR-D: Connection manager thread safety (M9)
  PR-E: Dual connectionState reconciliation (H6)

Wave 3 (serial — heavy overlap in core/network transport files):
  PR-F: Transport architecture (H1 + M2 + M3 + L3)
  PR-G: Reconnect policy + HeartbeatSender + constructor side-effects (M4 + M5 + M15)
  PR-H: Mock interface handshake (M16)
```

## Prompts

---

### PR-A: `fix(mqtt): replace yield() with proper connection readiness signal`

See `prompt-a-mqtt-subscription-timing.md`

### PR-B: `refactor(model): remove ConnectionState helper methods and fix updateStatusNotification return type`

See `prompt-b-connection-state-cleanup.md`

### PR-C: `refactor(data): replace lateinit var scope + start() with constructor injection`

See `prompt-c-manager-lifecycle.md`

### PR-D: `fix(data): make MeshConnectionManagerImpl.onConnectionChanged atomic`

See `prompt-d-connection-manager-atomicity.md`

### PR-E: `refactor(service): unify dual connectionState flows into single source of truth`

See `prompt-e-dual-connection-state.md`

### PR-F: `refactor(transport): rename *Interface → *Transport, flatten Spec/Factory layer, extract RadioTransportCallback`

See `prompt-f-transport-architecture.md`

### PR-G: `refactor(transport): extract reconnect policy, shared HeartbeatSender, remove constructor side-effects`

See `prompt-g-reconnect-heartbeat.md`

### PR-H: `fix(transport): add want_config handshake to MockInterface`

See `prompt-h-mock-handshake.md`
