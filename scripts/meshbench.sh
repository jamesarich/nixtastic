# nix run .#meshbench -- [host] - per-bearer mesh delivery on the bench.
#
# Ships mesh-bench-remote.sh to the bench host and runs it there. The measurement
# has to happen where the hardware is: the firmware radio is on that machine's
# USB and the BlueZ adapter node-kmp advertises through is its own. Running it
# from here over ssh keeps one linted copy of the logic in this repo rather than
# a /tmp script on a machine nobody backs up.
set -euo pipefail

host="${1:-${NIXTASTIC_BENCH_HOST:-james-pc.local}}"
shift || true

if [ "$host" = "-h" ] || [ "$host" = "--help" ]; then
    cat <<'USAGE'
usage: meshbench [host] [KEY=VALUE ...]

  host            bench host (default: $NIXTASTIC_BENCH_HOST, else james-pc.local)

  SENDS=10        frames per direction
  GAP=3           seconds between sends
  PORT=/dev/ttyACM2   the firmware radio's serial port on the bench host
  BEARERS=lora,ble-adv,gatt,udp   MESH_TRANSPORTS for the node-kmp node
  GATT_ROLE=CENTRAL_ONLY          MESH_GATT_ROLE
  REGION=US                       MESH_LORA_REGION
  NODE=bench          node-kmp node name

Prints a per-bearer, per-direction delivery matrix, counting decoded messages
rather than frames. One run covers every enabled bearer: node-kmp broadcasts on
all of them and the radio stamps each arrival with its transport, so the outbound
row comes from the radio's log and the inbound row from node-kmp's.

Both directions run in their own phase because a `meshtastic --listen` session
holds the serial port exclusively - the radio cannot be told to transmit while
its own log is captured.
USAGE
    exit 0
fi

remote="${NIXTASTIC_BENCH_REMOTE:?meshbench: remote payload path not set}"

echo "meshbench: $host" >&2
# shellcheck disable=SC2029  # the KEY=VALUE args are meant to expand into the remote env
ssh "$host" "env $* bash -s" <"$remote"
