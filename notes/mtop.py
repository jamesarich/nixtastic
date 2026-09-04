#!/usr/bin/env python3
"""mtop — btop-style live monitor for a Meshtastic bench soak.

Reads the meshtastic-mcp recorder JSONL streams only (never opens a serial
port), so it is safe to run alongside the MCP server, a flash, or the web
flasher.

  mtop.py            live dashboard
  mtop.py --once     render one frame and exit (for piping / testing)
  mtop.py --mtlog D  point at a different recorder dir
"""
import argparse, collections, json, os, sys, time
from datetime import datetime

DEF_MTLOG = os.path.expanduser("~/.local/share/meshtastic-mcp/.mtlog")
NODEMAP = os.path.expanduser("~/meshtastic/notes/soak-nodemap.json")
HIST, TAIL_BYTES, REFRESH = 120, 12 * 1024 * 1024, 2.0
ERRPAT = ("rebooting", "reboot in", "assert", "panic", "guru", "watchdog",
          "brownout", "crash", "crit", "fatal", "stack overflow",
          "out of memory", "malloc fail")
ANSI = __import__("re").compile(r"\x1b\[[0-9;]*m")
SOAK_ANCHOR = os.path.expanduser("~/meshtastic/notes/soak-start")

try:
    from rich.console import Console, Group
    from rich.table import Table
    from rich.live import Live
    from rich.panel import Panel
    from rich.text import Text
    from rich.layout import Layout
    from rich import box
except ImportError:
    sys.exit("needs 'rich':  ~/meshtastic/meshtastic-mcp/.venv/bin/python3 "
             + os.path.abspath(__file__))

BRAILLE = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]]


