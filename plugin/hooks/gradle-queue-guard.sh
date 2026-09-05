#!/bin/bash
# PreToolUse(Bash) guard: route every Gradle build through the machine-wide queue.
#
# Concurrent Claude sessions share one ~/.gradle. Unqueued parallel builds thrash
# the daemon registry and cache locks and exhaust RAM, so raw ./gradlew is denied
# here and the agent is told to re-issue via ~/.claude/bin/gradle-queue.
#
# Cheap, non-building invocations (--stop/--status/--version) pass through, as
# does an explicit GRADLE_QUEUE_BYPASS=1 prefix.

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

[ -z "$cmd" ] && exit 0

# Strip heredoc bodies before matching. They carry data, not commands - a commit
# message or a doc that merely mentions ./gradlew must not trip this guard.
cmd=$(printf '%s\n' "$cmd" | awk '
  inhd { if ($0 == delim) inhd = 0; next }
  {
    line = $0
    if (match(line, /<<-?[ \t]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?/)) {
      d = substr(line, RSTART, RLENGTH)
      gsub(/^<<-?[ \t]*|['"'"'"]/, "", d)
      delim = d; inhd = 1
    }
    print line
  }
')

# Not a Gradle invocation.
printf '%s' "$cmd" | grep -qE '(^|[^-[:alnum:]_/])(\./)?([^[:space:]]*/)?gradlew([[:space:]]|$)' || exit 0

# Already queued, or deliberately bypassed.
printf '%s' "$cmd" | grep -qE 'gradle-queue|GRADLE_QUEUE_BYPASS=1' && exit 0

# Cheap introspection that starts no build.
printf '%s' "$cmd" | grep -qE -- '--version|--status' && exit 0

# --stop is machine-wide: it kills daemons that other sessions are mid-build on,
# which surfaces there as "daemon has been stopped: stop command received".
if printf '%s' "$cmd" | grep -qE -- '--stop'; then
  jq -n '{hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "`./gradlew --stop` is blocked: it stops EVERY Gradle daemon on this machine, including ones other Claude sessions are actively building with. Those sessions see \"daemon has been stopped: stop command received\" and lose a long build.\n\nCheck what is running first with `~/.claude/bin/gradle-queue --status`. Idle daemons now expire on their own (org.gradle.daemon.idletimeout=15min). If you genuinely need a stop and the user asked for it, re-run with GRADLE_QUEUE_BYPASS=1 prefixed."
  }}'
  exit 0
fi

suggest=$(printf '%s' "$cmd" | sed -E 's|(\./)?[^[:space:]]*gradlew([[:space:]]+\|$)|~/.claude/bin/gradle-queue -- |g')

reason="Raw ./gradlew is blocked: $(find "$HOME/.claude/gradle-queue" -maxdepth 1 -name 'slot.*' 2>/dev/null | wc -l | tr -d ' ') of ${GRADLE_QUEUE_SLOTS:-2} shared build slots are in use, and several Claude sessions share one ~/.gradle on this machine. Unqueued parallel builds cause daemon-registry and cache-lock contention and OOM.

Re-run through the queue instead:

  ${suggest}

The wrapper blocks until a slot frees (FIFO), so give the Bash call a long timeout (timeout: 600000) or run_in_background: true - a queued wait plus a cold build easily exceeds the 120s default. Check contention any time with:

  ~/.claude/bin/gradle-queue --status

Reading the output: 'all N slots busy; queued at position N' on stderr is normal progress, not an error. Exit code 75 is a QUEUE-WAIT TIMEOUT, not a build failure - the build never started, so nothing in the source tree caused it and there is nothing to fix. Re-run it or report it as such; never edit or revert files to make a 75 go away. Pass these two rules along in any gradle-runner delegation prompt.

Prefix with GRADLE_QUEUE_BYPASS=1 only if the user explicitly asked to skip the queue."

jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
