# gradle-flatpak-sources

Workspace-local note. No `AGENTS.md` / `CLAUDE.md`; `CONTRIBUTING.md` (~2.2 KB)
and `CODEOWNERS` are the only governance.

- **Role:** Gradle plugin that generates Flathub-compliant **offline dependency
  manifests** - the thing that lets a Gradle build run inside Flathub's
  network-isolated builder.
- **Stack:** Kotlin, Gradle 9.7.1 wrapper (`-all`). Single `plugin/` module.
- **Default branch:** `main`
- **Shell:** `.#kotlin`

## Why it matters

It is the bridge between the Kotlin/Compose desktop build and Flathub
packaging. Its output is consumed by the Flathub submission for
`org.meshtastic.MeshtasticDesktop` (see the org's `flathub-submission` repo).
`Meshtastic-Android`'s `:desktopApp` is the upstream producer.

## Working here

- The `.#kotlin` shell provides `flatpak-builder` on Linux specifically so you
  can validate generated manifests rather than eyeballing them.
- No daemon JVM criteria - any JDK from the flake's set will start the daemon.
- `CODEOWNERS` exists: expect review routing on PRs.

## Gotchas

- Output correctness is only really provable by running a Flatpak build
  offline. A manifest that looks right can still fail in Flathub's sandbox
  because a dependency was resolved from a cache locally.
- **Vendor the same Gradle distribution the wrapper verifies.** `android`'s
  wrapper sets `distributionSha256Sum` with `validateDistributionUrl=true`, so
  the checksum is of the `-bin` zip. An offline manifest that vendored
  `gradle-9.6.1-all.zip` and only rewrote `distributionUrl` failed verification
  against its own bundled file. Vendoring the identical `-bin` artifact instead
  fixed it and shed ~70 MB (`android` `97d081dea`, PR #6625). Whenever the
  wrapper version moves, the vendored artifact and the checksum move together.
- **CI's Gradle version is not the wrapper's.** `setup-gradle` pins
  `matrix.gradle` over whatever the wrapper says, so a green CI run says
  nothing about the version developers and consumers actually use. The matrix
  was 9.5.1-only while the wrapper sat on 9.7.1, which is how two
  configuration-cache bugs shipped in 0.2.0 (PR #45): the task action captured
  the listener's live URL set, and the service's set was injected from outside
  so a reused CC entry emitted an empty manifest. Now 9.5.1 / 9.6.1 / 9.7.1 -
  floor, `android`'s pin, current. Add the consumer's version whenever it moves.
- Small repo, low commit volume - check whether history is recent before
  assuming current conventions.
