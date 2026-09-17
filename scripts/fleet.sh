# nix run .#fleet - what the bench is made of right now, and whether it is current.
#
# Every probe here is one a session got wrong by hand. The CH341 LoRa stick does
# not appear in /dev/serial/by-id, because in EPP/MEM/I2C mode it is an SPI
# bridge and creates no tty; looking there once had it recorded as unplugged. And
# a node-kmp jar whose hash matches on every host says the hosts agree, not that
# any of them is current - that cost two measurements, so the build stamp is
# compared against the repo's own HEAD. The Apple side is here because a fleet
# view that omits the iPad is how it got written off as unreachable for a day.
set -uo pipefail

hosts="${NIXTASTIC_FLEET_HOSTS:-james-pc.local james@192.168.1.23}"
root="${MESHTASTIC_WORKSPACE:-$PWD}"
jar_path="/tmp/meshnode-refactor.jar"

head_sha=""
if [ -d "$root/meshtastic-node-kmp/.git" ]; then
    head_sha=$(git -C "$root/meshtastic-node-kmp" rev-parse --short=12 HEAD 2>/dev/null || echo "")
fi
printf 'node-kmp HEAD %s\n\n' "${head_sha:-unknown}"

for host in $hosts; do
    printf '=== %s ===\n' "$host"
    if ! out=$(timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" \
        "bash -s -- '$jar_path'" <<'REMOTE' 2>/dev/null
        jar="$1"
        echo "HOST $(hostname)"
        if [ -f "$jar" ]; then
            echo "JAR $(unzip -p "$jar" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' | sed -n 's/^Mesh-Build: //p')"
        else
            echo "JAR none"
        fi
        for p in /dev/serial/by-id/*; do
            [ -e "$p" ] || continue
            echo "TTY $(basename "$p")"
        done
        # Not /dev/serial/by-id: in EPP/MEM/I2C mode the CH341 is an SPI bridge and creates no tty.
        # By device, not by vendor: 1a86 is QinHeng, who also make the USB hub on the uConsole.
        echo "LORA $(lsusb 2>/dev/null | grep -i 'ch341' | sed -n 's/.*ID \([0-9a-f:]*\).*/\1/p' | head -1)"
        bluetoothctl list 2>/dev/null | sed -n 's/^Controller /BT /p'
REMOTE
    ); then
        printf '  unreachable\n\n'
        continue
    fi

    jar=$(printf '%s\n' "$out" | sed -n 's/^JAR //p')
    case "$jar" in
        none) printf '  node-kmp   no jar at %s\n' "$jar_path" ;;
        *-dirty) printf '  node-kmp   %s  UNCOMMITTED - rebuild from a clean tree\n' "$jar" ;;
        "$head_sha") printf '  node-kmp   %s  matches HEAD\n' "$jar" ;;
        *) printf '  node-kmp   %s  BEHIND HEAD (%s)\n' "$jar" "${head_sha:-unknown}" ;;
    esac

    printf '%s\n' "$out" | sed -n 's/^TTY /  radio      /p'
    lora=$(printf '%s\n' "$out" | sed -n 's/^LORA //p')
    if [ -n "$lora" ]; then printf '  lora       ch341 %s\n' "$lora"; else printf '  lora       no ch341\n'; fi
    printf '%s\n' "$out" | sed -n 's/^BT /  bluetooth  /p'
    printf '\n'
done

# The Apple devices are not ssh hosts, so they need their own probe: devicectl for
# the iPad, and the framework Gradle last linked for what an install would carry.
if [ "$(uname -s)" = "Darwin" ]; then
    printf '=== this Mac (Apple bench) ===\n'

    # Every Apple tool needs the Nix environment stripped or xcrun reports Xcode missing.
    apple() {
        env -u DEVELOPER_DIR -u SDKROOT -u CC -u CXX -u LD -u AR -u NM -u RANLIB -u STRIP \
            -u NIX_CC PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$@"
    }

    devices=$(apple xcrun devicectl list devices 2>/dev/null | tail -n +3 | grep -v '^[[:space:]]*$' || true)
    if [ -n "$devices" ]; then
        printf '%s\n' "$devices" | while IFS= read -r line; do
            name=$(printf '%s' "$line" | awk '{print $1, $2}')
            state=$(printf '%s' "$line" | grep -oE 'available \(paired\)|unavailable|connecting' | head -1)
            printf '  device     %s  %s\n' "$name" "${state:-unknown}"
        done
    else
        printf '  device     none paired\n'
    fi

    fw="$root/meshtastic-node-kmp/monitor/build/bin/iosArm64/debugFramework/Monitor.framework"
    if [ -d "$fw" ]; then
        printf '  framework  linked %s\n' "$(date -r "$fw" '+%Y-%m-%d %H:%M' 2>/dev/null)"
    else
        printf '  framework  not linked - run: nix run .#iosdeploy\n'
    fi

    # Local Network is denied under herdr, so a LAN bearer cannot be exercised from here.
    if timeout 5 python3 -c "import socket;socket.socket(socket.AF_INET,socket.SOCK_DGRAM).sendto(b'x',('192.168.1.1',53))" 2>/dev/null; then
        printf '  lan        reachable\n'
    else
        printf '  lan        DENIED - macOS Local Network; run LAN work outside herdr\n'
    fi
    printf '\n'
fi
