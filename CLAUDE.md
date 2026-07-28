# CLAUDE.md

This file is a pointer for agent runners that key off the Claude filename. The
canonical guidance lives in [`AGENTS.md`](./AGENTS.md) — read that file.

The two are kept in sync. If they diverge, **`AGENTS.md` wins**.

A bare pointer is easy to skip mid-task, so the load-bearing constraints are
repeated here. They are the ones that cause silent wrong behaviour rather than
an obvious error:

- **`MESHTASTIC_WORKSPACE` must be set** or JDK pinning is inert and Gradle
  quietly auto-provisions its own JDKs. `direnv` sets it.
- **Six JDKs are required**, satisfying three different Gradle mechanisms
  (compile toolchains, per-repo daemon JVM criteria, per-module vendor
  toolchains). Removing any one breaks a specific repo.
- **Toolchain config belongs in `gradle.properties`, never `GRADLE_OPTS`** —
  the daemon never sees the launcher's environment.
- **Default branches are not all `main`** — `firmware` uses `develop`,
  `meshtastic-mcp` and `protobufs` use `master`. Resolve `origin/HEAD`.
- **`.gitignore` ignores everything by default.** A new file here is untracked
  until whitelisted.
- **`nix flake check` only evaluates shells, it does not build them.** Passing
  eval does not mean a repo builds.
