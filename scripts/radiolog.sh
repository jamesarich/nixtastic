# nix run .#radiolog -- [host] [port] [seconds] - a radio's own log, plain text.
#
# `meshtastic --listen` cannot show these. SerialConsole::log_to_serial only emits a
# LogRecord `if (usingProtobufs)`, gated on `!pauseBluetoothLogging`, and PhoneAPI sets
# that true the moment a client asks for config - so the tool most reachable for reading
# firmware logs is the one that silences them. A reader that speaks no protobuf takes the
# plain-text branch instead and gets everything, BLE and GATT included.
#
# The catch is that `usingProtobufs` latches on the first phone-API client and never
# clears, so a radio any tool has spoken to since boot is silent here until it reboots.
set -uo pipefail

host="${1:-james-pc.local}"
port="${2:-/dev/ttyACM2}"
secs="${3:-60}"

reader=$(cat <<'PY'
import serial, sys, time
port, secs = sys.argv[1], float(sys.argv[2])
try:
    s = serial.Serial(port, 115200, timeout=1)
except Exception as e:
    print("radiolog: cannot open %s: %s" % (port, e), file=sys.stderr); raise SystemExit(1)
end = time.time() + secs
while time.time() < end:
    line = s.readline()
    if line:
        sys.stdout.write(line.decode("utf-8", "replace")); sys.stdout.flush()
s.close()
PY
)

note_if_silent() {
    [ -s "$1" ] && { cat "$1"; return; }
    cat >&2 <<'WHY'
radiolog: nothing read, which on a live radio means it is in protobuf mode.
  usingProtobufs latches on the first phone-API client and never clears, so any
  earlier meshtastic --info/--listen silences the plain-text log until a reboot.
  Fix: meshtastic --port <port> --reboot, wait ~20 s, then run this before
  anything else touches the radio.
WHY
}

out=$(mktemp)
trap 'rm -f "$out"' EXIT

if [ "$host" = "local" ]; then
    python3 -c "$reader" "$port" "$secs" > "$out"
    note_if_silent "$out"
else
    # The bench's pyserial lives in PlatformIO's venv; the system python3 may not have it.
    printf '%s\n' "$reader" | timeout "$((secs + 30))" ssh "$host" \
        "PY=\$HOME/.platformio/penv/bin/python; [ -x \"\$PY\" ] || PY=python3; cat > /tmp/radiolog-\$\$.py && \"\$PY\" /tmp/radiolog-\$\$.py '$port' '$secs'; rm -f /tmp/radiolog-\$\$.py" > "$out"
    note_if_silent "$out"
fi
