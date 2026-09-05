# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
#
# The nixtastic plugin: hand-written source in plugin/ (NIXTASTIC_PLUGIN_SRC,
# a store path), rendered per machine into .cache/agent-marketplace/ with the
# generated forwarders, the bundled meshtastic-mcp skills and the memory hook.
# Derived from the workspace plus local checkouts, so it never enters the
# memory store. Design: notes/agent-surface.md.

plugin_render_dir() { printf '%s/.cache/agent-marketplace\n' "$1"; }
plugin_name() { printf 'nixtastic\n'; }
NIXTASTIC_FORWARD_SKIP='speckit-'
NIXTASTIC_BUNDLED_SKILLS='meshtastic-device-ops meshtastic-e2e meshtastic-org-knowledge'

# "<dir>\t<skill>\t<description>" for every repo skill that gets a forwarder.
plugin_forward_pairs() {
  while IFS=$'\t' read -r dir _ _; do
    [ -d "$1/$dir/.claude/skills" ] || continue
    for s in "$1/$dir/.claude/skills"/*/; do
      s=${s%/}; name=${s##*/}
      [ -f "$s/SKILL.md" ] || continue
      case "$name" in "$NIXTASTIC_FORWARD_SKIP"*) continue ;; esac
      desc=$(sed -n 's/^description:[[:space:]]*//p' "$s/SKILL.md" | head -1 | sed 's/^"\(.*\)"$/\1/; s/\\"/"/g')
      printf '%s\t%s\t%s\n' "$dir" "$name" "$desc"
    done
  done < "$NIXTASTIC_REPOS_TSV"
}

# Every input the render depends on, hashed in a stable order. Same
# function for sync (did it change?) and doctor (is the render stale?).
plugin_input_hash() {
  {
    printf '%s\n' "$1"; cat "$NIXTASTIC_REPOS_TSV"
    find "$NIXTASTIC_PLUGIN_SRC" -type f | sort | while read -r f; do
      printf '%s\n' "${f#"$NIXTASTIC_PLUGIN_SRC"}"; cat "$f"
    done
    [ -f "$1/bin/nixtastic-memory-hook" ] && cat "$1/bin/nixtastic-memory-hook"
    if [ -d "$1/meshtastic-mcp/src/meshtastic_mcp/skills" ]; then
      find "$1/meshtastic-mcp/src/meshtastic_mcp/skills" -type f | sort | while read -r f; do
        printf '%s\n' "${f#"$1"}"; cat "$f"
      done
    fi
    plugin_forward_pairs "$1" | while IFS=$'\t' read -r dir skill _; do
      printf '%s/%s\n' "$dir" "$skill"; cat "$1/$dir/.claude/skills/$skill/SKILL.md"
    done
  } | sha256sum | cut -c1-64
}

# $1 = out dir, $2 = root, $3 = dir, $4 = skill, $5 = description.
# SC2016: the backticks are markdown for the generated file, not expansions.
# shellcheck disable=SC2016
plugin_write_forwarder() {
  mkdir -p "$1"
  target="$2/$3/.claude/skills/$4"
  {
    echo '---'
    printf 'name: %s-%s\n' "$3" "$4"
    printf 'description: "[%s] %s"\n' "$3" "$(printf '%s' "$5" | sed 's/"/\\"/g')"
    echo '---'
    printf '# %s: %s (forwarder)\n\n' "$3" "$4"
    printf 'This skill lives in the `%s` repo and is only reachable from a session\n' "$3"
    echo 'started inside it; this forwarder makes it visible from anywhere in the workspace.'
    echo
    printf '1. Run `just brief %s` from the workspace root (or `nix run .#brief -- %s`)\n' "$3" "$3"
    echo '   and read what it prints - branch, drift, and the docs that repo expects read.'
    printf '2. Read and follow, exactly as written:\n\n       %s/SKILL.md\n\n' "$target"
    printf '   Its base directory is `%s`; its `references/` and\n' "$target"
    echo '   scripts resolve relative to that directory, not to this plugin.'
    printf '3. Work inside `%s` (or a worktree of it) and follow that repo'"'"'s own conventions.\n' "$2/$3"
  } > "$1/SKILL.md"
}

