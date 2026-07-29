{
  description = "Meshtastic workspace — dev shells for the Meshtastic org repos (firmware, apps, Kotlin libraries, MCP tooling)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # x86_64-darwin is absent on purpose: nixpkgs 26.11 dropped Intel
      # macOS support outright (it throws on eval). Apple-silicon only.
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
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
        # Shared .proto definitions. Also vendored as a submodule inside
        # firmware/protobufs — edit here, bump the pointer there.
        protobufs = { shell = "protobufs"; repo = "meshtastic/protobufs"; };
        # Cross-platform design standards, tokens and brand assets. Work here
        # is driven mostly through the org design board, not the repo:
        # https://github.com/orgs/meshtastic/projects/16
        design = { shell = "design"; repo = "meshtastic/design"; };
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
          toolchainPaths = lib.concatStringsSep ","
            (map (j: j.home or "${j}") jdks);

          jvmTools = with pkgs; [
            primaryJdk
            ktlint
            kotlin-language-server
          ] ++ jdks;

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

          #########################################################
          # Google's android CLI — the agent-oriented front end over
          # adb / sdkmanager / avdmanager / AGP.
          #
          # Used ONLY to bootstrap an SDK from nothing — deliberately not
          # in any dev shell. Two reasons:
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
          # Upstream ships x86_64-linux and aarch64-darwin only.
          #########################################################
          androidCli = lib.optional
            (lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.android-cli)
            pkgs.android-cli;

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
          kotlin = pkgs.mkShellNoCC {
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
            # No android-tools here: androidHook puts the SDK's own
            # platform-tools first on PATH, so a Nix adb would just be a
            # shadowed duplicate — and adb must match the SDK anyway.
            packages = common ++ jvmTools
              ++ lib.optionals isLinux [ pkgs.scrcpy ];
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
            shellHook = serialHook + pythonHook + (banner "firmware" "firmware — default env: heltec-v3") + ''
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
          mcp = pkgs.mkShellNoCC {
            name = "meshtastic-mcp";
            # The android CLI comes from $ANDROID_HOME/cmdline-tools
            # (androidHook puts it on PATH) — this repo's hardware-free
            # e2e drives an emulator via `android emulator` / `android
            # layout` rather than hand-rolled avdmanager/adb calls.
            packages = common ++ nodeTools ++ [
              python
              pkgs.uv
              pkgs.nodejs_22
              pkgs.ruff
            ];
            shellHook = serialHook + androidHook + pythonHook
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
          apple = pkgs.mkShellNoCC {
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
            packages = common ++ jvmTools ++ (with pkgs; [
              buf
              nanopb
              deno
              nodejs_22
              cargo
              rustc
            ]);
            shellHook = jvmHook
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
            packages = common ++ [ pkgs.nodejs_22 ]
              ++ lib.optionals isLinux [ pkgs.inkscape ];
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
            packages = common ++ nodeTools ++ [ python pkgs.uv ];
            shellHook = serialHook + pythonHook + (banner "nodes" "serial · BLE · flashing") + ''
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
          # Same guard as the devShells use — upstream ships android-cli
          # for x86_64-linux and aarch64-darwin only.
          androidCli = nixpkgs.lib.optional
            (nixpkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.android-cli)
            pkgs.android-cli;

          entries = nixpkgs.lib.mapAttrsToList
            (dir: v: "${dir}\t${v.repo}\t${v.shell}")
            self.workspace;
          sync = pkgs.writeShellApplication {
            name = "meshtastic-sync";
            runtimeInputs = [ pkgs.git ];
            text = ''
              # Modes:
              #   (default)  clone anything missing, fetch, report status.
              #              Never modifies a working tree.
              #   --pull     additionally FAST-FORWARD branches that can be
              #              fast-forwarded. Never merges, never rebases,
              #              never touches a dirty or diverged repo.
              #
              # The conservatism is deliberate: these repos routinely sit on
              # feature branches with work in progress, and a blanket
              # `git pull` would either create merge commits or fail dirty.
              #   --main     switch each repo to its DEFAULT branch first,
              #              then pull. Implies --pull. Refuses to switch a
              #              repo whose tracked files are modified.
              pull=false
              main=false
              for arg in "$@"; do
                case "$arg" in
                  --pull) pull=true ;;
                  --main) main=true; pull=true ;;
                  *) echo "unknown option: $arg" ; exit 1 ;;
                esac
              done

              root="''${MESHTASTIC_WORKSPACE:-$PWD}"
              if [ "$main" = true ]; then mode="  (--main)"
              elif [ "$pull" = true ]; then mode="  (--pull)"
              else mode=""; fi
              echo "workspace: $root$mode"
              echo ""

              printf '%s\n' ${nixpkgs.lib.escapeShellArgs entries} |
              while IFS=$'\t' read -r dir repo shell; do
                if [ ! -d "$root/$dir/.git" ]; then
                  echo "  clone     $dir  <- $repo"
                  git clone --quiet "https://github.com/$repo.git" "$root/$dir"
                  continue
                fi

                g="git -C $root/$dir"

                # A --single-branch clone narrows remote.origin.fetch to a
                # single ref, so `git fetch` can NEVER see any other
                # branch and drift on them is invisible. Detect it, and
                # widen under --pull (this is just the normal clone
                # default; nothing is discarded).
                narrow=false
                case "$($g config --get-all remote.origin.fetch | tr '\n' ' ')" in
                  *"refs/heads/*"*) ;;
                  *) narrow=true ;;
                esac
                if [ "$narrow" = true ] && [ "$pull" = true ]; then
                  $g config --replace-all remote.origin.fetch \
                    '+refs/heads/*:refs/remotes/origin/*'
                  narrow=false
                fi

                # Fetch is always safe — it only writes remote-tracking refs.
                $g fetch --quiet --prune --tags origin 2>/dev/null || true

                # --main moves to the repo's DEFAULT branch. NOT hardcoded
                # to "main": meshtastic-mcp's default is master. Resolved
                # from origin/HEAD, repairing it via `remote set-head` if
                # the clone never recorded one.
                switched=""
                if [ "$main" = true ]; then
                  if ! ref=$($g symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
                    $g remote set-head origin --auto >/dev/null 2>&1 || true
                    ref=$($g symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
                  fi
                  def="''${ref#refs/remotes/origin/}"
                  cur=$($g rev-parse --abbrev-ref HEAD)
                  if [ -n "$def" ] && [ "$def" != "$cur" ]; then
                    # Switching a dirty tree would drag the modifications
                    # onto the default branch. Leave it exactly where it is.
                    if [ "$($g status --porcelain --untracked-files=no | wc -l)" -gt 0 ]; then
                      switched="STAYED on $cur (tree dirty)"
                    elif $g rev-parse --verify --quiet "refs/heads/$def" >/dev/null 2>&1; then
                      $g checkout --quiet "$def" && switched="$cur -> $def"
                    else
                      $g checkout --quiet -b "$def" --track "origin/$def" \
                        && switched="$cur -> $def (new local branch)"
                    fi
                  fi
                fi

                branch=$($g rev-parse --abbrev-ref HEAD)
                # Only TRACKED modifications can block a fast-forward.
                # Untracked files cannot (git merge --ff-only happily
                # ignores them), so counting them as "dirty" would
                # needlessly skip repos — e.g. meshtastic-mcp, held back
                # by nothing but an untracked .remember/ directory.
                dirty=$($g status --porcelain --untracked-files=no | wc -l)
                untracked=$($g ls-files --others --exclude-standard | wc -l)

                # Missing tracking config does NOT mean missing remote
                # branch. Checking out a fetched ref, or pushing without
                # -u, leaves a branch with no upstream that nonetheless
                # exists on origin. Treating that as "nothing to compare"
                # silently hides real drift, so fall back to
                # origin/<branch> before giving up.
                tracked=true
                if ! upstream=$($g rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
                  if $g rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
                    upstream="origin/$branch"
                    tracked=false
                  else
                    if [ "$narrow" = true ]; then
                      why="not fetched (single-branch clone; --pull widens it)"
                    else
                      why="not on origin"
                    fi
                    printf '  local     %-24s %-30s %-10s %s\n' \
                      "$dir" "$branch" ".#$shell" "$why"
                    continue
                  fi
                fi

                # left = commits upstream has that we lack (behind)
                # right = commits we have that upstream lacks (ahead)
                counts=$($g rev-list --left-right --count "$upstream...HEAD")
                behind=$(echo "$counts" | cut -f1)
                ahead=$(echo "$counts" | cut -f2)

                # flags describe the working tree; drift describes the
                # branch. Keep them separate so a drift message can never
                # swallow the fact that the tree is dirty.
                flags=""
                [ -n "$switched" ] && flags="$switched"
                [ "$narrow" = true ] && flags="''${flags}''${flags:+, }single-branch clone"
                [ "$tracked" = false ] && flags="''${flags}''${flags:+, }no tracking"
                [ "$dirty" -gt 0 ] && flags="''${flags}''${flags:+, }$dirty dirty"
                [ "$untracked" -gt 0 ] && flags="''${flags}''${flags:+, }$untracked untracked"

                if [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ]; then
                  status="current"; drift=""
                elif [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
                  status="DIVERGED"; drift="+$ahead/-$behind"
                elif [ "$ahead" -gt 0 ]; then
                  status="ahead"; drift="+$ahead"
                elif [ "$dirty" -gt 0 ]; then
                  status="BEHIND"; drift="-$behind skipped, tree dirty"
                elif [ "$pull" = true ]; then
                  # Repair tracking config while we are here; harmless and
                  # reversible with `git branch --unset-upstream`.
                  [ "$tracked" = false ] && \
                    $g branch --quiet --set-upstream-to="$upstream" "$branch" >/dev/null 2>&1
                  if $g merge --ff-only --quiet "$upstream" 2>/dev/null; then
                    status="PULLED"; drift="-$behind fast-forwarded"
                    # A fast-forward can move recorded submodule pointers.
                    # Without re-syncing, the tree reads dirty again the
                    # instant the pull finishes — firmware/protobufs does
                    # this every time upstream bumps the proto pointer.
                    if [ -f "$root/$dir/.gitmodules" ]; then
                      $g submodule update --init --recursive --quiet 2>/dev/null || true
                      drift="$drift +submodules"
                    fi
                  else
                    status="FAILED"; drift="-$behind ff refused"
                  fi
                else
                  status="behind"; drift="-$behind (run with --pull)"
                fi

                printf '  %-9s %-24s %-30s %-10s %s\n' \
                  "$status" "$dir" "$branch" ".#$shell" \
                  "$drift''${drift:+''${flags:+  }}$flags"
              done

              echo ""
              if [ "$pull" = true ]; then
                echo "  fast-forwarded where safe; dirty/diverged repos untouched"
              else
                echo "  read-only. re-run to act:"
                echo "      nix run .#sync -- --pull    fast-forward current branches"
                echo "      nix run .#sync -- --main    switch to default branch, then pull"
              fi
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
          # nix run .#brief <repo> — orient before touching a repo.
          #
          # Generated live rather than written down, so it cannot go stale the
          # way a hand-maintained index does. Its job is to say WHAT TO READ,
          # not to inline it: per-repo agent docs total ~66 KB and must not all
          # be loaded.
          brief = pkgs.writeShellApplication {
            name = "meshtastic-brief";
            runtimeInputs = [ pkgs.git pkgs.coreutils pkgs.gh ];
            text = ''
              root="''${MESHTASTIC_WORKSPACE:-$PWD}"
              dir="''${1:-}"
              if [ -z "$dir" ]; then
                echo "usage: nix run .#brief <repo>"
                echo ""
                echo "repos:"
                printf '%s\n' ${nixpkgs.lib.escapeShellArgs entries} |
                  while IFS=$'\t' read -r d _ s; do printf '  %-24s %s\n' "$d" ".#$s"; done
                exit 0
              fi

              shell=""
              while IFS=$'\t' read -r d _ s; do
                [ "$d" = "$dir" ] && shell="$s"
              done <<< "$(printf '%s\n' ${nixpkgs.lib.escapeShellArgs entries})"

              [ -n "$shell" ] || { echo "unknown repo: $dir"; exit 1; }
              p="$root/$dir"
              [ -d "$p/.git" ] || { echo "$dir not cloned — run: nix run .#sync"; exit 1; }
              g="git -C $p"

              echo ""
              echo "  $dir"
              echo "  ────────────────────────────────────────────────────"
              printf '  shell        nix develop .#%s\n' "$shell"

              branch=$($g rev-parse --abbrev-ref HEAD)
              def=""
              if r=$($g symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
                def="''${r#refs/remotes/origin/}"
              fi
              printf '  branch       %s' "$branch"
              [ -n "$def" ] && [ "$branch" != "$def" ] && printf '   (default: %s)' "$def"
              echo ""

              if u=$($g rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
                c=$($g rev-list --left-right --count "$u...HEAD" 2>/dev/null || echo "0	0")
                printf '  drift        -%s / +%s vs %s\n' "$(echo "$c" | cut -f1)" "$(echo "$c" | cut -f2)" "$u"
              fi
              d=$($g status --porcelain --untracked-files=no | wc -l)
              [ "$d" -gt 0 ] && printf '  tree         %s tracked file(s) modified\n' "$d"

              echo ""
              echo "  READ BEFORE EDITING (in precedence order)"
              any=false
              for f in .specify/memory/constitution.md AGENTS.md CLAUDE.md CONTRIBUTING.md GOVERNANCE.md CODEOWNERS CONVENTIONS.md llms.txt; do
                if [ -f "$p/$f" ]; then
                  printf '    %-42s %6s\n' "$dir/$f" "$(( $(wc -c <"$p/$f") ))b"
                  any=true
                fi
              done
              if [ -f "$root/notes/$dir.md" ]; then
                printf '    %-42s %6s  (workspace-local)\n' "notes/$dir.md" "$(( $(wc -c <"$root/notes/$dir.md") ))b"
                any=true
              fi
              [ "$any" = false ] && echo "    (none found — read the code)"

              # Spec Kit repos run a lifecycle; ad-hoc edits are the wrong shape.
              if [ -d "$p/.specify" ]; then
                echo ""
                echo "  SPEC KIT — work flows through the spec lifecycle"
                [ -f "$p/.specify/memory/constitution.md" ] && \
                  echo "    constitution outranks other agent docs"
                if [ -d "$p/specs" ]; then
                  printf '    %s spec(s); most recent:\n' "$(find "$p/specs" -maxdepth 1 -mindepth 1 -type d | wc -l)"
                  find "$p/specs" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null \
                    | sort | tail -3 | sed 's/^/      /'
                fi
              fi

              for k in skills agents commands; do
                if [ -d "$p/.claude/$k" ]; then
                  printf '\n  .claude/%s\n' "$k"
                  find "$p/.claude/$k" -maxdepth 1 -mindepth 1 -printf '    %f\n' 2>/dev/null | sort | head -12
                fi
              done

              echo ""
              echo "  COMMIT STYLE (last 5 on this branch — match it)"
              $g log --oneline -5 --format='    %s' | cut -c1-74

              if command -v gh >/dev/null; then
                echo ""
                echo "  OPEN PRs"
                gh pr list --repo "meshtastic/$( $g remote get-url origin | sed 's|.*/||; s|\.git$||' )" \
                  --limit 5 --json number,title \
                  --template '{{range .}}    #{{.number}} {{.title}}{{"\n"}}{{end}}' 2>/dev/null \
                  || echo "    (unavailable)"
              fi

              echo ""
              if [ -d "$p/.claude/worktrees" ]; then
                n=$(find "$p/.claude/worktrees" -maxdepth 1 -mindepth 1 -type d | wc -l)
                [ "$n" -gt 0 ] && printf '  %s active worktree(s) — nix run .#worktree --list %s\n\n' "$n" "$dir"
              fi
            '';
          };

          # nix run .#worktree — worktrees that carry the right dev shell.
          #
          # A worktree inherits only the workspace-root .envrc, which selects
          # the DEFAULT shell. Working android in a bare worktree therefore
          # gets you no scrcpy and the host's android-cli instead of the
          # pinned one. Writing a per-worktree .envrc fixes that.
          #
          # Ignoring is done via .git/info/exclude (local, never committed)
          # because only `android` gitignores .claude/worktrees — editing a
          # tracked .gitignore in someone else's repo is not ours to do.
          worktree = pkgs.writeShellApplication {
            name = "meshtastic-worktree";
            runtimeInputs = [ pkgs.git pkgs.coreutils ];
            text = ''
              root="''${MESHTASTIC_WORKSPACE:-$PWD}"
              usage() {
                echo "usage:"
                echo "  nix run .#worktree -- <repo> <branch> [name]   create"
                echo "  nix run .#worktree -- --list [repo]            list"
                echo "  nix run .#worktree -- --prune [repo]           drop dead registrations"
              }

              repo_shell() {
                while IFS=$'\t' read -r d _ s; do
                  [ "$d" = "$1" ] && { echo "$s"; return; }
                done <<< "$(printf '%s\n' ${nixpkgs.lib.escapeShellArgs entries})"
              }
              all_repos() {
                printf '%s\n' ${nixpkgs.lib.escapeShellArgs entries} | while IFS=$'\t' read -r d _ _; do echo "$d"; done
              }

              # Explicit if/else rather than `A && B || C`: with the latter,
              # C also runs when A succeeds but B fails.
              targets() {
                if [ -n "''${1:-}" ]; then echo "$1"; else all_repos; fi
              }

              case "''${1:-}" in
                ""|-h|--help) usage; exit 0 ;;
                --list)
                  while read -r d; do
                    [ -d "$root/$d/.git" ] || continue
                    out=$(git -C "$root/$d" worktree list | tail -n +2)
                    if [ -n "$out" ]; then
                      echo "  $d:"
                      while IFS= read -r line; do printf '      %s\n' "$line"; done <<< "$out"
                    fi
                  done <<< "$(targets "''${2:-}")"
                  exit 0 ;;
                --prune)
                  while read -r d; do
                    [ -d "$root/$d/.git" ] || continue
                    n=$(git -C "$root/$d" worktree prune --dry-run 2>/dev/null | wc -l)
                    if [ "$n" -gt 0 ]; then
                      git -C "$root/$d" worktree prune
                      echo "  $d: pruned $n dead registration(s)"
                    fi
                  done <<< "$(targets "''${2:-}")"
                  exit 0 ;;
              esac

              dir="$1"; branch="''${2:-}"; name="''${3:-$(echo "$branch" | tr '/' '-')}"
              [ -n "$branch" ] || { usage; exit 1; }
              shell=$(repo_shell "$dir")
              [ -n "$shell" ] || { echo "unknown repo: $dir"; exit 1; }
              p="$root/$dir"
              [ -d "$p/.git" ] || { echo "$dir not cloned"; exit 1; }

              wt="$p/.claude/worktrees/$name"
              [ -e "$wt" ] && { echo "already exists: $wt"; exit 1; }

              # Keep the host repo's tracked files untouched.
              ex="$(git -C "$p" rev-parse --git-common-dir)/info/exclude"
              for pat in '.claude/worktrees/' '.envrc' '.direnv/'; do
                grep -qxF "$pat" "$ex" 2>/dev/null || echo "$pat" >> "$ex"
              done

              git -C "$p" fetch --quiet origin 2>/dev/null || true
              if git -C "$p" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
                git -C "$p" worktree add --quiet "$wt" "$branch"
              elif git -C "$p" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
                git -C "$p" worktree add --quiet --track -b "$branch" "$wt" "origin/$branch"
              else
                git -C "$p" worktree add --quiet -b "$branch" "$wt"
              fi

              cat > "$wt/.envrc" <<EOF
              # Generated by: nix run .#worktree
              # Selects $dir's shell explicitly. Without this the worktree would
              # inherit the workspace-root .envrc and get the DEFAULT shell.
              export MESHTASTIC_WORKSPACE="$root"
              use flake "$root#$shell"
              EOF

              echo "  created  $wt"
              echo "  branch   $branch"
              echo "  shell    .#$shell"
              echo ""
              echo "  cd $wt && direnv allow"
              echo "  nix run .#brief -- $dir"
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
          brief = { type = "app"; program = "${brief}/bin/meshtastic-brief"; };
          worktree = { type = "app"; program = "${worktree}/bin/meshtastic-worktree"; };
        });

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixpkgs-fmt);
    };
}
