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
#
# The outbound column is a LOWER BOUND, which is why it is labelled (min). It
# counts the firmware's own log line, and that reaches this host as a LogRecord
# stream which is sparse and is captured only during the outbound phase: a
# single-bearer LoRa run whose ACKs proved all six messages landed showed one.
# The `acknowledged by the radio` line below the matrix is the trustworthy
# outbound figure - an ACK cannot exist unless the radio decoded the packet -
# and with one bearer enabled it is that bearer's rate.
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

# The node joins the radio's own channel, key included. A matching name with a
# different PSK hears every frame and decodes none, which reads as a dead bearer
# rather than as the configuration error it is - this run measured 0% on all four
# bearers that way while the counters showed lora rx=16. Read before the --listen
# session below, which holds the port exclusively. CHANNEL_URL overrides.
if [ -z "${CHANNEL_URL:-}" ]; then
  CHANNEL_URL=$(timeout 40 meshtastic --port "$PORT" --info 2>/dev/null |
    grep -oE 'https://meshtastic\.org/e/#[A-Za-z0-9_-]+' | head -1)
fi
if [ -n "${CHANNEL_URL:-}" ]; then
  echo "channel from the radio: ${CHANNEL_URL:0:48}..."
else
  echo "WARNING: no channel URL from the radio - the node falls back to the default PSK,"
  echo "         so anything the radio sends on a keyed channel will not decode."
fi

# The outbound row is counted from the FIRMWARE's own log line, which reaches this
# host only as a protobuf LogRecord over the phone API - `meshtastic --listen`
# otherwise prints the Python client's debug output and nothing of the radio's.
# Without this every outbound cell reads 0% no matter what arrived. Persists in
# NVS, so this is a no-op on a radio already set up.
timeout 60 meshtastic --port "$PORT" --begin-edit \
  --set security.debug_log_api_enabled true --commit-edit >/dev/null 2>&1 ||
  echo "WARNING: could not enable the radio's log API - the outbound row will read 0%"
sleep 3

( cd "$KMP" && MESH_NODE_NAME="${NODE:-bench}" MESH_NODE_SHORT=BNCH MESH_LORA_REGION="${REGION:-US}" \
    MESH_TRANSPORTS="$BEARERS" MESH_GATT_ROLE="${GATT_ROLE:-CENTRAL_ONLY}" MESH_STATE_DIR="$RUN/state" \
    MESH_CHANNEL_URL="${CHANNEL_URL:-}" \
    nohup java -jar node-headless/build/libs/meshnode-headless.jar >"$RUN/kmp.log" 2>&1 & )

# Wait for the bearers to be usable rather than assuming a fixed settle. GATT has
# to scan, dial, resolve services and subscribe, and against a firmware peer that
# measured 93 seconds - three times the old `sleep 25`, so every outbound message
# went out before the link existed and the bearer scored 0% while working.
waited=0
while [ "$waited" -lt "${READY_TIMEOUT:-150}" ]; do
  ready=1
  grep -q "avail\[" "$RUN/kmp.log" 2>/dev/null || ready=0
  case ",$BEARERS," in
    *,gatt,*) grep -q ':ready' "$RUN/kmp.log" 2>/dev/null || ready=0 ;;
  esac
  [ "$ready" = 1 ] && break
  sleep 5
  waited=$((waited + 5))
done
echo "bearers settled after ${waited}s"
sleep 5

kmpnode=$(grep -oE 'node [^ ]+ \(!([0-9a-f]+)\)' "$RUN/kmp.log" | head -1 | grep -oE '[0-9a-f]{8}')

# Every outbound send goes to 127.0.0.1's phone API, and anything else holding that
# port answers instead - a meshtasticd container on --net=host will. The node then
# transmits nothing and the bearer reads 0% while working.
owner=$(timeout 40 meshtastic --host 127.0.0.1 --info 2>/dev/null | grep -m1 '^Owner:')
case "$owner" in
  *"${NODE:-bench}"*) ;;
  *)
    echo "ABORT: 127.0.0.1's phone API is not this run's node."
    echo "       expected ${NODE:-bench}, got: ${owner:-no answer}"
    echo "       something else holds tcp 4403 - ss -lntp | grep 4403"
    teardown
    exit 2
    ;;
esac
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

# An ACK can only come from a radio that decoded the packet, so the node's own
# Delivered events are ground truth for outbound delivery - and unlike the
# firmware's log they cannot be missed, because the node is the one counting.
# The firmware LogRecord stream is sparse: a run whose ACKs proved two messages
# landed showed only one 'decoded message' line for them.
#
# `via=` is the bearer the ACK came back on, not the one the message went out on,
# so this is a total rather than a per-bearer figure. Run one bearer to attribute it.
#
# It is itself a floor when the RETURN path is lossy: a GATT run measured 4/6
# outbound in the firmware's log and 0/6 acknowledged, because the delivery
# succeeded and the acknowledgement did not. The two numbers bound the truth from
# opposite sides - trust the higher one, and treat a gap between them as a
# statement about the return path.
acked=$(grep -oE "Delivered\(from=[0-9]+, requestId=[0-9]+" "$RUN/kmp.log" | sort -u | wc -l | tr -d ' ')

decoded_total=0
printf '\n%-10s %16s %16s\n' bearer 'kmp->radio (min)' 'radio->kmp (first)'
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
  decoded_total=$(( decoded_total + out + inn ))
  printf '%-10s %6s/%-7s %6s/%-7s\n' "$b" "$out" "$SENDS ($(pct "$out" "$SENDS"))" "$inn" "$SENDS ($(pct "$inn" "$SENDS"))"
done

echo
counters=$(grep -oE 'bearers .*rx=[0-9]+ tx=[0-9]+' "$RUN/kmp.log" | tail -1)
echo "-- bearer counters --"; echo "$counters"
# Printed beside the matrix, not inside it: it is a total across the bearers that
# were enabled, and it counts what the radio acknowledged rather than what any one
# bearer carried.
echo "-- acknowledged by the radio: $acked/$SENDS outbound (all bearers together) --"

# A row of zeros beside non-zero rx counters is the signature of a channel
# mismatch, not a dead link: the bearer carried the frames and no key opened
# them. Saying so here is the difference between a five-minute check and
# re-measuring a link that was never broken.
if [ "$decoded_total" -eq 0 ] && printf '%s' "$counters" | grep -qE 'rx=[1-9]'; then
  echo
  echo "NOTE: frames arrived but none decoded, so this run measured nothing."
  echo "      The node and the radio are not on one channel+PSK - compare the"
  echo "      radio's 'Primary channel URL' with the node's MESH_CHANNEL."
fi
echo "-- one packet carried onto several bearers by the radio --"
grep -ohE 'decoded message \(id=0x[0-9a-f]+[^"\\]*transport = [0-9]+' "$RUN/radio.log" 2>/dev/null |
  sed -E 's/.*id=(0x[0-9a-f]+).*transport = ([0-9]+)/\1 \2/' | sort -u |
  awk '{ seen[$1] = seen[$1] " " $2 } END { for (i in seen) { n = split(seen[i], a, " "); if (n > 1) print i " on transports" seen[i] } }' |
  head -3
teardown
