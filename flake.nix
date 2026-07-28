{
  description = "Meshtastic workspace — dev shells for the Meshtastic org repos (firmware, apps, Kotlin libraries, MCP tooling)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = import nixpkgs {
          inherit system;
          # Google ships android-cli as an unfree prebuilt binary. Allow
          # that one package rather than opening up allowUnfree wholesale.
          config.allowUnfreePredicate = p:
            builtins.elem (nixpkgs.lib.getName p) [ "android-cli" ];
        };
      });
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
        firmware = { shell = "firmware"; repo = "meshtastic/firmware"; };
        android = { shell = "android"; repo = "meshtastic/Meshtastic-Android"; };
        apple = { shell = "apple"; repo = "meshtastic/Meshtastic-Apple"; };
        meshtastic-sdk = { shell = "kotlin"; repo = "meshtastic/meshtastic-sdk"; };
        MQTTastic-Client-KMP = { shell = "kotlin"; repo = "meshtastic/MQTTastic-Client-KMP"; };
        kzstd = { shell = "kotlin"; repo = "meshtastic/kzstd"; };
        gradle-flatpak-sources = { shell = "kotlin"; repo = "meshtastic/gradle-flatpak-sources"; };
        meshtastic-mcp = { shell = "mcp"; repo = "meshtastic/meshtastic-mcp"; };
      };

      devShells = forAllSystems ({ pkgs, system }:
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
          jdks = [ pkgs.jdk21 pkgs.jdk17 pkgs.temurin-bin-11 ];
          primaryJdk = pkgs.jdk21;
          # .home, not the derivation root — on Darwin they differ, and
          # Gradle's toolchain resolver wants a real JAVA_HOME layout.
          toolchainPaths = lib.concatStringsSep "," (map (j: j.home) jdks);

          jvmTools = with pkgs; [
            primaryJdk
            ktlint
            kotlin-language-server
          ] ++ jdks;

          jvmHook = ''
            export JAVA_HOME="${primaryJdk.home}"
            export GRADLE_OPTS="''${GRADLE_OPTS:-} \
              -Dorg.gradle.java.installations.auto-detect=false \
              -Dorg.gradle.java.installations.auto-download=false \
              -Dorg.gradle.java.installations.paths=${toolchainPaths}"

            # Gradle's cache lives under the workspace when MESHTASTIC_WORKSPACE
            # is set (self-contained, disposable), else the usual ~/.gradle.
            # Note: it must NOT be derived from ./. — inside a flake that
            # evaluates to the read-only /nix/store copy of this file.
            if [ -n "''${MESHTASTIC_WORKSPACE:-}" ]; then
              export GRADLE_USER_HOME="''${GRADLE_USER_HOME:-$MESHTASTIC_WORKSPACE/.cache/gradle}"
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

          #########################################################
          # Google's android CLI — the agent-oriented front end over
          # adb / sdkmanager / avdmanager / AGP.
          #
          # Pinning it through Nix is the whole point: the standalone
          # install self-updates via `android update`, which quietly
          # drifts the toolchain. From /nix/store it can't, so the
          # version moves only when you bump the flake lock.
          #
          # Upstream ships x86_64-linux and aarch64-darwin only.
          #########################################################
          androidCli = lib.optional
            (lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.android-cli)
            pkgs.android-cli;

          #########################################################
          # Python (meshtastic-mcp, firmware build scripts, node CLI)
          #########################################################
          python = pkgs.python313;

          #########################################################
          # Talking to physical nodes over serial / BLE.
          #########################################################
          nodeTools = with pkgs; [
            esptool
            picocom
            usbutils
          ] ++ lib.optionals isLinux [
            android-tools # adb, for the Android app + MCP emulator e2e
            bluez
          ];

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
        in
        {
          #########################################################
          # default — everything light, for roaming the workspace
          #########################################################
          default = pkgs.mkShell {
            name = "meshtastic";
            packages = common ++ jvmTools ++ nodeTools ++ [ python pkgs.uv pkgs.nodejs_22 ];
            shellHook = jvmHook + androidHook + serialHook
              + (banner "workspace" "all toolchains — use a focused shell for real work")
              + ''
                echo "  .#kotlin    meshtastic-sdk · MQTTastic-Client-KMP · kzstd · gradle-flatpak-sources"
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
          kotlin = pkgs.mkShell {
            name = "meshtastic-kotlin";
            packages = common ++ jvmTools
              # gradle-flatpak-sources emits Flathub offline manifests;
              # flatpak-builder is what you check its output against.
              ++ lib.optionals isLinux [ pkgs.flatpak-builder ];
            shellHook = jvmHook + androidHook
              + (banner "kotlin" "meshtastic-sdk · MQTTastic-Client-KMP · kzstd · gradle-flatpak-sources")
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
            packages = common ++ jvmTools ++ androidCli
              ++ lib.optionals isLinux [ pkgs.android-tools pkgs.scrcpy ];
            shellHook = jvmHook + androidHook
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
          #########################################################
          firmware = pkgs.mkShell {
            name = "meshtastic-firmware";
            packages = common ++ nodeTools ++ (with pkgs; [
              platformio
              python
              ccache
              cmake
              ninja
            ]);
            shellHook = serialHook + (banner "firmware" "firmware — default env: heltec-v3") + ''
              export PLATFORMIO_CORE_DIR="''${PLATFORMIO_CORE_DIR:-$HOME/.platformio}"
              echo "  pio run -e heltec-v3"
              echo "  pio run -e heltec-v3 -t upload"
              echo "  pio device monitor"
              echo ""
            '';
          };

          #########################################################
          # mcp — Python server + Node web-ui
          #########################################################
          mcp = pkgs.mkShell {
            name = "meshtastic-mcp";
            # android-cli here too: this repo's hardware-free e2e drives
            # an emulator, and `android emulator` + `android layout`
            # cover that without hand-rolling avdmanager/adb calls.
            packages = common ++ nodeTools ++ androidCli ++ [
              python
              pkgs.uv
              pkgs.nodejs_22
              pkgs.ruff
            ];
            shellHook = serialHook + androidHook
              + (banner "mcp" "meshtastic-mcp — Python >=3.11, uv.lock") + ''
              # Let uv build venvs against the Nix interpreter rather than
              # downloading its own CPython.
              export UV_PYTHON="${python}/bin/python3"
              export UV_PYTHON_DOWNLOADS=never
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
          apple = pkgs.mkShell {
            name = "meshtastic-apple";
            packages = common ++ lib.optionals pkgs.stdenv.isDarwin (with pkgs; [
              swiftlint
              swift-format
              xcbeautify
            ]);
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
          # nodes — no build toolchain, just talk to hardware
          #########################################################
          nodes = pkgs.mkShell {
            name = "meshtastic-nodes";
            packages = common ++ nodeTools ++ [ python pkgs.uv ];
            shellHook = serialHook + (banner "nodes" "serial · BLE · flashing") + ''
              export UV_PYTHON="${python}/bin/python3"
              echo "  uvx meshtastic --info"
              echo "  uvx meshtastic --port /dev/ttyUSB0 --nodes"
              echo "  esptool.py chip_id"
              echo ""
            '';
          };
        });

      #############################################################
      # nix run .#sync — clone any missing workspace repo, then
      # report the state of each one. Safe to re-run; it never
      # touches a repo that already exists beyond reading its status.
      #############################################################
      apps = forAllSystems ({ pkgs, system }:
        let
          entries = nixpkgs.lib.mapAttrsToList
            (dir: v: "${dir}\t${v.repo}\t${v.shell}")
            self.workspace;
          sync = pkgs.writeShellApplication {
            name = "meshtastic-sync";
            runtimeInputs = [ pkgs.git ];
            text = ''
              root="''${MESHTASTIC_WORKSPACE:-$PWD}"
              echo "workspace: $root"
              echo ""
              printf '%s\n' ${nixpkgs.lib.escapeShellArgs entries} |
              while IFS=$'\t' read -r dir repo shell; do
                if [ ! -d "$root/$dir/.git" ]; then
                  echo "  clone   $dir  <- $repo"
                  git clone --quiet "https://github.com/$repo.git" "$root/$dir"
                else
                  branch=$(git -C "$root/$dir" rev-parse --abbrev-ref HEAD)
                  dirty=$(git -C "$root/$dir" status --porcelain | wc -l)
                  if [ "$dirty" -gt 0 ]; then state="($dirty dirty)"; else state=""; fi
                  printf '  ok      %-24s %-18s %-10s %s\n' \
                    "$dir" "$branch" ".#$shell" "$state"
                fi
              done
              echo ""
              echo "  enter a shell with:  nix develop .#<shell>"
            '';
          };
        in
        let
          # nix run .#bootstrap-sdk — reconcile $ANDROID_HOME against
          # android-sdk-packages.txt. This is the portability answer for
          # the one thing Nix isn't managing: the SDK stays writable
          # (so AGP is happy) but its contents are declared in a file.
          bootstrapSdk = pkgs.writeShellApplication {
            name = "meshtastic-bootstrap-sdk";
            runtimeInputs = [ pkgs.jdk21 pkgs.coreutils ] ++ androidCli;
            text = ''
              root="''${MESHTASTIC_WORKSPACE:-$PWD}"
              sdk="''${ANDROID_HOME:-$HOME/Android/Sdk}"
              list="$root/android-sdk-packages.txt"

              [ -f "$list" ] || { echo "missing $list"; exit 1; }

              if ! command -v android >/dev/null; then
                echo "android CLI unavailable on this platform"
                echo "(nixpkgs ships it for x86_64-linux and aarch64-darwin only)"
                echo "Fall back to: sdkmanager --sdk_root=$sdk --install ..."
                exit 1
              fi

              # sdkmanager underneath android-cli still needs a JDK; take
              # it from Nix rather than whatever is on the host PATH.
              export JAVA_HOME="${pkgs.jdk21.home}"

              want=()
              while read -r line; do
                case "$line" in ""|\#*) continue ;; esac
                want+=("$line")
              done < "$list"

              echo "sdk:      $sdk"
              echo "cli:      $(android --version)"
              echo "packages: ''${#want[@]} declared in $list"
              echo ""
              android --sdk="$sdk" sdk install "''${want[@]}"
              echo ""
              android --sdk="$sdk" sdk list
            '';
          };
        in
        {
          sync = { type = "app"; program = "${sync}/bin/meshtastic-sync"; };
          default = { type = "app"; program = "${sync}/bin/meshtastic-sync"; };
          bootstrap-sdk = {
            type = "app";
            program = "${bootstrapSdk}/bin/meshtastic-bootstrap-sdk";
          };
        });

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixpkgs-fmt);
    };
}
