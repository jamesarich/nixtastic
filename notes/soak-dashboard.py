#!/usr/bin/env python3
"""Live TUI dashboard for the Meshtastic 2.8.0 bench soak.

Reads the meshtastic-mcp recorder's JSONL streams (no serial access, so it
never contends with the MCP server or the web flasher) and shows per-node
heap, uptime/reboots, battery, mesh utilisation and recent errors.

Run:  python3 notes/soak-dashboard.py
Quit: Ctrl-C
"""
import json, os, sys, time, collections
from datetime import datetime

MTLOG = os.path.expanduser("~/.local/share/meshtastic-mcp/.mtlog")
TELEM = os.path.join(MTLOG, "telemetry.jsonl")
LOGS = os.path.join(MTLOG, "logs.jsonl")
NODEMAP = os.path.expanduser("~/meshtastic/notes/soak-nodemap.json")
REFRESH = 2.0
HIST = 40                      # samples kept per node for the sparkline
TAIL_BYTES = 12 * 1024 * 1024  # cap how much of each file we re-read

SPARK = "▁▂▃▄▅▆▇█"
ERR_RE = ("reboot", "rebooting", "assert", "panic", "guru", "watchdog",
          "brownout", "crash", "CRIT", "FATAL", "stack overflow",
          "out of memory", "malloc")

try:
    from rich.console import Console, Group
    from rich.table import Table
    from rich.live import Live
    from rich.panel import Panel
    from rich.text import Text
except ImportError:
    sys.exit("needs 'rich' - run with the meshtastic-mcp venv python:\n"
             "  ~/meshtastic/meshtastic-mcp/.venv/bin/python3 "
             "~/meshtastic/notes/soak-dashboard.py")


def tail_json(path):
    """Yield parsed json objects from the tail of a jsonl file."""
    try:
        sz = os.path.getsize(path)
    except OSError:
        return
    with open(path, "rb") as fh:
        if sz > TAIL_BYTES:
            fh.seek(sz - TAIL_BYTES)
            fh.readline()
        for raw in fh:
            try:
                yield json.loads(raw)
            except Exception:
                continue


def load_names():
    try:
        with open(NODEMAP) as fh:
            return json.load(fh)
    except Exception:
        return {}


def spark(vals):
    if len(vals) < 2:
        return ""
    lo, hi = min(vals), max(vals)
    if hi == lo:
        return SPARK[3] * len(vals)
    return "".join(SPARK[int((v - lo) / (hi - lo) * (len(SPARK) - 1))] for v in vals)


def human_uptime(s):
    if s is None:
        return "-"
    s = int(s)
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m = s // 60
    return f"{d}d{h:02d}h{m:02d}m" if d else f"{h:02d}h{m:02d}m"


def age(ts, now):
    if not ts:
        return "-"
    d = int(now - ts)
    if d < 90:
        return f"{d}s"
    if d < 5400:
        return f"{d // 60}m"
    return f"{d // 3600}h"


class State:
    def __init__(self):
        self.nodes = collections.defaultdict(lambda: {
            "heap": collections.deque(maxlen=HIST), "heap_ts": collections.deque(maxlen=HIST),
            "heap_total": None, "uptime": None, "reboots": 0, "batt": None, "volt": None,
            "chutil": None, "airtx": None, "rxbad": None, "rxdupe": None,
            "tx": None, "rx": None, "online": None, "total": None,
            "temp": None, "lux": None, "last": None, "port": None, "noise": None,
        })
        self.errors = collections.deque(maxlen=12)
        self.started = time.time()
        self.first_ts = None

    def ingest(self):
        for d in tail_json(TELEM):
            nid = d.get("from_node")
            if not nid:
                continue
            ts = d.get("ts")
            if ts and (self.first_ts is None or ts < self.first_ts):
                self.first_ts = ts
            n = self.nodes[nid]
            n["port"] = d.get("port") or n["port"]
            if ts:
                n["last"] = max(n["last"] or 0, ts)
            f = d.get("fields") or {}
            var = d.get("variant")
            if var == "local":
                hf = f.get("heapFreeBytes")
                if hf is not None:
                    if not n["heap"] or n["heap"][-1] != hf or (n["heap_ts"] and ts - n["heap_ts"][-1] > 60):
                        n["heap"].append(hf); n["heap_ts"].append(ts or 0)
                if f.get("heapTotalBytes"):
                    n["heap_total"] = f["heapTotalBytes"]
                for k, key in (("uptimeSeconds", "uptime"), ("numPacketsRxBad", "rxbad"),
                               ("numRxDupe", "rxdupe"), ("numPacketsTx", "tx"),
                               ("numPacketsRx", "rx"), ("numOnlineNodes", "online"),
                               ("numTotalNodes", "total"), ("noiseFloor", "noise"),
                               ("channelUtilization", "chutil"), ("airUtilTx", "airtx")):
                    v = f.get(k)
                    if v is None:
                        continue
                    if key == "uptime" and n["uptime"] is not None and v < n["uptime"] - 5:
                        n["reboots"] += 1
                    n[key] = v
            elif var == "device":
                for k, key in (("batteryLevel", "batt"), ("voltage", "volt"),
                               ("channelUtilization", "chutil"), ("airUtilTx", "airtx"),
                               ("uptimeSeconds", "uptime")):
                    v = f.get(k)
                    if v is None:
                        continue
                    if key == "uptime" and n["uptime"] is not None and v < n["uptime"] - 5:
                        n["reboots"] += 1
                    n[key] = v
            elif var == "environment":
                if f.get("temperature") is not None:
                    n["temp"] = f["temperature"]
                if f.get("lux") is not None:
                    n["lux"] = f["lux"]

        self.errors.clear()
        for d in tail_json(LOGS):
            line = (d.get("line") or "")
            low = line.lower()
            if any(p.lower() in low for p in ERR_RE):
                self.errors.append((d.get("ts"), d.get("port"), line.strip()[:110]))

    def heap_rate(self, n):
        """bytes/hour slope over the retained window."""
        h, t = list(n["heap"]), list(n["heap_ts"])
        if len(h) < 4 or not t[0]:
            return None
        span = t[-1] - t[0]
        if span < 600:
            return None
        return (h[-1] - h[0]) / (span / 3600.0)