# Render into a temp tree, compare the input hash with the stored one, then
# swap. Prints: rendered <forwarders> <changed|unchanged> <version>.
plugin_render() {
  root="$1"; rd=$(plugin_render_dir "$root"); name=$(plugin_name)
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.claude-plugin" "$tmp/$name"
  cp -R "$NIXTASTIC_PLUGIN_SRC"/. "$tmp/$name/"
  chmod -R u+w "$tmp"
  # git tracks no empty dirs, so an as-yet-empty skills/ is absent from the source.
  mkdir -p "$tmp/$name/skills" "$tmp/$name/hooks" "$tmp/$name/bin"
  [ -f "$root/bin/nixtastic-memory-hook" ] && cp "$root/bin/nixtastic-memory-hook" "$tmp/$name/hooks/nixtastic-memory-hook"
  printf '%s\n' "$root" > "$tmp/$name/hooks/workspace-root"
  cut -f1 "$NIXTASTIC_REPOS_TSV" > "$tmp/$name/hooks/repos"
  for s in $NIXTASTIC_BUNDLED_SKILLS; do
    src="$root/meshtastic-mcp/src/meshtastic_mcp/skills/$s"
    [ -d "$src" ] && cp -R "$src" "$tmp/$name/skills/$s"
  done
  n=0
  while IFS=$'\t' read -r dir skill desc; do
    [ -n "$dir" ] || continue
    plugin_write_forwarder "$tmp/$name/skills/$dir-$skill" "$root" "$dir" "$skill" "$desc"
    n=$((n + 1))
  done <<< "$(plugin_forward_pairs "$root")"
  jq -n --arg n "$name" '{name: $n, owner: {name: "James Rich"},
    plugins: [{name: $n, source: ("./" + $n), description: "Meshtastic workspace plugin, rendered by nix run .#sync"}]}' \
    > "$tmp/.claude-plugin/marketplace.json"
  hash=$(plugin_input_hash "$root")
  old=$(cat "$rd/.hash" 2>/dev/null || true)
  if [ "$hash" = "$old" ] && [ -f "$rd/$name/.claude-plugin/plugin.json" ]; then
    version=$(jq -r .version "$rd/$name/.claude-plugin/plugin.json")
    state=unchanged
  else
    version="0.$(date +%s).0"
    state=changed
  fi
  jq --arg v "$version" '.version = $v' "$tmp/$name/.claude-plugin/plugin.json" > "$tmp/pj" && mv "$tmp/pj" "$tmp/$name/.claude-plugin/plugin.json"
  find "$tmp" -type f -name '*.sh' -exec chmod +x {} +
  chmod +x "$tmp/$name/bin"/* "$tmp/$name/hooks/nixtastic-memory-hook" 2>/dev/null || true
  if [ "$state" = changed ] || [ ! -d "$rd/$name" ]; then
    mkdir -p "$rd"
    rm -rf "${rd:?}/${name:?}" "${rd:?}/.claude-plugin"
    mv "$tmp/$name" "$rd/$name"; mv "$tmp/.claude-plugin" "$rd/.claude-plugin"
    printf '%s\n' "$hash" > "$rd/.hash"
  fi
  rm -rf "$tmp"
  printf 'rendered %s %s %s\n' "$n" "$state" "$version"
}

# The root .claude/skills held copies of the bundled three, installed by a
# uv command sync used to print. The plugin carries them now.
plugin_retire_root_skills() {
  d="$1/.claude/skills"
  [ -d "$d" ] || return 0
  for e in "$d"/*; do
    [ -e "$e" ] || continue
    case " $NIXTASTIC_BUNDLED_SKILLS " in
      *" ${e##*/} "*) ;;
      *) echo "  WARN      .claude/skills has ${e##*/}, not a bundled copy - left alone; move it into plugin/skills/ or delete it"; return 0 ;;
    esac
  done
  rm -rf "$d"
  echo "  plugin    retired .claude/skills (bundled copies now ship in the plugin)"
}

NIXTASTIC_PLUGIN_HOOK_NAMES='nixtastic-memory-hook block-main-checkout-edits.sh gradle-queue-guard.sh'

plugin_config_dir() { printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }

plugin_installed_version() {
  f="$(plugin_config_dir)/plugins/installed_plugins.json"
  [ -f "$f" ] || return 0
  jq -r --arg k "$(plugin_name)@$(plugin_name)" '.plugins[$k][0].version // empty' "$f" 2>/dev/null
}

plugin_marketplace_known() {
  f="$(plugin_config_dir)/plugins/known_marketplaces.json"
  [ -f "$f" ] && jq -e --arg k "$(plugin_name)" '.[$k]' "$f" >/dev/null 2>&1
}

