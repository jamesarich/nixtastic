---
name: review-round
description: Work a CodeRabbit review round on a Meshtastic PR to completion - read the unresolved threads, fix or answer each, push ONCE, reply and resolve every thread, confirm CodeRabbit actually reviewed the new head (not a reply wrapper), and only then wait on checks. Also the pre-PR step - a local `just review` on a finished change. Use whenever a PR has CodeRabbit threads, a merge is BLOCKED with everything green, or before opening a PR in a repo where CodeRabbit runs (org-wide since 2026-09).
---

# Review round

CodeRabbit's findings on these repos are precise (measured: no style nits,
every finding valid). The cost is the loop around them. Every repo here now
reviews **incrementally** (`auto_incremental_review: true`, the upstream
default): a plain `git push` gets its delta reviewed with no command typed.
So the loop is push, read, fix, push - never a trigger comment. This skill
runs it once, in the order that avoids the four known traps:

1. **Replying is not resolving.** `android` refuses to enqueue until every
   thread is *resolved*; `gh pr checks` shows green and says nothing.
2. **The head SHA lies.** Every CodeRabbit reply is wrapped in a review object
   carrying the current head SHA with an empty body. Only a review body with
   `Actionable comments posted` is a real pass. `pr … reviewed` knows this.
3. **A clean round leaves no review object at all.** It edits its pinned
   summary comment in place to read "No actionable comments were generated",
   so reading reviews alone reports a good round as unreviewed and tempts you
   into a trigger comment. `pr … reviewed` reads that comment too, dated
   against the head commit - trust its verdict over a quiet PR. Two
   lookalikes it also names: `paused` (auto-review stops after
   `auto_pause_after_reviewed_commits` pushes, default 5) and `draft` (drafts
   are never auto-reviewed and the check goes green anyway). Both mean
   nothing was looked at; only those two earn a `rereview`.
4. **One push per round.** Each push spends a metered review and one of the
   five commits before auto-pause; fixing findings one commit at a time
   multiplied rounds past commits (#6499: 8 rounds for 6 commits).

## Before the PR exists

From the worktree, on a *finished* change: `just review`. It runs
`coderabbit review --agent` locally (free tier: 3 per hour - do not spend one
mid-implementation). Fix what it finds, commit, then open the PR. Most of a
round's findings never reach GitHub this way.

## The round

1. `just pr <repo> <n>` - read `review`, `threads`, `merge` lines. If
   `review` says `paused` or `skipped`, run `just pr <repo> <n> rereview`
   first and `just pr <repo> <n> wait --until reviewed`; there is nothing to
   address yet. If it says `draft`, the PR has never been reviewed - mark it
   ready, or `rereview --full` to force one while it stays draft.
2. `just pr <repo> <n> threads` - every unresolved thread with id, author,
   file:line, body. Classify each, in a short table you keep for step 5:
   - **fix** - the finding is right; note the change.
   - **decline** - it is wrong or out of scope; note the one-sentence reason.
   - **done** - an earlier push already addressed it.
3. Make every *fix* in the worktree (`just wt <repo> <name> <cmd>` runs
   there without cd), run that repo's own gate, commit - one commit or a few,
   your call, but **one push**.
4. Push once.
5. For each thread: `just pr <repo> <n> resolve <id> --reply "<one line>"`.
   Fix: what changed and where. Decline: the reason. Done: which commit.
   Terse, no attribution, no thanks - [[terse-pr-voice]].
6. `just pr <repo> <n> wait --until reviewed`. The push itself is the
   trigger; nothing to post. If it times out (exit 75), check `just pr <repo>
   <n>` and act on the state it names - `paused`/`skipped` → `rereview` and
   wait again; `running` → wait again; new threads → back to step 2. A
   timeout on its own is never a reason to post anything.
7. `just pr <repo> <n> wait --until checks`, then `just pr <repo> <n>` once
   more: `unresolved threads: 0`, checks green, `next` names the enqueue.

Report proven vs unproven plainly: "CodeRabbit reviewed <sha>, 0 actionable"
is the sentence that ends a round, and only `pr … reviewed` may say it.

## Never

- Never weaken the review profile or disable a tool to shorten a round.
- Never resolve a thread you did not address; decline it with a reason instead.
- Never read a green `CodeRabbit` check as a review.
- Never type `@coderabbitai full review` (or `rereview --full`) to shake a
  quiet PR. It re-reads the whole diff and raises fresh Minor findings on
  lines nobody touched, which is the loop this skill exists to end. It is for
  a draft, or when James asks - at most once per PR.
