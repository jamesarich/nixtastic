#!/usr/bin/env bash
# Per-bearer delivery between a firmware radio and a node-kmp node on one bench.
#
# One run measures every enabled bearer at once. node-kmp broadcasts on all of
# them, and the radio stamps each arrival with `transport = N`, so counting
# distinct decoded ids per transport value gives the outbound matrix without
# driving the bearers separately.
#
# Inbound is asymmetric and the column says so. A radio broadcast reaches every
# bearer, node-kmp decodes the first copy and drops the rest as duplicates, so
# inbound attributes each message to whichever bearer WON - not to whether a
# bearer could have delivered it. The frame counters beside the matrix are what
# say a bearer was carrying; a 0 there and only there is a fault. Run a single
# bearer to get its unaided rate.
#
# Delivered means DECODED. Counting ingress counts one frame per advertising
# event, counts the radio's own background traffic, and counts frames the
# receiver could not open - which is how an earlier version reported 20-38% for a
# link that was passing everything. Both sides must share a channel name AND PSK.
set -uo pipefail

PORT="${PORT:-/dev/ttyACM2}"
KMP="${KMP:-$HOME/meshtastic/meshtastic-node-kmp}"
SENDS="${SENDS:-8}"
GAP="${GAP:-6}"
BEARERS="${BEARERS:-lora,ble-adv,gatt,udp}"
RUN="/tmp/meshbench-$$"
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$RUN"

# Kill by PID from a pattern that cannot match this script's own argv. `pkill -f`
# is a foot-gun here: the pattern appears in the caller's command line.
reap() {
  ps -eo pid,args | awk -v w="$1" '$0 ~ w && !/awk/ {print $1}' | while read -r p; do
    [ "$p" = "$$" ] && continue
    kill "$p" 2>/dev/null
  done
}
teardown() { reap 'meshtastic .*--listen'; reap 'meshnode-headless'; sleep 2; }

# grep -c prints 0 AND exits 1 with no matches, so the obvious guard yields two
# lines and poisons the arithmetic that consumes it.
count() { grep -c "$1" "$2" 2>/dev/null | head -1; }

# The radio logs `decoded message (id=...` only once a channel key opens a packet.
decoded_from_kmp() {
  grep -ohE "decoded message \(id=0x[0-9a-f]+ fr=0x$1[^\"\\\\]*transport = $2" "$RUN/radio.log" 2>/dev/null |
    grep -oE 'id=0x[0-9a-f]+' | sort -u | wc -l
}
pct() { if [ "$2" -eq 0 ]; then echo "n/a"; else awk -v a="$1" -v b="$2" 'BEGIN{printf "%d%%", (a/b)*100}'; fi; }

bearer_of_transport() {
  case "$1" in
    1) echo lora ;; 6) echo udp ;; 9) echo ble-adv ;; 10) echo gatt ;; *) echo "transport-$1" ;;
  esac
}

teardown
( cd "$KMP" && MESH_NODE_NAME="${NODE:-bench}" MESH_NODE_SHORT=BNCH MESH_LORA_REGION="${REGION:-US}" \
    MESH_TRANSPORTS="$BEARERS" MESH_GATT_ROLE="${GATT_ROLE:-CENTRAL_ONLY}" MESH_STATE_DIR="$RUN/state" \
    nohup java -jar node-headless/build/libs/meshnode-headless.jar >"$RUN/kmp.log" 2>&1 & )
sleep 25

kmpnode=$(grep -oE 'node [^ ]+ \(!([0-9a-f]+)\)' "$RUN/kmp.log" | head -1 | grep -oE '[0-9a-f]{8}')
echo "run $RUN   bearers $BEARERS   node !${kmpnode:-unknown}   $SENDS per direction"

# Outbound: node-kmp broadcasts on every bearer; the radio's log says which arrived.
nohup meshtastic --port "$PORT" --listen >"$RUN/radio.log" 2>&1 &
sleep 8
for i in $(seq 1 "$SENDS"); do
  timeout 40 meshtastic --host 127.0.0.1 --sendtext "k2r $i" >/dev/null 2>&1
  sleep "$GAP"
done
sleep 10
reap 'meshtastic .*--listen'
sleep 3

# Inbound: node-kmp tags each decode with the bearer it arrived on.
before_lora=$(count 'rx\[lora\] text' "$RUN/kmp.log")
before_adv=$(count 'rx\[ble-adv\] text' "$RUN/kmp.log")
before_gatt=$(count 'rx\[gatt\] text' "$RUN/kmp.log")
before_udp=$(count 'rx\[udp\] text' "$RUN/kmp.log")
for i in $(seq 1 "$SENDS"); do
  timeout 40 meshtastic --port "$PORT" --sendtext "r2k $i" >/dev/null 2>&1
  sleep "$GAP"
done
sleep 10

printf '\n%-10s %16s %16s\n' bearer 'kmp->radio' 'radio->kmp (first)'
for t in 1 9 10 6; do
  b=$(bearer_of_transport "$t")
  case ",$BEARERS," in *",$b,"*) ;; *) continue ;; esac
  out=$(decoded_from_kmp "${kmpnode:-[0-9a-f]*}" "$t")
  case "$b" in
    lora) inn=$(( $(count 'rx\[lora\] text' "$RUN/kmp.log") - before_lora )) ;;
    ble-adv) inn=$(( $(count 'rx\[ble-adv\] text' "$RUN/kmp.log") - before_adv )) ;;
    gatt) inn=$(( $(count 'rx\[gatt\] text' "$RUN/kmp.log") - before_gatt )) ;;
    udp) inn=$(( $(count 'rx\[udp\] text' "$RUN/kmp.log") - before_udp )) ;;
    *) inn=0 ;;
  esac
  printf '%-10s %6s/%-7s %6s/%-7s\n' "$b" "$out" "$SENDS ($(pct "$out" "$SENDS"))" "$inn" "$SENDS ($(pct "$inn" "$SENDS"))"
done

echo
echo "-- bearer counters --"; grep -oE 'bearers .*rx=[0-9]+ tx=[0-9]+' "$RUN/kmp.log" | tail -1
echo "-- one packet carried onto several bearers by the radio --"
grep -ohE 'decoded message \(id=0x[0-9a-f]+[^"\\]*transport = [0-9]+' "$RUN/radio.log" 2>/dev/null |
  sed -E 's/.*id=(0x[0-9a-f]+).*transport = ([0-9]+)/\1 \2/' | sort -u |
  awk '{ seen[$1] = seen[$1] " " $2 } END { for (i in seen) { n = split(seen[i], a, " "); if (n > 1) print i " on transports" seen[i] } }' |
  head -3
teardown
