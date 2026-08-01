# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
{
  description = "Meshtastic workspace — dev shells for the Meshtastic org repos (firmware, apps, Kotlin libraries, MCP tooling)";

  # warn-dirty is deliberately NOT set via nixConfig here: an untrusted
  # nixConfig setting makes nix print an "ignoring untrusted flake
  # configuration setting" warning on every run — trading one line of noise
  # for two (verified). The suppression lives in .envrc as NIX_CONFIG,
  # which needs no trust because it is the user's own environment.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      # x86_64-darwin is absent on purpose: nixpkgs 26.11 dropped Intel
      # macOS support outright (it throws on eval). Apple-silicon only.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs {
              inherit system;
              # Google ships android-cli as an unfree prebuilt binary. Allow
              # that one package rather than opening up allowUnfree wholesale.
              config.allowUnfreePredicate = p: builtins.elem (nixpkgs.lib.getName p) [ "android-cli" ];
            };
          }
        );
    in
    {
      #############################################################
      # The workspace: every Meshtastic-org repo we work in, and
      # which dev shell it belongs to. `nix run .#sync` clones
      # whatever is missing — this list is what makes the workspace
      # portable to a fresh machine.
      #
      # Deliberately absent:
      #   meshtastic-sniffer   — alphafox02/, not the org
      #   meshtastic-backend   — Gradle 7.3.1 + Groovy DSL; predates
      #                          JDK 21 and won't share the kotlin shell
      #   pluginmeshtastic     — needs the non-redistributable ATAK SDK
      #############################################################
      workspace = {
        firmware = {
          shell = "firmware";
          repo = "meshtastic/firmware";
        };
        android = {
          shell = "android";
          repo = "meshtastic/Meshtastic-Android";
        };
        apple = {
          shell = "apple";
          repo = "meshtastic/Meshtastic-Apple";
        };
        meshtastic-sdk = {
          shell = "kotlin";
          repo = "meshtastic/meshtastic-sdk";
        };
        MQTTastic-Client-KMP = {
          shell = "kotlin";
          repo = "meshtastic/MQTTastic-Client-KMP";
        };
        kzstd = {
          shell = "kotlin";
          repo = "meshtastic/kzstd";
        };
        gradle-flatpak-sources = {
          shell = "kotlin";
          repo = "meshtastic/gradle-flatpak-sources";
        };
        meshtastic-mcp = {
          shell = "mcp";
          repo = "meshtastic/meshtastic-mcp";
        };
        # Shared .proto definitions. Also vendored as a submodule inside
        # firmware/protobufs — edit here, bump the pointer there.
        protobufs = {
          shell = "protobufs";
          repo = "meshtastic/protobufs";
        };
        # Cross-platform design standards, tokens and brand assets. Work here
        # is driven mostly through the org design board, not the repo:
        # https://github.com/orgs/meshtastic/projects/16
        design = {
          shell = "design";
          repo = "meshtastic/design";
        };
      };

      devShells = forAllSystems (
        { pkgs, ... }:
        let
          inherit (pkgs) lib;
          isLinux = pkgs.stdenv.isLinux;

          #########################################################
          # Common: present in every shell.
          #########################################################
          common = with pkgs; [
            git
            gh
            jq
            yq-go
            ripgrep
            fd
            just
            protobuf # meshtastic protobufs, shared across every repo
          ];

          #########################################################
          # JVM / Kotlin
          #
          # Gradle itself is NOT installed — every repo pins its own
          # version via ./gradlew (9.5.1 / 9.6.1). Nix supplies the JDKs.
          #
          # MQTTastic-Client-KMP declares javaToolchain = 11 while
          # android + meshtastic-sdk target 21, so we expose several
          # JDKs and point Gradle's toolchain resolver at all of them.
          # Auto-provisioning is disabled: Gradle must never download a
          # JDK behind Nix's back, or builds stop being reproducible.
          #########################################################
          # Two DIFFERENT Gradle mechanisms both read this list:
          #
          #  1. Toolchains — which JDK compiles the code. Driven by
          #     jvmToolchain(...) in the build scripts.
          #  2. Daemon JVM criteria — which JDK the daemon itself runs
          #     on. Declared per-repo in gradle/gradle-daemon-jvm.properties
          #     and NOT satisfiable by just any JDK:
          #
          #       meshtastic-sdk        vendor=JETBRAINS, version=21
          #       Meshtastic-Android    version=25
          #       MQTTastic-Client-KMP  version=21 (any vendor)
          #       kzstd, gradle-flatpak-sources — no criteria
          #
          # So the JetBrains Runtime and JDK 25 are not optional extras;
          # without them those two repos cannot start a daemon at all
          # once auto-provisioning is off.
          # A third mechanism on top of the two above: individual modules
          # can demand their own toolchain vendor. Meshtastic-Android's
          # :desktopApp (Compose Desktop) asks for JetBrains 25 at
          # desktopApp/build.gradle.kts:129 — its daemon runs happily on
          # plain JDK 25, but that module will not compile without JBR.
          jdks = [
            pkgs.jdk21
            pkgs.jdk17
            pkgs.temurin-bin-11
            pkgs.jetbrains.jdk-21 # meshtastic-sdk daemon (vendor=JETBRAINS)
            pkgs.jdk25 # Meshtastic-Android daemon
            pkgs.jetbrains.jdk # JBR 25 — :desktopApp toolchain
          ];
          primaryJdk = pkgs.jdk21;
          # .home where it exists — on Darwin it differs from the
          # derivation root, and Gradle wants a real JAVA_HOME layout.
          # The JetBrains build has no .home, hence the fallback.
          toolchainPaths = lib.concatStringsSep "," (map (j: j.home or "${j}") jdks);

          jvmTools =
            with pkgs;
            [
              primaryJdk
              ktlint
              kotlin-language-server
            ]
            ++ jdks;

          # These MUST land in gradle.properties, not GRADLE_OPTS.
          # GRADLE_OPTS configures the launcher JVM only; toolchain
          # resolution happens in the daemon, which never sees it.
          # Verified the hard way: with GRADLE_OPTS, `./gradlew
          # javaToolchains` still reported auto-download Enabled and
          # provisioned four Temurin JDKs into ~/.gradle/jdks.
          gradleProperties = ''
            # Generated by the Meshtastic workspace flake. Do not edit.
            org.gradle.java.installations.auto-detect=false
            org.gradle.java.installations.auto-download=false
            org.gradle.java.installations.paths=${toolchainPaths}
          '';

          jvmHook = ''
            export JAVA_HOME="${primaryJdk.home}"

            ${lib.optionalString isLinux ''
              # Compose Desktop tests (Skiko) dlopen libGL.so.1 at load time even
              # for CPU raster rendering. The Nix JVM's glibc never reads the
              # host's ld.so cache, so the host's own mesa is invisible and every
              # Compose UI test in a jvmTest run dies with LibraryLoadException —
              # 26 at once in Meshtastic-Android's :feature:settings, none of them
              # naming libGL; the real cause is the last Caused-by line. libglvnd
              # (the GL dispatch library) satisfies the link; verified sufficient
              # for the headless raster tests. Same failure class as the manylinux
              # wheels in .#mcp.
              export LD_LIBRARY_PATH="${
                pkgs.lib.makeLibraryPath [ pkgs.libglvnd ]
              }''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            ''}

            # Writing gradle.properties means owning GRADLE_USER_HOME, so
            # this only engages when MESHTASTIC_WORKSPACE is set (i.e. via
            # the workspace .envrc). Your ~/.gradle is never touched.
            #
            # Note it must NOT be derived from ./. — inside a flake that
            # evaluates to the read-only /nix/store copy of this file.
            if [ -n "''${MESHTASTIC_WORKSPACE:-}" ]; then
              export GRADLE_USER_HOME="''${GRADLE_USER_HOME:-$MESHTASTIC_WORKSPACE/.cache/gradle}"
              mkdir -p "$GRADLE_USER_HOME"
              cat > "$GRADLE_USER_HOME/gradle.properties" <<'EOF'
            ${gradleProperties}
            EOF
            else
              echo "  !  MESHTASTIC_WORKSPACE unset — JDK toolchains are NOT pinned."
              echo "     Gradle will auto-provision its own JDKs into ~/.gradle/jdks."
              echo "     Fix: run from the workspace root with direnv, or export"
              echo "     MESHTASTIC_WORKSPACE=/path/to/meshtastic first."
            fi
          '';

          #########################################################
          # Android SDK — host-managed, NOT androidenv.
          #
          # androidenv *does* carry build-tools 37.0.0 / platforms 37.1,
          # so currency is not the reason. The reason is write access:
          # an androidenv SDK lives in /nix/store read-only, and AGP
          # wants to write into $ANDROID_HOME (build-tools installs,
          # aapt2 from Maven, license acks). That is the documented
          # aapt2FromMavenOverride gotcha, and it bites hardest when
          # compileSdk moves and the composition hasn't caught up.
          #
          # On Ubuntu (FHS) a host SDK Just Works and sdkmanager stays
          # free to move. See notes below for the androidenv variant if
          # you want full pinning instead.
          #########################################################
          androidHook = ''
            export ANDROID_HOME="''${ANDROID_HOME:-$HOME/Android/Sdk}"
            export ANDROID_SDK_ROOT="$ANDROID_HOME"
            if [ ! -d "$ANDROID_HOME/platforms" ]; then
              echo "  !  No Android SDK at $ANDROID_HOME"
              echo "     Install cmdline-tools, then:"
              echo "     sdkmanager 'platforms;android-37' 'build-tools;37.0.0' 'platform-tools'"
            fi
            export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
          '';

          # android-cli deliberately appears in NO dev shell — it exists
          # only inside `nix run .#bootstrap-sdk`, where the reasoning is
          # written out in full.

          #########################################################
          # Python (meshtastic-mcp, firmware build scripts, node CLI)
          #########################################################
          python = pkgs.python313;

          # esptool (and friends) propagate their own interpreter, which
          # can land ahead of ours on PATH — observed as `python3` being
          # 3.14.6 while UV_PYTHON was 3.13.14. Prepend explicitly so the
          # bare `python3` and the one uv builds against are the same.
          pythonHook = ''
            export PATH="${python}/bin:$PATH"
          '';

          #########################################################
          # Talking to physical nodes over serial / BLE.
          #########################################################
          nodeTools =
            with pkgs;
            [
              esptool
              picocom
              usbutils
            ]
            ++ lib.optionals isLinux [
              android-tools # adb, for the Android app + MCP emulator e2e
              bluez
            ];

          #########################################################
          # clangd for firmware.
          #
          # compile_commands.json alone is NOT enough. Its entries invoke
          # PlatformIO's cross-compiler (xtensa-esp32s3-elf-g++ for ESP32,
          # arm-none-eabi-g++ for nRF52), and clangd cannot guess that
          # driver's builtin system include paths. Every translation unit
          # then dies at the first libc header:
          #
          #     'machine/endian.h' file not found  ->  1 error, stopping now
          #
          # --query-driver lets clangd execute the driver to extract them.
          # It is a clangd COMMAND-LINE flag; .clangd config cannot set it.
          # So wrap the binary rather than ask every editor to pass it —
          # same reasoning as platformio-core over platformio: the shell
          # should hand you a tool that already works.
          #
          # The glob is deliberately narrow: only PlatformIO's own package
          # dir, only gcc/g++ drivers. clangd will not execute anything else.
          #########################################################
          clangdPio = pkgs.writeShellApplication {
            name = "clangd";
            text = ''
              pio_dir="''${PLATFORMIO_CORE_DIR:-$HOME/.platformio}"
              exec ${pkgs.clang-tools}/bin/clangd \
                --query-driver="$pio_dir/packages/*/bin/*-gcc,$pio_dir/packages/*/bin/*-g++" \
                "$@"
            '';
          };

          serialHook = lib.optionalString isLinux ''
            if [ -n "$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null)" ]; then
              if ! id -nG | grep -qw dialout; then
                echo "  !  Serial devices present but you are not in 'dialout'."
                echo "     sudo usermod -aG dialout $USER   (then log out and back in)"
              fi
            fi
          '';

          banner = name: repos: ''
            echo ""
            echo "  meshtastic/${name}"
            echo "  ${repos}"
            echo ""
          '';
          # Which repos a shell serves, derived from the workspace table
          # so a banner cannot drift when a repo is added or moved.
          reposFor =
            shellName:
            lib.concatStringsSep " · " (
              lib.attrNames (lib.filterAttrs (_: v: v.shell == shellName) self.workspace)
            );
          # Which PlatformIO is right depends on the HOST, not the target, and
          # a flake cannot know the host: `builtins.pathExists /etc/NIXOS` does
          # evaluate, but making outputs depend on the evaluating machine means
          # the same flake and lock produce different derivations on NixOS than
          # on Ubuntu — `nix flake check --all-systems` in CI would then be
          # answering a question no NixOS contributor asked. So both are built,
          # named, and checked, and the shellHook tells you when you picked the
          # one that cannot work here.
          #
          # Upstream firmware's own flake selects `platformio` (verified — see
          # firmware/flake.nix), which is the right call for the NixOS users it
          # targets and the wrong one everywhere AppArmor restricts user
          # namespaces.
          mkFirmwareShell =
            {
              pio,
              extraHook,
            }:
            pkgs.mkShell {
              name = "meshtastic-firmware";
              # clangdPio comes FIRST so its wrapper shadows the plain clangd
              # in clang-tools. Verified with `command -v clangd` — do not
              # reorder. clang-tools is still here for clang-tidy, clang-query
              # and the rest, which need no wrapping.
              packages = [
                clangdPio
                pio
              ]
              ++ common
              ++ nodeTools
              ++ (with pkgs; [
                python
                cmake
                ninja
                clang-tools # clang-tidy etc.; ships no compiler driver
                yaml-cpp # -lyaml-cpp in the native/portduino link (variants/native/portduino.ini)
              ]);
              shellHook =
                serialHook
                + pythonHook
                + (banner "firmware" "firmware — default env: heltec-v3")
                + extraHook
                + ''
                  export PLATFORMIO_CORE_DIR="''${PLATFORMIO_CORE_DIR:-$HOME/.platformio}"
                  # `ccache` used to sit in this shell's packages and do
                  # nothing whatsoever: PlatformIO drives the compilers
                  # through SCons and never invokes it, and firmware's
                  # platformio.ini sets no build_cache_dir either. Its own
                  # object cache is the supported mechanism, and the env
                  # override is honoured — verified with `pio project
                  # config`, which reports the value back. Workspace-local,
                  # beside the Gradle cache, because .cache/ is documented
                  # as disposable.
                  export PLATFORMIO_BUILD_CACHE_DIR="''${PLATFORMIO_BUILD_CACHE_DIR:-''${MESHTASTIC_WORKSPACE:-$HOME}/.cache/platformio-build}"
                  echo "  pio run -e heltec-v3"
                  echo "  pio run -e heltec-v3 -t upload"
                  echo "  pio device monitor"
                  if [ -n "''${MESHTASTIC_WORKSPACE:-}" ]; then
                    fw="$MESHTASTIC_WORKSPACE/firmware"
                    if [ ! -f "$fw/compile_commands.json" ]; then
                      echo ""
                      echo "  !  no compile_commands.json — clangd cannot resolve includes."
                      echo "     pio run -e heltec-v3 -t compiledb"
                    fi
                    if [ ! -f "$fw/.clangd" ]; then
                      echo ""
                      echo "  !  no .clangd — clangd will reject the xtensa GCC flags."
                      echo "     recreate it from AGENTS.md (Firmware / clangd)."
                    fi
                  fi
                  echo ""
                '';
            };

        in
        {
          #########################################################
          # default — everything light, for roaming the workspace
          #########################################################
          default = pkgs.mkShell {
            name = "meshtastic";
            packages =
              common
              ++ jvmTools
              ++ nodeTools
              ++ [
                python
                pkgs.uv
                pkgs.nodejs_22
              ];
            shellHook =
              jvmHook
              + androidHook
              + serialHook
              + (banner "workspace" "all toolchains — use a focused shell for real work")
              + ''
                echo "  .#kotlin    ${reposFor "kotlin"}"
                echo "  .#android   Meshtastic-Android"
                echo "  .#firmware  firmware (PlatformIO)"
                echo "  .#mcp       meshtastic-mcp"
                echo "  .#apple     Meshtastic-Apple (macOS)"
                echo "  .#nodes     serial/BLE tools only"
                echo ""
                echo "  nix run .#sync   clone any missing repo"
                echo ""
              '';
          };

          #########################################################
          # kotlin — the KMP library repos
          #########################################################
          kotlin = pkgs.mkShellNoCC {
            name = "meshtastic-kotlin";
            packages =
              common
              ++ jvmTools
              # gradle-flatpak-sources emits Flathub offline manifests;
              # flatpak-builder is what you check its output against.
              ++ lib.optionals isLinux [ pkgs.flatpak-builder ];
            shellHook =
              jvmHook
              + androidHook
              + (banner "kotlin" (reposFor "kotlin"))
              + ''
                echo "  JDKs: 21 (default), 17, 11 — Gradle toolchains resolved from Nix"
                echo "  Build with ./gradlew (each repo pins its own Gradle: 9.5.1 / 9.6.1)"
                echo ""
              '';
          };

          #########################################################
          # android — the app; kotlin shell plus emulator plumbing
          #########################################################
          android = pkgs.mkShell {
            name = "meshtastic-android";
            # No android-tools here: androidHook puts the SDK's own
            # platform-tools first on PATH, so a Nix adb would just be a
            # shadowed duplicate — and adb must match the SDK anyway.
            packages = common ++ jvmTools ++ lib.optionals isLinux [ pkgs.scrcpy ];
            shellHook =
              jvmHook
              + androidHook
              + (banner "android" "Meshtastic-Android — compileSdk 37, minSdk 24")
              + ''
                echo "  ./gradlew :androidApp:assembleFdroidDebug"
                echo "  android emulator list / start <name>"
                echo "  android layout --output=./hierarchy.json"
                echo "  adb devices"
                echo ""
              '';
          };

          #########################################################
          # firmware — PlatformIO
          #
          # PlatformIO fetches its own cross-toolchains into
          # PLATFORMIO_CORE_DIR. Don't add gcc-arm-embedded here; two
          # toolchains on PATH is how you get baffling link errors.
          #
          # platformio-core, NOT platformio. The latter is a buildFHSEnv
          # bubblewrap wrapper, and this host sets
          # kernel apparmor_restrict_unprivileged_userns=1 (Ubuntu
          # default), which denies unprivileged user namespaces to
          # unconfined binaries — everything in /nix/store. Every pio
          # invocation dies with:
          #     bwrap: setting up uid map: Permission denied
          # Verified this is the machine, not a tool sandbox.
          #
          # The FHS wrapper exists to make PlatformIO's downloaded,
          # dynamically-linked toolchains run on NixOS. Ubuntu is already
          # FHS, so it buys nothing here. ON NIXOS, SWAP THIS BACK to
          # pkgs.platformio or the downloaded toolchains will not run.
          #
          # clang-tools is the ONE exception to the "no second toolchain"
          # rule above, and it is safe for a specific reason: the package
          # ships no bare compiler driver. Its bin/ is clangd, clang-format,
          # clang-tidy and friends — no `clang`, `clang++`, `cc` or `gcc` to
          # shadow the cross-compilers PlatformIO downloads. Verified by
          # listing the derivation's bin/.
          #
          # clangd needs compile_commands.json, which PlatformIO generates:
          #     pio run -e heltec-v3 -t compiledb
          # Upstream already gitignores /compile_commands.json, so producing
          # it leaves the tree clean.
          #
          # Formatting stays with trunk: firmware's tracked
          # .vscode/settings.json sets editor.defaultFormatter to trunk.io
          # for [cpp], and trunk fetches its own clang-format. The
          # clang-format landing on PATH here is incidental — don't wire an
          # editor to it and end up fighting trunk over the same files.
          #########################################################
          # The default. platformio-core is the bare Python package: no FHS
          # sandbox, so nothing for AppArmor to deny. Correct on any distro
          # that is already FHS, which is every mainstream Linux and macOS.
          firmware = mkFirmwareShell {
            pio = pkgs.platformio-core;
            extraHook = ''
              if [ -e /etc/NIXOS ]; then
                echo "  !  NixOS detected, and this shell ships platformio-core."
                echo "     PlatformIO downloads its own dynamically-linked"
                echo "     toolchains, which will not run without an FHS tree."
                echo "     Use:  nix develop .#firmware-fhs"
                echo ""
              fi
            '';
          };

          # For NixOS and anything else that is not FHS. pkgs.platformio is a
          # buildFHSEnv wrapper, which is what lets PlatformIO's downloaded
          # toolchains find /lib64/ld-linux-x86-64.so.2 and friends.
          firmware-fhs = mkFirmwareShell {
            pio = pkgs.platformio;
            extraHook = ''
              if [ ! -e /etc/NIXOS ]; then
                echo "  !  This shell wraps PlatformIO in buildFHSEnv (bwrap)."
                echo "     On a host with"
                echo "     kernel.apparmor_restrict_unprivileged_userns=1"
                echo "     (the Ubuntu default) every pio call dies with"
                echo "     'bwrap: setting up uid map: Permission denied'."
                echo "     On an FHS distro use:  nix develop .#firmware"
                echo ""
              fi
            '';
          };

          #########################################################
          # mcp — Python server + Node web-ui
          #########################################################
          mcp = pkgs.mkShellNoCC {
            name = "meshtastic-mcp";
            # The android CLI comes from $ANDROID_HOME/cmdline-tools
            # (androidHook puts it on PATH) — this repo's hardware-free
            # e2e drives an emulator via `android emulator` / `android
            # layout` rather than hand-rolled avdmanager/adb calls.
            packages =
              common
              ++ nodeTools
              ++ [
                python
                pkgs.uv
                pkgs.nodejs_22
                pkgs.ruff
              ];
            shellHook =
              serialHook
              + androidHook
              + pythonHook
              + (banner "mcp" "meshtastic-mcp — Python >=3.11, uv.lock")
              + ''
                # Let uv build venvs against the Nix interpreter rather than
                # downloading its own CPython.
                export UV_PYTHON="${python}/bin/python3"
                export UV_PYTHON_DOWNLOADS=never
                # ...which means the venv's manylinux wheels (numpy, opencv,
                # torch — the [ui]/[sdr] extras) load against Nix's loader,
                # and it cannot see the system libstdc++/libz they link. The
                # import dies as "Importing the numpy C-extensions failed",
                # naming neither library; the real cause is the last line of
                # the traceback (libstdc++.so.6 / libz.so.1 not found).
                export LD_LIBRARY_PATH="${
                  pkgs.lib.makeLibraryPath [
                    pkgs.stdenv.cc.cc.lib
                    pkgs.zlib
                  ]
                }''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                echo "  uv sync && uv run pytest"
                echo ""
              '';
          };

          #########################################################
          # apple — Meshtastic-Apple
          #
          # Xcode itself can't be packaged (not redistributable), so
          # this shell only supplies the linting/formatting layer and
          # defers the actual build to the host toolchain.
          #########################################################
          apple = pkgs.mkShellNoCC {
            name = "meshtastic-apple";
            packages =
              common
              ++ lib.optionals pkgs.stdenv.isDarwin (
                with pkgs;
                [
                  swiftlint
                  swift-format
                  xcbeautify
                ]
              );
            shellHook = (banner "apple" "Meshtastic-Apple — iOS · macOS · watchOS · visionOS") + ''
              if [ "$(uname)" != "Darwin" ]; then
                echo "  !  This repo builds only on macOS with Xcode."
                echo "     On Linux this shell gives you git/gh for review work."
              else
                echo "  xcodebuild -scheme Meshtastic | xcbeautify"
              fi
              echo ""
            '';
          };

          #########################################################
          # protobufs — the shared .proto definitions
          #
          # Deceptively multi-toolchain for a "just protos" repo:
          #   /              buf v2 (buf.yaml, buf.gen.yaml)
          #   packages/ts    Deno (deno.json + deno.lock), not npm
          #   packages/kmp   Gradle 9.6.1 wrapper, no daemon criteria
          #   packages/rust  Cargo
          #   nanopb.proto   consumed by firmware's vendored copy
          #
          # Codegen uses a REMOTE buf plugin (buf.build/bufbuild/es:v2.1.0),
          # so `buf generate` needs network — protoc-gen-es is not resolved
          # locally and deliberately isn't pinned here.
          #########################################################
          protobufs = pkgs.mkShellNoCC {
            name = "meshtastic-protobufs";
            packages =
              common
              ++ jvmTools
              ++ (with pkgs; [
                buf
                nanopb
                deno
                nodejs_22
                cargo
                rustc
              ]);
            shellHook =
              jvmHook
              + (banner "protobufs" "shared .proto definitions — buf · deno · gradle · cargo")
              + ''
                echo "  buf lint && buf generate     (generate needs network: remote plugin)"
                echo "  cd packages/ts   && deno task …"
                echo "  cd packages/kmp  && ./gradlew build"
                echo "  cd packages/rust && cargo build"
                echo ""
              '';
          };

          #########################################################
          # design — cross-platform design standards and assets
          #
          # Two real toolchains despite looking like an asset dump:
          #   tokens/   node + style-dictionary (`npm run build`)
          #   bin/generate-pngs.sh   inkscape --batch-process
          #
          # inkscape is a heavy closure. It is here because the repo's own
          # script calls it by name; substituting resvg/librsvg would render
          # differently and silently change shipped brand assets.
          #
          # Most work here starts from the org design board rather than the
          # repo tree — `gh` (in common) is the primary tool.
          #########################################################
          design = pkgs.mkShellNoCC {
            name = "meshtastic-design";
            packages = common ++ [ pkgs.nodejs_22 ] ++ lib.optionals isLinux [ pkgs.inkscape ];
            shellHook = (banner "design" "design standards · tokens · brand assets") + ''
              echo "  board   https://github.com/orgs/meshtastic/projects/16"
              echo "  gh issue list --repo meshtastic/design"
              echo "  cd tokens && npm ci && npm run build   (style-dictionary)"
              echo "  ./bin/generate-pngs.sh                 (inkscape)"
              echo ""
              echo "  standards/meshtastic_design_standards_latest.md is the"
              echo "  authoritative spec — versioned copies sit beside it."
              echo ""
            '';
          };

          #########################################################
          # nodes — no build toolchain, just talk to hardware
          #########################################################
          nodes = pkgs.mkShellNoCC {
            name = "meshtastic-nodes";
            packages =
              common
              ++ nodeTools
              ++ [
                python
                pkgs.uv
              ];
            shellHook =
              serialHook
              + pythonHook
              + (banner "nodes" "serial · BLE · flashing")
              + ''
                export UV_PYTHON="${python}/bin/python3"
                echo "  uvx meshtastic --info"
                echo "  uvx meshtastic --port /dev/ttyUSB0 --nodes"
                echo "  esptool.py chip_id"
                echo ""
              '';
          };
        }
      );

      #############################################################
      # The workspace tools, as buildable packages. `apps` below wraps
      # them for `nix run`, and `checks` lists them so `nix flake
      # check` BUILDS them — which is when writeShellApplication runs
      # ShellCheck. Keeping them only in `apps` meant CI never did.
      #
      # nix run .#sync — clone any missing workspace repo, then
      # report the state of each one. Safe to re-run: git state is
      # only ever read (or fast-forwarded, under --pull), and the only
      # writes are the generated workspace files — .envrc sidecars,
      # .mcp.json, info/exclude patterns — regenerated idempotently.
      #############################################################
      packages = forAllSystems (
        { pkgs, ... }:
        let
          #########################################################
          # Google's android CLI — the agent-oriented front end over
          # adb / sdkmanager / avdmanager / AGP.
          #
          # Lives HERE and only here: used to bootstrap an SDK from
          # nothing, and deliberately in no dev shell. Two reasons:
          #
          #  1. cmdline-tools 22.0.0+ ships the android CLI itself, at
          #     $ANDROID_HOME/cmdline-tools/latest/bin/android, and that
          #     copy is NEWER (1.0.15857036 vs nixpkgs 1.0.15498356). It
          #     wins on PATH anyway, so shipping ours was dead weight.
          #  2. Nix pins only the LAUNCHER. The store binary unpacks the
          #     real ~84M CLI into ~/.android/bin/android-cli and
          #     self-updates it. Its effective version is NOT locked by
          #     flake.lock.
          #
          # What it still buys: `nix run .#bootstrap-sdk` works on a
          # machine with no SDK and no cmdline-tools at all, which is the
          # chicken-and-egg the sdkmanager path cannot solve.
          #
          # Upstream ships x86_64-linux and aarch64-darwin only, hence
          # the availableOn guard.
          #########################################################
          androidCli = nixpkgs.lib.optional (nixpkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.android-cli) pkgs.android-cli;

          entries = nixpkgs.lib.mapAttrsToList (dir: v: "${dir}\t${v.repo}\t${v.shell}") self.workspace;

          #########################################################
          # The tool scripts are real files in scripts/*.sh — editable
          # with shell tooling, shellcheck-able directly, and a 10 KB
          # read instead of this whole flake. writeShellApplication
          # concatenates lib.sh in front of sync/worktree, so ShellCheck
          # still sees each tool whole at build time. Everything Nix
          # must supply reaches the scripts through runtimeEnv; the
          # rationale for each generated file lives in scripts/lib.sh.
          #
          # Store paths go stale on `nix flake update`; re-run .#sync.
          # MESHTASTIC_PIO_BIN is deliberately absent — doctor finds
          # ~/.platformio unaided, verified before dropping it.
          #########################################################
          mcpPython = pkgs.python313; # must match the .#mcp shell
          reposTsv = pkgs.writeText "nixtastic-repos.tsv" (nixpkgs.lib.concatStringsSep "\n" entries + "\n");
          toolEnv = {
            NIXTASTIC_REPOS_TSV = reposTsv;
            NIXTASTIC_UV = "${pkgs.uv}/bin/uv";
            NIXTASTIC_PY = "${mcpPython}/bin/python3";
            NIXTASTIC_LIB = pkgs.lib.makeLibraryPath [
              pkgs.stdenv.cc.cc.lib
              pkgs.zlib
            ];
          };

          sync = pkgs.writeShellApplication {
            name = "meshtastic-sync";
            # coreutils is explicit because mktemp/wc/cut/tr are load-bearing
            # here; relying on the ambient PATH made this work by luck.
            runtimeInputs = [
              pkgs.git
              pkgs.coreutils
              pkgs.jq
            ];
            runtimeEnv = toolEnv;
            text = builtins.readFile ./scripts/lib.sh + builtins.readFile ./scripts/sync.sh;
          };

          # nix run .#bootstrap-sdk — reconcile $ANDROID_HOME against
          # android-sdk-packages.txt. This is the portability answer for
          # the one thing Nix isn't managing: the SDK stays writable
          # (so AGP is happy) but its contents are declared in a file.
          bootstrapSdk = pkgs.writeShellApplication {
            name = "meshtastic-bootstrap-sdk";
            runtimeInputs = [
              pkgs.jdk21
              pkgs.coreutils
            ]
            ++ androidCli;
            runtimeEnv = {
              NIXTASTIC_JDK = pkgs.jdk21.home;
            };
            text = builtins.readFile ./scripts/bootstrap-sdk.sh;
          };
          # nix run .#brief <repo> — orient before touching a repo.
          #
          # Generated live rather than written down, so it cannot go stale the
          # way a hand-maintained index does. Its job is to say WHAT TO READ,
          # not to inline it: per-repo agent docs total ~66 KB and must not all
          # be loaded.
          brief = pkgs.writeShellApplication {
            name = "meshtastic-brief";
            # findutils and gnused are as load-bearing as git here (the spec
            # listing, .claude inventory and PR-title trim all shell out).
            # Undeclared they resolve off the ambient PATH, which works on a
            # normal machine and vanishes in the build sandbox — so leaving
            # them out silently made brief untestable by checks.tools-tests.
            runtimeInputs = [
              pkgs.git
              pkgs.coreutils
              pkgs.findutils
              pkgs.gnused
              pkgs.gh
            ];
            runtimeEnv = {
              NIXTASTIC_REPOS_TSV = reposTsv;
            };
            text = builtins.readFile ./scripts/brief.sh;
          };

          # nix run .#worktree — worktrees that arrive fully outfitted.
          #
          # Since per-repo .envrc files exist, a bare worktree under the
          # repo already inherits the right shell from the nearest ancestor
          # .envrc (verified — this was NOT true before f6b6888, and old
          # claims that it gets the default shell are stale). What a bare
          # worktree still lacks: the .envrc-workspace sidecar where the
          # repo tracks its own .envrc (firmware), the per-directory
          # .mcp.json, and any shell at all if parked outside the repo
          # tree. This tool writes all of it up front; `nix run .#sync`
          # adopts worktrees created behind its back.
          worktree = pkgs.writeShellApplication {
            name = "meshtastic-worktree";
            runtimeInputs = [
              pkgs.git
              pkgs.coreutils
              pkgs.jq
            ];
            runtimeEnv = toolEnv;
            text = builtins.readFile ./scripts/lib.sh + builtins.readFile ./scripts/worktree.sh;
          };

          #########################################################
          # nix run .#doctor — check the wiring the README's
          # "When something looks wrong" table describes.
          #
          # Every failure mode in that table is silent: nothing errors,
          # you just get the wrong toolchain, an unpinned JDK, or an MCP
          # server that stopped starting. Reading a table to diagnose
          # silence is the part worth automating — setup happens once
          # per machine, but these recur.
          #
          # direnv is deliberately NOT in runtimeInputs. It is the
          # user's install being checked; adding ours would make the
          # check pass by construction.
          #########################################################
          doctor = pkgs.writeShellApplication {
            name = "meshtastic-doctor";
            runtimeInputs = [
              pkgs.git
              pkgs.coreutils
              pkgs.jq
            ];
            runtimeEnv = {
              NIXTASTIC_REPOS_TSV = reposTsv;
            };
            text = builtins.readFile ./scripts/doctor.sh;
          };
        in
        {
          inherit
            sync
            brief
            worktree
            doctor
            ;
          bootstrap-sdk = bootstrapSdk;
          default = sync;
        }
      );

      # Wrappers over `packages`, one per tool. writeShellApplication
      # sets meta.mainProgram, so getExe resolves each binary name.
      apps = forAllSystems (
        { system, ... }:
        nixpkgs.lib.mapAttrs (_: drv: {
          type = "app";
          program = nixpkgs.lib.getExe drv;
        }) self.packages.${system}
      );

      # What `nix flake check` actually BUILDS. devShells and apps are
      # only evaluated — verified by feeding check an app with a
      # guaranteed SC2086 failure, which passed — so without this
      # output ShellCheck never gated the scripts in CI. The dev
      # shells stay out on purpose: building a mkShell realizes every
      # input, i.e. CI downloading six JDKs and Inkscape.
      #
      # Run it as TWO commands, locally and in CI:
      #     nix flake check --all-systems --no-build   eval every system
      #     nix flake check                            build yours
      # A bare `--all-systems` (without --no-build) tries to BUILD the
      # darwin and aarch64 checks on this machine too, and dies on
      # "platform mismatch" — verified, not assumed.
      checks = forAllSystems (
        { system, pkgs, ... }:
        self.packages.${system}
        // {
          formatter = self.formatter.${system};

          # Fixture tests for the git-state logic in sync and worktree —
          # drift reporting, fast-forward safety, adoption, tracked-file
          # respect — against a fake workspace of ten tiny repos with
          # local bare origins. Offline by construction, so the build
          # sandbox is a feature: every behaviour tested is pure git
          # state. runCommand attrs become env vars in the script.
          tools-tests = pkgs.runCommand "nixtastic-tools-tests" {
            nativeBuildInputs = [
              pkgs.git
              pkgs.coreutils
              pkgs.jq
            ];
            sync = "${self.packages.${system}.sync}/bin/meshtastic-sync";
            worktree = "${self.packages.${system}.worktree}/bin/meshtastic-worktree";
            brief = "${self.packages.${system}.brief}/bin/meshtastic-brief";
          } (builtins.readFile ./scripts/tools-tests.sh);

          # statix + deadnix over this repo's own tracked files. ${self}
          # is the store copy, which the deny-by-default .gitignore
          # keeps to exactly this repo — the cloned org repos (and their
          # .direnv nixpkgs symlinks) never land there, so the linters
          # cannot wander into other people's code.
          nix-lint =
            pkgs.runCommand "nixtastic-nix-lint"
              {
                nativeBuildInputs = [
                  pkgs.statix
                  pkgs.deadnix
                ];
              }
              ''
                statix check ${self}
                deadnix --fail ${self}
                touch "$out"
              '';
        }
      );

      # `nix fmt` passes the paths to format, and passes NOTHING when run bare.
      # Plain `pkgs.nixfmt` then falls back to stdin, reads an empty stream and
      # dies with `unexpected end of input` — so bare `nix fmt` has never worked
      # here, and nixfmt now warns that the bare invocation is deprecated at all.
      # CI caught it on its first run. Hence the wrapper.
      #
      # `git ls-files` rather than `find`: the ten cloned repos live under this
      # directory and ship their own .nix files (firmware carries a flake), so a
      # bare find would reformat someone else's tracked source. Deny-by-default
      # means this lists exactly the files this repo owns.
      formatter = forAllSystems (
        { pkgs, ... }:
        pkgs.writeShellApplication {
          name = "nixtastic-fmt";
          runtimeInputs = [
            pkgs.nixfmt
            pkgs.git
          ];
          text = ''
            if [ "$#" -gt 0 ]; then
              files=( "$@" )
            else
              mapfile -t files < <(git ls-files '*.nix')
            fi
            if [ "''${#files[@]}" -eq 0 ]; then
              echo "no .nix files to format" >&2
              exit 0
            fi
            nixfmt "''${files[@]}"
          '';
        }
      );
    };
}
