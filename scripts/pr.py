#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
"""PR status the way the merge queue sees it: checks for the HEAD sha (never
"whatever is attached"), unresolved review threads, queue position, conflicts.
Read-only except `rereview`. Design: notes/agent-tools.md."""
import argparse
import json
import os
import re
import subprocess
import sys
import time


def repos_tsv():
    out = {}
    p = os.environ.get("NIXTASTIC_REPOS_TSV")
    if p and os.path.isfile(p):
        with open(p, encoding="utf-8") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 2:
                    out[parts[0]] = parts[1]
    return out


def resolve_repo(arg, n):
    m = re.match(r"https?://github\.com/([^/]+/[^/]+)/pull/(\d+)", arg or "")
    if m:
        return m.group(1), int(m.group(2))
    if "/" in arg:
        return arg, int(n)
    table = repos_tsv()
    if arg not in table:
        sys.exit(f"unknown repo: {arg} (workspace dir name, org/repo, or a PR URL)")
    return table[arg], int(n)


def gh(*args):
    try:
        return subprocess.run(["gh", *args], capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError as e:
        sys.stderr.write(e.stderr or e.stdout or "")
        sys.exit(3)
    except FileNotFoundError:
        sys.exit("gh not found on PATH")


GQL = """query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){
 mergeQueueEntry{position state}
 reviews(last:30){nodes{author{login} state}}
 reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{author{login} path line body}}}}}}}"""

OK_CONCLUSIONS = ("success", "skipped", "neutral")
CR_LOGIN = "coderabbitai[bot]"


def review_state(repo, n, sha, checks):
    """Did CodeRabbit review THIS head? Only a review whose body says
    "Actionable comments posted" is a real pass — every reply it makes on a
    thread is wrapped in its own review object carrying the head SHA and an
    empty body, which reads as "re-reviewed" when nothing was. The CodeRabbit
    check saying "Review skipped" means skipped, not clean."""
    revs = json.loads(gh("api", f"repos/{repo}/pulls/{n}/reviews?per_page=100"))
    full = [r for r in revs if (r.get("user") or {}).get("login") == CR_LOGIN
            and "Actionable comments posted" in (r.get("body") or "")]
    at_head = [r for r in full if (r.get("commit_id") or "") == sha]
    cr = [c for c in checks if "coderabbit" in (c.get("name") or "").lower()]
    skipped = any("review skipped" in (((c.get("output") or {}).get("title") or "")
                                       + ((c.get("output") or {}).get("summary") or "")).lower() for c in cr)
    if at_head:
        state = "reviewed"
    elif skipped:
        state = "skipped"
    elif any(c["status"] != "completed" for c in cr):
        state = "pending"
    else:
        state = "none"
    actionable = None
    if at_head:
        m = re.search(r"Actionable comments posted:\s*\**\s*(\d+)", at_head[-1]["body"])
        actionable = int(m.group(1)) if m else None
    return {"state": state, "full_reviews": len(full), "actionable_at_head": actionable,
            "last_full_sha": (full[-1].get("commit_id") or "")[:7] if full else None}


def first_comment(t):
    nodes = t["comments"]["nodes"] or [{}]
    return nodes[0]


def fetch(repo, n, deep=False):
    owner, name = repo.split("/", 1)
    view = json.loads(gh("pr", "view", str(n), "--repo", repo, "--json",
                         "number,title,state,isDraft,author,headRefOid,headRefName,baseRefName,"
                         "mergeStateStatus,mergeable,reviewDecision,url"))
    g = json.loads(gh("api", "graphql", "-f", f"query={GQL}", "-F", f"owner={owner}", "-F", f"name={name}",
                      "-F", f"number={n}"))
    pr = g["data"]["repository"]["pullRequest"]
    sha = view["headRefOid"]
    checks = json.loads(gh("api", f"repos/{repo}/commits/{sha}/check-runs?per_page=100")).get("check_runs", [])
    behind = None
    try:  # informational: gh() exits 3 on failure; here that only drops the column
        behind = json.loads(gh("api", f"repos/{repo}/compare/{view['baseRefName']}...{sha}")).get("behind_by")
    except SystemExit:
        pass
    threads = list(pr["reviewThreads"]["nodes"])
    unresolved = [t for t in threads if not t["isResolved"]]
    ok = [c for c in checks if c["status"] == "completed" and c["conclusion"] in OK_CONCLUSIONS]
    fail = [c for c in checks if c["status"] == "completed" and c["conclusion"] not in OK_CONCLUSIONS + (None,)]
    pending = [c for c in checks if c["status"] != "completed"]
    replayed = []
    if deep:
        for c in ok:
            if re.search(r"test", c["name"], re.I):
                log = gh("api", f"repos/{repo}/actions/jobs/{c['id']}/logs")
                if "FROM-CACHE" in log:
                    replayed.append(c["name"])
    review = review_state(repo, n, sha, checks)
    reviews = {}
    for r in pr["reviews"]["nodes"]:
        reviews.setdefault(r["state"], []).append(r["author"]["login"])
    q = pr.get("mergeQueueEntry")
    return {
        "repo": repo, "number": view["number"], "title": view["title"], "state": view["state"],
        "draft": view["isDraft"], "author": view["author"]["login"], "url": view["url"], "head": sha,
        "head_branch": view["headRefName"], "base": view["baseRefName"], "behind_base": behind,
        "merge_state": view["mergeStateStatus"], "mergeable": view["mergeable"],
        "review_decision": view.get("reviewDecision"),
        "queue": {"position": q["position"], "state": q["state"]} if q else None,
        "review": review,
        "checks": {"ok": len(ok), "fail": len(fail), "pending": len(pending),
                   "pending_names": [c["name"] for c in pending], "fail_names": [c["name"] for c in fail],
                   "replayed_from_cache": replayed, "deep": deep},
        "reviews": reviews, "threads_unresolved": len(unresolved),
        "threads": [{"id": t["id"], "resolved": t["isResolved"],
                     "author": first_comment(t).get("author", {}).get("login", "?"),
                     "path": first_comment(t).get("path"), "line": first_comment(t).get("line"),
                     "body": first_comment(t).get("body", "")} for t in threads],
    }


def first_line(s, width=60):
    s = (s or "").strip()
    s = s.splitlines()[0] if s else ""
    return s if len(s) <= width else s[: width - 1] + "…"


def render_status(d):
    print(f"{d['repo']} #{d['number']}  {d['title']}   {d['state']}  draft:{'yes' if d['draft'] else 'no'}  by {d['author']}")
    bb = "" if d["behind_base"] is None else f"   behind base: {d['behind_base']}"
    print(f"head     {d['head'][:7]}   branch {d['head_branch']}   base {d['base']}{bb}")
    q = d["queue"]
    qs = f"position {q['position']} ({q['state']})" if q else "not enqueued"
    conf = {"CONFLICTING": "CONFLICTS — no workflows run until rebased", "MERGEABLE": "none"}.get(
        d["mergeable"], d["mergeable"] or "?")
    print(f"merge    {d['merge_state']}   unresolved threads: {d['threads_unresolved']}   queue: {qs}   conflicts: {conf}")
    c = d["checks"]
    names = ", ".join(c["pending_names"][:2]) or ", ".join(c["fail_names"][:2])
    print(f"checks@{d['head'][:7]}   ok {c['ok']}  fail {c['fail']}  pending {c['pending']}   {names}".rstrip())
    if c["deep"]:
        tail = ": " + ", ".join(c["replayed_from_cache"]) if c["replayed_from_cache"] else ""
        print(f"cache    {len(c['replayed_from_cache'])} test job(s) replayed FROM-CACHE{tail}")
    rv = "   ".join(f"{k} {len(v)} ({', '.join(v)})" for k, v in d["reviews"].items()) or "none"
    print(f"reviews  {rv}")
    print(f"review   {review_line(d)}")
    for t in [t for t in d["threads"] if not t["resolved"]][:6]:
        print(f"threads  {t['author']:<13} {t['path']}:{t['line']}  \"{first_line(t['body'])}\"")
    nxt = []
    if d["threads_unresolved"]:
        nxt.append(f"resolve {d['threads_unresolved']} threads")
    if c["fail"]:
        nxt.append(f"fix {c['fail']} failing check(s): {', '.join(c['fail_names'][:3])}")
    if c["pending"]:
        nxt.append("then checks")
    if d["mergeable"] == "CONFLICTING":
        nxt.append("rebase onto base")
    if d["review"]["state"] == "skipped":
        nxt.append("CodeRabbit skipped this head: `pr … rereview`")
    if d["state"] == "OPEN" and not q:
        nxt.append("`gh pr merge --squash` here means enqueue")
    print("next     " + ("; ".join(nxt) if nxt else ("in queue" if q else "nothing pending")))


def render_threads(d, show_all):
    for t in d["threads"]:
        if t["resolved"] and not show_all:
            continue
        mark = "resolved" if t["resolved"] else "OPEN"
        print(f"{t['id']}  {mark:<8} {t['author']:<13} {t['path']}:{t['line']}")
        for line in (t["body"] or "").strip().splitlines()[:6]:
            print(f"    {line}")


def review_line(d):
    r = d["review"]
    h = d["head"][:7]
    if r["state"] == "reviewed":
        n = r["actionable_at_head"]
        return f"CodeRabbit: reviewed at {h}" + (f" ({n} actionable)" if n is not None else "")
    last = f" — last full review at {r['last_full_sha']}" if r["last_full_sha"] else " — no full review yet"
    if r["state"] == "skipped":
        return f"CodeRabbit: skipped at {h}{last}; post `pr … rereview`"
    if r["state"] == "pending":
        return f"CodeRabbit: running on {h}{last}"
    return f"CodeRabbit: none at {h}{last}"


def resolve_thread(repo, n, thread, reply):
    if reply:
        gh("api", "graphql", "-f", "query=mutation($id:ID!,$body:String!){addPullRequestReviewThreadReply("
           "input:{pullRequestReviewThreadId:$id,body:$body}){comment{id}}}", "-F", f"id={thread}", "-F", f"body={reply}")
    gh("api", "graphql", "-f", "query=mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}",
       "-F", f"id={thread}")
    print(f"resolved {thread} on {repo}#{n}" + (" (with reply)" if reply else ""))


def summary_line(d):
    q = d["queue"]
    qs = f"position {q['position']}" if q else "none"
    return f"{d['state']} threads:{d['threads_unresolved']} pending:{d['checks']['pending']} queue: {qs} review:{d['review']['state']}"


def wait(repo, n, until, timeout):
    poll = float(os.environ.get("NIXTASTIC_PR_POLL", "30"))
    deadline = time.time() + timeout
    last = None
    while True:
        d = fetch(repo, n)
        s = summary_line(d)
        if s != last:
            print(s, flush=True)
            last = s
        met = {"checks": d["checks"]["pending"] == 0, "queue": d["queue"] is not None,
               "merged": d["state"] == "MERGED", "reviewed": d["review"]["state"] == "reviewed"}[until]
        if met:
            print(f"condition met: {until} ({s})")
            return 0
        if time.time() >= deadline:
            print(f"timed out after {timeout}s waiting for {until}; last: {s}", file=sys.stderr)
            return 75
        time.sleep(poll)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("repo")
    ap.add_argument("number", nargs="?", default="0")
    ap.add_argument("cmd", nargs="?", default="status",
                    choices=["status", "threads", "wait", "rereview", "reviewed", "resolve"])
    ap.add_argument("thread", nargs="?", help="resolve: the review thread id (from `threads`)")
    ap.add_argument("--reply", help="resolve: one-line reply to post before resolving")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--deep", action="store_true", help="grep passing test jobs' logs for FROM-CACHE")
    ap.add_argument("--all", action="store_true", help="threads: include resolved")
    ap.add_argument("--until", choices=["checks", "queue", "merged", "reviewed"], default="checks")
    ap.add_argument("--timeout", type=int, default=900, help="wait: seconds before exit 75")
    a = ap.parse_args()
    repo, n = resolve_repo(a.repo, a.number)
    if a.cmd == "wait":
        return wait(repo, n, a.until, a.timeout)
    if a.cmd == "resolve":
        if not a.thread:
            sys.exit("resolve needs a thread id — see `pr <repo> <n> threads`")
        resolve_thread(repo, n, a.thread, a.reply)
        return 0
    if a.cmd == "rereview":
        gh("pr", "comment", str(n), "--repo", repo, "--body", "@coderabbitai full review")
        print(f"posted '@coderabbitai full review' on {repo}#{n}")
        return 0
    d = fetch(repo, n, deep=a.deep)
    if a.json:
        json.dump(d, sys.stdout, indent=1)
        print()
        return 0
    if a.cmd == "reviewed":
        print(review_line(d))
        return 0 if d["review"]["state"] == "reviewed" else 1
    if a.cmd == "threads":
        render_threads(d, a.all)
    else:
        render_status(d)
    return 0


if __name__ == "__main__":
    sys.exit(main())