def braille_graph(vals, width=48, height=4):
    """Compact braille line graph, btop style."""
    if len(vals) < 2:
        return [" " * width] * height
    pts = vals[-width * 2:]
    if len(pts) < width * 2:
        pts = [pts[0]] * (width * 2 - len(pts)) + pts
    step = max(1, len(pts) // (width * 2))
    pts = pts[::step][-width * 2:]
    lo, hi = min(pts), max(pts)
    rng = (hi - lo) or 1
    grid = [[0] * width for _ in range(height)]
    for i, v in enumerate(pts):
        col, sub = divmod(i, 2)
        if col >= width:
            break
        lvl = int((v - lo) / rng * (height * 4 - 1))
        row = height - 1 - lvl // 4
        grid[row][col] |= BRAILLE[3 - (lvl % 4)][sub]
    return ["".join(chr(0x2800 + c) if c else " " for c in r) for r in grid]


def meter(frac, width=14):
    """Gradient bar: green -> yellow -> red as it empties."""
    frac = max(0.0, min(1.0, frac))
    filled = int(round(frac * width))
    color = "green" if frac > 0.4 else ("yellow" if frac > 0.2 else "red")
    return Text.assemble((("━" * filled), color), (("━" * (width - filled)), "grey30"))


def tail_json(path):
    try:
        sz = os.path.getsize(path)
    except OSError:
        return
    with open(path, "rb") as fh:
        if sz > TAIL_BYTES:
            fh.seek(sz - TAIL_BYTES); fh.readline()
        for raw in fh:
            try:
                yield json.loads(raw)
            except Exception:
                continue


def human_uptime(s):
    if s is None:
        return "-"
    s = int(s); d, s = divmod(s, 86400); h, s = divmod(s, 3600)
    return f"{d}d{h:02d}h" if d else f"{h:02d}h{s//60:02d}m"


def age(ts, now):
    if not ts:
        return "-"
    d = int(now - ts)
    return f"{d}s" if d < 90 else (f"{d//60}m" if d < 5400 else f"{d//3600}h")


class State:
    def __init__(self, mtlog):
        self.telem = os.path.join(mtlog, "telemetry.jsonl")
        self.logs = os.path.join(mtlog, "logs.jsonl")
        self.n = collections.defaultdict(lambda: {
            "heap": collections.deque(maxlen=HIST), "hts": collections.deque(maxlen=HIST),
            "htot": None, "up": None, "rb": 0, "batt": None, "chu": None, "air": None,
            "rxbad": None, "tx": None, "rx": None, "on": None, "tot": None,
            "temp": None, "lux": None, "last": None, "port": None})
        self.errors = collections.deque(maxlen=40)
        self.first = None
        try:
            self.first = float(open(SOAK_ANCHOR).read().strip())
        except Exception:
            self.first = None

    def ingest(self):
        for d in tail_json(self.telem):
            nid = d.get("from_node")
            if not nid:
                continue
            ts = d.get("ts")
            n = self.n[nid]
            n["port"] = d.get("port") or n["port"]
            if ts:
                n["last"] = max(n["last"] or 0, ts)
            f, var = d.get("fields") or {}, d.get("variant")
            if var == "local":
                hf = f.get("heapFreeBytes")
                if hf is not None and (not n["heap"] or n["heap"][-1] != hf):
                    n["heap"].append(hf); n["hts"].append(ts or 0)
                n["htot"] = f.get("heapTotalBytes") or n["htot"]
                for k, key in (("uptimeSeconds", "up"), ("numPacketsRxBad", "rxbad"),
                               ("numPacketsTx", "tx"), ("numPacketsRx", "rx"),
                               ("numOnlineNodes", "on"), ("numTotalNodes", "tot"),
                               ("channelUtilization", "chu"), ("airUtilTx", "air")):
                    v = f.get(k)
                    if v is None:
                        continue
                    if key == "up" and n["up"] is not None and v < n["up"] - 5:
                        n["rb"] += 1
                    n[key] = v
            elif var == "device":
                for k, key in (("batteryLevel", "batt"), ("channelUtilization", "chu"),
                               ("airUtilTx", "air"), ("uptimeSeconds", "up")):
                    v = f.get(k)
                    if v is None:
                        continue
                    if key == "up" and n["up"] is not None and v < n["up"] - 5:
                        n["rb"] += 1
                    n[key] = v
            elif var == "environment":
                n["temp"] = f.get("temperature", n["temp"])
                n["lux"] = f.get("lux", n["lux"])
        self.errors.clear()
        for d in tail_json(self.logs):
            if d.get("role") == "marker" or (d.get("level") or "") == "DEBUG":
                continue
            ts = d.get("ts")
            if self.first and ts and ts < self.first:
                continue          # pre-soak setup noise
            line = ANSI.sub("", (d.get("line") or "")).strip()
            if any(p in line.lower() for p in ERRPAT):
                self.errors.append((ts, d.get("port"), line[:120]))

    def rate(self, n):
        h, t = list(n["heap"]), list(n["hts"])
        if len(h) < 3 or not t[0] or (t[-1] - t[0]) < 600:
            return None
        return (h[-1] - h[0]) / ((t[-1] - t[0]) / 3600.0)


def build(st, names, width):
    now = time.time()
    bench = sorted([(k, v) for k, v in st.n.items() if k in names],
                   key=lambda kv: names[kv[0]])
    others = sorted([(k, v) for k, v in st.n.items() if k not in names],
                    key=lambda kv: -(kv[1]["last"] or 0))[:5]

    reboots = sum(v["rb"] for _, v in bench)
    worst = None
    for k, v in bench:
        r = st.rate(v)
        if r is not None and (worst is None or r < worst[1]):
            worst = (names[k], r)
    soak = ""
    if st.first:
        e = int(now - st.first); soak = f"{e//3600}h{(e%3600)//60:02d}m"
    hdr = Text.assemble(
        ("  mtop ", "bold green on grey15"), ("  2.8.0.8eda860 ", "bold white"),
        (f" {len(bench)} nodes ", "cyan"), (f" soak {soak} ", "cyan"),
        (f" reboots {reboots} ", "bold red" if reboots else "green"),
        (f" worst heap {worst[1]:+,.0f} B/h ({worst[0][:14]}) " if worst else "", 
         "yellow" if worst and worst[1] < -500 else "green"),
        (f" {datetime.now():%H:%M:%S}", "grey50"))

    t = Table(expand=True, box=box.SIMPLE_HEAD, header_style="bold cyan",
              border_style="grey30", pad_edge=False, show_edge=False)
    for c, j in (("node", "left"), ("uptime", "right"), ("rb", "right"),
                 ("free heap", "right"), ("", "left"), ("%", "right"),
                 ("B/h", "right"), ("bat", "right"), ("ch%", "right"),
                 ("air%", "right"), ("rx/tx", "right"), ("bad", "right"),
                 ("mesh", "right"), ("env", "right"), ("seen", "right")):
        t.add_column(c, justify=j, no_wrap=True)

    def add(nid, n, is_bench):
        heap = n["heap"][-1] if n["heap"] else None
        frac = (heap / n["htot"]) if (heap and n["htot"]) else None
        r = st.rate(n)
        rs, rc = "-", "grey50"
        if r is not None:
            rs = f"{r:+,.0f}"
            rc = "bold red" if r < -2000 else ("yellow" if r < -500 else "green")
        hc = "green"
        if frac is not None:
            hc = "bold red" if frac < .15 else ("yellow" if frac < .25 else "green")
        stale = n["last"] and (now - n["last"]) > 3600
        t.add_row(
            Text(names.get(nid, nid)[:24], style="bold white" if is_bench else "grey50"),
            human_uptime(n["up"]),
            Text(str(n["rb"] or ""), style="bold red" if n["rb"] else "grey50"),
            Text(f"{heap:,}" if heap else "-", style=hc),
            meter(frac, 10) if frac is not None else Text(""),
            Text(f"{frac*100:.0f}" if frac is not None else "-", style=hc),
            Text(rs, style=rc),
            f"{n['batt']:.0f}" if n["batt"] is not None else "-",
            f"{n['chu']:.1f}" if n["chu"] is not None else "-",
            f"{n['air']:.1f}" if n["air"] is not None else "-",
            f"{int(n['rx'] or 0)}/{int(n['tx'] or 0)}" if (n["rx"] or n["tx"]) else "-",
            Text(str(int(n["rxbad"])) if n["rxbad"] else "", style="yellow" if n["rxbad"] else "grey50"),
            f"{int(n['on'] or 0)}/{int(n['tot'] or 0)}" if n["tot"] else "-",
            ((f"{n['temp']:.0f}°" if n["temp"] is not None else "") +
             (f" {n['lux']:.0f}lx" if n["lux"] is not None else "")) or "-",
            Text(age(n["last"], now), style="red" if stale else "grey50"))

    for k, v in bench:
        add(k, v, True)
    if others:
        t.add_section()
        for k, v in others:
            add(k, v, False)

    gw = max(24, min(64, width // 2 - 12))
    graphs = []
    for k, v in bench:
        if len(v["heap"]) >= 2:
            graphs.append((names[k], list(v["heap"]), v["htot"]))
    graphs.sort(key=lambda g: (g[1][-1] / g[2]) if g[2] else 1)
    gp = []
    for nm, vals, tot in graphs[:4]:
        lines = braille_graph(vals, width=gw, height=3)
        cur = vals[-1]
        gp.append(Text.assemble((f"{nm[:22]:22}", "bold white"),
                                (f" {cur:,}", "cyan"),
                                (f" / {tot:,}" if tot else "", "grey50")))
        for ln in lines:
            gp.append(Text("  " + ln, style="green"))
    if not gp:
        gp = [Text("collecting heap samples…", style="grey50")]

    if st.errors:
        el = []
        for ts, port, line in list(st.errors)[-9:]:
            when = datetime.fromtimestamp(ts).strftime("%H:%M:%S") if ts else "--:--:--"
            el.append(Text.assemble((f"{when} ", "grey50"),
                                    (f"{(port or '').replace('/dev/','')[:9]:9} ", "cyan"),
                                    (line, "yellow")))
        ep = Group(*el)
        eb = "yellow"
    else:
        ep, eb = Text("clean since soak start — no reboots, asserts or panics", style="green"), "grey30"

    return hdr, t, gp, ep, eb


def render(st, names, width):
    hdr, t, gp, ep, eb = build(st, names, width)
    return Group(
        Panel(hdr, box=box.ROUNDED, border_style="green", padding=(0, 0)),
        Panel(t, title="[bold]nodes[/]", title_align="left", box=box.ROUNDED,
              border_style="cyan", padding=(0, 1)),
        Panel(Group(*gp), title="[bold]free heap[/]", title_align="left",
              box=box.ROUNDED, border_style="green", padding=(0, 1)),
        Panel(ep, title="[bold]events[/]", title_align="left", box=box.ROUNDED,
              border_style=eb, padding=(0, 1)),
        Text("  rb reboots · B/h heap slope · bad malformed rx · grey = RF neighbours"
             " · ctrl-c quit", style="grey50"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--mtlog", default=DEF_MTLOG)
    ap.add_argument("--nodemap", default=NODEMAP)
    a = ap.parse_args()

    def names():
        try:
            with open(a.nodemap) as fh:
                return json.load(fh)
        except Exception:
            return {}

    st = State(a.mtlog)
    nm = names()
    con = Console()
    if a.once:
        st.ingest()
        con.print(render(st, nm, con.width))
        return
    with Live(console=con, refresh_per_second=4, screen=True) as live:
        i = 0
        while True:
            if i % 30 == 0:
                nm = names() or nm
            st.ingest()
            live.update(render(st, nm, con.width))
            time.sleep(REFRESH)
            i += 1


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
