# nix run .#blebench -- [host] - measure BLE mesh delivery on the bench.
#
# Ships ble-bench-remote.sh to the bench host and runs it there. The measurement
# has to happen where the hardware is: the firmware radio is on that machine's
# USB and the BlueZ adapter node-kmp advertises through is its own. Running it
# from here over ssh keeps one linted copy of the logic in this repo rather than
# a /tmp script on a machine nobody backs up.
set -euo pipefail

host="${1:-${NIXTASTIC_BENCH_HOST:-james-pc.local}}"
shift || true

if [ "$host" = "-h" ] || [ "$host" = "--help" ]; then
    cat <<'USAGE'
usage: blebench [host] [KEY=VALUE ...]

  host            bench host (default: $NIXTASTIC_BENCH_HOST, else james-pc.local)

  SENDS=10        frames per direction
  GAP=3           seconds between sends
  PORT=/dev/ttyACM2   the firmware radio's serial port on the bench host
  BEARERS=ble-adv     MESH_TRANSPORTS for the node-kmp node
  NODE=bench          node-kmp node name

Prints a per-direction delivery matrix. Both directions are measured in their
own phase because a `meshtastic --listen` session holds the serial port
exclusively - the radio cannot be told to transmit while its own log is captured.
USAGE
    exit 0
fi

remote="${NIXTASTIC_BENCH_REMOTE:?blebench: remote payload path not set}"

echo "blebench: $host" >&2
# shellcheck disable=SC2029  # the KEY=VALUE args are meant to expand into the remote env
ssh "$host" "env $* bash -s" <"$remote"