# The CLI owns install state; we only call it, and only when needed. Without
# claude on PATH (the test sandbox, a server) say what would run.
# $1 = root, $2 = rendered version. Prints one status word, then the fix.
plugin_register() {
  rd=$(plugin_render_dir "$1"); name=$(plugin_name); inst=$(plugin_installed_version)
  want=""
  if ! plugin_marketplace_known; then want="claude plugin marketplace add $rd && claude plugin install $name@$name"
  elif [ -z "$inst" ]; then want="claude plugin install $name@$name"
  elif [ "$inst" != "$2" ]; then want="claude plugin update $name@$name"
  fi
  [ -z "$want" ] && { echo current; return 0; }
  if ! command -v claude >/dev/null 2>&1; then printf 'skipped\t%s\n' "$want"; return 0; fi
  if sh -c "$want" >/dev/null 2>&1; then
    case "$want" in *marketplace*) echo added+installed ;; *install*) echo installed ;; *) echo updated ;; esac
  else
    printf 'failed\t%s\n' "$want"
  fi
}

# Remove the user-scope entries the plugin now provides, matched by script
# basename so both machines' paths match. Only once the plugin is installed:
# removing first would leave sessions with no memory hook at all.
plugin_migrate_hooks() {
  cfg="$(plugin_config_dir)/settings.json"
  [ -f "$cfg" ] || { echo nothing; return 0; }
  [ -n "$(plugin_installed_version)" ] || { echo deferred; return 0; }
  pat=$(printf '%s' "$NIXTASTIC_PLUGIN_HOOK_NAMES" | tr ' ' '|')
  n=$(jq --arg p "$pat" '[.hooks // {} | .[] | .[] | .hooks[]? | select(.command | test($p))] | length' "$cfg")
  [ "$n" -gt 0 ] || { echo nothing; return 0; }
  cp "$cfg" "$cfg.nixtastic-bak-plugin"
  jq --arg p "$pat" '
    .hooks |= (with_entries(.value |= (map(.hooks |= map(select(.command | test($p) | not))) | map(select(.hooks | length > 0)))))
  ' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  printf 'migrated %s\n' "$n"
}

# The upstream android agent and the guard probe this exact path.
plugin_link_queue() {
  q="$(plugin_config_dir)/bin/gradle-queue"; target="$(plugin_render_dir "$1")/$(plugin_name)/bin/gradle-queue"
  mkdir -p "${q%/*}"
  if [ -L "$q" ] && [ "$(readlink "$q")" = "$target" ]; then echo current; return 0; fi
  bak=""
  if [ -e "$q" ] && [ ! -L "$q" ]; then mv "$q" "$q.pre-plugin"; bak=" backup=$q.pre-plugin"; fi
  ln -sfn "$target" "$q"
  printf 'linked%s\n' "$bak"
}

plugin_pass() {
  root="$1"
  out=$(plugin_render "$root")
  # shellcheck disable=SC2086
  set -- $out
  version="$4"
  printf '  plugin    rendered %s forwarder(s) into %s  (%s, version %s)\n' "$2" "$(plugin_render_dir "$root")" "$3" "$version"
  plugin_retire_root_skills "$root"
  restart=false
  reg=$(plugin_register "$root" "$version")
  case "$reg" in
    current) printf '  plugin    register  current (%s)\n' "$version" ;;
    skipped*) printf '  plugin    register  skipped - claude not on PATH; run:  %s\n' "${reg#*$'\t'}" ;;
    failed*)  printf '  WARN      plugin register failed; run by hand:  %s\n' "${reg#*$'\t'}" ;;
    *) printf '  plugin    register  %s\n' "$reg"; restart=true ;;
  esac
  mig=$(plugin_migrate_hooks)
  case "$mig" in
    deferred) echo '  plugin    hooks     kept in settings.json until the plugin is installed' ;;
    nothing)  echo '  plugin    hooks     nothing to migrate' ;;
    *) printf '  plugin    hooks     migrated %s user-scope entr(ies) now provided by the plugin  (backup: settings.json.nixtastic-bak-plugin)\n' "${mig#migrated }"
       echo '            the old ~/.claude/hooks/*.sh files are unused; delete them when convenient'
       restart=true ;;
  esac
  printf '  plugin    queue     %s\n' "$(plugin_link_queue "$root")"
  [ "$restart" = true ] && echo '            restart claude to load the plugin hooks and MCP server'
  return 0
}
