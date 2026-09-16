# nix run .#meshprobe -- [host] [KEY=VALUE ...] - one bearer's health on the bench.
#
# Ships a locally built node-kmp jar to the bench host, runs a node with a single
# bearer enabled, and prints what that bearer said about itself: every
# availability transition, the rx/tx counters, and each distinct fault.
#
# Complements meshbench, which measures delivery between two nodes. This one
# answers the question delivery cannot: whether a working bearer ever told its
# collectors it was broken. A 735-microsecond Unavailable on a healthy LoRa
# radio is invisible to a delivery matrix and plain in an availability trace.
set -euo pipefail

host="${1:-${NIXTASTIC_BENCH_HOST:-james-pc.local}}"
shift || true

if [ "$host" = "-h" ] || [ "$host" = "--help" ]; then
    cat <<'USAGE'
usage: meshprobe [host] [KEY=VALUE ...]

  host            bench host (default: $NIXTASTIC_BENCH_HOST, else james-pc.local)

  BEARERS=lora    MESH_TRANSPORTS for the node - one bearer keeps the trace readable
  SECONDS=70      how long to run
  JAR=<path>      the jar to ship (default: meshtastic-node-kmp's built nodeJar)
  REGION=US       MESH_LORA_REGION
  GATT_ROLE=CENTRAL_ONLY   MESH_GATT_ROLE
  NODE=probe      node name, which is also its state directory

Build the jar first, from the meshtastic-node-kmp checkout:

  just in meshtastic-node-kmp ~/.claude/bin/gradle-queue -- :node-headless:nodeJar

Exit status is 1 when the bearer reported Unavailable or NeedsPermission at any
point, so this is usable as a gate.
USAGE
    exit 0
fi

BEARERS="lora"
SECONDS_TO_RUN=70
REGION="US"
GATT_ROLE="CENTRAL_ONLY"
NODE="probe"
JAR=""

for arg in "$@"; do
    case "$arg" in
        BEARERS=*) BEARERS="${arg#*=}" ;;
        SECONDS=*) SECONDS_TO_RUN="${arg#*=}" ;;
        REGION=*) REGION="${arg#*=}" ;;
        GATT_ROLE=*) GATT_ROLE="${arg#*=}" ;;
        NODE=*) NODE="${arg#*=}" ;;
        JAR=*) JAR="${arg#*=}" ;;
        *)
            echo "meshprobe: unrecognised argument '$arg'" >&2
            exit 2
            ;;
    esac
done

if [ -z "$JAR" ]; then
    root="${MESHTASTIC_WORKSPACE:-$PWD}"
    JAR="$root/meshtastic-node-kmp/node-headless/build/libs/meshnode-headless.jar"
fi

if [ ! -f "$JAR" ]; then
    echo "meshprobe: no jar at $JAR" >&2
    echo "meshprobe: build it with ':node-headless:nodeJar', or pass JAR=<path>" >&2
    exit 2
fi

# Named for the node, so two probes on one host do not overwrite each other.
remote_jar="/tmp/meshprobe-$NODE.jar"
remote_log="/tmp/meshprobe-$NODE.log"

indent() {
    printf '%s\n' "$1" | while IFS= read -r line; do printf '  %s\n' "$line"; done
}

echo "meshprobe: $BEARERS on $host for ${SECONDS_TO_RUN}s"
scp -q "$JAR" "$host:$remote_jar"

# The JDK the workspace pins: the Nix one SIGSEGVs linking Kotlin/Native, and a
# bench host may have no java on PATH at all.
# shellcheck disable=SC2029  # the settings are built here and meant to expand into the remote env
ssh "$host" \
    "JDK=\$HOME/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2; \
     if [ -x \"\$JDK/bin/java\" ]; then java=\$JDK/bin/java; else java=java; fi; \
     env MESH_TRANSPORTS='$BEARERS' \
         MESH_LORA_REGION='$REGION' \
         MESH_GATT_ROLE='$GATT_ROLE' \
         MESH_PHONE_API_PORT=0 \
         MESH_NODE_NAME='$NODE' \
         timeout '$SECONDS_TO_RUN' \"\$java\" -jar '$remote_jar' > '$remote_log' 2>&1 || true"

# shellcheck disable=SC2029  # the log path is ours, expanded here on purpose
transitions=$(ssh "$host" "grep -oE 'avail\\[[a-z-]+\\] .*' '$remote_log' || true")
# shellcheck disable=SC2029  # the log path is ours, expanded here on purpose
counters=$(ssh "$host" "grep -oE '[a-z-]+ rx=[0-9]+ tx=[0-9]+' '$remote_log' | tail -1 || true")
# shellcheck disable=SC2029  # the log path is ours, expanded here on purpose
faults=$(ssh "$host" "grep -oE 'fault=.*' '$remote_log' | sort | uniq -c | sort -rn || true")

echo
echo "availability"
if [ -z "$transitions" ]; then
    echo "  (none - the bearer never reported, so it was never built)"
else
    indent "$transitions"
fi

echo
echo "counters"
echo "  ${counters:-(none)}"

if [ -n "$faults" ]; then
    echo
    echo "faults"
    indent "$faults"
fi

echo
# Unavailable and NeedsPermission are the two states that tell a collector to
# stop trying, so either one appearing on hardware that works is the finding.
if printf '%s' "$transitions" | grep -q 'Unavailable\|NeedsPermission'; then
    echo "VERDICT: the bearer disclaimed itself at least once - see the trace above"
    exit 1
fi

echo "VERDICT: clean - no Unavailable or NeedsPermission reported"
