#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
"""Cross-repo pin state: who pins protobufs, design, TAKPacket-SDK and the api
seeds, and whether each consumer is current. Offline by default; reads local
checkouts and local tags. Reports, never judges. Design: notes/agent-tools.md."""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.environ.get("MESHTASTIC_WORKSPACE") or os.getcwd()


def git(repo, *args, default=None):
    try:
        return subprocess.run(["git", "-C", os.path.join(ROOT, repo), *args],
                              capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return default


def cloned(repo):
    return os.path.isdir(os.path.join(ROOT, repo, ".git"))


def vkey(tag):
    return tuple(int(x) if x.isdigit() else 0 for x in re.sub(r"^v", "", tag).split("."))


def latest_tag(repo):
    tags = (git(repo, "tag", "--list", "v*", default="") or "").split()
    return max(tags, key=vkey) if tags else None


def head_short(repo):
    return git(repo, "rev-parse", "--short", "HEAD", default="?")


def tag_at(repo, sha):
    """Exact tag at sha, else 'vX.Y.Z+N' when ahead of a tag, else None."""
    exact = git(repo, "describe", "--tags", "--exact-match", sha)
    if exact:
        return exact, exact
    d = git(repo, "describe", "--tags", sha)
    if d and re.search(r"-\d+-g[0-9a-f]+$", d):
        base = re.sub(r"-\d+-g[0-9a-f]+$", "", d)
        n = re.search(r"-(\d+)-g", d).group(1)
        return f"{base}+{n}", base
    return None, None


def verdict_vs(pinned_tag, latest):
    if not pinned_tag or not latest:
        return "unknown"
    if vkey(pinned_tag) == vkey(latest):
        return "current"
    return f"behind: {latest}" if vkey(pinned_tag) < vkey(latest) else "ahead"


def submodule_sha(consumer, path):
    out = git(consumer, "ls-tree", "HEAD", path)
    return out.split()[2] if out and len(out.split()) >= 3 else None


def toml_version(consumer, relfile, key):
    p = os.path.join(ROOT, consumer, relfile)
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(rf'^\s*{re.escape(key)}\s*=\s*"([^"]+)"', line)
            if m:
                return m.group(1)
    return None


def sha256(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


def row(kind, repo, detail, pinned="", resolves="", verdict=""):
    return {"kind": kind, "repo": repo, "detail": detail, "pinned": pinned,
            "resolves": resolves, "verdict": verdict}


def submodule_row(consumer, path, producer, latest):
    sha = submodule_sha(consumer, path)
    if not sha:
        return row("consumer", consumer, f"submodule {path}", "", "", "unknown")
    label, base = tag_at(producer, sha)
    resolves = label or sha[:7]
    verdict = verdict_vs(base, latest) if base else "unknown"
    if verdict == "current" and label != base:  # past the latest tag, not on it
        verdict = f"ahead of {base}"
    return row("consumer", consumer, f"submodule {path} @ {sha[:7]} = {resolves}", sha[:7], resolves, verdict)


def toml_row(consumer, key, coord, latest):
    v = toml_version(consumer, "gradle/libs.versions.toml", key)
    return row("consumer", consumer, f"{coord} {v or '?'} (gradle/libs.versions.toml)", v or "",
               f"v{v}" if v else "", verdict_vs(f"v{v}", latest) if v else "unknown")


def rows():
    out = []
    # protobufs -> firmware, meshtastic-python, apple (submodules); android, meshtastic-sdk (toml)
    if cloned("protobufs"):
        latest = latest_tag("protobufs")
        out.append(row("producer", "protobufs", f"master {head_short('protobufs')}", "", "",
                       f"latest tag {latest or 'none'}"))
        for c in ("firmware", "meshtastic-python", "apple"):
            if cloned(c):
                out.append(submodule_row(c, "protobufs", "protobufs", latest))
        for c, key in (("android", "meshtastic-protobufs"), ("meshtastic-sdk", "meshtasticProtobufs")):
            if cloned(c):
                out.append(toml_row(c, key, "org.meshtastic:protobufs", latest))
    # TAKPacket-SDK -> android
    if cloned("TAKPacket-SDK") and cloned("android"):
        latest = latest_tag("TAKPacket-SDK")
        out.append(row("producer", "TAKPacket-SDK", f"main {head_short('TAKPacket-SDK')}", "", "",
                       f"latest tag {latest or 'none'}"))
        out.append(toml_row("android", "takpacket-sdk", "org.meshtastic:takpacket-sdk", latest))
    # design -> meshtastic (docs) submodule
    if cloned("design") and cloned("meshtastic"):
        out.append(row("producer", "design", f"master {head_short('design')}"))
        sha = submodule_sha("meshtastic", "static/design")
        if sha:
            behind = git("design", "rev-list", "--count", f"{sha}..HEAD")
            v = "current" if behind == "0" else (f"behind by {behind} commits" if behind else "unknown")
            out.append(row("consumer", "meshtastic", f"submodule static/design @ {sha[:7]}", sha[:7], sha[:7], v))
        else:
            out.append(row("consumer", "meshtastic", "submodule static/design", "", "", "unknown"))
    # api seeds -> android assets
    if cloned("api") and cloned("android"):
        out.append(row("producer", "api", "data/*.json"))
        pairs = (("maintenanceUf2", "maintenance_uf2"), ("bootloaderOtaQuirks", "device_bootloader_ota_quirks"),
                 ("deviceLinks", "device_links"), ("eventFirmware", "event_firmware"))
        parts = []
        for a, b in pairs:
            ha = sha256(os.path.join(ROOT, "api", "data", f"{a}.json"))
            hb = sha256(os.path.join(ROOT, "android", "androidApp", "src", "main", "assets", f"{b}.json"))
            parts.append(f"{b} {'same' if ha and ha == hb else ('DIFFERS' if ha and hb else 'missing')}")
        out.append(row("consumer", "android assets", "  ".join(parts)))
    return out


def render(rs):
    for r in rs:
        tail = f"  {r['verdict']}" if r["verdict"] else ""
        print(f"{r['kind']:<9} {r['repo']:<18} {r['detail']}{tail}")


def short_phrase(rs):
    cons = [r for r in rs if r["kind"] == "consumer" and r["verdict"]]
    if not cons:
        return "-"
    r = cons[0]
    d = r["detail"]
    name = d.split()[1] if d.startswith("submodule") else d.split()[0].split(":")[-1]
    return f"{name} {r['resolves'] or r['pinned']} {r['verdict']}".strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fetch", action="store_true", help="git fetch --tags in the producers first")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--repo", help="only rows naming this repo")
    ap.add_argument("--short", action="store_true", help="with --repo: one phrase, or '-'")
    a = ap.parse_args()
    if a.fetch:
        for p in ("protobufs", "design", "TAKPacket-SDK"):
            if cloned(p):
                git(p, "fetch", "--quiet", "--tags", "origin")
    rs = rows()
    if a.repo:
        rs = [r for r in rs if r["repo"] == a.repo or r["repo"].startswith(a.repo + " ")]
        if a.short:
            print(short_phrase(rs))
            return 0
    if a.json:
        json.dump(rs, sys.stdout, indent=1)
        print()
    else:
        render(rs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
