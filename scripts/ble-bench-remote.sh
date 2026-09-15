#!/usr/bin/env bash
# BLE mesh bench harness: per-direction delivery between a firmware radio and a
# node-kmp headless node sharing one bench.
#
# Phased on purpose. A `meshtastic --listen` session holds the serial port
# exclusively, so the radio cannot be told to transmit while its own log is being
# captured - the first version of this measured 0% in that direction and the
# radio had simply never been asked to send. Each direction therefore owns the
# port for its phase, and only the direction that needs the device log takes one.
set -uo pipefail

PORT="${PORT:-/dev/ttyACM2}"
KMP="${KMP:-$HOME/meshtastic/meshtastic-node-kmp}"
SENDS="${SENDS:-10}"
GAP="${GAP:-3}"
BEARERS="${BEARERS:-ble-adv}"
RUN="/tmp/blebench-$$"
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$RUN"

# Kill by PID from a pattern that cannot match this script's own argv. `pkill -f`
# is a foot-gun here: the pattern appears in the caller's command line, so it
# reaps the caller.
reap() {
  ps -eo pid,args | awk -v w="$1" '$0 ~ w && !/awk/ {print $1}' | while read -r p; do
    [ "$p" = "$$" ] && continue
    kill "$p" 2>/dev/null
  done
}
teardown() { reap 'meshtastic .*--listen'; reap 'meshnode-headless'; sleep 2; }

# grep -c prints 0 AND exits 1 when there are no matches, so `|| echo 0` yields
# two lines and poisons the arithmetic that consumes it.
count() { grep -c "$1" "$2" 2>/dev/null | head -1; }
ids() { grep -oE 'BLE mesh RX [^"\\]*id=0x[0-9a-f]+' "$1" 2>/dev/null | grep -oE 'id=0x[0-9a-f]+' | sort -u | wc -l; }
pct() { if [ "$2" -eq 0 ]; then echo "n/a"; else awk -v a="$1" -v b="$2" 'BEGIN{printf "%.0f%%", (a/b)*100}'; fi; }

kmp_start() {
  ( cd "$KMP" && MESH_NODE_NAME="${NODE:-bench}" MESH_NODE_SHORT=BNCH MESH_LORA_REGION=US \
      MESH_TRANSPORTS="$BEARERS" MESH_STATE_DIR="$RUN/state" \
      nohup java -jar node-headless/build/libs/meshnode-headless.jar >"$RUN/kmp.log" 2>&1 & )
  sleep 20
}

teardown
kmp_start
echo "run dir: $RUN   bearers: $BEARERS   sends per direction: $SENDS"

# Phase 1: node-kmp transmits, radio's device log counts ingress. Listener owns the port.
nohup meshtastic --port "$PORT" --listen >"$RUN/radio.log" 2>&1 &
sleep 8
for i in $(seq 1 "$SENDS"); do
  timeout 40 meshtastic --host 127.0.0.1 --sendtext "k2r $i" >/dev/null 2>&1
  sleep "$GAP"
done
sleep 8
k2r=$(ids "$RUN/radio.log")
reap 'meshtastic .*--listen'
sleep 3

# Phase 2: radio transmits, node-kmp's own counter is the witness. No listener,
# so the port is free for --sendtext.
before=$(count 'rx\[' "$RUN/kmp.log")
for i in $(seq 1 "$SENDS"); do
  timeout 40 meshtastic --port "$PORT" --sendtext "r2k $i" >/dev/null 2>&1
  sleep "$GAP"
done
sleep 8
after=$(count 'rx\[' "$RUN/kmp.log")
r2k=$((after - before))

printf '\n%-18s %5s %10s %6s\n' direction sent delivered rate
printf '%-18s %5s %10s %6s\n' "node-kmp->radio" "$SENDS" "$k2r" "$(pct "$k2r" "$SENDS")"
printf '%-18s %5s %10s %6s\n' "radio->node-kmp" "$SENDS" "$r2k" "$(pct "$r2k" "$SENDS")"
echo
echo "-- node-kmp counters --"; grep -oE 'bearers [a-z-]+ rx=[0-9]+ tx=[0-9]+' "$RUN/kmp.log" | tail -1
echo "-- radio ingress (distinct) --"; grep -ohE 'BLE mesh RX[^"\\]{0,60}' "$RUN/radio.log" | sed 's/id=0x[0-9a-f]*//' | sort -u | head -4
teardown
