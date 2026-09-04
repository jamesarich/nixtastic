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
    echo '   and read what it prints — branch, drift, and the docs that repo expects read.'
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
      *) echo "  WARN      .claude/skills has ${e##*/}, not a bundled copy — left alone; move it into plugin/skills/ or delete it"; return 0 ;;
    esac
  done
  rm -rf "$d"
  echo "  plugin    retired .claude/skills (bundled copies now ship in the plugin)"
}

plugin_pass() {
  root="$1"
  out=$(plugin_render "$root")
  # shellcheck disable=SC2086
  set -- $out
  printf '  plugin    rendered %s forwarder(s) into %s  (%s, version %s)\n' "$2" "$(plugin_render_dir "$root")" "$3" "$4"
  plugin_retire_root_skills "$root"
}
