#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
#
# SessionStart: reap finished background-job scratch, then retire the rows.
# Nothing else ever deletes a job directory - `claude rm` is the only path and
# it is only ever run by hand, so `~/.claude/jobs/<id>/tmp` accumulates forever.
# Measured 2026-09-15: 1789 MB of 1791 MB was tmp (one 1.6 GB scratch clone);
# all job metadata together was 2 MB.
#
# Three rules, deliberately separate - a job's scratch is disposable long before
# its row is, and a row is disposable long before its transcript:
#   reap    terminal job older than $tmp_days  -> empty tmp/, keep the row
#   reap    blocked job idle over $idle_days   -> empty tmp/, keep the row
#   retire  terminal job older than $rm_days   -> claude rm <id>
#
# A `working` job is never touched at all: its tmp is live scratch.
#
# Prints nothing and always exits 0: a GC that can break a session start is
# worse than the disk it saves. Detaches so SessionStart never waits on it.
#
# Runs on both machines, so nothing here may be GNU-only: no flock, no
# `date -d`, no `stat -c`, no `pgrep -a`. Ages are compared as whole days
# through a date-to-day-number conversion, which is all the policy needs.
#
#   NIXTASTIC_JOBS_GC=off       disable entirely
#   NIXTASTIC_JOBS_GC_TMP_DAYS  default 1
#   NIXTASTIC_JOBS_GC_IDLE_DAYS default 3
#   NIXTASTIC_JOBS_GC_RM_DAYS   default 7
#   NIXTASTIC_JOBS_GC_FG=1      run inline instead of detaching (tests)

[ "${NIXTASTIC_JOBS_GC:-on}" = off ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

jobs_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs"
[ -d "$jobs_dir" ] || exit 0

tmp_days="${NIXTASTIC_JOBS_GC_TMP_DAYS:-1}"
rm_days="${NIXTASTIC_JOBS_GC_RM_DAYS:-7}"
idle_days="${NIXTASTIC_JOBS_GC_IDLE_DAYS:-3}"

# The job this session is running as, so the sweep can never reap its own
# scratch out from under it. Absent for a foreground session, which is fine.
self=""
[ -n "${CLAUDE_JOB_DIR:-}" ] && self=$(basename "$CLAUDE_JOB_DIR")

# Days since the epoch for a YYYY-MM-DD prefix, by the usual civil-date
# formula. Beats `date -d`, which BSD date does not have.
daynum() {
  printf '%s' "${1:0:10}" | awk -F- '
    NF == 3 && $1 ~ /^[0-9]+$/ {
      y = $1; m = $2; d = $3
      if (m <= 2) { y -= 1; m += 12 }
      era = int((y >= 0 ? y : y - 399) / 400)
      yoe = y - era * 400
      doy = int((153 * (m - 3) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      print era * 146097 + doe - 719468
    }'
}

sweep() {
  log="$jobs_dir/.gc.log"
  today=$(daynum "$(date +%Y-%m-%d)")
  [ -n "$today" ] || return 0
  stamp=$(date +%Y-%m-%dT%H:%M:%S)

  # Session ids with a live process. A job can be `done` and still be held open
  # by an attached session, and `claude rm` would stop it. sessionId and
  # resumeSessionId diverge after a respawn, so either one matching counts.
  # shellcheck disable=SC2009  # the id is in the full command line, and only
  # GNU pgrep can print that (-a); BSD pgrep would send us back to ps anyway.
  live=$(ps -Ao args= 2>/dev/null | grep -- '--resume' |
    grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' |
    sort -u || true)

  for d in "$jobs_dir"/*/; do
    [ -d "$d" ] || continue
    id=$(basename "$d")
    [ "$id" = "$self" ] && continue

    if [ ! -f "$d/state.json" ]; then
      # A job directory is created before its state file is written, so a
      # stateless one is either forming right now or was abandoned mid-creation.
      if [ -n "$(find "$d" -maxdepth 0 -mtime +0 2>/dev/null)" ]; then
        rm -rf "${d:?}" && printf '%s stray %s\n' "$stamp" "$id" >> "$log"
      fi
      continue
    fi

    # One field per line: a blank field must not shift the ones after it.
    # Two clocks: a job finished when it went terminal, but it fell idle when it
    # was last touched at all, and a blocked job only ever has the second.
    { read -r state; read -r fin; read -r seen; read -r sids; } < <(jq -r '
      .state // "",
      (.lastTerminalAt // .updatedAt // ""),
      (.updatedAt // .lastTerminalAt // ""),
      ([.sessionId, .resumeSessionId] | map(select(. != null)) | join(" "))' \
      "$d/state.json" 2>/dev/null) || continue

    held=false
    for s in $sids; do
      case "$live" in *"$s"*) held=true ;; esac
    done

    case "$state" in
      done|failed|stopped)
        end=$(daynum "$fin"); [ -n "$end" ] || continue
        age=$((today - end)); due=$tmp_days
        if [ "$age" -ge "$rm_days" ] && [ "$held" = false ] &&
           claude rm "$id" >/dev/null 2>&1; then
          printf '%s retire %s (%sd, %s)\n' "$stamp" "$id" "$age" "$state" >> "$log"
          continue
        fi
        ;;
      blocked)
        # "Awaiting input" is not a promise that the answer is still wanted -
        # in practice a blocked row is as often a dead end nobody dismissed.
        # The row and its transcript stay either way; only scratch goes, and
        # only after longer than a finished job gets.
        [ "$held" = false ] || continue
        end=$(daynum "$seen"); [ -n "$end" ] || continue
        age=$((today - end)); due=$idle_days
        ;;
      *) continue ;;   # `working` is live scratch - never touched
    esac

    # Reap even when the row is kept: scratch is what grows, and a row left
    # open on a PR can otherwise pin gigabytes for weeks.
    if [ "$age" -ge "$due" ] && [ -n "$(ls -A "$d/tmp" 2>/dev/null)" ]; then
      kb=$(du -sk "$d/tmp" 2>/dev/null | cut -f1)
      rm -rf "${d:?}/tmp" && mkdir -p "$d/tmp" &&
        printf '%s reap %s (%s, %sd, %s MB)\n' "$stamp" "$id" "$state" "$age" "$((kb / 1024))" >> "$log"
    fi
  done

  # Keep the log from becoming the thing it cleans up.
  if [ -f "$log" ]; then
    tail -n 500 "$log" > "$log.new" 2>/dev/null && mv "$log.new" "$log"
  fi
}

# Every concurrent background agent fires SessionStart, so one sweep at a time.
# mkdir is the atomic primitive both platforms share; a lock left behind by a
# killed sweep is reclaimed once it is a day old rather than blocking forever.
lock="$jobs_dir/.gc.lock"
[ -n "$(find "$lock" -maxdepth 0 -mtime +0 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null

if [ -n "${NIXTASTIC_JOBS_GC_FG:-}" ]; then
  mkdir "$lock" 2>/dev/null || exit 0
  trap 'rmdir "$lock" 2>/dev/null' EXIT
  sweep
else
  # Re-exec self in the background rather than holding the hook open: the sweep
  # shells out to `claude rm`, which is not fast, and SessionStart must return.
  # setsid puts the sweep in its own session so reaping the hook's process group
  # cannot take it with them; darwin has no setsid, where nohup's ignored HUP is
  # the most that is portably available.
  export NIXTASTIC_JOBS_GC_FG=1
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$0" >/dev/null 2>&1 </dev/null &
  else
    nohup bash "$0" >/dev/null 2>&1 </dev/null &
  fi
fi
exit 0
