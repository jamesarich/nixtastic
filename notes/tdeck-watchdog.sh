#!/usr/bin/env bash
# Auto-recover wedged T-Decks during the 2.8.0 soak.
#
# Safety model - the previous version cycled a hub port carrying four
# unrelated boards. The port is now derived FROM THE DEVICE: we read the
# wedged board's own USB address out of sysfs, and before cutting power we
# re-read the serial at that exact address and require it to match. If the
# address does not resolve, or the serial does not match, or the thing there
# reports itself a hub, we cycle NOTHING and ask for hands.
#
# A port cycle only helps while the board is still enumerated. Once it has
# fallen off the bus there is no address to verify, so we never guess.

SERIALS=("3C:84:27:ED:9F:E0|t-deck-mui" "3C:84:27:CC:67:14|t-deck-nomui")
LOGFILE=/home/james/meshtastic/notes/tdeck-lockups.log
INTERVAL=180

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOGFILE"; }

port_for() {
  local l
  l=$(find /dev/serial/by-id -maxdepth 1 -type l 2>/dev/null | grep -F "$1" | head -1)
  [ -n "$l" ] && echo "/dev/$(readlink "$l" | sed 's|.*/||')"
}

# /dev/ttyACMn -> USB address (e.g. 1-2.3.2), taken as the deepest path
# component that is exactly a USB address (interface dirs contain ':').
usb_addr_for() {
  local path comp addr=""
  path=$(udevadm info -q path -n "$1" 2>/dev/null) || return 1
  IFS='/' read -ra comp <<< "$path"
  for c in "${comp[@]}"; do
    [[ "$c" =~ ^[0-9]+-[0-9]+(\.[0-9]+)*$ ]] && addr="$c"
  done
  [ -n "$addr" ] && echo "$addr"
}

# Only true when the address really is our board, on a real hub port.
safe_to_cycle() {                       # addr expected_serial -> hub port
  local addr="$1" want="$2" hub port actual
  [[ "$addr" == *.* ]] || return 1      # root-port device: not ours to cycle
  hub="${addr%.*}"; port="${addr##*.}"
  actual=$(cat "/sys/bus/usb/devices/$addr/serial" 2>/dev/null)
  [ "$actual" = "$want" ] || return 1   # address must still BE our board
  # Never cut power to a port with a hub behind it. Inspect ONLY that
  # port's own line - uhubctl's header names the hub itself, so grepping
  # the whole output would reject every port.
  uhubctl -l "$hub" -p "$port" 2>/dev/null \
    | grep -E "^[[:space:]]*Port $port:" | grep -qi 'hub' && return 1
  echo "$hub $port"
}

probe() { timeout 40 meshtastic-mcp info "$1" 2>/dev/null | grep -q firmware; }

echo "tdeck watchdog armed (verified-port) - probing every ${INTERVAL}s"
declare -A STATE
while true; do
  for entry in "${SERIALS[@]}"; do
    serial="${entry%%|*}"; name="${entry##*|}"
    port=$(port_for "$serial")

    if [ -z "$port" ]; then
      [ "${STATE[$name]}" = offbus ] || {
        echo "$name OFF BUS - needs a physical power cycle"
        log "$name off-bus"; STATE[$name]=offbus; }
      continue
    fi

    if probe "$port"; then
      [ -n "${STATE[$name]}" ] && { log "$name recovered"; STATE[$name]=""; }
      continue
    fi

    addr=$(usb_addr_for "$port")
    if ! hp=$(safe_to_cycle "$addr" "$serial"); then
      [ "${STATE[$name]}" = unsafe ] || {
        echo "$name wedged at ${addr:-?} - cannot verify its hub port, NOT cycling; needs hands"
        log "$name wedged, refused to cycle (addr=${addr:-none})"; STATE[$name]=unsafe; }
      continue
    fi
    set -- $hp
    log "$name wedged on $port (addr $addr -> hub $1 port $2) - cycling"
    uhubctl -l "$1" -p "$2" -a cycle -d 4 >/dev/null 2>&1
    sleep 14
    port=$(port_for "$serial")
    if [ -n "$port" ] && probe "$port"; then
      echo "$name lockup #$(grep -c 'cycling' "$LOGFILE") - recovered by hub cycle"
      log "$name recovered by cycle"; STATE[$name]=""
    else
      echo "$name lockup - cycle did not recover it; needs a physical power cycle"
      log "$name cycle failed"; STATE[$name]=failed
    fi
  done
  sleep "$INTERVAL"
done