def render(st, names):
    now = time.time()
    tbl = Table(expand=True, header_style="bold cyan", border_style="grey30", pad_edge=False)
    tbl.add_column("node", no_wrap=True)
    tbl.add_column("uptime", justify="right", no_wrap=True)
    tbl.add_column("rb", justify="right", no_wrap=True)
    tbl.add_column("free heap", justify="right", no_wrap=True)
    tbl.add_column("%", justify="right", no_wrap=True)
    tbl.add_column("trend", no_wrap=True)
    tbl.add_column("B/h", justify="right", no_wrap=True)
    tbl.add_column("batt", justify="right", no_wrap=True)
    tbl.add_column("ch%", justify="right", no_wrap=True)
    tbl.add_column("air%", justify="right", no_wrap=True)
    tbl.add_column("rx/tx", justify="right", no_wrap=True)
    tbl.add_column("bad", justify="right", no_wrap=True)
    tbl.add_column("nodes", justify="right", no_wrap=True)
    tbl.add_column("env", justify="right", no_wrap=True)
    tbl.add_column("seen", justify="right", no_wrap=True)

    known = [(nid, n) for nid, n in st.nodes.items() if nid in names]
    other = [(nid, n) for nid, n in st.nodes.items() if nid not in names]
    known.sort(key=lambda kv: names.get(kv[0], ""))
    other.sort(key=lambda kv: -(kv[1]["last"] or 0))

    def row(nid, n, bench):
        label = names.get(nid, nid)
        heap = n["heap"][-1] if n["heap"] else None
        pct = (heap / n["heap_total"] * 100) if (heap and n["heap_total"]) else None
        rate = st.heap_rate(n)
        pc = "white" if bench else "grey50"
        heap_c = "green"
        if pct is not None:
            if pct < 15:
                heap_c = "bold red"
            elif pct < 25:
                heap_c = "yellow"
        rate_s, rate_c = "-", "grey50"
        if rate is not None:
            rate_s = f"{rate:+,.0f}"
            rate_c = "red" if rate < -2000 else ("yellow" if rate < -500 else "green")
        stale = n["last"] and (now - n["last"]) > 3600
        tbl.add_row(
            Text(label[:26], style=("bold " + pc) if bench else pc),
            human_uptime(n["uptime"]),
            Text(str(n["reboots"] or ""), style="bold red" if n["reboots"] else "grey50"),
            Text(f"{heap:,}" if heap else "-", style=heap_c),
            Text(f"{pct:.0f}" if pct is not None else "-", style=heap_c),
            Text(spark(list(n["heap"])), style=heap_c),
            Text(rate_s, style=rate_c),
            f"{n['batt']:.0f}" if n["batt"] is not None else "-",
            f"{n['chutil']:.1f}" if n["chutil"] is not None else "-",
            f"{n['airtx']:.1f}" if n["airtx"] is not None else "-",
            f"{int(n['rx'] or 0)}/{int(n['tx'] or 0)}" if (n["rx"] or n["tx"]) else "-",
            Text(str(int(n["rxbad"])) if n["rxbad"] else "", style="yellow" if n["rxbad"] else "grey50"),
            f"{int(n['online'] or 0)}/{int(n['total'] or 0)}" if n["total"] else "-",
            (f"{n['temp']:.1f}°" if n["temp"] is not None else "") +
            (f" {n['lux']:.0f}lx" if n["lux"] is not None else "") or "-",
            Text(age(n["last"], now), style="red" if stale else "grey50"),
        )

    for nid, n in known:
        row(nid, n, True)
    if other:
        tbl.add_section()
        for nid, n in other[:6]:
            row(nid, n, False)

    soak = ""
    if st.first_ts:
        el = int(now - st.first_ts)
        soak = f"  soak {el//3600}h{(el%3600)//60:02d}m"
    hdr = Text.assemble(
        ("meshtastic 2.8.0.8eda860 soak", "bold green"),
        (f"   {len(known)} bench nodes", "cyan"),
        (soak, "cyan"),
        (f"   {datetime.now():%H:%M:%S}", "grey50"),
    )

    if st.errors:
        elines = []
        for ts, port, line in list(st.errors)[-8:]:
            when = datetime.fromtimestamp(ts).strftime("%H:%M:%S") if ts else "--:--:--"
            elines.append(Text.assemble((f"{when} ", "grey50"),
                                        (f"{(port or '').replace('/dev/','')} ", "cyan"),
                                        (line, "yellow")))
        errp = Panel(Group(*elines), title="recent reboots / errors",
                     border_style="yellow", title_align="left")
    else:
        errp = Panel(Text("none", style="green"), title="recent reboots / errors",
                     border_style="grey30", title_align="left")

    return Group(Panel(hdr, border_style="green"), tbl, errp,
                 Text("  rb=reboots  B/h=heap slope  bad=bad rx packets  "
                      "grey rows = RF neighbours   Ctrl-C to quit", style="grey50"))


def main():
    names = load_names()
    st = State()
    console = Console()
    with Live(console=console, refresh_per_second=4, screen=True) as live:
        tick = 0
        while True:
            if tick % 30 == 0:
                names = load_names() or names
            st.ingest()
            live.update(render(st, names))
            time.sleep(REFRESH)
            tick += 1


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
